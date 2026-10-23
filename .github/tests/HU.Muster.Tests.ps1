#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.Muster.psm1 (Mustertenant, Namenszuordnung) und Get-HUBackupInventory - ohne Netzwerk.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.EntraRestore.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Muster.psm1') -Force -DisableNameChecking
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-MU-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:Tmp } }
    Mock -ModuleName HU.Muster Write-HULog { }

    # kleiner Backup-Stand: CA mit Gruppe, Ort, Notfallkonto, einem fremden Benutzer; Profil mit Zuweisung, Filter, Bereichsmarkierung
    $script:MkStand = {
        param([string]$Tenant, [string]$Name, [bool]$Complete = $true)
        $d = Join-Path (Join-Path $script:Tmp $Tenant) $Name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $ca = [pscustomobject]@{ id = 'ca1'; displayName = '201 - MFA'; state = 'enabled'
            conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('aaaaaaaa-0000-0000-0000-000000000001'); excludeUsers = @('bbbbbbbb-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001') }
                locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('dddddddd-0000-0000-0000-000000000001') } }
            grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('mfa') } }
        $prof = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; id = 'p1'; displayName = 'Win Basis'; passwordRequired = $true; roleScopeTagIds = @('0', '7')
            assignments = @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'eeeeeeee-0000-0000-0000-000000000001'; deviceAndAppManagementAssignmentFilterId = 'ffffffff-0000-0000-0000-000000000001' } }) }
        $loc = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'dddddddd-0000-0000-0000-000000000001'; displayName = 'Schule LAN'; isTrusted = $true; ipRanges = @() }
        $fil = [pscustomobject]@{ id = 'ffffffff-0000-0000-0000-000000000001'; displayName = 'Nur Lenovo'; rule = '(device.manufacturer -eq "LENOVO")'; platform = 'windows10AndLater' }
        $tag = [pscustomobject]@{ id = '7'; displayName = 'Schule'; description = '' }
        foreach ($x in @(@('Conditional Access', 'ca.json', $ca), @('Konfiguration', 'p.json', $prof), @('Benannter Ort', 'l.json', $loc), @('Zuweisungsfilter', 'f.json', $fil), @('Bereichsmarkierung', 't.json', $tag))) {
            New-Item -ItemType Directory -Path (Join-Path $d $x[0]) -Force | Out-Null
            Write-HUBackupJson (Join-Path $d "$($x[0])\$($x[1])") $x[2]
        }
        $items = @(
            [pscustomobject]@{ Typ = 'Conditional Access'; Name = '201 - MFA'; Id = 'ca1'; File = 'Conditional Access\ca.json' }
            [pscustomobject]@{ Typ = 'Konfiguration'; Name = 'Win Basis'; Id = 'p1'; File = 'Konfiguration\p.json' }
            [pscustomobject]@{ Typ = 'Benannter Ort'; Name = 'Schule LAN'; Id = 'dddddddd-0000-0000-0000-000000000001'; File = 'Benannter Ort\l.json' }
            [pscustomobject]@{ Typ = 'Zuweisungsfilter'; Name = 'Nur Lenovo'; Id = 'ffffffff-0000-0000-0000-000000000001'; File = 'Zuweisungsfilter\f.json' }
            [pscustomobject]@{ Typ = 'Bereichsmarkierung'; Name = 'Schule'; Id = '7'; File = 'Bereichsmarkierung\t.json' }
        )
        Write-HUBackupJson (Join-Path $d 'index.json') ([pscustomobject]@{ Tenant = $Tenant; Errors = $(if ($Complete) { 0 } else { 1 }); Complete = $Complete; FailedTypes = @($(if (-not $Complete) { 'Compliance' })); Items = $items })
        return $d
    }
}

AfterAll {
    Remove-Module HU.Muster -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Bestand aus einem Backup-Stand' {
    It 'gleiche Zeilen und gleicher Fingerabdruck wie der Live-Bestand, Kopieren aus dem Stand gibt es nicht' {
        $d = & $script:MkStand 'T1' '2026-10-01_080000' $false
        $rows = @(Get-HUBackupInventory -Folder $d -TenantKey '__MUSTER__')
        $ca = @($rows | Where-Object Typ -eq 'Conditional Access')[0]
        $ca.Info | Should -Not -BeNullOrEmpty
        $ca.Copy | Should -Be ''
        $prof = @($rows | Where-Object Typ -eq 'Konfiguration')[0]
        $o = Get-Content -LiteralPath (Join-Path $d 'Konfiguration\p.json') -Raw | ConvertFrom-Json
        # live gelesene Fassung ohne Zuweisungen: gleicher Fingerabdruck (Zuweisungen zaehlen im Vergleich nicht)
        $o.PSObject.Properties.Remove('assignments')
        $prof.Hash | Should -Be (Get-HUCompareHash $o)
        @($rows | Where-Object { $_.PSObject.Properties['Error'] -and $_.Error -and $_.Typ -eq 'Compliance' }).Count | Should -Be 1
        @($rows | Where-Object Typ -eq 'Benannter Ort')[0].Obj.displayName | Should -Be 'Schule LAN'
    }
}

Describe 'Mustertenant' {
    It 'nur vollstaendige Staende, das bisherige Muster wandert nach frueher' {
        $bad = & $script:MkStand 'T1' '2026-10-02_080000' $false
        { Save-HUMuster -Settings $script:Set -Folder $bad -TenantKey 'T1' } | Should -Throw '*vollstaendig*'
        $ok = & $script:MkStand 'T1' '2026-10-03_080000' $true
        { Save-HUMuster -Settings $script:Set -Folder $ok -TenantKey 'T2' } | Should -Throw '*gehoert zu Tenant*'
        $m = Save-HUMuster -Settings $script:Set -Folder $ok -TenantKey 'T1' -Now ([datetime]'2026-10-22 10:00')
        $m.Source | Should -Be 'T1'
        $m.Label | Should -BeLike 'Muster (T1, 03.10.2026)'
        $ok2 = & $script:MkStand 'T2' '2026-10-04_080000' $true
        $m2 = Save-HUMuster -Settings $script:Set -Folder $ok2 -TenantKey 'T2' -Now ([datetime]'2026-10-22 11:00')
        $m2.Source | Should -Be 'T2'
        @(Get-ChildItem -LiteralPath (Join-Path (Get-HUMusterRoot $script:Set) 'frueher') -Directory).Count | Should -Be 1
        # Ablaufdatum der Backups beruehrt das Muster nicht (eigener Ordner)
        Remove-HUOldBackups -Root $script:Tmp -TenantKey 'T2' -Keep 1 -MaxDays 1 -Now ([datetime]'2030-01-01') | Out-Null
        (Get-HUMuster $script:Set).Source | Should -Be 'T2'
    }
}

Describe 'Namenszuordnung' {
    BeforeAll {
        Mock -ModuleName HU.Muster Get-HUSecBaseline { [pscustomobject]@{ Values = @{ V1 = @{ accounts = @('bbbbbbbb-0000-0000-0000-000000000001') } } } }
        Mock -ModuleName HU.Muster Test-HUEntraBreakGlass { if ($TenantKey -eq 'Z1') { [pscustomobject]@{ Ok = $true; Text = 'ok' } } else { [pscustomobject]@{ Ok = $false; Text = 'Keine Notfallkonten hinterlegt' } } }
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph {
            param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
            if ($Endpoint -like '/groups/aaaaaaaa*') { return [pscustomobject]@{ displayName = 'Lehrer' } }
            if ($Endpoint -like '/groups/eeeeeeee*') { return [pscustomobject]@{ displayName = 'Geraete 1A' } }
            throw 'unerwartet'
        }
        Mock -ModuleName HU.Muster Get-HUIntuneGraphAll {
            param($TenantKey, $Settings, $Endpoint, [switch]$V1)
            if ($Endpoint -like '/groups?*') {
                $n = (([uri]::UnescapeDataString($Endpoint) -split "displayName eq '")[1] -split "'")[0]
                if ($TenantKey -eq 'Z1' -and $n -eq 'Lehrer') { return @([pscustomobject]@{ id = 'x'; displayName = 'lehrer ' }) }
                if ($TenantKey -eq 'Z2' -and $n -eq 'Lehrer') { return @([pscustomobject]@{ id = 'x'; displayName = 'Lehrer' }, [pscustomobject]@{ id = 'y'; displayName = 'Lehrer' }) }
                return @()
            }
            if ($Endpoint -like '/identity/conditionalAccess/namedLocations*') { if ($TenantKey -eq 'Z1') { return @([pscustomobject]@{ id = 'l'; displayName = 'Schule LAN' }) }; return @() }
            if ($Endpoint -like '/deviceManagement/assignmentFilters*') { if ($TenantKey -eq 'Z2') { throw '403' }; return @([pscustomobject]@{ id = 'f'; displayName = 'Nur Lenovo' }) }
            if ($Endpoint -like '/deviceManagement/roleScopeTags*') { return @([pscustomobject]@{ id = '0'; displayName = 'Default' }) }
            return @()
        }
    }
    It 'ok, fehlt, mehrfach, nicht pruefbar; Notfallkonto wird ersetzt, fremde Benutzer nicht zuordenbar' {
        $d = & $script:MkStand 'Q' '2026-10-05_080000' $true
        $rows = @(Get-HUNameMap -Settings $script:Set -Folder $d -SourceKey 'Q' -Targets @('Z1', 'Z2') -Names @{ Z1 = 'Schule 1'; Z2 = 'Schule 2' })
        $g = @($rows | Where-Object { $_.Art -eq 'Gruppe' -and $_.Name -eq 'Lehrer' })[0]
        $g.'Schule 1' | Should -Be 'ok'
        $g.'Schule 2' | Should -Be 'mehrfach (2)'
        @($rows | Where-Object { $_.Name -eq 'Geraete 1A' })[0].'Schule 1' | Should -Be 'fehlt'
        $l = @($rows | Where-Object Art -eq 'Benannter Ort')[0]
        $l.Name | Should -Be 'Schule LAN'
        $l.'Schule 1' | Should -Be 'ok'; $l.'Schule 2' | Should -Be 'fehlt'
        @($rows | Where-Object Art -eq 'Zuweisungsfilter')[0].'Schule 2' | Should -Be 'nicht pruefbar'
        @($rows | Where-Object Art -eq 'Bereichsmarkierung')[0].'Schule 1' | Should -Be 'fehlt'
        @($rows | Where-Object Art -eq 'Notfallkonto')[0].'Schule 1' | Should -BeLike '*Notfallkonten des Ziels*'
        @($rows | Where-Object Art -eq 'Benutzer')[0].'Schule 2' | Should -BeLike 'nicht zuordenbar*'
        $bg = @($rows | Where-Object Art -eq 'Notfallkonten')[0]
        $bg.'Schule 1' | Should -Be 'ok'; $bg.'Schule 2' | Should -BeLike 'Keine Notfallkonten*'
        @($rows | Where-Object Art -eq 'Gruppe')[0].'Verwendet in' | Should -Match '^1x: '
    }
    It 'Namen vergleichen: Gross/klein und Leerzeichen am Rand egal' {
        ConvertTo-HUMuName '  Lehrer Team ' | Should -Be (ConvertTo-HUMuName 'lehrer team')
        ConvertTo-HUMuName 'Lehrer  Team' | Should -Not -Be (ConvertTo-HUMuName 'lehrer team')
    }
}

Describe 'Muster: Apps ohne Datei im Stand' {
    It 'Apps (nur Name im Stand) gelten im Muster als vorhanden, nicht als nicht lesbar' {
        InModuleScope HU.Intune {
            $f = Join-Path ([IO.Path]::GetTempPath()) ("hu-mus-app-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $f -Force | Out-Null
            Write-HUBackupJson (Join-Path $f 'index.json') ([pscustomobject]@{ Errors = 0; Complete = $true; FailedTypes = @(); Items = @([pscustomobject]@{ Typ = 'App'; Name = '7-Zip'; Id = 'a1'; File = ''; Hash = ''; AHash = '' }) })
            $rows = @(Get-HUBackupInventory -Folder $f -TenantKey '__MUSTER__')
            $rows.Count | Should -Be 1
            $rows[0].Name | Should -Be '7-Zip'
            $rows[0].PSObject.Properties['Error'] | Should -BeNullOrEmpty
            Remove-Item -LiteralPath $f -Recurse -Force
        }
    }
}
