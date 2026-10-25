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
# 2.5.1 (059 B1) Rollen, die keine Admin-Rollen sind bzw. jeder automatisch hat (User, Gast, Geraete, abgekuendigte Partner-Rollen):
# nie als Ausnahme in "100 - Admin-Portale" - sonst wuerde die Richtlinie fuer normale Benutzer nicht greifen oder Graph lehnt ab.
# Vorlagen-IDs: in der aktuellen Liste der eingebauten Rollen (Learn) nicht als zuweisbare Admin-Rolle gefuehrt.
$script:HUErNoAdminRoles = @(
    'a0b1b346-4d3e-4e8b-98f8-753987be4970',  # User
    '10dae51f-b6af-4016-8d66-8c2a99b929b3',  # Guest User
    '2af84b1e-32c8-42b7-82bc-daa82404023b',  # Restricted Guest User
    'd405c6df-0af8-4e3b-95e4-4d06e542189e',  # Device Users
    '9c094953-4995-41c8-84c8-3ebb9b32c93f',  # Device Join
    'c34f683f-4d5a-4403-affd-6615e00e3a7f',  # Workplace Device Join
    '2b499bcd-da44-4968-8aec-78e1674fa64d',  # nicht in der Learn-Liste
    '4ba39ca4-527c-499a-b93d-d9b492c50246',  # Partner Tier1 Support (Learn: Do not use)
    'e00e864a-17c5-4a4b-9c06-f5b95a8d5bd8',  # Partner Tier2 Support (Learn: Do not use)
    'a92aed5d-d78a-4d16-b381-09adb37eb3b0',  # nicht in der Learn-Liste
    'd35481f7-cda1-4fa2-8344-5a21f7f3724d'   # nicht in der Learn-Liste
)
$script:HUErIgnore = @('id', 'displayName', 'description', 'createdDateTime', 'modifiedDateTime', 'lastModifiedDateTime', 'version', 'deletedDateTime', 'templateId', 'assignments')
$script:HUErPwRuleTpl = '5cf42378-d67d-4f36-ba46-e8b86229381d'
# Kennwortregeln per App gesperrt (Live-Test 24.10., 403 trotz Recht); Tests schalten es fuer die Logik dahinter ab
$script:HUErPwRuleBlocked = $true
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
    # 053 B6: Zeitstempel zaehlen nicht - Entra setzt sie selbst (auch zeitversetzt); nur eine echte Inhaltsaenderung soll sperren
    $j = (ConvertTo-HUCleanObject $Obj @('@odata.context', 'modifiedDateTime', 'createdDateTime', 'lastModifiedDateTime')) | ConvertTo-Json -Depth 40 -Compress
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
    # Liste mit einem Eintrag kommt als einzelner Text an (PS entpackt): ist die andere Seite eine Liste, zaehlt ein nicht leerer Text als 1
    if ($nd -and -not $nj -and $null -ne $Now -and "$Now" -and "$Now" -ne '(neu)') { $nj = 1 }
    if ($nj -and -not $nd -and $null -ne $Then -and "$Then") { $nd = 1 }
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
        # 2.5.1 Auswahl-Angaben mitgelieferter Muster (huGruppen, huRollen, huLaenderwahl) sind kein Graph-Feld - nicht als "nicht geschrieben" nennen
        if ($p.Name -match '^@' -or $p.Name -in 'huGruppen', 'huRollen', 'huLaenderwahl' -or $Allowed -contains $p.Name -or $script:HUErIgnore -contains $p.Name) { continue }
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
        # ohne $( ): eine Liste mit einem Land (z. B. nur AT) wuerde darin zum Text "AT" (Graph 400 "does not match the schema")
        if ($f -eq 'countriesAndRegions') { $body[$f] = [object[]]@($b) } else { $body[$f] = $b }
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
    # Live-Test 24.10.: PATCH auf "Password Rule Settings" mit Anwendungsrecht GroupSettings.ReadWrite.All -> 403 Authorization_RequestDenied,
    # obwohl Learn das Recht nennt (Konfidenz U). Bis das geklaert ist: nicht schreiben, im Portal setzen.
    if ($tpl -eq $script:HUErPwRuleTpl -and $script:HUErPwRuleBlocked) { $Plan.Blocks.Add('Kennwortregeln (Password Rule Settings) lassen sich per App nicht schreiben - Microsoft lehnt trotz GroupSettings.ReadWrite.All ab. Bitte im Entra Admin Center setzen: Schutz > Authentifizierungsmethoden > Kennwortschutz.'); return }
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
    # 054 B1 (Gemini): bekannte Listenfelder immer als Liste senden - Absicherung gegen PS-5.1-Auspacken (eine Liste mit einem Eintrag -> Text -> Graph 400)
    $asList = { param($d, [string[]]$names) if ($d -is [System.Collections.IDictionary]) { foreach ($n in $names) { if ($d.Contains($n) -and $null -ne $d[$n]) { $d[$n] = [object[]]@($d[$n]) } } } }
    if ($body.ContainsKey('grantControls')) { & $asList $body['grantControls'] @('builtInControls', 'customAuthenticationFactors', 'termsOfUse') }
    if ($body.ContainsKey('conditions')) {
        $c0 = $body['conditions']
        & $asList $c0 @('clientAppTypes', 'signInRiskLevels', 'userRiskLevels', 'servicePrincipalRiskLevels', 'insiderRiskLevels')
        & $asList $c0['users'] @('includeUsers', 'excludeUsers', 'includeGroups', 'excludeGroups', 'includeRoles', 'excludeRoles')
        & $asList $c0['applications'] @('includeApplications', 'excludeApplications', 'includeUserActions', 'includeAuthenticationContextClassReferences')
        & $asList $c0['locations'] @('includeLocations', 'excludeLocations')
        & $asList $c0['platforms'] @('includePlatforms', 'excludePlatforms')
        & $asList $c0['clientApplications'] @('includeServicePrincipals', 'excludeServicePrincipals')
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
        if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm) (unter Berechtigungen fuer diesen Tenant erteilen). Nichts angelegt. Microsoft meldet: $($_.Exception.Message)" }
        # abgelehnt (z. B. 400): gesendeten Inhalt zur Fehlersuche ablegen (keine Geheimnisse - CA-Richtlinie)
        $err = $_
        try {
            $df = Join-Path (Join-Path (Join-Path (Get-HUBackupRoot $Settings) (ConvertTo-HUSafeFileName $tk)) '_fehler') ("$((Get-Date).ToString('yyyy-MM-dd_HHmmss'))_abgelehnt_$(ConvertTo-HUSafeFileName $Plan.Name 40).json")
            $dd = Split-Path $df -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
            [IO.File]::WriteAllText($df, ($Plan.Body | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding($false)))
            Write-HULog -Message "Abgelehnter Inhalt gespeichert: $df" -Level 'WARN' -Tenant $tk
        } catch { }
        throw $err
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
        return [pscustomobject]@{ Ok = $false; Written = 1; Mismatch = @($msg); BackupFile = ''; NewId = $id; After = $null; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
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
    # After: der eben gelesene Stand (fuer die Rueckgaengig-Datei - kein zweites Lesen, das Entra kurz nach dem Anlegen oft noch mit 404 beantwortet)
    return [pscustomobject]@{ Ok = (-not $bad.Count); Written = 1; Mismatch = @($bad); BackupFile = ''; NewId = $id; After = $after; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
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
        if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm) (unter Berechtigungen fuer diesen Tenant erteilen). Nichts geschrieben. Microsoft meldet: $($_.Exception.Message)" }
        # abgelehnt (z. B. 400): gesendeten Inhalt zur Fehlersuche ablegen (Kennwortliste nicht)
        $err = $_
        try {
            if (-not @($Plan.Changes | Where-Object { $script:HUErNoLog -contains $_.Feld }).Count) {
                $df = Join-Path (Join-Path (Join-Path (Get-HUBackupRoot $Settings) (ConvertTo-HUSafeFileName $tk)) '_fehler') ("$((Get-Date).ToString('yyyy-MM-dd_HHmmss'))_abgelehnt_$(ConvertTo-HUSafeFileName $Plan.Name 40).json")
                $dd = Split-Path $df -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                [IO.File]::WriteAllText($df, ($Plan.Body | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding($false)))
                Write-HULog -Message "Abgelehnter Inhalt gespeichert: $df" -Level 'WARN' -Tenant $tk
            }
        } catch { }
        throw $err
    }
    foreach ($c in $Plan.Changes) {
        $what = if ($script:HUErNoLog -contains $c.Feld) { 'geaendert (Inhalt nicht protokolliert)' } else { "$($c.Jetzt) -> $($c.Danach)" }
        Write-HULog -Message "Zurueckgeschrieben $($Plan.Typ) '$($Plan.Name)': $($c.Feld): $what (durch $Actor)" -Level 'OK' -Tenant $tk
    }
    # Nachpruefung - Entra liefert kurz nach dem Schreiben manchmal noch den alten Stand (Replikation): bei Abweichung nachlesen
    $after = $null; $bad = @()
    foreach ($wait in @(0, 2, 3, 5)) {
        if ($wait) { Start-Sleep -Seconds $wait }
        $after = Invoke-HUErGraph $tk $Settings $Plan.ReadEndpoint
        $bad = @($Plan.Changes | Where-Object { -not (Test-HUErEqual @(Get-HUErPathValue $after $_.Feld) @($_.Expected)) } | ForEach-Object {
                if ($script:HUErNoLog -contains $_.Feld) { "$($_.Feld): weicht nach dem Schreiben ab (Inhalt nicht protokolliert)" }
                else { "$($_.Feld): erwartet $($_.Danach), gelesen $(Format-HUErValue (Get-HUErPathValue $after $_.Feld))" }
            })
        if (-not $bad.Count) { break }
    }
    foreach ($b in $bad) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Name)': $b" -Level 'WARN' -Tenant $tk }
    # After: genau der Stand der Nachpruefung (fuer den Fingerabdruck der Rueckgaengig-Datei - kein zweites, evtl. veraltetes Lesen)
    return [pscustomobject]@{ Ok = (-not $bad.Count); Written = $Plan.Changes.Count; Mismatch = $bad; BackupFile = $file; After = $after; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

# ============================================================================
# 2.4.4 Uebertragen C (Konzept 045 Abschnitt 6, F6): Entra-Einstellungen aus dem MUSTER in andere Tenants.
# Quelle = Backup-Stand des Mustertenants (ResolveKey = dessen Live-Tenant fuer Namen). Ziel wird live gelesen,
# geprueft wird immer im ZIEL. Gruppen ueber den Namen (genau ein Treffer), Benutzer nie, eingebaute Rollen global.
# ============================================================================
$script:HUErTrKinds = @('authz', 'consent', 'location', 'groupSetting', 'caNew')

function ConvertTo-HUErName([string]$N) { return ("$N".Trim()).ToLowerInvariant() }

# Objekt flach kopieren (pscustomobject), damit Aenderungen die Quelle nicht beruehren
function Copy-HUErObject($O) { return ((ConvertTo-HUCleanObject $O @()) | ConvertTo-Json -Depth 40 | ConvertFrom-Json) }

# Gruppe der Quelle ueber den Namen im Ziel finden -> @{ Id; Name; Error }
function Resolve-HUErGroupToTarget([string]$ResolveKey, $Settings, [string]$TargetKey, [string]$GroupId) {
    $g = $null
    try { $g = Invoke-HUErGraph $ResolveKey $Settings "/groups/$GroupId`?`$select=id,displayName" } catch { return @{ Error = "Gruppe $GroupId ist in der Quelle nicht (mehr) lesbar" } }
    $n = "$($g.displayName)"
    if (-not $n) { return @{ Error = "Gruppe $GroupId hat in der Quelle keinen Namen" } }
    $f = [uri]::EscapeDataString("displayName eq '$($n.Replace("'", "''"))'")
    $hits = @()
    try { $hits = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint "/groups?`$filter=$f&`$select=id,displayName" -V1 | Where-Object { (ConvertTo-HUErName $_.displayName) -eq (ConvertTo-HUErName $n) }) }
    catch { return @{ Error = "Gruppe '$n' im Ziel nicht suchbar ($($_.Exception.Message))" } }
    if ($hits.Count -ne 1) { return @{ Error = "Gruppe '$n' gibt es im Ziel $(if ($hits.Count) { "$($hits.Count)-mal" } else { 'nicht' })"; Name = $n } }
    return @{ Id = "$($hits[0].id)"; Name = $n }
}

# eingeschaltete CA-Richtlinien im Ziel, die "Alle vertrauenswuerdigen Orte" bzw. einen bestimmten Ort verwenden -> Namen ($null = nicht lesbar)
function Get-HUErCaUsingLocation([string]$TargetKey, $Settings, [string]$LocationId) {
    $pol = $null
    try { $pol = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/identity/conditionalAccess/policies' -V1) } catch { return $null }
    # Komma: eine leere Liste darf nicht zu $null werden ($null bedeutet hier "nicht lesbar")
    return , [string[]]@($pol | Where-Object {
            $l = Get-HUErProp (Get-HUErProp $_ 'conditions') 'locations'
            @(@(Get-HUErProp $l 'includeLocations') + @(Get-HUErProp $l 'excludeLocations') | ForEach-Object { "$_" }) -contains $LocationId
        } | ForEach-Object { "$($_.displayName) ($($_.state))" })
}

function Get-HUErTrPlanConsent($Plan, [string]$TargetKey, $Settings, $Backup, [string]$ResolveKey) {
    $b = Copy-HUErObject $Backup
    $g = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $revs = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-HUErProp $b 'reviewers' | Where-Object { $_ })) {
        $q = "$(Get-HUErProp $r 'query')"
        if ($q -match "^(/v1\.0|/beta)?/users/$g") { $Plan.Blocks.Add("Reviewer ist ein einzelner Benutzer ($q) - Benutzer werden zwischen Tenants nie zugeordnet (Ue-3). Im Muster eine Gruppe oder Rolle verwenden."); continue }
        $m = [regex]::Match($q, "^((/v1\.0|/beta)?/groups/)$g(.*)$")
        if ($m.Success) {
            $t = Resolve-HUErGroupToTarget $ResolveKey $Settings $TargetKey $m.Groups[3].Value
            if ($t.Error) { $Plan.Blocks.Add("Reviewer: $($t.Error)."); continue }
            $q = "$($m.Groups[1].Value)$($t.Id)$($m.Groups[4].Value)"
            $Plan.Notes.Add("Reviewer-Gruppe '$($t.Name)' zugeordnet ($($m.Groups[3].Value) -> $($t.Id)).")
        }
        $revs.Add([pscustomobject]@{ query = $q; queryType = "$(Get-HUErProp $r 'queryType')"; queryRoot = (Get-HUErProp $r 'queryRoot') })
    }
    $b | Add-Member -NotePropertyName reviewers -NotePropertyValue $revs.ToArray() -Force
    if ((ConvertTo-HUErBool (Get-HUErProp $b 'isEnabled')) -and -not $revs.Count -and -not $Plan.Blocks.Count) { $Plan.Blocks.Add('Eingeschaltet ohne Reviewer ist nicht moeglich.') }
    Get-HUErPlanConsent $Plan $TargetKey $Settings $b
    # Reviewer, die es nur im Ziel gibt, fallen weg (PUT ersetzt die Liste): nicht still, sondern mit Namen und Pflicht-Haken
    if (-not $Plan.Blocks.Count -and $null -ne $Plan.Live) {
        $newQ = @($revs | ForEach-Object { "$($_.query)".ToLowerInvariant() })
        $gone = @(@(Get-HUErProp $Plan.Live 'reviewers' | Where-Object { $_ }) | Where-Object { $newQ -notcontains "$(Get-HUErProp $_ 'query')".ToLowerInvariant() })
        if ($gone.Count) {
            $names = @($gone | ForEach-Object {
                    $q = "$(Get-HUErProp $_ 'query')"
                    $mu = [regex]::Match($q, "/users/$g"); $mg = [regex]::Match($q, "/groups/$g")
                    if ($mu.Success) { try { "Benutzer $((Invoke-HUErGraph $TargetKey $Settings "/users/$($mu.Groups[1].Value)?`$select=userPrincipalName").userPrincipalName)" } catch { "Benutzer $($mu.Groups[1].Value)" } }
                    elseif ($mg.Success) { try { "Gruppe $((Invoke-HUErGraph $TargetKey $Settings "/groups/$($mg.Groups[1].Value)?`$select=displayName").displayName)" } catch { "Gruppe $($mg.Groups[1].Value)" } }
                    # 054 B3 (Gemini): Rollen-Reviewer mit Namen statt rohem Abfragepfad
                    elseif ($q -match "roleDefinition(s/|Id eq ')$g") { $rid = $Matches[2]; try { "Rolle $((Invoke-HUErGraph $TargetKey $Settings "/roleManagement/directory/roleDefinitions/$rid`?`$select=displayName").displayName)" } catch { "Rolle $rid" } }
                    else { $q }
                })
            $Plan.Confirms.Add("Im Ziel eingetragene Reviewer fallen weg (nur im Ziel, nicht im Muster): $($names -join ', ').")
        }
    }
}

# 2.5.1 Uebertragen der Autorisierungsrichtlinie: Zustimmungsrechte des Ziels fuer EIGENE Apps (ManagePermissionGrantsForOwnedResource.*)
# behalten - das Muster legt nur die Benutzer-Zustimmung fest (z. B. mitgelieferter Entra-Grundschutz), nicht die Team-/Owner-Rechte.
function Merge-HUErTrOwnedGrants([string]$TargetKey, $Settings, $Backup) {
    $bd = Get-HUErProp $Backup 'defaultUserRolePermissions'
    if (-not $bd -or -not (Test-HUErHas $bd 'permissionGrantPoliciesAssigned')) { return $Backup }
    $live = $null
    try { $live = Invoke-HUErGraph $TargetKey $Settings '/policies/authorizationPolicy' } catch { return $Backup }
    $owned = @(@(Get-HUErProp (Get-HUErProp $live 'defaultUserRolePermissions') 'permissionGrantPoliciesAssigned') | Where-Object { "$_" -like 'ManagePermissionGrantsForOwnedResource.*' })
    if (-not $owned.Count) { return $Backup }
    $b = Copy-HUErObject $Backup
    $d = Get-HUErProp $b 'defaultUserRolePermissions'
    $cur = @(@(Get-HUErProp $d 'permissionGrantPoliciesAssigned') | Where-Object { "$_" })
    $low = @($cur | ForEach-Object { "$_".ToLowerInvariant() })
    $add = @($owned | Where-Object { $low -notcontains "$_".ToLowerInvariant() })
    if ($add.Count) { Set-HUErProp $d 'permissionGrantPoliciesAssigned' ([object[]]@($cur + $add)) }
    return $b
}

# 2.5.1 Laenderwahl (mitgelieferter Geoblock): im Muster fest + waehlbar, gewaehlt wird in der Vorschau
function Get-HUErTrCountryChoice($Backup) {
    $m = Get-HUErProp $Backup 'huLaenderwahl'
    if (-not $m) { return $null }
    $fest = @(@(Get-HUErProp $m 'fest') | Where-Object { "$_" } | ForEach-Object { "$_".ToUpperInvariant() })
    $wahl = @(@(Get-HUErProp $m 'wahl') | Where-Object { $_ -and "$(Get-HUErProp $_ 'code')" })
    return [pscustomobject]@{ Fest = $fest; Wahl = $wahl }
}

function Get-HUErTrPlanLocation($Plan, [string]$TargetKey, $Settings, $Backup) {
    $type = "$(Get-HUErProp $Backup '@odata.type')"
    $name = "$(Get-HUErProp $Backup 'displayName')"
    if ($type -notin '#microsoft.graph.ipNamedLocation', '#microsoft.graph.countryNamedLocation') { $Plan.Blocks.Add("Ortstyp '$type' wird nicht uebertragen."); return }
    $all = $null
    try { $all = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/identity/conditionalAccess/namedLocations' -V1) } catch { $Plan.Blocks.Add("Orte im Ziel nicht lesbar ($($_.Exception.Message))."); return }
    $hits = @($all | Where-Object { (ConvertTo-HUErName $_.displayName) -eq (ConvertTo-HUErName $name) })
    if ($hits.Count -gt 1) { $Plan.Blocks.Add("Den Ort '$name' gibt es im Ziel $($hits.Count)-mal - nicht eindeutig."); return }
    $cc = Get-HUErTrCountryChoice $Backup
    if ($cc -and $hits.Count -eq 1) { $Plan.Blocks.Add("Den Ort '$name' gibt es im Ziel schon - die Laender dort im Portal anpassen (die Laenderwahl gilt nur beim Neuanlegen)."); return }
    $fields = if ($type -eq '#microsoft.graph.ipNamedLocation') { @('displayName', 'ipRanges', 'isTrusted') } else { @('displayName', 'countriesAndRegions', 'includeUnknownCountriesAndRegions') }
    if ($hits.Count -eq 1) {
        # 045 B1: gleicher Name ist nicht derselbe Inhalt - Aenderung zeigen, betroffene Richtlinien nennen, bewusst bestaetigen
        $b = Copy-HUErObject $Backup
        $b | Add-Member -NotePropertyName id -NotePropertyValue "$($hits[0].id)" -Force
        Get-HUErPlanLocation $Plan $TargetKey $Settings $b
        if ($Plan.Changes.Count) {
            $use = Get-HUErCaUsingLocation $TargetKey $Settings "$($hits[0].id)"
            if ($null -eq $use) { $Plan.Blocks.Add('Conditional Access im Ziel nicht lesbar - ohne zu wissen, welche Richtlinien den Ort verwenden, wird er nicht geaendert.') }
            elseif ($use.Count) { $Plan.Confirms.Add("Der Ort '$name' im Ziel wird geaendert und wirkt sofort auf $($use.Count) Richtlinie(n): $($use -join ', ').") }
            else { $Plan.Notes.Add("Der Ort '$name' wird im Ziel von keiner CA-Richtlinie verwendet.") }
        }
    } else {
        # neu anlegen (POST); Kennung entsteht im Ziel neu
        $Plan.Method = 'POST'; $Plan.Endpoint = '/identity/conditionalAccess/namedLocations'; $Plan.ReadEndpoint = ''; $Plan.Perm = 'Policy.ReadWrite.ConditionalAccess (und Policy.Read.All)'
        $body = @{ '@odata.type' = $type }
        foreach ($f in $fields) {
            $v = Get-HUErProp $Backup $f
            if ($null -eq $v) { continue }
            if ($f -eq 'ipRanges') {
                $v = [object[]]@(@($v) | ForEach-Object {
                        $cidr = "$(Get-HUErProp $_ 'cidrAddress')"; $t = "$(Get-HUErProp $_ '@odata.type')"
                        if (-not $t) { $t = if ($cidr.Contains(':')) { '#microsoft.graph.iPv6CidrRange' } else { '#microsoft.graph.iPv4CidrRange' } }
                        @{ '@odata.type' = $t; cidrAddress = $cidr } })
                if (-not $v.Count) { $Plan.Blocks.Add('Die Bereichsliste im Muster ist leer.'); continue }
            } elseif ($f -eq 'countriesAndRegions') { $v = [object[]]@($v) }
            $body[$f] = $v
            Add-HUErChange $Plan $f '(neu)' $v
        }
        $Plan.Body = $body
        if ($cc) {
            $opts = New-Object System.Collections.Generic.List[object]
            foreach ($wx in $cc.Wahl) {
                $code = "$(Get-HUErProp $wx 'code')".ToUpperInvariant()
                if ($cc.Fest -contains $code) { continue }
                $opts.Add([pscustomobject]@{ Key = "country:$code"; Value = [bool](ConvertTo-HUErBool (Get-HUErProp $wx 'an')); Text = "Erlaubt: $(Get-HUErProp $wx 'name') ($code)" })
            }
            $Plan | Add-Member -NotePropertyName Options -NotePropertyValue $opts.ToArray() -Force
            $Plan | Add-Member -NotePropertyName CountryFixed -NotePropertyValue ([string[]]$cc.Fest) -Force
            $Plan.Notes.Add("Laender: immer erlaubt $($cc.Fest -join ', '); weitere per Haken waehlen (Liste unten). Geschrieben werden fest + angehakt.")
        }
        $Plan.Notes.Add("Den Ort '$name' gibt es im Ziel noch nicht - er wird NEU angelegt (neue Kennung). Rueckgaengig = loeschen, solange unveraendert und von keiner Richtlinie verwendet.")
        $Plan.BreakGlass = $true
    }
    # 045 B1: vertrauenswuerdig wirkt sofort auf Richtlinien mit "Alle vertrauenswuerdigen Orte" - zaehlen und nennen; nicht lesbar = nicht setzen
    if ($Plan.Body -and $Plan.Body.ContainsKey('isTrusted') -and @($Plan.Changes | Where-Object { $_.Feld -eq 'isTrusted' }).Count) {
        $use = Get-HUErCaUsingLocation $TargetKey $Settings 'AllTrusted'
        # allgemeinen Haken aus dem Zurueckschreiben durch den genaueren mit Anzahl ersetzen
        foreach ($x in @($Plan.Confirms | Where-Object { "$_" -like 'Vertrauenswuerdig wird*' })) { [void]$Plan.Confirms.Remove($x) }
        if ($null -eq $use) {
            $Plan.Body.Remove('isTrusted')
            foreach ($x in @($Plan.Changes | Where-Object { $_.Feld -eq 'isTrusted' })) { [void]$Plan.Changes.Remove($x) }
            $Plan.Warnings.Add("'Vertrauenswuerdig' wird NICHT gesetzt: Conditional Access im Ziel ist nicht lesbar.")
        }
        else { $Plan.Confirms.Add("'Vertrauenswuerdig' = $(Get-HUErProp $Backup 'isTrusted') wirkt sofort auf $($use.Count) Richtlinie(n) mit 'Alle vertrauenswuerdigen Orte'$(if ($use.Count) { ": $($use -join ', ')" }).") }
    }
}

function Get-HUErTrPlanGroupSetting($Plan, [string]$TargetKey, $Settings, $Backup, [string]$ResolveKey) {
    $tpl = "$(Get-HUErProp $Backup 'templateId')"
    if (-not $tpl) { $Plan.Blocks.Add('Der Muster-Eintrag hat keine Vorlagen-Kennung (templateId).'); return }
    # Live-Test 24.10.: PATCH auf "Password Rule Settings" mit Anwendungsrecht GroupSettings.ReadWrite.All -> 403 Authorization_RequestDenied,
    # obwohl Learn das Recht nennt (Konfidenz U). Bis das geklaert ist: nicht schreiben, im Portal setzen.
    if ($tpl -eq $script:HUErPwRuleTpl -and $script:HUErPwRuleBlocked) { $Plan.Blocks.Add('Kennwortregeln (Password Rule Settings) lassen sich per App nicht schreiben - Microsoft lehnt trotz GroupSettings.ReadWrite.All ab. Bitte im Entra Admin Center setzen: Schutz > Authentifizierungsmethoden > Kennwortschutz.'); return }
    $b = Copy-HUErObject $Backup
    # GroupCreationAllowedGroupId: Gruppe der Quelle ueber den Namen im Ziel (045 B4)
    $vals = @(Get-HUErProp $b 'values' | Where-Object { $_ })
    foreach ($v in $vals) {
        if ("$(Get-HUErProp $v 'name')" -ne 'GroupCreationAllowedGroupId' -or -not "$(Get-HUErProp $v 'value')") { continue }
        $t = Resolve-HUErGroupToTarget $ResolveKey $Settings $TargetKey "$(Get-HUErProp $v 'value')"
        if ($t.Error) { $Plan.Blocks.Add("GroupCreationAllowedGroupId: $($t.Error)."); return }
        $v.value = $t.Id
        $Plan.Notes.Add("Gruppe fuer die Gruppenerstellung '$($t.Name)' zugeordnet.")
    }
    $live = $null
    try { $live = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/groupSettings' -V1 | Where-Object { "$($_.templateId)" -eq $tpl }) | Select-Object -First 1 }
    catch { $Plan.Blocks.Add("Verzeichniseinstellungen im Ziel nicht lesbar ($($_.Exception.Message))."); return }
    if ($live) { Get-HUErPlanGroupSetting $Plan $TargetKey $Settings $b; return }
    # 045 B4: fehlt im Ziel -> POST mit kompletter Werteliste; EnableMSStandardBlockedWords nie
    $Plan.Method = 'POST'; $Plan.Endpoint = '/groupSettings'; $Plan.ReadEndpoint = ''; $Plan.Perm = 'GroupSettings.ReadWrite.All'
    $list = @($vals | Where-Object { "$(Get-HUErProp $_ 'name')" -and "$(Get-HUErProp $_ 'name')" -ne 'EnableMSStandardBlockedWords' -and $null -ne (Get-HUErProp $_ 'value') })
    if (-not $list.Count) { $Plan.Blocks.Add('Die Werteliste im Muster ist leer.'); return }
    $Plan.Body = @{ templateId = $tpl; values = [object[]]@($list | ForEach-Object { @{ name = "$(Get-HUErProp $_ 'name')"; value = "$(Get-HUErProp $_ 'value')" } }) }
    foreach ($v in $list) { Add-HUErChange $Plan "values[$(Get-HUErProp $v 'name')]" '(neu)' "$(Get-HUErProp $v 'value')" }
    if (@($vals | Where-Object { "$(Get-HUErProp $_ 'name')" -eq 'EnableMSStandardBlockedWords' }).Count) { $Plan.Dropped.Add('EnableMSStandardBlockedWords (von Microsoft eingestellt)') }
    $names = @($list | ForEach-Object { "$(Get-HUErProp $_ 'name')" })
    if ($tpl -eq $script:HUErPwRuleTpl -and @($names | Where-Object { $script:HUErPwRuleP1 -contains $_ }).Count) {
        $p1 = $false
        try { foreach ($s in @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/subscribedSkus?$select=servicePlans' -V1)) { if (@($s.servicePlans | Where-Object { "$($_.servicePlanName)" -in 'AAD_PREMIUM', 'AAD_PREMIUM_P2' -and "$($_.provisioningStatus)" -eq 'Success' }).Count) { $p1 = $true; break } } } catch { }
        if (-not $p1) { $Plan.Blocks.Add('Kennwortliste und Sperrschwelle brauchen Microsoft Entra ID P1 - im Ziel nicht gefunden.') }
    }
    $ec = @($list | Where-Object { "$(Get-HUErProp $_ 'name')" -eq 'EnableGroupCreation' -and "$(Get-HUErProp $_ 'value')" -eq 'false' })
    if ($ec.Count) { $Plan.Confirms.Add('EnableGroupCreation = false: Nicht-Admins koennen danach keine Microsoft-365-Gruppen und keine Teams mehr anlegen.') }
    $Plan.Notes.Add('Diese Verzeichniseinstellung gibt es im Ziel noch nicht - sie wird NEU angelegt. Rueckgaengig durch Loeschen ist nicht vorgesehen (045 B4); zuruecksetzen bei Bedarf im Portal oder per Zurueckschreiben.')
    $Plan.BreakGlass = $false
}

# Schreibrecht im Ziel schon in der Vorschau zeigen (045 Ue-11): Rollen aus dem App-Token lesen (Anwendungsberechtigungen).
# Rueckgabe: fehlende Rechte; $null = nicht pruefbar. Nur Hinweis, keine Sperre (frisch erteilte Rechte stehen erst im naechsten Token).
$script:HUErTrPerms = @{
    authz = @('Policy.ReadWrite.Authorization'); consent = @('Policy.ReadWrite.ConsentRequest', 'Directory.ReadWrite.All')
    location = @('Policy.ReadWrite.ConditionalAccess'); caNew = @('Policy.ReadWrite.ConditionalAccess'); groupSetting = @('GroupSettings.ReadWrite.All', 'Directory.ReadWrite.All')
}
function Get-HUErTokenRoles([string]$TenantKey, $Settings) {
    try {
        $tok = "$(Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop)"
        $part = ($tok -split '\.')[1]
        if (-not $part) { return $null }
        $part = $part.Replace('-', '+').Replace('_', '/'); switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        $j = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        return @($j.roles | ForEach-Object { "$_" })
    } catch { return $null }
}

# ---------- 2.4.5 Conditional Access uebertragen (045 Ue-2 bis Ue-7, B2, F1, F5) ----------
# Nur NEU und nur "Nur Bericht" (Benutzeraktionen: aus). Alle Kennungen werden fuer das Ziel umgesetzt oder gesperrt.
$script:HUErBuiltinStrengthRx = '^00000000-0000-0000-0000-0000000000\d\d$'
function Get-HUErBreakGlassIds([string]$TenantKey) {
    try {
        $bl = Get-HUSecBaseline -TenantKey $TenantKey
        if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { return , [string[]]@($bl.Values['V1'].accounts | Where-Object { "$_" } | ForEach-Object { "$_" }) }
    } catch { }
    return , [string[]]@()
}
function Set-HUErProp($Obj, [string]$Name, $Value) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }

function Get-HUErTrPlanCa($Plan, [string]$TargetKey, $Settings, $Backup, [string]$ResolveKey, [string]$SourceLabel, [hashtable]$SourceNames = @{}) {
    $Plan.Perm = 'Policy.ReadWrite.ConditionalAccess (und Policy.Read.All)'
    # von Microsoft verwaltete Richtlinien legt Microsoft in jedem Tenant selbst an - keine Kopie
    if ("$(Get-HUErProp $Backup 'displayName')" -like 'Microsoft-managed:*') { $Plan.Blocks.Add('Von Microsoft verwaltete Richtlinie - Microsoft legt sie in jedem Tenant selbst an; dort im Portal ein-/ausschalten statt kopieren.'); return }
    $b = Copy-HUErObject $Backup
    $c = Get-HUErProp $b 'conditions'
    if (-not $c) { $Plan.Blocks.Add('Der Muster-Eintrag hat keine Bedingungen (conditions).'); return }
    $u = Get-HUErProp $c 'users'
    if (-not $u) { $Plan.Blocks.Add('Der Muster-Eintrag hat keine Benutzer-Bedingung.'); return }
    # Zuweisung wird NICHT uebertragen (wie Intune ohne Zuweisungen): Konten, Gruppen, Gaeste leer, "Keine" als Benutzer.
    # Nur die Notfallkonten des Ziels werden ausgenommen (045 F1), Rollen sind ueberall gleich und waehlbar (Udo 24.10.).
    # Liste ohne Pipeline auspacken: die Funktion gibt die Liste mit Komma zurueck - eine LEERE Liste (z. B. Quelle mitgeliefert)
    # kaeme sonst als ein Objekt in ForEach an und ToLowerInvariant schluege fehl (Test 25.10.)
    $srcBgRaw = [string[]](Get-HUErBreakGlassIds $ResolveKey)
    $srcBg = @($srcBgRaw | Where-Object { "$_" } | ForEach-Object { "$_".ToLowerInvariant() })
    # ohne @(): die Funktion gibt die Liste mit Komma zurueck, @() wuerde eine Liste in der Liste daraus machen (Graph 400)
    $tgtBg = [string[]](Get-HUErBreakGlassIds $TargetKey)
    if (-not $tgtBg.Count) { $Plan.Blocks.Add('Im Ziel sind keine Notfallkonten hinterlegt (Analyse > Sicherheit > Sollwerte, V1) - ohne sie wird keine Conditional-Access-Richtlinie uebertragen (045 F1).') }
    # was im Muster zugewiesen ist (nur Anzeige, Namen aus der Quelle)
    $nameOf = {
        param([string]$Kind, [string]$Id)
        if ($Id -notmatch $script:HUErGuidRx) { return $Id }
        $ep = if ($Kind -eq 'u') { "/users/$Id`?`$select=id,userPrincipalName" } else { "/groups/$Id`?`$select=id,displayName" }
        try { $o = Invoke-HUErGraph $ResolveKey $Settings $ep; if ($Kind -eq 'u') { return "$($o.userPrincipalName)" } else { return "$($o.displayName)" } } catch { return $Id }
    }
    # 2.5.1 Gruppen-Plaetze: Gruppen des Musters (Name aus der Quelle) und Platzhalter mitgelieferter Pakete (huGruppen) -
    # in der Vorschau je Platz eine Gruppe des Ziels waehlen, die gleich zugewiesen wird (Udo 25.10.)
    $slots = New-Object System.Collections.Generic.List[object]
    foreach ($gf in 'includeGroups', 'excludeGroups') {
        foreach ($gx in @(Get-HUErProp $u $gf | Where-Object { "$_" -match $script:HUErGuidRx })) { $slots.Add([pscustomobject]@{ Feld = $gf; Name = (& $nameOf 'g' "$gx") }) }
    }
    foreach ($hg in @(Get-HUErProp $Backup 'huGruppen' | Where-Object { $_ })) {
        $gf = "$(Get-HUErProp $hg 'feld')"; $gn = "$(Get-HUErProp $hg 'name')"
        if ($gf -in 'includeGroups', 'excludeGroups' -and $gn) { $slots.Add([pscustomobject]@{ Feld = $gf; Name = $gn }) }
    }
    $gChoices = $null
    if ($slots.Count) {
        try {
            $gChoices = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/groups?$select=id,displayName,securityEnabled,groupTypes' -V1 |
                    Where-Object { (ConvertTo-HUErBool $_.securityEnabled) -or @($_.groupTypes) -contains 'Unified' } |
                    ForEach-Object { [pscustomobject]@{ Id = "$($_.id)"; Name = "$($_.displayName)" } } | Sort-Object Name)
        } catch { $gChoices = $null; $Plan.Warnings.Add("Gruppen im Ziel nicht lesbar ($($_.Exception.Message)) - Gruppen werden nicht zugewiesen (Leserecht Group.Read.All).") }
    }
    $was = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(@('includeUsers', 'u', 'Konten'), @('includeGroups', 'g', 'Gruppen'), @('excludeUsers', 'u', 'Ausnahmen Konten'), @('excludeGroups', 'g', 'Ausnahmen Gruppen'))) {
        if ($pair[1] -eq 'g' -and $null -ne $gChoices) { continue }
        $vals = @(Get-HUErProp $u $pair[0] | Where-Object { "$_" -match $script:HUErGuidRx -and $srcBg -notcontains "$_".ToLowerInvariant() })
        if ($vals.Count) { $was.Add("$($pair[2]): $(@($vals | ForEach-Object { & $nameOf $pair[1] "$_" }) -join ', ')") }
    }
    # "alle Gaeste und externen Benutzer" (alle externen Tenants) ist ein Schluesselwort ohne Kennungen - per Haken uebernehmbar (unten)
    $ig = Get-HUErProp $u 'includeGuestsOrExternalUsers'
    $hasGuests = [bool]($ig -and "$(Get-HUErProp $ig 'guestOrExternalUserTypes')" -and "$(Get-HUErProp (Get-HUErProp $ig 'externalTenants') 'membershipKind')" -eq 'all')
    if (($ig -and -not $hasGuests) -or @(Get-HUErProp $u 'includeUsers' | ForEach-Object { "$_" }) -contains 'GuestsOrExternalUsers') { $was.Add('Gaeste/externe Benutzer (bestimmte Tenants)') }
    if ($was.Count) { $Plan.Warnings.Add("Zuweisung wird NICHT uebertragen - im Muster: $($was -join ' | '). Im Ziel selbst zuweisen.") }
    # Rollen: nur eingebaute (Ue-4; CA wirkt nur mit eingebauten Rollen)
    $roleNames = New-Object System.Collections.Generic.List[string]
    # 2.5.1 mitgelieferte "100 - Admin-Portale": alle eingebauten Rollen des ZIELS ausnehmen - die Liste aendert Microsoft laufend (Udo 25.10.)
    $allRolesDyn = ("$(Get-HUErProp $Backup 'huRollen')" -eq 'alleEingebautenAusnehmen')
    if ($allRolesDyn) {
        $br = $null
        try { $br = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/roleManagement/directory/roleDefinitions?$select=id,templateId,displayName,isBuiltIn,isEnabled' -V1 | Where-Object { (ConvertTo-HUErBool $_.isBuiltIn) -and "$($_.isEnabled)" -ne 'False' }) } catch { $Plan.Blocks.Add("Rollen im Ziel nicht lesbar ($($_.Exception.Message)) - ohne sie wuerde die Richtlinie alle Admins aussperren."); return }
        $rids = @($br | ForEach-Object { $(if ("$($_.templateId)") { "$($_.templateId)" } else { "$($_.id)" }) } | Where-Object { $_ -match $script:HUErGuidRx -and $script:HUErNoAdminRoles -notcontains "$_".ToLowerInvariant() } | Select-Object -Unique)
        if (-not $rids.Count) { $Plan.Blocks.Add('Im Ziel wurden keine eingebauten Rollen gelesen - ohne sie wuerde die Richtlinie alle Admins aussperren.'); return }
        Set-HUErProp $u 'excludeRoles' ([object[]]$rids)
        $roleNames.Add("ausser alle $($rids.Count) eingebauten Rollen")
        $Plan.Notes.Add("Ausgenommen: alle $($rids.Count) eingebauten Admin-Rollen, die das Ziel jetzt hat (ohne Benutzer-, Gast- und Geraete-Rollen). Kommen spaeter neue Rollen von Microsoft dazu, im Portal ergaenzen.")
    }
    foreach ($f in 'includeRoles', 'excludeRoles') {
        if ($allRolesDyn -and $f -eq 'excludeRoles') { continue }
        foreach ($x in @(Get-HUErProp $u $f | Where-Object { "$_" -match $script:HUErGuidRx })) {
            try {
                $rd = Invoke-HUErGraph $TargetKey $Settings "/roleManagement/directory/roleDefinitions/$x`?`$select=id,isBuiltIn,displayName"
                if (-not (ConvertTo-HUErBool $rd.isBuiltIn)) { $Plan.Blocks.Add("Rolle '$($rd.displayName)' ist eine eigene Rolle - wird nicht uebertragen.") }
                elseif ($f -eq 'includeRoles') { $roleNames.Add("$($rd.displayName)") }
                else { $roleNames.Add("ausser $($rd.displayName)") }
            } catch { $Plan.Blocks.Add("Rolle $x gibt es im Ziel nicht als eingebaute Rolle.") }
        }
    }
    $hasRoles = [bool]@(Get-HUErProp $u 'includeRoles' | Where-Object { "$_" }).Count
    # "Alle Benutzer" ist ein Schluesselwort (in jedem Tenant gleich) - wie Rollen waehlbar
    $hasAll = @(Get-HUErProp $u 'includeUsers' | ForEach-Object { "$_" }) -contains 'All'
    # 053 B1: ohne $( ) - ein leeres @() wuerde darin zu $null (Graph: "includeUsers": null -> 400); Rollen-Pfad braucht []
    $iu = New-Object System.Collections.Generic.List[string]
    if ($hasAll) { $iu.Add('All') } elseif (-not $hasRoles -and -not $hasGuests) { $iu.Add('None') }
    $nu = [pscustomobject]@{ includeUsers = [object[]]$iu.ToArray(); excludeUsers = [object[]]$tgtBg; includeGroups = [object[]]@(); excludeGroups = [object[]]@()
        includeRoles = [object[]]@(Get-HUErProp $u 'includeRoles' | Where-Object { "$_" }); excludeRoles = [object[]]@(Get-HUErProp $u 'excludeRoles' | Where-Object { "$_" }) }
    if ($hasGuests) { $nu | Add-Member -NotePropertyName includeGuestsOrExternalUsers -NotePropertyValue (Copy-HUErObject $ig) -Force }
    # Ausnahme "alle Gaeste und externen Benutzer" (alle externen Tenants) ist ein Schluesselwort ohne Kennungen - bleibt erhalten
    # (z. B. mitgelieferte Vorlage "Registrierung der Sicherheitsinfos"); eine Auswahl bestimmter Tenants wird nicht uebertragen
    $xg = Get-HUErProp $u 'excludeGuestsOrExternalUsers'
    if ($xg -and "$(Get-HUErProp $xg 'guestOrExternalUserTypes')") {
        if ("$(Get-HUErProp (Get-HUErProp $xg 'externalTenants') 'membershipKind')" -eq 'all') {
            $nu | Add-Member -NotePropertyName excludeGuestsOrExternalUsers -NotePropertyValue (Copy-HUErObject $xg) -Force
            $Plan.Notes.Add('Ausnahme: alle Gaeste und externen Benutzer (wie im Muster).')
        } else { $Plan.Warnings.Add('Die Ausnahme fuer Gaeste bestimmter Tenants wird NICHT uebertragen (Tenant-Kennungen) - im Ziel selbst setzen.') }
    }
    Set-HUErProp $c 'users' $nu
    $opts = New-Object System.Collections.Generic.List[object]
    if ($hasAll) { $opts.Add([pscustomobject]@{ Key = 'allUsers'; Value = $true; Text = "Benutzer 'Alle' aus dem Muster uebernehmen (Schluesselwort, in jedem Tenant gleich). Ohne Haken: Benutzer 'Keine'." }) }
    if ($hasRoles) { $opts.Add([pscustomobject]@{ Key = 'roles'; Value = $true; Text = "Rollen aus dem Muster uebernehmen (in jedem Tenant gleich): $($roleNames -join ', ')." }) }
    if ($hasGuests) { $opts.Add([pscustomobject]@{ Key = 'guests'; Value = $true; Text = "Benutzer 'alle Gaeste und externen Benutzer' aus dem Muster uebernehmen (Schluesselwort, in jedem Tenant gleich). Ohne Haken: Benutzer 'Keine'." }) }
    if ($null -ne $gChoices) {
        $i = 0
        foreach ($sl in $slots) {
            $i++
            $pre = @($gChoices | Where-Object { (ConvertTo-HUErName $_.Name) -eq (ConvertTo-HUErName $sl.Name) })
            $opts.Add([pscustomobject]@{ Key = "group:$i"; Kind = 'group'; Feld = $sl.Feld; Slot = $sl.Name; Value = $(if ($pre.Count -eq 1) { $pre[0].Id } else { '' })
                    Choices = [object[]]$gChoices; Text = "$(if ($sl.Feld -eq 'includeGroups') { 'Gilt fuer Gruppe' } else { 'Ausgenommen Gruppe' }) '$($sl.Name)':" })
        }
        $Plan.Notes.Add('Gruppen: je Platz eine Gruppe im Ziel waehlen (leer = nicht zuweisen). Gleichnamige Gruppen sind vorgewaehlt.')
    }
    if ($opts.Count) { $Plan | Add-Member -NotePropertyName Options -NotePropertyValue $opts.ToArray() -Force }
    else { $Plan.Notes.Add("Benutzer: 'Keine' - die Richtlinie gilt erst, wenn du sie im Ziel zuweist.") }
    # Orte ueber den Namen (Ue-2)
    $l = Get-HUErProp $c 'locations'
    if ($l) {
        $tl = $null
        foreach ($f in 'includeLocations', 'excludeLocations') {
            $new = New-Object System.Collections.Generic.List[string]
            foreach ($x in @(Get-HUErProp $l $f | Where-Object { "$_" })) {
                if ("$x" -notmatch $script:HUErGuidRx) { $new.Add("$x"); continue }
                $sn = ''
                # 2.5.1 Namen aus dem Muster selbst (mitgelieferte Pakete: der Ort ist Teil des Pakets, nicht in einem Tenant)
                if ($SourceNames -and $SourceNames.ContainsKey("$x".ToLowerInvariant())) { $sn = "$($SourceNames["$x".ToLowerInvariant()])" }
                if (-not $sn) { try { $sn = "$((Invoke-HUErGraph $ResolveKey $Settings "/identity/conditionalAccess/namedLocations/$x").displayName)" } catch { } }
                if (-not $sn) { $Plan.Blocks.Add("Benannter Ort $x ist in der Quelle nicht (mehr) lesbar."); continue }
                if ($null -eq $tl) { try { $tl = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/identity/conditionalAccess/namedLocations?$select=id,displayName' -V1) } catch { $Plan.Blocks.Add("Orte im Ziel nicht lesbar ($($_.Exception.Message))."); return } }
                $hits = @($tl | Where-Object { (ConvertTo-HUErName $_.displayName) -eq (ConvertTo-HUErName $sn) })
                if ($hits.Count -ne 1) { $Plan.Blocks.Add("Den Ort '$sn' gibt es im Ziel $(if ($hits.Count) { "$($hits.Count)-mal" } else { 'nicht' }) - zuerst den Ort uebertragen."); continue }
                $new.Add("$($hits[0].id)"); $Plan.Notes.Add("Ort '$sn' zugeordnet ($x -> $($hits[0].id)).")
            }
            Set-HUErProp $l $f ([object[]]$new.ToArray())
        }
    }
    # Dienstprinzipale (Objekt-IDs je Tenant) und Filterregeln mit Kennungen -> Sperre (050 Teil B)
    $ca = Get-HUErProp $c 'clientApplications'
    # 053 B3: auch ein Filter auf Dienstprinzipale (Sicherheitsattribute der Quelle) wird nicht uebertragen
    if ("$(Get-HUErProp (Get-HUErProp $ca 'servicePrincipalFilter') 'rule')") { $Plan.Blocks.Add('Die Richtlinie filtert Workload-Identitaeten (servicePrincipalFilter) - wird nicht uebertragen.') }
    if (@(@(Get-HUErProp $ca 'includeServicePrincipals') + @(Get-HUErProp $ca 'excludeServicePrincipals') | Where-Object { "$_" }).Count) { $Plan.Blocks.Add('Die Richtlinie gilt fuer Workload-Identitaeten (Dienstprinzipale, Kennungen je Tenant) - wird nicht uebertragen.') }
    foreach ($fp in @(@('devices', 'deviceFilter'), @('applications', 'applicationFilter'))) {
        $rule = "$(Get-HUErProp (Get-HUErProp (Get-HUErProp $c $fp[0]) $fp[1]) 'rule')"
        if ($rule -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') { $Plan.Blocks.Add("Die Filterregel ($($fp[1])) enthaelt eine Kennung - die gilt nur in der Quelle, wird nicht uebertragen.") }
    }
    # Nutzungsbedingungen, eigene Steuerelemente: nicht uebertragbar (Ue-5)
    $g = Get-HUErProp $b 'grantControls'
    if (@(Get-HUErProp $g 'termsOfUse' | Where-Object { "$_" }).Count) { $Plan.Blocks.Add('Nutzungsbedingungen (termsOfUse) werden nicht uebertragen.') }
    # 053 B2: eigene Steuerelemente sind Kennungen der Quelle
    if (@(Get-HUErProp $g 'customAuthenticationFactors' | Where-Object { "$_" }).Count) { $Plan.Blocks.Add('Eigene Steuerelemente (customAuthenticationFactors) werden nicht uebertragen.') }
    # Authentifizierungsstaerke: eingebaute bleiben (im Ziel geprueft), eigene ueber den Namen
    $asId = "$(Get-HUErProp (Get-HUErProp $g 'authenticationStrength') 'id')"
    if ($asId -and $asId -match $script:HUErBuiltinStrengthRx) {
        # eingebaute Staerke: gleiche Kennung in jedem Tenant - im Ziel nachlesen und mit Namen zeigen (falsche Kennung -> Sperre statt Graph 400)
        try {
            $bs = Invoke-HUErGraph $TargetKey $Settings "/policies/authenticationStrengthPolicies/$asId`?`$select=id,displayName,policyType"
            $Plan.Notes.Add("Authentifizierungsstaerke '$($bs.displayName)' (eingebaut).")
        } catch { $Plan.Blocks.Add("Eingebaute Authentifizierungsstaerke $asId ist im Ziel nicht lesbar ($($_.Exception.Message)).") }
    }
    if ($asId -and $asId -notmatch $script:HUErBuiltinStrengthRx) {
        $sn = ''
        try { $sn = "$((Invoke-HUErGraph $ResolveKey $Settings "/policies/authenticationStrengthPolicies/$asId`?`$select=id,displayName").displayName)" } catch { }
        if (-not $sn) { $Plan.Blocks.Add("Authentifizierungsstaerke $asId ist in der Quelle nicht (mehr) lesbar.") }
        else {
            $hits = @()
            try { $hits = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/policies/authenticationStrengthPolicies?$select=id,displayName' -V1 | Where-Object { (ConvertTo-HUErName $_.displayName) -eq (ConvertTo-HUErName $sn) }) } catch { }
            if ($hits.Count -ne 1) { $Plan.Blocks.Add("Authentifizierungsstaerke '$sn' gibt es im Ziel $(if ($hits.Count) { "$($hits.Count)-mal" } else { 'nicht' }).") }
            else { Set-HUErProp (Get-HUErProp $g 'authenticationStrength') 'id' "$($hits[0].id)"; $Plan.Notes.Add("Authentifizierungsstaerke '$sn' zugeordnet.") }
        }
    }
    if ($Plan.Blocks.Count) { return }
    # Name: fehlt die Richtlinie im Ziel -> Originalname (im Vergleich dann gleich zugeordnet); gibt es sie schon -> Zusatz "(von Muster)",
    # damit die neue Nur-Bericht-Richtlinie neben der bestehenden unterscheidbar bleibt (die bestehende wird nie geaendert, 045 Ue-7)
    $on = "$(Get-HUErProp $Backup 'displayName')"
    $exists = $false
    try { $exists = [bool]@(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/identity/conditionalAccess/policies?$select=displayName' -V1 | Where-Object { (ConvertTo-HUErName $_.displayName) -eq (ConvertTo-HUErName $on) }).Count } catch { $exists = $true }
    $nn = if ($exists) { "$on (von Muster)" } else { $on }
    if ($exists) { $Plan.Notes.Add("'$on' gibt es im Ziel schon - die bestehende bleibt unveraendert, die neue heisst '$nn'.") }
    Get-HUErPlanCaNew $Plan $TargetKey $Settings $b $nn
    # Hinweis aus dem Wiederherstellen ("die bestehende ... alte entfernen") passt nur, wenn es die Richtlinie im Ziel schon gibt
    if (-not $exists) {
        foreach ($x in @($Plan.Notes | Where-Object { "$_" -like 'Es wird eine NEUE Richtlinie angelegt*' })) { [void]$Plan.Notes.Remove($x) }
        $Plan.Notes.Add('Die Richtlinie fehlt im Ziel und wird mit dem Originalnamen NEU angelegt. Nach der Pruefung im Anmeldeprotokoll (Nur Bericht) im Ziel zuweisen und selbst einschalten.')
    }
    # Notfallkonten des Ziels muessen aktiv sein (043/045 Ue-3)
    $Plan.BreakGlass = $true
}

# Plan je Ziel (liest nur): Entra-Einstellung aus dem Muster uebertragen
function Get-HUEntraTransferPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [string]$Id = '', [string]$Name = '',
        [Parameter(Mandatory)]$Backup, [Parameter(Mandatory)][string]$ResolveKey, [string]$SourceLabel = 'Muster', [hashtable]$SourceNames = @{})
    $kind = Get-HUEntraRestoreKind $Typ $Id
    if ($script:HUErTrKinds -notcontains $kind) { throw "$Typ '$Name' wird (noch) nicht uebertragen" }
    $plan = New-HUErPlan $kind $TargetKey $Typ $Name
    $plan | Add-Member -NotePropertyName Transfer -NotePropertyValue $true
    $plan | Add-Member -NotePropertyName SourceLabel -NotePropertyValue $SourceLabel
    $plan | Add-Member -NotePropertyName EntraId -NotePropertyValue $Id
    if ($TargetKey -eq $ResolveKey) { $plan.Blocks.Add('Ziel ist der Tenant, aus dem das Muster stammt - dafuer gibt es Zurueckschreiben.'); return $plan }
    switch ($kind) {
        'authz' { Get-HUErPlanAuthz $plan $TargetKey $Settings (Merge-HUErTrOwnedGrants $TargetKey $Settings $Backup) }
        'consent' { Get-HUErTrPlanConsent $plan $TargetKey $Settings $Backup $ResolveKey }
        'location' { Get-HUErTrPlanLocation $plan $TargetKey $Settings $Backup }
        'groupSetting' { Get-HUErTrPlanGroupSetting $plan $TargetKey $Settings $Backup $ResolveKey }
        'caNew' { Get-HUErTrPlanCa $plan $TargetKey $Settings $Backup $ResolveKey $SourceLabel $SourceNames }
    }
    if ($plan.BreakGlass -eq $true -and $plan.Changes.Count) {
        $bg = Test-HUEntraBreakGlass -TenantKey $TargetKey -Settings $Settings
        $plan.BreakGlass = $bg
        if (-not $bg.Ok) { $plan.Blocks.Add("Ziel: $($bg.Text)") }
    }
    if (-not $plan.Changes.Count -and -not $plan.Blocks.Count) { $plan.Blocks.Add('Im Ziel schon gleich wie im Muster - nichts zu uebertragen.') }
    if (-not $plan.Blocks.Count) {
        $roles = Get-HUErTokenRoles $TargetKey $Settings
        $need = @($script:HUErTrPerms[$kind])
        if ($null -ne $roles -and $need.Count -and -not @($need | Where-Object { $roles -contains $_ }).Count) {
            $plan.Warnings.Add("Schreibrecht $($need[0]) ist im Ziel nicht erteilt (Berechtigungen > Tenant > 'Entra-Schreibrechte an ...') - so wuerde Intune/Entra das Schreiben ablehnen. Gerade erst erteilt? Dann gilt es erst mit dem naechsten Token (Trennen/Verbinden).")
        }
    }
    $plan.Notes.Add("Quelle: $SourceLabel (festgehaltener Stand). Geprueft wird im Ziel.")
    return $plan
}

function Get-HUErTrUndoDir($Settings, [string]$TenantKey) { return (Join-Path (Join-Path (Get-HUBackupRoot $Settings) (ConvertTo-HUSafeFileName $TenantKey)) '_vor-uebertragen') }

# Schreiben nach Bestaetigung. PATCH/PUT ueber Invoke-HUEntraRestore (erneut lesen, sichern, schreiben, nachpruefen);
# POST (neuer Ort / neue Verzeichniseinstellung): anlegen, nachlesen, je Feld pruefen. Danach Rueckgaengig-Datei.
# Laenderwahl aus der Vorschau in den Inhalt und die Nachpruefung uebernehmen (fest + angehakt)
function Set-HUErTrCountryBody($Plan) {
    $sel = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($Plan.CountryFixed)) { if ("$f" -and -not $sel.Contains("$f")) { $sel.Add("$f") } }
    foreach ($o in @($(if ($Plan.PSObject.Properties['Options']) { $Plan.Options }) | Where-Object { $_ -and "$($_.Key)" -like 'country:*' -and [bool]$_.Value })) {
        $code = "$($o.Key)".Substring(8)
        if (-not $sel.Contains($code)) { $sel.Add($code) }
    }
    $v = [object[]]$sel.ToArray()
    $Plan.Body['countriesAndRegions'] = $v
    foreach ($ch in @($Plan.Changes | Where-Object { $_.Feld -eq 'countriesAndRegions' })) {
        $ch.Expected = $v; $ch.Danach = Format-HUErValue $v; $ch.DanachVoll = Format-HUErValue $v -Full
        $ch.Anzahl = "0 -> $($v.Count)"
    }
}

function Invoke-HUEntraTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings, [string]$Actor = "$env:USERNAME", [datetime]$Now = (Get-Date))
    if ($Plan.Blocks.Count) { throw "Nicht uebertragen: $($Plan.Blocks -join ' ')" }
    $tk = $Plan.TenantKey
    $dir = Get-HUErTrUndoDir $Settings $tk
    $stamp = $Now.ToString('yyyy-MM-dd_HHmmss')
    if ($Plan.Method -ne 'POST') {
        $res = Invoke-HUEntraRestore -Plan $Plan -Settings $Settings -Actor "$Actor (Uebertragen aus $($Plan.SourceLabel))"
        $before = $null; try { $before = Read-HUBackupJson $res.BackupFile } catch { }
        $ha = ''; try { $ha = Get-HUErHash $(if ($null -ne $res.After) { $res.After } else { Invoke-HUErGraph $tk $Settings $Plan.ReadEndpoint }) } catch { }
        $file = Join-Path $dir "$($stamp)_geaendert_$(ConvertTo-HUSafeFileName $Plan.Name 40).json"
        Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'entraChanged'; Tenant = $tk; Typ = $Plan.Typ; EntraId = "$($Plan.EntraId)"; Name = $Plan.Name; ReadEndpoint = $Plan.ReadEndpoint; HashAfter = $ha; Before = $before; Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
        $res | Add-Member -NotePropertyName UndoFile -NotePropertyValue $file -Force
        return $res
    }
    if ($Plan.Kind -eq 'caNew') {
        # CA: hoechstens eine Anfrage je Sekunde (045, Learn) - vor dem Anlegen kurz warten
        Start-Sleep -Seconds 1
        # Auswahl in der Vorschau: Rollen nicht uebernehmen -> Benutzer 'Keine'
        $opts = @($(if ($Plan.PSObject.Properties['Options']) { $Plan.Options }) | Where-Object { $_ })
        $oR = @($opts | Where-Object { "$($_.Key)" -eq 'roles' }); $oA = @($opts | Where-Object { "$($_.Key)" -eq 'allUsers' }); $oG = @($opts | Where-Object { "$($_.Key)" -eq 'guests' })
        $keepR = $oR.Count -and [bool]$oR[0].Value; $keepA = $oA.Count -and [bool]$oA[0].Value; $keepG = $oG.Count -and [bool]$oG[0].Value
        if ($opts.Count) {
            $us = $Plan.Body['conditions']['users']
            # immer als Liste ([object[]]): $( ) wuerde eine Liste mit einem Eintrag zu einem Text auspacken (Graph 400)
            # Rollen nur leeren, wenn der Rollen-Haken angeboten und abgewaehlt wurde - eine reine Rollen-Ausnahme (z. B. Konto der
            # Entra-Synchronisierung bei "Alle Benutzer") bleibt sonst erhalten
            if ($oR.Count -and -not $keepR) { $us['includeRoles'] = [object[]]@(); $us['excludeRoles'] = [object[]]@() }
            if ($oG.Count -and -not $keepG -and $us.Contains('includeGuestsOrExternalUsers')) { $us.Remove('includeGuestsOrExternalUsers') }
            # 2.5.1 gewaehlte Gruppen des Ziels zuweisen (leer = nicht zuweisen)
            $gIn = @($opts | Where-Object { "$($_.Kind)" -eq 'group' -and "$($_.Feld)" -eq 'includeGroups' -and "$($_.Value)" -match $script:HUErGuidRx } | ForEach-Object { "$($_.Value)" } | Select-Object -Unique)
            $gEx = @($opts | Where-Object { "$($_.Kind)" -eq 'group' -and "$($_.Feld)" -eq 'excludeGroups' -and "$($_.Value)" -match $script:HUErGuidRx } | ForEach-Object { "$($_.Value)" } | Select-Object -Unique)
            $us['includeGroups'] = [object[]]$gIn; $us['excludeGroups'] = [object[]]$gEx
            # 053 B1: Liste statt $( ) - im Rollen-Pfad muss [] gesendet werden, nicht null
            $iu = New-Object System.Collections.Generic.List[string]
            if ($keepA) { $iu.Add('All') } elseif (-not $keepR -and -not $keepG -and -not $gIn.Count) { $iu.Add('None') }
            $us['includeUsers'] = [object[]]$iu.ToArray()
        }
        $res = Invoke-HUErCreate $Plan $Settings "$Actor (Uebertragen aus $($Plan.SourceLabel))"
        $file = ''
        $ep = "$($Plan.Endpoint)/$($res.NewId)"
        $after = $res.After
        if ($null -eq $after) { foreach ($wait in @($script:HUErReadDelays)) { Start-Sleep -Seconds $wait; try { $after = Invoke-HUErGraph $tk $Settings $ep; break } catch { } } }
        if ($null -eq $after) { Write-HULog -Message "Rueckgaengig-Datei fuer '$($Plan.Body.displayName)' nicht angelegt: Richtlinie (Id $($res.NewId)) nicht nachlesbar - bei Bedarf im Portal loeschen." -Level 'WARN' -Tenant $tk }
        if ($null -ne $after) {
            $file = Join-Path $dir "$($stamp)_neu_$(ConvertTo-HUSafeFileName $Plan.Name 40).json"
            Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'entraCreated'; Tenant = $tk; Typ = $Plan.Typ; Name = "$($Plan.Body.displayName)"; Id = "$($res.NewId)"; Endpoint = $ep; Hash = (Get-HUErHash $after); Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
        }
        $res | Add-Member -NotePropertyName UndoFile -NotePropertyValue $file -Force
        return $res
    }
    if ($Plan.Kind -eq 'location' -and $Plan.PSObject.Properties['CountryFixed']) { Set-HUErTrCountryBody $Plan }
    $r = $null
    try { $r = Invoke-HUErGraph $tk $Settings $Plan.Endpoint 'POST' $Plan.Body }
    catch { if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm). Nichts angelegt. Microsoft meldet: $($_.Exception.Message)" }; throw }
    $id = "$($r.id)"
    if (-not $id) { throw 'Angelegt, aber ohne Kennung zurueckgemeldet - bitte im Portal pruefen.' }
    Write-HULog -Message "Uebertragen: $($Plan.Typ) '$($Plan.Name)' aus $($Plan.SourceLabel) neu angelegt (Id $id, durch $Actor)" -Level 'OK' -Tenant $tk
    $after = $null; $readErr = ''
    foreach ($wait in @(@(0) + @($script:HUErReadDelays))) {
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        try { $after = Invoke-HUErGraph $tk $Settings "$($Plan.Endpoint)/$id"; $readErr = ''; break }
        catch { $readErr = "$($_.Exception.Message)"; if ($_.Exception.Data['StatusCode'] -ne 404) { break } }
    }
    $bad = New-Object System.Collections.Generic.List[string]
    if ($null -eq $after) { $bad.Add("Angelegt (Id $id), aber nicht nachlesbar ($readErr) - bitte im Portal pruefen und NICHT erneut anlegen.") }
    else {
        foreach ($c in $Plan.Changes) {
            if ($c.Feld -eq 'displayName' -and $Plan.Kind -eq 'groupSetting') { continue }
            # beide Seiten als Liste: eine Liste mit einem Eintrag kommt aus Funktionen ausgepackt zurueck
            if (-not (Test-HUErEqual @(Get-HUErPathValue $after $c.Feld) @($c.Expected))) { $bad.Add("$($c.Feld): erwartet $($c.Danach), gelesen $(Format-HUErValue (Get-HUErPathValue $after $c.Feld))") }
        }
    }
    foreach ($b in $bad) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Name)': $b" -Level 'WARN' -Tenant $tk }
    $file = ''
    if ($Plan.Kind -eq 'location' -and $null -ne $after) {
        $file = Join-Path $dir "$($stamp)_neu_$(ConvertTo-HUSafeFileName $Plan.Name 40).json"
        Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'entraCreated'; Tenant = $tk; Typ = $Plan.Typ; Name = $Plan.Name; Id = $id; Endpoint = "$($Plan.Endpoint)/$id"; Hash = (Get-HUErHash $after); Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
    }
    return [pscustomobject]@{ Ok = (-not $bad.Count); Written = 1; Mismatch = @($bad); BackupFile = ''; NewId = $id; UndoFile = $file; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

# Rueckgaengig fuer Entra-Uebertragungen (045 F5): geaendert -> gesicherten Stand mit derselben Logik wie Zurueckschreiben
# (dieselben Sperren, u. a. Notfallkonten); neu angelegter Ort -> loeschen, nur unveraendert und von keiner Richtlinie verwendet.
function Undo-HUEntraTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$U, [switch]$CheckOnly)
    $tk = "$($U.Tenant)"
    if ("$($U.Kind)" -eq 'entraCreated') {
        $cur = $null
        try { $cur = Invoke-HUErGraph $tk $Settings "$($U.Endpoint)" }
        catch {
            if ($_.Exception.Data['StatusCode'] -eq 404) { Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.erledigt.json') -Force; return [pscustomobject]@{ Deleted = $false; Text = 'Gibt es im Ziel nicht mehr - nichts zu tun.' } }
            throw
        }
        # 045 F5: eine neu angelegte CA nur loeschen, solange sie Nur Bericht oder aus ist
        if ("$($U.Typ)" -eq 'Conditional Access' -and "$($cur.state)" -notin 'enabledForReportingButNotEnforced', 'disabled') { throw "'$($U.Name)' ist inzwischen EINGESCHALTET - nicht automatisch geloescht." }
        if ((Get-HUErHash $cur) -ne "$($U.Hash)") { throw "'$($U.Name)' wurde nach dem Uebertragen geaendert - nicht automatisch geloescht." }
        if ("$($U.Typ)" -ne 'Conditional Access') {
            $use = Get-HUErCaUsingLocation $tk $Settings "$($U.Id)"
            if ($null -eq $use) { throw 'Conditional Access im Ziel nicht lesbar - nicht geloescht.' }
            if ($use.Count) { throw "'$($U.Name)' wird inzwischen verwendet: $($use -join ', ') - nicht geloescht." }
        }
        if ($CheckOnly) { return [pscustomobject]@{ Deleted = $false; Text = 'Loeschen moeglich' } }
        [void](Invoke-HUErGraph $tk $Settings "$($U.Endpoint)" 'DELETE')
        Write-HULog -Message "Rueckgaengig: $($U.Typ) '$($U.Name)' im Ziel geloescht (uebertragen $($U.Time) aus $($U.Source))" -Level 'OK' -Tenant $tk
        Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.rueckgaengig.json') -Force
        return [pscustomobject]@{ Deleted = $true; Text = "'$($U.Name)' geloescht." }
    }
    # entraChanged
    if ($null -eq $U.Before) { throw "Fuer '$($U.Name)' fehlt der gesicherte Stand - bitte im Portal pruefen." }
    $now = $null
    try { $now = Invoke-HUErGraph $tk $Settings "$($U.ReadEndpoint)" } catch { throw "'$($U.Name)' im Ziel nicht lesbar ($($_.Exception.Message))." }
    if (-not "$($U.HashAfter)" -or (Get-HUErHash $now) -ne "$($U.HashAfter)") { throw "'$($U.Name)' wurde nach dem Uebertragen geaendert - nicht automatisch zurueckgesetzt." }
    $plan = Get-HUEntraRestorePlan -TenantKey $tk -Settings $Settings -Typ "$($U.Typ)" -Id "$($U.EntraId)" -Name "$($U.Name)" -Backup $U.Before
    if ($plan.Blocks.Count) { throw "Zuruecksetzen gesperrt: $($plan.Blocks -join ' ')" }
    if ($CheckOnly) { return [pscustomobject]@{ Deleted = $false; Text = 'Zuruecksetzen moeglich' } }
    if (-not $plan.Changes.Count) { Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.erledigt.json') -Force; return [pscustomobject]@{ Deleted = $false; Text = 'Schon auf dem gesicherten Stand - nichts zu tun.' } }
    $r = Invoke-HUEntraRestore -Plan $plan -Settings $Settings -Actor "$env:USERNAME (Rueckgaengig Uebertragen)"
    Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.rueckgaengig.json') -Force
    return [pscustomobject]@{ Deleted = $false; Text = "'$($U.Name)' auf den Stand vor dem Uebertragen zurueckgesetzt$(if (-not $r.Ok) { ' - ACHTUNG Nachpruefung: ' + (@($r.Mismatch) -join '; ') })." }
}

Export-ModuleMember -Function Get-HUEntraRestoreKind, Get-HUEntraRestorePlan, Invoke-HUEntraRestore, Test-HUEntraBreakGlass, Format-HUErValue, Test-HUErEqual, Get-HUErPathValue, Get-HUEntraTransferPlan, Invoke-HUEntraTransfer, Undo-HUEntraTransfer
