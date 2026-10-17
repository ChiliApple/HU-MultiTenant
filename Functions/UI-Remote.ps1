#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung (Oberflaeche): Ein/Aus, Kopplung mit QR-Code, gekoppelte Handys, PIN, Freigaben, Einrichtung.
.DESCRIPTION
    Der Webserver laeuft in einem eigenen Runspace (Core\HU.Remote.ps1), Laeufe vom Handy in einem weiteren
    (Core\HU.RemoteRun.ps1). Diese Datei verbindet beides mit der Oberflaeche: ein Takt (0,5 s) uebernimmt Starts vom
    Handy, meldet am PC, sendet Push-Meldungen und haelt die Liste (Katalog) aktuell. Es oeffnet sich durch das Handy
    nie ein Dialog am PC (Review 031 B2).
    Dateien (je Windows-Konto, %APPDATA%\HU-MultiTenant): remote.json (Einstellungen), remote-marks.json (Freigaben),
    remote-devices.json (gekoppelte Handys, nur Hashes), remote-pin.json (PIN-Hash), remote-push.json (Push-Schluessel).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

. (Join-Path $script:AppRoot 'Core\HU.Remote.ps1')
. (Join-Path $script:AppRoot 'Core\HU.RemoteWeb.ps1')

$script:HURem = $null          # laufende Fernbedienung: @{ S; PS; RS; Handle; Timer; Runner; ... }
$script:HURemDlg = $null       # offenes Fenster
$script:HURemPushRuns = New-Object System.Collections.ArrayList
$script:HURemVapid = $null

# ----------------------------------------------------------------------------
# Einstellungen (remote.json) und Freigaben (remote-marks.json)
# ----------------------------------------------------------------------------
function Get-HURemoteConfigFile { return (Join-Path (Get-HURemoteDataDir) 'remote.json') }
function Get-HURemoteConfig {
    $j = $null; try { $f = Get-HURemoteConfigFile; if (Test-Path -LiteralPath $f) { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    $port = $script:HURemoteDefaultPort; try { if ($j -and [int]$j.Port -ge 1025 -and [int]$j.Port -le 65535) { $port = [int]$j.Port } } catch { }
    return [pscustomobject]@{
        AutoStart  = [bool]($j -and $j.AutoStart -eq $true)
        WhenLocked = [bool](-not $j -or $j.WhenLocked -ne $false)   # Entscheidung Udo: Handy startet auch bei gesperrter App (abschaltbar)
        KeepAwake  = [bool]($j -and $j.KeepAwake -eq $true)
        Intune     = [bool](-not $j -or $j.Intune -ne $false)      # Apps/Wartung am Handy (Standard an, abschaltbar)
        Port       = $port
        Networks   = @($(if ($j) { @($j.Networks) } else { @() }) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim() })
        SetupPort  = $(if ($j -and [int]$j.SetupPort -gt 0) { [int]$j.SetupPort } else { 0 })
        SetupSid   = "$(if ($j) { $j.SetupSid })"
        SetupAt    = "$(if ($j) { $j.SetupAt })"
        SetupIps   = @($(if ($j) { @($j.SetupIps) } else { @() }) | Where-Object { $_ })
    }
}
function Save-HURemoteConfig($Cfg) {
    Write-HUJsonFile -Path (Get-HURemoteConfigFile) -Object ([ordered]@{ v = 1; AutoStart = [bool]$Cfg.AutoStart; WhenLocked = [bool]$Cfg.WhenLocked; KeepAwake = [bool]$Cfg.KeepAwake; Intune = [bool]$Cfg.Intune
            Port = [int]$Cfg.Port; Networks = @($Cfg.Networks); SetupPort = [int]$Cfg.SetupPort; SetupSid = "$($Cfg.SetupSid)"; SetupAt = "$($Cfg.SetupAt)"; SetupIps = @($Cfg.SetupIps) })
}
function Get-HURemoteMarksFile { return (Join-Path (Get-HURemoteDataDir) 'remote-marks.json') }
# Rueckgabe: @{ Snippets = @{ Name = @{ Mode; Hash } }; Extensions = @{ RelPath = @{ Mode; Hash } } }
function Get-HURemoteMarks {
    $m = @{ Snippets = @{}; Extensions = @{} }
    try {
        $f = Get-HURemoteMarksFile
        if (Test-Path -LiteralPath $f) {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in @($j.Snippets.PSObject.Properties)) { if ($p -and "$($p.Value.Mode)" -in 'read', 'write') { $m.Snippets[$p.Name] = @{ Mode = "$($p.Value.Mode)"; Hash = "$($p.Value.Hash)" } } }
            foreach ($p in @($j.Extensions.PSObject.Properties)) { if ($p -and "$($p.Value.Mode)" -in 'read', 'write') { $m.Extensions[$p.Name] = @{ Mode = "$($p.Value.Mode)"; Hash = "$($p.Value.Hash)" } } }
        }
    } catch { Write-HULogWarn "Fernbedienung: Freigaben nicht lesbar - $($_.Exception.Message)" }
    return $m
}
function Save-HURemoteMarks($Marks) {
    $s = [ordered]@{}; foreach ($k in @($Marks.Snippets.Keys | Sort-Object)) { $s[$k] = [ordered]@{ Mode = $Marks.Snippets[$k].Mode; Hash = $Marks.Snippets[$k].Hash } }
    $e = [ordered]@{}; foreach ($k in @($Marks.Extensions.Keys | Sort-Object)) { $e[$k] = [ordered]@{ Mode = $Marks.Extensions[$k].Mode; Hash = $Marks.Extensions[$k].Hash } }
    Write-HUJsonFile -Path (Get-HURemoteMarksFile) -Object ([ordered]@{ v = 1; Snippets = $s; Extensions = $e })
}
function Get-HURemoteFileHash([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-HURemoteItemId([string]$Text) { return (Get-HURemoteHash $Text).Substring(0, 16) }

# ----------------------------------------------------------------------------
# Katalog fuers Handy (was gestartet werden darf) - am PC gebaut, das Handy kennt nur Kennungen
# ----------------------------------------------------------------------------
function ConvertTo-HURemoteParamDefs($Defs) {
    return @(@($Defs) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Type = "$($_.Type)".ToLower(); Label = "$($_.Label)"; Default = "$($_.Default)"; Choices = @($_.Choices | ForEach-Object { "$_" } | Where-Object { $_ }) } })
}
function Update-HURemoteCatalog([switch]$Force) {
    $r = $script:HURem; if (-not $r) { return }
    $S = $r.S
    $marks = Get-HURemoteMarks
    $items = @{}; $client = @()
    $qsTen = @(Get-HUStateValue 'qsMultiTenants' @()) | Where-Object { $_ }
    $allKeys = @($script:Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { $_ })
    $defTen = if (@($qsTen).Count) { @($qsTen) } else { @($(try { Get-HUQSTenantKey } catch { }) | Where-Object { $_ }) }
    # Snippets (nur freigegebene, Code-Stand muss zur Freigabe passen)
    foreach ($sn in @(Get-HUSnippets)) {
        $mk = $marks.Snippets["$($sn.name)"]; if (-not $mk) { continue }
        $h = Get-HUTeamsCodeHash "$($sn.code)"
        $id = Get-HURemoteItemId "snippet|$($sn.name)"
        $stale = ($h -ne $mk.Hash)
        $defs = ConvertTo-HURemoteParamDefs (Get-HUQSParams "$($sn.code)")
        $route = $null; try { $rt = Get-HUTeamsSnippetRoute "$($sn.name)"; if ($rt) { $route = @{ Name = "$($rt.Name)"; TargetIds = [string[]]@($rt.Ids) } } } catch { }
        $items[$id] = @{ Id = $id; Kind = 'snippet'; Name = "$($sn.name)"; Mode = $mk.Mode; Params = $defs; Hash = $h; Code = "$($sn.code)"; Route = $route; Stale = $stale; TargetText = '' }
        $client += [ordered]@{ id = $id; kind = 'snippet'; name = "$($sn.name)"; desc = $(if ($stale) { 'GEAENDERT - am PC unter Remote FB > Freigaben neu freigeben' } else { "$($sn.description)" }); cat = "$($sn.category)"; mode = $mk.Mode; stale = $stale
            params = @($defs | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type; label = $_.Label; def = $_.Default; choices = @($_.Choices) } }); tenants = @($defTen) }
    }
    # Erweiterungen (nur Windows PowerShell 5.1, nur freigegebene)
    $root = Join-Path $script:AppRoot 'Extensions'
    foreach ($exi in @($script:ExtensionItems)) {
        $ex = if ($exi -and $exi.PSObject.Properties['ExtensionObj']) { $exi.ExtensionObj } else { $exi }   # Liste haelt Anzeige-Objekte, die Erweiterung steckt in ExtensionObj
        if (-not $ex -or -not $ex.Path) { continue }
        $rel = "$($ex.Path)".Replace($root, '').TrimStart('\', '/')
        $mk = $marks.Extensions[$rel]; if (-not $mk) { continue }
        if ("$($ex.Runtime)" -eq 'PS7') { continue }
        $h = ''; try { $h = Get-HURemoteFileHash $ex.Path } catch { continue }
        $id = Get-HURemoteItemId "ext|$rel"
        $stale = ($h -ne $mk.Hash)
        $defs = @(ConvertTo-HURemoteParamDefs $ex.CustomParameters)
        $mode = $mk.Mode
        if ("$($ex.Mode)" -eq 'ReadWrite') { $mode = 'write' }
        if ($mode -eq 'write' -and $ex.DryRunCapable) { $defs = @([pscustomobject]@{ Name = 'Probelauf'; Type = 'bool'; Label = 'Probelauf (nichts aendern)'; Default = 'true'; Choices = @() }) + $defs }
        $items[$id] = @{ Id = $id; Kind = 'ext'; Name = "$($ex.Name)"; Mode = $mode; Params = $defs; Hash = $h; Path = "$($ex.Path)"; Stale = $stale; TargetText = '' }
        $client += [ordered]@{ id = $id; kind = 'ext'; name = "$($ex.Name)"; desc = $(if ($stale) { 'GEAENDERT - am PC unter Remote FB > Freigaben neu freigeben' } else { "$(if ($ex.Synopsis) { $ex.Synopsis } else { $ex.Description })" }); cat = "$($ex.Category)"; mode = $mode; stale = $stale
            params = @($defs | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type; label = $_.Label; def = $_.Default; choices = @($_.Choices) } }); tenants = @($(try { $k0 = Get-SelectedTenantKey; if ($k0) { "$k0" } elseif ($defTen.Count) { $defTen[0] } } catch { })) }
    }
    # Teams-Meldungen (alle gespeicherten)
    $targets = @()
    try { $targets = @((Get-HUNotifyConfig).Targets | Where-Object { $_ -and $_.Enabled } | ForEach-Object { [ordered]@{ id = "$($_.Id)"; name = "$($_.Name)" } }) } catch { }
    $snAll = @{}; foreach ($sn in @(Get-HUSnippets)) { $snAll["$($sn.name)"] = $sn }
    foreach ($jb in @(Get-HUTeamsJobs -AppRoot $script:AppRoot)) {
        if (-not $jb -or -not "$($jb.Id)") { continue }
        $id = Get-HURemoteItemId "teams|$($jb.Id)"
        $defs = @(); $mode = 'read'; $stale = $false
        if ("$($jb.Kind)" -eq 'Script') {
            $sn = $snAll["$($jb.Options.snippet)"]
            if ($sn) {
                $defs = ConvertTo-HURemoteParamDefs (Get-HUQSParams "$($sn.code)")
                # Werte der Meldung als Vorgabe
                foreach ($d in $defs) { if ($jb.Options.params -and $jb.Options.params.PSObject.Properties[$d.Name]) { $d.Default = "$($jb.Options.params.($d.Name))" } }
                $mk = $marks.Snippets["$($sn.name)"]
                $mode = if ($mk -and $mk.Mode -eq 'read') { 'read' } else { 'write' }
            }
            $want = "$(if ($jb.Options.PSObject.Properties['snippetHash']) { $jb.Options.snippetHash })"
            $stale = (-not $sn) -or ($want -ne (Get-HUTeamsCodeHash "$($sn.code)"))
        }
        $tIds = @($jb.Targets | Where-Object { "$_" })
        $tTxt = if (-not $tIds.Count) { 'alle aktiven Ziele' } else { (@($targets | Where-Object { $tIds -contains $_.id } | ForEach-Object { $_.name }) -join ', ') }
        $jt = @($jb.Tenants | Where-Object { "$_" }); if (-not $jt.Count) { $jt = $allKeys }
        $hash = Get-HURemoteHash (ConvertTo-Json -InputObject $jb -Depth 10 -Compress)
        $items[$id] = @{ Id = $id; Kind = 'teams'; Name = "$($jb.Name)"; Mode = $mode; Params = $defs; Hash = $hash; JobJson = (ConvertTo-Json -InputObject $jb -Depth 10 -Compress); Stale = $stale; TargetText = $tTxt; FixedTenants = $false }
        $client += [ordered]@{ id = $id; kind = 'teams'; name = "$($jb.Name)"; desc = $(if ($stale) { 'Skript geaendert - Meldung am PC neu speichern' } else { "$(Format-HUTeamsDays $jb.Days) $($jb.Time)".Trim() }); cat = ''; mode = $mode; stale = $stale
            params = @($defs | ForEach-Object { [ordered]@{ name = $_.Name; type = $_.Type; label = $_.Label; def = $_.Default; choices = @($_.Choices) } }); tenants = @($jt); targets = $tTxt }
    }
    # Apps und Wartung (Intune): feste Eintraege; was genau, waehlt das Handy (geprueft am PC, immer Kuerzel + PIN)
    $intune = [bool](Get-HURemoteConfig).Intune
    if ($intune) {
        foreach ($ar in 'app', 'rem') {
            $id = Get-HURemoteItemId "intune|$ar"
            $nm = if ($ar -eq 'app') { 'Intune-Apps' } else { 'Intune-Wartung' }
            $items[$id] = @{ Id = $id; Kind = 'intune'; Area = $ar; Name = $nm; Mode = 'write'; Params = @(); Hash = 'intune'; Stale = $false; TargetText = ''; FixedTenants = $false }
            $client += [ordered]@{ id = $id; kind = 'intune'; area = $ar; name = $nm; desc = ''; cat = ''; mode = 'write'; stale = $false; params = @(); tenants = @($defTen) }
        }
    }
    $S.Intune = $intune
    $tenants = @($script:Settings.tenants | Where-Object { $_ -and "$($_.key)" } | ForEach-Object { [ordered]@{ key = "$($_.key)"; name = $(if ("$($_.displayName)") { "$($_.displayName)" } else { "$($_.key)" }) } })
    $json = ConvertTo-Json -InputObject ([ordered]@{ items = @($client); tenants = @($tenants); targets = @($targets) }) -Depth 8 -Compress
    $S.Tenants = @($tenants | ForEach-Object { [pscustomobject]$_ })
    $S.Targets = @($targets | ForEach-Object { [pscustomobject]$_ })
    $S.Items = [hashtable]::Synchronized($items)
    if ($Force -or $json -ne "$($S.CatalogJson)") { $S.CatalogJson = $json; $S.CatVer = [int]$S.CatVer + 1 }
    $r.CatAt = Get-Date
}

# ----------------------------------------------------------------------------
# Einrichtung (UAC) und Pruefung
# ----------------------------------------------------------------------------
function Get-HURemoteMySid { try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return '' } }
function Get-HURemoteSetupState {
    $cfg = Get-HURemoteConfig
    $o = [ordered]@{ Ok = $false; Text = ''; Port = $cfg.Port; Cert = $null; Ca = $null; Warn = '' }
    if (-not $cfg.SetupPort) { $o.Text = 'Nicht eingerichtet.'; return [pscustomobject]$o }
    if ($cfg.SetupPort -ne $cfg.Port) { $o.Text = "Eingerichtet fuer Port $($cfg.SetupPort), eingestellt ist $($cfg.Port) - neu einrichten."; return [pscustomobject]$o }
    if ($cfg.SetupSid -ne (Get-HURemoteMySid)) { $o.Text = 'Eingerichtet fuer ein anderes Windows-Konto - neu einrichten.'; return [pscustomobject]$o }
    $b = Get-HURemoteBinding $cfg.Port
    if ($b.State -ne 'Ours') { $o.Text = "HTTPS-Bindung fuer Port $($cfg.Port) fehlt$(if ($b.State -eq 'Foreign') { $(if (Test-HURemoteHUMigPort $cfg.Port) { ' (Port gehoert der HUMig-Fernbedienung - anderen Port waehlen)' } else { ' (anderes Programm)' }) }) - neu einrichten."; return [pscustomobject]$o }
    $txt = Get-HURemoteUrlAclText $cfg.Port
    if (-not ("$txt" -match [regex]::Escape("https://+:$($cfg.Port)/")) -or -not (Test-HURemoteUrlAclOurs $txt $cfg.Port $cfg.SetupSid)) { $o.Text = 'Port-Freigabe fuer Dein Konto fehlt - neu einrichten.'; return [pscustomobject]$o }
    $cert = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $b.Thumb })[0]
    if (-not $cert) { $o.Text = 'Server-Zertifikat fehlt - neu einrichten.'; return [pscustomobject]$o }
    $o.Cert = $cert
    $o.Ca = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $cert.Issuer -and $_.FriendlyName -eq $script:HURemoteCaName } | Sort-Object NotAfter -Descending)[0]
    $san = Get-HURemoteCertSan $cert
    $ips = @(Get-HURemoteIPv4List | Where-Object { $_.Private } | ForEach-Object { $_.IP })
    $miss = @($ips | Where-Object { $san.IPs -notcontains $_ })
    if ($miss.Count) { $o.Warn = "Das Zertifikat passt nicht zur Adresse $($miss -join ', ') - Einrichtung erneuern (Tipp: feste Adresse im Router)." }
    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { $o.Warn = "Zertifikat laeuft am $($cert.NotAfter.ToString('dd.MM.yyyy')) ab - Einrichtung erneuern." }
    $o.Ok = $true
    $o.Text = "Eingerichtet fuer Dein Konto, Port $($cfg.Port) (seit $($cfg.SetupAt))."
    return [pscustomobject]$o
}
function Invoke-HURemoteSetup([ValidateSet('Install', 'Uninstall')][string]$Action, $Owner = $null) {
    $cfg = Get-HURemoteConfig
    $sid = Get-HURemoteMySid
    if (-not $sid) { Show-HUMessage 'Windows-Konto nicht ermittelbar.' -Icon Error -Owner $Owner; return $false }
    $port = if ($Action -eq 'Uninstall' -and $cfg.SetupPort) { $cfg.SetupPort } else { $cfg.Port }
    if ($Action -eq 'Install' -and $script:HURem) { Stop-HURemote 'Einrichtung' }
    if ($Action -eq 'Install' -and (Get-HURemoteBinding $port).State -eq 'Foreign') {
        $fp = Get-HURemoteFreePort $port
        Show-HUMessage "Port $port wird bereits von $(if (Test-HURemoteHUMigPort $port) { 'der HUMig-Fernbedienung' } else { 'einem anderen Programm' }) verwendet.$(if ($fp) { " Frei waere z. B. $fp - unter Einstellungen eintragen und speichern." })" -Icon Warning -Owner $Owner; return $false
    }
    if ($Action -eq 'Install' -and (Get-HURemoteBinding $port).State -ne 'Ours' -and -not (Test-HURemotePortFree $port)) {
        $fp = Get-HURemoteFreePort $port
        Show-HUMessage "Port $port ist belegt (anderes Programm).$(if ($fp) { " Frei waere z. B. $fp - unter Einstellungen eintragen." })" -Icon Warning -Owner $Owner; return $false
    }
    # Review 032 B5: die Skripte nicht aus dem (vom Benutzer beschreibbaren) Programmordner als Admin starten, sondern
    # als Admin in einen nur fuer Administratoren beschreibbaren Ordner kopieren, Pruefsummen gegen die hier
    # ermittelten Werte pruefen und die Kopie ausfuehren. Ergebnis ebenfalls dort (fuer das Konto nur lesbar).
    $nets = @(@($cfg.Networks) | Where-Object { "$_" -match '^[0-9./]+$' })
    $core = Join-Path $script:AppRoot 'Core'
    $hs = @{}
    foreach ($f in 'HU.RemoteSetup.ps1', 'HU.Remote.ps1') { $hs[$f] = (Get-FileHash -LiteralPath (Join-Path $core $f) -Algorithm SHA256).Hash }
    $nonce = [guid]::NewGuid().ToString('N')
    # Review 032 B53: je Lauf ein neuer Ordner mit zufaelligem Namen unter %windir%\Temp (Name vorher unbekannt, also
    # nicht vorab anlegbar); Besitzer Administratoren, ACL ohne Vererbung, keine Junction - sonst Abbruch
    $base = Join-Path $env:windir "Temp\HU-RemoteSetup-$nonce"
    $res = Join-Path $base 'result.json'
    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $boot = @"
`$ErrorActionPreference = 'Stop'
`$base = $(& $q $base); `$res = $(& $q $res); `$src = $(& $q $core)
`$files = @{ 'HU.RemoteSetup.ps1' = '$($hs['HU.RemoteSetup.ps1'])'; 'HU.Remote.ps1' = '$($hs['HU.Remote.ps1'])' }
`$ok = @('S-1-5-32-544', 'S-1-5-18', '$sid')
function Test-HUOwnDir([string]`$p) {
    `$i = Get-Item -LiteralPath `$p -Force
    if (-not `$i.PSIsContainer -or (`$i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return `$false }
    `$o = (Get-Acl -LiteralPath `$p).GetOwner([Security.Principal.SecurityIdentifier]).Value
    return (`$o -eq 'S-1-5-32-544' -or `$o -eq 'S-1-5-18')
}
# Reste frueherer Einrichtungen entfernen - nur eigene Ordner (Besitzer Administratoren/SYSTEM, keine Junction)
try {
    `$old = Join-Path `$env:ProgramData 'HU-MultiTenant-RemoteSetup'
    if ((Test-Path -LiteralPath `$old) -and (Test-HUOwnDir `$old)) { Remove-Item -LiteralPath `$old -Recurse -Force }
    Get-ChildItem -LiteralPath (Split-Path `$base -Parent) -Directory -Filter 'HU-RemoteSetup-*' -Force -ErrorAction SilentlyContinue |
        Where-Object { `$_.LastWriteTime -lt (Get-Date).AddHours(-1) -and (Test-HUOwnDir `$_.FullName) } | Remove-Item -Recurse -Force
} catch { }
try {
    if (Test-Path -LiteralPath `$base) { throw 'Setup-Ordner gibt es schon - abgebrochen' }
    [void](New-Item -ItemType Directory -Path `$base)
    `$o = & icacls.exe `$base /setowner '*S-1-5-32-544' 2>&1
    if (`$LASTEXITCODE) { throw "Besitzer des Setup-Ordners nicht gesetzt: `$o" }
    `$o = & icacls.exe `$base /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*$($sid):(OI)(CI)RX' 2>&1
    if (`$LASTEXITCODE) { throw "Rechte fuer den Setup-Ordner nicht gesetzt: `$o" }
    if (-not (Test-HUOwnDir `$base)) { throw 'Setup-Ordner: Besitzer oder Ordnerart unerwartet - abgebrochen' }
    foreach (`$a in (Get-Acl -LiteralPath `$base).Access) { if (`$ok -notcontains `$a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value) { throw "Setup-Ordner: unerwartete Berechtigung fuer `$(`$a.IdentityReference) - abgebrochen" } }
    foreach (`$k in `$files.Keys) {
        `$d = Join-Path `$base `$k
        Copy-Item -LiteralPath (Join-Path `$src `$k) -Destination `$d -Force
        if ((Get-FileHash -LiteralPath `$d -Algorithm SHA256).Hash -ne `$files[`$k]) { throw "Pruefsumme von `$k stimmt nicht - Datei wurde waehrend der Einrichtung veraendert" }
    }
    & (Join-Path `$base 'HU.RemoteSetup.ps1') -Action '$Action' -Port $port -Sid '$sid' -Networks '$($nets -join ',')' -ResultFile `$res
}
catch { [IO.File]::WriteAllText(`$res, (@{ Ok = `$false; Error = "`$(`$_.Exception.Message)" } | ConvertTo-Json), (New-Object Text.UTF8Encoding `$false)) }
finally { foreach (`$k in `$files.Keys) { Remove-Item -LiteralPath (Join-Path `$base `$k) -Force -ErrorAction SilentlyContinue } }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($boot))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    try {
        $p = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
    } catch { Show-HUMessage "Einrichtung abgebrochen (keine Administratorrechte erteilt).`n$($_.Exception.Message)" -Icon Warning -Owner $Owner; return $false }
    $j = $null; try { $j = Get-Content -LiteralPath $res -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if (-not $j -or -not $j.Ok) { Show-HUMessage "Einrichtung fehlgeschlagen: $(if ($j) { $j.Error } else { 'kein Ergebnis' })" -Icon Error -Owner $Owner; return $false }
    if ($Action -eq 'Install') {
        $cfg.SetupPort = $port; $cfg.SetupSid = $sid; $cfg.SetupAt = (Get-Date).ToString('dd.MM.yyyy HH:mm'); $cfg.SetupIps = @($j.Ips)
        Save-HURemoteConfig $cfg
        Write-HULogOK "Fernbedienung eingerichtet: Port $port, Adressen $(@($j.Ips) -join ', '). CA-Fingerabdruck: $($j.CaFp)"
    }
    else {
        $cfg.SetupPort = 0; $cfg.SetupSid = ''; $cfg.SetupAt = ''; $cfg.SetupIps = @()
        Save-HURemoteConfig $cfg
        Write-HULogInfo 'Fernbedienung: Einrichtung entfernt (die gemeinsame CA bleibt fuer HUMig).'
    }
    return $true
}

# ----------------------------------------------------------------------------
# Ein / Aus
# ----------------------------------------------------------------------------
function New-HURemoteIconPng([int]$Size) {
    try {
        $dv = New-Object System.Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $dc.DrawRectangle((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x1E, 0x1E, 0x2E))), $null, [System.Windows.Rect]::new(0, 0, $Size, $Size))
        if ($script:AppIcon) { $m = [Math]::Round($Size * 0.14); $dc.DrawImage($script:AppIcon, [System.Windows.Rect]::new($m, $m, $Size - 2 * $m, $Size - 2 * $m)) }
        $dc.Close()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Size, $Size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $ms = New-Object System.IO.MemoryStream
        $enc.Save($ms)
        return , $ms.ToArray()
    } catch { return $null }
}
function ConvertTo-HURemoteQrImage([string]$Text) {
    $q = ConvertTo-HURQrMatrix $Text
    $sc = 8; $qz = 4; $n = $q.Size; $w = ($n + 2 * $qz) * $sc
    $px = New-Object byte[] ($w * $w)
    for ($i = 0; $i -lt $px.Length; $i++) { $px[$i] = 255 }
    $row = New-Object byte[] $w
    for ($y = 0; $y -lt $n; $y++) {
        for ($i = 0; $i -lt $w; $i++) { $row[$i] = 255 }
        for ($x = 0; $x -lt $n; $x++) { if ($q.Modules[$y * $n + $x]) { $o = ($x + $qz) * $sc; for ($k = 0; $k -lt $sc; $k++) { $row[$o + $k] = 0 } } }
        for ($k = 0; $k -lt $sc; $k++) { [Array]::Copy($row, 0, $px, (($y + $qz) * $sc + $k) * $w, $w) }
    }
    $bmp = [System.Windows.Media.Imaging.BitmapSource]::Create($w, $w, 96, 96, [System.Windows.Media.PixelFormats]::Gray8, $null, $px, $w)
    $bmp.Freeze()
    return $bmp
}
function Get-HURemoteLogFile {
    $d = Join-Path $script:AppRoot 'Logs\Remote'
    try { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }; return (Join-Path $d ("Zugriffe_{0}.log" -f (Get-Date -Format 'yyyy-MM'))) } catch { return '' }
}

function Start-HURemote([switch]$Quiet, $Owner = $null) {
    if ($script:HURem) { return $true }
    $msg = { param($t, $lvl) if ($Quiet) { if ($lvl -eq 'Error') { Write-HULogError "Fernbedienung: $t" } else { Write-HULogWarn "Fernbedienung: $t" } } else { Show-HUMessage $t -Title 'Handy-Fernbedienung' -Icon $lvl -Owner $Owner } }
    $st = Get-HURemoteSetupState
    if (-not $st.Ok) { & $msg "Nicht gestartet: $($st.Text)`n`nEinmalig einrichten: Fenster Remote FB > Einstellungen > Einrichten (Windows fragt nach Administratorrechten)." 'Warning'; return $false }
    if ($st.Warn) { Write-HULogWarn "Fernbedienung: $($st.Warn)" }
    $ips = @(Get-HURemoteIPv4List | Where-Object { $_.Private })
    if (-not $ips.Count) { & $msg 'Keine private IPv4-Adresse gefunden - die Fernbedienung laeuft nur im lokalen Netz bzw. ueber das VPN.' 'Warning'; return $false }
    $cat = Get-HURemoteNetCategory $ips[0].Index
    if ($cat -eq 'Public') { & $msg "Das Netzwerk '$($ips[0].Alias)' ist als 'Oeffentlich' eingestuft - dort startet die Fernbedienung nicht. Zuhause: Netzwerkprofil 'Privat'." 'Warning'; return $false }
    $cfg = Get-HURemoteConfig
    $S = New-HURemoteState
    $S.Port = $cfg.Port; $S.Version = "$($script:Version)"
    $S.Devices = Read-HURemoteDevices
    $S.Pin = Read-HURemotePin
    $script:HURemVapid = $null
    try { $script:HURemVapid = Get-HURemoteVapid; $S.PushKey = $script:HURemVapid.Public } catch { Write-HULogWarn "Fernbedienung: Push nicht verfuegbar - $($_.Exception.Message)" }
    $S.LogFile = Get-HURemoteLogFile
    $S.Static = Get-HURemoteWebFiles -Version "$($script:Version)" -Pc "$env:COMPUTERNAME" -Icon192 (New-HURemoteIconPng 192) -Icon512 (New-HURemoteIconPng 512) -Ca $(if ($st.Ca) { $st.Ca.RawData } else { $null })
    $core = (Join-Path $script:AppRoot 'Core\HU.Remote.ps1') -replace "'", "''"
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('S', $S)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript(". '$core'`nStart-HURemoteListenerLoop `$S")
    $h = $ps.BeginInvoke()
    $script:HURem = @{ S = $S; PS = $ps; RS = $rs; Handle = $h; Port = $cfg.Port; Ip = $ips[0].IP; Ips = @($ips | ForEach-Object { $_.IP }); CaFp = (Get-HURemoteFingerprint $st.Ca)
        Timer = $null; Runner = $null; CatAt = [datetime]::MinValue; Started = (Get-Date); Awake = $false; LastBusy = '' }
    for ($i = 0; $i -lt 30 -and -not $S.Listening -and $S.Run; $i++) { Start-Sleep -Milliseconds 100 }
    if (-not $S.Listening) {
        $err = if ($S.Error) { $S.Error } else { 'Webserver antwortet nicht' }
        Stop-HURemote -Silent
        & $msg "Nicht gestartet: $err" 'Error'
        return $false
    }
    try { Update-HURemoteCatalog -Force } catch { Write-HULogWarn "Fernbedienung: Liste nicht erstellt - $($_.Exception.Message)" }
    # Apps/Wartung: Leseanfragen vom Handy im eigenen Runspace (blockiert weder Webserver noch Oberflaeche)
    try {
        $wset = $script:Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $wrun = (Join-Path $script:AppRoot 'Core\HU.RemoteRun.ps1') -replace "'", "''"
        $wrs = [runspacefactory]::CreateRunspace(); $wrs.Open()
        $wrs.SessionStateProxy.SetVariable('S', $S); $wrs.SessionStateProxy.SetVariable('Set', $wset); $wrs.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
        $wps = [powershell]::Create(); $wps.Runspace = $wrs
        [void]$wps.AddScript(". '$core'`n. '$wrun'`nStart-HURemoteIntuneWorker `$S `$Set `$AppRoot")
        $script:HURem.IW = @{ PS = $wps; RS = $wrs; Handle = $wps.BeginInvoke() }
    } catch { Write-HULogWarn "Fernbedienung: Apps/Wartung nicht verfuegbar - $($_.Exception.Message)" }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({ try { Update-HURemoteTick } catch { Write-HULogWarn "Fernbedienung: $($_.Exception.Message)" } })
    $script:HURem.Timer = $t
    $t.Start()
    Write-HULogOK "Fernbedienung aktiv: https://$($ips[0].IP):$($cfg.Port)$(if (-not $S.Pin) { ' - noch keine PIN: echte Laeufe vom Handy erst nach PIN (Fenster Remote FB > Einstellungen)' })"
    Update-HURemoteButton
    return $true
}
function Stop-HURemote([string]$Why = '', [switch]$Silent) {
    $r = $script:HURem
    if (-not $r) { return }
    if ($r.Runner) { $r.S.CancelReq = @{ By = 'PC'; At = Get-Date } }
    $script:HURem = $null
    try { if ($r.Timer) { $r.Timer.Stop() } } catch { }
    $r.S.Run = $false
    for ($i = 0; $i -lt 30 -and $r.S.Listening; $i++) { Start-Sleep -Milliseconds 100 }
    try { if ($r.Handle.IsCompleted) { [void]$r.PS.EndInvoke($r.Handle) } } catch { }
    try { $r.PS.Dispose() } catch { }
    try { $r.RS.Dispose() } catch { }
    if ($r.IW) {
        # Lese-Runspace: endet von selbst (S.Run); haengt er in einer Graph-Abfrage, nicht blockieren
        try { if ($r.IW.Handle.AsyncWaitHandle.WaitOne(1000)) { [void]$r.IW.PS.EndInvoke($r.IW.Handle); $r.IW.PS.Dispose(); $r.IW.RS.Dispose() } else { [void]$r.IW.PS.BeginStop($null, $null) } } catch { }
    }
    try { if ($r.S.DevDirty) { Save-HURemoteDevices $r.S.Devices } } catch { }
    if ($r.Awake) { try { Set-HURemoteAwakeUi $false } catch { } }
    if ($r.Runner) {
        # laufender Lauf: Abbruch angefordert - Runspace im Hintergrund auslaufen lassen (nicht blockieren)
        try { [void]$r.Runner.PS.BeginStop($null, $null) } catch { }
    }
    Update-HURemoteTitle ''
    if (-not $Silent) { Write-HULogInfo "Fernbedienung beendet$(if ($Why) { " ($Why)" })" }
    Update-HURemoteButton
    if ($script:HURemDlg) { try { Update-HURemoteDialog } catch { } }
}
# PC wach halten (Oberflaechen-Thread, solange die Fernbedienung an ist - Einstellung)
function Set-HURemoteAwakeUi([bool]$On) {
    try {
        if (-not ('HURemote.PowerUi' -as [type])) { Add-Type -Namespace HURemote -Name PowerUi -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop }
        [void][HURemote.PowerUi]::SetThreadExecutionState($(if ($On) { [uint32]0x80000001 } else { [uint32]0x80000000 }))
    } catch { }
}
# laeuft am PC gerade etwas (Quick Script, Erweiterung, Teams)? Grund oder ''
function Get-HURemotePcBusy {
    if ($script:QS_Timer -and $script:QS_Timer.IsEnabled) { return 'Quick Script' }
    if ($script:IsRunning) { return 'Erweiterung' }
    if ((Get-Command Test-HUJobRunning -ErrorAction SilentlyContinue) -and (Test-HUJobRunning 'TeamsJob')) { return 'Teams-Meldung' }
    return ''
}
# Gegenrichtung: laeuft ein Lauf vom Handy, starten am PC Quick Script, Erweiterungen und "Jetzt senden" nicht (gemeinsame Laufsperre)
function Test-HURemoteRunBusy([switch]$Message) {
    $r = $script:HURem
    if (-not ($r -and ($r.Runner -or $r.S.RunReq))) { return $false }
    if ($Message) { Show-HUMessage "Vom Handy laeuft gerade: $($r.S.Job.Title) (gestartet von '$($r.S.Job.By)').`nBitte warten, bis der Lauf fertig ist." -Title 'Handy-Fernbedienung' -Icon Warning }
    return $true
}
function Update-HURemoteTitle([string]$Text) {
    if (-not $script:Window) { return }
    $base = "HU-MultiTenant v$($script:Version)"
    $script:Window.Title = if ($Text) { "$base  -  $Text" } else { $base }
}

# Takt (0,5 s): Ereignisse, Starts vom Handy, Laufende, Push, Katalog
function Update-HURemoteTick {
    $r = $script:HURem; if (-not $r) { return }
    $S = $r.S
    if (-not $S.Listening -and $S.Error) { $e = $S.Error; Stop-HURemote -Silent; Write-HULogError "Fernbedienung beendet: $e"; return }
    while ($S.Events.Count -gt 0) {
        $ev = $S.Events.Dequeue()
        switch ("$($ev.Kind)") {
            'Paired' { Write-HULogOK "Fernbedienung: Handy '$($ev.Name)' gekoppelt ($($ev.Ip))"; if ($script:HURemDlg) { try { $script:HURemDlg.C['pnlRemPair'].Visibility = 'Collapsed' } catch { } } }
            'PairLocked' { Write-HULogWarn 'Fernbedienung: Kopplung gesperrt - 5 falsche Codes. Im Fenster Remote FB neu oeffnen.' }
            'Unpaired' { Write-HULogInfo "Fernbedienung: Handy '$($ev.Name)' hat sich entkoppelt" }
            'DevLocked' {
                Write-HULogWarn "Fernbedienung: Handy '$($ev.Name)' gesperrt - 3 falsche PINs. Entsperren im Fenster Remote FB."
                try { [void](Send-HUNotify -Category Jobs -Level Warning -Source 'Fernbedienung' -Title "Handy '$($ev.Name)' gesperrt" -Lines @('3 falsche PINs fuer einen echten Lauf - das Handy ist gesperrt, entsperren nur am PC.')) } catch { }
            }
        }
    }
    if ($S.Pair -and $S.Pair.Until -lt (Get-Date)) { Close-HURemotePairing $S }
    # Sperre am PC: Starts vom Handy nur, wenn erlaubt (Einstellung)
    $cfg = $r.Cfg; if (-not $cfg -or ((Get-Date) - $r.CfgAt).TotalSeconds -gt 10) { $cfg = Get-HURemoteConfig; $r.Cfg = $cfg; $r.CfgAt = Get-Date }
    $busy = Get-HURemotePcBusy
    if (-not $busy -and $script:LockActive -and -not $cfg.WhenLocked) { $busy = 'HU-MultiTenant ist am PC gesperrt' }
    $S.Busy = $busy
    # wach halten (Einstellung)
    if ($cfg.KeepAwake -ne $r.Awake) { Set-HURemoteAwakeUi $cfg.KeepAwake; $r.Awake = $cfg.KeepAwake }
    # Start vom Handy (dort mit Einmal-Bestaetigung, ggf. Kuerzel + PIN)
    $rq = $S.RunReq
    if ($rq -and -not $r.Runner) {
        $S.RunReq = $null
        if ($busy) { Add-HURemoteLineTo $S "Nicht gestartet - am PC laeuft gerade: $busy" 'Error' }
        else { Start-HURemoteRunner $rq }
    }
    if ($r.Runner) { Receive-HURemoteRunner }
    if ($S.DevDirty) { $S.DevDirty = $false; try { Save-HURemoteDevices $S.Devices } catch { } }
    Update-HURemotePushRuns
    # Liste alle 20 s neu (Snippets/Erweiterungen/Meldungen koennen sich am PC aendern)
    if (((Get-Date) - $r.CatAt).TotalSeconds -ge 20 -and -not $r.Runner) { try { Update-HURemoteCatalog } catch { } }
    if ($script:HURemDlg) { $r.DlgTick = [int]$r.DlgTick + 1; if ($r.DlgTick % 4 -eq 0) { try { Update-HURemoteDialog } catch { } } }
}

function Start-HURemoteRunner($Rq) {
    $r = $script:HURem; $S = $r.S
    $S.Lines.Clear()
    $S.Job.Running = $true; $S.Job.Title = "$($Rq.Item.Name)"; $S.Job.By = "$($Rq.By)"; $S.Job.Live = [bool]$Rq.Live
    $S.Job.Started = Get-Date; $S.Job.Ended = $null; $S.Job.Result = ''; $S.Job.Level = ''; $S.Job.Done = @()
    $set = $script:Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $files = @((Join-Path $script:AppRoot 'Core\HU.Remote.ps1'), (Join-Path $script:AppRoot 'Core\HU.RemoteRun.ps1')) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('S', $S)
    $rs.SessionStateProxy.SetVariable('Rq', $Rq)
    $rs.SessionStateProxy.SetVariable('Set', $set)
    $rs.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript(". $($files[0])`n. $($files[1])`nInvoke-HURemoteRun `$S `$Rq `$Set `$AppRoot")
    $r.Runner = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Rq = $Rq; Started = Get-Date }
    $what = switch ("$($Rq.Item.Kind)") { 'snippet' { 'Snippet' } 'ext' { 'Erweiterung' } default { 'Teams-Meldung' } }
    $tn = @($Rq.Tenants | ForEach-Object { $k = $_; $t = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1; if ($t) { "$($t.displayName)" } else { $k } })
    $log = "HANDY '$($Rq.By)' startet $what '$($Rq.Item.Name)'$(if ($Rq.Live) { ' - ECHTER LAUF' }) - Tenants: $($tn -join ', ')$(if ($Rq.Target) { ' - einmalig an ein Ziel' })"
    if ($Rq.Live) { Write-HULogWarn $log } else { Write-HULogInfo $log }
    Update-HURemoteTitle "Remote FB: $($Rq.Item.Name) (vom Handy)"
    Update-HURemoteButton
}
function Receive-HURemoteRunner {
    $r = $script:HURem; $run = $r.Runner
    if (-not $run.Handle.IsCompleted) { return }
    $S = $r.S
    try { [void]$run.PS.EndInvoke($run.Handle) } catch { Add-HURemoteLineTo $S "Fehler: $($_.Exception.Message)" 'Error'; if (-not $S.Job.Result) { $S.Job.Result = 'Fehler'; $S.Job.Level = 'Error' } }
    foreach ($e in @($run.PS.Streams.Error | Select-Object -First 3)) { Write-HULogWarn "Fernbedienung (Lauf): $($e.Exception.Message)" }
    try { $run.PS.Dispose() } catch { }
    try { $run.RS.Dispose() } catch { }
    $r.Runner = $null
    if (-not $S.Job.Ended) { $S.Job.Ended = Get-Date }
    $S.Job.Running = $false
    $msg = "HANDY-Lauf '$($S.Job.Title)' fertig: $($S.Job.Result)"
    switch ("$($S.Job.Level)") { 'OK' { Write-HULogOK $msg } 'Warning' { Write-HULogWarn $msg } default { Write-HULogError $msg } }
    Update-HURemoteTitle ''
    Update-HURemoteButton
    if ("$($run.Rq.Item.Kind)" -eq 'teams') { try { Update-HUTeamsHist; Update-HUTeamsJobs } catch { } }
    Send-HURemotePush
    try { Update-HURemoteCatalog } catch { }
}

# Push ohne Inhalt an alle Handys mit Abo (das Ergebnis holt sich das Handy dann beim PC)
function Send-HURemotePush {
    $r = $script:HURem
    if (-not $r -or -not $script:HURemVapid) { return }
    $reqs = Get-HURemotePushRequests $r.S.Devices $script:HURemVapid
    if (-not $reqs -or -not $reqs.Count) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:HURPushSendScript).AddArgument($reqs)
    [void]$script:HURemPushRuns.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date); Limit = (30 + 20 * $reqs.Count) })
}
function Update-HURemotePushRuns {
    foreach ($run in @($script:HURemPushRuns)) {
        $late = ((Get-Date) - $run.Started).TotalSeconds -gt [int]$run.Limit
        if (-not $run.Handle.IsCompleted -and -not $late) { continue }
        $script:HURemPushRuns.Remove($run)
        if (-not $run.Handle.IsCompleted) { try { [void]$run.PS.BeginStop($null, $null) } catch { }; Write-HULogWarn 'Fernbedienung: Push-Meldung nicht zugestellt (Zeitueberschreitung)'; continue }
        $res = @(); try { $res = @($run.PS.EndInvoke($run.Handle)) } catch { }
        try { $run.PS.Dispose() } catch { }
        $S = if ($script:HURem) { $script:HURem.S } else { $null }
        foreach ($x in $res) {
            if (-not $x) { continue }
            $c = [int]$x.Code
            if ($c -ge 200 -and $c -lt 300) { continue }
            $dv = if ($S) { $S.Devices[$x.Hash] } else { $null }
            if ($c -in @(404, 410) -and $dv -and "$($dv.PushEndpoint)" -eq "$($x.Url)") { $dv.PushEndpoint = ''; $S.DevDirty = $true; Write-HULogWarn "Fernbedienung: Push fuer '$($x.Name)' abgelaufen - am Handy unter Mehr wieder einschalten" }
            else { Write-HULogWarn "Fernbedienung: Push an '$($x.Name)' nicht zugestellt ($(if ($c) { "HTTP $c" } else { $x.Error }))" }
        }
    }
}

function Update-HURemoteButton {
    $b = $script:Controls['btnRemote']; if (-not $b) { return }
    $r = $script:HURem
    if ($r -and $r.Runner) { $b.Content = [char]::ConvertFromUtf32(0x1F4F1) + ' Remote FB ' + [char]0x25B6; $b.Foreground = Get-HUBrush '#FFB74D'; $b.ToolTip = "Vom Handy laeuft: $($r.S.Job.Title)" }
    elseif ($r) { $b.Content = [char]::ConvertFromUtf32(0x1F4F1) + ' Remote FB ' + [char]0x25CF; $b.Foreground = Get-HUBrush '#81C784'; $b.ToolTip = "Fernbedienung aktiv: https://$($r.Ip):$($r.Port)" }
    else { $b.Content = [char]::ConvertFromUtf32(0x1F4F1) + ' Remote FB'; $b.Foreground = Get-HUBrush '#CCCCCC'; $b.ToolTip = 'Handy-Fernbedienung: Snippets, Erweiterungen und Teams-Meldungen vom Handy starten' }
}

# Beim Start: Knopf, ggf. automatisch einschalten
function Initialize-HURemote {
    Update-HURemoteButton
    if ((Get-HURemoteConfig).AutoStart) { [void](Start-HURemote -Quiet) }
}
function Close-HURemote { try { Stop-HURemote -Silent } catch { } }

# ----------------------------------------------------------------------------
# Fenster
# ----------------------------------------------------------------------------
function Show-HURemoteDialog {
    if ($script:HURemDlg) { try { $script:HURemDlg.Window.Activate() } catch { }; return }
    $d = New-HUWindow 'RemoteWindow'
    $script:HURemDlg = $d
    $c = $d.C
    $cfg = Get-HURemoteConfig
    $c['chkRemAuto'].IsChecked = $cfg.AutoStart
    $c['chkRemLocked'].IsChecked = $cfg.WhenLocked
    $c['chkRemAwake'].IsChecked = $cfg.KeepAwake
    $c['chkRemIntune'].IsChecked = $cfg.Intune
    $c['txtRemPort'].Text = "$($cfg.Port)"
    $c['txtRemNets'].Text = (@($cfg.Networks) -join ', ')
    $c['btnRemClose'].Add_Click({ $script:HURemDlg.Window.Close() })
    $d.Window.Add_Closed({ $script:HURemDlg = $null })
    $c['btnRemOnOff'].Add_Click({
            if ($script:HURem) {
                if ($script:HURem.Runner -and -not (Confirm-HU 'Vom Handy laeuft gerade ein Lauf - er wird abgebrochen. Trotzdem ausschalten?' -Warning -Owner $script:HURemDlg.Window)) { return }
                Stop-HURemote
            } else { [void](Start-HURemote -Owner $script:HURemDlg.Window) }
            Update-HURemoteDialog
        })
    $c['btnRemPair'].Add_Click({ Open-HURemotePairUi })
    $c['btnRemPairClose'].Add_Click({ if ($script:HURem) { Close-HURemotePairing $script:HURem.S }; $script:HURemDlg.C['pnlRemPair'].Visibility = 'Collapsed' })
    $c['btnRemUnlock'].Add_Click({ Set-HURemoteDeviceAction 'unlock' })
    $c['btnRemRemove'].Add_Click({ Set-HURemoteDeviceAction 'remove' })
    $c['btnRemRemoveAll'].Add_Click({ Set-HURemoteDeviceAction 'all' })
    $c['btnRemPinSet'].Add_Click({
            $c2 = $script:HURemDlg.C
            $p1 = $c2['pwdRemPin1'].Password; $p2 = $c2['pwdRemPin2'].Password
            if ($p1 -ne $p2) { Show-HUMessage 'Die beiden PINs sind verschieden.' -Icon Warning -Owner $script:HURemDlg.Window; return }
            if (-not (Test-HURemotePinFormat $p1)) { Show-HUMessage "PIN: nur Ziffern, $($script:HURemotePinMin) bis $($script:HURemotePinMax) Stellen." -Icon Warning -Owner $script:HURemDlg.Window; return }
            try { Set-HURemotePin $p1 } catch { Show-HUMessage $_.Exception.Message -Icon Error -Owner $script:HURemDlg.Window; return }
            $c2['pwdRemPin1'].Password = ''; $c2['pwdRemPin2'].Password = ''
            if ($script:HURem) { $script:HURem.S.Pin = Read-HURemotePin }
            Write-HULogOK 'Fernbedienung: PIN festgelegt.'
            Update-HURemoteDialog
        })
    $c['btnRemOptSave'].Add_Click({
            $c2 = $script:HURemDlg.C
            $cfg = Get-HURemoteConfig
            $p = 0
            if (-not [int]::TryParse("$($c2['txtRemPort'].Text)".Trim(), [ref]$p) -or $p -lt 1025 -or $p -gt 65535) { Show-HUMessage 'Port: Zahl von 1025 bis 65535.' -Icon Warning -Owner $script:HURemDlg.Window; return }
            $nets = @("$($c2['txtRemNets'].Text)" -split '[,; ]+' | Where-Object { $_ })
            foreach ($n in $nets) { if ($n -notmatch '^[0-9./]+$' -or @(Get-HURemoteFirewallRemote @($n)).Count -lt 2) { Show-HUMessage "'$n' ist kein gueltiges Netz (z. B. 192.168.99.0/24)." -Icon Warning -Owner $script:HURemDlg.Window; return } }
            $netChanged = ((@($cfg.Networks) -join ',') -ne ($nets -join ',')) -or ($cfg.Port -ne $p)
            $cfg.AutoStart = [bool]$c2['chkRemAuto'].IsChecked; $cfg.WhenLocked = [bool]$c2['chkRemLocked'].IsChecked; $cfg.KeepAwake = [bool]$c2['chkRemAwake'].IsChecked; $cfg.Intune = [bool]$c2['chkRemIntune'].IsChecked
            $cfg.Port = $p; $cfg.Networks = $nets
            Save-HURemoteConfig $cfg
            if ($script:HURem) { $script:HURem.Cfg = $null }
            Write-HULogOK 'Fernbedienung: Einstellungen gespeichert.'
            if ($netChanged -and $cfg.SetupPort) { Show-HUMessage 'Port bzw. Netze geaendert - bitte die Einrichtung erneuern (Firewall-Regel und Port-Freigabe).' -Icon Info -Owner $script:HURemDlg.Window }
            Update-HURemoteDialog
        })
    $c['btnRemSetup'].Add_Click({ if (Invoke-HURemoteSetup 'Install' $script:HURemDlg.Window) { Show-HUMessage 'Fernbedienung eingerichtet. Jetzt im Reiter Status einschalten.' -Icon Info -Owner $script:HURemDlg.Window }; Update-HURemoteDialog })
    $c['btnRemUnsetup'].Add_Click({
            if (-not (Confirm-HU 'Einrichtung entfernen (HTTPS-Bindung, Port-Freigabe, Firewall-Regel, Server-Zertifikat)? Die gemeinsame CA bleibt fuer HUMig.' -Owner $script:HURemDlg.Window)) { return }
            if ($script:HURem) { Stop-HURemote 'Einrichtung entfernt' }
            [void](Invoke-HURemoteSetup 'Uninstall' $script:HURemDlg.Window); Update-HURemoteDialog
        })
    $c['btnRemMarkSave'].Add_Click({ Save-HURemoteMarksFromGrid })
    Initialize-HURemoteMarksGrid
    Update-HURemoteDialog
    $d.Window.Show()
}
function Open-HURemotePairUi {
    $c = $script:HURemDlg.C
    if (-not $script:HURem) { if (-not (Start-HURemote -Owner $script:HURemDlg.Window)) { return } }
    $r = $script:HURem
    $code = Open-HURemotePairing $r.S
    $url = "https://$($r.Ip):$($r.Port)/#c=$code"
    try { $c['imgRemQr'].Source = ConvertTo-HURemoteQrImage $url } catch { Write-HULogWarn "Fernbedienung: QR-Code nicht erzeugt - $($_.Exception.Message) (Zeile $($_.InvocationInfo.ScriptLineNumber))" }
    $c['txtRemCode'].Text = ($code.Substring(0, 3) + ' ' + $code.Substring(3))
    $c['txtRemPairInfo'].Text = "Gilt 10 Minuten, einmal. Adresse: https://$($r.Ip):$($r.Port)`nZuerst am Handy das Zertifikat installieren (Seite oeffnen > Zertifikat laden), dann koppeln."
    $c['txtRemFp'].Text = "CA SHA-256: $($r.CaFp)"
    $c['pnlRemPair'].Visibility = 'Visible'
}
function Set-HURemoteDeviceAction([string]$What) {
    $c = $script:HURemDlg.C
    $sel = $c['gridRemDev'].SelectedItem
    $devs = if ($script:HURem) { $script:HURem.S.Devices } else { Read-HURemoteDevices }
    if ($What -eq 'all') {
        if (-not $devs.Count -or -not (Confirm-HU "Alle $($devs.Count) Handys entkoppeln?" -Warning -Owner $script:HURemDlg.Window)) { return }
        $devs.Clear()
    } else {
        if (-not $sel) { Show-HUMessage 'Bitte ein Handy in der Liste waehlen.' -Icon Info -Owner $script:HURemDlg.Window; return }
        $key = "$($sel.Hash)"
        if (-not $devs.ContainsKey($key)) { return }
        if ($What -eq 'unlock') { $devs[$key].Locked = $false; $devs[$key].PinFails = 0; Write-HULogInfo "Fernbedienung: Handy '$($sel.Name)' entsperrt" }
        else { $devs.Remove($key); Write-HULogInfo "Fernbedienung: Handy '$($sel.Name)' entfernt" }
    }
    try { Save-HURemoteDevices $devs } catch { Show-HUMessage $_.Exception.Message -Icon Error -Owner $script:HURemDlg.Window }
    Update-HURemoteDialog
}
function Update-HURemoteDialog {
    $d = $script:HURemDlg; if (-not $d) { return }
    $c = $d.C
    $r = $script:HURem
    if ($r) {
        $c['dotRem'].Fill = Get-HUBrush '#4CAF50'
        $c['txtRemState'].Text = "Aktiv seit $($r.Started.ToString('HH:mm'))$(if ($r.S.Busy) { " - am PC laeuft: $($r.S.Busy)" })"
        $c['txtRemUrl'].Text = "https://$($r.Ip):$($r.Port)$(if (@($r.Ips).Count -gt 1) { "   (weitere: $((@($r.Ips) | Select-Object -Skip 1) -join ', '))" })"
        $c['btnRemOnOff'].Content = 'Ausschalten'; $c['btnRemOnOff'].Background = Get-HUBrush '#C62828'
        $j = $r.S.Job
        $c['txtRemJob'].Text = if ($j.Running) { "Vom Handy '$($j.By)' laeuft: $($j.Title)$(if ($j.Live) { ' (ECHTER LAUF)' })" } elseif ($j.Title) { "Zuletzt: $($j.Title) - $($j.Result)" } else { '' }
    } else {
        $c['dotRem'].Fill = Get-HUBrush '#666666'
        $c['txtRemState'].Text = 'Aus'
        $c['txtRemUrl'].Text = ''
        $c['txtRemJob'].Text = ''
        $c['btnRemOnOff'].Content = 'Einschalten'; $c['btnRemOnOff'].Background = Get-HUBrush '#4CAF50'
        $c['pnlRemPair'].Visibility = 'Collapsed'
    }
    $devs = if ($r) { $r.S.Devices } else { Read-HURemoteDevices }
    $sel = $c['gridRemDev'].SelectedItem; $selH = if ($sel) { "$($sel.Hash)" } else { '' }
    $rows = @(foreach ($k in @($devs.Keys)) { $x = $devs[$k]; [pscustomobject]@{ Hash = $k; Name = "$($x.Name)"; Created = "$($x.Created)"; LastSeen = "$($x.LastSeen)"; LastIp = "$($x.LastIp)"; State = $(if ($x.Locked) { 'GESPERRT (PIN)' } elseif ("$($x.PushEndpoint)") { 'ok, Push an' } else { 'ok' }) } })
    $c['gridRemDev'].ItemsSource = $rows
    if ($selH) { foreach ($x in $rows) { if ($x.Hash -eq $selH) { $c['gridRemDev'].SelectedItem = $x } } }
    $pin = Read-HURemotePin
    $c['txtRemPin'].Text = if ($pin) { "PIN gesetzt ($($pin.Set))" } else { 'noch keine PIN - echte Laeufe vom Handy sind gesperrt' }
    $st = Get-HURemoteSetupState
    $c['txtRemSetup'].Text = "$($st.Text)$(if ($st.Warn) { "`n$($st.Warn)" })"
    $c['txtRemSetup'].Foreground = Get-HUBrush $(if (-not $st.Ok) { '#FFB74D' } elseif ($st.Warn) { '#FFB74D' } else { '#81C784' })
    $c['txtRemFoot'].Text = 'Protokoll der Zugriffe und Laeufe: Logs\Remote. Client Secrets und Webhook-Adressen bleiben am PC; was ein Skript ausgibt, sieht das Handy.'
}

# Freigaben-Tabelle (DataTable: Zwei-Wege-Bindung der Auswahlspalte)
function Initialize-HURemoteMarksGrid {
    $c = $script:HURemDlg.C
    $marks = Get-HURemoteMarks
    $dt = New-Object System.Data.DataTable
    foreach ($n in 'Art', 'Name', 'Freigabe', 'Hinweis', 'Key', 'Kind', 'Hash', 'OldHash') { [void]$dt.Columns.Add($n) }
    foreach ($sn in @(Get-HUSnippets)) {
        $h = Get-HUTeamsCodeHash "$($sn.code)"
        $mk = $marks.Snippets["$($sn.name)"]
        $f = if (-not $mk) { 'aus' } elseif ($mk.Mode -eq 'read') { 'nur lesend' } else { 'aendert Daten' }
        $hint = if ($mk -and $mk.Hash -ne $h) { 'GEAENDERT - zum Erneuern speichern' } elseif ($sn.category) { "$($sn.category)" } else { '' }
        [void]$dt.Rows.Add('Snippet', "$($sn.name)", $f, $hint, "$($sn.name)", 'snippet', $h, $(if ($mk) { "$($mk.Hash)" } else { '' }))
    }
    $root = Join-Path $script:AppRoot 'Extensions'
    foreach ($exi in @($script:ExtensionItems)) {
        $ex = if ($exi -and $exi.PSObject.Properties['ExtensionObj']) { $exi.ExtensionObj } else { $exi }   # Liste haelt Anzeige-Objekte, die Erweiterung steckt in ExtensionObj
        if (-not $ex -or -not $ex.Path) { continue }
        $rel = "$($ex.Path)".Replace($root, '').TrimStart('\', '/')
        $h = ''; try { $h = Get-HURemoteFileHash $ex.Path } catch { }
        $mk = $marks.Extensions[$rel]
        $f = if (-not $mk) { 'aus' } elseif ($mk.Mode -eq 'read') { 'nur lesend' } else { 'aendert Daten' }
        $hint = if ("$($ex.Runtime)" -eq 'PS7') { 'nur PowerShell 7 - nicht vom Handy' } elseif ($mk -and $mk.Hash -ne $h) { 'GEAENDERT - zum Erneuern speichern' } elseif ("$($ex.Mode)" -eq 'ReadWrite') { 'schreibt (.MODE ReadWrite)' } else { '' }
        [void]$dt.Rows.Add('Erweiterung', "$($ex.Name)", $f, $hint, $rel, 'ext', $h, $(if ($mk) { "$($mk.Hash)" } else { '' }))
    }
    $c['gridRemMarks'].ItemsSource = $dt.DefaultView
    $script:HURemMarksTable = $dt
    $c['txtRemMarkInfo'].Text = "$(@($dt.Rows | Where-Object { $_.Freigabe -ne 'aus' }).Count) freigegeben"
}
function Save-HURemoteMarksFromGrid {
    $c = $script:HURemDlg.C
    try { [void]$c['gridRemMarks'].CommitEdit('Row', $true) } catch { }
    $m = @{ Snippets = @{}; Extensions = @{} }
    $warn = @()
    # Review 032 B3: nach der Freigabe geaenderten Code nicht still neu freigeben - Liste zeigen und bestaetigen lassen
    $rows = @($script:HURemMarksTable.Rows | Where-Object { "$($_.Freigabe)" -ne 'aus' -and "$($_.Hinweis)" -notlike 'nur PowerShell 7*' })
    $chg = @($rows | Where-Object { "$($_.OldHash)" -and "$($_.OldHash)" -ne "$($_.Hash)" })
    $renew = $true
    if ($chg.Count) {
        $renew = Confirm-HU ("Der Code dieser Freigaben wurde seit der Freigabe geaendert:`n`n" + (($chg | ForEach-Object { "  - $($_.Art): $($_.Name)" }) -join "`n") + "`n`nDie geaenderte Fassung fuers Handy freigeben?`n(Nein: bleiben gesperrt, bis Du sie erneuerst)") -Title 'Freigaben erneuern' -Warning -Owner $script:HURemDlg.Window
    }
    foreach ($row in $rows) {
        $mode = switch ("$($row.Freigabe)") { 'nur lesend' { 'read' } 'aendert Daten' { 'write' } default { '' } }
        if (-not $mode) { continue }
        $hash = if (-not $renew -and "$($row.OldHash)" -and "$($row.OldHash)" -ne "$($row.Hash)") { "$($row.OldHash)" } else { "$($row.Hash)" }
        if ("$($row.Kind)" -eq 'snippet') { $m.Snippets["$($row.Key)"] = @{ Mode = $mode; Hash = $hash } }
        else {
            if ($mode -eq 'read' -and "$($row.Hinweis)" -like 'schreibt*') { $warn += "$($row.Name)" }
            $m.Extensions["$($row.Key)"] = @{ Mode = $mode; Hash = $hash }
        }
    }
    try { Save-HURemoteMarks $m } catch { Show-HUMessage "Freigaben nicht gespeichert: $($_.Exception.Message)" -Icon Error -Owner $script:HURemDlg.Window; return }
    Write-HULogOK "Fernbedienung: $($m.Snippets.Count) Snippet(s) und $($m.Extensions.Count) Erweiterung(en) fuers Handy freigegeben$(if ($chg.Count) { if ($renew) { " ($($chg.Count) geaenderte erneuert)" } else { " ($($chg.Count) geaenderte bleiben gesperrt)" } })."
    if ($warn.Count) { Show-HUMessage "Als 'nur lesend' markiert, aber laut Kopf schreibend (.MODE ReadWrite) - gilt am Handy trotzdem als 'aendert Daten':`n$($warn -join ', ')" -Icon Warning -Owner $script:HURemDlg.Window }
    Initialize-HURemoteMarksGrid
    if ($script:HURem) { try { Update-HURemoteCatalog } catch { } }
}
