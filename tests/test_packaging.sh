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
    "$PYTHON" - "$ROOT" "$ROOT/tests/fixtures/shipped-files.txt" <<'PY'
import os, re, subprocess, sys
root = sys.argv[1]
manifest = sys.argv[2]
try:
    out = subprocess.check_output(["git.exe", "ls-files", "-z"], cwd=root)
    names = [n for n in out.decode().split("\0") if n]
except (OSError, subprocess.CalledProcessError):
    with open(manifest, encoding="utf-8") as f:
        names = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    if not names:
        sys.exit(2)
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

hsctl_jar_matches_source() {
    _hsctl_cwd=$(pwd)
    cd "$ROOT" || return 1
    _hsctl_finish() { cd "$_hsctl_cwd" 2>/dev/null; }
    _missing=
    for _tool in javac jar java sha256sum; do
        command -v "$_tool" >/dev/null 2>&1 || _missing="$_missing $_tool"
    done
    [ -n "$PYTHON" ] || _missing="$_missing python"
    [ -z "$_missing" ] || {
        printf 'SKIP: hsctl source/artifact check needs:%s\n' "$_missing"
        [ "${HSP_REQUIRE_HSCTL_REBUILD:-0}" = 1 ] && return 1
        _hsctl_finish
        return 77
    }
    _r8=${R8:-/tmp/tools/r8-8.13.19.jar}
    if [ ! -f "$_r8" ]; then
        printf 'SKIP: hsctl source/artifact check needs R8 8.13.19 (R8=%s)\n' "$_r8"
        [ "${HSP_REQUIRE_HSCTL_REBUILD:-0}" = 1 ] && return 1
        _hsctl_finish
        return 77
    fi
    "$PYTHON" - bin/hsctl.jar <<'PY' || { _hsctl_finish; return 1; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    entries = [n for n in z.namelist() if not n.endswith("/")]
if entries != ["classes.dex"]:
    print("FAIL: bin/hsctl.jar must contain exactly classes.dex, found: " + ", ".join(entries), file=sys.stderr)
    sys.exit(1)
PY
    _hsctl_tmp=$TMPROOT/hsctl-rebuild
    mkdir -p "$_hsctl_tmp/dex" || { _hsctl_finish; return 1; }
    B=$_hsctl_tmp/dex OUT=$_hsctl_tmp/hsctl.jar R8=$_r8 \
        sh "$ROOT/src/build-dex.sh" >/dev/null || {
        printf 'FAIL: hsctl rebuild from src/java failed (R8=%s)\n' "$_r8"
        _hsctl_finish
        return 1
    }
    "$PYTHON" - "$_hsctl_tmp/hsctl.jar" "$_hsctl_tmp/built.dex" <<'PY' || { _hsctl_finish; return 1; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as out:
    out.write(z.read("classes.dex"))
PY
    "$PYTHON" - bin/hsctl.jar "$_hsctl_tmp/shipped.dex" <<'PY' || { _hsctl_finish; return 1; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as out:
    out.write(z.read("classes.dex"))
PY
    _built_hash=$(sha256sum "$_hsctl_tmp/built.dex" | cut -d' ' -f1)
    _shipped_hash=$(sha256sum "$_hsctl_tmp/shipped.dex" | cut -d' ' -f1)
    [ "$_built_hash" = "$_shipped_hash" ] || {
        printf 'FAIL: bin/hsctl.jar classes.dex differs from current src/java rebuild\n'
        printf '  built=%s\n  shipped=%s\n' "$_built_hash" "$_shipped_hash"
        _hsctl_finish
        return 1
    }
    _zip_tmp=$TMPROOT/hsctl-rebuild-zip
    mkdir -p "$_zip_tmp/dex" || { _hsctl_finish; return 1; }
    B=$_zip_tmp/dex OUT=$_zip_tmp/hsctl.jar R8=$_r8 \
        sh "$ROOT/src/build-dex.sh" >/dev/null || { _hsctl_finish; return 1; }
    "$PYTHON" - "$_zip_tmp/hsctl.jar" "$_zip_tmp/built.dex" <<'PY' || { _hsctl_finish; return 1; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as out:
    out.write(z.read("classes.dex"))
PY
    [ "$(sha256sum "$_zip_tmp/built.dex" | cut -d' ' -f1)" = "$_shipped_hash" ] || {
        printf 'FAIL: zip and jar packaging produce different classes.dex\n'
        _hsctl_finish
        return 1
    }
    _hsctl_finish
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
    _out=$("$PYTHON" - "$ROOT" "$_outdir" <<'PY'
import glob, os, re, sys, zipfile
root = sys.argv[1]
outdir = sys.argv[2]
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
                "lib/common.sh", "lib/backup.sh", "META-INF/com/google/android/update-binary"]
    missing = [n for n in required if n not in names]
    if missing:
        print("missing entries: " + ", ".join(missing), file=sys.stderr)
        sys.exit(1)
    if "bin/hsctl.jar" not in names:
        print("missing entry: bin/hsctl.jar", file=sys.stderr)
        sys.exit(1)
    with open(os.path.join(root, "bin", "hsctl.jar"), "rb") as f:
        shipped_jar = f.read()
    if z.read("bin/hsctl.jar") != shipped_jar:
        print("bin/hsctl.jar in package differs from the repository artifact", file=sys.stderr)
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
    _root=$TMPROOT/package-no-app-root
    _outdir=$TMPROOT/package-no-app
    mkdir -p "$_root" "$_outdir"
    cp "$ROOT/package.sh" "$ROOT/module.prop" "$_root/"
    _out=$(cd "$_root" && sh ./package.sh --include-app "$_outdir" 2>&1) && return 1
    printf '%s\n' "$_out" | grep -q 'app/hotspot_plus.apk is missing'
}

run_case "module identity and version" module_identity
run_case "upstream subnet migration removed" no_legacy_migration
run_case "default subnet is 192.168.42.0/24" default_subnet_is_42
run_case "shipped files use LF" shipped_files_are_lf
run_case ".gitattributes covers shipped text" gitattributes_covers_shipped_text
run_case "installer is Magisk/KernelSU neutral" installer_is_manager_neutral
run_case "hsctl.jar matches current source" hsctl_jar_matches_source
run_case "package excludes private/binary artifacts" package_omits_private_and_binary_artifacts
run_case "package requires APK when --include-app is used" package_refuses_include_app_without_apk
