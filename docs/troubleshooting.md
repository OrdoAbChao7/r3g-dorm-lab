# Troubleshooting

The failures below are the ones that actually happened in this project. The
common thread: a command or a status can be "successful" at one layer while the
next layer is broken.

## Router and boot

### `mtd verify` succeeded, but the router does not boot

`mtd verify` only compares the partition bytes with the file. It does not check
that the kernel and rootfs are a matching bootable pair.

On the R3G, kernel0/kernel1 are two slots. The running 2.28.24 kernel matched
the 2019-04-03 kernel1 build, so the active slot was likely System 2. Replacing
only kernel1 created "OpenWrt kernel + non-matching rootfs". U-Boot still chose
System 2 because the uImage CRC was valid; the rootfs panic happened after
hand-off and did not set `flag_try_sys2_failed`.

**Do:** identify the active slot before writing; use the official sysupgrade
path; keep a full backup.

### Link is `Up` at 1 Gbps, but receive bytes stay 0

PHY negotiation is not a data path. In this project both the USB RTL8156 and the
built-in 2.5GbE port flapped while the router was resetting every second. The
USB NIC even disappeared from the bus (`CM_PROB_PHANTOM`).

**Do:** check RX bytes and DHCP, not just link speed. If the router may be in a
boot loop, use UART.

### `ping 192.168.31.1` replies, but the router is unreachable

`Find-NetRoute` showed the route going out of `WLAN 2` to the campus gateway, not
the local Ethernet port. A single ICMP reply from the wrong path is a false
positive.

**Do:** check `Find-NetRoute`, the interface index and the source address before
believing a ping.

### UBI: `bad image sequence number ... in PEB 256`

```text
ubi0 error: bad image sequence number 1856070410 in PEB 256, expected 887073040
ubi0 error: failed to attach mtd9, error -22
VFS: Cannot open root device "" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

The first 256 PEBs (32 MiB) had one UBI image sequence, the rest had another.
UBI refuses to attach when the sequence is inconsistent. The fix is to format the
whole UBI partition with `sysupgrade -n` / `ubiformat`, not to change boot flags.

**Do not:** assume the kernel is bad; the uImage CRC passed. Do not write a
bootloader or menu 2.

### U-Boot menu differs from the online guide

This unit showed `1,2,3,4,7,9`; some guides show `5/6`. Menu numbers are
build-specific. Menu 2 writes both kernel slots; 7/9 write the bootloader. They
are not recovery options in this project.

### CH340 disappears when the router powers on

At 12 V power-on the CH340 can re-enumerate; an open probe receives `00 00` and
then `ClearCommError failed (PermissionError(13))`.

**Do:** power the router into its boot loop first, then open the probe. Use a
direct motherboard USB port, not a hub.

### COM port changes every time

COM12/13/14 can be phantom records. Do not hardcode a port; run
`detect_com.ps1` before each session.

## OpenWrt

### LuCI returns 403

`403` with `x-luci-login-required: yes` is the normal unauthenticated response.
If the page is truly broken, check for a stale `uhttpd.main.lua_prefix` pointing
at a missing Lua SGI:

```sh
uci del uhttpd.main.lua_prefix
uci commit uhttpd
/etc/init.d/uhttpd restart
```

### `opkg` is missing

OpenWrt 25.12.6 on this target uses `apk`. Use `apk update` / `apk add`.
`apk add luci` was 12.1 MiB and 160 packages; plan the 91.7 MiB overlay.

## ESP32-S3

### Build and flash succeed, but DNS does not start

Logs:

```text
[blocklist] no PSRAM -- build with PSRAM=opi for an N16R8
[dns] no memory for the pending table or receive pool
```

`ps_malloc`/`ps_calloc` were compiled as 7-byte stubs returning NULL. The build
was missing `-DBOARD_HAS_PSRAM` (the release FQBN uses `PSRAM=opi`). Add the
define and rebuild from clean:

```bash
pio run -t clean
pio run
```

Expected after the fix: `arena 4.7 MB`, `restored 211,465 domains ... in 2128 ms`,
`[dns] serving`.

### PlatformIO fails under Git Bash

Git Bash injects `MSYSTEM=MINGW64`; pioarduino's `idf_tools.py` can reject the
toolchain. Build from native PowerShell and clear `MSYSTEM`.

## DNS and mihomo

### Queries to "campus DNS" return `198.18.x`

mihomo's `dns-hijack: any:53` plus nft DNAT intercepts DNS before it leaves the
LAN. The campus server did not answer. Do not conclude that the upstream is
poisoned; find out who answered.

### DNS loop

If the ESP32 upstream points at `192.168.1.1:53`, the chain becomes
`dnsmasq → ESP32 → dnsmasq`. Use mihomo's dedicated listener
`192.168.1.1:1053` and leave the secondary empty.

### Tailscale stays in `SYN_SENT`

Tailscale control-plane names were fake-IP'd. Add to mihomo's `fake-ip-filter`:

```text
+.tailscale.com
+.tailscale.io
+.ts.net
```

### ESP32 unplug causes a whole-house DNS outage

This is real: a 43.1 s outage was measured. `dns_failover.sh` switches dnsmasq to
the campus DNS after 2 failures and switches back after 3 successes. mihomo is
not a DNS single point; stopping it did not break DNS or HTTP in the drill.

### An ad still appears

DNS filtering is domain-level. Same-domain feed ads, in-app ads served from the
app's own domain, DoH, Android Private DNS and browser secure DNS can bypass it.
`doubleclick.net` not being blocked is not necessarily a failure: the list may
only contain subdomains. Use the ESP32 query log, not one ad, as the signal.

## Windows

### Double proxy or terminals ignoring the proxy

There are three layers: WinINET system proxy, environment variables, and Clash
Verge's own system proxy/TUN. The `proxy_setup` scripts manage WinINET and the
user environment variables and require Verge's system proxy/TUN to stay off.
`InternetSetOption(39/37)` is needed for browsers to notice a WinINET change;
environment variables only affect newly started processes.

### WoL sends but the PC does not wake

- The target must be wired to the same LAN; WoWLAN is a different path.
- Enable `Wake on Magic Packet` and `Shutdown Wake-On-Lan`.
- Disable Windows fast startup (`HiberbootEnabled=0`).
- A full power loss (unplugged PSU) cannot be woken by WoL.
- The endpoint may return `{"ok":true}` while the real wake is still untested;
  these are different claims.
