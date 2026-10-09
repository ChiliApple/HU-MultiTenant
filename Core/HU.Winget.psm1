#Requires -Version 5.1
<#
.SYNOPSIS
    winget-Anbindung fuer App-Updates: neueste Version ermitteln, Pakete suchen, Installer herunterladen.
.DESCRIPTION
    Bevorzugt das Modul Microsoft.WinGet.Client (Find-WinGetPackage), sonst winget.exe (Textausgabe).
    Nur Quelle "winget" (Community-Repository) - Store-Apps aktualisiert der Store selbst.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (winget = App-Installer aus dem Store, ab Windows 10 1809).
#>

# Versionen vergleichen: -1 (A aelter), 0 (gleich), 1 (A neuer). Ziffernbloecke numerisch, Rest als Text.
function Compare-HUVersion([string]$A, [string]$B) {
    # Build-Angaben nach '+' (z. B. 1.3.323+7f37e7) zaehlen nicht (wie bei SemVer)
    $A = ("$A" -split '\+')[0]; $B = ("$B" -split '\+')[0]
    $pa = @("$A".Trim() -replace '^[vV]', '' -split '[.\-_ ]' | Where-Object { $_ -ne '' })
    $pb = @("$B".Trim() -replace '^[vV]', '' -split '[.\-_ ]' | Where-Object { $_ -ne '' })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { '0' }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { '0' }
        $nx = 0L; $ny = 0L
        $ix = [long]::TryParse($x, [ref]$nx); $iy = [long]::TryParse($y, [ref]$ny)
        if ($ix -and $iy) { if ($nx -ne $ny) { return $(if ($nx -lt $ny) { -1 } else { 1 }) }; continue }
        $c = [string]::Compare($x, $y, [StringComparison]::OrdinalIgnoreCase)
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return 0
}

function Get-HUWingetExe {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Test-HUWingetModule { return [bool](Get-Command Find-WinGetPackage -ErrorAction SilentlyContinue) }

# winget.exe ausfuehren, Ausgabezeilen ohne Fortschrittsanzeigen
function Invoke-HUWinget([string[]]$Arguments) {
    $exe = Get-HUWingetExe
    if (-not $exe) { throw 'winget ist nicht installiert (App-Installer aus dem Microsoft Store).' }
    $old = $null
    try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $out = @(& $exe @Arguments 2>&1 | ForEach-Object { "$_" }) }
    finally { if ($old) { try { [Console]::OutputEncoding = $old } catch { } } }
    $lines = foreach ($l in $out) {
        $t = ($l -split "`r")[-1]
        $t = $t -replace '[▀-▟]', ''
        if ($t -match '^\s*[-\\|/]\s*$') { continue }
        if ($t -match '^\s*[\d.,]+\s*(KB|MB|GB)\s*/\s*[\d.,]+\s*(KB|MB|GB)\s*$') { continue }
        $t.TrimEnd()
    }
    return @($lines | Where-Object { $_ -ne $null })
}

# Tabelle aus "winget search" zerlegen (Spaltenpositionen aus der Kopfzeile, Sprache egal)
function ConvertFrom-HUWingetTable([string[]]$Lines) {
    $sep = -1
    for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^-{10,}\s*$') { $sep = $i; break } }
    if ($sep -lt 1) { return @() }
    $head = $Lines[$sep - 1]
    $starts = @([regex]::Matches($head, '(?<=^|\s)\S') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 3) { return @() }
    $rows = foreach ($l in @($Lines | Select-Object -Skip ($sep + 1))) {
        if (-not $l.Trim()) { continue }
        $col = for ($k = 0; $k -lt $starts.Count; $k++) {
            $s = $starts[$k]
            if ($s -ge $l.Length) { ''; continue }
            $e = if ($k + 1 -lt $starts.Count) { [Math]::Min($starts[$k + 1], $l.Length) } else { $l.Length }
            $l.Substring($s, $e - $s).Trim()
        }
        $col = @($col)
        if ($col.Count -ge 3 -and $col[1]) { [pscustomobject]@{ Name = $col[0]; Id = $col[1]; Version = $col[2] } }
    }
    return @($rows)
}

# Pakete suchen -> Name, Id, Version
function Find-HUWingetPackage([string]$Query, [int]$Max = 10, [string]$Source = 'winget') {
    if (-not $Source) { $Source = 'winget' }
    if (-not "$Query".Trim()) { return @() }
    if (Test-HUWingetModule) {
        try {
            return @(Find-WinGetPackage -Query $Query -Source $Source -ErrorAction Stop | Select-Object -First $Max | ForEach-Object { [pscustomobject]@{ Name = "$($_.Name)"; Id = "$($_.Id)"; Version = "$($_.Version)" } })
        } catch { }
    }
    $lines = Invoke-HUWinget @('search', '--query', $Query, '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    return @(ConvertFrom-HUWingetTable $lines | Select-Object -First $Max)
}

# neueste Version einer winget-ID ('' = nicht gefunden)
function Get-HUWingetLatest([string]$Id, [string]$Source = 'winget') {
    if (-not $Source) { $Source = 'winget' }
    if (-not "$Id".Trim()) { return '' }
    if (Test-HUWingetModule) {
        try {
            $p = Find-WinGetPackage -Id $Id -MatchOption Equals -Source $Source -ErrorAction Stop | Select-Object -First 1
            if ($p) { return "$($p.Version)" }
        } catch { }
    }
    $lines = Invoke-HUWinget @('show', '--id', $Id, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    foreach ($l in $lines) { if ($l -match '^\s*Version\s*:\s*(\S+)') { return $Matches[1] } }
    return ''
}

# Installer herunterladen -> Pfad der Setup-Datei (.msi bevorzugt, wenn -PreferMsi)
function Save-HUWingetInstaller([string]$Id, [string]$Version, [string]$Folder, [switch]$PreferMsi, [string]$Source = 'winget') {
    if (-not $Source) { $Source = 'winget' }
    if (-not (Test-Path -LiteralPath $Folder)) { [void](New-Item -ItemType Directory -Path $Folder -Force) }
    $base = @('download', '--id', $Id, '--exact', '--source', $Source, '--download-directory', $Folder, '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity', '--skip-dependencies')
    if ($Version) { $base += @('--version', $Version) }
    $variants = @(
        @('--architecture', 'x64', '--scope', 'machine') + $(if ($PreferMsi) { @('--installer-type', 'msi') } else { @() }),
        @('--architecture', 'x64', '--scope', 'machine'),
        @('--architecture', 'x64'),
        @()
    )
    $log = @()
    foreach ($v in $variants) {
        $log += @(Invoke-HUWinget ($base + $v))
        $files = @(Get-ChildItem -LiteralPath $Folder -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '(?i)^\.(msi|exe)$' })
        if ($files.Count) {
            $pick = $null
            if ($PreferMsi) { $pick = $files | Where-Object { $_.Extension -eq '.msi' } | Sort-Object Length -Descending | Select-Object -First 1 }
            if (-not $pick) { $pick = $files | Sort-Object Length -Descending | Select-Object -First 1 }
            return [pscustomobject]@{ Path = $pick.FullName; Log = $log }
        }
    }
    throw "Kein Installer heruntergeladen. winget: $((@($log | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ')"
}

# eingerichtete Quellen (winget source list)
function Get-HUWingetSources {
    if (Get-Command Get-WinGetSource -ErrorAction SilentlyContinue) {
        try { return @(Get-WinGetSource -ErrorAction Stop | ForEach-Object { "$($_.Name)" } | Where-Object { $_ }) } catch { }
    }
    $lines = @(Invoke-HUWinget @('source', 'list', '--disable-interactivity'))
    $sep = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{5,}\s*$') { $sep = $i; break } }
    if ($sep -lt 0) { return @() }
    return @($lines | Select-Object -Skip ($sep + 1) | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
}

# Leise-Schalter aus dem heruntergeladenen Manifest (winget legt eine .yaml daneben)
function Get-HUWingetSilentSwitch([string]$Folder) {
    $y = Get-ChildItem -LiteralPath $Folder -Filter *.yaml -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $y) { return '' }
    $txt = Get-Content -LiteralPath $y.FullName -Raw -Encoding UTF8
    $m = [regex]::Match($txt, '(?m)^\s*Silent:\s*(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim("'", '"') }
    return ''
}

Export-ModuleMember -Function Get-HUWingetSources, Compare-HUVersion, Get-HUWingetExe, Test-HUWingetModule, Invoke-HUWinget, ConvertFrom-HUWingetTable, Find-HUWingetPackage, Get-HUWingetLatest, Save-HUWingetInstaller, Get-HUWingetSilentSwitch
