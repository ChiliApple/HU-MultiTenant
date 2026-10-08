#Requires -Version 5.1
<#
.SYNOPSIS
    Quick Script: Verlauf der Laeufe (wann, welches Snippet, welche Tenants, Dauer, Ergebnis) mit Protokoll je Lauf.
.DESCRIPTION
    Logs\QuickScript\verlauf.jsonl          - eine Zeile je Lauf (die letzten 2000 werden behalten)
    Logs\QuickScript\<Datum>_<Zeit>_<Snippet>.log - vollstaendige Ausgabe des Laufs
    Protokolle aelter als logging.retentionDays (Standard 30 Tage) werden beim Start geloescht.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:QSHistDir = Join-Path $script:AppRoot 'Logs\QuickScript'
$script:QSHistFile = Join-Path $script:QSHistDir 'verlauf.jsonl'
$script:QS_RunLines = $null     # Ausgabezeilen des laufenden Laufs (fuer die Protokolldatei)

function Add-HUQSHistory {
    param([string]$Snippet, [string[]]$Tenants, [double]$Seconds, [string]$Result, [int]$Errors, [int]$Objects, [string[]]$Lines, [string]$Code)
    try {
        if (-not (Test-Path -LiteralPath $script:QSHistDir)) { New-Item -ItemType Directory -Path $script:QSHistDir -Force | Out-Null }
        $now = Get-Date
        $safe = ("$Snippet" -replace '[\\/:*?"<>|\s]+', '_').Trim('_')
        if (-not $safe) { $safe = 'Editor' }
        if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
        $log = Join-Path $script:QSHistDir ("{0}_{1}.log" -f $now.ToString('yyyy-MM-dd_HHmmss'), $safe)
        $head = @(
            "Quick Script: $Snippet"
            "Zeit:         $($now.ToString('dd.MM.yyyy HH:mm:ss'))"
            "Tenants:      $($Tenants -join ', ')"
            "Benutzer:     $env:USERDOMAIN\$env:USERNAME auf $env:COMPUTERNAME"
            "Dauer:        $([Math]::Round($Seconds, 1)) s"
            "Ergebnis:     $Result$(if ($Errors) { " ($Errors Fehler)" })"
            ('-' * 70)
        )
        $body = @($Lines) + @('', ('-' * 70), 'Code:', $Code)
        [System.IO.File]::WriteAllLines($log, [string[]]($head + $body), (New-Object System.Text.UTF8Encoding $true))
        $entry = [pscustomobject][ordered]@{
            Time = $now.ToString('s'); Snippet = "$Snippet"; Tenants = @($Tenants); Seconds = [Math]::Round($Seconds, 1)
            Result = $Result; Errors = $Errors; Objects = $Objects; Log = (Split-Path $log -Leaf)
        }
        $json = $entry | ConvertTo-Json -Compress -Depth 3
        [System.IO.File]::AppendAllText($script:QSHistFile, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { Write-HULogDebug "Verlauf: $($_.Exception.Message)" }
}

function Get-HUQSHistory([string]$Snippet = '') {
    if (-not (Test-Path -LiteralPath $script:QSHistFile)) { return @() }
    $list = foreach ($ln in [System.IO.File]::ReadAllLines($script:QSHistFile)) {
        if (-not $ln.Trim()) { continue }
        try { $e = $ln | ConvertFrom-Json } catch { continue }
        if ($Snippet -and $e.Snippet -ne $Snippet) { continue }
        $e
    }
    return @($list | Sort-Object { $_.Time } -Descending)
}

# Letzter Lauf eines Snippets als Kurztext (Snippet-Verwaltung)
function Get-HUQSLastRunText([string]$Snippet) {
    $h = Get-HUQSHistory $Snippet | Select-Object -First 1
    if (-not $h) { return '' }
    $t = try { ([datetime]$h.Time).ToString('dd.MM.yy HH:mm') } catch { "$($h.Time)" }
    return "Zuletzt ausgefuehrt: $t auf $(@($h.Tenants) -join ', ') - $($h.Result) ($($h.Seconds) s)"
}

function Show-HUQSHistory([string]$Snippet = '') {
    $all = @(Get-HUQSHistory $Snippet | Select-Object -First 500)
    if (-not $all.Count) { Show-HUMessage 'Noch keine Laeufe aufgezeichnet.' 'Verlauf'; return }
    $rows = foreach ($h in $all) {
        [pscustomobject][ordered]@{
            Zeit = $(try { ([datetime]$h.Time).ToString('dd.MM.yyyy HH:mm:ss') } catch { "$($h.Time)" })
            Snippet = "$($h.Snippet)"; Tenants = (@($h.Tenants) -join ', '); Dauer = "$($h.Seconds) s"
            Ergebnis = "$($h.Result)"; Fehler = $h.Errors; Objekte = $h.Objects; Protokoll = "$($h.Log)"
        }
    }
    $sel = Show-HUTableDialog -Title "Quick Script - Verlauf$(if ($Snippet) { ": $Snippet" })" -OkText 'Protokoll oeffnen' -Rows @($rows) -Width 1100 -Height 560 `
        -Hint "Je Lauf wird die komplette Ausgabe in Logs\QuickScript\ gespeichert (Aufbewahrung: $(Get-HURetentionDays) Tage). Doppelklick oeffnet das Protokoll."
    if ($sel -and $sel.Protokoll) {
        $f = Join-Path $script:QSHistDir $sel.Protokoll
        if (Test-Path -LiteralPath $f) { Start-Process notepad.exe -ArgumentList "`"$f`"" } else { Show-HUMessage "Protokoll nicht mehr vorhanden:`n$f" -Icon Warning }
    }
}

function Get-HURetentionDays {
    $d = 30
    try { if ([int]$script:Settings.logging.retentionDays -gt 0) { $d = [int]$script:Settings.logging.retentionDays } } catch { }
    return $d
}

# Aufraeumen beim Start: alte Protokolle loeschen, Verlauf auf 2000 Zeilen kuerzen
function Clear-HUQSHistoryOld {
    try {
        if (-not (Test-Path -LiteralPath $script:QSHistDir)) { return }
        $limit = (Get-Date).AddDays(-(Get-HURetentionDays))
        Get-ChildItem -LiteralPath $script:QSHistDir -Filter *.log -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:QSHistFile) {
            $lines = [System.IO.File]::ReadAllLines($script:QSHistFile)
            if ($lines.Count -gt 2000) { [System.IO.File]::WriteAllLines($script:QSHistFile, [string[]]($lines | Select-Object -Last 2000), (New-Object System.Text.UTF8Encoding $false)) }
        }
    } catch { }
}
