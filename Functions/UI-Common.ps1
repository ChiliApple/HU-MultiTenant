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
    # Tabellen: Spalten immer so breit wie der Inhalt - gilt fuer JEDE Tabelle im Programm (einmal registriert)
    try { Register-HUGridFit } catch { }
    # zusaetzlich direkt: alle Tabellen dieses Fensters (auch ohne Namen) - wirkt auch, falls der Klassen-Handler nicht greift
    try { foreach ($g in @(Get-HUDataGrids $w)) { Set-HUGridFit $g } }
    catch { try { Write-HULog -Message "Spaltenbreiten (Fenster): $($_.Exception.Message) (Zeile $($_.InvocationInfo.ScriptLineNumber))" -Level 'WARN' } catch { } }
    # jedes groessenveraenderbare Fenster mit sichtbarem Anfasser rechts unten
    try { if ($w.ResizeMode -eq [System.Windows.ResizeMode]::CanResize) { $w.ResizeMode = [System.Windows.ResizeMode]::CanResizeWithGrip } } catch { }
    $script:LastDialog = $w
    return @{ Window = $w; C = $c }
}

# Spaltenbreiten GLOBAL (Udo 24.10.): jede Text-Spalte jeder Tabelle ist so breit wie ihr Inhalt bzw. Kopf (+ Zellabstand
# 6/12 aus dem Theme) - nie abgeschnitten, nie aufgeblaeht. Feste Pixelbreiten und Stern-Breiten (Rest fuellen) werden
# zu "Auto". Greift ueber einen Klassen-Handler beim Laden jeder DataGrid und auch fuer Spalten, die der Code spaeter
# hinzufuegt (Breite wird danach im Hintergrund nachgezogen, damit eine im Code gesetzte Breite nicht gewinnt).
# Strict Mode: Variablen beim Laden anlegen
$script:HUGridFitRegistered = $false
$script:HUGridHookedList = New-Object System.Collections.ArrayList
$script:HUColsPending = New-Object System.Collections.ArrayList
function Set-HUColumnsFit($Columns) {
    try {
        $auto = New-Object System.Windows.Controls.DataGridLength(1, [System.Windows.Controls.DataGridLengthUnitType]::Auto)
        foreach ($col in @($Columns)) {
            if ($col -isnot [System.Windows.Controls.DataGridTextColumn]) { continue }
            if (-not $col.Width.IsAuto) { $col.Width = $auto }
        }
    } catch { try { Write-HULog -Message "Spaltenbreiten: $($_.Exception.Message) (Zeile $($_.InvocationInfo.ScriptLineNumber))" -Level 'WARN' } catch { } }
}
function Set-HUGridFit($Grid) {
    # darf NIE einen Fehler nach aussen geben (wird beim Laden jedes Fensters aufgerufen)
    try {
        if ($null -eq $Grid -or $Grid -isnot [System.Windows.Controls.DataGrid]) { return }
        Set-HUColumnsFit $Grid.Columns
        # jede Tabelle nur einmal verdrahten (Tag bleibt unberuehrt - den nutzen andere Fenster selbst)
        foreach ($h in $script:HUGridHookedList) { if ([object]::ReferenceEquals($h, $Grid)) { return } }
        [void]$script:HUGridHookedList.Add($Grid)
        # spaeter vom Code angelegte Spalten: Ereignis der Spaltenliste ueber .NET anhaengen
        # (PS 5.1 findet add_CollectionChanged an der Liste nicht und sucht dann an den einzelnen Spalten)
        $cols = $Grid.Columns
        $ev = $cols.GetType().GetEvent('CollectionChanged')
        if ($null -eq $ev) { return }
        $handler = [System.Collections.Specialized.NotifyCollectionChangedEventHandler] {
            param($s, $e)
            # erst nach dem Code, der die Spalte anlegt (der setzt evtl. noch eine Breite): im Hintergrund nachziehen
            try {
                if (-not $script:HUColsPending.Contains($s)) { [void]$script:HUColsPending.Add($s) }
                [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] {
                        try { $p = @($script:HUColsPending); $script:HUColsPending.Clear(); foreach ($x in $p) { Set-HUColumnsFit $x } } catch { }
                    })
            } catch { }
        }
        $ev.AddEventHandler($cols, $handler)
    } catch { try { Write-HULog -Message "Spaltenbreiten (Tabelle): $($_.Exception.Message) (Zeile $($_.InvocationInfo.ScriptLineNumber))" -Level 'WARN' } catch { } }
}
# alle DataGrids im logischen Baum eines Fensters/Elements
function Get-HUDataGrids($Root) {
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    if ($null -ne $Root) { $stack.Push($Root) }
    while ($stack.Count) {
        $n = $stack.Pop()
        if ($n -is [System.Windows.Controls.DataGrid]) { $out.Add($n) }
        if ($n -is [System.Windows.DependencyObject]) {
            try { foreach ($ch in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($ch -is [System.Windows.DependencyObject]) { $stack.Push($ch) } } } catch { }
        }
    }
    # ohne Komma: die Tabellen einzeln in die Pipeline (mit Komma + @() beim Aufrufer entstuende eine Liste in der Liste)
    return $out.ToArray()
}
function Register-HUGridFit {
    if ($script:HUGridFitRegistered) { return }
    $script:HUGridFitRegistered = $true
    try {
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.DataGrid], [System.Windows.FrameworkElement]::LoadedEvent,
            [System.Windows.RoutedEventHandler] { param($s, $e) Set-HUGridFit $s })
    } catch { try { Write-HULog -Message "Spaltenbreiten global: Registrieren fehlgeschlagen ($($_.Exception.Message))" -Level 'WARN' } catch { } }
    # GLOBAL: jedes groessenveraenderbare WPF-Fenster bekommt den sichtbaren Anfasser rechts unten (auch Fenster ausserhalb von New-HUWindow)
    # und die Oberflaechengroesse des Hauptfensters (Strg + Mausrad) gilt auch fuer alle weiteren Fenster
    try {
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Window], [System.Windows.FrameworkElement]::LoadedEvent,
            [System.Windows.RoutedEventHandler] { param($s, $e) try { if ($s.ResizeMode -eq [System.Windows.ResizeMode]::CanResize) { $s.ResizeMode = [System.Windows.ResizeMode]::CanResizeWithGrip } } catch { }; Set-HUWindowScale $s })
    } catch { }
}

# Aktuelle Oberflaechengroesse (1.0 = 100 %)
function Get-HUUiScaleValue {
    try { if ($script:UiScale -and [double]$script:UiScale -gt 0) { return [double]$script:UiScale } } catch { }
    return 1.0
}

# Oberflaechengroesse auf ein weiteres Fenster anwenden (Inhalt skalieren, feste Fenstergroesse mitwachsen lassen, im Bildschirm halten).
# Darf nie einen Fehler nach aussen geben (wird beim Laden jedes Fensters aufgerufen).
function Set-HUWindowScale($Window) {
    try {
        if ($null -eq $Window -or $Window -isnot [System.Windows.Window]) { return }
        if ($script:Window -and [object]::ReferenceEquals($Window, $script:Window)) { return }
        $sc = Get-HUUiScaleValue
        if ([Math]::Abs($sc - 1.0) -lt 0.01) { return }
        $ct = $Window.Content
        if ($ct -isnot [System.Windows.FrameworkElement]) { return }
        if ($ct.LayoutTransform -is [System.Windows.Media.ScaleTransform]) { return }
        $ct.LayoutTransform = [System.Windows.Media.ScaleTransform]::new($sc, $sc)
        $wa = [System.Windows.SystemParameters]::WorkArea
        $stc = "$($Window.SizeToContent)"
        if ($stc -notin 'Width', 'WidthAndHeight') {
            if ($Window.MinWidth -gt 0) { $Window.MinWidth = [Math]::Min($wa.Width * 0.9, $Window.MinWidth * $sc) }
            $cw = if (-not [double]::IsNaN($Window.Width)) { $Window.Width } else { $Window.ActualWidth }
            if ($cw -gt 0) { $Window.Width = [Math]::Min($wa.Width * 0.98, $cw * $sc) }
        }
        if ($stc -notin 'Height', 'WidthAndHeight') {
            if ($Window.MinHeight -gt 0) { $Window.MinHeight = [Math]::Min($wa.Height * 0.9, $Window.MinHeight * $sc) }
            $ch = if (-not [double]::IsNaN($Window.Height)) { $Window.Height } else { $Window.ActualHeight }
            if ($ch -gt 0) { $Window.Height = [Math]::Min($wa.Height * 0.98, $ch * $sc) }
        }
        # neu mittig ueber dem Besitzer (oder dem Bildschirm), immer ganz sichtbar
        $nw = if (-not [double]::IsNaN($Window.Width)) { $Window.Width } else { $Window.ActualWidth }
        $nh = if (-not [double]::IsNaN($Window.Height)) { $Window.Height } else { $Window.ActualHeight }
        $o = $Window.Owner
        $l = if ($o -and $o.IsLoaded -and $o.WindowState -eq 'Normal') { $o.Left + ($o.ActualWidth - $nw) / 2 } else { $wa.Left + ($wa.Width - $nw) / 2 }
        $t = if ($o -and $o.IsLoaded -and $o.WindowState -eq 'Normal') { $o.Top + ($o.ActualHeight - $nh) / 2 } else { $wa.Top + ($wa.Height - $nh) / 2 }
        $Window.Left = [Math]::Max($wa.Left, [Math]::Min($l, $wa.Right - $nw))
        $Window.Top = [Math]::Max($wa.Top, [Math]::Min($t, $wa.Bottom - $nh))
    } catch { try { Write-HULog -Message "Oberflaechengroesse (Fenster): $($_.Exception.Message)" -Level 'WARN' } catch { } }
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

# Hauptfenster nach vorne holen (z. B. wenn die Windows Sandbox davor liegt), damit Rueckfragen sichtbar sind
function Show-HUWindowFront($Window = $null) {
    $w = if ($Window) { $Window } else { $script:Window }
    if (-not $w) { return }
    try {
        if ($w.WindowState -eq [System.Windows.WindowState]::Minimized) { $w.WindowState = [System.Windows.WindowState]::Normal }
        $w.Topmost = $true
        [void]$w.Activate()
        $w.Topmost = $false
        [void]$w.Focus()
    } catch { }
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
    # Sicherung nur von einer gueltigen Datei (sonst ersetzt eine kaputte Datei die letzte gute Sicherung)
    if ($Backup -and (Test-Path -LiteralPath $Path) -and -not (Read-HUJsonFileChecked $Path).Error) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
# wie Read-HUJsonFile, unterscheidet aber 'fehlt' (Data $null, Error '') von 'nicht lesbar' (Error gesetzt)
function Read-HUJsonFileChecked([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Data = $null; Error = '' } }
    try {
        $txt = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not "$txt".Trim()) { return @{ Data = $null; Error = 'Datei ist leer' } }
        return @{ Data = ($txt | ConvertFrom-Json -ErrorAction Stop); Error = '' }
    } catch { return @{ Data = $null; Error = $_.Exception.Message } }
}

function Read-HUJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Rechtsklick-Menue fuer eine Liste: Eintraege @( @{ Header; Action; Enabled (scriptblock, optional) } )
# Ein Rechtsklick waehlt den Eintrag unter der Maus aus (WPF-ListBox), das Menue wirkt also auf ihn.
function Set-HUListMenu($ListBox, [object[]]$Entries) {
    $menu = New-Object System.Windows.Controls.ContextMenu
    foreach ($e in $Entries) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $e.Header
        $mi.Tag = $e
        $mi.Add_Click({ & $this.Tag.Action })
        [void]$menu.Items.Add($mi)
    }
    $menu.Add_Opened({
            foreach ($mi in $this.Items) { $mi.IsEnabled = [bool]$this.PlacementTarget.SelectedItem -and (-not $mi.Tag.Enabled -or [bool](& $mi.Tag.Enabled)) }
        })
    $ListBox.ContextMenu = $menu
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

# ----------------------------------------------------------------------------
# Windows Sandbox: Fenstergroesse und -position merken und beim naechsten Start wiederherstellen
# (die Sandbox selbst kennt dafuer keine Einstellung - daher ueber das Fenster)
# ----------------------------------------------------------------------------
$script:SbWinTimer = $null   # StrictMode: vor dem ersten Lesen setzen
$script:SbWin = $null

function Initialize-HUWin32Window {
    if ('HU.SbWin' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace HU {
    public static class SbWin {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        // sichtbare Hauptfenster, deren Titel den Text enthaelt -> "hwnd|pid|titel|klasse"
        public static List<string> Find(string part) {
            var res = new List<string>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                if (!IsWindowVisible(h)) return true;
                var t = new StringBuilder(256); GetWindowText(h, t, 256);
                if (t.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) < 0) return true;
                var c = new StringBuilder(256); GetClassName(h, c, 256);
                uint pid; GetWindowThreadProcessId(h, out pid);
                res.Add(h.ToInt64() + "|" + pid + "|" + t + "|" + c);
                return true;
            }, IntPtr.Zero);
            return res;
        }
    }
}
'@
}

# Sandbox-Fenster suchen: sichtbares Fenster mit "Sandbox" im Titel, das zu einem Sandbox-Prozess gehoert
function Get-HUSandboxWindow {
    $pids = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'WindowsSandbox*' -or $_.ProcessName -like 'vmconnect*' } | ForEach-Object { $_.Id })
    foreach ($e in @([HU.SbWin]::Find('Sandbox'))) {
        $f = $e -split '\|', 4
        if ($pids -contains [int]$f[1] -or $f[2] -match '^Windows[- ]Sandbox') {
            return [pscustomobject]@{ Hwnd = [IntPtr][long]$f[0]; Pid = [int]$f[1]; Title = $f[2]; Class = $f[3]; Proc = "$((Get-Process -Id ([int]$f[1]) -ErrorAction SilentlyContinue).ProcessName)" }
        }
    }
    return $null
}

function Start-HUSandboxWindowKeeper {
    try { Initialize-HUWin32Window } catch { return }
    $script:SbWin = @{ Started = Get-Date; Found = $null; Hwnd = [IntPtr]::Zero; Applied = 0; Last = '' }
    if (-not $script:SbWinTimer) {
        $script:SbWinTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:SbWinTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:SbWinTimer.Add_Tick({ try { Update-HUSandboxWindowKeeper } catch { $script:SbWinTimer.Stop() } })
    }
    $script:SbWinTimer.Start()
}

function Update-HUSandboxWindowKeeper {
    $s = $script:SbWin
    $wi = Get-HUSandboxWindow
    $h = if ($wi) { $wi.Hwnd } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) {
        # noch nicht da (max. 3 Min. warten) bzw. geschlossen
        if ($s.Found) { $script:SbWinTimer.Stop() }
        elseif (((Get-Date) - $s.Started).TotalMinutes -gt 3) {
            $script:SbWinTimer.Stop()
            $all = @([HU.SbWin]::Find('Sandbox') | ForEach-Object { ($_ -split '\|', 4)[2..3] -join ' / ' })
            Write-HULogWarn "Sandbox-Fenster nicht gefunden (Fenster mit 'Sandbox' im Titel: $(if ($all.Count) { $all -join '; ' } else { 'keine' }))"
        }
        return
    }
    if (-not $s.Found) {
        $s.Found = Get-Date; $s.Hwnd = $h
        Write-HULogInfo "Sandbox-Fenster gefunden: '$($wi.Title)' ($($wi.Proc), Klasse $($wi.Class))"
    }
    $age = ((Get-Date) - $s.Found).TotalSeconds
    $saved = Get-HUStateValue 'sandboxWindow' $null
    # die Sandbox passt ihr Fenster beim Hochfahren noch an - daher mehrmals setzen (sofort, nach 5 und nach 12 s)
    $due = @(0, 5, 12)
    if ($saved -and $s.Applied -lt $due.Count -and $age -ge $due[$s.Applied]) {
        $s.Applied++
        $x = [int]$saved.X; $y = [int]$saved.Y; $w = [int]$saved.W; $hh = [int]$saved.H
        $vis = [System.Windows.Forms.SystemInformation]::VirtualScreen
        if ($w -ge 800 -and $hh -ge 500 -and $x -lt $vis.Right - 50 -and $y -lt $vis.Bottom - 50 -and $x + $w -gt $vis.Left + 50 -and $y -gt $vis.Top - 50) {
            if ($saved.Max) { [void][HU.SbWin]::ShowWindow($h, 3) }
            else {
                [void][HU.SbWin]::ShowWindow($h, 9)
                $ok = [HU.SbWin]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $w, $hh, 0x0014)
                if (-not $ok) { $ok = [HU.SbWin]::MoveWindow($h, $x, $y, $w, $hh, $true) }
                if ($s.Applied -eq 1) { Write-HULogInfo "Sandbox-Fenster auf $x,$y ${w}x$hh gesetzt: $ok" }
            }
        }
        return
    }
    # danach die aktuelle Lage merken (auch wenn der Benutzer das Fenster verschiebt)
    if ($age -lt 15 -or [HU.SbWin]::IsIconic($h)) { return }
    $max = [HU.SbWin]::IsZoomed($h)
    $r = New-Object HU.SbWin+RECT
    if (-not [HU.SbWin]::GetWindowRect($h, [ref]$r)) { return }
    $cur = [pscustomobject]@{ X = $r.Left; Y = $r.Top; W = $r.Right - $r.Left; H = $r.Bottom - $r.Top; Max = [bool]$max }
    # Beim Herunterfahren zeigt die Sandbox ein kleines Fenster (ca. 620x320) - das nicht als Lage merken,
    # sonst startet die naechste Sandbox winzig (gespeicherte Lage wurde ueberschrieben)
    if (-not $max -and ($cur.W -lt 800 -or $cur.H -lt 500)) { return }
    if ($max -and $saved) { $cur.X = [int]$saved.X; $cur.Y = [int]$saved.Y; $cur.W = [int]$saved.W; $cur.H = [int]$saved.H }
    $key = "$($cur.X)|$($cur.Y)|$($cur.W)|$($cur.H)|$($cur.Max)"
    if ($key -ne $s.Last) {
        if (-not $s.Last) { Write-HULogInfo "Sandbox-Fenster: Lage wird gemerkt ($($cur.X),$($cur.Y) $($cur.W)x$($cur.H)$(if ($cur.Max) { ', maximiert' }))" }
        $s.Last = $key; Set-HUStateValue 'sandboxWindow' $cur; Save-HUUIState
    }
}
