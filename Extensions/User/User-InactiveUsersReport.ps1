<#
.SYNOPSIS
    Inaktive Benutzer (3/6/12+ Monate ohne Anmeldung) mit Lizenzen

.DESCRIPTION
    Liest alle User der Tenant-Domain aus und kategorisiert
    nach Inaktivitaet basierend auf signInActivity.lastSignInDateTime.
    Domain wird automatisch aus settings.json gelesen.
    Prueft zusaetzlich: Lizenzzuweisung, Account-Status, Erstellungsdatum,
    Department, JobTitle, Non-Interactive Sign-In.
    Sheets: Dashboard, All-Users, Inactive-3M, Inactive-6M, Inactive-12M+,
            Licensed-Inactive, Never-SignedIn.

.REQUIRED_PERMISSIONS
    User.Read.All
    AuditLog.Read.All
    Organization.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    User

.TARGETS
    []

.BATCH_CAPABLE
    $false

.DRY_RUN_CAPABLE
    $false

.RUNTIME
    PS5

.EXAMPLE
    . .\User-InactiveUsersReport.ps1
    Invoke-InactiveUsersReport -TenantKey "Schule-1" -Token $token
#>

function Invoke-InactiveUsersReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$DryRun
    )

    # ================================================================
    # 0. IMPORTEXCEL PRUEFEN
    # ================================================================

    if (-not (Initialize-HUExcel)) {
        Write-HULog -Message 'ImportExcel-Modul nicht verfuegbar.' -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = 'ImportExcel nicht verfuegbar' }
    }

    # ================================================================
    # CONFIG
    # ================================================================

    $scriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $projectRoot  = (Get-Item $scriptRoot).Parent.Parent.FullName
    $dateStamp    = Get-Date -Format 'yyyy-MM-dd'
    $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"
    $reportBase   = "InactiveUsers-Report_$TenantKey"

    # Schwellenwerte
    $now = Get-Date
    $threshold3M  = $now.AddMonths(-3)
    $threshold6M  = $now.AddMonths(-6)
    $threshold12M = $now.AddMonths(-12)

    # ================================================================
    # 1. PERMISSION VALIDATION
    # ================================================================

    Write-HULog -Message 'Pruefe Berechtigungen ...' -Level 'INFO' -Tenant $TenantKey

    $requiredPerms = @('User.Read.All', 'AuditLog.Read.All')
    foreach ($perm in $requiredPerms) {
        if (-not (Test-GraphPermission -Token $Token -Permission $perm)) {
            Write-HULog -Message "Berechtigung fehlt: $perm" -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = "Berechtigung fehlt: $perm" }
        }
    }

    Write-HULog -Message 'Berechtigungen OK' -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 2. FETCH ALL USERS WITH SIGN-IN ACTIVITY
    # ================================================================

    Write-HULog -Message "Lade alle User mit signInActivity ..." -Level 'INFO' -Tenant $TenantKey

    # signInActivity erfordert AuditLog.Read.All
    # Kein Domain-Filter: Tenant = Schule, alle User gehoeren zum Tenant
    $selectFields = 'id,displayName,userPrincipalName,mail,accountEnabled,createdDateTime,userType,assignedLicenses,signInActivity,department,jobTitle,companyName,faxNumber,officeLocation'
    $allUsers = Invoke-GraphRequestAll -Token $Token `
        -Endpoint "/users?`$select=$selectFields" `
        -TenantKey $TenantKey -Settings (Get-Settings)

    if (-not $allUsers -or @($allUsers).Count -eq 0) {
        Write-HULog -Message 'Keine User im Tenant gefunden.' -Level 'WARN' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = 'Keine User im Tenant gefunden' }
    }

    $allUsers = @($allUsers)
    $userCount = $allUsers.Count

    # Domain-Erkennung fuer Report-Titel (haeufigste UPN-Domain)
    $domainCounts = @{}
    foreach ($u in $allUsers) {
        if ($u.userPrincipalName -and $u.userPrincipalName -match '@(.+)$') {
            $d = $Matches[1]
            if ($domainCounts.ContainsKey($d)) { $domainCounts[$d]++ } else { $domainCounts[$d] = 1 }
        }
    }
    $primaryDomain = ($domainCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
    if (-not $primaryDomain) { $primaryDomain = $TenantKey }

    Write-HULog -Message "$userCount User geladen. Primaere Domain: @$primaryDomain" -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 3. FETCH SKU MAPPING (fuer Lizenznamen)
    # ================================================================

    Write-HULog -Message 'Lade SKU-Zuordnung ...' -Level 'INFO' -Tenant $TenantKey

    $skuIdMap = @{}
    try {
        $skuResponse = Invoke-GraphRequestWithRetry -Token $Token -Endpoint '/subscribedSkus' -TenantKey $TenantKey -Settings (Get-Settings)
        if ($skuResponse -and $skuResponse.value) {
            foreach ($sku in $skuResponse.value) {
                $skuIdMap[$sku.skuId] = $sku.skuPartNumber
            }
        }
        Write-HULog -Message "$($skuIdMap.Count) SKUs geladen." -Level 'INFO' -Tenant $TenantKey
    }
    catch {
        Write-HULog -Message "SKU-Zuordnung fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
    }

    # ================================================================
    # 4. SCHULTYP-ERKENNUNG (adSchema aus settings.json)
    # ================================================================

    # adSchema "iPack": Rolle in faxNumber, Klasse in officeLocation oder DisplayName
    # adSchema "VirtualSchool" (Default): Rolle in jobTitle, Klasse in department
    # Konfigurierbar pro Tenant in settings.json: "adSchema": "iPack" | "VirtualSchool"
    $tenantConfig = (Get-Settings).tenants | Where-Object { $_.key -eq $TenantKey }
    $isIPack = ($tenantConfig -and $tenantConfig.adSchema -eq 'iPack')
    Write-HULog -Message "AD-Schema: $(if ($isIPack) { 'iPack' } else { 'VirtualSchool' })" -Level 'INFO' -Tenant $TenantKey

    # ================================================================
    # 5. ENRICH USER DATA
    # ================================================================

    Write-HULog -Message 'Verarbeite User-Daten ...' -Level 'INFO' -Tenant $TenantKey

    $enrichedUsers = [System.Collections.ArrayList]::new()
    $counter = 0

    # Zaehler
    $activeCount     = 0
    $inactive3MCount = 0
    $inactive6MCount = 0
    $inactive12MCount = 0
    $neverSignedIn   = 0
    $licensedInactiveCount = 0
    $disabledCount   = 0

    foreach ($user in $allUsers) {
        $counter++

        # --- Last Sign-In ---
        $lastSignIn     = $null
        $lastSignInStr  = 'Nie'
        $daysSinceSignIn = 9999
        $category        = 'Active'

        if ($user.signInActivity -and $user.signInActivity.lastSignInDateTime) {
            try {
                $lastSignIn = [datetime]$user.signInActivity.lastSignInDateTime
                $lastSignInStr = $lastSignIn.ToString('yyyy-MM-dd HH:mm')
                $daysSinceSignIn = ($now - $lastSignIn).Days
            }
            catch {
                $lastSignInStr = 'Parse-Fehler'
                $daysSinceSignIn = 9999
            }
        }

        # Non-Interactive Sign-In als Fallback
        $lastNonInteractive    = $null
        $lastNonInteractiveStr = ''
        if ($user.signInActivity -and $user.signInActivity.lastNonInteractiveSignInDateTime) {
            try {
                $lastNonInteractive = [datetime]$user.signInActivity.lastNonInteractiveSignInDateTime
                $lastNonInteractiveStr = $lastNonInteractive.ToString('yyyy-MM-dd HH:mm')
            }
            catch { $lastNonInteractiveStr = '' }
        }

        # --- Kategorie bestimmen ---
        if ($daysSinceSignIn -eq 9999) {
            $category = 'Never-SignedIn'
            $neverSignedIn++
        }
        elseif ($lastSignIn -lt $threshold12M) {
            $category = 'Inactive-12M+'
            $inactive12MCount++
        }
        elseif ($lastSignIn -lt $threshold6M) {
            $category = 'Inactive-6M'
            $inactive6MCount++
        }
        elseif ($lastSignIn -lt $threshold3M) {
            $category = 'Inactive-3M'
            $inactive3MCount++
        }
        else {
            $category = 'Active'
            $activeCount++
        }

        # --- Lizenzen ---
        $licenseCount = 0
        $licenseNames = @()

        if ($user.assignedLicenses -and $user.assignedLicenses.Count -gt 0) {
            foreach ($lic in $user.assignedLicenses) {
                $licenseCount++
                if ($skuIdMap.ContainsKey($lic.skuId)) {
                    $licenseNames += $skuIdMap[$lic.skuId]
                }
                else {
                    $licenseNames += $lic.skuId
                }
            }
        }

        $licensesStr = if ($licenseNames.Count -gt 0) { $licenseNames -join ', ' } else { 'Keine' }
        $hasLicense  = if ($licenseCount -gt 0) { 'Ja' } else { 'Nein' }

        # Lizenziert aber inaktiv?
        if ($licenseCount -gt 0 -and $category -ne 'Active') {
            $licensedInactiveCount++
        }

        # --- Account-Status ---
        $accountEnabled = if ($user.accountEnabled -eq $true) { 'Aktiv' } else { 'Deaktiviert' }
        if ($user.accountEnabled -ne $true) { $disabledCount++ }

        # --- Erstellungsdatum ---
        $createdStr = ''
        $accountAge = ''
        if ($user.createdDateTime) {
            try {
                $created = [datetime]$user.createdDateTime
                $createdStr = $created.ToString('yyyy-MM-dd')
                $ageDays = ($now - $created).Days
                if ($ageDays -ge 365) {
                    $accountAge = "$([math]::Floor($ageDays / 365)) Jahre"
                }
                else {
                    $accountAge = "$ageDays Tage"
                }
            }
            catch { $createdStr = '' }
        }

        # --- Rolle + Klasse (schultyp-abhaengig) ---
        $rolle  = ''
        $klasse = ''

        if ($isIPack) {
            # iPack-Schema:
            #   Rolle  = faxNumber (Schueler/Lehrer)
            #   Klasse = officeLocation ODER aus DisplayName nach Komma ("Nachname Vorname, 3D")
            $rolle = if ($user.faxNumber) { $user.faxNumber } else { '' }
            $klasse = if ($user.officeLocation) {
                $user.officeLocation
            }
            elseif ($user.displayName -and $user.displayName -match ',\s*(\S+)\s*$') {
                $Matches[1]
            }
            else { '' }
        }
        else {
            # VirtualSchool-Schema:
            #   Rolle  = jobTitle (Schueler/Lehrer)
            #   Klasse = department (4B, 3D, Abteilung etc.)
            $rolle  = if ($user.jobTitle) { $user.jobTitle } else { '' }
            $klasse = if ($user.department) { $user.department } else { '' }
        }

        # --- Enriched Object ---
        $userObj = [PSCustomObject]@{
            DisplayName          = if ($user.displayName) { $user.displayName } else { '' }
            UPN                  = if ($user.userPrincipalName) { $user.userPrincipalName } else { '' }
            Rolle                = $rolle
            Klasse               = $klasse
            AccountStatus        = $accountEnabled
            UserType             = if ($user.userType) { $user.userType } else { 'Member' }
            LastSignIn           = $lastSignInStr
            DaysSinceSignIn      = if ($daysSinceSignIn -eq 9999) { 'Nie' } else { $daysSinceSignIn }
            LastNonInteractive   = $lastNonInteractiveStr
            Category             = $category
            HasLicense           = $hasLicense
            LicenseCount         = $licenseCount
            Licenses             = $licensesStr
            CreatedDate          = $createdStr
            AccountAge           = $accountAge
        }

        [void]$enrichedUsers.Add($userObj)

        if ($counter % 50 -eq 0) {
            Write-HULog -Message "[$counter/$userCount] Verarbeite ..." -Level 'INFO' -Tenant $TenantKey
        }
    }

    Write-HULog -Message "Verarbeitung abgeschlossen: $activeCount aktiv | $inactive3MCount 3M | $inactive6MCount 6M | $inactive12MCount 12M+ | $neverSignedIn nie angemeldet" -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 6. FILTER LISTS
    # ================================================================

    $inactive3MList  = @($enrichedUsers | Where-Object { $_.Category -eq 'Inactive-3M' })
    $inactive6MList  = @($enrichedUsers | Where-Object { $_.Category -eq 'Inactive-6M' })
    $inactive12MList = @($enrichedUsers | Where-Object { $_.Category -eq 'Inactive-12M+' })
    $neverSignedInList = @($enrichedUsers | Where-Object { $_.Category -eq 'Never-SignedIn' })
    $licensedInactiveList = @($enrichedUsers | Where-Object { $_.HasLicense -eq 'Ja' -and $_.Category -ne 'Active' })

    # ================================================================
    # 7. DRY-RUN CHECK
    # ================================================================

    if ($DryRun) {
        Write-HULog -Message "DRY-RUN: $userCount User, $($inactive3MList.Count + $inactive6MList.Count + $inactive12MList.Count + $neverSignedInList.Count) inaktiv, $licensedInactiveCount mit Lizenz. Kein Report." -Level 'WARN' -Tenant $TenantKey
        return [PSCustomObject]@{
            Success = $true; DryRun = $true
            TotalUsers = $userCount; Active = $activeCount
            Inactive3M = $inactive3MCount; Inactive6M = $inactive6MCount
            Inactive12M = $inactive12MCount; NeverSignedIn = $neverSignedIn
            LicensedInactive = $licensedInactiveCount
        }
    }

    # ================================================================
    # 8. GENERATE EXCEL REPORT
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
        # --- Sheet 1: All-Users ---
        $enrichedUsers | Export-Excel -Path $reportPath -WorksheetName 'All-Users' `
            -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *

        # --- Sheet 2: Inactive-3M ---
        if ($inactive3MList.Count -gt 0) {
            $inactive3MList | Export-Excel -Path $reportPath -WorksheetName 'Inactive-3M' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine User in dieser Kategorie.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Inactive-3M' -Append
        }

        # --- Sheet 3: Inactive-6M ---
        if ($inactive6MList.Count -gt 0) {
            $inactive6MList | Export-Excel -Path $reportPath -WorksheetName 'Inactive-6M' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine User in dieser Kategorie.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Inactive-6M' -Append
        }

        # --- Sheet 4: Inactive-12M+ ---
        if ($inactive12MList.Count -gt 0) {
            $inactive12MList | Export-Excel -Path $reportPath -WorksheetName 'Inactive-12M+' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine User in dieser Kategorie.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Inactive-12M+' -Append
        }

        # --- Sheet 5: Licensed-Inactive ---
        if ($licensedInactiveList.Count -gt 0) {
            $licensedInactiveList | Export-Excel -Path $reportPath -WorksheetName 'Licensed-Inactive' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Keine inaktiven User mit Lizenz.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Licensed-Inactive' -Append
        }

        # --- Sheet 6: Never-SignedIn ---
        if ($neverSignedInList.Count -gt 0) {
            $neverSignedInList | Export-Excel -Path $reportPath -WorksheetName 'Never-SignedIn' `
                -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
        } else {
            @([PSCustomObject]@{ Info = 'Alle User haben sich mindestens einmal angemeldet.' }) |
                Export-Excel -Path $reportPath -WorksheetName 'Never-SignedIn' -Append
        }

        # --- Standard-Formatierung ---
        Write-HULog -Message 'Wende HU-Standardformatierung an ...' -Level 'INFO' -Tenant $TenantKey

        Format-HUExcelWorkbook -WorkbookPath $reportPath `
            -PrimaryKeyColumn 'DisplayName' `
            -ConditionalColumns @('Category', 'AccountStatus', 'HasLicense', 'Rolle')

        # --- Column Grouping ---
        Set-HUExcelColumnGrouping -WorkbookPath $reportPath `
            -GroupDefinitions @(
                @{ Title = 'BENUTZER';    Columns = @('DisplayName', 'UPN', 'Rolle', 'Klasse', 'AccountStatus', 'UserType') }
                @{ Title = 'DETAILS';     Columns = @('CreatedDate', 'AccountAge') }
                @{ Title = 'AKTIVITAET';  Columns = @('LastSignIn', 'DaysSinceSignIn', 'LastNonInteractive', 'Category') }
                @{ Title = 'LIZENZEN';    Columns = @('HasLicense', 'LicenseCount', 'Licenses') }
            )

        # --- Dashboard ---
        $dashMetrics = [ordered]@{
            "User gesamt (@$primaryDomain)" = $userCount
            'Aktiv'                          = $activeCount
            'Inaktiv 3M'                     = $inactive3MCount
            'Inaktiv 6M'                     = $inactive6MCount
            'Inaktiv 12M+'                   = $inactive12MCount
            'Nie angemeldet'                 = $neverSignedIn
            'Deaktivierte Accounts'          = $disabledCount
            'Lizenziert aber inaktiv'        = $licensedInactiveCount
        }

        $sheetLinks = @(
            @{ SheetName = 'All-Users';         RowCount = $userCount;                    Description = "Alle @$primaryDomain User" }
            @{ SheetName = 'Inactive-3M';       RowCount = $inactive3MList.Count;         Description = 'Inaktiv seit 3 Monaten' }
            @{ SheetName = 'Inactive-6M';       RowCount = $inactive6MList.Count;         Description = 'Inaktiv seit 6 Monaten' }
            @{ SheetName = 'Inactive-12M+';     RowCount = $inactive12MList.Count;        Description = 'Inaktiv seit 12+ Monaten' }
            @{ SheetName = 'Licensed-Inactive';  RowCount = $licensedInactiveList.Count;  Description = 'Lizenziert aber inaktiv' }
            @{ SheetName = 'Never-SignedIn';     RowCount = $neverSignedInList.Count;     Description = 'Nie angemeldet' }
        )

        Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey `
            -ReportTitle "Inaktive User (@$primaryDomain)" -Metrics $dashMetrics -SheetDataSources $sheetLinks

        Write-HULog -Message "Report gespeichert: $reportPath" -Level 'OK' -Tenant $TenantKey
    }
    catch {
        $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
        Write-HULog -Message "Excel-Erstellung fehlgeschlagen: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }

    # ================================================================
    # 9. OPEN REPORT
    # ================================================================

    if (Test-Path $reportPath) {
        Write-HULog -Message 'Oeffne Report in Excel ...' -Level 'INFO' -Tenant $TenantKey
        try { Start-Process -FilePath $reportPath }
        catch { Write-HULog -Message "Automatisches Oeffnen fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
    }

    # ================================================================
    # 10. FINAL RESULT
    # ================================================================

    Write-HULog -Message "Report inaktive User abgeschlossen: $userCount User, $licensedInactiveCount lizenziert+inaktiv" -Level 'OK' -Tenant $TenantKey

    return [PSCustomObject]@{
        Success              = $true
        ReportPath           = $reportPath
        TenantKey            = $TenantKey
        TotalUsers           = $userCount
        ActiveCount          = $activeCount
        Inactive3MCount      = $inactive3MCount
        Inactive6MCount      = $inactive6MCount
        Inactive12MCount     = $inactive12MCount
        NeverSignedInCount   = $neverSignedIn
        DisabledCount        = $disabledCount
        LicensedInactiveCount = $licensedInactiveCount
    }
}
