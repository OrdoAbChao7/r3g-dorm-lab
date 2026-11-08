<#
.SYNOPSIS
    Verify R3G v1 firmware images and stock NAND backups against pinned hashes.

.DESCRIPTION
    Read-only. Computes SHA-256 and checks image structure:
      * kernel1 / initramfs / tftp_stock kernels: uImage magic 27 05 19 56,
        load address 0x80001000, header CRC, data CRC, kernel name
      * rootfs0: UBI magic "UBI#", size <= 32 MiB
      * sysupgrade: tar archive, marked as upgrade-only (never first install)
    Rejects R3G v2 images on a v1 unit.
    Cross-checks tftp_stock/kernel0.bin and kernel1.bin against the external
    backup parts when that backup path exists. If it does not exist, the
    cross-check is explicitly reported as skipped, never as verified.
    Also verifies the full NAND backup and its 12 extracted partitions.

    Nothing is written, downloaded or flashed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\verify_firmware.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\verify_firmware.ps1 -VerifyBackups
#>

[CmdletBinding()]
param(
    [string]$FirmwareDir = "",
    [string]$BackupDir = (Join-Path $PSScriptRoot "..\..\backups"),
    [switch]$VerifyBackups,
    [switch]$AllowInitramfsMissing
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $FirmwareDir) { $FirmwareDir = Join-Path $scriptDir "..\firmware" }
$failed = 0
$rows = @()

# Pinned values: OpenWrt 25.12.6 official sha256sums (downloaded 2026-11-04),
# Xiaomi CDN stock firmware, and this unit's backup manifest.
$pin = @{
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-initramfs-kernel.bin" = @{
        Size = 7607308;  Hash = "8d58d8a14c72eacff0ea281d59a2cd319db811f86848459816f024194485c37e"; Type = "initramfs" }
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-kernel1.bin" = @{
        Size = 3331950;  Hash = "cc7b1d187e1f5f42429094c2242ebcb9e161e696b21b27841c1f97e2685ef30c"; Type = "kernel1" }
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-rootfs0.bin" = @{
        Size = 5636096;  Hash = "3bede8061525b69ec64edf4027121f1e099a8a3d2c67dd7370401e9bc9cfcdae"; Type = "rootfs0" }
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-squashfs-sysupgrade.bin" = @{
        Size = 7813734;  Hash = "78c15850ee6d41f23779c23ba73bad7e1b2b33690b9ad8d7e749027fe821d57b"; Type = "sysupgrade" }
    "miwifi_r3g_firmware_dbc3c_2.28.46.bin" = @{
        Size = 24482204; Hash = "4b2b45e1e6c2dcacb9ad2b741345414eb8ba4bb434d5932a6dbd7e7354b20432"; Type = "stock-oem" }
    "tftp_stock\kernel0.bin" = @{
        Size = 4194304; Hash = "ab58d7a35bb75c988aad53001d52ed3f3306d138e36be8e7de2067891f7c5db8"; Type = "stock-kernel" }
    "tftp_stock\kernel1.bin" = @{
        Size = 4194304; Hash = "ab893d6c0732dcea7f029fd3d7101b844ff9d2b2fc6114b24e908d466e3b6168"; Type = "stock-kernel" }
    # v2 images are pinned only so they can be explicitly rejected.
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-v2-initramfs-kernel.bin" = @{
        Size = 7455358;  Hash = "2c8d4735796d1661e5b300d4346cf1cebe248553c8571dd929e65b054537ff7d"; Type = "v2-reject" }
    "openwrt-25.12.6-ramips-mt7621-xiaomi_mi-router-3g-v2-squashfs-sysupgrade.bin" = @{
        Size = 7668321;  Hash = "ccb3768dbcddaf92c3f97c6cc6ee4586ea9d611d7d726e48a68d205658c5779e"; Type = "v2-reject" }
}

$backupPin = @{
    "r3g-stock-full-20261104.bin" = @{ Size = 133693440; Hash = "0d690a8f6c36f4d34e89c2f13675120a500e72c6ae430eafeba4e4572e0e555d" }
    "parts\Bootloader.bin" = @{ Size = 524288;    Hash = "bf3cc484be162285639a1790c712a4eead39498281d7c6b1006d4cc0201f8ea3" }
    "parts\Config.bin"     = @{ Size = 262144;    Hash = "0d572659579d55a7751880870e0861cf909b1f3b0b1685be54d01b94d44af786" }
    "parts\Bdata.bin"      = @{ Size = 262144;    Hash = "dd01e42d66c82a44d011b19c493a323a909bb0d7552370e03c03581d3f9ae432" }
    "parts\Factory.bin"    = @{ Size = 262144;    Hash = "20460d6b7f9c49b608a051e7e64176af5b1791bcf8646e9251a533351e5a45d1" }
    "parts\crash.bin"      = @{ Size = 262144;    Hash = "3b874d3ba46c638fc3094f8e92fb744ca974893873f8885f54e23760f9b6311b" }
    "parts\crash_syslog.bin" = @{ Size = 262144;  Hash = "3b874d3ba46c638fc3094f8e92fb744ca974893873f8885f54e23760f9b6311b" }
    "parts\reserved0.bin"  = @{ Size = 262144;    Hash = "3b874d3ba46c638fc3094f8e92fb744ca974893873f8885f54e23760f9b6311b" }
    "parts\kernel0.bin"    = @{ Size = 4194304;   Hash = "ab58d7a35bb75c988aad53001d52ed3f3306d138e36be8e7de2067891f7c5db8" }
    "parts\kernel1.bin"    = @{ Size = 4194304;   Hash = "ab893d6c0732dcea7f029fd3d7101b844ff9d2b2fc6114b24e908d466e3b6168" }
    "parts\rootfs0.bin"    = @{ Size = 33554432;  Hash = "b1ec27567aa0ecb81be4fba1266e9b7145d014814ab6622475765f2864b5391f" }
    "parts\rootfs1.bin"    = @{ Size = 33554432;  Hash = "b4e123eadad9659a3c02995667e382adbbe6854683ea2fa9b3b4c8b44e091757" }
    "parts\overlay.bin"    = @{ Size = 56098816;  Hash = "c8f5b48c23d468bcb8757de033dcf1c984db85a7fc815ac9b909e118b73b6dcd" }
}

function Add-Row($file, $size, $hash, $result, $note) {
    $script:rows += [pscustomobject]@{ File = $file; Size = $size; SHA256 = $hash; Result = $result; Note = $note }
    if ($result -eq "FAIL") { $script:failed++ }
}

if (-not ("Crc32Util" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class Crc32Util {
    private static readonly uint[] Table = BuildTable();
    private static uint[] BuildTable() {
        uint[] t = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int k = 0; k < 8; k++)
                c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
        return t;
    }
    public static uint Compute(byte[] data, int offset, int count) {
        uint c = 0xFFFFFFFFu;
        for (int i = 0; i < count; i++)
            c = Table[(c ^ data[offset + i]) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }
}
'@
}

function Get-BE32([byte[]]$b, [int]$o) {
    return ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor [uint32]$b[$o+3]
}

function Test-UImage([string]$path, [string]$type, [long]$size) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 64) { return "shorter than a uImage header" }
    if (-not ($bytes[0] -eq 0x27 -and $bytes[1] -eq 0x05 -and $bytes[2] -eq 0x19 -and $bytes[3] -eq 0x56)) {
        return "magic not uImage"
    }

    $hcrc = Get-BE32 $bytes 4
    $hdr = New-Object byte[] 64
    [Array]::Copy($bytes, 0, $hdr, 0, 64)
    $hdr[4] = 0; $hdr[5] = 0; $hdr[6] = 0; $hdr[7] = 0
    $calcH = [Crc32Util]::Compute($hdr, 0, 64)
    if ($calcH -ne $hcrc) {
        return ("header CRC 0x{0:X8} != stored 0x{1:X8}" -f $calcH, $hcrc)
    }

    $dsize = Get-BE32 $bytes 12
    $dcrc = Get-BE32 $bytes 24
    if ((64 + [long]$dsize) -gt $bytes.Length) { return "data size exceeds file length" }
    $calcD = [Crc32Util]::Compute($bytes, 64, [int]$dsize)
    if ($calcD -ne $dcrc) {
        return ("data CRC 0x{0:X8} != stored 0x{1:X8}" -f $calcD, $dcrc)
    }

    $load = Get-BE32 $bytes 16
    $name = [System.Text.Encoding]::ASCII.GetString($bytes, 32, 32).Trim([char]0, ' ')
    $expectedLoad = [Convert]::ToUInt32("80001000", 16)
    if ($load -ne $expectedLoad) { return ("load address 0x{0:X8} != 0x80001000" -f $load) }
    if ($type -eq "kernel1" -and $size -gt 4MB) { return "kernel1 larger than 4 MiB partition" }
    if ($type -eq "initramfs" -and $size -gt 128MB) { return "initramfs unreasonably large" }
    if ($type -eq "stock-kernel") {
        if ($size -ne 4MB) { return "stock kernel is not a 4 MiB partition dump" }
        if ($name -notmatch "Linux-3\.10\.14") { return "unexpected stock kernel name '$name'" }
    } elseif ($name -notmatch "OpenWrt Linux") {
        return "unexpected image name '$name'"
    }
    return $null
}

function Test-Ubi([string]$path, [long]$size) {
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $buf = New-Object byte[] 4
        $null = $fs.Read($buf, 0, 4)
    } finally { $fs.Close() }
    $magic = [System.Text.Encoding]::ASCII.GetString($buf)
    if ($magic -ne "UBI#") { return "magic '$magic' is not UBI#" }
    if ($size -gt 32MB) { return "rootfs0 larger than 32 MiB partition" }
    return $null
}

Write-Host ""
Write-Host "=== R3G v1 firmware verification (read-only) ===" -ForegroundColor Cyan
Write-Host ("Firmware dir: " + (Resolve-Path $FirmwareDir).Path)
Write-Host ""

foreach ($name in ($pin.Keys | Sort-Object)) {
    $meta = $pin[$name]
    $path = Join-Path $FirmwareDir $name
    if ($name -like "miwifi_*") {
        $path = Join-Path (Join-Path $FirmwareDir "stock") $name
    } elseif (-not (Test-Path -LiteralPath $path)) {
        $alt = Join-Path (Join-Path $FirmwareDir "openwrt") $name
        if (Test-Path -LiteralPath $alt) { $path = $alt }
    }

    if (-not (Test-Path -LiteralPath $path)) {
        if ($meta.Type -eq "v2-reject") {
            Add-Row $name "-" "-" "SKIP" "v2 image not present (correct for a v1 unit)"
        } elseif ($meta.Type -eq "initramfs" -and $AllowInitramfsMissing) {
            Add-Row $name "-" "-" "SKIP" "initramfs optional and missing"
        } else {
            Add-Row $name "-" "-" "FAIL" "missing"
        }
        continue
    }

    $size = (Get-Item -LiteralPath $path).Length
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($meta.Type -eq "v2-reject") {
        Add-Row $name $size $hash.Substring(0,16) "FAIL" "R3G v2 image must not be used on v1"
        continue
    }
    if ($hash -ne $meta.Hash -or $size -ne $meta.Size) {
        Add-Row $name $size $hash.Substring(0,16) "FAIL" "hash/size mismatch vs official pin"
        continue
    }

    $note = "hash OK"
    $structErr = $null
    switch ($meta.Type) {
        "kernel1"      { $structErr = Test-UImage $path "kernel1" $size }
        "initramfs"    { $structErr = Test-UImage $path "initramfs" $size }
        "stock-kernel" { $structErr = Test-UImage $path "stock-kernel" $size }
        "rootfs0"      { $structErr = Test-Ubi $path $size }
        "sysupgrade"   { $note += "; tar upgrade package - NEVER use for first install" }
        "stock-oem"    { $note += "; Xiaomi CDN package - hash pin only; vendor authenticity and compatibility UNVERIFIED" }
    }
    if ($structErr) {
        Add-Row $name $size $hash.Substring(0,16) "FAIL" ("hash OK but structure: " + $structErr)
    } else {
        if ($meta.Type -eq "kernel1" -or $meta.Type -eq "initramfs" -or $meta.Type -eq "stock-kernel") {
            $note += "; uImage magic/header CRC/data CRC/load address OK"
        }
        if ($meta.Type -eq "rootfs0") { $note += "; UBI magic OK" }
        if ($meta.Type -eq "stock-kernel") {
            $partRel = "parts\" + [System.IO.Path]::GetFileName($name)
            $partPath = Join-Path $BackupDir $partRel
            if (Test-Path -LiteralPath $partPath) {
                $partSize = (Get-Item -LiteralPath $partPath).Length
                $partHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $partPath).Hash.ToLowerInvariant()
                if ($partHash -eq $hash -and $partSize -eq $size) {
                    $note += "; equals external backup $partRel"
                } else {
                    Add-Row $name $size $hash.Substring(0,16) "FAIL" "tftp_stock copy does not match external backup $partRel"
                    continue
                }
            } else {
                $note += "; external backup $partRel NOT PRESENT - cross-check SKIPPED"
            }
        }
        Add-Row $name $size $hash.Substring(0,16) "PASS" $note
    }
}

if ($VerifyBackups) {
    Write-Host "=== NAND backup verification ===" -ForegroundColor Cyan
    foreach ($rel in ($backupPin.Keys | Sort-Object)) {
        $meta = $backupPin[$rel]
        $path = Join-Path $BackupDir $rel
        if (-not (Test-Path -LiteralPath $path)) {
            Add-Row ("backup:" + $rel) "-" "-" "FAIL" "missing"
            continue
        }
        $size = (Get-Item -LiteralPath $path).Length
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($hash -eq $meta.Hash -and $size -eq $meta.Size) {
            Add-Row ("backup:" + $rel) $size $hash.Substring(0,16) "PASS" "matches manifest"
        } else {
            Add-Row ("backup:" + $rel) $size $hash.Substring(0,16) "FAIL" "hash/size mismatch"
        }
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

if ($script:failed -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("{0} check(s) FAILED - do not flash anything." -f $script:failed) -ForegroundColor Red
    exit 1
}
