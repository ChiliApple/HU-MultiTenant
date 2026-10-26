#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatzmodule: signierte Erweiterungen aus privaten Repositories (eigener Reiter).
.DESCRIPTION
    Ein Zusatzmodul liegt in einem privaten GitHub-Repository. Installiert und aktualisiert wird es nur, wenn dafuer ein
    Nur-Lese-Token hinterlegt ist. Jedes Modul-Release braucht eine Pruefsummen-Datei mit Signatur des Herausgeber-
    Zertifikats (gleiches Zertifikat wie HU-MultiTenant selbst). Beim Start wird jede Datei erneut gegen die
    gespeicherte, signierte Pruefsummen-Datei geprueft; nur dann wird das Modul geladen.

    Aufbau eines Moduls (im Repository):
      addon.json   { "id": "<Kennung>", "title": "...", "version": "1.0.0", "minApp": "2.3.1",
                     "tab": { "header": "...", "xaml": "Tab.xaml", "script": "Addon.ps1", "init": "Initialize-HUAddon<Kennung>" } }
      Tab.xaml     Wurzel <TabItem>; Theme ueber <TabItem.Resources><!--HU:THEME--></TabItem.Resources>
      Addon.ps1    Funktionen des Moduls (wird in den Programm-Bereich geladen), Einstieg = "init"
    Lokal: <AppRoot>\Addons\<Kennung>\ (Dateien + addon.sha256 + addon.sha256.p7s); neue Fassungen warten in
    Addons\.pending\<Kennung>\ und werden beim naechsten Start uebernommen.
    Tokens: %APPDATA%\HU-MultiTenant\addons\<owner>_<repo>.xml (DPAPI, nur fuer diesen Windows-Benutzer lesbar).
    Daten der Module: %APPDATA%\HU-MultiTenant\AddonData\<Id>\ (Get-HUAddonDataDir), in der App-Sicherung enthalten.
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

$script:HUAddonManifest = 'addon.sha256'
$script:HUAddonSignature = 'addon.sha256.p7s'

function Get-HUAddonsDir { return (Join-Path $script:AppRoot 'Addons') }
function Get-HUAddonTokenDir {
    $d = Join-Path (Join-Path $env:APPDATA 'HU-MultiTenant') 'addons'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# 2.5.3: Datenordner je Zusatzmodul (eigene Dateien, Archive, Protokolle): %APPDATA%\HU-MultiTenant\AddonData\<Id>\
# - pro Windows-Benutzer, neben den DPAPI-Secrets; die App-Sicherung nimmt AddonData\ komplett mit.
# Zusatzmodule rufen diese Funktion; fehlt sie (aeltere App), denselben Pfad selbst bilden.
function Get-HUAddonDataRoot {
    $base = $(if ($env:APPDATA) { $env:APPDATA } else { [IO.Path]::GetTempPath() })
    return (Join-Path (Join-Path $base 'HU-MultiTenant') 'AddonData')
}
function Get-HUAddonDataDir([string]$Id) {
    if (-not (Test-HUAddonId $Id)) { throw "Ungueltige Kennung fuer Zusatzmodul-Daten: '$Id'" }
    $d = Join-Path (Get-HUAddonDataRoot) $Id
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# Kennung eines Moduls: Buchstaben/Ziffern, beginnt mit Buchstabe (wird Teil von Funktions- und Ordnernamen)
function Test-HUAddonId([string]$Id) { return ("$Id" -cmatch '^[A-Za-z][A-Za-z0-9]{1,30}$') }
function Test-HUAddonRepoName([string]$Owner, [string]$Repo) { return ("$Owner" -match '^[A-Za-z0-9-]{1,39}$' -and "$Repo" -match '^[A-Za-z0-9._-]{1,100}$') }

# --- Tokens (DPAPI) --------------------------------------------------------------------------
function Save-HUAddonToken([string]$Owner, [string]$Repo, [Security.SecureString]$Token) {
    if (-not (Test-HUAddonRepoName $Owner $Repo)) { throw 'Repository-Name ungueltig (Besitzer/Name)' }
    $cred = New-Object System.Management.Automation.PSCredential -ArgumentList "$Owner/$Repo", $Token
    $cred | Export-Clixml -LiteralPath (Join-Path (Get-HUAddonTokenDir) "$Owner`_$Repo.xml") -Force
}
function Remove-HUAddonToken([string]$Owner, [string]$Repo) {
    Remove-Item -LiteralPath (Join-Path (Get-HUAddonTokenDir) "$Owner`_$Repo.xml") -Force -ErrorAction SilentlyContinue
}
# Hinterlegte Module: Owner, Repo, Token (Klartext nur im Speicher)
function Get-HUAddonSources {
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-HUAddonTokenDir) -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
        try {
            $c = Import-Clixml -LiteralPath $f.FullName
            $parts = "$($c.UserName)" -split '/', 2
            if ($parts.Count -ne 2 -or -not (Test-HUAddonRepoName $parts[0] $parts[1])) { continue }
            $out += [pscustomobject]@{ Owner = $parts[0]; Repo = $parts[1]; Token = $c.GetNetworkCredential().Password }
        } catch { }
    }
    return $out
}

# --- Pruefen ---------------------------------------------------------------------------------
# addon.json lesen und pruefen. Rueckgabe: Objekt mit Error = '' (gueltig) oder Grund.
function Read-HUAddonInfo([string]$Dir) {
    $o = [pscustomobject]@{ Id = ''; Title = ''; Version = $null; MinApp = $null; Header = ''; Xaml = ''; Script = ''; Init = ''; Dir = $Dir; Error = '' }
    $f = Join-Path $Dir 'addon.json'
    if (-not (Test-Path -LiteralPath $f)) { $o.Error = 'addon.json fehlt'; return $o }
    try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $o.Error = 'addon.json nicht lesbar'; return $o }
    $o.Id = "$($j.id)"; $o.Title = "$($j.title)"
    if (-not (Test-HUAddonId $o.Id)) { $o.Error = 'Kennung (id) ungueltig'; return $o }
    $o.Version = ConvertTo-HMVersion "$($j.version)"; $o.MinApp = ConvertTo-HMVersion "$($j.minApp)"
    if (-not $o.Version -or -not $o.MinApp) { $o.Error = 'version/minApp ungueltig'; return $o }
    $rel = { param($p) if ("$p" -and "$p" -notmatch '(^[\\/])|(\.\.)|:' -and "$p" -match '^[A-Za-z0-9._\\/ -]+$') { "$p" } else { '' } }
    if (-not $j.tab) { $o.Error = 'tab fehlt'; return $o }
    if ($j.tab) {
        $o.Header = "$($j.tab.header)"; $o.Xaml = & $rel $j.tab.xaml; $o.Script = & $rel $j.tab.script; $o.Init = "$($j.tab.init)"
        if (-not $o.Xaml -or -not $o.Script -or $o.Init -cnotmatch '^Initialize-HUAddon[A-Za-z0-9]+$') { $o.Error = 'tab: xaml/script/init ungueltig'; return $o }
    }
    return $o
}

# Alle Dateien eines Modul-Ordners gegen die signierte Pruefsummen-Datei pruefen. '' = gueltig, sonst Grund.
# Ausfuehrbare Dateien (ps1, psm1, xaml), die nicht in der Pruefsummen-Datei stehen, machen das Modul ungueltig.
function Test-HUAddonFiles([string]$Dir, [string]$Thumbprint) {
    $mf = Join-Path $Dir $script:HUAddonManifest; $sf = Join-Path $Dir $script:HUAddonSignature
    if (-not (Test-Path -LiteralPath $mf) -or -not (Test-Path -LiteralPath $sf)) { return 'Pruefsummen- oder Signatur-Datei fehlt' }
    $man = [System.IO.File]::ReadAllBytes($mf)
    $why = Test-HMManifestSignature $man ([System.IO.File]::ReadAllBytes($sf)) $Thumbprint
    if ($why) { return $why }
    $m = ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($man))
    if (-not $m.Count) { return 'Pruefsummen-Datei leer' }
    foreach ($k in $m.Keys) {
        $p = Join-Path $Dir ($k -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p)) { return "Datei fehlt: $k" }
        if ((Get-HMFileSha256 $p) -ne $m[$k]) { return "Datei veraendert: $k" }
    }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    # Endung selbst filtern: -Include wird von Windows PowerShell 5.1 zusammen mit -LiteralPath ignoriert
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.xaml' })) {
        $relp = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
        if (-not $m.ContainsKey($relp)) { return "fremde Datei: $relp" }
    }
    return ''
}

# Wartende neue Fassungen uebernehmen (vor dem Laden, beim Start)
function Use-HUAddonPending([string]$AddonsDir) {
    $pend = Join-Path $AddonsDir '.pending'
    if (-not (Test-Path -LiteralPath $pend)) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $pend -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-HUAddonId $d.Name)) { continue }
        $dst = Join-Path $AddonsDir $d.Name
        try {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction Stop }
            Move-Item -LiteralPath $d.FullName -Destination $dst -Force -ErrorAction Stop
        } catch { }
    }
}

# Module zum Laden: gueltig signiert, passende Programmversion. Rueckgabe je Ordner: Info mit Error.
function Get-HUAddonsToLoad([string]$AddonsDir, [Version]$AppVersion, [string]$Thumbprint) {
    if (-not (Test-Path -LiteralPath $AddonsDir)) { return @() }
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $AddonsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' })) {
        $i = Read-HUAddonInfo $d.FullName
        if (-not $i.Error -and $i.Id -cne $d.Name) { $i.Error = 'Ordnername passt nicht zur Kennung' }
        if (-not $i.Error) { $why = Test-HUAddonFiles $d.FullName $Thumbprint; if ($why) { $i.Error = "nicht vertrauenswuerdig: $why" } }
        if (-not $i.Error -and $AppVersion -lt $i.MinApp) { $i.Error = "braucht HU-MultiTenant $($i.MinApp) oder neuer" }
        $out += $i
    }
    return $out
}

# --- Installieren / Aktualisieren --------------------------------------------------------------
# Neueste signierte Fassung (Kanal wie das Programm) laden, pruefen und unter Addons\.pending\<Kennung> ablegen.
# Rueckgabe: Status (Neu, Aktuell, Fehler), Text, Id, Version.
function Install-HUAddon([string]$Owner, [string]$Repo, [string]$Token, [string]$AddonsDir, [Version]$AppVersion, [string]$Channel = 'Stable', [string]$Thumbprint) {
    $res = [pscustomobject]@{ Status = 'Fehler'; Text = ''; Id = ''; Version = $null }
    try {
        $rel = Select-HMRelease (Get-HMReleases $Owner $Repo $Token) $Channel -SignedOnly
        if (-not $rel) { $res.Text = 'kein signiertes Release gefunden'; return $res }
        $man = Get-HMReleaseAsset $rel.ManifestUrl $rel.ManifestApi $Token
        $sig = Get-HMReleaseAsset $rel.SignatureUrl $rel.SignatureApi $Token
        $why = Test-HMManifestSignature $man $sig $Thumbprint
        if ($why) { $res.Text = "Signatur: $why"; return $res }
        $m = ConvertFrom-HMManifest ([System.Text.Encoding]::UTF8.GetString($man))
        if (-not $m.ContainsKey('addon.json')) { $res.Text = 'kein Zusatzmodul (addon.json fehlt im Release)'; return $res }
        $stage = Join-Path (Join-Path $AddonsDir '.staging') ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            $h = @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = $script:HMUserAgent; Authorization = "token $Token" }
            foreach ($k in $m.Keys) {
                if ($k -match '(^[\\/])|(\.\.)|:' -or $k -notmatch '^[A-Za-z0-9._/ -]+$') { throw "unzulaessiger Pfad im Release: $k" }
                $dst = Join-Path $stage ($k -replace '/', '\')
                $dd = Split-Path $dst -Parent; if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
                $enc = ($k -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                Invoke-WebRequest "https://api.github.com/repos/$Owner/$Repo/contents/${enc}?ref=$($rel.Tag)" -Headers $h -UseBasicParsing -TimeoutSec 60 -OutFile $dst -ErrorAction Stop
                if ((Get-HMFileSha256 $dst) -ne $m[$k]) { throw "Pruefsumme stimmt nicht: $k" }
            }
            [System.IO.File]::WriteAllBytes((Join-Path $stage $script:HUAddonManifest), $man)
            [System.IO.File]::WriteAllBytes((Join-Path $stage $script:HUAddonSignature), $sig)
            $i = Read-HUAddonInfo $stage
            if ($i.Error) { throw $i.Error }
            if ($AppVersion -lt $i.MinApp) { throw "braucht HU-MultiTenant $($i.MinApp) oder neuer" }
            $why = Test-HUAddonFiles $stage $Thumbprint
            if ($why) { throw $why }
            $res.Id = $i.Id; $res.Version = $i.Version
            $cur = Read-HUAddonInfo (Join-Path $AddonsDir $i.Id)
            if (-not $cur.Error -and $cur.Version -ge $i.Version) { $res.Status = 'Aktuell'; $res.Text = "$($i.Title) $($i.Version) ist aktuell"; return $res }
            $pend = Join-Path (Join-Path $AddonsDir '.pending') $i.Id
            if (Test-Path -LiteralPath $pend) { Remove-Item -LiteralPath $pend -Recurse -Force }
            New-Item -ItemType Directory -Path (Split-Path $pend -Parent) -Force | Out-Null
            Move-Item -LiteralPath $stage -Destination $pend -Force
            $res.Status = 'Neu'; $res.Text = "$($i.Title) $($i.Version) geladen - wirkt nach dem Neustart von HU-MultiTenant"
            return $res
        } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue } }
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        $res.Text = $(if ($code -in 401, 403, 404) { "kein Zugriff auf $Owner/$Repo (HTTP $code) - Token pruefen" } else { "$($_.Exception.Message)" })
        return $res
    }
}
