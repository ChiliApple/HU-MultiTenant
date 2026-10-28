#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Wartung", Ansicht "WIN-Updates" (2.6.3, Schritt 1: nur lesen): Windows-Versionen und Patchstand der Geraete,
    Update-Ringe und Update-Profile ueber alle angehakten Tenants.
.DESCRIPTION
    Daten: Core\HU.WinUpdate.psm1 (Get-HUWuInventory), im Hintergrund je Tenant gelesen und zwischengespeichert.
    Ansichten: Uebersicht (Versionen x Tenants), Ringe und Profile, Geraete (Filter, Doppelklick in der Uebersicht
    zeigt die Geraete dieser Version). Export als CSV.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:WuRaw = @{}          # Tenant -> @{ Inv; Time }
$script:WuView = 'matrix'
$script:WuDevFilter = ''     # Version, auf die die Geraeteliste eingeschraenkt ist (aus der Uebersicht)
$script:WuRows = @()

function Show-HUWuMode([bool]$On) {
    $c = $script:Controls
    $c['pnlWuLeft'].Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' })
    $c['pnlWuRight'].Visibility = $c['pnlWuLeft'].Visibility
    $c['btnRemModeWu'].Background = Get-HUBrush $(if ($On) { '#1976D2' } else { '#3E3E42' })
    if ($On) {
        if (-not $c['spWuTenants'].Children.Count) { Update-HUWuTenantChecks }
        # sofort lesen; Stand aelter als 15 Minuten wird beim Oeffnen erneuert
        $old = @($script:WuRaw.Values | Where-Object { $_.Time -lt (Get-Date).AddMinutes(-15) }).Count
        Start-HUWuLoad -Force:($old -gt 0)
        Update-HUWuView
    }
}

function Update-HUWuTenantChecks {
    $sp = $script:Controls['spWuTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'wuTenants' @())
    if (-not $saved.Count) { $saved = @($script:Settings.tenants | ForEach-Object { "$($_.key)" }) }
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"; $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ if (-not $script:TenantToggleBusy) { Save-HUWuTenants } })
        $cb.Add_Unchecked({ if (-not $script:TenantToggleBusy) { Save-HUWuTenants } })
        [void]$sp.Children.Add($cb)
    }
    if (@($script:Settings.tenants).Count -gt 1) { Add-HUTenantAllToggle $sp { Save-HUWuTenants } }
}

function Get-HUWuTenants { return @(Get-HUCheckedTenants $script:Controls['spWuTenants']) }

function Save-HUWuTenants {
    Set-HUStateValue 'wuTenants' @(Get-HUWuTenants)
    Start-HUWuLoad
    Update-HUWuView
}

# Im Hintergrund lesen: nur Tenants ohne Stand (oder alle mit -Force). Der Update-Katalog ist fuer alle gleich.
function Start-HUWuLoad([switch]$Force) {
    $want = @(Get-HUWuTenants)
    if ($Force) { foreach ($k in $want) { $script:WuRaw.Remove($k) } }
    $need = @($want | Where-Object { -not $script:WuRaw[$_] })
    if (-not $need.Count) { return }
    if (Test-HUJobRunning 'WuLoad') { return }
    $cat = $null
    foreach ($v in $script:WuRaw.Values) { if ($v.Inv.Catalog -and $v.Inv.Catalog.Count) { $cat = $v.Inv.Catalog; break } }
    $script:Controls['lblWuState'].Text = "Lese Windows-Updates aus $($need.Count) Tenant(s) ..."
    Set-HUWuRunDot $true
    [void](Start-HUJob -Name 'WuLoad' -Quiet -Output $script:Controls['rtbRem'] -Vars @{ Need = $need; Cat = $cat } -Code {
            $c = $Cat
            foreach ($k in $Need) {
                try {
                    $inv = Get-HUWuInventory -TenantKey $k -Settings $Settings -Catalog $c
                    if (-not $c -and $inv.Catalog -and $inv.Catalog.Count) { $c = $inv.Catalog }
                    foreach ($e in @($inv.Errors)) { Write-HULog -Message "Windows-Updates: $e" -Level 'WARN' -Tenant $k }
                    Write-HULog -Message "Windows-Updates: $(@($inv.Devices).Count) Geraet(e), $(@($inv.Policies).Count) Ring(e)/Profil(e)" -Level 'INFO' -Tenant $k
                    $inv
                } catch {
                    Write-HULog -Message "Windows-Updates: $($_.Exception.Message)" -Level 'ERROR' -Tenant $k
                    [pscustomobject]@{ Tenant = $k; Devices = @(); Policies = @(); Catalog = $c; Errors = @("$($_.Exception.Message)") }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] -and $_.PSObject.Properties['Devices'] })) { $script:WuRaw["$($r.Tenant)"] = @{ Inv = $r; Time = Get-Date } }
            Update-HUWuView
            if (@(Get-HUWuTenants | Where-Object { -not $script:WuRaw[$_] }).Count) { Start-HUWuLoad }
        })
}

function Get-HUWuInventories { return @(foreach ($k in @(Get-HUWuTenants)) { if ($script:WuRaw[$k]) { $script:WuRaw[$k].Inv } }) }

function Get-HUWuTenantNames {
    $n = @{}; foreach ($t in @($script:Settings.tenants)) { $n["$($t.key)"] = $(if ("$($t.displayName)") { "$($t.displayName)" } else { "$($t.key)" }) }
    return $n
}

# Liste links (je Tenant Ampel und Kurzfassung) und Tabelle rechts neu aufbauen
function Update-HUWuView {
    $c = $script:Controls
    if ($c['pnlWuLeft'].Visibility -ne 'Visible') { return }
    $names = Get-HUWuTenantNames
    $invs = @(Get-HUWuInventories)
    $c['lstWuTenants'].ItemsSource = @(foreach ($i in $invs) {
            $s = Get-HUWuSummary $i
            $col = switch ($s.Ampel) { 'rot' { '#EF5350' } 'gelb' { '#FFB74D' } 'gruen' { '#81C784' } default { '#AAAAAA' } }
            $warn = @(@($i.Policies) | Where-Object { $_.Hinweis } | ForEach-Object { "$($_.Name): $($_.Hinweis)" })
            [pscustomobject]@{ Tenant = $i.Tenant; Title = "$($names[$i.Tenant])"; Color = $col
                Sub = "$($s.Text)$(if ($s.Haupt) { "; $($s.Haupt)" })$(if (@($i.Errors).Count) { " | nicht alles lesbar" })"
                Tip = (@("$($s.Text)") + @($i.Errors) + $warn) -join "`n" }
        })
    $loading = Test-HUJobRunning 'WuLoad'
    Set-HUWuRunDot $loading
    $missing = @(Get-HUWuTenants | Where-Object { -not $script:WuRaw[$_] }).Count
    $c['lblWuState'].Text = $(if (-not @(Get-HUWuTenants).Count) { 'Oben Tenants anhaken.' } elseif ($loading -or $missing) { "Lese ... ($missing Tenant(s) offen)" } else {
            $t = @($script:WuRaw.Values | ForEach-Object { $_.Time } | Sort-Object)[0]; "Stand $(if ($t) { $t.ToString('HH:mm') }) - neu laden mit $([char]0x21BB)" })
    $f = "$($c['txtWuFilter'].Text)".Trim()
    $rows = @()
    switch ($script:WuView) {
        'matrix' {
            $c['lblWuTitle'].Text = "$([char]0xDC)bersicht: Windows-Versionen je Tenant"
            $c['lblWuHint'].Text = "Je Zelle: Geraete (davon mit neuestem Sicherheitsupdate). Doppelklick auf eine Zeile zeigt die Geraete dieser Version."
            $rows = @(Get-HUWuMatrix $invs $names)
        }
        'policies' {
            $c['lblWuTitle'].Text = 'Update-Ringe und Profile'
            $c['lblWuHint'].Text = 'Ringe (Aufschub, Fristen, aktive Zeit, Pause), Feature-Update-Profile (Zielversion), Expedite, Qualitaets- und Treiber-Updates - mit Zuweisung.'
            $rows = @($invs | ForEach-Object { @($_.Policies) } | ForEach-Object { [pscustomobject][ordered]@{ Tenant = $names[$_.Tenant]; Art = $_.Art; Name = $_.Name; Einstellung = $_.Einstellung; Pause = $_.Pause; Zuweisung = $_.Zuweisung; Hinweis = $_.Hinweis } } | Sort-Object Tenant, Art, Name)
        }
        'devices' {
            $c['lblWuTitle'].Text = "Ger$([char]0xE4)te$(if ($script:WuDevFilter) { ": $($script:WuDevFilter)" })"
            $c['lblWuHint'].Text = "Patchstand: aktuell = neuestes Sicherheitsupdate des Builds, zurueck = hoechstens etwa 1 Monat dahinter, veraltet = aelter. $(if ($script:WuDevFilter) { 'Ansicht links neu waehlen hebt die Einschraenkung auf.' })"
            $rows = @($invs | ForEach-Object { @($_.Devices) } | Where-Object { -not $script:WuDevFilter -or $_.Version -eq $script:WuDevFilter } |
                    ForEach-Object { [pscustomobject][ordered]@{ Tenant = $names[$_.Tenant]; Geraet = $_.Geraet; Benutzer = $_.Benutzer; Version = $_.Version; Build = $_.Build; Patchstand = $_.Patchstand; 'Letzter Sync' = $_.LetzterSync; Besitz = $_.Besitz; Modell = $_.Modell } } |
                    Sort-Object @{ e = { switch ($_.Patchstand) { 'veraltet' { 0 } 'zurueck' { 1 } 'unbekannt' { 2 } default { 3 } } } }, Tenant, Geraet)
        }
    }
    if ($f) { $rows = @($rows | Where-Object { $o = $_; @($o.PSObject.Properties | Where-Object { "$($_.Value)" -like "*$f*" }).Count }) }
    $script:WuRows = $rows
    $c['gridWu'].ItemsSource = $rows
}

# gruener pulsierender Punkt neben dem Titel, solange gelesen wird
function Set-HUWuRunDot([bool]$On) {
    $d = $script:Controls['dotWuRun']
    if (-not $d) { return }
    if ($On) {
        if ($d.Visibility -eq 'Visible') { return }
        $an = New-Object System.Windows.Media.Animation.DoubleAnimation
        $an.From = 1.0; $an.To = 0.2; $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
        $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $d.Visibility = 'Visible'
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
    } else {
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $d.Opacity = 1.0; $d.Visibility = 'Collapsed'
    }
}

function Export-HUWuTable {
    $rows = @($script:WuRows)
    if (-not $rows.Count) { Show-HUMessage 'Keine Zeilen zum Speichern.' -Icon Info; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV (Excel, Semikolon)|*.csv'
    $dlg.FileName = "WIN-Updates_$($script:WuView)_$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv"
    try { $rp = Get-HUReportsPath; if (Test-Path -LiteralPath $rp) { $dlg.InitialDirectory = $rp } } catch { }
    if (-not $dlg.ShowDialog($script:Window)) { return }
    try {
        $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
        Write-HULogOK "Tabelle gespeichert: $($dlg.FileName)"
        if (Confirm-HU "Gespeichert:`n$($dlg.FileName)`n`nJetzt oeffnen?") { Open-HUUrl $dlg.FileName }   # Warnung: nein - nur lokal
    } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}

function Register-HUWinUpdateHandlers {
    $c = $script:Controls
    $c['btnRemModeWu'].Add_Click({ Save-HURemForm; Save-HURemLib; Set-HURemMode 'wu' })
    $c['btnWuLoad'].Add_Click({ Start-HUWuLoad -Force; Update-HUWuView })
    $c['btnWuExport'].Add_Click({ Export-HUWuTable })
    $c['lstWuView'].Add_SelectionChanged({
            $it = $script:Controls['lstWuView'].SelectedItem
            if ($it) { $script:WuView = "$($it.Tag)"; $script:WuDevFilter = ''; Update-HUWuView }
        })
    $c['txtWuFilter'].Add_TextChanged({
            $script:Controls['lblWuFilterHint'].Visibility = $(if ($script:Controls['txtWuFilter'].Text) { 'Collapsed' } else { 'Visible' })
            Update-HUWuView
        })
    $c['gridWu'].Add_MouseDoubleClick({
            $it = $script:Controls['gridWu'].SelectedItem
            if ($script:WuView -eq 'matrix' -and $it -and $it.PSObject.Properties['Version']) {
                $script:WuView = 'devices'; $script:WuDevFilter = "$($it.Version)"
                Update-HUWuView
            }
        })
    $c['gridWu'].Add_LoadingRow({
            param($s, $e)
            $o = $e.Row.Item
            $col = '#E0E0E0'
            if ($o.PSObject.Properties['Patchstand']) { $col = switch ("$($o.Patchstand)") { 'veraltet' { '#EF9A9A' } 'zurueck' { '#FFCC80' } 'unbekannt' { '#AAAAAA' } default { '#E0E0E0' } } }
            elseif ($o.PSObject.Properties['Hinweis'] -and "$($o.Hinweis)") { $col = '#FFCC80' }
            $e.Row.Foreground = Get-HUBrush $col
        })
}
