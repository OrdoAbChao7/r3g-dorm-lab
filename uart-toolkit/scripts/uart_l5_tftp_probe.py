#!/usr/bin/env python3
"""One-shot L5 TFTP probe: menu 1 (load initramfs to SDRAM) only.

This probe is deliberately narrow. It can transmit only:
  * menu key 1 + Enter
  * the U-Boot device IP + Enter
  * the U-Boot server IP + Enter
  * the initramfs filename + Enter

It never sends a boot confirmation, a flash command, or any other command.
Start it while the router is already in its boot loop; the CH340 may re-enumerate
if the router is powered on while the port is open.
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
ESP_IDS = {"303A:1001", "303A:0002", "303A:4001"}

MENU_RE = re.compile(rb"Please choose the operation:")
DEVICE_IP_RE = re.compile(rb"Input device IP", re.IGNORECASE)
SERVER_IP_RE = re.compile(rb"Input server IP", re.IGNORECASE)
FILENAME_RE = re.compile(rb"Input Linux Kernel filename", re.IGNORECASE)
START_RE = re.compile(rb"Starting kernel|## Booting image|TFTP", re.IGNORECASE)
Y_N_RE = re.compile(rb"\(Y/N\)|Are you sure", re.IGNORECASE)


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

    ap = argparse.ArgumentParser(description="One-shot L5 menu-1 TFTP probe")
    ap.add_argument("--port", default="")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--device-ip", default="192.168.31.1")
    ap.add_argument("--server-ip", default="192.168.31.100")
    ap.add_argument("--filename", required=True,
                    help="exact TFTP filename, no path")
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--allow-any-port", action="store_true")
    ap.add_argument("--menu-timeout", type=float, default=300.0)
    ap.add_argument("--prompt-timeout", type=float, default=45.0)
    ap.add_argument("--quiet-time", type=float, default=8.0)
    ap.add_argument("--max-after", type=float, default=120.0)
    ap.add_argument("--reconnect-wait", type=float, default=30.0)
    args = ap.parse_args()

    if not args.allow_tx:
        print("REFUSED: this probe transmits; pass --allow-tx for the authorized L5 session.",
              file=sys.stderr)
        return 2
    if serial is None:
        print("pyserial is not installed.", file=sys.stderr)
        return 5
    if not args.port:
        print("Pass --port COMx.", file=sys.stderr)
        return 2
    if "/" in args.filename or "\\" in args.filename:
        print("REFUSED: filename must be a basename, not a path.", file=sys.stderr)
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
    base = out / f"r3g_l5probe_{stamp}"
    rx_bin, tx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".tx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    sent = open(tx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 vidpid={vidpid} mode=L5-MENU1-TFTP "
               f"device_ip={args.device_ip} server_ip={args.server_ip} filename={args.filename}\n")
    text.flush()

    rx_sha = hashlib.sha256()
    tx_sha = hashlib.sha256()
    rx_total = tx_total = 0
    actions: list[dict] = []
    state = "WAIT_MENU"
    buffer = bytearray()
    t0 = time.monotonic()
    last_rx = t0
    prompt_at = 0.0
    start_at = 0.0
    drops = 0
    reconnects = 0
    ser = None

    def connect() -> bool:
        nonlocal ser, reconnects
        if find_port(device) is None:
            return False
        try:
            ser = open_port(device, args.baud)
        except Exception:
            ser = None
            return False
        reconnects += 1
        print(f"[connect] {device} opened", flush=True)
        return True

    def drop_port(exc: Exception) -> bool:
        nonlocal ser, drops, state, prompt_at
        drops += 1
        print(f"\n[DROP] {exc}", flush=True)
        text.write(f"\n# DROP {datetime.now().isoformat()} {exc}\n")
        text.flush()
        try:
            if ser is not None:
                ser.close()
        except Exception:
            pass
        ser = None
        buffer.clear()
        if state == "LOADING":
            state = "DROP_DURING_LOAD"
            return False
        state = "WAIT_MENU"
        prompt_at = 0.0
        return True

    def send(payload: bytes, action: str) -> None:
        nonlocal tx_total
        if ser is None:
            raise serial.SerialException("port is not open")
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

    ser = None
    connect()
    print("=" * 72)
    print(f" Port {device} @ {args.baud} 8N1   L5 MENU-1 TFTP PROBE")
    print(f" Will send: 1, then accept device/server defaults with Enter, "
          f"then {args.filename} + Enter")
    print(f" Waiting up to {args.menu_timeout:.0f}s for the U-Boot menu.")
    print("=" * 72)

    try:
        while True:
            if ser is None:
                if not connect():
                    time.sleep(0.5)
                    continue
            now = time.monotonic()
            try:
                waiting = ser.in_waiting
                chunk = ser.read(waiting if waiting else 1)
            except (serial.SerialException, OSError) as exc:
                if drop_port(exc):
                    continue
                break
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
                if len(buffer) > 131072:
                    del buffer[:-65536]
                last_rx = time.monotonic()

                if state == "WAIT_MENU" and MENU_RE.search(buffer):
                    state = "WAIT_DEVICE_IP"
                    prompt_at = time.monotonic()
                    print("\n[MENU] sending menu 1 (single key, no Enter).", flush=True)
                    send(b"1", "menu1")
                elif state == "WAIT_DEVICE_IP" and DEVICE_IP_RE.search(buffer):
                    state = "WAIT_SERVER_IP"
                    prompt_at = time.monotonic()
                    print("\n[PROMPT] device IP; accepting default.", flush=True)
                    time.sleep(0.10)
                    send(b"\r", "device-default")
                elif state == "WAIT_SERVER_IP" and SERVER_IP_RE.search(buffer):
                    state = "WAIT_FILENAME"
                    prompt_at = time.monotonic()
                    print("\n[PROMPT] server IP; accepting default.", flush=True)
                    time.sleep(0.10)
                    send(b"\r", "server-default")
                elif state == "WAIT_FILENAME" and FILENAME_RE.search(buffer):
                    state = "LOADING"
                    start_at = time.monotonic()
                    last_rx = start_at
                    print("\n[PROMPT] filename; sending initramfs name.", flush=True)
                    time.sleep(0.10)
                    send((args.filename + "\r").encode("ascii"), "filename")
                elif state == "LOADING" and Y_N_RE.search(buffer):
                    state = "MANUAL_REQUIRED"
                    print("\n[STOP] U-Boot asked a Y/N question; no answer sent.", flush=True)
                    break
                elif state == "LOADING" and START_RE.search(buffer):
                    # Keep collecting; do not send anything else.
                    pass
                continue

            if state == "WAIT_MENU" and now - t0 > args.menu_timeout:
                print(f"\n[TIMEOUT] menu not seen in {args.menu_timeout:.0f}s.", flush=True)
                break
            if state in ("WAIT_DEVICE_IP", "WAIT_SERVER_IP", "WAIT_FILENAME"):
                if now - prompt_at > args.prompt_timeout:
                    print(f"\n[TIMEOUT] {state} prompt not seen.", flush=True)
                    break
            if state == "LOADING":
                if now - start_at > args.max_after:
                    print("\n[STOP] load/collect hard cap reached.", flush=True)
                    break
                if now - last_rx > args.quiet_time and now - start_at > 5.0:
                    print("\n[STOP] serial quiet after load/start.", flush=True)
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
            "mode": "l5-menu1-tftp-probe",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "state": state,
            "device_ip": args.device_ip,
            "server_ip": args.server_ip,
            "filename": args.filename,
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

    return 0 if state in ("LOADING", "MANUAL_REQUIRED") else 6


if __name__ == "__main__":
    raise SystemExit(main())
