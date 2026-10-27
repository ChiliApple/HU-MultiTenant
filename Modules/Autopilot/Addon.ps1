#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatzmodul Autopilot - Oberflaeche des Reiters (Stufe 1: Uebersicht und Tags; Stufe 2: Hash-Archiv; Stufe 3: Aufnehmen).
.NOTES
    Wird von HU-MultiTenant per Dot-Source geladen, danach Initialize-HUAddonAutopilot.
    Entwicklung: liegt in AddonsDev\Autopilot\ (ohne Signatur). Graph-Zugriffe laufen im Hintergrund (Start-HUJob)
    mit Autopilot.Core.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:APDir = $PSScriptRoot
$script:APCore = Join-Path $PSScriptRoot 'Autopilot.Core.ps1'
. $script:APCore
. (Join-Path $PSScriptRoot 'Autopilot.Archiv.ps1')
# alle Modul-Variablen vorbelegen (das Programm laeuft mit Set-StrictMode)
$script:APRows = @()
$script:APRechteStand = @{}
$script:APLadeTenants = @()
$script:APArchiv = @{}          # Tenant -> Eintraege (entschluesselt, nur im Speicher)
$script:APArchivProps = @('Seriennummer', 'HashDa', 'Quelle', 'Lieferung', 'Eingelesen', 'InAutopilot', 'Geraetename', 'Benutzer', 'GroupTag', 'Modell', 'Eingerichtet', 'Ausgeschieden')
$script:APArchivJobTenant = ''
$script:APSerienCache = @{}      # Tenant -> Seriennummern (Autopilot), fuer die Pruefung beim Einlesen und 'In Autopilot'
$script:APSerienZeit = @{}       # Tenant -> Zeitpunkt, an dem die Seriennummern geholt wurden
$script:APSerienJob = $false     # laeuft gerade ein Abruf der Seriennummern
$script:APSerienLog = $false    # Ergebnis des Abrufs ins Protokoll schreiben
$script:APImport = $null
$script:APAufInfo = @{}          # Tenant -> Tags, Gruppen, Profile, Seriennummern (aus 'Tags & Gruppen laden')
$script:APAufRechte = @{}        # Tenant -> fehlende Rechte fuer das Aufnehmen
$script:APAufGruppe = $null      # Gruppe, die den gewaehlten Tag trifft (sicher)
$script:APAufNeueGruppe = $null  # in dieser Sitzung von der App angelegte Gruppe (Rueckgaengig)
$script:APAufGruppeWeg = $null   # Gruppe, die 'Angelegte Gruppe loeschen' gerade loeschen wuerde
$script:APAufLauf = $null        # letzter Import-Durchgang (Nachverfolgung)
$script:APAufJobTenant = ''
$script:APAufWecker = $false
$script:APTagWartet = $null      # markierte Zeilen, fuer die nach dem Laden der Tag-Dialog aufgeht
$script:APTagAlt = $null         # letzte Tag-Aenderung (Rueckgaengig)
$script:APTagJob = $null
$script:APAusVorgaenge = @{}     # Tenant -> Vorgaenge (Ausscheiden, verschluesselt gespeichert)
$script:APAusRechte = @{}        # Tenant -> fehlende Rechte fuer das Ausscheiden
$script:APAusJob = $null
$script:APAusWecker = $false
$script:APAusStatusTenant = ''
$script:APAusIntuneTenant = ''
$script:APUebergabeDateien = @()
$script:APProps = @('TenantName', 'Status', 'Seriennummer', 'Hersteller', 'Modell', 'GroupTag', 'Profil', 'Registrierung', 'InIntune', 'Geraetename', 'Benutzer', 'EingerichtetAm', 'LetzterKontakt', 'LetzterSync', 'Hinweis')

function Write-APLog([string]$Text, [string]$Color = '#CCCCCC') { Add-HURtbLine $script:Controls['apLog'] $Text $Color }
function Get-APTenantName([string]$Key) { try { return (Get-HUTenantDisplayName $Key) } catch { return $Key } }
# Pulsierender gruener Punkt, solange gelesen wird (wie in Analyse)
function Set-APDot($Dot, [bool]$On) {
    if (-not $Dot) { return }
    if ($On) {
        if ($Dot.Visibility -eq 'Visible') { return }
        $an = New-Object System.Windows.Media.Animation.DoubleAnimation
        $an.From = 1.0; $an.To = 0.2; $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
        $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $Dot.Visibility = 'Visible'
        $Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
    } else {
        $Dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $Dot.Opacity = 1.0; $Dot.Visibility = 'Collapsed'
    }
}
# Filter wie in Analyse: mehrere Woerter, alle muessen vorkommen
function Test-APFilter($Row, [string]$Filter, [string[]]$Props) {
    $f = "$Filter".Trim(); if (-not $f) { return $true }
    $txt = (@($Props | ForEach-Object { "$($Row.$_)" }) -join ' ')
    foreach ($w in ($f -split '\s+')) { if ($w -and $txt -notlike "*$w*") { return $false } }
    return $true
}

# ----------------------------------------------------------------------------------------------
# Tenants
# ----------------------------------------------------------------------------------------------
function Update-APTenantChecks {
    $sp = $script:Controls['apTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'apTenants' @())
    if (-not $saved.Count -and @($script:Settings.tenants).Count) { $saved = @("$(@($script:Settings.tenants)[0].key)") }
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"; $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'; $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.ToolTip = 'Tenant fuer Laden und Anzeige markieren'
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ if (-not $script:TenantToggleBusy) { Save-APTenants } })
        $cb.Add_Unchecked({ if (-not $script:TenantToggleBusy) { Save-APTenants } })
        [void]$sp.Children.Add($cb)
    }
    if (@($script:Settings.tenants).Count -gt 1) { Add-HUTenantAllToggle $sp { Save-APTenants } }
}
function Get-APTenants { return @(Get-HUCheckedTenants $script:Controls['apTenants']) }
function Save-APTenants { Set-HUStateValue 'apTenants' @(Get-APTenants); try { Save-HUUIState } catch { }; Update-APGrid }

# ----------------------------------------------------------------------------------------------
# Uebersicht
# ----------------------------------------------------------------------------------------------
# Spaltenbreiten nach neuem Inhalt neu berechnen (Auto waechst sonst nur und schrumpft nie) - nach dem Zeichnen
function Reset-APGridBreiten([string]$Name) {
    try {
        $g = $script:Controls[$Name]
        [void]$g.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] {
                try { foreach ($col in $g.Columns) { $col.Width = [System.Windows.Controls.DataGridLength]::new(0); $col.Width = [System.Windows.Controls.DataGridLength]::Auto } } catch { }
            }.GetNewClosure())
    } catch { }
}
function Get-APSichtbar {
    $sel = @(Get-APTenants)
    return @($script:APRows | Where-Object { $sel -contains "$($_.Tenant)" })
}
function Update-APGrid {
    $c = $script:Controls
    $all = @(Get-APSichtbar)
    $rows = $all
    if ($c.apChkNurProbleme.IsChecked) { $rows = @($rows | Where-Object { $_.Status -ne 'Bereit' }) }
    if ($c.apChkOhneIntune.IsChecked) { $rows = @($rows | Where-Object { $_.InIntune -ne 'ja' }) }
    $f = "$($c.apTxtFilter.Text)"
    if ($f.Trim()) { $rows = @($rows | Where-Object { Test-APFilter $_ $f $script:APProps }) }
    # Sortierung: Standard zuletzt eingerichtet oben; eine vom Benutzer gewaehlte Spalte bleibt beim Neuladen erhalten
    $sort = @(); foreach ($sd in @($c.apGrid.Items.SortDescriptions)) { $sort += $sd }
    if (-not $sort.Count) { $rows = @($rows | Sort-Object @{ e = { "$($_.EingerichtetAm)" }; Descending = $true }, @{ e = { "$($_.LetzterKontakt)" }; Descending = $true }) }
    $c.apGrid.ItemsSource = $null
    $c.apGrid.ItemsSource = $rows
    if ($sort.Count) {
        foreach ($sd in $sort) {
            [void]$c.apGrid.Items.SortDescriptions.Add($sd)
            foreach ($col in $c.apGrid.Columns) { if ("$($col.SortMemberPath)" -eq "$($sd.PropertyName)") { $col.SortDirection = $sd.Direction } }
        }
    } else { foreach ($col in $c.apGrid.Columns) { $col.SortDirection = $null }; $col0 = @($c.apGrid.Columns | Where-Object { "$($_.SortMemberPath)" -eq 'EingerichtetAm' }); if ($col0.Count) { $col0[0].SortDirection = [System.ComponentModel.ListSortDirection]::Descending } }
    Set-HUGridFit $c.apGrid
    Reset-APGridBreiten 'apGrid'
    if ($all.Count) {
        $teile = @('Bereit', 'Warnung', 'Fehlt', 'Fehler' | ForEach-Object { $s = $_; $n = @($all | Where-Object { $_.Status -eq $s }).Count; if ($n) { "$s $n" } })
        $oi = @($all | Where-Object { $_.InIntune -ne 'ja' }).Count
        $c.apTxtSumme.Text = "$($all.Count) Geraete:  " + ($teile -join '   ') + "   |   ohne Intune $oi" + $(if ($rows.Count -ne $all.Count) { "   |   angezeigt $($rows.Count)" } else { '' })
    } elseif (-not (Test-HUJobRunning 'AP-Laden')) { $c.apTxtSumme.Text = 'Tenants markieren und Laden klicken.' }
    # Tags & Gruppen
    $tags = @(Get-APTagSummen $all)
    foreach ($t in $tags) { $t | Add-Member -NotePropertyName TenantName -NotePropertyValue (Get-APTenantName "$($t.Tenant)") -Force }
    $c.apGridTags.ItemsSource = $null
    $c.apGridTags.ItemsSource = $tags
    Set-HUGridFit $c.apGridTags
    Reset-APGridBreiten 'apGridTags'
}

function Start-APLaden([string[]]$Tenants) {
    $ten = if (@($Tenants).Count) { @($Tenants) } else { @(Get-APTenants) }
    if (-not $ten.Count) { Show-HUMessage 'Bitte mindestens einen Tenant markieren.' -Icon Info; return }
    $namen = @($ten | ForEach-Object { Get-APTenantName $_ }) -join ', '
    Write-APLog "Lade Autopilot-Geraete: $namen ..." '#4FC3F7'
    Set-APDot $script:Controls['apDotLaden'] $true
    $script:Controls['apTxtSumme'].Text = "Lade $namen ..."
    $script:APLadeTenants = $ten
    $ok = (Start-HUJob -Name 'AP-Laden' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenants = $ten } -Code {
            . $APCore
            foreach ($t in $APTenants) {
                try { Get-APUebersicht $t $Settings } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'ERROR' -Tenant $t }
            }
        } -OnDone {
            param($res, $errs)
            $rows = @($res | Where-Object { $_ -and $_.PSObject.Properties['AutopilotId'] })
            foreach ($r in $rows) { $r | Add-Member -NotePropertyName TenantName -NotePropertyValue (Get-APTenantName "$($r.Tenant)") -Force }
            # geladene Tenants ersetzen, andere bleiben gemerkt
            $neu = @($script:APLadeTenants)
            $script:APRows = @($script:APRows | Where-Object { $neu -notcontains "$($_.Tenant)" }) + $rows
            Set-APDot $script:Controls['apDotLaden'] $false
            Update-APGrid
            try { Update-APArchivGrid } catch { }
            try { Update-APAusGrid } catch { }
            $p = @($rows | Where-Object { $_.Status -ne 'Bereit' }).Count
            Write-APLog "Fertig: $($rows.Count) Autopilot-Geraete, $p nicht bereit" $(if ($p) { '#FFB74D' } else { '#81C784' })
        })
    if (-not $ok) { Set-APDot $script:Controls['apDotLaden'] $false }
}

# ----------------------------------------------------------------------------------------------
# Detail-Fenster (Doppelklick): immer alle Werte, groessenveraenderbar mit Anfasser
# ----------------------------------------------------------------------------------------------
function Show-APDetail($Row) {
    if (-not $Row) { return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" Height="520" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources><!--HU:THEME--></Window.Resources>
    <DockPanel Margin="12">
        <TextBlock x:Name="txtHead" DockPanel.Dock="Top" Style="{StaticResource SectionTitle}" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <WrapPanel DockPanel.Dock="Bottom" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="btnCopy" Content="Kopieren" Width="100" Background="#555555" Style="{StaticResource DarkButton}" Margin="0,0,8,0" ToolTip="Alle Werte als Text in die Zwischenablage"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" ToolTip="Fenster schliessen"/>
        </WrapPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" AlternationCount="2" HeadersVisibility="Column">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Feld" Binding="{Binding Feld}" Width="Auto"/>
                <DataGridTextColumn Header="Wert" Binding="{Binding Wert}" Width="Auto" MaxWidth="700"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $dc = $d.C
    try { $w.Owner = $script:Window } catch { }
    $titel = (@("$($Row.Seriennummer)", "$($Row.Geraetename)" | Where-Object { $_ }) -join ' - ') + " ($($Row.TenantName))"
    $w.Title = "Autopilot - $titel"; $dc.txtHead.Text = $titel
    $felder = [ordered]@{
        'Tenant' = $Row.TenantName; 'Status' = $Row.Status; 'Hinweis' = $Row.Hinweis; 'Seriennummer' = $Row.Seriennummer
        'Hersteller' = $Row.Hersteller; 'Modell' = $Row.Modell; 'Group Tag' = $Row.GroupTag; 'Profil' = $Row.Profil
        'Profil (Graph)' = $Row.ProfilRoh; 'Registrierung' = $Row.Registrierung; 'In Intune' = $Row.InIntune
        'Geraetename' = $Row.Geraetename; 'Benutzer (UPN)' = $Row.Benutzer; 'Eingerichtet am (Intune)' = $Row.EingerichtetAm; 'Letzter Kontakt (Autopilot)' = $Row.LetzterKontakt; 'Letzter Sync (Intune)' = $Row.LetzterSync
        'Autopilot-ID' = $Row.AutopilotId; 'Intune-ID' = $Row.IntuneId
    }
    $zeilen = @(foreach ($k in $felder.Keys) { [pscustomobject]@{ Feld = $k; Wert = "$($felder[$k])" } })
    $dc.grid.ItemsSource = $zeilen
    $dc.btnCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText((@($zeilen | ForEach-Object { "$($_.Feld): $($_.Wert)" }) -join "`r`n")) } catch { } })
    $dc.btnClose.Add_Click({ $w.Close() })
    Restore-HUDialogState $w 'APDetail'
    $w.Add_Closing({ Save-HUDialogState $w 'APDetail' })
    [void]$w.ShowDialog()
}


# ----------------------------------------------------------------------------------------------
# Hash-Archiv (Stufe 2)
# ----------------------------------------------------------------------------------------------
# Ein-Tenant-Auswahl oben (Hash-Archiv, Aufnehmen, Ausscheiden gemeinsam)
function Get-APEinTenant { $i = $script:Controls['apCmbTenant'].SelectedItem; if ($i) { return "$($i.Tag)" } return '' }
function Get-APArchivTenant { return (Get-APEinTenant) }
function Update-APArchivTenants {
    $cmb = $script:Controls['apCmbTenant']; $cmb.Items.Clear()
    foreach ($t in @($script:Settings.tenants)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = "$($t.displayName)"; $it.Tag = "$($t.key)"
        [void]$cmb.Items.Add($it)
    }
    $first = "$(Get-HUStateValue 'apTenant' '')"
    if (-not $first) { $first = "$(@(Get-APTenants) | Select-Object -First 1)" }
    $idx = 0; for ($i = 0; $i -lt $cmb.Items.Count; $i++) { if ("$($cmb.Items[$i].Tag)" -eq $first) { $idx = $i; break } }
    if ($cmb.Items.Count) { $cmb.SelectedIndex = $idx }
}
# Archiv eines Tenants (einmal entschluesseln, dann im Speicher)
function Get-APArchivDaten([string]$Tenant) {
    if (-not $Tenant) { return @() }
    if (-not $script:APArchiv.ContainsKey($Tenant)) {
        try { $script:APArchiv[$Tenant] = @(Read-APArchiv $Tenant) }
        catch { Write-APLog "Hash-Archiv $(Get-APTenantName $Tenant) nicht lesbar: $($_.Exception.Message)" '#F44336'; $script:APArchiv[$Tenant] = @(); throw }
    }
    return @($script:APArchiv[$Tenant])
}
function Save-APArchivDaten([string]$Tenant, [object[]]$Liste) {
    Save-APArchiv $Tenant @($Liste)
    $script:APArchiv[$Tenant] = @($Liste)
}
function Update-APArchivGrid {
    $c = $script:Controls
    $t = Get-APArchivTenant
    if (-not $t) { return }
    $daten = @(); try { $daten = @(Get-APArchivDaten $t) } catch { }
    $ap = @($script:APRows | Where-Object { "$($_.Tenant)" -eq $t })
    $set = $null
    if (-not $ap.Count) {
        $set = Get-APSerienSet $t
        # Seriennummern fehlen oder sind aelter als 10 Minuten: im Hintergrund holen, danach baut sich die Tabelle neu auf
        $zeit = if ($script:APSerienZeit.ContainsKey($t)) { $script:APSerienZeit[$t] } else { [datetime]::MinValue }
        if ($null -eq $set -or ((Get-Date) - $zeit).TotalMinutes -gt 10) { Start-APSerienHolen @($t) }
    }
    $rows = @(Get-APArchivZeilen $daten $ap -MitFehlenden:([bool]$c.apChkArchivFehlt.IsChecked) -SerienSet $set)
    $nichtAp = @($rows | Where-Object { $_.HashDa -eq 'ja' -and $_.InAutopilot -eq 'nein' }).Count
    if ([bool]$c.apChkArchivNicht.IsChecked) { $rows = @($rows | Where-Object { $_.InAutopilot -eq 'nein' }) }
    $f = "$($c.apTxtArchivFilter.Text)"
    if ($f.Trim()) { $rows = @($rows | Where-Object { Test-APFilter $_ $f $script:APArchivProps }) }
    # Standard: neueste oben (zuletzt eingelesen, sonst zuletzt in Intune eingerichtet); eine gewaehlte Spalte bleibt erhalten
    $sort = @(); foreach ($sd in @($c.apGridArchiv.Items.SortDescriptions)) { $sort += $sd }
    if (-not $sort.Count) { $rows = @($rows | Sort-Object @{ e = { if ("$($_.Eingelesen)") { "$($_.Eingelesen)" } else { "$($_.Eingerichtet)" } }; Descending = $true }, @{ e = { "$($_.Eingerichtet)" }; Descending = $true }, Seriennummer) }
    $c.apGridArchiv.ItemsSource = $null
    $c.apGridArchiv.ItemsSource = $rows
    if ($sort.Count) {
        foreach ($sd in $sort) {
            [void]$c.apGridArchiv.Items.SortDescriptions.Add($sd)
            foreach ($col in $c.apGridArchiv.Columns) { if ("$($col.SortMemberPath)" -eq "$($sd.PropertyName)") { $col.SortDirection = $sd.Direction } }
        }
    }
    Set-HUGridFit $c.apGridArchiv
    Reset-APGridBreiten 'apGridArchiv'
    $geraete = @($daten | Group-Object { ConvertTo-APSerialKey $_.Seriennummer }).Count
    $txt = "$(Get-APTenantName $t): $geraete Geraet(e) mit Hash im Archiv ($(@($daten).Count) Hash(es))"
    if ($ap.Count) {
        $mit = @{}; foreach ($e in $daten) { $mit[(ConvertTo-APSerialKey $e.Seriennummer)] = 1 }
        $ohne = @($ap | Where-Object { -not $mit.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) }).Count
        $txt += "   |   Autopilot: $($ap.Count) Geraete, davon $ohne ohne Hash"
    } elseif ($null -ne $set) { $txt += "   |   Autopilot: $($set.Count) Geraete (Geraete ohne Hash: Uebersicht laden)" }
    elseif ($script:APSerienJob) { $txt += "   |   Abgleich mit Autopilot laeuft ..." }
    else { $txt += "   |   Abgleich mit Autopilot nicht moeglich (siehe Protokoll)" }
    if ($ap.Count -or $null -ne $set) { $txt += "   |   $nichtAp mit Hash nicht (mehr) in Autopilot" }
    $c.apTxtArchivSumme.Text = $txt + '   |   verschluesselt nur fuer diesen Windows-Benutzer'
}

# Dateien/Ordner einlesen
function Import-APArchivDateien([string[]]$Pfade) {
    $t = Get-APArchivTenant
    if (-not $t) { Show-HUMessage 'Bitte zuerst einen Tenant waehlen.' -Icon Info; return }
    $dateien = New-Object System.Collections.ArrayList
    foreach ($p in @($Pfade)) {
        if (Test-Path -LiteralPath $p -PathType Container) { foreach ($x in @(Get-ChildItem -LiteralPath $p -Recurse -File -Include *.csv, *.xlsx -ErrorAction SilentlyContinue)) { [void]$dateien.Add($x.FullName) } }
        elseif (Test-Path -LiteralPath $p) { [void]$dateien.Add($p) }
    }
    if (-not $dateien.Count) { Show-HUMessage 'Keine CSV- oder Excel-Dateien gefunden.' -Icon Info; return }
    try { $alt = @(Get-APArchivDaten $t) } catch { Show-HUMessage "Hash-Archiv nicht lesbar - nichts eingelesen.`n`n$($_.Exception.Message)" -Icon Error; return }
    $neu = @(); $fehler = @()
    foreach ($d in $dateien) {
        try { $r = Read-APHashDatei $d 'Lieferung/Datei'; $neu += @($r.Eintraege); $fehler += @($r.Fehler); Write-APLog "$([IO.Path]::GetFileName($d)): $(@($r.Eintraege).Count) Hash(es) ($($r.Format))$(if (@($r.Fehler).Count) { ", $(@($r.Fehler).Count) Zeile(n) uebersprungen" })" '#CCCCCC' }
        catch { $fehler += "$([IO.Path]::GetFileName($d)): $($_.Exception.Message)" }
    }
    # Pruefen gegen die Autopilot-Seriennummern ALLER Tenants (Konzept C2). Fehlen welche, kurz im Hintergrund holen.
    $script:APImport = [pscustomobject]@{ Tenant = $t; Neu = @($neu); Fehler = @($fehler) }
    $fehlt = @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ -and -not (Get-APSerienSet $_) })
    if (-not $fehlt.Count) { Complete-APArchivImport; return }
    Write-APLog "Pruefe Seriennummern gegen Autopilot aller Tenants ..." '#AAAAAA'
    if (-not (Start-APSerienHolen $fehlt -Log)) { Complete-APArchivImport }
}
# Autopilot-Seriennummern im Hintergrund holen (nur lesen). Danach: offenen Import abschliessen bzw. Archiv-Tabelle neu aufbauen.
function Start-APSerienHolen([string[]]$Keys, [switch]$Log) {
    if ($script:APSerienJob) { return $true }   # laeuft schon - das Ergebnis kommt ohnehin
    $script:APSerienJob = $true
    $script:APSerienLog = [bool]$Log
    # vorab Zeit setzen, damit ein Fehler nicht zu Dauerversuchen fuehrt
    foreach ($k in $Keys) { $script:APSerienZeit[$k] = Get-Date }
    Set-APDot $script:Controls['apDotArchiv'] $true
    $ok = Start-HUJob -Name 'AP-Serien' -Quiet -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APKeys = [string[]]$Keys } -Code {
        . $APCore
        foreach ($k in $APKeys) { try { Get-APSeriennummern $k $Settings } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'WARN' -Tenant $k } }
    } -OnDone {
        param($res, $errs)
        $script:APSerienJob = $false
        Set-APDot $script:Controls['apDotArchiv'] $false
        foreach ($r in @($res | Where-Object { $_ -and $_.PSObject.Properties['APSerien'] })) {
            $h = @{}; foreach ($x in @($r.Serien)) { $h[(ConvertTo-APSerialKey $x)] = 1 }
            $script:APSerienCache["$($r.Tenant)"] = $h
            $script:APSerienZeit["$($r.Tenant)"] = Get-Date
        }
        if ($script:APSerienLog) {
            $info = @($script:Settings.tenants | ForEach-Object { $k = "$($_.key)"; $set = Get-APSerienSet $k; "$(Get-APTenantName $k) $(if ($set) { $set.Count } else { '-' })" }) -join ', '
            Write-APLog "Autopilot-Seriennummern: $info" '#AAAAAA'
        }
        if ($script:APImport) { Complete-APArchivImport } else { Update-APArchivGrid }
    }
    if (-not $ok) { $script:APSerienJob = $false; Set-APDot $script:Controls['apDotArchiv'] $false }
    return [bool]$ok
}
# Seriennummern eines Tenants: aus der geladenen Uebersicht, sonst aus dem Zwischenspeicher ($null = unbekannt)
function Get-APSerienSet([string]$Tenant) {
    $rows = @($script:APRows | Where-Object { "$($_.Tenant)" -eq $Tenant })
    if ($rows.Count) { $h = @{}; foreach ($r in $rows) { $h[(ConvertTo-APSerialKey $r.Seriennummer)] = 1 }; return $h }
    if ($script:APSerienCache.ContainsKey($Tenant)) { return $script:APSerienCache[$Tenant] }
    return $null
}
function Complete-APArchivImport {
    $imp = $script:APImport; if (-not $imp) { return }
    $script:APImport = $null
    $t = $imp.Tenant; $neu = @($imp.Neu); $fehler = @($imp.Fehler)
    try { $alt = @(Get-APArchivDaten $t) } catch { Show-HUMessage "Hash-Archiv nicht lesbar - nichts eingelesen.`n`n$($_.Exception.Message)" -Icon Error; return }
    $hier = Get-APSerienSet $t; if (-not $hier) { $hier = @{} }
    $woanders = @{}
    foreach ($tk in @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ -and $_ -ne $t })) {
        $set = Get-APSerienSet $tk; if (-not $set) { continue }
        foreach ($k in $set.Keys) { if (-not $hier.ContainsKey($k) -and -not $woanders.ContainsKey($k)) { $woanders[$k] = $tk } }
    }
    $inHier = @($neu | Where-Object { $hier.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) }).Count
    $nFremd = @($neu | Where-Object { $woanders.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) }).Count
    Write-APLog "Pruefung: $(@($neu).Count) aus Datei - $inHier in $(Get-APTenantName $t), $nFremd in anderem Tenant, $(@($neu).Count - $inHier - $nFremd) in keinem Autopilot" '#AAAAAA'
    # Geraete in KEINEM Autopilot gehoeren wohl zum selben Tenant wie der Rest ihrer Datei: liegt die Mehrheit der
    # erkannten Geraete einer Datei in einem anderen Tenant, werden sie mit dorthin vorgeschlagen.
    $ohneZiel = @{}
    foreach ($g in @($neu | Group-Object Datei)) {
        $erk = @($g.Group | ForEach-Object { $k = ConvertTo-APSerialKey $_.Seriennummer; if ($hier.ContainsKey($k)) { $t } elseif ($woanders.ContainsKey($k)) { $woanders[$k] } })
        if (-not $erk.Count) { continue }
        $top = @($erk | Group-Object | Sort-Object Count -Descending)[0]
        if ("$($top.Name)" -eq $t -or $top.Count * 2 -le $erk.Count) { continue }
        foreach ($e in $g.Group) { $k = ConvertTo-APSerialKey $e.Seriennummer; if (-not $hier.ContainsKey($k) -and -not $woanders.ContainsKey($k)) { $woanders[$k] = "$($top.Name)"; $ohneZiel[$k] = 1 } }
    }
    $fremd = @($neu | Where-Object { $woanders.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) })
    if ($fremd.Count) {
        $grp = @($fremd | Group-Object { $woanders[(ConvertTo-APSerialKey $_.Seriennummer)] })
        $liste = (@($grp | ForEach-Object { $oz = @($_.Group | Where-Object { $ohneZiel.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) }).Count; "  $(Get-APTenantName $_.Name): $($_.Count) Geraet(e)$(if ($oz) { " (davon $oz in keinem Autopilot, aber aus derselben Datei)" })" }) -join "`n")
        $frage = "$($fremd.Count) Geraet(e) aus der Datei gehoeren laut Autopilot nicht zu $(Get-APTenantName $t), sondern zu:`n`n$liste`n`nJa = dort ins Archiv ablegen (empfohlen)`nNein = trotzdem hier in $(Get-APTenantName $t) ablegen"
        if (Confirm-HU $frage 'Autopilot - Hash-Archiv') {
            foreach ($g in $grp) {
                try {
                    $mz = Merge-APArchiv @(Get-APArchivDaten $g.Name) @($g.Group)
                    if ($mz.Neu) { Save-APArchivDaten $g.Name $mz.Liste }
                    Write-APLog "Hash-Archiv $(Get-APTenantName $g.Name): $($mz.Neu) neu, $($mz.Bekannt) schon vorhanden (aus Datei fuer $(Get-APTenantName $t))" '#81C784'
                } catch { Write-APLog "Hash-Archiv $(Get-APTenantName $g.Name): $($_.Exception.Message)" '#F44336' }
            }
            $neu = @($neu | Where-Object { -not $woanders.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) })
        }
    }
    $m = Merge-APArchiv $alt $neu
    if ($m.Neu) {
        try { Save-APArchivDaten $t $m.Liste } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error; return }
    }
    foreach ($f in $fehler) { Write-APLog $f '#FFB74D' }
    Write-APLog "Hash-Archiv $(Get-APTenantName $t): $($m.Neu) neu, $($m.Bekannt) schon vorhanden$(if ($fehler.Count) { ", $($fehler.Count) Hinweis(e)" })" $(if ($fehler.Count) { '#FFB74D' } else { '#81C784' })
    Update-APArchivGrid
}
function Select-APArchivDateien {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Hash-Dateien (*.csv;*.xlsx)|*.csv;*.xlsx|Alle Dateien (*.*)|*.*'
    $dlg.Multiselect = $true
    $dlg.Title = 'Dateien mit Hardware-Hash waehlen'
    if ($dlg.ShowDialog()) { Import-APArchivDateien @($dlg.FileNames) }
}

# Ergebnisse der Wartung abholen (nur lesen) und uebernehmen
function Start-APArchivAbholen {
    $t = Get-APArchivTenant
    if (-not $t) { Show-HUMessage 'Bitte zuerst einen Tenant waehlen.' -Icon Info; return }
    $script:APArchivJobTenant = $t
    Set-APDot $script:Controls['apDotArchiv'] $true
    Write-APLog "Hole Ergebnisse der Wartung $($script:APHashPaketName): $(Get-APTenantName $t) ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-Archiv' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t } -Code {
        . $APCore
        try { Get-APHashAusgaben $APTenant $Settings } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotArchiv'] $false
        $t = $script:APArchivJobTenant
        $r = @($res | Where-Object { $_ -and $_.PSObject.Properties['APHash'] })
        $gut = @($r | Where-Object { -not $_.Fehler -and $_.Hash })
        foreach ($x in @($r | Where-Object { $_.Fehler })) { Write-APLog "$($x.Geraet) ($($x.Seriennummer)): $($x.Fehler)" '#FFB74D' }
        if (-not $gut.Count) { Update-APArchivGrid; return }
        try { $alt = @(Get-APArchivDaten $t) } catch { Show-HUMessage 'Hash-Archiv nicht lesbar - nichts uebernommen.' -Icon Error; return }
        $neu = @($gut | ForEach-Object { New-APArchivEintrag -Seriennummer $_.Seriennummer -Hash $_.Hash -Quelle 'Wartung' -Datei "$($_.Geraet)" -Lieferung 'Wartung' -Eingelesen $_.Gelesen })
        $m = Merge-APArchiv $alt $neu
        if ($m.Neu) { try { Save-APArchivDaten $t $m.Liste } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error; return } }
        Write-APLog "Hash-Archiv $(Get-APTenantName $t): $($m.Neu) neu aus der Wartung, $($m.Bekannt) schon vorhanden" '#81C784'
        Update-APArchivGrid
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotArchiv'] $false }
}

# Bestaetigung mit eingetipptem Tenant-Namen (bei mehr als 5 Geraeten zusaetzlich die Anzahl)
function Confirm-APTippen([string]$Text, [string]$TenantName, [int]$Anzahl) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="NoResize" Title="Autopilot - Bestaetigen">
    <Window.Resources><!--HU:THEME--></Window.Resources>
    <StackPanel Margin="14">
        <TextBlock x:Name="txt" Foreground="#DDDDDD" TextWrapping="Wrap" FontSize="13" Margin="0,0,0,10"/>
        <TextBlock x:Name="lblT" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <TextBox x:Name="tbT" Style="{StaticResource DarkTextBox}" Margin="0,0,0,8" ToolTip="Tenant-Namen genau so eintippen, wie er angezeigt wird"/>
        <TextBlock x:Name="lblN" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <TextBox x:Name="tbN" Style="{StaticResource DarkTextBox}" Margin="0,0,0,10" ToolTip="Anzahl der Geraete eintippen"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOk" Content="Ausfuehren" Width="120" Background="#B85C00" Style="{StaticResource DarkButton}" Margin="0,0,8,0" IsEnabled="False" ToolTip="Erst aktiv, wenn die Eingaben stimmen"/>
            <Button x:Name="btnNo" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" ToolTip="Nichts ausfuehren"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $dc = $d.C
    try { $w.Owner = $script:Window } catch { }
    $dc.txt.Text = $Text
    $dc.lblT.Text = "Zur Bestaetigung Tenant-Namen eintippen: $TenantName"
    $mitN = ($Anzahl -gt 5)
    if ($mitN) { $dc.lblN.Text = "Anzahl der Geraete eintippen: $Anzahl" } else { $dc.lblN.Visibility = 'Collapsed'; $dc.tbN.Visibility = 'Collapsed' }
    $st = @{ Ok = $false }
    $pruef = { $dc.btnOk.IsEnabled = ("$($dc.tbT.Text)".Trim() -ceq $TenantName -and (-not $mitN -or "$($dc.tbN.Text)".Trim() -eq "$Anzahl")) }
    $dc.tbT.Add_TextChanged($pruef); $dc.tbN.Add_TextChanged($pruef)
    $dc.btnOk.Add_Click({ $st.Ok = $true; $w.Close() })
    $dc.btnNo.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
    return [bool]$st.Ok
}

# Wartung jetzt ausfuehren: markierte Zeilen, sonst alle Autopilot-Geraete ohne Hash (nur mit Intune-Eintrag)
function Start-APArchivWartung {
    $t = Get-APArchivTenant
    if (-not $t) { Show-HUMessage 'Bitte zuerst einen Tenant waehlen.' -Icon Info; return }
    if (-not @($script:APRows | Where-Object { "$($_.Tenant)" -eq $t }).Count) { Show-HUMessage "Bitte zuerst oben 'Laden' klicken (liest die Intune-Geraete dieses Tenants)." -Icon Info; return }
    $sel = @($script:Controls['apGridArchiv'].SelectedItems | Where-Object { $_ })
    $quelle = if ($sel.Count) { $sel } else { @($script:Controls['apGridArchiv'].ItemsSource | Where-Object { $_ -and $_.HashDa -eq 'nein' }) }
    $ziel = @($quelle | Where-Object { "$($_.IntuneId)" })
    $ohne = @($quelle).Count - $ziel.Count
    if (-not $ziel.Count) { Show-HUMessage "Keine passenden Geraete mit Intune-Eintrag$(if ($ohne) { " ($ohne ohne Intune - dort laeuft keine Wartung)" })." -Icon Info; return }
    $tn = Get-APTenantName $t
    $text = "Wartung $($script:APHashPaketName) jetzt auf $($ziel.Count) Geraet(en) in $tn ausfuehren$(if (-not $sel.Count) { ' (alle Autopilot-Geraete ohne Hash)' }).`n`nDas Geraet liest seinen Hardware-Hash einmal, merkt ihn unter ProgramData und gibt ihn an Intune zurueck. Sonst wird nichts geaendert. Fehlt das Paket, wird es angelegt (ohne Zuweisung).$(if ($ohne) { "`n`n$ohne markierte(s) Geraet(e) ohne Intune-Eintrag werden uebersprungen." })`n`nErgebnis nach einigen Minuten mit 'Hashes abholen'."
    if (-not (Confirm-APTippen $text $tn $ziel.Count)) { return }
    $ids = [string[]]@($ziel | ForEach-Object { "$($_.IntuneId)" })
    Set-APDot $script:Controls['apDotArchiv'] $true
    Write-APLog "Starte Wartung auf $($ids.Count) Geraet(en) in $tn ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-Wartung' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APIds = $ids } -Code {
        . $APCore
        try { Start-APHashWartung $APTenant $Settings $APIds } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotArchiv'] $false
        $r = @($res | Where-Object { $_ -and $_.PSObject.Properties['APStart'] })
        $f = @($r | Where-Object { -not $_.Ok }).Count
        Write-APLog "Wartung angestossen: $(@($r).Count - $f) ok$(if ($f) { ", $f Fehler" }) - in einigen Minuten 'Hashes abholen'" $(if ($f) { '#FFB74D' } else { '#81C784' })
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotArchiv'] $false }
}

# Dateiname: ein Geraet -> Autopilot-Hash_<SN>_<Datum>.csv, mehrere -> Autopilot-Hash_<Tenant>_<N>-Geraete_<Datum>.csv
function Get-APHashDateiname([string[]]$Seriennummern, [string]$Tenant = '', [datetime]$Jetzt = (Get-Date)) {
    $safe = { param([string]$v) (("$v".Trim() -replace '[^\p{L}\p{Nd}._-]+', '_').Trim('_', '.')) }
    $sn = @($Seriennummern | Where-Object { "$_".Trim() } | ForEach-Object { & $safe $_ })
    $tn = & $safe $Tenant
    $d = $Jetzt.ToString('yyyyMMdd')
    if ($sn.Count -eq 1) { return "Autopilot-Hash_$($sn[0])_$d.csv" }
    $teile = @('Autopilot-Hash') + @($(if ($tn) { $tn })) + @($(if ($sn.Count) { "$($sn.Count)-Geraete" })) + @($d)
    return "$(@($teile | Where-Object { $_ }) -join '_').csv"
}

# Export im Microsoft-Format (markierte Geraete mit Hash)
function Export-APArchiv {
    $t = Get-APArchivTenant; if (-not $t) { return }
    $sel = @($script:Controls['apGridArchiv'].SelectedItems | Where-Object { $_ -and $_.HashDa -eq 'ja' })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Geraete markieren (nur solche mit Hash).' -Icon Info; return }
    if (-not (Confirm-HU "$($sel.Count) Hash(es) als CSV speichern?`n`nDie Datei ist NICHT verschluesselt. Der Hardware-Hash gehoert dem Eigentuemer des Geraets - nur bewusst weitergeben (Haendler, neue Schule) und danach loeschen." 'Autopilot' -Warning)) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'; $tName = "$(@($script:Settings.tenants | Where-Object { "$($_.key)" -eq $t } | ForEach-Object { $_.displayName })[0])"; if (-not $tName) { $tName = $t }
    $dlg.FileName = (Get-APHashDateiname @($sel | ForEach-Object { "$($_.Seriennummer)" }) $tName)
    if (-not $dlg.ShowDialog()) { return }
    $daten = @(Get-APArchivDaten $t)
    $zeilen = @($sel | ForEach-Object { $e = Get-APNeuesterHash $daten $_.Seriennummer; if ($e) { [pscustomobject]@{ 'Device Serial Number' = "$($e.Seriennummer)"; 'Windows Product ID' = "$($e.ProductId)"; 'Hardware Hash' = "$($e.Hash)" } } })
    $zeilen | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
    Write-APLog "$($zeilen.Count) Hash(es) exportiert: $($dlg.FileName) (unverschluesselt)" '#FFB74D'
}
function Set-APArchivAusgeschieden([switch]$Aufheben) {
    $t = Get-APArchivTenant; if (-not $t) { return }
    $sel = @($script:Controls['apGridArchiv'].SelectedItems | Where-Object { $_ -and $_.HashDa -eq 'ja' })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Geraete markieren (nur solche mit Hash).' -Icon Info; return }
    if ($Aufheben) {
        $sel = @($sel | Where-Object { "$($_.Ausgeschieden)" })
        if (-not $sel.Count) { Show-HUMessage 'Keines der markierten Geraete ist als ausgeschieden gekennzeichnet.' -Icon Info; return }
    } else {
        $inAp = @($sel | Where-Object { $_.InAutopilot -eq 'ja' }).Count
        $frage = "$($sel.Count) Geraet(e) in $(Get-APTenantName $t) als ausgeschieden kennzeichnen?`n`nDer Hash bleibt im Archiv. Beim Aufnehmen werden die Geraete nicht mehr angeboten." + $(if ($inAp) { "`n`nACHTUNG: $inAp davon stehen noch in Autopilot - die Kennzeichnung entfernt sie dort NICHT (das macht spaeter der Reiter Ausscheiden)." } else { '' })
        if (-not (Confirm-HU $frage 'Autopilot - ausgeschieden')) { return }
    }
    $datum = if ($Aufheben) { '' } else { (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $liste = @(Set-APAusgeschieden @(Get-APArchivDaten $t) ([string[]]@($sel | ForEach-Object { $_.Seriennummer })) $datum)
    try { Save-APArchivDaten $t $liste } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error; return }
    Write-APLog "$($sel.Count) Geraet(e) $(if ($Aufheben) { 'nicht mehr als ausgeschieden gekennzeichnet' } else { 'als ausgeschieden gekennzeichnet' })" '#AAAAAA'
    Update-APArchivGrid
}
function Remove-APArchivEintraege {
    $t = Get-APArchivTenant; if (-not $t) { return }
    $sel = @($script:Controls['apGridArchiv'].SelectedItems | Where-Object { $_ -and $_.HashDa -eq 'ja' })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Geraete markieren (nur solche mit Hash).' -Icon Info; return }
    if (-not (Confirm-HU "$($sel.Count) Geraet(e) mit allen Hashes aus dem Archiv loeschen?`n`nDas laesst sich nicht rueckgaengig machen (ausser ueber die App-Sicherung)." 'Autopilot' -Warning)) { return }
    $weg = @{}; foreach ($s in $sel) { $weg[(ConvertTo-APSerialKey $s.Seriennummer)] = 1 }
    $liste = @(Get-APArchivDaten $t | Where-Object { -not $weg.ContainsKey((ConvertTo-APSerialKey $_.Seriennummer)) })
    try { Save-APArchivDaten $t $liste } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error; return }
    Write-APLog "$($sel.Count) Geraet(e) aus dem Hash-Archiv entfernt" '#AAAAAA'
    Update-APArchivGrid
}

# ----------------------------------------------------------------------------------------------
# Aufnehmen (Stufe 3): Geraete aus dem Hash-Archiv -> Tag -> Gruppe -> Import -> Sync -> Nachverfolgung
# ----------------------------------------------------------------------------------------------
function Get-APAufTenant { return (Get-APEinTenant) }
function Get-APAufTag { return "$($script:Controls['apTxtAufTagEingabe'].Text)".Trim() }
function Format-APDauer($Von, $Bis) {
    if (-not $Von -or -not $Bis) { return '' }
    $d = $Bis - $Von
    if ($d.TotalMinutes -lt 1) { return '< 1 Min' }
    if ($d.TotalHours -lt 1) { return "$([int][Math]::Floor($d.TotalMinutes)) Min" }
    return "$([int][Math]::Floor($d.TotalHours)) Std $($d.Minutes) Min"
}
function Update-APAufGrid {
    $c = $script:Controls
    $t = Get-APAufTenant; if (-not $t) { return }
    $daten = @(); try { $daten = @(Get-APArchivDaten $t) } catch { }
    $info = if ($script:APAufInfo.ContainsKey($t)) { $script:APAufInfo[$t] } else { $null }
    $hier = if ($info) { $info.Serien } else { Get-APSerienSet $t }
    $andere = @{}
    foreach ($tk in @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ -and $_ -ne $t })) {
        $set = Get-APSerienSet $tk; if ($set) { foreach ($k in $set.Keys) { if (-not $andere.ContainsKey($k)) { $andere[$k] = $tk } } }
    }
    $lauf = if ($script:APAufLauf -and $script:APAufLauf.Tenant -eq $t) { $script:APAufLauf } else { $null }
    $rows = New-Object System.Collections.ArrayList
    foreach ($g in @($daten | Group-Object { ConvertTo-APSerialKey $_.Seriennummer })) {
        $e = @($g.Group | Sort-Object Eingelesen -Descending)[0]
        $k = "$($g.Name)"
        $st = 'neu'; $amp = ''; $tagJ = ''; $hin = ''
        $aus = Get-APAusgeschieden $g.Group
        if ($aus) { $st = "ausgeschieden $($aus.Substring(0, [Math]::Min(10, $aus.Length)))"; $amp = 'grau'; $hin = 'im Hash-Archiv als ausgeschieden gekennzeichnet' }
        elseif ($hier -and $hier.ContainsKey($k)) { $st = 'schon registriert'; $amp = 'grau'; if ($info) { $tagJ = "$($hier[$k])" } }
        elseif ($andere.ContainsKey($k)) { $st = "in Autopilot von $(Get-APTenantName $andere[$k])"; $amp = 'fehler'; $hin = 'wird beim Import abgelehnt - zuerst dort entfernen' }
        $imp = ''; $grp = ''; $prof = ''; $dg = ''; $dp = ''
        $x = if ($lauf -and $lauf.Stand.ContainsKey($k)) { $lauf.Stand[$k] } else { $null }
        if ($x) {
            $imp = $x.Import; $hin = $x.Fehler
            $grp = $(if ($null -eq $x.InGruppe) { '' } elseif ($x.InGruppe) { 'ja' } else { 'nein' })
            $prof = $x.Profil
            $dg = Format-APDauer $lauf.Start $x.ZeitGruppe
            $dp = Format-APDauer $lauf.Start $x.ZeitProfil
            if ($x.Import -eq 'Fehler') { $amp = 'fehler' }
            elseif ("$($x.ProfilRoh)" -like 'assigned*') { $amp = 'gut'; $st = 'bereit fuer die Ausgabe'; if ($x.TagJetzt) { $tagJ = $x.TagJetzt } }
            elseif ($x.Import -eq 'ok') { $amp = 'warn'; $st = $(if ($lauf.PSObject.Properties['Art'] -and $lauf.Art -eq 'Tag') { 'Tag geaendert' } else { 'importiert' }); if ($x.TagJetzt) { $tagJ = $x.TagJetzt } }
        }
        if (-not $x -and ($st -eq 'schon registriert' -or $aus) -and -not [bool]$c.apChkAufAlle.IsChecked) { continue }
        [void]$rows.Add([pscustomobject]@{
                Seriennummer = "$($e.Seriennummer)"; Status = $st; TagJetzt = $tagJ; TagDatei = "$($e.GroupTag)"; Lieferung = "$($e.Lieferung)"; Eingelesen = "$($e.Eingelesen)"
                Import = $imp; InGruppe = $grp; Profil = $prof; DauerGruppe = $dg; DauerProfil = $dp; Hinweis = $hin; Ampel = $amp; Neu = ($st -eq 'neu')
            })
    }
    $r = @($rows.ToArray())
    $f = "$($c.apTxtAufFilter.Text)"
    if ($f.Trim()) { $r = @($r | Where-Object { Test-APFilter $_ $f @('Seriennummer', 'Status', 'TagJetzt', 'TagDatei', 'Lieferung', 'Import', 'Profil', 'Hinweis') }) }
    $sort = @(); foreach ($sd in @($c.apGridAuf.Items.SortDescriptions)) { $sort += $sd }
    # Standard: laufender Durchgang oben, dann neueste Lieferung
    if (-not $sort.Count) { $r = @($r | Sort-Object @{ e = { if ($_.Import) { 0 } else { 1 } } }, @{ e = { "$($_.Eingelesen)" }; Descending = $true }, Seriennummer) }
    $c.apGridAuf.ItemsSource = $null
    $c.apGridAuf.ItemsSource = $r
    foreach ($sd in $sort) { [void]$c.apGridAuf.Items.SortDescriptions.Add($sd); foreach ($col in $c.apGridAuf.Columns) { if ("$($col.SortMemberPath)" -eq "$($sd.PropertyName)") { $col.SortDirection = $sd.Direction } } }
    Set-HUGridFit $c.apGridAuf
    Reset-APGridBreiten 'apGridAuf'
    $nNeu = @($r | Where-Object { $_.Neu }).Count
    $txt = "$(@($daten | Group-Object { ConvertTo-APSerialKey $_.Seriennummer }).Count) Geraet(e) im Archiv, $nNeu neu"
    if (-not $info) { $txt += " - zuerst oben 'Laden' klicken" }
    if ($lauf) {
        $n = $lauf.Stand.Count
        $ok = @($lauf.Stand.Values | Where-Object { $_.Import -eq 'ok' }).Count
        $bereit = @($lauf.Stand.Values | Where-Object { "$($_.ProfilRoh)" -like 'assigned*' }).Count
        $txt = "Durchgang $($lauf.Start.ToString('HH:mm')): $n Geraet(e), $ok importiert, $bereit mit Profil   |   " + $txt
    }
    $c.apTxtAufSumme.Text = $txt
}
# Tag gewaehlt/eingetippt: pruefen, passende Gruppe und Profil anzeigen
function Update-APAufTag {
    $c = $script:Controls
    $t = Get-APAufTenant
    $tag = Get-APAufTag
    $info = if ($t -and $script:APAufInfo.ContainsKey($t)) { $script:APAufInfo[$t] } else { $null }
    $script:APAufGruppe = $null
    $c.apTxtAufGruppeName.Visibility = 'Collapsed'; $c.apBtnAufGruppeNeu.Visibility = 'Collapsed'
    $c.apBtnAufGruppeWeg.Visibility = 'Collapsed'
    if (-not $info) { $c.apTxtAufTag.Text = "Zuerst oben 'Laden' klicken."; $c.apTxtAufGruppe.Text = '-'; $c.apTxtAufProfil.Text = '-'; return }
    if (-not $tag) { $c.apTxtAufTag.Text = 'Tag waehlen oder eintippen.'; $c.apTxtAufTag.Foreground = Get-HUBrush '#AAAAAA'; $c.apTxtAufGruppe.Text = '-'; $c.apTxtAufProfil.Text = '-'; return }
    if (-not (Test-APTagText $tag)) {
        $c.apTxtAufTag.Text = 'Nur Buchstaben, Ziffern, - und _ erlaubt (keine Leerzeichen, kein Doppelpunkt).'; $c.apTxtAufTag.Foreground = Get-HUBrush '#F44336'
        $c.apTxtAufGruppe.Text = '-'; $c.apTxtAufProfil.Text = '-'; return
    }
    $vorh = @($info.Tags | Where-Object { "$($_.Tag)".ToUpperInvariant() -eq $tag.ToUpperInvariant() })
    if ($vorh.Count) {
        $v = $vorh[0]
        $andersGeschrieben = @($v.Schreibweisen | Where-Object { "$_" -cne $tag })
        $c.apTxtAufTag.Text = "$(if ($v.PSObject.Properties['NurRegel'] -and $v.NurRegel) { 'noch kein Geraet - nur in einer Gruppenregel' } else { "vorhanden: $($v.Anzahl) Geraet(e)" })$(if ($andersGeschrieben.Count) { " - auch geschrieben als $($andersGeschrieben -join ', ') (gilt in Gruppenregeln als gleich)" })"
        $c.apTxtAufTag.Foreground = Get-HUBrush $(if ($andersGeschrieben.Count) { '#FFB74D' } else { '#81C784' })
    } else { $c.apTxtAufTag.Text = 'neuer Tag'; $c.apTxtAufTag.Foreground = Get-HUBrush '#4FC3F7' }
    $treffer = @(Find-APTagGruppen $tag @($info.Gruppen))
    $sicher = @($treffer | Where-Object { $_.Art -eq 'sicher' })
    $teile = @(foreach ($g in $treffer) {
            $art = switch ($g.Art) { 'sicher' { 'Regel -eq' } 'unsicher' { 'zusammengesetzte Regel - bitte pruefen' } 'mehrere' { 'trifft mehrere Tags (startsWith/contains)' } }
            "$($g.Name) ($art$(if ("$($g.Aktiv)" -and "$($g.Aktiv)" -ne 'On') { ", Verarbeitung $($g.Aktiv)" }))"
        })
    if ($sicher.Count) { $script:APAufGruppe = $sicher[0] }
    # Loeschen anbieten: die eben angelegte Gruppe oder eine sichere Gruppe, die laut Beschreibung von der App stammt (auch aus frueheren Sitzungen)
    $weg = if ($script:APAufNeueGruppe -and $script:APAufNeueGruppe.Tenant -eq $t) { $script:APAufNeueGruppe } elseif ($sicher.Count -and $sicher[0].VonApp) { [pscustomobject]@{ Tenant = $t; Id = $sicher[0].Id; Name = $sicher[0].Name } } else { $null }
    $script:APAufGruppeWeg = $weg
    if ($weg) { $c.apBtnAufGruppeWeg.Visibility = 'Visible' }
    if (-not $treffer.Count) {
        $c.apTxtAufGruppe.Text = 'keine dynamische Gruppe trifft diesen Tag'
        $c.apTxtAufGruppe.Foreground = Get-HUBrush '#FFB74D'
    } else {
        $c.apTxtAufGruppe.Text = ($teile -join '   |   ')
        $c.apTxtAufGruppe.Foreground = Get-HUBrush $(if ($sicher.Count) { '#81C784' } else { '#FFB74D' })
    }
    if (-not $sicher.Count) {
        if (-not "$($c.apTxtAufGruppeName.Text)" -or "$($c.apTxtAufGruppeName.Tag)" -ne $tag) { $c.apTxtAufGruppeName.Text = "AP-$tag"; $c.apTxtAufGruppeName.Tag = $tag }
        $c.apTxtAufGruppeName.Visibility = 'Visible'; $c.apBtnAufGruppeNeu.Visibility = 'Visible'
    }
    $prof = @($treffer | ForEach-Object { @($_.Profile) } | Where-Object { $_ } | Select-Object -Unique)
    if ($prof.Count) { $c.apTxtAufProfil.Text = ($prof -join ', '); $c.apTxtAufProfil.Foreground = Get-HUBrush '#81C784' }
    elseif ($treffer.Count) { $c.apTxtAufProfil.Text = 'Gruppe hat KEIN Autopilot-Profil - die Geraete bekommen keines (Profil im Portal der Gruppe zuweisen)'; $c.apTxtAufProfil.Foreground = Get-HUBrush '#FFB74D' }
    else { $c.apTxtAufProfil.Text = 'ohne Gruppe kein Profil'; $c.apTxtAufProfil.Foreground = Get-HUBrush '#FFB74D' }
}
function Update-APAufRechteBanner {
    $c = $script:Controls
    $t = Get-APAufTenant
    $f = if ($t -and $script:APAufRechte.ContainsKey($t)) { @($script:APAufRechte[$t]) } else { @() }
    if (-not $f.Count) { $c.apAufRechte.Visibility = 'Collapsed'; return }
    $c.apTxtAufRechte.Text = "Fuer das Aufnehmen fehlen in $(Get-APTenantName $t): $($f -join ', ')"
    $c.apAufRechte.Visibility = 'Visible'
}
function Grant-APAufRechte {
    $t = Get-APAufTenant
    $f = if ($t -and $script:APAufRechte.ContainsKey($t)) { @($script:APAufRechte[$t]) } else { @() }
    if (-not $f.Count) { return }
    try { [void](Show-HUTenantSetupDialog -TenantKey $t -Preselect $f) } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning; return }
    Write-APLog 'Rechte erteilt - sie stehen nach etwa 1 Minute im Token. Lade in 90 Sekunden neu ...' '#AAAAAA'
    Invoke-HUDelayed 90 { Start-APAufLaden -Neu }
}
function Start-APAufLaden([switch]$Neu, [string]$Tenant) {
    $t = if ($Tenant) { $Tenant } else { Get-APAufTenant }
    if (-not $t) { Show-HUMessage 'Bitte zuerst einen Tenant waehlen.' -Icon Info; return }
    $script:APAufJobTenant = $t
    Set-APDot $script:Controls['apDotAuf'] $true
    Write-APLog "Lade Tags, Gruppen und Profile: $(Get-APTenantName $t) ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-AufLaden' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APNeu = [bool]$Neu } -Code {
        . $APCore
        Get-APFehlendeRechte $APTenant $Settings -Neu:$APNeu -Liste $script:APRechteAufnehmen -Art 'Auf'
        try { Get-APAufInfo $APTenant $Settings } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAuf'] $false
        $t = $script:APAufJobTenant
        foreach ($r in @($res | Where-Object { $_ -and $_.PSObject.Properties['Art'] -and $_.Art -eq 'Auf' })) { $script:APAufRechte["$($r.Tenant)"] = @($r.Fehlt) }
        $i = @($res | Where-Object { $_ -and $_.PSObject.Properties['APAufInfo'] })
        if ($i.Count) {
            $info = $i[0]
            # eine neu angelegte Gruppe ist evtl. noch nicht in der Liste
            if ($script:APAufNeueGruppe -and $script:APAufNeueGruppe.Tenant -eq $t -and -not @($info.Gruppen | Where-Object { $_.Id -eq $script:APAufNeueGruppe.Id }).Count) {
                $info.Gruppen = @($info.Gruppen) + [pscustomobject]@{ Id = $script:APAufNeueGruppe.Id; Name = $script:APAufNeueGruppe.Name; Regel = $script:APAufNeueGruppe.Regel; Verarbeitung = 'On'; VonApp = $true; Profile = @() }
            }
            # Tags auch aus den Regeln dynamischer Gruppen (-eq), z. B. SN-2026 fuer den naechsten Jahrgang ohne Geraete (Konzept 3.3)
            $bek = @{}; foreach ($x in @($info.Tags)) { $bek["$($x.Tag)".ToUpperInvariant()] = 1 }
            $extra = @()
            foreach ($g in @($info.Gruppen)) {
                foreach ($tm in @((Get-APRegelTerme "$($g.Regel)").Terme | Where-Object { $_.Op -eq 'eq' -and "$($_.Wert)" })) {
                    $u = "$($tm.Wert)".ToUpperInvariant()
                    if (-not $bek.ContainsKey($u)) { $bek[$u] = 1; $extra += [pscustomobject]@{ Tag = "$($tm.Wert)"; Anzahl = 0; Schreibweisen = @("$($tm.Wert)"); NurRegel = $true } }
                }
            }
            if ($extra.Count) { $info.Tags = @(@($info.Tags) + $extra | Sort-Object Tag) }
            $script:APAufInfo[$t] = $info
            $h = @{}; foreach ($k in $info.Serien.Keys) { $h[$k] = 1 }
            $script:APSerienCache[$t] = $h; $script:APSerienZeit[$t] = Get-Date
            $cmb = $script:Controls['apCmbAufTag']
            $cmb.Items.Clear(); foreach ($x in @($info.Tags)) { [void]$cmb.Items.Add("$($x.Tag)") }
            $cmb.SelectedIndex = -1
        }
        Update-APAufRechteBanner
        Update-APAufTag
        Update-APAufGrid
        # Tag aendern wartete auf Tags/Gruppen dieses Tenants
        if ($script:APTagWartet -and $script:APTagWartet.Tenant -eq $t) { $w = $script:APTagWartet; $script:APTagWartet = $null; if ($script:APAufInfo.ContainsKey($t)) { Show-APTagDialog $w.Tenant $w.Rows } }
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotAuf'] $false }
}
function New-APAufGruppeUI {
    $c = $script:Controls
    $t = Get-APAufTenant; $tag = Get-APAufTag; $name = "$($c.apTxtAufGruppeName.Text)".Trim()
    if (-not $t -or -not (Test-APTagText $tag)) { Show-HUMessage 'Bitte zuerst einen gueltigen Group Tag waehlen.' -Icon Info; return }
    if (-not $name) { Show-HUMessage 'Bitte einen Namen fuer die Gruppe eintippen.' -Icon Info; return }
    if (@($script:APAufRechte[$t]) -contains 'Group.Create') { Show-HUMessage 'Zum Anlegen fehlt das Recht Group.Create - oben "Rechte erteilen ..." verwenden.' -Icon Info; return }
    $regel = New-APGruppenRegel $tag
    if (-not (Confirm-HU "Dynamische Sicherheitsgruppe in $(Get-APTenantName $t) anlegen?`n`nName: $name`nRegel: $regel`nVerarbeitung: Ein`n`nDie Gruppe bekommt KEIN Autopilot-Profil - das wird im Portal zugewiesen. Mitglieder erscheinen erst, wenn Entra die Regel verarbeitet hat (kann dauern)." 'Autopilot - Gruppe anlegen')) { return }
    $script:APAufJobTenant = $t
    Set-APDot $c['apDotAuf'] $true
    $ok = Start-HUJob -Name 'AP-AufGruppe' -Output $c['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APName = $name; APTag = $tag } -Code {
        . $APCore
        try { New-APAufGruppe $APTenant $Settings $APName $APTag } catch { Write-HULog -Message "Gruppe anlegen: $($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAuf'] $false
        $g = @($res | Where-Object { $_ -and $_.PSObject.Properties['APGruppeNeu'] })
        if (-not $g.Count) { return }
        $script:APAufNeueGruppe = $g[0]
        $t = $script:APAufJobTenant
        if ($script:APAufInfo.ContainsKey($t)) {
            $script:APAufInfo[$t].Gruppen = @($script:APAufInfo[$t].Gruppen) + [pscustomobject]@{ Id = $g[0].Id; Name = $g[0].Name; Regel = $g[0].Regel; Verarbeitung = 'On'; VonApp = $true; Profile = @() }
        }
        Write-APLog "Gruppe '$($g[0].Name)' angelegt - Rueckgaengig mit 'Angelegte Gruppe loeschen ...'" '#81C784'
        Update-APAufTag
    }
    if (-not $ok) { Set-APDot $c['apDotAuf'] $false }
}
function Remove-APAufGruppeUI {
    $g = $script:APAufGruppeWeg; if (-not $g) { return }
    if (-not (Confirm-HU "Die von der App angelegte Gruppe '$($g.Name)' in $(Get-APTenantName $g.Tenant) wieder loeschen?`n`nNur loeschen, wenn kein Geraet mehr diesen Tag hat und der Gruppe nichts zugewiesen ist (Apps, Richtlinien, Profil). Geraete verlieren damit ihre Mitgliedschaft. Geloeschte Gruppen lassen sich 30 Tage im Entra-Portal wiederherstellen." 'Autopilot - Gruppe loeschen' -Warning)) { return }
    Set-APDot $script:Controls['apDotAuf'] $true
    $ok = Start-HUJob -Name 'AP-AufGruppeWeg' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $g.Tenant; APId = $g.Id } -Code {
        . $APCore
        try { Remove-APAufGruppe $APTenant $Settings $APId } catch { Write-HULog -Message "Gruppe loeschen: $($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAuf'] $false
        $r = @($res | Where-Object { $_ -and $_.PSObject.Properties['APGruppeWeg'] })
        if (-not $r.Count) { return }
        Write-APLog "$($r[0].Text)" $(if ($r[0].Ok) { '#81C784' } else { '#FFB74D' })
        if ($r[0].Ok) {
            $id = $r[0].Id; $t = $r[0].Tenant
            if ($script:APAufInfo.ContainsKey($t)) { $script:APAufInfo[$t].Gruppen = @($script:APAufInfo[$t].Gruppen | Where-Object { $_.Id -ne $id }) }
            if ($script:APAufNeueGruppe -and $script:APAufNeueGruppe.Id -eq $id) { $script:APAufNeueGruppe = $null }
            $script:APAufGruppeWeg = $null
            Update-APAufTag
        }
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotAuf'] $false }
}
function Start-APAufImportUI {
    $c = $script:Controls
    $t = Get-APAufTenant; $tag = Get-APAufTag
    if (-not $t) { Show-HUMessage 'Bitte zuerst einen Tenant waehlen.' -Icon Info; return }
    if (-not $script:APAufInfo.ContainsKey($t)) { Show-HUMessage "Bitte zuerst oben 'Laden' klicken (prueft, welche Geraete schon registriert sind)." -Icon Info; return }
    if (-not (Test-APTagText $tag)) { Show-HUMessage 'Bitte einen gueltigen Group Tag waehlen oder eintippen (Buchstaben, Ziffern, - und _).' -Icon Info; return }
    $f = @($script:APAufRechte[$t])
    if ($f -contains 'DeviceManagementServiceConfig.ReadWrite.All') { Show-HUMessage 'Zum Importieren fehlt das Recht DeviceManagementServiceConfig.ReadWrite.All - oben "Rechte erteilen ..." verwenden.' -Icon Info; return }
    if (Test-HUJobRunning 'AP-AufImport') { Show-HUMessage 'Ein Import laeuft noch.' -Icon Info; return }
    $sel = @($c.apGridAuf.SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage "Bitte die Geraete markieren (z. B. 'Alle neuen markieren')." -Icon Info; return }
    $neu = @($sel | Where-Object { $_.Neu })
    $nicht = $sel.Count - $neu.Count
    if (-not $neu.Count) { Show-HUMessage 'Unter den markierten Geraeten ist keines neu - schon registrierte bzw. in einem anderen Tenant werden nicht importiert.' -Icon Info; return }
    if ($neu.Count -gt 500) { Show-HUMessage "Hoechstens 500 Geraete je Durchgang (markiert: $($neu.Count))." -Icon Info; return }
    $daten = @(Get-APArchivDaten $t)
    $geraete = @(foreach ($r in $neu) { $e = Get-APNeuesterHash $daten $r.Seriennummer; if ($e -and "$($e.Hash)") { [pscustomobject]@{ Seriennummer = "$($e.Seriennummer)"; Hash = "$($e.Hash)"; ProductId = "$($e.ProductId)" } } })
    if (-not $geraete.Count) { Show-HUMessage 'Fuer die markierten Geraete liegt kein Hash im Archiv.' -Icon Info; return }
    $g = $script:APAufGruppe
    $tn = Get-APTenantName $t
    $abw = @($neu | Where-Object { "$($_.TagDatei)" -and "$($_.TagDatei)".ToUpperInvariant() -ne $tag.ToUpperInvariant() }).Count
    $warn = @()
    if (-not $g) { $warn += 'Keine Gruppe trifft den Tag sicher - die Geraete bekommen KEIN Autopilot-Profil.' }
    elseif (-not @($g.Profile).Count) { $warn += "Gruppe '$($g.Name)' hat kein Autopilot-Profil - die Geraete bekommen keines." }
    if ($abw) { $warn += "$abw Geraet(e) haben in der Datei einen anderen Tag - es gilt '$tag'." }
    if ($nicht) { $warn += "$nicht markierte(s) Geraet(e) sind nicht neu und werden uebersprungen." }
    $text = "Import in Autopilot: $tn`n`n  Geraete: $($geraete.Count)`n  Group Tag: $tag`n  Gruppe: $(if ($g) { $g.Name } else { '(keine)' })`n  Profil: $(if ($g -and @($g.Profile).Count) { @($g.Profile) -join ', ' } else { '(keines)' })" +
        $(if ($warn.Count) { "`n`nACHTUNG:`n- " + ($warn -join "`n- ") } else { '' }) +
        "`n`nDanach: Import-Eintraege werden entfernt, Autopilot-Sync einmal ausgeloest, Status alle 2 Minuten nachverfolgt."
    if (-not (Confirm-APTippen $text $tn $geraete.Count)) { return }
    $stand = @{}
    foreach ($x in $geraete) { $stand[(ConvertTo-APSerialKey $x.Seriennummer)] = [pscustomobject]@{ Import = 'laeuft'; Fehler = ''; InGruppe = $null; Profil = ''; ProfilRoh = ''; TagJetzt = ''; ZeitGruppe = $null; ZeitProfil = $null } }
    $script:APAufLauf = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Tenant = $t; Start = Get-Date; Tag = $tag; GruppeId = $(if ($g) { $g.Id } else { '' }); GruppeName = $(if ($g) { $g.Name } else { '' }); ProfilErwartet = [bool]($g -and @($g.Profile).Count); Stand = $stand; Serien = [string[]]@($geraete | ForEach-Object { $_.Seriennummer }) }
    Update-APAufGrid
    Set-APDot $c['apDotAuf'] $true
    Write-APLog "Importiere $($geraete.Count) Geraet(e) in $tn mit Tag $tag ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-AufImport' -Output $c['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APGeraete = $geraete; APTag = $tag } -Code {
        . $APCore
        try { Start-APAufImport $APTenant $Settings $APGeraete $APTag } catch { Write-HULog -Message "Import: $($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAuf'] $false
        $l = $script:APAufLauf; if (-not $l) { return }
        $erg = @($res | Where-Object { $_ -and $_.PSObject.Properties['APAufErg'] })
        foreach ($e in $erg) {
            $k = ConvertTo-APSerialKey $e.Seriennummer
            if (-not $l.Stand.ContainsKey($k)) { continue }
            $l.Stand[$k].Import = $(if ($e.Status -eq 'complete') { 'ok' } elseif ($e.Status -eq 'error') { 'Fehler' } else { 'offen' })
            $l.Stand[$k].Fehler = "$($e.Fehler)"
        }
        if (-not $erg.Count) { foreach ($v in $l.Stand.Values) { if ($v.Import -eq 'laeuft') { $v.Import = 'Fehler'; $v.Fehler = 'Import nicht gesendet - siehe Protokoll' } } }
        $nOk = @($erg | Where-Object { $_.Status -eq 'complete' }).Count
        $nF = @($erg | Where-Object { $_.Status -eq 'error' }).Count
        Write-APLog "Import fertig: $nOk ok$(if ($nF) { ", $nF Fehler" })$(if ($erg.Count - $nOk - $nF) { ", $($erg.Count - $nOk - $nF) noch offen" })" $(if ($nF) { '#FFB74D' } else { '#81C784' })
        foreach ($e in @($erg | Where-Object { $_.Fehler })) { Write-APLog "  $($e.Seriennummer): $($e.Fehler)" '#FFB74D' }
        Update-APAufGrid
        if ($nOk) { Set-APAufWecker 60 }
    }
    if (-not $ok) { Set-APDot $c['apDotAuf'] $false }
}
# Nachverfolgung: in Autopilot? in der Gruppe? Profil zugewiesen? (Dauer ab Import getrennt messen - T7)
function Start-APAufStatus([switch]$Auto) {
    $l = $script:APAufLauf
    if (-not $l) { if (-not $Auto) { Show-HUMessage 'Noch kein Import in dieser Sitzung.' -Icon Info }; return }
    if ($Auto -and -not [bool]$script:Controls['apChkAufAuto'].IsChecked) { return }
    if (Test-HUJobRunning 'AP-AufStatus') { return }
    $serien = [string[]]@($l.Serien | Where-Object { $x = $l.Stand[(ConvertTo-APSerialKey $_)]; $x -and $x.Import -ne 'Fehler' })
    if (-not $serien.Count) { return }
    Set-APDot $script:Controls['apDotAuf'] $true
    $ok = Start-HUJob -Name 'AP-AufStatus' -Quiet:$Auto -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $l.Tenant; APSerien = $serien; APGruppe = "$($l.GruppeId)" } -Code {
        . $APCore
        try { Get-APAufStatus $APTenant $Settings $APSerien $APGruppe } catch { Write-HULog -Message "Status: $($_.Exception.Message)" -Level 'WARN' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAuf'] $false
        $l = $script:APAufLauf; if (-not $l) { return }
        $jetzt = Get-Date
        foreach ($s in @($res | Where-Object { $_ -and $_.PSObject.Properties['APAufStat'] })) {
            $x = $l.Stand[(ConvertTo-APSerialKey $s.Seriennummer)]; if (-not $x) { continue }
            if ($s.InAutopilot -and $x.Import -ne 'ok') { $x.Import = 'ok'; $x.Fehler = '' }
            $x.TagJetzt = "$($s.GroupTag)"
            $x.InGruppe = $s.InGruppe
            $x.Profil = $(if ($s.InAutopilot) { "$($s.Profil)" } else { 'noch nicht in Autopilot' })
            $x.ProfilRoh = "$($s.ProfilRoh)"
            if ($s.InGruppe -and -not $x.ZeitGruppe) { $x.ZeitGruppe = $jetzt }
            if ("$($s.ProfilRoh)" -like 'assigned*' -and -not $x.ZeitProfil) { $x.ZeitProfil = $jetzt }
        }
        Update-APAufGrid
        # offen = noch kein Profil; erwartet die Gruppe keines, reicht Autopilot + Gruppe (sonst 2 Stunden umsonst nachfragen)
        $offen = @($l.Stand.Values | Where-Object { $_.Import -ne 'Fehler' -and $(if ($l.ProfilErwartet) { "$($_.ProfilRoh)" -notlike 'assigned*' } else { -not $_.InGruppe -and "$($l.GruppeId)" }) }).Count
        $mitGruppe = @($l.Stand.Values | Where-Object { $_.InGruppe }).Count
        Write-APLog "Status $($jetzt.ToString('HH:mm')): $(@($l.Stand.Values | Where-Object { "$($_.ProfilRoh)" -like 'assigned*' }).Count) mit Profil, $mitGruppe in der Gruppe, $offen offen" '#AAAAAA'
        if ($offen -and ($jetzt - $l.Start).TotalMinutes -lt 120 -and [bool]$script:Controls['apChkAufAuto'].IsChecked) {
            Set-APAufWecker 120
        } elseif (-not $offen) { Write-APLog $(if ($l.ProfilErwartet) { 'Alle importierten Geraete haben ein Profil - bereit fuer die Ausgabe.' } else { 'Alle importierten Geraete sind in Autopilot und in der Gruppe - ein Profil bekommen sie erst, wenn der Gruppe eines zugewiesen ist. Nachverfolgung beendet.' }) '#81C784' }
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotAuf'] $false }
}
# Genau EIN Wecker fuer die automatische Nachverfolgung (sonst laufen nach 'Status pruefen' zwei Ketten parallel)
function Set-APAufWecker([int]$Sekunden) {
    if ($script:APAufWecker) { return }
    $script:APAufWecker = $true
    Invoke-HUDelayed $Sekunden {
        $script:APAufWecker = $false
        if ($script:APAufLauf) { Start-APAufStatus -Auto }
    }
}
function Select-APAufAlleNeuen {
    $g = $script:Controls['apGridAuf']
    $g.SelectedItems.Clear()
    foreach ($r in @($g.ItemsSource | Where-Object { $_ -and $_.Neu })) { [void]$g.SelectedItems.Add($r) }
}

# ----------------------------------------------------------------------------------------------
# Tag aendern (Konzept 3.6) - aus der Uebersicht, ein Tenant je Durchgang
# ----------------------------------------------------------------------------------------------
function Start-APTagAendern {
    $sel = @($script:Controls['apGrid'].SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage 'Bitte in der Uebersicht die Geraete markieren.' -Icon Info; return }
    $ten = @($sel | ForEach-Object { "$($_.Tenant)" } | Select-Object -Unique)
    if ($ten.Count -ne 1) { Show-HUMessage 'Bitte nur Geraete aus EINEM Tenant markieren.' -Icon Info; return }
    $t = $ten[0]
    if (Test-HUJobRunning 'AP-Tag') { Show-HUMessage 'Eine Tag-Aenderung laeuft noch.' -Icon Info; return }
    if (-not $script:APAufInfo.ContainsKey($t)) {
        # Tags, Gruppen, Profile und Rechte zuerst lesen, danach geht der Dialog auf
        $script:APTagWartet = [pscustomobject]@{ Tenant = $t; Rows = $sel }
        Start-APAufLaden -Tenant $t
        return
    }
    Show-APTagDialog $t $sel
}
function Show-APTagDialog([string]$Tenant, [object[]]$Rows) {
    $info = $script:APAufInfo[$Tenant]
    $f = @($script:APAufRechte[$Tenant])
    if ($f -contains 'DeviceManagementServiceConfig.ReadWrite.All') { Show-HUMessage "Zum Aendern fehlt das Recht DeviceManagementServiceConfig.ReadWrite.All in $(Get-APTenantName $Tenant) - im Reiter Aufnehmen 'Rechte erteilen ...'." -Icon Info; return }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="640" SizeToContent="Height" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip" Title="Autopilot - Group Tag aendern">
    <Window.Resources><!--HU:THEME--></Window.Resources>
    <StackPanel Margin="14">
        <TextBlock x:Name="txtKopf" Foreground="#DDDDDD" TextWrapping="Wrap" FontSize="13" Margin="0,0,0,10"/>
        <TextBlock Text="Neuer Group Tag" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
            <TextBox x:Name="tbTag" Width="180" Style="{StaticResource DarkTextBox}" Margin="0,0,6,0" ToolTip="Buchstaben, Ziffern, - und _"/>
            <ComboBox x:Name="cbTag" Width="180" Style="{StaticResource DarkComboBox}" ToolTip="Vorhandenen Tag waehlen - wird links eingetragen"/>
        </StackPanel>
        <TextBlock x:Name="txtTag" Foreground="#AAAAAA" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <TextBlock x:Name="txtGruppe" Foreground="#CCCCCC" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <TextBlock x:Name="txtProfil" Foreground="#CCCCCC" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBlock x:Name="txtWarn" Foreground="#FFB74D" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <TextBlock x:Name="lblT" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <TextBox x:Name="tbT" Style="{StaticResource DarkTextBox}" Margin="0,0,0,8" ToolTip="Tenant-Namen genau so eintippen, wie er angezeigt wird"/>
        <TextBlock x:Name="lblN" Style="{StaticResource FieldLabel}" Margin="0,0,0,4"/>
        <TextBox x:Name="tbN" Style="{StaticResource DarkTextBox}" Margin="0,0,0,10" ToolTip="Anzahl der Geraete eintippen"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnOk" Content="Tag aendern" Width="120" Background="#B85C00" Style="{StaticResource DarkButton}" Margin="0,0,8,0" IsEnabled="False" ToolTip="Erst aktiv, wenn Tag und Bestaetigung stimmen"/>
            <Button x:Name="btnNo" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True" ToolTip="Nichts aendern"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $dc = $d.C
    try { $w.Owner = $script:Window } catch { }
    $tn = Get-APTenantName $Tenant
    $alt = @($Rows | Group-Object { if ("$($_.GroupTag)") { "$($_.GroupTag)" } else { '(ohne)' } } | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ', '
    $eing = @($Rows | Where-Object { $_.InIntune -eq 'ja' }).Count
    $dc.txtKopf.Text = "$($Rows.Count) Geraet(e) in $tn. Bisheriger Tag: $alt"
    foreach ($x in @($info.Tags)) { [void]$dc.cbTag.Items.Add("$($x.Tag)") }
    $dc.lblT.Text = "Zur Bestaetigung Tenant-Namen eintippen: $tn"
    $mitN = ($Rows.Count -gt 5)
    if ($mitN) { $dc.lblN.Text = "Anzahl der Geraete eintippen: $($Rows.Count)" } else { $dc.lblN.Visibility = 'Collapsed'; $dc.tbN.Visibility = 'Collapsed' }
    $st = @{ Ok = $false; Tag = ''; Gruppe = $null; Profile = @() }
    $pruef = {
        $tag = "$($dc.tbTag.Text)".Trim()
        $gueltig = Test-APTagText $tag
        $st.Gruppe = $null
        if (-not $tag) { $dc.txtTag.Text = 'Tag eintippen oder waehlen.'; $dc.txtGruppe.Text = ''; $dc.txtProfil.Text = ''; $dc.txtWarn.Text = '' }
        elseif (-not $gueltig) { $dc.txtTag.Text = 'Nur Buchstaben, Ziffern, - und _ erlaubt.'; $dc.txtTag.Foreground = Get-HUBrush '#F44336'; $dc.txtGruppe.Text = ''; $dc.txtProfil.Text = ''; $dc.txtWarn.Text = '' }
        else {
            $v = @($info.Tags | Where-Object { "$($_.Tag)".ToUpperInvariant() -eq $tag.ToUpperInvariant() })
            $dc.txtTag.Text = $(if ($v.Count) { if ($v[0].PSObject.Properties['NurRegel'] -and $v[0].NurRegel) { 'noch kein Geraet - nur in einer Gruppenregel' } else { "vorhanden: $($v[0].Anzahl) Geraet(e)" } } else { 'neuer Tag - keine Gruppe kennt ihn' })
            $dc.txtTag.Foreground = Get-HUBrush '#AAAAAA'
            $tr = @(Find-APTagGruppen $tag @($info.Gruppen))
            $si = @($tr | Where-Object { $_.Art -eq 'sicher' })
            # Nachverfolgung: sichere Gruppe, sonst die erste passende (zusammengesetzte Regel) - Profil zaehlt aus allen Treffern
            $st.Gruppe = $(if ($si.Count) { $si[0] } elseif ($tr.Count) { $tr[0] } else { $null })
            $st.Profile = @($tr | ForEach-Object { @($_.Profile) } | Where-Object { $_ } | Select-Object -Unique)
            $dc.txtGruppe.Text = 'Gruppe: ' + $(if ($tr.Count) { (@($tr | ForEach-Object { "$($_.Name) ($(switch ($_.Art) { 'sicher' { 'Regel -eq' } 'unsicher' { 'zusammengesetzte Regel' } 'mehrere' { 'trifft mehrere Tags' } }))" }) -join ', ') } else { 'keine dynamische Gruppe trifft diesen Tag' })
            $dc.txtGruppe.Foreground = Get-HUBrush $(if ($si.Count) { '#81C784' } else { '#FFB74D' })
            $pr = @($tr | ForEach-Object { @($_.Profile) } | Where-Object { $_ } | Select-Object -Unique)
            $dc.txtProfil.Text = 'Profil: ' + $(if ($pr.Count) { $pr -join ', ' } else { '(keines)' })
            $dc.txtProfil.Foreground = Get-HUBrush $(if ($pr.Count) { '#81C784' } else { '#FFB74D' })
            $wa = @()
            if ($eing) { $wa += "$eing Geraet(e) sind schon eingerichtet: der Gruppenwechsel wirkt SOFORT - andere Apps, Richtlinien und Profil, nicht erst beim naechsten Zuruecksetzen." }
            if (-not $pr.Count) { $wa += 'Ohne Profil startet ein zurueckgesetztes Geraet nicht mehr mit dem Schulprofil.' }
            $dc.txtWarn.Text = ($wa -join "`n")
        }
        $dc.btnOk.IsEnabled = ($gueltig -and "$($dc.tbT.Text)".Trim() -ceq $tn -and (-not $mitN -or "$($dc.tbN.Text)".Trim() -eq "$($Rows.Count)"))
    }
    $dc.cbTag.Add_SelectionChanged({ $v = "$($dc.cbTag.SelectedItem)"; if ($v) { $dc.tbTag.Text = $v } })
    $dc.tbTag.Add_TextChanged({ if ($dc.cbTag.SelectedIndex -ge 0 -and "$($dc.cbTag.SelectedItem)" -ne "$($dc.tbTag.Text)".Trim()) { $dc.cbTag.SelectedIndex = -1 }; & $pruef })
    $dc.tbT.Add_TextChanged($pruef); $dc.tbN.Add_TextChanged($pruef)
    $dc.btnOk.Add_Click({ $st.Ok = $true; $st.Tag = "$($dc.tbTag.Text)".Trim(); $w.Close() })
    $dc.btnNo.Add_Click({ $w.Close() })
    & $pruef
    Restore-HUDialogState $w 'APTag'
    $w.Add_Closing({ Save-HUDialogState $w 'APTag' })
    [void]$w.ShowDialog()
    if (-not $st.Ok) { return }
    $geraete = @($Rows | ForEach-Object { [pscustomobject]@{ Seriennummer = "$($_.Seriennummer)"; AutopilotId = "$($_.AutopilotId)"; Alt = "$($_.GroupTag)" } })
    Start-APTagJob $Tenant $geraete $st.Tag $st.Gruppe -ProfilErwartet:([bool]@($st.Profile).Count)
}
function Start-APTagJob([string]$Tenant, [object[]]$Geraete, [string]$Tag, $Gruppe, [switch]$Rueck, [switch]$ProfilErwartet) {
    Set-APDot $script:Controls['apDotLaden'] $true
    Write-APLog "$(if ($Rueck) { 'Rueckgaengig: ' })Group Tag aendern: $(@($Geraete).Count) Geraet(e) in $(Get-APTenantName $Tenant) -> $(if ($Rueck) { 'vorheriger Tag' } else { $Tag }) ..." '#4FC3F7'
    $script:APTagJob = [pscustomobject]@{ Tenant = $Tenant; Tag = $Tag; Gruppe = $Gruppe; Rueck = [bool]$Rueck; ProfilErwartet = [bool]$ProfilErwartet }
    $code = {
        . $APCore
        if ($APRueck) {
            # je vorherigem Tag ein Durchgang (ohne Tag gab es vorher: bleibt unveraendert - nur mit gueltigem Tag)
            foreach ($g in @($APGeraete | Group-Object Alt)) {
                if (-not (Test-APTagText "$($g.Name)")) { Write-HULog -Message "$($g.Count) Geraet(e) hatten vorher keinen gueltigen Tag ('$($g.Name)') - nicht zurueckgesetzt" -Level 'WARN' -Tenant $APTenant; continue }
                Set-APGroupTag $APTenant $Settings @($g.Group | ForEach-Object { [pscustomobject]@{ Seriennummer = $_.Seriennummer; AutopilotId = $_.AutopilotId; Alt = $_.Neu } }) "$($g.Name)"
            }
        } else { Set-APGroupTag $APTenant $Settings $APGeraete $APTag }
    }
    $ok = Start-HUJob -Name 'AP-Tag' -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $Tenant; APGeraete = @($Geraete); APTag = $Tag; APRueck = [bool]$Rueck } -Code $code -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotLaden'] $false
        $j = $script:APTagJob
        $r = @($res | Where-Object { $_ -and $_.PSObject.Properties['APTagErg'] })
        $gut = @($r | Where-Object { $_.Ok })
        Write-APLog "Tag geaendert: $($gut.Count) ok$(if ($r.Count - $gut.Count) { ", $($r.Count - $gut.Count) Fehler" }) - Gruppenwechsel und Profil folgen (Entra/Autopilot brauchen etwas)" $(if ($r.Count - $gut.Count) { '#FFB74D' } else { '#81C784' })
        if (-not $j.Rueck -and $gut.Count) {
            $script:APTagAlt = [pscustomobject]@{ Tenant = $j.Tenant; Geraete = @($gut | ForEach-Object { [pscustomobject]@{ Seriennummer = $_.Seriennummer; AutopilotId = $_.AutopilotId; Alt = $_.Alt; Neu = $_.Neu } }) }
            $script:Controls['apBtnTagUndo'].Visibility = 'Visible'
        } elseif ($j.Rueck) { $script:APTagAlt = $null; $script:Controls['apBtnTagUndo'].Visibility = 'Collapsed' }
        # Nachverfolgung wie beim Aufnehmen (Gruppe des neuen Tags, Profil) - Ergebnis im Protokoll und im Reiter Aufnehmen
        if ($gut.Count -and -not $j.Rueck) {
            $stand = @{}
            foreach ($x in $gut) { $stand[(ConvertTo-APSerialKey $x.Seriennummer)] = [pscustomobject]@{ Import = 'ok'; Fehler = ''; InGruppe = $null; Profil = ''; ProfilRoh = ''; TagJetzt = $x.Neu; ZeitGruppe = $null; ZeitProfil = $null } }
            $g = $j.Gruppe
            $script:APAufLauf = [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); Tenant = $j.Tenant; Start = Get-Date; Tag = $j.Tag; GruppeId = $(if ($g) { $g.Id } else { '' }); GruppeName = $(if ($g) { $g.Name } else { '' }); ProfilErwartet = $j.ProfilErwartet; Stand = $stand; Serien = [string[]]@($gut | ForEach-Object { $_.Seriennummer }); Art = 'Tag' }
            Set-APAufWecker 60
        }
        Invoke-HUDelayed 20 { Start-APLaden @($script:APTagJob.Tenant) }
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotLaden'] $false }
}
function Undo-APTagAenderung {
    $a = $script:APTagAlt; if (-not $a) { return }
    $liste = (@($a.Geraete | Group-Object Alt | ForEach-Object { "  $(if ("$($_.Name)") { $_.Name } else { '(ohne)' }): $($_.Count) Geraet(e)" }) -join "`n")
    if (-not (Confirm-HU "Letzte Tag-Aenderung in $(Get-APTenantName $a.Tenant) rueckgaengig machen?`n`nDie Geraete bekommen wieder:`n$liste`n`nDer Gruppenwechsel wirkt bei eingerichteten Geraeten sofort." 'Autopilot - Rueckgaengig' -Warning)) { return }
    Start-APTagJob $a.Tenant @($a.Geraete) '' $null -Rueck
}

# ----------------------------------------------------------------------------------------------
# Ausscheiden (Stufe 5, Konzept Teil 4): ein Tenant, Geraete aus der Uebersicht, Vorgaenge mit Nachverfolgung
# ----------------------------------------------------------------------------------------------
function Get-APAusVorgaenge([string]$Tenant) {
    if (-not $Tenant) { return @() }
    if (-not $script:APAusVorgaenge.ContainsKey($Tenant)) {
        try { $script:APAusVorgaenge[$Tenant] = @(Read-APVorgaenge $Tenant) } catch { Write-APLog "Vorgaenge nicht lesbar: $($_.Exception.Message)" '#F44336'; $script:APAusVorgaenge[$Tenant] = @() }
    }
    return @($script:APAusVorgaenge[$Tenant])
}
function Save-APAusVorgaenge([string]$Tenant, [object[]]$Liste) {
    try { Save-APVorgaenge $Tenant @($Liste); $script:APAusVorgaenge[$Tenant] = @($Liste) } catch { Show-HUMessage "Vorgaenge speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}
function Add-APAusSchritt($V, [string]$Schritt, [string]$Ergebnis) {
    $V.Schritte = @(@($V.Schritte) + [pscustomobject]@{ Zeit = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Schritt = $Schritt; Ergebnis = $Ergebnis })
}
# offen = noch etwas zu tun bzw. zu beobachten; abgeschlossen: Intune-Eintrag weg, ohne Intune nur Autopilot weg, oder durch neuen Versuch ersetzt
function Test-APAusOffen($V) {
    if ("$($V.Intune)" -in 'geloescht', 'weg') { return $false }
    if ("$($V.Autopilot)" -eq 'wiederholt') { return $false }
    if ("$($V.Intune)" -eq 'kein Eintrag' -and "$($V.Autopilot)" -in 'entfernt', 'nicht (mehr) da') { return $false }
    return $true
}
# Vorgang blockiert ein neues Ausscheiden nur, wenn der Wipe schon unterwegs ist
function Test-APAusBlockiert($V) { return ((Test-APAusOffen $V) -and "$($V.Wipe)" -in 'gesendet', 'pending', 'active', 'done', 'unbekannt') }
function Update-APAusRechteBanner {
    $c = $script:Controls; $t = Get-APEinTenant
    $f = if ($t -and $script:APAusRechte.ContainsKey($t)) { @($script:APAusRechte[$t]) } else { @() }
    if (-not $f.Count) { $c.apAusRechte.Visibility = 'Collapsed'; return }
    $c.apTxtAusRechte.Text = "Fuer Ausscheiden/Zurueckziehen fehlen in $(Get-APTenantName $t): $($f -join ', ')$(if ($f -contains 'BitlockerKey.Read.All') { ' (BitLocker nur fuer Zurueckziehen)' })"
    $c.apAusRechte.Visibility = 'Visible'
}
function Start-APAusRechteCheck([switch]$Neu) {
    $t = Get-APEinTenant; if (-not $t) { return }
    [void](Start-HUJob -Name 'AP-AusRechte' -Quiet -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APNeu = [bool]$Neu } -Code {
            . $APCore
            Get-APFehlendeRechte $APTenant $Settings -Neu:$APNeu -Liste ($script:APRechteAusscheiden + $script:APRechteZurueck) -Art 'Aus'
        } -OnDone {
            param($res, $errs)
            foreach ($r in @($res | Where-Object { $_ -and $_.PSObject.Properties['Art'] -and $_.Art -eq 'Aus' })) { $script:APAusRechte["$($r.Tenant)"] = @($r.Fehlt) }
            Update-APAusRechteBanner
        })
}
function Grant-APAusRechte {
    $t = Get-APEinTenant
    $f = if ($t -and $script:APAusRechte.ContainsKey($t)) { @($script:APAusRechte[$t]) } else { @() }
    if (-not $f.Count) { return }
    try { [void](Show-HUTenantSetupDialog -TenantKey $t -Preselect $f) } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning; return }
    Write-APLog 'Rechte erteilt - sie stehen nach etwa 1 Minute im Token. Pruefe in 90 Sekunden erneut ...' '#AAAAAA'
    Invoke-HUDelayed 90 { Start-APAusRechteCheck -Neu }
}
function Update-APAusGrid {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    $ap = @($script:APRows | Where-Object { "$($_.Tenant)" -eq $t })
    $hash = @{}; try { foreach ($e in @(Get-APArchivDaten $t)) { $hash[(ConvertTo-APSerialKey $e.Seriennummer)] = 1 } } catch { }
    $offen = @{}; foreach ($v in @(Get-APAusVorgaenge $t | Where-Object { Test-APAusBlockiert $_ })) { $offen[(ConvertTo-APSerialKey $v.Seriennummer)] = 1 }
    $rows = @(foreach ($r in $ap) {
            $k = ConvertTo-APSerialKey $r.Seriennummer
            $p = Get-APAusPruefung $r ([bool]$hash.ContainsKey($k))
            $txt = $p.Text; $amp = $p.Ampel
            if ($offen.ContainsKey($k)) { $txt = 'Vorgang laeuft (unten in der Nachverfolgung)'; $amp = 'grau' }
            [pscustomobject]@{
                Seriennummer = "$($r.Seriennummer)"; Geraetename = "$($r.Geraetename)"; Benutzer = "$($r.Benutzer)"; GroupTag = "$($r.GroupTag)"; InIntune = "$($r.InIntune)"
                Eigentum = "$(if ($r.PSObject.Properties['Eigentum']) { $r.Eigentum })"; LetzterSync = "$($r.LetzterSync)"; HashDa = $(if ($hash.ContainsKey($k)) { 'ja' } else { 'nein' })
                Pruefung = $txt; Ampel = $(if ($amp -eq 'gut') { '' } elseif ($amp -eq 'fehler') { 'fehler' } elseif ($amp -eq 'grau') { 'grau' } else { 'warn' })
                Zeile = $r; Laeuft = $offen.ContainsKey($k)
            }
        })
    $f = "$($c.apTxtAusFilter.Text)"
    if ($f.Trim()) { $rows = @($rows | Where-Object { Test-APFilter $_ $f @('Seriennummer', 'Geraetename', 'Benutzer', 'GroupTag', 'Pruefung') }) }
    $c.apGridAus.ItemsSource = $null
    $c.apGridAus.ItemsSource = $rows
    Set-HUGridFit $c.apGridAus
    Reset-APGridBreiten 'apGridAus'
    $c.apTxtAusSumme.Text = $(if ($ap.Count) { "$($ap.Count) Autopilot-Geraete$(if ($rows.Count -ne $ap.Count) { ", angezeigt $($rows.Count)" }) - Geraete suchen, markieren, 'Ausscheiden ...'" } else { "Oben 'Laden' klicken." })
    Update-APAusVorgangGrid
}
function Update-APAusVorgangGrid {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    $alle = @(Get-APAusVorgaenge $t)
    $liste = if ([bool]$c.apChkAusErledigt.IsChecked) { $alle } else { @($alle | Where-Object { Test-APAusOffen $_ }) }
    $rows = @(foreach ($v in @($liste | Sort-Object Start -Descending)) {
            $amp = if (-not (Test-APAusOffen $v)) { 'gut' } elseif ("$($v.Hinweis)") { 'fehler' } elseif ("$($v.Wipe)" -eq 'done') { 'gut' } else { 'warn' }
            [pscustomobject]@{ Id = $v.Id; Art = $(if ($v.PSObject.Properties['Art'] -and $v.Art) { $v.Art } else { 'Ausscheiden' }); Seriennummer = $v.Seriennummer; Geraetename = $v.Geraetename; Benutzer = $v.Benutzer; Start = $v.Start; Autopilot = $v.Autopilot; Wipe = $(if ("$($v.Intune)" -eq 'weg' -and "$($v.Wipe)" -in 'gesendet', 'pending', 'active') { 'vermutlich ausgefuehrt (Intune-Eintrag weg)' } else { Get-APWipeText "$($v.Wipe)" }); WipeRoh = "$($v.Wipe)"; Intune = $v.Intune; Geprueft = $v.Geprueft; Hinweis = $v.Hinweis; Ampel = $amp }
        })
    $c.apGridAusVorgang.ItemsSource = $null
    $c.apGridAusVorgang.ItemsSource = $rows
    Set-HUGridFit $c.apGridAusVorgang
    Reset-APGridBreiten 'apGridAusVorgang'
}
function Get-APWipeText([string]$W) {
    switch ($W) { 'unbekannt' { 'unbekannt - in Intune pruefen' } 'gesendet' { 'gesendet' } 'pending' { 'wartet auf Geraet' } 'active' { 'laeuft' } 'done' { 'erledigt' } 'failed' { 'fehlgeschlagen' } 'canceled' { 'abgebrochen' } 'notSupported' { 'nicht unterstuetzt' } default { $W } }
}
function Save-APAusProtokoll([string]$Tenant, $V) {
    try {
        $h = Get-APNeuesterHash @(Get-APArchivDaten $Tenant) $V.Seriennummer
        $d = Get-APProtokollDir $Tenant
        if ("$($V.Protokoll)") { $alt = Split-Path -Parent "$($V.Protokoll)"; if (Test-Path -LiteralPath $alt) { $d = $alt } }
        $p = @(Write-APAusProtokoll $V (Get-APTenantName $Tenant) $h $d)
        $V.Protokoll = $p[0]
    } catch { Write-APLog "Protokoll $($V.Seriennummer): $($_.Exception.Message)" '#FFB74D' }
}
function Start-APAusUI {
    $c = $script:Controls
    $t = Get-APEinTenant
    if (-not $t) { Show-HUMessage 'Bitte oben einen Tenant waehlen.' -Icon Info; return }
    if (-not $script:APAusRechte.ContainsKey($t)) { Show-HUMessage "Bitte zuerst oben 'Laden' klicken (liest die Geraete und prueft die Rechte)." -Icon Info; return }
    $f = @(@($script:APAusRechte[$t]) | Where-Object { $_ -ne 'BitlockerKey.Read.All' })
    if ($f.Count) { Show-HUMessage "Fuer das Ausscheiden fehlen Rechte: $($f -join ', ') - oben 'Rechte erteilen ...'." -Icon Info; return }
    if ((Test-HUJobRunning 'AP-Aus') -or (Test-HUJobRunning 'AP-Zur')) { Show-HUMessage 'Ein Ausscheiden bzw. Zurueckziehen laeuft noch - bitte warten.' -Icon Info; return }
    $sel = @($c.apGridAus.SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Geraete markieren.' -Icon Info; return }
    $priv = @($sel | Where-Object { $_.Eigentum -eq 'privat' })
    $lauf = @($sel | Where-Object { $_.Laeuft })
    $ziel = @($sel | Where-Object { $_.Eigentum -ne 'privat' -and -not $_.Laeuft })
    if (-not $ziel.Count) { Show-HUMessage 'Keines der markierten Geraete kann ausgeschieden werden (privat oder Vorgang laeuft schon).' -Icon Info; return }
    if ($ziel.Count -gt 25) { Show-HUMessage "Hoechstens 25 Geraete je Durchgang (markiert: $($ziel.Count))." -Icon Info; return }
    $tn = Get-APTenantName $t
    $ohneHash = @($ziel | Where-Object { $_.HashDa -ne 'ja' }).Count
    $ohneIntune = @($ziel | Where-Object { $_.InIntune -ne 'ja' }).Count
    $warn = @(foreach ($z in @($ziel | Where-Object { $_.Pruefung })) { "  $($z.Seriennummer): $($z.Pruefung)" })
    $text = "AUSSCHEIDEN in $tn - $($ziel.Count) Geraet(e):`n`n" + (@($ziel | Select-Object -First 12 | ForEach-Object { "  $($_.Seriennummer)  $($_.Geraetename)  $($_.Benutzer)" }) -join "`n") + $(if ($ziel.Count -gt 12) { "`n  ... und $($ziel.Count - 12) weitere" } else { '' }) +
        "`n`nAblauf je Geraet: Benutzer im Autopilot-Eintrag aufheben -> Autopilot-Eintrag entfernen -> warten, bis er weg ist (hoechstens 15 Minuten, sonst KEIN Wipe) -> WIPE (alles wird geloescht, Geraet startet ins Setup)." +
        "`nDanach: Nachverfolgung unten; den Intune-Eintrag loeschst Du erst nach erledigtem Wipe. Im Hash-Archiv werden die Geraete als ausgeschieden gekennzeichnet, je Geraet entsteht ein Protokoll." +
        $(if ($ohneHash) { "`n`nACHTUNG: $ohneHash Geraet(e) ohne Hash im Archiv - nach dem Wipe ist er nur noch neu am Geraet auslesbar." } else { '' }) +
        $(if ($ohneIntune) { "`n$ohneIntune Geraet(e) ohne Intune-Eintrag - nur der Autopilot-Eintrag wird entfernt." } else { '' }) +
        $(if ($priv.Count -or $lauf.Count) { "`nUebersprungen: $($priv.Count) privat, $($lauf.Count) mit laufendem Vorgang." } else { '' }) +
        $(if ($warn.Count) { "`n`nHinweise:`n" + ($warn -join "`n") } else { '' }) +
        "`n`nDER WIPE LAESST SICH NICHT RUECKGAENGIG MACHEN."
    if (-not (Confirm-APTippen $text $tn $ziel.Count)) { return }
    $jetzt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $neu = @(foreach ($z in $ziel) {
            $r = $z.Zeile
            $v = [pscustomobject]@{
                Id = [guid]::NewGuid().ToString(); Tenant = $t; Seriennummer = "$($r.Seriennummer)"; Geraetename = "$($r.Geraetename)"; Benutzer = "$($r.Benutzer)"
                Hersteller = "$($r.Hersteller)"; Modell = "$($r.Modell)"; GroupTag = "$($r.GroupTag)"; IntuneId = "$($r.IntuneId)"; AutopilotId = "$($r.AutopilotId)"
                Start = $jetzt; Autopilot = 'laeuft'; Wipe = ''; Intune = $(if ("$($r.IntuneId)") { 'da' } else { 'kein Eintrag' }); Geprueft = ''; Hinweis = ''; Schritte = @(); Protokoll = ''; Art = 'Ausscheiden'; AadId = "$(if ($r.PSObject.Properties['AadId']) { $r.AadId })"
            }
            Add-APAusSchritt $v 'Ausscheiden gestartet' "Group Tag $($r.GroupTag), Profil $($r.Profil), Primaerbenutzer $($r.Benutzer)"
            $v
        })
    # fruehere Versuche derselben Geraete ohne Wipe (z. B. Autopilot-Eintrag war noch da) gelten als ersetzt
    $serNeu = @($neu | ForEach-Object { ConvertTo-APSerialKey $_.Seriennummer })
    $bisher = @(Get-APAusVorgaenge $t)
    foreach ($v in @($bisher | Where-Object { (Test-APAusOffen $_) -and $serNeu -contains (ConvertTo-APSerialKey $_.Seriennummer) })) { $v.Autopilot = 'wiederholt'; Add-APAusSchritt $v 'Neuer Versuch' "ersetzt durch Ausscheiden $jetzt" }
    Save-APAusVorgaenge $t (@($bisher) + $neu)
    $geraete = @($ziel | ForEach-Object { [pscustomobject]@{ Seriennummer = "$($_.Zeile.Seriennummer)"; AutopilotId = "$($_.Zeile.AutopilotId)"; IntuneId = "$($_.Zeile.IntuneId)"; ApBenutzer = "$(if ($_.Zeile.PSObject.Properties['ApBenutzer']) { $_.Zeile.ApBenutzer })" } })
    Start-APAusJob $t @($neu | ForEach-Object { $_.Id }) $geraete
}
# Job fuer neue Vorgaenge und fuer 'Erneut versuchen' (Ids = Vorgaenge, die das Ergebnis bekommen)
function Start-APAusJob([string]$t, [string[]]$Ids, [object[]]$geraete) {
    $c = $script:Controls
    $tn = Get-APTenantName $t
    $script:APAusJob = [pscustomobject]@{ Tenant = $t; Ids = @($Ids); Start = Get-Date }
    Update-APAusGrid
    Set-APDot $c['apDotAus'] $true
    Write-APLog "Ausscheiden: $($geraete.Count) Geraet(e) in $tn ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-Aus' -Output $c['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APGeraete = $geraete } -Code {
        . $APCore
        try { Start-APAusscheiden $APTenant $Settings $APGeraete } catch { Write-HULog -Message "Ausscheiden: $($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAus'] $false
        $j = $script:APAusJob; if (-not $j) { return }
        $t = $j.Tenant
        $alle = @(Get-APAusVorgaenge $t)
        $erg = @{}; foreach ($e in @($res | Where-Object { $_ -and $_.PSObject.Properties['APAusErg'] })) { $erg[(ConvertTo-APSerialKey $e.Seriennummer)] = $e }
        $raus = @()
        foreach ($v in @($alle | Where-Object { $j.Ids -contains $_.Id })) {
            $e = $erg[(ConvertTo-APSerialKey $v.Seriennummer)]
            if (-not $e) { $v.Autopilot = 'unbekannt'; $v.Hinweis = 'kein Ergebnis - siehe Protokoll'; Add-APAusSchritt $v 'Ausscheiden' 'kein Ergebnis'; continue }
            if ($e.Benutzer) { Add-APAusSchritt $v 'Benutzer im Autopilot-Eintrag aufheben' $e.Benutzer }
            $v.Autopilot = switch ($e.Autopilot) { 'weg' { 'entfernt' } 'keiner' { 'nicht (mehr) da' } 'entfernt' { 'noch da' } default { $e.Autopilot } }
            Add-APAusSchritt $v 'Autopilot-Eintrag entfernen' $v.Autopilot
            $v.Wipe = $e.Wipe
            if ($e.Wipe -eq 'gesendet') { $v | Add-Member -NotePropertyName WipeGesendet -NotePropertyValue (Get-Date).ToString('s') -Force; $v | Add-Member -NotePropertyName SyncAuto -NotePropertyValue $false -Force }
            Add-APAusSchritt $v 'Wipe' $e.Wipe
            $v.Hinweis = "$($e.Fehler)"
            if ($e.Autopilot -in 'weg', 'keiner') { $raus += $v.Seriennummer }
            Save-APAusProtokoll $t $v
        }
        Save-APAusVorgaenge $t $alle
        # im Hash-Archiv als ausgeschieden kennzeichnen (Hash bleibt)
        if ($raus.Count) {
            try { Save-APArchivDaten $t @(Set-APAusgeschieden @(Get-APArchivDaten $t) ([string[]]$raus) ((Get-Date).ToString('yyyy-MM-dd HH:mm'))) } catch { Write-APLog "Hash-Archiv: $($_.Exception.Message)" '#FFB74D' }
        }
        $w = @($erg.Values | Where-Object { $_.Wipe -eq 'gesendet' }).Count
        Write-APLog "Ausscheiden: $w Wipe gesendet, $(@($erg.Values).Count - $w) ohne Wipe (siehe Hinweise) - Protokolle unter 'Protokolle ...'" $(if ($w -eq @($erg.Values).Count) { '#81C784' } else { '#FFB74D' })
        Update-APAusGrid
        Update-APArchivGrid
        Set-APAusWecker 120
        Invoke-HUDelayed 30 { Start-APLaden @($script:APAusJob.Tenant) }
    }
    if (-not $ok) { Set-APDot $c['apDotAus'] $false }
}
# Erneut versuchen: Vorgaenge ohne Wipe (Autopilot-Eintrag war noch da, Fehler) - prueft die Liste neu und schickt dann den Wipe
function Start-APAusNochmal {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    if ((Test-HUJobRunning 'AP-Aus') -or (Test-HUJobRunning 'AP-Zur')) { Show-HUMessage 'Ein Ausscheiden bzw. Zurueckziehen laeuft noch - bitte warten.' -Icon Info; return }
    $sel = @($c.apGridAusVorgang.SelectedItems | Where-Object { $_ })
    $alle = @(Get-APAusVorgaenge $t)
    $kand = @($alle | Where-Object { $v = $_; @($sel | Where-Object { $_.Id -eq $v.Id }).Count -and (Test-APAusOffen $v) -and "$($v.Wipe)" -in '', 'nicht gesendet', 'Fehler' })
    # Zurueckziehen ohne Schluessel: eigener Weg (Rueckfrage 'auch ohne Schluessel')
    $zur = @($kand | Where-Object { $_.PSObject.Properties['Art'] -and $_.Art -eq 'Zurueckziehen' })
    if ($zur.Count) { Start-APZurNochmal $t $zur; return }
    $ziel = $kand
    if (-not $ziel.Count) { Show-HUMessage 'Bitte unten Vorgaenge ohne Wipe markieren (Wipe leer, "nicht gesendet" oder "Fehler").' -Icon Info; return }
    $tn = Get-APTenantName $t
    $text = "Erneut versuchen in $tn - $($ziel.Count) Geraet(e):`n`n" + (@($ziel | ForEach-Object { "  $($_.Seriennummer)  $($_.Geraetename)  (Autopilot: $($_.Autopilot))" }) -join "`n") + "`n`nIst der Autopilot-Eintrag inzwischen weg, wird sofort der WIPE gesendet - sonst wird er entfernt und bis zu 15 Minuten gewartet.`n`nDER WIPE LAESST SICH NICHT RUECKGAENGIG MACHEN."
    if (-not (Confirm-APTippen $text $tn $ziel.Count)) { return }
    foreach ($v in $ziel) { $v.Autopilot = 'laeuft'; $v.Hinweis = ''; Add-APAusSchritt $v 'Erneut versuchen' 'gestartet' }
    Save-APAusVorgaenge $t $alle
    $geraete = @($ziel | ForEach-Object { [pscustomobject]@{ Seriennummer = "$($_.Seriennummer)"; AutopilotId = "$($_.AutopilotId)"; IntuneId = "$($_.IntuneId)"; ApBenutzer = '' } })
    Start-APAusJob $t @($ziel | ForEach-Object { $_.Id }) $geraete
}
# Sync an Geraete senden (auto oder ueber den Knopf). Ergebnis nur ins Protokoll der App.
function Start-APAusSyncJob([string]$t, [string[]]$Ids, [switch]$Quiet) {
    if (Test-HUJobRunning 'AP-AusSync') { return }
    Write-APLog "Sync an $($Ids.Count) Geraet(e) nachschieben ..." '#AAAAAA'
    [void](Start-HUJob -Name 'AP-AusSync' -Quiet:$Quiet -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APIds = $Ids } -Code {
            . $APCore
            try { Send-APSync $APTenant $Settings $APIds } catch { Write-HULog -Message "Sync: $($_.Exception.Message)" -Level 'WARN' -Tenant $APTenant }
        } -OnDone { param($res, $errs) })
}
function Send-APAusSyncUI {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    $sel = @($c.apGridAusVorgang.SelectedItems | Where-Object { $_ })
    $alle = @(Get-APAusVorgaenge $t)
    $ziel = @($alle | Where-Object { $v = $_; @($sel | Where-Object { $_.Id -eq $v.Id }).Count -and "$($v.Intune)" -eq 'da' -and "$($v.IntuneId)" })
    if (-not $ziel.Count) { Show-HUMessage 'Bitte unten Vorgaenge mit Intune-Eintrag markieren.' -Icon Info; return }
    foreach ($v in $ziel) { Add-APAusSchritt $v 'Sync gesendet' 'von Hand' }
    Save-APAusVorgaenge $t $alle
    Start-APAusSyncJob $t ([string[]]@($ziel | ForEach-Object { $_.IntuneId }))
}
# ----------------------------------------------------------------------------------------------
# Liste reinziehen (Abgaenger): Seriennummern und/oder UPNs -> passende Geraete markieren
# ----------------------------------------------------------------------------------------------
function Import-APAusListe([string[]]$Pfade) {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { Show-HUMessage 'Bitte oben einen Tenant waehlen.' -Icon Info; return }
    if (-not @($script:APRows | Where-Object { "$($_.Tenant)" -eq $t }).Count) { Show-HUMessage "Bitte zuerst oben 'Laden' klicken." -Icon Info; return }
    $werte = @()
    foreach ($p in @($Pfade)) {
        try { $w = @(Read-APListeDatei $p); $werte += $w; Write-APLog "$([IO.Path]::GetFileName($p)): $($w.Count) Eintrag/Eintraege" '#CCCCCC' }
        catch { Write-APLog "$([IO.Path]::GetFileName($p)): $($_.Exception.Message)" '#FFB74D' }
    }
    if (-not $werte.Count) { Show-HUMessage 'In der Datei wurden keine Seriennummern oder UPNs gefunden (Spalte "Seriennummer"/"Serial Number" bzw. "UPN"/"Benutzer"/"Mail").' -Icon Info; return }
    $c.apTxtAusFilter.Text = ''
    Update-APAusGrid
    $rows = @($c.apGridAus.ItemsSource | Where-Object { $_ })
    $bySer = @{}; $byUpn = @{}
    foreach ($r in $rows) { $bySer[(ConvertTo-APSerialKey $r.Seriennummer)] = $r; if ("$($r.Benutzer)") { $u = "$($r.Benutzer)".ToLowerInvariant(); if (-not $byUpn.ContainsKey($u)) { $byUpn[$u] = @() }; $byUpn[$u] += $r } }
    $treffer = @{}; $ohne = @()
    foreach ($w in $werte) {
        $hit = @()
        if ($w.Seriennummer) { $k = ConvertTo-APSerialKey $w.Seriennummer; if ($bySer.ContainsKey($k)) { $hit += $bySer[$k] } }
        if (-not $hit.Count -and $w.Upn) { $u = "$($w.Upn)".ToLowerInvariant(); if ($byUpn.ContainsKey($u)) { $hit += @($byUpn[$u]) } }
        if ($hit.Count) { foreach ($h in $hit) { $treffer["$($h.Seriennummer)"] = $h } } else { $ohne += $(if ($w.Seriennummer) { $w.Seriennummer } else { $w.Upn }) }
    }
    $c.apGridAus.SelectedItems.Clear()
    foreach ($h in $treffer.Values) { [void]$c.apGridAus.SelectedItems.Add($h) }
    if ($treffer.Count) { try { $c.apGridAus.ScrollIntoView(@($treffer.Values)[0]) } catch { } }
    Write-APLog "Liste: $($werte.Count) Eintrag/Eintraege, $($treffer.Count) Geraet(e) markiert, $($ohne.Count) ohne Treffer in $(Get-APTenantName $t)" $(if ($ohne.Count) { '#FFB74D' } else { '#81C784' })
    foreach ($o in @($ohne | Select-Object -First 40)) { Write-APLog "  ohne Treffer: $o" '#FFB74D' }
    if ($ohne.Count -gt 40) { Write-APLog "  ... und $($ohne.Count - 40) weitere" '#FFB74D' }
}
function Select-APAusListe {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Listen (*.csv;*.xlsx;*.txt)|*.csv;*.xlsx;*.txt|Alle Dateien (*.*)|*.*'
    $dlg.Multiselect = $true; $dlg.Title = 'Abgaengerliste waehlen (Seriennummern oder UPNs)'
    if ($dlg.ShowDialog()) { Import-APAusListe @($dlg.FileNames) }
}

# ----------------------------------------------------------------------------------------------
# Zurueckziehen (Retire) - Geraet bleibt bei der Familie
# ----------------------------------------------------------------------------------------------
function Start-APZurUI {
    $c = $script:Controls
    $t = Get-APEinTenant
    if (-not $t) { Show-HUMessage 'Bitte oben einen Tenant waehlen.' -Icon Info; return }
    if (-not $script:APAusRechte.ContainsKey($t)) { Show-HUMessage "Bitte zuerst oben 'Laden' klicken (liest die Geraete und prueft die Rechte)." -Icon Info; return }
    $f = @(@($script:APAusRechte[$t]) | Where-Object { $_ -ne 'DeviceManagementManagedDevices.ReadWrite.All' })
    if ($f.Count) { Show-HUMessage "Fuer das Zurueckziehen fehlen Rechte: $($f -join ', ') - oben 'Rechte erteilen ...'." -Icon Info; return }
    if ((Test-HUJobRunning 'AP-Aus') -or (Test-HUJobRunning 'AP-Zur')) { Show-HUMessage 'Ein Ausscheiden bzw. Zurueckziehen laeuft noch - bitte warten.' -Icon Info; return }
    $sel = @($c.apGridAus.SelectedItems | Where-Object { $_ -and -not $_.Laeuft })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Geraete markieren (ohne laufenden Vorgang).' -Icon Info; return }
    if ($sel.Count -gt 25) { Show-HUMessage "Hoechstens 25 Geraete je Durchgang (markiert: $($sel.Count))." -Icon Info; return }
    $ohneIntune = @($sel | Where-Object { $_.InIntune -ne 'ja' }).Count
    if ($ohneIntune) { Show-HUMessage "$ohneIntune markierte(s) Geraet(e) sind nicht in Intune - Zurueckziehen geht nur mit Intune-Eintrag." -Icon Info; return }
    $tn = Get-APTenantName $t
    $text = "ZURUECKZIEHEN in $tn - $($sel.Count) Geraet(e) (Geraet bleibt bei der Familie):`n`n" + (@($sel | Select-Object -First 12 | ForEach-Object { "  $($_.Seriennummer)  $($_.Geraetename)  $($_.Benutzer)" }) -join "`n") + $(if ($sel.Count -gt 12) { "`n  ... und $($sel.Count - 12) weitere" } else { '' }) +
        "`n`nAblauf je Geraet: BitLocker-Wiederherstellungsschluessel lesen (ohne Schluessel KEIN Zurueckziehen) -> Autopilot-Eintrag entfernen -> Zurueckziehen. Die Daten bleiben auf dem Geraet, Schul-Apps und -Einstellungen werden entfernt." +
        "`n`nWICHTIG: Das Geraet bleibt im Schul-Entra angemeldet. Anmelden geht nur mit dem Schulkonto - wird es nach dem Austritt deaktiviert, kommt niemand mehr hinein (ausser mit einem lokalen Konto). Empfehlung an die Familie: Daten sichern, dann Windows neu einrichten." +
        "`n`nDanach oeffnet sich je Geraet die Uebergabe-Bestaetigung mit dem BitLocker-Schluessel zum DRUCKEN - sie wird nicht gespeichert."
    if (-not (Confirm-APTippen $text $tn $sel.Count)) { return }
    $jetzt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $neu = @(foreach ($z in $sel) {
            $r = $z.Zeile
            $v = [pscustomobject]@{
                Id = [guid]::NewGuid().ToString(); Tenant = $t; Seriennummer = "$($r.Seriennummer)"; Geraetename = "$($r.Geraetename)"; Benutzer = "$($r.Benutzer)"
                Hersteller = "$($r.Hersteller)"; Modell = "$($r.Modell)"; GroupTag = "$($r.GroupTag)"; IntuneId = "$($r.IntuneId)"; AutopilotId = "$($r.AutopilotId)"
                Start = $jetzt; Autopilot = 'laeuft'; Wipe = ''; Intune = 'da'; Geprueft = ''; Hinweis = ''; Schritte = @(); Protokoll = ''; Art = 'Zurueckziehen'; AadId = "$(if ($r.PSObject.Properties['AadId']) { $r.AadId })"
            }
            Add-APAusSchritt $v 'Zurueckziehen gestartet' "Group Tag $($r.GroupTag), Primaerbenutzer $($r.Benutzer)"
            $v
        })
    $bisher = @(Get-APAusVorgaenge $t)
    $serNeu = @($neu | ForEach-Object { ConvertTo-APSerialKey $_.Seriennummer })
    foreach ($v in @($bisher | Where-Object { (Test-APAusOffen $_) -and $serNeu -contains (ConvertTo-APSerialKey $_.Seriennummer) })) { $v.Autopilot = 'wiederholt'; Add-APAusSchritt $v 'Neuer Versuch' "ersetzt durch Zurueckziehen $jetzt" }
    Save-APAusVorgaenge $t (@($bisher) + $neu)
    Start-APZurJob $t $neu $false
}
function Start-APZurNochmal([string]$t, [object[]]$Vorgaenge) {
    $tn = Get-APTenantName $t
    if (-not (Confirm-HU "$($Vorgaenge.Count) Geraet(e) in $tn erneut zurueckziehen - AUCH OHNE BitLocker-Schluessel?`n`nOhne Schluessel kann die Familie das Geraet nicht entsperren, falls BitLocker beim Start einen Wiederherstellungsschluessel verlangt." 'Autopilot - Zurueckziehen' -Warning)) { return }
    $alle = @(Get-APAusVorgaenge $t)
    foreach ($v in @($alle | Where-Object { $x = $_; @($Vorgaenge | Where-Object { $_.Id -eq $x.Id }).Count })) { $v.Autopilot = 'laeuft'; $v.Hinweis = ''; Add-APAusSchritt $v 'Erneut versuchen' 'auch ohne BitLocker-Schluessel' }
    Save-APAusVorgaenge $t $alle
    Start-APZurJob $t @($alle | Where-Object { $x = $_; @($Vorgaenge | Where-Object { $_.Id -eq $x.Id }).Count }) $true
}
function Start-APZurJob([string]$t, [object[]]$Vorgaenge, [bool]$OhneSchluessel) {
    $c = $script:Controls
    $script:APAusJob = [pscustomobject]@{ Tenant = $t; Ids = @($Vorgaenge | ForEach-Object { $_.Id }); Start = Get-Date }
    $geraete = @($Vorgaenge | ForEach-Object { [pscustomobject]@{ Seriennummer = "$($_.Seriennummer)"; IntuneId = "$($_.IntuneId)"; AadId = "$($_.AadId)"; ApBenutzer = '' } })
    Update-APAusGrid
    Set-APDot $c['apDotAus'] $true
    Write-APLog "Zurueckziehen: $($geraete.Count) Geraet(e) in $(Get-APTenantName $t) ..." '#4FC3F7'
    $ok = Start-HUJob -Name 'AP-Zur' -Output $c['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APGeraete = $geraete; APOhne = $OhneSchluessel } -Code {
        . $APCore
        try { Start-APZurueckziehen $APTenant $Settings $APGeraete $true $APOhne } catch { Write-HULog -Message "Zurueckziehen: $($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAus'] $false
        $j = $script:APAusJob; if (-not $j) { return }
        $t = $j.Tenant; $tn = Get-APTenantName $t
        $alle = @(Get-APAusVorgaenge $t)
        $erg = @{}; foreach ($e in @($res | Where-Object { $_ -and $_.PSObject.Properties['APZurErg'] })) { $erg[(ConvertTo-APSerialKey $e.Seriennummer)] = $e }
        $raus = @(); $offen = 0
        foreach ($v in @($alle | Where-Object { $j.Ids -contains $_.Id })) {
            $e = $erg[(ConvertTo-APSerialKey $v.Seriennummer)]
            if (-not $e) { $v.Autopilot = 'unbekannt'; $v.Hinweis = 'kein Ergebnis - siehe Protokoll'; continue }
            $nk = @($e.Schluessel | Where-Object { $_.Schluessel }).Count
            Add-APAusSchritt $v 'BitLocker-Schluessel lesen' "$nk gefunden (nur auf der Uebergabe-Bestaetigung, nicht gespeichert)"
            $v.Autopilot = switch ($e.Autopilot) { 'entfernt' { 'entfernt' } 'keiner' { 'nicht (mehr) da' } '' { 'unveraendert' } default { $e.Autopilot } }
            if ($e.Autopilot) { Add-APAusSchritt $v 'Autopilot-Eintrag entfernen' $v.Autopilot }
            $v.Wipe = $e.Retire
            Add-APAusSchritt $v 'Zurueckziehen' $e.Retire
            $v.Hinweis = "$($e.Fehler)"
            if ($e.Retire -eq 'gesendet') {
                $raus += $v.Seriennummer
                # Uebergabe-Bestaetigung mit Schluessel: nur temporaer zum Drucken, nach 10 Minuten geloescht
                try {
                    $f = Join-Path ([IO.Path]::GetTempPath()) ("Uebergabe_$(("$($v.Seriennummer)" -replace '[^A-Za-z0-9_-]', ''))_$([guid]::NewGuid().ToString('N').Substring(0, 6)).html")
                    Write-APUebergabe $v $tn @($e.Schluessel) $f
                    Start-Process $f
                    $script:APUebergabeDateien += $f
                    $offen++
                } catch { Write-APLog "Uebergabe $($v.Seriennummer): $($_.Exception.Message)" '#FFB74D' }
            }
            Save-APAusProtokoll $t $v
        }
        Save-APAusVorgaenge $t $alle
        if ($raus.Count) { try { Save-APArchivDaten $t @(Set-APAusgeschieden @(Get-APArchivDaten $t) ([string[]]$raus) ((Get-Date).ToString('yyyy-MM-dd HH:mm'))) } catch { } }
        Write-APLog "Zurueckziehen: $($raus.Count) gesendet, $(@($erg.Values).Count - $raus.Count) nicht (siehe Hinweise)$(if ($offen) { " - $offen Uebergabe-Bestaetigung(en) im Browser geoeffnet: JETZT DRUCKEN und danach den Browser-Tab schliessen - die Dateien werden in 10 Minuten geloescht" })" $(if ($raus.Count -eq @($erg.Values).Count) { '#81C784' } else { '#FFB74D' })
        if ($offen) { Invoke-HUDelayed 600 { Remove-APUebergabeDateien } }
        Update-APAusGrid
        Update-APArchivGrid
        Set-APAusWecker 120
        Invoke-HUDelayed 30 { Start-APLaden @($script:APAusJob.Tenant) }
    }
    if (-not $ok) { Set-APDot $c['apDotAus'] $false }
}
function Remove-APUebergabeDateien {
    foreach ($f in @($script:APUebergabeDateien)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { } }
    $script:APUebergabeDateien = @()
}

# ----------------------------------------------------------------------------------------------
# Ausscheide-Pakete fuer die Eltern (ZIP je Geraet + Uebersicht + Mailtext)
# ----------------------------------------------------------------------------------------------
function New-APAusPaketeUI {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    $sel = @($c.apGridAusVorgang.SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage "Bitte unten die Vorgaenge markieren (auch abgeschlossene - Haken 'auch abgeschlossene')." -Icon Info; return }
    $alle = @(Get-APAusVorgaenge $t)
    $ziel = @($alle | Where-Object { $v = $_; @($sel | Where-Object { $_.Id -eq $v.Id }).Count })
    $tn = Get-APTenantName $t
    try {
        $daten = @(Get-APArchivDaten $t)
        $ord = Join-Path (Get-APProtokollDir $t) "Pakete_$((Get-Date).ToString('HHmm'))"
        New-Item -ItemType Directory -Path $ord -Force | Out-Null
        $liste = @(foreach ($v in $ziel) {
                $h = Get-APNeuesterHash $daten $v.Seriennummer
                $z = New-APAusPaket $v $tn $h $ord
                Add-APAusSchritt $v 'Ausscheide-Paket' ([IO.Path]::GetFileName($z))
                [pscustomobject]@{ Seriennummer = $v.Seriennummer; Benutzer = $v.Benutzer; Art = $(if ($v.PSObject.Properties['Art']) { $v.Art } else { 'Ausscheiden' }); Hash = $(if ($h) { 'ja' } else { 'nein' }); Paket = [IO.Path]::GetFileName($z); 'Mail Eltern' = '' }
            })
        $liste | Export-Csv -LiteralPath (Join-Path $ord 'Uebersicht.csv') -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        $mail = "Betreff: Schulgeraet Ihres Kindes - Unterlagen fuer eine neue Schule`r`n`r`nSehr geehrte Eltern,`r`n`r`nim Anhang finden Sie die Unterlagen zum Schulgeraet Ihres Kindes (Seriennummer <Seriennummer>).`r`nWechselt Ihr Kind an eine Schule, die Geraete mit Windows Autopilot verwaltet, geben Sie bitte die Datei <Seriennummer>_Autopilot-Import.csv an die IT der neuen Schule weiter.`r`n`r`nMit freundlichen Gruessen`r`n<Name>"
        [IO.File]::WriteAllText((Join-Path $ord 'Mailtext.txt'), $mail, (New-Object Text.UTF8Encoding($true)))
        Save-APAusVorgaenge $t $alle
        Write-APLog "$($liste.Count) Ausscheide-Paket(e) erstellt: $ord (ohne BitLocker-Schluessel)" '#81C784'
        Start-Process explorer.exe -ArgumentList "`"$ord`""
    } catch { Show-HUMessage "Pakete: $($_.Exception.Message)" -Icon Error }
}

function Set-APAusWecker([int]$Sekunden) {
    if ($script:APAusWecker) { return }
    $script:APAusWecker = $true
    Invoke-HUDelayed $Sekunden { $script:APAusWecker = $false; Start-APAusStatus -Auto }
}
function Start-APAusStatus([switch]$Auto) {
    $t = if ($Auto -and $script:APAusJob) { $script:APAusJob.Tenant } else { Get-APEinTenant }
    if (-not $t) { return }
    if (Test-HUJobRunning 'AP-AusStatus') { return }
    $offen = @(Get-APAusVorgaenge $t | Where-Object { (Test-APAusOffen $_) -and "$($_.IntuneId)" -and "$($_.Intune)" -eq 'da' })
    if (-not $offen.Count) { if (-not $Auto) { Show-HUMessage 'Keine offenen Vorgaenge mit Intune-Eintrag.' -Icon Info }; return }
    $script:APAusStatusTenant = $t
    Set-APDot $script:Controls['apDotAus'] $true
    $ok = Start-HUJob -Name 'AP-AusStatus' -Quiet:$Auto -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APIds = [string[]]@($offen | ForEach-Object { $_.IntuneId }) } -Code {
        . $APCore
        try { Get-APAusStatus $APTenant $Settings $APIds } catch { Write-HULog -Message "Status: $($_.Exception.Message)" -Level 'WARN' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAus'] $false
        $t = $script:APAusStatusTenant
        $alle = @(Get-APAusVorgaenge $t)
        $jetzt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $byId = @{}; foreach ($s in @($res | Where-Object { $_ -and $_.PSObject.Properties['APAusStat'] })) { $byId["$($s.IntuneId)"] = $s }
        $noch = 0
        foreach ($v in $alle) {
            $s = $byId["$($v.IntuneId)"]; if (-not $s) { continue }
            $v.Geprueft = $jetzt
            if (-not $s.Da) {
                if ($s.Status -eq 'Intune-Eintrag weg') {
                    # nach einem ausgefuehrten Wipe entfernt Intune den Eintrag selbst (Test 26.10.: wenige Minuten nach dem Aufwecken)
                    $v.Intune = 'weg'
                    # 065 B6: Verschwinden heisst 'vermutlich ausgefuehrt' - koennte auch ein Loeschen im Portal sein
                    Add-APAusSchritt $v 'Intune-Eintrag' $("nicht mehr vorhanden - Wipe bzw. Zurueckziehen vermutlich ausgefuehrt (Intune entfernt das Geraet danach selbst)" + $(if ("$($v.Wipe)" -ne 'done') { '; Ausfuehrung von Intune nicht bestaetigt' } else { '' }))
                    Save-APAusProtokoll $t $v
                }
                continue
            }
            if ($s.Wipe -and $s.Wipe -ne "$($v.Wipe)") { $v.Wipe = $s.Wipe; Add-APAusSchritt $v 'Wipe-Status' "$(Get-APWipeText $s.Wipe)$(if ($s.WipeZeit) { " ($($s.WipeZeit))" })"; Save-APAusProtokoll $t $v }
            if ("$($v.Wipe)" -notin 'done', 'failed', 'canceled', 'notSupported') { $noch++ }
        }
        # einmal automatisch einen Sync nachschieben, wenn der Wipe 3 Minuten nach dem Senden noch nicht angekommen ist
        $nachSync = @(foreach ($v in $alle) {
                if ("$($v.Intune)" -ne 'da' -or "$($v.Wipe)" -notin 'gesendet', 'pending') { continue }
                if (-not $v.PSObject.Properties['WipeGesendet'] -or ($v.PSObject.Properties['SyncAuto'] -and $v.SyncAuto)) { continue }
                $ws = [datetime]::MinValue
                if ([datetime]::TryParse("$($v.WipeGesendet)", [ref]$ws) -and ((Get-Date) - $ws).TotalMinutes -ge 3) { $v.SyncAuto = $true; Add-APAusSchritt $v 'Sync nachgeschoben' 'automatisch (Wipe nach 3 Minuten noch nicht angekommen)'; $v }
            })
        Save-APAusVorgaenge $t $alle
        Update-APAusVorgangGrid
        if ($nachSync.Count) { Start-APAusSyncJob $t ([string[]]@($nachSync | ForEach-Object { $_.IntuneId })) -Quiet }
        Write-APLog "Nachverfolgung $jetzt`: $noch Wipe(s) noch offen" '#AAAAAA'
        # automatisch alle 2 Minuten, hoechstens 2 Stunden nach dem Durchgang - danach 'Status pruefen' von Hand
        if ($noch -and $script:APAusJob -and $script:APAusJob.Tenant -eq $t -and ((Get-Date) - $script:APAusJob.Start).TotalMinutes -lt 120) { Set-APAusWecker 120 }
    }
    if (-not $ok) { Set-APDot $script:Controls['apDotAus'] $false }
}
function Remove-APAusIntuneUI {
    $c = $script:Controls
    $t = Get-APEinTenant; if (-not $t) { return }
    $sel = @($c.apGridAusVorgang.SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage 'Bitte unten die Vorgaenge markieren.' -Icon Info; return }
    $alle = @(Get-APAusVorgaenge $t)
    $ziel = @($alle | Where-Object { $v = $_; @($sel | Where-Object { $_.Id -eq $v.Id }).Count -and "$($v.Wipe)" -eq 'done' -and "$($v.Intune)" -eq 'da' })
    if (-not $ziel.Count) { Show-HUMessage "Bei keinem markierten Vorgang ist der Wipe erledigt (Status 'erledigt'). Erst 'Status pruefen'." -Icon Info; return }
    $tn = Get-APTenantName $t
    $text = "Intune-Eintrag von $($ziel.Count) Geraet(en) in $tn loeschen?`n`n" + (@($ziel | ForEach-Object { "  $($_.Seriennummer)  $($_.Geraetename)" }) -join "`n") + "`n`nDer Wipe ist bei allen erledigt. Das Entra-Geraeteobjekt bleibt (raeumt die Regel fuer veraltete Geraete auf)." + $(if ($ziel.Count -lt $sel.Count) { "`n`n$($sel.Count - $ziel.Count) markierte(r) Vorgang/Vorgaenge ohne erledigten Wipe werden uebersprungen." } else { '' })
    if (-not (Confirm-APTippen $text $tn $ziel.Count)) { return }
    $script:APAusIntuneTenant = $t
    Set-APDot $c['apDotAus'] $true
    $ok = Start-HUJob -Name 'AP-AusIntune' -Output $c['apLog'] -Vars @{ APCore = $script:APCore; APTenant = $t; APIds = [string[]]@($ziel | ForEach-Object { $_.IntuneId }) } -Code {
        . $APCore
        try { Remove-APIntuneGeraete $APTenant $Settings $APIds } catch { Write-HULog -Message "$($_.Exception.Message)" -Level 'ERROR' -Tenant $APTenant }
    } -OnDone {
        param($res, $errs)
        Set-APDot $script:Controls['apDotAus'] $false
        $t = $script:APAusIntuneTenant
        $alle = @(Get-APAusVorgaenge $t)
        foreach ($r in @($res | Where-Object { $_ -and $_.PSObject.Properties['APIntuneWeg'] })) {
            foreach ($v in @($alle | Where-Object { "$($_.IntuneId)" -eq "$($r.IntuneId)" })) {
                if ($r.Ok) { $v.Intune = 'geloescht'; $v.Hinweis = '' } else { $v.Hinweis = "Intune loeschen: $($r.Fehler)" }
                Add-APAusSchritt $v 'Intune-Eintrag loeschen' $(if ($r.Ok) { 'geloescht' } else { "Fehler: $($r.Fehler)" })
                Save-APAusProtokoll $t $v
            }
        }
        Save-APAusVorgaenge $t $alle
        Update-APAusGrid
    }
    if (-not $ok) { Set-APDot $c['apDotAus'] $false }
}
function Open-APAusOrdner {
    $t = Get-APEinTenant; if (-not $t) { return }
    try { $d = Split-Path -Parent (Get-APProtokollDir $t); Start-Process explorer.exe -ArgumentList "`"$d`"" } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning }
}

# ----------------------------------------------------------------------------------------------
# Rechte: beim Laden pruefen, was der HU-MultiTenant-App je Tenant fehlt, und Erteilen anbieten
# ----------------------------------------------------------------------------------------------
function Start-APRechteCheck([switch]$Neu) {
    $keys = @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ })
    if (-not $keys.Count) { return }
    [void](Start-HUJob -Name 'AP-Rechte' -Quiet -Output $script:Controls['apLog'] -Vars @{ APCore = $script:APCore; APKeys = $keys; APNeu = [bool]$Neu } -Code {
            . $APCore
            foreach ($k in $APKeys) { Get-APFehlendeRechte $k $Settings -Neu:$APNeu }
        } -OnDone {
            param($res, $errs)
            foreach ($r in @($res | Where-Object { $_ -and $_.PSObject.Properties['Fehlt'] })) { $script:APRechteStand["$($r.Tenant)"] = $r }
            Update-APRechteBanner
        })
}
function Update-APRechteBanner {
    $c = $script:Controls
    $fehlt = @($script:APRechteStand.Values | Where-Object { -not $_.Fehler -and @($_.Fehlt).Count } | Sort-Object Tenant)
    if (-not $fehlt.Count) { $c.apRechteBanner.Visibility = 'Collapsed'; return }
    $c.apTxtRechte.Text = "Fehlende Rechte fuer das Autopilot-Modul - " + (@($fehlt | ForEach-Object { "$(Get-APTenantName $_.Tenant): $(@($_.Fehlt) -join ', ')" }) -join '  |  ')
    $c.apRechteBanner.Visibility = 'Visible'
}
function Grant-APRechte {
    $fehlt = @($script:APRechteStand.Values | Where-Object { -not $_.Fehler -and @($_.Fehlt).Count } | Sort-Object Tenant)
    if (-not $fehlt.Count) { return }
    $liste = (@($fehlt | ForEach-Object { "  $(Get-APTenantName $_.Tenant): $(@($_.Fehlt) -join ', ')" }) -join "`n")
    if (-not (Confirm-HU "Fehlende Leserechte erteilen:`n`n$liste`n`nJe Tenant oeffnet sich das Fenster 'Rechte erteilen' mit den fehlenden Rechten vorausgewaehlt. Ein Global Administrator des Tenants meldet sich einmal im Browser an.`n`nWeiter?" 'Autopilot')) { return }
    foreach ($f in $fehlt) {
        try { [void](Show-HUTenantSetupDialog -TenantKey "$($f.Tenant)" -Preselect @($f.Fehlt)) } catch { Show-HUMessage "$(Get-APTenantName $f.Tenant): $($_.Exception.Message)" -Icon Warning }
    }
    Write-APLog 'Rechte erteilt - sie stehen nach etwa 1 Minute im Token. Pruefe in 90 Sekunden erneut ...' '#AAAAAA'
    Invoke-HUDelayed 90 { Start-APRechteCheck -Neu }
}

# ----------------------------------------------------------------------------------------------
# Start
# ----------------------------------------------------------------------------------------------
function Get-APVersionText {
    $v = ''
    try { $v = "$((Get-Content -LiteralPath (Join-Path $script:APDir 'addon.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)" } catch { }
    if (-not $v) { return '' }
    return "v$v"
}
# Kopf je Reiter: Checkboxen (mehrere Tenants) oder Dropdown (ein Tenant) - nie beides
function Get-APReiter { $i = $script:Controls['apTabs'].SelectedItem; if ($i) { return "$($i.Header)" } return '' }
function Test-APEinTenantReiter { return ((Get-APReiter) -in 'Hash-Archiv', 'Aufnehmen', 'Ausscheiden') }
function Update-APKopf {
    $c = $script:Controls
    $ein = Test-APEinTenantReiter
    $c.apTenants.Visibility = $(if ($ein) { 'Collapsed' } else { 'Visible' })
    $c.apEinTenant.Visibility = $(if ($ein) { 'Visible' } else { 'Collapsed' })
    if ((Get-APReiter) -eq 'Aufnehmen') { Update-APAufRechteBanner; Update-APAufGrid }
    elseif ((Get-APReiter) -eq 'Hash-Archiv') { Update-APArchivGrid }
    elseif ((Get-APReiter) -eq 'Ausscheiden') { Update-APAusRechteBanner; Update-APAusGrid }
}
function Invoke-APLadenKnopf {
    $r = Get-APReiter
    if (-not (Test-APEinTenantReiter)) { Start-APLaden; return }
    $t = Get-APEinTenant
    if (-not $t) { Show-HUMessage 'Bitte oben einen Tenant waehlen.' -Icon Info; return }
    if ($r -eq 'Aufnehmen') { Start-APAufLaden }
    elseif ($r -eq 'Ausscheiden') { Start-APLaden @($t); Start-APAusRechteCheck }
    else { Start-APLaden @($t) }
}
# Aufbewahrung: beim Start einmal fragen, ob Protokolle/Pakete aelter als 6 Monate geloescht werden sollen (nie automatisch)
function Test-APAufbewahrung {
    $alt = @()
    try { $alt = @(Get-APAlteProtokolle 6) } catch { return }
    if (-not $alt.Count) { return }
    $n = ($alt | Measure-Object Dateien -Sum).Sum
    $liste = (@($alt | Sort-Object Datum | Select-Object -First 10 | ForEach-Object { "  $(Get-APTenantName $_.Tenant): $($_.Datum) ($($_.Dateien) Datei(en))" }) -join "`n") + $(if ($alt.Count -gt 10) { "`n  ... und $($alt.Count - 10) weitere" } else { '' })
    if (-not (Confirm-HU "Autopilot: $($alt.Count) Ordner mit Ausscheidungsprotokollen und Eltern-Paketen sind aelter als 6 Monate ($n Datei(en), personenbezogen):`n`n$liste`n`nJetzt loeschen? Abgeschlossene Vorgaenge in der Nachverfolgung, die aelter als 6 Monate sind, werden ebenfalls entfernt. Das Hash-Archiv bleibt unveraendert.`n`nNein = beim naechsten Start wieder fragen." 'Autopilot - Aufbewahrung' -Warning)) { return }
    $weg = 0
    foreach ($a in $alt) { try { Remove-Item -LiteralPath $a.Pfad -Recurse -Force -ErrorAction Stop; $weg++ } catch { Write-APLog "Loeschen $($a.Pfad): $($_.Exception.Message)" '#FFB74D' } }
    foreach ($t in @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ })) {
        $v = @(Get-APAusVorgaenge $t); if (-not $v.Count) { continue }
        $b = @(Select-APVorgaengeBehalten $v 6)
        if ($b.Count -ne $v.Count) { Save-APAusVorgaenge $t $b }
    }
    Write-APLog "Aufbewahrung: $weg Protokoll-Ordner aelter als 6 Monate geloescht" '#AAAAAA'
}

function Initialize-HUAddonAutopilot {
    $c = $script:Controls
    $c.apTxtVersion.Text = Get-APVersionText
    Update-APTenantChecks
    Update-APGrid
    $c.apBtnLaden.Add_Click({ Invoke-APLadenKnopf })
    $c.apBtnRechte.Add_Click({ Grant-APRechte })
    $c.apBtnLogClear.Add_Click({ $script:Controls['apLog'].Document.Blocks.Clear() })
    try { Add-HUOutputMenu $c['apLog'] { $script:Controls['apLog'].Document.Blocks.Clear() } } catch { }
    $c.apChkNurProbleme.Add_Click({ Update-APGrid })
    $c.apChkOhneIntune.Add_Click({ Update-APGrid })
    $c.apTxtFilter.Add_TextChanged({ Update-APGrid })
    $c.apGrid.Add_Sorting({ Reset-APGridBreiten 'apGrid' })
    $c.apGrid.Add_MouseDoubleClick({ Show-APDetail $script:Controls['apGrid'].SelectedItem })
    $c.apBtnClear.Add_Click({
            $sel = @(Get-APTenants)
            $script:APRows = @($script:APRows | Where-Object { $sel -notcontains "$($_.Tenant)" })
            Update-APGrid
        })
    $c.apBtnTag.Add_Click({ Start-APTagAendern })
    $c.apBtnTagUndo.Add_Click({ Undo-APTagAenderung })
    $c.apBtnTable.Add_Click({
            $r = @($script:Controls['apGrid'].ItemsSource | Where-Object { $_ })
            if (-not $r.Count) { Show-HUMessage 'Noch keine Geraete - zuerst Laden.' -Icon Info; return }
            # Inventar mit Benutzer (UPN), ohne Hash (Udo 26.10.: UPN immer mit)
            Show-HUQSTable -Title 'Autopilot - Geraete' -FilePrefix 'Autopilot-Inventar' -Objects @($r | Select-Object @{ n = 'Tenant'; e = { $_.TenantName } }, Status, Seriennummer, Hersteller, Modell, @{ n = 'Group Tag'; e = { $_.GroupTag } }, Profil, Registrierung, @{ n = 'In Intune'; e = { $_.InIntune } }, @{ n = 'Geraetename'; e = { $_.Geraetename } }, @{ n = 'Benutzer (UPN)'; e = { $_.Benutzer } }, @{ n = 'Eingerichtet am'; e = { $_.EingerichtetAm } }, @{ n = 'Letzter Kontakt'; e = { $_.LetzterKontakt } }, @{ n = 'Letzter Sync'; e = { $_.LetzterSync } }, Hinweis)
        })
    # Hash-Archiv
    Update-APArchivTenants
    $c.apCmbTenant.Add_SelectionChanged({
            $t = Get-APEinTenant
            if ($t) { Set-HUStateValue 'apTenant' $t; try { Save-HUUIState } catch { } }
            Update-APArchivGrid; Update-APAufRechteBanner; Update-APAufTag; Update-APAufGrid; Update-APAusRechteBanner; Update-APAusGrid
        })
    $c.apChkArchivFehlt.Add_Click({ Update-APArchivGrid })
    $c.apChkArchivNicht.Add_Click({ Update-APArchivGrid })
    $c.apTxtArchivFilter.Add_TextChanged({ Update-APArchivGrid })
    $c.apGridArchiv.Add_Sorting({ Reset-APGridBreiten 'apGridArchiv' })
    $c.apBtnArchivDatei.Add_Click({ Select-APArchivDateien })
    $c.apBtnArchivAbholen.Add_Click({ Start-APArchivAbholen })
    $c.apBtnArchivWartung.Add_Click({ Start-APArchivWartung })
    $c.apBtnArchivExport.Add_Click({ Export-APArchiv })
    $c.apBtnArchivEntfernen.Add_Click({ Remove-APArchivEintraege })
    $c.apBtnArchivAus.Add_Click({ Set-APArchivAusgeschieden })
    $c.apBtnArchivAusWeg.Add_Click({ Set-APArchivAusgeschieden -Aufheben })
    $c.apDropArchiv.Add_DragOver({ param($s, $e) $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }; $e.Handled = $true })
    $c.apDropArchiv.Add_Drop({
            param($s, $e)
            $f = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
            if ($f.Count) { try { Import-APArchivDateien ([string[]]$f) } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning } }
        })
    Update-APArchivGrid
    # Aufnehmen
    $c.apBtnAufRechte.Add_Click({ Grant-APAufRechte })
    $c.apChkAufAlle.Add_Click({ Update-APAufGrid })
    $c.apTxtAufFilter.Add_TextChanged({ Update-APAufGrid })
    $c.apBtnAufAlleNeu.Add_Click({ Select-APAufAlleNeuen })
    $c.apGridAuf.Add_Sorting({ Reset-APGridBreiten 'apGridAuf' })
    # Tag: eintippen oder aus der Liste waehlen (die Liste traegt ins Feld ein)
    $c.apCmbAufTag.Add_SelectionChanged({ $v = "$($script:Controls['apCmbAufTag'].SelectedItem)"; if ($v) { $script:Controls['apTxtAufTagEingabe'].Text = $v } })
    $c.apTxtAufTagEingabe.Add_TextChanged({
            # eingetippter Tag passt nicht zur Liste: Auswahl rechts leeren (sonst steht dort ein anderer Tag)
            $cb = $script:Controls['apCmbAufTag']
            if ($cb.SelectedIndex -ge 0 -and "$($cb.SelectedItem)" -ne "$($script:Controls['apTxtAufTagEingabe'].Text)".Trim()) { $cb.SelectedIndex = -1 }
            Update-APAufTag
        })
    $c.apBtnAufGruppeNeu.Add_Click({ New-APAufGruppeUI })
    $c.apBtnAufGruppeWeg.Add_Click({ Remove-APAufGruppeUI })
    $c.apBtnAufImport.Add_Click({ Start-APAufImportUI })
    $c.apBtnAufStatus.Add_Click({ Start-APAufStatus })
    $c.apChkAufAuto.Add_Click({ if ([bool]$script:Controls['apChkAufAuto'].IsChecked) { Start-APAufStatus -Auto } })
    # Ausscheiden
    $c.apTxtAusFilter.Add_TextChanged({ Update-APAusGrid })
    $c.apGridAus.Add_Sorting({ Reset-APGridBreiten 'apGridAus' })
    $c.apGridAusVorgang.Add_Sorting({ Reset-APGridBreiten 'apGridAusVorgang' })
    $c.apChkAusErledigt.Add_Click({ Update-APAusVorgangGrid })
    $c.apBtnAusStart.Add_Click({ Start-APAusUI })
    $c.apBtnAusZur.Add_Click({ Start-APZurUI })
    $c.apBtnAusListe.Add_Click({ Select-APAusListe })
    $c.apBtnAusPaket.Add_Click({ New-APAusPaketeUI })
    $c.apGridAus.Add_DragOver({ param($s, $e) $e.Effects = if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }; $e.Handled = $true })
    $c.apGridAus.Add_Drop({ param($s, $e) $f = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop)); if ($f.Count) { try { Import-APAusListe ([string[]]$f) } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning } } })
    $c.apBtnAusStatus.Add_Click({ Start-APAusStatus })
    $c.apBtnAusNochmal.Add_Click({ Start-APAusNochmal })
    $c.apBtnAusSync.Add_Click({ Send-APAusSyncUI })
    $c.apBtnAusIntune.Add_Click({ Remove-APAusIntuneUI })
    $c.apBtnAusOrdner.Add_Click({ Open-APAusOrdner })
    $c.apBtnAusRechte.Add_Click({ Grant-APAusRechte })
    # beim Wechsel auf 'Aufnehmen' neu aufbauen (Archiv kann sich geaendert haben) - nur Ereignisse des Reiters selbst
    $c.apTabs.Add_SelectionChanged({ param($s, $e) if ($e.OriginalSource -eq $s) { Update-APKopf } })
    Update-APKopf
    Update-APAufGrid
    # liegengebliebene Uebergabe-Bestaetigungen (BitLocker-Schluessel) aus dem Temp-Ordner entfernen
    try { Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'Uebergabe_*.html' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch { }
    # Aufbewahrung (6 Monate) kurz nach dem Start pruefen
    Invoke-HUDelayed 8 { Test-APAufbewahrung }
    # beim Laden: fehlende Rechte je Tenant pruefen (im Hintergrund)
    Start-APRechteCheck
}
