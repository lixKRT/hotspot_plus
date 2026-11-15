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
LEASE_IMPORT=$MODDIR/webroot/lease-import.conf
LEASE_DB=$DATA/udhcpd.leases
STATE=$RUN/state
HSCTL_JAR=$MODDIR/bin/hsctl.jar
FW_CHAIN=hsp_dhcp

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
    ENFORCE_GATEWAY=1
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
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    _o=$1
    for _i in 1 2 3 4; do
        _v=${_o%%.*}; _o=${_o#*.}
        [ "$_v" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}
is_mac() { echo "$1" | tr '-' ':' | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
lc() { echo "$1" | tr 'A-F' 'a-f' | tr '-' ':'; }
ip2int() {
    _a=${1%%.*}; _r=${1#*.}; _b=${_r%%.*}; _r=${_r#*.}; _c=${_r%%.*}; _d=${_r#*.}
    echo $(( (_a << 24) + (_b << 16) + (_c << 8) + _d ))
}
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
pfx2mask_int() { echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); }
pfx2mask() { int2ip "$(pfx2mask_int "$1")"; }

# Map an address configured in the "configured" subnet onto the actual subnet (keeps host part).
# usage: map_ip <ip> <cfg_net_int> <act_net_int> <act_size>
map_ip() {
    is_ipv4 "$1" || return 1
    _off=$(( $(ip2int "$1") - $2 ))
    [ "$_off" -gt 0 ] && [ "$_off" -lt $(( $4 - 1 )) ] || return 1
    int2ip $(( $3 + _off ))
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
fw_del() {
    _n=0
    while ipt -D OUTPUT -j $FW_CHAIN 2>/dev/null; do _n=$((_n+1)); [ $_n -gt 5 ] && break; done
    ipt -F $FW_CHAIN 2>/dev/null
    ipt -X $FW_CHAIN 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- udhcpd
dhcp_pid() {
    _p=$(cat "$RUN/udhcpd.pid" 2>/dev/null)
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && grep -q udhcpd "/proc/$_p/cmdline" 2>/dev/null && echo "$_p"
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
# Writes $RUN/udhcpd.conf for iface $1 with addr $2 (ip/prefix). Echo summary.
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
        if [ -f "$LEASES" ]; then
            while read -r _mac _ip _rest; do
                case "$_mac" in ''|'#'*) continue ;; esac
                is_mac "$_mac" || continue
                _mip=$(map_ip "$_ip" "$_cfgnet" "$_net" "$_size") || { log "static lease $_mac $_ip skipped (outside subnet)"; continue; }
                [ "$_mip" = "$_gw" ] && continue
                echo "static_lease $(lc "$_mac") $_mip"
            done < "$LEASES"
        fi
    } > "$RUN/udhcpd.conf"
    DHCP_SUMMARY="$_if $_s-$_e gw=$_gw dns=$_dns"
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
    rm -f "$LOCKF" "$HOLDF" "$RUN"/hsctl.*.out "$RUN/started_by_hsp"; rmdir "$LOCKD" 2>/dev/null
    log "UNSTICK done; killed:${_killed:- none}"
    echo "已清除操作锁；结束的进程:${_killed:- 无}"
}
