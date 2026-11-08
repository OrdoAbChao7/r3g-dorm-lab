#!/usr/bin/env python3
"""Restart uhttpd after the LuCI install and verify the local HTTP endpoint.

Fixed commands only; requires --allow-tx and --confirm-luci-enable.
Service restart and read-only HTTP checks; no UCI changes, no Flash writes.
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
PROMPT = b"root@OpenWrt:~#"

COMMANDS = [
    ("date", 15.0),
    ("/etc/init.d/uhttpd restart", 60.0),
    ("sleep 2; wget -O /dev/null http://127.0.0.1/cgi-bin/luci/; echo LUCI_HTTP_RC=$?", 60.0),
    ("wget -O /dev/null http://192.168.1.1/cgi-bin/luci/; echo LUCI_HTTP_LAN_RC=$?", 60.0),
    ("logread | grep -iE 'uhttpd|luci|dispatcher' | tail -n 20", 20.0),
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

    ap = argparse.ArgumentParser(description="Restart uhttpd and verify LuCI over the UART console")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-luci-enable", action="store_true")
    args = ap.parse_args()

    if not args.allow_tx or not args.confirm_luci_enable:
        print("REFUSED: pass --allow-tx and --confirm-luci-enable.", file=sys.stderr)
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
    base = out / f"r3g_luci_enable_{stamp}"
    rx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=LUCI-ENABLE commands={[c for c, _ in COMMANDS]!r}\n")
    text.flush()
    rx_sha = hashlib.sha256()
    rx_total = 0
    actions = []
    ser = open_port(device, args.baud)

    def pump_until_prompt(timeout: float) -> bool:
        nonlocal rx_total
        end = time.monotonic() + timeout
        buf = b""
        while time.monotonic() < end:
            waiting = ser.in_waiting
            chunk = ser.read(waiting if waiting else 1)
            if not chunk:
                continue
            raw.write(chunk)
            raw.flush()
            rx_sha.update(chunk)
            rx_total += len(chunk)
            text.write(chunk.decode("latin-1"))
            text.flush()
            sys.stdout.write(chunk.decode("latin-1"))
            sys.stdout.flush()
            buf = (buf + chunk)[-8192:]
            if PROMPT in buf:
                return True
        return False

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
    print(f" Port {device} @ {args.baud} 8N1   LUCI ENABLE (fixed commands)")
    print(" restart uhttpd -> local HTTP self-check")
    print("=" * 72)

    results = []
    try:
        time.sleep(0.3)
        send(b"\r", "activate-console")
        pump_until_prompt(10.0)
        for cmd, timeout in COMMANDS:
            send((cmd + "\r").encode("utf-8"), cmd)
            ok = pump_until_prompt(timeout)
            results.append({"command": cmd, "prompt_returned": ok})
            if not ok:
                print(f"\n[TIMEOUT] no prompt within {timeout:.0f}s after: {cmd}", flush=True)
                break
    finally:
        try:
            ser.close()
        except Exception:
            pass
        raw.close()
        text.close()
        actions_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        meta.write_text(json.dumps({
            "mode": "luci-enable",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "commands": [c for c, _ in COMMANDS],
            "results": results,
            "rx_bytes": rx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "text_file": str(txt),
            "actions_file": str(actions_path),
        }, indent=2), encoding="utf-8")
        print(f"\nrx_bytes={rx_total}")
        print(f"rx={rx_bin}\ntext={txt}\nmeta={meta}\nactions={actions_path}")

    return 0 if all(r["prompt_returned"] for r in results) else 6


if __name__ == "__main__":
    raise SystemExit(main())
