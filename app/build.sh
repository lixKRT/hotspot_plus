#!/bin/sh
# Gradle-less build of the 「热点增强」 launcher app (aapt2 + javac + d8 + zipalign + apksigner).
#   SDK=/opt/android-sdk sh app/build.sh  ->  app/build/unsigned.apk (or hotspot_plus.apk if a key exists)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=${SDK:-${ANDROID_HOME:-/opt/android-sdk}}
BT=${BT:-$SDK/build-tools/36.0.0}
PLAT=${PLAT:-$SDK/platforms/android-36/android.jar}
VERSION_CODE=${VERSION_CODE:-300}
VERSION_NAME=${VERSION_NAME:-0.3.0}
B=$HERE/build
rm -rf "$B"; mkdir -p "$B/classes" "$B/dex" "$B/gen" "$B/assets"
exe() {
    if [ -x "$1" ]; then echo "$1"
    elif [ -x "$1.exe" ]; then echo "$1.exe"
    else echo "error: missing build tool $1" >&2; exit 1
    fi
}
AAPT2=$(exe "$BT/aapt2")
ZIPALIGN=$(exe "$BT/zipalign")
D8="$BT/d8"
if [ ! -x "$D8" ] && [ ! -x "$D8.exe" ]; then D8="java -cp $BT/lib/d8.jar com.android.tools.r8.D8"; fi
APKSIGNER="$BT/apksigner"
if [ ! -x "$APKSIGNER" ] && [ ! -x "$APKSIGNER.exe" ]; then APKSIGNER="java -jar $BT/lib/apksigner.jar"; fi
"$AAPT2" compile --dir "$HERE/res" -o "$B/res.zip"
"$AAPT2" link -I "$PLAT" --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 30 --target-sdk-version 36 \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
    -A "$B/assets" --java "$B/gen" -o "$B/unsigned.apk" "$B/res.zip"
# shellcheck disable=SC2046
javac -nowarn -Xlint:-options --release 8 -encoding UTF-8 -classpath "$PLAT" \
    -d "$B/classes" $(find "$HERE/src" "$B/gen" -name '*.java')
# shellcheck disable=SC2046
# shellcheck disable=SC2086
$D8 --release --min-api 30 --lib "$PLAT" --output "$B/dex" $(find "$B/classes" -name '*.class')
PYTHON=${PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null)}
[ -n "$PYTHON" ] || { echo "error: python3 is required to add classes.dex" >&2; exit 1; }
"$PYTHON" - "$B/unsigned.apk" "$B/dex/classes.dex" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "classes.dex")
PY
"$ZIPALIGN" -p -f 4 "$B/unsigned.apk" "$B/aligned.apk"
if [ ! -f "$HERE/keystore/hotspot_plus.jks" ] || [ ! -f "$HERE/keystore/password.txt" ]; then
    cp "$B/aligned.apk" "$B/unsigned.apk"
    echo "built $B/unsigned.apk (unsigned: private keystore unavailable)" >&2
    exit 0
fi
# shellcheck disable=SC2086
$APKSIGNER sign --ks "$HERE/keystore/hotspot_plus.jks" --ks-key-alias hotspotplus \
    --ks-pass "file:$HERE/keystore/password.txt" \
    --out "$B/hotspot_plus.apk" "$B/aligned.apk"
# shellcheck disable=SC2086
$APKSIGNER verify "$B/hotspot_plus.apk"
echo "built $B/hotspot_plus.apk"
