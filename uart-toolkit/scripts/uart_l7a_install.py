#!/usr/bin/env python3
"""L7-A install step: send the fixed OpenWrt install command, then monitor.

This is the only tool that intentionally starts an install write. It requires both
--allow-tx and --confirm-l7a, sends exactly one install command, and then only
reads serial output (including across CH340 re-enumeration). It never sends a
second command or any boot confirmation.
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

    ap = argparse.ArgumentParser(description="Authorized L7-A install and monitor")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--image", default="/tmp/fw.bin")
    ap.add_argument("--duration", type=float, default=240.0)
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-l7a", action="store_true")
    args = ap.parse_args()

    if not args.allow_tx or not args.confirm_l7a:
        print("REFUSED: L7-A install requires --allow-tx and --confirm-l7a.",
              file=sys.stderr)
        return 2
    if serial is None:
        print("pyserial is not installed.", file=sys.stderr)
        return 5
    if not args.image.startswith("/tmp/") or "/" in args.image[5:]:
        print("REFUSED: image must be a single file under /tmp.", file=sys.stderr)
        return 2

    device = args.port.upper()
    info = find_port(device)
    if info is None:
        print(f"Port {device} is not present.", file=sys.stderr)
        return 3
    vidpid = parse_vidpid(info.hwid or "") or "?"
    if vidpid not in KNOWN_ADAPTERS:
        print(f"Refusing unknown adapter {vidpid}.", file=sys.stderr)
        return 4

    command = "sysupgrade -n " + args.image

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = out / f"r3g_l7a_install_{stamp}"
    rx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=L7A-INSTALL image={args.image}\n")
    text.flush()
    rx_sha = hashlib.sha256()
    rx_total = 0
    actions = []
    ser = None
    drops = 0

    def connect() -> bool:
        nonlocal ser
        if find_port(device) is None:
            return False
        try:
            ser = open_port(device, args.baud)
        except Exception:
            ser = None
            return False
        print(f"[connect] {device} opened", flush=True)
        return True

    def pump_until(deadline: float) -> None:
        nonlocal rx_total, ser, drops
        while time.monotonic() < deadline:
            if ser is None:
                if not connect():
                    time.sleep(0.4)
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

    print("=" * 72)
    print(f" Port {device} @ {args.baud} 8N1   L7-A INSTALL")
    print(f" Fixed command: {command}")
    print(" This writes NAND and may reboot the router. Monitoring only afterwards.")
    print("=" * 72)

    if not connect():
        print("Port not available.", file=sys.stderr)
        return 3
    try:
        time.sleep(0.3)
        ser.write(b"\r")
        ser.flush()
        actions.append({"at_s": round(time.monotonic(), 3), "action": "activate-console",
                        "bytes_hex": "0d", "bytes_ascii": "\\r"})
        pump_until(time.monotonic() + 1.0)
        ser.write((command + "\r").encode("utf-8"))
        ser.flush()
        actions.append({"at_s": round(time.monotonic(), 3), "action": "install",
                        "bytes_hex": (command + "\r").encode("utf-8").hex(),
                        "bytes_ascii": command + "\r"})
        print(f"\n[TX] {command}", flush=True)
        pump_until(time.monotonic() + args.duration)
    except KeyboardInterrupt:
        print("\n[STOP] interrupted by user.", flush=True)
    finally:
        try:
            if ser is not None:
                ser.close()
        except Exception:
            pass
        raw.close()
        text.close()
        actions_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        meta.write_text(json.dumps({
            "mode": "l7a-install",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "image": args.image,
            "command": command,
            "drops": drops,
            "rx_bytes": rx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "text_file": str(txt),
            "actions_file": str(actions_path),
        }, indent=2), encoding="utf-8")
        print(f"\nrx_bytes={rx_total} drops={drops}")
        print(f"rx={rx_bin}\ntext={txt}\nmeta={meta}\nactions={actions_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
