<#
.SYNOPSIS
    Enterprise-App-Inventur (Service Principals) - Bestand, Risiko und Aufraeumen

.DESCRIPTION
    Inventarisiert alle Enterprise Applications (Service Principals) eines Tenants,
    klassifiziert sie nach Herkunft (Microsoft / Eigen / Fremd), loest delegierte und
    Application-Permissions auf, ermittelt Besitzer und Sign-in-Aktivitaet und markiert
    kritische Berechtigungen, moegliche Privilege-Escalation, Duplikate (mehrfach angelegte
    Apps gleichen Namens) sowie inaktive Apps ohne Besitzer.

    Ausgabe: Excel-Report mit Dashboard und Themen-Sheets plus CSV je Tenant im Reports-Ordner.

    STUFE 2 (Schreiboperationen, Standard = Simulation/DryRun):
    Ueber den Parameter 'Aktion' koennen ausgewaehlte Apps deaktiviert, deren delegierte
    Consents widerrufen oder Service Principals geloescht werden. Ziel-Apps werden ueber die
    Objekt-ID(s) im Parameter 'ZielObjektId' angegeben (Komma-getrennt). Eine harte Schutzliste
    verhindert Aktionen gegen Microsoft-Apps, Directory-Sync, Intune, Windows Admin Center sowie
    Apps mit SSO/Provisionierung (Next-Exam, Uniflow, YSoft, WebUntis, lms.at, PS-Admin-Script).
    Eine Schreibaktion wird nur LIVE ausgefuehrt, wenn zusaetzlich das Feld 'LoeschBestaetigung'
    exakt den Tenant-Key enthaelt UND DryRun aus ist - andernfalls wird nur simuliert und
    protokolliert.

    Zusaetzlich benoetigte Permissions je Aktion (werden zur Laufzeit geprueft, damit die reine
    Inventur nicht an fehlenden Schreib-Scopes scheitert):
      Deaktivieren / SP-Loeschen : Application.ReadWrite.All
      Consent-Widerruf           : DelegatedPermissionGrant.ReadWrite.All (oder Directory.ReadWrite.All)

.REQUIRED_PERMISSIONS
    Application.Read.All
    Directory.Read.All
    AuditLog.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Security

.TARGETS
    []

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $true

.RUNTIME
    PS5

.MODE
    ReadWrite

.PARAM
    Aktion|choice|Aktion|Inventur|Inventur;Deaktivieren;Consent-Widerruf;SP-Loeschen
    ZielObjektId|string|Ziel Objekt-ID(s) fuer Schreibaktion (Komma-getrennt)|
    InaktivTage|int|Inaktiv-Schwelle in Tagen (Report-Markierung)|90
    SignInReport|choice|Sign-in-Report abrufen|Ja|Ja;Nein
    BesitzerAbrufen|choice|Besitzer je App abrufen|Ja|Ja;Nein
    LoeschBestaetigung|string|LIVE-Bestaetigung fuer Schreibaktion (Tenant-Key eingeben)|

.EXAMPLE
    . .\Security-EnterpriseAppInventory.ps1
    Invoke-EnterpriseAppInventory -TenantKey "Schule-1" -Token $token

.EXAMPLE
    Invoke-EnterpriseAppInventory -TenantKey "Schule-1" -Token $token -Aktion "Deaktivieren" -ZielObjektId "0000-...,1111-..." -LoeschBestaetigung "Schule-1"
#>

function Invoke-EnterpriseAppInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [ValidateSet('Inventur', 'Deaktivieren', 'Consent-Widerruf', 'SP-Loeschen')]
        [string]$Aktion = 'Inventur',

        [string]$ZielObjektId = '',

        [int]$InaktivTage = 90,

        [ValidateSet('Ja', 'Nein')]
        [string]$SignInReport = 'Ja',

        [ValidateSet('Ja', 'Nein')]
        [string]$BesitzerAbrufen = 'Ja',

        [string]$LoeschBestaetigung = '',

        [switch]$WhatIf
    )

    $fn = 'Invoke-EnterpriseAppInventory'
    $settings = Get-Settings

    # Microsoft-First-Party Tenant IDs (Apps, die Microsoft selbst gehoeren)
    $msTenants = @(
        'f8cdef31-a31e-4b4a-93e4-5f571e91255a',
        '72f988bf-86f1-41af-91ab-2d7cd011db47'
    )

    # App-Permissions mit besonderem Risiko
    $highRisk = @(
        'Mail.Read', 'Mail.ReadWrite', 'Mail.Send', 'MailboxSettings.ReadWrite',
        'Files.Read.All', 'Files.ReadWrite.All', 'Sites.Read.All', 'Sites.ReadWrite.All',
        'Directory.Read.All', 'Directory.ReadWrite.All', 'User.ReadWrite.All',
        'Group.ReadWrite.All', 'RoleManagement.ReadWrite.Directory',
        'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All',
        'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All'
    )

    # Harte Schutzliste (Name-Muster, case-insensitive) - niemals loeschen/deaktivieren
    $protectedPatterns = @(
        'Directory Synchronization', 'On-Premises Directory Synchronization',
        'Azure AD Connect', 'Entra Connect', 'AAD Connect', 'ADSync',
        'Microsoft Intune', 'Intune', 'Windows Admin Center', 'WindowsAdminCenter',
        'PS-Admin-Script', 'Next-?Exam', 'NextExam', 'Uniflow', 'YSoft', 'Safe ?Q',
        'WebUntis', 'lms\.at', 'Microsoft', 'Office 365', 'Graph',
        'Virtualschool-ServerApp', 'ServerApp-'
    )

    # Harte AppId-Schutzliste - diese Apps NIE anfassen (eigene Admin-Apps je Tenant)
    #   automatisch: die App-Registrierungen ALLER Tenants aus settings.json (das Tool selbst)
    #   zusaetzlich je Tenant: "protectedAppIds": ["<AppId>", ...] in settings.json
    $neverTouchAppIds = @()
    foreach ($t in @($settings.tenants)) {
        if ($t.PSObject.Properties['appId'] -and "$($t.appId)" -match '^[0-9a-fA-F-]{36}$') { $neverTouchAppIds += "$($t.appId)".ToLower() }
        if ($t.PSObject.Properties['protectedAppIds']) { foreach ($a in @($t.protectedAppIds)) { if ("$a".Trim()) { $neverTouchAppIds += "$a".Trim().ToLower() } } }
    }

    # ---- interner Paginator mit Fehlererkennung (auch fuer beta-URLs) ----
    function Get-HUPaged {
        param(
            [string]$Ep,
            [string]$Tk,
            $St,
            [ref]$OkRef,
            $ErrRef = $null
        )
        $items = [System.Collections.ArrayList]::new()
        $cur = $Ep
        $OkRef.Value = $true
        $guard = 0
        while ($cur -and $guard -lt 200) {
            $guard++
            $resp = Invoke-GraphRequestWithRetry -Token $Token -Endpoint $cur -TenantKey $Tk -Settings $St
            if ($resp.PSObject.Properties.Name -contains 'IsError' -and $resp.IsError) {
                $OkRef.Value = $false
                if ($ErrRef) { $ErrRef.Value = "HTTP $($resp.StatusCode): $($resp.ErrorMessage)" }
                break
            }
            if ($resp.value) {
                foreach ($it in $resp.value) { [void]$items.Add($it) }
            }
            $cur = $resp.'@odata.nextLink'
        }
        return @($items)
    }

    # ---- tid-Claim aus dem Token dekodieren (Fallback fuer eigene Tenant-GUID) ----
    function Get-TidFromToken {
        param([string]$Tok)
        try {
            $p = $Tok.Split('.')[1].Replace('-', '+').Replace('_', '/')
            while ($p.Length % 4) { $p += '=' }
            $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($p))
            return ($json | ConvertFrom-Json).tid
        } catch { return $null }
    }

    function Test-Protected {
        param([string]$Name, [string]$Herkunft, [string]$Sso, [string]$AppId)
        if ($AppId -and ($neverTouchAppIds -contains $AppId.ToLower())) { return 'AppId-Schutzliste' }
        if ($Herkunft -eq 'Microsoft') { return 'Microsoft-App' }
        if ($Sso -and $Sso -ne 'notSupported' -and $Sso -ne '') { return "SSO aktiv ($Sso)" }
        foreach ($p in $protectedPatterns) {
            if ($Name -match $p) { return "Namensmuster '$p'" }
        }
        return ''
    }

    try {
        Write-HULog -Message "[$fn] Start (Aktion=$Aktion) fuer $TenantKey" -Level 'INFO' -Tenant $TenantKey

        # ---- Pflicht-Permissions Lesezugriff ----
        foreach ($perm in @('Application.Read.All', 'Directory.Read.All')) {
            if (-not (Test-GraphPermission -Token $Token -Permission $perm)) {
                Write-HULog -Message "[$fn] Fehlende Permission: $perm" -Level 'ERROR' -Tenant $TenantKey
                return [PSCustomObject]@{ Success = $false; Error = "Berechtigung fehlt: $perm" }
            }
        }

        # Eigene Tenant-GUID fuer Owner-Abgleich - direkt aus Graph/Token (robust), Settings nur als Fallback
        $eigenerTenant = ''
        $org = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings -Endpoint '/organization'
        if (-not ($org.PSObject.Properties.Name -contains 'IsError' -and $org.IsError) -and $org.value) {
            $eigenerTenant = "$($org.value[0].id)"
        }
        if ([string]::IsNullOrWhiteSpace($eigenerTenant)) {
            $eigenerTenant = "$(Get-TidFromToken -Tok $Token)"
        }
        if ([string]::IsNullOrWhiteSpace($eigenerTenant) -and $settings -and $settings.tenants) {
            $matchT = $settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
            if ($matchT -and $matchT.tenantId) { $eigenerTenant = "$($matchT.tenantId)" }
        }
        if ([string]::IsNullOrWhiteSpace($eigenerTenant)) {
            Write-HULog -Message "[$fn] Eigene TenantId nicht ermittelbar - Eigen/Fremd-Trennung uebersprungen (alles Fremd)!" -Level 'WARN' -Tenant $TenantKey
        }
        else {
            Write-HULog -Message "[$fn] Eigene Tenant-GUID (Owner-Match): '$eigenerTenant'" -Level 'INFO' -Tenant $TenantKey
        }

        # ================================================================
        # SCHREIBAKTION (STUFE 2)
        # ================================================================
        if ($Aktion -ne 'Inventur') {

            $ids = @($ZielObjektId -split '[,\r\n;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if ($ids.Count -eq 0) {
                Write-HULog -Message "[$fn] Aktion '$Aktion' ohne ZielObjektId - nichts zu tun." -Level 'ERROR' -Tenant $TenantKey
                return [PSCustomObject]@{ Success = $false; Error = 'ZielObjektId fehlt' }
            }

            # benoetigte Schreib-Permission je Aktion pruefen
            $needPerm = if ($Aktion -eq 'Consent-Widerruf') { 'DelegatedPermissionGrant.ReadWrite.All' } else { 'Application.ReadWrite.All' }
            $havePerm = (Test-GraphPermission -Token $Token -Permission $needPerm)
            if (-not $havePerm -and $Aktion -eq 'Consent-Widerruf') {
                $havePerm = (Test-GraphPermission -Token $Token -Permission 'Directory.ReadWrite.All')
            }
            if (-not $havePerm) {
                Write-HULog -Message "[$fn] Schreib-Permission fehlt: $needPerm (in $TenantKey nicht consented?)" -Level 'ERROR' -Tenant $TenantKey
                return [PSCustomObject]@{ Success = $false; Error = "Schreib-Berechtigung fehlt: $needPerm" }
            }

            # LIVE nur wenn Bestaetigung == TenantKey UND kein DryRun
            $live = ((-not $WhatIf) -and ($LoeschBestaetigung -eq $TenantKey))
            if (-not $live) {
                Write-HULog -Message "[$fn] SIMULATION (DryRun-Default). LIVE erst mit LoeschBestaetigung='$TenantKey' und DryRun aus." -Level 'WARN' -Tenant $TenantKey
            }
            else {
                Write-HULog -Message "[$fn] LIVE-Modus aktiv - Aenderungen werden ausgefuehrt." -Level 'WARN' -Tenant $TenantKey
            }

            # Write-Logdatei vorbereiten
            $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
            $projectRoot = (Get-Item $scriptRoot).Parent.Parent.FullName
            $dateStamp = Get-Date -Format 'yyyy-MM-dd'
            $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"
            if (-not (Test-Path $reportFolder)) { New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null }
            $writeLog = Join-Path $reportFolder "EnterpriseApp-Writes_$TenantKey.log"

            $done = 0; $skipped = 0; $results = @()

            foreach ($oid in $ids) {
                # Ziel-SP laden
                $sp = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings `
                    -Endpoint "/servicePrincipals/$oid`?`$select=id,appId,displayName,appOwnerOrganizationId,accountEnabled,preferredSingleSignOnMode,tags"
                if ($sp.PSObject.Properties.Name -contains 'IsError' -and $sp.IsError) {
                    Write-HULog -Message "[$fn] Ziel $oid nicht ladbar: $($sp.ErrorMessage)" -Level 'ERROR' -Tenant $TenantKey
                    $skipped++; continue
                }

                $herkunft = if ($msTenants -contains $sp.appOwnerOrganizationId) { 'Microsoft' }
                    elseif ($sp.appOwnerOrganizationId -eq $eigenerTenant) { 'Eigen' } else { 'Fremd' }

                $blockReason = Test-Protected -Name $sp.displayName -Herkunft $herkunft -Sso $sp.preferredSingleSignOnMode -AppId $sp.appId
                if ($blockReason) {
                    Write-HULog -Message "[$fn] GESCHUETZT, uebersprungen: '$($sp.displayName)' -> $blockReason" -Level 'WARN' -Tenant $TenantKey
                    $skipped++
                    $results += [PSCustomObject]@{ App = $sp.displayName; ObjektId = $oid; Aktion = $Aktion; Ergebnis = "GESCHUETZT: $blockReason" }
                    continue
                }

                $verb = if ($live) { 'FUEHRE AUS' } else { 'WUERDE' }
                Write-HULog -Message "[$fn] $verb $Aktion : '$($sp.displayName)' ($oid)" -Level 'WARN' -Tenant $TenantKey
                $logLine = "{0};{1};{2};{3};{4};{5}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $TenantKey, $Aktion, $oid, $sp.displayName, $(if ($live) { 'LIVE' } else { 'SIMULATION' })

                $outcome = if ($live) { 'OK' } else { 'simuliert' }
                if ($live) {
                    try {
                        switch ($Aktion) {
                            'Deaktivieren' {
                                $note = "HU-Inventur: deaktiviert $dateStamp, Loeschung fruehestens $((Get-Date).AddDays(30).ToString('yyyy-MM-dd'))"
                                $body = @{ accountEnabled = $false; notes = $note }
                                $r = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings -Method 'PATCH' -Endpoint "/servicePrincipals/$oid" -Body $body
                                if ($r.PSObject.Properties.Name -contains 'IsError' -and $r.IsError) { throw $r.ErrorMessage }
                            }
                            'Consent-Widerruf' {
                                $okG = $true
                                $grants = Get-HUPaged -Ep "/oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)'" -Tk $TenantKey -St $settings -OkRef ([ref]$okG)
                                if (-not $okG) {
                                    # Fallback: alle Grants holen und clientseitig filtern
                                    $grants = Get-HUPaged -Ep "/oauth2PermissionGrants?`$top=999" -Tk $TenantKey -St $settings -OkRef ([ref]$okG) | Where-Object { $_.clientId -eq $sp.id }
                                }
                                $delCount = 0
                                foreach ($g in $grants) {
                                    $rd = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings -Method 'DELETE' -Endpoint "/oauth2PermissionGrants/$($g.id)"
                                    if (-not ($rd.PSObject.Properties.Name -contains 'IsError' -and $rd.IsError)) { $delCount++ }
                                }
                                $outcome = "OK ($delCount Grants entfernt)"
                            }
                            'SP-Loeschen' {
                                $r = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings -Method 'DELETE' -Endpoint "/servicePrincipals/$oid"
                                if ($r.PSObject.Properties.Name -contains 'IsError' -and $r.IsError) { throw $r.ErrorMessage }
                            }
                        }
                        $done++
                    }
                    catch {
                        $outcome = "FEHLER: $($_.Exception.Message)"
                        Write-HULog -Message "[$fn] Aktion fehlgeschlagen fuer $oid : $($_.Exception.Message)" -Level 'ERROR' -Tenant $TenantKey
                    }
                }
                else {
                    $done++
                }

                Add-Content -Path $writeLog -Value ("$logLine;$outcome") -Encoding UTF8
                $results += [PSCustomObject]@{ App = $sp.displayName; ObjektId = $oid; Aktion = $Aktion; Ergebnis = $outcome }
            }

            Write-HULog -Message "[$fn] Fertig. Verarbeitet=$done, Uebersprungen=$skipped, Log: $writeLog" -Level 'OK' -Tenant $TenantKey
            return [PSCustomObject]@{
                Success   = $true
                Aktion    = $Aktion
                Live      = $live
                Verarbeitet = $done
                Geschuetzt = $skipped
                LogPath   = $writeLog
                Details   = $results
            }
        }

        # ================================================================
        # INVENTUR (STUFE 1)
        # ================================================================

        # 1. Alle Service Principals
        Write-HULog -Message "[$fn] Lade Service Principals ..." -Level 'INFO' -Tenant $TenantKey
        $spSelect = 'id,appId,displayName,appOwnerOrganizationId,servicePrincipalType,accountEnabled,appRoleAssignmentRequired,createdDateTime,verifiedPublisher,signInAudience,preferredSingleSignOnMode'
        $okSp = $true
        $allSp = Get-HUPaged -Ep "/servicePrincipals?`$select=$spSelect&`$top=999" -Tk $TenantKey -St $settings -OkRef ([ref]$okSp)
        if (-not $okSp -and $allSp.Count -eq 0) {
            Write-HULog -Message "[$fn] Service Principals nicht lesbar." -Level 'ERROR' -Tenant $TenantKey
            return [PSCustomObject]@{ Success = $false; Error = 'Service Principals nicht lesbar' }
        }
        Write-HULog -Message "[$fn] Service Principals gesamt: $($allSp.Count)" -Level 'OK' -Tenant $TenantKey

        # 2. Delegated Consents (ein Aufruf, dann nach clientId gruppieren)
        $grantByClient = @{}
        $okGr = $true
        $grants = Get-HUPaged -Ep "/oauth2PermissionGrants?`$top=999" -Tk $TenantKey -St $settings -OkRef ([ref]$okGr)
        foreach ($g in $grants) {
            if (-not $grantByClient.ContainsKey($g.clientId)) { $grantByClient[$g.clientId] = @() }
            $grantByClient[$g.clientId] += $g
        }
        if (-not $okGr) { Write-HULog -Message "[$fn] oauth2PermissionGrants nur teilweise/nicht lesbar." -Level 'WARN' -Tenant $TenantKey }

        # 3. Sign-in-Report (beta) - Verfuegbarkeit sauber tracken
        $signIn = @{}
        $signInAvailable = $false
        if ($SignInReport -eq 'Ja') {
            if (Test-GraphPermission -Token $Token -Permission 'AuditLog.Read.All') {
                $okSi = $true
                $siErr = ''
                # PLURAL-Endpunkt (Singular liefert 404); KEIN $top - der Report paginiert selbst, $top provoziert HTTP 400
                $sa = Get-HUPaged -Ep 'https://graph.microsoft.com/beta/reports/servicePrincipalSignInActivities' -Tk $TenantKey -St $settings -OkRef ([ref]$okSi) -ErrRef ([ref]$siErr)
                if ($okSi) {
                    foreach ($s in $sa) { $signIn[$s.appId] = $s }
                    $signInAvailable = $true
                    Write-HULog -Message "[$fn] Sign-in-Report: $($sa.Count) Eintraege" -Level 'OK' -Tenant $TenantKey
                }
                else {
                    Write-HULog -Message "[$fn] Sign-in-Report nicht abrufbar ($siErr) - Inaktivitaet = unbekannt." -Level 'WARN' -Tenant $TenantKey
                }
            }
            else {
                Write-HULog -Message "[$fn] AuditLog.Read.All fehlt - Sign-in-Report uebersprungen (Inaktivitaet unbekannt)." -Level 'WARN' -Tenant $TenantKey
            }
        }

        # 4. Pro App auswerten
        $appRoleCache = @{}
        $rows = @()
        $processed = 0
        $totalToProcess = @($allSp | Where-Object { $_.servicePrincipalType -eq 'Application' -and -not ($msTenants -contains $_.appOwnerOrganizationId) }).Count

        foreach ($sp in $allSp) {
            if ($sp.servicePrincipalType -ne 'Application') { continue }

            $herkunft = if ($msTenants -contains $sp.appOwnerOrganizationId) { 'Microsoft' }
                elseif ($sp.appOwnerOrganizationId -eq $eigenerTenant) { 'Eigen' } else { 'Fremd' }

            if ($herkunft -eq 'Microsoft') {
                $rows += [PSCustomObject]@{
                    Herkunft = 'Microsoft'; Risikoklasse = ''; App = $sp.displayName; AppId = $sp.appId
                    Aktiviert = $sp.accountEnabled; ZuweisungNoetig = $sp.appRoleAssignmentRequired
                    SSO = $sp.preferredSingleSignOnMode; VerifiedPublisher = ''; Erstellt = $sp.createdDateTime
                    LetzterSignIn = ''; TageInaktiv = ''; IstInaktiv = ''; TenantWeitConsent = ''
                    DelegiertScopes = ''; AppPermissions = ''; RisikoTreffer = ''
                    IstDuplikat = ''; Besitzer = ''; OhneBesitzer = ''; ObjektId = $sp.id
                }
                continue
            }

            $processed++
            if ($processed % 25 -eq 0) {
                Write-HULog -Message "[$fn] [$processed/$totalToProcess] verarbeitet ..." -Level 'INFO' -Tenant $TenantKey
            }

            # Delegated Scopes (dedupliziert - MyFiles & Co listen sonst dieselben Scopes mehrfach)
            $scopes = ''; $tenantWeit = 'nein'
            $del = $grantByClient[$sp.id]
            if ($del) {
                $scopeSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($g in $del) {
                    foreach ($sc in ($g.scope -split '\s+')) { if ($sc) { [void]$scopeSet.Add($sc) } }
                    if ($g.consentType -eq 'AllPrincipals') { $tenantWeit = 'JA' }
                }
                $scopes = (($scopeSet | Sort-Object) -join ', ')
            }

            # Application Permissions
            $appPerms = @()
            $okA = $true
            $ara = Get-HUPaged -Ep "/servicePrincipals/$($sp.id)/appRoleAssignments" -Tk $TenantKey -St $settings -OkRef ([ref]$okA)
            foreach ($a in $ara) {
                if (-not $appRoleCache.ContainsKey($a.resourceId)) {
                    $map = @{}
                    $res = Invoke-GraphRequestWithRetry -Token $Token -TenantKey $TenantKey -Settings $settings -Endpoint "/servicePrincipals/$($a.resourceId)?`$select=appRoles"
                    if (-not ($res.PSObject.Properties.Name -contains 'IsError' -and $res.IsError)) {
                        foreach ($r in $res.appRoles) { $map[$r.id] = $r.value }
                    }
                    $appRoleCache[$a.resourceId] = $map
                }
                $name = $appRoleCache[$a.resourceId][$a.appRoleId]
                if ($name) { $appPerms += $name } else { $appPerms += $a.appRoleId }
            }

            $appPerms = @($appPerms | Sort-Object -Unique)
            $risiko = @($appPerms | Where-Object { $highRisk -contains $_ })

            # Risikoklasse
            $privEsc = ($appPerms -contains 'RoleManagement.ReadWrite.Directory') -and `
                (($appPerms -contains 'Application.ReadWrite.All') -or ($appPerms -contains 'AppRoleAssignment.ReadWrite.All'))
            $risikoklasse = if ($privEsc) { 'Privilege Escalation' }
                elseif ($risiko.Count -gt 0) { 'Kritisch' }
                elseif ($tenantWeit -eq 'JA' -and $scopes) { 'Erhoeht' }
                else { '' }

            # Besitzer
            $owners = ''
            if ($BesitzerAbrufen -eq 'Ja') {
                $okO = $true
                $ow = Get-HUPaged -Ep "/servicePrincipals/$($sp.id)/owners" -Tk $TenantKey -St $settings -OkRef ([ref]$okO)
                $owners = (($ow | ForEach-Object { if ($_.userPrincipalName) { $_.userPrincipalName } else { $_.displayName } }) -join '; ')
            }

            # Letzter Sign-in (Max ueber alle Aktivitaetstypen)
            $last = $null
            if ($signIn.ContainsKey($sp.appId)) {
                $s = $signIn[$sp.appId]
                foreach ($f in @('lastSignInActivity', 'delegatedClientSignInActivity', 'delegatedResourceSignInActivity', 'applicationAuthenticationClientSignInActivity', 'applicationAuthenticationResourceSignInActivity')) {
                    $prop = $s.PSObject.Properties[$f]
                    if ($prop -and $prop.Value -and $prop.Value.lastSignInDateTime) {
                        $d = [datetime]$prop.Value.lastSignInDateTime
                        if (-not $last -or $d -gt $last) { $last = $d }
                    }
                }
            }
            if ($last) {
                $tageInaktiv = [int]((Get-Date) - $last).TotalDays
                $istInaktiv = if ($tageInaktiv -ge $InaktivTage) { 'JA' } else { 'nein' }
            }
            elseif ($signInAvailable) {
                # Report da, aber kein Eintrag = keine Anmeldung im Berichtszeitraum (nicht zwingend "nie benutzt")
                $tageInaktiv = 'keine Aktivitaet'
                $istInaktiv = 'JA'
            }
            else {
                $tageInaktiv = 'unbekannt'
                $istInaktiv = 'unbekannt'
            }

            $rows += [PSCustomObject]@{
                Herkunft          = $herkunft
                Risikoklasse      = $risikoklasse
                App               = $sp.displayName
                AppId             = $sp.appId
                Aktiviert         = $sp.accountEnabled
                ZuweisungNoetig   = $sp.appRoleAssignmentRequired
                SSO               = $sp.preferredSingleSignOnMode
                VerifiedPublisher = $(if ($sp.verifiedPublisher.displayName) { $sp.verifiedPublisher.displayName } else { '-' })
                Erstellt          = $sp.createdDateTime
                LetzterSignIn     = $(if ($last) { $last.ToString('yyyy-MM-dd') } else { '' })
                TageInaktiv       = $tageInaktiv
                IstInaktiv        = $istInaktiv
                TenantWeitConsent = $tenantWeit
                DelegiertScopes   = $scopes
                AppPermissions    = ($appPerms -join ', ')
                RisikoTreffer     = ($risiko -join ', ')
                IstDuplikat       = ''
                Besitzer          = $owners
                OhneBesitzer      = $(if ($BesitzerAbrufen -eq 'Ja' -and -not $owners) { 'JA' } else { 'nein' })
                ObjektId          = $sp.id
            }
        }

        # Duplikate markieren (nach displayName, nur Eigen/Fremd)
        $nameGroups = @{}
        foreach ($r in $rows) {
            if ($r.Herkunft -eq 'Microsoft') { continue }
            $k = $r.App
            if (-not $nameGroups.ContainsKey($k)) { $nameGroups[$k] = 0 }
            $nameGroups[$k]++
        }
        foreach ($r in $rows) {
            if ($r.Herkunft -eq 'Microsoft') { continue }
            if ($nameGroups[$r.App] -gt 1) { $r.IstDuplikat = "JA ($($nameGroups[$r.App])x)" }
            else { $r.IstDuplikat = 'nein' }
        }

        # Kennzahlen
        $ms     = @($rows | Where-Object { $_.Herkunft -eq 'Microsoft' }).Count
        $eigen  = @($rows | Where-Object { $_.Herkunft -eq 'Eigen' })
        $fremd  = @($rows | Where-Object { $_.Herkunft -eq 'Fremd' })
        $nonMs  = @($rows | Where-Object { $_.Herkunft -ne 'Microsoft' })
        $krit   = @($nonMs | Where-Object { $_.RisikoTreffer -ne '' })
        $priv   = @($nonMs | Where-Object { $_.Risikoklasse -eq 'Privilege Escalation' })
        $inaktiv = @($nonMs | Where-Object { $_.IstInaktiv -eq 'JA' })
        $ohneBes = @($nonMs | Where-Object { $_.OhneBesitzer -eq 'JA' })
        $dupl   = @($nonMs | Where-Object { $_.IstDuplikat -like 'JA*' })

        # Duplikate GRUPPIERT (eine Zeile je Name) - AktivInstanz = juengste Anmeldung, Rest sind Loeschkandidaten
        $dupGruppen = @($nonMs | Group-Object App | Where-Object { $_.Count -gt 1 } | ForEach-Object {
            $sorted = $_.Group | Sort-Object Erstellt
            $aktiv = ($_.Group | Where-Object { $_.LetzterSignIn } | Sort-Object LetzterSignIn -Descending | Select-Object -First 1)
            [PSCustomObject]@{
                App              = $_.Name
                Anzahl           = $_.Count
                Aeltester        = ($sorted | Select-Object -First 1).Erstellt
                Neuester         = ($sorted | Select-Object -Last 1).Erstellt
                AktivInstanzId   = if ($aktiv) { $aktiv.ObjektId } else { '' }
                AktivLetzterSignIn = if ($aktiv) { $aktiv.LetzterSignIn } else { '' }
                Kritisch         = if (@($_.Group | Where-Object { $_.RisikoTreffer }).Count -gt 0) { 'JA' } else { 'nein' }
                LoeschKandidaten = (($_.Group | Where-Object { -not $aktiv -or $_.ObjektId -ne $aktiv.ObjektId }).ObjektId -join '; ')
            }
        })

        Write-HULog -Message "[$fn] Microsoft=$ms | Eigen=$($eigen.Count) | Fremd=$($fremd.Count) | Kritisch=$($krit.Count) | PrivEsc=$($priv.Count) | Inaktiv=$($inaktiv.Count) | OhneBesitzer=$($ohneBes.Count) | Duplikate=$($dupl.Count) in $($dupGruppen.Count) Gruppen" -Level 'OK' -Tenant $TenantKey

        # ---- Report-Pfad ----
        $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
        $projectRoot = (Get-Item $scriptRoot).Parent.Parent.FullName
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"
        if (-not (Test-Path $reportFolder)) { New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null }

        # ---- CSV je Tenant ----
        $csvVersion = 1
        do {
            $csvPath = Join-Path $reportFolder ("Security-EnterpriseApps_$TenantKey`_v$csvVersion.csv")
            $csvVersion++
        } while (Test-Path $csvPath)
        $rows | Sort-Object Herkunft, App | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-HULog -Message "[$fn] CSV erstellt: $csvPath" -Level 'OK' -Tenant $TenantKey

        # ---- Excel-Report ----
        $reportPath = $null
        if (Initialize-HUExcel) {
            $xlVersion = 1
            do {
                $reportPath = Join-Path $reportFolder ("Security-EnterpriseApps_$TenantKey`_v$xlVersion.xlsx")
                $xlVersion++
            } while (Test-Path $reportPath)

            try {
                $spSheetCols = 'Herkunft', 'Risikoklasse', 'App', 'AppId', 'Aktiviert', 'SSO', 'TenantWeitConsent', 'DelegiertScopes', 'AppPermissions', 'RisikoTreffer', 'LetzterSignIn', 'TageInaktiv', 'IstInaktiv', 'IstDuplikat', 'Besitzer', 'OhneBesitzer', 'Erstellt', 'ObjektId'

                function Export-Sheet {
                    param($Data, $Name, $Info)
                    if (@($Data).Count -gt 0) {
                        $Data | Select-Object $spSheetCols | Export-Excel -Path $reportPath -WorksheetName $Name -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
                    }
                    else {
                        @([PSCustomObject]@{ Info = $Info }) | Export-Excel -Path $reportPath -WorksheetName $Name -Append
                    }
                }

                Export-Sheet -Data $fremd   -Name 'Fremd-Apps'          -Info 'Keine Fremd-Apps.'
                Export-Sheet -Data $eigen   -Name 'Eigene-Apps'         -Info 'Keine eigenen Apps.'
                Export-Sheet -Data $krit    -Name 'Kritische-Perms'     -Info 'Keine kritischen App-Permissions.'
                Export-Sheet -Data $priv    -Name 'Privilege-Escalation' -Info 'Keine Privilege-Escalation gefunden.'
                Export-Sheet -Data $inaktiv -Name 'Inaktiv'             -Info 'Keine inaktiven Apps (oder Sign-in-Report fehlt).'
                Export-Sheet -Data $ohneBes -Name 'Ohne-Besitzer'       -Info 'Alle Apps haben Besitzer.'

                # Duplikat-Gruppen (eigene Spalten, daher separat)
                if ($dupGruppen.Count -gt 0) {
                    $dupGruppen | Select-Object App, Anzahl, Aeltester, Neuester, Kritisch, AktivInstanzId, AktivLetzterSignIn, LoeschKandidaten |
                        Export-Excel -Path $reportPath -WorksheetName 'Duplikat-Gruppen' -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
                }
                else {
                    @([PSCustomObject]@{ Info = 'Keine Duplikate.' }) | Export-Excel -Path $reportPath -WorksheetName 'Duplikat-Gruppen' -Append
                }

                Format-HUExcelWorkbook -WorkbookPath $reportPath -PrimaryKeyColumn 'App' `
                    -ConditionalColumns @('Risikoklasse', 'RisikoTreffer', 'IstInaktiv', 'OhneBesitzer', 'IstDuplikat', 'TenantWeitConsent')

                $dashMetrics = [ordered]@{
                    'Microsoft (ignoriert)'    = $ms
                    'Eigene Apps'              = $eigen.Count
                    'Fremd-Apps'               = $fremd.Count
                    'Kritische Permissions'    = $krit.Count
                    'Privilege Escalation'     = $priv.Count
                    'Inaktiv'                  = $inaktiv.Count
                    'Ohne Besitzer'            = $ohneBes.Count
                    'Duplikat-Gruppen'         = $dupGruppen.Count
                }
                $sheetLinks = @(
                    @{ SheetName = 'Fremd-Apps';           RowCount = $fremd.Count;       Description = 'Fremd-Apps (Detail)' }
                    @{ SheetName = 'Eigene-Apps';          RowCount = $eigen.Count;       Description = 'Eigene Apps' }
                    @{ SheetName = 'Kritische-Perms';      RowCount = $krit.Count;        Description = 'Kritische App-Permissions' }
                    @{ SheetName = 'Privilege-Escalation'; RowCount = $priv.Count;        Description = 'Faktisch Global-Admin' }
                    @{ SheetName = 'Inaktiv';              RowCount = $inaktiv.Count;     Description = "Inaktiv > $InaktivTage Tage / keine Aktivitaet" }
                    @{ SheetName = 'Ohne-Besitzer';        RowCount = $ohneBes.Count;     Description = 'Apps ohne Besitzer (nur Info)' }
                    @{ SheetName = 'Duplikat-Gruppen';     RowCount = $dupGruppen.Count;  Description = 'Duplikate gruppiert + Loeschkandidaten' }
                )
                Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey `
                    -ReportTitle "Enterprise-App-Inventur - $TenantKey" -Metrics $dashMetrics -SheetDataSources $sheetLinks

                Write-HULog -Message "[$fn] Excel-Report erstellt: $reportPath" -Level 'OK' -Tenant $TenantKey
            }
            catch {
                $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
                $errCmd = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
                Write-HULog -Message "[$fn] Excel-Generierung fehlgeschlagen: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
                $reportPath = $null
            }
        }
        else {
            Write-HULog -Message "[$fn] ImportExcel nicht verfuegbar - nur CSV erstellt." -Level 'WARN' -Tenant $TenantKey
        }

        # Report oeffnen
        $openPath = if ($reportPath -and (Test-Path $reportPath)) { $reportPath } else { $csvPath }
        if (Test-Path $openPath) {
            try { Start-Process -FilePath $openPath }
            catch { Write-HULog -Message "[$fn] Auto-open fehlgeschlagen: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
        }

        return [PSCustomObject]@{
            Success              = $true
            TenantKey            = $TenantKey
            ReportPath           = $reportPath
            CsvPath              = $csvPath
            ServicePrincipals    = $allSp.Count
            Microsoft            = $ms
            Eigen                = $eigen.Count
            Fremd                = $fremd.Count
            Kritisch             = $krit.Count
            PrivilegeEscalation  = $priv.Count
            Inaktiv              = $inaktiv.Count
            OhneBesitzer         = $ohneBes.Count
            Duplikate            = $dupl.Count
            SignInReportVerfuegbar = $signInAvailable
        }
    }
    catch {
        $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        $errCmd = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
        Write-HULog -Message "[$fn] $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
