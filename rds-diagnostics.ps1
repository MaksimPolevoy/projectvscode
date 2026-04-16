<#
.SYNOPSIS
    Диагностика RDS-фермы Windows Server 2019
.DESCRIPTION
    Скрипт проверяет основные компоненты RDS-фермы:
    - Сетевую доступность (порты 3389, 443)
    - Службы RDS (TermService, SessionEnv, UmRdpService и др.)
    - Лицензирование RDS
    - Сертификаты
    - RD Connection Broker
    - RD Gateway
    - RemoteApp-коллекции
    - Журналы событий
.PARAMETER RDSServer
    IP-адрес или имя RDS-сервера (по умолчанию — локальный)
.PARAMETER RemoteCheck
    Проверить удалённый сервер по сети
.EXAMPLE
    .\rds-diagnostics.ps1
    .\rds-diagnostics.ps1 -RDSServer "server103" -RemoteCheck
#>

param(
    [string]$RDSServer = $env:COMPUTERNAME,
    [switch]$RemoteCheck
)

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "RDS_Diagnostics_$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Write-Host $entry -ForegroundColor $(switch($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        default { "White" }
    })
    $entry | Out-File -Append -FilePath $logFile
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ДИАГНОСТИКА RDS-ФЕРМЫ" -ForegroundColor Cyan
Write-Host "  Сервер: $RDSServer" -ForegroundColor Cyan
Write-Host "  Время: $(Get-Date)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. СЕТЕВАЯ ДОСТУПНОСТЬ
# ============================================================
Write-Host "=== 1. СЕТЕВАЯ ДОСТУПНОСТЬ ===" -ForegroundColor Cyan

if ($RemoteCheck -or $RDSServer -ne $env:COMPUTERNAME) {
    $ports = @(3389, 443, 3391)
    foreach ($port in $ports) {
        try {
            $result = Test-NetConnection -ComputerName $RDSServer -Port $port -WarningAction SilentlyContinue
            if ($result.TcpTestSucceeded) {
                Write-Log "Порт $port на $RDSServer — ОТКРЫТ" "OK"
            } else {
                Write-Log "Порт $port на $RDSServer — ЗАКРЫТ" "ERROR"
            }
        } catch {
            Write-Log "Не удалось проверить порт $port : $_" "ERROR"
        }
    }

    # Ping
    if (Test-Connection -ComputerName $RDSServer -Count 2 -Quiet) {
        Write-Log "Ping $RDSServer — OK" "OK"
    } else {
        Write-Log "Ping $RDSServer — НЕ ОТВЕЧАЕТ" "ERROR"
    }

    # DNS
    try {
        $dns = Resolve-DnsName $RDSServer -ErrorAction Stop
        Write-Log "DNS-разрешение $RDSServer -> $($dns.IPAddress -join ', ')" "OK"
    } catch {
        Write-Log "DNS не может разрешить $RDSServer" "ERROR"
    }
} else {
    Write-Log "Локальная проверка — сетевые тесты пропущены" "INFO"
}

Write-Host ""

# ============================================================
# 2. СЛУЖБЫ RDS
# ============================================================
Write-Host "=== 2. СЛУЖБЫ RDS ===" -ForegroundColor Cyan

$rdsServices = @(
    @{Name="TermService";       Desc="Remote Desktop Services"},
    @{Name="SessionEnv";        Desc="Remote Desktop Configuration"},
    @{Name="UmRdpService";      Desc="Remote Desktop Services UserMode Port Redirector"},
    @{Name="Tssdis";            Desc="RD Connection Broker (если роль установлена)"},
    @{Name="TSGateway";         Desc="RD Gateway (если роль установлена)"},
    @{Name="W3SVC";             Desc="IIS (World Wide Web Publishing)"},
    @{Name="CertPropSvc";       Desc="Certificate Propagation"},
    @{Name="LicenseManager";    Desc="Windows Licensing Monitoring Service"}
)

foreach ($svc in $rdsServices) {
    try {
        $service = Get-Service -Name $svc.Name -ErrorAction Stop
        if ($service.Status -eq 'Running') {
            Write-Log "$($svc.Desc) ($($svc.Name)) — Запущена" "OK"
        } else {
            Write-Log "$($svc.Desc) ($($svc.Name)) — $($service.Status)" "ERROR"
        }
    } catch {
        Write-Log "$($svc.Desc) ($($svc.Name)) — Не найдена (роль не установлена?)" "WARN"
    }
}

Write-Host ""

# ============================================================
# 3. ЛИЦЕНЗИРОВАНИЕ RDS (ЧАСТАЯ ПРИЧИНА!)
# ============================================================
Write-Host "=== 3. ЛИЦЕНЗИРОВАНИЕ RDS ===" -ForegroundColor Cyan

# Проверяем роль RD Licensing
try {
    $licensingRole = Get-WindowsFeature -Name RDS-Licensing -ErrorAction Stop
    if ($licensingRole.Installed) {
        Write-Log "Роль RD Licensing — установлена" "OK"
    } else {
        Write-Log "Роль RD Licensing — НЕ установлена на этом сервере" "WARN"
    }
} catch {
    Write-Log "Не удалось проверить роль RD Licensing: $_" "WARN"
}

# Проверяем настройки лицензирования
try {
    $licSettings = Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
    $licMode = switch ($licSettings.LicensingType) {
        2 { "Per Device" }
        4 { "Per User" }
        default { "Не настроено ($($licSettings.LicensingType))" }
    }
    Write-Log "Режим лицензирования: $licMode" "INFO"

    if ($licSettings.LicenseServers) {
        Write-Log "Сервер лицензий: $($licSettings.LicenseServers)" "OK"
    } else {
        Write-Log "Сервер лицензий НЕ УКАЗАН — возможно grace period истёк!" "ERROR"
    }
} catch {
    Write-Log "Не удалось получить настройки лицензирования: $_" "WARN"
}

# Проверяем grace period
try {
    $grace = (Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TSLicenseReport -ErrorAction Stop)
    if ($grace) {
        Write-Log "Отчёт о лицензиях доступен" "INFO"
    }
} catch {
    Write-Log "Не удалось получить отчёт о лицензиях" "WARN"
}

# Grace period через реестр
try {
    $gracePeriod = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\GracePeriod" -ErrorAction Stop
    if ($gracePeriod) {
        Write-Log "Grace period запись в реестре НАЙДЕНА — возможно, лицензии не настроены!" "WARN"
    }
} catch {
    Write-Log "Grace period запись не найдена (это нормально, если лицензии настроены)" "OK"
}

Write-Host ""

# ============================================================
# 4. СЕРТИФИКАТЫ RDS
# ============================================================
Write-Host "=== 4. СЕРТИФИКАТЫ RDS ===" -ForegroundColor Cyan

try {
    $rdpCert = Get-CimInstance -Namespace "root/cimv2/TerminalServices" -ClassName Win32_TSGeneralSetting -ErrorAction Stop
    $thumbprint = $rdpCert.SSLCertificateSHA1Hash
    Write-Log "Thumbprint сертификата RDP: $thumbprint" "INFO"

    if ($thumbprint) {
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object { $_.Thumbprint -eq $thumbprint }
        if ($cert) {
            Write-Log "Сертификат: $($cert.Subject)" "INFO"
            Write-Log "Действителен до: $($cert.NotAfter)" $(if ($cert.NotAfter -lt (Get-Date)) { "ERROR" } else { "OK" })
            Write-Log "Издатель: $($cert.Issuer)" "INFO"

            if ($cert.NotAfter -lt (Get-Date)) {
                Write-Log "СЕРТИФИКАТ ИСТЁК! Это может вызывать ошибки подключения!" "ERROR"
            } elseif ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
                Write-Log "Сертификат истекает менее чем через 30 дней" "WARN"
            }
        } else {
            Write-Log "Сертификат с thumbprint $thumbprint не найден в хранилище!" "ERROR"
        }
    }
} catch {
    Write-Log "Не удалось получить информацию о сертификате RDP: $_" "WARN"
}

Write-Host ""

# ============================================================
# 5. RD SESSION HOST
# ============================================================
Write-Host "=== 5. RD SESSION HOST ===" -ForegroundColor Cyan

try {
    $rdshRole = Get-WindowsFeature -Name RDS-RD-Server -ErrorAction Stop
    if ($rdshRole.Installed) {
        Write-Log "Роль RD Session Host — установлена" "OK"
    } else {
        Write-Log "Роль RD Session Host — НЕ установлена" "ERROR"
    }
} catch {
    Write-Log "Не удалось проверить роль RDSH: $_" "WARN"
}

# Текущие сессии
try {
    $sessions = query user 2>&1
    Write-Log "Текущие сессии:" "INFO"
    foreach ($line in $sessions) {
        Write-Log "  $line" "INFO"
    }
} catch {
    Write-Log "Не удалось получить список сессий" "WARN"
}

# Настройки RDP
try {
    $rdpEnabled = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -ErrorAction Stop).fDenyTSConnections
    if ($rdpEnabled -eq 0) {
        Write-Log "RDP-подключения — Разрешены" "OK"
    } else {
        Write-Log "RDP-подключения — ЗАПРЕЩЕНЫ (fDenyTSConnections=1)" "ERROR"
    }
} catch {
    Write-Log "Не удалось проверить настройки RDP" "WARN"
}

# NLA
try {
    $nla = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -ErrorAction Stop).UserAuthentication
    Write-Log "NLA (Network Level Authentication): $(if ($nla -eq 1) {'Включена'} else {'Отключена'})" "INFO"
} catch {
    Write-Log "Не удалось проверить NLA" "WARN"
}

# Максимальное количество подключений
try {
    $maxConn = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "MaxConnectionAllowed" -ErrorAction SilentlyContinue).MaxConnectionAllowed
    if ($maxConn) {
        Write-Log "Максимум подключений: $maxConn" "INFO"
    }

    $maxPerUser = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fSingleSessionPerUser" -ErrorAction SilentlyContinue).fSingleSessionPerUser
    Write-Log "Одна сессия на пользователя: $(if ($maxPerUser -eq 1) {'Да'} else {'Нет'})" "INFO"
} catch {
    Write-Log "Не удалось проверить лимиты подключений" "WARN"
}

Write-Host ""

# ============================================================
# 6. RD CONNECTION BROKER
# ============================================================
Write-Host "=== 6. RD CONNECTION BROKER ===" -ForegroundColor Cyan

try {
    $cbRole = Get-WindowsFeature -Name RDS-Connection-Broker -ErrorAction Stop
    if ($cbRole.Installed) {
        Write-Log "Роль RD Connection Broker — установлена" "OK"

        # Проверяем коллекции
        try {
            Import-Module RemoteDesktop -ErrorAction Stop
            $collections = Get-RDSessionCollection -ErrorAction Stop
            foreach ($col in $collections) {
                Write-Log "Коллекция: $($col.CollectionName) — Тип: $($col.Type)" "INFO"

                # RemoteApp
                $apps = Get-RDRemoteApp -CollectionName $col.CollectionName -ErrorAction SilentlyContinue
                if ($apps) {
                    Write-Log "  RemoteApp программы:" "INFO"
                    foreach ($app in $apps) {
                        Write-Log "    - $($app.DisplayName) ($($app.Alias))" "INFO"
                    }
                }

                # Session Hosts в коллекции
                $hosts = Get-RDSessionHost -CollectionName $col.CollectionName -ErrorAction SilentlyContinue
                if ($hosts) {
                    foreach ($h in $hosts) {
                        Write-Log "  Host: $($h.SessionHost) — NewConnectionAllowed: $($h.NewConnectionAllowed)" $(if ($h.NewConnectionAllowed -eq 'Yes') {"OK"} else {"ERROR"})
                    }
                }
            }
        } catch {
            Write-Log "Не удалось получить коллекции RDS: $_" "ERROR"
        }

        # Deployment overview
        try {
            $deployment = Get-RDServer -ErrorAction Stop
            Write-Log "Серверы в развёртывании RDS:" "INFO"
            foreach ($srv in $deployment) {
                Write-Log "  $($srv.Server) — Роли: $($srv.Roles -join ', ')" "INFO"
            }
        } catch {
            Write-Log "Не удалось получить обзор развёртывания: $_" "WARN"
        }
    } else {
        Write-Log "Роль RD Connection Broker — НЕ установлена на этом сервере" "WARN"
    }
} catch {
    Write-Log "Не удалось проверить RD Connection Broker: $_" "WARN"
}

Write-Host ""

# ============================================================
# 7. RD GATEWAY
# ============================================================
Write-Host "=== 7. RD GATEWAY ===" -ForegroundColor Cyan

try {
    $gwRole = Get-WindowsFeature -Name RDS-Gateway -ErrorAction Stop
    if ($gwRole.Installed) {
        Write-Log "Роль RD Gateway — установлена" "OK"

        # Проверяем сертификат шлюза
        try {
            $gwConfig = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\TerminalServerGateway\Config\Core" -ErrorAction Stop
            if ($gwConfig) {
                Write-Log "RD Gateway конфигурация найдена" "OK"
            }
        } catch {
            Write-Log "Не удалось прочитать конфигурацию RD Gateway" "WARN"
        }
    } else {
        Write-Log "Роль RD Gateway — НЕ установлена на этом сервере" "INFO"
    }
} catch {
    Write-Log "Не удалось проверить RD Gateway: $_" "WARN"
}

Write-Host ""

# ============================================================
# 8. FIREWALL
# ============================================================
Write-Host "=== 8. FIREWALL ===" -ForegroundColor Cyan

try {
    $fwRules = Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
    foreach ($rule in $fwRules) {
        $status = if ($rule.Enabled -eq 'True') { "Включено" } else { "Отключено" }
        $action = $rule.Action
        Write-Log "Правило: $($rule.DisplayName) — $status — $action" $(if ($rule.Enabled -eq 'True' -and $action -eq 'Allow') {"OK"} else {"WARN"})
    }
} catch {
    Write-Log "Не удалось проверить правила файрвола: $_" "WARN"
}

# Проверяем слушающий порт 3389
try {
    $listener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        Write-Log "Порт 3389 — слушается (LISTEN)" "OK"
    } else {
        Write-Log "Порт 3389 — НЕ СЛУШАЕТСЯ!" "ERROR"
    }
} catch {
    Write-Log "Не удалось проверить порт 3389" "WARN"
}

Write-Host ""

# ============================================================
# 9. ЖУРНАЛЫ СОБЫТИЙ (последние ошибки)
# ============================================================
Write-Host "=== 9. ЖУРНАЛЫ СОБЫТИЙ (последние ошибки) ===" -ForegroundColor Cyan

$eventLogs = @(
    @{Log="Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational"; Desc="Remote Connection Manager"},
    @{Log="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational";     Desc="Local Session Manager"},
    @{Log="Microsoft-Windows-TerminalServices-Gateway/Operational";                  Desc="RD Gateway"},
    @{Log="Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational";          Desc="RDP Core"},
    @{Log="System";                                                                   Desc="System"}
)

foreach ($el in $eventLogs) {
    Write-Log "--- $($el.Desc) ---" "INFO"
    try {
        $events = Get-WinEvent -LogName $el.Log -MaxEvents 10 -ErrorAction Stop |
            Where-Object { $_.Level -le 3 } |  # Error и Warning
            Select-Object -First 5
        if ($events) {
            foreach ($evt in $events) {
                $lvl = switch ($evt.Level) { 1 {"CRIT"} 2 {"ERROR"} 3 {"WARN"} default {"INFO"} }
                Write-Log "  [$($evt.TimeCreated)] EventID:$($evt.Id) — $($evt.Message -replace "`r`n",' ' | Select-Object -First 1)" $lvl
            }
        } else {
            Write-Log "  Ошибок не найдено" "OK"
        }
    } catch {
        Write-Log "  Журнал недоступен или пуст" "WARN"
    }
}

Write-Host ""

# ============================================================
# 10. РЕСУРСЫ СЕРВЕРА
# ============================================================
Write-Host "=== 10. РЕСУРСЫ СЕРВЕРА ===" -ForegroundColor Cyan

# CPU
$cpu = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
Write-Log "CPU загрузка: $cpu%" $(if ($cpu -gt 90) {"ERROR"} elseif ($cpu -gt 70) {"WARN"} else {"OK"})

# RAM
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$usedPct = [math]::Round((1 - $freeRAM / $totalRAM) * 100, 1)
Write-Log "RAM: $freeRAM GB свободно из $totalRAM GB (использовано $usedPct%)" $(if ($usedPct -gt 90) {"ERROR"} elseif ($usedPct -gt 80) {"WARN"} else {"OK"})

# Диск
$disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
foreach ($disk in $disks) {
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    $totalGB = [math]::Round($disk.Size / 1GB, 2)
    $usedDiskPct = [math]::Round((1 - $freeGB / $totalGB) * 100, 1)
    Write-Log "Диск $($disk.DeviceID) — $freeGB GB свободно из $totalGB GB ($usedDiskPct%)" $(if ($freeGB -lt 2) {"ERROR"} elseif ($freeGB -lt 10) {"WARN"} else {"OK"})
}

Write-Host ""

# ============================================================
# ИТОГИ
# ============================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ДИАГНОСТИКА ЗАВЕРШЕНА" -ForegroundColor Cyan
Write-Host "  Результаты сохранены в: $logFile" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ЧАСТЫЕ ПРИЧИНЫ ПРОБЛЕМ С RDS:" -ForegroundColor Yellow
Write-Host "  1. Истёк grace period лицензирования (120 дней)" -ForegroundColor Yellow
Write-Host "  2. Истёк или некорректный SSL-сертификат" -ForegroundColor Yellow
Write-Host "  3. Служба TermService остановлена" -ForegroundColor Yellow
Write-Host "  4. Переполнение диска (профили пользователей)" -ForegroundColor Yellow
Write-Host "  5. NewConnectionAllowed = No на Session Host" -ForegroundColor Yellow
Write-Host "  6. Проблемы с DNS между серверами фермы" -ForegroundColor Yellow
Write-Host "  7. Блокировка порта 3389 файрволом" -ForegroundColor Yellow
Write-Host "  8. Исчерпан лимит одновременных подключений" -ForegroundColor Yellow
Write-Host ""
