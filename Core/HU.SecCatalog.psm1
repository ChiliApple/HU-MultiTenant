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

# Anwendungsrechte auf Microsoft Graph, mit denen eine App den Tenant uebernehmen oder alle Daten lesen/aendern kann (A42)
$script:HUSecCriticalPerms = @(
    'RoleManagement.ReadWrite.Directory', 'AppRoleAssignment.ReadWrite.All', 'Application.ReadWrite.All', 'Directory.ReadWrite.All',
    'Domain.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess', 'Policy.ReadWrite.Authorization', 'User.ReadWrite.All',
    'UserAuthenticationMethod.ReadWrite.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Mail.ReadWrite', 'Mail.Send',
    'Files.ReadWrite.All', 'Sites.ReadWrite.All', 'Sites.FullControl.All', 'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementRBAC.ReadWrite.All',
    # lesend, aber alle Postfaecher bzw. alle Dateien (in Schulen mit Schuelerdaten) - Review 039
    'Mail.Read', 'Files.Read.All', 'Sites.Read.All'
)

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
    guestsx = @{ Ep = "/users?`$filter=userType%20eq%20'Guest'&`$select=id,displayName,mail,createdDateTime,externalUserState,externalUserStateChangeDateTime"; All = $true; Perms = @('User.Read.All'); Lic = '' }
    adminact = @{ Custom = 'adminact'; Perms = @('RoleManagement.Read.Directory', 'User.Read.All', 'AuditLog.Read.All'); Lic = 'P1' }
    pwdset = @{ Ep = '/groupSettings'; All = $true; Perms = @('Group.Read.All'); Lic = '' }
    xtpart = @{ Ep = '/policies/crossTenantAccessPolicy/partners'; All = $true; Perms = @('Policy.Read.All'); Lic = '' }
    score  = @{ Ep = '/security/secureScores?$top=1'; All = $false; Perms = @('SecurityEvents.Read.All'); Lic = '' }
    disabled = @{ Ep = "/users?`$filter=accountEnabled%20eq%20false&`$select=id"; All = $true; Perms = @('User.Read.All'); Lic = '' }
    repset = @{ Ep = '/admin/reportSettings'; All = $false; Perms = @('ReportSettings.Read.All'); Lic = '' }
    spset  = @{ Ep = '/admin/sharepoint/settings'; All = $false; Perms = @('SharePointTenantSettings.Read.All'); Lic = '' }
    skus   = @{ Ep = '/subscribedSkus'; All = $true; Perms = @('Organization.Read.All'); Lic = '' }
    org    = @{ Ep = '/organization?$select=id,onPremisesSyncEnabled,onPremisesLastSyncDateTime'; All = $false; Perms = @('Organization.Read.All'); Lic = '' }
    authm  = @{ Ep = '/policies/authenticationMethodsPolicy'; All = $false; Perms = @('Policy.Read.All'); Lic = '' }
    acrp   = @{ Ep = '/policies/adminConsentRequestPolicy'; All = $false; Perms = @('Policy.Read.All'); Lic = '' }
    adminsync = @{ Custom = 'adminsync'; Perms = @('RoleManagement.Read.Directory', 'User.Read.All'); Lic = '' }
    syncerr = @{ Custom = 'syncerr'; Perms = @('User.Read.All', 'Group.Read.All'); Lic = '' }
    graphapps = @{ Custom = 'graphapps'; Perms = @('Application.Read.All'); Lic = '' }
    v1ex   = @{ Custom = 'v1ex'; Perms = @('Policy.Read.All', 'Group.Read.All'); Lic = 'P1' }
    nloc   = @{ Ep = '/identity/conditionalAccess/namedLocations'; All = $true; Perms = @('Policy.Read.All'); Lic = 'P1' }
    # Teams und Gruppen (2.3.0): M365-Gruppen mit Besitzern ($expand liefert hoechstens 20 Besitzer je Gruppe - reicht fuer "keiner" und "nur einer")
    m365grp = @{ Ep = "/groups?`$filter=groupTypes/any(c:c%20eq%20'Unified')&`$select=id,displayName,visibility,resourceProvisioningOptions&`$expand=owners(`$select=id,displayName)"; All = $true; Perms = @('Group.Read.All'); Lic = '' }
    grpguest = @{ Custom = 'grpguest'; Perms = @('Group.Read.All', 'User.Read.All'); Lic = '' }
    grpset = @{ Custom = 'grpset'; Perms = @('Group.Read.All'); Lic = '' }
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
# Fehler mit Klartext fuer die Anzeige (z.B. Obergrenzen) - wird nicht durch "Abruf fehlgeschlagen" ersetzt
function New-HUSecError([string]$Message) { $e = New-Object System.Exception($Message); $e.Data['HUSecMsg'] = $true; return $e }

# Viele GET-Abfragen gebuendelt (Graph JSON-Batching, je 20); Schluessel -> Antwort-Body, fehlende Schluessel = Fehler
function Invoke-HUSecBatch($Ctx, [hashtable]$Requests) {
    $tok = Get-GraphToken -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -ErrorAction Stop
    return (Invoke-GraphBatchGet -Token $tok -Requests $Requests)
}

# Team oder reine M365-Gruppe (resourceProvisioningOptions enthaelt 'Team')
function Get-HUSecGrpKind($G) { if (@($G.resourceProvisioningOptions) -contains 'Team') { return 'Team' } return 'Gruppe' }

function Get-HUSecCustomFact {
    param([Parameter(Mandatory)]$Ctx, [Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'adminact' {
            # Konten mit aktiver Verzeichnisrolle: direkt und ueber rollenzuweisbare Gruppen (eine Ebene, keine Verschachtelung moeglich).
            # Anmeldedaten per Massenabruf (/users mit signInActivity, seitenweise) statt Einzelabfragen - signInActivity ist stark gedrosselt (Review 037 B7/B8).
            $asg = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/roleManagement/directory/roleAssignments?$expand=principal' -All)
            $via = @{}; $sps = New-Object System.Collections.Generic.List[string]
            foreach ($x in $asg) {
                $t = "$($x.principal.'@odata.type')"; $prin = "$($x.principalId)".ToLowerInvariant()
                if (-not $prin) { continue }
                if ($t -like '*user') { if (-not $via.ContainsKey($prin)) { $via[$prin] = '' } }
                elseif ($t -like '*group') {
                    foreach ($m in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/groups/$prin/members/microsoft.graph.user?`$select=id" -All)) {
                        $mid = "$($m.id)".ToLowerInvariant(); if ($mid -and -not $via.ContainsKey($mid)) { $via[$mid] = "$($x.principal.displayName)" }
                    }
                }
                elseif ($t -like '*servicePrincipal') { if (-not $sps.Contains($prin)) { $sps.Add($prin) } }
            }
            if ($via.Count -gt 300) { throw (New-HUSecError 'mehr als 300 Konten mit Admin-Rolle - zu viele fuer diese Pruefung') }
            if ($via.Count) {
                foreach ($u in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/users?$select=id,userPrincipalName,accountEnabled,createdDateTime,signInActivity&$top=500' -All)) {
                    $id = "$($u.id)".ToLowerInvariant()
                    if (-not $via.ContainsKey($id)) { continue }
                    $s = $u.signInActivity
                    [pscustomobject]@{ kind = 'user'; id = $id; upn = "$($u.userPrincipalName)"
                        enabled = $(if ($u.PSObject.Properties['accountEnabled'] -and $null -ne $u.accountEnabled) { [bool]$u.accountEnabled } else { $true })   # fehlt = aktiv (fail-closed)
                        created = $u.createdDateTime; lastOk = $(if ($s) { $s.lastSuccessfulSignInDateTime }); lastAny = $(if ($s) { $s.lastSignInDateTime }); group = $via[$id] }
                }
            }
            foreach ($sp in $sps) { [pscustomobject]@{ kind = 'sp'; id = $sp } }
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
        'v1ex' {
            # V1: je zaehlende Richtlinie die wirksam ausgenommenen Benutzer (direkt + transitiv ueber Gruppen, nur Benutzer).
            # Platzhalter (GuestsOrExternalUsers, None, All) und Rollen zaehlen nicht; geloeschte Gruppe (404) = leer; sonstiger Fehler = nicht aufloesbar.
            $ca = Get-HUSecFact -Ctx $Ctx -Key 'ca'
            if (-not $ca.Ok) { $ex = New-Object System.Exception("Richtlinien nicht lesbar: $($ca.Detail)"); $ex.Data['StatusCode'] = $(if ($ca.Reason -eq 'Recht') { 403 } else { 500 }); throw $ex }
            $grp = @{}
            foreach ($pol in @($ca.Data | Where-Object { Test-HUSecCaHitsBreakGlass $_ })) {
                $users = New-Object System.Collections.Generic.HashSet[string]
                foreach ($u in @($pol.conditions.users.excludeUsers | Where-Object { $_ -and "$_" -notin 'GuestsOrExternalUsers', 'None', 'All' })) { [void]$users.Add("$u".ToLowerInvariant()) }
                $bad = 0; $gcount = 0
                foreach ($g in @($pol.conditions.users.excludeGroups | Where-Object { $_ })) {
                    $gid = "$g".ToLowerInvariant(); $gcount++
                    if (-not $grp.ContainsKey($gid)) {
                        try { $grp[$gid] = @(@(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/groups/$gid/transitiveMembers/microsoft.graph.user?`$select=id" -All) | ForEach-Object { "$($_.id)".ToLowerInvariant() }) }
                        catch { $code = 0; try { $code = [int]$_.Exception.Data['StatusCode'] } catch { }; $grp[$gid] = $(if ($code -eq 404) { @() } else { $null }) }
                    }
                    if ($null -eq $grp[$gid]) { $bad++ } else { foreach ($m in $grp[$gid]) { [void]$users.Add($m) } }
                }
                [pscustomobject]@{ id = "$($pol.id)"; name = "$($pol.displayName)"; all = (Test-HUSecCaTargetsAll $pol); roles = @($pol.conditions.users.includeRoles | Where-Object { $_ }).Count
                    users = @($users); groups = $gcount; badGroups = $bad; exRoles = @($pol.conditions.users.excludeRoles | Where-Object { $_ }).Count
                    exU = @($pol.conditions.users.excludeUsers | Where-Object { $_ -and "$_" -notin 'GuestsOrExternalUsers', 'None', 'All' }); exG = @($pol.conditions.users.excludeGroups | Where-Object { $_ }) }
            }
        }
        'adminsync' {
            # Benutzer mit aktiver Verzeichnisrolle (direkt oder ueber rollenzuweisbare Gruppe) und ob das Konto aus dem lokalen AD synchronisiert wird
            $asg = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/roleManagement/directory/roleAssignments?$expand=principal' -All)
            $defs = @{}
            foreach ($d in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/roleManagement/directory/roleDefinitions?$select=id,displayName' -All)) { $defs["$($d.id)"] = "$($d.displayName)" }
            $roles = @{}
            $add = { param($id, $rn) if (-not $roles.ContainsKey($id)) { $roles[$id] = New-Object System.Collections.Generic.List[string] }; if (-not $roles[$id].Contains($rn)) { $roles[$id].Add($rn) } }
            $gm = @{}
            foreach ($a in @($asg | Where-Object { "$($_.principalId)" })) {
                $t = "$($a.principal.'@odata.type')"; $id = "$($a.principalId)".ToLowerInvariant()
                $rn = if ($defs.ContainsKey("$($a.roleDefinitionId)")) { $defs["$($a.roleDefinitionId)"] } else { "$($a.roleDefinitionId)" }
                if ($t -like '*user') { & $add $id $rn }
                elseif ($t -like '*group') {
                    # Rolle ueber rollenzuweisbare Gruppe (eine Ebene, nicht verschachtelbar) - Mitglieder zaehlen wie direkte Rolleninhaber
                    if (-not $gm.ContainsKey($id)) { $gm[$id] = @(@(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/groups/$id/members/microsoft.graph.user?`$select=id" -All) | ForEach-Object { "$($_.id)".ToLowerInvariant() }) }
                    foreach ($m in $gm[$id]) { if ($m) { & $add $m "$rn (ueber Gruppe $($a.principal.displayName))" } }
                }
            }
            $ids = @($roles.Keys | Sort-Object)
            if ($ids.Count -gt 300) { throw (New-HUSecError 'mehr als 300 Konten mit Admin-Rolle - zu viele fuer diese Pruefung') }
            for ($i = 0; $i -lt $ids.Count; $i += 15) {
                $chunk = @($ids[$i..([math]::Min($i + 14, $ids.Count - 1))])
                $f = ($chunk | ForEach-Object { "'$_'" }) -join ','
                foreach ($u in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/users?`$filter=id%20in%20($f)&`$select=id,userPrincipalName,onPremisesSyncEnabled" -All)) {
                    [pscustomobject]@{ id = "$($u.id)"; upn = "$($u.userPrincipalName)"; synced = ("$($u.onPremisesSyncEnabled)" -match '^(?i)true$'); roles = (@($roles["$($u.id)"]) -join ', ') }
                }
            }
        }
        'grpset' {
            # Einstellungen fuer M365-Gruppen (Vorlage Group.Unified laut Microsoft Learn); fehlt das Objekt, gelten die Microsoft-Standardwerte
            $o = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint '/groupSettings' -All | Where-Object { "$($_.templateId)" -eq '62375ab9-6b52-47ed-826b-58e47e0e304b' -or "$($_.displayName)" -eq 'Group.Unified' }) | Select-Object -First 1
            $v = @{}; if ($o) { foreach ($x in @($o.values)) { $v["$($x.name)"] = "$($x.value)" } }
            $gid = "$($v['GroupCreationAllowedGroupId'])".Trim(); $gname = ''
            if ($gid -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                try { $g = Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/groups/$($gid)?`$select=displayName"; $gname = "$($g.displayName)" } catch { $gname = '' }
                if (-not $gname) { $gname = '(Gruppe nicht gefunden)' }
            }
            [pscustomobject]@{ Present = [bool]$o; Values = $v; GroupId = $gid; GroupName = $gname }
        }
        'grpguest' {
            # Gaeste in M365-Gruppen und Teams: Mitglieder je Gruppe lesen und mit den Gastkonten abgleichen
            # (memberOf je Gast braeuchte Directory.Read.All - das breite Recht fordert der Katalog nicht an)
            $gx = Get-HUSecFact -Ctx $Ctx -Key 'guestsx'
            if (-not $gx.Ok) { throw (New-HUSecError "Gastkonten nicht lesbar: $($gx.Detail)") }
            $gmap = @{}; foreach ($u in @($gx.Data | Where-Object { $_ })) { $gmap["$($u.id)".ToLowerInvariant()] = $u }
            $list = New-Object System.Collections.Generic.List[object]; $fail = 0; $groups = @()
            if ($gmap.Count) {
                $gr = Get-HUSecFact -Ctx $Ctx -Key 'm365grp'
                if (-not $gr.Ok) { throw (New-HUSecError "Gruppen nicht lesbar: $($gr.Detail)") }
                $groups = @($gr.Data | Where-Object { $_ })
                if ($groups.Count -gt 5000) { throw (New-HUSecError 'mehr als 5000 Teams und Gruppen - zu viele fuer diese Pruefung') }
                # Mitglieder gebuendelt (je 20 Gruppen ein Abruf); Gruppen mit mehr als 999 Mitgliedern werden einzeln nachgelesen
                $req = @{}; foreach ($g in $groups) { $req["$($g.id)"] = "/groups/$($g.id)/members/microsoft.graph.user?`$select=id&`$top=999" }
                $res = Invoke-HUSecBatch $Ctx $req
                foreach ($g in $groups) {
                    $body = $res["$($g.id)"]
                    if ($null -eq $body) { $fail++; continue }
                    $mem = @($body.value)
                    if ($body.PSObject.Properties['@odata.nextLink'] -and $body.'@odata.nextLink') {
                        try { $mem = @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint $req["$($g.id)"] -All) } catch { $fail++; continue }
                    }
                    foreach ($m in $mem) {
                        $u = $gmap["$($m.id)".ToLowerInvariant()]
                        if ($u) { $list.Add([pscustomobject]@{ Gast = "$($u.displayName)"; Mail = "$($u.mail)"; Gruppe = "$($g.displayName)"; Art = (Get-HUSecGrpKind $g); Sichtbarkeit = "$($g.visibility)" }) }
                    }
                }
            }
            [pscustomobject]@{ Guests = $gmap.Count; Groups = $groups.Count; Failed = $fail; Items = $list.ToArray() }
        }
        'syncerr' {
            # Benutzer und Gruppen mit Fehlern der Verzeichnissynchronisierung (Graph filtert die Sammlung nicht zuverlaessig - daher alle lesen, lokal filtern)
            foreach ($kind in @(@{ Ep = '/users?$select=id,userPrincipalName,onPremisesSyncEnabled,onPremisesProvisioningErrors&$top=999'; Typ = 'Benutzer' }, @{ Ep = '/groups?$select=id,displayName,onPremisesSyncEnabled,onPremisesProvisioningErrors&$top=999'; Typ = 'Gruppe' })) {
                foreach ($o in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint $kind.Ep -All)) {
                    $errs = @($o.onPremisesProvisioningErrors | Where-Object { $_ })
                    foreach ($e in $errs) {
                        [pscustomobject]@{ Typ = $kind.Typ; Name = $(if ($kind.Typ -eq 'Benutzer') { "$($o.userPrincipalName)" } else { "$($o.displayName)" }); Eigenschaft = "$($e.propertyCausingError)"; Wert = "$($e.value)"; Seit = "$($e.occurredDateTime)" }
                    }
                }
            }
        }
        'graphapps' {
            # Anwendungsrechte auf Microsoft Graph je Dienstprinzipal; die eigene App (Client-ID aus den Einstellungen) wird markiert
            $gsp = Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id,appRoles"
            if ($gsp -and $gsp.PSObject.Properties['value']) { $gsp = @($gsp.value) | Select-Object -First 1 }
            $names = @{}; foreach ($r in @($gsp.appRoles)) { $names["$($r.id)"] = "$($r.value)" }
            $own = ''
            try {
                $t = @($Ctx.Settings.tenants | Where-Object { "$($_.key)" -eq "$($Ctx.TenantKey)" }) | Select-Object -First 1
                if ($t -and "$($t.appId)") {
                    $osp = Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/servicePrincipals(appId='$($t.appId)')?`$select=id"
                    if ($osp -and $osp.PSObject.Properties['value']) { $osp = @($osp.value) | Select-Object -First 1 }
                    $own = "$($osp.id)"
                }
            } catch { $own = '' }
            foreach ($a in @(Invoke-HUSecFetch -TenantKey $Ctx.TenantKey -Settings $Ctx.Settings -Endpoint "/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')/appRoleAssignedTo" -All)) {
                [pscustomobject]@{ principalId = "$($a.principalId)"; app = "$($a.principalDisplayName)"; perm = $(if ($names.ContainsKey("$($a.appRoleId)")) { $names["$($a.appRoleId)"] } else { "$($a.appRoleId)" }); own = ($own -and "$($a.principalId)" -eq $own) }
            }
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
                    $det = $(if ($code) { "HTTP $code$(if ($msg) { ": $msg" })" } elseif ($_.Exception.Data['HUSecMsg']) { "$($_.Exception.Message)" } else { 'Abruf fehlgeschlagen oder unvollstaendig' })
                    # bekannte Anmeldefehler von Microsoft in Klartext (Dienst fehlt im Tenant, meist Microsoft-seitig)
                    $why = 'Technisch'
                    if ("$($_.Exception.Message)" -match 'AADSTS500011') { $why = 'Technisch'; $det = 'Secure Score im Tenant nicht verfuegbar (Dienst nicht bereitgestellt, AADSTS500011) - Secure Score einmal im Defender-Portal oeffnen, danach erneut pruefen' }
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
    A38 = @{ maxSyncAgeMinutes = 180 }
    V1  = @{ accounts = @() }
    A25 = @{ adminGroups = @(); maxUsers = 4 }
    A23 = @{ maxHours = 24 }
    E03 = @{ maxPercent = 5 }
    E04 = @{ minPercent = 95 }
}

# Sollwerte zum Bearbeiten im Dialog (Analyse > Sicherheit > Sollwerte): Regel, Schluessel, Art, Bedeutung
$script:HUSecBaselineInfo = @(
    @{ Rule = 'V1';  Key = 'accounts';          Kind = 'guids'; Text = 'Notfallkonten (Objekt-IDs der Benutzer, mit Komma getrennt). Jedes muss in jeder aussperrfaehigen Richtlinie ausgenommen sein; gilt auch fuer A25 und A27.' }
    @{ Rule = 'A25'; Key = 'adminGroups';       Kind = 'guids'; Text = 'Admin-Gruppen (Objekt-IDs), die bei der Adminportal-Sperre ausgenommen sein duerfen.' }
    @{ Rule = 'A25'; Key = 'maxUsers';          Kind = 'int';   Text = 'Hoechstens so viele einzelne Konten duerfen bei der Adminportal-Sperre ausgenommen sein (Notfallkonten zaehlen nicht).' }
    @{ Rule = 'A01'; Key = 'minEnabled';        Kind = 'int';   Text = 'Mindestens so viele aktive Richtlinien fuer bedingten Zugriff.' }
    @{ Rule = 'A08'; Key = 'min';               Kind = 'int';   Text = 'Mindestens so viele Global Administratoren.' }
    @{ Rule = 'A08'; Key = 'max';               Kind = 'int';   Text = 'Hoechstens so viele Global Administratoren.' }
    @{ Rule = 'A09'; Key = 'allowedWithout';    Kind = 'int';   Text = 'So viele Administratoren duerfen ohne MFA-Registrierung sein (z. B. Notfallkonten).' }
    @{ Rule = 'A19'; Key = 'warnDays';          Kind = 'int';   Text = 'Secrets und Zertifikate von Apps: so viele Tage vor Ablauf warnen.' }
    @{ Rule = 'A23'; Key = 'maxHours';          Kind = 'int';   Text = 'Gaeste muessen sich spaetestens nach so vielen Stunden neu anmelden.' }
    @{ Rule = 'A26'; Key = 'maxAgeDays';        Kind = 'int';   Text = 'Offene Gaesteinladungen gelten nach so vielen Tagen als veraltet.' }
    @{ Rule = 'A27'; Key = 'staleDays';         Kind = 'int';   Text = 'Admin-Konten ohne erfolgreiche Anmeldung seit so vielen Tagen gelten als veraltet.' }
    @{ Rule = 'A38'; Key = 'maxSyncAgeMinutes'; Kind = 'int';   Text = 'Der letzte Verzeichnissync darf hoechstens so viele Minuten her sein.' }
    @{ Rule = 'E03'; Key = 'maxPercent';        Kind = 'int';   Text = 'Hoechstens so viel Prozent nicht konforme Geraete.' }
    @{ Rule = 'E04'; Key = 'minPercent';        Kind = 'int';   Text = 'Mindestens so viel Prozent verschluesselte Windows-Geraete.' }
)

function ConvertTo-HUSecBaselineText($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) { return (@($Value) -join ', ') }
    return "$Value"
}

# Zeilen fuer den Dialog: Wert in dieser Ebene ('' = alle Tenants), Wert fuer alle Tenants, Standard
function Get-HUSecBaselineEdit {
    param([string]$Scope = '')
    $j = $null; try { $j = Read-HUSecJson (Join-Path (Get-HUSecPath) 'baseline.json') } catch { }
    $glob = if ($j -and $j.global) { $j.global } else { $null }
    $mine = if (-not $Scope) { $glob } elseif ($j -and $j.tenants -and $j.tenants.PSObject.Properties[$Scope]) { $j.tenants.$Scope } else { $null }
    foreach ($i in $script:HUSecBaselineInfo) {
        $def = $script:HUSecDefaults[$i.Rule][$i.Key]
        $g = if ($glob -and $glob.PSObject.Properties[$i.Rule] -and $glob.($i.Rule).PSObject.Properties[$i.Key]) { $glob.($i.Rule).($i.Key) } else { $null }
        $v = if ($mine -and $mine.PSObject.Properties[$i.Rule] -and $mine.($i.Rule).PSObject.Properties[$i.Key]) { $mine.($i.Rule).($i.Key) } else { $null }
        [pscustomobject]@{ Rule = $i.Rule; Key = $i.Key; Kind = $i.Kind; Text = $i.Text; Default = (ConvertTo-HUSecBaselineText $def); Global = (ConvertTo-HUSecBaselineText $g); Value = (ConvertTo-HUSecBaselineText $v) }
    }
}

# Speichert die Werte einer Ebene ('' = alle Tenants). $Values: 'Regel.Schluessel' -> Text; leer = Eintrag entfernen (dann gilt Standard bzw. alle Tenants).
# Prueft vorher alles: IDs als GUID, Zahlen 0-3650. Rueckgabe: Fehlerliste (leer = gespeichert). Andere Eintraege der Datei bleiben erhalten.
function Save-HUSecBaselineEdit {
    param([string]$Scope = '', [Parameter(Mandatory)][hashtable]$Values)
    $errs = New-Object System.Collections.Generic.List[string]
    $clean = @{}
    foreach ($i in $script:HUSecBaselineInfo) {
        $k = "$($i.Rule).$($i.Key)"
        if (-not $Values.ContainsKey($k)) { continue }
        $t = "$($Values[$k])".Trim()
        if (-not $t) { $clean[$k] = $null; continue }
        if ($i.Kind -eq 'guids') {
            $parts = @($t -split '[,;\s]+' | Where-Object { $_ })
            $g = [guid]::Empty
            $bad = @($parts | Where-Object { -not [guid]::TryParse($_, [ref]$g) })
            if ($bad.Count) { $errs.Add("$k`: keine gueltige Objekt-ID: $($bad -join ', ')"); continue }
            $clean[$k] = @($parts | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
        }
        else {
            $n = 0
            if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 0 -or $n -gt 3650) { $errs.Add("$k`: ganze Zahl von 0 bis 3650 erwartet ('$t')"); continue }
            $clean[$k] = $n
        }
    }
    if ($errs.Count) { return @($errs.ToArray()) }
    $file = Join-Path (Get-HUSecPath) 'baseline.json'
    $j = $null; try { $j = Read-HUSecJson $file } catch { return @('Sollwerte-Datei ist nicht lesbar - bitte pruefen oder umbenennen') }
    # in Hashtables umwandeln (bestehende, auch unbekannte Eintraege bleiben)
    $toH = { param($o) $h = [ordered]@{}; if ($o) { foreach ($p in $o.PSObject.Properties) { $r = [ordered]@{}; foreach ($q in $p.Value.PSObject.Properties) { $r[$q.Name] = $q.Value }; $h[$p.Name] = $r } }; $h }
    $glob = & $toH $(if ($j) { $j.global })
    $ten = [ordered]@{}
    if ($j -and $j.tenants) { foreach ($p in $j.tenants.PSObject.Properties) { $ten[$p.Name] = & $toH $p.Value } }
    $layer = if ($Scope) { if (-not $ten.Contains($Scope)) { $ten[$Scope] = [ordered]@{} }; $ten[$Scope] } else { $glob }
    foreach ($k in $clean.Keys) {
        $rule, $key = $k -split '\.', 2
        if ($null -eq $clean[$k]) { if ($layer.Contains($rule)) { $layer[$rule].Remove($key); if (-not $layer[$rule].Count) { $layer.Remove($rule) } }; continue }
        if (-not $layer.Contains($rule)) { $layer[$rule] = [ordered]@{} }
        $layer[$rule][$key] = $clean[$k]
    }
    if ($Scope -and -not $ten[$Scope].Count) { $ten.Remove($Scope) }
    Write-HUSecJson $file ([ordered]@{ global = $glob; tenants = $ten })
    return @()
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
                foreach ($q in $p.Value.PSObject.Properties) {
                    # Zahlen-Sollwerte nur als ganze Zahl 0 bis 3650 uebernehmen, sonst Standard behalten und melden (Review 037 B15)
                    $def = if ($script:HUSecDefaults.ContainsKey($p.Name)) { $script:HUSecDefaults[$p.Name][$q.Name] } else { $null }
                    if ($def -is [int]) {
                        $n = 0
                        if (-not [int]::TryParse("$($q.Value)", [ref]$n) -or $n -lt 0 -or $n -gt 3650) { $errs.Add("Sollwert $($p.Name).$($q.Name) ungueltig ('$($q.Value)') - Standard $def bleibt"); continue }
                        $b[$p.Name][$q.Name] = $n; continue
                    }
                    $b[$p.Name][$q.Name] = $q.Value
                }
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
# Geoblock (Review 037 B5): Grund, warum eine Richtlinie KEIN Geoblock ist ('' = ist einer). $Locs: Id -> @odata.type der benannten Orte.
# Zaehlt nur: Blockieren, alle Benutzer, alle Apps (ohne Ausnahmen, ohne Benutzeraktionen/Authentifizierungskontext), keine Spezialbedingung,
# und Laender-Standorte: Sperrliste (Laender eingeschlossen) oder Erlaubnisliste (alle Orte ausser Laender bzw. vertrauenswuerdige). Reine IP-Orte zaehlen nicht.
function Get-HUSecGeoReason($P, $Locs) {
    if (-not (Test-HUSecCaBlocks $P)) { return 'blockiert nicht' }
    $c = $P.conditions
    $inc = @($c.locations.includeLocations | Where-Object { $_ }); $exc = @($c.locations.excludeLocations | Where-Object { $_ })
    if (-not $inc.Count) { return 'keine Standortbedingung' }
    if ($c.authenticationFlows -and "$($c.authenticationFlows.transferMethods)" -match 'deviceCodeFlow|authenticationTransfer') { return 'Spezialrichtlinie (Authentifizierungsfluss)' }
    if (@(@($c.clientAppTypes) | Where-Object { $_ -and "$_" -ne 'all' }).Count) { return 'Spezialrichtlinie (nur bestimmte Client-Apps)' }
    if (@($c.applications.includeApplications) -notcontains 'All') { return 'nicht fuer alle Apps' }
    if (@($c.applications.excludeApplications | Where-Object { $_ }).Count) { return 'Apps ausgenommen' }
    if (@($c.applications.includeUserActions | Where-Object { $_ }).Count -or @($c.applications.includeAuthenticationContextClassReferences | Where-Object { $_ }).Count) { return 'Benutzeraktion oder Authentifizierungskontext' }
    if (@($c.users.includeUsers) -notcontains 'All') { return 'nicht fuer alle Benutzer' }
    if ($c.platforms -or $c.devices -or $c.clientApplications -or @($c.signInRiskLevels | Where-Object { $_ }).Count -or @($c.userRiskLevels | Where-Object { $_ }).Count -or @($c.servicePrincipalRiskLevels | Where-Object { $_ }).Count) { return 'Spezialrichtlinie (Plattform, Geraet, Risiko)' }
    $isC = { param($id) "$($Locs["$id"])" -like '*countryNamedLocation' }
    if (@($inc | Where-Object { & $isC $_ }).Count) { return '' }                                                    # Sperrliste
    if ($inc -contains 'All' -and (@($exc | Where-Object { (& $isC $_) -or "$_" -eq 'AllTrusted' }).Count)) { return '' }   # Erlaubnisliste
    return 'keine Laender-Standorte (nur IP-Bereiche)'
}
function Test-HUSecCaGeoblock($P, $Locs = @{}) { return (-not (Get-HUSecGeoReason $P $Locs)) }

# Richtlinie trifft alle Benutzer oder Admin-Rollen (dort waeren Notfallkonten betroffen); reine Gruppen-/Benutzerrichtlinien nicht
# Richtlinie blockiert oder verlangt etwas vom Konto (MFA, Authentifizierungsstaerke, Geraet, Nutzungsbedingungen ...); reine Sitzungsrichtlinien nicht
function Test-HUSecCaRestricts($P) {
    if (Test-HUSecCaBlocks $P) { return $true }
    $g = $P.grantControls
    if (-not $g) { return $false }
    return [bool](@($g.builtInControls | Where-Object { $_ }).Count -or $g.authenticationStrength -or @($g.termsOfUse | Where-Object { $_ }).Count -or @($g.customAuthenticationFactors | Where-Object { $_ }).Count)
}

# A25 (Review 037 B6): Grund, warum eine Adminportal-Sperre nicht zaehlt ('' = zaehlt). Ausnahmen duerfen nur sein:
# Admin-Rollen, hinterlegte Admin-Gruppen (Sollwert adminGroups) und hoechstens maxUsers einzelne Konten (Notfallkonten).
function Get-HUSecA25Reason($P, $B) {
    if (-not (Test-HUSecCaTargetsAll $P)) { return 'nicht fuer alle Benutzer' }
    $u = $P.conditions.users
    $roles = @($u.excludeRoles | Where-Object { $_ }).Count
    $allowG = @(Get-HUSecGuidList $B.adminGroups)
    $grp = @($u.excludeGroups | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
    $other = @($grp | Where-Object { $allowG -notcontains $_ }).Count
    $bg = @(Get-HUSecGuidList $B.__breakGlass)
    $usr = @($u.excludeUsers | Where-Object { $_ -and "$_" -notin 'None' -and $bg -notcontains "$_".ToLowerInvariant() }).Count
    $max = 4; try { if ($null -ne $B.maxUsers) { $max = [int]$B.maxUsers } } catch { }
    if (-not $roles -and -not ($grp.Count - $other)) { return 'keine Ausnahme fuer Admin-Rollen oder Admin-Gruppe' }
    if ($other) { return "zu breite Ausnahme: $other Gruppe(n) ausgenommen, die nicht als Admin-Gruppe hinterlegt sind" }
    if ($usr -gt $max) { return "zu breite Ausnahme: $usr einzelne Konten (mehr als $max)" }
    return ''
}

# Datum aus Graph (unter PS 5.1 String, unter PS 7 DateTime) kulturunabhaengig nach UTC (Review 037 B9)
function ConvertTo-HUSecUtc($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    try { return [datetimeoffset]::Parse("$Value", [cultureinfo]::InvariantCulture).UtcDateTime } catch { return $null }
}

# A27: Bewertung je aktivem Admin-Konto (Review 037 B7/B19). Gewertet wird nur die letzte ERFOLGREICHE Anmeldung
# (lastSignInDateTime enthaelt auch Fehlversuche). Ersatz nur, wenn lastSignInDateTime vor dem 1.12.2023 liegt (Feld seitdem gefuellt).
# Hinterlegte Notfallkonten (Sollwert V1 accounts) sind ausgenommen.
function Get-HUSecA27($Facts, $B, [datetime]$Now = [datetime]::UtcNow) {
    $max = [int]$B.staleDays
    $bg = @(Get-HUSecGuidList $B.__breakGlass)
    $since = [datetime]::new(2023, 12, 1, 0, 0, 0, [DateTimeKind]::Utc)
    foreach ($u in @($Facts | Where-Object { $_.kind -eq 'user' -and $_.enabled -and $bg -notcontains $_.id })) {
        $ok = ConvertTo-HUSecUtc $u.lastOk; $any = ConvertTo-HUSecUtc $u.lastAny; $cr = ConvertTo-HUSecUtc $u.created
        $last = $ok; $state = 'ok'; $txt = ''
        if (-not $ok -and $any -and $any -lt $since) { $last = $any }
        if ($last) { if (($Now - $last).TotalDays -gt $max) { $state = 'stale'; $txt = "seit $([int]($Now - $last).TotalDays) Tagen nicht angemeldet" } }
        elseif ($any) { $state = 'unknown'; $txt = 'nur Fehlversuche bekannt (keine erfolgreiche Anmeldung)' }
        elseif ($cr -and ($Now - $cr).TotalDays -gt $max) { $state = 'never'; $txt = 'nie angemeldet' }
        [pscustomobject]@{ User = $u; State = $state; Last = $last; Text = $txt }
    }
}

# Lizenz-Plaene aus subscribedSkus (Review 037 B11/B18): nur bereitgestellt (Success) und SKU aktiv (Enabled)
$script:HUSecPlanP2  = 'eec0eb4f-6444-4f95-aba0-50c24d67f998'   # AAD_PREMIUM_P2
function Test-HUSecPlan($Skus, [string[]]$Ids = @(), [string[]]$Names = @()) {
    foreach ($sku in @($Skus | Where-Object { $_ -and (-not $_.PSObject.Properties['capabilityStatus'] -or "$($_.capabilityStatus)" -eq 'Enabled') })) {
        foreach ($sp in @($sku.servicePlans | Where-Object { "$($_.provisioningStatus)" -eq 'Success' })) {
            if ($Ids -contains "$($sp.servicePlanId)".ToLowerInvariant() -or $Names -contains "$($sp.servicePlanName)") { return $true }
        }
    }
    return $false
}

# Benannte Orte: Id -> @odata.type (countryNamedLocation / ipNamedLocation)
function Get-HUSecLocTypes($Locs) {
    $h = @{}; foreach ($l in @($Locs | Where-Object { $_ })) { $h["$($l.id)"] = "$($l.'@odata.type')" }
    return $h
}

# A30 (Review 037 B11): Anmelderisiko mittel oder hoch, fuer alle Benutzer oder Admin-Rollen, und Blockieren
# oder MFA/Authentifizierungsstaerke mit Anmeldehaeufigkeit "jedes Mal" (Microsoft-Vorlage risikobasierter bedingter Zugriff)
function Test-HUSecCaRiskOk($P) {
    $lv = @($P.conditions.signInRiskLevels | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
    if (-not ($lv -contains 'medium' -or $lv -contains 'high')) { return $false }
    if (-not ((Test-HUSecCaTargetsAll $P) -or @($P.conditions.users.includeRoles | Where-Object { $_ }).Count)) { return $false }
    if (Test-HUSecCaBlocks $P) { return $true }
    $mfa = (@($P.grantControls.builtInControls) -contains 'mfa') -or $P.grantControls.authenticationStrength
    return [bool]($mfa -and "$($P.sessionControls.signInFrequency.frequencyInterval)" -eq 'everyTime')
}

# Richtlinie gilt fuer Gaeste: Gast-/Externen-Typen gewaehlt oder alle Benutzer
function Test-HUSecCaGuests($P) {
    $u = $P.conditions.users
    return [bool]($u.includeGuestsOrExternalUsers -or (@($u.includeUsers) -contains 'All') -or (@($u.includeUsers) -contains 'GuestsOrExternalUsers'))
}
# Anmeldehaeufigkeit in Stunden ("jedes Mal" = 0); $null = keine bzw. ausgeschaltet
function Get-HUSecSifHours($P) {
    $f = $P.sessionControls.signInFrequency
    if (-not $f -or -not [bool]$f.isEnabled) { return $null }
    if ("$($f.frequencyInterval)" -eq 'everyTime') { return 0 }
    $v = 0; if (-not [int]::TryParse("$($f.value)", [ref]$v) -or $v -le 0) { return $null }
    if ("$($f.type)" -eq 'days') { return $v * 24 }
    return $v
}

# Gueltige GUIDs aus einem Sollwert (Liste oder Einzelwert), klein geschrieben; ungueltige werden ignoriert (Review 037 B15)
function Get-HUSecGuidList($Value) {
    $g = [guid]::Empty
    return @(@($Value) | Where-Object { $_ -and [guid]::TryParse("$_", [ref]$g) } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
}
# Schnittmenge der wirksam ausgenommenen Benutzer aller V1-Richtlinien
function Get-HUSecV1Common([object[]]$Pols) {
    $p = @($Pols | Where-Object { $_ })
    if (-not $p.Count) { return @() }
    $set = @($p[0].users)
    foreach ($x in $p | Select-Object -Skip 1) { $u = @($x.users); $set = @($set | Where-Object { $u -contains $_ }) }
    return @($set)
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
        Items = { param($F, $B)
            foreach ($pol in @($F.ca | Where-Object { (Test-HUSecCaBlocks $_) -and (@($_.conditions.applications.includeApplications) -contains 'MicrosoftAdminPortals') })) {
                $why = Get-HUSecA25Reason $pol $B
                $zaehlt = (-not $why -and "$($pol.state)" -eq 'enabled')
                if (-not $why -and -not $zaehlt) { $why = "Status $($pol.state)" }
                [pscustomobject]@{ Richtlinie = "$($pol.displayName)"; Status = "$($pol.state)"; AusgenommeneRollen = @($pol.conditions.users.excludeRoles | Where-Object { $_ }).Count
                    AusgenommeneGruppen = @($pol.conditions.users.excludeGroups | Where-Object { $_ }).Count; AusgenommeneBenutzer = @($pol.conditions.users.excludeUsers | Where-Object { $_ }).Count
                    ZaehltFuerRegel = $(if ($zaehlt) { 'Ja' } else { 'Nein' }); Grund = $why }
            }
        }
        Eval = { param($F, $B)
            $cand = @($F.ca | Where-Object { (Test-HUSecCaBlocks $_) -and (@($_.conditions.applications.includeApplications) -contains 'MicrosoftAdminPortals') })
            $ok = @($cand | Where-Object { "$($_.state)" -eq 'enabled' -and -not (Get-HUSecA25Reason $_ $B) })
            if ($ok.Count) { return @{ Status = 'OK'; Count = $ok.Count; Detail = "$($ok.Count) aktive Blockier-Richtlinie(n) fuer die Adminportale, Ausnahmen nur Admin-Rollen, Admin-Gruppe bzw. Notfallkonten" } }
            $broad = @($cand | Where-Object { "$($_.state)" -eq 'enabled' -and (Get-HUSecA25Reason $_ $B) -like 'zu breite Ausnahme*' })
            if ($broad.Count) { return @{ Status = 'Abweichung'; Count = $broad.Count; Detail = "$(Get-HUSecA25Reason $broad[0] $B) - Admin-Gruppen in den Sollwerten (A25 adminGroups) hinterlegen oder Ausnahme verkleinern" } }
            if (@($cand | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' -and -not (Get-HUSecA25Reason $_ $B) }).Count) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'Adminportale nur im Berichtsmodus blockiert' } }
            @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Richtlinie, die Benutzer von den Adminportalen blockiert (alle Benutzer, Ausnahme nur fuer Admins)' }
        } }
    @{ Id = 'A27'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Keine veralteten Administrator-Konten (lange nicht angemeldet)'; Facts = @('adminact'); Min = $false; ItemsLabel = 'Konten'; ItemsSignIn = $true
        Items = { param($F, $B)
            foreach ($a in @(Get-HUSecA27 $F.adminact $B) | Where-Object { $_.State -ne 'ok' }) {
                [pscustomobject]@{ Anmeldename = "$($a.User.upn)"; LetzteAnmeldung = $(if ($a.Last) { $a.Last.ToString('yyyy-MM-dd') } else { '' }); Befund = $a.Text; UeberGruppe = "$($a.User.group)"; __Id = "$($a.User.id)" }
            }
        }
        Eval = { param($F, $B)
            $r = @(Get-HUSecA27 $F.adminact $B)
            $max = [int]$B.staleDays
            $bad = @($r | Where-Object { $_.State -ne 'ok' })
            $never = @($bad | Where-Object { $_.State -eq 'never' }).Count; $unk = @($bad | Where-Object { $_.State -eq 'unknown' }).Count
            $sp = @($F.adminact | Where-Object { $_.kind -eq 'sp' }).Count
            $grp = @($r | Where-Object { $_.User.group }).Count
            $d2 = "$($r.Count) aktive Admin-Konten (direkt und ueber Gruppen$(if ($grp) { ", $grp ueber Gruppe" }))$(if ($sp) { "; $sp Dienstprinzipal(e) mit Rolle (nicht bewertet)" })"
            if ($bad.Count) { return @{ Status = 'Abweichung'; Count = $bad.Count; Detail = "$d2, $($bad.Count) ohne erfolgreiche Anmeldung seit mehr als $max Tagen$(if ($never) { " (davon $never nie angemeldet)" })$(if ($unk) { ", $unk unbekannt (nur Fehlversuche bekannt)" })" } }
            @{ Status = 'OK'; Count = 0; Detail = "$d2, alle innerhalb von $max Tagen erfolgreich angemeldet" }
        } }
    @{ Id = 'A28'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Kennwortschutz fuer das lokale AD ist im Tenant eingeschaltet (Modus Erzwingen)'; Facts = @('pwdset'); Min = $false
        Eval = { param($F, $B)
            # Auswahl nach Vorlage (templateId laut Microsoft Learn), Name nur als Rueckfall (Review 037 B12)
            $o = @($F.pwdset | Where-Object { "$($_.templateId)" -eq '5cf42378-d67d-4f36-ba46-e8b86229381d' }) | Select-Object -First 1
            if (-not $o) { $o = @($F.pwdset | Where-Object { "$($_.displayName)" -eq 'Password Rule Settings' }) | Select-Object -First 1 }
            if (-not $o) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'keine eigenen Kennwortregeln gesetzt - es gilt der Microsoft-Standard (nicht Modus Erzwingen)' } }
            $v = @{}; foreach ($x in @($o.values)) { $v["$($x.name)"] = "$($x.value)" }
            $on = ($v['EnableBannedPasswordCheckOnPremises'] -eq 'True')
            $mode = "$($v['BannedPasswordCheckOnPremisesMode'])"
            $custom = @("$($v['BannedPasswordList'])" -split "`t" | Where-Object { $_ }).Count
            $d = "lokales AD: $(if ($on) { 'an' } else { 'aus' }), Modus $(if ($mode) { $mode } else { '-' }), eigene Verbotsliste: $custom Begriff(e). Ob die Agenten auf den Domaenencontrollern laufen, wird nicht geprueft"
            if ($on -and $mode -eq 'Enforce') { @{ Status = 'OK'; Count = 0; Detail = $d } } else { @{ Status = 'Abweichung'; Count = 0; Detail = $d } }
        } }
    @{ Id = 'A29'; Area = 'Entra'; Sev = 'Niedrig'; Title = 'Lizenz fuer Privileged Identity Management (PIM) vorhanden'; Facts = @('skus'); Min = $false
        Eval = { param($F, $B)
            if (Test-HUSecPlan $F.skus @($script:HUSecPlanP2) @('AAD_PREMIUM_P2', 'Entra_Identity_Governance')) { @{ Status = 'Info'; Count = 1; Detail = 'Entra ID P2 bzw. ID Governance vorhanden - PIM (zeitlich begrenzte Admin-Rechte) waere nutzbar' } }
            else { @{ Status = 'NichtPruefbar'; Reason = 'Lizenz'; Detail = 'keine Entra ID P2 bzw. ID Governance - PIM nicht nutzbar. Ersatz mit P1: dauerhafte Admin-Rollen klein halten (A08, A17, A27) und Rollen regelmaessig von Hand pruefen' } }
        } }
    @{ Id = 'A30'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Riskante Anmeldungen von Administratoren sind per Conditional Access abgefangen'; Facts = @('ca', 'skus'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) Test-HUSecCaRiskOk $P } }
        Eval = { param($F, $B)
            if (-not (Test-HUSecPlan $F.skus @($script:HUSecPlanP2) @('AAD_PREMIUM_P2'))) { return @{ Status = 'NichtPruefbar'; Reason = 'Lizenz'; Detail = 'Risikobasierte Richtlinien brauchen Entra ID P2. Ersatz mit P1: Geoblock (A24), MFA fuer alle (V5), Legacy-Auth (A04) und Geraetecode-Flow (V11) blockieren' } }
            $hit = @($F.ca | Where-Object { "$($_.state)" -eq 'enabled' -and (Test-HUSecCaRiskOk $_) }).Count
            if ($hit) { @{ Status = 'OK'; Count = $hit; Detail = "$hit aktive Richtlinie(n): Anmelderisiko mittel/hoch wird blockiert oder verlangt MFA bei jeder Anmeldung" } }
            else { @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Richtlinie, die mittleres/hohes Anmelderisiko von Admins blockiert oder MFA bei jeder Anmeldung verlangt' } }
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
    @{ Id = 'A34'; Area = 'SharePoint'; Sev = 'Mittel'; Title = 'Legacy-Authentifizierung in SharePoint ist ausgeschaltet'; Facts = @('spset'); Min = $false
        Eval = { param($F, $B)
            $v = $F.spset.isLegacyAuthProtocolsEnabled
            if ($null -eq $v -or "$v" -notmatch '^(?i)(true|false)$') { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld isLegacyAuthProtocolsEnabled nicht gefunden'; Complete = $false } }
            if ("$v" -match '^(?i)true$') { return @{ Status = 'Abweichung'; Count = 1; Detail = 'Legacy-Authentifizierung ist fuer SharePoint erlaubt' } }
            @{ Status = 'OK'; Count = 0; Detail = 'Legacy-Authentifizierung ist ausgeschaltet' }
        } }
    @{ Id = 'A35'; Area = 'SharePoint'; Sev = 'Niedrig'; Title = 'Externe Benutzer duerfen Freigaben nicht weitergeben'; Facts = @('spset'); Min = $false
        Eval = { param($F, $B)
            $v = $F.spset.isResharingByExternalUsersEnabled
            if ($null -eq $v -or "$v" -notmatch '^(?i)(true|false)$') { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld isResharingByExternalUsersEnabled nicht gefunden'; Complete = $false } }
            if ("$v" -match '^(?i)true$') { return @{ Status = 'Abweichung'; Count = 1; Detail = 'Externe Benutzer duerfen Freigaben weitergeben' } }
            @{ Status = 'OK'; Count = 0; Detail = 'Weitergabe durch externe Benutzer ist ausgeschaltet' }
        } }
    @{ Id = 'A36'; Area = 'SharePoint'; Sev = 'Niedrig'; Title = 'SharePoint: Domaenen-Einschraenkung und Leerlauf-Abmeldung (zur Kenntnis)'; Facts = @('spset'); Min = $false
        Eval = { param($F, $B)
            $m = "$($F.spset.sharingDomainRestrictionMode)"
            $idle = $F.spset.idleSessionSignOut
            if (-not $m -and -not $idle) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Felder sharingDomainRestrictionMode und idleSessionSignOut nicht gefunden'; Complete = $false } }
            $mt = switch ($m) { 'none' { 'keine Einschraenkung' } 'allowList' { 'nur erlaubte Domaenen' } 'blockList' { 'gesperrte Domaenen' } default { if ($m) { $m } else { 'unbekannt' } } }
            $it = 'unbekannt'
            if ($idle) { $it = if ("$($idle.isEnabled)" -match '^(?i)true$') { "an, Abmeldung nach $([int]([double]$idle.signOutAfterInSeconds / 60)) Min" } else { 'aus' } }
            @{ Status = 'Info'; Count = 0; Detail = "Externe Domaenen: $mt; Leerlauf-Abmeldung: $it" }
        } }
    @{ Id = 'A37'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Admin-Rollen nur fuer reine Cloud-Konten (nicht aus dem lokalen AD synchronisiert)'; Facts = @('adminsync'); Min = $false; ItemsLabel = 'Konten'; ItemsSort = 'Konto'
        Items = { param($F, $B) foreach ($u in @($F.adminsync | Where-Object { $_.synced })) { [pscustomobject]@{ Konto = $u.upn; Rollen = $u.roles } } }
        Eval = { param($F, $B)
            $all = @($F.adminsync)
            $n = @($all | Where-Object { $_.synced }).Count
            if ($n) { return @{ Status = 'Abweichung'; Count = $n; Detail = "$n von $($all.Count) Konten mit Admin-Rolle kommen aus dem lokalen AD" } }
            @{ Status = 'OK'; Count = 0; Detail = "alle $($all.Count) Konten mit Admin-Rolle sind reine Cloud-Konten" }
        } }
    @{ Id = 'A38'; Area = 'Entra'; Sev = 'Hoch'; Title = 'Verzeichnissynchronisierung (Entra Connect) laeuft regelmaessig'; Facts = @('org'); Min = $false
        Eval = { param($F, $B)
            $o = $F.org
            if (-not $o) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Organisation nicht gelesen'; Complete = $false } }
            if ("$($o.onPremisesSyncEnabled)" -notmatch '^(?i)true$') { return @{ Status = 'NichtPruefbar'; Reason = 'NichtAnwendbar'; Detail = 'keine Verzeichnissynchronisierung eingerichtet' } }
            $t = $null; try { if ($o.onPremisesLastSyncDateTime) { $t = ([datetime]$o.onPremisesLastSyncDateTime).ToUniversalTime() } } catch { }
            if (-not $t) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Zeitpunkt des letzten Syncs fehlt'; Complete = $false } }
            $min = [int]([datetime]::UtcNow - $t).TotalMinutes
            $loc = $t.ToLocalTime().ToString('dd.MM.yyyy HH:mm', [cultureinfo]::InvariantCulture)
            if ($min -gt [int]$B.maxSyncAgeMinutes) { return @{ Status = 'Abweichung'; Count = 1; Detail = "letzter Sync vor $([math]::Round($min / 60, 1)) Stunden ($loc), erlaubt $($B.maxSyncAgeMinutes) Minuten" } }
            @{ Status = 'OK'; Count = 0; Detail = "letzter Sync vor $min Minuten ($loc)" }
        } }
    @{ Id = 'A39'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Keine Fehler bei der Verzeichnissynchronisierung (Benutzer und Gruppen)'; Facts = @('syncerr'); Min = $false; ItemsLabel = 'Fehler'; ItemsSort = 'Name'
        Items = { param($F, $B) @($F.syncerr) }
        Eval = { param($F, $B)
            $n = @($F.syncerr | Where-Object { $_ }).Count
            if ($n) { return @{ Status = 'Abweichung'; Count = $n; Detail = "$n Sync-Fehler (meist doppelte UPN oder Mailadresse)" } }
            @{ Status = 'OK'; Count = 0; Detail = 'keine Sync-Fehler' }
        } }
    @{ Id = 'A40'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Schwache Anmeldemethoden (SMS, Sprachanruf) sind ausgeschaltet'; Facts = @('authm'); Min = $false
        Eval = { param($F, $B)
            $cfg = @($F.authm.authenticationMethodConfigurations | Where-Object { $_ })
            if (-not $cfg.Count) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Methodenliste nicht geliefert'; Complete = $false } }
            $on = @($cfg | Where-Object { "$($_.id)" -in 'Sms', 'Voice' -and "$($_.state)" -eq 'enabled' } | ForEach-Object { if ("$($_.id)" -eq 'Sms') { 'SMS' } else { 'Sprachanruf' } })
            $mail = @($cfg | Where-Object { "$($_.id)" -eq 'Email' -and "$($_.state)" -eq 'enabled' }).Count
            $hint = if ($mail) { ' (E-Mail-Code ist an - wird auch fuer Gaeste genutzt, daher nicht gewertet)' } else { '' }
            if ($on.Count) { return @{ Status = 'Abweichung'; Count = $on.Count; Detail = "eingeschaltet: $($on -join ', ')$hint" } }
            @{ Status = 'OK'; Count = 0; Detail = "SMS und Sprachanruf sind aus$hint" }
        } }
    @{ Id = 'A41'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Admin-Zustimmungs-Workflow ist eingeschaltet (Benutzer koennen App-Freigabe anfragen)'; Facts = @('acrp'); Min = $false
        Eval = { param($F, $B)
            $v = $F.acrp.isEnabled
            if ($null -eq $v -or "$v" -notmatch '^(?i)(true|false)$') { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Feld isEnabled nicht gefunden'; Complete = $false } }
            if ("$v" -match '^(?i)true$') { return @{ Status = 'OK'; Count = 0; Detail = 'Workflow ist eingeschaltet' } }
            @{ Status = 'Abweichung'; Count = 1; Detail = 'Workflow ist ausgeschaltet - Benutzer koennen keine Freigabe anfragen' }
        } }
    @{ Id = 'A42'; Area = 'Apps'; Sev = 'Hoch'; Title = 'Apps mit kritischen Anwendungsrechten auf Microsoft Graph'; Facts = @('graphapps'); Min = $false; ItemsLabel = 'Apps'; ItemsSort = 'App'; Export = $true
        Items = { param($F, $B)
            foreach ($g in (@($F.graphapps | Where-Object { $script:HUSecCriticalPerms -contains $_.perm }) | Group-Object principalId)) {
                $a = $g.Group[0]
                [pscustomobject]@{ App = "$($a.app)$(if ($a.own) { ' (dieses Programm)' })"; Rechte = (@($g.Group | ForEach-Object { $_.perm } | Sort-Object -Unique) -join ', ') }
            }
        }
        Eval = { param($F, $B)
            $crit = @($F.graphapps | Where-Object { $script:HUSecCriticalPerms -contains $_.perm })
            $apps = @($crit | Where-Object { -not $_.own } | Select-Object -ExpandProperty principalId -Unique)
            $ownTxt = if (@($crit | Where-Object { $_.own }).Count) { ' (dieses Programm nicht mitgezaehlt)' } else { '' }
            if ($apps.Count) { return @{ Status = 'Abweichung'; Count = $apps.Count; Detail = "$($apps.Count) App(s) mit kritischen Rechten$ownTxt - bitte pruefen, ob noetig" } }
            @{ Status = 'OK'; Count = 0; Detail = "keine weitere App mit kritischen Rechten$ownTxt" }
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
            $now = [datetime]::UtcNow
            foreach ($g in @($F.guestsx | Where-Object { "$($_.externalUserState)" -eq 'PendingAcceptance' })) {
                $d = ConvertTo-HUSecUtc $(if ($g.PSObject.Properties['externalUserStateChangeDateTime'] -and $g.externalUserStateChangeDateTime) { $g.externalUserStateChangeDateTime } else { $g.createdDateTime })
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
            # Alter ab letzter (erneuter) Einladung, sonst ab Anlage (Review 037 B13)
            $old = @($pend | Where-Object { $d = ConvertTo-HUSecUtc $(if ($_.PSObject.Properties['externalUserStateChangeDateTime'] -and $_.externalUserStateChangeDateTime) { $_.externalUserStateChangeDateTime } else { $_.createdDateTime }); $d -and ([datetime]::UtcNow - $d).TotalDays -gt $max }).Count
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
            @{ Status = 'Info'; Count = $n; Detail = "$n Gastkonto/Gastkonten. In welchen Teams und Gruppen sie Mitglied sind, zeigt C06" }
        } }
    @{ Id = 'C03'; Area = 'Teams'; Sev = 'Mittel'; Title = 'Teams und M365-Gruppen haben einen Besitzer'; Facts = @('m365grp'); Min = $false; ItemsLabel = 'Gruppen'; ItemsSort = 'Gruppe'; Export = $true
        Items = { param($F, $B) foreach ($g in @($F.m365grp | Where-Object { $_ -and -not @($_.owners | Where-Object { $_ }).Count })) { [pscustomobject]@{ Gruppe = "$($g.displayName)"; Art = (Get-HUSecGrpKind $g); Sichtbarkeit = "$($g.visibility)" } } }
        Eval = { param($F, $B)
            $all = @($F.m365grp | Where-Object { $_ })
            if (-not $all.Count) { return @{ Status = 'OK'; Count = 0; Detail = 'keine Teams oder M365-Gruppen' } }
            if (-not @($all | Where-Object { $_.PSObject.Properties['owners'] }).Count) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Besitzer werden nicht geliefert'; Complete = $false } }
            $n = @($all | Where-Object { -not @($_.owners | Where-Object { $_ }).Count }).Count
            $t = @($all | Where-Object { (Get-HUSecGrpKind $_) -eq 'Team' }).Count
            $nt = @($all | Where-Object { -not @($_.owners | Where-Object { $_ }).Count -and (Get-HUSecGrpKind $_) -eq 'Team' }).Count
            if ($n) { @{ Status = 'Abweichung'; Count = $n; Detail = "$n von $($all.Count) Teams/Gruppen ohne Besitzer, davon $nt Teams (Teams insgesamt: $t)" } }
            else { @{ Status = 'OK'; Count = 0; Detail = "alle $($all.Count) Teams/Gruppen haben einen Besitzer ($t Teams)" } }
        } }
    @{ Id = 'C04'; Area = 'Teams'; Sev = 'Niedrig'; Title = 'Teams und M365-Gruppen mit nur einem Besitzer (zur Kenntnis)'; Facts = @('m365grp'); Min = $false; ItemsLabel = 'Gruppen'; ItemsSort = 'Gruppe'
        Items = { param($F, $B) foreach ($g in @($F.m365grp | Where-Object { $_ -and @($_.owners | Where-Object { $_ }).Count -eq 1 })) { [pscustomobject]@{ Gruppe = "$($g.displayName)"; Art = (Get-HUSecGrpKind $g); Besitzer = "$(@($g.owners | Where-Object { $_ })[0].displayName)" } } }
        Eval = { param($F, $B)
            $all = @($F.m365grp | Where-Object { $_ })
            if ($all.Count -and -not @($all | Where-Object { $_.PSObject.Properties['owners'] }).Count) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = 'Besitzer werden nicht geliefert'; Complete = $false } }
            $n = @($all | Where-Object { @($_.owners | Where-Object { $_ }).Count -eq 1 }).Count
            @{ Status = 'Info'; Count = $n; Detail = "$n von $($all.Count) Teams/Gruppen mit nur einem Besitzer" }
        } }
    @{ Id = 'C05'; Area = 'Teams'; Sev = 'Mittel'; Title = 'Keine oeffentlichen Teams und M365-Gruppen'; Facts = @('m365grp'); Min = $false; ItemsLabel = 'Gruppen'; ItemsSort = 'Gruppe'; Export = $true
        Items = { param($F, $B) foreach ($g in @($F.m365grp | Where-Object { $_ -and "$($_.visibility)" -eq 'Public' })) { [pscustomobject]@{ Gruppe = "$($g.displayName)"; Art = (Get-HUSecGrpKind $g); Besitzer = @($g.owners | Where-Object { $_ }).Count } } }
        Eval = { param($F, $B)
            $all = @($F.m365grp | Where-Object { $_ })
            if (-not $all.Count) { return @{ Status = 'OK'; Count = 0; Detail = 'keine Teams oder M365-Gruppen' } }
            $n = @($all | Where-Object { "$($_.visibility)" -eq 'Public' }).Count
            $u = @($all | Where-Object { -not "$($_.visibility)" }).Count
            $d = "$n von $($all.Count) Teams/Gruppen oeffentlich$(if ($u) { ", bei $u fehlt die Angabe (nicht gezaehlt)" })"
            if ($n) { @{ Status = 'Abweichung'; Count = $n; Detail = $d } } else { @{ Status = 'OK'; Count = 0; Detail = $d } }
        } }
    @{ Id = 'C06'; Area = 'Teams'; Sev = 'Hoch'; Title = 'Gaeste in Teams und M365-Gruppen'; Facts = @('grpguest'); Min = $false; ItemsLabel = 'Mitgliedschaften'; ItemsSort = 'Gast'
        Items = { param($F, $B) @($F.grpguest.Items) }
        Eval = { param($F, $B)
            $x = $F.grpguest
            if (-not $x -or -not $x.Guests) { return @{ Status = 'OK'; Count = 0; Detail = 'keine Gastkonten' } }
            $it = @($x.Items)
            $miss = $(if ($x.Failed) { ", $($x.Failed) Gruppe(n) nicht lesbar" } else { '' })
            if ($it.Count) {
                $gs = @($it | ForEach-Object { $_.Mail + '|' + $_.Gast } | Sort-Object -Unique).Count
                $gr = @($it | ForEach-Object { $_.Gruppe } | Sort-Object -Unique).Count
                $r = @{ Status = 'Abweichung'; Count = $it.Count; Detail = "$gs Gast/Gaeste in $gr Teams/Gruppen ($($it.Count) Mitgliedschaften)$miss" }
            }
            else { $r = @{ Status = 'OK'; Count = 0; Detail = "$($x.Guests) Gastkonto/Gastkonten, in keinem der $($x.Groups) Teams/Gruppen Mitglied$miss" } }
            if ($x.Failed) { $r.Complete = $false }
            $r
        } }
    @{ Id = 'C07'; Area = 'Teams'; Sev = 'Mittel'; Title = 'Nicht jeder darf Teams und M365-Gruppen anlegen'; Facts = @('grpset'); Min = $false
        Eval = { param($F, $B)
            $v = $F.grpset.Values
            $on = -not ($v -and $v.ContainsKey('EnableGroupCreation') -and "$($v['EnableGroupCreation'])" -eq 'False')
            if ($on) { return @{ Status = 'Abweichung'; Count = 1; Detail = "alle Benutzer (auch Schueler) duerfen Teams und Gruppen anlegen$(if (-not $F.grpset.Present) { ' (Microsoft-Standard, nie geaendert)' })" } }
            if ($F.grpset.GroupId) { return @{ Status = 'OK'; Count = 0; Detail = "nur Administratoren und Mitglieder der Gruppe $($F.grpset.GroupName)" } }
            @{ Status = 'OK'; Count = 0; Detail = 'nur Administratoren' }
        } }
    @{ Id = 'C08'; Area = 'Teams'; Sev = 'Niedrig'; Title = 'Gaeste duerfen keine Besitzer von Teams und Gruppen sein'; Facts = @('grpset'); Min = $false
        Eval = { param($F, $B)
            $v = $F.grpset.Values; if (-not $v) { $v = @{} }
            $val = { param($k, $def) if ($v.ContainsKey($k) -and "$($v[$k])") { "$($v[$k])" -eq 'True' } else { $def } }
            $own = & $val 'AllowGuestsToBeGroupOwner' $false
            $add = & $val 'AllowToAddGuests' $true
            $acc = & $val 'AllowGuestsToAccessGroups' $true
            $d = "Gaeste als Besitzer: $(if ($own) { 'erlaubt' } else { 'nein' }); Gaeste hinzufuegen: $(if ($add) { 'erlaubt' } else { 'nein' }); Gaeste sehen Gruppeninhalte: $(if ($acc) { 'ja' } else { 'nein' })$(if (-not $F.grpset.Present) { ' (Microsoft-Standard)' })"
            if ($own) { @{ Status = 'Abweichung'; Count = 1; Detail = $d } } else { @{ Status = 'OK'; Count = 0; Detail = $d } }
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
        Items = { param($F, $B) Get-HUSecPolicyItems $F.ca { param($P) (Test-HUSecCaGuests $P) -and ($null -ne (Get-HUSecSifHours $P)) -and (Get-HUSecSifHours $P) -le [int]$B.maxHours } }
        Eval = { param($F, $B)
            # Review 037 B14: Hoechstwert als Sollwert (Standard 24 Stunden; "jedes Mal" = 0), Einheit Tage/Stunden umgerechnet
            $max = [int]$B.maxHours
            $hit = @($F.ca | Where-Object { (Test-HUSecCaGuests $_) -and ($null -ne (Get-HUSecSifHours $_)) })
            $on = @($hit | Where-Object { "$($_.state)" -eq 'enabled' })
            $ok = @($on | Where-Object { (Get-HUSecSifHours $_) -le $max })
            if ($ok.Count) { return @{ Status = 'OK'; Count = $ok.Count; Detail = "$($ok.Count) aktive Richtlinie(n): Gaeste melden sich spaetestens nach $(@($ok | ForEach-Object { Get-HUSecSifHours $_ } | Measure-Object -Minimum).Minimum) Stunden neu an (erlaubt: $max)" } }
            if ($on.Count) { $h = @($on | ForEach-Object { Get-HUSecSifHours $_ } | Measure-Object -Minimum).Minimum; return @{ Status = 'Abweichung'; Count = 0; Detail = "Anmeldehaeufigkeit fuer Gaeste $h Stunden - laenger als erlaubt ($max Stunden, Sollwert A23 maxHours)" } }
            if (@($hit | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'nur im Berichtsmodus' } }
            @{ Status = 'Abweichung'; Count = 0; Detail = 'keine Richtlinie mit Anmeldehaeufigkeit fuer Gaeste' }
        } }
    @{ Id = 'A24'; Area = 'Entra'; Sev = 'Mittel'; Title = 'Anmeldungen sind per Standort (Geoblock) eingeschraenkt'; Facts = @('ca', 'nloc'); Min = $false; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B)
            $locs = Get-HUSecLocTypes $F.nloc
            foreach ($pol in @($F.ca | Where-Object { $_.conditions.locations -and (@($_.conditions.locations.includeLocations).Count -gt 0) })) {
                $why = Get-HUSecGeoReason $pol $locs
                $zaehlt = (-not $why -and "$($pol.state)" -eq 'enabled')
                if (-not $why -and -not $zaehlt) { $why = "Status $($pol.state)" }
                $inc = @($pol.conditions.locations.includeLocations)
                [pscustomobject]@{ Richtlinie = "$($pol.displayName)"; Status = "$($pol.state)"; Aktion = $(if (Test-HUSecCaBlocks $pol) { 'Blockieren' } else { (@($pol.grantControls.builtInControls) -join ', ') })
                    OrteEingeschlossen = $(if ($inc -contains 'All') { 'Alle' } else { "$($inc.Count) Orte" }); OrteAusgenommen = @($pol.conditions.locations.excludeLocations | Where-Object { $_ }).Count
                    AusgenommeneBenutzer = @($pol.conditions.users.excludeUsers | Where-Object { $_ }).Count; AusgenommeneGruppen = @($pol.conditions.users.excludeGroups | Where-Object { $_ }).Count
                    ZaehltFuerRegel = $(if ($zaehlt) { 'Ja' } else { 'Nein' }); Grund = $why }
            }
        }
        Eval = { param($F, $B)
            $locs = Get-HUSecLocTypes $F.nloc
            $hit = @($F.ca | Where-Object { Test-HUSecCaGeoblock $_ $locs })
            $on = @($hit | Where-Object { "$($_.state)" -eq 'enabled' })
            $rep = @($hit | Where-Object { "$($_.state)" -eq 'enabledForReportingButNotEnforced' }).Count
            if ($on.Count) {
                $exG = @($on | ForEach-Object { @($_.conditions.users.excludeGroups | Where-Object { $_ }) }).Count
                $exU = @($on | ForEach-Object { @($_.conditions.users.excludeUsers | Where-Object { $_ }) }).Count
                $hint = if ($exG -or $exU) { " - Ausnahmen pruefen: $exU Benutzer, $exG Gruppe(n) ausgenommen" } else { '' }
                return @{ Status = 'OK'; Count = $on.Count; Detail = "$($on.Count) aktive Geoblock-Richtlinie(n) mit Laender-Standorten (welche Laender, wird nicht bewertet)$hint" }
            }
            if ($rep) { return @{ Status = 'Abweichung'; Count = 0; Detail = 'Geoblock nur im Berichtsmodus' } }
            @{ Status = 'Abweichung'; Count = 0; Detail = 'keine aktive Geoblock-Richtlinie (Blockieren, alle Benutzer, alle Apps, Laender-Standorte)' }
        } }
    @{ Id = 'V1'; Area = 'Entra'; Sev = 'Kritisch'; Title = 'Notfallkonten sind von allen aktiven blockierenden oder einschraenkenden Conditional-Access-Richtlinien ausgenommen'; Facts = @('v1ex'); Min = $true; ItemsLabel = 'Richtlinien'; ItemsSort = 'Richtlinie'
        Items = { param($F, $B)
            $acc = @(Get-HUSecGuidList $B.accounts)
            $common = Get-HUSecV1Common @($F.v1ex)
            foreach ($pol in @($F.v1ex)) {
                $miss = if ($acc.Count) { @($acc | Where-Object { @($pol.users) -notcontains $_ }).Count } else { -1 }
                $erg = if ($pol.badGroups) { 'Gruppe nicht lesbar' } elseif (-not @($pol.users).Count) { 'KEINE wirksame Ausnahme' } elseif ($acc.Count) { $(if ($miss) { "$miss Notfallkonto/-konten fehlen" } else { 'Notfallkonten ausgenommen' }) } elseif (@($common).Count) { 'gemeinsame Ausnahme vorhanden' } else { 'keine gemeinsame Ausnahme' }
                [pscustomobject]@{ Richtlinie = "$($pol.name)"; GiltFuer = $(if ($pol.all) { 'Alle Benutzer' } else { "$($pol.roles) Admin-Rollen" }); AusgenommeneBenutzer = @($pol.users).Count; AusgenommeneGruppen = $pol.groups; AusgenommeneRollen = $pol.exRoles
                    Ergebnis = $erg; __ExU = @($pol.exU); __ExG = @($pol.exG) }
            }
        }
        Eval = { param($F, $B)
            $pols = @($F.v1ex)
            if (-not $pols.Count) { return @{ Status = 'Info'; Count = 0; Detail = 'keine aktive blockierende oder einschraenkende Richtlinie fuer alle Benutzer oder Admin-Rollen' } }
            $bad = @($pols | Where-Object { $_.badGroups }).Count
            if ($bad) { return @{ Status = 'NichtPruefbar'; Reason = 'Technisch'; Detail = "in $bad Richtlinie(n) ist eine ausgenommene Gruppe nicht lesbar"; Complete = $false } }
            $roleHint = if (@($pols | Where-Object { $_.exRoles }).Count) { ' Ausgenommene Rollen zaehlen nicht als Notfallkonto.' } else { '' }
            $acc = @(Get-HUSecGuidList $B.accounts)
            if ($acc.Count) {
                $miss = @($pols | Where-Object { $p = $_; @($acc | Where-Object { @($p.users) -notcontains $_ }).Count })
                if ($miss.Count) { return @{ Status = 'Abweichung'; Count = $miss.Count; Detail = "hinterlegte Notfallkonten ($($acc.Count)) fehlen in $($miss.Count) von $($pols.Count) Richtlinien als Ausnahme.$roleHint" } }
                return @{ Status = 'OK'; Count = 0; Detail = "hinterlegte Notfallkonten ($($acc.Count)) sind in allen $($pols.Count) Richtlinien ausgenommen" }
            }
            $without = @($pols | Where-Object { -not @($_.users).Count }).Count
            if ($without) { return @{ Status = 'Abweichung'; Count = $without; Detail = "$without von $($pols.Count) Richtlinien ohne wirksame Ausnahme (Benutzer oder Gruppe).$roleHint" } }
            $common = @(Get-HUSecV1Common $pols)
            if (-not $common.Count) { return @{ Status = 'Abweichung'; Count = $pols.Count; Detail = "alle $($pols.Count) Richtlinien haben Ausnahmen, aber kein Konto ist in allen ausgenommen - Notfallkonto fehlt mindestens in einer.$roleHint" } }
            if ($common.Count -gt 4) { return @{ Status = 'OK'; Count = 0; Detail = "$($common.Count) Konten sind in allen $($pols.Count) Richtlinien ausgenommen - mehr als ueblich, Ausnahmen pruefen; Notfallkonten in den Sollwerten (V1 accounts) hinterlegen" } }
            @{ Status = 'OK'; Count = 0; Detail = "$($common.Count) Konto/Konten in allen $($pols.Count) Richtlinien ausgenommen - vermutlich die Notfallkonten; bitte in den Sollwerten (V1 accounts) bestaetigen" }
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
    C02 = 'Gaeste in Teams mit Minderjaehrigen sind heikel. Hier nur die Zahl der Gastkonten, damit Aenderungen auffallen; die Mitgliedschaften zeigt C06.'
    C03 = 'Ein Team ohne Besitzer verwaltet niemand: keiner nimmt Mitglieder heraus, prueft Gaeste oder raeumt auf. Besitzer koennen auch ausgeschiedene Lehrkraefte gewesen sein, deren Konto geloescht wurde.'
    C04 = 'Nur zur Kenntnis: faellt der einzige Besitzer aus (Karenz, Abgang), ist das Team verwaist. Microsoft empfiehlt mindestens zwei Besitzer.'
    C05 = 'Einem oeffentlichen Team kann jeder im Tenant beitreten - auch Schueler - und Dateien und Unterhaltungen lesen. Klassen-Teams sind normalerweise privat. Gewollte oeffentliche Teams als Ausnahme eintragen.'
    C06 = 'Externe Personen in Teams mit Minderjaehrigen sehen Unterhaltungen, Dateien und Mitgliederlisten. Die Liste zeigt jeden Gast mit seinen Teams und M365-Gruppen (direkte Mitgliedschaft; Sicherheitsgruppen und Verteiler werden nicht geprueft). Gewollte Gaeste als Ausnahme eintragen.'
    C07 = 'Duerfen alle Benutzer Teams und M365-Gruppen anlegen, entstehen schnell viele Teams von Schuelern ohne Aufsicht. Empfohlen: Anlegen nur fuer eine Gruppe (z.B. Lehrkraefte) erlauben - Einstellung EnableGroupCreation und GroupCreationAllowedGroupId (Microsoft Learn, Gruppeneinstellungen). Sicherheitsgruppen prueft A22.'
    C08 = 'Ein Gast als Besitzer kann Mitglieder und weitere Gaeste aufnehmen. Standard bei Microsoft ist aus. Ob Gaeste ueberhaupt hinzugefuegt werden duerfen, steht zur Kenntnis dabei.'
    A25 = 'Ohne diese Sperre koennen normale Benutzer (auch Schueler) die Adminportale oeffnen und viele Verzeichnisdaten lesen. Gesucht wird eine aktive Richtlinie fuer alle Benutzer mit Blockieren und Ziel Microsoft-Adminportale. Ausgenommen sein duerfen nur Admin-Rollen, als Admin-Gruppe hinterlegte Gruppen (Sollwert A25 adminGroups) und hoechstens 4 einzelne Konten (Notfallkonten); jede andere Gruppe gilt als zu breite Ausnahme (Baseline 1.14). Hinweis laut Microsoft: die Sperre betrifft auch die Microsoft-365-Selbstinstallationsseite (Office-Installation durch Benutzer) und nicht Graph oder PowerShell.'
    A27 = 'Konten mit Admin-Rolle, die niemand mehr nutzt, sind ein leichtes Ziel. Gezaehlt werden aktive Konten mit Rolle (direkt oder ueber eine rollenzuweisbare Gruppe) ohne ERFOLGREICHE Anmeldung seit mehr als 90 Tagen (Sollwert staleDays; Baseline 1.10). Fehlversuche zaehlen nicht als Aktivitaet. Hinterlegte Notfallkonten (V1) sind ausgenommen. PIM-berechtigte Rollen (P2) und Dienstprinzipale werden nicht bewertet.'
    A28 = 'Entra Kennwortschutz verbietet bekannte schwache Kennwoerter auch im lokalen AD. Geprueft wird nur die Einstellung im Tenant (an, Modus Erzwingen); ob der Agent auf den Domaenencontrollern laeuft, sieht die App nicht (Baseline 1.1).'
    A29 = 'PIM vergibt Admin-Rechte nur zeitlich begrenzt und mit Genehmigung. Die Regel zeigt nur, ob die Lizenz vorhanden ist (Entra ID P2 oder ID Governance, erkannt ueber die Plan-ID; Baseline 1.3). Ersatz mit P1: dauerhafte Admin-Rollen klein halten und Rollen regelmaessig von Hand pruefen.'
    A30 = 'Wird ein Admin-Konto bei riskanter Anmeldung nicht abgefangen, bleibt ein gestohlenes Kennwort nutzbar. OK ist eine aktive Richtlinie fuer alle Benutzer oder Admin-Rollen bei Anmelderisiko mittel oder hoch, die blockiert oder MFA bei jeder Anmeldung verlangt (Microsoft-Vorlage). Braucht Entra ID P2 (Baseline 1.9); mit P1 helfen Geoblock, MFA fuer alle und das Blockieren von Legacy-Auth und Geraetecode-Flow.'
    A31 = 'Partner-Organisationen duerfen je nach Einstellung auf den Tenant zugreifen. Die Liste zeigt die konfigurierten Partner mit ihrer Tenant-ID (Baseline 1.6). Nicht ohne Not entfernen.'
    A33 = 'Anonyme Links ohne Anmeldung lassen sich weiterleiten, der Zugriff ist dann nicht mehr nachvollziehbar. Ob Links ein Ablaufdatum haben, liefert Graph nicht und wird nicht geprueft (Baseline 3.2).'
    A34 = 'SharePoint-Zugriff mit alten Protokollen umgeht MFA und bedingten Zugriff. Ausschalten, sobald keine alte Anwendung mehr darauf zugreift.'
    A35 = 'Externe Benutzer, die Freigaben weitergeben, vergroessern den Kreis der Zugriffsberechtigten ohne dein Zutun.'
    A36 = 'Nur zur Kenntnis: ob externe Freigaben auf bestimmte Domaenen beschraenkt sind und ob inaktive Sitzungen abgemeldet werden. Keine Abweichung, kein Sollwert.'
    A37 = 'Ein Admin-Konto aus dem lokalen AD faellt mit dem lokalen AD: wer dort ein Kennwort zuruecksetzt oder einen Domaenencontroller uebernimmt, hat auch den Tenant. Microsoft empfiehlt reine Cloud-Konten fuer Admin-Rollen. Gezaehlt werden Konten mit Rolle direkt oder ueber eine rollenzuweisbare Gruppe; PIM-berechtigte Rollen (P2) werden nicht aufgeloest.'
    A38 = 'Steht die Synchronisierung, bleiben ausgeschiedene Konten in der Cloud aktiv und neue fehlen. Bei Sync alle 30 Minuten (Standard) ist ein Abstand ueber 3 Stunden ein Ausfall. Sollwert: letzter Sync hoechstens 180 Minuten her.'
    A39 = 'Sync-Fehler entstehen meist durch doppelte UPN oder Mailadressen; das Objekt wird dann nicht oder nur teilweise synchronisiert. Die Liste zeigt Objekt, Eigenschaft und Wert.'
    A40 = 'SMS und Sprachanruf lassen sich per SIM-Tausch oder Weiterleitung abfangen. Microsoft empfiehlt Authenticator-App, Passkey oder FIDO2. Der E-Mail-Code wird nicht gewertet, weil Gaeste ihn zur Anmeldung brauchen koennen.'
    A41 = 'Duerfen Benutzer Apps nicht selbst zustimmen (A17), sollen sie wenigstens eine Freigabe anfragen koennen - sonst weichen sie auf Umwege aus.'
    A42 = 'Diese Rechte erlauben einer App ohne angemeldeten Benutzer, Rollen zu vergeben, das Verzeichnis oder Richtlinien zu aendern oder alle Postfaecher und Dateien zu lesen bzw. zu aendern. Geprueft werden nur Anwendungsrechte auf Microsoft Graph (nicht Exchange- oder SharePoint-eigene Schnittstellen und keine delegierten Zustimmungen fuer alle Benutzer). Die App dieses Programms wird angezeigt, aber nicht mitgezaehlt.'
    A32 = 'Der Secure Score von Microsoft zeigt in Prozent, wie viele Sicherheitsempfehlungen umgesetzt sind. Verlauf ueber den Katalog-Verlauf vergleichbar (Baseline 3.1).'
    A26 = 'Gaeste, die ihre Einladung nie angenommen haben, sind totes Gewicht und koennen spaeter von Dritten uebernommen werden (Mailadresse faellt weg oder wird neu vergeben). Laut Baseline 1.12 entfernen. Sollwert: Einladungen aelter als 30 Tage, gezaehlt ab der letzten (erneut gesendeten) Einladung.'
    A21 = 'Das alte MSOL-PowerShell wird nicht mehr unterstuetzt und umgeht moderne Schutzfunktionen. Blockieren, sobald keine Skripte es mehr nutzen.'
    A22 = 'Wenn jeder Benutzer Apps, Sicherheitsgruppen oder neue Tenants anlegen darf, entstehen unkontrollierte Zugriffe und Wildwuchs.'
    A23 = 'Gaeste bleiben sonst lange angemeldet. Eine Anmeldehaeufigkeit zwingt sie, sich regelmaessig neu zu authentifizieren. Gezaehlt wird eine aktive Richtlinie fuer Gaeste (oder alle Benutzer) mit Anmeldehaeufigkeit hoechstens 24 Stunden bzw. jedes Mal (Sollwert A23 maxHours; Baseline 1.8).'
    A24 = 'Anmeldungen aus Laendern, in denen niemand arbeitet, sind fast immer Angriffe. Gezaehlt wird eine aktive Richtlinie: Blockieren, alle Benutzer, alle Apps, keine Spezialbedingung (Geraetecode-Flow, Client-Apps, Plattform, Risiko, Benutzeraktion) und Laender-Standorte - als Sperrliste (Laender eingeschlossen) oder Erlaubnisliste (alle Orte ausser erlaubte Laender bzw. vertrauenswuerdige Orte). Reine IP-Bereiche zaehlen nicht. Welche Laender gesperrt sind, wird nicht bewertet; Ausnahmen werden genannt (Microsoft Learn, Block access by location).'
    V1  = 'Notfallkonten muessen von jeder Richtlinie ausgenommen sein, die aussperren kann, sonst sperrt eine fehlerhafte Richtlinie alle aus. Geprueft werden aktive Richtlinien fuer alle Benutzer oder Admin-Rollen, die blockieren oder etwas verlangen (MFA, Geraet, Nutzungsbedingungen ...); reine Sitzungs- und Berichtsrichtlinien brauchen keine Ausnahme (Microsoft Learn, Notfallzugriffskonten). Ausgenommene Gruppen werden aufgeloest (auch verschachtelt). Mit hinterlegten Notfallkonten (Sollwert V1 accounts, Objekt-IDs) muss jedes in jeder Richtlinie ausgenommen sein; ohne Sollwert muss mindestens ein Konto in allen Richtlinien ausgenommen sein. Rollen als Ausnahme zaehlen nicht. Ob das Konto selbst einen Passkey/FIDO2-Schluessel hat, wird nicht gelesen.'
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
        $b = if ($bl.Values.ContainsKey($r.Id)) { @{} + $bl.Values[$r.Id] } else { @{} }
        if ($bl.Values.ContainsKey('V1')) { $b['__breakGlass'] = $bl.Values['V1'].accounts }   # Notfallkonten fuer A25/A27
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
# Detailliste darf gespeichert werden: nur Listen ohne Personendaten (z. B. App-Namen und Rechte), am Regel-Schluessel Export = $true
function Test-HUSecItemsExport([string]$RuleId) {
    $rule = @(Get-HUSecRules | Where-Object { $_.Id -eq $RuleId })[0]
    return [bool]($rule -and $rule.PSObject.Properties['Export'] -and $rule.Export)
}

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
    $b = if ($bl.Values.ContainsKey($RuleId)) { @{} + $bl.Values[$RuleId] } else { @{} }
    if ($bl.Values.ContainsKey('V1')) { $b['__breakGlass'] = $bl.Values['V1'].accounts }
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
        # Namen der Ausnahmen gesammelt aufloesen (je 15 IDs ein Abruf, Review 037 B16); nicht gefunden = geloescht oder nicht lesbar
        $g = [guid]::Empty
        $uIds = @($items | ForEach-Object { @($_.__ExU) } | Where-Object { [guid]::TryParse("$_", [ref]$g) } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
        $gIds = @($items | ForEach-Object { @($_.__ExG) } | Where-Object { [guid]::TryParse("$_", [ref]$g) } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)
        $names = @{}; $failed = $false
        foreach ($set in @(@{ Ids = $uIds; Ep = '/users'; Sel = 'id,userPrincipalName'; Fmt = { param($o) "$($o.userPrincipalName)" } }, @{ Ids = $gIds; Ep = '/groups'; Sel = 'id,displayName'; Fmt = { param($o) "Gruppe $($o.displayName)" } })) {
            $ids = @($set.Ids | Select-Object -First 500)
            for ($i = 0; $i -lt $ids.Count; $i += 15) {
                $chunk = @($ids[$i..([math]::Min($i + 14, $ids.Count - 1))])
                $f = ($chunk | ForEach-Object { "'$_'" }) -join ','
                try { foreach ($o in @(Invoke-HUSecFetch -TenantKey $TenantKey -Settings $Settings -Endpoint "$($set.Ep)?`$filter=id%20in%20($f)&`$select=$($set.Sel)" -All)) { $names["$($o.id)".ToLowerInvariant()] = (& $set.Fmt $o) } }
                catch { $failed = $true }
            }
        }
        $miss = if ($failed) { '(nicht lesbar)' } else { '(geloescht oder nicht gefunden)' }
        foreach ($it in $items) {
            $n = @(@($it.__ExU) + @($it.__ExG) | Where-Object { $_ } | ForEach-Object { $k = "$_".ToLowerInvariant(); if ($names.ContainsKey($k)) { $names[$k] } else { $miss } })
            $it | Add-Member -NotePropertyName Ausnahmen -NotePropertyValue $(if ($n.Count) { ($n -join ', ') } else { '-' }) -Force
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
    # Review 038 B7: ist der neue Stand schlechter als der bisherige Soll, wird das vermerkt (Hinweis beim Speichern und einmal in Teams)
    $old = $null; try { $old = Get-HUSecReference } catch { }
    $worse = 0
    if ($old) { $worse = @((Compare-HUSecReference -Results $Results -Reference $old).Changes | Where-Object { $_.Worse }).Count }
    $snap = [pscustomobject]@{ version = 1; time = $Now.ToUniversalTime().ToString('o'); rows = $rows; worse = $worse; prevTime = $(if ($old) { "$($old.time)" } else { '' }); worseShown = $false }
    $f = Join-Path (Get-HUSecPath) 'soll.json'
    Write-HUSecJson $f $snap
    Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'soll-verloren.json') -Force -ErrorAction SilentlyContinue   # neuer Soll-Stand: Zaehler neu
    return $f
}

# Vorschau vor dem Speichern: wie viele Regeln waeren im neuen Soll schlechter als im bisherigen (Liste der Aenderungen)
function Get-HUSecReferenceWorse {
    param([Parameter(Mandatory)][object[]]$Results)
    $old = $null; try { $old = Get-HUSecReference } catch { }
    if (-not $old) { return @() }
    return @((Compare-HUSecReference -Results $Results -Reference $old).Changes | Where-Object { $_.Worse })
}

# Hinweis "Soll schlechter" wurde in Teams gemeldet
function Set-HUSecReferenceWorseShown {
    $f = Join-Path (Get-HUSecPath) 'soll.json'
    $j = $null; try { $j = Read-HUSecJson $f } catch { }
    if (-not $j) { return }
    $j | Add-Member -NotePropertyName worseShown -NotePropertyValue $true -Force
    Write-HUSecJson $f $j
}

function Get-HUSecReference {
    # $null = kein Soll-Stand gespeichert
    $j = $null
    try { $j = Read-HUSecJson (Join-Path (Get-HUSecPath) 'soll.json') } catch { return $null }
    if (-not $j -or -not $j.rows) { return $null }
    return $j
}

# Vergleich Ist gegen Soll. Nur Regeln, die in beiden Staenden pruefbar sind (OK/Abweichung/Ausnahme), zaehlen als Aenderung;
# NichtPruefbar/Fehler/Info sind keine Aenderung (sonst Meldungen bei jedem Abruffehler). Gezaehlt werden nur Regeln, die im Soll pruefbar waren und jetzt nicht (Unchecked); dauerhaft nicht pruefbare zaehlen nicht.
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
        if ($r.Status -notin $checkable -or $o.status -notin $checkable) { if ($o.status -in $checkable -and $r.Status -notin $checkable -and $r.Status -ne 'Info') { $unchecked++ }; continue }
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
    'Get-HUSecBaseline', 'Save-HUSecSnapshot', 'Save-HUSecReference', 'Get-HUSecReference', 'Compare-HUSecReference', 'Update-HUSecLost', 'Get-HUSecReferenceWorse', 'Set-HUSecReferenceWorseShown', 'Get-HUSecBaselineEdit', 'Save-HUSecBaselineEdit', 'Get-HUSecPath', 'Get-HUSecMatrix', 'Get-HUSecCoverage', 'Get-HUSecLight', 'Get-HUSecWhy', 'Get-HUSecItems', 'Get-HUSecItemsLabel', 'Test-HUSecItemsExport'
)
