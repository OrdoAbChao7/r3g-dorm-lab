<#
.SYNOPSIS
    Restore ONLY the Realtek USB 2.5GbE adapter to DHCP / automatic metric.

.DESCRIPTION
    Safety rules enforced here:
      * Targets one adapter by exact description AND MAC address.
      * Never touches WLAN 2, Wi-Fi profiles, default routes, Clash, proxy,
        firewall, Winsock, or IPv4 forwarding.
      * Refuses to run without administrator rights; it does not self-elevate.
      * Writes a JSON snapshot and a text log before/after the change.

.EXAMPLE
    .\rollback_usb_nic.ps1 -DryRun
.EXAMPLE
    .\rollback_usb_nic.ps1 -Yes
#>

param(
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ExpectedDescription = "Realtek Gaming USB 2.5GbE Family Controller"
$ExpectedMac         = "AA-BB-CC-DD-EE-FF"

$ScriptDir = $PSScriptRoot
$Root      = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ReportDir = Join-Path $Root "reports"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogPath = Join-Path $ReportDir ("rollback_usb_nic_" + $Stamp + ".log")
$JsonPath = Join-Path $ReportDir ("rollback_usb_nic_" + $Stamp + ".json")

function Log([string]$Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Log "rollback_usb_nic start"
Log ("DryRun=" + [bool]$DryRun + " Yes=" + [bool]$Yes)

if (-not (IsAdmin)) {
    Log "REFUSED: not running as administrator. Restart Claude Code elevated; this script will not self-elevate."
    exit 3
}

$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.InterfaceDescription -eq $ExpectedDescription -and $_.MacAddress -eq $ExpectedMac
})
if ($adapters.Count -ne 1) {
    Log ("REFUSED: expected exactly one adapter with description '" + $ExpectedDescription + "' and MAC " + $ExpectedMac + "; found " + $adapters.Count)
    exit 4
}

$a = $adapters[0]
$idx = $a.ifIndex
Log ("target: name='" + $a.Name + "' desc='" + $a.InterfaceDescription + "' mac=" + $a.MacAddress + " guid=" + $a.InterfaceGuid + " ifIndex=" + $idx)
Log ("current: status=" + $a.Status + " linkSpeed=" + $a.LinkSpeed)

$ipIf = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
$ips  = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object IPAddress,PrefixLength,AddressState)
$dns  = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)

$snapshot = [pscustomobject]@{
    timestamp = (Get-Date).ToString("o")
    adapter   = [pscustomobject]@{
        Name = $a.Name
        Description = $a.InterfaceDescription
        Mac = $a.MacAddress
        Guid = [string]$a.InterfaceGuid
        ifIndex = $idx
        Status = [string]$a.Status
        LinkSpeed = [string]$a.LinkSpeed
    }
    ipv4 = $ips
    dns = $dns
    dhcp = if ($ipIf) { [string]$ipIf.Dhcp } else { "" }
    metric = if ($ipIf) { $ipIf.InterfaceMetric } else { 0 }
    automaticMetric = if ($ipIf) { [string]$ipIf.AutomaticMetric } else { "" }
}
$snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonPath -Encoding UTF8
Log ("snapshot written: " + $JsonPath)

Write-Host ""
Write-Host "About to restore DHCP / automatic metric on:" -ForegroundColor Yellow
Write-Host ("  Name : " + $a.Name)
Write-Host ("  Desc : " + $a.InterfaceDescription)
Write-Host ("  MAC  : " + $a.MacAddress)
Write-Host ("  GUID : " + $a.InterfaceGuid)
Write-Host ""
Write-Host "This will NOT touch WLAN 2, Wi-Fi profiles, the default route, Clash, proxy, firewall or Winsock." -ForegroundColor Gray

if ($DryRun) {
    Log "DRY-RUN: no change made"
    Write-Host "Dry-run only. No modification." -ForegroundColor Magenta
    exit 0
}

if (-not $Yes) {
    $answer = Read-Host "Proceed? [y/N]"
    if ($answer -notmatch '^(y|yes|是)$') {
        Log "cancelled by user"
        exit 0
    }
}

Log "setting DHCP enabled"
Set-NetIPInterface -InterfaceIndex $idx -Dhcp Enabled -ErrorAction Stop

Log "removing static IPv4 addresses on target adapter only"
Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

Log "resetting DNS to DHCP-provided"
Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction SilentlyContinue

Log "restoring automatic interface metric"
Set-NetIPInterface -InterfaceIndex $idx -AutomaticMetric Enabled -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1
$afterIp = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object IPAddress,PrefixLength,AddressState)
$afterIf = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
Log ("after: dhcp=" + [string]$afterIf.Dhcp + " metric=" + $afterIf.InterfaceMetric + " ips=" + (($afterIp | ForEach-Object { $_.IPAddress + "/" + $_.PrefixLength }) -join ","))
Log "done. WLAN and default routes untouched."
exit 0
