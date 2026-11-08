#!/bin/sh
# Remote power-on for the desktop: send WoL magic packets from the router.
# MACs come from /etc/wol.macs (one per line, '#' comments allowed).
# Every run is appended to /www/wol.log.

MACS_FILE="${WOL_MACS:-/etc/wol.macs}"
IFACE="${WOL_IFACE:-br-lan}"
LOG="${WOL_LOG:-/www/wol.log}"

WOL_BIN="${WOL_BIN:-/usr/bin/etherwake}"
[ -x "$WOL_BIN" ] || WOL_BIN="$(command -v etherwake 2>/dev/null)"
[ -n "$WOL_BIN" ] || { echo "etherwake is not installed" >&2; exit 3; }

[ -f "$MACS_FILE" ] || { echo "no mac list: $MACS_FILE" >&2; exit 2; }

rc_all=0
sent=0

while read -r mac rest; do
    case "$mac" in
        '' | \#*) continue ;;
    esac
    if "$WOL_BIN" -i "$IFACE" "$mac" >/dev/null 2>&1; then
        sent=$((sent + 1))
    else
        rc_all=1
    fi
done <"$MACS_FILE"

printf '%s wol iface=%s sent=%s rc=%s src=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$IFACE" "$sent" "$rc_all" "${WOL_SRC:-manual}" >>"$LOG"

[ "$sent" -gt 0 ] || exit 1
exit $rc_all
