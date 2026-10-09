#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Wartung": Wartungsskripte (Intune Remediations) mit KI erstellen, pruefen, verteilen und auswerten.
.DESCRIPTION
    Ablauf fuer Menschen:
      1. "+ Neu" oder "Beispiele ..." - Aufgabe in einem Satz beschreiben, "Prompt kopieren", in die KI einfuegen,
         Antwort kopieren und "Antwort einfuegen" (wird in Pruef- und Reparaturskript aufgeteilt).
      2. "Pruefen" findet typische Fehler (exit 1 fehlt, Neustart, Eingaben, PowerShell-7-Syntax ...).
      3. Tenants, Ziel und Zeitplan waehlen, "Hochladen & zuweisen" (optional zuerst Pilotgruppe).
      4. "Ergebnisse" zeigt je Geraet: Problem gefunden, behoben, Fehler, Ausgabe. "Jetzt auf Geraet ..." startet sofort.
    Bibliothek: Config\remediations.json (lokal). Beispiele: Config\remediations.example.json.
    Lizenz: Remediations brauchen Windows Enterprise/Education E3/A3 o. ae. und einmalig im Intune Admin Center
    "Mandantenverwaltung > Connectors und Token > Windows-Datenverarbeitung > Windows-Lizenzueberpruefung" eingeschaltet.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:RemLib = New-Object System.Collections.Generic.List[object]
$script:RemCurrent = $null
$script:RemLoading = $false
$script:RemLastResults = @()
$script:RemLastResultsName = ''
$script:RemPickBusy = $false

function Get-HURemLibPath { return (Join-Path $script:AppRoot 'Config\remediations.json') }

function ConvertTo-HURem($Src = $null) {
    $r = [pscustomobject][ordered]@{
        Id = [guid]::NewGuid().ToString(); Name = ''; Description = ''; AiTask = ''; Detection = ''; Remediation = ''
        RunAs = 'system'; RunAs32 = $false; TargetKind = 'group'; TargetGroup = ''; Pilot = $false; PilotGroup = ''
        ScheduleType = 'daily'; Interval = 1; Time = '08:00'; Date = ''
        Tenants = @(); Deployments = @(); Created = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Modified = ''
    }
    if ($Src) {
        foreach ($p in $r.PSObject.Properties.Name) { if ($Src.PSObject.Properties[$p] -and $null -ne $Src.$p) { $r.$p = $Src.$p } }
        $r.Tenants = @($r.Tenants | Where-Object { $_ } | ForEach-Object { "$_" })
        $r.Deployments = @($r.Deployments | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ Tenant = "$($_.Tenant)"; ScriptId = "$($_.ScriptId)"; Stage = "$($_.Stage)"; Time = "$($_.Time)"; Version = '' } })
        $r.RunAs32 = [bool]$r.RunAs32; $r.Pilot = [bool]$r.Pilot
        $iv = 1; if ([int]::TryParse("$($r.Interval)", [ref]$iv)) { $r.Interval = [Math]::Max(1, $iv) } else { $r.Interval = 1 }
    }
    return $r
}

function Import-HURemLib {
    $script:RemLib.Clear()
    $j = Read-HUJsonFile (Get-HURemLibPath)
    if ($j -and $j.PSObject.Properties['remediations']) { foreach ($r in @($j.remediations)) { if ($r) { $script:RemLib.Add((ConvertTo-HURem $r)) } } }
}

function Save-HURemLib {
    try { Write-HUJsonFile -Path (Get-HURemLibPath) -Object ([pscustomobject]@{ version = 1; remediations = @($script:RemLib.ToArray()) }) -Depth 8 -Backup }
    catch { Write-HULogError "Wartung speichern fehlgeschlagen: $($_.Exception.Message)" }
}

function Get-HURemById([string]$Id) { return ($script:RemLib | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) }

function Set-HURemDeployment($Rem, [string]$Tenant, [hashtable]$Values) {
    $d = @($Rem.Deployments) | Where-Object { $_.Tenant -eq $Tenant } | Select-Object -First 1
    if (-not $d) {
        $d = [pscustomobject][ordered]@{ Tenant = $Tenant; ScriptId = ''; Stage = ''; Time = ''; Version = '' }
        $Rem.Deployments = @(@($Rem.Deployments) + $d)
    }
    foreach ($k in $Values.Keys) { $d.$k = $Values[$k] }
}

# ----------------------------------------------------------------------------
# Liste und Formular
# ----------------------------------------------------------------------------
function Update-HURemList([string]$SelectId = '') {
    $lst = $script:Controls['lstRem']
    if (-not $SelectId -and $script:RemCurrent) { $SelectId = $script:RemCurrent.Id }
    $items = foreach ($r in ($script:RemLib | Sort-Object Name)) {
        $dep = @($r.Deployments | Where-Object { $_.ScriptId })
        $sub = if ("$($r.Remediation)".Trim()) { 'Pruefen + Reparieren' } else { 'Nur pruefen' }
        if ($dep.Count) { $sub += " | $($dep.Count) Tenant(s)$(if (@($dep | Where-Object { $_.Stage -eq 'pilot' }).Count) { ', Pilot' })" }
        [pscustomobject]@{ Title = $(if ($r.Name) { $r.Name } else { '(ohne Name)' }); Sub = $sub; Id = $r.Id }
    }
    $script:RemLoading = $true
    try {
        $lst.ItemsSource = @($items)
        $sel = @($items) | Where-Object { $_.Id -eq $SelectId } | Select-Object -First 1
        if ($sel) { $lst.SelectedItem = $sel } else { $lst.SelectedIndex = -1 }
    } finally { $script:RemLoading = $false }
}

function Update-HURemTenantChecks {
    $sp = $script:Controls['spRemTenants']
    $sp.Children.Clear()
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
        [void]$sp.Children.Add($cb)
    }
    if (@($script:Settings.tenants).Count -gt 1) { Add-HUTenantAllToggle $sp $null }
}

function Get-HURemDeploymentText($Deployments) {
    $parts = foreach ($d in @($Deployments | Where-Object { $_.ScriptId })) {
        $st = switch ("$($d.Stage)") { 'pilot' { 'Pilot' } 'all' { 'alle' } 'none' { 'ohne Zuweisung' } default { 'nicht zugewiesen' } }
        "$(Get-HUTenantDisplayName $d.Tenant): $st$(if ($d.Time) { ", $($d.Time)" })"
    }
    if (-not @($parts).Count) { return 'Noch nicht verteilt.' }
    return 'Verteilt: ' + (@($parts) -join '  |  ')
}

function Update-HURemScheduleUi {
    $c = $script:Controls
    $t = Get-HUComboTag $c['cmbRemSchedule']
    $c['lblRemInterval'].Visibility = $(if ($t -eq 'once') { 'Collapsed' } else { 'Visible' })
    $c['txtRemInterval'].Visibility = $c['lblRemInterval'].Visibility
    $c['lblRemInterval'].Text = 'alle'
    $c['txtRemInterval'].ToolTip = $(if ($t -eq 'hourly') { 'Stunden (1-23)' } else { 'Tage' })
    $c['lblRemTime'].Visibility = $(if ($t -eq 'hourly') { 'Collapsed' } else { 'Visible' })
    $c['txtRemTime'].Visibility = $c['lblRemTime'].Visibility
    $c['lblRemTime'].Text = $(if ($t -eq 'once') { 'am' } else { $(if ($t -eq 'hourly') { '' } else { 'Tag(e) um' }) })
    $c['txtRemDate'].Visibility = $(if ($t -eq 'once') { 'Visible' } else { 'Collapsed' })
    $c['txtRemGroup'].IsEnabled = ((Get-HUComboTag $c['cmbRemTarget']) -eq 'group')
    $c['btnRemGroupPick'].IsEnabled = $c['txtRemGroup'].IsEnabled
    $none = ((Get-HUComboTag $c['cmbRemTarget']) -eq 'none')
    foreach ($n in 'chkRemPilot', 'btnRemPilotPick', 'cmbRemSchedule', 'txtRemInterval', 'txtRemTime', 'txtRemDate') { $c[$n].IsEnabled = -not $none }
    $c['txtRemPilot'].IsEnabled = [bool]$c['chkRemPilot'].IsChecked -and -not $none
}

function Update-HURemButtons {
    $c = $script:Controls; $r = $script:RemCurrent
    $busy = Test-HUJobRunning 'Rem'
    $has = [bool]$r
    $deps = if ($r) { @($r.Deployments | Where-Object { $_.ScriptId }) } else { @() }
    $c['btnRemSave'].IsEnabled = $has
    $c['btnRemRemove'].IsEnabled = $has
    $c['btnRemDeploy'].IsEnabled = $has -and -not $busy
    $c['btnRemRelease'].IsEnabled = $has -and -not $busy -and [bool]@($deps | Where-Object { $_.Stage -eq 'pilot' }).Count
    $c['btnRemResults'].IsEnabled = $has -and -not $busy -and [bool]$deps.Count
    $c['btnRemRunNow'].IsEnabled = $has -and -not $busy -and [bool]$deps.Count
    $c['btnRemTestLocal'].IsEnabled = $has -and -not (Test-HUJobRunning 'RemTest')
    $c['btnRemSandbox'].IsEnabled = $has -and -not (Test-HURemSandboxBusy)
}

function Show-HURemForm($Rem) {
    $c = $script:Controls
    $script:RemLoading = $true
    try {
        $script:RemCurrent = $Rem
        $c['pnlRemForm'].IsEnabled = [bool]$Rem
        if (-not $Rem) {
            foreach ($n in 'txtRemName', 'txtRemDesc', 'txtRemAiTask', 'txtRemDetect', 'txtRemFix', 'txtRemGroup', 'txtRemPilot', 'txtRemDate') { $c[$n].Text = '' }
            $c['txtRemTenantState'].Text = 'Links ein Wartungspaket waehlen, "+ Neu" oder "Beispiele ..." anklicken.'
            foreach ($p in @(@('cmbRemTarget', 'group'), @('cmbRemSchedule', 'daily'), @('cmbRemRunAs', 'system'))) { [void](Select-HUComboTag $c[$p[0]] $p[1]) }
            Set-HUCheckedTenants $c['spRemTenants'] @()
            return
        }
        $c['txtRemName'].Text = "$($Rem.Name)"
        $c['txtRemDesc'].Text = "$($Rem.Description)"
        $c['txtRemAiTask'].Text = "$($Rem.AiTask)"
        $c['txtRemDetect'].Text = "$($Rem.Detection)"
        $c['txtRemFix'].Text = "$($Rem.Remediation)"
        Set-HUCheckedTenants $c['spRemTenants'] @($Rem.Tenants)
        [void](Select-HUComboTag $c['cmbRemTarget'] $Rem.TargetKind)
        $c['txtRemGroup'].Text = "$($Rem.TargetGroup)"
        $c['chkRemPilot'].IsChecked = [bool]$Rem.Pilot
        $c['txtRemPilot'].Text = "$($Rem.PilotGroup)"
        [void](Select-HUComboTag $c['cmbRemSchedule'] $Rem.ScheduleType)
        $c['txtRemInterval'].Text = "$($Rem.Interval)"
        $c['txtRemTime'].Text = "$($Rem.Time)"
        $c['txtRemDate'].Text = "$($Rem.Date)"
        [void](Select-HUComboTag $c['cmbRemRunAs'] $Rem.RunAs)
        $c['chkRem32'].IsChecked = [bool]$Rem.RunAs32
        $c['txtRemTenantState'].Text = Get-HURemDeploymentText $Rem.Deployments
    } finally {
        $script:RemLoading = $false
        Update-HURemScheduleUi
        Update-HURemButtons
    }
}

function Save-HURemForm {
    $r = $script:RemCurrent
    if (-not $r -or $script:RemLoading) { return }
    # @param-Felder: fehlende Wertzeilen mit dem Standard ergaenzen
    try { Complete-HURemParams 'Lib' } catch { }
    $c = $script:Controls
    $r.Name = $c['txtRemName'].Text.Trim()
    $r.Description = $c['txtRemDesc'].Text.Trim()
    $r.AiTask = $c['txtRemAiTask'].Text.Trim()
    $r.Detection = $c['txtRemDetect'].Text
    $r.Remediation = $c['txtRemFix'].Text
    $r.Tenants = @(Get-HUCheckedTenants $c['spRemTenants'])
    $r.TargetKind = Get-HUComboTag $c['cmbRemTarget']
    $r.TargetGroup = $c['txtRemGroup'].Text.Trim()
    $r.Pilot = [bool]$c['chkRemPilot'].IsChecked
    $r.PilotGroup = $c['txtRemPilot'].Text.Trim()
    $r.ScheduleType = Get-HUComboTag $c['cmbRemSchedule']
    $iv = 1; if ([int]::TryParse($c['txtRemInterval'].Text.Trim(), [ref]$iv)) { $r.Interval = [Math]::Max(1, $iv) }
    $r.Time = $c['txtRemTime'].Text.Trim()
    $r.Date = $c['txtRemDate'].Text.Trim()
    $r.RunAs = Get-HUComboTag $c['cmbRemRunAs']
    $r.RunAs32 = [bool]$c['chkRem32'].IsChecked
    $r.Modified = Get-Date -Format 'yyyy-MM-dd HH:mm'
}

function Select-HURem([string]$Id) {
    Save-HURemForm
    Save-HURemLib
    Show-HURemForm (Get-HURemById $Id)
}

function Add-HURem($Template = $null) {
    Save-HURemForm
    $r = ConvertTo-HURem $Template
    $r.Id = [guid]::NewGuid().ToString()
    $r.Deployments = @()
    if (-not $r.Name) { $r.Name = 'Neues Wartungspaket' }
    $r.Tenants = @(Get-HUStateValue 'remTenants' @())
    if (-not $r.TargetGroup) { $r.TargetGroup = "$(Get-HUStateValue 'remLastGroup' '')" }
    $script:RemLib.Add($r)
    Save-HURemLib
    Update-HURemList $r.Id
    Show-HURemForm $r
    if (-not $Template) { $script:Controls['txtRemAiTask'].Focus() | Out-Null }
}

function Get-HURemExamples {
    $j = Read-HUJsonFile (Join-Path $script:AppRoot 'Config\remediations.example.json')
    if ($j -and $j.PSObject.Properties['remediations']) { return @($j.remediations) }
    return @()
}

function Show-HURemExamplesMenu {
    $btn = $script:Controls['btnRemExamples']
    $menu = New-Object System.Windows.Controls.ContextMenu
    $ex = @(Get-HURemExamples)
    if (-not $ex.Count) { $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = '(keine Beispiele gefunden)'; $mi.IsEnabled = $false; [void]$menu.Items.Add($mi) }
    foreach ($e in $ex) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = "$($e.Name)"
        $mi.ToolTip = "$($e.Description)"
        $mi.Tag = $e
        $mi.Add_Click({ Add-HURem $this.Tag; Add-HURtbLine $script:Controls['rtbRem'] "Beispiel uebernommen: $($this.Tag.Name) - Tenants, Ziel und Zeitplan waehlen." '#81C784' })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $btn
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
}

function Remove-HURemCurrent {
    $r = $script:RemCurrent
    if (-not $r) { return }
    $deps = @($r.Deployments | Where-Object { $_.ScriptId })
    $msg = "'$($r.Name)' aus der Liste entfernen?"
    if ($deps.Count) { $msg += "`n`nIn Intune bleibt das Paket in $($deps.Count) Tenant(s) bestehen (Geraete > Skripts und Wartungen)." }
    if (-not (Confirm-HU $msg -Warning)) { return }
    [void]$script:RemLib.Remove($r)
    $script:RemCurrent = $null
    Save-HURemLib
    Update-HURemList
    Show-HURemForm $null
}

# ----------------------------------------------------------------------------
# KI und Pruefung
# ----------------------------------------------------------------------------
function Copy-HURemPrompt {
    $task = $script:Controls['txtRemAiTask'].Text.Trim()
    if (-not $task) { Show-HUMessage 'Bitte zuerst in einem Satz beschreiben, was geprueft und repariert werden soll.' -Icon Warning; $script:Controls['txtRemAiTask'].Focus() | Out-Null; return }
    $p = Get-HUAiPrompt -Kind remediation -Task $task
    try { [System.Windows.Clipboard]::SetText($p) } catch { Show-HUMessage "Zwischenablage nicht verfuegbar: $($_.Exception.Message)" -Icon Warning; return }
    Add-HURtbLine $script:Controls['rtbRem'] 'Prompt kopiert - in ChatGPT, Claude oder Copilot einfuegen, die Antwort kopieren und "Antwort einfuegen" klicken.' '#CE93D8'
}

function Import-HURemAnswer {
    $t = ''
    try { $t = [System.Windows.Clipboard]::GetText() } catch { }
    if (-not "$t".Trim()) { Show-HUMessage 'Die Zwischenablage ist leer - zuerst die Antwort der KI kopieren.' -Icon Warning; return }
    $c = $script:Controls
    if (($c['txtRemDetect'].Text.Trim() -or $c['txtRemFix'].Text.Trim()) -and -not (Confirm-HU 'Vorhandene Skripte ersetzen?')) { return }
    $s = Split-HUAiAnswer $t
    $c['txtRemDetect'].Text = $s.Detection
    $c['txtRemFix'].Text = $s.Remediation
    if ($c['txtRemName'].Text -eq 'Neues Wartungspaket' -and $c['txtRemAiTask'].Text.Trim()) {
        $n = $c['txtRemAiTask'].Text.Trim(); if ($n.Length -gt 60) { $n = $n.Substring(0, 60).Trim() + ' ...' }
        $c['txtRemName'].Text = $n
    }
    Save-HURemForm; Save-HURemLib; Update-HURemList
    Add-HURtbLine $c['rtbRem'] "Eingefuegt: Pruefskript $($s.Detection.Split("`n").Count) Zeilen, Reparaturskript $(if ($s.Remediation) { "$($s.Remediation.Split("`n").Count) Zeilen" } else { 'leer' })." '#81C784'
    [void](Invoke-HURemCheck)
}

# liefert $true, wenn keine Fehler
function Invoke-HURemCheck {
    Save-HURemForm
    $r = $script:RemCurrent
    if (-not $r) { return $false }
    $rtb = $script:Controls['rtbRem']
    $all = @(Test-HURemediationScript -Code $r.Detection -Kind detection -RunAs $r.RunAs) + @(Test-HURemediationScript -Code $r.Remediation -Kind remediation -RunAs $r.RunAs)
    Add-HURtbLine $rtb "--- Pruefung: $($r.Name) ---" '#4FC3F7'
    foreach ($x in $all) {
        $col = switch ($x.Stufe) { 'Fehler' { '#FF5252' } 'Warnung' { '#FFB74D' } 'OK' { '#81C784' } default { '#90CAF9' } }
        Add-HURtbLine $rtb "[$($x.Stufe)] $($x.Hinweis)" $col
    }
    return (-not @($all | Where-Object { $_.Stufe -eq 'Fehler' }).Count)
}

function Start-HURemLocalTest {
    Save-HURemForm
    $r = $script:RemCurrent
    if (-not $r -or -not "$($r.Detection)".Trim()) { return }
    if (-not (Confirm-HU "Das Pruefskript wird jetzt auf DIESEM PC ausgefuehrt (als du, nicht als SYSTEM, Zeitlimit 2 Minuten).`nEin korrekt geschriebenes Pruefskript aendert nichts.`n`nAusfuehren?")) { return }
    $rtb = $script:Controls['rtbRem']
    Add-HURtbLine $rtb "--- Pruefskript lokal: $($r.Name) ---" '#4FC3F7'
    [void](Start-HUJob -Name 'RemTest' -Output $rtb -Vars @{ Code = $r.Detection; Use32 = [bool]$r.RunAs32 } -Code {
            $f = Join-Path ([IO.Path]::GetTempPath()) ("hu-detect-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            [IO.File]::WriteAllText($f, $Code, (New-Object System.Text.UTF8Encoding $true))
            try {
                $exe = if ($Use32 -and [Environment]::Is64BitOperatingSystem) { Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe' }
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe
                $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$f`""
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $p = [System.Diagnostics.Process]::Start($psi)
                $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; Write-HULog -Message 'Abbruch nach 2 Minuten (Intune bricht nach 1 Stunde ab - trotzdem zu lange?)' -Level 'ERROR'; return }
                $out = "$($so.Result)".Trim(); $err = "$($se.Result)".Trim()
                if ($out) { foreach ($l in $out -split "`r?`n") { Write-HULog -Message "Ausgabe: $l" -Level 'INFO' } }
                if ($err) { foreach ($l in $err -split "`r?`n") { Write-HULog -Message "Fehler: $l" -Level 'WARN' } }
                $txt = switch ($p.ExitCode) { 0 { 'exit 0 = alles in Ordnung (keine Reparatur)' } 1 { 'exit 1 = Problem gefunden (Intune wuerde jetzt reparieren)' } default { "exit $($p.ExitCode) = unerwartet (nur 0 oder 1 verwenden)" } }
                Write-HULog -Message "$txt - $([Math]::Round($sw.Elapsed.TotalSeconds, 1)) s" -Level $(if ($p.ExitCode -in 0, 1) { 'OK' } else { 'WARN' })
                if ($out.Length -gt 2048) { Write-HULog -Message "Ausgabe hat $($out.Length) Zeichen - Intune zeigt nur 2.048." -Level 'WARN' }
            } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        } -OnDone { param($Result, $Errors) Update-HURemButtons })
    Update-HURemButtons
}

# ----------------------------------------------------------------------------
# Verteilen / Freigeben / Ergebnisse / Jetzt ausfuehren
# ----------------------------------------------------------------------------
function Get-HURemSchedule($Rem) {
    $date = ''
    if ($Rem.ScheduleType -eq 'once') {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact("$($Rem.Date)".Trim(), 'd.M.yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { throw "Datum '$($Rem.Date)' nicht lesbar - Format TT.MM.JJJJ" }
        $date = $d.ToString('yyyy-MM-dd')
    }
    if ($Rem.ScheduleType -ne 'hourly' -and "$($Rem.Time)" -notmatch '^\d{1,2}:\d{2}$') { throw "Uhrzeit '$($Rem.Time)' nicht lesbar - Format HH:mm" }
    return @{ Type = $(if ($Rem.ScheduleType) { $Rem.ScheduleType } else { 'daily' }); Interval = [int]$Rem.Interval; Time = "$($Rem.Time)"; Date = $date }
}

function Get-HURemScheduleText($Rem) {
    switch ($Rem.ScheduleType) {
        'hourly' { return "alle $($Rem.Interval) Stunde(n)" }
        'once' { return "einmal am $($Rem.Date) um $($Rem.Time)" }
        default { return "$(if ([int]$Rem.Interval -gt 1) { "alle $($Rem.Interval) Tage" } else { 'taeglich' }) um $($Rem.Time)" }
    }
}

$script:RemDeployCode = {
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($tk in $Tenants) {
        $r = [ordered]@{ Tenant = $tk; Ok = $false; ScriptId = ''; Error = '' }
        try {
            Write-HULog -Message "--- $tk ---" -Level 'INFO' -Tenant $tk
            $sid = if ($Deployments.ContainsKey($tk)) { "$($Deployments[$tk])" } else { '' }
            if ($Release) {
                if (-not $sid) { throw 'In diesem Tenant noch nicht hochgeladen' }
                [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$sid")
            } else {
                $new = Publish-HURemediation -TenantKey $tk -Settings $Settings -Def $Def -Id $sid
                Write-HULog -Message $(if ($new -eq $sid) { 'Skripte aktualisiert' } else { 'Wartungspaket angelegt' }) -Level 'OK' -Tenant $tk
                $sid = $new
            }
            $r.ScriptId = $sid
            if (@($Targets).Count) {
                $tg = @(Resolve-HUTargets -TenantKey $tk -Settings $Settings -Targets $Targets)
                $n = Set-HURemediationAssignment -TenantKey $tk -Settings $Settings -Id $sid -Targets $tg -Schedule $Schedule -RunRemediation ([bool]"$($Def.Remediation)".Trim())
                Write-HULog -Message "Zugewiesen: $(@($tg | ForEach-Object { $_.Label }) -join ', ') ($ScheduleText) - insgesamt $n Zuweisung(en)" -Level 'OK' -Tenant $tk
            } else { Write-HULog -Message 'Ohne Zuweisung hochgeladen (vorhandene Zuweisungen bleiben unveraendert)' -Level 'OK' -Tenant $tk }
            $r.Ok = $true
        } catch {
            $r.Error = $_.Exception.Message
            $hint = ''
            if ($r.Error -match '(?i)licen|lizenz') { $hint = ' -> Intune Admin Center: Mandantenverwaltung > Connectors und Token > Windows-Datenverarbeitung > "Windows-Lizenzueberpruefung" einschalten (A3/E3 noetig)' }
            elseif ($r.Error -match '403|Forbidden|Authorization') { $hint = ' -> Berechtigung DeviceManagementScripts.ReadWrite.All (und Group.Read.All) erteilen' }
            Write-HULog -Message "$($r.Error)$hint" -Level 'ERROR' -Tenant $tk
        }
        $results.Add([pscustomobject]$r)
    }
    $results.ToArray()
}

function Start-HURemDeploy([switch]$Release) {
    Save-HURemForm
    $r = $script:RemCurrent
    if (-not $r) { return }
    Save-HURemLib
    $tenants = if ($Release) { @($r.Deployments | Where-Object { $_.Stage -eq 'pilot' -and $_.ScriptId } | ForEach-Object { $_.Tenant }) } else { @($r.Tenants) }
    $err = New-Object System.Collections.Generic.List[string]
    if (-not $r.Name) { $err.Add('Name fehlt.') }
    if (-not $tenants.Count) { $err.Add('Kein Tenant angehakt.') }
    if ($r.TargetKind -eq 'group' -and -not $r.TargetGroup) { $err.Add('Zielgruppe fehlt (oder "Alle Geraete" waehlen).') }
    if ($r.Pilot -and -not $Release -and -not $r.PilotGroup -and $r.TargetKind -ne 'none') { $err.Add('Pilotgruppe fehlt.') }
    $sched = $null
    try { $sched = Get-HURemSchedule $r } catch { $err.Add($_.Exception.Message) }
    if ($err.Count) { Show-HUMessage ("Bitte zuerst ergaenzen:`n`n- " + ($err -join "`n- ")) 'Wartung' -Icon Warning; return }
    if (-not $Release -and -not (Invoke-HURemCheck)) { Show-HUMessage 'Die Pruefung hat Fehler gefunden (siehe Ausgabe) - bitte zuerst beheben.' 'Wartung' -Icon Warning; return }

    $targets = if ($r.TargetKind -eq 'none' -and -not $Release) { @() } elseif ($r.Pilot -and -not $Release) { @(@{ Kind = 'group'; GroupName = $r.PilotGroup }) } else { @(@{ Kind = $r.TargetKind; GroupName = $r.TargetGroup }) }
    $tText = if ($r.TargetKind -eq 'none' -and -not $Release) { 'keine Zuweisung (nur hochladen/aktualisieren)' } elseif ($r.Pilot -and -not $Release) { "Pilotgruppe '$($r.PilotGroup)'" } elseif ($r.TargetKind -eq 'allDevices') { 'Alle Geraete' } else { "Gruppe '$($r.TargetGroup)'" }
    $names = @($tenants | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', '
    $mode = if ("$($r.Remediation)".Trim()) { 'pruefen und reparieren' } else { 'nur pruefen und berichten' }
    if (-not (Confirm-HU "$($r.Name)`n`nTenants: $names`nZiel: $tText`nZeitplan: $(Get-HURemScheduleText $r)`nModus: $mode, als $(if ($r.RunAs -eq 'user') { 'Benutzer' } else { 'System' })`n`nJetzt $(if ($Release) { 'freigeben' } else { 'hochladen und zuweisen' })?")) { return }

    Set-HUStateValue 'remTenants' @($r.Tenants)
    if ($r.TargetGroup) { Set-HUStateValue 'remLastGroup' $r.TargetGroup }
    $deps = @{}
    foreach ($d in @($r.Deployments | Where-Object { $_.ScriptId })) { $deps[$d.Tenant] = $d.ScriptId }
    $script:RemJobId = $r.Id
    $script:RemJobRelease = [bool]$Release
    $rtb = $script:Controls['rtbRem']
    Add-HURtbLine $rtb "=== $(if ($Release) { 'Freigabe' } else { 'Verteilung' }): $($r.Name) $(Get-Date -Format 'HH:mm:ss') ===" '#4FC3F7'
    [void](Start-HUJob -Name 'Rem' -Code $script:RemDeployCode -Output $rtb -Vars @{
            Def = [pscustomobject]@{ Name = $r.Name; Description = $r.Description; Detection = $r.Detection; Remediation = $r.Remediation; RunAs = $r.RunAs; RunAs32 = [bool]$r.RunAs32; Publisher = (Get-HUAuthor $script:Settings 'HU-MultiTenant') }
            Tenants = $tenants; Deployments = $deps; Release = [bool]$Release; Targets = $targets; Schedule = $sched; ScheduleText = (Get-HURemScheduleText $r)
        } -OnDone { param($Result, $Errors) Complete-HURemDeploy $Result })
    Update-HURemButtons
}

function Complete-HURemDeploy($Result) {
    $r = Get-HURemById $script:RemJobId
    $okN = 0; $failN = 0
    if ($r) {
        foreach ($x in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) {
            if ($x.Ok) { $okN++ } else { $failN++ }
            if (-not $x.ScriptId) { continue }
            $v = @{ ScriptId = $x.ScriptId }
            if ($x.Ok) { $v.Time = Get-Date -Format 'dd.MM. HH:mm'; $old0 = @($r.Deployments) | Where-Object { $_.Tenant -eq $x.Tenant } | Select-Object -First 1; $v.Stage = $(if ($r.TargetKind -eq 'none' -and -not $script:RemJobRelease) { if ($old0 -and $old0.Stage -in 'all', 'pilot') { $old0.Stage } else { 'none' } } elseif ($script:RemJobRelease -or -not $r.Pilot) { 'all' } else { 'pilot' }) }
            Set-HURemDeployment $r $x.Tenant $v
        }
        Save-HURemLib
        Update-HURemList $r.Id
        if ($script:RemCurrent -and $script:RemCurrent.Id -eq $r.Id) { $script:Controls['txtRemTenantState'].Text = Get-HURemDeploymentText $r.Deployments }
    }
    Add-HURtbLine $script:Controls['rtbRem'] "Ergebnis: $okN Tenant(s) ok$(if ($failN) { ", $failN mit Fehler" })$(if ($okN) { ' - erste Ergebnisse nach dem naechsten Lauf auf den Geraeten (Ergebnisse).' })" $(if ($failN) { '#FFB74D' } else { '#81C784' })
    Update-HURemButtons
}

function Start-HURemResults {
    $r = $script:RemCurrent
    if (-not $r) { return }
    $checked = @(Get-HUCheckedTenants $script:Controls['spRemTenants'])
    $deps = @($r.Deployments | Where-Object { $_.ScriptId })
    $sel = @($deps | Where-Object { $checked -contains $_.Tenant }); if (-not $sel.Count) { $sel = $deps }
    $map = @{}; foreach ($d in $sel) { $map[$d.Tenant] = $d.ScriptId }
    Start-HURemResultsJob -Name $r.Name -Map $map -Rtb $script:Controls['rtbRem'] -JobName 'Rem'
}

# Ergebnisse je Geraet (Bibliothek und "In Intune"); Map = TenantKey -> Skript-ID
function Start-HURemResultsJob([string]$Name, [hashtable]$Map, $Rtb, [string]$JobName) {
    $script:RemResName = $Name
    $script:RemResRtb = $Rtb
    Add-HURtbLine $Rtb "=== Ergebnisse: $Name ===" '#4FC3F7'
    [void](Start-HUJob -Name $JobName -Output $Rtb -Vars @{ Map = $Map } -Code {
            foreach ($tk in $Map.Keys) {
                try {
                    $rows = @(Get-HURemediationRunStates -TenantKey $tk -Settings $Settings -Id $Map[$tk])
                    $grp = @($rows | Group-Object Pruefung | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                    $fixed = @($rows | Where-Object { $_.Reparatur -eq 'behoben' }).Count
                    Write-HULog -Message "$($rows.Count) Geraet(e)$(if ($grp) { ": $grp" })$(if ($fixed) { ", behoben=$fixed" })" -Level 'OK' -Tenant $tk
                    foreach ($x in $rows) { $o = [ordered]@{ Tenant = $tk }; foreach ($p in $x.PSObject.Properties) { $o[$p.Name] = $p.Value }; [pscustomobject]$o }
                } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $tk }
            }
        } -OnDone {
            param($Result, $Errors)
            $rows = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Geraet'] })
            $script:RemLastResults = $rows
            $script:RemLastResultsName = $script:RemResName
            Update-HURemButtons; Update-HURintButtons
            if (-not $rows.Count) { Add-HURtbLine $script:RemResRtb 'Noch keine Ergebnisse - die Geraete melden sich nach dem ersten geplanten Lauf.' '#FFB74D'; return }
            $view = foreach ($x in $rows) { $o = [ordered]@{}; foreach ($p in $x.PSObject.Properties) { if ($p.Name -ne 'DeviceId') { $o[$p.Name] = $p.Value } }; $o.Tenant = Get-HUTenantDisplayName $x.Tenant; [pscustomobject]$o }
            Show-HUQSTable -Title "Wartung $($script:RemResName)" -Objects @($view) -FilePrefix 'Wartung'
        })
    Update-HURemButtons; Update-HURintButtons
}

function Show-HURemRunNow {
    $r = $script:RemCurrent
    if (-not $r) { return }
    Show-HURemRunNowDialog -Name $r.Name -Deps @($r.Deployments | Where-Object { $_.ScriptId }) -Rtb $script:Controls['rtbRem'] -JobName 'Rem'
}

# Deps = Objekte mit Tenant und ScriptId
function Show-HURemRunNowDialog([string]$Name, $Deps, $Rtb, [string]$JobName) {
    $deps = @($Deps | Where-Object { $_ })
    if (-not $deps.Count) { return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Jetzt auf Geraet ausfuehren" Width="480" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblHint" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <TextBlock Text="Tenant" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <ComboBox x:Name="cmbTenant" Style="{StaticResource DarkComboBox}"/>
        <TextBlock Text="Geraetename(n), mit Komma getrennt" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtDevice" Style="{StaticResource DarkTextBox}"/>
        <TextBlock x:Name="lblPick" Text="oder aus den letzten Ergebnissen waehlen (Geraete mit Problem zuerst):" Style="{StaticResource HintText}" Margin="0,8,0,3"/>
        <ComboBox x:Name="cmbDevice" Style="{StaticResource DarkComboBox}"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="Ausfuehren" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $c.lblHint.Text = "'$Name' sofort ausfuehren (Pruefung und, wenn noetig, Reparatur). Das Geraet muss online sein; das Ergebnis erscheint nach ein paar Minuten unter 'Ergebnisse'."
    foreach ($dp in $deps) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = Get-HUTenantDisplayName $dp.Tenant; $it.Tag = $dp.Tenant; [void]$c.cmbTenant.Items.Add($it) }
    $c.cmbTenant.SelectedIndex = 0
    # Ergebnisliste nur verwenden, wenn sie zu diesem Skript gehoert
    $results = @(if ("$($script:RemLastResultsName)" -eq $Name) { $script:RemLastResults })
    $fill = {
        $c.cmbDevice.Items.Clear()
        $script:RemPickBusy = $true
        $tk = "$($c.cmbTenant.SelectedItem.Tag)"
        # zuerst Geraete mit Problem, dann der Rest
        $list = @($results | Where-Object { $_.Tenant -eq $tk } | Sort-Object @{ Expression = { $_.Pruefung -ne 'Problem gefunden' -and $_.Reparatur -notmatch 'fehl' } }, Geraet)
        foreach ($e in $list) { [void]$c.cmbDevice.Items.Add("$($e.Geraet)$(if ($e.Pruefung -eq 'Problem gefunden' -or $e.Reparatur -match 'fehl') { "  ($($e.Pruefung) / $($e.Reparatur))" })") }
        $vis = $(if ($list.Count) { 'Visible' } else { 'Collapsed' })
        $c.cmbDevice.Visibility = $vis; $c.lblPick.Visibility = $vis
        $script:RemPickBusy = $false
    }
    $script:RemPickBusy = $false
    & $fill
    $c.cmbTenant.Add_SelectionChanged({ $c.txtDevice.Text = ''; & $fill })
    $c.cmbDevice.Add_SelectionChanged({
            if ($script:RemPickBusy -or -not $c.cmbDevice.SelectedItem) { return }
            $n = ("$($c.cmbDevice.SelectedItem)" -split '  \(')[0].Trim()
            $have = @($c.txtDevice.Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($have -notcontains $n) { $c.txtDevice.Text = (@($have) + $n) -join ', ' }
        })
    $w.Add_ContentRendered({ $c.txtDevice.Focus() })
    $state = @{ Ok = $false }
    $c.btnOk.Add_Click({ if (-not $c.txtDevice.Text.Trim()) { Show-HUMessage 'Bitte einen Geraetenamen eingeben.' -Icon Warning -Owner $w; return }; $state.Ok = $true; $w.Close() })
    [void]$w.ShowDialog()
    if (-not $state.Ok) { return }
    $tk = "$($c.cmbTenant.SelectedItem.Tag)"
    $names = @($c.txtDevice.Text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $sid = (@($deps) | Where-Object { $_.Tenant -eq $tk } | Select-Object -First 1).ScriptId
    Add-HURtbLine $Rtb "=== Jetzt ausfuehren: $Name auf $($names -join ', ') ===" '#4FC3F7'
    [void](Start-HUJob -Name $JobName -Output $Rtb -Vars @{ Tk = $tk; Names = $names; Sid = $sid } -Code {
            foreach ($n in $Names) {
                try {
                    $devs = @(Find-HUManagedDevice -TenantKey $Tk -Settings $Settings -Name $n)
                    if (-not $devs.Count) { Write-HULog -Message "$n : nicht gefunden" -Level 'WARN' -Tenant $Tk; continue }
                    foreach ($dv in $devs) {
                        Start-HURemediationOnDevice -TenantKey $Tk -Settings $Settings -DeviceId $dv.id -Id $Sid
                        Write-HULog -Message "$($dv.deviceName): gestartet (letzter Sync $(try { ([datetime]$dv.lastSyncDateTime).ToLocalTime().ToString('dd.MM. HH:mm') } catch { '?' }))" -Level 'OK' -Tenant $Tk
                    }
                } catch {
                    $hint = if ("$($_.Exception.Message)" -match '403|Forbidden|Authorization') { ' -> Berechtigung DeviceManagementManagedDevices.PrivilegedOperations.All erteilen' } else { '' }
                    Write-HULog -Message "${n}: $($_.Exception.Message)$hint" -Level 'ERROR' -Tenant $Tk
                }
            }
        } -OnDone { param($Result, $Errors) Update-HURemButtons; Update-HURintButtons })
    Update-HURemButtons; Update-HURintButtons
}

# ----------------------------------------------------------------------------
# Ereignisse
# ----------------------------------------------------------------------------
function Register-HURemHandlers {
    $c = $script:Controls
    $c['lstRem'].Add_SelectionChanged({
            if ($script:RemLoading) { return }
            $it = $script:Controls['lstRem'].SelectedItem
            if ($it) { Select-HURem $it.Id }
        })
    $c['btnRemNew'].Add_Click({ Add-HURem })
    $c['btnRemGroupPick'].Add_Click({
            $c = $script:Controls
            $n = Show-HUGroupPicker -TenantKeys @(Get-HUCheckedTenants $c['spRemTenants']) -Current $c['txtRemGroup'].Text.Trim() -Title 'Zielgruppe waehlen'
            if ($n) { [void](Select-HUComboTag $c['cmbRemTarget'] 'group'); $c['txtRemGroup'].Text = $n; Update-HURemScheduleUi }
        })
    $c['btnRemPilotPick'].Add_Click({
            $c = $script:Controls
            $n = Show-HUGroupPicker -TenantKeys @(Get-HUCheckedTenants $c['spRemTenants']) -Current $c['txtRemPilot'].Text.Trim() -Title 'Pilotgruppe waehlen'
            if ($n) { $c['chkRemPilot'].IsChecked = $true; $c['txtRemPilot'].Text = $n; Update-HURemScheduleUi }
        })
    $c['btnRemExamples'].Add_Click({ Show-HURemExamplesMenu })
    $c['btnRemRemove'].Add_Click({ Remove-HURemCurrent })
    $c['btnRemAiCopy'].Add_Click({ Save-HURemForm; Copy-HURemPrompt })
    $c['btnRemAiPaste'].Add_Click({ Import-HURemAnswer })
    $c['btnRemCheck'].Add_Click({ [void](Invoke-HURemCheck) })
    $c['btnRemTestLocal'].Add_Click({ Start-HURemLocalTest })
    $c['btnRemSandbox'].Add_Click({ Save-HURemForm; $r = $script:RemCurrent; if ($r) { Start-HURemSandbox -Name $r.Name -Detection $r.Detection -Remediation $r.Remediation -RunAs $r.RunAs -Use32 ([bool]$r.RunAs32) -KeepOpen ([bool]$script:Controls['chkRemSandboxKeep'].IsChecked) } })
    $c['cmbRemSchedule'].Add_SelectionChanged({ Update-HURemScheduleUi })
    $c['cmbRemTarget'].Add_SelectionChanged({ Update-HURemScheduleUi })
    $c['chkRemPilot'].Add_Checked({ Update-HURemScheduleUi })
    $c['chkRemPilot'].Add_Unchecked({ Update-HURemScheduleUi })
    $c['txtRemName'].Add_LostFocus({ if (-not $script:RemLoading -and $script:RemCurrent) { Save-HURemForm; Update-HURemList } })
    $c['btnRemSave'].Add_Click({ Save-HURemForm; Save-HURemLib; Update-HURemList; Add-HURtbLine $script:Controls['rtbRem'] "Gespeichert: $($script:RemCurrent.Name)" '#81C784' })
    $c['btnRemDeploy'].Add_Click({ Start-HURemDeploy })
    $c['btnRemRelease'].Add_Click({ Start-HURemDeploy -Release })
    $c['btnRemResults'].Add_Click({ Start-HURemResults })
    $c['btnRemRunNow'].Add_Click({ Show-HURemRunNow })
    Add-HUOutputMenu $c['rtbRem'] { $script:Controls['rtbRem'].Document.Blocks.Clear() }
}

function Initialize-HUMaint {
    Import-HURemLib
    Update-HURemTenantChecks
    Update-HURemList
    Show-HURemForm $null
}

function Close-HUMaint {
    Save-HURemForm
    if ($script:RemLib.Count -or (Test-Path -LiteralPath (Get-HURemLibPath))) { Save-HURemLib }
}
