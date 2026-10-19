#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer den Vergleich von Conditional-Access-Richtlinien (Core\HU.Intune.psm1) - ohne Netzwerk.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Mod = Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking -PassThru
    function script:Pol($state, $groups, $roles = @('62e90394-69f5-4237-9190-012177145e10')) {
        [pscustomobject]@{
            id = [guid]::NewGuid().ToString(); displayName = 'MFA'; state = $state; createdDateTime = (Get-Date).ToString('o')
            conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeUsers = @(); excludeUsers = @(); includeGroups = $groups; excludeGroups = @(); includeRoles = $roles }; applications = [pscustomobject]@{ includeApplications = @('All') } }
            grantControls = [pscustomobject]@{ builtInControls = @('mfa') }
        }
    }
}

Describe 'Conditional Access: Hash zwischen Tenants vergleichbar' {
    It 'gleiche Richtlinie mit anderen Gruppen-IDs gleicher Anzahl hat denselben Hash' {
        $a = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' @([guid]::NewGuid().ToString()))
        $b = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' @([guid]::NewGuid().ToString()))
        $a | Should -Be $b
    }
    It 'anderer Status ergibt anderen Hash' {
        $g = @([guid]::NewGuid().ToString())
        $a = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' $g)
        $b = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'disabled' $g)
        $a | Should -Not -Be $b
    }
    It 'andere Anzahl Gruppen oder andere Rollen ergibt anderen Hash' {
        $one = @([guid]::NewGuid().ToString()); $two = @([guid]::NewGuid().ToString(), [guid]::NewGuid().ToString())
        $a = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' $one)
        $b = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' $two)
        $c = & $script:Mod { param($p) Get-HUCompareHash (ConvertTo-HUCaComparable $p) } (Pol 'enabled' $one @('194ae4cb-b126-40b2-bd5b-6091b380977d'))
        $a | Should -Not -Be $b
        $a | Should -Not -Be $c
    }
    It 'Statusbezeichnung: Ein, Aus, Melden' {
        (& $script:Mod { Get-HUCaStateLabel ([pscustomobject]@{ state = 'enabled' }) }) | Should -Be 'Ein'
        (& $script:Mod { Get-HUCaStateLabel ([pscustomobject]@{ state = 'disabled' }) }) | Should -Be 'Aus'
        (& $script:Mod { Get-HUCaStateLabel ([pscustomobject]@{ state = 'enabledForReportingButNotEnforced' }) }) | Should -Be 'Melden'
    }
}

Describe 'Vergleich: Namen mit doppelten Leerzeichen' {
    It 'zaehlt "204 -  MFA" und "204 - MFA" als dieselbe Richtlinie' {
        $rows = @(
            [pscustomobject]@{ Tenant = 'A'; Typ = 'Conditional Access'; Name = '204 -  MFA Guests'; Id = '1'; Hash = 'x'; Copy = ''; Info = 'Ein' },
            [pscustomobject]@{ Tenant = 'B'; Typ = 'Conditional Access'; Name = '204 - MFA Guests '; Id = '2'; Hash = 'x'; Copy = ''; Info = 'Aus' })
        $m = @(& $script:Mod { param($r) Get-HUCompareMatrix $r @('A', 'B') } $rows)
        $m.Count | Should -Be 1
        $m[0].Missing.Count | Should -Be 0
    }
}
