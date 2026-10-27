#Requires -Version 5.1
<#
.SYNOPSIS
    Muster-Pakete austauschen (2.5.7) - Oberflaeche: Exportieren, Importieren (Knopf und Ziehen), Pruefansicht,
    "ungeprueft" vor dem Anwenden bestaetigen.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Logik in Core\HU.MusterExchange.psm1.
#>

# Pruefansicht: Mode Export | Import | Apply. Rueckgabe: @{ Ok; Publisher; Note; Title; AllowScripts } (Ok = $false bei Abbruch)
function Show-HUMuReview {
    param([ValidateSet('Export', 'Import', 'Apply')][string]$Mode, [string]$Heading, [string]$Info, [object[]]$Rows, [string[]]$NameMarks = @(),
        [string]$Title = '', [string]$Publisher = '', [scriptblock]$Replan = $null, $Owner = $null, [string]$SaveName = '')
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1100" Height="680" MinWidth="760" MinHeight="420" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <StackPanel DockPanel.Dock="Top">
            <TextBlock x:Name="lblHead" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="lblInfo" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,4,0,8"/>
            <Grid x:Name="pnlFields" Margin="0,0,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock x:Name="lblTitle" Grid.Row="0" Text="Name des Pakets" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="0,0,10,4"/>
                <TextBox x:Name="txtTitle" Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkTextBox}" Margin="0,0,0,4" ToolTip="So heisst das Paket in deiner Bibliothek (gibt es den Namen schon, wird (2) angehaengt)"/>
                <TextBlock x:Name="lblPub" Grid.Row="1" Text="Herausgeber" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="0,0,10,4"/>
                <TextBox x:Name="txtPub" Grid.Row="1" Grid.Column="1" Style="{StaticResource DarkTextBox}" Margin="0,0,0,4" ToolTip="Frei waehlbar, steht in der Datei (z. B. Team oder Funktion) - bitte keinen Personennamen, wenn die Datei weitergegeben wird"/>
                <TextBlock x:Name="lblNote" Grid.Row="2" Text="Notiz zur Datei" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBox x:Name="txtNote" Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkTextBox}" ToolTip="Optional, steht im Manifest der Datei"/>
            </Grid>
        </StackPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="btnOk" MinWidth="170" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
                <Button x:Name="btnCancel" Content="Abbrechen" Width="110" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
            </StackPanel>
            <TextBlock x:Name="lblSum" Foreground="#CCCCCC" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <Grid>
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <DataGrid x:Name="grid" Grid.Row="0" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="False" HeadersVisibility="Column" SelectionMode="Single" CanUserAddRows="False">
                <DataGrid.Columns>
                    <DataGridCheckBoxColumn Header="Freigeben" Binding="{Binding Freigeben, UpdateSourceTrigger=PropertyChanged}" Width="Auto"/>
                    <DataGridTextColumn Header="Paket" Binding="{Binding Paket}" Width="Auto" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="Auto" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="Auto" MaxWidth="360" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Ergebnis" Binding="{Binding Ergebnis}" Width="Auto" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Grund" Binding="{Binding Grund}" Width="Auto" MaxWidth="420" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Entfernt" Binding="{Binding Entfernt}" Width="Auto" MaxWidth="360" IsReadOnly="True"/>
                    <DataGridTextColumn Header="Bitte ansehen" Binding="{Binding Hinweise}" Width="*" MinWidth="200" IsReadOnly="True"/>
                </DataGrid.Columns>
            </DataGrid>
            <TextBlock x:Name="lblNames" Grid.Row="1" Text="Namen von Orten und Authentifizierungsstaerken in der Datei (koennen Namen der Organisation enthalten):" Style="{StaticResource FieldLabel}" Margin="0,8,0,2"/>
            <TextBox x:Name="txtNames" Grid.Row="2" Style="{StaticResource DarkTextBox}" IsReadOnly="True" Height="64" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </Grid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $w.Title = $(switch ($Mode) { 'Export' { 'Muster exportieren - Pruefansicht' } 'Import' { 'Muster importieren - Pruefansicht' } default { 'Ungepruefte Pakete - Pruefansicht' } })
    $c.lblHead.Text = $Heading; $c.lblInfo.Text = $Info
    $c.btnOk.Content = $(switch ($Mode) { 'Export' { 'Speichern unter ...' } 'Import' { 'In die Bibliothek uebernehmen' } default { 'Als geprueft bestaetigen und weiter' } })
    $c.btnOk.ToolTip = $(switch ($Mode) { 'Export' { 'Datei .humuster mit den Eintraegen "uebernommen" speichern' } 'Import' { 'Neues Paket in der Bibliothek anlegen - als "ungeprueft" gekennzeichnet' } default { 'Du hast die Eintraege angesehen - die Pakete gelten danach als geprueft und koennen angewendet werden' } })
    # Felder je Modus
    $c.txtTitle.Text = $Title; $c.txtPub.Text = $Publisher
    if ($Mode -eq 'Apply') { $c.pnlFields.Visibility = 'Collapsed' }
    if ($Mode -eq 'Import') { foreach ($n in 'lblPub', 'txtPub', 'lblNote', 'txtNote') { $c[$n].Visibility = 'Collapsed' } }
    if ($Mode -eq 'Export') { foreach ($n in 'lblTitle', 'txtTitle') { $c[$n].Visibility = 'Collapsed' } }
    $c.txtNames.Text = $(if (@($NameMarks).Count) { @($NameMarks) -join "`n" } else { '(keine)' })
    $st = @{ Ok = $false; Rows = $Rows; Path = '' }
    $show = {
        $vm = @(foreach ($r in @($st.Rows)) {
                $erg = switch ("$($r.Status)") { 'ok' { 'uebernommen' } 'gesperrt' { 'gesperrt' } 'entfaellt' { 'entfaellt' } default { "$($r.Status)" } }
                [pscustomobject]@{ Paket = $(if ($r.PSObject.Properties['Paket']) { "$($r.Paket)" } else { '' }); Typ = "$($r.Typ)"; Name = "$($r.Name)"; Ergebnis = $erg
                    Grund = $(if ($r.PSObject.Properties['Grund']) { "$($r.Grund)" } else { '' }); Entfernt = $(if ($r.PSObject.Properties['Entfernt']) { "$($r.Entfernt)" } else { '' })
                    Hinweise = "$($r.Hinweise)"; Freigeben = [bool]($r.PSObject.Properties['Allow'] -and $r.Allow); IsScript = [bool]($r.PSObject.Properties['IsScript'] -and $r.IsScript)
                    Key = "$($r.Typ)|$($r.Name)"; Bewertung = $(if ("$($r.Status)" -eq 'gesperrt') { 'abweichend' } else { '' }) }
            })
        $c.grid.ItemsSource = $vm
        $ok = @($st.Rows | Where-Object { "$($_.Status)" -eq 'ok' }).Count; $bl = @($st.Rows | Where-Object { "$($_.Status)" -eq 'gesperrt' }).Count
        $c.lblSum.Text = "$ok uebernommen, $bl gesperrt$(if (@($st.Rows | Where-Object { $_.PSObject.Properties['P2'] -and $_.P2 }).Count) { ' - Eintraege mit Risiko-Bedingung brauchen Entra ID P2' })"
        $c.btnOk.IsEnabled = ($Mode -eq 'Apply') -or [bool]$ok
    }
    & $show
    # Spalte Paket nur beim Anwenden, Freigeben nur beim Export (Skripte einzeln nach Ansicht freigeben)
    $c.grid.Columns[1].Visibility = $(if ($Mode -eq 'Apply') { 'Visible' } else { 'Collapsed' })
    if ($Mode -ne 'Export' -or -not $Replan -or -not @($Rows | Where-Object { $_.PSObject.Properties['IsScript'] -and $_.IsScript }).Count) { $c.grid.Columns[0].Visibility = 'Collapsed' }
    $c.grid.Add_CellEditEnding({
            param($s, $e)
            if ("$($e.Column.Header)" -ne 'Freigeben' -or -not $Replan) { return }
            $row = $e.Row.Item
            if (-not $row.IsScript) { $e.Cancel = $true; return }
            $cb = $e.EditingElement
            $want = [bool]$cb.IsChecked
            $allow = @(@($c.grid.ItemsSource) | Where-Object { $_.IsScript -and ($(if ($_.Key -eq $row.Key) { $want } else { $_.Freigeben })) } | ForEach-Object { $_.Key })
            # erst nach dem Bearbeiten neu planen (waehrend CellEditEnding darf die Liste nicht wechseln)
            $script:MuRvAllow = $allow
            $w.Dispatcher.BeginInvoke([Action] { $st.Rows = @(& $Replan $script:MuRvAllow); & $show }) | Out-Null
        })
    $c.btnOk.Add_Click({
            if ($Mode -eq 'Import' -and -not $c.txtTitle.Text.Trim()) { Show-HUMessage 'Bitte einen Namen fuer das Paket eingeben.' -Icon Warning -Owner $w; return }
            # Export: Speicherort noch im Fenster waehlen (Pruefansicht bleibt offen, Abbrechen fuehrt zurueck)
            if ($Mode -eq 'Export') {
                $dlg = New-Object Microsoft.Win32.SaveFileDialog
                $dlg.Filter = 'Muster-Paket (*.humuster)|*.humuster'
                $dlg.FileName = $SaveName
                $dlg.AddExtension = $true; $dlg.OverwritePrompt = $true
                # zuletzt verwendeter Ordner, sonst Downloads (Dokumente liegt oft in OneDrive und oeffnet langsam)
                $last = "$(Get-HUStateValue 'muExportDir' '')"
                $dlg.InitialDirectory = $(if ($last -and (Test-Path -LiteralPath $last)) { $last } else { Join-Path $env:USERPROFILE 'Downloads' })
                if (-not $dlg.ShowDialog($w)) { return }
                $st.Path = $dlg.FileName
                try { Set-HUStateValue 'muExportDir' (Split-Path -Parent $dlg.FileName) } catch { }
            }
            $st.Ok = $true; $w.Close()
        })
    $c.btnCancel.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    return [pscustomobject]@{ Ok = $st.Ok; Path = "$($st.Path)"; Publisher = "$($c.txtPub.Text)".Trim(); Note = "$($c.txtNote.Text)".Trim(); Title = "$($c.txtTitle.Text)".Trim()
        AllowScripts = @(@($c.grid.ItemsSource) | Where-Object { $_.IsScript -and $_.Freigeben } | ForEach-Object { $_.Key }); Rows = $st.Rows }
}

# Paket exportieren (rechts im Reiter Muster bzw. Rechtsklick)
function Start-HUMuExport {
    $p = Get-HUMuCurPackage
    if (-not $p) { Show-HUMessage 'Bitte links ein Paket waehlen.' -Icon Info; return }
    try { $plan = Get-HUMusterExportPlan -Settings $script:Settings -Package $p }
    catch { Show-HUMessage "Export nicht moeglich: $($_.Exception.Message)" -Icon Error; return }
    # kein GetNewClosure (Funktionen und $script:-Variablen des Programms waeren darin nicht sichtbar) - laeuft waehrend ShowDialog
    $script:MuExpPkg = $p
    $replan = { param([string[]]$Allow) $script:MuExpPlan = Get-HUMusterExportPlan -Settings $script:Settings -Package $script:MuExpPkg -AllowScripts $Allow; @($script:MuExpPlan.Rows | ForEach-Object { $_ | Add-Member -NotePropertyName Allow -NotePropertyValue ($Allow -contains "$($_.Typ)|$($_.Name)") -Force; $_ }) }
    $script:MuExpPlan = $plan
    $pub = "$(Get-HUStateValue 'muPublisher' '')"
    if (-not $pub -and $plan.OrigPublisher) { $pub = $plan.OrigPublisher }
    $r = Show-HUMuReview -Mode Export -Heading "Exportieren: $($p.Title)" -Rows @($plan.Rows) -NameMarks @($plan.NameMarks) -Publisher $pub -Replan $replan -SaveName (ConvertTo-HUMxFileName $p.Title) `
        -Info 'Bevor die Datei entsteht, wird bereinigt: keine Zuweisungen, Benutzer, IP-Bereiche, Pruefer, Bereichsmarkierungen (Standard) und Benachrichtigungen; Gruppen nur als Name. Gesperrt sind Eintraege mit Geheimnissen, Kennungen oder Domains eigener Tenants, Zertifikat/WLAN/VPN - und Skripte, solange du sie nicht einzeln freigibst. Bitte Namen und Beschreibungen ansehen: sie gehen so in die Datei.'
    if (-not $r.Ok) { return }
    $plan = $script:MuExpPlan
    try { Set-HUStateValue 'muPublisher' $r.Publisher; Save-HUUIState } catch { }
    if (-not $r.Path) { return }
    try {
        $o = Save-HUMusterExport -Plan $plan -Path $r.Path -Publisher $r.Publisher -Note $r.Note -AppVersion $script:Version
        Add-HURtbLine $script:Controls['rtbMu'] "Exportiert: $($o.Path) - $($o.Count) Eintraege, SHA-256 $($o.Sha256)" '#81C784'
        Show-HUMessage "Gespeichert: $($o.Path)`n`n$($o.Count) Eintraege.`nPruefsumme (SHA-256), zum Vergleich beim Empfaenger:`n$($o.Sha256)" -Icon Info
    } catch { Show-HUMessage "Export fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}

# Import aus Dateien (Knopf oder Ziehen auf die Bibliothek)
function Start-HUMuImport([string[]]$Paths = @()) {
    if (-not @($Paths).Count) {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Muster-Paket oder JSON (*.humuster;*.json)|*.humuster;*.json|Muster-Paket (*.humuster)|*.humuster|JSON-Dateien (*.json)|*.json'
        $dlg.Multiselect = $true
        $last = "$(Get-HUStateValue 'muImportDir' '')"
        $dlg.InitialDirectory = $(if ($last -and (Test-Path -LiteralPath $last)) { $last } else { Join-Path $env:USERPROFILE 'Downloads' })
        if (-not $dlg.ShowDialog($script:Window)) { return }
        $Paths = @($dlg.FileNames)
        try { Set-HUStateValue 'muImportDir' (Split-Path -Parent $Paths[0]) } catch { }
    }
    try { $plan = Get-HUMusterImportPlan -Settings $script:Settings -Paths $Paths -AppVersion $script:Version }
    catch { Show-HUMessage "Import nicht moeglich: $($_.Exception.Message)" -Icon Error; return }
    if (-not $plan.Ok -and -not @($plan.Rows).Count) {
        Show-HUMessage "Nichts importiert:`n`n$(@($plan.Errors | Select-Object -First 8) -join "`n")$(if ($plan.Sha256) { "`n`nPruefsumme der Datei: $($plan.Sha256)" })" -Icon Warning
        return
    }
    $info = if ($plan.Kind -eq 'humuster') {
        "Datei von '$(if ($plan.Publisher) { $plan.Publisher } else { 'unbekannt' })'$(if ($plan.Exported) { ", exportiert $(try { ([datetime]$plan.Exported).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } catch { $plan.Exported })" }). Pruefsumme (SHA-256): $($plan.Sha256) - mit dem Herausgeber vergleichen (belegt, dass die Datei unveraendert ist, nicht wer sie gemacht hat). "
    } else { 'JSON-Dateien: erkannt werden Conditional Access, benannte Orte, Authentifizierungsstaerken und bekannte Intune-Objekte. ' }
    $info += 'Bereinigt wie beim Export. Das Paket kommt als NEUES Paket in die Bibliothek, gekennzeichnet "ungeprueft": anwenden laesst es sich erst nach deiner Bestaetigung.'
    if (-not $plan.Ok) { $info += "`nHinweis: $(@($plan.Errors) -join ' ')" }
    $r = Show-HUMuReview -Mode Import -Heading "Importieren: $($plan.Title)" -Info $info -Rows @($plan.Rows) -NameMarks @($plan.NameMarks) -Title $plan.Title
    if (-not $r.Ok) { return }
    try {
        $p = Save-HUMusterImport -Settings $script:Settings -Plan $plan -Title $r.Title
        Add-HURtbLine $script:Controls['rtbMu'] "Importiert: '$($p.Title)' ($($p.Count) Eintraege) - ungeprueft" '#81C784'
        Update-HUMuList -SelectId $p.Id
    } catch { Show-HUMessage "Import fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}

# Vor dem Anwenden: ungepruefte Pakete einmal ansehen und bestaetigen (Udo 27.10.). $true = weiter
function Confirm-HUMuChecked([object[]]$Packages) {
    $open = @($Packages | Where-Object { $_ -and -not $_.Checked })
    if (-not $open.Count) { return $true }
    $rows = @(foreach ($p in $open) { @(Get-HUMusterReviewRows -Settings $script:Settings -Package $p) })
    $r = Show-HUMuReview -Mode Apply -Heading "$($open.Count) importierte(s) Paket(e) noch ungeprueft: $(@($open | ForEach-Object { $_.Title }) -join ', ')" -Rows $rows `
        -Info 'Importierte Pakete kommen aus einer fremden Datei. Bitte die Eintraege ansehen - vor allem Namen, Beschreibungen und Hinweise. Angewendet wird wie immer: Conditional Access NEU im Modus Nur Bericht, Intune ohne Zuweisungen, Notfallkonten des Ziels ausgenommen.'
    if (-not $r.Ok) { return $false }
    foreach ($p in $open) { try { [void](Set-HUMusterChecked -Settings $script:Settings -Id $p.Id) } catch { Show-HUMessage "'$($p.Title)' nicht bestaetigt: $($_.Exception.Message)" -Icon Error; return $false } }
    try { Update-HUMuList } catch { }
    return $true
}

# Paket von Hand als geprueft bestaetigen (Knopf rechts)
function Start-HUMuCheck {
    $p = Get-HUMuCurPackage
    if (-not $p -or $p.Checked) { return }
    if (Confirm-HUMuChecked @($p)) { Add-HURtbLine $script:Controls['rtbMu'] "'$($p.Title)' als geprueft bestaetigt." '#81C784' }
}

function Register-HUMusterExchangeHandlers {
    $c = $script:Controls
    $c['btnMuImport'].Add_Click({ Start-HUMuImport })
    $c['btnMuExport'].Add_Click({ Start-HUMuExport })
    $c['btnMuCheck'].Add_Click({ Start-HUMuCheck })
    # Ziehen auf die Bibliothek: .humuster oder .json
    $c['lstMuPkg'].AllowDrop = $true
    $c['lstMuPkg'].Add_DragOver({
            param($s, $e)
            $ok = $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -and @($e.Data.GetData([System.Windows.DataFormats]::FileDrop) | Where-Object { [IO.Path]::GetExtension($_) -in '.humuster', '.json' }).Count
            $e.Effects = $(if ($ok) { [System.Windows.DragDropEffects]::Copy } else { [System.Windows.DragDropEffects]::None }); $e.Handled = $true
        })
    $c['lstMuPkg'].Add_Drop({
            param($s, $e)
            if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
            $files = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop) | Where-Object { [IO.Path]::GetExtension($_) -in '.humuster', '.json' })
            if ($files.Count) { $script:MuDropFiles = [string[]]$files; $script:Window.Dispatcher.BeginInvoke([Action] { Start-HUMuImport $script:MuDropFiles }) | Out-Null }
        })
}
