#Requires -Version 5.1
<#
.SYNOPSIS
    "So geht's" (Docs\SoGehts.json): Aufbau, Aktionen angemeldet, Quellen von Microsoft Learn.
#>
Describe 'So gehts - Rezepte' {
    BeforeAll {
        $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:J = [IO.File]::ReadAllText((Join-Path $script:Root 'Docs/SoGehts.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $src = foreach ($f in @(Get-ChildItem -Path (Join-Path $script:Root 'Functions') -Filter *.ps1)) { [IO.File]::ReadAllText($f.FullName) }
        $script:Reg = @([regex]::Matches(($src -join "`n"), "Register-HURecipeAction\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    It 'Format und je Bereich Titel und Rezepte' {
        $J.Format | Should -Be 'HU-SoGehts'
        foreach ($b in @($J.Bereiche.PSObject.Properties)) {
            "$($b.Value.Titel)" | Should -Not -BeNullOrEmpty
            @($b.Value.Rezepte).Count | Should -BeGreaterThan 0
        }
    }
    It 'Rezepte: eindeutige Id, Titel, Kurz, mindestens 2 Schritte mit Text' {
        $ids = @()
        foreach ($b in @($J.Bereiche.PSObject.Properties)) {
            foreach ($r in @($b.Value.Rezepte)) {
                "$($r.Id)" | Should -Match '^[a-z0-9-]+$'
                $ids += "$($r.Id)"
                "$($r.Titel)" | Should -Not -BeNullOrEmpty
                "$($r.Kurz)" | Should -Not -BeNullOrEmpty
                @($r.Schritte).Count | Should -BeGreaterOrEqual 2
                foreach ($s in @($r.Schritte)) { "$($s.Text)" | Should -Not -BeNullOrEmpty }
            }
        }
        @($ids | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
    It 'jede Aktion ist angemeldet oder eine https-Adresse, Knopf dazu beschriftet' {
        foreach ($b in @($J.Bereiche.PSObject.Properties)) {
            foreach ($r in @($b.Value.Rezepte)) {
                foreach ($s in @($r.Schritte | Where-Object { $_.PSObject.Properties['Aktion'] -and "$($_.Aktion)" })) {
                    $a = "$($s.Aktion)"
                    ($a -like 'url:https://*' -or $Reg -contains $a) | Should -BeTrue -Because "$($r.Id): $a"
                    "$($s.Knopf)" | Should -Not -BeNullOrEmpty -Because "$($r.Id): $a"
                }
            }
        }
    }
    It 'Quellen nur von Microsoft Learn' {
        foreach ($b in @($J.Bereiche.PSObject.Properties)) {
            foreach ($r in @($b.Value.Rezepte)) { foreach ($q in @($r.Quellen | Where-Object { $_ })) { "$($q.Url)" | Should -Match '^https://learn\.microsoft\.com/' } }
        }
    }
}
