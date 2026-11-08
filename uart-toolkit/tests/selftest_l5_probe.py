#!/usr/bin/env python3
"""Offline state-machine test for uart_l5_tftp_probe.py.

No real serial port is opened. A fake serial feeds the real U-Boot menu and
the three network prompts, then a fake TFTP/load trace. The test asserts the
probe sends only menu 1, the two IPs, and the filename.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "scripts" / "uart_l5_tftp_probe.py"
FILENAME = "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-initramfs-kernel.bin"


class FakeSerial:
    def __init__(self, schedule):
        self.schedule = schedule
        self.pending = bytearray()
        self.written = bytearray()
        self.closed = False

    def _pump(self):
        now = time.monotonic()
        rest = []
        for due, data in self.schedule:
            if due <= now:
                self.pending.extend(data)
            else:
                rest.append((due, data))
        self.schedule = rest

    @property
    def in_waiting(self):
        self._pump()
        return len(self.pending)

    def read(self, n):
        self._pump()
        if self.pending:
            data = bytes(self.pending[:n])
            del self.pending[:n]
            return data
        time.sleep(0.01)
        return b""

    def write(self, payload):
        self.written.extend(payload)
        now = time.monotonic()
        if payload == b"1":
            self.stage = 1
            self.schedule.append((now + 0.20,
                b"Please Input new ones /or Ctrl-C to discard\r\n"
                b"        Input device IP (192.168.31.1) ==:"))
        elif payload == b"\r" and getattr(self, "stage", 0) == 1:
            self.stage = 2
            self.schedule.append((now + 0.20,
                b"        Input server IP (192.168.31.100) ==:"))
        elif payload == b"\r" and getattr(self, "stage", 0) == 2:
            self.stage = 3
            self.schedule.append((now + 0.20,
                b"        Input Linux Kernel filename (uImage) ==:"))
        elif payload == (FILENAME + "\r").encode("ascii"):
            self.stage = 4
            self.schedule.append((now + 0.20,
                b"\r\nUsing eth0 device\r\n"
                b"TFTP from server 192.168.31.100; our IP address is 192.168.31.1\r\n"
                b"Loading: ############################################################\r\n"
                b"done\r\n"
                b"## Booting image at 80001000 ...\r\n"
                b"Starting kernel ...\r\n"))

    def flush(self):
        pass

    def close(self):
        self.closed = True


def load_probe():
    spec = importlib.util.spec_from_file_location("uart_l5_tftp_probe", PROBE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    mod = load_probe()
    fake = FakeSerial([])
    fake.schedule.append((time.monotonic() + 0.20, (
        b"Please choose the operation: \r\n"
        b"   1: Load system code to SDRAM via TFTP. \r\n"
        b"   2: Load system code then write to Flash via TFTP. \r\n"
        b"   3: Boot system code via Flash (default).\r\n"
        b"   4: Entr boot command line interface.\r\n"
        b"   7: Load Boot Loader code then write to Flash via Serial. \r\n"
        b"   9: Load Boot Loader code then write to Flash via TFTP. \r\n"
        b" 4  3  2  1  0 \r\n"
    )))

    mod.find_port = lambda device: SimpleNamespace(device=device,
                                                   hwid="USB VID:PID=1A86:7523")
    mod.open_port = lambda device, baud: fake

    with tempfile.TemporaryDirectory() as td:
        sys.argv = [
            "uart_l5_tftp_probe.py",
            "--port", "COMX",
            "--allow-tx",
            "--out-dir", td,
            "--filename", FILENAME,
            "--menu-timeout", "2",
            "--prompt-timeout", "1",
            "--quiet-time", "0.2",
            "--max-after", "3",
        ]
        rc = mod.main()
        assert rc == 0, f"return code {rc}"
        assert fake.closed, "serial was not closed"
        expected = ("1" + "\r" + "\r" + FILENAME + "\r").encode("ascii")
        assert bytes(fake.written) == expected, bytes(fake.written)
        metas = list(Path(td).glob("*.meta.json"))
        actions = list(Path(td).glob("*.actions.json"))
        assert metas and actions, "missing meta/actions"
        meta = json.loads(metas[0].read_text(encoding="utf-8"))
        acts = json.loads(actions[0].read_text(encoding="utf-8"))
        assert meta["state"] == "LOADING", meta
        assert meta["tx_bytes"] == len(expected), meta
        assert [a["action"] for a in acts] == [
            "menu1", "device-default", "server-default", "filename"
        ], acts
        log = Path(meta["text_file"]).read_text(encoding="latin-1")
        assert "Starting kernel" in log, log[-500:]
        print("PASS l5 probe sends only menu1/IPs/filename")
        print("PASS l5 probe records TFTP load and Starting kernel")
        print("PASS l5 probe closes port and writes meta/actions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
