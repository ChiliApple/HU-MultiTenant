#Requires -Version 5.1
<#
.SYNOPSIS
    Quick Script: Eingabefelder fuer Snippet-Parameter ("# @param ..." im Code) und Tenant-Mehrfachauswahl.
.DESCRIPTION
    Parameter: Format siehe Core\HU.QSParams.ps1. Die Felder werden neu aufgebaut, wenn sich die @param-Zeilen
    aendern (500 ms nach der letzten Eingabe); eingegebene Werte bleiben je Snippet erhalten, solange das Tool laeuft.
    Mehrere Tenants: Haken im Popup "Mehrere" - ab 2 Haken laeuft das Skript je Tenant einmal.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

. (Join-Path $script:AppRoot 'Core\HU.QSParams.ps1')

$script:QSParamSig = $null          # Signatur der aktuellen @param-Zeilen (Neuaufbau nur bei Aenderung)
$script:QSParamDefs = @()
$script:QSParamCtl = @{}            # Name -> Steuerelement
$script:QSParamMemory = @{}         # "Snippet|Name" -> zuletzt eingegebener Wert
$script:QSParamTimer = $null

function Get-HUQSParamKey([string]$Name) { return "$($script:QS_Current)|$Name" }

function Update-HUQSParamPanel([switch]$Force) {
    $c = $script:Controls
    $code = $c['txtQSEditor'].Text
    $defs = @(Get-HUQSParams $code)
    $sig = (@($defs | ForEach-Object { "$($_.Name)|$($_.Type)|$($_.Label)|$($_.Default)|$($_.Choices -join ';')" }) -join "`n") + "#$($script:QS_Current)"
    if (-not $Force -and $sig -eq $script:QSParamSig) { return }
    # Werte der alten Felder merken
    foreach ($n in @($script:QSParamCtl.Keys)) { $v = Get-HUQSParamControlValue $n; if ($null -ne $v) { $script:QSParamMemory[(Get-HUQSParamKey $n)] = $v } }
    $script:QSParamSig = $sig
    $script:QSParamDefs = $defs
    $script:QSParamCtl = @{}
    $panel = $c['pnlQSParams']
    $panel.Children.Clear()
    if (-not $defs.Count) { $panel.Visibility = 'Collapsed'; return }
    foreach ($p in $defs) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = [System.Windows.Thickness]::new(0, 2, 16, 2)
        $remembered = $script:QSParamMemory[(Get-HUQSParamKey $p.Name)]
        if ($p.Type -eq 'bool') {
            $ctl = New-Object System.Windows.Controls.CheckBox
            $ctl.Content = $p.Label
            $ctl.Foreground = Get-HUBrush '#CCCCCC'
            $ctl.VerticalAlignment = 'Center'
            $ctl.IsChecked = $(if ($null -ne $remembered) { [bool]$remembered } else { (ConvertTo-HUQSParamValue $p $p.Default) })
            if ($p.Name -match '^(DryRun|WhatIf|Simulation|Simulate|Test|TestMode|Probelauf|NurAnzeigen|Preview)$') {
                $ctl.Foreground = Get-HUBrush '#FF9800'
                $ctl.ToolTip = 'Aus = echter Lauf (vor dem Start kommt eine Rueckfrage)'
            }
            [void]$sp.Children.Add($ctl)
        } else {
            $lb = New-Object System.Windows.Controls.TextBlock
            $lb.Text = "$($p.Label):"
            $lb.Foreground = Get-HUBrush '#AAAAAA'
            $lb.VerticalAlignment = 'Center'
            $lb.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
            [void]$sp.Children.Add($lb)
            if ($p.Type -eq 'choice') {
                $ctl = New-Object System.Windows.Controls.ComboBox
                $ctl.Style = $script:Window.FindResource('DarkComboBox')
                $ctl.FontSize = 11
                foreach ($ch in $p.Choices) { [void]$ctl.Items.Add($ch) }
                $sel = if ($null -ne $remembered) { "$remembered" } else { $p.Default }
                if ($p.Choices -contains $sel) { $ctl.SelectedItem = $sel } elseif ($ctl.Items.Count) { $ctl.SelectedIndex = 0 }
            } else {
                $ctl = New-Object System.Windows.Controls.TextBox
                $ctl.Style = $script:Window.FindResource('DarkTextBox')
                $ctl.FontSize = 11
                $ctl.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
                $ctl.MinWidth = $(if ($p.Type -eq 'int') { 60 } else { 160 })
                $ctl.Text = $(if ($null -ne $remembered) { "$remembered" } else { $p.Default })
            }
            [void]$sp.Children.Add($ctl)
        }
        $script:QSParamCtl[$p.Name] = $ctl
        [void]$panel.Children.Add($sp)
    }
    $panel.Visibility = 'Visible'
}

function Get-HUQSParamControlValue([string]$Name) {
    $ctl = $script:QSParamCtl[$Name]
    if (-not $ctl) { return $null }
    if ($ctl -is [System.Windows.Controls.CheckBox]) { return [bool]$ctl.IsChecked }
    if ($ctl -is [System.Windows.Controls.ComboBox]) { return "$($ctl.SelectedItem)" }
    return "$($ctl.Text)"
}

# Werte fuer den Lauf (typisiert). Wirft bei ungueltiger Eingabe.
function Get-HUQSParamValues {
    $vals = @{}
    foreach ($p in $script:QSParamDefs) {
        $raw = Get-HUQSParamControlValue $p.Name
        $vals[$p.Name] = ConvertTo-HUQSParamValue $p $raw
        $script:QSParamMemory[(Get-HUQSParamKey $p.Name)] = $raw
    }
    return $vals
}

# Parameter, die im Code trotzdem gesetzt werden ($DryRun = ...) -> Feld wirkt nicht
function Get-HUQSOverriddenParams([string]$Code) {
    @($script:QSParamDefs | Where-Object { $Code -match ('(?m)^\s*\$' + [regex]::Escape($_.Name) + '\s*=') } | ForEach-Object { $_.Name })
}

function Start-HUQSParamRefresh {
    if (-not $script:QSParamTimer) {
        $script:QSParamTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:QSParamTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:QSParamTimer.Add_Tick({ $script:QSParamTimer.Stop(); try { Update-HUQSParamPanel } catch { } })
    }
    $script:QSParamTimer.Stop()
    $script:QSParamTimer.Start()
}

# ============================================================================
# Mehrere Tenants
# ============================================================================
function Update-HUQSTenantChecks {
    $sp = $script:Controls['spQSTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'qsMultiTenants' @())
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ Save-HUQSTenantChecks })
        $cb.Add_Unchecked({ Save-HUQSTenantChecks })
        [void]$sp.Children.Add($cb)
    }
    Update-HUQSMultiDisplay
}

function Get-HUQSCheckedTenants {
    @($script:Controls['spQSTenants'].Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
}

function Save-HUQSTenantChecks {
    Set-HUStateValue 'qsMultiTenants' @(Get-HUQSCheckedTenants)
    Update-HUQSMultiDisplay
}

# Tenants fuer den naechsten Lauf: ab 2 Haken die Haken, sonst die Auswahl links
function Get-HUQSRunTenants {
    $multi = @(Get-HUQSCheckedTenants)
    if ($multi.Count -ge 2) { return $multi }
    $k = Get-HUQSTenantKey
    if ($k) { return @($k) }
    return @()
}

function Update-HUQSMultiDisplay {
    $c = $script:Controls
    $multi = @(Get-HUQSCheckedTenants)
    if ($multi.Count -ge 2) {
        $names = @($multi | ForEach-Object { $k = $_; $t = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1; if ($t) { "$($t.displayName)" } else { $k } })
        $c['txtQSMulti'].Text = "$($multi.Count) Tenants"
        $c['txtQSMulti'].ToolTip = ($names -join "`n")
        $c['txtQSMulti'].Visibility = 'Visible'
        $c['btnQSMulti'].Content = "Mehrere ($($multi.Count)) $([char]0x25BE)"
        $c['btnQSMulti'].Foreground = Get-HUBrush '#4FC3F7'
        $c['cmbQSTenant'].IsEnabled = $false
    } else {
        $c['txtQSMulti'].Visibility = 'Collapsed'
        $c['btnQSMulti'].Content = "Mehrere $([char]0x25BE)"
        $c['btnQSMulti'].ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
        $c['cmbQSTenant'].IsEnabled = $true
    }
    $c['btnQSRun'].IsEnabled = ((@(Get-HUQSRunTenants).Count -gt 0) -and -not ($script:QS_Timer -and $script:QS_Timer.IsEnabled))
}

function Register-HUQSParamHandlers {
    $c = $script:Controls
    $c['btnQSMulti'].Add_Click({ $script:Controls['popQSTenants'].IsOpen = -not $script:Controls['popQSTenants'].IsOpen })
    $c['btnQSAll'].Add_Click({ foreach ($cb in $script:Controls['spQSTenants'].Children) { $cb.IsChecked = $true } })
    $c['btnQSNone'].Add_Click({ foreach ($cb in $script:Controls['spQSTenants'].Children) { $cb.IsChecked = $false }; $script:Controls['popQSTenants'].IsOpen = $false })
}
