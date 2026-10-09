#!/bin/sh
# Build the installable KernelSU module zip.
#   1) (optional) rebuild the app:  SDK=/path/to/android-sdk sh app/build.sh && cp app/build/hotspot_plus.apk app/
#   2) sh package.sh  ->  hotspot_plus-<version>.zip
# Note: app/hotspot_plus.apk is not tracked in git; build it (with your own keystore) or take it from a GitHub Release.
set -e
cd "$(dirname "$0")"
VER=$(sed -n 's/^version=//p' module.prop)
OUT=hotspot_plus-$VER.zip
[ -f app/hotspot_plus.apk ] || echo "warning: app/hotspot_plus.apk missing, module will install without the launcher app" >&2
rm -f "$OUT"
zip -qr -X "$OUT" META-INF README.md action.sh app bin customize.sh defaults diag.sh lib module.prop sepolicy.rule service.sh src uninstall.sh webroot \
    -x 'app/build/*' 'app/keystore/*'
echo "built $OUT"
