# =============================================================================
# RDP Certificate Diagnostic Script
# Run on the RDP server (192.168.4.3) as Administrator
# =============================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " RDP Certificate Diagnostics" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check current RDP certificate thumbprint
Write-Host "[1] Current RDP certificate thumbprint:" -ForegroundColor Yellow
$rdpThumbprint = (Get-WmiObject -Class "Win32_TSGeneralSetting" -Namespace root\cimv2\terminalservices).SSLCertificateSHA1Hash
if ($rdpThumbprint) {
    Write-Host "    $rdpThumbprint" -ForegroundColor Green
} else {
    Write-Host "    Not set (using default self-signed)" -ForegroundColor Red
}
Write-Host ""

# 2. Find and display the certificate details
Write-Host "[2] Certificate details:" -ForegroundColor Yellow
if ($rdpThumbprint) {
    $cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $rdpThumbprint }
    if ($cert) {
        Write-Host "    Subject:    $($cert.Subject)"
        Write-Host "    Issuer:     $($cert.Issuer)"
        Write-Host "    Not Before: $($cert.NotBefore)"
        Write-Host "    Not After:  $($cert.NotAfter)"
        Write-Host "    Has Key:    $($cert.HasPrivateKey)"

        if ($cert.NotAfter -lt (Get-Date)) {
            Write-Host "    STATUS:     EXPIRED!" -ForegroundColor Red
        } elseif ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
            Write-Host "    STATUS:     Expires within 30 days!" -ForegroundColor DarkYellow
        } else {
            Write-Host "    STATUS:     Valid" -ForegroundColor Green
        }
    } else {
        Write-Host "    Certificate not found in Local Machine store!" -ForegroundColor Red
    }
} else {
    Write-Host "    No custom certificate assigned to RDP" -ForegroundColor Red
}
Write-Host ""

# 3. List all certificates in Personal store
Write-Host "[3] All certificates in Local Machine\Personal store:" -ForegroundColor Yellow
$certs = Get-ChildItem -Path Cert:\LocalMachine\My
foreach ($c in $certs) {
    $status = if ($c.NotAfter -lt (Get-Date)) { "EXPIRED" } else { "Valid" }
    $color = if ($status -eq "EXPIRED") { "Red" } else { "Green" }
    Write-Host "    [$status] $($c.Subject) | Expires: $($c.NotAfter) | Thumbprint: $($c.Thumbprint)" -ForegroundColor $color
}
Write-Host ""

# 4. Check RDP service status
Write-Host "[4] RDP Service status:" -ForegroundColor Yellow
$rdpService = Get-Service -Name TermService
Write-Host "    TermService: $($rdpService.Status)"
$rdpTcp = Get-Service -Name UmRdpService -ErrorAction SilentlyContinue
if ($rdpTcp) {
    Write-Host "    UmRdpService: $($rdpTcp.Status)"
}
Write-Host ""

# 5. Check RDP listener configuration
Write-Host "[5] RDP-Tcp listener security layer:" -ForegroundColor Yellow
$listener = Get-WmiObject -Class "Win32_TSGeneralSetting" -Namespace root\cimv2\terminalservices
Write-Host "    SecurityLayer: $($listener.SecurityLayer)  (0=RDP, 1=Negotiate, 2=TLS)"
Write-Host "    MinEncryptionLevel: $($listener.MinEncryptionLevel)  (1=Low, 2=Client, 3=High, 4=FIPS)"
Write-Host ""

# 6. Check if NLA is enabled
Write-Host "[6] Network Level Authentication (NLA):" -ForegroundColor Yellow
Write-Host "    UserAuthenticationRequired: $($listener.UserAuthenticationRequired)  (1=Enabled)"
Write-Host ""

# 7. Firewall rules for RDP
Write-Host "[7] Firewall rules for RDP (port 3389):" -ForegroundColor Yellow
$rules = Get-NetFirewallRule -DisplayName "*Remote Desktop*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq 'True' }
if ($rules) {
    foreach ($r in $rules) {
        Write-Host "    [Enabled] $($r.DisplayName) - Direction: $($r.Direction) - Action: $($r.Action)"
    }
} else {
    Write-Host "    No enabled RDP firewall rules found" -ForegroundColor Red
}
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Diagnostics complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
