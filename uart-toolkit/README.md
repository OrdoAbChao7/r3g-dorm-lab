# UART Recovery Toolkit — Xiaomi R3G v1

This is the UART toolkit used to diagnose and recover a Xiaomi Mi Router 3G v1
(MT7621A, 128 MiB NAND) that entered a 1-second boot loop after only `kernel1`
was replaced with an OpenWrt image.

The toolkit is intentionally **read-only first**. It can capture the boot log,
send a fixed `printenv` probe, load an initramfs into RAM over TFTP, and finally
install OpenWrt with `sysupgrade`. NAND writes are never implicit; each stage
has a separate confirmation flag or command.

## Safety

- Use **3.3 V TTL** only. Do not connect VCC or the suspected VCC pin (J4-1).
- First connection: **R3G TX -> CH340 RXD**, **R3G GND -> CH340 GND**. Do not
  connect CH340 TXD until you intentionally enter the L4 stage.
- Power the router **before** opening the serial probe. The CH340 can drop off
  the USB bus during the router's 12 V power-on transient.
- COM numbers change on every plug. Detect the port each time; never hardcode it.
- A raw UART log can contain serial number, MAC addresses, Wi-Fi credentials and
  the admin password hash. Do not publish raw logs.

## Workflow

| Stage | Tool | What it does |
|---|---|---|
| Detect | `scripts/detect_com.ps1` | Enumerates CH340/CP210x/FTDI, rejects phantom ports |
| Capture | `scripts/uart_capture.py` | 115200 8N1, listen-only, writes `.bin` / `.log` / `.meta.json` |
| Analyze | `scripts/uart_analyze.py` | U-Boot banner, boot slot, CRC, panic, UBI errors |
| L4 probe | `scripts/uart_l4_readonly_probe.py` | Sends exactly `4`, Enter, `printenv`, Enter (11 bytes) |
| TFTP | `scripts/tftp_server.py` | Read-only TFTP, whitelist + SHA-256 pin, refuses WRQ |
| L5 | `scripts/uart_l5_tftp_probe.py` | Loads an initramfs into RAM; no NAND write |
| L7 | `scripts/uart_l7a_transfer.py`, `scripts/uart_l7a_install.py` | Fixed `sysupgrade -n` path with explicit confirmation |
| Diagnose | `scripts/uart_readonly_diag.py` | Read-only UCI/network/package checks over UART |
| Verify | `scripts/verify_firmware.ps1` | SHA-256, uImage header/data CRC, UBI magic |
| Network | `scripts/set_wired_ip.ps1` | Show/Apply/Rollback a host-only wired address |

`tests/` contains offline self-tests. They do not open a serial port or touch
the router.

## Quick self-test

```bash
python -I tests/selftest_tftp.py
python -I tests/selftest_uart.py
python -I tests/selftest_no_pyserial.py
python -I tests/selftest_safety.py
python -I tests/selftest_nic.py
```

Expected: the TFTP/UART/safety suites print `PASS`; the NIC suite may report
`BLOCKED` on a non-admin shell or a disconnected adapter. That is expected.

## First real session

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\detect_com.ps1

python -I .\scripts\uart_capture.py --port COMx --duration 180
python -I .\scripts\uart_analyze.py .\logs\r3g_uart_YYYYMMDD-HHMMSS.bin
```

Do not send any bytes in the first session. If the log shows
`UBI error: cannot attach mtd9` and a 1-second reset loop, read
`docs/RECOVERY_DECISION_TREE_FINAL.md` before deciding on L4/L5/L7.

## Directory map

```text
uart-toolkit/
├── scripts/          # capture, analyze, probe, TFTP, install helpers
├── tests/            # offline self-tests + sample U-Boot log
├── docs/             # wiring, decision tree, install/restore notes
├── research/         # boot flag, NAND layout, U-Boot behavior notes
├── README.md         # this file
└── START_HERE.md     # short first-session checklist
```

## Notes

- The scripts were developed on Windows 11 with PowerShell 5.1 and Python 3.13.
  The UART capture path also works on Linux/macOS with `pyserial`.
- Some scripts contain placeholder paths (`<repo-root>`, `COMx`) and placeholder
  MAC addresses. Replace them with your own values before running.
- The U-Boot menu differs between R3G builds. This unit showed `1,2,3,4,7,9`;
  older guides mention `5/6`. Menu 2 and 7/9 are write paths and are not part of
  this toolkit's default workflow.
