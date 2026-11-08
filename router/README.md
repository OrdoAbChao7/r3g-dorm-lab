# Router scripts

These scripts run on the R3G under OpenWrt 25.12.6 (root). They assume the
router already has LAN/WAN and SSH or UART access. Back up `/etc/config` and
`/etc/mihomo` before changing anything.

## mihomo

`install_router_proxy.sh` takes four files:

```sh
./install_router_proxy.sh <mihomo-binary> <config.yaml> <GeoIP.dat> ./files/mihomo.init
```

It verifies the binary and GeoIP hashes (edit them if you use a different
build), backs up `dhcp`, `firewall` and `/etc/mihomo`, installs `kmod-tun`,
points dnsmasq at `127.0.0.1:1053`, and starts mihomo.

Roll back with:

```sh
./rollback_router_proxy.sh /root/backups/router-proxy-YYYYmmdd-HHMMSS
```

`rollback_phase2_3.sh` is the earlier phase-specific rollback helper.

## DNS failover

`dns_failover.sh` is a watchdog for the ESP32 upstream:

- `FAILOVER_FALLBACK_1`, `FAILOVER_FALLBACK_2`: fallback servers (the defaults
  are documentation IPs; replace them)
- 2 consecutive failures switch to fallback
- 3 consecutive successes switch back
- state/log: `/www/dns_failover.log`
- manual: `sh dns_failover.sh force-primary|force-fallback|status`

Install it on cron (every minute) after testing manually.

## Blocklist refresh

`blocklist/update_blocklist.sh` downloads Hagezi Pro (or `BL_URL`), writes
`/www/blocklist.txt`, keeps `/www/blocklist.txt.bak`, and refills the ESP32's
snapshot source. Test with `blocklist/test_update_blocklist.sh` before deploying.

Typical cron entry (UTC; adjust to your timezone):

```text
40 18 * * * /usr/bin/update_blocklist.sh
```

Rollback: `sh update_blocklist.sh rollback`.

## mihomo drill

`mihomo_drill.sh` stops mihomo, probes DNS/HTTP, restarts it, and probes again.
It only stops the service; it does not change configuration. Use it to verify
that mihomo is not a DNS single point.

## Tailscale patches

`ts_fakeip_patch.sh` and `ts_route_exclude_patch.sh` are small helpers used to
add Tailscale names to mihomo's `fake-ip-filter` and to keep Tailscale traffic
out of the proxy path. Review the resulting config before applying.

## Wake-on-LAN

`wol/wol-pc.sh` sends magic packets with `etherwake`; `wol/wol.cgi` and
`wol/wol.html` provide a token-protected LAN page. Install paths and token setup
are in [docs/reproduction.md](../docs/reproduction.md#8-wake-on-lan-and-tailscale).

## Flash and backup helpers

`flash/unlock_ssh.ps1` wraps the stock-shell unlock; `flash/backup_stream.py`
streams a full NAND image to the PC; `flash/verify_firmware.ps1` checks image
hashes and uImage/UBI magic; `flash/nas_prepare_plan.sh` is a read-only NAS plan
printer. See [docs/flash/README.md](../docs/flash/README.md).

## Defaults

The scripts use documentation IPs (`192.0.2.x`, `198.51.100.x`, `203.0.113.x`)
and placeholder MACs. Replace them with your own. Do not expose the router
management plane or the mihomo API to the WAN.
