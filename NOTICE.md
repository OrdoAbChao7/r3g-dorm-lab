# NOTICE

This repository contains original scripts and documentation, plus a patch that
applies to an AGPL-3.0 upstream project. It does not vendor firmware binaries or
the upstream source tree.

## Upstream projects

| Project | Link | License / note |
|---|---|---|
| OpenWrt | https://openwrt.org/ | GPL-2.0; firmware images are not included |
| Xiaomi Mi Router 3G device page | https://openwrt.org/toh/xiaomi/mir3g | Device-specific install/recovery notes |
| Garionhk/ESP32-AdBlocker-N16R8 | https://github.com/Garionhk/ESP32-AdBlocker-N16R8 | AGPL-3.0; deployed firmware and source are upstream |
| mihomo (Clash.Meta) | https://github.com/MetaCubeX/mihomo | GPL-3.0; binary is not included |
| Hagezi DNS blocklists | https://github.com/hagezi/dns-blocklists | See upstream repository for the list license |
| Tailscale | https://tailscale.com/ | Client license per upstream |
| OpenWRTInvasion | https://github.com/acecilia/OpenWRTInvasion | See upstream repository; used only for the initial stock shell |
| PlatformIO / pioarduino | https://platformio.org/ | Build tooling |
| Python / pyserial | https://python.org/ / https://github.com/pyserial/pyserial | Runtime dependencies |

## Our patch

`esp32/patches/0001-configurable-plain-upstream.patch` modifies
Garionhk/ESP32-AdBlocker-N16R8. Because the upstream project is AGPL-3.0, the
patch is distributed under AGPL-3.0 as well. See
[`esp32/patches/LICENSE`](esp32/patches/LICENSE).

All other original code and documentation in this repository is MIT-licensed;
see [LICENSE](LICENSE).

## Security and privacy

Device backups, raw UART captures, Wi-Fi credentials, MAC addresses, serial
numbers and public/campus IP addresses are intentionally excluded. Placeholders
in the scripts are not real credentials. If you publish your own logs, redact
them first.
