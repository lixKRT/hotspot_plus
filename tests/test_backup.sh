#!/bin/sh
# Backup/restore/uninstall checks against a temporary HSP_DATA and backup directory.

_backup_env() { # name -> fresh temp tree
    _bt=$TMPROOT/backup-$1
    rm -rf "$_bt"
    mkdir -p "$_bt/data/run" "$_bt/data/logs" "$_bt/backups" "$_bt/bin" "$_bt/out"
    cat > "$_bt/data/config.conf" <<'EOF'
FIXED_GATEWAY="1"
GATEWAY="192.168.42.1"
PREFIX="24"
DHCP_ENABLE="1"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
FALLBACK_SSID="My AP"
FALLBACK_PASS="secret pass"
EOF
    printf 'aa:bb:cc:dd:ee:ff 192.168.42.10 laptop\n' > "$_bt/data/leases.conf"
    printf 'aa:bb:cc:dd:ee:ff 192.168.42.10 1700000000 0 0 0\n' > "$_bt/data/udhcpd.leases"
    printf '1234\n' > "$_bt/data/run/hspd.pid"
    printf 'runtime\n' > "$_bt/data/run/state"
    printf 'stale log\n' > "$_bt/data/logs/hsp.log"
    chmod 700 "$_bt/data"
}

_backup_hsp() { # args...
    env HSP_DATA="$_bt/data" HSP_BACKUP_DIR="${HSP_TEST_BDIR:-$_bt/backups}" \
        HSP_EXPORT_DIR="$_bt/out" HSP_NOW=1700000000 \
        HSP_DEVICE_BUILD=BP4A.251205.006 \
        HSP_BUSYBOX=/nonexistent PATH="$_bt/bin:$PATH" MODDIR="$ROOT" \
        sh "$ROOT/bin/hsp" "$@" 2>&1
}

_backup_if_privileged() {
    [ "$(id -u)" = 0 ]
}

_bundle_of() { # backup root -> newest bundle path
    _bo=$(ls -1d "$1"/*/ 2>/dev/null | sort | tail -n 1)
    [ -n "$_bo" ] && echo "${_bo%/}"
}

backup_bundle_contents_and_permissions() {
    _backup_env contents
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    [ -n "$_pkg" ] || { printf 'no bundle: %s\n' "$_out"; return 1; }
    [ -f "$_pkg/manifest" ] && [ -f "$_pkg/config.conf" ] && [ -f "$_pkg/leases.conf" ] &&
        grep -q '^format=hotspot_plus_backup$' "$_pkg/manifest" &&
        grep -q '^format_version=1$' "$_pkg/manifest" &&
        grep -q '^module_version=v0.3.0$' "$_pkg/manifest" &&
        grep -q '^created_at=1700000000$' "$_pkg/manifest" &&
        grep -q '^android_build=BP4A.251205.006$' "$_pkg/manifest" &&
        grep -q '^sha256=' "$_pkg/manifest" &&
        grep -q '^FALLBACK_PASS="secret pass"$' "$_pkg/config.conf" &&
        grep -q '^aa:bb:cc:dd:ee:ff 192.168.42.10 laptop$' "$_pkg/leases.conf" &&
        [ ! -e "$_pkg/udhcpd.leases" ] && [ ! -e "$_pkg/logs" ] && [ ! -e "$_pkg/run" ] &&
        [ "$(stat -c %a "$_pkg")" = 700 ] &&
        [ "$(stat -c %a "$_pkg/manifest")" = 600 ] &&
        [ "$(stat -c %a "$_pkg/config.conf")" = 600 ] &&
        printf '%s\n' "$_out" | grep -q "$_pkg"
}

backup_checksum_covers_payload() {
    _backup_env checksum
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    printf 'tampered\n' >> "$_pkg/leases.conf"
    _out=$(_backup_hsp restore "$_pkg" --yes) && return 1
    printf '%s\n' "$_out" | grep -q '校验' &&
        ! grep -q '^tampered$' "$_bt/data/leases.conf"
}

backup_rejects_unknown_version_and_missing_fields() {
    _backup_env version
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    _bad=$_bt/version-future
    cp -R "$_pkg" "$_bad"
    sed 's/^format_version=1$/format_version=999/' "$_bad/manifest" > "$_bad/manifest.tmp" &&
        mv -f "$_bad/manifest.tmp" "$_bad/manifest"
    _out=$(_backup_hsp restore "$_bad" --yes) && return 1
    printf '%s\n' "$_out" | grep -qi '不兼容\|版本'
    _missing=$_bt/version-missing
    cp -R "$_pkg" "$_missing"
    grep -v '^module_version=\|^created_at=' "$_missing/manifest" > "$_missing/manifest.tmp"
    mv -f "$_missing/manifest.tmp" "$_missing/manifest"
    _out=$(_backup_hsp restore "$_missing" --yes) && return 1
    printf '%s\n' "$_out" | grep -q '缺'
}

backup_rejects_path_traversal_and_symlinks() {
    _backup_if_privileged || return 0
    _backup_env links
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    cp -R "$_pkg" "$_bt/link"
    rm -f "$_bt/link/config.conf"
    ln -s /etc/passwd "$_bt/link/config.conf"
    _out=$(_backup_hsp restore "$_bt/link" --yes) && return 1
    printf '%s\n' "$_out" | grep -q '符号链接\|普通文件' && ! grep -q 'root:' "$_bt/data/config.conf"
}

restore_requires_explicit_confirmation() {
    _backup_env confirm
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    printf 'user config\n' > "$_bt/data/config.conf"
    _out=$(_backup_hsp restore "$_pkg") && return 1
    printf '%s\n' "$_out" | grep -q '确认' &&
        grep -q '^user config$' "$_bt/data/config.conf"
}

restore_replaces_config_and_leases() {
    _backup_env restore
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    printf 'GATEWAY="10.0.0.1"\n' > "$_bt/data/config.conf"
    : > "$_bt/data/leases.conf"
    _out=$(_backup_hsp restore "$_pkg" --yes) || { printf '%s\n' "$_out"; return 1; }
    grep -q '^GATEWAY="192.168.42.1"$' "$_bt/data/config.conf" &&
        grep -q '^FALLBACK_SSID="My AP"$' "$_bt/data/config.conf" &&
        grep -q 'laptop' "$_bt/data/leases.conf" &&
        grep -q '^aa:bb:cc:dd:ee:ff 192.168.42.10 1700000000 0 0 0$' "$_bt/data/udhcpd.leases" &&
        printf '%s\n' "$_out" | grep -q '已恢复'
}

restore_prompt_only_for_fresh_install() {
    _backup_env prompt
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    rm -f "$_bt/data/config.conf" "$_bt/data/leases.conf"
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=1$' || { printf '%s\n' "$_out"; return 1; }
    printf 'GATEWAY="192.168.42.1"\n' > "$_bt/data/config.conf"
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=0$' || { printf '%s\n' "$_out"; return 1; }
    rm -f "$_bt/data/config.conf"
    printf 'installer default\n' > "$_bt/data/.config_default"
    cp "$ROOT/defaults/config.conf" "$_bt/data/config.conf"
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=1$' || { printf '%s\n' "$_out"; return 1; }
}

restore_prompt_hidden_after_dismissal() {
    _backup_env dismissed
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    rm -f "$_bt/data/config.conf" "$_bt/data/leases.conf"
    _out=$(_backup_hsp restore-dismiss) || { printf '%s\n' "$_out"; return 1; }
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=0$'
}

restore_rejects_bad_payload_content() {
    _backup_env badpayload
    printf 'GATEWAY="192.168.42.1"\nreboot\n' > "$_bt/bad.conf"
    printf 'aa:bb:cc:dd:ee:ff 192.168.42.10 ok\n' > "$_bt/good.leases"
    printf 'not-a-mac 192.168.42.10\n' > "$_bt/bad.leases"
    (
        HSP_DATA=$_bt/data MODDIR=$ROOT HSP_BUSYBOX=/nonexistent
        export HSP_DATA MODDIR HSP_BUSYBOX
        . "$ROOT/lib/common.sh"
        . "$ROOT/lib/backup.sh"
        ! backup_config_sane "$_bt/bad.conf" &&
            backup_leases_sane "$_bt/good.leases" &&
            ! backup_leases_sane "$_bt/bad.leases"
    )
}

backup_list_and_export() {
    command -v tar >/dev/null 2>&1 || return 0
    _backup_env export
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    _out=$(_backup_hsp backup list) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q "${_pkg##*/}" || { printf '%s\n' "$_out"; return 1; }
    _out=$(_backup_hsp backup export "$_pkg") || { printf '%s\n' "$_out"; return 1; }
    [ -f "$_bt/out/${_pkg##*/}.tar.gz" ] || { printf '%s\n' "$_out"; return 1; }
}

backup_refuses_storage_inside_data() {
    _backup_env inside
    _out=$(env HSP_DATA="$_bt/data" HSP_BACKUP_DIR="$_bt/data/backups" HSP_NOW=1700000000 \
        HSP_BUSYBOX=/nonexistent MODDIR="$ROOT" sh "$ROOT/bin/hsp" backup 2>&1) && return 1
    printf '%s\n' "$_out" | grep -q '数据目录之外' &&
        [ ! -d "$_bt/data/backups" ]
}

uninstall_retries_then_continues_with_loud_error() {
    _backup_env uninstall-fail
    mkdir -p "$_bt/mod/lib"
    cp "$ROOT/uninstall.sh" "$_bt/mod/uninstall.sh"
    cp "$ROOT/lib/common.sh" "$ROOT/lib/backup.sh" "$_bt/mod/lib/"
    printf '#!/bin/sh\nexit 1\n' > "$_bt/bin/iptables"
    chmod +x "$_bt/bin/iptables"
    _out=$(env PATH="$_bt/bin:$PATH" HSP_DATA="$_bt/data" HSP_BACKUP_DIR="$_bt/backups" \
        HSP_UNINSTALL_RETRIES=2 HSP_UNINSTALL_RETRY_WAIT=1 \
        HSP_TEST_NO_REMOVE_MODULE=1 HSP_TEST_BACKUP_FAIL=1 \
        sh "$_bt/mod/uninstall.sh" 2>&1) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q 'ERROR' &&
        printf '%s\n' "$_out" | grep -q '备份' &&
        printf '%s\n' "$_out" | grep -q '尝试 2/2' &&
        printf '%s\n' "$_out" | grep -q 'hotspot_plus_backup.log' &&
        [ ! -d "$_bt/data" ] &&
        printf '%s\n' "$_out" | grep -q '继续卸载'
}

uninstall_creates_backup_before_removing_data() {
    _backup_env uninstall-ok
    mkdir -p "$_bt/mod/lib"
    cp "$ROOT/uninstall.sh" "$_bt/mod/uninstall.sh"
    cp "$ROOT/lib/common.sh" "$ROOT/lib/backup.sh" "$_bt/mod/lib/"
    printf '#!/bin/sh\nexit 0\n' > "$_bt/bin/iptables"
    chmod +x "$_bt/bin/iptables"
    _out=$(env PATH="$_bt/bin:$PATH" HSP_DATA="$_bt/data" HSP_BACKUP_DIR="$_bt/backups" \
        HSP_TEST_NO_REMOVE_MODULE=1 sh "$_bt/mod/uninstall.sh" 2>&1) || { printf '%s\n' "$_out"; return 1; }
    _pkg=$(_bundle_of "$_bt/backups")
    [ -n "$_pkg" ] && [ ! -d "$_bt/data" ] &&
        printf '%s\n' "$_out" | grep -q "$_pkg" &&
        printf '%s\n' "$_out" | grep -q '已备份'
}

upgrade_clears_runtime_only() {
    _backup_env upgrade
    mkdir -p "$_bt/mod/defaults"
    cp "$ROOT/defaults/config.conf" "$_bt/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_bt/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_bt/mod/module.prop"
    cp "$ROOT/customize.sh" "$_bt/mod/customize.sh"
    printf 'old stderr\n' > "$_bt/data/logs/hsctl.err"
    printf 'old dhcp log\n' > "$_bt/data/logs/udhcpd.log"
    printf 'old rotated\n' > "$_bt/data/logs/hsp.log.1"
    printf 'stale tmp\n' > "$_bt/data/run/hsctl.tmp"
    printf 'lock\n' > "$_bt/data/run/session.lock"
    printf 'sock\n' > "$_bt/data/run/hspd.sock"
    _before_c=$(cksum "$_bt/data/config.conf")
    _before_l=$(cksum "$_bt/data/leases.conf")
    _out=$(HSP_DATA="$_bt/data" MODPATH="$_bt/mod" HSP_INSTALLER_DRY_RUN=1 \
        sh -c 'ui_print() { printf "%s\n" "$*"; }; abort() { printf "%s\n" "$*"; }; set_perm() { :; }; set_perm_recursive() { :; }; . "$MODPATH/customize.sh"' 2>&1) ||
        { printf '%s\n' "$_out"; return 1; }
    [ "$(cksum "$_bt/data/config.conf")" = "$_before_c" ] &&
        [ "$(cksum "$_bt/data/leases.conf")" = "$_before_l" ] &&
        [ ! -e "$_bt/data/udhcpd.leases" ] &&
        [ ! -e "$_bt/data/run/hspd.pid" ] &&
        [ ! -e "$_bt/data/run/state" ] &&
        [ ! -e "$_bt/data/logs/hsp.log" ] &&
        [ ! -e "$_bt/data/logs/hsctl.err" ] &&
        [ ! -e "$_bt/data/logs/udhcpd.log" ] &&
        [ ! -e "$_bt/data/logs/hsp.log.1" ] &&
        [ ! -e "$_bt/data/run/hsctl.tmp" ] &&
        [ ! -e "$_bt/data/run/session.lock" ] &&
        [ ! -e "$_bt/data/run/hspd.sock" ] &&
        [ -d "$_bt/data/run" ] && [ -d "$_bt/data/logs" ]
}

installer_marks_only_default_config() {
    _backup_env marker
    mkdir -p "$_bt/mod/defaults"
    cp "$ROOT/defaults/config.conf" "$_bt/mod/defaults/config.conf"
    cp "$ROOT/defaults/leases.conf" "$_bt/mod/defaults/leases.conf"
    cp "$ROOT/module.prop" "$_bt/mod/module.prop"
    cp "$ROOT/customize.sh" "$_bt/mod/customize.sh"
    _out=$(HSP_DATA="$_bt/data2" MODPATH="$_bt/mod" HSP_INSTALLER_DRY_RUN=1 \
        sh -c 'ui_print() { printf "%s\n" "$*"; }; abort() { printf "%s\n" "$*"; }; set_perm() { :; }; set_perm_recursive() { :; }; . "$MODPATH/customize.sh"' 2>&1) ||
        { printf '%s\n' "$_out"; return 1; }
    [ -f "$_bt/data2/.config_default" ] && [ ! -f "$_bt/data/.config_default" ]
}

config_marker_lifecycle() {
    _backup_env lifecycle
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    # 1) default config + marker => prompt eligible
    : > "$_bt/data/.config_default"
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=1$' || { printf '%s\n' "$_out"; return 1; }
    # 2) successful user config change clears the marker => not eligible
    _out=$(env HSP_DATA="$_bt/data" HSP_BACKUP_DIR="$_bt/backups" HSP_BUSYBOX=/nonexistent \
        MODDIR="$ROOT" sh "$ROOT/bin/hsp" set DNS=223.5.5.5 2>&1) || { printf '%s\n' "$_out"; return 1; }
    [ ! -e "$_bt/data/.config_default" ] || { printf 'marker survived set\n'; return 1; }
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=0$' || { printf '%s\n' "$_out"; return 1; }
    # 3) restore also clears marker/dismissal => not eligible
    : > "$_bt/data/.config_default"
    _pkg=$(_bundle_of "$_bt/backups")
    _out=$(_backup_hsp restore "$_pkg" --yes) || { printf '%s\n' "$_out"; return 1; }
    [ ! -e "$_bt/data/.config_default" ] &&
        _out=$(_backup_hsp restore-prompt) &&
        printf '%s\n' "$_out" | grep -q '^prompt=0$'
}

clean_install_is_prompt_eligible() {
    _backup_env clean
    _out=$(_backup_hsp backup) || { printf '%s\n' "$_out"; return 1; }
    rm -f "$_bt/data/config.conf" "$_bt/data/leases.conf"
    _out=$(_backup_hsp restore-prompt) || { printf '%s\n' "$_out"; return 1; }
    printf '%s\n' "$_out" | grep -q '^prompt=1$'
}

ui_restore_prompt_requires_confirmation() {
    _ui=$ROOT/webroot/index.html
    _n=$(grep -c 'restore ${shq(restoreLatest)} --yes' "$_ui")
    [ "$_n" = 1 ] &&
        grep -q 'restore-prompt' "$_ui" &&
        grep -q 'btnRestoreDismiss' "$_ui" &&
        grep -q 'btnRestore.*onclick' "$_ui"
}

run_case "backup bundle contents, provenance and perms" backup_bundle_contents_and_permissions
run_case "backup checksum rejects tampering" backup_checksum_covers_payload
run_case "backup rejects unknown version/missing fields" backup_rejects_unknown_version_and_missing_fields
run_case "backup rejects symlink payload" backup_rejects_path_traversal_and_symlinks
run_case "restore requires explicit confirmation" restore_requires_explicit_confirmation
run_case "restore replaces config and static leases" restore_replaces_config_and_leases
run_case "restore prompt only for fresh install" restore_prompt_only_for_fresh_install
run_case "restore prompt hidden after dismissal" restore_prompt_hidden_after_dismissal
run_case "restore rejects injected config content" restore_rejects_bad_payload_content
run_case "backup list and explicit export" backup_list_and_export
run_case "backup dir must be outside data" backup_refuses_storage_inside_data
run_case "uninstall retries then continues loudly" uninstall_retries_then_continues_with_loud_error
run_case "uninstall backs up before deleting data" uninstall_creates_backup_before_removing_data
run_case "upgrade preserves user assets only" upgrade_clears_runtime_only
run_case "installer marks default config distinctly" installer_marks_only_default_config
run_case "config marker lifecycle: default/set/restore" config_marker_lifecycle
run_case "clean install is restore-prompt eligible" clean_install_is_prompt_eligible
run_case "UI restore prompt needs explicit confirmation" ui_restore_prompt_requires_confirmation
