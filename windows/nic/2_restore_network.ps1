<#
.SYNOPSIS
    One-click restore of the network snapshot saved by 2_setup_dual_nic_and_nas.ps1.

.DESCRIPTION
    Thin wrapper so the rollback path is a single, obvious command.
    Reads 02_DualNIC_And_WakeOnLAN_PXE/scripts/configs/network-backup-latest.json.
#>

param([switch]$DryRun, [switch]$Yes)

$main = Join-Path $PSScriptRoot "2_setup_dual_nic_and_nas.ps1"
if (-not (Test-Path $main)) {
    Write-Error "找不到主脚本: $main"
    exit 1
}

$bind = @{ Action = "Restore" }
if ($DryRun) { $bind.DryRun = $true }
if ($Yes) { $bind.Yes = $true }

& $main @bind
