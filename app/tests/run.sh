#!/bin/sh
# Host-runnable app checks. Android SDK is not required.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/.." && pwd)
OUT=${HSP_TEST_CLASSES:-$APP/build/test-classes}
JAVAC=${JAVAC:-javac}
JAVA=${JAVA:-java}

rm -rf "$OUT"
mkdir -p "$OUT"
"$JAVAC" -encoding UTF-8 -d "$OUT" \
    "$APP/src/com/lixkrt/hotspotplus/WebPolicy.java" \
    "$APP/src/com/lixkrt/hotspotplus/CommandPolicy.java" \
    "$HERE/policy/WebPolicyTest.java" \
    "$HERE/policy/CommandPolicyTest.java"
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.WebPolicyTest
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.CommandPolicyTest
sh "$HERE/manifest_invariants.sh"
sh "$HERE/build_policy.sh"
