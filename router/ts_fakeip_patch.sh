#!/bin/sh
# Let Tailscale domains bypass mihomo's fake-IP so tailscaled can dial them
# with real addresses (control plane and DERP servers).
CFG=/etc/mihomo/config.yaml

if grep -q "tailscale.com" "$CFG"; then
    echo "already patched"
    exit 0
fi

awk '
    { print }
    /msftncsi\.com/ {
        print "  - +.tailscale.com"
        print "  - +.tailscale.io"
        print "  - +.ts.net"
    }
' "$CFG" >"$CFG.new" || exit 1

mv "$CFG.new" "$CFG" || exit 1
echo "patched:"
sed -n '/fake-ip-filter/,/nameserver/p' "$CFG"
