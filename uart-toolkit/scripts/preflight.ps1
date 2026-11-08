<#
.SYNOPSIS
    Offline preflight for the R3G UART recovery toolkit.

.DESCRIPTION
    Checks the host and the prepared files without touching the router:
      * PowerShell / Python / pyserial availability
      * toolkit script presence and PowerShell syntax
      * firmware and backup hashes (delegates to verify_firmware.ps1)
      * optional COM adapter detection (read-only; absence is not fatal)
      * writes a Markdown report under reports\

    It does not change firewall, routes, DNS, Wi-Fi, proxy or adapter
    settings, and it never opens a serial port.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\preflight.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\preflight.ps1 -SkipBackupHash
#>

[CmdletBinding()]
param(
    [switch]$SkipBackupHash
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$report = New-Object System.Text.StringBuilder
$issues = 0

function Line([string]$text = "") { [void]$report.AppendLine($text) }
function Check([string]$name, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { "PASS" } else { "FAIL" }
    if (-not $ok) { $script:issues++ }
    Line ("| {0} | {1} | {2} |" -f $name, $mark, $detail)
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("[{0}] {1}: {2}" -f $mark, $name, $detail) -ForegroundColor $color
}

Line "# R3G UART Toolkit Preflight"
Line ""
Line ("- Time: " + (Get-Date).ToString("o"))
Line ("- Toolkit: ``" + $root + "``")
Line "- Router hardware was not touched. This report is host/tooling only."
Line ""
Line "| Check | Result | Detail |"
Line "|---|---|---|"

# PowerShell
Check "PowerShell" $true ($PSVersionTable.PSVersion.ToString() + " / " + $PSVersionTable.PSEdition)

# Python
$python = $null
foreach ($cand in @("py", "python", "python3")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source; break }
}
if ($python) {
    $ver = & $python -I -c "import sys;print(sys.version.split()[0])" 2>&1
    Check "Python" ($LASTEXITCODE -eq 0) ("$python -> $ver")
    $pser = & $python -I -c "import serial;print(serial.VERSION)" 2>&1
    Check "pyserial" ($LASTEXITCODE -eq 0) ("version " + ($pser -join " "))
} else {
    Check "Python" $false "not found (install Python 3 and pyserial)"
    Check "pyserial" $false "not checked"
}

# Scripts and syntax
$scripts = @("detect_com.ps1", "verify_firmware.ps1", "set_wired_ip.ps1", "preflight.ps1")
foreach ($s in $scripts) {
    $p = Join-Path $scriptDir $s
    if (Test-Path $p) {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
        Check ("syntax " + $s) ($errors.Count -eq 0) $(if ($errors.Count) { $errors[0].Message } else { "parsed" })
    } else {
        Check ("script " + $s) $false "missing"
    }
}
foreach ($s in @("uart_capture.py", "uart_console.py", "uart_analyze.py", "tftp_server.py")) {
    $p = Join-Path $scriptDir $s
    Check ("script " + $s) (Test-Path $p) $(if (Test-Path $p) { "present" } else { "missing" })
    if ((Test-Path $p) -and $python) {
        & $python -I -c "import sys; compile(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1], 'exec')" $p 2>$null
        Check ("py_compile " + $s) ($LASTEXITCODE -eq 0) "offline syntax check"
    }
}

# Firmware and backups
$verify = Join-Path $scriptDir "verify_firmware.ps1"
$fwArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $verify)
if (-not $SkipBackupHash) { $fwArgs += "-VerifyBackups" }
$out = & powershell @fwArgs 2>&1
$ok = ($LASTEXITCODE -eq 0)
Check "firmware/backup hashes" $ok $(if ($ok) { "all pinned hashes match" } else { "see verify_firmware output" })
Line ""
Line "<details><summary>verify_firmware.ps1 output</summary>"
Line ""
Line "``````"
foreach ($l in $out) { Line ([string]$l) }
Line "``````"
Line ""
Line "</details>"
Line ""

# COM adapters (read-only; absence is informational)
$detect = Join-Path $scriptDir "detect_com.ps1"
$cout = & powershell -NoProfile -ExecutionPolicy Bypass -File $detect 2>&1
$code = $LASTEXITCODE
$comNote = switch ($code) {
    0 { "supported adapter present" }
    2 { "no adapter plugged in (expected before hardware stage)" }
    3 { "adapter present but no COM port; check driver" }
    default { "detect_com exit $code" }
}
$isFatal = ($code -eq 3)
Check "USB-TTL adapter" (-not $isFatal) $comNote
Line ""
Line "<details><summary>detect_com.ps1 output</summary>"
Line ""
Line "``````"
foreach ($l in $cout) { Line ([string]$l) }
Line "``````"
Line ""
Line "</details>"
Line ""

Line "## Summary"
Line ""
if ($issues -eq 0) {
    Line "All checks passed. No router hardware was touched."
} else {
    Line ("{0} check(s) failed. Fix them before the hardware stage." -f $issues)
}

$reports = Join-Path $root "reports"
New-Item -ItemType Directory -Force -Path $reports | Out-Null
$path = Join-Path $reports ("PREFLIGHT_" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".md")
$report.ToString() | Set-Content -LiteralPath $path -Encoding UTF8

Write-Host ""
Write-Host ("Report: " + $path) -ForegroundColor Cyan
if ($issues -eq 0) {
    Write-Host "PREFLIGHT PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("PREFLIGHT FAILED: " + $issues + " issue(s)") -ForegroundColor Red
    exit 1
}
