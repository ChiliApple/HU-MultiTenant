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
    foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Get-HUPermUsage', 'Get-HUAppPermNeed', 'Get-HUWriteRoles' }, $true)) {
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

Describe 'Rechte-Fenster: Schreibrechte entziehen (2.6.12, Altbefund Sicherheit B1)' {
    It 'waehlt nur Rechte, mit denen die App aendern, senden oder Geraete steuern kann' {
        $r = @(Get-HUWriteRoles @('Directory.Read.All', 'DeviceManagementApps.ReadWrite.All', 'User.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'Mail.Send', 'AuditLog.Read.All', 'Policy.Read.All', 'Sites.FullControl.All', 'Group.Read.All', 'DeviceManagementApps.ReadWrite.All'))
        $r | Should -Be @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'Mail.Send', 'Sites.FullControl.All', 'User.ReadWrite.All')
    }
    It '078 Grok B1: auch Anlegen, Verwalten, Einladen und Konten sperren' {
        $r = @(Get-HUWriteRoles @('Group.Create', 'Team.Create', 'User.Invite.All', 'User.EnableDisableAccount.All', 'Sites.Manage.All', 'Group.Read.All', 'Sites.Read.All'))
        $r | Should -Be @('Group.Create', 'Sites.Manage.All', 'Team.Create', 'User.EnableDisableAccount.All', 'User.Invite.All')
    }
    It 'leer und nur Leserechte ergeben keine Auswahl' {
        @(Get-HUWriteRoles @()).Count | Should -Be 0
        @(Get-HUWriteRoles $null).Count | Should -Be 0
        @(Get-HUWriteRoles @('Directory.Read.All', 'Reports.Read.All')).Count | Should -Be 0
    }
}
