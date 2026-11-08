<#
.SYNOPSIS
    Show / apply / roll back 192.168.31.100/24 on the Realtek Gaming USB
    2.5GbE adapter only, with target-interface ARP/DAD checks.

.DESCRIPTION
    Safety boundaries:
      * Target requires BOTH InterfaceGuid and MAC, matching
        InterfaceDescription (Realtek + USB + 2.5GbE) and PNP status OK/Present.
      * Apply/Rollback never touch Wi-Fi, WLAN metric, default routes, Clash,
        system proxy, TUN or firewall.
      * Apply requires a complete, reliable IPv4+IPv6 DNS snapshot (query
        success and source known). If DNS cannot be read reliably, Apply is
        refused before any network change.
      * Apply sets no default gateway and no DNS. Rollback restores DNS only
        when a state explicitly records DnsTouched=$true; this Apply path
        never sets that flag.
      * DHCP-origin addresses are never re-created with New-NetIPAddress.
        Rollback re-enables DHCP, waits for a valid DHCP lease, and restores
        only PrefixOrigin=Manual addresses via New-NetIPAddress.
      * Rollback re-checks GUID/MAC/DHCP/manual/DNS state; only a full match
        returns ROLLBACK_VERIFIED. DHCP lease timeout is ROLLBACK_PENDING;
        DNS query uncertainty is INCONCLUSIVE.
      * -SelfTest runs pure logic and mock-operations tests only (no network
        changes); all restore tests use an injected operations adapter.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\set_wired_ip.ps1 -Show
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\set_wired_ip.ps1 -SelfTest
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\set_wired_ip.ps1 -Apply `
        -InterfaceGuid "{GUID}" -MacAddress "AA-BB-CC-DD-EE-FF" `
        -IUnderstandThisChangesTheWiredAdapter -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$MacAddress = "",
    [string]$InterfaceGuid = "",
    [string]$Address = "192.168.31.100",
    [int]$PrefixLength = 24,
    [switch]$Show,
    [switch]$Apply,
    [switch]$Rollback,
    [switch]$SelfTest,
    [switch]$IUnderstandThisChangesTheWiredAdapter,
    [string]$StateDir = "",
    [int]$DadTimeoutSeconds = 10,
    [int]$DhcpTimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $StateDir) { $StateDir = Join-Path $scriptDir "..\reports\netcfg" }

function Normalize-Mac([string]$mac) {
    return ($mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function Normalize-Guid([string]$guid) {
    try { return ([guid]$guid).ToString("B").ToUpperInvariant() } catch { return $null }
}

function Get-DnsSourceFromRegistry([string]$guid, [string]$family) {
    $sub = if ($family -eq "IPv6") { "Tcpip6" } else { "Tcpip" }
    $path = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$sub\Parameters\Interfaces\$guid"
    try {
        $key = Get-Item -LiteralPath $path -ErrorAction Stop
        $nameServer = [string]$key.GetValue("NameServer", "")
        $dhcpNameServer = [string]$key.GetValue("DhcpNameServer", "")
        $enableDhcp = $key.GetValue("EnableDHCP", $null)
        if ($nameServer.Trim()) { return "Manual" }
        if ($dhcpNameServer.Trim()) { return "Dhcp" }
        if ($null -ne $enableDhcp -and [int]$enableDhcp -eq 1) { return "Dhcp" }
        return "Empty"
    } catch { return "Unknown" }
}

function New-RealOps {
    return [pscustomobject]@{
        GetAdapters = { @(Get-NetAdapter -ErrorAction Stop) }
        GetPnp = { param($id) Get-PnpDevice -InstanceId $id -ErrorAction Stop }
        GetIpAddresses = { param($idx) @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop) }
        GetIpInterface = { param($idx) Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction Stop }
        RemoveIpAddress = { param($idx, $ip, $prefix)
            Remove-NetIPAddress -InterfaceIndex $idx -IPAddress $ip -PrefixLength $prefix `
                -Confirm:$false -ErrorAction Stop }
        SetDhcp = { param($idx, $enabled)
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp $enabled -ErrorAction Stop }
        AddIpAddress = { param($idx, $ip, $prefix, $skip)
            $params = @{ InterfaceIndex = $idx; IPAddress = $ip; PrefixLength = [int]$prefix; ErrorAction = "Stop" }
            if ($skip) { $params["SkipAsSource"] = $true }
            New-NetIPAddress @params | Out-Null }
        GetDns = { param($idx, $guid, $family)
            try {
                $r = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily $family -ErrorAction Stop
                $rows = @($r)
                if ($rows.Count -ne 1 -or -not $rows[0].PSObject.Properties['ServerAddresses']) {
                    return [pscustomobject]@{ Ok = $false; Servers = @(); Source = "Unknown"; Error = "incomplete DNS result" }
                }
                $servers = @($rows[0].ServerAddresses)
                $source = Get-DnsSourceFromRegistry $guid $family
                if ($servers.Count -gt 0 -and $source -eq "Empty") { $source = "Unknown" }
                return [pscustomobject]@{ Ok = $true; Servers = $servers; Source = $source; Error = "" }
            } catch {
                return [pscustomobject]@{ Ok = $false; Servers = @(); Source = "Unknown"; Error = $_.Exception.Message }
            } }
        SetDns = { param($idx, $family, $servers, $reset)
            if ($reset) {
                Set-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily $family -Reset -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily $family `
                    -ServerAddresses @($servers) -ErrorAction Stop
            } }
        GetRoutes = { @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
                        ForEach-Object { [pscustomobject]@{ DestinationPrefix = $_.DestinationPrefix; NextHop = $_.NextHop; InterfaceIndex = $_.InterfaceIndex; RouteMetric = $_.RouteMetric } }) }
        GetWlan = { @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                        $_.InterfaceDescription -match "Wi-?Fi|Wireless|802\.11"
                    } | ForEach-Object {
                        $wips = @(Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                  ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                        [pscustomobject]@{ InterfaceGuid = $_.InterfaceGuid; MacAddress = $_.MacAddress; IPv4 = $wips }
                    }) }
        Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
        Now = { Get-Date }
    }
}

$script:RealOps = $null
function Get-RealOps {
    if (-not $script:RealOps) { $script:RealOps = New-RealOps }
    return $script:RealOps
}

function Find-AdapterByGuid([string]$guid, $Ops = $null) {
    $want = Normalize-Guid $guid
    if (-not $want) { return @() }
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    return @((& $Ops.GetAdapters) |
             Where-Object { (Normalize-Guid $_.InterfaceGuid) -eq $want })
}

function Test-EligibleDescription([string]$desc) {
    return ($desc -match 'Realtek' -and $desc -match 'USB' -and
            $desc -match '2\.5\s*GbE' -and
            $desc -notmatch 'Wi-?Fi|Wireless|802\.11')
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-IdentityVerdict([bool]$guidOk, [bool]$macOk, [bool]$descOk, [bool]$pnpOk) {
    if ($guidOk -and $macOk -and $descOk -and $pnpOk) { return "Accept" }
    return "Reject"
}

function Get-AdapterPresenceVerdict([bool]$present, [bool]$macOk, [bool]$up) {
    if (-not $present) { return "Disappeared" }
    if (-not $macOk) { return "MacChanged" }
    if (-not $up) { return "LinkDown" }
    return "Online"
}

function Get-ConflictVerdict([bool]$localDuplicate, [string]$neighborState, [bool]$probeReplied) {
    # A reply or a neighbor entry proves occupation. No reply proves nothing.
    if ($localDuplicate) { return "Conflict" }
    if ($probeReplied) { return "Conflict" }
    switch ($neighborState) {
        "Reachable" { return "Conflict" }
        "Stale"     { return "Conflict" }
        "Delay"     { return "Conflict" }
        "Probe"     { return "Conflict" }
        "Incomplete" { return "Inconclusive" }
        "Unreachable" { return "Inconclusive" }
        default { return "Inconclusive" }
    }
}

function Get-DadVerdict([string]$state, [bool]$timedOut) {
    if ($timedOut) { return "Rollback" }
    switch ($state) {
        "Preferred" { return "Success" }
        "Duplicate" { return "Rollback" }
        "Invalid"   { return "Rollback" }
        "Deprecated" { return "Rollback" }
        ""          { return "Rollback" }
        default     { return "Inconclusive" }
    }
}

function Get-TargetAdapters {
    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $candidates = @($all | Where-Object {
        (Test-EligibleDescription $_.InterfaceDescription) -and $_.NdisPhysicalMedium -ne 9
    })
    if ($MacAddress) {
        $want = Normalize-Mac $MacAddress
        $candidates = @($candidates | Where-Object { (Normalize-Mac $_.MacAddress) -eq $want })
    }
    if ($InterfaceGuid) {
        $want = Normalize-Guid $InterfaceGuid
        $candidates = @($candidates | Where-Object { (Normalize-Guid $_.InterfaceGuid) -eq $want })
    }
    return $candidates
}

function Show-Adapters {
    Write-Host ""
    Write-Host "=== Network adapters (read-only) ===" -ForegroundColor Cyan
    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object InterfaceIndex)
    foreach ($a in $all) {
        $ips = @(Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $dhcp = (Get-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        $dad = (Get-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).DadTransmits
        $routes = @(Get-NetRoute -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" })
        $eligible = (Test-EligibleDescription $a.InterfaceDescription) -and $a.NdisPhysicalMedium -ne 9
        $mark = if ($eligible) { "TARGET-CANDIDATE" } else { "" }
        Write-Host ("[{0}] {1} {2}" -f $a.InterfaceIndex, $a.Name, $mark) -ForegroundColor $(if ($eligible) { "Green" } else { "Gray" })
        Write-Host ("    GUID: {0}" -f $a.InterfaceGuid)
        Write-Host ("    MAC : {0}" -f $a.MacAddress)
        Write-Host ("    Desc: {0}" -f $a.InterfaceDescription)
        Write-Host ("    PNP : {0}" -f $a.PnpDeviceID)
        Write-Host ("    DadTransmits: {0}" -f $dad)
        Write-Host ("    Status: {0}  Dhcp: {1}  IPv4: {2}  default-routes: {3}" -f `
            $a.Status, $dhcp, $(if ($ips.Count) { $ips -join ", " } else { "(none)" }), $routes.Count)
    }
    Write-Host ""
    Write-Host "Only Realtek + USB + 2.5GbE adapters are eligible. Wi-Fi is never touched." -ForegroundColor Yellow
    Write-Host "Apply/Rollback require BOTH -InterfaceGuid and -MacAddress." -ForegroundColor Yellow
    Write-Host ""
}

function Get-PnpStatus([string]$pnpDeviceId, $Ops = $null) {
    if (-not $pnpDeviceId) { return $null }
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    try { return (& $Ops.GetPnp $pnpDeviceId) } catch { return $null }
}

function Get-ExactTarget {
    if (-not $InterfaceGuid -or -not $MacAddress) {
        throw "Apply/Rollback requires BOTH -InterfaceGuid and -MacAddress."
    }
    $c = @(Get-TargetAdapters)
    if ($c.Count -eq 0) {
        throw "No eligible Realtek Gaming USB 2.5GbE adapter matches the supplied GUID+MAC."
    }
    if ($c.Count -gt 1) {
        throw "More than one eligible adapter; refusing to choose."
    }
    $a = $c[0]
    $guidOk = ((Normalize-Guid $a.InterfaceGuid) -eq (Normalize-Guid $InterfaceGuid))
    $macOk = ((Normalize-Mac $a.MacAddress) -eq (Normalize-Mac $MacAddress))
    $descOk = (Test-EligibleDescription $a.InterfaceDescription)
    $pnp = Get-PnpStatus $a.PnpDeviceID
    $pnpOk = [bool]($pnp -and $pnp.Present -eq $true -and $pnp.Status -eq "OK")
    $verdict = Get-IdentityVerdict $guidOk $macOk $descOk $pnpOk
    if ($verdict -ne "Accept") {
        throw ("Identity rejected: guidOk={0} macOk={1} descOk={2} pnpOk={3}" -f $guidOk, $macOk, $descOk, $pnpOk)
    }
    return $a
}

function Assert-AdapterOnline($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $matches = @(Find-AdapterByGuid $adapter.InterfaceGuid $Ops)
    if ($matches.Count -eq 0) { throw "adapter disappeared" }
    if ($matches.Count -gt 1) { throw "multiple adapters share the same GUID" }
    $a = $matches[0]
    $macOk = ((Normalize-Mac $a.MacAddress) -eq (Normalize-Mac $adapter.MacAddress))
    $descOk = (Test-EligibleDescription $a.InterfaceDescription)
    $pnp = Get-PnpStatus $a.PnpDeviceID $Ops
    $pnpOk = [bool]($pnp -and $pnp.Present -eq $true -and $pnp.Status -eq "OK")
    $up = ($a.Status -eq "Up")
    $verdict = Get-AdapterPresenceVerdict $true $macOk $up
    if ($verdict -ne "Online" -or -not $descOk -or -not $pnpOk) {
        throw ("adapter state changed: " + $verdict + " descOk=" + $descOk + " pnpOk=" + $pnpOk)
    }
    return $a
}

function Assert-AdapterPresent($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $matches = @(Find-AdapterByGuid $adapter.InterfaceGuid $Ops)
    if ($matches.Count -eq 0) { throw "adapter disappeared before rollback" }
    if ($matches.Count -gt 1) { throw "multiple adapters share the same GUID" }
    $a = $matches[0]
    if ((Normalize-Mac $a.MacAddress) -ne (Normalize-Mac $adapter.MacAddress)) {
        throw "adapter MAC changed before rollback"
    }
    if (-not (Test-EligibleDescription $a.InterfaceDescription)) {
        throw "adapter description changed before rollback"
    }
    $pnp = Get-PnpStatus $a.PnpDeviceID $Ops
    if (-not ($pnp -and $pnp.Present -eq $true -and $pnp.Status -eq "OK")) {
        throw "adapter PNP status is not OK before rollback"
    }
    return $a
}

function Test-AddressConfig {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        Write-Host "REFUSED: invalid IPv4 address." -ForegroundColor Red
        return $false
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        Write-Host "REFUSED: not an IPv4 address." -ForegroundColor Red
        return $false
    }
    if ($PrefixLength -ne 24) {
        Write-Host "REFUSED: PrefixLength must be 24 for this recovery link." -ForegroundColor Red
        return $false
    }
    $b = $parsed.GetAddressBytes()
    if (-not ($b[0] -eq 192 -and $b[1] -eq 168 -and $b[2] -eq 31)) {
        Write-Host "REFUSED: address must be inside 192.168.31.0/24." -ForegroundColor Red
        return $false
    }
    if ($b[3] -in @(0, 1, 255)) {
        Write-Host "REFUSED: .0/.1/.255 are not valid host addresses for this link." -ForegroundColor Red
        return $false
    }
    return $true
}

function Get-TargetNeighborState($adapter) {
    try {
        $n = Get-NetNeighbor -InterfaceIndex $adapter.InterfaceIndex -IPAddress $Address -ErrorAction Stop
        if ($n) { return [string]$n.State }
    } catch { }
    return "None"
}

function Test-LinkScopedProbe($adapter) {
    $src = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1)
    if ($src.Count -eq 0) {
        $src = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Select-Object -First 1)
    }
    if ($src.Count -eq 0) { return $false }
    try {
        $p = Start-Process -FilePath "ping.exe" -ArgumentList @("-S", $src[0].IPAddress, "-n", "1", "-w", "1000", $Address) `
            -Wait -PassThru -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

function Test-AddressConflict($adapter) {
    $localDuplicate = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -eq $Address }).Count -gt 0
    $neighbor = Get-TargetNeighborState $adapter
    $probe = Test-LinkScopedProbe $adapter
    $verdict = Get-ConflictVerdict $localDuplicate $neighbor $probe
    Write-Host ("Conflict check: localDuplicate={0} neighbor={1} probeReplied={2} => {3}" -f `
        $localDuplicate, $neighbor, $probe, $verdict) -ForegroundColor $(if ($verdict -eq "Conflict") { "Red" } else { "Yellow" })
    return $verdict
}

function Get-AddressOrigin($ip) {
    if ($ip.PSObject.Properties['PrefixOrigin']) { return [string]$ip.PrefixOrigin }
    return ""
}

function Get-AddressState($ip) {
    if ($null -eq $ip -or -not $ip.PSObject.Properties['AddressState']) { return $null }
    if ($null -eq $ip.AddressState) { return $null }
    return [string]$ip.AddressState
}

function Get-DadTransmitsFromOps($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    try { $iface = & $Ops.GetIpInterface $adapter.InterfaceIndex } catch { return $null }
    if (-not $iface.PSObject.Properties['DadTransmits']) { return $null }
    try { return [int]$iface.DadTransmits } catch { return $null }
}

function Wait-ManualAddressPreferred($adapter, [string]$IPAddress,
                                    [int]$TimeoutSeconds = 10,
                                    [int]$PollIntervalMilliseconds = 250,
                                    $Ops = $null) {
    # Reads the real Windows AddressState through the injected ops adapter.
    # Tentative is waited on; Duplicate/Invalid/Deprecated fail immediately;
    # a missing property is INCONCLUSIVE; adapter loss is PENDING.
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $timeout = [Math]::Max(1, $TimeoutSeconds)
    $poll = [Math]::Max(50, $PollIntervalMilliseconds)
    $deadline = (& $Ops.Now).AddSeconds($timeout)
    while ((& $Ops.Now) -lt $deadline) {
        $matches = @(Find-AdapterByGuid $adapter.InterfaceGuid $Ops)
        if ($matches.Count -eq 0) {
            $sameMac = @((& $Ops.GetAdapters) | Where-Object {
                (Normalize-Mac $_.MacAddress) -eq (Normalize-Mac $adapter.MacAddress) })
            if ($sameMac.Count -gt 0) { return "GuidChanged" }
            return "AdapterGone"
        }
        if ($matches.Count -gt 1) { return "IdentityChanged" }
        $live = $matches[0]
        if ((Normalize-Mac $live.MacAddress) -ne (Normalize-Mac $adapter.MacAddress)) {
            return "MacChanged"
        }
        if (-not (Test-EligibleDescription $live.InterfaceDescription)) {
            return "IdentityChanged"
        }
        if ($live.Status -ne "Up") { return "AdapterGone" }
        try { $ips = @(& $Ops.GetIpAddresses $live.InterfaceIndex) }
        catch { return "Inconclusive" }
        $target = @($ips | Where-Object { $_.IPAddress -eq $IPAddress })
        if ($target.Count -eq 0) {
            & $Ops.Sleep $poll
            continue
        }
        if ($target.Count -gt 1) { return "Inconclusive" }
        $state = Get-AddressState $target[0]
        if ($null -eq $state) { return "Inconclusive" }
        switch ($state) {
            "Preferred"  { return "Preferred" }
            "Tentative"  { }
            "Duplicate"  { return "Duplicate" }
            "Invalid"    { return "Invalid" }
            "Deprecated" { return "Deprecated" }
            default      { return "Inconclusive" }
        }
        & $Ops.Sleep $poll
    }
    return "Timeout"
}

function AddressKey($ip) {
    return ("{0}/{1}/{2}/{3}" -f $ip.IPAddress, $ip.PrefixLength,
            [bool]$ip.SkipAsSource, (Get-AddressOrigin $ip).ToUpperInvariant())
}

function RouteKey($r) {
    return ("{0}|{1}|{2}|{3}" -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex, $r.RouteMetric)
}

function WlanKey($w) {
    return ("{0}|{1}|{2}" -f (Normalize-Guid $w.InterfaceGuid), (Normalize-Mac $w.MacAddress), (@($w.IPv4) -join ","))
}

function Get-DadTransmits($adapter) {
    try {
        $iface = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
    } catch { return $null }
    if (-not $iface.PSObject.Properties['DadTransmits']) { return $null }
    try { return [int]$iface.DadTransmits } catch { return $null }
}

function Get-DadConfigVerdict($value) {
    if ($null -eq $value) { return "Inconclusive" }
    if ([int]$value -gt 0) { return "Allow" }
    return "Reject"
}

function Get-RollbackStatus([bool]$present, [bool]$restoreOk, [bool]$verified) {
    if (-not $present) { return "ROLLBACK_PENDING" }
    if (-not $restoreOk) { return "ROLLBACK_FAILED" }
    if ($verified) { return "ROLLBACK_VERIFIED" }
    return "ROLLBACK_FAILED"
}

# Pure model used only by -SelfTest to inject failures into each restore step.
# It mirrors Restore-StateInternal's order; it never touches Windows state.
function Get-RollbackScenarioVerdict([string[]]$faults) {
    if ($faults -contains "adapter-absent") { return "ROLLBACK_PENDING" }
    foreach ($step in @("delete", "dhcp", "static", "dns")) {
        if ($faults -contains $step) { return ("ROLLBACK_FAILED:" + $step) }
    }
    if ($faults -contains "verify") { return "ROLLBACK_FAILED:verify" }
    return "ROLLBACK_VERIFIED"
}

function Compare-AddressSets($saved, $current, [bool]$dhcpEnabled) {
    $savedKeys = @($saved | Where-Object { -not ($dhcpEnabled -and $_.IPAddress -like "169.254.*") } |
                  ForEach-Object { AddressKey $_ } | Sort-Object)
    $currentKeys = @($current | Where-Object { -not ($dhcpEnabled -and $_.IPAddress -like "169.254.*") } |
                    ForEach-Object { AddressKey $_ } | Sort-Object)
    return [pscustomobject]@{
        Ok = (($savedKeys -join ";") -eq ($currentKeys -join ";"))
        Saved = $savedKeys
        Current = $currentKeys
    }
}

function Compare-StringSets($saved, $current) {
    $s = @($saved | Sort-Object) -join ";"
    $c = @($current | Sort-Object) -join ";"
    return ($s -eq $c)
}

function Get-DnsSnapshot($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $v4 = & $Ops.GetDns $adapter.InterfaceIndex $adapter.InterfaceGuid "IPv4"
    $v6 = & $Ops.GetDns $adapter.InterfaceIndex $adapter.InterfaceGuid "IPv6"
    $ok = [bool]($v4.Ok -and $v6.Ok)
    $reliable = [bool]($ok -and $v4.Source -ne "Unknown" -and $v6.Source -ne "Unknown")
    $errors = @()
    if (-not $v4.Ok) { $errors += ("IPv4: " + $v4.Error) }
    if (-not $v6.Ok) { $errors += ("IPv6: " + $v6.Error) }
    if ($v4.Ok -and $v4.Source -eq "Unknown") { $errors += "IPv4 source unknown" }
    if ($v6.Ok -and $v6.Source -eq "Unknown") { $errors += "IPv6 source unknown" }
    return [pscustomobject]@{
        Ok = $ok
        Reliable = $reliable
        IPv4 = $v4
        IPv6 = $v6
        Error = ($errors -join "; ")
    }
}

function Get-CurrentSnapshot($adapter, $state, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $matches = @(Find-AdapterByGuid $adapter.InterfaceGuid $Ops)
    if ($matches.Count -ne 1) { return $null }
    $a = $matches[0]
    $ips = @(& $Ops.GetIpAddresses $a.InterfaceIndex |
             ForEach-Object { [pscustomobject]@{
                 IPAddress = $_.IPAddress; PrefixLength = $_.PrefixLength;
                 PrefixOrigin = (Get-AddressOrigin $_); SkipAsSource = [bool]$_.SkipAsSource;
                 AddressState = $(if ($_.PSObject.Properties['AddressState']) { [string]$_.AddressState } else { $null }) } })
    $iface = & $Ops.GetIpInterface $a.InterfaceIndex
    $dns = Get-DnsSnapshot $a $Ops
    $routes = @(& $Ops.GetRoutes)
    $wlan = @(& $Ops.GetWlan)
    return [pscustomobject]@{ Adapter = $a; IPv4 = $ips; Dhcp = [string]$iface.Dhcp;
                              DNS = $dns; Routes = $routes; Wlan = $wlan }
}

function Compare-State($saved, $current) {
    $failures = @()
    $pending = $false
    $inconclusive = $false
    if (-not $current) {
        return [pscustomobject]@{ Ok = $false; Pending = $false; Inconclusive = $false;
                                  Failures = @("adapter missing") }
    }
    if ((Normalize-Guid $saved.InterfaceGuid) -ne (Normalize-Guid $current.Adapter.InterfaceGuid)) { $failures += "GUID mismatch" }
    if ((Normalize-Mac $saved.MacAddress) -ne (Normalize-Mac $current.Adapter.MacAddress)) { $failures += "MAC mismatch" }
    if ([string]$saved.Dhcp -ne [string]$current.Dhcp) { $failures += "DHCP mode mismatch" }

    # Manual addresses must match exactly, including PrefixOrigin/PrefixLength/
    # SkipAsSource. DHCP addresses are allowed to change lease and IP.
    $savedManual = @($saved.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" -and $_.IPAddress -notlike "169.254.*" })
    $currentManual = @($current.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" -and $_.IPAddress -notlike "169.254.*" })
    $savedManualKeys = @($savedManual | ForEach-Object { AddressKey $_ } | Sort-Object)
    $currentManualKeys = @($currentManual | ForEach-Object { AddressKey $_ } | Sort-Object)
    if (($savedManualKeys -join ";") -ne ($currentManualKeys -join ";")) {
        $failures += ("manual IPv4 mismatch saved=[" + ($savedManualKeys -join ",") +
                      "] current=[" + ($currentManualKeys -join ",") + "]")
    }
    foreach ($ip in $savedManual) {
        $state = Get-AddressState $ip
        if ($null -eq $state) { $inconclusive = $true; $failures += "saved manual AddressState missing" }
        elseif ($state -ne "Preferred") { $failures += ("saved manual AddressState=" + $state) }
    }
    foreach ($ip in $currentManual) {
        $state = Get-AddressState $ip
        if ($null -eq $state) { $inconclusive = $true; $failures += "manual AddressState missing" }
        elseif ($state -ne "Preferred") { $failures += ("manual AddressState=" + $state) }
    }

    $savedDhcp = @($saved.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "DHCP" -and $_.IPAddress -notlike "169.254.*" })
    $currentDhcp = @($current.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "DHCP" -and $_.IPAddress -notlike "169.254.*" })
    if ([string]$saved.Dhcp -eq "Enabled") {
        if ($savedDhcp.Count -gt 0 -and $currentDhcp.Count -eq 0) {
            $pending = $true
            $failures += "DHCP address missing (lease pending)"
        } elseif ($currentDhcp.Count -gt 0) {
            $preferred = @($currentDhcp | Where-Object {
                $_.PSObject.Properties['AddressState'] -and $_.AddressState -eq "Preferred" })
            if ($preferred.Count -eq 0) {
                $pending = $true
                $failures += "DHCP address not Preferred"
            }
        }
    } elseif ($currentDhcp.Count -gt 0) {
        $failures += "DHCP address present while DHCP disabled"
    }

    if (-not $saved.DNS -or -not $saved.DNS.Ok -or -not $saved.DNS.Reliable) {
        $inconclusive = $true
        $failures += "saved DNS snapshot is not reliable"
    } elseif (-not $current.DNS -or -not $current.DNS.Ok) {
        $inconclusive = $true
        $failures += "DNS query failed"
    } elseif (-not $current.DNS.Reliable) {
        $inconclusive = $true
        $failures += "DNS source unknown"
    } else {
        foreach ($fam in @("IPv4", "IPv6")) {
            $s = $saved.DNS.$fam
            $c = $current.DNS.$fam
            if ([string]$s.Source -ne [string]$c.Source) {
                $failures += ("DNS " + $fam + " source mismatch saved=" + $s.Source + " current=" + $c.Source)
            } elseif (-not (Compare-StringSets @($s.Servers) @($c.Servers))) {
                $failures += ("DNS " + $fam + " server mismatch")
            }
        }
    }

    $savedRoutes = @($saved.Routes | ForEach-Object { RouteKey $_ })
    $currentRoutes = @($current.Routes | ForEach-Object { RouteKey $_ })
    if (-not (Compare-StringSets $savedRoutes $currentRoutes)) { $failures += "default route mismatch" }
    $savedWlan = @($saved.Wlan | ForEach-Object { WlanKey $_ })
    $currentWlan = @($current.Wlan | ForEach-Object { WlanKey $_ })
    if (-not (Compare-StringSets $savedWlan $currentWlan)) { $failures += "WLAN mismatch" }
    return [pscustomobject]@{
        Ok = ($failures.Count -eq 0 -and -not $pending -and -not $inconclusive)
        Pending = $pending
        Inconclusive = $inconclusive
        Failures = $failures
    }
}

function Save-State($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $ips = @(& $Ops.GetIpAddresses $adapter.InterfaceIndex |
             ForEach-Object { [pscustomobject]@{
                 IPAddress = $_.IPAddress; PrefixLength = $_.PrefixLength;
                 PrefixOrigin = (Get-AddressOrigin $_); SkipAsSource = [bool]$_.SkipAsSource;
                 AddressState = $(if ($_.PSObject.Properties['AddressState']) { [string]$_.AddressState } else { $null }) } })
    $iface = & $Ops.GetIpInterface $adapter.InterfaceIndex
    $dhcp = [string]$iface.Dhcp
    $badManual = @($ips | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" -and $_.IPAddress -notlike "169.254.*" -and
        (Get-AddressState $_) -ne "Preferred" })
    if ($badManual.Count -gt 0) {
        throw "REFUSED: a saved Manual IPv4 address is not AddressState=Preferred; cannot establish a safe baseline."
    }
    $dns = Get-DnsSnapshot $adapter $Ops
    if (-not $dns.Ok) {
        throw ("REFUSED: DNS snapshot failed; no network change made. " + $dns.Error)
    }
    if (-not $dns.Reliable) {
        throw ("REFUSED: DNS source cannot be determined reliably; no network change made. " + $dns.Error)
    }
    $routes = @(& $Ops.GetRoutes)
    $wlan = @(& $Ops.GetWlan)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $StateDir ("netcfg_" + $adapter.InterfaceGuid + "_" + $stamp + ".json")
    $state = [pscustomobject]@{
        savedAt = (Get-Date).ToString("o")
        StatePath = $path
        InterfaceGuid = $adapter.InterfaceGuid
        InterfaceIndex = $adapter.InterfaceIndex
        Name = $adapter.Name
        MacAddress = $adapter.MacAddress
        InterfaceDescription = $adapter.InterfaceDescription
        OriginalStatus = $adapter.Status
        Dhcp = $dhcp
        IPv4 = $ips
        DNS = $dns
        DnsTouched = $false
        Routes = $routes
        Wlan = $wlan
        note = "Only the target USB adapter is restored. DHCP-origin addresses are restored by DHCP; only Manual addresses use New-NetIPAddress. DNS is not changed by Apply; rollback only restores it when DnsTouched=true."
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $state
}

function Get-LatestState([string]$guid) {
    $want = Normalize-Guid $guid
    $files = @(Get-ChildItem -LiteralPath $StateDir -Filter "netcfg_*.json" -ErrorAction SilentlyContinue |
               Where-Object { (Normalize-Guid ($_.Name -replace '^netcfg_([^_]+)_.*$','$1')) -eq $want } |
               Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $null }
    return ($files[0].FullName | Get-Content -Raw | ConvertFrom-Json)
}

function Remove-AllManualIpv4($adapter, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $addrs = @(& $Ops.GetIpAddresses $adapter.InterfaceIndex | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" -or $_.IPAddress -like "169.254.*" })
    foreach ($ip in $addrs) {
        & $Ops.RemoveIpAddress $adapter.InterfaceIndex $ip.IPAddress ([int]$ip.PrefixLength)
    }
}

function Remove-NewIpv4($adapter, $state, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    $originalManual = @($state.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" } | ForEach-Object { AddressKey $_ })
    $current = @(& $Ops.GetIpAddresses $adapter.InterfaceIndex)
    foreach ($ip in $current) {
        $origin = Get-AddressOrigin $ip
        if (($origin -eq "Manual" -or $ip.IPAddress -like "169.254.*") -and
            ($originalManual -notcontains (AddressKey $ip))) {
            & $Ops.RemoveIpAddress $adapter.InterfaceIndex $ip.IPAddress ([int]$ip.PrefixLength)
        }
    }
}

function Restore-DnsState($adapter, $state, $Ops = $null) {
    # Apply never sets DNS. This function is deliberately gated: it only acts
    # when a saved state explicitly records DnsTouched=true. This prevents a
    # rollback from "restoring" an unreadable DNS snapshot to an empty one.
    if (-not $state.PSObject.Properties['DnsTouched'] -or -not [bool]$state.DnsTouched) { return }
    if (-not $state.DNS -or -not $state.DNS.Ok -or -not $state.DNS.Reliable) {
        throw "INCONCLUSIVE: saved DNS snapshot is not reliable"
    }
    $current = Get-DnsSnapshot $adapter $Ops
    if (-not $current.Ok) { throw "INCONCLUSIVE: DNS query failed during rollback" }
    if (-not $current.Reliable) { throw "INCONCLUSIVE: DNS source unknown during rollback" }
    foreach ($fam in @("IPv4", "IPv6")) {
        $s = $state.DNS.$fam
        $c = $current.$fam
        if ([string]$s.Source -eq [string]$c.Source -and
            (Compare-StringSets @($s.Servers) @($c.Servers))) { continue }
        switch ([string]$s.Source) {
            "Manual" { & $Ops.SetDns $adapter.InterfaceIndex $fam @($s.Servers) $false }
            "Dhcp"   { & $Ops.SetDns $adapter.InterfaceIndex $fam @() $true }
            "Empty"  { throw "ROLLBACK_FAILED: original DNS was empty but current DNS differs; refusing to clear" }
            default  { throw "INCONCLUSIVE: saved DNS source unknown" }
        }
    }
    $after = Get-DnsSnapshot $adapter $Ops
    if (-not $after.Ok) { throw "INCONCLUSIVE: DNS readback failed" }
    if (-not $after.Reliable) { throw "INCONCLUSIVE: DNS source unknown on readback" }
    foreach ($fam in @("IPv4", "IPv6")) {
        $s = $state.DNS.$fam
        $c = $after.$fam
        if ([string]$s.Source -ne [string]$c.Source -or
            -not (Compare-StringSets @($s.Servers) @($c.Servers))) {
            throw ("ROLLBACK_FAILED: DNS " + $fam + " readback mismatch")
        }
    }
}

function Restore-StateInternal($adapter, $state, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    Remove-NewIpv4 $adapter $state $Ops

    $savedDhcp = @($state.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "DHCP" -and $_.IPAddress -notlike "169.254.*" })
    $savedManual = @($state.IPv4 | Where-Object {
        (Get-AddressOrigin $_) -eq "Manual" -and $_.IPAddress -notlike "169.254.*" })

    # Restore the original DHCP mode before touching Manual addresses.
    if ([string]$state.Dhcp -eq "Enabled") {
        & $Ops.SetDhcp $adapter.InterfaceIndex "Enabled"
    } else {
        & $Ops.SetDhcp $adapter.InterfaceIndex "Disabled"
    }

    if ($savedManual.Count -gt 0) {
        $dad = Get-DadTransmitsFromOps $adapter $Ops
        if ($null -eq $dad) {
            throw "INCONCLUSIVE: cannot read DadTransmits; refusing to claim manual DAD completed"
        }
        if ([int]$dad -le 0) {
            throw ("INCONCLUSIVE: IPv4 DAD is disabled (DadTransmits=" + $dad + "); refusing to claim manual DAD completed")
        }

        foreach ($ip in $savedManual) {
            $current = @(& $Ops.GetIpAddresses $adapter.InterfaceIndex)
            $existing = @($current | Where-Object {
                (AddressKey $_) -eq (AddressKey $ip) })
            if ($existing.Count -eq 0) {
                & $Ops.AddIpAddress $adapter.InterfaceIndex $ip.IPAddress ([int]$ip.PrefixLength) ([bool]$ip.SkipAsSource)
            }
            $dadStatus = Wait-ManualAddressPreferred $adapter $ip.IPAddress `
                $DadTimeoutSeconds 250 $Ops
            switch ($dadStatus) {
                "Preferred" { }
                "Duplicate" { throw ("ROLLBACK_FAILED: manual DAD Duplicate for " + $ip.IPAddress) }
                "Invalid"   { throw ("ROLLBACK_FAILED: manual DAD Invalid for " + $ip.IPAddress) }
                "Deprecated" { throw ("ROLLBACK_FAILED: manual DAD Deprecated for " + $ip.IPAddress) }
                "Timeout"   { throw ("ROLLBACK_FAILED: manual DAD timeout for " + $ip.IPAddress) }
                "Inconclusive" { throw ("INCONCLUSIVE: manual AddressState unreadable for " + $ip.IPAddress) }
                "AdapterGone" { throw "PENDING: adapter disappeared during manual DAD" }
                "GuidChanged" { throw "ROLLBACK_FAILED: adapter GUID changed during manual DAD" }
                "MacChanged"  { throw "ROLLBACK_FAILED: adapter MAC changed during manual DAD" }
                "IdentityChanged" { throw "ROLLBACK_FAILED: adapter identity changed during manual DAD" }
                default { throw ("INCONCLUSIVE: manual DAD state " + $dadStatus + " for " + $ip.IPAddress) }
            }
        }
    }

    # DHCP lease check happens after Manual addresses have reached Preferred.
    if ([string]$state.Dhcp -eq "Enabled" -and $savedDhcp.Count -gt 0) {
        $deadline = (& $Ops.Now).AddSeconds([Math]::Max(1, $DhcpTimeoutSeconds))
        $leaseOk = $false
        while ((& $Ops.Now) -lt $deadline) {
            $scan = @(& $Ops.GetIpAddresses $adapter.InterfaceIndex)
            $valid = @($scan | Where-Object {
                (Get-AddressOrigin $_) -eq "DHCP" -and
                $_.IPAddress -notlike "169.254.*" -and
                $_.PSObject.Properties['AddressState'] -and
                $_.AddressState -eq "Preferred" })
            if ($valid.Count -gt 0) { $leaseOk = $true; break }
            & $Ops.Sleep 250
        }
        if (-not $leaseOk) {
            return [pscustomobject]@{ Ok = $false; Pending = $true;
                                      Error = "DHCP lease timeout" }
        }
    }

    Restore-DnsState $adapter $state $Ops
    return [pscustomobject]@{ Ok = $true; Pending = $false; Error = "" }
}

function Invoke-RestoreFlow($adapter, $state, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    try { $all = @(& $Ops.GetAdapters) } catch { return "ROLLBACK_FAILED" }
    $matches = @($all | Where-Object {
        (Normalize-Guid $_.InterfaceGuid) -eq (Normalize-Guid $adapter.InterfaceGuid) })
    if ($matches.Count -eq 0) {
        $sameMac = @($all | Where-Object {
            (Normalize-Mac $_.MacAddress) -eq (Normalize-Mac $adapter.MacAddress) })
        if ($sameMac.Count -gt 0) { return "ROLLBACK_FAILED" }  # GUID changed
        return "ROLLBACK_PENDING"                               # adapter absent
    }
    if ($matches.Count -gt 1) { return "ROLLBACK_FAILED" }
    $live = $matches[0]
    if ((Normalize-Mac $live.MacAddress) -ne (Normalize-Mac $adapter.MacAddress)) {
        return "ROLLBACK_FAILED"                                # MAC changed
    }
    if (-not (Test-EligibleDescription $live.InterfaceDescription)) {
        return "ROLLBACK_FAILED"
    }
    $pnp = Get-PnpStatus $live.PnpDeviceID $Ops
    if (-not ($pnp -and $pnp.Present -eq $true -and $pnp.Status -eq "OK")) {
        return "ROLLBACK_FAILED"
    }
    if ($live.Status -ne "Up") { return "ROLLBACK_PENDING" }

    try {
        $restore = Restore-StateInternal $live $state $Ops
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like "INCONCLUSIVE:*") { return "INCONCLUSIVE" }
        if ($msg -like "PENDING:*") { return "ROLLBACK_PENDING" }
        return "ROLLBACK_FAILED"
    }
    if ($restore.Pending) { return "ROLLBACK_PENDING" }

    try { $current = Get-CurrentSnapshot $live $state $Ops }
    catch { return "ROLLBACK_FAILED" }
    $cmp = Compare-State $state $current
    if ($cmp.Inconclusive) { return "INCONCLUSIVE" }
    if ($cmp.Pending) { return "ROLLBACK_PENDING" }
    if ($cmp.Ok) { return "ROLLBACK_VERIFIED" }
    return "ROLLBACK_FAILED"
}

function Invoke-WithAutoRollback($adapter, $state, [scriptblock]$Action, $Ops = $null) {
    if ($null -eq $Ops) { $Ops = Get-RealOps }
    try {
        & $Action
        return "Success"
    } catch {
        Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
        Write-Host "Attempting automatic rollback to saved state..." -ForegroundColor Yellow
        $status = Invoke-RestoreFlow $adapter $state $Ops
        if ($status -eq "ROLLBACK_VERIFIED") {
            Write-Host "Automatic rollback verified." -ForegroundColor Yellow
        } else {
            Write-Host ("AUTOMATIC ROLLBACK RESULT: " + $status) -ForegroundColor Red
        }
        return $status
    }
}

if ($SelfTest) {
    function New-TestDns([string]$server) {
        return [pscustomobject]@{
            Ok = $true; Reliable = $true
            IPv4 = [pscustomobject]@{ Ok = $true; Servers = @($server); Source = "Manual"; Error = "" }
            IPv6 = [pscustomobject]@{ Ok = $true; Servers = @(); Source = "Empty"; Error = "" }
            Error = ""
        }
    }
    function New-TestSnapshot([string]$guid, [string]$mac, [string]$dns) {
        return [pscustomobject]@{
            Adapter = [pscustomobject]@{ InterfaceGuid = $guid; MacAddress = $mac }
            Dhcp = "Disabled"
            IPv4 = @([pscustomobject]@{ IPAddress = "192.168.31.100"; PrefixLength = 24; PrefixOrigin = "Manual"; SkipAsSource = $false; AddressState = "Preferred" })
            DNS = (New-TestDns $dns)
            Routes = @()
            Wlan = @()
        }
    }
    $savedSnapshot = [pscustomobject]@{
        InterfaceGuid = "{00000000-0000-0000-0000-000000000000}"
        MacAddress = "AA-BB-CC-DD-EE-FF"
        Dhcp = "Disabled"
        IPv4 = @([pscustomobject]@{ IPAddress = "192.168.31.100"; PrefixLength = 24; PrefixOrigin = "Manual"; SkipAsSource = $false; AddressState = "Preferred" })
        DNS = (New-TestDns "1.1.1.1")
        Routes = @()
        Wlan = @()
    }

    function New-Addr([string]$ip, [int]$prefix, [string]$origin,
                      [string]$state = "Preferred", [bool]$skip = $false) {
        return [pscustomobject]@{
            IPAddress = $ip; PrefixLength = $prefix; PrefixOrigin = $origin;
            SkipAsSource = $skip; AddressState = $state
        }
    }

    function New-MockOps($rt) {
        $getAdapters = { if ($null -eq $rt.Adapter) { @() } else { @($rt.Adapter) } }.GetNewClosure()
        $getPnp = {
            if ($rt.PnpOk) { [pscustomobject]@{ Present = $true; Status = "OK" } }
            else { [pscustomobject]@{ Present = $false; Status = "Error" } }
        }.GetNewClosure()
        $getIps = { param($idx) @($rt.IPv4) }.GetNewClosure()
        $getIf = {
            param($idx)
            if ($rt.DadTransmitsMissing) { [pscustomobject]@{ Dhcp = $rt.Dhcp } }
            else { [pscustomobject]@{ Dhcp = $rt.Dhcp; DadTransmits = $rt.DadTransmits } }
        }.GetNewClosure()
        $removeIp = { param($idx, $ip, $prefix)
            if ($rt.FailRemove) { throw "injected remove failure" }
            [void]$rt.Calls.Add("remove:$ip")
            $rt.IPv4 = @($rt.IPv4 | Where-Object { -not ($_.IPAddress -eq $ip -and $_.PrefixLength -eq $prefix) })
        }.GetNewClosure()
        $setDhcp = { param($idx, $enabled)
            if ($rt.FailDhcp) { throw "injected DHCP failure" }
            [void]$rt.Calls.Add("dhcp:$enabled")
            $rt.Dhcp = $enabled
            $rt.IPv4 = @($rt.IPv4 | Where-Object { (Get-AddressOrigin $_) -ne "DHCP" })
            if ($enabled -eq "Enabled") {
                if ($rt.LeaseMode -eq "same") {
                    $rt.IPv4 += (New-Addr $rt.LeaseIp 24 "DHCP" "Preferred")
                } elseif ($rt.LeaseMode -eq "different") {
                    $rt.IPv4 += (New-Addr "192.168.31.77" 24 "DHCP" "Preferred")
                } elseif ($rt.LeaseMode -eq "tentative") {
                    $rt.IPv4 += (New-Addr $rt.LeaseIp 24 "DHCP" "Tentative")
                }
            }
        }.GetNewClosure()
        $addIp = { param($idx, $ip, $prefix, $skip)
            if ($rt.FailManual) { throw "injected manual restore failure" }
            [void]$rt.Calls.Add("add:$ip")
            if ($rt.ManualAddMissing) { return }
            $origin = "Manual"; $usePrefix = $prefix; $useSkip = [bool]$skip
            if ($rt.WrongManualOrigin) { $origin = "DHCP" }
            if ($rt.BadPrefix) { $usePrefix = 16 }
            if ($rt.BadSkip) { $useSkip = $true }
            $obj = [pscustomobject]@{
                IPAddress = $ip; PrefixLength = $usePrefix; PrefixOrigin = $origin;
                SkipAsSource = $useSkip
            }
            if (-not $rt.ManualAddNoState) {
                $obj | Add-Member -NotePropertyName AddressState -NotePropertyValue $rt.ManualAddState
            }
            $rt.IPv4 += $obj
            if ($rt.DisappearAfterAdd) { $rt.Adapter = $null }
            if ($rt.GuidChangeAfterAdd) {
                $rt.Adapter.InterfaceGuid = "{00000000-0000-0000-0000-000000000000}"
            }
            if ($rt.MacChangeAfterAdd) { $rt.Adapter.MacAddress = "00-00-00-00-00-00" }
        }.GetNewClosure()
        $getDns = { param($idx, $guid, $family)
            if ($rt.FailDnsRead -or $rt.FailDnsFamily -eq $family) {
                return [pscustomobject]@{ Ok = $false; Servers = @(); Source = "Unknown"; Error = "injected DNS read failure" }
            }
            return $rt.DNS.$family
        }.GetNewClosure()
        $setDns = { param($idx, $family, $servers, $reset)
            if ($rt.FailDnsWrite) { throw "injected DNS write failure" }
            [void]$rt.Calls.Add("dns:$family")
            if ($rt.DnsWriteNoEffect) { return }
            $src = if ($reset) { "Dhcp" } else { "Manual" }
            $vals = if ($reset) { @($rt.DhcpDnsServers) } else { @($servers) }
            $rt.DNS.$family = [pscustomobject]@{ Ok = $true; Servers = $vals; Source = $src; Error = "" }
        }.GetNewClosure()
        $getRoutes = { @() }
        $getWlan = { @() }
        $sleep = { param($ms) $rt.Clock = $rt.Clock.AddMilliseconds($ms) }.GetNewClosure()
        $now = { $rt.Clock = $rt.Clock.AddMilliseconds(250); return $rt.Clock }.GetNewClosure()
        return [pscustomobject]@{
            GetAdapters = $getAdapters; GetPnp = $getPnp; GetIpAddresses = $getIps;
            GetIpInterface = $getIf; RemoveIpAddress = $removeIp; SetDhcp = $setDhcp;
            AddIpAddress = $addIp; GetDns = $getDns; SetDns = $setDns;
            GetRoutes = $getRoutes; GetWlan = $getWlan; Sleep = $sleep; Now = $now
        }
    }

    function New-RestoreSaved([string]$dhcp, $addrs, $dns, [bool]$touched = $false) {
        return [pscustomobject]@{
            InterfaceGuid = "{00000000-0000-0000-0000-000000000000}"
            MacAddress = "AA-BB-CC-DD-EE-FF"
            InterfaceDescription = "Realtek Gaming USB 2.5GbE Family Controller"
            InterfaceIndex = 42; Status = "Up"; PnpDeviceID = "USB\VID_TEST"
            Dhcp = $dhcp; IPv4 = @($addrs); DNS = $dns; DnsTouched = $touched
            Routes = @(); Wlan = @()
        }
    }

    function New-RestoreRuntime($addrs, [string]$dhcp, $dns) {
        $adapter = [pscustomobject]@{
            InterfaceGuid = "{00000000-0000-0000-0000-000000000000}";
            MacAddress = "AA-BB-CC-DD-EE-FF";
            InterfaceDescription = "Realtek Gaming USB 2.5GbE Family Controller";
            InterfaceIndex = 42; Status = "Up"; PnpDeviceID = "USB\VID_TEST"
        }
        $rt = [pscustomobject]@{
            Adapter = $adapter; IPv4 = @($addrs); Dhcp = $dhcp; DNS = $dns;
            FailRemove = $false; FailDhcp = $false; FailManual = $false;
            FailDnsWrite = $false; FailDnsRead = $false; FailDnsFamily = "";
            DnsWriteNoEffect = $false; WrongManualOrigin = $false;
            BadPrefix = $false; BadSkip = $false; PnpOk = $true;
            DadTransmits = 3; DadTransmitsMissing = $false;
            ManualAddState = "Preferred"; ManualAddMissing = $false;
            ManualAddNoState = $false; DisappearAfterAdd = $false;
            GuidChangeAfterAdd = $false; MacChangeAfterAdd = $false;
            LeaseMode = "same"; LeaseIp = "192.168.31.50";
            DhcpDnsServers = @("192.168.31.1");
            Clock = [datetime]"2026-11-05T00:00:00";
            Calls = New-Object System.Collections.ArrayList
        }
        $rt | Add-Member -NotePropertyName Ops -NotePropertyValue (New-MockOps $rt)
        return $rt
    }

    $script:RestoreTotal = 0
    $script:RestoreFail = 0
    function Run-RestoreCase([string]$name, $saved, $rt, [string]$expect) {
        $script:RestoreTotal++
        $status = Invoke-RestoreFlow $saved $saved $rt.Ops
        if ($status -eq $expect) {
            Write-Host ("PASS restore: " + $name + " -> " + $status)
        } else {
            Write-Host ("FAIL restore: " + $name + " -> got " + $status + ", want " + $expect) -ForegroundColor Red
            $script:RestoreFail++
        }
    }
    $cases = @(
        @{ Name = "ARP neighbor Reachable with ICMP blocked"; Got = (Get-ConflictVerdict $false "Reachable" $false); Want = "Conflict" },
        @{ Name = "probe reply means conflict"; Got = (Get-ConflictVerdict $false "None" $true); Want = "Conflict" },
        @{ Name = "local duplicate means conflict"; Got = (Get-ConflictVerdict $true "None" $false); Want = "Conflict" },
        @{ Name = "no signals is INCONCLUSIVE"; Got = (Get-ConflictVerdict $false "None" $false); Want = "Inconclusive" },
        @{ Name = "incomplete neighbor is INCONCLUSIVE"; Got = (Get-ConflictVerdict $false "Incomplete" $false); Want = "Inconclusive" },
        @{ Name = "DAD Preferred is success"; Got = (Get-DadVerdict "Preferred" $false); Want = "Success" },
        @{ Name = "DAD Duplicate triggers rollback"; Got = (Get-DadVerdict "Duplicate" $false); Want = "Rollback" },
        @{ Name = "DAD Invalid triggers rollback"; Got = (Get-DadVerdict "Invalid" $false); Want = "Rollback" },
        @{ Name = "DAD timeout triggers rollback"; Got = (Get-DadVerdict "Tentative" $true); Want = "Rollback" },
        @{ Name = "DAD Tentative is INCONCLUSIVE"; Got = (Get-DadVerdict "Tentative" $false); Want = "Inconclusive" },
        @{ Name = "DAD Deprecated triggers rollback"; Got = (Get-DadVerdict "Deprecated" $false); Want = "Rollback" },
        @{ Name = "DAD missing property triggers rollback"; Got = (Get-DadVerdict "" $false); Want = "Rollback" },
        @{ Name = "identity rejects GUID mismatch"; Got = (Get-IdentityVerdict $false $true $true $true); Want = "Reject" },
        @{ Name = "identity rejects MAC mismatch"; Got = (Get-IdentityVerdict $true $false $true $true); Want = "Reject" },
        @{ Name = "identity rejects PNP mismatch"; Got = (Get-IdentityVerdict $true $true $true $false); Want = "Reject" },
        @{ Name = "adapter disappearance detected"; Got = (Get-AdapterPresenceVerdict $false $true $true); Want = "Disappeared" },
        @{ Name = "MAC change detected"; Got = (Get-AdapterPresenceVerdict $true $false $true); Want = "MacChanged" },
        @{ Name = "DAD enabled allowed"; Got = (Get-DadConfigVerdict 3); Want = "Allow" },
        @{ Name = "DAD disabled rejected"; Got = (Get-DadConfigVerdict 0); Want = "Reject" },
        @{ Name = "DAD unreadable is INCONCLUSIVE"; Got = (Get-DadConfigVerdict $null); Want = "Inconclusive" },
        @{ Name = "rollback verified"; Got = (Get-RollbackStatus $true $true $true); Want = "ROLLBACK_VERIFIED" },
        @{ Name = "rollback missing adapter is pending"; Got = (Get-RollbackStatus $false $false $false); Want = "ROLLBACK_PENDING" },
        @{ Name = "rollback restore failure"; Got = (Get-RollbackStatus $true $false $false); Want = "ROLLBACK_FAILED" },
        @{ Name = "rollback unverified"; Got = (Get-RollbackStatus $true $true $false); Want = "ROLLBACK_FAILED" },
        @{ Name = "address set match"; Got = (Compare-AddressSets @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=24;SkipAsSource=$false}) @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=24;SkipAsSource=$false}) $false).Ok; Want = $true },
        @{ Name = "address prefix mismatch"; Got = (Compare-AddressSets @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=24;SkipAsSource=$false}) @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=16;SkipAsSource=$false}) $false).Ok; Want = $false },
        @{ Name = "address count mismatch"; Got = (Compare-AddressSets @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=24;SkipAsSource=$false}) @([pscustomobject]@{IPAddress="192.168.31.100";PrefixLength=24;SkipAsSource=$false},[pscustomobject]@{IPAddress="192.168.31.101";PrefixLength=24;SkipAsSource=$false}) $false).Ok; Want = $false },
        @{ Name = "DNS set match"; Got = (Compare-StringSets @("1.1.1.1") @("1.1.1.1")); Want = $true },
        @{ Name = "DNS set mismatch"; Got = (Compare-StringSets @("1.1.1.1") @("8.8.8.8")); Want = $false },
        @{ Name = "rollback scenario full success"; Got = (Get-RollbackScenarioVerdict @()); Want = "ROLLBACK_VERIFIED" },
        @{ Name = "rollback scenario delete failure"; Got = (Get-RollbackScenarioVerdict @("delete")); Want = "ROLLBACK_FAILED:delete" },
        @{ Name = "rollback scenario DHCP failure"; Got = (Get-RollbackScenarioVerdict @("dhcp")); Want = "ROLLBACK_FAILED:dhcp" },
        @{ Name = "rollback scenario static failure"; Got = (Get-RollbackScenarioVerdict @("static")); Want = "ROLLBACK_FAILED:static" },
        @{ Name = "rollback scenario DNS failure"; Got = (Get-RollbackScenarioVerdict @("dns")); Want = "ROLLBACK_FAILED:dns" },
        @{ Name = "rollback scenario verify mismatch"; Got = (Get-RollbackScenarioVerdict @("verify")); Want = "ROLLBACK_FAILED:verify" },
        @{ Name = "rollback scenario adapter absent"; Got = (Get-RollbackScenarioVerdict @("adapter-absent")); Want = "ROLLBACK_PENDING" },
        @{ Name = "state comparison full match"; Got = (Compare-State $savedSnapshot (New-TestSnapshot $savedSnapshot.InterfaceGuid $savedSnapshot.MacAddress "1.1.1.1")).Ok; Want = $true },
        @{ Name = "state comparison GUID change"; Got = (Compare-State $savedSnapshot (New-TestSnapshot "{00000000-0000-0000-0000-000000000000}" $savedSnapshot.MacAddress "1.1.1.1")).Ok; Want = $false },
        @{ Name = "state comparison MAC change"; Got = (Compare-State $savedSnapshot (New-TestSnapshot $savedSnapshot.InterfaceGuid "00-00-00-00-00-00" "1.1.1.1")).Ok; Want = $false },
        @{ Name = "state comparison adapter missing"; Got = (Compare-State $savedSnapshot $null).Ok; Want = $false }
    )
    $fail = 0
    foreach ($c in $cases) {
        if ($c.Got -eq $c.Want) {
            Write-Host ("PASS " + $c.Name + " -> " + $c.Got)
        } else {
            Write-Host ("FAIL " + $c.Name + " -> got " + $c.Got + ", want " + $c.Want) -ForegroundColor Red
            $fail++
        }
    }
    # Mock-operation restore tests: these call Restore-StateInternal,
    # Remove-NewIpv4, Restore-DnsState, Get-CurrentSnapshot and Compare-State.
    # No real network cmdlet is reachable through the injected ops object.
    $DhcpTimeoutSeconds = 1
    $dnsManual = New-TestDns "1.1.1.1"
    $dnsOther = New-TestDns "8.8.8.8"
    $dnsDhcp = [pscustomobject]@{
        Ok = $true; Reliable = $true
        IPv4 = [pscustomobject]@{ Ok = $true; Servers = @("192.168.31.1"); Source = "Dhcp"; Error = "" }
        IPv6 = [pscustomobject]@{ Ok = $true; Servers = @(); Source = "Empty"; Error = "" }
        Error = ""
    }
    $dnsEmpty = [pscustomobject]@{
        Ok = $true; Reliable = $true
        IPv4 = [pscustomobject]@{ Ok = $true; Servers = @(); Source = "Empty"; Error = "" }
        IPv6 = [pscustomobject]@{ Ok = $true; Servers = @(); Source = "Empty"; Error = "" }
        Error = ""
    }
    $manual100 = New-Addr "192.168.31.100" 24 "Manual"
    $dhcp50 = New-Addr "192.168.31.50" 24 "DHCP"
    $savedBoth = New-RestoreSaved "Enabled" @($dhcp50, $manual100) $dnsManual
    $rt = New-RestoreRuntime @() "Enabled" $dnsManual
    $rt.LeaseMode = "same"; $rt.LeaseIp = "192.168.31.50"
    Run-RestoreCase "DHCP+Manual full restore" $savedBoth $rt "ROLLBACK_VERIFIED"

    $savedDhcpOnly = New-RestoreSaved "Enabled" @($dhcp50) $dnsManual
    $rt = New-RestoreRuntime @() "Enabled" $dnsManual
    $rt.LeaseMode = "same"; $rt.LeaseIp = "192.168.31.50"
    Run-RestoreCase "all addresses DHCP" $savedDhcpOnly $rt "ROLLBACK_VERIFIED"

    $rt = New-RestoreRuntime @() "Enabled" $dnsManual
    $rt.LeaseMode = "different"
    Run-RestoreCase "DHCP lease returns different IP" $savedBoth $rt "ROLLBACK_VERIFIED"

    $savedManualOnly = New-RestoreSaved "Disabled" @($manual100) $dnsManual
    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    Run-RestoreCase "DHCP disabled + Manual restore" $savedManualOnly $rt "ROLLBACK_VERIFIED"

    $rt = New-RestoreRuntime @((New-Addr "192.168.31.200" 24 "Manual")) "Disabled" $dnsManual
    $rt.FailRemove = $true
    Run-RestoreCase "remove new IP failure" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Enabled" $dnsManual
    $rt.FailDhcp = $true
    Run-RestoreCase "DHCP restore command failure" $savedBoth $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Enabled" $dnsManual
    $rt.LeaseMode = "none"
    Run-RestoreCase "DHCP lease timeout" $savedBoth $rt "ROLLBACK_PENDING"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.FailManual = $true
    Run-RestoreCase "Manual address restore failure" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.DadTransmits = 0
    Run-RestoreCase "DadTransmits=0 is INCONCLUSIVE" $savedManualOnly $rt "INCONCLUSIVE"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.DadTransmitsMissing = $true
    Run-RestoreCase "DadTransmits unreadable is INCONCLUSIVE" $savedManualOnly $rt "INCONCLUSIVE"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddState = "Tentative"
    Run-RestoreCase "Tentative manual address times out" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddState = "Duplicate"
    Run-RestoreCase "Duplicate manual address fails" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddState = "Invalid"
    Run-RestoreCase "Invalid manual address fails" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddState = "Deprecated"
    Run-RestoreCase "Deprecated manual address fails" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddNoState = $true
    Run-RestoreCase "missing AddressState is INCONCLUSIVE" $savedManualOnly $rt "INCONCLUSIVE"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.ManualAddMissing = $true
    Run-RestoreCase "manual address never appears" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.DisappearAfterAdd = $true
    Run-RestoreCase "adapter disappears during manual DAD" $savedManualOnly $rt "ROLLBACK_PENDING"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.GuidChangeAfterAdd = $true
    Run-RestoreCase "GUID changes during manual DAD" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.MacChangeAfterAdd = $true
    Run-RestoreCase "MAC changes during manual DAD" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @((New-Addr "192.168.31.100" 24 "Manual" "Tentative")) "Disabled" $dnsManual
    Run-RestoreCase "existing Tentative manual address waits then fails" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.FailDnsRead = $true
    Run-RestoreCase "DNS query failure is INCONCLUSIVE" $savedManualOnly $rt "INCONCLUSIVE"

    $savedDnsTouched = New-RestoreSaved "Disabled" @($manual100) $dnsManual $true
    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsOther
    $rt.FailDnsWrite = $true
    Run-RestoreCase "DNS restore command failure" $savedDnsTouched $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsOther
    $rt.DnsWriteNoEffect = $true
    Run-RestoreCase "DNS readback mismatch" $savedDnsTouched $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsOther
    Run-RestoreCase "DNS manual restore success" $savedDnsTouched $rt "ROLLBACK_VERIFIED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.Adapter.InterfaceGuid = "{00000000-0000-0000-0000-000000000000}"
    Run-RestoreCase "GUID change is rejected" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.Adapter.MacAddress = "00-00-00-00-00-00"
    Run-RestoreCase "MAC change is rejected" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.Adapter = $null
    Run-RestoreCase "adapter absent is PENDING" $savedManualOnly $rt "ROLLBACK_PENDING"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.BadPrefix = $true
    Run-RestoreCase "PrefixLength mismatch" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.WrongManualOrigin = $true
    Run-RestoreCase "PrefixOrigin mismatch" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @() "Disabled" $dnsManual
    $rt.BadSkip = $true
    Run-RestoreCase "SkipAsSource mismatch" $savedManualOnly $rt "ROLLBACK_FAILED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsEmpty
    $savedEmptyDns = New-RestoreSaved "Disabled" @($manual100) $dnsEmpty
    Run-RestoreCase "confirmed empty DNS is preserved" $savedEmptyDns $rt "ROLLBACK_VERIFIED"

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsDhcp
    $savedDhcpDns = New-RestoreSaved "Disabled" @($manual100) $dnsDhcp
    Run-RestoreCase "DHCP-origin DNS snapshot" $savedDhcpDns $rt "ROLLBACK_VERIFIED"

    $savedDhcpDnsTouched = New-RestoreSaved "Disabled" @($manual100) $dnsDhcp $true
    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsOther
    $rt.DhcpDnsServers = @("192.168.31.1")
    Run-RestoreCase "DNS DHCP auto restore success" $savedDhcpDnsTouched $rt "ROLLBACK_VERIFIED"

    # Save-State must refuse before any change when DNS is not reliable.
    $oldStateDir = $StateDir
    $StateDir = Join-Path ([IO.Path]::GetTempPath()) ("r3g_dns_gate_" + [guid]::NewGuid().ToString("N"))
    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.FailDnsRead = $true
    $threw = $false; $msg = ""
    try { Save-State $savedManualOnly $rt.Ops | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
    $script:RestoreTotal++
    if ($threw -and $msg -like "*DNS snapshot failed*") { Write-Host "PASS restore: Save-State refuses DNS query failure" }
    else { Write-Host ("FAIL restore: Save-State DNS query gate -> " + $msg) -ForegroundColor Red; $script:RestoreFail++ }

    $rt = New-RestoreRuntime @($manual100) "Disabled" $dnsManual
    $rt.FailDnsFamily = "IPv6"
    $threw = $false; $msg = ""
    try { Save-State $savedManualOnly $rt.Ops | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
    $script:RestoreTotal++
    if ($threw -and $msg -like "*DNS snapshot failed*") { Write-Host "PASS restore: Save-State refuses IPv6 DNS query failure" }
    else { Write-Host ("FAIL restore: Save-State IPv6 DNS gate -> " + $msg) -ForegroundColor Red; $script:RestoreFail++ }
    $StateDir = $oldStateDir

    Write-Host ("RESTORE TOTAL {0}  PASS {1}  FAIL {2}" -f `
        $script:RestoreTotal, ($script:RestoreTotal - $script:RestoreFail), $script:RestoreFail)

    Write-Host ("TOTAL {0}  PASS {1}  FAIL {2}" -f $cases.Count, ($cases.Count - $fail), $fail)
    if ($fail -eq 0 -and $script:RestoreFail -eq 0) { Write-Host "ALL NIC LOGIC SELF-TESTS PASSED"; exit 0 }
    exit 1
}

# Explicitly refuse conflicting action selections.
if ($Apply -and $Rollback) {
    Write-Host "REFUSED: -Apply and -Rollback cannot be used together." -ForegroundColor Red
    exit 2
}

# Default action is Show.
if (-not $Apply -and -not $Rollback) { $Show = $true }

if ($Show -and -not $Apply -and -not $Rollback) {
    Show-Adapters
    $c = @(Get-TargetAdapters)
    if ($c.Count -eq 1) {
        Write-Host ("Eligible target: index={0} guid={1} mac={2}" -f $c[0].InterfaceIndex, $c[0].InterfaceGuid, $c[0].MacAddress) -ForegroundColor Green
    } elseif ($c.Count -eq 0) {
        Write-Host "Eligible target: none (adapter absent or filter mismatch)." -ForegroundColor Yellow
    } else {
        Write-Host "Eligible target: multiple; supply -InterfaceGuid and -MacAddress." -ForegroundColor Yellow
    }
    exit 0
}

if ($Apply -or $Rollback) {
    if (-not $InterfaceGuid -or -not $MacAddress) {
        Write-Host "REFUSED: both -InterfaceGuid and -MacAddress are required." -ForegroundColor Red
        exit 2
    }
    if (-not (Test-Admin)) {
        Write-Host "REFUSED: administrator rights are required for Apply/Rollback." -ForegroundColor Red
        exit 5
    }
}

if ($Apply) {
    if (-not $IUnderstandThisChangesTheWiredAdapter) {
        Write-Host "REFUSED: -Apply requires -IUnderstandThisChangesTheWiredAdapter." -ForegroundColor Red
        exit 2
    }
    if (-not (Test-AddressConfig)) { exit 2 }
    try { $adapter = Get-ExactTarget } catch { Write-Host ("REFUSED: " + $_.Exception.Message) -ForegroundColor Red; exit 3 }

    if ($adapter.Status -ne "Up") {
        Write-Host ("REFUSED: link is '{0}', not Up. Connect the USB adapter first." -f $adapter.Status) -ForegroundColor Red
        exit 3
    }
    $dadTransmits = Get-DadTransmits $adapter
    $dadConfig = Get-DadConfigVerdict $dadTransmits
    if ($dadConfig -eq "Inconclusive") {
        Write-Host "INCONCLUSIVE: cannot read DadTransmits; refusing Apply." -ForegroundColor Red
        exit 3
    }
    if ($dadConfig -eq "Reject") {
        Write-Host ("REFUSED: IPv4 DAD is disabled (DadTransmits={0}); refusing Apply." -f $dadTransmits) -ForegroundColor Red
        exit 3
    }
    Write-Host ("DAD check: DadTransmits={0} (allowed; not modified)." -f $dadTransmits) -ForegroundColor Green
    $conflict = Test-AddressConflict $adapter
    if ($conflict -eq "Conflict") {
        Write-Host "REFUSED: address conflict detected on the target interface." -ForegroundColor Red
        exit 3
    }
    if ($conflict -eq "Inconclusive") {
        Write-Host "INCONCLUSIVE: pre-assignment ARP/ICMP cannot prove the address is free." -ForegroundColor Yellow
        Write-Host "Windows DAD after assignment is the authoritative check; it must reach Preferred." -ForegroundColor Yellow
    }

    if ($PSCmdlet.ShouldProcess(("{0} ({1})" -f $adapter.Name, $adapter.InterfaceGuid),
        ("Set {0}/{1}, no gateway, no DNS" -f $Address, $PrefixLength))) {
        $state = $null
        try { $state = Save-State $adapter } catch {
            Write-Host ("REFUSED: " + $_.Exception.Message) -ForegroundColor Red
            exit 3
        }
        Write-Host ("Saved original state: {0}" -f $state.StatePath) -ForegroundColor Cyan
        $result = Invoke-WithAutoRollback $adapter $state {
            Assert-AdapterOnline $adapter | Out-Null
            Remove-AllManualIpv4 $adapter
            Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -IPAddress $Address -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null

            $deadline = (Get-Date).AddSeconds($DadTimeoutSeconds)
            $dad = "Inconclusive"
            while ((Get-Date) -lt $deadline) {
                $live = Assert-AdapterOnline $adapter
                $ipObj = @(Get-NetIPAddress -InterfaceIndex $live.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                           Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq $PrefixLength })
                if ($ipObj.Count -ne 1) { throw "address object missing after add" }
                if (-not $ipObj[0].PSObject.Properties['AddressState']) {
                    throw "AddressState property missing after add"
                }
                $dad = Get-DadVerdict ([string]$ipObj[0].AddressState) $false
                if ($dad -eq "Success") { break }
                if ($dad -eq "Rollback") { throw ("DAD failed: AddressState=" + $ipObj[0].AddressState) }
                Start-Sleep -Milliseconds 250
            }
            if ($dad -ne "Success") {
                $dad = Get-DadVerdict "Tentative" $true
                throw "DAD timeout after $DadTimeoutSeconds seconds"
            }
            Write-Host "Applied. AddressState=Preferred; no default gateway and no DNS were configured." -ForegroundColor Green
        }
        if ($result -ne "Success") {
            Write-Host ("RESULT: " + $result) -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "WhatIf: no change made." -ForegroundColor Yellow
    }
    exit 0
}

if ($Rollback) {
    try { $adapter = Get-ExactTarget } catch { Write-Host ("REFUSED: " + $_.Exception.Message) -ForegroundColor Red; exit 3 }
    $state = Get-LatestState $InterfaceGuid
    if (-not $state) {
        Write-Host ("REFUSED: no saved state for GUID {0}." -f $InterfaceGuid) -ForegroundColor Red
        exit 3
    }
    if ((Normalize-Guid $state.InterfaceGuid) -ne (Normalize-Guid $InterfaceGuid) -or
        (Normalize-Mac $state.MacAddress) -ne (Normalize-Mac $MacAddress)) {
        Write-Host "REFUSED: saved state GUID/MAC does not match the requested target." -ForegroundColor Red
        exit 3
    }
    if ($PSCmdlet.ShouldProcess(("{0} ({1})" -f $adapter.Name, $adapter.InterfaceGuid), "Restore saved IPv4/DHCP state")) {
        $status = Invoke-RestoreFlow $adapter $state
        if ($status -eq "ROLLBACK_VERIFIED") {
            Write-Host "ROLLBACK_VERIFIED: restored state matches the saved snapshot." -ForegroundColor Green
        } elseif ($status -eq "ROLLBACK_PENDING") {
            Write-Host "ROLLBACK_PENDING: adapter absent/down or DHCP lease not yet available." -ForegroundColor Yellow
            exit 1
        } elseif ($status -eq "INCONCLUSIVE") {
            Write-Host "INCONCLUSIVE: DNS could not be read reliably; refusing to claim success." -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "ROLLBACK_FAILED: restored state does not match the saved snapshot." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "WhatIf: no change made." -ForegroundColor Yellow
    }
    exit 0
}
