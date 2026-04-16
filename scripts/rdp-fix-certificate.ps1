# =============================================================================
# RDP Certificate Fix Script
# Run on the RDP server (192.168.4.3) as Administrator
# =============================================================================
#
# This script:
#   1. Creates a new self-signed certificate for RDP
#   2. Binds it to the RDP listener
#   3. Exports the certificate for distribution to client machines
#   4. Restarts the RDP service
#
# =============================================================================

param(
    [string]$ServerFQDN = $env:COMPUTERNAME,
    [int]$CertValidityYears = 5,
    [string]$ExportPath = "C:\RDP-Certificate"
)

# Must run as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Run this script as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " RDP Certificate Fix" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Server name: $ServerFQDN"
Write-Host "Certificate validity: $CertValidityYears years"
Write-Host ""

# --- Step 1: Create new self-signed certificate ---
Write-Host "[Step 1] Creating new self-signed certificate..." -ForegroundColor Yellow

$cert = New-SelfSignedCertificate `
    -DnsName $ServerFQDN, "192.168.4.3", "localhost" `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -NotAfter (Get-Date).AddYears($CertValidityYears) `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -FriendlyName "RDP Certificate - $ServerFQDN" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")

Write-Host "    Created certificate: $($cert.Thumbprint)" -ForegroundColor Green
Write-Host "    Subject: $($cert.Subject)"
Write-Host "    Expires: $($cert.NotAfter)"
Write-Host ""

# --- Step 2: Bind certificate to RDP ---
Write-Host "[Step 2] Binding certificate to RDP listener..." -ForegroundColor Yellow

$wmiPath = (Get-WmiObject -Class "Win32_TSGeneralSetting" -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").__path
Set-WmiInstance -Path $wmiPath -Argument @{SSLCertificateSHA1Hash = $cert.Thumbprint}

Write-Host "    Certificate bound to RDP-Tcp listener" -ForegroundColor Green
Write-Host ""

# --- Step 3: Export certificate (public key only) for client trust ---
Write-Host "[Step 3] Exporting certificate for client distribution..." -ForegroundColor Yellow

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}

$exportFile = Join-Path $ExportPath "rdp-server-$ServerFQDN.cer"
Export-Certificate -Cert $cert -FilePath $exportFile | Out-Null

Write-Host "    Exported to: $exportFile" -ForegroundColor Green
Write-Host "    (This .cer file contains only the public key - safe to distribute)" -ForegroundColor Gray
Write-Host ""

# --- Step 4: Restart RDP service ---
Write-Host "[Step 4] Restarting Remote Desktop Services..." -ForegroundColor Yellow

Restart-Service -Name TermService -Force
Write-Host "    TermService restarted" -ForegroundColor Green
Write-Host ""

# --- Summary ---
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done! Next steps:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "The warning will disappear after clients trust the new certificate." -ForegroundColor White
Write-Host "Choose one of the options below:" -ForegroundColor White
Write-Host ""
Write-Host "Option A - Install certificate on each client manually:" -ForegroundColor Yellow
Write-Host "  1. Copy $exportFile to each client PC"
Write-Host '  2. Double-click the .cer file -> Install Certificate'
Write-Host '  3. Choose "Local Machine" -> "Trusted Root Certification Authorities"'
Write-Host ""
Write-Host "Option B - Deploy via Group Policy (recommended for domain):" -ForegroundColor Yellow
Write-Host "  1. Open Group Policy Management (gpmc.msc)"
Write-Host "  2. Edit GPO -> Computer Configuration -> Policies"
Write-Host "     -> Windows Settings -> Security Settings"
Write-Host "     -> Public Key Policies -> Trusted Root Certification Authorities"
Write-Host "  3. Import $exportFile"
Write-Host "  4. Run 'gpupdate /force' on clients or wait for policy refresh"
Write-Host ""
Write-Host "Option C - Deploy via PowerShell to clients (run on each client):" -ForegroundColor Yellow
Write-Host "  Import-Certificate -FilePath '\\server\share\rdp-server-$ServerFQDN.cer' -CertStoreLocation Cert:\LocalMachine\Root"
Write-Host ""
