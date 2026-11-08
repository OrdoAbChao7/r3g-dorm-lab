#!/bin/sh
# Roll back the router-global mihomo proxy to the pre-install state.
# Usage: rollback_router_proxy.sh <backup-dir printed by the installer>
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <backup-dir>" >&2; exit 2; }
BK=$1
[ -d "$BK" ] || { echo "backup dir not found: $BK" >&2; exit 1; }

/etc/init.d/mihomo stop 2>/dev/null || true
/etc/init.d/mihomo disable 2>/dev/null || true
ip link delete utun 2>/dev/null || true

if [ -f "$BK/dhcp" ]; then
	cp -a "$BK/dhcp" /etc/config/dhcp
fi
if [ -f "$BK/firewall" ]; then
	cp -a "$BK/firewall" /etc/config/firewall
fi
/etc/init.d/dnsmasq restart

rm -f /etc/init.d/mihomo /usr/bin/mihomo
rm -rf /etc/mihomo

echo "rolled back from $BK; reboot recommended to clear any residual routes"
