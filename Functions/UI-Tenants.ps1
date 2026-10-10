#Requires -Version 5.1
<#
.SYNOPSIS
    Tenant-Auswahl, Verbinden/Trennen, "Secret speichern" und Secret-Ablauf (Anzeige, Pruefung, Cache).
.DESCRIPTION
    Secret-Ablauf:
      - Quelle 1: Graph (Application.Read.All) - GET /applications(appId=...) -> passwordCredentials.
                  Das verwendete Secret wird ueber die ersten 3 Zeichen (hint) erkannt (HU.Auth: Get-AppSecretExpiry).
      - Quelle 2: manuell eingetragenes Datum (Einstellungen > Tenants > "Secret gueltig bis", settings.json: secretExpires).
      - Cache: %APPDATA%\HU-MultiTenant\secret-expiry.json (Anzeige auch ohne Verbindung).
      - Pruefung: bei jedem Verbinden, beim Start im Hintergrund (hoechstens 1x je 20 h), Einstellungen > "Alle Secrets pruefen".
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:SecretCachePath = [System.IO.Path]::Combine($env:APPDATA, 'HU-MultiTenant', 'secret-expiry.json')
$script:SecretCache = $null
$script:KeyIcon = [char]::ConvertFromUtf32(0x1F511)

# ============================================================================
# Secret-Ablauf: Cache + Bewertung
# ============================================================================
function Get-HUSecretCache {
    if ($null -eq $script:SecretCache) {
        $script:SecretCache = @{}
        $j = Read-HUJsonFile $script:SecretCachePath
        if ($j) { foreach ($p in $j.PSObject.Properties) { $script:SecretCache[$p.Name] = $p.Value } }
    }
    return $script:SecretCache
}
function Set-HUSecretCacheEntry([string]$TenantKey, $Result) {
    $cache = Get-HUSecretCache
    $old = $cache[$TenantKey]
    $e = [pscustomobject][ordered]@{
        Status  = "$($Result.Status)"
        EndDate = $(if ($Result.EndDate) { ([datetime]$Result.EndDate).ToString('s') } elseif ($old -and $Result.Status -ne 'OK') { "$($old.EndDate)" } else { '' })
        Matched = [bool]$Result.Matched
        Checked = (Get-Date).ToString('s')
        Error   = "$($Result.Error)"
    }
    # Fehler beim Pruefen: altes Ergebnis (Datum) behalten
    if ($Result.Status -ne 'OK' -and $old -and $old.PSObject.Properties['Matched']) { $e.Matched = [bool]$old.Matched }
    $cache[$TenantKey] = $e
    try {
        $o = [ordered]@{}; foreach ($k in ($cache.Keys | Sort-Object)) { $o[$k] = $cache[$k] }
        Write-HUJsonFile -Path $script:SecretCachePath -Object ([pscustomobject]$o) -Depth 4
    } catch { Write-Verbose "[Secret] Cache nicht gespeichert: $_" }
}

function Get-HUSecretWarnDays {
    try { if ($script:Settings.ui.PSObject.Properties['secretWarnDays'] -and [int]$script:Settings.ui.secretWarnDays -gt 0) { return [int]$script:Settings.ui.secretWarnDays } } catch { }
    return 30
}

# Bewertung fuer die Anzeige: Text, Kurztext, Farbe, Tooltip, Tage
function Get-HUSecretInfo([string]$TenantKey) {
    $r = [pscustomobject]@{ Days = $null; EndDate = $null; Source = ''; Text = ''; Short = ''; Color = '#858585'; Tooltip = ''; Level = 'Unknown' }
    if (-not $TenantKey) { return $r }
    $cache = Get-HUSecretCache
    $e = $cache[$TenantKey]
    $tenant = $script:Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    $manual = $null
    if ($tenant -and $tenant.PSObject.Properties['secretExpires'] -and "$($tenant.secretExpires)") {
        try { $manual = [datetime]::Parse("$($tenant.secretExpires)", [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    $end = $null
    if ($e -and "$($e.EndDate)") { try { $end = [datetime]::Parse("$($e.EndDate)", [Globalization.CultureInfo]::InvariantCulture); $r.Source = 'Graph' } catch { } }
    if (-not $end -and $manual) { $end = $manual; $r.Source = 'manuell' }
    $checked = if ($e -and "$($e.Checked)") { try { ([datetime]"$($e.Checked)").ToString('dd.MM.yyyy HH:mm') } catch { '' } } else { '' }

    if (-not $end) {
        $r.Text = "$($script:KeyIcon) Secret-Ablauf unbekannt"
        $why = if ($e -and $e.Status -eq 'NoPermission') { 'Der App fehlt die Berechtigung Application.Read.All (Application).' }
               elseif ($e -and "$($e.Error)") { "Letzte Pruefung: $($e.Error)" } else { 'Noch nicht geprueft - wird beim Verbinden ermittelt.' }
        $r.Tooltip = "$why`nAlternativ: Einstellungen > Tenants > 'Secret gueltig bis' manuell eintragen."
        return $r
    }
    $days = [int][Math]::Floor(($end.Date - (Get-Date).Date).TotalDays)
    $r.Days = $days; $r.EndDate = $end
    $warn = Get-HUSecretWarnDays
    if ($days -lt 0) { $r.Level = 'Expired'; $r.Color = '#F44336'; $r.Text = "$($script:KeyIcon) Secret ABGELAUFEN seit $($end.ToString('dd.MM.yyyy'))"; $r.Short = 'abgelaufen' }
    else {
        $r.Text = "$($script:KeyIcon) Secret gueltig bis $($end.ToString('dd.MM.yyyy')) ($days Tage)"
        $r.Short = "$days T"
        if ($days -le 7) { $r.Level = 'Critical'; $r.Color = '#F44336' }
        elseif ($days -le $warn) { $r.Level = 'Warn'; $r.Color = '#FF9800' }
        else { $r.Level = 'OK'; $r.Color = '#8BC34A' }
    }
    $src = if ($r.Source -eq 'manuell') { 'manuell eingetragen (Einstellungen)' }
           elseif ($e.Matched) { 'Graph - genau das gespeicherte Secret (erkannt an den ersten 3 Zeichen)' }
           else { 'Graph - naechstes ablaufendes Secret der App (gespeichertes Secret nicht eindeutig erkannt)' }
    $r.Tooltip = "Quelle: $src$(if ($checked) { "`nGeprueft: $checked" })`nWarnung ab $warn Tagen (Einstellungen > Allgemein)."
    return $r
}

# Pruefen (synchron, nach erfolgreichem Verbinden). Fehler werden nur protokolliert.
function Update-HUSecretExpiry([string]$TenantKey, [string]$Token) {
    if (-not $TenantKey -or -not $Token) { return }
    try {
        $res = Get-AppSecretExpiry -TenantKey $TenantKey -Settings $script:Settings -Token $Token
        Set-HUSecretCacheEntry $TenantKey $res
        switch ($res.Status) {
            'OK' { if ($res.EndDate) { Write-HULogInfo "Secret gueltig bis $(([datetime]$res.EndDate).ToString('dd.MM.yyyy'))$(if (-not $res.Matched) { ' (naechstes ablaufendes Secret der App)' })" -Tenant $TenantKey } }
            'NoPermission' { Write-HULogDebug 'Secret-Ablauf: Application.Read.All fehlt - Datum kann manuell in den Einstellungen eingetragen werden.' -Tenant $TenantKey }
            default { Write-HULogDebug "Secret-Ablauf nicht ermittelbar: $($res.Error)" -Tenant $TenantKey }
        }
    } catch { Write-HULogDebug "Secret-Ablauf: $($_.Exception.Message)" -Tenant $TenantKey }
    Update-HUSecretDisplay
}

# Alle Tenants im Hintergrund pruefen (Start / Einstellungen). -Force: auch wenn kuerzlich geprueft.
function Start-HUSecretCheckAll([switch]$Force, [scriptblock]$Done = $null) {
    $cache = Get-HUSecretCache
    $keys = @()
    foreach ($t in @($script:Settings.tenants)) {
        if (-not "$($t.tenantId)" -or "$($t.tenantId)" -match '<') { continue }
        $e = $cache[$t.key]
        $fresh = $false
        if (-not $Force -and $e -and "$($e.Checked)") { try { $fresh = (((Get-Date) - [datetime]"$($e.Checked)").TotalHours -lt 20) } catch { } }
        if (-not $fresh) { $keys += "$($t.key)" }
    }
    if (-not $keys.Count) { if ($Done) { & $Done }; return }
    $script:SecretCheckDone = $Done
    Write-HULogDebug "Secret-Ablauf wird im Hintergrund geprueft: $($keys -join ', ')"
    Invoke-AsyncCommand -ScriptBlock {
        param($appRoot, $settingsPath, $keys)
        $out = @()
        try {
            Import-Module (Join-Path $appRoot 'Core\HU.Auth.psm1') -Force -DisableNameChecking
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $keys) {
                $r = [pscustomobject]@{ Key = $k; Status = 'Error'; EndDate = ''; Matched = $false; Error = '' }
                try {
                    if (-not (Get-StoredCredential -TenantKey $k -Settings $settings)) { $r.Error = 'kein Secret gespeichert'; $out += $r; continue }
                    $tok = Get-GraphToken -TenantKey $k -Settings $settings -ErrorAction SilentlyContinue
                    if (-not $tok) { $r.Error = 'Anmeldung fehlgeschlagen (Secret abgelaufen oder falsch?)'; $out += $r; continue }
                    $x = Get-AppSecretExpiry -TenantKey $k -Settings $settings -Token $tok
                    $r.Status = $x.Status; $r.Matched = $x.Matched; $r.Error = $x.Error
                    if ($x.EndDate) { $r.EndDate = ([datetime]$x.EndDate).ToString('s') }
                } catch { $r.Error = $_.Exception.Message }
                $out += $r
            }
        } catch { return "ERR:$($_.Exception.Message)" }
        return ('RES:' + (ConvertTo-Json -InputObject @($out) -Compress))
    } -ArgumentList @($script:AppRoot, (Get-SettingsPath), [string[]]$keys) -TimeoutSec 120 -OnComplete {
        param($result)
        $s = "$result".Trim()
        if ($s -match '^RES:') {
            try {
                $arr = $s.Substring(4) | ConvertFrom-Json
                foreach ($r in $arr) {
                    if (-not $r) { continue }
                    if ($r.Status -ne 'OK' -and $r.Error -match 'kein Secret') { continue }
                    $res = [pscustomobject]@{ Status = $r.Status; EndDate = $(if ($r.EndDate) { [datetime]$r.EndDate } else { $null }); Matched = $r.Matched; Error = $r.Error }
                    Set-HUSecretCacheEntry $r.Key $res
                    if ($r.Status -ne 'OK' -and $r.Error -match 'Anmeldung') { Write-HULogWarn "Secret-Pruefung: $($r.Error)" -Tenant $r.Key }
                }
            } catch { Write-HULogDebug "Secret-Pruefung: Ergebnis nicht lesbar - $($_.Exception.Message)" }
        } else { Write-HULogDebug "Secret-Pruefung: $s" }
        Update-HUSecretDisplay -LogWarnings
        if ($script:SecretCheckDone) { try { & $script:SecretCheckDone } catch { } ; $script:SecretCheckDone = $null }
    }
}

function Update-HUSecretDisplay([switch]$LogWarnings) {
    $c = $script:Controls
    $info = Get-HUSecretInfo (Get-SelectedTenantKey)
    $c['txtSecretExpiry'].Text = $info.Text
    $c['txtSecretExpiry'].Foreground = Get-HUBrush $info.Color
    $c['txtSecretExpiry'].ToolTip = $info.Tooltip
    $qk = Get-HUQSTenantKey
    if ($qk) {
        $qi = Get-HUSecretInfo $qk
        $c['txtQSSecret'].Text = $(if ($qi.EndDate) { "Secret: $($qi.Short)" } else { '' })
        $c['txtQSSecret'].Foreground = Get-HUBrush $qi.Color
        $c['txtQSSecret'].ToolTip = $qi.Text + "`n" + $qi.Tooltip
    }
    # Warnung in der Titelleiste
    $bad = @()
    foreach ($t in @($script:Settings.tenants)) {
        $i = Get-HUSecretInfo $t.key
        if ($i.Level -in 'Warn', 'Critical', 'Expired') { $bad += [pscustomobject]@{ Name = "$($t.displayName)"; Info = $i } }
    }
    if ($bad.Count) {
        $worst = if (@($bad | Where-Object { $_.Info.Level -in 'Critical', 'Expired' }).Count) { '#F44336' } else { '#FF9800' }
        $c['txtSecretWarning'].Text = "$([char]0x26A0) $($bad.Count) Secret$(if ($bad.Count -gt 1) { 's' }) $(if ($bad.Count -gt 1) { 'laufen' } else { 'laeuft' }) bald ab"
        $c['txtSecretWarning'].Foreground = Get-HUBrush $worst
        $c['txtSecretWarning'].ToolTip = (($bad | ForEach-Object { "$($_.Name): $($_.Info.Text -replace '^\S+\s', '')" }) -join "`n") + "`n`nKlick: Einstellungen > Tenants"
        $c['txtSecretWarning'].Visibility = 'Visible'
        if ($LogWarnings) { foreach ($b in $bad) { Write-HULogWarn "$($b.Name): $($b.Info.Text -replace '^\S+\s', '')" } }
    } else { $c['txtSecretWarning'].Visibility = 'Collapsed' }
    Update-HUTenantItemSuffixes
}

# ============================================================================
# Tenant-Auswahllisten (Hauptleiste + Quick Script)
# ============================================================================
function Get-HUTenantStatusColor([string]$TenantKey) {
    $st = Get-TenantStatus -TenantKey $TenantKey
    if (-not $st) { return '#858585' }
    if ($st.isConnected -and $st.permissionsOk -ne $false) { return '#4CAF50' }
    if ($st.permissionsOk -eq $false) { return '#FFEB3B' }
    if ($st.lastChecked) { return '#D32F2F' }
    return '#858585'
}

function New-HUTenantItem($Tenant) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = [string][char]0x25CF
    $b.FontSize = 13
    $b.VerticalAlignment = 'Center'
    $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $b.Foreground = Get-HUBrush (Get-HUTenantStatusColor $Tenant.key)
    $tx = New-Object System.Windows.Controls.TextBlock
    $dom = if ($Tenant.PSObject.Properties['domain'] -and "$($Tenant.domain)") { " ($($Tenant.domain))" } else { '' }
    $tx.Text = "$($Tenant.displayName)$dom"
    $tx.VerticalAlignment = 'Center'
    $sfx = New-Object System.Windows.Controls.TextBlock
    $sfx.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $sfx.FontSize = 10
    $sfx.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($b); [void]$sp.Children.Add($tx); [void]$sp.Children.Add($sfx)
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $sp
    $item.Tag = "$($Tenant.key)"
    return $item
}

# Kurzhinweis "Secret: 12 T" an den Eintraegen (nur wenn Warnschwelle erreicht)
function Update-HUTenantItemSuffixes {
    foreach ($cmbName in @('cmbTenant', 'cmbQSTenant')) {
        $cmb = $script:Controls[$cmbName]
        if (-not $cmb) { continue }
        foreach ($it in $cmb.Items) {
            if (-not ($it -is [System.Windows.Controls.ComboBoxItem]) -or -not $it.Tag) { continue }
            $i = Get-HUSecretInfo "$($it.Tag)"
            $sfx = $it.Content.Children[2]
            if ($i.Level -in 'Warn', 'Critical', 'Expired') { $sfx.Text = "$($script:KeyIcon) $($i.Short)"; $sfx.Foreground = Get-HUBrush $i.Color }
            else { $sfx.Text = '' }
            $it.Content.Children[0].Foreground = Get-HUBrush (Get-HUTenantStatusColor "$($it.Tag)")
        }
    }
}

function Get-SelectedTenantKey {
    $sel = $script:Controls['cmbTenant'].SelectedItem
    if ($sel -and $sel.Tag) { return "$($sel.Tag)" }
    return $null
}
function Get-HUQSTenantKey {
    $sel = $script:Controls['cmbQSTenant'].SelectedItem
    if ($sel -and $sel.Tag) { return "$($sel.Tag)" }
    return $null
}

function Select-HUComboTag($Combo, [string]$Key) {
    if (-not $Key) { return $false }
    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ("$($Combo.Items[$i].Tag)" -eq $Key) { $Combo.SelectedIndex = $i; return $true }
    }
    return $false
}

# Beide Listen neu aufbauen (nach Start, Verbinden, Einstellungen)
function Update-TenantDropdown {
    $script:TenantSelectBusy = $true
    try {
        $mainKey = Get-SelectedTenantKey
        $qsKey = Get-HUQSTenantKey
        foreach ($cmbName in @('cmbTenant', 'cmbQSTenant')) {
            $cmb = $script:Controls[$cmbName]
            $cmb.Items.Clear()
            foreach ($t in @($script:Settings.tenants)) { [void]$cmb.Items.Add((New-HUTenantItem $t)) }
        }
        if (-not $mainKey) { $mainKey = Get-HUStateValue 'lastTenantKey' }
        if (-not $mainKey) { $mainKey = Get-CurrentTenantKey }
        if (-not (Select-HUComboTag $script:Controls['cmbTenant'] $mainKey) -and $script:Controls['cmbTenant'].Items.Count) { $script:Controls['cmbTenant'].SelectedIndex = 0 }
        if (-not $qsKey) { $qsKey = Get-HUStateValue 'qsTenantKey' }
        if (-not $qsKey) { $qsKey = Get-SelectedTenantKey }
        if (-not (Select-HUComboTag $script:Controls['cmbQSTenant'] $qsKey) -and $script:Controls['cmbQSTenant'].Items.Count) { $script:Controls['cmbQSTenant'].SelectedIndex = 0 }
    } finally { $script:TenantSelectBusy = $false }
    $k = Get-SelectedTenantKey
    # Auswahl hat sich (z. B. nach Einstellungen) geaendert -> alten Token nicht weiterverwenden
    if ($k -ne $mainKey) { $script:CurrentToken = $null; $script:Controls['txtPermissionStatus'].Text = '' }
    if ($k) { Set-CurrentTenant -TenantKey $k; Update-TenantStatus -TenantKey $k }
    Update-PersistCredentialCheckbox
    Update-HUSecretDisplay
}

function Update-TenantStatus([string]$TenantKey) {
    $ctrl = $script:Controls['txtTenantStatus']
    if (-not $TenantKey) { $ctrl.Text = ''; return }
    $status = Get-TenantStatus -TenantKey $TenantKey
    if ($status -and $status.isConnected) { $ctrl.Text = 'Verbunden'; $ctrl.Foreground = Get-HUBrush '#4CAF50' }
    elseif ($status -and ("$($status.errorMessage)" -like '*403*' -or $status.permissionsOk -eq $false)) { $ctrl.Text = 'Berechtigungen fehlen'; $ctrl.Foreground = Get-HUBrush '#FFEB3B' }
    elseif ($status -and $status.lastChecked) { $ctrl.Text = 'Nicht verbunden'; $ctrl.Foreground = Get-HUBrush '#D32F2F' }
    else { $ctrl.Text = 'Nicht geprueft'; $ctrl.Foreground = Get-HUBrush '#858585' }
}

# ============================================================================
# "Secret speichern" je Tenant (persistCredential in settings.json)
# ============================================================================
function Get-TenantPersistCredential([string]$TenantKey) {
    $tenant = $script:Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    if (-not $tenant -or $null -eq $tenant.PSObject.Properties['persistCredential']) { return $true }
    return [bool]$tenant.persistCredential
}
function Set-TenantPersistCredential([string]$TenantKey, [bool]$Persist) {
    $tenant = $script:Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    if (-not $tenant) { return }
    if ($null -eq $tenant.PSObject.Properties['persistCredential']) { $tenant | Add-Member -NotePropertyName 'persistCredential' -NotePropertyValue $Persist }
    else { $tenant.persistCredential = $Persist }
    Save-HUSettings | Out-Null
}
function Update-PersistCredentialCheckbox {
    $k = Get-SelectedTenantKey
    $chk = $script:Controls['chkPersistCred']
    $script:PersistBusy = $true
    try {
        if ($k) { $chk.IsEnabled = $true; $chk.IsChecked = (Get-TenantPersistCredential $k) }
        else { $chk.IsEnabled = $false; $chk.IsChecked = $true }
    } finally { $script:PersistBusy = $false }
}

# settings.json schreiben (Sicherung settings.json.bak) und Module neu laden
function Save-HUSettings {
    try {
        Write-HUJsonFile -Path (Join-Path $script:AppRoot 'Config\settings.json') -Object $script:Settings -Depth 10 -Backup
        return $true
    } catch {
        Write-HULogError "settings.json nicht gespeichert: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# Verbinden (Hauptleiste)
# ============================================================================
function Connect-HUTenant([string]$TenantKey) {
    if (-not $TenantKey) { return $null }
    Write-HULogInfo "Verbinde mit $TenantKey ..." -Tenant $TenantKey
    $tok = $null
    try { $tok = Get-GraphToken -TenantKey $TenantKey -Settings $script:Settings -ErrorAction Stop } catch { Write-HULogError "Anmeldung fehlgeschlagen: $($_.Exception.Message)" -Tenant $TenantKey }
    return $tok
}

function Register-HUTenantHandlers {
    $c = $script:Controls

    $c['cmbTenant'].Add_SelectionChanged({
        if ($script:TenantSelectBusy) { return }
        $k = Get-SelectedTenantKey
        if (-not $k) { return }
        Set-CurrentTenant -TenantKey $k
        Set-HUStateValue 'lastTenantKey' $k
        Update-TenantStatus -TenantKey $k
        Update-PersistCredentialCheckbox
        Update-HUSecretDisplay
        $script:CurrentToken = $null
        $script:Controls['txtPermissionStatus'].Text = ''
        Write-HULogInfo "Tenant gewaehlt: $k"
    })

    $c['chkPersistCred'].Add_Checked({
        if ($script:PersistBusy) { return }
        $k = Get-SelectedTenantKey
        if ($k) { Set-TenantPersistCredential $k $true; Write-HULogInfo "Secret bleibt gespeichert ($k)" }
    })
    $c['chkPersistCred'].Add_Unchecked({
        if ($script:PersistBusy) { return }
        $k = Get-SelectedTenantKey
        if ($k) { Set-TenantPersistCredential $k $false; Write-HULogWarn "Secret wird beim Beenden geloescht ($k)" }
    })

    $c['btnValidate'].Add_Click({
        $k = Get-SelectedTenantKey
        if (-not $k) { return }
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $script:CurrentToken = Connect-HUTenant $k
            if (-not $script:CurrentToken) {
                Write-HULogError 'Kein Token - Secret pruefen (Einstellungen > Tenants > Secret eingeben).' -Tenant $k
                Update-TenantStatusCache -TenantKey $k -Connected $false -ErrorMessage 'Token'
                Update-TenantStatus -TenantKey $k
                Update-HUTenantItemSuffixes
                return
            }
            $conn = Test-TenantConnection -TenantKey $k -Token $script:CurrentToken
            if ($conn.IsConnected) {
                Write-HULogOK "Verbunden mit $k" -Tenant $k
                $perms = @(Get-TokenPermissions -Token $script:CurrentToken)
                Write-HULogInfo "Token-Berechtigungen ($($perms.Count)):" -Tenant $k
                foreach ($p in $perms) { Write-HULogDebug "  [TOKEN] $p" -Tenant $k }
                $missing = @()
                if ($script:SelectedExtension -and $script:SelectedExtension.RequiredPermissions) {
                    foreach ($rp in @($script:SelectedExtension.RequiredPermissions)) {
                        $has = $perms -contains $rp
                        Write-HULogDebug "  $(if ($has) { '[OK]' } else { '[FEHLT]' }) $rp" -Tenant $k
                        if (-not $has) { $missing += $rp }
                    }
                }
                if ($missing.Count) {
                    $script:Controls['txtPermissionStatus'].Text = "Berechtigungen: $($perms.Count), $($missing.Count) fehlen"
                    $script:Controls['txtPermissionStatus'].Foreground = Get-HUBrush '#FFEB3B'
                    Write-HULogWarn "Fehlt: $($missing -join ', ')" -Tenant $k
                } else {
                    $script:Controls['txtPermissionStatus'].Text = "Berechtigungen: $($perms.Count)$(if ($script:SelectedExtension) { ' - alles da' })"
                    $script:Controls['txtPermissionStatus'].Foreground = Get-HUBrush '#4CAF50'
                }
                Update-HUSecretExpiry $k $script:CurrentToken
            } else {
                Write-HULogError "Verbindung fehlgeschlagen: $($conn.ErrorMessage)" -Tenant $k
                $script:Controls['txtPermissionStatus'].Text = 'Verbindung fehlgeschlagen'
                $script:Controls['txtPermissionStatus'].Foreground = Get-HUBrush '#D32F2F'
            }
            Update-TenantStatus -TenantKey $k
            Update-HUTenantItemSuffixes
        } finally { $script:Window.Cursor = $null }
    })

    $c['btnDisconnect'].Add_Click({
        $k = Get-SelectedTenantKey
        if (-not $k) { return }
        Clear-TokenCache -TenantKey $k
        $script:CurrentToken = $null
        $script:Controls['txtPermissionStatus'].Text = ''
        Update-TenantStatusCache -TenantKey $k -Connected $false
        Write-HULogWarn "Getrennt: $k" -Tenant $k
        Update-TenantStatus -TenantKey $k
        Update-HUTenantItemSuffixes
    })

    $c['txtSecretWarning'].Add_MouseLeftButtonUp({ Open-HUSettings 'Tenants' })
    $c['txtSecretExpiry'].Cursor = [System.Windows.Input.Cursors]::Hand
    $c['txtSecretExpiry'].Add_MouseLeftButtonUp({ Open-HUSettings 'Tenants' (Get-SelectedTenantKey) })
}
