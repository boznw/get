$now = Get-Date; $pw = "$env:PasswordPrefix" + ('{0:yy}{1:000}' -f $now, $now.DayOfYear) + "$env:PasswordSuffix"
$acct = "$env:COMPUTERNAME\migrate"
$u = Get-LocalUser migrate -ErrorAction SilentlyContinue
"Account: $(if ($u) { "enabled=$($u.Enabled) expires=$($u.AccountExpires)" } else { 'missing' })"
"Admins member: $([bool](Get-LocalGroupMember -SID S-1-5-32-544 | Where-Object Name -like '*\migrate'))"
$t = Get-ScheduledTask -TaskName 'BozNW - Remove user migration share' -ErrorAction SilentlyContinue
"Task: $(if ($t) { "$($t.State) at $(($t.Triggers | Select-Object -First 1).StartBoundary)" } else { 'missing' })"
"LocalAccountTokenFilterPolicy: $((Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy)"
$other = Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users', 'migrate' } | Select-Object -First 1
net use \\localhost\Users$ /user:$acct $pw 2>&1 | Out-String | ForEach-Object Trim
$ok = $false
try { $n = @(Get-ChildItem "\\localhost\Users$\$($other.Name)\AppData" -Force -ErrorAction Stop).Count; "Listed \\localhost\Users$\$($other.Name)\AppData as migrate: $n entries"; $ok = $true } catch { "List failed: $($_.Exception.Message)" }
net use \\localhost\Users$ /delete /y 2>&1 | Out-Null
if ($ok) { 'RESULT: SUCCESS migrate account can read another profile over the share'; exit 0 } else { 'RESULT: FAILURE access test failed'; exit 1 }
