#!/usr/bin/env python3
"""Reset the ESP32 via RTS and capture the boot log.

Read-only apart from the reset pulse. DTR is kept false so GPIO0 stays high
(normal boot). Used to diagnose the candidate firmware after flashing.
"""
import sys
import time

import serial

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ser = serial.Serial()
ser.port = "COM15"  # change to your ESP32 port
ser.baudrate = 115200
ser.timeout = 0.2
ser.dtr = False
ser.rts = False
ser.open()

# Normal-boot reset: assert RTS (EN low), release (EN high).
ser.rts = True
time.sleep(0.15)
ser.rts = False
time.sleep(0.10)

deadline = time.time() + 25
while time.time() < deadline:
    data = ser.read(4096)
    if data:
        sys.stdout.write(data.decode("latin-1", "replace"))
        sys.stdout.flush()
ser.close()
print("\nCAPTURE_DONE")
