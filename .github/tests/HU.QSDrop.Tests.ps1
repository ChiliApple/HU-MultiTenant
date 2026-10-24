#Requires -Version 5.1
# Quick Script: .ps1 ins Codefeld ziehen (Read-HUQSDropFile aus Functions\UI-QuickScript.ps1)

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Functions\UI-QuickScript.ps1'), [ref]$null, [ref]$null)
    foreach ($name in 'Read-HUQSDropFile', 'Get-HUQSScriptHints') {
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("HU-QSD-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
}
AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Quick Script: Datei ins Codefeld' {
    It 'liest UTF-8 mit und ohne BOM, Umlaute bleiben' {
        $txt = "# Prüfung äöü`r`nWrite-Host 'ß'"
        $a = Join-Path $script:Dir 'a.ps1'; [IO.File]::WriteAllText($a, $txt, (New-Object System.Text.UTF8Encoding($true)))
        $b = Join-Path $script:Dir 'b.ps1'; [IO.File]::WriteAllText($b, $txt, (New-Object System.Text.UTF8Encoding($false)))
        Read-HUQSDropFile $a | Should -BeExactly $txt
        Read-HUQSDropFile $b | Should -BeExactly $txt
    }
    It 'liest UTF-16 (BOM) und Windows-1252 ohne BOM' {
        $txt = "# Größe"
        $u = Join-Path $script:Dir 'u.ps1'; [IO.File]::WriteAllText($u, $txt, [System.Text.Encoding]::Unicode)
        Read-HUQSDropFile $u | Should -BeExactly $txt
        $w = Join-Path $script:Dir 'w.txt'; [IO.File]::WriteAllBytes($w, [System.Text.Encoding]::GetEncoding(1252).GetBytes($txt))
        Read-HUQSDropFile $w | Should -BeExactly $txt
    }
    It 'lehnt andere Endungen und zu grosse Dateien ab' {
        $x = Join-Path $script:Dir 'x.exe'; [IO.File]::WriteAllText($x, 'x')
        { Read-HUQSDropFile $x } | Should -Throw '*Nur .ps1*'
        $big = Join-Path $script:Dir 'big.ps1'; [IO.File]::WriteAllBytes($big, (New-Object byte[] (1MB + 1)))
        { Read-HUQSDropFile $big } | Should -Throw '*1 MB*'
    }
    It 'Hinweise: HU-Snippet vs. fremdes Skript, auffaellige Befehle, Kommentare zaehlen nicht' {
        $hu = Get-HUQSScriptHints "# @param Name|string|Name`r`n`$r = Invoke-GraphRequest -Token `$Token -Endpoint '/users'"
        $hu.Foreign | Should -BeFalse
        @($hu.Risky).Count | Should -Be 0
        $fr = Get-HUQSScriptHints "Connect-MgGraph`nRemove-Item C:\x -Recurse`n# Restart-Computer`niex `$s"
        $fr.Foreign | Should -BeTrue
        @($fr.Risky) | Should -Contain 'Loeschen (Remove-...)'
        @($fr.Risky) | Should -Contain 'Eigene Anmeldung (Connect-...)'
        @($fr.Risky) | Should -Contain 'Code aus Text ausfuehren (Invoke-Expression)'
        @($fr.Risky) | Should -Not -Contain 'Neustart/Herunterfahren'
    }
}
