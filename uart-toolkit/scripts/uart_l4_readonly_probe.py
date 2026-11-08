#!/usr/bin/env python3
"""One-shot read-only L4 probe for the R3G U-Boot console.

Authorized scope for this probe:
  * Send exactly one menu key ("4") plus one Enter to enter the U-Boot CLI.
  * Send exactly one read-only command: printenv + Enter.
  * Send nothing else; only the two read-only actions above.

The probe must be started BEFORE router power-on. It waits for the real
"Please choose the operation:" banner, enters menu 4 immediately, waits for
the "MT7621 #" prompt, then sends printenv once and records the response.

This is a hardware-phase adjunct, not part of the frozen v5.2.1 manifest.
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
except ImportError:  # pragma: no cover - exercised by the no-pyserial test
    serial = None
    list_ports = None

TOOLKIT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = TOOLKIT_ROOT / "logs"
KNOWN_ADAPTERS = {"1A86:7523": "CH340", "10C4:EA60": "CP210x", "0403:6001": "FTDI"}
ESP_IDS = {"303A:1001", "303A:0002", "303A:4001"}

MENU_RE = re.compile(rb"Please choose the operation:")
PROMPT_RE = re.compile(rb"MT7621\s*#")
TX_POLICY = ("4", "\r", "printenv\r")


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

    ap = argparse.ArgumentParser(description="One-shot read-only R3G U-Boot probe")
    ap.add_argument("--port", default="")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true",
                    help="required acknowledgement that this probe transmits 4/Enter/printenv only")
    ap.add_argument("--allow-any-port", action="store_true")
    ap.add_argument("--menu-timeout", type=float, default=300.0,
                    help="seconds to wait for the U-Boot menu after opening the port")
    ap.add_argument("--prompt-timeout", type=float, default=15.0,
                    help="seconds to wait for the MT7621 prompt after menu 4")
    ap.add_argument("--quiet-time", type=float, default=6.0,
                    help="seconds of serial silence after printenv before stopping")
    ap.add_argument("--max-after", type=float, default=30.0,
                    help="hard cap for collection after printenv")
    args = ap.parse_args()

    if not args.allow_tx:
        print("REFUSED: this probe transmits; pass --allow-tx only for the authorized read-only session.",
              file=sys.stderr)
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
    base = out / f"r3g_l4probe_{stamp}"
    rx_bin, tx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".tx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    sent = open(tx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 vidpid={vidpid} mode=L4-READONLY-PROBE tx_policy={TX_POLICY!r}\n")
    text.flush()

    rx_sha = hashlib.sha256()
    tx_sha = hashlib.sha256()
    rx_total = tx_total = 0
    actions: list[dict] = []
    state = "WAIT_MENU"
    buffer = bytearray()
    t0 = time.monotonic()
    last_rx = t0
    menu_at = 0.0
    printenv_at = 0.0
    prompt_deadline = 0.0

    def send(payload: bytes, action: str) -> None:
        nonlocal tx_total
        ser.write(payload)
        ser.flush()
        sent.write(payload)
        sent.flush()
        tx_sha.update(payload)
        tx_total += len(payload)
        actions.append({
            "at_s": round(time.monotonic() - t0, 3),
            "action": action,
            "bytes_hex": payload.hex(),
            "bytes_ascii": payload.decode("latin-1"),
        })
        print(f"[TX] {action}: {payload!r}", flush=True)

    ser = open_port(device, args.baud)
    print("=" * 68)
    print(f" Port {device} @ {args.baud} 8N1   L4 READ-ONLY PROBE")
    print(" TX policy: menu '4' + Enter, then one 'printenv' + Enter. Nothing else.")
    print(f" Waiting up to {args.menu_timeout:.0f}s for the U-Boot menu. Power on now.")
    print("=" * 68)

    try:
        while True:
            now = time.monotonic()
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
                buffer.extend(chunk)
                if len(buffer) > 65536:
                    del buffer[:-32768]
                last_rx = time.monotonic()

                if state == "WAIT_MENU" and MENU_RE.search(buffer):
                    state = "WAIT_PROMPT"
                    menu_at = time.monotonic()
                    prompt_deadline = menu_at + args.prompt_timeout
                    print("\n[MENU] U-Boot menu detected; sending '4'.", flush=True)
                    send(b"4", "menu4")
                    time.sleep(0.15)
                    send(b"\r", "menu4-enter")
                elif state == "WAIT_PROMPT" and PROMPT_RE.search(buffer):
                    state = "COLLECT"
                    print("\n[PROMPT] MT7621 prompt detected; sending read-only printenv.", flush=True)
                    time.sleep(0.20)
                    send(b"printenv\r", "printenv")
                    printenv_at = time.monotonic()
                    last_rx = printenv_at
                continue

            if state == "WAIT_MENU" and now - t0 > args.menu_timeout:
                print(f"\n[TIMEOUT] U-Boot menu not seen in {args.menu_timeout:.0f}s; no bytes sent.",
                      flush=True)
                break
            if state == "WAIT_PROMPT" and now > prompt_deadline:
                print("\n[TIMEOUT] menu key sent but MT7621 prompt not seen; printenv NOT sent.",
                      flush=True)
                break
            if state == "COLLECT":
                if now - printenv_at > args.max_after:
                    print("\n[STOP] collection hard cap reached.", flush=True)
                    break
                if now - last_rx > args.quiet_time and now - printenv_at > 3.0:
                    print("\n[STOP] serial quiet after printenv.", flush=True)
                    break
    except KeyboardInterrupt:
        print("\n[STOP] interrupted by user.", flush=True)
        state = "INTERRUPTED"
    finally:
        try:
            ser.close()
        except Exception:
            pass
        raw.close()
        sent.close()
        text.close()
        actions_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        meta.write_text(json.dumps({
            "mode": "l4-readonly-probe",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "state": state,
            "tx_policy": list(TX_POLICY),
            "rx_bytes": rx_total,
            "tx_bytes": tx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "tx_sha256": tx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "tx_file": str(tx_bin),
            "text_file": str(txt),
            "actions_file": str(actions_path),
        }, indent=2), encoding="utf-8")
        print(f"\nstate={state}")
        print(f"rx={rx_bin}\ntx={tx_bin}\nmeta={meta}\nactions={actions_path}")

    return 0 if state == "COLLECT" else 6


if __name__ == "__main__":
    raise SystemExit(main())
