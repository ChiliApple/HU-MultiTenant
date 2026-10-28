#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests fuer Functions\UI-Permissions.ps1 (2.6.2): Rechte aus Snippets, was die App braucht.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Setup.psm1') -Force -DisableNameChecking
    $src = Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Permissions.ps1') -Raw -Encoding UTF8
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Get-HUPermUsage', 'Get-HUAppPermNeed' }, $true)) {
        . ([scriptblock]::Create($f.Extent.Text.Replace('function ', 'function global:')))
    }
    $script:AppRoot = $root
    $global:ExtSnipRoot = $root
}

Describe 'Rechte-Fenster: Herkunft der Rechte (2.6.2)' {
    It 'liest die Zeile # Berechtigungen: aus Snippets, nur mit -WithSnippets' {
        function global:Get-HUSnippets { @([pscustomobject]@{ name = 'Gaeste'; code = "# Gaeste loeschen`n# Berechtigungen: User.ReadWrite.All, Directory.Read.All (optional)`nGet-X" }) }
        $script:ExtensionItems = @()
        $u = Get-HUPermUsage -WithSnippets
        @($u['User.ReadWrite.All']) | Should -Be @('Snippet: Gaeste')
        @($u['Directory.Read.All']) | Should -Be @('Snippet: Gaeste')
        (Get-HUPermUsage).Count | Should -Be 0
    }
    It 'App braucht: Standard, Verteilen, bei Bedarf, sonst leer' {
        $script:AppRoot = $global:ExtSnipRoot
        $n = Get-HUAppPermNeed
        $n['User.Read.All'] | Should -Be 'Standard'
        $n['DeviceManagementApps.ReadWrite.All'] | Should -Be 'Verteilen'
        $n['Group.Create'] | Should -Be 'bei Bedarf'
        $n.ContainsKey('User.ReadWrite.All') | Should -BeFalse
    }
}
