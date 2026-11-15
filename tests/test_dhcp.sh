#!/bin/sh
# Offline DHCP takeover checks (ADR-0006). Temporary MODDIR/HSP_DATA, fake
# udhcpd/iptables processes, no device, no real hotspot, and no client traffic.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

_dhcp_env() { # name -> temp MODDIR + DATA
    _dt=$TMPROOT/dhcp-$1
    rm -rf "$_dt"
    mkdir -p "$_dt/mod/bin" "$_dt/mod/lib" "$_dt/mod/defaults" \
        "$_dt/data/run" "$_dt/data/logs" "$_dt/fake"
    cp "$ROOT/bin/hsp" "$ROOT/bin/hspd" "$_dt/mod/bin/"
    cp "$ROOT/lib/common.sh" "$_dt/mod/lib/"
    cp "$ROOT/module.prop" "$_dt/mod/"
    cp "$ROOT/defaults/"* "$_dt/mod/defaults/"
    cp "$ROOT/bin/hsctl.jar" "$_dt/mod/bin/hsctl.jar" 2>/dev/null
    mkdir -p "$_dt/ipt-state"
    cat > "$_dt/data/config.conf" <<'EOF'
FIXED_GATEWAY="0"
ENFORCE_GATEWAY="0"
GATEWAY="192.168.42.1"
PREFIX="24"
DHCP_ENABLE="1"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
AP_IFACE="wlan2"
AUTO_START="0"
FALLBACK_SSID=""
FALLBACK_PASS=""
EOF
    printf '02:00:00:00:00:01 192.168.42.150 laptop\n' > "$_dt/data/leases.conf"
    : > "$_dt/data/udhcpd.leases"
    _dhcp_fakes
}

_dhcp_fakes() {
    cat > "$_dt/fake/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-4 -o addr show"*) printf '%s\n' "3: wlan2    inet 192.168.42.1/24 scope global wlan2" ;;
    *"route show"*) : ;;
esac
exit 0
EOF
    cat > "$_dt/fake/iptables" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$IPT_LOG"
printf 'ipt %s\n' "$*" >> "$ACTION_LOG"
case "$*" in
    *"-A hsp_dhcp"*)
        [ "${IPT_FAIL:-}" = owner ] && exit 1
        : > "$IPT_STATE/rule"; exit 0 ;;
    *"-C hsp_dhcp -o"*)
        [ -f "$IPT_STATE/rule" ] && exit 0
        exit 1 ;;
    *"-F hsp_dhcp"*)
        rm -f "$IPT_STATE/rule"; exit 0 ;;
    *"-X hsp_dhcp"*)
        rm -f "$IPT_STATE/rule" "$IPT_STATE/chain" "$IPT_STATE/jump"; exit 0 ;;
    *"-N hsp_dhcp"*)
        : > "$IPT_STATE/chain"; exit 0 ;;
    *"-I OUTPUT"*)
        [ "${IPT_FAIL:-}" = jump ] && exit 1
        : > "$IPT_STATE/jump"; exit 0 ;;
    *"-D OUTPUT -j hsp_dhcp"*)
        [ -f "$IPT_STATE/jump" ] || exit 1
        rm -f "$IPT_STATE/jump"; exit 0 ;;
    *"-C OUTPUT -j hsp_dhcp"*)
        [ -f "$IPT_STATE/jump" ] && exit 0
        exit 1 ;;
esac
exit 0
EOF
    cat > "$_dt/fake/busybox" <<'EOF'
#!/bin/sh
case "$1" in
    --list)
        printf 'udhcpd\ndumpleases\nflock\n'
        exit 0 ;;
    udhcpd)
        exec "$HSP_FAKE_UDHCPD" "$@" ;;
    dumpleases)
        exit 0 ;;
esac
exit 1
EOF
    cat > "$_dt/fake/udhcpd" <<'EOF'
#!/bin/sh
printf 'start %s\n' "$$" >> "$BUSY_LOG"
printf 'udhcpd-start\n' >> "$ACTION_LOG"
case "${DHCP_FAKE_MODE:-success}" in
    fail) exit 1 ;;
    crash)
        sleep 0.2
        printf 'crash %s\n' "$$" >> "$BUSY_LOG"
        exit 1 ;;
    success)
        trap 'printf "stop %s\n" "$$" >> "$BUSY_LOG"; printf "udhcpd-stop\n" >> "$ACTION_LOG"; exit 0' TERM INT
        while :; do sleep 1; done ;;
esac
exit 1
EOF
    cat > "$_dt/fake/getprop" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$_dt/fake/dumpsys" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$_dt/fake/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF
    cat > "$_dt/fake/app_process" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HSCTL_LOG"
exit 0
EOF
    chmod +x "$_dt/fake/ip" "$_dt/fake/iptables" "$_dt/fake/busybox" "$_dt/fake/udhcpd" \
        "$_dt/fake/getprop" "$_dt/fake/dumpsys" "$_dt/fake/setsid" \
        "$_dt/fake/app_process"
}

_dhcp_run() { # [VAR=value ...] -- hsp args...
    _envs=
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    [ "$1" = "--" ] && shift
    # shellcheck disable=SC2086
    env PATH="$_dt/fake:$PATH" MODDIR="$_dt/mod" HSP_DATA="$_dt/data" \
        HSP_APP_PROCESS="$_dt/fake/app_process" IPB="$_dt/fake/ip" \
        IPT="$_dt/fake/iptables" HSP_BUSYBOX="$_dt/fake/busybox" \
        HSP_FLOCK=: LOCK_WAIT=3 HSP_START_WAIT=0 \
        HSP_FAKE_UDHCPD="$_dt/fake/udhcpd" \
        HSP_DHCP_FAIL_LIMIT=3 HSP_GW_NO_SPAWN=1 \
        IPT_LOG="$_dt/iptables.log" BUSY_LOG="$_dt/busybox.log" ACTION_LOG="$_dt/actions.log" \
        IPT_STATE="$_dt/ipt-state" HSCTL_LOG="$_dt/hsctl.log" \
        $_envs sh "$_dt/mod/bin/hsp" "$@"
}

_dhcp_eval() { # shell body evaluated with common.sh loaded
    _eval_path="$_dt/fake:$PATH"; _eval_mod=$_dt/mod; _eval_data=$_dt/data
    export _eval_path _eval_mod _eval_data
    env PATH="$_eval_path" MODDIR="$_eval_mod" HSP_DATA="$_eval_data" \
        HSP_APP_PROCESS="$_dt/fake/app_process" IPB="$_dt/fake/ip" \
        IPT="$_dt/fake/iptables" HSP_BUSYBOX="$_dt/fake/busybox" \
        HSP_FLOCK=: \
        HSP_FAKE_UDHCPD="$_dt/fake/udhcpd" \
        HSP_DHCP_FAIL_LIMIT=3 \
        IPT_LOG="$_dt/iptables.log" BUSY_LOG="$_dt/busybox.log" ACTION_LOG="$_dt/actions.log" \
        IPT_STATE="$_dt/ipt-state" HSCTL_LOG="$_dt/hsctl.log" \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; '"$1"
}

_dhcp_state() { # key
    sed -n "s/^$1=//p" "$_dt/data/run/dhcp" 2>/dev/null | tail -n1
}

_dhcp_summary() { # key
    sed -n "s/^$1=//p" "$_dt/data/run/state" 2>/dev/null | tail -n1
}

_dhcp_json() { # expression
    _dhcp_run -- status --json | "$PYTHON" -c \
        'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d, "json": json}))' "$1"
}

_dhcp_cleanup_process() {
    _p=$(cat "$_dt/data/run/udhcpd.pid" 2>/dev/null)
    [ -n "$_p" ] && kill "$_p" 2>/dev/null
    _dhcp_eval 'dhcp_stop' >/dev/null 2>&1
}

dhcp_takeover_starts_and_verifies_before_jump() {
    _dhcp_env order || return 1
    _dhcp_eval 'dhcp_session_begin && dhcp_takeover wlan2 192.168.42.1/24' || return 1
    _s=$(grep -n '^udhcpd-start$' "$_dt/actions.log" | head -n1 | cut -d: -f1)
    _n=$(grep -n 'ipt .* -N hsp_dhcp' "$_dt/actions.log" | head -n1 | cut -d: -f1)
    _j=$(grep -n 'OUTPUT 1 -j hsp_dhcp' "$_dt/actions.log" | head -n1 | cut -d: -f1)
    _dhcp_cleanup_process
    [ -n "$_s" ] && [ -n "$_n" ] && [ -n "$_j" ] &&
        [ "$_s" -lt "$_n" ] && [ "$_s" -lt "$_j" ] &&
        [ "$(_dhcp_state serving)" = 1 ] &&
        [ "$(_dhcp_state degraded)" = 0 ]
}

udhcpd_start_failure_installs_no_takeover() {
    _dhcp_env start-fail || return 1
    env PATH="$_dt/fake:$PATH" MODDIR="$_dt/mod" HSP_DATA="$_dt/data" \
        IPB="$_dt/fake/ip" IPT="$_dt/fake/iptables" HSP_BUSYBOX="$_dt/fake/busybox" \
        HSP_FAKE_UDHCPD="$_dt/fake/udhcpd" HSP_FLOCK=: DHCP_FAKE_MODE=fail \
        IPT_LOG="$_dt/iptables.log" BUSY_LOG="$_dt/busybox.log" ACTION_LOG="$_dt/actions.log" \
        IPT_STATE="$_dt/ipt-state" \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; dhcp_session_begin; dhcp_takeover wlan2 192.168.42.1/24; exit $?'
    _dc_rc=$?
    [ "$_dc_rc" = 1 ] || return 1
    _rs=$(_dhcp_state reason)
    _sv=$(_dhcp_state serving)
    _fl=$(_dhcp_state failures)
    _dg=$(_dhcp_state degraded)
    [ "$_sv" = 0 ] &&
        [ "$_fl" = 1 ] &&
        [ "$_dg" = 0 ] &&
        [ "$_rs" = "udhcpd 启动失败" ] &&
        ! grep -q ' -N hsp_dhcp' "$_dt/iptables.log" &&
        ! grep -q 'OUTPUT 1 -j hsp_dhcp' "$_dt/iptables.log" &&
        [ ! -f "$_dt/data/run/udhcpd.pid" ]
}

firewall_failure_removes_jump_before_stopping_udhcpd() {
    _dhcp_env fw-fail || return 1
    env PATH="$_dt/fake:$PATH" MODDIR="$_dt/mod" HSP_DATA="$_dt/data" \
        IPB="$_dt/fake/ip" IPT="$_dt/fake/iptables" HSP_BUSYBOX="$_dt/fake/busybox" \
        HSP_FAKE_UDHCPD="$_dt/fake/udhcpd" HSP_FLOCK=: IPT_FAIL=owner \
        IPT_LOG="$_dt/iptables.log" BUSY_LOG="$_dt/busybox.log" ACTION_LOG="$_dt/actions.log" \
        IPT_STATE="$_dt/ipt-state" \
        sh -c '. "$MODDIR/lib/common.sh"; load_config; dhcp_session_begin; dhcp_takeover wlan2 192.168.42.1/24; exit $?'
    _dc_rc=$?
    [ "$_dc_rc" = 1 ] || return 1
    _d=$(grep -n 'ipt .* -D OUTPUT -j hsp_dhcp' "$_dt/actions.log" | tail -n1 | cut -d: -f1)
    _x=$(grep -nE 'ipt .* -X[[:space:]]+hsp_dhcp' "$_dt/actions.log" | tail -n1 | cut -d: -f1)
    _s=$(grep -n '^udhcpd-stop$' "$_dt/actions.log" | tail -n1 | cut -d: -f1)
    _sv=$(_dhcp_state serving)
    _rs=$(_dhcp_state reason)
    [ "$_sv" = 0 ] &&
        [ -n "$_d" ] && [ -n "$_x" ] && [ -n "$_s" ] &&
        [ "$_d" -lt "$_s" ] && [ "$_x" -lt "$_s" ] &&
        [ ! -f "$_dt/data/run/udhcpd.pid" ] &&
        [ "$_rs" = "iptables 接管规则安装失败" ]
}

repeated_crashes_enter_visible_degraded_mode() {
    _dhcp_env crashes || return 1
    _dhcp_eval 'dhcp_session_begin; dhcp_set serving 1
        dhcp_crash "synthetic udhcpd exit"
        [ "$(dhcp_get degraded)" = 0 ] || exit 1
        dhcp_crash "synthetic udhcpd exit"
        [ "$(dhcp_get degraded)" = 0 ] || exit 1
        dhcp_crash "synthetic udhcpd exit"
        [ "$(dhcp_get degraded)" = 1 ] || exit 1
        [ "$(dhcp_get retry_available)" = 1 ]' || return 1
    [ "$(_dhcp_state degraded)" = 1 ] &&
        [ "$(_dhcp_state reason)" = "udhcpd 连续异常退出" ] &&
        [ "$(_dhcp_summary dhcp_degraded)" = 1 ] &&
        grep -q 'DEGRADED' "$_dt/data/logs/hsp.log"
}

status_exposes_dhcp_degraded_and_retry() {
    _dhcp_env status || return 1
    _dhcp_eval 'dhcp_session_begin
        dhcp_degrade "udhcpd 连续异常退出" "udhcpd 进程已退出"' || return 1
    _s=$(_dhcp_run -- status --json) || return 1
    [ "$(printf '%s' "$_s" | "$PYTHON" -c \
        'import json,sys; d=json.load(sys.stdin); print(d["dhcp_degraded"])')" = True ] &&
        printf '%s' "$_s" | grep -q '"dhcp_mode":"degraded"' &&
        printf '%s' "$_s" | grep -q '"dhcp_reason":"udhcpd 连续异常退出"' &&
        printf '%s' "$_s" | grep -q '"dhcp_last_error":"udhcpd 进程已退出"' &&
        [ "$(printf '%s' "$_s" | "$PYTHON" -c \
            'import json,sys; d=json.load(sys.stdin); print(d["dhcp_retry_available"])')" = True ]
}

retry_success_restores_static_leases_without_restart() {
    _dhcp_env retry-ok || return 1
    _dhcp_eval 'dhcp_session_begin
        dhcp_degrade "udhcpd 连续异常退出" "udhcpd 进程已退出"' || return 1
    _dhcp_run -- dhcp retry > "$_dt/retry.out" 2>&1 || return 1
    _s=$(_dhcp_run -- status --json) || return 1
    _ok=1
    [ "$(_dhcp_state degraded)" = 0 ] || _ok=0
    [ "$(_dhcp_state serving)" = 1 ] || _ok=0
    grep -q '^static_lease 02:00:00:00:00:01 192.168.42.150$' "$_dt/data/run/udhcpd.conf" || _ok=0
    [ ! -s "$_dt/hsctl.log" ] || _ok=0
    printf '%s' "$_s" | grep -q '"dhcp_degraded":false' || _ok=0
    _dhcp_cleanup_process
    [ "$_ok" = 1 ]
}

retry_failure_stays_degraded_and_never_restarts_hotspot() {
    _dhcp_env retry-fail || return 1
    _dhcp_eval 'dhcp_session_begin
        dhcp_degrade "udhcpd 连续异常退出" "udhcpd 进程已退出"' || return 1
    _dhcp_run DHCP_FAKE_MODE=fail -- dhcp retry > "$_dt/retry.out" 2>&1 && return 1
    [ "$(_dhcp_state degraded)" = 1 ] &&
        [ "$(_dhcp_state retry_available)" = 1 ] &&
        [ ! -s "$_dt/hsctl.log" ] &&
        ! grep -q -- 'OUTPUT 1 -j hsp_dhcp' "$_dt/iptables.log" &&
        [ "$(grep -c '^start ' "$_dt/busybox.log" 2>/dev/null)" = 1 ] &&
        grep -q '重试失败' "$_dt/retry.out"
}

cleanup_is_idempotent_and_targets_only_hsp_chain() {
    _dhcp_env cleanup || return 1
    _dhcp_eval 'fw_del; fw_del' || return 1
    ! grep -Eq -- '-(F|X|D) (hsp_probe|other|INPUT$)' "$_dt/iptables.log" &&
        grep -q -- ' -D OUTPUT -j hsp_dhcp' "$_dt/iptables.log" &&
        grep -q -- ' -X hsp_dhcp' "$_dt/iptables.log" &&
        ! grep -q -- ' -X OUTPUT' "$_dt/iptables.log"
}

daemon_health_check_fail_closes_crashed_udhcpd() {
    _dhcp_env daemon-crash || return 1
    grep -q 'dhcp_crash' "$ROOT/bin/hspd" &&
        grep -q 'fw_del' "$ROOT/lib/common.sh" &&
        grep -q 'dhcp_stop' "$ROOT/lib/common.sh" &&
        grep -q 'dhcp retry' "$ROOT/bin/hsp"
}

ui_shows_chinese_degraded_warning_and_retry() {
    grep -q '自建 DHCP 已降级' "$ROOT/webroot/index.html" &&
        grep -q '重试自建 DHCP' "$ROOT/webroot/index.html" &&
        grep -q 'dhcp_retry_available' "$ROOT/webroot/index.html" &&
        grep -q 'dhcp_last_error' "$ROOT/webroot/index.html"
}

run_case "DHCP starts and verifies before OUTPUT jump" dhcp_takeover_starts_and_verifies_before_jump
run_case "udhcpd start failure installs no takeover" udhcpd_start_failure_installs_no_takeover
run_case "firewall failure removes jump before dhcp stop" firewall_failure_removes_jump_before_stopping_udhcpd
run_case "repeated udhcpd crashes become degraded" repeated_crashes_enter_visible_degraded_mode
run_case "status exposes DHCP degraded and retry" status_exposes_dhcp_degraded_and_retry
run_case "DHCP retry restores leases without restart" retry_success_restores_static_leases_without_restart
run_case "DHCP retry failure is bounded and visible" retry_failure_stays_degraded_and_never_restarts_hotspot
run_case "DHCP cleanup is idempotent and exact" cleanup_is_idempotent_and_targets_only_hsp_chain
run_case "daemon fail-closes a crashed udhcpd" daemon_health_check_fail_closes_crashed_udhcpd
run_case "UI shows Chinese degraded warning and retry" ui_shows_chinese_degraded_warning_and_retry
