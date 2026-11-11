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

`dns_failover_mihomo.sh` is the current watchdog. It assumes dnsmasq's upstream
is mihomo on `127.0.0.1#1053`:

- primary: `127.0.0.1#1053` (mihomo DNS)
- fallback: `FAILOVER_FALLBACK_1` / `FAILOVER_FALLBACK_2` (set your campus
  resolvers; the defaults are documentation IPs)
- health check: mihomo API `/version` + `/dns/query`; one failed check is
  re-tested after 2 seconds
- 1 failed check switches to fallback; 3 consecutive healthy checks switch back
- only `dhcp.@dnsmasq[0].server` is changed and dnsmasq is reloaded; mihomo is
  never restarted
- state/log: `/tmp/dns_failover_mihomo.state`, `/tmp/dns_failover_mihomo.log`
- manual: `sh dns_failover_mihomo.sh status|force-primary|force-fallback`

Install it on cron (every minute) after testing manually.

`dns_failover.sh` is the older ESP32-upstream watchdog, kept for the historical
two-layer architecture. Do not run both.

## DNS upstream policy

The failover script assumes mihomo is dnsmasq's only upstream. Inside mihomo,
split the upstream by domain so foreign names are not resolved locally:

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

The `#PROXY` suffix is mandatory: a DoH request without it still leaves from the
local WAN. Validate with `mihomo -t`, hot-reload, and confirm the EDNS resolver
changes while domestic names still use the campus DNS. Full steps are in
[docs/reproduction.md](../docs/reproduction.md#dns-upstream-policy).

## Portal auto-login

`portal_autologin/` keeps the campus wired-portal session alive. It never posts
a login while a session is online; when the status endpoint reports no session
it logs in with the credentials from `/etc/portal/login.conf` (mode 600) and the
BRAS `nasId` from `/etc/portal/nas.conf`, then verifies the session. A captcha
answer stops it for 30 minutes. On the router, set `PORTAL_WAN_DEV=wan` and
`PORTAL_RECONNECT=1` so a "device IP offline" error can reconnect the WAN once
per 15 minutes. See [portal_autologin/README.md](portal_autologin/README.md).

## Blocklist refresh

`blocklist/update_chinese_lists.sh` is the current anti-AD refresher:

- downloads Anti-AD and Hagezi Light, validates size/count/HTML/drop
- rebuilds the merged domain list, adds `+.` prefixes, converts it to MRS with
  `mihomo convert-ruleset`
- validates with `mihomo -t`
- hot-reloads the provider through `PUT /providers/rules/antiad`; it does not
  restart mihomo
- keeps `.bak` files and restores the old MRS/YAML if validation fails
- typical cron entry (UTC; adjust to your timezone):

  ```text
  45 18 * * * /usr/bin/update_chinese_lists.sh
  ```

`blocklist/update_blocklist.sh` is the older Hagezi Pro updater for the ESP32
fallback path. Test with `blocklist/test_update_blocklist.sh` before deploying.

## mihomo drill

`mihomo_drill.sh` stops mihomo, probes DNS/HTTP, restarts it, and probes again.
It only stops the service; it does not change configuration. Use it to verify
that the DNS failover watchdog covers a mihomo outage.

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
