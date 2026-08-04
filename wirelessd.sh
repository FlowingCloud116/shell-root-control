#!/system/bin/sh

# 这个 Root 守护进程只维护 Android 官方配对式无线调试开关。
# 所有者已确认持续强制开启：用户在本次开机手动关闭后，最多约五秒会被重新打开。

RUNTIME_DIR="/dev/shell-root-control"
STOP_FILE="$RUNTIME_DIR/stop"
WIRELESS_PID_FILE="$RUNTIME_DIR/wireless.pid"
SETTINGS_BIN="/system/bin/settings"
CMD_BIN="/system/bin/cmd"
GETPROP_BIN="/system/bin/getprop"
TIMEOUT_BIN="/system/bin/timeout"
POLL_SECONDS=5
cleaned=0

[ -x "$SETTINGS_BIN" ] || exit 1
[ -x "$CMD_BIN" ] || exit 1
[ -x "$GETPROP_BIN" ] || exit 1
[ -x "$TIMEOUT_BIN" ] || exit 1
[ -d "$RUNTIME_DIR" ] || exit 1
[ -f "$STOP_FILE" ] && exit 0

cleanup_wireless_daemon() {
    [ "$cleaned" -eq 0 ] || return 0
    cleaned=1
    recorded_pid="$(cat "$WIRELESS_PID_FILE" 2>/dev/null)"
    # 只删除仍属于自己的 PID 文件，避免旧进程退出时覆盖监督进程刚启动的新实例。
    [ "$recorded_pid" = "$$" ] && rm -f "$WIRELESS_PID_FILE"
}
trap 'cleanup_wireless_daemon; exit 0' INT TERM HUP
trap cleanup_wireless_daemon EXIT

printf '%s\n' "$$" > "$WIRELESS_PID_FILE" || exit 1
chown 0:0 "$WIRELESS_PID_FILE" 2>/dev/null || exit 1
chmod 0640 "$WIRELESS_PID_FILE" || exit 1

sleep_with_stop() {
    remaining="$1"
    while [ "$remaining" -gt 0 ]; do
        [ -f "$STOP_FILE" ] && return 1
        # 用户选择五秒恢复；更长的失败退避也按五秒分段，避免每秒创建一次 sleep。
        if [ "$remaining" -gt 5 ]; then
            sleep_step=5
        else
            sleep_step="$remaining"
        fi
        sleep "$sleep_step"
        remaining=$((remaining - sleep_step))
    done
    return 0
}

read_wireless_setting() {
    "$TIMEOUT_BIN" 5 "$SETTINGS_BIN" get global adb_wifi_enabled 2>/dev/null
}

enable_wireless_setting() {
    "$TIMEOUT_BIN" 5 "$SETTINGS_BIN" put global adb_wifi_enabled 1 >/dev/null 2>&1 || return 1
    [ "$(read_wireless_setting)" = 1 ]
}

# late_start service 可能早于系统完成启动；等 boot_completed 后再触碰 SettingsProvider。
while [ "$($GETPROP_BIN sys.boot_completed 2>/dev/null)" != 1 ]; do
    sleep_with_stop 1 || exit 0
done

# 不支持 Android 配对式无线调试的设备不能影响 rootctl；保留进程并低频等待能力可用。
while [ "$($TIMEOUT_BIN 5 $CMD_BIN adb is-wifi-supported 2>/dev/null)" != true ]; do
    sleep_with_stop 30 || exit 0
done

retry_delay=5
while :; do
    [ -f "$STOP_FILE" ] && break
    current_value="$(read_wireless_setting)"

    # 已经开启时只读取不重写，避免厂商系统重复重建 TLS 无线调试服务。
    if [ "$current_value" != 1 ]; then
        if enable_wireless_setting; then
            retry_delay=5
        else
            # SettingsProvider 暂不可用时逐步退避，避免失败状态形成高频 Root 命令循环。
            sleep_with_stop "$retry_delay" || break
            case "$retry_delay" in
                5) retry_delay=10 ;;
                10) retry_delay=30 ;;
                *) retry_delay=60 ;;
            esac
            continue
        fi
    fi
    sleep_with_stop "$POLL_SECONDS" || break
done
