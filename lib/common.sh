# shellcheck shell=sh
# shellcheck disable=SC2034,SC2120
# hotspot_plus - shared helpers. Sourced by bin/hsp, bin/hspd, service.sh, action.sh.
# Runs under BusyBox ash (KernelSU standalone mode) or /system/bin/sh (mksh); keep it POSIX-ish.

MODID=hotspot_plus
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/$MODID
DATA=${HSP_DATA:-/data/adb/$MODID}
RUN=$DATA/run
LOGDIR=$DATA/logs
LOG=$LOGDIR/hsp.log
CONF=$DATA/config.conf
LEASES=$DATA/leases.conf
LEASE_DB=$DATA/udhcpd.leases
STATE=$RUN/state
GWSTATE=$RUN/gateway
DHCPSTATE=$RUN/dhcp
HSCTL_JAR=$MODDIR/bin/hsctl.jar
FW_CHAIN=hsp_dhcp

DHCP_STABLE_SECS=${HSP_DHCP_STABLE_SECS:-120}

mkdir -p "$RUN" "$LOGDIR" 2>/dev/null

# ---------------------------------------------------------------- binaries
BB=$HSP_BUSYBOX
[ -n "$BB" ] || for _p in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$_p" ]; then BB=$_p; break; fi
done
[ -n "$IPB" ] || IPB=/system/bin/ip
[ -x "${IPB%% *}" ] || IPB="$BB ip"
[ -n "$IPT" ] || IPT=/system/bin/iptables
[ -x "$IPT" ] || IPT=iptables

bb_has() { [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx "$1"; }

# timeout(1): prefer busybox applet ("timeout [-s SIG] [-k KILL] SECS PROG"), else toybox.
TIMEOUT_BIN=""
if bb_has timeout; then TIMEOUT_BIN="$BB timeout"
elif command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout; fi
# NOTE: busybox flock only supports -s -x -u -n (NO -w). v0.1.0 used "flock -w 60", which made
# busybox print usage and exit 1 immediately -> "另一个操作正在进行". We poll with -n instead.
FLOCK_BIN=""
if [ -n "$HSP_FLOCK" ]; then FLOCK_BIN=$HSP_FLOCK   # test hook
elif bb_has flock; then FLOCK_BIN="$BB flock"
elif command -v flock >/dev/null 2>&1; then FLOCK_BIN=flock; fi

# ---------------------------------------------------------------- logging
TAG=${TAG:-hsp}
log() {
    mkdir -p "$LOGDIR" 2>/dev/null
    _sz=$(wc -c 2>/dev/null < "$LOG" || echo 0)
    if [ "${_sz:-0}" -gt 524288 ]; then mv -f "$LOG" "$LOG.1" 2>/dev/null; fi
    echo "$(date '+%m-%d %H:%M:%S') [$TAG] $*" >> "$LOG" 2>/dev/null
}
say() { echo "$*"; log "$*"; }

# tmo SECS LABEL CMD [ARGS...]: run an external command with a hard timeout, never leaking the
# op-lock fd (9) or the daemon FIFO fd (3) into it. Logs when the timeout fires.
tmo() {
    _ts=$1; _tl=$2; shift 2
    if [ -n "$TIMEOUT_BIN" ]; then
        # shellcheck disable=SC2086
        $TIMEOUT_BIN -k 3 "$_ts" "$@" 9>&- 3>&-
    else
        "$@" 9>&- 3>&-
    fi
    _trc=$?
    case $_trc in
        124|137|143) log "TIMEOUT after ${_ts}s (rc=$_trc): $_tl" ;;
    esac
    return $_trc
}
# iptables with bounded xtables-lock wait and a hard timeout
ipt() { tmo 15 "iptables $*" "$IPT" -w 5 "$@"; }

# ---------------------------------------------------------------- device info
SDK=$(getprop ro.build.version.sdk 2>/dev/null)
RELEASE=$(getprop ro.build.version.release 2>/dev/null)
HYPEROS=$(getprop ro.mi.os.version.incremental 2>/dev/null)
[ -n "$HYPEROS" ] || HYPEROS=$(getprop ro.build.version.incremental 2>/dev/null)
prop_get() { getprop "$1" 2>/dev/null; }

# ---------------------------------------------------------------- config
config_defaults() {
    FIXED_GATEWAY=1
    GATEWAY=192.168.42.1
    PREFIX=24
    DHCP_ENABLE=1
    DHCP_START=192.168.42.100
    DHCP_END=192.168.42.200
    LEASE_TIME=43200
    DNS=""
    ENFORCE_GATEWAY=0
    AUTO_START=0
    AP_IFACE=""
    POLL_INTERVAL=3
    METERED=1
    CALLER_PKG=root
}
load_config() {
    config_defaults
    # shellcheck disable=SC1090
    [ -f "$CONF" ] && . "$CONF"
    case "$PREFIX" in ''|*[!0-9]*) PREFIX=24 ;; esac
    case "$POLL_INTERVAL" in ''|*[!0-9]*) POLL_INTERVAL=3 ;; esac
    case "$LEASE_TIME" in ''|*[!0-9]*) LEASE_TIME=43200 ;; esac
    if ! gateway_addr_valid "$GATEWAY" "$PREFIX"; then
        log "WARN: invalid GATEWAY/PREFIX ($GATEWAY/$PREFIX); using 192.168.42.1/24"
        GATEWAY=192.168.42.1; PREFIX=24
    fi
    if ! gateway_dhcp_valid "$GATEWAY" "$PREFIX" "$DHCP_START" "$DHCP_END"; then
        log "WARN: invalid DHCP range ($DHCP_START-$DHCP_END) for $GATEWAY/$PREFIX; using 192.168.42.100-200"
        DHCP_START=192.168.42.100; DHCP_END=192.168.42.200
    fi
}

# ---------------------------------------------------------------- lifecycle state
state_get() { # key
    [ -f "$STATE" ] || return 1
    sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n1
}
state_set() { # key value
    [ $# -ge 2 ] || return 1
    mkdir -p "$RUN" 2>/dev/null
    _stmp=$STATE.tmp.$$
    if [ -f "$STATE" ]; then
        grep -v "^$1=" "$STATE" > "$_stmp" 2>/dev/null || :
    else
        : > "$_stmp"
    fi
    printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n\r\t' '   ' | tr -d '\000')" >> "$_stmp"
    mv -f "$_stmp" "$STATE"
}

record_lifecycle() { # action result [error]
    state_set last_action "$1"
    state_set last_result "$2"
    state_set last_error "${3:-}"
    state_set last_at "$(date +%s)"
    log "lifecycle: action=$1 result=$2${3:+ error=$3}"
}

record_boot() { # decision result sim [error]
    state_set boot_decision "$1"
    state_set boot_result "$2"
    state_set boot_sim "$3"
    state_set boot_error "${4:-}"
    state_set boot_at "$(date +%s)"
    log "boot-auto: decision=$1 result=$2 sim=${3:-none}${4:+ error=$4}"
}

sim_has_loaded() { # comma-separated gsm.sim.state
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | awk -F',' '
        { for (i = 1; i <= NF; i++) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", $i); if ($i == "LOADED") found = 1 } }
        END { exit !found }'
}

boot_autostart_decision() { # AUTO_START sim_state ap_running(0|1)
    if [ "$1" != 1 ]; then
        echo disabled
    elif [ "$3" = 1 ]; then
        echo already_on
    elif sim_has_loaded "$2"; then
        echo start
    else
        echo no_sim
    fi
}

# ---------------------------------------------------------------- IPv4 math
is_ipv4() {
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    _o=$1
    for _i in 1 2 3 4; do
        _v=${_o%%.*}
        case "$_v" in
            0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
            *) return 1 ;;
        esac
        if [ "$_i" -lt 4 ]; then
            case "$_o" in *.*) _o=${_o#*.} ;; *) return 1 ;; esac
        else
            case "$_o" in *.*) return 1 ;; esac
        fi
    done
    return 0
}
is_private_ipv4() {
    is_ipv4 "$1" || return 1
    _pa=${1%%.*}; _pr=${1#*.}
    _pb=${_pr%%.*}
    [ "$_pa" = 10 ] ||
        { [ "$_pa" = 192 ] && [ "$_pb" = 168 ]; } ||
        { [ "$_pa" = 172 ] && [ "$_pb" -ge 16 ] && [ "$_pb" -le 31 ]; }
}
is_mac() { echo "$1" | tr '-' ':' | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
lc() { echo "$1" | tr 'A-F' 'a-f' | tr '-' ':'; }
sanitize_remark() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\001-\010\013\014\016-\037' \
        | tr -d '"$`\\' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//' | cut -c1-64
}
ip2int() {
    _a=${1%%.*}; _r=${1#*.}; _b=${_r%%.*}; _r=${_r#*.}; _c=${_r%%.*}; _d=${_r#*.}
    echo $(( (_a << 24) + (_b << 16) + (_c << 8) + _d ))
}
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
pfx2mask_int() { echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); }
pfx2mask() { int2ip "$(pfx2mask_int "$1")"; }
last_usable_ip() { # ip/prefix -> last usable host address
    _lu_ip=${1%/*}; _lu_pfx=${1#*/}
    is_ipv4 "$_lu_ip" || return 1
    _lu_m=$(pfx2mask_int "$_lu_pfx")
    _lu_n=$(( $(ip2int "$_lu_ip") & _lu_m ))
    _lu_size=$(( 1 << (32 - _lu_pfx) ))
    int2ip $(( _lu_n + _lu_size - 2 ))
}
wait_dhcp_ready() { # iface [seconds]; interface has IPv4 and one Android DhcpServer sample names it
    _wdi=$1
    _wds=${2:-12}
    _wdsys=${HSP_SYSFS_NET:-/sys/class/net}
    case "$_wdi" in ''|*[!A-Za-z0-9_.-]*) echo "AP probe failed: invalid interface" >&2; return 1 ;; esac
    case "$_wds" in ''|*[!0-9]*) _wds=12 ;; esac
    _wd=0
    while [ "$_wd" -lt "$_wds" ]; do
        if [ -d "$_wdsys/$_wdi" ] && \
           $IPB -4 addr show dev "$_wdi" 2>/dev/null | grep -q 'inet '; then
            break
        fi
        sleep 1; _wd=$((_wd+1))
    done
    if [ ! -d "$_wdsys/$_wdi" ] || \
       ! $IPB -4 addr show dev "$_wdi" 2>/dev/null | grep -q 'inet '; then
        echo "$_wdi not ready after ${_wds}s (interface or IPv4 missing)" >&2
        return 1
    fi
    # One sample only: this probe runs on the hotspot start path, and a dumpsys loop
    # is a known wakeup/crash trigger. A missing, failed, or empty sample leaves the
    # lightweight interface/IPv4 checks authoritative; a reported interface must match.
    if command -v dumpsys >/dev/null 2>&1; then
        _wdo=$(tmo 2 "dumpsys wifi" dumpsys wifi 2>/dev/null) || _wdo=
        _wdq=$(printf '%s\n' "$_wdo" | grep "mApInterfaceName:" | head -n1)
        if [ -n "$_wdq" ]; then
            case "$_wdq" in
                *"mApInterfaceName: $_wdi"*) ;;
                *) echo "$_wdi is not the Android DhcpServer interface" >&2; return 1 ;;
            esac
        fi
    fi
    return 0
}

# Map an address configured in the "configured" subnet onto the actual subnet (keeps host part).
# usage: map_ip <ip> <cfg_net_int> <act_net_int> <act_size>
map_ip() {
    is_ipv4 "$1" || return 1
    _off=$(( $(ip2int "$1") - $2 ))
    [ "$_off" -gt 0 ] && [ "$_off" -lt $(( $4 - 1 )) ] || return 1
    int2ip $(( $3 + _off ))
}

# lease_validate_line MAC IP [REMARK] -> canonical "mac ip remark" or "ERR ..." and rc 1.
# A static address must be a usable host address in the configured private subnet.
lease_validate_line() {
    is_mac "$1" || { echo "ERR 无效 MAC: $1"; return 1; }
    is_ipv4 "$2" || { echo "ERR 无效 IP: $2"; return 1; }
    is_private_ipv4 "$2" || { echo "ERR 静态租约需在私有网段: $2"; return 1; }
    _lv_mask=$(pfx2mask_int "$PREFIX")
    _lv_net=$(( $(ip2int "$GATEWAY") & _lv_mask ))
    _lv_size=$(( 1 << (32 - PREFIX) ))
    _lv_off=$(( $(ip2int "$2") - _lv_net ))
    if [ "$_lv_off" -le 0 ] || [ "$_lv_off" -ge $(( _lv_size - 1 )) ]; then
        echo "ERR 地址 $2 不是 $(int2ip "$_lv_net")/$PREFIX 内的主机地址（不能是网络/广播/越界地址）"
        return 1
    fi
    [ "$2" = "$GATEWAY" ] && { echo "ERR 地址 $2 是热点网关"; return 1; }
    _lv_nm=$(sanitize_remark "${3:-}")
    printf '%s %s%s\n' "$(lc "$1")" "$2" "${_lv_nm:+ $_lv_nm}"
}

# subnet_setup [actual_ip/prefix]: describe configured and observed subnets.
# Sets SUBNET_STATUS (unavailable|configured|mapped), SUBNET_*_NET/CIDR, SUBNET_EXAMPLE.
subnet_setup() {
    SUBNET_STATUS=unavailable
    SUBNET_CFG_NET=""; SUBNET_CFG_CIDR=""; SUBNET_ACTUAL_NET=""; SUBNET_ACTUAL_CIDR=""
    SUBNET_CFG_SIZE=0; SUBNET_ACTUAL_SIZE=0; SUBNET_EXAMPLE=""
    _ss_cm=$(pfx2mask_int "$PREFIX")
    SUBNET_CFG_NET=$(( $(ip2int "$GATEWAY") & _ss_cm ))
    SUBNET_CFG_SIZE=$(( 1 << (32 - PREFIX) ))
    SUBNET_CFG_CIDR="$(int2ip "$SUBNET_CFG_NET")/$PREFIX"
    [ -n "${1:-}" ] || return 0
    _ss_ip=${1%/*}; _ss_pfx=${1#*/}
    [ "$_ss_pfx" != "$1" ] || return 0
    case "$_ss_pfx" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_ss_pfx" -ge 16 ] && [ "$_ss_pfx" -le 28 ] || return 0
    is_ipv4 "$_ss_ip" || return 0
    _ss_am=$(pfx2mask_int "$_ss_pfx")
    SUBNET_ACTUAL_NET=$(( $(ip2int "$_ss_ip") & _ss_am ))
    SUBNET_ACTUAL_SIZE=$(( 1 << (32 - _ss_pfx) ))
    SUBNET_ACTUAL_CIDR="$(int2ip "$SUBNET_ACTUAL_NET")/$_ss_pfx"
    if [ "$SUBNET_ACTUAL_NET" = "$SUBNET_CFG_NET" ] && [ "$_ss_pfx" = "$PREFIX" ]; then
        SUBNET_STATUS=configured
    else
        SUBNET_STATUS=mapped
        SUBNET_EXAMPLE=$(map_ip "$DHCP_START" "$SUBNET_CFG_NET" "$SUBNET_ACTUAL_NET" "$SUBNET_ACTUAL_SIZE") || SUBNET_EXAMPLE=""
        [ -z "$SUBNET_EXAMPLE" ] || SUBNET_EXAMPLE="$DHCP_START -> $SUBNET_EXAMPLE"
    fi
}

# ---------------------------------------------------------------- AP detection
# "iface addr/prefix" for every IPv4 address that could be a hotspot downstream.
addr_fp() {
    $IPB -4 -o addr show 2>/dev/null | awk '{sub(/@.*/,"",$2); print $2, $4}' \
        | grep -vE '^(lo|rmnet|r_rmnet|rev_rmnet|ccmni|tun|ppp|dummy|v4-|clat|ipsec|ifb|sit|ip6|ip_vti|seth|vcan|ims)' 
}
# Interfaces Tethering reports as TetheredState, excluding USB/BT/Ethernet.
tethered_ifaces() {
    tmo 8 "dumpsys tethering" dumpsys tethering 2>/dev/null | awk '
        /Tether state:/ {f=1; next}
        f && /Upstream wanted|Current upstream|Hardware offload/ {f=0}
        f && / - TetheredState/ {print $1}' \
        | grep -vE '^(rndis|usb|ncm|bt-pan|bt|eth|rmnet)'
}
# Sets AP_IF / AP_ADDR (ip/prefix) or returns 1. Uses $1 as cached tethered list if given.
ap_detect() {
    AP_IF=""; AP_ADDR=""
    _fp=$(addr_fp)
    [ -n "$_fp" ] || return 1
    if [ -n "$AP_IFACE" ]; then
        AP_ADDR=$(echo "$_fp" | awk -v i="$AP_IFACE" '$1==i{print $2; exit}')
        [ -n "$AP_ADDR" ] && AP_IF=$AP_IFACE && return 0
        return 1
    fi
    _tl=${1-$(tethered_ifaces)}
    for _t in $_tl; do
        AP_ADDR=$(echo "$_fp" | awk -v i="$_t" '$1==i{print $2; exit}')
        if [ -n "$AP_ADDR" ]; then AP_IF=$_t; return 0; fi
    done
    # Fallback (dumpsys failed / format changed): name heuristics, never the default-route iface.
    if [ -z "$_tl" ]; then
        _def=$($IPB -4 route show table all 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        _cand=$(echo "$_fp" | grep -E '^(wlan[1-9]|swlan[0-9]|ap[0-9]|ap_br_|softap[0-9]|wifi_br|wigig)' | grep -v "^$_def " | head -n1)
        if [ -n "$_cand" ]; then AP_IF=${_cand%% *}; AP_ADDR=${_cand#* }; return 0; fi
    fi
    return 1
}

# Cheap variant for frequent UI polling: trust the daemon's session file (verified against
# current addresses); fall back to full detection when the daemon is not running.
ap_detect_fast() {
    if [ -n "$(daemon_pid)" ]; then
        AP_IF=""; AP_ADDR=""
        [ -f "$RUN/session" ] || return 1
        read -r _si _sa _st < "$RUN/session"
        if addr_fp | grep -qx "$_si $_sa"; then AP_IF=$_si; AP_ADDR=$_sa; return 0; fi
    fi
    ap_detect
}

# ---------------------------------------------------------------- fixed gateway policy
# ADR-0007: module-start may request the gateway, retry twice (5s/15s) and then degrade;
# system-start gets exactly one repair restart. Attempts are counted per hotspot session.
is_private_ipv4() {
    is_ipv4 "$1" || return 1
    case "$1" in
        10.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    esac
    return 1
}
prefix_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 16 ] && [ "$1" -le 28 ]
}
in_subnet() { # ip network_int size (host part excludes network/broadcast)
    _off=$(( $(ip2int "$1") - $2 ))
    [ "$_off" -gt 0 ] && [ "$_off" -lt $(( $3 - 1 )) ]
}
gateway_addr_valid() { # gateway prefix
    is_ipv4 "$1" || return 1
    prefix_valid "$2" || return 1
    is_private_ipv4 "$1" || return 1
    _m=$(pfx2mask_int "$2"); _n=$(( $(ip2int "$1") & _m )); _sz=$(( 1 << (32 - $2) ))
    in_subnet "$1" "$_n" "$_sz"
}
gateway_dhcp_valid() { # gateway prefix dhcp_start dhcp_end
    gateway_addr_valid "$1" "$2" || return 1
    is_ipv4 "$3" && is_ipv4 "$4" || return 1
    _m=$(pfx2mask_int "$2"); _n=$(( $(ip2int "$1") & _m )); _sz=$(( 1 << (32 - $2) ))
    in_subnet "$3" "$_n" "$_sz" && in_subnet "$4" "$_n" "$_sz" || return 1
    _s=$(ip2int "$3"); _e=$(ip2int "$4"); _g=$(ip2int "$1")
    [ "$_s" -le "$_e" ] || return 1
    ! { [ "$_g" -ge "$_s" ] && [ "$_g" -le "$_e" ]; }
}
gateway_matches() { # cfg(ip/prefix) actual(ip/prefix)
    [ -n "$1" ] && [ -n "$2" ] || return 1
    [ "${1%/*}" = "${2%/*}" ] && [ "${1#*/}" = "${2#*/}" ]
}

# Attempt budget for one session. $1=origin $2=repairs already done.
gw_repair_limit() {
    case "$1" in
        module) echo 2 ;;
        system) echo 1 ;;
        *) echo 0 ;;
    esac
}
gw_repair_delay() { # origin attempt_number (1-based)
    case "$1" in
        module) [ "$2" = 1 ] && echo 5 || echo 15 ;;
        system) echo 0 ;;
        *) return 1 ;;
    esac
}
gateway_repair_plan() { # origin attempts_done -> "restart <delay>" | "degrade 0"
    _lim=$(gw_repair_limit "$1")
    [ "$_lim" -gt 0 ] || { echo "degrade 0"; return 0; }
    if [ "$2" -ge "$_lim" ]; then echo "degrade 0"; return 0; fi
    echo "restart $(gw_repair_delay "$1" $(( $2 + 1 )))"
}

gw_get() { # key
    [ -f "$GWSTATE" ] || return 1
    sed -n "s/^$1=//p" "$GWSTATE" 2>/dev/null | tail -n1
}
gw_set() { # key value
    [ $# -ge 2 ] || return 1
    mkdir -p "$RUN" 2>/dev/null
    _gtmp=$GWSTATE.tmp.$$
    if [ -f "$GWSTATE" ]; then
        grep -v "^$1=" "$GWSTATE" > "$_gtmp" 2>/dev/null || :
    else
        : > "$_gtmp"
    fi
    printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n\r\t' '   ' | tr -d '\000')" >> "$_gtmp"
    mv -f "$_gtmp" "$GWSTATE"
}
gw_active() { [ -f "$GWSTATE" ] && [ "$(gw_get active)" = 1 ]; }
gw_pending() { [ "$(gw_get pending)" = 1 ]; }

# Summary survives session end so `hsp status` can show the last outcome.
gw_summary_write() { # result reason
    state_set gw_result "$1"
    state_set gw_reason "${2:-}"
    state_set gw_attempts "$(gw_get attempts)"
    state_set gw_limit "$(gw_get limit)"
    state_set gw_origin "$(gw_get origin)"
    state_set gw_final_gw "$(gw_get final_gw)"
    state_set gw_degraded "$(gw_get degraded)"
    state_set gw_at "$(date +%s)"
}

gw_session_begin() { # origin(module|system)
    _go=${1:-system}
    _gn=$(date +%s)
    mkdir -p "$RUN" 2>/dev/null
    rm -f "$GWSTATE" "$RUN/enforce_broken"
    {
        echo "active=1"
        echo "session=$_gn-$$"
        echo "origin=$_go"
        echo "attempts=0"
        echo "limit=$(gw_repair_limit "$_go")"
        echo "pending=0"
        echo "pending_at=0"
        echo "hold=0"
        echo "hold_at=0"
        echo "seen=0"
        echo "degraded=0"
        echo "reason="
        echo "result=starting"
        echo "final_gw="
        echo "next_at=0"
        echo "at=$_gn"
    } > "$GWSTATE"
    state_set gw_result starting
    state_set gw_reason ""
    log "gateway: session begin origin=$_go limit=$(gw_repair_limit "$_go")"
}

gw_session_end() { # result reason
    gw_active || return 0
    gw_set hold 0
    gw_set hold_at 0
    gw_summary_write "${1:-ended}" "${2:-}"
    log "gateway: session end result=${1:-ended} attempts=$(gw_get attempts) final=$(gw_get final_gw)${2:+ reason=$2}"
    rm -f "$GWSTATE" "$RUN/enforce_broken"
}

gw_degrade() { # reason
    gw_set hold 0
    gw_set hold_at 0
    gw_set degraded 1
    gw_set result degraded
    gw_set reason "$1"
    gw_set next_at 0
    gw_set pending 0
    touch "$RUN/enforce_broken"
    gw_summary_write degraded "$1"
    log "gateway: DEGRADED origin=$(gw_get origin) attempts=$(gw_get attempts) final=$(gw_get final_gw) reason=$1"
}

gw_recovered() { # final
    gw_set degraded 0
    gw_set result ok
    gw_set reason ""
    gw_set next_at 0
    gw_set final_gw "$1"
    rm -f "$RUN/enforce_broken"
    gw_summary_write ok ""
    log "gateway: ok origin=$(gw_get origin) attempts=$(gw_get attempts) gateway=$1"
}

gw_spawn_repair() {
    log "gateway: repair restart to apply $GATEWAY/$PREFIX (attempt $(gw_get attempts)/$(gw_get limit), origin $(gw_get origin))"
    # Test hook: the caller drives `hsp repair` synchronously instead of a background child.
    [ "$HSP_GW_NO_SPAWN" = 1 ] && return 0
    setsid sh "$MODDIR/bin/hsp" repair >/dev/null 2>&1 < /dev/null 3>&- 9>&- &
}

gw_attempt_start() { # now
    gw_set attempts $(( $(gw_get attempts) + 1 ))
    gw_set pending 1
    gw_set pending_phase stopping
    gw_set pending_at "$1"
    gw_set next_at 0
    gw_set result repairing
    gw_set reason "mismatch: want $GATEWAY/$PREFIX, got $(gw_get final_gw)"
    log "gateway: repair attempt $(gw_get attempts)/$(gw_get limit) origin=$(gw_get origin) current=$(gw_get final_gw)"
    gw_spawn_repair
}

gw_pending_started() { gw_set pending_phase starting; }

# A user-requested restart/apply must keep the current session (ADR-0007: only an explicit
# off -> on resets the budget). The daemon may see the AP down before the start completes,
# so mark the session as manually restarting until the next observation.
gw_hold_begin() {
    gw_active || return 0
    gw_set hold 1
    gw_set hold_at "$(date +%s)"
    log "gateway: manual restart requested; keeping session budget (attempts $(gw_get attempts)/$(gw_get limit), origin $(gw_get origin))"
}
gw_hold_clear() {
    [ "$(gw_get hold)" = 1 ] || return 0
    gw_set hold 0
    gw_set hold_at 0
}
gw_holding() { [ "$(gw_get hold)" = 1 ]; }

gw_observe() { # iface addr  (call when the hotspot is up)
    _if=$1; _addr=$2
    gw_active || gw_session_begin system
    _origin=$(gw_get origin)
    [ "$(gw_get seen)" = 1 ] || gw_set seen 1
    if gw_holding; then
        gw_hold_clear
        log "gateway: manual restart returned with $_addr (attempts $(gw_get attempts)/$(gw_get limit))"
    fi
    if gw_pending; then
        # Before the restart begins the old AP is still visible; only an observation made
        # after the stop/start cycle counts as "the repair restart returned".
        if [ "$(gw_get pending_phase)" != starting ]; then
            log "gateway: repair restart in progress; ignoring observation $_addr"
            return 1
        fi
        gw_set pending 0
        gw_set pending_phase ""
        gw_set pending_at 0
        log "gateway: repair restart returned with $_addr (attempts $(gw_get attempts)/$(gw_get limit))"
    fi
    gw_set final_gw "$_addr"
    gw_set iface "$_if"
    if [ "$FIXED_GATEWAY" != 1 ] || [ "$ENFORCE_GATEWAY" != 1 ]; then
        gw_set result disabled
        gw_set reason "fixed gateway disabled"
        gw_set next_at 0
        gw_summary_write disabled "fixed gateway disabled"
        log "gateway: fixed gateway disabled; not enforcing (gateway=$_addr)"
        return 2
    fi
    if gateway_matches "$GATEWAY/$PREFIX" "$_addr"; then
        gw_recovered "$_addr"
        return 0
    fi
    if ! dhcp_capable; then
        # Without our own DHCP a restart cannot change the gateway; do not churn the hotspot.
        gw_degrade "fixed gateway unavailable: own DHCP is not capable"
        return 3
    fi
    if [ "$(gw_get degraded)" = 1 ]; then
        log "gateway: still mismatched ($_addr), session already degraded; no restart"
        return 3
    fi
    _plan=$(gateway_repair_plan "$_origin" "$(gw_get attempts)")
    case "$_plan" in
        restart\ *)
            _delay=${_plan#restart }
            if [ "$_delay" = 0 ]; then
                gw_attempt_start "$(date +%s)"
            else
                gw_set result waiting
                gw_set reason "mismatch: want $GATEWAY/$PREFIX, got $_addr"
                gw_set next_at $(( $(date +%s) + _delay ))
                log "gateway: mismatch ($_addr); retry $(( $(gw_get attempts) + 1 ))/$(gw_get limit) in ${_delay}s"
            fi ;;
        *)
            gw_degrade "mismatch: want $GATEWAY/$PREFIX, got $_addr; retries exhausted" ;;
    esac
    return 1
}

gw_tick() { # now current_addr -> 0 when a repair restart was triggered
    gw_active || return 1
    [ "$(gw_get degraded)" = 1 ] && return 1
    gw_pending && return 1
    _na=$(gw_get next_at)
    _na=${_na:-0}
    case "$_na" in ''|*[!0-9]*) _na=0 ;; esac
    [ "$_na" -gt 0 ] && [ "$1" -ge "$_na" ] || return 1
    if gateway_matches "$GATEWAY/$PREFIX" "$2"; then
        gw_recovered "$2"
        return 1
    fi
    gw_attempt_start "$1"
    return 0
}

# Called when the AP goes down. A repair restart keeps the session alive while pending.
gw_session_down() { # now
    gw_active || return 0
    if gw_holding; then
        _ha=$(gw_get hold_at); _ha=${_ha:-0}
        case "$_ha" in ''|*[!0-9]*) _ha=0 ;; esac
        if [ $(( $1 - _ha )) -lt 120 ]; then
            log "gateway: AP down during a manual restart; keeping session budget"
            return 0
        fi
        gw_hold_clear
    fi
    if gw_pending; then
        _pa=$(gw_get pending_at); _pa=${_pa:-0}
        case "$_pa" in ''|*[!0-9]*) _pa=0 ;; esac
        if [ $(( $1 - _pa )) -lt 120 ]; then
            log "gateway: AP down while repair restart is in flight; keeping session"
            return 0
        fi
        gw_set pending 0
        gw_degrade "repair restart did not bring the hotspot back"
        gw_session_end degraded "$(gw_get reason)"
        return 0
    fi
    if [ "$(gw_get degraded)" = 1 ]; then
        gw_session_end degraded "$(gw_get reason)"
    elif [ "$(gw_get result)" = ok ]; then
        gw_session_end ok ""
    else
        gw_session_end ended "$(gw_get reason)"
    fi
}

gw_status_value() { # key -> active value, else persisted summary
    if gw_active; then gw_get "$1"; else state_get "gw_$1"; fi
}

# ---------------------------------------------------------------- hsctl (dex) wrapper
# Hard timeout per sub-command; HsCtl also has its own internal deadline (exit 4).
hsctl() {
    case "$1" in start) _ht=${HSCTL_TMO_START:-50} ;; stop) _ht=30 ;; *) _ht=20 ;; esac
    echo "--- $(date '+%m-%d %H:%M:%S') hsctl $*" >> "$LOGDIR/hsctl.err"
    # stdout goes to a file, not a pipe: if a killed hsctl left any descendant holding the pipe,
    # $(hsctl ...) in the caller would otherwise still block until that descendant exits.
    _hf=$RUN/hsctl.$$.out
    tmo "$_ht" "hsctl $1" env CLASSPATH="$HSCTL_JAR" "${HSP_APP_PROCESS:-/system/bin/app_process}" \
        /system/bin --nice-name=hsctl com.hsp.HsCtl "$@" > "$_hf" 2>>"$LOGDIR/hsctl.err" < /dev/null
    _hrc=$?
    cat "$_hf" 2>/dev/null; rm -f "$_hf"
    return $_hrc
}
ap_state() {
    _s=$(hsctl state 2>/dev/null | sed -n 's/^ap_state=//p')
    echo "${_s:-0}"
}

# ---------------------------------------------------------------- DHCP firewall (block Android DhcpServer replies)
fw_supported() {
    # xt_owner is mandatory on Android kernels, but verify once.
    ipt -N hsp_probe 2>/dev/null
    if ipt -A hsp_probe -p udp --sport 67 -m owner ! --uid-owner 0 -j RETURN 2>/dev/null; then
        ipt -F hsp_probe 2>/dev/null; ipt -X hsp_probe 2>/dev/null; return 0
    fi
    ipt -F hsp_probe 2>/dev/null; ipt -X hsp_probe 2>/dev/null; return 1
}
fw_add() {
    _if=$1
    ipt -N $FW_CHAIN 2>/dev/null
    ipt -F $FW_CHAIN || return 1
    # Drop DHCP server packets (sport 67 -> 68) leaving the AP iface unless sent by root (our udhcpd).
    # Android's DhcpServer lives in NetworkStack (uid network_stack/1073 or system/1000).
    ipt -A $FW_CHAIN -o "$_if" -p udp --sport 67 --dport 68 -m owner ! --uid-owner 0 -j DROP || return 1
    ipt -C OUTPUT -j $FW_CHAIN 2>/dev/null || ipt -I OUTPUT 1 -j $FW_CHAIN || return 1
    return 0
}
fw_check() {
    ipt -C OUTPUT -j $FW_CHAIN 2>/dev/null && \
    ipt -C $FW_CHAIN -o "$1" -p udp --sport 67 --dport 68 -m owner ! --uid-owner 0 -j DROP 2>/dev/null
}
fw_check_retry() { # iface [attempts]
    _fr_n=${2:-2}
    while [ "$_fr_n" -gt 0 ]; do
        fw_check "$1" && return 0
        _fr_n=$((_fr_n - 1))
        [ "$_fr_n" -gt 0 ] && sleep 0.1
    done
    return 1
}
fw_del() {
    _n=0
    while ipt -D OUTPUT -j $FW_CHAIN 2>/dev/null; do _n=$((_n+1)); [ $_n -gt 5 ] && break; done
    ipt -F $FW_CHAIN 2>/dev/null
    ipt -X $FW_CHAIN 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- DHCP lifecycle
# One state file per hotspot session. udhcpd is verified before the DROP jump is installed.
# Every failure removes the jump before stopping udhcpd, then schedules a bounded retry.
# Once the budget is exhausted the session stays usable on system DHCP and reports degraded.
dhcp_get() { # key
    [ -f "$DHCPSTATE" ] || return 1
    sed -n "s/^$1=//p" "$DHCPSTATE" 2>/dev/null | tail -n1
}
dhcp_set() { # key value
    [ $# -ge 2 ] || return 1
    mkdir -p "$RUN" 2>/dev/null
    _dtmp=$DHCPSTATE.tmp.$$
    if [ -f "$DHCPSTATE" ]; then
        grep -v "^$1=" "$DHCPSTATE" > "$_dtmp" 2>/dev/null || :
    else
        : > "$_dtmp"
    fi
    printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n\r\t' '   ' | tr -d '\000')" >> "$_dtmp"
    mv -f "$_dtmp" "$DHCPSTATE"
}
dhcp_fail_limit() {
    _dl=${HSP_DHCP_FAIL_LIMIT:-3}
    case "$_dl" in ''|*[!0-9]*) _dl=3 ;; esac
    [ "$_dl" -gt 0 ] 2>/dev/null || _dl=3
    echo "$_dl"
}
dhcp_retry_delay() { # attempt number (1-based)
    _drd=${HSP_DHCP_RETRY_DELAYS:-"2 5 15"}
    set -- $_drd
    _drd_n=$#
    [ "$_drd_n" -gt 0 ] || { echo 15; return 0; }
    _drd_i=$1
    [ "$_drd_i" -gt 0 ] 2>/dev/null || _drd_i=1
    [ "$_drd_i" -gt "$_drd_n" ] && _drd_i=$_drd_n
    eval "echo \${$_drd_i}"
}
dhcp_retry_pending() {
    _drp=$(dhcp_get next_retry_at)
    case "$_drp" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_drp" -gt 0 ]
}
dhcp_stable_check() { # now
    _dc_now=$1
    _dc_since=$(dhcp_get stable_since)
    case "$_dc_since" in ''|*[!0-9]*) _dc_since=0 ;; esac
    [ "$(dhcp_get state)" = serving ] || return 1
    [ "$(dhcp_get serving)" = 1 ] || return 1
    [ "$_dc_since" -gt 0 ] || return 1
    [ $((_dc_now - _dc_since)) -ge "$DHCP_STABLE_SECS" ] || return 1
    dhcp_set attempts 0
    dhcp_set first_failure_at 0
    dhcp_set last_failure_at 0
    dhcp_set next_retry_at 0
    dhcp_set stable_since "$_dc_now"
    dhcp_summary_write
    log "dhcp: stable for ${DHCP_STABLE_SECS}s; retry budget reset"
    return 0
}
dhcp_session_begin() { # [--preserve]
    _ds_preserve=0
    case "${1:-}" in
        --preserve|preserve) _ds_preserve=1 ;;
    esac
    mkdir -p "$RUN" 2>/dev/null
    _ds_now=$(date +%s)
    if [ "$_ds_preserve" = 1 ] && [ -f "$DHCPSTATE" ]; then
        dhcp_set at "$_ds_now"
        dhcp_summary_write
        log "dhcp: session probe preserved (state=$(dhcp_get state) attempts=$(dhcp_get attempts)/$(dhcp_get limit))"
        return 0
    fi
    {
        echo "session=$_ds_now-$$"
        echo "state=idle"
        echo "serving=0"
        echo "degraded=0"
        echo "attempts=0"
        echo "limit=$(dhcp_fail_limit)"
        echo "first_failure_at=0"
        echo "last_failure_at=0"
        echo "next_retry_at=0"
        echo "stable_since=0"
        echo "reason="
        echo "last_error="
        echo "retry_available=0"
        echo "at=$_ds_now"
    } > "$DHCPSTATE"
    state_set dhcp_mode idle
    state_set dhcp_degraded 0
    state_set dhcp_reason ""
    state_set dhcp_last_error ""
    state_set dhcp_retry_available 0
    state_set dhcp_attempts 0
    state_set dhcp_limit "$(dhcp_fail_limit)"
    state_set dhcp_next_retry_at 0
    log "dhcp: session begin limit=$(dhcp_fail_limit)"
}
dhcp_summary_write() {
    state_set dhcp_mode "$(dhcp_get state)"
    state_set dhcp_degraded "$(dhcp_get degraded)"
    state_set dhcp_reason "$(dhcp_get reason)"
    state_set dhcp_last_error "$(dhcp_get last_error)"
    state_set dhcp_retry_available "$(dhcp_get retry_available)"
    state_set dhcp_attempts "$(dhcp_get attempts)"
    state_set dhcp_limit "$(dhcp_get limit)"
    state_set dhcp_next_retry_at "$(dhcp_get next_retry_at)"
    state_set dhcp_first_failure_at "$(dhcp_get first_failure_at)"
    state_set dhcp_last_failure_at "$(dhcp_get last_failure_at)"
    state_set dhcp_at "$(date +%s)"
}
dhcp_rollback_ordered() { # reason error [state]
    _dro_locked=0
    dhcp_lock_held || { health_lock || return 1; _dro_locked=1; }
    fw_del
    dhcp_stop
    dhcp_set serving 0
    dhcp_set state "${3:-failed}"
    [ -n "$1" ] && dhcp_set reason "$1"
    [ -n "$2" ] && dhcp_set last_error "$2"
    log "dhcp: fail-closed (${1:-takeover failed}): removed $FW_CHAIN/OUTPUT before stopping udhcpd${2:+ error=$2}"
    [ "$_dro_locked" = 1 ] && health_unlock
    return 0
}
dhcp_lock_held() {
    [ -n "${HEALTH_LOCK:-}" ]
}
dhcp_lock() { # serialize hspd takeover/rollback with `hsp dhcp retry`
    dhcp_lock_held && return 0
    health_lock
}
dhcp_unlock() {
    health_unlock
}
dhcp_record_failure() { # reason error
    _dn=$(date +%s)
    _df=$(dhcp_get attempts); _df=${_df:-0}
    case "$_df" in ''|*[!0-9]*) _df=0 ;; esac
    _dff=$(dhcp_get first_failure_at); _dff=${_dff:-0}
    case "$_dff" in ''|*[!0-9]*) _dff=0 ;; esac
    _df=$((_df + 1))
    [ "$_dff" -eq 0 ] && _dff=$_dn
    dhcp_set attempts "$_df"
    dhcp_set first_failure_at "$_dff"
    dhcp_set last_failure_at "$_dn"
    dhcp_set stable_since 0
    dhcp_set reason "$1"
    dhcp_set last_error "$2"
    if [ "$_df" -ge "$(dhcp_fail_limit)" ]; then
        dhcp_rollback_ordered "$1" "$2" degraded
        dhcp_set degraded 1
        dhcp_set retry_available 1
        dhcp_set next_retry_at 0
        dhcp_set state degraded
        dhcp_summary_write
        log "dhcp: DEGRADED system DHCP owns replies; retry available reason=${1:-unknown}"
        return 0
    fi
    dhcp_rollback_ordered "$1" "$2" retrying
    dhcp_set degraded 0
    dhcp_set retry_available 1
    dhcp_set next_retry_at $((_dn + $(dhcp_retry_delay "$_df")))
    dhcp_summary_write
    log "dhcp: retry $((_df + 1))/$(dhcp_fail_limit) in $(( $(dhcp_get next_retry_at) - _dn ))s; system DHCP owns replies meanwhile"
}
dhcp_degrade() { # reason error
    dhcp_rollback_ordered "$1" "$2" degraded
    dhcp_set degraded 1
    dhcp_set retry_available 1
    dhcp_set next_retry_at 0
    dhcp_set state degraded
    dhcp_summary_write
    log "dhcp: DEGRADED system DHCP owns replies; retry available reason=${1:-unknown}"
}
dhcp_crash() { # last_error
    case "$(dhcp_get state)" in serving) ;; *) return 0 ;; esac
    dhcp_record_failure "udhcpd 连续异常退出" "$1"
}
dhcp_takeover() { # iface addr
    _dt_if=$1; _dt_addr=$2
    [ -n "$_dt_if" ] && [ -n "$_dt_addr" ] || return 1
    if [ "$(dhcp_get state)" = degraded ] && [ "$HSP_DHCP_MANUAL_RETRY" != 1 ]; then
        log "dhcp: automatic takeover refused; session is degraded and needs manual retry"
        return 1
    fi
    dhcp_lock || return 1
    _dt_rc=0
    _dhcp_takeover_locked "$_dt_if" "$_dt_addr" || _dt_rc=$?
    dhcp_unlock
    return $_dt_rc
}
_dhcp_takeover_locked() {
    _dt_if=$1; _dt_addr=$2
    if [ "$(dhcp_get state)" = degraded ] && [ "$HSP_DHCP_MANUAL_RETRY" != 1 ]; then
        log "dhcp: automatic takeover refused; session is degraded and needs manual retry"
        return 1
    fi
    if ! dhcp_capable; then
        dhcp_rollback_ordered "自建 DHCP 不可用" "DHCP_ENABLE=0 / udhcpd 缺失 / iptables owner 不受支持"
        dhcp_set retry_available 1
        dhcp_set degraded 1
        dhcp_set state degraded
        dhcp_summary_write
        return 1
    fi
    if ! dhcp_start "$_dt_if" "$_dt_addr" || ! dhcp_running; then
        dhcp_record_failure "udhcpd 启动失败" "udhcpd 未能保持运行"
        return 1
    fi
    if ! fw_add "$_dt_if" || ! fw_check_retry "$_dt_if"; then
        dhcp_record_failure "iptables 接管规则安装失败" "无法安装或验证 $FW_CHAIN/OUTPUT"
        return 1
    fi
    dhcp_set serving 1
    dhcp_set state serving
    dhcp_set degraded 0
    dhcp_set stable_since "$(date +%s)"
    dhcp_set reason ""
    dhcp_set last_error ""
    dhcp_set retry_available 0
    dhcp_set next_retry_at 0
    dhcp_summary_write
    log "dhcp: takeover confirmed: $DHCP_SUMMARY; $FW_CHAIN/OUTPUT installed"
    return 0
}
dhcp_retry() { # [iface addr]
    _dr_if=${1:-}; _dr_addr=${2:-}
    if [ -z "$_dr_if" ]; then
        ap_detect_fast >/dev/null 2>&1 || {
            dhcp_set last_error "热点未开启，无法重试自建 DHCP"
            dhcp_summary_write
            echo "重试失败：热点未开启"
            return 1
        }
        _dr_if=$AP_IF; _dr_addr=$AP_ADDR
    fi
    _dr_reason=$(dhcp_get reason)
    log "dhcp: manual retry requested for $_dr_if $_dr_addr"
    health_lock || {
        echo "重试失败：另一个 DHCP 操作正在进行"
        return 1
    }
    dhcp_session_begin
    if HSP_DHCP_MANUAL_RETRY=1 _dhcp_takeover_locked "$_dr_if" "$_dr_addr"; then
        health_unlock
        log "dhcp: manual retry succeeded; static leases restored"
        echo "自建 DHCP 已恢复，静态租约生效"
        return 0
    fi
    dhcp_degrade "${_dr_reason:-udhcpd 连续异常退出}" "$(dhcp_get last_error)"
    health_unlock
    echo "重试失败：$(dhcp_get last_error)；仍由系统 DHCP 分配地址，热点未重启"
    return 1
}
dhcp_reset() {
    _dr_now=$(date +%s)
    _dr_degraded=$(dhcp_get degraded)
    _dr_state=$(dhcp_get state)
    dhcp_set attempts 0
    dhcp_set first_failure_at 0
    dhcp_set last_failure_at 0
    dhcp_set next_retry_at 0
    dhcp_set stable_since "$_dr_now"
    if dhcp_running; then
        dhcp_set degraded 0
        dhcp_set reason ""
        dhcp_set last_error ""
        dhcp_set retry_available 0
        dhcp_set serving 1
        dhcp_set state serving
    elif [ "$_dr_degraded" = 1 ]; then
        dhcp_set degraded 0
        dhcp_set state idle
        dhcp_set retry_available 0
        [ "$_dr_state" = degraded ] && dhcp_set reason ""
    else
        dhcp_set serving 0
        dhcp_set state idle
    fi
    dhcp_summary_write
    log "dhcp: user reset cleared failure budget and degraded flag"
}
dhcp_health_check() { # now iface addr
    _dhc_now=${1:-$(date +%s)}
    _dhc_if=$2; _dhc_addr=$3
    [ -n "$_dhc_if" ] && [ -n "$_dhc_addr" ] || return 0
    _dhc_state=$(dhcp_get state)
    if [ "$_dhc_state" = degraded ] || [ "$(dhcp_get degraded)" = 1 ]; then
        return 0
    fi
    case "$_dhc_state" in
        serving)
            if dhcp_running; then
                dhcp_stable_check "$_dhc_now"
                if ! fw_check "$_dhc_if"; then
                    log "dhcp: takeover rule missing; fail-closing"
                    dhcp_crash "接管规则丢失"
                    return 1
                fi
                return 0
            fi
            log "dhcp: udhcpd exited while serving; removing $FW_CHAIN before retry"
            dhcp_crash "udhcpd 进程已退出"
            return 1 ;;
        retrying)
            _dhc_next=$(dhcp_get next_retry_at)
            case "$_dhc_next" in ''|*[!0-9]*) _dhc_next=0 ;; esac
            [ "$_dhc_next" -gt 0 ] && [ "$_dhc_now" -ge "$_dhc_next" ] || return 0
            if dhcp_running || fw_check "$_dhc_if"; then
                log "dhcp: retrying state has partial ownership; fail-closing before retry"
                dhcp_record_failure "DHCP 接管状态不一致" "重试期间发现遗留 udhcpd 或 OUTPUT 跳转"
                return 1
            fi
            log "dhcp: retry due (attempt $(dhcp_get attempts)/$(dhcp_fail_limit))"
            dhcp_takeover "$_dhc_if" "$_dhc_addr" || return 1
            return 0 ;;
        *)
            return 0 ;;
    esac
}

# ---------------------------------------------------------------- udhcpd
dhcp_pid() {
    _p=$(cat "$RUN/udhcpd.pid" 2>/dev/null)
    [ -n "$_p" ] || return 0
    kill -0 "$_p" 2>/dev/null || return 0
    # setsid(1) normally execs in place. Some test shells keep an intermediate shell and
    # would hide the real applet from the child's cmdline; trust the pidfile only then.
    [ "$HSP_DHCP_PIDFILE_TRUST" = 1 ] && { echo "$_p"; return 0; }
    grep -q udhcpd "/proc/$_p/cmdline" 2>/dev/null && echo "$_p"
}
dhcp_running() { [ -n "$(dhcp_pid)" ]; }
dhcp_stop() {
    _p=$(dhcp_pid)
    if [ -n "$_p" ]; then
        kill "$_p" 2>/dev/null   # SIGTERM -> udhcpd writes lease file and exits
        _i=0; while kill -0 "$_p" 2>/dev/null && [ $_i -lt 10 ]; do sleep 0.2; _i=$((_i+1)); done
        kill -9 "$_p" 2>/dev/null
    fi
    # stray instances started by us (match our conf path)
    for _q in $(pgrep -f "udhcpd -f $RUN/udhcpd.conf" 2>/dev/null); do kill "$_q" 2>/dev/null; done
    rm -f "$RUN/udhcpd.pid"
}

# ---------------------------------------------------------------- DHCP health lock
# The daemon holds this only around a takeover/rollback sequence, never for its whole lifetime.
# A manual `hsp dhcp retry` takes the same lock so it cannot race the daemon's fail-close path.
HEALTHLOCKF=$RUN/dhcp-health.lock
HEALTHLOCKD=$RUN/dhcp-health.lockdir
HEALTH_LOCK=""
health_lock() {
    [ -n "${HEALTH_LOCK:-}" ] && return 0
    _hl_flock=${FLOCK_BIN:-}
    [ "${HSP_HEALTH_LOCK_MKDIR:-0}" = 1 ] && _hl_flock=""
    _hl_t0=$(date +%s)
    _hl_wait=${HSP_HEALTH_LOCK_WAIT:-10}
    while :; do
        if [ -n "$_hl_flock" ] && [ "$_hl_flock" != ":" ]; then
            if (exec 8>>"$HEALTHLOCKF"; $_hl_flock -n 8 9>&-) 2>/dev/null; then
                HEALTH_LOCK=flock
                return 0
            fi
        else
            if mkdir "$HEALTHLOCKD" 2>/dev/null; then
                echo "$$" > "$HEALTHLOCKD/pid"
                HEALTH_LOCK=mkdir
                return 0
            fi
            _hl_pid=$(cat "$HEALTHLOCKD/pid" 2>/dev/null)
            [ -n "$_hl_pid" ] && ! kill -0 "$_hl_pid" 2>/dev/null && rmdir "$HEALTHLOCKD" 2>/dev/null && continue
        fi
        [ $(( $(date +%s) - _hl_t0 )) -ge "$_hl_wait" ] && return 1
        sleep 0.2
    done
}
health_unlock() {
    case "${HEALTH_LOCK:-}" in
        mkdir) rm -f "$HEALTHLOCKD/pid"; rmdir "$HEALTHLOCKD" 2>/dev/null ;;
    esac
    HEALTH_LOCK=""
}

# Android's static-gateway request carries a fixed placeholder client address. On a cold
# start, the system DhcpServer can hand that placeholder to a real client before udhcpd
# starts. Once our server takes over, delete only the neighbour entries that are definitely
# wrong: a bound MAC holding an address other than its configured static IP, or a client
# holding the system placeholder. Dynamic clients stay untouched.
dhcp_release_placeholder_clients() { # iface gateway/prefix placeholder
    _ri=$1; _ra=$2; _rp=$3
    [ -n "$_ri" ] && [ -n "$_ra" ] && [ -n "$_rp" ] || return 0
    _rgw=${_ra%/*}
    _rmask=$(pfx2mask_int "${_ra#*/}")
    _rnet=$(( $(ip2int "$_rgw") & _rmask ))
    _rsize=$(( 1 << (32 - ${_ra#*/}) ))
    _tmp=$RUN/dhcp-neigh.$$.tmp
    $IPB -4 neigh show dev "$_ri" 2>/dev/null > "$_tmp"
    awk '
        /lladdr/ {
            ip = $1; mac = ""; for (i = 2; i <= NF; i++) if ($i == "lladdr") mac = tolower($(i + 1))
            if (mac ~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/) print mac, ip
        }' "$_tmp" | while read -r _rmac _rip; do
        _rstatic=$(lease_ip_for_mac "$_rmac")
        if [ -n "$_rstatic" ]; then
            _rcfgnet=$(( $(ip2int "$GATEWAY") & $(pfx2mask_int "$PREFIX") ))
            _reff=$(map_ip "$_rstatic" "$_rcfgnet" "$_rnet" "$_rsize") || _reff=""
            [ -n "$_reff" ] && [ "$_rip" = "$_reff" ] && continue
        fi
        # Delete only definite mismatches: a bound MAC at the wrong address, or a client
        # holding the system placeholder. Leave dynamic clients at ordinary addresses.
        if [ "$_rip" = "$_rp" ] || [ -n "$_rstatic" ]; then
            $IPB neigh del "$_rip" dev "$_ri" 2>/dev/null || true
            log "DHCP: client $_rmac at $_rip will re-acquire (bound=${_rstatic:-dynamic}, placeholder=$_rp)"
        fi
    done
    rm -f "$_tmp"
}

# The kernel keeps a stale ARP entry for the system placeholder after the client has
# already moved to its udhcpd-assigned address. Remove it when the client is currently
# reachable at a different address, so `clients` doesn't show the obsolete IP.
dhcp_drop_stale_placeholder() { # iface gateway/prefix placeholder
    _si=$1; _sa=$2; _sp=$3
    [ -n "$_si" ] && [ -n "$_sa" ] && [ -n "$_sp" ] || return 0
    _smac=$($IPB -4 neigh show dev "$_si" 2>/dev/null | awk -v want="$_sp" '
        $1 == want && /lladdr/ { for (i = 2; i <= NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')
    [ -n "$_smac" ] && is_mac "$_smac" || return 0
    # If this MAC is also at a real/static address, the placeholder entry is stale.
    _live=$($IPB -4 neigh show dev "$_si" 2>/dev/null | awk -v m="$(lc "$_smac")" -v p="$_sp" '
        /lladdr/ {
            ip = $1; mac = ""
            for (i = 2; i <= NF; i++) if ($i == "lladdr") mac = tolower($(i + 1))
            if (mac == m && ip != p) found = 1
        }
        END { exit !found }')
    [ "$_live" = 1 ] || return 0
    $IPB neigh del "$_sp" dev "$_si" 2>/dev/null || true
    log "DHCP: removed stale placeholder $_sp for $_smac (client has a current address)"
}

lease_ip_for_mac() { # mac -> configured static IP or empty
    [ -f "$LEASES" ] || return 0
    _lm=$(lc "$1")
    awk -v m="$_lm" 'tolower($1) == m { print $2; exit }' "$LEASES" 2>/dev/null
}
# Writes $RUN/udhcpd.conf for iface $1 with addr $2 (ip/prefix). Echo summary.
# Static reservations are always inside the configured single subnet. When the platform
# ignored the gateway request they keep the host part via map_ip().
dhcp_write_conf() {
    _if=$1; _gw=${2%/*}; _pf=${2#*/}
    _mask=$(pfx2mask_int "$_pf")
    _net=$(( $(ip2int "$_gw") & _mask ))
    _size=$(( 1 << (32 - _pf) ))
    _cfgmask=$(pfx2mask_int "$PREFIX")
    _cfgnet=$(( $(ip2int "$GATEWAY") & _cfgmask ))
    _s=$(map_ip "$DHCP_START" "$_cfgnet" "$_net" "$_size")
    _e=$(map_ip "$DHCP_END" "$_cfgnet" "$_net" "$_size")
    if [ -z "$_s" ] || [ -z "$_e" ] || [ "$(ip2int "$_s")" -gt "$(ip2int "$_e")" ]; then
        _lo=100; _hi=200
        [ "$_size" -le 256 ] && { _lo=$(( _size / 4 )); _hi=$(( _size - 3 )); }
        _s=$(int2ip $(( _net + _lo ))); _e=$(int2ip $(( _net + _hi )))
        log "DHCP range from config not usable in $(int2ip $_net)/$_pf, using $_s-$_e"
    fi
    [ "$_net" != "$_cfgnet" ] && log "WARN: actual subnet $(int2ip $_net)/$_pf != configured $(int2ip $_cfgnet)/$PREFIX; static leases mapped by host part"
    _dns=$DNS; [ -n "$_dns" ] || _dns=$_gw
    _max=$(( $(ip2int "$_e") - $(ip2int "$_s") + 1 + 32 ))
    _static=$RUN/static.leases.$$
    _reserved=$RUN/reserved.ips.$$
    : > "$_static"
    : > "$_reserved"
    if [ -f "$LEASES" ]; then
        while read -r _mac _ip _rest; do
            case "$_mac" in ''|'#'*) continue ;; esac
            _vl=$(lease_validate_line "$_mac" "$_ip" "$_rest") || { log "static lease invalid: $_vl"; continue; }
            _mac=${_vl%% *}
            _ip=${_vl#* }; _ip=${_ip%% *}
            _mip=$(map_ip "$_ip" "$_cfgnet" "$_net" "$_size") || { log "static lease $_mac $_ip skipped (outside subnet)"; continue; }
            [ "$_mip" = "$_gw" ] && continue
            if grep -qx "$_mip" "$_reserved" || grep -q "^$_mip " "$_reserved"; then
                log "ERROR: static lease IP collision on mapped address $_mip (MAC $_mac); entry skipped"
                continue
            fi
            _sstart=$(ip2int "$_s"); _send=$(ip2int "$_e"); _sip=$(ip2int "$_mip")
            [ "$_sip" -ge "$_sstart" ] && [ "$_sip" -le "$_send" ] && echo "reserve $_mip" >> "$_reserved"
            echo "static_lease $_mac $_mip" >> "$_static"
        done < "$LEASES"
    fi
    {
        echo "# generated by hotspot_plus $(date)"
        echo "interface $_if"
        echo "start $_s"
        echo "end $_e"
        echo "max_leases $_max"
        echo "lease_file $LEASE_DB"
        echo "pidfile $RUN/udhcpd.pid"
        echo "auto_time 30"
        echo "decline_time 600"
        echo "conflict_time 600"
        echo "offer_time 60"
        echo "min_lease 120"
        echo "opt subnet $(int2ip "$_mask")"
        echo "opt router $_gw"
        echo "opt dns $(echo "$_dns" | tr ',' ' ')"
        echo "opt broadcast $(int2ip $(( _net + _size - 1 )))"
        echo "opt lease $LEASE_TIME"
        # Android vendor option 43 "ANDROID_METERED" (same as Android's own DhcpServer/dnsmasq)
        [ "$METERED" = 1 ] && echo "opt 43 414e44524f49445f4d455445524544"
        cat "$_static"
    } > "$RUN/udhcpd.conf"
    rm -f "$_static" "$_reserved"
    DHCP_SUMMARY="$_if $_s-$_e gw=$_gw dns=$_dns"
}

# Remove dynamic lease records that now collide with a static reservation. This prevents a
# client's old address from being offered to another MAC after a rebind. The daemon owns
# lease writes; callers stop it before invoking this so it cannot rewrite the file in place.
lease_scrub_conflicts() { # [lease-file ...]
    [ -f "$LEASE_DB" ] || return 0
    [ -n "$(dhcp_pid 2>/dev/null)" ] && dhcp_stop 2>/dev/null
    _res=$RUN/static.reserved.$$
    : > "$_res"
    for _lf in "${@:-$LEASES}"; do
        [ -f "$_lf" ] || continue
        while read -r _smac _sip _rest; do
            case "$_smac" in ''|'#'*|Mac) continue ;; esac
            _sv=$(lease_validate_line "$_smac" "$_sip" "${_rest:-}") || continue
            _sv_ip=${_sv#* }; _sv_ip=${_sv_ip%% *}
            echo "$_sv_ip" >> "$_res"
        done < "$_lf"
    done
    [ -s "$_res" ] || { rm -f "$_res"; return 0; }
    _tmp=$LEASE_DB.scrub.$$
    awk -v reserved="$(tr '\n' ' ' < "$_res")" '
        BEGIN { n = split(reserved, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
        NR == 1 { print; next }
        {
            ip = ($2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ? $2 : substr($0, 19, 16)
            gsub(/^ +| +$/, "", ip)
            if (ip in skip) next
        }
        { print }
    ' "$LEASE_DB" > "$_tmp"
    _before=$(wc -l < "$LEASE_DB" 2>/dev/null || echo 0)
    _after=$(wc -l < "$_tmp" 2>/dev/null || echo 0)
    mv -f "$_tmp" "$LEASE_DB"
    rm -f "$_res"
    if [ $((_before - _after)) -gt 0 ]; then
        log "lease scrub: removed $((_before - _after)) stale lease(s) that collide with static reservations"
    fi
    return 0
}
dhcp_start() {
    _if=$1; _addr=$2
    dhcp_stop
    if ! bb_has udhcpd; then log "ERROR: busybox udhcpd not available ($BB)"; return 1; fi
    dhcp_write_conf "$_if" "$_addr"
    touch "$LEASE_DB"
    # setsid so it survives the caller (WebUI exec / action) exiting
    setsid "$BB" udhcpd -f "$RUN/udhcpd.conf" >> "$LOGDIR/udhcpd.log" 2>&1 < /dev/null 9>&- 3>&- &
    echo $! > "$RUN/udhcpd.pid"
    sleep 1
    if dhcp_running; then
        log "udhcpd started: $DHCP_SUMMARY (pid $(dhcp_pid))"
        return 0
    fi
    # A single sample can be a false negative under load (udhcpd still exec'ing).
    # Re-check briefly before spending a retry from the session budget.
    _ds_i=0
    while [ "$_ds_i" -lt 10 ]; do
        sleep 0.1
        if dhcp_running; then
            log "udhcpd started after grace: $DHCP_SUMMARY (pid $(dhcp_pid))"
            return 0
        fi
        _ds_i=$((_ds_i + 1))
    done
    log "ERROR: udhcpd exited immediately, see $LOGDIR/udhcpd.log"
    tail -n 5 "$LOGDIR/udhcpd.log" 2>/dev/null | while read -r _l; do log "  udhcpd: $_l"; done
    rm -f "$RUN/udhcpd.pid"
    return 1
}

# Can we run our own DHCP (needed for static leases and for the fixed-gateway request)?
dhcp_capable() {
    [ "$DHCP_ENABLE" = 1 ] || return 1
    bb_has udhcpd || return 1
    if [ ! -f "$RUN/fw_ok" ]; then
        if fw_supported; then echo 1 > "$RUN/fw_ok"; else echo 0 > "$RUN/fw_ok"; fi
    fi
    [ "$(cat "$RUN/fw_ok")" = 1 ]
}

# ---------------------------------------------------------------- daemon
daemon_pid() {
    _p=$(cat "$RUN/hspd.pid" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && grep -q hspd "/proc/$_p/cmdline" 2>/dev/null && echo "$_p"
}
daemon_pids() { # every live hspd process, not just the pidfile owner
    for _dp in /proc/[0-9]*; do
        _dp=${_dp#/proc/}
        [ -r "/proc/$_dp/comm" ] || continue
        [ "$(cat "/proc/$_dp/comm" 2>/dev/null)" = "busybox" ] || continue
        tr '\000' '|' < "/proc/$_dp/cmdline" 2>/dev/null | grep -q 'modules/hotspot_plus/bin/hspd' && echo "$_dp"
    done
}
daemon_wake() {
    # daemon keeps the FIFO open read+write, so this never blocks while it runs
    [ -n "$(daemon_pid)" ] && [ -p "$RUN/ev" ] && tmo 2 "daemon_wake" sh -c "echo '$1' > '$RUN/ev'" 2>/dev/null
    return 0
}

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }

# ---------------------------------------------------------------- operation lock
# fd 9 = $LOCKF (flock). Holder info in $HOLDF: "<pid> <op> <epoch>".
# Fallback (no usable flock): mkdir $LOCKD. Stale detection: holder dead, or held > LOCK_MAX_AGE.
LOCKF=$RUN/op.lock
HOLDF=$RUN/op.holder
LOCKD=$RUN/op.lockdir
LOCK_MAX_AGE=${LOCK_MAX_AGE:-240}
LOCK_WAIT=${LOCK_WAIT:-90}
LOCK_MODE=""

proc_alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
cmdline_of() { tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline"; }

# Print "pid fd cmdline" for every process holding op.lock open (excluding us and our subshells).
# One bounded `ls -l` over all fd dirs + awk (no per-fd forks: that was very slow on Android).
lock_fd_holders() {
    # shellcheck disable=SC2010
    tmo 10 "op.lock fd scan" ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v me="$$" '
        /^\/proc\/[0-9]+\/fd:$/ { split($0, a, "/"); pid = a[3]; next }
        /op\.lock/ && pid != me && !seen[pid]++ { print pid, $(NF-2) }' |
    while read -r _hp _hfd; do
        [ "$(awk '/^PPid:/{print $2}' "/proc/$_hp/status" 2>/dev/null)" = "$$" ] && continue
        _hc=$(cmdline_of "$_hp")
        # skip vanished processes and our own forked subshells (same cmdline as us)
        [ -n "$_hc" ] || continue
        [ "$_hc" = "$(cmdline_of $$)" ] && continue
        echo "$_hp $_hfd $_hc"
    done
}

lock_holder_info() { # sets H_PID H_OP H_AGE (empty if unknown)
    H_PID=""; H_OP=""; H_AGE=""
    [ -f "$HOLDF" ] || return 1
    read -r H_PID H_OP _hts < "$HOLDF" 2>/dev/null
    [ -n "$_hts" ] && H_AGE=$(( $(date +%s) - _hts ))
    return 0
}

# Is the op lock currently held by someone? (non-destructive probe)
lock_busy() {
    if [ -n "$FLOCK_BIN" ] && [ -f "$LOCKF" ]; then
        # subshell: take+release immediately; rc 1 and no stderr == busy
        _lb=$( (exec 8>>"$LOCKF"; $FLOCK_BIN -n 8 2>&1 9>&-) ); _lrc=$?
        [ $_lrc -ne 0 ] && [ -z "$_lb" ] && return 0
    fi
    [ -d "$LOCKD" ] && { lock_holder_info; proc_alive "$H_PID" && return 0; }
    return 1
}

lock_break() { # reason
    log "LOCK: breaking stale lock ($1). holder file: $(cat "$HOLDF" 2>/dev/null)"
    lock_fd_holders | while read -r _l; do log "LOCK:   fd holder: $_l"; done
    rm -f "$LOCKF" "$HOLDF"
    rmdir "$LOCKD" 2>/dev/null
    # our own fd 9 points to the old inode; reopen on the fresh file
    exec 9>&-
    exec 9>>"$LOCKF"
}

lock_release() {
    if [ -n "$LOCK_MODE" ]; then
        _rp=""; [ -f "$HOLDF" ] && read -r _rp _x < "$HOLDF"
        [ "$_rp" = "$$" ] && rm -f "$HOLDF"
        [ "$LOCK_MODE" = mkdir ] && rmdir "$LOCKD" 2>/dev/null
        LOCK_MODE=""
    fi
}

# lock <opname>: wait up to LOCK_WAIT seconds; exits 1 with a clear message on failure.
lock() {
    _op=${1:-op}
    log "op '$_op' requested (pid $$ ppid $PPID)"
    exec 9>>"$LOCKF"
    _t0=$(date +%s); _breaks=0; _mode=flock
    [ -n "$FLOCK_BIN" ] || _mode="mkdir"
    while :; do
        if [ "$_mode" = flock ]; then
            _ferr=$($FLOCK_BIN -n 9 2>&1); _frc=$?
            [ $_frc -eq 0 ] && break
            if [ -n "$_ferr" ]; then
                log "LOCK: flock failed abnormally rc=$_frc: $(echo "$_ferr" | head -n 2 | tr '\n' ' '); using mkdir lock"
                _mode="mkdir"; continue
            fi
        else
            mkdir "$LOCKD" 2>/dev/null && break
        fi
        lock_holder_info
        _now=$(date +%s)
        if [ $_breaks -lt 2 ]; then
            if [ -n "$H_PID" ] && ! proc_alive "$H_PID"; then
                _breaks=$((_breaks+1)); lock_break "holder pid $H_PID ($H_OP) is dead"; continue
            fi
            if [ -n "$H_AGE" ] && [ "$H_AGE" -gt "$LOCK_MAX_AGE" ]; then
                _breaks=$((_breaks+1)); lock_break "holder pid $H_PID ($H_OP) held ${H_AGE}s > ${LOCK_MAX_AGE}s"; continue
            fi
            if [ -z "$H_PID" ] && [ $(( _now - _t0 )) -ge 10 ]; then
                _breaks=$((_breaks+1)); lock_break "no holder info after 10s (fd inherited by a child?)"; continue
            fi
        fi
        if [ $(( _now - _t0 )) -ge "$LOCK_WAIT" ]; then
            say "另一个操作正在进行：${H_OP:-未知} (pid ${H_PID:-?}, 已 ${H_AGE:-?}s)。可在 WebUI 点「清除卡住的操作」"
            lock_fd_holders | while read -r _l; do log "LOCK:   fd holder: $_l"; done
            exit 1
        fi
        sleep 1
    done
    LOCK_MODE=$_mode
    echo "$$ $_op $(date +%s)" > "$HOLDF"
    trap 'lock_release' EXIT
    trap 'exit 130' INT TERM
    log "op '$_op' lock acquired via $_mode (waited $(( $(date +%s) - _t0 ))s)"
}

# Kill stuck operations and remove the lock (WebUI "清除卡住的操作").
# Matching is done on exact argv elements (not substrings) so unrelated shells whose command
# text merely mentions "hsp on" are never touched.
is_hsp_op_argv() { # argv lines on stdin -> 0 if "<sh> .../bin/hsp <op>" or ".../bin/hsp <op>"
    _i=0; _prev=""
    while IFS= read -r _arg; do
        _i=$((_i+1)); [ $_i -gt 6 ] && break
        case "$_prev" in
            */bin/hsp) case "$_arg" in on|off|toggle|restart|apply|start|stop) return 0 ;; esac ;;
        esac
        _prev=$_arg
    done
    return 1
}
is_hsctl_argv() {
    _first=1
    while IFS= read -r _arg; do
        if [ $_first = 1 ]; then
            _first=0
            [ "$_arg" = hsctl ] && return 0
            case "${_arg##*/}" in app_process|app_process64|app_process32|env|timeout|busybox|sh) ;; *) return 1 ;; esac
        fi
        [ "$_arg" = com.hsp.HsCtl ] && return 0
    done
    return 1
}
unstick() {
    _me=$$; _killed=""
    log "UNSTICK requested (pid $_me ppid $PPID); holder: $(cat "$HOLDF" 2>/dev/null)"
    # candidates via one bounded grep over all cmdlines, then exact argv checks
    for _pd in $(tmo 10 "unstick scan" grep -l -a -E 'hsctl|com\.hsp\.HsCtl|bin/hsp' /proc/[0-9]*/cmdline 2>/dev/null | sed 's,/cmdline$,,'); do
        _p=${_pd#/proc/}
        if [ "$_p" = "$_me" ] || [ "$_p" = "$PPID" ]; then continue; fi
        [ "$(awk '/^PPid:/{print $2}' "$_pd/status" 2>/dev/null)" = "$_me" ] && continue
        if tr '\000' '\n' 2>/dev/null < "$_pd/cmdline" | is_hsctl_argv; then
            kill -9 "$_p" 2>/dev/null && _killed="$_killed $_p(hsctl)"
        elif tr '\000' '\n' 2>/dev/null < "$_pd/cmdline" | is_hsp_op_argv; then
            kill -9 "$_p" 2>/dev/null && _killed="$_killed $_p(hsp)"
        fi
    done
    # anything else still holding op.lock (e.g. a child that inherited fd 9 in v0.1.0)
    for _l in $(lock_fd_holders | awk '{print $1}' | sort -u); do
        [ "$_l" = "$_me" ] && continue
        _c=$(cmdline_of "$_l")
        case "$_c" in *hspd*) continue ;; esac   # never kill the daemon here
        kill "$_l" 2>/dev/null && _killed="$_killed $_l(fd:${_c%% *})"
    done
    rm -f "$LOCKF" "$HOLDF" "$RUN"/hsctl.*.out; rmdir "$LOCKD" 2>/dev/null
    log "UNSTICK done; killed:${_killed:- none}"
    echo "已清除操作锁；结束的进程:${_killed:- 无}"
}
