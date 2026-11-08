# Architecture

## Hardware

| Part | Role |
|---|---|
| Xiaomi Mi Router 3G v1 | MT7621A, 128 MiB NAND, 256 MiB RAM, USB 3.0, dual-band Wi-Fi |
| CH340 USB-TTL (3.3 V) | UART console for U-Boot and Linux |
| ESP32-S3 N16R8 | 16 MB flash, 8 MB OPI PSRAM; DNS filter and blocklist cache |
| USB 2.5GbE NIC | Host-only wired management; optional |
| USB drive | NAS / Aria2 target; optional |
| Windows PC | Management, proxy client, WoL sender |

## Network plan

```text
                    Campus WAN (DHCP)
                           │
                    ┌──────┴──────┐
                    │  R3G v1     │
                    │  OpenWrt    │
                    │  25.12.6    │
                    └──┬───┬───┬──┘
                       │   │   │
             Wi-Fi 2.4/5│   │   └─ Tailscale (remote)
                       │   │
              ┌────────┘   └──────────┐
              │                       │
        phone / PC                ESP32-S3
        (DHCP DNS = .1)           .53:53
                                      │
                                      ▼
                              mihomo DNS :1053
                              fake-IP + TUN
```

### DNS chain

```text
client → dnsmasq 192.168.1.1:53 → ESP32 192.168.1.53:53
       → mihomo 192.168.1.1:1053 → upstream (campus / public)
```

Rules:

- Clients receive `192.168.1.1` via DHCP.
- dnsmasq uses `noresolv=1` and a single upstream: the ESP32.
- The ESP32 uses a **dedicated** upstream port (`1053`) on mihomo, never
  `192.168.1.1:53`; pointing it back at dnsmasq creates a loop.
- mihomo uses `198.18.0.1/16` fake-IP and `dns-hijack: any:53`; this is why a
  query sent to "campus DNS" from the LAN can still return `198.18.x`.

### Failure domains

| Component | If it fails | Mitigation |
|---|---|---|
| ESP32 | New DNS queries fail; measured 43.1 s outage after unplug | `dns_failover.sh` switches dnsmasq to campus DNS after 2 failures, switches back after 3 successes |
| mihomo | DNS/HTTP continue; only proxy and fake-IP are lost | No failover needed for DNS; restart restores proxy after ~5–10 s |
| dnsmasq | No LAN DNS/DHCP | Recover via LuCI/SSH/UART; keep a LAN management path |
| R3G | Whole LAN down | Keep a full NAND backup and a UART recovery path |
| Tailscale | Remote access lost; LAN unaffected | Local WoL / LAN management still works |

## Design constraints

- **MT7621 is the bottleneck.** Proxy throughput measured around 20 Mbps down
  and 10 Mbps up, while direct campus download reached 122 Mbps. The router is
  for browsing, phones and IoT; large downloads belong on the PC.
- **128 MiB NAND.** OpenWrt overlay is about 91.7 MiB before extras; LuCI took
  12.1 MiB / 160 packages. Plan package space.
- **No public IP.** WAN is campus DHCP. Remote access must go through Tailscale
  or another outbound tunnel; do not expose management ports.
- **Dual-slot stock firmware.** The R3G has kernel0/kernel1 and two rootfs
  slots. Writing only one half can produce a kernel/rootfs mismatch; see
  [docs/blog/uart-recovery.md](blog/uart-recovery.md).
- **DNS is a dependency chain.** Every hop must be explicit about who answers
  and which port is used; "the query returned the expected IP" is not enough.

## Repository boundaries

The public package excludes:

- full NAND backups and firmware images
- raw UART/`printenv` logs
- credentials, tokens and subscription URLs
- real MAC addresses, serial numbers and campus/VPS IPs
- upstream source trees (only a patch and links are included)

See [SECURITY.md](../SECURITY.md) and [NOTICE.md](../NOTICE.md).
