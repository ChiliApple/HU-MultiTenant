#Requires -Version 5.1
<#
.SYNOPSIS
    Muster anwenden (2.5.2): angehakte Pakete in genau einen Ziel-Tenant uebertragen - Rechte-Bedarf, Absturz-Markierung,
    Sperre je Tenant, Paket-Plan (Neu / Angleichen / Gesperrt), Ausfuehren in fester Reihenfolge und Paket-Rueckgaengig.
.DESCRIPTION
    Baut auf den bestehenden Plan-/Ausfuehrungs-Funktionen auf (HU.Transfer fuer Intune, HU.EntraRestore fuer Entra und
    Conditional Access) - dieselben Sperren und Nachpruefungen wie beim Uebertragen aus dem Tenant-Vergleich.
    Reihenfolge: Benannte Orte -> Entra-Einstellungen -> Intune -> Conditional Access (Rueckgaengig umgekehrt).
    Markierung %APPDATA%\HU-MultiTenant\muster-rechte-<Tenant>.json wird VOR dem Erteilen geschrieben und erst nach dem
    Zurueckgeben geloescht; Sperre muster-sperre-<Tenant>.lock mit Prozess-ID (verwaiste Sperre wird erkannt).
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Logik ohne Oberflaeche (Oberflaeche: Functions\UI-MusterApply.ps1).
#>

$script:HUMaStateRoot = Join-Path $(if ($env:APPDATA) { $env:APPDATA } else { [IO.Path]::GetTempPath() }) 'HU-MultiTenant'
function Set-HUMaStateRoot([string]$Path) { $script:HUMaStateRoot = $Path }
function Get-HUMaStateRoot { return $script:HUMaStateRoot }

# Schreibrechte je Art (Microsoft Learn: create-Endpunkte, kleinstes Anwendungsrecht)
$script:HUMaIntunePerm = @{ 'Wartung' = 'DeviceManagementScripts.ReadWrite.All'; 'Plattform-Skript' = 'DeviceManagementScripts.ReadWrite.All' }
$script:HUMaEntraPerm = @{ authz = 'Policy.ReadWrite.Authorization'; consent = 'Policy.ReadWrite.ConsentRequest'; location = 'Policy.ReadWrite.ConditionalAccess'; caNew = 'Policy.ReadWrite.ConditionalAccess'; groupSetting = 'GroupSettings.ReadWrite.All' }
$script:HUMaIntuneTypes = @('Konfiguration', 'Einstellungskatalog', 'Administrative Vorlage', 'Compliance', 'Wartung', 'Plattform-Skript', 'Feature-Update')

function ConvertTo-HUMaSafe([string]$Key) { return ("$Key" -replace '[^A-Za-z0-9_.-]', '_') }

# Art eines Muster-Eintrags: Entra-Art (authz, consent, location, groupSetting, caNew), 'intune' oder '' (nicht anwendbar)
function Get-HUMaItemKind([string]$Typ, [string]$Id) {
    $ek = Get-HUEntraRestoreKind $Typ $Id
    if ($ek) { return $ek }
    if ($script:HUMaIntuneTypes -contains $Typ) { return 'intune' }
    return ''
}
function Get-HUMaPermission([string]$Typ, [string]$Id) {
    $k = Get-HUMaItemKind $Typ $Id
    if (-not $k) { return '' }
    if ($k -eq 'intune') { if ($script:HUMaIntunePerm.ContainsKey($Typ)) { return $script:HUMaIntunePerm[$Typ] }; return 'DeviceManagementConfiguration.ReadWrite.All' }
    return "$($script:HUMaEntraPerm[$k])"
}
function Get-HUMaNeededPermissions([object[]]$Items) {
    return @(@($Items) | Where-Object { $_ } | ForEach-Object { Get-HUMaPermission "$($_.Typ)" "$($_.Id)" } | Where-Object { $_ } | Sort-Object -Unique)
}
# feste Reihenfolge: Orte zuerst (CA verweist darauf), Conditional Access zuletzt
function Get-HUMaOrder([string]$Typ, [string]$Id) {
    switch (Get-HUMaItemKind $Typ $Id) { 'location' { return 10 } { $_ -in 'authz', 'consent', 'groupSetting' } { return 20 } 'intune' { return 30 } 'caNew' { return 40 } default { return 99 } }
}

# erteilte Anwendungsrechte im Token des Ziels (frisch geholt - neu erteilte Rechte stehen erst im naechsten Token); $null = nicht lesbar
function Get-HUMaTokenRoles([string]$TenantKey, $Settings) {
    try {
        try { Clear-TokenCache -TenantKey $TenantKey } catch { }
        $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ForceRefresh -ErrorAction Stop
        if ($tok) { return @(Get-TokenPermissions -Token $tok) }
    } catch { }
    return $null
}
# Rechte-Ampel: je benoetigtes Recht vorhanden/fehlt
function Get-HUMaRightsRows([string[]]$Needed, $Roles) {
    return @(foreach ($n in @($Needed)) { [pscustomobject]@{ Recht = $n; Status = $(if ($null -eq $Roles) { 'unbekannt' } elseif (@($Roles) -contains $n) { 'vorhanden' } else { 'fehlt' }) } })
}

# ---------------------------------------------------------------- Markierung (Absturz-Sicherung) und Sperre
function Get-HUMaMarkerFile([string]$TenantKey) { return (Join-Path $script:HUMaStateRoot "muster-rechte-$(ConvertTo-HUMaSafe $TenantKey).json") }
function Write-HUMaMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [string]$TenantName = '', [string[]]$Planned = @(), [string[]]$Added = @(), [string]$Stage = 'vor dem Erteilen')
    $f = Get-HUMaMarkerFile $TenantKey
    $old = Get-HUMaMarker $TenantKey
    # PS 7 macht aus ISO-Datumstexten beim Lesen DateTime - immer als ISO-Text weitergeben
    $since = if ($old -and "$($old.Since)") { "$($old.Since)" } else { (Get-Date).ToString('s') }
    # schon gemerkte (hinzugefuegte) Rechte nie verlieren - auch wenn ein zweiter Durchgang weniger meldet
    $add = @(@($(if ($old) { $old.Added })) + @($Added) | Where-Object { "$_" } | ForEach-Object { "$_" } | Sort-Object -Unique)
    $pl = @(@($(if ($old) { $old.Planned })) + @($Planned) | Where-Object { "$_" } | ForEach-Object { "$_" } | Sort-Object -Unique)
    if (-not (Test-Path -LiteralPath $script:HUMaStateRoot)) { New-Item -ItemType Directory -Path $script:HUMaStateRoot -Force | Out-Null }
    $o = [pscustomobject]@{ Format = 1; Tenant = $TenantKey; TenantName = $TenantName; Since = $since; Changed = (Get-Date).ToString('s'); Planned = [object[]]$pl; Added = [object[]]$add; Stage = $Stage; Pid = $PID; Host = "$env:COMPUTERNAME" }
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return $o
}
function Get-HUMaMarker([string]$TenantKey) {
    $f = Get-HUMaMarkerFile $TenantKey
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (ConvertTo-HUMaIsoMarker (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch { return $null }
}
# PS 7 liest ISO-Zeiten als DateTime - in der Markierung immer als ISO-Text fuehren
function ConvertTo-HUMaIsoMarker($M) {
    if (-not $M) { return $M }
    foreach ($n in 'Since', 'Changed') { if ($M.PSObject.Properties[$n] -and $M.$n -is [datetime]) { $M.$n = $M.$n.ToString('s') } }
    return $M
}
function Get-HUMaMarkers {
    if (-not (Test-Path -LiteralPath $script:HUMaStateRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:HUMaStateRoot -File -Filter 'muster-rechte-*.json' | ForEach-Object {
            try { ConvertTo-HUMaIsoMarker (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $null } } | Where-Object { $_ -and "$($_.Tenant)" })
}
function Remove-HUMaMarker([string]$TenantKey) {
    $f = Get-HUMaMarkerFile $TenantKey
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

function Get-HUMaLockFile([string]$TenantKey) { return (Join-Path $script:HUMaStateRoot "muster-sperre-$(ConvertTo-HUMaSafe $TenantKey).lock") }
# Sperre je Tenant: zweite Instanz im selben Tenant ablehnen; Sperre eines beendeten Prozesses gilt als verwaist
function Enter-HUMaLock([string]$TenantKey) {
    $f = Get-HUMaLockFile $TenantKey
    if (Test-Path -LiteralPath $f) {
        $l = $null; try { $l = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        $lp = 0; if ($l -and "$($l.Pid)" -match '^\d+$') { $lp = [int]$l.Pid }
        if ($lp -and $lp -ne $PID -and "$($l.Host)" -eq "$env:COMPUTERNAME" -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) {
            throw "Fuer diesen Tenant laeuft 'Muster anwenden' schon in einem anderen Fenster (Prozess $lp, seit $($l.Time))."
        }
    }
    if (-not (Test-Path -LiteralPath $script:HUMaStateRoot)) { New-Item -ItemType Directory -Path $script:HUMaStateRoot -Force | Out-Null }
    [IO.File]::WriteAllText($f, ([pscustomobject]@{ Tenant = $TenantKey; Pid = $PID; Host = "$env:COMPUTERNAME"; Time = (Get-Date).ToString('s') } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
function Exit-HUMaLock([string]$TenantKey) {
    $f = Get-HUMaLockFile $TenantKey
    if (-not (Test-Path -LiteralPath $f)) { return }
    $l = $null; try { $l = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $l -or "$($l.Pid)" -eq "$PID") { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- Paket-Plan
# Ein Muster-Eintrag fuer ein Ziel planen (liest nur). Rueckgabe: Zeile mit Status neu | angleichen | gleich | wartet | gesperrt.
function Get-HUMaRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$TargetKey, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Item,
        [hashtable]$LocNames = @{}, [string[]]$PendingLocations = @())
    $typ = "$($Item.Typ)"; $id = "$($Item.Id)"; $kind = Get-HUMaItemKind $typ $id
    $row = [pscustomobject]@{ Order = (Get-HUMaOrder $typ $id); Typ = $typ; Name = "$($Item.Name)"; Paket = "$($Package.Title)"; PaketId = "$($Package.Id)"; Kind = $kind
        Status = 'gesperrt'; Default = $false; Plan = $null; Reason = ''; Folder = "$($Package.Folder)"; File = "$($Item.File)"; Id = $id; Source = "$($Item.Source)" }
    if (-not $kind) { $row.Reason = "$typ wird (noch) nicht angewendet."; return $row }
    $obj = $null
    try { $obj = Read-HUBackupJson (Join-Path $Package.Folder $Item.File) } catch { $row.Reason = "Muster-Datei nicht lesbar ($($_.Exception.Message))."; return $row }
    $label = "Muster: $($Package.Title)"
    $plan = $null
    try {
        if ($kind -eq 'intune') {
            $rk = Get-HUMusterResolveKey $Settings $row.Source
            $tags = Get-HUMusterTagNames @($Package.Folder) $row.Source
            $plan = Get-HUTransferPlan -Settings $Settings -Typ $typ -SourceObj $obj -SourceKey (Get-HUMusterKey) -ResolveKey $rk -SourceLabel $label -TargetKey $TargetKey -SourceTagNames $tags
            # gibt es den Namen im Ziel schon -> angleichen (bestehendes Objekt; Zuweisungen des Ziels bleiben)
            if (@($plan.Blocks | Where-Object { "$_" -like '*gibt es im Ziel schon*' }).Count) {
                $src = @(Get-HUCompareSources | Where-Object { $_.Typ -eq $typ })[0]
                $np = if ($src) { $src.Name } else { 'displayName' }
                $hit = @(Get-HUIntuneGraphAll -TenantKey $TargetKey -Settings $Settings -Endpoint "$($src.Ep -replace '\?.*$', '')?`$select=id,$np" | Where-Object { "$($_.$np)".Trim().ToLowerInvariant() -eq $row.Name.Trim().ToLowerInvariant() })
                if ($hit.Count -eq 1) { $plan = Get-HUTransferAlignPlan -Settings $Settings -Typ $typ -SourceObj $obj -SourceKey (Get-HUMusterKey) -ResolveKey $rk -SourceLabel $label -TargetKey $TargetKey -TargetId "$($hit[0].id)" }
                elseif ($hit.Count -gt 1) { $plan.Blocks.Add("'$($row.Name)' gibt es im Ziel $($hit.Count)-mal - nicht eindeutig.") }
            }
        } else {
            $plan = Get-HUEntraTransferPlan -TargetKey $TargetKey -Settings $Settings -Typ $typ -Id $id -Name $row.Name -Backup $obj -ResolveKey $row.Source -SourceLabel $label -SourceNames $LocNames
        }
    } catch { $row.Reason = "Plan nicht moeglich: $($_.Exception.Message)"; return $row }
    $row.Plan = $plan
    $blocks = @($plan.Blocks | ForEach-Object { "$_" })
    if (-not $blocks.Count) {
        $isAlign = ("$($plan.Kind)" -eq 'transferAlign') -or ($kind -ne 'intune' -and "$($plan.Method)" -ne 'POST')
        if ($isAlign -and -not @($plan.Changes | Where-Object { $null -ne $_.Expected }).Count) { $row.Status = 'gleich'; $row.Reason = 'Im Ziel schon gleich.'; return $row }
        $row.Status = $(if ($isAlign) { 'angleichen' } else { 'neu' })
        # neu = an; angleichen (bestehendes Objekt aendern) und CA-Zusatzrichtlinie "(von Muster)" = bewusst anhaken
        $dup = ($kind -eq 'caNew' -and $plan.Body -and "$($plan.Body.displayName)" -like '*(von Muster)')
        $row.Default = ($row.Status -eq 'neu' -and -not $dup)
        if ($dup) { $row.Reason = "Gibt es im Ziel schon - wuerde zusaetzlich als '$($plan.Body.displayName)' angelegt." }
        return $row
    }
    if (@($blocks | Where-Object { $_ -like '*schon gleich wie im Muster*' }).Count -eq $blocks.Count) { $row.Status = 'gleich'; $row.Reason = 'Im Ziel schon gleich.'; return $row }
    # Conditional Access wartet auf einen Ort, der im selben Durchgang neu angelegt wird
    $pend = @($PendingLocations | ForEach-Object { "$_".Trim().ToLowerInvariant() })
    $locBlocks = @($blocks | Where-Object { $_ -match "^Den Ort '(.+)' gibt es im Ziel nicht" })
    $rest = @($blocks | Where-Object { $_ -notmatch "^Den Ort '(.+)' gibt es im Ziel nicht" })
    if ($kind -eq 'caNew' -and $locBlocks.Count -and -not $rest.Count -and -not @($locBlocks | Where-Object { $pend -notcontains ([regex]::Match($_, "^Den Ort '(.+?)' gibt es").Groups[1].Value.Trim().ToLowerInvariant()) }).Count) {
        $row.Status = 'wartet'; $row.Default = $true; $row.Reason = 'Wird nach dem Ort angelegt (im selben Durchgang).'
        return $row
    }
    $row.Reason = ($blocks -join ' ')
    return $row
}

# alle Eintraege der gewaehlten Pakete planen (gleiche Art + Name: das erste Paket gewinnt)
function Get-HUMaPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$TargetKey, [Parameter(Mandatory)][object[]]$Packages)
    $seen = @{}; $todo = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Packages)) {
        foreach ($it in @($p.Items)) {
            $k = "$($it.Typ)|$("$($it.Name)".Trim().ToLowerInvariant())"
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true; $todo.Add([pscustomobject]@{ P = $p; I = $it })
        }
    }
    $locNames = Get-HUMusterLocationNames @($Packages | ForEach-Object { $_.Folder })
    $rows = New-Object System.Collections.Generic.List[object]
    # Orte zuerst planen: neu anzulegende Orte duerfen von CA im selben Durchgang verwendet werden
    foreach ($t in @($todo | Sort-Object { Get-HUMaOrder "$($_.I.Typ)" "$($_.I.Id)" })) {
        $pending = @($rows | Where-Object { $_.Kind -eq 'location' -and $_.Status -eq 'neu' -and $_.Default } | ForEach-Object { $_.Name })
        $rows.Add((Get-HUMaRow -Settings $Settings -TargetKey $TargetKey -Package $t.P -Item $t.I -LocNames $locNames -PendingLocations $pending))
    }
    return @($rows | Sort-Object Order, Typ, Name)
}

# Auswahl aus dem Schritt "Zuordnen" in einen Plan uebernehmen: Gruppen je Platz (Slot -> Gruppen-Id), Laender (Code -> an/aus)
function Set-HUMaChoices($Plan, [hashtable]$Groups = @{}, [hashtable]$Countries = @{}) {
    if (-not $Plan -or -not $Plan.PSObject.Properties['Options']) { return }
    foreach ($o in @($Plan.Options | Where-Object { $_ })) {
        if ("$($o.Kind)" -eq 'group' -and $Groups.ContainsKey("$($o.Slot)")) { $o.Value = "$($Groups["$($o.Slot)"])" }
        elseif ("$($o.Key)" -like 'country:*' -and $Countries.ContainsKey("$($o.Key)".Substring(8))) { $o.Value = [bool]$Countries["$($o.Key)".Substring(8)] }
    }
}
# Plaetze und Laender aller Zeilen fuer den Schritt "Zuordnen" (je Platzname einmal)
function Get-HUMaSlots([object[]]$Rows) {
    $slots = [ordered]@{}; $countries = [ordered]@{}
    foreach ($r in @($Rows | Where-Object { $_.Plan -and $_.Status -ne 'gesperrt' -and $_.Plan.PSObject.Properties['Options'] })) {
        foreach ($o in @($r.Plan.Options | Where-Object { $_ })) {
            if ("$($o.Kind)" -eq 'group') {
                $s = "$($o.Slot)"
                if (-not $slots.Contains($s)) { $slots[$s] = [pscustomobject]@{ Slot = $s; Feld = "$($o.Feld)"; Value = "$($o.Value)"; Choices = @($o.Choices); Used = (New-Object System.Collections.Generic.List[string]) } }
                if (-not $slots[$s].Used.Contains($r.Name)) { $slots[$s].Used.Add($r.Name) }
            } elseif ("$($o.Key)" -like 'country:*') {
                $c = "$($o.Key)".Substring(8)
                if (-not $countries.Contains($c)) { $countries[$c] = [pscustomobject]@{ Code = $c; Text = "$($o.Text)"; Value = [bool]$o.Value; Ort = $r.Name } }
            }
        }
    }
    return [pscustomobject]@{ Slots = @($slots.Values); Countries = @($countries.Values) }
}

# ---------------------------------------------------------------- Durchgang (Paket-Rueckgaengig)
function Get-HUMaRunDir($Settings, [string]$TenantKey) { return (Join-Path (Join-Path (Join-Path (Get-HUBackupRoot $Settings) '_Muster') 'anwenden') (ConvertTo-HUMaSafe $TenantKey)) }
function New-HUMaRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$TenantKey, [string[]]$Packages = @(), [string]$Actor = "$env:USERNAME", [datetime]$Now = (Get-Date))
    $d = Get-HUMaRunDir $Settings $TenantKey
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $run = [pscustomobject]@{ Format = 1; Tenant = $TenantKey; Time = $Now.ToString('s'); By = $Actor; Packages = [object[]]@($Packages); State = 'laeuft'; Steps = [object[]]@(); File = (Join-Path $d "$($Now.ToString('yyyy-MM-dd_HHmmss'))_anwenden.json") }
    Save-HUMaRun $run
    return $run
}
function Save-HUMaRun($Run) { Write-HUBackupJson $Run.File $Run }
function Add-HUMaRunStep($Run, [string]$Typ, [string]$Name, [bool]$Ok, [string]$UndoFile = '', [string]$Text = '') {
    $Run.Steps = [object[]](@($Run.Steps) + @([pscustomobject]@{ Typ = $Typ; Name = $Name; Ok = $Ok; UndoFile = $UndoFile; Text = $Text; Time = (Get-Date).ToString('s') }))
    Save-HUMaRun $Run
}
function Complete-HUMaRun($Run, [string]$State) { $Run.State = $State; Save-HUMaRun $Run }
function Get-HUMaRuns($Settings, [string]$TenantKey) {
    $d = Get-HUMaRunDir $Settings $TenantKey
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    return @(Get-ChildItem -LiteralPath $d -File -Filter '*_anwenden.json' | Sort-Object Name -Descending | ForEach-Object { try { $r = Read-HUBackupJson $_.FullName; $r | Add-Member -NotePropertyName File -NotePropertyValue $_.FullName -Force; $r } catch { } })
}
# Paket rueckgaengig: alle Schritte mit Rueckgaengig-Datei in umgekehrter Reihenfolge (CA -> Intune -> Entra -> Orte).
# Jeder Schritt mit denselben Sperren wie das einzelne Rueckgaengig (geaendert/zugewiesen/eingeschaltet = nicht automatisch).
function Undo-HUMaRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$File, [switch]$CheckOnly)
    $run = Read-HUBackupJson $File
    $res = New-Object System.Collections.Generic.List[object]
    $all = @($run.Steps | Where-Object { $_ -and "$($_.UndoFile)" })
    $steps = @(for ($i = $all.Count - 1; $i -ge 0; $i--) { $all[$i] })
    foreach ($s in $steps) {
        $uf = "$($s.UndoFile)"
        if (-not (Test-Path -LiteralPath $uf)) {
            $done = @(($uf -replace '\.json$', '.rueckgaengig.json'), ($uf -replace '\.json$', '.erledigt.json')) | Where-Object { Test-Path -LiteralPath $_ }
            $res.Add([pscustomobject]@{ Typ = "$($s.Typ)"; Name = "$($s.Name)"; Ok = [bool]$done.Count; Text = $(if ($done.Count) { 'schon rueckgaengig' } else { 'Rueckgaengig-Datei fehlt' }) }); continue
        }
        try { $r = Undo-HUTransfer -Settings $Settings -File $uf -CheckOnly:$CheckOnly; $res.Add([pscustomobject]@{ Typ = "$($s.Typ)"; Name = "$($s.Name)"; Ok = $true; Text = "$($r.Text)" }) }
        catch { $res.Add([pscustomobject]@{ Typ = "$($s.Typ)"; Name = "$($s.Name)"; Ok = $false; Text = "$($_.Exception.Message)" }) }
    }
    if (-not $CheckOnly -and -not @($res | Where-Object { -not $_.Ok }).Count) {
        $run.State = 'rueckgaengig'; Write-HUBackupJson $File $run
    }
    return $res.ToArray()
}

# Einen Schritt ausfuehren: frisch planen (Stand im Ziel kann sich seit der Vorschau geaendert haben, z. B. neu angelegter Ort),
# Auswahl uebernehmen, bei Sperren nichts schreiben. Ergebnis wird im Durchgang festgehalten.
function Invoke-HUMaStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$TargetKey, [Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Run,
        [hashtable]$Groups = @{}, [hashtable]$Countries = @{}, [hashtable]$LocNames = @{}, [string]$Actor = "$env:USERNAME")
    $pkg = [pscustomobject]@{ Title = $Row.Paket; Id = $Row.PaketId; Folder = $Row.Folder }
    $it = [pscustomobject]@{ Typ = $Row.Typ; Name = $Row.Name; Id = $Row.Id; File = $Row.File; Source = $Row.Source }
    $fresh = Get-HUMaRow -Settings $Settings -TargetKey $TargetKey -Package $pkg -Item $it -LocNames $LocNames
    if (-not $fresh.Plan -or $fresh.Status -in 'gesperrt', 'wartet') { $t = "Nicht angewendet: $($fresh.Reason)"; Add-HUMaRunStep $Run $Row.Typ $Row.Name $false '' $t; return [pscustomobject]@{ Ok = $false; Text = $t } }
    if ($fresh.Status -eq 'gleich') { Add-HUMaRunStep $Run $Row.Typ $Row.Name $true '' 'Im Ziel schon gleich - nichts geschrieben.'; return [pscustomobject]@{ Ok = $true; Text = 'schon gleich' } }
    Set-HUMaChoices $fresh.Plan $Groups $Countries
    try {
        $by = "$Actor (Muster anwenden)"
        $r = if ($fresh.Kind -ne 'intune') { Invoke-HUEntraTransfer -Plan $fresh.Plan -Settings $Settings -Actor $by }
        elseif ("$($fresh.Plan.Kind)" -eq 'transferAlign') { Invoke-HUTransferAlign -Plan $fresh.Plan -Settings $Settings -Actor $by }
        else { Invoke-HUTransfer -Plan $fresh.Plan -Settings $Settings -Actor $by }
        $mm = @($(if ($r.PSObject.Properties['Mismatch']) { $r.Mismatch }) | Where-Object { $_ })
        $t = $(if ($mm.Count) { "Geschrieben, Nachpruefung abweichend: $(@($mm | Select-Object -First 3) -join '; ')" } else { $(if ($fresh.Status -eq 'neu') { 'neu angelegt' } else { 'angeglichen' }) })
        Add-HUMaRunStep $Run $Row.Typ $Row.Name ([bool]$r.Ok) "$(if ($r.PSObject.Properties['UndoFile']) { $r.UndoFile })" $t
        return [pscustomobject]@{ Ok = [bool]$r.Ok; Text = $t }
    } catch {
        $t = "Fehler: $($_.Exception.Message)"
        Add-HUMaRunStep $Run $Row.Typ $Row.Name $false '' $t
        return [pscustomobject]@{ Ok = $false; Text = $t }
    }
}

Export-ModuleMember -Function Get-HUMaTokenRoles, Get-HUMaRightsRows, Set-HUMaStateRoot, Get-HUMaStateRoot, Get-HUMaItemKind, Get-HUMaPermission, Get-HUMaNeededPermissions, Get-HUMaOrder,
    Get-HUMaMarkerFile, Write-HUMaMarker, Get-HUMaMarker, Get-HUMaMarkers, Remove-HUMaMarker, Enter-HUMaLock, Exit-HUMaLock,
    Get-HUMaRow, Get-HUMaPlan, Set-HUMaChoices, Get-HUMaSlots, Get-HUMaRunDir, New-HUMaRun, Save-HUMaRun, Add-HUMaRunStep, Complete-HUMaRun, Get-HUMaRuns, Undo-HUMaRun, Invoke-HUMaStep
