#!/system/bin/sh

# 卸载时先封闭 FIFO 并停止三个 Root 进程，最后固定写入 DENY。
# 这个顺序避免排队中的 on 请求在卸载回滚之后再次打开 Shell Root。

MODDIR="${0%/*}"
RUNTIME_DIR="/dev/shell-root-control"
COMMAND_FIFO="$RUNTIME_DIR/commands"
RESPONSE_DIR="$RUNTIME_DIR/responses"
STOP_FILE="$RUNTIME_DIR/stop"
SERVICE_PID_FILE="$RUNTIME_DIR/service.pid"
DAEMON_PID_FILE="$RUNTIME_DIR/daemon.pid"
WIRELESS_PID_FILE="$RUNTIME_DIR/wireless.pid"
MAGISK_BIN="$(command -v magisk 2>/dev/null)"

[ -n "$MAGISK_BIN" ] || exit 1

if [ -d "$RUNTIME_DIR" ]; then
    : > "$STOP_FILE" 2>/dev/null || true
    chmod 0000 "$COMMAND_FIFO" 2>/dev/null || true
fi

pid_matches() {
    process_pid="$1"
    expected_path="$2"
    case "$process_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    process_command="$(tr '\000' ' ' < "/proc/$process_pid/cmdline" 2>/dev/null)"
    case "$process_command" in
        *"$expected_path"*) return 0 ;;
        *) return 1 ;;
    esac
}

matching_module_path() {
    process_pid="$1"
    for expected_path in "$MODDIR/service.sh" "$MODDIR/rootctld.sh" "$MODDIR/wirelessd.sh"; do
        if pid_matches "$process_pid" "$expected_path"; then
            printf '%s\n' "$expected_path"
            return 0
        fi
    done
    return 1
}

stop_module_pid() {
    process_pid="$1"
    expected_path="$2"
    pid_matches "$process_pid" "$expected_path" || return 0

    kill "$process_pid" 2>/dev/null || return 1
    attempt=0
    while [ "$attempt" -lt 20 ] && pid_matches "$process_pid" "$expected_path"; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if pid_matches "$process_pid" "$expected_path"; then
        # 等待期间 PID 可能被复用，强制信号前必须再次精确核对脚本路径。
        kill -9 "$process_pid" 2>/dev/null || return 1
        attempt=0
        while [ "$attempt" -lt 10 ] && pid_matches "$process_pid" "$expected_path"; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    ! pid_matches "$process_pid" "$expected_path"
}

stop_pid_file() {
    pid_file="$1"
    expected_path="$2"
    [ -f "$pid_file" ] || return 0
    process_pid="$(cat "$pid_file" 2>/dev/null)"
    stop_module_pid "$process_pid" "$expected_path"
}

wait_pid_file_exit() {
    pid_file="$1"
    expected_path="$2"
    grace_seconds="$3"
    [ -f "$pid_file" ] || return 0
    process_pid="$(cat "$pid_file" 2>/dev/null)"
    while [ "$grace_seconds" -gt 0 ] && pid_matches "$process_pid" "$expected_path"; do
        sleep 1
        grace_seconds=$((grace_seconds - 1))
    done
    return 0
}

stop_all_module_processes() {
    # 先按 PID 文件停止正常进程，再扫描 /proc 收敛 PID 文件缺失或损坏的孤儿进程。
    # wirelessd 的系统调用最多五秒，先给它六秒响应共享 stop 文件，避免遗留 Root 子进程。
    wait_pid_file_exit "$WIRELESS_PID_FILE" "$MODDIR/wirelessd.sh" 6
    stop_pid_file "$WIRELESS_PID_FILE" "$MODDIR/wirelessd.sh" || return 1
    stop_pid_file "$DAEMON_PID_FILE" "$MODDIR/rootctld.sh" || return 1
    stop_pid_file "$SERVICE_PID_FILE" "$MODDIR/service.sh" || return 1
    stop_pid_file "$DAEMON_PID_FILE" "$MODDIR/rootctld.sh" || return 1
    stop_pid_file "$WIRELESS_PID_FILE" "$MODDIR/wirelessd.sh" || return 1

    pass=0
    while [ "$pass" -lt 3 ]; do
        found=0
        for process_dir in /proc/[0-9]*; do
            process_pid="${process_dir#/proc/}"
            expected_path="$(matching_module_path "$process_pid")"
            if [ -n "$expected_path" ]; then
                found=1
                stop_module_pid "$process_pid" "$expected_path" || return 1
            fi
        done
        [ "$found" -eq 0 ] && return 0
        pass=$((pass + 1))
    done

    for process_dir in /proc/[0-9]*; do
        process_pid="${process_dir#/proc/}"
        matching_module_path "$process_pid" >/dev/null 2>&1 && return 1
    done
    return 0
}

read_policy_state() {
    row="$($MAGISK_BIN --sqlite "SELECT CAST(policy AS TEXT)||':'||CAST(until AS TEXT) AS state FROM policies WHERE uid=2000;" 2>/dev/null)"
    printf '%s\n' "$row" | sed -n 's/^state=//p' | tail -n 1
}

apply_deny() {
    "$MAGISK_BIN" --sqlite "INSERT INTO policies(uid,policy,until,logging,notification) VALUES(2000,1,0,0,0) ON CONFLICT(uid) DO UPDATE SET policy=1,until=0;" >/dev/null 2>&1
    [ "$(read_policy_state)" = 1:0 ]
}

# 停止不完整时仍尽力固定 DENY，但不删除运行目录，让失败状态可诊断、可重试。
if ! stop_all_module_processes; then
    apply_deny || exit 1
    sleep 4
    apply_deny || exit 1
    exit 1
fi

# 所有者已确认：卸载后一律关闭 Shell Root，不恢复安装时的临时允许状态。
apply_deny || exit 1
sleep 4
apply_deny || exit 1

# 按所有者选择，卸载后保留无线调试当前状态；这里只停止持续强制开启的守护进程。
# 仅清理本模块创建的固定运行目录，不触碰其他 Magisk 模块或应用数据。
rm -f "$COMMAND_FIFO" "$RUNTIME_DIR/ready" "$SERVICE_PID_FILE" "$DAEMON_PID_FILE" "$WIRELESS_PID_FILE" "$STOP_FILE"
find "$RESPONSE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
rmdir "$RESPONSE_DIR" "$RUNTIME_DIR" "$RUNTIME_DIR.lock" 2>/dev/null || true
