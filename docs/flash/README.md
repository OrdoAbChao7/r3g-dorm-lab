# Flash, backup and NAS notes

These notes cover the stock-router phase. Read [SECURITY.md](../../SECURITY.md)
and keep a full backup before any write.

## Unlock the stock shell

[docs/flash/UNLOCK_SSH.md](UNLOCK_SSH.md) describes the OpenWRTInvasion path on
stock 2.28.24. The wrapper is `router/flash/unlock_ssh.ps1`. The router admin
password is typed locally; it is not stored in the repository.

## Full NAND backup

`router/flash/backup_stream.py` streams `/dev/mtd0` over the LAN to the PC:

```bash
python -I .\router\flash\backup_stream.py --pc-ip 192.168.31.100 --out .\backups\r3g-stock-full.bin
```

The script prompts for the router password if `--password` is omitted. After the
image is written:

1. compute SHA-256;
2. save a partition manifest;
3. copy to a second physical disk;
4. verify both copies;
5. never modify the source image.

A single copy on one disk is not a recovery plan. The R3G has 128 MiB NAND and
12 stock partitions; record the partition table before writing.

## Verify downloaded firmware

`router/flash/verify_firmware.ps1` checks SHA-256, file size, uImage magic for
kernel1 and UBI magic for rootfs0. Place images in `router/firmware/` or pass
`-FirmwareDir`.

```powershell
powershell -ExecutionPolicy Bypass -File .\router\flash\verify_firmware.ps1 -FirmwareDir .\router\firmware -VerifyBackups
```

## USB recovery and NAS

[USB_RECOVERY_GUIDE.md](USB_RECOVERY_GUIDE.md) covers the stock-system USB
recovery media and its limits. [NAS_ARIA2_DEPLOY.md](NAS_ARIA2_DEPLOY.md) is the
Samba/Aria2 plan; it is optional and not needed for the DNS hub.

## Stop conditions

- No full backup, or only one physical copy: stop.
- No root shell and no UART: stop; do not guess an IP or switch Wi-Fi.
- `mtd verify` success: still not permission to write the other half.
- U-Boot menu 2 / 7 / 9: not a recovery path.
