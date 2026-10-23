#Requires -Version 5.1
<#
.SYNOPSIS
    Entra-Einstellungen aus einem Backup-Stand in DENSELBEN Tenant zurueckschreiben (Etappe 1).
.DESCRIPTION
    Unterstuetzt: Autorisierungsrichtlinie, Administratorzustimmung (Anfragen), benannte Orte (nur aendern),
    Verzeichniseinstellungen (nur aendern). Ablauf: Get-HUEntraRestorePlan liest den Live-Stand, vergleicht mit dem
    Backup und baut den Aufruf (nur dokumentiert beschreibbare Felder, Pruefungen, Warnungen). Invoke-HUEntraRestore
    liest unmittelbar davor erneut (Abbruch, wenn sich etwas geaendert hat), sichert den Live-Stand als Datei, schreibt
    und liest zur Kontrolle nach. Grundlage: Konzept 043 (Microsoft Learn, Graph v1.0), keine Massen-Wiederherstellung.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Braucht HU.Intune (Graph-Aufrufe, Backup-Pfad) und
    HU.SecCatalog (hinterlegte Notfallkonten, Sollwert V1).
#>

# Gast-Rollen: nur diese drei Rollen-Vorlagen sind fuer guestUserRoleId erlaubt (Learn, authorizationPolicy)
$script:HUErGuestRoles = @('a0b1b346-4d3e-4e8b-98f8-753987be4970', '10dae51f-b6af-4016-8d66-8c2a99b929b3', '2af84b1e-32c8-42b7-82bc-daa82404023b')
$script:HUErAuthzTop = @('allowEmailVerifiedUsersToJoinOrganization', 'allowInvitesFrom', 'allowUserConsentForRiskyApps', 'allowedToSignUpEmailBasedSubscriptions', 'allowedToUseSSPR', 'blockMsolPowerShell', 'guestUserRoleId')
$script:HUErDurp = @('allowedToCreateApps', 'allowedToCreateSecurityGroups', 'allowedToCreateTenants', 'allowedToReadBitlockerKeysForOwnedDevice', 'allowedToReadOtherUsers', 'permissionGrantPoliciesAssigned')
$script:HUErConsent = @('isEnabled', 'notifyReviewers', 'remindersEnabled', 'requestDurationInDays', 'reviewers')
# Felder, die nie gesendet werden und auch nicht als "verworfen" gelten (Verwaltung, Anzeige)
# assignments: das Backup haengt sie an jedes Objekt an (bei Entra-Arten und CA leer) - kein Feld der Richtlinie
$script:HUErIgnore = @('id', 'displayName', 'description', 'createdDateTime', 'modifiedDateTime', 'lastModifiedDateTime', 'version', 'deletedDateTime', 'templateId', 'assignments')
$script:HUErPwRuleTpl = '5cf42378-d67d-4f36-ba46-e8b86229381d'
$script:HUErPwRuleP1 = @('BannedPasswordList', 'EnableBannedPasswordCheck', 'LockoutThreshold', 'LockoutDurationInSeconds')
# Felder, deren Inhalt nie ins Protokoll kommt (nur "geaendert")
$script:HUErNoLog = @('values[BannedPasswordList]')
# Vorschau: ab dieser Laenge wird gekuerzt (voller Wert per Klick auf die Zeile)
$script:HUErShowMax = 300

# Welche Backup-Eintraege lassen sich zurueckschreiben? -> authz | consent | location | groupSetting | ''
function Get-HUEntraRestoreKind([string]$Typ, [string]$Id) {
    switch ($Typ) {
        'Entra-Einstellung' { if ($Id -eq 'authorizationPolicy') { return 'authz' }; if ($Id -eq 'adminConsentRequestPolicy') { return 'consent' }; return '' }
        'Benannter Ort' { return 'location' }
        'Verzeichniseinstellung' { return 'groupSetting' }
        'Conditional Access' { return 'caNew' }
        default { return '' }
    }
}

# Wert einer Eigenschaft (oder $null) - auch fuer Namen mit Punkt/@ (z. B. @odata.type)
function Get-HUErProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}
function Test-HUErHas($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
    return [bool]$Obj.PSObject.Properties[$Name]
}

# Vergleichbare Form: Skalare als Text (Gross/klein egal), Listen sortiert (Reihenfolge egal), Objekte als JSON mit sortierten Schluesseln
function ConvertTo-HUErComparable($V) {
    if ($null -eq $V) { return '<null>' }
    if ($V -is [string] -or $V -is [ValueType]) { return "$V".ToLowerInvariant() }
    if ($V -is [System.Collections.IEnumerable] -and -not ($V -is [System.Collections.IDictionary])) {
        return '[' + ((@($V | ForEach-Object { ConvertTo-HUErComparable $_ }) | Sort-Object) -join '|') + ']'
    }
    # IP-Bereiche nur ueber die Adresse vergleichen (@odata.type kann im Backup fehlen)
    $cidr = Get-HUErProp $V 'cidrAddress'
    if ($cidr) { return "$cidr".ToLowerInvariant() }
    return ((ConvertTo-HUCleanObject $V @('@odata.context')) | ConvertTo-Json -Depth 30 -Compress).ToLowerInvariant()
}
function Test-HUErEqual($A, $B) { return ((ConvertTo-HUErComparable $A) -eq (ConvertTo-HUErComparable $B)) }

# Wahrheitswert sicher lesen: Text "false"/"0" ist falsch (in PowerShell waere [bool]"false" wahr)
function ConvertTo-HUErBool($V) {
    if ($null -eq $V) { return $false }
    if ($V -is [bool]) { return $V }
    if ($V -is [string]) { return ($V.Trim() -in 'true', '1') }
    return [bool]$V
}

# Anzahl Eintraege (Liste oder Text mit Komma/Zeilen, z. B. BannedPasswordList) - 0 = kein Listenwert
function Get-HUErCount($V) {
    if ($null -eq $V) { return 0 }
    if ($V -is [string]) { $p = @($V -split '[\t\r\n,]+' | Where-Object { $_.Trim() }); if ($p.Count -gt 1) { return $p.Count }; return 0 }
    if ($V -is [System.Collections.IEnumerable] -and -not ($V -is [System.Collections.IDictionary])) { return @($V).Count }
    # einzelner Listeneintrag (PowerShell entpackt Listen mit einem Element)
    if ((Get-HUErProp $V 'cidrAddress') -or (Get-HUErProp $V 'query')) { return 1 }
    return 0
}
# Anzeige in der Vorschau. Ohne -Full ab $script:HUErShowMax Zeichen gekuerzt (B1: der volle Wert ist in der Vorschau aufklappbar).
# ein Listenelement lesbar: IP-Bereich als Adresse, Abfrage als Text, sonst JSON
function Format-HUErItem($E) {
    if ($E -is [string] -or $E -is [ValueType]) { return "$E" }
    if (Get-HUErProp $E 'cidrAddress') { return "$(Get-HUErProp $E 'cidrAddress')" }
    if (Get-HUErProp $E 'query') { return "$(Get-HUErProp $E 'query')" }
    return ((ConvertTo-HUCleanObject $E @('@odata.context')) | ConvertTo-Json -Depth 10 -Compress)
}

function Format-HUErValue($V, [switch]$Full) {
    if ($null -eq $V) { return '(leer)' }
    $t = ''
    if ($V -is [string]) { if ($V -eq '') { return '(leer)' }; $t = $V }
    elseif ($V -is [ValueType]) { return "$V" }
    elseif ($V -is [System.Collections.IEnumerable] -and -not ($V -is [System.Collections.IDictionary])) {
        $l = @($V)
        if (-not $l.Count) { return '(leer)' }
        $t = @($l | ForEach-Object { Format-HUErItem $_ }) -join ', '
    } else {
        # einzelnes Listenelement kommt in PowerShell oft ausgepackt an (z. B. ein IP-Bereich) - genauso lesbar zeigen
        $t = Format-HUErItem $V
    }
    if (-not $Full -and $t.Length -gt $script:HUErShowMax) { $t = $t.Substring(0, $script:HUErShowMax) + ' ...' }
    return $t
}

# Fingerabdruck des Live-Stands (fuer "hat sich seit der Vorschau etwas geaendert?")
function Get-HUErHash($Obj) {
    $j = (ConvertTo-HUCleanObject $Obj @('@odata.context')) | ConvertTo-Json -Depth 40 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$j"))) -replace '-', '').Substring(0, 20) } finally { $sha.Dispose() }
}

# Wert ueber einen Pfad: 'a', 'a.b', 'values[Name]'
function Get-HUErPathValue($Obj, [string]$Path) {
    $cur = $Obj
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $m = [regex]::Match($seg, '^(\w+)\[(.+)\]$')
        if ($m.Success) {
            $hit = @(@(Get-HUErProp $cur $m.Groups[1].Value) | Where-Object { "$(Get-HUErProp $_ 'name')" -eq $m.Groups[2].Value }) | Select-Object -First 1
            $cur = if ($hit) { Get-HUErProp $hit 'value' } else { $null }
        } else { $cur = Get-HUErProp $cur $seg }
    }
    return $cur
}

# Graph v1.0 kurz
function Invoke-HUErGraph([string]$TenantKey, $Settings, [string]$Endpoint, [string]$Method = 'GET', [hashtable]$Body) {
    if ($Method -eq 'GET') { return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $Endpoint -V1) }
    return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $Endpoint -Method $Method -Body $Body -V1 -NoRetry)
}
function Test-HUErExists([string]$TenantKey, $Settings, [string]$Endpoint) {
    try { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $Endpoint -V1 -NoRetry); return $true }
    catch { if ($_.Exception.Data['StatusCode'] -eq 404) { return $false }; throw }
}

# Notfallkonten (Sollwert V1 im Sicherheitskatalog): hinterlegt, vorhanden, aktiv -> @{ Ok; Text }
function Test-HUEntraBreakGlass {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $ids = @()
    try { $bl = Get-HUSecBaseline -TenantKey $TenantKey; if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { $ids = @($bl.Values['V1'].accounts | Where-Object { "$_" }) } } catch { }
    if (-not $ids.Count) { return [pscustomobject]@{ Ok = $false; Text = 'Keine Notfallkonten hinterlegt (Analyse > Sicherheit > Sollwerte, V1 accounts). Ohne Notfallkonten wird diese Einstellung nicht zurueckgeschrieben.' } }
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($id in $ids) {
        try {
            $u = Invoke-HUErGraph $TenantKey $Settings "/users/$id`?`$select=id,accountEnabled,userPrincipalName"
            if (-not (ConvertTo-HUErBool $u.accountEnabled)) { $bad.Add("$($u.userPrincipalName) ist deaktiviert") }
        } catch {
            if ($_.Exception.Data['StatusCode'] -eq 404) { $bad.Add("Konto $id gibt es nicht mehr") } else { $bad.Add("Konto $id nicht pruefbar ($($_.Exception.Message))") }
        }
    }
    if ($bad.Count) { return [pscustomobject]@{ Ok = $false; Text = "Notfallkonten nicht in Ordnung: $($bad -join '; '). Erst beheben, dann zurueckschreiben." } }
    return [pscustomobject]@{ Ok = $true; Text = "$($ids.Count) Notfallkonto/-konten vorhanden und aktiv." }
}

function New-HUErPlan([string]$Kind, [string]$TenantKey, [string]$Typ, [string]$Name) {
    return [pscustomobject]@{
        Kind = $Kind; TenantKey = $TenantKey; Typ = $Typ; Name = $Name; Method = ''; Endpoint = ''; ReadEndpoint = ''; Perm = ''
        Body = $null; Changes = New-Object System.Collections.Generic.List[object]; Dropped = New-Object System.Collections.Generic.List[string]
        Blocks = New-Object System.Collections.Generic.List[string]; Warnings = New-Object System.Collections.Generic.List[string]
        Confirms = New-Object System.Collections.Generic.List[string]; Notes = New-Object System.Collections.Generic.List[string]
        BreakGlass = $null; LiveHash = ''; Live = $null
    }
}
function Add-HUErChange($Plan, [string]$Path, $Now, $Then) {
    $jf = Format-HUErValue $Now -Full; $df = Format-HUErValue $Then -Full
    $nj = Get-HUErCount $Now; $nd = Get-HUErCount $Then
    $Plan.Changes.Add([pscustomobject]@{
            Feld = $Path; Jetzt = (Format-HUErValue $Now); Danach = (Format-HUErValue $Then); Expected = $Then
            JetztVoll = $jf; DanachVoll = $df
            Anzahl = $(if ($nj -or $nd) { "$nj -> $nd" } else { '' })
            Gekuerzt = ($jf.Length -gt $script:HUErShowMax -or $df.Length -gt $script:HUErShowMax)
        })
}
# Felder im Backup, die nicht geschrieben werden (B4: in der Vorschau zeigen)
function Add-HUErDropped($Plan, $Backup, [string[]]$Allowed) {
    foreach ($p in @($Backup.PSObject.Properties)) {
        if ($p.Name -match '^@' -or $Allowed -contains $p.Name -or $script:HUErIgnore -contains $p.Name) { continue }
        if (-not $Plan.Dropped.Contains($p.Name)) { $Plan.Dropped.Add($p.Name) }
    }
}

# ---------- Autorisierungsrichtlinie: PATCH, nur Abweichungen ----------
function Get-HUErPlanAuthz($Plan, [string]$TenantKey, $Settings, $Backup) {
    $Plan.Method = 'PATCH'; $Plan.Endpoint = '/policies/authorizationPolicy'; $Plan.ReadEndpoint = '/policies/authorizationPolicy'; $Plan.Perm = 'Policy.ReadWrite.Authorization'
    $live = Invoke-HUErGraph $TenantKey $Settings $Plan.ReadEndpoint
    $Plan.Live = $live; $Plan.LiveHash = Get-HUErHash $live
    $body = @{}
    foreach ($f in $script:HUErAuthzTop) {
        if (-not (Test-HUErHas $Backup $f)) { continue }
        $b = Get-HUErProp $Backup $f
        if ($null -eq $b) { continue }   # null nie senden
        $l = Get-HUErProp $live $f
        if (Test-HUErEqual $b $l) { continue }
        if ($f -eq 'guestUserRoleId' -and $script:HUErGuestRoles -notcontains "$b".ToLowerInvariant()) { $Plan.Blocks.Add("guestUserRoleId im Backup ($b) ist keine der drei erlaubten Gast-Rollen."); continue }
        $body[$f] = $b
        Add-HUErChange $Plan $f $l $b
    }
    $bd = Get-HUErProp $Backup 'defaultUserRolePermissions'
    if ($bd) {
        $ld = Get-HUErProp $live 'defaultUserRolePermissions'
        $diff = @($script:HUErDurp | Where-Object { $null -ne (Get-HUErProp $bd $_) -and -not (Test-HUErEqual (Get-HUErProp $bd $_) (Get-HUErProp $ld $_)) })
        if ($diff.Count) {
            # Unterobjekt vollstaendig senden (Zusammenfuehren nicht zugesichert)
            $sub = @{}
            foreach ($f in $script:HUErDurp) {
                $v = Get-HUErProp $bd $f
                if ($null -eq $v) { $v = Get-HUErProp $ld $f }
                if ($null -eq $v) { continue }
                if ($f -eq 'permissionGrantPoliciesAssigned') { $sub[$f] = [object[]]@($v) } else { $sub[$f] = $v }
            }
            $body['defaultUserRolePermissions'] = $sub
            foreach ($f in $diff) { Add-HUErChange $Plan "defaultUserRolePermissions.$f" (Get-HUErProp $ld $f) $sub[$f] }
            if ($sub.ContainsKey('allowedToReadOtherUsers') -and -not (ConvertTo-HUErBool $sub['allowedToReadOtherUsers'])) {
                $Plan.Blocks.Add('allowedToReadOtherUsers = false ist gesperrt (Microsoft: "DO NOT SET THIS VALUE TO false").')
            }
            if ($diff -contains 'permissionGrantPoliciesAssigned') {
                $pol = @($sub['permissionGrantPoliciesAssigned'])
                $custom = @($pol | ForEach-Object { ("$_" -split '\.', 2)[-1] } | Where-Object { $_ -and $_ -notlike 'microsoft-*' } | Select-Object -Unique)
                if ($custom.Count) {
                    $known = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/policies/permissionGrantPolicies?$select=id' -V1 | ForEach-Object { "$($_.id)" })
                    foreach ($c in $custom) { if ($known -notcontains $c) { $Plan.Blocks.Add("Zustimmungsrichtlinie '$c' gibt es im Tenant nicht mehr.") } }
                }
                $lostOwned = @(@(Get-HUErProp $ld 'permissionGrantPoliciesAssigned') | Where-Object { "$_" -like 'ManagePermissionGrantsForOwnedResource.*' -and @($pol | ForEach-Object { "$_".ToLowerInvariant() }) -notcontains "$_".ToLowerInvariant() })
                if ($lostOwned.Count) { $Plan.Confirms.Add("Entfernt Zustimmungsrechte fuer eigene Apps: $($lostOwned -join ', ')") }
            }
        }
    }
    if ($body.ContainsKey('allowInvitesFrom') -and "$($body['allowInvitesFrom'])" -eq 'none') { $Plan.Confirms.Add('allowInvitesFrom = none: niemand, auch kein Admin, kann danach Gaeste einladen.') }
    if ($body.ContainsKey('allowedToUseSSPR') -and -not (ConvertTo-HUErBool $body['allowedToUseSSPR'])) { $Plan.Confirms.Add('allowedToUseSSPR = false: Admins koennen ihr Kennwort nicht mehr selbst zuruecksetzen (wirkt bis zu 60 Minuten verzoegert).') }
    $Plan.Body = $body
    Add-HUErDropped $Plan $Backup ($script:HUErAuthzTop + @('defaultUserRolePermissions'))
    $Plan.BreakGlass = $true
}

# ---------- Administratorzustimmung: PUT, Live-Objekt + Backup-Felder ----------
function Test-HUErReviewer([string]$TenantKey, $Settings, $Rev) {
    $q = "$(Get-HUErProp $Rev 'query')"
    $g = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $m = [regex]::Match($q, "^(/v1\.0|/beta)?/users/$g$")
    if ($m.Success) { if (Test-HUErExists $TenantKey $Settings "/users/$($m.Groups[2].Value)?`$select=id") { return '' }; return "Reviewer-Benutzer $($m.Groups[2].Value) gibt es nicht mehr" }
    $m = [regex]::Match($q, "^(/v1\.0|/beta)?/groups/$g(/.*)?$")
    if ($m.Success) { if (Test-HUErExists $TenantKey $Settings "/groups/$($m.Groups[2].Value)?`$select=id") { return '' }; return "Reviewer-Gruppe $($m.Groups[2].Value) gibt es nicht mehr" }
    # Rolle als Pfad (/roleManagement/directory/roleDefinitions/{id}) oder als Filter (roleDefinitionId eq '{id}')
    $m = [regex]::Match($q, "^(/v1\.0|/beta)?/roleManagement/directory/roleDefinitions/$g$")
    $rid = if ($m.Success) { $m.Groups[2].Value } else { $m = [regex]::Match($q, "roleDefinitionId\s+eq\s+'$g'"); if ($m.Success) { $m.Groups[1].Value } else { '' } }
    if ($rid) { if (Test-HUErExists $TenantKey $Settings "/roleManagement/directory/roleDefinitions/$rid`?`$select=id") { return '' }; return "Reviewer-Rolle $rid gibt es nicht" }
    return "Reviewer '$q' laesst sich nicht pruefen"
}
function Get-HUErPlanConsent($Plan, [string]$TenantKey, $Settings, $Backup) {
    $Plan.Method = 'PUT'; $Plan.Endpoint = '/policies/adminConsentRequestPolicy'; $Plan.ReadEndpoint = '/policies/adminConsentRequestPolicy'; $Plan.Perm = 'Policy.ReadWrite.ConsentRequest'
    $live = Invoke-HUErGraph $TenantKey $Settings $Plan.ReadEndpoint
    $Plan.Live = $live; $Plan.LiveHash = Get-HUErHash $live
    $body = @{}
    foreach ($f in $script:HUErConsent) {
        $l = Get-HUErProp $live $f
        $b = if (Test-HUErHas $Backup $f) { Get-HUErProp $Backup $f } else { $null }
        $v = if ($null -ne $b) { $b } else { $l }
        if ($null -eq $v) { continue }
        if ($f -eq 'reviewers') {
            $v = [object[]]@(@($v) | ForEach-Object { $r = @{}; foreach ($k in 'query', 'queryType', 'queryRoot') { $x = Get-HUErProp $_ $k; if ($null -ne $x) { $r[$k] = $x } }; $r })
        }
        $body[$f] = $v
        if ($null -ne $b -and -not (Test-HUErEqual $b $l)) {
            Add-HUErChange $Plan $f $l $b
            if ($f -eq 'reviewers') { foreach ($r in @($b)) { $e = Test-HUErReviewer $TenantKey $Settings $r; if ($e) { $Plan.Blocks.Add("$e.") } } }
        }
    }
    $Plan.Body = $body
    $Plan.Notes.Add('Wirkung bis zu einer Stunde verzoegert; neue Reviewer sehen keine aelteren Anfragen.')
    Add-HUErDropped $Plan $Backup $script:HUErConsent
    $Plan.BreakGlass = $false
}

# ---------- Benannter Ort: nur aendern, PATCH mit @odata.type und ganzer Liste ----------
function Get-HUErPlanLocation($Plan, [string]$TenantKey, $Settings, $Backup) {
    $id = "$(Get-HUErProp $Backup 'id')"
    $type = "$(Get-HUErProp $Backup '@odata.type')"
    $Plan.Method = 'PATCH'; $Plan.Endpoint = "/identity/conditionalAccess/namedLocations/$id"; $Plan.ReadEndpoint = $Plan.Endpoint; $Plan.Perm = 'Policy.ReadWrite.ConditionalAccess (und Policy.Read.All)'
    if (-not $id) { $Plan.Blocks.Add('Der Backup-Eintrag hat keine Kennung.'); return }
    if ($type -notin '#microsoft.graph.ipNamedLocation', '#microsoft.graph.countryNamedLocation') { $Plan.Blocks.Add("Ortstyp '$type' wird nicht zurueckgeschrieben."); return }
    $live = $null
    try { $live = Invoke-HUErGraph $TenantKey $Settings $Plan.ReadEndpoint }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 404) {
            $Plan.Blocks.Add('Diesen Ort gibt es nicht mehr. Neu anlegen ist nicht vorgesehen (neue Kennung, Conditional Access verweist auf die alte). Geloeschte Orte lassen sich 30 Tage lang im Entra Admin Center unter "Geloeschte Elemente" wiederherstellen - danach sind sie nicht mehr als vertrauenswuerdig markiert, bitte pruefen.')
            return
        }
        throw
    }
    $Plan.Live = $live; $Plan.LiveHash = Get-HUErHash $live
    if ("$(Get-HUErProp $live '@odata.type')" -ne $type) { $Plan.Blocks.Add('Der Ort hat inzwischen einen anderen Typ - nicht zurueckschreibbar.'); return }
    $fields = if ($type -eq '#microsoft.graph.ipNamedLocation') { @('displayName', 'ipRanges', 'isTrusted') } else { @('displayName', 'countriesAndRegions', 'includeUnknownCountriesAndRegions') }
    $body = @{ '@odata.type' = $type }
    foreach ($f in $fields) {
        $b = Get-HUErProp $Backup $f
        if ($null -eq $b) { continue }
        $l = Get-HUErProp $live $f
        if ($f -eq 'ipRanges') {
            $cmpB = @(@($b) | ForEach-Object { "$(Get-HUErProp $_ 'cidrAddress')" }); $cmpL = @(@($l) | ForEach-Object { "$(Get-HUErProp $_ 'cidrAddress')" })
            if (Test-HUErEqual $cmpB $cmpL) { continue }
            $v = [object[]]@(@($b) | ForEach-Object {
                    $cidr = "$(Get-HUErProp $_ 'cidrAddress')"
                    $t = "$(Get-HUErProp $_ '@odata.type')"
                    if (-not $t) { $t = if ($cidr.Contains(':')) { '#microsoft.graph.iPv6CidrRange' } else { '#microsoft.graph.iPv4CidrRange' } }
                    @{ '@odata.type' = $t; cidrAddress = $cidr }
                })
            if (-not $v.Count) { $Plan.Blocks.Add('Die Bereichsliste im Backup ist leer.'); continue }
            $body[$f] = $v
            Add-HUErChange $Plan $f $l $b
            continue
        }
        if (Test-HUErEqual $b $l) { continue }
        $body[$f] = $(if ($f -eq 'countriesAndRegions') { [object[]]@($b) } else { $b })
        Add-HUErChange $Plan $f $l $b
        if ($f -eq 'isTrusted') { $Plan.Confirms.Add("Vertrauenswuerdig wird $(if (ConvertTo-HUErBool $b) { 'EIN' } else { 'AUS' })geschaltet - wirkt auf alle Richtlinien mit 'Alle vertrauenswuerdigen Orte'.") }
        if ($f -eq 'includeUnknownCountriesAndRegions') { $Plan.Confirms.Add('Unbekannte Laender/Regionen werden geaendert - bei blockierenden Richtlinien koennen Benutzer ausgesperrt werden.') }
    }
    $Plan.Body = $body
    Add-HUErDropped $Plan $Backup $fields
    $Plan.Notes.Add('Wirkung fuer angemeldete Benutzer bis zu einer Stunde verzoegert (Token-Erneuerung).')
    $Plan.BreakGlass = $true
}

# ---------- Verzeichniseinstellung: nur aendern, Zuordnung ueber templateId, ganze values-Liste ----------
function Get-HUErPlanGroupSetting($Plan, [string]$TenantKey, $Settings, $Backup) {
    $tpl = "$(Get-HUErProp $Backup 'templateId')"
    $Plan.Method = 'PATCH'; $Plan.Perm = 'GroupSettings.ReadWrite.All'
    if (-not $tpl) { $Plan.Blocks.Add('Der Backup-Eintrag hat keine Vorlagen-Kennung (templateId).'); return }
    $all = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/groupSettings' -V1)
    $live = @($all | Where-Object { "$($_.templateId)" -eq $tpl }) | Select-Object -First 1
    if (-not $live) { $Plan.Blocks.Add('Zu dieser Vorlage gibt es im Tenant kein Einstellungsobjekt. Neu anlegen ist in dieser Version nicht vorgesehen.'); return }
    $Plan.Endpoint = "/groupSettings/$($live.id)"; $Plan.ReadEndpoint = $Plan.Endpoint
    # einzeln lesen wie spaeter beim zweiten Lesen und bei der Nachpruefung (gleiche Form fuer den Fingerabdruck)
    $live = Invoke-HUErGraph $TenantKey $Settings $Plan.ReadEndpoint
    $Plan.Live = $live; $Plan.LiveHash = Get-HUErHash $live
    $vals = [ordered]@{}
    foreach ($v in @($live.values)) { if ("$($v.name)" -and "$($v.name)" -ne 'EnableMSStandardBlockedWords') { $vals["$($v.name)"] = "$($v.value)" } }
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($v in @(Get-HUErProp $Backup 'values')) {
        $n = "$(Get-HUErProp $v 'name')"; if (-not $n -or $n -eq 'EnableMSStandardBlockedWords') { continue }
        $bv = Get-HUErProp $v 'value'; if ($null -eq $bv) { continue }
        $lv = if ($vals.Contains($n)) { $vals[$n] } else { $null }
        if (Test-HUErEqual "$bv" $lv) { continue }
        $vals[$n] = "$bv"; $changed.Add($n)
        Add-HUErChange $Plan "values[$n]" $lv "$bv"
    }
    $Plan.Body = @{ values = [object[]]@($vals.Keys | ForEach-Object { @{ name = $_; value = $vals[$_] } }) }
    if ($changed.Contains('GroupCreationAllowedGroupId') -and "$($vals['GroupCreationAllowedGroupId'])") {
        if (-not (Test-HUErExists $TenantKey $Settings "/groups/$($vals['GroupCreationAllowedGroupId'])?`$select=id")) { $Plan.Blocks.Add("Die Gruppe fuer GroupCreationAllowedGroupId ($($vals['GroupCreationAllowedGroupId'])) gibt es nicht mehr.") }
    }
    if ($changed.Contains('EnableGroupCreation') -and "$($vals['EnableGroupCreation'])" -eq 'false') { $Plan.Confirms.Add('EnableGroupCreation = false: Nicht-Admins koennen danach keine Microsoft-365-Gruppen und keine Teams mehr anlegen.') }
    if ($tpl -eq $script:HUErPwRuleTpl) {
        if (@($changed | Where-Object { $script:HUErPwRuleP1 -contains $_ }).Count) {
            $p1 = $false
            foreach ($s in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/subscribedSkus?$select=servicePlans' -V1)) {
                if (@($s.servicePlans | Where-Object { "$($_.servicePlanName)" -in 'AAD_PREMIUM', 'AAD_PREMIUM_P2' -and "$($_.provisioningStatus)" -eq 'Success' }).Count) { $p1 = $true; break }
            }
            if (-not $p1) { $Plan.Blocks.Add('Eigene Kennwortliste und Sperrschwelle brauchen Microsoft Entra ID P1 - die Lizenz fehlt im Tenant.') }
        }
        $th = 0; $du = 0
        if ([int]::TryParse("$($vals['LockoutThreshold'])", [ref]$th) -and $changed.Contains('LockoutThreshold') -and $th -lt 5) { $Plan.Warnings.Add("Sperrschwelle $th ist sehr niedrig - Benutzer werden schnell gesperrt.") }
        if ([int]::TryParse("$($vals['LockoutDurationInSeconds'])", [ref]$du) -and $changed.Contains('LockoutDurationInSeconds') -and $du -lt 60) { $Plan.Warnings.Add("Sperrdauer $du s liegt unter dem Standard von 60 s.") }
        if ($changed.Contains('BannedPasswordList')) { $Plan.Notes.Add('Die Kennwortliste kann einige Stunden brauchen, bis sie wirkt.') }
    }
    if (@(@(Get-HUErProp $Backup 'values') | Where-Object { "$(Get-HUErProp $_ 'name')" -eq 'EnableMSStandardBlockedWords' }).Count) { $Plan.Dropped.Add('EnableMSStandardBlockedWords (von Microsoft eingestellt)') }
    Add-HUErDropped $Plan $Backup @('values')
    $Plan.BreakGlass = $false
}

# Regel A-1: nur in denselben Tenant. Steht im Backup-Stand (index.json) ein Tenant-Schluessel oder eine
# Tenant-ID und weicht sie vom Ziel ab -> Abbruch. Aeltere Staende ohne TenantId: der Ordner ist die Schranke.
function Assert-HUErSameTenant([string]$TenantKey, $Settings, $BackupIndex) {
    if ($null -eq $BackupIndex) { return }
    $bk = "$(Get-HUErProp $BackupIndex 'Tenant')"
    if ($bk -and $bk -ne $TenantKey) { throw "Der Backup-Stand gehoert zu Tenant '$bk', Ziel ist '$TenantKey'. Zurueckschreiben nur in denselben Tenant - nichts geschrieben." }
    $bid = "$(Get-HUErProp $BackupIndex 'TenantId')"
    if (-not $bid) { return }
    $tid = "$(@($Settings.tenants | Where-Object { $_.key -eq $TenantKey } | ForEach-Object { $_.tenantId }) | Select-Object -First 1)"
    if ($tid -and $bid -ne $tid) { throw 'Die Tenant-ID im Backup-Stand passt nicht zum Ziel-Tenant. Zurueckschreiben nur in denselben Tenant - nichts geschrieben.' }
}

# ---------- Conditional Access: NEU anlegen, nur als "Nur Bericht" (bestehende Richtlinie bleibt unberuehrt) ----------
$script:HUErCaSkip = @('id', 'createdDateTime', 'modifiedDateTime', 'templateId', 'deletedDateTime', 'partialEnablementStrategy')
$script:HUErGuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Referenzierte Objekte im Ziel pruefen -> Liste fehlender/nicht pruefbarer (leer = alles da)
function Test-HUErCaRefs([string]$TenantKey, $Settings, $Policy) {
    $miss = New-Object System.Collections.Generic.List[string]
    $c = Get-HUErProp $Policy 'conditions'
    $u = Get-HUErProp $c 'users'; $a = Get-HUErProp $c 'applications'; $l = Get-HUErProp $c 'locations'; $g = Get-HUErProp $Policy 'grantControls'
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($f in 'includeUsers', 'excludeUsers') { foreach ($x in @(Get-HUErProp $u $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Benutzer'; E = "/users/$x`?`$select=id"; X = "$x" }) } } }
    foreach ($f in 'includeGroups', 'excludeGroups') { foreach ($x in @(Get-HUErProp $u $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Gruppe'; E = "/groups/$x`?`$select=id"; X = "$x" }) } } }
    foreach ($f in 'includeRoles', 'excludeRoles') { foreach ($x in @(Get-HUErProp $u $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Rolle'; E = "/roleManagement/directory/roleDefinitions/$x`?`$select=id"; X = "$x" }) } } }
    foreach ($f in 'includeLocations', 'excludeLocations') { foreach ($x in @(Get-HUErProp $l $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Benannter Ort'; E = "/identity/conditionalAccess/namedLocations/$x"; X = "$x" }) } } }
    foreach ($f in 'includeApplications', 'excludeApplications') { foreach ($x in @(Get-HUErProp $a $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'App'; E = "/servicePrincipals(appId='$x')?`$select=id"; X = "$x" }) } } }
    foreach ($x in @(Get-HUErProp $a 'includeAuthenticationContextClassReferences' | Where-Object { "$_" })) {
        if ("$x" -match '^c([1-9]|1[0-9]|2[0-5])$') { $checks.Add(@{ L = 'Authentifizierungskontext'; E = "/identity/conditionalAccess/authenticationContextClassReferences/$x"; X = "$x" }) }
        else { $miss.Add("Authentifizierungskontext '$x' hat kein gueltiges Format (c1 bis c25)") }
    }
    $ca = Get-HUErProp $c 'clientApplications'
    foreach ($f in 'includeServicePrincipals', 'excludeServicePrincipals') { foreach ($x in @(Get-HUErProp $ca $f)) { if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Dienstprinzipal'; E = "/servicePrincipals/$x`?`$select=id"; X = "$x" }) } } }
    foreach ($x in @(Get-HUErProp $g 'customAuthenticationFactors')) { if ("$x") { $miss.Add("Eigenes Steuerelement $x wird nicht unterstuetzt") } }
    foreach ($x in @(Get-HUErProp $g 'termsOfUse' | Where-Object { "$_" })) {
        if ("$x" -match $script:HUErGuidRx) { $checks.Add(@{ L = 'Nutzungsbedingungen'; E = "/identityGovernance/termsOfUse/agreements/$x`?`$select=id"; X = "$x" }) }
        else { $miss.Add("Nutzungsbedingungen '$x' haben kein gueltiges Format") }
    }
    $as = Get-HUErProp (Get-HUErProp $g 'authenticationStrength') 'id'
    if ("$as") { $checks.Add(@{ L = 'Authentifizierungsstaerke'; E = "/policies/authenticationStrengthPolicies/$as`?`$select=id"; X = "$as" }) }
    foreach ($ck in $checks) {
        try { if (-not (Test-HUErExists $TenantKey $Settings $ck.E)) { $miss.Add("$($ck.L) $($ck.X) gibt es im Tenant nicht (mehr)") } }
        catch { $miss.Add("$($ck.L) $($ck.X) nicht pruefbar ($($_.Exception.Message))") }
    }
    return , $miss
}

function Get-HUErPlanCaNew($Plan, [string]$TenantKey, $Settings, $Backup, [string]$NewName) {
    $Plan.Method = 'POST'; $Plan.Endpoint = '/identity/conditionalAccess/policies'; $Plan.ReadEndpoint = ''; $Plan.Perm = 'Policy.ReadWrite.ConditionalAccess (und Policy.Read.All)'
    $Plan.BreakGlass = $false
    if (-not (Get-HUErProp $Backup 'conditions')) { $Plan.Blocks.Add('Der Backup-Eintrag hat keine Bedingungen (conditions).'); return }
    if (-not $NewName) { $NewName = "$(Get-HUErProp $Backup 'displayName') (wiederhergestellt)" }
    # gleicher Name schon vorhanden (z. B. zweimal am selben Tag wiederhergestellt): Nummer anhaengen, damit die Kopien unterscheidbar bleiben
    try {
        $taken = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/identity/conditionalAccess/policies?$select=displayName' -V1 | ForEach-Object { "$($_.displayName)".Trim().ToLowerInvariant() })
        if ($taken -contains $NewName.Trim().ToLowerInvariant()) {
            $n = 2; $base = $NewName -replace '\)$', ''
            while ($taken -contains "$base $n)".ToLowerInvariant()) { $n++ }
            $NewName = "$base $n)"
            $Plan.Notes.Add("Den Namen gibt es schon - die neue Richtlinie heisst '$NewName'.")
        }
    } catch { }
    # Authentifizierungsstaerke: nur die Kennung senden (die gelesene Form enthaelt schreibgeschuetzte Felder)
    $asId = "$(Get-HUErProp (Get-HUErProp (Get-HUErProp $Backup 'grantControls') 'authenticationStrength') 'id')"
    $body = @{ displayName = $NewName; state = 'enabledForReportingButNotEnforced' }
    foreach ($f in 'conditions', 'grantControls', 'sessionControls') {
        $v = Get-HUErProp $Backup $f
        if ($null -eq $v) { continue }
        $h = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $v $script:HUErCaSkip)
        if ($f -eq 'grantControls') { if ($h.ContainsKey('authenticationStrength')) { $h.Remove('authenticationStrength') }; if ($asId) { $h['authenticationStrength'] = @{ id = $asId } } }
        if ($h.Count) { $body[$f] = $h }
    }
    # "Nur Bericht" gibt es nicht fuer Benutzeraktionen (Learn: report-only "except for items included in the User Actions scope")
    # nur Eintraege mit Wert zaehlen: @($null) hat die Anzahl 1 (046 B1)
    if (@(Get-HUErProp (Get-HUErProp (Get-HUErProp $Backup 'conditions') 'applications') 'includeUserActions' | Where-Object { "$_" }).Count) {
        $body.state = 'disabled'
        $Plan.Warnings.Add('Richtlinie fuer Benutzeraktionen: "Nur Bericht" ist dafuer nicht moeglich - sie wird AUSGESCHALTET angelegt.')
    }
    # Learn-Warnung: Nur-Bericht mit konformem Geraet kann auf macOS/iOS/Android Zertifikat-Abfragen ausloesen
    $bic = @(Get-HUErProp (Get-HUErProp $Backup 'grantControls') 'builtInControls')
    $certOpen = @()
    if ($body.state -eq 'enabledForReportingButNotEnforced' -and $bic -contains 'compliantDevice') {
        $pl = Get-HUErProp (Get-HUErProp $Backup 'conditions') 'platforms'
        $ex = @(Get-HUErProp $pl 'excludePlatforms'); $in = @(Get-HUErProp $pl 'includePlatforms' | Where-Object { "$_" })
        # ohne Plattform-Bedingung oder mit "all" gilt die Richtlinie fuer alle Plattformen
        $open = @('android', 'iOS', 'macOS' | Where-Object { $ex -notcontains $_ -and (-not $in.Count -or $in -contains 'all' -or $in -contains $_) })
        $certOpen = $open
        if ($open.Count) { $Plan.Confirms.Add("Verlangt ein konformes Geraet: Microsoft warnt, dass Benutzer auf $($open -join ', ') auch im Modus 'Nur Bericht' wiederholt nach einem Geraetezertifikat gefragt werden koennen (Plattformen dort ausnehmen).") }
    }
    foreach ($m in (Test-HUErCaRefs $TenantKey $Settings $Backup)) { $Plan.Blocks.Add("$m.") }
    # Notfallkonten: im Nur-Bericht-Modus keine Aussperrung, aber vor dem Einschalten noetig
    try {
        $bl = Get-HUSecBaseline -TenantKey $TenantKey
        $bg = @(); if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { $bg = @($bl.Values['V1'].accounts | Where-Object { "$_" }) }
        $exU = @(Get-HUErProp (Get-HUErProp (Get-HUErProp $Backup 'conditions') 'users') 'excludeUsers' | ForEach-Object { "$_".ToLowerInvariant() })
        $notEx = @($bg | Where-Object { $exU -notcontains "$_".ToLowerInvariant() })
        if (-not $bg.Count) { $Plan.Notes.Add('Keine Notfallkonten hinterlegt (Sollwert V1) - vor dem Einschalten pruefen, dass sie ausgenommen sind.') }
        elseif (-not $notEx.Count) { $Plan.Notes.Add("Notfallkonten: alle $($bg.Count) direkt ausgenommen.") }
        elseif ($notEx.Count) {
            $txt = "$($notEx.Count) Notfallkonto/-konten sind nicht direkt ausgenommen$(if (@(Get-HUErProp (Get-HUErProp (Get-HUErProp $Backup 'conditions') 'users') 'excludeGroups' | Where-Object { "$_" }).Count) { ' (ausgenommene Gruppen hier nicht aufgeloest)' })"
            # konformes Geraet: die Zertifikat-Abfrage wirkt schon im Nur-Bericht-Modus (046 B3) -> Pflicht-Haken
            if ($certOpen.Count) { $Plan.Confirms.Add("$txt - die Zertifikat-Abfrage trifft sie schon jetzt (Nur Bericht).") }
            else { $Plan.Warnings.Add("$txt - vor dem Einschalten ergaenzen.") }
        }
    } catch { }
    $Plan.Body = $body
    Add-HUErChange $Plan 'displayName' '(neu)' $NewName
    Add-HUErChange $Plan 'state' '(neu)' $body.state
    $map = ConvertTo-HUFlatMap ([pscustomobject]@{ conditions = $body['conditions']; grantControls = $body['grantControls']; sessionControls = $body['sessionControls'] }) -Full
    try { $map = Resolve-HUFlatMapIds -TenantKey $TenantKey -Settings $Settings -Map $map } catch { }
    foreach ($k in @($map.Keys | Sort-Object)) { Add-HUErChange $Plan $k '(neu)' "$($map[$k])" }
    $Plan.Notes.Add('Es wird eine NEUE Richtlinie angelegt; die bestehende bleibt unveraendert. Nach der Pruefung im Anmeldeprotokoll (Nur Bericht) selbst einschalten und die alte entfernen.')
    Add-HUErDropped $Plan $Backup @('conditions', 'grantControls', 'sessionControls', 'state')
}

# Plan bauen: liest live, vergleicht, prueft. Schreibt nichts.
function Get-HUEntraRestorePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [string]$Id = '', [string]$Name = '', [Parameter(Mandatory)]$Backup, $BackupIndex = $null, [string]$NewName = '')
    $kind = Get-HUEntraRestoreKind $Typ $Id
    if (-not $kind) { throw "$Typ '$Name' laesst sich nicht zurueckschreiben" }
    Assert-HUErSameTenant -TenantKey $TenantKey -Settings $Settings -BackupIndex $BackupIndex
    $plan = New-HUErPlan $kind $TenantKey $Typ $Name
    switch ($kind) {
        'authz' { Get-HUErPlanAuthz $plan $TenantKey $Settings $Backup }
        'consent' { Get-HUErPlanConsent $plan $TenantKey $Settings $Backup }
        'location' { Get-HUErPlanLocation $plan $TenantKey $Settings $Backup }
        'groupSetting' { Get-HUErPlanGroupSetting $plan $TenantKey $Settings $Backup }
        'caNew' { Get-HUErPlanCaNew $plan $TenantKey $Settings $Backup $NewName }
    }
    if ($plan.BreakGlass -eq $true -and $plan.Changes.Count) {
        $bg = Test-HUEntraBreakGlass -TenantKey $TenantKey -Settings $Settings
        $plan.BreakGlass = $bg
        if (-not $bg.Ok) { $plan.Blocks.Add($bg.Text) }
    }
    return $plan
}

# Neu anlegen (Conditional Access): nichts wird ueberschrieben, daher keine Sicherung; danach nachlesen
# Wartezeiten (Sekunden) fuers Nachlesen nach dem Anlegen: eine neue CA-Richtlinie ist oft erst nach einigen Sekunden lesbar (404)
$script:HUErReadDelays = @(2, 3, 5, 5, 5, 10)
function Invoke-HUErCreate($Plan, $Settings, [string]$Actor) {
    $tk = $Plan.TenantKey
    $r = $null
    try { $r = Invoke-HUErGraph $tk $Settings $Plan.Endpoint 'POST' $Plan.Body }
    catch {
        if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm) (unter Berechtigungen fuer diesen Tenant erteilen). Nichts angelegt." }
        throw
    }
    $id = "$($r.id)"
    if (-not $id) { throw 'Angelegt, aber ohne Kennung zurueckgemeldet - bitte im Portal pruefen.' }
    Write-HULog -Message "Neu angelegt $($Plan.Typ) '$($Plan.Body.displayName)' als $($Plan.Body.state) (Id $id, aus '$($Plan.Name)', durch $Actor)" -Level 'OK' -Tenant $tk
    $after = $null; $readErr = ''
    foreach ($wait in @(@(0) + @($script:HUErReadDelays))) {
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        try { $after = Invoke-HUErGraph $tk $Settings "$($Plan.Endpoint)/$id"; $readErr = ''; break }
        catch {
            $readErr = "$($_.Exception.Message)"
            # nur "noch nicht da" (404) abwarten, andere Fehler sofort melden
            if ($_.Exception.Data['StatusCode'] -ne 404) { break }
        }
    }
    if ($null -eq $after) {
        # angelegt ist sie (POST hat die Kennung geliefert) - nur das Nachlesen ging nicht: kein Fehler "nicht zurueckgeschrieben"
        $msg = "Angelegt (Id $id), aber nicht nachlesbar ($readErr) - bitte im Portal pruefen und NICHT erneut anlegen (sonst entsteht eine zweite Richtlinie)."
        Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Body.displayName)': $msg" -Level 'WARN' -Tenant $tk
        return [pscustomobject]@{ Ok = $false; Written = 1; Mismatch = @($msg); BackupFile = ''; NewId = $id; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
    }
    $bad = New-Object System.Collections.Generic.List[string]
    if ("$($after.state)" -ne "$($Plan.Body.state)") { $bad.Add("state: erwartet $($Plan.Body.state), gelesen $($after.state)") }
    if ("$($after.displayName)" -ne "$($Plan.Body.displayName)") { $bad.Add("displayName: erwartet $($Plan.Body.displayName), gelesen $($after.displayName)") }
    # Inhalt grob nachpruefen (046 B2): Verknuepfung, Steuerelemente, Anzahl der Benutzer/Apps/Orte
    $bg = $Plan.Body['grantControls']; $ag = Get-HUErProp $after 'grantControls'
    $cmp = New-Object System.Collections.Generic.List[object]
    $cmp.Add(@('grantControls.operator', "$(Get-HUErProp $bg 'operator')", "$(Get-HUErProp $ag 'operator')"))
    $cmp.Add(@('grantControls.builtInControls', ((@(Get-HUErProp $bg 'builtInControls' | Where-Object { "$_" }) | Sort-Object) -join ','), ((@(Get-HUErProp $ag 'builtInControls' | Where-Object { "$_" }) | Sort-Object) -join ',')))
    $bc = $Plan.Body['conditions']; $ac = Get-HUErProp $after 'conditions'
    foreach ($pp in @(@('users', 'includeUsers'), @('users', 'excludeUsers'), @('users', 'includeGroups'), @('applications', 'includeApplications'), @('locations', 'includeLocations'), @('locations', 'excludeLocations'))) {
        $nb = @(Get-HUErProp (Get-HUErProp $bc $pp[0]) $pp[1] | Where-Object { "$_" }).Count
        $na = @(Get-HUErProp (Get-HUErProp $ac $pp[0]) $pp[1] | Where-Object { "$_" }).Count
        $cmp.Add(@("conditions.$($pp[0]).$($pp[1]) (Anzahl)", "$nb", "$na"))
    }
    foreach ($x in $cmp) { if ($x[1] -ne $x[2]) { $bad.Add("$($x[0]): erwartet '$($x[1])', gelesen '$($x[2])'") } }
    foreach ($b in $bad) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Body.displayName)': $b" -Level 'WARN' -Tenant $tk }
    return [pscustomobject]@{ Ok = (-not $bad.Count); Written = 1; Mismatch = @($bad); BackupFile = ''; NewId = $id; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

# Zurueckschreiben nach Bestaetigung: erneut lesen, sichern, schreiben, nachpruefen.
function Invoke-HUEntraRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings, [string]$Actor = "$env:USERNAME")
    if ($Plan.Blocks.Count) { throw "Nicht zurueckgeschrieben: $($Plan.Blocks -join ' ')" }
    if (-not $Plan.Changes.Count) { throw 'Nichts zu schreiben - der Live-Stand entspricht schon dem Backup.' }
    $tk = $Plan.TenantKey
    if ($Plan.Method -eq 'POST') { return (Invoke-HUErCreate $Plan $Settings $Actor) }
    # zweites Lesen: hat sich seit der Vorschau etwas geaendert?
    $now = Invoke-HUErGraph $tk $Settings $Plan.ReadEndpoint
    if ((Get-HUErHash $now) -ne $Plan.LiveHash) { throw 'Der Live-Stand hat sich seit der Vorschau geaendert (z. B. im Portal). Nichts geschrieben - bitte Vorschau neu oeffnen.' }
    # Sicherung des Live-Stands unmittelbar davor
    $dir = Join-Path (Join-Path (Get-HUBackupRoot $Settings) (ConvertTo-HUSafeFileName $tk)) '_vor-zurueckschreiben'
    $file = Join-Path $dir ("$((Get-Date).ToString('yyyy-MM-dd_HHmmss'))_$($Plan.Kind)_$(ConvertTo-HUSafeFileName $Plan.Name 40).json")
    Write-HUBackupJson $file $now
    try { [void](Invoke-HUErGraph $tk $Settings $Plan.Endpoint $Plan.Method $Plan.Body) }
    catch {
        if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm) (unter Berechtigungen fuer diesen Tenant erteilen). Nichts geschrieben." }
        throw
    }
    foreach ($c in $Plan.Changes) {
        $what = if ($script:HUErNoLog -contains $c.Feld) { 'geaendert (Inhalt nicht protokolliert)' } else { "$($c.Jetzt) -> $($c.Danach)" }
        Write-HULog -Message "Zurueckgeschrieben $($Plan.Typ) '$($Plan.Name)': $($c.Feld): $what (durch $Actor)" -Level 'OK' -Tenant $tk
    }
    # Nachpruefung
    $after = Invoke-HUErGraph $tk $Settings $Plan.ReadEndpoint
    $bad = @($Plan.Changes | Where-Object { -not (Test-HUErEqual (Get-HUErPathValue $after $_.Feld) $_.Expected) } | ForEach-Object {
            if ($script:HUErNoLog -contains $_.Feld) { "$($_.Feld): weicht nach dem Schreiben ab (Inhalt nicht protokolliert)" }
            else { "$($_.Feld): erwartet $($_.Danach), gelesen $(Format-HUErValue (Get-HUErPathValue $after $_.Feld))" }
        })
    foreach ($b in $bad) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Name)': $b" -Level 'WARN' -Tenant $tk }
    return [pscustomobject]@{ Ok = (-not $bad.Count); Written = $Plan.Changes.Count; Mismatch = $bad; BackupFile = $file; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

Export-ModuleMember -Function Get-HUEntraRestoreKind, Get-HUEntraRestorePlan, Invoke-HUEntraRestore, Test-HUEntraBreakGlass, Format-HUErValue, Test-HUErEqual, Get-HUErPathValue
