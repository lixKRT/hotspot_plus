#!/bin/sh
# Build a Magisk/KernelSU module zip. No APK or private signing material is required.
#   sh package.sh [OUTPUT_DIR]
# An APK may be added explicitly with: INCLUDE_APP=1 sh package.sh (app/hotspot_plus.apk must exist).
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
OUTDIR=${1:-$ROOT}
VER=$(sed -n 's/^version=//p' "$ROOT/module.prop" | tr -d '\r')
[ -n "$VER" ] || { echo "error: module.prop has no version" >&2; exit 1; }
OUT=$OUTDIR/hotspot_plus-$VER.zip
PYTHON=${PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null)}
[ -n "$PYTHON" ] || { echo "error: python3 is required to build the verified package" >&2; exit 1; }

if [ -f "$ROOT/app/hotspot_plus.apk" ]; then
    echo "warning: app/hotspot_plus.apk ignored; package.sh builds the module-only zip" >&2
    echo "warning: use INCLUDE_APP=1 sh package.sh to include the app in a local artifact" >&2
elif [ "${INCLUDE_APP:-0}" = 1 ]; then
    echo "error: INCLUDE_APP=1 but app/hotspot_plus.apk is missing" >&2
    echo "       build it with SDK=/path/to/android-sdk sh app/build.sh" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
rm -f "$OUT"
cd "$ROOT"
"$PYTHON" - "$ROOT" "$OUT" "${INCLUDE_APP:-0}" <<'PY'
import os, sys, zipfile

root, out, include_app = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
files = ["README.md", "action.sh", "bin/hsctl.jar", "bin/hsp", "bin/hspd",
         "customize.sh", "defaults/config.conf", "defaults/leases.conf", "diag.sh",
         "lib/common.sh", "module.prop", "sepolicy.rule", "service.sh", "uninstall.sh",
         "webroot/index.html"]
for base, _, names in os.walk(os.path.join(root, "META-INF")):
    for name in names:
        files.append(os.path.relpath(os.path.join(base, name), root).replace(os.sep, "/"))
if include_app:
    apk = os.path.join(root, "app", "hotspot_plus.apk")
    if not os.path.isfile(apk):
        sys.exit("error: app/hotspot_plus.apk missing")
    files.append("app/hotspot_plus.apk")

missing = [f for f in files if not os.path.isfile(os.path.join(root, f))]
if missing:
    sys.exit("error: required files missing: " + ", ".join(missing))

for name in files:
    if any(part in ("build", "keystore", ".git") for part in name.split("/")):
        sys.exit("error: refusing to package private/build path: " + name)
    if name.endswith((".jks", ".keystore", ".zip")) or name.endswith("password.txt"):
        sys.exit("error: refusing to package secret/artifact: " + name)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(files):
        with open(os.path.join(root, name), "rb") as f:
            data = f.read()
        if name != "bin/hsctl.jar" and b"\r\n" in data:
            sys.exit("error: CRLF in packaged file: " + name)
        z.writestr(name, data)

with zipfile.ZipFile(out) as z:
    names = z.namelist()
    bad = [n for n in names if n.startswith(("app/", ".git/"))
           or any(part in ("build", "keystore") for part in n.split("/"))
           or n.endswith((".apk", ".jks", ".keystore", ".zip")) or n.endswith("password.txt")]
    if bad:
        sys.exit("error: package verification found forbidden entries: " + ", ".join(bad))
print("verified %d files" % len(names))
PY
echo "built $OUT"
