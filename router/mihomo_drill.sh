#!/bin/sh
# mihomo failure drill (non-destructive).
# Stops the service, measures the real impact on LAN DNS and HTTP, starts it
# again, and measures recovery. Touches no configuration file and deletes
# nothing: this is the same failure mode a crash would produce, but recoverable.
#
# Run:  sh /usr/bin/mihomo_drill.sh
# Log:  /www/mihomo_drill.log

set -u
LOG=/www/mihomo_drill.log

say() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

dnscheck() {
    if nslookup www.baidu.com 192.168.1.1 >/dev/null 2>&1; then echo OK; else echo FAIL; fi
}

httpcheck() {
    if wget -q -T 6 -O /dev/null http://www.baidu.com 2>/dev/null; then echo OK; else echo FAIL; fi
}

say "=== drill start ==="
say "BEFORE      dns=$(dnscheck) http=$(httpcheck) mihomo=$(/etc/init.d/mihomo status 2>&1 | head -1)"

/etc/init.d/mihomo stop
sleep 3
say "STOPPED+3s  dns=$(dnscheck) http=$(httpcheck)"

sleep 15
say "STOPPED+18s dns=$(dnscheck) http=$(httpcheck)"

/etc/init.d/mihomo start
sleep 5
say "STARTED+5s  dns=$(dnscheck) http=$(httpcheck)"

sleep 5
say "STARTED+10s dns=$(dnscheck) http=$(httpcheck)"

say "=== drill end ==="
