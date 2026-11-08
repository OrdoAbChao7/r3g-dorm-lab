<#
.SYNOPSIS
    R3G Dorm Lab - Dual NIC (Wi-Fi internet + USB Ethernet LAN) and SMB mapping.

.DESCRIPTION
    Design rules enforced by this script:
      * Wi-Fi keeps the default gateway and its metric. Never touched.
      * The USB Ethernet adapter is LAN-only: no default gateway on it.
      * Original adapter state is snapshotted to JSON before any change.
      * DHCP is preferred; static is only proposed when DHCP cannot reach
        the router or the subnets conflict.
      * -DryRun prints every planned change and performs none.

.EXAMPLE
    .\2_setup_dual_nic_and_nas.ps1 -Action Inspect
.EXAMPLE
    .\2_setup_dual_nic_and_nas.ps1 -Action Apply -RouterIP 192.168.1.1 -DryRun
.EXAMPLE
    .\2_setup_dual_nic_and_nas.ps1 -Action Map -RouterIP 192.168.1.1 -Share root -Drive Z
.EXAMPLE
    .\2_setup_dual_nic_and_nas.ps1 -Action Restore
#>

param(
    [ValidateSet("Menu", "Inspect", "Apply", "Map", "Test", "Restore")]
    [string]$Action = "Menu",

    [string]$AdapterName,
    [int]$InterfaceIndex = -1,

    [string]$RouterIP = "192.168.1.1",
    [string]$StaticIP = "192.168.1.10",
    [int]$PrefixLength = 24,

    [string]$Share = "root",
    [string]$Drive = "Z",
    [string]$SmbUser = "",
    [string]$SmbPass = "",

    [switch]$ForceStatic,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CfgDir   = Join-Path $PSScriptRoot "configs"
$LogDir   = Join-Path $Root "logs"
$BackupFile = Join-Path $CfgDir "network-backup-latest.json"

New-Item -ItemType Directory -Force -Path $CfgDir, $LogDir | Out-Null

function Write-Head([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor Cyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "[ OK ] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "[FAIL] $Text" -ForegroundColor Red }
function Write-Plan([string]$Text) { Write-Host "[PLAN] $Text" -ForegroundColor Magenta }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (-not (Test-Admin)) {
        Write-Warn "需要管理员权限，正在请求提升..."
        $parts = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"",
                   "-Action", $Action)
        if ($AdapterName) { $parts += @("-AdapterName", "`"$AdapterName`"") }
        if ($InterfaceIndex -ge 0) { $parts += @("-InterfaceIndex", "$InterfaceIndex") }
        if ($RouterIP) { $parts += @("-RouterIP", $RouterIP) }
        if ($StaticIP) { $parts += @("-StaticIP", $StaticIP) }
        if ($DryRun) { $parts += "-DryRun" }
        Start-Process powershell -Verb RunAs -ArgumentList ($parts -join " ")
        exit
    }
}

function Confirm-Plan([string]$What) {
    if ($Yes) { return $true }
    $answer = Read-Host "$What  [y/N]"
    return ($answer -match '^(y|yes|是)$')
}

# ---------------------------------------------------------------- snapshot
function Get-AdapterSnapshot {
    Get-NetAdapter | ForEach-Object {
        $idx = $_.ifIndex
        $ipIf = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty IPAddress)
        $prefixes = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Select-Object -ExpandProperty PrefixLength)
        $gws = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty NextHop)
        $dns = @()
        try { $dns = @(Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty ServerAddresses) } catch {}
        [pscustomobject]@{
            Name = $_.Name
            InterfaceIndex = $idx
            InterfaceDescription = $_.InterfaceDescription
            MacAddress = $_.MacAddress
            Status = [string]$_.Status
            MediaType = [string]$_.MediaType
            Dhcp = if ($ipIf) { [string]$ipIf.Dhcp } else { "" }
            InterfaceMetric = if ($ipIf) { $ipIf.InterfaceMetric } else { 0 }
            IPAddresses = $ips
            PrefixLengths = $prefixes
            Gateways = $gws
            DnsServers = $dns
        }
    }
}

function Save-NetworkBackup {
    $snapshot = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        computer = $env:COMPUTERNAME
        adapters = @(Get-AdapterSnapshot)
        defaultRoutes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                          Select-Object ifIndex, InterfaceAlias, NextHop, RouteMetric)
        systemProxy = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue |
                       Select-Object ProxyEnable, ProxyServer)
        ipEnableRouter = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -ErrorAction SilentlyContinue).IPEnableRouter
    }
    $json = $snapshot | ConvertTo-Json -Depth 8
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $stamped = Join-Path $CfgDir ("network-backup-" + $stamp + ".json")
    Set-Content -Path $stamped -Value $json -Encoding UTF8
    Set-Content -Path $BackupFile -Value $json -Encoding UTF8
    Write-Ok "已保存网络快照: $stamped"
    return $stamped
}

# ---------------------------------------------------------------- adapters
function Get-CandidateUsbAdapters {
    $all = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    if (-not $all) { $all = Get-NetAdapter }
    $scored = foreach ($a in $all) {
        $desc = [string]$a.InterfaceDescription
        $name = [string]$a.Name
        $blob = "$desc $name"
        $score = 0
        if ($blob -match 'USB|RTL8153|AX88179|ASIX|Realtek USB|CDC') { $score += 40 }
        if ([string]$a.MediaType -eq '802.3') { $score += 20 }
        if ($a.LinkSpeed -match '1 Gbps|1.0 Gbps|2.5 Gbps') { $score += 10 }
        # VPN / virtual / wireless adapters must never be offered as the LAN NIC.
        if ($blob -match 'TAP|VPN|Virtual|Hyper-V|vEthernet|WSL|Loopback|Bluetooth') { $score -= 200 }
        if ([string]$a.MediaType -match '802.11|Wireless') { $score -= 200 }
        if ($blob -match 'Wi-?Fi|Wireless|WLAN') { $score -= 200 }
        if ($a.Virtual) { $score -= 200 }
        [pscustomobject]@{ Adapter = $a; Score = $score }
    }
    return @($scored | Where-Object { $_.Score -ge 40 } | Sort-Object Score -Descending |
             ForEach-Object { $_.Adapter })
}

function Resolve-Adapter([string]$Purpose = "USB 千兆网卡") {
    if ($InterfaceIndex -ge 0) {
        $a = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $a) { throw "找不到 ifIndex=$InterfaceIndex 的适配器" }
        return $a
    }
    if ($AdapterName) {
        $a = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if (-not $a) { throw "找不到名为 '$AdapterName' 的适配器" }
        return $a
    }

    $candidates = @(Get-CandidateUsbAdapters)
    if ($candidates.Count -eq 1) {
        Write-Ok "自动识别 $Purpose : $($candidates[0].Name) ($($candidates[0].InterfaceDescription))"
        return $candidates[0]
    }
    if ($candidates.Count -gt 1) {
        Write-Host "检测到多个候选，请选择 $Purpose :"
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  [{0}] {1}  ({2})  {3}" -f ($i + 1), $candidates[$i].Name,
                        $candidates[$i].InterfaceDescription, $candidates[$i].Status)
        }
        $sel = Read-Host "序号"
        $n = [int]$sel
        if ($n -lt 1 -or $n -gt $candidates.Count) { throw "无效序号" }
        return $candidates[$n - 1]
    }

    Write-Warn "未能自动识别 USB 网卡，列出全部适配器："
    Show-Adapters
    $idx = Read-Host "请输入 ifIndex"
    $a = Get-NetAdapter -InterfaceIndex ([int]$idx) -ErrorAction SilentlyContinue
    if (-not $a) { throw "找不到 ifIndex=$idx" }
    return $a
}

function Show-Adapters {
    Write-Head "网络适配器 (只读)"
    Get-NetAdapter | Select-Object ifIndex, Name, InterfaceDescription, Status, LinkSpeed, MacAddress |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    Write-Host "默认路由 0.0.0.0/0:" -ForegroundColor Gray
    Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object ifIndex, InterfaceAlias, NextHop, RouteMetric |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    Write-Host "IPv4 地址:" -ForegroundColor Gray
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Select-Object ifIndex, InterfaceAlias, IPAddress, PrefixLength |
        Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

# ---------------------------------------------------------------- subnet math
function ConvertTo-UInt32([string]$ip) {
    $parts = $ip.Split('.')
    if ($parts.Count -ne 4) { throw "非法 IPv4: $ip" }
    return ([uint32]$parts[0] -shl 24) -bor ([uint32]$parts[1] -shl 16) -bor
           ([uint32]$parts[2] -shl 8) -bor ([uint32]$parts[3])
}

function Get-Network([string]$ip, [int]$prefix) {
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefix)) }
    return (ConvertTo-UInt32 $ip) -band $mask
}

function Test-SubnetConflict([string]$targetIp, [int]$targetPrefix, $adapter) {
    if (-not $adapter) { return $false }
    $targetNet = Get-Network $targetIp $targetPrefix
    $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    foreach ($entry in $ips) {
        $net = Get-Network $entry.IPAddress $entry.PrefixLength
        $targetMask = if ($targetPrefix -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $targetPrefix)) }
        $entryMask = if ($entry.PrefixLength -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $entry.PrefixLength)) }
        if (($net -band $targetMask) -eq $targetNet -and ($targetNet -band $entryMask) -eq $net) {
            return $true
        }
    }
    return $false
}

# ---------------------------------------------------------------- apply
function Test-RouterReachable {
    $ping = Test-Connection -ComputerName $RouterIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    return [bool]$ping
}

function Invoke-Apply {
    $adapter = Resolve-Adapter

    Write-Head "目标: $($adapter.Name) -> $RouterIP"
    Write-Host "当前配置:"
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object IPAddress, PrefixLength | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

    # Subnet conflict against every other connected adapter (Wi-Fi included).
    $conflict = $false
    foreach ($other in @(Get-NetAdapter | Where-Object { $_.ifIndex -ne $adapter.ifIndex -and $_.Status -eq 'Up' })) {
        if (Test-SubnetConflict $StaticIP $PrefixLength $other) {
            Write-Err "目标子网 $StaticIP/$PrefixLength 与 '$($other.Name)' 的子网冲突。"
            Write-Warn "请先修改路由器 LAN 网段或本机 Wi-Fi，脚本不会继续。"
            return
        }
    }
    if (-not $conflict) { Write-Ok "未发现子网冲突" }

    $ipIf = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $currentIp = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty IPAddress)
    $sameSubnet = $currentIp | Where-Object { (Get-Network $_ $PrefixLength) -eq (Get-Network $StaticIP $PrefixLength) }

    if (-not $ForceStatic -and $ipIf -and $ipIf.Dhcp -eq 'Enabled' -and $sameSubnet -and (Test-RouterReachable)) {
        Write-Ok "DHCP 已拿到同网段地址且路由器可达，无需修改。"
        Invoke-Test
        return
    }

    Write-Ok "保留快照"
    $backupPath = Save-NetworkBackup

    Write-Warn "即将修改 '$($adapter.Name)':"
    Write-Plan "关闭该网卡 DHCP"
    Write-Plan "清除该网卡已有 IPv4 地址"
    Write-Plan "清除该网卡上的默认路由 (0.0.0.0/0)"
    Write-Plan "设置 $StaticIP/$PrefixLength，不设置默认网关"
    Write-Plan "接口 metric = 9000，让 Wi-Fi 保持默认出口"
    Write-Host ""
    Write-Host "不会修改: Wi-Fi 网关/Metric、VPN、系统代理、TUN、防火墙、IPEnableRouter、Winsock。" -ForegroundColor Gray

    if ($DryRun) {
        Write-Plan "(DryRun) 未执行任何修改。快照: $backupPath"
        return
    }
    if (-not (Confirm-Plan "确认执行以上网络修改?")) {
        Write-Warn "已取消。"
        return
    }

    Ensure-Admin

    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled -ErrorAction Stop
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIP -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -InterfaceMetric 9000 -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 1
    Write-Ok "静态地址已应用。"
    Invoke-Test
}

# ---------------------------------------------------------------- test
function Invoke-Test {
    Write-Head "连通性验证"

    $defaults = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
    if ($defaults.Count -eq 0) {
        Write-Err "没有默认路由，外网必然不通 (Wi-Fi 是否连接?)"
    } else {
        foreach ($r in $defaults) {
            Write-Ok "默认路由 via $($r.InterfaceAlias) -> $($r.NextHop) metric=$($r.RouteMetric)"
        }
        $usbDefault = $defaults | Where-Object { $_.InterfaceAlias -match 'USB|以太网|Ethernet' }
        if ($usbDefault) {
            Write-Warn "检测到 USB/以太网 上仍有默认路由，可能抢占外网。请运行 Apply 修正。"
        }
    }

    if (Test-Connection -ComputerName $RouterIP -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Write-Ok "路由器 $RouterIP 可达"
    } else {
        Write-Warn "路由器 $RouterIP 不可达 (Breed 阶段也是 192.168.1.1, 请检查网线与网卡)"
    }

    foreach ($port in 80, 443, 445) {
        $t = Test-NetConnection -ComputerName $RouterIP -Port $port -WarningAction SilentlyContinue
        if ($t.TcpTestSucceeded) { Write-Ok "$RouterIP`:$port 开放" }
        else { Write-Warn "$RouterIP`:$port 未开放" }
    }

    try {
        $r = Invoke-WebRequest -Uri "https://www.baidu.com" -UseBasicParsing -TimeoutSec 8
        Write-Ok "外网 HTTPS 正常 (状态码 $($r.StatusCode)) — 默认走 Wi-Fi"
    } catch {
        Write-Warn "外网访问失败: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- SMB
function Test-SmbPort {
    $t = Test-NetConnection -ComputerName $RouterIP -Port 445 -WarningAction SilentlyContinue
    return [bool]$t.TcpTestSucceeded
}

function Find-FreeDrive([string]$preferred) {
    if (-not (Test-Path "${preferred}:\")) { return $preferred }
    foreach ($c in @('Z','Y','X','W','V','U','T')) {
        if (-not (Test-Path "${c}:\")) { return $c }
    }
    throw "没有可用的盘符"
}

function Invoke-Map {
    Ensure-Admin
    Write-Head "映射 Samba 共享"
    if (-not (Test-SmbPort)) {
        Write-Err "$RouterIP`:445 未开放，无法映射。"
        Write-Host "排查: 路由器 Samba 是否启用；是否有防火墙；Padavan 可能仅支持 SMBv1。" -ForegroundColor Yellow
        return
    }

    $unc = "\\$RouterIP\$Share"
    $useDrive = Find-FreeDrive $Drive
    if ($useDrive -ne $Drive) { Write-Warn "盘符 ${Drive}: 已占用，改用 ${useDrive}:" }

    if (Test-Path "${useDrive}:\") {
        if (-not (Confirm-Plan "断开已有 ${useDrive}: 映射并重新映射?")) { return }
        net use "${useDrive}:" /delete /y 2>$null | Out-Null
    }

    $netArgs = @("use", "${useDrive}:", $unc, "/persistent:no")
    if ($SmbUser) {
        $netArgs += "/user:$SmbUser"
        if ($SmbPass) { $netArgs += $SmbPass }
    }

    if ($DryRun) {
        Write-Plan ("net " + ($netArgs -join " "))
        return
    }

    $out = & net @netArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "已映射 ${useDrive}: -> $unc"
        Write-Host "提示: 若资源管理器打不开，先在 '启用或关闭 Windows 功能' 勾选 SMB 1.0/CIFS。" -ForegroundColor Gray
    } else {
        Write-Err "映射失败: $out"
        Write-Host "可尝试:" -ForegroundColor Yellow
        Write-Host "  net use * /delete /y"
        Write-Host "  .\2_setup_dual_nic_and_nas.ps1 -Action Map -SmbUser admin -SmbPass admin"
    }
}

# ---------------------------------------------------------------- restore
function Invoke-Restore {
    Ensure-Admin
    Write-Head "恢复原始网络配置"
    if (-not (Test-Path $BackupFile)) {
        Write-Err "找不到快照: $BackupFile"
        return
    }
    $snap = Get-Content $BackupFile -Raw | ConvertFrom-Json
    Write-Host "快照时间: $($snap.timestamp)"
    foreach ($a in $snap.adapters) {
        Write-Host ("  [{0}] {1}  dhcp={2}  ip={3}" -f $a.InterfaceIndex, $a.Name, $a.Dhcp, ($a.IPAddresses -join ','))
    }

    if ($DryRun) { Write-Plan "(DryRun) 未修改"; return }
    if (-not (Confirm-Plan "把上述适配器恢复到快照状态?")) { return }

    foreach ($a in $snap.adapters) {
        $adp = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adp) { Write-Warn "适配器 $($a.Name) 已不存在，跳过"; continue }

        Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $a.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        if ($a.Dhcp -ne 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $a.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue
            $ips  = @($a.IPAddresses)
            $pfxs = @($a.PrefixLengths)
            $gws  = @($a.Gateways)
            for ($i = 0; $i -lt $ips.Count; $i++) {
                $ip = $ips[$i]
                if (-not $ip) { continue }
                $pfx = if ($i -lt $pfxs.Count -and $pfxs[$i]) { $pfxs[$i] } else { 24 }
                New-NetIPAddress -InterfaceIndex $a.InterfaceIndex -IPAddress $ip -PrefixLength $pfx -ErrorAction SilentlyContinue | Out-Null
            }
            foreach ($gw in $gws) {
                if ($gw -and $gw -ne '0.0.0.0') {
                    New-NetRoute -InterfaceIndex $a.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
                }
            }
        } else {
            Set-NetIPInterface -InterfaceIndex $a.InterfaceIndex -Dhcp Enabled -ErrorAction SilentlyContinue
        }
        if ($a.InterfaceMetric -and $a.InterfaceMetric -gt 0) {
            Set-NetIPInterface -InterfaceIndex $a.InterfaceIndex -InterfaceMetric $a.InterfaceMetric -ErrorAction SilentlyContinue
        }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-Ok "已按快照恢复。建议重启网络适配器或重启电脑以确保生效。"
}

# ---------------------------------------------------------------- menu
function Show-Menu {
    while ($true) {
        Write-Head "R3G Dorm Lab - 双网卡与 NAS"
        Write-Host "  1. 查看当前适配器与路由 (只读)"
        Write-Host "  2. 配置 USB 网卡 (优先 DHCP, 必要时静态)"
        Write-Host "  3. 连通性验证"
        Write-Host "  4. 映射 Samba 共享"
        Write-Host "  5. 从快照恢复网络"
        Write-Host "  0. 退出"
        $c = Read-Host "请选择"
        switch ($c) {
            "1" { Show-Adapters }
            "2" { Invoke-Apply }
            "3" { Invoke-Test }
            "4" { Invoke-Map }
            "5" { Invoke-Restore }
            "0" { return }
            default { Write-Warn "无效选择" }
        }
    }
}

switch ($Action) {
    "Inspect" { Show-Adapters }
    "Apply"   { Invoke-Apply }
    "Map"     { Invoke-Map }
    "Test"    { Invoke-Test }
    "Restore" { Invoke-Restore }
    default   { Show-Menu }
}
