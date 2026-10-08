<#
.SYNOPSIS
    Microsoft-365-Lizenzen: Auslastung und Zuweisung

.DESCRIPTION
    Zeigt alle verfuegbaren SKUs mit Auslastung (consumed/enabled),
    listet User mit/ohne Lizenz, identifiziert Mehrfach-Lizenzen.
    Sheets: Dashboard, SKU-Overview, Licensed-Users, Unlicensed-Users, Multi-Licensed.

.REQUIRED_PERMISSIONS
    Organization.Read.All
    User.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    User

.TARGETS
    []

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $false

.RUNTIME
    PS5

.EXAMPLE
    . .\User-LicenseOverviewReport.ps1
    Invoke-LicenseOverviewReport -TenantKey "Schule-1" -Token $token
#>

function Invoke-LicenseOverviewReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$DryRun
    )

        Write-HULog -Message "Starte Lizenz-Uebersichtsbericht fuer Tenant: $TenantKey" -Level 'INFO' -Tenant $TenantKey

        $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $projectRoot = (Get-Item $scriptRoot).Parent.Parent.FullName
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"

        if (-not (Test-Path $reportFolder)) {
            New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
        }

        $reportBase = "License-Report_$TenantKey"

        # Permissions-Check
        try {
            $requiredPerms = @('Organization.Read.All', 'User.Read.All')
            foreach ($perm in $requiredPerms) {
                if (-not (Test-GraphPermission -Token $Token -Permission $perm)) {
                    Write-HULog -Message "Berechtigung fehlt: $perm" -Level 'ERROR' -Tenant $TenantKey
                    return
                }
            }
        }
        catch {
            Write-HULog -Message "Fehler bei Berechtigungspruefung: $($_.Exception.Message) (Zeile: $($_.InvocationInfo.ScriptLineNumber))" -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = 'Berechtigungspruefung fehlgeschlagen' }
        }

        Write-HULog -Message 'Berechtigungen OK' -Level 'OK' -Tenant $TenantKey

        try {
            # 1. Fetch subscribedSkus
            Write-HULog -Message "Lade SKU-Daten ..." -Level 'INFO' -Tenant $TenantKey
            $skuResponse = Invoke-GraphRequestWithRetry -Token $Token -Endpoint '/subscribedSkus' -TenantKey $TenantKey -Settings (Get-Settings)

            if (-not $skuResponse -or -not $skuResponse.value) {
                Write-HULog -Message "Keine SKU-Daten verfuegbar" -Level 'WARN' -Tenant $TenantKey
                $skuList = @()
            }
            else {
                $skuList = $skuResponse.value
            }

            # 2. Build SKU-ID mapping
            $skuIdMap = @{}
            foreach ($sku in $skuList) {
                $skuIdMap[$sku.skuId] = $sku.skuPartNumber
            }

            # 3. Build SKU Overview Sheet
            Write-HULog -Message "Verarbeite SKU-Uebersicht ($(($skuList | Measure-Object).Count) SKUs) ..." -Level 'INFO' -Tenant $TenantKey
            $skuOverview = @()

            foreach ($sku in $skuList) {
                $enabled = if ($sku.prepaidUnits.enabled) { [int]$sku.prepaidUnits.enabled } else { 0 }
                $consumed = if ($sku.consumedUnits) { [int]$sku.consumedUnits } else { 0 }
                $available = $enabled - $consumed

                $usagePercent = if ($enabled -gt 0) {
                    [math]::Round(($consumed / $enabled) * 100, 1)
                }
                else {
                    0
                }

                $suspended = if ($sku.prepaidUnits.suspended) { [int]$sku.prepaidUnits.suspended } else { 0 }
                $warning = if ($sku.prepaidUnits.warning) { [int]$sku.prepaidUnits.warning } else { 0 }

                $status = if ($sku.capabilityStatus) { $sku.capabilityStatus } else { 'Unknown' }

                $skuOverview += [PSCustomObject]@{
                    SKU          = $sku.skuPartNumber
                    Status       = $status
                    Enabled      = $enabled
                    Consumed     = $consumed
                    Available    = $available
                    UsagePercent = $usagePercent
                    Suspended    = $suspended
                    Warning      = $warning
                }
            }

            # 4. Fetch all users with license info
            Write-HULog -Message "Lade User-Daten ..." -Level 'INFO' -Tenant $TenantKey
            $userResponse = Invoke-GraphRequestAll -Token $Token `
                -Endpoint "/users?`$select=displayName,userPrincipalName,assignedLicenses,accountEnabled,userType" `
                -TenantKey $TenantKey -Settings (Get-Settings)

            if (-not $userResponse) {
                Write-HULog -Message "Keine User-Daten verfuegbar" -Level 'WARN' -Tenant $TenantKey
                $allUsers = @()
            }
            else {
                $allUsers = $userResponse
            }

            # 5. Build User License Data
            Write-HULog -Message "Verarbeite User-Lizenzdaten ($(($allUsers | Measure-Object).Count) User) ..." -Level 'INFO' -Tenant $TenantKey
            $licensedUsers = @()
            $unlicensedUsers = @()
            $multiLicensedUsers = @()

            foreach ($user in $allUsers) {
                $displayName = if ($user.displayName) { $user.displayName } else { '' }
                $upn = if ($user.userPrincipalName) { $user.userPrincipalName } else { '' }
                $accountEnabled = if ($user.accountEnabled -eq $true) { 'Ja' } else { 'Nein' }
                $userType = if ($user.userType) { $user.userType } else { 'Member' }

                $licenseCount = 0
                $licenseNames = @()

                if ($user.assignedLicenses -and $user.assignedLicenses.Count -gt 0) {
                    foreach ($license in $user.assignedLicenses) {
                        $skuId = $license.skuId
                        if ($skuIdMap.ContainsKey($skuId)) {
                            $licenseNames += $skuIdMap[$skuId]
                            $licenseCount++
                        }
                    }
                }

                $licensesStr = if ($licenseNames.Count -gt 0) { [string]::Join(', ', $licenseNames) } else { '' }

                $userObj = [PSCustomObject]@{
                    DisplayName     = $displayName
                    UPN             = $upn
                    AccountEnabled  = $accountEnabled
                    UserType        = $userType
                    LicenseCount    = $licenseCount
                    Licenses        = $licensesStr
                }

                if ($licenseCount -eq 0) {
                    if ($user.accountEnabled -eq $true) {
                        $unlicensedUsers += $userObj
                    }
                }
                elseif ($licenseCount -gt 1) {
                    $multiLicensedUsers += $userObj
                    $licensedUsers += $userObj
                }
                else {
                    $licensedUsers += $userObj
                }
            }

            # 6. Calculate Dashboard Metrics
            $totalSKUs = ($skuOverview | Measure-Object).Count
            $totalEnabled = ($skuOverview | Measure-Object -Property Enabled -Sum).Sum
            $totalConsumed = ($skuOverview | Measure-Object -Property Consumed -Sum).Sum
            $overallUsagePercent = if ($totalEnabled -gt 0) {
                [math]::Round(($totalConsumed / $totalEnabled) * 100, 1)
            }
            else {
                0
            }
            $totalUnlicensed = ($unlicensedUsers | Measure-Object).Count
            $totalMultiLicensed = ($multiLicensedUsers | Measure-Object).Count

            $dashboardMetrics = [PSCustomObject]@{
                'SKUs gesamt'           = $totalSKUs
                'Lizenzen gesamt'       = $totalEnabled
                'Verbrauchte Lizenzen'  = $totalConsumed
                'Auslastung (%)'        = "$overallUsagePercent%"
                'Unlizenzierte User'    = $totalUnlicensed
                'Mehrfach-lizenziert'   = $totalMultiLicensed
            }

            # 7. DRY-RUN CHECK
            if ($DryRun) {
                Write-HULog -Message "DRY-RUN: $totalSKUs SKUs, $totalUnlicensed unlizenziert. Kein Report." -Level 'WARN' -Tenant $TenantKey
                return [PSCustomObject]@{
                    Success = $true; DryRun = $true
                    SKUsTotal = $totalSKUs; UnlicensedUsers = $totalUnlicensed
                }
            }

            # 8. Export to Excel
            Write-HULog -Message 'Exportiere Excel-Report ...' -Level 'INFO' -Tenant $TenantKey

            $version = 1
            do {
                $reportFileName = "${reportBase}_v${version}.xlsx"
                $excelPath = Join-Path $reportFolder $reportFileName
                $version++
            } while (Test-Path $excelPath)

            try {
                # --- Sheet 1: SKU-Overview ---
                if ($skuOverview.Count -gt 0) {
                    $skuOverview | Export-Excel -Path $excelPath -WorksheetName 'SKU-Overview' `
                        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *
                } else {
                    @([PSCustomObject]@{ Info = 'Keine SKU-Daten gefunden.' }) |
                        Export-Excel -Path $excelPath -WorksheetName 'SKU-Overview'
                }

                # --- Sheet 2: Licensed-Users ---
                if ($licensedUsers.Count -gt 0) {
                    $licensedUsers | Export-Excel -Path $excelPath -WorksheetName 'Licensed-Users' `
                        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
                } else {
                    @([PSCustomObject]@{ Info = 'Keine lizenzierten User gefunden.' }) |
                        Export-Excel -Path $excelPath -WorksheetName 'Licensed-Users' -Append
                }

                # --- Sheet 3: Unlicensed-Users ---
                if ($unlicensedUsers.Count -gt 0) {
                    $unlicensedUsers | Export-Excel -Path $excelPath -WorksheetName 'Unlicensed-Users' `
                        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
                } else {
                    @([PSCustomObject]@{ Info = 'Keine unlizenzierten User gefunden.' }) |
                        Export-Excel -Path $excelPath -WorksheetName 'Unlicensed-Users' -Append
                }

                # --- Sheet 4: Multi-Licensed ---
                if ($multiLicensedUsers.Count -gt 0) {
                    $multiLicensedUsers | Export-Excel -Path $excelPath -WorksheetName 'Multi-Licensed' `
                        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
                } else {
                    @([PSCustomObject]@{ Info = 'Keine mehrfach-lizenzierten User.' }) |
                        Export-Excel -Path $excelPath -WorksheetName 'Multi-Licensed' -Append
                }

                # --- Standard-Formatierung ---
                Write-HULog -Message 'Formatiere Arbeitsmappe ...' -Level 'INFO' -Tenant $TenantKey

                Format-HUExcelWorkbook -WorkbookPath $excelPath `
                    -PrimaryKeyColumn 'SKU' `
                    -ConditionalColumns @('Status', 'UsagePercent', 'Available')

                # --- Column Grouping ---
                Set-HUExcelColumnGrouping -WorkbookPath $excelPath `
                    -GroupDefinitions @(
                        @{ Title = 'LIZENZ';     Columns = @('SKU', 'Status') }
                        @{ Title = 'AUSLASTUNG'; Columns = @('Enabled', 'Consumed', 'Available', 'UsagePercent') }
                        @{ Title = 'SONSTIG';    Columns = @('Suspended', 'Warning') }
                    )

                # --- Dashboard ---
                $dashMetrics = [ordered]@{
                    'SKUs gesamt'        = $totalSKUs
                    'Lizenzen gesamt'    = $totalEnabled
                    'Verbraucht'         = $totalConsumed
                    'Auslastung'         = "$overallUsagePercent%"
                    'Unlizenziert'       = $totalUnlicensed
                    'Mehrfach-lizenziert'= $totalMultiLicensed
                }

                $sheetLinks = @(
                    @{ SheetName = 'SKU-Overview';     RowCount = $skuOverview.Count;        Description = 'Alle SKUs' }
                    @{ SheetName = 'Licensed-Users';   RowCount = $licensedUsers.Count;      Description = 'Lizenzierte User' }
                    @{ SheetName = 'Unlicensed-Users'; RowCount = $unlicensedUsers.Count;    Description = 'Unlizenzierte User' }
                    @{ SheetName = 'Multi-Licensed';   RowCount = $multiLicensedUsers.Count; Description = 'Mehrfach-lizenziert' }
                )

                Add-HUExcelDashboard -WorkbookPath $excelPath -TenantKey $TenantKey `
                    -ReportTitle 'Lizenz-Uebersicht' -Metrics $dashMetrics -SheetDataSources $sheetLinks

                Write-HULog -Message "Report gespeichert: $excelPath" -Level 'OK' -Tenant $TenantKey
            }
            catch {
                $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
                $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
                Write-HULog -Message "Excel-Erstellung fehlgeschlagen: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
                return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
            }

            # --- OPEN REPORT ---
            if (Test-Path $excelPath) {
                try { Start-Process -FilePath $excelPath }
                catch { Write-HULog -Message "Automatisches Oeffnen fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
            }

            return [PSCustomObject]@{
                Success             = $true
                ReportPath          = $excelPath
                SKUsTotal           = $totalSKUs
                TotalEnabled        = $totalEnabled
                TotalConsumed       = $totalConsumed
                OverallUsagePercent = $overallUsagePercent
                UnlicensedUsers     = $totalUnlicensed
                MultiLicensedUsers  = $totalMultiLicensed
                LicensedUsersCount  = $licensedUsers.Count
            }
        }
        catch {
            $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
            $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
            Write-HULog -Message "Fehler bei Lizenz-Report: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
        }
}
