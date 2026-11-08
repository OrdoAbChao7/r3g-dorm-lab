#!/usr/bin/env python3
"""Interactive UART console for the R3G U-Boot console (SEPARATE from capture).

This tool can transmit only bytes you press yourself. It is intentionally not
part of uart_capture.py, which has no serial-write path at all.

Safety:
  * Requires --allow-tx; without it the tool exits before opening any port.
  * 115200 8N1, no flow control, DTR/RTS de-asserted.
  * Refuses unknown USB VID:PID adapters unless --allow-any-port is explicit.
  * No automatic Enter, no automatic command, no scheduled keystrokes.
  * Ctrl+] exits. Every received byte is logged; every transmitted byte is
    logged separately in .tx.bin.

This tool is NOT authorized for the current L0-L2 phase. It exists for a
future, explicitly authorized L4 session.

Example:
    python -I uart_console.py --port COM5 --allow-tx
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
except ImportError:
    serial = None
    list_ports = None

TOOLKIT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = TOOLKIT_ROOT / "logs"
KNOWN_ADAPTERS = {"1A86:7523": "CH340", "10C4:EA60": "CP210x", "0403:6001": "FTDI"}
ESP_IDS = {"303A:1001", "303A:0002", "303A:4001"}


def parse_vidpid(hwid: str) -> str | None:
    if not hwid:
        return None
    m = re.search(r"VID[:=]PID[=:]([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})", hwid)
    if m:
        return f"{m.group(1)}:{m.group(2)}".upper()
    v = re.search(r"VID[_:=]?([0-9A-Fa-f]{4})", hwid)
    p = re.search(r"PID[_:=]?([0-9A-Fa-f]{4})", hwid)
    if v and p:
        return f"{v.group(1)}:{p.group(1)}".upper()
    return None


def find_port(device: str):
    for p in list_ports.comports():
        if p.device.upper() == device.upper():
            return p
    return None


def open_port(device: str, baud: int) -> "serial.Serial":
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
    ap = argparse.ArgumentParser(description="R3G interactive UART console (TX capable)")
    ap.add_argument("--port", default="")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true",
                    help="required acknowledgement that this tool can transmit")
    ap.add_argument("--allow-any-port", action="store_true")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        if serial is None:
            print("pyserial is not installed; --list needs it.", file=sys.stderr)
            return 5
        for p in list_ports.comports():
            vid = parse_vidpid(p.hwid or "") or "?"
            print(f"{p.device}  {KNOWN_ADAPTERS.get(vid, 'unknown'):10s}  {p.description}  hwid={p.hwid}")
        return 0
    if not args.allow_tx:
        print("REFUSED: interactive TX requires --allow-tx.", file=sys.stderr)
        print("For boot-log capture use uart_capture.py (read-only, no TX path).", file=sys.stderr)
        return 2
    if serial is None:
        print("pyserial is not installed.", file=sys.stderr)
        return 5
    if not args.port:
        print("Pass --port COMx.", file=sys.stderr)
        return 2

    device = args.port.upper()
    info = find_port(device)
    if info is None:
        print(f"Port {device} is not present.", file=sys.stderr)
        return 3
    vidpid = parse_vidpid(info.hwid or "") or "?"
    if vidpid in ESP_IDS:
        print(f"Refusing {vidpid}: Espressif device, not the R3G adapter.", file=sys.stderr)
        return 4
    if not args.allow_any_port and vidpid not in KNOWN_ADAPTERS:
        print(f"Refusing unknown adapter {vidpid}; use --allow-any-port only if certain.",
              file=sys.stderr)
        return 4

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = out / f"r3g_console_{stamp}"
    rx_bin, tx_bin, txt, meta = (base.with_suffix(s) for s in (".rx.bin", ".tx.bin", ".log", ".meta.json"))
    raw = open(rx_bin, "wb")
    sent = open(tx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 vidpid={vidpid} mode=INTERACTIVE-TX\n")
    text.flush()
    rx_sha = hashlib.sha256()
    tx_sha = hashlib.sha256()
    rx_total = tx_total = 0

    ser = open_port(device, args.baud)
    print("=" * 64)
    print(f" Port {device} @ {args.baud} 8N1   INTERACTIVE TX ENABLED")
    print(" Only keys you press are sent. Ctrl+] exits.")
    print(" Do not type flash/NVRAM commands unless separately authorized.")
    print("=" * 64)

    import msvcrt
    try:
        while True:
            while msvcrt.kbhit():
                ch = msvcrt.getwch()
                if ch in ("\x00", "\xe0"):
                    msvcrt.getwch()
                    continue
                if ch == "\x1d":  # Ctrl+]
                    raise KeyboardInterrupt
                payload = b"\r" if ch == "\r" else (b"\x7f" if ch == "\x08" else ch.encode("latin-1", "replace"))
                ser.write(payload)
                ser.flush()
                sent.write(payload)
                sent.flush()
                tx_sha.update(payload)
                tx_total += len(payload)
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
    except KeyboardInterrupt:
        pass
    finally:
        try:
            ser.close()
        except Exception:
            pass
        raw.close(); sent.close(); text.close()
        meta.write_text(json.dumps({
            "mode": "interactive-tx", "port": device, "baud": args.baud,
            "vidpid": vidpid, "rx_bytes": rx_total, "tx_bytes": tx_total,
            "rx_sha256": rx_sha.hexdigest(), "tx_sha256": tx_sha.hexdigest(),
            "rx_file": str(rx_bin), "tx_file": str(tx_bin), "text_file": str(txt),
        }, indent=2), encoding="utf-8")
        print(f"\nrx={rx_bin}\ntx={tx_bin}\nmeta={meta}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
