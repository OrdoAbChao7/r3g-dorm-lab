<#
.SYNOPSIS
    Read-only detection of USB-to-TTL adapters for the R3G UART recovery.

.DESCRIPTION
    Enumerates serial ports and PnP "Ports" devices, matches known USB-UART
    VID/PID pairs, and separates present devices from phantom (not present)
    records. It never opens a COM port, never sends bytes, and never changes
    any device or driver setting.

    Known adapters:
        CH340    VID_1A86 PID_7523
        CP210x   VID_10C4 PID_EA60
        FTDI     VID_0403 PID_6001
    Also recognised (warning only, not for the R3G):
        Espressif USB-JTAG/serial  VID_303A  (ESP32 boards)

    Exit codes:
        0  at least one supported adapter is present
        2  no supported adapter present
        3  adapter present but no active COM port (driver/port problem)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\detect_com.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$known = @{
    "1A86:7523" = @{ Name = "CH340";    Use = "supported" }
    "10C4:EA60" = @{ Name = "CP210x";   Use = "supported" }
    "0403:6001" = @{ Name = "FTDI";     Use = "supported" }
    "303A:1001" = @{ Name = "Espressif USB-JTAG/serial"; Use = "warning" }
    "303A:0002" = @{ Name = "Espressif USB-serial";      Use = "warning" }
}

function Get-VidPid([string]$instanceId) {
    if ($instanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
        return ($Matches[1] + ":" + $Matches[2]).ToUpperInvariant()
    }
    return $null
}

function Get-ComFromName([string]$name) {
    if ($name -match '\((COM\d+)\)') { return $Matches[1] }
    return $null
}

Write-Host ""
Write-Host "=== R3G UART adapter detection (read-only) ===" -ForegroundColor Cyan
Write-Host ""

$activePorts = @()
try { $activePorts = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { }
Write-Host ("Active serial ports (SerialPort.GetPortNames()): " + $(if ($activePorts.Count) { $activePorts -join ", " } else { "(none)" }))

$present = @()
$phantom = @()
try {
    $all = @(Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue)
    $present = @($all | Where-Object { $_.Present -eq $true -and $_.Status -ne "Unknown" })
    $phantom = @($all | Where-Object { $_.Present -ne $true -or $_.Status -eq "Unknown" })
} catch {
    Write-Host ("WARN: Get-PnpDevice failed: " + $_.Exception.Message) -ForegroundColor Yellow
}

$foundSupported = $false
$foundWarning = $false
$presentSupportedPorts = @()

Write-Host ""
Write-Host "--- Present Ports-class devices ---" -ForegroundColor Cyan
if ($present.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor Yellow
} else {
    foreach ($d in $present) {
        $vidpid = Get-VidPid $d.InstanceId
        $com = Get-ComFromName $d.FriendlyName
        $kind = "unknown"
        $use = "unknown"
        if ($vidpid -and $known.ContainsKey($vidpid)) {
            $kind = $known[$vidpid].Name
            $use = $known[$vidpid].Use
        }
        if ($use -eq "supported") {
            $foundSupported = $true
            if ($com -and ($activePorts -contains $com)) { $presentSupportedPorts += $com }
        }
        if ($use -eq "warning") { $foundWarning = $true }

        $color = switch ($use) { "supported" { "Green" } "warning" { "Yellow" } default { "Gray" } }
        Write-Host ("  [{0}] {1}" -f $d.Status, $d.FriendlyName) -ForegroundColor $color
        Write-Host ("        VID:PID = {0}   chip = {1}   COM = {2}" -f $(if ($vidpid) { $vidpid } else { "?" }), $kind, $(if ($com) { $com } else { "?" }))
        Write-Host ("        InstanceId = {0}" -f $d.InstanceId)
    }
}

Write-Host ""
Write-Host "--- Phantom / not-present Ports records (NOT usable) ---" -ForegroundColor DarkGray
if ($phantom.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor DarkGray
} else {
    foreach ($d in $phantom) {
        $vidpid = Get-VidPid $d.InstanceId
        $kind = if ($vidpid -and $known.ContainsKey($vidpid)) { $known[$vidpid].Name } else { "unknown" }
        Write-Host ("  {0}  VID:PID={1}  chip={2}" -f $d.FriendlyName, $(if ($vidpid) { $vidpid } else { "?" }), $kind) -ForegroundColor DarkGray
    }
    Write-Host "  These entries cannot be opened. Do not treat a phantom COM number as the adapter." -ForegroundColor DarkGray
}

Write-Host ""
if ($foundWarning) {
    Write-Host "NOTE: an Espressif (VID_303A) serial device is present. It may belong to an ESP32 board, not the R3G adapter." -ForegroundColor Yellow
    Write-Host "      Unplug it before choosing the COM port, or verify by unplug/replug." -ForegroundColor Yellow
    Write-Host ""
}

if ($foundSupported) {
    if ($presentSupportedPorts.Count -gt 0) {
        Write-Host ("RESULT: supported adapter present on " + ($presentSupportedPorts -join ", ")) -ForegroundColor Green
        Write-Host "Next: confirm by unplug/replug that this COM port disappears and reappears." -ForegroundColor Gray
        exit 0
    } else {
        Write-Host "RESULT: supported adapter is present but no active COM port was reported." -ForegroundColor Yellow
        Write-Host "        Check Device Manager for a yellow warning icon / missing driver." -ForegroundColor Yellow
        exit 3
    }
} else {
    Write-Host "RESULT: no supported USB-TTL adapter detected." -ForegroundColor Yellow
    Write-Host "        Plug in the 3.3V adapter (CH340/CP210x/FTDI) and run again." -ForegroundColor Gray
    exit 2
}
