#requires -Version 5.1
<#
L5 helper: apply the fixed 192.168.31.100/24 address to the known USB Realtek
adapter, using the audited set_wired_ip.ps1 tool. This helper contains no
network logic of its own; it only supplies the exact GUID/MAC and records the
elevated transcript for the L5 evidence log.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path (Split-Path -Parent $here) "logs\l5_nic_apply.log"
$marker = Join-Path (Split-Path -Parent $here) "logs\l5_nic_apply.result.txt"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
Start-Transcript -Path $log -Force | Out-Null
try {
    & (Join-Path $here "set_wired_ip.ps1") `
        -Apply `
        -InterfaceGuid "{00000000-0000-0000-0000-000000000000}" `
        -MacAddress "AA-BB-CC-DD-EE-FF" `
        -IUnderstandThisChangesTheWiredAdapter
    "LASTEXITCODE=$LASTEXITCODE" | Tee-Object -FilePath $marker
} catch {
    "ERROR=$($_.Exception.Message)" | Tee-Object -FilePath $marker
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
