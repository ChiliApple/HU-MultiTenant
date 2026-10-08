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
        $cb.Add_Checked({ Save-HURintTenants })
        $cb.Add_Unchecked({ Save-HURintTenants })
        [void]$sp.Children.Add($cb)
    }
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
        $rows = @($it.Per.Values)
        $sub = $(if ($it.Global) { 'Microsoft' } else { "$(@($rows)[0].Publisher)" })
        if ($keys.Count -gt 1) { $sub += " | $($it.Per.Count) von $($keys.Count)" }
        if (@($rows | Where-Object { $_.AssignKnown }).Count) { $sub += $(if (@($rows | Where-Object { @($_.Assignments).Count }).Count) { ' | zugewiesen' } else { ' | nicht zugewiesen' }) }
        [pscustomobject]@{ Title = $it.Name; Sub = $sub.Trim(' ', '|'); Key = $it.Key }
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
    $detail = $has -and [bool]$script:RintDetail.Count
    foreach ($b in 'btnRintResults', 'btnRintRunNow') { $c[$b].IsEnabled = $has -and -not $busy }
    $c['btnRintReloadOne'].IsEnabled = $has
    $c['btnRintPortal'].IsEnabled = $has
    $c['btnRintToLib'].IsEnabled = $detail
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

# Skripte, Zuweisungen und Zusammenfassung aller Tenants des Skripts laden (Hintergrund)
function Start-HURintDetail {
    $it = $script:RintCurrent
    if (-not $it) { return }
    if (Test-HUJobRunning 'RintDetail') { $script:RintDetailPending = $true; return }
    $script:RintDetailPending = $false
    $per = @{}; foreach ($k in $it.Per.Keys) { $per[$k] = $it.Per[$k].Id }
    $script:RintDetailKey = $it.Key
    [void](Start-HUJob -Name 'RintDetail' -Quiet -Output $script:Controls['rtbRem'] -Vars @{ Per = $per } -Code {
            foreach ($k in $Per.Keys) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try { Get-HURemediationDetail -TenantKey $k -Settings $Settings -Id $Per[$k] }
                catch { Write-HULog -Message "Details: $($_.Exception.Message)" -Level 'WARN' -Tenant $k }
                if ($sw.Elapsed.TotalSeconds -gt 15) { Write-HULog -Message "Details brauchten $([int]$sw.Elapsed.TotalSeconds) s (Intune antwortet langsam)" -Level 'INFO' -Tenant $k }
            }
        } -OnDone {
            param($Result, $Errors)
            if (-not $script:RintCurrent) { return }
            if ($script:RintDetailPending -or $script:RintCurrent.Key -ne $script:RintDetailKey) { Start-HURintDetail; return }
            $c = $script:Controls
            $script:RintDetail = @{}
            foreach ($d in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Detection'] })) { $script:RintDetail[$d.Tenant] = $d }
            $keys = @($script:RintCurrent.Per.Keys | Where-Object { $script:RintDetail.ContainsKey($_) })
            if (-not $keys.Count) {
                $c['txtRintSummary'].Text = 'Details nicht lesbar (siehe Ausgabe unten).'
                if (@($Errors).Count -eq 0) { Add-HURtbLine $c['rtbRem'] "Details zu '$($script:RintCurrent.Name)' kamen leer zurueck." '#FFB74D' }
                Update-HURintButtons; return
            }
            $d0 = $script:RintDetail[$keys[0]]
            $c['txtRintDetect'].Text = $d0.Detection
            $c['txtRintFix'].Text = $d0.Remediation
            $c['txtRintName'].Text = $d0.Name
            $c['txtRintDesc'].Text = $d0.Description
            [void](Select-HUComboTag $c['cmbRintRunAs'] $d0.RunAs)
            $c['chkRint32'].IsChecked = [bool]$d0.RunAs32
            $multi = ($keys.Count -gt 1)
            $c['txtRintSummary'].Text = (@(foreach ($k in $keys) { $s = $script:RintDetail[$k].Summary; if ($s) { $(if ($multi) { "$(Get-HUTenantDisplayName $k): " }) + $s } }) -join "`n")
            if (-not $c['txtRintSummary'].Text) { $c['txtRintSummary'].Text = 'Noch keine Laeufe gemeldet.' }
            # Skripte zwischen den Tenants vergleichen
            $diff = @($keys | Where-Object { $script:RintDetail[$_].Detection -ne $d0.Detection -or $script:RintDetail[$_].Remediation -ne $d0.Remediation })
            $state = @()
            if ($script:RintCurrent.Global) { $state += 'Skript von Microsoft - Inhalt kann nicht geaendert werden.' }
            if (-not "$($d0.Detection)".Trim() -and -not $script:RintCurrent.Global) { $state += 'Pruefskript leer oder nicht lesbar.' }
            if ($diff.Count) { $state += "Skripte unterscheiden sich in: $(@($diff | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ') - angezeigt wird $(Get-HUTenantDisplayName $keys[0]); Speichern setzt ueberall diese Fassung." }
            $c['lblRintScriptState'].Text = ($state -join ' ')
            Update-HURintAssignGrid
            Update-HURintButtons
        })
}

# ----------------------------------------------------------------------------
# Aktionen (alle Tenants des gewaehlten Skripts)
# ----------------------------------------------------------------------------
function Start-HURintAction([string]$Title, [scriptblock]$Code, [hashtable]$Vars = @{}) {
    $it = $script:RintCurrent
    if (-not $it) { return }
    if (Test-HUJobRunning 'RintAct') { Show-HUMessage 'Es laeuft bereits eine Aktion - bitte warten.' -Icon Warning; return }
    $per = @{}; foreach ($k in $it.Per.Keys) { $per[$k] = $it.Per[$k].Id }
    $Vars.Per = $per; $Vars.ScriptName = $it.Name
    $script:RintActKeys = @($it.Per.Keys)
    Add-HURtbLine $script:Controls['rtbRem'] "=== $Title`: $($it.Name) ===" '#4FC3F7'
    [void](Start-HUJob -Name 'RintAct' -Output $script:Controls['rtbRem'] -Vars $Vars -Code $Code -OnDone {
            param($Result, $Errors)
            Start-HURintLoad -Keys $script:RintActKeys -Force -Then { if ($script:RintCurrent) { Show-HURint } }
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
    Start-HURintAction 'Zuweisung entfernen' -Vars @{ Keys = $keys } -Code {
        foreach ($k in $Per.Keys) {
            try { $n = Remove-HURemediationAssignments -TenantKey $k -Settings $Settings -Id $Per[$k] -Keys $Keys; Write-HULog -Message "$n Zuweisung(en) entfernt" -Level $(if ($n) { 'OK' } else { 'INFO' }) -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Save-HURintChanges {
    $c = $script:Controls; $it = $script:RintCurrent
    if (-not $it -or $it.Global -or -not $script:RintDetail.Count) { return }
    $d0 = @($script:RintDetail.Values)[0]
    $v = @{}
    $name = $c['txtRintName'].Text.Trim(); $desc = $c['txtRintDesc'].Text.Trim()
    if ($name -and $name -ne $d0.Name) { $v.Name = $name }
    if ($desc -ne "$($d0.Description)".Trim()) { $v.Description = $desc }
    $ra = Get-HUComboTag $c['cmbRintRunAs']; if ($ra -ne $d0.RunAs) { $v.RunAs = $ra }
    $r32 = [bool]$c['chkRint32'].IsChecked; if ($r32 -ne [bool]$d0.RunAs32) { $v.RunAs32 = $r32 }
    # Skripte: auch speichern, wenn sie sich zwischen den Tenants unterscheiden (dann ueberall diese Fassung)
    $det = $c['txtRintDetect'].Text; $fix = $c['txtRintFix'].Text
    $differs = @($script:RintDetail.Values | Where-Object { $_.Detection -ne $det -or $_.Remediation -ne $fix }).Count
    if ($differs) { $v.Detection = $det; $v.Remediation = $fix }
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
    $assigned = @($it.Per.Keys | Where-Object { ($script:RintDetail.ContainsKey($_) -and @($script:RintDetail[$_].Assignments).Count) -or @($it.Per[$_].Assignments).Count })
    $msg = "'$($it.Name)' aus Intune LOESCHEN?`n`nTenants: $(@($it.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')"
    if ($assigned.Count) { $msg += "`n`nACHTUNG: in $($assigned.Count) Tenant(s) noch zugewiesen - die Geraete fuehren es dann nicht mehr aus." }
    $msg += "`n`nDas kann nicht rueckgaengig gemacht werden (die Ergebnisse gehen verloren)."
    if (-not (Confirm-HU $msg 'Loeschen' -Warning)) { return }
    if (-not (Confirm-HU "Wirklich loeschen: '$($it.Name)' in $($it.Per.Count) Tenant(s)?" 'Loeschen' -Warning)) { return }
    Start-HURintAction 'Loeschen' -Code {
        foreach ($k in $Per.Keys) {
            try { Remove-HURemediation -TenantKey $k -Settings $Settings -Id $Per[$k]; Write-HULog -Message "'$ScriptName' geloescht" -Level 'OK' -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
    $script:RintCurrent = $null
    Show-HURint
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
    $d0 = $script:RintDetail[$keys[0]]
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
