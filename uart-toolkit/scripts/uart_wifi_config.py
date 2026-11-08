#!/usr/bin/env python3
"""Configure both R3G Wi-Fi radios over serial without logging the key.

The WPA2 key is generated locally, written only to a local file, and sent via
`read` with terminal echo disabled. UCI commands reference `$WIFIKEY`, so the
key does not appear in the shell command line or in any log written by this
tool. Only fixed commands are sent.

Defaults:
  radio0 (2.4 GHz) SSID R3G-OpenWrt
  radio1 (5 GHz)   SSID R3G-OpenWrt-5G
  encryption psk2 (WPA2-PSK), same generated key for both.
"""

from __future__ import annotations

import argparse
import json
import re
import secrets
import string
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


def make_key() -> str:
    alphabet = string.ascii_letters + string.digits
    while True:
        key = "".join(secrets.choice(alphabet) for _ in range(24))
        if (any(c.islower() for c in key) and any(c.isupper() for c in key)
                and any(c.isdigit() for c in key)):
            return key


def main() -> int:
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="Configure R3G Wi-Fi over serial")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-wifi-config", action="store_true")
    args = ap.parse_args()

    if not args.allow_tx or not args.confirm_wifi_config:
        print("REFUSED: requires --allow-tx and --confirm-wifi-config.", file=sys.stderr)
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

    key = make_key()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    key_file = out / f"wifi_key_{stamp}.txt"
    key_file.write_text(key + "\n", encoding="utf-8")
    meta = out / f"wifi_config_{stamp}.meta.json"

    ser = open_port(device, args.baud)
    rx = bytearray()
    tx_count = 0

    def read_until(pattern: bytes, timeout: float) -> bool:
        nonlocal rx
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                waiting = ser.in_waiting
                chunk = ser.read(waiting if waiting else 1)
            except Exception:
                return False
            if chunk:
                rx.extend(chunk)
                if len(rx) > 131072:
                    del rx[:-65536]
                if re.search(pattern, bytes(rx), re.IGNORECASE):
                    return True
        return False

    def send(payload: bytes, wait: float = 0.15) -> None:
        nonlocal tx_count
        ser.write(payload)
        ser.flush()
        tx_count += len(payload)
        time.sleep(wait)

    commands = [
        "uci set wireless.default_radio0.ssid='R3G-OpenWrt'",
        "uci set wireless.default_radio0.encryption='psk2'",
        'uci set wireless.default_radio0.key="$WIFIKEY"',
        "uci set wireless.default_radio0.disabled='0'",
        "uci set wireless.radio0.disabled='0'",
        "uci set wireless.radio0.country='CN'",
        "uci set wireless.default_radio1.ssid='R3G-OpenWrt-5G'",
        "uci set wireless.default_radio1.encryption='psk2'",
        'uci set wireless.default_radio1.key="$WIFIKEY"',
        "uci set wireless.default_radio1.disabled='0'",
        "uci set wireless.radio1.disabled='0'",
        "uci set wireless.radio1.country='CN'",
        "uci commit wireless",
    ]

    print("=" * 68)
    print(f" Port {device} @ {args.baud} 8N1   CONFIGURE WI-FI")
    print(" No TX/RX content is written to disk; the WPA2 key uses read/stty -echo.")
    print(f" Key file: {key_file}")
    print("=" * 68)

    status = "UNKNOWN"
    try:
        time.sleep(0.3)
        send(b"\r", 0.2)
        if not read_until(rb"root@OpenWrt:~#", 6.0):
            status = "NO_SHELL_PROMPT"
            print("[FAIL] root shell prompt not seen.")
            return 6
        # Read the key into a shell variable with terminal echo disabled.
        send(b"stty -echo\r", 0.3)
        send(b"read -r WIFIKEY\r", 0.5)
        send(key.encode("ascii") + b"\r", 0.5)
        for cmd in commands:
            send((cmd + "\r").encode("utf-8"), 0.25)
        send(b"wifi reload\r", 10.0)
        send(b"stty echo\r", 0.3)
        send(b"unset WIFIKEY\r", 0.3)
        send(b"rm -f /root/.ash_history\r", 0.3)
        send(b"iw dev\r", 2.0)
        send(b"iwinfo\r", 2.0)
        status = "CONFIGURED" if (b"phy0-ap0" in rx or b"phy1-ap0" in rx or b"type AP" in rx) else "NO_WLAN_INTERFACE"
        if status == "CONFIGURED":
            print("[OK] Wi-Fi configured; wlan interface(s) present.")
            print(f"[INFO] Wi-Fi key is stored in {key_file}; move it to a password manager and delete the file.")
        else:
            print("[WARN] wireless config committed, but no wlan interface was seen.")
    finally:
        try:
            ser.close()
        except Exception:
            pass
        meta.write_text(json.dumps({
            "mode": "configure-wifi",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "ssid_2g": "R3G-OpenWrt",
            "ssid_5g": "R3G-OpenWrt-5G",
            "encryption": "psk2",
            "status": status,
            "tx_bytes": tx_count,
            "rx_bytes_seen": len(rx),
            "tx_logged": False,
            "rx_logged": False,
            "key_file": str(key_file),
        }, indent=2), encoding="utf-8")

    return 0 if status == "CONFIGURED" else 6


if __name__ == "__main__":
    raise SystemExit(main())
