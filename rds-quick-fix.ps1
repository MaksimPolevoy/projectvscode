<#
.SYNOPSIS
    Быстрое исправление типичных проблем RDS на Windows Server 2019
.DESCRIPTION
    Исправляет самые частые причины отказа RDS:
    - Перезапуск служб RDS
    - Сброс grace period лицензирования
    - Включение RDP-подключений
    - Разрешение новых подключений на Session Host
.PARAMETER Fix
    Какой фикс применить: All, Services, Licensing, Firewall, Connections
.EXAMPLE
    .\rds-quick-fix.ps1 -Fix Services
    .\rds-quick-fix.ps1 -Fix All
#>

#Requires -RunAsAdministrator

param(
    [ValidateSet("All", "Services", "Licensing", "Firewall", "Connections", "Certificate")]
    [string]$Fix = "All"
)

$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch($Level) {
        "ERROR" { "Red" }
        "OK"    { "Green" }
        "FIX"   { "Magenta" }
        "WARN"  { "Yellow" }
        default { "White" }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message" -ForegroundColor $color
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  БЫСТРОЕ ИСПРАВЛЕНИЕ RDS" -ForegroundColor Magenta
Write-Host "  Применяемый фикс: $Fix" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""

# ============================================================
# FIX 1: ПЕРЕЗАПУСК СЛУЖБ RDS
# ============================================================
if ($Fix -in "All", "Services") {
    Write-Host "=== ПЕРЕЗАПУСК СЛУЖБ RDS ===" -ForegroundColor Cyan

    $services = @("TermService", "SessionEnv", "UmRdpService")

    foreach ($svcName in $services) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            Write-Status "Перезапуск $svcName ($($svc.DisplayName))..." "FIX"
            Restart-Service -Name $svcName -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name $svcName
            Write-Status "$svcName — $($svc.Status)" $(if ($svc.Status -eq 'Running') {"OK"} else {"ERROR"})
        } catch {
            Write-Status "Не удалось перезапустить $svcName : $_" "ERROR"
        }
    }

    # Перезапуск Connection Broker если есть
    try {
        $cb = Get-Service -Name "Tssdis" -ErrorAction Stop
        Write-Status "Перезапуск RD Connection Broker..." "FIX"
        Restart-Service -Name "Tssdis" -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Status "RD Connection Broker — $($(Get-Service 'Tssdis').Status)" "OK"
    } catch {
        Write-Status "RD Connection Broker не установлен на этом сервере" "INFO"
    }

    Write-Host ""
}

# ============================================================
# FIX 2: ЛИЦЕНЗИРОВАНИЕ (GRACE PERIOD)
# ============================================================
if ($Fix -in "All", "Licensing") {
    Write-Host "=== ПРОВЕРКА / ИСПРАВЛЕНИЕ ЛИЦЕНЗИРОВАНИЯ ===" -ForegroundColor Cyan

    # Проверяем, настроен ли сервер лицензий
    try {
        $licSettings = Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TerminalServiceSetting -ErrorAction Stop

        if (-not $licSettings.LicenseServers -or $licSettings.LicenseServers -eq "") {
            Write-Status "Сервер лицензий НЕ НАСТРОЕН!" "ERROR"
            Write-Status "Для настройки выполните:" "INFO"
            Write-Host ""
            Write-Host '  $obj = Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TerminalServiceSetting' -ForegroundColor Yellow
            Write-Host '  $obj | Invoke-CimMethod -MethodName SetSpecifiedLicenseServerList -Arguments @{SpecifiedLSList=@("СЕРВЕР_ЛИЦЕНЗИЙ")}' -ForegroundColor Yellow
            Write-Host '  $obj | Invoke-CimMethod -MethodName ChangeMode -Arguments @{LicensingType=4}  # 4=Per User, 2=Per Device' -ForegroundColor Yellow
            Write-Host ""
        } else {
            Write-Status "Сервер лицензий: $($licSettings.LicenseServers)" "OK"
        }
    } catch {
        Write-Status "Ошибка проверки лицензий: $_" "ERROR"
    }

    # Проверяем grace period
    try {
        $graceKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"
        if (Test-Path $graceKey) {
            Write-Status "Обнаружена запись Grace Period в реестре" "WARN"
            Write-Status "Для сброса grace period (ТОЛЬКО если лицензии настроены):" "INFO"
            Write-Host ""
            Write-Host "  # ВНИМАНИЕ: Сначала настройте сервер лицензий!" -ForegroundColor Red
            Write-Host '  # Получите права на ключ реестра:' -ForegroundColor Yellow
            Write-Host '  $acl = Get-Acl "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod"' -ForegroundColor Yellow
            Write-Host '  $rule = New-Object System.Security.AccessControl.RegistryAccessRule("Administrators","FullControl","Allow")' -ForegroundColor Yellow
            Write-Host '  $acl.SetAccessRule($rule)' -ForegroundColor Yellow
            Write-Host '  Set-Acl "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod" $acl' -ForegroundColor Yellow
            Write-Host '  Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod" -Force' -ForegroundColor Yellow
            Write-Host '  Restart-Service TermService -Force' -ForegroundColor Yellow
            Write-Host ""
        } else {
            Write-Status "Grace period не активен (лицензии настроены корректно)" "OK"
        }
    } catch {
        Write-Status "Ошибка проверки grace period: $_" "WARN"
    }

    Write-Host ""
}

# ============================================================
# FIX 3: FIREWALL
# ============================================================
if ($Fix -in "All", "Firewall") {
    Write-Host "=== НАСТРОЙКА FIREWALL ===" -ForegroundColor Cyan

    try {
        # Включаем правила Remote Desktop
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
        Write-Status "Правила файрвола для Remote Desktop — включены" "OK"
    } catch {
        Write-Status "Не удалось настроить правила файрвола: $_" "ERROR"
    }

    # Проверяем порт 3389
    $listener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        Write-Status "Порт 3389 слушается — OK" "OK"
    } else {
        Write-Status "Порт 3389 НЕ слушается — перезапустите TermService" "ERROR"
    }

    Write-Host ""
}

# ============================================================
# FIX 4: РАЗРЕШЕНИЕ ПОДКЛЮЧЕНИЙ
# ============================================================
if ($Fix -in "All", "Connections") {
    Write-Host "=== РАЗРЕШЕНИЕ ПОДКЛЮЧЕНИЙ ===" -ForegroundColor Cyan

    # Включаем RDP
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Force
        Write-Status "RDP-подключения разрешены (fDenyTSConnections=0)" "OK"
    } catch {
        Write-Status "Не удалось разрешить RDP: $_" "ERROR"
    }

    # Разрешаем новые подключения на Session Host
    try {
        Import-Module RemoteDesktop -ErrorAction Stop
        $collections = Get-RDSessionCollection -ErrorAction Stop
        foreach ($col in $collections) {
            $hosts = Get-RDSessionHost -CollectionName $col.CollectionName -ErrorAction SilentlyContinue
            foreach ($h in $hosts) {
                if ($h.NewConnectionAllowed -ne 'Yes') {
                    Write-Status "Включаем подключения на $($h.SessionHost)..." "FIX"
                    Set-RDSessionHost -SessionHost $h.SessionHost -NewConnectionAllowed $true -ErrorAction Stop
                    Write-Status "$($h.SessionHost) — подключения разрешены" "OK"
                } else {
                    Write-Status "$($h.SessionHost) — подключения уже разрешены" "OK"
                }
            }
        }
    } catch {
        Write-Status "Не удалось настроить Session Hosts (возможно, это не Connection Broker): $_" "WARN"
    }

    Write-Host ""
}

# ============================================================
# FIX 5: СЕРТИФИКАТ
# ============================================================
if ($Fix -in "All", "Certificate") {
    Write-Host "=== ПРОВЕРКА СЕРТИФИКАТА ===" -ForegroundColor Cyan

    try {
        $rdpCert = Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TSGeneralSetting -ErrorAction Stop
        $thumbprint = $rdpCert.SSLCertificateSHA1Hash

        if ($thumbprint) {
            $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $thumbprint }
            if ($cert -and $cert.NotAfter -lt (Get-Date)) {
                Write-Status "СЕРТИФИКАТ ИСТЁК: $($cert.Subject) — $($cert.NotAfter)" "ERROR"
                Write-Status "Для использования самоподписанного сертификата:" "INFO"
                Write-Host ""
                Write-Host '  # Создать новый самоподписанный сертификат:' -ForegroundColor Yellow
                Write-Host '  $newCert = New-SelfSignedCertificate -DnsName "server103.domain.local" -CertStoreLocation "Cert:\LocalMachine\My" -NotAfter (Get-Date).AddYears(3)' -ForegroundColor Yellow
                Write-Host '  # Установить его для RDP:' -ForegroundColor Yellow
                Write-Host '  $path = (Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TSGeneralSetting).__Path' -ForegroundColor Yellow
                Write-Host '  Set-CimInstance -Path $path -Property @{SSLCertificateSHA1Hash=$newCert.Thumbprint}' -ForegroundColor Yellow
                Write-Host ""
            } elseif ($cert) {
                Write-Status "Сертификат действителен до $($cert.NotAfter)" "OK"
            } else {
                Write-Status "Сертификат не найден в хранилище!" "ERROR"
            }
        }
    } catch {
        Write-Status "Ошибка проверки сертификата: $_" "WARN"
    }

    Write-Host ""
}

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  ИСПРАВЛЕНИЯ ПРИМЕНЕНЫ" -ForegroundColor Magenta
Write-Host "" -ForegroundColor Magenta
Write-Host "  Если проблема сохраняется:" -ForegroundColor Yellow
Write-Host "  1. Запустите rds-diagnostics.ps1 для полной диагностики" -ForegroundColor Yellow
Write-Host "  2. Проверьте Event Viewer -> Applications and Services Logs" -ForegroundColor Yellow
Write-Host "     -> Microsoft -> Windows -> TerminalServices-*" -ForegroundColor Yellow
Write-Host "  3. Перезагрузите сервер если ничего не помогает" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Magenta
Write-Host ""
