#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5: Support-ZIP, Ordnername einer Testinstallation (Functions\UI-Support.ps1). Kein Fenster, kein ZIP auf dem Desktop.
.NOTES
    Aufruf: Invoke-Pester .github\tests\UI.Support.Tests.ps1
#>

BeforeAll {
    Set-StrictMode -Version 1.0   # wie Main.ps1
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $script:Root 'Functions\UI-Support.ps1')
}

Describe 'Support-ZIP: Ordnername einer Testinstallation' {
    It 'ein Ordnername mit weniger als 8 Zeichen wirft nicht und bleibt ganz' {
        { Get-HUSandboxZipLabel 'abc' $null } | Should -Not -Throw
        Get-HUSandboxZipLabel 'abc' $null | Should -BeExactly 'abc'
        Get-HUSandboxZipLabel '' $null | Should -BeExactly ''
    }
    It 'genau 8 Zeichen bleiben ganz, laengere werden auf 8 gekuerzt' {
        Get-HUSandboxZipLabel 'abcdefgh' $null | Should -BeExactly 'abcdefgh'
        Get-HUSandboxZipLabel '0f0f0f0f1234abcd' $null | Should -BeExactly '0f0f0f0f'
    }
    It 'ungueltige Dateinamenzeichen werden auch im Ordnernamen ersetzt' {
        Get-HUSandboxZipLabel 'a:b*c?d<e>f|g' $null | Should -BeExactly 'a_b_c_d_'
    }
    It 'mit bekannter App gilt deren Name (ungueltige Zeichen ersetzt), egal wie kurz der Ordnername ist' {
        $app = [pscustomobject]@{ Name = 'Mein/Programm: 1' }
        Get-HUSandboxZipLabel 'x' $app | Should -BeExactly 'Mein_Programm_ 1'
    }
    It 'New-HUSupportZip nutzt die Funktion und schneidet den Namen nicht mehr selbst' {
        $src = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Support.ps1'), [Text.Encoding]::UTF8)
        $src | Should -Match 'Get-HUSandboxZipLabel \$d\.Name \$app'
        $src | Should -Not -Match '\$d\.Name\.Substring\(0, 8\)'
    }
    It 'Testlauf mit echtem Sandbox-Ordner mit kurzem Namen: Label ohne Fehler (Temp-Ordner als LOCALAPPDATA)' {
        $old = $env:LOCALAPPDATA
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("husup_" + [guid]::NewGuid().ToString('N'))
        try {
            $sb = Join-Path (Join-Path $tmp 'HU-MultiTenant') 'Sandbox'
            [void](New-Item -ItemType Directory -Path (Join-Path $sb 'kurz') -Force)
            $env:LOCALAPPDATA = $tmp
            $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'HU-MultiTenant') 'Sandbox'
            $labels = @(foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory)) { Get-HUSandboxZipLabel $d.Name $null })
            $labels | Should -Be @('kurz')
        } finally {
            $env:LOCALAPPDATA = $old
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
