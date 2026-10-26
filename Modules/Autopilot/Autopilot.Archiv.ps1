#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatzmodul Autopilot - Hash-Archiv: Dateien einlesen, verschluesselt ablegen (DPAPI), zusammenfuehren.
.DESCRIPTION
    Reine Funktionen ohne Oberflaeche und ohne Graph (testbar). Ablage je Tenant in
    %APPDATA%\HU-MultiTenant\AddonData\Autopilot\HashArchiv_<Tenant>.dat (Get-HUAddonDataDir, sonst gleicher Pfad).
    Der Hash ist bei jedem Lesen am Geraet anders - deshalb mehrere Hashes je Seriennummer, der neueste gilt.
    Benutzer (Assigned User) aus CSV-Dateien wird bewusst NICHT gespeichert (Konzept 3.3).
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Daten nur fuer diesen Windows-Benutzer lesbar).
#>

$script:APArchivEntropy = [Text.Encoding]::UTF8.GetBytes('HU-MultiTenant-Autopilot-Hash-Archiv-v1')
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

function Get-APArchivDir {
    if (Get-Command Get-HUAddonDataDir -ErrorAction SilentlyContinue) { return (Get-HUAddonDataDir 'Autopilot') }
    $d = Join-Path $env:APPDATA 'HU-MultiTenant\AddonData\Autopilot'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}
function Get-APArchivDatei([string]$Tenant, [string]$Dir = '') {
    $k = ("$Tenant" -replace '[^A-Za-z0-9_-]', '')
    if (-not $k) { throw 'Tenant fehlt' }
    $base = if ($Dir) { $Dir } else { Get-APArchivDir }
    return (Join-Path $base "HashArchiv_$k.dat")
}

function Get-APSha([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes("$Text")) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}
function Test-APHashText([string]$Hash) {
    $h = "$Hash".Trim()
    if ($h.Length -lt 1000) { return $false }
    try { return ([Convert]::FromBase64String($h).Length -gt 500) } catch { return $false }
}
function ConvertTo-APSerialKey([string]$S) { return ("$S" -replace '\s', '').ToUpperInvariant() }

# Ein Archiv-Eintrag = ein Hash einer Seriennummer aus einer Quelle
function New-APArchivEintrag {
    param([string]$Seriennummer, [string]$Hash, [string]$Quelle, [string]$Datei = '', [string]$Lieferung = '', [string]$ProductId = '', [string]$GroupTag = '', [string]$Eingelesen = '')
    $h = "$Hash".Trim()
    return [pscustomobject]@{
        Seriennummer = "$Seriennummer".Trim()
        ProductId    = "$ProductId".Trim()
        Hash         = $h
        Sha          = (Get-APSha $h)
        Quelle       = $Quelle
        Datei        = $Datei
        Lieferung    = $Lieferung
        GroupTag     = "$GroupTag".Trim()
        Eingelesen   = $(if ($Eingelesen) { $Eingelesen } else { (Get-Date).ToString('yyyy-MM-dd HH:mm') })
    }
}

# --- Ablage (DPAPI, aktueller Windows-Benutzer) ------------------------------------------------
function Read-APArchiv([string]$Tenant, [string]$Dir = '') {
    $f = Get-APArchivDatei $Tenant $Dir
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $enc = [IO.File]::ReadAllBytes($f)
    $raw = [Security.Cryptography.ProtectedData]::Unprotect($enc, $script:APArchivEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $j = [Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json
    return @($j.eintraege | Where-Object { $_ })
}
function Save-APArchiv([string]$Tenant, [object[]]$Eintraege, [string]$Dir = '') {
    $f = Get-APArchivDatei $Tenant $Dir
    $obj = [pscustomobject]@{ version = 1; tenant = $Tenant; gespeichert = (Get-Date).ToString('s'); eintraege = @($Eintraege) }
    $raw = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5 -Compress))
    $enc = [Security.Cryptography.ProtectedData]::Protect($raw, $script:APArchivEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $tmp = "$f.tmp"
    [IO.File]::WriteAllBytes($tmp, $enc)
    # PowerShell macht aus `$null` sonst einen leeren Text ("Pfad hat ein ungueltiges Format") - deshalb [NullString]::Value
    if (Test-Path -LiteralPath $f) { [IO.File]::Replace($tmp, $f, [NullString]::Value) } else { [IO.File]::Move($tmp, $f) }
}

# Neue Eintraege hinzufuegen; gleicher Hash (SHA256) bei gleicher Seriennummer = schon bekannt
function Merge-APArchiv([object[]]$Alt, [object[]]$Neu) {
    $liste = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($e in @($Alt)) { if (-not $e) { continue }; $k = "$(ConvertTo-APSerialKey $e.Seriennummer)|$($e.Sha)"; if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; [void]$liste.Add($e) } }
    $n = 0; $b = 0
    foreach ($e in @($Neu)) {
        if (-not $e) { continue }
        $k = "$(ConvertTo-APSerialKey $e.Seriennummer)|$($e.Sha)"
        if ($seen.ContainsKey($k)) { $b++; continue }
        $seen[$k] = 1; [void]$liste.Add($e); $n++
    }
    return [pscustomobject]@{ Liste = @($liste.ToArray()); Neu = $n; Bekannt = $b }
}

# --- Dateien lesen ---------------------------------------------------------------------------
# Spalte finden (Gross/klein, Leerzeichen, - und _ egal)
function Get-APSpaltenwert($Row, [string[]]$Namen) {
    foreach ($p in $Row.PSObject.Properties) {
        $n = ("$($p.Name)" -replace '[\s_-]', '').ToLowerInvariant()
        if ($Namen -contains $n) { return "$($p.Value)" }
    }
    return $null
}
$script:APSpalten = @{
    Serial = @('deviceserialnumber', 'serialnumber', 'seriennummer', 'serial')
    Hash   = @('hardwarehash', 'hash', 'devicehardwaredata', '4khh', 'hardwarehash4k')
    Pid    = @('windowsproductid', 'productid', 'produktid')
    Tag    = @('grouptag', 'gruppentag', 'ordertag')
}
# Liefert @{ Eintraege; Fehler (Liste Text); Format }
function Read-APHashDatei([string]$Pfad, [string]$Quelle = 'Datei') {
    $res = [pscustomobject]@{ Eintraege = @(); Fehler = @(); Format = '' }
    $name = [IO.Path]::GetFileName($Pfad)
    $lief = [IO.Path]::GetFileNameWithoutExtension($Pfad)
    $ext = [IO.Path]::GetExtension($Pfad).ToLowerInvariant()
    $rows = @()
    if ($ext -eq '.csv' -or $ext -eq '.txt') {
        $first = @(Get-Content -LiteralPath $Pfad -TotalCount 1 -Encoding UTF8)[0]
        $delim = if (([regex]::Matches("$first", ';')).Count -gt ([regex]::Matches("$first", ',')).Count) { ';' } else { ',' }
        $rows = @(Import-Csv -LiteralPath $Pfad -Delimiter $delim -Encoding UTF8)
        $res.Format = "CSV ($delim)"
    } elseif ($ext -eq '.xlsx') {
        $ok = $false
        if (Get-Command Initialize-HUExcel -ErrorAction SilentlyContinue) { try { $ok = [bool](Initialize-HUExcel) } catch { $ok = $false } }
        if (-not $ok -or -not (Get-Command Import-Excel -ErrorAction SilentlyContinue)) { $res.Fehler = @("$name`: Excel kann nicht gelesen werden (Modul ImportExcel fehlt) - bitte als CSV speichern"); return $res }
        $rows = @(Import-Excel -Path $Pfad)
        $res.Format = 'Excel'
    } else { $res.Fehler = @("$name`: Dateityp $ext wird nicht unterstuetzt (CSV oder Excel)"); return $res }
    if (-not $rows.Count) { $res.Fehler = @("$name`: keine Zeilen"); return $res }
    if ($null -eq (Get-APSpaltenwert $rows[0] $script:APSpalten.Serial) -or $null -eq (Get-APSpaltenwert $rows[0] $script:APSpalten.Hash)) {
        $res.Fehler = @("$name`: Spalten 'Device Serial Number' und 'Hardware Hash' nicht gefunden"); return $res
    }
    $out = New-Object System.Collections.ArrayList; $err = New-Object System.Collections.ArrayList
    $i = 1
    foreach ($r in $rows) {
        $i++
        $s = "$(Get-APSpaltenwert $r $script:APSpalten.Serial)".Trim()
        $h = "$(Get-APSpaltenwert $r $script:APSpalten.Hash)".Trim()
        if (-not $s -and -not $h) { continue }
        if (-not $s) { [void]$err.Add("$name Zeile $i`: Seriennummer fehlt"); continue }
        if (-not (Test-APHashText $h)) { [void]$err.Add("$name Zeile $i ($s): Hash fehlt oder ungueltig"); continue }
        [void]$out.Add((New-APArchivEintrag -Seriennummer $s -Hash $h -Quelle $Quelle -Datei $name -Lieferung $lief -ProductId "$(Get-APSpaltenwert $r $script:APSpalten.Pid)" -GroupTag "$(Get-APSpaltenwert $r $script:APSpalten.Tag)"))
    }
    $res.Eintraege = @($out.ToArray()); $res.Fehler = @($err.ToArray())
    return $res
}

# --- Anzeige ---------------------------------------------------------------------------------
# Eine Zeile je Seriennummer (neuester Hash) + Abgleich mit den geladenen Autopilot-Geraeten des Tenants.
# Ohne geladene Uebersicht reicht fuer 'In Autopilot' die Liste der Seriennummern ($SerienSet, Schluessel = ConvertTo-APSerialKey).
function Get-APArchivZeilen([object[]]$Eintraege, [object[]]$ApRows, [switch]$MitFehlenden, [hashtable]$SerienSet) {
    $ap = @{}
    foreach ($r in @($ApRows)) { if ($r) { $ap[(ConvertTo-APSerialKey $r.Seriennummer)] = $r } }
    $out = New-Object System.Collections.ArrayList
    $da = @{}
    foreach ($g in @(@($Eintraege) | Where-Object { $_ } | Group-Object { ConvertTo-APSerialKey $_.Seriennummer })) {
        $neu = @($g.Group | Sort-Object Eingelesen -Descending)[0]
        $k = "$($g.Name)"; $da[$k] = 1
        $a = if ($ap.ContainsKey($k)) { $ap[$k] } else { $null }
        [void]$out.Add([pscustomobject]@{
                Seriennummer = "$($neu.Seriennummer)"
                HashDa       = 'ja'
                Anzahl       = $g.Count
                Quelle       = "$($neu.Quelle)"
                Lieferung    = "$($neu.Lieferung)"
                Eingelesen   = "$($neu.Eingelesen)"
                InAutopilot  = $(if ($a) { 'ja' } elseif (@($ApRows).Count) { 'nein' } elseif ($null -ne $SerienSet) { if ($SerienSet.ContainsKey($k)) { 'ja' } else { 'nein' } } else { '?' })
                Geraetename  = $(if ($a) { "$($a.Geraetename)" } else { '' })
                Benutzer     = $(if ($a) { "$($a.Benutzer)" } else { '' })
                GroupTag     = $(if ($a) { "$($a.GroupTag)" } else { "$($neu.GroupTag)" })
                Modell       = $(if ($a) { "$($a.Modell)" } else { '' })
                Eingerichtet = $(if ($a) { "$($a.EingerichtetAm)" } else { '' })
                IntuneId     = $(if ($a) { "$($a.IntuneId)" } else { '' })
                Ausgeschieden = (Get-APAusgeschieden $g.Group)
            })
    }
    if ($MitFehlenden) {
        foreach ($k in $ap.Keys) {
            if ($da.ContainsKey($k)) { continue }
            $a = $ap[$k]
            [void]$out.Add([pscustomobject]@{
                    Seriennummer = "$($a.Seriennummer)"; HashDa = 'nein'; Anzahl = 0; Quelle = ''; Lieferung = ''; Eingelesen = ''
                    InAutopilot = 'ja'; Geraetename = "$($a.Geraetename)"; Benutzer = "$($a.Benutzer)"; GroupTag = "$($a.GroupTag)"; Modell = "$($a.Modell)"; Eingerichtet = "$($a.EingerichtetAm)"; IntuneId = "$($a.IntuneId)"; Ausgeschieden = ''
                })
        }
    }
    return @($out.ToArray())
}
# Ausgeschieden markieren (Datum) bzw. aufheben (leer) - gilt fuer alle Hashes der Seriennummer; der Hash bleibt im Archiv
function Set-APAusgeschieden([object[]]$Eintraege, [string[]]$Serien, [string]$Datum) {
    $set = @{}; foreach ($x in @($Serien)) { $set[(ConvertTo-APSerialKey $x)] = 1 }
    foreach ($e in @($Eintraege)) {
        if (-not $e) { continue }
        if ($set.ContainsKey((ConvertTo-APSerialKey $e.Seriennummer))) { $e | Add-Member -NotePropertyName Ausgeschieden -NotePropertyValue $Datum -Force }
        $e
    }
}
function Get-APAusgeschieden([object[]]$Gruppe) {
    $d = @($Gruppe | ForEach-Object { if ($_.PSObject.Properties['Ausgeschieden']) { "$($_.Ausgeschieden)" } } | Where-Object { $_ } | Sort-Object -Descending)
    if ($d.Count) { return $d[0] } return ''
}
# Neuester Hash je Seriennummer (fuer Export)
function Get-APNeuesterHash([object[]]$Eintraege, [string]$Seriennummer) {
    $k = ConvertTo-APSerialKey $Seriennummer
    return (@(@($Eintraege) | Where-Object { $_ -and (ConvertTo-APSerialKey $_.Seriennummer) -eq $k } | Sort-Object Eingelesen -Descending) | Select-Object -First 1)
}


# --- Ausscheiden: Vorgaenge (verschluesselt wie das Archiv) und Protokolle -------------------------
function Get-APVorgangDatei([string]$Tenant, [string]$Dir = '') {
    $k = ("$Tenant" -replace '[^A-Za-z0-9_-]', '')
    if (-not $k) { throw 'Tenant fehlt' }
    $base = if ($Dir) { $Dir } else { Get-APArchivDir }
    return (Join-Path $base "Ausscheiden_$k.dat")
}
function Read-APVorgaenge([string]$Tenant, [string]$Dir = '') {
    $f = Get-APVorgangDatei $Tenant $Dir
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $raw = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($f), $script:APArchivEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return @(([Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json).vorgaenge | Where-Object { $_ })
}
function Save-APVorgaenge([string]$Tenant, [object[]]$Liste, [string]$Dir = '') {
    $f = Get-APVorgangDatei $Tenant $Dir
    $raw = [Text.Encoding]::UTF8.GetBytes(([pscustomobject]@{ version = 1; tenant = $Tenant; vorgaenge = @($Liste) } | ConvertTo-Json -Depth 6 -Compress))
    $tmp = "$f.tmp"
    [IO.File]::WriteAllBytes($tmp, [Security.Cryptography.ProtectedData]::Protect($raw, $script:APArchivEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser))
    if (Test-Path -LiteralPath $f) { [IO.File]::Replace($tmp, $f, [NullString]::Value) } else { [IO.File]::Move($tmp, $f) }
}
function Get-APProtokollDir([string]$Tenant, [string]$Dir = '') {
    $k = ("$Tenant" -replace '[^A-Za-z0-9_-]', '')
    $base = if ($Dir) { $Dir } else { Get-APArchivDir }
    $d = Join-Path $base "Ausscheiden\$k\$((Get-Date).ToString('yyyy-MM-dd'))"
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}
function ConvertTo-APHtml([string]$T) { return [Net.WebUtility]::HtmlEncode("$T") }
# Protokoll je Geraet (HTML zum Drucken) + Import-CSV fuer die neue Schule (wenn ein Hash da ist). Rueckgabe: Pfade
function Write-APAusProtokoll($Vorgang, [string]$TenantName, $Hash, [string]$Ordner) {
    $v = $Vorgang
    $ser = ("$($v.Seriennummer)" -replace '[^A-Za-z0-9_-]', '')
    $zeilen = (@($v.Schritte | ForEach-Object { "<tr><td>$(ConvertTo-APHtml $_.Zeit)</td><td>$(ConvertTo-APHtml $_.Schritt)</td><td>$(ConvertTo-APHtml $_.Ergebnis)</td></tr>" }) -join "`n")
    $hashTxt = if ($Hash -and "$($Hash.Hash)") { "<p class='h'>$(ConvertTo-APHtml $Hash.Hash)</p><p>Product ID: $(ConvertTo-APHtml $Hash.ProductId)</p>" } else { '<p><b>Kein Hardware-Hash im Archiv.</b> Das Geraet kann an einer neuen Schule nur mit einem neu ausgelesenen Hash registriert werden.</p>' }
    $html = @"
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Ausscheidungsprotokoll $ser</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:20px}table{border-collapse:collapse;width:100%;margin:8px 0 16px}td,th{border:1px solid #bbb;padding:4px 8px;text-align:left;font-size:13px}th{background:#eee}.h{font-family:Consolas,monospace;font-size:9px;word-break:break-all}</style></head><body>
<h1>Ausscheidungsprotokoll</h1>
<table>
<tr><th>Schule (Tenant)</th><td>$(ConvertTo-APHtml $TenantName)</td></tr>
<tr><th>Datum</th><td>$(ConvertTo-APHtml $v.Start)</td></tr>
<tr><th>Seriennummer</th><td>$(ConvertTo-APHtml $v.Seriennummer)</td></tr>
<tr><th>Hersteller / Modell</th><td>$(ConvertTo-APHtml "$($v.Hersteller) $($v.Modell)")</td></tr>
<tr><th>Geraetename</th><td>$(ConvertTo-APHtml $v.Geraetename)</td></tr>
<tr><th>Group Tag (bisher)</th><td>$(ConvertTo-APHtml $v.GroupTag)</td></tr>
<tr><th>Bisheriger Primaerbenutzer</th><td>$(ConvertTo-APHtml $v.Benutzer)</td></tr>
</table>
<h2>Schritte</h2><table><tr><th>Zeit</th><th>Schritt</th><th>Ergebnis</th></tr>
$zeilen
</table>
<h2>Hardware-Hash</h2>$hashTxt
<p>Mit diesem Hash (bzw. der beiliegenden CSV) kann die IT einer neuen Schule das Geraet wieder per Windows Autopilot registrieren.</p>
</body></html>
"@
    $f = Join-Path $Ordner "${ser}_Ausscheidungsprotokoll.html"
    [IO.File]::WriteAllText($f, $html, (New-Object Text.UTF8Encoding($true)))
    $out = @($f)
    if ($Hash -and "$($Hash.Hash)") {
        $c = Join-Path $Ordner "${ser}_Autopilot-Import.csv"
        @([pscustomobject]@{ 'Device Serial Number' = "$($v.Seriennummer)"; 'Windows Product ID' = "$($Hash.ProductId)"; 'Hardware Hash' = "$($Hash.Hash)" }) | Export-Csv -LiteralPath $c -NoTypeInformation -Encoding UTF8
        $out += $c
    }
    return $out
}


# --- Liste fuer das Ausscheiden (Abgaenger): Seriennummern und/oder UPNs aus CSV, Excel oder Text ---------------
$script:APSpaltenUpn = @('userprincipalname', 'upn', 'benutzer', 'user', 'mail', 'email', 'emailadresse', 'primaryuser', 'assigneduser', 'schueler')
function Read-APListeDatei([string]$Pfad) {
    $ext = [IO.Path]::GetExtension($Pfad).ToLowerInvariant()
    $rows = @()
    if ($ext -eq '.xlsx') {
        if (Get-Command Initialize-HUExcel -ErrorAction SilentlyContinue) { try { [void](Initialize-HUExcel) } catch { } }
        if (-not (Get-Command Import-Excel -ErrorAction SilentlyContinue)) { throw 'Excel kann nicht gelesen werden (Modul ImportExcel fehlt) - bitte als CSV speichern' }
        $rows = @(Import-Excel -Path $Pfad)
    } elseif ($ext -in '.csv', '.txt') {
        $lines = @(Get-Content -LiteralPath $Pfad -Encoding UTF8 | Where-Object { "$_".Trim() })
        if (-not $lines.Count) { return @() }
        $first = "$($lines[0])"
        $delim = if (([regex]::Matches($first, ';')).Count -gt ([regex]::Matches($first, ',')).Count) { ';' } else { ',' }
        if ($first -notmatch '[;,]' -and $lines.Count -ge 1) {
            # eine Spalte ohne Trennzeichen: Kopfzeile nur, wenn sie wie ein Spaltenname aussieht
            $kopf = ($first -replace '[\s_-]', '').ToLowerInvariant()
            $daten = if (($script:APSpalten.Serial + $script:APSpaltenUpn) -contains $kopf) { @($lines | Select-Object -Skip 1) } else { $lines }
            return @(foreach ($l in $daten) { $v = "$l".Trim().Trim('"'); if ($v) { if ($v -match '@') { [pscustomobject]@{ Seriennummer = ''; Upn = $v } } else { [pscustomobject]@{ Seriennummer = $v; Upn = '' } } } })
        }
        $rows = @(Import-Csv -LiteralPath $Pfad -Delimiter $delim -Encoding UTF8)
    } else { throw "Dateityp $ext wird nicht unterstuetzt (CSV, TXT oder Excel)" }
    return @(foreach ($r in $rows) {
            $s = "$(Get-APSpaltenwert $r $script:APSpalten.Serial)".Trim()
            $u = "$(Get-APSpaltenwert $r $script:APSpaltenUpn)".Trim()
            if ($s -or $u) { [pscustomobject]@{ Seriennummer = $s; Upn = $(if ($u -match '@') { $u } else { '' }) } }
        })
}

# --- Ausscheide-Paket fuer die Eltern (ZIP je Geraet) --------------------------------------------------------
function Get-APNachname([string]$Upn) {
    $l = ("$Upn" -split '@')[0]
    $teile = @($l -split '[._]' | Where-Object { $_ })
    $n = if ($teile.Count -gt 1) { $teile[-1] } elseif ($teile.Count) { $teile[0] } else { 'Geraet' }
    return (($n -replace '[^A-Za-z0-9-]', '') -replace '^$', 'Geraet')
}
function New-APAusPaket($Vorgang, [string]$TenantName, $Hash, [string]$Ordner) {
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    $v = $Vorgang
    $ser = ("$($v.Seriennummer)" -replace '[^A-Za-z0-9_-]', '')
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hu-ap-paket-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        [void](Write-APAusProtokoll $v $TenantName $Hash $tmp)
        $anl = @"
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Hinweis zum Geraet $ser</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;max-width:760px}h1{font-size:20px}</style></head><body>
<h1>Hinweis zum Schulgeraet (Seriennummer $(ConvertTo-APHtml $v.Seriennummer))</h1>
<p>Dieses Geraet wurde aus der Verwaltung der Schule entlassen.</p>
<p>Wechselt Ihr Kind an eine andere Schule, die Geraete mit <b>Windows Autopilot</b> verwaltet, geben Sie bitte die beiliegende Datei
<b>${ser}_Autopilot-Import.csv</b> an die IT der neuen Schule weiter. Damit kann das Geraet dort wieder registriert werden.</p>
<p>Die Datei enthaelt die Seriennummer und eine technische Kennung des Geraets (Hardware-Hash), aber keine persoenlichen Daten.
Bitte nur an die IT der neuen Schule weitergeben.</p>
<p>Das beiliegende Protokoll zeigt, was beim Ausscheiden gemacht wurde.</p>
</body></html>
"@
        [IO.File]::WriteAllText((Join-Path $tmp 'Hinweis_fuer_Eltern.html'), $anl, (New-Object Text.UTF8Encoding($true)))
        $zip = Join-Path $Ordner "${ser}_$(Get-APNachname $v.Benutzer)_Ausscheiden.zip"
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zip)
        return $zip
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
# Uebergabe-Bestaetigung mit BitLocker-Schluessel - NUR zum Drucken, wird nicht dauerhaft gespeichert
function Write-APUebergabe($Vorgang, [string]$TenantName, [object[]]$Schluessel, [string]$Datei) {
    $v = $Vorgang
    $k = (@($Schluessel | ForEach-Object { "<tr><td>$(ConvertTo-APHtml $_.Laufwerk)</td><td>$(ConvertTo-APHtml $_.Id)</td><td style='font-family:Consolas,monospace;font-size:15px'>$(ConvertTo-APHtml $_.Schluessel)</td></tr>" }) -join "`n")
    if (-not $k) { $k = '<tr><td colspan="3">kein Wiederherstellungsschluessel gefunden</td></tr>' }
    $html = @"
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Uebergabe $(ConvertTo-APHtml $v.Seriennummer)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222;max-width:820px}table{border-collapse:collapse;width:100%;margin:8px 0 16px}td,th{border:1px solid #bbb;padding:5px 8px;text-align:left;font-size:13px}th{background:#eee}.u{margin-top:48px;display:flex;gap:48px}.u div{flex:1;border-top:1px solid #333;padding-top:4px;font-size:12px}</style></head><body>
<h1>Uebergabe-Bestaetigung</h1>
<table><tr><th>Schule (Tenant)</th><td>$(ConvertTo-APHtml $TenantName)</td></tr><tr><th>Datum</th><td>$((Get-Date).ToString('dd.MM.yyyy'))</td></tr>
<tr><th>Geraet</th><td>$(ConvertTo-APHtml "$($v.Hersteller) $($v.Modell)") - Seriennummer $(ConvertTo-APHtml $v.Seriennummer)</td></tr>
<tr><th>Bisheriger Benutzer</th><td>$(ConvertTo-APHtml $v.Benutzer)</td></tr></table>
<p>Das Geraet wurde aus der Verwaltung der Schule entlassen (Zurueckziehen). Die Daten auf dem Geraet bleiben erhalten.
Die Anmeldung ist weiterhin nur mit dem bisherigen Schulkonto moeglich - wird dieses nach dem Schulaustritt deaktiviert, ist eine Anmeldung nur noch mit einem vorhandenen lokalen Konto moeglich.
<b>Empfehlung:</b> Daten sichern und Windows anschliessend selbst neu einrichten.</p>
<h2>BitLocker-Wiederherstellungsschluessel</h2>
<p>Gut aufbewahren - wird beim Start ein Wiederherstellungsschluessel verlangt, ist er hier zu finden.</p>
<table><tr><th>Laufwerk</th><th>Schluessel-ID</th><th>Wiederherstellungsschluessel</th></tr>
$k
</table>
<div class="u"><div>Schule</div><div>Erziehungsberechtigte(r)</div></div>
</body></html>
"@
    [IO.File]::WriteAllText($Datei, $html, (New-Object Text.UTF8Encoding($true)))
}


# --- Aufbewahrung (Konzept 4.7, Udo 26.10.: 6 Monate): alte Protokoll-/Paket-Ordner finden -------------------
# Ordner Ausscheiden\<Tenant>\<yyyy-MM-dd>\ - das Datum im Ordnernamen zaehlt. Geloescht wird nur nach Rueckfrage.
function Get-APAlteProtokolle([int]$Monate = 6, [string]$Dir = '') {
    $base = Join-Path $(if ($Dir) { $Dir } else { Get-APArchivDir }) 'Ausscheiden'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $grenze = (Get-Date).Date.AddMonths(-$Monate)
    foreach ($t in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
        foreach ($d in @(Get-ChildItem -LiteralPath $t.FullName -Directory -ErrorAction SilentlyContinue)) {
            $dt = [datetime]::MinValue
            if ([datetime]::TryParseExact($d.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt) -and $dt -lt $grenze) {
                [pscustomobject]@{ Tenant = $t.Name; Datum = $d.Name; Pfad = $d.FullName; Dateien = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue).Count }
            }
        }
    }
}
# abgeschlossene Vorgaenge aelter als die Grenze (enthalten UPN) - fuer das Aufraeumen der Vorgangsliste
function Select-APVorgaengeBehalten([object[]]$Vorgaenge, [int]$Monate = 6) {
    $grenze = (Get-Date).AddMonths(-$Monate)
    foreach ($v in @($Vorgaenge)) {
        $dt = [datetime]::MinValue
        $alt = ([datetime]::TryParse("$($v.Start)", [ref]$dt) -and $dt -lt $grenze)
        $offen = -not ("$($v.Intune)" -in 'geloescht', 'weg' -or "$($v.Autopilot)" -eq 'wiederholt' -or ("$($v.Intune)" -eq 'kein Eintrag' -and "$($v.Autopilot)" -in 'entfernt', 'nicht (mehr) da'))
        if (-not $alt -or $offen) { $v }
    }
}
