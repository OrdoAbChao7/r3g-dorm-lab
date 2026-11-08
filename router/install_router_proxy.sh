#!/bin/sh
# Install mihomo router-global proxy on the R3G (OpenWrt 25.12.6, apk).
# Run on the router as root. Read the plan first; this is a Phase 2 change.
set -eu

usage() {
	echo "usage: $0 <mihomo-binary> <config.yaml> <GeoIP.dat> <mihomo.init>" >&2
	exit 2
}

[ $# -eq 4 ] || usage
BIN_SRC=$1
CONF_SRC=$2
GEO_SRC=$3
INIT_SRC=$4

EXPECTED_BIN_SHA256=c246ff6d3a0da9b01e75c73a04d7ce66bc8644703c8a59353d222fedadf0f362
EXPECTED_GEO_SHA256=05148054bebbeaaf0c0ab09ec8308a2448b92a4f470364a51235a068ef77a04b

[ -f "$BIN_SRC" ] || { echo "missing binary: $BIN_SRC" >&2; exit 1; }
[ -f "$CONF_SRC" ] || { echo "missing config: $CONF_SRC" >&2; exit 1; }
[ -f "$GEO_SRC" ] || { echo "missing GeoIP: $GEO_SRC" >&2; exit 1; }
[ -f "$INIT_SRC" ] || { echo "missing init script: $INIT_SRC" >&2; exit 1; }

echo "== verify hashes =="
printf '%s  %s\n' "$EXPECTED_BIN_SHA256" "$BIN_SRC" | sha256sum -c - || exit 1
printf '%s  %s\n' "$EXPECTED_GEO_SHA256" "$GEO_SRC" | sha256sum -c - || exit 1

BK=/root/backups/router-proxy-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
cp -a /etc/config/dhcp "$BK/dhcp" 2>/dev/null || true
cp -a /etc/config/firewall "$BK/firewall" 2>/dev/null || true
[ -d /etc/mihomo ] && cp -a /etc/mihomo "$BK/mihomo" || true
echo "backup=$BK"

echo "== install packages =="
apk update
apk add kmod-tun
[ -e /dev/net/tun ] || { echo "ERROR: /dev/net/tun still missing" >&2; exit 1; }

echo "== install files =="
cp "$BIN_SRC" /usr/bin/mihomo
chmod 0755 /usr/bin/mihomo
mkdir -p /etc/mihomo
cp "$CONF_SRC" /etc/mihomo/config.yaml
chmod 0600 /etc/mihomo/config.yaml
cp "$GEO_SRC" /etc/mihomo/GeoIP.dat
chmod 0644 /etc/mihomo/GeoIP.dat
cp "$INIT_SRC" /etc/init.d/mihomo
chmod 0755 /etc/init.d/mihomo
/etc/init.d/mihomo enable
/etc/init.d/mihomo start

echo "== point dnsmasq at mihomo =="
if ! uci -q get dhcp.@dnsmasq[0].server | grep -q '127.0.0.1#1053'; then
	uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053'
fi
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

echo "== done; check logread -e mihomo and ip addr show utun =="
