$t = "$env:TargetHost"
$r = Test-NetConnection -ComputerName $t -Port 445 -WarningAction SilentlyContinue
"Ping: $($r.PingSucceeded); TCP 445 to ${t}: $($r.TcpTestSucceeded); from $env:COMPUTERNAME ($($r.SourceAddress.IPAddress))"
if ($r.TcpTestSucceeded) { 'RESULT: SUCCESS port 445 reachable'; exit 0 } else { 'RESULT: FAILURE port 445 not reachable'; exit 1 }
