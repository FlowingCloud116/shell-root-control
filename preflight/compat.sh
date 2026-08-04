#!/system/bin/sh

# 这个只读脚本验证目标 Magisk 版本、policies 表字段和 root_access 查询格式。
# 它不修改策略，安装前必须返回 compat_ok。

MAGISK_BIN="$(command -v magisk 2>/dev/null)"
[ -n "$MAGISK_BIN" ] || exit 1
[ "$($MAGISK_BIN -V 2>/dev/null)" = 30700 ] || exit 1

schema_row="$($MAGISK_BIN --sqlite "SELECT sql FROM sqlite_master WHERE type='table' AND name='policies';" 2>/dev/null)"
schema="$(printf '%s\n' "$schema_row" | sed -n 's/^sql=//p' | tail -n 1)"
for definition in 'uid INT' 'policy INT' 'until INT' 'logging INT' 'notification INT'; do
    printf '%s\n' "$schema" | grep -F "$definition" >/dev/null 2>&1 || exit 1
done

root_access_row="$($MAGISK_BIN --sqlite "SELECT COALESCE((SELECT value FROM settings WHERE key='root_access'),3) AS value;" 2>/dev/null)"
root_access="$(printf '%s\n' "$root_access_row" | sed -n 's/^value=//p' | tail -n 1)"
case "$root_access" in
    0|1|2|3) ;;
    *) exit 1 ;;
esac

printf '%s\n' compat_ok
