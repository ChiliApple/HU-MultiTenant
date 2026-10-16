#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter Teams: Ziele (Workflows-Webhooks), zeitgesteuerte Meldungen (Auftraege + Aufgabenplanung), Sendeprotokoll.
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
        foreach ($cb in @($c['pnlTeamsCats'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) {
            $cb.IsChecked = (Test-HUNotifyCat -Target $Target -Category "$($cb.Tag)")
        }
        $c['btnTeamsDel'].IsEnabled = [bool]$Target
        $c['btnTeamsTest'].IsEnabled = $true
        $c['lblTeamsHint'].Text = if ($Target) { "Ziel $($Target.Name) - Kennung $(Get-HUNotifyUrlTag $Target.Url). Adresse ist gespeichert (verschluesselt) und wird nicht angezeigt." } else { 'Neues Ziel: Name, Webhook-Adresse, Kategorien - dann Speichern.' }
    } finally { $script:TeamsFillBusy = $false }
}

function Get-HUTeamsCatsFromPanel {
    $h = @{}
    foreach ($cb in @($script:Controls['pnlTeamsCats'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) { $h["$($cb.Tag)"] = [bool]$cb.IsChecked }
    return $h
}

function Save-HUTeamsTarget {
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
    $list = @($cfg.Targets | Where-Object { $_.Id -ne $script:TeamsCurrent })
    $list += [pscustomobject]@{ Id = $script:TeamsCurrent; Name = $name; Url = $url; Enabled = [bool]$c['chkTeamsEnabled'].IsChecked; Cats = (Get-HUTeamsCatsFromPanel); Created = $(if ($old) { $old.Created } else { '' }) }
    $r = Set-HUNotifyTargets -Targets $list
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
    else { $c['lblTeamsHint'].Text = 'Testnachricht gesendet - bitte im Teams-Kanal pruefen.'; Write-HULogOK "Teams-Testnachricht an '$name' gesendet." }
}

# ============================================================================
# AUFTRAEGE
# ============================================================================

function Get-HUTeamsJobLabel($Job) {
    $d = @($Job.Days | ForEach-Object { [int]$_ })
    $when = if ($d.Count) { ($d | Sort-Object | ForEach-Object { @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So')[$_ - 1] }) -join '' } else { 'taeglich' }
    $kindLabel = "$((Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($Job.Kind)" }).Label)"
    $nm = "$($Job.Name)"
    if ($kindLabel -and $nm -ne $kindLabel) { $nm = "$nm ($kindLabel)" }
    $tids = @($Job.Targets | Where-Object { "$_" })
    $to = 'alle Ziele'
    if ($tids.Count) {
        $all = @((Get-HUNotifyConfig).Targets)
        $names = @($tids | ForEach-Object { $id = "$_"; $t = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if ($t) { "$($t.Name)" } else { '?' } })
        $to = $names -join ', '
    }
    return "$(if ($Job.Enabled) { '' } else { '(aus) ' })$nm  -  $when $($Job.Time)  -  an $to"
}

function Update-HUTeamsJobs {
    $c = $script:Controls
    $lb = $c['lstTeamsJobs']
    $jobs = @()
    try { $jobs = @(Get-HUTeamsJobs -AppRoot $script:AppRoot) } catch { Write-HULogError $_.Exception.Message }
    $script:TeamsFillBusy = $true
    try {
        $lb.Items.Clear()
        $sel = $null
        foreach ($j in $jobs) {
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = (Get-HUTeamsJobLabel $j)
            $li.Tag = $j
            [void]$lb.Items.Add($li)
            if ("$($j.Id)" -eq $script:TeamsJobCurrent) { $sel = $li }
        }
        $lb.SelectedItem = $sel
    } finally { $script:TeamsFillBusy = $false }
}

function Update-HUTeamsJobTaskLabel($Job) {
    $c = $script:Controls
    if (-not $Job) { $c['lblTeamsJobTask'].Text = 'Neuer Auftrag: Name, Uhrzeit, Tenants - dann Speichern. Danach "Aufgabe anlegen" fuer den automatischen Lauf.'; $c['btnTeamsJobTask'].Content = 'Aufgabe anlegen'; $c['btnTeamsJobTask'].IsEnabled = $false; return }
    $t = Get-HUTeamsJobTask -Job $Job
    $c['btnTeamsJobTask'].IsEnabled = $true
    if ($t.Exists) {
        $c['btnTeamsJobTask'].Content = 'Aufgabe entfernen'
        $next = if ($t.NextRun) { ([datetime]$t.NextRun).ToString('dd.MM. HH:mm') } else { '-' }
        $last = if ($t.LastRun -and ([datetime]$t.LastRun).Year -gt 2000) { ([datetime]$t.LastRun).ToString('dd.MM. HH:mm') + " (Code $($t.LastResult))" } else { 'noch nie' }
        $c['lblTeamsJobTask'].Text = "Aufgabenplanung: $($t.State), naechster Lauf $next, letzter Lauf $last.`nLetztes Ergebnis: $(if ($Job.LastResult) { $Job.LastResult } else { '-' })"
    }
    else {
        $c['btnTeamsJobTask'].Content = 'Aufgabe anlegen'
        $c['lblTeamsJobTask'].Text = "Keine Aufgabe in der Aufgabenplanung - der Auftrag laeuft nur ueber 'Jetzt senden'.`nLetztes Ergebnis: $(if ($Job.LastResult) { $Job.LastResult } else { '-' })"
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
        $kind = if ($Job) { "$($Job.Kind)" } else { 'Daily' }
        foreach ($i in $c['cmbTeamsJobKind'].Items) { if ("$($i.Tag)" -eq $kind) { $c['cmbTeamsJobKind'].SelectedItem = $i } }
        Update-HUTeamsJobTargetChecks
        $tids = @(if ($Job) { $Job.Targets | ForEach-Object { "$_" } } else { @() })
        foreach ($cb in @($c['pnlTeamsJobTargets'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) { $cb.IsChecked = ($tids -contains "$($cb.Tag)") }
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

function Get-HUTeamsJobFromForm {
    $c = $script:Controls
    $name = "$($c['txtTeamsJobName'].Text)".Trim()
    if (-not $name) { throw 'Bitte einen Namen eingeben.' }
    $time = "$($c['txtTeamsJobTime'].Text)".Trim()
    if ($time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw 'Uhrzeit bitte als HH:mm (z. B. 07:00).' }
    $kind = "$($c['cmbTeamsJobKind'].SelectedItem.Tag)"; if (-not $kind) { $kind = 'Daily' }
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
    $allT = @($c['pnlTeamsJobTargets'].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
    $selT = @($allT | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $j.Targets = $(if ($selT.Count -eq $allT.Count) { @() } else { $selT })   # alle angehakt = leer = alle (auch spaetere)
    return $j
}

function Save-HUTeamsJob {
    try {
        $j = Get-HUTeamsJobFromForm
        $jobs = @(Get-HUTeamsJobs -AppRoot $script:AppRoot | Where-Object { $_.Id -ne $j.Id })
        $jobs += $j
        Set-HUTeamsJobs -AppRoot $script:AppRoot -Jobs $jobs
        $script:TeamsJobCurrent = "$($j.Id)"
        # bestehende Aufgabe an den neuen Zeitplan anpassen
        if ((Get-HUTeamsJobTask -Job $j).Exists) { $r = Register-HUTeamsJobTask -Job $j -AppRoot $script:AppRoot; if ($r) { Write-HULogWarn $r } }
        Update-HUTeamsJobs
        Show-HUTeamsJob $j
        Write-HULogOK "Teams-Auftrag '$($j.Name)' gespeichert."
    } catch { Show-HUMessage $_.Exception.Message -Icon Warning }
}

function Remove-HUTeamsJob {
    if (-not $script:TeamsJobCurrent) { return }
    $j = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent
    if (-not $j) { return }
    if (-not (Confirm-HU "Auftrag '$($j.Name)' entfernen (inkl. Aufgabe in der Aufgabenplanung)?" -Warning)) { return }
    $r = Unregister-HUTeamsJobTask -Job $j; if ($r) { Write-HULogWarn $r }
    Set-HUTeamsJobs -AppRoot $script:AppRoot -Jobs @(Get-HUTeamsJobs -AppRoot $script:AppRoot | Where-Object { $_.Id -ne $j.Id })
    $script:TeamsJobCurrent = ''
    Update-HUTeamsJobs
    Show-HUTeamsJob $null
}

function Switch-HUTeamsJobTask {
    if (-not $script:TeamsJobCurrent) { Show-HUMessage 'Bitte den Auftrag zuerst speichern.' -Icon Warning; return }
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

function Start-HUTeamsJobNow {
    param([string]$TargetId = '', [string]$TargetName = '')
    $c = $script:Controls
    try { $j = Get-HUTeamsJobFromForm } catch { Show-HUMessage $_.Exception.Message -Icon Warning; return }
    if (-not (Get-HUNotifyConfig).Configured) { Show-HUMessage 'Noch kein Teams-Ziel gespeichert.' -Icon Warning; return }
    $c['btnTeamsJobRun'].IsEnabled = $false; $c['btnTeamsJobSendTo'].IsEnabled = $false
    $c['lblTeamsJobTask'].Text = "'$($j.Name)' laeuft$(if ($TargetName) { " - einmalig an '$TargetName'" }) - Tenants werden gelesen (siehe Protokoll unten links) ..."
    $ids = @(); if ($TargetId) { $ids = @($TargetId) }
    $ok = Start-HUJob -Name 'TeamsJob' -Output $c['rtbLog'] -Vars @{ TJob = $j; TIds = $ids } -Code {
        foreach ($m in 'HU.Notify', 'HU.TeamsJobs') { Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking -ErrorAction Stop }
        $r = Invoke-HUTeamsJob -Job $TJob -Settings $Settings -AppRoot $AppRoot -TargetIds $TIds
        [pscustomobject]@{ __TeamsDone = $true; Success = $r.Success; Message = "$($r.Message)" }
    } -OnDone {
        param($Result, $Errors)
        $c = $script:Controls
        $c['btnTeamsJobRun'].IsEnabled = $true; $c['btnTeamsJobSendTo'].IsEnabled = $true
        $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__TeamsDone'] }) | Select-Object -First 1
        $msg = if ($d) { $d.Message } elseif ($Errors.Count) { $Errors -join '; ' } else { 'kein Ergebnis' }
        if ($d -and $d.Success) { Write-HULogOK "Teams: $msg" } else { Write-HULogError "Teams: $msg" }
        Update-HUTeamsHist
        Update-HUTeamsJobs
        $j2 = $null; if ($script:TeamsJobCurrent) { $j2 = Get-HUTeamsJob -AppRoot $script:AppRoot -Id $script:TeamsJobCurrent }
        Update-HUTeamsJobTaskLabel $j2
    }
    if (-not $ok) { $c['btnTeamsJobRun'].IsEnabled = $true; $c['btnTeamsJobSendTo'].IsEnabled = $true }
}

# "An Kanal ...": Menue mit allen aktiven Zielen, Klick sendet den Auftrag einmalig nur dorthin
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
    # Kategorien-Haken
    $c['pnlTeamsCats'].Children.Clear()
    foreach ($k in @(Get-HUNotifyCategories)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $k.Label; $cb.Tag = $k.Key; $cb.IsChecked = $k.Default
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 12, 1)
        [void]$c['pnlTeamsCats'].Children.Add($cb)
    }
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
        if ($script:TeamsFillBusy) { return }
        $c2 = $script:Controls
        $labels = @(Get-HUTeamsKinds | ForEach-Object { "$($_.Label)" })
        $cur = "$($c2['txtTeamsJobName'].Text)".Trim()
        if ($cur -and ($labels -notcontains $cur)) { return }
        $sel = $c2['cmbTeamsJobKind'].SelectedItem
        if ($sel) { $k = Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($sel.Tag)" } | Select-Object -First 1; if ($k) { $c2['txtTeamsJobName'].Text = "$($k.Label)" } }
    })

    $c['lstTeamsJobs'].Add_SelectionChanged({
        if ($script:TeamsFillBusy) { return }
        $it = $script:Controls['lstTeamsJobs'].SelectedItem
        if ($it) { Show-HUTeamsJob $it.Tag }
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
