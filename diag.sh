#!/system/bin/sh
# hotspot_plus diagnostics. Standalone: works with or without the module installed.
#   su -c sh /path/to/diag.sh            -> writes /sdcard/Download/hotspot_plus_diag_<time>.txt
#   su -c sh /path/to/diag.sh --ui       -> also dumps the foreground activity/fragments
#                                           (open 设置 > 个人热点 > 已连接设备 first, for phase 2)
# Passphrases are masked. MAC addresses are kept (needed to debug static leases).
if [ "$(id -u)" != 0 ]; then echo "请用 root 运行: su -c sh $0"; exit 1; fi
OUTDIR=${HSP_DIAG_OUTDIR:-/sdcard/Download}
[ -d "$OUTDIR" ] || OUTDIR=/data/local/tmp
OUT=$OUTDIR/hotspot_plus_diag_$(date +%Y%m%d_%H%M%S).txt
[ -f "$MODDIR/bin/hsp" ] || MODDIR=/data/adb/modules/hotspot_plus
DATA=${HSP_DATA:-/data/adb/hotspot_plus}
IPB=/system/bin/ip
IPT=/system/bin/iptables
BB=${HSP_BUSYBOX:-}
[ -n "$BB" ] || for p in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do [ -x "$p" ] && { BB=$p; break; }; done

mask() { sed -E -e 's/([Pp]assphrase[=:" ]+)[^,}"<[:space:]]+/\1***MASKED***/g' -e 's/(<string name="Passphrase">)[^<]*/\1***MASKED***/g' -e 's/(pass_b64=).*/\1***MASKED***/'; }
sec() { echo; echo "=================== $* ==================="; }
run() { echo "\$ $*"; "$@" 2>&1 | mask; }
# T SECS CMD...: hard timeout for anything that talks to system services (never hang diag)
TMO=""
if [ -n "$BB" ] && $BB --list 2>/dev/null | grep -qx timeout; then TMO="$BB timeout -k 2"
elif command -v timeout >/dev/null 2>&1; then TMO="timeout -k 2"; fi
T() {
    _s=$1; shift
    # shellcheck disable=SC2086
    if [ -n "$TMO" ]; then $TMO "$_s" "$@"; else "$@"; fi
    _r=$?
    case $_r in 124|137|143) echo "[diag] TIMEOUT after ${_s}s: $*" ;; esac
    return $_r
}
HSCTL() { T 20 env CLASSPATH="$MODDIR/bin/hsctl.jar" /system/bin/app_process /system/bin --nice-name=hsctl com.hsp.HsCtl "$@"; }

{
sec "time / identity"
date; id; id -Z 2>/dev/null; echo "selinux: $(getenforce 2>/dev/null)"
sec "build"
for k in ro.product.model ro.product.marketname ro.product.device ro.build.version.release ro.build.version.sdk \
         ro.build.version.security_patch ro.build.fingerprint ro.mi.os.version.name ro.mi.os.version.code \
         ro.mi.os.version.incremental ro.miui.ui.version.name ro.build.version.incremental persist.sys.miui_optimization; do
    echo "$k=$(getprop $k)"
done
uname -a
sec "root / busybox"
echo "KSU: $(/data/adb/ksud -V 2>/dev/null || ksud -V 2>/dev/null)"
echo "busybox: $BB $($BB 2>/dev/null | head -n1)"
for a in udhcpd dumpleases ip flock setsid pgrep timeout base64; do
    printf '%s=' "$a"; $BB --list 2>/dev/null | grep -qx "$a" && echo yes || echo no
done
echo "system dnsmasq: $(ls -l /system/bin/dnsmasq 2>&1)"
sec "hotspot_plus processes (hsp / hsctl / app_process / udhcpd / hspd)"
run sh -c 'ps -A -o pid,ppid,user,etime,args 2>/dev/null | grep -E "PID|hsp|hsctl|app_process|udhcpd|com\.hsp" | grep -v grep'
echo "--- /proc scan (pid ppid state cmdline)  [single grep, timeout 10s]"
T 10 grep -l -a -E 'hotspot_plus|hsctl|com\.hsp\.|udhcpd|bin/hsp' /proc/[0-9]*/cmdline 2>/dev/null | while read -r f; do
    d=${f%/cmdline}
    pp=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
    st=$(awk '/^State:/{print $2}' "$d/status" 2>/dev/null)
    echo "${d#/proc/} ppid=$pp state=$st $(tr '\0' ' ' 2>/dev/null < "$d/cmdline")"
done
sec "operation lock"
echo "--- op.lock: $(ls -li "$DATA/run/op.lock" 2>&1)"
echo "--- op.lock contents:"; cat "$DATA/run/op.lock" 2>/dev/null
echo "--- op.holder (pid op epoch; now=$(date +%s)):"; cat "$DATA/run/op.holder" 2>/dev/null
echo "--- op.lockdir: $(ls -ld "$DATA/run/op.lockdir" 2>&1)"
echo "--- processes with op.lock open (pid fd : cmdline)  [single bounded ls, timeout 10s]"
# shellcheck disable=SC2010
T 10 ls -l /proc/[0-9]*/fd 2>/dev/null | awk '
    /^\/proc\/[0-9]+\/fd:$/ { split($0, a, "/"); pid = a[3]; next }
    /op\.lock/ { print pid, $(NF-2) }' | while read -r p fd; do
    echo "$p fd$fd : $(tr '\0' ' ' 2>/dev/null < "/proc/$p/cmdline")"
done
if [ -n "$BB" ] && $BB --list 2>/dev/null | grep -qx flock; then
    echo "--- busybox flock self-test (expect: -w unsupported, -n works)"
    _tf=/data/local/tmp/hsp_flock_test.$$
    : > "$_tf"
    ( exec 7>>"$_tf"; _o=$($BB flock -w 1 7 2>&1); _r=$?; echo "flock -w 1 rc=$_r: $(echo "$_o" | head -n 1)" )
    ( exec 7>>"$_tf"; _o=$($BB flock -n 7 2>&1); _r=$?; echo "flock -n rc=$_r ${_o}" )
    rm -f "$_tf"
fi
sec "tethering / wifi modules"
run sh -c 'ls -d /apex/*tether* /apex/*wifi* 2>/dev/null'
run T 15 sh -c 'pm list packages -f 2>/dev/null | grep -iE "tether|networkstack|com\.android\.wifi|resources\.overlay.*(tether|wifi)"'
for p in com.android.networkstack.tethering com.google.android.networkstack.tethering com.android.networkstack.tethering.inprocess com.google.android.networkstack.tethering.inprocess com.android.networkstack com.google.android.networkstack; do
    v=$(T 10 dumpsys package "$p" 2>/dev/null | grep -m1 versionName); [ -n "$v" ] && echo "$p $v"
done
run sh -c 'ps -A -o user,pid,ppid,label,comm 2>/dev/null | grep -iE "networkstack|tether|dnsmasq|udhcpd|hostapd|wificond|hsp|hsctl|netd" | grep -v grep'
sec "dnsmasq command line (legacy DHCP if --dhcp-range present)"
for pid in $(pidof dnsmasq 2>/dev/null); do echo "pid $pid: $(tr '\0' ' ' < "/proc/$pid/cmdline")"; done
sec "UDP sockets on 67/53 (/proc/net/udp, hex port 0043/0035)"
awk 'NR==1 || $2 ~ /:0043$|:0035$/' /proc/net/udp
run sh -c 'netstat -uanp 2>/dev/null | grep -E ":(67|53) "'
sec "interfaces"
run $IPB addr
run $IPB -4 route show table all
run $IPB rule
run $IPB neigh
run cat /proc/net/arp
sec "iptables filter"
run T 10 $IPT -w 5 -S OUTPUT
run T 10 $IPT -w 5 -S FORWARD
run T 10 $IPT -w 5 -S INPUT
run T 10 sh -c "$IPT -w 5 -S 2>/dev/null | grep -E 'hsp_|tetherctrl|oem_out|-o (wlan|ap|swlan)'"
sec "iptables nat"
run T 10 $IPT -w 5 -t nat -S
sec "iptables mangle (tether)"
run T 10 sh -c "$IPT -w 5 -t mangle -S 2>/dev/null | grep -iE 'tether|wlan|hsp'"
sec "dumpsys tethering (trimmed)"
T 15 dumpsys tethering 2>&1 | sed -n '1,/BPF offload:/p' | head -n 400 | mask
T 15 dumpsys tethering 2>&1 | grep -iE "useLegacyDhcp|legacy|DhcpServer|Tether state|TetheredState|upstream|prefix|192\.168|10\.|172\." | head -n 80 | mask
sec "dumpsys wifi: SoftAp"
T 20 dumpsys wifi 2>/dev/null | grep -iE -A25 "Dump of SoftApManager" | mask | head -n 120
T 20 dumpsys wifi 2>/dev/null | grep -iE "mApInterfaceName|getConnectedClientList|SoftApConfiguration|WifiApConfigStore|mWifiApState|softap" | mask | head -n 60
sec "saved softap config (passphrase masked)"
for x in /data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml /data/misc_ce/0/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml; do
    if [ -f "$x" ]; then echo "--- $x"; mask < "$x" | head -n 80; else echo "--- $x: (not present)"; fi
done
sec "device_config"
run T 10 sh -c 'device_config list connectivity 2>/dev/null | grep -iE "tether|dhcp"'
run T 10 sh -c 'device_config list tethering 2>/dev/null'
run T 10 sh -c 'device_config list wifi 2>/dev/null | grep -iE "softap|tether" | head -n 40'
run T 10 sh -c 'settings list global 2>/dev/null | grep -iE "tether|soft_ap|hotspot|wifi_ap"'
sec "cmd wifi"
run T 10 sh -c 'cmd wifi get-softap-supported-features 2>&1 | head'
if [ -f "$MODDIR/bin/hsctl.jar" ]; then
    sec "hsctl probe (timeout 20s)"
    HSCTL probe 2>&1 | head -n 150
    echo "probe rc=$?"
    HSCTL config 2>&1 | mask | grep -v '^ssid_b64'
fi
if [ -d "$DATA" ]; then
    sec "hotspot_plus status"
    T 40 sh "$MODDIR/bin/hsp" status 2>&1
    T 30 sh "$MODDIR/bin/hsp" clients 2>&1
    sec "hotspot_plus config"
    mask < "$DATA/config.conf" 2>/dev/null
    echo "--- leases.conf"; cat "$DATA/leases.conf" 2>/dev/null
    echo "--- udhcpd.conf"; cat "$DATA/run/udhcpd.conf" 2>/dev/null
    echo "--- dumpleases"; [ -n "$BB" ] && $BB dumpleases -f "$DATA/udhcpd.leases" 2>&1
    sec "hotspot_plus logs"
    tail -n 200 "$DATA/logs/hsp.log" 2>/dev/null
    echo "--- udhcpd.log"; tail -n 80 "$DATA/logs/udhcpd.log" 2>/dev/null
    echo "--- hsctl.err (tail)"; tail -n 120 "$DATA/logs/hsctl.err" 2>/dev/null
fi
sec "logcat (tethering / softap / dhcp)"
T 20 logcat -d -b main,system,events 2>/dev/null | grep -iE "Tethering|IpServer|DhcpServer|SoftAp|TetheringService|hsctl|WifiService.*(ap|tether)|hostapd|dnsmasq" | tail -n 300 | mask
sec "app com.hsp.hotspotplus (crash / AndroidRuntime)"
run sh -c 'pm path com.hsp.hotspotplus 2>&1; dumpsys package com.hsp.hotspotplus 2>/dev/null | grep -m3 -E "versionName|versionCode|targetSdk"'
echo "--- logcat crash buffer"
T 15 logcat -d -b crash 2>/dev/null | tail -n 400
echo "--- logcat main/system (hotspotplus / AndroidRuntime / WebView / su)"
T 20 logcat -d -b main,system 2>/dev/null | grep -iE "hotspotplus|com\.hsp|AndroidRuntime|FATAL|chromium|WebView|ksud|KernelSU" | tail -n 400
if [ "$1" = "--ui" ]; then
    sec "foreground activity (phase-2 hook target)"
    T 15 dumpsys activity top 2>/dev/null | grep -E "ACTIVITY|Fragment|mResumed|#[0-9]+:|Added Fragments|Active Fragments" | head -n 120
    T 15 dumpsys window 2>/dev/null | grep -E "mCurrentFocus|mFocusedApp" | head
    run sh -c 'pm path com.android.settings; dumpsys package com.android.settings | grep -m2 -E "versionName|versionCode"'
fi
sec "end"
} > "$OUT" 2>&1 9>&-

echo "诊断信息已写入: $OUT"
echo "（已屏蔽热点密码；包含 MAC 地址，分享前可自行检查）"
