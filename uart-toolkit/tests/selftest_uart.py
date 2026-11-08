#!/usr/bin/env python3
"""Offline self-test for uart_capture.py, uart_console.py and uart_analyze.py."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
ANALYZE = SCRIPTS / "uart_analyze.py"
CAPTURE = SCRIPTS / "uart_capture.py"
CONSOLE = SCRIPTS / "uart_console.py"
PY = sys.executable
results = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f" - {detail}" if detail else ""))
    results.append((name, cond, detail))


def run_analyzer(text: str):
    tmp = Path(tempfile.mkdtemp(prefix="r3g_uart_test_"))
    log = tmp / "log.txt"
    js = tmp / "out.json"
    md = tmp / "out.md"
    log.write_text(text, encoding="utf-8")
    p = subprocess.run([PY, "-I", str(ANALYZE), "--input", str(log),
                        "--out", str(md), "--json", str(js)],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=20)
    if p.returncode != 0:
        raise RuntimeError(p.stdout + p.stderr)
    return json.loads(js.read_text(encoding="utf-8")), md.read_text(encoding="utf-8")


def load_capture_module():
    spec = importlib.util.spec_from_file_location("uart_capture_mod", CAPTURE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    # 1. Multiple boots: last one must be System 1.
    f, md = run_analyzer(
        "Booting System 1\n"
        "Booting System 2\n"
        "Booting System 1\n")
    check("multi-boot sequence", f["facts"]["boot_sequence"] == [1, 2, 1],
          str(f["facts"]["boot_sequence"]))
    check("multi-boot last system is 1 (not first regex match)",
          f["facts"]["last_boot_system"] == 1 and f["facts"]["last_boot_system_line"] == 3,
          f"last={f['facts']['last_boot_system']} line={f['facts']['last_boot_system_line']}")
    check("multi-boot markdown states last observed System 1",
          "Last observed boot: System 1" in md)

    # 2. CRC mapping kernel1/kernel2 vs System 1/2.
    f2, md2 = run_analyzer(
        "Booting System 1\n"
        "Verifying kernel1 uImage CRC, addr: 0x200000\n"
        "   Verifying Checksum ... OK\n"
        "Booting System 2\n"
        "Verifying kernel2 uImage CRC, addr: 0x600000\n"
        "   Verifying Checksum ... OK\n"
        "Verifying kernel1 uImage CRC\n")
    crc = f2["facts"]["crc_checks"]
    check("kernel1@0x200000 maps to System 1",
          any(c["kernel_number"] == 1 and c["addr"] == "0x200000" and c["system"] == 1 for c in crc))
    check("kernel2@0x600000 maps to System 2",
          any(c["kernel_number"] == 2 and c["addr"] == "0x600000" and c["system"] == 2 for c in crc))
    check("kernel1 without address is labelled naming convention",
          any(c["kernel_number"] == 1 and c["addr"] is None and "naming convention" in c["mapping_basis"] for c in crc))
    check("markdown distinguishes U-Boot kernel names from partition labels",
          "not the Linux partition labels" in md2)

    # 3. CRC error, panic, UBI error, repeated boot.
    f3, md3 = run_analyzer(
        "Ralink UBoot Version: 5.0.0.0\n"
        "Booting System 2\n"
        "Verifying kernel2 uImage CRC, addr: 0x600000\n"
        "   Bad Data CRC\n"
        "Starting kernel ...\n"
        "Kernel panic - not syncing: VFS: Unable to mount root fs\n"
        "UBI error: cannot attach mtd9\n"
        "Rebooting in 1 seconds..\n"
        "Ralink UBoot Version: 5.0.0.0\n"
        "Booting System 2\n"
        "Ralink UBoot Version: 5.0.0.0\n")
    check("CRC error count", f3["facts"]["crc_error_count"] >= 1, str(f3["facts"]["crc_error_count"]))
    check("panic count", f3["facts"]["panic_count"] >= 1, str(f3["facts"]["panic_count"]))
    check("UBI/VFS error count", f3["facts"]["ubi_error_count"] >= 1, str(f3["facts"]["ubi_error_count"]))
    check("repeated boot banner count", f3["facts"]["uboot_banner_count"] == 3,
          str(f3["facts"]["uboot_banner_count"]))

    # 4. Flag occurrences: all listed, last value, never "current".
    f4, md4 = run_analyzer(
        "flag_last_success=1\n"
        "Booting System 2\n"
        "flag_try_sys1_failed=0\n"
        "flag_last_success=0\n"
        "flag_last_success=0\n")
    occ = f4["facts"]["flag_occurrences"]["flag_last_success"]
    check("all flag occurrences collected", len(occ) == 3, str(occ))
    check("last flag value is the last occurrence",
          f4["facts"]["flag_last_values"]["flag_last_success"] == "0")
    check("markdown does not present historical flags as current",
          "current values" in md4 and "not" in md4)
    check("markdown lists flag line numbers",
          "L1=1" in md4 and "L4=0" in md4 and "L5=0" in md4)

    # 5. Capture tool has no transmit path.
    src = CAPTURE.read_text(encoding="utf-8")
    check("uart_capture.py contains no ser.write", "ser.write" not in src)
    check("uart_capture.py contains no msvcrt", "msvcrt" not in src)
    check("uart_capture.py contains no allow-tx option", "--allow-tx" not in src)
    check("uart_capture.py declares LISTEN-ONLY", "LISTEN-ONLY" in src)

    # 6. Console refuses without --allow-tx and does not open a port.
    p = subprocess.run([PY, "-I", str(CONSOLE), "--port", "COM99"],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=10)
    check("uart_console.py refuses without --allow-tx",
          p.returncode == 2 and "REFUSED" in (p.stdout + p.stderr),
          f"exit={p.returncode}")

    # 7. Adapter VID/PID validation.
    mod = load_capture_module()
    cases = [
        ("USB VID:PID=1A86:7523 SER=1", True, "CH340"),
        ("USB VID:PID=10C4:EA60 SER=1", True, "CP210x"),
        ("USB VID:PID=0403:6001 SER=1", True, "FTDI"),
        ("USB VID:PID=303A:1001 SER=1", False, "Espressif"),
        ("USB VID:PID=1234:5678 SER=1", False, "unknown"),
    ]
    for hwid, expect_ok, label in cases:
        info = SimpleNamespace(hwid=hwid, device="COM9")
        ok, why = mod.validate_adapter(info, allow_any=False, expected=set())
        check(f"VID/PID {label}", ok == expect_ok, why)
    ok_any, why_any = mod.validate_adapter(SimpleNamespace(hwid="nohwid", device="COM9"),
                                           allow_any=True, expected=set())
    check("missing VID/PID allowed only with --allow-any-port", ok_any, why_any)
    ok_filter, why_filter = mod.validate_adapter(SimpleNamespace(hwid="USB VID:PID=1A86:7523", device="COM9"),
                                                 allow_any=False, expected={"10C4:EA60"})
    check("expected VID/PID filter works", not ok_filter, why_filter)

    # 8. Replay hash equals source.
    tmp = Path(tempfile.mkdtemp(prefix="r3g_capture_test_"))
    sample = tmp / "sample.bin"
    data = bytes(range(256)) * 8
    sample.write_bytes(data)
    p = subprocess.run([PY, "-I", str(CAPTURE), "--replay", str(sample),
                        "--out-dir", str(tmp / "out")],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=20)
    bins = list((tmp / "out").glob("*.bin"))
    ok = p.returncode == 0 and len(bins) == 1 and hashlib.sha256(bins[0].read_bytes()).hexdigest() == hashlib.sha256(data).hexdigest()
    check("replay raw BIN hash equals source", ok, f"exit={p.returncode}")

    print()
    failed = [r for r in results if not r[1]]
    print(f"TOTAL {len(results)}  PASS {len(results)-len(failed)}  FAIL {len(failed)}")
    if failed:
        print("FAILED: " + ", ".join(r[0] for r in failed))
        return 1
    print("ALL UART SELF-TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
