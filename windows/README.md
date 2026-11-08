# Windows helpers

These scripts run on the Windows PC, not on the router.

## `proxy_setup/` — WifiProxyMode

Keeps the local proxy in sync with the current network:

- On the router Wi-Fi (`R3G-OpenWrt-5G`), the router's transparent proxy is
  active. The script disables the Windows system proxy and removes
  `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`.
- On another network, if Clash is listening on `127.0.0.1:7897`, it enables the
  system proxy and sets the user environment variables.
- Otherwise it leaves a direct connection and clears proxy settings.

It runs from two scheduled tasks (one per minute, one on network events) and
stores state in `%LOCALAPPDATA%\WifiProxyMode\`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Notes:

- Keep Clash Verge's own "system proxy" and TUN **off**; the script manages the
  Windows proxy and expects the router or Clash to be the only proxy.
- The installation backs up the environment variables, git global proxy, WinINET
  settings and `verge.yaml` under `backup/` (gitignored).
- Environment variables only affect newly started processes. Open a new terminal
  after a network switch.
- Existing long-lived connections are not interrupted.

## WoL sender

`wol-send.ps1` sends a magic packet to a target MAC on a broadcast address:

```powershell
powershell -ExecutionPolicy Bypass -File .\wol-send.ps1 -Mac "AA-BB-CC-DD-EE-FF" -Broadcast 192.168.31.255
```

`wol-check.ps1` is a read-only evidence collector for the target PC: link state,
IP configuration, `powercfg /devicequery wake_armed`, `powercfg /lastwake`, and
recent Kernel-Power events.

WoL prerequisites on the target:

- wired NIC in the same LAN
- `Wake on Magic Packet` and `Shutdown Wake-On-Lan` enabled
- Windows fast startup disabled (`HiberbootEnabled=0`)
- BIOS/UEFI `Power On By PCI-E` enabled
- the PSU must not be fully unplugged

## `nic/` — dual-NIC and diagnostics

- `2_setup_dual_nic_and_nas.ps1`: sets the USB Ethernet adapter to a host-only
  address (no default gateway), maps the router Samba share, and can restore
  DHCP. It has Show/Apply/Rollback modes; start with the read-only view.
- `2_restore_network.ps1`: restores the network profile.
- `rollback_usb_nic.ps1`: reverts the USB NIC changes using a saved snapshot.
- `wol_capability_check.ps1`: read-only Wake-on-LAN capability check.
- `check_pxe_capability.ps1`: read-only PXE capability check (not used in the
  current build).

Run PowerShell as the normal user unless a script specifically needs admin.
Read the `-Show`/`-WhatIf` output before applying anything.
