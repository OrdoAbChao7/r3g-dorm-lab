#!/usr/bin/env python3
"""Static/runtime safety checks for the recovery toolkit (offline only).

Verifies that:
  * no automation script contains a flash/NVRAM write command;
  * uart_capture.py has no serial write path;
  * tftp_server.py does not open files for writing except its append-only log;
  * set_wired_ip.ps1 targets only the Realtek USB 2.5GbE adapter and never
    marks the Wi-Fi adapter as a target;
  * set_wired_ip.ps1 refuses -Apply without the explicit acknowledgement;
  * verify_firmware.ps1 contains no network-changing cmdlet.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
ALLOWLIST_PATH = ROOT / "tests" / "safety_allowlist.json"
PY = sys.executable
results = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (f" - {detail}" if detail else ""))
    results.append((name, cond, detail))


def scan(path: Path, patterns: list[str]):
    text = path.read_text(encoding="utf-8", errors="replace")
    hits = []
    for p in patterns:
        for m in re.finditer(p, text, re.I):
            line = text.count("\n", 0, m.start()) + 1
            hits.append((p, line))
    return hits


MENU_TOKEN = r"(?:菜单|选项|选择)\s*(?:2|二)"
INPUT_TOKEN = r"输入\s*(?:2|二|Y|y)"
DIRECT_ACTION = r"(?:确认写入|执行恢复|恢复原厂|写入内核|启动恢复菜单)"
POSITIVE_MENU_RE = re.compile(
    r"(?:^|[。；;！!，,\n])\s*(?:但|若|如果)?\s*"
    r"(?:请|再次|直接|如需|需要|可以|按提示|按|进入|启动|执行|选择|输入|确认|点击|运行|使用|恢复应|恢复需要|恢复必须)"
    r"[^。；;！!\n]{0,30}?(?:" + MENU_TOKEN + r"|" + INPUT_TOKEN + r"|" + DIRECT_ACTION + r")|"
    r"(?:^|[。；;！!，,\n])\s*" + MENU_TOKEN +
    r"\s*(?:后|然后|并|，|,)?\s*(?:等待|写入|擦除|恢复|回退|刷写|烧录|输入|确认)|"
    r"(?:^|[。；;！!，,\n])\s*" + DIRECT_ACTION + r"|"
    r"(?:^|[+，,]\s*)" + INPUT_TOKEN + r"|"
    r"(?:在|于)[^。；;！!\n]{0,20}?输入\s*(?:2|二|Y|y)", re.I)
MENU2_RE = re.compile(r"(?:菜单|选项|选择)\s*(?:2|二)|menu\s*2", re.I)
ACTION_RE = re.compile(r"(写入|写到|擦除|恢复|回退|救砖|刷写|烧录|输入|选择|进入|启动|执行|确认|"
                       r"flash\s*write|write|erase|recover|rollback)", re.I)
MIXED_RE = re.compile(r"(?:菜单|选项|选择)\s*1\s*[/／]\s*2", re.I)
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
PROHIBITION_RE = re.compile(r"(禁止|不得|不要|不能|不允许|不提供|不属于|不是|不得据此|不可|未授权)")
FACT_RE = re.compile(r"(历史|证据|此前|曾经|当时|记录|显示|实测|官方|提交|设计|用途|原理|"
                     r"分析|说明|据|会|将|可能)")

# Dangerous write commands. Read-only printenv/fw_printenv/nanddump/nand read/
# mtd without write-verb are deliberately absent.
DANGER_PATTERNS = [
    (re.compile(r"\bmtd\s+(?:write|erase)\b", re.I), "mtd write/erase"),
    (re.compile(r"\bnand\s+(?:write|erase)\b", re.I), "nand write/erase"),
    (re.compile(r"\bsetenv\b", re.I), "setenv"),
    (re.compile(r"\bsaveenv\b", re.I), "saveenv"),
    (re.compile(r"\bfw_setenv\b", re.I), "fw_setenv"),
    (re.compile(r"\bubiformat\b", re.I), "ubiformat"),
    (re.compile(r"\bflash_erase\b", re.I), "flash_erase"),
    (re.compile(r"\bflashcp\b", re.I), "flashcp"),
    (re.compile(r"\bnvram\s+(?:set|commit)\b", re.I), "nvram set/commit"),
    (re.compile(r"\buci\s+(?:set|commit)\b", re.I), "uci set/commit"),
    (re.compile(r"\bdd\b[^\n]*of=/dev/(?:mtd|ubi)", re.I), "dd to mtd/ubi"),
    (re.compile(r"(?<![\w.-])sysupgrade(?![\w.-])", re.I), "sysupgrade"),
]


def load_allowlist() -> set[tuple[str, int, str]]:
    if not ALLOWLIST_PATH.exists():
        return set()
    data = json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8"))
    out = set()
    for entry in data.get("entries", []):
        out.add((entry["file"], int(entry["line"]), entry["sha256"].lower()))
    return out


def line_hash(line: str) -> str:
    return hashlib.sha256(line.strip().encode("utf-8")).hexdigest()


def _is_allowed(rel: str, line_no: int, line: str, allow: set) -> bool:
    return (rel, line_no, line_hash(line)) in allow


def _positive_menu(line: str) -> bool:
    return bool(POSITIVE_MENU_RE.search(line))


def _positive_danger(line: str) -> bool:
    for pat, _kind in DANGER_PATTERNS:
        for m in pat.finditer(line):
            prefix = line[max(0, m.start() - 36):m.start()]
            if re.search(r"(禁止|不得|不要|不能|不允许|不可|曾|已经|此前|当时|历史)", prefix[-30:]):
                continue
            if re.search(r"(?:^|[。；;！!，,\n])\s*(?:请|执行|运行|输入|使用|在[^。；\n]{0,12}中)"
                         r"\s*[^。；\n]{0,18}$", prefix):
                return True
    return False


def scan_text(text: str, rel: str = "", allow: set | None = None):
    """Return (line, kind, text) for executable menu/Flash guidance.

    Chapter headings never exempt anything. Menu positive steps are always
    violations. A dangerous command is allowed only when the same paragraph
    explicitly prohibits it (and no positive command is present), or when the
    exact (file, line number, line SHA-256) entry is in the explicit allowlist.
    Read-only commands are not in DANGER_PATTERNS.
    """
    if allow is None:
        allow = load_allowlist()
    lines = text.splitlines()
    violations = []
    para = []

    def flush():
        nonlocal para
        if not para:
            return
        menu_susp = []
        danger = []
        menu_positive = False
        danger_positive = False
        prohibited = False
        fact = False
        for ln, line in para:
            allowed = _is_allowed(rel, ln, line, allow)
            if _positive_menu(line) and not allowed:
                menu_positive = True
            if ((MENU2_RE.search(line) and ACTION_RE.search(line)) or MIXED_RE.search(line)) and not allowed:
                menu_susp.append((ln, line))
            if _positive_danger(line):
                danger_positive = True
            if PROHIBITION_RE.search(line):
                prohibited = True
            if FACT_RE.search(line):
                fact = True
            for pat, kind in DANGER_PATTERNS:
                if pat.search(line) and not allowed:
                    danger.append((ln, kind, line))
        if menu_positive:
            for ln, line in menu_susp[:1] or [(para[0][0], para[0][1])]:
                violations.append((ln, "positive menu-2 operation", line.strip()[:140]))
        elif menu_susp and not (prohibited or fact):
            for ln, line in menu_susp[:1]:
                violations.append((ln, "suspicious menu-2 description", line.strip()[:140]))
        for ln, kind, line in danger:
            if danger_positive:
                violations.append((ln, "positive dangerous command: " + kind, line.strip()[:140]))
            elif prohibited:
                pass
            else:
                violations.append((ln, kind, line.strip()[:140]))
        para = []

    for i, line in enumerate(lines, 1):
        if HEADING_RE.match(line):
            flush()
            continue
        if not line.strip():
            flush()
            continue
        para.append((i, line))
    flush()
    return violations


# Backward-compatible name used by older test code.
def scan_guidance(text: str):
    return scan_text(text, "", set())


def main() -> int:
    flash_patterns = [
        r"\bmtd\s+write\b", r"\bmtd\s+erase\b", r"\bnand\s+erase\b",
        r"\bnand\s+write\b", r"\bubiformat\b", r"\bsaveenv\b",
        r"\bflash\s+write\b", r"\berase\s+all\b",
    ]
    for f in sorted(SCRIPTS.iterdir()):
        if f.suffix.lower() not in (".py", ".ps1"):
            continue
        hits = scan(f, flash_patterns)
        check(f"no flash/NVRAM write command in {f.name}", not hits,
              "; ".join(f"L{ln}:{p}" for p, ln in hits))

    cap = (SCRIPTS / "uart_capture.py").read_text(encoding="utf-8")
    check("uart_capture.py has no ser.write", "ser.write" not in cap)
    check("uart_capture.py has no serial.write", "serial.write" not in cap)

    tftp = (SCRIPTS / "tftp_server.py").read_text(encoding="utf-8")
    write_modes = re.findall(r"open\([^\n]*?,\s*[\"'](wb|w|a\+|w\+|r\+)[\"']", tftp)
    check("tftp_server.py only opens files for append-only logging",
          set(write_modes) <= {"a"}, str(write_modes))

    verify = (SCRIPTS / "verify_firmware.ps1").read_text(encoding="utf-8")
    net_cmds = re.findall(r"\b(Set-NetIPInterface|New-NetIPAddress|Remove-NetIPAddress|"
                          r"Set-NetRoute|Remove-NetRoute|Set-DnsClientServerAddress)\b", verify)
    check("verify_firmware.ps1 contains no network-changing cmdlet", not net_cmds, str(net_cmds))

    preflight = (SCRIPTS / "preflight.ps1").read_text(encoding="utf-8")
    pre_cmds = re.findall(r"\b(Set-NetIPInterface|New-NetIPAddress|Remove-NetIPAddress|"
                          r"Set-NetRoute|Remove-NetRoute|Set-DnsClientServerAddress|"
                          r"Restart-NetAdapter|Disable-NetAdapter|Enable-NetAdapter)\b", preflight)
    check("preflight.ps1 contains no network-changing cmdlet", not pre_cmds, str(pre_cmds))

    detect = (SCRIPTS / "detect_com.ps1").read_text(encoding="utf-8")
    check("detect_com.ps1 never opens/reads/writes a serial port",
          not re.search(r"\.Open\(|\.Read\(|\.Write\(|new\s+SerialPort|New-Object\s+.*SerialPort", detect, re.I))
    check("detect_com.ps1 uses read-only PnP/port enumeration",
          "Get-PnpDevice" in detect and "GetPortNames" in detect)

    start = (ROOT / "START_HERE.md").read_text(encoding="utf-8")
    tftp_lines = [l for l in start.splitlines() if "tftp_server.py" in l and "--root" in l]
    check("START_HERE has two independent TFTP configs", len(tftp_lines) == 2,
          f"commands={len(tftp_lines)}")
    openwrt_ok = any(("firmware\\openwrt" in l and "initramfs-kernel.bin" in l and
                      "8d58d8a1" in l and "kernel1.bin" not in l) for l in tftp_lines)
    stock_ok = any(("firmware\\tftp_stock" in l and "kernel1.bin" in l and
                    "ab893d6c" in l and "initramfs" not in l) for l in tftp_lines)
    check("START_HERE config A is OpenWrt initramfs only", openwrt_ok)
    check("START_HERE config B is stock kernel1 only", stock_ok)

    check("START_HERE marks menu 2 BLOCKED", "菜单 2" in start and "BLOCKED" in start)
    check("START_HERE wiring: J4 TX -> CH340 RXD",
          "CH340 RXD" in start and "J4 TX" in start)
    check("START_HERE first round does not connect CH340 TXD",
          "不接 CH340 TXD" in start or "不要接 CH340 TXD" in start)

    for doc in ("FLASH_SAFETY_REVIEW.md", "START_HERE.md",
                "docs/RECOVERY_DECISION_TREE.md", "research/TFTP_RECOVERY_ANALYSIS.md"):
        text = (ROOT / doc).read_text(encoding="utf-8")
        check(f"{doc}: option 2 BLOCKED", "BLOCKED" in text)
        check(f"{doc}: option 5/6 permanently forbidden", "永久禁止" in text)
        check(f"{doc}: no absolute read-only claim for whole initramfs",
              "绝对只读" in text and ("不等于" in text or "不是" in text or "不得" in text))
        check(f"{doc}: every flash write needs separate review",
              "单独" in text and ("审查" in text or "授权" in text))

    # Reverse scan: executable guidance must not remain in any shipped file.
    allow = load_allowlist()
    allow_data = json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8")) if ALLOWLIST_PATH.exists() else {"entries": []}
    for entry in allow_data.get("entries", []):
        rel, ln, digest = entry["file"], int(entry["line"]), entry["sha256"].lower()
        p = ROOT / rel
        lines = p.read_text(encoding="utf-8").splitlines() if p.is_file() else []
        actual = line_hash(lines[ln - 1]) if 0 < ln <= len(lines) else ""
        check(f"allowlist exact content: {rel}:{ln}", actual == digest,
              "stale allowlist entry must be removed or re-approved with a recorded reason")
    main_manuals = ["START_HERE.md", "FLASH_SAFETY_REVIEW.md",
                    "docs/RECOVERY_DECISION_TREE.md",
                    "docs/STOCK_RESTORE_AND_OPENWRT_INSTALL.md"]
    for doc in main_manuals:
        text = (ROOT / doc).read_text(encoding="utf-8")
        violations = scan_text(text, doc, allow)
        check(f"{doc}: no menu-2/executable dangerous guidance", not violations,
              "; ".join(f"L{ln}:{kind}" for ln, kind, _ in violations[:4]))

        # Unverified MIPS addresses must not be presented as definite values.
        addr_bad = []
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if "0xA0200000" in line or "0x80A00000" in line:
                ctx = "\n".join(lines[max(0, i - 2):i + 3])
                if not any(m in ctx for m in ("UNVERIFIED", "未验证", "禁止", "不得")):
                    addr_bad.append(i + 1)
        check(f"{doc}: unverified load addresses are marked", not addr_bad, str(addr_bad))

        check(f"{doc}: TFTP success is not equated to NAND recovery",
              "不等于 NAND 恢复成功" in text)
        check(f"{doc}: kernel0 protection is explicit",
              ("保护 kernel0" in text or "kernel0 未写" in text) and "kernel0 可覆盖" not in text)

    # Every shipped text/code scope, including SOURCE_RESEARCH.md and tests.
    # The scanner's own test file is excluded because it intentionally contains
    # malicious synthetic strings; all other tests are scanned.
    scan_files = [ROOT / "START_HERE.md", ROOT / "FLASH_SAFETY_REVIEW.md",
                  ROOT / "TOOLCHAIN_TEST_REPORT.md", ROOT / "README.md",
                  ROOT / "SOURCE_RESEARCH.md",
                  ROOT / "HARDWARE_SESSION_CHECKLIST.md",
                  ROOT / "READ_ONLY_UART_PROCEDURE.md",
                  ROOT / "R3G_RECOVERY_DECISION_TREE_FINAL.md",
                  ROOT / "R3G_BOOT_LOG_ANALYSIS.md"]
    for folder in ("docs", "research", "scripts", "tests"):
        scan_files.extend(sorted((ROOT / folder).rglob("*")))
    seen = set()
    for p in scan_files:
        if not p.is_file() or p.suffix.lower() not in (".md", ".py", ".ps1", ".txt"):
            continue
        rel = p.relative_to(ROOT).as_posix()
        if rel in seen:
            continue
        seen.add(rel)
        if rel == "tests/selftest_safety.py":
            check("scanner self-test file is excluded from self-scan (synthetic data)", True)
            continue
        if rel.startswith("research/sources/"):
            # Raw HTML/JSON/string exports are external evidence, not
            # operational documents; scan their synthesized research/*.md
            # summaries instead.
            check("raw research exports are excluded from guidance scan (evidence data)", True)
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        violations = scan_text(text, rel, allow)
        check(f"{rel}: no executable menu/Flash guidance", not violations,
              "; ".join(f"L{ln}:{kind}" for ln, kind, _ in violations[:4]))

    # The test report must not present simulations as real hardware tests.
    test_report = (ROOT / "TOOLCHAIN_TEST_REPORT.md").read_text(encoding="utf-8")
    check("test report distinguishes simulation from hardware",
          "NOT TESTED" in test_report and "BLOCKED" in test_report and
          "真实硬件测试通过" not in test_report and
          "软件测试通过不等于真实硬件恢复通过" in test_report)

    # The scanner must distinguish history/prohibition from executable steps.
    synthetic = [
        ("## 历史证据\n\n请再次选择菜单 2 并输入 Y 写入内核。", True),
        ("## 风险分析\n\n如需恢复，进入菜单 2 并确认写入。", True),
        ("菜单 2 为 BLOCKED。\n\n但是，如果需要恢复，可以再次选择菜单 2。", True),
        ("禁止执行菜单 2；但请选择菜单 2 并输入 Y。", True),
        ("菜单 2 为 BLOCKED，不得执行。\n但若要恢复，请选择菜单 2 并输入 Y 写入内核。", True),
        ("选择 2，按提示操作。", True),
        ("再次选项 2 写入已知良好的 4 MiB 原厂内核。", True),
        ("恢复应通过选项 1/2 或 Linux mtd。", True),
        ("选项 2 擦除两个内核槽。", True),
        ("菜单 2 + 输入 Y 确认，然后观察 Writing image。", True),
        ("禁止执行菜单 2 写入；不得输入 Y。", False),
        ("菜单 2 为 BLOCKED，不属于默认恢复流程。", False),
        ("技术原理：菜单 2 可能擦除 kernel0，但未实测。", False),
        ("本节仅保留风险分析：选项 2 写入两个槽，不得照做。", False),
        ("## 历史证据\n\n官方 2019 提交记录：菜单 2 会把镜像写入两个内核槽。", False),
        ("此前曾经执行过菜单 2；历史记录显示当时向两个内核槽写入。", False),
        ("## 禁止事项\n\n不得执行 saveenv、nand write 或 nand erase。", False),
        ("TFTP 成功不等于 NAND 恢复成功；不得据此执行菜单 2。", False),
        ("菜单 2 在 U-Boot 中的设计用途是接收镜像并写入内核区域；本文件不提供执行步骤。", False),
        ("历史记录显示当时曾向两个内核槽写入，未提供任何操作步骤。", False),
        ("请再次选择菜单 2。", True),
        ("请进入菜单 2。", True),
        ("选择菜单2后等待。", True),
        ("在 U-Boot 中输入 2。", True),
        ("请执行 mtd write image kernel1。", True),
        ("请执行 setenv flag_last_success 0。", True),
        ("请执行 fw_setenv flag_last_success 0。", True),
        ("请执行 ubiformat /dev/mtdX。", True),
        ("请执行 flash_erase /dev/mtdX。", True),
        ("请执行 nvram set flag_try_sys1_failed=1。", True),
        ("请执行 nvram commit。", True),
        ("请执行 uci set network.lan.ipaddr=192.168.31.100。", True),
        ("请执行 uci commit。", True),
        ("请执行 dd if=image.bin of=/dev/mtdblock3。", True),
        ("请执行 sysupgrade -n image.bin。", True),
        ("请执行 flashcp image.bin /dev/mtd3。", True),
        ("按菜单 2 执行恢复。", True),
        ("启动恢复菜单并确认写入。", True),
        ("选择选项二后写入内核。", True),
        ("输入Y确认写入。", True),
        ("fw_printenv 只读，不写入。", False),
        ("printenv 只读。", False),
        ("nanddump /dev/mtd0 只读。", False),
        ("禁止执行 `mtd write`。", False),
        ("不得执行 `nand erase`。", False),
        ("`saveenv` 属于 NVRAM 写入，禁止执行。", False),
        ("历史记录：曾执行 `setenv`，但本文件不提供执行步骤。", False),
        ("禁止 `ubiformat`、`flash_erase`、`flashcp`。", False),
        ("`sysupgrade.bin` 是文件名，不是命令。", False),
        ("`mtdinfo` 只读查询；本文件不提供任何写入步骤。", False),
        ("`setenv`/`saveenv` 必须单独授权，禁止照抄执行。", False),
        ("不要执行 `nvram set` 或 `nvram commit`。", False),
        ("不要执行 `uci set` 或 `uci commit`。", False),
        ("禁止 `dd ... of=/dev/mtd`。", False),
        ("菜单 2 为 BLOCKED，不属于恢复流程。", False),
        ("禁止选择菜单 2。", False),
        ("不要输入 Y。", False),
        ("历史记录显示当时曾向两个内核槽写入，未提供步骤。", False),
        ("菜单 2 的设计用途是写内核，本文件不提供执行步骤。", False),
        ("`fw_printenv` 和 `nanddump` 只读，允许用于诊断。", False),
    ]
    for idx, (sample, expect_violation) in enumerate(synthetic, 1):
        found = bool(scan_text(sample, "", set()))
        check(f"guidance scanner case {idx}", found == expect_violation,
              f"expected_violation={expect_violation} got={found}")

    wired = (SCRIPTS / "set_wired_ip.ps1").read_text(encoding="utf-8")
    check("set_wired_ip.ps1 matches Realtek + USB + 2.5GbE",
          "'Realtek'" in wired and "'USB'" in wired and r"2\.5\s*GbE" in wired)
    check("set_wired_ip.ps1 refuses wireless in target filter",
          "NdisPhysicalMedium -ne 9" in wired and "Wi-?Fi|Wireless|802\\.11" in wired)
    check("set_wired_ip.ps1 Apply requires explicit acknowledgement",
          "-IUnderstandThisChangesTheWiredAdapter" in wired)
    check("set_wired_ip.ps1 does not set a default gateway",
          "-DefaultGateway" not in wired)
    dns_start = wired.find("function Restore-StateInternal")
    dns_end = wired.find("function Invoke-RestoreFlow")
    dns_gate = ("DnsTouched" in wired and "Restore-DnsState" in wired and
                dns_start != -1 and dns_end > dns_start and
                "Set-DnsClientServerAddress" not in wired[dns_start:dns_end] and
                "Restore-DnsState $adapter $state $Ops" in wired[dns_start:dns_end])
    check("DNS restore is gated by DnsTouched and uses injected ops", dns_gate)
    check("DNS write commands exist only in SetDns adapter",
          wired.count("Set-DnsClientServerAddress") == 2,
          f"count={wired.count('Set-DnsClientServerAddress')}")
    restore_start = wired.find("function Remove-AllManualIpv4")
    restore_end = wired.find("function Invoke-WithAutoRollback")
    restore_body = wired[restore_start:restore_end] if restore_start != -1 and restore_end > restore_start else ""
    net_cmds = re.findall(r"\b(?:Get|Set|New|Remove)-Net(?:Adapter|IPAddress|IPInterface|Route|Neighbor|DnsClientServerAddress)\b", restore_body)
    check("restore call chain has no direct real network cmdlet", not net_cmds, str(net_cmds))

    # Runtime: Show must not mark the WLAN adapter as a target.
    p = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(SCRIPTS / "set_wired_ip.ps1"), "-Show"],
                       capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=60)
    out = (p.stdout or "") + (p.stderr or "")
    wlan_ok = True
    for line in out.splitlines():
        if re.search(r"\bWLAN\b|Wi-Fi|Wireless", line, re.I) and "TARGET-CANDIDATE" in line:
            wlan_ok = False
    check("set_wired_ip.ps1 -Show does not mark Wi-Fi as target", wlan_ok, f"exit={p.returncode}")
    check("set_wired_ip.ps1 -Show runs read-only", p.returncode == 0, f"exit={p.returncode}")

    # Runtime: Apply without the mandatory GUID/MAC identity must refuse.
    p2 = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                         "-File", str(SCRIPTS / "set_wired_ip.ps1"), "-Apply",
                         "-IUnderstandThisChangesTheWiredAdapter", "-WhatIf"],
                        capture_output=True, text=True, encoding="utf-8",
                        errors="replace", timeout=60)
    out2 = (p2.stdout or "") + (p2.stderr or "")
    check("set_wired_ip.ps1 -Apply without GUID+MAC is refused",
          p2.returncode == 2 and "REFUSED" in out2, f"exit={p2.returncode}")

    print()
    failed = [r for r in results if not r[1]]
    print(f"TOTAL {len(results)}  PASS {len(results)-len(failed)}  FAIL {len(failed)}")
    if failed:
        print("FAILED: " + ", ".join(r[0] for r in failed))
        return 1
    print("ALL SAFETY SELF-TESTS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
