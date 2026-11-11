#!/bin/sh
# Daily refresh of the Anti-AD / Hagezi Light lists and the Mihomo file provider.
# Fixed sources; validates size/count/HTML/drop; keeps .bak; atomic replace.
# The provider is hot-reloaded through the Mihomo API (no service restart).
#
# Install as /usr/bin/update_chinese_lists.sh and run from cron, e.g.:
#   45 18 * * * /usr/bin/update_chinese_lists.sh
# Set MIHOMO_API and the rule-provider name below if they differ.

LOG=/www/chinese_update.log
ANTIAD=/www/antiad.txt
LIGHT=/www/light.txt
MRG=/www/antiad-merged.txt
TMPA=/tmp/antiad.new
TMPL=/tmp/light.new
A_URL=https://anti-ad.net/domains.txt
L_URL=https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/light.txt
API="${MIHOMO_API:-http://192.168.1.1:9090}"
PROVIDER="${MIHOMO_PROVIDER:-antiad}"
API_HOST=$(printf '%s' "$API" | sed -e 's#^http://##' -e 's#^https://##' -e 's#/.*##' -e 's#:.*##')
API_PORT=$(printf '%s' "$API" | sed -n 's#^[^:]*://[^:]*:\([0-9]*\).*#\1#p')
[ -n "$API_PORT" ] || API_PORT=9090

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "start"
rm -f "$TMPA" "$TMPL"
if ! wget -q -O "$TMPA" "$A_URL"; then log "antiad download failed"; rm -f "$TMPA" "$TMPL"; exit 1; fi
if ! wget -q -O "$TMPL" "$L_URL"; then log "light download failed"; rm -f "$TMPA" "$TMPL"; exit 1; fi
A_SIZE=$(wc -c < "$TMPA")
L_SIZE=$(wc -c < "$TMPL")
A_LINES=$(wc -l < "$TMPA")
L_LINES=$(wc -l < "$TMPL")
log "downloaded antiad=${A_SIZE}B/${A_LINES}L light=${L_SIZE}B/${L_LINES}L"
if [ "$A_SIZE" -lt 1000000 ] || [ "$L_SIZE" -lt 1000000 ]; then
  log "size check failed"; rm -f "$TMPA" "$TMPL"; exit 1
fi
if grep -qi '<html' "$TMPA" || grep -qi '<html' "$TMPL"; then
  log "html error page"; rm -f "$TMPA" "$TMPL"; exit 1
fi
if [ "$A_LINES" -lt 50000 ] || [ "$L_LINES" -lt 40000 ]; then
  log "line count too low"; rm -f "$TMPA" "$TMPL"; exit 1
fi
OLD_A=$(wc -l < "$ANTIAD" 2>/dev/null || echo 0)
OLD_L=$(wc -l < "$LIGHT" 2>/dev/null || echo 0)
if [ "$OLD_A" -gt 0 ] && [ "$A_LINES" -lt $((OLD_A / 2)) ]; then
  log "antiad drop too large"; rm -f "$TMPA" "$TMPL"; exit 1
fi
if [ "$OLD_L" -gt 0 ] && [ "$L_LINES" -lt $((OLD_L / 2)) ]; then
  log "light drop too large"; rm -f "$TMPA" "$TMPL"; exit 1
fi
[ -f "$ANTIAD" ] && cp "$ANTIAD" "${ANTIAD}.bak"
[ -f "$LIGHT" ] && cp "$LIGHT" "${LIGHT}.bak"
mv "$TMPA" "$ANTIAD" && mv "$TMPL" "$LIGHT"
if [ $? -ne 0 ]; then log "replace failed"; exit 1; fi
# Rebuild the merged domain list used by the Mihomo file provider.
{ cat "$ANTIAD"; grep -oE "^[|][|][A-Za-z0-9._-]+" "$LIGHT" | sed "s/^[|][|]//"; } | tr "A-Z" "a-z" | grep -E "^[a-z0-9.-]+$" | sort -u > /tmp/antiad-merged.new
M_LINES=$(wc -l < /tmp/antiad-merged.new 2>/dev/null || echo 0)
if [ "$M_LINES" -gt 50000 ]; then
  mv /tmp/antiad-merged.new "$MRG"
  # '+.domain' matches the domain and every subdomain; a bare entry is exact-only.
  { echo "payload:"; sed "s/^/  - +./" "$MRG"; } > /etc/mihomo/ruleset/anti-ad.yaml.new
  Y_LINES=$(wc -l < /etc/mihomo/ruleset/anti-ad.yaml.new 2>/dev/null || echo 0)
  if [ "$Y_LINES" -gt 50001 ]; then
    /usr/bin/mihomo convert-ruleset domain yaml /etc/mihomo/ruleset/anti-ad.yaml.new /tmp/anti-ad.mrs.new
    MRS_SIZE=$(wc -c < /tmp/anti-ad.mrs.new 2>/dev/null || echo 0)
    if [ "$MRS_SIZE" -gt 100000 ]; then
      OLD_SUM=$(md5sum /etc/mihomo/ruleset/anti-ad.mrs 2>/dev/null | awk "{print \$1}")
      NEW_SUM=$(md5sum /tmp/anti-ad.mrs.new | awk "{print \$1}")
      if [ -n "$OLD_SUM" ] && [ "$OLD_SUM" = "$NEW_SUM" ]; then
        log "mrs unchanged lines=${Y_LINES}; provider not reloaded"
        rm -f /etc/mihomo/ruleset/anti-ad.yaml.new /tmp/anti-ad.mrs.new
      else
        cp /etc/mihomo/ruleset/anti-ad.mrs /etc/mihomo/ruleset/anti-ad.mrs.bak 2>/dev/null
        cp /etc/mihomo/ruleset/anti-ad.yaml /etc/mihomo/ruleset/anti-ad.yaml.bak 2>/dev/null
        mv /etc/mihomo/ruleset/anti-ad.yaml.new /etc/mihomo/ruleset/anti-ad.yaml
        mv /tmp/anti-ad.mrs.new /etc/mihomo/ruleset/anti-ad.mrs
        chmod 644 /etc/mihomo/ruleset/anti-ad.yaml /etc/mihomo/ruleset/anti-ad.mrs
        cp "$MRG" /etc/mihomo/ruleset/anti-ad.txt.new
        mv /etc/mihomo/ruleset/anti-ad.txt.new /etc/mihomo/ruleset/anti-ad.txt
        if /usr/bin/mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1; then
          SECRET=$(awk "/^secret:/{print \$2}" /etc/mihomo/config.yaml | tr -d '"')
          printf "PUT /providers/rules/%s HTTP/1.1\r\nHost: %s:%s\r\nAuthorization: Bearer %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" "$PROVIDER" "$API_HOST" "$API_PORT" "$SECRET" | nc "$API_HOST" "$API_PORT" | grep -q "204 No Content"
          if [ $? -eq 0 ]; then
            log "merged ok lines=${M_LINES} yaml=${Y_LINES} mrs=${MRS_SIZE} provider hot-reloaded"
          else
            log "hot reload failed; new mrs staged, running provider unchanged"
          fi
        else
          cp /etc/mihomo/ruleset/anti-ad.mrs.bak /etc/mihomo/ruleset/anti-ad.mrs 2>/dev/null
          cp /etc/mihomo/ruleset/anti-ad.yaml.bak /etc/mihomo/ruleset/anti-ad.yaml 2>/dev/null
          log "config test failed; restored previous provider, no restart"
        fi
      fi
    else
      log "mrs convert failed size=${MRS_SIZE}"; rm -f /etc/mihomo/ruleset/anti-ad.yaml.new /tmp/anti-ad.mrs.new
    fi
  else
    log "yaml build failed lines=${Y_LINES}"; rm -f /etc/mihomo/ruleset/anti-ad.yaml.new
  fi
else
  log "merged failed lines=${M_LINES}"; rm -f /tmp/antiad-merged.new
fi
sync
log "ok antiad=${A_SIZE}B/${A_LINES}L light=${L_SIZE}B/${L_LINES}L"
