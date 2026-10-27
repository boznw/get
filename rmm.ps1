<#
  Bozarth Networking - Datto RMM agent bootstrap
  Usage (elevated PowerShell on the new machine):
      irm https://get.boznw.com/rmm | iex

  Installs the agent into a staging site. Move the device to the
  client's real site from the Datto RMM web portal afterward.
#>

# ---- EDIT THESE TWO VALUES -------------------------------------------
$Platform = 'concord'                  # first part of your portal URL, e.g. merlot.centrastage.net
$SiteUID  = '1f678a83-358d-4ac9-8b04-58e241c15736'  # Datto RMM > Sites > (staging site) > Settings > Site UID
# ---------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

# Must be run elevated
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Run PowerShell as Administrator, then try again.' -ForegroundColor Red; return }

# Skip if already installed
if (Get-Service -Name CagService -ErrorAction SilentlyContinue) {
    Write-Host 'Datto RMM agent is already installed.' -ForegroundColor Yellow; return
}

# Older Windows 10 builds default to TLS 1.0/1.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$exe = Join-Path $env:TEMP 'DattoRMMAgent.exe'
$url = "https://$Platform.centrastage.net/csm/profile/downloadAgent/$SiteUID"

Write-Host 'Downloading Datto RMM agent...'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on PS 5.1
Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

# Refuse to run anything that isn't validly signed by Datto/Kaseya
$sig = Get-AuthenticodeSignature -FilePath $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Datto|Kaseya') {
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Write-Host "Installer signature check FAILED (status: $($sig.Status); signer: $($sig.SignerCertificate.Subject)). Not installing." -ForegroundColor Red
    return
}
Write-Host "Signature OK: $($sig.SignerCertificate.Subject)"

Write-Host 'Installing...'
Start-Process -FilePath $exe -Wait
Remove-Item $exe -Force -ErrorAction SilentlyContinue

# Give the service a moment to register
for ($i = 0; $i -lt 30 -and -not (Get-Service CagService -ErrorAction SilentlyContinue); $i++) { Start-Sleep 2 }

if (Get-Service CagService -ErrorAction SilentlyContinue) {
    Write-Host "Done. $env:COMPUTERNAME should appear in Datto RMM within a few minutes." -ForegroundColor Green
} else {
    Write-Host 'Installer ran, but the CagService service was not found. Check the device in Datto RMM.' -ForegroundColor Red
}