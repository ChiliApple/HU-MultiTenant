#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer die Muster-Bibliothek (Core\HU.Muster.psm1, 2.5.1): Pakete, Namenskatalog, Uebernahme des
    bisherigen Musters, Vergleich mit Teilpaketen - ohne Netzwerk.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.EntraRestore.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Muster.psm1') -Force -DisableNameChecking
    Mock -ModuleName HU.Muster Write-HULog { }
    # die bisherigen Tests laufen ohne mitgelieferte Pakete (eigener Describe-Block weiter unten)
    $script:BuiltinReal = Get-HUMusterBuiltinRoot
    Set-HUMusterBuiltinRoot (Join-Path ([IO.Path]::GetTempPath()) 'HU-MUL-keine-mitgelieferten')

    # Backup-Stand: CA mit Gruppe, Ort, Benutzer; Compliance; Ort, Filter, Bereichsmarkierung, Staerke (nur im Index)
    $script:MkStand = {
        param([string]$Base, [string]$Tenant, [string]$Name, [string]$CaName = '201 - MFA', [bool]$PwReq = $true)
        $d = Join-Path (Join-Path $Base $Tenant) $Name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $ca = [pscustomobject]@{ id = 'ca1'; displayName = $CaName; state = 'enabled'
            conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('aaaaaaaa-0000-0000-0000-000000000001'); excludeUsers = @('bbbbbbbb-0000-0000-0000-000000000001') }
                locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('dddddddd-0000-0000-0000-000000000001') } }
            grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @(); authenticationStrength = [pscustomobject]@{ id = '99999999-0000-0000-0000-000000000009' } } }
        $cmp = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; id = 'c1'; displayName = 'Win Compliance'; passwordRequired = $PwReq; roleScopeTagIds = @('0', '7') }
        $loc = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'dddddddd-0000-0000-0000-000000000001'; displayName = 'Standortnetz'; isTrusted = $true; ipRanges = @() }
        foreach ($x in @(@('Conditional Access', 'ca.json', $ca), @('Compliance', 'c.json', $cmp), @('Benannter Ort', 'l.json', $loc))) {
            New-Item -ItemType Directory -Path (Join-Path $d $x[0]) -Force | Out-Null
            Write-HUBackupJson (Join-Path $d "$($x[0])\$($x[1])") $x[2]
        }
        $items = @(
            [pscustomobject]@{ Typ = 'Conditional Access'; Name = $CaName; Id = 'ca1'; File = 'Conditional Access\ca.json' }
            [pscustomobject]@{ Typ = 'Compliance'; Name = 'Win Compliance'; Id = 'c1'; File = 'Compliance\c.json' }
            [pscustomobject]@{ Typ = 'Benannter Ort'; Name = 'Standortnetz'; Id = 'dddddddd-0000-0000-0000-000000000001'; File = 'Benannter Ort\l.json' }
            [pscustomobject]@{ Typ = 'Bereichsmarkierung'; Name = 'Verwaltung'; Id = '7'; File = '' }
            [pscustomobject]@{ Typ = 'Authentifizierungsstaerke'; Name = 'Phishing-resistent eigen'; Id = '99999999-0000-0000-0000-000000000009'; File = '' }
            [pscustomobject]@{ Typ = 'App'; Name = '7-Zip'; Id = 'a1'; File = '' }
        )
        Write-HUBackupJson (Join-Path $d 'index.json') ([pscustomobject]@{ Tenant = $Tenant; Errors = 0; Complete = $true; FailedTypes = @(); Items = $items })
        return $d
    }
    $script:NewBase = {
        $b = Join-Path ([IO.Path]::GetTempPath()) ("HU-MUL-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $b -Force | Out-Null
        return $b
    }
}

Describe 'Schlagwoerter' {
    It 'trennt an Komma, Strichpunkt und Leerzeichen, # vorne weg, doppelte einmal' {
        @(ConvertTo-HUMusterTags '#Pflicht, empfohlen;pflicht  P1') -join '|' | Should -Be 'Pflicht|empfohlen|P1'
        @(ConvertTo-HUMusterTags '').Count | Should -Be 0
    }
}

Describe 'Pakete anlegen, bearbeiten, loeschen' {
    BeforeAll {
        $script:B = & $script:NewBase
        $script:S = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:B } }
        $script:S1 = & $script:MkStand $script:B 'T1' '2026-10-20_080000'
        $script:S2 = & $script:MkStand $script:B 'T2' '2026-10-21_080000' '202 - Schueler MFA' $false
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { if ($Endpoint -like '/groups/aaaaaaaa*') { return [pscustomobject]@{ displayName = 'Lehrkraefte' } }; throw 'unerwartet' }
    }
    AfterAll { Remove-Item -LiteralPath $script:B -Recurse -Force -ErrorAction SilentlyContinue }

    It 'gemischtes Paket: Herkunft je Eintrag, doppelte weg, Namenskatalog ohne Benutzer' {
        $items = @(Get-HUMusterStandItems $script:S1 'T1' | Where-Object Typ -eq 'Conditional Access') +
                 @(Get-HUMusterStandItems $script:S2 'T2' | Where-Object { $_.Typ -in 'Conditional Access', 'Compliance' }) +
                 @(Get-HUMusterStandItems $script:S1 'T1' | Where-Object Typ -eq 'Compliance')
        $r = Save-HUMusterPackage -Settings $script:S -Title 'CA Grundschutz' -Category 'Conditional Access' -Tags @('#Pflicht', 'P1') -Note 'Test' -Items $items -ResolveGroups -Now ([datetime]'2026-10-25 09:00')
        $p = $r.Package
        $p.Count | Should -Be 3
        @($r.Skipped) | Should -Be @('Compliance: Win Compliance')
        $p.Sources -join ',' | Should -Be 'T1,T2'
        $p.TagText | Should -Be '#Pflicht #P1'
        $p.Complete | Should -BeFalse
        @($p.Items | Where-Object Typ -eq 'Compliance')[0].Source | Should -Be 'T2'
        $cat = @((Get-Content -LiteralPath (Join-Path $p.Folder 'names.json') -Raw | ConvertFrom-Json).Items)
        @($cat | Where-Object Art -eq 'Gruppe')[0].Name | Should -Be 'Lehrkraefte'
        @($cat | Where-Object Art -eq 'Benannter Ort')[0].Name | Should -Be 'Standortnetz'
        @($cat | Where-Object Art -eq 'Bereichsmarkierung')[0].Name | Should -Be 'Verwaltung'
        @($cat | Where-Object Art -eq 'Authentifizierungsstaerke')[0].Name | Should -Be 'Phishing-resistent eigen'
        @($cat | Where-Object Art -eq 'Benutzer').Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $p.Folder 'names.json') -Raw) | Should -Not -Match 'bbbbbbbb'
        Resolve-HUMusterName $p.Folder 'Benannter Ort' 'DDDDDDDD-0000-0000-0000-000000000001' | Should -Be 'Standortnetz'
        (Get-HUMusterTagNames @($p.Folder) 'T2')['7'] | Should -Be 'Verwaltung'
        (Get-HUMusterTagNames @($p.Folder) 'T1').Count | Should -Be 0
    }
    It 'gleicher Titel nur einmal, Kategorie muss bekannt sein, leer geht nicht' {
        $items = @(Get-HUMusterStandItems $script:S1 'T1' | Select-Object -First 1)
        { Save-HUMusterPackage -Settings $script:S -Title 'ca grundschutz ' -Category 'Conditional Access' -Items $items } | Should -Throw '*schon ein Paket*'
        { Save-HUMusterPackage -Settings $script:S -Title 'X' -Category 'Unbekannt' -Items $items } | Should -Throw '*Kategorie*'
        { Save-HUMusterPackage -Settings $script:S -Title ' ' -Items $items } | Should -Throw '*Namen*'
    }
    It 'Bestand des Pakets wie ein Backup-Stand, je Zeile Herkunft und Paket' {
        $p = @(Get-HUMusterPackages $script:S | Where-Object Title -eq 'CA Grundschutz')[0]
        $rows = @(Get-HUMusterInventory @($p))
        $rows.Count | Should -Be 3
        @($rows | Where-Object Name -eq '202 - Schueler MFA')[0].Origin | Should -Be 'T2'
        @($rows | Where-Object Name -eq '201 - MFA')[0].Origin | Should -Be 'T1'
        @($rows | ForEach-Object { $_.Tenant } | Sort-Object -Unique) | Should -Be @('__MUSTER__')
        $rows[0].Paket | Should -Be 'CA Grundschutz'
    }
    It 'bearbeiten behaelt Id und Erstellt, ersetzt Eintraege; duplizieren ueber die Eintraege' {
        $p = @(Get-HUMusterPackages $script:S | Where-Object Title -eq 'CA Grundschutz')[0]
        $items = @(Get-HUMusterPackageItems $p | Where-Object Typ -eq 'Conditional Access')
        $r = Save-HUMusterPackage -Settings $script:S -Id $p.Id -Title 'CA Grundschutz' -Category 'Conditional Access' -Items $items -Now ([datetime]'2026-10-25 10:00')
        $r.Package.Id | Should -Be $p.Id
        $r.Package.Count | Should -Be 2
        $r.Package.Created | Should -Be $p.Created
        $r.Package.Changed | Should -Be '2026-10-25T10:00:00'
        @(Get-ChildItem -LiteralPath (Get-HUMusterPkgRoot $script:S) -Directory | Where-Object { $_.Name -like '_*' }).Count | Should -Be 0
        $d = Save-HUMusterPackage -Settings $script:S -Title 'CA Grundschutz (Kopie)' -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $r.Package)
        $d.Package.Id | Should -Not -Be $p.Id
        $d.Package.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $d.Package.Folder 'names.json') | Should -BeTrue
    }
    It 'Gesamtstand aus einem Backup-Stand; loeschen verschiebt in den Papierkorb' {
        $g = (New-HUMusterPackageFromStand -Settings $script:S -Folder $script:S1 -TenantKey 'T1' -Title 'Gesamtstand T1').Package
        $g.Complete | Should -BeTrue
        $g.Category | Should -Be 'Gesamtstand'
        $g.Count | Should -Be 6
        { New-HUMusterPackageFromStand -Settings $script:S -Folder $script:S1 -TenantKey 'T9' -Title 'Falsch' } | Should -Throw '*gehoert zu Tenant*'
        Remove-HUMusterPackage $script:S $g.Id
        @(Get-HUMusterPackages $script:S | Where-Object Id -eq $g.Id).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path (Get-HUMusterRoot $script:S) 'papierkorb') -Directory).Count | Should -Be 1
        Get-HUMusterPackage $script:S '..\x' | Should -BeNullOrEmpty
    }
    It 'Auswahl: Titel, Ordner, Teilpaket oder Gesamtstand' {
        $all = @(Get-HUMusterPackages $script:S)
        $sel = Get-HUMusterSelection $script:S @($all[0].Id, 'gibt-es-nicht')
        $sel.Packages.Count | Should -Be 1
        $sel.Label | Should -BeLike 'Muster: *'
        $sel.Complete | Should -BeFalse
        Get-HUMusterSelection $script:S @('nix') | Should -BeNullOrEmpty
    }
}

Describe 'Bisheriges Muster wird einmalig Paket' {
    It 'Gesamtstand-Paket aus _Muster\aktuell, danach nicht noch einmal' {
        $b = & $script:NewBase
        $s = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $b } }
        $st = & $script:MkStand $b 'T1' '2026-10-23_120500'
        Save-HUMuster -Settings $s -Folder $st -TenantKey 'T1' | Out-Null
        $p = @(Get-HUMusterPackages $s)
        $p.Count | Should -Be 1
        $p[0].Title | Should -Be 'Gesamtstand T1 23.10.2026 (bisheriges Muster)'
        $p[0].Complete | Should -BeTrue
        $p[0].Items[0].Stand | Should -Be '2026-10-23_120500'
        Remove-HUMusterPackage $s $p[0].Id
        @(Get-HUMusterPackages $s).Count | Should -Be 0
        Remove-Item -LiteralPath $b -Recurse -Force
    }
}

Describe 'Vergleich mit Teilpaketen' {
    It 'was nicht im Teilpaket ist, zaehlt nicht als Abweichung; Gesamtstand schon' {
        $mk = '__MUSTER__'
        $row = { param($t, $typ, $n, $h) [pscustomobject]@{ Tenant = $t; Typ = $typ; Name = $n; Id = 'x'; Hash = $h; Copy = 'generic'; Info = '' } }
        $rows = @(
            (& $row $mk 'Conditional Access' '201 - MFA' 'h1'), (& $row 'T1' 'Conditional Access' '201 - MFA' 'h1'), (& $row 'T2' 'Conditional Access' '201 - MFA' 'h2'),
            (& $row 'T1' 'Konfiguration' 'Nur in Tenants' 'k1'), (& $row 'T2' 'Konfiguration' 'Nur in Tenants' 'k1'),
            (& $row 'T1' 'Konfiguration' 'Nur in T1' 'z1')
        )
        $keys = @($mk, 'T1', 'T2')
        $p = @(Get-HUMusterMatrix $rows $keys -Partial)
        $ca = @($p | Where-Object Name -eq '201 - MFA')[0]
        $ca.NotInPkg | Should -BeFalse
        $ca.Diff | Should -BeTrue
        $both = @($p | Where-Object Name -eq 'Nur in Tenants')[0]
        $both.NotInPkg | Should -BeTrue
        $both.Diff | Should -BeFalse
        @($both.Missing) -contains $mk | Should -BeFalse
        $one = @($p | Where-Object Name -eq 'Nur in T1')[0]
        $one.Diff | Should -BeTrue
        @($one.Missing) | Should -Be @('T2')
        # Gesamtstand: fehlt im Muster = Abweichung
        $full = @(Get-HUMusterMatrix $rows $keys)
        @($full | Where-Object Name -eq 'Nur in Tenants')[0].Diff | Should -BeTrue
    }
}

Describe 'Vergleich: CA aus dem Muster mit Werten aus dem Ziel' {
    BeforeAll {
        $script:CaObj = {
            param([string]$State, [string[]]$Bg, [string[]]$Roles, [string]$Ctl = 'mfa', [bool]$Rollen = $false)
            $o = [pscustomobject]@{ displayName = '100 - Admin'; state = $State
                conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeUsers = @('All'); excludeUsers = @($Bg); excludeRoles = @($Roles) } }
                grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @($Ctl) } }
            if ($Rollen) { $o | Add-Member -NotePropertyName huRollen -NotePropertyValue 'alleEingebautenAusnehmen' }
            $o
        }
        $script:CaRow = { param($t, $o, $h) [pscustomobject]@{ Tenant = $t; Typ = 'Conditional Access'; Name = '100 - Admin'; Id = 'x'; Hash = $h; Copy = ''; Info = ''; Obj = $o } }
    }
    It 'nur Status, Notfallkonten und Rollen (huRollen) anders -> nicht abweichend' {
        $mk = '__MUSTER__'
        $r1 = '11111111-0000-0000-0000-000000000001'; $r2 = '22222222-0000-0000-0000-000000000002'; $bg = 'bbbbbbbb-0000-0000-0000-000000000001'
        $rows = @(
            (& $script:CaRow $mk (& $script:CaObj 'enabledForReportingButNotEnforced' @() @() -Rollen $true) 'hm'),
            (& $script:CaRow 'T1' (& $script:CaObj 'enabled' @($bg) @($r1, $r2)) 'ht'),
            (& $script:CaRow 'T2' (& $script:CaObj 'enabled' @($bg) @($r1, $r2)) 'ht')
        )
        $m = @(Get-HUMusterMatrix $rows @($mk, 'T1', 'T2'))[0]
        $m.Diff | Should -BeFalse
        $m.Status | Should -BeLike 'ueberall (wie Muster*'
    }
    It 'echte Abweichung (anderes Steuerelement) bleibt abweichend' {
        $mk = '__MUSTER__'
        $rows = @(
            (& $script:CaRow $mk (& $script:CaObj 'enabledForReportingButNotEnforced' @() @() -Rollen $true) 'hm'),
            (& $script:CaRow 'T1' (& $script:CaObj 'enabled' @() @() 'block') 'ht')
        )
        @(Get-HUMusterMatrix $rows @($mk, 'T1'))[0].Diff | Should -BeTrue
    }
    It 'Tenants untereinander verschieden -> abweichend' {
        $mk = '__MUSTER__'
        $rows = @(
            (& $script:CaRow $mk (& $script:CaObj 'enabledForReportingButNotEnforced' @() @()) 'hm'),
            (& $script:CaRow 'T1' (& $script:CaObj 'enabled' @() @()) 'h1'),
            (& $script:CaRow 'T2' (& $script:CaObj 'enabled' @() @() 'block') 'h2')
        )
        @(Get-HUMusterMatrix $rows @($mk, 'T1', 'T2'))[0].Diff | Should -BeTrue
    }
    It 'Rollen ohne huRollen zaehlen weiter' {
        $mk = '__MUSTER__'
        $rows = @(
            (& $script:CaRow $mk (& $script:CaObj 'enabledForReportingButNotEnforced' @() @('11111111-0000-0000-0000-000000000001')) 'hm'),
            (& $script:CaRow 'T1' (& $script:CaObj 'enabled' @() @('11111111-0000-0000-0000-000000000001', '22222222-0000-0000-0000-000000000002')) 'ht')
        )
        @(Get-HUMusterMatrix $rows @($mk, 'T1'))[0].Diff | Should -BeTrue
    }
}

Describe 'Namenszuordnung mit Paketen' {
    It 'Gruppennamen aus dem Namenskatalog, mehrere Pakete, ohne Quell-Tenant' {
        $b = & $script:NewBase
        $s = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $b } }
        $st = & $script:MkStand $b 'T1' '2026-10-20_080000'
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { if ($Endpoint -like '/groups/aaaaaaaa*') { return [pscustomobject]@{ displayName = 'Lehrkraefte' } }; throw 'unerwartet' }
        $p1 = (Save-HUMusterPackage -Settings $s -Title 'P1' -Category 'Conditional Access' -Items @(Get-HUMusterStandItems $st 'T1' | Where-Object Typ -eq 'Conditional Access') -ResolveGroups).Package
        $p2 = (Save-HUMusterPackage -Settings $s -Title 'P2' -Category 'Compliance' -Items @(Get-HUMusterStandItems $st 'T1' | Where-Object Typ -eq 'Compliance')).Package
        # ab jetzt darf der Quell-Tenant nicht mehr gefragt werden
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { throw 'Quell-Tenant gefragt' }
        Mock -ModuleName HU.Muster Get-HUSecBaseline { $null }
        Mock -ModuleName HU.Muster Test-HUEntraBreakGlass { [pscustomobject]@{ Ok = $true; Text = 'ok' } }
        Mock -ModuleName HU.Muster Get-HUIntuneGraphAll {
            if ($Endpoint -like '/groups?*') { return @([pscustomobject]@{ id = 'g'; displayName = 'Lehrkraefte' }) }
            if ($Endpoint -like '/deviceManagement/roleScopeTags*') { return @([pscustomobject]@{ id = '3'; displayName = 'verwaltung' }) }
            return @()
        }
        $rows = @(Get-HUNameMap -Settings $s -Folder @($p1.Folder, $p2.Folder) -Targets @('Z1') -Names @{ Z1 = 'Ziel' })
        $g = @($rows | Where-Object Art -eq 'Gruppe')[0]
        $g.Name | Should -Be 'Lehrkraefte'
        $g.Ziel | Should -Be 'ok'
        @($rows | Where-Object Art -eq 'Bereichsmarkierung')[0].Ziel | Should -Be 'ok'
        @($rows | Where-Object Art -eq 'Benannter Ort')[0].Name | Should -Be 'Standortnetz'
        Remove-Item -LiteralPath $b -Recurse -Force
    }
}

Describe 'Review 2.5.1: mehrere Pakete, gleiche Tag-Ids, Uebernahme mit fehlender Datei' {
    BeforeAll {
        $script:B2 = & $script:NewBase
        $script:S2s = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:B2 } }
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { throw 'kein Netz' }
    }
    AfterAll { Remove-Item -LiteralPath $script:B2 -Recurse -Force -ErrorAction SilentlyContinue }

    It 'gleicher Eintrag in zwei gewaehlten Paketen: nur einmal im Bestand (erstes Paket gewinnt)' {
        $st = & $script:MkStand $script:B2 'T1' '2026-10-20_080000'
        $a = (Save-HUMusterPackage -Settings $script:S2s -Title 'A' -Category 'Compliance' -Items @(Get-HUMusterStandItems $st 'T1' | Where-Object Typ -eq 'Compliance')).Package
        $g = (New-HUMusterPackageFromStand -Settings $script:S2s -Folder $st -TenantKey 'T1' -Title 'G').Package
        $rows = @(Get-HUMusterInventory @($a, $g))
        @($rows | Where-Object Name -eq 'Win Compliance').Count | Should -Be 1
        @($rows | Where-Object Name -eq 'Win Compliance')[0].Paket | Should -Be 'A'
        $m = @(Get-HUMusterMatrix $rows @('__MUSTER__', 'T1'))
        @($m | Where-Object Name -eq 'Win Compliance')[0].Dupe | Should -BeFalse
    }
    It 'Bereichsmarkierung "7" aus zwei Tenants mit verschiedenen Namen bleibt getrennt' {
        $s1 = & $script:MkStand $script:B2 'TA' '2026-10-21_080000'
        $s2 = & $script:MkStand $script:B2 'TB' '2026-10-21_090000' '205 - Andere CA'
        # im zweiten Stand heisst Tag 7 anders
        $ix = Get-Content -LiteralPath (Join-Path $s2 'index.json') -Raw | ConvertFrom-Json
        @($ix.Items | Where-Object Typ -eq 'Bereichsmarkierung')[0].Name = 'Bibliothek'
        Write-HUBackupJson (Join-Path $s2 'index.json') $ix
        $c2 = Join-Path $s2 'Compliance\c.json'
        $o = Get-Content -LiteralPath $c2 -Raw | ConvertFrom-Json; $o.displayName = 'Win Compliance B'
        Write-HUBackupJson $c2 $o
        $items = @(Get-HUMusterStandItems $s1 'TA' | Where-Object Typ -eq 'Compliance') + @(Get-HUMusterStandItems $s2 'TB' | Where-Object Typ -eq 'Compliance' | ForEach-Object { $_.Name = 'Win Compliance B'; $_ })
        $p = (Save-HUMusterPackage -Settings $script:S2s -Title 'Gemischt' -Category 'Compliance' -Items $items).Package
        (Get-HUMusterTagNames @($p.Folder) 'TA')['7'] | Should -Be 'Verwaltung'
        (Get-HUMusterTagNames @($p.Folder) 'TB')['7'] | Should -Be 'Bibliothek'
        Resolve-HUMusterName $p.Folder 'Bereichsmarkierung' '7' 'TB' | Should -Be 'Bibliothek'
    }
    It 'bisheriges Muster mit fehlender Datei wird trotzdem uebernommen (Eintrag ausgelassen)' {
        $b = & $script:NewBase
        $s = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $b } }
        $st = & $script:MkStand $b 'T1' '2026-10-23_120500'
        Save-HUMuster -Settings $s -Folder $st -TenantKey 'T1' | Out-Null
        Remove-Item -LiteralPath (Join-Path (Join-Path (Get-HUMusterRoot $s) 'aktuell') 'Compliance\c.json') -Force
        $p = @(Get-HUMusterPackages $s)
        $p.Count | Should -Be 1
        @($p[0].Items | Where-Object Typ -eq 'Compliance').Count | Should -Be 0
        @($p[0].Items | Where-Object Typ -eq 'Conditional Access').Count | Should -Be 1
        Remove-Item -LiteralPath $b -Recurse -Force
    }
    It 'Bearbeiten: scheitert das Umschalten, bleibt der bisherige Stand' {
        $st = & $script:MkStand $script:B2 'T9' '2026-10-22_080000'
        $p = (Save-HUMusterPackage -Settings $script:S2s -Title 'Swap' -Category 'Compliance' -Items @(Get-HUMusterStandItems $st 'T9' | Where-Object Typ -eq 'Compliance')).Package
        Mock -ModuleName HU.Muster Move-Item { if ("$LiteralPath" -like '*_neu_*') { throw 'gesperrt' } else { Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force } }
        { Save-HUMusterPackage -Settings $script:S2s -Id $p.Id -Title 'Swap' -Category 'Compliance' -Items @(Get-HUMusterPackageItems $p) } | Should -Throw '*bisherige Stand bleibt*'
        (Get-HUMusterPackage $script:S2s $p.Id).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Get-HUMusterPkgRoot $script:S2s) -Directory | Where-Object { $_.Name -like '_*' }).Count | Should -Be 0
    }
}

Describe 'Papierkorb der Bibliothek' {
    It 'loeschen, auflisten, zurueckholen (Name mit Zusatz), endgueltig loeschen, nach Frist leeren' {
        $b = & $script:NewBase
        $s = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $b } }
        $st = & $script:MkStand $b 'T1' '2026-10-20_080000'
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { throw 'kein Netz' }
        $p = (Save-HUMusterPackage -Settings $s -Title 'P' -Category 'Compliance' -Items @(Get-HUMusterStandItems $st 'T1' | Where-Object Typ -eq 'Compliance')).Package
        Remove-HUMusterPackage $s $p.Id -Now ([datetime]'2026-07-01 10:00')
        $t = @(Get-HUMusterTrash $s)
        $t.Count | Should -Be 1
        $t[0].Title | Should -Be 'P'
        $t[0].DeletedAt | Should -Be ([datetime]'2026-07-01 10:00')
        # gleicher Name inzwischen neu angelegt -> Zusatz
        [void](Save-HUMusterPackage -Settings $s -Title 'P' -Category 'Compliance' -Items @(Get-HUMusterStandItems $st 'T1' | Where-Object Typ -eq 'Compliance'))
        $r = Restore-HUMusterPackage $s $t[0].Folder
        $r.Title | Should -Be 'P (wiederhergestellt)'
        @(Get-HUMusterPackages $s).Count | Should -Be 2
        @(Get-HUMusterTrash $s).Count | Should -Be 0
        { Restore-HUMusterPackage $s $st } | Should -Throw '*Papierkorb*'
        # 058 B6: '..' im Pfad wird nie als Papierkorb-Eintrag akzeptiert
        $bin = Get-HUMusterTrashRoot $s
        New-Item -ItemType Directory -Path (Join-Path $bin 'x') -Force | Out-Null
        { Remove-HUMusterTrashItem $s (Join-Path $bin '..') } | Should -Throw '*Papierkorb*'
        { Remove-HUMusterTrashItem $s (Join-Path (Join-Path $bin 'x') '..') } | Should -Throw '*Papierkorb*'
        Test-Path -LiteralPath (Get-HUMusterRoot $s) | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $bin 'x') -Force
        # Frist: alt weg, neu bleibt
        Remove-HUMusterPackage $s $r.Id -Now ([datetime]'2026-07-01 10:00')
        $q = @(Get-HUMusterPackages $s)[0]
        Remove-HUMusterPackage $s $q.Id -Now ([datetime]'2026-10-20 10:00')
        Clear-HUMusterTrash $s 90 ([datetime]'2026-10-25') | Should -Be 1
        @(Get-HUMusterTrash $s).Count | Should -Be 1
        Remove-HUMusterTrashItem $s (@(Get-HUMusterTrash $s)[0].Folder)
        @(Get-HUMusterTrash $s).Count | Should -Be 0
        Remove-Item -LiteralPath $b -Recurse -Force
    }
}

Describe 'Mitgelieferte Pakete (Programmordner Muster)' {
    BeforeAll {
        Set-HUMusterBuiltinRoot $script:BuiltinReal
        $script:Bb = & $script:NewBase
        $script:Sb = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:Bb }; tenants = @([pscustomobject]@{ key = 'T1' }, [pscustomobject]@{ key = 'T2' }) }
        Mock -ModuleName HU.Muster Invoke-HUIntuneGraph { throw 'kein Netz' }
    }
    AfterAll {
        Set-HUMusterBuiltinRoot (Join-Path ([IO.Path]::GetTempPath()) 'HU-MUL-keine-mitgelieferten')
        Remove-Item -LiteralPath $script:Bb -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'neun Pakete, schreibgeschuetzt, zuerst gelistet, Kategorie Mitgeliefert' {
        $all = @(Get-HUMusterPackages $script:Sb)
        $b = @($all | Where-Object BuiltIn)
        $b.Count | Should -Be 9
        @($b | Where-Object { $_.Category -ne 'Mitgeliefert' }).Count | Should -Be 0
        $all[0].BuiltIn | Should -BeTrue
        # Praxis-Set Schule ganz oben (Order 10), die anderen danach
        $all[0].Id | Should -Be 'mitgeliefert-ca-schule-praxis'
        @($b | ForEach-Object { $_.CopyCategory } | Sort-Object -Unique) -join '|' | Should -Be 'Compliance|Conditional Access|Entra-Grundschutz'
        foreach ($p in $b) { $p.Count | Should -BeGreaterThan 0; @($p.Learn).Count | Should -BeGreaterThan 0; $p.Sources -join '' | Should -Be 'mitgeliefert' }
    }
    It 'jeder Eintrag lesbar: Datei da, Name = displayName, keine Benutzer/Gruppen/Orte mit Kennung' {
        $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        foreach ($p in @(Get-HUMusterBuiltinPackages)) {
            # Orte des Pakets selbst (mitgeliefert, Platzhalter-Kennung) duerfen in den Richtlinien stehen - sonst keine Kennungen
            $own = @($p.Items | Where-Object { $_.Typ -eq 'Benannter Ort' } | ForEach-Object { "$($_.Id)".ToLowerInvariant() })
            foreach ($it in @($p.Items)) {
                "$($it.File)" | Should -Not -Match '[^A-Za-z0-9_./-]'
                $o = Read-HUBackupJson (Join-Path $p.Folder $it.File)
                if ($it.Typ -ne 'Entra-Einstellung') { "$($o.displayName)" | Should -Be "$($it.Name)" }
                if ($it.Typ -eq 'Benannter Ort') { "$($o.'@odata.type')" | Should -Be '#microsoft.graph.countryNamedLocation' }
                if ($it.Typ -eq 'Conditional Access') {
                    "$($o.state)" | Should -BeIn @('enabledForReportingButNotEnforced', 'disabled')
                    $u = $o.conditions.users
                    foreach ($f in 'includeUsers', 'excludeUsers', 'includeGroups', 'excludeGroups') { @($u.$f | Where-Object { "$_" -match $guid }).Count | Should -Be 0 }
                    @(@($o.conditions.locations.includeLocations) + @($o.conditions.locations.excludeLocations) | Where-Object { "$_" -match $guid -and $own -notcontains "$_".ToLowerInvariant() }).Count | Should -Be 0
                }
                if ($it.Typ -eq 'Compliance') {
                    # Uebertragen verlangt genau eine Aktion 'Als nicht konform markieren'
                    @($o.scheduledActionsForRule | ForEach-Object { $_.scheduledActionConfigurations } | Where-Object { $_.actionType -eq 'block' }).Count | Should -Be 1
                }
            }
        }
    }
    It 'Vergleich: Bestand mit Herkunft mitgeliefert, Teilpaket-Matrix' {
        $sel = Get-HUMusterSelection $script:Sb @('mitgeliefert-compliance-windows')
        $sel.Complete | Should -BeFalse
        $inv = @(Get-HUMusterInventory $sel.Packages)
        $inv.Count | Should -Be 1
        $inv[0].Origin | Should -Be 'mitgeliefert'
        $inv[0].Copy | Should -Be 'compliance'
        $inv[0].Hash | Should -Not -BeNullOrEmpty
    }
    It 'nicht bearbeitbar, nicht loeschbar; Kopie unter echter Kategorie bearbeitbar' {
        $p = Get-HUMusterPackage $script:Sb 'mitgeliefert-ca-grundschutz'
        $p.BuiltIn | Should -BeTrue
        { Save-HUMusterPackage -Settings $script:Sb -Id $p.Id -Title $p.Title -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $p) } | Should -Throw '*schreibgeschuetzt*'
        { Remove-HUMusterPackage $script:Sb $p.Id } | Should -Throw '*mitgeliefert*'
        $k = (Save-HUMusterPackage -Settings $script:Sb -Title "$($p.Title) (Kopie)" -Category $p.CopyCategory -Items @(Get-HUMusterPackageItems $p)).Package
        $k.BuiltIn | Should -BeFalse
        $k.Category | Should -Be 'Conditional Access'
        $k.Count | Should -Be $p.Count
        $k.Sources -join '' | Should -Be 'mitgeliefert'
        { Save-HUMusterPackage -Settings $script:Sb -Title $p.Title -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $p) } | Should -Throw '*schon ein Paket*'
    }
    It 'Quellen der mitgelieferten Pakete: vollstaendige https-Adressen auf Microsoft Learn (vom Link-Pruefer gefunden)' {
        $urls = @(Get-HUMusterBuiltinPackages | ForEach-Object { @($_.Learn) } | Sort-Object -Unique)
        $urls.Count | Should -BeGreaterThan 5
        @($urls | Where-Object { $_ -notmatch '^https://learn\.microsoft\.com/[a-z0-9/._-]+$' }).Count | Should -Be 0
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $found = @(& (Join-Path $root '.github\scripts\Test-HULinks.ps1') -Root (Join-Path $root 'Muster') -Offline -PassThru | ForEach-Object Url)
        foreach ($u in $urls) { $found | Should -Contain $u }
    }
    It 'Notiz der mitgelieferten Pakete: kurze Punkte je Zeile' {
        foreach ($p in @(Get-HUMusterBuiltinPackages)) { @("$($p.Note)" -split "`n" | Where-Object { $_.Length -gt 220 }).Count | Should -Be 0 -Because $p.Title }
    }
    It 'Namen benannter Orte aus dem Paket (names.json und index.json)' {
        $p = Get-HUMusterPackage $script:Sb 'mitgeliefert-ca-schule-praxis'
        $h = Get-HUMusterLocationNames @($p.Folder)
        $h.Count | Should -Be 3
        @($h.Values) -contains 'Erlaubte Standorte ohne MFA' | Should -BeTrue
        $g = Get-HUMusterPackage $script:Sb 'mitgeliefert-ca-geoblock-admins'
        (Get-HUMusterLocationNames @($g.Folder))['a1b2c3d4-0903-4000-8000-000000000903'] | Should -Be 'Erlaubte Länder (Geoblock)'
        (Get-HUMusterLocationNames @('')).Count | Should -Be 0
    }
    It 'Praxis-Set Schule: Gruppen nur als Platzhalter (huGruppen), keine Konten' {
        $p = Get-HUMusterPackage $script:Sb 'mitgeliefert-ca-schule-praxis'
        $l = Get-HUMusterPackageItems $p | Where-Object { $_.Name -eq '201 - MFA Lehrer' }
        $o = Read-HUBackupJson (Join-Path $p.Folder $l.File)
        @($o.huGruppen | ForEach-Object { "$($_.feld):$($_.name)" }) -join '|' | Should -Be 'includeGroups:Lehrer|excludeGroups:Ausnahmen MFA Lehrer'
        @($o.conditions.users.includeGroups).Count | Should -Be 0
    }
    It 'Namen nachschlagen: mitgeliefert -> erster Tenant, sonst unveraendert' {
        Test-HUMusterBuiltinSource 'mitgeliefert' | Should -BeTrue
        Get-HUMusterResolveKey $script:Sb 'mitgeliefert' | Should -Be 'T1'
        Get-HUMusterResolveKey $script:Sb 'T2' | Should -Be 'T2'
        Get-HUMusterResolveKey ([pscustomobject]@{ tenants = @() }) 'mitgeliefert' | Should -Be ''
    }
}
