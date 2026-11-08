<#
.SYNOPSIS
    Verify the downloaded OpenWrt images against the official sha256sums.txt.

.DESCRIPTION
    Checks SHA-256, file size, uImage magic for kernel1 and UBI magic for
    rootfs0. Read-only. Exit code 0 only when every expected file passes.

.EXAMPLE
    .\verify_firmware.ps1
    .\verify_firmware.ps1 -FirmwareDir "<repo-root>\router\firmware"
#>

param(
    [string]$FirmwareDir = (Join-Path $PSScriptRoot "..\firmware")
)

$ErrorActionPreference = "Stop"
$dir = (Resolve-Path $FirmwareDir).Path
$sumsPath = Join-Path $dir "sha256sums.txt"

if (-not (Test-Path $sumsPath)) {
    Write-Error "找不到 $sumsPath"
    exit 2
}

$expected = @{}
foreach ($line in Get-Content $sumsPath) {
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
        $expected[$Matches[2].Trim()] = $Matches[1].ToLower()
    }
}

$targets = @(
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin",
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin",
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin",
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-initramfs-kernel.bin"
)

$failed = 0
$rows = @()

foreach ($name in $targets) {
    $path = Join-Path $dir $name
    if (-not (Test-Path $path)) {
        $rows += [pscustomobject]@{ File = $name; Size = "-"; SHA256 = "MISSING"; Result = "FAIL" }
        $failed++
        continue
    }

    $size = (Get-Item $path).Length
    $hash = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
    $ok = $expected.ContainsKey($name) -and $expected[$name] -eq $hash -and $size -gt 1MB

    $magicOk = $true
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $buf = New-Object byte[] 4
        $null = $fs.Read($buf, 0, 4)
        if ($name -match 'kernel1|initramfs') {
            $magicOk = ($buf[0] -eq 0x27 -and $buf[1] -eq 0x05 -and $buf[2] -eq 0x19 -and $buf[3] -eq 0x56)
        } elseif ($name -match 'rootfs0') {
            $magicOk = ([System.Text.Encoding]::ASCII.GetString($buf) -eq 'UBI#')
        } else {
            $magicOk = $true  # sysupgrade is a tar archive; verified by hash only
        }
    } finally { $fs.Close() }

    $result = if ($ok -and $magicOk) { "PASS" } else { "FAIL" }
    if ($result -eq "FAIL") { $failed++ }
    $rows += [pscustomobject]@{
        File = $name
        Size = $size
        SHA256 = $hash.Substring(0, 16) + "..."
        Result = $result + $(if ($magicOk) { "" } else { " (magic)" })
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($failed -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed file(s) FAILED" -ForegroundColor Red
    exit 1
}
