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
    if (-not $desc -and $Perm -match 'ReadWrite|PrivilegedOperations') { $desc = 'schreibender Zugriff' }
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
                    if (-not (Get-StoredCredential -TenantKey $k -Settings $settings)) { $r.Error = 'kein Secret gespeichert'; $out += $r; continue }
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
        $c.txtStatus.Text = $(if (-not $entry) { 'Lese ...' } elseif ($entry.Error) { $entry.Error } else { "$($roles.Count) Berechtigungen, gelesen $($entry.Time.ToString('HH:mm'))" })
    }
}

function Show-HUPermissions([string]$TenantKey = '') {
    $d = New-HUWindow 'PermissionsWindow'
    $w = $d.Window; $c = $d.C
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
    $c.btnClose.Add_Click({ $script:PermUi.Window.Close() })
    $w.Add_Loaded({ Update-HUPermView })
    $w.Add_Closed({ $script:PermUi = $null })

    $c.cmbTenant.SelectedIndex = $sel   # loest das Lesen aus
    [void]$w.ShowDialog()
}
