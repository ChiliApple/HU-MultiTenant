#Requires -Version 5.1
<#
.SYNOPSIS
    "So geht's": kurze Rezepte je Bereich (Docs\SoGehts.json) in einem kleinen Fenster.
.DESCRIPTION
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
    Einheitlich fuer alle Bereiche:
      - Inhalt: Docs\SoGehts.json -> Bereiche.<bereich>.Rezepte (Titel, Kurz, Schritte, Achtung, Quellen)
      - Knopf je Schritt: Aktion = ID, die der Bereich mit Register-HURecipeAction anmeldet, oder url:https://...
      - Fenster: Show-HURecipeWindow '<bereich>' (nicht modal - man kann daneben weiterarbeiten)
#>

$script:HURecipeActions = @{}
$script:HURecipeWin = $null
$script:HURecipeCur = $null

# Bereich meldet eine Aktion an, z. B. Register-HURecipeAction 'wu.newRing' { Start-HUWuNew 'ring' }
function Register-HURecipeAction([string]$Id, [scriptblock]$Action) { $script:HURecipeActions[$Id] = $Action }

function Invoke-HURecipeAction([string]$Id) {
    if ($Id -like 'url:https://*') { Open-HUUrl $Id.Substring(4); return }
    if (-not $script:HURecipeActions.ContainsKey($Id)) { Show-HUMessage "Diese Aktion gibt es (noch) nicht: $Id" -Icon Info; return }
    try { & $script:HURecipeActions[$Id] } catch { Show-HUMessage "Aktion fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}

# Rezepte eines Bereichs lesen. Rueckgabe: @{ Titel; Stand; Rezepte } oder $null
function Get-HURecipes([string]$Area, [string]$Path = '') {
    if (-not $Path) { $Path = Join-Path $script:AppRoot 'Docs\SoGehts.json' }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $j = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ("$($j.Format)" -ne 'HU-SoGehts' -or -not $j.Bereiche.PSObject.Properties[$Area]) { return $null }
    $b = $j.Bereiche.$Area
    return [pscustomobject]@{ Titel = "$($b.Titel)"; Stand = "$($j.Stand)"; Rezepte = @($b.Rezepte) }
}

function Show-HURecipeWindow([string]$Area, [string]$SelectId = '') {
    $r = Get-HURecipes $Area
    if (-not $r -or -not @($r.Rezepte).Count) { Show-HUMessage 'Fuer diesen Bereich gibt es noch keine Anleitungen.' -Icon Info; return }
    # schon offen: nach vorne holen und Bereich wechseln
    if ($script:HURecipeWin -and $script:HURecipeWin.IsVisible) { try { $script:HURecipeWin.Close() } catch { } }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="600" MinWidth="640" MinHeight="380" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <Button x:Name="btnClose" DockPanel.Dock="Right" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
            <TextBlock x:Name="lblStand" Foreground="#888888" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="270" MinWidth="200"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <ListBox x:Name="lstRec" Style="{StaticResource DarkListBox}" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            <GridSplitter Grid.Column="1" Width="6" HorizontalAlignment="Stretch" Background="Transparent"/>
            <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" Margin="8,0,0,0">
                <StackPanel Margin="0,0,10,0">
                    <TextBlock x:Name="lblTitle" Foreground="White" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock x:Name="lblShort" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,4,0,12"/>
                    <StackPanel x:Name="spSteps"/>
                    <Border x:Name="bdWarn" BorderBrush="#FFB74D" BorderThickness="3,0,0,0" Background="#2A2418" Padding="10,8" Margin="0,8,0,0">
                        <StackPanel>
                            <TextBlock Text="Wirkt nicht, wenn &#x2026; / Achtung" Foreground="#FFB74D" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,4"/>
                            <StackPanel x:Name="spWarn"/>
                        </StackPanel>
                    </Border>
                    <TextBlock x:Name="lblSrcHead" Text="Quellen (Microsoft Learn)" Foreground="#AAAAAA" FontSize="11" Margin="0,12,0,4"/>
                    <StackPanel x:Name="spSrc"/>
                </StackPanel>
            </ScrollViewer>
        </Grid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window
    if ($script:Window) { $w.Owner = $script:Window }
    $w.Title = $r.Titel
    $script:HURecipeWin = $w
    $script:HURecipeCur = @{ C = $d.C; R = $r; Win = $w }
    $d.C.lblStand.Text = "Stand der Anleitungen: $($r.Stand). Knoepfe oeffnen die passende Stelle in der App - das Fenster bleibt offen."
    foreach ($rec in @($r.Rezepte)) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "$($rec.Titel)"; $tb.TextWrapping = 'Wrap'
        $li.Content = $tb; $li.Tag = "$($rec.Id)"; $li.Padding = [System.Windows.Thickness]::new(6, 5, 6, 5)
        [void]$d.C.lstRec.Items.Add($li)
    }
    $d.C.lstRec.Add_SelectionChanged({ $it = $script:HURecipeCur.C.lstRec.SelectedItem; if ($it) { Show-HURecipe "$($it.Tag)" } })
    $d.C.btnClose.Add_Click({ $script:HURecipeCur.Win.Close() })
    $w.Add_Closed({ $script:HURecipeWin = $null })
    $sel = 0
    if ($SelectId) { for ($i = 0; $i -lt $d.C.lstRec.Items.Count; $i++) { if ("$($d.C.lstRec.Items[$i].Tag)" -eq $SelectId) { $sel = $i } } }
    $d.C.lstRec.SelectedIndex = $sel
    $w.Show()
}

# Ein Rezept rechts anzeigen
function Show-HURecipe([string]$Id) {
    $c = $script:HURecipeCur.C
    $rec = @($script:HURecipeCur.R.Rezepte | Where-Object { "$($_.Id)" -eq $Id })[0]
    if (-not $rec) { return }
    $bc = New-Object System.Windows.Media.BrushConverter
    $c.lblTitle.Text = "$($rec.Titel)"; $c.lblShort.Text = "$($rec.Kurz)"
    $c.spSteps.Children.Clear(); $c.spWarn.Children.Clear(); $c.spSrc.Children.Clear()
    $n = 0
    foreach ($st in @($rec.Schritte)) {
        $n++
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        foreach ($wd in @([System.Windows.GridLength]::new(30), [System.Windows.GridLength]::new(1, 'Star'))) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $wd; [void]$g.ColumnDefinitions.Add($cd) }
        $num = New-Object System.Windows.Controls.Border
        $num.Width = 22; $num.Height = 22; $num.CornerRadius = [System.Windows.CornerRadius]::new(11); $num.Background = $bc.ConvertFromString('#1976D2'); $num.VerticalAlignment = 'Top'; $num.HorizontalAlignment = 'Left'
        $nt = New-Object System.Windows.Controls.TextBlock
        $nt.Text = "$n"; $nt.Foreground = $bc.ConvertFromString('#FFFFFF'); $nt.FontWeight = 'SemiBold'; $nt.HorizontalAlignment = 'Center'; $nt.VerticalAlignment = 'Center'; $nt.FontSize = 12
        $num.Child = $nt
        [void]$g.Children.Add($num)
        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        $tx = New-Object System.Windows.Controls.TextBlock
        $tx.Text = "$($st.Text)"; $tx.TextWrapping = 'Wrap'; $tx.FontSize = 13; $tx.Foreground = $bc.ConvertFromString('#E0E0E0')
        [void]$sp.Children.Add($tx)
        if ($st.PSObject.Properties['Aktion'] -and "$($st.Aktion)") {
            $b = New-Object System.Windows.Controls.Button
            $arrow = [char]0x2192
            $b.Content = $(if ($st.PSObject.Properties['Knopf'] -and "$($st.Knopf)") { "$arrow $($st.Knopf)" } else { "$arrow oeffnen" })
            $b.Style = $script:HURecipeCur.Win.FindResource('ToolButton'); $b.FontSize = 11; $b.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
            $b.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0); $b.HorizontalAlignment = 'Left'; $b.Tag = "$($st.Aktion)"
            $b.Add_Click({ param($s, $e) Invoke-HURecipeAction "$($s.Tag)" })
            [void]$sp.Children.Add($b)
        }
        [void]$g.Children.Add($sp)
        [void]$c.spSteps.Children.Add($g)
    }
    foreach ($a in @($rec.Achtung | Where-Object { $_ })) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = "$([char]0x2022)  $a"; $t.TextWrapping = 'Wrap'; $t.FontSize = 12; $t.Foreground = $bc.ConvertFromString('#E0E0E0'); $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)
        [void]$c.spWarn.Children.Add($t)
    }
    $c.bdWarn.Visibility = $(if ($c.spWarn.Children.Count) { 'Visible' } else { 'Collapsed' })
    foreach ($q in @($rec.Quellen | Where-Object { $_ })) {
        $lt = New-Object System.Windows.Controls.TextBlock
        $lt.Text = "$($q.Titel)"; $lt.ToolTip = "$($q.Url)"; $lt.Cursor = 'Hand'; $lt.TextDecorations = [System.Windows.TextDecorations]::Underline
        $lt.Foreground = $bc.ConvertFromString('#4FC3F7'); $lt.FontSize = 12; $lt.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4); $lt.Tag = "$($q.Url)"
        $lt.Add_MouseLeftButtonUp({ param($s, $e) Open-HUUrl "$($s.Tag)" })
        [void]$c.spSrc.Children.Add($lt)
    }
    $c.lblSrcHead.Visibility = $(if ($c.spSrc.Children.Count) { 'Visible' } else { 'Collapsed' })
}
