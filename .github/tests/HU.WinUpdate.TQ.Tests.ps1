#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatz-Tests (Test und Qualitaet, Pruefung 2.6.4): schliessen Luecken in HU.WinUpdate.Tests.ps1.
    Pester 5, PS-5.1-tauglich (kein ?:, ??, && ; keine PS-7-Syntax). Ablage: .github\tests\HU.WinUpdate.TQ.Tests.ps1
.NOTES
    Die Befund-Faelle (F-Nummer im Namen) sind seit den 074-Fixes gruen und laufen normal mit. Nichts davon braucht Graph, WPF oder Netz (alles gemockt).
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.WinUpdate.psm1') -Force -DisableNameChecking
    # reine Hilfsfunktionen aus der UI-Datei per AST holen (ohne WPF)
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Functions\UI-WinUpdates.ps1'), [ref]$null, [ref]$null)
    foreach ($n in 'ConvertTo-HUWuDataTable', 'Get-HUWuCell') {
        $f = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true)
        . ([scriptblock]::Create($f.Extent.Text))
    }
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('HU-WU-TQ-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{}
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'TQ: Get-HUWuDate (Graph-Zeiten, PS 5.1 Text / PS 7 DateTime)' {
    It 'ISO mit Z, ohne Z, DateTime-Objekt: ergibt DateTime; Kauderwelsch, leer, Jahr <2000: $null' {
        InModuleScope HU.WinUpdate {
            (Get-HUWuDate '2026-10-28T00:00:00Z').ToUniversalTime().Year | Should -Be 2026
            (Get-HUWuDate '2026-10-28T10:30:00').Hour | Should -Be 10
            (Get-HUWuDate ([datetime]'2026-10-28 13:00')).Day | Should -Be 28    # PS 7: ConvertFrom-Json liefert DateTime
            Get-HUWuDate 'x' | Should -BeNullOrEmpty
            Get-HUWuDate '' | Should -BeNullOrEmpty
            Get-HUWuDate $null | Should -BeNullOrEmpty
            Get-HUWuDate '0001-01-01T00:00:00Z' | Should -BeNullOrEmpty
        }
    }
    It 'unabhaengig von der Thread-Kultur (de-AT, en-US)' {
        InModuleScope HU.WinUpdate {
            $old = [Threading.Thread]::CurrentThread.CurrentCulture
            try {
                foreach ($c in 'de-AT', 'en-US') {
                    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]$c
                    (Get-HUWuDate '2026-03-04T00:00:00Z').ToUniversalTime().Month | Should -Be 3
                    (Get-HUWuDate ([datetime]'2026-03-04')).Month | Should -Be 3
                }
            } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
        }
    }
}

Describe 'TQ: ConvertTo-HUWuDataTable (Sortierung im DataGrid)' {
    It 'Spalten nur mit ganzen Zahlen sind Int32 und sortieren numerisch (9 < 12 < 100)' {
        $rows = @([pscustomobject]@{ T = 'x'; G = 100 }, [pscustomobject]@{ T = 'y'; G = 9 }, [pscustomobject]@{ T = 'z'; G = 12 })
        $dt = ConvertTo-HUWuDataTable $rows
        $dt.Columns['G'].DataType | Should -Be ([int])
        $dt.DefaultView.Sort = 'G ASC'
        (@($dt.DefaultView | ForEach-Object { $_['G'] }) -join ',') | Should -Be '9,12,100'
    }
    It 'double (Measure-Object -Sum) wird Int32; Leerwerte werden DBNull' {
        $dt = ConvertTo-HUWuDataTable @([pscustomobject]@{ S = [double]3; E = '' }, [pscustomobject]@{ S = [double]12; E = $null })
        $dt.Columns['S'].DataType | Should -Be ([int])
        $dt.Rows[1]['E'] | Should -Be ([DBNull]::Value)
    }
    It 'keine Zeilen: leere DataTable (nicht aufgerollt); eine Zeile: DataTable' {
        $a = ConvertTo-HUWuDataTable @(); $a.GetType().Name | Should -Be 'DataTable'; $a.Rows.Count | Should -Be 0
        $b = ConvertTo-HUWuDataTable @([pscustomobject]@{ a = 1 }); $b.GetType().Name | Should -Be 'DataTable'; $b.Rows.Count | Should -Be 1
    }
    It 'gemischte Spalte (Zahl + Text) bleibt Text; Text wird nicht verloren' {
        $dt = ConvertTo-HUWuDataTable @([pscustomobject]@{ M = 5 }, [pscustomobject]@{ M = '?' })
        $dt.Columns['M'].DataType | Should -Be ([string])
        $dt.Rows[1]['M'] | Should -Be '?'
    }
    It 'Get-HUWuCell: DataRowView und PSObject, fehlende Spalte = $null' {
        $dt = ConvertTo-HUWuDataTable @([pscustomobject]@{ Key = 'k1'; N = 'a' })
        Get-HUWuCell $dt.DefaultView[0] 'Key' | Should -Be 'k1'
        Get-HUWuCell $dt.DefaultView[0] 'Gibtsnicht' | Should -BeNullOrEmpty
        Get-HUWuCell ([pscustomobject]@{ Key = 'k2' }) 'Key' | Should -Be 'k2'
    }
    # Befund F2: Spaltennamen = Tenant-Anzeigenamen. WPF bindet AutoGenerate-Spalten ueber einen Property-Pfad: . [ ] ( ) / , sind Sonderzeichen
    It 'F2: Tenant-Spaltennamen ohne WPF-Pfad-Sonderzeichen (Schule St. Test (A))' {
        $inv = @([pscustomobject]@{ Tenant = 'a'; Catalog = @{}; Devices = @([pscustomobject]@{ Version = 'Windows 11'; BuildNr = 26200; Patchstand = 'aktuell'; Tenant = 'a' }) })
        $rows = @(Get-HUWuMatrix $inv @{ a = 'HAK St. Test (Sued) [1]' })
        $dt = ConvertTo-HUWuDataTable $rows
        @($dt.Columns.ColumnName | Where-Object { $_ -match '[\.\[\]\(\)/,]' }) | Should -BeNullOrEmpty
    }
}

Describe 'TQ: Get-HUWuMatrix / Get-HUWuDriverMatrix' {
    BeforeAll {
        $script:mk = { param($t, $n, $ok) [pscustomobject]@{ Tenant = $t; Catalog = @{}; Errors = @(); Policies = @(); Drivers = @()
                Devices = @(1..$n | ForEach-Object { [pscustomobject]@{ Version = 'Windows 11 25H2'; BuildNr = 26200; Patchstand = $(if ($_ -le $ok) { 'aktuell' } else { 'zurueck' }); Tenant = $t } }) } }
    }
    It 'ohne Inventare / Tenant ohne Geraete: leeres Ergebnis ohne Fehler' {
        @(Get-HUWuMatrix @()).Count | Should -Be 0
        @(Get-HUWuMatrix @([pscustomobject]@{ Tenant = 'a'; Devices = @(); Catalog = @{} })).Count | Should -Be 0
        @(Get-HUWuDriverMatrix @()).Count | Should -Be 0
    }
    It 'eine Version, 3 Tenants: Summen und Prozent stimmen (12+9+100, 5+9+1 aktuell)' {
        $r = @(Get-HUWuMatrix @((& $script:mk 'a' 12 5), (& $script:mk 'b' 9 9), (& $script:mk 'c' 100 1)) @{ a = 'A'; b = 'B'; c = 'C' })
        $r.Count | Should -Be 1
        $r[0].Gesamt | Should -Be 121
        $r[0].'Aktuell %' | Should -Be 12
        $r[0].B | Should -Be '9 (9 aktuell)'
    }
    It 'F3: zwei Tenants mit gleichem Anzeigenamen behalten beide eine Spalte (kein stilles Ueberschreiben)' {
        $r = @(Get-HUWuMatrix @((& $script:mk 'a' 12 5), (& $script:mk 'b' 9 9)) @{ a = 'Schule X'; b = 'Schule X' })
        $spalten = @($r[0].PSObject.Properties.Name | Where-Object { $_ -like 'Schule X*' })
        $spalten.Count | Should -Be 2
    }
    It 'F3: Tenant-Anzeigename "Gesamt" ueberschreibt nicht die Summenspalte' {
        $r = @(Get-HUWuMatrix @((& $script:mk 'a' 12 5)) @{ a = 'Gesamt' })
        $r[0].Gesamt | Should -Be 12
        @($r[0].PSObject.Properties.Name | Where-Object { $_ -like 'Gesamt*' }).Count | Should -Be 2
    }
}

Describe 'TQ: Set-HUWuAssignment (assign ersetzt die ganze Liste)' {
    BeforeEach { $script:Calls = New-Object System.Collections.Generic.List[object] }
    It 'Lesen schlaegt fehl -> es wird NICHT geschrieben (sonst waere die Liste nur noch der neue Eintrag)' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll { throw 'Graph 429' }
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $null }
        { Set-HUWuAssignment -TenantKey 't' -Settings $script:Set -Art 'Update-Ring' -Id 'r1' -Add @([pscustomobject]@{ Kind = 'group'; GroupId = 'g9' }) } | Should -Throw
        Should -Invoke Invoke-HUIntuneGraph -ModuleName HU.WinUpdate -Times 0 -Exactly
    }
    It 'Gruppen-Id in anderer Schreibweise ersetzt das vorhandene Ziel (Count bleibt 1)' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll { @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'ABC-1' } }) }
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; B = $Body }); $null }
        (Set-HUWuAssignment -TenantKey 't' -Settings $script:Set -Art 'Update-Ring' -Id 'r1' -Add @([pscustomobject]@{ Kind = 'group'; GroupId = 'abc-1' })) | Should -Be 1
    }
    It 'alle Ziele entfernen: es wird eine LEERE Liste geschrieben (assignments = [])' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll { @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }) }
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; B = $Body }); $null }
        (Set-HUWuAssignment -TenantKey 't' -Settings $script:Set -Art 'Expedite' -Id 'e1' -RemoveKeys @('group|g1')) | Should -Be 0
        $post = @($script:Calls | Where-Object { $_.Ep -like '*/assign' })   # 074: vorher wird zusaetzlich der Stand gelesen (Sicherung)
        $post.Count | Should -Be 1
        @($post[0].B.assignments).Count | Should -Be 0
        ($post[0].B | ConvertTo-Json -Depth 5 -Compress) | Should -Match '"assignments":\[\]'
    }
    It 'Ausschluss und Alle Benutzer bekommen die richtigen @odata.type (Ring); Expedite: Alle Benutzer abgelehnt' {
        InModuleScope HU.WinUpdate {
            (ConvertTo-HUWuTarget ([pscustomobject]@{ Kind = 'exclude'; GroupId = 'g' }))['@odata.type'] | Should -Be '#microsoft.graph.exclusionGroupAssignmentTarget'
            (ConvertTo-HUWuTarget ([pscustomobject]@{ Kind = 'allUsers' }))['@odata.type'] | Should -Be '#microsoft.graph.allLicensedUsersAssignmentTarget'
            { ConvertTo-HUWuTarget ([pscustomobject]@{ Kind = 'quatsch' }) } | Should -Throw '*Unbekanntes Ziel*'
        }
        { Set-HUWuAssignment -TenantKey 't' -Settings $script:Set -Art 'Expedite' -Id 'e1' -Add @([pscustomobject]@{ Kind = 'allUsers' }) } | Should -Throw '*Geraetegruppen*'
    }
    It 'RemoveKeys: nicht vorhandener Schluessel ist ein stilles No-Op (Zahl bleibt gleich)' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll { @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }) }
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $null }
        (Set-HUWuAssignment -TenantKey 't' -Settings $script:Set -Art 'Update-Ring' -Id 'r1' -RemoveKeys @('group|gibtsnicht')) | Should -Be 1
    }
}

Describe 'TQ: Remove-HUWuProfile (loeschen)' {
    BeforeEach { $script:Calls = New-Object System.Collections.Generic.List[object] }
    It 'zugewiesener Ring: Fehler, KEIN DELETE, kein Sicherungsfile' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph {
            $script:Calls.Add("$Method $Endpoint")
            if ($Endpoint -like '*/assignments') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a1' }) } }
            [pscustomobject]@{ id = 'r1'; displayName = 'Ring' }
        }
        { Remove-HUWuProfile -TenantKey 't' -Settings $script:Set -Art 'Update-Ring' -Id 'r1' -BackupRoot $script:Tmp } | Should -Throw '*zugewiesen*'
        @($script:Calls | Where-Object { $_ -like 'DELETE*' }).Count | Should -Be 0
    }
    It 'Ring ohne Zuweisung: erst Sicherung (Datei mit id), dann DELETE' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph {
            $script:Calls.Add("$Method $Endpoint")
            if ($Endpoint -like '*/assignments') { return [pscustomobject]@{ value = @() } }
            if ($Method -eq 'DELETE') { return $null }
            [pscustomobject]@{ id = 'r1'; displayName = 'Ring' }
        }
        $f = Remove-HUWuProfile -TenantKey 't' -Settings $script:Set -Art 'Update-Ring' -Id 'r1' -BackupRoot $script:Tmp
        Test-Path -LiteralPath $f | Should -BeTrue
        (Get-Content -LiteralPath $f -Raw) | Should -Match '"id"'
        $script:Calls[-1] | Should -BeLike 'DELETE */deviceConfigurations/r1'
    }
    It 'Sicherung scheitert (Zielordner ist eine Datei) -> KEIN DELETE' {
        $blocker = Join-Path $script:Tmp 'blocker.txt'; Set-Content -LiteralPath $blocker -Value 'x'
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph {
            $script:Calls.Add("$Method $Endpoint")
            [pscustomobject]@{ id = 'f1'; displayName = 'Feature'; value = @() }
        }
        { Remove-HUWuProfile -TenantKey 't' -Settings $script:Set -Art 'Feature-Update' -Id 'f1' -BackupRoot $blocker } | Should -Throw
        @($script:Calls | Where-Object { $_ -like 'DELETE*' }).Count | Should -Be 0
    }
    It '074 B1: auch Expedite wird vor dem Loeschen frisch auf Zuweisungen geprueft; ohne Zuweisung wird geloescht' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph {
            $script:Calls.Add("$Method $Endpoint")
            if ($Endpoint -like '*/assignments') { return [pscustomobject]@{ value = @() } }
            [pscustomobject]@{ id = 'e1'; displayName = 'Exp' }
        }
        [void](Remove-HUWuProfile -TenantKey 't' -Settings $script:Set -Art 'Expedite' -Id 'e1' -BackupRoot $script:Tmp)
        @($script:Calls | Where-Object { $_ -like '*assignments*' }).Count | Should -Be 1
        @($script:Calls | Where-Object { $_ -like 'DELETE /deviceManagement/windowsQualityUpdateProfiles/e1' }).Count | Should -Be 1
    }
}

Describe 'TQ: Set-HUWuRingPause / Set-HUWuSettings' {
    BeforeEach { $script:Calls = New-Object System.Collections.Generic.List[object] }
    It 'pause / resume: PATCH nur mit dem einen Feld + @odata.type, Stand vorher gesichert' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ M = $Method; Ep = $Endpoint; B = $Body }); if ($Method -eq 'GET') { [pscustomobject]@{ id = 'r1' } } else { $null } }
        $f = Set-HUWuRingPause -TenantKey 't' -Settings $script:Set -Id 'r1' -What 'quality' -Action 'pause' -BackupRoot $script:Tmp
        Test-Path -LiteralPath $f | Should -BeTrue
        $p = $script:Calls | Where-Object { $_.M -eq 'PATCH' }
        $p.B.qualityUpdatesPaused | Should -BeTrue
        @($p.B.Keys | Where-Object { $_ -notin 'qualityUpdatesPaused', '@odata.type' }).Count | Should -Be 0
        [void](Set-HUWuRingPause -TenantKey 't' -Settings $script:Set -Id 'r1' -What 'feature' -Action 'resume' -BackupRoot $script:Tmp)
        ($script:Calls | Where-Object { $_.M -eq 'PATCH' })[-1].B.featureUpdatesPaused | Should -BeFalse
    }
    It 'extend: POST auf extendQualityUpdatesPause bzw. extendFeatureUpdatesPause, keine Sicherung' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ M = $Method; Ep = $Endpoint }); $null }
        Set-HUWuRingPause -TenantKey 't' -Settings $script:Set -Id 'r1' -What 'quality' -Action 'extend' | Should -Be ''
        Set-HUWuRingPause -TenantKey 't' -Settings $script:Set -Id 'r1' -What 'feature' -Action 'extend' | Should -Be ''
        $script:Calls[0].Ep | Should -BeLike '*/r1/extendQualityUpdatesPause'
        $script:Calls[1].Ep | Should -BeLike '*/r1/extendFeatureUpdatesPause'
        $script:Calls[0].M | Should -Be 'POST'
    }
    It 'Save-HUWuBefore: Dateiname ohne Sonderzeichen (Tenant-Key mit Leerzeichen/Slash)' {
        $f = Save-HUWuBefore 'Schule A/B' 'Update-Ring' ([pscustomobject]@{ id = 'x y' }) $script:Tmp
        (Split-Path $f -Leaf) | Should -Match '^[A-Za-z0-9_.-]+\.json$'
    }
}

Describe 'TQ: Neu anlegen (Bodies, Grenzen)' {
    BeforeEach { $script:Calls = New-Object System.Collections.Generic.List[object] }
    It 'Ring-Body: ungueltige Uhrzeit wird abgelehnt; H:mm wird zu HH:mm:ss.0000000; Bereichsgrenzen' {
        { New-HUWuRingBody -Name 'r' -QualityDeferral 3 -QualityDeadline 3 -FeatureDeadline 7 -Grace 2 -ActiveStart '25:00' -ActiveEnd '15:00' -UserPause $false } | Should -Throw '*ungueltig*'
        $b = New-HUWuRingBody -Name 'r' -QualityDeferral 3 -QualityDeadline 3 -FeatureDeadline 7 -Grace 2 -ActiveStart '7:00' -ActiveEnd '15:00' -UserPause $true
        $b.installationSchedule.activeHoursStart | Should -Be '07:00:00.0000000'
        $b.userPauseAccess | Should -Be 'enabled'
        $b.featureUpdatesDeferralPeriodInDays | Should -Be 0
        $b.GetType().Name | Should -Be 'Hashtable'      # Invoke-HUIntuneGraph verlangt [hashtable], kein [ordered]
        { New-HUWuRing -TenantKey 't' -Settings $script:Set -Name 'r' -QualityDeferral 31 } | Should -Throw
    }
    It 'Expedite: RebootDays 0..2, Body mit expeditedUpdateSettings; Rueckgabe = Id' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ Ep = $Endpoint; B = $Body }); [pscustomobject]@{ id = 'new1' } }
        New-HUWuExpedite -TenantKey 't' -Settings $script:Set -Name 'E' -Release '2026-10-14T00:00:00Z' -RebootDays 0 | Should -Be 'new1'
        $script:Calls[0].B.expeditedUpdateSettings.daysUntilForcedReboot | Should -Be 0
        $script:Calls[0].B.expeditedUpdateSettings.qualityUpdateRelease | Should -Be '2026-10-14T00:00:00Z'
        { New-HUWuExpedite -TenantKey 't' -Settings $script:Set -Name 'E' -Release 'x' -RebootDays 3 } | Should -Throw
    }
    It 'Treiber-Richtlinie: manuell hat KEIN deploymentDeferralInDays, automatisch schon' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ B = $Body }); [pscustomobject]@{ id = 'd1' } }
        [void](New-HUWuDriverProfile -TenantKey 't' -Settings $script:Set -Name 'D' -Approval manual -DeferDays 7)
        [void](New-HUWuDriverProfile -TenantKey 't' -Settings $script:Set -Name 'D' -Approval automatic -DeferDays 7)
        $script:Calls[0].B.ContainsKey('deploymentDeferralInDays') | Should -BeFalse
        $script:Calls[1].B.deploymentDeferralInDays | Should -Be 7
    }
    It 'Feature-Profil gestaffelt: Start/Ende als UTC-ISO, Intervall als Zahl; "sofort" ohne rolloutSettings' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Calls.Add([pscustomobject]@{ B = $Body }); [pscustomobject]@{ id = 'f1' } }
        [void](New-HUWuFeatureProfile -TenantKey 't' -Settings $script:Set -Name 'F' -Version '25H2')
        $script:Calls[0].B.ContainsKey('rolloutSettings') | Should -BeFalse
        [void](New-HUWuFeatureProfile -TenantKey 't' -Settings $script:Set -Name 'F' -Version '25H2' -Rollout @{ Mode = 'gradual'; Start = [datetime]'2026-11-02 08:00'; End = [datetime]'2026-11-20 08:00'; Interval = 7 })
        $r = $script:Calls[1].B.rolloutSettings
        $r.offerStartDateTimeInUTC | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        $r.offerIntervalInDays | Should -Be 7
        ([datetime]$r.offerEndDateTimeInUTC) | Should -BeGreaterThan ([datetime]$r.offerStartDateTimeInUTC)
    }
    It 'POST ohne Id in der Antwort: Rueckgabe ist leer (Aufrufer muss das als Fehler behandeln)' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $null }
        New-HUWuExpedite -TenantKey 't' -Settings $script:Set -Name 'E' -Release 'x' | Should -Be ''
    }
}

Describe 'TQ: Sichern / Importieren (Datei von aussen)' {
    BeforeAll {
        $script:W = { param($o, $n) $p = Join-Path $script:Tmp $n; [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($true)); $p }   # mit BOM wie der Windows-Editor
    }
    It 'falsches Format / kaputtes JSON: Fehler' {
        { Read-HUWuExportFile (& $script:W ([pscustomobject]@{ Format = 'Anderes' }) 'a.json') } | Should -Throw '*Format*'
        $p = Join-Path $script:Tmp 'b.json'; Set-Content -LiteralPath $p -Value '{ kaputt'
        { Read-HUWuExportFile $p } | Should -Throw
    }
    It 'unbekannte Art und leerer Name werden uebersprungen; @odata.type und roleScopeTagIds werden gesetzt (fremder Typ wird ueberschrieben)' {
        $doc = [pscustomobject]@{ Format = 'HU-WinUpdates'; FormatVersion = 1; Items = @(
                [pscustomobject]@{ Art = 'Update-Ring'; Name = 'R1'; Body = [pscustomobject]@{ displayName = 'R1'; '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; roleScopeTagIds = @('5') } }
                [pscustomobject]@{ Art = 'Unbekannt'; Name = 'X'; Body = [pscustomobject]@{} }
                [pscustomobject]@{ Art = 'Expedite'; Name = ''; Body = [pscustomobject]@{} }) }
        $r = @(Read-HUWuExportFile (& $script:W $doc 'c.json'))
        $r.Count | Should -Be 1
        $r[0].Body['@odata.type'] | Should -Be '#microsoft.graph.windowsUpdateForBusinessConfiguration'
        @($r[0].Body['roleScopeTagIds']) | Should -Be @('0')
    }
    It 'genau ein Eintrag (Items kein Array) und Umlaute im Namen bleiben erhalten' {
        $doc = [pscustomobject]@{ Format = 'HU-WinUpdates'; FormatVersion = 1; Items = [pscustomobject]@{ Art = 'Expedite'; Name = "Pr$([char]0xFC)fung $([char]0xC4)"; Body = [pscustomobject]@{ displayName = 'x' } } }
        $r = @(Read-HUWuExportFile (& $script:W $doc 'd.json'))
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be "Pr$([char]0xFC)fung $([char]0xC4)"
    }
    It 'F4: Verwaltungsfelder aus einer fremden/bearbeiteten Datei (id, assignments, createdDateTime) werden beim Lesen verworfen' {
        $doc = [pscustomobject]@{ Format = 'HU-WinUpdates'; FormatVersion = 1; Items = @([pscustomobject]@{ Art = 'Update-Ring'; Name = 'R'
                    Body = [pscustomobject]@{ displayName = 'R'; id = 'fremd'; createdDateTime = '2020-01-01T00:00:00Z'; assignments = @([pscustomobject]@{ target = 'x' }); qualityUpdatesPaused = $true } }) }
        $r = @(Read-HUWuExportFile (& $script:W $doc 'e.json'))
        $r[0].Body.ContainsKey('id') | Should -BeFalse
        $r[0].Body.ContainsKey('assignments') | Should -BeFalse
        $r[0].Body.ContainsKey('createdDateTime') | Should -BeFalse
    }
    It 'Export -> Datei -> Import: Ring mit verschachteltem installationSchedule bleibt gleich (JSON-Tiefe)' {
        $raw = [pscustomobject]@{ id = 'r1'; displayName = 'R'; qualityUpdatesPaused = $true; deadlineForQualityUpdatesInDays = 3
            installationSchedule = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsUpdateActiveHoursInstall'; activeHoursStart = '07:00:00.0000000'; activeHoursEnd = '15:00:00.0000000' } }
        $doc = New-HUWuExportDoc @([pscustomobject]@{ Art = 'Update-Ring'; Name = 'R'; Tenant = 't'; Raw = $raw }) @{ t = 'Schule' } ([datetime]'2026-10-28')
        $p = Join-Path $script:Tmp 'f.json'; [IO.File]::WriteAllText($p, ($doc | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        $r = @(Read-HUWuExportFile $p)
        $r[0].Body.installationSchedule.activeHoursStart | Should -Be '07:00:00.0000000'
        $r[0].Body.qualityUpdatesPaused | Should -BeFalse
        $r[0].Body.ContainsKey('id') | Should -BeFalse
    }
    It 'Export: gleicher Art+Name aus mehreren Tenants wird nur einmal gesichert; Eintrag ohne Raw wird ausgelassen' {
        $rows = @(
            [pscustomobject]@{ Art = 'Expedite'; Name = 'E'; Tenant = 'a'; Raw = [pscustomobject]@{ displayName = 'E' } }
            [pscustomobject]@{ Art = 'Expedite'; Name = 'E'; Tenant = 'b'; Raw = [pscustomobject]@{ displayName = 'E' } }
            [pscustomobject]@{ Art = 'Expedite'; Name = 'Ohne'; Tenant = 'a'; Raw = $null })
        $d = New-HUWuExportDoc $rows @{} ([datetime]'2026-10-28')
        @($d.Items).Count | Should -Be 1
    }
    It 'Feature-Update mit Zeitraum in der Vergangenheit verliert rolloutSettings; in der Zukunft bleibt er' {
        $past = [pscustomobject]@{ displayName = 'F'; rolloutSettings = [pscustomobject]@{ offerStartDateTimeInUTC = '2026-01-01T00:00:00Z' } }
        $fut = [pscustomobject]@{ displayName = 'F'; rolloutSettings = [pscustomobject]@{ offerStartDateTimeInUTC = '2026-12-01T00:00:00Z' } }
        (ConvertTo-HUWuExportBody 'Feature-Update' $past ([datetime]'2026-10-28')).ContainsKey('rolloutSettings') | Should -BeFalse
        (ConvertTo-HUWuExportBody 'Feature-Update' $fut ([datetime]'2026-10-28')).ContainsKey('rolloutSettings') | Should -BeTrue
    }
}

Describe 'TQ: Get-HUWuInventory (Fehlerpfade, alles gemockt)' {
    BeforeAll {
        $script:Ring = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsUpdateForBusinessConfiguration'; id = 'r1'; displayName = 'Ring A'; qualityUpdatesDeferralPeriodInDays = 3; assignments = @() }
    }
    It 'Geraete-Abfrage 403: Fehlertext "Berechtigung fehlt", Ringe werden trotzdem gelesen' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll {
            if ($Endpoint -like '*managedDevices*') { throw 'Graph GET: 403 Forbidden' }
            if ($Endpoint -like '*deviceConfigurations*') { return @($script:Ring) }
            return @()
        }
        Mock -ModuleName HU.WinUpdate Get-HUGroupNames { @{} }
        $i = Get-HUWuInventory -TenantKey 't' -Settings $script:Set -Catalog @{ 1 = 1 }
        @($i.Devices).Count | Should -Be 0
        @($i.Errors | Where-Object { $_ -like 'Geraete nicht lesbar: Berechtigung fehlt*' }).Count | Should -Be 1   # 074 B14: Recht wird genannt
        @($i.Policies).Count | Should -Be 1
    }
    It 'Geraete: erste Abfrage (mit joinType) scheitert, Rueckfall ohne joinType liefert Geraete ohne Fehlereintrag' {
        $script:n = 0
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll {
            if ($Endpoint -like '*managedDevices*') {
                if ($Endpoint -like '*joinType*') { throw 'Graph: Property joinType not found' }
                return @([pscustomobject]@{ id = 'd1'; deviceName = 'PC1'; osVersion = '10.0.26100.1'; lastSyncDateTime = '2026-10-27T10:00:00Z'; managedDeviceOwnerType = 'company' })
            }
            return @()
        }
        Mock -ModuleName HU.WinUpdate Get-HUGroupNames { @{} }
        $i = Get-HUWuInventory -TenantKey 't' -Settings $script:Set -Catalog @{ 1 = 1 } -Now ([datetime]'2026-10-28')
        @($i.Devices).Count | Should -Be 1
        @($i.Errors).Count | Should -Be 0
        $i.Devices[0].OhneSync | Should -BeFalse
    }
    It 'F5: Zuweisungen eines Profils nicht lesbar (429/403) -> das steht in Errors, nicht stillschweigend "keine Zuweisung"' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll {
            if ($Endpoint -like '*managedDevices*') { return @() }
            if ($Endpoint -like '*windowsFeatureUpdateProfiles/f1/assignments') { throw 'Graph GET: 429' }
            if ($Endpoint -like '*windowsFeatureUpdateProfiles') { return @([pscustomobject]@{ id = 'f1'; displayName = 'Feature'; featureUpdateVersion = '25H2' }) }
            return @()
        }
        Mock -ModuleName HU.WinUpdate Get-HUGroupNames { @{} }
        $i = Get-HUWuInventory -TenantKey 't' -Settings $script:Set -Catalog @{ 1 = 1 }
        @($i.Errors | Where-Object { $_ -like '*Feature*' -or $_ -like '*Zuweisung*' }).Count | Should -BeGreaterThan 0
    }
    It 'ein einziges Objekt statt Liste (PS 5.1 rollt 1-Element-Ergebnisse aus): Policies/Devices bleiben Arrays' {
        Mock -ModuleName HU.WinUpdate Get-HUIntuneGraphAll {
            if ($Endpoint -like '*managedDevices*') { return [pscustomobject]@{ id = 'd1'; deviceName = 'PC1'; osVersion = '10.0.26100.1' } }
            if ($Endpoint -like '*deviceConfigurations*') { return $script:Ring }
            return @()
        }
        Mock -ModuleName HU.WinUpdate Get-HUGroupNames { @{} }
        $i = Get-HUWuInventory -TenantKey 't' -Settings $script:Set -Catalog @{ 1 = 1 }
        @($i.Devices).Count | Should -Be 1
        @($i.Policies).Count | Should -Be 1
        $i.Policies.GetType().IsArray | Should -BeTrue
    }
}

Describe 'TQ: Treiber-Aktion' {
    It 'Aktion ungueltig -> Fehler vor dem Graph-Aufruf; approve schickt deploymentDeferral/-Datum als UTC, decline/suspend ohne Datum' {
        Mock -ModuleName HU.WinUpdate Invoke-HUIntuneGraph { $script:Last = $Body; [pscustomobject]@{ value = $null } }
        { Invoke-HUWuDriverAction -TenantKey 't' -Settings $script:Set -ProfileId 'p' -Action 'loeschen' -DriverIds 'd1' } | Should -Throw
        Should -Invoke Invoke-HUIntuneGraph -ModuleName HU.WinUpdate -Times 0 -Exactly
        [void](Invoke-HUWuDriverAction -TenantKey 't' -Settings $script:Set -ProfileId 'p' -Action 'approve' -DriverIds 'd1' -Date ([datetime]'2026-11-05 08:00'))
        $script:Last.deploymentDate | Should -Match 'Z$'
        [void](Invoke-HUWuDriverAction -TenantKey 't' -Settings $script:Set -ProfileId 'p' -Action 'decline' -DriverIds @('d1', 'd2'))
        $script:Last.ContainsKey('deploymentDate') | Should -BeFalse
        @($script:Last.driverIds).Count | Should -Be 2
    }
}
