<#
.SYNOPSIS
    Read-only PXE capability report for the current PC and its NICs.

.DESCRIPTION
    Reports firmware mode, NIC PXE-related advanced properties and link state.
    It cannot prove that a USB NIC has a UEFI PXE option ROM; absence of
    evidence is reported as "unknown", never as supported.

.EXAMPLE
    .\check_pxe_capability.ps1
#>

param([switch]$Json)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Head([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor Cyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor Cyan
}

Write-Head "PXE 能力检测 (只读)"

$fw = "unknown"
try {
    $info = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop
    $fw = [string]$info.BiosFirmwareType
} catch {
    try {
        $sysPart = Get-Partition -ErrorAction Stop | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
        if ($sysPart) { $fw = "Uefi (inferred from EFI system partition)" }
    } catch {}
}
Write-Host "固件模式: $fw"

Write-Head "网络适配器"
$rows = @()
foreach ($a in Get-NetAdapter) {
    $pxeProps = @()
    try {
        $pxeProps = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction Stop |
            Where-Object { $_.DisplayName -match 'PXE|Network Boot|Boot Protocol|UEFI' -or $_.RegistryKeyword -match 'PXE|Boot' } |
            Select-Object -ExpandProperty DisplayName)
    } catch {}

    $verdict = if ($pxeProps.Count -gt 0) { "advertises: " + ($pxeProps -join '; ') }
               elseif ($a.MediaType -eq '802.3') { "no PXE property visible (unknown, likely no option ROM)" }
               else { "n/a" }

    $rows += [pscustomobject]@{
        ifIndex = $a.ifIndex
        Name = $a.Name
        Description = $a.InterfaceDescription
        Status = [string]$a.Status
        Speed = [string]$a.LinkSpeed
        PXE = $verdict
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 240 | Write-Host

Write-Head "结论"
Write-Host "1. 固件是否 UEFI: $fw"
Write-Host "2. 只有真实进入 PXE 菜单才算支持；属性缺失不能证明不支持，属性存在也不能证明可用。" -ForegroundColor Yellow
Write-Host "3. USB 转 RJ45 网卡通常没有 PXE Option ROM，优先用主板内置网口做 PXE 实验。" -ForegroundColor Yellow
Write-Host "4. 无论如何保留 U 盘恢复方案。" -ForegroundColor Gray

if ($Json) {
    $report = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        firmware = $fw
        adapters = $rows
        note = "Property presence is not proof of UEFI PXE support"
    }
    $path = Join-Path $LogDir ("pxe-capability-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".json")
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    Write-Host "JSON 报告: $path" -ForegroundColor Green
}
