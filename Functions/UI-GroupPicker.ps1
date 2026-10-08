#Requires -Version 5.1
<#
.SYNOPSIS
    Auswahl aus mehreren Tenants fuer Apps und Wartung: Gruppen (Ziel/Pilot) und vorhandene Win32-Apps
    in Intune (Abhaengigkeiten). Zeigt je Name, in wie vielen Tenants es ihn gibt - zugeordnet wird je Tenant per Name.
.NOTES
    Dot-Source aus Main.ps1. Ergebnisse werden je Tenant fuer die Sitzung zwischengespeichert (Knopf "Neu laden").
    Gruppen: Group.Read.All. Apps: DeviceManagementApps.Read(Write).All. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:GroupCache = @{}     # TenantKey -> @{ Rows = object[]; Error = ''; Time = datetime }
$script:W32Cache = @{}       # dto. fuer Win32-Apps
$script:GP = $null           # offenes Auswahlfenster

function Get-HUPickCache([string]$Kind) { if ($Kind -eq 'win32') { return $script:W32Cache }; return $script:GroupCache }

# Eintraege mehrerer Tenants -> eine Zeile je Name mit "in x von y Tenants"
function Get-HUPickRows([string]$Kind, [string[]]$Keys, [string]$Filter = '', [bool]$OnlyAll = $false, [string[]]$Exclude = @()) {
    $cache = Get-HUPickCache $Kind
    $map = @{}
    foreach ($k in $Keys) {
        $e = $cache[$k]
        if (-not $e) { continue }
        foreach ($g in @($e.Rows)) {
            $n = "$($g.Name)"
            if (-not $n -or @($Exclude) -contains $n) { continue }
            if (-not $map.ContainsKey($n.ToLower())) { $map[$n.ToLower()] = @{ Name = $n; Item = $g; Tenants = New-Object System.Collections.Generic.List[string] } }
            $t = $map[$n.ToLower()].Tenants
            if (-not $t.Contains($k)) { $t.Add($k) }
        }
    }
    $f = "$Filter".Trim()
    $rows = foreach ($v in $map.Values) {
        if ($f -and $v.Name -notlike "*$f*" -and "$($v.Item.Publisher)" -notlike "*$f*") { continue }
        $cnt = $v.Tenants.Count
        if ($OnlyAll -and $cnt -lt $Keys.Count) { continue }
        $missing = @($Keys | Where-Object { -not $v.Tenants.Contains($_) } | ForEach-Object { Get-HUTenantDisplayName $_ })
        [pscustomobject]@{
            Name      = $v.Name
            Typ       = $(if ($Kind -eq 'win32') { "$($v.Item.Version)" } else { "$($v.Item.Typ)" })
            Info      = $(if ($Kind -eq 'win32') { "$($v.Item.Publisher)" } else { '' })
            Vorhanden = $(if ($cnt -eq $Keys.Count) { "alle ($cnt)" } else { "$cnt von $($Keys.Count)" })
            Fehlt     = ($missing -join ', ')
            Sort      = $(if ($cnt -eq $Keys.Count) { 0 } else { 1 })
        }
    }
    return @($rows | Sort-Object Sort, Name)
}

# Kompatibel zu frueher (Smoke-Test)
function Get-HUGroupPickRows([string[]]$Keys, [string]$Filter = '', [bool]$OnlyAll = $false) { return Get-HUPickRows -Kind 'group' -Keys $Keys -Filter $Filter -OnlyAll $OnlyAll }

function Update-HUGroupPickView {
    $g = $script:GP
    if (-not $g) { return }
    $c = $g.C
    $cache = Get-HUPickCache $g.Kind
    $rows = @(Get-HUPickRows -Kind $g.Kind -Keys $g.Keys -Filter $c.txtFilter.Text -OnlyAll ([bool]$c.chkAll.IsChecked) -Exclude $g.Exclude)
    $c.grid.ItemsSource = $rows
    $loaded = @($g.Keys | Where-Object { $cache[$_] })
    $errs = @($g.Keys | Where-Object { $cache[$_] -and $cache[$_].Error } | ForEach-Object { "$(Get-HUTenantDisplayName $_): $($cache[$_].Error)" })
    $what = if ($g.Kind -eq 'win32') { 'App(s)' } else { 'Gruppe(n)' }
    $txt = if ($loaded.Count -lt $g.Keys.Count) { "Lade ... ($($loaded.Count) von $($g.Keys.Count) Tenants)" } else { "$($rows.Count) $what" }
    if ($errs.Count) { $txt += "  |  Fehler: " + ($errs -join '; ') }
    $c.lblState.Text = $txt
    $c.lblState.Foreground = Get-HUBrush $(if ($errs.Count) { '#FFB74D' } else { '#858585' })
    if ($rows.Count -and -not $c.grid.SelectedItem -and -not $g.Multi) {
        $cur = @($rows | Where-Object { $_.Name -eq $g.Current } | Select-Object -First 1)
        $c.grid.SelectedItem = $(if ($cur.Count) { $cur[0] } else { $rows[0] })
        if ($c.grid.SelectedItem) { $c.grid.ScrollIntoView($c.grid.SelectedItem) }
    }
}

function Start-HUGroupLoad([string[]]$Keys, [string]$Kind = 'group') {
    $cache = Get-HUPickCache $Kind
    $need = @($Keys | Where-Object { -not $cache[$_] })
    if (-not $need.Count) { return }
    $job = "Pick-$Kind"
    if (Test-HUJobRunning $job) { return }
    $script:GPLoadKind = $Kind
    [void](Start-HUJob -Name $job -Output $null -Vars @{ Need = $need; Kind = $Kind } -Code {
            foreach ($k in $Need) {
                try {
                    $rows = if ($Kind -eq 'win32') { @(Get-HUTenantWin32Apps -TenantKey $k -Settings $Settings) } else { @(Get-HUTenantGroups -TenantKey $k -Settings $Settings) }
                    [pscustomobject]@{ Tenant = $k; Rows = $rows; Error = '' }
                } catch {
                    $m = $_.Exception.Message
                    if ($m -match '403|Forbidden|Authorization') { $m = $(if ($Kind -eq 'win32') { 'Berechtigung DeviceManagementApps.ReadWrite.All fehlt' } else { 'Berechtigung Group.Read.All fehlt' }) }
                    [pscustomobject]@{ Tenant = $k; Rows = @(); Error = $m }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            $cache = Get-HUPickCache $script:GPLoadKind
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) {
                $cache[$r.Tenant] = @{ Rows = @($r.Rows); Error = "$($r.Error)"; Time = Get-Date }
            }
            foreach ($e in @($Errors)) { if ($script:GP) { $script:GP.C.lblState.Text = "Fehler: $e" } }
            Update-HUGroupPickView
            if ($script:GP -and $script:GP.Kind -eq $script:GPLoadKind) { Start-HUGroupLoad $script:GP.Keys $script:GP.Kind }
        })
}

# Rueckgabe: Name (oder bei -Multi Namen) bzw. $null (abgebrochen)
function Show-HUTenantPicker {
    param([ValidateSet('group', 'win32')][string]$Kind = 'group', [string[]]$TenantKeys, [string]$Current = '', [string]$Title = 'Auswaehlen',
        [string]$Info = '', [switch]$Multi, [string[]]$Exclude = @())
    if (-not @($TenantKeys).Count) { Show-HUMessage 'Bitte zuerst bei "Tenants" mindestens einen Tenant anhaken.' -Icon Warning; return $null }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="560" MinWidth="480" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
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
                <DataGridTextColumn x:Name="colName" Header="Name" Binding="{Binding Name}" Width="3*"/>
                <DataGridTextColumn x:Name="colTyp" Header="Typ" Binding="{Binding Typ}" Width="130"/>
                <DataGridTextColumn x:Name="colInfo" Header="Hersteller" Binding="{Binding Info}" Width="2*"/>
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
    $cols = $c.grid.Columns
    if ($Kind -eq 'win32') { $cols[0].Header = 'App'; $cols[1].Header = 'Version' }
    else { $cols[0].Header = 'Gruppe'; $cols[2].Visibility = 'Collapsed' }
    if ($Multi) { $c.grid.SelectionMode = 'Extended' }
    $tn = @($TenantKeys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', '
    $c.lblInfo.Text = $(if ($Info) { "$Info (aus: $tn)" } else { "Aus: $tn. Zugeordnet wird je Tenant per Name - fehlt der Eintrag in einem Tenant, meldet das Hochladen dort einen Fehler." })
    $state = @{ Result = $null }
    $script:GP = @{ C = $c; Keys = @($TenantKeys); Current = $Current; Kind = $Kind; Multi = [bool]$Multi; Exclude = @($Exclude) }
    $c.txtFilter.Add_TextChanged({
            $script:GP.C.txtFilterHint.Visibility = $(if ($script:GP.C.txtFilter.Text) { 'Collapsed' } else { 'Visible' })
            $script:GP.C.grid.SelectedItem = $null
            Update-HUGroupPickView
        })
    $c.chkAll.Add_Checked({ Update-HUGroupPickView })
    $c.chkAll.Add_Unchecked({ Update-HUGroupPickView })
    $c.btnReload.Add_Click({
            if (Test-HUJobRunning "Pick-$($script:GP.Kind)") { return }
            $cache = Get-HUPickCache $script:GP.Kind
            foreach ($k in $script:GP.Keys) { $cache.Remove($k) }
            Update-HUGroupPickView
            Start-HUGroupLoad $script:GP.Keys $script:GP.Kind
        })
    $pick = {
        $sel = @($c.grid.SelectedItems | ForEach-Object { "$($_.Name)" })
        if (-not $sel.Count) { return }
        $state.Result = $(if ($Multi) { $sel } else { $sel[0] })
        $w.Close()
    }
    $c.btnOk.Add_Click($pick)
    $c.grid.Add_MouseDoubleClick($pick)
    $c.btnCancel.Add_Click({ $w.Close() })
    $c.txtFilter.Add_PreviewKeyDown({
            param($s, $e)
            $g = $script:GP.C.grid
            $n = @($g.ItemsSource).Count
            if (-not $n) { return }
            if ("$($e.Key)" -eq 'Down') { $g.SelectedIndex = [Math]::Min($n - 1, $g.SelectedIndex + 1); $g.ScrollIntoView($g.SelectedItem); $e.Handled = $true }
            elseif ("$($e.Key)" -eq 'Up') { $g.SelectedIndex = [Math]::Max(0, $g.SelectedIndex - 1); $g.ScrollIntoView($g.SelectedItem); $e.Handled = $true }
        })
    $w.Add_ContentRendered({ $script:GP.C.txtFilter.Focus() | Out-Null; Update-HUGroupPickView; Start-HUGroupLoad $script:GP.Keys $script:GP.Kind })
    try { [void]$w.ShowDialog() } finally { $script:GP = $null }
    return $state.Result
}

function Show-HUGroupPicker {
    param([string[]]$TenantKeys, [string]$Current = '', [string]$Title = 'Gruppe waehlen')
    return Show-HUTenantPicker -Kind 'group' -TenantKeys $TenantKeys -Current $Current -Title $Title
}
