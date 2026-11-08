#!/bin/sh
# Roll back Phase 2.3 (MetaCubeXD + manual selection) to the pre-change config.
# Usage: rollback_phase2_3.sh [backup-dir]
set -eu

BK="${1:-/root/backups/router-proxy-phase2.3-20261107-190643}"
[ -f "$BK/config.yaml" ] || { echo "missing: $BK/config.yaml" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
if [ -f /etc/mihomo/config.yaml ]; then
	cp -a /etc/mihomo/config.yaml "/etc/mihomo/config.yaml.phase2.3-$STAMP"
fi
cp -a "$BK/config.yaml" /etc/mihomo/config.yaml
chmod 600 /etc/mihomo/config.yaml
/etc/init.d/mihomo restart

echo "restored: $BK/config.yaml"
echo "UI files remain at /etc/mihomo/ui (remove manually if no longer needed)"
