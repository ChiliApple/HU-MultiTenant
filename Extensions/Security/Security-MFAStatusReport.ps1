<#
.SYNOPSIS
    MFA-Registrierungsstatus aller Benutzer auswerten

.DESCRIPTION
    Wertet den MFA-Status aller Benutzer im Tenant aus.
    Zeigt registrierte Methoden, MFA-Faehigkeit, SSPR-Status,
    Passwordless-Faehigkeit und Admin-Status.
    Sheets: Dashboard, All-Users, Not-MFA-Registered, Admins, Methods-Summary.

.REQUIRED_PERMISSIONS
    AuditLog.Read.All
    User.Read.All

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

.RUNTIME
    PS5

.EXAMPLE
    . .\Security-MFAStatusReport.ps1
    Invoke-MFAStatusReport -TenantKey "Schule-1" -Token $token
#>

function Invoke-MFAStatusReport {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TenantKey,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$Settings = @{},

        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    $functionName = "Invoke-MFAStatusReport"
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $projectRoot = (Get-Item $scriptRoot).Parent.Parent.FullName

    try {
        Write-HULog -Level 'INFO' -Message "[$functionName] Starte MFA-Statusbericht fuer Tenant: $TenantKey" -Tenant $TenantKey

        # Abrufen der Authentifizierungsmethoden-Registrierungsdetails
        Write-HULog -Level 'INFO' -Message "[$functionName] Rufe AuthenticationMethods-Report ab ..." -Tenant $TenantKey

        $allUsers = [System.Collections.ArrayList]::new()
        $endpoint = '/reports/authenticationMethods/userRegistrationDetails'
        $pageCount = 0

        do {
            $pageCount++
            Write-HULog -Level 'DEBUG' -Message "[$functionName] Seite $pageCount wird verarbeitet ..." -Tenant $TenantKey

            $response = Invoke-GraphRequestWithRetry -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings

            if ($response -and $response.value) {
                foreach ($item in $response.value) {
                    [void]$allUsers.Add($item)
                }
                Write-HULog -Level 'DEBUG' -Message "[$functionName] $($response.value.Count) Benutzer auf Seite $pageCount hinzugefuegt (insgesamt: $($allUsers.Count))" -Tenant $TenantKey
            }

            $endpoint = if ($response.'@odata.nextLink') {
                $response.'@odata.nextLink' -replace 'https://graph.microsoft.com/v1.0', ''
            }
            else {
                $null
            }
        } while ($endpoint)

        Write-HULog -Level 'INFO' -Message "[$functionName] Insgesamt $($allUsers.Count) Benutzer abgerufen" -Tenant $TenantKey

        # Angereicherte Objekte bauen
        $enrichedUsers = @()
        foreach ($user in $allUsers) {
            $enrichedUsers += [PSCustomObject]@{
                DisplayName        = if ($user.userDisplayName) { $user.userDisplayName } else { '' }
                UPN                = if ($user.userPrincipalName) { $user.userPrincipalName } else { '' }
                UserType           = if ($user.userType) { $user.userType } else { 'member' }
                IsAdmin            = if ($user.isAdmin -eq $true) { 'Ja' } else { 'Nein' }
                MfaRegistered      = if ($user.isMfaRegistered -eq $true) { 'Ja' } else { 'Nein' }
                MfaCapable         = if ($user.isMfaCapable -eq $true) { 'Ja' } else { 'Nein' }
                DefaultMfaMethod   = if ($user.defaultMfaMethod) { $user.defaultMfaMethod } else { 'none' }
                MethodsRegistered  = if ($user.methodsRegistered) { ($user.methodsRegistered -join ', ') } else { '' }
                PasswordlessCapable = if ($user.isPasswordlessCapable -eq $true) { 'Ja' } else { 'Nein' }
                SsprRegistered     = if ($user.isSsprRegistered -eq $true) { 'Ja' } else { 'Nein' }
                SsprCapable        = if ($user.isSsprCapable -eq $true) { 'Ja' } else { 'Nein' }
                SsprEnabled        = if ($user.isSsprEnabled -eq $true) { 'Ja' } else { 'Nein' }
            }
        }

        Write-HULog -Level 'INFO' -Message "[$functionName] $($enrichedUsers.Count) Benutzer angereichert" -Tenant $TenantKey

        # Gefilterte Listen erstellen
        $notMfaRegistered = @($enrichedUsers | Where-Object { $_.MfaRegistered -eq 'Nein' })
        $admins = @($enrichedUsers | Where-Object { $_.IsAdmin -eq 'Ja' })

        Write-HULog -Level 'INFO' -Message "[$functionName] $($notMfaRegistered.Count) Benutzer ohne MFA-Registrierung | $($admins.Count) Administratoren" -Tenant $TenantKey

        # Methodenzusammenfassung
        $methodCounts = @{}
        foreach ($u in $enrichedUsers) {
            if ($u.MethodsRegistered) {
                $methods = $u.MethodsRegistered -split ', '
                foreach ($m in $methods) {
                    $trimmed = $m.Trim()
                    if ($trimmed -ne '') {
                        if ($methodCounts.ContainsKey($trimmed)) {
                            $methodCounts[$trimmed]++
                        }
                        else {
                            $methodCounts[$trimmed] = 1
                        }
                    }
                }
            }
        }

        $methodSummary = @()
        $totalUsers = if ($enrichedUsers.Count -gt 0) { $enrichedUsers.Count } else { 1 }

        foreach ($methodKey in ($methodCounts.Keys | Sort-Object)) {
            $methodSummary += [PSCustomObject]@{
                Method     = $methodKey
                Count      = $methodCounts[$methodKey]
                Percentage = [math]::Round(($methodCounts[$methodKey] / $totalUsers) * 100, 1)
            }
        }

        Write-HULog -Level 'INFO' -Message "[$functionName] $($methodSummary.Count) eindeutige MFA-Methoden gefunden" -Tenant $TenantKey

        # Berichte Zusammenfassung
        $mfaRegisteredCount = @($enrichedUsers | Where-Object { $_.MfaRegistered -eq 'Ja' }).Count
        $mfaRate = if ($enrichedUsers.Count -gt 0) { [math]::Round(($mfaRegisteredCount / $enrichedUsers.Count) * 100, 1) } else { 0 }
        $passwordlessCapableCount = @($enrichedUsers | Where-Object { $_.PasswordlessCapable -eq 'Ja' }).Count

        # Bereite Dashboard-Daten vor
        $dashboardData = [PSCustomObject]@{
            TenantKey              = $TenantKey
            ReportDate             = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
            TotalUsers             = $enrichedUsers.Count
            MfaRegistered          = $mfaRegisteredCount
            MfaNotRegistered       = $notMfaRegistered.Count
            MfaRegistrationRate    = "$mfaRate%"
            AdminCount             = $admins.Count
            AdminsMfaRegistered    = @($admins | Where-Object { $_.MfaRegistered -eq 'Ja' }).Count
            PasswordlessCapable    = $passwordlessCapableCount
            UniqueMethodsCount     = $methodSummary.Count
        }

        # Excel-Export vorbereiten
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"

        if (-not (Test-Path $reportFolder)) {
            [void](New-Item -Path $reportFolder -ItemType Directory -Force)
            Write-HULog -Level 'INFO' -Message "[$functionName] Berichtordner erstellt: $reportFolder" -Tenant $TenantKey
        }

        $reportBase = "MFA-Status-Report_$TenantKey"
        $excelFile = Join-Path $reportFolder "$reportBase.xlsx"

        if ($DryRun) {
            Write-HULog -Level 'WARN' -Message "[$functionName] DRY-RUN: $($enrichedUsers.Count) Benutzer, $($notMfaRegistered.Count) ohne MFA. Kein Report." -Tenant $TenantKey
            return [PSCustomObject]@{
                Success = $true; DryRun = $true
                TotalUsers = $enrichedUsers.Count; MfaNotRegistered = $notMfaRegistered.Count
            }
        }

        # --- EXCEL EXPORT ---
        Write-HULog -Level 'INFO' -Message "[$functionName] Exportiere nach Excel ..." -Tenant $TenantKey

        if (-not (Test-Path $reportFolder)) {
            New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null
        }

        $version = 1
        do {
            $reportFileName = "${reportBase}_v${version}.xlsx"
            $excelFile = Join-Path $reportFolder $reportFileName
            $version++
        } while (Test-Path $excelFile)

        try {
            # --- Sheet 1: All-Users ---
            if ($enrichedUsers.Count -gt 0) {
                $enrichedUsers | Export-Excel -Path $excelFile -WorksheetName 'All-Users' `
                    -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *
            } else {
                @([PSCustomObject]@{ Info = 'Keine Benutzer gefunden.' }) |
                    Export-Excel -Path $excelFile -WorksheetName 'All-Users'
            }

            # --- Sheet 2: Not-MFA-Registered ---
            if ($notMfaRegistered.Count -gt 0) {
                $notMfaRegistered | Export-Excel -Path $excelFile -WorksheetName 'Not-MFA-Registered' `
                    -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
            } else {
                @([PSCustomObject]@{ Info = 'Alle Benutzer haben MFA registriert.' }) |
                    Export-Excel -Path $excelFile -WorksheetName 'Not-MFA-Registered' -Append
            }

            # --- Sheet 3: Admins ---
            if ($admins.Count -gt 0) {
                $admins | Export-Excel -Path $excelFile -WorksheetName 'Admins' `
                    -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
            } else {
                @([PSCustomObject]@{ Info = 'Keine Administratoren gefunden.' }) |
                    Export-Excel -Path $excelFile -WorksheetName 'Admins' -Append
            }

            # --- Sheet 4: Methods-Summary ---
            if ($methodSummary.Count -gt 0) {
                $methodSummary | Export-Excel -Path $excelFile -WorksheetName 'Methods-Summary' `
                    -AutoSize -FreezeTopRow -BoldTopRow -Append
            } else {
                @([PSCustomObject]@{ Info = 'Keine MFA-Methoden gefunden.' }) |
                    Export-Excel -Path $excelFile -WorksheetName 'Methods-Summary' -Append
            }

            # --- Standard-Formatierung ---
            Write-HULog -Level 'INFO' -Message "[$functionName] Formatiere Arbeitsmappe ..." -Tenant $TenantKey

            Format-HUExcelWorkbook -WorkbookPath $excelFile `
                -PrimaryKeyColumn 'DisplayName' `
                -ConditionalColumns @('MfaRegistered', 'MfaCapable', 'IsAdmin', 'PasswordlessCapable')

            # --- Dashboard ---
            $dashMetrics = [ordered]@{
                'Gesamt Benutzer'        = $enrichedUsers.Count
                'MFA registriert'        = $mfaRegisteredCount
                'MFA nicht registriert'  = $notMfaRegistered.Count
                'MFA-Rate'               = "$mfaRate%"
                'Administratoren'        = $admins.Count
                'Passwortlos-faehig'    = $passwordlessCapableCount
            }

            $sheetLinks = @(
                @{ SheetName = 'All-Users';           RowCount = $enrichedUsers.Count;      Description = 'Alle Benutzer' }
                @{ SheetName = 'Not-MFA-Registered';  RowCount = $notMfaRegistered.Count;   Description = 'Ohne MFA-Registrierung' }
                @{ SheetName = 'Admins';              RowCount = $admins.Count;              Description = 'Administratoren' }
                @{ SheetName = 'Methods-Summary';     RowCount = $methodSummary.Count;       Description = 'MFA-Methoden Uebersicht' }
            )

            Add-HUExcelDashboard -WorkbookPath $excelFile -TenantKey $TenantKey `
                -ReportTitle 'MFA-Status-Report' -Metrics $dashMetrics -SheetDataSources $sheetLinks

            Write-HULog -Level 'OK' -Message "[$functionName] Report erstellt: $excelFile" -Tenant $TenantKey
        }
        catch {
            $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
            $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
            Write-HULog -Level 'ERROR' -Message "[$functionName] Excel-Erstellung fehlgeschlagen: $($_.Exception.Message)${errLine}${errCmd}" -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
        }

        # --- OPEN REPORT ---
        if (Test-Path $excelFile) {
            try { Start-Process -FilePath $excelFile }
            catch { Write-HULog -Level 'WARN' -Message "[$functionName] Automatisches Oeffnen fehlgeschlagen: $($_.Exception.Message)" -Tenant $TenantKey }
        }

        return [PSCustomObject]@{
            Success             = $true
            ReportPath          = $excelFile
            TotalUsers          = $enrichedUsers.Count
            MfaRegistered       = $mfaRegisteredCount
            MfaNotRegistered    = $notMfaRegistered.Count
            MfaRegistrationRate = $mfaRate
            AdminCount          = $admins.Count
            PasswordlessCapable = $passwordlessCapableCount
        }
    }
    catch {
        $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        $errCmd  = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
        Write-HULog -Level 'ERROR' -Message "[$functionName] $($_.Exception.Message)${errLine}${errCmd}" -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
