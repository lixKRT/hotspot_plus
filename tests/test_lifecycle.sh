#!/bin/sh
# Offline lifecycle and boot auto-start checks. Uses only a temporary HSP_DATA and fake binaries.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

_lifecycle_env() { # name -> prints temp dir
    _lt=$TMPROOT/lifecycle-$1
    rm -rf "$_lt"
    mkdir -p "$_lt/data" "$_lt/bin"
}

_lifecycle_fakes() {
    cat > "$_lt/bin/getprop" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GETPROP_LOG"
case "$1" in
    gsm.sim.state) cat "$SIM_STATE_FILE" 2>/dev/null ;;
esac
exit 0
EOF
    cat > "$_lt/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-o addr show"*)
        [ -f "$AP_STATE_FILE" ] && printf '%s\n' "2: wlan2    inet 192.168.42.1/24 scope global wlan2"
        ;;
esac
exit 0
EOF
    cat > "$_lt/bin/iptables" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$_lt/bin/app_process" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "com.hsp.HsCtl" ]; do shift; done
[ $# -gt 0 ] && shift
_sub=$1; [ $# -gt 0 ] && shift
printf '%s %s\n' "$_sub" "$*" >> "$HSCTL_LOG"
case "$_sub" in
    start)
        case "${HSCTL_MODE:-ok}" in
            ok) : > "$AP_STATE_FILE"; printf '%s\n' "start_result=SUCCESS" ;;
            fail) printf '%s\n' "error=bad \"quote\" \\ slash"; exit 1 ;;
            reject) printf '%s\n' "start_result=UNSUPPORTED"; exit 1 ;;
            noap) printf '%s\n' "start_result=SUCCESS" ;;
        esac
        ;;
    stop)
        rm -f "$AP_STATE_FILE"
        printf '%s\n' "stop_result=SUCCESS"
        ;;
    state) printf '%s\n' "ap_state=0" ;;
esac
exit 0
EOF
    chmod +x "$_lt/bin/getprop" "$_lt/bin/ip" "$_lt/bin/iptables" "$_lt/bin/app_process"
}

_lifecycle_config() { # AUTO SIM [extra]
    cat > "$_lt/data/config.conf" <<EOF
AUTO_START="$1"
FIXED_GATEWAY="0"
ENFORCE_GATEWAY="0"
DHCP_ENABLE="0"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
AP_IFACE="wlan2"
FALLBACK_SSID=""
FALLBACK_PASS=""
EOF
}

_lifecycle_run() { # [VAR=value ...] -- hsp args...
    _envs=
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    [ "$1" = "--" ] && shift
    # shellcheck disable=SC2086
    env PATH="$_lt/bin:$PATH" HSP_DATA="$_lt/data" HSP_APP_PROCESS="$_lt/bin/app_process" \
        IPB="$_lt/bin/ip" IPT="$_lt/bin/iptables" GETPROP_LOG="$_lt/getprop.log" \
        SIM_STATE_FILE="$_lt/sim" AP_STATE_FILE="$_lt/ap" HSCTL_LOG="$_lt/hsctl.log" \
        HSCTL_MODE="${HSCTL_MODE:-ok}" $_envs sh "$ROOT/bin/hsp" "$@"
}

_lifecycle_status() {
    _lifecycle_run -- status --json
}

_json() { # expression
    "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d, "json": json}))' "$1"
}

_sim_reads() {
    if [ ! -f "$_lt/getprop.log" ]; then
        echo 0
    elif grep -qx 'gsm.sim.state' "$_lt/getprop.log"; then
        grep -cx 'gsm.sim.state' "$_lt/getprop.log"
    else
        echo 0
    fi
}

_hsctl_has() {
    [ -f "$_lt/hsctl.log" ] && grep -q "^$1" "$_lt/hsctl.log"
}

boot_decision_matrix() {
    . "$ROOT/lib/common.sh"
    [ "$(boot_autostart_decision 0 LOADED 0)" = disabled ] &&
        [ "$(boot_autostart_decision 1 '' 0)" = no_sim ] &&
        [ "$(boot_autostart_decision 1 ABSENT,ABSENT 0)" = no_sim ] &&
        [ "$(boot_autostart_decision 1 NOT_LOADED 0)" = no_sim ] &&
        [ "$(boot_autostart_decision 1 LOADED 1)" = already_on ] &&
        [ "$(boot_autostart_decision 1 LOADED 0)" = start ] &&
        [ "$(boot_autostart_decision 1 ABSENT,LOADED 0)" = start ]
}

default_auto_start_is_off() {
    grep -q '^AUTO_START="0"$' "$ROOT/defaults/config.conf" &&
        grep -q '^    AUTO_START=0$' "$ROOT/lib/common.sh"
}

boot_disabled_does_not_read_sim() {
    _lifecycle_env disabled || return 1
    _lifecycle_fakes
    _lifecycle_config 0 ABSENT
    printf '%s\n' ABSENT > "$_lt/sim"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    [ "$(_sim_reads)" = 0 ] &&
        [ ! -f "$_lt/ap" ] &&
        [ "$(_lifecycle_status | _json 'd["boot_decision"]')" = disabled ] &&
        [ "$(_lifecycle_status | _json 'd["boot_result"]')" = skipped ] &&
        [ "$(_lifecycle_status | _json 'd["auto_start"]')" = False ]
}

boot_starts_once_when_loaded_token_exists() {
    _lifecycle_env loaded || return 1
    _lifecycle_fakes
    _lifecycle_config 1 ABSENT,LOADED
    printf '%s\n' ABSENT,LOADED > "$_lt/sim"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_decision"]')" = start ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = started ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_sim"]')" = ABSENT,LOADED ] &&
        [ "$(printf '%s' "$_s" | _json 'd["ap"]')" = True ] &&
        [ "$(grep -c '^start ' "$_lt/hsctl.log")" = 1 ] &&
        grep -q 'boot-auto' "$_lt/data/logs/hsp.log"
}

boot_skips_without_loaded_token() {
    _lifecycle_env nosim || return 1
    _lifecycle_fakes
    _lifecycle_config 1 NOT_LOADED,ABSENT
    printf '%s\n' NOT_LOADED,ABSENT > "$_lt/sim"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_decision"]')" = no_sim ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = skipped ] &&
        [ ! -f "$_lt/ap" ] &&
        ! _hsctl_has start
}

boot_already_on_does_not_restart() {
    _lifecycle_env already || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    : > "$_lt/ap"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_decision"]')" = already_on ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = already_on ] &&
        [ -f "$_lt/ap" ] &&
        ! _hsctl_has start &&
        ! _hsctl_has stop
}

boot_output_is_clean_for_redirect() {
    _lifecycle_env clean || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    : > "$_lt/ap"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    [ "$(cat "$_lt/out")" = "开机自动开启：热点已开启，跳过" ]
}

boot_already_on_wins_over_missing_sim() {
    _lifecycle_env already-nosim || return 1
    _lifecycle_fakes
    _lifecycle_config 1 ABSENT
    printf '%s\n' ABSENT > "$_lt/sim"
    : > "$_lt/ap"
    _lifecycle_run -- boot-auto > "$_lt/out" 2>&1 || return 1
    [ "$(_lifecycle_status | _json 'd["boot_decision"]')" = already_on ] &&
        ! _hsctl_has start &&
        ! _hsctl_has stop
}

boot_start_failure_is_visible() {
    _lifecycle_env failure || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    _lifecycle_run HSP_START_WAIT=0 HSCTL_MODE=fail -- boot-auto > "$_lt/out" 2>&1 && return 1
    _s=$(_lifecycle_status)
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = start_failed ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_result"]')" = start_failed ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_error"]')" = 'bad "quote" \ slash' ] &&
        grep -q 'ERROR:.*start failed' "$_lt/data/logs/hsp.log"
}

boot_rejection_is_not_reported_as_success() {
    _lifecycle_env reject || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    _lifecycle_run HSP_START_WAIT=0 HSCTL_MODE=reject -- boot-auto > "$_lt/out" 2>&1 && return 1
    _s=$(_lifecycle_status)
    [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = start_failed ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_error"]')" = UNSUPPORTED ] &&
        [ "$(printf '%s' "$_s" | _json 'd["ap"]')" = False ]
}

boot_timeout_is_distinct() {
    _lifecycle_env timeout || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    _lifecycle_run HSCTL_MODE=noap HSP_START_WAIT=1 -- boot-auto > "$_lt/out" 2>&1 && return 1
    _s=$(_lifecycle_status)
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(printf '%s' "$_s" | _json 'd["boot_result"]')" = timeout ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_result"]')" = timeout ] &&
        grep -q 'TIMEOUT:.*hotspot start' "$_lt/data/logs/hsp.log"
}

boot_is_limited_to_once_per_boot() {
    _lifecycle_env once || return 1
    _lifecycle_fakes
    _lifecycle_config 1 LOADED
    printf '%s\n' LOADED > "$_lt/sim"
    _lifecycle_run -- boot-auto > "$_lt/out1" 2>&1 || return 1
    _lifecycle_run -- boot-auto > "$_lt/out2" 2>&1 || return 1
    [ "$(_sim_reads)" = 1 ] &&
        [ "$(grep -c '^start ' "$_lt/hsctl.log")" = 1 ] &&
        grep -q 'boot-auto already evaluated' "$_lt/out2"
}

manual_on_already_on_is_idempotent() {
    _lifecycle_env idempotent || return 1
    _lifecycle_fakes
    _lifecycle_config 0 LOADED
    : > "$_lt/ap"
    _lifecycle_run -- on > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(printf '%s' "$_s" | _json 'd["last_action"]')" = on ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_result"]')" = already_on ] &&
        [ -f "$_lt/ap" ] &&
        ! _hsctl_has start &&
        ! _hsctl_has stop
}

restart_reports_lifecycle_result() {
    _lifecycle_env restart || return 1
    _lifecycle_fakes
    _lifecycle_config 0 LOADED
    : > "$_lt/ap"
    _lifecycle_run -- restart > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(printf '%s' "$_s" | _json 'd["last_action"]')" = restart ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_result"]')" = started ] &&
        [ "$(printf '%s' "$_s" | _json 'd["ap"]')" = True ] &&
        _hsctl_has stop &&
        _hsctl_has start
}

restart_stops_before_start() {
    _lifecycle_env restart-order || return 1
    _lifecycle_fakes
    _lifecycle_config 0 LOADED
    : > "$_lt/ap"
    _lifecycle_run -- restart > "$_lt/out" 2>&1 || return 1
    [ "$(grep -n '^stop ' "$_lt/hsctl.log" | cut -d: -f1)" -lt "$(grep -n '^start ' "$_lt/hsctl.log" | cut -d: -f1)" ]
}

stop_reports_and_leaves_ap_off() {
    _lifecycle_env stop || return 1
    _lifecycle_fakes
    _lifecycle_config 0 LOADED
    : > "$_lt/ap"
    _lifecycle_run -- off > "$_lt/out" 2>&1 || return 1
    _s=$(_lifecycle_status)
    [ "$(printf '%s' "$_s" | _json 'd["last_action"]')" = off ] &&
        [ "$(printf '%s' "$_s" | _json 'd["last_result"]')" = stopped ] &&
        [ "$(printf '%s' "$_s" | _json 'd["ap"]')" = False ] &&
        [ ! -f "$_lt/ap" ]
}

status_json_survives_error_text() {
    _lifecycle_env json || return 1
    _lifecycle_fakes
    _lifecycle_config 0 LOADED
    _lifecycle_run HSP_START_WAIT=0 -- on > "$_lt/out" 2>&1 && return 1
    _s=$(_lifecycle_status) || return 1
    printf '%s' "$_s" | _json 'json.dumps(d, sort_keys=True)' >/dev/null
}

service_boot_path_is_one_shot_and_independent() {
    grep -q 'bin/hsp" boot-auto' "$ROOT/service.sh" &&
        ! grep -q 'gsm.sim.state\|bin/hsp" on' "$ROOT/service.sh" &&
        ! grep -rq 'oneplus8t_fixed_hotspot\|hotspotboot' \
            "$ROOT/bin/hsp" "$ROOT/bin/hspd" "$ROOT/lib" "$ROOT/service.sh"
}

hotspot_start_waits_for_tether_route() {
    grep -q 'wait_hotspot_ready 12' "$ROOT/bin/hsp" &&
        grep -q 'wait_dhcp_ready 12' "$ROOT/bin/hspd" &&
        grep -q 'sys/class/net/\$AP_IF' "$ROOT/bin/hsp" &&
        grep -q 'dev " iface' "$ROOT/bin/hsp"
}

default_tethering_is_module_owned() {
    grep -q '^FIXED_GATEWAY="1"$' "$ROOT/defaults/config.conf" &&
        grep -q '^DHCP_ENABLE="1"$' "$ROOT/defaults/config.conf" &&
        grep -q '^ENFORCE_GATEWAY="0"$' "$ROOT/defaults/config.conf" &&
        grep -q '^    FIXED_GATEWAY=1$' "$ROOT/lib/common.sh" &&
        grep -q '^    DHCP_ENABLE=1$' "$ROOT/lib/common.sh" &&
        grep -q '^    ENFORCE_GATEWAY=0$' "$ROOT/lib/common.sh"
}

own_dhcp_has_bounded_start_attempts() {
    grep -q 'DHCP_TRIED=0' "$ROOT/bin/hspd" &&
        grep -q '\[ "\$DHCP_TRIED" = 0 \]' "$ROOT/bin/hspd" &&
        grep -q 'one startup attempt for this session' "$ROOT/bin/hspd"
}

static_clients_renew_after_takeover() {
    grep -q 'dhcp_release_placeholder_clients' "$ROOT/bin/hspd" &&
        grep -q 'dhcp_drop_stale_placeholder' "$ROOT/bin/hspd" &&
        grep -q 'lease_ip_for_mac' "$ROOT/lib/common.sh" &&
        grep -q 'client .* at .* will re-acquire' "$ROOT/lib/common.sh"
}

run_case "boot decision matrix" boot_decision_matrix
run_case "AUTO_START defaults off" default_auto_start_is_off
run_case "boot disabled does not read SIM" boot_disabled_does_not_read_sim
run_case "boot starts once for LOADED token" boot_starts_once_when_loaded_token_exists
run_case "boot skips without LOADED token" boot_skips_without_loaded_token
run_case "boot already-on does not churn" boot_already_on_does_not_restart
run_case "boot output is clean for redirect" boot_output_is_clean_for_redirect
run_case "boot already-on wins over missing SIM" boot_already_on_wins_over_missing_sim
run_case "boot start failure is visible" boot_start_failure_is_visible
run_case "boot rejection is not success" boot_rejection_is_not_reported_as_success
run_case "boot timeout is distinct" boot_timeout_is_distinct
run_case "boot evaluates at most once" boot_is_limited_to_once_per_boot
run_case "manual on already-on is idempotent" manual_on_already_on_is_idempotent
run_case "restart reports lifecycle result" restart_reports_lifecycle_result
run_case "restart stops before starting" restart_stops_before_start
run_case "stop reports and leaves AP off" stop_reports_and_leaves_ap_off
run_case "status JSON survives error text" status_json_survives_error_text
run_case "service boot path is one-shot and independent" service_boot_path_is_one_shot_and_independent
run_case "hotspot start waits for tether route" hotspot_start_waits_for_tether_route
run_case "default hotspot DHCP is module-owned" default_tethering_is_module_owned
run_case "own DHCP has bounded start attempts" own_dhcp_has_bounded_start_attempts
run_case "static clients renew after DHCP takeover" static_clients_renew_after_takeover
