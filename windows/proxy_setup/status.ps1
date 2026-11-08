<#
  WifiProxyMode 状态查看

  只读：显示当前模式、系统代理、用户环境变量、检测结果和计划任务状态。
#>

$stateDir = Join-Path $env:LOCALAPPDATA 'WifiProxyMode'
$modePath = Join-Path $stateDir 'mode.txt'
$logPath  = Join-Path $stateDir 'proxy-mode.log'

$mode = '(未生成)'
if (Test-Path -LiteralPath $modePath) {
  $mode = ((Get-Content -LiteralPath $modePath) | Select-Object -First 1).Trim()
}

$inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue

Write-Host '=== 当前模式 ==='
Write-Host ("mode.txt          : {0}" -f $mode)
Write-Host ("系统代理 ProxyEnable: {0}" -f $inet.ProxyEnable)
Write-Host ("ProxyServer       : {0}" -f $inet.ProxyServer)
Write-Host ''
Write-Host '=== 用户环境变量 ==='
foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY') {
  $v = [Environment]::GetEnvironmentVariable($n, 'User')
  if ([string]::IsNullOrEmpty($v)) { $v = '(未设置)' }
  Write-Host ("{0,-12}: {1}" -f $n, $v)
}
Write-Host ''
Write-Host '=== 实时探测 ==='
$probe = 'probe-{0}.example.com' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
$fake = $false
try {
  $answers = Resolve-DnsName -Name $probe -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
  foreach ($a in $answers) {
    if ($a.Type -eq 'A' -and $a.IPAddress) {
      $bytes = ([System.Net.IPAddress]::Parse($a.IPAddress)).GetAddressBytes()
      if ($bytes[0] -eq 198 -and ($bytes[1] -eq 18 -or $bytes[1] -eq 19)) { $fake = $true }
    }
  }
} catch { }
Write-Host ("路由器透明代理探测 : {0}" -f $(if ($fake) { '是（返回 fake-IP）' } else { '否' }))

$clash = $false
$client = New-Object System.Net.Sockets.TcpClient
try {
  $async = $client.BeginConnect('127.0.0.1', 7897, $null, $null)
  if ($async.AsyncWaitHandle.WaitOne(400)) { $client.EndConnect($async); $clash = [bool]$client.Connected }
} catch { } finally { try { $client.Close() } catch { } }
Write-Host ("本地 Clash 7897    : {0}" -f $(if ($clash) { '在监听' } else { '未监听' }))
Write-Host ''
Write-Host '=== 计划任务 ==='
& schtasks.exe /Query /TN 'WifiProxyMode' /FO LIST 2>$null | Select-String -Pattern '任务名|状态|下次运行时间|Last Run|Next Run|Status|Schema'
Write-Host ''
Write-Host '=== 最近日志 ==='
if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 10 } else { Write-Host '(暂无日志)' }
