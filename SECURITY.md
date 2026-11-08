# Security

## Scope

This repository contains scripts that can change router, ESP32 and Windows
network settings. Review every command before running it. The repository is a
reference implementation, not a turnkey installer.

## Secrets

No real credentials are included. The following are placeholders:

- `<repo-root>`, `<workspace>`, `COMx`
- `AA:BB:CC:DD:EE:FF` and similar MAC addresses
- `192.0.2.x`, `198.51.100.x`, `203.0.113.x` (documentation/test networks)
- `192.0.2.x` for campus DNS and `100.64.0.1` for a Tailscale example
- `ntfy.sh/<your-topic>`

If you fork this repository, keep it that way. Do not commit:

- Wi-Fi SSIDs/passwords, router admin passwords, root password hashes
- `secrets.h`, `config.json`, mihomo `secret:` values, subscription URLs
- Raw UART logs (they can contain SN, MAC, PSK and the admin hash)
- Device backups or firmware images

## Network exposure

- Keep SSH, LuCI, the mihomo control API and the WoL endpoint on the LAN.
- The WoL CGI uses a shared token in `/etc/wol.token` (mode 600). Treat it as a
  password; rotate it if it appears in a screenshot or log.
- The ESP32 web UI uses HTTP Basic Auth. Do not expose it to the WAN.
- If you use Tailscale, use an ACL that only allows the devices you need, and
  keep `--accept-dns=false --accept-routes=false` unless you have a reason.
- Do not expose the router's WAN address on port 22, 80, 9090 or the WoL port.

## Logs and screenshots

Before publishing a UART log, `printenv`, `dmesg`, LuCI screenshot or `nft`
dump, remove:

- serial number, MAC addresses, SSIDs, Wi-Fi PSK
- admin/root password hashes
- public/campus IP addresses and VPS endpoints
- tokens, subscription URLs and API secrets

The `docs/evidence/` files in this repository are deliberately shortened and
redacted.

## Reporting

If you find a security issue in the scripts, open a private security advisory on
GitHub or contact the repository owner. Do not open a public issue with a live
token or credential.
