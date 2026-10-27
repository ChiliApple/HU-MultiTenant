#Requires -Version 5.1
<#
.SYNOPSIS
    Berechtigungen: erteilte Graph-Anwendungsberechtigungen je Tenant, benoetigte Berechtigungen der
    gewaehlten Extension und Vergleich aller Tenants (Fenster XAML\PermissionsWindow.xaml).
.DESCRIPTION
    Die erteilten Berechtigungen stehen im Token (Claim "roles") - das Token wird im Hintergrund mit dem
    gespeicherten Secret geholt, ein vorheriges "Verbinden" ist nicht noetig.
    Beschreibung und Risiko kommen aus Config\extensions-registry.json, "Genutzt von" aus den geladenen Extensions.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:PermCache = @{}      # TenantKey -> @{ Roles = string[]; Error = ''; Time = datetime }
$script:PermUi = $null       # offenes Fenster (fuer die Rueckmeldung aus dem Hintergrund)
$script:PermRegistry = $null
# Schreibpaket fuer Uebertragen/Zurueckschreiben (Entra, Conditional Access): nie Standard, nur zeitweise je Tenant (045 Ue-11)
$script:HUWritePackage = @('Policy.ReadWrite.ConditionalAccess', 'Policy.ReadWrite.Authorization', 'Policy.ReadWrite.ConsentRequest', 'GroupSettings.ReadWrite.All')
$script:HUWritePkgDays = 7
$script:HUWriteRevoke = $null

function Get-HUWritePkgSince([string]$Key) {
    $v = "$(Get-HUStateValue "writePkg_$Key" '')"
    if (-not $v) { return $null }
    try { return [datetime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function Set-HUWritePkgSince([string]$Key, $When) {
    Set-HUStateValue "writePkg_$Key" $(if ($When) { ([datetime]$When).ToString('s') } else { '' })
    try { Save-HUUIState } catch { }
}

# Beim Start: Schreibpaket laenger als 7 Tage an? -> einmal am Tag erinnern (nicht blockierend fuer die Arbeit)
function Test-HUWritePkgReminder {
    $old = @(foreach ($t in @($script:Settings.tenants)) { $d = Get-HUWritePkgSince "$($t.key)"; if ($d -and ((Get-Date) - $d).TotalDays -ge $script:HUWritePkgDays) { "$($t.displayName) (seit $($d.ToString('dd.MM.yyyy')))" } })
    if (-not $old.Count) { return }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ("$(Get-HUStateValue 'writePkgReminded' '')" -eq $today) { return }
    Set-HUStateValue 'writePkgReminded' $today; try { Save-HUUIState } catch { }
    Write-HULogWarn "Entra-Schreibrechte (Uebertragen/Zurueckschreiben) seit ueber $($script:HUWritePkgDays) Tagen an: $($old -join ', ')"
    Show-HUMessage "Die Entra-Schreibrechte fuer Uebertragen/Zurueckschreiben sind seit ueber $($script:HUWritePkgDays) Tagen an:`n`n$($old -join "`n")`n`nWenn nicht mehr gebraucht: Berechtigungen > Tenant waehlen > 'Entra-Schreibrechte aus ...'." -Icon Warning
}

function Get-HUPermRegistry {
    if ($null -eq $script:PermRegistry) {
        $script:PermRegistry = @{}
        try {
            $r = (Get-Content (Join-Path $script:AppRoot 'Config\extensions-registry.json') -Raw -Encoding UTF8 | ConvertFrom-Json).permissionsRegistry
            foreach ($p in $r.PSObject.Properties) { $script:PermRegistry[$p.Name] = $p.Value }
        } catch { Write-HULogDebug "extensions-registry.json: $($_.Exception.Message)" }
    }
    return $script:PermRegistry
}

function Get-HUPermInfo([string]$Perm) {
    $e = (Get-HUPermRegistry)[$Perm]
    $risk = if ($e -and "$($e.risk)") { switch ("$($e.risk)") { 'Low' { 'niedrig' } 'Medium' { 'mittel' } 'High' { 'hoch' } default { "$($e.risk)" } } } else { '?' }
    $desc = if ($e) { "$($e.description)" } else { '' }
    # nicht im Register: nach dem Namen schaetzen und als geschaetzt kennzeichnen
    if (-not $e) {
        if ($Perm -match 'ReadWrite|Write|PrivilegedOperations') { $risk = 'hoch (geschaetzt)'; $desc = 'nicht in der Liste - nach dem Namen: schreibender Zugriff' }
        elseif ($Perm -match 'Read') { $risk = 'mittel (geschaetzt)'; $desc = 'nicht in der Liste - nach dem Namen: lesender Zugriff' }
    }
    return @{ Risk = $risk; Desc = $desc }
}

# Berechtigung -> Extensions, die sie brauchen
function Get-HUPermUsage {
    $map = @{}
    foreach ($item in @($script:ExtensionItems)) {
        foreach ($p in @($item.ExtensionObj.RequiredPermissions)) {
            if (-not "$p") { continue }
            if (-not $map.ContainsKey("$p")) { $map["$p"] = New-Object System.Collections.Generic.List[string] }
            $map["$p"].Add("$($item.Name)")
        }
    }
    return $map
}

function Get-HUTenantDisplayName([string]$Key) {
    if ($Key -eq (Get-HUMusterKey)) { return (Get-HUAnaTenantName $Key) }
    $t = @($script:Settings.tenants) | Where-Object { "$($_.key)" -eq $Key } | Select-Object -First 1
    if ($t -and "$($t.displayName)") { return "$($t.displayName)" }
    return $Key
}

# Rollen der Tenants im Hintergrund lesen; danach Update-HUPermView
function Start-HUPermFetch([string[]]$Keys, [switch]$Force) {
    $need = @($Keys | Where-Object { $Force -or -not $script:PermCache.ContainsKey($_) })
    if (-not $need.Count) { Update-HUPermView; return }
    if ($script:PermUi) { $script:PermUi.C.txtStatus.Text = "Lese Berechtigungen: $(@($need | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', ') ..." }
    Invoke-AsyncCommand -ScriptBlock {
        param($appRoot, $settingsPath, $keys, $force)
        $out = @()
        try {
            Import-Module (Join-Path $appRoot 'Core\HU.Auth.psm1') -Force -DisableNameChecking
            Import-Module (Join-Path $appRoot 'Core\HU.Graph.psm1') -Force -DisableNameChecking
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $keys) {
                $r = [pscustomobject]@{ Key = $k; Roles = @(); Error = '' }
                try {
                    if (-not (Test-HUTenantCredential -TenantKey $k -Settings $settings)) { $r.Error = 'kein Zugang auf diesem PC (Zertifikat/Secret)'; $out += $r; continue }
                    $p = @{ TenantKey = $k; Settings = $settings; ErrorAction = 'SilentlyContinue' }
                    if ($force) { $p.ForceRefresh = $true }
                    $tok = Get-GraphToken @p
                    if (-not $tok) { $r.Error = 'Anmeldung fehlgeschlagen (Secret abgelaufen oder falsch?)'; $out += $r; continue }
                    $r.Roles = @(Get-TokenPermissions -Token $tok | Sort-Object)
                } catch { $r.Error = $_.Exception.Message }
                $out += $r
            }
        } catch { return "ERR:$($_.Exception.Message)" }
        return ('RES:' + (ConvertTo-Json -InputObject @($out) -Compress -Depth 3))
    } -ArgumentList @($script:AppRoot, (Get-SettingsPath), [string[]]$need, [bool]$Force) -TimeoutSec 120 -OnComplete {
        param($result)
        $s = "$result".Trim()
        if ($s -match '^RES:') {
            try {
                $arr = $s.Substring(4) | ConvertFrom-Json
                foreach ($r in $arr) {
                    if (-not $r) { continue }
                    $script:PermCache["$($r.Key)"] = @{ Roles = @($r.Roles | Where-Object { $_ }); Error = "$($r.Error)"; Time = Get-Date }
                }
            } catch { Write-HULogDebug "Berechtigungen: Ergebnis nicht lesbar - $($_.Exception.Message)" }
        } else {
            Write-HULogWarn "Berechtigungen: $s"
        }
        Update-HUPermView
    }
}

# Fensterinhalt aus Cache aufbauen (Einzel-Tenant oder Vergleich)
function Update-HUPermView {
    $ui = $script:PermUi
    if (-not $ui -or -not $ui.Window.IsLoaded) { return }
    $c = $ui.C
    $usage = Get-HUPermUsage
    $key = $ui.Key
    $entry = $script:PermCache[$key]
    $roles = if ($entry) { @($entry.Roles) } else { @() }

    # Benoetigt von der gewaehlten Extension
    $ext = $script:SelectedExtension
    if ($ext -and @($ext.RequiredPermissions).Count) {
        $c.lblNeeded.Text = "Ben$([char]0xF6)tigt von $($ext.Name)"
        $c.gridNeeded.ItemsSource = @(foreach ($p in @($ext.RequiredPermissions)) {
                $i = Get-HUPermInfo $p
                $st = if (-not $entry) { '...' } elseif ($entry.Error) { '? (kein Token)' } elseif ($roles -contains $p) { "$([char]0x2714) erteilt" } else { "$([char]0x2716) fehlt" }
                [pscustomobject]@{ Berechtigung = $p; Risiko = $i.Risk; Status = $st; Beschreibung = $i.Desc }
            })
        $c.lblNeeded.Visibility = 'Visible'; $c.gridNeeded.Visibility = 'Visible'
    } else {
        $c.lblNeeded.Visibility = 'Collapsed'; $c.gridNeeded.Visibility = 'Collapsed'
    }

    if ($ui.Compare) {
        $keys = @($script:Settings.tenants | ForEach-Object { "$($_.key)" })
        $all = New-Object System.Collections.Generic.SortedSet[string]
        foreach ($k in $keys) { if ($script:PermCache[$k]) { foreach ($r in $script:PermCache[$k].Roles) { [void]$all.Add("$r") } } }
        foreach ($p in $usage.Keys) { [void]$all.Add("$p") }
        $rows = foreach ($p in $all) {
            $i = Get-HUPermInfo $p
            $o = [ordered]@{ Berechtigung = $p; Risiko = $i.Risk }
            foreach ($k in $keys) {
                $e = $script:PermCache[$k]
                $o[$k] = if (-not $e) { '...' } elseif ($e.Error) { '?' } elseif (@($e.Roles) -contains $p) { [string][char]0x2714 } else { '-' }
            }
            $o['Genutzt von'] = $(if ($usage[$p]) { @($usage[$p]) -join ', ' } else { '' })
            [pscustomobject]$o
        }
        $c.btnWriteOff.IsEnabled = $false; $c.btnWriteOn.IsEnabled = $false   # im Vergleich kein einzelner Tenant gewaehlt
        $c.lblGranted.Text = "Vergleich aller Tenants  ($([char]0x2714) erteilt, - nicht erteilt, ? kein Token)"
        $c.gridGranted.ItemsSource = @($rows)
        $errs = @($keys | Where-Object { $script:PermCache[$_] -and $script:PermCache[$_].Error } | ForEach-Object { "$(Get-HUTenantDisplayName $_): $($script:PermCache[$_].Error)" })
        $c.txtStatus.Text = $(if ($errs.Count) { $errs -join ' | ' } elseif (@($keys | Where-Object { -not $script:PermCache[$_] }).Count) { 'Lese ...' } else { "$($keys.Count) Tenants gelesen" })
    } else {
        $c.lblGranted.Text = "Erteilt f$([char]0xFC)r $(Get-HUTenantDisplayName $key)"
        $c.gridGranted.ItemsSource = @(foreach ($p in $roles) {
                $i = Get-HUPermInfo $p
                [pscustomobject][ordered]@{ Berechtigung = $p; Risiko = $i.Risk; Beschreibung = $i.Desc; 'Genutzt von' = $(if ($usage[$p]) { @($usage[$p]) -join ', ' } else { '' }) }
            })
        $wp = @($script:HUWritePackage | Where-Object { $roles -contains $_ })
        $since = Get-HUWritePkgSince $key
        $wpTxt = if (-not $entry -or $entry.Error) { '' } elseif ($wp.Count) { " | Entra-Schreibrechte AN ($($wp.Count)/$($script:HUWritePackage.Count))$(if ($since) { " seit $($since.ToString('dd.MM. HH:mm'))" })" } else { ' | Entra-Schreibrechte aus' }
        $c.txtStatus.Text = $(if (-not $entry) { 'Lese ...' } elseif ($entry.Error) { $entry.Error } else { "$($roles.Count) Berechtigungen, gelesen $($entry.Time.ToString('HH:mm'))$wpTxt" })
        if ($entry -and -not $entry.Error -and -not $wp.Count -and $since) { Set-HUWritePkgSince $key $null }
        # Knoepfe nur, wenn es etwas zu tun gibt (Stand unbekannt: beide frei)
        $known = ($entry -and -not $entry.Error)
        $c.btnWriteOff.IsEnabled = (-not $known) -or [bool]$wp.Count
        $c.btnWriteOn.IsEnabled = (-not $known) -or ($wp.Count -lt $script:HUWritePackage.Count)
        $c.btnWriteOff.ToolTip = $(if ($known -and -not $wp.Count) { "Entra-Schreibrechte sind nicht erteilt - nichts zu entziehen:`n$($script:HUWritePackage -join "`n")" } else { "Genau diese 4 Rechte wieder entziehen (Admin-Anmeldung im Browser):`n$($script:HUWritePackage -join "`n")`n`nAndere Schreibrechte (Intune, Benutzer, Apps) bleiben." })

    }
}

# Schreibpaket entziehen: Admin-Anmeldung im Browser, dann genau diese Rechte entfernen (Remove-HUAppPermissions)
function Start-HUWritePkgRevoke([string]$Key) {
    $ui = $script:PermUi
    $t = @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $Key })[0]
    if (-not $t -or -not "$($t.appId)" -or -not "$($t.tenantId)") { Show-HUMessage 'Tenant-ID bzw. Anwendungs-ID fehlen.' -Icon Warning; return }
    if ($script:HUWriteRevoke) { Show-HUMessage 'Eine Anmeldung zum Entziehen laeuft schon - bitte im Browser abschliessen.' -Icon Info; return }
    if (-not (Confirm-HU -Warning "Entra-Schreibrechte fuer $(Get-HUTenantDisplayName $Key) entziehen?`n`n$($script:HUWritePackage -join "`n")`n`nAndere Schreibrechte (Intune, Benutzer, Apps) bleiben. Es oeffnet sich der Browser zur Admin-Anmeldung (Global Admin oder Privileged Role Admin)." -Owner $(if ($ui) { $ui.Window } else { $null }))) { return }
    $ctx = $null
    try { $ctx = Start-HUAdminLogin -TenantId "$($t.tenantId)" } catch { Show-HUMessage "Anmeldung nicht gestartet: $($_.Exception.Message)" -Icon Error; return }
    if ($ui) { $ui.C.txtStatus.Text = 'Bitte im Browser als Admin anmelden ...' }
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:HUWriteRevoke = @{ Ctx = $ctx; Timer = $tm; Key = $Key; AppId = "$($t.appId)" }
    $tm.Add_Tick({
            $r = $script:HUWriteRevoke
            if (-not $r) { return }
            $res = $null
            try { $res = Receive-HUAdminLogin -Context $r.Ctx } catch { $res = [pscustomobject]@{ Ok = $false; Error = "$($_.Exception.Message)" } }
            if ($null -eq $res) { return }
            $r.Timer.Stop(); $script:HUWriteRevoke = $null
            if (-not $res.Ok) { Show-HUMessage "Nicht entzogen: $($res.Error)" -Icon Error; return }
            if (-not (Test-HUAdminCanGrant $res)) { Show-HUMessage 'Das angemeldete Konto darf keine App-Rechte entziehen (Global Admin oder Privileged Role Admin noetig). Nichts geaendert.' -Icon Warning; return }
            $removed = @()
            try { $removed = @(Remove-HUAppPermissions -Login $res -AppId $r.AppId -Permissions $script:HUWritePackage) }
            catch { Show-HUMessage "Entziehen fehlgeschlagen: $(Get-HUSetupErrorText $_)" -Icon Error; return }
            Set-HUWritePkgSince $r.Key $null
            Write-HULog -Message "Entra-Schreibrechte entzogen ($(Get-HUTenantDisplayName $r.Key)): $(if ($removed.Count) { $removed -join ', ' } else { 'waren nicht erteilt' }) (durch $($res.Upn))" -Level 'OK'
            $script:PermCache.Remove($r.Key)
            if ($script:PermUi) { Update-HUPermView; Start-HUPermFetch -Keys @($r.Key) -Force }
            Show-HUMessage "$(if ($removed.Count) { "Entzogen: $($removed -join ', ')." } else { 'Die Entra-Schreibrechte waren nicht erteilt - nichts zu tun.' })`n`nEin schon geholtes Token kann sie noch bis zu einer Stunde enthalten; Schreiben wird danach abgelehnt." -Icon Info
        })
    $tm.Start()
}

function Show-HUPermissions([string]$TenantKey = '') {
    $d = New-HUWindow 'PermissionsWindow'
    $w = $d.Window; $c = $d.C
    # Gross genug oeffnen, dass Beschreibung und 'Genutzt von' ohne Scrollen lesbar sind (an Bildschirm angepasst)
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w.Width = [Math]::Max($w.MinWidth, [Math]::Min(1700, [Math]::Floor($wa.Width * 0.92)))
        $w.Height = [Math]::Max($w.MinHeight, [Math]::Min(1000, [Math]::Floor($wa.Height * 0.9)))
    } catch { }
    $script:PermUi = @{ Window = $w; C = $c; Key = ''; Compare = $false }
    foreach ($t in @($script:Settings.tenants)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = "$($t.displayName)"; $it.Tag = "$($t.key)"
        $it.Style = $w.FindResource('DarkComboBoxItem')
        [void]$c.cmbTenant.Items.Add($it)
    }
    if (-not $c.cmbTenant.Items.Count) { Show-HUMessage 'Noch keine Tenants angelegt (Einstellungen > Tenants).' -Icon Warning; return }
    $sel = 0
    for ($i = 0; $i -lt $c.cmbTenant.Items.Count; $i++) { if ("$($c.cmbTenant.Items[$i].Tag)" -eq $TenantKey) { $sel = $i } }

    # Spaltenkoepfe im Vergleich: Anzeigename statt Schluessel
    $c.gridGranted.Add_AutoGeneratingColumn({
            param($s, $e)
            $h = "$($e.PropertyName)"
            if ($h -notin 'Berechtigung', 'Risiko', 'Beschreibung', 'Genutzt von') { $e.Column.Header = Get-HUTenantDisplayName $h }
        })
    $c.cmbTenant.Add_SelectionChanged({
            $script:PermUi.Key = "$($script:PermUi.C.cmbTenant.SelectedItem.Tag)"
            $script:PermUi.Compare = $false
            Start-HUPermFetch -Keys @($script:PermUi.Key)
        })
    $c.btnReload.Add_Click({
            $keys = if ($script:PermUi.Compare) { @($script:Settings.tenants | ForEach-Object { "$($_.key)" }) } else { @($script:PermUi.Key) }
            foreach ($k in $keys) { $script:PermCache.Remove($k) }
            Update-HUPermView
            Start-HUPermFetch -Keys $keys -Force
        })
    $c.btnCompare.Add_Click({
            $script:PermUi.Compare = $true
            Update-HUPermView
            Start-HUPermFetch -Keys @($script:Settings.tenants | ForEach-Object { "$($_.key)" })
        })
    $c.btnEntra.Add_Click({
            $t = @($script:Settings.tenants) | Where-Object { "$($_.key)" -eq $script:PermUi.Key } | Select-Object -First 1
            $appId = "$($t.appId)"
            Open-HUUrl $(if ($appId -match '^[0-9a-fA-F-]{36}$') { "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$appId" } else { 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade' })
        })
    $c.btnGrant.Add_Click({
            $ui = $script:PermUi
            $k = $ui.Key
            $pre = @(); if ($script:SelectedExtension) { $pre = @($script:SelectedExtension.RequiredPermissions | Where-Object { $_ }) }
            $added = @(Show-HUTenantSetupDialog -TenantKey $k -Preselect $pre -Owner $ui.Window)
            if ($script:PermUi) {
                $script:PermCache.Remove($k)
                Update-HUPermView
                if ($added.Count) { $script:PermUi.C.txtStatus.Text = "Erteilt: $($added -join ', ') - erscheint nach etwa 1 Minute im Token (dann Neu lesen)." }
                else { Start-HUPermFetch -Keys @($k) -Force }
            }
        })
    $c.btnWriteOn.Add_Click({
            $ui = $script:PermUi; $k = $ui.Key
            if (-not (Confirm-HU "Entra-Schreibrechte fuer Uebertragen/Zurueckschreiben NUR fuer $(Get-HUTenantDisplayName $k) erteilen?`n`n$($script:HUWritePackage -join "`n")`n`nDamit kann die App Conditional Access und Entra-Einstellungen aendern. Andere Schreibrechte bleiben wie sie sind. Nach der Arbeit bitte wieder 'Entra-Schreibrechte aus ...' (Erinnerung nach $($script:HUWritePkgDays) Tagen)." -Warning -Owner $ui.Window)) { return }
            $added = @(Show-HUTenantSetupDialog -TenantKey $k -Preselect $script:HUWritePackage -Owner $ui.Window)
            if (-not $script:PermUi) { return }
            $have = @(); if ($script:PermCache[$k] -and -not $script:PermCache[$k].Error) { $have = @($script:PermCache[$k].Roles) }
            if ($added.Count -or -not @($script:HUWritePackage | Where-Object { $have -notcontains $_ }).Count) { Set-HUWritePkgSince $k (Get-Date) }
            $script:PermCache.Remove($k); Update-HUPermView
            if ($added.Count) { $script:PermUi.C.txtStatus.Text = "Erteilt: $($added -join ', ') - erscheint nach etwa 1 Minute im Token (dann Neu lesen)." } else { Start-HUPermFetch -Keys @($k) -Force }
        })
    $c.btnWriteOff.Add_Click({
            $k = $script:PermUi.Key; $e = $script:PermCache[$k]
            if ($e -and -not $e.Error -and -not @($script:HUWritePackage | Where-Object { @($e.Roles) -contains $_ }).Count) { Show-HUMessage "Fuer $(Get-HUTenantDisplayName $k) sind keine Entra-Schreibrechte erteilt - nichts zu entziehen." -Icon Info -Owner $script:PermUi.Window; return }
            Start-HUWritePkgRevoke $k
        })
    $c.btnClose.Add_Click({ $script:PermUi.Window.Close() })
    $w.Add_Loaded({ Update-HUPermView })
    $w.Add_Closed({ $script:PermUi = $null })

    $c.cmbTenant.SelectedIndex = $sel   # loest das Lesen aus
    [void]$w.ShowDialog()
}
