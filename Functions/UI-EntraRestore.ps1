#Requires -Version 5.1
<#
.SYNOPSIS
    Backup & Verlauf: Entra-Einstellungen zurueckschreiben - Vorschau-Dialog und Ablauf (Logik in Core\HU.EntraRestore.psm1).
.NOTES
    Wird per Dot-Source aus Main.ps1 geladen (UI-Thread). Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
    Ablauf: Plan im Hintergrund lesen -> Vorschau (je Feld jetzt/danach, Sperren, Warnungen, Pflicht-Haken) ->
    nach Bestaetigung im Hintergrund schreiben (erneut lesen, sichern, schreiben, nachpruefen) -> Ergebnis.
#>

# Vorschau-Dialog. Rueckgabe $true = zurueckschreiben.
# 2.5.1: -Remaining = Anzahl weiterer Ziele in der Warteschlange -> zusaetzlich Knopf 'Ueberspringen';
# Abbrechen beendet dann das ganze Uebertragen ($script:ErPreviewChoice = 'skip' | 'cancel' | 'write')
$script:ErPreviewChoice = ''
function Show-HUEntraRestorePreview($Plan, [string]$TenantName, [string]$Stamp, [int]$Remaining = 0) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="880" Height="640" MinWidth="640" MinHeight="420" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
            <TextBlock x:Name="lblTitle" Foreground="#E0E0E0" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="lblSub" Style="{StaticResource HintText}" FontSize="11" Margin="0,4,0,8" TextWrapping="Wrap"/>
        </StackPanel>
        <DataGrid x:Name="gridChanges" Grid.Row="1" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                  ToolTip="Nur diese Felder werden geschrieben: links der Wert jetzt im Tenant, rechts der Wert aus dem Backup">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Feld" Binding="{Binding Feld}" Width="200"/>
                <DataGridTextColumn Header="Anzahl" Binding="{Binding Anzahl}" Width="70"/>
                <DataGridTextColumn Header="Jetzt im Tenant" Binding="{Binding Jetzt}" Width="Auto"/>
                <DataGridTextColumn Header="Danach (aus dem Backup)" Binding="{Binding Danach}" Width="Auto"/>
                <DataGridTextColumn Header="Voll" Binding="{Binding Status}" Width="70"/>
            </DataGrid.Columns>
        </DataGrid>
        <Expander x:Name="expFull" Grid.Row="2" Header="Voller Wert der markierten Zeile" Foreground="#E0E0E0" Margin="0,8,0,0" IsExpanded="False"
                  ToolTip="Zeigt den kompletten Wert, der geschrieben wird - auch das, was in der Tabelle gekuerzt ist">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBox x:Name="txtFullNow" Grid.Column="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" MaxHeight="160" Margin="0,4,4,0" Background="#252526" Foreground="#E0E0E0" FontFamily="Consolas" FontSize="11"/>
                <TextBox x:Name="txtFullThen" Grid.Column="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" MaxHeight="160" Margin="4,4,0,0" Background="#252526" Foreground="#E0E0E0" FontFamily="Consolas" FontSize="11"/>
            </Grid>
        </Expander>
        <ScrollViewer Grid.Row="3" MaxHeight="200" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
            <StackPanel x:Name="pnlInfo"/>
        </ScrollViewer>
        <StackPanel x:Name="pnlType" Grid.Row="4" Orientation="Horizontal" Margin="0,10,0,0" Visibility="Collapsed">
            <TextBlock x:Name="lblType" Foreground="#FF8A65" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="txtType" Width="220" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Zur Sicherheit den Namen des Ziel-Tenants eintippen"/>
        </StackPanel>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnWrite" Content="&#x21BA; Zurueckschreiben" MinWidth="170" Padding="14,0,14,0" Background="#A65A28" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Liest den Tenant erneut, sichert den aktuellen Stand als Datei, schreibt nur die gezeigten Felder und prueft danach nach"/>
            <Button x:Name="btnSkip" Content="Ueberspringen" Width="130" Background="#555555" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Diesen Tenant auslassen und mit dem naechsten Ziel weitermachen"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="110" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $isAl = ("$($Plan.Kind)" -eq 'transferAlign')
    $isTr = ("$($Plan.Kind)" -eq 'transferNew') -or $isAl
    $isEt = [bool]$Plan.PSObject.Properties['Transfer']   # 2.4.4 Entra aus dem Muster
    $isEtCa = $isEt -and "$($Plan.Kind)" -eq 'caNew'
    $w.Title = if ($isEtCa) { 'Uebertragen (Conditional Access aus dem Muster, Nur Bericht)' } elseif ($isEt) { 'Uebertragen (Entra, aus dem Muster)' } elseif ($isTr) { 'Uebertragen' } elseif ($Plan.Kind -eq 'caNew') { 'Conditional Access wiederherstellen (Nur Bericht)' } else { 'Entra-Einstellung zurueckschreiben' }
    $c.lblTitle.Text = if ($isEt -or $isTr) { "$($Plan.Typ): $($Plan.Name)  -  $($Plan.SourceLabel) -> $TenantName" } else { "$($Plan.Typ): $($Plan.Name)  -  $TenantName" }
    if ($isEt) { $c.gridChanges.Columns[3].Header = 'Danach (aus dem Muster)'; $c.btnWrite.Content = $(if ($isEtCa) { "$([char]0x2192) Neu anlegen (Nur Bericht)" } else { "$([char]0x2192) Uebertragen" }) }
    if ($isEtCa) { $c.btnWrite.ToolTip = 'Legt eine NEUE Richtlinie im Modus Nur Bericht an (erzwingt nichts), liest sie danach nach und legt eine Rueckgaengig-Datei an. Bestehende Richtlinien bleiben unveraendert.' }
    elseif ($isEt -and "$($Plan.Method)" -eq 'POST') { $c.btnWrite.ToolTip = 'Legt im Ziel NEU an, liest danach nach und prueft jedes Feld.' }
    elseif ($isEt) { $c.btnWrite.ToolTip = 'Liest das Ziel erneut, sichert den aktuellen Stand als Datei, schreibt nur die gezeigten Felder und prueft danach nach.' }
    elseif ($isAl) { $c.btnWrite.ToolTip = 'Liest das Ziel erneut, sichert es als Rueckgaengig-Datei, gleicht an und prueft danach nach. Zuweisungen bleiben.' }
    elseif ($isTr) { $c.btnWrite.ToolTip = 'Legt im Ziel NEU an (ohne Zuweisungen), liest danach nach und legt eine Rueckgaengig-Datei an.' }
    elseif ($Plan.Method -eq 'POST') { $c.btnWrite.ToolTip = 'Legt eine NEUE Richtlinie im Modus Nur Bericht an; die bestehende bleibt unveraendert.' }
    if ($isTr) { $c.gridChanges.Columns[3].Header = 'Danach (aus der Quelle)'; $c.btnWrite.Content = $(if ($isAl) { "$([char]0x2192) Angleichen" } else { "$([char]0x2192) Neu anlegen" }) }
    $c.lblSub.Text = if ($isEtCa) { "Wird in $TenantName als NEUE Richtlinie '$(if ($Plan.Body) { $Plan.Body.displayName } else { "$($Plan.Name) (von Muster)" })' im Modus $(if ($Plan.Body -and "$($Plan.Body.state)" -eq 'disabled') { 'AUS' } else { 'NUR BERICHT' }) angelegt - bestehende Richtlinien bleiben unveraendert. Ohne Konten; Gruppen je Platz unten waehlbar, Orte ueber den Namen zugeordnet, Notfallkonten des Ziels ausgenommen. Schreibrecht: $($Plan.Perm)." } elseif ($isEt) { "Entra-Einstellung aus dem festgehaltenen Muster nach $TenantName. Methode $($Plan.Method), Schreibrecht: $($Plan.Perm). $(if ($Plan.Method -eq 'POST') { 'Wird im Ziel NEU angelegt; danach nachgelesen und je Feld geprueft.' } else { 'Vor dem Schreiben wird das Ziel erneut gelesen und als Datei gesichert; danach nachgeprueft.' })" } elseif ($isAl) { "Das bestehende Objekt in $TenantName wird an die Quelle ANGEGLICHEN. Schreibrecht: $($Plan.Perm). Vor dem Schreiben wird das Ziel erneut gelesen (geaendert = Abbruch) und als Rueckgaengig-Datei gesichert; Zuweisungen bleiben unveraendert." } elseif ($isTr) { "Wird in $TenantName NEU angelegt, ohne Zuweisungen. Schreibrecht: $($Plan.Perm). Vor dem Schreiben wird erneut geprueft, ob es den Namen dort inzwischen gibt; danach wird nachgelesen und eine Rueckgaengig-Datei angelegt." } elseif ($Plan.Method -eq 'POST') { "Aus dem Stand $Stamp in denselben Tenant als NEUE Richtlinie, Schreibrecht: $($Plan.Perm). Die bestehende Richtlinie wird nicht veraendert." } else { "Aus dem Stand $Stamp in denselben Tenant. Methode $($Plan.Method), Schreibrecht: $($Plan.Perm). Vor dem Schreiben wird der Tenant erneut gelesen und der aktuelle Stand als Datei gesichert." }
    # B1: gekuerzte Werte muessen vor dem Schreiben einmal voll angesehen werden (Zeile markieren, voller Wert klappt auf)
    $rows = @($Plan.Changes | ForEach-Object { [pscustomobject]@{ Feld = $_.Feld; Anzahl = $_.Anzahl; Jetzt = $_.Jetzt; Danach = $_.Danach; JetztVoll = $_.JetztVoll; DanachVoll = $_.DanachVoll; Gekuerzt = [bool]$_.Gekuerzt; Status = $(if ($_.Gekuerzt) { 'ansehen' } else { '' }) } })
    $c.gridChanges.ItemsSource = $rows
    $add = {
        param([string]$Text, [string]$Color, [switch]$Bold)
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.Margin = '0,2,0,2'; $t.FontSize = 12
        $t.Foreground = Get-HUBrush $Color
        if ($Bold) { $t.FontWeight = 'SemiBold' }
        [void]$c.pnlInfo.Children.Add($t)
    }
    if ($Plan.Blocks.Count) { & $add 'GESPERRT - es wird gar nichts geschrieben, auch keine der anderen Zeilen:' '#EF5350' -Bold }
    foreach ($b in $Plan.Blocks) { & $add "- $b" '#EF5350' }
    if (@($rows | Where-Object { $_.Gekuerzt }).Count) { & $add 'Gekuerzte Werte (Spalte Voll = ansehen): Zeile markieren, der volle Wert klappt unten auf. Schreiben geht erst, wenn alle angesehen sind.' '#FFB74D' }
    if ($Plan.BreakGlass -and $Plan.BreakGlass.PSObject.Properties['Ok'] -and $Plan.BreakGlass.Ok) { & $add "Notfallkonten: $($Plan.BreakGlass.Text)" '#81C784' }
    foreach ($wn in $Plan.Warnings) { & $add "Achtung: $wn" '#FFB74D' }
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($cf in $Plan.Confirms) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "Verstanden: $cf"; $cb.Foreground = Get-HUBrush '#FF8A65'; $cb.Margin = '0,3,0,3'; $cb.FontSize = 12
        try { $cb.Style = $w.FindResource('DarkCheckBox') } catch { }
        $cb.ToolTip = 'Vor dem Zurueckschreiben bewusst bestaetigen'
        $checks.Add($cb); [void]$c.pnlInfo.Children.Add($cb)
    }
    # 059 B2: Hinweis, wenn eine gewaehlte Gruppe nichts aendert (Haken 'Alle') oder zugleich zugewiesen und ausgenommen ist
    $allOps = @($(if ($Plan.PSObject.Properties['Options']) { $Plan.Options }) | Where-Object { $_ })
    $grpHint = New-Object System.Windows.Controls.TextBlock
    $grpHint.TextWrapping = 'Wrap'; $grpHint.Margin = '0,2,0,2'; $grpHint.FontSize = 12; $grpHint.Foreground = Get-HUBrush '#FFB74D'; $grpHint.Visibility = 'Collapsed'
    $grpUpd = {
        $gi = @($allOps | Where-Object { "$($_.Kind)" -eq 'group' -and "$($_.Feld)" -eq 'includeGroups' -and "$($_.Value)" })
        $ge = @($allOps | Where-Object { "$($_.Kind)" -eq 'group' -and "$($_.Feld)" -eq 'excludeGroups' -and "$($_.Value)" })
        $msg = New-Object System.Collections.Generic.List[string]
        if ($gi.Count -and @($allOps | Where-Object { "$($_.Key)" -eq 'allUsers' -and [bool]$_.Value }).Count) { $msg.Add("Benutzer 'Alle' ist angehakt - die gewaehlte Gruppe aendert daran nichts.") }
        $both = @($gi | Where-Object { @($ge | ForEach-Object { "$($_.Value)" }) -contains "$($_.Value)" })
        if ($both.Count) { $msg.Add("Dieselbe Gruppe ist zugleich zugewiesen und ausgenommen ('$(@($both | ForEach-Object Slot) -join "', '")') - die Ausnahme gewinnt, die Richtlinie gilt fuer diese Gruppe nicht.") }
        $grpHint.Text = "Achtung: $($msg -join ' ')"
        $grpHint.Visibility = $(if ($msg.Count) { 'Visible' } else { 'Collapsed' })
    }
    # 2.4.5 waehlbare Uebernahmen (z. B. Rollen, 'Alle Benutzer'): Haken = uebernehmen
    foreach ($op in @($(if ($Plan.PSObject.Properties['Options']) { $Plan.Options }) | Where-Object { $_ })) {
        if ($op.PSObject.Properties['Kind'] -and "$($op.Kind)" -eq 'group') {
            # 2.5.1 Gruppen-Platz: Gruppe des Ziels waehlen (Tippen springt zum Namen), leer = nicht zuweisen
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'; $sp.Margin = '0,3,0,3'
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$($op.Text)"; $tb.Foreground = Get-HUBrush '#90CAF9'; $tb.FontSize = 12; $tb.VerticalAlignment = 'Center'; $tb.Margin = '0,0,8,0'; $tb.MinWidth = 260
            $cb2 = New-Object System.Windows.Controls.ComboBox
            try { $cb2.Style = $w.FindResource('DarkComboBox') } catch { }
            $cb2.MinWidth = 320; $cb2.FontSize = 12; $cb2.IsTextSearchEnabled = $true
            # ComboBoxItem mit Text als Inhalt und Kennung im Tag (PSCustomObject + DisplayMemberPath zeigt '@{Id=...}' - Test 25.10.)
            $mkItem = { param([string]$Id, [string]$Name) $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = $Name; $ci.Tag = $Id; try { $ci.Style = $w.FindResource('DarkComboBoxItem') } catch { }; $ci }
            [void]$cb2.Items.Add((& $mkItem '' '(nicht zuweisen)'))
            $sel = 0; $ix = 0
            foreach ($ch in @($op.Choices)) {
                if (-not $ch) { continue }
                $ix++
                [void]$cb2.Items.Add((& $mkItem "$($ch.Id)" "$($ch.Name)"))
                if ("$($op.Value)" -and "$($ch.Id)" -eq "$($op.Value)") { $sel = $ix }
            }
            $cb2.SelectedIndex = $sel
            $cb2.Tag = $op
            $cb2.ToolTip = "Platz '$($op.Slot)': Gruppe im Ziel, die die Richtlinie $(if ("$($op.Feld)" -eq 'includeGroups') { 'erhaelt' } else { 'ausnimmt' }). Gleichnamige Gruppe ist vorgewaehlt."
            $cb2.Add_SelectionChanged({ $it = $this.SelectedItem; $this.Tag.Value = $(if ($it) { "$($it.Tag)" } else { '' }); & $grpUpd })
            [void]$sp.Children.Add($tb); [void]$sp.Children.Add($cb2)
            [void]$c.pnlInfo.Children.Add($sp)
            continue
        }
        $ob = New-Object System.Windows.Controls.CheckBox
        $ob.Content = "$($op.Text)"; $ob.IsChecked = [bool]$op.Value; $ob.Foreground = Get-HUBrush '#90CAF9'; $ob.Margin = '0,3,0,3'; $ob.FontSize = 12
        try { $ob.Style = $w.FindResource('DarkCheckBox') } catch { }
        $ob.Tag = $op
        $ob.Add_Checked({ $this.Tag.Value = $true; & $grpUpd }); $ob.Add_Unchecked({ $this.Tag.Value = $false; & $grpUpd })
        [void]$c.pnlInfo.Children.Add($ob)
    }
    if (@($allOps | Where-Object { "$($_.Kind)" -eq 'group' }).Count) { [void]$c.pnlInfo.Children.Add($grpHint); & $grpUpd }
    if ($Plan.Dropped.Count) { & $add "Wird nicht geschrieben (nicht beschreibbar oder bewusst ausgelassen): $($Plan.Dropped -join ', ')" '#AAAAAA' }
    foreach ($n in $Plan.Notes) { & $add "Hinweis: $n" '#90CAF9' }
    $state = @{ Ok = $false; Skip = $false }
    $script:ErPreviewChoice = 'cancel'
    if ($Remaining -gt 0) {
        $c.btnSkip.Visibility = 'Visible'
        $c.btnCancel.ToolTip = "Uebertragen ganz beenden - auch die $Remaining weiteren Ziele werden nicht mehr vorbereitet"
        $c.btnSkip.Add_Click({ $state.Skip = $true; $w.Close() })
    }
    # 045 Ue-10: bei mehreren Zielen den Ziel-Tenant-Namen eintippen
    $typeName = if ($Plan.PSObject.Properties['TypeToConfirm']) { "$($Plan.TypeToConfirm)" } else { '' }
    if ($typeName) { $c.pnlType.Visibility = 'Visible'; $c.lblType.Text = "Zum Bestaetigen '$typeName' eintippen:" }
    # 2.5.1: angesehen je Zeilennummer merken (nicht nur am Zeilenobjekt - Test 25.10.: Knopf blieb trotz angesehener Zeile grau)
    $seen = @{}
    $unseen = { @(for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Gekuerzt -and -not $seen.ContainsKey($i)) { $i } }).Count }
    $upd = { $c.btnWrite.IsEnabled = [bool]((-not $Plan.Blocks.Count) -and $Plan.Changes.Count -and -not @($checks | Where-Object { -not $_.IsChecked }).Count -and -not (& $unseen) -and (-not $typeName -or "$($c.txtType.Text)".Trim() -eq $typeName)) }
    foreach ($cb in $checks) { $cb.Add_Checked($upd); $cb.Add_Unchecked($upd) }
    $c.txtType.Add_TextChanged($upd)
    $c.gridChanges.Add_SelectionChanged({
            $ri = $c.gridChanges.SelectedIndex
            if ($ri -lt 0 -or $ri -ge $rows.Count) { return }
            $r = $rows[$ri]
            $c.txtFullNow.Text = "Jetzt im Tenant:`r`n$($r.JetztVoll)"
            $c.txtFullThen.Text = "Danach (wird geschrieben):`r`n$($r.DanachVoll)"
            $c.expFull.IsExpanded = $true
            $wasNew = $r.Gekuerzt -and -not $seen.ContainsKey($ri)
            if ($r.Gekuerzt) { $seen[$ri] = $true; $r.Status = 'gesehen' }
            & $upd
            # Anzeige 'gesehen' erst nach dem Auswahl-Ereignis auffrischen (Refresh mitten im Ereignis kann scheitern)
            if ($wasNew) { $gc = $c.gridChanges; [void]$w.Dispatcher.BeginInvoke([action]({ try { $gc.Items.Refresh() } catch { } }.GetNewClosure())) }
        })
    & $upd
    # nur eine Zeile: gleich markieren, damit der volle Wert sofort zu sehen ist
    if ($rows.Count -eq 1 -and -not $rows[0].Gekuerzt) { $c.gridChanges.SelectedIndex = 0 }
    $c.btnWrite.Add_Click({
            $q = if ($isEt) { "'$($Plan.Name)' jetzt aus dem Muster nach $TenantName uebertragen ($($Plan.Changes.Count) Feld(er), $(if ($Plan.Method -eq 'POST') { 'neu anlegen' } else { 'aendern' }))?" } elseif ($isAl) { "'$($Plan.Name)' jetzt in $TenantName an die Quelle ANGLEICHEN ($(@($Plan.Changes | Where-Object { $null -ne $_.Expected }).Count) Feld(er))?" } elseif ($isTr) { "'$($Plan.NewName)' jetzt in $TenantName NEU anlegen (ohne Zuweisungen)?" } elseif ($Plan.Method -eq 'POST') { "'$($Plan.Body.displayName)' jetzt in $TenantName NEU anlegen ($(if ($Plan.Body.state -eq 'disabled') { 'ausgeschaltet' } else { 'Nur Bericht' }))?" } else { "Jetzt $($Plan.Changes.Count) Feld(er) von '$($Plan.Name)' in $TenantName zurueckschreiben?" }
            if (-not (Confirm-HU $q -Warning -Owner $w)) { return }
            $state.Ok = $true; $w.Close()
        })
    # alle Spalten nach Inhalt; Fenster so breit wie die Spalten (mind. 880, hoechstens 95 % des Bildschirms)
    $w.Add_ContentRendered({
            try {
                $sum = 0; foreach ($col in @($c.gridChanges.Columns)) { $sum += $col.ActualWidth }
                $wa = [System.Windows.SystemParameters]::WorkArea
                $nw = [Math]::Max(880, [Math]::Min([Math]::Floor($wa.Width * 0.95), ($sum + 70) * (Get-HUUiScaleValue)))
                if ($nw -gt $w.ActualWidth) { $w.Width = $nw; $w.Left = $wa.Left + [Math]::Max(0, ($wa.Width - $nw) / 2) }
            } catch { }
        })
    [void]$w.ShowDialog()
    $script:ErPreviewChoice = $(if ($state.Ok) { 'write' } elseif ($state.Skip) { 'skip' } else { 'cancel' })
    return [bool]$state.Ok
}

# Ablauf fuer genau einen markierten Eintrag
function Start-HUEntraRestore($Row) {
    $c = $script:Controls
    $k = $script:BakTenant
    $stamp = try { [datetime]::ParseExact((Split-Path $script:BakA -Leaf), 'yyyy-MM-dd_HHmmss', $null).ToString('dd.MM.yyyy HH:mm') } catch { "$(Split-Path $script:BakA -Leaf)" }
    $tn = Get-HUAnaTenantName $k
    $backup = $null
    try { $backup = Read-HUBackupJson $Row.FileA } catch { Show-HUMessage "Backup-Datei nicht lesbar: $($_.Exception.Message)" -Icon Error; return }
    $bix = $null
    try { $bix = Read-HUBackupJson (Join-Path $script:BakA 'index.json') } catch { Show-HUMessage "index.json des Backup-Stands nicht lesbar - ohne sie wird nicht zurueckgeschrieben: $($_.Exception.Message)" -Icon Error; return }
    Add-HURtbLine $c['rtbAna'] "Lese $($Row.Typ) '$($Row.Name)' in $tn fuer die Vorschau ..." '#90CAF9'
    $script:EntraRestoreCtx = @{ Tenant = $tn; Stamp = $stamp }
    # Conditional Access wird neu angelegt: Name mit Zusatz wie beim Wiederherstellen von Intune-Eintraegen
    $newName = if ((Get-HUEntraRestoreKind "$($Row.Typ)" "$($Row.Id)") -eq 'caNew') { "$($Row.Name) (wiederhergestellt $((Split-Path $script:BakA -Leaf).Substring(0, 10)))" } else { '' }
    [void](Start-HUJob -Name 'EntraRestorePlan' -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; Typ = "$($Row.Typ)"; Id = "$($Row.Id)"; Nm = "$($Row.Name)"; Bk = $backup; Bix = $bix; NN = $newName } -Code {
            try { [pscustomobject]@{ __Plan = (Get-HUEntraRestorePlan -TenantKey $TK -Settings $Settings -Typ $Typ -Id $Id -Name $Nm -Backup $Bk -BackupIndex $Bix -NewName $NN) } }
            catch { [pscustomobject]@{ __PlanError = $(if (Test-HUGraphForbidden $_) { "Leserecht fehlt ($($_.Exception.Message))" } else { "$($_.Exception.Message)" }) } }
        } -OnDone {
            param($Result, $Errors)
            $r = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__Plan'] -or $_.PSObject.Properties['__PlanError']) }) | Select-Object -First 1
            if (-not $r) { Show-HUMessage 'Vorschau fehlgeschlagen (siehe Protokoll).' -Icon Error; return }
            if ($r.PSObject.Properties['__PlanError']) { Show-HUMessage "Vorschau fehlgeschlagen: $($r.__PlanError)" -Icon Error; return }
            $plan = $r.__Plan
            $ctx = $script:EntraRestoreCtx
            if (-not $plan.Changes.Count -and -not $plan.Blocks.Count) { Show-HUMessage "$($plan.Typ) '$($plan.Name)': Der Tenant entspricht schon dem Stand $($ctx.Stamp) - nichts zu schreiben.$(if ($plan.Dropped.Count) { "`n`nNicht verglichen (nicht beschreibbar): $($plan.Dropped -join ', ')" })" -Icon Info; return }
            if (-not (Show-HUEntraRestorePreview $plan $ctx.Tenant $ctx.Stamp)) { Add-HURtbLine $script:Controls['rtbAna'] 'Zurueckschreiben abgebrochen.' '#AAAAAA'; return }
            [void](Start-HUJob -Name 'EntraRestoreWrite' -Output $script:Controls['rtbAna'] -Vars @{ Plan = $plan } -Code {
                    try { [pscustomobject]@{ __Res = (Invoke-HUEntraRestore -Plan $Plan -Settings $Settings) } }
                    catch { Write-HULog -Message "$($Plan.Typ) '$($Plan.Name)': $($_.Exception.Message)" -Level 'ERROR' -Tenant $Plan.TenantKey; [pscustomobject]@{ __ResError = "$($_.Exception.Message)" } }
                } -OnDone {
                    param($Result, $Errors)
                    $r2 = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__Res'] -or $_.PSObject.Properties['__ResError']) }) | Select-Object -First 1
                    if (-not $r2) { Show-HUMessage 'Zurueckschreiben: kein Ergebnis (siehe Protokoll).' -Icon Error; return }
                    if ($r2.PSObject.Properties['__ResError']) { Show-HUMessage "Nicht zurueckgeschrieben:`n`n$($r2.__ResError)" -Icon Error; return }
                    $res = $r2.__Res
                    $txt = if ($res.PSObject.Properties['NewId'] -and $res.NewId) { "Neu angelegt als 'Nur Bericht' (Id $($res.NewId)). Die bestehende Richtlinie ist unveraendert." } else { "$($res.Written) Feld(er) geschrieben. Stand vorher gesichert:`n$($res.BackupFile)" }
                    if ($res.Mismatch.Count) { $txt += "`n`nNachpruefung - abweichend gelesen:`n$($res.Mismatch -join "`n")" } else { $txt += "`n`nNachpruefung: alle geschriebenen Felder stimmen." }
                    if ($res.Notes.Count) { $txt += "`n`n$($res.Notes -join "`n")" }
                    Show-HUMessage $txt -Icon $(if ($res.Ok) { 'Info' } else { 'Warning' })
                })
        })
}
