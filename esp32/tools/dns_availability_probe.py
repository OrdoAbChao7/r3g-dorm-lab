#!/usr/bin/env python3
"""Continuous DNS availability probe for the ESP32 outage drill.

Queries the router's dnsmasq (192.168.1.1) once per interval and records
whether DNS answers, how long it took, and when it comes back. Read-only:
it sends ordinary DNS queries and changes nothing.

Usage:
  python dns_availability_probe.py --duration 600 --interval 1 --out drill.csv
"""

from __future__ import annotations

import argparse
import csv
import socket
import struct
import sys
import time
from datetime import datetime


def build_query(name: str, ident: int = 0x4242) -> bytes:
    q = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0)
    for label in name.rstrip(".").split("."):
        q += bytes([len(label)]) + label.encode("ascii")
    return q + b"\x00" + struct.pack(">HH", 1, 1)


def query(host: str, name: str, timeout: float) -> tuple[bool, float, str]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    t0 = time.perf_counter()
    try:
        sock.sendto(build_query(name), (host, 53))
        data, _ = sock.recvfrom(4096)
        dt = (time.perf_counter() - t0) * 1000
        rcode = data[3] & 0x0F if len(data) > 3 else 255
        return (rcode == 0, dt, f"rcode={rcode}")
    except socket.timeout:
        return (False, (time.perf_counter() - t0) * 1000, "timeout")
    except OSError as exc:
        return (False, (time.perf_counter() - t0) * 1000, f"error={exc}")
    finally:
        sock.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.1.1")
    ap.add_argument("--name", default="example.com")
    ap.add_argument("--duration", type=int, default=600)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    rows = []
    failures = 0
    first_fail = None
    last_fail = None
    back_at = None
    deadline = time.time() + args.duration

    print(f"probing {args.host} every {args.interval}s for {args.duration}s; log={args.out}")
    try:
        while time.time() < deadline:
            ok, ms, note = query(args.host, args.name, args.timeout)
            ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
            rows.append((ts, "ok" if ok else "FAIL", f"{ms:.0f}", note))
            if ok:
                if first_fail and back_at is None:
                    back_at = ts
                    print(f"[{ts}] DNS recovered after outage")
                print(f"[{ts}] ok {ms:6.0f} ms")
            else:
                failures += 1
                first_fail = first_fail or ts
                last_fail = ts
                print(f"[{ts}] FAIL {ms:6.0f} ms {note}")
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("interrupted")

    if args.out:
        with open(args.out, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["time", "result", "ms", "note"])
            w.writerows(rows)

    print("--- summary ---")
    print(f"samples={len(rows)} failures={failures}")
    print(f"first_failure={first_fail} last_failure={last_fail} recovered_at={back_at}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
