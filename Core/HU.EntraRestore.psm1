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
$script:HUErIgnore = @('id', 'displayName', 'description', 'createdDateTime', 'modifiedDateTime', 'lastModifiedDateTime', 'version', 'deletedDateTime', 'templateId')
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

# Plan bauen: liest live, vergleicht, prueft. Schreibt nichts.
function Get-HUEntraRestorePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [string]$Id = '', [string]$Name = '', [Parameter(Mandatory)]$Backup, $BackupIndex = $null)
    $kind = Get-HUEntraRestoreKind $Typ $Id
    if (-not $kind) { throw "$Typ '$Name' laesst sich nicht zurueckschreiben" }
    Assert-HUErSameTenant -TenantKey $TenantKey -Settings $Settings -BackupIndex $BackupIndex
    $plan = New-HUErPlan $kind $TenantKey $Typ $Name
    switch ($kind) {
        'authz' { Get-HUErPlanAuthz $plan $TenantKey $Settings $Backup }
        'consent' { Get-HUErPlanConsent $plan $TenantKey $Settings $Backup }
        'location' { Get-HUErPlanLocation $plan $TenantKey $Settings $Backup }
        'groupSetting' { Get-HUErPlanGroupSetting $plan $TenantKey $Settings $Backup }
    }
    if ($plan.BreakGlass -eq $true -and $plan.Changes.Count) {
        $bg = Test-HUEntraBreakGlass -TenantKey $TenantKey -Settings $Settings
        $plan.BreakGlass = $bg
        if (-not $bg.Ok) { $plan.Blocks.Add($bg.Text) }
    }
    return $plan
}

# Zurueckschreiben nach Bestaetigung: erneut lesen, sichern, schreiben, nachpruefen.
function Invoke-HUEntraRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings, [string]$Actor = "$env:USERNAME")
    if ($Plan.Blocks.Count) { throw "Nicht zurueckgeschrieben: $($Plan.Blocks -join ' ')" }
    if (-not $Plan.Changes.Count) { throw 'Nichts zu schreiben - der Live-Stand entspricht schon dem Backup.' }
    $tk = $Plan.TenantKey
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
