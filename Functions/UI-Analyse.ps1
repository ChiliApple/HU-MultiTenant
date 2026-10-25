#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Analyse": "Was bekommt ...?" - alle Apps, Profile, Richtlinien und Skripte, die eine Gruppe,
    ein Geraet oder ein Benutzer in den angehakten Tenants bekommt (auch ueber verschachtelte Gruppen und "Alle ...").
.DESCRIPTION
    Je Tenant ein eigener Hintergrund-Auftrag (Get-HUAssignmentReport); Ergebnisse erscheinen nach und nach in der Tabelle.
    Nur lesend.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:AnaRows = New-Object System.Collections.ArrayList
$script:AnaGen = 0
$script:AnaWait = @{}
$script:AnaLabel = ''

function Update-HUAnaTenantChecks {
    $sp = $script:Controls['spAnaTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'anaTenants' @())
    if (-not $saved.Count) { $saved = @($script:Settings.tenants | ForEach-Object { "$($_.key)" }) }
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ if (-not $script:TenantToggleBusy) { Save-HUAnaTenants } })
        $cb.Add_Unchecked({ if (-not $script:TenantToggleBusy) { Save-HUAnaTenants } })
        [void]$sp.Children.Add($cb)
    }
    if (@($script:Settings.tenants).Count -gt 1) { Add-HUTenantAllToggle $sp { Save-HUAnaTenants } }
}

function Save-HUAnaTenants {
    Set-HUStateValue 'anaTenants' @(Get-HUCheckedTenants $script:Controls['spAnaTenants'])
    # Sicherheit vor dem ersten Pruefen: Spalten der Regelliste folgen den Haken
    if ($script:AnaMode -eq 'sec' -and -not $script:SecRan) { try { Show-HUSecPreview } catch { } }
}

function Get-HUAnaTenantName([string]$Key) {
    if ($Key -eq (Get-HUMusterKey)) {
        if ("$($script:CmpMusterLabel)") { return "$($script:CmpMusterLabel)" }
        $m = $null; try { $m = Get-HUMusterSelectionUi } catch { }; if ($m) { return $m.Label }; return 'Muster'
    }
    if (Test-HUMusterBuiltinSource $Key) { return 'Mitgeliefert' }
    $t = @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $Key }) | Select-Object -First 1
    if ($t -and "$($t.displayName)") { return "$($t.displayName)" }
    return $Key
}

function Get-HUAnaKind {
    $it = $script:Controls['cmbAnaKind'].SelectedItem
    if ($it -and "$($it.Tag)") { return "$($it.Tag)" }
    return 'group'
}

function Set-HUAnaMode([string]$Mode) {
    $c = $script:Controls
    if ($Mode -notin 'asg', 'cmp', 'bak', 'sec') { $Mode = 'asg' }
    $script:AnaMode = $Mode
    $vis = { param($b) if ($b) { 'Visible' } else { 'Collapsed' } }
    $c['pnlAnaAsg'].Visibility = & $vis ($Mode -eq 'asg')
    $c['pnlAnaCmp'].Visibility = & $vis ($Mode -eq 'cmp')
    $c['pnlAnaBak'].Visibility = & $vis ($Mode -eq 'bak')
    $c['pnlAnaSec'].Visibility = & $vis ($Mode -eq 'sec')
    $c['gridAna'].Visibility = $c['pnlAnaAsg'].Visibility
    $c['gridCmp'].Visibility = $c['pnlAnaCmp'].Visibility
    $c['gridBak'].Visibility = $c['pnlAnaBak'].Visibility
    $c['gridSec'].Visibility = $c['pnlAnaSec'].Visibility
    $c['btnAnaModeAsg'].Background = Get-HUBrush $(if ($Mode -eq 'asg') { '#1976D2' } else { '#3E3E42' })
    $c['btnAnaModeCmp'].Background = Get-HUBrush $(if ($Mode -eq 'cmp') { '#1976D2' } else { '#3E3E42' })
    $c['btnAnaModeBak'].Background = Get-HUBrush $(if ($Mode -eq 'bak') { '#1976D2' } else { '#3E3E42' })
    $c['btnAnaModeSec'].Background = Get-HUBrush $(if ($Mode -eq 'sec') { '#1976D2' } else { '#3E3E42' })
    Set-HUStateValue 'anaMode' $Mode
    if ($Mode -eq 'bak') { Update-HUBakView }
    if ($Mode -eq 'sec') { try { Show-HUSecPreview } catch { } }
    Update-HUAnaHint
}

# Pulsierender gruener Punkt vor der Statuszeile (Analyse), solange gelesen/geprueft wird (wie Teams-Meldung).
# Er pulsiert, wenn eine Ansicht es verlangt (Set-HUAnaRunDot) ODER irgendein Auftrag in die Analyse-Ausgabe schreibt
# (z. B. Doppelklick, der Einstellungen nachlaedt) - so muss nicht jeder Auftrag den Punkt selbst schalten.
$script:AnaDotWanted = $false
function Test-HUAnaJobRunning {
    $o = $script:Controls['rtbAna']
    if (-not $o -or -not $script:HUJobs) { return $false }
    foreach ($s in @($script:HUJobs.Values)) { if ($s -and -not $s.Done -and [object]::ReferenceEquals($s.Output, $o)) { return $true } }
    return $false
}
function Set-HUAnaRunDot([bool]$On) {
    $script:AnaDotWanted = $On
    Update-HUAnaRunDot
}
function Update-HUAnaRunDot {
    $d = $script:Controls['dotAnaRun']
    if (-not $d) { return }
    $On = [bool]$script:AnaDotWanted -or (Test-HUAnaJobRunning)
    if ($On) {
        if ($d.Visibility -eq 'Visible') { return }
        $an = New-Object System.Windows.Media.Animation.DoubleAnimation
        $an.From = 1.0; $an.To = 0.2; $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
        $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $d.Visibility = 'Visible'
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
    }
    else {
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $d.Opacity = 1.0; $d.Visibility = 'Collapsed'
    }
}

function Update-HUAnaHint {
    if ($script:AnaMode -eq 'cmp') { Update-HUCmpHint; return }
    if ($script:AnaMode -eq 'bak') { Update-HUBakHint; return }
    if ($script:AnaMode -eq 'sec') { Update-HUSecHint; return }
    $c = $script:Controls
    $wait = @($script:AnaWait.Keys)
    Set-HUAnaRunDot ($wait.Count -gt 0)
    $n = $script:AnaRows.Count
    if ($wait.Count) {
        $c['lblAnaHint'].Text = "$($script:AnaLabel): $n Eintrag/Eintraege bisher - warte auf $(@($wait | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ') ..."
    } elseif ($script:AnaLabel) {
        $ex = @($script:AnaRows | Where-Object { "$($_.Status)" -like 'ausgeschlossen*' }).Count
        $vis = @(Get-HUAnaVisibleRows).Count
        $c['lblAnaHint'].Text = "$($script:AnaLabel): $n Eintrag/Eintraege$(if ($ex) { " ($ex ausgeschlossen)" })$(if ($vis -ne $n) { ", $vis angezeigt" }). Nur lesend - Filter (Spalte Filter) werden angezeigt, aber nicht ausgewertet."
    } else {
        $c['lblAnaHint'].Text = 'Gruppe, Geraet oder Benutzer eingeben und Anzeigen klicken. Beruecksichtigt verschachtelte Gruppen, Alle Geraete / Alle Benutzer und Ausschluesse.'
    }
}

function Get-HUAnaVisibleRows {
    $rows = @($script:AnaRows)
    if (-not $script:Controls['chkAnaAll'].IsChecked) {
        $rows = @($rows | Where-Object { @("$($_.Ueber)" -split ', ' | Where-Object { $_ -and $_ -notin 'Alle Geraete', 'Alle Benutzer' }).Count })
    }
    $typ = "$($script:Controls['cmbAnaType'].SelectedItem)"
    if ($typ -and $typ -ne '(alle Arten)') { $rows = @($rows | Where-Object { "$($_.Typ)" -eq $typ }) }
    foreach ($w in @("$($script:Controls['txtAnaFilter'].Text)" -split '\s+' | Where-Object { $_ })) {
        $rows = @($rows | Where-Object { ("$($_.Tenant) $($_.Typ) $($_.Name) $($_.Absicht) $($_.Ueber) $($_.Status)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @($rows | Sort-Object Typ, Name, Tenant)
}

function Update-HUAnaTypes {
    $cb = $script:Controls['cmbAnaType']
    $cur = "$($cb.SelectedItem)"
    $types = @('(alle Arten)') + @($script:AnaRows | ForEach-Object { "$($_.Typ)" } | Sort-Object -Unique)
    if ((@($cb.Items) -join '|') -eq ($types -join '|')) { return }
    $script:AnaTypeBusy = $true
    $cb.Items.Clear()
    foreach ($t in $types) { [void]$cb.Items.Add($t) }
    $cb.SelectedItem = $(if ($types -contains $cur) { $cur } else { '(alle Arten)' })
    $script:AnaTypeBusy = $false
}

function Update-HUAnaGrid {
    Update-HUAnaTypes
    $sorted = @(Get-HUAnaVisibleRows)
    $script:Controls['gridAna'].ItemsSource = $sorted
    Update-HUAnaHint
}

function Start-HUAnaRun {
    $c = $script:Controls
    $name = $c['txtAnaName'].Text.Trim()
    if (-not $name) { Show-HUMessage 'Bitte Gruppe, Geraet oder Benutzer eingeben.' -Icon Warning; return }
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'])
    if (-not $keys.Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning; return }
    $kind = Get-HUAnaKind
    $script:AnaGen++
    $gen = $script:AnaGen
    $script:AnaRows.Clear()
    $script:AnaWait = @{}
    $kindText = switch ($kind) { 'device' { 'Geraet' } 'user' { 'Benutzer' } default { 'Gruppe' } }
    $script:AnaLabel = "$kindText '$name'"
    Set-HUStateValue 'anaKind' $kind
    Update-HUAnaGrid
    $c['rtbAna'].Document.Blocks.Clear()
    Add-HURtbLine $c['rtbAna'] "Was bekommt $($script:AnaLabel)? - $($keys.Count) Tenant(s)" '#90CAF9'
    foreach ($k in $keys) {
        $script:AnaWait[$k] = $true
        $ok = Start-HUJob -Name "Ana-$gen-$k" -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; Kind = $kind; Target = $name; Gen = $gen } -Code {
            try { @(Get-HUAssignmentReport -TenantKey $TK -Settings $Settings -Kind $Kind -Name $Target) | ForEach-Object { $_ } }
            catch {
                $m = $_.Exception.Message
                if ($m -match '403|Forbidden|Authorization') { $m = "Berechtigung fehlt ($m) - noetig: DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All, DeviceManagementManagedDevices.Read.All, Group.Read.All, User.Read.All, Device.Read.All" }
                Write-HULog -Message $m -Level 'ERROR' -Tenant $TK
            }
            [pscustomobject]@{ __AnaDone = $TK; __AnaGen = $Gen }
        } -OnDone {
            param($Result, $Errors)
            $done = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__AnaDone'] }) | Select-Object -First 1
            if (-not $done -or [int]$done.__AnaGen -ne $script:AnaGen) { return }
            $script:AnaWait.Remove("$($done.__AnaDone)")
            $tn = Get-HUAnaTenantName "$($done.__AnaDone)"
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Typ'] })) {
                [void]$script:AnaRows.Add([pscustomobject]@{ Tenant = $tn; Typ = "$($r.Typ)"; Name = "$($r.Name)"; Absicht = "$($r.Absicht)"; Ueber = "$($r.Ueber)"; Status = "$($r.Status)"; Filter = "$($r.Filter)" })
            }
            Update-HUAnaGrid
        }
        if (-not $ok) { $script:AnaWait.Remove($k) }
    }
    Update-HUAnaHint
}

# ----------------------------------------------------------------------------
# Tenant-Vergleich
# ----------------------------------------------------------------------------
$script:AnaMode = 'asg'
$script:CmpData = @{}
$script:CmpWait = @{}
$script:CmpKeys = @()
$script:UndoEntra = $false
$script:CmpGen = 0
$script:CmpMatrix = @()
$script:CmpMusterSel = $null    # angehakte Muster-Pakete des letzten Vergleichs (Get-HUMusterSelection)
$script:CmpMusterLabel = ''
$script:CmpMoBusy = $false

function Update-HUCmpHint {
    $c = $script:Controls
    $wait = @($script:CmpWait.Keys)
    Set-HUAnaRunDot ($wait.Count -gt 0)
    if ($wait.Count) { $c['lblAnaHint'].Text = "Lese Bestand ... warte auf $(@($wait | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')"; return }
    if (-not $script:CmpKeys.Count) { $c['lblAnaHint'].Text = 'Tenants anhaken (mindestens 2) und Vergleichen klicken. Verglichen werden nach Name: Intune (Profile, Einstellungskatalog, Administrative Vorlagen, Compliance, Wartung, Skripte, Updates, Autopilot, App-Schutz, Registrierung, Filter, Rollen u. a.), Conditional Access, Apps und die Entra-Einstellungen wie im Backup.'; return }
    $all = @($script:CmpMatrix)
    $d = @($all | Where-Object Diff).Count
    $vis = @(Get-HUCmpVisibleRows).Count
    $c['lblAnaHint'].Text = "$($all.Count) Eintraege, $d mit Unterschied$(if ($vis -ne $all.Count) { ", $vis angezeigt" }). Gleich = gleicher Name; 'Einstellungen abweichend' fuer Profile, Compliance, Feature-Updates, Autopilot, Conditional Access (Zelle Ein, Aus oder Melden) und die weiteren Arten aus dem Backup; IDs von Gruppen, Apps und Orten zaehlen dabei nicht, die Namen zeigt der Doppelklick. Doppelklick zeigt die abweichenden Einstellungen. Uebertragen: einen Eintrag markieren, Quelle und Ziele waehlen, je Ziel Vorschau - Intune neu angelegt ohne Zuweisungen oder angeglichen; Entra-Einstellungen und Conditional Access (neu, als Nur Bericht) nur aus dem Muster.$(if ($script:CmpMusterSel -and -not $script:CmpMusterSel.Complete) { ' Muster = Teilpaket(e): Eintraege, die nicht im Paket sind, zaehlen nicht als Abweichung (Zelle nicht im Paket).' })"
}

# Arten-Dropdown: hinter jeder Art steht, was damit geht (uebertragen/angleichen/nur vergleichen)
function Get-HUCmpTypeHint([string]$Typ) {
    if ($Typ -in 'Benannter Ort', 'Verzeichniseinstellung') { return 'uebertragen aus Muster' }
    if ($Typ -eq 'Entra-Einstellung') { return 'teils uebertragbar aus Muster' }
    if ($Typ -eq 'Conditional Access') { return 'neu als Nur Bericht aus Muster' }
    $src = Get-HUCompareSources | Where-Object { $_.Typ -eq $Typ } | Select-Object -First 1
    if ($src -and $src.Copy) { if ($src.Copy -in @('generic', 'compliance') -and $src.Hash) { return 'uebertragen + angleichen' } else { return 'neu anlegen' } }
    return 'nur vergleichen'
}

function Get-HUCmpVisibleRows {
    $rows = @($script:CmpMatrix)
    if ($script:Controls['chkCmpDiff'].IsChecked) { $rows = @($rows | Where-Object Diff) }
    # Teilpaket: auf Wunsch nur die Eintraege des Musters
    $mk = Get-HUMusterKey
    if (@($script:CmpKeys) -contains $mk -and $script:Controls['chkCmpMusterOnly'].IsChecked) { $rows = @($rows | Where-Object { @($_.Have) -contains $mk }) }
    $typ = "$($script:Controls['cmbCmpType'].SelectedItem)" -replace '\s+\([^)]*\)$', ''
    if ($typ -and $typ -ne '(alle Arten)') { $rows = @($rows | Where-Object { $_.Typ -eq $typ }) }
    foreach ($w in @("$($script:Controls['txtCmpFilter'].Text)" -split '\s+' | Where-Object { $_ })) {
        $rows = @($rows | Where-Object { ("$($_.Typ) $($_.Name) $($_.Status)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @($rows | Sort-Object Typ, Name)
}

# Zelle im Vergleich: Haken, bei Conditional Access der Status (Ein / Aus / Melden)
function Get-HUCmpCellText($M, [string]$Key) {
    if ($Key -eq (Get-HUMusterKey) -and $M.PSObject.Properties['NotInPkg'] -and $M.NotInPkg) { return 'nicht im Paket' }
    $it = @($M.Items | Where-Object { $_.Tenant -eq $Key })[0]
    if ($it -and $it.PSObject.Properties['Info'] -and "$($it.Info)") { return "$($it.Info)" }
    return "$([char]0x2714)"
}

# Farbe je Zelle (Schalter "Farben"; aus = normale Schrift). Vergleichswert: Fingerabdruck des Musters, sonst der haeufigste.
# Steht im Status nicht "abweichend" (z. B. nur Reihenfolge verschieden), sind alle vorhandenen gruen.
function Get-HUCmpCellColor($M, [string]$Key) {
    $def = '#CCCCCC'
    if (-not $script:Controls['chkCmpColor'] -or -not $script:Controls['chkCmpColor'].IsChecked) { return $def }
    if (@($M.Unknown) -contains $Key) { return '#8A8A8A' }
    if ($Key -eq (Get-HUMusterKey) -and $M.PSObject.Properties['NotInPkg'] -and $M.NotInPkg) { return '#8A8A8A' }
    if (@($M.Have) -notcontains $Key) { return '#EF5350' }
    if ("$($M.Status)" -notlike '*abweichend*') { return '#81C784' }
    $withHash = @($M.Items | Where-Object { "$($_.Hash)" })
    $mine = @($withHash | Where-Object { $_.Tenant -eq $Key })
    if (-not $mine.Count) { return $def }
    $mk = Get-HUMusterKey
    $refItem = @($withHash | Where-Object { $_.Tenant -eq $mk })
    $ref = if ($refItem.Count) { "$($refItem[0].Hash)" } else { "$(@($withHash | Group-Object Hash | Sort-Object Count -Descending)[0].Name)" }
    if (@($mine | Where-Object { "$($_.Hash)" -eq $ref }).Count) { return '#81C784' }
    return '#FFB74D'
}

function Update-HUCmpGrid {
    $c = $script:Controls
    $g = $c['gridCmp']
    $keys = @($script:CmpKeys)
    # Spalten: Typ, Name, je Tenant, Status
    $g.Columns.Clear()
    $add = { param($h, $b, $w) $col = New-Object System.Windows.Controls.DataGridTextColumn; $col.Header = $h; $col.Binding = New-Object System.Windows.Data.Binding($b); $col.Width = $w; [void]$g.Columns.Add($col) }
    & $add 'Typ' 'Typ' (New-Object System.Windows.Controls.DataGridLength(150))
    & $add 'Name' 'Name' (New-Object System.Windows.Controls.DataGridLength(2, 'Star'))
    for ($i = 0; $i -lt $keys.Count; $i++) {
        & $add (Get-HUAnaTenantName $keys[$i]) "T$i" (New-Object System.Windows.Controls.DataGridLength(1, [System.Windows.Controls.DataGridLengthUnitType]::Auto)); $g.Columns[$g.Columns.Count - 1].MinWidth = 120
        # Zeichenfarbe aus Fc<i> (Schalter "Farben")
        $st = New-Object System.Windows.Style([System.Windows.Controls.TextBlock])
        [void]$st.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.TextBlock]::ForegroundProperty, (New-Object System.Windows.Data.Binding("Fc$i")))))
        $g.Columns[$g.Columns.Count - 1].ElementStyle = $st
    }
    & $add 'Status' 'Status' (New-Object System.Windows.Controls.DataGridLength(1, 'Star'))
    # Arten-Auswahl
    $cb = $c['cmbCmpType']; $cur = "$($cb.SelectedItem)"
    $types = @('(alle Arten)') + @($script:CmpMatrix | ForEach-Object { $_.Typ } | Sort-Object -Unique | ForEach-Object { "$_   ($(Get-HUCmpTypeHint $_))" })
    if ((@($cb.Items) -join '|') -ne ($types -join '|')) {
        $script:CmpTypeBusy = $true
        $cb.Items.Clear(); foreach ($t in $types) { [void]$cb.Items.Add($t) }
        # gewaehlte Art bleibt auch ueber Neu-Laden (z. B. nach dem Uebertragen) und Neustart erhalten - Vergleich ueber den Namen ohne Hinweis
        $want = "$($script:CmpTypeWanted)"; if (-not $want) { $want = ($cur -replace '\s+\([^)]*\)$', '') }
        $hit = @($types | Where-Object { ($_ -replace '\s+\([^)]*\)$', '') -eq $want }) | Select-Object -First 1
        $cb.SelectedItem = $(if ($hit) { $hit } else { '(alle Arten)' })
        $script:CmpTypeBusy = $false
        # Breite nach laengstem Eintrag (plus Abstand und Pfeil), damit nichts abgeschnitten wird
        try {
            $tf = New-Object System.Windows.Media.Typeface($cb.FontFamily, $cb.FontStyle, $cb.FontWeight, $cb.FontStretch)
            $wMax = 0.0
            foreach ($t in $types) {
                $ft = New-Object System.Windows.Media.FormattedText($t, [System.Globalization.CultureInfo]::CurrentUICulture, [System.Windows.FlowDirection]::LeftToRight, $tf, $cb.FontSize, [System.Windows.Media.Brushes]::White)
                if ($ft.WidthIncludingTrailingWhitespace -gt $wMax) { $wMax = $ft.WidthIncludingTrailingWhitespace }
            }
            $cb.Width = [Math]::Max(190, [Math]::Ceiling($wMax) + 44)
        } catch { }
    }
    $items = foreach ($m in @(Get-HUCmpVisibleRows)) {
        $o = [ordered]@{ Typ = $m.Typ; Name = $m.Name }
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $nip = ($keys[$i] -eq (Get-HUMusterKey) -and $m.PSObject.Properties['NotInPkg'] -and $m.NotInPkg)
            $o["T$i"] = $(if ($nip) { 'nicht im Paket' } elseif ($m.Have -contains $keys[$i]) { Get-HUCmpCellText $m $keys[$i] } elseif (@($m.Unknown) -contains $keys[$i]) { '?' } else { "$([char]0x2014)" }); $o["Fc$i"] = Get-HUCmpCellColor $m $keys[$i]
        }
        $o.Status = ("$($m.Status)$(if ($m.Missing.Count -and -not $m.Copy -and $m.Typ -notin 'Benannter Ort', 'Verzeichniseinstellung', 'Conditional Access') { ' (nur anzeigen)' })" -replace [regex]::Escape((Get-HUMusterKey)), 'Muster')
        $o.Ref = $m
        [pscustomobject]$o
    }
    $g.ItemsSource = @($items)
    Update-HUCmpHint
}

function Start-HUCmpRun {
    $c = $script:Controls
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'])
    $muster = $null
    if ($c['chkCmpMuster'].IsChecked) {
        $muster = Get-HUMusterSelectionUi
        if (-not $muster) { Show-HUMessage 'Es ist kein Muster-Paket angehakt. Im Reiter Muster mindestens ein Paket anhaken (oder in Backup & Verlauf einen Stand als Muster festhalten).' -Icon Info; return }
    }
    if (($keys.Count + [int][bool]$muster) -lt 2) { Show-HUMessage 'Bitte mindestens zwei Tenants anhaken (oder einen Tenant und das Muster).' -Icon Warning; return }
    if ($muster) { $keys = @(@(Get-HUMusterKey) + $keys) }
    $script:CmpMusterSel = $muster
    $script:CmpMusterLabel = $(if ($muster) { $muster.Label } else { '' })
    # Haken "Nur Muster-Eintraege": nur mit Muster sichtbar, bei Teilpaketen automatisch an
    $c['chkCmpMusterOnly'].Visibility = $(if ($muster) { 'Visible' } else { 'Collapsed' })
    $script:CmpMoBusy = $true
    $c['chkCmpMusterOnly'].IsChecked = [bool]($muster -and -not $muster.Complete)
    $script:CmpMoBusy = $false
    $script:CmpGen++
    $gen = $script:CmpGen
    $script:CmpKeys = $keys
    $script:CmpData = @{}
    $script:CmpWait = @{}
    $script:CmpMatrix = @()
    Update-HUCmpGrid
    $c['rtbAna'].Document.Blocks.Clear()
    Add-HURtbLine $c['rtbAna'] "Tenant-Vergleich: $(@($keys | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" '#90CAF9'
    foreach ($k in $keys) {
        $script:CmpWait[$k] = $true
        $ok = Start-HUJob -Name "Cmp-$gen-$k" -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; Gen = $gen; IsMu = [bool]($muster -and $k -eq (Get-HUMusterKey)); PK = $(if ($muster) { $muster.Packages } else { $null }) } -Code {
            $rows = @()
            # Muster: Bestand aus den angehakten Paketen (Backup-Staende), nicht live - je Zeile mit Quell-Tenant (Origin)
            try { $rows = $(if ($IsMu) { @(Get-HUMusterInventory @($PK | Where-Object { $_ })) } else { @(Get-HUCompareInventory -TenantKey $TK -Settings $Settings) }) }
            catch {
                Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $TK
                $rows = @([pscustomobject]@{ Tenant = $TK; Typ = '*'; Name = ''; Id = ''; Hash = ''; Copy = ''; Error = "$($_.Exception.Message)" })
            }
            [pscustomobject]@{ __CmpDone = $TK; __CmpGen = $Gen; Rows = $rows }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__CmpDone'] }) | Select-Object -First 1
            if (-not $d -or [int]$d.__CmpGen -ne $script:CmpGen) { return }
            $script:CmpWait.Remove("$($d.__CmpDone)")
            $script:CmpData["$($d.__CmpDone)"] = @($d.Rows)
            if (-not $script:CmpWait.Count) {
                $all = @($script:CmpData.Values | ForEach-Object { $_ })
                # Teilpakete: was nicht im Paket ist, zaehlt nicht als Abweichung (Gesamtstand: alles zaehlt)
                $script:CmpMatrix = @(Get-HUMusterMatrix $all $script:CmpKeys -Partial:([bool]($script:CmpMusterSel -and -not $script:CmpMusterSel.Complete)))
                Update-HUCmpGrid
            } else { Update-HUCmpHint }
        }
        if (-not $ok) { $script:CmpWait.Remove($k) }
    }
    Update-HUCmpHint
}

# Uebertragen A (2.4.1, Konzept 045): genau ein Eintrag, Quelle waehlen (Tenant oder Muster), Ziele waehlen,
# je Ziel Vorschau mit Pruefungen -> neu anlegen (ohne Zuweisungen) -> Nachpruefung, Rueckgaengig-Datei.
function Start-HUCmpCopy {
    $c = $script:Controls
    $mk = Get-HUMusterKey
    $sel = @($c['gridCmp'].SelectedItems | ForEach-Object { $_.Ref } | Where-Object { $_ })
    if ($sel.Count -ne 1) { Show-HUMessage 'Bitte genau einen Eintrag markieren - Uebertragen geht je Eintrag, mit Vorschau je Ziel-Tenant.' -Icon Info; return }
    $m = $sel[0]
    if ($m.Dupe) { Show-HUMessage "'$($m.Name)' ist in einem Tenant doppelt - wird nicht uebertragen (unklar, welche Fassung die richtige ist)." -Icon Warning; return }
    # 2.4.4: Entra-Einstellungen (nur aus dem Muster, 045 F6)
    $ek = ''
    if (Get-Command Get-HUEntraTransferPlan -ErrorAction SilentlyContinue) { $ek = Get-HUEntraRestoreKind $m.Typ (Get-HUCmpEntraId $m) }
    if ($ek -in 'authz', 'consent', 'location', 'groupSetting', 'caNew') { Start-HUCmpEntraCopy $m; return }
    if (-not (@(Get-HUCompareSources | Where-Object { $_.Typ -eq $m.Typ -and $_.Copy }).Count)) { Show-HUMessage "$($m.Typ) laesst sich (noch) nicht uebertragen.`n`nApps ueber die Bibliothek verteilen; Autopilot und die weiteren Arten werden vorerst nur verglichen." -Icon Info; return }
    $have = @($m.Items | ForEach-Object { $_.Tenant } | Select-Object -Unique)
    $srcKey = $have[0]
    if ($have.Count -gt 1) {
        $pick = @(Show-HUTenantChoice -Title 'Quelle' -Text "Von welchem Tenant soll '$($m.Name)' uebernommen werden? Genau einen anhaken." -Keys $have -OkText 'Weiter')
        if (-not $pick.Count) { return }
        if ($pick.Count -ne 1) { Show-HUMessage 'Bitte genau eine Quelle anhaken.' -Icon Warning; return }
        $srcKey = $pick[0]
    }
    $srcItem = @($m.Items | Where-Object { $_.Tenant -eq $srcKey })[0]
    $missing = @($m.Missing | Where-Object { $_ -ne $mk })
    # 2.4.2 Angleichen: Ziele, in denen es den Eintrag gibt, aber mit anderem Fingerabdruck (nur Arten mit PATCH-Weg)
    $diff = @()
    if ($m.Copy -in @('generic', 'compliance') -and "$($srcItem.Hash)") {
        $diff = @($m.Items | Where-Object { $_.Tenant -ne $mk -and $_.Tenant -ne $srcKey -and "$($_.Hash)" -and "$($_.Hash)" -ne "$($srcItem.Hash)" } | ForEach-Object { $_.Tenant } | Select-Object -Unique)
    }
    $targets = @($missing + $diff)
    if (-not $targets.Count) { Show-HUMessage "'$($m.Name)' fehlt in keinem angehakten Tenant und weicht nirgends ab (oder diese Art wird noch nicht angeglichen - Einstellungskatalog und Administrative Vorlage folgen spaeter)." -Icon Info; return }
    $txt = "'$($m.Name)' aus $(Get-HUAnaTenantName $srcKey) uebertragen - je Tenant folgt eine eigene Vorschau."
    if ($missing.Count) { $txt += "`nFehlt (wird NEU angelegt, ohne Zuweisungen): $(@($missing | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
    if ($diff.Count) { $txt += "`nWeicht ab (wird ANGEGLICHEN, Zuweisungen bleiben): $(@($diff | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
    $tg = @(Show-HUTenantChoice -Title 'Uebertragen nach' -Text $txt -Keys $targets -OkText 'Weiter')
    if (-not $tg.Count) { return }
    # Muster: Namen (Gruppen, Orte, Bereichsmarkierungen) im Tenant nachschlagen, aus dem der Eintrag stammt
    $resolve = $srcKey
    if ($srcKey -eq $mk) { $resolve = $(if ($srcItem.PSObject.Properties['Origin'] -and "$($srcItem.Origin)") { "$($srcItem.Origin)" } else { '' }) }
    # mitgelieferte Eintraege: Namen (Rollen, Microsoft-Apps) in einem eigenen Tenant nachschlagen - die Kennungen sind ueberall gleich
    $resolve = Get-HUMusterResolveKey $script:Settings $resolve
    $modes = @{}; $tids = @{}
    foreach ($t in $targets) {
        $modes[$t] = $(if ($diff -contains $t) { 'align' } else { 'new' })
        $ti = @($m.Items | Where-Object { $_.Tenant -eq $t })
        $tids[$t] = $(if ($ti.Count) { "$($ti[0].Id)" } else { '' })
    }
    $script:TrQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($t in $tg) { $script:TrQueue.Enqueue($t) }
    $script:TrCtx = @{ Typ = $m.Typ; Name = $m.Name; Src = $srcKey; SrcLabel = (Get-HUAnaTenantName $srcKey); Resolve = $resolve; TagNames = $(if ($srcKey -eq $mk -and $resolve -and $script:CmpMusterSel) { Get-HUMusterTagNames $script:CmpMusterSel.Folders $resolve } else { @{} })
        Obj = $(if ($srcItem.PSObject.Properties['Obj'] -and $null -ne $srcItem.Obj) { $srcItem.Obj } else { $null }); Id = $srcItem.Id; Multi = ($tg.Count -gt 1); Done = 0; DoneNames = (New-Object System.Collections.Generic.List[string]); Cur = ''
        Modes = $modes; TIds = $tids }
    Start-HUTransferNext
}

# Kennung einer Entra-Einzeleinstellung fuer die Zeile: erst die Kennungen der Eintraege (Live = Schluessel wie 'authorizationPolicy'),
# sonst ueber den Anzeigenamen der Backup-Quelle (das Muster aus dem Backup kann eine andere Kennung tragen)
function Get-HUCmpEntraId($M) {
    foreach ($it in @($M.Items)) { $id = "$($it.Id)"; if ($id -and (Get-HUEntraRestoreKind $M.Typ $id)) { return $id } }
    if ($M.Typ -eq 'Entra-Einstellung') {
        try { $src = @(Get-HUBackupEntraSources | Where-Object { $_.Typ -eq $M.Typ -and "$($_.Title)" -eq "$($M.Name)" }) | Select-Object -First 1; if ($src) { return "$($src.Key)" } } catch { }
    }
    return "$(@($M.Items)[0].Id)"
}

# Entra-Einstellung aus dem Muster in andere Tenants (045 Abschnitt 6, F6): Quelle ist immer der festgehaltene Muster-Stand
function Start-HUCmpEntraCopy($M) {
    $mk = Get-HUMusterKey
    $mi = @($M.Items | Where-Object { $_.Tenant -eq $mk })
    if (-not $mi.Count -or $null -eq $mi[0].Obj) { Show-HUMessage "Entra-Einstellungen und Conditional Access werden nur aus dem Muster uebertragen (bewusst festgehaltener Soll-Stand).`n`nIm Reiter Muster ein Paket mit '$($M.Name)' anhaken, hier den Haken 'Muster' setzen und Vergleich einlesen." -Icon Info; return }
    # Quell-Tenant des Muster-Eintrags (Namen dort nachschlagen; dieser Tenant wird nicht als Ziel angeboten)
    $src = "$(if ($mi[0].PSObject.Properties['Origin']) { $mi[0].Origin })"
    if (-not $src) { Show-HUMessage "Fuer '$($M.Name)' im Muster ist der Quell-Tenant nicht bekannt - bitte das Paket neu speichern." -Icon Warning; return }
    $mh = "$($mi[0].Hash)"
    $missing = @($M.Missing | Where-Object { $_ -ne $mk -and $_ -ne $src })
    $diff = @($M.Items | Where-Object { $_.Tenant -ne $mk -and $_.Tenant -ne $src -and "$($_.Hash)" -ne $mh } | ForEach-Object { $_.Tenant } | Select-Object -Unique)
    $targets = @($missing + $diff | Select-Object -Unique)
    if (-not $targets.Count) { Show-HUMessage "'$($M.Name)' ist in allen angehakten Tenants schon wie im Muster (der Tenant, aus dem das Muster stammt, wird nicht angeboten)." -Icon Info; return }
    $txt = "'$($M.Name)' aus dem Muster uebertragen - je Tenant eine eigene Vorschau, Bestaetigung mit dem Tenant-Namen."
    if ($M.Typ -eq 'Conditional Access') {
        # 045 Ue-7: nie eine bestehende Richtlinie aendern - immer eine NEUE im Modus Nur Bericht
        $txt = "'$($M.Name)' aus dem Muster als NEUE Richtlinie im Modus NUR BERICHT anlegen, ohne Konten (Gruppen in der Vorschau waehlbar) - bestehende Richtlinien bleiben unveraendert. Je Tenant eine eigene Vorschau, Bestaetigung mit dem Tenant-Namen."
        if ($missing.Count) { $txt += "`nFehlt (mit gleichem Namen anlegen): $(@($missing | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
        if ($diff.Count) { $txt += "`nGibt es anders (zusaetzlich '$($M.Name) (von Muster)' zum Vergleichen): $(@($diff | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
    } else {
        if ($missing.Count) { $txt += "`nFehlt (wird NEU angelegt): $(@($missing | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
        if ($diff.Count) { $txt += "`nWeicht ab (wird ANGEGLICHEN): $(@($diff | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" }
    }
    $tg = @(Show-HUTenantChoice -Title 'Uebertragen nach' -Text $txt -Keys $targets -OkText 'Weiter')
    if (-not $tg.Count) { return }
    $modes = @{}; foreach ($t in $targets) { $modes[$t] = 'entra' }
    $script:TrQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($t in $tg) { $script:TrQueue.Enqueue($t) }
    $script:TrCtx = @{ Typ = $M.Typ; Name = $M.Name; Src = $mk; SrcLabel = (Get-HUAnaTenantName $mk); Resolve = $src; Obj = $mi[0].Obj; Id = $(if ($M.Typ -eq 'Entra-Einstellung') { Get-HUCmpEntraId $M } else { "$($mi[0].Id)" })
        Multi = ($tg.Count -gt 1); Done = 0; DoneNames = (New-Object System.Collections.Generic.List[string]); Cur = ''; Modes = $modes; TIds = @{}; Entra = $true
        LocNames = $(if ($script:CmpMusterSel) { Get-HUMusterLocationNames @($script:CmpMusterSel.Folders) } else { @{} }) }
    Start-HUTransferNext
}

# Vergleich neu laden; bei Entra/CA erst nach 10 s (neu Angelegtes/Geloeschtes steht erst dann richtig in der Liste)
function Start-HUCmpRunDelayed([switch]$Entra) {
    if (-not $Entra) { Start-HUCmpRun; return }
    Add-HURtbLine $script:Controls['rtbAna'] 'Vergleich wird in 10 Sekunden neu geladen (Entra braucht kurz, bis die Aenderung in der Liste steht).' '#90CAF9'
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(10)
    $t.Add_Tick({ param($s, $e) try { $s.Stop() } catch { }; Start-HUCmpRun })
    $t.Start()
}

# naechstes Ziel aus der Warteschlange: Plan lesen -> Vorschau -> schreiben -> Ergebnis -> weiter
function Start-HUTransferNext {
    $c = $script:Controls
    if (-not $script:TrQueue -or -not $script:TrQueue.Count) {
        $x = $script:TrCtx
        if ($x -and $x.Done) {
            if ($x.Multi -and -not $x.Entra) { Show-HUMessage "'$($x.Name)' neu angelegt in: $(@($x.DoneNames) -join ', ').`n`nNoch OHNE Zuweisungen - zum Wirken im jeweiligen Tenant zuweisen (Zuweisungen werden nicht uebertragen)." -Icon Info }
            Add-HURtbLine $c['rtbAna'] 'Uebertragen fertig.' '#90CAF9'
            Start-HUCmpRunDelayed -Entra:([bool]$x.Entra)
        }
        return
    }
    $t = $script:TrQueue.Dequeue()
    $script:TrCtx.Cur = (Get-HUAnaTenantName $t)
    $x = $script:TrCtx
    Add-HURtbLine $c['rtbAna'] "Pruefe '$($x.Name)' fuer $(Get-HUAnaTenantName $t) ..." '#90CAF9'
    $mode = "$($x.Modes[$t])"; $tid = "$($x.TIds[$t])"
    [void](Start-HUJob -Name 'TransferPlan' -Quiet -Output $c['rtbAna'] -Vars @{ X = $x; T = $t; Mode = $mode; Tid = $tid } -Code {
            try {
                $o = if ($null -ne $X.Obj) { $X.Obj } else { Get-HUCompareObject -TenantKey $X.Src -Settings $Settings -Typ $X.Typ -Id $X.Id }
                $p = if ($Mode -eq 'entra') { Get-HUEntraTransferPlan -TargetKey $T -Settings $Settings -Typ $X.Typ -Id $X.Id -Name $X.Name -Backup $o -ResolveKey $X.Resolve -SourceLabel $X.SrcLabel -SourceNames $(if ($X.LocNames) { $X.LocNames } else { @{} }) }
                elseif ($Mode -eq 'align') { Get-HUTransferAlignPlan -Settings $Settings -Typ $X.Typ -SourceObj $o -SourceKey $X.Src -ResolveKey $X.Resolve -SourceLabel $X.SrcLabel -TargetKey $T -TargetId $Tid }
                else { Get-HUTransferPlan -Settings $Settings -Typ $X.Typ -SourceObj $o -SourceKey $X.Src -ResolveKey $X.Resolve -SourceLabel $X.SrcLabel -TargetKey $T -SourceTagNames $(if ($X.TagNames) { $X.TagNames } else { @{} }) }
                [pscustomobject]@{ __Plan = $p }
            } catch { [pscustomobject]@{ __PlanError = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $r = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__Plan'] -or $_.PSObject.Properties['__PlanError']) }) | Select-Object -First 1
            if (-not $r) { Show-HUMessage 'Vorschau fehlgeschlagen (siehe Protokoll).' -Icon Error; Start-HUTransferNext; return }
            if ($r.PSObject.Properties['__PlanError']) { Show-HUMessage "Vorschau fehlgeschlagen: $($r.__PlanError)" -Icon Error; Start-HUTransferNext; return }
            $plan = $r.__Plan
            $tn = Get-HUAnaTenantName $plan.TenantKey
            # 045 Ue-10: bei mehreren Zielen und bei Entra immer den Ziel-Tenant-Namen eintippen
            if ($script:TrCtx.Multi -or $plan.PSObject.Properties['Transfer']) { $plan | Add-Member -NotePropertyName TypeToConfirm -NotePropertyValue $tn -Force }
            $rest = $(if ($script:TrQueue) { $script:TrQueue.Count } else { 0 })
            if (-not (Show-HUEntraRestorePreview $plan $tn '' -Remaining $rest)) {
                # 2.5.1: Abbrechen beendet das ganze Uebertragen (vorher kamen alle weiteren Ziele trotzdem nacheinander); Ueberspringen = naechstes Ziel
                if ("$script:ErPreviewChoice" -eq 'skip') { Add-HURtbLine $script:Controls['rtbAna'] "$tn`: uebersprungen." '#AAAAAA'; Start-HUTransferNext; return }
                $n = $rest; if ($script:TrQueue) { $script:TrQueue.Clear() }
                Add-HURtbLine $script:Controls['rtbAna'] "$tn`: nicht uebertragen - Uebertragen abgebrochen$(if ($n) { " ($n weitere Ziel(e) nicht mehr vorbereitet)" })." '#AAAAAA'
                Start-HUTransferNext; return
            }
            [void](Start-HUJob -Name 'TransferWrite' -Output $script:Controls['rtbAna'] -Vars @{ Plan = $plan } -Code {
                    try {
                        $isE = [bool]$Plan.PSObject.Properties['Transfer']
                        [pscustomobject]@{ __Res = $(if ($isE) { Invoke-HUEntraTransfer -Plan $Plan -Settings $Settings } elseif ("$($Plan.Kind)" -eq 'transferAlign') { Invoke-HUTransferAlign -Plan $Plan -Settings $Settings } else { Invoke-HUTransfer -Plan $Plan -Settings $Settings }); __Kind = $(if ($isE) { 'entra' } else { "$($Plan.Kind)" }); __New = ("$($Plan.Method)" -eq 'POST'); __Ca = ("$($Plan.Kind)" -eq 'caNew'); __State = "$(if ($Plan.Body) { $Plan.Body['state'] })" }
                    }
                    catch { Write-HULog -Message "$($Plan.Typ) '$($Plan.Name)': $($_.Exception.Message)" -Level 'ERROR' -Tenant $Plan.TenantKey; [pscustomobject]@{ __ResError = "$($_.Exception.Message)" } }
                } -OnDone {
                    param($Result, $Errors)
                    $r2 = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__Res'] -or $_.PSObject.Properties['__ResError']) }) | Select-Object -First 1
                    if (-not $r2) { Show-HUMessage 'Uebertragen: kein Ergebnis (siehe Protokoll).' -Icon Error }
                    elseif ($r2.PSObject.Properties['__ResError']) { Show-HUMessage "Nicht uebertragen:`n`n$($r2.__ResError)" -Icon Error }
                    else {
                        $res = $r2.__Res; $script:TrCtx.Done++; [void]$script:TrCtx.DoneNames.Add("$($script:TrCtx.Cur)")
                        $isAl = ("$($r2.__Kind)" -eq 'transferAlign' -or ("$($r2.__Kind)" -eq 'entra' -and -not $r2.__New))
                        $txt = if ($r2.__Ca) { "Neue Richtlinie angelegt im Modus $(if ($r2.__State -eq 'disabled') { 'AUS (Benutzeraktionen)' } else { 'NUR BERICHT' }) - sie erzwingt nichts. Erst im Anmeldeprotokoll (Bericht) pruefen, dann im Portal selbst einschalten und die alte Richtlinie entfernen.$(if ($res.UndoFile) { ' Rueckgaengig (loeschen, solange nicht eingeschaltet): Tenant-Vergleich > Rueckgaengig ...' })" }
                        elseif ("$($r2.__Kind)" -eq 'entra') { "$(if ($r2.__New) { 'Im Ziel neu angelegt' } else { 'Im Ziel angeglichen (Stand davor gesichert)' }) - wie im Muster.$(if ($res.UndoFile) { ' Rueckgaengig: Tenant-Vergleich > Rueckgaengig ...' } else { ' Rueckgaengig ist hierfuer nicht vorgesehen.' })" }
                        elseif ($isAl) { "Angeglichen - das Objekt im Ziel hat jetzt die Einstellungen der Quelle. Zuweisungen unveraendert. Rueckgaengig: Tenant-Vergleich > Rueckgaengig ..." }
                        else { "Neu angelegt (Id $($res.NewId)), ohne Zuweisungen - zum Wirken im Ziel zuweisen. Rueckgaengig: Tenant-Vergleich > Rueckgaengig ..." }
                        if ($res.Mismatch.Count) { $txt += "`n`nNachpruefung - $($res.Mismatch.Count) Einstellung(en) weichen von der Quelle ab:`n$(@($res.Mismatch | Select-Object -First 12) -join "`n")$(if ($res.Mismatch.Count -gt 12) { "`n..." })" } else { $txt += "`n`nNachpruefung: alle Einstellungen wie in der Quelle." }
                        if ($res.Dropped.Count) { $txt += "`n`nNicht uebernommen: $($res.Dropped -join '; ')" }
                        if ($res.Ok) { Show-HUMessage $txt -Icon Info }
                        elseif (-not "$($res.UndoFile)") { Show-HUMessage "ACHTUNG - im Ziel ist nicht alles wie in der Quelle angekommen.`n`n$txt" -Icon Warning }
                        # 047 F3: Abweichung deutlich melden und Rueckgaengig direkt anbieten (nicht automatisch)
                        elseif (Confirm-HU "ACHTUNG - im Ziel ist nicht alles wie in der Quelle angekommen.`n`n$txt`n`nJetzt rueckgaengig machen ($(if ($isAl) { 'den Stand vor dem Angleichen wiederherstellen' } else { 'das neu angelegte Objekt wieder loeschen' }))?" -Warning) {
                            [void](Start-HUJob -Name 'TransferUndo' -Output $script:Controls['rtbAna'] -Vars @{ F = $res.UndoFile } -Code {
                                    try { $u = Undo-HUTransfer -Settings $Settings -File $F; Write-HULog -Message $u.Text -Level 'OK' }
                                    catch { Write-HULog -Message "Rueckgaengig: $($_.Exception.Message)" -Level 'ERROR' }
                                })
                        }
                    }
                    Start-HUTransferNext
                })
        })
}

# Rueckgaengig: zuvor uebertragene (neu angelegte) Objekte wieder loeschen - nur wenn seitdem unveraendert
function Start-HUTransferUndo {
    $c = $script:Controls
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'] | Where-Object { $_ })
    # nichts angehakt (z. B. nach Neustart): die Tenants des geladenen Vergleichs nehmen
    if (-not $keys.Count) { $keys = @(@($script:CmpKeys) | Where-Object { $_ -and $_ -ne (Get-HUMusterKey) }) }
    if (-not $keys.Count) { Show-HUMessage 'Bitte oben die Tenants anhaken, in denen rueckgaengig gemacht werden soll.' -Icon Info; return }
    $list = @(Get-HUTransferUndoList -Settings $script:Settings -Keys $keys)
    if (-not $list.Count) { Show-HUMessage 'In den angehakten Tenants gibt es nichts rueckgaengig zu machen (keine Uebertragungen gespeichert).' -Icon Info; return }
    # je Eintrag live pruefen, ob Rueckgaengig gerade moeglich ist (liest nur), dann erst das Fenster
    Add-HURtbLine $c['rtbAna'] "Pruefe $($list.Count) Rueckgaengig-Eintraege ..." '#90CAF9'
    [void](Start-HUJob -Name 'UndoCheck' -Quiet -Output $c['rtbAna'] -Vars @{ L = $list } -Code {
            $o = foreach ($e in $L) {
                $st = Get-HUTransferUndoStatus -Settings $Settings -File $e.Datei
                $e | Add-Member -NotePropertyName Ok -NotePropertyValue ([bool]$st.Ok) -Force -PassThru |
                    Add-Member -NotePropertyName Moeglich -NotePropertyValue $(if ($st.Ok) { 'ja' } else { "nein - $($st.Text)" }) -Force -PassThru |
                    Add-Member -NotePropertyName Aktion -NotePropertyValue $(if ($e.Was -eq 'angeglichen') { 'Stand zuruecksetzen' } else { 'LOESCHEN im Ziel' }) -Force -PassThru
            }
            [pscustomobject]@{ __UndoList = @($o) }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__UndoList'] }) | Select-Object -First 1
            if (-not $d) { Show-HUMessage 'Rueckgaengig-Eintraege konnten nicht geprueft werden (siehe Protokoll).' -Icon Error; return }
            Show-HUTransferUndoDialog @($d.__UndoList)
        })
}

function Show-HUTransferUndoDialog([object[]]$List) {
    $c = $script:Controls
    $list = @($List)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1040" Height="480" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="16">
        <TextBlock DockPanel.Dock="Top" Foreground="#E0E0E0" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Spalte 'Rueckgaengig =' sagt, was passiert: LOESCHEN im Ziel (neu Angelegtes) oder Stand zuruecksetzen (Angeglichenes). Spalte 'Jetzt moeglich' wurde eben live geprueft - 'nein' nennt den Grund (z. B. seitdem geaendert oder zugewiesen); solche Zeilen lassen sich nicht ausfuehren."/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnOk" Content="Rueckgaengig ..." Width="140" Background="#B71C1C" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Extended">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Tenant" Binding="{Binding TenantName}" Width="140"/>
                <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="140"/>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="Auto"/>
                <DataGridTextColumn Header="Was" Binding="{Binding Was}" Width="95"/>
                <DataGridTextColumn Header="Rueckgaengig =" Binding="{Binding Aktion}" Width="140"/>
                <DataGridTextColumn Header="Jetzt moeglich" Binding="{Binding Moeglich}" Width="260"/>
                <DataGridTextColumn Header="Uebertragen" Binding="{Binding Zeit}" Width="140"/>
                <DataGridTextColumn Header="Quelle" Binding="{Binding Quelle}" Width="110"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mm = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mm.Groups[1].Value))
    $w = $d.Window; $dc = $d.C
    $w.Title = 'Uebertragen rueckgaengig'
    # Fenster so breit wie die Spalten (alle nach Inhalt), hoechstens 95 % des Bildschirms
    $w.Add_ContentRendered({
            try {
                $sum = 0; foreach ($col in @($dc.grid.Columns)) { $sum += $col.ActualWidth }
                $wa = [System.Windows.SystemParameters]::WorkArea
                $w.Width = [Math]::Max(700, [Math]::Min([Math]::Floor($wa.Width * 0.95), ($sum + 70) * (Get-HUUiScaleValue)))
                $w.Left = $wa.Left + [Math]::Max(0, ($wa.Width - $w.Width) / 2)
            } catch { }
        })
    $dc.grid.ItemsSource = @($list | ForEach-Object { $_ | Add-Member -NotePropertyName TenantName -NotePropertyValue (Get-HUAnaTenantName $_.Tenant) -Force -PassThru })
    $state = @{ Sel = @() }
    $dc.btnOk.Add_Click({
            $state.Sel = @($dc.grid.SelectedItems)
            if (-not $state.Sel.Count) { Show-HUMessage 'Bitte Eintraege markieren.' -Icon Info -Owner $w; return }
            $no = @($state.Sel | Where-Object { -not $_.Ok })
            if ($no.Count) { Show-HUMessage "Gerade nicht moeglich:`n`n$(@($no | ForEach-Object { "  $($_.TenantName): '$($_.Name)' - $($_.Moeglich)" }) -join "`n")`n`nBitte nur Zeilen mit 'Jetzt moeglich = ja' markieren." -Icon Warning -Owner $w; $state.Sel = @(); return }
            if (-not (Confirm-HU "$($state.Sel.Count) Objekt(e) rueckgaengig machen?`n`n$(@($state.Sel | Select-Object -First 10 | ForEach-Object { "  $($_.TenantName): $($_.Typ) '$($_.Name)' - $($_.Aktion)" }) -join "`n")" -Warning -Owner $w)) { $state.Sel = @(); return }
            $w.Close()
        })
    [void]$w.ShowDialog()
    if (-not $state.Sel.Count) { return }
    $files = @($state.Sel | ForEach-Object { $_.Datei })
    # Entra/CA (nicht Intune): nach dem Loeschen erst nach 10 s neu laden
    $script:UndoEntra = [bool]@($state.Sel | Where-Object { $_.Typ -in 'Conditional Access', 'Benannter Ort', 'Verzeichniseinstellung', 'Entra-Einstellung' }).Count
    [void](Start-HUJob -Name 'TransferUndo' -Output $c['rtbAna'] -Vars @{ Files = $files } -Code {
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($f in $Files) {
                try { $r = Undo-HUTransfer -Settings $Settings -File $f; Write-HULog -Message $r.Text -Level 'OK'; [void]$out.Add($r.Text) }
                catch { Write-HULog -Message "Rueckgaengig: $($_.Exception.Message)" -Level 'ERROR'; [void]$out.Add("NICHT rueckgaengig: $($_.Exception.Message)") }
            }
            [pscustomobject]@{ __UndoDone = @($out.ToArray()) }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__UndoDone'] }) | Select-Object -First 1
            if ($d) {
                $lines = @($d.__UndoDone)
                Show-HUMessage ($lines -join "`n`n") -Icon $(if (@($lines | Where-Object { $_ -like 'NICHT*' }).Count) { 'Warning' } else { 'Info' })
            }
            if (@($script:CmpKeys).Count) { Start-HUCmpRunDelayed -Entra:([bool]$script:UndoEntra) }
        })
}

# Namenszuordnung (nur lesen): Gruppen, Orte, Filter, Bereichsmarkierungen der Quelle in den Ziel-Tenants nach Name suchen.
# Quelle: Mustertenant (wenn angehakt), sonst der neueste vollstaendige Backup-Stand des ersten angehakten Tenants.
function Start-HUCmpMap {
    $c = $script:Controls
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'])
    $folder = @(); $src = ''; $label = ''
    $muster = $null
    if ($c['chkCmpMuster'].IsChecked) { $muster = Get-HUMusterSelectionUi }
    if ($muster) { $folder = @($muster.Folders); $src = ''; $label = $muster.Label }
    elseif ($keys.Count) {
        $src = $keys[0]
        $st = @(Get-HUBackupList -Root (Get-HUBakRootSafe) -TenantKey $src | Where-Object Complete) | Select-Object -First 1
        if (-not $st) { Show-HUMessage "Fuer $(Get-HUAnaTenantName $src) gibt es noch keinen vollstaendigen Backup-Stand - erst Backup & Verlauf > Backup jetzt." -Icon Info; return }
        $folder = @($st.Folder); $label = "$(Get-HUAnaTenantName $src), Stand $($st.Label)"
    }
    $targets = @($keys | Where-Object { $_ -ne $src })
    if (-not @($folder).Count -or -not $targets.Count) { Show-HUMessage 'Quelle (Muster oder erster angehakter Tenant) und mindestens einen weiteren Tenant anhaken.' -Icon Info; return }
    $names = @{}; foreach ($t in $targets) { $names[$t] = Get-HUAnaTenantName $t }
    $script:CmpMapLabel = $label
    Add-HURtbLine $c['rtbAna'] "Zuordnung pruefen: Quelle $label -> $(@($targets | ForEach-Object { $names[$_] }) -join ', ') ..." '#90CAF9'
    [void](Start-HUJob -Name 'CmpMap' -Quiet -Output $c['rtbAna'] -Vars @{ F = $folder; S = $src; T = $targets; N = $names } -Code {
            try { [pscustomobject]@{ __Map = @(Get-HUNameMap -Settings $Settings -Folder $F -SourceKey $S -Targets $T -Names $N) } }
            catch { [pscustomobject]@{ __MapError = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $r = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__Map'] -or $_.PSObject.Properties['__MapError']) }) | Select-Object -First 1
            if (-not $r) { Show-HUMessage 'Zuordnung: kein Ergebnis (siehe Protokoll).' -Icon Error; return }
            if ($r.PSObject.Properties['__MapError']) { Show-HUMessage "Zuordnung nicht moeglich: $($r.__MapError)" -Icon Error; return }
            $rows = @($r.__Map)
            Add-HURtbLine $script:Controls['rtbAna'] "$($rows.Count) Zeile(n) - nur Anzeige, es wird nichts geschrieben." '#81C784'
            Show-HUQSTable -Title "Namenszuordnung - Quelle $($script:CmpMapLabel)" -Objects $rows -FilePrefix 'Namenszuordnung'
        })
}

# Doppelklick: Einstellungen der Tenants gegenueberstellen - immer ALLE Werte, abweichende zuerst und markiert
function Show-HUCmpDetail {
    $r = $script:Controls['gridCmp'].SelectedItem
    if (-not $r -or -not $r.Ref) { return }
    $m = $r.Ref
    $items = @($m.Items | Group-Object Tenant | ForEach-Object { $_.Group[0] })
    # 2.5.1 Muster immer ganz links, danach die Tenants in der Reihenfolge der Vergleichstabelle
    $mkd = Get-HUMusterKey
    $ord = @($script:CmpKeys)
    $items = @(@($items | Where-Object { $_.Tenant -eq $mkd }) + @($items | Where-Object { $_.Tenant -ne $mkd } | Sort-Object { $ix = [array]::IndexOf($ord, "$($_.Tenant)"); if ($ix -lt 0) { 999 } else { $ix } }))
    if ($items.Count -lt 2) { Show-HUMessage "'$($m.Name)' gibt es nur in $(Get-HUAnaTenantName $items[0].Tenant) - nichts zu vergleichen." -Icon Info; return }
    if ($m.Typ -eq 'App') { Show-HUMessage 'Apps bitte unter Apps > In Intune vergleichen.' -Icon Info; return }
    $script:CmpDetailName = "$($m.Typ): $($m.Name)"
    $script:CmpDetailKeys = @($items | ForEach-Object { $_.Tenant })
    Add-HURtbLine $script:Controls['rtbAna'] "Lade Einstellungen von '$($m.Name)' ..." '#90CAF9'
    [void](Start-HUJob -Name 'CmpDetail' -Quiet -Output $script:Controls['rtbAna'] -Vars @{ Items = $items; MK = (Get-HUMusterKey) } -Code {
            $maps = @{}
            foreach ($it in $Items) {
                try {
                    # weitere Arten bringen das gelesene Objekt mit (Obj), die Intune-Grundarten werden vollstaendig nachgeladen
                    $o = if ($it.PSObject.Properties['Obj'] -and $null -ne $it.Obj) { $it.Obj } else { Get-HUCompareObject -TenantKey $it.Tenant -Settings $Settings -Typ $it.Typ -Id $it.Id }
                    # IDs im Muster gehoeren zum Quell-Tenant des Eintrags - Namen dort nachschlagen
                    $rk = if ($it.Tenant -eq $MK) { Get-HUMusterResolveKey $Settings "$(if ($it.PSObject.Properties['Origin']) { $it.Origin })" } else { $it.Tenant }
                    $maps[$it.Tenant] = $(if ($rk) { Resolve-HUFlatMapIds -TenantKey $rk -Settings $Settings -Map (ConvertTo-HUFlatMap $o) } else { ConvertTo-HUFlatMap $o })
                    # 2.5.1 mitgelieferte Muster: Werte, die erst beim Uebertragen aus dem Ziel kommen, als Text zeigen statt "(leer)"
                    if ($it.Tenant -eq $MK -and $o) {
                        $mp = $maps[$it.Tenant]
                        if ("$(if ($o.PSObject.Properties['huRollen']) { $o.huRollen })" -eq 'alleEingebautenAusnehmen') { $mp['conditions.users.excludeRoles'] = '(beim Uebertragen: alle eingebauten Admin-Rollen des Ziels)' }
                        if ($o.PSObject.Properties['huGruppen']) {
                            foreach ($gf in 'includeGroups', 'excludeGroups') {
                                $sl = @(@($o.huGruppen) | Where-Object { $_ -and "$($_.feld)" -eq $gf } | ForEach-Object { "$($_.name)" })
                                if ($sl.Count) { $mp["conditions.users.$gf"] = "(Platz: $($sl -join ', ') - beim Uebertragen waehlen)" }
                            }
                        }
                    }
                }
                catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $it.Tenant }
            }
            # zusaetzlich alle Einstellungen (auch gleiche), damit das Fenster immer die Werte zeigt
            $tk = @($Items | ForEach-Object { $_.Tenant })
            $allKeys = @($maps.Values | ForEach-Object { @($_.Keys) } | Sort-Object -Unique)
            $all = foreach ($k in $allKeys) {
                $o = [ordered]@{ Einstellung = "$k" }
                for ($i = 0; $i -lt $tk.Count; $i++) { $mp = $maps[$tk[$i]]; $o["T$i"] = $(if ($mp -and $mp.Contains($k)) { "$($mp[$k])" } else { '' }) }
                [pscustomobject]$o
            }
            [pscustomobject]@{ __Diff = @(Get-HUCompareDiff $maps $tk); __All = @($all); Count = $maps.Count }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Diff'] }) | Select-Object -First 1
            if (-not $d) { return }
            $keys = @($script:CmpDetailKeys)
            if ($d.Count -lt 2) { Add-HURtbLine $script:Controls['rtbAna'] 'Nicht in allen Tenants lesbar - kein Vergleich.' '#FFB74D'; return }
            $diffNames = @(@($d.__Diff) | ForEach-Object { "$($_.Einstellung)" })
            $mk = { param($x, [string]$st) $o = [ordered]@{ Unterschied = $st; Einstellung = $x.Einstellung }; for ($i = 0; $i -lt $keys.Count; $i++) { $o[(Get-HUAnaTenantName $keys[$i])] = $x."T$i" }; [pscustomobject]$o }
            # abweichende zuerst (Werte wie im Vergleich), danach alle gleichen
            $rows = @(@(@($d.__Diff) | ForEach-Object { & $mk $_ 'abweichend' }) + @(@($d.__All) | Where-Object { $diffNames -notcontains "$($_.Einstellung)" } | ForEach-Object { & $mk $_ 'gleich' }))
            if (-not $rows.Count) { Show-HUMessage "$($script:CmpDetailName)`n`nKeine Einstellungen gelesen." -Icon Info; return }
            Add-HURtbLine $script:Controls['rtbAna'] "$($diffNames.Count) abweichende, $($rows.Count - $diffNames.Count) gleiche Einstellung(en)" '#81C784'
            Show-HUQSTable -Title "Einstellungen - $($script:CmpDetailName) ($(if ($diffNames.Count) { "$($diffNames.Count) abweichend" } else { 'keine Unterschiede - nur IDs, Zeitstempel oder Name/Beschreibung' }))" -Objects $rows -FilePrefix 'Vergleich-Details'
        })
}

function Register-HUCmpHandlers {
    $c = $script:Controls
    $c['chkCmpDiff'].IsChecked = [bool](Get-HUStateValue 'cmpDiff' $true)
    $c['chkCmpDiff'].Add_Checked({ Set-HUStateValue 'cmpDiff' $true; Update-HUCmpGrid })
    $c['chkCmpDiff'].Add_Unchecked({ Set-HUStateValue 'cmpDiff' $false; Update-HUCmpGrid })
    $c['chkCmpMusterOnly'].Add_Checked({ if (-not $script:CmpMoBusy) { Update-HUCmpGrid } })
    $c['chkCmpMusterOnly'].Add_Unchecked({ if (-not $script:CmpMoBusy) { Update-HUCmpGrid } })
    $script:CmpTypeWanted = "$(Get-HUStateValue 'cmpType' '')"
    $c['cmbCmpType'].Add_SelectionChanged({
            if ($script:CmpTypeBusy) { return }
            $script:CmpTypeWanted = ("$($script:Controls['cmbCmpType'].SelectedItem)" -replace '\s+\([^)]*\)$', '')
            Set-HUStateValue 'cmpType' $script:CmpTypeWanted
            Update-HUCmpGrid
        })
    $c['txtCmpFilter'].Add_TextChanged({ Update-HUCmpGrid })
    $c['btnCmpRun'].Add_Click({ Start-HUCmpRun })
    $c['btnCmpCopy'].Add_Click({ Start-HUCmpCopy })
    $c['btnCmpUndo'].Add_Click({ Start-HUTransferUndo })
    $c['btnCmpMap'].Add_Click({ Start-HUCmpMap })
    $c['chkCmpMuster'].IsChecked = [bool](Get-HUStateValue 'cmpMuster' $false)
    $c['chkCmpMuster'].Add_Checked({ Set-HUStateValue 'cmpMuster' $true })
    $c['chkCmpMuster'].Add_Unchecked({
            Set-HUStateValue 'cmpMuster' $false
            # Muster-Spalte sofort weg (ohne neu einzulesen): Matrix aus den schon gelesenen Tenants neu bilden
            $mk = Get-HUMusterKey
            if (@($script:CmpKeys) -contains $mk -and -not $script:CmpWait.Count) {
                $script:CmpKeys = @($script:CmpKeys | Where-Object { $_ -ne $mk })
                [void]$script:CmpData.Remove($mk)
                $script:CmpMusterSel = $null; $script:CmpMusterLabel = ''
                $script:Controls['chkCmpMusterOnly'].Visibility = 'Collapsed'
                $script:CmpMatrix = $(if (@($script:CmpKeys).Count) { @(Get-HUMusterMatrix @($script:CmpData.Values | ForEach-Object { $_ }) $script:CmpKeys) } else { @() })
                Update-HUCmpGrid
            }
        })
    $c['chkCmpColor'].IsChecked = [bool](Get-HUStateValue 'cmpColor' $true)
    $c['chkCmpColor'].Add_Checked({ Set-HUStateValue 'cmpColor' $true; Update-HUCmpGrid })
    $c['chkCmpColor'].Add_Unchecked({ Set-HUStateValue 'cmpColor' $false; Update-HUCmpGrid })
    $c['gridCmp'].Add_MouseDoubleClick({ Show-HUCmpDetail })
    $c['btnCmpTable'].Add_Click({
            if (-not @($script:CmpMatrix).Count) { Show-HUMessage 'Noch keine Ergebnisse.' -Icon Info; return }
            $keys = @($script:CmpKeys)
            $rows = foreach ($m in @(Get-HUCmpVisibleRows)) {
                $o = [ordered]@{ Typ = $m.Typ; Name = $m.Name }
                foreach ($k in $keys) { $o[(Get-HUAnaTenantName $k)] = $(if ($m.Have -contains $k) { $(if ((Get-HUCmpCellText $m $k) -in 'Ein', 'Aus', 'Melden') { Get-HUCmpCellText $m $k } else { 'ja' }) } else { 'fehlt' }) }
                $o.Status = $m.Status
                [pscustomobject]$o
            }
            Show-HUQSTable -Title 'Tenant-Vergleich' -Objects @($rows) -FilePrefix 'Tenant-Vergleich'
        })
}

# ----------------------------------------------------------------------------
# Backup und Verlauf
# ----------------------------------------------------------------------------
$script:BakRows = @()
$script:BakInfo = $null
$script:BakBusy = $false

function Get-HUBakRootSafe { try { return (Get-HUBackupRoot $script:Settings) } catch { return '' } }

function Update-HUBakHint {
    $c = $script:Controls
    Set-HUAnaRunDot ([bool]$script:BakBusy)
    if ($script:BakBusy) { return }
    if (-not $script:BakInfo) { $c['lblAnaHint'].Text = 'Backup jetzt sichert die angehakten Tenants. Danach im Verlauf zwei Staende waehlen und Anzeigen: neu, geloescht, Einstellungen/Zuweisungen geaendert, umbenannt - mit Benutzer aus dem Intune-Protokoll. Doppelklick zeigt die Unterschiede.'; return }
    $all = @($script:BakRows); $vis = @(Get-HUBakVisibleRows).Count
    $chg = @($all | Where-Object { $_.Aenderung -and $_.Aenderung -notin 'gleich', 'erstmals gesichert', 'nicht mehr gesichert' }).Count
    $c['lblAnaHint'].Text = "$($script:BakInfo): $($all.Count) Eintraege$(if ($script:BakInfo -match '->') { ", $chg geaendert" })$(if ($vis -ne $all.Count) { ", $vis angezeigt" }). Wiederherstellen legt den Eintrag aus dem aelteren Stand ($(if ($script:BakA) { [datetime]::ParseExact((Split-Path $script:BakA -Leaf), 'yyyy-MM-dd_HHmmss', $null).ToString('dd.MM. HH:mm') })) neu an (Name mit Zusatz, ohne Zuweisungen; Conditional Access als neue Richtlinie im Modus Nur Bericht); Entra-Einstellungen (Autorisierung, Administratorzustimmung, benannte Orte, Verzeichniseinstellungen) werden einzeln mit Vorschau zurueckgeschrieben."
}

function Update-HUBakView {
    $c = $script:Controls
    $c['lblBakRoot'].Text = "Ablage: $(Get-HUBakRootSafe)"
    $cb = $c['cmbBakTenant']
    $cur = if ($cb.SelectedItem) { "$($cb.SelectedItem.Tag)" } else { "$(Get-HUStateValue 'bakTenant' '')" }
    $script:BakTenantBusy = $true
    $cb.Items.Clear()
    foreach ($t in @($script:Settings.tenants)) { $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Content = "$($t.displayName)"; $i.Tag = "$($t.key)"; [void]$cb.Items.Add($i) }
    $sel = @($cb.Items | Where-Object { "$($_.Tag)" -eq $cur }) | Select-Object -First 1
    if (-not $sel -and $cb.Items.Count) { $sel = $cb.Items[0] }
    $cb.SelectedItem = $sel
    $script:BakTenantBusy = $false
    Update-HUBakSnapshots
    Update-HUBakHint
}

function Update-HUBakSnapshots {
    $c = $script:Controls
    $k = if ($c['cmbBakTenant'].SelectedItem) { "$($c['cmbBakTenant'].SelectedItem.Tag)" } else { '' }
    $list = @(); $root = Get-HUBakRootSafe
    if ($k -and $root) { $list = @(Get-HUBackupList -Root $root -TenantKey $k) }
    foreach ($n in 'cmbBakA', 'cmbBakB') { $c[$n].Items.Clear() }
    $only = New-Object System.Windows.Controls.ComboBoxItem; $only.Content = '(nur linken Stand zeigen)'; $only.Tag = ''
    [void]$c['cmbBakB'].Items.Add($only)
    foreach ($s in $list) {
        foreach ($n in 'cmbBakA', 'cmbBakB') { $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Content = $s.Label; $i.Tag = $s.Folder; [void]$c[$n].Items.Add($i) }
    }
    if ($list.Count -ge 2) { $c['cmbBakA'].SelectedIndex = 1; $c['cmbBakB'].SelectedIndex = 1 }
    elseif ($list.Count -eq 1) { $c['cmbBakA'].SelectedIndex = 0; $c['cmbBakB'].SelectedIndex = 0 }
    $c['btnBakCmp'].IsEnabled = ($list.Count -gt 0)
    if (-not $list.Count -and $k) { $c['lblAnaHint'].Text = "Fuer $(Get-HUAnaTenantName $k) gibt es noch kein Backup - Tenant anhaken und Backup jetzt." }
}

function Get-HUBakVisibleRows {
    $rows = @($script:BakRows)
    if ($script:Controls['chkBakChanges'].IsChecked -and $script:BakInfo -match '->') { $rows = @($rows | Where-Object { $_.Aenderung -notin 'gleich', 'erstmals gesichert', 'nicht mehr gesichert' }) }
    $ti = $script:Controls['cmbBakTyp'].SelectedItem
    if ($ti -and "$($ti.Tag)") { $t = "$($ti.Tag)"; $rows = @($rows | Where-Object { "$($_.Typ)" -eq $t }) }
    foreach ($w in @("$($script:Controls['txtBakFilter'].Text)" -split '\s+' | Where-Object { $_ })) {
        $rows = @($rows | Where-Object { ("$($_.Typ) $($_.Name) $($_.Aenderung) $($_.Wer)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @($rows | Sort-Object Typ, Name)
}

function Update-HUBakGrid { Update-HUBakTypes; $script:Controls['gridBak'].ItemsSource = @(Get-HUBakVisibleRows); Update-HUBakHint }
# Auswahl "Art": alle Arten des angezeigten Vergleichs bzw. Stands (mit Anzahl); die gewaehlte Art bleibt, solange es sie gibt
$script:BakTypesKey = $null; $script:BakTypBusy = $false
function Update-HUBakTypes {
    $cb = $script:Controls['cmbBakTyp']
    $groups = @(@($script:BakRows) | Group-Object Typ | Sort-Object Name)
    $key = (@($groups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '|')
    if ($key -eq $script:BakTypesKey) { return }
    $script:BakTypesKey = $key
    $cur = if ($cb.SelectedItem) { "$($cb.SelectedItem.Tag)" } else { '' }
    $script:BakTypBusy = $true
    try {
        $cb.Items.Clear()
        $all = New-Object System.Windows.Controls.ComboBoxItem; $all.Content = 'Alle Arten'; $all.Tag = ''; [void]$cb.Items.Add($all)
        foreach ($g in $groups) { $i = New-Object System.Windows.Controls.ComboBoxItem; $i.Content = "$($g.Name) ($($g.Count))"; $i.Tag = "$($g.Name)"; [void]$cb.Items.Add($i) }
        $sel = @($cb.Items | Where-Object { "$($_.Tag)" -eq $cur }) | Select-Object -First 1
        $cb.SelectedItem = $(if ($sel) { $sel } else { $all })
    } finally { $script:BakTypBusy = $false }
}

function Start-HUBakNow([string[]]$Keys = @(), [switch]$Auto) {
    $c = $script:Controls
    if (-not $Keys.Count) { $Keys = @(Get-HUCheckedTenants $c['spAnaTenants']) }
    if (-not $Keys.Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning; return }
    if (Test-HUJobRunning 'Backup') { if (-not $Auto) { Show-HUMessage 'Es laeuft bereits ein Backup.' -Icon Info }; return }
    $keep = [int](Get-HUProp $script:Settings.ui 'backupKeep' 30)
    $maxDays = [int](Get-HUProp $script:Settings.ui 'backupMaxDays' 365)
    $script:BakBusy = $true
    $c['btnBakNow'].IsEnabled = $false
    Set-HUAnaRunDot $true
    $c['lblAnaHint'].Text = "Backup laeuft ($($Keys.Count) Tenant(s)) - je Tenant 1-3 Minuten ..."
    Add-HURtbLine $c['rtbAna'] "$(if ($Auto) { 'Automatisches ' })Backup: $(@($Keys | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')" '#90CAF9'
    [void](Start-HUJob -Name 'Backup' -Output $c['rtbAna'] -Vars @{ Keys = $Keys; Keep = $keep; MaxDays = $maxDays } -Code {
            $root = Get-HUBackupRoot $Settings
            foreach ($k in $Keys) {
                try {
                    $r = Save-HUTenantBackup -TenantKey $k -Settings $Settings -Root $root
                    $del = Remove-HUOldBackups -Root $root -TenantKey $k -Keep $Keep -MaxDays $MaxDays
                    if ($r.Errors) { Write-HULog -Message "Backup UNVOLLSTAENDIG: $($r.Count) Eintraege, $($r.Errors) nicht lesbar - Stand ist markiert und zaehlt nicht als vollstaendiges Backup$(if ($del) { ", $del alte Staende entfernt" })" -Level 'WARN' -Tenant $k }
                    else { Write-HULog -Message "Backup fertig: $($r.Count) Eintraege$(if ($del) { ", $del alte Staende entfernt" })" -Level 'OK' -Tenant $k }
                    if (@($r.MissingPerms).Count) { Write-HULog -Message "Nicht gesichert (Recht fehlt): $(@($r.MissingPerms) -join ', ') - Einstellungen > Berechtigungen > Fehlende Rechte erteilen" -Level 'WARN' -Tenant $k }
                } catch { Write-HULog -Message "Backup: $($_.Exception.Message)" -Level 'ERROR' -Tenant $k }
            }
        } -OnDone {
            param($Result, $Errors)
            $script:BakBusy = $false
            Set-HUAnaRunDot $false
            $script:Controls['btnBakNow'].IsEnabled = $true
            Set-HUStateValue 'bakLast' (Get-Date).ToString('s')
            if ($script:AnaMode -eq 'bak') { Update-HUBakSnapshots; Update-HUBakHint }
        })
}

function Start-HUBakCompare {
    $c = $script:Controls
    $k = "$($c['cmbBakTenant'].SelectedItem.Tag)"
    $a = $c['cmbBakA'].SelectedItem; $b = $c['cmbBakB'].SelectedItem
    if (-not $a) { return }
    $fa = "$($a.Tag)"; $fb = if ($b) { "$($b.Tag)" } else { '' }
    if ($fb -and $fa -eq $fb) { $fb = '' }
    if ($fb -and (Split-Path $fb -Leaf) -lt (Split-Path $fa -Leaf)) { $t = $fa; $fa = $fb; $fb = $t }
    $la = [datetime]::ParseExact((Split-Path $fa -Leaf), 'yyyy-MM-dd_HHmmss', $null)
    $script:BakA = $fa; $script:BakB = $fb; $script:BakTenant = $k
    if (-not $fb) {
        $ix = Read-HUJsonFile (Join-Path $fa 'index.json')
        $script:BakRows = @(@($ix.Items) | ForEach-Object { [pscustomobject]@{ Typ = $_.Typ; Name = $_.Name; Aenderung = ''; Wer = ''; Id = $_.Id; FileA = $(if ($_.File) { Join-Path $fa $_.File } else { '' }); FileB = '' } })
        $script:BakInfo = "$(Get-HUAnaTenantName $k), Stand $($la.ToString('dd.MM.yyyy HH:mm'))"
        Update-HUBakGrid
        return
    }
    $lb = [datetime]::ParseExact((Split-Path $fb -Leaf), 'yyyy-MM-dd_HHmmss', $null)
    $rows = @(Compare-HUBackups -FolderA $fa -FolderB $fb | ForEach-Object { $_ | Add-Member -NotePropertyName Wer -NotePropertyValue '' -PassThru })
    $inc = @(@($fa, $fb) | Where-Object { $ixc = Read-HUJsonFile (Join-Path $_ 'index.json'); $ixc -and (($ixc.PSObject.Properties['Complete'] -and -not $ixc.Complete) -or [int]$ixc.Errors -gt 0) })
    if ($inc.Count) { Add-HURtbLine $c['rtbAna'] "Achtung: $($inc.Count) der beiden Staende ist unvollstaendig - betroffene Eintraege stehen als 'unbekannt', nicht als 'neu'/'geloescht'." '#FFB74D' }
    $script:BakRows = $rows
    $script:BakInfo = "$(Get-HUAnaTenantName $k), $($la.ToString('dd.MM. HH:mm')) -> $($lb.ToString('dd.MM. HH:mm'))"
    Update-HUBakGrid
    # wer hat geaendert: Intune-Protokoll zwischen den beiden Staenden
    $ids = @($rows | Where-Object { $_.Aenderung -notin 'gleich', 'erstmals gesichert', 'nicht mehr gesichert' } | ForEach-Object { "$($_.Id)" })
    if (-not $ids.Count) { return }
    [void](Start-HUJob -Name 'BakAudit' -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; From = $la.AddMinutes(-1); To = $lb.AddMinutes(1); Ids = $ids } -Code {
            try { $ev = @(Get-HUAuditEvents -TenantKey $TK -Settings $Settings -From $From -To $To) }
            catch { Write-HULog -Message "Intune-Protokoll nicht lesbar ($($_.Exception.Message)) - Berechtigung DeviceManagementConfiguration.Read.All bzw. DeviceManagementApps.Read.All" -Level 'WARN' -Tenant $TK; return }
            foreach ($g in @($ev | Where-Object { $Ids -contains $_.ResourceId } | Group-Object ResourceId)) {
                [pscustomobject]@{ __Audit = $g.Name; Text = (@($g.Group | Sort-Object Time | ForEach-Object { "$($_.Actor) ($($_.Time.ToLocalTime().ToString('dd.MM. HH:mm')))" } | Select-Object -Unique) -join '; ') }
            }
        } -OnDone {
            param($Result, $Errors)
            foreach ($x in @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Audit'] })) {
                foreach ($r in @($script:BakRows | Where-Object { "$($_.Id)" -eq "$($x.__Audit)" })) { $r.Wer = $x.Text }
            }
            Update-HUBakGrid
        })
}

function Show-HUBakDetail {
    $r = $script:Controls['gridBak'].SelectedItem
    if (-not $r) { return }
    if (-not $r.FileA -and -not $r.FileB) { Show-HUMessage 'Apps sind nur als Liste gesichert.' -Icon Info; return }
    if ($r.FileA -and $r.FileB) {
        $la = Split-Path $script:BakA -Leaf; $lb = Split-Path $script:BakB -Leaf
        $d = @(Get-HUBackupItemDiff $r.FileA $r.FileB)
        if (-not $d.Count) { Show-HUMessage "$($r.Typ): $($r.Name)`n`nKeine Unterschiede in Einstellungen und Zuweisungen." -Icon Info; return }
        $rows = @($d | ForEach-Object { [pscustomobject][ordered]@{ Einstellung = $_.Einstellung; "Stand $la" = $_.T0; "Stand $lb" = $_.T1 } })
        Show-HUQSTable -Title "Aenderungen - $($r.Typ): $($r.Name)" -Objects $rows -FilePrefix 'Backup-Aenderungen'
        return
    }
    # nur ein Stand: alle Einstellungen anzeigen
    $f = if ($r.FileA) { $r.FileA } else { $r.FileB }
    $m = ConvertTo-HUFlatMap (Read-HUJsonFile $f) -WithAssignments
    $rows = @($m.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Einstellung = $_; Wert = $m[$_] } })
    Show-HUQSTable -Title "$($r.Typ): $($r.Name)" -Objects $rows -FilePrefix 'Backup-Eintrag'
}

function Start-HUBakRestore {
    $c = $script:Controls
    $sel = @($c['gridBak'].SelectedItems | Where-Object { $_.FileA })
    if (-not $sel.Count) { Show-HUMessage 'Bitte Eintraege markieren, die es im aelteren Stand gibt (neue Eintraege gibt es dort noch nicht).' -Icon Info; return }
    # Entra-Einstellungen: einzeln zurueckschreiben (Vorschau, Sicherung, Nachpruefung) - nur die freigegebenen Arten
    $entra = @($sel | Where-Object { Get-HUEntraRestoreKind "$($_.Typ)" "$($_.Id)" })
    if ($entra.Count) {
        if ($sel.Count -gt 1) { Show-HUMessage 'Entra-Einstellungen und Conditional Access werden einzeln mit Vorschau zurueckgeschrieben - bitte genau einen Eintrag markieren.' -Icon Info; return }
        Start-HUEntraRestore $entra[0]; return
    }
    $ok = @(Get-HUCompareSources | Where-Object { $_.Copy } | ForEach-Object { $_.Typ })
    $skip = @($sel | Where-Object { $ok -notcontains "$($_.Typ)" })
    $sel = @($sel | Where-Object { $ok -contains "$($_.Typ)" })
    if (-not $sel.Count) { Show-HUMessage "Diese Eintraege lassen sich noch nicht wiederherstellen ($(@($skip | ForEach-Object { $_.Typ } | Sort-Object -Unique) -join ', ')).`n`nSie werden gesichert und im Verlauf verglichen. Einzeln mit Vorschau zurueckschreiben geht fuer: Autorisierungsrichtlinie, Administratorzustimmung, benannte Orte, Verzeichniseinstellungen, Conditional Access (als 'Nur Bericht')." -Icon Info; return }
    $k = $script:BakTenant
    $stamp = (Split-Path $script:BakA -Leaf).Substring(0, 10)
    $lines = @($sel | Select-Object -First 15 | ForEach-Object { "  $($_.Typ): $($_.Name)" })
    if (-not (Confirm-HU "$($sel.Count) Eintrag/Eintraege aus dem Stand $stamp in $(Get-HUAnaTenantName $k) NEU anlegen:`n`n$($lines -join "`n")$(if ($sel.Count -gt 15) { "`n  ..." })`n`nName mit Zusatz '(wiederhergestellt $stamp)', OHNE Zuweisungen - der bestehende Eintrag bleibt unveraendert.`n`nDanach vergleichen, zuweisen und den alten Eintrag selbst entfernen.$(if ($skip.Count) { "`n`nNicht dabei ($($skip.Count)): $(@($skip | ForEach-Object { $_.Typ } | Sort-Object -Unique) -join ', ') - lassen sich so nicht wiederherstellen." })")) { return }
    $jobs = @($sel | ForEach-Object { [pscustomobject]@{ Typ = $_.Typ; Name = $_.Name; File = $_.FileA } })
    [void](Start-HUJob -Name 'BakRestore' -Output $c['rtbAna'] -Vars @{ TK = $k; Jobs = $jobs; Stamp = $stamp } -Code {
            foreach ($j in $Jobs) {
                try {
                    [void](Restore-HUBackupItem -TenantKey $TK -Settings $Settings -Typ $j.Typ -File $j.File -Name "$($j.Name) (wiederhergestellt $Stamp)")
                    Write-HULog -Message "$($j.Typ) '$($j.Name)' wiederhergestellt (ohne Zuweisungen)" -Level 'OK' -Tenant $TK
                } catch { Write-HULog -Message "$($j.Typ) '$($j.Name)': $($_.Exception.Message)" -Level 'ERROR' -Tenant $TK }
            }
        })
}

# Gewaehlten (linken) Stand als Muster festhalten: Gesamtstand-Paket in der Muster-Bibliothek (laeuft nicht ab)
function Start-HUBakMuster {
    $c = $script:Controls
    $k = "$($c['cmbBakTenant'].SelectedItem.Tag)"
    $a = $c['cmbBakA'].SelectedItem
    if (-not $k -or -not $a) { Show-HUMessage 'Bitte Tenant und Stand (links) waehlen.' -Icon Info; return }
    $folder = "$($a.Tag)"
    $def = "Gesamtstand $(Get-HUAnaTenantName $k) $(("$($a.Content)" -split ' ')[0])"
    $r = Read-HUNameDescription -Title 'Als Muster festhalten' -Name $def -Hint "Stand $($a.Content) von $(Get-HUAnaTenantName $k) wird als Paket 'Gesamtstand' in der Muster-Bibliothek gespeichert (Reiter Muster): Soll-Stand, laeuft nicht ab, im Tenant-Vergleich als Spalte 'Muster'. Es wird nichts in einen Tenant geschrieben."
    if (-not $r) { return }
    if (@(Get-HUMusterPackages $script:Settings | Where-Object { (ConvertTo-HUMuName $_.Title) -eq (ConvertTo-HUMuName $r.Name) }).Count) { Show-HUMessage "Es gibt schon ein Muster-Paket '$($r.Name)' - bitte einen anderen Namen waehlen." -Icon Warning; return }
    Add-HURtbLine $c['rtbAna'] "Halte Stand $($a.Content) als Muster '$($r.Name)' fest ..." '#90CAF9'
    [void](Start-HUJob -Name 'BakMuster' -Output $c['rtbAna'] -Vars @{ F = $folder; TK = $k; T = $r.Name; N = $r.Description } -Code {
            try { [pscustomobject]@{ __MuMade = (New-HUMusterPackageFromStand -Settings $Settings -Folder $F -TenantKey $TK -Title $T -Note $N -ResolveGroups).Package.Id } }
            catch { [pscustomobject]@{ __MuErr = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__MuMade'] -or $_.PSObject.Properties['__MuErr']) }) | Select-Object -First 1
            if (-not $d) { Show-HUMessage 'Nicht festgehalten (siehe Protokoll).' -Icon Error; return }
            if ($d.PSObject.Properties['__MuErr']) { Show-HUMessage "Nicht festgehalten: $($d.__MuErr)" -Icon Error; return }
            $first = -not @(Get-HUMuSelIds).Count
            if ($first) { Set-HUMuSelIds @($d.__MuMade) }
            Show-HUMessage "Festgehalten als Muster-Paket.$(if ($first) { ' Es ist fuer den Tenant-Vergleich angehakt.' } else { ' Im Reiter Muster anhaken, um es im Tenant-Vergleich zu verwenden.' })" -Icon Info
            try { Update-HUMuList $d.__MuMade } catch { }
        })
}

function Register-HUBakHandlers {
    $c = $script:Controls
    $c['btnAnaModeBak'].Add_Click({ Set-HUAnaMode 'bak' })
    $c['btnBakNow'].Add_Click({ Start-HUBakNow })
    $c['btnBakFolder'].Add_Click({ $p = Get-HUBakRootSafe; if ($p) { Start-Process explorer.exe -ArgumentList "`"$p`"" } })
    $c['cmbBakTenant'].Add_SelectionChanged({ if (-not $script:BakTenantBusy -and $script:Controls['cmbBakTenant'].SelectedItem) { Set-HUStateValue 'bakTenant' "$($script:Controls['cmbBakTenant'].SelectedItem.Tag)"; Update-HUBakSnapshots } })
    $c['btnBakCmp'].Add_Click({ Start-HUBakCompare })
    $c['chkBakChanges'].Add_Checked({ Update-HUBakGrid })
    $c['chkBakChanges'].Add_Unchecked({ Update-HUBakGrid })
    $c['txtBakFilter'].Add_TextChanged({ Update-HUBakGrid })
    $c['cmbBakTyp'].Add_SelectionChanged({ if (-not $script:BakTypBusy) { Update-HUBakGrid } })
    $c['gridBak'].Add_MouseDoubleClick({ Show-HUBakDetail })
    $c['btnBakRestore'].Add_Click({ Start-HUBakRestore })
    $c['btnBakMuster'].Add_Click({ Start-HUBakMuster })
    $c['btnBakTable'].Add_Click({
            $rows = @(Get-HUBakVisibleRows | Select-Object Typ, Name, Aenderung, Wer)
            if (-not $rows.Count) { Show-HUMessage 'Noch keine Eintraege.' -Icon Info; return }
            Show-HUQSTable -Title "Backup - $($script:BakInfo)" -Objects $rows -FilePrefix 'Backup-Verlauf'
        })
    # automatisch einmal taeglich (alle Tenants), kurz nach dem Start
    if ([bool](Get-HUProp $script:Settings.ui 'backupDaily' $true)) {
        $last = $null; try { $last = [datetime](Get-HUStateValue 'bakLast' '') } catch { }
        if (-not $last -or ((Get-Date) - $last).TotalHours -ge 20) {
            Invoke-HUDelayed 30 { Start-HUBakNow -Keys @($script:Settings.tenants | ForEach-Object { "$($_.key)" }) -Auto }
        }
    }
}

function Register-HUAnaHandlers {
    $c = $script:Controls
    Update-HUAnaTenantChecks
    $kind = "$(Get-HUStateValue 'anaKind' 'group')"
    foreach ($it in @($c['cmbAnaKind'].Items)) { if ("$($it.Tag)" -eq $kind) { $c['cmbAnaKind'].SelectedItem = $it } }
    $c['chkAnaAll'].IsChecked = [bool](Get-HUStateValue 'anaAll' $true)
    $c['chkAnaAll'].Add_Checked({ Set-HUStateValue 'anaAll' $true; Update-HUAnaGrid })
    $c['chkAnaAll'].Add_Unchecked({ Set-HUStateValue 'anaAll' $false; Update-HUAnaGrid })
    # Protokoll unten: Hoehe per Ziehgriff (gemerkt)
    try { $h = [double](Get-HUStateValue 'anaLogHeight' 120); if ($h -ge 60 -and $h -le 800) { $c['rtbAna'].Height = $h } } catch { }
    $c['thbAnaLog'].Add_DragDelta({
            param($s, $e)
            $h = $script:Controls['rtbAna'].Height - $e.VerticalChange
            $script:Controls['rtbAna'].Height = [math]::Max(60, [math]::Min(800, $h))
        })
    $c['thbAnaLog'].Add_DragCompleted({ Set-HUStateValue 'anaLogHeight' ([int]$script:Controls['rtbAna'].Height) })
    $c['txtAnaFilter'].Add_TextChanged({ Update-HUAnaGrid })
    $c['cmbAnaType'].Add_SelectionChanged({ if (-not $script:AnaTypeBusy) { Update-HUAnaGrid } })
    Update-HUAnaTypes
    $c['btnAnaModeAsg'].Add_Click({ Set-HUAnaMode 'asg' })
    $c['btnAnaModeCmp'].Add_Click({ Set-HUAnaMode 'cmp' })
    $c['btnAnaModeSec'].Add_Click({ Set-HUAnaMode 'sec' })
    $c['btnAnaRun'].Add_Click({ Start-HUAnaRun })
    $c['txtAnaName'].Add_KeyDown({ param($s, $e) if ("$($e.Key)" -eq 'Return') { $e.Handled = $true; Start-HUAnaRun } })
    $c['cmbAnaKind'].Add_SelectionChanged({ $script:Controls['btnAnaPick'].IsEnabled = ((Get-HUAnaKind) -eq 'group') })
    $c['btnAnaPick'].IsEnabled = ((Get-HUAnaKind) -eq 'group')
    $c['btnAnaPick'].Add_Click({
            $keys = @(Get-HUCheckedTenants $script:Controls['spAnaTenants'])
            if (-not $keys.Count) { Show-HUMessage 'Bitte mindestens einen Tenant anhaken.' -Icon Warning; return }
            $n = Show-HUGroupPicker -TenantKeys $keys -Current $script:Controls['txtAnaName'].Text.Trim() -Title 'Gruppe waehlen'
            if ($n) { $script:Controls['txtAnaName'].Text = $n }
        })
    $c['btnAnaTable'].Add_Click({
            if (-not $script:AnaRows.Count) { Show-HUMessage 'Noch keine Ergebnisse.' -Icon Info; return }
            Show-HUQSTable -Title "Zuweisungen: $($script:AnaLabel)" -Objects @(Get-HUAnaVisibleRows) -FilePrefix 'Zuweisungen'
        })
    Add-HUOutputMenu $c['rtbAna'] { $script:Controls['rtbAna'].Document.Blocks.Clear() }
    Register-HUCmpHandlers
    Register-HUBakHandlers
    Register-HUSecHandlers
    Set-HUAnaMode "$(Get-HUStateValue 'anaMode' 'asg')"
}
