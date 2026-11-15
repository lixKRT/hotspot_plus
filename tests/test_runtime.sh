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

strict_ipv4() {
    . "$ROOT/lib/common.sh"
    is_ipv4 192.168.42.1 &&
        is_ipv4 0.0.0.0 &&
        is_ipv4 255.255.255.255 &&
        ! is_ipv4 192.168.042.1 &&
        ! is_ipv4 192.168.42.256 &&
        ! is_ipv4 192.168.42.1.5 &&
        ! is_ipv4 192.168.42 &&
        ! is_ipv4 '192.168.42.1;reboot'
}

private_subnet() {
    . "$ROOT/lib/common.sh"
    is_private_ipv4 10.1.2.3 &&
        is_private_ipv4 172.16.0.1 &&
        is_private_ipv4 172.31.255.254 &&
        is_private_ipv4 192.168.42.10 &&
        ! is_private_ipv4 172.32.0.1 &&
        ! is_private_ipv4 8.8.8.8
}

mkdir -p "$TMPROOT/data/run" "$TMPROOT/data/logs"

run_case "prefix mask /24" mask_pfx_24
run_case "prefix mask /28" mask_pfx_28
run_case "private range mapping" map_range
run_case "strict IPv4 parsing" strict_ipv4
run_case "private IPv4 ranges" private_subnet
