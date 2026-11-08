<#
  WifiProxyMode 安装脚本

  做的事情：
    1. 把当前的代理相关配置备份到 proxy_setup\backup\（环境变量、git 全局代理、WinINET 设置、verge.yaml）。
    2. 删除用户环境变量里的 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY
       （它们写死指向 127.0.0.1:7897，Clash 一关就会让终端工具连不上）。
    3. 删除 git 全局 http.proxy / https.proxy（git 会改为跟随环境变量，由自动脚本按网络设置）。
    4. 尽量把 Clash Verge 的“系统代理”开关置为关闭（交给自动脚本统一管理）。
    5. 注册计划任务（不需要管理员权限）：
         WifiProxyMode      每分钟运行一次，兜底
         WifiProxyMode-Net  网络连接/断开事件触发，切换后几秒内生效
    6. 立即运行一次，让当前状态生效。

  回滚：运行 uninstall.ps1。
#>

$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupDir = Join-Path $here 'backup'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$vergeDir  = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$vergeYaml = Join-Path $vergeDir 'verge.yaml'

Write-Host '[1/6] 备份现有配置 ...'
& reg.exe export 'HKCU\Environment' (Join-Path $backupDir "HKCU-Environment-$stamp.reg") /y | Out-Null

$envBackup = [ordered]@{}
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
  $envBackup[$n] = [Environment]::GetEnvironmentVariable($n, 'User')
}
$envBackup | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupDir "user-env-proxy-$stamp.json") -Encoding UTF8

$gitBackup = [ordered]@{
  'http.proxy'  = [string](& git config --global --get http.proxy 2>$null)
  'https.proxy' = [string](& git config --global --get https.proxy 2>$null)
}
$gitBackup | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupDir "git-proxy-$stamp.json") -Encoding UTF8

$inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$inetBackup = [ordered]@{
  ProxyEnable   = $inet.ProxyEnable
  ProxyServer   = $inet.ProxyServer
  ProxyOverride = $inet.ProxyOverride
  AutoConfigURL = $inet.AutoConfigURL
}
$inetBackup | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupDir "wininet-proxy-$stamp.json") -Encoding UTF8

if (Test-Path -LiteralPath $vergeYaml) {
  Copy-Item -LiteralPath $vergeYaml -Destination (Join-Path $backupDir "verge.yaml.$stamp") -Force
}

Write-Host '[2/6] 移除用户环境变量中的代理设置 ...'
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
  [Environment]::SetEnvironmentVariable($n, $null, 'User')
}

Write-Host '[3/6] 移除 git 全局代理 ...'
& git config --global --unset http.proxy 2>$null
& git config --global --unset https.proxy 2>$null

Write-Host '[4/6] 关闭 Clash Verge 自带的系统代理开关（脚本将接管这一项）...'
if (Test-Path -LiteralPath $vergeYaml) {
  try {
    $text = Get-Content -LiteralPath $vergeYaml -Raw
    $new  = [regex]::Replace($text, '(?m)^enable_system_proxy:\s*true\s*$', 'enable_system_proxy: false')
    if ($new -ne $text) {
      [System.IO.File]::WriteAllText($vergeYaml, $new, (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {
    Write-Warning 'verge.yaml 修改失败（文件可能被占用），跳过；自动脚本仍会持续纠正系统代理开关。'
  }
}

Write-Host '[5/6] 注册计划任务 ...'
$script = Join-Path $here 'proxy-mode.ps1'
$runner = Join-Path $here 'run-proxy-mode.cmd'

$registered = $false
try {
  & schtasks.exe /Create /TN 'WifiProxyMode' /TR $runner /SC MINUTE /MO 1 /F 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw '每分钟任务创建失败' }

  & schtasks.exe /Create /TN 'WifiProxyMode-Net' /TR $runner /SC ONEVENT /EC 'Microsoft-Windows-NetworkProfile/Operational' /MO '*[System[EventID=10000 or EventID=10001]]' /F 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw '网络事件任务创建失败' }

  $registered = $true
} catch {
  Write-Warning ('计划任务注册失败：{0}' -f $_.Exception.Message)
}

# 清理历史遗留的登录触发任务；不存在时 schtasks 会报错，忽略即可
$ErrorActionPreference = 'Continue'
& schtasks.exe /Delete /TN 'WifiProxyMode-Logon' /F *> $null
$ErrorActionPreference = 'Stop'

Write-Host '[6/6] 立即执行一次切换 ...'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Mode auto

if ($registered) {
  Write-Host ''
  Write-Host '完成。当前模式：'
  Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'WifiProxyMode\mode.txt') -ErrorAction SilentlyContinue
  Write-Host ''
  Write-Host '说明：router=路由器代理（本机不挂代理）/ clash=本机 Clash / direct=直连。'
} else {
  Write-Host '计划任务未成功注册；自动切换不会生效，请检查 schtasks 权限。'
}
