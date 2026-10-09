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

function Save-HUAnaTenants { Set-HUStateValue 'anaTenants' @(Get-HUCheckedTenants $script:Controls['spAnaTenants']) }

function Get-HUAnaTenantName([string]$Key) {
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
    $asg = ($Mode -ne 'cmp')
    $script:AnaMode = $(if ($asg) { 'asg' } else { 'cmp' })
    $c['pnlAnaAsg'].Visibility = $(if ($asg) { 'Visible' } else { 'Collapsed' })
    $c['pnlAnaCmp'].Visibility = $(if ($asg) { 'Collapsed' } else { 'Visible' })
    $c['gridAna'].Visibility = $c['pnlAnaAsg'].Visibility
    $c['gridCmp'].Visibility = $c['pnlAnaCmp'].Visibility
    $c['btnAnaModeAsg'].Background = Get-HUBrush $(if ($asg) { '#1976D2' } else { '#3E3E42' })
    $c['btnAnaModeCmp'].Background = Get-HUBrush $(if ($asg) { '#3E3E42' } else { '#1976D2' })
    Set-HUStateValue 'anaMode' $Mode
    Update-HUAnaHint
}

function Update-HUAnaHint {
    if ($script:AnaMode -eq 'cmp') { Update-HUCmpHint; return }
    $c = $script:Controls
    $wait = @($script:AnaWait.Keys)
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
$script:CmpGen = 0
$script:CmpMatrix = @()

function Update-HUCmpHint {
    $c = $script:Controls
    $wait = @($script:CmpWait.Keys)
    if ($wait.Count) { $c['lblAnaHint'].Text = "Lese Bestand ... warte auf $(@($wait | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ')"; return }
    if (-not $script:CmpKeys.Count) { $c['lblAnaHint'].Text = 'Tenants anhaken (mindestens 2) und Vergleichen klicken. Verglichen werden Profile, Einstellungskatalog, Administrative Vorlagen, Compliance, Wartung, Plattform-Skripte, Feature-Updates, Autopilot, Conditional Access und Apps - nach Name.'; return }
    $all = @($script:CmpMatrix)
    $d = @($all | Where-Object Diff).Count
    $vis = @(Get-HUCmpVisibleRows).Count
    $c['lblAnaHint'].Text = "$($all.Count) Eintraege, $d mit Unterschied$(if ($vis -ne $all.Count) { ", $vis angezeigt" }). Gleich = gleicher Name; 'Einstellungen abweichend' nur fuer Profile, Compliance, Feature-Updates und Autopilot. Doppelklick zeigt die abweichenden Einstellungen. Kopieren ohne Zuweisungen."
}

function Get-HUCmpVisibleRows {
    $rows = @($script:CmpMatrix)
    if ($script:Controls['chkCmpDiff'].IsChecked) { $rows = @($rows | Where-Object Diff) }
    $typ = "$($script:Controls['cmbCmpType'].SelectedItem)"
    if ($typ -and $typ -ne '(alle Arten)') { $rows = @($rows | Where-Object { $_.Typ -eq $typ }) }
    foreach ($w in @("$($script:Controls['txtCmpFilter'].Text)" -split '\s+' | Where-Object { $_ })) {
        $rows = @($rows | Where-Object { ("$($_.Typ) $($_.Name) $($_.Status)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    return @($rows | Sort-Object Typ, Name)
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
    for ($i = 0; $i -lt $keys.Count; $i++) { & $add (Get-HUAnaTenantName $keys[$i]) "T$i" (New-Object System.Windows.Controls.DataGridLength(95)) }
    & $add 'Status' 'Status' (New-Object System.Windows.Controls.DataGridLength(1, 'Star'))
    # Arten-Auswahl
    $cb = $c['cmbCmpType']; $cur = "$($cb.SelectedItem)"
    $types = @('(alle Arten)') + @($script:CmpMatrix | ForEach-Object { $_.Typ } | Sort-Object -Unique)
    if ((@($cb.Items) -join '|') -ne ($types -join '|')) {
        $script:CmpTypeBusy = $true
        $cb.Items.Clear(); foreach ($t in $types) { [void]$cb.Items.Add($t) }
        $cb.SelectedItem = $(if ($types -contains $cur) { $cur } else { '(alle Arten)' })
        $script:CmpTypeBusy = $false
    }
    $items = foreach ($m in @(Get-HUCmpVisibleRows)) {
        $o = [ordered]@{ Typ = $m.Typ; Name = $m.Name }
        for ($i = 0; $i -lt $keys.Count; $i++) { $o["T$i"] = $(if ($m.Have -contains $keys[$i]) { "$([char]0x2714)" } else { "$([char]0x2014)" }) }
        $o.Status = "$($m.Status)$(if ($m.Missing.Count -and -not $m.Copy) { ' (nur anzeigen)' })"
        $o.Ref = $m
        [pscustomobject]$o
    }
    $g.ItemsSource = @($items)
    Update-HUCmpHint
}

function Start-HUCmpRun {
    $c = $script:Controls
    $keys = @(Get-HUCheckedTenants $c['spAnaTenants'])
    if ($keys.Count -lt 2) { Show-HUMessage 'Bitte mindestens zwei Tenants anhaken.' -Icon Warning; return }
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
        $ok = Start-HUJob -Name "Cmp-$gen-$k" -Quiet -Output $c['rtbAna'] -Vars @{ TK = $k; Gen = $gen } -Code {
            $rows = @()
            try { $rows = @(Get-HUCompareInventory -TenantKey $TK -Settings $Settings) }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $TK }
            [pscustomobject]@{ __CmpDone = $TK; __CmpGen = $Gen; Rows = $rows }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__CmpDone'] }) | Select-Object -First 1
            if (-not $d -or [int]$d.__CmpGen -ne $script:CmpGen) { return }
            $script:CmpWait.Remove("$($d.__CmpDone)")
            $script:CmpData["$($d.__CmpDone)"] = @($d.Rows)
            if (-not $script:CmpWait.Count) {
                $all = @($script:CmpData.Values | ForEach-Object { $_ })
                $script:CmpMatrix = @(Get-HUCompareMatrix $all $script:CmpKeys)
                Update-HUCmpGrid
            } else { Update-HUCmpHint }
        }
        if (-not $ok) { $script:CmpWait.Remove($k) }
    }
    Update-HUCmpHint
}

function Start-HUCmpCopy {
    $c = $script:Controls
    $sel = @($c['gridCmp'].SelectedItems | ForEach-Object { $_.Ref } | Where-Object { $_ -and $_.Missing.Count })
    if (-not $sel.Count) { Show-HUMessage 'Bitte Eintraege markieren, die in einem Tenant fehlen (Strg/Shift fuer mehrere).' -Icon Info; return }
    $no = @($sel | Where-Object { -not $_.Copy })
    $todo = @($sel | Where-Object { $_.Copy })
    if (-not $todo.Count) { Show-HUMessage "Diese Arten koennen nicht kopiert werden: $(@($no | ForEach-Object { $_.Typ } | Select-Object -Unique) -join ', ').`n`nApps ueber die Bibliothek verteilen; Conditional Access, Administrative Vorlagen und Autopilot im Portal anlegen (Gruppen-IDs unterscheiden sich je Tenant)." -Icon Info; return }
    $jobs = foreach ($m in $todo) {
        $srcItem = @($m.Items)[0]
        foreach ($t in $m.Missing) { [pscustomobject]@{ Typ = $m.Typ; Name = $m.Name; From = $srcItem.Tenant; Id = $srcItem.Id; To = $t } }
    }
    $jobs = @($jobs)
    $lines = @($jobs | Select-Object -First 15 | ForEach-Object { "  $($_.Typ): $($_.Name)  ($(Get-HUAnaTenantName $_.From) -> $(Get-HUAnaTenantName $_.To))" })
    $more = if ($jobs.Count -gt 15) { "`n  ... und $($jobs.Count - 15) weitere" } else { '' }
    $skip = if ($no.Count) { "`n`nNicht kopierbar (uebersprungen): $($no.Count)" } else { '' }
    if (-not (Confirm-HU "$($jobs.Count) Kopie(n) anlegen - OHNE Zuweisungen (wirkt also noch auf keinem Geraet):`n`n$($lines -join "`n")$more$skip`n`nKennwoerter/Zertifikate in Profilen liefert Intune nicht mit - solche Profile danach im Portal pruefen.")) { return }
    $c['btnCmpCopy'].IsEnabled = $false
    $ok = Start-HUJob -Name 'CmpCopy' -Output $c['rtbAna'] -Vars @{ Jobs = $jobs } -Code {
        foreach ($j in $Jobs) {
            try {
                $id = Copy-HUIntuneObject -Typ $j.Typ -SourceTenant $j.From -SourceId $j.Id -TargetTenant $j.To -Settings $Settings
                Write-HULog -Message "$($j.Typ) '$($j.Name)' kopiert (ohne Zuweisungen)" -Level 'OK' -Tenant $j.To
            } catch { Write-HULog -Message "$($j.Typ) '$($j.Name)': $($_.Exception.Message)" -Level 'ERROR' -Tenant $j.To }
        }
    } -OnDone {
        param($Result, $Errors)
        $script:Controls['btnCmpCopy'].IsEnabled = $true
        Add-HURtbLine $script:Controls['rtbAna'] 'Fertig - Vergleich wird neu geladen.' '#90CAF9'
        Start-HUCmpRun
    }
    if (-not $ok) { $c['btnCmpCopy'].IsEnabled = $true }
}

# Doppelklick: Einstellungen der Tenants gegenueberstellen (nur abweichende)
function Show-HUCmpDetail {
    $r = $script:Controls['gridCmp'].SelectedItem
    if (-not $r -or -not $r.Ref) { return }
    $m = $r.Ref
    $items = @($m.Items | Group-Object Tenant | ForEach-Object { $_.Group[0] })
    if ($items.Count -lt 2) { Show-HUMessage "'$($m.Name)' gibt es nur in $(Get-HUAnaTenantName $items[0].Tenant) - nichts zu vergleichen." -Icon Info; return }
    if ($m.Typ -eq 'App') { Show-HUMessage 'Apps bitte unter Apps > In Intune vergleichen.' -Icon Info; return }
    $script:CmpDetailName = "$($m.Typ): $($m.Name)"
    $script:CmpDetailKeys = @($items | ForEach-Object { $_.Tenant })
    Add-HURtbLine $script:Controls['rtbAna'] "Lade Einstellungen von '$($m.Name)' ..." '#90CAF9'
    [void](Start-HUJob -Name 'CmpDetail' -Quiet -Output $script:Controls['rtbAna'] -Vars @{ Items = $items } -Code {
            $maps = @{}
            foreach ($it in $Items) {
                try { $maps[$it.Tenant] = Resolve-HUFlatMapIds -TenantKey $it.Tenant -Settings $Settings -Map (ConvertTo-HUFlatMap (Get-HUCompareObject -TenantKey $it.Tenant -Settings $Settings -Typ $it.Typ -Id $it.Id)) }
                catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $it.Tenant }
            }
            [pscustomobject]@{ __Diff = @(Get-HUCompareDiff $maps @($Items | ForEach-Object { $_.Tenant })); Count = $maps.Count }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Diff'] }) | Select-Object -First 1
            if (-not $d) { return }
            $keys = @($script:CmpDetailKeys)
            if ($d.Count -lt 2) { Add-HURtbLine $script:Controls['rtbAna'] 'Nicht in allen Tenants lesbar - kein Vergleich.' '#FFB74D'; return }
            $rows = foreach ($x in @($d.__Diff)) {
                $o = [ordered]@{ Einstellung = $x.Einstellung }
                for ($i = 0; $i -lt $keys.Count; $i++) { $o[(Get-HUAnaTenantName $keys[$i])] = $x."T$i" }
                [pscustomobject]$o
            }
            $rows = @($rows)
            if (-not $rows.Count) { Show-HUMessage "$($script:CmpDetailName)`n`nKeine Unterschiede in den Einstellungen (nur IDs, Zeitstempel oder Name/Beschreibung)." -Icon Info; return }
            Add-HURtbLine $script:Controls['rtbAna'] "$($rows.Count) abweichende Einstellung(en)" '#81C784'
            Show-HUQSTable -Title "Unterschiede - $($script:CmpDetailName)" -Objects $rows -FilePrefix 'Vergleich-Details'
        })
}

function Register-HUCmpHandlers {
    $c = $script:Controls
    $c['chkCmpDiff'].IsChecked = [bool](Get-HUStateValue 'cmpDiff' $true)
    $c['chkCmpDiff'].Add_Checked({ Set-HUStateValue 'cmpDiff' $true; Update-HUCmpGrid })
    $c['chkCmpDiff'].Add_Unchecked({ Set-HUStateValue 'cmpDiff' $false; Update-HUCmpGrid })
    $c['cmbCmpType'].Add_SelectionChanged({ if (-not $script:CmpTypeBusy) { Update-HUCmpGrid } })
    $c['txtCmpFilter'].Add_TextChanged({ Update-HUCmpGrid })
    $c['btnCmpRun'].Add_Click({ Start-HUCmpRun })
    $c['btnCmpCopy'].Add_Click({ Start-HUCmpCopy })
    $c['gridCmp'].Add_MouseDoubleClick({ Show-HUCmpDetail })
    $c['btnCmpTable'].Add_Click({
            if (-not @($script:CmpMatrix).Count) { Show-HUMessage 'Noch keine Ergebnisse.' -Icon Info; return }
            $keys = @($script:CmpKeys)
            $rows = foreach ($m in @(Get-HUCmpVisibleRows)) {
                $o = [ordered]@{ Typ = $m.Typ; Name = $m.Name }
                foreach ($k in $keys) { $o[(Get-HUAnaTenantName $k)] = $(if ($m.Have -contains $k) { 'ja' } else { 'fehlt' }) }
                $o.Status = $m.Status
                [pscustomobject]$o
            }
            Show-HUQSTable -Title 'Tenant-Vergleich' -Objects @($rows) -FilePrefix 'Tenant-Vergleich'
        })
}

function Register-HUAnaHandlers {
    $c = $script:Controls
    Update-HUAnaTenantChecks
    $kind = "$(Get-HUStateValue 'anaKind' 'group')"
    foreach ($it in @($c['cmbAnaKind'].Items)) { if ("$($it.Tag)" -eq $kind) { $c['cmbAnaKind'].SelectedItem = $it } }
    $c['chkAnaAll'].IsChecked = [bool](Get-HUStateValue 'anaAll' $true)
    $c['chkAnaAll'].Add_Checked({ Set-HUStateValue 'anaAll' $true; Update-HUAnaGrid })
    $c['chkAnaAll'].Add_Unchecked({ Set-HUStateValue 'anaAll' $false; Update-HUAnaGrid })
    $c['txtAnaFilter'].Add_TextChanged({ Update-HUAnaGrid })
    $c['cmbAnaType'].Add_SelectionChanged({ if (-not $script:AnaTypeBusy) { Update-HUAnaGrid } })
    Update-HUAnaTypes
    $c['btnAnaModeAsg'].Add_Click({ Set-HUAnaMode 'asg' })
    $c['btnAnaModeCmp'].Add_Click({ Set-HUAnaMode 'cmp' })
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
    Set-HUAnaMode "$(Get-HUStateValue 'anaMode' 'asg')"
}
