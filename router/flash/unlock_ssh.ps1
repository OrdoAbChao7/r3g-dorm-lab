<#
.SYNOPSIS
    Launch OpenWRTInvasion against the stock Xiaomi R3G (SSH/Telnet/FTP unlock).

.DESCRIPTION
    Pre-flight: verifies the router is actually reachable on the local link,
    then runs the upstream exploit interactively in its own directory with
    proxies disabled for the target IP.

    The router admin password is typed into the local console by you. This
    script never stores, logs or transmits it.

    This does NOT flash anything. It only starts telnet/ssh/ftp on the stock
    firmware. Reboot the router to drop those services.

.EXAMPLE
    .\unlock_ssh.ps1
.EXAMPLE
    .\unlock_ssh.ps1 -RouterIP 192.168.31.1
#>

param(
    [string]$RouterIP = "192.168.31.1",
    [switch]$SkipChecks
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ToolDir = Join-Path $PSScriptRoot "OpenWRTInvasion"
$Script = Join-Path $ToolDir "remote_command_execution_vulnerability.py"

function Write-Head([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor Cyan
}

function Write-Warn([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }

function Test-Tcp([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

if (-not (Test-Path $Script)) {
    Write-Error "找不到 $Script"
    exit 2
}

Write-Head "OpenWRTInvasion 预检"
Write-Host "目标: $RouterIP"
Write-Host "工具: $ToolDir"

if (-not $SkipChecks) {
    $ping = Test-Connection -ComputerName $RouterIP -Count 1 -Quiet -ErrorAction SilentlyContinue
    $http = Test-Tcp $RouterIP 80
    $ssh  = Test-Tcp $RouterIP 22
    Write-Host ("ICMP: {0}   TCP80: {1}   TCP22: {2}" -f $ping, $http, $ssh)

    if (-not ($ping -or $http -or $ssh)) {
        Write-Host ""
        Write-Host "路由器在当前链路上不可达，已停止，不会运行漏洞脚本。" -ForegroundColor Red
        Write-Host ""
        Write-Host "连接检查清单:" -ForegroundColor Yellow
        Write-Host "  1. 路由器已通电，LAN 口指示灯正常"
        Write-Host "  2. USB/内置网线接在 R3G 的 LAN 口（不是 WAN）"
        Write-Host "  3. 该网卡拿到 192.168.31.x 地址（DHCP），或手动设为 192.168.31.2/24"
        Write-Host "  4. 或者把笔记本 Wi-Fi 连到 R3G 的 SSID"
        Write-Host "  5. 确认没有代理/VPN 劫持 192.168.31.1"
        Write-Host ""
        Write-Host "当前带 192.168.31.x 地址的网卡:" -ForegroundColor Gray
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like '192.168.31.*' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength |
            Format-Table -AutoSize | Out-String -Width 120 | Write-Host
        exit 3
    }
} else {
    Write-Host "已跳过连通性检查 (-SkipChecks)" -ForegroundColor Yellow
}

# The exploit must reach the router directly, never through Clash/v2rayN.
$env:NO_PROXY = "$RouterIP,127.0.0.1,localhost"
$env:no_proxy = $env:NO_PROXY
Remove-Item Env:HTTP_PROXY  -ErrorAction SilentlyContinue
Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
Remove-Item Env:ALL_PROXY   -ErrorAction SilentlyContinue
Remove-Item Env:http_proxy  -ErrorAction SilentlyContinue
Remove-Item Env:https_proxy -ErrorAction SilentlyContinue
Remove-Item Env:all_proxy   -ErrorAction SilentlyContinue

Write-Head "接下来在上游脚本里输入"
Write-Host "  1) Router IP      -> $RouterIP (直接回车即可)"
Write-Host "  2) 管理密码        -> 你输入，不会保存"
Write-Host "  3) 文件来源        -> 1 (本地 TCP 文件服务器，路由器无需外网)"
Write-Host ""
Write-Host "按回车启动..." -ForegroundColor Gray
Read-Host | Out-Null

Push-Location $ToolDir
try {
    & python $Script
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Head "结果检测"
$p21 = Test-Tcp $RouterIP 21
$p22 = Test-Tcp $RouterIP 22
$p23 = Test-Tcp $RouterIP 23
Write-Host ("FTP 21: {0}   SSH 22: {1}   Telnet 23: {2}" -f $p21, $p22, $p23)

if ($p22 -or $p23) {
    Write-Host ""
    Write-Host "解锁成功（默认 root/root；首次登录后请修改）" -ForegroundColor Green
    Write-Host "下一步（只读备份）:"
    Write-Host "  scp .\router\flash\backup_readonly.sh root@${RouterIP}:/tmp/"
    Write-Host "  ssh root@${RouterIP} `"sh /tmp/backup_readonly.sh`""
    Write-Host ""
    Write-Host "重要: 不刷机时，重启路由器即可关闭 telnet/ftp/ssh。" -ForegroundColor Yellow
} else {
    Write-Warn "22/23 仍未开放。若上游脚本报错，可能是固件已修补该漏洞。"
    Write-Host "备选路线: 官方开发者固件 + miwifi_ssh.bin（需要小米账号与 U 盘）。"
}

exit $code
