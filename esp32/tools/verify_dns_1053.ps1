$ErrorActionPreference = "SilentlyContinue"
$servers = @("192.168.1.53", "192.168.1.1")
$domains = @(
    "pagead2.googlesyndication.com",
    "googlesyndication.com",
    "www.baidu.com",
    "www.google.com",
    "example.com"
)

foreach ($s in $servers) {
    Write-Output "=== server $s ==="
    foreach ($d in $domains) {
        $a = Resolve-DnsName -Server $s -Name $d -Type A -ErrorAction SilentlyContinue
        $aaaa = Resolve-DnsName -Server $s -Name $d -Type AAAA -ErrorAction SilentlyContinue
        $aips = ($a | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) -join ','
        $aaaips = ($aaaa | Where-Object { $_.Type -eq 'AAAA' } | ForEach-Object { $_.IPAddress }) -join ','
        if (-not $aips) { $aips = 'NO_A' }
        if (-not $aaaips) { $aaaips = 'NO_AAAA' }
        Write-Output ("{0,-42} A={1,-12} AAAA={2}" -f $d, $aips, $aaaips)
    }
}

Write-Output "=== TCP via 192.168.1.53 ==="
$t = Resolve-DnsName -Server 192.168.1.53 -Name pagead2.googlesyndication.com -Type A -TcpOnly -ErrorAction SilentlyContinue
$tips = ($t | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) -join ','
if (-not $tips) { $tips = 'NO_A' }
Write-Output ("TCP pagead2 A={0}" -f $tips)
