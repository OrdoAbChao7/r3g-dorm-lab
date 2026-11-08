#!/usr/bin/env python3
"""Read-only UART capture that survives CH340 re-enumeration.

The R3G power-on transient can make the CH340 disappear from Windows and
reappear. This tool reopens the same COM port and keeps one continuous log.
It has no serial write path.
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

    ap = argparse.ArgumentParser(description="R3G read-only UART capture with reconnect")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--duration", type=float, default=45.0)
    ap.add_argument("--reconnect-wait", type=float, default=30.0)
    args = ap.parse_args()

    if serial is None:
        print("pyserial is not installed.", file=sys.stderr)
        return 5

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = out / f"r3g_reconnect_{stamp}"
    rx_bin, txt, meta = (base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json"))
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={args.port} baud={args.baud} "
               f"8N1 mode=READ-ONLY-RECONNECT\n")
    text.flush()

    rx_sha = hashlib.sha256()
    rx_total = 0
    reconnects = 0
    drops = 0
    t0 = time.monotonic()
    ser = None
    device = args.port.upper()

    def connect() -> bool:
        nonlocal ser
        info = find_port(device)
        if info is None:
            return False
        vidpid = parse_vidpid(info.hwid or "") or "?"
        if vidpid not in KNOWN_ADAPTERS:
            print(f"Refusing unknown adapter {vidpid}.", file=sys.stderr)
            return False
        try:
            ser = open_port(device, args.baud)
        except Exception as exc:
            print(f"[connect] {device} failed: {exc}", file=sys.stderr)
            ser = None
            return False
        print(f"[connect] {device} {vidpid} opened", flush=True)
        text.write(f"\n# connected {datetime.now().isoformat()} vidpid={vidpid}\n")
        text.flush()
        return True

    print("=" * 68)
    print(f" Port {device} @ {args.baud} 8N1   READ-ONLY RECONNECT CAPTURE")
    print(" No serial write path. Power on the router after this message.")
    print("=" * 68)

    try:
        while time.monotonic() - t0 < args.duration:
            if ser is None:
                if not connect():
                    time.sleep(0.5)
                    continue
            try:
                waiting = ser.in_waiting
                chunk = ser.read(waiting if waiting else 1)
            except Exception as exc:
                drops += 1
                print(f"\n[DROP] {exc}", flush=True)
                text.write(f"\n# DROP {datetime.now().isoformat()} {exc}\n")
                text.flush()
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
                continue

            if chunk:
                raw.write(chunk)
                raw.flush()
                rx_sha.update(chunk)
                rx_total += len(chunk)
                text.write(chunk.decode("latin-1"))
                text.flush()
                sys.stdout.write(chunk.decode("latin-1"))
                sys.stdout.flush()
            else:
                # Detect unplugged adapter even when read() returns no data.
                if find_port(device) is None:
                    drops += 1
                    print("\n[DROP] port disappeared", flush=True)
                    text.write(f"\n# DROP {datetime.now().isoformat()} port disappeared\n")
                    text.flush()
                    try:
                        ser.close()
                    except Exception:
                        pass
                    ser = None
                    continue

            if ser is None:
                wait_start = time.monotonic()
                while time.monotonic() - wait_start < args.reconnect_wait:
                    if connect():
                        reconnects += 1
                        break
                    time.sleep(0.5)
                if ser is None:
                    print("\n[STOP] port did not return.", flush=True)
                    break
    except KeyboardInterrupt:
        print("\n[STOP] interrupted by user.", flush=True)
    finally:
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass
        raw.close()
        text.close()
        meta.write_text(json.dumps({
            "mode": "read-only-reconnect",
            "port": device,
            "baud": args.baud,
            "rx_bytes": rx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "drops": drops,
            "reconnects": reconnects,
            "rx_file": str(rx_bin),
            "text_file": str(txt),
        }, indent=2), encoding="utf-8")
        print(f"\nrx_bytes={rx_total} drops={drops} reconnects={reconnects}")
        print(f"rx={rx_bin}\ntext={txt}\nmeta={meta}")

    return 0 if rx_total else 6


if __name__ == "__main__":
    raise SystemExit(main())
