#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests fuer Core\HU.WinUpdate.psm1 (2.6.3): Build -> Version, Patchstand aus dem Katalog, Ringe/Profile, Uebersicht.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.WinUpdate.psm1') -Force -DisableNameChecking
    $rev = { param($b, $u, $d) [pscustomobject]@{ osBuild = [pscustomobject]@{ buildNumber = $b; updateBuildRevision = $u }; releaseDateTime = $d } }
    $script:Items = @(
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateCatalogItem'; displayName = '2026.10 B'; classification = 'security'; releaseDateTime = '2026-10-14T00:00:00Z'; productRevisions = @((& $rev 26200 7000 '2026-10-14T00:00:00Z'), (& $rev 26100 7000 '2026-10-14T00:00:00Z')) }
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateCatalogItem'; displayName = '2026.09 B'; classification = 'security'; releaseDateTime = '2026-09-09T00:00:00Z'; productRevisions = @((& $rev 26200 6800 '2026-09-09T00:00:00Z')) }
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateCatalogItem'; displayName = '2026.06 B'; classification = 'security'; releaseDateTime = '2026-06-10T00:00:00Z'; productRevisions = @((& $rev 26200 6000 '2026-06-10T00:00:00Z')) }
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateCatalogItem'; displayName = '2026.10 D'; classification = 'nonSecurity'; releaseDateTime = '2026-10-28T00:00:00Z'; productRevisions = @((& $rev 26200 7100 '2026-10-28T00:00:00Z')) }
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsFeatureUpdateCatalogItem'; displayName = '25H2' }
    )
}

Describe 'Windows-Updates: Version und Patchstand' {
    It 'Build -> Version' {
        (Get-HUWuBuildInfo '10.0.26200.6899').Label | Should -Be 'Windows 11 25H2 (26200)'
        (Get-HUWuBuildInfo '10.0.26100.1').Version | Should -Be '24H2'
        (Get-HUWuBuildInfo '10.0.19045.5000').Product | Should -Be 'Windows 10'
        (Get-HUWuBuildInfo '10.0.27000.1').Label | Should -Be 'Windows 11 Build 27000 (Vorschau oder unbekannt)'
        (Get-HUWuBuildInfo '10.0.20348.1').Label | Should -Be 'Windows Server 2022 (20348)'
        (Get-HUWuBuildInfo '').Label | Should -Be 'unbekannt'
    }
    It 'Name neuer Versionen kommt aus dem Katalog (z. B. 26H2)' {
        $it = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateCatalogItem'; classification = 'security'; releaseDateTime = '2026-10-14T00:00:00Z'
            productRevisions = @([pscustomobject]@{ versionName = '26H2'; productName = 'Windows 11'; releaseDateTime = '2026-10-14T00:00:00Z'; osBuild = [pscustomobject]@{ buildNumber = 26300; updateBuildRevision = 9700 } }) }
        $c = ConvertFrom-HUWuCatalog @($it)
        (Get-HUWuBuildInfo '10.0.26300.9700' $c).Label | Should -Be 'Windows 11 26H2 (26300)'
        (Get-HUWuBuildInfo '10.0.26300.9700').Label | Should -Match 'Vorschau'
    }
    It 'Katalog: nur Qualitaets-Updates, je Build neueste zuerst' {
        $c = ConvertFrom-HUWuCatalog $script:Items
        @($c[26200]).Count | Should -Be 4
        @($c[26200])[0].Ubr | Should -Be 7100
        @($c[26100]).Count | Should -Be 1
    }
    It 'Patchstand: aktuell = neuestes Sicherheitsupdate, zurueck <= 40 Tage, sonst veraltet' {
        $c = ConvertFrom-HUWuCatalog $script:Items
        Get-HUWuPatchState (Get-HUWuBuildInfo '10.0.26200.7000') $c | Should -Be 'aktuell'
        Get-HUWuPatchState (Get-HUWuBuildInfo '10.0.26200.7100') $c | Should -Be 'aktuell'
        Get-HUWuPatchState (Get-HUWuBuildInfo '10.0.26200.6850') $c | Should -Be 'zurueck'
        Get-HUWuPatchState (Get-HUWuBuildInfo '10.0.26200.6000') $c | Should -Be 'veraltet'
        Get-HUWuPatchState (Get-HUWuBuildInfo '10.0.22631.1') $c | Should -Be 'unbekannt'
        Get-HUWuLatestText $c 26200 | Should -Be '26200.7000 vom 14.10.2026'
    }
    It 'Update-Ring: Aufschub, Pause, Neustart-Pruefung' {
        $o = [pscustomobject]@{ id = 'r1'; displayName = 'Ring'; qualityUpdatesDeferralPeriodInDays = 3; featureUpdatesDeferralPeriodInDays = 14; deadlineForQualityUpdatesInDays = 2; deadlineForFeatureUpdatesInDays = 7
            installationSchedule = [pscustomobject]@{ activeHoursStart = '07:00:00.0000000'; activeHoursEnd = '15:00:00.0000000' }; skipChecksBeforeRestart = $true
            qualityUpdatesPaused = $true; qualityUpdatesPauseExpiryDateTime = '2026-10-30T10:00:00Z'; featureUpdatesPaused = $false }
        $r = ConvertTo-HUWuPolicyRow -Tenant 't' -Art 'Update-Ring' -O $o -Asg @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) -Names @{} -Now ([datetime]'2026-10-28')
        $r.Einstellung | Should -Match 'Qualitaet 3 T\., Feature 14 T\.'
        $r.Einstellung | Should -Match 'aktive Zeit 07:00-15:00'
        $r.Pause | Should -Match '^Qualitaet bis 30\.10\.'
        $r.Hinweis | Should -Match 'Neustart-Pruefung'
        $r.Hinweis | Should -Match 'Qualitaet-Pause endet'
        $r.Zuweisung | Should -Be 'Alle Geraete'
    }
    It 'Feature-Update: Zielversion und Zuweisung ueber Gruppennamen' {
        $o = [pscustomobject]@{ id = 'f1'; displayName = 'Auf 25H2'; featureUpdateVersion = 'Windows 11, version 25H2'; endOfSupportDate = '2028-10-10T00:00:00Z' }
        $r = ConvertTo-HUWuPolicyRow -Tenant 't' -Art 'Feature-Update' -O $o -Asg @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }) -Names @{ g1 = 'Schueler-NB' }
        $r.Einstellung | Should -Match 'Zielversion: Windows 11, version 25H2'
        $r.Zuweisung | Should -Be 'Schueler-NB'
        (ConvertTo-HUWuPolicyRow -Tenant 't' -Art 'Feature-Update' -O $o -Asg @() -Names @{}).Zuweisung | Should -Be 'nicht zugewiesen'
    }
    It 'Uebersicht und Kurzfassung' {
        $c = ConvertFrom-HUWuCatalog $script:Items
        $mk = { param($v, $p, $stale) [pscustomobject]@{ Version = (Get-HUWuBuildInfo $v).Label; BuildNr = (Get-HUWuBuildInfo $v).Build; Patchstand = $p; OhneSync = $stale } }
        $i1 = [pscustomobject]@{ Tenant = 'a'; Catalog = $c; Devices = @((& $mk '10.0.26200.7000' 'aktuell' $false), (& $mk '10.0.26200.6000' 'veraltet' $true), (& $mk '10.0.26100.7000' 'aktuell' $false)) }
        $i2 = [pscustomobject]@{ Tenant = 'b'; Catalog = $c; Devices = @((& $mk '10.0.26200.7000' 'aktuell' $false)) }
        $m = @(Get-HUWuMatrix @($i1, $i2) @{ a = 'Schule A'; b = 'Schule B' })
        $m.Count | Should -Be 2
        $m[0].Version | Should -Be 'Windows 11 25H2 (26200)'
        $m[0].'Schule A' | Should -Be '2 (1 aktuell)'
        $m[0].'Schule B' | Should -Be '1 (1 aktuell)'
        $m[0].Gesamt | Should -Be 3
        $m[1].'Schule B' | Should -Be ''
        $s = Get-HUWuSummary $i1
        $s.Total | Should -Be 3; $s.Old | Should -Be 1; $s.Stale | Should -Be 1
    }
}
