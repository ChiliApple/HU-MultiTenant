#Requires -Version 5.1
<#
.SYNOPSIS
    Prueft alle Web-Links im Repository (Code, Doku, mitgelieferte Muster, Konfiguration) - tot, umgeleitet oder ok.
.DESCRIPTION
    Sammelt jede http(s)-Adresse aus *.ps1, *.psm1, *.json, *.md, *.html und *.xaml (ohne .git, Logs, Reports),
    fasst gleiche Adressen zusammen (mit allen Fundstellen) und fragt jede einmal ab (HEAD, bei Ablehnung GET).
    Ausgenommen sind Adressen, die keine Seiten sind: Graph-/Anmelde-Endpunkte, localhost, Beispiel-Domains und
    Vorlagen mit Platzhaltern ($, {}).
    Regel fuers Repo: Links stehen nur an diesen Stellen und immer vollstaendig (https://...), damit dieses Skript sie findet -
    Muster-Quellen in paket.json 'Learn', Doku-Links in Docs\*.html, Quellen im Code als Kommentar mit voller Adresse.
.PARAMETER Root
    Ordner des Repositorys (Standard: zwei Ebenen ueber diesem Skript).
.PARAMETER Offline
    Nur auflisten, nicht abfragen.
.PARAMETER Csv
    Ergebnis zusaetzlich als CSV speichern.
.PARAMETER PassThru
    Zeilen als Objekte zurueckgeben statt als Tabelle (fuer Tests und Weiterverarbeitung).
.EXAMPLE
    .\.github\scripts\Test-HULinks.ps1                 # alle pruefen, Rueckgabewert 1 bei toten Links
.EXAMPLE
    .\.github\scripts\Test-HULinks.ps1 -Offline        # nur Liste der Links mit Fundstellen
.NOTES
    Zielmaschine: Entwickler-PC oder GitHub-Runner mit Internet. Schreibt nichts im Repository.
#>
[CmdletBinding()]
param([string]$Root = '', [switch]$Offline, [string]$Csv = '', [int]$TimeoutSec = 20, [switch]$PassThru)

if (-not $Root) { $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$skipRx = '^https?://(localhost|127\.0\.0\.1|\[::1\])|^https?://[^/.]+(/|$)|example\.(com|org|net)|graph\.microsoft\.com|fonts\.(googleapis|gstatic)\.com|\u2026|login\.microsoftonline\.com|login\.windows\.net|api2\.cursor\.sh|schemas\.microsoft\.com|schemas\.openxmlformats\.org|www\.w3\.org/|[$\{\}]'
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include *.ps1, *.psm1, *.json, *.md, *.html, *.xaml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|Logs|Reports|node_modules)[\\/]' })
$found = @{}
foreach ($f in $files) {
    $txt = ''
    try { $txt = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    foreach ($m in [regex]::Matches($txt, 'https?://[^\s"''<>`\)\]\\|,]+')) {
        $u = $m.Value.TrimEnd('.', ';', ':', '*', '!', '?')
        if ($u -match $skipRx) { continue }
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        if (-not $found.ContainsKey($u)) { $found[$u] = New-Object System.Collections.Generic.List[string] }
        if (-not $found[$u].Contains($rel)) { $found[$u].Add($rel) }
    }
}
$rows = foreach ($u in @($found.Keys | Sort-Object)) {
    $st = ''; $final = ''
    if (-not $Offline) {
        foreach ($meth in 'Head', 'Get') {
            try {
                $r = Invoke-WebRequest -Uri $u -Method $meth -UseBasicParsing -MaximumRedirection 5 -TimeoutSec $TimeoutSec -ErrorAction Stop
                $st = "$([int]$r.StatusCode)"
                try { $final = "$($r.BaseResponse.ResponseUri)"; if (-not $final) { $final = "$($r.BaseResponse.RequestMessage.RequestUri)" } } catch { }
                break
            } catch {
                $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                $st = $(if ($code) { "$code" } else { "Fehler: $($_.Exception.Message)" })
                if ($code -notin 400, 403, 405, 500, 501, 502, 503) { break }   # abgelehntes HEAD (manche Server) mit GET nochmal
            }
        }
    }
    $ok = $Offline -or ($st -match '^2\d\d$')
    # uebliche Umleitungen nicht melden: Sprache (/en-us/), Anmeldeseite, Portal ohne Anmeldung, nur Kodierung/Abfrage
    $redir = ''
    if ($final -and $final.TrimEnd('/') -ne $u.TrimEnd('/')) {
        $norm = { param($x) ([Uri]::UnescapeDataString("$x") -replace '/[a-z]{2}-[a-z]{2}/', '/' -replace '[?#].*$', '').TrimEnd('/') }
        # Kurzlinks (aka.ms), 'latest'/'raw' von GitHub und Schema-Adressen leiten absichtlich um
        $boring = ($u -match '^https?://aka\.ms/|/releases/latest$|github\.com/.+/raw/|adaptivecards\.io/schemas') -or ($final -match '^https://login\.(microsoftonline\.com|windows\.net)/') -or ($final -match '/Error/UE_404') -or ((& $norm $final) -eq (& $norm $u))
        if (-not $boring) { $redir = $final }
    }
    [pscustomobject]@{ Status = $(if ($Offline) { '-' } elseif ($ok) { 'ok' } else { "TOT ($st)" }); Url = $u; Umgeleitet = $redir; Fundstellen = ($found[$u] -join '; ') }
}
$rows = @($rows)
if ($PassThru) { return $rows }
$rows | Format-Table -AutoSize -Wrap
$bad = @($rows | Where-Object { $_.Status -like 'TOT*' })
"{0} Links in {1} Dateien, {2} tot, {3} dauerhaft umgezogen (Adresse im Repo aktualisieren)." -f $rows.Count, $files.Count, $bad.Count, @($rows | Where-Object { $_.Umgeleitet }).Count
if ($Csv) { $rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8 -Delimiter ';' }
if ($bad.Count) { exit 1 }
