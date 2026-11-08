#!/usr/bin/env python3
"""TCP/UDP re-test for the ESP32 DNS on port 53 (read-only).

Explains the earlier TCP/53 contradiction: the ESP32's TCP listener is
single-threaded with a backlog of 3 and a 5 s idle read timeout.
"""
import socket
import struct
import threading
import time

TARGET = ("192.168.1.53", 53)
R3G = ("192.168.1.1", 53)


def q(name="www.baidu.com"):
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    out += b"\x00"
    return struct.pack(">HHHHHH", 0x1111, 0x0100, 1, 0, 0, 0) + out + struct.pack(">HH", 1, 1)


def udp_query(host, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t0 = time.monotonic()
    try:
        s.sendto(q(), host)
        data, _ = s.recvfrom(4096)
        dt = (time.monotonic() - t0) * 1000
        return True, round(dt), len(data)
    except socket.timeout:
        return False, round((time.monotonic() - t0) * 1000), 0
    finally:
        s.close()


def tcp_query(host, timeout=3.0, hold=0.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    t0 = time.monotonic()
    try:
        s.connect(host)
        t1 = time.monotonic()
        p = q()
        s.sendall(struct.pack(">H", len(p)) + p)
        ln = s.recv(2)
        if len(ln) < 2:
            return False, round((t1 - t0) * 1000), 0, round((time.monotonic() - t1) * 1000)
        n = struct.unpack(">H", ln)[0]
        data = b""
        while len(data) < n:
            c = s.recv(n - len(data))
            if not c:
                break
            data += c
        if hold:
            time.sleep(hold)
        return True, round((t1 - t0) * 1000), len(data), round((time.monotonic() - t1) * 1000)
    except socket.timeout:
        return False, round((time.monotonic() - t0) * 1000), 0, 0
    except OSError as e:
        return False, round((time.monotonic() - t0) * 1000), 0, 0
    finally:
        s.close()


print("== UDP sequential to ESP32 ==")
for i in range(5):
    ok, ms, n = udp_query(TARGET)
    print(f"UDP {i+1}: ok={ok} ms={ms} bytes={n}")

print("== TCP sequential to ESP32 ==")
for i in range(5):
    ok, ms, n, rms = tcp_query(TARGET)
    print(f"TCP {i+1}: ok={ok} connect_ms={ms} bytes={n} response_ms={rms}")

print("== TCP concurrent x3 to ESP32 ==")
results = [None] * 3


def worker(i):
    results[i] = tcp_query(TARGET, timeout=8.0)


threads = [threading.Thread(target=worker, args=(i,)) for i in range(3)]
for t in threads:
    t.start()
for t in threads:
    t.join()
for i, r in enumerate(results):
    print(f"TCP concurrent {i+1}: ok={r[0]} connect_ms={r[1]} bytes={r[2]} response_ms={r[3]}")

print("== hold-open test: A holds connection, B connects ==")
a = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
a.settimeout(3.0)
try:
    a.connect(TARGET)
    p = q()
    a.sendall(struct.pack(">H", len(p)) + p)
    ln = a.recv(2)
    print(f"A: connected and got reply={len(ln) == 2}")
    t0 = time.monotonic()
    ok, ms, n, rms = tcp_query(TARGET, timeout=3.0)
    print(f"B during A hold: ok={ok} connect_ms={ms} bytes={n} (A held {round((time.monotonic()-t0)*1000)} ms)")
finally:
    a.close()

print("== TCP sequential to R3G dnsmasq ==")
for i in range(3):
    ok, ms, n, rms = tcp_query(R3G)
    print(f"R3G TCP {i+1}: ok={ok} connect_ms={ms} bytes={n} response_ms={rms}")
