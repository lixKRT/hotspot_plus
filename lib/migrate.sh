# shellcheck shell=sh
# hotspot_plus config migrations. Sourced by customize.sh (installer) and usable standalone:
#   sh lib/migrate.sh /data/adb/hotspot_plus
# v0.2.0: default subnet 192.168.43.0/24 -> 192.168.4.0/24. Only applied when the config still
# has the OLD DEFAULTS (gateway .43.1, /24, pool .43.100-.43.200); custom values are left alone.

_mig_get() { # KEY FILE -> value without quotes (last occurrence)
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$2" 2>/dev/null | tail -n 1
}
_mig_set() { # KEY VALUE FILE
    if grep -q "^$1=" "$3"; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$3"
    else
        echo "$1=\"$2\"" >> "$3"
    fi
}
_mig_log() { # message -> stdout + hsp.log
    echo "$*"
    mkdir -p "$MIG_DATA/logs" 2>/dev/null
    echo "$(date '+%m-%d %H:%M:%S') [migrate] $*" >> "$MIG_DATA/logs/hsp.log" 2>/dev/null
}

migrate_subnet_v020() { # DATA_DIR
    MIG_DATA=$1
    _c=$MIG_DATA/config.conf; _l=$MIG_DATA/leases.conf
    [ -f "$_c" ] || return 0
    _gw=$(_mig_get GATEWAY "$_c"); _pf=$(_mig_get PREFIX "$_c")
    _ds=$(_mig_get DHCP_START "$_c"); _de=$(_mig_get DHCP_END "$_c"); _dns=$(_mig_get DNS "$_c")
    [ "$_gw" = 192.168.43.1 ] || return 0
    if [ "${_pf:-24}" != 24 ] || [ "${_ds:-192.168.43.100}" != 192.168.43.100 ] || [ "${_de:-192.168.43.200}" != 192.168.43.200 ]; then
        _mig_log "子网迁移跳过：网关是旧默认 192.168.43.1，但前缀/地址池是自定义的 (PREFIX=$_pf $_ds-$_de)，保持不变"
        return 0
    fi
    cp -f "$_c" "$_c.v01.bak"
    _mig_set GATEWAY 192.168.4.1 "$_c"
    _mig_set DHCP_START 192.168.4.100 "$_c"
    _mig_set DHCP_END 192.168.4.200 "$_c"
    [ "$_dns" = 192.168.43.1 ] && _mig_set DNS 192.168.4.1 "$_c"
    _mig_log "子网迁移：GATEWAY 192.168.43.1 -> 192.168.4.1，地址池 192.168.43.100-200 -> 192.168.4.100-200（备份 config.conf.v01.bak）"
    if [ -f "$_l" ]; then
        _n=$(grep -cE '^[[:space:]]*[^#[:space:]]+[[:space:]]+192\.168\.43\.[0-9]+([[:space:]]|$)' "$_l")
        if [ "${_n:-0}" -gt 0 ]; then
            cp -f "$_l" "$_l.v01.bak"
            sed -i -E '/^[[:space:]]*#/!s/^([[:space:]]*[^[:space:]]+[[:space:]]+)192\.168\.43\.([0-9]+)([[:space:]]|$)/\1192.168.4.\2\3/' "$_l"
            _mig_log "子网迁移：$_n 条静态租约 192.168.43.N -> 192.168.4.N（备份 leases.conf.v01.bak）"
        fi
        # sample comment line from older defaults
        sed -i 's/^# aa:bb:cc:dd:ee:ff 192\.168\.43\.10 /# aa:bb:cc:dd:ee:ff 192.168.4.10 /' "$_l"
    fi
    # old dynamic lease DB holds 192.168.43.x addresses
    rm -f "$MIG_DATA/udhcpd.leases" && _mig_log "子网迁移：已清空旧的 udhcpd 租约数据库"
    return 0
}

# standalone use
case "${0##*/}" in
    migrate.sh) migrate_subnet_v020 "${1:-/data/adb/hotspot_plus}" ;;
esac
