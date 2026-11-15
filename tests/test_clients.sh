#!/bin/sh
# Offline client-merge and static-lease checks. All client data comes from synthetic fixtures.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

_clients_env() { # name [prefix]
    _ct=$TMPROOT/clients-$1
    rm -rf "$_ct"
    mkdir -p "$_ct/data/run" "$_ct/data/logs" "$_ct/bin"
    _cp=${2:-24}
    cat > "$_ct/data/config.conf" <<EOF
FIXED_GATEWAY="0"
GATEWAY="192.168.42.1"
PREFIX="$_cp"
DHCP_ENABLE="1"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
AP_IFACE="wlan2"
EOF
    cat > "$_ct/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
    *"-4 -o addr show"*) printf '%s\n' "5: wlan2    inet ${AP_ADDR_OVERRIDE:-${AP_ADDR:-192.168.42.1/24}} scope global wlan2" ;;
    *"neigh show"*) cat "$NEIGH_FIXTURE" ;;
esac
exit 0
EOF
    cat > "$_ct/bin/iptables" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$_ct/bin/busybox" <<'EOF'
#!/bin/sh
case "$1" in
    --list) printf '%s\n' dumpleases ;;
    dumpleases) [ "$2" = -f ] || exit 1; cat "$DUMPLEASES_FIXTURE" ;;
esac
exit 0
EOF
    cat > "$_ct/bin/dumpsys" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$_ct/bin/app_process" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$_ct/bin/ip" "$_ct/bin/iptables" "$_ct/bin/busybox" "$_ct/bin/dumpsys" "$_ct/bin/app_process"
    printf 'wlan2 192.168.42.1/24 %s\n' "$(date +%s)" > "$_ct/data/run/session"
}

_clients_run() { # [VAR=value ...] -- hsp args...
    _envs=
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    [ "$1" = "--" ] && shift
    (
        PATH="$_ct/bin:$PATH"
        export PATH
        HSP_DATA="$_ct/data" HSP_BUSYBOX="$_ct/bin/busybox" IPB="$_ct/bin/ip" IPT="$_ct/bin/iptables"
        export HSP_DATA HSP_BUSYBOX IPB IPT
        HSP_APP_PROCESS="$_ct/bin/app_process" NEIGH_FIXTURE="$_ct/neigh" DUMPLEASES_FIXTURE="$_ct/dumpleases"
        export HSP_APP_PROCESS NEIGH_FIXTURE DUMPLEASES_FIXTURE
        HSP_ASSOC_COUNT=3
        export HSP_ASSOC_COUNT
        _override=""
        for _e in $_envs; do
            case "$_e" in AP_ADDR=*) _override=${_e#AP_ADDR=} ;; esac
        done
        [ -n "$_override" ] && { AP_ADDR_OVERRIDE=$_override; export AP_ADDR_OVERRIDE; }
        for _e in $_envs; do export "$_e"; done
        sh "$ROOT/bin/hsp" "$@"
    )
}

_all_fixtures() {
    cp "$ROOT/tests/fixtures/ip-neigh.txt" "$_ct/neigh"
    cp "$ROOT/tests/fixtures/dumpleases.txt" "$_ct/dumpleases"
    cp "$ROOT/tests/fixtures/leases.conf" "$_ct/data/leases.conf"
    cat > "$_ct/data/udhcpd.leases" <<'EOF'
Mac Address       IP Address      Host Name           Lease Expires
EOF
    # The fake dhcp_pid() finds no live daemon, so flush and discovery must not depend on one.
    printf '\n# A disconnected static client must not be silently dropped.\n' >> "$_ct/neigh"
}

_clients_json() {
    _clients_run -- clients --json
}

_json() {
    "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d, "json": json}))' "$1"
}

_client_count() { _clients_json | _json 'len(d["clients"])'; }

_client_field() { # mac key
    _clients_json | _json "[c for c in d[\"clients\"] if c[\"mac\"]==\$argv" 2>/dev/null
}

_row() { # mac expression
    _clients_json | "$PYTHON" -c 'import json,sys
mac=sys.argv[1]; expr=sys.argv[2]
d=json.load(sys.stdin)
rows=[c for c in d["clients"] if c["mac"]==mac]
print(eval(expr, {"c": rows[0]}) if rows else "MISSING")' "$1" "$2"
}

_text() { _clients_run -- clients; }

_lease() { # args -> data/leases.conf contents + rc
    _clients_run -- lease "$@"
}

_lease_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$_ct/data/leases.conf" 2>/dev/null
}

_lease_reset() {
    : > "$_ct/data/leases.conf"
}

clients_merge_three_sources() {
    _clients_env merge || return 1
    _all_fixtures
    [ "$(_client_count)" = 5 ] &&
        [ "$(_row 02:00:00:00:00:01 'c["ip"]')" = 192.168.42.101 ] &&
        [ "$(_row 02:00:00:00:00:01 'c["hostname"]')" = laptop ] &&
        [ "$(_row 02:00:00:00:00:01 'c["remark"]')" = 工作笔记本 ] &&
        [ "$(_row 02:00:00:00:00:01 'c["static_ip"]')" = 192.168.42.101 ] &&
        [ "$(_row 02:00:00:00:00:01 'c["state"]')" = REACHABLE ] &&
        [ "$(_row 02:00:00:00:00:01 'c["online"]')" = True ] &&
        [ "$(_row 02:00:00:00:00:01 'c["ip6"]')" = "fd00::101" ]
}

clients_keep_stale_and_lease_only_entries() {
    _clients_env stale || return 1
    _all_fixtures
    [ "$(_row 02:00:00:00:00:02 'c["state"]')" = STALE ] &&
        [ "$(_row 02:00:00:00:00:02 'c["online"]')" = True ] &&
        [ "$(_row 02:00:00:00:00:02 'c["lease"]')" = "0d_00:05:00" ] &&
        [ "$(_row 02:00:00:00:00:04 'c["ip"]')" = 192.168.42.104 ] &&
        [ "$(_row 02:00:00:00:00:04 'c["hostname"]')" = phone ] &&
        [ "$(_row 02:00:00:00:00:04 'c["static_ip"]')" = 192.168.42.150 ] &&
        [ "$(_row 02:00:00:00:00:04 'c["online"]')" = False ]
}

clients_show_static_only_clients() {
    _clients_env static || return 1
    _all_fixtures
    [ "$(_row 02:00:00:00:00:05 'c["ip"]')" = "" ] &&
        [ "$(_row 02:00:00:00:00:05 'c["static_ip"]')" = 192.168.42.160 ] &&
        [ "$(_row 02:00:00:00:00:05 'c["remark"]')" = 离线设备 ] &&
        [ "$(_row 02:00:00:00:00:05 'c["state"]')" = STATIC_ONLY ] &&
        [ "$(_row 02:00:00:00:00:05 'c["online"]')" = False ] &&
        [ "$(_row 02:00:00:00:00:05 'c["lease"]')" = "" ]
}

clients_text_and_json_share_source() {
    _clients_env text || return 1
    _all_fixtures
    _t=$(_text) || return 1
    printf '%s\n' "$_t" | grep -q '02:00:00:00:00:01.*192.168.42.101' &&
        printf '%s\n' "$_t" | grep -q '02:00:00:00:00:02.*STALE' &&
        printf '%s\n' "$_t" | grep -q '02:00:00:00:00:05.*STATIC_ONLY' &&
        [ "$(printf '%s\n' "$_t" | grep -c '^02:00:00:00:00:')" = 5 ]
}

clients_ap_off_is_empty() {
    _clients_env off || return 1
    rm -f "$_ct/data/run/session"
    cat > "$_ct/bin/ip" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$_ct/bin/ip"
    _clients_run -- clients --json | _json 'd["ap"]' | grep -qx False
}

lease_add_normalizes_and_keeps_remark() {
    _clients_env add || return 1
    _lease_reset
    _lease add AA-BB-CC-DD-EE-01 192.168.42.10 我的笔记本 >/dev/null || return 1
    [ "$(_lease_lines)" = "aa:bb:cc:dd:ee:01 192.168.42.10 我的笔记本" ]
}

lease_rejects_noncanonical_mac() {
    _clients_env badmac || return 1
    _lease_reset
    _lease add aa:bb:cc:dd:ee:1 192.168.42.10 >/dev/null 2>&1 && return 1
    _lease add 'aa:bb:cc:dd:ee:01;rm -rf /' 192.168.42.11 >/dev/null 2>&1 && return 1
    [ -z "$(_lease_lines)" ]
}

lease_rejects_duplicate_mac_and_ip() {
    _clients_env dup || return 1
    _lease_reset
    _lease add 02:00:00:00:00:01 192.168.42.10 >/dev/null || return 1
    _lease add 02:00:00:00:00:01 192.168.42.11 >/dev/null 2>&1 && return 1
    _lease add 02:00:00:00:00:02 192.168.42.10 >/dev/null 2>&1 && return 1
    [ "$(_lease_lines)" = "02:00:00:00:00:01 192.168.42.10" ]
}

lease_rejects_invalid_addresses() {
    _clients_env badip || return 1
    _lease_reset
    for _ip in 192.168.42.0 192.168.42.255 192.168.42.1 8.8.8.8 192.168.43.10 192.168.42.300 192.168.42; do
        _lease add 02:00:00:00:00:01 "$_ip" >/dev/null 2>&1 && return 1
    done
    [ -z "$(_lease_lines)" ]
}

lease_rejects_ip_on_other_mac() {
    _clients_env other || return 1
    _lease_reset
    _lease add 02:00:00:00:00:01 192.168.42.10 >/dev/null || return 1
    _lease add 02:00:00:00:00:02 192.168.42.20 旧设备 >/dev/null || return 1
    [ "$(_lease_lines | grep '^02:00:00:00:00:02 ')" = "02:00:00:00:00:02 192.168.42.20 旧设备" ] &&
        ! _lease add 02:00:00:00:00:03 192.168.42.20 第三者 >/dev/null 2>&1
}

lease_remark_is_sanitized() {
    _clients_env remark || return 1
    _lease_reset
    _lease add 02:00:00:00:00:01 192.168.42.10 'a"b$c`d\e	f
g' >/dev/null || return 1
    _v=$(_lease_lines | cut -d' ' -f3-)
    [ "$_v" = "abcde f g" ]
}

lease_import_rejects_shell_text() {
    _clients_env shelltext || return 1
    _lease_reset
    printf '# synthetic fixture\n' > "$_ct/data/leases.conf"
    _lease import 'aa:bb:cc:dd:ee:01; rm -rf /tmp/x' >/dev/null 2>&1 && return 1
    _lease import "$(printf 'aa:bb:cc:dd:ee:01 10.0.0.1' | base64)" >/dev/null 2>&1 && return 1
    [ "$(cat "$_ct/data/leases.conf")" = '# synthetic fixture' ]
}

lease_import_accepts_clean_text() {
    _clients_env import || return 1
    _lease_reset
    _txt=$(printf '02:00:00:00:00:01 192.168.42.10 备注一\n02:00:00:00:00:02 192.168.42.20 备注二\n')
    _b64=$(printf '%s' "$_txt" | base64 | tr -d '\n')
    _lease import "$_b64" >/dev/null || return 1
    [ "$(_lease_lines)" = "02:00:00:00:00:01 192.168.42.10 备注一
02:00:00:00:00:02 192.168.42.20 备注二" ]
}

lease_import_rebind_removes_old_reservation() {
    _clients_env rebind || return 1
    printf '%s\n' '# synthetic fixture' '02:00:00:00:00:02 192.168.42.20 旧设备' > "$_ct/data/leases.conf"
    cat > "$_ct/data/udhcpd.leases" <<'EOF'
Mac Address       IP Address      Host Name           Lease Expires
02:00:00:00:00:02 192.168.42.20  old                 0d 06:00:00
02:00:00:00:00:09 192.168.42.99  other               0d 06:00:00
EOF
    _txt=$(printf '02:00:00:00:00:01 192.168.42.10 笔记本\n02:00:00:00:00:02 192.168.42.30 新位置\n')
    _lease import "$(printf '%s' "$_txt" | base64 | tr -d '\n')" >/dev/null || return 1
    [ "$(_lease_lines | grep '^02:00:00:00:00:02 ')" = "02:00:00:00:00:02 192.168.42.30 新位置" ] &&
        ! grep -q '^02:00:00:00:00:02 192.168.42.20 ' "$_ct/data/udhcpd.leases" &&
        grep -q '^02:00:00:00:00:09 192.168.42.99 ' "$_ct/data/udhcpd.leases"
}

lease_import_rejects_duplicates_without_writing() {
    _clients_env importdup || return 1
    _lease_reset
    printf '# keep\n' > "$_ct/data/leases.conf"
    _txt=$(printf '02:00:00:00:00:01 192.168.42.10\n02:00:00:00:00:01 192.168.42.11\n')
    _lease import "$(printf '%s' "$_txt" | base64 | tr -d '\n')" >/dev/null 2>&1 && return 1
    [ "$(cat "$_ct/data/leases.conf")" = '# keep' ]
}

lease_config_reports_effective_ip() {
    _clients_env map || return 1
    _lease_reset
    _lease add 02:00:00:00:00:01 192.168.42.10 >/dev/null || return 1
    _clients_run AP_ADDR=192.168.99.1/24 -- status --json | _json 'd["subnet"]["status"]' | grep -qx mapped &&
        _clients_run AP_ADDR=192.168.99.1/24 -- status --json | _json 'd["subnet"]["actual"]' | grep -qx '192.168.99.0/24' &&
        _clients_run AP_ADDR=192.168.99.1/24 -- config | _json 'd["leases"][0]["effective_ip"]' | grep -qx '192.168.99.10'
}

dhcp_conf_reserves_static_addresses() {
    _clients_env dhcpconf || return 1
    _lease_reset
    _lease add 02:00:00:00:00:01 192.168.42.150 >/dev/null || return 1
    _lease add 02:00:00:00:00:02 192.168.42.160 >/dev/null || return 1
    cat > "$_ct/data/udhcpd.leases" <<'EOF'
Mac Address       IP Address      Host Name           Lease Expires
02:00:00:00:00:02 192.168.42.150  old-phone           0d 06:00:00
02:00:00:00:00:09 192.168.42.199  other               0d 06:00:00
EOF
    _clients_run -- lease apply >/dev/null || return 1
    [ -f "$_ct/data/run/udhcpd.conf" ] &&
        grep -q '^static_lease 02:00:00:00:00:01 192.168.42.150$' "$_ct/data/run/udhcpd.conf" &&
        grep -q '^static_lease 02:00:00:00:00:02 192.168.42.160$' "$_ct/data/run/udhcpd.conf" &&
        grep -q '^opt lease 43200$' "$_ct/data/run/udhcpd.conf" &&
        ! grep -q '^02:00:00:00:00:02 192.168.42.150 ' "$_ct/data/udhcpd.leases" &&
        grep -q '^02:00:00:00:00:09 192.168.42.199 ' "$_ct/data/udhcpd.leases"
}

lease_import_rebind_scrubs_old_dynamic_lease() {
    _clients_env rebind-dyn || return 1
    printf '%s\n' '02:00:00:00:00:02 192.168.42.20 旧设备' > "$_ct/data/leases.conf"
    cat > "$_ct/data/udhcpd.leases" <<'EOF'
Mac Address       IP Address      Host Name           Lease Expires
02:00:00:00:00:02 192.168.42.20  old                 0d 06:00:00
02:00:00:00:00:09 192.168.42.99  other               0d 06:00:00
EOF
    _txt=$(printf '02:00:00:00:00:02 192.168.42.30 新位置\n')
    _lease import "$(printf '%s' "$_txt" | base64 | tr -d '\n')" >/dev/null || return 1
    [ "$(_lease_lines)" = "02:00:00:00:00:02 192.168.42.30 新位置" ] &&
        ! grep -q '^02:00:00:00:00:02 192.168.42.20 ' "$_ct/data/udhcpd.leases" &&
        grep -q '^02:00:00:00:00:09 192.168.42.99 ' "$_ct/data/udhcpd.leases"
}

run_case "clients merge neighbor/lease/static sources" clients_merge_three_sources
run_case "clients label stale and lease-only entries" clients_keep_stale_and_lease_only_entries
run_case "clients show static-only reservations" clients_show_static_only_clients
run_case "clients text shares JSON source" clients_text_and_json_share_source
run_case "clients AP-off output is empty" clients_ap_off_is_empty
run_case "lease add normalizes MAC and keeps remark" lease_add_normalizes_and_keeps_remark
run_case "lease rejects noncanonical MAC" lease_rejects_noncanonical_mac
run_case "lease rejects duplicate MAC and IP" lease_rejects_duplicate_mac_and_ip
run_case "lease rejects invalid/out-of-subnet addresses" lease_rejects_invalid_addresses
run_case "lease rejects address held by another MAC" lease_rejects_ip_on_other_mac
run_case "lease remark is sanitized" lease_remark_is_sanitized
run_case "lease import rejects encoded shell text" lease_import_rejects_shell_text
run_case "lease import accepts clean text" lease_import_accepts_clean_text
run_case "lease import rebind removes old reservation" lease_import_rebind_removes_old_reservation
run_case "lease import duplicate does not write" lease_import_rejects_duplicates_without_writing
run_case "lease effective IP maps actual subnet" lease_config_reports_effective_ip
run_case "udhcpd conf reserves current static IPs" dhcp_conf_reserves_static_addresses
run_case "lease rebind scrubs old dynamic lease" lease_import_rebind_scrubs_old_dynamic_lease
