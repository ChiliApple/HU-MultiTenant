#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Wartung", Ansicht "In Intune": vorhandene Wartungsskripte (Remediations) der angehakten Tenants verwalten -
    Zuweisungen mit Zeitplan, Skripte und Eigenschaften, Ergebnisse, sofort ausfuehren, in die Bibliothek holen, Loeschen.
.DESCRIPTION
    Bei mehreren Tenants werden Skripte gleichen Namens zusammengefasst; jede Aenderung wird in allen Tenants ausgefuehrt,
    in denen es das Skript gibt. Skripte von Microsoft (isGlobalScript) koennen nur gelesen und zugewiesen werden.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:RemMode = 'lib'
$script:RintRaw = @{}          # TenantKey -> @{ Rows = object[]; Error = ''; Time }
$script:RintItems = @()
$script:RintCurrent = $null
$script:RintDetail = @{}       # TenantKey -> Detail (Skripte, Zuweisungen, Zusammenfassung)
$script:RintDetailKey = ''
$script:RintDetailPending = $false
$script:RintLoadThen = $null
$script:RintGen = 0
$script:RintEditorFrom = ''
$script:RintDetailWait = New-Object System.Collections.Generic.List[string]

# ----------------------------------------------------------------------------
# Ansicht umschalten
# ----------------------------------------------------------------------------
function Set-HURemMode([string]$Mode) {
    $c = $script:Controls
    $script:RemMode = $Mode
    $int = ($Mode -eq 'int')
    $c['pnlRemLibLeft'].Visibility = $(if ($int) { 'Collapsed' } else { 'Visible' })
    $c['pnlRemLibRight'].Visibility = $c['pnlRemLibLeft'].Visibility
    $c['pnlRemIntLeft'].Visibility = $(if ($int) { 'Visible' } else { 'Collapsed' })
    $c['pnlRemIntRight'].Visibility = $c['pnlRemIntLeft'].Visibility
    $c['btnRemModeLib'].Background = Get-HUBrush $(if ($int) { '#3E3E42' } else { '#1976D2' })
    $c['btnRemModeInt'].Background = Get-HUBrush $(if ($int) { '#1976D2' } else { '#3E3E42' })
    if ($int) {
        if (-not $c['spRintTenants'].Children.Count) { Update-HURintTenantChecks }
        Start-HURintLoad
        Update-HURintList
    }
}

function Update-HURintTenantChecks {
    $sp = $script:Controls['spRintTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'rintTenants' @())
    if (-not $saved.Count) { $k = "$(Get-SelectedTenantKey)"; if ($k) { $saved = @($k) } elseif (@($script:Settings.tenants).Count) { $saved = @("$(@($script:Settings.tenants)[0].key)") } }
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ if (-not $script:TenantToggleBusy) { Save-HURintTenants } })
        $cb.Add_Unchecked({ if (-not $script:TenantToggleBusy) { Save-HURintTenants } })
        [void]$sp.Children.Add($cb)
    }
    if (@($script:Settings.tenants).Count -gt 1) { Add-HUTenantAllToggle $sp { Save-HURintTenants } }
}

function Get-HURintTenants { return @(Get-HUCheckedTenants $script:Controls['spRintTenants']) }

function Save-HURintTenants {
    Set-HUStateValue 'rintTenants' @(Get-HURintTenants)
    Start-HURintLoad
    Update-HURintList
}

# ----------------------------------------------------------------------------
# Laden und Liste
# ----------------------------------------------------------------------------
function Start-HURintLoad([string[]]$Keys = @(), [switch]$Force, [scriptblock]$Then = $null) {
    $want = if (@($Keys).Count) { @($Keys) } else { @(Get-HURintTenants) }
    if ($Force) { foreach ($k in $want) { $script:RintRaw.Remove($k) } }
    $need = @($want | Where-Object { -not $script:RintRaw[$_] })
    if (-not $need.Count) { if ($Then) { & $Then }; return }
    if (Test-HUJobRunning 'RintLoad') { return }
    $script:RintLoadThen = $Then
    $script:Controls['lblRintState'].Text = "Lade Wartungsskripte aus $($need.Count) Tenant(s) ..."
    [void](Start-HUJob -Name 'RintLoad' -Quiet -Output $script:Controls['rtbRem'] -Vars @{ Need = $need } -Code {
            foreach ($k in $Need) {
                try { [pscustomobject]@{ Tenant = $k; Rows = @(Get-HUTenantRemediationList -TenantKey $k -Settings $Settings); Error = '' } }
                catch {
                    $m = $_.Exception.Message
                    if ($m -match '403|Forbidden|Authorization') { $m = 'Berechtigung DeviceManagementScripts.ReadWrite.All (und Group.Read.All) fehlt' }
                    elseif ($m -match '(?i)licen|lizenz') { $m += ' -> Windows-Lizenzueberpruefung im Intune Admin Center einschalten (A3/E3)' }
                    Write-HULog -Message $m -Level 'ERROR' -Tenant $k
                    [pscustomobject]@{ Tenant = $k; Rows = @(); Error = $m }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) { $script:RintRaw[$r.Tenant] = @{ Rows = @($r.Rows); Error = "$($r.Error)"; Time = Get-Date } }
            Update-HURintList
            $t = $script:RintLoadThen; $script:RintLoadThen = $null
            if ($t) { & $t }
            if (@(Get-HURintTenants | Where-Object { -not $script:RintRaw[$_] }).Count) { Start-HURintLoad }
        })
}

function Get-HURintMerged {
    $map = [ordered]@{}
    foreach ($k in @(Get-HURintTenants)) {
        $e = $script:RintRaw[$k]
        if (-not $e) { continue }
        foreach ($r in @($e.Rows)) {
            $key = "$($r.Name.ToLower())"
            if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ Key = $key; Name = $r.Name; Global = $r.Global; Per = [ordered]@{} } }
            $map[$key].Per[$k] = $r
        }
    }
    return @($map.Values)
}

function Update-HURintList {
    $c = $script:Controls
    $keys = @(Get-HURintTenants)
    $script:RintItems = @(Get-HURintMerged)
    $f = $c['txtRintFilter'].Text.Trim()
    $c['lblRintFilterHint'].Visibility = $(if ($f) { 'Collapsed' } else { 'Visible' })
    $kind = Get-HUComboTag $c['cmbRintType']
    $items = foreach ($it in ($script:RintItems | Sort-Object Name)) {
        if ($f -and $it.Name -notlike "*$f*") { continue }
        if ($kind -eq 'own' -and $it.Global) { continue }
        if ($kind -eq 'global' -and -not $it.Global) { continue }
        if ($kind -eq 'partial' -and $it.Per.Count -ge $keys.Count) { continue }
        $rows = @($it.Per.Values)
        $sub = $(if ($it.Global) { 'Microsoft' } else { "$(@($rows)[0].Publisher)" })
        $pr = Get-HUIntPresenceText @($it.Per.Keys) $keys
        if ($pr.Short) { $sub += " | $($pr.Short)" }
        if (@($rows | Where-Object { $_.AssignKnown }).Count) { $sub += $(if (@($rows | Where-Object { @($_.Assignments).Count }).Count) { ' | zugewiesen' } else { ' | nicht zugewiesen' }) }
        [pscustomobject]@{ Title = $it.Name; Sub = $sub.Trim(' ', '|'); Key = $it.Key; Tip = $(if ($pr.Tip) { $pr.Tip } else { $null }) }
    }
    $sel = if ($script:RintCurrent) { $script:RintCurrent.Key } else { '' }
    $c['lstRint'].ItemsSource = @($items)
    $hit = @($items) | Where-Object { $_.Key -eq $sel } | Select-Object -First 1
    if ($hit) { $c['lstRint'].SelectedItem = $hit }
    $errs = @($keys | Where-Object { $script:RintRaw[$_] -and $script:RintRaw[$_].Error } | ForEach-Object { "$(Get-HUTenantDisplayName $_): $($script:RintRaw[$_].Error)" })
    $loaded = @($keys | Where-Object { $script:RintRaw[$_] }).Count
    $st = if (-not $keys.Count) { 'Oben mindestens einen Tenant anhaken.' } elseif ($loaded -lt $keys.Count) { "Lade ... ($loaded von $($keys.Count))" } else { "$(@($items).Count) von $($script:RintItems.Count) Wartungsskript(en)" }
    if ($errs.Count) { $st += "`nFehler: " + ($errs -join '; ') }
    $c['lblRintState'].Text = $st
    if ($script:RintCurrent) {
        $n = $script:RintItems | Where-Object { $_.Key -eq $script:RintCurrent.Key } | Select-Object -First 1
        if ($n) { $script:RintCurrent = $n; Show-HURint -Keep } else { $script:RintCurrent = $null; Show-HURint }
    }
}

# ----------------------------------------------------------------------------
# Detailansicht
# ----------------------------------------------------------------------------
function Update-HURintButtons {
    $c = $script:Controls
    if (-not $c -or -not $c.ContainsKey('btnRintResults')) { return }
    $it = $script:RintCurrent
    $busy = Test-HUJobRunning 'RintAct'
    $has = [bool]$it
    $detail = $has -and (Test-HURintDetailComplete)
    foreach ($b in 'btnRintResults', 'btnRintRunNow') { $c[$b].IsEnabled = $has -and -not $busy }
    $c['btnRintReloadOne'].IsEnabled = $has
    $c['btnRintPortal'].IsEnabled = $has
    $c['btnRintToLib'].IsEnabled = $detail
    $c['btnRintCopy'].IsEnabled = $detail -and -not $it.Global -and -not $busy
    $edit = $has -and -not $it.Global
    $c['btnRintDelete'].IsEnabled = $edit -and -not $busy
    $c['btnRintSave'].IsEnabled = $edit -and $detail -and -not $busy
    foreach ($n in 'txtRintName', 'txtRintDesc', 'cmbRintRunAs', 'chkRint32') { $c[$n].IsEnabled = $edit }
    foreach ($n in 'txtRintDetect', 'txtRintFix') { $c[$n].IsReadOnly = -not $edit }
    foreach ($b in 'btnRintAssignAdd', 'btnRintAssignRemove') { $c[$b].IsEnabled = $has -and -not $busy }
}

function Update-HURintScheduleUi {
    $c = $script:Controls
    $t = Get-HUComboTag $c['cmbRintSchedule']
    $c['lblRintInterval'].Visibility = $(if ($t -eq 'once') { 'Collapsed' } else { 'Visible' })
    $c['txtRintInterval'].Visibility = $c['lblRintInterval'].Visibility
    $c['txtRintInterval'].ToolTip = $(if ($t -eq 'hourly') { 'Stunden (1-23)' } else { 'Tage' })
    $c['lblRintTime'].Visibility = $(if ($t -eq 'hourly') { 'Collapsed' } else { 'Visible' })
    $c['txtRintTime'].Visibility = $c['lblRintTime'].Visibility
    $c['txtRintDate'].Visibility = $(if ($t -eq 'once') { 'Visible' } else { 'Collapsed' })
    $k = Get-HUComboTag $c['cmbRintTarget']
    $c['txtRintGroup'].IsEnabled = ($k -in 'group', 'exclude')
    $c['btnRintGroupPick'].IsEnabled = $c['txtRintGroup'].IsEnabled
    $ex = ($k -eq 'exclude')
    foreach ($n in 'cmbRintSchedule', 'txtRintInterval', 'txtRintTime', 'txtRintDate', 'chkRintFix') { $c[$n].IsEnabled = -not $ex }
}

function Show-HURint([switch]$Keep) {
    $c = $script:Controls
    $it = $script:RintCurrent
    $c['pnlRintForm'].IsEnabled = [bool]$it
    if (-not $it) {
        $script:RintDetail = @{}
        $c['txtRintTitle'].Text = 'Links ein Wartungsskript waehlen'; $c['txtRintInfo'].Text = ''; $c['txtRintSummary'].Text = ''
        $c['gridRintAssign'].ItemsSource = $null
        foreach ($n in 'txtRintName', 'txtRintDesc', 'txtRintDetect', 'txtRintFix') { $c[$n].Text = '' }
        $c['lblRintScriptState'].Text = ''
        Update-HURintButtons
        return
    }
    $rows = @($it.Per.Values)
    $first = $rows[0]
    $c['txtRintTitle'].Text = $it.Name
    $info = "$(if ($it.Global) { 'von Microsoft (nur lesen und zuweisen)' } else { "Hersteller: $($first.Publisher)" }) | als $(if ($first.RunAs -eq 'user') { 'Benutzer' } else { 'System' })$(if ($first.RunAs32) { ', 32-Bit' })"
    $tt = Get-HUIntTenantText @($it.Per.Keys) @(Get-HURintTenants)
    if ($tt) { $info += " | vorhanden: $tt" }
    $c['txtRintInfo'].Text = $info
    if (-not $Keep) {
        $script:RintDetail = @{}
        $c['txtRintName'].Text = $it.Name
        $c['txtRintDesc'].Text = "$($first.Description)"
        [void](Select-HUComboTag $c['cmbRintRunAs'] $first.RunAs)
        $c['chkRint32'].IsChecked = [bool]$first.RunAs32
        $c['txtRintDetect'].Text = ''; $c['txtRintFix'].Text = ''
        $c['txtRintSummary'].Text = 'Lade Skripte, Zuweisungen und Zusammenfassung ...'
        $c['lblRintScriptState'].Text = ''
        Update-HURintAssignGrid
        Start-HURintDetail
    } else { Update-HURintAssignGrid }
    Update-HURintButtons
}

function Update-HURintAssignGrid {
    $c = $script:Controls; $it = $script:RintCurrent
    if (-not $it) { return }
    $all = @(Get-HURintTenants)
    $agg = [ordered]@{}
    foreach ($k in @($it.Per.Keys)) {
        # genaue Zuweisungen aus dem Detail, sonst aus der Liste
        $list = if ($script:RintDetail.ContainsKey($k)) { @($script:RintDetail[$k].Assignments) } else { @($it.Per[$k].Assignments) }
        foreach ($a in $list) {
            $ak = "$($a.Key)|$($a.Zeitplan)|$($a.Reparatur)"
            if (-not $agg.Contains($ak)) { $agg[$ak] = @{ A = $a; T = New-Object System.Collections.Generic.List[string] } }
            $agg[$ak].T.Add($k)
        }
    }
    $c['gridRintAssign'].ItemsSource = @(foreach ($v in $agg.Values) {
            [pscustomobject]@{ Ziel = $v.A.Ziel; Zeitplan = $v.A.Zeitplan; Reparatur = $v.A.Reparatur; Tenants = $(if ($all.Count -gt 1) { Get-HUIntTenantText @($v.T) $all } else { '' }); Key = $v.A.Key }
        })
}

# Skripte, Zuweisungen und Zusammenfassung laden - je Tenant ein eigener Hintergrundauftrag (gleichzeitig),
# jeder Tenant erscheint, sobald er da ist. Gen verwirft Antworten zu einer frueheren Auswahl.
function Start-HURintDetail {
    $it = $script:RintCurrent
    if (-not $it) { return }
    $script:RintGen++
    $gen = $script:RintGen
    $script:RintDetail = @{}
    $script:RintEditorFrom = ''
    $script:RintDetailKey = $it.Key
    $script:RintDetailWait = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($it.Per.Keys)) {
        $script:RintDetailWait.Add($k)
        [void](Start-HUJob -Name "RintDetail-$gen-$k" -Quiet -Output $script:Controls['rtbRem'] -Vars @{ K = $k; Id = $it.Per[$k].Id; Gen = $gen } -Code {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $d = $null
                try { $d = Get-HURemediationDetail -TenantKey $K -Settings $Settings -Id $Id } catch { Write-HULog -Message "Details: $($_.Exception.Message)" -Level 'WARN' -Tenant $K }
                if ($sw.Elapsed.TotalSeconds -gt 15) { Write-HULog -Message "Details brauchten $([int]$sw.Elapsed.TotalSeconds) s (Intune antwortet langsam)" -Level 'INFO' -Tenant $K }
                [pscustomobject]@{ Gen = $Gen; Tenant = $K; Detail = $d }
            } -OnDone {
                param($Result, $Errors)
                $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Gen'] })[0]
                if (-not $r -or $r.Gen -ne $script:RintGen -or -not $script:RintCurrent) { return }
                [void]$script:RintDetailWait.Remove($r.Tenant)
                if ($r.Detail) { $script:RintDetail[$r.Tenant] = $r.Detail }
                Show-HURintDetail
            })
    }
    Update-HURintButtons
}

function Test-HURintDetailComplete { return ($script:RintCurrent -and $script:RintDetailWait -and $script:RintDetailWait.Count -eq 0 -and $script:RintDetail.Count) }

# Detailansicht aus den bisher geladenen Tenants
function Show-HURintDetail {
    $c = $script:Controls; $it = $script:RintCurrent
    if (-not $it) { return }
    $keys = @($it.Per.Keys | Where-Object { $script:RintDetail.ContainsKey($_) })
    $waiting = @($script:RintDetailWait)
    if ($keys.Count -and -not $script:RintEditorFrom) {
        # Editor einmal fuellen (erster geladener Tenant) - danach nicht mehr ueberschreiben
        $script:RintEditorFrom = $keys[0]
        $d0 = $script:RintDetail[$keys[0]]
        $c['txtRintDetect'].Text = $d0.Detection
        $c['txtRintFix'].Text = $d0.Remediation
        $c['txtRintName'].Text = $d0.Name
        $c['txtRintDesc'].Text = $d0.Description
        [void](Select-HUComboTag $c['cmbRintRunAs'] $d0.RunAs)
        $c['chkRint32'].IsChecked = [bool]$d0.RunAs32
    }
    $multi = (@($it.Per.Keys).Count -gt 1)
    $lines = @(foreach ($k in $keys) { $sm = $script:RintDetail[$k].Summary; $(if ($multi) { "$(Get-HUTenantDisplayName $k): " }) + $(if ($sm) { $sm } else { 'noch keine Laeufe gemeldet' }) })
    if ($waiting.Count) { $lines += "Lade: $(@($waiting | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ') ..." }
    elseif (-not $keys.Count) { $lines += 'Details nicht lesbar (siehe Ausgabe unten).' }
    $c['txtRintSummary'].Text = ($lines -join "`n")
    $state = @()
    if ($it.Global) { $state += 'Skript von Microsoft - Inhalt kann nicht geaendert werden.' }
    if ($script:RintEditorFrom) {
        $d0 = $script:RintDetail[$script:RintEditorFrom]
        if (-not "$($d0.Detection)".Trim() -and -not $it.Global) { $state += 'Pruefskript leer oder nicht lesbar.' }
        $diff = @($keys | Where-Object { $script:RintDetail[$_].Detection -ne $d0.Detection -or $script:RintDetail[$_].Remediation -ne $d0.Remediation })
        if ($diff.Count) { $state += "Skripte unterscheiden sich in: $(@($diff | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ') - angezeigt wird $(Get-HUTenantDisplayName $script:RintEditorFrom). Werden die Skripte geaendert und gespeichert, bekommen alle Tenants diese Fassung (Name/Beschreibung allein aendert sie nicht)." }
    }
    $c['lblRintScriptState'].Text = ($state -join ' ')
    Update-HURintAssignGrid
    Update-HURintButtons
}

# Quelle der im Editor angezeigten Fassung
function Get-HURintEditorDetail {
    if ($script:RintEditorFrom -and $script:RintDetail.ContainsKey($script:RintEditorFrom)) { return $script:RintDetail[$script:RintEditorFrom] }
    return @($script:RintDetail.Values)[0]
}

# ----------------------------------------------------------------------------
# Aktionen (alle Tenants des gewaehlten Skripts)
# ----------------------------------------------------------------------------
function Start-HURintAction([string]$Title, [scriptblock]$Code, [hashtable]$Vars = @{}, [string[]]$Only = @(), [scriptblock]$Local = $null) {
    $it = $script:RintCurrent
    if (-not $it) { return }
    if (Test-HUJobRunning 'RintAct') { Show-HUMessage 'Es laeuft bereits eine Aktion - bitte warten.' -Icon Warning; return }
    $per = @{}; foreach ($k in $it.Per.Keys) { if (-not $Only.Count -or $Only -contains $k) { $per[$k] = $it.Per[$k].Id } }
    $Vars.Per = $per; $Vars.ScriptName = $it.Name
    $script:RintActKeys = @($per.Keys)
    $script:RintActKeysLocal = $Local
    Add-HURtbLine $script:Controls['rtbRem'] "=== $Title`: $($it.Name) ===" '#4FC3F7'
    [void](Start-HUJob -Name 'RintAct' -Output $script:Controls['rtbRem'] -Vars $Vars -Code $Code -OnDone {
            param($Result, $Errors)
            # sofort in der Anzeige nachziehen (z. B. entfernte Zuweisung), dann neu laden - Intune liefert Aenderungen
            # oft erst nach ein paar Sekunden, daher einmal sofort und einmal verzoegert
            if ($script:RintActKeysLocal) { try { & $script:RintActKeysLocal } catch { } }
            else { Start-HURintLoad -Keys $script:RintActKeys -Force -Then { if ($script:RintCurrent) { Show-HURint } } }
            $script:RintActKeysDelayed = @($script:RintActKeys)
            Invoke-HUDelayed 6 { Start-HURintLoad -Keys $script:RintActKeysDelayed -Force -Then { if ($script:RintCurrent) { Show-HURint } } }
            Update-HURintButtons
        })
    Update-HURintButtons
}

function Get-HURintScheduleInput {
    $c = $script:Controls
    $type = Get-HUComboTag $c['cmbRintSchedule']
    $iv = 1; if (-not [int]::TryParse($c['txtRintInterval'].Text.Trim(), [ref]$iv) -or $iv -lt 1) { $iv = 1 }
    $time = $c['txtRintTime'].Text.Trim()
    if ($type -ne 'hourly' -and $time -notmatch '^\d{1,2}:\d{2}$') { throw "Uhrzeit '$time' nicht lesbar - Format HH:mm" }
    $date = ''
    if ($type -eq 'once') {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($c['txtRintDate'].Text.Trim(), 'd.M.yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { throw "Datum '$($c['txtRintDate'].Text.Trim())' nicht lesbar - Format TT.MM.JJJJ" }
        $date = $d.ToString('yyyy-MM-dd')
    }
    $text = switch ($type) { 'hourly' { "alle $iv Std." } 'once' { "einmal am $($c['txtRintDate'].Text.Trim()) um $time" } default { "$(if ($iv -gt 1) { "alle $iv Tage" } else { 'taeglich' }) um $time" } }
    return @{ Schedule = @{ Type = $type; Interval = $iv; Time = $time; Date = $date }; Text = $text }
}

function Add-HURintAssignment {
    $c = $script:Controls; $it = $script:RintCurrent
    $kind = Get-HUComboTag $c['cmbRintTarget']
    $grp = $c['txtRintGroup'].Text.Trim()
    if ($kind -in 'group', 'exclude' -and -not $grp) { Show-HUMessage 'Bitte einen Gruppennamen eingeben (oder mit der Lupe suchen).' -Icon Warning; return }
    $sc = $null
    try { $sc = Get-HURintScheduleInput } catch { Show-HUMessage $_.Exception.Message -Icon Warning; return }
    $fix = [bool]$c['chkRintFix'].IsChecked
    $lbl = switch ($kind) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } 'exclude' { "Ausschluss '$grp'" } default { "Gruppe '$grp'" } }
    $how = if ($kind -eq 'exclude') { '' } else { "`nZeitplan: $($sc.Text)`nReparatur: $(if ($fix) { 'ja' } else { 'nein (nur pruefen)' })" }
    if (-not (Confirm-HU "$($it.Name)`n`nZuweisen: $lbl$how`nTenants: $(@($it.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')`n`nAusfuehren?")) { return }
    if ($grp) { Set-HUStateValue 'remLastGroup' $grp }
    Start-HURintAction 'Zuweisen' -Vars @{ T = @{ Kind = $kind; GroupName = $grp }; Schedule = $sc.Schedule; Fix = $fix; SchedText = $sc.Text } -Code {
        foreach ($k in $Per.Keys) {
            try {
                $tg = @(Resolve-HUTargets -TenantKey $k -Settings $Settings -Targets @($T))
                $n = Set-HURemediationAssignment -TenantKey $k -Settings $Settings -Id $Per[$k] -Targets $tg -Schedule $Schedule -RunRemediation $Fix
                Write-HULog -Message "Zugewiesen: $($tg[0].Label)$(if ($T.Kind -ne 'exclude') { " ($SchedText)" }) - insgesamt $n Zuweisung(en)" -Level 'OK' -Tenant $k
            } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Remove-HURintAssignment {
    $sel = @($script:Controls['gridRintAssign'].SelectedItems)
    if (-not $sel.Count) { Show-HUMessage 'Bitte in der Tabelle die Zuweisung(en) markieren.' -Icon Info; return }
    $keys = @($sel | ForEach-Object { $_.Key } | Select-Object -Unique)
    if (-not (Confirm-HU "Zuweisung(en) entfernen:`n- $(@($sel | ForEach-Object { "$($_.Ziel)$(if ($_.Zeitplan) { " ($($_.Zeitplan))" })" }) -join "`n- ")`n`nin allen Tenants dieses Skripts?" -Warning)) { return }
    $script:RintRemoveKeys = $keys
    $local = {
        foreach ($r in @($script:RintCurrent.Per.Values)) { $r.Assignments = @(@($r.Assignments) | Where-Object { $script:RintRemoveKeys -notcontains $_.Key }) }
        foreach ($d in @($script:RintDetail.Values)) { $d.Assignments = @(@($d.Assignments) | Where-Object { $script:RintRemoveKeys -notcontains $_.Key }) }
        Update-HURintAssignGrid
    }
    Start-HURintAction 'Zuweisung entfernen' -Local $local -Vars @{ RemoveKeys = $keys } -Code {
        foreach ($k in $Per.Keys) {
            try { $n = Remove-HURemediationAssignments -TenantKey $k -Settings $Settings -Id $Per[$k] -Keys $RemoveKeys; Write-HULog -Message "$n Zuweisung(en) entfernt" -Level $(if ($n) { 'OK' } else { 'INFO' }) -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Save-HURintChanges {
    $c = $script:Controls; $it = $script:RintCurrent
    if (-not $it -or $it.Global -or -not $script:RintDetail.Count) { return }
    $d0 = Get-HURintEditorDetail
    $v = @{}
    $name = $c['txtRintName'].Text.Trim(); $desc = $c['txtRintDesc'].Text.Trim()
    if ($name -and $name -ne $d0.Name) { $v.Name = $name }
    if ($desc -ne "$($d0.Description)".Trim()) { $v.Description = $desc }
    $ra = Get-HUComboTag $c['cmbRintRunAs']; if ($ra -ne $d0.RunAs) { $v.RunAs = $ra }
    $r32 = [bool]$c['chkRint32'].IsChecked; if ($r32 -ne [bool]$d0.RunAs32) { $v.RunAs32 = $r32 }
    # Skripte nur speichern, wenn sie im Editor geaendert wurden - sonst bleiben abweichende Fassungen je Tenant
    # (z. B. tenant-eigene IDs im Skript) unangetastet
    $det = $c['txtRintDetect'].Text; $fix = $c['txtRintFix'].Text
    $differs = 0
    if ($det -ne $d0.Detection -or $fix -ne $d0.Remediation) {
        $v.Detection = $det; $v.Remediation = $fix
        $differs = @($script:RintDetail.Values | Where-Object { $_.Detection -ne $det -or $_.Remediation -ne $fix }).Count
        $other = @($script:RintDetail.Values | Where-Object { $_.Tenant -ne $d0.Tenant -and ($_.Detection -ne $d0.Detection -or $_.Remediation -ne $d0.Remediation) })
        if ($other.Count -and -not (Confirm-HU "Die Skripte sind in $(@($other | ForEach-Object { Get-HUTenantDisplayName $_.Tenant }) -join ', ') anders als in $(Get-HUTenantDisplayName $d0.Tenant).`n`nBeim Speichern bekommen ALLE Tenants die Fassung aus dem Editor - tenant-eigene Werte (z. B. Tenant-ID) gehen dort verloren.`n`nTrotzdem fortfahren?" 'Wartung' -Warning)) { return }
    }
    if (-not $v.Count) { Show-HUMessage 'Nichts geaendert.' -Icon Info; return }
    if ($v.ContainsKey('Detection')) {
        $rtb = $c['rtbRem']
        $all = @(Test-HURemediationScript -Code $det -Kind detection -RunAs $ra) + @(Test-HURemediationScript -Code $fix -Kind remediation -RunAs $ra)
        Add-HURtbLine $rtb "--- Pruefung: $($it.Name) ---" '#4FC3F7'
        foreach ($x in $all) { Add-HURtbLine $rtb "[$($x.Stufe)] $($x.Hinweis)" $(switch ($x.Stufe) { 'Fehler' { '#FF5252' } 'Warnung' { '#FFB74D' } 'OK' { '#81C784' } default { '#90CAF9' } }) }
        if (@($all | Where-Object { $_.Stufe -eq 'Fehler' }).Count) { Show-HUMessage 'Die Pruefung hat Fehler gefunden (siehe Ausgabe) - bitte zuerst beheben.' 'Wartung' -Icon Warning; return }
    }
    $what = @()
    if ($v.Name) { $what += "Name -> $($v.Name)" }; if ($v.ContainsKey('Description')) { $what += 'Beschreibung' }
    if ($v.ContainsKey('RunAs')) { $what += "Ausfuehren als $(if ($v.RunAs -eq 'user') { 'Benutzer' } else { 'System' })" }; if ($v.ContainsKey('RunAs32')) { $what += "32-Bit $(if ($v.RunAs32) { 'ein' } else { 'aus' })" }
    if ($v.ContainsKey('Detection')) { $what += "Skripte$(if ($differs -lt $script:RintDetail.Count) { " (in $differs Tenant(s) abweichend)" })" }
    if (-not (Confirm-HU "$($it.Name)`n`nAendern: $($what -join ', ')`nTenants: $(@($it.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')`n`nDie Geraete verwenden die neue Fassung beim naechsten Lauf. Speichern?")) { return }
    if ($v.Name) { $it.Key = $v.Name.ToLower(); $script:RintCurrent = $it }
    Start-HURintAction 'Speichern' -Vars @{ V = $v } -Code {
        foreach ($k in $Per.Keys) {
            try { Update-HURemediation -TenantKey $k -Settings $Settings -Id $Per[$k] -Values $V; Write-HULog -Message 'Gespeichert' -Level 'OK' -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Remove-HURintScript {
    $it = $script:RintCurrent
    if (-not $it -or $it.Global) { return }
    $isAsg = { param($k) ($script:RintDetail.ContainsKey($k) -and @($script:RintDetail[$k].Assignments).Count) -or @($it.Per[$k].Assignments).Count }
    $keys = @($it.Per.Keys)
    # mehrere Tenants: gezielt auswaehlen, in welchen geloescht wird (nichts vorausgewaehlt)
    if ($keys.Count -gt 1) {
        $notes = @{}; foreach ($k in $keys) { $notes[$k] = $(if (& $isAsg $k) { 'zugewiesen' } else { '' }) }
        $keys = @(Show-HUTenantChoice -Title 'Loeschen' -Text "'$($it.Name)' gibt es in $($keys.Count) Tenants. In welchen loeschen?" -Keys $keys -Notes $notes -OkText 'Loeschen ...')
        if (-not $keys.Count) { return }
    }
    $assigned = @($keys | Where-Object { & $isAsg $_ })
    $msg = "'$($it.Name)' aus Intune LOESCHEN?`n`nTenants: $(@($keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')"
    if ($assigned.Count) { $msg += "`n`nACHTUNG: in $($assigned.Count) Tenant(s) noch zugewiesen - die Geraete fuehren es dann nicht mehr aus." }
    $msg += "`n`nDas kann nicht rueckgaengig gemacht werden (die Ergebnisse gehen verloren)."
    if (-not (Confirm-HU $msg 'Loeschen' -Warning)) { return }
    if (-not (Confirm-HU "Wirklich loeschen: '$($it.Name)' in $($keys.Count) Tenant(s)?" 'Loeschen' -Warning)) { return }
    $allGone = ($keys.Count -eq $it.Per.Count)
    Start-HURintAction 'Loeschen' -Only $keys -Code {
        foreach ($k in $Per.Keys) {
            try { Remove-HURemediation -TenantKey $k -Settings $Settings -Id $Per[$k]; Write-HULog -Message "'$ScriptName' geloescht" -Level 'OK' -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
    if ($allGone) { $script:RintCurrent = $null; Show-HURint }
}

function Start-HURintResults {
    $it = $script:RintCurrent
    if (-not $it) { return }
    $map = @{}; foreach ($k in $it.Per.Keys) { $map[$k] = $it.Per[$k].Id }
    Start-HURemResultsJob -Name $it.Name -Map $map -Rtb $script:Controls['rtbRem'] -JobName 'RintAct'
}

function Show-HURintRunNow {
    $it = $script:RintCurrent
    if (-not $it) { return }
    $deps = @(foreach ($k in $it.Per.Keys) { [pscustomobject]@{ Tenant = $k; ScriptId = $it.Per[$k].Id } })
    Show-HURemRunNowDialog -Name $it.Name -Deps $deps -Rtb $script:Controls['rtbRem'] -JobName 'RintAct'
}

# Skript samt Verteilung in die Bibliothek holen (vorhandenes Paket mit gleichem Namen wird aktualisiert)
function Copy-HURintToLib {
    $it = $script:RintCurrent
    if (-not $it -or -not $script:RintDetail.Count) { return }
    $keys = @($it.Per.Keys | Where-Object { $script:RintDetail.ContainsKey($_) })
    $d0 = Get-HURintEditorDetail
    $ids = @($it.Per.Values | ForEach-Object { $_.Id })
    $r = $script:RemLib | Where-Object { @($_.Deployments | Where-Object { $ids -contains $_.ScriptId }).Count } | Select-Object -First 1
    if (-not $r) { $r = $script:RemLib | Where-Object { $_.Name -eq $it.Name } | Select-Object -First 1 }
    if ($r -and -not (Confirm-HU "In der Bibliothek gibt es '$($r.Name)' schon.`n`nMit den Skripten und der Verteilung aus Intune ueberschreiben?")) { return }
    $isNew = -not $r
    if ($isNew) { $r = ConvertTo-HURem; $r.Id = [guid]::NewGuid().ToString() }
    $r.Name = $d0.Name; $r.Description = $d0.Description
    $r.Detection = $d0.Detection; $r.Remediation = $d0.Remediation
    $r.RunAs = $d0.RunAs; $r.RunAs32 = [bool]$d0.RunAs32
    $r.Tenants = @($keys)
    # Ziel und Zeitplan aus der ersten Einschluss-Zuweisung
    $a = @($d0.Assignments | Where-Object { $_.Kind -ne 'exclude' }) | Select-Object -First 1
    if ($a) {
        $r.TargetKind = $(if ($a.Kind -eq 'allDevices') { 'allDevices' } else { 'group' })
        $r.TargetGroup = $(if ($a.Kind -eq 'group') { $a.GroupName } else { $r.TargetGroup })
        $r.ScheduleType = $a.Schedule.Type; $r.Interval = $a.Schedule.Interval; $r.Time = $a.Schedule.Time; $r.Date = $a.Schedule.Date
    } else { $r.TargetKind = 'none' }
    $r.Pilot = $false
    $r.Deployments = @(foreach ($k in $keys) { [pscustomobject][ordered]@{ Tenant = $k; ScriptId = $it.Per[$k].Id; Stage = $(if (@($script:RintDetail[$k].Assignments).Count) { 'all' } else { 'none' }); Time = ''; Version = '' } })
    $r.Modified = Get-Date -Format 'yyyy-MM-dd HH:mm'
    if ($isNew) { $script:RemLib.Add($r) }
    Save-HURemLib
    $note = ''
    if (@($d0.Assignments).Count -gt 1) { $note = ' Es gibt mehrere Zuweisungen - in der Bibliothek steht nur die erste; die anderen bleiben in Intune unveraendert.' }
    if ($a -and $a.Kind -eq 'allUsers') { $note += ' "Alle Benutzer" gibt es in der Bibliothek nicht - Ziel pruefen.' }
    Set-HURemMode 'lib'
    Update-HURemList $r.Id
    Show-HURemForm $r
    Add-HURtbLine $script:Controls['rtbRem'] "$(if ($isNew) { 'In die Bibliothek uebernommen' } else { 'Bibliothek aktualisiert' }): $($r.Name).$note" '#81C784'
}

# Skript in weitere Tenants kopieren (Name, Hersteller, Skripte, Ausfuehren als; optional Zuweisungen per Gruppenname)
function Copy-HURintToTenants {
    $it = $script:RintCurrent
    if (-not $it -or $it.Global -or -not $script:RintDetail.Count) { return }
    $have = @($it.Per.Keys)
    $cand = @(@($script:Settings.tenants) | Where-Object { $have -notcontains "$($_.key)" })
    if (-not $cand.Count) { Show-HUMessage 'Das Skript gibt es schon in allen Tenants (soweit angehakt und geladen).' -Icon Info; return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="In andere Tenants kopieren" Width="460" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblHint" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <TextBlock Text="Ziel-Tenants" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <WrapPanel x:Name="spTenants" Margin="0,0,0,8"/>
        <CheckBox x:Name="chkAssign" Content="Zuweisungen mitnehmen (Gruppen werden je Tenant per Name gesucht)" Style="{StaticResource DarkCheckBox}" IsChecked="True"/>
        <TextBlock x:Name="lblAssign" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="20,4,0,0"/>
        <StackPanel x:Name="pnlMissing" Orientation="Horizontal" Margin="20,8,0,0">
            <TextBlock Text="Fehlt die Gruppe im Ziel:" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="cmbMissing" Style="{StaticResource DarkComboBox}" Width="190">
                <ComboBoxItem Content="nicht zuweisen" Tag="skip" IsSelected="True"/>
                <ComboBoxItem Content="stattdessen Alle Geraete" Tag="allDevices"/>
            </ComboBox>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="Kopieren" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $d0 = Get-HURintEditorDetail
    $src = $d0.Tenant
    $c.lblHint.Text = "'$($it.Name)' wird mit Pruef- und Reparaturskript aus $(Get-HUTenantDisplayName $src) angelegt. Gibt es im Ziel schon ein Skript mit diesem Namen, wird der Tenant uebersprungen."
    if ("$($d0.Detection)`n$($d0.Remediation)" -match '(?i)tenant.?id|client.?id|secret|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') { $c.lblHint.Text += "`n`nACHTUNG: Das Skript enthaelt Tenant-/App-IDs oder ein Secret - im Ziel-Tenant passen diese Werte vermutlich nicht. Nach dem Kopieren dort anpassen." }
    foreach ($t in $cand) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"; $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
        [void]$c.spTenants.Children.Add($cb)
    }
    $asg = @($d0.Assignments)
    $c.lblAssign.Text = $(if ($asg.Count) { (@($asg | ForEach-Object { "$($_.Ziel)$(if ($_.Zeitplan) { " ($($_.Zeitplan), Reparatur $($_.Reparatur))" })" }) -join "`n") } else { 'Keine Zuweisungen vorhanden.' })
    if (-not $asg.Count) { $c.chkAssign.IsChecked = $false; $c.chkAssign.IsEnabled = $false }
    if (-not @($asg | Where-Object { $_.Kind -eq 'group' }).Count) { $c.pnlMissing.Visibility = 'Collapsed' }
    $c.chkAssign.Add_Checked({ $c.pnlMissing.IsEnabled = $true })
    $c.chkAssign.Add_Unchecked({ $c.pnlMissing.IsEnabled = $false })
    $state = @{ Ok = $false; Keys = @() }
    $c.btnOk.Add_Click({
            $state.Keys = @($c.spTenants.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
            if (-not $state.Keys.Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning -Owner $w; return }
            $state.Ok = $true; $w.Close()
        })
    [void]$w.ShowDialog()
    if (-not $state.Ok) { return }
    if (Test-HUJobRunning 'RintAct') { Show-HUMessage 'Es laeuft bereits eine Aktion - bitte warten.' -Icon Warning; return }
    $withAsg = [bool]$c.chkAssign.IsChecked
    $missing = "$($c.cmbMissing.SelectedItem.Tag)"
    $rows = @(if ($withAsg) {
            foreach ($a in $asg) {
                $sc = $a.Schedule
                $date = ''; if ("$($sc.Date)" -match '^(\d{1,2})\.(\d{1,2})\.(\d{4})$') { $date = '{2}-{1:00}-{0:00}' -f [int]$Matches[1], [int]$Matches[2], $Matches[3] }
                @{ Kind = $a.Kind; GroupName = $a.GroupName; Label = $a.Ziel; Fix = ($a.Reparatur -eq 'ja'); Schedule = @{ Type = $sc.Type; Interval = $sc.Interval; Time = $sc.Time; Date = $date } }
            }
        })
    $def = [pscustomobject]@{ Name = $d0.Name; Description = $d0.Description; Publisher = $d0.Publisher; Detection = $d0.Detection; Remediation = $d0.Remediation; RunAs = $d0.RunAs; RunAs32 = [bool]$d0.RunAs32 }
    $script:RintCopyKeys = @($state.Keys)
    Add-HURtbLine $script:Controls['rtbRem'] "=== Kopieren: $($it.Name) -> $(@($state.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ') $(if (-not $withAsg) { '(ohne Zuweisungen)' } elseif ($missing -eq 'allDevices') { '(fehlende Gruppe -> Alle Geraete)' } else { '(fehlende Gruppe -> nicht zuweisen)' }) ===" '#4FC3F7'
    [void](Start-HUJob -Name 'RintAct' -Output $script:Controls['rtbRem'] -Vars @{ TargetKeys = @($state.Keys); Def = $def; Rows = $rows; Missing = $missing } -Code {
            foreach ($k in $TargetKeys) {
                try {
                    $exist = @(Get-HUIntuneGraphAll -TenantKey $k -Settings $Settings -Endpoint '/deviceManagement/deviceHealthScripts' | Where-Object { "$($_.displayName)" -eq $Def.Name })
                    if ($exist.Count) { Write-HULog -Message "'$($Def.Name)' gibt es hier schon - uebersprungen" -Level 'WARN' -Tenant $k; continue }
                    $id = Publish-HURemediation -TenantKey $k -Settings $Settings -Def $Def
                    Write-HULog -Message "Angelegt: $($Def.Name)" -Level 'OK' -Tenant $k
                    $allDone = $false
                    foreach ($r in $Rows) {
                        try {
                            $tg = $null
                            try { $tg = @(Resolve-HUTargets -TenantKey $k -Settings $Settings -Targets @(@{ Kind = $r.Kind; GroupName = $r.GroupName })) }
                            catch {
                                # fehlende Gruppe: je nach Auswahl auf "Alle Geraete" ausweichen (nur einmal je Tenant; Ausschluesse entfallen)
                                if ($r.Kind -ne 'group' -or $Missing -ne 'allDevices' -or "$($_.Exception.Message)" -notmatch 'gibt es in diesem Tenant nicht') { throw }
                                if ($allDone) { Write-HULog -Message "Gruppe '$($r.GroupName)' fehlt - 'Alle Geraete' ist schon zugewiesen" -Level 'INFO' -Tenant $k; continue }
                                Write-HULog -Message "Gruppe '$($r.GroupName)' fehlt - stattdessen Alle Geraete" -Level 'WARN' -Tenant $k
                                $tg = @(Resolve-HUTargets -TenantKey $k -Settings $Settings -Targets @(@{ Kind = 'allDevices' }))
                                $allDone = $true
                            }
                            $n = Set-HURemediationAssignment -TenantKey $k -Settings $Settings -Id $id -Targets $tg -Schedule $r.Schedule -RunRemediation ([bool]$r.Fix)
                            Write-HULog -Message "Zugewiesen: $($tg[0].Label) - insgesamt $n Zuweisung(en)" -Level 'OK' -Tenant $k
                        } catch { Write-HULog -Message "Zuweisung '$($r.Label)': $($_.Exception.Message)" -Level 'WARN' -Tenant $k }
                    }
                } catch {
                    $msg = $_.Exception.Message
                    if ($msg -match '(?i)licen|lizenz') { $msg += ' -> Windows-Lizenzueberpruefung im Intune Admin Center einschalten (A3/E3)' }
                    Write-HULog -Message $msg -Level 'ERROR' -Tenant $k
                }
            }
        } -OnDone {
            param($Result, $Errors)
            $shown = @(Get-HURintTenants)
            $re = @($script:RintCopyKeys | Where-Object { $shown -contains $_ })
            if ($re.Count) { Start-HURintLoad -Keys $re -Force }
            Add-HURtbLine $script:Controls['rtbRem'] 'Tipp: Ziel-Tenants links anhaken, um das Skript dort zu sehen.' '#90CAF9'
            Update-HURintButtons
        })
    Update-HURintButtons
}

function Open-HURintPortal {
    $it = $script:RintCurrent
    if (-not $it) { return }
    foreach ($k in @($it.Per.Keys | Select-Object -First 5)) {
        $t = @($script:Settings.tenants) | Where-Object { "$($_.key)" -eq $k } | Select-Object -First 1
        $tid = if ($t) { "$($t.tenantId)" } else { '' }
        Open-HUUrl "https://intune.microsoft.com/$tid/#view/Microsoft_Intune_DeviceSettings/DevicesMenu/~/remediations"
    }
}

# ----------------------------------------------------------------------------
# Ereignisse
# ----------------------------------------------------------------------------
function Register-HURintHandlers {
    $c = $script:Controls
    $c['btnRemModeLib'].Add_Click({ Set-HURemMode 'lib' })
    $c['btnRemModeInt'].Add_Click({ Save-HURemForm; Save-HURemLib; Set-HURemMode 'int' })
    $c['btnRintLoad'].Add_Click({ Start-HURintLoad -Force })
    $c['txtRintFilter'].Add_TextChanged({ Update-HURintList })
    $c['cmbRintType'].Add_SelectionChanged({ if ($script:RemMode -eq 'int') { Update-HURintList } })
    $c['lstRint'].Add_SelectionChanged({
            $sel = $script:Controls['lstRint'].SelectedItem
            if (-not $sel) { return }
            if ($script:RintCurrent -and $script:RintCurrent.Key -eq $sel.Key) { return }
            $script:RintCurrent = $script:RintItems | Where-Object { $_.Key -eq $sel.Key } | Select-Object -First 1
            Show-HURint
        })
    $c['cmbRintTarget'].Add_SelectionChanged({ Update-HURintScheduleUi })
    $c['cmbRintSchedule'].Add_SelectionChanged({ Update-HURintScheduleUi })
    $c['btnRintGroupPick'].Add_Click({
            if (-not $script:RintCurrent) { return }
            $n = Show-HUGroupPicker -TenantKeys @($script:RintCurrent.Per.Keys) -Current $script:Controls['txtRintGroup'].Text.Trim() -Title 'Gruppe waehlen'
            if ($n) { $script:Controls['txtRintGroup'].Text = $n }
        })
    $c['btnRintAssignAdd'].Add_Click({ Add-HURintAssignment })
    $c['btnRintAssignRemove'].Add_Click({ Remove-HURintAssignment })
    $c['btnRintCheck'].Add_Click({
            $c = $script:Controls; $rtb = $c['rtbRem']
            $ra = Get-HUComboTag $c['cmbRintRunAs']
            $all = @(Test-HURemediationScript -Code $c['txtRintDetect'].Text -Kind detection -RunAs $ra) + @(Test-HURemediationScript -Code $c['txtRintFix'].Text -Kind remediation -RunAs $ra)
            Add-HURtbLine $rtb "--- Pruefung: $($c['txtRintName'].Text) ---" '#4FC3F7'
            foreach ($x in $all) { Add-HURtbLine $rtb "[$($x.Stufe)] $($x.Hinweis)" $(switch ($x.Stufe) { 'Fehler' { '#FF5252' } 'Warnung' { '#FFB74D' } 'OK' { '#81C784' } default { '#90CAF9' } }) }
        })
    $c['btnRintSave'].Add_Click({ Save-HURintChanges })
    $c['btnRintResults'].Add_Click({ Start-HURintResults })
    $c['btnRintRunNow'].Add_Click({ Show-HURintRunNow })
    $c['btnRintToLib'].Add_Click({ Copy-HURintToLib })
    $c['btnRintCopy'].Add_Click({ Copy-HURintToTenants })
    $c['btnRintReloadOne'].Add_Click({ if ($script:RintCurrent) { Start-HURintLoad -Keys @($script:RintCurrent.Per.Keys) -Force -Then { if ($script:RintCurrent) { Show-HURint } } } })
    $c['btnRintPortal'].Add_Click({ Open-HURintPortal })
    $c['btnRintDelete'].Add_Click({ Remove-HURintScript })
}

function Initialize-HURint {
    Update-HURintTenantChecks
    Update-HURintScheduleUi
    Show-HURint
    Set-HURemMode 'lib'
}
