#Requires -Version 5.1
# Tenant-Vergleich, Schalter "Farben": Farbe je Zelle (Get-HUCmpCellColor aus Functions\UI-Analyse.ps1)

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Functions\UI-Analyse.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HUCmpCellColor' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    function Get-HUMusterKey { '__MUSTER__' }
    $script:Controls = @{ chkCmpColor = [pscustomobject]@{ IsChecked = $true } }
    $script:Mk = { param($status, $items, $have, $unk = @()) [pscustomobject]@{ Status = $status; Items = $items; Have = $have; Unknown = $unk } }
    $script:It = { param($t, $h) [pscustomobject]@{ Tenant = $t; Hash = $h } }
}

Describe 'Tenant-Vergleich: Farben' {
    It 'fehlt = rot, nicht lesbar = grau, gleich = gruen' {
        $m = & $script:Mk 'fehlt teilweise' @((& $script:It 'A' 'h1')) @('A') @('C')
        Get-HUCmpCellColor $m 'A' | Should -Be '#81C784'
        Get-HUCmpCellColor $m 'B' | Should -Be '#EF5350'
        Get-HUCmpCellColor $m 'C' | Should -Be '#8A8A8A'
    }
    It 'abweichend: Vergleich mit dem Muster, sonst mit der Mehrheit' {
        $m = & $script:Mk 'ueberall, Einstellungen abweichend' @((& $script:It '__MUSTER__' 'h1'), (& $script:It 'A' 'h1'), (& $script:It 'B' 'h2'), (& $script:It 'C' 'h2')) @('__MUSTER__', 'A', 'B', 'C')
        Get-HUCmpCellColor $m 'A' | Should -Be '#81C784'
        Get-HUCmpCellColor $m 'B' | Should -Be '#FFB74D'
        $m2 = & $script:Mk 'ueberall, Einstellungen abweichend' @((& $script:It 'A' 'h1'), (& $script:It 'B' 'h2'), (& $script:It 'C' 'h2')) @('A', 'B', 'C')
        Get-HUCmpCellColor $m2 'A' | Should -Be '#FFB74D'
        Get-HUCmpCellColor $m2 'B' | Should -Be '#81C784'
    }
    It 'nicht abweichend (z. B. nur Reihenfolge): alle vorhandenen gruen; Schalter aus: normale Schrift' {
        $m = & $script:Mk 'ueberall' @((& $script:It 'A' 'h1'), (& $script:It 'B' 'h2')) @('A', 'B')
        Get-HUCmpCellColor $m 'B' | Should -Be '#81C784'
        $script:Controls.chkCmpColor.IsChecked = $false
        Get-HUCmpCellColor $m 'B' | Should -Be '#CCCCCC'
        $script:Controls.chkCmpColor.IsChecked = $true
    }
}
