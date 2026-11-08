#!/bin/sh
# R3G blocklist updater -- DESIGN + OFFLINE-TESTED, NOT INSTALLED by the audit.
# Fetches Hagezi Pro, validates it, keeps the previous snapshot, atomically
# replaces /www/blocklist.txt, and leaves the old file untouched on failure.
# POSIX sh (OpenWrt ash compatible). Optional env overrides exist only to let
# the offline test run against a temp dir; on the router the defaults apply.

set -u

URL="${BL_URL:-https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt}"
LIVE="${BL_LIVE:-/www/blocklist.txt}"
TMP="${BL_TMP:-${LIVE}.new}"
BAK="${BL_BAK:-${LIVE}.bak}"
LOG="${BL_LOG:-/www/blocklist_update.log}"
MIN_BYTES="${BL_MIN_BYTES:-3000000}"
MAX_BYTES="${BL_MAX_BYTES:-8000000}"
MIN_DOMAINS="${BL_MIN_DOMAINS:-150000}"
FETCH="${BL_FETCH:-}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }
fail() { log "REJECT: $*"; rm -f "$TMP"; echo "REJECT: $*"; exit 1; }

case "${1:-update}" in
  -rollback|rollback)
    [ -f "$BAK" ] || { log "rollback: no backup"; echo "rollback: no backup"; exit 1; }
    mv "$BAK" "$LIVE" || { log "rollback: mv failed"; exit 1; }
    log "rollback: restored $LIVE from backup"
    echo "ROLLBACK OK"
    exit 0
    ;;
  update) ;;
  *) echo "usage: $0 [update|-rollback]" >&2; exit 2 ;;
esac

rm -f "$TMP"
if [ -n "$FETCH" ]; then
  "$FETCH" "$TMP" "$URL"
else
  uclient-fetch -T 60 -O "$TMP" "$URL"
fi
rc=$?
[ "$rc" -eq 0 ] || fail "fetch failed rc=$rc"
[ -s "$TMP" ] || fail "empty download"

size=$(wc -c < "$TMP" | tr -d ' ')
[ "$size" -ge "$MIN_BYTES" ] || fail "too small: $size bytes"
[ "$size" -le "$MAX_BYTES" ] || fail "too large: $size bytes"

if grep -qiE '<!DOCTYPE|<html' "$TMP"; then
  fail "HTML error page"
fi

count=$(grep -cE '^\|\|[^/^]+\^' "$TMP" || true)
hosts=$(grep -cE '^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]' "$TMP" || true)
total=$((count + hosts))
[ "$total" -ge "$MIN_DOMAINS" ] || fail "domain count too low: $total"

prev=0
if [ -f "$LIVE" ]; then
  prev=$(grep -cE '^\|\|[^/^]+\^' "$LIVE" || true)
  if [ "$prev" -gt 0 ] && [ "$total" -lt $((prev / 2)) ]; then
    fail "count dropped >50%: $total vs $prev"
  fi
  cp -p "$LIVE" "$BAK" || fail "backup copy failed"
fi

mv "$TMP" "$LIVE" || fail "atomic replace failed"
log "UPDATED: domains=$total size=$size prev=$prev"
echo "UPDATED domains=$total size=$size prev=$prev"
