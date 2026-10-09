#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Apps", Ansicht "Updates": neue Versionen der Bibliotheks-Apps ueber winget finden, herunterladen
    und als neue Version uebernehmen (danach wie gewohnt Testinstallation und Hochladen mit Pilotgruppe).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (winget noetig).
#>

$script:UpdInfo = @{}

function Get-HUUpdApps { return @($script:AppLib | Where-Object { $_.Type -eq 'win32' } | Sort-Object Name) }

function Get-HUUpdRow($App) {
    $i = $script:UpdInfo[$App.Id]
    $dep = @($App.Deployments | Where-Object { $_.AppId })
    $intune = (@($dep | ForEach-Object { "$(Get-HUTenantDisplayName $_.Tenant) $(if ($_.Version) { "v$($_.Version)" })$(if ($_.Stage -eq 'pilot') { ' Pilot' })".Trim() }) -join '; ')
    $status = ''; $latest = ''; $upd = $false
    if (-not $App.WingetId) {
        $status = if ($i -and @($i.Suggest).Count) { "keine winget-ID - $(@($i.Suggest).Count) Vorschlag/Vorschlaege" } elseif ($i) { 'keine winget-ID - bitte zuordnen' } else { 'keine winget-ID' }
    } elseif (-not $i) {
        $status = 'noch nicht geprueft'
    } elseif ($i.Error) {
        $status = "Fehler: $($i.Error)"
    } elseif (-not $i.Latest) {
        $status = 'bei winget nicht gefunden'
    } else {
        $latest = $i.Latest
        $cmp = Compare-HUVersion "$($App.Version)" $latest
        if (-not $App.Version -or $cmp -lt 0) { $status = "$([char]0x2B06) Update verfuegbar"; $upd = $true }
        elseif ($cmp -eq 0) { $status = 'aktuell' }
        else { $status = 'neuer als winget' }
    }
    $old = @($dep | Where-Object { $_.Version -and $App.Version -and (Compare-HUVersion $_.Version $App.Version) -lt 0 })
    if ($old.Count) { $status += " | Intune noch alt: $(@($old | ForEach-Object { Get-HUTenantDisplayName $_.Tenant }) -join ', ')" }
    return [pscustomobject]@{ Id = $App.Id; App = "$($App.Name)"; Version = "$($App.Version)"; Latest = $latest; Status = $status; Intune = $intune; WingetId = "$($App.WingetId)"; Update = $upd }
}

function Update-HUUpdList([string]$SelectId = '') {
    $g = $script:Controls['gridUpd']
    if (-not $SelectId -and $g.SelectedItem) { $SelectId = "$($g.SelectedItem.Id)" }
    $rows = @(Get-HUUpdApps | ForEach-Object { Get-HUUpdRow $_ })
    $nUpd = @($rows | Where-Object Update).Count
    $nNoId = @($rows | Where-Object { -not $_.WingetId }).Count
    if ($script:Controls['chkUpdOnlyNew'].IsChecked) { $rows = @($rows | Where-Object Update) }
    $g.ItemsSource = $rows
    $sel = @($rows | Where-Object { $_.Id -eq $SelectId }) | Select-Object -First 1
    if ($sel) { $g.SelectedItem = $sel }
    if (-not (Test-HUJobRunning 'AppUpd')) {
        $c = @(Get-HUUpdApps).Count
        $script:Controls['lblUpdState'].Text = $(if (-not $c) { 'Keine Setup-Apps (MSI/EXE) in der Bibliothek.' }
            elseif (-not $script:UpdInfo.Count) { "$c App(s) - noch nicht geprueft." }
            else { "$c App(s): $nUpd mit Update$(if ($nNoId) { ", $nNoId ohne winget-ID" })." })
    }
}

function Start-HUUpdCheck {
    $apps = @(Get-HUUpdApps)
    if (-not $apps.Count) { Show-HUMessage 'Keine Setup-Apps (MSI/EXE) in der Bibliothek.' -Icon Info; return }
    $items = @($apps | ForEach-Object { [pscustomobject]@{ Id = $_.Id; WingetId = "$($_.WingetId)"; Name = "$($_.Name)"; Query = (Get-HUAppBaseName $_.Name) } })
    $script:Controls['lblUpdState'].Text = "Pruefe $($items.Count) App(s) bei winget ... (je App einige Sekunden)"
    $script:Controls['btnUpdCheck'].IsEnabled = $false
    $ok = Start-HUJob -Name 'AppUpd' -Output $script:Controls['rtbApps'] -Vars @{ Items = $items } -Code {
        if (-not (Get-HUWingetExe) -and -not (Test-HUWingetModule)) { Write-HULog -Message 'winget fehlt - App-Installer aus dem Microsoft Store installieren.' -Level 'ERROR'; return }
        Write-HULog -Message "winget: $(if (Test-HUWingetModule) { 'Modul Microsoft.WinGet.Client' } else { 'winget.exe' })" -Level 'INFO'
        foreach ($it in $Items) {
            $r = [pscustomobject]@{ Id = $it.Id; Latest = ''; Error = ''; Suggest = @() }
            try {
                if ($it.WingetId) {
                    $r.Latest = Get-HUWingetLatest $it.WingetId
                    Write-HULog -Message "$($it.Name): $(if ($r.Latest) { "winget $($r.Latest)" } else { "'$($it.WingetId)' nicht gefunden" })" -Level 'INFO'
                } else {
                    $r.Suggest = @(Find-HUWingetPackage $it.Query 8)
                    Write-HULog -Message "$($it.Name): keine winget-ID, $($r.Suggest.Count) Treffer fuer '$($it.Query)'" -Level 'INFO'
                }
            } catch { $r.Error = $_.Exception.Message; Write-HULog -Message "$($it.Name): $($r.Error)" -Level 'WARN' }
            $r
        }
    } -OnDone {
        param($Result, $Errors)
        $script:Controls['btnUpdCheck'].IsEnabled = $true
        $auto = @()
        foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Suggest'] })) {
            $a = Get-HUAppById $r.Id
            if (-not $a) { continue }
            $info = @{ Latest = "$($r.Latest)"; Error = "$($r.Error)"; Suggest = @($r.Suggest); Time = Get-Date }
            if (-not $a.WingetId -and @($r.Suggest).Count) {
                # eindeutiger Treffer mit gleichem Namen -> zuordnen
                $base = Get-HUAppBaseName $a.Name
                $same = @($r.Suggest | Where-Object { $_.Name -eq $a.Name -or (Get-HUAppBaseName $_.Name) -eq $base })
                if ($same.Count -eq 1) { $a.WingetId = $same[0].Id; $info.Latest = "$($same[0].Version)"; $auto += "$($a.Name) = $($a.WingetId)" }
            }
            $script:UpdInfo[$r.Id] = $info
        }
        if ($auto.Count) {
            Save-HUAppLib
            Add-HURtbLine $script:Controls['rtbApps'] "winget-ID automatisch zugeordnet (bitte pruefen): $($auto -join '; ')" '#FFB74D'
        }
        Update-HUUpdList
        $n = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Suggest'] }).Count
        if (-not $n) { $script:Controls['lblUpdState'].Text = 'Pruefung ohne Ergebnis - Meldung unten in der Ausgabe (winget installiert?).' }
        else { Add-HURtbLine $script:Controls['rtbApps'] "Updates geprueft: $($script:Controls['lblUpdState'].Text)" '#81C784' }
    }
    if (-not $ok) { $script:Controls['btnUpdCheck'].IsEnabled = $true }
}

function Get-HUUpdSelected {
    $r = $script:Controls['gridUpd'].SelectedItem
    if (-not $r) { Show-HUMessage 'Bitte eine App in der Liste waehlen.' -Icon Info; return $null }
    return (Get-HUAppById "$($r.Id)")
}

function Show-HUWingetIdDialog($App) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="winget-ID zuordnen" Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblApp" Foreground="#E0E0E0" FontWeight="SemiBold" Margin="0,0,0,8"/>
        <DockPanel>
            <Button x:Name="btnSearch" DockPanel.Dock="Right" Content="Suchen" Style="{StaticResource ToolButton}" FontSize="11" Padding="10,2" Margin="6,0,0,0"/>
            <TextBox x:Name="txtQuery" Style="{StaticResource DarkTextBox}" FontSize="12"/>
        </DockPanel>
        <ListBox x:Name="lstHits" Style="{StaticResource DarkListBox}" Height="200" Margin="0,8,0,0">
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <StackPanel Margin="0,2">
                        <TextBlock Text="{Binding Name}" Foreground="#E0E0E0" FontWeight="SemiBold"/>
                        <TextBlock Text="{Binding Sub}" Foreground="#858585" FontSize="10"/>
                    </StackPanel>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
        <TextBlock Text="winget-ID (z. B. 7zip.7zip) - leer = Zuordnung entfernen" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtId" Style="{StaticResource DarkTextBox}" FontSize="12"/>
        <TextBlock x:Name="lblInfo" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,6,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="Uebernehmen" Width="110" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $dc = $d.C
    try { $w.Owner = $script:Window } catch { }
    $script:WgDlg = $dc
    $dc.lblApp.Text = "$($App.Name)$(if ($App.Version) { "  (Bibliothek v$($App.Version))" })"
    $dc.txtQuery.Text = Get-HUAppBaseName $App.Name
    $dc.txtId.Text = "$($App.WingetId)"
    $show = {
        param($Hits)
        $script:WgDlg.lstHits.ItemsSource = @($Hits | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Sub = "$($_.Id)  |  v$($_.Version)"; Id = $_.Id } })
        $script:WgDlg.lblInfo.Text = $(if (@($Hits).Count) { 'Treffer anklicken uebernimmt die ID.' } else { 'Keine Treffer - anderen Suchbegriff probieren (z. B. Herstellername).' })
    }
    $script:WgShow = $show
    $i = $script:UpdInfo[$App.Id]
    if ($i -and @($i.Suggest).Count) { & $show @($i.Suggest) } else { $dc.lblInfo.Text = 'Suchen fragt winget (dauert einige Sekunden).' }
    $dc.lstHits.Add_SelectionChanged({ $s = $script:WgDlg.lstHits.SelectedItem; if ($s) { $script:WgDlg.txtId.Text = "$($s.Id)" } })
    $dc.btnSearch.Add_Click({
            $q = $script:WgDlg.txtQuery.Text.Trim()
            if (-not $q) { return }
            $script:WgDlg.lblInfo.Text = 'Suche ...'
            [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
            try { & $script:WgShow @(Find-HUWingetPackage $q 15) }
            catch { $script:WgDlg.lblInfo.Text = "Fehler: $($_.Exception.Message)" }
            finally { [System.Windows.Input.Mouse]::OverrideCursor = $null }
        })
    $dc.txtQuery.Add_KeyDown({ param($s, $e) if ("$($e.Key)" -eq 'Return') { $e.Handled = $true; $script:WgDlg.btnSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
    $st = @{ Ok = $false }
    $dc.btnOk.Add_Click({ $st.Ok = $true; $w.Close() })
    try { [void]$w.ShowDialog() } finally { $script:WgDlg = $null; $script:WgShow = $null }
    if (-not $st.Ok) { return }
    $id = $dc.txtId.Text.Trim()
    if ($id -eq "$($App.WingetId)") { return }
    $App.WingetId = $id
    $script:UpdInfo.Remove($App.Id)
    $hit = @($dc.lstHits.ItemsSource | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if ($hit) { $script:UpdInfo[$App.Id] = @{ Latest = ($hit.Sub -replace '^.*\|\s*v', ''); Error = ''; Suggest = @(); Time = Get-Date } }
    Save-HUAppLib
    Update-HUUpdList $App.Id
}

function Start-HUUpdGet {
    $a = Get-HUUpdSelected
    if (-not $a) { return }
    if (-not $a.WingetId) { Show-HUMessage 'Zuerst eine winget-ID zuordnen.' -Icon Info; return }
    $i = $script:UpdInfo[$a.Id]
    $ver = if ($i) { "$($i.Latest)" } else { '' }
    if (-not $ver) { Show-HUMessage 'Zuerst "Nach Updates suchen".' -Icon Info; return }
    if ($a.Version -and (Compare-HUVersion $a.Version $ver) -ge 0 -and -not (Confirm-HU "Die Bibliothek hat schon v$($a.Version) (winget: v$ver).`n`nTrotzdem neu herunterladen?")) { return }
    $safe = ("$($a.Name)" -replace '[\\/:*?"<>|]', '_').Trim()
    $dir = Join-Path $env:USERPROFILE "Downloads\HU-App-Updates\$safe\$ver"
    if (-not (Confirm-HU "$($a.Name): v$ver von winget herunterladen?`n`nOrdner: $dir`n`nDie Datei wird als neue Version der Bibliotheks-App uebernommen - hochgeladen wird noch nichts. Danach: Testinstallation in der Sandbox, dann Hochladen mit Pilotgruppe.")) { return }
    $script:UpdGetApp = $a.Id
    $script:Controls['btnUpdGet'].IsEnabled = $false
    $ok = Start-HUJob -Name 'AppUpdGet' -Output $script:Controls['rtbApps'] -Vars @{ WId = "$($a.WingetId)"; Ver = $ver; Dir = $dir; Msi = ($a.Kind -eq 'msi'); AName = "$($a.Name)" } -Code {
        Write-HULog -Message "$AName v${Ver}: lade herunter ($WId) ..." -Level 'INFO'
        $r = Save-HUWingetInstaller -Id $WId -Version $Ver -Folder $Dir -PreferMsi:$Msi
        Write-HULog -Message "Heruntergeladen: $($r.Path)" -Level 'OK'
        [pscustomobject]@{ __UpdPath = $r.Path; Silent = (Get-HUWingetSilentSwitch $Dir) }
    } -OnDone {
        param($Result, $Errors)
        $script:Controls['btnUpdGet'].IsEnabled = $true
        $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__UpdPath'] }) | Select-Object -First 1
        $a = Get-HUAppById $script:UpdGetApp
        if (-not $r -or -not $a) { return }
        $oldLeaf = if ($a.SetupPath) { Split-Path $a.SetupPath -Leaf } else { '' }
        $oldCmd = "$($a.InstallCmd)"
        Set-HUAppMode 'lib'
        Add-HUAppFromFile $r.__UpdPath -Target $a
        # abgebrochen (z. B. Rueckfrage wegen anderem Namen) -> nichts weiter
        if ("$($a.SetupPath)" -ne (Get-Item -LiteralPath $r.__UpdPath).FullName) { return }
        if ($a.Kind -eq 'exe') {
            $newLeaf = Split-Path $a.SetupPath -Leaf
            # eigene Schalter der bisherigen Version behalten, sonst die aus dem winget-Manifest
            if ($oldLeaf -and $oldCmd -like "*$oldLeaf*" -and $oldCmd.Trim() -ne "`"$oldLeaf`"") { $a.InstallCmd = $oldCmd.Replace($oldLeaf, $newLeaf) }
            elseif ("$($a.InstallCmd)".Trim() -eq "`"$newLeaf`"" -and $r.Silent) { $a.InstallCmd = "`"$newLeaf`" $($r.Silent)" }
            Save-HUAppLib
            Show-HUAppForm $a
        }
        Add-HURtbLine $script:Controls['rtbApps'] "Naechste Schritte: Installationsbefehl pruefen -> Testinstallation in der Sandbox -> Hochladen (Pilotgruppe) -> spaeter freigeben." '#90CAF9'
    }
    if (-not $ok) { $script:Controls['btnUpdGet'].IsEnabled = $true }
}

function Register-HUUpdHandlers {
    $c = $script:Controls
    $c['chkUpdOnlyNew'].IsChecked = [bool](Get-HUStateValue 'updOnlyNew' $false)
    $c['chkUpdOnlyNew'].Add_Checked({ Set-HUStateValue 'updOnlyNew' $true; Update-HUUpdList })
    $c['chkUpdOnlyNew'].Add_Unchecked({ Set-HUStateValue 'updOnlyNew' $false; Update-HUUpdList })
    $c['btnUpdCheck'].Add_Click({ Start-HUUpdCheck })
    $c['btnUpdGet'].Add_Click({ Start-HUUpdGet })
    $c['btnUpdSetId'].Add_Click({ $a = Get-HUUpdSelected; if ($a) { Show-HUWingetIdDialog $a } })
    $c['gridUpd'].Add_MouseDoubleClick({ $a = Get-HUUpdSelected; if ($a) { Show-HUWingetIdDialog $a } })
    $c['btnUpdOpen'].Add_Click({
            $a = Get-HUUpdSelected
            if (-not $a) { return }
            Set-HUAppMode 'lib'
            Update-HUAppList $a.Id
            Select-HUApp $a.Id
        })
}
