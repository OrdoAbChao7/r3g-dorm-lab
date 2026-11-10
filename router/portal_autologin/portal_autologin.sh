#!/bin/sh
# portal_autologin.sh - keep the R3G WAN authenticated against the WHUT portal.
#
# Requires: busybox nc, flock, ifup/ifdown. The portal answers plain HTTP on
# the campus LAN; busybox nc has no timeout flag, so stdin is kept open briefly
# and the server closes the connection (Connection: close).
#
# Contract:
#   * credentials live in /etc/portal/login.conf (root, mode 600), never here;
#   * the script only acts when /api/account/status shows no live session and
#     the WAN has an IPv4 address;
#   * on "device IP not online" it reconnects the WAN once per 15 minutes and
#     re-checks, because the NAS only re-registers the device after a link
#     cycle (the portal's own instruction);
#   * it never solves captchas: a "code 2" answer stops it with a long backoff;
#   * it never calls logout and never touches an existing session;
#   * it writes only to /tmp; the credential file is the only flash write.
#
# Usage: portal_autologin.sh [run|status|test-login]
#   run        cron entry point; acts only when the portal session is gone
#   status     print the current session and local state, no side effects
#   test-login one login attempt even if offline-check passes (diagnostics)

set -u

HOST="${PORTAL_HOST:-172.30.21.100}"
PORT="${PORTAL_PORT:-80}"
CONF="${PORTAL_CONF:-/etc/portal/login.conf}"
STATE="${PORTAL_STATE:-/tmp/portal_autologin.state}"
BOUNCE="${PORTAL_BOUNCE:-/tmp/portal_autologin.bounce}"
LOG="${PORTAL_LOG:-/tmp/portal_autologin.log}"
LOCK="${PORTAL_LOCK:-/tmp/portal_autologin.lock}"
WAN_DEV="${PORTAL_WAN_DEV:-wan}"
NAS_CONF="${PORTAL_NAS_CONF:-/etc/portal/nas.conf}"

say() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
    logger -t portal-autologin "$*"
}

wan_ip() {
    ip -4 addr show dev "$WAN_DEV" 2>/dev/null |
        sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1
}

wan_mac() {
    ip link show dev "$WAN_DEV" 2>/dev/null |
        sed -n 's/.*link\/ether \([0-9a-fA-F:]*\).*/\1/p' | head -n1
}

http_exchange() {
    { printf '%s' "$1"; sleep 3; } | nc "$HOST" "$PORT"
}

http_get() {
    { printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$1" "$HOST"; sleep 3; } |
        nc "$HOST" "$PORT"
}

urlencode() {
    printf '%s' "$1" | awk '
        BEGIN { for (i = 32; i <= 126; i++) ord[sprintf("%c", i)] = i }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
                else printf "%%%02X", ord[c]
            }
        }'
}

json_code() {
    printf '%s' "$1" | tr -d '\r' |
        sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\([-0-9][0-9]*\).*/\1/p' | head -n1
}

json_field() {
    printf '%s' "$1" | tr -d '\r' |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

is_online() {
    resp=$(http_get /api/account/status)
    [ "$(json_code "$resp")" = 0 ] || return 1
    printf '%s' "$resp" | tr -d '\r' | grep -q '"Username"[[:space:]]*:[[:space:]]*"[^"]'
}

state_get() {
    [ -f "$STATE" ] || { echo 0; return 0; }
    value=$(sed -n "s/^$1=//p" "$STATE" | head -n1)
    case "$value" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$value" ;;
    esac
}

state_set() {
    printf 'fail=%s\nnext=%s\n' "$1" "$2" >"$STATE"
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c <"$LOG")" -gt 65536 ] && mv "$LOG" "$LOG.1"
}

# The NAS only registers a device for portal login after it sees the link come
# up again; the portal itself answers "device IP not online, reconnect" until
# then. One link cycle per 15 minutes at most, and only while offline.
wan_reconnect() {
    now=$(date +%s)
    last=0
    [ -f "$BOUNCE" ] && last=$(sed -n '1p' "$BOUNCE" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt 900 ]; then
        say "WAN reconnect skipped (already tried recently)"
        return 1
    fi
    printf '%s\n' "$now" >"$BOUNCE"
    say "portal reports the device IP is offline; reconnecting WAN"
    ifdown "$WAN_DEV" 2>/dev/null
    sleep 3
    ifup "$WAN_DEV" 2>/dev/null
    n=0
    while [ -z "$(wan_ip)" ] && [ "$n" -lt 15 ]; do
        sleep 2
        n=$((n + 1))
    done
    sleep 3
    return 0
}

# After a link cycle the NAS may authenticate the MAC by itself; give it up to
# a minute before spending a credential login.
wait_online() {
    limit=$1
    waited=0
    while [ "$waited" -lt "$limit" ]; do
        if is_online; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# While unauthenticated the BRAS answers any port-80 request with a 302 to the
# portal login page, whose query carries the real nasId and acip for this port
# (e.g. nasId=52 while /api/config says default_nas=14).
discover_portal() {
    DISCOVERED_NAS=""
    DISCOVERED_ACIP=""
    resp=$( { printf 'GET / HTTP/1.0\r\nHost: 1.1.1.1\r\nConnection: close\r\n\r\n'; sleep 3; } | nc 1.1.1.1 80 )
    loc=$(printf '%s' "$resp" | tr -d '\r' |
        sed -n 's/^Location:[[:space:]]*\(.*\)$/\1/p' | head -n1)
    printf '%s' "$loc" | grep -q 'nasId=' || return 1
    DISCOVERED_NAS=$(printf '%s' "$loc" | sed -n 's/.*[?&]nasId=\([0-9][0-9]*\).*/\1/p')
    DISCOVERED_ACIP=$(printf '%s' "$loc" | sed -n 's/.*[?&]acip=\([0-9.][0-9.]*\).*/\1/p')
    [ -n "$DISCOVERED_NAS" ]
}

# One credential login. Sets LOGIN_CODE and LOGIN_MSG.
post_login() {
    token_resp=$(http_get /api/csrf-token)
    token=$(json_field "$token_resp" csrf_token)
    cookie=$(printf '%s' "$token_resp" | tr -d '\r' |
        sed -n 's/^Set-Cookie:[[:space:]]*\(yudear=[^;]*\).*/\1/p' | head -n1)
    if [ -z "$token" ]; then
        LOGIN_CODE=csrf
        LOGIN_MSG="no csrf token"
        return 0
    fi

    nas=""
    [ -r "$NAS_CONF" ] && nas=$(sed -n 's/^NAS_ID=//p' "$NAS_CONF" | head -n1)
    [ -n "$nas" ] || { discover_portal && nas=$DISCOVERED_NAS; }
    [ -n "$nas" ] || nas=$(json_field "$(http_get /api/config)" default_nas)
    [ -n "$nas" ] || nas=14

    login_ip=$(wan_ip)
    body="username=$(urlencode "$USERNAME")&password=$(urlencode "$PASSWORD")&switchip=&nasId=$nas&userIpv4=$login_ip&userMac=$(wan_mac)&captcha=&captchaId="
    length=$(printf '%s' "$body" | wc -c)
    request=$(printf 'POST /api/account/login HTTP/1.0\r\nHost: %s\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nX-CSRF-Token: %s\r\nCookie: %s\r\nContent-Length: %s\r\n\r\n%s' \
        "$HOST" "$token" "$cookie" "$length" "$body")
    resp=$(http_exchange "$request")
    LOGIN_CODE=$(json_code "$resp")
    LOGIN_MSG=$(json_field "$resp" msg)
    [ -n "$LOGIN_CODE" ] || {
        LOGIN_CODE=bad
        [ -n "$LOGIN_MSG" ] || LOGIN_MSG=$(printf '%s' "$resp" | head -c 120 | tr -d '\r\n')
    }
}

attempt_login() {
    now=$(date +%s)
    now_ip=$(wan_ip)
    [ -n "$now_ip" ] || { say "no WAN IPv4, skipping login"; return 0; }

    # Never post a login while a session is live: the portal answers ok but
    # drops the existing session, and the NAS then reports the IP as offline.
    if is_online; then
        state_set 0 0
        return 0
    fi

    post_login
    case "$LOGIN_CODE" in
        0)
            state_set 0 0
            sleep 2
            if is_online; then
                say "login OK and verified online (ip $now_ip, nas $nas)"
                return 0
            fi
            say "portal accepted the login but the session is not online yet (ip $now_ip)"
            ;;
        2)
            state_set 0 $((now + 1800))
            say "portal requires a captcha; auto-login paused, manual login needed"
            return 0
            ;;
        1)
            case "$LOGIN_MSG" in
                *不在线*)
                    if wan_reconnect; then
                        if wait_online 60; then
                            state_set 0 0
                            say "session restored by itself after the WAN reconnect (no credential login needed)"
                            return 0
                        fi
                        post_login
                        if [ "$LOGIN_CODE" = 0 ]; then
                            state_set 0 0
                            sleep 2
                            if is_online; then
                                say "login OK after WAN reconnect (ip $(wan_ip))"
                            else
                                say "login accepted after WAN reconnect but session still offline"
                            fi
                            return 0
                        fi
                    fi
                    ;;
            esac
            fail=$((fail + 1))
            delay=$((300 * fail))
            [ "$delay" -gt 1800 ] && delay=1800
            state_set "$fail" $((now + delay))
            say "login rejected (code 1, nas $nas): $LOGIN_MSG; retry in ${delay}s"
            ;;
        *)
            state_set 0 $((now + 300))
            say "unexpected portal answer: $LOGIN_MSG"
            ;;
    esac
}

run_once() {
    exec 9>"$LOCK" || exit 1
    flock -n 9 || exit 0

    rotate_log
    [ -r "$CONF" ] || exit 0
    . "$CONF"
    [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ] || exit 0
    [ -n "$(wan_ip)" ] || exit 0

    now=$(date +%s)
    [ "$now" -ge "$(state_get next)" ] || exit 0

    if is_online; then
        if [ "$(state_get fail)" != 0 ]; then
            state_set 0 0
            say "session is back, counters reset"
        fi
        exit 0
    fi

    fail=$(state_get fail)
    attempt_login
}

show_status() {
    current_ip=$(wan_ip)
    if is_online; then
        echo "session: online (wan $current_ip)"
    else
        echo "session: offline (wan ${current_ip:-none})"
    fi
    echo "conf:    $CONF $([ -r "$CONF" ] && echo present || echo missing)"
    echo "state:   fail=$(state_get fail) next=$(state_get next)"
    echo "portal:  http://$HOST:$PORT"
}

case "${1:-run}" in
    run) run_once ;;
    status) show_status ;;
    test-login)
        [ -r "$CONF" ] || { echo "missing $CONF" >&2; exit 1; }
        . "$CONF"
        if is_online && [ "${PORTAL_FORCE_LOGIN:-0}" != 1 ]; then
            echo "session is online; refusing test-login (set PORTAL_FORCE_LOGIN=1 to override)"
            exit 0
        fi
        fail=$(state_get fail)
        attempt_login
        ;;
    *) echo "usage: $0 [run|status|test-login]" >&2; exit 2 ;;
esac
