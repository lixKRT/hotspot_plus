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
    "$APP/src/com/lixkrt/hotspotplus/BridgeCommands.java" \
    "$APP/src/com/lixkrt/hotspotplus/RootShell.java" \
    "$HERE/policy/WebPolicyTest.java" \
    "$HERE/policy/CommandPolicyTest.java" \
    "$HERE/policy/BridgeDispatchTest.java" \
    "$HERE/policy/RootShellFramingTest.java" \
    "$HERE/policy/DispatchIntegrationTest.java"
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.WebPolicyTest
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.CommandPolicyTest
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.BridgeDispatchTest
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.RootShellFramingTest
"$JAVA" -cp "$OUT" com.lixkrt.hotspotplus.DispatchIntegrationTest
sh "$HERE/manifest_invariants.sh"
sh "$HERE/build_policy.sh"
