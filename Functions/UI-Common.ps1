#Requires -Version 5.1
<#
.SYNOPSIS
    Gemeinsame UI-Hilfen: XAML laden (mit Theme), Farben, Meldungen, Eingabe-Dialoge.
.NOTES
    Wird per Dot-Source aus Main.ps1 geladen (UI-Thread). Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:BrushConv = $null
function Get-HUBrush([string]$Color) {
    if (-not $script:BrushConv) { $script:BrushConv = [System.Windows.Media.BrushConverter]::new() }
    try { return $script:BrushConv.ConvertFromString($Color) } catch { return [System.Windows.Media.Brushes]::White }
}

# XAML-Datei aus XAML\ lesen und das Theme (XAML\Theme.xaml) an der Markierung <!--HU:THEME--> einsetzen.
function Get-HUXaml([string]$Name) {
    $dir = Join-Path $script:AppRoot 'XAML'
    $xaml = [System.IO.File]::ReadAllText((Join-Path $dir "$Name.xaml"), [System.Text.Encoding]::UTF8)
    if ($xaml.Contains('<!--HU:THEME-->')) {
        $theme = [System.IO.File]::ReadAllText((Join-Path $dir 'Theme.xaml'), [System.Text.Encoding]::UTF8)
        $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
        if (-not $m.Success) { throw 'XAML\Theme.xaml: ResourceDictionary nicht gefunden' }
        $xaml = $xaml.Replace('<!--HU:THEME-->', $m.Groups[1].Value)
    }
    return $xaml
}

# Fenster aus XAML erzeugen; liefert @{ Window = ...; C = @{ Name = Element } } mit allen x:Name-Elementen
function New-HUWindow([string]$Name, [string]$XamlText = '') {
    $x = if ($XamlText) { $XamlText } else { Get-HUXaml $Name }
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($x))
    try { $w = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $c = @{}
    foreach ($m in [regex]::Matches($x, 'x:Name="([A-Za-z0-9_]+)"')) {
        $n = $m.Groups[1].Value
        if ($c.ContainsKey($n)) { continue }
        $el = $w.FindName($n)
        if ($el) { $c[$n] = $el }
    }
    if ($script:Window -and $script:Window -ne $w -and $script:Window.IsLoaded) {
        try { $w.Owner = $script:Window; $w.WindowStartupLocation = 'CenterOwner' } catch { }
    }
    if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch { } }
    $script:LastDialog = $w
    return @{ Window = $w; C = $c }
}

function Show-HUMessage {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', [ValidateSet('Info', 'Warning', 'Error')][string]$Icon = 'Info', $Owner = $null)
    $img = switch ($Icon) { 'Warning' { 'Warning' } 'Error' { 'Error' } default { 'Information' } }
    $o = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $script:Window } else { $null }
    if ($o) { [void][System.Windows.MessageBox]::Show($o, $Text, $Title, 'OK', $img) }
    else { [void][System.Windows.MessageBox]::Show($Text, $Title, 'OK', $img) }
}

function Confirm-HU {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', [switch]$Warning, $Owner = $null)
    $img = if ($Warning) { 'Warning' } else { 'Question' }
    $o = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $script:Window } else { $null }
    $r = if ($o) { [System.Windows.MessageBox]::Show($o, $Text, $Title, 'YesNo', $img) } else { [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', $img) }
    return ("$r" -eq 'Yes')
}

# Ja / Nein / Abbrechen -> 'Yes' | 'No' | 'Cancel'
function Confirm-HUYesNoCancel {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', $Owner = $null)
    $o = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $script:Window } else { $null }
    $r = if ($o) { [System.Windows.MessageBox]::Show($o, $Text, $Title, 'YesNoCancel', 'Question') } else { [System.Windows.MessageBox]::Show($Text, $Title, 'YesNoCancel', 'Question') }
    return "$r"
}

# Kleiner Dialog: Name + Beschreibung (Snippet speichern unter / umbenennen). Rueckgabe $null = abgebrochen.
function Read-HUNameDescription {
    param([string]$Title = 'Snippet speichern', [string]$Name = '', [string]$Description = '', [string]$Hint = '', $Owner = $null)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock x:Name="lblHint" Style="{StaticResource HintText}" FontSize="11" Margin="0,0,0,10"/>
        <TextBlock Text="Name" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <TextBox x:Name="txtName" Style="{StaticResource DarkTextBox}" FontSize="12"/>
        <TextBlock Text="Kurzbeschreibung (erscheint in der Liste)" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <TextBox x:Name="txtDesc" Style="{StaticResource DarkTextBox}" FontSize="12" TextWrapping="Wrap" AcceptsReturn="False" MaxLength="300"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="OK" Width="90" Background="#4CAF50" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = $Title
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $c.txtName.Text = $Name
    $c.txtDesc.Text = $Description
    $c.lblHint.Text = $Hint
    if (-not $Hint) { $c.lblHint.Visibility = 'Collapsed' }
    $state = @{ Ok = $false }
    $c.btnOk.Add_Click({
        if (-not $c.txtName.Text.Trim()) { Show-HUMessage 'Bitte einen Namen eingeben.' -Icon Warning -Owner $w; return }
        $state.Ok = $true; $w.Close()
    })
    $w.Add_ContentRendered({ $c.txtName.Focus(); $c.txtName.SelectAll() })
    [void]$w.ShowDialog()
    if (-not $state.Ok) { return $null }
    return [pscustomobject]@{ Name = $c.txtName.Text.Trim(); Description = ($c.txtDesc.Text -replace '\s+', ' ').Trim() }
}

# Ordner/Datei im Explorer oeffnen (Browser/Explorer laeuft als angemeldeter Benutzer)
function Open-HUPath([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        Start-Process -FilePath explorer.exe -ArgumentList "`"$Path`""
    } catch { Write-HULogWarn "Oeffnen fehlgeschlagen: $($_.Exception.Message)" }
}
function Open-HUUrl([string]$Url) {
    try { Start-Process -FilePath explorer.exe -ArgumentList "`"$Url`"" } catch { try { Start-Process $Url } catch { } }
}

# JSON schreiben: erst in Temp-Datei, dann ersetzen (nie halb geschriebene Datei); optional Sicherung *.bak
function Write-HUJsonFile {
    param([string]$Path, $Object, [int]$Depth = 10, [switch]$Backup)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth $Depth
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    if ($Backup -and (Test-Path -LiteralPath $Path)) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-HUJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Rechtsklick-Menue fuer Ausgabefenster (RichTextBox): Kopieren, Alles kopieren, Ausgabe leeren
function Add-HUOutputMenu($RichTextBox, [scriptblock]$Clear) {
    $menu = New-Object System.Windows.Controls.ContextMenu
    $mkItem = {
        param([string]$Header, [string]$Gesture)
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $Header
        if ($Gesture) { $mi.InputGestureText = $Gesture }
        $mi
    }
    $miCopy = & $mkItem 'Kopieren' 'Strg+C'
    $miCopy.Add_Click({ $t = $this.Parent.PlacementTarget; if ($t) { $t.Copy() } })
    $miAll = & $mkItem 'Alles kopieren' ''
    $miAll.Add_Click({
            $t = $this.Parent.PlacementTarget
            if (-not $t) { return }
            $txt = (New-Object System.Windows.Documents.TextRange($t.Document.ContentStart, $t.Document.ContentEnd)).Text
            if ($txt.Trim()) { try { [System.Windows.Clipboard]::SetText($txt) } catch { } }
        })
    $miClear = & $mkItem 'Ausgabe leeren' ''
    $clearAction = $Clear
    $miClear.Add_Click({ & $clearAction }.GetNewClosure())
    [void]$menu.Items.Add($miCopy)
    [void]$menu.Items.Add($miAll)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$menu.Items.Add($miClear)
    $menu.Add_Opened({ $this.Items[0].IsEnabled = ($this.PlacementTarget -and -not $this.PlacementTarget.Selection.IsEmpty) })
    $RichTextBox.ContextMenu = $menu
}
