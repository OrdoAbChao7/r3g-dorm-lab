#!/usr/bin/env python3
"""Read-only diagnostics over the OpenWrt initramfs serial console.

The command list is hardcoded and contains only read-only queries. The tool
does not accept arbitrary commands and never writes NAND/UBI/Flash.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import serial
    from serial.tools import list_ports
except ImportError:  # pragma: no cover
    serial = None
    list_ports = None

TOOLKIT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = TOOLKIT_ROOT / "logs"
KNOWN_ADAPTERS = {"1A86:7523": "CH340", "10C4:EA60": "CP210x", "0403:6001": "FTDI"}

COMMANDS = [
    "cat /proc/mtd",
    "cat /proc/cmdline",
    "cat /proc/partitions",
    "ls -l /dev/mtd*",
    "ubinfo -a",
    "mtdinfo -a",
    "dmesg | tail -n 200",
    "mount",
    "df -h",
    "free",
    "uname -a",
]

VERIFY_COMMANDS = [
    "sha256sum /dev/mtd7",
    "sha256sum /dev/mtd8",
    "dd if=/dev/mtd9ro bs=131072 skip=0 count=1 2>/dev/null | hexdump -C -n 64",
    "dd if=/dev/mtd9ro bs=131072 skip=255 count=1 2>/dev/null | hexdump -C -n 64",
    "dd if=/dev/mtd9ro bs=131072 skip=256 count=1 2>/dev/null | hexdump -C -n 64",
    "dd if=/dev/mtd9ro bs=131072 skip=257 count=1 2>/dev/null | hexdump -C -n 64",
]

NET_COMMANDS = [
    "ip -4 addr show",
    "ip route",
    "which tftp",
    "which wget",
    "which nc",
    "cat /etc/openwrt_release",
]

WIFI_COMMANDS = [
    "iw dev",
    "iwinfo",
    "ip link show",
    "ls -l /etc/config/wireless",
    "which hostapd",
    "which wpad",
    "logread | tail -n 120",
]

RADIO_COMMANDS = [
    "dmesg | grep -iE 'mt76|eeprom|calib|ieee80211 phy' | tail -n 100",
    "iw dev phy0-ap0 station dump",
    "iw dev phy1-ap0 station dump",
    "iwinfo phy0-ap0 assoclist",
    "iwinfo phy1-ap0 assoclist",
    "cat /tmp/dhcp.leases",
    "cat /proc/net/dev",
    "iwinfo phy0-ap0 info",
    "iwinfo phy1-ap0 info",
    "logread | grep -iE 'hostapd|wpa_supplicant|deauth|beacon|radar|DFS' | tail -n 100",
]

SCAN_COMMANDS = [
    "iw dev phy0-ap0 scan | grep -E '^BSS|signal:|SSID:' | head -n 120",
    "iw dev phy1-ap0 scan | grep -E '^BSS|signal:|SSID:' | head -n 120",
]

WAN_COMMANDS = [
    "uci show network.wan",
    "ip link show wan",
    "ip -4 addr show wan",
    "ip route",
    "ifstatus wan",
    "cat /tmp/resolv.conf.d/resolv.conf.auto",
    "ping -c 4 -W 2 223.5.5.5",
    "ping -c 2 -W 2 www.baidu.com",
    "wget -O /tmp/g204 http://connect.rom.miui.com/generate_204; echo RC=$?; wc -c </tmp/g204; head -c 200 /tmp/g204",
    "logread | grep -iE 'wan|udhcpc|dhcp|netifd' | tail -n 60",
]

PKG_COMMANDS = [
    "cat /etc/openwrt_release",
    "command -v opkg",
    "command -v apk",
    "ls -la /etc/apk",
    "ls -la /etc/apk/repositories.d 2>/dev/null",
    "cat /etc/apk/repositories.d/*.list 2>/dev/null",
    "apk --version",
    "apk info 2>&1 | head -n 25",
    "df -h /overlay",
]

LUCI_COMMANDS = [
    "ls -l /www/cgi-bin/ 2>/dev/null",
    "ls -l /etc/uci-defaults/ 2>/dev/null",
    "cat /etc/config/uhttpd",
    "ps w | grep -E 'uhttpd|rpcd' | grep -v grep",
    "logread | grep -iE 'uhttpd|luci|rpcd|dispatcher|passwd' | tail -n 40",
]

LUCI2_COMMANDS = [
    "apk info -e luci-base; echo RC_BASE=$?",
    "apk info -e luci-mod-admin-full; echo RC_ADMIN=$?",
    "apk info -e uhttpd-mod-lua; echo RC_UHTTPD_LUA=$?",
    "apk info -e lua; echo RC_LUA=$?",
    "ls -l /usr/lib/lua/luci/sgi/uhttpd.lua 2>/dev/null",
    "cat /www/cgi-bin/luci",
    "ls /usr/lib/uhttpd 2>/dev/null",
    "logread | tail -n 25",
]

LUCI3_COMMANDS = [
    "ls -l /usr/share/ucode/luci/dispatcher.uc 2>/dev/null",
    "ls /usr/share/ucode/luci 2>/dev/null | head -n 20",
    "wget -O /dev/null http://127.0.0.1/cgi-bin/luci/admin/; echo RC_ADMIN=$?",
    "wget -O /dev/null http://127.0.0.1/cgi-bin/luci/admin/status; echo RC_STATUS=$?",
    "SCRIPT_NAME=/cgi-bin/luci PATH_INFO=/cgi-bin/luci/admin/ REQUEST_METHOD=GET QUERY_STRING= REMOTE_ADDR=127.0.0.1 HTTP_HOST=127.0.0.1 /www/cgi-bin/luci 2>&1 | head -c 400; echo; echo CGI_RC=$?",
]

LUCI4_COMMANDS = [
    "SCRIPT_NAME=/cgi-bin/luci PATH_INFO=/admin/ REQUEST_METHOD=GET QUERY_STRING= REMOTE_ADDR=127.0.0.1 HTTP_HOST=127.0.0.1 /www/cgi-bin/luci 2>&1 | head -c 200; echo; echo CGI1_RC=$?",
    "SCRIPT_NAME=/cgi-bin/luci PATH_INFO=/ REQUEST_METHOD=GET QUERY_STRING= REMOTE_ADDR=127.0.0.1 HTTP_HOST=127.0.0.1 /www/cgi-bin/luci 2>&1 | head -c 200; echo; echo CGI2_RC=$?",
    "wget -O /dev/null http://127.0.0.1/; echo RC_ROOT=$?",
    "wget -O /dev/null http://127.0.0.1/cgi-bin/cgi-backup; echo RC_CGIO=$?",
    "command -v nc; echo RC_NC=$?",
]

LUCI5_COMMANDS = [
    "(printf 'GET /cgi-bin/luci/ HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n'; sleep 2) | nc 127.0.0.1 80 | head -c 500",
    "wget -O /tmp/luci403 http://127.0.0.1/cgi-bin/luci/; echo RC=$?; wc -c </tmp/luci403; head -c 200 /tmp/luci403",
    "command -v uclient-fetch; echo RC_UF=$?",
    "uclient-fetch -O /tmp/luci403u http://127.0.0.1/cgi-bin/luci/ 2>&1 | head -n 8; echo RC_UF2=$?; wc -c </tmp/luci403u 2>/dev/null; head -c 200 /tmp/luci403u 2>/dev/null",
]

ACCEPT_COMMANDS = [
    "logread | grep -iE 'dispatcher|passwd' | tail -n 10",
    "iw dev phy0-ap0 station dump",
    "iw dev phy1-ap0 station dump",
    "iwinfo phy0-ap0 assoclist",
    "iwinfo phy1-ap0 assoclist",
    "cat /tmp/dhcp.leases",
]

PWCHECK_COMMANDS = [
    "date",
    "ls -l /etc/shadow",
    "logread | grep -iE 'passwd|chpasswd|luci' | tail -n 10",
]

HTTPCHECK_COMMANDS = [
    "date",
    "ls -l /etc/shadow",
    "ps w | grep -E 'uhttpd|rpcd' | grep -v grep",
    "netstat -ltn 2>/dev/null | head -n 15",
    "iwinfo phy1-ap0 assoclist",
    "iwinfo phy0-ap0 assoclist",
    "cat /tmp/dhcp.leases",
    "logread | tail -n 25",
]

ESP32_COMMANDS = [
    "cat /proc/net/arp",
    "ping -c 3 -W 2 192.168.1.53",
    "iw dev phy0-ap0 station dump",
    "iwinfo phy0-ap0 assoclist",
    "cat /tmp/dhcp.leases",
]

DNSCHECK_COMMANDS = [
    "nslookup doubleclick.net 192.168.1.53",
    "nslookup pagead2.googlesyndication.com 192.168.1.53",
    "nslookup ads.doubleclick.net 192.168.1.53",
    "nslookup googlesyndication.com 192.168.1.53",
    "nslookup www.baidu.com 192.168.1.53",
]

BLTEST_COMMANDS = [
    "date",
    "wget -O /tmp/pro.txt https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.txt; echo RC=$?; wc -c </tmp/pro.txt",
]

AUDIT1_COMMANDS = [
    "uci show dhcp",
    "ls -l /var/etc/dnsmasq.conf* 2>/dev/null",
    "grep -iE 'dhcp-option|no-resolv|^server=|dhcp-range' /var/etc/dnsmasq.conf.* 2>/dev/null | head -n 40",
    "ps w | grep dnsmasq | grep -v grep",
    "cat /tmp/resolv.conf.d/resolv.conf.auto",
]

AUDIT2_COMMANDS = [
    "uci show dhcp.odhcpd",
    "ip -6 addr show br-lan",
    "ip -6 route",
    "ifstatus lan",
    "ifstatus wan6",
    "logread | grep -iE 'odhcpd|RA|DHCPv6' | tail -n 30",
]

AUDIT3_COMMANDS = [
    "wget -O /tmp/sec_status http://192.168.1.53/status; echo RC=$?; wc -c </tmp/sec_status; head -c 200 /tmp/sec_status",
    "wget -O /tmp/sec_root http://192.168.1.53/; echo RC=$?; wc -c </tmp/sec_root; head -c 200 /tmp/sec_root",
    "wget -O /tmp/sec_scan http://192.168.1.53/scan; echo RC=$?; wc -c </tmp/sec_scan; head -c 300 /tmp/sec_scan",
    "wget -O /tmp/sec_log http://192.168.1.53/log; echo RC=$?; wc -c </tmp/sec_log; head -c 200 /tmp/sec_log",
    "uci show firewall | grep -iE 'redirect|forwarding|zone|masq' | head -n 40",
    "nft list ruleset 2>/dev/null | grep -iE '192.168.1.53' | head -n 10",
]

AUDIT4_COMMANDS = [
    "nslookup pagead2.googlesyndication.com 192.168.1.1",
    "nslookup googlesyndication.com 192.168.1.1",
    "nslookup www.baidu.com 192.168.1.1",
    "nslookup example.com 192.168.1.1",
    "nslookup no-such-9f3a2b.invalid 192.168.1.1",
    "nslookup pagead2.googlesyndication.com 192.168.1.53",
    "nslookup doubleclick.net 192.168.1.1",
]

AUDIT5_COMMANDS = [
    "ip link show utun 2>/dev/null",
    "ip -4 addr show utun 2>/dev/null",
    "ip route show table all 2>/dev/null | grep -i utun | head -n 10",
    "ps w | grep -iE 'clash|sing|tun|proxy|vpn|tailscale|zerotier' | grep -v grep | head -n 20",
    "cat /tmp/dhcp.leases",
    "cat /proc/net/arp",
]

AUDIT6_COMMANDS = [
    "ip rule show",
    "nft list ruleset 2>/dev/null | grep -iE 'utun|198.18|2022' | head -n 20",
    "netstat -ltn 2>/dev/null | head -n 30",
    "ps w | head -n 40",
    "ls /etc/init.d/ | grep -iE 'clash|mihomo|sing|shell|passwall|shadow|v2ray|xray|trojan|proxy'",
    "uci show 2>/dev/null | grep -iE 'clash|mihomo|openclash|passwall|sing-box|v2ray|xray' | head -n 20",
]

MIHOMO_PRE_COMMANDS = [
    "ps w | grep -i mihomo | grep -v grep",
    "ls -l /etc/init.d/mihomo /etc/mihomo/config.yaml",
    "sed -n '1,60p' /etc/init.d/mihomo",
    "grep -n '^external-controller' /etc/mihomo/config.yaml",
    "awk '/^secret:/{print \"SECRET_LINE=\" NR \" LEN=\" length($0)}' /etc/mihomo/config.yaml",
    "netstat -ltnp 2>/dev/null | grep 9090",
    "nft list ruleset 2>/dev/null | grep -n -B2 -A6 '9090' | head -n 40",
    "nft list chain inet fw4 input_wan 2>/dev/null | head -n 30",
    "ip -4 addr show utun",
    "sha256sum /etc/mihomo/config.yaml",
    "stat -c '%a %U:%G %s' /etc/mihomo/config.yaml",
]

MIHOMO_VAL_COMMANDS = [
    "date",
    "/usr/bin/mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml; echo TEST_RC=$?",
    "command -v nslookup; echo NS_RC=$?",
    "nslookup www.google.com 192.168.1.1 2>&1 | head -n 12",
    "command -v uclient-fetch; echo UF_RC=$?",
    "command -v wget; echo WG_RC=$?",
]

MIHOMO_POST_COMMANDS = [
    "wc -c </tmp/proxies.json",
    "grep -o '\"name\":\"PROXY\"' /tmp/proxies.json | wc -l",
    "grep -o '\"name\":\"AUTO\"' /tmp/proxies.json | wc -l",
    "grep -o '\"name\":\"[^\"]*\"' /tmp/proxies.json | wc -l",
    "nft list chain inet fw4 reject_from_wan 2>/dev/null | head -n 10",
    "ls -l /root/backups/mihomo-secret-empty-<stamp>/",
]


def parse_vidpid(hwid: str) -> str | None:
    if not hwid:
        return None
    m = re.search(r"VID[:=]PID[=:]([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})", hwid)
    if m:
        return f"{m.group(1)}:{m.group(2)}".upper()
    return None


def find_port(device: str):
    for p in list_ports.comports():
        if p.device.upper() == device.upper():
            return p
    return None


def open_port(device: str, baud: int):
    ser = serial.Serial()
    ser.port = device
    ser.baudrate = baud
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.05
    ser.write_timeout = 0.5
    ser.xonxoff = False
    ser.rtscts = False
    ser.dsrdtr = False
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    return ser


def main() -> int:
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="Read-only OpenWrt initramfs diagnostics")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--profile", choices=("basic", "verify", "net", "wifi", "radio", "scan", "wan", "pkg", "luci", "luci2", "luci3", "luci4", "luci5", "accept", "pwcheck", "httpcheck", "esp32", "dnscheck", "bltest", "audit1", "audit2", "audit3", "audit4", "audit5", "audit6", "mihomopre", "mihomoval", "mihomopost"), default="basic")
    ap.add_argument("--settle", type=float, default=1.0)
    args = ap.parse_args()

    if not args.allow_tx:
        print("REFUSED: this tool transmits the fixed read-only command list; pass --allow-tx.",
              file=sys.stderr)
        return 2
    if serial is None:
        print("pyserial is not installed.", file=sys.stderr)
        return 5

    device = args.port.upper()
    info = find_port(device)
    if info is None:
        print(f"Port {device} is not present.", file=sys.stderr)
        return 3
    vidpid = parse_vidpid(info.hwid or "") or "?"
    if vidpid not in KNOWN_ADAPTERS:
        print(f"Refusing unknown adapter {vidpid}.", file=sys.stderr)
        return 4

    commands = {
        "basic": COMMANDS,
        "verify": VERIFY_COMMANDS,
        "net": NET_COMMANDS,
        "wifi": WIFI_COMMANDS,
        "radio": RADIO_COMMANDS,
        "scan": SCAN_COMMANDS,
        "wan": WAN_COMMANDS,
        "pkg": PKG_COMMANDS,
        "luci": LUCI_COMMANDS,
        "luci2": LUCI2_COMMANDS,
        "luci3": LUCI3_COMMANDS,
        "luci4": LUCI4_COMMANDS,
        "luci5": LUCI5_COMMANDS,
        "accept": ACCEPT_COMMANDS,
        "pwcheck": PWCHECK_COMMANDS,
        "httpcheck": HTTPCHECK_COMMANDS,
        "esp32": ESP32_COMMANDS,
        "dnscheck": DNSCHECK_COMMANDS,
        "bltest": BLTEST_COMMANDS,
        "audit1": AUDIT1_COMMANDS,
        "audit2": AUDIT2_COMMANDS,
        "audit3": AUDIT3_COMMANDS,
        "audit4": AUDIT4_COMMANDS,
        "audit5": AUDIT5_COMMANDS,
        "audit6": AUDIT6_COMMANDS,
        "mihomopre": MIHOMO_PRE_COMMANDS,
        "mihomoval": MIHOMO_VAL_COMMANDS,
        "mihomopost": MIHOMO_POST_COMMANDS,
    }[args.profile]
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = out / f"r3g_readonly_diag_{stamp}"
    rx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=READONLY-DIAG profile={args.profile} commands={commands!r}\n")
    text.flush()
    rx_sha = hashlib.sha256()
    rx_total = 0
    actions = []
    ser = open_port(device, args.baud)

    def pump(seconds: float) -> None:
        nonlocal rx_total
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            waiting = ser.in_waiting
            chunk = ser.read(waiting if waiting else 1)
            if chunk:
                raw.write(chunk)
                raw.flush()
                rx_sha.update(chunk)
                rx_total += len(chunk)
                text.write(chunk.decode("latin-1"))
                text.flush()
                sys.stdout.write(chunk.decode("latin-1"))
                sys.stdout.flush()

    def send(payload: bytes, action: str) -> None:
        ser.write(payload)
        ser.flush()
        actions.append({
            "at_s": round(time.monotonic(), 3),
            "action": action,
            "bytes_hex": payload.hex(),
            "bytes_ascii": payload.decode("latin-1"),
        })
        print(f"\n[TX] {action}", flush=True)

    print("=" * 72)
    print(f" Port {device} @ {args.baud} 8N1   READ-ONLY INITRAMFS DIAGNOSTICS")
    print(" Sending only: Enter to activate console, then fixed read-only queries.")
    print("=" * 72)

    try:
        time.sleep(0.3)
        send(b"\r", "activate-console")
        pump(1.0)
        for cmd in commands:
            send((cmd + "\r").encode("utf-8"), cmd)
            if " scan " in cmd:
                pump(10.0)
            elif cmd.startswith("ping "):
                pump(8.0)
            elif cmd.startswith("wget "):
                pump(8.0)
            elif "/www/cgi-bin/luci" in cmd:
                pump(10.0)
            elif cmd.startswith("printf ") or cmd.startswith("(printf "):
                pump(10.0)
            elif cmd.startswith("uclient-fetch"):
                pump(10.0)
            elif cmd.startswith("nslookup "):
                pump(10.0)
            elif "pro.txt" in cmd:
                pump(150.0)
            else:
                pump(2.0)
        pump(1.0)
    finally:
        try:
            ser.close()
        except Exception:
            pass
        raw.close()
        text.close()
        actions_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        meta.write_text(json.dumps({
            "mode": "readonly-initramfs-diag",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "commands": commands,
            "rx_bytes": rx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "text_file": str(txt),
            "actions_file": str(actions_path),
        }, indent=2), encoding="utf-8")
        print(f"\nrx_bytes={rx_total}")
        print(f"rx={rx_bin}\ntext={txt}\nmeta={meta}\nactions={actions_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
