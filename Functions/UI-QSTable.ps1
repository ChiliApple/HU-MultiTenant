#Requires -Version 5.1
<#
.SYNOPSIS
    Quick Script: Objekt-Ausgaben als Tabelle (filtern, sortieren) mit Export nach CSV, Excel und Zwischenablage.
.DESCRIPTION
    Gibt ein Skript Objekte aus (z. B. [pscustomobject]@{ ... } oder Graph-Ergebnisse), werden sie gesammelt;
    der Knopf "Tabelle" zeigt sie an. Spalten = alle vorkommenden Eigenschaften (Reihenfolge des ersten Auftretens).
    Listen werden mit ", " verbunden, Datumswerte als yyyy-MM-dd HH:mm.
    Excel braucht das Modul ImportExcel (Install-Module ImportExcel -Scope CurrentUser), sonst nur CSV.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:QS_Objects = [System.Collections.Generic.List[object]]::new()

# Ist das ein "echtes" Objekt fuer die Tabelle? (keine Texte, Zahlen, Formatierungsobjekte)
function Test-HUQSTableObject($Obj) {
    if ($null -eq $Obj) { return $false }
    $b = if ($Obj -is [psobject]) { $Obj.PSObject.BaseObject } else { $Obj }
    if ($null -eq $b -or $b -is [string] -or $b.GetType().IsValueType -or $b -is [datetime]) { return $false }
    if ($b.GetType().FullName -like 'Microsoft.PowerShell.Commands.Internal.Format.*') { return $false }
    if ($b -is [System.Collections.IDictionary]) { return $true }
    return (@($Obj.PSObject.Properties).Count -gt 0)
}

function Format-HUQSCell($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd HH:mm') }
    if ($v -is [string]) { return $v }
    if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [System.Collections.IDictionary])) { return ((@($v) | ForEach-Object { Format-HUQSCell $_ }) -join ', ') }
    if ($v -is [psobject] -and $v.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
        return ((@($v.PSObject.Properties) | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
    }
    return "$v"
}

# Objekte -> flache Zeilen (geordnete Eigenschaften, alles Text) + Spaltenliste
function ConvertTo-HUQSRows([object[]]$Objects) {
    $cols = [System.Collections.Generic.List[string]]::new()
    $rows = foreach ($o in @($Objects)) {
        $pairs = if ($o -is [System.Collections.IDictionary]) { @($o.Keys | ForEach-Object { @{ N = "$_"; V = $o[$_] } }) }
                 else { @($o.PSObject.Properties | Where-Object { $_.MemberType -in 'NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty' } | ForEach-Object { @{ N = $_.Name; V = $(try { $_.Value } catch { $null }) } }) }
        $r = [ordered]@{}
        foreach ($p in $pairs) {
            if ($p.N -like '@odata.*') { continue }
            if (-not $cols.Contains($p.N)) { $cols.Add($p.N) }
            $r[$p.N] = Format-HUQSCell $p.V
        }
        $r
    }
    $flat = foreach ($r in @($rows)) {
        $o = [ordered]@{}
        foreach ($cn in $cols) { $o[$cn] = $(if ($r.Contains($cn)) { $r[$cn] } else { '' }) }
        [pscustomobject]$o
    }
    return [pscustomobject]@{ Columns = @($cols); Rows = @($flat) }
}

function Update-HUQSTableButton {
    $n = $script:QS_Objects.Count
    $b = $script:Controls['btnQSTable']
    $b.IsEnabled = ($n -gt 0)
    $b.Content = "$([char]::ConvertFromUtf32(0x1F4CA)) Tabelle$(if ($n) { " ($n)" })"
}

# -Objects: andere Quelle (Reiter Apps/Wartung), -FilePrefix: Vorschlag fuer den Dateinamen beim Export
function Show-HUQSTable([string]$Title = '', [object[]]$Objects = $null, [string]$FilePrefix = 'QuickScript') {
    $src = if ($null -ne $Objects) { @($Objects) } else { $script:QS_Objects.ToArray() }
    if (-not @($src).Count) { return }
    $data = ConvertTo-HUQSRows $src
    # DataTable mit sicheren Spaltennamen (Bindung verkraftet keine Punkte/Klammern); Kopfzeile zeigt den echten Namen
    $dt = New-Object System.Data.DataTable
    $map = [ordered]@{}
    $i = 0
    foreach ($cn in $data.Columns) {
        $safe = "c$i"; $i++
        $map[$safe] = $cn
        [void]$dt.Columns.Add($safe, [string])
    }
    foreach ($r in $data.Rows) {
        $row = $dt.NewRow()
        foreach ($safe in $map.Keys) { $row[$safe] = $r.($map[$safe]) }
        [void]$dt.Rows.Add($row)
    }

    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1100" Height="640" MinWidth="600" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="12">
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock x:Name="txtCount" DockPanel.Dock="Right" Foreground="#858585" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/>
            <Grid>
                <TextBox x:Name="txtFilter" Style="{StaticResource DarkTextBox}" FontSize="12"/>
                <TextBlock x:Name="txtFilterHint" Text="Filtern (alle Spalten) ..." Foreground="#666666" FontSize="12" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
        </DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <StackPanel Orientation="Horizontal">
                <Button x:Name="btnCsv" Content="CSV speichern ..." Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,6,0"
                        ToolTip="Semikolon-getrennt, UTF-8 - oeffnet direkt in Excel (Sicht: aktueller Filter)"/>
                <Button x:Name="btnXlsx" Content="Excel speichern ..." Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,6,0"
                        ToolTip="Mit Filter und fixierter Kopfzeile (Modul ImportExcel noetig)"/>
                <Button x:Name="btnCopy" Content="Kopieren" Style="{StaticResource ToolButton}" ToolTip="Sichtbare Zeilen mit Tabulator in die Zwischenablage (in Excel einfuegen)"/>
            </StackPanel>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" HorizontalAlignment="Right"/>
        </DockPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="True" SelectionMode="Extended"
                  CanUserSortColumns="True" CanUserReorderColumns="True" CanUserResizeColumns="True" ClipboardCopyMode="IncludeHeader"
                  EnableRowVirtualization="True" EnableColumnVirtualization="True"/>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = "Ergebnis$(if ($Title) { " - $Title" })"
    Restore-HUDialogState $w 'QSTable'
    $view = $dt.DefaultView
    $c.grid.Add_AutoGeneratingColumn({ param($s0, $e) $e.Column.Header = $map[$e.PropertyName]; $e.Column.MaxWidth = 600 })
    $c.grid.ItemsSource = $view
    $updCount = { $c.txtCount.Text = "$($view.Count) von $($dt.Rows.Count) Zeilen  |  $($map.Count) Spalten" }
    & $updCount
    $c.txtFilter.Add_TextChanged({
        $f = $c.txtFilter.Text
        $c.txtFilterHint.Visibility = $(if ($f) { 'Collapsed' } else { 'Visible' })
        if (-not $f) { $view.RowFilter = '' }
        else {
            $esc = $f -replace "'", "''" -replace '\[', '[[]' -replace '(?<!\[)\]', '[]]' -replace '\*', '[*]' -replace '%', '[%]'
            $view.RowFilter = (@($map.Keys | ForEach-Object { "[$_] LIKE '%$esc%'" }) -join ' OR ')
        }
        & $updCount
    })
    # sichtbare Zeilen (Filter + Sortierung) mit echten Spaltennamen
    $visible = {
        foreach ($rv in $view) {
            $o = [ordered]@{}
            foreach ($safe in $map.Keys) { $o[$map[$safe]] = "$($rv[$safe])" }
            [pscustomobject]$o
        }
    }
    $defaultName = "${FilePrefix}_$(if ($Title) { ($Title -replace '[\\/:*?"<>|]', '_') + '_' })$(Get-Date -Format 'yyyy-MM-dd_HHmm')"
    $reports = Get-HUReportsPath
    $c.btnCsv.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'CSV (Excel, Semikolon)|*.csv'
        $dlg.FileName = "$defaultName.csv"
        if (Test-Path -LiteralPath $reports) { $dlg.InitialDirectory = $reports }
        if (-not $dlg.ShowDialog($w)) { return }
        try {
            @(& $visible) | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
            Write-HULogOK "Tabelle gespeichert: $($dlg.FileName)"
            if (Confirm-HU "Gespeichert:`n$($dlg.FileName)`n`nJetzt oeffnen?" -Owner $w) { Open-HUUrl $dlg.FileName }
        } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error -Owner $w }
    })
    $c.btnXlsx.Add_Click({
        if (-not (Get-Command Export-Excel -ErrorAction SilentlyContinue)) {
            if (Get-Module -ListAvailable -Name ImportExcel) { Import-Module ImportExcel -DisableNameChecking }
            else { Show-HUMessage "Fuer Excel-Dateien wird das Modul ImportExcel gebraucht (Excel selbst nicht):`n`n  Install-Module ImportExcel -Scope CurrentUser`n`nBis dahin: CSV speichern (oeffnet ebenfalls in Excel)." 'Excel' -Icon Warning -Owner $w; return }
        }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Excel (*.xlsx)|*.xlsx'
        $dlg.FileName = "$defaultName.xlsx"
        if (Test-Path -LiteralPath $reports) { $dlg.InitialDirectory = $reports }
        if (-not $dlg.ShowDialog($w)) { return }
        try {
            if (Test-Path -LiteralPath $dlg.FileName) { Remove-Item -LiteralPath $dlg.FileName -Force }
            @(& $visible) | Export-Excel -Path $dlg.FileName -WorksheetName 'Ergebnis' -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow -TableStyle Medium2 -NoNumberConversion *
            Write-HULogOK "Tabelle gespeichert: $($dlg.FileName)"
            if (Confirm-HU "Gespeichert:`n$($dlg.FileName)`n`nJetzt oeffnen?" -Owner $w) { Open-HUUrl $dlg.FileName }
        } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error -Owner $w }
    })
    $c.btnCopy.Add_Click({
        $lines = @((@($map.Values) -join "`t"))
        foreach ($rv in $view) { $lines += (@($map.Keys | ForEach-Object { "$($rv[$_])" -replace "[`t`r`n]", ' ' }) -join "`t") }
        try { [System.Windows.Clipboard]::SetText(($lines -join "`r`n")); $c.txtCount.Text = "$($view.Count) Zeilen kopiert" } catch { }
    })
    $c.btnClose.Add_Click({ $w.Close() })
    $w.Add_Closing({ Save-HUDialogState $w 'QSTable' })
    $w.Add_ContentRendered({ $c.txtFilter.Focus() })
    [void]$w.ShowDialog()
}
