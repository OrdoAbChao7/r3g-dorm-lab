#!/usr/bin/env python3
"""Read-only probes of the Mihomo DNS listener at 192.168.1.1:1053."""
import socket
import struct

HOST = "192.168.1.1"
PORT = 1053


def name_wire(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode("ascii")
    return out + b"\x00"


def build_query(name, qtype, edns=False, ident=0x4321):
    q = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 1 if edns else 0)
    q += name_wire(name) + struct.pack(">HH", qtype, 1)
    if edns:
        q += b"\x00" + struct.pack(">HHIH", 41, 1232, 0, 0)
    return q


def read_name(msg, off):
    labels, jumped, end, seen = [], False, off, 0
    while True:
        if off >= len(msg) or seen > 128:
            return "".join(labels), end
        ln = msg[off]
        if ln & 0xC0 == 0xC0:
            ptr = struct.unpack(">H", msg[off:off + 2])[0] & 0x3FFF
            if not jumped:
                end = off + 2
            off, jumped = ptr, True
            continue
        off += 1
        if ln == 0:
            if not jumped:
                end = off
            break
        labels.append(msg[off:off + ln].decode("latin-1"))
        off += ln
        seen += 1
    return ".".join(labels) + ".", end


def parse(msg):
    if len(msg) < 12:
        return {"error": "short"}
    ident, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", msg[:12])
    out = {"rcode": flags & 0xF, "tc": bool(flags & 0x0200), "an": an, "ar": ar,
           "answers": [], "opt": None}
    off = 12
    for _ in range(qd):
        _, off = read_name(msg, off)
        off += 4
    for _ in range(an):
        _, off = read_name(msg, off)
        if off + 10 > len(msg):
            break
        rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        off += 10
        rdata = msg[off:off + rdlen]
        off += rdlen
        val = None
        if rtype == 1 and rdlen == 4:
            val = socket.inet_ntoa(rdata)
        elif rtype == 28 and rdlen == 16:
            val = socket.inet_ntop(socket.AF_INET6, rdata)
        elif rtype == 5:
            val, _ = read_name(msg, off - rdlen)
        out["answers"].append((rtype, ttl, val))
    for _ in range(ns):
        _, off = read_name(msg, off)
        if off + 10 > len(msg):
            break
        _, _, _, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        off += 10 + rdlen
    for _ in range(ar):
        _, off = read_name(msg, off)
        if off + 10 > len(msg):
            break
        rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", msg[off:off + 10])
        off += 10
        if rtype == 41:
            out["opt"] = {"udpsize": rclass}
        off += rdlen
    return out


def udp(name, qtype, edns=False, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(build_query(name, qtype, edns), (HOST, PORT))
        data, _ = s.recvfrom(65535)
        return parse(data)
    except socket.timeout:
        return {"error": "timeout"}
    finally:
        s.close()


def tcp(name, qtype, edns=False, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((HOST, PORT))
        q = build_query(name, qtype, edns)
        s.sendall(struct.pack(">H", len(q)) + q)
        ln = s.recv(2)
        if len(ln) < 2:
            return {"error": "short"}
        n = struct.unpack(">H", ln)[0]
        data = b""
        while len(data) < n:
            chunk = s.recv(n - len(data))
            if not chunk:
                break
            data += chunk
        return parse(data)
    except socket.timeout:
        return {"error": "timeout"}
    except OSError as e:
        return {"error": f"{e.errno}:{e.strerror}"}
    finally:
        s.close()


def fmt(r):
    if "error" in r:
        return "ERROR:" + r["error"]
    parts = [f"rcode={r['rcode']}", f"an={r['an']}", f"ar={r['ar']}"]
    if r["opt"]:
        parts.append(f"opt={r['opt']['udpsize']}")
    for t, ttl, val in r["answers"][:5]:
        parts.append(f"t{t}->{val}(ttl={ttl})")
    return " ".join(parts)


CASES = [
    ("A  google", "www.google.com", 1, False, "udp"),
    ("A  youtube", "www.youtube.com", 1, False, "udp"),
    ("A  baidu", "www.baidu.com", 1, False, "udp"),
    ("A  pagead2", "pagead2.googlesyndication.com", 1, False, "udp"),
    ("A  doubleclick", "doubleclick.net", 1, False, "udp"),
    ("A  example", "example.com", 1, False, "udp"),
    ("A  nonexistent", "no-such-9f3a2b.invalid", 1, False, "udp"),
    ("AAAA google", "www.google.com", 28, False, "udp"),
    ("AAAA pagead2", "pagead2.googlesyndication.com", 28, False, "udp"),
    ("CNAME baidu", "www.baidu.com", 5, False, "udp"),
    ("HTTPS google", "www.google.com", 65, False, "udp"),
    ("TXT google", "www.google.com", 16, False, "udp"),
    ("A  google + EDNS0", "www.google.com", 1, True, "udp"),
    ("TCP A google", "www.google.com", 1, False, "tcp"),
    ("TCP A pagead2", "pagead2.googlesyndication.com", 1, False, "tcp"),
]

for label, name, qtype, edns, proto in CASES:
    r = (udp if proto == "udp" else tcp)(name, qtype, edns)
    print(f"MIHOMO {label:26s} {fmt(r)}")
