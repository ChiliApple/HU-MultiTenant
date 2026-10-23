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

# Verweise einer Quelle sammeln: Liste @{ Art; Id; Name; Used } (Name aus dem Stand, wo moeglich)
function Get-HUMuRefs([string]$Folder) {
    $ix = Read-HUBackupJson (Join-Path $Folder 'index.json')
    $objs = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($ix.Items)) { if ("$($it.File)") { try { $objs.Add([pscustomobject]@{ Typ = "$($it.Typ)"; Name = "$($it.Name)"; Id = "$($it.Id)"; O = (Read-HUBackupJson (Join-Path $Folder $it.File)) }) } catch { } } }
    $names = @{}
    foreach ($x in $objs) { if ($x.Typ -in 'Benannter Ort', 'Zuweisungsfilter', 'Bereichsmarkierung') { $names["$($x.Typ)|$("$($x.Id)".ToLowerInvariant())"] = $x.Name } }
    $refs = @{}
    $add = {
        param([string]$Art, [string]$Id, [string]$Name, [string]$Used)
        if (-not $Id) { return }
        $k = "$Art|$($Id.ToLowerInvariant())"
        if (-not $refs.ContainsKey($k)) { $refs[$k] = [pscustomobject]@{ Art = $Art; Id = $Id; Name = $Name; Used = (New-Object System.Collections.Generic.List[string]) } }
        if (-not $refs[$k].Used.Contains($Used)) { $refs[$k].Used.Add($Used) }
    }
    foreach ($x in $objs) {
        $used = "$($x.Typ): $($x.Name)"
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
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$SourceKey, [Parameter(Mandatory)][string[]]$Targets, [hashtable]$Names = @{})
    $refs = @(Get-HUMuRefs $Folder)
    # Notfallkonten der Quelle (Sollwert V1) - werden beim Uebertragen durch die des Ziels ersetzt (Ue-3)
    $bgSrc = @()
    try { $bl = Get-HUSecBaseline -TenantKey $SourceKey; if ($bl -and $bl.Values -and $bl.Values.ContainsKey('V1')) { $bgSrc = @($bl.Values['V1'].accounts | ForEach-Object { "$_".ToLowerInvariant() }) } } catch { }
    # Gruppennamen in der Quelle nachschlagen (der Stand enthaelt nur IDs)
    foreach ($r in @($refs | Where-Object { $_.Art -eq 'Gruppe' -and -not $_.Name })) {
        try { $g = Invoke-HUIntuneGraph -TenantKey $SourceKey -Settings $Settings -Endpoint "/groups/$($r.Id)?`$select=displayName" -V1 -NoRetry; $r.Name = "$($g.displayName)" }
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

Export-ModuleMember -Function Get-HUMusterKey, Get-HUMusterRoot, Get-HUMuster, Save-HUMuster, Get-HUNameMap, ConvertTo-HUMuName
