$t = "$env:TargetHost"; $ip = "$env:TargetIp"
"Client: $env:COMPUTERNAME"
Get-NetIPConfiguration | Where-Object { $_.IPv4Address } | ForEach-Object { "  $($_.InterfaceAlias): $($_.IPv4Address.IPAddress)/$($_.IPv4Address.PrefixLength) gw $($_.IPv4DefaultGateway.NextHop) dns $($_.DNSServer.ServerAddresses -join ',')" }
Get-NetConnectionProfile | ForEach-Object { "  Profile: $($_.InterfaceAlias) '$($_.Name)' $($_.NetworkCategory)" }
try { "DNS ${t}: " + ((Resolve-DnsName $t -ErrorAction Stop | Where-Object IPAddress | ForEach-Object IPAddress) -join ', ') } catch { "DNS ${t}: FAILED $($_.Exception.Message)" }
foreach ($h in @($ip, $t) | Where-Object { $_ }) {
    $p = Test-Connection $h -Count 2 -Quiet -ErrorAction SilentlyContinue
    $c = New-Object Net.Sockets.TcpClient
    $ok = $false; try { $ok = $c.ConnectAsync($h, 445).Wait(3000) -and $c.Connected } catch {} finally { $c.Close() }
    "  ${h}: ping=$p tcp445=$ok"
}
$arp = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1
"  ARP ${ip}: $(if ($arp) { "$($arp.LinkLayerAddress) $($arp.State)" } else { 'none' })"
$c = New-Object Net.Sockets.TcpClient; $okIp = $false; try { $okIp = $c.ConnectAsync($ip, 445).Wait(3000) -and $c.Connected } catch {} finally { $c.Close() }
if ($okIp) { 'RESULT: SUCCESS port 445 reachable by IP'; exit 0 } else { 'RESULT: FAILURE port 445 not reachable by IP'; exit 1 }
