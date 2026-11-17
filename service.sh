#!/system/bin/sh
# late_start service: start the watcher daemon after boot completes.
MODDIR=${0%/*}
DATA=/data/adb/hotspot_plus
mkdir -p "$DATA/run" "$DATA/logs"
rm -f "$DATA/run/"*.pid "$DATA/run/ev" "$DATA/run/fw_ok" "$DATA/run/session" "$DATA/run/gateway" "$DATA/run/enforce_broken" "$DATA/run/op.lock" "$DATA/run/op.holder" "$DATA/run/"hsctl.*.out "$DATA/boot.done" 2>/dev/null
rmdir "$DATA/run/op.lockdir" 2>/dev/null
(
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
    sleep 8
    sh "$MODDIR/bin/hsp" daemon start > /dev/null 2>> "$DATA/logs/hsp.log"
    sleep 12
    sh "$MODDIR/bin/hsp" boot-auto > /dev/null 2>> "$DATA/logs/hsp.log"
) &
