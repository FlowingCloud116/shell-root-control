#!/system/bin/sh

# 这个脚本只为安装前实机验证创建临时 IPC，不修改 Magisk 授权策略。
# 它必须由临时允许的 Root Shell 执行，并配合普通 adb shell 客户端调用 status。

RUNTIME_DIR="/dev/shell-root-control"
COMMAND_FIFO="$RUNTIME_DIR/commands"
RESPONSE_DIR="$RUNTIME_DIR/responses"
READY_FILE="$RUNTIME_DIR/ready"
STOP_FILE="$RUNTIME_DIR/stop"
ROOTCTLD_SCRIPT="/data/local/tmp/shell-root-control-preflight-rootctld.sh"
TOYBOX_BIN="/system/bin/toybox"

[ -f "$ROOTCTLD_SCRIPT" ] || exit 1
[ ! -e "$RUNTIME_DIR" ] || exit 1
[ ! -e "$RUNTIME_DIR.lock" ] || exit 1

mkdir "$RUNTIME_DIR" "$RESPONSE_DIR" || exit 1
mkfifo "$COMMAND_FIFO" || exit 1
chown 0:2000 "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO" || exit 1
chmod 0750 "$RUNTIME_DIR" "$RESPONSE_DIR" || exit 1
chmod 0000 "$COMMAND_FIFO" || exit 1
"$TOYBOX_BIN" chcon u:object_r:magisk_file:s0 "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO" || exit 1

for target in "$RUNTIME_DIR" "$RESPONSE_DIR" "$COMMAND_FIFO"; do
    context="$($TOYBOX_BIN ls -Zd "$target" 2>/dev/null)"
    case "$context" in
        *u:object_r:magisk_file:s0*) ;;
        *) exit 1 ;;
    esac
done

rm -f "$STOP_FILE" "$READY_FILE"
/system/bin/sh "$ROOTCTLD_SCRIPT" >/dev/null 2>&1 &
daemon_pid="$!"

i=0
while [ "$i" -lt 50 ] && [ ! -f "$READY_FILE" ] && kill -0 "$daemon_pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
done

[ -f "$READY_FILE" ] && kill -0 "$daemon_pid" 2>/dev/null
