# Reproduction guide

This is the end-to-end path used on a Xiaomi Mi Router 3G v1. It assumes you
have physical access, a 3.3 V USB-TTL adapter, a 12 V power supply and a Windows
PC. Paths are relative to the repository root.

> Read [SECURITY.md](../SECURITY.md) first. Do not write flash without a full
> backup and a recovery path. `mtd verify` success is not a boot guarantee.

## 0. Prerequisites

| Item | Notes |
|---|---|
| R3G v1 | MT7621A, 128 MiB NAND, USB 3.0. Confirm the version before flashing |
| CH340/CP210x/FTDI 3.3 V adapter | 115200 8N1, no flow control |
| 12 V PSU | Use the router's own supply; do not power it from the adapter |
| USB drive | For a second full backup |
| Windows PC | PowerShell 5.1+, Python 3.11+, optional PlatformIO |
| OpenWrt 25.12.6 images | Verify SHA-256 against the official `sha256sums` |

Place downloaded firmware in `router/firmware/` if you use
`router/flash/verify_firmware.ps1`.

## 1. Back up the stock router

Follow [docs/flash/UNLOCK_SSH.md](flash/UNLOCK_SSH.md) for the stock-shell
unlock. Then take a full NAND image:

```powershell
powershell -ExecutionPolicy Bypass -File .\router\flash\unlock_ssh.ps1
python -I .\router\flash\backup_stream.py --pc-ip 192.168.31.100 --out .\backups\r3g-stock-full.bin
```

The script prompts for the router password; it does not ship a default. After
the image is written:

1. Compute SHA-256 and save a manifest.
2. Copy the image to a second physical disk.
3. Verify both copies.
4. Do not modify the source backup.

A single backup on one disk is not a recovery plan.

## 2. If the router is in a boot loop

The failure this repository is built around: only `kernel1` was replaced, U-Boot
kept selecting System 2, UBI could not attach, and the kernel panicked every
second. Do not write `rootfs0` blindly. Capture the boot log first:

```powershell
powershell -ExecutionPolicy Bypass -File .\uart-toolkit\scripts\detect_com.ps1
python -I .\uart-toolkit\scripts\uart_capture.py --port COMx --duration 180
python -I .\uart-toolkit\scripts\uart_analyze.py .\uart-toolkit\logs\r3g_uart_YYYYMMDD-HHMMSS.bin
```

Then follow [uart-toolkit/START_HERE.md](../uart-toolkit/START_HERE.md):

- L4: fixed `printenv` probe (11 bytes).
- L5: load an initramfs over TFTP into RAM; no NAND write.
- L7: `sysupgrade -n` after a second backup.

The actual failure signature is in
[docs/evidence/boot-log-ubi-panic.txt](evidence/boot-log-ubi-panic.txt) and
[docs/evidence/ubi-peb.txt](evidence/ubi-peb.txt).

## 3. Install OpenWrt

Do **not** repeat the half-flash. Use the official sysupgrade image and let
OpenWrt format the UBI partition:

```text
sysupgrade -n /tmp/fw.bin
```

Expected key lines:

```text
ubiformat: mtd9 (nand), size 123207680 bytes (117.5 MiB), 940 eraseblocks
ubi0: attached mtd9 ... good PEBs: 940, bad PEBs: 0
Volume ID 0, name "rootfs", 36 LEBs (4.3 MiB)
Volume ID 1, name "rootfs_data", 880 LEBs (106.5 MiB)
sysupgrade successful
```

After the first boot, verify persistence with a 12 V power cycle, not only a
soft reboot.

## 4. Post-install network

- LAN: `192.168.1.1/24`, DHCP on.
- WAN: DHCP (campus or upstream router).
- Wi-Fi: 2.4 GHz and 5 GHz, WPA2-PSK.
- LuCI: this image uses `apk`, not `opkg`.

```sh
apk update
apk add luci
```

If `/cgi-bin/luci/` returns 403 with `x-luci-login-required: yes`, that is the
normal unauthenticated response, not a broken LuCI. If the image carries a
stale `uhttpd.main.lua_prefix`, remove it:

```sh
uci del uhttpd.main.lua_prefix
uci commit uhttpd
/etc/init.d/uhttpd restart
```

### 4.1 Campus portal session

If the WAN is behind a captive portal, authenticate once from a device on the
R3G LAN (the portal binds the WAN IP/MAC). Before automating it, confirm the
portal type and the NAS ID:

```sh
# The real NAS ID is in the BRAS redirect URL, not /api/config default_nas.
# Example: acip=172.30.1.223&acname=WHUT-Bras-ME60-A&nasId=52
printf 'NAS_ID=52\n' > /etc/portal/nas.conf
chmod 600 /etc/portal/nas.conf
```

Deploy the helper (see [router/portal_autologin/README.md](../router/portal_autologin/README.md)):

```sh
cp router/portal_autologin/portal_autologin.sh /usr/bin/
cp router/portal_autologin/portal_set_credentials.sh /usr/bin/
chmod 755 /usr/bin/portal_autologin.sh /usr/bin/portal_set_credentials.sh
ssh -t root@192.168.1.1 /usr/bin/portal_set_credentials.sh   # interactive, mode-600 file
echo '*/3 * * * * /usr/bin/portal_autologin.sh run >/dev/null 2>&1' >> /etc/crontabs/root
```

The script exits without logging in while a session is online. If it reports
`设备IP不在线`, reconnect WAN once and re-check before retrying the login.

Also exclude the campus network from the proxy path:

```yaml
tun:
  route-exclude-address:
    - 172.30.0.0/12
rules:
  - IP-CIDR,172.30.0.0/12,DIRECT,no-resolve
  - DOMAIN-SUFFIX,whut.edu.cn,DIRECT
```

## 5. mihomo (optional proxy layer)

`router/install_router_proxy.sh` expects four inputs: the mihomo binary, a
config, a GeoIP file and the init script. Hashes are pinned in the script;
replace them if you use a different build.

```sh
./router/install_router_proxy.sh /path/to/mihomo /path/to/config.yaml /path/to/GeoIP.dat ./router/files/mihomo.init
```

The script backs up `dhcp`, `firewall` and `/etc/mihomo`, installs `kmod-tun`,
points dnsmasq at `127.0.0.1:1053`, and starts mihomo. Review the script before
running it. On MT7621, expect roughly 8–20 Mbps through a single VLESS/TLS
stream; direct campus downloads can reach 122 Mbps.

## 6. ESP32-S3 DNS filter (optional, off-chain)

The deployed firmware is Garionhk/ESP32-AdBlocker-N16R8 v1.0.3. This device is
**optional** and no longer in the client DNS chain; keep it only if you want an
independent fallback. Clone the upstream project at the v1.0.3 tag/commit, apply
the patch, and build:

```bash
git clone https://github.com/Garionhk/ESP32-AdBlocker-N16R8.git
cd ESP32-AdBlocker-N16R8
git checkout v1.0.3
git apply /path/to/r3g-dorm-lab/esp32/patches/0001-configurable-plain-upstream.patch
pio run -t clean
```

Use the provided `esp32/build/build_psram.ps1` or make sure the build defines
`-DBOARD_HAS_PSRAM` (the release FQBN equivalent is `PSRAM=opi`). Build from a
native PowerShell, not Git Bash; MSYS injects `MSYSTEM=MINGW64`, which can break
pioarduino's toolchain setup.

Flash only the application partition for an update:

```bash
esptool --port COMx --baud 921600 write-flash 0x10000 adblocker-v1.0.3-app.bin
```

If the log says `[blocklist] no PSRAM` or `[dns] no memory`, the build did not
enable PSRAM. Do not flash that image to a DNS-critical device.

Configure the ESP32 with a static LAN address (for example `192.168.1.53`),
primary upstream `192.168.1.1:1053`, secondary empty, DoT off if the campus
network blocks 853. Do **not** point dnsmasq at the ESP32 in the current
architecture; clients should use mihomo directly.

## 7. DNS chain, failover and anti-AD refresh

Point dnsmasq at mihomo's DNS listener:

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Do not point the ESP32 or any client back at `192.168.1.1:53` from inside
dnsmasq; that creates a loop. Use the mihomo DNS listener on `1053`.

### DNS upstream policy

Sending every name to the campus resolver leaks foreign names at the DNS layer.
Keep CN/private names local and resolve the rest through DoH over the proxy:

```yaml
dns:
  nameserver:
    - https://1.1.1.1/dns-query#PROXY
    - https://1.0.0.1/dns-query#PROXY
  nameserver-policy:
    "geosite:cn,private":
      - 202.114.x.x
      - 202.114.x.y
  proxy-server-nameserver:
    - 202.114.x.x
    - 202.114.x.y
```

`#PROXY` is part of the address. Without it the DoH request still leaves from
the local WAN and the resolver identity does not change. Validate with
`mihomo -t`, hot-reload, and confirm the EDNS resolver changes while domestic
sites still resolve through the campus DNS.

Install the DNS failover watchdog and the anti-AD refresh script:

```sh
cp router/dns_failover_mihomo.sh /usr/bin/dns_failover_mihomo.sh
cp router/blocklist/update_chinese_lists.sh /usr/bin/update_chinese_lists.sh
chmod 755 /usr/bin/dns_failover_mihomo.sh /usr/bin/update_chinese_lists.sh
```

`dns_failover_mihomo.sh` checks mihomo's API (`/version` and `/dns/query`), then
switches dnsmasq to the campus resolvers after one failed check and switches
back after three healthy checks. It only reloads dnsmasq; it never restarts
mihomo. Set `FAILOVER_FALLBACK_1` and `FAILOVER_FALLBACK_2` to your campus
resolvers (the defaults are documentation IPs).

The anti-AD updater downloads Anti-AD and Hagezi Light, merges them, converts the
list to MRS, validates the config, and hot-reloads the provider through the
mihomo API. Add cron entries:

```text
* * * * * /usr/bin/dns_failover_mihomo.sh run
45 18 * * * /usr/bin/update_chinese_lists.sh
```

The time above is UTC; adjust for your timezone. Keep the old `.mrs`/`.yaml`
files; the script restores them if validation fails.

## 8. Wake-on-LAN and Tailscale

Install the WoL scripts on the router:

```sh
cp router/wol/wol-pc.sh /usr/bin/wol-pc.sh
chmod 755 /usr/bin/wol-pc.sh
cp router/wol/wol.html /www/wol.html
cp router/wol/wol.cgi /www/cgi-bin/wol
chmod 755 /www/cgi-bin/wol
printf '%s\n' "$(head -c 16 /dev/urandom | hexdump -e '16/1 "%02x"')" > /etc/wol.token
chmod 600 /etc/wol.token
```

Put target MACs in `/etc/wol.macs`, one per line. The page posts to
`/cgi-bin/wol?k=<token>` and returns `unauthorized` or `{"ok":true}`.

Tailscale is optional:

```sh
tailscale up --accept-dns=false --accept-routes=false
```

Add a dedicated firewall zone for `tailscale0` (input ACCEPT, forward REJECT),
and add `+.tailscale.com`, `+.tailscale.io`, `+.ts.net` to mihomo's
`fake-ip-filter`, otherwise the control plane can be fake-IP'd and stuck in
`SYN_SENT`.

## 9. Windows proxy mode

`windows/proxy_setup/install.ps1` backs up the current proxy settings, removes
hard-coded proxy environment variables, disables Clash Verge's own system proxy,
registers two scheduled tasks, and runs the mode switch once. The switch probes a
random subdomain: a `198.18.0.0/15` answer means a router transparent proxy is
active, so the local system proxy is turned off; otherwise it falls back to
Clash on `127.0.0.1:7897`.

Run it from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\proxy_setup\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\proxy_setup\status.ps1
```

Rollback:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\proxy_setup\uninstall.ps1
```

This `WifiProxyMode` is the original per-network switch and is kept for
reference. If you adopt a single facade/dispatcher, apps only need the facade
port, internal ports live in one registry (`ports.json`), and the system proxy
has exactly one owner. See [docs/blog/operations.md](blog/operations.md).

## 10. Acceptance checklist

- [ ] `ping 192.168.1.1` has 0% loss.
- [ ] SSH 22 and HTTP 80 are reachable on the LAN.
- [ ] `nslookup pagead2.googlesyndication.com 192.168.1.1` returns a fake-IP
      (`198.18.x`), and `curl` to it is rejected at connection time.
- [ ] `nslookup www.baidu.com 192.168.1.1` returns a fake-IP (`198.18.x`).
- [ ] `dnsmasq` upstream is `127.0.0.1#1053`; `noresolv=1`.
- [ ] Stop mihomo DNS (or use the failover test hook): dnsmasq switches to campus
      DNS within about a minute; after three healthy checks it switches back.
- [ ] anti-AD refresh: `mihomo -t` passes, the provider hot-reloads with 204, and
      the process PID does not change.
- [ ] mihomo process restart: DNS failover covers the gap; proxy returns in ~5–10 s.
- [ ] Power-cycle the router: UBI attach, Wi-Fi, WAN and DNS recover.
- [ ] mihomo API: no secret returns 401; with the configured secret returns 200;
      port 9090 is not reachable from the WAN.
- [ ] DNS leak: the EDNS resolver is the proxy-side DoH resolver (Cloudflare in
      the reference deployment); domestic names still use the campus DNS.
- [ ] Portal: `portal_autologin.sh status` reports online; a controlled logout
      is recovered without posting a login while the session is online.
- [ ] WoL: wrong token rejected, correct token accepted (real wake if the target is wired).
- [ ] Tailscale: local `wol.html` reachable from the tailnet; phone test if needed.
- [ ] Windows: on the router Wi-Fi, the system proxy is off; on another Wi-Fi, Clash is used.
- [ ] If a PC facade is used: `curl -x http://127.0.0.1:17890
      https://www.gstatic.com/generate_204` returns 204, and the campus portal
      stays direct.

## 11. Do not

- Do not write only one half of a dual-slot firmware.
- Do not use U-Boot menu 2 or 7/9 as a recovery path.
- Do not write `rootfs0` without a proven root shell and a second backup.
- Do not expose SSH, LuCI, the mihomo API or WoL to the WAN.
- Do not leave the mihomo API `secret` empty on a shared LAN.
- Do not log in to the campus portal while a session is online; check status
  first. Do not store portal credentials outside a mode-600 file or DPAPI.
- Do not hardcode internal proxy ports in applications; give them one facade.
- Do not publish raw UART logs or `printenv` output.
- Do not treat `mtd verify`, a 1 Gbps link or a single ping as proof of a working
  boot.
