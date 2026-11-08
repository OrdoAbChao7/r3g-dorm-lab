#!/usr/bin/env python3
"""READ-ONLY UART capture for the Xiaomi R3G boot log.

This tool intentionally contains NO code that writes to a serial port.
Interactive transmission lives in the separate uart_console.py and is not
part of this tool.

Properties:
  * 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control.
  * DTR and RTS de-asserted before and after opening the port.
  * Refuses ports whose USB VID:PID is not a known USB-TTL adapter
    (CH340 1A86:7523, CP210x 10C4:EA60, FTDI 0403:6001) unless the operator
    explicitly passes --allow-any-port.
  * Refuses phantom/absent ports (pyserial only lists present ports).
  * Nothing is sent automatically; there is no auto-Enter and no command.
  * Saves raw .bin, text .log and .meta.json with SHA-256 and adapter identity.
  * Replay mode (--replay) feeds a recorded file through the same writer
    without opening any serial port.

Examples:
    python -I uart_capture.py --list
    python -I uart_capture.py --port COM5 --duration 180
    python -I uart_capture.py --replay tests/sample_uboot_log.txt --out-dir logs
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

KNOWN_ADAPTERS = {
    "1A86:7523": "CH340",
    "10C4:EA60": "CP210x",
    "0403:6001": "FTDI",
}
ESP_IDS = {"303A:1001", "303A:0002", "303A:4001"}


def parse_vidpid(hwid: str) -> str | None:
    if not hwid:
        return None
    # pyserial Windows form: "USB VID:PID=1A86:7523 SER=..."
    m = re.search(r"VID[:=]PID[=:]([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})", hwid)
    if m:
        return f"{m.group(1)}:{m.group(2)}".upper()
    # Device-instance form: "USB\VID_1A86&PID_7523\..." or "VID=1A86 PID=7523"
    v = re.search(r"VID[_:=]?([0-9A-Fa-f]{4})", hwid)
    p = re.search(r"PID[_:=]?([0-9A-Fa-f]{4})", hwid)
    if v and p:
        return f"{v.group(1)}:{p.group(1)}".upper()
    return None


def adapter_name(vidpid: str) -> str:
    if vidpid in KNOWN_ADAPTERS:
        return KNOWN_ADAPTERS[vidpid]
    if vidpid in ESP_IDS:
        return "Espressif (NOT a target adapter)"
    return "unknown"


def validate_adapter(info, allow_any: bool, expected: set[str]) -> tuple[bool, str]:
    vidpid = parse_vidpid(getattr(info, "hwid", "") or "")
    if vidpid is None:
        if allow_any:
            return True, "no VID:PID in hwid; allowed by --allow-any-port"
        return False, "no USB VID:PID in hwid; refusing (use --allow-any-port only if you are certain)"
    if vidpid in ESP_IDS:
        return False, f"{vidpid} is an Espressif device, not the R3G adapter"
    if expected and vidpid not in expected:
        return False, f"{vidpid} not in expected adapter list {sorted(expected)}"
    if not allow_any and vidpid not in KNOWN_ADAPTERS:
        return False, f"{vidpid} is not a known USB-TTL adapter (use --allow-any-port to override)"
    return True, f"{vidpid} ({adapter_name(vidpid)})"


def list_serial_ports(show_all: bool = True) -> int:
    print("Available serial ports (present devices only):")
    ports = list(list_ports.comports()) if list_ports else []
    if not ports:
        print("  (none)")
        return 2
    for p in ports:
        vidpid = parse_vidpid(p.hwid) or "?"
        print(f"  {p.device:8s} {adapter_name(vidpid):32s} {p.description}")
        print(f"           hwid={p.hwid}")
    return 0


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
    ser.xonxoff = False
    ser.rtscts = False
    ser.dsrdtr = False
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.dtr = False
    ser.rts = False
    return ser


class CaptureWriter:
    def __init__(self, out_dir: Path, tag: str):
        out_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        base = out_dir / f"{tag}_{stamp}"
        self.bin_path = base.with_suffix(".bin")
        self.log_path = base.with_suffix(".log")
        self.meta_path = base.with_suffix(".meta.json")
        self.raw = open(self.bin_path, "wb")
        self.text = open(self.log_path, "w", encoding="utf-8", newline="")
        self.total = 0
        self.sha = hashlib.sha256()

    def write(self, chunk: bytes) -> None:
        if not chunk:
            return
        self.raw.write(chunk)
        self.raw.flush()
        self.sha.update(chunk)
        self.total += len(chunk)
        self.text.write(chunk.decode("latin-1"))
        self.text.flush()
        sys.stdout.write(chunk.decode("latin-1"))
        sys.stdout.flush()

    def header(self, lines: list[str]) -> None:
        for line in lines:
            self.text.write("# " + line + "\n")
        self.text.flush()

    def close(self, meta: dict) -> None:
        try:
            self.raw.close()
        finally:
            self.text.close()
        meta.update(raw_file=str(self.bin_path), text_file=str(self.log_path),
                    bytes_received=self.total, raw_sha256=self.sha.hexdigest(),
                    ended_at=datetime.now().isoformat(timespec="seconds"))
        with open(self.meta_path, "w", encoding="utf-8") as fh:
            json.dump(meta, fh, indent=2, ensure_ascii=False)
        print(f"\n--- closed ---\nraw : {self.bin_path}\ntext: {self.log_path}\nmeta: {self.meta_path}")


def replay(path: Path, out_dir: Path, baud: int) -> int:
    data = path.read_bytes()
    writer = CaptureWriter(out_dir, "r3g_replay")
    writer.header([f"replay source={path}", f"baud={baud} 8N1 (no port opened)",
                   "mode=replay (self-test only)"])
    for i in range(0, len(data), 4096):
        writer.write(data[i:i + 4096])
        time.sleep(0.005)
    writer.close({"mode": "replay", "source": str(path), "baud": baud,
                  "port": None, "note": "replay does not touch any serial port"})
    return 0


def capture(device: str, baud: int, out_dir: Path, duration: float | None,
            allow_any: bool, expected: set[str]) -> int:
    info = find_port(device)
    if info is None:
        print(f"Port {device} is not present. Phantom COM numbers cannot be opened.", file=sys.stderr)
        return 3

    ok, why = validate_adapter(info, allow_any, expected)
    vidpid = parse_vidpid(info.hwid or "") or "?"
    if not ok:
        print(f"Refusing {device}: {why}", file=sys.stderr)
        print("This tool is read-only but refuses unknown adapters to avoid targeting the wrong device.",
              file=sys.stderr)
        return 4

    ser = open_port(device, baud)
    writer = CaptureWriter(out_dir, "r3g_uart")
    writer.header([
        f"start={datetime.now().isoformat(timespec='seconds')}",
        f"port={device} baud={baud} 8N1 no-flow",
        f"device={info.description} hwid={info.hwid} vidpid={vidpid} chip={adapter_name(vidpid)}",
        "mode=LISTEN-ONLY; this tool contains no serial write path",
        "DTR/RTS de-asserted; no automatic bytes are sent.",
    ])

    print("=" * 64)
    print(f" Port {device} @ {baud} 8N1   LISTEN-ONLY (no bytes are sent)")
    print(f" Device: {info.description}")
    print(f" HWID:   {info.hwid}")
    print(f" Adapter check: {why}")
    print(f" Output: {out_dir}")
    print(" Power on the router only when authorized. Exit: Ctrl+C")
    print("=" * 64)

    deadline = time.time() + duration if duration else None
    try:
        while True:
            if deadline and time.time() >= deadline:
                print("\nDuration reached.")
                break
            waiting = ser.in_waiting
            chunk = ser.read(waiting if waiting else 1)
            if chunk:
                writer.write(chunk)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            ser.close()
        except Exception:
            pass
        writer.close({
            "mode": "listen-only", "port": device, "baud": baud,
            "bytesize": 8, "parity": "none", "stopbits": 1, "flow_control": "none",
            "dtr": False, "rts": False, "device_description": info.description,
            "device_hwid": info.hwid, "vidpid": vidpid, "chip": adapter_name(vidpid),
            "serial_write_path": "none in this tool",
        })
    return 0


def main() -> int:
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="R3G read-only UART capture")
    ap.add_argument("--port", default="", help="COM port, e.g. COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--duration", type=float, default=0, help="seconds; 0 = until Ctrl+C")
    ap.add_argument("--allow-any-port", action="store_true",
                    help="allow an adapter with unknown/missing VID:PID (explicit risk)")
    ap.add_argument("--expect-vidpid", action="append", default=[],
                    help="restrict to this VID:PID, e.g. 1A86:7523; repeatable")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--replay", default="", help="offline self-test: replay a file")
    args = ap.parse_args()

    if args.replay:
        return replay(Path(args.replay), Path(args.out_dir), args.baud)

    if args.list:
        if serial is None:
            print("pyserial is not installed; --list needs it. Replay does not.", file=sys.stderr)
            return 5
        return list_serial_ports()

    if serial is None:
        print("pyserial is not installed. Run: python -m pip install pyserial", file=sys.stderr)
        return 5

    if not args.port:
        list_serial_ports()
        print("\nPass --port COMx (see above).")
        return 2

    expected = {v.upper() for v in args.expect_vidpid} if args.expect_vidpid else set()
    return capture(args.port.upper(), args.baud, Path(args.out_dir),
                   args.duration or None, args.allow_any_port, expected)


if __name__ == "__main__":
    raise SystemExit(main())
