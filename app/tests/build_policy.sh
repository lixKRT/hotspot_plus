#!/bin/sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/.." && pwd)
BUILD="$APP/build.sh"

grep -q 'VERSION_CODE=${VERSION_CODE:-300}' "$BUILD" || { echo 'FAIL app versionCode default'; exit 1; }
grep -q 'VERSION_NAME=${VERSION_NAME:-0.3.0}' "$BUILD" || { echo 'FAIL app versionName default'; exit 1; }
grep -q 'unsigned: private keystore unavailable' "$BUILD" || { echo 'FAIL unsigned fallback'; exit 1; }
grep -q 'keystore/hotspot_plus.jks' "$BUILD" || { echo 'FAIL private key path'; exit 1; }
! grep -q 'password' "$APP/../.gitignore" || true
if [ -e "$APP/keystore/hotspot_plus.jks" ] || [ -e "$APP/keystore/password.txt" ]; then
    echo 'note: local keystore exists and is gitignored'
fi
echo 'build policy: ok'
