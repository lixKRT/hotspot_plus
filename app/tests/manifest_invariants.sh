#!/bin/sh
# Offline checks for the app identity, protected toggle entry, and WebUI bridge surface.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP="$ROOT/app"
MANIFEST="$APP/AndroidManifest.xml"
SHORTCUTS="$APP/res/xml/shortcuts.xml"
WEB="$ROOT/webroot/index.html"

fail() {
    printf 'FAIL %s\n' "$1"
    exit 1
}

grep -q 'package="com.lixkrt.hotspotplus"' "$MANIFEST" || fail 'manifest package identity'
grep -q 'android:name="com.lixkrt.hotspotplus.permission.TOGGLE_HOTSPOT"' "$MANIFEST" \
    || fail 'toggle permission declaration'
grep -A6 'android:name="com.lixkrt.hotspotplus.permission.TOGGLE_HOTSPOT"' "$MANIFEST" \
    | grep -q 'protectionLevel="signature"' || fail 'toggle permission is signature level'
grep -A8 'android:name=".ToggleActivity"' "$MANIFEST" \
    | grep -q 'android:permission="com.lixkrt.hotspotplus.permission.TOGGLE_HOTSPOT"' \
    || fail 'ToggleActivity permission'
grep -q 'android:name=".MainActivity"' "$MANIFEST" || fail 'launcher activity'
grep -q 'android:name=".HspTileService"' "$MANIFEST" || fail 'tile service'
grep -q 'android.permission.BIND_QUICK_SETTINGS_TILE' "$MANIFEST" || fail 'tile permission'

grep -q 'com.lixkrt.hotspotplus.TOGGLE' "$SHORTCUTS" || fail 'shortcut action'
grep -q 'android:targetPackage="com.lixkrt.hotspotplus"' "$SHORTCUTS" || fail 'shortcut package'
grep -q 'android:targetClass="com.lixkrt.hotspotplus.ToggleActivity"' "$SHORTCUTS" || fail 'shortcut class'

grep -q "typeof window\.ksu\.exec === 'function'" "$WEB" || fail 'bridge feature detection'
grep -q 'exec(`${HSP} ${args}`' "$WEB" || fail 'fixed hsp command surface'
grep -q "lease stage" "$WEB" || fail 'lease stage surface'
grep -q '薄壳桥不可用' "$WEB" || fail 'degraded bridge copy'
! grep -q 'KernelSU WebUI 环境' "$WEB" || fail 'stale bridge fallback copy'
