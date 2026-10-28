<#
.SYNOPSIS
    Shares a folder on this PC (default: C:\Users as the hidden share Users$) so it can be
    opened from another PC on the network. Apply, DetectOnly or Remove.

.DESCRIPTION
    Built so a user can open their old PC from the new one (\\OLDPC\Users$), sign in with an
    account on the old PC, and copy whatever they choose.

    Mode Apply (default):

      1. Server service (LanmanServer): set to Automatic and started.
      2. Share: SharePath shared as ShareName with the given share rights. If the share already
         exists on the same path, missing rights are granted and extra entries only reported.
         If it exists on another path, the run fails and changes nothing. NTFS permissions are
         not changed: each account sees exactly what it can see when signed in locally (a user
         their own profile, an administrator everything).
      3. Remote admin (AllowRemoteAdmin, default true): on a workgroup PC Windows removes admin
         rights from local accounts that connect over the network (remote UAC), so a local
         administrator would get "access denied" on other users' profiles. This sets
         LocalAccountTokenFilterPolicy = 1 so local administrators keep their rights over the
         share. Remove puts the old value back. Not needed on a domain.
      4. Firewall: one inbound rule, "BozNW - SMB-In (Domain/Private)", TCP 445, Domain and
         Private profiles only. Never opened on Public.
      5. Network profile: a connection on the Public profile can't be reached. It's reported,
         and switched to Private only if SetNetworkPrivate is true.

    Everything changed is recorded in HKLM\SOFTWARE\BozNW\NetworkShare\<ShareName>, and Mode
    Remove undoes exactly that. No folder or file is ever created or deleted, except the
    folder when SharePath doesn't exist yet (that folder is kept on Remove).

    Mode DetectOnly prints what Apply would do and changes nothing.

.PARAMETER ShareName
    Share name. A trailing $ hides it from browsing. Component variable ShareName. Default Users$.

.PARAMETER SharePath
    Local folder to share. Component variable SharePath. Default the profiles folder (C:\Users).

.PARAMETER FullAccess
    Comma-separated principals with Full share access. Component variable FullAccess. Default
    Administrators.

.PARAMETER ChangeAccess
    Comma-separated principals with Change share access. Component variable ChangeAccess.
    Default none.

.PARAMETER ReadAccess
    Comma-separated principals with Read share access. Component variable ReadAccess. Default
    Authenticated Users.

.PARAMETER Mode
    Apply, DetectOnly or Remove. Component variable Mode. Default Apply.

.PARAMETER AllowRemoteAdmin
    "true"/"false". Component variable AllowRemoteAdmin. Default true (see step 3).

.PARAMETER SetNetworkPrivate
    Switches connections on the Public profile to Private. Component variable
    SetNetworkPrivate ("true"). Default off: reported only.

.PARAMETER Help
    Prints this usage and exits. Same as --help, --usage, -Usage or -?.

.NOTES
    Name:            Set-NetworkShare.ps1
    Author:          Stephen Bozarth
    Created:         2026-10-28
    Modified:        2026-10-28
    Version:         1.0.0
    Ticket:          no-ticket
    Permissions:     Local System (Datto RMM agent) or an elevated admin shell
    Unattended-safe: Yes. Adds a share, one firewall rule and (optionally) one registry value;
                     Remove undoes only what it recorded. Never deletes files.
    RMM name:        [Network] Set-NetworkShare - Share a folder on this PC

    Datto RMM passes input variables as environment variables (always strings). Each parameter
    defaults to its component variable, so the same file runs as a component or by hand.

.EXAMPLE
    .\Set-NetworkShare.ps1 -Mode DetectOnly

.EXAMPLE
    .\Set-NetworkShare.ps1 -SetNetworkPrivate

.EXAMPLE
    .\Set-NetworkShare.ps1 -Mode Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param (
    [Parameter(ParameterSetName = 'Run')][string]$ShareName = $(if ("$env:ShareName".Trim()) { "$env:ShareName".Trim() } else { 'Users$' }),
    [Parameter(ParameterSetName = 'Run')][string]$SharePath = "$env:SharePath".Trim(),
    [Parameter(ParameterSetName = 'Run')][string]$FullAccess = $(if ($null -ne $env:FullAccess) { $env:FullAccess } else { 'Administrators' }),
    [Parameter(ParameterSetName = 'Run')][string]$ChangeAccess = "$env:ChangeAccess",
    [Parameter(ParameterSetName = 'Run')][string]$ReadAccess = $(if ($null -ne $env:ReadAccess) { $env:ReadAccess } else { 'Authenticated Users' }),
    [Parameter(ParameterSetName = 'Run')][string]$Mode = $(if ("$env:Mode".Trim()) { "$env:Mode".Trim() } else { 'Apply' }),
    [Parameter(ParameterSetName = 'Run')][string]$AllowRemoteAdmin = $(if ("$env:AllowRemoteAdmin".Trim()) { "$env:AllowRemoteAdmin".Trim() } else { 'true' }),
    [Parameter(ParameterSetName = 'Run')][switch]$SetNetworkPrivate = ("$env:SetNetworkPrivate".Trim() -eq 'true'),

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

$RecordRoot  = 'HKLM:\SOFTWARE\BozNW\NetworkShare'
$FwRuleName  = 'BozNW-SMB-In'
$FwRuleTitle = 'BozNW - SMB-In (Domain/Private)'
$UacKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$UacValue    = 'LocalAccountTokenFilterPolicy'
$Rank        = @{ Read = 1; Change = 2; Full = 3 }

function Write-Log { param([string]$Level, [string]$Message) Write-Output "[$Level] $Message" }

function Resolve-Principal {
    # Name or SID -> account name as this PC knows it. Throws if it doesn't exist.
    param([string]$Value)
    try {
        if ($Value -match '^S-1-[\d-]+$') { $sid = New-Object Security.Principal.SecurityIdentifier $Value }
        else { $sid = (New-Object Security.Principal.NTAccount $Value).Translate([Security.Principal.SecurityIdentifier]) }
        $sid.Translate([Security.Principal.NTAccount]).Value
    }
    catch { throw "Principal '$Value' doesn't exist on this PC" }
}

function Get-RequestedAccess {
    # One entry per principal with its highest requested right.
    $map = [ordered]@{}
    foreach ($pair in @(@('Full', $FullAccess), @('Change', $ChangeAccess), @('Read', $ReadAccess))) {
        foreach ($raw in ("$($pair[1])" -split ',')) {
            if (-not $raw.Trim()) { continue }
            $name = Resolve-Principal $raw.Trim()
            if (-not $map.Contains($name) -or $Rank[$pair[0]] -gt $Rank[$map[$name]]) { $map[$name] = $pair[0] }
        }
    }
    @($map.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Right = $map[$_] } })
}

function Save-Record {
    param([string]$Name, [hashtable]$Values)
    $key = Join-Path $RecordRoot $Name
    if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
    foreach ($k in $Values.Keys) {
        $v = $Values[$k]
        if ($v -is [array]) { New-ItemProperty $key -Name $k -Value ([string[]]$v) -PropertyType MultiString -Force | Out-Null }
        else { New-ItemProperty $key -Name $k -Value "$v" -PropertyType String -Force | Out-Null }
    }
}

try {
    if ($Mode -notin 'Apply', 'DetectOnly', 'Remove') { throw "Mode '$Mode' must be Apply, DetectOnly or Remove" }
    if ($AllowRemoteAdmin -notin 'true', 'false') { throw "AllowRemoteAdmin '$AllowRemoteAdmin' must be true or false" }
    if (-not $ShareName -or $ShareName.Length -gt 80 -or $ShareName -match '[\\/:*?"<>|\[\]=;,+]') { throw "ShareName '$ShareName' is not a valid share name" }
    if ($ShareName -in 'ADMIN$', 'IPC$', 'print$' -or $ShareName -match '^[A-Za-z]\$$') { throw "ShareName '$ShareName' is a Windows system share" }
    $recKey = Join-Path $RecordRoot $ShareName
    Write-Log INFO "Mode: $Mode; share: $ShareName"

    # ================= Remove =================
    if ($Mode -eq 'Remove') {
        if (-not (Test-Path $recKey)) { Write-Output 'RESULT: SKIPPED nothing recorded for this share; nothing removed'; exit 2 }
        $rec = Get-ItemProperty $recKey
        if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
            if ($rec.CreatedShare -eq '1') { Remove-SmbShare -Name $ShareName -Force; Write-Log INFO "Removed share $ShareName" }
            else {
                foreach ($n in @($rec.ShareGrants | Where-Object { $_ })) {
                    Revoke-SmbShareAccess -Name $ShareName -AccountName $n -Force | Out-Null
                    Write-Log INFO "Revoked share access for $n"
                }
            }
        }
        if ($rec.UacChanged -eq '1') {
            if ($rec.UacPrevious -eq '<none>') { Remove-ItemProperty $UacKey -Name $UacValue -ErrorAction SilentlyContinue }
            else { New-ItemProperty $UacKey -Name $UacValue -Value ([int]$rec.UacPrevious) -PropertyType DWord -Force | Out-Null }
            Write-Log INFO "$UacValue restored to $($rec.UacPrevious)"
        }
        foreach ($alias in @($rec.ProfilesMadePrivate | Where-Object { $_ })) {
            $cp = Get-NetConnectionProfile -InterfaceAlias $alias -ErrorAction SilentlyContinue
            if ($cp -and $cp.NetworkCategory -eq 'Private') { Set-NetConnectionProfile -InterfaceAlias $alias -NetworkCategory Public; Write-Log INFO "Network '$alias' set back to Public" }
        }
        Remove-Item $recKey -Recurse -Force
        if (-not @(Get-ChildItem $RecordRoot -ErrorAction SilentlyContinue).Count -and
            (Get-ItemProperty $RecordRoot -ErrorAction SilentlyContinue).CreatedFirewallRule -eq '1') {
            Remove-NetFirewallRule -Name $FwRuleName -ErrorAction SilentlyContinue
            Remove-ItemProperty $RecordRoot -Name CreatedFirewallRule -ErrorAction SilentlyContinue
            Write-Log INFO "Removed firewall rule $FwRuleTitle"
        }
        Write-Output 'RESULT: SUCCESS share removed and settings restored'
        exit 0
    }

    # ================= Apply / DetectOnly =================
    $DryRun = $Mode -eq 'DetectOnly'
    $Would  = if ($DryRun) { 'would ' } else { '' }
    if (-not $SharePath) {
        $SharePath = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').ProfilesDirectory)
    }
    if ($SharePath -notmatch '^[A-Za-z]:\\.+') { throw "SharePath '$SharePath' must be a local folder like C:\Users (not a drive root)" }
    $SharePath = [IO.Path]::GetFullPath($SharePath).TrimEnd('\')
    $access = Get-RequestedAccess
    foreach ($a in $access) { Write-Log INFO "Share access requested: $($a.Name) = $($a.Right)" }

    $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($existing -and $existing.Path.TrimEnd('\') -ine $SharePath) { throw "a share named $ShareName already exists on another path ($($existing.Path))" }

    $rec = if (Test-Path $recKey) { Get-ItemProperty $recKey } else { $null }
    $created     = if ($rec) { "$($rec.CreatedShare)" } else { '0' }
    $shareGrants = @(if ($rec) { $rec.ShareGrants | Where-Object { $_ } })
    $madePriv    = @(if ($rec) { $rec.ProfilesMadePrivate | Where-Object { $_ } })
    $uacChanged  = if ($rec) { "$($rec.UacChanged)" } else { '0' }
    $uacPrevious = if ($rec) { "$($rec.UacPrevious)" } else { '' }
    $changes = 0

    # 1. Server service
    $svc = Get-Service LanmanServer
    if ($svc.StartType -ne 'Automatic' -or $svc.Status -ne 'Running') {
        Write-Log INFO "${Would}set the Server service to Automatic and start it (was $($svc.StartType), $($svc.Status))"
        if (-not $DryRun) { Set-Service LanmanServer -StartupType Automatic; Start-Service LanmanServer }
        $changes++
    }

    # 2. Share
    if (-not (Test-Path -LiteralPath $SharePath -PathType Container)) {
        Write-Log INFO "${Would}create folder $SharePath"
        if (-not $DryRun) { New-Item -ItemType Directory -Path $SharePath -Force | Out-Null }
        $changes++
    }
    if (-not $existing) {
        Write-Log INFO "${Would}create share $ShareName -> $SharePath"
        if (-not $DryRun) {
            $splat = @{ Name = $ShareName; Path = $SharePath; FolderEnumerationMode = 'AccessBased'; Description = 'Added by [Network] Set-NetworkShare' }
            foreach ($r in 'Full', 'Change', 'Read') {
                $names = @($access | Where-Object Right -eq $r | ForEach-Object Name)
                if ($names.Count) { $splat["${r}Access"] = [string[]]$names }
            }
            New-SmbShare @splat | Out-Null
            $created = '1'
        }
        $changes++
    }
    else {
        $current = @(Get-SmbShareAccess -Name $ShareName)
        foreach ($a in $access) {
            $entry = $current | Where-Object { $_.AccountName -ieq $a.Name -and "$($_.AccessControlType)" -eq 'Allow' } | Select-Object -First 1
            if ($entry -and $Rank["$($entry.AccessRight)"] -ge $Rank[$a.Right]) { continue }
            Write-Log INFO "${Would}grant share $($a.Right) to $($a.Name)"
            if (-not $DryRun) {
                Grant-SmbShareAccess -Name $ShareName -AccountName $a.Name -AccessRight $a.Right -Force | Out-Null
                if (-not $entry -and $a.Name -notin $shareGrants) { $shareGrants += $a.Name }
            }
            $changes++
        }
        foreach ($e in $current) {
            if (-not @($access | Where-Object { $_.Name -ieq $e.AccountName }).Count) { Write-Log WARN "Share also grants $($e.AccessControlType) $($e.AccessRight) to $($e.AccountName) (left as is)" }
        }
    }

    # 3. Remote admin for local accounts
    if ($AllowRemoteAdmin -eq 'true') {
        $cur = (Get-ItemProperty $UacKey -Name $UacValue -ErrorAction SilentlyContinue).$UacValue
        if ($cur -ne 1) {
            Write-Log INFO "${Would}set $UacValue = 1 so local administrators keep admin rights over the network (was $(if ($null -eq $cur) { 'not set' } else { $cur }))"
            if (-not $DryRun) {
                if ($uacChanged -ne '1') { $uacPrevious = if ($null -eq $cur) { '<none>' } else { "$cur" }; $uacChanged = '1' }
                New-ItemProperty $UacKey -Name $UacValue -Value 1 -PropertyType DWord -Force | Out-Null
            }
            $changes++
        }
    }

    # 4. Firewall
    $rule = Get-NetFirewallRule -Name $FwRuleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        Write-Log INFO "${Would}add firewall rule '$FwRuleTitle' (TCP 445 in, Domain/Private)"
        if (-not $DryRun) {
            New-NetFirewallRule -Name $FwRuleName -DisplayName $FwRuleTitle -Direction Inbound -Protocol TCP -LocalPort 445 `
                -Action Allow -Profile Domain, Private -Description 'Added by [Network] Set-NetworkShare' | Out-Null
            if (-not (Test-Path $RecordRoot)) { New-Item $RecordRoot -Force | Out-Null }
            New-ItemProperty $RecordRoot -Name CreatedFirewallRule -Value '1' -PropertyType String -Force | Out-Null
        }
        $changes++
    }
    elseif ("$($rule.Enabled)" -ne 'True') {
        Write-Log INFO "${Would}enable firewall rule '$FwRuleTitle'"
        if (-not $DryRun) { Enable-NetFirewallRule -Name $FwRuleName }
        $changes++
    }

    # 5. Network profile
    $publicNets = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object NetworkCategory -eq 'Public')
    foreach ($n in $publicNets) {
        if ($SetNetworkPrivate) {
            Write-Log INFO "${Would}set network '$($n.InterfaceAlias)' ($($n.Name)) to Private"
            if (-not $DryRun) {
                Set-NetConnectionProfile -InterfaceIndex $n.InterfaceIndex -NetworkCategory Private
                if ($n.InterfaceAlias -notin $madePriv) { $madePriv += $n.InterfaceAlias }
            }
            $changes++
        }
        else { Write-Log WARN "Network '$($n.InterfaceAlias)' ($($n.Name)) is Public: other PCs can't reach the share. Run with SetNetworkPrivate = true" }
    }

    if ($DryRun) {
        Write-Output "SHARE: \\$env:COMPUTERNAME\$ShareName -> $SharePath"
        Write-Output $(if ($changes) { "RESULT: SUCCESS DetectOnly: $changes change(s) needed" } else { 'RESULT: SUCCESS DetectOnly: already configured' })
        exit 0
    }

    Save-Record $ShareName @{
        Path = $SharePath; CreatedShare = $created; ShareGrants = [string[]]$shareGrants
        ProfilesMadePrivate = [string[]]$madePriv; UacChanged = $uacChanged; UacPrevious = $uacPrevious
        Modified = (Get-Date).ToString('s')
    }

    # Read back
    $share = Get-SmbShare -Name $ShareName
    if ($share.Path.TrimEnd('\') -ine $SharePath) { throw "share read back with path $($share.Path)" }
    Write-Output "SHARE: \\$env:COMPUTERNAME\$ShareName -> $($share.Path)"
    foreach ($e in Get-SmbShareAccess -Name $ShareName) { Write-Output "ACCESS: $($e.AccessControlType) $($e.AccessRight) $($e.AccountName)" }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | ForEach-Object IPAddress)
    if ($ips.Count) { Write-Output "ADDRESS: $($ips -join ', ')" }

    $note = if ($publicNets.Count -and -not $SetNetworkPrivate) { '; network is Public, not reachable' } else { '' }
    Write-Output $(if ($changes) { "RESULT: SUCCESS share configured$note" } else { "RESULT: SUCCESS share already configured$note" })
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    Write-Output "RESULT: FAILURE $($_.Exception.Message)"
    exit 1
}
