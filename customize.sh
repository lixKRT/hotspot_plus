# shellcheck shell=sh
# KernelSU / Magisk installer hook (sourced). Variables: MODPATH API ARCH KSU KSU_VER ...
# shellcheck disable=SC2034
SKIPUNZIP=0
DATA=/data/adb/hotspot_plus

ui_print "- Hotspot Plus 热点增强"
ui_print "- 设备: $(getprop ro.product.marketname 2>/dev/null || getprop ro.product.model)"
ui_print "- Android $(getprop ro.build.version.release) (API $API)  HyperOS $(getprop ro.mi.os.version.incremental)"
[ "$KSU" = true ] && ui_print "- KernelSU $KSU_VER"

if [ "$API" -lt 30 ]; then
    abort "! 需要 Android 11 (API 30) 及以上"
fi
[ "$ARCH" = arm64 ] || ui_print "! 警告：非 arm64 ($ARCH)，未测试"

BB=""
for p in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$p" ] && { BB=$p; break; }
done
if [ -n "$BB" ] && "$BB" --list | grep -qx udhcpd; then
    ui_print "- busybox udhcpd: 可用 ($BB)"
else
    ui_print "! 未找到带 udhcpd 的 busybox：静态租约/固定网关将不可用，仅保留开关与设备列表"
fi

mkdir -p "$DATA/run" "$DATA/logs"
if [ ! -f "$DATA/config.conf" ]; then
    cp "$MODPATH/defaults/config.conf" "$DATA/config.conf"
    ui_print "- 已创建默认配置 $DATA/config.conf"
else
    ui_print "- 保留已有配置 $DATA/config.conf"
fi
[ -f "$DATA/leases.conf" ] || cp "$MODPATH/defaults/leases.conf" "$DATA/leases.conf"
# shellcheck source=lib/migrate.sh
. "$MODPATH/lib/migrate.sh"
migrate_subnet_v020 "$DATA" | while IFS= read -r _m; do ui_print "- $_m"; done
chmod 700 "$DATA"

# ---------------------------------------------------------------- launcher app 「热点增强」
install_app() {
    _apk=$MODPATH/app/hotspot_plus.apk
    [ -f "$_apk" ] || return 0
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
        ui_print "  首次打开时请在 KernelSU 管理器 →「超级用户」里给「热点增强」授权 root"
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

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/hsp" 0 0 0755
set_perm "$MODPATH/bin/hspd" 0 0 0755
set_perm "$MODPATH/diag.sh" 0 0 0755
# app_process refuses writable dex/jar on newer Android (W^X for code loading): keep it read-only
set_perm "$MODPATH/bin/hsctl.jar" 0 0 0444

ui_print "- 安装完成。重启后生效；之后打开桌面上的「热点增强」App，或在 KernelSU 管理器中打开本模块 WebUI。"
ui_print "- 命令行: su -c /data/adb/modules/hotspot_plus/bin/hsp status"
