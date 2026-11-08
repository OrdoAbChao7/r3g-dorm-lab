#!/usr/bin/env python3
"""Set a generated strong root password over the serial console.

Security properties:
  * Generates a 24-character random password locally.
  * Writes it only to a local file (path printed at the end).
  * Does NOT log transmitted bytes or received bytes to disk.
  * Sends only: Enter, `passwd`, password, password. No other command.
  * Requires --allow-tx and --confirm-password-change.
"""

from __future__ import annotations

import argparse
import hashlib
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


def make_password() -> str:
    upper = string.ascii_uppercase
    lower = string.ascii_lowercase
    digits = string.digits
    symbols = "!@#%^*-_=+"
    alphabet = upper + lower + digits + symbols
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(24))
        if (any(c in upper for c in pw) and any(c in lower for c in pw)
                and any(c in digits for c in pw) and any(c in symbols for c in pw)):
            return pw


def main() -> int:
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="Set generated R3G root password over serial")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-password-change", action="store_true")
    args = ap.parse_args()

    if not args.allow_tx or not args.confirm_password_change:
        print("REFUSED: requires --allow-tx and --confirm-password-change.", file=sys.stderr)
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

    password = make_password()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    pw_file = out / f"root_password_{stamp}.txt"
    pw_file.write_text(password + "\n", encoding="utf-8")
    meta = out / f"root_password_{stamp}.meta.json"

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
                if len(rx) > 65536:
                    del rx[:-32768]
                if re.search(pattern, bytes(rx), re.IGNORECASE):
                    return True
        return False

    def send(payload: bytes) -> None:
        nonlocal tx_count
        ser.write(payload)
        ser.flush()
        tx_count += len(payload)

    print("=" * 68)
    print(f" Port {device} @ {args.baud} 8N1   SET GENERATED ROOT PASSWORD")
    print(" No TX/RX content is written to disk.")
    print(f" Password file: {pw_file}")
    print("=" * 68)

    status = "UNKNOWN"
    try:
        time.sleep(0.3)
        send(b"\r")
        if not read_until(rb"root@OpenWrt:~#", 6.0):
            status = "NO_SHELL_PROMPT"
            print("[FAIL] root shell prompt not seen; no password sent.")
            return 6
        send(b"passwd\r")
        if not read_until(rb"New password:", 5.0):
            status = "NO_NEW_PASSWORD_PROMPT"
            print("[FAIL] passwd New password prompt not seen.")
            return 6
        send(password.encode("ascii") + b"\r")
        if not read_until(rb"Retype password:", 5.0):
            status = "NO_RETYPE_PROMPT"
            print("[FAIL] passwd Retype password prompt not seen.")
            return 6
        send(password.encode("ascii") + b"\r")
        if read_until(rb"password for root changed", 6.0):
            status = "PASSWORD_CHANGED"
            print("[OK] root password changed.")
            print(f"[INFO] Store the password from {pw_file} in a password manager, then delete the file.")
        else:
            status = "CHANGE_NOT_CONFIRMED"
            print("[FAIL] success message not seen; inspect the router console.")
            return 6
    finally:
        try:
            ser.close()
        except Exception:
            pass
        meta.write_text(json.dumps({
            "mode": "set-generated-root-password",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "status": status,
            "tx_bytes": tx_count,
            "rx_bytes_seen": len(rx),
            "tx_logged": False,
            "rx_logged": False,
            "password_file": str(pw_file),
        }, indent=2), encoding="utf-8")

    return 0 if status == "PASSWORD_CHANGED" else 6


if __name__ == "__main__":
    raise SystemExit(main())
