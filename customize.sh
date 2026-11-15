# shellcheck shell=sh
# Magisk / KernelSU installer hook (sourced). Variables: MODPATH API ARCH and the manager's
# optional KSU/KSU_VER; installation must also work when those are unset (Magisk).
# shellcheck disable=SC2034
SKIPUNZIP=0
DATA=/data/adb/hotspot_plus

_hsp_ver=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | tr -d '\r')
_hsp_release=$(getprop ro.build.version.release 2>/dev/null)
_hsp_mi=$(getprop ro.mi.os.version.incremental 2>/dev/null)

ui_print "- Hotspot Plus 热点增强 ${_hsp_ver:-unknown} (hotspot_plus)"
ui_print "- 设备: $(getprop ro.product.marketname 2>/dev/null || getprop ro.product.model)"
ui_print "- Android ${_hsp_release:-unknown} (API ${API:-unknown})  HyperOS ${_hsp_mi:-unknown}"
ui_print "- 架构: ${ARCH:-unknown}"
if [ "$KSU" = true ]; then
    ui_print "- 管理器: KernelSU ${KSU_VER:-unknown}"
else
    ui_print "- 管理器: Magisk"
fi

if [ "${API:-0}" -lt 30 ] 2>/dev/null; then
    abort "! 需要 Android 11 (API 30) 及以上"
fi
[ "$ARCH" = arm64 ] || ui_print "! 警告：非 arm64 ($ARCH)，未测试"

BB=""
if [ -n "$HSCTL_BUSYBOX" ]; then
    [ -x "$HSCTL_BUSYBOX" ] && BB=$HSCTL_BUSYBOX
fi
for p in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -n "$BB" ] && break
    [ -x "$p" ] && { BB=$p; break; }
done
if [ -n "$BB" ] && "$BB" --list | grep -qx udhcpd; then
    ui_print "- busybox: $BB udhcpd: 可用"
else
    ui_print "! busybox udhcpd: 不可用（未找到带 udhcpd 的 busybox）"
    ui_print "! 静态租约/固定网关将不可用，仅保留开关与设备列表"
fi

HSP_DATA=${HSP_DATA:-$DATA}
mkdir -p "$HSP_DATA/run" "$HSP_DATA/logs"
if [ ! -f "$HSP_DATA/config.conf" ]; then
    cp "$MODPATH/defaults/config.conf" "$HSP_DATA/config.conf"
    ui_print "- 已创建默认配置 $HSP_DATA/config.conf (网关 192.168.42.1/24)"
else
    ui_print "- 保留已有配置 $HSP_DATA/config.conf（不改写用户设置）"
fi
if [ ! -f "$HSP_DATA/leases.conf" ]; then
    cp "$MODPATH/defaults/leases.conf" "$HSP_DATA/leases.conf"
    ui_print "- 已创建静态租约文件 $HSP_DATA/leases.conf"
else
    ui_print "- 保留已有静态租约 $HSP_DATA/leases.conf"
fi
chmod 700 "$HSP_DATA"

# ---------------------------------------------------------------- launcher app 「热点增强」
install_app() {
    _apk=$MODPATH/app/hotspot_plus.apk
    if [ ! -f "$_apk" ]; then
        ui_print "- 未包含启动器 App（模块功能可用，安装 App 请使用带 App 的发行包）"
        return 0
    fi
    if [ -n "$HSP_INSTALLER_DRY_RUN" ]; then
        ui_print "- 预览：跳过 App 安装（$_apk）"
        return 0
    fi
    _t=""; command -v timeout >/dev/null 2>&1 && _t="timeout 120"
    # system_server must be able to read the file: /data/adb is not readable for it, use /data/local/tmp
    _tmp=/data/local/tmp/hotspot_plus.apk
    _out=""
    if cp -f "$_apk" "$_tmp" 2>/dev/null && chmod 644 "$_tmp"; then
        _out=$($_t pm install -r "$_tmp" 2>&1)
    fi
    if ! echo "$_out" | grep -q Success; then
        # fallback: stream the APK through stdin
        _out="$_out / $($_t pm install -r -S "$(wc -c < "$_apk")" < "$_apk" 2>&1)"
    fi
    rm -f "$_tmp"
    if echo "$_out" | grep -q Success; then
        ui_print "- 已安装/更新 App「热点增强」(com.hsp.hotspotplus)"
        ui_print "  首次打开时请在 Magisk 或 KernelSU 管理器 →「超级用户」里给「热点增强」授权 root"
    else
        ui_print "! 自动安装 App 失败: $(echo "$_out" | tr '\n' ' ' | cut -c1-200)"
        mkdir -p /sdcard/Download 2>/dev/null
        if cp -f "$_apk" /sdcard/Download/hotspot_plus.apk 2>/dev/null; then
            ui_print "  已复制到 /sdcard/Download/hotspot_plus.apk，请用文件管理器手动安装"
        else
            ui_print "  请手动安装模块内的 $MODPATH/app/hotspot_plus.apk"
        fi
        echo "$_out" | grep -q UPDATE_INCOMPATIBLE && ui_print "  (签名不一致：请先卸载旧的「热点增强」App 再装)"
    fi
}
install_app

[ -n "$HSP_INSTALLER_DRY_RUN" ] || {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm "$MODPATH/bin/hsp" 0 0 0755
    set_perm "$MODPATH/bin/hspd" 0 0 0755
    set_perm "$MODPATH/diag.sh" 0 0 0755
    # app_process refuses writable dex/jar on newer Android (W^X for code loading): keep it read-only
    set_perm "$MODPATH/bin/hsctl.jar" 0 0 0444
}

ui_print "- 安装完成。重启后生效；之后打开桌面上的「热点增强」App，或在模块管理器中打开本模块 WebUI。"
ui_print "- 命令行: su -c /data/adb/modules/hotspot_plus/bin/hsp status"
