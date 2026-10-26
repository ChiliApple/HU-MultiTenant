#Requires -Version 5.1
<#
.SYNOPSIS
    Mustertenant (festgehaltener Soll-Stand) und Namenszuordnung zwischen Tenants - nur lesen.
.DESCRIPTION
    Mustertenant: ein vollstaendiger Backup-Stand eines Tenants wird als Soll-Stand festgehalten
    (Backups\_Muster\aktuell, laeuft nicht ab). Im Tenant-Vergleich kann er als eigene Spalte mitlaufen.
    Namenszuordnung: welche Gruppen, benannten Orte, Zuweisungsfilter und Bereichsmarkierungen eine Quelle
    (Muster oder Backup-Stand eines Tenants) verwendet und ob es sie in den Ziel-Tenants unter demselben Namen
    genau einmal gibt. Grundlage fuer das spaetere Uebertragen (Konzept 045, Regeln Ue-2 und Ue-3). Schreibt nichts
    in Tenants.
    Muster-Bibliothek (2.5.1, Konzept 056): mehrere Pakete (Teilpakete oder Gesamtstand) mit Kategorie, Schlagwoertern,
    Herkunft je Eintrag und Namenskatalog (names.json). Das bisherige Muster wird einmalig als Gesamtstand-Paket uebernommen.
    Mitgelieferte Pakete (Programmordner Muster\) nach Microsoft-Empfehlung: schreibgeschuetzt, Kopie bearbeitbar.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Braucht HU.Intune (Backup, Graph) und HU.SecCatalog
    (Notfallkonten, Sollwert V1).
#>

$script:HUMuKey = '__MUSTER__'
$script:HUMuGuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-HUMusterKey { return $script:HUMuKey }
function Get-HUMusterRoot($Settings) { return (Join-Path (Get-HUBackupRoot $Settings) '_Muster') }

# Aktueller Mustertenant -> @{ Folder; Source; SourceTime; PinnedAt; Note; Label } oder $null
function Get-HUMuster($Settings) {
    $d = Join-Path (Get-HUMusterRoot $Settings) 'aktuell'
    $mf = Join-Path $d 'muster.json'
    if (-not (Test-Path -LiteralPath $mf) -or -not (Test-Path -LiteralPath (Join-Path $d 'index.json'))) { return $null }
    try { $m = Read-HUBackupJson $mf } catch { return $null }
    $t = $null; try { $t = [datetime]::ParseExact("$($m.SourceTime)", 'yyyy-MM-dd_HHmmss', $null) } catch { }
    return [pscustomobject]@{ Folder = $d; Source = "$($m.Source)"; SourceTime = "$($m.SourceTime)"; PinnedAt = "$($m.PinnedAt)"; Note = "$($m.Note)"
        Label = "Muster ($($m.Source)$(if ($t) { ', ' + $t.ToString('dd.MM.yyyy') }))" }
}

# Backup-Stand als Muster festhalten. Nur vollstaendige Staende. Das bisherige Muster wandert nach _Muster\frueher.
function Save-HUMuster {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$TenantKey, [string]$Note = '', [datetime]$Now = (Get-Date))
    $ixf = Join-Path $Folder 'index.json'
    if (-not (Test-Path -LiteralPath $ixf)) { throw 'Der gewaehlte Stand hat keine index.json.' }
    $ix = Read-HUBackupJson $ixf
    $complete = if ($ix.PSObject.Properties['Complete']) { [bool]$ix.Complete } else { [int]$ix.Errors -eq 0 }
    if (-not $complete) { throw 'Nur ein vollstaendiger Backup-Stand kann Muster werden (dieser ist unvollstaendig).' }
    if ("$($ix.Tenant)" -and "$($ix.Tenant)" -ne $TenantKey) { throw "Der Stand gehoert zu Tenant '$($ix.Tenant)', nicht zu '$TenantKey'." }
    $root = Get-HUMusterRoot $Settings
    $cur = Join-Path $root 'aktuell'
    $tmp = Join-Path $root ("_neu_" + $Now.ToString('yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # erst vollstaendig kopieren, dann umschalten - ein Abbruch laesst das bisherige Muster stehen
    Copy-Item -LiteralPath $Folder -Destination $tmp -Recurse -Force
    Write-HUBackupJson (Join-Path $tmp 'muster.json') ([pscustomobject]@{ Source = $TenantKey; SourceTime = (Split-Path $Folder -Leaf); PinnedAt = $Now.ToString('s'); Note = $Note; By = "$env:USERNAME" })
    if (Test-Path -LiteralPath $cur) {
        $old = Get-HUMuster $Settings
        $arch = Join-Path (Join-Path $root 'frueher') ("$($Now.ToString('yyyy-MM-dd_HHmmss'))__$(ConvertTo-HUSafeFileName "$($old.Source)")")
        New-Item -ItemType Directory -Path (Split-Path $arch -Parent) -Force | Out-Null
        Move-Item -LiteralPath $cur -Destination $arch -Force
    }
    Move-Item -LiteralPath $tmp -Destination $cur -Force
    Write-HULog -Message "Mustertenant festgehalten: Stand $(Split-Path $Folder -Leaf) von '$TenantKey'" -Level 'OK' -Tenant $TenantKey
    return (Get-HUMuster $Settings)
}

# --------------------------- Namenszuordnung (nur lesen) ---------------------------

function Get-HUMuProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null
}

# Schluessel eines Verweises: Bereichsmarkierungen sind kleine Zahlen je Tenant ("1", "2") - nur zusammen mit dem
# Quell-Tenant eindeutig; alles andere sind GUIDs (056-Review: gleiche Tag-Id in zwei Tenants)
function Get-HUMuKey([string]$Art, [string]$Id, [string]$Source = '') {
    $k = "$Art|$("$Id".ToLowerInvariant())"
    if ($Art -eq 'Bereichsmarkierung') { $k += "|$("$Source".ToLowerInvariant())" }
    return $k
}

# Verweise einer Quelle sammeln: Liste @{ Art; Id; Name; Used; Source } (Name aus dem Stand bzw. Namenskatalog, wo moeglich).
# Source = Tenant, aus dem der verweisende Eintrag stammt (Paket: je Eintrag, sonst $DefaultSource).
function Get-HUMuRefs([string]$Folder, [string]$DefaultSource = '') {
    $ix = Read-HUBackupJson (Join-Path $Folder 'index.json')
    $objs = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($ix.Items)) {
        if (-not "$($it.File)") { continue }
        $src = if ($it.PSObject.Properties['Source'] -and "$($it.Source)") { "$($it.Source)" } else { $DefaultSource }
        try { $objs.Add([pscustomobject]@{ Typ = "$($it.Typ)"; Name = "$($it.Name)"; Id = "$($it.Id)"; Source = $src; O = (Read-HUBackupJson (Join-Path $Folder $it.File)) }) } catch { }
    }
    # Namenskatalog des Pakets (names.json) zuerst, dann Namen aus Objekten im Stand selbst
    $names = Get-HUMusterNameMap $Folder
    foreach ($x in $objs) { if ($x.Typ -in 'Benannter Ort', 'Zuweisungsfilter', 'Bereichsmarkierung') { $names[(Get-HUMuKey $x.Typ $x.Id $x.Source)] = $x.Name } }
    $refs = @{}
    $curSrc = ''
    $add = {
        param([string]$Art, [string]$Id, [string]$Name, [string]$Used)
        if (-not $Id) { return }
        $k = Get-HUMuKey $Art $Id $curSrc
        if (-not $Name -and $names.ContainsKey($k)) { $Name = "$($names[$k])" }
        if (-not $refs.ContainsKey($k)) { $refs[$k] = [pscustomobject]@{ Art = $Art; Id = $Id; Name = $Name; Used = (New-Object System.Collections.Generic.List[string]); Source = $curSrc } }
        if (-not $refs[$k].Used.Contains($Used)) { $refs[$k].Used.Add($Used) }
    }
    foreach ($x in $objs) {
        $used = "$($x.Typ): $($x.Name)"
        $curSrc = $x.Source
        if ($x.Typ -eq 'Conditional Access') {
            $c = Get-HUMuProp $x.O 'conditions'; $u = Get-HUMuProp $c 'users'; $l = Get-HUMuProp $c 'locations'
            foreach ($f in 'includeGroups', 'excludeGroups') { foreach ($g in @(Get-HUMuProp $u $f)) { if ("$g" -match $script:HUMuGuidRx) { & $add 'Gruppe' "$g" '' $used } } }
            foreach ($f in 'includeUsers', 'excludeUsers') { foreach ($g in @(Get-HUMuProp $u $f)) { if ("$g" -match $script:HUMuGuidRx) { & $add 'Benutzer' "$g" '' $used } } }
            foreach ($f in 'includeLocations', 'excludeLocations') { foreach ($g in @(Get-HUMuProp $l $f)) { if ("$g" -match $script:HUMuGuidRx) { & $add 'Benannter Ort' "$g" "$($names["Benannter Ort|$("$g".ToLowerInvariant())"])" $used } } }
        }
        foreach ($a in @(Get-HUMuProp $x.O 'assignments')) {
            $t = Get-HUMuProp $a 'target'
            $gid = "$(Get-HUMuProp $t 'groupId')"
            if ($gid -match $script:HUMuGuidRx) { & $add 'Gruppe' $gid '' $used }
            $fid = "$(Get-HUMuProp $t 'deviceAndAppManagementAssignmentFilterId')"
            if ($fid -match $script:HUMuGuidRx) { & $add 'Zuweisungsfilter' $fid "$($names["Zuweisungsfilter|$($fid.ToLowerInvariant())"])" $used }
        }
        foreach ($st in @(Get-HUMuProp $x.O 'roleScopeTagIds')) { if ("$st" -and "$st" -ne '0') { & $add 'Bereichsmarkierung' "$st" "$($names["Bereichsmarkierung|$("$st".ToLowerInvariant())"])" $used } }
    }
    return @($refs.Values)
}

# Name vergleichbar machen (045 F2: Gross/klein und Leerzeichen am Rand egal; Zeichen in der Mitte bleiben, wie sie sind)
function ConvertTo-HUMuName([string]$N) { return ("$N".Trim()).ToLowerInvariant() }

# Namenszuordnung: je Verweis der Quelle eine Zeile, je Ziel-Tenant ok / fehlt / mehrfach / nicht pruefbar
function Get-HUNameMap {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string[]]$Folder, [string]$SourceKey = '', [Parameter(Mandatory)][string[]]$Targets, [hashtable]$Names = @{})
    # mehrere Quellen (Muster-Pakete): Verweise zusammenfassen, je Verweis der Tenant, aus dem er stammt
    $byKey = @{}
    foreach ($f in @($Folder)) {
        foreach ($r in @(Get-HUMuRefs $f $SourceKey)) {
            $k = Get-HUMuKey $r.Art $r.Id $r.Source
            if (-not $byKey.ContainsKey($k)) { $byKey[$k] = $r; continue }
            foreach ($u in $r.Used) { if (-not $byKey[$k].Used.Contains($u)) { $byKey[$k].Used.Add($u) } }
            if (-not $byKey[$k].Name -and $r.Name) { $byKey[$k].Name = $r.Name }
        }
    }
    $refs = @($byKey.Values)
    # Notfallkonten der Quellen (Sollwert V1) - werden beim Uebertragen durch die des Ziels ersetzt (Ue-3)
    $bgSrc = @()
    foreach ($sk in @(@($SourceKey) + @($refs | ForEach-Object { "$($_.Source)" }) | Where-Object { $_ } | Sort-Object -Unique)) {
        try { $bl = Get-HUSecBaseline -TenantKey $sk; if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { $bgSrc += @($bl.Values['V1'].accounts | ForEach-Object { "$_".ToLowerInvariant() }) } } catch { }
    }
    # Gruppennamen in der Quelle nachschlagen (der Stand enthaelt nur IDs; Pakete bringen sie im Namenskatalog mit)
    foreach ($r in @($refs | Where-Object { $_.Art -eq 'Gruppe' -and -not $_.Name })) {
        $sk = if ("$($r.Source)") { "$($r.Source)" } else { $SourceKey }
        if (-not $sk) { continue }
        try { $g = Invoke-HUIntuneGraph -TenantKey $sk -Settings $Settings -Endpoint "/groups/$($r.Id)?`$select=displayName" -V1 -NoRetry; $r.Name = "$($g.displayName)" }
        catch { $r.Name = '' }
    }
    $lists = @{}
    $listOf = {
        param([string]$Tk, [string]$Art)
        $k = "$Tk|$Art"
        if (-not $lists.ContainsKey($k)) {
            $ep = switch ($Art) { 'Benannter Ort' { '/identity/conditionalAccess/namedLocations?$select=id,displayName' } 'Zuweisungsfilter' { '/deviceManagement/assignmentFilters?$select=id,displayName' } 'Bereichsmarkierung' { '/deviceManagement/roleScopeTags?$select=id,displayName' } }
            try { $lists[$k] = @(Get-HUIntuneGraphAll -TenantKey $Tk -Settings $Settings -Endpoint $ep -V1:($Art -eq 'Benannter Ort')) } catch { $lists[$k] = $null }
        }
        return , $lists[$k]
    }
    $rows = foreach ($r in @($refs | Sort-Object Art, Name)) {
        $o = [ordered]@{ Art = $r.Art; Name = $(if ($r.Name) { $r.Name } else { "(unbekannt, $("$($r.Id)".Substring(0, 8)))" }) }
        $isBg = ($r.Art -eq 'Benutzer' -and $bgSrc -contains "$($r.Id)".ToLowerInvariant())
        if ($r.Art -eq 'Benutzer') { $o.Art = $(if ($isBg) { 'Notfallkonto' } else { 'Benutzer' }); $o.Name = "$("$($r.Id)".Substring(0, 8))..." }
        foreach ($t in $Targets) {
            $col = if ($Names.ContainsKey($t)) { $Names[$t] } else { $t }
            $v = ''
            if ($r.Art -eq 'Benutzer') { $v = $(if ($isBg) { 'wird durch die Notfallkonten des Ziels ersetzt' } else { 'nicht zuordenbar (Benutzer)' }) }
            elseif (-not $r.Name) { $v = 'Name in der Quelle unbekannt' }
            elseif ($r.Art -eq 'Gruppe') {
                $f = [uri]::EscapeDataString("displayName eq '$($r.Name.Replace("'", "''"))'")
                try {
                    $hits = @(Get-HUIntuneGraphAll -TenantKey $t -Settings $Settings -Endpoint "/groups?`$filter=$f&`$select=id,displayName" -V1 | Where-Object { (ConvertTo-HUMuName "$($_.displayName)") -eq (ConvertTo-HUMuName $r.Name) })
                    $v = switch ($hits.Count) { 0 { 'fehlt' } 1 { 'ok' } default { "mehrfach ($($hits.Count))" } }
                } catch { $v = 'nicht pruefbar' }
            } else {
                $l = & $listOf $t $r.Art
                if ($null -eq $l) { $v = 'nicht pruefbar' }
                else {
                    $hits = @($l | Where-Object { (ConvertTo-HUMuName "$($_.displayName)") -eq (ConvertTo-HUMuName $r.Name) })
                    $v = switch ($hits.Count) { 0 { 'fehlt' } 1 { 'ok' } default { "mehrfach ($($hits.Count))" } }
                }
            }
            $o[$col] = $v
        }
        $o['Verwendet in'] = "$($r.Used.Count)x: $((@($r.Used | Select-Object -First 3)) -join '; ')$(if ($r.Used.Count -gt 3) { ' ...' })"
        [pscustomobject]$o
    }
    # Notfallkonten je Ziel (Ue-3): ohne hinterlegte, aktive Notfallkonten kein Uebertragen von CA/Autorisierung/Orten
    $bgRow = [ordered]@{ Art = 'Notfallkonten'; Name = '(Sollwert V1 je Tenant)' }
    foreach ($t in $Targets) {
        $col = if ($Names.ContainsKey($t)) { $Names[$t] } else { $t }
        $bgRow[$col] = try { $b = Test-HUEntraBreakGlass -TenantKey $t -Settings $Settings; if ($b.Ok) { 'ok' } else { "$($b.Text)" } } catch { 'nicht pruefbar' }
    }
    $bgRow['Verwendet in'] = 'Pflicht fuer Conditional Access, Autorisierungsrichtlinie, benannte Orte'
    return @(@($rows) + @([pscustomobject]$bgRow))
}

# =====================================================================================
# Muster-Bibliothek (2.5.1): mehrere Pakete (Teilpakete oder Gesamtstand), Kategorien, Schlagwoerter, Herkunft je Eintrag.
# Ablage: Backups\_Muster\pakete\<Id>\ mit paket.json, index.json (wie ein Backup-Stand - Vergleich/Diff ohne Umbau),
# den Eintraegen und names.json (Namenskatalog: Quell-ID -> Art + Name, damit spaeter auch ohne Quell-Tenant aufgeloest
# werden kann). Schreibt nichts in Tenants.
# =====================================================================================

$script:HUMuMigrating = $false
# Mitgelieferte Pakete (2.5.1): liegen im Programm unter Muster\<Id>\, kommen mit jedem Update, sind schreibgeschuetzt.
# Herkunft der Eintraege = 'mitgeliefert' (kein Tenant; Namen von Rollen u. a. schlaegt die App in einem eigenen Tenant nach).
$script:HUMuBuiltinSource = 'mitgeliefert'
$script:HUMuBuiltinCategory = 'Mitgeliefert'
$script:HUMuBuiltinRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Muster'
$script:HUMuCategories = @('Conditional Access', 'Compliance', 'Entra-Grundschutz', 'Endpunktsicherheit/Defender', 'Updates', 'Geraetekonfiguration', 'Gesamtstand')
$script:HUMuNameTypes = @('Benannter Ort', 'Zuweisungsfilter', 'Bereichsmarkierung', 'Authentifizierungsstaerke')

function Get-HUMusterCategories { return $script:HUMuCategories }
function Get-HUMusterBuiltinRoot { return $script:HUMuBuiltinRoot }
# nur fuer Tests: anderer Ordner fuer die mitgelieferten Pakete
function Set-HUMusterBuiltinRoot([string]$Path) { $script:HUMuBuiltinRoot = $Path }
function Get-HUMusterBuiltinSource { return $script:HUMuBuiltinSource }
function Test-HUMusterBuiltinSource([string]$Source) { return ("$Source" -eq $script:HUMuBuiltinSource) }
# Tenant, in dem Kennungen eines Eintrags zu Namen werden: eigener Quell-Tenant; bei mitgelieferten Eintraegen der erste
# eingerichtete Tenant (dort stehen nur Rollen und Microsoft-Apps - deren Kennungen sind in jedem Tenant gleich)
function Get-HUMusterResolveKey($Settings, [string]$Source) {
    if (-not (Test-HUMusterBuiltinSource $Source)) { return $Source }
    $t = @(@($Settings.tenants) | Where-Object { $_ -and "$($_.key)" }) | Select-Object -First 1
    if ($t) { return "$($t.key)" }; return ''
}
function Get-HUMusterPkgRoot($Settings) { return (Join-Path (Get-HUMusterRoot $Settings) 'pakete') }

# Schlagwoerter aus Freitext: Komma, Strichpunkt oder Leerzeichen trennen, '#' vorne weg, doppelte (Gross/klein) einmal
function ConvertTo-HUMusterTags([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in @("$Text" -split '[,;\s]+')) {
        $t = $t.Trim().TrimStart('#').Trim()
        if (-not $t) { continue }
        if (@($out | Where-Object { $_ -ieq $t }).Count) { continue }
        $out.Add($t)
    }
    return $out.ToArray()
}

# Namenskatalog eines Ordners (names.json) -> Hashtable "Art|id" -> Name (leer, wenn keiner da)
function Get-HUMusterNameMap([string]$Folder) {
    $map = @{}
    $f = Join-Path $Folder 'names.json'
    if (-not (Test-Path -LiteralPath $f)) { return $map }
    try { foreach ($n in @((Read-HUBackupJson $f).Items)) { if ("$($n.Id)" -and "$($n.Name)") { $map[(Get-HUMuKey "$($n.Art)" "$($n.Id)" "$($n.Source)")] = "$($n.Name)" } } } catch { }
    return $map
}

# Name eines Verweises aus dem Namenskatalog eines Pakets ('' = unbekannt)
function Resolve-HUMusterName([string]$Folder, [string]$Art, [string]$Id, [string]$Source = '') {
    if (-not $Folder -or -not $Id) { return '' }
    $m = Get-HUMusterNameMap $Folder
    $k = Get-HUMuKey $Art $Id $Source
    if ($m.ContainsKey($k)) { return "$($m[$k])" }
    return ''
}

# Bereichsmarkierungen der Pakete aus EINEM Quell-Tenant: Id -> Name (fuer das Uebertragen; '0' = Standard braucht keinen Namen)
function Get-HUMusterTagNames([string[]]$Folders, [string]$Source) {
    $h = @{}
    foreach ($f in @($Folders)) {
        $nf = Join-Path $f 'names.json'
        if (-not (Test-Path -LiteralPath $nf)) { continue }
        try { foreach ($n in @((Read-HUBackupJson $nf).Items)) { if ("$($n.Art)" -eq 'Bereichsmarkierung' -and "$($n.Id)" -and "$($n.Name)" -and "$($n.Source)" -ieq $Source) { $h["$($n.Id)"] = "$($n.Name)" } } } catch { }
    }
    return $h
}

# 2.5.1 Namen benannter Orte aus dem Paket selbst (names.json + Eintraege 'Benannter Ort'): Kennung (klein) -> Name.
# Mitgelieferte Pakete bringen den Ort mit - er steht in keinem Tenant, aus dem man den Namen nachlesen koennte.
function Get-HUMusterLocationNames([string[]]$Folders) {
    $h = @{}
    foreach ($f in @($Folders | Where-Object { "$_" })) {
        $nf = Join-Path $f 'names.json'
        if (Test-Path -LiteralPath $nf) {
            try { foreach ($n in @((Read-HUBackupJson $nf).Items)) { if ("$($n.Art)" -eq 'Benannter Ort' -and "$($n.Id)" -and "$($n.Name)") { $h["$($n.Id)".ToLowerInvariant()] = "$($n.Name)" } } } catch { }
        }
        $xf = Join-Path $f 'index.json'
        if (Test-Path -LiteralPath $xf) {
            try { foreach ($it in @((Read-HUBackupJson $xf).Items)) { if ("$($it.Typ)" -eq 'Benannter Ort' -and "$($it.Id)" -and "$($it.Name)" -and -not $h.ContainsKey("$($it.Id)".ToLowerInvariant())) { $h["$($it.Id)".ToLowerInvariant()] = "$($it.Name)" } } } catch { }
        }
    }
    return $h
}

function Read-HUMusterPackage([string]$Folder, [switch]$BuiltIn) {
    $pf = Join-Path $Folder 'paket.json'
    if (-not (Test-Path -LiteralPath $pf) -or -not (Test-Path -LiteralPath (Join-Path $Folder 'index.json'))) { return $null }
    try { $p = Read-HUBackupJson $pf; $ix = Read-HUBackupJson (Join-Path $Folder 'index.json') } catch { return $null }
    $items = @($ix.Items)
    $srcs = @($items | ForEach-Object { "$($_.Source)" } | Where-Object { $_ } | Sort-Object -Unique)
    # PS 7 macht aus ISO-Datumstexten beim Lesen DateTime - immer als ISO-Text weitergeben
    $iso = { param($v) if ($v -is [datetime]) { $v.ToString('s') } else { "$v" } }
    $created = & $iso $p.Created; $changed = & $iso $p.Changed
    $chg = $null; try { $chg = [datetime]::Parse($changed, [Globalization.CultureInfo]::InvariantCulture) } catch { }
    return [pscustomobject]@{
        Id = "$($p.Id)"; Title = "$($p.Title)"; Category = "$($p.Category)"; Tags = @($p.Tags | Where-Object { "$_" } | ForEach-Object { "$_" }); Note = "$($p.Note)"
        Created = $created; Changed = $changed; ChangedText = $(if ($chg) { $chg.ToString('dd.MM.yyyy HH:mm') } else { '' }); By = "$($p.By)"
        Origin = $(if ("$($p.Origin)") { "$($p.Origin)" } else { 'eigen' }); Complete = [bool]$p.Complete
        Count = $items.Count; Sources = $srcs; SourceText = ($srcs -join ', '); Folder = $Folder; Items = $items
        TagText = (@($p.Tags | Where-Object { "$_" } | ForEach-Object { "#$_" }) -join ' ')
        BuiltIn = [bool]$BuiltIn
        # Kategorie fuer eine Kopie (mitgelieferte Pakete stehen unter 'Mitgeliefert', die Kopie unter ihrer echten Kategorie)
        CopyCategory = $(if ("$($p.CopyCategory)" -and $script:HUMuCategories -contains "$($p.CopyCategory)") { "$($p.CopyCategory)" } elseif ($script:HUMuCategories -contains "$($p.Category)") { "$($p.Category)" } else { 'Conditional Access' })
        Learn = @($p.Learn | Where-Object { "$_" } | ForEach-Object { "$_" })
    }
}

# Alle Pakete der Bibliothek (sortiert nach Kategorie-Reihenfolge, dann Titel). Uebernimmt beim ersten Aufruf das bisherige
# Muster (_Muster\aktuell) als Paket "Gesamtstand" - einmalig, das alte Muster bleibt liegen.
function Get-HUMusterPackages($Settings) {
    try { Initialize-HUMusterLibrary $Settings | Out-Null } catch { try { Write-HULog -Message "Muster-Bibliothek: bisheriges Muster nicht uebernommen ($($_.Exception.Message))" -Level 'WARN' } catch { } }
    $list = New-Object System.Collections.Generic.List[object]
    $bix = @{}
    foreach ($p in @(Get-HUMusterBuiltinPackages)) { $bix[$p.Id] = $bix.Count; $list.Add($p) }
    $root = Get-HUMusterPkgRoot $Settings
    if (Test-Path -LiteralPath $root) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -notlike '_*' })) {
            $p = Read-HUMusterPackage $d.FullName
            # eigene Kopie mit der Kennung eines mitgelieferten Pakets: das mitgelieferte gewinnt (Kennung bleibt eindeutig)
            if ($p -and -not @($list | Where-Object { $_.Id -eq $p.Id }).Count) { $list.Add($p) }
        }
    }
    # Mitgelieferte zuerst (in ihrer Reihenfolge, Order aus paket.json), dann nach Kategorie-Reihenfolge und Titel
    return @($list.ToArray() | Sort-Object @{ Expression = { if ($_.BuiltIn) { -1 } else { $i = [array]::IndexOf($script:HUMuCategories, $_.Category); if ($i -lt 0) { 99 } else { $i } } } },
        @{ Expression = { if ($_.BuiltIn -and $bix.ContainsKey($_.Id)) { '{0:D4}' -f $bix[$_.Id] } else { "$($_.Title)" } } })
}

# Mitgelieferte Pakete (Programmordner Muster\) - schreibgeschuetzt
function Get-HUMusterBuiltinPackages {
    $r = $script:HUMuBuiltinRoot
    if (-not $r -or -not (Test-Path -LiteralPath $r)) { return @() }
    # 2.5.1 Reihenfolge: 'Order' aus paket.json (kleiner = weiter oben, z. B. Praxis-Set Schule zuerst), sonst nach Ordnername
    $list = @(foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name)) {
            $p = Read-HUMusterPackage $d.FullName -BuiltIn
            if ($p) {
                $p.Category = $script:HUMuBuiltinCategory
                $o = 50; try { $pj = Read-HUBackupJson (Join-Path $d.FullName 'paket.json'); if ($pj.PSObject.Properties['Order'] -and "$($pj.Order)" -match '^\d+$') { $o = [int]$pj.Order } } catch { }
                [pscustomobject]@{ O = $o; N = $d.Name; P = $p }
            }
        })
    return @($list | Sort-Object O, N | ForEach-Object { $_.P })
}

function Get-HUMusterPackage($Settings, [string]$Id) {
    if (-not $Id -or $Id -match '[\\/:*?"<>|]' -or $Id -like '*..*') { return $null }
    $b = @(Get-HUMusterBuiltinPackages | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($b) { return $b }
    return (Read-HUMusterPackage (Join-Path (Get-HUMusterPkgRoot $Settings) $Id))
}

# Namenskatalog fuer die Eintraege eines (neuen) Pakets: Orte, Filter, Bereichsmarkierungen, Staerken aus den Index-Dateien
# der Quell-Staende (Name + Id stehen dort), Gruppen live im Quell-Tenant (nur mit -ResolveGroups), vorhandene Kataloge
# (Bearbeiten eines Pakets) als Rueckfall. Liefert Liste @{ Art; Id; Name; Source }.
function Get-HUMusterNameCatalog {
    param([Parameter(Mandatory)][string]$PackageFolder, [object[]]$Items = @(), $Settings = $null, [switch]$ResolveGroups)
    $known = @{}
    $byStand = @{}
    foreach ($it in @($Items)) {
        $f = "$($it.Folder)"
        if (-not $f -or $byStand.ContainsKey($f)) { continue }
        $byStand[$f] = $true
        foreach ($k in @((Get-HUMusterNameMap $f).GetEnumerator())) { $known[$k.Key] = @{ Name = "$($k.Value)"; Source = "$($it.Source)" } }
        try {
            foreach ($x in @((Read-HUBackupJson (Join-Path $f 'index.json')).Items)) {
                # Quell-Stand: Tenant = der des Eintrags; Paket (beim Bearbeiten): Tenant steht je Eintrag im Index
                $xs = if ($x.PSObject.Properties['Source'] -and "$($x.Source)") { "$($x.Source)" } else { "$($it.Source)" }
                if ($script:HUMuNameTypes -contains "$($x.Typ)" -and "$($x.Id)" -and "$($x.Name)") { $known[(Get-HUMuKey "$($x.Typ)" "$($x.Id)" $xs)] = @{ Name = "$($x.Name)"; Source = $xs } }
            }
        } catch { }
    }
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in @(Get-HUMuRefs $PackageFolder)) {
        $k = Get-HUMuKey $r.Art $r.Id $r.Source
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $n = "$($r.Name)"
        if (-not $n -and $known.ContainsKey($k)) { $n = "$($known[$k].Name)" }
        if (-not $n -and $r.Art -eq 'Gruppe' -and $ResolveGroups -and "$($r.Source)" -and $Settings) {
            try { $n = "$((Invoke-HUIntuneGraph -TenantKey "$($r.Source)" -Settings $Settings -Endpoint "/groups/$($r.Id)?`$select=displayName" -V1 -NoRetry).displayName)" } catch { $n = '' }
        }
        if ($r.Art -eq 'Benutzer') { continue }   # Benutzer nie in den Katalog (Personenbezug)
        $out.Add([pscustomobject]@{ Art = $r.Art; Id = "$($r.Id)"; Name = $n; Source = "$($r.Source)" })
    }
    # Authentifizierungsstaerken aus CA (grantControls.authenticationStrength.id) - nur Name, wenn bekannt
    try {
        foreach ($x in @((Read-HUBackupJson (Join-Path $PackageFolder 'index.json')).Items | Where-Object { "$($_.Typ)" -eq 'Conditional Access' -and "$($_.File)" })) {
            $o = Read-HUBackupJson (Join-Path $PackageFolder $x.File)
            $as = Get-HUMuProp (Get-HUMuProp (Get-HUMuProp $o 'grantControls') 'authenticationStrength') 'id'
            if ("$as") {
                $k = "Authentifizierungsstaerke|$("$as".ToLowerInvariant())"
                if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out.Add([pscustomobject]@{ Art = 'Authentifizierungsstaerke'; Id = "$as"; Name = $(if ($known.ContainsKey($k)) { "$($known[$k].Name)" } else { '' }); Source = "$($x.Source)" }) }
            }
        }
    } catch { }
    return $out.ToArray()
}

# Paket anlegen oder ersetzen. Items: @{ Typ; Name; Id; File (relativ, '' = nur Name); Folder (Quell-Stand oder Paket);
# Source (Tenant); Stand }. Gleiche Art+Name nur einmal (erster gewinnt). Erst vollstaendig neu schreiben, dann umschalten.
# Rueckgabe: @{ Package; Skipped (Liste 'Art: Name') }
function Save-HUMusterPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Title, [string]$Category = 'Gesamtstand', [string[]]$Tags = @(), [string]$Note = '',
        [Parameter(Mandatory)][object[]]$Items, [switch]$Complete, [string]$Id = '', [switch]$ResolveGroups, [switch]$SkipMissing, [datetime]$Now = (Get-Date)
    )
    $Title = "$Title".Trim()
    if (-not $Title) { throw 'Das Paket braucht einen Namen.' }
    if ($script:HUMuCategories -notcontains $Category) { throw "Unbekannte Kategorie: $Category" }
    if (-not @($Items).Count) { throw 'Das Paket hat keine Eintraege.' }
    $root = Get-HUMusterPkgRoot $Settings
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $old = $null
    if ($Id) {
        $old = Get-HUMusterPackage $Settings $Id
        if (-not $old) { throw "Paket $Id nicht gefunden." }
        if ($old.BuiltIn) { throw "'$($old.Title)' ist mitgeliefert und schreibgeschuetzt - bitte duplizieren und die Kopie bearbeiten." }
    }
    else { $Id = "$($Now.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
    # gleicher Titel nur einmal (Gross/klein egal)
    foreach ($p in @(Get-HUMusterPackages $Settings)) { if ($p.Id -ne $Id -and (ConvertTo-HUMuName $p.Title) -eq (ConvertTo-HUMuName $Title)) { throw "Es gibt schon ein Paket '$($p.Title)'." } }
    $tmp = Join-Path $root ("_neu_" + $Id + '_' + $Now.ToString('HHmmssfff'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $seen = @{}; $skipped = New-Object System.Collections.Generic.List[string]; $ixItems = New-Object System.Collections.Generic.List[object]
    $n = 0
    try {
        foreach ($it in @($Items)) {
            $typ = "$($it.Typ)"; $name = "$($it.Name)"
            if (-not $typ -or -not $name) { continue }
            $k = "$typ|$(ConvertTo-HUMuName $name)"
            if ($seen.ContainsKey($k)) { $skipped.Add("${typ}: $name"); continue }
            $seen[$k] = $true
            $n++
            $file = ''
            if ("$($it.File)") {
                $srcPath = Join-Path "$($it.Folder)" "$($it.File)"
                if (-not (Test-Path -LiteralPath $srcPath)) {
                    if ($SkipMissing) { $skipped.Add("${typ}: $name (Datei fehlt)"); $seen.Remove($k); $n--; continue }
                    throw "Datei fehlt: $srcPath"
                }
                $file = "$(ConvertTo-HUSafeFileName $typ 40)\$('{0:D3}' -f $n)_$(ConvertTo-HUSafeFileName $name 60).json"
                $dst = Join-Path $tmp $file
                $dd = Split-Path $dst -Parent
                if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                Copy-Item -LiteralPath $srcPath -Destination $dst -Force
            }
            $ixItems.Add([pscustomobject]@{ Typ = $typ; Name = $name; Id = "$($it.Id)"; File = $file; Source = "$($it.Source)"; Stand = "$($it.Stand)" })
        }
        if (-not $ixItems.Count) { throw 'Das Paket hat keine Eintraege.' }
        Write-HUBackupJson (Join-Path $tmp 'index.json') ([pscustomobject]@{ Tenant = (Get-HUMusterKey); Errors = 0; Complete = $true; FailedTypes = @(); Items = $ixItems.ToArray() })
        $cat = @(Get-HUMusterNameCatalog -PackageFolder $tmp -Items $Items -Settings $Settings -ResolveGroups:$ResolveGroups)
        Write-HUBackupJson (Join-Path $tmp 'names.json') ([pscustomobject]@{ Format = 1; Items = $cat })
        Write-HUBackupJson (Join-Path $tmp 'paket.json') ([pscustomobject]@{
                Format = 1; Id = $Id; Title = $Title; Category = $Category; Tags = @(ConvertTo-HUMusterTags ($Tags -join ' ')); Note = "$Note"
                Created = $(if ($old -and $old.Created) { $old.Created } else { $Now.ToString('s') }); Changed = $Now.ToString('s'); By = "$env:USERNAME"
                Origin = $(if ($old) { $old.Origin } else { 'eigen' }); Complete = [bool]$Complete
            })
    } catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; throw }
    $dst = Join-Path $root $Id
    if (Test-Path -LiteralPath $dst) {
        $bak = Join-Path $root ("_alt_" + $Id + '_' + $Now.ToString('HHmmssfff'))
        try { Move-Item -LiteralPath $dst -Destination $bak -Force -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; throw "Paket nicht gespeichert - der bisherige Ordner ist gesperrt ($($_.Exception.Message))." }
        try { Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop }
        catch {
            # zurueck: der bisherige Stand bleibt sichtbar
            try { Move-Item -LiteralPath $bak -Destination $dst -Force -ErrorAction Stop } catch { }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            throw "Paket nicht gespeichert ($($_.Exception.Message)) - der bisherige Stand bleibt."
        }
        Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        try { Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; throw "Paket nicht gespeichert ($($_.Exception.Message))." }
    }
    Write-HULog -Message "Muster-Paket '$Title' gespeichert ($($ixItems.Count) Eintraege$(if ($skipped.Count) { ", $($skipped.Count) doppelt weggelassen" }))" -Level 'OK'
    return [pscustomobject]@{ Package = (Read-HUMusterPackage $dst); Skipped = $skipped.ToArray() }
}

# Eintraege eines Pakets als Items fuer Save-HUMusterPackage (Bearbeiten, Duplizieren)
function Get-HUMusterPackageItems($Package) {
    return @(@($Package.Items) | ForEach-Object { [pscustomobject]@{ Typ = "$($_.Typ)"; Name = "$($_.Name)"; Id = "$($_.Id)"; File = "$($_.File)"; Folder = $Package.Folder; Source = "$($_.Source)"; Stand = "$($_.Stand)" } })
}

# Eintraege eines Backup-Stands als Items (fuer das Paket)
function Get-HUMusterStandItems([string]$Folder, [string]$TenantKey) {
    $ix = Read-HUBackupJson (Join-Path $Folder 'index.json')
    $stand = Split-Path $Folder -Leaf
    return @(@($ix.Items) | Where-Object { "$($_.Typ)" -and "$($_.Name)" } | ForEach-Object { [pscustomobject]@{ Typ = "$($_.Typ)"; Name = "$($_.Name)"; Id = "$($_.Id)"; File = "$($_.File)"; Folder = $Folder; Source = $TenantKey; Stand = $stand } })
}

# Gesamtstand eines Backup-Stands als Paket (Nachfolger von "Als Muster festhalten") - nur vollstaendige Staende
function New-HUMusterPackageFromStand {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)][string]$Title, [string]$Note = '', [switch]$ResolveGroups, [datetime]$Now = (Get-Date))
    $ix = Read-HUBackupJson (Join-Path $Folder 'index.json')
    $complete = if ($ix.PSObject.Properties['Complete']) { [bool]$ix.Complete } else { [int]$ix.Errors -eq 0 }
    if (-not $complete) { throw 'Nur ein vollstaendiger Backup-Stand kann Gesamtstand-Paket werden (dieser ist unvollstaendig).' }
    if ("$($ix.Tenant)" -and "$($ix.Tenant)" -ne $TenantKey) { throw "Der Stand gehoert zu Tenant '$($ix.Tenant)', nicht zu '$TenantKey'." }
    return (Save-HUMusterPackage -Settings $Settings -Title $Title -Category 'Gesamtstand' -Note $Note -Items @(Get-HUMusterStandItems $Folder $TenantKey) -Complete -ResolveGroups:$ResolveGroups -Now $Now)
}

# Paket loeschen = in den Papierkorb der Bibliothek verschieben (_Muster\papierkorb), nicht endgueltig
function Remove-HUMusterPackage($Settings, [string]$Id, [datetime]$Now = (Get-Date)) {
    $p = Get-HUMusterPackage $Settings $Id
    if (-not $p) { throw "Paket $Id nicht gefunden." }
    if ($p.BuiltIn) { throw "'$($p.Title)' ist mitgeliefert und kann nicht geloescht werden." }
    $bin = Join-Path (Get-HUMusterRoot $Settings) 'papierkorb'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    # 058 B7: gesperrter Ordner -> Fehler statt "verschoben"
    Move-Item -LiteralPath $p.Folder -Destination (Join-Path $bin "$($Now.ToString('yyyy-MM-dd_HHmmss'))__$Id") -Force -ErrorAction Stop
    Write-HULog -Message "Muster-Paket '$($p.Title)' in den Papierkorb der Bibliothek verschoben" -Level 'OK'
}

# --------------------------- Papierkorb der Bibliothek ---------------------------

function Get-HUMusterTrashRoot($Settings) { return (Join-Path (Get-HUMusterRoot $Settings) 'papierkorb') }

# Pakete im Papierkorb: @{ Folder; Id; Title; Category; Count; DeletedAt (datetime); DeletedText } - neueste zuerst
function Get-HUMusterTrash($Settings) {
    $bin = Get-HUMusterTrashRoot $Settings
    if (-not (Test-Path -LiteralPath $bin)) { return @() }
    $list = foreach ($d in @(Get-ChildItem -LiteralPath $bin -Directory)) {
        $p = Read-HUMusterPackage $d.FullName
        if (-not $p) { continue }
        $t = $null; try { $t = [datetime]::ParseExact(($d.Name -split '__', 2)[0], 'yyyy-MM-dd_HHmmss', $null) } catch { $t = $d.LastWriteTime }
        [pscustomobject]@{ Folder = $d.FullName; Id = $p.Id; Title = $p.Title; Category = $p.Category; Count = $p.Count; DeletedAt = $t; DeletedText = $t.ToString('dd.MM.yyyy HH:mm') }
    }
    return @($list | Sort-Object DeletedAt -Descending)
}

# Ordner muss direkt im Papierkorb liegen (keine fremden Pfade)
function Test-HUMusterTrashFolder($Settings, [string]$Folder) {
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return $false }
    # '.'/'..' am Ende oder unterwegs ergeben einen Elternordner, der der Papierkorb ist - nie zulassen (058 B6)
    if (@("$Folder" -split '[\\/]' | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count) { return $false }
    $bin = [IO.Path]::GetFullPath((Get-HUMusterTrashRoot $Settings)).TrimEnd('\', '/')
    $par = [IO.Path]::GetFullPath((Split-Path $Folder -Parent)).TrimEnd('\', '/')
    return ($par -eq $bin)
}

# Paket aus dem Papierkorb zurueckholen; gibt es den Namen schon, mit Zusatz "(wiederhergestellt)"
function Restore-HUMusterPackage($Settings, [string]$Folder, [datetime]$Now = (Get-Date)) {
    if (-not (Test-HUMusterTrashFolder $Settings $Folder)) { throw 'Kein Paket im Papierkorb der Bibliothek.' }
    $p = Read-HUMusterPackage $Folder
    if (-not $p) { throw 'Paket im Papierkorb nicht lesbar.' }
    $root = Get-HUMusterPkgRoot $Settings
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $id = $p.Id
    # Kennung aus paket.json nur als einfacher Ordnername (058 B6)
    if ($id -match '[\\/:*?"<>|]' -or $id -like '*..*' -or $id -like '_*') { $id = '' }
    if (-not $id -or (Test-Path -LiteralPath (Join-Path $root $id))) { $id = "$($Now.ToString('yyyyMMdd-HHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 6))" }
    $titles = @(Get-HUMusterPackages $Settings | ForEach-Object { ConvertTo-HUMuName $_.Title })
    $title = $p.Title
    if ($titles -contains (ConvertTo-HUMuName $title)) {
        $title = "$($p.Title) (wiederhergestellt)"; $i = 2
        while ($titles -contains (ConvertTo-HUMuName $title)) { $title = "$($p.Title) (wiederhergestellt $i)"; $i++ }
    }
    $dst = Join-Path $root $id
    Move-Item -LiteralPath $Folder -Destination $dst -Force -ErrorAction Stop
    $pf = Join-Path $dst 'paket.json'
    $j = Read-HUBackupJson $pf
    $j.Id = $id; $j.Title = $title
    Write-HUBackupJson $pf $j
    Write-HULog -Message "Muster-Paket '$title' aus dem Papierkorb zurueckgeholt" -Level 'OK'
    return (Read-HUMusterPackage $dst)
}

# Ein Paket im Papierkorb endgueltig loeschen
function Remove-HUMusterTrashItem($Settings, [string]$Folder) {
    if (-not (Test-HUMusterTrashFolder $Settings $Folder)) { throw 'Kein Paket im Papierkorb der Bibliothek.' }
    Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop
    Write-HULog -Message "Muster-Paket endgueltig geloescht ($(Split-Path $Folder -Leaf))" -Level 'OK'
}

# Papierkorb leeren: alles, was laenger als $Days Tage drin liegt (0 = alles). Rueckgabe: Anzahl
function Clear-HUMusterTrash($Settings, [int]$Days = 90, [datetime]$Now = (Get-Date)) {
    $n = 0
    foreach ($t in @(Get-HUMusterTrash $Settings)) {
        if ($Days -gt 0 -and $t.DeletedAt -gt $Now.AddDays(-$Days)) { continue }
        try { Remove-Item -LiteralPath $t.Folder -Recurse -Force -ErrorAction Stop; $n++ } catch { }
    }
    if ($n) { Write-HULog -Message "Papierkorb der Muster-Bibliothek: $n Paket(e) endgueltig geloescht$(if ($Days -gt 0) { " (aelter als $Days Tage)" })" -Level 'OK' }
    return $n
}

# Bisheriges Muster (_Muster\aktuell) einmalig als Paket uebernehmen. Ohne Netz (Gruppennamen loest der Vergleich weiter live auf).
function Initialize-HUMusterLibrary($Settings) {
    $mr = Get-HUMusterRoot $Settings
    $flag = Join-Path $mr 'bibliothek.json'
    if ((Test-Path -LiteralPath $flag) -or $script:HUMuMigrating) { return $null }
    # Save-HUMusterPackage liest die Bibliothek selbst - Sperre gegen Endlosschleife; Merker erst nach Erfolg (sonst beim naechsten Start erneut)
    $script:HUMuMigrating = $true
    try {
        $m = Get-HUMuster $Settings
        $made = $null
        if ($m) {
            $t = $null; try { $t = [datetime]::ParseExact("$($m.SourceTime)", 'yyyy-MM-dd_HHmmss', $null) } catch { }
            $title = "Gesamtstand $($m.Source)$(if ($t) { ' ' + $t.ToString('dd.MM.yyyy') }) (bisheriges Muster)"
            $existing = @(Get-HUMusterPackages $Settings | Where-Object { (ConvertTo-HUMuName $_.Title) -eq (ConvertTo-HUMuName $title) }) | Select-Object -First 1
            if ($existing) { $made = $existing }
            else {
                $items = @(Get-HUMusterStandItems $m.Folder $m.Source | ForEach-Object { $_.Stand = $m.SourceTime; $_ })
                $r = Save-HUMusterPackage -Settings $Settings -Title $title -Category 'Gesamtstand' -Note "$($m.Note)" -Items $items -Complete -SkipMissing
                $made = $r.Package
                if (@($r.Skipped).Count) { Write-HULog -Message "Bisheriges Muster uebernommen, $(@($r.Skipped).Count) Eintrag/Eintraege ausgelassen: $((@($r.Skipped) | Select-Object -First 5) -join '; ')" -Level 'WARN' }
            }
        }
        New-Item -ItemType Directory -Path $mr -Force | Out-Null
        Write-HUBackupJson $flag ([pscustomobject]@{ Format = 1; Created = (Get-Date).ToString('s'); Migrated = "$(if ($made) { $made.Id })" })
        return $made
    } finally { $script:HUMuMigrating = $false }
}

# Gewaehlte Pakete -> Auswahl fuer Vergleich und Uebertragen ($null = keine gueltigen gewaehlt)
function Get-HUMusterSelection($Settings, [string[]]$Ids) {
    $pk = @(Get-HUMusterPackages $Settings | Where-Object { @($Ids) -contains $_.Id })
    if (-not $pk.Count) { return $null }
    $label = if ($pk.Count -eq 1) { "Muster: $($pk[0].Title)" } else { "Muster: $($pk.Count) Pakete" }
    return [pscustomobject]@{
        Packages = $pk; Ids = @($pk | ForEach-Object { $_.Id }); Folders = @($pk | ForEach-Object { $_.Folder }); Label = $label
        Complete = [bool]@($pk | Where-Object Complete).Count; Sources = @($pk | ForEach-Object { $_.Sources } | Sort-Object -Unique)
        Titles = (@($pk | ForEach-Object { $_.Title }) -join ', ')
    }
}

# Bestand der gewaehlten Pakete (wie Get-HUBackupInventory, Tenant = Muster) - je Zeile zusaetzlich Origin (Quell-Tenant)
# und Paket (Titel), damit Uebertragen und Detailvergleich Namen im richtigen Tenant nachschlagen.
# Gleiche Art+Name in mehreren gewaehlten Paketen: das erste Paket gewinnt (sonst "doppelt" und kein Uebertragen), Hinweis im Protokoll.
function Get-HUMusterInventory([object[]]$Packages) {
    $mk = Get-HUMusterKey
    $seen = @{}
    foreach ($p in @($Packages)) {
        $orig = @{}
        foreach ($it in @($p.Items)) { $orig["$($it.Typ)|$($it.Id)|$(ConvertTo-HUMuName "$($it.Name)")"] = "$($it.Source)" }
        foreach ($r in @(Get-HUBackupInventory -Folder $p.Folder -TenantKey $mk)) {
            $o = "$($orig["$($r.Typ)|$($r.Id)|$(ConvertTo-HUMuName "$($r.Name)")"])"
            $r | Add-Member -NotePropertyName Origin -NotePropertyValue $o -Force
            $r | Add-Member -NotePropertyName Paket -NotePropertyValue $p.Title -Force
            if ("$($r.Name)") {
                $k = "$($r.Typ)|$(ConvertTo-HUMuName "$($r.Name)")"
                if ($seen.ContainsKey($k)) {
                    try { Write-HULog -Message "Muster: $($r.Typ) '$($r.Name)' steht in '$($seen[$k])' und '$($p.Title)' - verglichen wird die Fassung aus '$($seen[$k])'" -Level 'WARN' } catch { }
                    continue
                }
                $seen[$k] = $p.Title
            }
            $r
        }
    }
}

# Conditional Access aus dem Muster gegen die Tenants: Felder, die erst beim Uebertragen aus dem Ziel kommen oder bewusst anders sind,
# zaehlen nicht als Abweichung - Status (Muster immer 'Nur Bericht'), die eingestellten Notfallkonten des Tenants (Sollwert V1) in excludeUsers
# (060 B3: weitere ausgenommene Konten zaehlen), Rollen bei huRollen, Gruppen bei huGruppen.
# Liefert $true, wenn die Tenants untereinander gleich sind und sich vom Muster nur in diesen Feldern unterscheiden.
# Notfallkonten (Sollwert V1) je Tenant, waehrend einer Matrix einmal gelesen (064 B2); $null = kein Sollwert V1
$script:HUMuBgCache = @{}
function Get-HUMusterBreakGlass([string]$TenantKey) {
    if (-not $TenantKey) { return @() }
    if ($script:HUMuBgCache.ContainsKey($TenantKey)) { return $script:HUMuBgCache[$TenantKey] }
    $bg = $null
    try { $bl = Get-HUSecBaseline -TenantKey $TenantKey; if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { $bg = @($bl.Values['V1'].accounts | Where-Object { "$_" } | ForEach-Object { "$_".ToLowerInvariant() }) } } catch { }
    if ($bg -and -not @($bg).Count) { $bg = $null }
    $script:HUMuBgCache[$TenantKey] = $bg
    return $bg
}

function Test-HUMusterCaOnlyTemplateDiff($Row, [string]$MusterKey) {
    if ("$($Row.Typ)" -ne 'Conditional Access') { return $false }
    $items = @($Row.Items | Where-Object { $_.PSObject.Properties['Obj'] -and $null -ne $_.Obj })
    if ($items.Count -ne @($Row.Items).Count) { return $false }
    $mu = @($items | Where-Object { "$($_.Tenant)" -eq $MusterKey }); $tn = @($items | Where-Object { "$($_.Tenant)" -ne $MusterKey })
    if ($mu.Count -ne 1 -or -not $tn.Count) { return $false }
    $mo = $mu[0].Obj
    $ign = @('state')
    if ($mo.PSObject.Properties['huRollen'] -and "$($mo.huRollen)") { $ign += 'conditions.users.excludeRoles', 'conditions.users.includeRoles' }
    if ($mo.PSObject.Properties['huGruppen'] -and $mo.huGruppen) { $ign += 'conditions.users.includeGroups', 'conditions.users.excludeGroups' }
    $rx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $flat = {
        param($o, [string[]]$Skip)
        $f = ConvertTo-HUFlatMap $o; $n = @{}
        foreach ($k in $f.Keys) { $nk = [regex]::Replace("$k", $rx, '#id'); if ($Skip -contains $nk) { continue }; $n[$nk] = [regex]::Replace("$($f[$k])", $rx, '#id') }
        $n
    }
    # excludeUsers ohne die Notfallkonten des Tenants (Sollwert V1) - so wie es beim Uebertragen entstuende
    $exu = {
        param($o, [string]$TenantKey)
        $bg = @(Get-HUMusterBreakGlass $TenantKey)
        $l = @()
        try { $l = @($o.conditions.users.excludeUsers | Where-Object { "$_" -and $bg -notcontains "$_".ToLowerInvariant() }) } catch { }
        if (-not $l.Count) { return '(leer)' }
        return ((@($l | ForEach-Object { [regex]::Replace("$_", $rx, '#id') } | Sort-Object)) -join ', ')
    }
    try {
        # Tenants untereinander: alle Felder, excludeUsers ohne die Notfallkonten des jeweiligen Tenants (064 B2)
        if (@($tn | ForEach-Object { $_.Hash } | Select-Object -Unique).Count -gt 1) {
            $maps = @{}; $ks = @(); for ($i = 0; $i -lt $tn.Count; $i++) { $tmi = & $flat $tn[$i].Obj @(); $tmi['conditions.users.excludeUsers'] = & $exu $tn[$i].Obj "$($tn[$i].Tenant)"; $maps["t$i"] = $tmi; $ks += "t$i" }
            if (@(Get-HUCompareDiff $maps $ks).Count) { return $false }
        }
        # Muster gegen jeden Tenant ohne die Vorlagen-Felder; excludeUsers ohne Notfallkonten des jeweiligen Tenants
        $mm = & $flat $mo $ign; $mm['conditions.users.excludeUsers'] = & $exu $mo ''
        foreach ($t in $tn) {
            $tm = & $flat $t.Obj $ign; $tm['conditions.users.excludeUsers'] = & $exu $t.Obj "$($t.Tenant)"
            if (@(Get-HUCompareDiff @{ m = $mm; t = $tm } @('m', 't')).Count) { return $false }
        }
        return $true
    } catch { return $false }
}

# Vergleichsmatrix mit Muster-Spalte. -Partial (nur Teilpakete gewaehlt): Was nicht im Paket ist, zaehlt nicht als Abweichung -
# die Zeile wird nur unter den Tenants bewertet und bekommt NotInPkg = $true (Zelle "nicht im Paket").
function Get-HUMusterMatrix([object[]]$Rows, [string[]]$Keys, [switch]$Partial) {
    $mk = Get-HUMusterKey
    $m = @(Get-HUCompareMatrix $Rows $Keys)
    $script:HUMuBgCache = @{}
    # CA: nur Status/Notfallkonten/Platzhalter anders als im Muster -> nicht als abweichend zaehlen
    if ($Keys -contains $mk) {
        foreach ($r in $m) {
            if ("$($r.Status)" -like '*Einstellungen abweichend*' -and @($r.Have) -contains $mk -and (Test-HUMusterCaOnlyTemplateDiff $r $mk)) {
                $r.Status = ("$($r.Status)" -replace ', Einstellungen abweichend', '') + ' (wie Muster; Status und Notfallkonten kommen aus dem Tenant)'
                $r.Diff = (@($r.Missing).Count -gt 0 -or @($r.Unknown).Count -gt 0 -or $r.Dupe)
            }
            elseif ("$($r.Typ)" -eq 'Conditional Access' -and "$($r.Status)" -like '*Einstellungen abweichend*' -and @($r.Have) -contains $mk) {
                # Grund nennen, wenn Notfallkonten nicht abgezogen werden koennen (064 B2)
                $noV1 = @(@($r.Have) | Where-Object { "$_" -ne $mk -and $null -eq (Get-HUMusterBreakGlass "$_") })
                if ($noV1.Count) { $r.Status = "$($r.Status) (Sollwert V1 fehlt: $($noV1 -join ', '))" }
            }
        }
    }
    if (-not $Partial -or $Keys -notcontains $mk) { return $m }
    $others = @($Keys | Where-Object { $_ -ne $mk })
    $errs = @($Rows | Where-Object { $_.PSObject.Properties['Error'] -and $_.Error })
    foreach ($r in $m) {
        if (@($r.Have) -contains $mk) { $r | Add-Member -NotePropertyName NotInPkg -NotePropertyValue $false -Force; $r; continue }
        $r2 = @(Get-HUCompareMatrix (@($r.Items) + $errs) $others) | Select-Object -First 1
        if (-not $r2) { $r | Add-Member -NotePropertyName NotInPkg -NotePropertyValue $true -Force; $r; continue }
        $r2 | Add-Member -NotePropertyName NotInPkg -NotePropertyValue $true -Force
        $r2
    }
}

Export-ModuleMember -Function Get-HUMusterBuiltinRoot, Set-HUMusterBuiltinRoot, Get-HUMusterBuiltinSource, Test-HUMusterBuiltinSource, Get-HUMusterResolveKey, Get-HUMusterBuiltinPackages,
    Get-HUMusterKey, Get-HUMusterRoot, Get-HUMuster, Save-HUMuster, Get-HUNameMap, ConvertTo-HUMuName,
    Get-HUMusterCategories, Get-HUMusterPkgRoot, ConvertTo-HUMusterTags, Get-HUMusterNameMap, Resolve-HUMusterName, Get-HUMusterTagNames, Get-HUMusterLocationNames,
    Get-HUMusterPackages, Get-HUMusterPackage, Get-HUMusterNameCatalog, Save-HUMusterPackage, Get-HUMusterPackageItems, Get-HUMusterStandItems,
    New-HUMusterPackageFromStand, Remove-HUMusterPackage, Initialize-HUMusterLibrary, Get-HUMusterTrashRoot, Get-HUMusterTrash, Restore-HUMusterPackage, Remove-HUMusterTrashItem, Clear-HUMusterTrash, Get-HUMusterSelection, Get-HUMusterInventory, Get-HUMusterMatrix, Test-HUMusterCaOnlyTemplateDiff
