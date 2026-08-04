#!/system/bin/sh

# 这是常驻的 Root 端服务。ADB Shell 只能发送固定协议的短命令，
# 不能把任何输入直接转换成 SQL 或 shell 命令；数据库语句全部由这里固定生成。

RUNTIME_DIR="/dev/shell-root-control"
COMMAND_FIFO="$RUNTIME_DIR/commands"
RESPONSE_DIR="$RUNTIME_DIR/responses"
READY_FILE="$RUNTIME_DIR/ready"
DAEMON_PID_FILE="$RUNTIME_DIR/daemon.pid"
STOP_FILE="$RUNTIME_DIR/stop"
MAGISK_BIN="$(command -v magisk 2>/dev/null)"
TOYBOX_BIN="/system/bin/toybox"
cleaned=0

[ -n "$MAGISK_BIN" ] || exit 1
[ -x "$TOYBOX_BIN" ] || exit 1
[ -d "$RUNTIME_DIR" ] && [ -d "$RESPONSE_DIR" ] && [ -p "$COMMAND_FIFO" ] || exit 1
[ -f "$STOP_FILE" ] && exit 0

cleanup_daemon() {
    [ "$cleaned" -eq 0 ] || return 0
    cleaned=1
    chmod 0000 "$COMMAND_FIFO" 2>/dev/null || true
    rm -f "$READY_FILE" "$DAEMON_PID_FILE"
}
trap 'cleanup_daemon; exit 0' INT TERM HUP
trap cleanup_daemon EXIT

# 尽早发布 PID，让卸载脚本能收敛刚 fork 但尚未 ready 的 child。
printf '%s\n' "$$" > "$DAEMON_PID_FILE" || exit 1
[ -f "$STOP_FILE" ] && exit 0

# SELinux 标签是控制通道可用性的前置条件；失败时不发布 ready。
"$TOYBOX_BIN" chcon u:object_r:magisk_file:s0 "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO" 2>/dev/null || exit 1
for target in "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO"; do
    context="$($TOYBOX_BIN ls -Zd "$target" 2>/dev/null)"
    case "$context" in
        *u:object_r:magisk_file:s0*) ;;
        *) exit 1 ;;
    esac
done
[ -f "$STOP_FILE" ] && exit 0

chown 0:2000 "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO" 2>/dev/null || exit 1
chmod 0750 "$RUNTIME_DIR" "$RESPONSE_DIR" || exit 1
chmod 0620 "$COMMAND_FIFO" || exit 1
[ -f "$STOP_FILE" ] && exit 0

write_response() {
    response_id="$1"
    response_text="$2"
    temp_file="$RESPONSE_DIR/.${response_id}.$$"
    response_file="$RESPONSE_DIR/$response_id"
    printf '%s\n' "$response_text" > "$temp_file" || return 1
    chown 0:2000 "$temp_file" 2>/dev/null || return 1
    chmod 0640 "$temp_file" || return 1
    "$TOYBOX_BIN" chcon u:object_r:magisk_file:s0 "$temp_file" 2>/dev/null || {
        rm -f "$temp_file"
        return 1
    }
    mv -f "$temp_file" "$response_file" || return 1
}

read_policy() {
    row="$($MAGISK_BIN --sqlite "SELECT policy FROM policies WHERE uid=2000;" 2>/dev/null)"
    printf '%s\n' "$row" | sed -n 's/^policy=//p' | tail -n 1
}

read_until() {
    row="$($MAGISK_BIN --sqlite "SELECT until FROM policies WHERE uid=2000;" 2>/dev/null)"
    printf '%s\n' "$row" | sed -n 's/^until=//p' | tail -n 1
}

read_root_access() {
    # COALESCE 让“没有设置行”和“查询失败”可区分：失败时不会误放行。
    row="$($MAGISK_BIN --sqlite "SELECT COALESCE((SELECT value FROM settings WHERE key='root_access'),3) AS value;" 2>/dev/null)"
    value="$(printf '%s\n' "$row" | sed -n 's/^value=//p' | tail -n 1)"
    case "$value" in
        0|1|2|3) printf '%s\n' "$value"; return 0 ;;
        *) return 1 ;;
    esac
}

set_policy() {
    value="$1"
    case "$value" in
        1|2) ;;
        *) return 1 ;;
    esac

    # 固定 SQL 只更新 Shell 的策略和有效期，并通过 SELECT 回读确认真实结果。
    "$MAGISK_BIN" --sqlite "INSERT INTO policies(uid,policy,until,logging,notification) VALUES(2000,$value,0,0,0) ON CONFLICT(uid) DO UPDATE SET policy=excluded.policy,until=0;" >/dev/null 2>&1
    [ "$(read_policy)" = "$value" ] && [ "$(read_until)" = 0 ] || return 1

    # Magisk 会短暂缓存同一 UID 的 su 策略；窗口结束后才通知客户端完成。
    sleep 4
    # 等待期间策略可能被 Magisk App 或其他 Root 进程改写，返回前必须再次确认。
    [ "$(read_policy)" = "$value" ] && [ "$(read_until)" = 0 ]
}

valid_id() {
    id="$1"
    [ "${#id}" -eq 16 ] || return 1
    case "$id" in
        *[!0123456789abcdef]*) return 1 ;;
    esac
    return 0
}

# 用读写方式打开 FIFO，避免没有写端时 read 因 EOF 忙循环。
exec 3<>"$COMMAND_FIFO" || exit 1
[ -f "$STOP_FILE" ] && exit 0
printf '%s\n' ready > "$READY_FILE" || exit 1

IFS=' '
while IFS= read -r request_line <&3; do
    [ -f "$STOP_FILE" ] && break
    [ "${#request_line}" -le 96 ] || continue

    # 只接受固定的 v1 <16 位十六进制 ID> <命令> 格式。
    set -- $request_line
    request_id="$2"
    request_command="$3"
    if [ "$#" -ne 3 ] || [ "$1" != v1 ] || ! valid_id "$request_id"; then
        continue
    fi

    case "$request_command" in
        on)
            root_access="$(read_root_access)"
            case "$root_access" in
                0|1) write_response "$request_id" "error global_setting" ;;
                2|3)
                    if set_policy 2; then
                        write_response "$request_id" "ok on"
                    else
                        write_response "$request_id" "error database"
                    fi
                    ;;
                *) write_response "$request_id" "error database" ;;
            esac
            ;;
        off)
            if set_policy 1; then
                # 按所有者选择，只阻止后续新建的 su，不强杀已经取得 Root 的进程。
                write_response "$request_id" "ok off"
            else
                write_response "$request_id" "error database"
            fi
            ;;
        status)
            current_policy="$(read_policy)"
            case "$current_policy" in
                2)
                    root_access="$(read_root_access)"
                    case "$root_access" in
                        2|3) write_response "$request_id" "ok status on" ;;
                        0|1) write_response "$request_id" "ok status blocked" ;;
                        *) write_response "$request_id" "error database" ;;
                    esac
                    ;;
                1) write_response "$request_id" "ok status off" ;;
                0) write_response "$request_id" "ok status query" ;;
                3) write_response "$request_id" "ok status restrict" ;;
                *) write_response "$request_id" "error database" ;;
            esac
            ;;
        *)
            write_response "$request_id" "error command"
            ;;
    esac

    # 响应由 Root 创建，Shell 只能读取；定期删除过期响应避免无限增长。
    find "$RESPONSE_DIR" -type f -name '[0-9a-f]*' -mmin +10 -delete 2>/dev/null || true
done
