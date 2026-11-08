#!/usr/bin/env python3
"""Point the R3G LAN DNS at the ESP32 ad-blocker (192.168.1.53).

Fixed commands only, no arbitrary input:
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='192.168.1.53'
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    uci show dhcp.@dnsmasq[0].noresolv
    uci show dhcp.@dnsmasq[0].server
    nslookup pagead2.googlesyndication.com 192.168.1.1
    nslookup www.baidu.com 192.168.1.1

Requires --allow-tx and --confirm-lan-dns. The campus DNS stays as the
ESP32's own upstream (configured on the device), not as a second router DNS.
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
    "uci set dhcp.@dnsmasq[0].noresolv='1'",
    "uci -q delete dhcp.@dnsmasq[0].server",
    "uci add_list dhcp.@dnsmasq[0].server='192.168.1.53'",
    "uci commit dhcp",
    "/etc/init.d/dnsmasq restart",
    "uci show dhcp.@dnsmasq[0].noresolv",
    "uci show dhcp.@dnsmasq[0].server",
    "nslookup pagead2.googlesyndication.com 192.168.1.1",
    "nslookup www.baidu.com 192.168.1.1",
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

    ap = argparse.ArgumentParser(description="Point the R3G LAN DNS at the ESP32 ad-blocker")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-lan-dns", action="store_true")
    args = ap.parse_args()

    if not args.confirm_lan_dns:
        print("REFUSED: this changes the router's LAN DNS forwarding; "
              "pass --allow-tx --confirm-lan-dns.", file=sys.stderr)
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

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = out / f"r3g_set_lan_dns_{stamp}"
    rx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=SET-LAN-DNS commands={COMMANDS!r}\n")
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
    print(f" Port {device} @ {args.baud} 8N1   POINT LAN DNS AT 192.168.1.53")
    print("=" * 72)
    try:
        time.sleep(0.3)
        send(b"\r", "activate-console")
        pump(1.0)
        for cmd in COMMANDS:
            send((cmd + "\r").encode("utf-8"), cmd)
            if cmd.startswith("nslookup "):
                pump(10.0)
            else:
                pump(3.0)
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
            "mode": "set-lan-dns",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "commands": COMMANDS,
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
