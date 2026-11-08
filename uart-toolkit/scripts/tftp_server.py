#!/usr/bin/env python3
"""Read-only TFTP server for the R3G U-Boot recovery (second-audit hardened).

Safety / correctness properties:

  * Serves only regular files inside --root; rejects absolute paths,
    drive letters, "..", and symlinks that resolve outside the root.
  * Refuses every WRQ (upload) and every non-RRQ opcode.
  * Data-transfer sockets bind to the SAME concrete IPv4 address as the
    listening socket, so replies do not follow the Wi-Fi default route.
  * Wildcard binds (0.0.0.0) are rejected.
  * When binding to a non-loopback address (i.e. actually serving the LAN),
    an exact-name allowlist is mandatory, every allowed file must have a
    SHA-256 pin, and every pin is verified against the file before startup.
  * ACK handling is strict: only the exact expected block number confirms a
    block. Duplicate ACKs of previous blocks are ignored (not success), and
    unexpected ACKs do not advance the transfer.
  * Logs every request, byte count and SHA-256; nothing is sent anywhere else.
  * Never changes Windows firewall, routes, Wi-Fi or adapter settings.

This is a file-transfer tool only. It cannot flash anything by itself.

Usage:
    python -I tftp_server.py --root ../firmware/tftp_stock \
        --bind 192.168.31.100 --port 69 \
        --allow kernel1.bin \
        --expect-sha256 kernel1.bin=ab893d6c0732dcea7f029fd3d7101b844ff9d2b2fc6114b24e908d466e3b6168
    python -I tftp_server.py --root ../firmware/tftp_stock --port 16969
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import os
import socket
import struct
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6
ERR_NOT_FOUND, ERR_ACCESS, ERR_ILLEGAL, ERR_EXISTS = 1, 2, 4, 6
ERR_OPTION = 8  # RFC 2347: option negotiation failed
MAX_BLOCK = 65464
MIN_BLOCK = 8
TFTP_DEFAULT_BLOCK = 512
LOOPBACK = "127.0.0.1"


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


class Logger:
    def __init__(self, path: str | None):
        self.fh = open(path, "a", encoding="utf-8") if path else None

    def __call__(self, msg: str) -> None:
        line = f"[{now()}] {msg}"
        print(line, flush=True)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()

    def close(self) -> None:
        if self.fh:
            self.fh.close()


def error_packet(code: int, msg: str) -> bytes:
    return struct.pack("!HH", OP_ERROR, code) + msg.encode() + b"\x00"


def parse_request(payload: bytes):
    parts = payload[2:].split(b"\x00")
    if len(parts) < 2:
        return None
    filename = parts[0].decode("utf-8", "replace")
    mode = parts[1].decode("ascii", "replace").lower()
    opts = []
    rest = parts[2:]
    for i in range(0, len(rest) - 1, 2):
        if not rest[i]:
            break
        opts.append((rest[i].decode("ascii", "replace").lower(),
                     rest[i + 1].decode("ascii", "replace")))
    return filename, mode, opts


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_config(root: Path, bind: str, allow: set[str], pins: dict[str, str]) -> list[str]:
    """Return a list of configuration errors. Empty list means valid."""
    errors: list[str] = []
    try:
        ip = ipaddress.ip_address(bind)
    except ValueError:
        return [f"--bind must be a concrete IPv4 address, got {bind!r}"]
    if ip.version != 4:
        errors.append("--bind must be IPv4")
    if str(ip) == "0.0.0.0":
        errors.append("wildcard bind 0.0.0.0 is rejected; specify the wired NIC IP")

    external = not ip.is_loopback
    if external:
        if not allow:
            errors.append("serving a non-loopback address requires --allow (exact filenames)")
        if not pins:
            errors.append("serving a non-loopback address requires --expect-sha256 pins")
        missing = sorted(a for a in allow if a not in pins)
        if missing:
            errors.append("every --allow file needs a SHA-256 pin; missing: " + ", ".join(missing))
        extra = sorted(p for p in pins if p not in allow)
        if extra:
            errors.append("pin given for file not in --allow: " + ", ".join(extra))

    for rel, digest in pins.items():
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest.lower()):
            errors.append(f"invalid SHA-256 pin for {rel}")
            continue
        if not root.is_dir():
            continue
        target = (root / rel).resolve()
        if root.resolve() not in target.parents and target != root.resolve():
            errors.append(f"pin path escapes root: {rel}")
            continue
        if not target.is_file():
            errors.append(f"pinned file missing: {rel}")
            continue
        actual = sha256_of(target)
        if actual != digest.lower():
            errors.append(f"pinned file hash mismatch: {rel} got {actual}")
    return errors


class Server:
    def __init__(self, root: Path, bind: str, port: int, allow: set[str],
                 pins: dict[str, str], max_block: int, log: Logger,
                 timeout: float = 3.0, retries: int = 5,
                 max_file_bytes: int = 16 * 1024 * 1024,
                 ready_file: str | None = None):
        self.root = root.resolve()
        self.bind = bind
        self.port = port
        self.allow = allow
        self.pins = pins
        self.max_block = max_block
        self.log = log
        self.timeout = timeout
        self.retries = retries
        self.max_file_bytes = max_file_bytes
        self.ready_file = ready_file

    def resolve_request(self, filename: str) -> Path | None:
        name = filename.replace("\\", "/")
        if name.startswith("/") or ":" in name:
            return None
        try:
            target = (self.root / name).resolve()
        except OSError:
            return None
        if target != self.root and self.root not in target.parents:
            return None
        if not target.is_file():
            return None
        rel = target.relative_to(self.root).as_posix()
        if self.allow and rel not in self.allow:
            return None
        return target

    def serve_forever(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((self.bind, self.port))
            # READY is emitted only after the UDP socket has actually bound.
            self.log(f"READY {self.bind}:{self.port}")
            if self.ready_file:
                try:
                    ready_path = Path(self.ready_file)
                    ready_tmp = ready_path.with_name(
                        ready_path.name + f".tmp.{os.getpid()}")
                    ready_tmp.write_text(
                        f"READY {self.bind}:{self.port}\n", encoding="utf-8")
                    os.replace(ready_tmp, ready_path)
                except OSError as exc:
                    self.log(f"cannot write ready file: {exc}")
            self.log(f"TFTP READ-ONLY serving '{self.root}' on {self.bind}:{self.port}")
            if self.allow:
                self.log(f"allowlist: {sorted(self.allow)}")
            if self.pins:
                self.log(f"SHA-256 pins: {len(self.pins)} file(s) verified at startup")
            while True:
                try:
                    data, addr = sock.recvfrom(4096)
                except KeyboardInterrupt:
                    self.log("stopping")
                    return
                if len(data) < 4:
                    continue
                op = struct.unpack("!H", data[:2])[0]
                if op == OP_RRQ:
                    req = parse_request(data)
                    if not req:
                        continue
                    threading.Thread(
                        target=self.handle_rrq, args=(req[0], req[1], req[2], addr),
                        daemon=True,
                    ).start()
                elif op == OP_WRQ:
                    self.log(f"REFUSED WRQ from {addr[0]}:{addr[1]}")
                    sock.sendto(error_packet(ERR_ACCESS, "Read-only server"), addr)
                else:
                    sock.sendto(error_packet(ERR_ILLEGAL, "Illegal TFTP operation"), addr)

    def handle_rrq(self, filename: str, mode: str, opts, addr) -> None:
        peer = f"{addr[0]}:{addr[1]}"
        target = self.resolve_request(filename)
        if target is None:
            self.log(f"{peer} RRQ '{filename}' -> refused (not allowed or not found)")
            self._send_error(addr, ERR_ACCESS, "Access violation")
            return

        # RFC 2348 option validation happens BEFORE the file snapshot.
        # Invalid values are rejected with ERROR 8; they are never clamped.
        optmap = dict(opts)
        block_size = TFTP_DEFAULT_BLOCK  # RFC 1350 default; never --max-block
        effective_timeout = self.timeout
        negotiated = {}
        if "blksize" in optmap:
            raw = optmap["blksize"]
            try:
                requested = int(raw)
            except (TypeError, ValueError):
                self.log(f"{peer} RRQ '{filename}' -> REFUSED invalid blksize={raw!r}")
                self._send_error(addr, ERR_OPTION, "Option negotiation failed")
                return
            if requested < MIN_BLOCK or requested > MAX_BLOCK:
                self.log(f"{peer} RRQ '{filename}' -> REFUSED blksize={requested} "
                         f"outside {MIN_BLOCK}..{MAX_BLOCK}")
                self._send_error(addr, ERR_OPTION, "Option negotiation failed")
                return
            block_size = min(requested, self.max_block)
            negotiated["blksize"] = str(block_size)
        if "timeout" in optmap:
            try:
                effective_timeout = max(1.0, min(float(optmap["timeout"]), 10.0))
                negotiated["timeout"] = str(int(effective_timeout))
            except (TypeError, ValueError):
                pass

        # TOCTOU fix: read the file exactly once into an immutable in-memory
        # snapshot, hash that snapshot, compare with the pin, and send the
        # SAME bytes. The file is never reopened for transmission.
        try:
            with open(target, "rb") as fh:
                data = fh.read(self.max_file_bytes + 1)
        except OSError as exc:
            self.log(f"{peer} RRQ '{filename}' -> read error: {exc}")
            self._send_error(addr, ERR_ACCESS, "Read error")
            return
        if len(data) > self.max_file_bytes:
            self.log(f"{peer} RRQ '{filename}' -> REFUSED: larger than "
                     f"{self.max_file_bytes} byte limit")
            self._send_error(addr, ERR_ACCESS, "File too large")
            return

        size = len(data)
        digest = hashlib.sha256(data).hexdigest()
        rel = target.relative_to(self.root).as_posix()
        pin = self.pins.get(rel)
        if pin and digest.lower() != pin.lower():
            self.log(f"{peer} RRQ '{filename}' -> REFUSED: SHA-256 mismatch "
                     f"got {digest} expected {pin}")
            self._send_error(addr, ERR_ACCESS, "Checksum mismatch")
            return

        if "tsize" in optmap:
            negotiated["tsize"] = str(size)

        self.log(f"{peer} RRQ '{filename}' ({size} bytes) mode={mode} "
                 f"snapshot_sha256={digest} block_size={block_size} opts={opts}")

        # Bind the data socket to the same concrete address as the listener.
        # This guarantees the source address the client sees and prevents the
        # reply from being routed out of a different interface.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((self.bind, 0))
            sock.settimeout(effective_timeout)
            sent = 0
            blocks = 0
            try:
                if negotiated:
                    oack = struct.pack("!H", OP_OACK)
                    for k, v in negotiated.items():
                        oack += k.encode() + b"\x00" + v.encode() + b"\x00"
                    if not self._ack_loop(sock, oack, addr, 0, effective_timeout):
                        self.log(f"{peer} OACK not acknowledged")
                        return
                offset = 0
                block = 1
                while True:
                    chunk = data[offset:offset + block_size]
                    packet = struct.pack("!HH", OP_DATA, block & 0xFFFF) + chunk
                    if not self._ack_loop(sock, packet, addr, block & 0xFFFF, effective_timeout):
                        self.log(f"{peer} block {block} not acknowledged")
                        return
                    sent += len(chunk)
                    blocks += 1
                    if len(chunk) < block_size:
                        break
                    offset += block_size
                    block += 1
                if sent != size:
                    self.log(f"{peer} ERROR sent {sent} of {size} bytes; "
                             f"snapshot_sha256={digest}")
                else:
                    self.log(f"{peer} done '{filename}' {sent}/{size} bytes "
                             f"in {blocks} block(s) snapshot_sha256={digest}")
            except OSError as exc:
                self.log(f"{peer} transfer error: {exc}")

    def _ack_loop(self, sock: socket.socket, packet: bytes, addr,
                  expect_block: int, timeout: float | None = None) -> bool:
        """Send one packet and wait for the exact ACK.

        Only an ACK whose block number equals expect_block returns True.
        ACKs for earlier blocks (duplicates) are ignored and never advance the
        transfer. ACKs for later blocks are illegal and ignored. Timeouts
        trigger retransmission up to self.retries.
        """
        effective_timeout = timeout if timeout is not None else self.timeout
        previous = (expect_block - 1) & 0xFFFF
        for attempt in range(1, self.retries + 1):
            sock.sendto(packet, addr)
            deadline = time.time() + effective_timeout
            while time.time() < deadline:
                try:
                    data, peer = sock.recvfrom(1024)
                except socket.timeout:
                    break
                if peer != addr:
                    continue
                if len(data) < 4:
                    continue
                op = struct.unpack("!H", data[:2])[0]
                if op == OP_ACK:
                    blk = struct.unpack("!H", data[2:4])[0]
                    if blk == expect_block:
                        return True
                    if blk == previous:
                        self.log(f"duplicate ACK {blk} while expecting {expect_block}; ignored")
                    else:
                        self.log(f"unexpected ACK {blk} while expecting {expect_block}; ignored")
                    continue
                if op == OP_ERROR:
                    self.log("client error: " + data[4:].decode("ascii", "replace"))
                    return False
                # Any other opcode from the client is ignored.
            if attempt < self.retries:
                self.log(f"retransmit block {expect_block} attempt {attempt} "
                         f"to {addr[0]}:{addr[1]}")
        return False

    def _send_error(self, addr, code: int, msg: str) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.bind((self.bind, 0))
            s.sendto(error_packet(code, msg), addr)


def block_size_arg(text: str) -> int:
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"block size must be an integer, got {text!r}")
    if value < MIN_BLOCK or value > MAX_BLOCK:
        raise argparse.ArgumentTypeError(
            f"block size must be in {MIN_BLOCK}..{MAX_BLOCK}, got {value}")
    return value


def parse_pins(values: list[str]) -> dict[str, str]:
    pins = {}
    for v in values:
        if "=" not in v:
            raise SystemExit(f"--expect-sha256 needs name=hash, got: {v}")
        name, digest = v.split("=", 1)
        digest = digest.strip().lower()
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise SystemExit(f"SHA-256 must be 64 hex chars: {v}")
        pins[name] = digest
    return pins


def main() -> int:
    ap = argparse.ArgumentParser(description="Read-only TFTP server for router recovery")
    ap.add_argument("--root", required=True)
    ap.add_argument("--bind", default=LOOPBACK,
                    help="concrete IPv4 of the wired NIC; wildcard is rejected")
    ap.add_argument("--port", type=int, default=69)
    ap.add_argument("--allow", action="append", default=[],
                    help="exact relative filename to serve; repeatable")
    ap.add_argument("--expect-sha256", action="append", default=[],
                    metavar="NAME=HASH", help="pin a file's SHA-256; repeatable")
    ap.add_argument("--max-block", type=block_size_arg, default=TFTP_DEFAULT_BLOCK,
                    help=f"maximum blksize accepted for RFC 2348 negotiation "
                         f"({MIN_BLOCK}..{MAX_BLOCK}; default 512); no option always uses 512")
    ap.add_argument("--block", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--max-file-bytes", type=int, default=16 * 1024 * 1024,
                    help="refuse files larger than this (default 16 MiB)")
    ap.add_argument("--timeout", type=float, default=3.0,
                    help="per-block ACK timeout seconds (default 3.0)")
    ap.add_argument("--retries", type=int, default=5,
                    help="maximum sends per block (default 5)")
    ap.add_argument("--log", default=None)
    ap.add_argument("--ready-file", default=None,
                    help="write READY after the UDP socket has bound (test handshake)")
    args = ap.parse_args()

    if args.block is not None:
        print("CONFIG ERROR: --block has been removed; use --max-block (default 512).", file=sys.stderr)
        return 2

    root = Path(args.root)
    if not root.is_dir():
        print(f"root directory does not exist: {root}", file=sys.stderr)
        return 2

    allow = set(args.allow)
    pins = parse_pins(args.expect_sha256)
    errors = validate_config(root, args.bind, allow, pins)
    if errors:
        for e in errors:
            print(f"CONFIG ERROR: {e}", file=sys.stderr)
        return 2

    log = Logger(args.log)
    try:
        Server(root, args.bind, args.port, allow, pins, args.max_block, log,
               timeout=max(0.1, args.timeout), retries=max(1, args.retries),
               max_file_bytes=max(1, args.max_file_bytes),
               ready_file=args.ready_file).serve_forever()
    except OSError as exc:
        log(f"cannot bind {args.bind}:{args.port}: {exc}")
        return 1
    finally:
        log.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
