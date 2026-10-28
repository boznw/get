$a = Get-NetAdapter -Physical | Where-Object InterfaceDescription -match 'Ethernet'
foreach ($n in $a) {
  "Adapter: $($n.Name) $($n.InterfaceDescription) $($n.Status)"
  $pm = Get-NetAdapterPowerManagement -Name $n.Name
  "PM: " + (($pm | Select-Object * -ExcludeProperty Cim*,PS* | Out-String -Width 200).Trim() -replace "`r?`n", ' | ')
  $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
  foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if ($p -and "$($p.NetCfgInstanceId)" -ieq "$($n.InterfaceGuid)") {
      "Class key: $($k.PSChildName)"
      $p.PSObject.Properties | Where-Object { $_.Name -match 'Suspend|SS|PnPCap|Idle|Sleep|Power|EEE|ULP' } | ForEach-Object { "  $($_.Name) = $($_.Value)" }
    }
  }
  Get-NetAdapterAdvancedProperty -Name $n.Name -AllProperties | Where-Object { $_.RegistryKeyword -match 'Suspend|SS|Idle' } | ForEach-Object { "  ADV $($_.RegistryKeyword) [$($_.DisplayName)] = $($_.RegistryValue)" }
}
'RESULT: SUCCESS diag'
