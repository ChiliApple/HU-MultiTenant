#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer die Doku-Seiten-Auswahl (Show-HUManual) - ohne Oberflaeche, nur Quelltext-Pruefung.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Root = $root
    $script:Src = Join-Path $root 'Functions\UI-Update.ps1'
    $tokens = $null; $errs = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$tokens, [ref]$errs)
    $script:Fn = $script:Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-HUManual' }, $true)
    $script:Pages = @('Anleitung', 'Einstieg', 'Funktionen', 'Roadmap')
}

Describe 'Show-HUManual: nur feste Seiten' {
    It 'Funktion ist vorhanden' { $script:Fn | Should -Not -BeNullOrEmpty }
    It 'Parameter Page hat eine Positivliste mit genau den erlaubten Seiten' {
        $p = $script:Fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Page' }
        $p | Should -Not -BeNullOrEmpty
        $vs = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $vs | Should -Not -BeNullOrEmpty
        $vals = @($vs.PositionalArguments | ForEach-Object { $_.Value })
        ($vals | Sort-Object) -join ',' | Should -Be (($script:Pages | Sort-Object) -join ',')
    }
    It 'Standardwert ist Anleitung (bestehende Aufrufe bleiben gleich)' {
        $p = $script:Fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Page' }
        "$($p.DefaultValue.Value)" | Should -Be 'Anleitung'
    }
    It 'jede Seite der Liste existiert in docs\' {
        foreach ($pg in $script:Pages) { Test-Path -LiteralPath (Join-Path $script:Root "docs\$pg.html") | Should -BeTrue -Because $pg }
    }
    It 'Temp-Datei ist je Seite getrennt' {
        $txt = Get-Content -LiteralPath $script:Src -Raw
        $txt | Should -Match 'HU-MultiTenant_\$file'
    }
}
