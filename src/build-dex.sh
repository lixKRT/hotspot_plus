#!/bin/sh
# Rebuild bin/hsctl.jar from src/java (host side). Needs JDK 11+ and r8.jar from Google Maven:
#   https://dl.google.com/android/maven2/com/android/tools/r8/8.13.19/r8-8.13.19.jar
# The android/* stubs in src/stubs are compile-time only and are NOT packaged.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
R8=${R8:-/tmp/tools/r8-8.13.19.jar}
B=$(mktemp -d)
mkdir -p "$B/stubs" "$B/cls" "$B/dex"
javac --release 8 -nowarn -d "$B/stubs" "$HERE"/stubs/android/os/*.java
(cd "$B/stubs" && jar cf ../stubs.jar .)
javac --release 8 -Xlint:-options -cp "$B/stubs.jar" -d "$B/cls" "$HERE"/java/com/hsp/*.java
java -cp "$R8" com.android.tools.r8.D8 --release --min-api 30 --classpath "$B/stubs.jar" \
    --output "$B/dex" "$B"/cls/com/hsp/*.class
(cd "$B/dex" && rm -f "$HERE/../bin/hsctl.jar" && zip -q -X "$HERE/../bin/hsctl.jar" classes.dex)
rm -rf "$B"
echo "built $HERE/../bin/hsctl.jar"
