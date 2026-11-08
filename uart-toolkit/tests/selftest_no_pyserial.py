#!/usr/bin/env python3
"""Offline tests with pyserial made unimportable.

The wrapper installs an import blocker for `serial` / `serial.*` and then runs
the target script with runpy. This verifies dependency ordering:

  * uart_capture.py --replay works without pyserial.
  * uart_capture.py --port COMx without pyserial fails with exit 5 (only
    opening a port needs pyserial).
  * uart_console.py without --allow-tx refuses with exit 2 BEFORE checking
    pyserial.
  * uart_console.py with --allow-tx but without pyserial fails with exit 5.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
PY = sys.executable
results = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f" - {detail}" if detail else ""))
    results.append((name, cond, detail))


def run_without_pyserial(script: Path, args: list[str], cwd: Path | None = None):
    wrapper = r'''
import runpy, sys
class Blocker:
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "serial" or fullname.startswith("serial."):
            raise ImportError("pyserial intentionally blocked for this test")
        return None
sys.meta_path.insert(0, Blocker())
script = sys.argv[1]
sys.argv = [script] + sys.argv[2:]
try:
    runpy.run_path(script, run_name="__main__")
except SystemExit as e:
    raise SystemExit(e.code)
'''
    return subprocess.run([PY, "-I", "-c", wrapper, str(script)] + args,
                          capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=30, cwd=str(cwd) if cwd else None)


def main() -> int:
    sample = ROOT / "tests" / "sample_uboot_log.txt"
    tmp = Path(tempfile.mkdtemp(prefix="r3g_no_pyserial_"))

    p1 = run_without_pyserial(SCRIPTS / "uart_capture.py",
                              ["--replay", str(sample), "--out-dir", str(tmp / "replay")],
                              cwd=tmp)
    bins = list((tmp / "replay").glob("*.bin")) if (tmp / "replay").is_dir() else []
    check("capture --replay works without pyserial",
          p1.returncode == 0 and len(bins) == 1,
          f"exit={p1.returncode} bins={len(bins)}")

    p2 = run_without_pyserial(SCRIPTS / "uart_capture.py", ["--port", "COM99"], cwd=tmp)
    check("capture --port without pyserial exits 5",
          p2.returncode == 5 and "pyserial" in (p2.stdout + p2.stderr).lower(),
          f"exit={p2.returncode}")

    p3 = run_without_pyserial(SCRIPTS / "uart_console.py", ["--port", "COM99"], cwd=tmp)
    check("console without --allow-tx refuses before pyserial check",
          p3.returncode == 2 and "REFUSED" in (p3.stdout + p3.stderr),
          f"exit={p3.returncode}")

    p4 = run_without_pyserial(SCRIPTS / "uart_console.py",
                              ["--port", "COM99", "--allow-tx"], cwd=tmp)
    check("console with --allow-tx but without pyserial exits 5",
          p4.returncode == 5 and "pyserial" in (p4.stdout + p4.stderr).lower(),
          f"exit={p4.returncode}")

    print()
    failed = [r for r in results if not r[1]]
    print(f"TOTAL {len(results)}  PASS {len(results)-len(failed)}  FAIL {len(failed)}")
    if failed:
        print("FAILED: " + ", ".join(r[0] for r in failed))
        return 1
    print("ALL NO-PYSERIAL SELF-TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
