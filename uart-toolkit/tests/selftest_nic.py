#!/usr/bin/env python3
"""Offline identity and guard tests for set_wired_ip.ps1.

Never applies or rolls back: only Show and WhatIf are executed. Cases that
cannot run because the shell is not elevated, the USB link is Down, or no
saved state exists are reported BLOCKED, never PASS.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "set_wired_ip.ps1"
PS = "powershell.exe"
results = []


def run(args: list[str]):
    return subprocess.run([PS, "-NoProfile", "-ExecutionPolicy", "Bypass",
                           "-File", str(SCRIPT)] + args,
                          capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=90)


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"{status} {name}" + (f" - {detail}" if detail else ""))
    results.append((name, status, detail))


def blocked(name, why):
    print(f"BLOCKED {name} - {why}")
    results.append((name, "BLOCKED", why))


def skip(name, why):
    print(f"SKIP {name} - {why}")
    results.append((name, "SKIP", why))


def find_target(out: str):
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if "Desc: Realtek Gaming USB 2.5GbE" in line and i >= 2:
            g = re.search(r"GUID:\s*(\{[0-9A-Fa-f-]+\})", lines[i - 2])
            m = re.search(r"MAC\s*:\s*([0-9A-Fa-f-]+)", lines[i - 1])
            if g and m:
                return g.group(1), m.group(1)
    return None, None


def main() -> int:
    # Pure logic simulations for ARP/DAD/rollback/identity.
    st = run(["-SelfTest"])
    stout = (st.stdout or "") + (st.stderr or "")
    check("NIC logic SelfTest passes", st.returncode == 0 and "ALL NIC LOGIC SELF-TESTS PASSED" in stout,
          f"exit={st.returncode}")
    check("NIC SelfTest covers expected cases", "TOTAL 40" in stout and "PASS 40" in stout,
          stout.strip().splitlines()[-2] if stout.strip() else "")
    check("NIC SelfTest exercises Restore-StateInternal chain",
          "RESTORE TOTAL 35" in stout and "PASS 35" in stout and "FAIL 0" in stout,
          "mock ops; no real network")
    check("NIC SelfTest covers Manual DAD states",
          "DadTransmits=0 is INCONCLUSIVE" in stout and
          "Duplicate manual address fails" in stout and
          "Tentative manual address times out" in stout and
          "missing AddressState is INCONCLUSIVE" in stout,
          "mock ops; no real network")

    show = run(["-Show"])
    out = (show.stdout or "") + (show.stderr or "")
    check("Show runs read-only", show.returncode == 0, f"exit={show.returncode}")
    check("Show does not mark Wi-Fi as target",
          not any(("WLAN" in l or "Wi-Fi" in l or "Wireless" in l) and "TARGET-CANDIDATE" in l
                  for l in out.splitlines()))
    check("Show exposes PNP device ID for candidate", "PNP : USB\\VID_" in out)
    check("Show exposes DadTransmits", "DadTransmits:" in out)
    dad_match = re.search(r"DadTransmits:\s*(\d+)", out)
    check("target interface has DAD enabled (DadTransmits > 0, read-only)",
          dad_match is not None and int(dad_match.group(1)) > 0,
          f"value={dad_match.group(1) if dad_match else 'missing'}")

    # Windows PowerShell 5.1 does not support Get-NetAdapter -InterfaceGuid.
    param_probe = subprocess.run(
        [PS, "-NoProfile", "-Command",
         "if ((Get-Command Get-NetAdapter).Parameters.Keys -contains 'InterfaceGuid') { exit 1 } else { exit 0 }"],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
    check("Get-NetAdapter has no -InterfaceGuid parameter",
          param_probe.returncode == 0, f"exit={param_probe.returncode}")

    guid, mac = find_target(out)
    if not guid:
        blocked("NIC identity tests", "no eligible Realtek USB 2.5GbE adapter present")
    else:
        print(f"      target: GUID={guid} MAC={mac}")
        ok = run(["-Show", "-InterfaceGuid", guid, "-MacAddress", mac])
        okout = (ok.stdout or "") + (ok.stderr or "")
        check("Show accepts exact GUID+MAC identity",
              ok.returncode == 0 and f"guid={guid}" in okout and "Eligible target" in okout,
              f"exit={ok.returncode}")

        badmac = run(["-Show", "-InterfaceGuid", guid, "-MacAddress", "00-00-00-00-00-00"])
        bm = (badmac.stdout or "") + (badmac.stderr or "")
        check("Show rejects wrong MAC",
              badmac.returncode == 0 and "Eligible target: none" in bm,
              f"exit={badmac.returncode}")

        badguid = run(["-Show", "-InterfaceGuid", "{00000000-0000-0000-0000-000000000000}",
                       "-MacAddress", mac])
        bg = (badguid.stdout or "") + (badguid.stderr or "")
        check("Show rejects wrong GUID",
              badguid.returncode == 0 and "Eligible target: none" in bg,
              f"exit={badguid.returncode}")

        # Apply requires identity before anything else.
        p = run(["-Apply", "-IUnderstandThisChangesTheWiredAdapter", "-WhatIf"])
        check("Apply without GUID+MAC is refused",
              p.returncode == 2 and "both -InterfaceGuid and -MacAddress" in (p.stdout + p.stderr),
              f"exit={p.returncode}")

        p2 = run(["-Apply", "-Rollback", "-InterfaceGuid", guid, "-MacAddress", mac])
        check("Apply + Rollback together is refused",
              p2.returncode == 2 and "cannot be used together" in (p2.stdout + p2.stderr),
              f"exit={p2.returncode}")

        state_dir = ROOT / "reports" / "netcfg"
        before = state_dir.exists()
        p3 = run(["-Apply", "-InterfaceGuid", guid, "-MacAddress", mac,
                  "-IUnderstandThisChangesTheWiredAdapter", "-WhatIf"])
        out3 = (p3.stdout or "") + (p3.stderr or "")
        after = state_dir.exists()
        if p3.returncode == 0:
            check("Apply WhatIf makes no change and writes no state",
                  "WhatIf" in out3 and before == after,
                  f"exit={p3.returncode} state_before={before} state_after={after}")
        elif p3.returncode == 5:
            blocked("Apply WhatIf", "administrator rights required (real precondition)")
        elif p3.returncode == 3:
            reason = "link down or address conflict"
            for line in out3.splitlines():
                if "REFUSED" in line:
                    reason = line.strip()
                    break
            blocked("Apply WhatIf", reason)
        else:
            check("Apply WhatIf guard", False, f"unexpected exit={p3.returncode}: {out3[-300:]}")

        p4 = run(["-Rollback", "-InterfaceGuid", guid, "-MacAddress", mac, "-WhatIf"])
        out4 = (p4.stdout or "") + (p4.stderr or "")
        if p4.returncode == 5:
            blocked("Rollback WhatIf", "administrator rights required (real precondition)")
        elif p4.returncode == 3:
            blocked("Rollback WhatIf", "no saved state or target precondition not met")
        elif p4.returncode == 0:
            check("Rollback WhatIf makes no change", "WhatIf" in out4, f"exit={p4.returncode}")
        else:
            check("Rollback WhatIf guard", False, f"unexpected exit={p4.returncode}: {out4[-300:]}")

    blocked("Real ARP/neighbor/DAD probe on USB interface",
            "当前非管理员且 USB 链路 Disconnected；只执行了 SelfTest 纯逻辑模拟")
    blocked("Real automatic rollback on modification failure",
            "本轮禁止实际修改网络；只验证了回滚判定逻辑")

    print()
    failed = [r for r in results if r[1] == "FAIL"]
    blocked_n = [r for r in results if r[1] == "BLOCKED"]
    skipped = [r for r in results if r[1] == "SKIP"]
    passed = [r for r in results if r[1] == "PASS"]
    print(f"TOTAL {len(results)}  PASS {len(passed)}  FAIL {len(failed)}  "
          f"BLOCKED {len(blocked_n)}  SKIP {len(skipped)}")
    if failed:
        print("FAILED: " + ", ".join(r[0] for r in failed))
        return 1
    print("ALL EXECUTED NIC SELF-TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
