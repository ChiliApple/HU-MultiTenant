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
    It 'Patchstand: Anzahl neuerer Sicherheitsupdates (0 aktuell, 1 zurueck, 2+ veraltet)' {
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
        $r.Einstellung | Should -Match 'Aufschub Qualitaet 3 T\., Feature 14 T\.; Frist Qualitaet 2 T\., Feature 7 T\.'
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
        $m[0].'Aktuell %' | Should -Be 67
        @(Get-HUWuMatrix @($i1) @{} ([datetime]'2026-11-01'))[0].Support | Should -Be 'laeuft'
        @(Get-HUWuMatrix @($i1) @{} ([datetime]'2027-06-01'))[0].Support | Should -Be 'abgelaufen'
        $s = Get-HUWuSummary $i1
        $s.Total | Should -Be 3; $s.Old | Should -Be 1; $s.Stale | Should -Be 1
    }
    It 'Treiber: Zeile, Status, Kategorie und Zusammenfassung ueber Tenants' {
        $d1 = [pscustomobject]@{ id = 'x1'; name = 'Intel Grafik'; version = '31.0.1'; manufacturer = 'Intel'; driverClass = 'Display'; category = 'recommended'; approvalStatus = 'needsReview'; applicableDeviceCount = 120; releaseDateTime = '2026-10-01T00:00:00Z' }
        $d2 = [pscustomobject]@{ id = 'y1'; name = 'Intel Grafik'; version = '31.0.1'; manufacturer = 'Intel'; driverClass = 'Display'; category = 'recommended'; approvalStatus = 'approved'; applicableDeviceCount = 80; deployDateTime = '2026-10-20T00:00:00Z' }
        $r1 = ConvertTo-HUWuDriverRow -Tenant 'a' -ProfileId 'p1' -ProfileName 'Treiber' -D $d1
        $r1.Status | Should -Be 'pruefen'; $r1.Kategorie | Should -Be 'empfohlen'; $r1.Geraete | Should -Be 120; $r1.Datum | Should -Be '2026-10-01'
        $r2 = ConvertTo-HUWuDriverRow -Tenant 'b' -ProfileId 'p2' -ProfileName 'Treiber' -D $d2
        $r2.Ab | Should -Be '20.10.2026'
        $m = @(Get-HUWuDriverMatrix @([pscustomobject]@{ Tenant = 'a'; Drivers = @($r1) }, [pscustomobject]@{ Tenant = 'b'; Drivers = @($r2) }) @{ a = 'A'; b = 'B' })
        $m.Count | Should -Be 1
        $m[0].A | Should -Be '120 (pruefen)'
        $m[0].B | Should -Be '80 (freigegeben)'
        $m[0].Geraete | Should -Be 200
        @(Get-HUWuDriverMatrix @([pscustomobject]@{ Tenant = 'a'; Drivers = @($r1) }) @{} { param($d) $d.Status -eq 'freigegeben' }).Count | Should -Be 0
    }
    It 'Treiber-Richtlinie ohne meldende Geraete gibt einen Hinweis' {
        $o = [pscustomobject]@{ id = 'p1'; displayName = 'Treiber Auto'; approvalType = 'automatic'; deploymentDeferralInDays = 3; deviceReporting = 0; newUpdates = 0 }
        $r = ConvertTo-HUWuPolicyRow -Tenant 't' -Art 'Treiber-Update' -O $o -Asg @() -Names @{}
        $r.Einstellung | Should -Match 'automatisch'
        $r.Hinweis | Should -Match 'Keine Geraete melden'
    }
    It 'Beitritt als Text' {
        ConvertTo-HUWuJoinText 'azureADJoined' | Should -Be 'Entra'
        ConvertTo-HUWuJoinText 'azureADRegistered' | Should -Be 'nur registriert'
        ConvertTo-HUWuJoinText '' | Should -Be 'unbekannt'
    }
}

Describe 'Windows-Updates: aendern (Schritt 2)' {
    BeforeAll {
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:Bk = Join-Path ([IO.Path]::GetTempPath()) ("HU-WU-" + [guid]::NewGuid().ToString('N'))
    }
    AfterAll { Remove-Item -LiteralPath $script:Bk -Recurse -Force -ErrorAction SilentlyContinue }
    It 'Zuweisung ergaenzen und entfernen: liest, ersetzt gleiches Ziel, schreibt die ganze Liste' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll { @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'G1' } }, [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) }
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; M = $Method; B = $Body }); $null }
        $n = Set-HUWuAssignment -TenantKey 't' -Settings ([pscustomobject]@{}) -Art 'Update-Ring' -Id 'r1' -Add @([pscustomobject]@{ Kind = 'group'; GroupId = 'g2' }) -RemoveKeys @('allDevices|')
        $n | Should -Be 2
        $c = $script:Calls[-1]
        $c.Ep | Should -Be '/deviceManagement/deviceConfigurations/r1/assign'
        $c.M | Should -Be 'POST'
        @($c.B.assignments).Count | Should -Be 2
        @($c.B.assignments)[0].'@odata.type' | Should -Be '#microsoft.graph.deviceConfigurationAssignment'
        @($c.B.assignments | ForEach-Object { $_.target.groupId }) | Should -Contain 'g2'
    }
    It 'Feature-Update: Alle Geraete wird abgelehnt (nur Gruppen)' {
        { Set-HUWuAssignment -TenantKey 't' -Settings ([pscustomobject]@{}) -Art 'Feature-Update' -Id 'f1' -Add @([pscustomobject]@{ Kind = 'allDevices' }) } | Should -Throw '*Geraetegruppen*'
    }
    It 'Einstellungen: vorher sichern, PATCH mit @odata.type' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; M = $Method; B = $Body }); if ($Method -eq 'GET') { [pscustomobject]@{ id = 'r1'; deadlineForQualityUpdatesInDays = $null } } }
        $f = Set-HUWuSettings -TenantKey 't' -Settings ([pscustomobject]@{}) -Art 'Update-Ring' -Id 'r1' -Changes @{ deadlineForQualityUpdatesInDays = 3 } -BackupRoot $script:Bk
        Test-Path -LiteralPath $f | Should -BeTrue
        $p = $script:Calls[-1]
        $p.M | Should -Be 'PATCH'
        $p.B.'@odata.type' | Should -Be '#microsoft.graph.windowsUpdateForBusinessConfiguration'
        $p.B.deadlineForQualityUpdatesInDays | Should -Be 3
    }
    It 'Rollout: sofort = keine Einstellung, gestaffelt mit Ende und Abstand' {
        ConvertTo-HUWuRollout @{ Mode = 'now' } | Should -BeNullOrEmpty
        $r = ConvertTo-HUWuRollout @{ Mode = 'gradual'; Start = [datetime]'2026-11-02'; End = [datetime]'2026-11-16'; Interval = 7 }
        $r.offerIntervalInDays | Should -Be 7
        $r.offerEndDateTimeInUTC | Should -Match '^2026-11-1[56]T'
    }
    It 'Treiber freigeben: executeAction mit Datum' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; M = $Method; B = $Body }); [pscustomobject]@{ value = [pscustomobject]@{ successfulDriverIds = @('d1') } } }
        $r = Invoke-HUWuDriverAction -TenantKey 't' -Settings ([pscustomobject]@{}) -ProfileId 'p1' -Action approve -DriverIds @('d1') -Date ([datetime]'2026-10-28')
        @($r.successfulDriverIds) | Should -Be @('d1')
        $script:Calls[-1].Ep | Should -Be '/deviceManagement/windowsDriverUpdateProfiles/p1/executeAction'
        $script:Calls[-1].B.actionName | Should -Be 'approve'
        $script:Calls[-1].B.deploymentDate | Should -Match '^2026-10-2[78]T'
    }
    It 'Profile ueber Tenants zusammenfassen' {
        $a = [pscustomobject]@{ Tenant = 'a'; Art = 'Update-Ring'; Name = 'Ring'; Einstellung = 'x'; Pause = ''; Zuweisung = 'Alle Geraete'; Hinweis = ''; Id = '1'; AsgList = @() }
        $b = [pscustomobject]@{ Tenant = 'b'; Art = 'Update-Ring'; Name = 'ring'; Einstellung = 'y'; Pause = ''; Zuweisung = 'Alle Geraete'; Hinweis = ''; Id = '2'; AsgList = @() }
        $g = @(Get-HUWuPolicyGroups @([pscustomobject]@{ Policies = @($a) }, [pscustomobject]@{ Policies = @($b) }) @{ a = 'A'; b = 'B' })
        $g.Count | Should -Be 1
        $g[0].Tenants | Should -Be 'A, B'
        $g[0].Einstellung | Should -Match 'verschieden'
        @($g[0].Items).Count | Should -Be 2
    }

    It 'Treiber-Richtlinie: 0 melden wird durch Treiberliste korrigiert' {
        InModuleScope HU.WinUpdate {
            $row = [pscustomobject]@{ Id = 'p1'; Einstellung = 'manuell; 0 Geraet(e) melden'; Hinweis = 'Keine Geraete melden - x' }
            Update-HUWuDriverPolicyRow $row @([pscustomobject]@{ ProfilId = 'p1'; Geraete = 7 }, [pscustomobject]@{ ProfilId = 'p2'; Geraete = 99 })
            $row.Hinweis | Should -Be ''
            $row.Einstellung | Should -Be 'manuell; 1 Treiber, bis 7 betroffene Geraete'
        }
    }

    It 'Neuer Ring: Feature-Aufschub 0, aktive Zeit im Graph-Format' {
        $b = New-HUWuRingBody -Name 'R' -QualityDeferral 3 -QualityDeadline 3 -FeatureDeadline 7 -Grace 2 -ActiveStart '7:00' -ActiveEnd '15:00' -UserPause $false
        $b.featureUpdatesDeferralPeriodInDays | Should -Be 0
        $b.installationSchedule.activeHoursStart | Should -Be '07:00:00.0000000'
        $b.installationSchedule.activeHoursEnd | Should -Be '15:00:00.0000000'
        $b.userPauseAccess | Should -Be 'disabled'
        $b.skipChecksBeforeRestart | Should -BeFalse
        { New-HUWuRingBody -Name 'R' -QualityDeferral 3 -QualityDeadline 3 -FeatureDeadline 7 -Grace 2 -ActiveStart '25:00' -ActiveEnd '15:00' -UserPause $false } | Should -Throw
    }
}
