# =============================================================================
# RDP Certificate Trust Script (run on CLIENT machines)
# Run as Administrator on each client that connects to the RDP server
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$CertificatePath
)

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Run this script as Administrator!" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $CertificatePath)) {
    Write-Host "ERROR: Certificate file not found: $CertificatePath" -ForegroundColor Red
    exit 1
}

Write-Host "Installing RDP server certificate as trusted..." -ForegroundColor Yellow
Import-Certificate -FilePath $CertificatePath -CertStoreLocation Cert:\LocalMachine\Root
Write-Host "Done! The RDP security warning should no longer appear." -ForegroundColor Green
Write-Host "You may need to restart the Remote Desktop client." -ForegroundColor Gray
