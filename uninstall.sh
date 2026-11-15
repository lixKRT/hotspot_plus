#!/system/bin/sh
# Runs when the module is removed. Firewall rules / udhcpd do not survive a reboot, but clean up anyway.
# ADR-0008 (amended): attempt a versioned backup first; on exhausted failure log loudly with paths
# and continue, because removal is the owner's explicit destructive choice.
MODDIR=${0%/*}
DATA=${HSP_DATA:-/data/adb/hotspot_plus}
BACKUP_DIR=${HSP_BACKUP_DIR:-/data/adb/hotspot_plus_backups}
BACKUP_LOG=$DATA/../hotspot_plus_backup.log
RETRIES=${HSP_UNINSTALL_RETRIES:-3}
case "$RETRIES" in ''|*[!0-9]*|0) RETRIES=1 ;; esac

IPT=/system/bin/iptables
[ -x "$IPT" ] || IPT=iptables
_n=0
while [ "$_n" -lt 32 ] && $IPT -w -D OUTPUT -j hsp_dhcp 2>/dev/null; do _n=$((_n+1)); done
$IPT -w -F hsp_dhcp 2>/dev/null
$IPT -w -X hsp_dhcp 2>/dev/null
for f in "$DATA"/run/*.pid; do
    [ -f "$f" ] || continue
    p=""
    read -r p < "$f" 2>/dev/null
    [ -n "$p" ] && kill "$p" 2>/dev/null
done

_backup_ok=0
_i=1
SH=/system/bin/sh
[ -x "$SH" ] || SH=sh
while [ "$_i" -le "$RETRIES" ]; do
    if [ -n "$HSP_TEST_BACKUP_FAIL" ]; then
        _rc=1
        _out="test-injected failure"
    elif [ -f "$MODDIR/lib/backup.sh" ]; then
        _out=$(MODDIR=$MODDIR HSP_DATA=$DATA HSP_BACKUP_DIR=$BACKUP_DIR \
            "$SH" -c '. "$1"; . "$2"; backup_create' backup "$MODDIR/lib/common.sh" "$MODDIR/lib/backup.sh" 2>&1)
        _rc=$?
    else
        _out="uninstall: lib/backup.sh missing"
        _rc=1
    fi
    if [ $_rc -eq 0 ] && [ -n "$_out" ]; then
        _backup_ok=1
        echo "已备份用户配置和静态租约: $_out"
        break
    fi
    echo "! 备份尝试 $_i/$RETRIES 失败: $_out"
    [ "$_i" -lt "$RETRIES" ] && sleep "${HSP_UNINSTALL_RETRY_WAIT:-2}"
    _i=$((_i+1))
done
if [ "$_backup_ok" != 1 ]; then
    {
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: 卸载前备份失败，已重试 $((RETRIES - 1)) 次"
        echo "  数据目录: $DATA"
        echo "  备份目录: $BACKUP_DIR"
        echo "  备份日志: $BACKUP_LOG"
        echo "  继续卸载；如需保留配置，请先重装模块并运行 hsp backup 后再移除。"
    } | tee -a "$BACKUP_LOG" >&2
    echo "! ERROR: 备份失败，继续卸载（详情见 $BACKUP_LOG）"
fi

rm -rf "$DATA"

if [ -z "$HSP_TEST_NO_REMOVE_MODULE" ]; then
    rm -rf "${MODDIR:-/data/adb/modules/hotspot_plus}"
fi
