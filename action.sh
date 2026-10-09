#!/system/bin/sh
# KernelSU "Action" button: toggle the hotspot.
MODDIR=${0%/*}
echo "Hotspot Plus：切换热点…"
sh "$MODDIR/bin/hsp" toggle
echo
sh "$MODDIR/bin/hsp" status
