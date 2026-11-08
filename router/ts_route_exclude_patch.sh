#!/bin/sh
# Keep Tailscale's 100.64.0.0/10 out of mihomo's transparent redirect.
# Without this, requests to the router's own Tailscale address are redirected
# to mihomo's proxy listener and hang.
CFG=/etc/mihomo/config.yaml

grep -q "100.64.0.0/10" "$CFG" && { echo "already patched"; exit 0; }

awk '
    { print }
    /149\.248\.10\.4\/32/ { print "  - 100.64.0.0/10" }
' "$CFG" >"$CFG.new" || exit 1

mv "$CFG.new" "$CFG" || exit 1
echo "patched:"
sed -n '/route-exclude-address/,/^[a-z]/p' "$CFG" | head -8
