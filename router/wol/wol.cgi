#!/bin/sh
# LAN-only WoL trigger for uhttpd: /cgi-bin/wol?k=<token>
# The token is in /etc/wol.token; nothing else can be passed to the shell.

TOKEN_FILE=/etc/wol.token

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

tok="$(cat "$TOKEN_FILE" 2>/dev/null | tr 'A-Z' 'a-z')"
qs="${QUERY_STRING:-}"

if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    qs="$(cat)"
fi

k="$(printf '%s' "$qs" | sed -n 's/.*k=\([0-9a-zA-Z]\{4,64\}\).*/\1/p' | tr 'A-Z' 'a-z')"

if [ -z "$tok" ] || [ "$k" != "$tok" ]; then
    printf '{"ok":false,"error":"unauthorized"}\n'
    exit 0
fi

if WOL_SRC="web" /usr/bin/wol-pc.sh >/dev/null 2>&1; then
    printf '{"ok":true}\n'
else
    printf '{"ok":false,"error":"wol-failed"}\n'
fi
