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
$script:WuGroups = @{}       # Key (Art|name) -> zusammengefasster Eintrag (Ringe und Profile)
$script:WuSelKey = ''        # markierter Eintrag in Ringe und Profile
$script:WuChoices = $null    # Zielversionen und beschleunigbare Updates aus dem Katalog
$script:WuSetCtl = @{}       # Eingabefelder im Bereich Einstellungen

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
    [void](Start-HUJob -Name 'WuLoad' -Quiet -Output $script:Controls['rtbRem'] -Vars @{ Need = $need; Cat = $cat; NeedChoices = (-not $script:WuChoices) } -Code {
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
            # Zielversionen und beschleunigbare Updates (fuer + Feature-Update / + Expedite) - einmal je Sitzung
            if ($NeedChoices -and @($Need).Count) { try { [pscustomobject]@{ WuChoices = (Get-HUWuCatalogChoices -TenantKey @($Need)[0] -Settings $Settings) } } catch { Write-HULog -Message "Katalog-Auswahl: $($_.Exception.Message)" -Level 'WARN' } }
        } -OnDone {
            param($Result, $Errors)
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] -and $_.PSObject.Properties['Devices'] })) { $script:WuRaw["$($r.Tenant)"] = @{ Inv = $r; Time = Get-Date } }
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['WuChoices'] })) { $script:WuChoices = $r.WuChoices }
            Update-HUWuView
            if (@(Get-HUWuTenants | Where-Object { -not $script:WuRaw[$_] }).Count) { Start-HUWuLoad }
        })
}

function Get-HUWuInventories { return @(foreach ($k in @(Get-HUWuTenants)) { if ($script:WuRaw[$k]) { $script:WuRaw[$k].Inv } }) }

function Get-HUWuTenantNames {
    $n = @{}; foreach ($t in @($script:Settings.tenants)) { $n["$($t.key)"] = $(if ("$($t.displayName)") { "$($t.displayName)" } else { "$($t.key)" }) }
    return $n
}

# Vorfilter (Haken oben): Patchstand, Sync, Besitz, Windows 10
function Test-HUWuDeviceFilter($D) {
    $c = $script:Controls
    $ps = switch ("$($D.Patchstand)") { 'veraltet' { $c['chkWuOld'] } 'zurueck' { $c['chkWuBehind'] } 'aktuell' { $c['chkWuCurrent'] } default { $c['chkWuUnknown'] } }
    if (-not $ps.IsChecked) { return $false }
    if ($c['chkWuStale'].IsChecked -and -not $D.OhneSync) { return $false }
    if ($c['chkWuActive'].IsChecked -and $D.OhneSync) { return $false }
    if ($c['chkWuCompany'].IsChecked -and "$($D.Besitz)" -ne 'company') { return $false }
    if ($c['chkWuWin10'].IsChecked -and "$($D.Version)" -notlike 'Windows 10*') { return $false }
    return $true
}

# Anzeige des Patchstands (intern: aktuell | zurueck | veraltet | unbekannt)
function Get-HUWuPatchText([string]$P) {
    switch ($P) { 'zurueck' { return '1 Update fehlt' } 'veraltet' { return 'veraltet (2+ fehlen)' } default { return $P } }
}

# Zeilen -> DataTable; Spalten mit nur ganzen Zahlen werden Int32 (richtige Sortierung). -1 bei Fehlende Updates = unbekannt
function ConvertTo-HUWuDataTable([object[]]$Rows) {
    $dt = New-Object System.Data.DataTable
    $rows = @($Rows | Where-Object { $_ })
    if (-not $rows.Count) { return , $dt }   # Komma: sonst rollt PowerShell die Tabelle in Zeilen aus
    $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($n in $cols) {
        $num = $true
        foreach ($r in $rows) { $v = $r.$n; if ($null -ne $v -and "$v" -ne '' -and -not ($v -is [int] -or $v -is [long] -or $v -is [double])) { $num = $false; break } }
        [void]$dt.Columns.Add($n, $(if ($num) { [int] } else { [string] }))
    }
    foreach ($r in $rows) {
        $dr = $dt.NewRow()
        foreach ($n in $cols) { $v = $r.$n; $dr[$n] = $(if ($dt.Columns[$n].DataType -eq [int]) { if ($null -eq $v -or "$v" -eq '') { [DBNull]::Value } else { [int]$v } } else { "$v" }) }
        [void]$dt.Rows.Add($dr)
    }
    return , $dt
}

# Wert einer Zeile (DataRowView) lesen
function Get-HUWuCell($Item, [string]$Name) {
    if ($Item -is [System.Data.DataRowView]) { if ($Item.Row.Table.Columns.Contains($Name)) { return "$($Item[$Name])" }; return $null }
    if ($Item -and $Item.PSObject.Properties[$Name]) { return "$($Item.$Name)" }
    return $null
}

function Test-HUWuDriverFilter($D) {
    $c = $script:Controls
    $cb = switch ("$($D.Status)") { 'pruefen' { $c['chkDrvReview'] } 'freigegeben' { $c['chkDrvApproved'] } 'ausgesetzt' { $c['chkDrvSuspended'] } 'abgelehnt' { $c['chkDrvDeclined'] } default { $c['chkDrvReview'] } }
    if (-not $cb.IsChecked) { return $false }
    if ($c['chkDrvRecommended'].IsChecked -and "$($D.Kategorie)" -ne 'empfohlen') { return $false }
    if ($c['chkDrvApplicable'].IsChecked -and [int]$D.Geraete -le 0) { return $false }
    if ($c['chkDrvRecent'].IsChecked -and "$($D.Datum)" -and "$($D.Datum)" -lt (Get-Date).AddMonths(-12).ToString('yyyy-MM-dd')) { return $false }
    return $true
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
            $drv = @(@($i.PSObject.Properties['Drivers'] | ForEach-Object { $_.Value }) | Where-Object { $_ -and $_.Status -eq 'pruefen' -and [int]$_.Geraete -gt 0 -and "$($_.Datum)" -ge (Get-Date).AddMonths(-12).ToString('yyyy-MM-dd') }).Count
            [pscustomobject]@{ Tenant = $i.Tenant; Title = "$($names[$i.Tenant])"; Color = $col
                Sub = "$($s.Text)$(if ($s.Haupt) { "; $($s.Haupt)" })$(if ($drv) { "; $drv Treiber (12 Monate) zu pruefen" })$(if (@($i.Errors).Count) { " | nicht alles lesbar" })"
                Tip = (@("$($s.Text)") + @($i.Errors) + $warn) -join "`n" }
        })
    $loading = Test-HUJobRunning 'WuLoad'
    Set-HUWuRunDot $loading
    $missing = @(Get-HUWuTenants | Where-Object { -not $script:WuRaw[$_] }).Count
    $c['lblWuState'].Text = $(if (-not @(Get-HUWuTenants).Count) { 'Oben Tenants anhaken.' } elseif ($loading -or $missing) { "Lese ... ($missing Tenant(s) offen)" } else {
            $t = @($script:WuRaw.Values | ForEach-Object { $_.Time } | Sort-Object)[0]; "Stand $(if ($t) { $t.ToString('HH:mm') }) - neu laden mit $([char]0x21BB)" })
    $f = "$($c['txtWuFilter'].Text)".Trim()
    $c['pnlWuChecks'].Visibility = $(if ($script:WuView -in 'matrix', 'devices') { 'Visible' } else { 'Collapsed' })
    $c['pnlWuDrvChecks'].Visibility = $(if ($script:WuView -eq 'drivers') { 'Visible' } else { 'Collapsed' })
    $c['pnlWuDrvActions'].Visibility = $c['pnlWuDrvChecks'].Visibility
    foreach ($b in 'btnWuNewRing', 'btnWuNewFeat', 'btnWuNewDrv', 'btnWuNewExp', 'btnWuImport') { $c[$b].Visibility = $(if ($script:WuView -in 'policies', 'matrix') { 'Visible' } else { 'Collapsed' }) }
    $c['btnWuBackup'].Visibility = $(if ($script:WuView -eq 'policies') { 'Visible' } else { 'Collapsed' })
    $c['pnlWuNew'].Visibility = $(if ($script:WuView -in 'policies', 'matrix') { 'Visible' } else { 'Collapsed' })
    if (-not "$($c['txtDrvDate'].Text)") { $c['txtDrvDate'].Text = (Get-Date).ToString('dd.MM.yyyy') }
    $rows = @()
    switch ($script:WuView) {
        'matrix' {
            $c['lblWuTitle'].Text = "$([char]0xDC)bersicht: Windows-Versionen je Tenant"
            $c['lblWuHint'].Text = "Je Zelle: Geraete (davon mit neuestem Sicherheitsupdate). Farbe: gruen ab 80 % aktuell, gelb ab 50 %, orange darunter, rot = Version ohne Support (kein Sicherheitspatch seit ueber 2,5 Monaten). Doppelklick zeigt die Geraete dieser Version."
            # Uebersicht mit denselben Vorfiltern wie die Geraeteliste
            $fi = @(foreach ($i in $invs) { [pscustomobject]@{ Tenant = $i.Tenant; Catalog = $i.Catalog; Devices = @(@($i.Devices) | Where-Object { Test-HUWuDeviceFilter $_ }); Policies = $i.Policies; Errors = $i.Errors } })
            $rows = @(Get-HUWuMatrix $fi $names)
        }
        'policies' {
            $c['lblWuTitle'].Text = 'Update-Ringe und Profile'
            $c['lblWuHint'].Text = 'Gleiche Ringe/Profile aller angehakten Tenants in einer Zeile (wie Wartung > In Intune). Eintrag markieren: unten Zuweisungen und Einstellungen. Neu anlegen, Sichern und Importieren: Knoepfe oben.'
            $script:WuGroups = @{}
            $rows = @(foreach ($g in @(Get-HUWuPolicyGroups $invs $names)) {
                    $script:WuGroups[$g.Key] = $g
                    [pscustomobject][ordered]@{ Art = $g.Art; Name = $g.Name; Tenants = $g.Tenants; Einstellung = $g.Einstellung; Pause = $g.Pause; Zuweisung = $g.Zuweisung; Hinweis = $g.Hinweis; Key = $g.Key }
                })
        }
        'devices' {
            $c['lblWuTitle'].Text = "Ger$([char]0xE4)te$(if ($script:WuDevFilter) { ": $($script:WuDevFilter)" })"
            $c['lblWuHint'].Text = "Patchstand: aktuell = neuestes Sicherheitsupdate des Builds, 1 Update fehlt = etwa einen Monat zurueck, veraltet = zwei oder mehr fehlen. Fehlende Updates -1 = unbekannt. Spaltenkopf anklicken zum Sortieren. $(if ($script:WuDevFilter) { 'Ansicht links neu waehlen hebt die Einschraenkung auf.' })"
            $rows = @($invs | ForEach-Object { @($_.Devices) } | Where-Object { (-not $script:WuDevFilter -or $_.Version -eq $script:WuDevFilter) -and (Test-HUWuDeviceFilter $_) } |
                    ForEach-Object { [pscustomobject][ordered]@{ Tenant = $names[$_.Tenant]; Geraet = $_.Geraet; Benutzer = $_.Benutzer; Version = $_.Version; Build = $_.Build; Patchstand = (Get-HUWuPatchText $_.Patchstand); 'Fehlende Updates' = $(if ($null -ne $_.Fehlend) { [int]$_.Fehlend } else { -1 }); 'Letzter Sync' = $_.LetzterSync; Beitritt = $(if ($_.PSObject.Properties['Beitritt']) { $_.Beitritt } else { '' }); Besitz = $_.Besitz; Modell = $_.Modell } } |
                    Sort-Object @{ e = { $_.'Fehlende Updates' }; Descending = $true }, Tenant, Geraet)
        }
    }
    if ($script:WuView -eq 'drivers') {
        $c['lblWuTitle'].Text = 'Treiber-Updates'
        $c['lblWuHint'].Text = 'Anstehende Treiber aller Treiber-Richtlinien; gleicher Treiber in mehreren Tenants = eine Zeile, je Tenant betroffene Geraete (Status). Doppelklick zeigt die Einzelheiten je Richtlinie.'
        $rows = @(Get-HUWuDriverMatrix $invs $names { param($d) Test-HUWuDriverFilter $d })
        if (-not $rows.Count) {
            $np = @($invs | ForEach-Object { @($_.Policies) } | Where-Object { $_.Art -eq 'Treiber-Update' }).Count
            $c['lblWuHint'].Text = $(if (-not $np) { 'In den angehakten Tenants gibt es keine Treiber-Richtlinie (Intune: Geraete > Windows-Updates > Treiber-Updates).' } else { "Keine Treiber mit diesem Filter. $np Treiber-Richtlinie(n) vorhanden - Hinweise dazu unter 'Ringe und Profile'." })
        }
    }
    if ($f) { $rows = @($rows | Where-Object { $o = $_; @($o.PSObject.Properties | Where-Object { "$($_.Value)" -like "*$f*" }).Count }) }
    $script:WuRows = $rows
    # DataTable statt PowerShell-Objekte: WPF kann dann per Klick auf den Spaltenkopf sortieren (Zahlen als Zahlen)
    $c['gridWu'].ItemsSource = (ConvertTo-HUWuDataTable $rows).DefaultView
    # markierten Eintrag nach dem Neuaufbau wieder markieren (Ringe und Profile)
    if ($script:WuView -eq 'policies' -and $script:WuSelKey) {
        foreach ($rv in @($c['gridWu'].ItemsSource)) { if ("$($rv['Key'])" -eq $script:WuSelKey) { $c['gridWu'].SelectedItem = $rv; break } }
    }
    Show-HUWuDetail
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

# Einzelheiten eines Treibers: je Tenant und Richtlinie Status, Geraete, Freigabe ab
function Show-HUWuDriverDetail($Row) {
    $names = Get-HUWuTenantNames
    $list = @(Get-HUWuInventories | ForEach-Object { @($_.Drivers) } | Where-Object { $_.Treiber -eq $Row.Treiber -and $_.Version -eq $Row.Version })
    $txt = "$($Row.Treiber)`nVersion $($Row.Version) - $($Row.Hersteller), $($Row.Klasse), $($Row.Kategorie)$(if ($Row.Datum) { ", vom $($Row.Datum)" })`n`n" +
        (@($list | ForEach-Object { "  $($names[$_.Tenant]) / $($_.Profil): $($_.Status), $($_.Geraete) Geraet(e)$(if ($_.Ab) { ", ab $($_.Ab)" })" }) -join "`n")
    Show-HUMessage $txt -Title 'Treiber' -Icon Info
}

function Export-HUWuTable {
    $rows = @($script:WuRows)
    if (-not $rows.Count) { Show-HUMessage 'Keine Zeilen zum Speichern.' -Icon Info; return }
    $rows = @($rows | Select-Object -Property * -ExcludeProperty Key, AsgList, Raw, Items)   # interne Spalten nicht mitspeichern
    if (-not (Get-Command Export-Excel -ErrorAction SilentlyContinue) -and (Get-Module -ListAvailable -Name ImportExcel)) { Import-Module ImportExcel -DisableNameChecking }
    $xl = [bool](Get-Command Export-Excel -ErrorAction SilentlyContinue)
    $sheet = @{ matrix = 'Uebersicht'; policies = 'Ringe und Profile'; devices = 'Geraete'; drivers = 'Treiber' }[$script:WuView]
    if (-not $sheet) { $sheet = 'WIN-Updates' }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = $(if ($xl) { 'Excel-Tabelle (*.xlsx)|*.xlsx|CSV (Excel, Semikolon)|*.csv' } else { 'CSV (Excel, Semikolon)|*.csv' })
    $dlg.FileName = "WIN-Updates_$($sheet -replace ' ', '-')_$(Get-Date -Format 'yyyy-MM-dd_HHmm')"
    try { $rp = Get-HUReportsPath; if (Test-Path -LiteralPath $rp) { $dlg.InitialDirectory = $rp } } catch { }
    if (-not $dlg.ShowDialog($script:Window)) { return }
    try {
        if ($xl -and $dlg.FileName -like '*.xlsx') {
            if (Test-Path -LiteralPath $dlg.FileName) { Remove-Item -LiteralPath $dlg.FileName -Force }   # Excel-Datei wird sonst angehaengt statt ersetzt
            $rows | Export-Excel -Path $dlg.FileName -WorksheetName $sheet -TableName 'WinUpdates' -TableStyle Medium2 -AutoSize -FreezeTopRow -BoldTopRow
        } else {
            if (-not $xl) { Write-HULogWarn 'Excel-Tabelle braucht das Modul ImportExcel (Install-Module ImportExcel -Scope CurrentUser) - gespeichert als CSV' }
            $rows | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
        }
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
    foreach ($n in 'chkWuOld', 'chkWuBehind', 'chkWuCurrent', 'chkWuUnknown', 'chkWuStale', 'chkWuActive', 'chkWuCompany', 'chkWuWin10', 'chkDrvReview', 'chkDrvApproved', 'chkDrvSuspended', 'chkDrvDeclined', 'chkDrvRecommended', 'chkDrvApplicable', 'chkDrvRecent') {
        $c[$n].Add_Click({ Update-HUWuView })
    }
    $c['gridWu'].Add_AutoGeneratingColumn({ param($s, $e) if ("$($e.PropertyName)" -in 'Key') { $e.Cancel = $true } })
    $c['gridWu'].Add_SelectionChanged({
            if ($script:WuView -ne 'policies') { return }
            $k = Get-HUWuCell $script:Controls['gridWu'].SelectedItem 'Key'
            if ($k -and $k -ne $script:WuSelKey) { $script:WuSelKey = $k; Show-HUWuDetail }
        })
    $c['btnWuGroupPick'].Add_Click({
            $n = Show-HUGroupPicker -TenantKeys @(Get-HUWuTenants) -Current $script:Controls['txtWuGroup'].Text.Trim() -Title 'Gruppe waehlen'
            if ($n) { $script:Controls['txtWuGroup'].Text = "$n" }
        })
    $c['btnWuAssignAdd'].Add_Click({ Start-HUWuAssign 'add' })
    $c['btnWuAssignRemove'].Add_Click({ Start-HUWuAssign 'remove' })
    $c['btnWuSave'].Add_Click({ Start-HUWuSave })
    $c['btnWuPauseQ'].Add_Click({ Start-HUWuPause 'quality' })
    $c['btnWuPauseF'].Add_Click({ Start-HUWuPause 'feature' })
    $c['btnWuResume'].Add_Click({ Start-HUWuPause 'resume' })
    $c['btnWuDelete'].Add_Click({ Start-HUWuDelete })
    $c['btnWuNewFeat'].Add_Click({ Start-HUWuNew 'feature' })
    $c['btnWuNewExp'].Add_Click({ Start-HUWuNew 'expedite' })
    $c['btnWuNewRing'].Add_Click({ Start-HUWuNew 'ring' })
    $c['btnWuNewDrv'].Add_Click({ Start-HUWuNew 'driver' })
    $c['btnWuBackup'].Add_Click({ try { Save-HUWuBackupFile } catch { Show-HUMessage "Sichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error } })   # Fehler sonst unsichtbar
    $c['btnWuImport'].Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'WIN-Updates-Sicherung (*.json)|*.json'
            try { $dlg.InitialDirectory = (Get-HUWuTemplateDir) } catch { }
            if ($dlg.ShowDialog($script:Window)) { try { Start-HUWuImport $dlg.FileName } catch { Show-HUMessage "Importieren fehlgeschlagen: $($_.Exception.Message)" -Icon Error } }
        })
    $c['gridWu'].Add_DragOver({ param($s, $e) $e.Effects = $(if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }); $e.Handled = $true })
    $c['gridWu'].Add_Drop({
            param($s, $e)
            $f = @(@($e.Data.GetData([System.Windows.DataFormats]::FileDrop)) | Where-Object { "$_" -like '*.json' })
            if ($f.Count) { try { Start-HUWuImport "$($f[0])" } catch { Show-HUMessage "Importieren fehlgeschlagen: $($_.Exception.Message)" -Icon Error } } else { Show-HUMessage 'Bitte eine WIN-Updates-Sicherung (.json) hineinziehen.' -Icon Info }
        })
    $c['btnDrvApprove'].Add_Click({ Start-HUWuDriverAct 'approve' })
    $c['btnDrvSuspend'].Add_Click({ Start-HUWuDriverAct 'suspend' })
    $c['btnDrvDecline'].Add_Click({ Start-HUWuDriverAct 'decline' })
    $c['gridWu'].Add_MouseDoubleClick({
            $it = $script:Controls['gridWu'].SelectedItem
            $ver = Get-HUWuCell $it 'Version'
            if ($script:WuView -eq 'matrix' -and $ver) {
                $script:WuView = 'devices'; $script:WuDevFilter = $ver
                Update-HUWuView
            }
            elseif ($script:WuView -eq 'drivers' -and (Get-HUWuCell $it 'Treiber')) {
                Show-HUWuDriverDetail ([pscustomobject]@{ Treiber = (Get-HUWuCell $it 'Treiber'); Version = $ver; Hersteller = (Get-HUWuCell $it 'Hersteller'); Klasse = (Get-HUWuCell $it 'Klasse'); Kategorie = (Get-HUWuCell $it 'Kategorie'); Datum = (Get-HUWuCell $it 'Datum') })
            }
        })
    $c['gridWu'].Add_LoadingRow({
            param($s, $e)
            $o = $e.Row.Item
            $col = '#E0E0E0'
            $ps = Get-HUWuCell $o 'Patchstand'; $hi = Get-HUWuCell $o 'Hinweis'; $tr = Get-HUWuCell $o 'Treiber'
            $sup = Get-HUWuCell $o 'Support'; $pct = Get-HUWuCell $o 'Aktuell %'
            if ($null -ne $sup) {
                # Uebersicht: abgelaufene Version rot, sonst nach Anteil aktueller Geraete
                $p = 0; [void][int]::TryParse("$pct", [ref]$p)
                $col = $(if ($sup -eq 'abgelaufen') { '#EF9A9A' } elseif ($p -ge 80) { '#A5D6A7' } elseif ($p -ge 50) { '#FFE082' } else { '#FFCC80' })
            }
            elseif ($null -ne $ps) { $col = $(if ($ps -like 'veraltet*') { '#EF9A9A' } elseif ($ps -like '1 Update*') { '#FFCC80' } elseif ($ps -eq 'unbekannt') { '#AAAAAA' } else { '#E0E0E0' }) }
            elseif ($hi) { $col = '#FFCC80' }
            elseif ($tr -and "$(Get-HUWuCell $o 'Status')" -match 'pruefen') { $col = '#FFCC80' }
            $e.Row.Foreground = Get-HUBrush $col
        })
}

# ============================================================================
# Schritt 2: Zuweisen und Einstellungen (Ablauf wie Wartung > In Intune), Neu, Treiber
# ============================================================================

# Bereich unten: Zuweisungen (ueber Tenants nach Ziel zusammengefasst) und Einstellungen je Art
function Show-HUWuDetail {
    $c = $script:Controls
    $g = $null
    if ($script:WuView -eq 'policies' -and $script:WuSelKey -and $script:WuGroups.ContainsKey($script:WuSelKey)) { $g = $script:WuGroups[$script:WuSelKey] }
    if (-not $g) { $c['pnlWuDetail'].Visibility = 'Collapsed'; return }
    $c['pnlWuDetail'].Visibility = 'Visible'
    $names = Get-HUWuTenantNames
    $c['txtWuDetTitle'].Text = "$($g.Art): $($g.Name)"
    $c['txtWuDetInfo'].Text = "in $(@($g.Items).Count) Tenant(s): $($g.Tenants). Aenderungen gelten fuer alle genannten Tenants."
    # Zuweisungen nach Ziel-Text zusammenfassen; je Tenant der eigene Schluessel (Gruppen-IDs sind je Tenant verschieden)
    $m = [ordered]@{}
    foreach ($it in @($g.Items)) {
        foreach ($a in @($it.AsgList)) {
            $z = "$($a.Ziel)"
            if (-not $m.Contains($z)) { $m[$z] = @{ Ziel = $z; Keys = @{}; T = New-Object System.Collections.Generic.List[string] } }
            $m[$z].Keys[$it.Tenant] = $a.Key
            if (-not $m[$z].T.Contains($names[$it.Tenant])) { $m[$z].T.Add($names[$it.Tenant]) }
        }
    }
    $c['gridWuAssign'].ItemsSource = @(foreach ($v in $m.Values) { [pscustomobject]@{ Ziel = $v.Ziel; Tenants = ($v.T -join ', '); Keys = $v.Keys } })
    # Einstellungen
    $p = $c['pnlWuSet']; $p.Children.Clear(); $script:WuSetCtl = @{}
    $raw = @($g.Items)[0].Raw
    $rv = { param($n) if ($raw -and $raw.PSObject.Properties[$n] -and $null -ne $raw.$n) { "$($raw.$n)" } else { '' } }
    $ring = ($g.Art -eq 'Update-Ring')
    switch ($g.Art) {
        'Update-Ring' {
            Add-HUWuField 'qd' 'Aufschub Qualitaet (Tage)' (& $rv 'qualityUpdatesDeferralPeriodInDays') 40 '0-30: so viele Tage nach Erscheinen wird ein Qualitaetsupdate angeboten'
            Add-HUWuField 'fd' 'Aufschub Feature (Tage)' (& $rv 'featureUpdatesDeferralPeriodInDays') 40 '0 lassen, wenn ein Feature-Update-Profil die Version vorgibt (Microsoft-Empfehlung)'
            Add-HUWuField 'dq' 'Frist Qualitaet (Tage)' (& $rv 'deadlineForQualityUpdatesInDays') 40 '0-30: spaetestens so viele Tage nach dem Angebot wird installiert (leer = keine Frist)'
            Add-HUWuField 'df' 'Frist Feature (Tage)' (& $rv 'deadlineForFeatureUpdatesInDays') 40 '0-30 (leer = keine Frist)'
            Add-HUWuField 'gp' 'Kulanz (Tage)' (& $rv 'deadlineGracePeriodInDays') 40 '0-7: so lange nach der Frist darf der Nutzer den Neustart noch verschieben'
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = 'Neustart-Pruefung ueberspringen (nur fuer Ladewagen)'; $cb.Style = $script:Window.FindResource('DarkCheckBox')
            $cb.IsChecked = ((& $rv 'skipChecksBeforeRestart') -eq 'True'); $cb.Margin = [System.Windows.Thickness]::new(0, 6, 12, 4)
            $cb.ToolTip = 'An = Neustart auch bei Akku unter 40 %, Praesentation usw. Fuer 1:1-Notebooks aus lassen.'
            $script:WuSetCtl['skip'] = $cb; [void]$p.Children.Add($cb)
        }
        'Feature-Update' {
            $vers = @(@($script:WuChoices.Features | ForEach-Object { $_.Version }) + @(& $rv 'featureUpdateVersion') | Where-Object { $_ } | Select-Object -Unique)
            Add-HUWuCombo 'ver' 'Zielversion' $vers (& $rv 'featureUpdateVersion') 230
            $ro = $null; if ($raw -and $raw.PSObject.Properties['rolloutSettings']) { $ro = $raw.rolloutSettings }
            $s1 = $null; $s2 = $null; $iv = ''
            if ($ro) { $s1 = Get-HUWuDateLocal $ro.offerStartDateTimeInUTC; $s2 = Get-HUWuDateLocal $ro.offerEndDateTimeInUTC; $iv = "$($ro.offerIntervalInDays)" }
            Add-HUWuCombo 'mode' 'Verfuegbar' @('sofort', 'ab Datum', 'gestaffelt') $(if ($s1 -and $s2) { 'gestaffelt' } elseif ($s1) { 'ab Datum' } else { 'sofort' }) 110
            Add-HUWuField 'start' 'ab' $(if ($s1) { $s1.ToString('dd.MM.yyyy') } else { '' }) 80 'TT.MM.JJJJ (gestaffelt: mindestens 2 Tage in der Zukunft)'
            Add-HUWuField 'end' 'bis' $(if ($s2) { $s2.ToString('dd.MM.yyyy') } else { '' }) 80 'TT.MM.JJJJ - letzte Gruppe'
            Add-HUWuField 'int' 'Abstand (Tage)' $iv 40 'Tage zwischen den Gruppen'
        }
        'Treiber-Update' {
            Add-HUWuCombo 'appr' 'Freigabe' @('manuell', 'automatisch') $(if ((& $rv 'approvalType') -eq 'automatic') { 'automatisch' } else { 'manuell' }) 120
            Add-HUWuField 'defer' 'Aufschub (Tage, nur automatisch)' (& $rv 'deploymentDeferralInDays') 40 '0-30'
        }
        default {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $(if ($g.Art -eq 'Expedite') { 'Expedite hat nur das Update und den Neustart - nach dem Ausrollen wieder entfernen (Microsoft-Empfehlung).' } else { 'Diese Art wird hier nur angezeigt.' })
            $t.Foreground = Get-HUBrush '#AAAAAA'; $t.TextWrapping = 'Wrap'
            [void]$p.Children.Add($t)
        }
    }
    $c['btnWuSave'].Visibility = $(if ($g.Art -in 'Update-Ring', 'Feature-Update', 'Treiber-Update') { 'Visible' } else { 'Collapsed' })
    foreach ($b in 'btnWuPauseQ', 'btnWuPauseF', 'btnWuResume') { $c[$b].Visibility = $(if ($ring) { 'Visible' } else { 'Collapsed' }) }
    $c['btnWuDelete'].Visibility = $(if ($g.Art -in 'Feature-Update', 'Expedite', 'Treiber-Update') { 'Visible' } else { 'Collapsed' })
    # Alle Geraete / Alle Benutzer nur bei Ringen (Profile: nur Geraetegruppen)
    foreach ($ci in $c['cmbWuTarget'].Items) { if ("$($ci.Tag)" -in 'allDevices', 'allUsers') { $ci.IsEnabled = $ring } }
    if (-not $ring -and "$($c['cmbWuTarget'].SelectedItem.Tag)" -in 'allDevices', 'allUsers') { $c['cmbWuTarget'].SelectedIndex = 0 }
}

function Get-HUWuDateLocal($v) { if (-not "$v") { return $null }; try { $d = [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture); if ($d.Year -lt 2000) { return $null }; return $d.ToLocalTime() } catch { return $null } }

function Add-HUWuField([string]$Key, [string]$Label, [string]$Value, [int]$Width = 60, [string]$Tip = '') {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = [System.Windows.Thickness]::new(0, 2, 14, 4)
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label; $l.Foreground = Get-HUBrush '#BBBBBB'; $l.FontSize = 11; $l.VerticalAlignment = 'Center'; $l.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $t = New-Object System.Windows.Controls.TextBox
    $t.Style = $script:Window.FindResource('DarkTextBox'); $t.Width = $Width; $t.Text = $Value
    if ($Tip) { $t.ToolTip = $Tip; $l.ToolTip = $Tip }
    [void]$sp.Children.Add($l); [void]$sp.Children.Add($t)
    [void]$script:Controls['pnlWuSet'].Children.Add($sp)
    $script:WuSetCtl[$Key] = $t
}

function Add-HUWuCombo([string]$Key, [string]$Label, [string[]]$Items, [string]$Value, [int]$Width = 160) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = [System.Windows.Thickness]::new(0, 2, 14, 4)
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label; $l.Foreground = Get-HUBrush '#BBBBBB'; $l.FontSize = 11; $l.VerticalAlignment = 'Center'; $l.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $cb = New-Object System.Windows.Controls.ComboBox
    $cb.Style = $script:Window.FindResource('DarkComboBox'); $cb.Width = $Width
    foreach ($i in @($Items)) { [void]$cb.Items.Add("$i") }
    if ($Value) { $cb.SelectedItem = $Value }
    [void]$sp.Children.Add($l); [void]$sp.Children.Add($cb)
    [void]$script:Controls['pnlWuSet'].Children.Add($sp)
    $script:WuSetCtl[$Key] = $cb
}

function Get-HUWuSelGroup {
    if ($script:WuSelKey -and $script:WuGroups.ContainsKey($script:WuSelKey)) { return $script:WuGroups[$script:WuSelKey] }
    Show-HUMessage 'Bitte oben einen Ring bzw. ein Profil markieren.' -Icon Info
    return $null
}

# 'TT.MM.JJJJ' -> datetime (oder $null)
function ConvertFrom-HUWuDateText([string]$T) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact("$T".Trim(), 'dd.MM.yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return $d }
    return $null
}

# Auftrag im Hintergrund: Work = @(@{ Tenant; Art; Id; ... }), Op + P = was zu tun ist
function Start-HUWuJob([string]$Op, [object[]]$Work, [hashtable]$P, [string]$What) {
    if (Test-HUJobRunning 'WuAct') { Show-HUMessage 'Es laeuft noch eine Aenderung - bitte warten.' -Icon Info; return }
    Add-HURtbLine $script:Controls['rtbRem'] "=== WIN-Updates: $What ===" '#4FC3F7'
    [void](Start-HUJob -Name 'WuAct' -Output $script:Controls['rtbRem'] -Vars @{ Op = $Op; Work = @($Work); P = $P } -Code {
            foreach ($x in $Work) {
                $tk = "$($x.Tenant)"
                try {
                    $msg = ''
                    switch ($Op) {
                        'assignAdd' {
                            $gid = ''
                            if ("$($P.Kind)" -in 'group', 'exclude') {
                                $grp = Find-HUGroup -TenantKey $tk -Settings $Settings -Name "$($P.Group)"
                                if (-not $grp) { throw "Gruppe '$($P.Group)' gibt es in diesem Tenant nicht" }
                                $gid = "$($grp.id)"
                            }
                            $n = Set-HUWuAssignment -TenantKey $tk -Settings $Settings -Art $x.Art -Id $x.Id -Add @([pscustomobject]@{ Kind = "$($P.Kind)"; GroupId = $gid })
                            $msg = "$($x.Name): zugewiesen ($n Zuweisung(en))"
                        }
                        'assignRemove' { $n = Set-HUWuAssignment -TenantKey $tk -Settings $Settings -Art $x.Art -Id $x.Id -RemoveKeys @($x.Keys); $msg = "$($x.Name): Zuweisung entfernt ($n bleiben)" }
                        'settings' { $f = Set-HUWuSettings -TenantKey $tk -Settings $Settings -Art $x.Art -Id $x.Id -Changes $P.Changes; $msg = "$($x.Name): gespeichert (vorher: $f)" }
                        'pause' { [void](Set-HUWuRingPause -TenantKey $tk -Settings $Settings -Id $x.Id -What $x.What -Action $x.Action); $msg = "$($x.Name): $($x.What) $($x.Action)" }
                        'delete' { $f = Remove-HUWuProfile -TenantKey $tk -Settings $Settings -Art $x.Art -Id $x.Id; $msg = "$($x.Name): entfernt (vorher: $f)" }
                        'newFeature' { $id = New-HUWuFeatureProfile -TenantKey $tk -Settings $Settings -Name $P.Name -Version $P.Version -Rollout $P.Rollout -Win10Fallback ([bool]$P.Win10); $msg = "'$($P.Name)' angelegt (ohne Zuweisung)" }
                        'newExpedite' { $id = New-HUWuExpedite -TenantKey $tk -Settings $Settings -Name $P.Name -Release $P.Release -RebootDays $P.Reboot; $msg = "'$($P.Name)' angelegt (ohne Zuweisung)" }
                        'import' { $id = New-HUWuFromBody -TenantKey $tk -Settings $Settings -Art $x.Art -Body $x.Body; $msg = "'$($x.Name)' angelegt aus Sicherung (ohne Zuweisung)" }
                        'newRing' { $id = New-HUWuRing -TenantKey $tk -Settings $Settings -Name $P.Name -QualityDeferral $P.qd -QualityDeadline $P.dq -FeatureDeadline $P.df -Grace $P.gp -ActiveStart $P.ahs -ActiveEnd $P.ahe -UserPause ([bool]$P.up); $msg = "'$($P.Name)' angelegt (ohne Zuweisung)" }
                        'newDriver' { $id = New-HUWuDriverProfile -TenantKey $tk -Settings $Settings -Name $P.Name -Approval $P.appr -DeferDays $P.defer; $msg = "'$($P.Name)' angelegt (ohne Zuweisung)" }
                        'driver' {
                            $r = Invoke-HUWuDriverAction -TenantKey $tk -Settings $Settings -ProfileId $x.Id -Action $P.Action -DriverIds @($x.DriverIds) -Date $P.Date
                            $ok = @($r.successfulDriverIds).Count; $bad = @($r.failedDriverIds).Count + @($r.notFoundDriverIds).Count
                            $msg = "$($x.Name): $ok Treiber $($P.Action)$(if ($bad) { ", $bad nicht moeglich" })"
                        }
                    }
                    Write-HULog -Message $msg -Level 'OK' -Tenant $tk
                    [pscustomobject]@{ Tenant = $tk; Ok = $true; Missing = '' }
                } catch {
                    $m = "$($_.Exception.Message)"
                    $miss = ''
                    if ($m -match '403|Forbidden|Authorization') { $miss = 'DeviceManagementConfiguration.ReadWrite.All'; $m += ' -> Berechtigung DeviceManagementConfiguration.ReadWrite.All erteilen' }
                    elseif ($m -match '(?i)licen') { $m += ' -> Windows-Lizenz mit Autopatch-Berechtigung und Windows-Lizenzueberpruefung im Intune Admin Center noetig' }
                    Write-HULog -Message "$($x.Name): $m" -Level 'ERROR' -Tenant $tk
                    [pscustomobject]@{ Tenant = $tk; Ok = $false; Missing = $miss }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            Request-HUMissingRight $Result 'Windows-Updates aendern'
            # Intune braucht einen Moment, bis Aenderungen gelesen werden koennen
            Invoke-HUDelayed 4 { Start-HUWuLoad -Force; Update-HUWuView }
        })
}

function Start-HUWuAssign([string]$Mode) {
    $g = Get-HUWuSelGroup; if (-not $g) { return }
    $c = $script:Controls
    $names = Get-HUWuTenantNames
    if ($Mode -eq 'add') {
        $kind = "$($c['cmbWuTarget'].SelectedItem.Tag)"
        $grp = $c['txtWuGroup'].Text.Trim()
        if ($kind -in 'group', 'exclude' -and -not $grp) { Show-HUMessage 'Bitte einen Gruppennamen eingeben oder mit der Lupe waehlen.' -Icon Info; return }
        if ($g.Art -ne 'Update-Ring' -and $kind -in 'allDevices', 'allUsers') { Show-HUMessage "$($g.Art) laesst sich laut Microsoft nur Geraetegruppen zuweisen." -Icon Info; return }
        $ziel = switch ($kind) { 'group' { "Gruppe '$grp'" } 'exclude' { "Ausschluss '$grp'" } 'allDevices' { 'Alle Geraete' } default { 'Alle Benutzer' } }
        $work = @(foreach ($it in @($g.Items)) { @{ Tenant = $it.Tenant; Art = $it.Art; Id = $it.Id; Name = $it.Name } })
        if (-not (Confirm-HU -Warning "$($g.Art) '$($g.Name)' zuweisen: $ziel`n`nTenants: $($g.Tenants)`n`nDie Gruppe wird je Tenant ueber den Namen gesucht. Ab dann gilt das Profil fuer deren Geraete.")) { return }
        Start-HUWuJob 'assignAdd' $work @{ Kind = $kind; Group = $grp } "Zuweisen $ziel"
        return
    }
    $sel = @($c['gridWuAssign'].SelectedItems | Where-Object { $_ })
    if (-not $sel.Count) { Show-HUMessage 'Bitte die Zuweisungen markieren, die entfernt werden sollen.' -Icon Info; return }
    $work = @(foreach ($it in @($g.Items)) {
            $keys = @($sel | ForEach-Object { $_.Keys[$it.Tenant] } | Where-Object { $_ })
            if ($keys.Count) { @{ Tenant = $it.Tenant; Art = $it.Art; Id = $it.Id; Name = $it.Name; Keys = $keys } }
        })
    if (-not $work.Count) { return }
    if (-not (Confirm-HU -Warning "Zuweisungen entfernen von $($g.Art) '$($g.Name)':`n`n$(@($sel | ForEach-Object { "  $($_.Ziel) ($($_.Tenants))" }) -join "`n")`n`nDie Geraete dieser Ziele bekommen das Profil dann nicht mehr.")) { return }
    Start-HUWuJob 'assignRemove' $work @{} 'Zuweisungen entfernen'
}

# Eingaben pruefen: ganze Zahl im Bereich oder leer (= $null)
function Get-HUWuIntField([string]$Key, [int]$Min, [int]$Max, [string]$Label) {
    $t = "$($script:WuSetCtl[$Key].Text)".Trim()
    if (-not $t) { return @{ Ok = $true; Value = $null } }
    $n = 0
    if (-not [int]::TryParse($t, [ref]$n) -or $n -lt $Min -or $n -gt $Max) { Show-HUMessage "$Label`: bitte eine Zahl von $Min bis $Max (oder leer)." -Icon Warning; return @{ Ok = $false } }
    return @{ Ok = $true; Value = $n }
}

function Start-HUWuSave {
    $g = Get-HUWuSelGroup; if (-not $g) { return }
    $ch = @{}; $txt = @()
    switch ($g.Art) {
        'Update-Ring' {
            foreach ($f in @(@('qd', 'qualityUpdatesDeferralPeriodInDays', 0, 30, 'Aufschub Qualitaet'), @('fd', 'featureUpdatesDeferralPeriodInDays', 0, 365, 'Aufschub Feature'),
                    @('dq', 'deadlineForQualityUpdatesInDays', 0, 30, 'Frist Qualitaet'), @('df', 'deadlineForFeatureUpdatesInDays', 0, 30, 'Frist Feature'), @('gp', 'deadlineGracePeriodInDays', 0, 7, 'Kulanz'))) {
                $r = Get-HUWuIntField $f[0] $f[2] $f[3] $f[4]
                if (-not $r.Ok) { return }
                $ch[$f[1]] = $r.Value; $txt += "  $($f[4]): $(if ($null -eq $r.Value) { 'leer' } else { "$($r.Value) Tage" })"
            }
            # Aufschub darf nicht leer sein (Pflichtfeld im Ring)
            foreach ($k in 'qualityUpdatesDeferralPeriodInDays', 'featureUpdatesDeferralPeriodInDays') { if ($null -eq $ch[$k]) { $ch.Remove($k) } }
            $ch['skipChecksBeforeRestart'] = [bool]$script:WuSetCtl['skip'].IsChecked
            $txt += "  Neustart-Pruefung ueberspringen: $(if ($ch['skipChecksBeforeRestart']) { 'ja' } else { 'nein' })"
        }
        'Feature-Update' {
            $ver = "$($script:WuSetCtl['ver'].SelectedItem)"
            if (-not $ver) { Show-HUMessage 'Bitte eine Zielversion waehlen.' -Icon Info; return }
            $ch['featureUpdateVersion'] = $ver; $txt += "  Zielversion: $ver"
            $ro = Get-HUWuRolloutInput; if ($ro -eq $false) { return }
            if ($ro) { $ch['rolloutSettings'] = ConvertTo-HUWuRollout $ro; $txt += "  Verfuegbar: $($ro.Mode) ab $($ro.Start.ToString('dd.MM.yyyy'))$(if ($ro.End) { " bis $($ro.End.ToString('dd.MM.yyyy')), alle $($ro.Interval) Tage" })" }
            else { $ch['rolloutSettings'] = @{ '@odata.type' = '#microsoft.graph.windowsUpdateRolloutSettings'; offerStartDateTimeInUTC = $null; offerEndDateTimeInUTC = $null; offerIntervalInDays = $null }; $txt += '  Verfuegbar: sofort' }
        }
        'Treiber-Update' {
            $auto = ("$($script:WuSetCtl['appr'].SelectedItem)" -eq 'automatisch')
            $ch['approvalType'] = $(if ($auto) { 'automatic' } else { 'manual' }); $txt += "  Freigabe: $(if ($auto) { 'automatisch (empfohlene)' } else { 'manuell' })"
            if ($auto) { $r = Get-HUWuIntField 'defer' 0 30 'Aufschub'; if (-not $r.Ok) { return }; if ($null -ne $r.Value) { $ch['deploymentDeferralInDays'] = $r.Value; $txt += "  Aufschub: $($r.Value) Tage" } }
        }
        default { return }
    }
    $work = @(foreach ($it in @($g.Items)) { @{ Tenant = $it.Tenant; Art = $it.Art; Id = $it.Id; Name = $it.Name } })
    if (-not (Confirm-HU -Warning "$($g.Art) '$($g.Name)' aendern in: $($g.Tenants)`n`n$($txt -join "`n")`n`nDer bisherige Stand wird vorher gesichert (%APPDATA%\HU-MultiTenant\WinUpdates-vorher).")) { return }
    Start-HUWuJob 'settings' $work @{ Changes = $ch } "Speichern $($g.Name)"
}

# Verfuegbarkeit aus den Feldern: $null = sofort, $false = Eingabefehler, sonst @{ Mode; Start; End; Interval }
function Get-HUWuRolloutInput {
    $mode = "$($script:WuSetCtl['mode'].SelectedItem)"
    if ($mode -eq 'sofort' -or -not $mode) { return $null }
    $s = ConvertFrom-HUWuDateText $script:WuSetCtl['start'].Text
    if (-not $s) { Show-HUMessage 'Bitte das Datum "ab" als TT.MM.JJJJ eingeben.' -Icon Warning; return $false }
    if ($mode -eq 'ab Datum') { return @{ Mode = 'date'; Start = $s } }
    $e = ConvertFrom-HUWuDateText $script:WuSetCtl['end'].Text
    $iv = 0; [void][int]::TryParse("$($script:WuSetCtl['int'].Text)".Trim(), [ref]$iv)
    if (-not $e -or $e -le $s -or $iv -lt 1) { Show-HUMessage 'Gestaffelt: "bis" muss nach "ab" liegen, Abstand mindestens 1 Tag.' -Icon Warning; return $false }
    if ($s -lt (Get-Date).Date.AddDays(2)) { Show-HUMessage 'Gestaffelt: Microsoft verlangt als Beginn mindestens 2 Tage in der Zukunft.' -Icon Warning; return $false }
    return @{ Mode = 'gradual'; Start = $s; End = $e; Interval = $iv }
}

function Start-HUWuPause([string]$What) {
    $g = Get-HUWuSelGroup; if (-not $g -or $g.Art -ne 'Update-Ring') { return }
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($g.Items)) {
        $raw = $it.Raw
        if ($What -eq 'resume') {
            foreach ($w in 'quality', 'feature') { if ($raw.PSObject.Properties["$($w)UpdatesPaused"] -and $raw."$($w)UpdatesPaused") { $work.Add(@{ Tenant = $it.Tenant; Id = $it.Id; Name = $it.Name; What = $w; Action = 'resume' }) } }
        } else {
            $on = ($raw.PSObject.Properties["$($What)UpdatesPaused"] -and $raw."$($What)UpdatesPaused")
            $work.Add(@{ Tenant = $it.Tenant; Id = $it.Id; Name = $it.Name; What = $What; Action = $(if ($on) { 'extend' } else { 'pause' }) })
        }
    }
    if (-not $work.Count) { Show-HUMessage 'Dieser Ring ist in keinem Tenant pausiert.' -Icon Info; return }
    $wt = $(if ($What -eq 'quality') { 'Qualitaetsupdates' } elseif ($What -eq 'feature') { 'Feature-Updates' } else { 'alle Pausen' })
    $txt = $(if ($What -eq 'resume') { "Pausen aufheben ($wt) fuer '$($g.Name)' in: $($g.Tenants)?`n`nDie Geraete holen danach die ausstehenden Updates." }
        else { "$wt fuer '$($g.Name)' pausieren in: $($g.Tenants)?`n`nDie Pause gilt 35 Tage ab jetzt (laeuft schon eine, wird sie auf 35 Tage ab jetzt verlaengert). Danach holen die Geraete die Updates automatisch." })
    if (-not (Confirm-HU -Warning $txt)) { return }
    Start-HUWuJob 'pause' $work.ToArray() @{} "Pause: $wt"
}

function Start-HUWuDelete {
    $g = Get-HUWuSelGroup; if (-not $g) { return }
    # Mehrere Zeilen markiert (Strg/Umschalt): alle markierten entfernen - z. B. alte Expedites mehrerer Tenants
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($script:Controls['gridWu'].SelectedItems)) {
        $k = "$(Get-HUWuCell $r 'Key')"
        if ($k -and $script:WuGroups.ContainsKey($k) -and -not @($groups | Where-Object { $_.Key -eq $k }).Count) { $groups.Add($script:WuGroups[$k]) }
    }
    if (-not $groups.Count) { $groups.Add($g) }
    if (@($groups | Where-Object { $_.Art -eq 'Update-Ring' }).Count) { Show-HUMessage 'Update-Ringe werden hier nicht geloescht (nur Profile) - bitte nur Profile markieren.' -Icon Info; return }
    $work = @(foreach ($x in $groups) { foreach ($it in @($x.Items)) { @{ Tenant = $it.Tenant; Art = $it.Art; Id = $it.Id; Name = $it.Name } } })
    $list = (@($groups | ForEach-Object { "  $($_.Art) '$($_.Name)' in: $($_.Tenants)" }) -join "`n")
    if (-not (Confirm-HU -Warning "Loeschen ($($work.Count)):`n`n$list`n`nDer Stand wird vorher gesichert. Geraete behalten die bereits installierte Version.")) { return }
    Start-HUWuJob 'delete' $work @{} "Entfernen ($($work.Count))"
}

# + Feature-Update / + Expedite: kleines Fenster, angelegt in den angehakten Tenants ohne Zuweisung (wie Wartung)
function Start-HUWuNew([string]$Kind) {
    $keys = @(Get-HUWuTenants)
    if (-not $keys.Count) { Show-HUMessage 'Bitte links Tenants anhaken.' -Icon Info; return }
    if ($Kind -in 'ring', 'driver') { Start-HUWuNewSimple $Kind $keys; return }
    if (-not $script:WuChoices) { Show-HUMessage 'Die Auswahl (Versionen/Updates) wird noch gelesen - gleich noch einmal versuchen.' -Icon Info; Start-HUWuLoad -Force; return }
    $names = Get-HUWuTenantNames
    $r = Show-HUWuNewDialog $Kind
    if (-not $r) { return }
    $tn = (@($keys | ForEach-Object { $names[$_] }) -join ', ')
    $work = @(foreach ($k in $keys) { @{ Tenant = $k; Name = $r.Name } })
    if ($Kind -eq 'feature') {
        if (-not (Confirm-HU -Warning "Feature-Update-Profil anlegen in: $tn`n`n  Name: $($r.Name)`n  Zielversion: $($r.Version)`n  Verfuegbar: $($r.Text)`n`nAngelegt OHNE Zuweisung - danach markieren und unten zuweisen. Wirkt nur auf Entra- bzw. Hybrid-beigetretene Geraete.")) { return }
        Start-HUWuJob 'newFeature' $work @{ Name = $r.Name; Version = $r.Version; Rollout = $r.Rollout; Win10 = $r.Win10 } "Neu: $($r.Name)"
    } else {
        if (-not (Confirm-HU -Warning "Expedite anlegen in: $tn`n`n  Name: $($r.Name)`n  Update: $($r.Text)`n  Neustart spaetestens nach $($r.Reboot) Tag(en)`n`nAngelegt OHNE Zuweisung - danach markieren und unten zuweisen. Nach dem Ausrollen wieder entfernen.")) { return }
        Start-HUWuJob 'newExpedite' $work @{ Name = $r.Name; Release = $r.Release; Reboot = $r.Reboot } "Neu: $($r.Name)"
    }
    $script:WuView = 'policies'
    foreach ($li in $script:Controls['lstWuView'].Items) { if ("$($li.Tag)" -eq 'policies') { $script:Controls['lstWuView'].SelectedItem = $li } }
}

# Fester Ordner fuer Vorlagen - die App-Sicherung nimmt ihn mit
function Get-HUWuTemplateDir {
    $d = Join-Path (Get-HUAbDataRoot) 'WinUpdates-Vorlagen'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# Sichern: markierte Ringe/Profile -> JSON (ohne Zuweisungen; gleicher Name in mehreren Tenants = einmal, aus dem ersten)
function Save-HUWuBackupFile {
    if ($script:WuView -ne 'policies') { Show-HUMessage 'Sichern geht unter "Ringe und Profile": Eintraege markieren (Strg/Umschalt fuer mehrere).' -Icon Info; return }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($script:Controls['gridWu'].SelectedItems)) {
        $k = "$(Get-HUWuCell $r 'Key')"
        if ($k -and $script:WuGroups.ContainsKey($k)) { foreach ($it in @($script:WuGroups[$k].Items)) { $rows.Add($it) } }
    }
    if (-not $rows.Count) { Show-HUMessage 'Bitte oben die Ringe/Profile markieren, die gesichert werden sollen.' -Icon Info; return }
    $doc = New-HUWuExportDoc $rows.ToArray() (Get-HUWuTenantNames)
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'WIN-Updates-Sicherung (*.json)|*.json'
    $dlg.FileName = "WIN-Updates-Sicherung_$(Get-Date -Format 'yyyy-MM-dd_HHmm').json"
    try { $dlg.InitialDirectory = (Get-HUWuTemplateDir) } catch { }
    if (-not $dlg.ShowDialog($script:Window)) { return }
    try {
        [System.IO.File]::WriteAllText($dlg.FileName, ($doc | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        Write-HULogOK "WIN-Updates gesichert ($(@($doc.Items).Count) Eintrag/Eintraege): $($dlg.FileName)"
        Show-HUMessage "Gesichert: $(@($doc.Items).Count) Ring(e)/Profil(e), ohne Zuweisungen.`n`n$(@($doc.Items | ForEach-Object { "  $($_.Art): $($_.Name)  (aus $($_.Quelle))" }) -join "`n")`n`n$($dlg.FileName)" -Icon Info
    } catch { Show-HUMessage "Speichern fehlgeschlagen: $($_.Exception.Message)" -Icon Error }
}

# Importieren: Sicherung in den angehakten Tenants anlegen (ohne Zuweisung). Gleicher Name schon da -> wird ausgelassen.
function Start-HUWuImport([string]$Path) {
    $keys = @(Get-HUWuTenants)
    if (-not $keys.Count) { Show-HUMessage 'Bitte links die Ziel-Tenants anhaken.' -Icon Info; return }
    try { $items = @(Read-HUWuExportFile $Path) } catch { Show-HUMessage "Datei nicht lesbar: $($_.Exception.Message)" -Icon Warning; return }
    if (-not $items.Count) { Show-HUMessage 'In der Datei sind keine Ringe/Profile.' -Icon Info; return }
    $names = Get-HUWuTenantNames
    $have = @{}
    foreach ($i in @(Get-HUWuInventories)) { foreach ($p in @($i.Policies)) { $have["$($i.Tenant)|$($p.Art)|$($p.Name)"] = 1 } }
    $work = New-Object System.Collections.Generic.List[object]; $skip = New-Object System.Collections.Generic.List[string]
    foreach ($k in $keys) {
        foreach ($it in $items) {
            if ($have.ContainsKey("$k|$($it.Art)|$($it.Name)")) { $skip.Add("  $($names[$k]): $($it.Art) '$($it.Name)'"); continue }
            $work.Add(@{ Tenant = $k; Art = $it.Art; Name = $it.Name; Body = $it.Body })
        }
    }
    if (-not $work.Count) { Show-HUMessage "Alles schon vorhanden (gleicher Name) - nichts anzulegen.`n`n$($skip -join "`n")" -Icon Info; return }
    $list = (@($items | ForEach-Object { "  $($_.Art): $($_.Name)" }) -join "`n")
    $tn = (@($keys | ForEach-Object { $names[$_] }) -join ', ')
    $msg = "Aus Sicherung anlegen in: $tn ($($work.Count) neu)`n`n$list"
    if ($skip.Count) { $msg += "`n`nSchon vorhanden, wird ausgelassen:`n$($skip -join "`n")" }
    $msg += "`n`nAngelegt OHNE Zuweisung - danach markieren und unten zuweisen."
    if (-not (Confirm-HU -Warning $msg)) { return }
    Start-HUWuJob 'import' $work.ToArray() @{} "Importieren ($($work.Count))"
    $script:WuView = 'policies'
    foreach ($li in $script:Controls['lstWuView'].Items) { if ("$($li.Tag)" -eq 'policies') { $script:Controls['lstWuView'].SelectedItem = $li } }
}

# + Ring / + Treiber: Felder mit den empfohlenen Werten vorbelegt, alles aenderbar
function Start-HUWuNewSimple([string]$Kind, [string[]]$Keys) {
    $names = Get-HUWuTenantNames
    $tn = (@($Keys | ForEach-Object { $names[$_] }) -join ', ')
    if ($Kind -eq 'ring') {
        $f = @(
            @{ Key = 'Name'; Label = 'Name'; Value = 'WU-Ring Standard'; Width = 320 }
            @{ Key = 'qd'; Label = 'Aufschub Qualitaet (Tage, 0-30)'; Value = '3'; Int = @(0, 30) }
            @{ Key = 'dq'; Label = 'Frist Qualitaet (Tage, 0-30)'; Value = '3'; Int = @(0, 30); Tip = 'Danach wird das Update erzwungen' }
            @{ Key = 'df'; Label = 'Frist Feature (Tage, 0-30)'; Value = '7'; Int = @(0, 30) }
            @{ Key = 'gp'; Label = 'Nachfrist Neustart (Tage, 0-7)'; Value = '2'; Int = @(0, 7); Tip = 'Nach der Frist so viele Tage bis zum erzwungenen Neustart' }
            @{ Key = 'ahs'; Label = 'Aktive Zeit von (HH:mm)'; Value = '07:00'; Time = $true; Tip = 'In dieser Zeit kein automatischer Neustart' }
            @{ Key = 'ahe'; Label = 'Aktive Zeit bis (HH:mm)'; Value = '15:00'; Time = $true }
            @{ Key = 'up'; Label = 'Benutzer duerfen Updates pausieren'; Check = $true; Value = $false }
        )
        $r = Show-HUWuFormDialog 'Neuer Update-Ring' 'Update-Ring (Aufschub, Fristen, aktive Zeit)' 'Feature-Aufschub ist fest 0 - die Windows-Version steuert das Feature-Update-Profil. Neustart-Pruefung wird nicht uebersprungen. Angelegt ohne Zuweisung.' $f
        if (-not $r) { return }
        $txt = "  Name: $($r.Name)`n  Aufschub Qualitaet $($r.qd) T., Feature 0 T.`n  Frist Qualitaet $($r.dq) T., Feature $($r.df) T., Nachfrist $($r.gp) T.`n  Aktive Zeit $($r.ahs)-$($r.ahe)`n  Benutzer duerfen pausieren: $(if ($r.up) { 'ja' } else { 'nein' })"
        if (-not (Confirm-HU -Warning "Update-Ring anlegen in: $tn`n`n$txt`n`nAngelegt OHNE Zuweisung - danach markieren und unten zuweisen.")) { return }
        $op = 'newRing'
    } else {
        $f = @(
            @{ Key = 'Name'; Label = 'Name'; Value = 'Treiber automatisch'; Width = 320 }
            @{ Key = 'appr'; Label = 'Freigabe'; Items = @('automatisch', 'manuell'); Value = 'automatisch' }
            @{ Key = 'defer'; Label = 'Aufschub (Tage, nur automatisch)'; Value = '7'; Int = @(0, 30); Tip = 'Empfohlene Treiber erst nach so vielen Tagen - fehlerhafte fallen vorher auf' }
        )
        $r = Show-HUWuFormDialog 'Neue Treiber-Richtlinie' 'Treiber-Updates' 'Automatisch: empfohlene Treiber werden nach dem Aufschub freigegeben. Manuell: jeder Treiber muss unter Treiber freigegeben werden. Wirkt nur auf Entra- bzw. Hybrid-beigetretene Geraete. Angelegt ohne Zuweisung.' $f
        if (-not $r) { return }
        $r.appr = $(if ($r.appr -eq 'manuell') { 'manual' } else { 'automatic' })
        $txt = "  Name: $($r.Name)`n  Freigabe: $(if ($r.appr -eq 'manual') { 'manuell' } else { "automatisch, Aufschub $($r.defer) T." })"
        if (-not (Confirm-HU -Warning "Treiber-Richtlinie anlegen in: $tn`n`n$txt`n`nAngelegt OHNE Zuweisung - danach markieren und unten zuweisen.")) { return }
        $op = 'newDriver'
    }
    $work = @(foreach ($k in $Keys) { @{ Tenant = $k; Name = $r.Name } })
    Start-HUWuJob $op $work $r "Neu: $($r.Name)"
    $script:WuView = 'policies'
    foreach ($li in $script:Controls['lstWuView'].Items) { if ("$($li.Tag)" -eq 'policies') { $script:Controls['lstWuView'].SelectedItem = $li } }
}

# Einfaches Formular: Fields = @{ Key; Label; Value; Width; Tip; Int=@(min,max) | Time | Check | Items }. Rueckgabe: Hashtable oder $null
function Show-HUWuFormDialog([string]$Title, [string]$Head, [string]$Info, [object[]]$Fields) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="600" MinWidth="520" SizeToContent="Height" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="16">
        <TextBlock x:Name="txtHead" Style="{StaticResource SectionTitle}"/>
        <TextBlock x:Name="txtInfo" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <Grid x:Name="grdF">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" MinWidth="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        </Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="btnOk" Content="Weiter" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    try { $w.Owner = $script:Window } catch { }
    $w.Title = $Title; $c.txtHead.Text = $Head; $c.txtInfo.Text = $Info
    $ctl = @{}; $row = 0
    foreach ($f in $Fields) {
        [void]$c.grdF.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::Auto }))
        if ($f.Check) {
            $e = New-Object System.Windows.Controls.CheckBox
            $e.Style = $w.FindResource('DarkCheckBox'); $e.Content = $f.Label; $e.IsChecked = [bool]$f.Value; $e.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            [System.Windows.Controls.Grid]::SetColumnSpan($e, 2)   # ganze Breite - Text sonst abgeschnitten
        } else {
            $l = New-Object System.Windows.Controls.TextBlock
            $l.Text = $f.Label; $l.Style = $w.FindResource('FieldLabel'); $l.VerticalAlignment = 'Center'; $l.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
            if ($f.Tip) { $l.ToolTip = $f.Tip }
            [System.Windows.Controls.Grid]::SetRow($l, $row); [void]$c.grdF.Children.Add($l)
            if ($f.Items) {
                $e = New-Object System.Windows.Controls.ComboBox
                $e.Style = $w.FindResource('DarkComboBox'); $e.Width = 160; $e.HorizontalAlignment = 'Left'
                foreach ($i in @($f.Items)) { [void]$e.Items.Add("$i") }
                $e.SelectedItem = "$($f.Value)"
            } else {
                $e = New-Object System.Windows.Controls.TextBox
                $e.Style = $w.FindResource('DarkTextBox'); $e.Text = "$($f.Value)"; $e.HorizontalAlignment = 'Left'
                # Breite Felder (Name) fuellen die Spalte statt fester Breite - nie ueber den Rand hinaus
                if ($f.Width) { $e.HorizontalAlignment = 'Stretch' } else { $e.Width = 70 }
                if ($f.Tip) { $e.ToolTip = $f.Tip }
            }
            $e.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
            [System.Windows.Controls.Grid]::SetColumn($e, 1)
        }
        [System.Windows.Controls.Grid]::SetRow($e, $row); [void]$c.grdF.Children.Add($e)
        $ctl[$f.Key] = $e; $row++
    }
    $st = @{ R = $null }
    $c.btnOk.Add_Click({
            $res = @{}
            foreach ($f in $Fields) {
                $e = $ctl[$f.Key]
                if ($f.Check) { $res[$f.Key] = [bool]$e.IsChecked; continue }
                if ($f.Items) { $res[$f.Key] = "$($e.SelectedItem)"; continue }
                $v = "$($e.Text)".Trim()
                if (-not $v) { Show-HUMessage "Bitte '$($f.Label)' ausfuellen." -Icon Info -Owner $w; return }
                if ($f.Int) {
                    $n = 0
                    if (-not [int]::TryParse($v, [ref]$n) -or $n -lt $f.Int[0] -or $n -gt $f.Int[1]) { Show-HUMessage "'$($f.Label)': Zahl von $($f.Int[0]) bis $($f.Int[1])." -Icon Warning -Owner $w; return }
                    $res[$f.Key] = $n; continue
                }
                if ($f.Time) {
                    $t = [datetime]::MinValue
                    if (-not [datetime]::TryParseExact($v, [string[]]@('HH:mm', 'H:mm'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) { Show-HUMessage "'$($f.Label)': Uhrzeit als HH:mm, z. B. 07:00." -Icon Warning -Owner $w; return }
                    $res[$f.Key] = $t.ToString('HH:mm'); continue
                }
                $res[$f.Key] = $v
            }
            if ($res.ContainsKey('ahs') -and $res.ContainsKey('ahe') -and $res.ahs -eq $res.ahe) { Show-HUMessage 'Aktive Zeit: von und bis duerfen nicht gleich sein.' -Icon Warning -Owner $w; return }
            $st.R = $res
            $w.Close()
        })
    [void]$w.ShowDialog()
    return $st.R
}

function Show-HUWuNewDialog([string]$Kind) {
    $feat = ($Kind -eq 'feature')
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" MinWidth="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="16">
        <TextBlock x:Name="txtHead" Style="{StaticResource SectionTitle}"/>
        <TextBlock x:Name="txtInfo" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <TextBlock Text="Name" Style="{StaticResource FieldLabel}" VerticalAlignment="Center"/>
            <TextBox Grid.Column="1" x:Name="txtName" Style="{StaticResource DarkTextBox}" Margin="0,3"/>
            <TextBlock Grid.Row="1" x:Name="lblPick" Style="{StaticResource FieldLabel}" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="1" Grid.Column="1" x:Name="cmbPick" Style="{StaticResource DarkComboBox}" Margin="0,3"/>
            <TextBlock Grid.Row="2" x:Name="lblMode" Style="{StaticResource FieldLabel}" VerticalAlignment="Center"/>
            <ComboBox Grid.Row="2" Grid.Column="1" x:Name="cmbMode" Style="{StaticResource DarkComboBox}" Margin="0,3"/>
            <StackPanel Grid.Row="3" Grid.Column="1" x:Name="pnlDates" Orientation="Horizontal" Margin="0,3">
                <TextBlock Text="ab" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="txtStart" Style="{StaticResource DarkTextBox}" Width="90" ToolTip="TT.MM.JJJJ"/>
                <TextBlock Text="bis" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="12,0,6,0"/>
                <TextBox x:Name="txtEnd" Style="{StaticResource DarkTextBox}" Width="90" ToolTip="TT.MM.JJJJ - letzte Gruppe"/>
                <TextBlock Text="alle" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="12,0,6,0"/>
                <TextBox x:Name="txtInt" Style="{StaticResource DarkTextBox}" Width="40" Text="7"/>
                <TextBlock Text="Tage" Style="{StaticResource FieldLabel}" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </StackPanel>
            <CheckBox Grid.Row="4" Grid.Column="1" x:Name="chkWin10" Style="{StaticResource DarkCheckBox}" Margin="0,6,0,0"
                      Content="Geraete, die kein Windows 11 koennen: neuestes Windows 10"/>
        </Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="btnOk" Content="Weiter" Width="110" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    try { $w.Owner = $script:Window } catch { }
    $st = @{ R = $null }
    if ($feat) {
        $w.Title = 'Neues Feature-Update-Profil'
        $c.txtHead.Text = 'Feature-Update-Profil (Zielversion)'
        $c.txtInfo.Text = 'Bringt die Geraete auf diese Windows-Version und haelt sie dort (kein Downgrade). Angelegt ohne Zuweisung. Wirkt nur auf Entra- bzw. Hybrid-beigetretene Geraete; im Update-Ring sollte der Feature-Aufschub 0 sein.'
        $c.lblPick.Text = 'Zielversion'; $c.lblMode.Text = 'Verfuegbar'
        foreach ($f in @($script:WuChoices.Features)) { [void]$c.cmbPick.Items.Add($f.Text) }
        if ($c.cmbPick.Items.Count) { $c.cmbPick.SelectedIndex = 0 }
        foreach ($o in 'sofort', 'ab Datum', 'gestaffelt') { [void]$c.cmbMode.Items.Add($o) }
        $c.cmbMode.SelectedIndex = 0
        $c.txtStart.Text = (Get-Date).AddDays(2).ToString('dd.MM.yyyy'); $c.txtEnd.Text = (Get-Date).AddDays(16).ToString('dd.MM.yyyy')
        $upd = { $mo = "$($c.cmbMode.SelectedItem)"; $c.pnlDates.Visibility = $(if ($mo -eq 'sofort') { 'Collapsed' } else { 'Visible' }); $c.txtEnd.IsEnabled = ($mo -eq 'gestaffelt'); $c.txtInt.IsEnabled = ($mo -eq 'gestaffelt') }
        $c.cmbMode.Add_SelectionChanged({ & $upd })
        & $upd
        $setName = { $i = $c.cmbPick.SelectedIndex; if ($i -ge 0) { $c.txtName.Text = "Feature-Update $(@($script:WuChoices.Features)[$i].Version)" } }
        $c.cmbPick.Add_SelectionChanged({ & $setName }); & $setName
    } else {
        $w.Title = 'Neues Expedite'
        $c.txtHead.Text = 'Sicherheitsupdate beschleunigen (Expedite)'
        $c.txtInfo.Text = 'Installiert das gewaehlte Update sofort, ohne Aufschub, und startet spaetestens nach der Frist neu. Angelegt ohne Zuweisung. Nach dem Ausrollen wieder entfernen.'
        $c.lblPick.Text = 'Update'; $c.lblMode.Text = 'Neustart nach'
        foreach ($e in @($script:WuChoices.Expeditable)) { [void]$c.cmbPick.Items.Add($e.Text) }
        if ($c.cmbPick.Items.Count) { $c.cmbPick.SelectedIndex = 0 }
        foreach ($o in '0 Tagen (sofort)', '1 Tag', '2 Tagen') { [void]$c.cmbMode.Items.Add($o) }
        $c.cmbMode.SelectedIndex = 1
        $c.pnlDates.Visibility = 'Collapsed'; $c.chkWin10.Visibility = 'Collapsed'
        $setName = { $i = $c.cmbPick.SelectedIndex; if ($i -ge 0) { $c.txtName.Text = "Expedite $(@($script:WuChoices.Expeditable)[$i].Name)" } }
        $c.cmbPick.Add_SelectionChanged({ & $setName }); & $setName
    }
    $c.btnOk.Add_Click({
            $i = $c.cmbPick.SelectedIndex
            $nm = $c.txtName.Text.Trim()
            if ($i -lt 0 -or -not $nm) { Show-HUMessage 'Bitte Name und Auswahl angeben.' -Icon Info -Owner $w; return }
            if ($feat) {
                $f = @($script:WuChoices.Features)[$i]
                $mo = "$($c.cmbMode.SelectedItem)"; $ro = @{ Mode = 'now' }; $tx = 'sofort'
                if ($mo -ne 'sofort') {
                    $s = ConvertFrom-HUWuDateText $c.txtStart.Text
                    if (-not $s) { Show-HUMessage 'Bitte "ab" als TT.MM.JJJJ eingeben.' -Icon Warning -Owner $w; return }
                    if ($mo -eq 'ab Datum') { $ro = @{ Mode = 'date'; Start = $s }; $tx = "ab $($s.ToString('dd.MM.yyyy'))" }
                    else {
                        $e = ConvertFrom-HUWuDateText $c.txtEnd.Text; $iv = 0; [void][int]::TryParse("$($c.txtInt.Text)", [ref]$iv)
                        if (-not $e -or $e -le $s -or $iv -lt 1) { Show-HUMessage '"bis" muss nach "ab" liegen, Abstand mindestens 1 Tag.' -Icon Warning -Owner $w; return }
                        if ($s -lt (Get-Date).Date.AddDays(2)) { Show-HUMessage 'Gestaffelt: Beginn mindestens 2 Tage in der Zukunft (Microsoft).' -Icon Warning -Owner $w; return }
                        $ro = @{ Mode = 'gradual'; Start = $s; End = $e; Interval = $iv }; $tx = "gestaffelt $($s.ToString('dd.MM.')) bis $($e.ToString('dd.MM.yyyy')), alle $iv Tage"
                    }
                }
                $st.R = [pscustomobject]@{ Name = $nm; Version = $f.Version; Rollout = $ro; Text = $tx; Win10 = [bool]$c.chkWin10.IsChecked }
            } else {
                $e = @($script:WuChoices.Expeditable)[$i]
                $st.R = [pscustomobject]@{ Name = $nm; Release = $e.Release; Text = $e.Text; Reboot = $c.cmbMode.SelectedIndex }
            }
            $w.Close()
        })
    [void]$w.ShowDialog()
    return $st.R
}

# Treiber: markierte Zeilen -> je Tenant und Richtlinie die Treiber-IDs
function Start-HUWuDriverAct([string]$Action) {
    $c = $script:Controls
    $keys = @(@($c['gridWu'].SelectedItems) | ForEach-Object { Get-HUWuCell $_ 'Key' } | Where-Object { $_ })
    if (-not $keys.Count) { Show-HUMessage 'Bitte oben die Treiber markieren (Strg/Umschalt fuer mehrere).' -Icon Info; return }
    $want = switch ($Action) { 'approve' { @('pruefen', 'ausgesetzt', 'abgelehnt') } 'suspend' { @('freigegeben') } default { @('pruefen') } }
    $drv = @(Get-HUWuInventories | ForEach-Object { @($_.Drivers) } | Where-Object { $_ -and $keys -contains "$($_.Treiber)|$($_.Version)" -and $want -contains $_.Status })
    if (-not $drv.Count) {
        Show-HUMessage $(switch ($Action) { 'approve' { 'Die markierten Treiber sind schon freigegeben.' } 'suspend' { 'Aussetzen geht nur bei freigegebenen Treibern.' } default { 'Ablehnen geht nur bei Treibern im Status pruefen (freigegebene lassen sich nur aussetzen).' } }) -Icon Info
        return
    }
    $date = Get-Date
    if ($Action -eq 'approve') {
        $d = ConvertFrom-HUWuDateText $c['txtDrvDate'].Text
        if (-not $d) { Show-HUMessage 'Bitte das Datum neben "Freigeben ab" als TT.MM.JJJJ eingeben.' -Icon Warning; return }
        $date = $(if ($d.Date -le (Get-Date).Date) { Get-Date } else { $d })
    }
    $names = Get-HUWuTenantNames
    $work = @(foreach ($gr in @($drv | Group-Object { "$($_.Tenant)|$($_.ProfilId)" })) {
            $f = @($gr.Group)[0]
            @{ Tenant = $f.Tenant; Id = $f.ProfilId; Name = "$($names[$f.Tenant]) / $($f.Profil)"; DriverIds = @($gr.Group | ForEach-Object { $_.Id }) }
        })
    $verb = switch ($Action) { 'approve' { "freigeben ab $($date.ToString('dd.MM.yyyy'))" } 'suspend' { 'aussetzen' } default { 'ablehnen' } }
    $list = (@($work | ForEach-Object { "  $($_.Name): $(@($_.DriverIds).Count) Treiber" }) -join "`n")
    if (-not (Confirm-HU -Warning "$($drv.Count) Treiber $verb`n`n$list`n`n$(if ($Action -eq 'decline') { 'Abgelehnte Treiber werden nicht installiert (spaeter freigeben moeglich).' } elseif ($Action -eq 'approve') { 'Die betroffenen Geraete installieren sie ab diesem Datum ueber Windows Update.' } else { 'Ausgesetzte Treiber werden nicht weiter verteilt.' })")) { return }
    Start-HUWuJob 'driver' $work @{ Action = $Action; Date = $date } "Treiber $verb"
}
