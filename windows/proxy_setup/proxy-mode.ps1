<#
  WifiProxyMode —— 让本机代理跟随网络自动切换

  规则（auto 模式）：
    1. 当前网络已经是透明代理（系统 DNS 对随机探测域名返回 198.18.0.0/15 的 fake-IP，
       说明路由器在接管 DNS 和流量）→ 关闭本机系统代理与代理环境变量。
    2. 否则，如果本地 Clash 的 mixed-port 127.0.0.1:7897 在监听 → 打开系统代理并设置
       HTTP_PROXY/HTTPS_PROXY/ALL_PROXY（这些变量只影响之后新启动的进程）。
    3. 两者都没有 → 直连，不留任何代理配置。

  手动模式：
    -Mode router  强制按"路由器代理"处理（关闭本机代理）
    -Mode clash   强制按"本地 Clash"处理（打开本机代理）
    -Mode direct  强制直连（关闭本机代理，环境变量也清掉）
#>
param(
  [ValidateSet('auto','router','clash','direct')]
  [string]$Mode = 'auto'
)

$ErrorActionPreference = 'Stop'

$stateDir = Join-Path $env:LOCALAPPDATA 'WifiProxyMode'
$logPath  = Join-Path $stateDir 'proxy-mode.log'
$modePath = Join-Path $stateDir 'mode.txt'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$inetKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyServer = '127.0.0.1:7897'
$proxyVars   = [ordered]@{
  HTTP_PROXY  = 'http://127.0.0.1:7897'
  HTTPS_PROXY = 'http://127.0.0.1:7897'
  ALL_PROXY   = 'http://127.0.0.1:7897'
  NO_PROXY    = 'localhost,127.0.0.1,::1'
}

function Write-Log {
  param([string]$Message)
  try {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    $fi = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -gt 262144) {
      $tail = Get-Content -LiteralPath $logPath -Tail 500
      Set-Content -LiteralPath $logPath -Value $tail -Encoding UTF8
    }
  } catch { }
}

# 探测当前网络的 DNS 是否被透明代理接管：对随机子域名做解析，
# 若返回 198.18.0.0/15（fake-IP 段）则说明路由器在代理。
function Test-RouterTransparentProxy {
  $name = 'probe-{0}.example.com' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    $answers = Resolve-DnsName -Name $name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
    foreach ($a in $answers) {
      if ($a.Type -eq 'A' -and $a.IPAddress) {
        $bytes = ([System.Net.IPAddress]::Parse($a.IPAddress)).GetAddressBytes()
        if ($bytes[0] -eq 198 -and ($bytes[1] -eq 18 -or $bytes[1] -eq 19)) { return $true }
      }
    }
  } catch { }
  return $false
}

function Test-ClashAlive {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect('127.0.0.1', 7897, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(400)) { return $false }
    $client.EndConnect($async)
    return [bool]$client.Connected
  } catch { return $false }
  finally { try { $client.Close() } catch { } }
}

function Set-SystemProxy {
  param([bool]$Enabled)
  $changed = $false
  $cur = Get-ItemProperty -Path $inetKey -ErrorAction SilentlyContinue
  if ($Enabled) {
    if ($cur.ProxyServer -ne $proxyServer) {
      Set-ItemProperty -Path $inetKey -Name ProxyServer -Value $proxyServer
      $changed = $true
    }
    if ($cur.ProxyEnable -ne 1) {
      Set-ItemProperty -Path $inetKey -Name ProxyEnable -Value 1 -Type DWord
      $changed = $true
    }
  } else {
    if ($cur.ProxyEnable -ne 0) {
      Set-ItemProperty -Path $inetKey -Name ProxyEnable -Value 0 -Type DWord
      $changed = $true
    }
  }
  if ($changed) {
    if (-not ('WifiProxyMode.WinInet' -as [type])) {
      Add-Type -Namespace WifiProxyMode -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
    }
    [WifiProxyMode.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WifiProxyMode.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
  }
}

# 只修改用户级环境变量，影响的是之后新启动的进程；已经运行的程序不受影响。
function Set-UserProxyEnv {
  param([bool]$Enabled)
  foreach ($name in $proxyVars.Keys) {
    $want = if ($Enabled) { $proxyVars[$name] } else { $null }
    $cur  = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($cur -ne $want) {
      [Environment]::SetEnvironmentVariable($name, $want, 'User')
    }
  }
}

$router = $false
$clash  = $false
switch ($Mode) {
  'router' { $router = $true }
  'clash'  { $clash  = $true }
  'direct' { }
  default {
    $router = Test-RouterTransparentProxy
    if (-not $router) { $clash = Test-ClashAlive }
  }
}

if ($router) {
  $desired = 'router'
  Set-SystemProxy   -Enabled $false
  Set-UserProxyEnv  -Enabled $false
} elseif ($clash) {
  $desired = 'clash'
  Set-SystemProxy   -Enabled $true
  Set-UserProxyEnv  -Enabled $true
} else {
  $desired = 'direct'
  Set-SystemProxy   -Enabled $false
  Set-UserProxyEnv  -Enabled $false
}

$previous = ''
try {
  $previous = ((Get-Content -LiteralPath $modePath -ErrorAction Stop) | Select-Object -First 1).Trim()
} catch { }

if ($previous -ne $desired) {
  Write-Log ('mode {0} -> {1} (router={2}, clash={3}, override={4})' -f $previous, $desired, $router, $clash, $Mode)
  Set-Content -LiteralPath $modePath -Value $desired -Encoding ASCII
} elseif ($Mode -ne 'auto') {
  Write-Log ('mode {0} unchanged (override={1})' -f $desired, $Mode)
}

if ($Mode -ne 'auto') {
  Write-Output ('mode={0} router={1} clash={2}' -f $desired, $router, $clash)
}
