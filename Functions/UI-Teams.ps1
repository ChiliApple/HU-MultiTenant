#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter Teams: Ziele (Workflows-Webhooks), Meldungen (eingebaut oder aus Skript, mit Zielen und Zeitplan), Sendeprotokoll.
.DESCRIPTION
    Logik in Core\HU.Notify.psm1 (Ziele, Karten, Senden) und Core\HU.TeamsJobs.psm1 (Auftraege, Datenerhebung,
    Aufgabenplanung). Hier nur Oberflaeche.
    Ziele: %APPDATA%\HU-MultiTenant\notify-targets.json (DPAPI). Auftraege: Config\teams-jobs.json (lokal).
    Die Webhook-Adresse wird in einer PasswordBox eingegeben und nie wieder angezeigt (leer lassen = behalten).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:TeamsCurrent = ''      # Id des gewaehlten Ziels ('' = neu)
$script:TeamsJobCurrent = ''   # Id des gewaehlten Auftrags ('' = neu)
$script:TeamsFillBusy = $false

# ============================================================================
# ZIELE
# ============================================================================

function Update-HUTeamsTargets {
    $c = $script:Controls
    $cfg = Get-HUNotifyConfig
    $lb = $c['lstTeamsTargets']
    $script:TeamsFillBusy = $true
    try {
        $lb.Items.Clear()
        $sel = $null
        foreach ($t in @($cfg.Targets)) {
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = "$(if ($t.Enabled) { '' } else { '(aus) ' })$($t.Name)"
            $li.Tag = $t
            [void]$lb.Items.Add($li)
            if ("$($t.Id)" -eq $script:TeamsCurrent) { $sel = $li }
        }
        $lb.SelectedItem = $sel
    } finally { $script:TeamsFillBusy = $false }
    if ($cfg.Error) { $c['lblTeamsHint'].Text = "Ziele nicht lesbar: $($cfg.Error)" }
    elseif (-not $lb.Items.Count) { $c['lblTeamsHint'].Text = 'Noch kein Ziel. In Teams: Kanal > Workflows > "Post to a channel when a webhook request is received" anlegen, Adresse hier eintragen.' }
}

function Show-HUTeamsTarget($Target) {
    $c = $script:Controls
    $script:TeamsFillBusy = $true
    try {
        $script:TeamsCurrent = if ($Target) { "$($Target.Id)" } else { '' }
        $c['txtTeamsName'].Text = if ($Target) { "$($Target.Name)" } else { 'Admin-Kanal' }
        $c['pwdTeamsUrl'].Password = ''
        $c['chkTeamsEnabled'].IsChecked = if ($Target) { [bool]$Target.Enabled } else { $true }
        foreach ($cb in @(Get-HUTeamsCatBoxes)) {
            $cb.IsChecked = (Test-HUNotifyCat -Target $Target -Category "$($cb.Tag)")
        }
        $c['btnTeamsDel'].IsEnabled = [bool]$Target
        $c['btnTeamsTest'].IsEnabled = $true
        $c['lblTeamsHint'].Text = if ($Target) { "Ziel $($Target.Name) - Id $($Target.Id) (fuer Send-HUNotify -TargetIds), Kennung $(Get-HUNotifyUrlTag $Target.Url). Adresse ist gespeichert (verschluesselt) und wird nicht angezeigt." } else { 'Neues Ziel: Name und Webhook-Adresse eintragen, dann Speichern.' }
    } finally { $script:TeamsFillBusy = $false }
}

# Am Ziel steht nur noch, ob es Fehlermeldungen zeitgesteuerter Laeufe bekommt (Kategorie 'Jobs'). Welche Meldungen ein
# Ziel bekommt, steht an der Meldung selbst (rechts, "Senden an"). Alte Kategorie-Haken - auch eigene Kategorien aus den
# 2.1.10-Testversionen - bleiben gespeichert (Get-HUTeamsCatsFromPanel), werden aber nicht mehr angezeigt.
function Get-HUTeamsCatBoxes {
    @($script:Controls['pnlTeamsCats'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
}

function Update-HUTeamsCatChecks {
    $c = $script:Controls
    $c['pnlTeamsCats'].Children.Clear()
    $k = Get-HUNotifyCategories | Where-Object { $_.Key -eq 'Jobs' } | Select-Object -First 1
    if (-not $k) { return }
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = 'Jobs'
    $cb.Content = 'Hinweis, wenn eine zeitgesteuerte Meldung nicht laufen kann'
    $cb.ToolTip = 'Scheitert eine geplante Aufgabe (z. B. Secret abgelaufen, Einstellungen nicht lesbar), kommt eine Fehlerkarte an dieses Ziel.'
    $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
    $cb.Margin = [System.Windows.Thickness]::new(0, 1, 12, 1)
    $cb.IsChecked = [bool]$k.Default
    [void]$c['pnlTeamsCats'].Children.Add($cb)
}

function Get-HUTeamsCatsFromPanel {
    # Nicht angezeigte (eingebaute) Kategorien behalten ihren gespeicherten Wert
    param($Old)
    $h = @{}
    if ($Old -and $Old.Cats) { foreach ($k in @($Old.Cats.PSBase.Keys)) { $h["$k"] = [bool]$Old.Cats[$k] } }
    foreach ($cb in @(Get-HUTeamsCatBoxes)) { $h["$($cb.Tag)"] = [bool]$cb.IsChecked }
    return $h
}

function Save-HUTeamsTarget {
    param([switch]$Quiet)
    $c = $script:Controls
    $name = "$($c['txtTeamsName'].Text)".Trim()
    if (-not $name) { Show-HUMessage 'Bitte einen Namen eingeben.' -Icon Warning; return }
    $url = "$($c['pwdTeamsUrl'].Password)".Trim()
    $cfg = Get-HUNotifyConfig
    $old = $cfg.Targets | Where-Object { $_.Id -eq $script:TeamsCurrent } | Select-Object -First 1
    if (-not $url) {
        if (-not $old) { Show-HUMessage 'Bitte die Webhook-Adresse aus Teams (Workflows) einfuegen.' -Icon Warning; return }
        $url = $old.Url
    }
    else {
        $why = Test-HUWebhookUrl $url
        if ($why) { Show-HUMessage "Webhook-Adresse: $why" -Icon Warning; return }
        if (-not (Test-HUWebhookHostKnown $url)) {
            if (-not (Confirm-HU "Die Adresse stammt nicht erkennbar aus der Workflows-App / Power Automate.`n`nTrotzdem speichern?" -Warning)) { return }
        }
    }
    $newT = [pscustomobject]@{ Id = $script:TeamsCurrent; Name = $name; Url = $url; Enabled = [bool]$c['chkTeamsEnabled'].IsChecked; Cats = (Get-HUTeamsCatsFromPanel -Old $old); Created = $(if ($old) { $old.Created } else { '' }) }
    # Review 030 B18: Lesen + Schreiben unter der Sperre (parallel z. B. ein Snippet mit Add-HUNotifyTarget)
    $script:__teamsSaveOut = ''
    try {
        Invoke-HUNotifyLocked {
            $cur = Get-HUNotifyConfig
            if ($cur.Error) { $script:__teamsSaveOut = "Ziele nicht lesbar: $($cur.Error)"; return }
            $list = @($cur.Targets | Where-Object { $_.Id -ne $script:TeamsCurrent }) + @($newT)
            $script:__teamsSaveOut = Set-HUNotifyTargets -Targets $list
        }
    } catch { $script:__teamsSaveOut = "$($_.Exception.Message) - Aenderung nicht gespeichert, bitte in einigen Sekunden erneut 'Speichern' klicken." }
    $r = "$($script:__teamsSaveOut)"
    if ($r) { Show-HUMessage $r -Icon Error; return }
    $c['pwdTeamsUrl'].Password = ''
    $new = (Get-HUNotifyConfig).Targets | Where-Object { $_.Name -eq $name } | Select-Object -Last 1
    if ($new) { $script:TeamsCurrent = "$($new.Id)" }
    Update-HUTeamsJobTargetChecks
    Update-HUTeamsTargets
    Show-HUTeamsTarget $new
    Write-HULogOK "Teams-Ziel '$name' gespeichert."
}

function Remove-HUTeamsTarget {
    if (-not $script:TeamsCurrent) { return }
    $c = $script:Controls
    if (-not (Confirm-HU "Ziel '$($c['txtTeamsName'].Text)' entfernen?`n`nDie Adresse wird geloescht; der Workflow in Teams bleibt bestehen." -Warning)) { return }
    $r = Remove-HUNotifyTarget -Id $script:TeamsCurrent
    if ($r) { Show-HUMessage $r -Icon Error; return }
    $script:TeamsCurrent = ''
    Update-HUTeamsJobTargetChecks
    Update-HUTeamsTargets
    Show-HUTeamsTarget $null
}

function Test-HUTeamsTarget {
    $c = $script:Controls
    $url = "$($c['pwdTeamsUrl'].Password)".Trim()
    $name = "$($c['txtTeamsName'].Text)".Trim(); if (-not $name) { $name = 'Teams' }
    $c['lblTeamsHint'].Text = 'Testnachricht wird gesendet ...'
    $r = if ($url) { Send-HUNotifyTest -Url $url -Name $name } elseif ($script:TeamsCurrent) { Send-HUNotifyTest -TargetId $script:TeamsCurrent } else { 'Bitte zuerst eine Webhook-Adresse eingeben.' }
    Update-HUTeamsHist
    if ($r) { $c['lblTeamsHint'].Text = "Test: $r"; Show-HUMessage "Testnachricht nicht gesendet:`n`n$r" -Icon Warning }
    else { $c['lblTeamsHint'].Text = 'Testnachricht gesendet (vom Workflow angenommen) - bitte im Teams-Kanal pruefen. Zeigt das Handy nur den Kanalnamen? Dann den Workflow einmal anpassen: F1 > Teams > Push-Vorschau am Handy (ca. 10 Minuten).'; Write-HULogOK "Teams-Testnachricht an '$name' gesendet." }
}

# ============================================================================
# MELDUNGEN (intern: Auftraege / Jobs)
# ============================================================================

function Get-HUTeamsJobLabel($Job) {
    $d = @($Job.Days | ForEach-Object { [int]$_ })
    $when = if ($d.Count) { ($d | Sort-Object | ForEach-Object { @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So')[$_ - 1] }) -join '' } else { 'taeglich' }
    $kindLabel = if ("$($Job.Kind)" -eq 'Script') { "Skript: $($Job.Options.snippet)" } else { "$((Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($Job.Kind)" }).Label)" }
    $nm = "$($Job.Name)"
    if ($kindLabel -and $nm -ne $kindLabel -and $nm -ne "$($Job.Options.snippet)") { $nm = "$nm ($kindLabel)" }
    $tids = @($Job.Targets | Where-Object { "$_" })
    $to = 'alle Ziele'
    if ($tids.Count) {
        $all = @((Get-HUNotifyConfig).Targets)
        $names = @($tids | ForEach-Object { $id = "$_"; $t = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if ($t) { "$($t.Name)" } else { '?' } })
        $to = $names -join ', '
    }
    $st = Get-HUTeamsScriptState $Job
    return "$(if ($Job.Enabled) { '' } else { '(aus) ' })$nm  -  $when $($Job.Time)  -  an $to$(if ($st) { "  -  ! $st" })"
}

# Wochentage kompakt: 1..5 -> "Mo-Fr", 1,3,5 -> "Mo, Mi, Fr", keiner -> "taeglich"
function Format-HUTeamsDays($Days) {
    $n = @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So')
    $d = @(@($Days) | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 7 } | Sort-Object -Unique)
    if (-not $d.Count -or $d.Count -eq 7) { return 'taeglich' }
    $parts = @(); $i = 0
    while ($i -lt $d.Count) {
        $j = $i; while ($j + 1 -lt $d.Count -and $d[$j + 1] -eq $d[$j] + 1) { $j++ }
        if ($j - $i -ge 2) { $parts += "$($n[$d[$i] - 1])-$($n[$d[$j] - 1])" } else { for ($k = $i; $k -le $j; $k++) { $parts += $n[$d[$k] - 1] } }
        $i = $j + 1
    }
    return ($parts -join ', ')
}

# Zeile der Meldungsliste (Spalten Name | Wochentage/Uhrzeit | Ziele | Tenants)
function ConvertTo-HUTeamsJobRow($Job, $AllTargets) {
    $nm = "$($Job.Name)"
    # Hinweise in eine eigene Spalte - der Name bleibt kurz
    $st = @()
    $ss = Get-HUTeamsScriptState $Job
    if ($ss) { $st += "! $(if ($ss -match 'geaendert') { 'Skript geaendert - neu speichern' } else { $ss })" }
    if (-not $Job.Enabled) { $st += 'Zeitplan aus' }
    $tids = @(@($Job.Targets) | Where-Object { "$_" })
    $to = if ($tids.Count) { (@($tids | ForEach-Object { $id = "$_"; $tt = $AllTargets | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if ($tt) { "$($tt.Name)" } else { '?' } }) -join ', ') } else { 'alle' }
    $keys = @(@($Job.Tenants) | Where-Object { "$_" })
    $tn = if ($keys.Count) { (@($keys | ForEach-Object { $k = "$_"; $x = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1; if ($x) { "$($x.displayName)" } else { $k } }) -join ', ') } else { 'alle' }
    return [pscustomobject]@{ Kopf = $false; Name = $nm; Zeitplan = "$(Format-HUTeamsDays $Job.Days) $($Job.Time)"; Ziele = $to; Tenants = $tn; Status = ($st -join ', '); Job = $Job }
}

function Update-HUTeamsJobs {
    $c = $script:Controls
    $lb = $c['lstTeamsJobs']
    $jobs = @()
    try { $jobs = @(Get-HUTeamsJobs -AppRoot $script:AppRoot) } catch { Write-HULogError $_.Exception.Message }
    $allT = @((Get-HUNotifyConfig).Targets)
    $script:TeamsFillBusy = $true
    try {
        $rows = New-Object System.Collections.ArrayList
        $sel = $null
        # zwei Gruppen: eingebaute Meldungen, Meldungen aus Skripten (Ueberschriften sind nicht waehlbar)
        foreach ($g in @(@{ Head = 'Eingebaute Meldungen'; Script = $false }, @{ Head = 'Meldungen aus Skripten'; Script = $true })) {
            $grp = @($jobs | Where-Object { ("$($_.Kind)" -eq 'Script') -eq $g.Script })
            [void]$rows.Add([pscustomobject]@{ Kopf = $true; Name = "$($g.Head)$(if (-not $grp.Count) { ' - noch keine (+ Neu)' })"; Zeitplan = ''; Ziele = ''; Tenants = ''; Status = ''; Job = $null })
            foreach ($j in $grp) {
                $r = ConvertTo-HUTeamsJobRow $j $allT
                [void]$rows.Add($r)
                if ("$($j.Id)" -eq $script:TeamsJobCurrent) { $sel = $r }
            }
        }
        $lb.ItemsSource = $rows
        # Spalten wieder an den Inhalt anpassen (Auto waechst sonst nur); danach bleibt jede Spalte ziehbar
        foreach ($col in $lb.Columns) { $col.Width = [System.Windows.Controls.DataGridLength]::new(0); $col.Width = [System.Windows.Controls.DataGridLength]::Auto }
        $lb.SelectedItem = $sel
    } finally { $script:TeamsFillBusy = $false }
}

function Update-HUTeamsJobTaskLabel($Job) {
    $c = $script:Controls
    if (-not $Job) { $c['lblTeamsJobTask'].Text = 'Neue Meldung: was gemeldet wird, Name, Ziele, Tenants - dann Speichern. "Jetzt senden" geht sofort; fuer den Zeitplan danach "Aufgabe anlegen".'; $c['btnTeamsJobTask'].Content = 'Aufgabe anlegen'; $c['btnTeamsJobTask'].IsEnabled = $false; return }
    $t = Get-HUTeamsJobTask -Job $Job
    $c['btnTeamsJobTask'].IsEnabled = $true
    $warn = Get-HUTeamsScriptState $Job
    if ($warn) { $warn = "ACHTUNG: $warn (geplante Laeufe fuehren es bis dahin nicht aus).`n" }
    if ($t.Exists) {
        $c['btnTeamsJobTask'].Content = 'Aufgabe entfernen'
        $next = if ($t.NextRun) { ([datetime]$t.NextRun).ToString('dd.MM. HH:mm') } else { '-' }
        $codeTxt = switch ("$($t.LastResult)") { '0' { 'OK' } '1' { 'Fehler' } '2' { 'teilweise gesendet' } '3' { 'Konfiguration pruefen' } '267009' { 'laeuft' } default { "Code $($t.LastResult)" } }
        $last = if ($t.LastRun -and ([datetime]$t.LastRun).Year -gt 2000) { ([datetime]$t.LastRun).ToString('dd.MM. HH:mm') + " ($codeTxt)" } else { 'noch nie' }
        $c['lblTeamsJobTask'].Text = "$($warn)Aufgabenplanung: $($t.State), naechster Lauf $next, letzter Lauf $last.`nLetztes Ergebnis: $(if ($Job.LastResult) { $Job.LastResult } else { '-' })"
    }
    else {
        $c['btnTeamsJobTask'].Content = 'Aufgabe anlegen'
        $c['lblTeamsJobTask'].Text = "$($warn)Kein Zeitplan - die Meldung sendet nur ueber 'Jetzt senden'. Zeitplan: 'Aufgabe anlegen'.`nLetztes Ergebnis: $(if ($Job.LastResult) { $Job.LastResult } else { '-' })"
    }
}

function Show-HUTeamsJob($Job) {
    $c = $script:Controls
    $script:TeamsFillBusy = $true
    try {
        $script:TeamsJobCurrent = if ($Job) { "$($Job.Id)" } else { '' }
        $c['txtTeamsJobName'].Text = if ($Job) { "$($Job.Name)" } else { 'Tages-Ampel' }   # neuer Auftrag: Name folgt der Art (siehe SelectionChanged)
        $c['txtTeamsJobTime'].Text = if ($Job -and "$($Job.Time)") { "$($Job.Time)" } else { '07:00' }
        $c['chkTeamsJobEnabled'].IsChecked = if ($Job) { [bool]$Job.Enabled } else { $true }
        $mask = $false
        if ($Job -and $Job.Options -and $Job.Options.PSObject.Properties['maskDevices']) { $mv = $Job.Options.maskDevices; $mask = [bool]($mv -eq $true -or "$mv".Trim() -match '^(?i)(true|1|ja|yes|on|an)$') }
        $c['chkTeamsJobMask'].IsChecked = $mask
        Update-HUTeamsMaskState
        $kind = if ($Job) { "$($Job.Kind)" } else { 'Daily' }
        $c['cmbTeamsJobKind'].SelectedItem = $null   # Skript-Meldung: oben nichts gewaehlt
        foreach ($i in $c['cmbTeamsJobKind'].Items) { if ("$($i.Tag)" -eq $kind) { $c['cmbTeamsJobKind'].SelectedItem = $i } }
        Update-HUTeamsSnippetCombo -Select $(if ($Job -and $Job.Options -and $Job.Options.PSObject.Properties['snippet']) { "$($Job.Options.snippet)" } else { '' })
        $pv = [ordered]@{}
        if ($Job -and $Job.Options -and $Job.Options.PSObject.Properties['params'] -and $Job.Options.params) { foreach ($pp in $Job.Options.params.PSObject.Properties) { $pv[$pp.Name] = $pp.Value } }
        Update-HUTeamsJobParams $pv
        Update-HUTeamsMaskState
        Update-HUTeamsJobTargetChecks
        # Where-Object: $null | ForEach-Object laeuft einmal mit $null -> '' waere ein "Ziel" und kein Haken bliebe gesetzt
        $tids = @(if ($Job) { @($Job.Targets) | Where-Object { "$_" } | ForEach-Object { "$_" } })
        # leer = alle Ziele -> alle anhaken (so wird es auch gesendet)
        foreach ($cb in @($c['pnlTeamsJobTargets'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) { $cb.IsChecked = ((-not $tids.Count) -or ($tids -contains "$($cb.Tag)")) }
        $days = @(if ($Job) { $Job.Days | ForEach-Object { [int]$_ } } else { @() })
        foreach ($cb in @($c['pnlTeamsJobDays'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) { $cb.IsChecked = ($days -contains [int]$cb.Tag) }
        $keys = @(if ($Job) { $Job.Tenants } else { @() })
        if (-not $keys.Count) { $keys = @($script:Settings.tenants | ForEach-Object { "$($_.key)" }) }
        Set-HUCheckedTenants $c['pnlTeamsJobTenants'] $keys
        $c['btnTeamsJobDel'].IsEnabled = [bool]$Job
        $c['btnTeamsJobRun'].IsEnabled = $true
        Update-HUTeamsJobTaskLabel $Job
    } finally { $script:TeamsFillBusy = $false }
}

# Was gemeldet wird: Skript gewaehlt -> 'Script', sonst die eingebaute Meldung oben ('' = nichts gewaehlt)
function Get-HUTeamsFormKind {
    $c = $script:Controls
    $sn = $c['cmbTeamsJobSnippet'].SelectedItem
    if ($sn -and "$($sn.Tag)") { return 'Script' }
    return "$($c['cmbTeamsJobKind'].SelectedItem.Tag)"
}

# "Geraetenamen ausblenden" gibt es nur beim Defender-Alarm (Review 030 B2)
function Update-HUTeamsMaskState {
    $c = $script:Controls
    $kind = Get-HUTeamsFormKind
    $isDef = ($kind -eq 'Defender')
    $c['chkTeamsJobMask'].IsEnabled = $isDef
    $c['chkTeamsJobMask'].Opacity = $(if ($isDef) { 1.0 } else { 0.5 })
    $c['chkTeamsJobMask'].Visibility = $(if ($kind -eq 'Script') { 'Collapsed' } else { 'Visible' })
}

# @param-Felder des gewaehlten Skripts an der Meldung (wie oben im Quick Script); Werte: gespeicherte, sonst Standard
$script:TeamsParamCtl = @{}
$script:TeamsParamDefs = @()
function Update-HUTeamsJobParams($Values = $null) {
    $c = $script:Controls
    $panel = $c['pnlTeamsJobParams']
    # aktuelle Eingaben behalten, wenn keine gespeicherten Werte uebergeben werden (z. B. Skript neu gewaehlt)
    if ($null -eq $Values) { $Values = Get-HUTeamsJobParamValues }
    $panel.Children.Clear(); $script:TeamsParamCtl = @{}; $script:TeamsParamDefs = @()
    $sn = $c['cmbTeamsJobSnippet'].SelectedItem
    $code = ''
    if ($sn -and "$($sn.Tag)") { try { $code = Get-HUTeamsSnippetCode -AppRoot $script:AppRoot -Name "$($sn.Tag)" } catch { } }
    $defs = @(Get-HUQSParams $code)
    $script:TeamsParamDefs = $defs
    if (-not $defs.Count) { $panel.Visibility = 'Collapsed'; return }
    foreach ($p in $defs) {
        $has = ($Values -is [System.Collections.IDictionary]) -and $Values.Contains($p.Name)
        $v = if ($has) { $Values[$p.Name] } else { $p.Default }
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.Margin = [System.Windows.Thickness]::new(0, 2, 16, 2)
        if ($p.Type -eq 'bool') {
            $ctl = New-Object System.Windows.Controls.CheckBox
            $ctl.Content = $p.Label; $ctl.Foreground = Get-HUBrush '#CCCCCC'; $ctl.VerticalAlignment = 'Center'
            $ctl.IsChecked = [bool](ConvertTo-HUQSParamValue $p $v)
            if ($p.Name -match '^(DryRun|WhatIf|Simulation|Simulate|Test|TestMode|Probelauf|NurAnzeigen|Preview)$') { $ctl.Foreground = Get-HUBrush '#FF9800'; $ctl.ToolTip = 'Aus = echter Lauf (beim Speichern kommt eine Rueckfrage)' }
            [void]$sp.Children.Add($ctl)
        }
        else {
            $lb = New-Object System.Windows.Controls.TextBlock
            $lb.Text = "$($p.Label):"; $lb.Foreground = Get-HUBrush '#AAAAAA'; $lb.VerticalAlignment = 'Center'; $lb.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
            [void]$sp.Children.Add($lb)
            if ($p.Type -eq 'choice') {
                $ctl = New-Object System.Windows.Controls.ComboBox
                $ctl.Style = $script:Window.FindResource('DarkComboBox'); $ctl.FontSize = 11
                foreach ($ch in $p.Choices) { [void]$ctl.Items.Add($ch) }
                if ($p.Choices -contains "$v") { $ctl.SelectedItem = "$v" } elseif ($ctl.Items.Count) { $ctl.SelectedIndex = 0 }
            }
            else {
                $ctl = New-Object System.Windows.Controls.TextBox
                $ctl.Style = $script:Window.FindResource('DarkTextBox'); $ctl.FontSize = 11
                $ctl.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
                $ctl.MinWidth = $(if ($p.Type -eq 'int') { 60 } else { 140 })
                $ctl.Text = "$v"
            }
            [void]$sp.Children.Add($ctl)
        }
        $script:TeamsParamCtl[$p.Name] = $ctl
        [void]$panel.Children.Add($sp)
    }
    $panel.Visibility = 'Visible'
}

# Werte der @param-Felder an der Meldung (Name -> Wert); Typpruefung wie im Quick Script
function Get-HUTeamsJobParamValues([switch]$Check) {
    $h = [ordered]@{}
    foreach ($p in @($script:TeamsParamDefs)) {
        $ctl = $script:TeamsParamCtl[$p.Name]
        if (-not $ctl) { continue }
        $raw = if ($ctl -is [System.Windows.Controls.CheckBox]) { [bool]$ctl.IsChecked } elseif ($ctl -is [System.Windows.Controls.ComboBox]) { "$($ctl.SelectedItem)" } else { "$($ctl.Text)".Trim() }
        if ($Check) { $raw = ConvertTo-HUQSParamValue $p $raw }   # wirft bei falscher Zahl
        $h[$p.Name] = $raw
    }
    return $h
}

# Skript-Auswahl: gespeicherte Quick-Script-Snippets (Auswahl bleibt, auch wenn das Snippet inzwischen fehlt)
function Update-HUTeamsSnippetCombo {
    param($Select = $null)   # untypisiert: [string] macht aus `$null '' - dann ginge die Auswahl beim Aufklappen verloren
    $cb = $script:Controls['cmbTeamsJobSnippet']
    $wasBusy = $script:TeamsFillBusy; $script:TeamsFillBusy = $true   # Neuaufbau ist keine Auswahl (Felder-Werte bleiben)
    try {
    $cur = if ($null -ne $Select) { $Select } elseif ($cb.SelectedItem) { "$($cb.SelectedItem.Tag)" } else { '' }
    $names = @(Get-HUSnippets | ForEach-Object { "$($_.name)" } | Sort-Object)
    $cb.Items.Clear()
    $none = New-Object System.Windows.Controls.ComboBoxItem; $none.Content = '(kein Skript - eingebaute Meldung oben)'; $none.Tag = ''; $none.Foreground = Get-HUBrush '#888888'
    [void]$cb.Items.Add($none); if (-not $cur) { $cb.SelectedItem = $none }
    foreach ($n in $names) { $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Content = $n; $i.Tag = $n; [void]$cb.Items.Add($i); if ($n -eq $cur) { $cb.SelectedItem = $i } }
    if ($cur -and $names -notcontains $cur) {
        $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Content = "$cur (fehlt!)"; $i.Tag = $cur; $i.Foreground = Get-HUBrush '#F44336'
        [void]$cb.Items.Insert(0, $i); $cb.SelectedItem = $i
    }
    } finally { $script:TeamsFillBusy = $wasBusy }
}

# Skript-Meldung: wurde das Snippet seit dem Speichern geaendert? (Review 030 B33) - '' = passt, sonst Hinweistext
function Get-HUTeamsScriptState($Job) {
    if (-not $Job -or "$($Job.Kind)" -ne 'Script') { return '' }
    $sn = "$($Job.Options.snippet)"
    try { $code = Get-HUTeamsSnippetCode -AppRoot $script:AppRoot -Name $sn } catch { return "Skript '$sn' fehlt" }
    $want = "$(if ($Job.Options.PSObject.Properties['snippetHash']) { $Job.Options.snippetHash })"
    if ($want -ne (Get-HUTeamsCodeHash $code)) { return "Skript '$sn' geaendert - Meldung neu speichern" }
    return ''
}

function Get-HUTeamsJobFromForm {
    param([string]$Purpose = '')   # 'Speichern' / 'Jetzt senden': echter Lauf eines Skripts wird bestaetigt (Review 030 B34)
    $c = $script:Controls
    $name = "$($c['txtTeamsJobName'].Text)".Trim()
    if (-not $name) { throw 'Bitte einen Namen eingeben.' }
    $time = "$($c['txtTeamsJobTime'].Text)".Trim()
    if ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw 'Uhrzeit bitte als HH:mm (z. B. 07:00).' }
    $kind = Get-HUTeamsFormKind
    if (-not $kind) { throw 'Bitte eine eingebaute Meldung oder ein Skript waehlen.' }
    $cat = $kind   # Fusszeilen-Kennzeichnung = Art
    $days = @($c['pnlTeamsJobDays'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { [int]$_.Tag })
    $all = @($script:Settings.tenants | ForEach-Object { "$($_.key)" })
    $keys = @(Get-HUCheckedTenants $c['pnlTeamsJobTenants'])
    if (-not $keys.Count) { throw 'Bitte mindestens einen Tenant anhaken.' }
    if ($keys.Count -eq $all.Count) { $keys = @() }   # leer = alle (auch spaeter angelegte)
    $old = $null
    if ($script:TeamsJobCurrent) { $old = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent }
    $j = if ($old) { $old } else { New-HUTeamsJob -Name $name -Kind $kind }
    $j.Name = $name; $j.Kind = $kind; $j.Time = ('{0:D2}:{1}' -f [int]($time.Split(':')[0]), $time.Split(':')[1])
    $j.Days = $days; $j.Tenants = $keys; $j.Category = $cat; $j.Enabled = [bool]$c['chkTeamsJobEnabled'].IsChecked
    if ($null -eq $j.Options) { $j | Add-Member -NotePropertyName Options -NotePropertyValue ([pscustomobject]@{}) -Force }
    $j.Options | Add-Member -NotePropertyName maskDevices -NotePropertyValue ([bool]$c['chkTeamsJobMask'].IsChecked) -Force
    if ($kind -eq 'Script') {
        $sn = if ($c['cmbTeamsJobSnippet'].SelectedItem) { "$($c['cmbTeamsJobSnippet'].SelectedItem.Tag)" } else { '' }
        if (-not $sn) { throw 'Bitte ein Skript waehlen (gespeichertes Snippet aus Quick Script).' }
        $code = Get-HUTeamsSnippetCode -AppRoot $script:AppRoot -Name $sn
        # Review 030 B34: Probelauf-Schalter (DryRun ...) steht im Standard auf aus -> echter Lauf ohne Aufsicht
        $defs = @(Get-HUQSParams $code)
        $form = Get-HUTeamsJobParamValues -Check   # Werte aus den Feldern an der Meldung
        $vals = @{}
        foreach ($p in $defs) { $vals[$p.Name] = $(if ($form.Contains($p.Name)) { $form[$p.Name] } else { try { ConvertTo-HUQSParamValue $p $p.Default } catch { $p.Default } }) }
        if ($Purpose -and (Test-HUQSLiveRun $defs $vals)) {
            $tn = @($keys | ForEach-Object { $k = $_; $tt = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1; if ($tt) { "$($tt.displayName)" } else { $k } })
            if (-not $tn.Count) { $tn = @($script:Settings.tenants | ForEach-Object { "$($_.displayName)" }) }
            $what = if ($Purpose -eq 'Speichern') { "Die Meldung fuehrt das Skript bei JEDEM Lauf - auch zeitgesteuert, ohne Aufsicht - als echten Lauf aus." } else { 'Das Skript laeuft jetzt als echter Lauf.' }
            if (-not (Confirm-HU "ECHTER LAUF - Aenderungen werden ausgefuehrt!`n`nSkript: $sn (Probelauf-Schalter ist aus)`nTenants: $($tn -join ', ')`n`n$what`n`nFortfahren?" 'Teams - Meldung aus Skript' -Warning)) { return $null }
        }
        $j.Options | Add-Member -NotePropertyName snippet -NotePropertyValue $sn -Force
        $j.Options | Add-Member -NotePropertyName snippetHash -NotePropertyValue (Get-HUTeamsCodeHash $code) -Force   # Review 030 B33
        $j.Options | Add-Member -NotePropertyName params -NotePropertyValue ([pscustomobject]$vals) -Force
    }
    $allT = @($c['pnlTeamsJobTargets'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
    $selT = @($allT | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    if ($allT.Count -and -not $selT.Count) { throw 'Bitte mindestens ein Ziel anhaken (zum Stummschalten den Auftrag deaktivieren).' }   # Befund B1 (Review 029)
    # alle angehakt = leer = alle (auch spaetere). Nicht $(if ...) - das macht aus @() ein $null
    if ($selT.Count -eq $allT.Count) { $j.Targets = @() } else { $j.Targets = @($selT) }
    return $j
}

function Save-HUTeamsJob {
    try {
        $j = Get-HUTeamsJobFromForm -Purpose 'Speichern'
        if (-not $j) { return }
        Invoke-HUTeamsJobsLocked {
            $jobs = @(Get-HUTeamsJobs -AppRoot $script:AppRoot | Where-Object { $_.Id -ne $j.Id })
            $jobs += $j
            Set-HUTeamsJobs -AppRoot $script:AppRoot -Jobs $jobs
        }
        $script:TeamsJobCurrent = "$($j.Id)"
        # bestehende Aufgabe an den neuen Zeitplan anpassen
        if ((Get-HUTeamsJobTask -Job $j).Exists) { $r = Register-HUTeamsJobTask -Job $j -AppRoot $script:AppRoot; if ($r) { Write-HULogWarn $r } }
        Update-HUTeamsJobs
        Show-HUTeamsJob $j
        Write-HULogOK "Teams-Meldung '$($j.Name)' gespeichert."
    } catch { Show-HUMessage $_.Exception.Message -Icon Warning }
}

function Remove-HUTeamsJob {
    if (-not $script:TeamsJobCurrent) { return }
    $j = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent
    if (-not $j) { return }
    if (-not (Confirm-HU "Meldung '$($j.Name)' entfernen (inkl. Aufgabe in der Aufgabenplanung)?$(if ("$($j.Kind)" -eq 'Script') { "`n`nDas Snippet selbst bleibt in Quick Script erhalten." })" -Warning)) { return }
    $r = Unregister-HUTeamsJobTask -Job $j; if ($r) { Write-HULogWarn $r }
    try { Invoke-HUTeamsJobsLocked { Set-HUTeamsJobs -AppRoot $script:AppRoot -Jobs @(Get-HUTeamsJobs -AppRoot $script:AppRoot | Where-Object { $_.Id -ne $j.Id }) } }
    catch { Show-HUMessage $_.Exception.Message -Icon Warning; return }
    $script:TeamsJobCurrent = ''
    Update-HUTeamsJobs
    Show-HUTeamsJob $null
}

function Switch-HUTeamsJobTask {
    if (-not $script:TeamsJobCurrent) { Show-HUMessage 'Bitte die Meldung zuerst speichern.' -Icon Warning; return }
    $j = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent
    if (-not $j) { return }
    $t = Get-HUTeamsJobTask -Job $j
    if ($t.Exists) {
        $r = Unregister-HUTeamsJobTask -Job $j
        if ($r) { Show-HUMessage $r -Icon Error } else { Write-HULogOK "Aufgabe fuer '$($j.Name)' entfernt." }
    }
    else {
        if (-not (Get-HUNotifyConfig).Configured) { Show-HUMessage 'Noch kein Teams-Ziel gespeichert - die Aufgabe haette nichts, wohin sie senden kann.' -Icon Warning; return }
        $r = Register-HUTeamsJobTask -Job $j -AppRoot $script:AppRoot
        if ($r) { Show-HUMessage $r -Icon Error }
        else { Write-HULogOK "Aufgabe '\HU-MultiTenant\$(Get-HUTeamsJobTaskName $j)' angelegt: $(Get-HUTeamsJobLabel $j), Konto $env:USERNAME (nur bei Anmeldung)." }
    }
    Update-HUTeamsJobTaskLabel $j
}

# Pulsierender gruener Punkt vor der Statuszeile, solange eine Meldung laeuft (wie HUMig)
function Set-HUTeamsRunDot([bool]$On) {
    $d = $script:Controls['dotTeamsJobRun']
    if (-not $d) { return }
    if ($On) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 1.0; $a.To = 0.2; $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
        $a.AutoReverse = $true; $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $d.Visibility = 'Visible'
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }
    else {
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $d.Opacity = 1.0; $d.Visibility = 'Collapsed'
    }
}

function Start-HUTeamsJobNow {
    param([string]$TargetId = '', [string]$TargetName = '')
    $c = $script:Controls
    try { $j = Get-HUTeamsJobFromForm -Purpose 'Jetzt senden' } catch { Show-HUMessage $_.Exception.Message -Icon Warning; return }
    if (-not $j) { return }
    if (-not (Get-HUNotifyConfig).Configured) { Show-HUMessage 'Noch kein Teams-Ziel gespeichert.' -Icon Warning; return }
    $c['btnTeamsJobRun'].IsEnabled = $false; $c['btnTeamsJobSendTo'].IsEnabled = $false
    $c['lblTeamsJobTask'].Text = "'$($j.Name)' laeuft$(if ($TargetName) { " - einmalig an '$TargetName'" }) - $(if ("$($j.Kind)" -eq 'Script') { "Skript '$($j.Options.snippet)' laeuft je Tenant" } else { 'Tenants werden gelesen' }) (siehe Protokoll unten links) ..."
    $ids = @(); if ($TargetId) { $ids = @($TargetId) }
    Set-HUTeamsRunDot $true
    $ok = Start-HUJob -Name 'TeamsJob' -Output $c['rtbLog'] -Vars @{ TJob = $j; TIds = $ids } -Code {
        foreach ($m in 'HU.Notify', 'HU.TeamsJobs') { Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking -ErrorAction Stop }
        Grant-HUSendApproval -Reason 'Jetzt senden'   # Klick auf "Jetzt senden" ist die Freigabe (Review 030 B4a)
        $r = Invoke-HUTeamsJob -Job $TJob -Settings $Settings -AppRoot $AppRoot -TargetIds $TIds
        [pscustomobject]@{ __TeamsDone = $true; Success = $r.Success; Message = "$($r.Message)" }
    } -OnDone {
        param($Result, $Errors)
        $c = $script:Controls
        Set-HUTeamsRunDot $false
        $c['btnTeamsJobRun'].IsEnabled = $true; $c['btnTeamsJobSendTo'].IsEnabled = $true
        $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__TeamsDone'] }) | Select-Object -First 1
        $msg = if ($d) { $d.Message } elseif ($Errors.Count) { $Errors -join '; ' } else { 'kein Ergebnis' }
        if ($d -and $d.Success) { Write-HULogOK "Teams: $msg" } else { Write-HULogError "Teams: $msg" }
        Update-HUTeamsHist
        Update-HUTeamsJobs
        $j2 = $null; if ($script:TeamsJobCurrent) { $j2 = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent }
        Update-HUTeamsJobTaskLabel $j2
    }
    if (-not $ok) { Set-HUTeamsRunDot $false; $c['btnTeamsJobRun'].IsEnabled = $true; $c['btnTeamsJobSendTo'].IsEnabled = $true }
}

# "An Kanal ...": Menue mit allen aktiven Zielen, Klick sendet die Meldung einmalig nur dorthin
function Show-HUTeamsSendToMenu {
    $c = $script:Controls
    $cfg = Get-HUNotifyConfig
    $targets = @($cfg.Targets | Where-Object { $_ -and $_.Enabled })
    if (-not $targets.Count) { Show-HUMessage 'Kein aktives Teams-Ziel gespeichert.' -Icon Warning; return }
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($t in $targets) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = "$($t.Name)"
        $mi.Tag = @{ Id = "$($t.Id)"; Name = "$($t.Name)" }
        $mi.Add_Click({ Start-HUTeamsJobNow -TargetId $this.Tag.Id -TargetName $this.Tag.Name })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $c['btnTeamsJobSendTo']
    $menu.Placement = 'Top'
    $menu.IsOpen = $true
}

# ============================================================================
# PROTOKOLL
# ============================================================================

function Update-HUTeamsHist {
    $rows = New-Object System.Collections.ArrayList
    foreach ($h in @(Get-HUNotifyHistory -Last 200)) {
        $z = "$($h.Time)"; try { $z = ([datetime]$h.Time).ToString('dd.MM.yyyy HH:mm') } catch { }
        [void]$rows.Add([pscustomobject]@{ Zeit = $z; Ziel = "$($h.Target) [$($h.Tag)]"; Kategorie = "$($h.Category)"; Titel = "$($h.Title)"; Ergebnis = "$($h.Result)" })
    }
    $script:Controls['gridTeamsHist'].ItemsSource = $rows
}

# ============================================================================
# EREIGNISSE
# ============================================================================

function Register-HUTeamsHandlers {
    $c = $script:Controls
    # Ziel: nur noch der Haken fuer Fehlermeldungen
    Update-HUTeamsCatChecks
    # Skript-Auswahl beim Aufklappen neu lesen (Snippets koennen inzwischen gespeichert worden sein)
    $c['cmbTeamsJobSnippet'].Add_DropDownOpened({ Update-HUTeamsSnippetCombo })
    $c['cmbTeamsJobSnippet'].Add_SelectionChanged({
        if ($script:TeamsFillBusy) { return }
        $c2 = $script:Controls
        $it = $c2['cmbTeamsJobSnippet'].SelectedItem
        Update-HUTeamsMaskState
        Update-HUTeamsJobParams @{}   # neues Skript: Standardwerte
        if (-not $it -or -not "$($it.Tag)") { return }
        # Skript gewaehlt: oben keine eingebaute Meldung (entweder - oder)
        $script:TeamsFillBusy = $true
        try { $c2['cmbTeamsJobKind'].SelectedItem = $null } finally { $script:TeamsFillBusy = $false }
        # Name folgt dem Skript, solange im Feld ein Standardname steht
        $cur = "$($c2['txtTeamsJobName'].Text)".Trim()
        $std = @(Get-HUTeamsKinds | ForEach-Object { "$($_.Label)" }) + @(Get-HUSnippets | ForEach-Object { "$($_.name)" })
        if (-not $cur -or $std -contains $cur) { $c2['txtTeamsJobName'].Text = "$($it.Tag)" }
    })
    # Wochentage
    $c['pnlTeamsJobDays'].Children.Clear()
    $i = 0
    foreach ($d in 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So') {
        $i++
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $d; $cb.Tag = $i
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        [void]$c['pnlTeamsJobDays'].Children.Add($cb)
    }
    Update-HUTeamsJobTenantChecks

    $c['lstTeamsTargets'].Add_SelectionChanged({
        if ($script:TeamsFillBusy) { return }
        $it = $script:Controls['lstTeamsTargets'].SelectedItem
        if ($it) { Show-HUTeamsTarget $it.Tag }
    })
    $c['btnTeamsNew'].Add_Click({ $script:Controls['lstTeamsTargets'].SelectedItem = $null; Show-HUTeamsTarget $null })
    $c['btnTeamsSave'].Add_Click({ Save-HUTeamsTarget })
    $c['btnTeamsDel'].Add_Click({ Remove-HUTeamsTarget })
    $c['btnTeamsTest'].Add_Click({ Test-HUTeamsTarget })

    # Name folgt der gewaehlten Art, solange im Feld ein Standardname steht (eigene Namen bleiben)
    $c['cmbTeamsJobKind'].Add_SelectionChanged({
        Update-HUTeamsMaskState
        if ($script:TeamsFillBusy) { return }
        $c2 = $script:Controls
        $sel = $c2['cmbTeamsJobKind'].SelectedItem
        # eingebaute Meldung gewaehlt: Skript-Auswahl auf "kein Skript" (entweder - oder)
        if ($sel) {
            $script:TeamsFillBusy = $true
            try { $c2['cmbTeamsJobSnippet'].SelectedIndex = 0 } finally { $script:TeamsFillBusy = $false }
            Update-HUTeamsMaskState
            Update-HUTeamsJobParams @{}
        }
        $labels = @(Get-HUTeamsKinds | ForEach-Object { "$($_.Label)" }) + @(Get-HUSnippets | ForEach-Object { "$($_.name)" })
        $cur = "$($c2['txtTeamsJobName'].Text)".Trim()
        if ($cur -and ($labels -notcontains $cur)) { return }
        if ($sel) { $k = Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($sel.Tag)" } | Select-Object -First 1; if ($k) { $c2['txtTeamsJobName'].Text = "$($k.Label)" } }
    })

    $c['lstTeamsJobs'].Add_SelectionChanged({
        if ($script:TeamsFillBusy) { return }
        $it = $script:Controls['lstTeamsJobs'].SelectedItem
        if ($it -and -not $it.Kopf -and $it.Job) { Show-HUTeamsJob $it.Job }
    })
    $c['btnTeamsJobNew'].Add_Click({ $script:Controls['lstTeamsJobs'].SelectedItem = $null; Show-HUTeamsJob $null })
    $c['btnTeamsJobSave'].Add_Click({ Save-HUTeamsJob })
    $c['btnTeamsJobDel'].Add_Click({ Remove-HUTeamsJob })
    $c['btnTeamsJobRun'].Add_Click({ Start-HUTeamsJobNow })
    $c['btnTeamsJobSendTo'].Add_Click({ Show-HUTeamsSendToMenu })
    $c['btnTeamsJobTask'].Add_Click({ Switch-HUTeamsJobTask })
    $c['btnTeamsHistRefresh'].Add_Click({ Update-HUTeamsHist })

    Update-HUTeamsTargets
    Show-HUTeamsTarget $null
    Update-HUTeamsJobs
    Show-HUTeamsJob $null
    Update-HUTeamsHist
}

# Ziel-Haken fuer Auftraege (nach Anlegen/Loeschen von Zielen neu aufbauen; Auswahl bleibt)
function Update-HUTeamsJobTargetChecks {
    $sp = $script:Controls['pnlTeamsJobTargets']
    $was = @($sp.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $sp.Children.Clear()
    foreach ($t in @((Get-HUNotifyConfig).Targets | Where-Object { $_ -and $_.Enabled })) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.Name)"; $cb.Tag = "$($t.Id)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = ($was -contains "$($t.Id)")
        [void]$sp.Children.Add($cb)
    }
}

# Tenant-Haken fuer Auftraege (nach Aenderungen in den Einstellungen neu aufbauen)
function Update-HUTeamsJobTenantChecks {
    $sp = $script:Controls['pnlTeamsJobTenants']
    $sp.Children.Clear()
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"; $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = $true
        [void]$sp.Children.Add($cb)
    }
    Add-HUTenantAllToggle $sp { }
}

# Meldung(en) "Aus Skript", die dieses Snippet verwenden -> Route fuer Laeufe im Quick-Script-Editor (oder $null).
# Mehrere Meldungen mit demselben Snippet: Ziele zusammen; eine davon mit "alle Ziele" = alle.
function Get-HUTeamsSnippetRoute([string]$Snippet) {
    if (-not $Snippet) { return $null }
    $jobs = @()
    try { $jobs = @(Get-HUTeamsJobs -AppRoot $script:AppRoot | Where-Object { "$($_.Kind)" -eq 'Script' -and "$($_.Options.snippet)" -eq $Snippet }) } catch { return $null }
    if (-not $jobs.Count) { return $null }
    $all = @($jobs | Where-Object { -not @($_.Targets | Where-Object { "$_" }).Count }).Count -gt 0
    $ids = if ($all) { @() } else { @($jobs | ForEach-Object { $_.Targets } | Where-Object { "$_" } | ForEach-Object { "$_" } | Sort-Object -Unique) }
    return [pscustomobject]@{ Name = "$($jobs[0].Name)"; Ids = [string[]]$ids; Jobs = @($jobs | ForEach-Object { "$($_.Name)" }) }
}

# Review 030 B4 (Entscheidung Udo): Snippets/Erweiterungen, die Teams-Meldungen senden, fragen EINMAL je Lauf vorher.
function Confirm-HUTeamsSend {
    param([string]$Code, [string]$What = 'Snippet', $Route = $null)
    # Rueckgabe: send = Ja (Lauf bekommt die Sendefreigabe), skip = Nein, cancel = Abbrechen,
    # none = keine Frage noetig (kein Send-Aufruf im Code oder sicher kein Empfaenger) - der Lauf bekommt KEINE Freigabe.
    # Die Textsuche dient nur der Anzeige; gesperrt wird im Modul selbst (Review 030 B4a).
    # -Route: das Snippet gehoert zu einer Meldung "Aus Skript" - dann gehen alle Karten an deren Ziele.
    if ("$Code" -notmatch '(?i)\bSend-HU(Notify|TeamsCard)\b') { return 'none' }
    $cfg = Get-HUNotifyConfig
    $targets = @($cfg.Targets | Where-Object { $_ -and $_.Enabled })
    if (-not $targets.Count) { return 'none' }   # kein aktives Ziel - es kann nichts rausgehen
    if ($Route) {
        $to = @($targets | Where-Object { -not @($Route.Ids).Count -or @($Route.Ids) -contains "$($_.Id)" } | ForEach-Object { "$($_.Name)" })
        if (-not $to.Count) { Write-HULogWarn "Teams: Meldung '$($Route.Name)' hat kein aktives Ziel - es wird nichts gesendet."; return 'none' }
        $txt = "Dieses $What gehoert zur Meldung '$($Route.Name)'$(if (@($Route.Jobs).Count -gt 1) { " (und $(@($Route.Jobs).Count - 1) weiteren)" }) und sendet an:`n`n   $($to -join ', ')`n`n"
    }
    else {
        # ohne Meldung: nur noch alte eigene Kategorien aus den 2.1.10-Testversionen senden
        $known = @(Get-HUNotifyCategories | ForEach-Object { $_.Key })
        $cats = @([regex]::Matches("$Code", '(?i)-Category\s+[''"]?([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $known -contains $_ })
        $direct = "$Code" -match '(?i)-TargetIds\b|-IgnoreCategory\b|\bSend-HUTeamsCard\b|-Category\s+\$'   # Ziel/Kategorie nicht sicher erkennbar
        $to = @($targets | Where-Object { $t = $_; @($cats | Where-Object { Test-HUNotifyCat -Target $t -Category $_ }).Count } | ForEach-Object { "$($_.Name)" })
        if (-not $direct -and -not $to.Count) {
            Write-HULogWarn "Teams: Dieses $What ist keiner Meldung zugeordnet - es wird nichts gesendet. Reiter Teams > Meldungen > + Neu > 'oder Meldung aus Skript' und dieses Snippet waehlen."
            return 'none'
        }
        $txt = "Dieses $What kann Meldungen an Teams senden.`n`nGeht an: $(if ($to.Count) { $to -join ', ' } else { 'im Code nicht sicher erkennbar' })`n`n"
    }
    $txt += "Ja = ausfuehren UND an Teams senden`nNein = ausfuehren, aber nichts an Teams senden`nAbbrechen = nicht ausfuehren"
    switch (Confirm-HUYesNoCancel -Text $txt -Title 'Teams-Meldungen senden?') {
        'Yes' { return 'send' }
        'No' { return 'skip' }
        default { return 'cancel' }
    }
}
