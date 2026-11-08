# R3G Dorm Lab — reproducible reference

A Xiaomi Mi Router 3G v1 turned into a small dorm network hub:

- OpenWrt 25.12.6 on the router
- UART recovery after a half-flashed dual-slot firmware
- ESP32-S3 DNS filtering (211k domains) in front of mihomo
- mihomo fake-IP routing with DNS failover
- Wake-on-LAN from a token-protected web page
- Tailscale access from outside the LAN
- Windows proxy mode that follows the current network

This is the **public reproduction package**, distilled from a private lab
notebook. It contains scripts, sanitized evidence and step-by-step guides. It
does **not** contain device backups, firmware images, raw UART logs, credentials,
real MAC addresses, or campus/VPS IP addresses.

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

The important part is the DNS chain: clients only know the router, the router
forwards to the ESP32, the ESP32 applies the blocklist, and allowed queries go to
mihomo's dedicated DNS listener. Each hop is replaceable; the failure modes are
documented in [docs/troubleshooting.md](docs/troubleshooting.md).

## Modules

| Path | What it is |
|---|---|
| [uart-toolkit/](uart-toolkit/) | Read-only capture, fixed `printenv` probe, TFTP initramfs, sysupgrade helpers |
| [router/](router/) | mihomo install/rollback, DNS failover, blocklist refresh, WoL CGI |
| [esp32/](esp32/) | Patch, PlatformIO build, flash and DNS verification tools for the ESP32-S3 |
| [windows/](windows/) | Dual-NIC setup, WoL sender/checker, proxy-mode scheduler |
| [docs/](docs/) | Reproduction guide, architecture, troubleshooting, sanitized evidence |
| [docs/blog/](docs/blog/) | Two long-form write-ups: the UART rescue and the DNS hub |

## Quick start

1. Read [SECURITY.md](SECURITY.md) and [docs/reproduction.md](docs/reproduction.md).
2. **Back up before writing.** Follow [docs/flash/UNLOCK_SSH.md](docs/flash/UNLOCK_SSH.md)
   and use [router/flash/](router/flash/) to take a full NAND image.
3. If the router is already in a boot loop, start at
   [uart-toolkit/START_HERE.md](uart-toolkit/START_HERE.md).
4. Install OpenWrt with the sysupgrade path; see
   [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md) for the failure that
   made this necessary.
5. Configure the DNS chain: [router/README.md](router/README.md) and
   [esp32/README.md](esp32/README.md).
6. Add remote power-on: [router/wol/](router/wol/) and
   [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md).
7. On Windows, use [windows/proxy_setup/](windows/proxy_setup/) so the local
   proxy follows the current network.

## What was verified

| Item | Status |
|---|---|
| R3G v1 UART capture | Verified on hardware: 49,392 B passive log, U-Boot 1.1.3, System 2, UBI PEB 256 error |
| L4 `printenv` | Verified: 11 bytes transmitted, flags captured |
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

## Safety

- **Do not write flash without a full backup and a tested recovery path.** A
  `mtd verify` success only proves that the partition matches the file; it does
  not prove that the kernel and rootfs are a bootable pair.
- Use **3.3 V TTL** for UART. Do not connect VCC or the suspected VCC pin.
- Keep router management on the LAN. Do not expose SSH, HTTP, the mihomo API or
  the WoL endpoint to the WAN.
- Treat WoL tokens and DNS blocklist URLs as secrets; rotate them if they leak.
- Replace every placeholder (`<repo-root>`, `COMx`, `AA:BB:CC:DD:EE:FF`,
  `192.0.2.x`, `198.51.100.x`, `203.0.113.x`) with your own values.

## Repository map

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
