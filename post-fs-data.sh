#!/system/bin/sh

# 这个早期脚本只做一次很短的 DENY 写入，不启动常驻服务，也不阻塞启动流程。
# 这样上次开机若处于 ON，下一次 adbd 可用前就会先回到 OFF。

MAGISK_BIN="$(command -v magisk 2>/dev/null)"
[ -n "$MAGISK_BIN" ] || exit 1
[ "$($MAGISK_BIN -V 2>/dev/null)" = 30700 ] || exit 1

schema_row="$($MAGISK_BIN --sqlite "SELECT sql FROM sqlite_master WHERE type='table' AND name='policies';" 2>/dev/null)"
schema="$(printf '%s\n' "$schema_row" | sed -n 's/^sql=//p' | tail -n 1)"
for definition in 'uid INT' 'policy INT' 'until INT' 'logging INT' 'notification INT'; do
    printf '%s\n' "$schema" | grep -F "$definition" >/dev/null 2>&1 || exit 1
done

# 退出码不作为成功依据；必须回读 policy 和 until。
"$MAGISK_BIN" --sqlite "INSERT INTO policies(uid,policy,until,logging,notification) VALUES(2000,1,0,0,0) ON CONFLICT(uid) DO UPDATE SET policy=1,until=0;" >/dev/null 2>&1
policy_row="$($MAGISK_BIN --sqlite "SELECT policy FROM policies WHERE uid=2000;" 2>/dev/null)"
until_row="$($MAGISK_BIN --sqlite "SELECT until FROM policies WHERE uid=2000;" 2>/dev/null)"
policy_value="$(printf '%s\n' "$policy_row" | sed -n 's/^policy=//p' | tail -n 1)"
until_value="$(printf '%s\n' "$until_row" | sed -n 's/^until=//p' | tail -n 1)"
[ "$policy_value" = 1 ] && [ "$until_value" = 0 ]
