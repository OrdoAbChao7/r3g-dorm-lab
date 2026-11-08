# R3G Dorm Lab

[English](README.md) | [简体中文](README.zh-CN.md)

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![OpenWrt 25.12.6](https://img.shields.io/badge/OpenWrt-25.12.6-00b5e2)
![ESP32-S3 N16R8](https://img.shields.io/badge/ESP32--S3-N16R8-e7352c)
![Release](https://img.shields.io/github/v/release/OrdoAbChao7/r3g-dorm-lab)

A reproducible **Xiaomi Mi Router 3G v1** dorm network hub: UART recovery,
OpenWrt 25.12.6, an ESP32-S3 DNS filter, mihomo fake-IP routing, DNS failover,
Wake-on-LAN and Tailscale.

Most write-ups stop at `sysupgrade successful`. This one keeps the evidence: the
half-flashed dual-slot firmware, the UBI `PEB 256` failure, the 11-byte UART
probe, the ESP32 PSRAM stub, and the 43-second DNS outage drill. The scripts and
sanitized logs are here so you can reproduce the path — or avoid the traps.

## Contents

- [Architecture](#architecture)
- [What's inside](#whats-inside)
- [Quick start](#quick-start)
- [Verified status](#verified-status)
- [Design decisions](#design-decisions)
- [Safety](#safety)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)
- [Credits](#credits)
- [License](#license)

## Architecture

```text
Campus WAN (DHCP)
      │
   R3G v1 / OpenWrt 25.12.6
      ├─ Wi-Fi 2.4/5 + LAN ── phone / PC / ESP32-S3
      ├─ dnsmasq :53 ── ESP32 192.168.1.53:53 ── mihomo 192.168.1.1:1053
      ├─ mihomo TUN + fake-IP ── proxy / direct
      └─ Tailscale ── remote access
```

The DNS chain is the part that matters: clients only know the router, the router
forwards to the ESP32, the ESP32 applies the blocklist, and allowed queries go to
mihomo's dedicated DNS listener. Every hop is replaceable; the failure modes are
in [docs/troubleshooting.md](docs/troubleshooting.md).

## What's inside

| Path | What it is | Start here |
|---|---|---|
| [uart-toolkit/](uart-toolkit/) | Read-only capture, fixed `printenv` probe, TFTP initramfs, sysupgrade helpers | [README](uart-toolkit/README.md) |
| [router/](router/) | mihomo install/rollback, DNS failover, blocklist refresh, WoL CGI | [README](router/README.md) |
| [esp32/](esp32/) | Patch, PlatformIO build, flash and DNS verification tools | [README](esp32/README.md) |
| [windows/](windows/) | Dual-NIC setup, WoL sender/checker, proxy-mode scheduler | [README](windows/README.md) |
| [docs/](docs/) | Reproduction guide, architecture, troubleshooting, sanitized evidence | [reproduction.md](docs/reproduction.md) |
| [docs/blog/](docs/blog/) | Two long-form write-ups: the UART rescue and the DNS hub | [uart-recovery.md](docs/blog/uart-recovery.md) |

## Quick start

1. Read [SECURITY.md](SECURITY.md) and [docs/reproduction.md](docs/reproduction.md).
2. **Back up before writing.** Follow
   [docs/flash/UNLOCK_SSH.md](docs/flash/UNLOCK_SSH.md) and use
   [router/flash/](router/flash/) to take a full NAND image.
3. If the router is already in a boot loop, start at
   [uart-toolkit/START_HERE.md](uart-toolkit/START_HERE.md).
4. Install OpenWrt with the sysupgrade path. The failure that made this
   necessary is documented in [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md).
5. Configure the DNS chain: [router/README.md](router/README.md) and
   [esp32/README.md](esp32/README.md).
6. Add remote power-on: [router/wol/](router/wol/) and
   [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md).
7. On Windows, use [windows/proxy_setup/](windows/proxy_setup/) so the local
   proxy follows the current network.
8. Run the [acceptance checklist](docs/reproduction.md#10-acceptance-checklist).

## Verified status

| Item | Status |
|---|---|
| R3G v1 UART capture | Verified on hardware: 49,392 B passive log, U-Boot 1.1.3, System 2, UBI PEB 256 error |
| L4 `printenv` | Verified: 11 bytes transmitted, boot flags captured |
| L5 TFTP initramfs | Verified: 7,607,308 B loaded into RAM, no NAND write |
| L7 OpenWrt install | Verified: `sysupgrade -n`, `ubiformat` 940 PEB, first boot and power-cycle boot |
| ESP32 DNS filtering | Verified: 211,465 domains, 2.1 s flash restore, `0.0.0.0` / `::` for blocked names |
| DNS failover | Verified by drill: ESP32 unplug caused a 43.1 s outage; mihomo stop did not break DNS |
| WoL endpoint | Token rejection/acceptance verified; real wake not yet tested |
| Tailscale | LAN-side `wol.html` reachable; phone-side external test pending |
| Phone DoH / Private DNS | Not verified |
| Long-term stability | Observing |

The private notebook contains the full evidence chain, including raw logs that
are intentionally excluded here.

## Design decisions

- **Never flash half a dual-slot system.** R3G has kernel0/kernel1 and two
  rootfs slots. A valid `mtd verify` does not prove the pair boots.
- **`mtd verify`, link speed and ping are different layers.** 1 Gbps is PHY;
  a single ping can leave through the wrong interface.
- **UART first, writes last.** The L4 probe sends exactly 11 bytes; L5 loads
  initramfs into RAM; L7 is a separate, explicit `sysupgrade`.
- **Make the DNS chain explicit.** The ESP32 upstream is `192.168.1.1:1053`,
  never `192.168.1.1:53`; the latter creates a loop through dnsmasq.
- **Measure single points.** The ESP32 is the only true DNS single point;
  stopping mihomo did not break DNS or HTTP in the drill.
- **One proxy controller.** The router owns transparent proxying on its Wi-Fi;
  the Windows helper only enables Clash when the router path is absent.

## Safety

- Use **3.3 V TTL** for UART. Do not connect VCC or the suspected VCC pin.
- Do not write flash without a full backup, a second physical copy, and a
  tested recovery path.
- Keep router management on the LAN. Do not expose SSH, HTTP, the mihomo API or
  the WoL endpoint to the WAN.
- Treat WoL tokens and DNS blocklist URLs as secrets; rotate them if they leak.
- Replace every placeholder (`<repo-root>`, `COMx`, `AA:BB:CC:DD:EE:FF`,
  `192.0.2.x`, `198.51.100.x`, `203.0.113.x`) with your own values.
- Raw UART logs can contain SN, MAC, PSK and the admin hash. Redact before
  publishing.

## Repository layout

```text
.
├── docs/
│   ├── architecture.md
│   ├── reproduction.md
│   ├── troubleshooting.md
│   ├── evidence/             # sanitized boot log, flags, PSRAM logs
│   ├── blog/                 # the two long-form write-ups
│   ├── flash/                # unlock, USB recovery, NAS notes
│   └── link-diagnosis/       # NIC cross-test methodology
├── uart-toolkit/             # scripts, tests, wiring/decision-tree docs
├── router/                   # mihomo, DNS failover, blocklist, WoL
├── esp32/                    # patch, build, flash and DNS tools
├── windows/                  # proxy-mode, WoL, dual-NIC scripts
├── SECURITY.md
├── NOTICE.md
└── LICENSE
```

## Documentation

| Document | What it answers |
|---|---|
| [docs/reproduction.md](docs/reproduction.md) | The end-to-end path, from stock backup to acceptance |
| [docs/architecture.md](docs/architecture.md) | Components, data flow and failure domains |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause → fix table |
| [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md) | The long-form rescue story |
| [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md) | The DNS hub and reliability story |
| [docs/evidence/](docs/evidence/) | Sanitized boot log, `printenv`, UBI and PSRAM evidence |
| [uart-toolkit/README.md](uart-toolkit/README.md) | What each UART tool does and how to self-test |
| [router/README.md](router/README.md) | mihomo, failover, blocklist and WoL scripts |
| [esp32/README.md](esp32/README.md) | Patch, PSRAM build, flash and DNS verification |
| [windows/README.md](windows/README.md) | Proxy mode, WoL sender and dual-NIC helpers |

## Credits

- OpenWrt and the R3G device support
- Garionhk/ESP32-AdBlocker-N16R8 (AGPL-3.0) for the deployed ESP32 firmware;
  [esp32/patches/](esp32/patches/) contains our patch under AGPL-3.0
- mihomo / Clash.Meta
- Hagezi DNS blocklists
- Tailscale
- OpenWRTInvasion (used for the initial stock-firmware shell)

See [NOTICE.md](NOTICE.md) for links and license notes.

## License

Original code and documentation: MIT. The patch under `esp32/patches/` is
distributed under AGPL-3.0 because it modifies an AGPL-3.0 project.
