#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer die Regelauswahl an Teams-Meldungen: Resolve-HUSecRuleSelection (Core\HU.SecCatalog.psm1),
    die Meldung "Sicherheits-Regeln" (heutiger Stand gewaehlter Regeln) und die Regelauswahl der "Sicherheits-Aenderung".
.NOTES
    Ohne Fenster, ohne Netzwerk, ohne Aufgabenplanung. Der Katalog-Lauf ist ersetzt (Mock), es wird nichts gesendet (-NoSend).
    Nur kuenstliche Testdaten.
#>

BeforeAll {
    Set-StrictMode -Version 1.0   # wie Main.ps1
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-TeamsSecRules-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path (Join-Path $script:TestRoot 'Config') -ItemType Directory -Force | Out-Null
    # eigenes, leeres Profil VOR dem Laden der Module: Sollwerte, Soll-Stand und Teams-Ziele liegen unter APPDATA
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = Join-Path $script:TestRoot 'appdata'
    New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null
    Import-Module (Join-Path $script:Root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:Root 'Core\HU.Notify.psm1') -Force -DisableNameChecking
    $nf = & (Get-Module HU.Notify) { $script:NotifyFile }
    if (-not "$nf".StartsWith($script:TestRoot)) { throw "Teams-Ziele zeigen nicht in den Testordner ($nf) - Abbruch, damit keine echten Karten gesendet werden" }
    Import-Module (Join-Path $script:Root 'Core\HU.TeamsJobs.psm1') -Force -DisableNameChecking

    function script:Res([string]$Id, [string]$Status = 'OK', [string]$Tenant = 'T1', [string]$Reason = '', $Count = $null, [string]$Detail = '', [string]$Sev = 'Hoch') {
        [pscustomobject]@{ RuleId = $Id; Area = 'Test'; Title = "Regel $Id"; Sev = $Sev; Tenant = $Tenant; Status = $Status; Reason = $Reason; Count = $Count; Detail = $Detail; Complete = $true; ExceptionId = '' }
    }
    $script:AllIds = @(Get-HUSecRules | ForEach-Object { "$($_.Id)" })
    $script:Rules = @(Get-HUSecRules)
    $script:Set2 = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; displayName = 'Schule A' }, [pscustomobject]@{ key = 'T2'; displayName = 'Schule B' }) }
    $script:Names = @{ T1 = 'Schule A'; T2 = 'Schule B' }
    $script:TeamsSrc = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Teams.ps1'), [Text.Encoding]::UTF8)
    $script:Xaml = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\MainWindow.xaml'), [Text.Encoding]::UTF8)
}

AfterAll {
    Remove-Module HU.TeamsJobs, HU.Notify, HU.SecCatalog -Force -ErrorAction SilentlyContinue
    $env:APPDATA = $script:OldAppData
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Regelauswahl aufloesen (Resolve-HUSecRuleSelection)' {
    It 'nichts gewaehlt (<Name>): keine Einschraenkung, gueltig' -ForEach @(
        @{ Name = 'null'; Value = $null }, @{ Name = 'leerer Text'; Value = '' }, @{ Name = 'nur Trennzeichen'; Value = ' , ; ' }, @{ Name = 'leere Liste'; Value = @() }
    ) {
        $s = Resolve-HUSecRuleSelection -Value $Value
        $s.Set | Should -BeFalse
        $s.Full | Should -BeTrue
        $s.Valid | Should -BeTrue
        $s.Ids.Count | Should -Be 0
        $s.Unknown.Count | Should -Be 0
    }
    It 'Regelnummern: Schreibweise egal, Reihenfolge wie im Katalog, doppelte nur einmal' {
        $s = Resolve-HUSecRuleSelection -Value 'k07, K04;k07  A01'
        $s.Set | Should -BeTrue
        $s.Full | Should -BeFalse
        $s.Valid | Should -BeTrue
        $want = @($script:AllIds | Where-Object { $_ -in 'K07', 'K04', 'A01' })
        ($s.Ids -join ',') | Should -Be ($want -join ',')
        ($s.Tokens -join ',') | Should -Be 'K07,K04,A01'
        $s.Text | Should -Be ($want -join ', ')
    }
    It 'Liste aus der Datei (auch mit einem Eintrag) und Text sind gleichwertig' {
        ((Resolve-HUSecRuleSelection -Value @('K07')).Ids -join ',') | Should -Be 'K07'
        ((Resolve-HUSecRuleSelection -Value @('K07', 'K04')).Ids -join ',') | Should -Be ((Resolve-HUSecRuleSelection -Value 'K04,K07').Ids -join ',')
    }
    It 'Umfang als Eintrag: bleibt als Kennung gespeichert und wird beim Lauf aufgeloest' {
        $s = Resolve-HUSecRuleSelection -Value 'onlyRisk'
        ($s.Ids -join ',') | Should -Be 'K07'
        ($s.Tokens -join ',') | Should -Be 'onlyRisk'
        $n = Resolve-HUSecRuleSelection -Value 'noRisk'
        $n.Ids | Should -Not -Contain 'K07'
        $n.Ids.Count | Should -Be ($script:AllIds.Count - 1)
    }
    It 'jeder Umfang aus der Tabelle ist als Eintrag gueltig (ein neuer Umfang gilt sofort auch hier)' {
        foreach ($sc in @(Get-HUSecScopes)) {
            $s = Resolve-HUSecRuleSelection -Value $sc.Id
            $s.Valid | Should -BeTrue -Because $sc.Id
            $s.Unknown.Count | Should -Be 0 -Because $sc.Id
            $s.Full | Should -Be $sc.Full -Because $sc.Id
        }
    }
    It 'Umfang "all" zusammen mit einer Regel: alles' {
        $s = Resolve-HUSecRuleSelection -Value 'all, K07'
        $s.Full | Should -BeTrue
        $s.Valid | Should -BeTrue
        $s.Ids.Count | Should -Be 0
    }
    It 'nur Unbekanntes: gesetzt, aber ungueltig - nie still "alles"' {
        $s = Resolve-HUSecRuleSelection -Value 'X99, gibtsnicht'
        $s.Set | Should -BeTrue
        $s.Valid | Should -BeFalse
        $s.Full | Should -BeFalse
        $s.Ids.Count | Should -Be 0
        ($s.Unknown -join ',') | Should -Be 'X99,gibtsnicht'
    }
    It 'Gueltiges und Unbekanntes gemischt: gueltig, Unbekanntes wird genannt' {
        $s = Resolve-HUSecRuleSelection -Value 'K07, X99'
        $s.Valid | Should -BeTrue
        ($s.Ids -join ',') | Should -Be 'K07'
        ($s.Unknown -join ',') | Should -Be 'X99'
    }
    It 'K07 darf seinen Detailtext in die Karte geben (nur Zahlen), andere Regeln nicht ungefragt' {
        $k = $script:Rules | Where-Object { $_.Id -eq 'K07' }
        $k.CardDetail | Should -BeTrue
        @($script:Rules | Where-Object { $_.PSObject.Properties['CardDetail'] -and $_.CardDetail } | ForEach-Object { "$($_.Id)" }) | Should -Be @('K07')
    }
}

Describe 'Karte Sicherheits-Regeln (New-HUSecRulesCardSpec)' {
    It 'alles in Ordnung: keine Karte, mit "auch ohne Befund" eine gruene' {
        $r = @((Res 'K07' 'OK' 'T1'), (Res 'K07' 'OK' 'T2'))
        New-HUSecRulesCardSpec -Results $r -Keys 'T1', 'T2' -Names $script:Names -Rules $script:Rules | Should -BeNullOrEmpty
        $s = New-HUSecRulesCardSpec -Results $r -Keys 'T1', 'T2' -Names $script:Names -Rules $script:Rules -SendAlways -Selection 'K07'
        $s.Level | Should -Be 'OK'
        $s.Preview | Should -Be 'alles in Ordnung'
        $s.Rows.Count | Should -Be 2
        $s.Rows[0].Name | Should -Be 'Schule A'
        $s.Rows[0].Text | Should -Be 'in Ordnung'
        $s.Facts['Gepruefte Regeln'] | Should -Be 'K07'
        $s.Facts['Abweichungen'] | Should -Be 0
    }
    It 'Abweichung: Karte, Stufe nach Schweregrad, Detailtext nur bei CardDetail' {
        $r = @((Res 'K07' 'Abweichung' 'T1' '' 2 '5 riskante Anmeldung(en) bei 2 Konto/Konten'), (Res 'A01' 'Abweichung' 'T2' '' 3 'Richtlinie Geheim' 'Mittel'))
        $s = New-HUSecRulesCardSpec -Results $r -Keys 'T1', 'T2' -Names $script:Names -Rules $script:Rules
        $s.Level | Should -Be 'Error'
        $s.Rows[0].Status | Should -Be 'Error'
        $s.Rows[0].Text | Should -Match '^K07: 5 riskante Anmeldung'
        $s.Rows[1].Status | Should -Be 'Warning'
        $s.Rows[1].Text | Should -Be 'A01 Regel A01 (3)'
        $s.Rows[1].Text | Should -Not -Match 'Geheim'
        $s.Preview | Should -Be '2 Abweichungen in 2 Tenants (Schule A, Schule B)'
        $s.Facts['Abweichungen'] | Should -Be 2
    }
    It 'Regel mit Zeitraum: Hinweis, dass dasselbe Ereignis wiederkommt' {
        $s = New-HUSecRulesCardSpec -Results @(Res 'K07' 'Abweichung' 'T1' '' 1) -Keys 'T1' -Rules $script:Rules
        @($s.Lines | Where-Object { $_ -match 'Regeln mit Zeitraum \(K07\)' }).Count | Should -Be 1
        $o = New-HUSecRulesCardSpec -Results @(Res 'A01' 'Abweichung' 'T1' '' 1) -Keys 'T1' -Rules $script:Rules
        @($o.Lines | Where-Object { $_ -match 'Regeln mit Zeitraum' }).Count | Should -Be 0
    }
    It 'nicht pruefbar, Fehler und unbekannter Status sind Befund - nie Entwarnung' -ForEach @(
        @{ Status = 'NichtPruefbar' }, @{ Status = 'Fehler' }, @{ Status = 'NeuerStatus' }
    ) {
        $s = New-HUSecRulesCardSpec -Results @(Res 'K07' $Status 'T1' 'Recht') -Keys 'T1' -Rules $script:Rules
        $s | Should -Not -BeNullOrEmpty
        $s.Level | Should -Be 'Warning'
        $s.Rows[0].Text | Should -Be 'K07 nicht pruefbar: Recht'
        $s.Facts['Nicht pruefbar'] | Should -Be 1
        $s.Preview | Should -Match 'nicht alles pruefbar'
    }
    It 'Tenant mit fehlgeschlagenem Lauf oder ohne Ergebnis: rote Zeile "nicht lesbar"' {
        $s = New-HUSecRulesCardSpec -Results @(Res 'K07' 'OK' 'T1') -Keys 'T1', 'T2' -Names $script:Names -Failed @{ T2 = 1 } -Rules $script:Rules
        $s.Level | Should -Be 'Error'
        $s.Rows[1].Name | Should -Be 'Schule B'
        $s.Rows[1].Text | Should -Match 'nicht lesbar'
        $s.Facts['Tenants nicht lesbar'] | Should -Be 1
        # ohne Eintrag in Failed, aber auch ohne ein einziges Ergebnis: ebenfalls nicht lesbar
        $n = New-HUSecRulesCardSpec -Results @(Res 'K07' 'OK' 'T1') -Keys 'T1', 'T2' -Rules $script:Rules
        $n.Rows[1].Text | Should -Match 'nicht lesbar'
    }
    It 'fehlerhafte Sollwerte (Zeile ohne Regelnummer) sind Befund' {
        $bad = [pscustomobject]@{ RuleId = '-'; Area = 'Katalog'; Title = 'Sollwerte'; Sev = 'Hoch'; Tenant = 'T1'; Status = 'Fehler'; Reason = 'Technisch'; Count = $null; Detail = 'Name: geheim'; Complete = $false; ExceptionId = '' }
        $s = New-HUSecRulesCardSpec -Results @((Res 'K07' 'OK' 'T1'), $bad) -Keys 'T1' -Rules $script:Rules
        $s | Should -Not -BeNullOrEmpty
        $s.Rows[0].Text | Should -Match 'Sollwerte fehlerhaft'
        $s.Rows[0].Text | Should -Not -Match 'geheim'
    }
    It 'Ausnahme und abgeschaltete Regel: kein Befund, aber in der Karte sichtbar' {
        $r = @((Res 'K07' 'Ausnahme' 'T1'), (Res 'K04' 'Info' 'T1' 'Aus'))
        New-HUSecRulesCardSpec -Results $r -Keys 'T1' -Rules $script:Rules | Should -BeNullOrEmpty
        $s = New-HUSecRulesCardSpec -Results $r -Keys 'T1' -Rules $script:Rules -SendAlways
        $s.Level | Should -Be 'OK'
        $s.Rows[0].Text | Should -Be 'K07 Ausnahme; K04 abgeschaltet (Sollwerte)'
    }
    It 'bei einem Tenant keine gepruefte Regel uebrig (<Name>): Befund statt "nichts zu melden"' -ForEach @(
        @{ Name = 'abgeschaltet'; Reason = 'Aus'; Text = 'keine der gewaehlten Regeln geprueft; K07 abgeschaltet (Sollwerte)' }
        @{ Name = 'nur Hinweis'; Reason = ''; Text = 'keine der gewaehlten Regeln geprueft; K07 nur Hinweis' }
    ) {
        $s = New-HUSecRulesCardSpec -Results @((Res 'K07' 'Info' 'T1' $Reason), (Res 'K07' 'OK' 'T2')) -Keys 'T1', 'T2' -Rules $script:Rules
        $s | Should -Not -BeNullOrEmpty
        $s.Level | Should -Be 'Warning'
        $s.Rows[0].Text | Should -Be $Text
        $s.Rows[1].Text | Should -Be 'in Ordnung'
        $s.Facts['Nicht pruefbar'] | Should -Be 1
    }
    It 'Vorschau nennt nur Tenants mit Abweichung, nicht die mit "nicht pruefbar"' {
        $s = New-HUSecRulesCardSpec -Results @((Res 'K07' 'Abweichung' 'T1' '' 1), (Res 'K07' 'NichtPruefbar' 'T2' 'Recht')) -Keys 'T1', 'T2' -Names $script:Names -Rules $script:Rules
        $s.Preview | Should -Be '1 Abweichung in 1 Tenant (Schule A)'
    }
    It 'unbekannter Eintrag in der Auswahl: Karte kommt auch ohne Abweichung, mit Hinweis' {
        $s = New-HUSecRulesCardSpec -Results @(Res 'K07' 'OK' 'T1') -Keys 'T1' -Rules $script:Rules -Unknown 'X99'
        $s | Should -Not -BeNullOrEmpty
        $s.Level | Should -Be 'Warning'
        @($s.Lines | Where-Object { $_ -match 'Nicht im Katalog.*X99' }).Count | Should -Be 1
    }
    It 'viele Befunde je Tenant werden gekuerzt' {
        $r = @(1..9 | ForEach-Object { Res "A0$_" 'Abweichung' 'T1' '' 1 })
        $s = New-HUSecRulesCardSpec -Results $r -Keys 'T1' -Rules $script:Rules -MaxPerTenant 4
        $s.Rows[0].Text | Should -Match 'und 5 weitere'
    }
}

Describe 'Meldung Sicherheits-Regeln im Lauf (Invoke-HUTeamsJob)' {
    BeforeEach {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { throw 'im Test wird nicht gesendet' }
    }
    It 'Art ist registriert und speicherbar; Auswahl mit einem Eintrag bleibt nach dem Speichern lesbar' {
        $k = Get-HUTeamsKinds | Where-Object Key -eq 'SecRules'
        $k.Label | Should -Be 'Sicherheits-Regeln'
        $k.Category | Should -Be 'Security'
        $j = New-HUTeamsJob -Name 'K07 taeglich' -Kind 'SecRules' -Options @{ rules = [string[]]@('K07'); sendAlways = $true }
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        $back = Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id
        $back.Kind | Should -Be 'SecRules'
        ((Get-HUTeamsSecSelection -Job $back).Ids -join ',') | Should -Be 'K07'
        $back.Options.sendAlways | Should -BeTrue
    }
    It 'gewaehlte Regel geht als -RuleIds an den Katalog; alles in Ordnung = nichts zu melden' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1', 'T2') -Options @{ rules = 'k07' }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 0
        $r.Success | Should -BeTrue
        $r.Spec | Should -BeNullOrEmpty
        $r.Message | Should -Match 'Nichts zu melden'
        $r.Message | Should -Match 'Regeln: K07'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 2 -Exactly -ParameterFilter { ($RuleIds -join ',') -eq 'K07' }
    }
    It '"auch ohne Befund senden": Karte trotz allem in Ordnung (auch als Text "true" aus der Datei)' -ForEach @(@{ V = $true }, @{ V = 'true' }) {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = @('K07'); sendAlways = $V }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec | Should -Not -BeNullOrEmpty
        $r.Spec.Level | Should -Be 'OK'
    }
    It '"auch ohne Befund senden" als "false" oder unlesbar aus der Datei bleibt aus' -ForEach @(@{ V = 'false' }, @{ V = '0' }, @{ V = '' }) {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = @('K07'); sendAlways = $V }
        (Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend).Spec | Should -BeNullOrEmpty
    }
    It 'ohne Auswahl: alle Regeln (leere -RuleIds)' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'A01'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1')
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 0
        $r.Message | Should -Match 'Regeln: alle'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 1 -Exactly -ParameterFilter { @($RuleIds).Count -eq 0 }
    }
    It 'Auswahl gesetzt, aber nichts Gueltiges: Konfigurationsfehler (Code 3), der Katalog laeuft NICHT mit allem' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { throw 'darf nicht laufen' }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = @('X99') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 3
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'Regelauswahl ungueltig \(X99\)'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 0 -Exactly
    }
    It 'Katalog-Lauf eines Tenants schlaegt fehl: Karte mit roter Zeile statt "Nichts zu melden"' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { if ($TenantKey -eq 'T2') { throw 'Token' }; [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1', 'T2') -Options @{ rules = @('K07') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec | Should -Not -BeNullOrEmpty
        $r.Spec.Level | Should -Be 'Error'
        $r.Spec.Rows[1].Name | Should -Be 'Schule B'
        $r.Spec.Rows[1].Text | Should -Match 'nicht lesbar'
    }
    It 'Abweichung: Karte mit dem Namen der Meldung im Titel' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'Abweichung'; Reason = ''; Count = 2; Detail = '3 riskante Anmeldung(en)' } }
        $j = New-HUTeamsJob -Name 'Riskante Anmeldungen' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = @('K07', 'X99') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Message | Should -Be 'Vorschau'
        $r.Spec.Title | Should -Match '^Riskante Anmeldungen - '
        $r.Spec.Rows[0].Text | Should -Be 'K07: 3 riskante Anmeldung(en)'
        @($r.Spec.Lines | Where-Object { $_ -match 'Nicht im Katalog.*X99' }).Count | Should -Be 1
    }
}

Describe 'Sicherheits-Aenderung mit Regelauswahl' {
    BeforeEach {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { throw 'im Test wird nicht gesendet' }
        Mock -ModuleName HU.TeamsJobs Get-HUSecReference { [pscustomobject]@{ time = '2026-11-18T10:00:00Z'; rows = @(); worse = 3; worseShown = $false } }
        Mock -ModuleName HU.TeamsJobs Update-HUSecLost { @() }
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
    }
    It 'ohne Auswahl wie bisher: alle Regeln, Hinweis "Soll schlechter" wird gezeigt' {
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1')
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec | Should -Not -BeNullOrEmpty
        $r.Spec.Preview | Should -Match 'Soll-Stand geaendert'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 1 -Exactly -ParameterFilter { @($RuleIds).Count -eq 0 }
    }
    It 'mit Auswahl: nur diese Regeln, Hinweis "Soll schlechter" bleibt der Meldung ohne Auswahl' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecReference { [pscustomobject]@{ time = '2026-11-18T10:00:00Z'; rows = @([pscustomobject]@{ tenant = 'T1'; ruleId = 'K07'; status = 'OK'; count = 0; latest = '' }); worse = 3; worseShown = $false } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1') -Options @{ rules = @('onlyRisk') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 0
        $r.Spec | Should -BeNullOrEmpty
        $r.Message | Should -Match 'Regeln: K07'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 1 -Exactly -ParameterFilter { ($RuleIds -join ',') -eq 'K07' }
    }
    It 'mit Auswahl und Aenderung: Karte nennt, was verglichen wurde' {
        Mock -ModuleName HU.TeamsJobs Compare-HUSecReference { [pscustomobject]@{ Changes = @([pscustomobject]@{ Tenant = 'T1'; RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Kind = 'Neu'; Worse = $true; Was = 'OK'; Is = 'Abweichung'; WasCount = 0; IsCount = 1 }); Unchecked = 0; Since = ''; HiddenCount = 0; Silent = @() } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1') -Options @{ rules = @('K07', 'X99') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        @($r.Spec.Lines | Where-Object { $_ -eq 'Verglichen wurden nur die gewaehlten Regeln: K07.' }).Count | Should -Be 1
        @($r.Spec.Lines | Where-Object { $_ -match 'Nicht im Katalog.*X99' }).Count | Should -Be 1
    }
    It 'mit Auswahl, Regel fehlt im Soll-Stand: Karte "nicht verglichen" statt "nichts zu melden"' {
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'Abweichung'; Reason = ''; Count = 2; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1') -Options @{ rules = @('K07') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec | Should -Not -BeNullOrEmpty
        $r.Spec.Level | Should -Be 'Warning'
        $r.Spec.Rows[0].Name | Should -Be 'Schule A - nicht verglichen'
        $r.Spec.Rows[0].Text | Should -Be 'im Soll-Stand nicht enthalten (Soll neu speichern): K07'
        $r.Spec.Facts['Nicht verglichen'] | Should -Be 1
        $r.Spec.Preview | Should -Be 'keine Aenderung, aber nicht alles verglichen'
    }
    It 'ohne Auswahl bleibt eine Regel ohne Soll-Zeile wie bisher still (kein neues Verhalten fuer bestehende Meldungen)' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecReference { [pscustomobject]@{ time = '2026-11-18T10:00:00Z'; rows = @(); worse = 0; worseShown = $true } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1')
        (Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend).Spec | Should -BeNullOrEmpty
    }
    It 'mit Auswahl, Katalog eines Tenants nicht lesbar: Karte nennt den Tenant' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecReference { [pscustomobject]@{ time = '2026-11-18T10:00:00Z'; rows = @([pscustomobject]@{ tenant = 'T1'; ruleId = 'K07'; status = 'OK'; count = 0; latest = '' }); worse = 0; worseShown = $true } }
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { if ($TenantKey -eq 'T2') { throw 'Token' }; [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1', 'T2') -Options @{ rules = @('K07') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec.Rows.Count | Should -Be 1
        $r.Spec.Rows[0].Name | Should -Be 'Schule B - nicht verglichen'
        $r.Spec.Rows[0].Text | Should -Be 'Katalog nicht lesbar'
    }
    It 'mit Auswahl, ein Eintrag unbekannt, sonst keine Aenderung: Karte nennt den unbekannten Eintrag' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecReference { [pscustomobject]@{ time = '2026-11-18T10:00:00Z'; rows = @([pscustomobject]@{ tenant = 'T1'; ruleId = 'K07'; status = 'OK'; count = 0; latest = '' }); worse = 0; worseShown = $true } }
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1') -Options @{ rules = @('K07', 'X99') }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Spec | Should -Not -BeNullOrEmpty
        $r.Spec.Rows.Count | Should -Be 0
        @($r.Spec.Lines | Where-Object { $_ -match 'Nicht im Katalog.*X99' }).Count | Should -Be 1
    }
    It 'Auswahl ungueltig: Code 3, kein Lauf mit allen Regeln' {
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecDrift' -Tenants @('T1') -Options @{ rules = 'X99' }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 3
        $r.Message | Should -Match 'Regelauswahl ungueltig'
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 0 -Exactly
    }
}

Describe 'Werte aus einer von Hand bearbeiteten Datei' {
    BeforeEach {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { throw 'im Test wird nicht gesendet' }
        Mock -ModuleName HU.TeamsJobs Invoke-HUSecCatalog { [pscustomobject]@{ RuleId = 'K07'; Title = 'R'; Sev = 'Hoch'; Tenant = $TenantKey; Status = 'OK'; Reason = ''; Count = 0; Detail = '' } }
    }
    It 'rules = <Name>: Zahl oder Wahrheitswert ist keine Regel - Code 3 statt eines Laufs mit allem' -ForEach @(@{ Name = '7'; V = 7 }, @{ Name = 'true'; V = $true }) {
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = $V }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 3
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 0 -Exactly
    }
    It 'rules leer (<Name>): gilt als nichts gewaehlt, es wird alles geprueft' -ForEach @(@{ Name = 'null'; V = $null }, @{ Name = 'leerer Text'; V = '' }, @{ Name = 'Liste mit leerem Text'; V = @('') }) {
        $j = New-HUTeamsJob -Name 'S' -Kind 'SecRules' -Tenants @('T1') -Options @{ rules = $V }
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set2 -AppRoot $script:TestRoot -NoSend
        $r.Code | Should -Be 0
        Should -Invoke -ModuleName HU.TeamsJobs Invoke-HUSecCatalog -Times 1 -Exactly -ParameterFilter { @($RuleIds).Count -eq 0 }
    }
}

Describe 'Handy-Fernbedienung' {
    It 'laedt fuer Teams-Meldungen den Sicherheitskatalog vor dem Teams-Modul' {
        $remote = [IO.File]::ReadAllText((Join-Path $script:Root 'Core\HU.RemoteRun.ps1'), [Text.Encoding]::UTF8)
        $remote | Should -Match "'HU\.Intune', 'HU\.SecCatalog', 'HU\.Notify', 'HU\.TeamsJobs'\) \{"
    }
    It 'mit genau dieser Modulliste sind alle Befehle der beiden Katalog-Meldungen da (frischer Prozess)' {
        $exe = (Get-Process -Id $PID).Path
        $code = "`$ErrorActionPreference = 'Stop'; `$env:APPDATA = '$($env:APPDATA)'; foreach (`$m in 'HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Intune', 'HU.SecCatalog', 'HU.Notify', 'HU.TeamsJobs') { Import-Module (Join-Path '$($script:Root)' ('Core\' + `$m + '.psm1')) -Force -DisableNameChecking }; (@('Resolve-HUSecRuleSelection', 'Get-HUSecReference', 'Invoke-HUSecCatalog', 'Compare-HUSecReference', 'Update-HUSecLost', 'Get-HUSecRules', 'Invoke-HUTeamsJob') | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) }) -join ','; 'ENDE'"
        $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -Command $code 2>&1 | ForEach-Object { "$_" })
        ($out -join '|') | Should -Be '|ENDE'
    }
}

Describe 'Oberflaeche: Regelauswahl im Reiter Teams' {
    It 'Auswahl "Sicherheits-Regeln" und die neuen Felder stehen im Fenster, mit Tooltip' {
        $script:Xaml | Should -Match '<ComboBoxItem Content="Sicherheits-Regeln" Tag="SecRules"/>'
        foreach ($n in 'pnlTeamsJobSec', 'txtTeamsJobRules', 'cmbTeamsJobRuleAdd', 'chkTeamsJobSendAlways', 'lblTeamsJobSecHint') { $script:Xaml | Should -Match "x:Name=`"$n`"" -Because $n }
        foreach ($n in 'txtTeamsJobRules', 'cmbTeamsJobRuleAdd', 'chkTeamsJobSendAlways') { $script:Xaml | Should -Match "x:Name=`"$n`"[^>]*ToolTip=" -Because $n }
    }
    It 'jede eingebaute Art des Moduls steht in der Auswahl des Fensters' {
        foreach ($k in @(Get-HUTeamsKinds | Where-Object { $_.Key -ne 'Script' })) { $script:Xaml | Should -Match "Tag=`"$($k.Key)`"" -Because $k.Key }
    }
    It 'Speichern: Auswahl ueber den Katalog geprueft, Unbekanntes abgelehnt, bei anderen Arten entfernt' {
        $script:TeamsSrc | Should -Match 'Resolve-HUSecRuleSelection -Value'
        $script:TeamsSrc | Should -Match 'if \(\$sel\.Unknown\.Count\) \{ throw'
        $script:TeamsSrc | Should -Match "foreach \(\`$n in 'rules', 'sendAlways'\) \{ if \(\`$j\.Options\.PSObject\.Properties\[\`$n\]\) \{ \`$j\.Options\.PSObject\.Properties\.Remove\(\`$n\) \} \}"
        $script:TeamsSrc | Should -Match "if \(\`$kind -in 'SecDrift', 'SecRules'\)"
    }
    It 'Felder sind nur bei den Meldungen des Sicherheitskatalogs sichtbar' {
        $script:TeamsSrc | Should -Match "\`$isSec = \(\`$kind -in 'SecDrift', 'SecRules'\)"
        $script:TeamsSrc | Should -Match "\['chkTeamsJobSendAlways'\]\.Visibility = \`$\(if \(\`$kind -eq 'SecRules'\)"
    }
}
