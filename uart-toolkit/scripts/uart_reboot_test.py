#!/usr/bin/env python3
"""Reboot the router over UART and capture the full boot log.

Fixed commands only: `sync` then `reboot`. Requires --allow-tx and
--confirm-reboot. It does not enter U-Boot menus, does not write flash,
and does not send anything after the reboot command.

The tool waits for the shutdown/reboot and captures output until the
OpenWrt login prompt appears (or --watch seconds elapse), then reports
which boot milestones were observed (UBI attach, WAN DHCP lease,
hostapd AP-ENABLED, init complete, login prompt).
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
BOOT_DONE = b"Please press Enter to activate this console."

MILESTONES = [
    ("ubi_attach", b"ubi0: attached mtd9"),
    ("squashfs_root", b"VFS: Mounted root (squashfs"),
    ("ubifs_overlay", b"mounted UBI device 0, volume 1"),
    ("radio_24", b"mt7603e 0000:01:00.0: firmware init done"),
    ("radio_5", b"mt76x2e 0000:02:00.0: Firmware running!"),
    ("wan_link", b"wan: Link is Up - 1Gbps"),
    ("ap24_forward", b"phy0-ap0 entered forwarding state"),
    ("ap5_forward", b"phy1-ap0 entered forwarding state"),
    ("init", b"procd: - init -"),
    ("boot_done", b"Please press Enter to activate this console."),
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

    ap = argparse.ArgumentParser(description="Reboot the router over UART and capture the boot log")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--allow-tx", action="store_true")
    ap.add_argument("--confirm-reboot", action="store_true")
    ap.add_argument("--watch", type=float, default=180.0, help="seconds to capture after reboot")
    args = ap.parse_args()

    if not args.allow_tx or not args.confirm_reboot:
        print("REFUSED: pass --allow-tx and --confirm-reboot.", file=sys.stderr)
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
    base = out / f"r3g_reboot_test_{stamp}"
    rx_bin, txt, meta, actions_path = (
        base.with_suffix(s) for s in (".rx.bin", ".log", ".meta.json", ".actions.json")
    )
    raw = open(rx_bin, "wb")
    text = open(txt, "w", encoding="utf-8", newline="")
    text.write(f"# start={datetime.now().isoformat()} port={device} baud={args.baud} "
               f"8N1 mode=REBOOT-TEST commands=['sync', 'reboot']\n")
    text.flush()
    rx_sha = hashlib.sha256()
    rx_total = 0
    recent = b""
    actions = []
    ser = open_port(device, args.baud)

    def pump(timeout: float, stop_at_prompt: bool = False, stop_at_boot: bool = False) -> bool:
        nonlocal rx_total, recent
        end = time.monotonic() + timeout
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
            recent = (recent + chunk)[-65536:]
            if stop_at_prompt and PROMPT in recent:
                return True
            if stop_at_boot and BOOT_DONE in recent:
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
    print(f" Port {device} @ {args.baud} 8N1   REBOOT TEST (sync -> reboot -> capture)")
    print("=" * 72)

    ok = True
    try:
        time.sleep(0.3)
        send(b"\r", "activate-console")
        if not pump(10.0, stop_at_prompt=True):
            print("\n[FAIL] no shell prompt; refusing to reboot without a verified console.", flush=True)
            ok = False
            return 6
        recent = b""
        send(b"sync\r", "sync")
        if not pump(30.0, stop_at_prompt=True):
            print("\n[FAIL] sync did not return a prompt; refusing to reboot.", flush=True)
            ok = False
            return 7
        recent = b""
        send(b"reboot\r", "reboot")
        observed = pump(args.watch, stop_at_boot=True)
        if observed:
            pump(10.0)  # let late DHCP/hostapd lines flush
    finally:
        try:
            ser.close()
        except Exception:
            pass
        raw.close()
        text.close()
        actions_path.write_text(json.dumps(actions, indent=2), encoding="utf-8")
        milestones = {name: (needle in recent) for name, needle in MILESTONES}
        meta.write_text(json.dumps({
            "mode": "reboot-test",
            "port": device,
            "baud": args.baud,
            "vidpid": vidpid,
            "commands": ["sync", "reboot"],
            "watch_seconds": args.watch,
            "boot_done_seen": bool(milestones.get("login_prompt")),
            "milestones": milestones,
            "rx_bytes": rx_total,
            "rx_sha256": rx_sha.hexdigest(),
            "rx_file": str(rx_bin),
            "text_file": str(txt),
            "actions_file": str(actions_path),
        }, indent=2), encoding="utf-8")
        print("\n--- boot milestones ---")
        for name, seen in milestones.items():
            print(f"{name:14s} {'SEEN' if seen else 'not seen'}")
        print(f"\nrx_bytes={rx_total}")
        print(f"rx={rx_bin}\ntext={txt}\nmeta={meta}\nactions={actions_path}")

    return 0 if milestones.get("login_prompt") else 6


if __name__ == "__main__":
    raise SystemExit(main())
