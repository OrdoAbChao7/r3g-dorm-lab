#!/usr/bin/env python3
"""Offline state-machine test for uart_l4_readonly_probe.py.

No real serial port is opened. A fake serial object feeds the real U-Boot menu
and prompt text and records every transmitted byte. The test asserts that the
probe sends only the authorized sequence: '4', Enter, 'printenv', Enter.
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
PROBE = ROOT / "scripts" / "uart_l4_readonly_probe.py"


class FakeSerial:
    def __init__(self, schedule):
        self.schedule = schedule  # list of (due_monotonic, bytes)
        self.pending = bytearray()
        self.written = bytearray()
        self.closed = False
        self.t0 = time.monotonic()

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
        if payload == b"4":
            self.schedule.append((now + 0.20, b"MT7621 # "))
        elif payload == b"printenv\r":
            self.schedule.append((now + 0.20, (
                b"baudrate=115200\r\n"
                b"bootcmd=mtkautoboot\r\n"
                b"flag_last_success=0\r\n"
                b"flag_try_sys1_failed=0\r\n"
                b"flag_try_sys2_failed=1\r\n"
                b"MT7621 # "
            )))

    def flush(self):
        pass

    def close(self):
        self.closed = True


def load_probe():
    spec = importlib.util.spec_from_file_location("uart_l4_readonly_probe", PROBE)
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
            "uart_l4_readonly_probe.py",
            "--port", "COMX",
            "--allow-tx",
            "--out-dir", td,
            "--menu-timeout", "2",
            "--prompt-timeout", "1",
            "--quiet-time", "0.2",
            "--max-after", "5",
        ]
        rc = mod.main()
        files = sorted(Path(td).glob("r3g_l4probe_*"))
        metas = list(Path(td).glob("*.meta.json"))
        actions = list(Path(td).glob("*.actions.json"))
        assert rc == 0, f"return code {rc}"
        assert fake.closed, "serial was not closed"
        assert bytes(fake.written) == b"4\rprintenv\r", bytes(fake.written)
        assert metas and actions, files
        meta = json.loads(metas[0].read_text(encoding="utf-8"))
        acts = json.loads(actions[0].read_text(encoding="utf-8"))
        assert meta["tx_bytes"] == 11, meta
        assert meta["state"] == "COLLECT", meta
        assert [a["action"] for a in acts] == ["menu4", "menu4-enter", "printenv"], acts
        log = Path(meta["text_file"]).read_text(encoding="latin-1")
        assert "flag_last_success=0" in log, log[-500:]
        print("PASS l4 probe sends only 4/Enter/printenv")
        print("PASS l4 probe captures printenv output")
        print("PASS l4 probe closes the port and writes meta/actions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
