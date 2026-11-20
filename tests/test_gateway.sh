#!/bin/sh
# Offline fixed-gateway policy checks (ADR-0003/0007). Temporary MODDIR/HSP_DATA,
# fake hsctl + gateway observations, no device and no real hotspot.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

_gw_env() { # name -> temp MODDIR + DATA
    _gw=$TMPROOT/gateway-$1
    rm -rf "$_gw"
    mkdir -p "$_gw/mod/bin" "$_gw/mod/lib" "$_gw/mod/defaults" \
        "$_gw/data/run" "$_gw/data/logs" "$_gw/fake"
    cp "$ROOT/bin/hsp" "$ROOT/bin/hspd" "$_gw/mod/bin/"
    cp "$ROOT/lib/common.sh" "$_gw/mod/lib/"
    cp "$ROOT/module.prop" "$_gw/mod/"
    cp "$ROOT/defaults/"* "$_gw/mod/defaults/"
    cp "$ROOT/bin/hsctl.jar" "$_gw/mod/bin/hsctl.jar" 2>/dev/null
}

# Fake device surface. AP_STATE_FILE holds the gateway address (e.g. 192.168.42.1/24)
# or is absent when the hotspot is off; NEXT_GW_FILE changes it on the next hsctl start.
_gw_fakes() {
    cat > "$_gw/fake/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-o addr show"*) [ -s "$AP_STATE_FILE" ] && printf '3: wlan2    inet %s scope global wlan2\n' "$(cat "$AP_STATE_FILE")" ;;
    *"route show"*) : ;;
esac
exit 0
EOF
    cat > "$_gw/fake/iptables" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$_gw/fake/busybox" <<'EOF'
#!/bin/sh
[ "$1" = --list ] && printf 'udhcpd\nflock\n'
exit 0
EOF
    cat > "$_gw/fake/getprop" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$_gw/fake/app_process" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "com.hsp.HsCtl" ]; do shift; done
[ $# -gt 0 ] && shift
_sub=$1; [ $# -gt 0 ] && shift
printf '%s %s\n' "$_sub" "$*" >> "$HSCTL_LOG"
case "$_sub" in
    start)
        if [ -f "$NEXT_GW_FILE" ]; then cat "$NEXT_GW_FILE" > "$AP_STATE_FILE"; else cat "$DEFAULT_GW_FILE" > "$AP_STATE_FILE"; fi
        printf '%s\n' "start_result=SUCCESS" ;;
    stop)
        : > "$AP_STATE_FILE"
        printf '%s\n' "stop_result=SUCCESS" ;;
    state) printf '%s\n' "ap_state=2" ;;
esac
exit 0
EOF
    chmod +x "$_gw/fake/ip" "$_gw/fake/iptables" "$_gw/fake/getprop" \
        "$_gw/fake/app_process" "$_gw/fake/busybox"
}

_gw_config() { # gateway prefix fixed enforce
    cat > "$_gw/data/config.conf" <<EOF
FIXED_GATEWAY="$3"
ENFORCE_GATEWAY="$4"
GATEWAY="$1"
PREFIX="$2"
DHCP_ENABLE="${HSP_TEST_DHCP:-1}"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
AP_IFACE="wlan2"
AUTO_START="0"
FALLBACK_SSID=""
FALLBACK_PASS=""
EOF
}

_gw_run() { # [delay_sim ...] -- hsp args
    _envs=
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    [ "$1" = "--" ] && shift
    # shellcheck disable=SC2086
    env PATH="$_gw/fake:$PATH" MODDIR="$_gw/mod" HSP_DATA="$_gw/data" HSP_APP_PROCESS="$_gw/fake/app_process" \
        IPB="$_gw/fake/ip" IPT="$_gw/fake/iptables" HSP_BUSYBOX="$_gw/fake/busybox" \
        HSP_GW_NO_SPAWN=1 \
        GS="$_gw/data/run" HSCTL_LOG="$_gw/hsctl.log" \
        AP_STATE_FILE="$_gw/ap" NEXT_GW_FILE="$_gw/next" DEFAULT_GW_FILE="$_gw/default" \
        $_envs sh "$_gw/mod/bin/hsp" "$@"
}

_gw_status() { _gw_run -- status --json; }

_jq() { # json expression
    "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d, "json": json}))' "$1"
}

_restarts() {
    [ -f "$_gw/hsctl.log" ] && grep -c '^start ' "$_gw/hsctl.log" || echo 0
}

_gw_state() { # key
    sed -n "s/^$1=//p" "$_gw/data/run/gateway" 2>/dev/null | tail -n1
}

_gw_summary() { # key
    sed -n "s/^$1=//p" "$_gw/data/run/state" 2>/dev/null | tail -n1
}

# ------------------------------------------------------------------ policy matrix
gateway_validation_matrix() {
    . "$ROOT/lib/common.sh"
    gateway_addr_valid 192.168.42.1 24 &&
        gateway_addr_valid 10.20.30.1 24 &&
        gateway_addr_valid 172.16.5.1 16 &&
        gateway_addr_valid 192.168.42.129 25 &&
        ! gateway_addr_valid 192.168.42.0 24 &&
        ! gateway_addr_valid 192.168.42.255 24 &&
        ! gateway_addr_valid 8.8.8.8 24 &&
        ! gateway_addr_valid 10.0.0.1 8 &&
        ! gateway_addr_valid 192.168.42.1 15 &&
        ! gateway_addr_valid 192.168.42.1 29 &&
        ! gateway_addr_valid 192.168.42.1 "" &&
        ! gateway_addr_valid 192.168.42 24
}

default_gateway_is_42_1() {
    . "$ROOT/lib/common.sh"
    unset GATEWAY PREFIX
    config_defaults
    [ "$GATEWAY/$PREFIX" = "192.168.42.1/24" ] &&
        grep -q '^GATEWAY="192.168.42.1"$' "$ROOT/defaults/config.conf"
}

gateway_repair_plan_matrix() {
    . "$ROOT/lib/common.sh"
    [ "$(gateway_repair_plan module 0)" = "restart 5" ] &&
        [ "$(gateway_repair_plan module 1)" = "restart 15" ] &&
        [ "$(gateway_repair_plan module 2)" = "degrade 0" ] &&
        [ "$(gateway_repair_plan module 3)" = "degrade 0" ] &&
        [ "$(gateway_repair_plan system 0)" = "restart 0" ] &&
        [ "$(gateway_repair_plan system 1)" = "degrade 0" ] &&
        [ "$(gateway_repair_plan none 0)" = "degrade 0" ]
}

invalid_config_falls_back_to_default() {
    _gw_env fallback || return 1
    _gw_fakes
    printf 'GATEWAY="8.8.8.8"\nPREFIX="24"\nDHCP_START="8.8.8.100"\nDHCP_END="8.8.8.200"\n' > "$_gw/data/config.conf"
    _s=$(_gw_status) || return 1
    [ "$(printf '%s' "$_s" | _jq 'd["gateway_cfg"]')" = 192.168.42.1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["prefix_cfg"]')" = 24 ] &&
        grep -q 'invalid GATEWAY/PREFIX' "$_gw/data/logs/hsp.log"
}

set_rejects_non_private_gateway() {
    _gw_env set-public || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    _out=$(_gw_run -- set GATEWAY=8.8.8.8) && return 1
    printf '%s' "$_out" | grep -q '私有网段' &&
        grep -q '^GATEWAY="192.168.42.1"$' "$_gw/data/config.conf"
}

set_rejects_network_and_broadcast() {
    _gw_env set-edge || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    _out=$(_gw_run -- set GATEWAY=192.168.42.0) && return 1
    printf '%s' "$_out" | grep -q '网络地址' || return 1
    _out=$(_gw_run -- set GATEWAY=192.168.42.255) && return 1
    printf '%s' "$_out" | grep -q '网络地址' || return 1
    _out=$(_gw_run -- set PREFIX=29) && return 1
    printf '%s' "$_out" | grep -q '16-28'
}

set_accepts_private_gateway() {
    _gw_env set-ok || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    _gw_run -- set GATEWAY=10.20.30.1 PREFIX=24 DHCP_START=10.20.30.100 DHCP_END=10.20.30.150 > "$_gw/out" 2>&1 || return 1
    grep -q '^GATEWAY="10.20.30.1"$' "$_gw/data/config.conf" &&
        grep -q '^PREFIX="24"$' "$_gw/data/config.conf"
}

# ------------------------------------------------------------------ module start
module_requests_gateway_and_accepts_it() {
    _gw_env module-ok || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.42.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_restarts)" = 1 ] &&
        grep -q '^start .*--static 192.168.42.1/24 192.168.42.254/24' "$_gw/hsctl.log" &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = ok ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_origin"]')" = module ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_final"]')" = 192.168.42.1/24 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = False ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_ok"]')" = True ]
}

module_start_waits_5s_before_first_retry() {
    _gw_env module-wait1 || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_restarts)" = 1 ] &&
        [ "$(_gw_state attempts)" = 0 ] &&
        [ "$(_gw_state result)" = waiting ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = waiting ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_next_in"]')" -le 5 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_next_in"]')" -ge 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_repair"]')" = False ] &&
        grep -q 'retry 1/2 in 5s' "$_gw/data/logs/hsp.log"
}

module_retry_uses_15s_then_degrades() {
    _gw_env module-budget || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1

    # first repair restart (5s wait is already recorded by the waiting state)
    _gw_repair || return 1
    [ "$(_gw_state attempts)" = 1 ] &&
        [ "$(_gw_state result)" = waiting ] &&
        [ "$(_gw_state next_at)" -le $(( $(date +%s) + 15 )) ] &&
        grep -q 'retry 2/2 in 15s' "$_gw/data/logs/hsp.log" || return 1

    # second repair restart -> budget exhausted, degrade for this session
    _gw_repair || return 1
    _s=$(_gw_status)
    [ "$(_gw_state degraded)" = 1 ] &&
        [ "$(_gw_state attempts)" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = degraded ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = True ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_final"]')" = 192.168.4.1/24 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["enforce_broken"]')" = True ] &&
        printf '%s' "$(_gw_state reason)" | grep -q 'retries exhausted' &&
        [ -f "$_gw/data/run/enforce_broken" ]
}

# Runs one repair restart the way the daemon would: advance the clock so the scheduled
# retry is due, then execute `hsp repair`.
_gw_repair() {
    # Advance the scheduled retry so the daemon tick fires, then run the repair it dispatches.
    # shellcheck disable=SC2034
    HSP_GW_NO_SPAWN=1 HSP_DATA="$_gw/data" MODDIR="$_gw/mod" \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; gw_tick $(( $(date +%s) + 60 )) "$(gw_get final_gw)"'
    _gw_run -- repair > "$_gw/repair.out" 2>&1
}

degraded_session_does_not_restart_again() {
    _gw_env degraded-loop || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _before=$(_restarts)
    # a repeat status/observation and a further repair request must not restart anything
    _gw_status > /dev/null
    _gw_run -- repair > "$_gw/repair2.out" 2>&1
    [ "$(_restarts)" = "$_before" ] &&
        grep -q 'without an active pending attempt' "$_gw/data/logs/hsp.log"
}

# ------------------------------------------------------------------ system start
system_start_gets_exactly_one_repair() {
    _gw_env system-one || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    # hotspot already up on another subnet, started by the system
    printf '192.168.43.1/24\n' > "$_gw/ap"
    printf '192.168.43.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(printf '%s' "$_s" | _jq 'd["gateway_origin"]')" = system ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 1 ] &&
        [ "$(_gw_state attempts)" = 1 ] &&
        [ "$(_gw_state pending)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_repair"]')" = True ] &&
        grep -q 'repair restart' "$_gw/data/logs/hsp.log" &&
        ! grep -q 'retry .* in 5s' "$_gw/data/logs/hsp.log"
}

system_mismatch_degrades_after_one_repair() {
    _gw_env system-degrade || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.43.1/24\n' > "$_gw/ap"
    printf '192.168.43.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _gw_run -- repair > "$_gw/repair.out" 2>&1
    _s=$(_gw_status)
    [ "$(_gw_state attempts)" = 1 ] &&
        [ "$(_gw_state degraded)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = True ] &&
        [ "$(_restarts)" = 1 ]
}

system_start_successful_repair_is_bounded() {
    _gw_env system-ok || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.43.1/24\n' > "$_gw/ap"
    printf '192.168.42.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _gw_run -- repair > "$_gw/repair.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_gw_state attempts)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = ok ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_final"]')" = 192.168.42.1/24 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_ok"]')" = True ] &&
        [ "$(_restarts)" = 1 ]
}

# ------------------------------------------------------------------ sessions
manual_off_on_starts_new_budget() {
    _gw_env session-reset || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _old=$(_gw_state session)

    _gw_run -- off > "$_gw/off.out" 2>&1 || return 1
    [ ! -f "$_gw/data/run/gateway" ] &&
        [ "$(_gw_summary gw_result)" = degraded ] &&
        [ "$(_gw_summary gw_attempts)" = 2 ] || return 1

    _gw_run -- on > "$_gw/on2.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = waiting ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = False ] &&
        [ "$(_gw_state session)" != "$_old" ] &&
        [ "$(_gw_state limit)" = 2 ]
}

manual_off_clears_repair_state() {
    _gw_env session-clear || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.42.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    [ -f "$_gw/data/run/gateway" ] || return 1
    _gw_run -- off > "$_gw/off.out" 2>&1 || return 1
    [ ! -f "$_gw/data/run/gateway" ] &&
        [ ! -f "$_gw/data/run/enforce_broken" ] &&
        [ "$(_gw_summary gw_result)" = ok ]
}

status_exposes_attempts_final_and_reason() {
    _gw_env status-fields || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _s=$(_gw_status) || return 1
    printf '%s' "$_s" | _jq 'json.dumps(d, sort_keys=True)' > /dev/null &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_final"]')" = 192.168.4.1/24 ] &&
        printf '%s' "$(printf '%s' "$_s" | _jq 'd["gateway_reason"]')" | grep -q 'mismatch' &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_matches_final"]')" = False ]
}

lifecycle_failure_releases_session() {
    _gw_env start-fail || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    # make start fail: no AP appears
    : > "$_gw/default"
    _gw_run HSP_START_WAIT=0 -- on > "$_gw/out" 2>&1 && return 1
    [ ! -f "$_gw/data/run/gateway" ] &&
        [ "$(_gw_summary gw_result)" = start_failed ] &&
        grep -q 'gateway: session end result=start_failed' "$_gw/data/logs/hsp.log"
}

config_change_does_not_expand_budget() {
    _gw_env no-expand || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _gw_run -- set DHCP_START=192.168.42.120 DHCP_END=192.168.42.210 > "$_gw/set.out" 2>&1 || return 1
    _gw_run -- status --json > /dev/null || return 1
    [ "$(_gw_state degraded)" = 1 ] &&
        [ "$(_gw_state attempts)" = 2 ] &&
        [ "$(_restarts)" = 3 ]
}

# Exhausted module budget, then a user `apply`: one manual restart is allowed, but it must
# not restore the repair allowance or start a new automatic repair loop.
apply_after_exhausted_budget_keeps_budget() {
    _gw_env apply-exhausted || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _before=$(_restarts)
    _gw_run -- apply > "$_gw/apply.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_restarts)" = $(( _before + 1 )) ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = True ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = degraded ] &&
        grep -q 'manual restart requested; keeping session budget' "$_gw/data/logs/hsp.log"
}

# Same for `restart`: it is not a new session, so attempts stay exhausted.
restart_after_exhausted_budget_keeps_budget() {
    _gw_env restart-exhausted || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _before=$(_restarts)
    _gw_run -- restart > "$_gw/restart.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_restarts)" = $(( _before + 1 )) ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_origin"]')" = module ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = True ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = degraded ]
}

# After apply/restart preserved the budget, only an explicit off -> on resets it.
explicit_off_on_after_apply_still_resets() {
    _gw_env apply-then-off-on || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _gw_repair || return 1
    _gw_repair || return 1
    _gw_run -- apply > "$_gw/apply.out" 2>&1 || return 1
    [ "$(_gw_state attempts)" = 2 ] || return 1
    _gw_run -- off > "$_gw/off.out" 2>&1 || return 1
    [ ! -f "$_gw/data/run/gateway" ] || return 1
    _gw_run -- on > "$_gw/on2.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 2 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = waiting ]
}

# Even a healthy session keeps its identity across `apply` (no new session, no extra attempts).
apply_on_healthy_session_does_not_open_new_session() {
    _gw_env apply-healthy || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.42.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _session=$(_gw_state session)
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- set DHCP_START=192.168.42.120 DHCP_END=192.168.42.210 > "$_gw/set.out" 2>&1 || return 1
    _gw_run -- apply > "$_gw/apply.out" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_gw_state session)" = "$_session" ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_origin"]')" = module ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = False ] &&
        [ "$(grep -c 'gateway: session begin' "$_gw/data/logs/hsp.log")" = 1 ]
}

# A system start whose one repair failed must stay degraded; it must not inherit the
# module-start retry allowance (no second restart, no 5s/15s retries).
failed_system_repair_does_not_gain_module_allowance() {
    _gw_env system-no-upgrade || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.43.1/24\n' > "$_gw/ap"
    printf '192.168.43.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    _gw_run -- repair > "$_gw/repair.out" 2>&1
    [ "$(_gw_state degraded)" = 1 ] || return 1
    _before=$(_restarts)
    # A later `on` (idempotent), `apply` and a stray repair request must all stay bounded.
    _gw_run -- on > "$_gw/on2.out" 2>&1 || return 1
    _gw_run -- apply > "$_gw/apply.out" 2>&1 || return 1
    _gw_run -- repair > "$_gw/repair2.out" 2>&1
    _s=$(_gw_status)
    [ "$(printf '%s' "$_s" | _jq 'd["gateway_origin"]')" = system ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_limit"]')" = 1 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_degraded"]')" = True ] &&
        [ "$(_restarts)" -le $(( _before + 1 )) ] &&
        ! grep -q 'retry .* in 5s\|retry .* in 15s' "$_gw/data/logs/hsp.log"
}

daemon_has_one_repair_owner() {
    ! grep -q 'started_by_hsp\|last_enforce\|enforce_pending' "$ROOT/bin/hspd" &&
        grep -q 'gw_observe' "$ROOT/bin/hspd" &&
        grep -q 'gw_session_down' "$ROOT/bin/hspd" &&
        ! grep -q 'started_by_hsp' "$ROOT/bin/hsp" &&
        grep -q 'bin/hsp" repair' "$ROOT/lib/common.sh"
}

repeat_on_while_waiting_does_not_stack_restarts() {
    _gw_env repeat-on || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.4.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out0" 2>&1 || return 1
    _before=$(_restarts)
    _gw_run -- on > "$_gw/out1" 2>&1 || return 1
    _gw_run -- on > "$_gw/out2" 2>&1 || return 1
    _s=$(_gw_status)
    [ "$(_restarts)" = "$_before" ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_attempts"]')" = 0 ] &&
        [ "$(printf '%s' "$_s" | _jq 'd["gateway_result"]')" = waiting ]
}

pending_repair_is_not_double_counted() {
    _gw_env pending-dup || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf '192.168.43.1/24\n' > "$_gw/ap"
    printf '192.168.43.1/24\n' > "$_gw/default"
    _gw_run -- on > "$_gw/out" 2>&1 || return 1
    [ "$(_gw_state attempts)" = 1 ] && [ "$(_gw_state pending)" = 1 ] || return 1
    _before=$(_restarts)
    # a second observation while the restart is in flight must not start another attempt
    HSP_DATA="$_gw/data" MODDIR="$_gw/mod" HSP_GW_NO_SPAWN=1 \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; AP_IF=wlan2; AP_ADDR=192.168.43.1/24; gw_observe "$AP_IF" "$AP_ADDR"'
    [ "$(_gw_state attempts)" = 1 ] && [ "$(_restarts)" = "$_before" ] &&
        grep -q 'repair restart in progress' "$_gw/data/logs/hsp.log"
}

daemon_clears_stale_pending_on_start() {
    _gw_env daemon-start || return 1
    _gw_fakes
    _gw_config 192.168.42.1 24 1 1
    printf 'active=1\norigin=module\nattempts=1\nlimit=2\npending=1\nresult=repairing\n' \
        > "$_gw/data/run/gateway"
    HSP_DATA="$_gw/data" MODDIR="$_gw/mod" timeout 3 sh "$_gw/mod/bin/hspd" > "$_gw/hspd.out" 2>&1
    # the daemon records the reset in its log and keeps the attempt count (no fresh budget)
    grep -q 'daemon start' "$_gw/data/logs/hsp.log" &&
        [ "$(_gw_state attempts)" = 1 ]
}

ui_repair_text_is_chinese() {
    grep -q '网关修复' "$ROOT/webroot/index.html" &&
        grep -q '已降级' "$ROOT/webroot/index.html" &&
        grep -q '等待重试' "$ROOT/webroot/index.html" &&
        grep -q 'gateway_degraded' "$ROOT/webroot/index.html"
}

run_case "gateway validation matrix" gateway_validation_matrix
run_case "default gateway is 192.168.42.1/24" default_gateway_is_42_1
run_case "repair plan matrix (5s/15s, 1 system)" gateway_repair_plan_matrix
run_case "invalid config falls back to default" invalid_config_falls_back_to_default
run_case "set rejects non-private gateway" set_rejects_non_private_gateway
run_case "set rejects network/broadcast/prefix" set_rejects_network_and_broadcast
run_case "set accepts private gateway" set_accepts_private_gateway
run_case "module start requests and accepts gateway" module_requests_gateway_and_accepts_it
run_case "module mismatch waits 5s" module_start_waits_5s_before_first_retry
run_case "module retries 15s then degrades" module_retry_uses_15s_then_degrades
run_case "degraded session never restarts again" degraded_session_does_not_restart_again
run_case "system start gets one repair" system_start_gets_exactly_one_repair
run_case "system mismatch degrades after one repair" system_mismatch_degrades_after_one_repair
run_case "system successful repair is bounded" system_start_successful_repair_is_bounded
run_case "off/on grants a new bounded budget" manual_off_on_starts_new_budget
run_case "off clears repair state" manual_off_clears_repair_state
run_case "status exposes attempts/final/reason" status_exposes_attempts_final_and_reason
run_case "start failure releases the session" lifecycle_failure_releases_session
run_case "config change does not expand budget" config_change_does_not_expand_budget
run_case "apply after exhausted budget keeps budget" apply_after_exhausted_budget_keeps_budget
run_case "restart after exhausted budget keeps budget" restart_after_exhausted_budget_keeps_budget
run_case "explicit off/on after apply still resets" explicit_off_on_after_apply_still_resets
run_case "apply on healthy session keeps session" apply_on_healthy_session_does_not_open_new_session
run_case "failed system repair gains no module allowance" failed_system_repair_does_not_gain_module_allowance
run_case "daemon is the single repair owner" daemon_has_one_repair_owner
run_case "repeat on while waiting does not stack restarts" repeat_on_while_waiting_does_not_stack_restarts
run_case "pending repair is not double counted" pending_repair_is_not_double_counted
run_case "daemon start clears a stale pending flag" daemon_clears_stale_pending_on_start
run_case "UI repair text stays Chinese" ui_repair_text_is_chinese
