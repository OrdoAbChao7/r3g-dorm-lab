<#
  WifiProxyMode 卸载 / 回滚脚本

  恢复为安装前的状态：
    - 删除计划任务 WifiProxyMode（以及备用任务 WifiProxyMode-Logon）
    - 恢复用户环境变量 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY
    - 恢复 git 全局 http.proxy / https.proxy
    - 把 Clash Verge 的 enable_system_proxy 恢复为 true
  恢复值取自 proxy_setup\backup\ 下最近一次安装的备份；没有备份时使用下面记录的原始值。
#>

$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupDir = Join-Path $here 'backup'

Write-Host '[1/4] 删除计划任务 ...'
$ErrorActionPreference = 'Continue'
foreach ($t in 'WifiProxyMode','WifiProxyMode-Net','WifiProxyMode-Logon') {
  & schtasks.exe /Delete /TN $t /F *> $null
  try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
}
$ErrorActionPreference = 'Stop'

Write-Host '[2/4] 恢复用户环境变量 ...'
$defaults = [ordered]@{
  HTTP_PROXY  = 'http://127.0.0.1:7897'
  HTTPS_PROXY = 'http://127.0.0.1:7897'
  ALL_PROXY   = 'http://127.0.0.1:7897'
  NO_PROXY    = 'localhost,127.0.0.1,::1'
}
$envBackup = $null
$latestEnv = Get-ChildItem -LiteralPath $backupDir -Filter 'user-env-proxy-*.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestEnv) {
  try { $envBackup = Get-Content -LiteralPath $latestEnv.FullName -Raw | ConvertFrom-Json } catch { }
}
foreach ($n in $defaults.Keys) {
  $value = $null
  if ($envBackup -and $envBackup.PSObject.Properties.Name -contains $n) { $value = $envBackup.$n }
  if ([string]::IsNullOrEmpty($value)) { $value = $defaults[$n] }
  [Environment]::SetEnvironmentVariable($n, $value, 'User')
}

Write-Host '[3/4] 恢复 git 全局代理 ...'
$gitBackup = $null
$latestGit = Get-ChildItem -LiteralPath $backupDir -Filter 'git-proxy-*.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestGit) {
  try { $gitBackup = Get-Content -LiteralPath $latestGit.FullName -Raw | ConvertFrom-Json } catch { }
}
$httpProxy = 'http://127.0.0.1:7897'
$httpsProxy = 'http://127.0.0.1:7897'
if ($gitBackup) {
  if ($gitBackup.'http.proxy')  { $httpProxy  = $gitBackup.'http.proxy' }
  if ($gitBackup.'https.proxy') { $httpsProxy = $gitBackup.'https.proxy' }
}
& git config --global http.proxy  $httpProxy
& git config --global https.proxy $httpsProxy

Write-Host '[4/4] 恢复 Clash Verge 的系统代理开关 ...'
$vergeYaml = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\verge.yaml'
if (Test-Path -LiteralPath $vergeYaml) {
  try {
    $text = Get-Content -LiteralPath $vergeYaml -Raw
    $new  = [regex]::Replace($text, '(?m)^enable_system_proxy:\s*false\s*$', 'enable_system_proxy: true')
    if ($new -ne $text) { [System.IO.File]::WriteAllText($vergeYaml, $new, (New-Object System.Text.UTF8Encoding($false))) }
  } catch {
    Write-Warning 'verge.yaml 修改失败（文件可能被占用），请在 Clash Verge 界面里手动打开“系统代理”。'
  }
}

Write-Host ''
Write-Host '已回滚。当前用户环境下一次新开终端生效；如仍在旧终端里，可重开终端或手动 unset。'
