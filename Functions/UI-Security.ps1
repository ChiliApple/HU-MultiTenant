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
        'Info' { if ("$($Cell.Detail)" -match '\(([0-9.,]+ %)\)\s*$') { return $Matches[1] }; return 'i' }
        default { return "$($Cell.Status)" }
    }
}

# Gewaehlter Filterwert (Tag) einer Auswahlbox; leer = alle
function Get-HUSecComboTag([string]$Name) {
    $cb = $script:Controls[$Name]
    if ($cb -and $cb.SelectedItem) { return "$($cb.SelectedItem.Tag)" }
    return ''
}

function Get-HUSecVisibleRows {
    $rows = @($script:SecMatrix)
    if ($script:Controls['chkSecDev'].IsChecked) { $rows = @($rows | Where-Object { $_.Dev }) }
    if ($script:Controls['chkSecDiff'].IsChecked) { $rows = @($rows | Where-Object { $_.Diff }) }
    $selArea = Get-HUSecComboTag 'cmbSecArea'
    if ($selArea) { $rows = @($rows | Where-Object { "$($_.Area)" -eq $selArea }) }
    $selSev = Get-HUSecComboTag 'cmbSecSev'
    if ($selSev) { $rows = @($rows | Where-Object { "$($_.Sev)" -eq $selSev }) }
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
    & $add 'Regel' 'Rule' (New-Object System.Windows.Controls.DataGridLength(1, $cells))
    & $pad 28
    # Tenant-Spalten: Text wie bisher, in der letzten Zeile (Ampel) zusaetzlich ein farbiger Punkt
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $tpl = [System.Windows.Markup.XamlReader]::Parse("<DataTemplate xmlns=`'http://schemas.microsoft.com/winfx/2006/xaml/presentation`'><StackPanel Orientation=`'Horizontal`'><Ellipse Width=`'9`' Height=`'9`' Margin=`'0,0,6,0`' VerticalAlignment=`'Center`' Fill=`'{Binding Lc$i}`' Visibility=`'{Binding Lv$i}`'/><TextBlock Text=`'{Binding T$i}`' VerticalAlignment=`'Center`'/></StackPanel></DataTemplate>")
        $col = New-Object System.Windows.Controls.DataGridTemplateColumn
        $col.Header = Get-HUAnaTenantName $keys[$i]; $col.CellTemplate = $tpl; $col.SortMemberPath = "T$i"; $col.MinWidth = 120
        $col.Width = New-Object System.Windows.Controls.DataGridLength(1, $cells)
        [void]$g.Columns.Add($col)
    }
    $items = foreach ($m in @(Get-HUSecVisibleRows)) {
        $o = [ordered]@{ Sev = $m.Sev; SevRank = [int]@{ Kritisch = 0; Hoch = 1; Mittel = 2; Niedrig = 3 }["$($m.Sev)"]; Area = $m.Area; Nr = "$($m.RuleId)"; Rule = "$($m.Title)" }
        for ($i = 0; $i -lt $keys.Count; $i++) { $o["T$i"] = Get-HUSecCellText $m.Cells[$keys[$i]] }
        for ($i = 0; $i -lt $keys.Count; $i++) { $o["Lc$i"] = '#000000'; $o["Lv$i"] = 'Collapsed' }
        $o.Ref = $m
        [pscustomobject]$o
    }
    $items = @($items)
    # letzte Zeile: Ampel je Tenant in derselben Spalte (rot = ab 10 nicht erfuellte Regeln, gelb = 1 bis 9, gruen = keine)
    if ($script:SecRan -and $keys.Count) {
        $col = @{ Rot = '#EF5350'; Gelb = '#FFB74D'; Gruen = '#66BB6A'; Grau = '#757575' }
        $f = [ordered]@{ Sev = ''; SevRank = 9; Area = ''; Nr = ''; Rule = 'Ampel' }
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $rows = $script:SecData["$($keys[$i])"]
            if ($rows) { $l = Get-HUSecLight -Results @($rows) -Key $keys[$i]; $f["T$i"] = "$($l.Ok) von $($l.Checked)"; $f["Lc$i"] = $col[$l.Color] }
            else { $f["T$i"] = '...'; $f["Lc$i"] = $col['Grau'] }
            $f["Lv$i"] = 'Visible'
        }
        $f.Ref = $null
        $items += [pscustomobject]$f
    }
    $g.ItemsSource = @($items)
    Update-HUSecHint
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
            <Button x:Name="btnList" Content="Konten anzeigen" Width="140" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Die betroffenen Eintraege des markierten Tenants anzeigen (nur Anzeige, wird nicht gespeichert)"/>
            <Button x:Name="btnExc" Content="Ausnahme ..." Width="120" Background="#3E3E42" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Fuer diese Regel eine befristete Ausnahme eintragen oder entfernen"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" IsDefault="True"/>
        </StackPanel>
        <TextBlock x:Name="lblTitle" DockPanel.Dock="Top" Foreground="White" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock x:Name="lblMeta" DockPanel.Dock="Top" Foreground="#90CAF9" FontSize="11" Margin="0,2,0,8"/>
        <TextBlock x:Name="lblWhy" DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <DataGrid x:Name="gridD" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Tenant" Binding="{Binding Tenant}" Width="130"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="170"/>
                <DataGridTextColumn Header="Anzahl" Binding="{Binding Anzahl}" Width="60"/>
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
            $det = if ($cell) { "$($cell.Detail)$(if ($cell.Complete -eq $false) { ' (unvollstaendig gelesen)' })" } else { '' }
            [pscustomobject]@{ Key = $k; Tenant = (Get-HUAnaTenantName $k); Status = (Get-HUSecStatusText $cell); Anzahl = $(if ($cell -and [int]"0$($cell.Count)" -gt 0) { "$($cell.Count)" } else { '' }); Detail = $det }
        })
    $hasItems = [bool](@(Get-HUSecRules | Where-Object { $_.Id -eq $m.RuleId -and $_.PSObject.Properties['Items'] }).Count)
    if (-not $hasItems) { $ctl.btnList.Visibility = 'Collapsed' } else { $ctl.btnList.Content = "$(Get-HUSecItemsLabel "$($m.RuleId)") anzeigen" }
    $ctl.btnList.Add_Click({
            $sel = $ctl.gridD.SelectedItem
            if (-not $sel) { Show-HUMessage 'Bitte zuerst einen Tenant in der Tabelle markieren.' -Icon Info -Owner $w; return }
            Start-HUSecItems -Key "$($sel.Key)" -RuleId "$($m.RuleId)" -Title "$($m.Title)" -Window $w -Button $ctl.btnList
        })
    $state = @{ Exc = $false }
    $ctl.btnExc.Add_Click({ $state.Exc = $true; $w.Close() })
    [void]$w.ShowDialog()
    if ($state.Exc) { Start-HUSecException -Row $m }
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
                   Text="Ausnahmen sind befristet und mit Begruendung. Nach Ablauf zaehlt die Abweichung wieder. Zum Anwenden danach erneut Pruefen klicken."/>
        <DataGrid x:Name="gridEx" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Regel" Binding="{Binding Regel}" Width="60"/>
                <DataGridTextColumn Header="Tenant" Binding="{Binding Tenant}" Width="120"/>
                <DataGridTextColumn Header="Begruendung" Binding="{Binding Begruendung}" Width="2*"/>
                <DataGridTextColumn Header="Verantwortlich" Binding="{Binding Verantwortlich}" Width="130"/>
                <DataGridTextColumn Header="Gueltig bis" Binding="{Binding Bis}" Width="95"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="80"/>
            </DataGrid.Columns>
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
                [pscustomobject]@{ Id = "$($e.id)"; Regel = "$($e.ruleId)"; Tenant = (Get-HUAnaTenantName "$($e.tenant)"); Begruendung = "$($e.reason)"; Verantwortlich = "$($e.responsible)"; Bis = $until.ToLocalTime().ToString('yyyy-MM-dd'); Status = $(if ($until -gt $now) { 'aktiv' } else { 'abgelaufen' }) }
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
        <TextBlock Text="Tenant" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <ComboBox x:Name="cmbTenant" Style="{StaticResource DarkComboBox}" ToolTip="Die Ausnahme gilt nur fuer diesen Tenant"/>
        <TextBlock Text="Begruendung (mindestens 20 Zeichen)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtReason" Style="{StaticResource DarkTextBox}" FontSize="12" TextWrapping="Wrap" AcceptsReturn="False" MaxLength="400" Height="60"
                 ToolTip="Warum ist die Abweichung gewollt? Erscheint in der Ausnahmenliste"/>
        <TextBlock Text="Verantwortlich (Rolle)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtWho" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Rolle, keine Person, z.B. Systembetreuung oder Schulleitung"/>
        <TextBlock x:Name="lblUntil" Text="Gueltig bis (JJJJ-MM-TT)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtUntil" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Nach Ablauf zaehlt die Abweichung wieder. Hoechstens 12 Monate, bei Kritisch 3 Monate"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnRemove" Content="Ausnahme entfernen" Width="150" Background="#C62828" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Die bestehende Ausnahme dieses Tenants fuer diese Regel loeschen"/>
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
    foreach ($k in $Keys) { $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = (Get-HUAnaTenantName $k); $it.Tag = $k; [void]$ctl.cmbTenant.Items.Add($it) }
    $first = $null
    foreach ($it in @($ctl.cmbTenant.Items)) { if (-not $first -and $Row.Cells[$it.Tag] -and $Row.Cells[$it.Tag].Status -in 'Abweichung', 'Ausnahme') { $first = $it } }
    if (-not $first -and $ctl.cmbTenant.Items.Count) { $first = $ctl.cmbTenant.Items[0] }
    $ctl.cmbTenant.SelectedItem = $first
    $ctl.txtWho.Text = 'Systembetreuung'
    $maxMonths = if ("$($Row.Sev)" -eq 'Kritisch') { 3 } else { 12 }
    $ctl.txtUntil.Text = (Get-Date).AddMonths([Math]::Min(3, $maxMonths)).ToString('yyyy-MM-dd')
    $sync = {
        $tk = "$($ctl.cmbTenant.SelectedItem.Tag)"
        $has = @($excs | Where-Object { $_.ruleId -eq $Row.RuleId -and $_.tenant -eq $tk }).Count -gt 0
        $ctl.btnRemove.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
    }
    $ctl.cmbTenant.Add_SelectionChanged($sync)
    & $sync
    $state = @{ Action = '' }
    $ctl.btnOk.Add_Click({
            $until = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($ctl.txtUntil.Text.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$until)) { Show-HUMessage 'Datum bitte als JJJJ-MM-TT eingeben.' -Icon Warning -Owner $w; return }
            if (-not $ctl.txtWho.Text.Trim()) { Show-HUMessage 'Bitte eine verantwortliche Rolle eintragen.' -Icon Warning -Owner $w; return }
            $err = Test-HUSecExceptionInput -Reason $ctl.txtReason.Text -ValidUntil $until.Date.AddDays(1).AddSeconds(-1) -Sev "$($Row.Sev)"
            if ($err) { Show-HUMessage $err -Icon Warning -Owner $w; return }
            $state.Action = 'add'; $w.Close()
        })
    $ctl.btnRemove.Add_Click({ $state.Action = 'remove'; $w.Close() })
    $w.Add_ContentRendered({ $ctl.txtReason.Focus() })
    [void]$w.ShowDialog()
    if (-not $state.Action) { return $null }
    $until2 = [datetime]::ParseExact($ctl.txtUntil.Text.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    return [pscustomobject]@{ Action = $state.Action; Tenant = "$($ctl.cmbTenant.SelectedItem.Tag)"; Reason = $ctl.txtReason.Text.Trim(); Who = $ctl.txtWho.Text.Trim(); Until = $until2.Date.AddDays(1).AddSeconds(-1) }
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
    try {
        if ($res.Action -eq 'remove') {
            $old = @(Get-HUSecExceptions | Where-Object { $_.ruleId -eq $m.RuleId -and $_.tenant -eq $res.Tenant })
            foreach ($o in $old) { Remove-HUSecException -Id "$($o.id)" }
            Add-HURtbLine $script:Controls['rtbAna'] "Ausnahme entfernt: $($m.RuleId) / $(Get-HUAnaTenantName $res.Tenant)" '#FFB74D'
        } else {
            [void](Add-HUSecException -RuleId $m.RuleId -TenantKey $res.Tenant -Reason $res.Reason -ValidUntil $res.Until -Responsible $res.Who -Sev "$($m.Sev)")
            Add-HURtbLine $script:Controls['rtbAna'] "Ausnahme eingetragen: $($m.RuleId) / $(Get-HUAnaTenantName $res.Tenant) bis $($res.Until.ToString('yyyy-MM-dd'))" '#81C784'
        }
        Write-HULog -Message "Katalog-Ausnahme $($res.Action): $($m.RuleId)" -Level 'INFO' -Tenant $res.Tenant
    } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning; return }
    Add-HURtbLine $script:Controls['rtbAna'] 'Zum Anwenden bitte erneut Pruefen klicken.' '#90CAF9'
}

function Register-HUSecHandlers {
    $c = $script:Controls
    $c['chkSecDev'].IsChecked = [bool](Get-HUStateValue 'secDev' $false)
    $c['chkSecDiff'].IsChecked = [bool](Get-HUStateValue 'secDiff' $false)
    $c['chkSecDev'].Add_Checked({ Set-HUStateValue 'secDev' $true; Update-HUSecGrid })
    $c['chkSecDev'].Add_Unchecked({ Set-HUStateValue 'secDev' $false; Update-HUSecGrid })
    $c['chkSecDiff'].Add_Checked({ Set-HUStateValue 'secDiff' $true; Update-HUSecGrid })
    $c['chkSecDiff'].Add_Unchecked({ Set-HUStateValue 'secDiff' $false; Update-HUSecGrid })
    foreach ($pair in @(@('cmbSecArea', 'secArea'), @('cmbSecSev', 'secSev'))) {
        $cbx = $c[$pair[0]]; $key = $pair[1]
        $saved = "$(Get-HUStateValue $key '')"
        foreach ($it in @($cbx.Items)) { if ("$($it.Tag)" -eq $saved) { $cbx.SelectedItem = $it } }
    }
    $c['cmbSecArea'].Add_SelectionChanged({ Set-HUStateValue 'secArea' (Get-HUSecComboTag 'cmbSecArea'); Update-HUSecGrid })
    $c['cmbSecSev'].Add_SelectionChanged({ Set-HUStateValue 'secSev' (Get-HUSecComboTag 'cmbSecSev'); Update-HUSecGrid })
    $c['txtSecFilter'].Add_TextChanged({ Update-HUSecGrid })
    $c['btnSecRun'].Add_Click({ Start-HUSecRun })
    $c['btnSecExc'].Add_Click({ Show-HUSecExceptions })
    $c['btnSecRef'].Add_Click({
            if (-not $script:SecRan -or -not @($script:SecResults).Count) { Show-HUMessage 'Noch keine Ergebnisse - zuerst pruefen.' -Icon Info; return }
            $old = $null; try { $old = Get-HUSecReference } catch { }
            $n = @($script:SecKeys).Count
            $txt = "Den aktuellen Stand ($n Tenant(s)) als Soll speichern?`n`nDie Meldung 'Sicherheits-Aenderung' (Reiter Teams) meldet danach jede Aenderung dagegen. Gespeichert werden nur Status und Zahlen."
            if ($old) { $txt += "`n`nDer bisherige Soll-Stand wird ersetzt." }
            if (-not (Confirm-HU $txt)) { return }
            try { [void](Save-HUSecReference -Results $script:SecResults); Show-HUMessage 'Soll-Stand gespeichert.' -Icon Info }
            catch { Show-HUMessage "Soll-Stand nicht gespeichert: $($_.Exception.Message)" -Icon Warning }
        })
    $c['gridSec'].Add_MouseDoubleClick({ Show-HUSecDetail })
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
