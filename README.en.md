# R3G Dorm Hub

English | [简体中文](README.md)

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![OpenWrt 25.12.6](https://img.shields.io/badge/OpenWrt-25.12.6-00b5e2)
![mihomo 1.19.33](https://img.shields.io/badge/mihomo-1.19.33-4b5563)
![Release](https://img.shields.io/github/v/release/OrdoAbChao7/r3g-dorm-lab)

A reproducible **Xiaomi Mi Router 3G v1** dorm network hub: UART recovery,
OpenWrt 25.12.6, mihomo fake-IP routing, anti-AD filtering, DNS failover,
Wake-on-LAN and Tailscale.

Most write-ups stop at `sysupgrade successful`. This one keeps the evidence: the
half-flashed dual-slot firmware, the UBI `PEB 256` failure, the 11-byte UART
probe, the ESP32 PSRAM stub, a 43-second whole-house DNS outage drill, and the
later decision to collapse the DNS chain from ESP32 into mihomo. The scripts and
sanitized logs are here so you can reproduce the path — or avoid the traps.

## What you get

One R3G turns a dorm network into:

- every device that joins the Wi-Fi gets a global proxy: domestic traffic goes
  direct, foreign traffic goes through the proxy, and Windows no longer needs
  manual proxy switching;
- ad and tracking domains are rejected in mihomo's rule layer, with no
  per-device app;
- if mihomo's DNS fails, dnsmasq falls back to the campus resolver and switches
  back automatically;
- you can wake the PC from outside the dorm through a Tailscale-reachable WoL
  page;
- after a router power cycle, Wi-Fi, WAN, DNS and the proxy recover
  automatically;
- an ESP32-S3 can stay as an independent DNS fallback, but it is no longer in
  the client DNS chain.

```text
phone / tablet / PC / TV
        │  Wi-Fi / LAN
        ▼
   R3G (DHCP DNS = 192.168.1.1)
        ├─ ad / tracking domains ──> mihomo anti-AD REJECT
        ├─ CN domains ──> direct
        └─ foreign domains ──> proxy
```

```text
$ nslookup pagead2.googlesyndication.com 192.168.1.1
Name:    pagead2.googlesyndication.com
Address: 198.18.0.x        # fake-IP; the actual block is at connection time
$ curl -I http://pagead2.googlesyndication.com
curl: (52) Empty reply from server

$ nslookup www.baidu.com 192.168.1.1
Name:    www.baidu.com
Address: 198.18.0.83
```

| Scenario | Without this setup | With it |
|---|---|---|
| Phone / tablet ads | an ad-blocker app on every device | rejected at connection time once on the Wi-Fi |
| Windows proxy | manual Clash / system proxy toggling | follows the current network automatically |
| Roommate devices | each device configured by hand | DHCP hands out `192.168.1.1` |
| Away from the dorm | a powered-off PC stays off | Tailscale + WoL page |
| mihomo DNS failure | DNS for the whole room stops | watchdog falls back to the campus resolver |
| Router reboot | manual checks | Wi-Fi / WAN / DNS / proxy recover |

> This is the target state. DNS/rule filtering covers domain-level ads only;
> same-domain feed ads, in-app ads, DoH and Android Private DNS are not
> guaranteed. Real WoL wake and phone-side Tailscale are still pending. See
> [Verified status](#verified-status) for what was measured.

## Contents

- [What you get](#what-you-get)
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
      ├─ Wi-Fi 2.4/5 + LAN ── phone / PC / IoT
      ├─ dnsmasq :53 ── 127.0.0.1#1053 ── mihomo DNS (fake-IP)
      │                        ├─ RULE-SET,antiad,REJECT
      │                        ├─ GEOIP,CN,DIRECT
      │                        └─ MATCH,PROXY
      ├─ mihomo TUN + fake-IP ── proxy / direct
      ├─ dns_failover_mihomo.sh ── campus DNS fallback
      ├─ Tailscale ── remote access
      └─ ESP32-S3 192.168.1.53 (off-chain, optional fallback)
```

The DNS chain is the part that matters: clients only know the router; dnsmasq
hands queries to mihomo's dedicated DNS listener on `1053`; mihomo returns a
fake-IP and applies the anti-AD rule at connection time; allowed traffic is then
split by `GEOIP,CN` and `MATCH`.

Why not `dnsmasq → ESP32 → mihomo`? That was the earlier chain, and it worked
with 211,465 Hagezi Pro domains. But the ESP32 was a single point: an unplug
drill caused a 43.1-second whole-house DNS outage. Moving filtering into mihomo
removed one hop, grew the list from 103k to 177k, and made daily updates
hot-reloadable without a restart. The ESP32 is still kept as an independent
device; direct `.53` queries can serve as a fallback.

Failure modes are in [docs/architecture.md](docs/architecture.md) and
[docs/troubleshooting.md](docs/troubleshooting.md).

## What's inside

| Path | What it is | Start here |
|---|---|---|
| [uart-toolkit/](uart-toolkit/) | Read-only capture, fixed `printenv` probe, TFTP initramfs, sysupgrade helpers | [README](uart-toolkit/README.md) |
| [router/](router/) | mihomo install/rollback, DNS failover, anti-AD refresh, WoL CGI | [README](router/README.md) |
| [esp32/](esp32/) | Patch, PlatformIO build, flash and DNS verification tools (optional fallback) | [README](esp32/README.md) |
| [windows/](windows/) | Dual-NIC setup, WoL sender/checker, proxy-mode scheduler | [README](windows/README.md) |
| [docs/](docs/) | Reproduction guide, architecture, troubleshooting, sanitized evidence | [reproduction.md](docs/reproduction.md) |
| [docs/blog/](docs/blog/) | Three long-form write-ups: rescue, DNS hub, retrospective | [retrospective.md](docs/blog/retrospective.md) |

## Quick start

1. Read [SECURITY.md](SECURITY.md) and [docs/reproduction.md](docs/reproduction.md).
2. **Back up before writing.** Follow
   [docs/flash/UNLOCK_SSH.md](docs/flash/UNLOCK_SSH.md) and use
   [router/flash/](router/flash/) to take a full NAND image.
3. If the router is already in a boot loop, start at
   [uart-toolkit/START_HERE.md](uart-toolkit/START_HERE.md).
4. Install OpenWrt with the sysupgrade path. The failure that made this
   necessary is documented in [docs/blog/uart-recovery.md](docs/blog/uart-recovery.md).
5. Configure mihomo and the DNS chain: [router/README.md](router/README.md).
6. Optional: keep the ESP32 as an independent DNS fallback, see
   [esp32/README.md](esp32/README.md).
7. Add remote power-on: [router/wol/](router/wol/) and
   [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md).
8. On Windows, use [windows/proxy_setup/](windows/proxy_setup/) so the local
   proxy follows the current network.
9. Run the [acceptance checklist](docs/reproduction.md#10-acceptance-checklist).

## Verified status

| Item | Status |
|---|---|
| R3G v1 UART capture | Verified on hardware: 49,392 B passive log, U-Boot 1.1.3, System 2, UBI PEB 256 error |
| L4 `printenv` | Verified: 11 bytes transmitted, boot flags captured |
| L5 TFTP initramfs | Verified: 7,607,308 B loaded into RAM, no NAND write |
| L7 OpenWrt install | Verified: `sysupgrade -n`, `ubiformat` 940 PEB, first boot and power-cycle boot |
| mihomo global proxy | Verified: TUN + fake-IP, 4 nodes, manual `PROXY` + `AUTO` fallback |
| anti-AD filtering | Verified: 177,307 MRS rules, connection-layer `REJECT`, 4–7 s load |
| anti-AD daily refresh | Verified: `mihomo -t` + `PUT /providers/rules/antiad` hot reload, 204, zero restart |
| DNS failover | Verified by controlled drill: 1 failure switches to campus DNS, 3 successes switch back; real kill not rehearsed |
| NCSI direct | Verified: Windows probe endpoints 200, PC reports Internet |
| ESP32 DNS filtering | Historically verified: 211,465 domains, 2.1 s flash restore; now off-chain |
| WoL endpoint | Token rejection/acceptance verified; real wake not yet tested |
| Tailscale | Local-side `wol.html` reachable; phone-side external test pending |
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
- **Make the DNS chain explicit.** The client DNS is dnsmasq `:53`; its upstream
  is mihomo `127.0.0.1#1053`. If the ESP32 participates, it may only point at
  `1053`, never back at `192.168.1.1:53`.
- **Measure single points.** The ESP32 once caused a 43.1 s outage; after the
  migration mihomo DNS is the new single point, covered by
  `dns_failover_mihomo.sh`.
- **Update without restarting.** The daily anti-AD refresh runs `mihomo -t`,
  then hot-reloads the provider through the API; on failure the old MRS stays.
- **One proxy controller.** The router owns transparent proxying on its Wi-Fi;
  the Windows helper only enables Clash when the router path is absent.

## Safety

- Use **3.3 V TTL** for UART. Do not connect VCC or the suspected VCC pin.
- Do not write flash without a full backup, a second physical copy, and a
  tested recovery path.
- Keep router management on the LAN. Do not expose SSH, HTTP, the mihomo API or
  the WoL endpoint to the WAN.
- **Set a non-empty `secret` on the mihomo control API.** `secret: ""` lets any
  client on the same LAN control the API without authentication; LAN-only
  binding is not a substitute for authentication.
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
│   ├── blog/                 # three long-form write-ups
│   ├── flash/                # unlock, USB recovery, NAS notes
│   └── link-diagnosis/       # NIC cross-test methodology
├── uart-toolkit/             # scripts, tests, wiring/decision-tree docs
├── router/                   # mihomo, DNS failover, anti-AD, WoL
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
| [docs/blog/dorm-hub.md](docs/blog/dorm-hub.md) | The DNS hub and reliability story (with historical architecture note) |
| [docs/blog/retrospective.md](docs/blog/retrospective.md) | Project retrospective: decisions, metrics, problems, next steps |
| [docs/evidence/](docs/evidence/) | Sanitized boot log, `printenv`, UBI and PSRAM evidence |
| [uart-toolkit/README.md](uart-toolkit/README.md) | What each UART tool does and how to self-test |
| [router/README.md](router/README.md) | mihomo, failover, anti-AD and WoL scripts |
| [esp32/README.md](esp32/README.md) | Patch, PSRAM build, flash and DNS verification |
| [windows/README.md](windows/README.md) | Proxy mode, WoL sender and dual-NIC helpers |

## Credits

- OpenWrt and the R3G device support
- mihomo / Clash.Meta
- Anti-AD and Hagezi DNS blocklists
- Garionhk/ESP32-AdBlocker-N16R8 (AGPL-3.0) for the experimental ESP32 firmware;
  [esp32/patches/](esp32/patches/) contains our patch under AGPL-3.0
- Tailscale
- OpenWRTInvasion (used for the initial stock-firmware shell)

See [NOTICE.md](NOTICE.md) for links and license notes.

## License

Original code and documentation: MIT. The patch under `esp32/patches/` is
distributed under AGPL-3.0 because it modifies an AGPL-3.0 project.
