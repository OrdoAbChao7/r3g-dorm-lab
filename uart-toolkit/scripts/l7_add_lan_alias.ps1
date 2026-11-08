#requires -Version 5.1
<#
L7 validation helper: add a secondary 192.168.1.100/24 address to the known
USB Realtek adapter so the installed OpenWrt LAN (192.168.1.1) can be tested.
No default gateway and no DNS are configured. The existing 192.168.31.100/24
address is kept.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path (Split-Path -Parent $here) "logs\l7_lan_alias.log"
$marker = Join-Path (Split-Path -Parent $here) "logs\l7_lan_alias.result.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
    New-NetIPAddress -InterfaceIndex 2 -IPAddress "192.168.1.100" -PrefixLength 24 -ErrorAction Stop | Out-Null
    "OK" | Tee-Object -FilePath $marker
} catch {
    "ERROR=$($_.Exception.Message)" | Tee-Object -FilePath $marker
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
