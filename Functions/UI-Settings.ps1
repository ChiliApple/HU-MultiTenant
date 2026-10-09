#Requires -Version 5.1
<#
.SYNOPSIS
    Einstellungen: Allgemein (Verknuepfungen, Start-Reiter, Darstellung, Secrets), Tenants (anlegen, bearbeiten,
    Secret eingeben/pruefen), Update (Kanal, Signatur).
.DESCRIPTION
    Config\settings.json  - Tenants, ui.*, logging.logLevel, reporting.outputPath (Sicherung settings.json.bak)
    Config\update.json    - Channel, AllowUnsigned (weitere Schluessel bleiben erhalten)
    %APPDATA%\HU-MultiTenant\ui-state.json - Oberflaechengroesse
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

function Set-HUProp($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Get-HUProp($Object, [string]$Name, $Default = $null) {
    if ($Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

# Fehlende Abschnitte in settings.json ergaenzen (aeltere Dateien, Erststart)
function Initialize-HUSettingsDefaults($S) {
    foreach ($sec in @('app', 'credentials', 'extensions', 'logging', 'reporting', 'ui')) {
        if (-not $S.PSObject.Properties[$sec] -or $null -eq $S.$sec) { Set-HUProp $S $sec ([pscustomobject]@{}) }
    }
    if (-not $S.PSObject.Properties['tenants'] -or $null -eq $S.tenants) { Set-HUProp $S 'tenants' @() }
    $d = @{
        credentials = @{ tokenCacheTTL = 3000; credentialNamePrefix = 'HU-' }
        logging     = @{ file = './Logs/HU-MultiTenant_{date}.log'; logLevel = 'Info'; retentionDays = 30 }
        reporting   = @{ outputPath = './Reports'; autoVersioning = $true; defaultFormat = 'xlsx' }
        ui          = @{ maxLogLines = 500; startTab = 'QuickScript'; secretWarnDays = 30; checkSecretsOnStart = $true; checkUpdatesOnStart = $true }
        extensions  = @{ allowAutoLoad = $true; searchPaths = @('./Extensions'); disabled = @() }
    }
    foreach ($sec in $d.Keys) { foreach ($k in $d[$sec].Keys) { if (-not $S.$sec.PSObject.Properties[$k]) { Set-HUProp $S.$sec $k $d[$sec][$k] } } }
    return $S
}

# Erststart: settings.json ohne Tenants anlegen
function New-HUSettingsFile([string]$Path) {
    $s = [pscustomobject]@{ tenants = @() }
    $s = Initialize-HUSettingsDefaults $s
    Write-HUJsonFile -Path $Path -Object $s -Depth 10
}

function Test-HUGuid([string]$Value) { return ($Value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') }

function Open-HUSettings([string]$Tab = '', [string]$TenantKey = '') {
    if (Show-HUSettingsDialog -Tab $Tab -TenantKey $TenantKey) {
        Update-TenantDropdown
        Update-HUSecretDisplay
        # Tenant-Haken in Apps/Wartung neu aufbauen (Auswahl der offenen Eintraege bleibt)
        Save-HUAppForm; Update-HUAppTenantChecks; Show-HUAppForm $script:AppCurrent; Update-HUIntTenantChecks
        Save-HURemForm; Update-HURemTenantChecks; Show-HURemForm $script:RemCurrent
    }
}

function Show-HUSettingsDialog {
    param([string]$Tab = '', [string]$TenantKey = '')
    $d = New-HUWindow 'SettingsWindow'
    $w = $d.Window; $c = $d.C
    Restore-HUDialogState $w 'SettingsWindow'
    $S = $script:Settings
    $st = @{ Saved = $false; Tenants = [System.Collections.Generic.List[object]]::new(); Cur = -1; Busy = $false }
    foreach ($t in @($S.tenants)) { $st.Tenants.Add(($t | ConvertTo-Json -Depth 6 | ConvertFrom-Json)) }

    # ---------------- Allgemein ----------------
    $selTag = {
        param($cmb, [string]$tag)
        foreach ($i in $cmb.Items) { if ("$($i.Tag)" -eq $tag) { $cmb.SelectedItem = $i; return } }
        if ($cmb.Items.Count) { $cmb.SelectedIndex = 0 }
    }
    & $selTag $c.cmbStartTab (Get-HUProp $S.ui 'startTab' 'QuickScript')
    foreach ($p in @(80, 90, 100, 110, 120, 130, 140, 150)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem; $it.Content = "$p %"; $it.Tag = "$($p / 100)"; [void]$c.cmbScale.Items.Add($it)
    }
    $curScale = [Math]::Round([double]$(if ($script:UiScale) { $script:UiScale } else { 1.0 }), 1)
    foreach ($i in $c.cmbScale.Items) { if ([Math]::Abs([double]$i.Tag - $curScale) -lt 0.01) { $c.cmbScale.SelectedItem = $i } }
    if (-not $c.cmbScale.SelectedItem) { $c.cmbScale.SelectedIndex = 2 }
    $ll = "$(Get-HUProp $S.logging 'logLevel' 'Info')"
    & $selTag $c.cmbLogLevel $(if ($ll -match '^debug') { 'Debug' } elseif ($ll -match '^warn') { 'Warn' } else { 'Info' })
    $c.txtReports.Text = "$(Get-HUProp $S.reporting 'outputPath' './Reports')"
    $c.chkSecretCheckStart.IsChecked = [bool](Get-HUProp $S.ui 'checkSecretsOnStart' $true)
    $c.txtWarnDays.Text = "$(Get-HUSecretWarnDays)"
    $c.txtAuthor.Text = "$(Get-HUProp $S.ui 'author' '')"
    # Sperre
    $lc = Get-HULockConfig
    $c.chkLockEnabled.IsChecked = $lc.Enabled
    $c.txtLockMinutes.Text = "$($lc.Minutes)"
    $c.chkLockOnStart.IsChecked = $lc.OnStart
    $updLockInfo = { $c.txtLockInfo.Text = $(if (Test-HULockPinSet) { 'PIN ist festgelegt' } else { 'noch keine PIN' }) }
    & $updLockInfo
    $c.btnLockPin.Add_Click({ if (Show-HULockPinDialog $w) { & $updLockInfo } })
    $updShortcutInfo = {
        $exe = Join-Path $script:AppRoot $script:LauncherName
        $c.txtShortcutInfo.Text = "Starter: $(if (Test-Path -LiteralPath $exe) { $exe } else { 'noch nicht erstellt' })  |  Verknuepfung vorhanden: $(if (Test-HUShortcut) { 'ja' } else { 'nein' })"
    }
    & $updShortcutInfo
    $mkLink = {
        param([string]$Loc, [bool]$All)
        try {
            $l = New-HUShortcut -Location $Loc -AllUsers:$All
            Write-HULogOK "Verknuepfung erstellt: $l"
            Show-HUMessage "Verknuepfung erstellt:`n$l" -Owner $w
        } catch { Show-HUMessage "Verknuepfung fehlgeschlagen:`n$($_.Exception.Message)$(if ($All) { "`n`nFuer alle Benutzer sind Administratorrechte noetig." })" -Icon Error -Owner $w }
        & $updShortcutInfo
    }
    $c.btnShortcutDesktop.Add_Click({ & $mkLink 'Desktop' $false })
    $c.btnShortcutStart.Add_Click({ & $mkLink 'StartMenu' $false })
    $c.btnShortcutAll.Add_Click({ & $mkLink 'Desktop' $true })
    $c.btnLauncher.Add_Click({
        if (New-HULauncher -Force) { Show-HUMessage "Starter bereit:`n$(Join-Path $script:AppRoot $script:LauncherName)" -Owner $w } else { Show-HUMessage 'Starter konnte nicht erstellt werden (Protokoll).' -Icon Error -Owner $w }
        & $updShortcutInfo
    })
    $c.btnReportsBrowse.Add_Click({
        $f = New-Object System.Windows.Forms.FolderBrowserDialog
        $f.Description = 'Ordner fuer Reports'
        try { $f.SelectedPath = Get-HUReportsPath } catch { }
        if ($f.ShowDialog() -eq 'OK') { $c.txtReports.Text = $f.SelectedPath }
    })

    # ---------------- Tenants ----------------
    $secretLine = {
        param($t)
        $i = Get-HUSecretInfo "$($t.key)"
        $has = $false
        try { $has = [bool](Get-StoredCredential -TenantKey "$($t.key)" -Settings ([pscustomobject]@{ tenants = @($t); credentials = $S.credentials })) } catch { }
        if (-not $has) { return @('Kein Secret auf diesem PC gespeichert', '#FF9800') }
        if ($i.EndDate) { return @(($i.Text -replace '^\S+\s', ''), $i.Color) }
        return @('Secret gespeichert, Ablauf unbekannt', '#858585')
    }
    $refreshList = {
        param([int]$Select = -1)
        $st.Busy = $true
        try {
            $items = for ($i = 0; $i -lt $st.Tenants.Count; $i++) {
                $t = $st.Tenants[$i]
                $sl = & $secretLine $t
                [pscustomobject]@{
                    Title = "$(if ((Get-HUProp $t 'isPrimary' $false) -eq $true) { [char]0x2605 + ' ' })$(Get-HUProp $t 'displayName' '(ohne Namen)')"
                    Sub = "$(Get-HUProp $t 'key' '')  $(Get-HUProp $t 'domain' '')"
                    Secret = $sl[0]; SecretColor = $sl[1]; Index = $i
                }
            }
            $c.lstTenants.ItemsSource = @($items)
            if ($Select -ge 0 -and $Select -lt $st.Tenants.Count) { $c.lstTenants.SelectedIndex = $Select }
        } finally { $st.Busy = $false }
    }
    $formToTenant = {
        if ($st.Cur -lt 0 -or $st.Cur -ge $st.Tenants.Count) { return }
        $t = $st.Tenants[$st.Cur]
        Set-HUProp $t 'displayName' $c.tDisplay.Text.Trim()
        Set-HUProp $t 'key' ($c.tKey.Text.Trim() -replace '\s+', '-')
        Set-HUProp $t 'tenantId' $c.tTenantId.Text.Trim()
        Set-HUProp $t 'appId' $c.tAppId.Text.Trim()
        Set-HUProp $t 'domain' $c.tDomain.Text.Trim()
        Set-HUProp $t 'credentialName' $c.tCredName.Text.Trim()
        Set-HUProp $t 'adSchema' $(if ($c.tSchema.SelectedItem) { "$($c.tSchema.SelectedItem.Content)" } else { 'VirtualSchool' })
        Set-HUProp $t 'notes' $c.tNotes.Text
        Set-HUProp $t 'persistCredential' ([bool]$c.tPersist.IsChecked)
        $exp = $c.tExpires.Text.Trim()
        $dt = [datetime]::MinValue
        if ($exp -and [datetime]::TryParseExact($exp, @('dd.MM.yyyy', 'd.M.yyyy', 'yyyy-MM-dd'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { Set-HUProp $t 'secretExpires' $dt.ToString('yyyy-MM-dd') }
        elseif (-not $exp -and $t.PSObject.Properties['secretExpires']) { $t.PSObject.Properties.Remove('secretExpires') }
        $prot = @($c.tProtected.Text -split '[,;\s]+' | Where-Object { $_ })
        if ($prot.Count) { Set-HUProp $t 'protectedAppIds' $prot } elseif ($t.PSObject.Properties['protectedAppIds']) { $t.PSObject.Properties.Remove('protectedAppIds') }
        if ($c.tPrimary.IsChecked) { foreach ($o in $st.Tenants) { Set-HUProp $o 'isPrimary' ($o -eq $t) } } else { Set-HUProp $t 'isPrimary' $false }
    }
    $tenantToForm = {
        $st.Busy = $true
        try {
            $on = ($st.Cur -ge 0 -and $st.Cur -lt $st.Tenants.Count)
            $c.pnlTenant.IsEnabled = $on
            $t = if ($on) { $st.Tenants[$st.Cur] } else { [pscustomobject]@{} }
            $c.tDisplay.Text = "$(Get-HUProp $t 'displayName' '')"
            $c.tKey.Text = "$(Get-HUProp $t 'key' '')"
            $c.tTenantId.Text = "$(Get-HUProp $t 'tenantId' '')"
            $c.tAppId.Text = "$(Get-HUProp $t 'appId' '')"
            $c.tDomain.Text = "$(Get-HUProp $t 'domain' '')"
            $c.tCredName.Text = "$(Get-HUProp $t 'credentialName' '')"
            $sch = "$(Get-HUProp $t 'adSchema' 'VirtualSchool')"
            $c.tSchema.SelectedIndex = $(if ($sch -eq 'iPack') { 1 } else { 0 })
            $c.tNotes.Text = "$(Get-HUProp $t 'notes' '')"
            $c.tPersist.IsChecked = [bool](Get-HUProp $t 'persistCredential' $true)
            $c.tPrimary.IsChecked = ((Get-HUProp $t 'isPrimary' $false) -eq $true)
            $e = "$(Get-HUProp $t 'secretExpires' '')"
            $c.tExpires.Text = $(if ($e) { try { ([datetime]::Parse($e, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy') } catch { $e } } else { '' })
            $c.tProtected.Text = (@(Get-HUProp $t 'protectedAppIds' @()) -join ', ')
            $c.tTestResult.Text = ''
            if ($on) { $sl = & $secretLine $t; $c.tSecretState.Text = $sl[0]; $c.tSecretState.Foreground = Get-HUBrush $sl[1] } else { $c.tSecretState.Text = '' }
        } finally { $st.Busy = $false }
    }
    $c.lstTenants.Add_SelectionChanged({
        if ($st.Busy) { return }
        & $formToTenant
        $it = $c.lstTenants.SelectedItem
        $st.Cur = if ($it) { [int]$it.Index } else { -1 }
        & $tenantToForm
    })
    # Namen in der Liste sofort aktualisieren (beim Verlassen eines Feldes)
    # verzoegert, damit ein Klick auf einen anderen Eintrag nicht verloren geht
    foreach ($tb in @($c.tDisplay, $c.tKey, $c.tDomain)) {
        $tb.Add_LostFocus({
            if ($st.Busy -or $st.Cur -lt 0) { return }
            & $formToTenant
            [void]$w.Dispatcher.BeginInvoke([Action]{ try { if (-not $st.Busy) { & $refreshList $st.Cur } } catch { } }, [System.Windows.Threading.DispatcherPriority]::Background)
        })
    }

    $c.btnTenantAdd.Add_Click({
        & $formToTenant
        $n = $st.Tenants.Count + 1
        $key = "Tenant-$n"; while (@($st.Tenants | Where-Object { $_.key -eq $key }).Count) { $n++; $key = "Tenant-$n" }
        $st.Tenants.Add([pscustomobject][ordered]@{
            key = $key; displayName = "Neuer Tenant $n"; tenantId = ''; appId = ''; domain = ''; credentialName = "HU-$($key.ToUpper())"
            isPrimary = ($st.Tenants.Count -eq 0); adSchema = 'VirtualSchool'; tags = @(); notes = ''; persistCredential = $true
        })
        $st.Cur = $st.Tenants.Count - 1
        & $refreshList $st.Cur
        & $tenantToForm
        $c.tDisplay.Focus(); $c.tDisplay.SelectAll()
    })
    $c.btnTenantRemove.Add_Click({
        if ($st.Cur -lt 0) { return }
        $t = $st.Tenants[$st.Cur]
        if (-not (Confirm-HU "Tenant '$($t.displayName)' aus der Liste entfernen?`n`nDas gespeicherte Secret auf diesem PC bleibt erhalten (Knopf 'Gespeichertes Secret loeschen')." -Warning -Owner $w)) { return }
        $st.Tenants.RemoveAt($st.Cur)
        $st.Cur = [Math]::Min($st.Cur, $st.Tenants.Count - 1)
        & $refreshList $st.Cur
        & $tenantToForm
    })
    $moveT = {
        param([int]$Dir)
        if ($st.Cur -lt 0) { return }
        & $formToTenant
        $j = $st.Cur + $Dir
        if ($j -lt 0 -or $j -ge $st.Tenants.Count) { return }
        $t = $st.Tenants[$st.Cur]; $st.Tenants.RemoveAt($st.Cur); $st.Tenants.Insert($j, $t)
        $st.Cur = $j
        & $refreshList $j
    }
    $c.btnTenantUp.Add_Click({ & $moveT -1 })
    $c.btnTenantDown.Add_Click({ & $moveT 1 })

    $c.btnSecretSet.Add_Click({
        if ($st.Cur -lt 0) { return }
        & $formToTenant
        $t = $st.Tenants[$st.Cur]
        if (-not "$($t.key)") { Show-HUMessage 'Zuerst einen Schluessel eingeben.' -Icon Warning -Owner $w; return }
        $r = Show-HUSecretInput -TenantKey "$($t.key)" -Tenant $t -Owner $w
        if ($r) {
            if ($r.Expires) { $c.tExpires.Text = ([datetime]$r.Expires).ToString('dd.MM.yyyy') }
            elseif ($r.Saved) { $c.tExpires.Text = '' }
            & $formToTenant
            & $refreshList $st.Cur
            & $tenantToForm
            if ($r.Saved) { $c.tTestResult.Text = "Secret gespeichert. 'Verbindung + Secret pruefen' liest das neue Ablaufdatum." }
        }
    })
    $c.btnSecretDelete.Add_Click({
        if ($st.Cur -lt 0) { return }
        $t = $st.Tenants[$st.Cur]
        if (-not (Confirm-HU "Gespeichertes Secret fuer '$($t.displayName)' auf diesem PC loeschen?" -Warning -Owner $w)) { return }
        try { Remove-StoredCredential -TenantKey "$($t.key)" -Settings ([pscustomobject]@{ tenants = @($t); credentials = $S.credentials }) -Confirm:$false } catch { }
        Clear-HUSecretState "$($t.key)"
        & $refreshList $st.Cur; & $tenantToForm
    })
    $c.btnOpenApp.Add_Click({
        & $formToTenant
        $t = if ($st.Cur -ge 0) { $st.Tenants[$st.Cur] } else { $null }
        $appId = if ($t) { "$($t.appId)" } else { '' }
        Open-HUUrl $(if (Test-HUGuid $appId) { "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/$appId" } else { 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade' })
    })
    $c.btnTenantTest.Add_Click({
        if ($st.Cur -lt 0) { return }
        & $formToTenant
        $t = $st.Tenants[$st.Cur]
        if (-not (Test-HUGuid "$($t.tenantId)") -or -not (Test-HUGuid "$($t.appId)")) { $c.tTestResult.Text = 'Tenant-ID und Anwendungs-ID muessen GUIDs sein.'; $c.tTestResult.Foreground = Get-HUBrush '#FF9800'; return }
        $tmp = [pscustomobject]@{ tenants = @($t); credentials = $S.credentials }
        $w.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $tok = $null
            try { $tok = Get-GraphToken -TenantKey "$($t.key)" -Settings $tmp -ForceRefresh -ErrorAction Stop } catch { $c.tTestResult.Text = "Anmeldung fehlgeschlagen: $($_.Exception.Message)" }
            if (-not $tok) { if (-not $c.tTestResult.Text) { $c.tTestResult.Text = 'Anmeldung fehlgeschlagen - Secret fehlt oder ist falsch/abgelaufen.' }; $c.tTestResult.Foreground = Get-HUBrush '#F44336'; return }
            $perms = @(Get-TokenPermissions -Token $tok)
            $x = Get-AppSecretExpiry -TenantKey "$($t.key)" -Settings $tmp -Token $tok
            Set-HUSecretCacheEntry "$($t.key)" $x
            $txt = "Anmeldung OK - $($perms.Count) Anwendungsberechtigungen."
            if ($x.Status -eq 'OK' -and $x.EndDate) { $txt += " Secret gueltig bis $(([datetime]$x.EndDate).ToString('dd.MM.yyyy'))$(if (-not $x.Matched) { ' (naechstes ablaufendes Secret der App)' })." }
            elseif ($x.Status -eq 'NoPermission') { $txt += " Ablaufdatum nicht lesbar: Application.Read.All fehlt - Datum manuell eintragen oder Berechtigung erteilen." }
            else { $txt += " Ablaufdatum: $($x.Error)" }
            $c.tTestResult.Text = $txt
            $c.tTestResult.Foreground = Get-HUBrush '#8BC34A'
            & $refreshList $st.Cur
            $sl = & $secretLine $t; $c.tSecretState.Text = $sl[0]; $c.tSecretState.Foreground = Get-HUBrush $sl[1]
        } finally { $w.Cursor = $null; try { Clear-TokenCache -TenantKey "$($t.key)" } catch { } }
    })
    $c.btnCheckAllSecrets.Add_Click({
        $c.btnCheckAllSecrets.IsEnabled = $false
        $c.btnCheckAllSecrets.Content = 'Pruefe ... (gespeicherte Tenants)'
        $script:SettingsRefresh = { try { & $refreshList $st.Cur; & $tenantToForm; $c.btnCheckAllSecrets.IsEnabled = $true; $c.btnCheckAllSecrets.Content = "$($script:KeyIcon) Alle Secrets pruefen" } catch { } }
        Start-HUSecretCheckAll -Force -Done { if ($script:SettingsRefresh) { & $script:SettingsRefresh } }
    })

    # ---------------- Update ----------------
    $ucfg = Update-UpdateConfig
    $uRaw = Read-HUJsonFile (Join-Path $script:ConfigDir 'update.json')
    & $selTag $c.cmbChannel $(if ($ucfg) { "$($ucfg.Channel)" } else { 'Stable' })
    $c.chkRequireSig.IsChecked = -not ($uRaw -and $uRaw.PSObject.Properties['AllowUnsigned'] -and $uRaw.AllowUnsigned -eq $true)
    $c.chkCheckOnStart.IsChecked = [bool](Get-HUProp $S.ui 'checkUpdatesOnStart' $true)
    $inst = Get-HUInstalledInfo
    $c.txtUpdateInfo.Text = "Installiert: v$($script:Version)$(if ($inst -and $inst.PSObject.Properties['Date']) { " (geladen $($inst.Date), $(Get-HUProp $inst 'Check' ''))" } else { ' (nicht ueber Pull.ps1 installiert)' })`nQuelle: github.com/$(if ($ucfg) { "$($ucfg.Owner)/$($ucfg.Repo)" } else { 'ChiliApple/HU-MultiTenant' })`nSignierte Releases werden mit dem Zertifikat des Herausgebers geprueft (Fingerabdruck im Programm). Eigene Quelle: Config\update.json (Owner, Repo, SignerThumbprint)."
    $c.btnCheckNow.Add_Click({ Invoke-UpdateCheck; Show-HUMessage 'Die Pruefung laeuft im Hintergrund - das Ergebnis steht im Protokoll (Reiter Extensions), bei neuer Version wird der Knopf Update gold.' -Owner $w })
    $c.btnOtherVersion.Add_Click({ $w.Close(); Show-HUVersionPicker })

    # ---------------- Speichern ----------------
    $c.btnSave.Add_Click({
        & $formToTenant
        $keys = @{}
        for ($i = 0; $i -lt $st.Tenants.Count; $i++) {
            $t = $st.Tenants[$i]
            $why = if (-not "$($t.key)") { 'Schluessel fehlt' } elseif ($keys.ContainsKey("$($t.key)")) { "Schluessel '$($t.key)' doppelt" }
                   elseif (-not "$($t.displayName)") { 'Anzeigename fehlt' } elseif (-not (Test-HUGuid "$($t.tenantId)")) { 'Tenant-ID ist keine GUID' }
                   elseif (-not (Test-HUGuid "$($t.appId)")) { 'Anwendungs-ID ist keine GUID' } else { '' }
            if ($why) { $c.tabSettings.SelectedItem = $c.tabTenants; & $refreshList -1; $st.Cur = -1; $c.lstTenants.SelectedIndex = $i; Show-HUMessage "Tenant $($i + 1): $why" -Icon Warning -Owner $w; return }
            $keys["$($t.key)"] = $true
        }
        $et = $c.tExpires.Text.Trim(); $dtx = [datetime]::MinValue
        if ($st.Cur -ge 0 -and $et -and -not [datetime]::TryParseExact($et, @('dd.MM.yyyy', 'd.M.yyyy', 'yyyy-MM-dd'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dtx)) {
            $c.tabSettings.SelectedItem = $c.tabTenants; Show-HUMessage "'Secret gueltig bis' bitte als TT.MM.JJJJ eingeben (oder leer lassen)." -Icon Warning -Owner $w; return
        }
        $lm = 0
        if ($c.chkLockEnabled.IsChecked) {
            if (-not [int]::TryParse($c.txtLockMinutes.Text.Trim(), [ref]$lm) -or $lm -lt 1 -or $lm -gt 240) { $c.tabSettings.SelectedItem = $c.tabGeneral; Show-HUMessage 'Sperre: Minuten als Zahl zwischen 1 und 240.' -Icon Warning -Owner $w; return }
            if (-not (Test-HULockPinSet)) { $c.tabSettings.SelectedItem = $c.tabGeneral; Show-HUMessage 'Fuer die Sperre bitte zuerst eine PIN festlegen (Ersatz, falls Windows Hello nicht geht).' -Icon Warning -Owner $w; return }
        } else { [void][int]::TryParse($c.txtLockMinutes.Text.Trim(), [ref]$lm); if ($lm -lt 1) { $lm = 3 } }
        $wd = 0
        if (-not [int]::TryParse($c.txtWarnDays.Text.Trim(), [ref]$wd) -or $wd -lt 1 -or $wd -gt 365) { $c.tabSettings.SelectedItem = $c.tabGeneral; Show-HUMessage 'Warnschwelle: Zahl zwischen 1 und 365.' -Icon Warning -Owner $w; return }

        Set-HUProp $S 'tenants' @($st.Tenants.ToArray())
        Set-HUProp $S.ui 'startTab' "$($c.cmbStartTab.SelectedItem.Tag)"
        Set-HUProp $S.ui 'secretWarnDays' $wd
        Set-HUProp $S.ui 'checkSecretsOnStart' ([bool]$c.chkSecretCheckStart.IsChecked)
        Set-HUProp $S.ui 'author' $c.txtAuthor.Text.Trim()
        Set-HUProp $S.ui 'lockEnabled' ([bool]$c.chkLockEnabled.IsChecked)
        Set-HUProp $S.ui 'lockMinutes' $lm
        Set-HUProp $S.ui 'lockOnStart' ([bool]$c.chkLockOnStart.IsChecked)
        Set-HUProp $S.ui 'checkUpdatesOnStart' ([bool]$c.chkCheckOnStart.IsChecked)
        Set-HUProp $S.logging 'logLevel' "$($c.cmbLogLevel.SelectedItem.Tag)"
        Set-HUProp $S.reporting 'outputPath' $c.txtReports.Text.Trim()
        if (-not (Save-HUSettings)) { Show-HUMessage 'settings.json konnte nicht gespeichert werden (Protokoll).' -Icon Error -Owner $w; return }

        # update.json (andere Schluessel bleiben)
        try {
            $u = if ($uRaw) { $uRaw } else { [pscustomobject]@{} }
            Set-HUProp $u 'Channel' "$($c.cmbChannel.SelectedItem.Tag)"
            if ($c.chkRequireSig.IsChecked) { if ($u.PSObject.Properties['AllowUnsigned']) { $u.PSObject.Properties.Remove('AllowUnsigned') } } else { Set-HUProp $u 'AllowUnsigned' $true }
            Write-HUJsonFile -Path (Join-Path $script:ConfigDir 'update.json') -Object $u -Depth 4
        } catch { Write-HULogWarn "update.json: $($_.Exception.Message)" }

        if ($c.cmbScale.SelectedItem) { Set-HUUiScale ([double]::Parse("$($c.cmbScale.SelectedItem.Tag)", [Globalization.CultureInfo]::InvariantCulture)) }

        # Module mit der neuen Datei neu laden
        $script:Settings = Initialize-HUSettingsDefaults (Import-TenantSettings -SettingsPath (Join-Path $script:AppRoot 'Config\settings.json'))
        $st.Saved = $true
        Write-HULogOK 'Einstellungen gespeichert.'
        $w.Close()
    })
    $c.btnCancel.Add_Click({ $w.Close() })
    $w.Add_Closing({ Save-HUDialogState $w 'SettingsWindow' })

    # Start-Reiter / Tenant
    & $refreshList -1
    $idx = 0
    if ($TenantKey) { for ($i = 0; $i -lt $st.Tenants.Count; $i++) { if ("$($st.Tenants[$i].key)" -eq $TenantKey) { $idx = $i } } }
    if ($st.Tenants.Count) { $st.Cur = -1; $c.lstTenants.SelectedIndex = $idx } else { $st.Cur = -1; & $tenantToForm }
    switch ($Tab) { 'Tenants' { $c.tabSettings.SelectedItem = $c.tabTenants } 'Update' { $c.tabSettings.SelectedItem = $c.tabUpdate } default { } }
    $c.txtSettingsInfo.Text = "Programmordner: $($script:AppRoot)"
    [void]$w.ShowDialog()
    return $st.Saved
}
