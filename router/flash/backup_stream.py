#!/usr/bin/env python3
"""Stream a full NAND image from a stock Xiaomi R3G to this PC.

Why streaming: the router's /tmp is a 123 MB tmpfs, smaller than the 127.5 MB
"ALL" partition, so dumping to /tmp first can OOM the router. This tool reads
/dev/mtd0 over telnet and sends it to a TCP listener on the PC.

Read-only: nothing is written to the router's flash.
"""
import argparse
import hashlib
import json
import os
import socket
import sys
import threading
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240

# Stock R3G layout from /proc/mtd (sizes, cumulative offsets)
PARTS = [
    ("Bootloader", 0x00000000, 0x00080000),
    ("Config", 0x00080000, 0x00040000),
    ("Bdata", 0x000C0000, 0x00040000),
    ("Factory", 0x00100000, 0x00040000),
    ("crash", 0x00140000, 0x00040000),
    ("crash_syslog", 0x00180000, 0x00040000),
    ("reserved0", 0x001C0000, 0x00040000),
    ("kernel0", 0x00200000, 0x00400000),
    ("kernel1", 0x00600000, 0x00400000),
    ("rootfs0", 0x00A00000, 0x02000000),
    ("rootfs1", 0x02A00000, 0x02000000),
    ("overlay", 0x04A00000, 0x03580000),
]
ALL_SIZE = 0x07F80000


class Telnet:
    def __init__(self, host, port=23, timeout=10):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(1.0)

    def clean(self, data):
        out = bytearray()
        i = 0
        while i < len(data):
            b = data[i]
            if b != IAC:
                out.append(b)
                i += 1
                continue
            if i + 1 >= len(data):
                break
            cmd = data[i + 1]
            if cmd in (DO, DONT, WILL, WONT) and i + 2 < len(data):
                opt = data[i + 2]
                if cmd == DO:
                    self.s.sendall(bytes([IAC, WONT, opt]))
                elif cmd == WILL:
                    self.s.sendall(bytes([IAC, DONT, opt]))
                i += 3
            elif cmd == SB:
                j = data.find(bytes([IAC, SE]), i)
                i = (j + 2) if j != -1 else len(data)
            else:
                i += 2
        return bytes(out)

    def read_until(self, patterns, timeout=15):
        if isinstance(patterns, bytes):
            patterns = [patterns]
        deadline = time.time() + timeout
        text = b""
        while time.time() < deadline:
            low = text.lower()
            for p in patterns:
                if p.lower() in low:
                    return p, text.decode("utf-8", "ignore")
            try:
                chunk = self.s.recv(4096)
                if not chunk:
                    break
                text += self.clean(chunk)
            except socket.timeout:
                continue
            except OSError:
                break
        return None, text.decode("utf-8", "ignore")

    def send(self, line):
        self.s.sendall((line + "\n").encode())

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class Receiver(threading.Thread):
    def __init__(self, bind_ip, port, out_path):
        super().__init__(daemon=True)
        self.bind_ip = bind_ip
        self.port = port
        self.out_path = out_path
        self.received = 0
        self.error = None
        self.connected = threading.Event()
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind((bind_ip, port))
        self.srv.listen(1)
        self.srv.settimeout(180)

    def run(self):
        try:
            conn, addr = self.srv.accept()
            self.connected.set()
            print("[recv] connected from %s:%d" % addr)
            with open(self.out_path, "wb") as f:
                last = 0
                while True:
                    data = conn.recv(262144)
                    if not data:
                        break
                    f.write(data)
                    self.received += len(data)
                    if self.received - last >= 16 * 1024 * 1024:
                        last = self.received
                        print("[recv] %d MB" % (self.received // (1024 * 1024)))
            conn.close()
        except Exception as exc:  # noqa: BLE001 - report, do not crash
            self.error = str(exc)
        finally:
            try:
                self.srv.close()
            except OSError:
                pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.31.1")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default=None, help="router login password; prompted if omitted")
    ap.add_argument("--pc-ip", required=True, help="PC address reachable from the router")
    ap.add_argument("--port", type=int, default=9001)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    if args.password is None:
        import getpass
        args.password = getpass.getpass("router password: ")

    if os.path.exists(args.out):
        print("refusing to overwrite %s" % args.out, file=sys.stderr)
        return 2

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    recv = Receiver("0.0.0.0", args.port, args.out)
    recv.start()

    t = Telnet(args.host)
    pattern, text = t.read_until([b"login:", b"login as:", b"Username:", b"#"], timeout=12)
    if pattern is None:
        print("no login prompt:\n" + text, file=sys.stderr)
        return 3
    if pattern != b"#":
        t.send(args.user)
        pattern, text = t.read_until([b"Password:", b"password:", b"#"], timeout=12)
        if pattern is None:
            print("no password prompt:\n" + text, file=sys.stderr)
            return 3
        if pattern != b"#":
            t.send(args.password)
            pattern, text = t.read_until([b"#", b"$"], timeout=12)
            if pattern is None:
                print("login failed:\n" + text, file=sys.stderr)
                return 3

    print("[telnet] logged in")
    cmd = "dd if=/dev/mtd0 bs=65536 2>/dev/null | nc %s %d" % (args.pc_ip, args.port)
    print("[router] " + cmd)
    t.send(cmd)

    # The shell prompt returns after nc finishes.
    pattern, text = t.read_until([b"#"], timeout=args.timeout)
    elapsed_ok = pattern is not None
    t.send("exit")
    t.close()

    recv.join(timeout=30)

    if recv.error:
        print("[recv] error: %s" % recv.error, file=sys.stderr)
    size = os.path.getsize(args.out) if os.path.exists(args.out) else 0
    print("[recv] bytes=%d expected=%d" % (size, ALL_SIZE))

    ok = elapsed_ok and size == ALL_SIZE and not recv.error
    if not ok:
        print("BACKUP INCOMPLETE", file=sys.stderr)
        return 4

    full_hash = sha256_file(args.out)
    print("[hash] full sha256=%s" % full_hash)

    parts_dir = os.path.join(os.path.dirname(os.path.abspath(args.out)), "parts")
    os.makedirs(parts_dir, exist_ok=True)
    manifest = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "router": args.host,
        "image": os.path.basename(args.out),
        "size": size,
        "sha256": full_hash,
        "parts": [],
    }
    with open(args.out, "rb") as f:
        for name, off, length in PARTS:
            f.seek(off)
            blob = f.read(length)
            p = os.path.join(parts_dir, name + ".bin")
            with open(p, "wb") as pf:
                pf.write(blob)
            manifest["parts"].append({
                "name": name,
                "offset": off,
                "size": len(blob),
                "sha256": hashlib.sha256(blob).hexdigest(),
            })
            print("[part] %-13s off=0x%08x size=%d" % (name, off, len(blob)))

    man_path = os.path.splitext(args.out)[0] + ".manifest.json"
    with open(man_path, "w", encoding="utf-8") as mf:
        json.dump(manifest, mf, indent=2)
    print("[done] %s\n[done] %s" % (args.out, man_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
