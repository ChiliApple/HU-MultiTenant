#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer den Pruefumfang im Sicherheitskatalog (Analyse > Sicherheit): Umfang aufloesen, Teil-Laeufe
    zusammenfuehren, "nicht geprueft", Verlauf und Soll nur nach vollstaendigem Lauf, Grundschutz-Balken.
.NOTES
    Ohne Fenster und ohne Netzwerk: nur die reine Logik aus Core\HU.SecCatalog.psm1 und Textpruefungen an UI-Security.ps1 und MainWindow.xaml.
    Nur kuenstliche Testdaten.
#>

BeforeAll {
    Set-StrictMode -Version 1.0   # wie Main.ps1
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-SecScope-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TestAppData -ItemType Directory -Force | Out-Null
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = $script:TestAppData
    Import-Module (Join-Path $script:Root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking

    function script:Res([string]$Id, [string]$Status = 'OK', [string]$Tenant = 'T1', [string]$Reason = '') {
        [pscustomobject]@{ RuleId = $Id; Area = 'Test'; Title = "Regel $Id"; Sev = 'Mittel'; Tenant = $Tenant; Status = $Status; Reason = $Reason; Count = $null; Detail = ''; Complete = $true; ExceptionId = '' }
    }
    function script:Rows([string[]]$Ids, [string]$Tenant = 'T1', [string]$Status = 'OK') { @($Ids | ForEach-Object { Res $_ $Status $Tenant }) }
    $script:AllIds = @(Get-HUSecRules | ForEach-Object { "$($_.Id)" })
    $script:Sec = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Security.ps1'), [Text.Encoding]::UTF8)
    $script:T0 = [datetime]'2026-11-18T10:00:00'
    $script:T1 = [datetime]'2026-11-18T10:30:00'
}

AfterAll {
    $env:APPDATA = $script:OldAppData
    Remove-Item -LiteralPath $script:TestAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Umfaenge: Tabelle und Aufloesung' {
    It 'bietet all, noRisk und onlyRisk mit Text und Tooltip an' {
        $s = @(Get-HUSecScopes)
        @($s | ForEach-Object { $_.Id }) | Should -Be @('all', 'noRisk', 'onlyRisk')
        foreach ($i in $s) { $i.Text | Should -Not -BeNullOrEmpty; $i.Tip | Should -Not -BeNullOrEmpty }
        ($s | Where-Object Id -eq 'all').Text | Should -Be 'Alles'
        ($s | Where-Object Id -eq 'noRisk').Text | Should -Be 'Ohne riskante Anmeldungen'
        ($s | Where-Object Id -eq 'onlyRisk').Text | Should -Be 'Nur riskante Anmeldungen'
        @($s | Where-Object Full).Count | Should -Be 1
        ($s | Where-Object Full).Id | Should -Be 'all'
    }

    It 'all, leere und unbekannte Kennung: keine Einschraenkung (nichts, auch kein $null)' {
        @(Resolve-HUSecScope -Id 'all').Count | Should -Be 0
        @(Resolve-HUSecScope -Id 'gibtsnicht').Count | Should -Be 0
        @(Resolve-HUSecScope -Id '').Count | Should -Be 0
        @(Resolve-HUSecScope).Count | Should -Be 0
        $null -eq (Resolve-HUSecScope -Id 'all') | Should -BeTrue
    }

    It 'noRisk: alle Regeln ausser K07' {
        $ids = @(Resolve-HUSecScope -Id 'noRisk')
        $ids | Should -Not -Contain 'K07'
        $ids.Count | Should -Be ($script:AllIds.Count - 1)
        foreach ($i in $script:AllIds) { if ($i -ne 'K07') { $ids | Should -Contain $i } }
    }

    It 'onlyRisk: nur K07' {
        @(Resolve-HUSecScope -Id 'onlyRisk') | Should -Be @('K07')
    }

    It 'jede Regelnummer in der Tabelle existiert im Katalog, je Zeile Include oder Exclude' {
        $tab = InModuleScope HU.SecCatalog { $script:HUSecScopes }
        @($tab).Count | Should -BeGreaterOrEqual 3
        foreach ($t in $tab) {
            foreach ($n in @($t.Include) + @($t.Exclude)) { if ($n) { $script:AllIds | Should -Contain $n -Because "Umfang $($t.Id)" } }
            (@($t.Include).Count -gt 0 -and @($t.Exclude).Count -gt 0) | Should -BeFalse -Because "Umfang $($t.Id) hat beides"
        }
        @($tab | ForEach-Object { $_.Id } | Select-Object -Unique).Count | Should -Be @($tab).Count
    }

    It 'Lauf-Plan: nur all ist vollstaendig und darf den Verlauf schreiben' {
        $p = Get-HUSecRunPlan -ScopeId 'all'
        $p.Full | Should -BeTrue; $p.SaveHistory | Should -BeTrue; @($p.RuleIds).Count | Should -Be 0
        foreach ($id in 'noRisk', 'onlyRisk') {
            $q = Get-HUSecRunPlan -ScopeId $id
            $q.Full | Should -BeFalse; $q.SaveHistory | Should -BeFalse; @($q.RuleIds).Count | Should -BeGreaterThan 0; $q.Id | Should -Be $id
        }
        (Get-HUSecRunPlan -ScopeId 'unbekannt').Id | Should -Be 'all'
        (Get-HUSecRunPlan -ScopeId '').Full | Should -BeTrue
    }
}

Describe 'Zusammenfuehren der Ergebnisse' {
    It 'vollstaendiger Lauf ersetzt alles und stempelt die Zeilen' {
        $prev = Rows @('A01', 'A02', 'K07')
        $m = @(Merge-HUSecTenantRows -Previous $prev -New (Rows @('A01', 'A02')) -RuleIds @() -Stamp $script:T1)
        @($m.RuleId) | Should -Be @('A01', 'A02')
        foreach ($r in $m) { $r.RunAt | Should -Be $script:T1 }
    }

    It 'Teil-Lauf ersetzt nur die neu geprueften Regeln, der Rest bleibt mit altem Stempel' {
        $old = Rows @('A01', 'A02', 'K07'); foreach ($r in $old) { $r | Add-Member -NotePropertyName RunAt -NotePropertyValue $script:T0 }
        $new = @(Res 'K07' 'Abweichung')
        $m = @(Merge-HUSecTenantRows -Previous $old -New $new -RuleIds @('K07') -Stamp $script:T1)
        $m.Count | Should -Be 3
        ($m | Where-Object RuleId -eq 'K07').Status | Should -Be 'Abweichung'
        ($m | Where-Object RuleId -eq 'K07').RunAt | Should -Be $script:T1
        ($m | Where-Object RuleId -eq 'A01').RunAt | Should -Be $script:T0
        ($m | Where-Object RuleId -eq 'A02').Status | Should -Be 'OK'
    }

    It 'Teil-Lauf ersetzt auch die Sollwert-Fehlerzeilen (RuleId -), ohne neue Zeilen bleibt der Stand' {
        $old = @(Res 'A01') + @(Res '-' 'Fehler')
        $m = @(Merge-HUSecTenantRows -Previous $old -New @(Res 'K07') -RuleIds @('K07') -Stamp $script:T1)
        @($m | Where-Object RuleId -eq '-').Count | Should -Be 0
        $keep = @(Merge-HUSecTenantRows -Previous $old -New @() -RuleIds @('K07') -Stamp $script:T1)
        $keep.Count | Should -Be 2
    }

    It 'abgewaehlter Tenant faellt weg, neuer Tenant hat nur den Teil-Lauf' {
        $prev = @{ A = @(Rows @('A01', 'K07') 'A'); B = @(Rows @('A01', 'K07') 'B') }
        $new = @{ A = @(Res 'K07' 'Abweichung' 'A'); C = @(Res 'K07' 'OK' 'C') }
        $m = Merge-HUSecRunData -Previous $prev -Keys @('A', 'C') -New $new -RuleIds @('K07') -Stamp $script:T1
        @($m.Keys | Sort-Object) | Should -Be @('A', 'C')
        $m.ContainsKey('B') | Should -BeFalse
        @($m['A']).Count | Should -Be 2
        @($m['C']).Count | Should -Be 1
        @($m['C'])[0].RuleId | Should -Be 'K07'
    }

    It 'Start eines Laufs ohne neue Ergebnisse: vollstaendig = leer (wie bisher), Teil-Lauf = Stand der angehakten Tenants' {
        $prev = @{ A = @(Rows @('A01') 'A'); B = @(Rows @('A01') 'B') }
        (Merge-HUSecRunData -Previous $prev -Keys @('A', 'B') -RuleIds @()).Count | Should -Be 0
        $p = Merge-HUSecRunData -Previous $prev -Keys @('B', 'C') -RuleIds @('K07')
        @($p.Keys) | Should -Be @('B')
        @(Get-HUSecResultList -Data $p -Keys @('B', 'C')).Count | Should -Be 1
    }

    It 'Tenant ohne Ergebnis im Teil-Lauf (Fehler) behaelt den bisherigen Stand, im vollstaendigen Lauf nicht' {
        $prev = @{ A = @(Rows @('A01') 'A') }
        $p = Merge-HUSecRunData -Previous $prev -Keys @('A') -New @{ A = @() } -RuleIds @('K07')
        @($p['A']).Count | Should -Be 1
        $f = Merge-HUSecRunData -Previous $prev -Keys @('A') -New @{ A = @() } -RuleIds @()
        @($f['A']).Count | Should -Be 0
    }
}

Describe 'nicht geprueft (eigener Zustand)' {
    It 'erster Lauf als Teil-Lauf: alle anderen Regeln sind "nicht geprueft", nicht ok und keine Abweichung' {
        $res = @(Res 'K07' 'Abweichung')
        $mx = @(Get-HUSecMatrix -Results $res -Keys @('T1') -MarkNotRun)
        $mx.Count | Should -Be $script:AllIds.Count
        foreach ($row in $mx) {
            $cell = $row.Cells['T1']
            if ($row.RuleId -eq 'K07') { $cell.Status | Should -Be 'Abweichung' }
            else {
                $cell.Status | Should -Be 'NichtGeprueft'
                $cell.Status | Should -Not -Be 'OK'
                $row.Dev | Should -BeFalse
                $row.Diff | Should -BeFalse
            }
        }
        (Get-HUSecNotRunText) | Should -Be "nicht gepr$([char]0xFC)ft"
    }

    It 'ohne -MarkNotRun bleibt die Zelle leer (vollstaendiger Lauf wie bisher)' {
        $mx = @(Get-HUSecMatrix -Results @() -Keys @('T1'))
        foreach ($row in $mx) { $row.Cells['T1'] | Should -BeNullOrEmpty }
    }

    It 'Platzhalter fuer "nur Unterschiede": gleicher Status in beiden Tenants, Platzhalter daneben ist kein Unterschied' {
        $res = @(Res 'A01' 'OK' 'A')
        $mx = @(Get-HUSecMatrix -Results $res -Keys @('A', 'B') -MarkNotRun)
        ($mx | Where-Object RuleId -eq 'A01').Diff | Should -BeFalse
    }

    It 'Get-HUSecNotRunIds nennt Regeln ohne Ergebnis, Handpruefungen zaehlen nicht, -Ids begrenzt' {
        $hand = @(Get-HUSecManualIds)
        $ids = @(Get-HUSecNotRunIds -Results (Rows @('A01')) -Key 'T1')
        $ids | Should -Not -Contain 'A01'
        foreach ($h in $hand) { $ids | Should -Not -Contain $h }
        @(Get-HUSecNotRunIds -Results @() -Key 'T1' -Ids @('A01', 'A02')).Count | Should -Be 2
        @(Get-HUSecNotRunIds -Results @() -Key 'T1' -Ids @()).Count | Should -Be 0
        @(Get-HUSecNotRunIds -Results (Rows @('A01') 'T2') -Key 'T1' -Ids @('A01')).Count | Should -Be 1
    }

    It 'Stand der Zelle: frisch = leer, aelterer Lauf = Uhrzeit, ausgelassen = nicht geprueft' {
        $fresh = Res 'A01'; $fresh | Add-Member -NotePropertyName RunAt -NotePropertyValue $script:T1
        $old = Res 'A02'; $old | Add-Member -NotePropertyName RunAt -NotePropertyValue $script:T0
        Get-HUSecCellStand -Cell $fresh -LastStamp $script:T1 | Should -Be ''
        Get-HUSecCellStand -Cell $old -LastStamp $script:T1 | Should -Match '^Stand von 10:00 '
        Get-HUSecCellStand -Cell (Res 'A03') -LastStamp $script:T1 | Should -Be ''
        Get-HUSecCellStand -Cell $null -LastStamp $script:T1 | Should -Be ''
        Get-HUSecCellStand -Cell ([pscustomobject]@{ Status = 'NichtGeprueft' }) -LastStamp $script:T1 | Should -Be (Get-HUSecNotRunText)
    }
}

Describe 'Verlauf und Soll nur nach vollstaendigem Lauf' {
    It 'Verlauf wird nur bei vollstaendigem Lauf geschrieben (Plan und Aufruf in UI-Security)' {
        (Get-HUSecRunPlan -ScopeId 'noRisk').SaveHistory | Should -BeFalse
        (Get-HUSecRunPlan -ScopeId 'all').SaveHistory | Should -BeTrue
        $script:Sec | Should -Match '(?s)if \(\$script:SecFull\) \{\s*try \{ \[void\]\(Save-HUSecSnapshot'
    }

    It 'Soll speichern: gesperrt nach Teil-Lauf (mit Grund), frei nach vollem Lauf und vor dem ersten Lauf' {
        $why = Get-HUSecRefLock -Ran $true -Full $false -ScopeText 'Ohne riskante Anmeldungen'
        $why | Should -Not -BeNullOrEmpty
        $why | Should -Match 'Ohne riskante Anmeldungen'
        $why | Should -Match 'vollst'
        Get-HUSecRefLock -Ran $true -Full $true -ScopeText 'Alles' | Should -Be ''
        Get-HUSecRefLock -Ran $false -Full $false | Should -Be ''
    }

    It 'UI: Knopf wird gesperrt, behaelt den Tooltip-Grund, Klick-Handler prueft die Sperre ebenfalls' {
        $script:Sec | Should -Match 'function Update-HUSecRefButton'
        $script:Sec | Should -Match 'Get-HUSecRefLock -Ran \$script:SecRan -Full \$script:SecFull'
        $script:Sec | Should -Match '\$b\.IsEnabled = \$false; \$b\.ToolTip = \$why'
        $script:Sec | Should -Match "(?s)btnSecRef'\]\.Add_Click\(\{.*?Get-HUSecRefLock"
    }
}

Describe 'Grundschutz-Balken: "nicht geprueft" zaehlt wie "nicht pruefbar"' {
    BeforeAll {
        $script:Crit = @{}; foreach ($r in (Get-HUSecRules)) { if ("$($r.Sev)" -eq 'Kritisch') { $script:Crit["$($r.Id)"] = $true } }
        $script:Basic = @(Get-HUSecBasicIds)
        $script:BasicCrit = @($script:Basic | Where-Object { $script:Crit.ContainsKey($_) })
        $script:BasicNonCrit = @($script:Basic | Where-Object { -not $script:Crit.ContainsKey($_) -and @(Get-HUSecManualIds) -notcontains $_ })
    }

    It 'die Grundschutz-Liste hat kritische und nicht kritische Regeln' {
        $script:BasicCrit.Count | Should -BeGreaterThan 0
        $script:BasicNonCrit.Count | Should -BeGreaterThan 0
    }

    It 'ausgelassene kritische Regel: nie erfuellt, in der Gesamtzahl, Balken gelb' {
        $skip = $script:BasicCrit[0]
        $ids = @($script:Basic | Where-Object { $_ -ne $skip -and @(Get-HUSecManualIds) -notcontains $_ })
        $res = @(Rows $ids)
        $teil = Get-HUSecBasicLight -Results $res -Key 'T1' -Ids $script:Basic -Partial
        $teil.NotRun | Should -BeGreaterThan 0
        $teil.CriticalNotRun | Should -BeGreaterThan 0
        $teil.Color | Should -Be 'Gelb'
        $teil.Ok | Should -Be $ids.Count
        $teil.Total | Should -BeGreaterThan $teil.Ok
        # ohne den Schalter (vollstaendiger Lauf) bleibt alles wie bisher
        $voll = Get-HUSecBasicLight -Results $res -Key 'T1' -Ids $script:Basic
        $voll.Color | Should -Be 'Gruen'
        $voll.NotRun | Should -Be 0
    }

    It 'ausgelassene nicht kritische Regel: nie erfuellt, aber der Balken bleibt gruen (wie nicht pruefbar)' {
        $skip = $script:BasicNonCrit[0]
        $ids = @($script:Basic | Where-Object { $_ -ne $skip -and @(Get-HUSecManualIds) -notcontains $_ })
        $l = Get-HUSecBasicLight -Results @(Rows $ids) -Key 'T1' -Ids $script:Basic -Partial
        $l.NotRun | Should -Be 1
        $l.CriticalNotRun | Should -Be 0
        $l.Color | Should -Be 'Gruen'
        $l.Total | Should -Be ($l.Ok + 1)
    }

    It 'nichts geprueft (z. B. nur K07 gelaufen): Grau, nichts erfuellt' {
        $l = Get-HUSecBasicLight -Results @(Res 'K07' 'Abweichung') -Key 'T1' -Ids $script:Basic -Partial
        $l.Color | Should -Be 'Grau'
        $l.Ok | Should -Be 0
        $l.NotRun | Should -BeGreaterThan 0
    }
}

Describe 'Ampel im Teil-Lauf: Get-HUSecLight -Partial (Funktion wird ausgefuehrt)' {
    BeforeAll {
        $script:Hand = @(Get-HUSecManualIds)
        $script:Auto = @($script:AllIds | Where-Object { $script:Hand -notcontains $_ })
    }

    It 'die Testdaten passen: K07 ist automatisch geprueft, es gibt mindestens 12 weitere Regeln' {
        $script:Auto | Should -Contain 'K07'
        @($script:Auto | Where-Object { $_ -ne 'K07' }).Count | Should -BeGreaterOrEqual 12
    }

    It 'erster Teil-Lauf nur K07, K07 OK: nicht gruen, sondern gelb; die uebrigen Regeln sind "nicht geprueft"' {
        $l = Get-HUSecLight -Results @(Res 'K07') -Key 'T1' -Partial
        $l.Color | Should -Be 'Gelb'
        $l.Ok | Should -Be 1
        $l.Checked | Should -Be 1
        $l.NotRun | Should -Be ($script:Auto.Count - 1)
    }

    It 'Teil-Lauf, nichts erfuellt oder abgewichen geprueft (nur K07 nicht pruefbar): grau' {
        $l = Get-HUSecLight -Results @(Res 'K07' 'NichtPruefbar') -Key 'T1' -Partial
        $l.Color | Should -Be 'Grau'
        $l.Ok | Should -Be 0
    }

    It 'Teil-Lauf mit einem Fehler: gelb wie bisher (Rot erst ab 10 nicht erfuellten Regeln)' {
        $l = Get-HUSecLight -Results @(Res 'K07' 'Fehler' 'T1' 'Abruf') -Key 'T1' -Partial
        $l.Color | Should -Be 'Gelb'
        $l.Deviations | Should -Be 1
    }

    It 'Teil-Lauf mit 10 Abweichungen: rot wie bisher' {
        $res = @(Rows @($script:Auto | Select-Object -First 10) 'T1' 'Abweichung')
        $l = Get-HUSecLight -Results $res -Key 'T1' -Partial
        $l.Color | Should -Be 'Rot'
        $l.Deviations | Should -Be 10
        # derselbe Befund ohne den Schalter
        (Get-HUSecLight -Results $res -Key 'T1').Color | Should -Be 'Rot'
    }

    It 'Teil-Lauf, in dem jede Regel ein Ergebnis hat (frueherer Stand der Sitzung): gruen, nichts offen' {
        $l = Get-HUSecLight -Results @(Rows $script:Auto) -Key 'T1' -Partial
        $l.Color | Should -Be 'Gruen'
        $l.NotRun | Should -Be 0
    }

    It 'voller Lauf (ohne -Partial) unveraendert: K07 OK allein ist gruen, NotRun 0' {
        $l = Get-HUSecLight -Results @(Res 'K07') -Key 'T1'
        $l.Color | Should -Be 'Gruen'
        $l.Ok | Should -Be 1
        $l.NotRun | Should -Be 0
    }

    It '-Ids begrenzt die Regeln, die als "nicht geprueft" zaehlen (Auswahl der Oberflaeche)' {
        $other = @($script:Auto | Where-Object { $_ -ne 'K07' })[0]
        $a = Get-HUSecLight -Results @(Res 'K07') -Key 'T1' -Partial -Ids @('K07')
        $a.Color | Should -Be 'Gruen'
        $a.NotRun | Should -Be 0
        $b = Get-HUSecLight -Results @(Res 'K07') -Key 'T1' -Partial -Ids @('K07', $other)
        $b.Color | Should -Be 'Gelb'
        $b.NotRun | Should -Be 1
        $e = Get-HUSecLight -Results @(Res 'K07') -Key 'T1' -Partial -Ids @()
        $e.NotRun | Should -Be 0
    }

    It 'andere Tenants zaehlen nicht mit' {
        $l = Get-HUSecLight -Results @(@(Res 'K07' 'OK' 'T2') + @(Rows $script:Auto 'T1')) -Key 'T1' -Partial
        $l.Color | Should -Be 'Gruen'
        # Gegenprobe: T1 hat nur K07, alle anderen Ergebnisse gehoeren T2 und duerfen T1 nicht gruen machen
        $m = Get-HUSecLight -Results @(@(Res 'K07' 'OK' 'T1') + @(Rows $script:Auto 'T2')) -Key 'T1' -Partial
        $m.Color | Should -Be 'Gelb'
        $m.NotRun | Should -BeGreaterThan 0
    }

    It 'die Ampelzeile der Oberflaeche ruft Get-HUSecLight mit -Partial und der Auswahl auf und nimmt NotRun daraus' {
        $script:Sec | Should -Match 'Get-HUSecLight -Results @\(\$rows\) -Key \$keys\[\$i\] -Partial:\(-not \$script:SecFull\) -Ids \$selIds'
        $script:Sec | Should -Match '\$nr = \$l\.NotRun'
    }

    It 'Hinweiszeile "Einfach": Leerzeichen nach dem Doppelpunkt (H1)' {
        $script:Sec | Should -Match 'Einfach: \$\(@\(Get-HUSecVisibleRows\)\.Count\) Grundschutz-Regeln'
        $script:Sec | Should -Not -Match 'Einfach:\$\('
    }
}

Describe 'Ausnahmen: wirkungslos richtet sich nach dem letzten Pruefen' {
    BeforeAll {
        $script:Exc = [pscustomobject]@{ id = 'e1'; ruleId = 'K07'; tenant = 'T1'; validUntil = (Get-Date).AddDays(30).ToString('o'); objectId = '-'; created = (Get-Date).ToString('o') }
    }

    It 'aelteres "nicht pruefbar" macht die Ausnahme nach einem Teil-Lauf nicht wirkungslos' {
        $old = Res 'K07' 'NichtPruefbar' 'T1' 'Lizenz'; $old | Add-Member -NotePropertyName RunAt -NotePropertyValue $script:T0
        $other = Res 'A01'; $other | Add-Member -NotePropertyName RunAt -NotePropertyValue $script:T1
        (Get-HUSecExceptionState -Exception $script:Exc -Results @($old, $other)) | Should -Match '^wirkungslos: nicht pruefbar'
        $last = @(Get-HUSecLastRunResults -Results @($old, $other) -Stamp $script:T1)
        $last.Count | Should -Be 1
        (Get-HUSecExceptionState -Exception $script:Exc -Results $last) | Should -Be 'aktiv'
    }

    It 'ohne Stempel (kein Lauf) bleiben alle Ergebnisse' {
        @(Get-HUSecLastRunResults -Results (Rows @('A01', 'A02')) -Stamp $null).Count | Should -Be 2
    }
}

Describe 'Oberflaeche, Lauf und andere Aufrufer des Katalogs' {
    It 'cmbSecScope steht in MainWindow.xaml im Bereich pnlAnaSec, neben btnSecRun, mit Tooltip' {
        $x = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\MainWindow.xaml'), [Text.Encoding]::UTF8)
        $x | Should -Match 'x:Name="cmbSecScope"'
        $a = $x.IndexOf('x:Name="pnlAnaSec"'); $c = $x.IndexOf('x:Name="cmbSecScope"'); $b = $x.IndexOf('x:Name="btnSecRun"')
        $a | Should -BeGreaterThan 0
        $c | Should -BeGreaterThan $a
        $b | Should -BeGreaterThan $c
        $m = [regex]::Match($x, '<ComboBox x:Name="cmbSecScope"[^>]*>')
        $m.Value | Should -Match 'ToolTip='
        $m.Value | Should -Match 'DarkComboBox'
        $x | Should -Match 'Umfang:'
    }

    It 'Start-HUSecRun: Umfang aus der Auswahl, RuleIds nur bei Teil-Lauf, alte Laeufe werden vor dem Zusammenfuehren verworfen' {
        $script:Sec | Should -Match 'Get-HUSecRunPlan -ScopeId \(Get-HUSecComboTag ''cmbSecScope''\)'
        $script:Sec | Should -Match 'Invoke-HUSecCatalog -TenantKey \$TK -Settings \$Settings -RuleIds \$Ids'
        $script:Sec | Should -Match 'Merge-HUSecRunData -Previous \$script:SecData -Keys @\(\$tk\)'
        $gen = $script:Sec.IndexOf('[int]$d.__SecGen -ne $script:SecGen')
        $mer = $script:Sec.IndexOf('Merge-HUSecRunData -Previous $script:SecData -Keys @($tk)')
        $gen | Should -BeGreaterThan 0
        $mer | Should -BeGreaterThan $gen
        $script:Sec | Should -Match '\$script:SecGen\+\+'
        $script:Sec | Should -Match "Get-HUStateValue 'secScope' 'all'"
        $script:Sec | Should -Match "Set-HUStateValue 'secScope'"
    }

    It 'die taegliche Teams-Pruefung prueft alles, die Fernbedienung nach ihrer eigenen Auswahl; beide unabhaengig vom Umfang der Oberflaeche' {
        $teams = [IO.File]::ReadAllText((Join-Path $script:Root 'Core\HU.TeamsJobs.psm1'), [Text.Encoding]::UTF8)
        $m = [regex]::Match($teams, 'Invoke-HUSecCatalog -TenantKey \$k -Settings \$Settings[^\r\n]{0,10}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Not -Match 'RuleIds'
        $teams | Should -Not -Match 'cmbSecScope'
        $remote = [IO.File]::ReadAllText((Join-Path $script:Root 'Core\HU.RemoteRun.ps1'), [Text.Encoding]::UTF8)
        $remote | Should -Not -Match 'cmbSecScope|Get-HUSecRunPlan|Resolve-HUSecScope|Start-HUSecRun'
        # nur der Knopf in der Oberflaeche ruft Start-HUSecRun auf
        $hits = @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1 | Where-Object { $_.Name -ne 'UI-Security.ps1' -and ([IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) -match 'Start-HUSecRun') })
        $hits.Count | Should -Be 0
    }

    It 'Tabelle/Export und Detailfenster kennzeichnen gemischte Staende' {
        $script:Sec | Should -Match 'Get-HUSecCellStand -Cell \$cell -LastStamp \$script:SecStamp'
        $script:Sec | Should -Match 'x:Name="colStand"'
        $script:Sec | Should -Match 'Teil-Lauf: \$\(\$script:SecScopeText\)'
    }

    It 'Farben der Anzeige laufen ueber das Farbschema (Rollen Fg und Status), keine BrushConverter-Reste' {
        $script:Sec | Should -Not -Match 'BrushConverter'
        $script:Sec | Should -Match "ConvertTo-HUThemeColor \(Get-HUSecCellColor \`$cell\) 'Fg'"
        $script:Sec | Should -Match "ConvertTo-HUThemeColor '#EF5350' 'Status'"
    }
}
