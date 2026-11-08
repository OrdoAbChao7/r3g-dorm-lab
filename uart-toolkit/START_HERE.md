# START HERE — first UART session

This is the short path for the first read-only session. Read
[../SECURITY.md](../SECURITY.md) and [README.md](README.md) first.

## 1. Confirm the adapter

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\detect_com.ps1
```

The port must be `Present=True`, `Status=OK`, and match the expected VID/PID
(CH340 is `1A86:7523`). Phantom entries are not usable. Do not hardcode the COM
number.

## 2. Wire only RX and GND

```text
R3G J4 TX  -> CH340 RXD
R3G J4 GND -> CH340 GND
```

Do not connect VCC. Do not connect CH340 TXD. Do not connect J4-1. The router
uses its own 12 V supply.

## 3. Power the router first, then open the probe

The CH340 may re-enumerate when the router's 12 V supply comes up. If the probe
is already open, it can receive `00 00` and fail with
`ClearCommError failed (PermissionError(13))`. Power the router into its boot
loop first, then start the capture.

## 4. Listen only

```bash
python -I .\scripts\uart_capture.py --port COMx --duration 180
```

The capture tool has no transmit path. Do not press keys and do not enter the
U-Boot menu in this session.

## 5. Analyze

```bash
python -I .\scripts\uart_analyze.py .\logs\r3g_uart_YYYYMMDD-HHMMSS.bin
```

Record: U-Boot version, selected system, kernel name/CRC, UBI attach error,
panic, and reset interval. The raw `.log` may contain identifiers; do not publish
it. Use a redacted excerpt.

## 6. Stop before writing

The next stages are separate decisions:

- **L4**: send only `4`, Enter, `printenv`, Enter (11 bytes) with
  `uart_l4_readonly_probe.py`.
- **L5**: load an initramfs over TFTP into RAM; no NAND write.
- **L7**: install OpenWrt with `sysupgrade -n`; this erases the UBI partition.

Do not run `saveenv`, `setenv`, `reset`, `boot`, `mtd`, `nand`, or menu 2/7/9.
Do not write a bootloader. If the log does not prove the failure point, stop and
collect more read-only evidence.
