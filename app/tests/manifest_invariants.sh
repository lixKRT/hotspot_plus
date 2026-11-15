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
grep -q '无可信 root 桥' "$WEB" || fail 'degraded bridge copy'
! grep -q 'KernelSU WebUI 环境' "$WEB" || fail 'stale bridge fallback copy'

# User-facing copy must match the OnePlus 8T / Magisk adaptation and v0.3.0 behavior.
grep -q '一加 8T KB2000' "$WEB" || fail 'target device copy'
grep -q 'Android 16' "$WEB" || fail 'target Android copy'
grep -q 'Magisk 31.1' "$WEB" || fail 'target Magisk copy'
grep -q 'hotspot_plus v0.3.0' "$WEB" || fail 'module version copy'
grep -q 'com.lixkrt.hotspotplus' "$WEB" || fail 'app package copy'
grep -q '签名级权限保护' "$WEB" || fail 'protected shortcut copy'
grep -q '默认 192.168.42.1/24' "$WEB" || fail 'default gateway copy'
grep -q '默认关闭；仅当 AUTO_START=1' "$WEB" || fail 'auto-start default-off copy'
grep -q 'const boolOn = (v) => v === .1. || v === 1 || v === true' "$WEB" \
    || fail 'config booleans bind both string and JSON forms'
grep -q '热点仍可用' "$WEB" || fail 'DHCP degraded mode keeps hotspot usable'
grep -q '不会重启热点' "$WEB" || fail 'DHCP retry does not restart hotspot'
grep -q '不循环重启' "$WEB" || fail 'gateway repair is bounded'
grep -q '不会自动恢复' "$WEB" || fail 'restore requires confirmation'
grep -q 'Magisk 应用 →「超级用户」' "$APP/src/com/lixkrt/hotspotplus/RootShell.java" \
    || fail 'Magisk permission guidance'
! grep -q 'KernelSU 管理器' "$APP/src/com/lixkrt/hotspotplus/RootShell.java" \
    || fail 'stale KernelSU permission guidance'
grep -q '不会回退到内置副本或远程页面' "$APP/src/com/lixkrt/hotspotplus/MainActivity.java" \
    || fail 'no silent bundled-page fallback copy'

# The local document must be served through the trusted origin. A data: main
# document is rejected by the interceptor and shows ERR_INVALID_RESPONSE.
grep -q 'web.loadUrl(BASE_URL)' "$APP/src/com/lixkrt/hotspotplus/MainActivity.java" \
    || fail 'local page must load the trusted origin'
! grep -q 'loadDataWithBaseURL\|loadData(html' "$APP/src/com/lixkrt/hotspotplus/MainActivity.java" \
    || fail 'local page must not use data: document loading'
