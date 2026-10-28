<#
.SYNOPSIS
    Keeps a Windows PC awake and its network adapters powered so a remote session (Datto RMM
    Web Remote, Splashtop, RDP) doesn't drop. Undo with -Mode Restore.

.DESCRIPTION
    Apply (default) changes the ACTIVE power plan and the physical network adapters:

      Power plan (plugged in; on battery too with IncludeBattery)
        - Sleep after                          -> Never
        - Hibernate after                      -> Never
        - Turn off hard disk after             -> Never
        - USB selective suspend                -> Disabled   (USB NICs and docks)
        - PCI Express Link State Power Mgmt    -> Off
        - Wireless adapter power saving        -> Maximum performance
        - Networking connectivity in standby   -> Enabled    (Modern Standby PCs only)
        - Lid close action (plugged in only)   -> Do nothing (IgnoreLidOnAC)

      Network adapters (physical, not Bluetooth)
        - "Allow the computer to turn off this device to save power" -> off
        - Selective suspend / sleep on disconnect (power management)  -> off
        - Driver power-saving options: Energy Efficient Ethernet, Advanced EEE, Green Ethernet,
          Gigabit Lite, Power Saving Mode, Ultra Low Power Mode, Reduce Speed On Power Down,
          System Idle Power Saver, Auto Power Save, Selective Suspend -> Disabled / Off;
          Wi-Fi MIMO Power Save Mode -> No SMPS

    The display is still allowed to turn off: that doesn't drop a remote session.

    Adapter changes are written with -NoRestart, so the adapter does NOT bounce and the session
    running this job stays up. Windows applies them at the next adapter restart or reboot
    (RestartAdapter = true restarts the changed adapters at the end; the connection drops for a
    few seconds).

    The first Apply saves every original value in HKLM:\SOFTWARE\BozNW\RemoteAccessPowerSetting
    (administrators only). Later Applies add only values not yet saved, so Restore always goes back
    to what the PC had before the first run. Restore puts them back and removes the record.

    DetectOnly reports what Apply would change and changes nothing.

    A power setting forced by Group Policy (HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings)
    wins over the plan; those are logged as WARN.

.PARAMETER Mode
    Apply (default), Restore or DetectOnly. Component variable: Mode.

.PARAMETER IncludeBattery
    Also change the on-battery values (except lid close). Default off, so a laptop on battery
    still sleeps and doesn't run flat. Component variable: IncludeBattery ("true"/"false").

.PARAMETER IgnoreLidOnAC
    Closing the lid while plugged in does nothing instead of sleeping. Default on.
    Component variable: IgnoreLidOnAC ("true"/"false").

.PARAMETER RestartAdapter
    Restart each adapter whose driver settings changed so they apply now. Drops the network for a
    few seconds. Default off. Component variable: RestartAdapter ("true"/"false").

.PARAMETER Help
    Prints this usage and exits. Same as --help, --usage, -Usage or -?.

.NOTES
    Name:            Set-RemoteAccessPowerSetting.ps1
    Author:          Stephen Bozarth
    Created:         2026-10-28
    Modified:        2026-10-28
    Version:         1.0.0
    Ticket:          no-ticket
    Permissions:     Local System (Datto RMM agent)
    Unattended-safe: Yes (no adapter bounce unless RestartAdapter = true)
    RMM name:        [Power] Set-RemoteAccessPowerSetting - Keep the PC awake and the network up for remote work

    Exit 0 = done / compliant. Exit 1 = failure, or DetectOnly found settings to change.
    Exit 2 = skipped (Restore with nothing recorded).
    StdOut ends with one "RESULT: SUCCESS|FAILURE|SKIPPED <reason>" line.

.EXAMPLE
    .\Set-RemoteAccessPowerSetting.ps1 -Mode DetectOnly

.EXAMPLE
    .\Set-RemoteAccessPowerSetting.ps1 -IncludeBattery -RestartAdapter

.EXAMPLE
    .\Set-RemoteAccessPowerSetting.ps1 -Mode Restore
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Run')]
param (
    [Parameter(ParameterSetName = 'Run')]
    [string]$Mode = $(if ("$env:Mode".Trim()) { "$env:Mode".Trim() } else { 'Apply' }),

    [Parameter(ParameterSetName = 'Run')]
    [switch]$IncludeBattery = ("$env:IncludeBattery".Trim() -eq 'true'),

    [Parameter(ParameterSetName = 'Run')]
    [switch]$IgnoreLidOnAC = $(if ("$env:IgnoreLidOnAC".Trim()) { "$env:IgnoreLidOnAC".Trim() -eq 'true' } else { $true }),

    [Parameter(ParameterSetName = 'Run')]
    [switch]$RestartAdapter = ("$env:RestartAdapter".Trim() -eq 'true'),

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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # no progress bars in a component (§9)

$ComponentVersion = '1.0.0'
$StateKey         = 'HKLM:\SOFTWARE\BozNW\RemoteAccessPowerSetting'
$PolicyKey        = 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings'

# Power plan settings. Ac/Dc = value Apply sets; Dc only used with IncludeBattery. $null = leave.
$PowerSettings = @(
    @{ Name = 'Sleep after';                        Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Ac = 0; Dc = 0 }
    @{ Name = 'Hibernate after';                    Sub = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Ac = 0; Dc = 0 }
    @{ Name = 'Turn off hard disk after';           Sub = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Ac = 0; Dc = 0 }
    @{ Name = 'USB selective suspend';              Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Ac = 0; Dc = 0 }
    @{ Name = 'PCI Express link state power mgmt';  Sub = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Ac = 0; Dc = 0 }
    @{ Name = 'Wireless adapter power saving';      Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; Ac = 0; Dc = 0 }
    @{ Name = 'Networking connectivity in standby'; Sub = 'fea3413e-7e05-4911-9a71-700331f1c294'; Setting = 'f15576e8-98b7-4186-b944-eafa664402d9'; Ac = 1; Dc = 1; Optional = $true }
    @{ Name = 'Lid close action';                   Sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; Setting = '5ca83367-6e45-459f-a27b-476b1d01c936'; Ac = 0; Dc = $null; Lid = $true }
)

# Adapter driver (advanced) properties to turn off, by registry keyword. Target is the valid value
# whose display text matches the pattern, so the driver's own value for "off" is used.
$AdvancedKeywords = [ordered]@{
    '*EEE'                     = '^(Disabled|Off)$'
    'EEELinkAdvertisement'     = '^(Disabled|Off)$'
    'AdvancedEEE'              = '^(Disabled|Off)$'
    'EnableGreenEthernet'      = '^(Disabled|Off)$'
    'GigaLite'                 = '^(Disabled|Off)$'
    'PowerSavingMode'          = '^(Disabled|Off)$'
    'ULPMode'                  = '^(Disabled|Off)$'
    'ReduceSpeedOnPowerDown'   = '^(Disabled|Off)$'
    'SipsEnabled'              = '^(Disabled|Off)$'
    'AutoPowerSaveModeEnabled' = '^(Disabled|Off)$'
    '*SelectiveSuspend'        = '^(Disabled|Off)$'
    'MIMOPowerSaveMode'        = 'No SMPS'
}
$PmProperties = 'AllowComputerToTurnOffDevice', 'SelectiveSuspend', 'DeviceSleepOnDisconnect'

$script:ExitCode = 1
$script:Result   = 'FAILURE Stopped before completing'

#region ---------------------------------------------------------------- Helpers
function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR', 'CHANGE', 'WOULD')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    [Console]::Out.WriteLine(('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message))
}

function Get-ActiveSchemeGuid {
    $out = (& powercfg.exe /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLower() }
    throw 'Could not read the active power plan'
}

# Returns @{Ac;Dc} or $null when the setting doesn't exist on this PC. The last two 0x values in
# "powercfg /query" are the current AC and DC indexes (works in any display language).
function Get-PowerIndex([string]$Scheme, [string]$Sub, [string]$Setting) {
    $out = & powercfg.exe /query $Scheme $Sub $Setting 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $hex = [regex]::Matches(($out -join "`n"), '0x([0-9a-fA-F]{8})')
    if ($hex.Count -lt 2) { return $null }
    @{
        Ac = [int64][Convert]::ToUInt32($hex[$hex.Count - 2].Groups[1].Value, 16)
        Dc = [int64][Convert]::ToUInt32($hex[$hex.Count - 1].Groups[1].Value, 16)
    }
}

function Set-PowerIndex([string]$Scheme, [string]$Sub, [string]$Setting, [ValidateSet('Ac', 'Dc')][string]$Source, [int64]$Value) {
    $verb = if ($Source -eq 'Ac') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $out = & powercfg.exe $verb $Scheme $Sub $Setting $Value 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $verb $Setting failed: $($out -join ' ')" }
}

function Get-TargetAdapter {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -notmatch 'Bluetooth' })
}

function Read-State {
    if (-not (Test-Path $StateKey)) { return @() }
    $json = (Get-ItemProperty -Path $StateKey -Name Backup -ErrorAction SilentlyContinue).Backup
    if (-not $json) { return @() }
    # Parenthesised so Windows PowerShell 5.1 unrolls the array instead of returning it as one object
    ($json | ConvertFrom-Json) | ForEach-Object { $_ }
}

function Save-State([object[]]$Entries) {
    if (-not (Test-Path $StateKey)) {
        New-Item -Path $StateKey -Force | Out-Null
        $acl = New-Object System.Security.AccessControl.RegistrySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {   # SYSTEM, Administrators
            $id = New-Object System.Security.Principal.SecurityIdentifier $sid
            $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule $id, 'FullControl', 'ContainerInherit', 'None', 'Allow'))
        }
        Set-Acl -Path $StateKey -AclObject $acl
    }
    $json = ConvertTo-Json -InputObject @($Entries) -Depth 4 -Compress
    New-ItemProperty -Path $StateKey -Name Backup -Value $json -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $StateKey -Name Version -Value $ComponentVersion -PropertyType String -Force | Out-Null
}

# Adds an original value to the backup only if that item isn't recorded yet.
function Add-StateEntry([System.Collections.ArrayList]$State, [hashtable]$Entry) {
    if (-not ($State | Where-Object { $_.Key -eq $Entry.Key })) { [void]$State.Add([pscustomobject]$Entry) }
}

function Format-Value([string]$Name, [int64]$Value) {
    if ($Name -like '*after') { if ($Value -eq 0) { 'Never' } else { '{0} min' -f [math]::Round($Value / 60) } }
    else { "$Value" }
}
#endregion

#region ---------------------------------------------------------------- Apply / DetectOnly
function Invoke-Apply([bool]$DetectOnly) {
    $scheme  = Get-ActiveSchemeGuid
    $state   = [System.Collections.ArrayList]@(Read-State)
    $pending = 0; $changed = 0; $nicChanged = @{}
    $verbLevel = if ($DetectOnly) { 'WOULD' } else { 'CHANGE' }
    Write-Log -Message "Active power plan: $scheme"

    # --- Power plan ----------------------------------------------------------------------------
    foreach ($s in $PowerSettings) {
        if ($s.ContainsKey('Lid') -and -not $IgnoreLidOnAC) { continue }
        $cur = Get-PowerIndex $scheme $s.Sub $s.Setting
        if (-not $cur) {
            $lvl = if ($s.ContainsKey('Optional')) { 'INFO' } else { 'WARN' }
            Write-Log $lvl "$($s.Name): not available on this PC, skipped"
            continue
        }
        if (Test-Path (Join-Path $PolicyKey $s.Setting)) { Write-Log WARN "$($s.Name): set by Group Policy; the policy value wins over the plan" }

        foreach ($src in 'Ac', 'Dc') {
            if ($src -eq 'Dc' -and -not $IncludeBattery) { continue }
            $want = $s[$src]
            if ($null -eq $want -or $cur[$src] -eq $want) { continue }
            $label = if ($src -eq 'Ac') { 'plugged in' } else { 'on battery' }
            Write-Log $verbLevel ("{0} ({1}): {2} -> {3}" -f $s.Name, $label, (Format-Value $s.Name $cur[$src]), (Format-Value $s.Name $want))
            $pending++
            if ($DetectOnly) { continue }
            Add-StateEntry $state @{ Key = "PWR|$scheme|$($s.Setting)|$src"; Type = 'Power'; Scheme = $scheme; Sub = $s.Sub; Setting = $s.Setting; Source = $src; Value = $cur[$src]; Name = $s.Name }
            Save-State $state   # record before changing, so a failure part-way can still be restored
            Set-PowerIndex $scheme $s.Sub $s.Setting $src $want
            $changed++
        }
    }
    if (-not $DetectOnly -and $changed) {
        & powercfg.exe /setactive $scheme | Out-Null   # re-apply the plan so new values take effect now
    }

    # --- Network adapters ---------------------------------------------------------------------
    $adapters = Get-TargetAdapter
    if (-not $adapters.Count) { Write-Log WARN 'No physical network adapters found' }
    foreach ($a in $adapters) {
        $guid = "$($a.InterfaceGuid)".ToLower()
        Write-Log -Message "Adapter: $($a.Name) ($($a.InterfaceDescription)) - $($a.Status)"

        # Power management tab
        $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
        if ($pm) {
            $set = @{}
            foreach ($p in $PmProperties) {
                if (-not ($pm.PSObject.Properties.Name -contains $p)) { continue }
                if ("$($pm.$p)" -ne 'Enabled') { continue }
                Write-Log $verbLevel "  $p`: Enabled -> Disabled"
                $pending++
                if ($DetectOnly) { continue }
                Add-StateEntry $state @{ Key = "PM|$guid|$p"; Type = 'NicPm'; Adapter = $guid; AdapterName = $a.Name; Property = $p; Value = 'Enabled' }
                $set[$p] = 'Disabled'
            }
            if ($set.Count) {
                Save-State $state
                Set-NetAdapterPowerManagement -Name $a.Name @set -NoRestart
                $changed += $set.Count; $nicChanged[$a.Name] = $true
            }
        }

        # Advanced (driver) properties
        $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction SilentlyContinue |
            Where-Object { $AdvancedKeywords.Contains($_.RegistryKeyword) })
        foreach ($prop in $props) {
            $kw = $prop.RegistryKeyword
            $display = @($prop.ValidDisplayValues); $values = @($prop.ValidRegistryValues)
            if (-not $display.Count -or $display.Count -ne $values.Count) { continue }
            $i = 0..($display.Count - 1) | Where-Object { $display[$_] -match $AdvancedKeywords[$kw] } | Select-Object -First 1
            if ($null -eq $i) { continue }
            $want = "$($values[$i])"; $cur = "$(@($prop.RegistryValue)[0])"
            if ($cur -eq $want) { continue }
            Write-Log $verbLevel "  $($prop.DisplayName): $($prop.DisplayValue) -> $($display[$i])"
            $pending++
            if ($DetectOnly) { continue }
            Add-StateEntry $state @{ Key = "ADV|$guid|$kw"; Type = 'NicAdv'; Adapter = $guid; AdapterName = $a.Name; Keyword = $kw; Value = $cur }
            Save-State $state
            Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $kw -RegistryValue $want -AllProperties -NoRestart
            $changed++; $nicChanged[$a.Name] = $true
        }
    }

    # --- Result -------------------------------------------------------------------------------
    if ($DetectOnly) {
        if ($pending) { $script:ExitCode = 1; $script:Result = "FAILURE Not compliant: $pending setting(s) would change" }
        else          { $script:ExitCode = 0; $script:Result = 'SUCCESS Compliant: nothing to change' }
        return
    }
    if (-not $changed) { $script:ExitCode = 0; $script:Result = 'SUCCESS Already set: nothing to change'; return }

    $tail = ''
    if ($nicChanged.Count) {
        if ($RestartAdapter) {
            foreach ($n in $nicChanged.Keys) {
                Write-Log WARN "Restarting adapter $n (network drops for a few seconds)"
                Restart-NetAdapter -Name $n -ErrorAction Continue
            }
        }
        else {
            Write-Log -Message 'Adapter changes take effect at the next adapter restart or reboot'
            $tail = '; adapter changes apply after reboot'
        }
    }
    $script:ExitCode = 0
    $script:Result   = "SUCCESS Applied remote access power settings$tail"
}
#endregion

#region ---------------------------------------------------------------- Restore
function Invoke-Restore {
    $state = @(Read-State)
    if (-not $state.Count) { $script:ExitCode = 2; $script:Result = 'SKIPPED Nothing recorded to restore'; return }

    $active = Get-ActiveSchemeGuid; $schemes = @{}; $failed = 0; $nic = $false
    $adapters = @{}; foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) { $adapters["$($a.InterfaceGuid)".ToLower()] = $a }

    foreach ($e in $state) {
        try {
            switch ($e.Type) {
                'Power' {
                    Set-PowerIndex $e.Scheme $e.Sub $e.Setting $e.Source ([int64]$e.Value)
                    $schemes[$e.Scheme] = $true
                    Write-Log CHANGE ("{0} ({1}): restored to {2}" -f $e.Name, $e.Source, (Format-Value $e.Name ([int64]$e.Value)))
                }
                'NicPm' {
                    $a = $adapters[$e.Adapter]
                    if (-not $a) { Write-Log WARN "Adapter $($e.AdapterName) not found; $($e.Property) not restored"; continue }
                    $p = @{ $e.Property = $e.Value }
                    Set-NetAdapterPowerManagement -Name $a.Name @p -NoRestart; $nic = $true
                    Write-Log CHANGE "$($a.Name) $($e.Property): restored to $($e.Value)"
                }
                'NicAdv' {
                    $a = $adapters[$e.Adapter]
                    if (-not $a) { Write-Log WARN "Adapter $($e.AdapterName) not found; $($e.Keyword) not restored"; continue }
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $e.Keyword -RegistryValue $e.Value -AllProperties -NoRestart; $nic = $true
                    Write-Log CHANGE "$($a.Name) $($e.Keyword): restored to $($e.Value)"
                }
            }
        }
        catch { $failed++; Write-Log ERROR "Restore of $($e.Key) failed: $($_.Exception.Message)" }
    }
    if ($schemes.ContainsKey($active)) { & powercfg.exe /setactive $active | Out-Null }

    if ($failed) { $script:ExitCode = 1; $script:Result = "FAILURE Restore incomplete: $failed item(s) failed; record kept"; return }
    Remove-Item -Path $StateKey -Recurse -Force
    $script:ExitCode = 0
    $script:Result   = 'SUCCESS Restored original power settings' + $(if ($nic) { '; adapter changes apply after reboot' } else { '' })
}
#endregion

#region ---------------------------------------------------------------- Main
try {
    Write-Log -Message "Set-RemoteAccessPowerSetting $ComponentVersion on $env:COMPUTERNAME"
    if ($Mode -notin 'Apply', 'Restore', 'DetectOnly') { throw "Mode must be Apply, Restore or DetectOnly (got '$Mode')" }
    Write-Log -Message "Mode: $Mode | IncludeBattery: $IncludeBattery | IgnoreLidOnAC: $IgnoreLidOnAC | RestartAdapter: $RestartAdapter"

    switch ($Mode) {
        'Apply'      { Invoke-Apply -DetectOnly $false }
        'DetectOnly' { Invoke-Apply -DetectOnly $true }
        'Restore'    { Invoke-Restore }
    }
}
catch {
    Write-Log ERROR $_.Exception.Message
    $script:ExitCode = 1
    $script:Result   = "FAILURE $($_.Exception.Message)"
}
Write-Output "RESULT: $script:Result"
exit $script:ExitCode
#endregion
