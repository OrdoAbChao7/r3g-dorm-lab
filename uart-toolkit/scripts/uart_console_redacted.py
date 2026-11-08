#!/usr/bin/env python3
"""Interactive UART console with TX payloads deliberately NOT logged.

Use this for entering a password on the router console. Received bytes are
still logged for evidence; transmitted keystrokes are counted but never written
to disk. The tool has no automatic Enter, command, or timing logic.

Ctrl+] exits. The router's passwd program should suppress echo, so the password
should not appear in the RX log either; if it does, delete the RX/log files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
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

    ap = argparse.ArgumentParser(description="R3G interactive console with redacted TX")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    args = ap.parse_args()

    if not args.allow_tx:
        print("REFUSED: pass --allow-tx for the authorized password session.", file=sys.stderr)
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
    base = out / f"r3g_console_redacted_{stamp}"
    rx_bin, txt, meta = (base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json"))
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=INTERACTIVE-REDACTED-TX\n# TX payloads are NOT logged.\n")
    text.flush()
    rx_sha = hashlib.sha256()
    rx_total = tx_total = 0

    ser = open_port(device, args.baud)
    print("=" * 68)
    print(f" Port {device} @ {args.baud} 8N1   INTERACTIVE, TX NOT LOGGED")
    print(" Type only the password steps. Ctrl+] exits.")
    print("=" * 68)

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
        raw.close()
        text.close()
        meta.write_text(json.dumps({
            "mode": "interactive-redacted-tx",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "rx_bytes": rx_total,
            "tx_bytes": tx_total,
            "tx_logged": False,
            "rx_sha256": rx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "text_file": str(txt),
        }, indent=2), encoding="utf-8")
        print(f"\nrx={rx_bin}\ntext={txt}\nmeta={meta}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
