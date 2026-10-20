#Requires -Version 5.1
<#
.SYNOPSIS
    Sicherheitskatalog: Regeln, Sammler, Ausnahmen, Sollwerte und Verlauf. Nur lesend.
.DESCRIPTION
    Drei Schichten:
      1. Sammler  (Get-HUSecFact)       - ruft Graph ab, merkt sich je Lauf, liefert Grund-Code statt leerer Listen
      2. Regeln   ($script:HUSecRules)  - reine Funktionen auf den abgerufenen Daten
      3. Lauf     (Invoke-HUSecCatalog) - Rechte/Lizenz vorab pruefen, Regeln auswerten, Ausnahmen anwenden
    Status: OK, Abweichung, Ausnahme, NichtPruefbar (Grund: Recht, Lizenz, Technisch, Manuell, NichtAnwendbar), Fehler, Info.
    Ein Fehler beim Abruf ergibt nie OK. Gespeichert werden nur Zahlen und Status, keine Namen oder IDs von Personen.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Ablage: %APPDATA%\HU-MultiTenant\katalog\
#>

# ============================================================================
# Ablage
# ============================================================================
function Get-HUSecPath {
    $p = Join-Path (Join-Path $env:APPDATA 'HU-MultiTenant') 'katalog'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-HUSecJson([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Read-HUSecJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ============================================================================
# Sammler
# ============================================================================
# Einziger Netzwerk-Zugriff des Katalogs (in Tests ersetzbar). Wirft bei Fehlern; Statuscode steht in Exception.Data.
function Invoke-HUSecFetch {
    param([string]$TenantKey, $Settings, [string]$Endpoint, [switch]$All, [switch]$Beta)
    # Beta nur, wo v1.0 nachweislich Eintraege auslaesst (Conditional Access: eine Richtlinie fehlte in v1.0, in beta vorhanden)
    if ($All) { return @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $Endpoint -V1:(-not $Beta)) }
    return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $Endpoint -V1:(-not $Beta))
}

# Rechte des Tokens (roles-Claim); leer = unbekannt
function Get-HUSecTokenRoles([string]$TenantKey, $Settings) {
    try {
        # frisch holen: neu erteilte Rechte stehen sonst erst nach Ablauf des zwischengespeicherten Tokens im roles-Claim
        $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ForceRefresh -ErrorAction Stop
        if ($tok) { return @(Get-TokenPermissions -Token $tok) }
    } catch { }
    return @()
}

# Abrufbare Daten: Schluessel -> Endpunkt, Recht, Lizenz
$script:HUSecFacts = @{
    ca     = @{ Custom = 'ca'; All = $true; Perms = @('Policy.Read.All'); Lic = 'P1' }
    authz  = @{ Ep = '/policies/authorizationPolicy'; All = $false; Perms = @('Policy.Read.All'); Lic = '' }
    # A21: das Feld blockMsolPowerShell liefert Graph nur mit Policy.ReadWrite.Authorization (Beobachtung aus dem Betrieb; in der Microsoft-Doku nicht ausdruecklich belegt)
    authzbl = @{ Ep = '/policies/authorizationPolicy'; All = $false; Perms = @('Policy.ReadWrite.Authorization'); Lic = ''; Manual = 'Feld ist nur mit dem weitreichenden Schreibrecht Policy.ReadWrite.Authorization lesbar, das der Katalog nicht anfordert - bitte im Entra Admin Center selbst pruefen' }
    secdef = @{ Ep = '/policies/identitySecurityDefaultsEnforcementPolicy'; All = $false; Perms = @('Policy.Read.All'); Lic = '' }
    ga     = @{ Ep = "/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId%20eq%20'62e90394-69f5-4237-9190-012177145e10'&`$expand=principal"; All = $true; Perms = @('RoleManagement.Read.Directory'); Lic = '' }
    guests = @{ Ep = "/users?`$filter=userType%20eq%20'Guest'&`$select=id"; All = $true; Perms = @('User.Read.All'); Lic = '' }
    apps   = @{ Ep = "/applications?`$select=id,displayName,passwordCredentials,keyCredentials"; All = $true; Perms = @('Application.Read.All'); Lic = '' }
    compl  = @{ Ep = "/deviceManagement/deviceCompliancePolicies?`$expand=assignments"; All = $true; Perms = @('DeviceManagementConfiguration.Read.All'); Lic = '' }
    devs   = @{ Ep = "/deviceManagement/managedDevices?`$select=id,deviceName,userPrincipalName,complianceState,isEncrypted,operatingSystem"; All = $true; Perms = @('DeviceManagementManagedDevices.Read.All'); Lic = '' }
    reg    = @{ Ep = "/reports/authenticationMethods/userRegistrationDetails?`$filter=isAdmin%20eq%20true"; All = $true; Perms = @('AuditLog.Read.All'); Lic = 'P1' }
    guestsx = @{ Ep = "/users?`$filter=userType%20eq%20'Guest'&`$select=id,displayName,mail,createdDateTime,externalUserState"; All = $true; Perms = @('User.Read.All'); Lic = '' }
    adminact = @{ Custom = 'adminact'; Perms = @('RoleManagement.Read.Directory', 'User.Read.All', 'AuditLog.Read.All'); Lic = 'P1' }
    pwdset = @{ Ep = '/groupSettings'; All = $true; Perms = @('Group.Read.All'); Lic = '' }
    xtpart = @{ Ep = '/policies/crossTenantAccessPolicy/partners'; All = $true; Perms = @('Policy.Read.All'); Lic = '' }
    score  = @{ Ep = '/security/secureScores?$top=1'; All = $false; Perms = @('SecurityEvents.Read.All'); Lic = '' }
    disabled = @{ Ep = "/users?`$filter=accountEnabled%20eq%20false&`$select=id"; All = $true; Perms = @('User.Read.All'); Lic = '' }
    repset = @{ Ep = '/admin/reportSettings'; All = $false; Perms = @('ReportSettings.Read.All'); Lic = '' }
    spset  = @{ Ep = '/admin/sharepoint/settings'; All = $false; Perms = @('SharePointTenantSettings.Read.All'); Lic = '' }
    skus   = @{ Ep = '/subscribedSkus'; All = $true; Perms = @('Organization.Read.All'); Lic = '' }
}

function New-HUSecContext {
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $ctx = [pscustomobject]@{ TenantKey = $TenantKey; Settings = $Settings; Cache = @{}; Roles = @(Get-HUSecTokenRoles $TenantKey $Settings); Plans = $null }
    # Lizenz aus subscribedSkus bestimmen (nicht aus Fehlertexten ableiten); unbekannt = $null
    $f = Get-HUSecFact -Ctx $ctx -Key 'skus' -SkipLicense
    if ($f.Ok) {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($sku in @($f.Data)) { foreach ($sp in @($sku.servicePlans)) { if ("$($sp.provisioningStatus)" -eq 'Success') { $names.Add("$($sp.servicePlanName)") } } }
        $ctx.Plans = $names.ToArray()
    }
    return $ctx
}

function Test-HUSecLicense($Ctx, [string]$Lic) {
    # $true/$false; unbekannt (Lizenzliste nicht lesbar) = $true, damit der Abruf entscheidet
    if (-not $Lic) { return $true }
    if ($null -eq $Ctx.Plans) { return $true }
    $p = @($Ctx.Plans)
    switch ($Lic) {
        'P1' { return [bool]($p -contains 'AAD_PREMIUM' -or $p -contains 'AAD_PREMIUM_P2') }
        'P2' { return [bool]($p -contains 'AAD_PREMIUM_P2') }
        default { return $true }
    }
}

# Abrufe aus mehreren Einzelaufrufen (nur lesend); jeder Fehler wirft und macht die Regel nicht pruefbar
function Get-HUSecCustomFact {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'adminact' {
            # Benutzer mit direkter, aktiver Verzeichnisrolle (Gruppen/PIM-eligible sind nicht sichtbar) und ihre letzte Anmeldung
            $asg = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/roleManagement/directory/roleAssignments?$expand=principal' -All)
            $ids = @($asg | Where-Object { "$($_.principal.'@odata.type')" -like '*user' } | ForEach-Object { "$($_.principalId)" } | Where-Object { $_ } | Sort-Object -Unique)
            if ($ids.Count -gt 100) { throw 'mehr als 100 Admin-Konten' }
            foreach ($id in $ids) {
                $u = Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/users/$id`?`$select=id,userPrincipalName,accountEnabled,createdDateTime,signInActivity"
                $s = $u.signInActivity
                $v = if ($s -and $s.PSObject.Properties['lastSuccessfulSignInDateTime'] -and $s.lastSuccessfulSignInDateTime) { $s.lastSuccessfulSignInDateTime } elseif ($s) { $s.lastSignInDateTime } else { $null }
                [pscustomobject]@{ id = "$($u.id)"; upn = "$($u.userPrincipalName)"; enabled = [bool]$u.accountEnabled; created = $u.createdDateTime; last = $v }
            }
        }
        'ca' {
            # v1.0 fuehrt; beta wird nur zum Abgleich der Ids gelesen. Fehlt eine Richtlinie in v1.0 (in einem Tenant beobachtet, Ursache unklar), kommt sie aus beta dazu und wird markiert. Schlaegt beta fehl, gilt nur v1.0.
            $v1 = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/identity/conditionalAccess/policies' -All)
            $bt = @(); try { $bt = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/identity/conditionalAccess/policies' -All -Beta) } catch { $bt = @() }
            $have = @{}; foreach ($p in $v1) { $have["$($p.id)"] = $true }
            $extra = @($bt | Where-Object { $_ -and "$($_.id)" -and -not $have.ContainsKey("$($_.id)") })
            foreach ($e in $extra) { $e | Add-Member -NotePropertyName __OnlyBeta -NotePropertyValue $true -Force }
            $v1
            $extra
        }
        default { throw "Unbekannter Abruf $Name" }
    }
}

# Ergebnis: Ok, Data, Reason (Recht|Lizenz|Technisch), Detail (kurz, ohne Personendaten)
function Get-HUSecFact {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Key, [switch]$SkipLicense)
    if ($Ctx.Cache.ContainsKey($Key)) { return $Ctx.Cache[$Key] }
    $def = $script:HUSecFacts[$Key]
    $res = $null
    if (-not $def) {
        $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'Technisch'; Detail = "Unbekannte Datenquelle $Key" }
    }
    else {
        $miss = @()
        if (@($Ctx.Roles).Count) { $miss = @($def.Perms | Where-Object { $Ctx.Roles -notcontains $_ }) }
        if ($miss.Count) {
            if ($def.ContainsKey('Manual')) { $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'Manuell'; Detail = "$($def.Manual)" } }
            else { $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'Recht'; Detail = "Recht fehlt: $($miss -join ', ')" } }
        }
        elseif (-not $SkipLicense -and -not (Test-HUSecLicense $Ctx $def.Lic)) {
            $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'Lizenz'; Detail = "Lizenz fehlt: $($def.Lic)" }
        }
        else {
            try {
                if ($def.ContainsKey('Custom')) { $d = Get-HUSecCustomFact -Ctx $Ctx -Name $def.Custom }
                else { $d = Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint $def.Ep -All:$def.All }
                # Einzelobjekt: manche Endpunkte liefern ein Objekt, andere eine Liste mit einem Eintrag
                if (-not $def.All -and $d -and $d.PSObject.Properties['value']) { $d = @($d.value) | Select-Object -First 1 }
                $res = [pscustomobject]@{ Ok = $true; Data = $d; Reason = ''; Detail = '' }
            }
            catch {
                $code = 0
                try { $code = [int]$_.Exception.Data['StatusCode'] } catch { }
                if ($code -in 401, 403) { $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = 'Recht'; Detail = "HTTP $code (Recht oder Rolle fehlt)" } }
                else {
                    # kurze Fehlermeldung von Graph (ohne GUIDs, gekuerzt) - hilft bei HTTP 400 & Co.
                    $msg = ''
                    try { $msg = ("$($_.Exception.Message)" -replace '^[^:]*:\s*', '' -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>' -replace '\s+', ' ').Trim(); if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' } } catch { }
                    $det = $(if ($code) { "HTTP $code$(if ($msg) { ": $msg" })" } else { 'Abruf fehlgeschlagen oder unvollstaendig' })
                    # bekannte Anmeldefehler von Microsoft in Klartext (Dienst fehlt im Tenant, meist Microsoft-seitig)
                    $why = 'Technisch'
                    if ("$($_.Exception.Message)" -match 'AADSTS500011') { $why = 'Technisch'; $det = 'Secure Score im Tenant nicht verfuegbar (Dienst nicht bereitgestellt, AADSTS500011) - Ursache unklar' }
                    $res = [pscustomobject]@{ Ok = $false; Data = $null; Reason = $why; Detail = $det }
                }
            }
        }
    }
    $Ctx.Cache[$Key] = $res
    return $res
}

# ============================================================================
# Ergebnis
# ============================================================================
function New-HUSecResult {
    param($Rule, [string]$Tenant, [string]$Status, [string]$Reason = '', $Count = $null, [string]$Detail = '', [bool]$Complete = $true)
    [pscustomobject]@{
        RuleId = "$($Rule.Id)"; Area = "$($Rule.Area)"; Title = "$($Rule.Title)"; Sev = "$($Rule.Sev)"; Tenant = $Tenant
        Status = $Status; Reason = $Reason; Count = $Count; Detail = $Detail; Complete = $Complete; ExceptionId = ''
    }
}

# ============================================================================
# Sollwerte (Standard im Code, Ueberschreibung je Tenant in baseline.json)
# ============================================================================
$script:HUSecDefaults = @{
    A01 = @{ minEnabled = 1 }
    A08 = @{ min = 2; max = 4 }
    A09 = @{ allowedWithout = 2 }
    A19 = @{ warnDays = 30 }
    A26 = @{ maxAgeDays = 30 }
    A27 = @{ staleDays = 90 }
    E03 = @{ maxPercent = 5 }
    E04 = @{ minPercent = 95 }
}

# Regeln mit Min = true (Mindeststandard) lassen sich in den Sollwerten nicht abschalten, nur per Ausnahme mit Ablauf
function Get-HUSecBaseline {
    param([string]$TenantKey, [object[]]$Rules = @())
    $b = @{}
    foreach ($k in $script:HUSecDefaults.Keys) { $b[$k] = @{} + $script:HUSecDefaults[$k] }
    $errs = New-Object System.Collections.Generic.List[string]
    $file = Join-Path (Get-HUSecPath) 'baseline.json'
    $j = $null
    try { $j = Read-HUSecJson $file } catch { $errs.Add('Sollwerte-Datei nicht lesbar (Schema)') }
    if ($j) {
        $ids = @($Rules | ForEach-Object { $_.Id })
        foreach ($layer in @($j.global, $(if ($TenantKey -and $j.tenants) { $j.tenants.$TenantKey } else { $null }))) {
            if (-not $layer) { continue }
            foreach ($p in $layer.PSObject.Properties) {
                if ($ids.Count -and $ids -notcontains $p.Name) { $errs.Add("Unbekannte Regel $($p.Name) in den Sollwerten"); continue }
                if (-not $b.ContainsKey($p.Name)) { $b[$p.Name] = @{} }
                foreach ($q in $p.Value.PSObject.Properties) { $b[$p.Name][$q.Name] = $q.Value }
            }
        }
    }
    return [pscustomobject]@{ Values = $b; Errors = $errs.ToArray() }
}

# ============================================================================
# Ausnahmen (je Regel + Tenant + Objekt, mit Ablauf)
# ============================================================================
function Get-HUSecExceptions {
    $j = $null
    try { $j = Read-HUSecJson (Join-Path (Get-HUSecPath) 'exceptions.json') } catch { }
    if (-not $j) { return @() }
    return @($j.items)
}

function Test-HUSecExceptionInput {
    param([string]$Reason, [datetime]$ValidUntil, [string]$Sev, [datetime]$Now = (Get-Date))
    if (("$Reason").Trim().Length -lt 20) { return 'Begruendung: mindestens 20 Zeichen.' }
    if ($ValidUntil -le $Now) { return 'Gueltig bis muss in der Zukunft liegen.' }
    $maxMonths = if ($Sev -eq 'Kritisch') { 3 } else { 12 }
    if ($ValidUntil -gt $Now.AddMonths($maxMonths)) { return "Gueltig bis: hoechstens $maxMonths Monate (Schweregrad $Sev)." }
    return ''
}

function Add-HUSecException {
    param([Parameter(Mandatory)][string]$RuleId, [Parameter(Mandatory)][string]$TenantKey, [string]$ObjectId = '-',
        [Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][datetime]$ValidUntil, [Parameter(Mandatory)][string]$Responsible, [string]$Sev = 'Hoch')
    $err = Test-HUSecExceptionInput -Reason $Reason -ValidUntil $ValidUntil -Sev $Sev
    if ($err) { throw $err }
    $items = @(Get-HUSecExceptions | Where-Object { -not ($_.ruleId -eq $RuleId -and $_.tenant -eq $TenantKey -and $_.objectId -eq $ObjectId) })
    $new = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N').Substring(0, 8); ruleId = $RuleId; tenant = $TenantKey; objectId = $ObjectId
        reason = $Reason.Trim(); responsible = $Responsible; created = (Get-Date).ToUniversalTime().ToString('o'); validUntil = $ValidUntil.ToUniversalTime().ToString('o')
    }
    Write-HUSecJson (Join-Path (Get-HUSecPath) 'exceptions.json') ([pscustomobject]@{ version = 1; items = @($items + $new) })
    return $new
}

function Remove-HUSecException([string]$Id) {
    $items = @(Get-HUSecExceptions | Where-Object { $_.id -ne $Id })
    Write-HUSecJson (Join-Path (Get-HUSecPath) 'exceptions.json') ([pscustomobject]@{ version = 1; items = $items })
}

# Gueltige Ausnahme zu Ergebnis? Abgelaufen = zaehlt nicht (Abweichung bleibt)
function Find-HUSecException($Result, [object[]]$Exceptions, [datetime]$Now = (Get-Date)) {
    foreach ($e in @($Exceptions)) {
        if ($e.ruleId -eq $Result.RuleId -and $e.tenant -eq $Result.Tenant -and $e.objectId -eq '-') {
            if ([datetime]::Parse("$($e.validUntil)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -gt $Now) { return $e }
        }
    }
    return $null
}

# ============================================================================
# Regeln (reine Funktionen: $F = Daten nach Schluessel, $B = Sollwerte der Regel)
# ============================================================================
function Test-HUSecCaTargetsAll($P) {
    $u = @($P.conditions.users.includeUsers)
    return [bool]($u -contains 'All')
}
function Test-HUSecCaBlocks($P) {
    return [bool](@($P.grantControls.builtInControls) -contains 'block')
}

# Aktive Richtlinie, die MFA (oder eine Authentifizierungsstaerke) fuer alle Apps verlangt
function Test-HUSecCaMfa($P) {
    return [bool]("$($P.state)" -eq 'enabled' -and (@($P.conditions.applications.includeApplications) -contains 'All') -and
        ((@($P.grantControls.builtInControls) -contains 'mfa') -or $P.grantControls.authenticationStrength))
}

# MFA verlangt (ohne Blick auf den Status der Richtlinie)
function Test-HUSecCaMfaAny($P) {
    return [bool]((@($P.conditions.applications.includeApplications) -contains 'All') -and ((@($P.grantControls.builtInControls) -contains 'mfa') -or $P.grantControls.authenticationStrength))
}

# Liste der Richtlinien fuer "Richtlinien anzeigen": alle Richtlinien, mit Hinweis ob und warum sie fuer die Regel zaehlen
function Get-HUSecPolicyItems($Policies, [scriptblock]$Match) {
    foreach ($pol in @($Policies)) {
        $m = $false; try { $m = [bool](& $Match $pol) } catch { }
        $state = "$($pol.state)"
        $blocks = Test-HUSecCaBlocks $pol
        $aktion = if ($blocks) { 'Blockieren' } else { (@($pol.grantControls.builtInControls) -join ', ') }
        if (-not $aktion -and $pol.grantControls.authenticationStrength) { $aktion = 'Authentifizierungsstaerke' }
        $u = $pol.conditions.users
        $gilt = if (Test-HUSecCaTargetsAll $pol) { 'Alle Benutzer' } elseif (@($u.includeRoles | Where-Object { $_ }).Count) { "$(@($u.includeRoles | Where-Object { $_ }).Count) Admin-Rollen" } elseif (@($u.includeGroups | Where-Object { $_ }).Count) { 'Gruppen' } elseif ($u.includeGuestsOrExternalUsers) { 'Gaeste' } else { 'einzelne Benutzer' }
        $why = if ($m -and $state -eq 'enabled') { '' } elseif ($m) { "Status $state" } else { 'trifft die Regel nicht' }
        if ($pol.PSObject.Properties['__OnlyBeta']) { $why = ("$why (nur ueber beta sichtbar)").Trim() }
        [pscustomobject]@{ Richtlinie = "$($pol.displayName)"; Status = $state; Aktion = $aktion; GiltFuer = $gilt; ZaehltFuerRegel = $(if ($m -and $state -eq 'enabled') { 'Ja' } else { 'Nein' }); Grund = $why }
    }
}

# Geoblock-Richtlinie: blockiert, hat eine Standortbedingung, ist keine Spezialrichtlinie (z.B. Geraetecode-Flow, nur bestimmte Client-Apps) und trifft nicht nur Gaeste
function Test-HUSecCaGeoblock($P) {
    if (-not (Test-HUSecCaBlocks $P)) { return $false }
    if (-not $P.conditions.locations -or -not (@($P.conditions.locations.includeLocations | Where-Object { $_ }).Count)) { return $false }
    if ($P.conditions.authenticationFlows -and "$($P.conditions.authenticationFlows.transferMethods)") { return $false }
    if (@(@($P.conditions.clientAppTypes) | Where-Object { $_ -and "$_" -ne 'all' }).Count) { return $false }
    $apps = @($P.conditions.applications.includeApplications | Where-Object { $_ })
    if ($apps.Count -and ($apps -notcontains 'All')) { return $false }
    $u = $P.conditions.users
    return [bool]((Test-HUSecCaTargetsAll $P) -or @($u.includeUsers | Where-Object { $_ }).Count -or @($u.includeGroups | Where-Object { $_ }).Count -or @($u.includeRoles | Where-Object { $_ }).Count)
}

# Richtlinie trifft alle Benutzer oder Admin-Rollen (dort waeren Notfallkonten betroffen); reine Gruppen-/Benutzerrichtlinien nicht
# Richtlinie blockiert oder verlangt etwas vom Konto (MFA, Authentifizierungsstaerke, Geraet, Nutzungsbedingungen ...); reine Sitzungsrichtlinien nicht
function Test-HUSecCaRestricts($P) {
    if (Test-HUSecCaBlocks $P) { return $true }
    $g = $P.grantControls
    if (-not $g) { return $false }
    return [bool](@($g.builtInControls | Where-Object { $_ }).Count -or $g.authenticationStrength -or @($g.termsOfUse | Where-Object { $_ }).Count -or @($g.customAuthenticationFactors | Where-Object { $_ }).Count)
}

function Test-HUSecCaHitsBreakGlass($P) {
    return [bool]("$($P.state)" -eq 'enabled' -and ((Test-HUSecCaTargetsAll $P) -or @($P.conditions.users.includeRoles | Where-Object { $_ }).Count) -and (Test-HUSecCaRestricts $P))
}

# Wichtige Admin-Rollen (Rollenvorlagen-IDs laut Microsoft Learn; nicht gegen jeden Tenant verifiziert)
$script:HUSecAdminRoles = [ordered]@{
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
    '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
    'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
    '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
    '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'
    'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' = 'Conditional Access Administrator'
    '729827e3-9c14-49f7-bb1b-9608f156bbb8' = 'Helpdesk Administrator'
    '966707d0-3269-4727-9be2-8c3a10f19b9d' = 'Password Administrator'
}

$script:HUSecRules = @(
    @{ Id = 'A01'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Conditional Access: mindestens eine Richtlinie ist aktiv (nicht nur Berichtsmodus)'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) $true } }
        Eval = { param($F, $B)
            $all = @($F.ca)
            $on = @($all | Where-Object { "$($_.state)" -eq 'enabled' }).Count
            $rep = @($all | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count
            $off = $all.Count - $on - $rep
            $d = "$on aktiv, $rep nur Berichtsmodus, $off aus"
            if ($on -ge [int]$B.minEnabled) { @{ Status = 'OK'; Count = $on; Detail = $d } } else { @{ Status = 'Abweichung'; Count = $on; Detail = $d } }
        } }
    @{ Id = 'A04'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Legacy-Authentifizierung ist per Richtlinie blockiert'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) $t = @($P.conditions.clientAppTypes); (Test-HUSecCaTargetsAll $P) -and (Test-HUSecCaBlocks $P) -and ($t -contains 'exchangeActiveSync') -and ($t -contains 'other') } }
        Eval = { param($F, $B)
            $hit = @($F.ca | Where-Object {
                    $t = @($_.conditions.clientAppTypes)
                    (Test-HUSecCaTargetsAll $_) -and (Test-HUSecCaBlocks $_) -and ($t -contains 'exchangeActiveSync') -and ($t -contains 'other')
                })
            $on = @($hit | Where-Object { "$($_.state)" -eq 'enabled' }).Count
            $rep = @($hit | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count
            if ($on) { @{ Status = 'OK'; Count = $on; Detail = "$on aktive Richtlinie(n)" } }
            elseif ($rep) { @{ Status = 'Abweichung'; Count = 0; Detail = 'nur im Berichtsmodus' } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine passende Richtlinie' } }
        } }
    @{ Id = 'A08'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Anzahl Global Administratoren'; Facts = @('ga'); Min = $false; ItemsLabel = 'Konten'; ItemsSort = 'Name'
        Items = { param($F, $B)
            foreach ($r in @($F.ga)) {
                $t = "$($r.principal.'@odata.type')"
                $typ = if ($t -like '*user') { 'Benutzer' } elseif ($t -like '*group') { 'Gruppe' } elseif ($t -like '*servicePrincipal') { 'Dienstprinzipal' } else { $t }
                $nm = if ($t -like '*user') { "$($r.principal.userPrincipalName)" } else { "$($r.principal.displayName)" }
                [pscustomobject]@{ Name = $nm; Typ = $typ; Anzeigename = "$($r.principal.displayName)" }
            }
        }
        Eval = { param($F, $B)
            $rows = @($F.ga)
            $groups = @($rows | Where-Object { "$($_.principal.'@odata.type')" -like '*group' }).Count
            $users = @($rows | Where-Object { "$($_.principal.'@odata.type')" -like '*user' }).Count
            $sps = @($rows | Where-Object { "$($_.principal.'@odata.type')" -like '*servicePrincipal' }).Count
            if ($groups) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Count = $users; Detail = "$groups Gruppe(n) in der Rolle - Mitglieder werden noch nicht aufgeloest"; Complete = $false } }
            $d = "$users Benutzer, $sps Dienstprinzipal(e)"
            if ($users -ge [int]$B.min -and $users -le [int]$B.max) { @{ Status = 'OK'; Count = $users; Detail = $d } } else { @{ Status = 'Abweichung'; Count = $users; Detail = "$d (Soll $($B.min)-$($B.max))" } }
        } }
    @{ Id = 'A14'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Gaeste haben die am staerksten eingeschraenkte Verzeichnisrolle'; Facts = @('authz'); Min = $false
        Eval = { param($F, $B)
            $id = "$($F.authz.guestUserRoleId)"
            if (-not $id) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld guestUserRoleId nicht gefunden'; Complete = $false } }
            if ($id -eq '2af84b1e-32c8-42b7-82bc-daa82404023b') { @{ Status = 'OK'; Detail = 'eingeschraenkt' } }
            elseif ($id -eq '10dae51f-b6af-4016-8d66-8c2a99b929b3') { @{ Status = 'Abweichung'; Detail = 'Standard-Gastrolle (sieht Verzeichnisobjekte)' } }
            else { @{ Status = 'Abweichung'; Detail = 'Gaeste haben Mitglieder-Rechte' } }
        } }
    @{ Id = 'A15'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Gaeste einladen duerfen nur Administratoren und Gast-Einlader'; Facts = @('authz'); Min = $false
        Eval = { param($F, $B)
            $v = "$($F.authz.allowInvitesFrom)"
            if (-not $v) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld allowInvitesFrom nicht gefunden'; Complete = $false } }
            if ($v -in 'adminsAndGuestInviters', 'none') { @{ Status = 'OK'; Detail = $v } } else { @{ Status = 'Abweichung'; Detail = $v } }
        } }
    @{ Id = 'A17'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'Benutzer duerfen Apps nicht selbst zustimmen (User Consent)'; Facts = @('authz'); Min = $true
        Eval = { param($F, $B)
            $d = $F.authz.defaultUserRolePermissions
            $prop = $null
            if ($d -and $d.PSObject.Properties['permissionGrantPoliciesAssigned']) { $prop = $d.permissionGrantPoliciesAssigned }
            elseif ($F.authz.PSObject.Properties['permissionGrantPolicyIdsAssignedToDefaultUserRole']) { $prop = $F.authz.permissionGrantPolicyIdsAssignedToDefaultUserRole }
            else { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld fuer Consent-Richtlinien nicht gefunden'; Complete = $false } }
            $badList = @(@($prop) | Where-Object { "$_" -like 'ManagePermissionGrantsForSelf.*' })
            $bad = $badList.Count
            $names = @($badList | ForEach-Object {
                    switch -Wildcard ("$_") {
                        '*legacy' { 'alle Apps (Legacy)' }
                        '*-low' { 'verifizierte Herausgeber, schwache Berechtigungen' }
                        '*recommended' { 'von Microsoft verwaltet (empfohlen)' }
                        default { ("$_" -replace '^ManagePermissionGrantsForSelf\.', '') }
                    }
                }) -join '; '
            if ($bad -eq 0) { @{ Status = 'OK'; Count = 0; Detail = 'kein Benutzer-Consent' } } else { @{ Status = 'Abweichung'; Count = $bad; Detail = "Benutzer-Consent aktiv: $names" } }
        } }
    @{ Id = 'V5'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'MFA-Grundschutz vorhanden (Security Defaults oder CA-Richtlinie fuer alle)'; Facts = @('ca', 'secdef'); Min = $true; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaMfaAny $P) -and (Test-HUSecCaTargetsAll $P) } }
        Eval = { param($F, $B)
            $sd = [bool]$F.secdef.isEnabled
            $mfa = @($F.ca | Where-Object {
                    "$($_.state)" -eq 'enabled' -and (Test-HUSecCaTargetsAll $_) -and (@($_.conditions.applications.includeApplications) -contains 'All') -and
                    ((@($_.grantControls.builtInControls) -contains 'mfa') -or $_.grantControls.authenticationStrength)
                }).Count
            if ($sd -or $mfa) { @{ Status = 'OK'; Count = $mfa; Detail = "Security Defaults $(if ($sd) { 'an' } else { 'aus' }), $mfa CA-Richtlinie(n) mit MFA fuer alle" } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'Security Defaults aus und keine aktive MFA-Richtlinie fuer alle' } }
        } }
    @{ Id = 'A02'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'MFA fuer Administratoren erzwungen (wichtige Admin-Rollen abgedeckt)'; Facts = @('ca', 'secdef'); Min = $true; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaMfaAny $P) -and ((Test-HUSecCaTargetsAll $P) -or @($P.conditions.users.includeRoles | Where-Object { $_ }).Count) } }
        Eval = { param($F, $B)
            if ([bool]$F.secdef.isEnabled) { return @{ Status = 'OK'; Count = 0; Detail = 'Security Defaults an (MFA fuer Administratoren)' } }
            $pols = @($F.ca | Where-Object { Test-HUSecCaMfa $_ })
            $exU = @($pols | ForEach-Object { @($_.conditions.users.excludeUsers) } | Where-Object { $_ } | Sort-Object -Unique).Count
            $exG = @($pols | ForEach-Object { @($_.conditions.users.excludeGroups) } | Where-Object { $_ } | Sort-Object -Unique).Count
            $ex = if ($exU -or $exG) { " | Ausgenommen in diesen Richtlinien: $exU Benutzer, $exG Gruppe(n) - bitte pruefen (nur Notfallkonten)" } else { '' }
            if (@($pols | Where-Object { Test-HUSecCaTargetsAll $_ }).Count) { return @{ Status = 'OK'; Count = 0; Detail = "MFA-Richtlinie fuer alle Benutzer deckt Administratoren ab$ex" } }
            $cov = @($pols | ForEach-Object { @($_.conditions.users.includeRoles) } | ForEach-Object { "$_".ToLowerInvariant() })
            $miss = @($script:HUSecAdminRoles.Keys | Where-Object { $cov -notcontains $_ } | ForEach-Object { $script:HUSecAdminRoles[$_] })
            if ($miss.Count -eq 0) { @{ Status = 'OK'; Count = 0; Detail = "alle geprueften Admin-Rollen durch MFA-Richtlinien abgedeckt$ex" } }
            else { @{ Status = 'Abweichung'; Count = $miss.Count; Detail = "ohne MFA-Richtlinie: $($miss -join ', ')$ex" } }
        } }
    @{ Id = 'A03'; Area = 'Entra'; Sev = 'Hoch'; Title = 'MFA gilt auch fuer Gaeste'; Facts = @('ca', 'secdef'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaMfaAny $P) -and ((Test-HUSecCaTargetsAll $P) -or ($P.conditions.users.includeGuestsOrExternalUsers -and "$($P.conditions.users.includeGuestsOrExternalUsers.guestOrExternalUserTypes)" -like '*b2bCollaborationGuest*')) } }
        Eval = { param($F, $B)
            if ([bool]$F.secdef.isEnabled) { return @{ Status = 'OK'; Count = 0; Detail = 'Security Defaults an' } }
            $pols = @($F.ca | Where-Object { Test-HUSecCaMfa $_ })
            $grp = @($pols | Where-Object { @($_.conditions.users.includeGroups).Count }).Count
            $hit = @($pols | Where-Object { (Test-HUSecCaTargetsAll $_) -or ($_.conditions.users.includeGuestsOrExternalUsers -and "$($_.conditions.users.includeGuestsOrExternalUsers.guestOrExternalUserTypes)" -like '*b2bCollaborationGuest*') }).Count
            if ($hit) { @{ Status = 'OK'; Count = $hit; Detail = "$hit MFA-Richtlinie(n) gelten fuer Gaeste. Gruppenbasierte MFA-Richtlinien (Lehrer, Schueler): $grp - ob alle Gruppen abgedeckt sind, wird noch nicht geprueft" } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = "keine aktive MFA-Richtlinie fuer Gaeste ($grp gruppenbasierte MFA-Richtlinie(n) vorhanden)" } }
        } }
    @{ Id = 'A09'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'Administratoren haben MFA registriert'; Facts = @('reg', 'disabled'); Min = $true; ItemsSignIn = $true
        Items = { param($F, $B)
            $dis = @{}; foreach ($x in @($F.disabled)) { $dis["$($x.id)"] = $true }
            @($F.reg | Where-Object { ($_.isMfaRegistered -eq $false) -and -not $dis.ContainsKey("$($_.id)") } | ForEach-Object {
                    [pscustomobject]@{ Anmeldename = "$($_.userPrincipalName)"; Anzeigename = "$($_.userDisplayName)"; Methoden = (@($_.methodsRegistered) -join ', '); __Id = "$($_.id)" }
                })
        }
        Eval = { param($F, $B)
            $dis = @{}; foreach ($x in @($F.disabled)) { $dis["$($x.id)"] = $true }
            $all = @($F.reg)
            $adm = @($all | Where-Object { -not $dis.ContainsKey("$($_.id)") })
            $nDis = $all.Count - $adm.Count
            if (-not $adm.Count) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'keine Administratoren in den Registrierungsdaten gefunden'; Complete = $false } }
            $no = @($adm | Where-Object { $_.isMfaRegistered -eq $false }).Count
            $d = "$no von $($adm.Count) Administratoren ohne MFA-Registrierung (erlaubt: $($B.allowedWithout), z.B. Notfallkonten)"
            if ($nDis -gt 0) { $d += "; $nDis deaktivierte Konten nicht gezaehlt" }
            if ($no -gt [int]$B.allowedWithout) { @{ Status = 'Abweichung'; Count = $no; Detail = $d } } else { @{ Status = 'OK'; Count = $no; Detail = $d } }
        } }
    @{ Id = 'V15'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Berichte verbergen Benutzer-, Gruppen- und Standortnamen'; Facts = @('repset'); Min = $false
        Eval = { param($F, $B)
            if (-not $F.repset.PSObject.Properties['displayConcealedNames']) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld displayConcealedNames nicht gefunden'; Complete = $false } }
            if ($F.repset.displayConcealedNames -eq $true) { @{ Status = 'OK'; Count = 0; Detail = 'Namen in Berichten sind verborgen' } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'Namen in Admin-Berichten sind sichtbar' } }
        } }
    @{ Id = 'A19'; Area = 'Apps'; Sev = 'Hoch'; Title = 'Zugangsdaten von App-Registrierungen laufen ab oder sind abgelaufen'; Facts = @('apps'); Min = $false; ItemsLabel = 'Apps'; ItemsSort = 'LaeuftAb'
        Items = { param($F, $B)
            $now = Get-Date; $soon = $now.AddDays([int]$B.warnDays)
            foreach ($a in @($F.apps)) {
                $ends = @(@($a.passwordCredentials) + @($a.keyCredentials) | Where-Object { $_ -and $_.endDateTime } | ForEach-Object { [datetime]$_.endDateTime })
                if (-not $ends.Count) { continue }
                $last = ($ends | Measure-Object -Maximum).Maximum
                if ($last -lt $now) { $st = 'abgelaufen' } elseif ($last -lt $soon) { $st = 'laeuft bald ab' } else { continue }
                [pscustomobject]@{ App = "$($a.displayName)"; Status = $st; LaeuftAb = $last.ToString('yyyy-MM-dd'); AppId = "$($a.id)" }
            }
        }
        Eval = { param($F, $B)
            $now = Get-Date; $soon = $now.AddDays([int]$B.warnDays)
            $exp = New-Object System.Collections.Generic.List[string]; $near = New-Object System.Collections.Generic.List[string]
            foreach ($a in @($F.apps)) {
                $ends = @(@($a.passwordCredentials) + @($a.keyCredentials) | Where-Object { $_ -and $_.endDateTime } | ForEach-Object { [datetime]$_.endDateTime })
                if (-not $ends.Count) { continue }
                $last = ($ends | Measure-Object -Maximum).Maximum
                if ($last -lt $now) { $exp.Add("$($a.displayName)") } elseif ($last -lt $soon) { $near.Add("$($a.displayName)") }
            }
            $n = $exp.Count + $near.Count
            if ($n -eq 0) { return @{ Status = 'OK'; Count = 0; Detail = "keine App mit abgelaufenen oder bald ablaufenden Zugangsdaten ($(@($F.apps).Count) Apps)" } }
            $names = @(@($near) + @($exp) | Select-Object -First 3) -join ', '
            @{ Status = 'Abweichung'; Count = $n; Detail = "$($near.Count) laufen in $($B.warnDays) Tagen ab, $($exp.Count) bereits abgelaufen (jeweils ohne neuere Zugangsdaten), z.B. $names" }
        } }
    @{ Id = 'E01'; Area = 'Intune'; Sev = 'Hoch'; Title = 'Compliance-Richtlinien vorhanden und zugewiesen'; Facts = @('compl'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B)
            foreach ($c in @($F.compl)) {
                $n = @($c.assignments).Count
                [pscustomobject]@{ Richtlinie = "$($c.displayName)"; Zuweisungen = $n; Plattform = ("$($c.'@odata.type')" -replace '^#microsoft.graph.', ''); Ergebnis = $(if ($n) { 'zugewiesen' } else { 'KEINE Zuweisung' }) }
            }
        }
        Eval = { param($F, $B)
            $n = @($F.compl).Count
            if ($n -eq 0) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'keine Compliance-Richtlinie vorhanden' } }
            $un = @($F.compl | Where-Object { @($_.assignments).Count -eq 0 }).Count
            if ($un) { @{ Status = 'Abweichung'; Count = $un; Detail = "$un von $n Richtlinie(n) ohne Zuweisung" } } else { @{ Status = 'OK'; Count = $n; Detail = "$n Richtlinie(n), alle zugewiesen" } }
        } }
    @{ Id = 'E03'; Area = 'Intune'; Sev = 'Hoch'; Title = 'Anteil nicht konformer Geraete ist niedrig'; Facts = @('devs'); Min = $false; ItemsLabel = 'Geraete'; ItemsSort = 'Geraet'
        Items = { param($F, $B)
            foreach ($d in @($F.devs | Where-Object { "$($_.complianceState)" -eq 'noncompliant' })) {
                [pscustomobject]@{ Geraet = "$($d.deviceName)"; Benutzer = "$($d.userPrincipalName)"; System = "$($d.operatingSystem)" }
            }
        }
        Eval = { param($F, $B)
            $total = @($F.devs).Count
            if ($total -eq 0) { return @{ Status = 'Info'; Count = 0; Detail = 'keine verwalteten Geraete' } }
            $nc = @($F.devs | Where-Object { "$($_.complianceState)" -eq 'noncompliant' }).Count
            $pct = [math]::Round(100.0 * $nc / $total, 1)
            $d = "$nc von $total Geraeten nicht konform ($pct %, Grenze $($B.maxPercent) %)"
            if ($pct -gt [double]$B.maxPercent) { @{ Status = 'Abweichung'; Count = $nc; Detail = $d } } else { @{ Status = 'OK'; Count = $nc; Detail = $d } }
        } }
    @{ Id = 'E04'; Area = 'Intune'; Sev = 'Hoch'; Title = 'Windows-Geraete sind verschluesselt (BitLocker)'; Facts = @('devs'); Min = $false; ItemsLabel = 'Geraete'; ItemsSort = 'Geraet'
        Items = { param($F, $B)
            foreach ($d in @($F.devs | Where-Object { "$($_.operatingSystem)" -eq 'Windows' -and $_.isEncrypted -eq $false })) {
                [pscustomobject]@{ Geraet = "$($d.deviceName)"; Benutzer = "$($d.userPrincipalName)" }
            }
        }
        Eval = { param($F, $B)
            $w = @($F.devs | Where-Object { "$($_.operatingSystem)" -eq 'Windows' })
            if (-not $w.Count) { return @{ Status = 'Info'; Count = 0; Detail = 'keine verwalteten Windows-Geraete' } }
            $un = @($w | Where-Object { $_.isEncrypted -eq $false }).Count
            $pct = [math]::Round(100.0 * ($w.Count - $un) / $w.Count, 1)
            $d = "$($w.Count - $un) von $($w.Count) Windows-Geraeten verschluesselt ($pct %, Soll mindestens $($B.minPercent) %)"
            if ($pct -lt [double]$B.minPercent) { @{ Status = 'Abweichung'; Count = $un; Detail = $d } } else { @{ Status = 'OK'; Count = $un; Detail = $d } }
        } }
    @{ Id = 'A25'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Normale Benutzer sind von den Microsoft-Adminportalen ausgesperrt (Conditional Access)'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaBlocks $P) -and (Test-HUSecCaTargetsAll $P) -and (@($P.conditions.applications.includeApplications) -contains 'MicrosoftAdminPortals') -and (@(@($P.conditions.users.excludeRoles) + @($P.conditions.users.excludeGroups) | Where-Object { $_ }).Count -gt 0) } }
        Eval = { param($F, $B)
            $hit = @($F.ca | Where-Object {
                    "$($_.state)" -eq 'enabled' -and (Test-HUSecCaBlocks $_) -and (Test-HUSecCaTargetsAll $_) -and
                    (@($_.conditions.applications.includeApplications) -contains 'MicrosoftAdminPortals') -and
                    (@(@($_.conditions.users.excludeRoles) + @($_.conditions.users.excludeGroups) | Where-Object { $_ }).Count -gt 0)
                })
            $rep = @($F.ca | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' -and (Test-HUSecCaBlocks $_) -and (@($_.conditions.applications.includeApplications) -contains 'MicrosoftAdminPortals') }).Count
            if ($hit.Count) { @{ Status = 'OK'; Count = $hit.Count; Detail = "$($hit.Count) aktive Blockier-Richtlinie(n) fuer die Adminportale mit Ausnahme (Admins)" } }
            elseif ($rep) { @{ Status = 'Abweichung'; Count = 0; Detail = 'Adminportale nur im Berichtsmodus blockiert' } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Richtlinie, die Benutzer von den Adminportalen blockiert (alle Benutzer, Ausnahme fuer Admins)' } }
        } }
    @{ Id = 'A27'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Keine veralteten Administrator-Konten (lange nicht angemeldet)'; Facts = @('adminact'); Min = $false; ItemsLabel = 'Konten'; ItemsSignIn = $true
        Items = { param($F, $B)
            $max = [int]$B.staleDays; $now = Get-Date
            foreach ($a in @($F.adminact | Where-Object { $_.enabled })) {
                $d = $null; try { if ($a.last) { $d = [datetime]$a.last } } catch { }
                $c = $null; try { if ($a.created) { $c = [datetime]$a.created } } catch { }
                $stale = if ($d) { ($now - $d).TotalDays -gt $max } else { $c -and ($now - $c).TotalDays -gt $max }
                if ($stale) { [pscustomobject]@{ Anmeldename = "$($a.upn)"; __Id = "$($a.id)" } }
            }
        }
        Eval = { param($F, $B)
            $max = [int]$B.staleDays; $now = Get-Date
            $act = @($F.adminact | Where-Object { $_.enabled })
            $stale = 0; $never = 0
            foreach ($a in $act) {
                $d = $null; try { if ($a.last) { $d = [datetime]$a.last } } catch { }
                $c = $null; try { if ($a.created) { $c = [datetime]$a.created } } catch { }
                if ($d) { if (($now - $d).TotalDays -gt $max) { $stale++ } }
                elseif ($c -and ($now - $c).TotalDays -gt $max) { $stale++; $never++ }
            }
            $d2 = "$($act.Count) aktive Admin-Konten (nur direkte Rollen)"
            if ($stale) { @{ Status = 'Abweichung'; Count = $stale; Detail = "$d2, $stale ohne Anmeldung seit mehr als $max Tagen$(if ($never) { " (davon $never nie angemeldet)" })" } }
            else { @{ Status = 'OK'; Count = 0; Detail = "$d2, alle innerhalb von $max Tagen angemeldet" } }
        } }
    @{ Id = 'A28'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Kennwortschutz fuer das lokale AD ist im Tenant eingeschaltet (Modus Erzwingen)'; Facts = @('pwdset'); Min = $false
        Eval = { param($F, $B)
            $o = @($F.pwdset | Where-Object { "$($_.displayName)" -eq 'Password Rule Settings' }) | Select-Object -First 1
            if (-not $o) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'keine eigenen Kennwortregeln gesetzt (Standard: lokales AD nicht eingebunden, keine eigene Verbotsliste)' } }
            $v = @{}; foreach ($x in @($o.values)) { $v["$($x.name)"] = "$($x.value)" }
            $on = ($v['EnableBannedPasswordCheckOnPremises'] -eq 'True')
            $mode = "$($v['BannedPasswordCheckOnPremisesMode'])"
            $custom = @("$($v['BannedPasswordList'])" -split "`t" | Where-Object { $_ }).Count
            $d = "lokales AD: $(if ($on) { 'an' } else { 'aus' }), Modus $(if ($mode) { $mode } else { '-' }), eigene Verbotsliste: $custom Begriff(e). Ob die Agenten auf den Domaenencontrollern laufen, wird nicht geprueft"
            if ($on -and $mode -eq 'Enforce') { @{ Status = 'OK'; Count = 0; Detail = $d } } else { @{ Status = 'Abweichung'; Count = 0; Detail = $d } }
        } }
    @{ Id = 'A29'; Area = 'Entra'; Sev = 'Niedrig'; Title = 'Lizenz fuer Privileged Identity Management (PIM) vorhanden'; Facts = @('skus'); Min = $false
        Eval = { param($F, $B)
            $pl = @($F.skus | ForEach-Object { @($_.servicePlans) } | Where-Object { "$($_.provisioningStatus)" -eq 'Success' } | ForEach-Object { "$($_.servicePlanName)" })
            if ($pl -contains 'AAD_PREMIUM_P2') { @{ Status = 'Info'; Count = 1; Detail = 'Entra ID P2 vorhanden - PIM (zeitlich begrenzte Admin-Rechte) waere nutzbar' } }
            else { @{ Status = 'NichtPruefbar'; Reason = 'Lizenz'; Detail = 'keine Entra ID P2 - PIM nicht nutzbar' } }
        } }
    @{ Id = 'A30'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Riskante Anmeldungen von Administratoren sind per Conditional Access blockiert'; Facts = @('ca', 'skus'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaBlocks $P) -and (@($P.conditions.signInRiskLevels | Where-Object { $_ }).Count -gt 0) -and ((Test-HUSecCaTargetsAll $P) -or (@($P.conditions.users.includeRoles | Where-Object { $_ }).Count -gt 0)) } }
        Eval = { param($F, $B)
            $pl = @($F.skus | ForEach-Object { @($_.servicePlans) } | Where-Object { "$($_.provisioningStatus)" -eq 'Success' } | ForEach-Object { "$($_.servicePlanName)" })
            if ($pl -notcontains 'AAD_PREMIUM_P2') { return @{ Status = 'NichtPruefbar'; Reason = 'Lizenz'; Detail = 'Risikobasierte Richtlinien brauchen Entra ID P2' } }
            $hit = @($F.ca | Where-Object {
                    "$($_.state)" -eq 'enabled' -and (Test-HUSecCaBlocks $_) -and
                    (@($_.conditions.signInRiskLevels | Where-Object { $_ }).Count -gt 0) -and
                    ((Test-HUSecCaTargetsAll $_) -or (@($_.conditions.users.includeRoles | Where-Object { $_ }).Count -gt 0))
                }).Count
            if ($hit) { @{ Status = 'OK'; Count = $hit; Detail = "$hit aktive Blockier-Richtlinie(n) nach Anmelderisiko" } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Richtlinie, die riskante Anmeldungen von Admins blockiert' } }
        } }
    @{ Id = 'A31'; Area = 'Entra'; Sev = 'Niedrig'; Title = 'Partner-Organisationen (Cross-Tenant-Zugriff) sind bekannt'; Facts = @('xtpart'); Min = $false; ItemsLabel = 'Partner'; ItemsSort = 'TenantId'
        Items = { param($F, $B)
            foreach ($p in @($F.xtpart)) {
                # leere Felder = Partner nutzt die Standardeinstellung des Tenants (nichts Eigenes hinterlegt)
                $in = "$($p.b2bCollaborationInbound.usersAndGroups.accessType)"; $out = "$($p.b2bCollaborationOutbound.usersAndGroups.accessType)"; $mfa = $p.inboundTrust.isMfaAccepted
                [pscustomobject]@{ TenantId = "$($p.tenantId)"; B2BEingehend = $(if ($in) { $in } else { 'Standard' }); B2BAusgehend = $(if ($out) { $out } else { 'Standard' }); MfaAkzeptiert = $(if ($null -eq $mfa) { 'Standard' } else { "$mfa" }) }
            }
        }
        Eval = { param($F, $B)
            $n = @($F.xtpart).Count
            @{ Status = 'Info'; Count = $n; Detail = "$n konfigurierte Partner-Organisation(en). Bestehende Verbindungen nur entfernen, wenn keine Zusammenarbeit mehr besteht (z. B. Lizenzpartner)" }
        } }
    @{ Id = 'A33'; Area = 'SharePoint'; Sev = 'Mittel'; Title = 'Externe Freigabe ohne Anmeldung (anonyme Links) ist ausgeschaltet'; Facts = @('spset'); Min = $false
        Eval = { param($F, $B)
            $c = "$($F.spset.sharingCapability)"
            if (-not $c) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld sharingCapability nicht gefunden'; Complete = $false } }
            if ($c -eq 'externalUserAndGuestSharing') { return @{ Status = 'Abweichung'; Count = 1; Detail = 'Freigabe an Jeden per Link ohne Anmeldung ist erlaubt' } }
            if ($c -in 'disabled', 'externalUserSharingOnly', 'existingExternalUserSharingOnly') { return @{ Status = 'OK'; Count = 0; Detail = "Externe Freigabe: $c (keine anonymen Links)" } }
            return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = "unbekannter Wert fuer sharingCapability: $c"; Complete = $false }
        } }
    @{ Id = 'A32'; Area = 'Entra'; Sev = 'Niedrig'; Title = 'Microsoft Secure Score (Fortschritt der Sicherheitsempfehlungen)'; Facts = @('score'); Min = $false
        Eval = { param($F, $B)
            $s = $F.score
            if (-not $s -or -not $s.PSObject.Properties['currentScore'] -or -not $s.PSObject.Properties['maxScore'] -or [double]$s.maxScore -le 0) {
                return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'kein Secure Score geliefert'; Complete = $false }
            }
            $pc = [math]::Round(100 * [double]$s.currentScore / [double]$s.maxScore, 1)
            @{ Status = 'Info'; Count = [int][math]::Round($pc); Detail = "$([math]::Round([double]$s.currentScore, 1)) von $([math]::Round([double]$s.maxScore, 1)) Punkten ($pc %)" }
        } }
    @{ Id = 'A26'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Keine offenen Gaesteinladungen (nie angenommen)'; Facts = @('guestsx'); Min = $false; ItemsLabel = 'Einladungen'; ItemsSort = 'Eingeladen'
        Items = { param($F, $B)
            $now = Get-Date
            foreach ($g in @($F.guestsx | Where-Object { "$($_.externalUserState)" -eq 'PendingAcceptance' })) {
                $d = $null; try { if ($g.createdDateTime) { $d = [datetime]$g.createdDateTime } } catch { }
                [pscustomobject]@{ Anzeigename = "$($g.displayName)"; Mail = "$($g.mail)"; Eingeladen = $(if ($d) { $d.ToString('yyyy-MM-dd') } else { '' }); TageOffen = $(if ($d) { [int]($now - $d).TotalDays } else { '' }) }
            }
        }
        Eval = { param($F, $B)
            $all = @($F.guestsx)
            if (-not $all.Count) { return @{ Status = 'OK'; Count = 0; Detail = 'keine Gastkonten' } }
            if (-not @($all | Where-Object { $_.PSObject.Properties['externalUserState'] -and "$($_.externalUserState)" }).Count) {
                return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Einladungsstatus der Gaeste wird nicht geliefert'; Complete = $false }
            }
            $max = [int]$B.maxAgeDays
            $pend = @($all | Where-Object { "$($_.externalUserState)" -eq 'PendingAcceptance' })
            $old = @($pend | Where-Object { $d = $null; try { $d = [datetime]$_.createdDateTime } catch { }; $d -and ((Get-Date) - $d).TotalDays -gt $max }).Count
            if ($old) { @{ Status = 'Abweichung'; Count = $old; Detail = "$($pend.Count) offene Einladung(en), davon $old aelter als $max Tage" } }
            else { @{ Status = 'OK'; Count = 0; Detail = "$($pend.Count) offene Einladung(en), keine aelter als $max Tage" } }
        } }
    @{ Id = 'C02'; Area = 'Teams'; Sev = 'Hoch'; Title = 'Gastkonten im Tenant (externe Mitglieder in Teams und Gruppen)'; Facts = @('guestsx'); Min = $false; ItemsLabel = 'Gaeste'; ItemsSort = 'Anzeigename'
        Items = { param($F, $B)
            foreach ($g in @($F.guestsx)) {
                $d = $null; try { if ($g.createdDateTime) { $d = [datetime]$g.createdDateTime } } catch { }
                [pscustomobject]@{ Anzeigename = "$($g.displayName)"; Mail = "$($g.mail)"; Einladung = "$($g.externalUserState)"; Erstellt = $(if ($d) { $d.ToString('yyyy-MM-dd') } else { '' }) }
            }
        }
        Eval = { param($F, $B)
            $n = @($F.guestsx).Count
            @{ Status = 'Info'; Count = $n; Detail = "$n Gastkonto/Gastkonten. Nur Anzahl - welche Teams und Gruppen sie nutzen, wird mit dem Paket Teams und Gruppen geprueft" }
        } }
    @{ Id = 'V11'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Geraetecode-Flow ist per Richtlinie blockiert'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaTargetsAll $P) -and (Test-HUSecCaBlocks $P) -and ("$($P.conditions.authenticationFlows.transferMethods)" -like '*deviceCodeFlow*') } }
        Eval = { param($F, $B)
            $hit = @($F.ca | Where-Object {
                    "$($_.state)" -eq 'enabled' -and (Test-HUSecCaTargetsAll $_) -and (Test-HUSecCaBlocks $_) -and
                    ("$($_.conditions.authenticationFlows.transferMethods)" -like '*deviceCodeFlow*')
                }).Count
            if ($hit) { @{ Status = 'OK'; Count = $hit; Detail = "$hit aktive Richtlinie(n)" } } else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Blockier-Richtlinie fuer den Geraetecode-Flow' } }
        } }
    @{ Id = 'A21'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Zugriff ueber das alte MSOL-PowerShell ist blockiert'; Facts = @('authzbl'); Min = $false
        Eval = { param($F, $B)
            if (-not $F.authzbl.PSObject.Properties['blockMsolPowerShell']) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld blockMsolPowerShell nicht gefunden'; Complete = $false } }
            if ([bool]$F.authzbl.blockMsolPowerShell) { @{ Status = 'OK'; Count = 0; Detail = 'MSOL-PowerShell blockiert' } }
            else { @{ Status = 'Abweichung'; Count = 1; Detail = 'MSOL-PowerShell ist erlaubt (Skripte vorher auf Microsoft Graph umstellen)' } }
        } }
    @{ Id = 'A22'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Benutzer duerfen keine Apps, Sicherheitsgruppen oder Tenants anlegen'; Facts = @('authz'); Min = $false
        Eval = { param($F, $B)
            $perm = $F.authz.defaultUserRolePermissions
            if (-not $perm) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld defaultUserRolePermissions nicht gefunden'; Complete = $false } }
            $allowed = New-Object System.Collections.Generic.List[string]
            $unknown = New-Object System.Collections.Generic.List[string]
            foreach ($item in @(@{ N = 'allowedToCreateApps'; T = 'Apps registrieren' }, @{ N = 'allowedToCreateSecurityGroups'; T = 'Sicherheitsgruppen anlegen' }, @{ N = 'allowedToCreateTenants'; T = 'Tenants anlegen' })) {
                $prop = $perm.PSObject.Properties[$item.N]
                if (-not $prop -or $null -eq $prop.Value) { $unknown.Add($item.T) } elseif ([bool]$prop.Value) { $allowed.Add($item.T) }
            }
            if ($allowed.Count) { $d = "Benutzer duerfen: $($allowed -join ', ')"; if ($unknown.Count) { $d += " (nicht lesbar: $($unknown -join ', '))" }; return @{ Status = 'Abweichung'; Count = $allowed.Count; Detail = $d } }
            if ($unknown.Count) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = "nicht lesbar: $($unknown -join ', ')"; Complete = $false } }
            @{ Status = 'OK'; Count = 0; Detail = 'alle drei Rechte fuer Benutzer aus' }
        } }
    @{ Id = 'A23'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Gaeste muessen sich regelmaessig neu anmelden (Sitzungsdauer)'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) $P.conditions.users.includeGuestsOrExternalUsers -and $P.sessionControls.signInFrequency -and [bool]$P.sessionControls.signInFrequency.isEnabled } }
        Eval = { param($F, $B)
            $hit = @($F.ca | Where-Object { $_.conditions.users.includeGuestsOrExternalUsers -and $_.sessionControls.signInFrequency -and [bool]$_.sessionControls.signInFrequency.isEnabled })
            $on = @($hit | Where-Object { "$($_.state)" -eq 'enabled' }).Count
            $rep = @($hit | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count
            if ($on) { @{ Status = 'OK'; Count = $on; Detail = "$on aktive Richtlinie(n) mit Anmeldehaeufigkeit fuer Gaeste" } }
            elseif ($rep) { @{ Status = 'Abweichung'; Count = 0; Detail = 'nur im Berichtsmodus' } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine Richtlinie mit Anmeldehaeufigkeit fuer Gaeste' } }
        } }
    @{ Id = 'A24'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Anmeldungen sind per Standort (Geoblock) eingeschraenkt'; Facts = @('ca'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B)
            foreach ($pol in @($F.ca | Where-Object { $_.conditions.locations -and (@($_.conditions.locations.includeLocations).Count -gt 0) })) {
                $blocks = Test-HUSecCaBlocks $pol
                $inc = @($pol.conditions.locations.includeLocations)
                $ex = @($pol.conditions.locations.excludeLocations | Where-Object { $_ }).Count
                $isGeo = Test-HUSecCaGeoblock $pol
                $zaehlt = ($isGeo -and "$($pol.state)" -eq 'enabled')
                $why = if ($zaehlt) { '' } elseif (-not $blocks) { 'blockiert nicht' } elseif (-not $isGeo) { 'Spezialrichtlinie (kein Geoblock)' } else { "Status $($pol.state)" }
                [pscustomobject]@{ Richtlinie = "$($pol.displayName)"; Status = "$($pol.state)"; Aktion = $(if ($blocks) { 'Blockieren' } else { (@($pol.grantControls.builtInControls) -join ', ') })
                    OrteEingeschlossen = $(if ($inc -contains 'All') { 'Alle' } else { "$($inc.Count) Orte" }); OrteAusgenommen = $ex; ZaehltFuerRegel = $(if ($zaehlt) { 'Ja' } else { 'Nein' }); Grund = $why }
            }
        }
        Eval = { param($F, $B)
            $hit = @($F.ca | Where-Object { Test-HUSecCaGeoblock $_ })
            $on = @($hit | Where-Object { "$($_.state)" -eq 'enabled' }).Count
            $rep = @($hit | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count
            if ($on) { @{ Status = 'OK'; Count = $on; Detail = "$on aktive Geoblock-Richtlinie(n) (welche Laender, wird nicht geprueft)" } }
            elseif ($rep) { @{ Status = 'Abweichung'; Count = 0; Detail = 'Geoblock nur im Berichtsmodus' } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Geoblock-Richtlinie' } }
        } }
    @{ Id = 'V1'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'Notfallkonten sind von allen aktiven blockierenden oder einschraenkenden Conditional-Access-Richtlinien ausgenommen'; Facts = @('ca'); Min = $true; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B)
            foreach ($pol in @($F.ca | Where-Object { Test-HUSecCaHitsBreakGlass $_ })) {
                $exU = @($pol.conditions.users.excludeUsers | Where-Object { $_ }).Count
                $exG = @($pol.conditions.users.excludeGroups | Where-Object { $_ }).Count
                $who = if (Test-HUSecCaTargetsAll $pol) { 'Alle Benutzer' } else { "$(@($pol.conditions.users.includeRoles | Where-Object { $_ }).Count) Admin-Rollen" }
                [pscustomobject]@{ Richtlinie = "$($pol.displayName)"; GiltFuer = $who; AusgenommeneBenutzer = $exU; AusgenommeneGruppen = $exG
                    Ergebnis = $(if ($exU + $exG) { 'hat Ausnahme' } else { 'KEINE Ausnahme' })
                    __ExU = @($pol.conditions.users.excludeUsers | Where-Object { $_ -and "$_" -ne 'GuestsOrExternalUsers' }); __ExG = @($pol.conditions.users.excludeGroups | Where-Object { $_ }) }
            }
        }
        Eval = { param($F, $B)
            $pols = @($F.ca | Where-Object { Test-HUSecCaHitsBreakGlass $_ })
            if (-not $pols.Count) { return @{ Status = 'Info'; Count = 0; Detail = 'keine aktive blockierende oder einschraenkende Richtlinie fuer alle Benutzer oder Admin-Rollen' } }
            $without = @($pols | Where-Object { -not (@(@($_.conditions.users.excludeUsers) + @($_.conditions.users.excludeGroups) | Where-Object { $_ }).Count) }).Count
            if ($without) { @{ Status = 'Abweichung'; Count = $without; Detail = "$without von $($pols.Count) aktiven Richtlinien (alle Benutzer oder Admin-Rollen) ohne jede Ausnahme" } }
            else { @{ Status = 'OK'; Count = 0; Detail = "alle $($pols.Count) aktiven Richtlinien (alle Benutzer oder Admin-Rollen) haben eine Ausnahme - ob es die Notfallkonten sind und in allen dieselben, bitte selbst pruefen" } }
        } }
)

# Kurzerklaerung je Regel (Warum wird das geprueft?) fuer das Detailfenster
$script:HUSecWhy = @{
    A01 = 'Richtlinien im Berichtsmodus schuetzen nicht. Geprueft wird nur, dass mindestens eine Richtlinie aktiv ist (Sollwert minEnabled, je Tenant aenderbar). Welche Richtlinien aktiv sein sollen, prueft diese Regel nicht.'
    A04 = 'Alte Protokolle (POP, IMAP, SMTP-Basic) umgehen MFA. Eine Richtlinie sollte sie blockieren.'
    A08 = 'Zu viele Global Administratoren vergroessern die Angriffsflaeche, zu wenige gefaehrden die Erreichbarkeit. Soll: 2 bis 4.'
    A14 = 'Gaeste sollen im Verzeichnis moeglichst wenig sehen koennen (eingeschraenkteste Rolle).'
    A15 = 'Wer Gaeste einladen darf, bestimmt, wer externe Konten anlegen kann.'
    A17 = 'Duerfen Benutzer Apps selbst zustimmen, kann eine Phishing-App Zugriff auf Daten bekommen.'
    V5  = 'Ohne MFA-Grundschutz reicht ein gestohlenes Passwort. Entweder Security Defaults oder eine MFA-Richtlinie fuer alle Benutzer.'
    A02 = 'Administratorkonten sind das beliebteste Angriffsziel. Ohne MFA reicht ein gestohlenes Passwort fuer Vollzugriff.'
    A03 = 'Gast-Konten werden oft schwach geschuetzt. MFA soll auch fuer sie gelten.'
    A09 = 'Ein Administratorkonto ohne MFA-Registrierung ist ein Einfallstor, auch wenn eine MFA-Richtlinie besteht. Notfallkonten sind bewusst ohne MFA.'
    V15 = 'Sichtbare Namen in Admin-Berichten (Nutzung, Anmeldungen) geben Schuelerdaten an alle weiter, die diese Berichte sehen.'
    A19 = 'Laeuft das letzte Secret oder Zertifikat einer App ab, faellt die Funktion aus (z.B. Berichte, Mails, Anmeldung).'
    E01 = 'Ohne zugewiesene Compliance-Richtlinie gilt jedes Geraet als konform (je nach Einstellung).'
    E03 = 'Viele nicht konforme Geraete deuten auf fehlende Updates, Verschluesselung oder Schutz hin. Grenze in baseline.json aenderbar.'
    E04 = 'Unverschluesselte Notebooks gefaehrden Schuelerdaten bei Verlust. Grenze in baseline.json aenderbar.'
    C02 = 'Gaeste in Teams mit Minderjaehrigen sind heikel. Hier zunaechst nur die Zahl der Gastkonten, damit Aenderungen auffallen.'
    A25 = 'Ohne diese Sperre koennen normale Benutzer (auch Schueler) die Adminportale oeffnen und viele Verzeichnisdaten lesen. Gesucht wird eine aktive Richtlinie fuer alle Benutzer mit Blockieren, Ziel Microsoft-Adminportale und Ausnahme fuer Administratoren (Baseline 1.14).'
    A27 = 'Konten mit Admin-Rolle, die niemand mehr nutzt, sind ein leichtes Ziel. Gezaehlt werden aktive Konten mit direkter Rolle ohne Anmeldung seit mehr als 90 Tagen (Baseline 1.10). Gruppen- und PIM-Rollen sind nicht sichtbar.'
    A28 = 'Entra Kennwortschutz verbietet bekannte schwache Kennwoerter auch im lokalen AD. Geprueft wird nur die Einstellung im Tenant (an, Modus Erzwingen); ob der Agent auf den Domaenencontrollern laeuft, sieht die App nicht (Baseline 1.1).'
    A29 = 'PIM vergibt Admin-Rechte nur zeitlich begrenzt und mit Genehmigung. Die Regel zeigt nur, ob die Lizenz vorhanden ist (Baseline 1.3).'
    A30 = 'Wird ein Admin-Konto bei riskanter Anmeldung nicht blockiert, bleibt ein gestohlenes Kennwort nutzbar. Braucht Entra ID P2 (Baseline 1.9).'
    A31 = 'Partner-Organisationen duerfen je nach Einstellung auf den Tenant zugreifen. Die Liste zeigt die konfigurierten Partner mit ihrer Tenant-ID (Baseline 1.6). Nicht ohne Not entfernen.'
    A33 = 'Anonyme Links ohne Anmeldung lassen sich weiterleiten, der Zugriff ist dann nicht mehr nachvollziehbar. Ob Links ein Ablaufdatum haben, liefert Graph nicht und wird nicht geprueft (Baseline 3.2).'
    A32 = 'Der Secure Score von Microsoft zeigt in Prozent, wie viele Sicherheitsempfehlungen umgesetzt sind. Verlauf ueber den Katalog-Verlauf vergleichbar (Baseline 3.1).'
    A26 = 'Gaeste, die ihre Einladung nie angenommen haben, sind totes Gewicht und koennen spaeter von Dritten uebernommen werden (Mailadresse faellt weg oder wird neu vergeben). Laut Baseline 1.12 entfernen. Sollwert: Einladungen aelter als 30 Tage.'
    A21 = 'Das alte MSOL-PowerShell wird nicht mehr unterstuetzt und umgeht moderne Schutzfunktionen. Blockieren, sobald keine Skripte es mehr nutzen.'
    A22 = 'Wenn jeder Benutzer Apps, Sicherheitsgruppen oder neue Tenants anlegen darf, entstehen unkontrollierte Zugriffe und Wildwuchs.'
    A23 = 'Gaeste bleiben sonst lange angemeldet. Eine Anmeldehaeufigkeit zwingt sie, sich regelmaessig neu zu authentifizieren.'
    A24 = 'Anmeldungen aus Laendern, in denen niemand arbeitet, sind fast immer Angriffe. Eine Geoblock-Richtlinie (Blockieren mit Standortbedingung, ohne Spezialzweck wie Geraetecode-Flow) blockiert sie. Welche Laender erlaubt sind, wird nicht geprueft.'
    V1  = 'Notfallkonten muessen von jeder Richtlinie ausgenommen sein, sonst sperrt eine fehlerhafte Richtlinie alle aus. Geprueft werden aktive Richtlinien fuer alle Benutzer oder Admin-Rollen, die blockieren oder etwas verlangen (MFA, Geraet, Nutzungsbedingungen ...): jede braucht mindestens eine Ausnahme. Reine Sitzungs- und Berichtsrichtlinien brauchen keine (Microsoft Learn, Notfallzugriffskonten). Ob das Konto selbst einen Passkey/FIDO2-Schluessel hat, wird nicht gelesen. Ob es die Notfallkonten sind und in allen dieselben, wird nicht geprueft.'
    V11 = 'Der Geraetecode-Flow wird fuer Phishing missbraucht und selten gebraucht. Er sollte per Richtlinie blockiert sein.'
}
function Get-HUSecWhy([string]$RuleId) { if ($script:HUSecWhy.ContainsKey($RuleId)) { return $script:HUSecWhy[$RuleId] } return '' }

function Get-HUSecRules { return @($script:HUSecRules | ForEach-Object { [pscustomobject]$_ }) }

# ============================================================================
# Lauf
# ============================================================================
function Invoke-HUSecCatalog {
    <#
    .SYNOPSIS
        Wertet die Regeln fuer einen Tenant aus. Gibt je Regel ein Ergebnis zurueck (nie eine leere Liste = OK).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [string[]]$RuleIds = @(), $Context = $null, [datetime]$Now = (Get-Date))
    $ctx = if ($Context) { $Context } else { New-HUSecContext -TenantKey $TenantKey -Settings $Settings }
    $rules = @(Get-HUSecRules | Where-Object { -not $RuleIds.Count -or $RuleIds -contains $_.Id })
    $bl = Get-HUSecBaseline -TenantKey $TenantKey -Rules (Get-HUSecRules)
    $exc = @(Get-HUSecExceptions)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rules) {
        $facts = @{}
        $fail = $null
        foreach ($k in $r.Facts) {
            $fact = Get-HUSecFact -Ctx $ctx -Key $k
            if (-not $fact.Ok) { $fail = $fact; break }
            $facts[$k] = $fact.Data
        }
        if ($fail) { $out.Add((New-HUSecResult -Rule $r -Tenant $TenantKey -Status 'NichtPruefbar' -Reason $fail.Reason -Detail $fail.Detail -Complete $false)); continue }
        $b = if ($bl.Values.ContainsKey($r.Id)) { $bl.Values[$r.Id] } else { @{} }
        # In den Sollwerten abgeschaltet (enabled = false): nur Info; bei Regeln mit Mindeststandard (Min) wirkt das nicht
        if (-not $r.Min -and $b.ContainsKey('enabled') -and $b.enabled -eq $false) {
            $out.Add((New-HUSecResult -Rule $r -Tenant $TenantKey -Status 'Info' -Detail 'in den Sollwerten abgeschaltet')); continue
        }
        try {
            $e = & $r.Eval $facts $b
            $cnt = if ($e.ContainsKey('Count')) { $e.Count } else { $null }
            $cmp = if ($e.ContainsKey('Complete')) { [bool]$e.Complete } else { $true }
            $rs = if ($e.ContainsKey('Reason')) { "$($e.Reason)" } else { '' }
            $res = New-HUSecResult -Rule $r -Tenant $TenantKey -Status $e.Status -Reason $rs -Count $cnt -Detail "$($e.Detail)" -Complete $cmp
            if ($res.Status -eq 'Abweichung') {
                $x = Find-HUSecException $res $exc $Now
                if ($x) { $res.Status = 'Ausnahme'; $res.ExceptionId = "$($x.id)" }
            }
            $out.Add($res)
        }
        catch { $out.Add((New-HUSecResult -Rule $r -Tenant $TenantKey -Status 'Fehler' -Reason 'Technisch' -Detail 'Fehler bei der Auswertung der Regel' -Complete $false)) }
    }
    foreach ($m in $bl.Errors) { $out.Add([pscustomobject]@{ RuleId = '-'; Area = 'Katalog'; Title = 'Sollwerte'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'Fehler'; Reason = 'Technisch'; Count = $null; Detail = $m; Complete = $false; ExceptionId = '' }) }
    return $out.ToArray()
}

# ============================================================================
# Betroffene Objekte auf Anforderung (nur Anzeige, wird nicht gespeichert und nicht in den Verlauf geschrieben)
# ============================================================================
function Get-HUSecItemsLabel([string]$RuleId) {
    $rule = @(Get-HUSecRules | Where-Object { $_.Id -eq $RuleId })[0]
    if ($rule -and $rule.PSObject.Properties['ItemsLabel']) { return "$($rule.ItemsLabel)" }
    return 'Konten'
}

function Get-HUSecItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$RuleId, $Context = $null)
    $rule = @(Get-HUSecRules | Where-Object { $_.Id -eq $RuleId })[0]
    if (-not $rule -or -not $rule.PSObject.Properties['Items']) { return @() }
    $ctx = if ($Context) { $Context } else { New-HUSecContext -TenantKey $TenantKey -Settings $Settings }
    $facts = @{}
    foreach ($k in $rule.Facts) {
        $fact = Get-HUSecFact -Ctx $ctx -Key $k
        if (-not $fact.Ok) { throw "Daten nicht lesbar ($($fact.Reason)): $($fact.Detail)" }
        $facts[$k] = $fact.Data
    }
    $bl = Get-HUSecBaseline -TenantKey $TenantKey -Rules (Get-HUSecRules)
    $b = if ($bl.Values.ContainsKey($RuleId)) { $bl.Values[$RuleId] } else { @{} }
    $items = @(& $rule.Items $facts $b)
    if ($rule.PSObject.Properties['ItemsSignIn'] -and $rule.ItemsSignIn) {
        # Rollen je Konto (nur direkte, aktive Zuweisungen; keine Gruppen-/PIM-eligible-Rollen)
        $roleMap = @{}; $roleErr = $false
        try {
            $defs = @{}
            foreach ($d in @(Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "/roleManagement/directory/roleDefinitions?`$select=id,displayName" -All)) { $defs["$($d.id)"] = "$($d.displayName)" }
            foreach ($a in @(Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "/roleManagement/directory/roleAssignments?`$select=principalId,roleDefinitionId" -All)) {
                $nm = if ($defs.ContainsKey("$($a.roleDefinitionId)")) { $defs["$($a.roleDefinitionId)"] } else { "$($a.roleDefinitionId)" }
                if (-not $roleMap.ContainsKey("$($a.principalId)")) { $roleMap["$($a.principalId)"] = New-Object System.Collections.Generic.List[string] }
                if (-not $roleMap["$($a.principalId)"].Contains($nm)) { $roleMap["$($a.principalId)"].Add($nm) }
            }
        } catch { $roleErr = $true }
        foreach ($i in $items) {
            $rl = if ($roleErr) { '(nicht lesbar)' } elseif ($roleMap.ContainsKey("$($i.__Id)")) { (($roleMap["$($i.__Id)"] | Sort-Object) -join ', ') } else { '(Gruppe/PIM)' }
            $i | Add-Member -NotePropertyName Rollen -NotePropertyValue $rl -Force
        }
        $n = 0
        foreach ($i in $items) {
            $last = ''; $act = ''
            if ($n -lt 60 -and "$($i.__Id)") {
                try {
                    $u = Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "/users/$($i.__Id)?`$select=signInActivity,accountEnabled"
                    $act = if ($u.PSObject.Properties['accountEnabled'] -and $null -ne $u.accountEnabled) { if ($u.accountEnabled) { 'Ja' } else { 'Nein' } } else { '' }
                    $s = $u.signInActivity
                    $v = if ($s -and $s.PSObject.Properties['lastSuccessfulSignInDateTime'] -and $s.lastSuccessfulSignInDateTime) { $s.lastSuccessfulSignInDateTime } elseif ($s) { $s.lastSignInDateTime } else { $null }
                    $last = if ($v) { ([datetime]$v).ToString('yyyy-MM-dd') } else { 'nie' }
                } catch { $last = '(nicht lesbar)' }
            }
            $i | Add-Member -NotePropertyName Aktiv -NotePropertyValue $act -Force
            $i | Add-Member -NotePropertyName LetzteAnmeldung -NotePropertyValue $last -Force
            $n++
        }
    }
    # Namen der ausgenommenen Benutzer/Gruppen (nur Anzeige, nicht gespeichert; je Objekt eine Abfrage, hoechstens 40)
    if (@($items | Where-Object { $_.PSObject.Properties['__ExU'] }).Count) {
        $nameCache = @{}; $budget = 40
        $resolve = {
            param([string]$Kind, [string]$Id)
            $key = "$Kind/$Id"
            if ($nameCache.ContainsKey($key)) { return $nameCache[$key] }
            if ($script:__secBudget -le 0) { return '(nicht abgefragt)' }
            $script:__secBudget--
            try {
                if ($Kind -eq 'users') { $o = Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "/users/$Id`?`$select=userPrincipalName"; $nm = "$($o.userPrincipalName)" }
                else { $o = Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "/groups/$Id`?`$select=displayName"; $nm = "Gruppe $($o.displayName)" }
                if (-not $nm -or $nm -eq 'Gruppe ') { $nm = '(nicht lesbar)' }
            } catch { $nm = '(nicht lesbar)' }
            $nameCache[$key] = $nm
            return $nm
        }
        $script:__secBudget = $budget
        foreach ($i in $items) {
            $names = @()
            foreach ($id in @($i.__ExU)) { $names += (& $resolve 'users' "$id") }
            foreach ($id in @($i.__ExG)) { $names += (& $resolve 'groups' "$id") }
            $i | Add-Member -NotePropertyName Ausnahmen -NotePropertyValue $(if ($names.Count) { ($names -join ', ') } else { '-' }) -Force
        }
    }
    $sortKey = if ($rule.PSObject.Properties['ItemsSort']) { "$($rule.ItemsSort)" } else { 'Anmeldename' }
    return @($items | Sort-Object $sortKey | Select-Object -Property * -ExcludeProperty __Id, __ExU, __ExG)
}

# ============================================================================
# Matrix (Regeln x Tenants)
# ============================================================================
$script:HUSecSevRank = @{ 'Kritisch' = 0; 'Hoch' = 1; 'Mittel' = 2; 'Niedrig' = 3 }

function Get-HUSecMatrix {
    param([object[]]$Results = @(), [string[]]$Keys = @())
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in (Get-HUSecRules)) {
        $cells = @{}
        foreach ($k in $Keys) { $cells[$k] = @($Results | Where-Object { $_.RuleId -eq $r.Id -and $_.Tenant -eq $k }) | Select-Object -First 1 }
        $got = @($Keys | Where-Object { $cells[$_] })
        $sig = @($got | ForEach-Object { "$($cells[$_].Status)/$($cells[$_].Reason)" } | Sort-Object -Unique)
        $dev = [bool](@($got | Where-Object { $cells[$_].Status -in 'Abweichung', 'Fehler' }).Count)
        $rows.Add([pscustomobject]@{ RuleId = $r.Id; Area = $r.Area; Title = $r.Title; Sev = $r.Sev; Cells = $cells; Dev = $dev; Diff = ($sig.Count -gt 1) })
    }
    return @($rows | Sort-Object @{ Expression = { $script:HUSecSevRank["$($_.Sev)"] } }, RuleId)
}

# "x von y geprueft" je Tenant (Abweichung/OK/Ausnahme zaehlen als geprueft)
function Get-HUSecCoverage {
    param([object[]]$Results = @(), [Parameter(Mandatory)][string]$Key)
    $mine = @($Results | Where-Object { $_.Tenant -eq $Key -and $_.RuleId -ne '-' })
    $ok = @($mine | Where-Object { $_.Status -in 'OK', 'Abweichung', 'Ausnahme' }).Count
    return [pscustomobject]@{ Checked = $ok; Total = $mine.Count }
}

# Ampel je Tenant: Rot = ab 10 nicht erfuellte Regeln (Abweichung oder Fehler), Gelb = 1 bis 9, Gruen = keine, Grau = nichts geprueft
function Get-HUSecLight {
    param([object[]]$Results = @(), [Parameter(Mandatory)][string]$Key)
    $sevOf = @{}; foreach ($r in (Get-HUSecRules)) { $sevOf[$r.Id] = "$($r.Sev)" }
    $mine = @($Results | Where-Object { $_.Tenant -eq $Key -and $_.RuleId -ne '-' })
    $checked = @($mine | Where-Object { $_.Status -in 'OK', 'Abweichung', 'Ausnahme' })
    $ok = @($checked | Where-Object { $_.Status -in 'OK', 'Ausnahme' }).Count
    $dev = @($mine | Where-Object { $_.Status -in 'Abweichung', 'Fehler' })
    $by = @{ Kritisch = 0; Hoch = 0; Mittel = 0; Niedrig = 0 }
    foreach ($d in $dev) { $sv = "$($sevOf[$d.RuleId])"; if ($by.ContainsKey($sv)) { $by[$sv]++ } }
    $unchecked = @($mine | Where-Object { $_.Status -eq 'NichtPruefbar' }).Count
    $color = if (-not $mine.Count -or (-not $checked.Count -and -not $dev.Count)) { 'Grau' }
    elseif ($dev.Count -ge 10) { 'Rot' } elseif ($dev.Count -gt 0) { 'Gelb' } else { 'Gruen' }
    return [pscustomobject]@{ Color = $color; Ok = $ok; Checked = $checked.Count; Deviations = $dev.Count; BySev = $by; NotCheckable = $unchecked }
}

# ============================================================================
# Verlauf (nur Status und Zahlen)
# ============================================================================
function Save-HUSecSnapshot {
    param([Parameter(Mandatory)][object[]]$Results, [int]$KeepMonths = 24, [datetime]$Now = (Get-Date))
    $dir = Join-Path (Get-HUSecPath) 'verlauf'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rows = @($Results | Sort-Object Tenant, RuleId | ForEach-Object {
            [pscustomobject]@{ ruleId = $_.RuleId; tenant = $_.Tenant; status = $_.Status; reason = $_.Reason; count = $_.Count; exceptionId = $_.ExceptionId }
        })
    $snap = [pscustomobject]@{ version = 1; time = $Now.ToUniversalTime().ToString('o'); rows = $rows }
    $f = Join-Path $dir ("{0}.json" -f $Now.ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    Write-HUSecJson $f $snap
    $limit = $Now.AddMonths(-$KeepMonths)
    foreach ($old in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($old.LastWriteTime -lt $limit) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $f
}

# ============================================================================
# Soll-Stand (gespeicherter Stand, gegen den der taegliche Lauf vergleicht - nur Status und Zahlen)
# ============================================================================
function Save-HUSecReference {
    param([Parameter(Mandatory)][object[]]$Results, [datetime]$Now = (Get-Date))
    $rows = @($Results | Where-Object { $_.RuleId -and $_.RuleId -ne '-' } | Sort-Object Tenant, RuleId | ForEach-Object {
            [pscustomobject]@{ ruleId = $_.RuleId; tenant = $_.Tenant; status = $_.Status; reason = $_.Reason; count = $_.Count }
        })
    $snap = [pscustomobject]@{ version = 1; time = $Now.ToUniversalTime().ToString('o'); rows = $rows }
    $f = Join-Path (Get-HUSecPath) 'soll.json'
    Write-HUSecJson $f $snap
    Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'soll-verloren.json') -Force -ErrorAction SilentlyContinue   # neuer Soll-Stand: Zaehler neu
    return $f
}

function Get-HUSecReference {
    # $null = kein Soll-Stand gespeichert
    $j = $null
    try { $j = Read-HUSecJson (Join-Path (Get-HUSecPath) 'soll.json') } catch { return $null }
    if (-not $j -or -not $j.rows) { return $null }
    return $j
}

# Vergleich Ist gegen Soll. Nur Regeln, die in beiden Staenden pruefbar sind (OK/Abweichung/Ausnahme), zaehlen als Aenderung;
# NichtPruefbar/Fehler/Info sind keine Aenderung (sonst Meldungen bei jedem Abruffehler), sie werden nur gezaehlt.
function Compare-HUSecReference {
    param([Parameter(Mandatory)][object[]]$Results, [Parameter(Mandatory)]$Reference, [string[]]$Keys = @())
    $ruleOf = @{}; foreach ($r in (Get-HUSecRules)) { $ruleOf[$r.Id] = $r }
    $ref = @{}; foreach ($x in @($Reference.rows)) { $ref["$($x.tenant)|$($x.ruleId)"] = $x }
    $checkable = 'OK', 'Abweichung', 'Ausnahme'
    $changes = New-Object System.Collections.Generic.List[object]
    $unchecked = 0
    foreach ($r in @($Results | Where-Object { $_.RuleId -and $_.RuleId -ne '-' })) {
        if ($Keys.Count -and $Keys -notcontains $r.Tenant) { continue }
        $o = $ref["$($r.Tenant)|$($r.RuleId)"]
        if (-not $o) { continue }
        if ($r.Status -notin $checkable -or $o.status -notin $checkable) { if ($r.Status -notin $checkable) { $unchecked++ }; continue }
        $rule = $ruleOf[$r.RuleId]
        $kind = $null
        if ("$($o.status)" -ne "$($r.Status)") { $kind = 'Status' }
        elseif ($r.Status -eq 'Abweichung' -and "$($o.count)" -ne "$($r.Count)") { $kind = 'Anzahl' }
        if (-not $kind) { continue }
        $worse = ($r.Status -eq 'Abweichung' -and $o.status -ne 'Abweichung') -or ($kind -eq 'Anzahl' -and [int]"0$($r.Count)" -gt [int]"0$($o.count)")
        $changes.Add([pscustomobject]@{
                Tenant = "$($r.Tenant)"; RuleId = "$($r.RuleId)"; Title = "$($r.Title)"; Sev = "$($r.Sev)"; Kind = $kind; Worse = $worse
                Was = "$($o.status)"; Is = "$($r.Status)"; WasCount = $o.count; IsCount = $r.Count
            })
    }
    return [pscustomobject]@{ Changes = @($changes.ToArray() | Sort-Object @{ Expression = { -[int]$_.Worse } }, @{ Expression = { $script:HUSecSevRank["$($_.Sev)"] } }, Tenant, RuleId); Unchecked = $unchecked; Since = "$($Reference.time)" }
}

# "Pruefung verloren": eine Regel, die im Soll pruefbar war und an N Laeufen in Folge nicht pruefbar ist (Recht entzogen, Dienst weg),
# wird einmal gemeldet - sonst verschwindet ein Verstoss lautlos. Zaehler nur lokal (Regel-Id, Tenant, Anzahl), kein Objektbezug.
function Update-HUSecLost {
    param([Parameter(Mandatory)][object[]]$Results, [Parameter(Mandatory)]$Reference, [string[]]$Keys = @(), [int]$After = 3, [switch]$NoWrite)
    $checkable = 'OK', 'Abweichung', 'Ausnahme'
    $file = Join-Path (Get-HUSecPath) 'soll-verloren.json'
    $state = @{}
    try { $j = Read-HUSecJson $file; if ($j) { foreach ($x in @($j.rows)) { $state["$($x.key)"] = @{ runs = [int]$x.runs; reported = [bool]$x.reported } } } } catch { }
    $ref = @{}; foreach ($x in @($Reference.rows)) { $ref["$($x.tenant)|$($x.ruleId)"] = $x }
    $ruleOf = @{}; foreach ($r in (Get-HUSecRules)) { $ruleOf[$r.Id] = $r }
    $lost = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Results | Where-Object { $_.RuleId -and $_.RuleId -ne '-' })) {
        if ($Keys.Count -and $Keys -notcontains $r.Tenant) { continue }
        $key = "$($r.Tenant)|$($r.RuleId)"
        $o = $ref[$key]
        if (-not $o -or $r.Status -eq 'Info') { continue }
        $s = if ($state.ContainsKey($key)) { $state[$key] } else { @{ runs = 0; reported = $false } }
        if ($o.status -in $checkable -and $r.Status -notin $checkable) {
            $s.runs++
            if ($s.runs -ge $After -and -not $s.reported) {
                $s.reported = $true
                $lost.Add([pscustomobject]@{ Tenant = "$($r.Tenant)"; RuleId = "$($r.RuleId)"; Title = "$($r.Title)"; Sev = "$($r.Sev)"; Runs = $s.runs; Reason = "$($r.Reason)" })
            }
        }
        else { $s.runs = 0; $s.reported = $false }
        $state[$key] = $s
    }
    if (-not $NoWrite) {
        $rows = @($state.Keys | Sort-Object | Where-Object { $state[$_].runs -gt 0 } | ForEach-Object { [pscustomobject]@{ key = $_; runs = $state[$_].runs; reported = $state[$_].reported } })
        Write-HUSecJson $file ([pscustomobject]@{ version = 1; rows = $rows })
    }
    return @($lost.ToArray())
}

Export-ModuleMember -Function @(
    'Get-HUSecRules', 'Invoke-HUSecCatalog', 'New-HUSecContext', 'Get-HUSecFact', 'Invoke-HUSecFetch',
    'Get-HUSecExceptions', 'Add-HUSecException', 'Remove-HUSecException', 'Test-HUSecExceptionInput', 'Find-HUSecException',
    'Get-HUSecBaseline', 'Save-HUSecSnapshot', 'Save-HUSecReference', 'Get-HUSecReference', 'Compare-HUSecReference', 'Update-HUSecLost', 'Get-HUSecPath', 'Get-HUSecMatrix', 'Get-HUSecCoverage', 'Get-HUSecLight', 'Get-HUSecWhy', 'Get-HUSecItems', 'Get-HUSecItemsLabel'
)
