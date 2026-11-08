# Read-only scan of serial ports for the R3G lab.
# Lists present COM ports, flags the R3G CH340 (never flash it) and ESP32 candidates.
$ErrorActionPreference = "Continue"
$r3g = "1A86:7523"
$esp = @("303A:1001", "303A:4001", "1A86:55D3", "10C4:EA60", "0403:6001")

"=== Present Ports-class devices ==="
Get-PnpDevice -Class Ports -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
    $m = [regex]::Match($_.InstanceId, 'VID[_&]([0-9A-Fa-f]{4})[&+]PID[_&]([0-9A-Fa-f]{4})')
    $vidpid = if ($m.Success) { ($m.Groups[1].Value + ":" + $m.Groups[2].Value).ToUpper() } else { "?" }
    $tag = if ($vidpid -eq $r3g) { "R3G UART - DO NOT FLASH" }
           elseif ($esp -contains $vidpid) { "ESP32 CANDIDATE" }
           else { "" }
    "{0,-34} {1,-10} {2}" -f $_.FriendlyName, $vidpid, $tag
}

"=== Problem USB devices (enumeration failures) ==="
Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -ne "OK" } |
    ForEach-Object { "{0,-8} {1}  {2}" -f $_.Status, $_.FriendlyName, $_.InstanceId }

"=== SerialPort.GetPortNames() ==="
[System.IO.Ports.SerialPort]::GetPortNames() -join ", "
