#Requires -Version 5.1
<#
.SYNOPSIS
    App-Sicherung (2.5.9): Reiter "Sicherung" in den Einstellungen, Jetzt sichern, Pruefen, Wiederherstellen, Automatik.
.DESCRIPTION
    Logik in Core\HU.AppBackup.psm1. Hier nur Oberflaeche und Ablauf.
    Einstellungen (settings.json, ui.*): appBackupPath, appBackupMode (aus|taeglich|woechentlich), appBackupKeep, appBackupMuster, appBackupTenant.
    Zustand (ui-state.json): appBackupLast (letzte erfolgreiche Sicherung), appBackupResult (Text).
    Teams-Ziele (Webhook-Adressen) gehen entschluesselt NUR in die verschluesselte Sicherung und werden beim Wiederherstellen neu verschluesselt.
    Kennwort fuer die Automatik: %APPDATA%\HU-MultiTenant\sicherung-kennwort.dat (DPAPI, nur dieser Windows-Benutzer; nie in der Sicherung).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:AbDlg = $null   # offener Einstellungs-Dialog: @{ C; W }
# StrictMode: alle Zustandsvariablen vorab anlegen (sonst Fehler beim ersten Lesen)
$script:AbProg = $null        # Fortschritt (synchronisierte Hashtable) waehrend Sichern/Pruefen
$script:AbProgTimer = $null   # Anzeige-Timer
$script:AbAuto = $false       # laufende Sicherung ist automatisch
$script:AbOpen = $null        # laufendes Pruefen/Lesen: @{ File; Info; CheckOnly; Owner }
$script:AbCheck = $null       # Pruefung der Automatik
$script:AbTimer = $null       # Automatik-Timer (alle 15 Minuten)
$script:AbExtra = $null       # Sonderinhalte der laufenden Sicherung (nach Gebrauch geleert)

function Get-HUAbDataRoot {
    if (-not $env:APPDATA) { throw 'APPDATA ist nicht gesetzt.' }
    return (Join-Path $env:APPDATA 'HU-MultiTenant')
}

function Get-HUAbConfig($S = $script:Settings) {
    $keep = 10; try { $keep = [int](Get-HUProp $S.ui 'appBackupKeep' 10) } catch { }
    if ($keep -lt 1 -or $keep -gt 999) { $keep = 10 }
    $mode = "$(Get-HUProp $S.ui 'appBackupMode' 'aus')"; if ($mode -notin 'aus', 'taeglich', 'woechentlich') { $mode = 'aus' }
    return [pscustomobject]@{
        Path   = [Environment]::ExpandEnvironmentVariables("$(Get-HUProp $S.ui 'appBackupPath' '')".Trim())
        Mode   = $mode
        Keep   = $keep
        Muster = [bool](Get-HUProp $S.ui 'appBackupMuster' $true)
        Tenant = [bool](Get-HUProp $S.ui 'appBackupTenant' $false)
    }
}

function Get-HUAbBackupRoot {
    try { return (Get-HUBackupRoot $script:Settings) } catch { return '' }
}

# ---------------------------------------------------------------- Kennwort-Dialog ----------------------------------------------------------------
# $New: festlegen (zweimal, mind. 10 Zeichen, optional fuer die Automatik merken). Sonst: einmal eingeben (zum Oeffnen).
# Rueckgabe: @{ Password (SecureString); Remember } oder $null.
function Show-HUAbPasswordDialog($Owner = $null, [switch]$New, [string]$Text = '') {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kennwort der App-Sicherung" Width="420" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="txtInfo" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <TextBlock Text="Kennwort" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <PasswordBox x:Name="pw1" Height="28" Background="#2D2D2D" Foreground="White" BorderBrush="#3E3E42" Padding="6,3"/>
        <StackPanel x:Name="pnlNew">
            <TextBlock Text="Kennwort wiederholen" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
            <PasswordBox x:Name="pw2" Height="28" Background="#2D2D2D" Foreground="White" BorderBrush="#3E3E42" Padding="6,3"/>
            <CheckBox x:Name="chkRemember" Content="F&#xFC;r die automatische Sicherung auf diesem PC merken" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,10,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="OK" Width="110" Background="#388E3C" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $c.txtInfo.Text = $(if ($Text) { $Text } elseif ($New) { 'Mindestens 10 Zeichen. Ohne dieses Kennwort ist keine Sicherung zu oeffnen - bitte sicher aufbewahren (z. B. im Kennwort-Manager). Ein neues Kennwort gilt nur fuer neue Sicherungen.' } else { 'Kennwort der Sicherung eingeben.' })
    if (-not $New) { $c.pnlNew.Visibility = 'Collapsed' }
    $st = @{ R = $null }
    $c.btnOk.Add_Click({
            if ($New) {
                $why = Test-HUAbPassword $c.pw1.SecurePassword $c.pw2.SecurePassword
                if ($why) { Show-HUMessage $why -Icon Warning -Owner $w; return }
            } elseif (-not $c.pw1.SecurePassword.Length) { return }
            $st.R = [pscustomobject]@{ Password = $c.pw1.SecurePassword.Copy(); Remember = [bool]($New -and $c.chkRemember.IsChecked) }
            $w.Close()
        })
    $w.Add_ContentRendered({ $c.pw1.Focus() })
    [void]$w.ShowDialog()
    return $st.R
}

# ---------------------------------------------------------------- Reiter in den Einstellungen ----------------------------------------------------------------
function Initialize-HUAbSettingsTab($c, $w) {
    $script:AbDlg = @{ C = $c; W = $w; Pw = $null }
    $cfg = Get-HUAbConfig
    $c.txtAbPath.Text = "$(Get-HUProp $script:Settings.ui 'appBackupPath' '')"
    $c.chkAbMuster.IsChecked = $cfg.Muster
    $c.chkAbTenant.IsChecked = $cfg.Tenant
    $c.txtAbKeep.Text = "$($cfg.Keep)"
    foreach ($i in $c.cmbAbMode.Items) { if ("$($i.Tag)" -eq $cfg.Mode) { $c.cmbAbMode.SelectedItem = $i } }
    if (-not $c.cmbAbMode.SelectedItem) { $c.cmbAbMode.SelectedIndex = 0 }
    Update-HUAbTabInfo
    if ((Test-HUJobRunning 'AppBackup') -or (Test-HUJobRunning 'AppBackupOpen')) { Start-HUAbProgressTimer }
    $c.btnAbBrowse.Add_Click({
            $f = New-Object System.Windows.Forms.FolderBrowserDialog
            $f.Description = 'Ordner fuer die App-Sicherung (auch Netzwerkfreigabe oder USB-Laufwerk)'
            $cc = $script:AbDlg.C
            if ($cc.txtAbPath.Text -and (Test-Path -LiteralPath $cc.txtAbPath.Text)) { $f.SelectedPath = $cc.txtAbPath.Text }
            if ($f.ShowDialog() -eq 'OK') { $cc.txtAbPath.Text = $f.SelectedPath }
        })
    $c.btnAbPw.Add_Click({
            $r = Show-HUAbPasswordDialog $script:AbDlg.W -New
            if (-not $r) { return }
            $script:AbDlg.Pw = $r.Password
            $dr = Get-HUAbDataRoot
            try {
                if ($r.Remember) { Save-HUAppBackupPassword -DataRoot $dr -Password $r.Password; Write-HULogOK 'App-Sicherung: Kennwort gespeichert (DPAPI, dieser Windows-Benutzer).' }
                else { Remove-HUAppBackupPassword $dr; Write-HULogInfo 'App-Sicherung: Kennwort nur fuer diese Sitzung (nicht gespeichert) - die Automatik laeuft so nicht.' }
            } catch { Show-HUMessage "Kennwort nicht gespeichert: $($_.Exception.Message)" -Icon Error -Owner $script:AbDlg.W }
            Update-HUAbTabInfo
        })
    $c.btnAbNow.Add_Click({ Start-HUAppBackupNow -FromDialog })
    $c.btnAbCheck.Add_Click({ Start-HUAppBackupOpen -CheckOnly })
    $c.btnAbRestore.Add_Click({ Start-HUAppBackupOpen })
    $c.btnAbOpen.Add_Click({
            $p = [Environment]::ExpandEnvironmentVariables("$($script:AbDlg.C.txtAbPath.Text)".Trim())
            if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList "`"$p`"" } else { Show-HUMessage 'Der Sicherungsordner existiert (noch) nicht.' -Icon Info -Owner $script:AbDlg.W }
        })
}

# Kopfzeile im Hauptfenster neben dem Schluessel: Diskette, Tooltip mit letzter Sicherung; laeuft = blau mit Prozent, Fehler = orange
function Update-HUAbMainStatus {
    $t = $null; try { $t = $script:Controls['txtAppBackupStatus'] } catch { }
    if (-not $t) { return }
    $ic = [char]::ConvertFromUtf32(0x1F4BE)
    $run = Get-HUAbProgressText
    $last = "$(Get-HUStateValue 'appBackupLast' '')"; $res = "$(Get-HUStateValue 'appBackupResult' '')"
    $lt = $(if ($last) { try { ([datetime]::Parse($last, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy HH:mm') } catch { $last } } else { '' })
    $cfg = Get-HUAbConfig
    if ($run) {
        $p = $script:AbProg; $pc = $(if ($p -and [double]$p.Total -gt 0) { " $([int](100 * [double]$p.Done / [double]$p.Total)) %" } else { ' ...' })
        $t.Text = "$ic$pc"; $t.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue; $t.ToolTip = "App-Sicherung $run"
    } elseif ($res -like 'FEHLER*' -or $res -like 'Automatik:*') {
        $t.Text = "$ic !"; $t.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9800'); $t.ToolTip = "App-Sicherung: $res$(if ($lt) { "`nLetzte erfolgreiche: $lt" })`nKlick: Einstellungen > Sicherung"
    } else {
        $t.Text = "$ic"; $t.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#858585')
        $t.ToolTip = $(if ($lt) { "App-Sicherung: zuletzt $lt$(if ($res) { " ($res)" })`nAutomatisch: $($cfg.Mode)`nKlick: Einstellungen > Sicherung" } else { "Noch keine App-Sicherung`nKlick: Einstellungen > Sicherung" })
    }
}

function Register-HUAbMainStatus {
    $t = $null; try { $t = $script:Controls['txtAppBackupStatus'] } catch { }
    if (-not $t) { return }
    $t.Add_MouseLeftButtonUp({ Open-HUSettings -Tab 'Sicherung' })
    Update-HUAbMainStatus
}

function Update-HUAbTabInfo {
    Update-HUAbMainStatus
    if (-not $script:AbDlg) { return }
    $c = $script:AbDlg.C
    $stored = Test-Path -LiteralPath (Join-Path (Get-HUAbDataRoot) 'sicherung-kennwort.dat')
    $c.txtAbPwInfo.Text = $(if ($stored) { 'gespeichert (Automatik moeglich)' } elseif ($script:AbDlg.Pw) { 'nur fuer diese Sitzung' } else { 'noch keines festgelegt' })
    $c.btnAbPw.Content = $(if ($stored -or $script:AbDlg.Pw) { 'Kennwort aendern ...' } else { 'Kennwort festlegen ...' })
    $run = Get-HUAbProgressText
    foreach ($b in 'btnAbNow', 'btnAbCheck', 'btnAbRestore') { $c[$b].IsEnabled = -not $run }
    $c.btnAbNow.Content = $(if ($run -like 'sichert*') { 'Sichert ...' } else { 'Jetzt sichern' })
    if ($run) { $c.txtAbLast.Text = $run; $c.txtAbLast.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue; return }
    $c.txtAbLast.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#AAAAAA')
    $last = "$(Get-HUStateValue 'appBackupLast' '')"; $res = "$(Get-HUStateValue 'appBackupResult' '')"
    $c.txtAbLast.Text = $(if ($last) { "$(try { ([datetime]::Parse($last, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy HH:mm') } catch { $last })$(if ($res) { "  -  $res" })" } elseif ($res) { $res } else { 'noch keine' })
}

# beim Speichern der Einstellungen (Rueckgabe: Fehlertext oder '')
function Save-HUAbSettingsFromForm($c, $S) {
    $keep = 0
    if (-not [int]::TryParse("$($c.txtAbKeep.Text)".Trim(), [ref]$keep) -or $keep -lt 1 -or $keep -gt 999) { return 'Sicherung: aufbewahren als Zahl zwischen 1 und 999.' }
    $mode = "$($c.cmbAbMode.SelectedItem.Tag)"
    $path = "$($c.txtAbPath.Text)".Trim()
    if ($mode -ne 'aus' -and -not $path) { return 'Sicherung: fuer die automatische Sicherung bitte einen Ordner angeben.' }
    Set-HUProp $S.ui 'appBackupPath' $path
    Set-HUProp $S.ui 'appBackupMode' $mode
    Set-HUProp $S.ui 'appBackupKeep' $keep
    Set-HUProp $S.ui 'appBackupMuster' ([bool]$c.chkAbMuster.IsChecked)
    Set-HUProp $S.ui 'appBackupTenant' ([bool]$c.chkAbTenant.IsChecked)
    return ''
}

# ---------------------------------------------------------------- Sichern ----------------------------------------------------------------
# -FromDialog: Werte aus dem offenen Einstellungs-Dialog (auch ungespeichert), Kennwort notfalls abfragen.
# -Auto: aus den Einstellungen, nur mit gespeichertem Kennwort, ohne Dialoge.
function Start-HUAppBackupNow([switch]$FromDialog, [switch]$Auto) {
    $owner = $(if ($FromDialog -and $script:AbDlg) { $script:AbDlg.W } else { $script:Window })
    if ($FromDialog -and $script:AbDlg) {
        $c = $script:AbDlg.C
        $folder = [Environment]::ExpandEnvironmentVariables("$($c.txtAbPath.Text)".Trim())
        $keep = 10; [void][int]::TryParse("$($c.txtAbKeep.Text)".Trim(), [ref]$keep); if ($keep -lt 1) { $keep = 10 }
        $muster = [bool]$c.chkAbMuster.IsChecked; $tenant = [bool]$c.chkAbTenant.IsChecked
    } else {
        $cfg = Get-HUAbConfig
        $folder = $cfg.Path; $keep = $cfg.Keep; $muster = $cfg.Muster; $tenant = $cfg.Tenant
    }
    if (-not $folder) { if (-not $Auto) { Show-HUMessage 'Bitte zuerst einen Sicherungsordner angeben.' -Icon Warning -Owner $owner }; return }
    # 072 (B6): "Jetzt sichern" uebernimmt Ordner, Haken und Automatik gleich in die Einstellungen -
    # sonst laeuft die Automatik nie, wenn das Fenster danach mit Abbrechen geschlossen wird
    if ($FromDialog -and $script:AbDlg) {
        $why = Save-HUAbSettingsFromForm $script:AbDlg.C $script:Settings
        if ($why) { Show-HUMessage $why -Icon Warning -Owner $owner; return }
        if (Save-HUSettings) { Write-HULogInfo 'App-Sicherung: Ordner, Haken und Automatik gespeichert.' }
    }
    $dr = Get-HUAbDataRoot
    $pw = $(if ($FromDialog -and $script:AbDlg -and $script:AbDlg.Pw) { $script:AbDlg.Pw } else { Get-HUAppBackupPassword -DataRoot $dr })
    if (-not $pw) {
        if ($Auto) {
            Set-HUStateValue 'appBackupResult' 'Automatik: kein Kennwort gespeichert'; Write-HULogWarn 'App-Sicherung (automatisch): kein gespeichertes Kennwort - uebersprungen.'
            # 071 B4: dieser Hinweis hoechstens einmal am Tag
            $today = (Get-Date).ToString('yyyy-MM-dd')
            if ("$(Get-HUStateValue 'appBackupNoPwHint' '')" -ne $today) {
                Set-HUStateValue 'appBackupNoPwHint' $today
                Show-HUToast -Title 'App-Sicherung uebersprungen' -Text "Kein Kennwort fuer die automatische Sicherung gespeichert.`nKlick: Einstellungen > Sicherung" -Icon Warning -OnClick { Open-HUSettings -Tab 'Sicherung' }
            }
            Update-HUAbMainStatus; return
        }
        $r = Show-HUAbPasswordDialog $owner -New
        if (-not $r) { return }
        $pw = $r.Password
        if ($script:AbDlg) { $script:AbDlg.Pw = $pw }
        if ($r.Remember) { try { Save-HUAppBackupPassword -DataRoot $dr -Password $pw } catch { } }
        Update-HUAbTabInfo
    }
    if ((Test-HUJobRunning 'AppBackup') -or (Test-HUJobRunning 'AppBackupOpen')) { if (-not $Auto) { Show-HUMessage 'Es laeuft bereits eine App-Sicherung bzw. Pruefung.' -Icon Info -Owner $owner }; return }
    $bk = $(if ($muster -or $tenant) { Get-HUAbBackupRoot } else { '' })
    $src = @()
    try { $src = @(Get-HUAppBackupSources -AppRoot $script:AppRoot -DataRoot $dr -BackupRoot $bk -IncludeMuster:$muster -IncludeTenantBackups:$tenant) }
    catch { if (-not $Auto) { Show-HUMessage "Dateien nicht ermittelbar: $($_.Exception.Message)" -Icon Error -Owner $owner }; return }
    $mods = @(Get-HUAbModuleList (Get-HUAddonsDir))
    # Teams-Ziele (Udo 27.10.): entschluesselt nur innerhalb der verschluesselten Sicherung
    $extra = @{}
    try {
        $nc = Get-HUNotifyConfig
        if (@($nc.Targets).Count) { $extra['special/teams-ziele.json'] = [Text.Encoding]::UTF8.GetBytes((([ordered]@{ v = 1; items = @($nc.Targets) }) | ConvertTo-Json -Depth 6 -Compress)) }
    } catch { Write-HULogWarn 'App-Sicherung: Teams-Ziele nicht lesbar - ohne sie gesichert.' }
    $per = (@($src | Group-Object Area | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')
    Write-HULogInfo "App-Sicherung startet im Hintergrund$(if ($Auto) { ' (automatisch)' }): $($src.Count) Dateien ($per) ..."
    $script:AbAuto = [bool]$Auto
    $script:AbProg = [hashtable]::Synchronized(@{ Phase = 'Start'; Done = 0; Total = $src.Count })
    $script:AbExtra = $extra
    [void](Start-HUJob -Name 'AppBackup' -Quiet -Vars @{ Src = $src; Pw = $pw; Folder = $folder; Ver = "$($script:Version)"; Keep = $keep; Mods = $mods; Large = $tenant; Extra = $extra; Prog = $script:AbProg } -Code {
            Import-Module (Join-Path $AppRoot 'Core\HU.AppBackup.psm1') -Force -DisableNameChecking
            try {
                $r = New-HUAppBackup -Sources $Src -Password $Pw -Folder $Folder -AppVersion $Ver -Keep $Keep -Modules $Mods -Large:$Large -Extra $Extra -Progress $Prog
                [pscustomobject]@{ __Ab = $true; Ok = $true; Path = $r.Path; Files = $r.Files; Bytes = $r.Bytes; Removed = @($r.Removed); Error = '' }
            } catch { [pscustomobject]@{ __Ab = $true; Ok = $false; Error = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Ab'] })[0]
            $auto = [bool]$script:AbAuto
            # 071 F1: Klartext der Teams-Ziele nach Gebrauch ueberschreiben
            if ($script:AbExtra) { foreach ($k in @($script:AbExtra.Keys)) { try { [Array]::Clear($script:AbExtra[$k], 0, $script:AbExtra[$k].Length) } catch { } }; $script:AbExtra = $null }
            if ($r -and $r.Ok) {
                $mb = [Math]::Round($r.Bytes / 1MB, 1)
                Set-HUStateValue 'appBackupLast' ((Get-Date).ToString('s'))
                Set-HUStateValue 'appBackupResult' "ok, $($r.Files) Dateien ($mb MB)$(if ($auto) { ', automatisch' })"
                Write-HULogOK "App-Sicherung: $(Split-Path -Leaf $r.Path) ($($r.Files) Dateien, $mb MB)$(if (@($r.Removed).Count) { " - alte entfernt: $(@($r.Removed).Count)" })"
                if (-not $auto) { Show-HUMessage "Sicherung erstellt:`n$($r.Path)`n`n$($r.Files) Dateien, $mb MB." -Owner $(if ($script:AbDlg) { $script:AbDlg.W } else { $script:Window }) }
                else { Show-HUToast -Title 'App-Sicherung erstellt' -Text "$($r.Files) Dateien, $mb MB - $(Split-Path -Leaf $r.Path)" -Icon Success -OnClick { Open-HUSettings -Tab 'Sicherung' } }
            } else {
                $err = $(if ($r) { $r.Error } else { (@($Errors) -join ' ') })
                Set-HUStateValue 'appBackupResult' "FEHLER: $err"
                Write-HULogError "App-Sicherung fehlgeschlagen: $err"
                if (-not $auto) { Show-HUMessage "Sicherung fehlgeschlagen:`n$err" -Icon Error -Owner $(if ($script:AbDlg) { $script:AbDlg.W } else { $script:Window }) }
                else { Show-HUToast -Title 'App-Sicherung fehlgeschlagen' -Text "$err`nKlick: Einstellungen > Sicherung" -Icon Error -OnClick { Open-HUSettings -Tab 'Sicherung' } }
            }
            $script:AbProg = $null
            Update-HUAbTabInfo
        })
    Start-HUAbProgressTimer
    Update-HUAbTabInfo
}

# Anzeige waehrend der Sicherung (Reiter Sicherung): Knopf gesperrt, Fortschritt in "Letzte Sicherung"
function Start-HUAbProgressTimer {
    if ($script:AbProgTimer) { $script:AbProgTimer.Start(); return }
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({
            Update-HUAbTabInfo
            if (-not $script:AbProg -and -not (Test-HUJobRunning 'AppBackup') -and -not (Test-HUJobRunning 'AppBackupOpen')) { $this.Stop() }
        })
    $script:AbProgTimer = $t
    $t.Start()
}

function Get-HUAbProgressText {
    $p = $script:AbProg
    if (-not $p -or -not ((Test-HUJobRunning 'AppBackup') -or (Test-HUJobRunning 'AppBackupOpen'))) { return '' }
    $t = [double]$p.Total; $d = [double]$p.Done
    $pc = $(if ($t -gt 0) { " ($([int](100 * $d / $t)) %)" } else { '' })
    switch ("$($p.Phase)") {
        'Dateien' { return "sichert: $([int]$d) von $([int]$t) Dateien$pc" }
        'Verschluesseln' { return 'sichert: verschluesseln ...' }
        'Pruefen' { return 'sichert: zuruecklesen und pruefen ...' }
        'Schluessel' { return 'prueft: Schluessel aus dem Kennwort ...' }
        'Pruefsumme' { return "prueft: Pruefsumme$pc" }
        'Entschluesseln' { return "prueft: entschluesseln$pc" }
        'Lesen' { return "prueft: $([int]$d) von $([int]$t) Dateien lesen$pc" }
        'Vergleichen' { return "prueft: Pruefsummen der Dateien$pc" }
        default { return 'laeuft ...' }
    }
}

# Automatik: beim Start (verzoegert) und dann stuendlich pruefen
function Start-HUAppBackupScheduler {
    $check = {
        try {
            Update-HUAbMainStatus
            $cfg = Get-HUAbConfig
            if (-not $cfg.Path -or -not (Test-HUAppBackupDue $cfg.Mode (Get-HUStateValue 'appBackupLast' ''))) { return }
            # nach einem Fehlschlag (z. B. Netzlaufwerk weg) hoechstens einmal pro Stunde neu versuchen
            $try = $null; try { $try = [datetime]::Parse("$(Get-HUStateValue 'appBackupTry' '')", [Globalization.CultureInfo]::InvariantCulture) } catch { }
            if ($try -and ((Get-Date) - $try).TotalMinutes -lt 60) { return }
            Set-HUStateValue 'appBackupTry' ((Get-Date).ToString('s'))
            Start-HUAppBackupNow -Auto
        } catch { Write-HULogWarn "App-Sicherung (automatisch): $($_.Exception.Message)" }
    }
    $script:AbCheck = $check
    Invoke-HUDelayed 90 { & $script:AbCheck }
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    # alle 15 Minuten pruefen: bei durchlaufender App kommt die taegliche Sicherung so kurz nach Mitternacht
    $t.Interval = [TimeSpan]::FromMinutes(15)
    $t.Add_Tick({ & $script:AbCheck })
    $t.Start()
    $script:AbTimer = $t
}

# ---------------------------------------------------------------- Pruefen / Wiederherstellen ----------------------------------------------------------------
function Start-HUAppBackupOpen([switch]$CheckOnly) {
    $owner = $(if ($script:AbDlg) { $script:AbDlg.W } else { $script:Window })
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'HU-Sicherung (*.husicherung)|*.husicherung'
    $dlg.Title = $(if ($CheckOnly) { 'Sicherung pruefen' } else { 'Sicherung wiederherstellen' })
    $dir = $(if ($script:AbDlg) { [Environment]::ExpandEnvironmentVariables("$($script:AbDlg.C.txtAbPath.Text)".Trim()) } else { (Get-HUAbConfig).Path })
    if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
    if (-not $dlg.ShowDialog($owner)) { return }
    $file = $dlg.FileName
    # Kopf (nicht authentisiert) nur zur Anzeige
    $info = ''
    try {
        $fs = [IO.File]::OpenRead($file)
        try { $h = (Read-HUAppBackupHeaderStream $fs).Header; $info = "Sicherung vom $(try { ([datetime]::Parse("$($h.Created)", [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } catch { $h.Created }), HU-MultiTenant $($h.App), $($h.Files) Dateien." } finally { $fs.Dispose() }
    } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Error -Owner $owner; return }
    $r = Show-HUAbPasswordDialog $owner -Text "$info`n`nKennwort der Sicherung eingeben."
    if (-not $r) { return }
    $dr = Get-HUAbDataRoot
    if ((Test-HUJobRunning 'AppBackup') -or (Test-HUJobRunning 'AppBackupOpen')) { Show-HUMessage 'Es laeuft bereits eine App-Sicherung bzw. Pruefung.' -Icon Info -Owner $owner; return }
    # im Hintergrund pruefen und lesen (grosse Sicherungen brauchen etwas) - Fortschritt in Kopfzeile und Reiter
    $script:AbOpen = @{ File = $file; Info = $info; CheckOnly = [bool]$CheckOnly; Owner = $owner }
    $script:AbProg = [hashtable]::Synchronized(@{ Phase = 'Schluessel'; Done = 0; Total = 0 })
    Write-HULogInfo "App-Sicherung wird $(if ($CheckOnly) { 'geprueft' } else { 'zum Wiederherstellen gelesen' }): $(Split-Path -Leaf $file) ..."
    [void](Start-HUJob -Name 'AppBackupOpen' -Quiet -Vars @{ F = $file; Pw = $r.Password; Ver = "$($script:Version)"; Dr = $dr; Bk = (Get-HUAbBackupRoot); Prog = $script:AbProg } -Code {
            Import-Module (Join-Path $AppRoot 'Core\HU.AppBackup.psm1') -Force -DisableNameChecking
            try { $o = Open-HUAppBackup -Path $F -Password $Pw -AppVersion $Ver -AppRoot $AppRoot -DataRoot $Dr -BackupRoot $Bk -Progress $Prog; [pscustomobject]@{ __AbO = $true; O = $o; Error = '' } }
            catch { [pscustomobject]@{ __AbO = $true; O = $null; Error = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $script:AbProg = $null
            Update-HUAbTabInfo
            $x = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__AbO'] })[0]
            $a = $script:AbOpen; $script:AbOpen = $null
            if (-not $a) { return }
            if (-not $x -or -not $x.O) { Show-HUMessage "Sicherung nicht lesbar: $(if ($x) { $x.Error } else { @($Errors) -join ' ' })" -Icon Error -Owner $a.Owner; return }
            Complete-HUAppBackupOpen $x.O $a
        })
    Start-HUAbProgressTimer
    Update-HUAbTabInfo
}

# Fortsetzung nach dem Lesen im Hintergrund: Pruefergebnis zeigen bzw. Bereiche waehlen und schreiben
function Complete-HUAppBackupOpen($o, $a) {
    $owner = $a.Owner; $file = $a.File; $info = $a.Info; $CheckOnly = $a.CheckOnly
    $dr = Get-HUAbDataRoot
    if ($o.Errors.Count) { foreach ($er in @($o.Errors)) { Write-HULogWarn "App-Sicherung $(Split-Path -Leaf $file): $er" }; Show-HUMessage "Sicherung nicht in Ordnung - nichts geschrieben:`n`n$((@($o.Errors) | Select-Object -First 10) -join "`n")$(if (@($o.Errors).Count -gt 10) { "`n... und $(@($o.Errors).Count - 10) weitere (Protokoll)" })" -Icon Error -Owner $owner; return }
    $areas = @($o.Rows | Group-Object Area | Sort-Object Name | ForEach-Object { "  $($_.Name): $($_.Count) Datei(en)" })
    $mods = @($o.Manifest.Modules | Where-Object { $_ } | ForEach-Object { "$($_.Title) $($_.Version)" })
    if ($CheckOnly) {
        Write-HULogOK "App-Sicherung geprueft: $(Split-Path -Leaf $file) - in Ordnung ($(@($o.Rows).Count) Dateien)."
        Show-HUMessage "Sicherung in Ordnung (Kennwort, Pruefsummen, Inhalt).`n`n$info`n`n$($areas -join "`n")$(if ($mods.Count) { "`n`nZusatzmodule: $($mods -join ', ')" })`n`nEs wurde nichts geschrieben." -Owner $owner
        return
    }
    $sel = Show-HUAbRestorePick $o $owner
    if (-not $sel -or -not @($sel).Count) { return }
    if (-not (Confirm-HU "Diese Bereiche jetzt wiederherstellen?`n`n$(@($sel) -join "`n")`n`nDer aktuelle Stand der betroffenen Dateien wird vorher unter`n$(Join-Path $dr 'Wiederherstellung')`nabgelegt. Danach HU-MultiTenant neu starten." 'Wiederherstellen' -Warning -Owner $owner)) { return }
    $known = @(); try { $known = @((Get-HUNotifyConfig).Targets | ForEach-Object { "$($_.Id)" }) } catch { }
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try {
        $w = Restore-HUAppBackup -Opened $o -Areas @($sel) -AppRoot $script:AppRoot -DataRoot $dr -BackupRoot (Get-HUAbBackupRoot) -KnownTargetIds $known -SettingsValidator { param($f) $null -ne (Import-TenantSettings -SettingsPath $f) } -SpecialHandler {
                param($Name, $Bytes)
                if ($Name -ne 'special/teams-ziele.json') { throw "Unbekannter Sonderinhalt '$Name'." }
                $j = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
                $why = Set-HUNotifyTargets -Targets @($j.items)
                if ($why) { throw "Teams-Ziele: $why" }
            }
    } catch { [System.Windows.Input.Mouse]::OverrideCursor = $null; Show-HUMessage "Wiederherstellen fehlgeschlagen: $($_.Exception.Message)" -Icon Error -Owner $owner; return }
    [System.Windows.Input.Mouse]::OverrideCursor = $null
    Write-HULogOK "App-Sicherung wiederhergestellt: $(Split-Path -Leaf $file) - $($w.Written) Dateien ($(@($sel) -join ', ')). Vorstand: $($w.Before)"
    # Hinweise fuer danach
    $notes = New-Object System.Collections.Generic.List[string]
    if (@($sel) -contains (Get-HUAppBackupArea 'config/settings.json')) {
        try {
            $ns = Import-TenantSettings -SettingsPath (Join-Path $script:AppRoot 'Config\settings.json')
            $noSec = @(foreach ($t in @($ns.tenants)) { $has = $false; try { $has = [bool](Test-HUTenantCredential -TenantKey "$($t.key)" -Settings $ns) } catch { }; if (-not $has) { "$($t.displayName)" } })
            if ($noSec.Count) { $notes.Add("Secret bzw. Zertifikat auf diesem PC fehlt fuer: $($noSec -join ', ') (Einstellungen > Tenants).") }
            foreach ($k in 'backupPath', 'setupPath', 'appBackupPath') { $p = "$(Get-HUProp $ns.ui $k '')"; if ($p -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($p)))) { $notes.Add("Ordner aus den Einstellungen gibt es hier nicht ($k): $p") } }
        } catch { }
    }
    if (@($w.Paused).Count) { $notes.Add("Teams-Auftraege pausiert (Ziel fehlt hier - im Reiter Teams Ziel neu eintragen und einschalten): $(@($w.Paused) -join ', ')") }
    $inst = @(Get-HUAbModuleList (Get-HUAddonsDir) | ForEach-Object { "$($_.Id)" })
    $miss = @(@($w.Modules) | Where-Object { $_ -and $inst -notcontains "$($_.Id)" } | ForEach-Object { "$($_.Title) $($_.Version)" })
    if ($miss.Count) { $notes.Add("Zusatzmodule hier nicht installiert (Reiter Zusatzmodule): $($miss -join ', ')") }
    if (@($sel) -notcontains (Get-HUAppBackupArea 'special/teams-ziele.json') -and @($sel) -contains (Get-HUAppBackupArea 'config/teams-jobs.json')) { $notes.Add('Teams-Ziele nicht mit wiederhergestellt - Auftraege ohne Ziel sind pausiert.') }
    $notes.Add('Freigaben der Fernbedienung und gekoppelte Handys sind nicht in der Sicherung - bei Bedarf neu erteilen bzw. koppeln.')
    # ab jetzt nichts mehr aus dem Speicher zurueckschreiben (Fensterzustand, Apps, Wartung beim Beenden)
    $script:AbRestored = $true
    # 071 B1 (Udo: immer neu starten): jeder offene Stand im Speicher (Einstellungen, Snippets, Teams, Zusatzmodule) wuerde sonst
    # den wiederhergestellten ueberschreiben - deshalb ohne Wahl neu starten; das Einstellungsfenster schliesst ohne Speichern
    Show-HUMessage "$($w.Written) Datei(en) wiederhergestellt.`n`n$(@($notes | ForEach-Object { "- $_" }) -join "`n")`n`nHU-MultiTenant startet jetzt neu, damit der wiederhergestellte Stand gilt." 'Wiederherstellen' -Owner $owner
    Write-HULogInfo 'Wiederhergestellt - HU-MultiTenant startet neu.'
    if ($script:AbDlg) { try { $script:AbDlg.W.Close() } catch { } }
    # erst nach dem Schliessen des Einstellungsfensters (modal) neu starten
    Invoke-HUDelayed 1 { Restart-HUApp }
}

# Auswahl der Bereiche (alle vorgewaehlt). Rueckgabe: Bereichsnamen oder $null.
function Show-HUAbRestorePick($Opened, $Owner) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Wiederherstellen - Bereiche waehlen" Width="860" Height="460" MinWidth="620" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <TextBlock DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="Haken = wird aus der Sicherung zurueckgeschrieben (ueberschreibt den aktuellen Stand). Nicht angehakte Bereiche bleiben, wie sie sind."/>
        <TextBlock x:Name="txtCode" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8" Foreground="#FFB74D"
                   Text="Orange = enthaelt Skripte oder Webhook-Adressen. Diese Bereiche sind nicht vorgewaehlt: Skripte laufen danach mit den Rechten der Tenants bzw. als SYSTEM auf den Geraeten. Nur anhaken, wenn die Sicherung von dir selbst stammt."/>
        <CheckBox x:Name="chkAll" DockPanel.Dock="Top" Content="Alle" IsChecked="False" Style="{StaticResource DarkCheckBox}" Margin="6,0,0,6"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="btnOk" Content="Weiter" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="False" HeadersVisibility="Column" SelectionMode="Single" CanUserAddRows="False">
            <DataGrid.Columns>
                <DataGridTemplateColumn Header="">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <CheckBox IsChecked="{Binding Pick, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center" Style="{StaticResource DarkCheckBox}"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTemplateColumn Header="Bereich">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <TextBlock Text="{Binding Area}" Foreground="{Binding Color}" VerticalAlignment="Center" Margin="4,0"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Dateien" Binding="{Binding Count}" IsReadOnly="True"/>
                <DataGridTextColumn Header="Stand in der Sicherung" Binding="{Binding Saved}" IsReadOnly="True"/>
                <DataGridTextColumn Header="Aktuell hier" Binding="{Binding Current}" IsReadOnly="True"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $fmt = { param($v) if ("$v") { try { ([datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy HH:mm') } catch { "$v" } } else { '' } }
    $rows = foreach ($g in @($Opened.Rows | Group-Object Area | Sort-Object Name)) {
        $sv = @($g.Group | ForEach-Object { "$($_.Changed)" } | Where-Object { $_ } | Sort-Object -Descending)[0]
        $ex = @($g.Group | Where-Object Exists)
        $cv = @($ex | ForEach-Object { "$($_.CurChanged)" } | Where-Object { $_ } | Sort-Object -Descending)[0]
        $code = (@($g.Group | Where-Object { Test-HUAppBackupCodeName "$($_.Name)" }).Count -gt 0)
        [pscustomobject]@{ Pick = (-not $code); Code = $code; Color = $(if ($code) { '#FFB74D' } else { '#E0E0E0' }); Area = $g.Name; Count = $g.Count; Saved = (& $fmt $sv); Current = $(if ($ex.Count) { "$($ex.Count) vorhanden, neueste $(& $fmt $cv)" } else { 'nicht vorhanden' }) }
    }
    $c.grid.ItemsSource = @($rows)
    $st = @{ R = $null; Busy = $false }
    $c.chkAll.IsChecked = (-not @($rows | Where-Object { -not $_.Pick }).Count)
    if (-not @($rows | Where-Object { $_.Code }).Count) { $c.txtCode.Visibility = 'Collapsed' }
    # "Alle": setzt bzw. entfernt alle Haken (ein Klick je Zeile genuegt - Haken direkt in der Zelle)
    $setAll = { param([bool]$v) if ($st.Busy) { return }; foreach ($r in @($c.grid.ItemsSource)) { $r.Pick = $v }; $c.grid.Items.Refresh() }
    $c.chkAll.Add_Checked({ & $setAll $true })
    $c.chkAll.Add_Unchecked({ & $setAll $false })
    $c.btnOk.Add_Click({ $c.grid.CommitEdit(); $st.R = @(@($c.grid.ItemsSource) | Where-Object { $_.Pick } | ForEach-Object { $_.Area }); $w.Close() })
    [void]$w.ShowDialog()
    return $st.R
}
