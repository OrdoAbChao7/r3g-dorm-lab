# Read-only diagnostic: force a real WLAN scan through the native wlanapi,
# then print the refreshed visible-network list. Changes no adapter setting,
# no profile, no route, and does not connect to anything.
param(
    [string]$InterfaceGuid = "",
    [int]$WaitSeconds = 8
)

$ErrorActionPreference = "Stop"

if (-not $InterfaceGuid) {
    $out = (netsh wlan show interfaces) -join "`n"
    $m = [regex]::Match($out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    if (-not $m.Success) { throw "Cannot find a WLAN interface GUID." }
    $InterfaceGuid = $m.Groups[1].Value
}

$sig = @"
using System;
using System.Runtime.InteropServices;
public static class R3GWlanScan {
    [DllImport("wlanapi.dll")]
    public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
    [DllImport("wlanapi.dll")]
    public static extern uint WlanScan(IntPtr hClientHandle, ref Guid pInterfaceGuid, IntPtr pDot11Ssid, IntPtr pIeData, IntPtr pReserved);
    [DllImport("wlanapi.dll")]
    public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
}
"@
Add-Type -TypeDefinition $sig

$negotiated = 0
$handle = [IntPtr]::Zero
$rc = [R3GWlanScan]::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$negotiated, [ref]$handle)
if ($rc -ne 0) { throw "WlanOpenHandle failed: $rc" }

try {
    $guid = [Guid]$InterfaceGuid
    $rc2 = [R3GWlanScan]::WlanScan($handle, [ref]$guid, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    "WlanScan rc=$rc2 guid=$InterfaceGuid"
    if ($rc2 -ne 0) { throw "WlanScan failed: $rc2" }
}
finally {
    [void][R3GWlanScan]::WlanCloseHandle($handle, [IntPtr]::Zero)
}

Start-Sleep -Seconds $WaitSeconds
netsh wlan show networks mode=bssid
