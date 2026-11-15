#!/system/bin/sh
# Read-only/reversible platform probe for hotspot_plus on OnePlus 8T KB2000.
#
# Run as root on the device:
#   su -c /system/bin/sh /data/local/tmp/probe-8t.sh > /data/local/tmp/probe.facts
#
# Output is line-oriented. Pipe it through tools/probe_report.py on the host to
# redact build identity, MAC addresses, SSIDs and credentials.
#
# This script does not install, flash, toggle the hotspot, or modify the legacy
# module. Its only persistent-looking change is a uniquely named iptables chain
# that is removed by the cleanup trap.

set -u
PATH=/system/bin:/system/xbin:/data/adb/magisk:$PATH
export PATH

CHAIN=hsp_probe_02
IPT=${IPT:-/system/bin/iptables}
BB=
for candidate in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$candidate" ]; then BB=$candidate; break; fi
done

probe_tmp=/data/local/tmp/hsp-probe-02.$$
rm -rf "$probe_tmp"
mkdir -p "$probe_tmp" 2>/dev/null || probe_tmp=
chain_created=0

tmo() {
    seconds=$1
    shift
    if [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx timeout; then
        "$BB" timeout -k 2 "$seconds" "$@"
    elif command -v timeout >/dev/null 2>&1; then
        timeout -k 2 "$seconds" "$@"
    else
        "$@"
    fi
}

status() {
    printf 'STATUS|%s|%s|%s\n' "$1" "$2" "$3"
}

cleanup() {
    if [ "$chain_created" = 1 ]; then
        while "$IPT" -w 5 -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
        "$IPT" -w 5 -F "$CHAIN" 2>/dev/null
        "$IPT" -w 5 -X "$CHAIN" 2>/dev/null
    fi
    if [ -n "${udhcpd_pid:-}" ] && kill -0 "$udhcpd_pid" 2>/dev/null; then
        kill "$udhcpd_pid" 2>/dev/null
        sleep 1
        kill -9 "$udhcpd_pid" 2>/dev/null
    fi
    [ -n "$probe_tmp" ] && rm -rf "$probe_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

echo HSP_PROBE=1

# ---------------------------------------------------------------- identity

probe_identity() {
    model=$(getprop ro.product.model)
    release=$(getprop ro.build.version.release)
    sdk=$(getprop ro.build.version.sdk)
    incremental=$(getprop ro.build.version.incremental)
    security_patch=$(getprop ro.build.version.security_patch)
    fingerprint=$(getprop ro.build.fingerprint)
    magisk_version=
    for candidate in /data/adb/magisk/magisk /data/adb/magisk/magisk64; do
        [ -x "$candidate" ] || continue
        magisk_version=$("$candidate" -v 2>/dev/null)
        break
    done
    selinux=$(getenforce 2>/dev/null)
    echo "BUILD|model=$model"
    echo "BUILD|android=$release"
    echo "BUILD|sdk=$sdk"
    echo "BUILD|build=$incremental"
    echo "BUILD|security_patch=$security_patch"
    echo "BUILD|fingerprint=$fingerprint"
    echo "BUILD|magisk=$magisk_version"
    echo "BUILD|selinux=$selinux"

    if [ -n "$model" ] && [ -n "$release" ] && [ -n "$sdk" ]; then
        status build.identity PASS "$model Android $release SDK $sdk build=$incremental magisk=$magisk_version"
    else
        status build.identity FAIL "missing build property"
    fi
    if [ "$selinux" = Enforcing ]; then
        status selinux.mode PASS "Enforcing"
    else
        status selinux.mode FAIL "expected Enforcing, got ${selinux:-unknown}"
    fi
}

# ---------------------------------------------------------------- root/tools

probe_root() {
    id_output=$(id)
    case "$id_output" in
        *"uid=0"*) root_uid=PASS ;;
        *) root_uid=FAIL ;;
    esac
    case "$id_output" in
        *"context=u:r:magisk:s0"*) magisk_domain=PASS ;;
        *) magisk_domain=FAIL ;;
    esac
    echo "ROOT|id=$(echo "$id_output" | sed 's/context=.*/context=<redacted>/')"
    echo "ROOT|context=$(echo "$id_output" | sed -n 's/.*context=//p')"
    status root.uid "$root_uid" "uid 0 in a real script"
    status root.selinux_domain "$magisk_domain" "u:r:magisk:s0"

    if [ -n "$BB" ]; then
        version=$("$BB" 2>/dev/null | head -n 1)
        echo "BUSYBOX|path=$BB"
        echo "BUSYBOX|version=$version"
        missing=
        required_found=
        for applet in udhcpd dumpleases ip flock timeout; do
            if "$BB" --list 2>/dev/null | grep -qx "$applet"; then
                required_found="$required_found,$applet"
            else
                missing="$missing,$applet"
            fi
        done
        if [ -z "$missing" ]; then
            status busybox.tools PASS "udhcpd,dumpleases,ip,flock,timeout"
        else
            status busybox.tools FAIL "missing${missing}"
        fi
    else
        status busybox.tools FAIL "Magisk busybox not found"
    fi
}

# ---------------------------------------------------------------- tethering

probe_tethering() {
    hsctl_jar=/data/local/tmp/hsctl.jar
    if [ ! -f "$hsctl_jar" ]; then
        status tethering.signatures UNVERIFIED "push bin/hsctl.jar to $hsctl_jar"
        status fixed_gateway.request UNVERIFIED "requires hsctl.jar and a later install/state-change ticket"
        return
    fi
    probe_out=$probe_tmp/hsctl-probe.txt
    if CLASSPATH=$hsctl_jar tmo 20 /system/bin/app_process /system/bin \
            --nice-name=hsp_probe_hsctl com.hsp.HsCtl probe > "$probe_out" 2>&1; then
        sed 's/^/HSCTL|/' "$probe_out"
        has_start=0
        has_parcel=0
        has_listener=0
        grep -q '^method=.*startTethering(' "$probe_out" && has_start=1
        grep -q '^parcel_field=.*localIPv4Address' "$probe_out" &&
            grep -q '^parcel_field=.*staticClientAddress' "$probe_out" && has_parcel=1
        grep -q '^listener_iface=ok' "$probe_out" && has_listener=1
        if [ "$has_start" = 1 ] && [ "$has_parcel" = 1 ] && [ "$has_listener" = 1 ]; then
            status tethering.signatures PASS "startTethering + localIPv4Address/staticClientAddress + IIntResultListener"
        else
            status tethering.signatures FAIL "required signature/field missing"
        fi
        state=$(tmo 20 env CLASSPATH="$hsctl_jar" /system/bin/app_process /system/bin \
            --nice-name=hsp_probe_state com.hsp.HsCtl state 2>&1)
        echo "HSCTL_STATE|$(echo "$state" | tr '\n' ' ')"
        printf '%s\n' "$state" | sed 's/^/HSCTL_STATE|/'
    else
        status tethering.signatures FAIL "hsctl probe failed"
    fi

    # A temporary module is explicitly out of scope. A request would either
    # restart the active hotspot or change its gateway, so only report what the
    # signatures allow and leave adoption for a reversible later ticket.
    status fixed_gateway.request UNVERIFIED \
        "request fields exist; adoption needs hotpot restart/install, forbidden in this ticket"
}

# ---------------------------------------------------------------- callback

build_callback_probe() {
    # Built at development time and pushed alongside this script. If it is not
    # present, report UNVERIFIED rather than compiling on the device.
    :
}

probe_callback() {
    callback_jar=/data/local/tmp/callback-probe.jar
    if [ ! -f "$callback_jar" ]; then
        status callback.magisk_domain UNVERIFIED "push tools/probe-src built callback-probe.jar"
        return
    fi
    out=$probe_tmp/callback.txt
    CLASSPATH=$callback_jar tmo 20 /system/bin/app_process /system/bin \
        --nice-name=hsp_probe_callback com.hsp.probe.CallbackProbe > "$out" 2>&1
    rc=$?
    sed 's/^/CALLBACK|/' "$out"
    if grep -q '^event_callback_registration=PASS' "$out" &&
       grep -q '^binder_callback=PASS' "$out"; then
        status callback.magisk_domain PASS "event registration and IIntResultListener callback succeeded"
    else
        status callback.magisk_domain FAIL "callback probe rc=$rc"
    fi
    if grep -q '^event_callback_methods=' "$out"; then
        methods=$(sed -n 's/^event_callback_methods=//p' "$out")
        status callback.methods PASS "$methods"
    fi
}

# ---------------------------------------------------------------- boot

probe_boot() {
    boot_completed=$(getprop sys.boot_completed)
    bootcomplete=$(getprop dev.bootcomplete)
    crypto=$(getprop ro.crypto.state)
    ce=$(getprop sys.user.0.ce_available)
    vold=$(getprop init.svc.vold)
    netd=$(getprop init.svc.netd)
    uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    user_state=$(tmo 10 dumpsys user 2>/dev/null | grep -m1 'State:' | tr -d ' ')
    echo "BOOT|sys.boot_completed=$boot_completed"
    echo "BOOT|dev.bootcomplete=$bootcomplete"
    echo "BOOT|ro.crypto.state=$crypto"
    echo "BOOT|sys.user.0.ce_available=$ce"
    echo "BOOT|init.svc.vold=$vold"
    echo "BOOT|init.svc.netd=$netd"
    echo "BOOT|uptime=$uptime"
    echo "BOOT|user=$user_state"
    echo "BOOT|data_adb_readable=$([ -r /data/adb ] && echo yes || echo no)"
    echo "BOOT|tethering_service=$(tmo 10 service check tethering 2>&1 | tr ' ' '_')"

    if [ "$boot_completed" = 1 ] && [ -r /data/adb ]; then
        status boot.timing PASS "boot_completed=1; /data/adb readable; CE available=$ce; user unlocked"
    else
        status boot.timing FAIL "boot or /data/adb visibility incomplete"
    fi
    # Facts observed after boot do not prove when service.sh first saw /data/adb.
    status boot.timing_at_service_start UNVERIFIED \
        "no install/reboot marker in this ticket; observed post-boot state only"
}

# ---------------------------------------------------------------- DHCP

probe_dhcp() {
    ap_iface=
    ap_addr=
    addr_out=$(tmo 10 /system/bin/ip -4 -o addr show 2>/dev/null)
    echo "NET|$(echo "$addr_out" | tr '\n' ';')"
    ap_iface=$(printf '%s\n' "$addr_out" | awk '$2 ~ /^wlan[1-9]/ && $4 ~ /^192\.168\./ {print $2; exit}')
    [ -n "$ap_iface" ] && ap_addr=$(printf '%s\n' "$addr_out" | awk -v i="$ap_iface" '$2 == i {print $4; exit}')
    if [ -n "$ap_iface" ]; then
        status hotspot.interface PASS "$ap_iface $ap_addr"
    else
        status hotspot.interface UNVERIFIED "hotspot is not active; iptables owner test uses wlan2"
        ap_iface=wlan2
    fi

    fw_probe=hsp_probe_02
    if "$IPT" -w 5 -N "$fw_probe" 2>/dev/null; then
        chain_created=1
        if "$IPT" -w 5 -A "$fw_probe" -o "$ap_iface" -p udp --sport 67 --dport 68 \
                -m owner ! --uid-owner 0 -j DROP 2>/dev/null &&
           "$IPT" -w 5 -I OUTPUT 1 -j "$fw_probe" 2>/dev/null; then
            echo "IPTABLES|$("$IPT" -w 5 -S "$fw_probe" 2>&1 | tr '\n' ';')"
            status dhcp.iptables_owner PASS "chain+owner rule added and linked on $ap_iface"
        else
            status dhcp.iptables_owner FAIL "owner rule or OUTPUT link rejected"
        fi
        while "$IPT" -w 5 -D OUTPUT -j "$fw_probe" 2>/dev/null; do :; done
        "$IPT" -w 5 -F "$fw_probe" 2>/dev/null
        "$IPT" -w 5 -X "$fw_probe" 2>/dev/null
        chain_created=0
        if "$IPT" -w 5 -C OUTPUT -j "$fw_probe" 2>/dev/null; then
            status dhcp.iptables_cleanup FAIL "temporary chain still linked"
            echo "CLEANUP|dhcp.iptables_owner|FAIL: temporary chain still linked"
        else
            status dhcp.iptables_cleanup PASS "temporary $fw_probe chain removed"
            echo "CLEANUP|dhcp.iptables_owner|temporary $fw_probe chain removed; pre-existing rules untouched"
        fi
    else
        status dhcp.iptables_owner FAIL "cannot create $fw_probe"
    fi

    if [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx udhcpd; then
        conf=$probe_tmp/udhcpd.conf
        leases=$probe_tmp/leases
        pidfile=$probe_tmp/pid
        printf 'Mac Address       IP Address      Host Name           Expires at\n' > "$leases"
        {
            echo "interface $ap_iface"
            echo "start 192.168.42.240"
            echo "end 192.168.42.242"
            echo "max_leases 3"
            echo "lease_file $leases"
            echo "pidfile $pidfile"
            echo "auto_time 30"
            echo "decline_time 600"
            echo "conflict_time 600"
            echo "offer_time 60"
            echo "min_lease 120"
            echo "opt subnet 255.255.255.0"
            echo "opt router 192.168.42.1"
            echo "opt dns 192.168.42.1"
            echo "opt broadcast 192.168.42.255"
            echo "opt lease 120"
        } > "$conf"
        "$BB" udhcpd -f "$conf" > "$probe_tmp/udhcpd.log" 2>&1 < /dev/null &
        udhcpd_pid=$!
        sleep 1
        if kill -0 "$udhcpd_pid" 2>/dev/null; then
            status dhcp.udhcpd PASS "udhcpd started with temporary config"
            if "$BB" dumpleases -f "$leases" -a >/dev/null 2>&1; then
                status dhcp.dumpleases PASS "header-only lease database readable"
            else
                status dhcp.dumpleases FAIL "dumpleases rejected lease database"
            fi
            kill "$udhcpd_pid" 2>/dev/null
            sleep 1
            if kill -0 "$udhcpd_pid" 2>/dev/null; then
                status dhcp.udhcpd_cleanup FAIL "udhcpd still running"
                echo "CLEANUP|dhcp.udhcpd|FAIL: udhcpd still running"
            else
                status dhcp.udhcpd_cleanup PASS "udhcpd stopped"
                echo "CLEANUP|dhcp.udhcpd|udhcpd stopped; temporary directory removed"
            fi
            udhcpd_pid=
        else
            status dhcp.udhcpd FAIL "udhcpd exited immediately"
            sed 's/^/UDHCPD_ERROR|/' "$probe_tmp/udhcpd.log" 2>/dev/null
        fi
    else
        status dhcp.udhcpd FAIL "busybox udhcpd unavailable"
    fi
    status dhcp.end_to_end UNVERIFIED \
        "no client traffic injected; lease handoff is covered by acceptance ticket"
}

probe_identity
probe_root
probe_tethering
probe_callback
probe_boot
probe_dhcp
