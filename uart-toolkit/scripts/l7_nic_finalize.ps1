#requires -Version 5.1
<#
Final L7 network cleanup: remove the temporary L5/L7 addresses and assign a
single management address 192.168.1.2/24 to the USB Realtek adapter, with no
default gateway and no DNS. 192.168.1.2 is outside the router's default DHCP
pool, so it can be used to reach 192.168.1.1 without changing the default route.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path (Split-Path -Parent $here) "logs\l7_nic_finalize.log"
$marker = Join-Path (Split-Path -Parent $here) "logs\l7_nic_finalize.result.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
    Remove-NetIPAddress -InterfaceIndex 2 -IPAddress "192.168.1.100" -PrefixLength 24 `
        -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceIndex 2 -IPAddress "192.168.31.100" -PrefixLength 24 `
        -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex 2 -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
    New-NetIPAddress -InterfaceIndex 2 -IPAddress "192.168.1.2" -PrefixLength 24 -ErrorAction Stop | Out-Null
    "OK" | Tee-Object -FilePath $marker
} catch {
    "ERROR=$($_.Exception.Message)" | Tee-Object -FilePath $marker
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
