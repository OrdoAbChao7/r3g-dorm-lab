#!/bin/sh
# DNS failover watchdog for the R3G + Mihomo gateway.
#
# Normal state : dnsmasq upstream = Mihomo DNS (127.0.0.1#1053), fake-ip active.
# If Mihomo's API or DNS resolver stops answering, dnsmasq is switched to the
# campus resolvers so the LAN keeps resolving without proxy DNS.
# When Mihomo answers again for OK_THRESHOLD consecutive runs, it switches back.
#
# The primary check uses the Mihomo API (/version and /dns/query). A single
# failed check is re-tried after 2 seconds, so a config hot-reload does not
# trigger a failover. The fallback is only accepted when a direct query returns
# a real address: while Mihomo is up its TUN can hijack router-originated :53
# traffic and answer with a fake-ip, which must not count as a working fallback.
#
# Only dhcp.@dnsmasq[0].server is touched and noresolv stays 1. dnsmasq is
# reloaded only on a transition; mihomo is never restarted. Every transition
# is logged. Run from cron once a minute.
#
# Usage: dns_failover_mihomo.sh [run|status|force-primary|force-fallback]
# Test hooks: FAILOVER_FORCE=down|up overrides the primary health result;
#             FAILOVER_FORCE_FALLBACK=up accepts the fallback path.

set -u

PRIMARY="127.0.0.1#1053"
FALLBACK_1="${FAILOVER_FALLBACK_1:-192.0.2.53}"
FALLBACK_2="${FAILOVER_FALLBACK_2:-192.0.2.54}"
API="${FAILOVER_API:-http://192.168.1.1:9090}"
PROBE_NAME="${FAILOVER_PROBE:-example.com}"
FAIL_THRESHOLD="${FAILOVER_FAIL_N:-1}"
OK_THRESHOLD="${FAILOVER_OK_N:-3}"
STATE="${FAILOVER_STATE:-/tmp/dns_failover_mihomo.state}"
LOCK="${FAILOVER_LOCK:-/tmp/dns_failover_mihomo.lock}"
LOG="${FAILOVER_LOG:-/tmp/dns_failover_mihomo.log}"

say() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
    logger -t dns-failover-mihomo "$*"
}

# Current upstream mode, read from uci rather than a file: if someone changes
# the config by hand the script follows reality instead of its own memory.
current_mode() {
    servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)"
    case "$servers" in
        *"$PRIMARY"*) echo primary ;;
        *"$FALLBACK_1"*|*"$FALLBACK_2"*) echo fallback ;;
        *) echo unknown ;;
    esac
}

primary_check() {
    wget -q -T 3 -O /dev/null "$API/version" 2>/dev/null || return 1
    body="$(wget -q -T 5 -O - "$API/dns/query?name=$PROBE_NAME&type=A" 2>/dev/null)" || return 1
    printf '%s' "$body" | grep -q '"Status":0' || return 1
    printf '%s' "$body" | grep -q '"Answer"' || return 1
    return 0
}

primary_healthy() {
    case "${FAILOVER_FORCE:-}" in
        down) return 1 ;;
        up)   return 0 ;;
    esac
    primary_check && return 0
    sleep 2
    primary_check
}

fallback_healthy() {
    [ "${FAILOVER_FORCE_FALLBACK:-}" = "up" ] && return 0
    for srv in "$FALLBACK_1" "$FALLBACK_2"; do
        out="$(nslookup "$PROBE_NAME" "$srv" 2>/dev/null)" || continue
        addr="$(printf '%s\n' "$out" | sed -n 's/^Address:[[:space:]]*\([0-9][0-9.]*\)$/\1/p' | grep -v '^198\.18\.' | head -1)"
        [ -n "$addr" ] && return 0
    done
    return 1
}

read_counter() {
    if [ -f "$STATE" ]; then
        v="$(sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1)"
        case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
    else
        echo 0
    fi
}

write_counters() {
    printf 'fail=%s\nok=%s\n' "$1" "$2" >"$STATE"
}

apply_dns() {
    target="$1"
    uci -q delete dhcp.@dnsmasq[0].server
    if [ "$target" = "primary" ]; then
        uci add_list dhcp.@dnsmasq[0].server="$PRIMARY" >/dev/null
    else
        uci add_list dhcp.@dnsmasq[0].server="$FALLBACK_1" >/dev/null
        uci add_list dhcp.@dnsmasq[0].server="$FALLBACK_2" >/dev/null
    fi
    uci -q set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    if [ "$target" = "primary" ]; then
        say "SWITCH -> primary ($PRIMARY): Mihomo DNS restored"
    else
        say "SWITCH -> fallback ($FALLBACK_1,$FALLBACK_2): campus DNS, proxy and ad filtering suspended"
    fi
}

run_once() {
    exec 9>"$LOCK" || exit 1
    flock -n 9 || { echo busy; exit 0; }

    mode="$(current_mode)"
    fail="$(read_counter fail)"
    ok="$(read_counter ok)"

    if [ "$mode" = "unknown" ]; then
        write_counters "$fail" "$ok"
        echo "unknown dnsmasq upstream, not managing"
        exit 0
    fi

    if primary_healthy; then
        fail=0
        if [ "$mode" = "fallback" ]; then
            ok=$((ok + 1))
            if [ "$ok" -ge "$OK_THRESHOLD" ]; then
                apply_dns primary
                ok=0
            fi
        else
            ok=0
        fi
    else
        ok=0
        fail=$((fail + 1))
        if [ "$mode" = "primary" ] && [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
            if fallback_healthy; then
                apply_dns fallback
                fail=0
            else
                say "primary unhealthy but campus fallback unreachable; staying on primary"
                fail=0
            fi
        fi
    fi

    write_counters "$fail" "$ok"
}

show_status() {
    echo "mode=$(current_mode) fail=$(read_counter fail) ok=$(read_counter ok)"
    echo "servers=$(uci -q get dhcp.@dnsmasq[0].server) noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv)"
    if primary_healthy; then echo "primary=healthy"; else echo "primary=unhealthy"; fi
    if fallback_healthy; then echo "fallback=reachable"; else echo "fallback=masked-or-down"; fi
}

case "${1:-run}" in
    run) run_once ;;
    status) show_status ;;
    force-primary) apply_dns primary; write_counters 0 0 ;;
    force-fallback)
        if fallback_healthy; then
            apply_dns fallback; write_counters 0 0
        else
            echo "fallback unreachable; refusing to switch"
            exit 1
        fi
        ;;
    *) echo "usage: $0 [run|status|force-primary|force-fallback]" >&2; exit 2 ;;
esac
