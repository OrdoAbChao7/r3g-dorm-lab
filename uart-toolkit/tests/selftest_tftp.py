#!/usr/bin/env python3
"""Offline self-test for tftp_server.py (no router, no real network peer).

Covers the second-audit requirements:
  * exact ACK matching (ACK 0 while expecting 1, ACK 2 early, duplicate ACK)
  * lost ACK -> DATA retransmission -> successful completion
  * retransmission exhaustion -> server reports failure
  * OACK negotiation (blksize/tsize)
  * last short block and exact block-multiple files
  * SHA-256 equality of the received bytes for every successful transfer
  * allowlist, path traversal, symlink escape, WRQ rejection
  * startup rejection: pin mismatch, missing allowlist/pin for non-loopback,
    wildcard bind, missing pinned file
  * data socket source address equals the configured bind address

Exit code 0 only if every executed case passes. A case that cannot be executed
on this host is reported SKIP with the reason, never PASS.
"""

from __future__ import annotations

import hashlib
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6
SERVER = Path(__file__).resolve().parent.parent / "scripts" / "tftp_server.py"
PY = sys.executable

results = []


def check(name: str, cond: bool, detail: str = ""):
    status = "PASS" if cond else "FAIL"
    print(f"{status} {name}" + (f" - {detail}" if detail else ""))
    results.append((name, status, detail))


def skip(name: str, reason: str):
    print(f"SKIP {name} - {reason}")
    results.append((name, "SKIP", reason))


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def wait_ready(proc, ready_file: Path, timeout: float = 15.0,
               expected: str | None = None, require_alive: bool = True):
    """Wait until the server has bound its UDP socket and written READY.

    A fixed sleep is never used. READY is written atomically by the server;
    the client validates its content and re-checks that the child is alive
    before returning. Slow startup is bounded by an explicit timeout, not by
    a guess based on elapsed wall-clock time.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready_file.exists():
            try:
                content = ready_file.read_text(encoding="utf-8").strip()
            except OSError:
                content = ""
            if content and (expected is None or content == expected):
                if require_alive and proc.poll() is not None:
                    raise RuntimeError(
                        f"server exited after READY rc={proc.returncode}")
                return True
        if proc.poll() is not None:
            out = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(
                f"server exited before READY rc={proc.returncode} out={out[-300:]}")
        time.sleep(0.02)
    raise RuntimeError(f"READY timeout after {timeout:.1f}s")


def start_server(root: Path, port: int, bind: str = "127.0.0.1",
                 allow: list[str] | None = None, pins: list[str] | None = None,
                 timeout: float = 0.3, retries: int = 3,
                 log: Path | None = None, max_file_bytes: int | None = None,
                 max_block: int | None = None, ready_file: Path | None = None):
    cmd = [PY, "-I", str(SERVER), "--root", str(root), "--bind", bind,
           "--port", str(port), "--timeout", str(timeout), "--retries", str(retries)]
    if max_block is not None:
        cmd += ["--max-block", str(max_block)]
    if max_file_bytes is not None:
        cmd += ["--max-file-bytes", str(max_file_bytes)]
    for a in allow or []:
        cmd += ["--allow", a]
    for p in pins or []:
        cmd += ["--expect-sha256", p]
    if log:
        cmd += ["--log", str(log)]
    if ready_file is None:
        ready_file = root.parent / f"ready_{port}_{os.getpid()}_{time.time_ns()}.txt"
    try:
        ready_file.unlink()
    except FileNotFoundError:
        pass
    cmd += ["--ready-file", str(ready_file)]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace")
    try:
        wait_ready(proc, ready_file, timeout=15.0,
                   expected=f"READY {bind}:{port}")
    except Exception:
        stop(proc)
        raise
    return proc


def stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


def start_expect_failure(root: Path, port: int, bind: str,
                         allow: list[str], pins: list[str]) -> tuple[int, str]:
    cmd = [PY, "-I", str(SERVER), "--root", str(root), "--bind", bind,
           "--port", str(port)]
    for a in allow:
        cmd += ["--allow", a]
    for p in pins:
        cmd += ["--expect-sha256", p]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=10)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def recv_packet(s: socket.socket, timeout: float):
    s.settimeout(timeout)
    try:
        data, peer = s.recvfrom(65536)
        return data, peer
    except socket.timeout:
        return None, None


def fetch(port: int, filename: str, block_size: int = 512,
          policy: str = "normal", timeout: float = 1.5,
          on_first_data=None):
    """Fetch a file. policy applies to DATA block 1:
       normal | ack_prev | ack_next | drop_first | dup_ack | never_ack
    Returns (data, seen_blocks, first_peer).
    """
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        req = struct.pack("!H", OP_RRQ) + filename.encode() + b"\x00octet\x00"
        req += b"blksize\x00" + str(block_size).encode() + b"\x00"
        req += b"tsize\x000\x00"
        s.sendto(req, ("127.0.0.1", port))
        buf = bytearray()
        committed: set[int] = set()
        expected = 1
        seen = []
        peer0 = None
        first_data = True
        oack_seen = False

        while True:
            data, peer = recv_packet(s, timeout)
            if data is None:
                raise RuntimeError("timeout waiting for server packet")
            if peer0 is None:
                peer0 = peer
            op = struct.unpack("!H", data[:2])[0]
            if op == OP_ERROR:
                return b"__ERROR__:" + data[4:].decode("ascii", "replace").encode(), seen, peer0
            if op == OP_OACK:
                oack_seen = True
                s.sendto(struct.pack("!HH", OP_ACK, 0), peer)
                continue
            if op != OP_DATA:
                raise RuntimeError(f"unexpected opcode {op}")
            blk = struct.unpack("!H", data[2:4])[0]
            seen.append(blk)
            payload = data[4:]
            if on_first_data is not None and len(seen) == 1:
                on_first_data()
            if blk not in committed:
                buf.extend(payload)
                committed.add(blk)

            if policy == "never_ack":
                s.sendto(struct.pack("!HH", OP_ACK, 0), peer)
                continue

            if first_data and blk == 1 and policy != "normal":
                first_data = False
                if policy == "ack_prev":
                    s.sendto(struct.pack("!HH", OP_ACK, 0), peer)
                    continue  # wait for retransmitted DATA 1
                if policy == "ack_next":
                    s.sendto(struct.pack("!HH", OP_ACK, 2), peer)
                    continue
                if policy == "drop_first":
                    continue  # send nothing; wait for retransmit
                if policy == "dup_ack":
                    s.sendto(struct.pack("!HH", OP_ACK, 1), peer)
                    s.sendto(struct.pack("!HH", OP_ACK, 1), peer)
                    # fall through and accept this block

            if blk != expected:
                raise RuntimeError(f"block {blk} != expected {expected}")
            s.sendto(struct.pack("!HH", OP_ACK, blk), peer)
            if len(payload) < block_size:
                return bytes(buf), seen, peer0
            expected = (expected + 1) & 0xFFFF


def parse_oack(data: bytes) -> dict[str, str]:
    parts = data[2:].split(b"\x00")
    out = {}
    for i in range(0, len(parts) - 1, 2):
        if not parts[i]:
            break
        out[parts[i].decode("ascii", "replace").lower()] = parts[i + 1].decode("ascii", "replace")
    return out


def raw_option_probe(port: int, filename: str, options: dict[str, str]):
    """Send an RRQ with the given options and inspect the actual packet."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(3)
        req = struct.pack("!H", OP_RRQ) + filename.encode() + b"\x00octet\x00"
        for k, v in options.items():
            req += k.encode() + b"\x00" + str(v).encode() + b"\x00"
        s.sendto(req, ("127.0.0.1", port))
        data, peer = s.recvfrom(65536)
        op = struct.unpack("!H", data[:2])[0]
        if op == OP_OACK:
            oack = parse_oack(data)
            s.sendto(struct.pack("!HH", OP_ACK, 0), peer)
            data2, _ = s.recvfrom(65536)
            op2 = struct.unpack("!H", data2[:2])[0]
            if op2 == OP_DATA:
                return op2, data2[4:], oack
            return op2, data2[2:], oack
        if op == OP_DATA:
            return op, data[4:], {}
        return op, data[2:], {}


def run_max_block_cli(value: str, port: int):
    ready = Path(tempfile.gettempdir()) / f"r3g_tftp_cli_{port}_{os.getpid()}.ready"
    cmd = [PY, "-I", str(SERVER), "--root", str(SERVER.parent.parent / "firmware" / "tftp_stock"),
           "--port", str(port), "--max-block", value, "--ready-file", str(ready)]
    try:
        ready.unlink()
    except FileNotFoundError:
        pass
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    running = False
    out = ""
    try:
        wait_ready(p, ready, timeout=15.0,
                   expected=f"READY 127.0.0.1:{port}")
        running = True
    except RuntimeError as exc:
        out = str(exc)
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
        if p.stdout:
            out += (p.stdout.read() or "")
        try:
            ready.unlink()
        except FileNotFoundError:
            pass
    return running, (p.returncode, out)


def local_ipv4_addresses() -> list[str]:
    ips = set()
    try:
        for res in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(res[4][0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith("127."))


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="r3g_tftp_test2_"))
    root = tmp / "root"
    root.mkdir()
    allowed = os.urandom(5000)          # last short block
    exact = os.urandom(4096)            # exact 8 * 512
    (root / "allowed.bin").write_bytes(allowed)
    (root / "exact.bin").write_bytes(exact)
    (root / "secret.txt").write_text("must not be served")
    outside = tmp / "outside.txt"
    outside.write_text("must not be served via traversal")
    log = tmp / "server.log"

    pin_allowed = "allowed.bin=" + sha(allowed)
    pin_exact = "exact.bin=" + sha(exact)
    allow = ["allowed.bin", "exact.bin"]
    pins = [pin_allowed, pin_exact]

    port = 17101
    ready_main = tmp / "ready_main.txt"
    proc = start_server(root, port, allow=allow, pins=pins, log=log,
                        timeout=0.3, retries=3, ready_file=ready_main)
    check("READY handshake is written only after bind",
          ready_main.exists() and
          ready_main.read_text(encoding="utf-8").strip() == f"READY 127.0.0.1:{port}",
          ready_main.read_text(encoding="utf-8").strip() if ready_main.exists() else "missing")
    try:
        data, seen, peer = fetch(port, "allowed.bin", 512)
        check("normal RRQ (short last block) hash", data == allowed,
              f"{len(data)} bytes sha256={sha(data)[:16]} blocks={seen}")
        check("normal RRQ source address is 127.0.0.1", peer is not None and peer[0] == "127.0.0.1",
              str(peer))

        data2, seen2, _ = fetch(port, "exact.bin", 512)
        check("exact block-multiple file (zero-length final block) hash", data2 == exact,
              f"{len(data2)} bytes blocks={seen2}")

        data3, seen3, _ = fetch(port, "allowed.bin", 512, policy="ack_prev", timeout=1.0)
        check("ACK 0 while expecting 1: ignored, transfer completes",
              data3 == allowed, f"blocks={seen3} (expect duplicate 1)")

        data4, seen4, _ = fetch(port, "allowed.bin", 512, policy="ack_next", timeout=1.0)
        check("ACK 2 early: ignored, transfer completes",
              data4 == allowed, f"blocks={seen4} (expect duplicate 1)")

        data5, seen5, _ = fetch(port, "allowed.bin", 512, policy="drop_first", timeout=1.0)
        check("lost ACK triggers DATA retransmission", data5 == allowed and seen5.count(1) >= 2,
              f"blocks={seen5}")

        data6, seen6, _ = fetch(port, "allowed.bin", 512, policy="dup_ack", timeout=1.0)
        check("duplicate ACK does not corrupt transfer", data6 == allowed,
              f"blocks={seen6}")

        err, _, _ = fetch(port, "secret.txt", 512)
        check("allowlist refusal", err.startswith(b"__ERROR__"), err.decode("ascii", "replace"))

        err2, _, _ = fetch(port, "../outside.txt", 512)
        check("path traversal refusal", err2.startswith(b"__ERROR__"), err2.decode("ascii", "replace"))

        # Symlink escape (if the host permits creating symlinks).
        try:
            os.symlink(outside, root / "link_out")
            err3, _, _ = fetch(port, "link_out", 512)
            check("symlink escape refusal", err3.startswith(b"__ERROR__"), err3.decode("ascii", "replace"))
        except OSError as exc:
            # Fall back to a directory junction, which does not need admin.
            try:
                j = root / "link_dir"
                subprocess.run(["cmd", "/c", "mklink", "/J", str(j), str(outside.parent)],
                               capture_output=True, timeout=10)
                if j.exists():
                    err4, _, _ = fetch(port, "link_dir/outside.txt", 512)
                    check("junction/symlink escape refusal", err4.startswith(b"__ERROR__"),
                          err4.decode("ascii", "replace"))
                else:
                    skip("symlink/junction escape refusal",
                         f"cannot create symlink or junction on this host: {exc}")
            except Exception as exc2:
                skip("symlink/junction escape refusal", f"host restriction: {exc2}")
    finally:
        stop(proc)

    # RFC 2348 block-size bounds: CLI validation and actual packet inspection.
    for idx, (value, should_run) in enumerate((("8", True), ("512", True), ("65464", True),
                                               ("0", False), ("-1", False), ("1", False),
                                               ("7", False), ("65465", False))):
        running, (code, out) = run_max_block_cli(value, 17140 + idx)
        if should_run:
            check(f"--max-block {value} is accepted", running, f"rc={code}")
        else:
            check(f"--max-block {value} is rejected", not running and "block size" in out.lower(),
                  f"rc={code} out={out.strip()[:120]}")

    # Legacy --block must be refused explicitly, not silently reinterpreted.
    p_legacy = subprocess.run([PY, "-I", str(SERVER),
                               "--root", str(SERVER.parent.parent / "firmware" / "tftp_stock"),
                               "--port", "17163", "--block", "512"],
                              capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=10)
    legacy_out = (p_legacy.stdout or "") + (p_legacy.stderr or "")
    check("legacy --block is refused with migration message",
          p_legacy.returncode == 2 and "use --max-block" in legacy_out,
          f"rc={p_legacy.returncode}")

    def probe_with_max(max_block: int, port: int, options: dict[str, str]):
        p = start_server(root, port, allow=["exact.bin"], pins=[pin_exact],
                         timeout=0.4, retries=2, max_block=max_block)
        try:
            return raw_option_probe(port, "exact.bin", options)
        finally:
            stop(p)

    # max-block=8: no option still uses RFC 1350 512; blksize=8 uses 8.
    op, payload, oack = probe_with_max(8, 17160, {})
    check("max-block=8 with no blksize uses DATA 512",
          op == OP_DATA and not oack and len(payload) == 512,
          f"op={op} oack={oack} payload={len(payload)}")
    op, payload, oack = probe_with_max(8, 17160, {"blksize": "8"})
    check("max-block=8 with blksize=8 negotiates 8",
          op == OP_DATA and oack.get("blksize") == "8" and len(payload) == 8,
          f"op={op} oack={oack} payload={len(payload)}")

    # max-block=512: no option 512; blksize=1024 is capped at 512; blksize=8 stays 8.
    op, payload, oack = probe_with_max(512, 17161, {})
    check("max-block=512 with no blksize uses DATA 512",
          op == OP_DATA and not oack and len(payload) == 512,
          f"op={op} oack={oack} payload={len(payload)}")
    op, payload, oack = probe_with_max(512, 17161, {"blksize": "1024"})
    check("max-block=512 with blksize=1024 negotiates 512",
          op == OP_DATA and oack.get("blksize") == "512" and len(payload) == 512,
          f"op={op} oack={oack} payload={len(payload)}")
    op, payload, oack = probe_with_max(512, 17161, {"blksize": "8"})
    check("max-block=512 with blksize=8 negotiates 8",
          op == OP_DATA and oack.get("blksize") == "8" and len(payload) == 8,
          f"op={op} oack={oack} payload={len(payload)}")
    for bad in ("0", "1", "7", "65465"):
        op, payload, oack = probe_with_max(512, 17161, {"blksize": bad})
        code8 = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
        check(f"client blksize={bad} rejected with ERROR 8",
              op == OP_ERROR and code8 == 8, f"op={op} code={code8}")

    # max-block=65464: no option 512; blksize=65464 is allowed.
    op, payload, oack = probe_with_max(65464, 17162, {})
    check("max-block=65464 with no blksize uses DATA 512",
          op == OP_DATA and not oack and len(payload) == 512,
          f"op={op} oack={oack} payload={len(payload)}")
    op, payload, oack = probe_with_max(65464, 17162, {"blksize": "65464"})
    check("max-block=65464 with blksize=65464 negotiates 65464",
          op == OP_DATA and oack.get("blksize") == "65464" and len(payload) == 4096,
          f"op={op} oack={oack} payload={len(payload)}")

    # WRQ refusal on a fresh server.
    port2 = 17102
    p2 = start_server(root, port2, allow=allow, pins=pins, timeout=0.3, retries=2)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(3)
            s.sendto(struct.pack("!H", OP_WRQ) + b"upload.bin\x00octet\x00", ("127.0.0.1", port2))
            resp, _ = s.recvfrom(4096)
        check("WRQ refusal", struct.unpack("!H", resp[:2])[0] == OP_ERROR,
              resp[4:].decode("ascii", "replace"))
    finally:
        stop(p2)

    # Retransmission exhaustion.
    port3 = 17103
    log3 = tmp / "timeout.log"
    p3 = start_server(root, port3, allow=["allowed.bin"], pins=[pin_allowed],
                      timeout=0.2, retries=2, log=log3)
    try:
        try:
            fetch(port3, "allowed.bin", 512, policy="never_ack", timeout=0.6)
        except RuntimeError:
            pass
        time.sleep(1.2)
        text = log3.read_text(encoding="utf-8", errors="replace")
        check("retransmission exhaustion reports failure",
              "block 1 not acknowledged" in text and "done 'allowed.bin'" not in text,
              "server log")
    finally:
        stop(p3)

    # TOCTOU: hash and send the same in-memory snapshot. Modify/replace after
    # startup must be rejected at request time; mid-transfer changes must not
    # affect the bytes already snapshotted.
    race_root = tmp / "race"
    race_root.mkdir()
    orig_modify = os.urandom(5000)
    orig_replace = os.urandom(5000)
    orig_big = os.urandom(512 * 1024)
    (race_root / "modify.bin").write_bytes(orig_modify)
    (race_root / "replace.bin").write_bytes(orig_replace)
    (race_root / "big.bin").write_bytes(orig_big)
    (race_root / "toolarge.bin").write_bytes(os.urandom(5000))
    race_pins = [
        "modify.bin=" + sha(orig_modify),
        "replace.bin=" + sha(orig_replace),
        "big.bin=" + sha(orig_big),
        "toolarge.bin=" + sha((race_root / "toolarge.bin").read_bytes()),
    ]
    race_log = tmp / "race.log"
    port5 = 17110
    p5 = start_server(race_root, port5, allow=["modify.bin", "replace.bin", "big.bin"],
                      pins=race_pins[:3], timeout=0.4, retries=3, log=race_log,
                      max_block=4096)
    try:
        (race_root / "modify.bin").write_bytes(os.urandom(5000))
        err, _, _ = fetch(port5, "modify.bin", 512)
        check("file modified after startup is refused (TOCTOU)",
              err.startswith(b"__ERROR__"), err.decode("ascii", "replace"))

        (race_root / "replace.bin").unlink()
        (race_root / "replace.bin").write_bytes(os.urandom(6000))
        err, _, _ = fetch(port5, "replace.bin", 512)
        check("file replaced after startup is refused (TOCTOU)",
              err.startswith(b"__ERROR__"), err.decode("ascii", "replace"))

        changed = {"done": False}

        def mutate_during_transfer():
            if not changed["done"]:
                (race_root / "big.bin").write_bytes(os.urandom(len(orig_big)))
                changed["done"] = True

        data5, seen5, _ = fetch(port5, "big.bin", 4096, timeout=2.0,
                                on_first_data=mutate_during_transfer)
        check("mid-transfer file change does not affect sent snapshot",
              changed["done"] and data5 == orig_big,
              f"bytes={len(data5)} blocks={len(seen5)}")
        check("received SHA-256 equals configured pin",
              sha(data5) == sha(orig_big),
              sha(data5)[:16])
    finally:
        stop(p5)

    # Size limit: a pinned 5000-byte file is refused when max is 4096.
    port6 = 17111
    lim_log = tmp / "limit.log"
    p6 = start_server(race_root, port6, allow=["toolarge.bin"],
                      pins=[race_pins[3]], timeout=0.3, retries=2,
                      max_file_bytes=4096, log=lim_log)
    try:
        err, _, _ = fetch(port6, "toolarge.bin", 512)
        text = lim_log.read_text(encoding="utf-8", errors="replace")
        check("file above --max-file-bytes is refused",
              err.startswith(b"__ERROR__") and "too large" in (text + err.decode("ascii", "replace")).lower(),
              err.decode("ascii", "replace"))
    finally:
        stop(p6)

    # Startup configuration refusals.
    code, out = start_expect_failure(root, 17104, "127.0.0.1", ["allowed.bin"],
                                     ["allowed.bin=" + "0" * 64])
    check("startup refuses SHA-256 pin mismatch",
          code != 0 and "hash mismatch" in out.lower(), f"exit={code}")

    code, out = start_expect_failure(root, 17105, "192.0.2.1", [], [])
    check("non-loopback bind requires allowlist",
          code != 0 and "requires --allow" in out, f"exit={code}")

    code, out = start_expect_failure(root, 17106, "192.0.2.1", ["allowed.bin"], [])
    check("non-loopback bind requires pins",
          code != 0 and "requires --expect-sha256" in out, f"exit={code}")

    code, out = start_expect_failure(root, 17107, "0.0.0.0", allow, pins)
    check("wildcard bind rejected",
          code != 0 and "wildcard" in out.lower(), f"exit={code}")

    code, out = start_expect_failure(root, 17108, "127.0.0.1", ["nope.bin"],
                                     ["nope.bin=" + "0" * 64])
    check("startup refuses missing pinned file",
          code != 0 and "missing" in out.lower(), f"exit={code}")

    # Multi-NIC source binding. Prefer a real non-loopback local IPv4.
    ips = local_ipv4_addresses()
    if ips:
        bind_ip = ips[0]
        port4 = 17109
        p4 = start_server(root, port4, bind=bind_ip, allow=["exact.bin"],
                          pins=[pin_exact], timeout=0.5, retries=2)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                req = struct.pack("!H", OP_RRQ) + b"exact.bin\x00octet\x00"
                s.sendto(req, (bind_ip, port4))
                s.settimeout(2)
                d1, peer = s.recvfrom(65536)
                # ACK block 0 if OACK (no options requested -> DATA 1)
                op = struct.unpack("!H", d1[:2])[0]
                if op == OP_DATA:
                    s.sendto(struct.pack("!HH", OP_ACK, 1), peer)
                check("non-loopback bind: data source address matches bind IP",
                      peer is not None and peer[0] == bind_ip,
                      f"client saw source {peer[0] if peer else None}, expected {bind_ip}")
        finally:
            stop(p4)
    else:
        skip("non-loopback bind source address",
             "no non-loopback IPv4 address discovered; loopback source already tested")

    # READY handshake: delayed start, timeout, early exit, port collision,
    # repeated start/stop and deterministic child cleanup.
    ready_delay = tmp / "ready_delay.txt"
    delayed = subprocess.Popen(
        [PY, "-I", "-c",
         "import pathlib,sys,time; time.sleep(0.6); pathlib.Path(sys.argv[1]).write_text('READY')",
         str(ready_delay)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.monotonic()
    try:
        wait_ready(delayed, ready_delay, timeout=10.0, require_alive=False)
        elapsed = time.monotonic() - t0
        check("delayed startup waits for READY", ready_delay.exists() and elapsed >= 0.45,
              f"elapsed={elapsed:.2f}s")
    finally:
        delayed.wait(timeout=5)

    ready_never = tmp / "ready_never.txt"
    late = subprocess.Popen(
        [PY, "-I", "-c", "import time; time.sleep(3)"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    timed_out = False
    try:
        try:
            wait_ready(late, ready_never, timeout=0.3)
        except RuntimeError as exc:
            timed_out = "READY timeout" in str(exc)
    finally:
        late.terminate()
        late.wait(timeout=5)
    check("READY timeout is reported, not guessed", timed_out)

    early = subprocess.Popen(
        [PY, "-I", "-c", "import sys; sys.exit(7)"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    early_exit = False
    try:
        try:
            wait_ready(early, tmp / "ready_early.txt", timeout=2.0)
        except RuntimeError as exc:
            early_exit = "exited before READY" in str(exc) and "rc=7" in str(exc)
    finally:
        early.wait(timeout=5)
    check("early server exit is reported by handshake", early_exit)

    busy_port = 17180
    blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    exclusive = getattr(socket, "SO_EXCLUSIVEADDRUSE", None)
    if exclusive is not None:
        blocker.setsockopt(socket.SOL_SOCKET, exclusive, 1)
    blocker.bind(("127.0.0.1", busy_port))
    busy_proc = None
    busy_rejected = False
    try:
        try:
            busy_proc = start_server(root, busy_port, allow=allow, pins=pins,
                                     ready_file=tmp / "ready_busy.txt")
        except RuntimeError as exc:
            busy_rejected = "exited before READY" in str(exc)
    finally:
        if busy_proc is not None:
            stop(busy_proc)
        blocker.close()
    check("occupied UDP port is reported by handshake", busy_rejected,
          "second server must not report READY")

    repeat_ok = True
    for i in range(3):
        rp = start_server(root, 17190 + i, allow=allow, pins=pins,
                          ready_file=tmp / f"ready_repeat_{i}.txt")
        repeat_ok = repeat_ok and rp.poll() is None
        stop(rp)
        repeat_ok = repeat_ok and rp.poll() is not None
    check("repeated start/stop leaves no child running", repeat_ok)

    # Mid-test failure: abort the client after the first DATA packet, then stop
    # the server and confirm the child is gone and the port can be reused.
    abort_port = 17182
    abort = start_server(root, abort_port, allow=["exact.bin"], pins=[pin_exact],
                         ready_file=tmp / "ready_abort.txt")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            req = struct.pack("!H", OP_RRQ) + b"exact.bin\x00octet\x00"
            s.sendto(req, ("127.0.0.1", abort_port))
            s.settimeout(2)
            s.recvfrom(65536)  # receive first DATA/OACK, never ACK it
    finally:
        stop(abort)
    check("mid-test client abort leaves no child running", abort.poll() is not None)

    reused = start_server(root, abort_port, allow=["exact.bin"], pins=[pin_exact],
                          ready_file=tmp / "ready_reused.txt")
    try:
        check("port is reusable after mid-test abort", reused.poll() is None)
    finally:
        stop(reused)

    # Summary
    print()
    failed = [r for r in results if r[1] == "FAIL"]
    skipped = [r for r in results if r[1] == "SKIP"]
    print(f"TOTAL {len(results)}  PASS {len(results)-len(failed)-len(skipped)}  "
          f"FAIL {len(failed)}  SKIP {len(skipped)}")
    if failed:
        print("FAILED: " + ", ".join(r[0] for r in failed))
        return 1
    if skipped:
        print("SKIPPED: " + ", ".join(r[0] for r in skipped))
    print("ALL EXECUTED TFTP SELF-TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
