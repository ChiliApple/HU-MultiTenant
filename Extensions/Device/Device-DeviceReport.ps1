<#
.SYNOPSIS
    Geraete-Report: alle Intune-Geraete mit Sync-Ampel und Compliance als Excel

.DESCRIPTION
    Ein Report fuer alle verwalteten Geraete eines Tenants (ersetzt AllDevicesReport,
    StaleDevicesReport und SyncStatusExport).
    Ampel nach Tagen ohne Synchronisierung: OK (bis 30), Warnung (31-89), Kritisch (90-119),
    Cleanup-Gefahr (ab 120 - Intune-Bereinigungsregeln entfernen solche Geraete oft automatisch).
    Blaetter: Dashboard, Alle-Geraete, Sync-Warnung, Cleanup-Gefahr, Nicht-konform
    (mit den nicht erfuellten Compliance-Richtlinien je Geraet).
    Geeignet zur Weitergabe an Kustoden: Filter, Ampelfarben, fixierte Kopfzeile.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All

.CATEGORY
    Device

.TARGETS
    []

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $false

.RUNTIME
    PS5

.MODE
    ReadOnly

.PARAM
    NurWindows|bool|Nur Windows-Geraete|false

.EXAMPLE
    . .\Device-DeviceReport.ps1
    Invoke-DeviceReport -TenantKey "Schule-1" -Token $token
#>

function Invoke-DeviceReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantKey,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [bool]$NurWindows = $false
    )

    [string]$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    [string]$projectRoot = (Get-Item $scriptRoot).Parent.Parent.FullName
    [string]$reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$(Get-Date -Format 'yyyy-MM-dd')"
    [string]$reportBase = "Geraete-Report_$TenantKey"

    try {
        Write-HULog -Message 'Geraete-Report gestartet' -Level 'INFO' -Tenant $TenantKey

        if (-not (Initialize-HUExcel)) {
            Write-HULog -Message 'Modul ImportExcel nicht verfuegbar.' -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = 'ImportExcel nicht verfuegbar' }
        }
        if (-not (Test-GraphPermission -Token $Token -Permission 'DeviceManagementManagedDevices.Read.All')) {
            Write-HULog -Message 'Fehlende Berechtigung: DeviceManagementManagedDevices.Read.All' -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = 'Fehlende Berechtigung' }
        }

        # --- 1. Geraete laden ---
        Write-HULog -Message 'Lade verwaltete Geraete ...' -Level 'INFO' -Tenant $TenantKey
        $res = Get-ManagedDevices -Token $Token -TenantKey $TenantKey -Settings (Get-Settings) `
            -Select @('id', 'deviceName', 'serialNumber', 'userPrincipalName', 'model', 'manufacturer', 'operatingSystem', 'osVersion',
                'managedDeviceOwnerType', 'enrolledDateTime', 'lastSyncDateTime', 'complianceState')
        [array]$devices = @(if ($res -and $res.Devices) { $res.Devices })
        if ($NurWindows) { $devices = @($devices | Where-Object { "$($_.operatingSystem)" -match '^Windows' }) }
        Write-HULog -Message "$($devices.Count) Geraete geladen$(if ($NurWindows) { ' (nur Windows)' })" -Level 'INFO' -Tenant $TenantKey

        # --- 2. Ampel ---
        $now = Get-Date
        $rows = New-Object System.Collections.Generic.List[object]
        $cnt = @{ OK = 0; Warnung = 0; Kritisch = 0; 'Cleanup-Gefahr' = 0 }
        foreach ($d in $devices) {
            $days = 9999; $last = 'nie'
            if ($d.lastSyncDateTime) {
                try { $ls = [datetime]$d.lastSyncDateTime; $days = [int]($now - $ls).TotalDays; $last = $ls.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
            }
            $status = if ($days -ge 120) { 'Cleanup-Gefahr' } elseif ($days -ge 90) { 'Kritisch' } elseif ($days -gt 30) { 'Warnung' } else { 'OK' }
            $cnt[$status]++
            $owner = switch ("$($d.managedDeviceOwnerType)") { 'company' { 'Unternehmen' } 'personal' { 'Privat' } default { "$($d.managedDeviceOwnerType)" } }
            $rows.Add([PSCustomObject][ordered]@{
                    DeviceName       = "$($d.deviceName)"
                    SerialNumber     = "$($d.serialNumber)"
                    User             = "$($d.userPrincipalName)"
                    Hersteller       = "$($d.manufacturer)"
                    Model            = "$($d.model)"
                    OS               = "$($d.operatingSystem)"
                    OSVersion        = "$($d.osVersion)"
                    Besitzer         = $owner
                    Enrolled         = $(if ($d.enrolledDateTime) { try { ([datetime]$d.enrolledDateTime).ToString('yyyy-MM-dd') } catch { '' } } else { '' })
                    LastSync         = $last
                    TageSeitSync     = $days
                    Status           = $status
                    ComplianceState  = $(if ($d.complianceState) { "$($d.complianceState)" } else { 'unknown' })
                    ComplianceDetail = ''
                    Id               = "$($d.id)"
                })
        }
        Write-HULog -Message "Ampel: OK=$($cnt.OK) | Warnung=$($cnt.Warnung) | Kritisch=$($cnt.Kritisch) | Cleanup-Gefahr=$($cnt.'Cleanup-Gefahr')" -Level 'INFO' -Tenant $TenantKey

        # --- 3. Compliance-Details nur fuer nicht konforme Geraete ---
        $nonComp = @($rows | Where-Object { $_.ComplianceState -in 'noncompliant', 'error', 'conflict' })
        if ($nonComp.Count) {
            Write-HULog -Message "Lese Compliance-Details fuer $($nonComp.Count) nicht konforme Geraete ..." -Level 'INFO' -Tenant $TenantKey
            $req = @{}
            foreach ($r in $nonComp) { $req[$r.Id] = "/deviceManagement/managedDevices/$($r.Id)/deviceCompliancePolicyStates" }
            $map = Invoke-GraphBatchGet -Token $Token -Requests $req -OnProgress {
                param($done, $total)
                if ($done % 100 -eq 0 -or $done -eq $total) { Write-HULog -Message "[$done/$total] Compliance-Details gelesen" -Level 'INFO' -Tenant $TenantKey }
            }
            foreach ($r in $nonComp) {
                $b = $map[$r.Id]
                if (-not $b) { $r.ComplianceDetail = '(nicht lesbar)'; continue }
                $bad = @(@($b.value) | Where-Object { $_ -and $_.state -notin 'compliant', 'notApplicable', 'unknown' })
                $r.ComplianceDetail = (@($bad | ForEach-Object { "$(if ($_.displayName) { $_.displayName } else { $_.id }) ($($_.state))" }) -join '; ')
            }
        }

        # --- 4. Blaetter ---
        $out = @($rows | Sort-Object TageSeitSync -Descending | Select-Object -Property * -ExcludeProperty Id)
        $sheets = [ordered]@{
            'Alle-Geraete'   = @{ Rows = $out; Desc = 'Alle verwalteten Geraete'; Empty = 'Keine Geraete vorhanden.' }
            'Sync-Warnung'   = @{ Rows = @($out | Where-Object { $_.Status -ne 'OK' }); Desc = 'Mehr als 30 Tage ohne Sync'; Empty = 'Alle Geraete haben in den letzten 30 Tagen synchronisiert.' }
            'Cleanup-Gefahr' = @{ Rows = @($out | Where-Object { $_.Status -eq 'Cleanup-Gefahr' }); Desc = 'Ab 120 Tagen ohne Sync'; Empty = 'Keine Geraete im Cleanup-Bereich.' }
            'Nicht-konform'  = @{ Rows = @($out | Where-Object { $_.ComplianceState -in 'noncompliant', 'error', 'conflict' }); Desc = 'Nicht konform, mit Richtlinien'; Empty = 'Alle Geraete sind konform.' }
        }

        if (-not (Test-Path -LiteralPath $reportFolder)) { New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null }
        $v = 1
        do { $reportPath = Join-Path $reportFolder "${reportBase}_v$v.xlsx"; $v++ } while (Test-Path -LiteralPath $reportPath)

        Write-HULog -Message 'Erstelle Excel-Report ...' -Level 'INFO' -Tenant $TenantKey
        $first = $true
        foreach ($name in $sheets.Keys) {
            $sh = $sheets[$name]
            $data = if (@($sh.Rows).Count) { @($sh.Rows) } else { @([PSCustomObject]@{ Info = $sh.Empty }) }
            $p = @{ Path = $reportPath; WorksheetName = $name; AutoSize = $true; FreezeTopRow = $true; BoldTopRow = $true; NoNumberConversion = '*' }
            if (-not $first) { $p.Append = $true }
            $data | Export-Excel @p
            $first = $false
        }

        Format-HUExcelWorkbook -WorkbookPath $reportPath -PrimaryKeyColumn 'DeviceName' -ConditionalColumns @('Status', 'ComplianceState')
        Set-HUExcelColumnGrouping -WorkbookPath $reportPath -GroupDefinitions @(
            @{ Title = 'GERAET'; Columns = @('DeviceName', 'SerialNumber', 'User', 'Besitzer') }
            @{ Title = 'SYSTEM'; Columns = @('Hersteller', 'Model', 'OS', 'OSVersion') }
            @{ Title = 'SYNC'; Columns = @('Enrolled', 'LastSync', 'TageSeitSync', 'Status') }
            @{ Title = 'COMPLIANCE'; Columns = @('ComplianceState', 'ComplianceDetail') }
        )
        $metrics = [ordered]@{
            'Geraete gesamt'          = $rows.Count
            'OK (bis 30 Tage)'        = $cnt.OK
            'Warnung (31-89 Tage)'    = $cnt.Warnung
            'Kritisch (90-119 Tage)'  = $cnt.Kritisch
            'Cleanup-Gefahr (ab 120)' = $cnt.'Cleanup-Gefahr'
            'Nicht konform'           = @($sheets['Nicht-konform'].Rows).Count
        }
        $links = @(foreach ($name in $sheets.Keys) { @{ SheetName = $name; RowCount = @($sheets[$name].Rows).Count; Description = $sheets[$name].Desc } })
        Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey -ReportTitle 'Geraete-Report' -Metrics $metrics -SheetDataSources $links

        Write-HULog -Message "Report gespeichert: $reportPath" -Level 'OK' -Tenant $TenantKey
        try { Start-Process -FilePath $reportPath } catch { Write-HULog -Message "Report konnte nicht geoeffnet werden: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }

        return [PSCustomObject]@{
            Success       = $true
            ReportPath    = $reportPath
            TotalDevices  = $rows.Count
            OkCount       = $cnt.OK
            WarnCount     = $cnt.Warnung
            CritCount     = $cnt.Kritisch
            CleanupCount  = $cnt.'Cleanup-Gefahr'
            NonCompliant  = @($sheets['Nicht-konform'].Rows).Count
        }
    }
    catch {
        $line = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        Write-HULog -Message "Fehler: $($_.Exception.Message)$line" -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
