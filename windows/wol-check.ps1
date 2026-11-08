<#
  Read-only evidence collector for the wake target (run on the laptop).
  Run once after each wake attempt.
#>
$ErrorActionPreference = "SilentlyContinue"

$nic = Get-NetAdapter | Where-Object {
    $_.InterfaceDescription -eq "Realtek Gaming 2.5GbE Family Controller"
}

Write-Host "===== time ====="
Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host ""
Write-Host "===== native NIC link ====="
$nic | Select-Object Name, Status, LinkSpeed, MediaConnectionState, MacAddress | Format-List

Write-Host "===== IP config ====="
if ($nic) {
    Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex |
        Select-Object IPv4Address, IPv4DefaultGateway | Format-List
}

Write-Host "===== wake_armed ====="
powercfg /devicequery wake_armed

Write-Host ""
Write-Host "===== last wake source ====="
powercfg /lastwake

Write-Host ""
Write-Host "===== Kernel-Power events, last 3h ====="
Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-Kernel-Power'
    StartTime    = (Get-Date).AddHours(-3)
} -MaxEvents 25 |
    Select-Object TimeCreated, Id |
    Format-Table -AutoSize
