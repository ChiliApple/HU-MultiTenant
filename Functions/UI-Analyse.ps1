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
    $c['pnlAnaAsg'].Visibility = $(if ($asg) { 'Visible' } else { 'Collapsed' })
    $c['btnAnaModeAsg'].Background = Get-HUBrush $(if ($asg) { '#1976D2' } else { '#3E3E42' })
    $c['btnAnaModeCmp'].Background = Get-HUBrush $(if ($asg) { '#3E3E42' } else { '#1976D2' })
    Set-HUStateValue 'anaMode' $Mode
    if (-not $asg) { $c['lblAnaHint'].Text = 'Tenant-Vergleich folgt in der naechsten Testversion.' }
    else { Update-HUAnaHint }
}

function Update-HUAnaHint {
    $c = $script:Controls
    $wait = @($script:AnaWait.Keys)
    $n = $script:AnaRows.Count
    if ($wait.Count) {
        $c['lblAnaHint'].Text = "$($script:AnaLabel): $n Eintrag/Eintraege bisher - warte auf $(@($wait | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', ') ..."
    } elseif ($script:AnaLabel) {
        $ex = @($script:AnaRows | Where-Object { "$($_.Status)" -like 'ausgeschlossen*' }).Count
        $vis = @(Get-HUAnaVisibleRows).Count
        $c['lblAnaHint'].Text = "$($script:AnaLabel): $n Eintrag/Eintraege$(if ($vis -ne $n) { ", $vis angezeigt" })$(if ($ex) { " (davon $ex ausgeschlossen)" }). Nur lesend - Filter (Spalte Filter) werden angezeigt, aber nicht ausgewertet."
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
    Set-HUAnaMode "$(Get-HUStateValue 'anaMode' 'asg')"
}
