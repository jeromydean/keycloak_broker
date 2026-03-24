#Requires -Version 5.1
<#
.SYNOPSIS
  One-time dev setup: self-signed TLS certs for each Keycloak instance in docker-compose.

.DESCRIPTION
  Creates three PKCS#12 files under .\certs\ (same password for all; matches compose env).
  Each cert is installed into LocalMachine\Trusted Root so the host (browser, .NET, MSAL)
  trusts HTTPS on localhost.

  Adding to LocalMachine\Root requires Administrator; the script re-launches elevated via
  RunAs when needed (UAC prompt).

.NOTES
  SANs: localhost, 127.0.0.1, host.docker.internal (for optional HTTPS from containers).

  Run from the repository root before: docker compose up -d
#>

# LocalMachine\Root and New-SelfSignedCertificate -CertStoreLocation LocalMachine\My require elevation.
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
  Write-Host "Administrator rights are required to add certificates to the machine Trusted Root store." -ForegroundColor Yellow
  Write-Host "Restarting with elevated privileges (UAC)..." -ForegroundColor Yellow
  $scriptPath = $MyInvocation.MyCommand.Path
  Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
  exit
}

$certPassword = "password"
$validityDays = 365
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot
New-Item -ItemType Directory -Force -Path "certs" | Out-Null

$dnsNames = @("localhost", "127.0.0.1", "host.docker.internal")
$extensions = @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")

$instances = @(
  @{ RelativePath = "certs\keycloak-onprem-1.pfx"; FriendlyName = "Keycloak broker POC SSL (onprem_1)" }
  @{ RelativePath = "certs\keycloak-onprem-2.pfx"; FriendlyName = "Keycloak broker POC SSL (onprem_2)" }
  @{ RelativePath = "certs\keycloak-cloud-idp.pfx"; FriendlyName = "Keycloak broker POC SSL (cloud_idp)" }
)

$rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
$rootStore.Open("ReadWrite")

try {
  foreach ($inst in $instances) {
    $outPath = Join-Path $repoRoot $inst.RelativePath
    Write-Host ""
    Write-Host "Generating $($inst.FriendlyName) -> $outPath" -ForegroundColor Cyan

    $cert = New-SelfSignedCertificate `
      -DnsName $dnsNames `
      -CertStoreLocation "Cert:\LocalMachine\My" `
      -NotAfter (Get-Date).AddDays($validityDays) `
      -KeyAlgorithm RSA `
      -KeyLength 2048 `
      -HashAlgorithm SHA256 `
      -KeyUsage DigitalSignature, KeyEncipherment `
      -TextExtension $extensions `
      -FriendlyName $inst.FriendlyName

    Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green

    Write-Host "  Adding to Trusted Root (LocalMachine)..." -ForegroundColor Cyan
    $rootStore.Add($cert)

    Write-Host "  Removing from Personal (LocalMachine\My)..." -ForegroundColor Cyan
    Remove-Item -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force

    $securePassword = ConvertTo-SecureString -String $certPassword -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath $outPath -Password $securePassword | Out-Null
    Write-Host "  Exported PFX." -ForegroundColor Green
  }
}
finally {
  $rootStore.Close()
}

Write-Host ""
Write-Host "Done. Keystore password for all PFX files: $certPassword (set in docker-compose)." -ForegroundColor Cyan
Write-Host "Next: docker compose up -d  then  .\keycloak-setup.ps1" -ForegroundColor Cyan
