#!/usr/bin/env python3
"""Read-only serial watcher: waits for the ESP32 blocklist to finish loading
(or fail) and prints only blocklist/LED lines. Does not reset the board."""
import re
import serial
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ser = serial.Serial()
ser.port = "COM15"  # change to your ESP32 port
ser.baudrate = 115200
ser.timeout = 0.2
ser.dtr = False
ser.rts = False
ser.open()

deadline = time.time() + 180
done = False
while time.time() < deadline and not done:
    data = ser.read(4096)
    if not data:
        continue
    text = data.decode("latin-1", "replace")
    for line in text.splitlines():
        if re.search(r"\[blocklist\]|\[led\]", line):
            print(line, flush=True)
            if re.search(
                r"list \d+: .* domains|snapshot saved|download failed|reload failed|"
                r"rejected|no PSRAM|not enough PSRAM",
                line,
            ):
                done = True
ser.close()
print("WATCHER_DONE", flush=True)
