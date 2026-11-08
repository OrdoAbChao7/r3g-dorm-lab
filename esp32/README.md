# ESP32-S3 DNS filter

The deployed firmware is [Garionhk/ESP32-AdBlocker-N16R8](https://github.com/Garionhk/ESP32-AdBlocker-N16R8)
v1.0.3 (AGPL-3.0). This directory contains the patch, build configuration and
verification tools used to run it in front of mihomo.

## Why a patch

The upstream UI had a fixed plain-DNS port (53). In this network, mihomo uses
`dns-hijack: any:53`; pointing the ESP32 at `192.168.1.1:53` would loop back into
dnsmasq. The patch adds a configurable `dnsPort` for the two plain upstreams and
guards against using the device's own address as upstream. The local-name path
still uses port 53.

The patch is under AGPL-3.0; see [`patches/LICENSE`](patches/LICENSE).

## Build

```bash
git clone https://github.com/Garionhk/ESP32-AdBlocker-N16R8.git
cd ESP32-AdBlocker-N16R8
git checkout v1.0.3
git apply /path/to/r3g-dorm-lab/esp32/patches/0001-configurable-plain-upstream.patch
```

The build must enable PSRAM. The provided `build/platformio.ini` uses:

```ini
board_build.arduino.memory_type = qio_opi
build_flags = -DCORE_DEBUG_LEVEL=0 -DBOARD_HAS_PSRAM
```

Build from native PowerShell. `build/build_psram.ps1` clears `MSYSTEM`, runs
`pio run -t clean`, and rebuilds; Git Bash can re-inject `MSYSTEM=MINGW64` and
break pioarduino's toolchain setup.

If the boot log says:

```text
[blocklist] no PSRAM -- build with PSRAM=opi for an N16R8
[dns] no memory for the pending table or receive pool
```

the PSRAM branch was compiled as a stub. Add `-DBOARD_HAS_PSRAM`, clean, rebuild.
Expected after the fix: `arena 4.7 MB`, `restored 211,465 domains ... in 2128 ms`,
`[dns] serving`.

## Flash

For an update, write only the application partition; do not `erase-flash` unless
you intend to wipe NVS and the blocklist snapshot:

```bash
esptool --port COMx --baud 921600 write-flash 0x10000 adblocker-v1.0.3-app.bin
```

`tools/flash_candidate_app.ps1` and `tools/flash_adblocker.ps1` wrap the same
operation. Keep the ESP32 and the R3G UART on different COM ports; the scripts
should refuse the wrong adapter. The candidate helper pins the reference build's
SHA-256 and size; update `$expectedSha` and `$expectedSize` if you build your own
image.

## Verify

```bash
nslookup pagead2.googlesyndication.com 192.168.1.53
nslookup www.baidu.com 192.168.1.53
```

- blocked: `0.0.0.0` / `::`
- allowed: `198.18.x` (mihomo fake-IP)
- missing: NXDOMAIN

Then repeat through the router (`192.168.1.1`). The results should match.

`tools/dns_availability_probe.py` samples DNS every second and writes a CSV; it
was used for the 43.1 s outage drill. `tools/dns_probe.py`,
`tools/dns_probe_mihomo.py`, `tools/tcp_retest.py` and
`tools/verify_dns_1053.ps1` are the smaller checks.

## Notes

- Use a static LAN address (for example `192.168.1.53`) or a DHCP reservation.
- Set primary upstream to `192.168.1.1:1053`, secondary empty, DoT off if the
  campus network blocks 853.
- The ESP32 is the only true DNS single point; deploy `router/dns_failover.sh`.
- Firmware binaries are not included; build from upstream + patch.
