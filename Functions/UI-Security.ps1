# ============================================================================
# Analyse > Sicherheit (Sicherheitskatalog, nur lesend)
# Logik liegt in Core\HU.SecCatalog.psm1, hier nur Anzeige und Bedienung.
# ============================================================================
$script:SecKeys = @()
$script:SecData = @{}
$script:SecWait = @{}
$script:SecGen = 0
$script:SecResults = @()
$script:SecMatrix = @()
$script:SecRan = $false

function Get-HUSecCellText($Cell) {
    if (-not $Cell) { return "$([char]0x2014)" }
    $why = switch ("$($Cell.Reason)") { 'Recht' { 'Recht' } 'Lizenz' { 'Lizenz' } 'Technisch' { 'Technik' } 'Manuell' { 'Manuell' } 'NichtAnwendbar' { 'n/a' } default { '' } }
    switch ("$($Cell.Status)") {
        'OK' { return "$([char]0x2714)" }
        'Abweichung' { return $(if ([int]"0$($Cell.Count)" -gt 0) { "$([char]0x2716) $($Cell.Count)" } else { "$([char]0x2716)" }) }
        'Ausnahme' { return "$([char]0x25D0)" }
        'NichtPruefbar' { return "? $why".Trim() }
        'Fehler' { return "$([char]0x26A0)" }
        'Info' { if ("$($Cell.Reason)" -eq 'Aus') { return 'aus' }; if ("$($Cell.Reason)" -eq 'Handgeprueft') { return "$([char]0x2714) Hand" }; if ("$($Cell.Detail)" -match '\(([0-9.,]+ %)\)\s*$') { return $Matches[1] }; return 'i' }
        default { return "$($Cell.Status)" }
    }
}

# Farbe des Zeichens je Status (Schalter "Farben"; aus = normale Schrift)
function Get-HUSecCellColor($Cell) {
    $def = '#CCCCCC'
    if (-not $Cell -or -not $script:Controls['chkSecColor'] -or -not $script:Controls['chkSecColor'].IsChecked) { return $def }
    switch ("$($Cell.Status)") {
        'OK' { return '#81C784' }
        'Abweichung' { return '#EF5350' }
        'Fehler' { return '#EF5350' }
        'Ausnahme' { return '#FFB74D' }
        'NichtPruefbar' { if ("$($Cell.Reason)" -eq 'Manuell' -and (Test-HUSecManualRule "$($Cell.RuleId)")) { return '#FFB74D' }; return '#8A8A8A' }
        'Info' { if ("$($Cell.Reason)" -eq 'Aus') { return '#8A8A8A' }; if ("$($Cell.Reason)" -eq 'Handgeprueft') { return '#A5D6A7' }; return $def }
        default { return $def }
    }
}

# Gewaehlter Filterwert (Tag) einer Auswahlbox; leer = alle
function Get-HUSecComboTag([string]$Name) {
    $cb = $script:Controls[$Name]
    if ($cb -and $cb.SelectedItem) { return "$($cb.SelectedItem.Tag)" }
    return ''
}

# Bereiche und Grade (Mehrfachauswahl per Haken in einer aufklappenden Liste): ausgeblendete Werte
$script:HUSecPick = @{ Area = @{ All = 'Alle Bereiche'; None = 'Kein Bereich'; Many = 'Bereiche'; State = 'secAreaOff' }; Sev = @{ All = 'Alle Grade'; None = 'Kein Grad'; Many = 'Grade'; State = 'secSevOff' } }
function Get-HUSecPickOff([string]$Kind) {
    $sp = $script:Controls["spSec$Kind"]
    if (-not $sp) { return @() }
    return @($sp.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and -not $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
}
function Get-HUSecAreasOff { return @(Get-HUSecPickOff 'Area') }

function Update-HUSecPickButton([string]$Kind) {
    $p = $script:HUSecPick[$Kind]
    $all = @($script:Controls["spSec$Kind"].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
    $on = @($all | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
    $txt = if ($on.Count -eq $all.Count) { $p.All } elseif (-not $on.Count) { $p.None } elseif ($on.Count -eq 1) { $on[0] } elseif ($all.Count - $on.Count -eq 1) { "ohne $(@($all | Where-Object { -not $_.IsChecked })[0].Tag)" } else { "$($on.Count) $($p.Many)" }
    $script:Controls["btnSec$Kind"].Content = "$txt $([char]0x25BE)"
}

# Liste mit Haken aufbauen (gespeichert werden die ausgeblendeten Werte), dazu "alle"
function Initialize-HUSecPick([string]$Kind, [string[]]$Values) {
    $c = $script:Controls; $p = $script:HUSecPick[$Kind]
    $off = @("$(Get-HUStateValue $p.State '')" -split ',' | Where-Object { $_ })
    $fg = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CCCCCC')
    foreach ($v in $Values) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $v; $cb.IsChecked = ($off -notcontains $v); $cb.Foreground = $fg; $cb.FontSize = 12; $cb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
        $cb.Tag = $v; $cb.Uid = $Kind
        $cb.Add_Click({ $k = $this.Uid; Set-HUStateValue $script:HUSecPick[$k].State (@(Get-HUSecPickOff $k) -join ','); Update-HUSecPickButton $k; Update-HUSecGrid })
        [void]$c["spSec$Kind"].Children.Add($cb)
    }
    $lnk = New-Object System.Windows.Controls.Button
    $lnk.Content = 'alle'; $lnk.Uid = $Kind; $lnk.FontSize = 11; $lnk.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0); $lnk.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left; $lnk.Padding = [System.Windows.Thickness]::new(8, 1, 8, 1)
    try { $lnk.Style = $script:Window.FindResource('DarkButton'); $lnk.Background = ([System.Windows.Media.BrushConverter]::new().ConvertFromString('#3E3E42')) } catch { }
    $lnk.Add_Click({ $k = $this.Uid; foreach ($x in @($script:Controls["spSec$k"].Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })) { $x.IsChecked = $true }; Set-HUStateValue $script:HUSecPick[$k].State ''; Update-HUSecPickButton $k; Update-HUSecGrid })
    [void]$c["spSec$Kind"].Children.Add($lnk)
    Update-HUSecPickButton $Kind
    # Klick auf den Knopf bei offener Liste: das Popup schliesst schon beim Druecken - nicht gleich wieder oeffnen
    $script:HUSecPick[$Kind].Closed = [datetime]::MinValue
    $c["popSec$Kind"].Uid = $Kind
    $c["popSec$Kind"].Add_Closed({ $script:HUSecPick[$this.Uid].Closed = [datetime]::Now })
    $c["btnSec$Kind"].Uid = $Kind
    $c["btnSec$Kind"].Add_Click({ $k = $this.Uid; if (([datetime]::Now - $script:HUSecPick[$k].Closed).TotalMilliseconds -gt 300) { $script:Controls["popSec$k"].IsOpen = $true } })
}

function Get-HUSecVisibleRows {
    # -NoStatusFilter: nur Grad, Bereich und Suchtext (fuer die Ampel - "Nur Abweichungen" wuerde sie verfaelschen)
    param([switch]$NoStatusFilter)
    $rows = @($script:SecMatrix)
    if (-not $NoStatusFilter -and $script:Controls['chkSecDev'].IsChecked) { $rows = @($rows | Where-Object { $_.Dev }) }
    if (-not $NoStatusFilter -and $script:Controls['chkSecDiff'].IsChecked) { $rows = @($rows | Where-Object { $_.Diff }) }
    $offArea = @(Get-HUSecAreasOff)
    if ($offArea.Count) { $rows = @($rows | Where-Object { $offArea -notcontains "$($_.Area)" }) }
    $offSev = @(Get-HUSecPickOff 'Sev')
    if ($offSev.Count) { $rows = @($rows | Where-Object { $offSev -notcontains "$($_.Sev)" }) }
    foreach ($w in @("$($script:Controls['txtSecFilter'].Text)" -split '\s+' | Where-Object { $_ })) {
        $rows = @($rows | Where-Object { ("$($_.RuleId) $($_.Area) $($_.Title) $($_.Sev)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @($rows)
}

function Update-HUSecHint {
    $c = $script:Controls
    $wait = @($script:SecWait.Keys)
    Set-HUAnaRunDot ($wait.Count -gt 0)
    if ($wait.Count) { $c['lblAnaHint'].Text = "Pruefe ... warte auf $(@($wait | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')"; return }
    if (-not $script:SecRan) {
        $c['lblAnaHint'].Text = 'Tenants anhaken und Pruefen klicken. Es wird nur gelesen. Nicht pruefbar ist nie gruen: fehlende Rechte, Lizenz oder Technik werden als "?" mit Grund angezeigt.'
        return
    }
    $all = @($script:SecMatrix)
    $dev = @($all | Where-Object Dev).Count
    $vis = @(Get-HUSecVisibleRows).Count
    $cov = @($script:SecKeys | ForEach-Object { $cv = Get-HUSecCoverage -Results $script:SecResults -Key $_; "$(Get-HUAnaTenantName $_) $($cv.Checked)/$($cv.Total)" }) -join ', '
    $c['lblAnaHint'].Text = "$($all.Count) Regeln, $dev mit Abweichung$(if ($vis -ne $all.Count) { ", $vis angezeigt" }). Geprueft: $cov. Zeichen: $([char]0x2714) ok, $([char]0x2716) Abweichung (Zahl = Anzahl), $([char]0x25D0) Ausnahme, ? nicht pruefbar (Grund dahinter), $([char]0x26A0) Fehler, i Info. Doppelklick = Details."
}

function Update-HUSecGrid {
    $c = $script:Controls
    $g = $c['gridSec']
    $keys = @($script:SecKeys)
    $g.Columns.Clear()
    $add = { param($h, $b, $w, $sp = '') $col = New-Object System.Windows.Controls.DataGridTextColumn; $col.Header = $h; $col.Binding = New-Object System.Windows.Data.Binding($b); $col.Width = $w; if ($sp) { $col.SortMemberPath = $sp }; [void]$g.Columns.Add($col) }
    $cells = [System.Windows.Controls.DataGridLengthUnitType]::Auto
    # Abstand rechts im Text, damit die naechste Spalte nicht gleich nach dem Inhalt beginnt
    $pad = { param($m) $st = New-Object System.Windows.Style([System.Windows.Controls.TextBlock]); [void]$st.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.TextBlock]::MarginProperty, (New-Object System.Windows.Thickness(0, 0, $m, 0))))); $g.Columns[$g.Columns.Count - 1].ElementStyle = $st }
    & $add 'Grad' 'Sev' (New-Object System.Windows.Controls.DataGridLength(1, $cells)) 'SevRank'
    & $pad 16
    & $add 'Bereich' 'Area' (New-Object System.Windows.Controls.DataGridLength(1, $cells))
    & $pad 16
    & $add 'Nr' 'Nr' (New-Object System.Windows.Controls.DataGridLength(1, $cells))
    & $pad 16
    & $add $(if (@($script:SecMatrix).Count) { "Regel ($(@(Get-HUSecVisibleRows).Count))" } else { 'Regel' }) 'Rule' (New-Object System.Windows.Controls.DataGridLength(1, $cells))
    & $pad 28
    # Tenant-Spalten: Text wie bisher, in der letzten Zeile (Ampel) zusaetzlich ein farbiger Punkt
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $tpl = [System.Windows.Markup.XamlReader]::Parse("<DataTemplate xmlns=`'http://schemas.microsoft.com/winfx/2006/xaml/presentation`'><StackPanel Orientation=`'Horizontal`'><Ellipse Width=`'9`' Height=`'9`' Margin=`'0,0,6,0`' VerticalAlignment=`'Center`' Fill=`'{Binding Lc$i}`' Visibility=`'{Binding Lv$i}`'/><TextBlock Text=`'{Binding T$i}`' Foreground=`'{Binding Fc$i}`' VerticalAlignment=`'Center`'/></StackPanel></DataTemplate>")
        $col = New-Object System.Windows.Controls.DataGridTemplateColumn
        $col.Header = Get-HUAnaTenantName $keys[$i]; $col.CellTemplate = $tpl; $col.SortMemberPath = "T$i"; $col.MinWidth = 120
        $col.Width = New-Object System.Windows.Controls.DataGridLength(1, $cells)
        [void]$g.Columns.Add($col)
    }
    $items = foreach ($m in @(Get-HUSecVisibleRows)) {
        $o = [ordered]@{ Sev = $m.Sev; SevRank = [int]@{ Kritisch = 0; Hoch = 1; Mittel = 2; Niedrig = 3 }["$($m.Sev)"]; Area = $m.Area; Nr = "$($m.RuleId)"; Rule = "$($m.Title)" }
        for ($i = 0; $i -lt $keys.Count; $i++) { $o["T$i"] = Get-HUSecCellText $m.Cells[$keys[$i]]; $o["Fc$i"] = Get-HUSecCellColor $m.Cells[$keys[$i]] }
        for ($i = 0; $i -lt $keys.Count; $i++) { $o["Lc$i"] = '#000000'; $o["Lv$i"] = 'Collapsed' }
        $o.Ref = $m
        [pscustomobject]$o
    }
    $items = @($items)
    # letzte Zeile: Ampel je Tenant in derselben Spalte (rot = ab 10 nicht erfuellte Regeln, gelb = 1 bis 9, gruen = keine)
    if ($script:SecRan -and $keys.Count) {
        $col = @{ Rot = '#EF5350'; Gelb = '#FFB74D'; Gruen = '#66BB6A'; Grau = '#757575' }
        # Ampel folgt der Auswahl (Grad, Bereich, Suchtext); "Nur Abweichungen/Unterschiede" zaehlt nicht als Auswahl
        $selIds = @(Get-HUSecVisibleRows -NoStatusFilter | ForEach-Object { "$($_.RuleId)" })
        $part = ($selIds.Count -lt @($script:SecMatrix).Count)
        $f = [ordered]@{ Sev = ''; SevRank = 9; Area = ''; Nr = ''; Rule = $(if ($part) { "Ampel (nur Auswahl: $($selIds.Count) Regeln)" } else { 'Ampel' }) }
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $rows = $script:SecData["$($keys[$i])"]
            $had = [bool]$rows
            if ($rows -and $part) { $rows = @(@($rows) | Where-Object { $selIds -contains "$($_.RuleId)" }) }
            if ($had -and -not @($rows).Count) { $f["T$i"] = '-'; $f["Lc$i"] = $col['Grau'] }
            elseif ($rows) { $l = Get-HUSecLight -Results @($rows) -Key $keys[$i]; $f["T$i"] = "$($l.Ok) von $($l.Checked)"; $f["Lc$i"] = $col[$l.Color] }
            else { $f["T$i"] = '...'; $f["Lc$i"] = $col['Grau'] }
            $f["Lv$i"] = 'Visible'; $f["Fc$i"] = '#CCCCCC'
        }
        $f.Ref = $null
        $items += [pscustomobject]$f
    }
    $g.ItemsSource = @($items)
    Update-HUSecHint
}

# Vor dem ersten Pruefen: Regelliste schon zeigen (leere Zellen) - fuer die angehakten Tenants
function Show-HUSecPreview {
    if ($script:SecRan) { return }
    $script:SecKeys = @(Get-HUCheckedTenants $script:Controls['spAnaTenants'])
    $script:SecMatrix = @(Get-HUSecMatrix -Results @() -Keys $script:SecKeys)
    Update-HUSecGrid
}

function Start-HUSecRun {
    $c = $script:Controls
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'])
    if (-not $keys.Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning; return }
    $script:SecGen++
    $gen = $script:SecGen
    $script:SecKeys = $keys
    $script:SecData = @{}
    $script:SecWait = @{}
    $script:SecResults = @()
    $script:SecRan = $true
    $script:SecMatrix = @(Get-HUSecMatrix -Results @() -Keys $keys)
    Update-HUSecGrid
    $c['rtbAna'].Document.Blocks.Clear()
    Add-HURtbLine $c['rtbAna'] "Sicherheitskatalog (nur lesend): $(@($keys | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" '#90CAF9'
    foreach ($k in $keys) {
        $script:SecWait[$k] = $true
        $ok = Start-HUJob -Name "Sec-$gen-$k" -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; Gen = $gen } -Code {
            $rows = @()
            try { $rows = @(Invoke-HUSecCatalog -TenantKey $TK -Settings $Settings) }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $TK }
            [pscustomobject]@{ __SecDone = $TK; __SecGen = $Gen; Rows = $rows }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__SecDone'] }) | Select-Object -First 1
            if (-not $d -or [int]$d.__SecGen -ne $script:SecGen) { return }
            $script:SecWait.Remove("$($d.__SecDone)")
            $script:SecData["$($d.__SecDone)"] = @($d.Rows)
            if (-not @($d.Rows).Count) { Add-HURtbLine $script:Controls['rtbAna'] "$(Get-HUAnaTenantName "$($d.__SecDone)"): keine Ergebnisse (Fehler siehe Log)" '#FFB74D' }
            if (-not $script:SecWait.Count) {
                $script:SecResults = @($script:SecData.Values | ForEach-Object { $_ })
                $script:SecMatrix = @(Get-HUSecMatrix -Results $script:SecResults -Keys $script:SecKeys)
                try { [void](Save-HUSecSnapshot -Results $script:SecResults) } catch { Write-HULog -Message "Verlauf nicht gespeichert: $($_.Exception.Message)" -Level 'WARN' }
                Update-HUSecGrid
            } else { Update-HUSecGrid }
        }
        if (-not $ok) { $script:SecWait.Remove($k) }
    }
    Update-HUSecHint
}

function Get-HUSecStatusText($Cell) {
    if (-not $Cell) { return 'kein Ergebnis' }
    $sym = Get-HUSecCellText $Cell
    $word = switch ("$($Cell.Status)") { 'NichtPruefbar' { 'nicht pruefbar' } default { "$($Cell.Status)" } }
    $why = if ("$($Cell.Reason)") { " ($($Cell.Reason))" } else { '' }
    return "$($sym.Split(' ')[0]) $word$why"
}

# Ladeanzeige fuer das Detailfenster: Knopf "Lade ...", Sanduhr, gruener Punkt im Hauptfenster
function Set-HUSecBusy([bool]$On) {
    $b = $script:SecBusy
    try {
        if ($On) {
            if ($b.Btn) { $b.Btn.IsEnabled = $false; $b.Btn.Content = 'Lade ...' }
            if ($b.Win) { $b.Win.Cursor = [System.Windows.Input.Cursors]::Wait }
        } else {
            if ($b.Btn) { $b.Btn.IsEnabled = $true; $b.Btn.Content = "$($b.Label)" }
            if ($b.Win) { $b.Win.Cursor = $null }
        }
    } catch { }
    try { Set-HUAnaRunDot ($On -or ($script:SecWait -and $script:SecWait.Count -gt 0)) } catch { }
}

function Start-HUSecItems {
    param([string]$Key, [string]$RuleId, [string]$Title, $Window = $null, $Button = $null)
    $script:SecBusy = @{ Win = $Window; Btn = $Button; Label = $(if ($Button) { "$($Button.Content)" } else { '' }) }
    Set-HUSecBusy $true
    $script:SecItemsTitle = "$Title - $(Get-HUAnaTenantName $Key)"
    $script:SecItemsLabel = Get-HUSecItemsLabel $RuleId
    $script:SecItemsExport = Test-HUSecItemsExport $RuleId
    Add-HURtbLine $script:Controls['rtbAna'] "Lade $($script:SecItemsLabel): $(Get-HUAnaTenantName $Key) ($RuleId) ..." '#90CAF9'
    $started = Start-HUJob -Name "SecItems-$RuleId-$Key" -Quiet -Output $script:Controls['rtbAna'] -Vars @{ TK = $Key; RID = $RuleId } -Code {
            $rows = @(); $err = ''
            try { $rows = @(Get-HUSecItems -TenantKey $TK -Settings $Settings -RuleId $RID) }
            catch { $err = "$($_.Exception.Message)"; Write-HULog -Message $err -Level 'ERROR' -Tenant $TK }
            [pscustomobject]@{ __SecItems = $true; Rows = $rows; Err = $err }
        } -OnDone {
            param($Result, $Errors)
            Set-HUSecBusy $false
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__SecItems'] }) | Select-Object -First 1
            if (-not $d) { Show-HUMessage "$($script:SecItemsLabel): keine Antwort erhalten (siehe Log)." -Icon Warning; return }
            if ($d.Err) { Show-HUMessage "$($script:SecItemsLabel) konnten nicht gelesen werden: $($d.Err)" -Icon Warning; return }
            if (-not @($d.Rows).Count) { Show-HUMessage "Keine betroffenen $($script:SecItemsLabel)." -Icon Info; return }
            Add-HURtbLine $script:Controls['rtbAna'] "$(@($d.Rows).Count) Eintraege$(if ($script:SecItemsExport) { ' (ohne Personendaten, Speichern moeglich)' } else { ' (nur Anzeige, nicht gespeichert)' })" '#81C784'
            Show-HUQSTable -Title $script:SecItemsTitle -Objects @($d.Rows) -FilePrefix 'Katalog-Liste' -NoExport:(-not $script:SecItemsExport)
        }
    if (-not $started) { Set-HUSecBusy $false }
}

# Sollwerte bearbeiten (Datei baseline.json im Katalog-Ordner): Ebene "Alle Tenants" oder ein Tenant; leeres Feld = Wert entfernen
function Show-HUSecBaseline {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sollwerte - Sicherheitskatalog" Width="1100" Height="560" MinWidth="760" MinHeight="380" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="Gilt fuer" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox x:Name="cmbScope" Width="240" Style="{StaticResource DarkComboBox}"/>
        </StackPanel>
        <TextBlock DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="In der Spalte Wert eintragen (einfach hineinklicken). Leer = kein eigener Wert: dann gilt der Wert fuer alle Tenants bzw. der Standard. Objekt-IDs mit Komma trennen (Entra Admin Center > Benutzer bzw. Gruppen > Objekt-ID). Gespeichert wird lokal in deinem Profil; beim naechsten Pruefen gilt der neue Wert."/>
        <TextBlock x:Name="lblReplace" DockPanel.Dock="Top" Foreground="#FFB74D" TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"
                   Text="Ein Tenant-Wert ersetzt den Wert fuer alle Tenants vollstaendig - auch bei Listen (Katalog disabled, statusOnly, silent, Notfallkonten). Was aus der Spalte 'Alle Tenants' weiter gelten soll, hier mit eintragen."/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <TextBlock x:Name="lblState" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Button x:Name="btnSave" Content="Speichern" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
        <DataGrid x:Name="gridB" Style="{StaticResource DarkDataGrid}" IsReadOnly="False" AutoGenerateColumns="False" HeadersVisibility="Column" SelectionMode="Single" CanUserAddRows="False" CanUserDeleteRows="False" CanUserSortColumns="False">
            <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                    <Style.Triggers>
                        <DataTrigger Binding="{Binding Regel}" Value="Katalog"><Setter Property="Background" Value="#1C2A38"/></DataTrigger>
                    </Style.Triggers>
                </Style>
            </DataGrid.RowStyle>
            <DataGrid.Columns>
                <DataGridTextColumn Header="Regel" Binding="{Binding Regel}" IsReadOnly="True" Width="Auto" MinWidth="60"/>
                <DataGridTextColumn Header="Sollwert" Binding="{Binding Name}" IsReadOnly="True" Width="Auto" MinWidth="140"/>
                <DataGridTemplateColumn Header="Wert (hier eintragen)" Width="300">
                    <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                            <TextBox Text="{Binding Wert, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Background="#2D2D30" Foreground="White" BorderBrush="#3E3E42" CaretBrush="White"
                                     Padding="4,2" FontSize="12" TextWrapping="Wrap" VerticalContentAlignment="Center"/>
                        </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn x:Name="colGlob" Header="Alle Tenants" Binding="{Binding Global}" IsReadOnly="True" Width="Auto" MinWidth="140"/>
                <DataGridTextColumn Header="Standard" Binding="{Binding Standard}" IsReadOnly="True" Width="Auto" MinWidth="80"/>
                <DataGridTextColumn Header="Bedeutung" Binding="{Binding Text}" IsReadOnly="True" Width="*">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    if ($script:Window) { $w.Owner = $script:Window }
    $st = @{ Scope = ''; Table = $null; Dirty = $false; Loading = $false }
    $scopes = @([pscustomobject]@{ Key = ''; Name = 'Alle Tenants' }) + @($script:Settings.tenants | Where-Object { "$($_.key)" } | ForEach-Object { [pscustomobject]@{ Key = "$($_.key)"; Name = (Get-HUAnaTenantName "$($_.key)") } })
    foreach ($s in $scopes) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = $s.Name; $it.Tag = $s.Key; [void]$ctl.cmbScope.Items.Add($it) }
    $load = {
        $st.Loading = $true
        $tb = New-Object System.Data.DataTable
        foreach ($col in 'Regel', 'Key', 'Name', 'Wert', 'Global', 'Standard', 'Text', 'Orig') { [void]$tb.Columns.Add($col) }
        foreach ($r in @(Get-HUSecBaselineEdit -Scope $st.Scope)) {
            [void]$tb.Rows.Add($r.Rule, "$($r.Rule).$($r.Key)", $r.Key, $r.Value, $r.Global, $r.Default, $r.Text, $r.Value)
        }
        $st.Table = $tb
        $ctl.gridB.ItemsSource = $tb.DefaultView
        $ctl.colGlob.Visibility = $(if ($st.Scope) { 'Visible' } else { 'Collapsed' })
        $ctl.lblReplace.Visibility = $(if ($st.Scope) { 'Visible' } else { 'Collapsed' })
        $st.Dirty = $false; $ctl.lblState.Text = ''
        $st.Loading = $false
    }
    $isDirty = { $st.Table -and @($st.Table.Rows | Where-Object { "$($_['Wert'])".Trim() -ne "$($_['Orig'])".Trim() }).Count -gt 0 }
    $save = {
        try { $ctl.gridB.CommitEdit() | Out-Null; $ctl.gridB.CommitEdit() | Out-Null } catch { }
        $vals = @{}
        foreach ($row in $st.Table.Rows) { if ("$($row['Wert'])".Trim() -ne "$($row['Orig'])".Trim()) { $vals["$($row['Key'])"] = "$($row['Wert'])" } }
        if (-not $vals.Count) { $ctl.lblState.Text = 'Nichts geaendert.'; return $true }
        $err = @(Save-HUSecBaselineEdit -Scope $st.Scope -Values $vals)
        if ($err.Count) { Show-HUMessage ("Nicht gespeichert:`n`n" + ($err -join "`n")) -Icon Warning -Owner $w; return $false }
        Write-HULogOK "Sicherheitskatalog: Sollwerte gespeichert ($(if ($st.Scope) { Get-HUAnaTenantName $st.Scope } else { 'alle Tenants' }): $(@($vals.Keys | Sort-Object) -join ', '))."
        & $load
        $ctl.lblState.Text = 'Gespeichert - gilt beim naechsten Pruefen.'
        return $true
    }
    $ctl.cmbScope.Add_SelectionChanged({
            $new = "$($ctl.cmbScope.SelectedItem.Tag)"
            if ($st.Loading -or ($new -eq $st.Scope -and $st.Table)) { return }
            if (& $isDirty) {
                if (Confirm-HU 'Geaenderte Werte speichern, bevor du die Ebene wechselst?' -Owner $w) { if (-not (& $save)) { return } }
            }
            $st.Scope = $new
            & $load
        })
    $ctl.btnSave.Add_Click({ [void](& $save) })
    $ctl.btnClose.Add_Click({ $w.Close() })
    $w.Add_Closing({
            param($s, $e)
            if (& $isDirty) {
                if (Confirm-HU 'Geaenderte Werte speichern?' -Owner $w) { if (-not (& $save)) { $e.Cancel = $true } }
            }
        })
    # Start: markierter Tenant der Matrix, sonst "Alle Tenants"
    $start = 0
    $ctl.cmbScope.SelectedIndex = $start
    if (-not $st.Table) { & $load }
    [void]$w.ShowDialog()
}

function Show-HUSecDetail {
    $r = $script:Controls['gridSec'].SelectedItem
    if (-not $r -or -not $r.Ref) { return }
    $m = $r.Ref
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="980" Height="420" MinWidth="620" MinHeight="300" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnList" Content="Konten anzeigen" MinWidth="140" Padding="14,6" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Die betroffenen Eintraege des markierten Tenants anzeigen (nur Anzeige, wird nicht gespeichert)"/>
            <Button x:Name="btnFix" Content="So behebst du es" MinWidth="140" Padding="14,6" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Kurzanleitung: wo im Portal und welche Schritte, mit Link auf Microsoft Learn"/>
            <Button x:Name="btnExc" Content="Ausnahme ..." MinWidth="120" Padding="14,6" Background="#3E3E42" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Fuer diese Regel eine befristete Ausnahme eintragen oder entfernen"/>
            <Button x:Name="btnMan" Content="Von Hand geprueft ..." MinWidth="160" Padding="14,6" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Pruefung je Tenant mit Datum und Notiz bestaetigen (gilt 12 Monate) oder Bestaetigung entfernen"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" IsDefault="True"/>
        </StackPanel>
        <TextBlock x:Name="lblTitle" DockPanel.Dock="Top" Foreground="White" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock x:Name="lblMeta" DockPanel.Dock="Top" Foreground="#90CAF9" FontSize="11" Margin="0,2,0,8"/>
        <TextBlock x:Name="lblWhy" DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <DataGrid x:Name="gridD" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Tenant" Binding="{Binding Tenant}" Width="Auto" MinWidth="130"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="Auto" MinWidth="170"/>
                <DataGridTextColumn Header="Anzahl" Binding="{Binding Anzahl}" Width="Auto" MinWidth="60"/>
                <DataGridTextColumn Header="Details" Binding="{Binding Detail}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    $w.Title = "$($m.RuleId) - Details"
    $ctl.lblTitle.Text = "$($m.Title)"
    $ctl.lblMeta.Text = "$($m.RuleId)  |  $($m.Area)  |  Schweregrad $($m.Sev)"
    $why = Get-HUSecWhy "$($m.RuleId)"
    $ctl.lblWhy.Text = $why
    if (-not $why) { $ctl.lblWhy.Visibility = 'Collapsed' }
    $ctl.gridD.ItemsSource = @(foreach ($k in @($script:SecKeys)) {
            $cell = $m.Cells[$k]
            # "unvollstaendig" nur, wenn wirklich gelesen wurde (nicht bei fehlender Lizenz, fehlendem Recht oder Handpruefung)
            $noRead = ($cell -and "$($cell.Status)" -eq 'NichtPruefbar' -and "$($cell.Reason)" -in 'Lizenz', 'Recht', 'Manuell', 'NichtAnwendbar')
            $det = if ($cell) { "$($cell.Detail)$(if ($cell.Complete -eq $false -and -not $noRead) { ' (unvollstaendig gelesen)' })" } else { '' }
            [pscustomobject]@{ Key = $k; Tenant = (Get-HUAnaTenantName $k); Status = (Get-HUSecStatusText $cell); Anzahl = $(if ($cell -and [int]"0$($cell.Count)" -gt 0) { "$($cell.Count)" } else { '' }); Detail = $det }
        })
    # Liste nur anbieten, wenn mindestens ein Tenant die Regel pruefen konnte
    $listable = { param($cl) $cl -and "$($cl.Status)" -in 'OK', 'Abweichung', 'Ausnahme', 'Info' }
    $hasItems = [bool](@(Get-HUSecRules | Where-Object { $_.Id -eq $m.RuleId -and $_.PSObject.Properties['Items'] }).Count) -and [bool](@(@($script:SecKeys) | Where-Object { & $listable $m.Cells[$_] }).Count)
    if (-not $hasItems) { $ctl.btnList.Visibility = 'Collapsed' } else { $ctl.btnList.Content = "$(Get-HUSecItemsLabel "$($m.RuleId)") anzeigen" }
    $ctl.btnList.Add_Click({
            $sel = $ctl.gridD.SelectedItem
            if (-not $sel) { Show-HUMessage 'Bitte zuerst einen Tenant in der Tabelle markieren.' -Icon Info -Owner $w; return }
            if (-not (& $listable $m.Cells["$($sel.Key)"])) { Show-HUMessage "Bei $($sel.Tenant) war die Regel nicht pruefbar - keine Liste." -Icon Info -Owner $w; return }
            Start-HUSecItems -Key "$($sel.Key)" -RuleId "$($m.RuleId)" -Title "$($m.Title)" -Window $w -Button $ctl.btnList
        })
    $ctl.btnFix.Add_Click({ Show-HUSecFix -RuleId "$($m.RuleId)" })
    $state = @{ Exc = $false; Man = $false }
    $ctl.btnExc.Add_Click({ $state.Exc = $true; $w.Close() })
    # Handpruefung: keine Ausnahme und keine Liste, dafuer Bestaetigen
    if (Test-HUSecManualRule "$($m.RuleId)") { $ctl.btnExc.Visibility = 'Collapsed'; $ctl.btnList.Visibility = 'Collapsed'; $ctl.btnMan.Visibility = 'Visible' }
    $ctl.btnMan.Add_Click({ $state.Man = $true; $w.Close() })
    # Doppelklick auf eine Zeile = wie der angebotene Knopf (Konten/Richtlinien/... anzeigen bzw. von Hand geprueft)
    $ctl.gridD.ToolTip = $(if ($ctl.btnList.Visibility -eq 'Visible') { "Doppelklick: $($ctl.btnList.Content)" } elseif ($ctl.btnMan.Visibility -eq 'Visible') { 'Doppelklick: von Hand geprueft ...' } else { $null })
    $ctl.gridD.Add_MouseDoubleClick({
            param($s, $e)
            $o = $e.OriginalSource
            try { while ($o -and $o -isnot [System.Windows.Controls.DataGridRow]) { $o = $(if ($o -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($o) } else { [System.Windows.LogicalTreeHelper]::GetParent($o) }) } } catch { $o = $null }
            if (-not $o) { return }
            $b = if ($ctl.btnList.Visibility -eq 'Visible' -and $ctl.btnList.IsEnabled) { $ctl.btnList } elseif ($ctl.btnMan.Visibility -eq 'Visible') { $ctl.btnMan } else { $null }
            if ($b) { $e.Handled = $true; $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        })
    [void]$w.ShowDialog()
    if ($state.Exc) { Start-HUSecException -Row $m }
    if ($state.Man) { Start-HUSecManual -Row $m }
}

# ============================================================================
# "So behebst du es": Anleitung je Regel (Docs/Behebung.json, frische Fassung von GitHub main)
# ============================================================================
function Show-HUSecFix {
    param([Parameter(Mandatory)][string]$RuleId)
    $f = Get-HUSecFix -RuleId $RuleId -LocalPath (Join-Path $script:AppRoot 'Docs\Behebung.json')
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="560" MinWidth="520" MinHeight="320" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="16">
        <WrapPanel DockPanel.Dock="Bottom" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnLearn" Content="Microsoft Learn oeffnen" Width="180" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnPortal" Content="Portal oeffnen" Width="130" Background="#3E3E42" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnCopy" Content="Pfad kopieren" Width="120" Background="#3E3E42" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" IsDefault="True"/>
        </WrapPanel>
        <TextBlock x:Name="lblTitle" DockPanel.Dock="Top" Foreground="White" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock x:Name="lblMeta" DockPanel.Dock="Top" Foreground="#90CAF9" FontSize="11" Margin="0,2,0,10"/>
        <TextBlock x:Name="lblSrc" DockPanel.Dock="Bottom" Foreground="#888888" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"/>
        <TextBlock x:Name="lblOld" DockPanel.Dock="Bottom" Foreground="#FFB74D" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
                <TextBlock Text="Wo im Portal" Foreground="#AAAAAA" FontSize="11" Margin="0,0,0,2"/>
                <Border BorderBrush="#1976D2" BorderThickness="3,0,0,0" Margin="0,0,0,0">
                <TextBox x:Name="txtPath" IsReadOnly="True" TextWrapping="Wrap" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,12" Padding="8,6"
                         Background="#1C2A38" Foreground="#90CAF9" BorderBrush="#1976D2" BorderThickness="0,0,0,0" CaretBrush="#90CAF9"/>
                </Border>
                <TextBlock x:Name="lblStepsHead" Text="Schritte" Foreground="#AAAAAA" FontSize="11" Margin="0,0,0,4"/>
                <StackPanel x:Name="spSteps"/>
                <TextBlock x:Name="lblNote" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
                <TextBlock x:Name="lblLinksHead" Text="Quellen (Microsoft Learn)" Foreground="#AAAAAA" FontSize="11" Margin="0,12,0,4"/>
                <StackPanel x:Name="spLinks"/>
            </StackPanel>
        </ScrollViewer>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    if ($script:Window) { $w.Owner = $script:Window }
    $w.Title = "$RuleId - So behebst du es"
    $ctl.lblTitle.Text = "$($f.Title)"
    $rule = @(Get-HUSecRules | Where-Object { $_.Id -eq $RuleId })[0]
    $ctl.lblMeta.Text = "$RuleId$(if ($rule) { "  |  $($rule.Area)  |  Schweregrad $($rule.Sev)" })"
    $bc = New-Object System.Windows.Media.BrushConverter
    if ($f.Has) {
        $ctl.txtPath.Text = $(if ($f.Path) { "$($f.Path)" } else { 'kein Menue im Portal - die Schritte unten laufen per PowerShell' })
        $i = 0
        foreach ($st in @($f.Steps)) {
            $i++
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$i.  $st"; $tb.TextWrapping = 'Wrap'; $tb.FontSize = 12; $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
            $tb.Foreground = $bc.ConvertFromString('#E0E0E0')
            [void]$ctl.spSteps.Children.Add($tb)
        }
        if ($f.Note) { $ctl.lblNote.Text = "$($f.Note)"; $ctl.lblNote.Visibility = 'Visible' }
        foreach ($l in @($f.Learn)) {
            $lt = New-Object System.Windows.Controls.TextBlock
            $lt.Text = "$($l.Title)"; $lt.ToolTip = "$($l.Url)"; $lt.Cursor = 'Hand'; $lt.TextDecorations = [System.Windows.TextDecorations]::Underline
            $lt.Foreground = $bc.ConvertFromString('#4FC3F7'); $lt.FontSize = 12; $lt.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4); $lt.Tag = "$($l.Url)"
            $lt.Add_MouseLeftButtonUp({ param($s, $e) Open-HUUrl "$($s.Tag)" })
            [void]$ctl.spLinks.Children.Add($lt)
        }
        if (-not @($f.Learn).Count) { $ctl.lblLinksHead.Visibility = 'Collapsed'; $ctl.btnLearn.Visibility = 'Collapsed' }
        if (-not $f.PortalUrl) { $ctl.btnPortal.Visibility = 'Collapsed' } else { $ctl.btnPortal.Content = "$($f.PortalName) oeffnen"; $ctl.btnPortal.Width = [double]::NaN; $ctl.btnPortal.Padding = [System.Windows.Thickness]::new(12, 0, 12, 0) }
        if (-not $f.Path) { $ctl.btnCopy.Visibility = 'Collapsed' }
        $ctl.lblSrc.Text = "Geprueft am $($f.Checked) gegen Microsoft Learn  |  Stand der Anleitungen $($f.Stand)$(if ($f.Hint) { "`n$($f.Hint)" })"
        if ($f.Old) { $ctl.lblOld.Text = 'Diese Anleitung wurde vor mehr als 6 Monaten geprueft - Menuenamen koennen sich geaendert haben, der Learn-Artikel ist massgeblich.'; $ctl.lblOld.Visibility = 'Visible' }
    } else {
        $ctl.txtPath.Text = '-'
        $ctl.lblStepsHead.Text = 'Fuer diese Regel gibt es noch keine Anleitung.'
        $ctl.lblLinksHead.Visibility = 'Collapsed'
        $ctl.btnLearn.Content = 'Learn-Suche oeffnen'
        $ctl.btnPortal.Visibility = 'Collapsed'; $ctl.btnCopy.Visibility = 'Collapsed'
        $why = Get-HUSecWhy $RuleId
        if ($why) { $ctl.lblNote.Text = $why; $ctl.lblNote.Visibility = 'Visible' }
        $ctl.lblSrc.Text = 'Die Suche oeffnet Microsoft Learn mit dem Titel der Regel.'
    }
    $ctl.btnLearn.Add_Click({ if ($f.Has -and @($f.Learn).Count) { Open-HUUrl "$(@($f.Learn)[0].Url)" } else { Open-HUUrl "$($f.SearchUrl)" } })
    $ctl.btnPortal.Add_Click({ if ($f.PortalUrl) { Open-HUUrl "$($f.PortalUrl)" } })
    $ctl.btnCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText("$($f.Path)") } catch { } })
    [void]$w.ShowDialog()
}

function Show-HUSecExceptions {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="420" MinWidth="620" MinHeight="300" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="16">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnNew" Content="Neu fuer markierte Regel ..." Width="190" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Eine Ausnahme fuer die Regel eintragen, die in der Matrix markiert ist"/>
            <Button x:Name="btnDel" Content="Entfernen" Width="100" Background="#C62828" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Die markierte Ausnahme loeschen - die Abweichung gilt dann sofort wieder"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" IsDefault="True"/>
        </StackPanel>
        <TextBlock DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="Ausnahmen sind befristet und mit Begruendung. Nach Ablauf zaehlt die Abweichung wieder. Zum Anwenden danach erneut Pruefen klicken. 'wirkungslos' (orange): die Regel ist abgeschaltet oder beim letzten Pruefen nicht pruefbar - die Ausnahme kann entfernt werden; fuer nie pruefbare Regeln besser in den Sollwerten unter Katalog disabled abschalten."/>
        <DataGrid x:Name="gridEx" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Regel" Binding="{Binding Regel}" Width="Auto" MinWidth="60"/>
                <DataGridTextColumn Header="Tenant" Binding="{Binding Tenant}" Width="Auto" MinWidth="120"/>
                <DataGridTextColumn Header="Begruendung" Binding="{Binding Begruendung}" Width="2*"/>
                <DataGridTextColumn Header="Verantwortlich" Binding="{Binding Verantwortlich}" Width="Auto" MinWidth="130"/>
                <DataGridTextColumn Header="Gueltig bis" Binding="{Binding Bis}" Width="Auto" MinWidth="95"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="Auto" MinWidth="210"/>
            </DataGrid.Columns>
            <DataGrid.RowStyle>
                <Style TargetType="DataGridRow">
                    <Style.Triggers>
                        <DataTrigger Binding="{Binding Wirkungslos}" Value="ja"><Setter Property="Foreground" Value="#FFB74D"/></DataTrigger>
                        <DataTrigger Binding="{Binding Status}" Value="abgelaufen"><Setter Property="Foreground" Value="#888888"/></DataTrigger>
                    </Style.Triggers>
                </Style>
            </DataGrid.RowStyle>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    $w.Title = 'Sicherheitskatalog - Ausnahmen'
    $load = {
        $now = Get-Date
        $ctl.gridEx.ItemsSource = @(foreach ($e in @(Get-HUSecExceptions)) {
                $until = [datetime]$e.validUntil
                $es = Get-HUSecExceptionState -Exception $e -Results @($script:SecResults) -Now $now
                [pscustomobject]@{ Id = "$($e.id)"; Regel = "$($e.ruleId)"; Tenant = (Get-HUAnaTenantName "$($e.tenant)"); Begruendung = "$($e.reason)"; Verantwortlich = "$($e.responsible)"; Bis = $until.ToLocalTime().ToString('yyyy-MM-dd'); Status = $es; Wirkungslos = $(if ($es -like 'wirkungslos*') { 'ja' } else { 'nein' }) }
            })
    }
    & $load
    $ctl.btnNew.Add_Click({
            if (-not $script:Controls['gridSec'].SelectedItem) { Show-HUMessage 'Bitte zuerst in der Matrix eine Regel markieren.' -Icon Info -Owner $w; return }
            Start-HUSecException
            & $load
        })
    $ctl.btnDel.Add_Click({
            $sel = $ctl.gridEx.SelectedItem
            if (-not $sel) { Show-HUMessage 'Bitte eine Ausnahme markieren.' -Icon Info -Owner $w; return }
            Remove-HUSecException -Id "$($sel.Id)"
            Write-HULog -Message "Katalog-Ausnahme entfernt: $($sel.Regel)" -Level 'INFO'
            Add-HURtbLine $script:Controls['rtbAna'] "Ausnahme entfernt: $($sel.Regel) / $($sel.Tenant). Zum Anwenden erneut Pruefen klicken." '#FFB74D'
            & $load
        })
    [void]$w.ShowDialog()
}

function Show-HUSecExceptionDialog {
    param([Parameter(Mandatory)]$Row, [string[]]$Keys)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblHint" Style="{StaticResource HintText}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <DockPanel Margin="0,0,0,3">
            <Button x:Name="btnAllT" DockPanel.Dock="Right" Content="alle" Padding="8,1" FontSize="11" Background="#3E3E42" Style="{StaticResource DarkButton}" ToolTip="Alle Tenants anhaken"/>
            <TextBlock Text="Tenants (je Tenant eine eigene Ausnahme)" Style="{StaticResource FieldLabel}" VerticalAlignment="Center"/>
        </DockPanel>
        <WrapPanel x:Name="wpTenants" Margin="0,2,0,0"/>
        <TextBlock x:Name="lblNoDev" Foreground="#FFB74D" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0" Visibility="Collapsed"
                   Text="Hinweis: Ausnahmen wirken nur auf Abweichungen. Ist die Regel nicht pruefbar (z. B. '? Lizenz'), bitte in den Sollwerten unter 'Katalog disabled' abschalten."/>
        <TextBlock Text="Begruendung (mindestens 20 Zeichen)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtReason" Style="{StaticResource DarkTextBox}" FontSize="12" TextWrapping="Wrap" AcceptsReturn="False" MaxLength="400" Height="60"
                 ToolTip="Warum ist die Abweichung gewollt? Erscheint in der Ausnahmenliste"/>
        <TextBlock Text="Verantwortlich (Rolle)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtWho" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Rolle, keine Person, z.B. Systembetreuung oder Schulleitung"/>
        <TextBlock x:Name="lblUntil" Text="Gueltig bis (JJJJ-MM-TT)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtUntil" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Nach Ablauf zaehlt die Abweichung wieder. Hoechstens 12 Monate, bei Kritisch 3 Monate"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnRemove" Content="Ausnahme entfernen" Width="150" Background="#C62828" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Die bestehenden Ausnahmen der angehakten Tenants fuer diese Regel loeschen"/>
            <Button x:Name="btnOk" Content="Speichern" Width="100" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    $w.Title = "Ausnahme - $($Row.RuleId)"
    $ctl.lblHint.Text = "$($Row.RuleId) [$($Row.Sev)] $($Row.Title)`nEine Ausnahme ist befristet und mit Begruendung. Nach Ablauf gilt die Abweichung wieder."
    $excs = @(Get-HUSecExceptions)
    # Tenants als Haken; vorbelegt sind die mit Abweichung oder Ausnahme, sonst der erste
    $fg = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CCCCCC')
    $anyDev = [bool]@($Keys | Where-Object { $Row.Cells[$_] -and $Row.Cells[$_].Status -in 'Abweichung', 'Ausnahme' }).Count
    foreach ($k in $Keys) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = (Get-HUAnaTenantName $k); $cb.Tag = $k; $cb.Foreground = $fg; $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
        $cb.IsChecked = $(if ($anyDev) { [bool]($Row.Cells[$k] -and $Row.Cells[$k].Status -in 'Abweichung', 'Ausnahme') } else { $k -eq $Keys[0] })
        [void]$ctl.wpTenants.Children.Add($cb)
    }
    $picked = { @($ctl.wpTenants.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" }) }
    $ctl.txtWho.Text = 'Systembetreuung'
    $maxMonths = if ("$($Row.Sev)" -eq 'Kritisch') { 3 } else { 12 }
    $ctl.txtUntil.Text = (Get-Date).AddMonths([Math]::Min(3, $maxMonths)).ToString('yyyy-MM-dd')
    $sync = {
        $tks = @(& $picked)
        $has = @($excs | Where-Object { $_.ruleId -eq $Row.RuleId -and $tks -contains $_.tenant }).Count -gt 0
        $ctl.btnRemove.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
        # Hinweis, wenn bei einem angehakten Tenant gar keine Abweichung vorliegt (nicht pruefbar)
        $np = @($tks | Where-Object { $Row.Cells[$_] -and "$($Row.Cells[$_].Status)" -eq 'NichtPruefbar' }).Count
        $ctl.lblNoDev.Visibility = $(if ($np) { 'Visible' } else { 'Collapsed' })
    }
    foreach ($cb in @($ctl.wpTenants.Children)) { $cb.Add_Click($sync) }
    $ctl.btnAllT.Add_Click({ foreach ($cb in @($ctl.wpTenants.Children)) { $cb.IsChecked = $true }; & $sync })
    & $sync
    $state = @{ Action = '' }
    $ctl.btnOk.Add_Click({
            if (-not @(& $picked).Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning -Owner $w; return }
            $until = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($ctl.txtUntil.Text.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$until)) { Show-HUMessage 'Datum bitte als JJJJ-MM-TT eingeben.' -Icon Warning -Owner $w; return }
            if (-not $ctl.txtWho.Text.Trim()) { Show-HUMessage 'Bitte eine verantwortliche Rolle eintragen.' -Icon Warning -Owner $w; return }
            $err = Test-HUSecExceptionInput -Reason $ctl.txtReason.Text -ValidUntil $until.Date.AddDays(1).AddSeconds(-1) -Sev "$($Row.Sev)"
            if ($err) { Show-HUMessage $err -Icon Warning -Owner $w; return }
            $state.Action = 'add'; $w.Close()
        })
    $ctl.btnRemove.Add_Click({ if (-not @(& $picked).Count) { return }; $state.Action = 'remove'; $w.Close() })
    $w.Add_ContentRendered({ $ctl.txtReason.Focus() })
    [void]$w.ShowDialog()
    if (-not $state.Action) { return $null }
    $until2 = [datetime]::ParseExact($ctl.txtUntil.Text.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    return [pscustomobject]@{ Action = $state.Action; Tenants = @(& $picked); Reason = $ctl.txtReason.Text.Trim(); Who = $ctl.txtWho.Text.Trim(); Until = $until2.Date.AddDays(1).AddSeconds(-1) }
}

function Start-HUSecException {
    param($Row = $null)
    $m = $Row
    if (-not $m) {
        $r = $script:Controls['gridSec'].SelectedItem
        if (-not $r -or -not $r.Ref) { Show-HUMessage 'Bitte zuerst eine Regel in der Tabelle markieren.' -Icon Info; return }
        $m = $r.Ref
    }
    if (-not $script:SecKeys.Count) { return }
    $res = Show-HUSecExceptionDialog -Row $m -Keys @($script:SecKeys)
    if (-not $res) { return }
    # je angehaktem Tenant eine eigene Ausnahme (Ablauf und Begruendung gleich)
    foreach ($tk in @($res.Tenants)) {
        try {
            if ($res.Action -eq 'remove') {
                $old = @(Get-HUSecExceptions | Where-Object { $_.ruleId -eq $m.RuleId -and $_.tenant -eq $tk })
                foreach ($o in $old) { Remove-HUSecException -Id "$($o.id)" }
                if ($old.Count) { Add-HURtbLine $script:Controls['rtbAna'] "Ausnahme entfernt: $($m.RuleId) / $(Get-HUAnaTenantName $tk)" '#FFB74D' }
            } else {
                [void](Add-HUSecException -RuleId $m.RuleId -TenantKey $tk -Reason $res.Reason -ValidUntil $res.Until -Responsible $res.Who -Sev "$($m.Sev)")
                Add-HURtbLine $script:Controls['rtbAna'] "Ausnahme eingetragen: $($m.RuleId) / $(Get-HUAnaTenantName $tk) bis $($res.Until.ToString('yyyy-MM-dd'))" '#81C784'
            }
            Write-HULog -Message "Katalog-Ausnahme $($res.Action): $($m.RuleId)" -Level 'INFO' -Tenant $tk
        } catch { Show-HUMessage "$(Get-HUAnaTenantName $tk): $($_.Exception.Message)" -Icon Warning; return }
    }
    Add-HURtbLine $script:Controls['rtbAna'] 'Zum Anwenden bitte erneut Pruefen klicken.' '#90CAF9'
}

# ============================================================================
# Handpruefung: Bestaetigung je Tenant (Datum, Rolle, Notiz), gilt 12 Monate
# ============================================================================
function Show-HUSecManualDialog {
    param([Parameter(Mandatory)]$Row, [string[]]$Keys)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblHint" Style="{StaticResource HintText}" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <DockPanel Margin="0,0,0,3">
            <Button x:Name="btnAllT" DockPanel.Dock="Right" Content="alle" Padding="8,1" FontSize="11" Background="#3E3E42" Style="{StaticResource DarkButton}" ToolTip="Alle Tenants anhaken"/>
            <TextBlock Text="Tenants (je Tenant eine eigene Bestaetigung)" Style="{StaticResource FieldLabel}" VerticalAlignment="Center"/>
        </DockPanel>
        <WrapPanel x:Name="wpTenants" Margin="0,2,0,0"/>
        <TextBlock Text="Notiz: was wurde wie geprueft? (mindestens 10 Zeichen, keine Namen)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtNote" Style="{StaticResource DarkTextBox}" FontSize="12" TextWrapping="Wrap" AcceptsReturn="False" MaxLength="300" Height="60"
                 ToolTip="Erscheint in den Details, z. B. 'AD-Abfrage am DC, 0 Treffer'"/>
        <TextBlock Text="Verantwortlich (Rolle)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtWho" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Rolle, keine Person, z.B. Systembetreuung"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnRemove" Content="Bestaetigung entfernen" Width="170" Background="#C62828" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Die Bestaetigungen der angehakten Tenants fuer diese Pruefung loeschen"/>
            <Button x:Name="btnOk" Content="Bestaetigen" Width="110" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $ctl = $d.C
    $w.Title = "Von Hand geprueft - $($Row.RuleId)"
    $ctl.lblHint.Text = "$($Row.RuleId) [$($Row.Sev)] $($Row.Title)`nDiese Pruefung kann das Programm nicht selbst lesen. Bestaetigung gilt 12 Monate, danach erscheint sie wieder als offen. Zaehlt nicht zur Ampel."
    $man = @(Get-HUSecManual)
    $fg = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CCCCCC')
    # vorbelegt: offene bzw. abgelaufene Tenants, sonst der erste
    $open = @($Keys | Where-Object { -not $Row.Cells[$_] -or "$($Row.Cells[$_].Status)" -ne 'Info' })
    foreach ($k in $Keys) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = (Get-HUAnaTenantName $k); $cb.Tag = $k; $cb.Foreground = $fg; $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
        $cb.IsChecked = $(if ($open.Count) { $open -contains $k } else { $k -eq $Keys[0] })
        [void]$ctl.wpTenants.Children.Add($cb)
    }
    $picked = { @($ctl.wpTenants.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" }) }
    $ctl.txtWho.Text = 'Systembetreuung'
    $sync = {
        $tks = @(& $picked)
        $has = @($man | Where-Object { $_.ruleId -eq $Row.RuleId -and $tks -contains $_.tenant }).Count -gt 0
        $ctl.btnRemove.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
    }
    foreach ($cb in @($ctl.wpTenants.Children)) { $cb.Add_Click($sync) }
    $ctl.btnAllT.Add_Click({ foreach ($cb in @($ctl.wpTenants.Children)) { $cb.IsChecked = $true }; & $sync })
    & $sync
    $state = @{ Action = '' }
    $ctl.btnOk.Add_Click({
            if (-not @(& $picked).Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning -Owner $w; return }
            if ($ctl.txtNote.Text.Trim().Length -lt 10) { Show-HUMessage 'Notiz: mindestens 10 Zeichen (was wurde wie geprueft?).' -Icon Warning -Owner $w; return }
            if (-not $ctl.txtWho.Text.Trim()) { Show-HUMessage 'Bitte eine verantwortliche Rolle eintragen.' -Icon Warning -Owner $w; return }
            $state.Action = 'add'; $w.Close()
        })
    $ctl.btnRemove.Add_Click({ if (-not @(& $picked).Count) { return }; $state.Action = 'remove'; $w.Close() })
    $w.Add_ContentRendered({ $ctl.txtNote.Focus() })
    [void]$w.ShowDialog()
    if (-not $state.Action) { return $null }
    return [pscustomobject]@{ Action = $state.Action; Tenants = @(& $picked); Note = $ctl.txtNote.Text.Trim(); Who = $ctl.txtWho.Text.Trim() }
}

function Start-HUSecManual {
    param([Parameter(Mandatory)]$Row)
    if (-not $script:SecKeys.Count) { return }
    $res = Show-HUSecManualDialog -Row $Row -Keys @($script:SecKeys)
    if (-not $res) { return }
    foreach ($tk in @($res.Tenants)) {
        try {
            if ($res.Action -eq 'remove') {
                Remove-HUSecManual -RuleId "$($Row.RuleId)" -TenantKey $tk
                Add-HURtbLine $script:Controls['rtbAna'] "Handpruefung zurueckgenommen: $($Row.RuleId) / $(Get-HUAnaTenantName $tk)" '#FFB74D'
            } else {
                [void](Set-HUSecManual -RuleId "$($Row.RuleId)" -TenantKey $tk -Note $res.Note -Responsible $res.Who)
                Add-HURtbLine $script:Controls['rtbAna'] "Handpruefung bestaetigt: $($Row.RuleId) / $(Get-HUAnaTenantName $tk)" '#81C784'
            }
            Write-HULog -Message "Katalog-Handpruefung $($res.Action): $($Row.RuleId)" -Level 'INFO' -Tenant $tk
        } catch { Show-HUMessage "$(Get-HUAnaTenantName $tk): $($_.Exception.Message)" -Icon Warning; return }
        # Zelle sofort neu berechnen (kein Graph noetig)
        $new = Get-HUSecManualResult -RuleId "$($Row.RuleId)" -TenantKey $tk
        if ($new -and $script:SecRan) {
            $script:SecResults = @(@($script:SecResults | Where-Object { -not ("$($_.RuleId)" -eq "$($Row.RuleId)" -and "$($_.Tenant)" -eq $tk) }) + $new)
        }
    }
    if ($script:SecRan) {
        $script:SecMatrix = @(Get-HUSecMatrix -Results $script:SecResults -Keys $script:SecKeys)
        Update-HUSecGrid
    }
}

function Register-HUSecHandlers {
    $c = $script:Controls
    $c['chkSecDev'].IsChecked = [bool](Get-HUStateValue 'secDev' $false)
    $c['chkSecDiff'].IsChecked = [bool](Get-HUStateValue 'secDiff' $false)
    $c['chkSecColor'].IsChecked = [bool](Get-HUStateValue 'secColor' $true)
    $c['chkSecColor'].Add_Checked({ Set-HUStateValue 'secColor' $true; Update-HUSecGrid })
    $c['chkSecColor'].Add_Unchecked({ Set-HUStateValue 'secColor' $false; Update-HUSecGrid })
    $c['chkSecDev'].Add_Checked({ Set-HUStateValue 'secDev' $true; Update-HUSecGrid })
    $c['chkSecDev'].Add_Unchecked({ Set-HUStateValue 'secDev' $false; Update-HUSecGrid })
    $c['chkSecDiff'].Add_Checked({ Set-HUStateValue 'secDiff' $true; Update-HUSecGrid })
    $c['chkSecDiff'].Add_Unchecked({ Set-HUStateValue 'secDiff' $false; Update-HUSecGrid })
    # Bereiche und Grade: Haken je Wert (Bereiche auch aus den Regeln)
    $areas = @('Entra', 'Apps', 'Intune', 'Teams', 'SharePoint', 'Handpruefung')
    foreach ($a in @(Get-HUSecRules | ForEach-Object { "$($_.Area)" } | Sort-Object -Unique)) { if ($areas -notcontains $a) { $areas += $a } }
    Initialize-HUSecPick 'Area' $areas
    Initialize-HUSecPick 'Sev' @('Kritisch', 'Hoch', 'Mittel', 'Niedrig')
    $c['txtSecFilter'].Add_TextChanged({ Update-HUSecGrid })
    $c['btnSecRun'].Add_Click({ Start-HUSecRun })
    $c['btnSecExc'].Add_Click({ Show-HUSecExceptions })
    $c['btnSecBase'].Add_Click({ try { Show-HUSecBaseline } catch { Show-HUMessage "Sollwerte: $($_.Exception.Message)" -Icon Warning } })
    $c['btnSecRef'].Add_Click({
            if (-not $script:SecRan -or -not @($script:SecResults).Count) { Show-HUMessage 'Noch keine Ergebnisse - zuerst pruefen.' -Icon Info; return }
            $old = $null; try { $old = Get-HUSecReference } catch { }
            $n = @($script:SecKeys).Count
            $txt = "Den aktuellen Stand ($n Tenant(s)) als Soll speichern?`n`nDie Meldung 'Sicherheits-Aenderung' (Reiter Teams) meldet danach jede Aenderung dagegen. Gespeichert werden nur Status und Zahlen."
            if ($old) {
                $txt += "`n`nDer bisherige Soll-Stand wird ersetzt."
                $w = @(); try { $w = @(Get-HUSecReferenceWorse -Results $script:SecResults) } catch { }
                if ($w.Count) {
                    $ex = (@($w | Select-Object -First 5 | ForEach-Object { "$($_.RuleId) ($(Get-HUAnaTenantName $_.Tenant))" }) -join ', ')
                    $txt += "`n`nACHTUNG: Der neue Stand ist bei $($w.Count) Regel(n) SCHLECHTER als der bisherige Soll, z. B. $ex$(if ($w.Count -gt 5) { ' ...' }). Diese Verschlechterungen gelten danach als normal und werden nicht mehr gemeldet. Die Teams-Meldung weist einmal darauf hin."
                }
            }
            if (-not (Confirm-HU -Warning $txt)) { return }
            try { [void](Save-HUSecReference -Results $script:SecResults); Show-HUMessage 'Soll-Stand gespeichert.' -Icon Info }
            catch { Show-HUMessage "Soll-Stand nicht gespeichert: $($_.Exception.Message)" -Icon Warning }
        })
    $c['gridSec'].Add_MouseDoubleClick({ Show-HUSecDetail })
    # "So behebst du es": Rechtsklick auf eine Regel oder F1 auf der markierten Zeile
    $cmFix = New-Object System.Windows.Controls.ContextMenu
    $miFix = New-Object System.Windows.Controls.MenuItem; $miFix.Header = 'So behebst du es ...'; $miFix.InputGestureText = 'F1'
    $miFix.Add_Click({ $r = $script:Controls['gridSec'].SelectedItem; if ($r -and $r.Ref) { Show-HUSecFix -RuleId "$($r.Ref.RuleId)" } })
    [void]$cmFix.Items.Add($miFix)
    $miDet = New-Object System.Windows.Controls.MenuItem; $miDet.Header = 'Details ...'
    $miDet.Add_Click({ Show-HUSecDetail })
    [void]$cmFix.Items.Add($miDet)
    $c['gridSec'].ContextMenu = $cmFix
    $c['gridSec'].Add_PreviewMouseRightButtonDown({
            param($s, $e)
            # Zeile unter der Maus markieren, damit das Menue zur richtigen Regel gehoert
            $dep = $e.OriginalSource
            while ($dep -and -not ($dep -is [System.Windows.Controls.DataGridRow])) { $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep) }
            if ($dep) { $dep.IsSelected = $true }
        })
    # F1 auf der markierten Zeile: siehe Tastatur-Handler in Main.ps1
    $c['btnSecTable'].Add_Click({
            if (-not $script:SecRan -or -not @($script:SecMatrix).Count) { Show-HUMessage 'Noch keine Ergebnisse.' -Icon Info; return }
            $keys = @($script:SecKeys)
            $rows = foreach ($m in @(Get-HUSecVisibleRows)) {
                $o = [ordered]@{ Grad = $m.Sev; Nr = $m.RuleId; Bereich = $m.Area; Regel = $m.Title }
                foreach ($k in $keys) {
                    $cell = $m.Cells[$k]
                    $o[(Get-HUAnaTenantName $k)] = $(if ($cell) { "$($cell.Status)$(if ("$($cell.Reason)") { " ($($cell.Reason))" })$(if ($null -ne $cell.Count -and "$($cell.Count)" -ne '' -and [int]"0$($cell.Count)" -gt 0) { " $($cell.Count)" })" } else { '' })
                }
                [pscustomobject]$o
            }
            Show-HUQSTable -Title 'Sicherheitskatalog' -Objects @($rows) -FilePrefix 'Sicherheitskatalog'
        })
}
