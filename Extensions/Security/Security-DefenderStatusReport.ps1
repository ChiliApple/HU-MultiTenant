<#
.SYNOPSIS
    Defender-Status aller Windows-Geraete: Signaturen, Echtzeit- und Manipulationsschutz, Malware, Update-Ring

.DESCRIPTION
    Umfassender Report: OS-Version, Update-Ring, Defender-Signaturstatus,
    Echtzeit-Schutz, Malware-Erkennungen, Compliance. Mit bedingter Formatierung.
    Sheets: Dashboard (KPIs), All-Devices, Non-Compliant, Defender-Issues, Signature-Expired.
    Verwendet ImportExcel + HU.Excel.psm1 fuer einheitliches Design.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All
    DeviceManagementServiceConfig.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Security

.TARGETS
    []

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $false

.EXAMPLE
    . .\Security-DefenderStatusReport.ps1
    Invoke-DefenderStatusReport -TenantKey "Schule-1" -Token $token
#>

function Invoke-DefenderStatusReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token
    )

    # ================================================================
    # HELPER: Format-DateTimeSafe
    # ================================================================
    function Format-DateTimeSafe {
        param([object]$DateString, [string]$Format = 'yyyy-MM-dd HH:mm')
        if ([string]::IsNullOrWhiteSpace($DateString)) { return '-' }
        try {
            $dt = [DateTime]::Parse($DateString)
            return $dt.ToString($Format)
        }
        catch { return [string]$DateString }
    }

    # ================================================================
    # HELPER: Parse-ProductStatus (Flags-Enum)
    # ================================================================
    function Parse-ProductStatus {
        param([object]$StatusValue)
        if ($null -eq $StatusValue) { return 'Unknown' }

        # Graph API kann Int32 ODER komma-getrennten String liefern
        $val = $null
        if ($StatusValue -is [int] -or $StatusValue -is [long]) {
            $val = [int]$StatusValue
        }
        elseif ($StatusValue -is [string]) {
            # Versuch numerischen String zu parsen
            $parsed = 0
            if ([int]::TryParse($StatusValue, [ref]$parsed)) {
                $val = $parsed
            }
            else {
                # String-Flags: "noStatusFlagsSet", "noQuickScanHappenedForSpecifiedPeriod,noStatusFlagsSet" etc.
                $flagMap = @{
                    'noStatusFlagsSet'                          = 0
                    'serviceNotRunning'                         = 1
                    'serviceStartedWithoutMalwareProtection'    = 2
                    'pendingFullScanDueToThreatAction'          = 4
                    'pendingRebootDueToThreatAction'            = 8
                    'pendingManualStepsDueToThreatAction'       = 16
                    'avSignaturesOutOfDate'                     = 32
                    'asSignaturesOutOfDate'                     = 64
                    'noQuickScanHappenedForSpecifiedPeriod'     = 128
                    'noFullScanHappenedForSpecifiedPeriod'      = 256
                    'systemInitiatedScanInProgress'             = 512
                    'systemInitiatedCleanInProgress'            = 1024
                    'samplesPendingSubmission'                  = 2048
                    'productRunningInEvaluationMode'            = 4096
                    'productRunningInNonGenuineMode'            = 8192
                    'productExpired'                            = 16384
                    'offlineScanRequired'                       = 32768
                    'serviceShutdownAsPartOfSystemShutdown'     = 65536
                    'threatRemediationFailedCritically'         = 131072
                    'threatRemediationFailedNonCritically'      = 262144
                    'noStatusFlagsSetButTurnedOff'              = 524288
                    'platformOutOfDate'                         = 1048576
                    'platformUpdateInProgress'                  = 2097152
                    'platformAboutToBeOutdated'                 = 4194304
                    'signatureOrPlatformEndOfLifeIsPastOrIsImpending' = 8388608
                    'windowsSModeSignaturesInUseOnNonWin10SInstall'   = 16777216
                }
                $val = 0
                $flags = $StatusValue -split ','
                foreach ($flag in $flags) {
                    $trimmed = $flag.Trim()
                    if ($flagMap.ContainsKey($trimmed)) {
                        $val = $val -bor $flagMap[$trimmed]
                    }
                }
            }
        }
        else {
            return 'Unknown'
        }

        if ($val -eq 0) { return 'Clean' }

        $criticalFlags = @(1, 131072, 16384, 32768)
        foreach ($f in $criticalFlags) {
            if (($val -band $f) -ne 0) { return 'Critical' }
        }
        $pendingFlags = @(4, 8, 16, 262144)
        foreach ($f in $pendingFlags) {
            if (($val -band $f) -ne 0) { return 'PendingRestart' }
        }
        $warnFlags = @(32, 64, 128, 256, 1048576, 4194304, 8388608)
        foreach ($f in $warnFlags) {
            if (($val -band $f) -ne 0) { return 'Warning' }
        }
        return 'Clean'
    }

    # ================================================================
    # 0. IMPORTEXCEL PRUEFEN
    # ================================================================

    if (-not (Initialize-HUExcel)) {
        Write-HULog -Message 'ImportExcel-Modul nicht verfuegbar. Bitte installieren: Install-Module ImportExcel -Scope CurrentUser' -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = 'ImportExcel nicht verfuegbar' }
    }

    # ================================================================
    # CONFIG
    # ================================================================

    $scriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $projectRoot  = (Get-Item $scriptRoot).Parent.Parent.FullName
    $dateStamp    = Get-Date -Format 'yyyy-MM-dd'
    $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"
    $reportBase   = "Defender-Report_$TenantKey"

    # ================================================================
    # 1. PERMISSION VALIDATION
    # ================================================================

    Write-HULog -Message 'Pruefe Berechtigungen ...' -Level 'INFO' -Tenant $TenantKey

    $requiredPerms = @(
        'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementServiceConfig.Read.All'
    )

    foreach ($perm in $requiredPerms) {
        if (-not (Test-GraphPermission -Token $Token -Permission $perm)) {
            Write-HULog -Message "Berechtigung fehlt: $perm" -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = "Berechtigung fehlt: $perm" }
        }
    }

    Write-HULog -Message 'Berechtigungen OK' -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 2. FETCH ALL MANAGED DEVICES
    # ================================================================

    Write-HULog -Message 'Lade verwaltete Geraete ...' -Level 'INFO' -Tenant $TenantKey

    $deviceResult = Get-ManagedDevices -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)
    if (-not $deviceResult -or $deviceResult.Count -eq 0) {
        Write-HULog -Message 'Keine verwalteten Geraete gefunden.' -Level 'WARN' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = 'Keine verwalteten Geraete gefunden' }
    }

    $devices = $deviceResult.Devices
    $deviceCount = $deviceResult.Count
    Write-HULog -Message "$deviceCount Geraet(e) geladen." -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 3. FETCH UPDATE RINGS
    # ================================================================

    Write-HULog -Message 'Lade Update-Ring-Konfigurationen ...' -Level 'INFO' -Tenant $TenantKey

    $updateRingMap = @{}

    try {
        $wufbConfigs = @(Invoke-GraphRequestAll -Token $Token `
            -Endpoint "/deviceManagement/deviceConfigurations?`$filter=isof('microsoft.graph.windowsUpdateForBusinessConfiguration')" `
            -TenantKey $TenantKey -Settings (Get-Settings))

        if (-not $wufbConfigs -or $wufbConfigs.Count -eq 0) {
            $allConfigs = Invoke-GraphRequestAll -Token $Token `
                -Endpoint '/deviceManagement/deviceConfigurations' `
                -TenantKey $TenantKey -Settings (Get-Settings)
            $wufbConfigs = @($allConfigs | Where-Object {
                $_.'@odata.type' -eq '#microsoft.graph.windowsUpdateForBusinessConfiguration'
            })
        }

        Write-HULog -Message "$($wufbConfigs.Count) Update-Ring(s) gefunden." -Level 'INFO' -Tenant $TenantKey

        foreach ($ring in $wufbConfigs) {
            $ringName = if ($ring.displayName) { $ring.displayName } else { 'Ring ohne Namen' }
            $ringId   = $ring.id
            try {
                $deviceStatuses = Invoke-GraphRequestAll -Token $Token `
                    -Endpoint "/deviceManagement/deviceConfigurations/$ringId/deviceStatuses" `
                    -TenantKey $TenantKey -Settings (Get-Settings)
                foreach ($ds in $deviceStatuses) {
                    if ($ds.deviceDisplayName) {
                        $updateRingMap[$ds.deviceDisplayName] = $ringName
                    }
                }
            }
            catch {
                Write-HULog -Message "Geraetestatus fuer Update-Ring '$ringName' fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
            }
        }

        Write-HULog -Message "$($updateRingMap.Count) Geraet(e) einem Update-Ring zugeordnet." -Level 'OK' -Tenant $TenantKey
    }
    catch {
        Write-HULog -Message "Abruf der Update-Ringe fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
    }

    # ================================================================
    # 4. FETCH WINDOWS PROTECTION STATE (Defender pro Device)
    # ================================================================

    # Defender-Status aller Windows-Geraete in Graph-Batches zu je 20 Abfragen holen
    # (statt einer Abfrage je Geraet - bei vielen Geraeten um ein Vielfaches schneller).
    # Quelle: learn.microsoft.com/graph/json-batching
    $winIds = @($devices | Where-Object { "$($_.operatingSystem)" -match '^Windows' -and $_.id } | ForEach-Object { "$($_.id)" })
    Write-HULog -Message "Lese Defender-Status von $($winIds.Count) Windows-Geraeten (in Paketen zu 20) ..." -Level 'INFO' -Tenant $TenantKey
    $req = @{}
    foreach ($id in $winIds) { $req[$id] = "/deviceManagement/managedDevices/$id/windowsProtectionState" }
    $wpsMap = Invoke-GraphBatchGet -Token $Token -Requests $req -OnProgress {
        param($done, $total)
        if ($done % 100 -eq 0 -or $done -eq $total) { Write-HULog -Message "[$done/$total] Defender-Status gelesen" -Level 'INFO' -Tenant $TenantKey }
    }
    Write-HULog -Message "Defender-Status fuer $($wpsMap.Count) von $($winIds.Count) Windows-Geraeten erhalten" -Level 'INFO' -Tenant $TenantKey

    $enrichedDevices = [System.Collections.ArrayList]::new()

    # Statistik-Zaehler
    $statCritical = 0; $statPendingRestart = 0; $statWarning = 0; $statClean = 0; $statUnknown = 0
    $statRtpDisabled = 0; $statTamperDisabled = 0; $statMalwareFound = 0; $statSigExpired = 0

    $counter = 0
    foreach ($device in $devices) {
        $counter++
        $deviceId   = $device.id
        $deviceName = if ($device.deviceName) { $device.deviceName } else { 'Unknown' }

        # --- OS-Info ---
        $osVersion = if ($device.operatingSystem -and $device.osVersion) {
            "$($device.operatingSystem) $($device.osVersion)"
        } elseif ($device.operatingSystem) {
            $device.operatingSystem
        } else { '-' }

        $buildNumber = if ($device.deviceBuildNumber) { $device.deviceBuildNumber }
                       elseif ($device.osVersion) { $device.osVersion }
                       else { '-' }

        $ringName        = if ($updateRingMap.ContainsKey($deviceName)) { $updateRingMap[$deviceName] } else { 'kein Ring' }
        $complianceState = if ($device.complianceState) { $device.complianceState } else { 'unknown' }
        $lastSync        = Format-DateTimeSafe -DateString $device.lastSyncDateTime
        $aadDeviceId     = if ($device.azureADDeviceId) { $device.azureADDeviceId } else { '-' }

        # --- Defender-Status via windowsProtectionState ---
        $sigStatus     = 'Unknown'
        $rtpStatus     = 'Unknown'
        $tamperStatus  = 'Unknown'
        $productStatus = 'Unknown'
        $malwareStatus = 'Nein'
        $lastScanDate  = '-'

        try {
            $wps = $wpsMap["$deviceId"]

            if ($wps -and -not ($wps.PSObject.Properties.Name -contains 'IsError' -and $wps.IsError)) {

                # Signatur-Aktualitaet
                if ($wps.lastReportedDateTime) {
                    try {
                        $sigDate = [DateTime]::Parse($wps.lastReportedDateTime)
                        $sigAge  = ((Get-Date) - $sigDate).Days
                        if ($sigAge -lt 2)      { $sigStatus = 'Ja' }
                        elseif ($sigAge -le 7)   { $sigStatus = 'Nein' }
                        else                     { $sigStatus = "Ueberfaellig $sigAge Tage"; $statSigExpired++ }
                    }
                    catch { $sigStatus = 'Unknown' }
                }
                if ($wps.PSObject.Properties.Name -contains 'signatureUpdateOverdue' -and $wps.signatureUpdateOverdue -eq $true) {
                    if ($sigStatus -eq 'Ja') { $sigStatus = 'Nein' }
                }

                # Echtzeit-Schutz
                if ($wps.PSObject.Properties.Name -contains 'antivirusEnabled') {
                    if ($wps.antivirusEnabled -eq $true) { $rtpStatus = 'Aktiviert' }
                    else { $rtpStatus = 'Deaktiviert'; $statRtpDisabled++ }
                }
                elseif ($wps.PSObject.Properties.Name -contains 'malwareProtectionEnabled') {
                    if ($wps.malwareProtectionEnabled -eq $true) { $rtpStatus = 'Aktiviert' }
                    else { $rtpStatus = 'Deaktiviert'; $statRtpDisabled++ }
                }

                # Manipulationsschutz
                if ($wps.PSObject.Properties.Name -contains 'tamperProtectionEnabled') {
                    if ($wps.tamperProtectionEnabled -eq $true) { $tamperStatus = 'Aktiviert' }
                    else { $tamperStatus = 'Deaktiviert'; $statTamperDisabled++ }
                }

                # Product Status (Flags)
                if ($wps.PSObject.Properties.Name -contains 'productStatus') {
                    $productStatus = Parse-ProductStatus -StatusValue $wps.productStatus
                }

                # Malware-Erkennungen
                if ($wps.PSObject.Properties.Name -contains 'detectedMalwareState') {
                    $malwareList = @($wps.detectedMalwareState)
                    if ($malwareList.Count -gt 0 -and $null -ne $malwareList[0]) {
                        $activeThreats = @($malwareList | Where-Object {
                            $_.state -ne 'fullyScanRequired' -and $_.state -ne 'cleanedByAv'
                        })
                        if ($activeThreats.Count -gt 0) {
                            $malwareStatus = "Ja - $($activeThreats.Count) aktive Bedrohungen"
                            $statMalwareFound++
                        }
                    }
                }

                # Letzter Scan
                if ($wps.lastFullScanDateTime) {
                    $lastScanDate = Format-DateTimeSafe -DateString $wps.lastFullScanDateTime
                }
                elseif ($wps.lastQuickScanDateTime) {
                    $lastScanDate = Format-DateTimeSafe -DateString $wps.lastQuickScanDateTime
                }
            }
        }
        catch {
            if ($counter -le 5 -or $counter % 50 -eq 0) {
                Write-HULog -Message "[$counter/$deviceCount] windowsProtectionState fehlgeschlagen fuer $deviceName : $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
            }
        }

        # Statistik
        switch ($productStatus) {
            'Critical'       { $statCritical++ }
            'PendingRestart' { $statPendingRestart++ }
            'Warning'        { $statWarning++ }
            'Clean'          { $statClean++ }
            default          { $statUnknown++ }
        }

        # --- Enriched Object (14 Spalten) ---
        $enriched = [PSCustomObject]@{
            DeviceName                  = $deviceName
            DeviceID                    = $aadDeviceId
            ManagedDeviceID             = $deviceId
            OSVersion                   = $osVersion
            WindowsVersionBuild         = $buildNumber
            UpdateRing                  = $ringName
            Defender_SignaturenAktuell   = $sigStatus
            Defender_Echtzeitschutz      = $rtpStatus
            Defender_Manipulationsschutz = $tamperStatus
            Defender_ProductStatus       = $productStatus
            Defender_MalwareFound        = $malwareStatus
            LastDefenderScan             = $lastScanDate
            ComplianceState              = $complianceState
            LastSyncDateTime             = $lastSync
        }

        [void]$enrichedDevices.Add($enriched)

    }

    # ================================================================
    # 5. FILTER-LISTEN
    # ================================================================

    $nonCompliantDevices = @($enrichedDevices | Where-Object { $_.ComplianceState -ne 'compliant' -and $_.ComplianceState -ne 'unknown' })
    $defenderIssues      = @($enrichedDevices | Where-Object { $_.Defender_ProductStatus -ne 'Clean' -or $_.Defender_MalwareFound -ne 'Nein' })
    $signatureExpired    = @($enrichedDevices | Where-Object { $_.Defender_SignaturenAktuell -like 'Ueberfaellig*' })

    Write-HULog -Message "Defender-Daten vollstaendig. Probleme: $($defenderIssues.Count), Signatur abgelaufen: $($signatureExpired.Count), Nicht konform: $($nonCompliantDevices.Count)" -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 6. SECURITY ALERTS (optional)
    # ================================================================

    try {
        $hasSecPerm = Test-GraphPermission -Token $Token -Permission 'SecurityEvents.Read.All'
        if ($hasSecPerm) {
            Write-HULog -Message 'Lade Sicherheitswarnungen ...' -Level 'INFO' -Tenant $TenantKey
            $alerts = Get-MalwareAlerts -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)
            if ($alerts -and $alerts.Count -gt 0) {
                $alertsByDevice = @{}
                foreach ($alert in $alerts) {
                    if ($alert.evidence) {
                        foreach ($ev in $alert.evidence) {
                            if ($ev.deviceDnsName) {
                                if (-not $alertsByDevice.ContainsKey($ev.deviceDnsName)) {
                                    $alertsByDevice[$ev.deviceDnsName] = [System.Collections.ArrayList]::new()
                                }
                                [void]$alertsByDevice[$ev.deviceDnsName].Add($alert)
                            }
                        }
                    }
                }
                Write-HULog -Message "$($alerts.Count) Sicherheitswarnung(en), $($alertsByDevice.Keys.Count) Geraet(e) betroffen." -Level 'OK' -Tenant $TenantKey

                # Malware-Status nachtraeglich updaten
                foreach ($dev in $enrichedDevices) {
                    if ($dev.Defender_MalwareFound -eq 'Nein' -and $alertsByDevice.ContainsKey($dev.DeviceName)) {
                        $alertCount = $alertsByDevice[$dev.DeviceName].Count
                        $dev.Defender_MalwareFound = "Ja - $alertCount Alert(s)"
                        $statMalwareFound++
                    }
                }
                # Filter-Listen neu berechnen
                $defenderIssues   = @($enrichedDevices | Where-Object { $_.Defender_ProductStatus -ne 'Clean' -or $_.Defender_MalwareFound -ne 'Nein' })
                $signatureExpired = @($enrichedDevices | Where-Object { $_.Defender_SignaturenAktuell -like 'Ueberfaellig*' })
            }
        }
        else {
            Write-HULog -Message 'SecurityEvents.Read.All nicht vorhanden - Alerts uebersprungen.' -Level 'WARN' -Tenant $TenantKey
        }
    }
    catch {
        Write-HULog -Message "Abruf der Sicherheitswarnungen fehlgeschlagen (unkritisch): $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
    }

    # ================================================================
    # 7. GENERATE EXCEL REPORT (ImportExcel)
    # ================================================================

    Write-HULog -Message 'Erstelle Excel-Report (ImportExcel) ...' -Level 'INFO' -Tenant $TenantKey

    if (-not (Test-Path $reportFolder)) {
        New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null
    }

    $version = 1
    do {
        $reportFileName = "${reportBase}_v${version}.xlsx"
        $reportPath = Join-Path $reportFolder $reportFileName
        $version++
    } while (Test-Path $reportPath)

    try {
        # --- Sheet 1: All-Devices (14 Spalten) ---
        $enrichedDevices | Export-Excel -Path $reportPath -WorksheetName 'All-Devices' `
            -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *

        # --- Sheet 2: Non-Compliant ---
        if ($nonCompliantDevices.Count -gt 0) {
            $nonCompliantDevices | Export-Excel -Path $reportPath -WorksheetName 'Non-Compliant' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine nicht konformen Geraete gefunden.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Non-Compliant' -Append
        }

        # --- Sheet 3: Defender-Issues ---
        if ($defenderIssues.Count -gt 0) {
            $defenderIssues | Export-Excel -Path $reportPath -WorksheetName 'Defender-Issues' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine Defender-Probleme gefunden.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Defender-Issues' -Append
        }

        # --- Sheet 4: Signature-Expired ---
        if ($signatureExpired.Count -gt 0) {
            $signatureExpired | Export-Excel -Path $reportPath -WorksheetName 'Signature-Expired' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine abgelaufenen Signaturen.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Signature-Expired' -Append
        }

        # --- Standard-Formatierung ---
        Write-HULog -Message 'Wende HU-Standardformatierung an ...' -Level 'INFO' -Tenant $TenantKey

        Format-HUExcelWorkbook -WorkbookPath $reportPath `
            -PrimaryKeyColumn 'DeviceName' `
            -ConditionalColumns @(
                'Defender_SignaturenAktuell', 'Defender_Echtzeitschutz',
                'Defender_Manipulationsschutz', 'Defender_ProductStatus',
                'Defender_MalwareFound', 'ComplianceState'
            )

        # --- Freeze Panes: Header + Spalten A-C fixiert ---
        Set-HUExcelFreezePanes -WorkbookPath $reportPath -SheetName 'All-Devices' -FreezeRow 2 -FreezeColumn 4

        # --- Column Grouping ---
        Set-HUExcelColumnGrouping -WorkbookPath $reportPath `
            -GroupDefinitions @(
                @{ Title = 'GERAET';     Columns = @('DeviceName', 'DeviceID', 'ManagedDeviceID') }
                @{ Title = 'OS UPDATE';  Columns = @('OSVersion', 'WindowsVersionBuild', 'UpdateRing') }
                @{ Title = 'DEFENDER';   Columns = @('Defender_SignaturenAktuell', 'Defender_Echtzeitschutz', 'Defender_Manipulationsschutz', 'Defender_ProductStatus', 'Defender_MalwareFound', 'LastDefenderScan') }
                @{ Title = 'COMPLIANCE'; Columns = @('ComplianceState', 'LastSyncDateTime') }
            )

        # --- Dashboard ---
        $dashMetrics = [ordered]@{
            'Geraete gesamt'                = $deviceCount
            'Sauber (Clean)'                = $statClean
            'Kritisch (Critical)'           = $statCritical
            'Neustart ausstehend (Pending)' = $statPendingRestart
            'Echtzeitschutz deaktiviert'    = $statRtpDisabled
            'Manipulationsschutz deaktiviert' = $statTamperDisabled
            'Malware gefunden'              = $statMalwareFound
            'Signaturen abgelaufen (>7d)'   = $statSigExpired
            'Nicht konform (Non-Compliant)' = $nonCompliantDevices.Count
        }

        $sheetLinks = @(
            @{ SheetName = 'All-Devices';       RowCount = $deviceCount;                Description = 'Alle Geraete (14 Spalten)' }
            @{ SheetName = 'Non-Compliant';     RowCount = $nonCompliantDevices.Count;  Description = 'Nicht-konforme Geraete' }
            @{ SheetName = 'Defender-Issues';   RowCount = $defenderIssues.Count;       Description = 'ProductStatus ungleich Clean oder Malware' }
            @{ SheetName = 'Signature-Expired'; RowCount = $signatureExpired.Count;     Description = 'Signaturen > 7 Tage ueberfaellig' }
        )

        Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey `
            -ReportTitle 'Defender-Status-Report' -Metrics $dashMetrics -SheetDataSources $sheetLinks

        Write-HULog -Message "Report gespeichert: $reportPath" -Level 'OK' -Tenant $TenantKey
    }
    catch {
        $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
        Write-HULog -Message "Excel-Erstellung fehlgeschlagen: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }

    # ================================================================
    # 8. OPEN REPORT IN EXCEL
    # ================================================================

    if (Test-Path $reportPath) {
        Write-HULog -Message 'Oeffne Report in Excel ...' -Level 'INFO' -Tenant $TenantKey
        try { Start-Process -FilePath $reportPath }
        catch {
            Write-HULog -Message "Automatisches Oeffnen fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
        }
    }

    # ================================================================
    # 9. FINAL RESULT
    # ================================================================

    Write-HULog -Message "Defender-Report fertig: $deviceCount Geraete, $($defenderIssues.Count) Probleme, $statCritical kritisch" -Level 'OK' -Tenant $TenantKey

    return [PSCustomObject]@{
        Success             = $true
        ReportPath          = $reportPath
        TenantKey           = $TenantKey
        TotalDevices        = $deviceCount
        DefenderIssues      = $defenderIssues.Count
        CriticalCount       = $statCritical
        PendingRestartCount = $statPendingRestart
        MalwareFoundCount   = $statMalwareFound
        SigExpiredCount     = $statSigExpired
        RtpDisabledCount    = $statRtpDisabled
        NonCompliantCount   = $nonCompliantDevices.Count
        GeneratedAt         = Get-Date
    }
}
