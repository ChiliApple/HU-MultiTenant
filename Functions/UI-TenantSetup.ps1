#Requires -Version 5.1
<#
.SYNOPSIS
    Tenant einrichten (Admin-Anmeldung im Browser) und fehlende Rechte erteilen (Fenster XAML\TenantSetupWindow.xaml).
.DESCRIPTION
    Einrichten: Global Admin meldet sich einmal im Browser an; HU-MultiTenant legt App-Registrierung, Service
    Principal und ein nicht exportierbares Zertifikat an, erteilt die gewaehlten Rechte, testet die Anmeldung und
    traegt den Tenant in settings.json ein (Core\HU.Setup.psm1, New-HUTenantSetup).
    Rechte erteilen: fester Tenant, nur fehlende Rechte hinzufuegen (Add-HUAppPermissions) - auch fuer eigene Skripte.
    Weitreichende Rechte (Liste "risky" in Config\graph-permissions.json) werden rot angezeigt und eigens bestaetigt.
    Das Admin-Token bleibt nur im Speicher und wird nach dem Lauf verworfen.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:TSU = $null   # offenes Einrichtungsfenster (Zustand)

function Add-HUTsuLog([string]$Text, [string]$Level = 'Info') {
    $u = $script:TSU
    if (-not $u) { return }
    $col = switch ($Level) { 'OK' { '#81C784' } 'Warn' { '#FFB74D' } 'Error' { '#EF9A9A' } default { '#90CAF9' } }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "$((Get-Date).ToString('HH:mm:ss'))  $Text"
    $tb.Foreground = Get-HUBrush $col
    $tb.TextWrapping = 'Wrap'
    [void]$u.C.lstLog.Items.Add($tb)
    $u.C.lstLog.ScrollIntoView($tb)
}

# Rechte-Liste aufbauen: Katalog + von Extensions benoetigte + bereits erteilte + selbst hinzugefuegte
function Update-HUTsuPermList {
    $u = $script:TSU
    $c = $u.C
    $c.lstPerms.Items.Clear()
    $usage = @{}; try { $usage = Get-HUPermUsage } catch { }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($u.Catalog.permissions)) { if (-not $names.Contains("$($p.name)")) { $names.Add("$($p.name)") } }
    foreach ($p in @($usage.Keys | Sort-Object)) { if (-not $names.Contains("$p")) { $names.Add("$p") } }
    foreach ($p in @($u.Granted)) { if (-not $names.Contains("$p")) { $names.Add("$p") } }
    foreach ($p in @($u.Extra)) { if (-not $names.Contains("$p")) { $names.Add("$p") } }
    foreach ($n in $names) {
        $cat = @($u.Catalog.permissions | Where-Object { "$($_.name)" -eq $n })[0]
        $risky = Test-HUPermissionRisky $n $u.Catalog
        $granted = ($u.Granted -contains $n)
        $why = if ($cat) { "$($cat.why)" } else { '' }
        if ($usage[$n]) { $why = (@($why, "Extensions: $(@($usage[$n]) -join ', ')") | Where-Object { $_ }) -join ' | ' }
        if (-not $why -and $u.Extra -contains $n) { $why = 'selbst hinzugefuegt' }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style = $u.Window.FindResource('DarkCheckBox')
        $cb.Tag = $n
        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = "$n$(if ($granted) { "   $([char]0x2714) erteilt" } elseif ($u.Mode -eq 'Grant' -and $u.GrantedKnown) { "   $([char]0x2716) fehlt" })$(if ($risky) { '   (weitreichend)' })"
        $t1.Foreground = Get-HUBrush $(if ($risky) { '#EF5350' } elseif ($granted) { '#81C784' } else { '#E0E0E0' })
        $t1.FontWeight = 'SemiBold'
        [void]$sp.Children.Add($t1)
        if ($why) { $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = $why; $t2.Foreground = Get-HUBrush '#909090'; $t2.FontSize = 11; $t2.TextWrapping = 'Wrap'; [void]$sp.Children.Add($t2) }
        $cb.Content = $sp
        if ($granted) { $cb.IsChecked = $true; $cb.IsEnabled = $false }
        elseif ($u.Checked.ContainsKey($n)) { $cb.IsChecked = [bool]$u.Checked[$n] }
        else {
            # Vorauswahl: Standard-Rechte; beim Erteilen zusaetzlich alles, was eine Extension braucht
            $cb.IsChecked = (($cat -and $cat.default -eq $true) -or ($u.Mode -eq 'Grant' -and $usage[$n] -and -not $risky) -or ($u.Extra -contains $n))
        }
        $cb.Add_Click({ $script:TSU.Checked["$($this.Tag)"] = [bool]$this.IsChecked; Update-HUTsuState })
        [void]$c.lstPerms.Items.Add($cb)
    }
    Update-HUTsuState
}

function Get-HUTsuSelected {
    return @($script:TSU.C.lstPerms.Items | Where-Object { $_.IsEnabled -and $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
}

function Update-HUTsuState {
    $u = $script:TSU
    if (-not $u) { return }
    $sel = @(Get-HUTsuSelected)
    $risky = @($sel | Where-Object { Test-HUPermissionRisky $_ $u.Catalog })
    $busy = ($u.Phase -ne 'Idle')
    foreach ($x in @($u.C.lstPerms, $u.C.txtKey, $u.C.txtName, $u.C.txtExtraPerm, $u.C.btnAddPerm, $u.C.btnSelDefault, $u.C.btnSelNone)) { $x.IsEnabled = -not $busy }
    $u.C.btnStart.IsEnabled = (-not $busy -and $sel.Count -gt 0)
    if (-not $busy) {
        $u.C.txtState.Text = if ($u.Mode -eq 'Grant') { "$($sel.Count) Recht(e) zum Erteilen ausgewaehlt$(if ($risky.Count) { ", davon $($risky.Count) weitreichend" })" }
                             else { "$($sel.Count) Rechte ausgewaehlt$(if ($risky.Count) { ", davon $($risky.Count) weitreichend" })" }
    }
}

# Tenant-Eintrag aus der Einrichtung in settings.json uebernehmen (gleiche tenantId: ersetzen, Schluessel/Name bleiben)
function Save-HUTenantFromSetup($Entry, [string]$WantedName = '') {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($script:Settings.tenants)) { if ($t) { $list.Add($t) } }
    $idx = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ("$($list[$i].tenantId)" -eq "$($Entry.tenantId)") { $idx = $i; break } }
    if ($idx -ge 0) {
        $t = $list[$idx]
        $oldKey = "$($t.key)"
        foreach ($p in 'tenantId', 'appId', 'auth', 'certThumbprint', 'appObjectId', 'spId') { Set-HUProp $t $p $Entry.$p }
        if (-not "$($t.domain)") { Set-HUProp $t 'domain' "$($Entry.domain)" }
        if ($WantedName) { Set-HUProp $t 'displayName' $WantedName }
        if ($t.PSObject.Properties['secretExpires']) { $t.PSObject.Properties.Remove('secretExpires') }
        $key = $oldKey
    } else {
        $t = [pscustomobject][ordered]@{
            key = "$($Entry.key)"; displayName = "$($Entry.displayName)"; tenantId = "$($Entry.tenantId)"; appId = "$($Entry.appId)"; domain = "$($Entry.domain)"
            credentialName = ''; auth = 'certificate'; certThumbprint = "$($Entry.certThumbprint)"; appObjectId = "$($Entry.appObjectId)"; spId = "$($Entry.spId)"
            isPrimary = ($list.Count -eq 0); adSchema = 'VirtualSchool'; tags = @(); notes = ''; persistCredential = $true
        }
        $list.Add($t)
        $key = "$($Entry.key)"
    }
    Set-HUProp $script:Settings 'tenants' @($list.ToArray())
    if (-not (Save-HUSettings)) { throw 'settings.json konnte nicht gespeichert werden (Protokoll)' }
    try { Clear-HUSecretState $key } catch { }
    return $key
}

# Hintergrund-Lauf (Einrichten bzw. Rechte erteilen); Fortschritt ueber eine Warteschlange
function Start-HUTsuWorker([scriptblock]$Code, [hashtable]$Vars) {
    $u = $script:TSU
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
    $rs.SessionStateProxy.SetVariable('__Q', $q)
    $rs.SessionStateProxy.SetVariable('__Code', $Code.ToString())
    foreach ($e in $Vars.GetEnumerator()) { $rs.SessionStateProxy.SetVariable([string]$e.Key, $e.Value) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            $ErrorActionPreference = 'Stop'
            foreach ($m in 'HU.Auth', 'HU.Setup') { Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking }
            $OnStep = { param($t, $l) $__Q.Enqueue(@("$t", "$l")) }
            try { & ([scriptblock]::Create($__Code)) }
            catch { [pscustomobject]@{ __Error = "$($_.Exception.Message)" } }
        })
    $u.Worker = @{ PS = $ps; RS = $rs; Q = $q; Handle = $ps.BeginInvoke() }
}

# Takt: Browser-Antwort abholen, Fortschritt anzeigen, Ende erkennen
function Invoke-HUTsuTick {
    $u = $script:TSU
    if (-not $u) { return }
    if ($u.Phase -eq 'Login') {
        $r = $null
        try { $r = Receive-HUAdminLogin -Context $u.LoginCtx } catch { $r = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
        if ($null -eq $r) {
            $sec = [int]((Get-Date) - $u.LoginCtx.Started).TotalSeconds
            $u.C.txtState.Text = "Warte auf die Anmeldung im Browser ... ($sec s)"
            return
        }
        $u.LoginCtx = $null
        if (-not $r.Ok) { Add-HUTsuLog $r.Error 'Error'; Stop-HUTsu; return }
        Complete-HUTsuLogin $r
        return
    }
    if ($u.Phase -eq 'Work' -and $u.Worker) {
        $item = $null
        while ($u.Worker.Q.TryDequeue([ref]$item)) { Add-HUTsuLog $item[0] $item[1] }
        if (-not $u.Worker.Handle.IsCompleted) {
            $u.C.txtState.Text = "Laeuft ... ($([int]((Get-Date) - $u.WorkStarted).TotalSeconds) s)"
            return
        }
        $out = $null
        try { $out = @($u.Worker.PS.EndInvoke($u.Worker.Handle)) | Select-Object -Last 1 } catch { $out = [pscustomobject]@{ __Error = $_.Exception.Message } }
        $errs = @($u.Worker.PS.Streams.Error | ForEach-Object { "$($_.Exception.Message)" })
        while ($u.Worker.Q.TryDequeue([ref]$item)) { Add-HUTsuLog $item[0] $item[1] }
        try { $u.Worker.PS.Dispose() } catch { }
        try { $u.Worker.RS.Dispose() } catch { }
        $u.Worker = $null
        $u.Login = $null   # Admin-Token verwerfen
        if (-not $out -and $errs.Count) { $out = [pscustomobject]@{ __Error = $errs -join '; ' } }
        Complete-HUTsuWork $out
    }
}

function Stop-HUTsu {
    $u = $script:TSU
    if ($u.LoginCtx) { Stop-HUAdminLogin $u.LoginCtx; $u.LoginCtx = $null }
    $u.Login = $null
    $u.Phase = 'Idle'
    Update-HUTsuState
}

# Anmeldung ist da: pruefen und Hintergrund-Lauf starten
function Complete-HUTsuLogin($Login) {
    $u = $script:TSU
    $w = $u.Window
    Add-HUTsuLog "Angemeldet: $(if ($Login.Name) { $Login.Name } else { $Login.Upn }) (Tenant $($Login.Tid))" 'OK'
    if (-not (Test-HUAdminCanGrant $Login)) {
        Add-HUTsuLog 'Dieses Konto ist weder Global Administrator noch Privileged Role Administrator (bei PIM: Rolle zuerst aktivieren). Nichts geaendert.' 'Error'
        Stop-HUTsu; return
    }
    $sel = @(Get-HUTsuSelected)
    if ($u.Mode -eq 'Grant') {
        if ("$($Login.Tid)" -ne "$($u.Tenant.tenantId)") { Add-HUTsuLog "Angemeldet im falschen Tenant ($($Login.Tid)) - erwartet $($u.Tenant.tenantId). Nichts geaendert." 'Error'; Stop-HUTsu; return }
        $u.Login = $Login
        $u.Phase = 'Work'; $u.WorkStarted = Get-Date
        Add-HUTsuLog "Erteile $($sel.Count) Recht(e) ..." 'Info'
        Start-HUTsuWorker -Vars @{ Login = $Login; AppId = "$($u.Tenant.appId)"; Perms = [string[]]$sel } -Code {
            $added = @(Add-HUAppPermissions -Login $Login -AppId $AppId -Permissions $Perms)
            [pscustomobject]@{ Added = $added }
        }
        Update-HUTsuState
        return
    }
    # Einrichten: Schluessel/Doppelte pruefen
    $existing = @($script:Settings.tenants | Where-Object { "$($_.tenantId)" -eq "$($Login.Tid)" })[0]
    $key = ($u.C.txtKey.Text.Trim() -replace '\s+', '-')
    if ($existing) {
        $msg = "Dieser Tenant ist schon eingetragen: '$($existing.displayName)' (Schluessel $($existing.key)).`n`nNeu einrichten? Es wird eine neue App-Registrierung 'HU-MultiTenant' mit Zertifikat angelegt; Schluessel und Einstellungen des Eintrags bleiben.`nDie bisherige App-Registrierung (mit Secret) danach im Entra Admin Center loeschen."
        if (-not (Confirm-HU $msg 'Tenant einrichten' -Warning -Owner $w)) { Add-HUTsuLog 'Abgebrochen - nichts geaendert.' 'Warn'; Stop-HUTsu; return }
        $key = "$($existing.key)"
    } else {
        if (-not $key) { $key = if ("$($Login.Upn)" -match '@([^.]+)\.') { $Matches[1] } else { "Tenant-$(@($script:Settings.tenants).Count + 1)" } }
        if (@($script:Settings.tenants | Where-Object { "$($_.key)" -eq $key }).Count) { Add-HUTsuLog "Schluessel '$key' ist schon vergeben - bitte einen anderen eingeben. Nichts geaendert." 'Error'; Stop-HUTsu; return }
    }
    $u.Login = $Login
    $u.Key = $key
    $u.Phase = 'Work'; $u.WorkStarted = Get-Date
    Start-HUTsuWorker -Vars @{ Login = $Login; Perms = [string[]]$sel; Key = $key; DName = $u.C.txtName.Text.Trim() } -Code {
        New-HUTenantSetup -Login $Login -Permissions $Perms -Key $Key -DisplayName $DName -OnStep $OnStep
    }
    Update-HUTsuState
}

function Complete-HUTsuWork($Out) {
    $u = $script:TSU
    if (-not $Out -or $Out.PSObject.Properties['__Error']) {
        if ($Out -and $Out.__Error -and -not @($u.C.lstLog.Items | Where-Object { "$($_.Text)" -match [regex]::Escape("$($Out.__Error)") }).Count) { Add-HUTsuLog "FEHLER: $($Out.__Error)" 'Error' }
        Add-HUTsuLog 'Nicht abgeschlossen.' 'Error'
        Stop-HUTsu; return
    }
    if ($u.Mode -eq 'Grant') {
        $added = @($Out.Added)
        if ($added.Count) { Add-HUTsuLog "Erteilt: $($added -join ', ')" 'OK' } else { Add-HUTsuLog 'Alle gewaehlten Rechte waren schon erteilt.' 'OK' }
        Add-HUTsuLog 'Neue Rechte erscheinen nach etwa 1 Minute im Token - dann im Fenster Berechtigungen "Neu lesen".' 'Info'
        try { Clear-TokenCache -TenantKey "$($u.Tenant.key)" } catch { }
        if ($script:PermCache) { $script:PermCache.Remove("$($u.Tenant.key)") }
        foreach ($p in $added) { if ($u.Granted -notcontains $p) { $u.Granted += $p } }
        $u.Result = $added
        $u.Phase = 'Idle'
        Update-HUTsuPermList
        $u.C.btnStart.Content = 'Weitere Rechte erteilen'
        return
    }
    try {
        $key = Save-HUTenantFromSetup -Entry $Out -WantedName $u.C.txtName.Text.Trim()
        Add-HUTsuLog "Eingetragen und gespeichert: $key ($($Out.domain)). Das Zertifikat liegt nur auf diesem PC (Benutzer-Zertifikatspeicher)." 'OK'
        Add-HUTsuLog 'Fertig. Fuer weitere Tenants: neuer Schluessel und nochmals anmelden.' 'OK'
        $u.Result = $key
        $u.Done += $key
        $u.C.txtKey.Text = ''; $u.C.txtName.Text = ''
        $u.C.btnStart.Content = 'Weiteren Tenant einrichten'
    } catch { Add-HUTsuLog "Eingerichtet, aber nicht gespeichert: $($_.Exception.Message)" 'Error' }
    $u.Phase = 'Idle'
    Update-HUTsuState
}

<#
.SYNOPSIS
    Fenster "Tenant einrichten" (ohne -TenantKey) bzw. "Fehlende Rechte erteilen" (mit -TenantKey).
    Rueckgabe: Liste der eingerichteten Schluessel bzw. erteilten Rechte (leer = nichts geaendert).
#>
function Show-HUTenantSetupDialog {
    param([string]$TenantKey = '', [string[]]$Preselect = @(), $Owner = $null)
    $catalog = $null
    try { $catalog = Get-HUPermissionCatalog $script:AppRoot } catch { Show-HUMessage "Config\graph-permissions.json nicht lesbar: $($_.Exception.Message)" -Icon Error; return @() }
    $d = New-HUWindow 'TenantSetupWindow'
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner; $w.WindowStartupLocation = 'CenterOwner' } catch { } }
    $tenant = $null
    if ($TenantKey) {
        $tenant = @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $TenantKey })[0]
        if (-not $tenant -or -not (Test-HUGuid "$($tenant.tenantId)") -or -not (Test-HUGuid "$($tenant.appId)")) { Show-HUMessage 'Tenant-ID bzw. Anwendungs-ID fehlen - zuerst den Tenant einrichten.' -Icon Warning; return @() }
    }
    $granted = @(); $known = $false
    if ($tenant -and $script:PermCache -and $script:PermCache[$TenantKey] -and -not $script:PermCache[$TenantKey].Error) { $granted = @($script:PermCache[$TenantKey].Roles); $known = $true }
    $script:TSU = @{
        Window = $w; C = $c; Catalog = $catalog; Mode = $(if ($tenant) { 'Grant' } else { 'Setup' }); Tenant = $tenant
        Granted = $granted; GrantedKnown = $known; Extra = @(); Checked = @{}; Phase = 'Idle'; LoginCtx = $null; Login = $null; Worker = $null
        Key = ''; WorkStarted = $null; Result = $null; Done = @()
    }
    foreach ($p in $Preselect) { if ("$p") { $script:TSU.Checked["$p"] = $true; if (-not @($catalog.permissions | Where-Object { "$($_.name)" -eq "$p" }).Count) { $script:TSU.Extra += "$p" } } }

    if ($tenant) {
        $w.Title = 'Fehlende Rechte erteilen'
        $c.txtTitle.Text = "Rechte erteilen: $($tenant.displayName)"
        $c.txtIntro.Text = "Ein Global Administrator (oder Privileged Role Administrator) dieses Tenants meldet sich einmal im Browser an. Die ausgewaehlten Rechte werden der App $($tenant.appId) zusaetzlich erteilt (Administratorzustimmung) - vorhandene bleiben, entfernt wird nichts.$(if (-not $known) { "`nErteilte Rechte sind noch nicht gelesen - bereits erteilte werden beim Erteilen uebersprungen." })"
        $c.pnlNames.Visibility = 'Collapsed'
        $c.btnStart.Content = 'Im Browser anmelden und Rechte erteilen'
    } else {
        $c.txtIntro.Text = "Ein Global Administrator meldet sich einmal im Browser an (Microsoft-App 'Graph Command Line Tools'). HU-MultiTenant legt dann im Tenant die App-Registrierung 'HU-MultiTenant' an, erzeugt auf diesem PC ein nicht exportierbares Zertifikat (12 Monate, wird automatisch erneuert), erteilt die ausgewaehlten Rechte, testet die Anmeldung und traegt den Tenant ein. Kein Secret, nichts abzutippen."
    }

    $c.btnSelDefault.Add_Click({ $script:TSU.Checked = @{}; Update-HUTsuPermList })
    $c.btnSelNone.Add_Click({ foreach ($cb in $script:TSU.C.lstPerms.Items) { if ($cb.IsEnabled) { $cb.IsChecked = $false; $script:TSU.Checked["$($cb.Tag)"] = $false } }; Update-HUTsuState })
    $addPerm = {
        $u = $script:TSU
        $n = $u.C.txtExtraPerm.Text.Trim()
        if (-not $n) { return }
        if ($n -notmatch '^[A-Za-z]+(\.[A-Za-z]+)+$') { Show-HUMessage "'$n' ist kein gueltiger Rechtename (Beispiel: Mail.Send)." -Icon Warning -Owner $u.Window; return }
        if ($u.Extra -notcontains $n) { $u.Extra += $n }
        $u.Checked[$n] = $true
        $u.C.txtExtraPerm.Text = ''
        Update-HUTsuPermList
    }
    $c.btnAddPerm.Add_Click($addPerm)
    $c.txtExtraPerm.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { & $addPerm; $e.Handled = $true } })

    $c.btnStart.Add_Click({
        $u = $script:TSU
        $sel = @(Get-HUTsuSelected)
        if (-not $sel.Count) { return }
        if ($u.Mode -eq 'Setup') {
            $k = $u.C.txtKey.Text.Trim()
            if ($k -and $k -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Show-HUMessage 'Schluessel: nur Buchstaben, Ziffern, Punkt, Minus, Unterstrich.' -Icon Warning -Owner $u.Window; return }
        }
        $risky = @($sel | Where-Object { Test-HUPermissionRisky $_ $u.Catalog })
        if ($risky.Count) {
            $msg = "Diese Rechte sind weitreichend:`n`n  $($risky -join "`n  ")`n`nDie App kann damit ohne Benutzer z. B. Benutzer, Apps, Rollen, Mails oder Dateien im ganzen Tenant lesen bzw. aendern. Wer das Zertifikat bzw. Secret auf diesem PC nutzen kann, hat diese Rechte ebenfalls.`n`nWirklich erteilen?"
            if (-not (Confirm-HU $msg 'Weitreichende Rechte' -Warning -Owner $u.Window)) { return }
        }
        try { $u.LoginCtx = Start-HUAdminLogin -TenantId $(if ($u.Tenant) { "$($u.Tenant.tenantId)" } else { '' }) }
        catch { Add-HUTsuLog "Anmeldung nicht gestartet: $($_.Exception.Message)" 'Error'; return }
        $u.Phase = 'Login'
        Add-HUTsuLog "Browser geoeffnet - bitte als Administrator anmelden und 'Akzeptieren' (ohne Haekchen 'im Namen der Organisation'). Antwort an http://localhost:$($u.LoginCtx.Port)/" 'Info'
        Update-HUTsuState
    })
    $c.btnClose.Add_Click({ $script:TSU.Window.Close() })
    $w.Add_Closing({
        param($s, $e)
        $u = $script:TSU
        if ($u.Phase -eq 'Work') { Show-HUMessage 'Bitte warten, bis der Lauf fertig ist (bei einem Fehler wird Angelegtes wieder entfernt).' -Icon Warning -Owner $u.Window; $e.Cancel = $true; return }
        if ($u.Phase -eq 'Login') { Stop-HUTsu }
    })
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({ try { Invoke-HUTsuTick } catch { Add-HUTsuLog "Fehler: $($_.Exception.Message)" 'Error'; Stop-HUTsu } })
    $w.Add_Closed({ $timer.Stop() })
    Update-HUTsuPermList
    $timer.Start()
    [void]$w.ShowDialog()
    $timer.Stop()
    $res = if ($script:TSU.Mode -eq 'Grant') { @($script:TSU.Result) } else { @($script:TSU.Done) }
    $script:TSU = $null
    return @($res | Where-Object { $_ })
}

# ============================================================================
# Zertifikat erneuern (automatisch 30 Tage vor Ablauf, oder per Knopf) und loeschen (Not-Aus)
# ============================================================================
$script:CertRenewDays = 30
$script:CertRenewRunning = @{}

function Get-HUTenantCertDaysLeft($Tenant) {
    if (-not (Test-HUTenantCertAuth $Tenant)) { return $null }
    $cert = Get-HUTenantCertificate -TenantKey "$($Tenant.key)" -Settings ([pscustomobject]@{ tenants = @($Tenant) })
    if (-not $cert) { return $null }
    return [int][Math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
}

# Erneuert im Hintergrund; danach neuer Thumbprint in settings.json. Done erhaelt (Key, Ok, Text).
function Start-HUCertRenew([string]$TenantKey, [scriptblock]$Done = $null) {
    $t = @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $TenantKey })[0]
    if (-not $t -or -not (Test-HUTenantCertAuth $t)) { return $false }
    if ($script:CertRenewRunning[$TenantKey]) { return $false }
    $script:CertRenewRunning[$TenantKey] = $true
    Write-HULogInfo "Zertifikat wird erneuert ..." -Tenant $TenantKey
    $state = @{ Key = $TenantKey; Done = $Done }
    Invoke-AsyncCommand -ScriptBlock {
        param($appRoot, $tenantJson)
        try {
            Import-Module (Join-Path $appRoot 'Core\HU.Auth.psm1') -Force -DisableNameChecking
            Import-Module (Join-Path $appRoot 'Core\HU.Setup.psm1') -Force -DisableNameChecking
            $t = $tenantJson | ConvertFrom-Json
            $th = Update-HUTenantCertificate -Tenant $t -WarningVariable wv -WarningAction SilentlyContinue
            return "OK:$th$(if ($wv) { "|$(@($wv) -join '; ')" })"
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:AppRoot, ($t | ConvertTo-Json -Depth 6 -Compress)) -TimeoutSec 400 -State $state -BusyTag 'cert' -BusyText 'Zertifikat erneuern' -OnComplete {
        param($result, $st)
        $key = $st.Key
        $script:CertRenewRunning.Remove($key)
        $s = "$result".Trim()
        $ok = $false; $txt = ''
        if ($s -match '^OK:([0-9A-Fa-f]{40})(\|(.*))?') {
            $th = $Matches[1]; $warn = $Matches[3]
            $t = @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $key })[0]
            if ($t) { Set-HUProp $t 'certThumbprint' $th; [void](Save-HUSettings) }
            try { Clear-HUSecretState $key } catch { }
            $ok = $true
            $txt = "Zertifikat erneuert ($($th.Substring(0, 8))...).$(if ($warn) { " Hinweis: $warn" })"
            Write-HULogOK $txt -Tenant $key
        } else {
            $txt = "Zertifikat nicht erneuert: $($s -replace '^ERR:', '')"
            Write-HULogWarn $txt -Tenant $key
        }
        if ($st.Done) { try { & $st.Done $key $ok $txt } catch { } }
        try { Update-HUSecretDisplay } catch { }
    }
    return $true
}

# Beim Start: Zertifikate, die in <= 30 Tagen ablaufen, erneuern
function Start-HUCertRenewAll {
    foreach ($t in @($script:Settings.tenants)) {
        if (-not $t) { continue }
        $d = $null
        try { $d = Get-HUTenantCertDaysLeft $t } catch { }
        if ($null -eq $d) { continue }
        if ($d -lt 0) { Write-HULogWarn 'Zertifikat abgelaufen - Tenant neu einrichten (Einstellungen > Tenants > Einrichten).' -Tenant "$($t.key)"; continue }
        if ($d -le $script:CertRenewDays) { [void](Start-HUCertRenew "$($t.key)") }
    }
}

# Not-Aus: Zertifikat(e) von HU-MultiTenant auf diesem PC loeschen
function Remove-HUTenantCertLocal($Tenant) {
    if (-not (Remove-HUCertLocal "$($Tenant.certThumbprint)")) { return $false }
    try { Clear-HUSecretState "$($Tenant.key)" } catch { }
    return $true
}
