#!/usr/bin/env python3
"""Read-only analysis of a captured R3G UART log (second-audit hardened).

This tool never opens a serial port and never talks to the router. It only
reads a log (text or the raw .bin) and produces a Markdown summary plus an
optional JSON file.

Second-audit corrections:
  * All "Booting System N" events are collected in line order. The LAST one in
    the file is reported as the last observed boot, not the first regex match.
  * Every boot-flag occurrence is listed with its line number. A value seen in
    one log is never presented as the router's current value.
  * U-Boot's "kernel1/kernel2" CRC names are distinguished from the Linux
    partition labels kernel0/kernel1. When the CRC line includes an address,
    kernel1 @0x200000 is mapped to System 1 and kernel2 @0x600000 to System 2;
    otherwise the mapping is labelled as a naming convention, not a fact.
  * CRC errors, kernel panics, UBI errors and repeated boot cycles are counted
    with line numbers.

It reports what the log contains. It does not choose a recovery action and
never generates flash-write commands.

Usage:
    python -I uart_analyze.py --input logs/r3g_uart_20261104-120000.log
    python -I uart_analyze.py --input logs/r3g_uart_20261104-120000.bin --out reports/analysis.md
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

PATTERNS = {
    "uboot_identity": [
        re.compile(r"U-Boot\s+[\d.]+\s*\([^)]*\)"),
        re.compile(r"Ralink UBoot Version:\s*\S+"),
        re.compile(r"MT7621 stage1 code done", re.I),
        re.compile(r"DRAMC calibration passed", re.I),
        re.compile(r"Power on memory test.*", re.I),
    ],
    "uboot_menu": [
        re.compile(r"Please choose the operation"),
        re.compile(r"\d+:\s*(Load system code|Load Boot|Load UBoot|Boot system code|Entr boot command line|System Load|System Enter)"),
        re.compile(r"Please Input new ones"),
        re.compile(r"Input (device IP|server IP|Linux Kernel filename|Uboot filename)"),
    ],
    "boot_selection": [
        re.compile(r"Booting System\s*[12]", re.I),
        re.compile(r"Verifying kernel[12] uImage CRC.*", re.I),
        re.compile(r"Boot failure detected on both systems", re.I),
        re.compile(r"flag_try_sys[12]_failed\s*[:=]\s*\d+", re.I),
        re.compile(r"flag_last_success\s*[:=]\s*\d+", re.I),
        re.compile(r"flag_boot_rootfs\s*[:=]\s*\S+", re.I),
        re.compile(r"flag_boot_success\s*[:=]\s*\d+", re.I),
    ],
    "image_crc": [
        re.compile(r"Verifying Checksum\s*\.*\s*(OK|FAILED|Bad)", re.I),
        re.compile(r"Bad Magic Number", re.I),
        re.compile(r"Bad Header Checksum", re.I),
        re.compile(r"Bad Data CRC", re.I),
        re.compile(r"Uncompressing Kernel Image\s*\.*\s*(OK|error)", re.I),
        re.compile(r"Image Name:\s*.*"),
        re.compile(r"Load Address:\s*0x[0-9a-f]+", re.I),
    ],
    "linux": [
        re.compile(r"Linux version\s+\S+.*"),
        re.compile(r"Starting kernel \.\.\."),
        re.compile(r"Kernel panic - not syncing.*", re.I),
        re.compile(r"Unable to handle kernel.*", re.I),
        re.compile(r"VFS:.*", re.I),
        re.compile(r"init:.*not found", re.I),
    ],
    "nand": [
        re.compile(r"bad block.*", re.I),
        re.compile(r"nand.*(error|fail|timeout).*", re.I),
        re.compile(r"ECC.*", re.I),
        re.compile(r"NAND ID.*", re.I),
        re.compile(r"Device not found.*", re.I),
    ],
    "ubi": [
        re.compile(r"ubi0:.*", re.I),
        re.compile(r"UBI (error|warning).*", re.I),
        re.compile(r"UBIFS.*(error|recovery|mount).*", re.I),
        re.compile(r"mount_root.*", re.I),
        re.compile(r"Unable to mount.*", re.I),
        re.compile(r"No filesystem.*", re.I),
    ],
    "watchdog_reset": [
        re.compile(r"watchdog.*", re.I),
        re.compile(r"WDT.*", re.I),
        re.compile(r"(software|system|hard) reset.*", re.I),
        re.compile(r"Rebooting in \d+ seconds.*", re.I),
        re.compile(r"Restarting system.*", re.I),
    ],
    "network": [
        re.compile(r"mt7530.*", re.I),
        re.compile(r"(eth0|eth1|gsw|switch).*(link|up|down|init).*", re.I),
        re.compile(r"PHY.*(link|up|down).*", re.I),
        re.compile(r"DHCP.*", re.I),
        re.compile(r"br-lan.*", re.I),
    ],
    "wireless": [
        re.compile(r"mt7603e.*", re.I),
        re.compile(r"mt7612e?.*", re.I),
        re.compile(r"mt76x[0-9].*", re.I),
        re.compile(r"(wlan|ra0|rai0|802\.11).*", re.I),
    ],
}

FLAGS = ("flag_try_sys1_failed", "flag_try_sys2_failed",
         "flag_last_success", "flag_boot_success", "flag_boot_rootfs")
FLAG_RE = re.compile(
    r"(flag_try_sys1_failed|flag_try_sys2_failed|flag_last_success|"
    r"flag_boot_success|flag_boot_rootfs)\s*[:=]\s*([0-9a-zA-Z]+)",
    re.I)
BOOT_RE = re.compile(r"Booting System\s*([12])", re.I)
CRC_RE = re.compile(r"Verifying kernel([12]) uImage CRC(?:,\s*addr:\s*(0x[0-9a-fA-F]+))?", re.I)
CRC_FAIL_RE = re.compile(r"Bad Magic Number|Bad Header Checksum|Bad Data CRC|"
                         r"Verifying Checksum\s*\.*\s*(?:FAILED|Bad)", re.I)
PANIC_RE = re.compile(r"Kernel panic|Unable to handle kernel", re.I)
UBI_ERROR_RE = re.compile(r"UBI (?:error|warning)|UBIFS.*(?:error)|"
                          r"Unable to mount|VFS: Cannot open root", re.I)


def read_input(path: Path) -> str:
    data = path.read_bytes()
    if path.suffix.lower() in (".bin", ".raw"):
        return data.decode("latin-1")
    for enc in ("utf-8", "gb18030", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1", "replace")


def analyze(text: str) -> dict:
    lines = text.splitlines()
    sections: dict[str, list[dict]] = {}
    for name, patterns in PATTERNS.items():
        hits = []
        for i, line in enumerate(lines, 1):
            for pat in patterns:
                if pat.search(line):
                    hits.append({"line": i, "text": line.rstrip()[:300]})
                    break
        sections[name] = hits

    facts: dict[str, object] = {}

    # All Booting System events, in file order. The last line wins.
    boot_events = []
    for i, line in enumerate(lines, 1):
        m = BOOT_RE.search(line)
        if m:
            boot_events.append({"line": i, "system": int(m.group(1))})
    facts["boot_system_events"] = boot_events
    facts["boot_sequence"] = [e["system"] for e in boot_events]
    if boot_events:
        last = boot_events[-1]
        facts["last_boot_system"] = last["system"]
        facts["last_boot_system_line"] = last["line"]
    else:
        facts["last_boot_system"] = None
        facts["last_boot_system_line"] = None

    # CRC lines: collect U-Boot kernel number and optional address.
    crc_events = []
    for i, line in enumerate(lines, 1):
        m = CRC_RE.search(line)
        if m:
            k = int(m.group(1))
            addr = int(m.group(2), 16) if m.group(2) else None
            if addr == 0x200000:
                system = 1
                basis = "address 0x200000"
            elif addr == 0x600000:
                system = 2
                basis = "address 0x600000"
            else:
                system = k
                basis = "naming convention (kernel1->System 1, kernel2->System 2), no address"
            crc_events.append({"line": i, "kernel_number": k, "addr": m.group(2),
                               "system": system, "mapping_basis": basis,
                               "text": line.strip()[:200]})
    facts["crc_checks"] = crc_events

    # All flag occurrences. Never present a single one as "current".
    flag_events: dict[str, list[dict]] = {f: [] for f in FLAGS}
    for i, line in enumerate(lines, 1):
        for m in FLAG_RE.finditer(line):
            name = m.group(1).lower()
            if name in flag_events:
                flag_events[name].append({"line": i, "value": m.group(2)})
    facts["flag_occurrences"] = flag_events
    facts["flag_last_values"] = {
        name: (evs[-1]["value"] if evs else None) for name, evs in flag_events.items()
    }

    facts["crc_error_count"] = sum(1 for l in lines if CRC_FAIL_RE.search(l))
    facts["panic_count"] = sum(1 for l in lines if PANIC_RE.search(l))
    facts["ubi_error_count"] = sum(1 for l in lines if UBI_ERROR_RE.search(l))
    facts["panic_seen"] = facts["panic_count"] > 0

    m = re.search(r"U-Boot\s+([\d.]+)\s*\(([^)]*)\)", text)
    if m:
        facts["uboot_version"] = f"U-Boot {m.group(1)} ({m.group(2)})"
    m = re.search(r"Ralink UBoot Version:\s*(\S+)", text)
    if m:
        facts["ralink_uboot_version"] = m.group(1)
    m = re.search(r"Linux version\s+(\S+)", text)
    if m:
        facts["linux_version"] = m.group(1)

    cycles = max(len(re.findall(r"Ralink UBoot Version", text)),
                 len(re.findall(r"U-Boot\s+1\.1\.3", text)))
    facts["uboot_banner_count"] = cycles

    return {"facts": facts, "sections": sections, "line_count": len(lines)}


def render(report: dict, source: Path) -> str:
    facts = report["facts"]
    out = [
        "# UART Log Analysis",
        "",
        f"- Source: `{source}`",
        f"- Lines: {report['line_count']}",
        f"- Generated: {datetime.now().isoformat(timespec='seconds')}",
        "- This is a keyword/line report only. It does not choose a recovery action.",
        "",
        "## Key facts observed",
        "",
    ]
    if facts.get("uboot_version"):
        out.append(f"- U-Boot: `{facts['uboot_version']}`")
    if facts.get("ralink_uboot_version"):
        out.append(f"- Ralink UBoot: `{facts['ralink_uboot_version']}`")
    if facts.get("linux_version"):
        out.append(f"- Linux version: `{facts['linux_version']}`")

    boot_events = facts.get("boot_system_events", [])
    if boot_events:
        out.append(f"- Booting System events, in file order: "
                   + ", ".join(f"L{e['line']}=System {e['system']}" for e in boot_events))
        out.append(f"- **Last observed boot: System {facts['last_boot_system']} "
                   f"(line {facts['last_boot_system_line']})**")
    else:
        out.append("- Booting System events: **none found**")

    out.append(f"- U-Boot banner occurrences: **{facts.get('uboot_banner_count', 0)}**"
               + (" (2+ suggests a boot loop)" if facts.get("uboot_banner_count", 0) >= 2 else ""))
    out.append(f"- CRC error lines: **{facts.get('crc_error_count', 0)}**")
    out.append(f"- Kernel panic / oops lines: **{facts.get('panic_count', 0)}**")
    out.append(f"- UBI/VFS mount error lines: **{facts.get('ubi_error_count', 0)}**")
    out.append("")

    crc_events = facts.get("crc_checks", [])
    if crc_events:
        out.append("## U-Boot CRC checks and system mapping")
        out.append("")
        out.append("| Line | U-Boot name | Address | Mapped system | Basis |")
        out.append("|---:|---|---|---|---|")
        for e in crc_events:
            out.append(f"| {e['line']} | kernel{e['kernel_number']} | "
                       f"{e['addr'] or '?'} | System {e['system']} | {e['mapping_basis']} |")
        out.append("")
        out.append("Note: U-Boot's `kernel1`/`kernel2` are image-slot names, not the "
                   "Linux partition labels `kernel0`/`kernel1`.")
        out.append("")

    flag_events = facts.get("flag_occurrences", {})
    printed = {k: v for k, v in flag_events.items() if v}
    out.append("## Boot flag occurrences")
    out.append("")
    if not printed:
        out.append("- **No boot flag values printed in this log.** Do not guess them.")
    else:
        out.append("These are values printed at specific lines. Unless they came from a "
                   "single `printenv` in the current boot session and no further reboot "
                   "occurred, they are **not** the router's current values.")
        out.append("")
        for name, evs in printed.items():
            vals = ", ".join(f"L{e['line']}={e['value']}" for e in evs)
            out.append(f"- `{name}`: {vals} (last occurrence: `{evs[-1]['value']}`)")
    out.append("")

    for name, hits in report["sections"].items():
        out.append(f"## {name} ({len(hits)})")
        out.append("")
        if not hits:
            out.append("(no match)")
        else:
            for h in hits[:200]:
                out.append(f"- L{h['line']}: `{h['text']}`")
            if len(hits) > 200:
                out.append(f"- ... {len(hits) - 200} more match(es), see raw log")
        out.append("")
    return "\n".join(out)


def main() -> int:
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="Analyze an R3G UART log (read-only)")
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", default="")
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.is_file():
        print(f"Input not found: {src}")
        return 2

    text = read_input(src)
    report = analyze(text)
    md = render(report, src)

    out = Path(args.out) if args.out else src.with_name(src.stem + "_analysis.md")
    out.write_text(md, encoding="utf-8")
    print(md)
    print(f"\nMarkdown report: {out}")

    if args.json:
        jp = Path(args.json)
        jp.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"JSON report: {jp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
