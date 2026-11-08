# Guarded ESP32-S3 flashing helper.
# Hard rule: the R3G UART is a CH340 (1A86:7523) and must never be flashed.
# Refuses any port whose VID:PID is not a known ESP32 USB/JTAG or USB-serial adapter.
param(
    [Parameter(Mandatory = $true)][string]$Port,
    [string]$Image = "",
    [switch]$ConfirmFlash,
    [int]$Baud = 921600
)
$ErrorActionPreference = "Stop"
$fwDir = (Join-Path $PSScriptRoot "..\firmware")

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

# 2. Pick the release image variant to match the connection.
if (-not $Image) {
    $Image = if ($vidpid -eq "303A:1001" -or $vidpid -eq "303A:4001") {
        Join-Path $fwDir "adblocker-v1.0.3-esp32s3-n16r8-usbcdc.bin"
    } else {
        Join-Path $fwDir "adblocker-v1.0.3-esp32s3-n16r8.bin"
    }
}
if (-not (Test-Path $Image)) { throw "Image not found: $Image" }
$name = Split-Path $Image -Leaf
$sumFile = Join-Path (Split-Path $Image) "SHA256SUMS.txt"
if (-not (Test-Path $sumFile)) { throw "SHA256SUMS.txt not found next to the image." }
$line = Select-String -Path $sumFile -Pattern ([regex]::Escape($name)) | Select-Object -First 1
if (-not $line) { throw "No checksum entry for $name" }
$expected = ($line.Line -split '\s+')[0].ToLower()
$actual = (Get-FileHash -Algorithm SHA256 -Path $Image).Hash.ToLower()
if ($actual -ne $expected) { throw "SHA256 mismatch for ${name}: $actual != $expected" }
"Image OK: $name (SHA256 $actual)"

# 3. Read-only chip check before anything destructive.
& python -m esptool --port $Port flash-id
if ($LASTEXITCODE -ne 0) { throw "esptool flash-id failed; board not in download mode?" }

if (-not $ConfirmFlash) {
    "Dry run only. Re-run with -ConfirmFlash to erase and write $name."
    exit 0
}

# 4. Erase and write the merged release image at 0x0, then verify.
& python -m esptool --port $Port --baud $Baud erase-flash
if ($LASTEXITCODE -ne 0) { throw "erase-flash failed." }
& python -m esptool --port $Port --baud $Baud write-flash 0x0 $Image
if ($LASTEXITCODE -ne 0) { throw "write-flash failed." }
# write-flash already verifies the written data ("Hash of data verified").
# A post-reset full-chip verify would fail by design: the freshly flashed
# firmware formats LittleFS on first boot, changing the spiffs region.
"FLASH OK: $name (write hash verified; full-chip verify skipped by design)"
