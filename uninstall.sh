#!/system/bin/sh
# Runs when the module is removed. Firewall rules / udhcpd do not survive a reboot, but clean up anyway.
IPT=/system/bin/iptables
while $IPT -w -D OUTPUT -j hsp_dhcp 2>/dev/null; do :; done
$IPT -w -F hsp_dhcp 2>/dev/null
$IPT -w -X hsp_dhcp 2>/dev/null
for f in /data/adb/hotspot_plus/run/*.pid; do
    [ -f "$f" ] || continue
    read -r p < "$f"
    [ -n "$p" ] && kill "$p" 2>/dev/null
done
rm -rf /data/adb/hotspot_plus
