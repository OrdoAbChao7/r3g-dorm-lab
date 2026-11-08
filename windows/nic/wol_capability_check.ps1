<#
.SYNOPSIS
    Wake-on-LAN capability check (read-only).

.DESCRIPTION
    Collects evidence only. It never enables wake options and never changes
    power settings. The final verdict separates what the NIC advertises from
    what the platform actually supports, and says "unknown" where evidence is
    insufficient.

.EXAMPLE
    .\wol_capability_check.ps1
.EXAMPLE
    .\wol_capability_check.ps1 -AdapterName "以太网 2" -Json
#>

param(
    [string]$AdapterName,
    [int]$InterfaceIndex = -1,
    [switch]$Json
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Head([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor Cyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor Cyan
}

function Get-TargetAdapter {
    if ($InterfaceIndex -ge 0) { return Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue }
    if ($AdapterName) { return Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue }

    $cands = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        $_.MediaType -eq '802.3' -and -not $_.Virtual -and
        ([string]$_.InterfaceDescription -match 'USB|RTL8153|AX88179|ASIX|Realtek USB')
    })
    if ($cands.Count -eq 1) { return $cands[0] }
    if ($cands.Count -gt 1) {
        for ($i = 0; $i -lt $cands.Count; $i++) {
            Write-Host ("[{0}] {1}  {2}  {3}" -f ($i + 1), $cands[$i].Name, $cands[$i].InterfaceDescription, $cands[$i].Status)
        }
        $n = [int](Read-Host "选择 USB 网卡序号")
        return $cands[$n - 1]
    }
    Write-Host "未自动识别 USB 网卡，列出全部 802.3 适配器："
    Get-NetAdapter | Where-Object { $_.MediaType -eq '802.3' } |
        Select-Object ifIndex, Name, InterfaceDescription, Status, MacAddress |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    return $null
}

function Invoke-PowerCfg([string]$Arguments) {
    try {
        $out = & powercfg $Arguments.Split(' ') 2>&1
        return ($out | Out-String).Trim()
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Test-PowerCfgState([string]$Query) {
    $text = Invoke-PowerCfg $Query
    return [pscustomobject]@{ Query = $Query; Text = $text; Answered = ($text -notmatch 'ERROR|不支持|not supported|Invalid') }
}

$adapter = Get-TargetAdapter

Write-Head "WoL 能力检测 (只读)"

if (-not $adapter) {
    Write-Host "没有选中适配器，仍会输出系统睡眠状态。" -ForegroundColor Yellow
} else {
    Write-Host "适配器: $($adapter.Name)"
    Write-Host "描述  : $($adapter.InterfaceDescription)"
    Write-Host "MAC   : $($adapter.MacAddress)"
    Write-Host "状态  : $($adapter.Status)  $($adapter.LinkSpeed)"

    $drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceName -and $adapter.InterfaceDescription -and
                          $_.DeviceName -like ("*" + $adapter.InterfaceDescription.Trim() + "*") } |
           Select-Object -First 1
    if ($drv) {
        Write-Host "驱动  : $($drv.DriverProviderName) $($drv.DriverVersion)"
    } else {
        Write-Host "驱动  : 未能通过 CIM 关联到具体驱动版本" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "网卡电源管理能力 (advertised):" -ForegroundColor Gray
    try {
        $pm = Get-NetAdapterPowerManagement -Name $adapter.Name -ErrorAction Stop
        $pm | Select-Object WakeOnMagicPacket, WakeOnPattern, DeviceSleepOnDisconnect,
                          SelectiveSuspend, ModernStandby | Format-List | Out-String | Write-Host
    } catch {
        Write-Host "  Get-NetAdapterPowerManagement 不可用: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "高级属性中与唤醒相关的项:" -ForegroundColor Gray
    try {
        Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction Stop |
            Where-Object { $_.DisplayName -match 'Wake|唤醒|PME|Shutdown' -or $_.RegistryKeyword -match 'Wake|PME' } |
            Select-Object DisplayName, DisplayValue, RegistryKeyword |
            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    } catch {
        Write-Host "  读取失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Head "系统睡眠状态 (powercfg /a)"
$sleepText = Invoke-PowerCfg "/a"
Write-Host $sleepText

$s0 = ($sleepText -match 'S0 Low Power Idle|S0 低电量待机|Standby \(S0')
$s1 = ($sleepText -match 'Standby \(S1')
$s2 = ($sleepText -match 'Standby \(S2')
$s3 = ($sleepText -match 'Standby \(S3|待机 \(S3')
$s4 = ($sleepText -match 'Hibernate|休眠')
$fastStartup = $true  # Windows default; reported separately below
try {
    $hib = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -ErrorAction SilentlyContinue).HibernateEnabled
    if ($hib -eq 0) { $s4 = $false }
} catch {}

Write-Head "唤醒设备查询"
$wakeProgrammable = Invoke-PowerCfg "/devicequery wake_programmable"
$wakeArmed        = Invoke-PowerCfg "/devicequery wake_armed"
Write-Host "wake_programmable (可被配置为唤醒源):" -ForegroundColor Gray
Write-Host $wakeProgrammable
Write-Host ""
Write-Host "wake_armed (当前已武装):" -ForegroundColor Gray
Write-Host $wakeArmed

$s3query = Test-PowerCfgState "/devicequery wake_from_S3"
$s4query = Test-PowerCfgState "/devicequery wake_from_S4"
$s5query = Test-PowerCfgState "/devicequery wake_from_S5"

$macInProgrammable = $false
$macInArmed = $false
if ($adapter) {
    $name = $adapter.InterfaceDescription
    $macInProgrammable = ($wakeProgrammable -match [regex]::Escape($name))
    $macInArmed = ($wakeArmed -match [regex]::Escape($name))
}

Write-Head "结论 (证据分级)"
Write-Host ("S0 Modern Standby : " + $(if ($s0) { "可用" } else { "不可用/未报告" }))
Write-Host ("S3 睡眠           : " + $(if ($s3) { "可用" } else { "不可用/未报告" }))
Write-Host ("S4 休眠           : " + $(if ($s4) { "可用" } else { "不可用/未报告" }))
Write-Host ("S5 关机           : " + "无法由 powercfg 直接证明；需 BIOS + 网卡 + 待机供电共同支持")
Write-Host ""
if ($adapter) {
    Write-Host ("网卡在 wake_programmable 列表中: " + $macInProgrammable)
    Write-Host ("网卡在 wake_armed 列表中       : " + $macInArmed)
}
Write-Host ""
Write-Host "重要: 网卡高级属性里的 'Wake on Magic Packet' 只说明网卡具备该能力，" -ForegroundColor Yellow
Write-Host "      不等于主板支持从 S5 关机状态唤醒。只有实测成功才能宣称 S5 可用。" -ForegroundColor Yellow
Write-Host ""
Write-Host "建议的实测顺序: S3 睡眠 -> S4 休眠 -> S5 关机(关闭快速启动)。" -ForegroundColor Gray
Write-Host "每次只改一个变量，记录结果，失败时先在 BIOS 查 'Wake on LAN / Power On By PCI-E'。" -ForegroundColor Gray

if ($Json) {
    $report = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        adapter = if ($adapter) { [pscustomobject]@{
            Name = $adapter.Name
            Description = $adapter.InterfaceDescription
            Mac = $adapter.MacAddress
            Status = [string]$adapter.Status
            Driver = if ($drv) { "$($drv.DriverProviderName) $($drv.DriverVersion)" } else { "unknown" }
        } } else { $null }
        sleep = [pscustomobject]@{ s0 = $s0; s1 = $s1; s2 = $s2; s3 = $s3; s4 = $s4 }
        wakeProgrammable = $wakeProgrammable
        wakeArmed = $wakeArmed
        wakeFromS3 = $s3query.Text
        wakeFromS4 = $s4query.Text
        wakeFromS5 = $s5query.Text
        note = "Magic Packet capability is not proof of S5 wake support"
    }
    $path = Join-Path $LogDir ("wol-capability-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + ".json")
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
    Write-Host ""
    Write-Host "JSON 报告: $path" -ForegroundColor Green
}
