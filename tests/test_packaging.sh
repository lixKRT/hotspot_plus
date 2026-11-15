#!/bin/sh
# Offline packaging checks: identity, safe defaults, LF, and package contents.

PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)

module_identity() {
    [ "$(sed -n 's/^id=//p' "$ROOT/module.prop")" = hotspot_plus ] &&
        [ "$(sed -n 's/^version=//p' "$ROOT/module.prop")" = v0.3.0 ] &&
        [ "$(sed -n 's/^versionCode=//p' "$ROOT/module.prop")" = 300 ] &&
        grep -q '^DATA=/data/adb/hotspot_plus$' "$ROOT/customize.sh"
}

no_legacy_migration() {
    [ ! -e "$ROOT/lib/migrate.sh" ] &&
        ! grep -rq 'migrate_subnet\|192\.168\.43\.' \
            "$ROOT/customize.sh" "$ROOT/lib" "$ROOT/defaults" "$ROOT/bin/hsp" "$ROOT/bin/hspd"
}

default_subnet_is_42() {
    grep -q '^GATEWAY="192.168.42.1"$' "$ROOT/defaults/config.conf" &&
        grep -q '^PREFIX="24"$' "$ROOT/defaults/config.conf" &&
        grep -q '^DHCP_START="192.168.42.100"$' "$ROOT/defaults/config.conf" &&
        grep -q '^DHCP_END="192.168.42.200"$' "$ROOT/defaults/config.conf" &&
        grep -q 'GATEWAY=192\.168\.42\.1' "$ROOT/lib/common.sh" &&
        grep -q 'DHCP_START=192\.168\.42\.100' "$ROOT/lib/common.sh" &&
        grep -q 'DHCP_END=192\.168\.42\.200' "$ROOT/lib/common.sh" &&
        ! grep -rq '192\.168\.4\.' "$ROOT/defaults" "$ROOT/lib" "$ROOT/webroot" "$ROOT/bin/hsp" "$ROOT/bin/hspd"
}

shipped_files_are_lf() {
    [ -n "$PYTHON" ] || return 1
    "$PYTHON" - "$ROOT" <<'PY'
import os, re, subprocess, sys
root = sys.argv[1]
try:
    out = subprocess.check_output(["git.exe", "ls-files", "-z"], cwd=root)
except (OSError, subprocess.CalledProcessError) as exc:
    print("cannot list shipped files: %s" % exc, file=sys.stderr)
    sys.exit(2)
names = [n for n in out.decode().split("\0") if n]
bad = []
for name in names:
    if name == "bin/hsctl.jar":
        continue
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    with open(path, "rb") as f:
        data = f.read()
    if b"\r\n" in data or b"\r" in data.replace(b"\r\n", b""):
        bad.append(name)
if bad:
    print("CRLF/CR in: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
}

gitattributes_covers_shipped_text() {
    _a=$ROOT/.gitattributes
    grep -q '^\*\.sh text eol=lf$' "$_a" &&
        grep -q '^module\.prop text eol=lf$' "$_a" &&
        grep -q '^bin/hsp text eol=lf$' "$_a" &&
        grep -q '^bin/hspd text eol=lf$' "$_a" &&
        grep -q '^META-INF/com/google/android/\* text eol=lf$' "$_a" &&
        grep -q '^sepolicy\.rule text eol=lf$' "$_a" &&
        grep -q '^bin/hsctl\.jar binary$' "$_a"
}

installer_is_manager_neutral() {
    ! grep -q '请在 KernelSU 管理器' "$ROOT/customize.sh" &&
        grep -q '/data/adb/magisk/busybox' "$ROOT/customize.sh" &&
        grep -q '管理器: Magisk' "$ROOT/customize.sh"
}

package_omits_private_and_binary_artifacts() {
    [ -n "$PYTHON" ] || return 1
    _outdir=$TMPROOT/package-test
    mkdir -p "$_outdir"
    _has_apk=0
    [ -f "$ROOT/app/hotspot_plus.apk" ] && _has_apk=1
    _pkgout=$(cd "$ROOT" && sh ./package.sh "$_outdir" 2>&1) || {
        printf '%s\n' "$_pkgout"
        return 1
    }
    if [ "$_has_apk" = 1 ]; then
        printf '%s\n' "$_pkgout" | grep -q 'warning:.*module-only' || return 1
    fi
    _out=$("$PYTHON" - "$_outdir" <<'PY'
import glob, os, re, sys, zipfile
outdir = sys.argv[1]
pkgs = glob.glob(os.path.join(outdir, "hotspot_plus-v*.zip"))
if len(pkgs) != 1:
    sys.exit("expected one package, found %d" % len(pkgs))
with zipfile.ZipFile(pkgs[0]) as z:
    names = z.namelist()
    leaked = [n for n in names if re.search(
        r"(^|/)(app/(build|keystore)/|\.git/|build/)|\.(apk|jks|keystore|zip)$|"
        r"(^|/)password\.txt$|device-evidence", n)]
    if leaked:
        print("unexpected entries: " + ", ".join(leaked), file=sys.stderr)
        sys.exit(1)
    required = ["customize.sh", "module.prop", "bin/hsp", "bin/hspd", "defaults/config.conf",
                "lib/common.sh", "META-INF/com/google/android/update-binary"]
    missing = [n for n in required if n not in names]
    if missing:
        print("missing entries: " + ", ".join(missing), file=sys.stderr)
        sys.exit(1)
    for n in names:
        if n.endswith("/"):
            continue
        data = z.read(n)
        if n.endswith((".sh", ".prop", ".conf", ".html", ".rule")) or n.startswith(("bin/hsp", "META-INF/")):
            if b"\r\n" in data:
                print("CRLF in zip entry: " + n, file=sys.stderr)
                sys.exit(1)
PY
    ) || { printf '%s\n' "$_out"; return 1; }
}

package_refuses_include_app_without_apk() {
    _outdir=$TMPROOT/package-no-app
    mkdir -p "$_outdir"
    _out=$(cd "$ROOT" && INCLUDE_APP=1 sh ./package.sh "$_outdir" 2>&1) && return 1
    printf '%s\n' "$_out" | grep -q 'app/hotspot_plus.apk is missing'
}

run_case "module identity and version" module_identity
run_case "upstream subnet migration removed" no_legacy_migration
run_case "default subnet is 192.168.42.0/24" default_subnet_is_42
run_case "shipped files use LF" shipped_files_are_lf
run_case ".gitattributes covers shipped text" gitattributes_covers_shipped_text
run_case "installer is Magisk/KernelSU neutral" installer_is_manager_neutral
run_case "package excludes private/binary artifacts" package_omits_private_and_binary_artifacts
run_case "package requires APK when INCLUDE_APP=1" package_refuses_include_app_without_apk
