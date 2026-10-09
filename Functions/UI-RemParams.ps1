#Requires -Version 5.1
<#
.SYNOPSIS
    Wartung: Eingabefelder fuer "# @param"-Zeilen in Pruef- und Reparaturskript (Bibliothek und In Intune).
.DESCRIPTION
    Der Wert steht direkt im Skript in der Zeile unter "# @param" ("$Name = 'Wert'  # @value") - Intune
    kennt keine Parameter, hochgeladen wird genau der Editor-Inhalt. Ein Feld gilt fuer beide Skripte.
    Format und Pruefung: Core\HU.QSParams.ps1 (Set-HURemParamValues, Test-HURemParams, Get-HURemParamCandidates).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:RemParamUi = @{
    Lib = @{ Det = 'txtRemDetect'; Fix = 'txtRemFix'; Panel = 'pnlRemParams'; Sig = ''; Busy = $false; Timer = $null }
    Int = @{ Det = 'txtRintDetect'; Fix = 'txtRintFix'; Panel = 'pnlRintParams'; Sig = ''; Busy = $false; Timer = $null }
}

# Felder beider Skripte (Pruefskript zuerst), Werte und umwandelbare Zuweisungen
function Get-HURemParamModel([string]$Which) {
    $u = $script:RemParamUi[$Which]; $c = $script:Controls
    $det = "$($c[$u.Det].Text)"; $fix = "$($c[$u.Fix].Text)"
    $defs = @(); $seen = @{}
    foreach ($p in @(Get-HUQSParams $det) + @(Get-HUQSParams $fix)) { if (-not $seen.ContainsKey($p.Name.ToLower())) { $seen[$p.Name.ToLower()] = $true; $defs += $p } }
    $vals = Get-HURemParamValues $fix
    foreach ($kv in (Get-HURemParamValues $det).GetEnumerator()) { $vals[$kv.Key] = $kv.Value }
    $cands = @(); $cs = @{}
    foreach ($x in @(Get-HURemParamCandidates $det) + @(Get-HURemParamCandidates $fix)) {
        if (-not $seen.ContainsKey($x.Name.ToLower()) -and -not $cs.ContainsKey($x.Name.ToLower())) { $cs[$x.Name.ToLower()] = $true; $cands += $x }
    }
    $sig = (@($defs | ForEach-Object { "$($_.Name)|$($_.Type)|$($_.Label)|$($_.Default)|$($_.Choices -join ';')=$($vals[$_.Name])" }) -join "`n") + '#' + (@($cands | ForEach-Object { $_.Name }) -join ',')
    return [pscustomobject]@{ Defs = $defs; Values = $vals; Cands = $cands; Sig = $sig }
}

function Start-HURemParamTimer([string]$Which) {
    $u = $script:RemParamUi[$Which]
    if ($u.Busy) { return }
    if (-not $u.Timer) {
        $u.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $u.Timer.Interval = [TimeSpan]::FromMilliseconds(500)
        $u.Timer.Tag = $Which
        $u.Timer.Add_Tick({ $this.Stop(); Update-HURemParamPanel $this.Tag })
    }
    $u.Timer.Stop(); $u.Timer.Start()
}

function Update-HURemParamPanel([string]$Which, [switch]$Force) {
    $u = $script:RemParamUi[$Which]; $c = $script:Controls
    $panel = $c[$u.Panel]
    if (-not $panel) { return }
    $m = $null
    try { $m = Get-HURemParamModel $Which } catch { return }
    if (-not $Force -and $m.Sig -eq $u.Sig) { return }
    # nicht umbauen, waehrend in einem Feld getippt wird
    if (-not $Force -and $panel.IsKeyboardFocusWithin) { return }
    $u.Sig = $m.Sig
    $panel.Children.Clear()
    if (-not $m.Defs.Count -and -not $m.Cands.Count) { $panel.Visibility = 'Collapsed'; return }
    $panel.Visibility = 'Visible'
    if ($m.Defs.Count) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = 'Werte:'; $t.Foreground = Get-HUBrush '#AAAAAA'; $t.VerticalAlignment = 'Center'; $t.FontWeight = 'SemiBold'
        $t.Margin = [System.Windows.Thickness]::new(0, 2, 10, 2)
        $t.ToolTip = 'Felder aus den "# @param"-Zeilen. Der Wert steht im Skript in der Zeile darunter ("# @value") und wird genau so hochgeladen.'
        [void]$panel.Children.Add($t)
    }
    foreach ($p in $m.Defs) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = [System.Windows.Thickness]::new(0, 2, 16, 2)
        $cur = if ($m.Values.ContainsKey($p.Name)) { $m.Values[$p.Name] } else { $p.Default }
        if ($p.Type -eq 'bool') {
            $ctl = New-Object System.Windows.Controls.CheckBox
            $ctl.Content = $p.Label; $ctl.Foreground = Get-HUBrush '#CCCCCC'; $ctl.VerticalAlignment = 'Center'
            try { $ctl.IsChecked = [bool](ConvertTo-HUQSParamValue $p $cur) } catch { $ctl.IsChecked = $false }
            $ctl.Tag = @{ W = $Which; N = $p.Name }
            $ctl.Add_Click({ Set-HURemParamFromUi $this.Tag.W $this.Tag.N ([bool]$this.IsChecked) $this })
            [void]$sp.Children.Add($ctl)
        } else {
            $lb = New-Object System.Windows.Controls.TextBlock
            $lb.Text = "$($p.Label):"; $lb.Foreground = Get-HUBrush '#AAAAAA'; $lb.VerticalAlignment = 'Center'
            $lb.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
            [void]$sp.Children.Add($lb)
            if ($p.Type -eq 'choice') {
                $ctl = New-Object System.Windows.Controls.ComboBox
                $ctl.Style = $script:Window.FindResource('DarkComboBox'); $ctl.FontSize = 11
                foreach ($ch in $p.Choices) { [void]$ctl.Items.Add($ch) }
                if ($p.Choices -contains "$cur") { $ctl.SelectedItem = "$cur" } elseif ($ctl.Items.Count) { $ctl.SelectedIndex = 0 }
                $ctl.Tag = @{ W = $Which; N = $p.Name }
                $ctl.Add_SelectionChanged({ Set-HURemParamFromUi $this.Tag.W $this.Tag.N "$($this.SelectedItem)" $this })
            } else {
                $ctl = New-Object System.Windows.Controls.TextBox
                $ctl.Style = $script:Window.FindResource('DarkTextBox'); $ctl.FontSize = 11
                $ctl.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
                $ctl.MinWidth = $(if ($p.Type -eq 'int') { 60 } else { 160 })
                $ctl.Text = "$cur"
                $ctl.Tag = @{ W = $Which; N = $p.Name }
                $ctl.Add_TextChanged({ if ($this.IsKeyboardFocusWithin) { Set-HURemParamFromUi $this.Tag.W $this.Tag.N $this.Text $this } })
            }
            [void]$sp.Children.Add($ctl)
        }
        [void]$panel.Children.Add($sp)
    }
    if ($m.Cands.Count) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = "Werte als Felder uebernehmen ($($m.Cands.Count))"
        $b.Style = $script:Window.FindResource('ToolButton'); $b.FontSize = 11
        $b.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2); $b.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $b.ToolTip = "Einfache Zuweisungen am Skriptanfang als Eingabefelder anlegen: $(@($m.Cands | ForEach-Object { '$' + $_.Name }) -join ', ')"
        $b.Tag = $Which
        $b.Add_Click({ Convert-HURemParamCandidates $this.Tag })
        [void]$panel.Children.Add($b)
    }
    try { $panel.IsEnabled = -not ($c[$u.Det].IsReadOnly) } catch { }
}

# Feld geaendert -> @value-Zeile in beiden Skripten setzen
function Set-HURemParamFromUi([string]$Which, [string]$Name, $Value, $Control = $null) {
    $u = $script:RemParamUi[$Which]; $c = $script:Controls
    if ($u.Busy) { return }
    $u.Busy = $true
    try {
        foreach ($k in $u.Det, $u.Fix) {
            $box = $c[$k]; $code = "$($box.Text)"
            if (-not @(Get-HUQSParams $code | Where-Object { $_.Name -eq $Name }).Count) { continue }
            $new = Set-HURemParamValues $code @{ $Name = $Value }
            if ($new -cne $code) { $box.Text = $new }
        }
        if ($Control) { $Control.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty); $Control.ToolTip = $null }
    } catch {
        if ($Control) { $Control.BorderBrush = Get-HUBrush '#FF5252'; $Control.ToolTip = "$($_.Exception.Message)" }
    } finally {
        $u.Busy = $false
        try { $u.Sig = (Get-HURemParamModel $Which).Sig } catch { }
    }
}

# Vor Speichern/Hochladen/Test: fehlende Wertzeilen mit dem Standard ergaenzen
function Complete-HURemParams([string]$Which) {
    $u = $script:RemParamUi[$Which]; $c = $script:Controls
    $u.Busy = $true
    try {
        foreach ($k in $u.Det, $u.Fix) {
            $box = $c[$k]; $code = "$($box.Text)"
            if (-not @(Get-HUQSParams $code).Count) { continue }
            try { $new = Set-HURemParamValues $code @{} -FillDefaults; if ($new -cne $code) { $box.Text = $new } } catch { }
        }
    } finally { $u.Busy = $false }
    Update-HURemParamPanel $Which -Force
}

function Convert-HURemParamCandidates([string]$Which) {
    $u = $script:RemParamUi[$Which]; $c = $script:Controls
    $m = Get-HURemParamModel $Which
    if (-not $m.Cands.Count) { return }
    $names = @($m.Cands | ForEach-Object { $_.Name })
    if (-not (Confirm-HU "Diese Zuweisungen am Skriptanfang werden zu Eingabefeldern:`n`n$(@($names | ForEach-Object { '$' + $_ }) -join ', ')`n`nIm Skript kommt je eine Zeile '# @param ...' dazu, der Wert bleibt gleich. Die Beschriftung kannst du in der @param-Zeile aendern (Name|Typ|Beschriftung|Standard).`n`nUebernehmen?" 'Wartung')) { return }
    $u.Busy = $true
    try {
        foreach ($k in $u.Det, $u.Fix) {
            $box = $c[$k]; $code = "$($box.Text)"
            $new = Convert-HURemAssignToParam $code $names
            if ($new -cne $code) { $box.Text = $new }
        }
    } finally { $u.Busy = $false }
    Update-HURemParamPanel $Which -Force
    Add-HURtbLine $c['rtbRem'] "Als Felder uebernommen: $(@($names | ForEach-Object { '$' + $_ }) -join ', ')" '#81C784'
}

function Register-HURemParamHandlers {
    $c = $script:Controls
    foreach ($w in 'Lib', 'Int') {
        $u = $script:RemParamUi[$w]
        foreach ($k in $u.Det, $u.Fix) {
            if (-not $c[$k]) { continue }
            $c[$k].Tag = $w
            $c[$k].Add_TextChanged({ Start-HURemParamTimer $this.Tag })
        }
    }
}
