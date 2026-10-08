#Requires -Version 5.1
<#
.SYNOPSIS
    Automatische Pruefungen fuer HU-MultiTenant (GitHub Actions, Windows PowerShell 5.1) - blockierend.
.DESCRIPTION
    1. Syntax aller PowerShell-Dateien (Parser), UTF-8-BOM
    2. XAML-Fenster laden (mit Theme); alle im Code verwendeten Steuerelemente vorhanden
    3. Konfigurationsdateien (JSON) lesbar
    4. Update-Bibliothek in Pull.ps1 und Functions\Core-Update.ps1 identisch
    5. Version: Config\version.json = oberster Eintrag in CHANGELOG.md
    6. PSScriptAnalyzer: keine Fehler (Schweregrad Error)
    7. Pester-Tests (.github\tests\*.Tests.ps1)
.NOTES
    Aufruf (auch lokal): powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1
    Zielmaschine: Windows-PC / GitHub-Runner mit Internet (PSScriptAnalyzer, Pester werden bei Bedarf installiert).
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fail = New-Object System.Collections.Generic.List[string]
function Step([string]$Name, [scriptblock]$Do) {
    Write-Host "== $Name" -ForegroundColor Cyan
    try { $r = & $Do; if ($r) { Write-Host "   $r" -ForegroundColor Green } else { Write-Host '   OK' -ForegroundColor Green } }
    catch { $fail.Add("$Name : $($_.Exception.Message)"); Write-Host "   FEHLER: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "HU-MultiTenant CI - PowerShell $($PSVersionTable.PSVersion) - $([Environment]::OSVersion.VersionString)"

# 1. Syntax + BOM
Step 'Syntax und UTF-8-BOM aller .ps1/.psm1' {
    $bad = @()
    $files = @(Get-ChildItem -Path $root -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '\\(Logs|Reports|\.git)\\' })
    foreach ($f in $files) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { $bad += "$($f.Name): " + (($e | Select-Object -First 2 | ForEach-Object { "Zeile $($_.Extent.StartLineNumber) $($_.Message)" }) -join ' | ') }
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
            # ohne BOM nur erlaubt, wenn die Datei reines ASCII ist (PS 5.1 liest sonst Umlaute falsch)
            if (@($b | Where-Object { $_ -gt 127 }).Count) { $bad += "$($f.Name): Nicht-ASCII-Zeichen ohne UTF-8-BOM" }
        }
    }
    if ($bad.Count) { throw ($bad -join '; ') }
    "$($files.Count) Dateien"
}

# 2. XAML + Steuerelemente
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$script:AppRoot = $root
. (Join-Path $root 'Functions\UI-Common.ps1')
$script:Win = @{}
foreach ($pair in @(
        @{ X = 'MainWindow'; Code = @('Main.ps1', 'Functions\UI-Tenants.ps1', 'Functions\UI-QuickScript.ps1', 'Functions\UI-State.ps1', 'Functions\UI-Extensions.ps1', 'Functions\UI-Snippets.ps1', 'Functions\UI-Update.ps1', 'Functions\UI-QSParams.ps1', 'Functions\UI-QSTable.ps1', 'Functions\UI-QSHistory.ps1', 'Functions\UI-Apps.ps1', 'Functions\UI-IntuneApps.ps1', 'Functions\UI-Maint.ps1', 'Functions\UI-IntuneRem.ps1'); Pattern = "(?:\`$script:Controls|\`$c)\['([A-Za-z0-9_]+)'\]" }
        @{ X = 'SettingsWindow'; Code = @('Functions\UI-Settings.ps1'); Pattern = '\$c\.([A-Za-z][A-Za-z0-9_]*)' }
        @{ X = 'SnippetManager'; Code = @('Functions\UI-Snippets.ps1'); Pattern = '\$c\.([A-Za-z][A-Za-z0-9_]*)' }
        @{ X = 'PermissionsWindow'; Code = @('Functions\UI-Permissions.ps1'); Pattern = '\$c\.([A-Za-z][A-Za-z0-9_]*)' }
    )) {
    Step "XAML $($pair.X) + verwendete Steuerelemente" {
        $d = New-HUWindow $pair.X
        $names = @()
        foreach ($cf in $pair.Code) {
            $txt = Get-Content (Join-Path $root $cf) -Raw -Encoding UTF8
            if ($pair.X -eq 'SnippetManager') { $txt = $txt.Substring($txt.IndexOf('function Show-HUSnippetManager')) }
            $names += @([regex]::Matches($txt, $pair.Pattern) | ForEach-Object { $_.Groups[1].Value })
        }
        $names = @($names | Sort-Object -Unique)
        $miss = @($names | Where-Object { -not $d.C.ContainsKey($_) })
        if ($miss.Count) { throw "fehlt im XAML: $($miss -join ', ')" }
        $d.Window.Close()
        "$($names.Count) Steuerelemente"
    }
}

# 3. JSON
Step 'Konfigurationsdateien (JSON)' {
    $n = 0
    foreach ($f in @(Get-ChildItem (Join-Path $root 'Config') -Filter *.json)) { [void](Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json); $n++ }
    "$n Dateien"
}

# 4. Update-Bibliothek identisch
Step 'Update-Bibliothek Pull.ps1 = Functions\Core-Update.ps1' {
    $re = '(?s)#region HMUpdateLib.*?#endregion HMUpdateLib'
    $a = [regex]::Match((Get-Content (Join-Path $root 'Pull.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    $b = [regex]::Match((Get-Content (Join-Path $root 'Functions\Core-Update.ps1') -Raw -Encoding UTF8), $re).Value -replace "`r`n", "`n"
    if (-not $a -or -not $b) { throw 'Bereich HMUpdateLib fehlt' }
    if ($a -ne $b) { throw 'Bereich HMUpdateLib unterscheidet sich - beide Dateien gleich halten' }
    "$(($a -split "`n").Count) Zeilen"
}

# 5. Version
Step 'Version (Config\version.json = CHANGELOG.md)' {
    $v = (Get-Content (Join-Path $root 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    $m = [regex]::Match((Get-Content (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8), '(?m)^## v([0-9.]+)')
    if (-not $m.Success) { throw 'kein "## v<Version>" in CHANGELOG.md' }
    if ($m.Groups[1].Value -ne $v) { throw "version.json $v, CHANGELOG.md $($m.Groups[1].Value)" }
    "v$v"
}

# 6. PSScriptAnalyzer
function Install-HUModule([string]$Name, [string]$Max = '') {
    if (Get-Module -ListAvailable -Name $Name | Where-Object { -not $Max -or $_.Version -le [Version]$Max } | Select-Object -First 1) { return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    $p = @{ Name = $Name; Force = $true; Scope = 'CurrentUser'; SkipPublisherCheck = $true; AllowClobber = $true }
    if ($Max) { $p.MaximumVersion = $Max }
    Install-Module @p
}
Step 'PSScriptAnalyzer (Fehler)' {
    Install-HUModule 'PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error)
    if ($r.Count) { throw (($r | Select-Object -First 10 | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }) -join ' | ') }
    'keine Fehler'
}

# 7. Pester
Step 'Pester-Tests' {
    Install-HUModule 'Pester' '5.99.99'
    Import-Module Pester -MaximumVersion 5.99.99 -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $PSScriptRoot
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'Detailed'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount -gt 0) { throw "$($res.FailedCount) von $($res.TotalCount) Tests fehlgeschlagen" }
    "$($res.PassedCount) Tests bestanden"
}

Write-Host ''
if ($fail.Count) {
    Write-Host "FEHLGESCHLAGEN ($($fail.Count)):" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    if ($env:GITHUB_STEP_SUMMARY) { (@('### HU-MultiTenant CI: FEHLGESCHLAGEN') + @($fail | ForEach-Object { "- $_" })) | Add-Content $env:GITHUB_STEP_SUMMARY }
    exit 1
}
Write-Host 'ALLE PRUEFUNGEN BESTANDEN' -ForegroundColor Green
if ($env:GITHUB_STEP_SUMMARY) { '### HU-MultiTenant CI: alle Pruefungen bestanden' | Add-Content $env:GITHUB_STEP_SUMMARY }
exit 0
