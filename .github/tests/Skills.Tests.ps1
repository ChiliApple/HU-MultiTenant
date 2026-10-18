#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer die Skills hu-snippet und hu-extension: Pruefprogramme, Vorlagen, Anleitungen.
.DESCRIPTION
    Ziel: Was in den Anleitungen (skills\*\SKILL.md) steht, stimmt mit dem Programmcode ueberein - und bleibt es.
    1. Pruefprogramme erkennen die dokumentierten Fehler (und melden die Vorlagen nicht).
    2. Vorlagen laufen gegen eine Graph-Attrappe (Snippets: wie die Laufzeit, Extensions: ueber den echten Lader).
    3. Die Attrappen haben die Parameter der echten Funktionen (sonst wuerde der Test Fehler verdecken).
    4. Die Vorlagen stehen woertlich in den Anleitungen, alle Regeln sind beschrieben.
    5. Aussagen der Anleitungen, die auf dem Programmcode beruhen, werden gegen den Code geprueft (faellt auf, wenn sich der Code aendert).
    Kein Netzwerk, keine Oberflaeche.
.NOTES
    Aufruf: Invoke-Pester .github\tests\Skills.Tests.ps1   (oder ueber Invoke-CITests.ps1)
#>

BeforeDiscovery {
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $snipDir = Join-Path $repo 'skills\hu-snippet\templates'
    $extDir = Join-Path $repo 'skills\hu-extension\templates'
    $SnippetTemplates = @(Get-ChildItem -LiteralPath $snipDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $ExtensionTemplates = @(Get-ChildItem -LiteralPath $extDir -Filter '*.ps1' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $ShippedExtensions = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Extensions') -Filter '*.ps1' -Recurse | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })

    # Snippets, die einen bestimmten FEHLER ausloesen muessen: Regel + Code
    $BadSnippets = @(
        @{ Name = 'Syntaxfehler'; Rule = 'S01'; Code = "# x`n# Berechtigungen: keine`nif (" }
        @{ Name = 'PowerShell-7-Syntax ??'; Rule = 'S02'; Code = "# x`n# Berechtigungen: keine`n`$a = `$null`n`$b = `$a ?? 1" }
        @{ Name = 'param-Block'; Rule = 'S03'; Code = "# x`n# Berechtigungen: keine`nparam(`$a)`nWrite-Host 1" }
        @{ Name = 'Token zugewiesen'; Rule = 'S04'; Code = "# x`n# Berechtigungen: keine`n`$Token = 'abc'" }
        @{ Name = 'Name ungueltig'; Rule = 'S05'; Code = "# x`n# Berechtigungen: keine`n# @param 1x|string|x|" }
        @{ Name = 'reservierter Name'; Rule = 'S05'; Code = "# x`n# Berechtigungen: keine`n# @param Input|string|x|" }
        @{ Name = 'Feldvariable ueberschrieben'; Rule = 'S06'; Code = "# x`n# Berechtigungen: keine`n# @param Tage|int|Tage|30`n`$Tage = 5" }
        @{ Name = 'Read-Host'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`n`$a = Read-Host 'wie'" }
        @{ Name = 'Write-HULogInfo'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`nWrite-HULogInfo 'x'" }
        @{ Name = 'Get-Settings'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`n`$s = Get-Settings" }
        @{ Name = 'Connect-MgGraph'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`nConnect-MgGraph" }
        @{ Name = 'Invoke-RestMethod gegen Graph'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`nInvoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users'" }
        @{ Name = 'Excel-Funktion'; Rule = 'S07'; Code = "# x`n# Berechtigungen: keine`n`$null = Initialize-HUExcel" }
        @{ Name = '-Uri an Invoke-GraphRequest'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`nInvoke-GraphRequest -Token `$Token -Uri 'https://graph.microsoft.com/v1.0/users'" }
        @{ Name = '-Headers an Invoke-GraphRequest'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`nInvoke-GraphRequest -Token `$Token -Endpoint '/users' -Headers @{ a = 'b' }" }
        @{ Name = 'Method PUT'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (-not `$DryRun) { `$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users/1' -Method PUT -Body @{ a = 1 } ; `$r.IsError }" }
        @{ Name = 'Body als Text'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (-not `$DryRun) { `$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users/1' -Method PATCH -Body '{""a"":1}' ; `$r.IsError }" }
        @{ Name = 'Body mit ConvertTo-Json'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (-not `$DryRun) { `$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users/1' -Method PATCH -Body (@{ a = 1 } | ConvertTo-Json) ; `$r.IsError }" }
        @{ Name = 'Version im Pfad'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`n`$r = Invoke-GraphRequest -Token `$Token -Endpoint '/beta/users'; `$r.IsError" }
        @{ Name = 'fremde Adresse'; Rule = 'S08'; Code = "# x`n# Berechtigungen: keine`n`$r = Invoke-GraphRequest -Token `$Token -Endpoint 'https://example.org/x'; `$r.IsError" }
        @{ Name = 'All fuer Einzelobjekt'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`n`$wv = `$null`n@(Invoke-GraphRequestAll -Token `$Token -Endpoint '/users/abc' -WarningVariable wv -WarningAction SilentlyContinue)" }
        @{ Name = 'All mit ApiVersion'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`n`$wv = `$null`n@(Invoke-GraphRequestAll -Token `$Token -Endpoint '/users' -ApiVersion beta -WarningVariable wv -WarningAction SilentlyContinue)" }
        @{ Name = '$top in doppelten Anfuehrungszeichen'; Rule = 'S08'; Code = "# x`n# Berechtigungen: User.Read.All`n`$wv = `$null`n@(Invoke-GraphRequestAll -Token `$Token -Endpoint ""/users?`$top=5"" -WarningVariable wv -WarningAction SilentlyContinue)" }
        @{ Name = 'Send-HUNotify falscher Parameter'; Rule = 'S09'; Code = "# x`n# Berechtigungen: keine`nSend-HUNotify -Title 'x' -Zeilen 'a'" }
        @{ Name = 'Send-HUNotify falsches Level'; Rule = 'S09'; Code = "# x`n# Berechtigungen: keine`nSend-HUNotify -Title 'x' -Level 'Fatal'" }
        @{ Name = 'Token ausgegeben'; Rule = 'S10'; Code = "# x`n# Berechtigungen: keine`nWrite-Host `$Token" }
        @{ Name = 'Token in Zeichenkette'; Rule = 'S10'; Code = "# x`n# Berechtigungen: keine`n`$h = ""Bearer `$Token""" }
        @{ Name = 'aendern ohne DryRun'; Rule = 'S11'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n`$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n`$r.IsError" }
        @{ Name = 'DryRun vertauscht'; Rule = 'S11'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (`$DryRun) { `$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }; `$r.IsError }" }
        @{ Name = 'Schreibaufruf ausserhalb der Abfrage'; Rule = 'S11'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (`$DryRun) { Write-Host 'x' }`n`$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n`$r.IsError" }
        @{ Name = 'DryRun nie abgefragt'; Rule = 'S11'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`n`$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n`$r.IsError" }
        @{ Name = 'Rechtename ungueltig'; Rule = 'S14'; Code = "# x`n# Berechtigungen: Gerate`nWrite-Host 1" }
    )

    # Snippets, die KEINEN FEHLER ausloesen duerfen (Schreibweisen, die zulaessig sind)
    $GoodSnippets = @(
        @{ Name = 'Probelauf mit continue'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nforeach (`$i in 1..2) {`n if (`$DryRun) { Write-Host 'x'; continue }`n `$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n if (`$r.IsError) { Write-Error 'f' }`n}" }
        @{ Name = 'Probelauf mit if/else'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param DryRun|bool|Probelauf|true`nif (`$DryRun) { Write-Host 'x' } else { `$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }; if (`$r.IsError) { Write-Error 'f' } }" }
        @{ Name = 'Probelauf mit -not'; Code = "# x`n# Berechtigungen: User.ReadWrite.All`n# @param WhatIf|bool|Probelauf|true`nif (-not `$WhatIf) { `$r = Invoke-GraphRequestWithRetry -Token `$Token -Endpoint '/users/1' -Method DELETE; if (`$r.IsError) { Write-Error 'f' } }" }
        @{ Name = 'beta ueber ApiVersion'; Code = "# x`n# Berechtigungen: User.Read.All`n`$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users/1' -ApiVersion beta`nif (`$r.IsError) { Write-Error 'f' }" }
        @{ Name = 'beta ueber absolute Adresse'; Code = "# x`n# Berechtigungen: User.Read.All`n`$wv = `$null`n@(Invoke-GraphRequestAll -Token `$Token -Endpoint 'https://graph.microsoft.com/beta/users' -WarningVariable wv -WarningAction SilentlyContinue)" }
    )

    # Extensions: Regel + Code (Kopf und Funktion), die einen FEHLER ausloesen muessen
    $extHead = "<#`n.SYNOPSIS`n    x`n.REQUIRED_PERMISSIONS`n    User.Read.All`n.CATEGORY`n    User`n.MODE`n    ReadOnly`n.DRY_RUN_CAPABLE`n    false`n#>`n"
    $extHeadRW = "<#`n.SYNOPSIS`n    x`n.REQUIRED_PERMISSIONS`n    User.ReadWrite.All`n.CATEGORY`n    User`n.MODE`n    ReadWrite`n.DRY_RUN_CAPABLE`n    true`n#>`n"
    $extParams = "[CmdletBinding()]`n    param([Parameter(Mandatory)][string]`$TenantKey, [Parameter(Mandatory)][string]`$Token)`n"
    $BadExtensions = @(
        @{ Name = 'Syntaxfehler'; Rule = 'E01'; Code = $extHead + "function Invoke-X {`n" }
        @{ Name = 'kein Kopf'; Rule = 'E03'; Code = "function Invoke-X {`n    $extParams    1`n}" }
        @{ Name = 'Kopf ohne SYNOPSIS und DESCRIPTION'; Rule = 'E03'; Code = "<#`n.CATEGORY`n    User`n#>`nfunction Invoke-X {`n    $extParams}" }
        @{ Name = 'PARAM mit zwei Feldern'; Rule = 'E03'; Code = "<#`n.SYNOPSIS`n    x`n.PARAM`n    Tage|int`n#>`nfunction Invoke-X {`n    $extParams}" }
        @{ Name = 'keine Invoke-Funktion'; Rule = 'E04'; Code = $extHead + "function Get-X {`n    $extParams}" }
        @{ Name = 'zwei Invoke-Funktionen'; Rule = 'E04'; Code = $extHead + "function Invoke-X {`n    $extParams}`nfunction Invoke-Y {`n    $extParams}" }
        @{ Name = 'TenantKey fehlt'; Rule = 'E04'; Code = $extHead + "function Invoke-X {`n    param([Parameter(Mandatory)][string]`$Token)`n}" }
        @{ Name = 'SupportsShouldProcess + WhatIf'; Rule = 'E05'; Code = $extHeadRW + "function Invoke-X {`n    [CmdletBinding(SupportsShouldProcess)]`n    param([Parameter(Mandatory)][string]`$TenantKey, [Parameter(Mandatory)][string]`$Token, [switch]`$WhatIf)`n}" }
        @{ Name = 'Verbose doppelt'; Rule = 'E05'; Code = $extHead + "function Invoke-X {`n    [CmdletBinding()]`n    param([Parameter(Mandatory)][string]`$TenantKey, [Parameter(Mandatory)][string]`$Token, [switch]`$Verbose)`n}" }
        @{ Name = 'DRY_RUN true ohne WhatIf'; Rule = 'E05'; Code = $extHeadRW + "function Invoke-X {`n    $extParams}" }
        @{ Name = 'PARAM ohne Funktionsparameter'; Rule = 'E06'; Code = "<#`n.SYNOPSIS`n    x`n.PARAM`n    Tage|int|Tage|30`n#>`nfunction Invoke-X {`n    $extParams}" }
        @{ Name = 'Read-Host'; Rule = 'E07'; Code = $extHead + "function Invoke-X {`n    $extParams    `$a = Read-Host 'x'`n}" }
        @{ Name = 'Invoke-RestMethod gegen Graph'; Rule = 'E07'; Code = $extHead + "function Invoke-X {`n    $extParams    Invoke-RestMethod -Uri 'https://graph.microsoft.com/v1.0/users'`n}" }
        @{ Name = 'Graph-Parameter falsch'; Rule = 'E08'; Code = $extHead + "function Invoke-X {`n    $extParams    `$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users' -Foo 1`n}" }
        @{ Name = 'catch ohne throw'; Rule = 'E09'; Code = $extHead + "function Invoke-X {`n    $extParams    try { 1 }`n    catch { Write-HULogError 'f' -Tenant `$TenantKey; return `$null }`n}" }
        @{ Name = 'Token geloggt'; Rule = 'E10'; Code = $extHead + "function Invoke-X {`n    $extParams    Write-HULogInfo ""T `$Token"" -Tenant `$TenantKey`n}" }
        @{ Name = 'aendern ohne ReadWrite'; Rule = 'E11'; Code = $extHead + "function Invoke-X {`n    $extParams    `$r = Invoke-GraphRequestWithRetry -Token `$Token -TenantKey `$TenantKey -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n    if (`$r.IsError) { throw 'f' }`n}" }
        @{ Name = 'aendern ohne Probelauf-Abfrage'; Rule = 'E11'; Code = $extHeadRW + "function Invoke-X {`n    [CmdletBinding()]`n    param([Parameter(Mandatory)][string]`$TenantKey, [Parameter(Mandatory)][string]`$Token, [switch]`$WhatIf)`n    `$r = Invoke-GraphRequestWithRetry -Token `$Token -TenantKey `$TenantKey -Endpoint '/users/1' -Method PATCH -Body @{ a = 1 }`n    if (`$r.IsError) { throw 'f' }`n    if (`$WhatIf) { 'x' }`n}" }
        @{ Name = 'Rechtename ungueltig'; Rule = 'E14'; Code = "<#`n.SYNOPSIS`n    x`n.REQUIRED_PERMISSIONS`n    Gerate`n#>`nfunction Invoke-X {`n    $extParams}" }
    )
}

BeforeAll {
    $script:Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:SkillsDir = Join-Path $script:Repo 'skills'
    $script:SnippetChecker = Join-Path $script:SkillsDir 'hu-snippet\tools\Test-HUSnippet.ps1'
    $script:ExtensionChecker = Join-Path $script:SkillsDir 'hu-extension\tools\Test-HUExtension.ps1'

    function script:Get-SnippetFindings([string]$Code) { return @(& $script:SnippetChecker -Code $Code -Quiet) }
    function script:Get-ExtensionFindings([string]$Code) { return @(& $script:ExtensionChecker -Code $Code -Quiet) }
    function script:Read-Utf8([string]$Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) }
    function script:ConvertTo-Lf([string]$Text) { return ($Text -replace "`r`n", "`n") }

    # Parameter einer Funktion aus dem Quelltext lesen (ohne das Modul zu laden)
    function script:Get-FunctionParamNames([string]$File, [string]$Function) {
        $t = $null
        $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$t, [ref]$e)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true)
        if (-not $fn) { throw "Funktion $Function nicht gefunden in $File" }
        $pb = $fn.Body.ParamBlock
        if (-not $pb -and $fn.Parameters) { return @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        return @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    # Die Attrappe muss dieselben Parameter haben wie die echte Funktion (sonst deckt der Test Fehler zu)
    function script:Assert-FakeMatchesReal([string]$Name, [string]$RealFile) {
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction')
        $fake = @((Get-Command -Name $Name -CommandType Function).Parameters.Keys | Where-Object { $common -notcontains $_ } | Sort-Object)
        $real = @(Get-FunctionParamNames $RealFile $Name | Sort-Object)
        ($fake -join ',') | Should -Be ($real -join ',') -Because "Attrappe $Name"
    }
}

Describe 'Pruefprogramm Snippets (Test-HUSnippet.ps1)' {
    It 'Vorlage <Name> hat keinen einzigen Befund' -ForEach $SnippetTemplates {
        $f = @(Get-SnippetFindings (Read-Utf8 $Path))
        ($f | ForEach-Object { "$($_.Stufe) $($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'erkennt: <Name> (<Rule>)' -ForEach $BadSnippets {
        $all = @(Get-SnippetFindings $Code)
        foreach ($x in $all) { $x.Regel | Should -Match '^S\d\d$' }
        @($all | Where-Object { $_.Stufe -eq 'FEHLER' -and $_.Regel -eq $Rule }).Count | Should -BeGreaterThan 0
    }
    It 'meldet keinen Fehler bei zulaessiger Schreibweise: <Name>' -ForEach $GoodSnippets {
        $f = @(Get-SnippetFindings $Code | Where-Object { $_.Stufe -eq 'FEHLER' })
        ($f | ForEach-Object { "$($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'Beispiel-Snippets des Programms (quick-snippets.example.json) haben keine Fehler' {
        $json = Get-Content -LiteralPath (Join-Path $script:Repo 'Config\quick-snippets.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $json.snippets.Count | Should -BeGreaterThan 5
        foreach ($s in $json.snippets) {
            $f = @(Get-SnippetFindings ([string]$s.code) | Where-Object { $_.Stufe -eq 'FEHLER' })
            ($f | ForEach-Object { "$($s.name): $($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
        }
    }
    It 'Probelauf-Namen stimmen mit der Laufzeit (HU.QSParams.ps1) ueberein' {
        $rt = Read-Utf8 (Join-Path $script:Repo 'Core\HU.QSParams.ps1')
        $m1 = [regex]::Match($rt, "\^\((DryRun\|[A-Za-z|]+)\)\`$'")
        $m1.Success | Should -BeTrue
        $ck = Read-Utf8 $script:SnippetChecker
        $m2 = [regex]::Match($ck, "\`$guardRx = '\^\((DryRun\|[A-Za-z|]+)\)\`$'")
        $m2.Success | Should -BeTrue
        $m2.Groups[1].Value | Should -Be $m1.Groups[1].Value
    }
}

Describe 'Pruefprogramm Extensions (Test-HUExtension.ps1)' {
    It 'Vorlage <Name> hat keinen einzigen Befund' -ForEach $ExtensionTemplates {
        $f = @(Get-ExtensionFindings (Read-Utf8 $Path))
        ($f | ForEach-Object { "$($_.Stufe) $($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'erkennt: <Name> (<Rule>)' -ForEach $BadExtensions {
        $all = @(Get-ExtensionFindings $Code)
        foreach ($x in $all) { $x.Regel | Should -Match '^E\d\d$' }
        @($all | Where-Object { $_.Stufe -eq 'FEHLER' -and $_.Regel -eq $Rule }).Count | Should -BeGreaterThan 0
    }
    It 'Extensions\Template.ps1 hat keinen Fehler' {
        $f = @(Get-ExtensionFindings (Read-Utf8 (Join-Path $script:Repo 'Extensions\Template.ps1')) | Where-Object { $_.Stufe -eq 'FEHLER' })
        ($f | ForEach-Object { "$($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }
    It 'mitgelieferte Extension <Name> hat ausser dem bekannten E09 (Success = $false statt throw) keinen Fehler' -ForEach $ShippedExtensions {
        $f = @(Get-ExtensionFindings (Read-Utf8 $Path) | Where-Object { $_.Stufe -eq 'FEHLER' -and $_.Regel -ne 'E09' })
        ($f | ForEach-Object { "$($_.Regel) Z$($_.Zeile): $($_.Text)" }) -join "`n" | Should -BeNullOrEmpty
    }
}

Describe 'Anleitungen (SKILL.md)' {
    BeforeAll {
        $script:SnippetSkill = ConvertTo-Lf (Read-Utf8 (Join-Path $script:SkillsDir 'hu-snippet\SKILL.md'))
        $script:ExtensionSkill = ConvertTo-Lf (Read-Utf8 (Join-Path $script:SkillsDir 'hu-extension\SKILL.md'))
    }
    It 'hu-snippet: Kopf mit name und description' {
        $script:SnippetSkill | Should -Match '(?s)^---\nname: hu-snippet\ndescription: [^\n]{40,}\n---\n'
    }
    It 'hu-extension: Kopf mit name und description' {
        $script:ExtensionSkill | Should -Match '(?s)^---\nname: hu-extension\ndescription: [^\n]{40,}\n---\n'
    }
    It 'hu-snippet: Vorlage <Name> steht woertlich in der Anleitung' -ForEach $SnippetTemplates {
        $t = (ConvertTo-Lf (Read-Utf8 $Path)).TrimEnd("`n")
        $script:SnippetSkill.Contains($t) | Should -BeTrue -Because "die Vorlage $Name muss unveraendert in skills\hu-snippet\SKILL.md stehen"
    }
    It 'hu-extension: Vorlage <Name> steht woertlich in der Anleitung' -ForEach $ExtensionTemplates {
        $t = (ConvertTo-Lf (Read-Utf8 $Path)).TrimEnd("`n")
        $script:ExtensionSkill.Contains($t) | Should -BeTrue -Because "die Vorlage $Name muss unveraendert in skills\hu-extension\SKILL.md stehen"
    }
    It 'hu-snippet: das Rezept zum Erzeugen der Import-Datei liefert, was die Snippet-Verwaltung liest' {
        $m = [regex]::Match($script:SnippetSkill, '(?s)```powershell\n(@\{ snippets = .*?)```')
        $m.Success | Should -BeTrue
        $recipe = $m.Groups[1].Value -replace '\.\\', './'
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-skill-imp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Push-Location $tmp
        try {
            [System.IO.File]::WriteAllText((Join-Path $tmp 'mein-snippet.ps1'), "# Test`n# Berechtigungen: keine`nWrite-Host 'ae'`n", (New-Object System.Text.UTF8Encoding($false)))
            & ([scriptblock]::Create($recipe))
            $t = $null
            $e = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo 'Functions\UI-Snippets.ps1'), [ref]$t, [ref]$e)
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-HUSnippet' }, $true)
            . ([scriptblock]::Create($fn.Extent.Text))
            $j = Get-Content -LiteralPath (Join-Path $tmp 'snippets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $raw = if ($j.PSObject.Properties['snippets']) { @($j.snippets) } else { @($j) }
            $sn = @($raw | ForEach-Object { ConvertTo-HUSnippet $_ })[0]
            $sn.name | Should -Be 'Name'
            $sn.category | Should -Be 'Eigene'
            $sn.code | Should -Match "Write-Host 'ae'"
            $sn.code | Should -Match '^# Test'
        }
        finally { Pop-Location; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'hu-snippet: jede Regel S01-S16 ist beschrieben' {
        foreach ($i in 1..16) { $script:SnippetSkill | Should -Match ('\| S{0:00} \|' -f $i) }
    }
    It 'hu-extension: jede Regel E01-E16 ist beschrieben' {
        foreach ($i in 1..16) { $script:ExtensionSkill | Should -Match ('\| E{0:00} \|' -f $i) }
    }
    It 'Pruefprogramme melden nur beschriebene Regeln' {
        $ck = (Read-Utf8 $script:SnippetChecker)
        foreach ($m in [regex]::Matches($ck, "Add-Finding '(?:FEHLER|WARNUNG)' '(S\d\d)'")) { $script:SnippetSkill | Should -Match ('\| {0} \|' -f $m.Groups[1].Value) }
        $ck2 = (Read-Utf8 $script:ExtensionChecker)
        foreach ($m in [regex]::Matches($ck2, "Add-Finding '(?:FEHLER|WARNUNG)' '(E\d\d)'")) { $script:ExtensionSkill | Should -Match ('\| {0} \|' -f $m.Groups[1].Value) }
    }
    It 'gemeinsamer Block beider Pruefprogramme ist identisch' {
        $rx = '(?s)#region Gemeinsam[^\n]*\n(.*)#endregion Gemeinsam'
        $a = [regex]::Match((ConvertTo-Lf (Read-Utf8 $script:SnippetChecker)), $rx).Groups[1].Value
        $b = [regex]::Match((ConvertTo-Lf (Read-Utf8 $script:ExtensionChecker)), $rx).Groups[1].Value
        $a.Length | Should -BeGreaterThan 1000
        $b | Should -Be $a
    }
    It 'Dateien in skills\ enthalten keine Hinweise auf Werkzeuge oder Hersteller von Assistenten' {
        foreach ($f in (Get-ChildItem -LiteralPath $script:SkillsDir -Recurse -File)) {
            (Read-Utf8 $f.FullName) | Should -Not -Match '(?i)claude|anthropic|openai|chatgpt|copilot|gemini' -Because $f.FullName
        }
    }
    It 'Dateien in skills\ sind ASCII oder haben BOM (ps1) bzw. sind UTF-8 (md)' {
        foreach ($f in (Get-ChildItem -LiteralPath $script:SkillsDir -Recurse -Filter '*.ps1')) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $ascii = -not @($bytes | Where-Object { $_ -gt 127 }).Count
            ($hasBom -or $ascii) | Should -BeTrue -Because $f.FullName
        }
    }
}

Describe 'Aussagen der Anleitungen gegen den Programmcode' {
    It 'Snippet-Laufzeit: Funktionen und Parameter wie in der Tabelle' {
        $rt = Join-Path $script:Repo 'Core\HU.QSRuntime.ps1'
        (Get-FunctionParamNames $rt 'Invoke-GraphRequest') -join ',' | Should -Be 'Token,Endpoint,Method,Body,ApiVersion,ContentType'
        (Get-FunctionParamNames $rt 'Invoke-GraphRequestWithRetry') -join ',' | Should -Be 'Token,Endpoint,Method,Body,TenantKey,Settings,MaxRetries,ApiVersion'
        (Get-FunctionParamNames $rt 'Invoke-GraphRequestAll') -join ',' | Should -Be 'Token,Endpoint,TenantKey,Settings,MaxPages'
    }
    It 'Modul HU.Graph: gleiche Parameter wie die Laufzeit-Huellen' {
        $g = Join-Path $script:Repo 'Core\HU.Graph.psm1'
        (Get-FunctionParamNames $g 'Invoke-GraphRequest') -join ',' | Should -Be 'Token,Endpoint,Method,Body,ApiVersion,ContentType'
        (Get-FunctionParamNames $g 'Invoke-GraphRequestWithRetry') -join ',' | Should -Be 'Token,Endpoint,Method,Body,TenantKey,Settings,MaxRetries,ApiVersion'
        (Get-FunctionParamNames $g 'Invoke-GraphRequestAll') -join ',' | Should -Be 'Token,Endpoint,TenantKey,Settings,MaxPages'
    }
    It 'Graph: nur GET, POST, PATCH, DELETE; Fehler als Objekt; absolute https-Adresse unveraendert; Body nur bei POST/PATCH' {
        $g = Read-Utf8 (Join-Path $script:Repo 'Core\HU.Graph.psm1')
        $g | Should -Match "ValidateSet\('GET', 'POST', 'PATCH', 'DELETE'\)"
        $g | Should -Match 'IsError\s*=\s*\$true'
        $g | Should -Match 'StatusCode\s*=\s*\$statusCode'
        $g | Should -Match 'ErrorMessage\s*=\s*\$errorDetail'
        $g | Should -Match "\`$Endpoint\.StartsWith\('https://'\)"
        $g | Should -Match "\`$Method -in @\('POST', 'PATCH'\)"
        $g | Should -Match 'ConvertTo-Json -Depth 10'
    }
    It 'Extension-Lader: Schluessel, Kategorien, Modus, -WhatIf nur bei DryRunCapable, nur deklarierte Parameter' {
        $e = Read-Utf8 (Join-Path $script:Repo 'Core\HU.Extensions.psm1')
        $e | Should -Match ([regex]::Escape("'SYNOPSIS|DESCRIPTION|REQUIRED_PERMISSIONS|REQUIRED_ROLES|CATEGORY|TARGETS|BATCH_CAPABLE|DRY_RUN_CAPABLE|RUNTIME|MODE|PARAM|EXAMPLE|NOTES'"))
        $e | Should -Match ([regex]::Escape("'Device-'   = 'Device'"))
        $e | Should -Match ([regex]::Escape("'Policy-'   = 'Policy'"))
        $e | Should -Match ([regex]::Escape("'Security-' = 'Security'"))
        $e | Should -Match ([regex]::Escape("'Common-'   = 'Common'"))
        $e | Should -Match ([regex]::Escape("'User-'     = 'User'"))
        $e | Should -Match ([regex]::Escape("ReadWrite|Write|Manage"))
        $e | Should -Match ([regex]::Escape('if ($WhatIf -and $Extension.DryRunCapable)'))
        $e | Should -Match ([regex]::Escape('if ($funcParams.ContainsKey($cpKey))'))
        $e | Should -Match ([regex]::Escape("Where-Object { `$_.Name -ne 'Template.ps1' }"))
    }
    It 'Extension-Lauf: Erfolg = keine Ausnahme (Success wird nur im catch auf false gesetzt)' {
        $e = Read-Utf8 (Join-Path $script:Repo 'Core\HU.Extensions.psm1')
        $e | Should -Match '(?s)\$output = & \$mainFunction\.Name @invokeParams\s+\$result\.Success = \$true'
        $e | Should -Match '(?s)catch \{\s+\$result\.ErrorMessage = \$_\.Exception\.Message\s+\$result\.Success = \$false'
    }
    It 'Protokollfunktionen: Message an erster Stelle, Tenant optional' {
        $l = Join-Path $script:Repo 'Core\HU.Logging.psm1'
        foreach ($n in 'Write-HULogInfo', 'Write-HULogOK', 'Write-HULogWarn', 'Write-HULogError', 'Write-HULogDebug') {
            (Get-FunctionParamNames $l $n) -join ',' | Should -Be 'Message,Tenant'
        }
    }
    It 'Send-HUNotify: Parameter wie im Pruefprogramm erlaubt' {
        $names = Get-FunctionParamNames (Join-Path $script:Repo 'Core\HU.Notify.psm1') 'Send-HUNotify'
        $ck = Read-Utf8 $script:SnippetChecker
        $m = [regex]::Match($ck, "\`$okP = @\(([^)]*)\)")
        $m.Success | Should -BeTrue
        $allowed = @([regex]::Matches($m.Groups[1].Value, "'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value })
        foreach ($n in $names) { $allowed | Should -Contain $n }
    }
    It 'Excel-Funktionen: Parameter wie in der Anleitung' {
        $x = Join-Path $script:Repo 'Core\HU.Excel.psm1'
        $np = Get-FunctionParamNames $x 'New-HUExcelReport'
        foreach ($n in 'Data', 'SheetName', 'ReportPath', 'PrimaryKeyColumn', 'ConditionalColumns') { $np | Should -Contain $n }
        $dp = Get-FunctionParamNames $x 'Add-HUExcelDashboard'
        foreach ($n in 'WorkbookPath', 'TenantKey', 'ReportTitle', 'Metrics', 'SheetDataSources') { $dp | Should -Contain $n }
    }
    It 'Die Vorlagen benutzen nur Parameter, die es bei den aufgerufenen HU-Funktionen gibt' -ForEach (@($SnippetTemplates) + @($ExtensionTemplates)) {
        $map = @{
            'Invoke-GraphRequest'          = @($script:Repo, 'Core\HU.QSRuntime.ps1')
            'Invoke-GraphRequestWithRetry' = @($script:Repo, 'Core\HU.QSRuntime.ps1')
            'Invoke-GraphRequestAll'       = @($script:Repo, 'Core\HU.QSRuntime.ps1')
            'Send-HUNotify'                = @($script:Repo, 'Core\HU.Notify.psm1')
            'Write-HULogInfo'              = @($script:Repo, 'Core\HU.Logging.psm1')
            'Write-HULogOK'                = @($script:Repo, 'Core\HU.Logging.psm1')
            'Write-HULogWarn'              = @($script:Repo, 'Core\HU.Logging.psm1')
            'Write-HULogError'             = @($script:Repo, 'Core\HU.Logging.psm1')
            'Write-HULogDebug'             = @($script:Repo, 'Core\HU.Logging.psm1')
            'Initialize-HUExcel'           = @($script:Repo, 'Core\HU.Excel.psm1')
            'New-HUExcelReport'            = @($script:Repo, 'Core\HU.Excel.psm1')
            'Add-HUExcelDashboard'         = @($script:Repo, 'Core\HU.Excel.psm1')
        }
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')
        $t = $null
        $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
        $checked = 0
        foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cn = "$($c.GetCommandName())"
            if (-not $map.ContainsKey($cn)) { continue }
            $real = Get-FunctionParamNames (Join-Path $map[$cn][0] $map[$cn][1]) $cn
            foreach ($el in $c.CommandElements) {
                if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $pn = $el.ParameterName
                (@($real + $common) | Where-Object { $_.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase) }).Count | Should -BeGreaterThan 0 -Because "$cn -$pn"
                $checked++
            }
        }
        $checked | Should -BeGreaterThan 0
    }
}

Describe 'Snippet-Vorlagen laufen gegen eine Graph-Attrappe' {
    BeforeAll {
        . (Join-Path $script:Repo 'Core\HU.QSParams.ps1')

        $global:HUSkillTest = @{ Calls = (New-Object System.Collections.ArrayList); Devices = @(); PageFails = $false; PostResult = $null; Notes = (New-Object System.Collections.ArrayList) }

        function global:Invoke-GraphRequestAll {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Endpoint, [string]$TenantKey, [PSCustomObject]$Settings, [int]$MaxPages = 100)
            [void]$global:HUSkillTest.Calls.Add([pscustomobject]@{ Fn = 'All'; Endpoint = $Endpoint; Method = 'GET'; TenantKey = $TenantKey })
            if ($global:HUSkillTest.PageFails) { Write-Warning 'Seite 2 fehlgeschlagen' }
            $global:HUSkillTest.Devices
        }
        function global:Invoke-GraphRequestWithRetry {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Endpoint, [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET', [hashtable]$Body, [string]$TenantKey, [PSCustomObject]$Settings, [int]$MaxRetries, [string]$ApiVersion)
            [void]$global:HUSkillTest.Calls.Add([pscustomobject]@{ Fn = 'Retry'; Endpoint = $Endpoint; Method = $Method; TenantKey = $TenantKey })
            $global:HUSkillTest.PostResult
        }
        function global:Invoke-GraphRequest {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Endpoint, [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET', [hashtable]$Body, [string]$ApiVersion, [string]$ContentType = 'application/json')
            [void]$global:HUSkillTest.Calls.Add([pscustomobject]@{ Fn = 'Single'; Endpoint = $Endpoint; Method = $Method; TenantKey = '' })
            $global:HUSkillTest.PostResult
        }
        function global:Send-HUNotify {
            [CmdletBinding()]
            param([string]$Category = '', [Parameter(Mandatory)][string]$Title, [string[]]$Lines = @(), [ValidateSet('OK', 'Warning', 'Error', 'Info')][string]$Level = 'Info', [System.Collections.IDictionary]$Facts, [object[]]$Rows = @(), [hashtable[]]$Actions = @(), [string]$Source = '', [string[]]$TargetIds = @(), [switch]$IgnoreCategory, [string]$Preview = '')
            [void]$global:HUSkillTest.Notes.Add([pscustomobject]@{ Title = $Title; Lines = $Lines; Level = $Level; Preview = $Preview })
            [pscustomobject]@{ Text = 'ok'; Ok = 1; Failed = 0 }
        }

        # Snippet wie die Laufzeit starten: Variablen setzen, Skript ausfuehren, alle Datenstroeme einsammeln
        function script:Invoke-TestSnippet([string]$Path, [hashtable]$Vars) {
            $global:HUSkillTest.Calls.Clear()
            $global:HUSkillTest.Notes.Clear()
            $ErrorActionPreference = 'Continue'   # wie im Runspace des Quick Scripts (dort wird nichts gesetzt)
            $Token = 'tok-123'
            $TenantKey = 'Schule-1'
            $Schule = 'Schule-1'
            foreach ($k in $Vars.Keys) { Set-Variable -Name $k -Value $Vars[$k] }
            $sb = [scriptblock]::Create((Read-Utf8 $Path))
            $all = @(& $sb *>&1)
            return [pscustomobject]@{
                Objects  = @($all | Where-Object { $_ -is [pscustomobject] -or ($_ -isnot [System.Management.Automation.ErrorRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.VerboseRecord]) })
                Errors   = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                Warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                Text     = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
            }
        }
        $script:Tpl = Join-Path $script:SkillsDir 'hu-snippet\templates'
        $script:Stale = (Get-Date).AddDays(-90).ToUniversalTime().ToString('o')
        $script:Fresh = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
    }
    AfterAll {
        foreach ($n in 'Invoke-GraphRequestAll', 'Invoke-GraphRequestWithRetry', 'Invoke-GraphRequest', 'Send-HUNotify') { Remove-Item -Path "function:global:$n" -ErrorAction SilentlyContinue }
        Remove-Variable -Name HUSkillTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Attrappen haben die Parameter der echten Funktionen' {
        $rt = Join-Path $script:Repo 'Core\HU.QSRuntime.ps1'
        Assert-FakeMatchesReal 'Invoke-GraphRequest' $rt
        Assert-FakeMatchesReal 'Invoke-GraphRequestWithRetry' $rt
        Assert-FakeMatchesReal 'Invoke-GraphRequestAll' $rt
        Assert-FakeMatchesReal 'Send-HUNotify' (Join-Path $script:Repo 'Core\HU.Notify.psm1')
    }

    Context 'lesen.ps1' {
        It 'liefert nur Geraete ohne Sync innerhalb der Frist und benutzt $Token' {
            $global:HUSkillTest.PageFails = $false
            $global:HUSkillTest.Devices = @(
                [pscustomobject]@{ deviceName = 'NB-ALT'; userPrincipalName = 'a@x.at'; lastSyncDateTime = $script:Stale }
                [pscustomobject]@{ deviceName = 'NB-NEU'; userPrincipalName = 'b@x.at'; lastSyncDateTime = $script:Fresh }
                [pscustomobject]@{ deviceName = 'NB-NIE'; userPrincipalName = 'c@x.at'; lastSyncDateTime = $null }
            )
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'lesen.ps1') @{ Tage = 30 }
            $rows = @($r.Objects | Where-Object { $_.PSObject.Properties['Geraet'] })
            @($rows | ForEach-Object { $_.Geraet } | Sort-Object) -join ',' | Should -Be 'NB-ALT,NB-NIE'
            $r.Errors.Count | Should -Be 0
            $global:HUSkillTest.Calls.Count | Should -Be 1
        }
        It 'bricht bei unvollstaendiger Liste mit Fehlermeldung ab (keine Ergebniszeilen)' {
            $global:HUSkillTest.PageFails = $true
            $global:HUSkillTest.Devices = @([pscustomobject]@{ deviceName = 'NB-ALT'; userPrincipalName = 'a@x.at'; lastSyncDateTime = $script:Stale })
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'lesen.ps1') @{ Tage = 30 }
            @($r.Objects | Where-Object { $_.PSObject.Properties['Geraet'] }).Count | Should -Be 0
            $r.Errors.Count | Should -BeGreaterThan 0
            "$($r.Errors[0])" | Should -Match 'unvollstaendig'
            $global:HUSkillTest.PageFails = $false
        }
        It 'Kopf wird von der Laufzeit gelesen (Feld Tage = int, Standard 30)' {
            $p = @(Get-HUQSParams (Read-Utf8 (Join-Path $script:Tpl 'lesen.ps1')))
            $p.Count | Should -Be 1
            $p[0].Name | Should -Be 'Tage'
            $p[0].Type | Should -Be 'int'
            $p[0].Default | Should -Be '30'
        }
    }

    Context 'aendern.ps1' {
        BeforeEach {
            $global:HUSkillTest.PageFails = $false
            $global:HUSkillTest.PostResult = $null
            $global:HUSkillTest.Devices = @([pscustomobject]@{ id = 'id-1'; deviceName = "NB-O'Neil" })
        }
        It 'Probelauf: keine aendernden Aufrufe, Ergebnis Probelauf' {
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = "NB-O'Neil"; DryRun = $true }
            @($global:HUSkillTest.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
            @($r.Objects | Where-Object { $_.PSObject.Properties['Ergebnis'] })[0].Ergebnis | Should -Be 'Probelauf'
        }
        It 'echter Lauf: ein POST syncDevice je Geraet, Ergebnis Sync gesendet' {
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = "NB-O'Neil"; DryRun = $false }
            $posts = @($global:HUSkillTest.Calls | Where-Object { $_.Method -eq 'POST' })
            $posts.Count | Should -Be 1
            $posts[0].Endpoint | Should -Be '/deviceManagement/managedDevices/id-1/syncDevice'
            @($r.Objects | Where-Object { $_.PSObject.Properties['Ergebnis'] })[0].Ergebnis | Should -Be 'Sync gesendet'
        }
        It 'Filter: Name mit Apostroph wird verdoppelt und kodiert' {
            $null = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = "NB-O'Neil"; DryRun = $true }
            $ep = $global:HUSkillTest.Calls[0].Endpoint
            $ep | Should -Match ([regex]::Escape([uri]::EscapeDataString("deviceName eq 'NB-O''Neil'")))
            $ep | Should -Match '^/deviceManagement/managedDevices\?\$select=id,deviceName&\$filter='
        }
        It 'Fehlerobjekt der Antwort wird als Ergebnis gemeldet' {
            $global:HUSkillTest.PostResult = [pscustomobject]@{ IsError = $true; StatusCode = 403; ErrorMessage = 'verboten'; Endpoint = 'x'; Method = 'POST' }
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = 'NB-1'; DryRun = $false }
            @($r.Objects | Where-Object { $_.PSObject.Properties['Ergebnis'] })[0].Ergebnis | Should -Be 'Fehler 403: verboten'
        }
        It 'unvollstaendige Liste: nichts wird geaendert' {
            $global:HUSkillTest.PageFails = $true
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = 'NB-1'; DryRun = $false }
            @($global:HUSkillTest.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
            $r.Errors.Count | Should -BeGreaterThan 0
        }
        It 'kein Treffer oder leerer Name: keine aendernden Aufrufe' {
            $global:HUSkillTest.Devices = @()
            $null = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = 'NB-1'; DryRun = $false }
            @($global:HUSkillTest.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
            $null = Invoke-TestSnippet (Join-Path $script:Tpl 'aendern.ps1') @{ Geraetename = ''; DryRun = $false }
            $global:HUSkillTest.Calls.Count | Should -Be 0
        }
        It 'Kopf: Probelauf-Feld wird von der Laufzeit als Schutz erkannt (Haken aus = echter Lauf)' {
            $p = @(Get-HUQSParams (Read-Utf8 (Join-Path $script:Tpl 'aendern.ps1')))
            ($p | Where-Object { $_.Name -eq 'DryRun' }).Type | Should -Be 'bool'
            ($p | Where-Object { $_.Name -eq 'DryRun' }).Default | Should -Be 'true'
            Test-HUQSLiveRun $p @{ DryRun = $false } | Should -BeTrue
            Test-HUQSLiveRun $p @{ DryRun = $true } | Should -BeFalse
        }
    }

    Context 'teams-meldung.ps1' {
        It 'sendet eine Karte mit Anzahlen, ohne Geraetenamen' {
            $global:HUSkillTest.PageFails = $false
            $global:HUSkillTest.Devices = @(
                [pscustomobject]@{ deviceName = 'GEHEIM-NB-1'; lastSyncDateTime = $script:Stale }
                [pscustomobject]@{ deviceName = 'NB-2'; lastSyncDateTime = $script:Fresh }
            )
            $r = Invoke-TestSnippet (Join-Path $script:Tpl 'teams-meldung.ps1') @{ Tage = 30 }
            $global:HUSkillTest.Notes.Count | Should -Be 1
            $n = $global:HUSkillTest.Notes[0]
            $n.Level | Should -Be 'Warning'
            $n.Title | Should -Match '1 Geraete ohne Sync'
            (($n.Title, $n.Preview, ($n.Lines -join ' ')) -join ' ') | Should -Not -Match 'GEHEIM'
            ($r.Text -join ' ') | Should -Match 'GEHEIM-NB-1'
        }
        It 'unvollstaendige Liste: keine Karte' {
            $global:HUSkillTest.PageFails = $true
            $null = Invoke-TestSnippet (Join-Path $script:Tpl 'teams-meldung.ps1') @{ Tage = 30 }
            $global:HUSkillTest.Notes.Count | Should -Be 0
            $global:HUSkillTest.PageFails = $false
        }
    }
}

Describe 'Extension-Vorlagen laufen ueber den echten Lader gegen eine Graph-Attrappe' {
    BeforeAll {
        $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hu-skills-' + [guid]::NewGuid().ToString('N'))
        $script:TmpExt = Join-Path $script:TmpRoot 'Extensions\Device'
        New-Item -ItemType Directory -Path $script:TmpExt -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TmpRoot 'Config') -Force | Out-Null
        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $script:SkillsDir 'hu-extension\templates') -Filter '*.ps1')) { Copy-Item -LiteralPath $f.FullName -Destination $script:TmpExt }

        Import-Module (Join-Path $script:Repo 'Core\HU.Extensions.psm1') -Force -DisableNameChecking

        $global:HUSkillExt = @{ Calls = (New-Object System.Collections.ArrayList); Devices = @(); PageFails = $false; PostResult = $null; ExcelOk = $true; Log = (New-Object System.Collections.ArrayList); Excel = (New-Object System.Collections.ArrayList) }
        function global:Invoke-GraphRequestAll {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Endpoint, [string]$TenantKey, [PSCustomObject]$Settings, [int]$MaxPages = 100)
            [void]$global:HUSkillExt.Calls.Add([pscustomobject]@{ Fn = 'All'; Endpoint = $Endpoint; Method = 'GET'; TenantKey = $TenantKey })
            if ($global:HUSkillExt.PageFails) { Write-Warning 'Seite 2 fehlgeschlagen' }
            $global:HUSkillExt.Devices
        }
        function global:Invoke-GraphRequestWithRetry {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Endpoint, [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET', [hashtable]$Body, [string]$TenantKey, [PSCustomObject]$Settings, [int]$MaxRetries, [string]$ApiVersion)
            [void]$global:HUSkillExt.Calls.Add([pscustomobject]@{ Fn = 'Retry'; Endpoint = $Endpoint; Method = $Method; TenantKey = $TenantKey })
            $global:HUSkillExt.PostResult
        }
        foreach ($lvl in 'Info', 'OK', 'Warn', 'Error', 'Debug') {
            Set-Item -Path "function:global:Write-HULog$lvl" -Value ([scriptblock]::Create('param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant) [void]$global:HUSkillExt.Log.Add("' + $lvl + ': $Message")'))
        }
        function global:Initialize-HUExcel { return [bool]$global:HUSkillExt.ExcelOk }
        function global:New-HUExcelReport {
            [CmdletBinding()]
            param([Parameter(Mandatory)][object[]]$Data, [string]$SheetName = 'Data', [Parameter(Mandatory)][string]$ReportPath, [string]$PrimaryKeyColumn, [string[]]$ConditionalColumns)
            [void]$global:HUSkillExt.Excel.Add([pscustomobject]@{ Fn = 'Report'; Path = $ReportPath; Rows = @($Data).Count; Sheet = $SheetName })
        }
        function global:Add-HUExcelDashboard {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$WorkbookPath, [Parameter(Mandatory)][string]$TenantKey, [string]$ReportTitle = 'Report', [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Metrics, [hashtable[]]$SheetDataSources)
            [void]$global:HUSkillExt.Excel.Add([pscustomobject]@{ Fn = 'Dashboard'; Path = $WorkbookPath; Metrics = $Metrics })
        }

        function script:Get-TestExt([string]$Name) { return @(Get-AllExtensions -SearchPaths @((Join-Path $script:TmpRoot 'Extensions')) -ForceRescan | Where-Object { $_.Name -eq $Name })[0] }
        function script:Start-TestExt([string]$Name, [hashtable]$Custom = @{}, [switch]$WhatIf) {
            $global:HUSkillExt.Calls.Clear()
            $global:HUSkillExt.Log.Clear()
            $global:HUSkillExt.Excel.Clear()
            $ext = Get-TestExt $Name
            if ($WhatIf) { return Invoke-ExtensionScript -Extension $ext -TenantKey 'Schule-1' -Token 'tok-123' -WhatIf -CustomParameters $Custom }
            return Invoke-ExtensionScript -Extension $ext -TenantKey 'Schule-1' -Token 'tok-123' -CustomParameters $Custom
        }
        $script:Stale = (Get-Date).AddDays(-90).ToUniversalTime().ToString('o')
        $script:Fresh = (Get-Date).AddDays(-1).ToUniversalTime().ToString('o')
    }
    AfterAll {
        foreach ($n in 'Invoke-GraphRequestAll', 'Invoke-GraphRequestWithRetry', 'Initialize-HUExcel', 'New-HUExcelReport', 'Add-HUExcelDashboard', 'Write-HULogInfo', 'Write-HULogOK', 'Write-HULogWarn', 'Write-HULogError', 'Write-HULogDebug') { Remove-Item -Path "function:global:$n" -ErrorAction SilentlyContinue }
        Remove-Variable -Name HUSkillExt -Scope Global -ErrorAction SilentlyContinue
        Remove-Module HU.Extensions -Force -ErrorAction SilentlyContinue
        if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot)) { Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Attrappen haben die Parameter der echten Funktionen' {
        $rt = Join-Path $script:Repo 'Core\HU.Graph.psm1'
        Assert-FakeMatchesReal 'Invoke-GraphRequestWithRetry' $rt
        Assert-FakeMatchesReal 'Invoke-GraphRequestAll' $rt
        $x = Join-Path $script:Repo 'Core\HU.Excel.psm1'
        Assert-FakeMatchesReal 'New-HUExcelReport' $x
        Assert-FakeMatchesReal 'Add-HUExcelDashboard' $x
        foreach ($l in 'Info', 'OK', 'Warn', 'Error', 'Debug') { Assert-FakeMatchesReal "Write-HULog$l" (Join-Path $script:Repo 'Core\HU.Logging.psm1') }
    }

    Context 'Lader' {
        It 'findet beide Vorlagen mit den Werten aus dem Kopf' {
            $b = Get-TestExt 'Device-BeispielSyncBericht'
            $b | Should -Not -BeNullOrEmpty
            $b.Category | Should -Be 'Device'
            $b.Mode | Should -Be 'ReadOnly'
            $b.DryRunCapable | Should -BeFalse
            $b.BatchCapable | Should -BeTrue
            @($b.CustomParameters | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Tage,Excel'
            $b.RequiredPermissions | Should -Contain 'DeviceManagementManagedDevices.Read.All'
            $g = Get-TestExt 'Device-BeispielGeraeteSync'
            $g | Should -Not -BeNullOrEmpty
            $g.Mode | Should -Be 'ReadWrite'
            $g.DryRunCapable | Should -BeTrue
            @($g.RequiredPermissions).Count | Should -Be 2
            @($g.CustomParameters | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Geraetename'
        }
        It 'ueberspringt eine Datei ohne SYNOPSIS/DESCRIPTION im ersten Blockkommentar' {
            $dir = Join-Path $script:TmpRoot 'Other\Device'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Device-Ohne.ps1') -Value "<#`n.CATEGORY`n    Device`n#>`nfunction Invoke-Ohne { param(`$TenantKey, `$Token) }" -Encoding UTF8
            $all = @(Get-AllExtensions -SearchPaths @((Join-Path $script:TmpRoot 'Other')) -ForceRescan)
            @($all | Where-Object { $_.Name -eq 'Device-Ohne' }).Count | Should -Be 0
            # und das Pruefprogramm meldet es
            @(Get-ExtensionFindings (Read-Utf8 (Join-Path $dir 'Device-Ohne.ps1')) | Where-Object { $_.Stufe -eq 'FEHLER' -and $_.Regel -eq 'E03' }).Count | Should -BeGreaterThan 0
        }
        It 'SupportsShouldProcess + eigenes -WhatIf scheitert beim Start (Fehler, wie im Pruefprogramm beschrieben)' {
            $dir = Join-Path $script:TmpRoot 'Konflikt\Device'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $code = "<#`n.SYNOPSIS`n    x`n.DRY_RUN_CAPABLE`n    true`n#>`nfunction Invoke-Konflikt {`n    [CmdletBinding(SupportsShouldProcess)]`n    param([Parameter(Mandatory)][string]`$TenantKey, [Parameter(Mandatory)][string]`$Token, [switch]`$WhatIf)`n    1`n}"
            Set-Content -LiteralPath (Join-Path $dir 'Device-Konflikt.ps1') -Value $code -Encoding UTF8
            $ext = @(Get-AllExtensions -SearchPaths @((Join-Path $script:TmpRoot 'Konflikt')) -ForceRescan)[0]
            $r = Invoke-ExtensionScript -Extension $ext -TenantKey 'T' -Token 'x' -WhatIf
            $r.Success | Should -BeFalse
        }
    }

    Context 'Device-BeispielSyncBericht' {
        BeforeEach {
            $global:HUSkillExt.PageFails = $false
            $global:HUSkillExt.ExcelOk = $true
            $global:HUSkillExt.Devices = @(
                [pscustomobject]@{ deviceName = 'NB-ALT'; userPrincipalName = 'a@x.at'; operatingSystem = 'Windows'; lastSyncDateTime = $script:Stale }
                [pscustomobject]@{ deviceName = 'NB-NEU'; userPrincipalName = 'b@x.at'; operatingSystem = 'Windows'; lastSyncDateTime = $script:Fresh }
            )
        }
        It 'Erfolg, zaehlt richtig, benutzt TenantKey, protokolliert ueber Write-HULog*' {
            $r = Start-TestExt 'Device-BeispielSyncBericht' @{ Tage = 30; Excel = $false }
            $r.Success | Should -BeTrue
            $r.Output.Geraete | Should -Be 2
            $r.Output.OhneSync | Should -Be 1
            $global:HUSkillExt.Calls[0].TenantKey | Should -Be 'Schule-1'
            ($global:HUSkillExt.Log -join "`n") | Should -Match 'NB-ALT'
        }
        It 'Excel an: Bericht im Ordner HU-Reports_<Datum>, Dashboard mit Kennzahlen' {
            $r = Start-TestExt 'Device-BeispielSyncBericht' @{ Tage = 30; Excel = $true }
            $r.Success | Should -BeTrue
            $rep = @($global:HUSkillExt.Excel | Where-Object { $_.Fn -eq 'Report' })[0]
            $rep.Rows | Should -Be 1
            $rep.Path | Should -Match 'HU-Reports_\d{4}-\d{2}-\d{2}'
            $rep.Path | Should -Match '\.xlsx$'
            $r.Output.Bericht | Should -Be $rep.Path
            $dash = @($global:HUSkillExt.Excel | Where-Object { $_.Fn -eq 'Dashboard' })[0]
            $dash.Metrics['Ohne Sync'] | Should -Be 1
        }
        It 'ohne ImportExcel: kein Bericht, trotzdem Erfolg' {
            $global:HUSkillExt.ExcelOk = $false
            $r = Start-TestExt 'Device-BeispielSyncBericht' @{ Tage = 30; Excel = $true }
            $r.Success | Should -BeTrue
            $r.Output.Bericht | Should -Be ''
        }
        It 'unvollstaendige Liste: Ausnahme, Oberflaeche meldet Fehlschlag' {
            $global:HUSkillExt.PageFails = $true
            $r = Start-TestExt 'Device-BeispielSyncBericht' @{ Tage = 30; Excel = $false }
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match 'unvollstaendig'
        }
        It 'ein nicht deklarierter Parameter aus der Oberflaeche wird ignoriert' {
            $r = Start-TestExt 'Device-BeispielSyncBericht' @{ Tage = 30; Excel = $false; Unbekannt = 'x' }
            $r.Success | Should -BeTrue
        }
    }

    Context 'Device-BeispielGeraeteSync' {
        BeforeEach {
            $global:HUSkillExt.PageFails = $false
            $global:HUSkillExt.PostResult = $null
            $global:HUSkillExt.Devices = @([pscustomobject]@{ id = 'id-1'; deviceName = 'NB-1' })
        }
        It 'Probelauf: -WhatIf wird uebergeben, kein aendernder Aufruf' {
            $r = Start-TestExt 'Device-BeispielGeraeteSync' @{ Geraetename = 'NB-1' } -WhatIf
            $r.Success | Should -BeTrue
            $r.WasDryRun | Should -BeTrue
            $r.Output.Probelauf | Should -BeTrue
            @($global:HUSkillExt.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
        }
        It 'echter Lauf: POST syncDevice mit TenantKey' {
            $r = Start-TestExt 'Device-BeispielGeraeteSync' @{ Geraetename = 'NB-1' }
            $r.Success | Should -BeTrue
            $posts = @($global:HUSkillExt.Calls | Where-Object { $_.Method -eq 'POST' })
            $posts.Count | Should -Be 1
            $posts[0].Endpoint | Should -Be '/deviceManagement/managedDevices/id-1/syncDevice'
            $posts[0].TenantKey | Should -Be 'Schule-1'
            $r.Output.Geaendert | Should -Be 1
        }
        It 'Fehlerobjekt der Antwort: Ausnahme, Fehlschlag in der Oberflaeche' {
            $global:HUSkillExt.PostResult = [pscustomobject]@{ IsError = $true; StatusCode = 403; ErrorMessage = 'verboten'; Endpoint = 'x'; Method = 'POST' }
            $r = Start-TestExt 'Device-BeispielGeraeteSync' @{ Geraetename = 'NB-1' }
            $r.Success | Should -BeFalse
            $r.ErrorMessage | Should -Match '1 von 1'
        }
        It 'unvollstaendige Liste: nichts geaendert, Fehlschlag' {
            $global:HUSkillExt.PageFails = $true
            $r = Start-TestExt 'Device-BeispielGeraeteSync' @{ Geraetename = 'NB-1' }
            $r.Success | Should -BeFalse
            @($global:HUSkillExt.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
        }
        It 'leerer Name: Fehlschlag mit Hinweis, kein Graph-Aufruf' {
            $r = Start-TestExt 'Device-BeispielGeraeteSync' @{ Geraetename = '' }
            $r.Success | Should -BeFalse
            $global:HUSkillExt.Calls.Count | Should -Be 0
        }
    }
}
