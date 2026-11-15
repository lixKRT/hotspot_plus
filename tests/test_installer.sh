#!/bin/sh
# Installer checks with a temporary MODPATH and HSP_DATA; no device is touched.

installer_writes_defaults_only_if_absent() {
    _t=${TMPROOT}/installer-defaults
    rm -rf "$_t"
    mkdir -p "$_t/mod/defaults" "$_t/data"
    cp "$ROOT/defaults/config.conf" "$_t/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_t/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_t/mod/module.prop"
    _out=$(_hsp_install "$_t/mod" "$_t/data") || { printf '%s\n' "$_out"; return 1; }
    grep -q '^GATEWAY="192.168.42.1"$' "$_t/data/config.conf" &&
        grep -q '^DHCP_END="192.168.42.200"$' "$_t/data/config.conf"
}

installer_preserves_existing_custom_config() {
    _t=${TMPROOT}/installer-preserve
    rm -rf "$_t"
    mkdir -p "$_t/mod/defaults" "$_t/data"
    cp "$ROOT/defaults/config.conf" "$_t/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_t/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_t/mod/module.prop"
    printf 'GATEWAY="10.20.30.1"\nPREFIX="24"\nDHCP_START="10.20.30.100"\nDHCP_END="10.20.30.150"\nAUTO_START="1"\n' \
        > "$_t/data/config.conf"
    printf 'aa:bb:cc:dd:ee:ff 10.20.30.42 laptop\n' > "$_t/data/leases.conf"
    _before_c=$(cksum "$_t/data/config.conf")
    _before_l=$(cksum "$_t/data/leases.conf")
    _out=$(_hsp_install "$_t/mod" "$_t/data") || { printf '%s\n' "$_out"; return 1; }
    [ "$(cksum "$_t/data/config.conf")" = "$_before_c" ] &&
        [ "$(cksum "$_t/data/leases.conf")" = "$_before_l" ] &&
        grep -q '保留已有配置' <<EOF
$_out
EOF
}

installer_reports_environment() {
    _t=${TMPROOT}/installer-report
    rm -rf "$_t"
    mkdir -p "$_t/mod/defaults" "$_t/data" "$_t/bin"
    cp "$ROOT/defaults/config.conf" "$_t/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_t/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_t/mod/module.prop"
    printf '#!/bin/sh\n[ "$1" = --list ] && echo udhcpd\n' > "$_t/bin/busybox"
    chmod +x "$_t/bin/busybox"
    _out=$(_hsp_install "$_t/mod" "$_t/data" "$_t/bin/busybox" arm64 36) ||
        { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q 'v0.3.0' &&
        printf '%s\n' "$_out" | grep -q 'arm64' &&
        printf '%s\n' "$_out" | grep -q 'API 36' &&
        printf '%s\n' "$_out" | grep -q 'udhcpd: 可用'
}

installer_without_ksu_or_udhcpd_continues() {
    _t=${TMPROOT}/installer-no-ksu
    rm -rf "$_t"
    mkdir -p "$_t/mod/defaults" "$_t/data"
    cp "$ROOT/defaults/config.conf" "$_t/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_t/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_t/mod/module.prop"
    _out=$(_hsp_install "$_t/mod" "$_t/data" /nonexistent/busybox arm64 36) ||
        { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q 'udhcpd: 不可用' &&
        [ -f "$_t/data/config.conf" ] &&
        ! printf '%s\n' "$_out" | grep -q 'KernelSU'
}

installer_does_not_uninstall_legacy() {
    ! grep -q 'oneplus8t_fixed_hotspot' "$ROOT/customize.sh" &&
        ! grep -q 'uninstall\|magisk --remove-modules' "$ROOT/customize.sh"
}

_hsp_install() { # MODPATH DATA [BUSYBOX] [ARCH] [API]
    HSP_DATA=$2
    MODPATH=$1
    API=${5:-36}
    ARCH=${4:-arm64}
    HSCTL_BUSYBOX=${3:-}
    HSP_INSTALLER_DRY_RUN=1
    unset KSU KSU_VER
    ui_print() { printf '%s\n' "$*"; }
    abort() { printf '%s\n' "$*"; return 1; }
    set_perm() { :; }
    set_perm_recursive() { :; }
    getprop() { printf '\n'; }
    . "$ROOT/customize.sh"
}

run_case "installer creates defaults when absent" installer_writes_defaults_only_if_absent
run_case "installer preserves custom config and leases" installer_preserves_existing_custom_config
run_case "installer reports version/arch/API/udhcpd" installer_reports_environment
run_case "installer works without KSU or udhcpd" installer_without_ksu_or_udhcpd_continues
run_case "installer leaves legacy module alone" installer_does_not_uninstall_legacy
