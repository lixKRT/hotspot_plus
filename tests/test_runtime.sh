#!/bin/sh
# Runtime helper tests. Sources lib/common.sh with a temporary data directory.

mask_pfx_24() {
    . "$ROOT/lib/common.sh"
    [ "$(pfx2mask_int 24)" = "4294967040" ]
}

mask_pfx_28() {
    . "$ROOT/lib/common.sh"
    [ "$(pfx2mask_int 28)" = "4294967280" ]
}

map_range() {
    . "$ROOT/lib/common.sh"
    cfg=$(( $(ip2int 192.168.42.1) & $(pfx2mask_int 24) ))
    act=$(( $(ip2int 192.168.99.1) & $(pfx2mask_int 24) ))
    [ "$(map_ip 192.168.42.50 "$cfg" "$act" 256)" = "192.168.99.50" ]
}

mkdir -p "$TMPROOT/data/run" "$TMPROOT/data/logs"

run_case "prefix mask /24" mask_pfx_24
run_case "prefix mask /28" mask_pfx_28
run_case "private range mapping" map_range
