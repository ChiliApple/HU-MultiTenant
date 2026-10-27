#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer das mitgelieferte Modul Autopilot (Modules\Autopilot) - reine Funktionen und Aufbau, ohne Graph und ohne Oberflaeche.
#>
BeforeAll {
    $script:App = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Root = Join-Path (Join-Path $script:App 'Modules') 'Autopilot'
    . (Join-Path $script:Root 'Autopilot.Archiv.ps1')
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('HU-AP-Test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'addon.json' {
    It 'Kennung, Version, Mindestversion und Reiter' {
        $j = Get-Content -LiteralPath (Join-Path $script:Root 'addon.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.id | Should -Be 'Autopilot'
        ($j.version -as [version]) | Should -Not -BeNullOrEmpty
        ($j.minApp -as [version]) | Should -BeGreaterOrEqual ([version]'2.5.2')
        $j.tab.init | Should -Be 'Initialize-HUAddonAutopilot'
        Test-Path -LiteralPath (Join-Path $script:Root $j.tab.xaml) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root $j.tab.script) | Should -BeTrue
    }
    It 'CHANGELOG hat einen Abschnitt fuer die Version (Release-Text der CI)' {
        $j = Get-Content -LiteralPath (Join-Path $script:Root 'addon.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        (Get-Content -LiteralPath (Join-Path $script:Root 'CHANGELOG.md') -Raw -Encoding UTF8) | Should -Match ("(?m)^## v" + [regex]::Escape($j.version) + '\b')
    }
}

Describe 'Hash-Archiv' {
    It 'Seriennummer: ohne Leerzeichen, gross' {
        ConvertTo-APSerialKey ' ab 12 c ' | Should -Be 'AB12C'
    }
    It 'Hash-Text: zu kurz oder kein Base64 wird abgelehnt' {
        Test-APHashText 'abc' | Should -BeFalse
        Test-APHashText ('!' * 1200) | Should -BeFalse
        Test-APHashText ([Convert]::ToBase64String((New-Object byte[] 900))) | Should -BeTrue
    }
    It 'Zusammenfuehren: gleicher Hash bei gleicher Seriennummer ist schon bekannt' {
        $h = [Convert]::ToBase64String((New-Object byte[] 900))
        $a = New-APArchivEintrag -Seriennummer 'PF1' -Hash $h -Quelle 'Datei'
        $b = New-APArchivEintrag -Seriennummer 'pf1 ' -Hash $h -Quelle 'Intune'
        $m = Merge-APArchiv @($a) @($b)
        $m.Neu | Should -Be 0; $m.Bekannt | Should -Be 1; @($m.Liste).Count | Should -Be 1
    }
    It 'Ablage verschluesselt (DPAPI) und wieder lesbar' -Skip:($env:OS -ne 'Windows_NT') {
        $h = [Convert]::ToBase64String((New-Object byte[] 900))
        Save-APArchiv 'T1' @((New-APArchivEintrag -Seriennummer 'PF1' -Hash $h -Quelle 'Datei')) $script:Tmp
        $f = Get-APArchivDatei 'T1' $script:Tmp
        [IO.File]::ReadAllText($f) | Should -Not -Match 'PF1'
        @(Read-APArchiv 'T1' $script:Tmp)[0].Seriennummer | Should -Be 'PF1'
    }
}

Describe 'Modul-Aufbau (wie die CI eines Zusatzmoduls)' {
    It 'Skripte ohne Syntaxfehler, Nicht-ASCII nur mit BOM' {
        foreach ($f in Get-ChildItem -LiteralPath $script:Root -Filter '*.ps1' -File) {
            $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            @($e).Count | Should -Be 0 -Because $f.Name
            $b = [IO.File]::ReadAllBytes($f.FullName)
            $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
            ($bom -or -not @($b | Where-Object { $_ -gt 0x7F }).Count) | Should -BeTrue -Because $f.Name
        }
    }
    It 'Tab.xaml gueltig, Theme-Platzhalter, Namen mit Praefix ap, alle benutzten Steuerelemente vorhanden' {
        $xaml = Get-Content -LiteralPath (Join-Path $script:Root 'Tab.xaml') -Raw -Encoding UTF8
        { [void][xml]$xaml } | Should -Not -Throw
        $xaml | Should -Match '<!--HU:THEME-->'
        # Schluessel, die das Theme schon setzt, duerfen im Reiter nicht noch einmal stehen (sonst laedt der Reiter nicht: doppelter Schluessel)
        $theme = Get-Content -LiteralPath (Join-Path (Join-Path $script:App 'XAML') 'Theme.xaml') -Raw -Encoding UTF8
        foreach ($k in @([regex]::Matches($theme, 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })) { $xaml | Should -Not -Match ('x:Key="' + [regex]::Escape($k) + '"') -Because $k }
        $names = @([regex]::Matches($xaml, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
        @($names | Where-Object { $_ -notmatch '^(ap|tab)' }).Count | Should -Be 0
        $code = Get-Content -LiteralPath (Join-Path $script:Root 'Addon.ps1') -Raw -Encoding UTF8
        foreach ($m in [regex]::Matches($code, "Controls\['(ap[A-Z][A-Za-z0-9]+)'\]")) { $names | Should -Contain $m.Groups[1].Value }
    }
    It 'StrictMode: jede $script:AP-Variable ist auf oberster Ebene vorbelegt' {
        $top = @('Addon.ps1', 'Autopilot.Core.ps1', 'Autopilot.Archiv.ps1') | ForEach-Object { Get-Content -LiteralPath (Join-Path $script:Root $_) -Encoding UTF8 }
        $init = @($top | Where-Object { $_ -match '^\$script:' } | ForEach-Object { [regex]::Matches($_, '\$script:(\w+)\s*=') | ForEach-Object { $_.Groups[1].Value } })
        $code = Get-Content -LiteralPath (Join-Path $script:Root 'Addon.ps1') -Raw -Encoding UTF8
        foreach ($v in @([regex]::Matches($code, '\$script:(AP\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) { $init | Should -Contain $v }
    }
}

Describe 'Hash speichern: Dateiname mit Seriennummer' {
    BeforeAll {
        $r = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $r 'Modules\Autopilot\Addon.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Get-APHashDateiname' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    It 'ein Geraet, mehrere Geraete, unsichere Zeichen' {
        Get-APHashDateiname @('PF4W22X6') 'Schule A' ([datetime]'2026-10-27') | Should -Be 'Autopilot-Hash_PF4W22X6_20261027.csv'
        Get-APHashDateiname @('A1', 'B2', 'C3') 'Schule A' ([datetime]'2026-10-27') | Should -Be 'Autopilot-Hash_Schule_A_3-Geraete_20261027.csv'
        Get-APHashDateiname @('X/Y:Z') '' ([datetime]'2026-10-27') | Should -Be 'Autopilot-Hash_X_Y_Z_20261027.csv'
    }
}
