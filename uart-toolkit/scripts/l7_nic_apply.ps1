#requires -Version 5.1
<#
L7 validation helper: apply 192.168.1.100/24 to the known USB Realtek adapter
so the installed OpenWrt LAN (192.168.1.1) can be reached. Uses the audited
set_wired_ip.ps1; no default gateway and no DNS are configured.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path (Split-Path -Parent $here) "logs\l7_nic_apply.log"
$marker = Join-Path (Split-Path -Parent $here) "logs\l7_nic_apply.result.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
    & (Join-Path $here "set_wired_ip.ps1") `
        -Apply `
        -InterfaceGuid "{00000000-0000-0000-0000-000000000000}" `
        -MacAddress "AA-BB-CC-DD-EE-FF" `
        -Address "192.168.1.100" `
        -PrefixLength 24 `
        -IUnderstandThisChangesTheWiredAdapter
    "LASTEXITCODE=$LASTEXITCODE" | Tee-Object -FilePath $marker
} catch {
    "ERROR=$($_.Exception.Message)" | Tee-Object -FilePath $marker
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
