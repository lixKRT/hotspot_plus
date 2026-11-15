# shellcheck shell=sh
# Versioned, checksummed user-asset bundles: configuration and static leases only.
# Runtime leases, PIDs, locks, sockets, temp files and logs are never inputs (ADR-0008).

BACKUP_FORMAT=hotspot_plus_backup
BACKUP_FORMAT_VERSION=1
BACKUP_DIR=${HSP_BACKUP_DIR:-/data/adb/hotspot_plus_backups}
BACKUP_PROMPT_STATE=$DATA/.restore_prompt
BACKUP_DEFAULT_MARKER=$DATA/.config_default
BACKUP_EXPORT_DIR=${HSP_EXPORT_DIR:-/sdcard/Download}
BACKUP_RETRIES=${HSP_BACKUP_RETRIES:-3}
BACKUP_LOG=$DATA/../hotspot_plus_backup.log

backup_sha256() { # file
    if [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx sha256sum; then
        "$BB" sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx sha256sum; then
        busybox sha256sum "$1" 2>/dev/null | awk '{print $1}'
    fi
}

backup_payload_sum() { # dir -> deterministic checksum over manifest fields + payload files
    _bp=$1
    {
        sed -n '/^format=/p;/^format_version=/p;/^module_version=/p;/^created_at=/p;/^android_build=/p' "$_bp/manifest" 2>/dev/null
        echo '--- config.conf'
        cat "$_bp/config.conf" 2>/dev/null
        echo '--- leases.conf'
        cat "$_bp/leases.conf" 2>/dev/null
    } > "$_bp/.sum.$$" 2>/dev/null || return 1
    backup_sha256 "$_bp/.sum.$$"
    _rc=$?
    rm -f "$_bp/.sum.$$"
    return $_rc
}

backup_is_root() { [ "$(id -u 2>/dev/null)" = 0 ]; }

backup_path_safe() { # path must stay below BACKUP_DIR and contain no newline/control bytes
    case "$1" in ''|*"$nl"*|*[[:cntrl:]]*) return 1 ;; esac
    case "$1" in "$BACKUP_DIR"/*) return 0 ;; esac
    # Allow an explicit restore/validation source outside BACKUP_DIR (e.g. an exported copy)
    [ -d "$1" ] && [ -f "$1/manifest" ]
}

backup_validate() { # dir -> prints reasons; rc 1 if invalid
    _bd=$1
    _bad=""
    [ -d "$_bd" ] || { echo "备份目录不存在: $_bd"; return 1; }
    [ -f "$_bd/manifest" ] || { echo "备份包缺少 manifest"; return 1; }
    for _bf in config.conf leases.conf; do
        [ -e "$_bd/$_bf" ] || { echo "备份包缺少 $_bf"; return 1; }
        [ -L "$_bd/$_bf" ] && { echo "备份包包含符号链接: $_bf"; return 1; }
        [ -f "$_bd/$_bf" ] || { echo "备份包包含非普通文件: $_bf"; return 1; }
        [ -r "$_bd/$_bf" ] || { echo "备份包文件不可读: $_bf"; return 1; }
    done
    _fmt=$(sed -n 's/^format=//p' "$_bd/manifest" | head -n1)
    _ver=$(sed -n 's/^format_version=//p' "$_bd/manifest" | head -n1)
    _unk=$(grep -vE '^(format|format_version|module_version|created_at|android_build|sha256)=' "$_bd/manifest" | head -n1)
    _mv=$(sed -n 's/^module_version=//p' "$_bd/manifest" | head -n1)
    _ca=$(sed -n 's/^created_at=//p' "$_bd/manifest" | head -n1)
    _ab=$(sed -n 's/^android_build=//p' "$_bd/manifest" | head -n1)
    _sum=$(sed -n 's/^sha256=//p' "$_bd/manifest" | head -n1)
    [ "$_fmt" = "$BACKUP_FORMAT" ] || _bad="$_bad 格式不兼容"
    [ "$_ver" = "$BACKUP_FORMAT_VERSION" ] || _bad="$_bad 备份格式版本不兼容 ($_ver)"
    [ -n "$_mv" ] || _bad="$_bad 缺 module_version"
    [ -n "$_ca" ] || _bad="$_bad 缺 created_at"
    [ -n "$_ab" ] || _bad="$_bad 缺 android_build"
    [ -n "$_sum" ] || _bad="$_bad 缺 sha256 校验和"
    [ -z "$_unk" ] || _bad="$_bad 含未知字段: $_unk"
    if [ -z "$_bad" ]; then
        _calc=$(backup_payload_sum "$_bd") || _bad="$_bad 无法计算校验和"
        [ "$_calc" = "$_sum" ] || _bad="$_bad 校验和不匹配（备份已损坏或被修改）"
    fi
    if [ -n "$_bad" ]; then
        echo "备份无效:$_bad"
        return 1
    fi
    return 0
}

backup_config_sane() { # file -> 0 if the shell config is free of commands/redirections
    ! grep -qE '[$`;|&<>]' "$1" &&
        ! grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[^=[:space:]]' "$1" &&
        ! grep -qE '^[[:space:]]*(reboot|su|sh|exec|eval|source|\.)[[:space:]]*$' "$1"
}

backup_leases_sane() { # file -> 0 if every non-comment line is "mac ip [remark]"
    awk '
        /^[[:space:]]*(#|$)/ { next }
        NF < 2 { bad = 1 }
        {
          x = tolower($1); gsub(/-/, ":", x)
          n = split(x, p, ":")
          if (n != 6) { bad = 1; next }
          for (i = 1; i <= 6; i++) if (length(p[i]) != 2) bad = 1
        }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

backup_real_path() { # path -> canonical absolute path even if the leaf does not exist yet
    _brp=$1
    _brp_tail=""
    while [ ! -d "$_brp" ] && [ "$_brp" != "/" ] && [ "$_brp" != "." ]; do
        _brp_tail="/${_brp##*/}$_brp_tail"
        _brp=${_brp%/*}
        [ -n "$_brp" ] || _brp=/
    done
    _brp_base=$(cd "$_brp" 2>/dev/null && pwd -P) || _brp_base=$_brp
    if [ "$_brp_base" = "/" ]; then echo "/${_brp_tail#/}"; else echo "$_brp_base$_brp_tail"; fi
}

backup_create() { # [destdir] -> prints bundle path
    _dest=${1:-$BACKUP_DIR}
    [ -f "$CONF" ] || { echo "备份失败：缺少 $CONF" >&2; return 1; }
    [ -f "$LEASES" ] || { echo "备份失败：缺少 $LEASES" >&2; return 1; }
    _data_real=$(cd "$DATA" 2>/dev/null && pwd -P)
    _dest_real=$(backup_real_path "$_dest")
    case "$_dest_real/" in
        "$_data_real/"*) echo "备份失败：备份目录必须在模块数据目录之外（$_dest）" >&2; return 1 ;;
    esac
    mkdir -p "$_dest" 2>/dev/null || { echo "备份失败：无法创建 $_dest" >&2; return 1; }
    chmod 700 "$_dest" 2>/dev/null
    _ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | tr -d '\r')
    [ -n "$_ver" ] || _ver=${HSP_MODULE_VERSION:-unknown}
    _build=${HSP_DEVICE_BUILD:-$(getprop ro.build.display.id 2>/dev/null)}
    [ -n "$_build" ] || _build=unknown
    _now=${HSP_NOW:-$(date +%s)}
    _name=${_now}-${_ver#v}
    _out=$_dest/$_name
    _i=1
    while [ -e "$_out" ]; do _out=$_dest/$_name-$_i; _i=$((_i+1)); done
    (umask 077; mkdir -p "$_out") || { echo "备份失败：无法创建 $_out" >&2; return 1; }
    chmod 700 "$_out" 2>/dev/null
    (umask 077; cp "$CONF" "$_out/config.conf") || { rm -rf "$_out"; return 1; }
    (umask 077; cp "$LEASES" "$_out/leases.conf") || { rm -rf "$_out"; return 1; }
    chmod 600 "$_out/config.conf" "$_out/leases.conf" 2>/dev/null
    {
        printf 'format=%s\n' "$BACKUP_FORMAT"
        printf 'format_version=%s\n' "$BACKUP_FORMAT_VERSION"
        printf 'module_version=%s\n' "$_ver"
        printf 'created_at=%s\n' "$_now"
        printf 'android_build=%s\n' "$_build"
    } > "$_out/manifest"
    _sum=$(backup_payload_sum "$_out") || { rm -rf "$_out"; return 1; }
    printf 'sha256=%s\n' "$_sum" >> "$_out/manifest"
    chmod 600 "$_out/manifest" 2>/dev/null
    echo "$_out"
}

backup_create_retry() { # attempts -> bundle path; loud errors after exhaustion
    _tries=${1:-$BACKUP_RETRIES}
    case "$_tries" in ''|*[!0-9]*|0) _tries=1 ;; esac
    _i=1
    _last=""
    while [ "$_i" -le "$_tries" ]; do
        _bp=$(backup_create 2>&1) && { echo "$_bp"; return 0; }
        _last=$_bp
        log "backup attempt $_i/$_tries failed: $_bp"
        [ "$_i" -lt "$_tries" ] && sleep "${HSP_BACKUP_RETRY_WAIT:-1}"
        _i=$((_i+1))
    done
    mkdir -p "$(dirname "$BACKUP_LOG")" 2>/dev/null
    {
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: 备份失败，已重试 $((_tries - 1)) 次"
        echo "  数据目录: $DATA"
        echo "  备份目录: $BACKUP_DIR"
        echo "  请先运行 hsp backup 或修好备份目录后再移除模块"
        [ -n "$_last" ] && echo "  最近错误: $_last"
    } >> "$BACKUP_LOG" 2>/dev/null
    echo "ERROR: 备份失败: ${_last:-未知错误}" >&2
    echo "  日志: $BACKUP_LOG" >&2
    return 1
}

backup_list() {
    [ -d "$BACKUP_DIR" ] || return 0
    for _bd in "$BACKUP_DIR"/*; do
        [ -d "$_bd" ] || continue
        backup_validate "$_bd" >/dev/null 2>&1 || continue
        _ver=$(sed -n 's/^module_version=//p' "$_bd/manifest" | head -n1)
        _at=$(sed -n 's/^created_at=//p' "$_bd/manifest" | head -n1)
        printf '%s\t%s\t%s\n' "${_bd##*/}" "$_at" "$_ver"
    done
}

backup_restore() { # dir
    _bd=$1
    [ -n "$_bd" ] || { echo "用法: hsp restore <备份目录> --yes"; return 1; }
    backup_validate "$_bd" || return 1
    backup_config_sane "$_bd/config.conf" || { echo "备份无效: 配置含可疑内容"; return 1; }
    backup_leases_sane "$_bd/leases.conf" || { echo "备份无效: 静态租约格式不正确"; return 1; }
    _tmpc=$RUN/config.restore.$$
    _tmpl=$RUN/leases.restore.$$
    cp "$_bd/config.conf" "$_tmpc" || return 1
    cp "$_bd/leases.conf" "$_tmpl" || return 1
    mv -f "$_tmpc" "$CONF" && mv -f "$_tmpl" "$LEASES" || return 1
    chmod 700 "$DATA" 2>/dev/null
    chmod 600 "$CONF" "$LEASES" 2>/dev/null
    rm -f "$BACKUP_DEFAULT_MARKER" "$BACKUP_PROMPT_STATE"
    echo "已恢复: $_bd"
}

backup_dismiss() {
    mkdir -p "$DATA" 2>/dev/null
    printf '%s\n' "$(date +%s)" > "$BACKUP_PROMPT_STATE"
    chmod 600 "$BACKUP_PROMPT_STATE" 2>/dev/null
}

# A prompt is offered only when no user configuration exists and a valid bundle is present.
backup_prompt() {
    _fresh=0
    if [ ! -f "$CONF" ]; then
        _fresh=1
    elif [ -f "$BACKUP_DEFAULT_MARKER" ]; then
        _fresh=1
    fi
    [ "$_fresh" = 1 ] || { echo "prompt=0"; return 0; }
    [ -f "$BACKUP_PROMPT_STATE" ] && { echo "prompt=0"; return 0; }
    _any=""
    [ -d "$BACKUP_DIR" ] && for _bd in "$BACKUP_DIR"/*; do
        [ -d "$_bd" ] || continue
        backup_validate "$_bd" >/dev/null 2>&1 || continue
        _any=$_bd
    done
    [ -n "$_any" ] || { echo "prompt=0"; return 0; }
    echo "prompt=1"
    echo "count=$(backup_list | wc -l | tr -d ' ')"
    echo "latest=$_any"
}

backup_export() { # dir [outdir]
    _bd=$1
    _od=${2:-$BACKUP_EXPORT_DIR}
    backup_validate "$_bd" || return 1
    mkdir -p "$_od" 2>/dev/null || { echo "导出失败：无法创建 $_od"; return 1; }
    _tar=$_od/${_bd##*/}.tar.gz
    (cd "$(dirname "$_bd")" && tar -czf "$_tar" "${_bd##*/}") || { rm -f "$_tar"; echo "导出失败"; return 1; }
    chmod 600 "$_tar" 2>/dev/null
    echo "已导出: $_tar"
}
