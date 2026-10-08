#Requires -Version 5.1
<#
.SYNOPSIS
    Gruppen-Auswahl fuer Apps und Wartung: liest die Gruppen der angehakten Tenants, filtert und zeigt,
    in wie vielen Tenants es eine Gruppe dieses Namens gibt (zugewiesen wird je Tenant per Name).
.NOTES
    Dot-Source aus Main.ps1. Gruppen werden je Tenant fuer die Sitzung zwischengespeichert (Knopf "Neu laden").
    Benoetigt Group.Read.All. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:GroupCache = @{}     # TenantKey -> @{ Rows = object[]; Error = ''; Time = datetime }
$script:GP = $null           # offenes Auswahlfenster

# Gruppen mehrerer Tenants -> eine Zeile je Name mit "in x von y Tenants"
function Get-HUGroupPickRows([string[]]$Keys, [string]$Filter = '', [bool]$OnlyAll = $false) {
    $map = @{}
    foreach ($k in $Keys) {
        $e = $script:GroupCache[$k]
        if (-not $e) { continue }
        foreach ($g in @($e.Rows)) {
            $n = "$($g.Name)"
            if (-not $map.ContainsKey($n.ToLower())) { $map[$n.ToLower()] = @{ Name = $n; Typ = "$($g.Typ)"; Tenants = New-Object System.Collections.Generic.List[string] } }
            $t = $map[$n.ToLower()].Tenants
            if (-not $t.Contains($k)) { $t.Add($k) }
        }
    }
    $f = "$Filter".Trim()
    $rows = foreach ($v in $map.Values) {
        if ($f -and $v.Name -notlike "*$f*") { continue }
        $cnt = $v.Tenants.Count
        if ($OnlyAll -and $cnt -lt $Keys.Count) { continue }
        $missing = @($Keys | Where-Object { -not $v.Tenants.Contains($_) } | ForEach-Object { Get-HUTenantDisplayName $_ })
        [pscustomobject]@{
            Name      = $v.Name
            Typ       = $v.Typ
            Vorhanden = $(if ($cnt -eq $Keys.Count) { "alle ($cnt)" } else { "$cnt von $($Keys.Count)" })
            Fehlt     = ($missing -join ', ')
            Sort      = $(if ($cnt -eq $Keys.Count) { 0 } else { 1 })
        }
    }
    return @($rows | Sort-Object Sort, Name)
}

function Update-HUGroupPickView {
    $g = $script:GP
    if (-not $g) { return }
    $c = $g.C
    $rows = @(Get-HUGroupPickRows -Keys $g.Keys -Filter $c.txtFilter.Text -OnlyAll ([bool]$c.chkAll.IsChecked))
    $c.grid.ItemsSource = $rows
    $loaded = @($g.Keys | Where-Object { $script:GroupCache[$_] })
    $errs = @($g.Keys | Where-Object { $script:GroupCache[$_] -and $script:GroupCache[$_].Error } | ForEach-Object { "$(Get-HUTenantDisplayName $_): $($script:GroupCache[$_].Error)" })
    $txt = if ($loaded.Count -lt $g.Keys.Count) { "Lade Gruppen ... ($($loaded.Count) von $($g.Keys.Count) Tenants)" } else { "$($rows.Count) Gruppe(n)" }
    if ($errs.Count) { $txt += "  |  Fehler: " + ($errs -join '; ') }
    $c.lblState.Text = $txt
    $c.lblState.Foreground = Get-HUBrush $(if ($errs.Count) { '#FFB74D' } else { '#858585' })
    if ($rows.Count -and -not $c.grid.SelectedItem) {
        $cur = @($rows | Where-Object { $_.Name -eq $g.Current } | Select-Object -First 1)
        $c.grid.SelectedItem = $(if ($cur.Count) { $cur[0] } else { $rows[0] })
        if ($c.grid.SelectedItem) { $c.grid.ScrollIntoView($c.grid.SelectedItem) }
    }
}

function Start-HUGroupLoad([string[]]$Keys) {
    $need = @($Keys | Where-Object { -not $script:GroupCache[$_] })
    if (-not $need.Count) { return }
    if (Test-HUJobRunning 'Groups') { return }
    [void](Start-HUJob -Name 'Groups' -Output $null -Vars @{ Need = $need } -Code {
            foreach ($k in $Need) {
                try { [pscustomobject]@{ Tenant = $k; Rows = @(Get-HUTenantGroups -TenantKey $k -Settings $Settings); Error = '' } }
                catch {
                    $m = $_.Exception.Message
                    if ($m -match '403|Forbidden|Authorization') { $m = 'Berechtigung Group.Read.All fehlt' }
                    [pscustomobject]@{ Tenant = $k; Rows = @(); Error = $m }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) {
                $script:GroupCache[$r.Tenant] = @{ Rows = @($r.Rows); Error = "$($r.Error)"; Time = Get-Date }
            }
            foreach ($e in @($Errors)) { if ($script:GP) { $script:GP.C.lblState.Text = "Fehler: $e" } }
            Update-HUGroupPickView
            # weitere Tenants (falls waehrend des Ladens angehakt)
            if ($script:GP) { Start-HUGroupLoad $script:GP.Keys }
        })
}

# Rueckgabe: Gruppenname oder $null (abgebrochen)
function Show-HUGroupPicker {
    param([string[]]$TenantKeys, [string]$Current = '', [string]$Title = 'Gruppe waehlen')
    if (-not @($TenantKeys).Count) { Show-HUMessage 'Bitte zuerst bei "Tenants" mindestens einen Tenant anhaken.' -Icon Warning; return $null }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="720" Height="560" MinWidth="480" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <TextBlock x:Name="lblInfo" DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <Button x:Name="btnReload" DockPanel.Dock="Right" Content="&#x21BB; Neu laden" Style="{StaticResource ToolButton}" FontSize="11" Padding="8,2" Margin="8,0,0,0"/>
            <CheckBox x:Name="chkAll" DockPanel.Dock="Right" Content="nur in allen Tenants" Style="{StaticResource DarkCheckBox}" VerticalAlignment="Center" Margin="10,0,0,0"/>
            <Grid>
                <TextBox x:Name="txtFilter" Style="{StaticResource DarkTextBox}" FontSize="12"/>
                <TextBlock x:Name="txtFilterHint" Text="Filtern (Name enthaelt ...)" Foreground="#666666" FontSize="12" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
        </DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="btnOk" Content="Uebernehmen" Width="120" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
                <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
            </StackPanel>
            <TextBlock x:Name="lblState" Foreground="#858585" FontSize="11" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" HeadersVisibility="Column">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Gruppe" Binding="{Binding Name}" Width="3*"/>
                <DataGridTextColumn Header="Typ" Binding="{Binding Typ}" Width="150"/>
                <DataGridTextColumn Header="Vorhanden" Binding="{Binding Vorhanden}" Width="90"/>
                <DataGridTextColumn Header="Fehlt in" Binding="{Binding Fehlt}" Width="2*"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = $Title
    $c.lblInfo.Text = "Gruppen aus: $(@($TenantKeys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', '). Zugewiesen wird je Tenant die Gruppe mit genau diesem Namen - fehlt sie in einem Tenant, meldet das Hochladen dort einen Fehler."
    $state = @{ Result = $null }
    $script:GP = @{ C = $c; Keys = @($TenantKeys); Current = $Current }
    $c.txtFilter.Add_TextChanged({
            $script:GP.C.txtFilterHint.Visibility = $(if ($script:GP.C.txtFilter.Text) { 'Collapsed' } else { 'Visible' })
            $script:GP.C.grid.SelectedItem = $null
            Update-HUGroupPickView
        })
    $c.chkAll.Add_Checked({ Update-HUGroupPickView })
    $c.chkAll.Add_Unchecked({ Update-HUGroupPickView })
    $c.btnReload.Add_Click({
            if (Test-HUJobRunning 'Groups') { return }
            foreach ($k in $script:GP.Keys) { $script:GroupCache.Remove($k) }
            Update-HUGroupPickView
            Start-HUGroupLoad $script:GP.Keys
        })
    $pick = {
        $it = $c.grid.SelectedItem
        if (-not $it) { return }
        $state.Result = "$($it.Name)"
        $w.Close()
    }
    $c.btnOk.Add_Click($pick)
    $c.grid.Add_MouseDoubleClick($pick)
    $c.btnCancel.Add_Click({ $w.Close() })
    # Pfeiltasten im Filterfeld bewegen die Auswahl
    $c.txtFilter.Add_PreviewKeyDown({
            param($s, $e)
            $g = $script:GP.C.grid
            $n = @($g.ItemsSource).Count
            if (-not $n) { return }
            if ("$($e.Key)" -eq 'Down') { $g.SelectedIndex = [Math]::Min($n - 1, $g.SelectedIndex + 1); $g.ScrollIntoView($g.SelectedItem); $e.Handled = $true }
            elseif ("$($e.Key)" -eq 'Up') { $g.SelectedIndex = [Math]::Max(0, $g.SelectedIndex - 1); $g.ScrollIntoView($g.SelectedItem); $e.Handled = $true }
        })
    $w.Add_ContentRendered({ $script:GP.C.txtFilter.Focus() | Out-Null; Update-HUGroupPickView; Start-HUGroupLoad $script:GP.Keys })
    try { [void]$w.ShowDialog() } finally { $script:GP = $null }
    return $state.Result
}
