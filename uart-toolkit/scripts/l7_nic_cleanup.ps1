#requires -Version 5.1
<#
L7 post-install cleanup: remove the temporary 192.168.1.100 alias and roll the
USB Realtek adapter back to the saved pre-L5 state (DHCP). The router's own
DHCP server should then provide a 192.168.1.x lease.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path (Split-Path -Parent $here) "logs\l7_nic_cleanup.log"
$marker = Join-Path (Split-Path -Parent $here) "logs\l7_nic_cleanup.result.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
    Remove-NetIPAddress -InterfaceIndex 2 -IPAddress "192.168.1.100" -PrefixLength 24 `
        -Confirm:$false -ErrorAction SilentlyContinue
    & (Join-Path $here "set_wired_ip.ps1") `
        -Rollback `
        -InterfaceGuid "{00000000-0000-0000-0000-000000000000}" `
        -MacAddress "AA-BB-CC-DD-EE-FF" `
        -DhcpTimeoutSeconds 20
    "LASTEXITCODE=$LASTEXITCODE" | Tee-Object -FilePath $marker
} catch {
    "ERROR=$($_.Exception.Message)" | Tee-Object -FilePath $marker
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
