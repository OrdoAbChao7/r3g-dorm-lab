<#
  Wake-on-LAN Magic Packet sender.
  Run this on ANOTHER device (not the laptop being woken).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\wol-send.ps1
    powershell -ExecutionPolicy Bypass -File .\wol-send.ps1 -Mac "AA-BB-CC-DD-EE-04" -Broadcast 192.168.31.255

  -Mac        target NIC MAC (native Realtek 2.5GbE by default)
  -Broadcast  subnet broadcast address (Xiaomi router default LAN: 192.168.31.0/24)
  -Ports      UDP ports to try, 9 and 7 by default
  -Count      packets per port
#>
param(
    [string]$Mac = "AA-BB-CC-DD-EE-04",
    [string]$Broadcast = "192.168.31.255",
    [int[]]$Ports = @(9, 7),
    [int]$Count = 3
)

$macBytes = $Mac -split '[-:]' | ForEach-Object { [Convert]::ToByte($_, 16) }
if ($macBytes.Count -ne 6) { throw "Bad MAC: $Mac" }

$payload = [byte[]](@(0xFF) * 6 + ($macBytes * 16))
Write-Host ("Magic packet: {0} bytes, target MAC {1}" -f $payload.Length, $Mac)

$udp = New-Object System.Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
try {
    foreach ($p in $Ports) {
        for ($i = 0; $i -lt $Count; $i++) {
            [void]$udp.Send($payload, $payload.Length, $Broadcast, $p)
            Write-Host ("  sent -> {0}:{1}" -f $Broadcast, $p)
            Start-Sleep -Milliseconds 300
        }
    }
} finally {
    $udp.Close()
}
Write-Host "Done."
