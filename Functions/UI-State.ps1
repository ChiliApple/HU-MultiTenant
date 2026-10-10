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
        $last = if ($sel -eq $c['tabExtensions']) { 'Extensions' } elseif ($sel -eq $c['tabApps']) { 'Apps' } elseif ($sel -eq $c['tabMaint']) { 'Wartung' } elseif ($sel -eq $c['tabAnalyse']) { 'Analyse' } else { 'QuickScript' }
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

# Start-Reiter: Einstellung ui.startTab = QuickScript (Standard) | Extensions | Last
function Select-HUStartTab {
    $mode = 'QuickScript'
    try { if ($script:Settings.ui.PSObject.Properties['startTab'] -and "$($script:Settings.ui.startTab)") { $mode = "$($script:Settings.ui.startTab)" } } catch { }
    if ($mode -eq 'Last') { $mode = Get-HUStateValue 'LastTab' 'QuickScript' }
    $tab = switch ($mode) { 'Extensions' { 'tabExtensions' } 'Apps' { 'tabApps' } 'Wartung' { 'tabMaint' } 'Analyse' { 'tabAnalyse' } default { 'tabQuickScript' } }
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
    $hide = ($sel -eq $c['tabApps'] -or $sel -eq $c['tabMaint'] -or $sel -eq $c['tabAnalyse'])
    if ($hide -eq $script:LeftHidden) { return }
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
}

# Unterfenster (z. B. Snippet-Verwaltung): Groesse/Position merken
function Restore-HUDialogState($Window, [string]$Key) {
    $g = Get-HUStateValue $Key
    if (-not $g) { return }
    try {
        if ($g.Width -and $g.Height) { $Window.Width = [double]$g.Width; $Window.Height = [double]$g.Height }
        if ($null -ne $g.Left -and $null -ne $g.Top -and (Test-HUOnScreen ([double]$g.Left) ([double]$g.Top) $Window.Width $Window.Height)) {
            $Window.WindowStartupLocation = 'Manual'; $Window.Left = [double]$g.Left; $Window.Top = [double]$g.Top
        }
    } catch { }
}
function Save-HUDialogState($Window, [string]$Key) {
    try {
        $rb = if ($Window.WindowState -ne 'Normal') { $Window.RestoreBounds } else { [System.Windows.Rect]::new($Window.Left, $Window.Top, $Window.Width, $Window.Height) }
        Set-HUStateValue $Key ([pscustomobject]@{ Left = [Math]::Round($rb.Left); Top = [Math]::Round($rb.Top); Width = [Math]::Round($rb.Width); Height = [Math]::Round($rb.Height) })
        Save-HUUIState
    } catch { }
}
