#!/bin/sh
# Offline AP-interface probe checks (ADR-0006). No device, no real hotspot:
# /sys/class/net is faked for both present and absent interfaces.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

_ifp_env() { # name
    _ip=$TMPROOT/iface-probe-$1
    rm -rf "$_ip"
    mkdir -p "$_ip/mod/bin" "$_ip/mod/lib" "$_ip/data/run" "$_ip/data/logs" \
        "$_ip/fake" "$_ip/sys/net/eth0"
    cp "$ROOT/bin/hsp" "$ROOT/bin/hspd" "$_ip/mod/bin/"
    cp "$ROOT/lib/common.sh" "$_ip/mod/lib/"
    cp "$ROOT/module.prop" "$_ip/mod/"
    printf '%s\n' \
        'FIXED_GATEWAY="0"' \
        'ENFORCE_GATEWAY="0"' \
        'GATEWAY="192.168.42.1"' \
        'PREFIX="24"' \
        'DHCP_ENABLE="1"' \
        'DHCP_START="192.168.42.100"' \
        'DHCP_END="192.168.42.200"' \
        'AP_IFACE="eth0"' \
        'AUTO_START="0"' \
        > "$_ip/data/config.conf"
    : > "$_ip/ap"
    _ifp_fakes
}

_ifp_fakes() {
    cat > "$_ip/fake/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-4 addr show dev"*) printf '%s\n' "3: eth0    inet 192.168.42.1/24 scope global eth0" ;;
    *"-4 -o addr show"*) [ -f "$AP_STATE_FILE" ] && printf '%s\n' "3: eth0    inet 192.168.42.1/24 scope global eth0" ;;
    *"tethering"*) [ -f "$AP_STATE_FILE" ] && printf '%s\n' "     - TetheredState" ;;
    *"route show"*) : ;;
esac
exit 0
EOF
    cat > "$_ip/fake/dumpsys" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DUMPSYS_LOG"
printf 'WifiService state:\n  mApInterfaceName: %s\n' "$(cat "$DUMPSYS_IFACE_FILE")"
EOF
    cat > "$_ip/fake/busybox" <<'EOF'
#!/bin/sh
case "$1" in
    --list) printf 'udhcpd\nflock\n' ;;
    timeout) shift; shift; exec "$@" ;;
    udhcpd) printf 'started %s\n' "$*" >> "$UDHCPD_LOG"; exec sleep 3600 ;;
esac
exit 0
EOF
    cat > "$_ip/fake/iptables" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IPT_LOG"
case "$*" in
    *"-C hsp_dhcp -o"*) exit 0 ;;
    *"-C OUTPUT -j"*) exit 0 ;;
esac
exit 0
EOF
    chmod +x "$_ip/fake/ip" "$_ip/fake/dumpsys" "$_ip/fake/busybox" "$_ip/fake/iptables"
}

_ifp_eval() { # shell body, with common.sh loaded and the fake /sys path bound
    env PATH="$_ip/fake:$PATH" MODDIR="$_ip/mod" HSP_DATA="$_ip/data" \
        IPB="$_ip/fake/ip" IPT="$_ip/fake/iptables" HSP_BUSYBOX="$_ip/fake/busybox" \
        HSP_FLOCK=: HSP_SYSFS_NET="$_ip/sys/net" \
        DUMPSYS_LOG="$_ip/dumpsys.log" DUMPSYS_IFACE_FILE="$_ip/dumpsys.iface" \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; '"$1"
}

_ifp_session_up() { # starts the real daemon and waits for its first session decision
    env PATH="$_ip/fake:$PATH" MODDIR="$_ip/mod" HSP_DATA="$_ip/data" \
        IPB="$_ip/fake/ip" IPT="$_ip/fake/iptables" HSP_BUSYBOX="$_ip/fake/busybox" \
        HSP_FLOCK=: HSP_SYSFS_NET="$_ip/sys/net" HSP_DHCP_READY_WAIT=0 \
        HSP_DHCP_PIDFILE_TRUST=1 AP_STATE_FILE="$_ip/ap" \
        DUMPSYS_LOG="$_ip/dumpsys.log" DUMPSYS_IFACE_FILE="$_ip/dumpsys.iface" \
        UDHCPD_LOG="$_ip/udhcpd.log" IPT_LOG="$_ip/iptables.log" \
        sh "$_ip/mod/bin/hspd" > "$_ip/daemon.out" 2>&1 9>&- 3>&- &
    _ifp_dpid=$!
    _ifp_i=0
    while [ "$_ifp_i" -lt 30 ]; do
        _ifp_state=$(sed -n 's/^state=//p' "$_ip/data/run/dhcp" 2>/dev/null | tail -n1)
        [ "$_ifp_state" = degraded ] && return 0
        [ "$_ifp_state" = serving ] && return 0
        sleep 0.1; _ifp_i=$((_ifp_i + 1))
    done
    return 1
}

_ifp_stop() {
    [ -n "${_ifp_dpid:-}" ] && kill "$_ifp_dpid" 2>/dev/null
    _ifp_i=0
    while [ -n "${_ifp_dpid:-}" ] && kill -0 "$_ifp_dpid" 2>/dev/null && [ "$_ifp_i" -lt 30 ]; do
        sleep 0.1; _ifp_i=$((_ifp_i + 1))
    done
    [ -n "${_ifp_dpid:-}" ] && kill -9 "$_ifp_dpid" 2>/dev/null
    _ifp_dpid=
    _ifp_udhcpd=$(cat "$_ip/data/run/udhcpd.pid" 2>/dev/null)
    [ -n "$_ifp_udhcpd" ] && kill "$_ifp_udhcpd" 2>/dev/null
    rm -f "$_ip/data/run/udhcpd.pid"
}

_ifp_wait_state() { # desired-state [tenths]
    _ifp_want=$1; _ifp_limit=${2:-50}; _ifp_i=0
    while [ "$_ifp_i" -lt "$_ifp_limit" ]; do
        _ifp_cur=$(sed -n 's/^state=//p' "$_ip/data/run/dhcp" 2>/dev/null | tail -n1)
        [ "$_ifp_cur" = "$_ifp_want" ] && return 0
        sleep 0.1; _ifp_i=$((_ifp_i + 1))
    done
    return 1
}

_ifp_calls() {
    if [ -f "$_ip/dumpsys.log" ]; then
        _ifp_n=$(grep -c '^wifi$' "$_ip/dumpsys.log" 2>/dev/null)
        echo "${_ifp_n:-0}"
    else
        echo 0
    fi
}

_ifp_probe() { # ap_iface seconds -> "probe=<rc>" plus a marker for either dumpsys answer
    _ifp_eval "wait_dhcp_ready $1 $2; _r=\$?; printf 'probe=%s\n' \"\$_r\"" > "$_ip/out" 2>&1
    cat "$_ip/dumpsys.iface" 2>/dev/null
    cat "$_ip/out"
}

iface_probe_eth0_succeeds() {
    _ifp_env eth0-ok || return 1
    printf 'eth0\n' > "$_ip/dumpsys.iface"
    _ifp_probe eth0 2 > "$_ip/result"
    grep -qx 'eth0' "$_ip/result" || return 1
    grep -q '^probe=0$' "$_ip/result" || return 1
    [ "$(_ifp_calls)" -le 1 ]
}

iface_probe_wrong_dumpsys_iface_fails() {
    _ifp_env eth0-wrong || return 1
    printf 'wlan2\n' > "$_ip/dumpsys.iface"
    _ifp_probe eth0 2 > "$_ip/result"
    grep -qx 'wlan2' "$_ip/result" || return 1
    grep -q '^probe=1$' "$_ip/result" || return 1
    [ "$(_ifp_calls)" -le 1 ]
}

iface_probe_missing_iface_fails_without_dumpsys() {
    _ifp_env eth0-missing || return 1
    printf 'eth0\n' > "$_ip/dumpsys.iface"
    _ifp_eval 'wait_dhcp_ready eth1 0' > "$_ip/out" 2>&1 && return 1
    [ "$(_ifp_calls)" = 0 ]
}

iface_probe_failure_degrades_via_state_machine() {
    _ifp_env degrade || return 1
    printf 'wlan2\n' > "$_ip/dumpsys.iface"
    _ifp_eval 'dhcp_session_begin
        wait_dhcp_ready eth0 0 || dhcp_degrade "AP 接口探测失败" "eth0 未就绪或 mApInterfaceName 不匹配"
        [ "$(dhcp_get degraded)" = 1 ]
        [ "$(dhcp_get reason)" = "AP 接口探测失败" ]
        [ "$(dhcp_get retry_available)" = 1 ]
        [ "$(dhcp_get state)" = degraded ]' > "$_ip/out" 2>&1 || return 1
    [ "$(sed -n 's/^dhcp_degraded=//p' "$_ip/data/run/state" | tail -n1)" = 1 ]
}

iface_probe_daemon_degrades_without_takeover() {
    _ifp_env daemon-degrade || return 1
    printf 'wlan2\n' > "$_ip/dumpsys.iface"
    _ifp_session_up || { _ifp_stop; return 1; }
    sleep 2
    _ok=1
    [ "$(sed -n 's/^state=//p' "$_ip/data/run/dhcp" | tail -n1)" = degraded ] || _ok=0
    [ "$(sed -n 's/^degraded=//p' "$_ip/data/run/dhcp" | tail -n1)" = 1 ] || _ok=0
    [ "$(sed -n 's/^retry_available=//p' "$_ip/data/run/dhcp" | tail -n1)" = 1 ] || _ok=0
    [ "$(_ifp_calls)" -le 1 ] || _ok=0
    [ ! -f "$_ip/udhcpd.log" ] || _ok=0
    ! grep -q -- '-A hsp_dhcp' "$_ip/iptables.log" 2>/dev/null || _ok=0
    _ifp_stop
    [ "$_ok" = 1 ]
}

iface_probe_failure_resets_for_next_session() {
    _ifp_env recovery || return 1
    printf 'wlan2\n' > "$_ip/dumpsys.iface"
    _ifp_session_up || { _ifp_stop; return 1; }
    sleep 2
    [ "$(sed -n 's/^state=//p' "$_ip/data/run/dhcp" | tail -n1)" = degraded ] || { _ifp_stop; return 1; }

    rm -f "$_ip/ap"
    printf 'down\n' > "$_ip/data/run/ev"
    _ifp_wait_state idle || { _ifp_stop; return 1; }

    printf 'eth0\n' > "$_ip/dumpsys.iface"
    : > "$_ip/ap"
    printf 'up\n' > "$_ip/data/run/ev"
    _ifp_wait_state serving 80 || { _ifp_stop; return 1; }

    _ok=1
    [ "$(sed -n 's/^serving=//p' "$_ip/data/run/dhcp" | tail -n1)" = 1 ] || _ok=0
    [ "$(sed -n 's/^degraded=//p' "$_ip/data/run/dhcp" | tail -n1)" = 0 ] || _ok=0
    [ "$(_ifp_calls)" = 2 ] || _ok=0
    [ -s "$_ip/udhcpd.log" ] || _ok=0
    grep -q -- '-A hsp_dhcp' "$_ip/iptables.log" || _ok=0
    _ifp_stop
    [ "$_ok" = 1 ]
}

run_case "iface probe: eth0 matches the reported interface" iface_probe_eth0_succeeds
run_case "iface probe: foreign dumpsys interface fails" iface_probe_wrong_dumpsys_iface_fails
run_case "iface probe: missing interface fails before dumpsys" iface_probe_missing_iface_fails_without_dumpsys
run_case "iface probe: failure enters degraded state" iface_probe_failure_degrades_via_state_machine
run_case "iface probe: daemon degrades without takeover" iface_probe_daemon_degrades_without_takeover
run_case "iface probe: next session probes again" iface_probe_failure_resets_for_next_session
