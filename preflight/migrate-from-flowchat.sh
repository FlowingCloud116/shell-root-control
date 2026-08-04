#!/system/bin/sh

# 这个一次性迁移脚本只用于把旧模块 ID flowchat_shell_rootctl 切换到 shell_root_control。
# 它不信任旧模块的卸载实现：先完整校验新模块，再独立封闭旧通道、停止旧进程并固定 DENY。

OLD_MODULE_DIR="/data/adb/modules/flowchat_shell_rootctl"
NEW_MODULE_DIR="/data/adb/modules_update/shell_root_control"
OLD_RUNTIME_DIR="/dev/flowchat-rootctl"
OLD_COMMAND_FIFO="$OLD_RUNTIME_DIR/commands"
OLD_RESPONSE_DIR="$OLD_RUNTIME_DIR/responses"
OLD_STOP_FILE="$OLD_RUNTIME_DIR/stop"
OLD_SERVICE_PID_FILE="$OLD_RUNTIME_DIR/service.pid"
OLD_DAEMON_PID_FILE="$OLD_RUNTIME_DIR/daemon.pid"
MAGISK_BIN="$(command -v magisk 2>/dev/null)"
TOYBOX_BIN="/system/bin/toybox"

[ "$(id -u)" = 0 ] || exit 1
[ -n "$MAGISK_BIN" ] || exit 1
[ -x "$TOYBOX_BIN" ] || exit 1
[ "$($MAGISK_BIN -V 2>/dev/null)" = 30700 ] || exit 1
[ -d "$OLD_MODULE_DIR" ] && [ ! -L "$OLD_MODULE_DIR" ] || exit 1
[ -d "$NEW_MODULE_DIR" ] && [ ! -L "$NEW_MODULE_DIR" ] || exit 1
[ ! -e "$NEW_MODULE_DIR/remove" ] && [ ! -e "$NEW_MODULE_DIR/disable" ] || exit 1
[ -f "$OLD_MODULE_DIR/module.prop" ] && [ ! -L "$OLD_MODULE_DIR/module.prop" ] || exit 1
[ -f "$NEW_MODULE_DIR/module.prop" ] && [ ! -L "$NEW_MODULE_DIR/module.prop" ] || exit 1

read_module_property() {
    property_file="$1"
    property_name="$2"
    sed -n "s/^${property_name}=//p" "$property_file" | tail -n 1
}

# 旧目录和新暂存目录都必须指向预期模块，避免误删其他模块或迁移半成品。
[ "$(read_module_property "$OLD_MODULE_DIR/module.prop" id)" = flowchat_shell_rootctl ] || exit 1
[ "$(read_module_property "$NEW_MODULE_DIR/module.prop" id)" = shell_root_control ] || exit 1
[ "$(read_module_property "$NEW_MODULE_DIR/module.prop" name)" = 'Shell Root Control' ] || exit 1
[ "$(read_module_property "$NEW_MODULE_DIR/module.prop" version)" = 1.2.0 ] || exit 1
[ "$(read_module_property "$NEW_MODULE_DIR/module.prop" versionCode)" = 3 ] || exit 1

for relative_path in post-fs-data.sh service.sh rootctld.sh wirelessd.sh uninstall.sh system/bin/rootctl; do
    candidate="$NEW_MODULE_DIR/$relative_path"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ] || exit 1
    /system/bin/sh -n "$candidate" >/dev/null 2>&1 || exit 1
done

verify_file_hash() {
    expected_hash="$1"
    candidate="$2"
    hash_line="$($TOYBOX_BIN sha256sum "$candidate" 2>/dev/null)" || return 1
    set -- $hash_line
    [ "$#" -ge 2 ] && [ "$1" = "$expected_hash" ]
}

# 迁移只接受本次已在电脑端审查并打包的精确文件，避免误启用被替换或残缺的暂存模块。
verify_file_hash 9b80829802135751f132238fce5526da39cc0caad4bb0f7c0f435bf37fff180f "$NEW_MODULE_DIR/module.prop" || exit 1
verify_file_hash bd57aba2b5310a25105816ca356e63a20c3a82208497e0d12d412c74a1b3364e "$NEW_MODULE_DIR/post-fs-data.sh" || exit 1
verify_file_hash 7dc5f930f4c1877f2b3ec5f713804bd41c9de3ca462868e1441ea2f23b46a3f8 "$NEW_MODULE_DIR/service.sh" || exit 1
verify_file_hash f8e33abc1bd1a8b68ef324aa28b9ab01fa044a4b42ddaa76956a13c3d25ee46f "$NEW_MODULE_DIR/rootctld.sh" || exit 1
verify_file_hash 8be30ccdcbea49ad598dd8d75af53f90a4764a5e72f28cf8a816d61bfc34af0c "$NEW_MODULE_DIR/wirelessd.sh" || exit 1
verify_file_hash 0458919b42b12a4dadc05a58493a2e2ad312d716d3c67c4335aa7eec489c3d86 "$NEW_MODULE_DIR/uninstall.sh" || exit 1
verify_file_hash afc30e3df75cdf949494159b4f74bf17e967ac9c55fc50a6d02ec0b766635051 "$NEW_MODULE_DIR/system/bin/rootctl" || exit 1

# 通用版的控制通道必须全部使用新路径；任何旧运行路径残留都视为暂存不完整。
for relative_path in service.sh rootctld.sh wirelessd.sh uninstall.sh system/bin/rootctl; do
    candidate="$NEW_MODULE_DIR/$relative_path"
    grep -F '/dev/shell-root-control' "$candidate" >/dev/null 2>&1 || exit 1
    if grep -F '/dev/flowchat-rootctl' "$candidate" >/dev/null 2>&1; then
        exit 1
    fi
done

schema_row="$($MAGISK_BIN --sqlite "SELECT sql FROM sqlite_master WHERE type='table' AND name='policies';" 2>/dev/null)"
schema="$(printf '%s\n' "$schema_row" | sed -n 's/^sql=//p' | tail -n 1)"
for definition in 'uid INT' 'policy INT' 'until INT' 'logging INT' 'notification INT'; do
    printf '%s\n' "$schema" | grep -F "$definition" >/dev/null 2>&1 || exit 1
done

old_process_matches() {
    process_pid="$1"
    case "$process_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    process_command="$(tr '\000' ' ' < "/proc/$process_pid/cmdline" 2>/dev/null)"
    case "$process_command" in
        *"$OLD_MODULE_DIR/service.sh"*|*"$OLD_MODULE_DIR/rootctld.sh"*) return 0 ;;
        *) return 1 ;;
    esac
}

stop_old_process() {
    process_pid="$1"
    old_process_matches "$process_pid" || return 0

    kill "$process_pid" 2>/dev/null || return 1
    attempt=0
    while [ "$attempt" -lt 20 ] && old_process_matches "$process_pid"; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if old_process_matches "$process_pid"; then
        # 强制信号前再次核对命令行，绝不因 PID 复用误杀其他进程。
        kill -9 "$process_pid" 2>/dev/null || return 1
        attempt=0
        while [ "$attempt" -lt 10 ] && old_process_matches "$process_pid"; do
            sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    ! old_process_matches "$process_pid"
}

stop_old_pid_file() {
    pid_file="$1"
    [ -f "$pid_file" ] || return 0
    process_pid="$(cat "$pid_file" 2>/dev/null)"
    stop_old_process "$process_pid"
}

stop_all_old_processes() {
    # 先按 PID 文件收敛正常进程，再扫描固定脚本路径处理丢失 PID 文件的孤儿进程。
    stop_old_pid_file "$OLD_DAEMON_PID_FILE" || return 1
    stop_old_pid_file "$OLD_SERVICE_PID_FILE" || return 1
    stop_old_pid_file "$OLD_DAEMON_PID_FILE" || return 1

    pass=0
    while [ "$pass" -lt 3 ]; do
        found=0
        for process_dir in /proc/[0-9]*; do
            process_pid="${process_dir#/proc/}"
            if old_process_matches "$process_pid"; then
                found=1
                stop_old_process "$process_pid" || return 1
            fi
        done
        [ "$found" -eq 0 ] && return 0
        pass=$((pass + 1))
    done

    for process_dir in /proc/[0-9]*; do
        process_pid="${process_dir#/proc/}"
        old_process_matches "$process_pid" && return 1
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

# 先封闭入口再停止进程，避免迁移期间排队的 on 请求晚于 DENY 生效。
if [ -d "$OLD_RUNTIME_DIR" ]; then
    [ ! -e "$OLD_COMMAND_FIFO" ] || [ -p "$OLD_COMMAND_FIFO" ] || exit 1
    : > "$OLD_STOP_FILE" 2>/dev/null || exit 1
    chmod 0000 "$OLD_COMMAND_FIFO" 2>/dev/null || true
fi
stop_all_old_processes || exit 1

# Magisk 会短暂缓存同一 UID 的 su 策略；等待窗口后再次写入并回读。
apply_deny || exit 1
sleep 4
apply_deny || exit 1

# 仅清理旧模块的固定运行目录，不触碰其他模块或应用数据。
rm -f "$OLD_COMMAND_FIFO" "$OLD_RUNTIME_DIR/ready" "$OLD_SERVICE_PID_FILE" "$OLD_DAEMON_PID_FILE" "$OLD_STOP_FILE"
find "$OLD_RESPONSE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
rmdir "$OLD_RESPONSE_DIR" "$OLD_RUNTIME_DIR" "$OLD_RUNTIME_DIR.lock" 2>/dev/null || true
[ ! -e "$OLD_COMMAND_FIFO" ] || exit 1

# 最后才标记旧模块移除；此前任一步失败都保留旧模块，便于重启恢复后重试。
: > "$OLD_MODULE_DIR/remove" || exit 1
[ -f "$OLD_MODULE_DIR/remove" ] && [ ! -L "$OLD_MODULE_DIR/remove" ] || exit 1
printf '%s\n' migration_ready
