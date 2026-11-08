#!/usr/bin/env python3
"""Read-only DNS probes against the ESP32 (192.168.1.53) and R3G (192.168.1.1).

Sends raw DNS queries (UDP and TCP, optional EDNS0) and prints a compact
summary. Does not change any device state.
"""
import socket
import struct
import sys

ESP = "192.168.1.53"
R3G = "192.168.1.1"


def name_wire(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode("ascii")
    return out + b"\x00"


def build_query(name, qtype, edns=False, ident=0x1234):
    q = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 1 if edns else 0)
    q += name_wire(name) + struct.pack(">HH", qtype, 1)
    if edns:
        q += b"\x00" + struct.pack(">HHIH", 41, 1232, 0, 0)
    return q


def read_name(msg, off):
    labels = []
    jumped = False
    end = off
    seen = 0
    while True:
        if off >= len(msg) or seen > 128:
            return "".join(labels), end
        ln = msg[off]
        if ln & 0xC0 == 0xC0:
            ptr = struct.unpack(">H", msg[off:off + 2])[0] & 0x3FFF
            if not jumped:
                end = off + 2
            off = ptr
            jumped = True
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
    out = {"id": ident, "rcode": flags & 0xF, "tc": bool(flags & 0x0200),
           "aa": bool(flags & 0x0400), "ra": bool(flags & 0x0080), "ancount": an, "arcount": ar,
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
    # walk authority/additional to find OPT (type 41 in additional)
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
            out["opt"] = {"udpsize": rclass, "flags": ttl & 0xFFFF}
        off += rdlen
    return out


def udp(host, name, qtype, edns=False, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(build_query(name, qtype, edns), (host, 53))
        data, _ = s.recvfrom(65535)
        return parse(data)
    except socket.timeout:
        return {"error": "timeout"}
    finally:
        s.close()


def tcp(host, name, qtype, edns=False, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, 53))
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
    finally:
        s.close()


def fmt(res):
    if "error" in res:
        return "ERROR:" + res["error"]
    parts = [f"rcode={res['rcode']}", f"an={res['ancount']}", f"ar={res['arcount']}", f"tc={int(res['tc'])}"]
    if res["opt"]:
        parts.append(f"opt={res['opt']['udpsize']}")
    for rtype, ttl, val in res["answers"][:6]:
        parts.append(f"t{rtype}->{val}(ttl={ttl})")
    return " ".join(parts)


CASES = [
    ("A  pagead2 (blocked)", "pagead2.googlesyndication.com", 1, False, "udp"),
    ("AAAA pagead2 (blocked)", "pagead2.googlesyndication.com", 28, False, "udp"),
    ("HTTPS pagead2 (blocked)", "pagead2.googlesyndication.com", 65, False, "udp"),
    ("TXT pagead2 (blocked)", "pagead2.googlesyndication.com", 16, False, "udp"),
    ("CNAME pagead2 (blocked)", "pagead2.googlesyndication.com", 5, False, "udp"),
    ("A  google", "www.google.com", 1, False, "udp"),
    ("AAAA google", "www.google.com", 28, False, "udp"),
    ("A  youtube", "www.youtube.com", 1, False, "udp"),
    ("A  baidu (CNAME chain)", "www.baidu.com", 1, False, "udp"),
    ("A  baidu + EDNS0", "www.baidu.com", 1, True, "udp"),
    ("A  pagead2 + EDNS0", "pagead2.googlesyndication.com", 1, True, "udp"),
    ("A  doubleclick (not listed)", "doubleclick.net", 1, False, "udp"),
    ("A  nonexistent", "no-such-9f3a2b.invalid", 1, False, "udp"),
    ("TCP A baidu", "www.baidu.com", 1, False, "tcp"),
    ("TCP A pagead2 (blocked)", "pagead2.googlesyndication.com", 1, False, "tcp"),
]

for label, name, qtype, edns, proto in CASES:
    fn = udp if proto == "udp" else tcp
    r = fn(ESP, name, qtype, edns)
    print(f"ESP  {label:32s} {fmt(r)}")

print("--- via R3G dnsmasq (192.168.1.1) ---")
for label, name, qtype in [
    ("A  pagead2 (blocked)", "pagead2.googlesyndication.com", 1),
    ("A  baidu", "www.baidu.com", 1),
]:
    r = udp(R3G, name, qtype)
    print(f"R3G  {label:32s} {fmt(r)}")
