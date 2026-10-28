<#
.SYNOPSIS
    Prepares a user's old PC for data migration: shares C:\Users as \\PC\Users$ and creates a
    temporary local administrator to copy with. Everything is removed automatically after
    DaysToExpire (default 14), or at once with Mode Remove.

.DESCRIPTION
    Run it on the OLD PC. From the new PC the user (or a tech) opens \\OLDPC\Users$ (or
    \\<IP>\Users$), signs in as OLDPC\migrate, and copies whatever they want. No variables are
    needed: every setting has a default below and can be overridden by a component variable or a
    command-line parameter.

    Mode Apply (default):

      1. Server service (LanmanServer): Automatic and started.
      2. Account: local user AccountName (default migrate), member of Administrators, account
         expires after DaysToExpire, password never expires, user can't change it. Re-running
         Apply on an account this script created resets its password and expiry. An account of
         that name that this script didn't create is never touched (the run fails).
      3. Password: Password if given, otherwise <PasswordPrefix><yy><day of year><PasswordSuffix>
         from this PC's date. Defaults Mig and !: run on 1 Jan 2027 -> Mig27001!. If the PC's
         password policy needs more (minimum length, complexity), the rule is extended and the
         job output says how (see "Password policy" in the README). The job output shows only
         the pattern with the prefix and suffix masked, e.g. <prefix>27001<suffix>.
      4. Share: C:\Users (the profiles folder) as Users$: Administrators Full, Authenticated
         Users Read. NTFS is not changed; the account sees everything as a local administrator.
      5. Remote admin: LocalAccountTokenFilterPolicy = 1, so a local administrator keeps admin
         rights over the network (Windows strips them by default on workgroup PCs).
      6. Firewall: inbound TCP 445 rule "BozNW - SMB-In (Domain/Private)", never on Public.
      7. Network: connections on the Public profile are switched to Private (SetNetworkPrivate,
         default true), because a Public network can't be reached.
      8. Clean-up: a scheduled task "BozNW - Remove user migration share" runs Mode Remove when
         the account expires (copy of this script in C:\ProgramData\BozNW\UserMigrationShare).

    Mode Remove (also run by the clean-up task) undoes exactly what was recorded in
    HKLM\SOFTWARE\BozNW\UserMigrationShare: share, account, LocalAccountTokenFilterPolicy,
    firewall rule, network profiles, scheduled task. Files are never deleted.

    Mode DetectOnly prints what Apply would do and changes nothing.

.PARAMETER Mode
    Apply, DetectOnly or Remove. Component variable Mode. Default Apply.

.PARAMETER AccountName
    Temporary local administrator. Component variable AccountName. Default migrate.

.PARAMETER Password
    Password for the account, instead of the prefix + date + suffix rule. Component variable
    Password (make it a masked/secret variable). Default: the rule.

.PARAMETER PasswordPrefix
    Text before the date part. Component variable PasswordPrefix. Default in $DefaultPasswordPrefix.

.PARAMETER PasswordSuffix
    Text after the date part. Component variable PasswordSuffix. Default in $DefaultPasswordSuffix.

.PARAMETER DaysToExpire
    Days until the account expires and everything is removed. Component variable DaysToExpire.
    Default 14.

.PARAMETER ShareName
    Component variable ShareName. Default Users$ (the $ hides it from browsing).

.PARAMETER SetNetworkPrivate
    "true"/"false". Component variable SetNetworkPrivate. Default true.

.PARAMETER Help
    Prints this usage and exits. Same as --help, --usage, -Usage or -?.

.NOTES
    Name:            Initialize-UserMigrationShare.ps1
    Author:          Stephen Bozarth
    Created:         2026-10-28
    Modified:        2026-10-28
    Version:         2.0.0
    Ticket:          no-ticket
    Permissions:     Local System (Datto RMM agent) or an elevated admin shell
    Unattended-safe: Yes. Creates a temporary admin account and a share that remove themselves
                     after DaysToExpire; Remove undoes only what it recorded. Never deletes files.
    RMM name:        [Migration] Initialize-UserMigrationShare - Prepare Users folder for data migration

    Replaces Set-NetworkShare 1.0.0. Windows PowerShell 5.1 or PowerShell 7.

.EXAMPLE
    .\Initialize-UserMigrationShare.ps1 -Mode DetectOnly

.EXAMPLE
    .\Initialize-UserMigrationShare.ps1 -DaysToExpire 7

.EXAMPLE
    .\Initialize-UserMigrationShare.ps1 -Mode Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param (
    [Parameter(ParameterSetName = 'Run')][string]$Mode           = $(if ("$env:Mode".Trim()) { "$env:Mode".Trim() } else { 'Apply' }),
    [Parameter(ParameterSetName = 'Run')][string]$AccountName    = $(if ("$env:AccountName".Trim()) { "$env:AccountName".Trim() } else { 'migrate' }),
    [Parameter(ParameterSetName = 'Run')][string]$Password       = "$env:Password",
    [Parameter(ParameterSetName = 'Run')][string]$PasswordPrefix = "$env:PasswordPrefix",
    [Parameter(ParameterSetName = 'Run')][string]$PasswordSuffix = "$env:PasswordSuffix",
    [Parameter(ParameterSetName = 'Run')][string]$DaysToExpire   = $(if ("$env:DaysToExpire".Trim()) { "$env:DaysToExpire".Trim() } else { '14' }),
    [Parameter(ParameterSetName = 'Run')][string]$ShareName      = $(if ("$env:ShareName".Trim()) { "$env:ShareName".Trim() } else { 'Users$' }),
    [Parameter(ParameterSetName = 'Run')][string]$SetNetworkPrivate = $(if ("$env:SetNetworkPrivate".Trim()) { "$env:SetNetworkPrivate".Trim() } else { 'true' }),

    # Usage: -Help, -Usage, --help, --usage or -? (repo rule, naming conventions §9)
    [Parameter(ParameterSetName = 'Help')][Alias('Usage', '-help', '-usage')][switch]$Help,
    [Parameter(ParameterSetName = 'Help', ValueFromRemainingArguments, DontShow)][string[]]$HelpArgs
)

if ($Help -or $HelpArgs -or @($PSBoundParameters.Values | ForEach-Object { $_ } | Where-Object { "$_" -in '--help', '--usage' }).Count) {
    $unknown = @(@($HelpArgs) | Where-Object { $_ -and $_ -notin '--help', '--usage', '-h', '/?' })
    if ($unknown.Count) { Write-Warning "Unknown argument(s): $($unknown -join ' ')" }
    Get-Help $PSCommandPath -Detailed | Out-String -Width 120
    exit $(if ($unknown.Count) { 1 } else { 0 })
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # no progress bars in a component (§9)

# ======================= Defaults (edit here) =======================================
# Password rule: <prefix><yy><day of year, 3 digits><suffix>, e.g. 1 Jan 2027 -> Mig27001!
$DefaultPasswordPrefix = 'Mig'
$DefaultPasswordSuffix = '!'
# =====================================================================================

$RecordKey   = 'HKLM:\SOFTWARE\BozNW\UserMigrationShare'
$WorkDir     = Join-Path $env:ProgramData 'BozNW\UserMigrationShare'
$TaskName    = 'BozNW - Remove user migration share'
$FwRuleName  = 'BozNW-SMB-In'
$FwRuleTitle = 'BozNW - SMB-In (Domain/Private)'
$UacKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$UacValue    = 'LocalAccountTokenFilterPolicy'
$AdminsSid   = 'S-1-5-32-544'
$AuthUsersSid = 'S-1-5-11'

function Write-Log { param([string]$Level, [string]$Message) Write-Output "[$Level] $Message" }

# Local password policy: @{ MinLength; Complexity } from secedit (language independent).
function Get-PasswordPolicy {
    $cfg = Join-Path $env:TEMP ("secpol-{0}.inf" -f [guid]::NewGuid().ToString('N'))
    $pol = @{ MinLength = 0; Complexity = $false }
    try {
        & secedit.exe /export /cfg $cfg /areas SECURITYPOLICY /quiet | Out-Null
        foreach ($line in (Get-Content $cfg -ErrorAction Stop)) {
            if ($line -match '^\s*MinimumPasswordLength\s*=\s*(\d+)') { $pol.MinLength = [int]$Matches[1] }
            if ($line -match '^\s*PasswordComplexity\s*=\s*(\d+)')    { $pol.Complexity = $Matches[1] -eq '1' }
        }
    }
    catch { Write-Log WARN "Could not read the password policy ($($_.Exception.Message)); assuming none" }
    finally { Remove-Item $cfg -Force -ErrorAction SilentlyContinue }
    $pol
}

# Extends <prefix><date><suffix> until it meets the policy. Returns @{ Password; Pattern; Notes }.
function Resolve-RulePassword([string]$Prefix, [string]$DatePart, [string]$Suffix, [string]$Year, [hashtable]$Policy, [string]$Account) {
    $mid = $DatePart; $notes = @()
    $build = { "$Prefix$mid$Suffix" }
    while ((& $build).Length -lt $Policy.MinLength) { $mid += $Year }
    if ($mid -ne $DatePart) {
        $notes += "minimum length $($Policy.MinLength): year $Year appended to the date part ($(($mid.Length - $DatePart.Length) / 4)x)"
    }
    if ($Policy.Complexity) {
        $pw = & $build
        $classes = @(($pw -cmatch '[A-Z]'), ($pw -cmatch '[a-z]'), ($pw -match '\d'), ($pw -match '[^A-Za-z0-9]')) | Where-Object { $_ }
        $extra = ''
        foreach ($c in @(@('[A-Z]', 'A'), @('[a-z]', 'a'), @('[^A-Za-z0-9]', '!'))) {
            if (@($classes).Count + $extra.Length -ge 3) { break }
            if ($pw -cnotmatch $c[0]) { $extra += $c[1] }
        }
        if ($extra) { $notes += "complexity: '$extra' added after the suffix" }
        if ($Account -and ($pw + $extra) -match [regex]::Escape($Account)) { throw "the password would contain the account name '$Account' (complexity rule); change AccountName or the prefix" }
        return @{ Password = (& $build) + $extra; Pattern = "<prefix>$mid<suffix>$extra"; Notes = $notes }
    }
    @{ Password = (& $build); Pattern = "<prefix>$mid<suffix>"; Notes = $notes }
}
function Get-SidName([string]$Sid) { (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value }
function Get-Record { if (Test-Path $RecordKey) { Get-ItemProperty $RecordKey } else { $null } }
function Save-Record([hashtable]$Values) {
    if (-not (Test-Path $RecordKey)) { New-Item $RecordKey -Force | Out-Null }
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($v -is [array]) { New-ItemProperty $RecordKey -Name $k -Value ([string[]]$v) -PropertyType MultiString -Force | Out-Null }
        else { New-ItemProperty $RecordKey -Name $k -Value "$v" -PropertyType String -Force | Out-Null }
    }
}

# ================= Remove =================
function Invoke-Remove {
    $rec = Get-Record
    if (-not $rec) { Write-Output 'RESULT: SKIPPED nothing recorded; nothing removed'; exit 2 }
    $names = @($rec.PSObject.Properties.Name)
    $val = { param($n) if ($names -contains $n) { "$($rec.$n)" } else { '' } }

    if ((& $val 'CreatedTask') -eq '1') {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log INFO "Removed scheduled task '$TaskName'"
    }
    $share = & $val 'ShareName'
    if ((& $val 'CreatedShare') -eq '1' -and $share -and (Get-SmbShare -Name $share -ErrorAction SilentlyContinue)) {
        Remove-SmbShare -Name $share -Force; Write-Log INFO "Removed share $share"
    }
    $acct = & $val 'AccountName'
    if ((& $val 'CreatedAccount') -eq '1' -and $acct -and (Get-LocalUser -Name $acct -ErrorAction SilentlyContinue)) {
        Remove-LocalUser -Name $acct; Write-Log INFO "Removed account $acct"
    }
    if ((& $val 'UacChanged') -eq '1') {
        $prev = & $val 'UacPrevious'
        if ($prev -eq '<none>') { Remove-ItemProperty $UacKey -Name $UacValue -ErrorAction SilentlyContinue }
        else { New-ItemProperty $UacKey -Name $UacValue -Value ([int]$prev) -PropertyType DWord -Force | Out-Null }
        Write-Log INFO "$UacValue restored to $prev"
    }
    if ((& $val 'CreatedFirewallRule') -eq '1') {
        Remove-NetFirewallRule -Name $FwRuleName -ErrorAction SilentlyContinue; Write-Log INFO "Removed firewall rule $FwRuleTitle"
    }
    foreach ($alias in @($rec.PSObject.Properties | Where-Object Name -eq 'ProfilesMadePrivate' | ForEach-Object { $_.Value }) | Where-Object { $_ }) {
        $cp = Get-NetConnectionProfile -InterfaceAlias $alias -ErrorAction SilentlyContinue
        if ($cp -and $cp.NetworkCategory -eq 'Private') { Set-NetConnectionProfile -InterfaceAlias $alias -NetworkCategory Public; Write-Log INFO "Network '$alias' set back to Public" }
    }
    Remove-Item $RecordKey -Recurse -Force
    # The clean-up task runs the copy in $WorkDir; leave the folder for it, delete it otherwise.
    if ($PSCommandPath -notlike "$WorkDir*") { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output 'RESULT: SUCCESS migration share and account removed; settings restored'
    exit 0
}

try {
    if ($Mode -notin 'Apply', 'DetectOnly', 'Remove') { throw "Mode '$Mode' must be Apply, DetectOnly or Remove" }
    Write-Log INFO "Mode: $Mode on $env:COMPUTERNAME"
    if ($Mode -eq 'Remove') { Invoke-Remove }

    # ---- Inputs ----
    $days = 0
    if (-not [int]::TryParse($DaysToExpire, [ref]$days) -or $days -lt 1 -or $days -gt 90) { throw "DaysToExpire '$DaysToExpire' must be 1 to 90" }
    if ($SetNetworkPrivate -notin 'true', 'false') { throw "SetNetworkPrivate must be true or false" }
    if ($AccountName -notmatch '^[A-Za-z0-9._-]{1,20}$') { throw "AccountName '$AccountName' is not a valid local user name" }
    if ($ShareName -notmatch '^[^\\/:*?"<>|\[\]=;,+]{1,80}$' -or $ShareName -in 'ADMIN$', 'IPC$', 'C$') { throw "ShareName '$ShareName' is not valid" }

    $now     = Get-Date
    $expires = $now.Date.AddDays($days + 1).AddMinutes(-1)          # end of the last day
    $datePart = '{0:yy}{1:000}' -f $now, $now.DayOfYear
    $policy = Get-PasswordPolicy
    Write-Log INFO "Password policy: minimum length $($policy.MinLength), complexity $(if ($policy.Complexity) { 'on' } else { 'off' })"
    if ($Password) { $pw = $Password; $pwNote = 'from the Password variable' }
    else {
        $pre = if ("$PasswordPrefix".Trim()) { $PasswordPrefix } else { $DefaultPasswordPrefix }
        $suf = if ("$PasswordSuffix".Trim()) { $PasswordSuffix } else { $DefaultPasswordSuffix }
        $res = Resolve-RulePassword $pre $datePart $suf ('{0:yyyy}' -f $now) $policy $AccountName
        $pw = $res.Password
        $pwNote = $res.Pattern   # prefix and suffix masked: the job output never shows the password
        foreach ($n in $res.Notes) { Write-Log WARN "Password adjusted for the PC's policy: $n -> $pwNote" }
    }
    $profilesDir = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').ProfilesDirectory)

    $DryRun = $Mode -eq 'DetectOnly'
    $Would  = if ($DryRun) { 'would ' } else { '' }
    $rec    = Get-Record
    $r = @{}
    if ($rec) { foreach ($p in $rec.PSObject.Properties) { if ($p.Name -notlike 'PS*') { $r[$p.Name] = $p.Value } } }
    $r.AccountName = $AccountName; $r.ShareName = $ShareName

    # 1. Server service
    $svc = Get-Service LanmanServer
    if ($svc.StartType -ne 'Automatic' -or $svc.Status -ne 'Running') {
        Write-Log INFO "${Would}set the Server service to Automatic and start it"
        if (-not $DryRun) { Set-Service LanmanServer -StartupType Automatic; Start-Service LanmanServer }
    }

    # 2-3. Account
    $admins = Get-SidName $AdminsSid
    $user = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if ($user -and "$($r.CreatedAccount)" -ne '1') { throw "a local account named $AccountName already exists and wasn't created by this component; set AccountName to another name" }
    $secure = ConvertTo-SecureString $pw -AsPlainText -Force
    $desc = "BozNW data migration, expires $($expires.ToString('yyyy-MM-dd'))"   # max 48 chars
    if (-not $user) {
        Write-Log INFO "${Would}create local administrator $AccountName (expires $($expires.ToString('yyyy-MM-dd HH:mm')))"
        if (-not $DryRun) {
            New-LocalUser -Name $AccountName -Password $secure -AccountExpires $expires -PasswordNeverExpires -UserMayNotChangePassword `
                -Description $desc -FullName 'Data migration (temporary)' | Out-Null
            $r.CreatedAccount = '1'
        }
    }
    else {
        Write-Log INFO "${Would}reset password and expiry of $AccountName (expires $($expires.ToString('yyyy-MM-dd HH:mm')))"
        if (-not $DryRun) { Set-LocalUser -Name $AccountName -Password $secure -AccountExpires $expires -Description $desc; Enable-LocalUser -Name $AccountName }
    }
    if (-not $DryRun) {
        $member = @(Get-LocalGroupMember -SID $AdminsSid -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$AccountName" })
        if (-not $member.Count) { Add-LocalGroupMember -SID $AdminsSid -Member $AccountName; Write-Log INFO "Added $AccountName to $admins" }
    }

    # 4. Share
    $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Path.TrimEnd('\') -ine $profilesDir.TrimEnd('\')) { throw "a share named $ShareName already exists on another path ($($existing.Path))" }
    if (-not $existing) {
        Write-Log INFO "${Would}share $profilesDir as $ShareName"
        if (-not $DryRun) {
            New-SmbShare -Name $ShareName -Path $profilesDir -FullAccess $admins -ReadAccess (Get-SidName $AuthUsersSid) `
                -FolderEnumerationMode AccessBased -Description 'Data migration share (BozNW, temporary)' | Out-Null
            $r.CreatedShare = '1'
        }
    }

    # 5. Remote admin
    $cur = (Get-ItemProperty $UacKey -Name $UacValue -ErrorAction SilentlyContinue).$UacValue
    if ($cur -ne 1) {
        Write-Log INFO "${Would}set $UacValue = 1 (was $(if ($null -eq $cur) { 'not set' } else { $cur }))"
        if (-not $DryRun) {
            if ("$($r.UacChanged)" -ne '1') { $r.UacChanged = '1'; $r.UacPrevious = if ($null -eq $cur) { '<none>' } else { "$cur" } }
            New-ItemProperty $UacKey -Name $UacValue -Value 1 -PropertyType DWord -Force | Out-Null
        }
    }

    # 6. Firewall
    $rule = Get-NetFirewallRule -Name $FwRuleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        Write-Log INFO "${Would}add firewall rule '$FwRuleTitle'"
        if (-not $DryRun) {
            New-NetFirewallRule -Name $FwRuleName -DisplayName $FwRuleTitle -Direction Inbound -Protocol TCP -LocalPort 445 `
                -Action Allow -Profile Domain, Private -Description 'Added by [Migration] Initialize-UserMigrationShare' | Out-Null
            $r.CreatedFirewallRule = '1'
        }
    }
    elseif ("$($rule.Enabled)" -ne 'True' -and -not $DryRun) { Enable-NetFirewallRule -Name $FwRuleName }

    # 7. Network profile
    $madePriv = @($r.ProfilesMadePrivate | Where-Object { $_ })
    $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object NetworkCategory -eq 'Public')
    foreach ($n in $public) {
        if ($SetNetworkPrivate -eq 'true') {
            Write-Log INFO "${Would}set network '$($n.InterfaceAlias)' ($($n.Name)) to Private"
            if (-not $DryRun) { Set-NetConnectionProfile -InterfaceIndex $n.InterfaceIndex -NetworkCategory Private; if ($n.InterfaceAlias -notin $madePriv) { $madePriv += $n.InterfaceAlias } }
        }
        else { Write-Log WARN "Network '$($n.InterfaceAlias)' is Public: the share can't be reached over it" }
    }
    $r.ProfilesMadePrivate = [string[]]$madePriv

    # 8. Clean-up task
    Write-Log INFO "${Would}schedule '$TaskName' for $($expires.ToString('yyyy-MM-dd HH:mm'))"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        $copy = Join-Path $WorkDir 'Initialize-UserMigrationShare.ps1'
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) { Copy-Item -LiteralPath $PSCommandPath -Destination $copy -Force }
        else { Set-Content -Path $copy -Value $MyInvocation.MyCommand.ScriptBlock.ToString() -Encoding UTF8 }
        $action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$copy`" -Mode Remove"
        $trigger   = New-ScheduledTaskTrigger -Once -At $expires
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        $r.CreatedTask = '1'
    }

    if ($DryRun) { Write-Output 'RESULT: SUCCESS DetectOnly: nothing changed'; exit 0 }

    $r.Expires = $expires.ToString('s'); $r.Modified = $now.ToString('s')
    Save-Record $r

    # Read back
    $share = Get-SmbShare -Name $ShareName
    $u = Get-LocalUser -Name $AccountName
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object IPAddress)
    Write-Output "SHARE: \\$env:COMPUTERNAME\$ShareName -> $($share.Path)$(if ($ips.Count) { "  (or \\$($ips[0])\$ShareName)" })"
    Write-Output "ACCOUNT: $env:COMPUTERNAME\$AccountName (local administrator), password $pwNote"
    Write-Output "EXPIRES: $($u.AccountExpires.ToString('yyyy-MM-dd HH:mm')); then '$TaskName' removes the share, account and settings"
    if ($ips.Count) { Write-Output "ADDRESS: $($ips -join ', ')" }
    Write-Output "RESULT: SUCCESS migration share ready for $days day(s)"
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output "RESULT: FAILURE $($_.Exception.Message)"
    exit 1
}
