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

# Feste Knopfbreite -> Mindestbreite: in waagrechten StackPanels und WrapPanels (Knopfleisten) richtet sich der Knopf dann nach
# seinem Text. In Grids und DockPanels bleibt die Breite fest (dort wuerde der Knopf sonst die ganze Zelle fuellen).
function Set-HUButtonFit($Root) {
    if (-not $Root) { return }
    foreach ($ch in @([System.Windows.LogicalTreeHelper]::GetChildren($Root))) {
        if ($ch -isnot [System.Windows.DependencyObject]) { continue }
        if ($ch -is [System.Windows.Controls.Button] -and -not [double]::IsNaN($ch.Width)) {
            $p = $ch.Parent
            $row = (($p -is [System.Windows.Controls.StackPanel] -and $p.Orientation -eq 'Horizontal') -or $p -is [System.Windows.Controls.WrapPanel])
            if ($row) {
                $ch.MinWidth = [Math]::Max($ch.MinWidth, $ch.Width); $ch.Width = [double]::NaN
                if ($ch.Padding.Left -lt 10) { $ch.Padding = [System.Windows.Thickness]::new(12, $ch.Padding.Top, 12, $ch.Padding.Bottom) }
            }
        }
        Set-HUButtonFit $ch
    }
}

# ----------------------------------------------------------------------------
# 2.5.6 GLOBAL Ausgabefenster (RichTextBox, schreibgeschuetzt): Neuestes oben (Standard) oder unten.
# Merker im FlowDocument.Tag ('bottom' = klassisch unten) - so koennen auch Module (HU.Logging) ohne UI-Funktionen danach schreiben.
# ----------------------------------------------------------------------------
$script:HUOutputDone = New-Object System.Collections.ArrayList
$script:HUOutputClear = @{}
function Add-HUOutputBlock($Rtb, $Block, [int]$Max = 1500, [switch]$NoScroll) {
    if (-not $Rtb -or -not $Block) { return }
    $doc = $Rtb.Document
    if ("$($doc.Tag)" -eq 'bottom') {
        $doc.Blocks.Add($Block)
        while ($doc.Blocks.Count -gt $Max) { [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock) }
        if (-not $NoScroll) { $Rtb.ScrollToEnd() }
    } else {
        if ($doc.Blocks.FirstBlock) { $doc.Blocks.InsertBefore($doc.Blocks.FirstBlock, $Block) } else { $doc.Blocks.Add($Block) }
        while ($doc.Blocks.Count -gt $Max) { [void]$doc.Blocks.Remove($doc.Blocks.LastBlock) }
        if (-not $NoScroll) { $Rtb.ScrollToHome() }
    }
}
function Get-HUOutputStateKey($Rtb) { $n = "$($Rtb.Name)"; if ($n) { "outBottom_$n" } else { '' } }
function Switch-HUOutputOrder($Rtb) {
    $doc = $Rtb.Document
    $list = @($doc.Blocks)
    $doc.Blocks.Clear()
    for ($i = $list.Count - 1; $i -ge 0; $i--) { $doc.Blocks.Add($list[$i]) }
    $bottom = ("$($doc.Tag)" -ne 'bottom')
    $doc.Tag = $(if ($bottom) { 'bottom' } else { 'top' })
    $k = Get-HUOutputStateKey $Rtb
    if ($k) { try { Set-HUStateValue $k $(if ($bottom) { 'ja' } else { 'nein' }) } catch { } }
    if ($bottom) { $Rtb.ScrollToEnd() } else { $Rtb.ScrollToHome() }
}
function Clear-HUOutput($Rtb) {
    $n = "$($Rtb.Name)"
    if ($n -and $script:HUOutputClear.ContainsKey($n)) { & $script:HUOutputClear[$n] } else { $Rtb.Document.Blocks.Clear() }
}
# kleine Knoepfe "Umkehren" und "Loeschen" rechts oben in der Ausgabe
# Sucht in der Kopfzeile ueber der Ausgabe (Nachbar-Panel, hoechstens zwei Ebenen hoch) einen Knopf "Leeren"/"Ausgabe leeren"
# oder einen mit Tag 'HUOutputClear'. Rueckgabe @{ Button; Panel } oder $null.
function Find-HUOutputHeaderClear($Rtb) {
    $isClear = { param($b) $b -is [System.Windows.Controls.Button] -and ("$($b.Tag)" -eq 'HUOutputClear' -or "$($b.Content)" -match '^\s*(Ausgabe\s+)?leeren\s*$') }
    $child = $Rtb; $p = $Rtb.Parent
    for ($lvl = 0; $lvl -lt 2 -and $p -is [System.Windows.Controls.Panel]; $lvl++) {
        foreach ($sib in @($p.Children)) {
            if ([object]::ReferenceEquals($sib, $child) -or $sib -isnot [System.Windows.Controls.Panel]) { continue }
            $hits = @($sib.Children | Where-Object { & $isClear $_ })
            if ($hits.Count -eq 1) { return @{ Button = $hits[0]; Panel = $sib } }
        }
        $child = $p; $p = $p.Parent
        while ($p -and $p -isnot [System.Windows.Controls.Panel] -and $p -is [System.Windows.FrameworkElement]) { $child = $p; $p = $p.Parent }
    }
    return $null
}
function Add-HUOutputTools($Rtb) {
    if (-not $Rtb -or $Rtb -isnot [System.Windows.Controls.RichTextBox]) { return }
    foreach ($d in $script:HUOutputDone) { if ([object]::ReferenceEquals($d, $Rtb)) { return } }
    $p = $Rtb.Parent
    if (-not ($p -is [System.Windows.Controls.Panel] -or $p -is [System.Windows.Controls.Decorator])) { return }
    if ($p -is [System.Windows.Controls.Panel] -and $p.IsItemsHost) { return }
    [void]$script:HUOutputDone.Add($Rtb)
    # eigener "Leeren"-Knopf rechts oben ueber der Ausgabe (z. B. in Modulen) -> ausblenden, unser "Loeschen" loest ihn aus
    $old = $null
    if ($p -is [System.Windows.Controls.Panel]) {
        # Review 066 B1: nie einen fremden Loesch-Knopf treffen - nur ausdruecklich markiert (Tag 'HUOutputClear') oder
        # exakt "Leeren"/"Ausgabe leeren", rechts oben und in derselben Grid-Zelle wie die Ausgabe; hoechstens ein Knopf
        $cell = { param($e) "$([System.Windows.Controls.Grid]::GetRow($e))/$([System.Windows.Controls.Grid]::GetColumn($e))" }
        $cands = @(foreach ($sib in @($p.Children)) {
                if ($sib -isnot [System.Windows.Controls.Button]) { continue }
                if ("$($sib.Tag)" -eq 'HUOutputClear') { $sib; continue }
                if ("$($sib.HorizontalAlignment)" -eq 'Right' -and "$($sib.VerticalAlignment)" -eq 'Top' -and "$($sib.Content)" -match '^\s*(Ausgabe\s+)?leeren\s*$' -and (& $cell $sib) -eq (& $cell $Rtb)) { $sib }
            })
        if ($cands.Count -eq 1) { $old = $cands[0]; $old.Visibility = 'Collapsed' }
    }
    # Kopfzeile mit eigenem "Leeren" (z. B. Protokoll: Reports / Log-Ordner / Leeren) -> "Umkehren" dort daneben, nichts ueber der Ausgabe
    $head = $null
    if (-not $old) { $head = Find-HUOutputHeaderClear $Rtb }
    $k = Get-HUOutputStateKey $Rtb
    $bottom = $false
    if ($k) { try { $bottom = ("$(Get-HUStateValue $k 'nein')" -eq 'ja') } catch { } }
    $doc = $Rtb.Document
    if ($bottom) { $doc.Tag = 'bottom' } else {
        $doc.Tag = 'top'
        # schon vorhandener Inhalt (vor dem Einhaengen geschrieben) ebenfalls neuestes oben
        if ($doc.Blocks.Count -gt 1) { $list = @($doc.Blocks); $doc.Blocks.Clear(); for ($i = $list.Count - 1; $i -ge 0; $i--) { $doc.Blocks.Add($list[$i]) } }
    }
    if ($head) {
        $hb = $head.Button; $hp = $head.Panel
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $hb.Style; $b.Background = $hb.Background; $b.FontSize = $hb.FontSize; $b.Padding = $hb.Padding; $b.Cursor = 'Hand'
        $b.Content = [string][char]0x21C5 + ' Umkehren'; $b.ToolTip = 'Reihenfolge umkehren: neuestes oben oder unten (wird je Ausgabe gemerkt)'
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0); $b.VerticalAlignment = $hb.VerticalAlignment
        foreach ($dp in @([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Grid]::RowProperty, [System.Windows.Controls.Grid]::ColumnProperty)) {
            $v = $hb.ReadLocalValue($dp); if ($v -ne [System.Windows.DependencyProperty]::UnsetValue) { $b.SetValue($dp, $v) }
        }
        $b.Tag = $Rtb
        $b.Add_Click({ try { Switch-HUOutputOrder $this.Tag } catch { } })
        # direkt neben "Leeren" (links davon; bei DockPanel Right = danach einfuegen)
        $i = $hp.Children.IndexOf($hb)
        if ($hp -is [System.Windows.Controls.DockPanel] -and "$([System.Windows.Controls.DockPanel]::GetDock($hb))" -eq 'Right') { $hp.Children.Insert($i + 1, $b) } else { $hp.Children.Insert($i, $b) }
        return
    }
    # Huelle: Grid an der Stelle der Ausgabe, angehaengte Eigenschaften wandern mit
    $g = New-Object System.Windows.Controls.Grid
    $att = @([System.Windows.Controls.Grid]::RowProperty, [System.Windows.Controls.Grid]::ColumnProperty, [System.Windows.Controls.Grid]::RowSpanProperty,
        [System.Windows.Controls.Grid]::ColumnSpanProperty, [System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Panel]::ZIndexProperty)
    foreach ($dp in $att) {
        $v = $Rtb.ReadLocalValue($dp)
        if ($v -ne [System.Windows.DependencyProperty]::UnsetValue) { $g.SetValue($dp, $v); $Rtb.ClearValue($dp) }
    }
    if ($p -is [System.Windows.Controls.Panel]) {
        $idx = $p.Children.IndexOf($Rtb); $p.Children.RemoveAt($idx); [void]$g.Children.Add($Rtb); $p.Children.Insert($idx, $g)
    } else { $p.Child = $null; [void]$g.Children.Add($Rtb); $p.Child = $g }
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.VerticalAlignment = 'Top'
    $bar.Margin = [System.Windows.Thickness]::new(0, 3, 22, 0); $bar.Opacity = 0.55
    $bar.Add_MouseEnter({ $this.Opacity = 1 }); $bar.Add_MouseLeave({ $this.Opacity = 0.55 })
    $sty = $Rtb.TryFindResource('DarkButton')
    if (-not $sty -and $script:Window) { $sty = $script:Window.TryFindResource('DarkButton') }
    $mk = {
        param([string]$Text, [string]$Tip)
        $b = New-Object System.Windows.Controls.Button
        if ($sty) { $b.Style = $sty }
        $b.Content = $Text; $b.ToolTip = $Tip; $b.FontSize = 10; $b.Padding = [System.Windows.Thickness]::new(7, 1, 7, 1)
        $b.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0); $b.Background = Get-HUBrush '#3E3E42'; $b.Cursor = 'Hand'
        $b
    }
    $bRev = & $mk ([string][char]0x21C5 + ' Umkehren') 'Reihenfolge umkehren: neuestes oben oder unten (wird je Ausgabe gemerkt)'
    $bDel = & $mk ([string][char]0x2715 + ' L' + [char]0x00F6 + 'schen') 'Ausgabe leeren'
    $bRev.Tag = $Rtb; $bDel.Tag = [pscustomobject]@{ Rtb = $Rtb; Old = $old }
    $bRev.Add_Click({ try { Switch-HUOutputOrder $this.Tag } catch { } })
    $bDel.Add_Click({
            try {
                $t = $this.Tag
                if ($t.Old) {
                    # gebundenes Command ausfuehren (RaiseEvent loest es nicht aus), sonst Click
                    if ($t.Old.Command) { if ($t.Old.Command.CanExecute($t.Old.CommandParameter)) { $t.Old.Command.Execute($t.Old.CommandParameter) } }
                    else { $t.Old.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
                } else { Clear-HUOutput $t.Rtb }
            } catch { }
        })
    [void]$bar.Children.Add($bRev); [void]$bar.Children.Add($bDel)
    [void]$g.Children.Add($bar)
}
# alle schreibgeschuetzten Ausgaben unter $Root ausstatten (Hauptfenster, Fenster, Modul-Reiter)
function Set-HUOutputTools($Root) {
    if (-not $Root) { return }
    $todo = New-Object System.Collections.ArrayList
    $walk = {
        param($n)
        foreach ($ch in @([System.Windows.LogicalTreeHelper]::GetChildren($n))) {
            if ($ch -isnot [System.Windows.DependencyObject]) { continue }
            if ($ch -is [System.Windows.Controls.RichTextBox]) { if ($ch.IsReadOnly) { [void]$todo.Add($ch) }; continue }
            & $walk $ch
        }
    }
    & $walk $Root
    foreach ($r in $todo) { try { Add-HUOutputTools $r } catch { try { Write-HULog -Message "Ausgabe-Knoepfe: $($_.Exception.Message)" -Level 'WARN' } catch { } } }
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
    # 2.5.6 GLOBAL: Knoepfe mit fester Breite in Knopfleisten wachsen mit ihrer Beschriftung (nie abgeschnitten, auch wenn der Text spaeter wechselt)
    try { Set-HUButtonFit $w } catch { }
    # 2.5.6 GLOBAL: Ausgaben mit Umkehren/Loeschen, neuestes oben
    try { Set-HUOutputTools $w } catch { }
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
# Zeile "abweichend"? Spalte Unterschied/Abweichung/Status/Ergebnis (Objekte oder DataTable mit echtem Namen in Caption)
$script:HUDiffTintCols = @('Unterschied', 'Abweichung', 'Status', 'Ergebnis', 'Vergleich', 'Bewertung')
$script:HUDiffTintBrush = $null
function Test-HUDiffItem($Item) {
    if ($null -eq $Item) { return $false }
    $vals = @()
    if ($Item -is [System.Data.DataRowView]) {
        foreach ($col in $Item.Row.Table.Columns) { if ("$($col.Caption)" -in $script:HUDiffTintCols -or "$($col.ColumnName)" -in $script:HUDiffTintCols) { $vals += "$($Item.Row[$col])" } }
    } else {
        foreach ($n in $script:HUDiffTintCols) { $p = $Item.PSObject.Properties[$n]; if ($p) { $vals += "$($p.Value)" } }
    }
    # "abweichend" (Vergleiche, Bewertung) und "Abweichung" (Status im Sicherheitskatalog); "keine Abweichung" zaehlt nicht
    # Review 066 B6: jede Form von "abweich..." ausser verneint ("keine/ohne/nicht ...") oder mit Anzahl 0 ("Abweichung: 0", "0 Abweichungen")
    foreach ($v in $vals) {
        if ($v -match '(?i)abweich' -and $v -notmatch '(?i)\b(keine|kein|ohne|nicht)\s+abweich|abweich\w*\s*:\s*0\b|(^|\D)0\s+abweich') { return $true }
    }
    return $false
}
$script:HUTintQueue = New-Object System.Collections.ArrayList
$script:HUTintWarned = $false
function Set-HUDiffRowTint($Row, [switch]$Retry) {
    try {
        if ($null -eq $Row) { return }
        if ($null -eq $script:HUDiffTintBrush) { $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#3A321F')); $b.Freeze(); $script:HUDiffTintBrush = $b }
        # nur in Fenstern, die aufgehen (Detail/Ergebnis) - nicht im Hauptfenster (Udo 25.10.)
        $win = [System.Windows.Window]::GetWindow($Row)
        if ($null -eq $win) {
            # LoadingRow kommt, bevor die Zeile im Fenster haengt -> einmal nachholen, sobald sie geladen ist
            if (-not $Retry) {
                [void]$script:HUTintQueue.Add($Row)
                if ($script:HUTintQueue.Count -eq 1) {
                    [void]$Row.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Loaded, [System.Action]{
                            $q = @($script:HUTintQueue); $script:HUTintQueue.Clear()
                            foreach ($x in $q) { Set-HUDiffRowTint $x -Retry }
                        })
                }
            }
            return
        }
        if ($script:Window -and [object]::ReferenceEquals($win, $script:Window)) { return }
        if (Test-HUDiffItem $Row.Item) { $Row.Background = $script:HUDiffTintBrush }
        elseif ([object]::ReferenceEquals($Row.Background, $script:HUDiffTintBrush)) { $Row.ClearValue([System.Windows.Controls.Control]::BackgroundProperty) }
    } catch {
        if (-not $script:HUTintWarned) { $script:HUTintWarned = $true; try { Write-HULog -Message "Zeilenfaerbung: $($_.Exception.Message)" -Level 'WARN' } catch { } }
    }
}

function Set-HUGridFit($Grid) {
    # darf NIE einen Fehler nach aussen geben (wird beim Laden jedes Fensters aufgerufen)
    try {
        if ($null -eq $Grid -or $Grid -isnot [System.Windows.Controls.DataGrid]) { return }
        Set-HUColumnsFit $Grid.Columns
        # jede Tabelle nur einmal verdrahten (Tag bleibt unberuehrt - den nutzen andere Fenster selbst)
        foreach ($h in $script:HUGridHookedList) { if ([object]::ReferenceEquals($h, $Grid)) { return } }
        [void]$script:HUGridHookedList.Add($Grid)
        # GLOBAL (Udo 25.10.): in aufgehenden Fenstern Zeilen mit "abweichend" dezent einfaerben - beim Erzeugen jeder Zeile, auch wiederverwendete
        try {
            $Grid.Add_LoadingRow({ param($s, $e) Set-HUDiffRowTint $e.Row })
            foreach ($it in @($Grid.Items)) { $r = $Grid.ItemContainerGenerator.ContainerFromItem($it); if ($r) { Set-HUDiffRowTint $r } }
        } catch { }
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

# ---------------------------------------------------------------------------------------------
# Meldungen und Rueckfragen im App-Stil (2.5.9, Udo: global, sauber, Scrollbalken erst bei viel Text)
# Ersetzt die Windows-MessageBox; faellt nur zurueck, wenn das App-Design nicht ladbar ist (z. B. ganz am Start).
# Mode: OK | YesNo | YesNoCancel. Icon: Info | Warning | Error | Question. Rueckgabe: 'OK' | 'Yes' | 'No' | 'Cancel'.
# Schliessen (X, Esc): OK -> 'OK', YesNo -> 'No', YesNoCancel -> 'Cancel'.
# Warnung mit Ja/Nein: Enter = Nein (sicherer Standard), sonst Enter = OK bzw. Ja. Strg+C kopiert Titel und Text.
# ---------------------------------------------------------------------------------------------
$script:HUDlgTheme = $null
function Show-HUDialogBox {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', [ValidateSet('OK', 'YesNo', 'YesNoCancel')][string]$Mode = 'OK',
        [ValidateSet('Info', 'Warning', 'Error', 'Question')][string]$Icon = 'Info', $Owner = $null)
    $fallback = {
        $img = switch ($Icon) { 'Warning' { 'Warning' } 'Error' { 'Error' } 'Question' { 'Question' } default { 'Information' } }
        $o = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $script:Window } else { $null }
        # 072 G1: auch im Rueckfall bei Ja/Nein sicher "Nein" vorgewaehlt
        $def = $(switch ($Mode) { 'YesNo' { 'No' } 'YesNoCancel' { 'Cancel' } default { 'OK' } })
        $r = if ($o) { [System.Windows.MessageBox]::Show($o, $Text, $Title, $Mode, $img, $def) } else { [System.Windows.MessageBox]::Show($Text, $Title, $Mode, $img, $def) }
        return "$r"
    }
    try {
        if (-not $script:HUDlgTheme) {
            $theme = [System.IO.File]::ReadAllText((Join-Path (Join-Path $script:AppRoot 'XAML') 'Theme.xaml'), [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
            if (-not $m.Success) { return (& $fallback) }
            $script:HUDlgTheme = $m.Groups[1].Value
        }
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" MinWidth="440" MinHeight="170" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#1E1E1E" ShowInTaskbar="False" UseLayoutRounding="True">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Bottom" Background="#252526" BorderBrush="#3E3E42" BorderThickness="0,1,0,0" Padding="16,10">
            <StackPanel x:Name="pnlButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
        </Border>
        <Grid Margin="18,18,22,16">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid x:Name="icoBox" Width="34" Height="34" VerticalAlignment="Top" Margin="0,0,16,0">
                <Ellipse x:Name="icoCircle"/>
                <TextBlock x:Name="icoGlyph" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
            </Grid>
            <ScrollViewer x:Name="scroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" VerticalAlignment="Center">
                <TextBox x:Name="txt" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0" Background="Transparent" Foreground="#E0E0E0"
                         FontSize="13" Padding="0" Cursor="Arrow" IsTabStop="False" MinWidth="300"/>
            </ScrollViewer>
        </Grid>
    </DockPanel>
</Window>
'@
        $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $script:HUDlgTheme))
        $w = $d.Window; $c = $d.C
        $w.Title = $Title
        $o = if ($Owner) { $Owner } elseif ($script:Window -and $script:Window.IsLoaded) { $script:Window } else { $null }
        if ($o -and $o -ne $w) { try { $w.Owner = $o } catch { } } else { $w.WindowStartupLocation = 'CenterScreen'; $w.ShowInTaskbar = $true }
        $txt = "$Text".TrimEnd()
        $c.txt.Text = $txt
        # Breite nach Textmenge: kurze Meldungen kompakt, lange breiter (bessere Zeilen statt hoher schmaler Spalte)
        $len = $txt.Length; $lines = @($txt -split "`n").Count
        $c.txt.MaxWidth = $(if ($len -gt 1200 -or $lines -gt 24) { 760 } elseif ($len -gt 400) { 620 } else { 520 })
        # Scrollbalken erst, wenn der Text wirklich nicht mehr passt (65 % der Bildschirmhoehe)
        $wa = [System.Windows.SystemParameters]::WorkArea
        $c.scroll.MaxHeight = [Math]::Max(240, $wa.Height * 0.65)
        $ic = switch ($Icon) {
            'Warning' { @('#F57C00', '!') } 'Error' { @('#D32F2F', [string][char]0x2715) } 'Question' { @('#1976D2', '?') } default { @('#1976D2', 'i') }
        }
        $c.icoCircle.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFrom($ic[0])
        $c.icoGlyph.Text = $ic[1]
        # 072 G3: Screenreader - Fenster, Symbol und Text benennen; Knoepfe tragen die Meldung als Hilfetext
        $kind = switch ($Icon) { 'Warning' { 'Warnung' } 'Error' { 'Fehler' } 'Question' { 'Frage' } default { 'Hinweis' } }
        $ap = [System.Windows.Automation.AutomationProperties]
        $short = $(if ($txt.Length -gt 400) { $txt.Substring(0, 400) + ' ...' } else { $txt })
        $ap::SetName($w, "${kind}: $Title")
        $ap::SetName($c.icoBox, $kind)
        $ap::SetName($c.txt, $short)
        if ($Icon -eq 'Error') { $c.icoGlyph.FontSize = 16; $c.icoGlyph.Margin = [System.Windows.Thickness]::new(0) }
        $st = @{ R = $(switch ($Mode) { 'YesNo' { 'No' } 'YesNoCancel' { 'Cancel' } default { 'OK' } }) }
        $defs = @(switch ($Mode) {
            'YesNo' { @(@('Yes', 'Ja', $(if ($Icon -eq 'Warning') { '#C62828' } else { '#1976D2' })), @('No', 'Nein', '#555555')) }
            'YesNoCancel' { @(@('Yes', 'Ja', '#1976D2'), @('No', 'Nein', '#555555'), @('Cancel', 'Abbrechen', '#555555')) }
            default { , @('OK', 'OK', '#1976D2') }
        })
        $defaultKey = $(if ($Mode -eq 'YesNo' -and $Icon -eq 'Warning') { 'No' } elseif ($Mode -eq 'OK') { 'OK' } else { 'Yes' })
        $cancelKey = $(switch ($Mode) { 'YesNo' { 'No' } 'YesNoCancel' { 'Cancel' } default { 'OK' } })
        $first = $null
        foreach ($b in $defs) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = $b[1]; $btn.Tag = $b[0]; $btn.MinWidth = 96
            [System.Windows.Automation.AutomationProperties]::SetName($btn, $(if ($b[0] -eq $defaultKey -and $defs.Count -gt 1) { "$($b[1]) (Enter)" } else { "$($b[1])" }))
            [System.Windows.Automation.AutomationProperties]::SetHelpText($btn, $short); $btn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $btn.Style = $w.FindResource('DarkButton')
            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($b[2])
            if ($b[0] -eq $defaultKey) { $btn.IsDefault = $true; $first = $btn }
            if ($b[0] -eq $cancelKey) { $btn.IsCancel = $true }
            $btn.Add_Click({ param($sd, $e) $st.R = "$($sd.Tag)"; $w.Close() })
            if ($b[0] -eq $defaultKey -and $defs.Count -gt 1) {
                # vorgewaehlter Knopf (Enter) mit hellem Rahmen - man sieht auf einen Blick, was Enter ausloest
                $btn.Margin = [System.Windows.Thickness]::new(0)
                $fr = New-Object System.Windows.Controls.Border
                $fr.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#E0E0E0'); $fr.BorderThickness = [System.Windows.Thickness]::new(2)
                $fr.CornerRadius = [System.Windows.CornerRadius]::new(6); $fr.Padding = [System.Windows.Thickness]::new(1); $fr.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
                $fr.ToolTip = 'Enter'
                $fr.Child = $btn
                [void]$c.pnlButtons.Children.Add($fr)
            } else { [void]$c.pnlButtons.Children.Add($btn) }
        }
        $w.Add_KeyDown({
                param($sd, $e)
                if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and -not $c.txt.SelectionLength) {
                    try { [System.Windows.Clipboard]::SetText("$Title`r`n`r`n$($c.txt.Text)") } catch { }
                    $e.Handled = $true
                }
            })
        $w.Add_ContentRendered({ if ($first) { [void]$first.Focus() } })
        [void]$w.ShowDialog()
        return $st.R
    } catch {
        try { Write-HULog -Message "Meldungsfenster: $($_.Exception.Message) - Windows-Meldung verwendet" -Level 'WARN' } catch { }
        return (& $fallback)
    }
}

# ---------------------------------------------------------------------------------------------
# Hinweis unten rechts im App-Stil (2.5.9): fuer Ereignisse im Hintergrund (z. B. automatische App-Sicherung).
# Nimmt keinen Fokus, bleibt ueber anderen Fenstern, verschwindet von selbst (Fehler laenger); mehrere stapeln sich.
# -OnClick: Aktion beim Klick auf den Hinweis (schliesst ihn danach).
# ---------------------------------------------------------------------------------------------
$script:HUToasts = New-Object System.Collections.ArrayList
function Show-HUToast {
    param([string]$Title, [string]$Text = '', [ValidateSet('Info', 'Warning', 'Error', 'Success')][string]$Icon = 'Info', [int]$Seconds = 0, [scriptblock]$OnClick = $null)
    try {
        if (-not $script:HUDlgTheme) {
            $theme = [System.IO.File]::ReadAllText((Join-Path (Join-Path $script:AppRoot 'XAML') 'Theme.xaml'), [System.Text.Encoding]::UTF8)
            $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
            if ($m.Success) { $script:HUDlgTheme = $m.Groups[1].Value }
        }
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowActivated="False" ShowInTaskbar="False"
        ResizeMode="NoResize" SizeToContent="Height" Width="380" UseLayoutRounding="True">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <Border x:Name="box" Background="#252526" BorderBrush="#3E3E42" BorderThickness="1" CornerRadius="6" Margin="8" Cursor="Hand">
        <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.55"/></Border.Effect>
        <DockPanel>
            <Border x:Name="bar" DockPanel.Dock="Left" Width="4" CornerRadius="6,0,0,6"/>
            <Button x:Name="btnX" DockPanel.Dock="Right" Content="&#x2715;" VerticalAlignment="Top" Margin="0,6,6,0" Padding="6,2"
                    Background="Transparent" Foreground="#9E9E9E" BorderThickness="0" Cursor="Hand" FontSize="11" ToolTip="Schliessen"/>
            <Grid Margin="12,12,6,12">
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid Width="28" Height="28" VerticalAlignment="Top" Margin="0,0,12,0">
                    <Ellipse x:Name="icoCircle"/>
                    <TextBlock x:Name="icoGlyph" Foreground="White" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel Grid.Column="1">
                    <TextBlock x:Name="txtTitle" Foreground="White" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock x:Name="txtText" Foreground="#BDBDBD" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                    <TextBlock Text="HU-MultiTenant" Foreground="#707070" FontSize="10" Margin="0,6,0,0"/>
                </StackPanel>
            </Grid>
        </DockPanel>
    </Border>
</Window>
'@
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($x.Replace('<!--HU:THEME-->', "$($script:HUDlgTheme)")))
        try { $w = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
        $f = { param($n) $w.FindName($n) }
        $col = switch ($Icon) { 'Warning' { @('#F57C00', '!') } 'Error' { @('#D32F2F', [string][char]0x2715) } 'Success' { @('#388E3C', [string][char]0x2713) } default { @('#1976D2', 'i') } }
        $br = [System.Windows.Media.BrushConverter]::new().ConvertFrom($col[0])
        (& $f 'bar').Background = $br; (& $f 'icoCircle').Fill = $br; (& $f 'icoGlyph').Text = $col[1]
        (& $f 'txtTitle').Text = $Title
        $tt = & $f 'txtText'; if ($Text) { $tt.Text = $Text } else { $tt.Visibility = 'Collapsed' }
        if ($script:AppIcon) { try { $w.Icon = $script:AppIcon } catch { } }
        $st = @{ W = $w; Click = $OnClick; Timer = $null }
        $w.Tag = $st
        $close = {
            param($win)
            try { if ($win.Tag.Timer) { $win.Tag.Timer.Stop() } } catch { }
            [void]$script:HUToasts.Remove($win)
            try { $win.Close() } catch { }
            Update-HUToastPositions
        }
        $script:HUToastClose = $close
        (& $f 'btnX').Add_Click({ param($sd, $e) $e.Handled = $true; & $script:HUToastClose ([System.Windows.Window]::GetWindow($sd)) })
        (& $f 'box').Add_MouseLeftButtonUp({
                param($sd, $e)
                $win = [System.Windows.Window]::GetWindow($sd)
                $cb = $win.Tag.Click
                & $script:HUToastClose $win
                # gesperrte App: der Hinweis darf die Sperre nicht umgehen (kein Fenster oeffnen)
                $locked = $false; try { $locked = [bool](Get-Variable -Name LockActive -Scope Script -ValueOnly -ErrorAction SilentlyContinue) } catch { }
                if ($cb -and -not $locked) { try { & $cb } catch { } }
            })
        $secs = $(if ($Seconds -gt 0) { $Seconds } elseif ($Icon -in 'Error', 'Warning') { 20 } else { 8 })
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromSeconds($secs)
        $t.Tag = $w
        $t.Add_Tick({ $this.Stop(); & $script:HUToastClose $this.Tag })
        $st.Timer = $t
        # Maus darueber: nicht ausblenden
        $w.Add_MouseEnter({ try { $this.Tag.Timer.Stop() } catch { } })
        $w.Add_MouseLeave({ try { $this.Tag.Timer.Start() } catch { } })
        [void]$script:HUToasts.Add($w)
        $w.Left = -10000; $w.Top = -10000
        $w.Show()
        Update-HUToastPositions
        $t.Start()
    } catch { try { Write-HULog -Message "Hinweis unten rechts: $($_.Exception.Message)" -Level 'WARN' } catch { } }
}
# 071 B5: offene Hinweise schliessen (Beenden, Sperre)
function Close-HUToasts {
    foreach ($w in @($script:HUToasts)) { try { if ($w.Tag.Timer) { $w.Tag.Timer.Stop() } } catch { }; try { $w.Close() } catch { } }
    $script:HUToasts.Clear()
}
function Update-HUToastPositions {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $bottom = $wa.Bottom - 8
    foreach ($w in @($script:HUToasts)) {
        try {
            $w.Left = $wa.Right - $w.ActualWidth - 8
            $w.Top = $bottom - $w.ActualHeight
            $bottom = $w.Top
        } catch { }
    }
}

function Show-HUMessage {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', [ValidateSet('Info', 'Warning', 'Error')][string]$Icon = 'Info', $Owner = $null)
    [void](Show-HUDialogBox -Text $Text -Title $Title -Mode 'OK' -Icon $Icon -Owner $Owner)
}

function Confirm-HU {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', [switch]$Warning, $Owner = $null)
    return ((Show-HUDialogBox -Text $Text -Title $Title -Mode 'YesNo' -Icon $(if ($Warning) { 'Warning' } else { 'Question' }) -Owner $Owner) -eq 'Yes')
}

# Ja / Nein / Abbrechen -> 'Yes' | 'No' | 'Cancel'
function Confirm-HUYesNoCancel {
    param([string]$Text, [string]$Title = 'HU-MultiTenant', $Owner = $null)
    return (Show-HUDialogBox -Text $Text -Title $Title -Mode 'YesNoCancel' -Icon 'Question' -Owner $Owner)
}

# Kleiner Dialog: Name + Beschreibung (Snippet speichern unter / umbenennen). Rueckgabe $null = abgebrochen.
function Read-HUNameDescription {
    param([string]$Title = 'Snippet speichern', [string]$Name = '', [string]$Description = '', [string]$Hint = '', $Owner = $null)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" MinWidth="520" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
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
    if ("$($RichTextBox.Name)" -and $Clear) { $script:HUOutputClear["$($RichTextBox.Name)"] = $Clear }
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
