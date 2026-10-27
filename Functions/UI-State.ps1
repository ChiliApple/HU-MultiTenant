#Requires -Version 5.1
<#
.SYNOPSIS
    Fensterzustand merken: Position, Groesse, maximiert, Aufteilung (Splitter), Reiter, letzter Tenant, Oberflaechen-Groesse.
.DESCRIPTION
    Datei: %APPDATA%\HU-MultiTenant\ui-state.json (pro Windows-Benutzer, nicht im Programmordner).
    Wiederherstellung vor dem Anzeigen des Fensters: Position nur, wenn sie auf einem vorhandenen Bildschirm liegt.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:StateFilePath = [System.IO.Path]::Combine($env:APPDATA, 'HU-MultiTenant', 'ui-state.json')
$script:UIState = $null

function Get-HUUIState {
    if ($script:UIState) { return $script:UIState }
    $s = Read-HUJsonFile $script:StateFilePath
    if (-not $s) { $s = [pscustomobject]@{} }
    $script:UIState = $s
    return $s
}
function Get-HUStateValue([string]$Name, $Default = $null) {
    $s = Get-HUUIState
    if ($s.PSObject.Properties[$Name] -and $null -ne $s.$Name -and "$($s.$Name)" -ne '') { return $s.$Name }
    return $Default
}
function Set-HUStateValue([string]$Name, $Value) {
    $s = Get-HUUIState
    if ($s.PSObject.Properties[$Name]) { $s.$Name = $Value } else { $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Save-HUUIState {
    # 2.5.9: nach dem Wiederherstellen einer App-Sicherung nichts mehr aus dem Speicher zurueckschreiben (bis zum Neustart)
    if ((Get-Variable -Name AbRestored -Scope Script -ErrorAction SilentlyContinue).Value) { return }
    try { Write-HUJsonFile -Path $script:StateFilePath -Object (Get-HUUIState) -Depth 5 } catch { Write-Verbose "[UIState] Speichern fehlgeschlagen: $_" }
}

# Rechteck (WPF-Einheiten) liegt zumindest teilweise auf dem virtuellen Bildschirm (alle Monitore)?
function Test-HUOnScreen([double]$Left, [double]$Top, [double]$Width, [double]$Height) {
    $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vt = [System.Windows.SystemParameters]::VirtualScreenTop
    $vw = [System.Windows.SystemParameters]::VirtualScreenWidth
    $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
    # Titelleiste (obere 40 px, mittlere 100 px) muss erreichbar sein
    $cx = $Left + [Math]::Min(100, $Width / 2)
    return ($cx -ge $vl -and $cx -le ($vl + $vw - 20) -and $Top -ge ($vt - 10) -and ($Top + 40) -le ($vt + $vh))
}

# Anteil (0..1) einer Zeile/Spalte zwischen zwei Sternen in GridLength umsetzen
function Set-HUStarPair($First, $Second, [double]$Ratio) {
    if ($Ratio -le 0.05 -or $Ratio -ge 0.95) { return }
    $First.Height = [System.Windows.GridLength]::new($Ratio, 'Star')
    $Second.Height = [System.Windows.GridLength]::new(1 - $Ratio, 'Star')
}
function Get-HURatio([double]$A, [double]$B) {
    if (($A + $B) -le 0) { return 0 }
    return [Math]::Round($A / ($A + $B), 4)
}

function Restore-HUWindowState {
    $w = $script:Window
    $c = $script:Controls
    # alte Felder (v1.x) uebernehmen
    $left = Get-HUStateValue 'Left' (Get-HUStateValue 'windowLeft')
    $top = Get-HUStateValue 'Top' (Get-HUStateValue 'windowTop')
    $width = Get-HUStateValue 'Width' (Get-HUStateValue 'windowWidth')
    $height = Get-HUStateValue 'Height' (Get-HUStateValue 'windowHeight')
    try {
        if ($width -and $height) {
            $wa = [System.Windows.SystemParameters]::WorkArea
            $w.Width = [Math]::Max([double]$w.MinWidth, [Math]::Min([double]$width, [System.Windows.SystemParameters]::VirtualScreenWidth))
            $w.Height = [Math]::Max([double]$w.MinHeight, [Math]::Min([double]$height, [System.Windows.SystemParameters]::VirtualScreenHeight))
            if ($null -ne $left -and $null -ne $top -and (Test-HUOnScreen ([double]$left) ([double]$top) $w.Width $w.Height)) {
                $w.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
                $w.Left = [double]$left
                $w.Top = [double]$top
            } elseif ($w.Height -gt $wa.Height) { $w.Height = $wa.Height }
        }
        if ((Get-HUStateValue 'Maximized' $false) -eq $true) { $w.WindowState = [System.Windows.WindowState]::Maximized }
    } catch { Write-Verbose "[UIState] Fenster: $_" }

    try {
        $lw = Get-HUStateValue 'LeftWidth'
        if ($lw -and [double]$lw -ge 200) { $c['colLeft'].Width = [System.Windows.GridLength]::new([double]$lw); $script:LeftWidthSaved = [double]$lw }
        $r = Get-HUStateValue 'QSEditorRatio'
        if ($r) { Set-HUStarPair $c['rowQSEditor'] $c['rowQSOutput'] ([double]$r) }
        $r = Get-HUStateValue 'ExtDetailsRatio'
        if ($r) { Set-HUStarPair $c['rowExtDetails'] $c['rowExtLog'] ([double]$r) }
        # Reiter Apps / Wartung: Listenbreite und Aufteilung Formular/Ausgabe
        foreach ($p in @(@('Apps', 'colAppsLeft', 'rowAppsForm', 'rowAppsLog'), @('Rem', 'colRemLeft', 'rowRemForm', 'rowRemLog'))) {
            $w = Get-HUStateValue "$($p[0])LeftWidth"
            if ($w -and [double]$w -ge 150 -and $c[$p[1]]) { $c[$p[1]].Width = [System.Windows.GridLength]::new([double]$w) }
            $r = Get-HUStateValue "$($p[0])FormRatio"
            if ($r -and $c[$p[2]]) { Set-HUStarPair $c[$p[2]] $c[$p[3]] ([double]$r) }
        }
        $fs = Get-HUStateValue 'EditorFontSize'
        if ($fs -and [double]$fs -ge 8 -and [double]$fs -le 32) { $c['txtQSEditor'].FontSize = [double]$fs }
    } catch { Write-Verbose "[UIState] Aufteilung: $_" }

    Set-HUUiScale ([double](Get-HUStateValue 'UiScale' 1.0)) -NoSave
    try { Initialize-HUTabDrag } catch { Write-Verbose "[UIState] Reiter: $_" }
}

function Save-HUWindowState {
    $w = $script:Window
    $c = $script:Controls
    try {
        $isMax = ($w.WindowState -eq [System.Windows.WindowState]::Maximized)
        $rb = if ($w.WindowState -ne [System.Windows.WindowState]::Normal) { $w.RestoreBounds } else { [System.Windows.Rect]::new($w.Left, $w.Top, $w.Width, $w.Height) }
        if (-not $rb.IsEmpty -and $rb.Width -gt 100) {
            Set-HUStateValue 'Left' ([Math]::Round($rb.Left)); Set-HUStateValue 'Top' ([Math]::Round($rb.Top))
            Set-HUStateValue 'Width' ([Math]::Round($rb.Width)); Set-HUStateValue 'Height' ([Math]::Round($rb.Height))
        }
        Set-HUStateValue 'Maximized' $isMax
        foreach ($old in @('windowLeft', 'windowTop', 'windowWidth', 'windowHeight')) { if ($script:UIState.PSObject.Properties[$old]) { $script:UIState.PSObject.Properties.Remove($old) } }
        $lw = if ($script:LeftHidden) { $script:LeftWidthSaved } else { $c['colLeft'].ActualWidth }
        if ($lw -ge 200) { Set-HUStateValue 'LeftWidth' ([Math]::Round($lw)) }
        $r = Get-HURatio $c['rowQSEditor'].ActualHeight $c['rowQSOutput'].ActualHeight
        if ($r) { Set-HUStateValue 'QSEditorRatio' $r }
        $r = Get-HURatio $c['rowExtDetails'].ActualHeight $c['rowExtLog'].ActualHeight
        if ($r) { Set-HUStateValue 'ExtDetailsRatio' $r }
        foreach ($p in @(@('Apps', 'colAppsLeft', 'rowAppsForm', 'rowAppsLog'), @('Rem', 'colRemLeft', 'rowRemForm', 'rowRemLog'))) {
            if (-not $c[$p[1]]) { continue }
            # nur gemessene Werte speichern (Reiter war sichtbar)
            if ($c[$p[1]].ActualWidth -ge 150) { Set-HUStateValue "$($p[0])LeftWidth" ([Math]::Round($c[$p[1]].ActualWidth)) }
            $r = Get-HURatio $c[$p[2]].ActualHeight $c[$p[3]].ActualHeight
            if ($r) { Set-HUStateValue "$($p[0])FormRatio" $r }
        }
        Set-HUStateValue 'EditorFontSize' $c['txtQSEditor'].FontSize
        $sel = $c['tabMain'].SelectedItem
        $last = if ($sel -eq $c['tabExtensions']) { 'Extensions' } elseif ($sel -eq $c['tabApps']) { 'Apps' } elseif ($sel -eq $c['tabMaint']) { 'Wartung' } elseif ($sel -eq $c['tabAnalyse']) { 'Analyse' } elseif ($sel -eq $c['tabTeams']) { 'Teams' } elseif ($sel -eq $c['tabMuster']) { 'Muster' } elseif ($sel -and "$($sel.Tag)" -eq 'addon' -and "$($sel.Name)") { "$($sel.Name)" } else { 'QuickScript' }
        Set-HUStateValue 'LastTab' $last
    } catch { Write-Verbose "[UIState] Erfassen: $_" }
    Save-HUUIState
}

# Oberflaechen-Groesse (Strg + Mausrad, Strg + 0) - skaliert den gesamten Fensterinhalt
function Set-HUUiScale([double]$Scale, [switch]$NoSave) {
    $Scale = [Math]::Round([Math]::Max(0.8, [Math]::Min(1.6, $Scale)), 2)
    $script:UiScale = $Scale
    $root = $script:Controls['rootPanel']
    if ($root) { $root.LayoutTransform = [System.Windows.Media.ScaleTransform]::new($Scale, $Scale) }
    if (-not $NoSave) { Set-HUStateValue 'UiScale' $Scale }
}

# ============================================================================
# Reiter verschieben (Ziehen mit der Maus), Reihenfolge in ui-state.json (TabOrder = x:Name der Reiter)
# ============================================================================
$script:HUTabDefault = @()

# Reine Funktion: gespeicherte Reihenfolge auf die vorhandenen Reiter anwenden.
# Unbekannte Namen fallen weg, neue Reiter (spaetere Versionen) kommen an ihrer Standardstelle hinten dazu.
function Get-HUTabOrder([string[]]$Saved, [string[]]$Current) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Saved)) { if ($n -and $Current -contains $n -and -not $out.Contains($n)) { $out.Add($n) } }
    foreach ($n in @($Current)) { if (-not $out.Contains($n)) { $out.Add($n) } }
    return @($out.ToArray())
}

function Set-HUTabOrder([string[]]$Names) {
    $tc = $script:Controls['tabMain']
    if (-not $tc) { return }
    $sel = $tc.SelectedItem
    $items = @($tc.Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] })
    $order = Get-HUTabOrder -Saved $Names -Current @($items | ForEach-Object { "$($_.Name)" })
    $i = 0
    foreach ($n in $order) {
        $t = @($items | Where-Object { "$($_.Name)" -eq $n })[0]
        if (-not $t) { continue }
        if ($tc.Items.IndexOf($t) -ne $i) { $tc.Items.Remove($t); [void]$tc.Items.Insert($i, $t) }
        $i++
    }
    if ($sel) { $tc.SelectedItem = $sel }
}

function Save-HUTabOrder {
    $names = @($script:Controls['tabMain'].Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] } | ForEach-Object { "$($_.Name)" })
    if (($names -join ',') -eq ($script:HUTabDefault -join ',')) {
        $s = Get-HUUIState; if ($s.PSObject.Properties['TabOrder']) { $s.PSObject.Properties.Remove('TabOrder') }
    } else { Set-HUStateValue 'TabOrder' $names }
    Save-HUUIState
}

function Initialize-HUTabDrag {
    $tc = $script:Controls['tabMain']
    if (-not $tc) { return }
    $script:HUTabDefault = @($tc.Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] } | ForEach-Object { "$($_.Name)" })
    try { $saved = @(Get-HUStateValue 'TabOrder' @()); if ($saved.Count) { Set-HUTabOrder -Names $saved } } catch { Write-Verbose "[UIState] Reiter-Reihenfolge: $_" }
    $script:HUTabDragStart = $null; $script:HUTabDragItem = $null
    foreach ($t in @($tc.Items | Where-Object { $_ -is [System.Windows.Controls.TabItem] })) {
        $t.AllowDrop = $true
        if (-not $t.ToolTip) { $t.ToolTip = 'Reiter mit der Maus an eine andere Stelle ziehen; Rechtsklick: Reihenfolge zuruecksetzen' }
        $t.Add_PreviewMouseLeftButtonDown({
                param($s, $e)
                # nur auf dem Reiter-Kopf ziehen - Klicks im Inhalt (Scrollbalken, Tabellen) nicht abfangen
                $script:HUTabDragItem = $null; $script:HUTabDragStart = $null
                $p = $e.GetPosition($s)
                if ($p.X -lt 0 -or $p.Y -lt 0 -or $p.X -gt $s.ActualWidth -or $p.Y -gt $s.ActualHeight) { return }
                $script:HUTabDragStart = $e.GetPosition($null); $script:HUTabDragItem = $s
            })
        $t.Add_PreviewMouseLeftButtonUp({ $script:HUTabDragItem = $null; $script:HUTabDragStart = $null })
        $t.Add_PreviewMouseMove({
                param($s, $e)
                if ($e.LeftButton -ne 'Pressed' -or -not $script:HUTabDragItem -or $null -eq $script:HUTabDragStart) { return }
                $p = $e.GetPosition($null)
                if ([Math]::Abs($p.X - $script:HUTabDragStart.X) -lt [System.Windows.SystemParameters]::MinimumHorizontalDragDistance -and
                    [Math]::Abs($p.Y - $script:HUTabDragStart.Y) -lt [System.Windows.SystemParameters]::MinimumVerticalDragDistance) { return }
                $src = $script:HUTabDragItem; $script:HUTabDragItem = $null; $script:HUTabDragStart = $null
                try { [void][System.Windows.DragDrop]::DoDragDrop($src, $src, [System.Windows.DragDropEffects]::Move) } catch { Write-Verbose "[UIState] Ziehen: $_" }
            })
        $t.Add_Drop({
                param($s, $e)
                try {
                    $src = $e.Data.GetData([System.Windows.Controls.TabItem])
                    if (-not $src -or $src -eq $s) { return }
                    $tcm = $script:Controls['tabMain']
                    $idx = $tcm.Items.IndexOf($s)
                    $tcm.Items.Remove($src); [void]$tcm.Items.Insert($idx, $src)
                    $tcm.SelectedItem = $src
                    Save-HUTabOrder
                } catch { Write-Verbose "[UIState] Ablegen: $_" }
            })
        $cm = New-Object System.Windows.Controls.ContextMenu
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'Reiter-Reihenfolge zuruecksetzen'
        $mi.Add_Click({ Set-HUTabOrder -Names $script:HUTabDefault; Save-HUTabOrder })
        [void]$cm.Items.Add($mi)
        $t.ContextMenu = $cm
    }
}

# Start-Reiter: Einstellung ui.startTab = QuickScript (Standard) | Extensions | Last
function Select-HUStartTab {
    $mode = 'QuickScript'
    try { if ($script:Settings.ui.PSObject.Properties['startTab'] -and "$($script:Settings.ui.startTab)") { $mode = "$($script:Settings.ui.startTab)" } } catch { }
    if ($mode -eq 'Last') { $mode = Get-HUStateValue 'LastTab' 'QuickScript' }
    $tab = switch ($mode) { 'Extensions' { 'tabExtensions' } 'Apps' { 'tabApps' } 'Wartung' { 'tabMaint' } 'Analyse' { 'tabAnalyse' } 'Teams' { 'tabTeams' } 'Muster' { 'tabMuster' } default { 'tabQuickScript' } }
    # Reiter eines Zusatzmoduls (gespeichert mit seinem Namen) - nur wenn das Modul geladen ist
    if ($mode -like 'tab*' -and $script:Controls[$mode] -and "$($script:Controls[$mode].Tag)" -eq 'addon') { $tab = $mode }
    $script:Controls['tabMain'].SelectedItem = $script:Controls[$tab]
    Update-HULeftPanel
}

# Extension-Liste links nur dort zeigen, wo sie gebraucht wird (nicht in Apps/Wartung - mehr Platz)
$script:LeftHidden = $false
$script:LeftWidthSaved = 320.0
function Update-HULeftPanel {
    $c = $script:Controls
    $sel = $c['tabMain'].SelectedItem
    # Tenant-Leiste (Verbinden/Trennen) gilt nur fuer Extensions - Quick Script, Apps und Wartung waehlen Tenants selbst
    $c['pnlTenantBar'].Visibility = $(if ($sel -eq $c['tabExtensions']) { 'Visible' } else { 'Collapsed' })
    $hide = ($sel -eq $c['tabApps'] -or $sel -eq $c['tabMaint'] -or $sel -eq $c['tabAnalyse'] -or $sel -eq $c['tabTeams'] -or $sel -eq $c['tabMuster'] -or ($sel -and "$($sel.Tag)" -eq 'addon'))
    if ($hide -eq $script:LeftHidden) { Update-HUMainOverlay; return }
    if ($hide) {
        if ($c['colLeft'].ActualWidth -ge 200) { $script:LeftWidthSaved = $c['colLeft'].ActualWidth }
        $c['colLeft'].MinWidth = 0
        $c['colLeft'].Width = [System.Windows.GridLength]::new(0)
        $c['colSplit'].Width = [System.Windows.GridLength]::new(0)
        $c['pnlLeft'].Visibility = 'Collapsed'; $c['splLeft'].Visibility = 'Collapsed'
    } else {
        $c['pnlLeft'].Visibility = 'Visible'; $c['splLeft'].Visibility = 'Visible'
        $c['colSplit'].Width = [System.Windows.GridLength]::new(8)
        $c['colLeft'].Width = [System.Windows.GridLength]::new([Math]::Max(200, $script:LeftWidthSaved))
        $c['colLeft'].MinWidth = 200
    }
    $script:LeftHidden = $hide
    Update-HUMainOverlay
}

# Reiterleiste immer an derselben Stelle: Tenant-Leiste und Extension-Liste liegen ueber dem Inhaltsbereich der Reiter.
# Hier werden ihre Abstaende gesetzt (unter der Reiterleiste) und der Inhalt der Reiter entsprechend eingerueckt.
function Update-HUMainOverlay {
    $c = $script:Controls
    $tm = $c['tabMain']; if (-not $tm) { return }
    # Unterkante der Reiterleiste (auch bei zweizeiliger Leiste): unterster Reiterkopf
    $hh = 0.0
    foreach ($ti in @($tm.Items)) {
        if (-not ($ti -is [System.Windows.Controls.TabItem]) -or $ti.Visibility -ne 'Visible' -or $ti.ActualHeight -le 0) { continue }
        try { $y = $ti.TranslatePoint((New-Object System.Windows.Point 0, $ti.ActualHeight), $tm).Y; if ($y -gt $hh) { $hh = $y } } catch { }
    }
    if ($hh -le 0) { $hh = 32.0 }
    $tbOn = ($c['pnlTenantBar'].Visibility -eq 'Visible')
    $tb = 0.0
    if ($tbOn) { $tb = $c['pnlTenantBar'].ActualHeight; if ($tb -le 0) { $c['pnlTenantBar'].Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity))); $tb = $c['pnlTenantBar'].DesiredSize.Height }; $tb += 8 }
    $c['pnlTenantBar'].Margin = New-Object System.Windows.Thickness 0, ($hh + 8), 0, 0
    $top = $hh + 8 + $tb
    $c['pnlLeft'].Margin = New-Object System.Windows.Thickness 0, $top, 0, 0
    $c['splLeft'].Margin = New-Object System.Windows.Thickness 0, $top, 0, 0
    $left = if ($script:LeftHidden) { 0.0 } else { $c['colLeft'].ActualWidth + $c['colSplit'].ActualWidth }
    if (-not $script:LeftHidden -and $left -lt 200) { $left = [Math]::Max(200, $script:LeftWidthSaved) + 8 }
    $tm.Padding = New-Object System.Windows.Thickness $left, $tb, 0, 0
}

# Unterfenster (z. B. Snippet-Verwaltung): Groesse/Position merken
function Restore-HUDialogState($Window, [string]$Key) {
    $g = Get-HUStateValue $Key
    if (-not $g) { return }
    try {
        # gespeichert wird die Groesse OHNE Oberflaechengroesse (Set-HUWindowScale skaliert beim Laden) - sonst waechst das Fenster bei
        # jedem Oeffnen um den Faktor (Udo 25.10.). Alte, schon skalierte Werte: auf den Bildschirm begrenzen.
        if ($g.Width -and $g.Height) {
            $sc = Get-HUUiScaleValue; $wa = [System.Windows.SystemParameters]::WorkArea
            $vw = $(if ($g.PSObject.Properties['Unscaled'] -and $g.Unscaled) { [double]$g.Width } else { [double]$g.Width / $sc })
            $vh = $(if ($g.PSObject.Properties['Unscaled'] -and $g.Unscaled) { [double]$g.Height } else { [double]$g.Height / $sc })
            $Window.Width = [Math]::Max([Math]::Max(200, $Window.MinWidth), [Math]::Min($vw, $wa.Width * 0.9 / $sc))
            $Window.Height = [Math]::Max([Math]::Max(150, $Window.MinHeight), [Math]::Min($vh, $wa.Height * 0.9 / $sc))
        }
        if ($null -ne $g.Left -and $null -ne $g.Top -and (Test-HUOnScreen ([double]$g.Left) ([double]$g.Top) $Window.Width $Window.Height)) {
            $Window.WindowStartupLocation = 'Manual'; $Window.Left = [double]$g.Left; $Window.Top = [double]$g.Top
        }
    } catch { }
}
function Save-HUDialogState($Window, [string]$Key) {
    try {
        $rb = if ($Window.WindowState -ne 'Normal') { $Window.RestoreBounds } else { [System.Windows.Rect]::new($Window.Left, $Window.Top, $Window.Width, $Window.Height) }
        $sc = Get-HUUiScaleValue
        Set-HUStateValue $Key ([pscustomobject]@{ Left = [Math]::Round($rb.Left); Top = [Math]::Round($rb.Top); Width = [Math]::Round($rb.Width / $sc); Height = [Math]::Round($rb.Height / $sc); Unscaled = $true })
        Save-HUUIState
    } catch { }
}
