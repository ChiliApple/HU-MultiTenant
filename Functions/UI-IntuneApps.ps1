#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Apps", Ansicht "In Intune": vorhandene Windows-Apps der angehakten Tenants verwalten -
    Zuweisungen, Abhaengigkeiten/Ersetzungen, Eigenschaften und Symbol, Status je Geraet, Loeschen.
.DESCRIPTION
    Bei mehreren Tenants werden Apps gleichen Namens (und Typs) zusammengefasst; jede Aenderung wird in allen
    Tenants ausgefuehrt, in denen es die App gibt. Gruppen und Ziel-Apps werden je Tenant per Name gesucht.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:AppMode = 'lib'
$script:IntRaw = @{}         # TenantKey -> @{ Rows = object[]; Error = ''; Time }
$script:IntItems = @()
$script:IntCurrent = $null
$script:IntRelRows = @()
$script:IntIconFile = ''
$script:IntLoading = $false
$script:IntDetailPending = $false
$script:IntDetailKey = ''

$script:IntIntentText = @{ required = 'Erforderlich'; available = 'Verfuegbar'; uninstall = 'Deinstallieren'; availableWithoutEnrollment = 'Verfuegbar (ohne Reg.)' }
$script:IntNotifyText = @{ showAll = 'anzeigen'; showReboot = 'nur Neustart'; hideAll = 'keine' }

# ----------------------------------------------------------------------------
# Ansicht umschalten
# ----------------------------------------------------------------------------
function Set-HUAppMode([string]$Mode) {
    $c = $script:Controls
    $script:AppMode = $Mode
    $int = ($Mode -eq 'int')
    $c['pnlAppLibLeft'].Visibility = $(if ($int) { 'Collapsed' } else { 'Visible' })
    $c['pnlAppLibRight'].Visibility = $c['pnlAppLibLeft'].Visibility
    $c['pnlAppIntLeft'].Visibility = $(if ($int) { 'Visible' } else { 'Collapsed' })
    $c['pnlAppIntRight'].Visibility = $c['pnlAppIntLeft'].Visibility
    $c['btnAppModeLib'].Background = Get-HUBrush $(if ($int) { '#3E3E42' } else { '#1976D2' })
    $c['btnAppModeInt'].Background = Get-HUBrush $(if ($int) { '#1976D2' } else { '#3E3E42' })
    Set-HUStateValue 'appMode' $Mode
    if ($int) {
        if (-not $c['spIntTenants'].Children.Count) { Update-HUIntTenantChecks }
        Start-HUIntLoad
        Update-HUIntList
    }
}

function Update-HUIntTenantChecks {
    $sp = $script:Controls['spIntTenants']
    $sp.Children.Clear()
    $saved = @(Get-HUStateValue 'intTenants' @())
    if (-not $saved.Count) { $k = "$(Get-SelectedTenantKey)"; if ($k) { $saved = @($k) } elseif (@($script:Settings.tenants).Count) { $saved = @("$(@($script:Settings.tenants)[0].key)") } }
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.FontSize = 11
        $cb.Margin = [System.Windows.Thickness]::new(0, 1, 10, 1)
        $cb.IsChecked = ($saved -contains "$($t.key)")
        $cb.Add_Checked({ Save-HUIntTenants })
        $cb.Add_Unchecked({ Save-HUIntTenants })
        [void]$sp.Children.Add($cb)
    }
}

function Get-HUIntTenants { return @(Get-HUCheckedTenants $script:Controls['spIntTenants']) }

function Save-HUIntTenants {
    Set-HUStateValue 'intTenants' @(Get-HUIntTenants)
    Start-HUIntLoad
    Update-HUIntList
}

# ----------------------------------------------------------------------------
# Laden und Liste
# ----------------------------------------------------------------------------
function Start-HUIntLoad([string[]]$Keys = @(), [switch]$Force, [scriptblock]$Then = $null) {
    $keysAll = @(Get-HUIntTenants)
    $want = if (@($Keys).Count) { @($Keys) } else { $keysAll }
    if ($Force) { foreach ($k in $want) { $script:IntRaw.Remove($k) } }
    $need = @($want | Where-Object { -not $script:IntRaw[$_] })
    if (-not $need.Count) { if ($Then) { & $Then }; return }
    if (Test-HUJobRunning 'IntLoad') { return }
    $script:IntLoading = $true
    $script:IntLoadThen = $Then
    $script:Controls['lblIntState'].Text = "Lade Apps aus $($need.Count) Tenant(s) ..."
    [void](Start-HUJob -Name 'IntLoad' -Output $script:Controls['rtbApps'] -Vars @{ Need = $need } -Code {
            foreach ($k in $Need) {
                try { [pscustomobject]@{ Tenant = $k; Rows = @(Get-HUTenantAppList -TenantKey $k -Settings $Settings); Error = '' } }
                catch {
                    $m = $_.Exception.Message
                    if ($m -match '403|Forbidden|Authorization') { $m = 'Berechtigung DeviceManagementApps.ReadWrite.All (und Group.Read.All) fehlt' }
                    Write-HULog -Message $m -Level 'ERROR' -Tenant $k
                    [pscustomobject]@{ Tenant = $k; Rows = @(); Error = $m }
                }
            }
        } -OnDone {
            param($Result, $Errors)
            foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) { $script:IntRaw[$r.Tenant] = @{ Rows = @($r.Rows); Error = "$($r.Error)"; Time = Get-Date } }
            $script:IntLoading = $false
            Update-HUIntList
            $t = $script:IntLoadThen; $script:IntLoadThen = $null
            if ($t) { & $t }
            # waehrend des Ladens angehakte Tenants nachladen
            if (@(Get-HUIntTenants | Where-Object { -not $script:IntRaw[$_] }).Count) { Start-HUIntLoad }
        })
}

function Get-HUIntMerged {
    $keys = @(Get-HUIntTenants)
    $map = [ordered]@{}
    foreach ($k in $keys) {
        $e = $script:IntRaw[$k]
        if (-not $e) { continue }
        foreach ($r in @($e.Rows)) {
            $key = "$($r.Name.ToLower())|$($r.OType)"
            if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ Key = $key; Name = $r.Name; Typ = $r.Typ; OType = $r.OType; Kind = $r.Kind; Per = [ordered]@{} } }
            $map[$key].Per[$k] = $r
        }
    }
    return @($map.Values)
}

function Update-HUIntList {
    $c = $script:Controls
    $keys = @(Get-HUIntTenants)
    $script:IntItems = @(Get-HUIntMerged)
    $f = $c['txtIntFilter'].Text.Trim()
    $c['lblIntFilterHint'].Visibility = $(if ($f) { 'Collapsed' } else { 'Visible' })
    $kind = Get-HUComboTag $c['cmbIntType']
    $items = foreach ($it in ($script:IntItems | Sort-Object Name)) {
        if ($f -and $it.Name -notlike "*$f*") { continue }
        if ($kind -and $it.Kind -ne $kind) { continue }
        $rows = @($it.Per.Values)
        $vers = @($rows | ForEach-Object { $_.Version } | Where-Object { $_ } | Select-Object -Unique)
        $assigned = @($rows | Where-Object { @($_.Assignments).Count -or $_.IsAssigned }).Count
        $sub = "$($it.Typ)$(if ($vers.Count) { " | v$($vers -join '/')" })"
        if ($keys.Count -gt 1) { $sub += " | $($it.Per.Count) von $($keys.Count)" }
        $sub += $(if ($assigned) { ' | zugewiesen' } else { ' | nicht zugewiesen' })
        [pscustomobject]@{ Title = $it.Name; Sub = $sub; Key = $it.Key }
    }
    $sel = if ($script:IntCurrent) { $script:IntCurrent.Key } else { '' }
    $c['lstIntApps'].ItemsSource = @($items)
    $hit = @($items) | Where-Object { $_.Key -eq $sel } | Select-Object -First 1
    if ($hit) { $c['lstIntApps'].SelectedItem = $hit }
    $errs = @($keys | Where-Object { $script:IntRaw[$_] -and $script:IntRaw[$_].Error } | ForEach-Object { "$(Get-HUTenantDisplayName $_): $($script:IntRaw[$_].Error)" })
    $loaded = @($keys | Where-Object { $script:IntRaw[$_] }).Count
    $st = if (-not $keys.Count) { 'Oben mindestens einen Tenant anhaken.' } elseif ($loaded -lt $keys.Count) { "Lade ... ($loaded von $($keys.Count))" } else { "$(@($items).Count) von $($script:IntItems.Count) App(s)" }
    if ($errs.Count) { $st += "`nFehler: " + ($errs -join '; ') }
    $c['lblIntState'].Text = $st
    # aktuelle App mit frischen Daten neu anzeigen
    if ($script:IntCurrent) {
        $n = $script:IntItems | Where-Object { $_.Key -eq $script:IntCurrent.Key } | Select-Object -First 1
        if ($n) { $script:IntCurrent = $n; Show-HUIntApp -KeepRel } else { $script:IntCurrent = $null; Show-HUIntApp }
    }
}

# ----------------------------------------------------------------------------
# Detailansicht
# ----------------------------------------------------------------------------
function Get-HUIntTenantText([string[]]$Have, [string[]]$All) {
    if ($All.Count -le 1) { return '' }
    if ($Have.Count -eq $All.Count) { return "alle ($($All.Count))" }
    return "$($Have.Count) von $($All.Count): $(@($Have | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')"
}

function Show-HUIntApp([switch]$KeepRel) {
    $c = $script:Controls
    $it = $script:IntCurrent
    $c['pnlIntForm'].IsEnabled = [bool]$it
    foreach ($b in 'btnIntStatus', 'btnIntReloadOne', 'btnIntPortal', 'btnIntDelete') { $c[$b].IsEnabled = [bool]$it }
    if (-not $it) {
        $c['txtIntTitle'].Text = 'Links eine App waehlen'; $c['txtIntInfo'].Text = ''
        $c['gridIntAssign'].ItemsSource = $null; $c['gridIntRel'].ItemsSource = $null; $c['imgIntIcon'].Source = $null
        foreach ($n in 'txtIntName', 'txtIntPublisher', 'txtIntDesc') { $c[$n].Text = '' }
        $c['lblIntIcon'].Text = ''
        return
    }
    $keys = @($it.Per.Keys)
    $all = @(Get-HUIntTenants)
    $rows = @($it.Per.Values)
    $first = $rows[0]
    $vers = @($rows | ForEach-Object { $_.Version } | Where-Object { $_ } | Select-Object -Unique)
    $c['txtIntTitle'].Text = $it.Name
    $info = "$($it.Typ)$(if ($vers.Count) { " | Version $($vers -join ' / ')" })$(if ($first.Publisher) { " | $($first.Publisher)" })"
    $tt = Get-HUIntTenantText $keys $all
    if ($tt) { $info += " | vorhanden: $tt" }
    if (@($rows | Where-Object { $_.State -and $_.State -ne 'published' }).Count) { $info += ' | wird von Intune noch verarbeitet' }
    $c['txtIntInfo'].Text = $info
    Update-HUIntAssignGrid
    $c['pnlIntRel'].Visibility = $(if ($it.Kind -eq 'win32') { 'Visible' } else { 'Collapsed' })
    $isWin = ($it.Kind -ne 'other')
    $c['txtIntDeadline'].IsEnabled = $isWin; $c['cmbIntNotify'].IsEnabled = $isWin
    if (-not $KeepRel) {
        $c['txtIntName'].Text = $it.Name
        $c['txtIntPublisher'].Text = "$($first.Publisher)"
        $c['txtIntDesc'].Text = "$($first.Description)"
        $script:IntIconFile = ''; $c['lblIntIcon'].Text = ''
        $c['gridIntRel'].ItemsSource = $null
        $c['imgIntIcon'].Source = $null
        Start-HUIntDetail
    }
}

function Update-HUIntAssignGrid {
    $c = $script:Controls; $it = $script:IntCurrent
    if (-not $it) { return }
    $keys = @($it.Per.Keys)
    $all = @(Get-HUIntTenants)
    # Zuweisungen zusammengefasst ueber die Tenants
    $agg = [ordered]@{}
    foreach ($k in $keys) {
        foreach ($a in @($it.Per[$k].Assignments)) {
            $ak = "$($a.Key)|$($a.Intent)"
            if (-not $agg.Contains($ak)) { $agg[$ak] = @{ A = $a; T = New-Object System.Collections.Generic.List[string]; N = New-Object System.Collections.Generic.List[string]; D = New-Object System.Collections.Generic.List[string] } }
            $agg[$ak].T.Add($k)
            $nt = $(if ($script:IntNotifyText.ContainsKey($a.Notify)) { $script:IntNotifyText[$a.Notify] } else { "$($a.Notify)" }); if (-not $agg[$ak].N.Contains($nt)) { $agg[$ak].N.Add($nt) }
            if ($a.Deadline -and -not $agg[$ak].D.Contains($a.Deadline)) { $agg[$ak].D.Add($a.Deadline) }
        }
    }
    $c['gridIntAssign'].ItemsSource = @(foreach ($v in $agg.Values) {
            [pscustomobject]@{
                Ziel = $v.A.Ziel; Absicht = $(if ($script:IntIntentText.ContainsKey($v.A.Intent)) { $script:IntIntentText[$v.A.Intent] } else { $v.A.Intent })
                Hinweise = (@($v.N | Where-Object { $_ }) -join ' / '); Frist = ($v.D -join ' / ')
                Tenants = $(if ($all.Count -gt 1) { Get-HUIntTenantText @($v.T) $all } else { '' }); Key = $v.A.Key
            }
        })
}

# Symbol, Zuweisungen und Beziehungen der gewaehlten App laden (Hintergrund)
function Start-HUIntDetail {
    $it = $script:IntCurrent
    if (-not $it) { return }
    if (Test-HUJobRunning 'IntDetail') { $script:IntDetailPending = $true; return }
    $script:IntDetailPending = $false
    $per = @{}; foreach ($k in $it.Per.Keys) { $per[$k] = $it.Per[$k].Id }
    $script:IntDetailKey = $it.Key
    [void](Start-HUJob -Name 'IntDetail' -Output $null -Vars @{ Per = $per; Win32 = ($it.Kind -eq 'win32') } -Code {
            $first = @($Per.Keys)[0]
            $icon = $null
            try { $icon = Get-HUAppIconBytes -TenantKey $first -Settings $Settings -AppId $Per[$first] } catch { }
            $rel = @()
            if ($Win32) {
                $rel = @(foreach ($k in $Per.Keys) {
                        try { foreach ($r in @(Get-HUAppRelationRows -TenantKey $k -Settings $Settings -AppId $Per[$k])) { $r | Add-Member -NotePropertyName Tenant -NotePropertyValue $k -PassThru } } catch { }
                    })
            }
            $asg = @{}
            foreach ($k in $Per.Keys) { try { $asg[$k] = @(Get-HUAppAssignmentRows -TenantKey $k -Settings $Settings -AppId $Per[$k]) } catch { } }
            [pscustomobject]@{ Icon = $icon; Rel = $rel; Assign = $asg }
        } -OnDone {
            param($Result, $Errors)
            $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Rel'] })[0]
            # inzwischen andere App gewaehlt -> fuer diese neu laden
            if (-not $script:IntCurrent) { return }
            if ($script:IntDetailPending -or $script:IntCurrent.Key -ne $script:IntDetailKey) { Start-HUIntDetail; return }
            if (-not $r) { return }
            $c = $script:Controls
            foreach ($k in @($r.Assign.Keys)) { if ($script:IntCurrent.Per.Contains($k)) { $script:IntCurrent.Per[$k].Assignments = @($r.Assign[$k]) } }
            Update-HUIntAssignGrid
            if ($r.Icon) {
                try {
                    $ms = New-Object System.IO.MemoryStream(, [byte[]]$r.Icon)
                    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $ms; $bi.EndInit()
                    $c['imgIntIcon'].Source = $bi
                } catch { }
            }
            $script:IntRelRows = @($r.Rel)
            $all = @(Get-HUIntTenants)
            $agg = [ordered]@{}
            foreach ($x in $script:IntRelRows) {
                if (-not $agg.Contains($x.Key)) { $agg[$x.Key] = @{ X = $x; T = New-Object System.Collections.Generic.List[string] } }
                $agg[$x.Key].T.Add($x.Tenant)
            }
            $c['gridIntRel'].ItemsSource = @(foreach ($v in $agg.Values) { [pscustomobject]@{ Art = $v.X.Art; App = $v.X.App; Typ = $v.X.Typ; Tenants = $(if ($all.Count -gt 1) { Get-HUIntTenantText @($v.T) $all } else { '' }); Key = $v.X.Key } })
        })
}

# ----------------------------------------------------------------------------
# Aktionen (alle Tenants der gewaehlten App)
# ----------------------------------------------------------------------------
function Start-HUIntAction([string]$Title, [scriptblock]$Code, [hashtable]$Vars = @{}) {
    $it = $script:IntCurrent
    if (-not $it) { return }
    if (Test-HUJobRunning 'IntAct') { Show-HUMessage 'Es laeuft bereits eine Aktion - bitte warten.' -Icon Warning; return }
    $per = @{}; foreach ($k in $it.Per.Keys) { $per[$k] = $it.Per[$k].Id }
    $Vars.Per = $per; $Vars.OType = $it.OType; $Vars.Kind = $it.Kind; $Vars.AppName = $it.Name
    $script:IntActKeys = @($it.Per.Keys)
    Add-HURtbLine $script:Controls['rtbApps'] "=== $Title`: $($it.Name) ===" '#4FC3F7'
    [void](Start-HUJob -Name 'IntAct' -Output $script:Controls['rtbApps'] -Vars $Vars -Code $Code -OnDone {
            param($Result, $Errors)
            # betroffene Tenants neu laden, Detail neu
            Start-HUIntLoad -Keys $script:IntActKeys -Force -Then { if ($script:IntCurrent) { Show-HUIntApp } }
        })
}

function Add-HUIntAssignment {
    $c = $script:Controls
    $kind = Get-HUComboTag $c['cmbIntTarget']
    $grp = $c['txtIntGroup'].Text.Trim()
    if ($kind -in 'group', 'exclude' -and -not $grp) { Show-HUMessage 'Bitte einen Gruppennamen eingeben (oder mit der Lupe suchen).' -Icon Warning; return }
    $dl = $null
    try { $dl = ConvertTo-HUDeadline $c['txtIntDeadline'].Text } catch { Show-HUMessage $_.Exception.Message -Icon Warning; return }
    $intent = Get-HUComboTag $c['cmbIntIntent']
    $t = @{ Kind = $kind; GroupName = $grp; Intent = $intent }
    $lbl = switch ($kind) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } 'exclude' { "Ausschluss '$grp'" } default { "Gruppe '$grp'" } }
    if (-not (Confirm-HU "$($script:IntCurrent.Name)`n`nZuweisen: $lbl - $($script:IntIntentText[$intent])`nTenants: $(@($script:IntCurrent.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')`n`nAusfuehren?")) { return }
    Start-HUIntAction 'Zuweisen' -Vars @{ T = $t; Notify = (Get-HUComboTag $c['cmbIntNotify']); Deadline = $dl } -Code {
        foreach ($k in $Per.Keys) {
            try {
                $tg = @(Resolve-HUTargets -TenantKey $k -Settings $Settings -Targets @($T))
                $n = Set-HUAppAssignment -TenantKey $k -Settings $Settings -AppId $Per[$k] -AppKind $Kind -Targets $tg -Notifications $(if ($Notify) { $Notify } else { 'showAll' }) -Deadline $Deadline
                Write-HULog -Message "Zugewiesen: $($tg[0].Label) - insgesamt $n Zuweisung(en)" -Level 'OK' -Tenant $k
            } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Remove-HUIntAssignment {
    $sel = @($script:Controls['gridIntAssign'].SelectedItems)
    if (-not $sel.Count) { Show-HUMessage 'Bitte in der Tabelle die Zuweisung(en) markieren.' -Icon Info; return }
    $keys = @($sel | ForEach-Object { $_.Key } | Select-Object -Unique)
    if (-not (Confirm-HU "Zuweisung(en) entfernen:`n- $(@($sel | ForEach-Object { "$($_.Ziel) ($($_.Absicht))" }) -join "`n- ")`n`nin allen Tenants dieser App?" -Warning)) { return }
    Start-HUIntAction 'Zuweisung entfernen' -Vars @{ Keys = $keys } -Code {
        foreach ($k in $Per.Keys) {
            try { $n = Remove-HUAppAssignments -TenantKey $k -Settings $Settings -AppId $Per[$k] -Keys $Keys; Write-HULog -Message "$n Zuweisung(en) entfernt" -Level $(if ($n) { 'OK' } else { 'INFO' }) -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Add-HUIntRelation {
    $it = $script:IntCurrent
    $tag = Get-HUComboTag $script:Controls['cmbIntRelKind']
    $art, $typ = $tag -split '\|'
    $names = @(Show-HUTenantPicker -Kind 'win32' -Multi -TenantKeys @($it.Per.Keys) -Exclude @($it.Name) -Title $(if ($art -eq 'sup') { 'Welche App wird ersetzt?' } else { 'Abhaengigkeit waehlen' }) `
            -Info $(if ($art -eq 'sup') { 'Aeltere Version(en), die diese App ersetzt' } else { 'Apps, die vor dieser App installiert sein muessen' }))
    $names = @($names | Where-Object { $_ })
    if (-not $names.Count) { return }
    Start-HUIntAction $(if ($art -eq 'sup') { 'Ersetzung' } else { 'Abhaengigkeit' }) -Vars @{ Names = $names; Art = $art; Typ = $typ } -Code {
        foreach ($k in $Per.Keys) {
            try {
                $w32 = @(Get-HUTenantWin32Apps -TenantKey $k -Settings $Settings)
                $add = @(foreach ($n in $Names) {
                        $hit = @($w32 | Where-Object { $_.Name -eq $n } | Sort-Object { try { [datetime]$_.Modified } catch { [datetime]::MinValue } } -Descending)
                        if (-not $hit.Count) { Write-HULog -Message "'$n' gibt es hier nicht - uebersprungen" -Level 'WARN' -Tenant $k; continue }
                        @{ Art = $Art; TargetId = $hit[0].Id; Type = $Typ }
                    })
                if (-not $add.Count) { continue }
                $n = Set-HUAppRelations -TenantKey $k -Settings $Settings -AppId $Per[$k] -Add $add
                Write-HULog -Message "Gesetzt - insgesamt $n Beziehung(en)" -Level 'OK' -Tenant $k
            } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Remove-HUIntRelation {
    $sel = @($script:Controls['gridIntRel'].SelectedItems)
    if (-not $sel.Count) { Show-HUMessage 'Bitte in der Tabelle die Eintraege markieren.' -Icon Info; return }
    $keys = @($sel | ForEach-Object { $_.Key } | Select-Object -Unique)
    if (-not (Confirm-HU "Entfernen:`n- $(@($sel | ForEach-Object { "$($_.Art): $($_.App)" }) -join "`n- ")`n`nin allen Tenants dieser App?" -Warning)) { return }
    Start-HUIntAction 'Beziehung entfernen' -Vars @{ Keys = $keys } -Code {
        foreach ($k in $Per.Keys) {
            try { $n = Set-HUAppRelations -TenantKey $k -Settings $Settings -AppId $Per[$k] -RemoveKeys $Keys; Write-HULog -Message "Entfernt - noch $n Beziehung(en)" -Level 'OK' -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Save-HUIntProperties {
    $c = $script:Controls; $it = $script:IntCurrent
    $first = @($it.Per.Values)[0]
    $name = $c['txtIntName'].Text.Trim(); $pub = $c['txtIntPublisher'].Text.Trim(); $desc = $c['txtIntDesc'].Text.Trim()
    $v = @{
        Name = $(if ($name -and $name -ne $it.Name) { $name } else { '' })
        Publisher = $(if ($pub -and $pub -ne "$($first.Publisher)") { $pub } else { '' })
        Description = $(if ($desc -and $desc -ne "$($first.Description)") { $desc } else { '' })
        IconFile = $script:IntIconFile
    }
    if (-not ($v.Name -or $v.Publisher -or $v.Description -or $v.IconFile)) { Show-HUMessage 'Nichts geaendert.' -Icon Info; return }
    $what = @(); if ($v.Name) { $what += "Name -> $($v.Name)" }; if ($v.Publisher) { $what += 'Hersteller' }; if ($v.Description) { $what += 'Beschreibung' }; if ($v.IconFile) { $what += 'Symbol' }
    if (-not (Confirm-HU "$($it.Name)`n`nAendern: $($what -join ', ')`nTenants: $(@($it.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')`n`nSpeichern?")) { return }
    if ($v.Name) { $it.Key = "$($v.Name.ToLower())|$($it.OType)"; $script:IntCurrent = $it }
    Start-HUIntAction 'Eigenschaften' -Vars @{ V = $v } -Code {
        foreach ($k in $Per.Keys) {
            try { Update-HUAppProperties -TenantKey $k -Settings $Settings -AppId $Per[$k] -OType $OType -Name $V.Name -Description $V.Description -Publisher $V.Publisher -IconFile $V.IconFile; Write-HULog -Message 'Gespeichert' -Level 'OK' -Tenant $k }
            catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
        }
    }
}

function Remove-HUIntApp {
    $it = $script:IntCurrent
    $assigned = @($it.Per.Values | Where-Object { @($_.Assignments).Count })
    $msg = "'$($it.Name)' ($($it.Typ)) aus Intune LOESCHEN?`n`nTenants: $(@($it.Per.Keys | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ')"
    if ($assigned.Count) { $msg += "`n`nACHTUNG: in $($assigned.Count) Tenant(s) noch zugewiesen - die App wird dann nicht mehr verteilt (bereits installierte bleiben installiert)." }
    if (@($script:IntRelRows).Count) { $msg += "`n`nDie App hat Abhaengigkeiten/Ersetzungen - Intune loescht erst, wenn sie entfernt sind." }
    $msg += "`n`nDas kann nicht rueckgaengig gemacht werden."
    if (-not (Confirm-HU $msg 'Loeschen' -Warning)) { return }
    if (-not (Confirm-HU "Wirklich loeschen: '$($it.Name)' in $($it.Per.Count) Tenant(s)?" 'Loeschen' -Warning)) { return }
    Start-HUIntAction 'Loeschen' -Code {
        foreach ($k in $Per.Keys) {
            try { Remove-HUIntuneApp -TenantKey $k -Settings $Settings -AppId $Per[$k]; Write-HULog -Message "'$AppName' geloescht" -Level 'OK' -Tenant $k }
            catch {
                $m = $_.Exception.Message
                if ($m -match '(?i)relationship|dependen|supersed') { $m += ' -> zuerst Abhaengigkeiten/Ersetzungen entfernen (auch bei Apps, die von dieser abhaengen)' }
                Write-HULog -Message $m -Level 'ERROR' -Tenant $k
            }
        }
    }
    # nach dem Loeschen bleibt die Liste ohne Auswahl
    $script:IntCurrent = $null
    Show-HUIntApp
}

function Start-HUIntStatus {
    $it = $script:IntCurrent
    if (-not $it -or (Test-HUJobRunning 'IntAct')) { return }
    $per = @{}; foreach ($k in $it.Per.Keys) { $per[$k] = $it.Per[$k].Id }
    $script:IntStatusName = $it.Name
    Add-HURtbLine $script:Controls['rtbApps'] "=== Status: $($it.Name) - Intune erstellt den Bericht, das dauert etwas ===" '#4FC3F7'
    [void](Start-HUJob -Name 'IntAct' -Output $script:Controls['rtbApps'] -Vars @{ Per = $per } -Code {
            foreach ($k in $Per.Keys) {
                try {
                    $rows = @(Get-HUAppInstallStatus -TenantKey $k -Settings $Settings -AppId $Per[$k])
                    $grp = @($rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                    Write-HULog -Message "$($rows.Count) Geraet(e)$(if ($grp) { ": $grp" })" -Level 'OK' -Tenant $k
                    foreach ($r in $rows) { $o = [ordered]@{ Tenant = $k }; foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }; [pscustomobject]$o }
                } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $k }
            }
        } -OnDone {
            param($Result, $Errors)
            $rows = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Geraet'] })
            if (-not $rows.Count) { Add-HURtbLine $script:Controls['rtbApps'] 'Keine Geraetedaten (nicht zugewiesen oder Intune hat den Bericht noch nicht erstellt).' '#FFB74D'; return }
            foreach ($r in $rows) { $r.Tenant = Get-HUTenantDisplayName $r.Tenant }
            Show-HUQSTable -Title "Status $($script:IntStatusName)" -Objects $rows -FilePrefix 'App-Status'
        })
}

function Open-HUIntPortal {
    $it = $script:IntCurrent
    if (-not $it) { return }
    foreach ($k in @($it.Per.Keys | Select-Object -First 5)) {
        $t = @($script:Settings.tenants) | Where-Object { "$($_.key)" -eq $k } | Select-Object -First 1
        $tid = if ($t) { "$($t.tenantId)" } else { '' }
        Open-HUUrl "https://intune.microsoft.com/$tid/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($it.Per[$k].Id)"
    }
}

# ----------------------------------------------------------------------------
# Ereignisse
# ----------------------------------------------------------------------------
function Register-HUIntAppHandlers {
    $c = $script:Controls
    $c['btnAppModeLib'].Add_Click({ Set-HUAppMode 'lib' })
    $c['btnAppModeInt'].Add_Click({ Save-HUAppForm; Save-HUAppLib; Set-HUAppMode 'int' })
    $c['btnIntLoad'].Add_Click({ Start-HUIntLoad -Force })
    $c['txtIntFilter'].Add_TextChanged({ Update-HUIntList })
    $c['cmbIntType'].Add_SelectionChanged({ if ($script:AppMode -eq 'int') { Update-HUIntList } })
    $c['lstIntApps'].Add_SelectionChanged({
            $sel = $script:Controls['lstIntApps'].SelectedItem
            if (-not $sel) { return }
            if ($script:IntCurrent -and $script:IntCurrent.Key -eq $sel.Key) { return }
            $script:IntCurrent = $script:IntItems | Where-Object { $_.Key -eq $sel.Key } | Select-Object -First 1
            Show-HUIntApp
        })
    $c['cmbIntTarget'].Add_SelectionChanged({
            $k = Get-HUComboTag $script:Controls['cmbIntTarget']
            $script:Controls['txtIntGroup'].IsEnabled = ($k -in 'group', 'exclude')
            $script:Controls['btnIntGroupPick'].IsEnabled = $script:Controls['txtIntGroup'].IsEnabled
        })
    $c['btnIntGroupPick'].Add_Click({
            if (-not $script:IntCurrent) { return }
            $n = Show-HUGroupPicker -TenantKeys @($script:IntCurrent.Per.Keys) -Current $script:Controls['txtIntGroup'].Text.Trim() -Title 'Gruppe waehlen'
            if ($n) { $script:Controls['txtIntGroup'].Text = $n }
        })
    $c['btnIntAssignAdd'].Add_Click({ Add-HUIntAssignment })
    $c['btnIntAssignRemove'].Add_Click({ Remove-HUIntAssignment })
    $c['btnIntRelAdd'].Add_Click({ Add-HUIntRelation })
    $c['btnIntRelRemove'].Add_Click({ Remove-HUIntRelation })
    $c['btnIntIcon'].Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Bild, Symbol oder Programm|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.ico;*.exe;*.dll|Alle Dateien|*.*'
            if (-not $dlg.ShowDialog($script:Window)) { return }
            $out = Join-Path ([IO.Path]::GetTempPath()) ("hu-icon-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
            try { [void](ConvertTo-HUIconPng -Path $dlg.FileName -OutFile $out) } catch { Show-HUMessage "Symbol nicht lesbar: $($_.Exception.Message)" -Icon Warning; return }
            $script:IntIconFile = $out
            $script:Controls['lblIntIcon'].Text = "neu: $(Split-Path $dlg.FileName -Leaf)"
            try {
                $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = [Uri]::new($out); $bi.EndInit()
                $script:Controls['imgIntIcon'].Source = $bi
            } catch { }
        })
    $c['btnIntPropSave'].Add_Click({ Save-HUIntProperties })
    $c['btnIntStatus'].Add_Click({ Start-HUIntStatus })
    $c['btnIntReloadOne'].Add_Click({ if ($script:IntCurrent) { Start-HUIntLoad -Keys @($script:IntCurrent.Per.Keys) -Force -Then { if ($script:IntCurrent) { Show-HUIntApp } } } })
    $c['btnIntPortal'].Add_Click({ Open-HUIntPortal })
    $c['btnIntDelete'].Add_Click({ if ($script:IntCurrent) { Remove-HUIntApp } })
}

function Initialize-HUIntApps {
    Update-HUIntTenantChecks
    Show-HUIntApp
    Set-HUAppMode 'lib'
}
