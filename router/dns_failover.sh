#!/bin/sh
# DNS failover watchdog for the R3G + ESP32 ad-blocker chain.
#
# Normal state : dnsmasq upstream = ESP32 (192.168.1.53), filtering active.
# If the ESP32 stops answering for FAIL_THRESHOLD consecutive runs, dnsmasq is
# switched to the campus resolvers so the LAN keeps working without filtering.
# When the ESP32 answers again for OK_THRESHOLD consecutive runs, it switches
# back.
#
# Every decision is logged. The script only touches dhcp.@dnsmasq[0].server and
# leaves noresolv=1 in place. Run from cron once a minute.
#
# Usage: dns_failover.sh [run|status|force-primary|force-fallback]
# Test hooks: FAILOVER_FORCE=down|up makes the health check return that result.

set -u

PRIMARY="${FAILOVER_PRIMARY:-192.168.1.53}"
FALLBACK_1="${FAILOVER_FALLBACK_1:-192.0.2.53}"
FALLBACK_2="${FAILOVER_FALLBACK_2:-192.0.2.54}"
PROBE_NAME="${FAILOVER_PROBE:-example.com}"
FAIL_THRESHOLD="${FAILOVER_FAIL_N:-2}"
OK_THRESHOLD="${FAILOVER_OK_N:-3}"
LOG="${FAILOVER_LOG:-/www/dns_failover.log}"
STATE="${FAILOVER_STATE:-/tmp/dns_failover.state}"
LOCK="${FAILOVER_LOCK:-/tmp/dns_failover.lock}"

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# Current upstream mode, read from uci rather than a file: if someone changes
# the config by hand the script follows reality instead of its own memory.
current_mode() {
    servers="$(uci -q get dhcp.@dnsmasq[0].server || true)"
    case " $servers " in
        *" $PRIMARY "*) echo primary ;;
        "") echo unknown ;;
        *) echo fallback ;;
    esac
}

healthy() {
    case "${FAILOVER_FORCE:-}" in
        down) return 1 ;;
        up)   return 0 ;;
    esac
    nslookup "$PROBE_NAME" "$PRIMARY" >/dev/null 2>&1
}

read_counter() {
    # $1 = file suffix, prints integer
    if [ -f "$STATE" ]; then
        v=$(sed -n "s/^$1=//p" "$STATE" 2>/dev/null | head -1)
        case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
    else
        echo 0
    fi
}

write_counters() {
    printf 'fail=%s\nok=%s\n' "$1" "$2" >"$STATE"
}

set_primary() {
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="$PRIMARY" >/dev/null
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    say "SWITCH -> primary ($PRIMARY): filtering restored"
}

set_fallback() {
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="$FALLBACK_1" >/dev/null
    uci add_list dhcp.@dnsmasq[0].server="$FALLBACK_2" >/dev/null
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    say "SWITCH -> fallback ($FALLBACK_1,$FALLBACK_2): filtering suspended, internet kept"
}

run_once() {
    # single instance
    if [ -f "$LOCK" ]; then
        pid=$(cat "$LOCK" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "busy"; exit 0; }
    fi
    echo $$ >"$LOCK"
    trap 'rm -f "$LOCK"' EXIT

    mode=$(current_mode)
    fail=$(read_counter fail)
    ok=$(read_counter ok)

    if healthy; then
        ok=$((ok + 1))
        fail=0
        if [ "$mode" = "fallback" ] && [ "$ok" -ge "$OK_THRESHOLD" ]; then
            set_primary
            ok=0
        fi
    else
        fail=$((fail + 1))
        ok=0
        if [ "$mode" = "primary" ] && [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
            set_fallback
            fail=0
        fi
    fi

    write_counters "$fail" "$ok"
}

show_status() {
    echo "mode=$(current_mode) fail=$(read_counter fail) ok=$(read_counter ok)"
    echo "servers=$(uci -q get dhcp.@dnsmasq[0].server)"
    echo "noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv)"
    if healthy; then echo "esp32=healthy"; else echo "esp32=unhealthy"; fi
}

case "${1:-run}" in
    run) run_once ;;
    status) show_status ;;
    force-primary) set_primary; write_counters 0 0 ;;
    force-fallback) set_fallback; write_counters 0 0 ;;
    *) echo "usage: $0 [run|status|force-primary|force-fallback]" >&2; exit 2 ;;
esac
