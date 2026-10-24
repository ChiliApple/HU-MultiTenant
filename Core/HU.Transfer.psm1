#Requires -Version 5.1
<#
.SYNOPSIS
    Uebertragen A (2.4.1): ein Intune-Objekt aus einer Quelle (Tenant oder Mustertenant) in einem anderen Tenant NEU anlegen -
    mit Vorschau, Pruefungen, Zuordnung der Bereichsmarkierungen, Nachpruefung und Rueckgaengig.
.DESCRIPTION
    Regeln aus Konzept 045 (Ue-1 bis Ue-14), soweit sie fuer das Neuanlegen gelten:
    - Quelle nur lesen; je Ziel ein eigener Plan (Get-HUTransferPlan) und ein eigenes Ergebnis (Invoke-HUTransfer).
    - Gibt es im Ziel schon ein Objekt gleichen Namens (Gross/klein und Leerzeichen am Rand egal): Sperre (Angleichen = 2.4.2).
    - Geheimnisse (verschluesselte Werte, Kennwoerter, Pre-Shared-Keys) und Profile mit Zertifikats-/Geheimnis-Verweisen
      (WLAN, VPN, kabelgebunden, SCEP, PKCS): Sperre.
    - Bereichsmarkierungen ueber den Namen, eindeutig - sonst Sperre. Standard-Markierung '0' bleibt '0'.
    - Ohne Zuweisungen (wie das bisherige Kopieren). Zuweisungen uebertragen folgt erst nach dem Test-Tenant.
    - Unmittelbar vor dem Schreiben erneut pruefen, ob der Name im Ziel inzwischen existiert.
    - Administrative Vorlage unvollstaendig: das angelegte Objekt wird sofort wieder geloescht.
    - Nach dem Anlegen nachlesen und je Einstellung mit der Quelle vergleichen.
    - Rueckgaengig-Datei je Ziel unter Backups\<Ziel>\_vor-uebertragen; Rueckgaengig = loeschen, nur wenn das Objekt
      seitdem unveraendert ist (Fingerabdruck).
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Braucht HU.Intune.
#>

# Profile mit Verweisen auf Zertifikatsprofile oder Geheimnisse - nicht uebertragbar (045 Ue-5/Ue-6)
# 045 B3: immer sperren, auch wenn GET keinen Schluessel zeigt (WLAN-Schluessel kommen oft gar nicht mit)
$script:HUTrRefTypes = '(?i)(wifi|wi-fi|vpn|wired|scep|pkcs|derivedcredential|certificate|trustedroot)'
# Eigenschaftsnamen mit geheimem Inhalt (047 B3: enthaelt, nicht nur genau) - Textwerte; Einstellungen ueber Kennwort-REGELN
# (passwordRequiredType, passwordMinimumLength ...) sind keine Geheimnisse und werden ueber $script:HUTrSecretNotNames ausgenommen
$script:HUTrSecretNames = '(?i)(password|secret|presharedkey|passphrase|networkkey|sharedkey|psk)'
$script:HUTrSecretNotNames = '(?i)(type|required|length|days|count|minutes|expir|history|complex|mode|policy|prompt|block|allowed|enabled|sign|reuse|character|minimum|maximum|attempt|change|sync)'
# 047 B1: GUIDs im Objekt sind Verweise auf Objekte des Quell-Tenants - ausser in diesen Feldern (Microsoft-Kennungen, eigene ID,
# Teile, die New-HUIntuneObject neu baut oder nicht sendet)
$script:HUTrIdOkNames = @('settingDefinitionId', 'templateId', 'settingInstanceTemplateId', 'settingValueTemplateId', 'templateReference', 'settingInstanceTemplateReference', 'settingValueTemplateReference', 'templateFamily', '@odata.type', '@odata.context', 'assignments', 'scheduledActionsForRule', 'roleScopeTagIds', 'definition@odata.bind', 'presentation@odata.bind')
# 047 B6: eigene 'id' nur auf oberster Ebene und bei Einstellungen/Werten von Vorlagen, nicht in jeder Tiefe
$script:HUTrIdOkPath = '^(|(settings|definitionValues|presentationValues)\[\d+\]|definitionValues\[\d+\]\.presentationValues\[\d+\])$'
$script:HUTrGuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# 2.4.2 Uebertragen B (045/F3-F4): nur Arten mit dokumentiertem PATCH; Einstellungskatalog und Administrative Vorlage nicht
$script:HUTrAlignCopy = @('generic', 'compliance')

# GUIDs ausserhalb der erlaubten Felder suchen -> Fundstellen (Pfad = Wert)
function Find-HUTrForeignIds($Obj, [string]$Path = '') {
    $hits = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Obj) { return $hits.ToArray() }
    if ($Obj -is [string] -or $Obj -is [ValueType]) {
        if ("$Obj" -match $script:HUTrGuidRx) { $hits.Add("$(if ($Path) { $Path } else { '(Wert)' }) = $($Matches[0])") }
        return $hits.ToArray()
    }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Collections.IDictionary])) {
        $i = 0; foreach ($e in $Obj) { foreach ($h in (Find-HUTrForeignIds $e "$Path[$i]")) { $hits.Add($h) }; $i++ }
        return $hits.ToArray()
    }
    $props = if ($Obj -is [System.Collections.IDictionary]) { @($Obj.Keys | ForEach-Object { [pscustomobject]@{ Name = "$_"; Value = $Obj[$_] } }) } else { @($Obj.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }) }
    foreach ($p in $props) {
        if ($script:HUTrIdOkNames -contains $p.Name) { continue }
        if ($p.Name -like '*@odata.*') { continue }   # Graph-Metadaten (settings@odata.context ...) - werden nie mitgeschickt
        if ($p.Name -eq 'id' -and $Path -match $script:HUTrIdOkPath) { continue }
        foreach ($h in (Find-HUTrForeignIds $p.Value $(if ($Path) { "$Path.$($p.Name)" } else { $p.Name }))) { $hits.Add($h) }
    }
    return $hits.ToArray()
}

# 045 F2: Gross/klein und Leerzeichen am Rand egal, Zeichen in der Mitte bleiben
function ConvertTo-HUTrName([string]$N) { return ("$N".Trim()).ToLowerInvariant() }

function Get-HUTrProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null
}

# Geheimnisse im Objekt suchen -> Liste von Fundstellen (leer = keine)
function Find-HUTrSecrets($Obj, [string]$Path = '') {
    $hits = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Obj -or $Obj -is [string] -or $Obj -is [ValueType]) { return $hits.ToArray() }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Collections.IDictionary])) {
        $i = 0; foreach ($e in $Obj) { foreach ($h in (Find-HUTrSecrets $e "$Path[$i]")) { $hits.Add($h) }; $i++ }
        return $hits.ToArray()
    }
    $props = if ($Obj -is [System.Collections.IDictionary]) { @($Obj.Keys | ForEach-Object { [pscustomobject]@{ Name = "$_"; Value = $Obj[$_] } }) } else { @($Obj.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }) }
    $type = "$(Get-HUTrProp $Obj '@odata.type')"
    # Einstellungskatalog: geheimer Wert (valueState encryptedValueToken/notEncrypted)
    if ($type -like '*SecretSettingValue') { $hits.Add("$Path (geheimer Einstellungswert)") }
    # OMA-URI: verschluesselter Wert
    if ([bool](Get-HUTrProp $Obj 'isEncrypted') -or "$(Get-HUTrProp $Obj 'secretReferenceValueId')") { $hits.Add("$Path (verschluesselter OMA-URI-Wert)") }
    foreach ($p in $props) {
        if ($p.Name -match $script:HUTrSecretNames -and $p.Name -notmatch $script:HUTrSecretNotNames -and $p.Value -is [string] -and "$($p.Value)" -ne '') { $hits.Add("$(if ($Path) { "$Path." })$($p.Name)") }
        elseif ($p.Name -match '(?i)IsSet$' -and $p.Value -eq $true) { $hits.Add("$(if ($Path) { "$Path." })$($p.Name)") }
        elseif ($null -ne $p.Value -and -not ($p.Value -is [string]) -and -not ($p.Value -is [ValueType])) {
            foreach ($h in (Find-HUTrSecrets $p.Value $(if ($Path) { "$Path.$($p.Name)" } else { $p.Name }))) { $hits.Add($h) }
        }
    }
    return $hits.ToArray()
}

function Get-HUTrSource([string]$Typ) { return (Get-HUCompareSources | Where-Object { $_.Typ -eq $Typ } | Select-Object -First 1) }

# Namen der vorhandenen Objekte dieser Art im Ziel (normalisiert)
function Get-HUTrTargetNames([string]$TenantKey, $Settings, $Src) {
    $base = ($Src.Ep -replace '\?.*$', '')
    $items = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $base)
    return @($items | Where-Object { -not ($Src.Typ -eq 'Wartung' -and $_.isGlobalScript) } | ForEach-Object { ConvertTo-HUTrName "$($_.($Src.Name))" })
}

# Plan je Ziel: liest im Ziel, prueft, schreibt nichts
function Get-HUTransferPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)]$SourceObj,
        [Parameter(Mandatory)][string]$SourceKey, [string]$ResolveKey = '', [string]$SourceLabel = '',
        [Parameter(Mandatory)][string]$TargetKey, [hashtable]$SourceTagNames = @{}
    )
    if (-not $ResolveKey) { $ResolveKey = $SourceKey }
    $src = Get-HUTrSource $Typ
    $nameProp = if ($src) { $src.Name } else { 'displayName' }
    $name = "$(Get-HUTrProp $SourceObj $nameProp)"
    $plan = [pscustomobject]@{
        Kind = 'transferNew'; Typ = $Typ; Name = $name; NewName = $name; TenantKey = $TargetKey; SourceKey = $SourceKey; SourceLabel = $(if ($SourceLabel) { $SourceLabel } else { $SourceKey })
        Method = 'POST'; Endpoint = $(if ($src) { $src.Ep -replace '\?.*$', '' } else { '' }); Perm = 'DeviceManagementConfiguration.ReadWrite.All'
        Body = $null; SourceObj = $SourceObj; ScopeTagIds = @('0')
        Changes = New-Object System.Collections.Generic.List[object]; Dropped = New-Object System.Collections.Generic.List[string]
        Blocks = New-Object System.Collections.Generic.List[string]; Warnings = New-Object System.Collections.Generic.List[string]
        Confirms = New-Object System.Collections.Generic.List[string]; Notes = New-Object System.Collections.Generic.List[string]
        BreakGlass = $null; LiveHash = ''; Live = $null
    }
    if ($SourceKey -eq $TargetKey) { $plan.Blocks.Add('Quelle und Ziel sind derselbe Tenant - dafuer gibt es Zurueckschreiben.'); return $plan }
    if (-not $src -or -not $src.Copy) { $plan.Blocks.Add("$Typ laesst sich (noch) nicht uebertragen."); return $plan }
    if (-not $name) { $plan.Blocks.Add('Die Quelle hat keinen Namen.'); return $plan }
    # Name im Ziel schon vorhanden -> nicht neu anlegen (Angleichen kommt mit 2.4.2)
    try {
        if ((Get-HUTrTargetNames $TargetKey $Settings $src) -contains (ConvertTo-HUTrName $name)) { $plan.Blocks.Add("'$name' gibt es im Ziel schon (Angleichen bestehender Objekte kommt mit 2.4.2).") }
    } catch { $plan.Blocks.Add("Bestand im Ziel nicht lesbar ($($_.Exception.Message)).") }
    # Geheimnisse und Verweise
    foreach ($h in @(Find-HUTrSecrets $SourceObj | Select-Object -First 5)) { $plan.Blocks.Add("Geheimer Wert ($h) - Geheimnisse werden nie uebertragen, das Objekt bitte im Ziel selbst anlegen.") }
    # Verweise auf Objekte des Quell-Tenants (GUIDs) wuerden als tote IDs im Ziel landen (047 B1)
    $fids = @(Find-HUTrForeignIds $SourceObj)
    foreach ($h in @($fids | Select-Object -First 5)) { $plan.Blocks.Add("Verweis auf ein Objekt des Quell-Tenants ($h) - im Ziel ungueltig, nicht uebertragbar.") }
    if ($fids.Count -gt 5) { $plan.Blocks.Add("... und $($fids.Count - 5) weitere Verweise.") }
    $ot = "$(Get-HUTrProp $SourceObj '@odata.type')"
    if ($ot -match $script:HUTrRefTypes) { $plan.Blocks.Add("Profiltyp $($ot -replace '^#microsoft\.graph\.', '') verweist auf Zertifikate oder Geheimnisse des Quell-Tenants - nicht uebertragbar.") }
    # Bereichsmarkierungen ueber den Namen
    $tags = @(@(Get-HUTrProp $SourceObj 'roleScopeTagIds') | Where-Object { "$_" -and "$_" -ne '0' })
    if ($tags.Count) {
        $tl = $null
        try { $tl = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint '/deviceManagement/roleScopeTags?$select=id,displayName') } catch { $plan.Blocks.Add("Bereichsmarkierungen im Ziel nicht lesbar ($($_.Exception.Message)).") }
        $ids = New-Object System.Collections.Generic.List[string]
        if ($null -ne $tl) {
            foreach ($t in $tags) {
                $tn = "$($SourceTagNames["$t"])"
                if (-not $tn) { try { $tn = "$((Invoke-HUIntuneGraph -TenantKey $ResolveKey -Settings $Settings -Endpoint "/deviceManagement/roleScopeTags/$t" -NoRetry).displayName)" } catch { $tn = '' } }
                if (-not $tn) { $plan.Blocks.Add("Bereichsmarkierung $($t): Name in der Quelle unbekannt."); continue }
                $hit = @($tl | Where-Object { (ConvertTo-HUTrName "$($_.displayName)") -eq (ConvertTo-HUTrName $tn) })
                if ($hit.Count -eq 1) { $ids.Add("$($hit[0].id)") } else { $plan.Blocks.Add("Bereichsmarkierung '$tn' gibt es im Ziel $(if ($hit.Count) { "$($hit.Count)-mal" } else { 'nicht' }).") }
            }
        }
        if (@(@(Get-HUTrProp $SourceObj 'roleScopeTagIds') | Where-Object { "$_" -eq '0' }).Count) { $ids.Insert(0, '0') }
        if ($ids.Count) { $plan.ScopeTagIds = @($ids) }
    }
    # Art-spezifische Hinweise
    switch ($Typ) {
        'Compliance' {
            $acts = @(@(Get-HUTrProp $SourceObj 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object { @(Get-HUTrProp $_ 'scheduledActionConfigurations') } | Where-Object { $_ })
            $n = @($acts | Where-Object { "$(Get-HUTrProp $_ 'actionType')" -in 'notification', 'pushNotification' }).Count
            $nb = @($acts | Where-Object { "$(Get-HUTrProp $_ 'actionType')" -eq 'block' }).Count
            # 045 B5: genau eine block-Aktion muss uebrig bleiben; weggelassene Benachrichtigung bewusst bestaetigen
            if ($nb -ne 1) { $plan.Blocks.Add("Die Quelle hat $nb Aktion(en) 'Als nicht konform markieren' - genau eine ist noetig.") }
            if ($n) {
                $plan.Dropped.Add("$n Benachrichtigungs-Aktion(en) (Vorlagen gibt es je Tenant)")
                $plan.Confirms.Add("$n Benachrichtigung(en) an Benutzer werden NICHT uebernommen: Geraete werden als nicht konform markiert, ohne dass jemand eine Nachricht bekommt. Im Ziel im Portal ergaenzen.")
            }
        }
        'Administrative Vorlage' { $plan.Notes.Add('Wird in zwei Schritten angelegt (Vorlage, dann Werte). Scheitert ein Wert, wird die Vorlage im Ziel sofort wieder geloescht.') }
        'Einstellungskatalog' { if ("$(Get-HUTrProp (Get-HUTrProp $SourceObj 'templateReference') 'templateId')") { $plan.Notes.Add('Endpunktsicherheits-Vorlage: muss im Ziel verfuegbar sein, sonst lehnt Intune ab.') } }
    }
    $plan.Notes.Add('Wird NEU angelegt, ohne Zuweisungen - wirkt also noch auf kein Geraet. Rueckgaengig (loeschen) geht, solange es im Ziel unveraendert ist.')
    # Vorschau: alle Einstellungen der Quelle (IDs in der Quelle zu Namen)
    $map = ConvertTo-HUFlatMap $SourceObj -Full
    try { $map = Resolve-HUFlatMapIds -TenantKey $ResolveKey -Settings $Settings -Map $map } catch { }
    $plan.Changes.Add([pscustomobject]@{ Feld = $nameProp; Jetzt = '(fehlt)'; Danach = $name; Expected = $name; JetztVoll = '(fehlt)'; DanachVoll = $name; Anzahl = ''; Gekuerzt = $false })
    foreach ($k in @($map.Keys | Sort-Object)) {
        $v = "$($map[$k])"
        $plan.Changes.Add([pscustomobject]@{ Feld = $k; Jetzt = '(fehlt)'; Danach = $(if ($v.Length -gt 300) { $v.Substring(0, 300) + ' ...' } else { $v }); Expected = $v; JetztVoll = '(fehlt)'; DanachVoll = $v; Anzahl = ''; Gekuerzt = ($v.Length -gt 300) })
    }
    if ($plan.ScopeTagIds.Count -gt 1 -or $plan.ScopeTagIds[0] -ne '0') { $plan.Notes.Add("Bereichsmarkierungen im Ziel: $($plan.ScopeTagIds -join ', ')") }
    return $plan
}

# Compliance: Aktionen der Quelle fuer das Ziel aufbereiten (Benachrichtigungen weglassen, Vorlagen gibt es je Tenant)
function Get-HUTrComplianceRuleName($Obj) {
    $r = @(@(Get-HUTrProp $Obj 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object { "$(Get-HUTrProp $_ 'ruleName')" } | Where-Object { $_ }) | Select-Object -First 1
    if ($r) { return "$r" }; return 'PasswordRequired'
}

# Aktionen kurz und vergleichbar (Art:Kulanzstunden, sortiert) - fuer Vorschau und Vergleich beim Angleichen (050 B8)
function Get-HUTrComplianceActionText($Obj) {
    $a = @(@(Get-HUTrProp $Obj 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object { @(Get-HUTrProp $_ 'scheduledActionConfigurations') } | Where-Object { $_ } |
            ForEach-Object { "$(Get-HUTrProp $_ 'actionType'):$([int](Get-HUTrProp $_ 'gracePeriodHours'))h" } | Sort-Object)
    return ($a -join ', ')
}

function Get-HUTrComplianceActions($Obj) {
    $acts = @(@(Get-HUTrProp $Obj 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object { @(Get-HUTrProp $_ 'scheduledActionConfigurations') } | Where-Object { $_ } | ForEach-Object {
            @{ actionType = "$(Get-HUTrProp $_ 'actionType')"; gracePeriodHours = [int](Get-HUTrProp $_ 'gracePeriodHours'); notificationTemplateId = ''; notificationMessageCCList = @() } })
    $acts = @($acts | Where-Object { $_.actionType -ne 'notification' -and $_.actionType -ne 'pushNotification' })
    if (-not $acts.Count) { $acts = @(@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = ''; notificationMessageCCList = @() }) }
    return ,$acts
}

# Angleichen-Body (045 F3, volles Objekt): Quell-Stand plus null fuer Felder, die nur das Ziel gesetzt hat -
# so wird das Ziel wirklich gleich der Quelle (nichts bleibt still stehen)
# 050 B7: auch in Unterobjekten; Listen mit [] statt null leeren. 050 B12: ...IsSet-Felder sind schreibgeschuetzt - nie senden.
function Add-HUTrAlignNulls($Body, $Tgt) {
    if (-not ($Body -is [System.Collections.IDictionary]) -or -not ($Tgt -is [System.Collections.IDictionary])) { return }
    foreach ($k in @($Tgt.Keys)) {
        $tv = $Tgt[$k]
        if (-not $Body.Contains("$k")) {
            $Body["$k"] = if ($tv -is [System.Collections.IEnumerable] -and -not ($tv -is [string]) -and -not ($tv -is [System.Collections.IDictionary])) { , @() } else { $null }
        } elseif ($Body["$k"] -is [System.Collections.IDictionary] -and $tv -is [System.Collections.IDictionary]) { Add-HUTrAlignNulls $Body["$k"] $tv }
    }
}
function Remove-HUTrIsSet($H) {
    if ($H -is [System.Collections.IDictionary]) {
        foreach ($k in @($H.Keys)) { if ("$k" -match '(?i)IsSet$') { $H.Remove($k) } else { Remove-HUTrIsSet $H[$k] } }
    } elseif ($H -is [System.Collections.IEnumerable] -and -not ($H -is [string])) { foreach ($e in $H) { Remove-HUTrIsSet $e } }
}
function Get-HUTrAlignBody($SourceObj, $TargetObj) {
    $body = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $SourceObj)
    $tgt = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $TargetObj)
    Add-HUTrAlignNulls $body $tgt
    Remove-HUTrIsSet $body
    return $body
}

# Plan fuer das Angleichen (2.4.2, 045 Ue-8/F3): bestehendes Objekt gleichen Namens im Ziel per PATCH auf den Quell-Stand bringen.
# Liest das Ziel-Objekt, schreibt nichts. Felder, die nur im Ziel einen Wert haben, werden geleert (volles Objekt) und gezeigt.
function Get-HUTransferAlignPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)]$SourceObj,
        [Parameter(Mandatory)][string]$SourceKey, [string]$ResolveKey = '', [string]$SourceLabel = '',
        [Parameter(Mandatory)][string]$TargetKey, [Parameter(Mandatory)][string]$TargetId
    )
    if (-not $ResolveKey) { $ResolveKey = $SourceKey }
    $src = Get-HUTrSource $Typ
    $nameProp = if ($src) { $src.Name } else { 'displayName' }
    $name = "$(Get-HUTrProp $SourceObj $nameProp)"
    $plan = [pscustomobject]@{
        Kind = 'transferAlign'; Typ = $Typ; Name = $name; NewName = $name; TenantKey = $TargetKey; SourceKey = $SourceKey; SourceLabel = $(if ($SourceLabel) { $SourceLabel } else { $SourceKey })
        Method = 'PATCH'; Endpoint = $(if ($src) { $src.Ep -replace '\?.*$', '' } else { '' }); Perm = 'DeviceManagementConfiguration.ReadWrite.All'
        TargetId = $TargetId; Body = $null; SourceObj = $SourceObj; ScopeTagIds = @()
        Changes = New-Object System.Collections.Generic.List[object]; Dropped = New-Object System.Collections.Generic.List[string]
        Blocks = New-Object System.Collections.Generic.List[string]; Warnings = New-Object System.Collections.Generic.List[string]
        Confirms = New-Object System.Collections.Generic.List[string]; Notes = New-Object System.Collections.Generic.List[string]
        BreakGlass = $null; LiveHash = ''; Live = $null
    }
    if ($SourceKey -eq $TargetKey) { $plan.Blocks.Add('Quelle und Ziel sind derselbe Tenant - dafuer gibt es Zurueckschreiben.'); return $plan }
    if (-not $src -or -not $src.Copy) { $plan.Blocks.Add("$Typ laesst sich (noch) nicht uebertragen."); return $plan }
    if (-not $name) { $plan.Blocks.Add('Die Quelle hat keinen Namen.'); return $plan }
    if ($src.Copy -eq 'admx') { $plan.Blocks.Add('Administrative Vorlagen werden (noch) nicht angeglichen - die Bindung der Werte (updateDefinitionValues) ist erst im Test-Tenant zu klaeren.'); return $plan }
    if ($src.Copy -notin $script:HUTrAlignCopy) { $plan.Blocks.Add("$Typ wird (noch) nicht angeglichen."); return $plan }
    # Geheimnisse und Verweise wie beim Neu-Anlegen
    foreach ($h in @(Find-HUTrSecrets $SourceObj | Select-Object -First 5)) { $plan.Blocks.Add("Geheimer Wert ($h) - Geheimnisse werden nie uebertragen, das Objekt bitte im Ziel selbst pflegen.") }
    $fids = @(Find-HUTrForeignIds $SourceObj)
    foreach ($h in @($fids | Select-Object -First 5)) { $plan.Blocks.Add("Verweis auf ein Objekt des Quell-Tenants ($h) - im Ziel ungueltig, nicht uebertragbar.") }
    if ($fids.Count -gt 5) { $plan.Blocks.Add("... und $($fids.Count - 5) weitere Verweise.") }
    $ot = "$(Get-HUTrProp $SourceObj '@odata.type')"
    if ($ot -match $script:HUTrRefTypes) { $plan.Blocks.Add("Profiltyp $($ot -replace '^#microsoft\.graph\.', '') verweist auf Zertifikate oder Geheimnisse des Quell-Tenants - nicht uebertragbar.") }
    # Ziel-Objekt lesen
    $tgt = $null
    try { $tgt = Get-HUCompareObject -TenantKey $TargetKey -Settings $Settings -Typ $Typ -Id $TargetId }
    catch { $plan.Blocks.Add("Ziel-Objekt nicht lesbar ($($_.Exception.Message))."); return $plan }
    if ((ConvertTo-HUTrName "$(Get-HUTrProp $tgt $nameProp)") -ne (ConvertTo-HUTrName $name)) { $plan.Blocks.Add('Das Ziel-Objekt heisst inzwischen anders - bitte neu vergleichen.'); return $plan }
    # 050 B2: Geheimnisse im ZIEL wuerden ueberschrieben - Rueckgaengig kann sie nicht wiederherstellen
    foreach ($h in @(Find-HUTrSecrets $tgt | Select-Object -First 5)) { $plan.Blocks.Add("Geheimer Wert im Ziel ($h) - wuerde beim Angleichen ueberschrieben und laesst sich nicht wiederherstellen. Bitte im Portal angleichen.") }
    $tot = "$(Get-HUTrProp $tgt '@odata.type')"
    if ($ot -and $tot -and $ot -ne $tot) { $plan.Blocks.Add("Profiltyp verschieden: Quelle $($ot -replace '^#microsoft\.graph\.', ''), Ziel $($tot -replace '^#microsoft\.graph\.', '') - nicht angleichbar.") }
    if ($src.Copy -eq 'compliance') {
        $acts = @(@(Get-HUTrProp $SourceObj 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object { @(Get-HUTrProp $_ 'scheduledActionConfigurations') } | Where-Object { $_ })
        $n = @($acts | Where-Object { "$(Get-HUTrProp $_ 'actionType')" -in 'notification', 'pushNotification' }).Count
        $nb = @($acts | Where-Object { "$(Get-HUTrProp $_ 'actionType')" -eq 'block' }).Count
        if ($nb -ne 1) { $plan.Blocks.Add("Die Quelle hat $nb Aktion(en) 'Als nicht konform markieren' - genau eine ist noetig.") }
        if ($n) {
            $plan.Dropped.Add("$n Benachrichtigungs-Aktion(en) (Vorlagen gibt es je Tenant)")
            $plan.Confirms.Add("Die Aktionen im Ziel werden ersetzt - OHNE Benachrichtigungen: Geraete werden als nicht konform markiert, ohne dass jemand eine Nachricht bekommt. Im Ziel im Portal ergaenzen.")
        } else { $plan.Confirms.Add('Die Aktionen im Ziel werden durch die der Quelle ersetzt (bestehende Benachrichtigungen im Ziel fallen weg).') }
        # 050 B8: Aktionen stehen nicht im Feldvergleich - eigene Zeile, damit auch reine Aktions-Unterschiede sichtbar sind
        $sa = Get-HUTrComplianceActionText $SourceObj; $ta = Get-HUTrComplianceActionText $tgt
        $saNew = (@(Get-HUTrComplianceActions $SourceObj | ForEach-Object { "$($_.actionType):$($_.gracePeriodHours)h" } | Sort-Object) -join ', ')
        if ($saNew -ne $ta) { $plan.Changes.Add([pscustomobject]@{ Feld = 'Aktionen (nicht konform)'; Jetzt = $(if ($ta) { $ta } else { '(keine)' }); Danach = $saNew; Expected = $saNew; JetztVoll = $ta; DanachVoll = "$saNew (Quelle: $sa)"; Anzahl = ''; Gekuerzt = $false }) }
    }
    $plan.Live = $tgt
    $plan.LiveHash = Get-HUCompareHashNeutral $tgt
    # Vorschau: nur Unterschiede; Felder, die nur im Ziel einen Wert haben, bleiben und werden gezeigt (045 F3)
    $ms = ConvertTo-HUFlatMap $SourceObj -Full
    try { $ms = Resolve-HUFlatMapIds -TenantKey $ResolveKey -Settings $Settings -Map $ms } catch { }
    $mt = ConvertTo-HUFlatMap $tgt -Full
    try { $mt = Resolve-HUFlatMapIds -TenantKey $TargetKey -Settings $Settings -Map $mt } catch { }
    $keys = @(@($ms.Keys) + @($mt.Keys) | Sort-Object -Unique)
    $same = 0
    foreach ($k in $keys) {
        $sv = if ($ms.ContainsKey($k)) { "$($ms[$k])" } else { $null }
        $tv = if ($mt.ContainsKey($k)) { "$($mt[$k])" } else { $null }
        if ($null -ne $sv -and $sv -eq $tv) { $same++; continue }
        if ($null -eq $sv) {
            # Nur im Ziel gesetzt: wird beim Angleichen entfernt bzw. geleert (045 F3, volles Objekt) - sichtbar, nie still
            $top = ($k -split '[\.\[]')[0]
            $sent = [bool]@($ms.Keys | Where-Object { ($_ -split '[\.\[]')[0] -eq $top }).Count
            $lbl = if ($sent) { '(wird entfernt - die Quelle hat diesen Eintrag nicht)' } else { '(wird geleert - die Quelle hat hier keinen Wert)' }
            $plan.Changes.Add([pscustomobject]@{ Feld = $k; Jetzt = $(if ($tv.Length -gt 300) { $tv.Substring(0, 300) + ' ...' } else { $tv }); Danach = $lbl; Expected = $null; JetztVoll = $tv; DanachVoll = $lbl; Anzahl = ''; Gekuerzt = ($tv.Length -gt 300) })
            continue
        }
        $jetzt = if ($null -eq $tv) { '(fehlt)' } else { $tv }
        $plan.Changes.Add([pscustomobject]@{ Feld = $k; Jetzt = $(if ($jetzt.Length -gt 300) { $jetzt.Substring(0, 300) + ' ...' } else { $jetzt }); Danach = $(if ($sv.Length -gt 300) { $sv.Substring(0, 300) + ' ...' } else { $sv }); Expected = $sv; JetztVoll = $jetzt; DanachVoll = $sv; Anzahl = ''; Gekuerzt = ($sv.Length -gt 300 -or $jetzt.Length -gt 300) })
    }
    if (-not $plan.Changes.Count -and -not $plan.Blocks.Count) { $plan.Blocks.Add('Feld fuer Feld keine Unterschiede zur Quelle - nichts anzugleichen (nur Reihenfolge oder Kennungen verschieden).') }
    if ($same) { $plan.Notes.Add("$same Feld(er) sind schon gleich und werden nicht gezeigt.") }
    $plan.Notes.Add('Zuweisungen und Bereichsmarkierungen des Ziels bleiben unveraendert.')
    $plan.Notes.Add('Vor dem Schreiben wird das Ziel erneut gelesen (geaendert seit der Vorschau = Abbruch) und der Ziel-Stand als Rueckgaengig-Datei gesichert.')
    return $plan
}

# Angleichen schreiben (nach Bestaetigung): erneut lesen, sichern, PATCH mit vollem Quell-Objekt, nachlesen und pruefen
function Invoke-HUTransferAlign {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings, [string]$Actor = "$env:USERNAME", [datetime]$Now = (Get-Date))
    if ($Plan.Blocks.Count) { throw "Nicht angeglichen: $($Plan.Blocks -join ' ')" }
    $tk = $Plan.TenantKey
    $src = Get-HUTrSource $Plan.Typ
    $ep = "$($Plan.Endpoint)/$($Plan.TargetId)"
    # Ue-8: unmittelbar vor dem Schreiben erneut lesen und mit dem Vorschau-Stand vergleichen
    $cur = $null
    try { $cur = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ $Plan.Typ -Id $Plan.TargetId }
    catch { throw "Ziel-Objekt nicht mehr lesbar ($($_.Exception.Message)) - nichts geschrieben." }
    if ((Get-HUCompareHashNeutral $cur) -ne "$($Plan.LiveHash)") { throw "'$($Plan.Name)' wurde im Ziel seit der Vorschau geaendert - nichts geschrieben. Bitte neu vergleichen." }
    # Ziel-Stand sichern (Rueckgaengig)
    $dir = Get-HUTrUndoDir $Settings $tk
    $file = Join-Path $dir ("$($Now.ToString('yyyy-MM-dd_HHmmss'))_geaendert_$(ConvertTo-HUSafeFileName $Plan.Name 40).json")
    Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'changed'; Tenant = $tk; Typ = $Plan.Typ; Name = $Plan.Name; Id = "$($Plan.TargetId)"; Endpoint = $ep; HashBefore = "$($Plan.LiveHash)"; HashAfter = ''; Before = $cur; Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
    # PATCH mit vollem Quell-Objekt (045 F3); id/Zeiten/Zuweisungen/Bereichsmarkierungen/Aktionen entfernt ConvertTo-HUCleanObject
    $body = Get-HUTrAlignBody $Plan.SourceObj $cur
    $patched = $false
    try {
        [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint $ep -Method PATCH -Body $body)
        $patched = $true
        if ($src.Copy -eq 'compliance') {
            $acts = Get-HUTrComplianceActions $Plan.SourceObj
            [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "$ep/scheduleActionsForRules" -Method POST -Body @{ deviceComplianceScheduledActionForRules = @(@{ ruleName = (Get-HUTrComplianceRuleName $Plan.SourceObj); scheduledActionConfigurations = @($acts) }) })
        }
    } catch {
        $err = $_
        # 050 B9: PATCH selbst gescheitert = nichts geaendert -> Rueckgaengig-Datei wieder weg
        if (-not $patched) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if (Test-HUGraphForbidden $err) { throw "Schreibrecht fehlt: $($Plan.Perm). Nichts veraendert." }
            throw "Angleichen abgelehnt ($($err.Exception.Message)) - im Ziel wurde nichts veraendert."
        }
        # halb angeglichen: Fingerabdruck nachlesen, damit Rueckgaengig moeglich bleibt
        $ha = ''
        try { $ha = Get-HUCompareHashNeutral (Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ $Plan.Typ -Id $Plan.TargetId) } catch { }
        try { Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'changed'; Tenant = $tk; Typ = $Plan.Typ; Name = $Plan.Name; Id = "$($Plan.TargetId)"; Endpoint = $ep; HashBefore = "$($Plan.LiveHash)"; HashAfter = $ha; Before = $cur; Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor }) } catch { }
        Write-HULog -Message "Angleichen $($Plan.Typ) '$($Plan.Name)': Einstellungen geschrieben, Aktionen NICHT ($($err.Exception.Message))" -Level 'ERROR' -Tenant $tk
        throw "HALB angeglichen: Einstellungen geschrieben, Aktionen nicht ($($err.Exception.Message)). Rueckgaengig ist moeglich (Tenant-Vergleich > Rueckgaengig ...)$(if (-not $ha) { ' - Nachlesen gescheitert, bitte im Portal pruefen' })."
    }
    Write-HULog -Message "Angleichen: $($Plan.Typ) '$($Plan.Name)' in $tk an $($Plan.SourceLabel) angeglichen (Id $($Plan.TargetId), durch $Actor)" -Level 'OK' -Tenant $tk
    # Nachpruefung: jede Einstellung der Quelle muss im Ziel angekommen sein
    $mismatch = New-Object System.Collections.Generic.List[string]
    $hash = ''
    try {
        $after = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ $Plan.Typ -Id $Plan.TargetId
        $hash = Get-HUCompareHashNeutral $after
        $ms = ConvertTo-HUFlatMap $Plan.SourceObj; $ma = ConvertTo-HUFlatMap $after
        foreach ($k in @($ms.Keys | Sort-Object)) {
            if ("$($ms[$k])" -match $script:HUTrGuidRx) { continue }
            if (-not $ma.ContainsKey($k)) { $mismatch.Add("$k`: fehlt im Ziel") }
            elseif ("$($ma[$k])" -ne "$($ms[$k])") { $mismatch.Add("$k`: Quelle '$($ms[$k])', Ziel '$($ma[$k])'") }
        }
        # Rueckrichtung: Ziel-eigene Felder muessen geleert sein (045 F3)
        foreach ($k in @($ma.Keys | Sort-Object)) {
            if ($ms.ContainsKey($k) -or "$($ma[$k])" -match $script:HUTrGuidRx) { continue }
            $mismatch.Add("$k`: steht noch im Ziel ('$($ma[$k])'), die Quelle hat hier keinen Wert")
        }
        # Compliance-Aktionen stehen nicht in der flachen Liste (050 B8) - eigens vergleichen
        if ($src.Copy -eq 'compliance') {
            $want = (@(Get-HUTrComplianceActions $Plan.SourceObj | ForEach-Object { "$($_.actionType):$($_.gracePeriodHours)h" } | Sort-Object) -join ', ')
            $got = Get-HUTrComplianceActionText $after
            if ($got -and $got -ne $want) { $mismatch.Add("Aktionen: erwartet '$want', im Ziel '$got'") }
        }
    } catch { $mismatch.Add("Nachlesen nicht moeglich ($($_.Exception.Message))") }
    foreach ($m in @($mismatch | Select-Object -First 20)) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.Name)': $m" -Level 'WARN' -Tenant $tk }
    Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'changed'; Tenant = $tk; Typ = $Plan.Typ; Name = $Plan.Name; Id = "$($Plan.TargetId)"; Endpoint = $ep; HashBefore = "$($Plan.LiveHash)"; HashAfter = $hash; Before = $cur; Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
    return [pscustomobject]@{ Ok = (-not $mismatch.Count); NewId = "$($Plan.TargetId)"; Written = 1; Mismatch = @($mismatch); UndoFile = $file; BackupFile = $file; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

function Get-HUTrUndoDir($Settings, [string]$TenantKey) { return (Join-Path (Join-Path (Get-HUBackupRoot $Settings) (ConvertTo-HUSafeFileName $TenantKey)) '_vor-uebertragen') }

# Schreiben nach Bestaetigung
function Invoke-HUTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings, [string]$Actor = "$env:USERNAME", [datetime]$Now = (Get-Date))
    if ($Plan.Blocks.Count) { throw "Nicht uebertragen: $($Plan.Blocks -join ' ')" }
    $tk = $Plan.TenantKey
    $src = Get-HUTrSource $Plan.Typ
    # zweites Lesen: inzwischen angelegt?
    if ((Get-HUTrTargetNames $tk $Settings $src) -contains (ConvertTo-HUTrName $Plan.NewName)) { throw "'$($Plan.NewName)' gibt es im Ziel inzwischen - nichts angelegt. Bitte neu vergleichen." }
    $newId = ''
    try { $newId = New-HUIntuneObject -TenantKey $tk -Settings $Settings -Typ $Plan.Typ -Obj $Plan.SourceObj -Name $Plan.NewName -ScopeTagIds @($Plan.ScopeTagIds) }
    catch {
        $nid = "$($_.Exception.Data['NewId'])"
        if ($nid) {
            # halb angelegt: sofort wieder entfernen
            $msg = "$($_.Exception.Message)"
            try { [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "$($Plan.Endpoint)/$nid" -Method DELETE -NoRetry); throw "Nicht vollstaendig anlegbar, im Ziel wieder geloescht: $msg" }
            catch { if ("$($_.Exception.Message)" -like 'Nicht vollstaendig anlegbar*') { throw }; throw "$msg - LOESCHEN FEHLGESCHLAGEN, bitte im Portal entfernen (Id $nid)." }
        }
        if (Test-HUGraphForbidden $_) { throw "Schreibrecht fehlt: $($Plan.Perm). Nichts angelegt." }
        throw
    }
    Write-HULog -Message "Uebertragen: $($Plan.Typ) '$($Plan.NewName)' aus $($Plan.SourceLabel) neu angelegt (Id $newId, ohne Zuweisungen, durch $Actor)" -Level 'OK' -Tenant $tk
    # Nachpruefung: angelegtes Objekt lesen, Einstellungen der Quelle muessen gleich sein
    $mismatch = New-Object System.Collections.Generic.List[string]
    $hash = ''
    try {
        $after = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ $Plan.Typ -Id $newId
        $hash = Get-HUCompareHashNeutral $after
        $ms = ConvertTo-HUFlatMap $Plan.SourceObj; $ma = ConvertTo-HUFlatMap $after
        foreach ($k in @($ms.Keys | Sort-Object)) {
            if ("$($ms[$k])" -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') { continue }   # nur noch erlaubte Microsoft-Kennungen (Quell-Verweise sind vorher gesperrt)
            if (-not $ma.ContainsKey($k)) { $mismatch.Add("$k`: fehlt im Ziel") }
            elseif ("$($ma[$k])" -ne "$($ms[$k])") { $mismatch.Add("$k`: Quelle '$($ms[$k])', Ziel '$($ma[$k])'") }
        }
    } catch { $mismatch.Add("Nachlesen nicht moeglich ($($_.Exception.Message))") }
    foreach ($m in @($mismatch | Select-Object -First 20)) { Write-HULog -Message "Nachpruefung $($Plan.Typ) '$($Plan.NewName)': $m" -Level 'WARN' -Tenant $tk }
    # Rueckgaengig-Datei
    $dir = Get-HUTrUndoDir $Settings $tk
    $file = Join-Path $dir ("$($Now.ToString('yyyy-MM-dd_HHmmss'))_neu_$(ConvertTo-HUSafeFileName $Plan.NewName 40).json")
    Write-HUBackupJson $file ([pscustomobject]@{ Kind = 'created'; Tenant = $tk; Typ = $Plan.Typ; Name = $Plan.NewName; Id = $newId; Endpoint = "$($Plan.Endpoint)/$newId"; Hash = $hash; Source = $Plan.SourceLabel; Time = $Now.ToString('s'); By = $Actor })
    return [pscustomobject]@{ Ok = (-not $mismatch.Count); NewId = $newId; Written = 1; Mismatch = @($mismatch); UndoFile = $file; BackupFile = ''; Dropped = @($Plan.Dropped); Notes = @($Plan.Notes) }
}

# Offene Rueckgaengig-Eintraege der angegebenen Tenants (neueste zuerst)
function Get-HUTransferUndoList {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string[]]$Keys)
    $rows = foreach ($k in $Keys) {
        $d = Get-HUTrUndoDir $Settings $k
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Filter '*.json' | Where-Object { $_.Name -match '_(neu|geaendert)_' -and $_.Name -notmatch '\.(rueckgaengig|erledigt)\.json$' })) {
            try { $u = Read-HUBackupJson $f.FullName } catch { continue }
            [pscustomobject]@{ Tenant = "$($u.Tenant)"; Typ = "$($u.Typ)"; Name = "$($u.Name)"; Zeit = "$($u.Time)"; Quelle = "$($u.Source)"; Was = $(if ("$($u.Kind)" -in 'changed', 'entraChanged') { 'angeglichen' } else { 'neu angelegt' }); Datei = $f.FullName }
        }
    }
    return @($rows | Sort-Object Zeit -Descending)
}

# Rueckgaengig: angelegtes Objekt loeschen, wenn es seitdem unveraendert ist
function Undo-HUTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$File, [switch]$Force, [switch]$CheckOnly)
    $u = Read-HUBackupJson $File
    # Entra-Uebertragungen (2.4.4) macht HU.EntraRestore rueckgaengig (dieselben Sperren wie beim Zurueckschreiben)
    if ("$($u.Kind)" -in 'entraChanged', 'entraCreated') { return (Undo-HUEntraTransfer -Settings $Settings -File $File -U $u -CheckOnly:$CheckOnly) }
    if ("$($u.Kind)" -eq 'changed') { return (Undo-HUTransferChange -Settings $Settings -File $File -U $u -Force:$Force -CheckOnly:$CheckOnly) }
    if ("$($u.Kind)" -ne 'created') { throw 'Unbekannte Rueckgaengig-Datei.' }
    $tk = "$($u.Tenant)"
    $cur = $null
    try { $cur = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ "$($u.Typ)" -Id "$($u.Id)" }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 404) { Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.erledigt.json') -Force; return [pscustomobject]@{ Deleted = $false; Text = 'Gibt es im Ziel nicht mehr - nichts zu tun.' } }
        throw
    }
    # 047 B5: ohne Fingerabdruck (Nachlesen war gescheitert) nur mit -Force
    if (-not "$($u.Hash)" -and -not $Force) { throw "Fuer '$($u.Name)' gibt es keinen Fingerabdruck (Nachlesen nach dem Anlegen war gescheitert) - bitte im Portal pruefen und dort loeschen." }
    if ("$($u.Hash)" -and (Get-HUCompareHashNeutral $cur) -ne "$($u.Hash)" -and -not $Force) { throw "'$($u.Name)' wurde nach dem Uebertragen geaendert - nicht automatisch geloescht. Bitte im Portal pruefen." }
    # Zuweisungen zaehlen im Fingerabdruck nicht mit - eigens pruefen: zugewiesen = wirkt auf Geraete, nie automatisch loeschen
    $asg = $null
    try { $asg = @(Get-HUIntuneGraphAll -TenantKey $tk -Settings $Settings -Endpoint "$($u.Endpoint)/assignments") } catch { throw "Zuweisungen von '$($u.Name)' nicht lesbar - nicht geloescht ($($_.Exception.Message))." }
    if ($asg.Count) { throw "'$($u.Name)' ist inzwischen zugewiesen ($($asg.Count)) - nicht automatisch geloescht. Erst die Zuweisungen im Portal entfernen." }
    if ($CheckOnly) { return [pscustomobject]@{ Deleted = $false; Text = 'Loeschen moeglich' } }
    [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "$($u.Endpoint)" -Method DELETE -NoRetry)
    Write-HULog -Message "Rueckgaengig: $($u.Typ) '$($u.Name)' im Ziel geloescht (uebertragen $($u.Time) aus $($u.Source))" -Level 'OK' -Tenant $tk
    Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.rueckgaengig.json') -Force
    return [pscustomobject]@{ Deleted = $true; Text = "'$($u.Name)' geloescht." }
}

# Rueckgaengig nach dem Angleichen: gesicherten Ziel-Stand zurueckschreiben, nur wenn seitdem unveraendert (045 Ue-9)
function Undo-HUTransferChange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)]$U, [switch]$Force, [switch]$CheckOnly)
    $tk = "$($U.Tenant)"
    $cur = $null
    try { $cur = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ "$($U.Typ)" -Id "$($U.Id)" }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 404) { Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.erledigt.json') -Force; return [pscustomobject]@{ Deleted = $false; Text = 'Gibt es im Ziel nicht mehr - nichts zu tun.' } }
        throw
    }
    if (-not "$($U.HashAfter)" -and -not $Force) { throw "Fuer '$($U.Name)' gibt es keinen Fingerabdruck (Nachlesen nach dem Angleichen war gescheitert) - bitte im Portal pruefen." }
    if ("$($U.HashAfter)" -and (Get-HUCompareHashNeutral $cur) -ne "$($U.HashAfter)" -and -not $Force) { throw "'$($U.Name)' wurde nach dem Angleichen geaendert - nicht automatisch zurueckgesetzt. Bitte im Portal pruefen." }
    if ($CheckOnly) { return [pscustomobject]@{ Deleted = $false; Text = 'Zuruecksetzen moeglich' } }
    # gesicherten Stand zurueckschreiben (eigener Tenant: auch Benachrichtigungs-Vorlagen duerfen zurueck);
    # Felder, die erst das Angleichen gesetzt hat, werden wieder geleert
    $body = Get-HUTrAlignBody $U.Before $cur
    [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "$($U.Endpoint)" -Method PATCH -Body $body)
    if ("$($U.Typ)" -eq 'Compliance') {
        $rules = @(@(Get-HUTrProp $U.Before 'scheduledActionsForRule') | Where-Object { $_ } | ForEach-Object {
                @{ ruleName = "$(if ("$(Get-HUTrProp $_ 'ruleName')") { Get-HUTrProp $_ 'ruleName' } else { 'PasswordRequired' })"
                    scheduledActionConfigurations = @(@(Get-HUTrProp $_ 'scheduledActionConfigurations') | Where-Object { $_ } | ForEach-Object {
                            @{ actionType = "$(Get-HUTrProp $_ 'actionType')"; gracePeriodHours = [int](Get-HUTrProp $_ 'gracePeriodHours'); notificationTemplateId = "$(Get-HUTrProp $_ 'notificationTemplateId')"; notificationMessageCCList = @(@(Get-HUTrProp $_ 'notificationMessageCCList') | Where-Object { $_ }) } })
                } })
        if ($rules.Count) { [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "$($U.Endpoint)/scheduleActionsForRules" -Method POST -Body @{ deviceComplianceScheduledActionForRules = @($rules) }) }
    }
    $txt = "'$($U.Name)' auf den Stand vor dem Angleichen zurueckgesetzt."
    try {
        $after = Get-HUCompareObject -TenantKey $tk -Settings $Settings -Typ "$($U.Typ)" -Id "$($U.Id)"
        if ((Get-HUCompareHashNeutral $after) -ne "$($U.HashBefore)") { $txt += ' ACHTUNG: Der Fingerabdruck weicht vom gesicherten Stand ab - bitte im Portal pruefen (Details im Protokoll).' }
    } catch { $txt += " (Nachlesen nicht moeglich: $($_.Exception.Message))" }
    Write-HULog -Message "Rueckgaengig: $($U.Typ) '$($U.Name)' auf den Stand vor dem Angleichen zurueckgesetzt (angeglichen $($U.Time) aus $($U.Source))" -Level 'OK' -Tenant $tk
    Move-Item -LiteralPath $File -Destination ($File -replace '\.json$', '.rueckgaengig.json') -Force
    return [pscustomobject]@{ Deleted = $false; Text = $txt }
}

# Nur pruefen, ob Rueckgaengig gerade moeglich waere (liest das Ziel, schreibt nichts) - fuer die Anzeige im Rueckgaengig-Fenster
function Get-HUTransferUndoStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$File)
    try {
        $r = Undo-HUTransfer -Settings $Settings -File $File -CheckOnly
        if ("$($r.Text)" -like '*moeglich') { return [pscustomobject]@{ Ok = $true; Text = "$($r.Text)" } }
        return [pscustomobject]@{ Ok = $false; Text = "$($r.Text)" }
    } catch {
        Write-HULog -Message "Rueckgaengig-Pruefung $([System.IO.Path]::GetFileName($File)): $($_.Exception.Message)" -Level 'INFO'
        return [pscustomobject]@{ Ok = $false; Text = "$($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Get-HUTransferPlan, Get-HUTransferAlignPlan, Invoke-HUTransfer, Invoke-HUTransferAlign, Get-HUTransferUndoList, Get-HUTransferUndoStatus, Undo-HUTransfer, Find-HUTrSecrets, Find-HUTrForeignIds
