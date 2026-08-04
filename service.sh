#!/system/bin/sh

# 这个常驻监督脚本由 Magisk late_start service 阶段启动。
# 它先关闭 Shell Root，再同时守护受限 rootctl 服务和配对式无线调试服务。

MODDIR="${0%/*}"
RUNTIME_DIR="/dev/shell-root-control"
COMMAND_FIFO="$RUNTIME_DIR/commands"
RESPONSE_DIR="$RUNTIME_DIR/responses"
READY_FILE="$RUNTIME_DIR/ready"
SERVICE_PID_FILE="$RUNTIME_DIR/service.pid"
WIRELESS_PID_FILE="$RUNTIME_DIR/wireless.pid"
STOP_FILE="$RUNTIME_DIR/stop"
MAGISK_BIN="$(command -v magisk 2>/dev/null)"
TOYBOX_BIN="/system/bin/toybox"
daemon_pid=""
wireless_pid=""
cleaned=0

[ -n "$MAGISK_BIN" ] || exit 1

# 当前模块只针对已经实机确认的 Magisk 30.7；版本或表结构不符时不猜测策略值。
[ "$($MAGISK_BIN -V 2>/dev/null)" = 30700 ] || exit 1
schema_row="$($MAGISK_BIN --sqlite "SELECT sql FROM sqlite_master WHERE type='table' AND name='policies';" 2>/dev/null)"
schema="$(printf '%s\n' "$schema_row" | sed -n 's/^sql=//p' | tail -n 1)"
for definition in 'uid INT' 'policy INT' 'until INT' 'logging INT' 'notification INT'; do
    printf '%s\n' "$schema" | grep -F "$definition" >/dev/null 2>&1 || exit 1
done

read_policy() {
    row="$($MAGISK_BIN --sqlite "SELECT policy FROM policies WHERE uid=2000;" 2>/dev/null)"
    printf '%s\n' "$row" | sed -n 's/^policy=//p' | tail -n 1
}

read_until() {
    row="$($MAGISK_BIN --sqlite "SELECT until FROM policies WHERE uid=2000;" 2>/dev/null)"
    printf '%s\n' "$row" | sed -n 's/^until=//p' | tail -n 1
}

set_shell_policy() {
    policy_value="$1"
    case "$policy_value" in
        1|2) ;;
        *) return 1 ;;
    esac

    # 只更新 policy 和 until，保留日志/通知字段；CLI 退出码不可靠，因此必须回读。
    "$MAGISK_BIN" --sqlite "INSERT INTO policies(uid,policy,until,logging,notification) VALUES(2000,$policy_value,0,0,0) ON CONFLICT(uid) DO UPDATE SET policy=excluded.policy,until=0;" >/dev/null 2>&1
    [ "$(read_policy)" = "$policy_value" ] && [ "$(read_until)" = 0 ]
}

# 即使 Toybox、SELinux 或两个 daemon 初始化随后失败，也先保证新的 su 请求处于 DENY。
retry=0
while [ "$retry" -lt 10 ]; do
    if set_shell_policy 1; then
        break
    fi
    retry=$((retry + 1))
    sleep 0.5
done
[ "$retry" -lt 10 ] || exit 1

# Magisk 会短暂缓存同一 UID 的 su 策略；控制通道在缓存窗口结束后才开放。
sleep 4
[ "$(read_policy)" = 1 ] && [ "$(read_until)" = 0 ] || exit 1

[ -x "$TOYBOX_BIN" ] || exit 1
[ -x "$MODDIR/rootctld.sh" ] || exit 1
[ -x "$MODDIR/wirelessd.sh" ] || exit 1

# /dev 是 root 管理的目录，原子 mkdir 防止同一模块重复启动多个监督进程。
if ! mkdir "$RUNTIME_DIR.lock" 2>/dev/null; then
    exit 0
fi

prepare_runtime() {
    mkdir -p "$RUNTIME_DIR" "$RESPONSE_DIR" || return 1
    chown 0:2000 "$RUNTIME_DIR" "$RESPONSE_DIR" 2>/dev/null || return 1
    chmod 0750 "$RUNTIME_DIR" "$RESPONSE_DIR" || return 1

    if [ ! -p "$COMMAND_FIFO" ]; then
        rm -f "$COMMAND_FIFO"
        mkfifo "$COMMAND_FIFO" || return 1
    fi
    chown 0:2000 "$COMMAND_FIFO" 2>/dev/null || return 1
    chmod 0000 "$COMMAND_FIFO" || return 1

    "$TOYBOX_BIN" chcon u:object_r:magisk_file:s0 "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO" 2>/dev/null || return 1
    for target in "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO"; do
        context="$($TOYBOX_BIN ls -Zd "$target" 2>/dev/null)"
        case "$context" in
            *u:object_r:magisk_file:s0*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

pid_matches() {
    process_pid="$1"
    expected_name="$2"
    case "$process_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    process_command="$(tr '\000' ' ' < "/proc/$process_pid/cmdline" 2>/dev/null)"
    case "$process_command" in
        *"$MODDIR/$expected_name"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_tracked_child() {
    process_pid="$1"
    expected_name="$2"
    grace_seconds="$3"
    while [ "$grace_seconds" -gt 0 ] && pid_matches "$process_pid" "$expected_name"; do
        sleep 1
        grace_seconds=$((grace_seconds - 1))
    done
    if pid_matches "$process_pid" "$expected_name"; then
        kill "$process_pid" 2>/dev/null || return 1
        attempt=0
        while [ "$attempt" -lt 20 ] && pid_matches "$process_pid" "$expected_name"; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    if pid_matches "$process_pid" "$expected_name"; then
        # 强制信号前再次核对同一完整脚本路径，避免 PID 复用后误杀其他进程。
        kill -9 "$process_pid" 2>/dev/null || return 1
        attempt=0
        while [ "$attempt" -lt 10 ] && pid_matches "$process_pid" "$expected_name"; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    pid_matches "$process_pid" "$expected_name" && return 1
    case "$process_pid" in
        ''|*[!0-9]*) ;;
        *) wait "$process_pid" 2>/dev/null || true ;;
    esac
    return 0
}

cleanup_service() {
    [ "$cleaned" -eq 0 ] || return 0
    cleaned=1
    : > "$STOP_FILE" 2>/dev/null || true
    chmod 0000 "$COMMAND_FIFO" 2>/dev/null || true
    # wirelessd 的 settings 调用带五秒超时，先给它六秒按 stop 标记自行退出。
    stop_failed=0
    stop_tracked_child "$wireless_pid" wirelessd.sh 6 || stop_failed=1
    stop_tracked_child "$daemon_pid" rootctld.sh 0 || stop_failed=1
    rm -f "$SERVICE_PID_FILE" "$READY_FILE"
    if [ "$stop_failed" -eq 0 ]; then
        rm -f "$WIRELESS_PID_FILE"
        rmdir "$RUNTIME_DIR.lock" 2>/dev/null || true
    fi
}
trap 'cleanup_service; exit 0' INT TERM HUP
trap cleanup_service EXIT

if ! prepare_runtime; then
    exit 1
fi
printf '%s\n' "$$" > "$SERVICE_PID_FILE" || exit 1
rm -f "$STOP_FILE" "$READY_FILE" "$WIRELESS_PID_FILE"

start_root_daemon() {
    rm -f "$READY_FILE"
    "$MODDIR/rootctld.sh" &
    daemon_pid="$!"
}

start_wireless_daemon() {
    "$MODDIR/wirelessd.sh" >/dev/null 2>&1 &
    wireless_pid="$!"
}

start_wireless_daemon

# rootctld 退出时沿用原有监督重启；wirelessd 自身吸收所有可预期系统错误，不额外高频轮询。
while :; do
    [ -f "$STOP_FILE" ] && break

    start_root_daemon
    if [ -f "$STOP_FILE" ]; then
        stop_tracked_child "$daemon_pid" rootctld.sh 0 || true
        daemon_pid=""
        break
    fi

    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=""
    rm -f "$READY_FILE"

    [ -f "$STOP_FILE" ] && break
    # wirelessd 只在不可恢复的脚本损坏或被外部终止时退出；随 rootctld 重启点顺便恢复。
    if ! pid_matches "$wireless_pid" wirelessd.sh; then
        wait "$wireless_pid" 2>/dev/null || true
        start_wireless_daemon
    fi
    sleep 2
done
