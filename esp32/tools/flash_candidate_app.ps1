# Guarded app-only flash for the ESP32-S3 PSRAM-corrected candidate firmware.
# Hard rule: COM13 is the R3G CH340 UART and must never be flashed.
# This script writes only the application partition at 0x10000.
# It does NOT run erase-flash; NVS and the LittleFS blocklist snapshot are preserved.
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [string]$Image = "",
    [switch]$ConfirmFlash,
    [int]$Baud = 921600
)
$ErrorActionPreference = "Stop"
if (-not $Image) { $Image = (Join-Path $PSScriptRoot "..\firmware\candidate-psram\adblocker-v1.0.3-dnsport-psram.bin") }
$expectedSha = "8ed05c7d6bc047ad506d0752154d1b1c3b1f13326061fa77b4d826a94f58f132"
$expectedSize = 1306464

# 1. Port identity first: present, known adapter, never the R3G CH340.
$pnp = Get-PnpDevice -Class Ports -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match [regex]::Escape($Port) } | Select-Object -First 1
if (-not $pnp) { throw "Port $Port is not present." }
$m = [regex]::Match($pnp.InstanceId, 'VID[_&]([0-9A-Fa-f]{4})[&+]PID[_&]([0-9A-Fa-f]{4})')
if (-not $m.Success) { throw "Cannot read VID/PID for $Port ($($pnp.InstanceId))." }
$vidpid = ($m.Groups[1].Value + ":" + $m.Groups[2].Value).ToUpper()
"Port ${Port}: $($pnp.FriendlyName) [$vidpid]"
if ($vidpid -eq "1A86:7523" -or $pnp.FriendlyName -match "CH340") {
    throw "REFUSED: $Port is the R3G CH340 UART. Never flash the router."
}
$esp = @("303A:1001", "303A:4001", "1A86:55D3", "10C4:EA60", "0403:6001")
if ($esp -notcontains $vidpid) {
    throw "REFUSED: $vidpid is not a known ESP32 USB/JTAG or USB-serial adapter."
}

# 2. Image identity: exact SHA-256 and size of the approved candidate.
if (-not (Test-Path $Image)) { throw "Image not found: $Image" }
$size = (Get-Item $Image).Length
$actual = (Get-FileHash -Algorithm SHA256 -Path $Image).Hash.ToLower()
if ($size -ne $expectedSize) { throw "Unexpected image size: $size" }
if ($actual -ne $expectedSha) { throw "SHA256 mismatch: $actual" }
"Image OK: $(Split-Path $Image -Leaf) ($size B, SHA256 $actual)"

# 3. Read-only chip check before any write.
& python -m esptool --chip esp32s3 --port $Port flash-id
if ($LASTEXITCODE -ne 0) { throw "esptool flash-id failed; board not in download mode?" }

if (-not $ConfirmFlash) {
    "Dry run only. Re-run with -ConfirmFlash to write the app at 0x10000."
    exit 0
}

# 4. App-only write at 0x10000. No erase-flash. write-flash verifies the hash.
& python -m esptool --chip esp32s3 --port $Port --baud $Baud write-flash 0x10000 $Image
if ($LASTEXITCODE -ne 0) { throw "write-flash failed." }
"FLASH OK: app written at 0x10000; write hash verified; no erase-flash; NVS and LittleFS preserved."
