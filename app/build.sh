#!/bin/sh
# Gradle-less build of the 「热点增强」 launcher app (aapt2 + javac + d8 + zipalign + apksigner).
#   SDK=/opt/android-sdk sh app/build.sh  ->  app/build/hotspot_plus.apk
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=${SDK:-${ANDROID_HOME:-/opt/android-sdk}}
BT=${BT:-$SDK/build-tools/37.0.0}
PLAT=${PLAT:-$SDK/platforms/android-36/android.jar}
VERSION_CODE=${VERSION_CODE:-200}
VERSION_NAME=${VERSION_NAME:-0.2.0}
B=$HERE/build
rm -rf "$B"; mkdir -p "$B/classes" "$B/dex" "$B/gen" "$B/assets"
# bundled fallback copy of the module WebUI (the app prefers the installed module's copy)
cp "$HERE/../webroot/index.html" "$B/assets/index.html"
"$BT/aapt2" compile --dir "$HERE/res" -o "$B/res.zip"
"$BT/aapt2" link -I "$PLAT" --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 30 --target-sdk-version 36 \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
    -A "$B/assets" --java "$B/gen" -o "$B/unsigned.apk" "$B/res.zip"
# shellcheck disable=SC2046
javac -nowarn -Xlint:-options -source 8 -target 8 -encoding UTF-8 -bootclasspath "$PLAT:$BT/core-lambda-stubs.jar" -classpath "$PLAT" \
    -d "$B/classes" $(find "$HERE/src" "$B/gen" -name '*.java')
# shellcheck disable=SC2046
"$BT/d8" --release --min-api 30 --lib "$PLAT" --output "$B/dex" $(find "$B/classes" -name '*.class')
(cd "$B/dex" && zip -q -X "$B/unsigned.apk" classes.dex)
"$BT/zipalign" -p -f 4 "$B/unsigned.apk" "$B/aligned.apk"
"$BT/apksigner" sign --ks "$HERE/keystore/hotspot_plus.jks" --ks-key-alias hotspotplus \
    --ks-pass "file:$HERE/keystore/password.txt" \
    --out "$B/hotspot_plus.apk" "$B/aligned.apk"
"$BT/apksigner" verify "$B/hotspot_plus.apk"
echo "built $B/hotspot_plus.apk"
