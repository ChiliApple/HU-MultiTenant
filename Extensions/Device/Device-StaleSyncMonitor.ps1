<#
.SYNOPSIS
    Geraete, deren Benutzer sich anmelden, die aber nicht mehr mit Intune synchronisieren
.DESCRIPTION
    Vergleicht Intune lastSyncDateTime mit Entra approximateLastSignInDateTime
    des Geraete-Owners. Findet Geraete wo der MDM-Agent (dmwappushsvc) haengt
    obwohl der User aktiv ist. Verhindert unnoetiges Loeschen durch Cleanup Rules.

    Ausgabe: Tabelle mit DeviceName, User, LastSync, LastSignIn, DeltaDays, Status.
    Status-Kategorien:
      - KRITISCH: >90 Tage Sync-Luecke bei aktivem User
      - WARNUNG:  >60 Tage Sync-Luecke bei aktivem User
      - INAKTIV:  User UND Device beide >60 Tage inaktiv
      - OK:       Device synct regelmaessig
.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All
    User.Read.All
    AuditLog.Read.All
.CATEGORY
    Device
.TARGETS
    []
.BATCH_CAPABLE
    true
.DRY_RUN_CAPABLE
    false
.RUNTIME
    PS5
.MODE
    ReadOnly
.PARAM
    StaleDays|int|Schwellwert Tage ohne Sync|60
    ShowAll|bool|Auch OK-Geraete anzeigen|false
#>

function Invoke-StaleSyncMonitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [int]$StaleDays = 60,

        [bool]$ShowAll = $false
    )

    # --- 1. Alle Managed Devices holen ---
    Write-HULogInfo "Lade Intune Managed Devices..." -Tenant $TenantKey

    $deviceSelect = 'id,deviceName,userPrincipalName,lastSyncDateTime,managedDeviceOwnerType,operatingSystem,complianceState,enrolledDateTime,model'
    $deviceEndpoint = "/deviceManagement/managedDevices?`$select=$deviceSelect&`$top=999"

    $allDevices = Invoke-GraphRequestAll -Token $Token -Endpoint $deviceEndpoint -TenantKey $TenantKey
    if (-not $allDevices -or $allDevices.Count -eq 0) {
        Write-HULogWarn "Keine Managed Devices gefunden." -Tenant $TenantKey
        return @()
    }
    Write-HULogOK "$($allDevices.Count) Geraete geladen." -Tenant $TenantKey

    # --- 2. Unique UPNs sammeln ---
    $upns = @($allDevices |
        Where-Object { $_.userPrincipalName -and $_.userPrincipalName -ne '' } |
        ForEach-Object { $_.userPrincipalName.ToLower() } |
        Sort-Object -Unique)

    Write-HULogInfo "$($upns.Count) eindeutige User. Lade Sign-In-Daten..." -Tenant $TenantKey

    # --- 3. User Sign-In-Daten holen (Batched) ---
    $userSignInMap = @{}

    $batchSize = 15
    for ($i = 0; $i -lt $upns.Count; $i += $batchSize) {
        $batch = $upns[$i..[Math]::Min($i + $batchSize - 1, $upns.Count - 1)]

        $filterParts = $batch | ForEach-Object {
            "userPrincipalName eq '$_'"
        }
        $filter = $filterParts -join ' or '
        $userEndpoint = "/users?`$filter=$filter&`$select=userPrincipalName,signInActivity,displayName&`$top=999"

        $users = Invoke-GraphRequestAll -Token $Token -Endpoint $userEndpoint -TenantKey $TenantKey

        foreach ($user in $users) {
            if ($user.userPrincipalName) {
                $lastSignIn = $null
                if ($user.signInActivity -and $user.signInActivity.lastSignInDateTime) {
                    $lastSignIn = [DateTime]::Parse($user.signInActivity.lastSignInDateTime)
                }
                $userSignInMap[$user.userPrincipalName.ToLower()] = @{
                    DisplayName = $user.displayName
                    LastSignIn  = $lastSignIn
                }
            }
        }

        # Throttle-Schutz
        if ($i + $batchSize -lt $upns.Count) {
            Start-Sleep -Milliseconds 200
        }
    }

    Write-HULogOK "Sign-In-Daten fuer $($userSignInMap.Count) User geladen." -Tenant $TenantKey

    # --- 4. Vergleich und Klassifizierung ---
    $now = [DateTime]::UtcNow
    $results = [System.Collections.ArrayList]::new()

    foreach ($device in $allDevices) {
        $lastSync = $null
        if ($device.lastSyncDateTime) {
            $lastSync = [DateTime]::Parse($device.lastSyncDateTime)
        }

        $syncAgeDays = if ($lastSync) {
            [Math]::Round(($now - $lastSync).TotalDays, 0)
        } else { 9999 }

        $upn = if ($device.userPrincipalName) { $device.userPrincipalName.ToLower() } else { '' }
        $userInfo = if ($upn -and $userSignInMap.ContainsKey($upn)) { $userSignInMap[$upn] } else { $null }

        $lastSignIn = if ($userInfo) { $userInfo.LastSignIn } else { $null }
        $signInAgeDays = if ($lastSignIn) {
            [Math]::Round(($now - $lastSignIn).TotalDays, 0)
        } else { 9999 }

        # Status bestimmen
        $status = 'OK'
        if ($syncAgeDays -gt 90 -and $signInAgeDays -lt $StaleDays) {
            $status = 'KRITISCH'
        }
        elseif ($syncAgeDays -gt $StaleDays -and $signInAgeDays -lt $StaleDays) {
            $status = 'WARNUNG'
        }
        elseif ($syncAgeDays -gt $StaleDays -and $signInAgeDays -gt $StaleDays) {
            $status = 'INAKTIV'
        }

        $entry = [PSCustomObject]@{
            DeviceName     = $device.deviceName
            User           = if ($userInfo) { $userInfo.DisplayName } else { $upn }
            UPN            = $upn
            OS             = $device.operatingSystem
            Model          = $device.model
            LastSync       = if ($lastSync) { $lastSync.ToString('yyyy-MM-dd') } else { 'nie' }
            SyncAgeDays    = $syncAgeDays
            LastSignIn     = if ($lastSignIn) { $lastSignIn.ToString('yyyy-MM-dd') } else { 'unbekannt' }
            SignInAgeDays  = $signInAgeDays
            DeltaDays      = if ($syncAgeDays -ne 9999 -and $signInAgeDays -ne 9999) { $syncAgeDays - $signInAgeDays } else { 0 }
            Compliance     = $device.complianceState
            Status         = $status
        }

        if ($ShowAll -or $status -ne 'OK') {
            [void]$results.Add($entry)
        }
    }

    # --- 5. Sortierung und Ausgabe ---
    $sorted = $results | Sort-Object -Property @(
        @{ Expression = {
            switch ($_.Status) {
                'KRITISCH' { 0 }
                'WARNUNG'  { 1 }
                'INAKTIV'  { 2 }
                'OK'       { 3 }
                default    { 4 }
            }
        }; Ascending = $true },
        @{ Expression = { $_.SyncAgeDays }; Descending = $true }
    )

    # Zusammenfassung
    $kritisch = @($sorted | Where-Object { $_.Status -eq 'KRITISCH' }).Count
    $warnung  = @($sorted | Where-Object { $_.Status -eq 'WARNUNG' }).Count
    $inaktiv  = @($sorted | Where-Object { $_.Status -eq 'INAKTIV' }).Count

    Write-HULogInfo "================================================================" -Tenant $TenantKey
    Write-HULogInfo "STALE SYNC MONITOR - Schwellwert: $StaleDays Tage | Geraete: $($allDevices.Count)" -Tenant $TenantKey

    if ($kritisch -gt 0) {
        Write-HULogError "KRITISCH: $kritisch | WARNUNG: $warnung | INAKTIV: $inaktiv" -Tenant $TenantKey
    }
    elseif ($warnung -gt 0) {
        Write-HULogWarn "KRITISCH: $kritisch | WARNUNG: $warnung | INAKTIV: $inaktiv" -Tenant $TenantKey
    }
    else {
        Write-HULogOK "KRITISCH: $kritisch | WARNUNG: $warnung | INAKTIV: $inaktiv" -Tenant $TenantKey
    }

    Write-HULogInfo "================================================================" -Tenant $TenantKey

    if ($sorted.Count -gt 0) {
        foreach ($item in $sorted) {
            $line = "[{0,-8}] {1,-25} | User: {2,-25} | Sync: {3} ({4}d) | SignIn: {5} ({6}d) | Delta: {7}d" -f $item.Status, $item.DeviceName, $item.User, $item.LastSync, $item.SyncAgeDays, $item.LastSignIn, $item.SignInAgeDays, $item.DeltaDays

            switch ($item.Status) {
                'KRITISCH' { Write-HULogError $line -Tenant $TenantKey }
                'WARNUNG'  { Write-HULogWarn $line -Tenant $TenantKey }
                'INAKTIV'  { Write-HULogDebug $line -Tenant $TenantKey }
                default    { Write-HULogInfo $line -Tenant $TenantKey }
            }
        }
    }
    else {
        Write-HULogOK "Alle Geraete syncen innerhalb von $StaleDays Tagen." -Tenant $TenantKey
    }

    # --- 6. Excel-Export ---
    if ($sorted.Count -gt 0) {
        try {
            $excelReady = Initialize-HUExcel
            if ($excelReady) {
                $dateStr = Get-Date -Format 'yyyy-MM-dd_HHmm'

                # Settings laden fuer Report-Pfad
                $settingsFile = Join-Path $AppRoot 'Config\settings.json'
                $rptSettings = $null
                if (Test-Path $settingsFile) {
                    $rptSettings = (Get-Content $settingsFile -Raw | ConvertFrom-Json).reporting
                }

                $cfgPath = if ($rptSettings -and $rptSettings.outputPath) {
                    $rptSettings.outputPath
                } else { './Reports' }

                if ($cfgPath.StartsWith('.')) {
                    $reportDir = Join-Path $AppRoot $cfgPath
                } else {
                    $reportDir = $cfgPath
                }

                # Date-stamped subfolder (HU-Reports_YYYY-MM-DD) - Standard-Konvention
                $dateFolder = "HU-Reports_$(Get-Date -Format 'yyyy-MM-dd')"
                $reportDir = Join-Path $reportDir $dateFolder

                if (-not (Test-Path $reportDir)) {
                    New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
                }
                $reportPath = Join-Path $reportDir "StaleSyncMonitor_${TenantKey}_${dateStr}.xlsx"

                # Export-Daten vorbereiten (ohne UPN fuer saubere Darstellung)
                $exportData = $sorted | Select-Object Status, DeviceName, User, OS, Model, LastSync, SyncAgeDays, LastSignIn, SignInAgeDays, DeltaDays, Compliance

                # Sheet schreiben + HU-Formatting
                New-HUExcelReport -Data $exportData `
                    -SheetName 'StaleSync' `
                    -ReportPath $reportPath `
                    -PrimaryKeyColumn 'DeviceName' `
                    -ConditionalColumns @('Status', 'Compliance')

                # Dashboard mit KPIs
                $metrics = [ordered]@{
                    'Geraete gesamt'  = $allDevices.Count
                    'KRITISCH (Sync-Fehler)' = $kritisch
                    'WARNUNG (Sync veraltet)' = $warnung
                    'INAKTIV'         = $inaktiv
                    'OK'              = $allDevices.Count - $kritisch - $warnung - $inaktiv
                }

                Add-HUExcelDashboard -WorkbookPath $reportPath `
                    -TenantKey $TenantKey `
                    -ReportTitle 'Stale Sync Monitor' `
                    -Metrics $metrics `
                    -SheetDataSources @(
                        @{ SheetName = 'StaleSync'; RowCount = $sorted.Count; Description = 'Geraete mit Sync-Problemen' }
                    )

                Write-HULogOK "Excel-Report: $reportPath" -Tenant $TenantKey

                # openAfterExport aus Settings
                $autoOpen = if ($rptSettings -and $rptSettings.PSObject.Properties['openAfterExport']) {
                    $rptSettings.openAfterExport
                } else { $true }
                if ($autoOpen) { Invoke-Item $reportPath }
            }
            else {
                Write-HULogWarn "ImportExcel nicht verfuegbar - kein Excel-Export." -Tenant $TenantKey
            }
        }
        catch {
            Write-HULogWarn "Excel-Export fehlgeschlagen: $($_.Exception.Message)" -Tenant $TenantKey
        }
    }

    # Ergebnis-Objekt fuer GUI
    return [PSCustomObject]@{
        TenantKey    = $TenantKey
        TotalDevices = $allDevices.Count
        Kritisch     = $kritisch
        Warnung      = $warnung
        Inaktiv      = $inaktiv
        StaleDays    = $StaleDays
        Results      = @($sorted)
        ReportPath   = if ($reportPath) { $reportPath } else { '' }
        Timestamp    = $now.ToString('yyyy-MM-dd HH:mm:ss')
    }
}
