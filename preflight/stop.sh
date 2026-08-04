#!/system/bin/sh

# 这个脚本只清理安装前预检创建的固定运行目录和临时进程。
# 清理文件前必须确认预检 daemon 已退出，避免留下仍持有 Root 的孤儿进程。

RUNTIME_DIR="/dev/shell-root-control"
COMMAND_FIFO="$RUNTIME_DIR/commands"
RESPONSE_DIR="$RUNTIME_DIR/responses"
STOP_FILE="$RUNTIME_DIR/stop"
DAEMON_PID_FILE="$RUNTIME_DIR/daemon.pid"
PREFLIGHT_SCRIPT="/data/local/tmp/shell-root-control-preflight-rootctld.sh"

preflight_process_matches() {
    process_pid="$1"
    case "$process_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    command_line="$(tr '\000' ' ' < "/proc/$process_pid/cmdline" 2>/dev/null)"
    case "$command_line" in
        *"$PREFLIGHT_SCRIPT"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_preflight_process() {
    process_pid="$1"
    preflight_process_matches "$process_pid" || return 0

    kill "$process_pid" 2>/dev/null || return 1
    attempt=0
    while [ "$attempt" -lt 20 ] && preflight_process_matches "$process_pid"; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if preflight_process_matches "$process_pid"; then
        # 强制信号前重新核对命令行，避免 PID 被系统复用后误杀其他进程。
        kill -9 "$process_pid" 2>/dev/null || return 1
        attempt=0
        while [ "$attempt" -lt 10 ] && preflight_process_matches "$process_pid"; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    ! preflight_process_matches "$process_pid"
}

if [ -d "$RUNTIME_DIR" ]; then
    : > "$STOP_FILE" 2>/dev/null || true
    chmod 0000 "$COMMAND_FIFO" 2>/dev/null || true
fi

daemon_pid="$(cat "$DAEMON_PID_FILE" 2>/dev/null)"
stop_preflight_process "$daemon_pid" || exit 1

# PID 文件可能在异常退出时丢失，因此再按固定脚本路径扫描一次。
for process_dir in /proc/[0-9]*; do
    process_pid="${process_dir#/proc/}"
    if preflight_process_matches "$process_pid"; then
        stop_preflight_process "$process_pid" || exit 1
    fi
done

for process_dir in /proc/[0-9]*; do
    process_pid="${process_dir#/proc/}"
    preflight_process_matches "$process_pid" && exit 1
done

rm -f "$COMMAND_FIFO" "$RUNTIME_DIR/ready" "$DAEMON_PID_FILE" "$STOP_FILE"
find "$RESPONSE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
rmdir "$RESPONSE_DIR" "$RUNTIME_DIR" 2>/dev/null || true
