#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5: Farbschema Dunkel/Hell/wie Windows (Functions\UI-Theme.ps1, Themes\*.json). Keine sichtbaren Fenster, XAML wird nur geladen.
.NOTES
    Aufruf: Invoke-Pester .github\tests\HU.Theme.Tests.ps1
#>

BeforeAll {
    Set-StrictMode -Version 1.0   # wie Main.ps1
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AppRoot = $script:Root
    if ($PSVersionTable.PSVersion.Major -le 5 -or $IsWindows) { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase }
    # Protokoll nur mitschreiben (kein Modul noetig)
    $script:LogLines = New-Object System.Collections.ArrayList
    function Write-HULog { param([string]$Message, [string]$Level = 'INFO', [string]$Tenant = '') [void]$script:LogLines.Add("$Level $Message") }
    . (Join-Path $script:Root 'Functions\UI-Theme.ps1')

    $theme = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\Theme.xaml'), [Text.Encoding]::UTF8)
    $script:ThemeInner = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>').Groups[1].Value
    function Get-TestXaml([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Replace('<!--HU:THEME-->', $script:ThemeInner) }
    function Get-MainXaml { Get-TestXaml (Join-Path $script:Root 'XAML\MainWindow.xaml') }

    # Temp-Ordner als Programmordner mit Themes\
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) "hutheme_$([guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $script:Tmp -Force)
    function New-TempRoot { $r = Join-Path $script:Tmp ([guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path (Join-Path $r 'Themes') -Force); return $r }
    function New-ValidTheme {
        return [ordered]@{
            schema = 1; id = 'tt'; name = 'Test'; kind = 'light'
            roles  = [ordered]@{ Bg = [ordered]@{ '#111111' = '#EEEEEE' }; Fg = [ordered]@{ '#CCCCCC' = '#222222' } }
            log    = [ordered]@{ OK = '#2E7D32' }
            keep   = @('#1976D2')
            future = 'wird ignoriert'
        }
    }
    function Write-ThemeFile([string]$Dir, [string]$Id, $Obj) {
        $p = Join-Path $Dir "$Id.json"
        [IO.File]::WriteAllText($p, ($Obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
        return $p
    }
    function Use-Theme([string]$Setting) { Initialize-HUTheme -Setting $Setting -AppRoot $script:Root }
}
AfterAll {
    Initialize-HUTheme -Setting 'dark' -AppRoot $script:Root
    if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Schema-Dateien Themes\*.json' {
    It 'dark.json und light.json sind gueltig, ids passen zu den Dateinamen' {
        foreach ($id in 'dark', 'light') {
            $t = Read-HUThemeFile (Join-Path $script:Root "Themes\$id.json")
            $t | Should -Not -BeNullOrEmpty -Because "$id.json: $script:HUThemeReadError"
            $t.Id | Should -BeExactly $id
            $t.SchemaVersion | Should -Be 1
        }
    }
    It 'dark ersetzt nichts, light ist kind light mit Protokollfarben' {
        $d = Read-HUThemeFile (Join-Path $script:Root 'Themes\dark.json')
        $d.Kind | Should -BeExactly 'dark'
        $d.Roles.Count | Should -Be 0
        $l = Read-HUThemeFile (Join-Path $script:Root 'Themes\light.json')
        $l.Kind | Should -BeExactly 'light'
        foreach ($k in 'OK', 'WARN', 'ERROR', 'INFO', 'DEBUG', 'Text') { $l.Log.ContainsKey($k) | Should -BeTrue -Because $k }
    }
    It 'keine Ketten: in keiner Rolle von light.json ist ein Zielwert zugleich Schluessel' {
        $j = [IO.File]::ReadAllText((Join-Path $script:Root 'Themes\light.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($role in $j.roles.PSObject.Properties) {
            $keys = @($role.Value.PSObject.Properties.Name)
            foreach ($p in $role.Value.PSObject.Properties) { $keys -contains $p.Value | Should -BeFalse -Because "$($role.Name) $($p.Name) -> $($p.Value)" }
        }
    }
    It 'light.json kennt alle sieben Rollen' {
        $l = Read-HUThemeFile (Join-Path $script:Root 'Themes\light.json')
        foreach ($r in 'Bg', 'Fg', 'Border', 'Btn', 'BtnFg', 'Auto', 'Status') { $l.Roles.ContainsKey($r) | Should -BeTrue -Because $r; $l.Roles[$r].Count | Should -BeGreaterThan 0 -Because $r }
    }
    It 'Dateien sind UTF-8 mit BOM' {
        foreach ($id in 'dark', 'light') {
            $b = [IO.File]::ReadAllBytes((Join-Path $script:Root "Themes\$id.json"))
            ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue -Because $id
        }
    }
    It 'eine gueltige Datei mit unbekannten Zusatzfeldern wird angenommen' {
        $dir = Join-Path (New-TempRoot) 'Themes'
        $p = Write-ThemeFile $dir 'tt' (New-ValidTheme)
        $t = Read-HUThemeFile $p
        $t | Should -Not -BeNullOrEmpty -Because $script:HUThemeReadError
        $t.Roles['Bg']['111111'] | Should -Be 'EEEEEE'
        $t.Keep | Should -Contain '#1976D2'
    }
    It 'lehnt <Name> ab' -ForEach @(
        @{ Name = 'Kette'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Bg['#EEEEEE'] = '#FFFFFF' } }
        @{ Name = 'zu kurzen Farbwert'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Bg['#1111'] = '#EEEEEE' } }
        @{ Name = 'Farbname statt Hex'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Fg['#CCCCCC'] = 'Red' } }
        @{ Name = 'Ausdruck als Wert'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Fg['#CCCCCC'] = '$(calc)' } }
        @{ Name = 'Ausdruck als Schluessel'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Fg['#CCCCCC; calc'] = '#222222' } }
        @{ Name = 'Wert mit Zeilenumbruch am Ende'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Fg['#CCCCCC'] = "#222222`n" } }
        @{ Name = 'Zahl als Wert'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles.Fg['#CCCCCC'] = 222222 } }
        @{ Name = 'falsches schema'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.schema = 2 } }
        @{ Name = 'schema als Text'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.schema = '1' } }
        @{ Name = 'id ungleich Dateiname'; Id = 'tt'; File = 'anders'; Mutate = { param($t) } }
        @{ Name = 'id mit Grossbuchstaben'; Id = 'TT'; File = 'TT'; Mutate = { param($t) } }
        @{ Name = 'id mit Punkt'; Id = 'a.b'; File = 'a.b'; Mutate = { param($t) } }
        @{ Name = 'unbekannte kind'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.kind = 'medium' } }
        @{ Name = 'unbekannte Rolle'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.roles['Zzz'] = [ordered]@{ '#111111' = '#EEEEEE' } } }
        @{ Name = 'kaputte Farbe im Protokoll'; Id = 'tt'; File = 'tt'; Mutate = { param($t) $t.log['OK'] = 'gruen' } }
    ) {
        $t = New-ValidTheme
        $t.id = $Id
        & $Mutate $t
        $dir = Join-Path (New-TempRoot) 'Themes'
        $p = Write-ThemeFile $dir $File $t
        Read-HUThemeFile $p | Should -BeNullOrEmpty -Because $Name
        $script:HUThemeReadError | Should -Not -BeNullOrEmpty
    }
    It 'lehnt denselben Schluessel in Gross- und Kleinschreibung ab' {
        $dir = Join-Path (New-TempRoot) 'Themes'
        $p = Join-Path $dir 'tt.json'
        [IO.File]::WriteAllText($p, '{"schema":1,"id":"tt","name":"T","kind":"light","roles":{"Fg":{"#CCCCCC":"#222222","#cccccc":"#333333"}}}', (New-Object System.Text.UTF8Encoding($true)))
        Read-HUThemeFile $p | Should -BeNullOrEmpty
    }
    It 'lehnt kein JSON und leere Datei ab' {
        $dir = Join-Path (New-TempRoot) 'Themes'
        $p = Join-Path $dir 'tt.json'
        [IO.File]::WriteAllText($p, '{ das ist kein json', (New-Object System.Text.UTF8Encoding($true)))
        Read-HUThemeFile $p | Should -BeNullOrEmpty
        [IO.File]::WriteAllText($p, '', (New-Object System.Text.UTF8Encoding($true)))
        Read-HUThemeFile $p | Should -BeNullOrEmpty
        Read-HUThemeFile (Join-Path $dir 'gibtsnicht.json') | Should -BeNullOrEmpty
    }
}

Describe 'Einstellung aufloesen: Initialize-HUTheme' {
    BeforeEach { $script:LogLines.Clear() }
    AfterEach { Use-Theme 'dark' }

    It 'dark: kein Eingriff, Grundwerte, keine Warnung' {
        Use-Theme 'dark'
        Get-HUTheme | Should -BeExactly 'dark'
        Test-HULightTheme | Should -BeFalse
        $i = Get-HUThemeInfo
        $i.Setting | Should -BeExactly 'dark'; $i.Id | Should -BeExactly 'dark'; $i.Name | Should -Be 'Dunkel'; $i.IsLight | Should -BeFalse
        $i.SchemaVersion | Should -Be 1
        $i.File | Should -BeLike '*Themes?dark.json'
        $script:LogLines.Count | Should -Be 0
    }
    It 'light: Hell, aus kind, Datei und Version' {
        Use-Theme 'light'
        Get-HUTheme | Should -BeExactly 'light'
        Test-HULightTheme | Should -BeTrue
        $i = Get-HUThemeInfo
        $i.Setting | Should -BeExactly 'light'; $i.Name | Should -Be 'Hell'; $i.IsLight | Should -BeTrue; $i.SchemaVersion | Should -Be 1
        $i.File | Should -BeLike '*Themes?light.json'
        $i.Warning | Should -BeNullOrEmpty
    }
    It 'Gross-/Kleinschreibung der Einstellung ist egal' {
        Use-Theme ' Light '
        Get-HUTheme | Should -BeExactly 'light'
        (Get-HUThemeInfo).Setting | Should -BeExactly 'light'
    }
    It 'leere Einstellung gilt als dark ohne Warnung' {
        foreach ($s in '', '   ', $null) {
            Initialize-HUTheme -Setting $s -AppRoot $script:Root
            Get-HUTheme | Should -BeExactly 'dark'
            (Get-HUThemeInfo).Setting | Should -BeExactly 'dark'
        }
        $script:LogLines.Count | Should -Be 0
    }
    It 'unbekannte oder unzulaessige Einstellung (<S>) gilt als dark, eine Warnzeile, kein Fehler' -ForEach @(
        @{ S = 'Lila' }, @{ S = 'x y' }, @{ S = '..\light' }, @{ S = 'a/b' }, @{ S = ('a' * 40) }, @{ S = "light`nlight" }
    ) {
        { Use-Theme $S } | Should -Not -Throw
        Get-HUTheme | Should -BeExactly 'dark'
        Test-HULightTheme | Should -BeFalse
        $script:LogLines.Count | Should -Be 1
        $script:LogLines[0] | Should -Match '^WARN '
        (Get-HUThemeInfo).Warning | Should -Not -BeNullOrEmpty
    }
    It 'fehlende Schema-Datei (Programmordner ohne Themes), Einstellung light: dark, eine Warnzeile, kein Fehler' {
        $r = Join-Path $script:Tmp ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $r -Force)
        foreach ($s in 'light', 'lila') {
            $script:LogLines.Clear()
            { Initialize-HUTheme -Setting $s -AppRoot $r } | Should -Not -Throw
            Get-HUTheme | Should -BeExactly 'dark'
            Test-HULightTheme | Should -BeFalse
            $script:LogLines.Count | Should -Be 1 -Because $s
            $script:LogLines[0] | Should -Match '^WARN '
        }
        # "Wie Windows" mit hellem Windows sucht light.json: auch das ist eine Warnung
        Mock Get-HUWindowsAppTheme { 'light' }
        $script:LogLines.Clear()
        { Initialize-HUTheme -Setting 'system' -AppRoot $r } | Should -Not -Throw
        Test-HULightTheme | Should -BeFalse
        $script:LogLines.Count | Should -Be 1
    }
    It 'dark ist eingebaut: ohne dark.json (Ordner fehlt oder leer) still gueltig, keine Warnung, keine Tabellen' {
        $leer = New-TempRoot
        $ohne = Join-Path $script:Tmp ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $ohne -Force)
        foreach ($r in $leer, $ohne) {
            $script:LogLines.Clear()
            Initialize-HUTheme -Setting 'dark' -AppRoot $r
            Get-HUTheme | Should -BeExactly 'dark'
            Test-HULightTheme | Should -BeFalse
            $i = Get-HUThemeInfo
            $i.Setting | Should -BeExactly 'dark'; $i.Id | Should -BeExactly 'dark'; $i.Name | Should -Be 'Dunkel'; $i.IsLight | Should -BeFalse
            $i.Warning | Should -BeNullOrEmpty
            $script:LogLines.Count | Should -Be 0
            ConvertTo-HUThemeColor '#1E1E1E' 'Bg' | Should -Be '#1E1E1E'
        }
        # "Wie Windows" mit dunklem Windows: ebenfalls still
        Mock Get-HUWindowsAppTheme { 'dark' }
        $script:LogLines.Clear()
        Initialize-HUTheme -Setting 'system' -AppRoot $leer
        Get-HUTheme | Should -BeExactly 'dark'
        $script:LogLines.Count | Should -Be 0
    }
    It 'eine kaputte dark.json warnt weiter (nur die fehlende Datei ist still)' {
        $r = New-TempRoot
        [IO.File]::WriteAllText((Join-Path $r 'Themes\dark.json'), '{ kaputt', (New-Object System.Text.UTF8Encoding($true)))
        Initialize-HUTheme -Setting 'dark' -AppRoot $r
        Get-HUTheme | Should -BeExactly 'dark'
        $script:LogLines.Count | Should -Be 1
        $script:LogLines[0] | Should -Match '^WARN '
    }
    It 'eine vorhandene gueltige dark.json hat Vorrang vor dem eingebauten Grundschema' {
        $r = New-TempRoot
        $t = New-ValidTheme; $t.id = 'dark'; $t.name = 'Dunkel (Datei)'; $t.kind = 'dark'
        [void](Write-ThemeFile (Join-Path $r 'Themes') 'dark' $t)
        $script:LogLines.Clear()
        Initialize-HUTheme -Setting 'dark' -AppRoot $r
        $i = Get-HUThemeInfo
        $i.Name | Should -Be 'Dunkel (Datei)'
        $i.File | Should -BeLike '*Themes?dark.json'
        $script:LogLines.Count | Should -Be 0
        (Get-HUThemeList -AppRoot $r | Where-Object Id -eq 'dark').Name | Should -Be 'Dunkel (Datei)'
    }
    It 'kaputte Schema-Datei: dark, eine Warnzeile, Einstellung bleibt' {
        $r = New-TempRoot
        [IO.File]::WriteAllText((Join-Path $r 'Themes\light.json'), '{ kaputt', (New-Object System.Text.UTF8Encoding($true)))
        { Initialize-HUTheme -Setting 'light' -AppRoot $r } | Should -Not -Throw
        Get-HUTheme | Should -BeExactly 'dark'
        (Get-HUThemeInfo).Setting | Should -BeExactly 'light'
        $script:LogLines.Count | Should -Be 1
        # und nichts wird umgesetzt
        ConvertTo-HUThemeColor '#1E1E1E' 'Bg' | Should -Be '#1E1E1E'
    }
    It 'eigene Schema-Datei wird ueber ihren Namen gefunden, kind steuert hell/dunkel (nicht der Name)' {
        $r = New-TempRoot
        $t = New-ValidTheme; $t.id = 'mein-schema'; $t.name = 'Dunkel (nur der Name)'
        [void](Write-ThemeFile (Join-Path $r 'Themes') 'mein-schema' $t)
        Initialize-HUTheme -Setting 'Mein-Schema' -AppRoot $r
        Get-HUTheme | Should -BeExactly 'mein-schema'
        Test-HULightTheme | Should -BeTrue
        (Get-HUThemeInfo).Name | Should -Be 'Dunkel (nur der Name)'
        ConvertTo-HUThemeColor '#111111' 'Bg' | Should -Be '#EEEEEE'
        $script:LogLines.Count | Should -Be 0
    }
    It 'system folgt Get-HUWindowsAppTheme (hell), Einstellung bleibt system' {
        Mock Get-HUWindowsAppTheme { 'light' }
        Use-Theme 'system'
        Get-HUTheme | Should -BeExactly 'light'
        Test-HULightTheme | Should -BeTrue
        (Get-HUThemeInfo).Setting | Should -BeExactly 'system'
    }
    It 'system folgt Get-HUWindowsAppTheme (dunkel), Einstellung bleibt system' {
        Mock Get-HUWindowsAppTheme { 'dark' }
        Use-Theme 'system'
        Get-HUTheme | Should -BeExactly 'dark'
        Test-HULightTheme | Should -BeFalse
        (Get-HUThemeInfo).Setting | Should -BeExactly 'system'
    }
    It 'system mit unsinniger Antwort gilt als dark' {
        Mock Get-HUWindowsAppTheme { 'blau' }
        Use-Theme 'system'
        Get-HUTheme | Should -BeExactly 'dark'
    }
    It 'Get-HUWindowsAppTheme liefert nur light oder dark' {
        Get-HUWindowsAppTheme | Should -BeIn @('light', 'dark')
    }
    It 'laedt ohne WPF und ohne Protokoll-Funktion im StrictMode 1.0 (eigener Runspace), wirft nie' {
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript({
                    param($File, $Root)
                    Set-StrictMode -Version 1.0
                    . $File
                    Initialize-HUTheme -Setting 'light' -AppRoot $Root
                    $a = (Get-HUThemeInfo).Id
                    Initialize-HUTheme -Setting 'gibt-es-nicht' -AppRoot $Root
                    $b = (Get-HUThemeInfo)
                    Initialize-HUTheme -Setting 'light' -AppRoot (Join-Path $Root 'nicht-da')
                    "$a|$($b.Id)|$($b.Warning.Length -gt 0)|$((Get-HUThemeInfo).Id)"
                }).AddArgument((Join-Path $script:Root 'Functions\UI-Theme.ps1')).AddArgument($script:Root)
            $r = $ps.Invoke()
            $ps.HadErrors | Should -BeFalse -Because (($ps.Streams.Error | ForEach-Object { "$_" }) -join '; ')
            "$($r[0])" | Should -Be 'light|dark|True|dark'
        } finally { $ps.Dispose() }
    }
}

Describe 'Farbschema dunkel aendert nichts' {
    BeforeAll { Use-Theme 'dark' }
    It 'MainWindow-XAML bleibt Byte fuer Byte gleich (auch dasselbe Objekt)' {
        $x = Get-MainXaml
        $o = ConvertTo-HUThemeXaml $x
        $o | Should -BeExactly $x
        [object]::ReferenceEquals($o, $x) | Should -BeTrue
    }
    It 'alle XAML-Dateien bleiben gleich' {
        foreach ($f in @(Get-ChildItem (Join-Path $script:Root 'XAML') -Filter *.xaml)) {
            $x = Get-TestXaml $f.FullName
            ConvertTo-HUThemeXaml $x | Should -BeExactly $x -Because $f.Name
        }
    }
    It 'Farben bleiben, in jeder Rolle' {
        foreach ($r in 'Bg', 'Fg', 'Border', 'Btn', 'BtnFg', 'Auto', 'Status', 'Unbekannt') {
            ConvertTo-HUThemeColor '#1E1E1E' $r | Should -BeExactly '#1E1E1E'
            ConvertTo-HUThemeColor 'White' $r | Should -BeExactly 'White'
            ConvertTo-HUThemeColor '{StaticResource X}' $r | Should -BeExactly '{StaticResource X}'
        }
        ConvertTo-HUThemeColor '' 'Bg' | Should -BeExactly ''
    }
    It 'keine Logfarben im dunklen Schema' {
        Get-HUThemeLogColors | Should -BeNullOrEmpty
    }
}

Describe 'Farbschema hell: Farben und XAML umsetzen' {
    BeforeAll { Use-Theme 'light' }
    AfterAll { Use-Theme 'dark' }

    It 'setzt Farben je Rolle um' {
        ConvertTo-HUThemeColor '#1E1E1E' 'Bg' | Should -Be '#F2EFE9'
        ConvertTo-HUThemeColor '#CCCCCC' 'Fg' | Should -Be '#2E2A24'
        ConvertTo-HUThemeColor 'White' 'Fg' | Should -Be '#1F1C18'
        ConvertTo-HUThemeColor 'White' 'BtnFg' | Should -Be 'White'
        ConvertTo-HUThemeColor '#555555' 'Btn' | Should -Be '#6B655A'
        ConvertTo-HUThemeColor '#3E3E42' 'Border' | Should -Be '#CFC8BA'
        ConvertTo-HUThemeColor '#4CAF50' 'Status' | Should -Be '#2E7D32'
        ConvertTo-HUThemeColor '#1976D2' 'Btn' | Should -Be '#1976D2'      # farbige Knoepfe bleiben
        ConvertTo-HUThemeColor '#801E1E1E' 'Bg' | Should -Be '#80F2EFE9'   # Deckkraft bleibt
        ConvertTo-HUThemeColor '#1e1e1e' 'Bg' | Should -Be '#F2EFE9'       # Kleinschreibung
        ConvertTo-HUThemeColor '{StaticResource X}' 'Bg' | Should -Be '{StaticResource X}'
        ConvertTo-HUThemeColor 'Transparent' 'Bg' | Should -Be 'Transparent'
    }
    It 'unbekannte Rolle gilt als Auto' {
        ConvertTo-HUThemeColor '#CCCCCC' 'Zzz' | Should -Be (ConvertTo-HUThemeColor '#CCCCCC' 'Auto')
        ConvertTo-HUThemeColor '#CCCCCC' '' | Should -Be '#2E2A24'
    }
    It 'Rollen ohne Eintrag lassen die Farbe stehen' {
        ConvertTo-HUThemeColor '#123456' 'Bg' | Should -Be '#123456'
    }
    It 'Knopf mit weisser Schrift bekommt mittelgraue Flaeche, Text daneben wird dunkel' {
        $x = '<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><Button Background="#555555" Foreground="White"/><TextBlock Foreground="White"/><Border Background="#3E3E42"/></Grid>'
        $h = ConvertTo-HUThemeXaml $x
        $h | Should -Match '<Button Background="#6B655A" Foreground="White"/>'
        $h | Should -Match '<TextBlock Foreground="#1F1C18"/>'
        $h | Should -Match '<Border Background="#FFFDF9"/>'
    }
    It 'Knopf mit eigener dunkler Schrift wird wie ein Feld behandelt' {
        ConvertTo-HUThemeXaml '<Button Background="#3E3E42" Foreground="#CCCCCC"/>' | Should -Be '<Button Background="#FFFDF9" Foreground="#2E2A24"/>'
    }
    It 'Setter: Knopf-Style ja, Hover mit TargetName nicht' {
        $x = '<Style TargetType="Button"><Setter Property="Background" Value="#555555"/><Setter Property="Foreground" Value="White"/><Setter TargetName="tb" Property="Background" Value="#3E3E42"/></Style>'
        $h = ConvertTo-HUThemeXaml $x
        $h | Should -Match 'Property="Background" Value="#6B655A"'
        $h | Should -Match 'Property="Foreground" Value="White"'
        $h | Should -Match 'TargetName="tb" Property="Background" Value="#FFFDF9"'
    }
    It 'Zeilen-Tonungen (Setter in DataGridRow) werden hell' {
        $x = '<Style TargetType="DataGridRow"><Style.Triggers><DataTrigger Binding="{Binding S}" Value="x"><Setter Property="Background" Value="#4A1C1C"/></DataTrigger></Style.Triggers></Style>'
        ConvertTo-HUThemeXaml $x | Should -Match 'Property="Background" Value="#F9E1E1"'
    }
    It 'Kommentare bleiben unveraendert' {
        ConvertTo-HUThemeXaml '<Grid><!-- Background="#1E1E1E" --></Grid>' | Should -Be '<Grid><!-- Background="#1E1E1E" --></Grid>'
    }
    # --- Anfuehrungszeichen: Attributwerte in "..." und in '...' ---
    It "einfache Anfuehrungszeichen bei Attributen werden umgesetzt, das Anfuehrungszeichen bleibt" {
        ConvertTo-HUThemeXaml "<Border Background='#232323' BorderBrush='#3E3E42'/>" | Should -BeExactly "<Border Background='#EDE9E2' BorderBrush='#CFC8BA'/>"
        ConvertTo-HUThemeXaml "<Button Background='#555555' Foreground='White'/>" | Should -BeExactly "<Button Background='#6B655A' Foreground='White'/>"
        ConvertTo-HUThemeXaml "<Button Background='#3E3E42' Foreground='#CCCCCC'/>" | Should -BeExactly "<Button Background='#FFFDF9' Foreground='#2E2A24'/>"
        ConvertTo-HUThemeXaml "<TextBlock Foreground='White'/>" | Should -BeExactly "<TextBlock Foreground='#1F1C18'/>"
    }
    It "einfache Anfuehrungszeichen bei Setter Property und Value, TargetType und TargetName" {
        $x = "<Style TargetType='Button'><Setter Property='Background' Value='#555555'/><Setter Property='Foreground' Value='White'/><Setter TargetName='tb' Property='Background' Value='#3E3E42'/></Style>"
        $h = ConvertTo-HUThemeXaml $x
        $h | Should -BeExactly "<Style TargetType='Button'><Setter Property='Background' Value='#6B655A'/><Setter Property='Foreground' Value='White'/><Setter TargetName='tb' Property='Background' Value='#FFFDF9'/></Style>"
        ConvertTo-HUThemeXaml "<Style TargetType='{x:Type Button}'><Setter Property='Background' Value='#555555'/></Style>" | Should -BeExactly "<Style TargetType='{x:Type Button}'><Setter Property='Background' Value='#6B655A'/></Style>"
    }
    It "gemischte Anfuehrungszeichen in einem Tag, Wert mit dem jeweils anderen Anfuehrungszeichen im Text" {
        ConvertTo-HUThemeXaml "<Border Background='#232323' BorderBrush=`"#3E3E42`"/>" | Should -BeExactly "<Border Background='#EDE9E2' BorderBrush=`"#CFC8BA`"/>"
        ConvertTo-HUThemeXaml "<TextBlock Text=`"it's`" Foreground='#CCCCCC'/>" | Should -BeExactly "<TextBlock Text=`"it's`" Foreground='#2E2A24'/>"
        ConvertTo-HUThemeXaml "<TextBlock Text='say `"hi`"' Foreground=`"#CCCCCC`"/>" | Should -BeExactly "<TextBlock Text='say `"hi`"' Foreground=`"#2E2A24`"/>"
        ConvertTo-HUThemeXaml "<Button Content='ok' Foreground='#CCCCCC' Background=`"#3E3E42`"/>" | Should -BeExactly "<Button Content='ok' Foreground='#2E2A24' Background=`"#FFFDF9`"/>"
        # Farbtext in einem anderen Attribut wird nicht angefasst
        ConvertTo-HUThemeXaml "<TextBlock Text='Background=`"#232323`"'/>" | Should -BeExactly "<TextBlock Text='Background=`"#232323`"'/>"
    }
    It 'im dunklen Schema kommt auch ein Text mit einfachen Anfuehrungszeichen unveraendert (dasselbe Objekt) zurueck' {
        Use-Theme 'dark'
        try {
            $x = "<Border Background='#232323'/>"
            [object]::ReferenceEquals((ConvertTo-HUThemeXaml $x), $x) | Should -BeTrue
        } finally { Use-Theme 'light' }
    }
    # --- Property-Element-Syntax und Setter.Value ---
    It 'Property-Element Background, BorderBrush, Foreground: die Farbe bekommt die Rolle der Eigenschaft statt Auto' {
        # #555555: Bg #E3DED5, Border #BFB8AA, Auto #857D70; #FFFFFF: Fg #1F1C18, in Auto ohne Eintrag
        ConvertTo-HUThemeXaml '<Border><Border.Background><SolidColorBrush Color="#555555"/></Border.Background></Border>' | Should -BeExactly '<Border><Border.Background><SolidColorBrush Color="#E3DED5"/></Border.Background></Border>'
        ConvertTo-HUThemeXaml '<Border><Border.BorderBrush><SolidColorBrush Color="#555555"/></Border.BorderBrush></Border>' | Should -BeExactly '<Border><Border.BorderBrush><SolidColorBrush Color="#BFB8AA"/></Border.BorderBrush></Border>'
        ConvertTo-HUThemeXaml '<TextBlock><TextBlock.Foreground><SolidColorBrush Color="#FFFFFF"/></TextBlock.Foreground></TextBlock>' | Should -BeExactly '<TextBlock><TextBlock.Foreground><SolidColorBrush Color="#1F1C18"/></TextBlock.Foreground></TextBlock>'
        ConvertTo-HUThemeXaml '<Path><Path.Stroke><SolidColorBrush Color="#555555"/></Path.Stroke></Path>' | Should -BeExactly '<Path><Path.Stroke><SolidColorBrush Color="#BFB8AA"/></Path.Stroke></Path>'
        ConvertTo-HUThemeXaml '<Path><Path.Fill><SolidColorBrush Color="#555555"/></Path.Fill></Path>' | Should -BeExactly '<Path><Path.Fill><SolidColorBrush Color="#857D70"/></Path.Fill></Path>'   # Fill hat keine eigene Rolle: Auto
    }
    It 'Property-Element mit Verlauf: GradientStop Color gilt als die Rolle der Eigenschaft' {
        $x = '<Border><Border.Background><LinearGradientBrush><GradientStop Color="#555555" Offset="0"/><GradientStop Color="#232323" Offset="1"/></LinearGradientBrush></Border.Background></Border>'
        ConvertTo-HUThemeXaml $x | Should -BeExactly '<Border><Border.Background><LinearGradientBrush><GradientStop Color="#E3DED5" Offset="0"/><GradientStop Color="#EDE9E2" Offset="1"/></LinearGradientBrush></Border.Background></Border>'
    }
    It 'Setter.Value mit Pinsel: die Rolle kommt aus Property des umschliessenden Setters, im Knopf-Style als Btn' {
        ConvertTo-HUThemeXaml '<Style TargetType="Border"><Setter Property="Background"><Setter.Value><SolidColorBrush Color="#555555"/></Setter.Value></Setter></Style>' | Should -BeExactly '<Style TargetType="Border"><Setter Property="Background"><Setter.Value><SolidColorBrush Color="#E3DED5"/></Setter.Value></Setter></Style>'
        ConvertTo-HUThemeXaml '<Style TargetType="Button"><Setter Property="Background"><Setter.Value><SolidColorBrush Color="#555555"/></Setter.Value></Setter></Style>' | Should -BeExactly '<Style TargetType="Button"><Setter Property="Background"><Setter.Value><SolidColorBrush Color="#6B655A"/></Setter.Value></Setter></Style>'
        ConvertTo-HUThemeXaml "<Style TargetType='Border'><Setter Property='BorderBrush'><Setter.Value><SolidColorBrush Color='#555555'/></Setter.Value></Setter></Style>" | Should -BeExactly "<Style TargetType='Border'><Setter Property='BorderBrush'><Setter.Value><SolidColorBrush Color='#BFB8AA'/></Setter.Value></Setter></Style>"
    }
    It 'Property-Element in einer Knopf-Vorlage: Button.Background und Border.Background im Button-Style gelten als Knopffläche (Btn)' {
        ConvertTo-HUThemeXaml '<Button><Button.Background><SolidColorBrush Color="#555555"/></Button.Background></Button>' | Should -BeExactly '<Button><Button.Background><SolidColorBrush Color="#6B655A"/></Button.Background></Button>'
        $x = '<Style TargetType="Button"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border><Border.Background><SolidColorBrush Color="#555555"/></Border.Background></Border></ControlTemplate></Setter.Value></Setter></Style>'
        ConvertTo-HUThemeXaml $x | Should -BeExactly $x.Replace('#555555', '#6B655A')
    }
    It 'ohne Rahmen bleibt Color bei Auto, auch nach einem geschlossenen Property-Element und bei anderen Property-Elementen' {
        ConvertTo-HUThemeXaml '<SolidColorBrush x:Key="K" Color="#555555"/>' | Should -BeExactly '<SolidColorBrush x:Key="K" Color="#857D70"/>'
        ConvertTo-HUThemeXaml '<Window.Resources><SolidColorBrush x:Key="K" Color="#555555"/></Window.Resources>' | Should -BeExactly '<Window.Resources><SolidColorBrush x:Key="K" Color="#857D70"/></Window.Resources>'
        ConvertTo-HUThemeXaml '<Border><Border.Background><SolidColorBrush Color="#555555"/></Border.Background><SolidColorBrush Color="#555555"/></Border>' | Should -BeExactly '<Border><Border.Background><SolidColorBrush Color="#E3DED5"/></Border.Background><SolidColorBrush Color="#857D70"/></Border>'
        ConvertTo-HUThemeXaml '<Border><Border.Effect><DropShadowEffect Color="#555555"/></Border.Effect></Border>' | Should -BeExactly '<Border><Border.Effect><DropShadowEffect Color="#857D70"/></Border.Effect></Border>'
        ConvertTo-HUThemeXaml '<Setter Property="Template"><Setter.Value><ControlTemplate><Border.Effect><DropShadowEffect Color="#555555"/></Border.Effect></ControlTemplate></Setter.Value></Setter>' | Should -Match 'Color="#857D70"'
    }
    It 'Theme-Teil wird zwischengespeichert und gleich umgesetzt wie ohne Zwischenspeicher' {
        $x = Get-TestXaml (Join-Path $script:Root 'XAML\SettingsWindow.xaml')
        $a = ConvertTo-HUThemeXaml $x
        $b = ConvertTo-HUThemeXamlCore $x
        $a | Should -BeExactly $b
        ConvertTo-HUThemeXaml $x | Should -BeExactly $a   # aus dem Zwischenspeicher
    }
    It 'Fehler in der Umsetzung: Original zurueck, einmal protokolliert' {
        $script:LogLines.Clear()
        Mock ConvertTo-HUThemeXamlCore { throw 'kaputt' }
        $script:HUThemeCache = @{}
        $script:HUThemeXamlWarned = $false
        $x = '<Grid Background="#1E1E1E"/>'
        ConvertTo-HUThemeXaml $x | Should -BeExactly $x
        ConvertTo-HUThemeXaml '<Grid Background="#252526"/>' | Should -BeExactly '<Grid Background="#252526"/>'
        @($script:LogLines | Where-Object { $_ -match 'XAML nicht umgesetzt' }).Count | Should -Be 1
    }
    It 'Protokollfarben kommen aus dem Feld log' {
        $lc = Get-HUThemeLogColors
        $lc['ERROR'] | Should -Be '#C62828'
        $lc['Text'] | Should -Be '#2E2A24'
        foreach ($k in 'OK', 'WARN', 'ERROR', 'INFO', 'DEBUG') { $lc[$k] | Should -Match '^#[0-9A-F]{6}$' }
    }
}

Describe 'Alle Fenster laden in Hell' {
    BeforeAll {
        $script:AllXaml = @(Get-ChildItem (Join-Path $script:Root 'XAML') -Filter *.xaml | Where-Object Name -ne 'Theme.xaml') + @(Get-Item (Join-Path $script:Root 'Modules\Autopilot\Tab.xaml'))
    }
    AfterAll { Use-Theme 'dark' }

    It 'findet die Fenster und den Reiter des Moduls' { @($script:AllXaml).Count | Should -BeGreaterOrEqual 7 }
    It 'laden in hell per XamlReader und unterscheiden sich von dunkel' {
        foreach ($f in $script:AllXaml) {
            $x = Get-TestXaml $f.FullName
            Use-Theme 'dark'
            $d = ConvertTo-HUThemeXaml $x
            $d | Should -BeExactly $x -Because $f.Name
            Use-Theme 'light'
            $h = ConvertTo-HUThemeXaml $x
            $h | Should -Not -BeExactly $d -Because $f.Name
            $r = [System.Xml.XmlReader]::Create([IO.StringReader]::new($h))
            try { { [void][System.Windows.Markup.XamlReader]::Load($r) } | Should -Not -Throw -Because $f.Name } finally { $r.Close() }
        }
    }
}

Describe 'Vollstaendigkeit: jede Farbe der App ist umgesetzt oder bewusst geblieben' {
    BeforeAll {
        $l = Read-HUThemeFile (Join-Path $script:Root 'Themes\light.json')
        $script:Known = @{}
        foreach ($role in $l.Roles.Keys) { foreach ($k in $l.Roles[$role].Keys) { $script:Known[$k] = $role } }
        $script:Keep = @{}
        foreach ($k in $l.Keep) { $script:Keep[$k.Substring(1)] = $true }
    }
    It 'keep: nur Farben, die nicht zugleich umgesetzt werden und tatsaechlich vorkommen' {
        $script:Keep.Count | Should -BeGreaterThan 0
        $used = @{}
        $files = @(Get-ChildItem (Join-Path $script:Root 'XAML') -Filter *.xaml) + @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File | Where-Object Extension -in '.ps1', '.xaml') + @(Get-Item (Join-Path $script:Root 'Main.ps1'))
        foreach ($f in $files) { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8), '#(?:[0-9A-Fa-f]{2})?([0-9A-Fa-f]{6})\b')) { $used[$m.Groups[1].Value.ToUpperInvariant()] = $true } }
        foreach ($k in $script:Keep.Keys) { $used.ContainsKey($k) | Should -BeTrue -Because "keep #$k kommt im Code nicht mehr vor" }
    }
    It 'XAML, Funktionen, Autopilot-Reiter und Main.ps1: keine unbekannte Farbe' {
        # UI-Theme.ps1 selbst nennt Farben nur als Beispiele in der Hilfe
        $files = @(Get-ChildItem (Join-Path $script:Root 'XAML') -Filter *.xaml) + @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1 | Where-Object Name -ne 'UI-Theme.ps1') + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File | Where-Object Extension -in '.ps1', '.xaml') + @(Get-Item (Join-Path $script:Root 'Main.ps1'))
        $missing = New-Object System.Collections.ArrayList
        foreach ($f in $files) {
            $n = 0
            foreach ($line in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) {
                $n++
                foreach ($m in [regex]::Matches($line, '#(?:[0-9A-Fa-f]{2})?([0-9A-Fa-f]{6})\b')) {
                    $k = $m.Groups[1].Value.ToUpperInvariant()
                    if (-not $script:Known.ContainsKey($k) -and -not $script:Keep.ContainsKey($k)) { [void]$missing.Add("$($f.Name):$n #$k") }
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because "diese Farben fehlen in Themes\light.json (Rolle eintragen oder unter keep aufnehmen): $($missing -join ', ')"
    }
}

Describe 'Ladestellen: jede XAML-Ladestelle ist am Farbschema angeschlossen oder ausdruecklich ausgenommen' {
    BeforeAll {
        # Ausnahmen: Datei, Kennwort der Stelle (steht in der Zeile des Treffers), Grund
        $script:Exceptions = @(
            @{ File = 'UI-Splash.ps1'; Key = 'Get-HUSplashXaml'; Reason = 'Startbildschirm bleibt wie er ist' }
            @{ File = 'Main.ps1'; Key = 'wird neu gestartet'; Reason = 'Neustart-Fenster laeuft vor den Einstellungen' }
            @{ File = 'Main.ps1'; Key = '$script:Splash'; Reason = 'Startbildschirm bleibt wie er ist' }
            @{ File = 'UI-Security.ps1'; Key = 'DataTemplate'; Reason = 'DataTemplate mit gebundenen Farben, wird spaeter ueber die Daten geloest' }
        )
        $script:ExceptionUsed = @{}
        $script:Files = @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1 | Where-Object Name -ne 'UI-Theme.ps1') + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File -Filter *.ps1) + @(Get-Item (Join-Path $script:Root 'Main.ps1'))
    }
    It 'jeder Treffer von XamlReader steht in einer Funktion mit ConvertTo-HUThemeXaml oder auf der Ausnahmeliste' {
        $bad = New-Object System.Collections.ArrayList
        foreach ($f in $script:Files) {
            $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
            $hits = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'XamlReader\]::') { $i + 1 } })
            if (-not $hits.Count) { continue }
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $funcs = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            foreach ($ln in $hits) {
                $ok = $false
                $inside = @($funcs | Where-Object { $_.Extent.StartLineNumber -le $ln -and $_.Extent.EndLineNumber -ge $ln } | Sort-Object { $_.Extent.EndLineNumber - $_.Extent.StartLineNumber })
                if ($inside.Count -and $inside[0].Extent.Text -match 'ConvertTo-HUThemeXaml') { $ok = $true }
                if (-not $ok) {
                    foreach ($e in $script:Exceptions) {
                        if ($e.File -eq $f.Name -and $lines[$ln - 1].Contains($e.Key)) { $ok = $true; $script:ExceptionUsed["$($e.File)|$($e.Key)"] = $true }
                    }
                }
                if (-not $ok) { [void]$bad.Add("$($f.Name):$ln") }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "diese Ladestellen setzen das Farbschema nicht um (ConvertTo-HUThemeXaml aufrufen oder mit Grund in die Ausnahmeliste): $($bad -join ', ')"
    }
    It 'jede Ausnahme trifft noch eine Stelle (keine veralteten Eintraege)' {
        foreach ($e in $script:Exceptions) { $script:ExceptionUsed.ContainsKey("$($e.File)|$($e.Key)") | Should -BeTrue -Because "$($e.File) / $($e.Key)" }
    }
    It 'die Ladestellen des Kerns rufen ConvertTo-HUThemeXaml auf' {
        $common = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Common.ps1'), [Text.Encoding]::UTF8)
        ([regex]::Matches($common, 'ConvertTo-HUThemeXaml')).Count | Should -BeGreaterOrEqual 2   # New-HUWindow und Show-HUToast
        [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Addons.ps1'), [Text.Encoding]::UTF8) | Should -Match 'ConvertTo-HUThemeXaml'
        [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-SecretSetup.ps1'), [Text.Encoding]::UTF8) | Should -Match 'ConvertTo-HUThemeXaml'
    }
}

Describe 'Theme-Liste' {
    It 'Get-HUThemeList liefert dark und light zuerst, mit Id, Name, Kind, File' {
        $l = @(Get-HUThemeList -AppRoot $script:Root)
        $l.Count | Should -BeGreaterOrEqual 2
        $l[0].Id | Should -BeExactly 'dark'; $l[0].Name | Should -Be 'Dunkel'; $l[0].Kind | Should -BeExactly 'dark'
        $l[1].Id | Should -BeExactly 'light'; $l[1].Name | Should -Be 'Hell'; $l[1].Kind | Should -BeExactly 'light'
        foreach ($i in $l) { Test-Path -LiteralPath $i.File | Should -BeTrue }
    }
    It 'ungueltige Dateien fehlen in der Liste, gueltige eigene kommen dazu' {
        $r = New-TempRoot
        Copy-Item (Join-Path $script:Root 'Themes\*.json') (Join-Path $r 'Themes')
        $t = New-ValidTheme; $t.id = 'zzz'
        [void](Write-ThemeFile (Join-Path $r 'Themes') 'zzz' $t)
        $t = New-ValidTheme; $t.id = 'kaputt'; $t.kind = 'medium'
        [void](Write-ThemeFile (Join-Path $r 'Themes') 'kaputt' $t)
        [IO.File]::WriteAllText((Join-Path $r 'Themes\kein-json.json'), 'x', (New-Object System.Text.UTF8Encoding($true)))
        $ids = @(Get-HUThemeList -AppRoot $r | ForEach-Object Id)
        ($ids -join ',') | Should -Be 'dark,light,zzz'
    }
    It 'ohne Themes-Ordner: nur das eingebaute Dunkel, kein Fehler' {
        $l = @(Get-HUThemeList -AppRoot (Join-Path $script:Tmp 'gibt-es-nicht'))
        $l.Count | Should -Be 1
        $l[0].Id | Should -BeExactly 'dark'; $l[0].Name | Should -Be 'Dunkel'; $l[0].Kind | Should -BeExactly 'dark'
    }
    It 'fehlt dark.json, steht Dunkel trotzdem zuerst in der Liste, light und eigene folgen' {
        $r = New-TempRoot
        [void](Copy-Item (Join-Path $script:Root 'Themes\light.json') (Join-Path $r 'Themes'))
        $t = New-ValidTheme; $t.id = 'zzz'
        [void](Write-ThemeFile (Join-Path $r 'Themes') 'zzz' $t)
        $l = @(Get-HUThemeList -AppRoot $r)
        ($l.Id -join ',') | Should -Be 'dark,light,zzz'
        $l[0].Name | Should -Be 'Dunkel'
    }
    It 'eine kaputte dark.json: Dunkel steht trotzdem in der Liste' {
        $r = New-TempRoot
        [IO.File]::WriteAllText((Join-Path $r 'Themes\dark.json'), 'x', (New-Object System.Text.UTF8Encoding($true)))
        @(Get-HUThemeList -AppRoot $r | ForEach-Object Id) | Should -Contain 'dark'
    }
}

Describe 'Einbindung: Pinsel, Fenster, Einstellung, Protokollfarben, Main' {
    BeforeAll {
        $script:Window = $null; $script:AppIcon = $null
        . (Join-Path $script:Root 'Functions\UI-Common.ps1')
        . (Join-Path $script:Root 'Functions\UI-Settings.ps1')
    }
    AfterAll { Use-Theme 'dark' }

    It 'Get-HUBrush: dunkel exakt die Farbe, hell je Rolle umgesetzt' {
        Use-Theme 'dark'
        (Get-HUBrush '#1E1E1E' 'Bg').Color.ToString() | Should -Be '#FF1E1E1E'
        (Get-HUBrush '#3A321F').Color.ToString() | Should -Be '#FF3A321F'
        Use-Theme 'light'
        (Get-HUBrush '#1E1E1E' 'Bg').Color.ToString() | Should -Be '#FFF2EFE9'
        (Get-HUBrush '#CCCCCC' 'Fg').Color.ToString() | Should -Be '#FF2E2A24'
        (Get-HUBrush '#CCCCCC').Color.ToString() | Should -Be '#FF2E2A24'    # Auto
        (Get-HUBrush '#E0E0E0' 'Fg').Color.ToString() | Should -Be '#FF24211C' # Rahmen des Standardknopfs im Dialog
        (Get-HUBrush '#1976D2' 'Btn').Color.ToString() | Should -Be '#FF1976D2'
    }
    It 'Get-HUBrush: ungueltige Farbe gibt weiss und wirft nicht' {
        Use-Theme 'light'
        { Get-HUBrush 'kein-brush' 'Bg' } | Should -Not -Throw
    }
    It 'Abweichend-Tonung ist im hellen Schema ein helles Gelb, im dunklen unveraendert' {
        Use-Theme 'dark'
        ConvertTo-HUThemeColor '#3A321F' 'Bg' | Should -Be '#3A321F'
        Use-Theme 'light'
        $c = ConvertTo-HUThemeColor '#3A321F' 'Bg'
        $c | Should -Not -Be '#3A321F'
        $c | Should -Be '#FFF3D6'
    }
    It 'New-HUWindow setzt das Schema fuer Name und XamlText um' {
        Use-Theme 'dark'
        $d = New-HUWindow 'SettingsWindow'
        $d.Window.Background.Color.ToString() | Should -Be '#FF1E1E1E'
        Use-Theme 'light'
        $h = New-HUWindow 'SettingsWindow'
        $h.Window.Background.Color.ToString() | Should -Be '#FFF2EFE9'
        $t = New-HUWindow -XamlText '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="#1E1E1E"/>'
        $t.Window.Background.Color.ToString() | Should -Be '#FFF2EFE9'
    }
    It 'Einstellungsfenster hat die Auswahl Farbschema, der Kopf den Knopf, beide mit Tooltip' {
        $s = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\SettingsWindow.xaml'), [Text.Encoding]::UTF8)
        $m = [regex]::Match($s, '<ComboBox[^>]*x:Name="cmbTheme"[^>]*>')
        $m.Success | Should -BeTrue
        $m.Value | Should -Match 'ToolTip="[^"]+Neustart'
        $m.Value | Should -Match 'App-Modus'
        $mw = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\MainWindow.xaml'), [Text.Encoding]::UTF8)
        $b = [regex]::Match($mw, '<Button[^>]*x:Name="btnTheme"[^>]*>')
        $b.Success | Should -BeTrue
        $b.Value | Should -Match 'ToolTip="[^"]+'
    }
    It 'ui.theme: Standard dark, vorhandener Wert bleibt, Vorlage der Einstellungen hat das Feld' {
        $s = Initialize-HUSettingsDefaults ([pscustomobject]@{ tenants = @(); ui = [pscustomobject]@{ startTab = 'Last' } })
        $s.ui.theme | Should -BeExactly 'dark'
        $s2 = Initialize-HUSettingsDefaults ([pscustomobject]@{ tenants = @(); ui = [pscustomobject]@{ theme = 'light' } })
        $s2.ui.theme | Should -BeExactly 'light'
        $ex = [IO.File]::ReadAllText((Join-Path $script:Root 'Config\settings.example.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        $ex.ui.theme | Should -BeExactly 'dark'
    }
    It 'Protokoll: Set-HULogColors setzt Stufen und Standardfarbe, ist exportiert' {
        $mod = Import-Module (Join-Path $script:Root 'Core\HU.Logging.psm1') -Force -DisableNameChecking -PassThru
        try {
            (Get-Command Set-HULogColors -Module $mod.Name -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            & $mod { $script:LevelColors['ERROR'] } | Should -Be '#D32F2F'
            & $mod { $script:LogDefaultColor } | Should -Be '#CCCCCC'
            & $mod { Set-HULogColors @{ ERROR = '#C62828'; Text = '#2E2A24'; Unsinn = '#000000' } }
            & $mod { $script:LevelColors['ERROR'] } | Should -Be '#C62828'
            & $mod { $script:LevelColors.ContainsKey('UNSINN') } | Should -BeFalse
            & $mod { $script:LogDefaultColor } | Should -Be '#2E2A24'
            & $mod { $script:LevelColors['OK'] } | Should -Be '#4CAF50'   # nicht genannte Stufen bleiben
        } finally { Remove-Module $mod.Name -Force -ErrorAction SilentlyContinue }
    }
    It 'Main.ps1: UI-Theme vor UI-Common (auch ohne Oberflaeche), Einstellung wird geladen, Starttest-Schalter, Knopf, Protokollfarben' {
        $main = [IO.File]::ReadAllText((Join-Path $script:Root 'Main.ps1'), [Text.Encoding]::UTF8)
        $main.IndexOf("'UI-Theme', 'UI-Common'") | Should -BeGreaterThan 0
        $main | Should -Match "@\('UI-Theme', 'UI-Common', 'UI-Settings'\)"
        $main | Should -Match 'Initialize-HUTheme -Setting \$__ts -AppRoot \$script:AppRoot'
        $main.IndexOf('Initialize-HUTheme') | Should -BeLessThan $main.IndexOf('Show-SecretSetupDialog')
        $main | Should -Match 'HUMT_SMOKE_THEME'
        $main | Should -Match "\`$steps \+= 'Hell'"
        $main | Should -Match "Controls\['btnTheme'\]"
        $main | Should -Match 'Switch-HUThemeQuick'
        $main | Should -Match 'Set-HULogColors'
        $main | Should -Match "Get-HUBrush \`$col 'Fg'"
    }
    It 'Switch-HUThemeQuick und Test-HURestartAllowed sind vorhanden' {
        Get-Command Switch-HUThemeQuick -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Test-HURestartAllowed -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Test-HUCloseAllowed -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}

Describe 'Farbschema umschalten: Switch-HUThemeQuick und Test-HURestartAllowed (Fenster und Neustart gestubbt)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\UI-Settings.ps1')
        $script:Calls = New-Object System.Collections.ArrayList
        $script:Window = $null
        $script:Answer = $true; $script:Discard = $true; $script:JobRunning = $false; $script:SaveOk = $true; $script:SaveThrows = $false; $script:DiscardThrows = $false
        function Confirm-HU { param([string]$Text, [string]$Title = 'HU-MultiTenant', [switch]$Warning, $Owner = $null) [void]$script:Calls.Add("Confirm:$Title"); $script:LastConfirm = $Text; $script:LastWarning = [bool]$Warning; return $script:Answer }
        function Confirm-HUQSDiscard { param([string]$Action = 'fortfahren') if ($script:DiscardThrows) { throw 'Test-Ausnahme' }; return $script:Discard }
        function Test-HUJobRunning { param([string]$Name) return $script:JobRunning }
        function Show-HUMessage { param([string]$Text, [string]$Title = 'HU-MultiTenant', $Icon = 'Info', $Owner = $null) [void]$script:Calls.Add('Message') }
        function Save-HUSettings { [void]$script:Calls.Add('Save'); if ($script:SaveThrows) { throw 'Test-Ausnahme' }; return $script:SaveOk }
        function Restart-HUApp { [void]$script:Calls.Add('Restart') }
        function Write-HULogOK { param($Message) }
    }
    BeforeEach {
        $script:Calls.Clear(); $script:LogLines.Clear()
        $script:Answer = $true; $script:Discard = $true; $script:JobRunning = $false; $script:SaveOk = $true; $script:SaveThrows = $false; $script:DiscardThrows = $false
        $script:IsRunning = $false; $script:LastConfirm = ''; $script:LastWarning = $false
        $script:HUJobs = @{}; $script:MA = $null; $script:TSU = $null
        $script:Settings = [pscustomobject]@{ ui = [pscustomobject]@{ theme = 'dark' } }
    }
    AfterAll { Use-Theme 'dark' }

    It 'hell -> dunkel: speichert dark und startet neu' {
        Use-Theme 'light'
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'dark'
        ($script:Calls -join ',') | Should -Be 'Confirm:Farbschema,Save,Restart'
    }
    It 'dunkel -> hell: speichert light und startet neu' {
        Use-Theme 'dark'
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'light'
        ($script:Calls -join ',') | Should -Be 'Confirm:Farbschema,Save,Restart'
    }
    It 'Rueckfrage nennt bei "Wie Windows" (system), dass es ausgeschaltet wird; bei dark und light kein Zusatz' {
        $script:Settings.ui.theme = 'system'
        Mock Get-HUWindowsAppTheme { 'light' }
        Use-Theme 'system'
        Switch-HUThemeQuick
        $script:LastConfirm | Should -BeLike 'Farbschema auf Dunkel umstellen?*'
        $script:LastConfirm | Should -Match '"Wie Windows" wird dabei ausgeschaltet\. Wieder einschalten unter Einstellungen > Allgemein\.'
        $script:Settings.ui.theme | Should -BeExactly 'dark'
        foreach ($t in 'dark', 'light') {
            $script:Settings.ui.theme = $t; $script:LastConfirm = ''
            Use-Theme $t
            Switch-HUThemeQuick
            $script:LastConfirm | Should -Match 'startet dafür neu\.$'
            $script:LastConfirm | Should -Not -Match 'Wie Windows'
        }
    }
    It 'wie Windows (gerade hell) -> dark, (gerade dunkel) -> light' {
        $script:Settings.ui.theme = 'system'
        Mock Get-HUWindowsAppTheme { 'light' }
        Use-Theme 'system'
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'dark'
        $script:Calls.Clear(); $script:Settings.ui.theme = 'system'
        Mock Get-HUWindowsAppTheme { 'dark' }
        Use-Theme 'system'
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'light'
    }
    It 'Nein bei der Rueckfrage: nichts gespeichert, kein Neustart' {
        Use-Theme 'dark'
        $script:Answer = $false
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'dark'
        ($script:Calls -join ',') | Should -Be 'Confirm:Farbschema'
    }
    It 'Speichern schlaegt fehl: Hinweis, kein Neustart' {
        Use-Theme 'dark'
        $script:SaveOk = $false
        Switch-HUThemeQuick
        ($script:Calls -join ',') | Should -Be 'Confirm:Farbschema,Save,Message'
        # der neue Wert bleibt nicht im Speicher stehen
        $script:Settings.ui.theme | Should -BeExactly 'dark'
    }
    It 'Speichern wirft einen Fehler: Hinweis, kein Neustart, alter Wert zurueck' {
        Use-Theme 'dark'
        $script:SaveThrows = $true
        Switch-HUThemeQuick
        ($script:Calls -join ',') | Should -Be 'Confirm:Farbschema,Save,Message'
        $script:Settings.ui.theme | Should -BeExactly 'dark'
    }
    It 'Speichern schlaegt fehl, Einstellung war vorher gar nicht gesetzt: Eintrag ist danach wieder weg' {
        Use-Theme 'dark'
        $script:Settings = [pscustomobject]@{ ui = [pscustomobject]@{} }
        $script:SaveOk = $false
        Switch-HUThemeQuick
        $script:Settings.ui.PSObject.Properties['theme'] | Should -BeNullOrEmpty
        $script:Calls | Should -Not -Contain 'Restart'
    }
    It 'laufender Auftrag und Nein: nichts gespeichert, kein Neustart' {
        Use-Theme 'dark'
        $script:JobRunning = $true; $script:HUJobs = @{ Apps = @{ Done = $false } }
        # erste Rueckfrage (Umstellen) Ja, zweite (Auftrag laeuft noch) Nein: die Funktion gilt nur in diesem Test
        $script:AskCount = 0
        function Confirm-HU { param([string]$Text, [string]$Title = 'HU-MultiTenant', [switch]$Warning, $Owner = $null) $script:AskCount++; [void]$script:Calls.Add("Confirm:$Title"); return ($script:AskCount -le 1) }
        Switch-HUThemeQuick
        $script:Settings.ui.theme | Should -BeExactly 'dark'
        $script:Calls | Should -Not -Contain 'Save'
        $script:Calls | Should -Not -Contain 'Restart'
        $script:AskCount | Should -Be 2
    }
    It 'Test-HURestartAllowed: ohne Laufendes sofort ja, ungespeichertes Snippet oder Nein bricht ab' {
        Test-HURestartAllowed | Should -BeTrue
        $script:Discard = $false
        Test-HURestartAllowed | Should -BeFalse
        $script:Discard = $true; $script:IsRunning = $true; $script:Answer = $false
        Test-HURestartAllowed | Should -BeFalse
        $script:Answer = $true
        Test-HURestartAllowed | Should -BeTrue
    }
    It 'Test-HURestartAllowed: ein laufender fremder Auftrag (hier MaRun) fragt nach, Nein bricht ab, Ja erlaubt; der lesbare Name steht in der Rueckfrage' {
        $script:JobRunning = $true; $script:HUJobs = @{ MaRun = @{ Done = $false } }
        $script:Answer = $false
        Test-HURestartAllowed | Should -BeFalse
        $script:LastConfirm | Should -Match 'Muster anwenden'
        $script:LastConfirm | Should -Not -Match 'MaRun'
        $script:LastConfirm | Should -Match 'beim Neustart abgebrochen'
        $script:Answer = $true
        Test-HURestartAllowed | Should -BeTrue
        @($script:Calls).Count | Should -Be 2
    }
    It 'Test-HURestartAllowed: beendete Auftraege fragen nicht nach, mehrere werden alle genannt' {
        $script:JobRunning = $false; $script:HUJobs = @{ Fertig = @{ Done = $true }; Alt = @{ Done = $true } }
        Test-HURestartAllowed | Should -BeTrue
        @($script:Calls).Count | Should -Be 0
        $script:JobRunning = $true; $script:HUJobs = @{ BakRestore = 1; IntAct = 1; 'Sec-3-x' = 1 }
        $script:Answer = $false
        Test-HURestartAllowed | Should -BeFalse
        $script:LastConfirm | Should -Match 'Wiederherstellen'
        $script:LastConfirm | Should -Match 'Apps in Intune \(Aktion\)'
        $script:LastConfirm | Should -Match 'Sicherheitskatalog'
        $script:LastConfirm | Should -Not -Match 'BakRestore|Sec-3-x'
    }
    It 'Test-HURestartAllowed: laufendes Anwenden eines Musters verhindert den Neustart ohne Rueckfrage, nur eine Meldung' {
        $script:MA = @{ Running = $true }
        Test-HURestartAllowed | Should -BeFalse
        ($script:Calls -join ',') | Should -Be 'Message'
        $script:MA = @{ Running = $false }
        Test-HURestartAllowed | Should -BeTrue
    }
    It 'Test-HURestartAllowed: laufende Tenant-Einrichtung (Phase Work) verhindert den Neustart, Idle und Login nicht' {
        $script:TSU = @{ Phase = 'Work' }
        Test-HURestartAllowed | Should -BeFalse
        ($script:Calls -join ',') | Should -Be 'Message'
        $script:Calls.Clear()
        foreach ($p in 'Idle', 'Login') { $script:TSU = @{ Phase = $p }; Test-HURestartAllowed | Should -BeTrue }
        @($script:Calls).Count | Should -Be 0
    }
    It 'Test-HURestartAllowed: ohne Auftragsverwaltung, Muster und Einrichtung (Variablen fehlen, StrictMode) kein Fehler, Neustart erlaubt' {
        Remove-Variable -Name HUJobs, MA, TSU -Scope Script -ErrorAction SilentlyContinue
        { Test-HURestartAllowed } | Should -Not -Throw
        Test-HURestartAllowed | Should -BeTrue
        $script:LogLines.Count | Should -Be 0
    }
    It 'Test-HURestartAllowed: eine Ausnahme in der Pruefung ergibt $false (kein Neustart) und eine Protokollzeile' {
        $script:DiscardThrows = $true
        Test-HURestartAllowed | Should -BeFalse
        @($script:LogLines | Where-Object { $_ -match '^WARN .*Neustart nicht freigegeben' }).Count | Should -Be 1
        $script:Calls | Should -Not -Contain 'Restart'
    }

    # --- Test-HUCloseAllowed: gemeinsame Pruefung fuer Beenden und Neustart ---
    It 'Schliessen: ein laufender fremder Auftrag fragt genau einmal, nennt ihn lesbar und warnt' {
        $script:JobRunning = $true; $script:HUJobs = @{ BakRestore = 1 }
        $script:Answer = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        @($script:Calls).Count | Should -Be 1
        $script:LastConfirm | Should -Be 'Es laufen noch Hintergrundaufträge (Wiederherstellen). Sie werden beim Beenden abgebrochen. Trotzdem beenden?'
        $script:LastWarning | Should -BeTrue
        $script:Answer = $true
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
    }
    It 'Schliessen: beendete Auftraege fragen nicht, ohne Laufendes keine Rueckfrage' {
        $script:JobRunning = $false; $script:HUJobs = @{ Fertig = @{ Done = $true }; BakRestore = @{ Done = $true } }
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        Test-HUCloseAllowed | Should -BeTrue
        @($script:Calls).Count | Should -Be 0
    }
    It 'Schliessen: gleiche Anwendertexte werden nur einmal genannt, unbekannte Namen (Zusatzmodule) bleiben unveraendert, mehr als 5 werden gekuerzt' {
        $script:JobRunning = $true; $script:HUJobs = @{ 'Sec-1-a' = 1; 'Sec-1-b' = 1; 'SecChg-2-a' = 1; 'ZusatzJob' = 1; 'AP-Laden' = 1 }
        $script:Answer = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        ([regex]::Matches($script:LastConfirm, 'Sicherheitskatalog')).Count | Should -Be 1
        $script:LastConfirm | Should -Match 'ZusatzJob'
        $script:LastConfirm | Should -Match 'Autopilot'
        $script:HUJobs = @{ Apps = 1; Rem = 1; MaRun = 1; BakRestore = 1; AppBackup = 1; Z1 = 1; Z2 = 1 }
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        $script:LastConfirm | Should -Match 'und 2 weitere'
    }
    It 'Zuordnung der Auftragsnamen: genauer Name vor Anfang, Gross-/Kleinschreibung egal, unbekannt unveraendert' {
        Get-HUJobLabel 'Apps' | Should -Be $script:HUJobLabels['Apps']
        Get-HUJobLabel 'Rem' | Should -Be 'Wartung'
        Get-HUJobLabel 'Sec-12-key' | Should -Be 'Sicherheitskatalog'
        Get-HUJobLabel 'sec-12-key' | Should -Be 'Sicherheitskatalog'
        Get-HUJobLabel 'Secret-Job' | Should -Be 'Secret-Job'
        Get-HUJobLabel 'Unbekannt' | Should -Be 'Unbekannt'
        $keep = $script:HUJobLabels
        Remove-Variable -Name HUJobLabels -Scope Script
        try { Get-HUJobLabel 'Apps' | Should -Be 'Apps' } finally { $script:HUJobLabels = $keep }
    }
    It 'Zuordnung: jeder genaue Name kommt wirklich als Start-HUJob -Name im Code vor' {
        $code = ((Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) + (Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File -Filter *.ps1) | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) }) -join "`n"
        $missing = @($script:HUJobLabels.Keys | Where-Object {
                $k = "$_"
                if ($k.EndsWith('*')) { $pre = $k.TrimEnd('*'); -not ($code.Contains("Start-HUJob -Name `"$pre") -or $code.Contains("Start-HUJob -Name '$pre")) }
                else { -not $code.Contains("Start-HUJob -Name '$k'") }
            })
        $missing | Should -BeNullOrEmpty
    }
    It 'Zuordnung: jeder feste Auftragsname im Code hat einen lesbaren Text (neue Auftraege fallen auf)' {
        $files = @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File -Filter *.ps1)
        $names = @{}
        foreach ($f in $files) {
            $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            foreach ($m in [regex]::Matches($t, 'Start-HUJob\s+-Name\s+[''"]([A-Za-z][A-Za-z0-9-]*)')) { $names[$m.Groups[1].Value] = $f.Name }
        }
        $names.Count | Should -BeGreaterThan 40
        $noLabel = @($names.Keys | Where-Object { (Get-HUJobLabel "$_") -ceq "$_" } | Sort-Object | ForEach-Object { "$_ ($($names[$_]))" })
        $noLabel | Should -BeNullOrEmpty -Because 'jeder Auftrag braucht eine Zeile in $script:HUJobLabels (Functions\UI-Settings.ps1)'
    }
    It 'Sperre und Schliessen: aus der Sperre keine Rueckfragen, Sperrfenster schliesst mit, kein Sperren ohne Hauptfenster' {
        $main = [IO.File]::ReadAllText((Join-Path $script:Root 'Main.ps1'), [Text.Encoding]::UTF8)
        $main | Should -Match 'if \(-not \$script:SkipCloseChecks -and -not \$script:LockActive\) \{'
        $h = [regex]::Match($main, '(?s)\$script:Window\.Add_Closing\(\{.*?Close-HULockDialog').Value
        $h | Should -Not -BeNullOrEmpty
        $h.IndexOf('Test-HUCloseAllowed') | Should -BeLessThan $h.IndexOf('Close-HULockDialog')
        $lock = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Lock.ps1'), [Text.Encoding]::UTF8)
        $lock | Should -Match 'if \(\$script:LockClosing -or -not \$script:Window\) \{ return \}'
        $lock | Should -Match '\$script:LockDlg = @\{ W = \$w; State = \$state \}'
        # fail-closed: Inhalt und LockActive nur nach erfolgreichem Entsperren zuruecksetzen
        $fin = [regex]::Match($lock, '(?s)try \{ Show-HULockDialog -AtStart:\$AtStart \} finally \{(.*?)\r?\n    \}\r?\n\}').Groups[1].Value
        $fin | Should -Not -BeNullOrEmpty
        $guard = [regex]::Match($fin, '(?s)if \(\$script:LockUnlocked\) \{(.*)\}').Groups[1].Value
        $guard | Should -Match "Visibility = 'Visible'"
        $guard | Should -Match '\$script:LockActive = \$false'
        ($fin.Replace($guard, '')) | Should -Not -Match "Visibility = 'Visible'|LockActive = \`$false"
        $lock | Should -Match '\$script:LockUnlocked = \[bool\]\(\$state\.Unlocked -and -not \$state\.Exit\)'
        $lock | Should -Match '\$script:LockExitPending = \$true'
        $main | Should -Match '(?s)if \(-not \$closeOk -and -not \$lockExit\) \{\s*\$e\.Cancel = \$true.*?Start-HULockAfterClose.*?return'
        # waehrend der Rueckfragen beim Beenden: kein Sperrfenster, Inhalt sofort verbergen, Sperre nachholen
        $main | Should -Match '(?s)\$script:CloseChecking = \$true.*?try \{ \$closeOk = Test-HUCloseAllowed ''beenden'' \} finally \{ \$script:CloseChecking = \$false \}'
        $due = [regex]::Match($lock, '(?s)if \(\$script:CloseChecking\) \{(.*?)\r?\n    \}').Groups[1].Value
        $due | Should -Match '\$script:LockDue = \$true'
        $due | Should -Match "Visibility = 'Hidden'"
        $due | Should -Match 'return'
        $due | Should -Not -Match 'Show-HULockDialog'
        $lock | Should -Match '(?s)function Start-HULockAfterClose \{.*?if \(-not \$script:LockDue\) \{ return \}.*?BeginInvoke'
        # Verhalten von Close-HULockDialog mit Stellvertretern (ohne Fenster)
        $fn = [regex]::Match($lock, '(?s)function Close-HULockDialog \{.*?\r?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($fn))
        $closed = @{ N = 0 }
        $w = New-Object psobject
        $w | Add-Member -MemberType ScriptMethod -Name Close -Value { $closed.N++ }.GetNewClosure()
        $timer = New-Object psobject
        $stopped = @{ N = 0 }
        $timer | Add-Member -MemberType ScriptMethod -Name Stop -Value { $stopped.N++ }.GetNewClosure()
        $st = @{ Unlocked = $false; Exit = $false }
        $script:LockTimer = $timer; $script:LockDlg = @{ W = $w; State = $st }; $script:LockClosing = $false
        Close-HULockDialog
        $script:LockClosing | Should -BeTrue
        $st.Exit | Should -BeTrue
        $closed.N | Should -Be 1
        $stopped.N | Should -Be 1
        $script:LockDlg | Should -BeNullOrEmpty
        { Close-HULockDialog } | Should -Not -Throw   # ohne offenes Sperrfenster: nichts zu tun
        $closed.N | Should -Be 1
        $script:LockTimer = $null
    }
    It 'Beenden aus der Sperre: ohne Rueckfragen (SkipCloseChecks vor Close) und ohne den Inhalt sichtbar zu machen' {
        $t = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Lock.ps1'), [Text.Encoding]::UTF8)
        $m = [regex]::Match($t, '(?s)if \(\$state\.Exit\) \{(.*?)\r?\n    \}')
        $m.Success | Should -BeTrue
        $body = $m.Groups[1].Value
        $body | Should -Match '\$script:SkipCloseChecks = \$true'
        $body.IndexOf('$script:SkipCloseChecks = $true') | Should -BeLessThan $body.IndexOf('$script:Window.Close()')
        $body | Should -Not -Match "Visibility = 'Visible'"
        $body | Should -Not -Match 'LockActive = \$false'
    }
    It 'Schliessen: laufendes Muster-Anwenden wird nicht verboten, aber mit Warnung gefragt (Nein bricht ab); der Auftrag MaRun wird nicht zusaetzlich genannt' {
        $script:MA = @{ Running = $true }
        $script:JobRunning = $true; $script:HUJobs = @{ MaRun = 1 }
        $script:Answer = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        @($script:Calls).Count | Should -Be 1
        $script:LastConfirm | Should -Match 'Muster angewendet'
        $script:LastConfirm | Should -Match 'Zwischenstand'
        $script:LastConfirm | Should -Match 'Trotzdem beenden\?'
        $script:LastWarning | Should -BeTrue
        $script:Calls.Clear()
        $script:Answer = $true
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        @($script:Calls).Count | Should -Be 1    # nur die Warnung, keine zweite Rueckfrage zu MaRun
        $script:Calls | Should -Not -Contain 'Message'
    }
    It 'Schliessen: ein weiterer Auftrag neben dem laufenden Muster-Anwenden fragt zusaetzlich einmal' {
        $script:MA = @{ Running = $true }
        $script:JobRunning = $true; $script:HUJobs = @{ MaRun = 1; BakRestore = 1 }
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        @($script:Calls).Count | Should -Be 2
        $script:LastConfirm | Should -Match 'Wiederherstellen'
        $script:LastConfirm | Should -Not -Match 'Muster anwenden'
    }
    It 'Neustart bei laufendem Muster-Anwenden: Meldung, kein Neustart, keine Rueckfrage' {
        $script:MA = @{ Running = $true }
        Test-HUCloseAllowed 'neu starten' | Should -BeFalse
        ($script:Calls -join ',') | Should -Be 'Message'
    }
    It 'Schliessen: laufende Tenant-Einrichtung (Phase Work) fragt mit Warnung, Idle und Login nicht; Neustart lehnt mit Meldung ab' {
        $script:TSU = @{ Phase = 'Work' }
        $script:Answer = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        @($script:Calls).Count | Should -Be 1
        $script:LastConfirm | Should -Match 'Tenant-Einrichtung'
        $script:LastWarning | Should -BeTrue
        $script:Calls.Clear(); $script:Answer = $true
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        $script:Calls.Clear()
        Test-HUCloseAllowed 'neu starten' | Should -BeFalse
        ($script:Calls -join ',') | Should -Be 'Message'
        $script:Calls.Clear()
        foreach ($ph in 'Idle', 'Login') { $script:TSU = @{ Phase = $ph }; Test-HUCloseAllowed 'beenden' | Should -BeTrue }
        @($script:Calls).Count | Should -Be 0
    }
    It 'Schliessen: laufende Extension und ungespeichertes Snippet fragen wie bisher' {
        $script:IsRunning = $true; $script:Answer = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        $script:LastConfirm | Should -Be 'Eine Extension laeuft noch. Trotzdem beenden?'
        $script:IsRunning = $false; $script:Discard = $false
        Test-HUCloseAllowed 'beenden' | Should -BeFalse
        $script:Discard = $true
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
    }
    It 'Schliessen: eine Ausnahme in der Pruefung erlaubt das Beenden ($true), schreibt eine Protokollzeile und zeigt keine Meldung; der Neustart bleibt verboten' {
        $script:DiscardThrows = $true
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        @($script:LogLines | Where-Object { $_ -match '^WARN Beenden: Pruefung .*Test-Ausnahme' }).Count | Should -Be 1
        $script:Calls | Should -Not -Contain 'Message'
        $script:LogLines.Clear()
        Test-HUCloseAllowed 'neu starten' | Should -BeFalse
        @($script:LogLines | Where-Object { $_ -match '^WARN .*Neustart nicht freigegeben' }).Count | Should -Be 1
        $script:Calls | Should -Contain 'Message'
    }
    It 'Schliessen: ohne Auftragsverwaltung, Muster, Einrichtung und IsRunning (Variablen fehlen, StrictMode) kein Fehler' {
        Remove-Variable -Name HUJobs, MA, TSU, IsRunning -Scope Script -ErrorAction SilentlyContinue
        { Test-HUCloseAllowed 'beenden' } | Should -Not -Throw
        Test-HUCloseAllowed 'beenden' | Should -BeTrue
        $script:LogLines.Count | Should -Be 0
        @($script:Calls).Count | Should -Be 0
    }
    It 'Test-HURestartAllowed ruft die gemeinsame Funktion auf (Quelltext), der Closing-Handler in Main.ps1 ebenfalls und fragt nicht mehr einzeln nach Apps/Rem' {
        $ui = [IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Settings.ps1'), [Text.Encoding]::UTF8)
        $fn = [regex]::Match($ui, '(?s)function Test-HURestartAllowed \{.*?\r?\n\}').Value
        $fn | Should -Match "Test-HUCloseAllowed -Action 'neu starten'"
        $main = [IO.File]::ReadAllText((Join-Path $script:Root 'Main.ps1'), [Text.Encoding]::UTF8)
        $h = [regex]::Match($main, '(?s)Window\.Add_Closing\(\{.*?\r?\n\}\)').Value
        $h | Should -Not -BeNullOrEmpty
        $h | Should -Match "if \(-not \`$script:SkipCloseChecks -and -not \`$script:LockActive\) \{"
        $h | Should -Match "\`$closeOk = Test-HUCloseAllowed 'beenden'"
        $h | Should -Not -Match "Test-HUJobRunning|Confirm-HUQSDiscard|'Apps'|'Rem'"
        # der uebrige Teil des Handlers (Fensterzustand, Tenants trennen, Aufraeumen) bleibt
        $h | Should -Match 'Save-HUWindowState'
        $h | Should -Match 'Close-AsyncPool'
    }
}

Describe 'Windows-App-Modus: Get-HUWindowsAppTheme (Registry-Zugriff gemockt)' {
    It 'Wert 1 = light, ausgelesen wird AppsUseLightTheme unter ...\Themes\Personalize' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 1 } }
        Get-HUWindowsAppTheme | Should -BeExactly 'light'
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -like 'HKCU:*\Themes\Personalize' -and $Name -eq 'AppsUseLightTheme' }
    }
    It 'Wert 0 = dark' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 0 } }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
    }
    It 'Wert fehlt = dark' {
        Mock Get-ItemProperty { [pscustomobject]@{ Anderes = 1 } }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = $null } }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
    }
    It 'Schluessel fehlt (Get-ItemProperty liefert nichts) = dark' {
        Mock Get-ItemProperty { $null }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
    }
    It 'Zugriff wirft (Schluessel nicht vorhanden, keine Rechte) = dark' {
        Mock Get-ItemProperty { throw 'Der Pfad existiert nicht' }
        { Get-HUWindowsAppTheme } | Should -Not -Throw
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
    }
    It 'unerwartete Werte (2, Text) gelten als dark' {
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 2 } }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
        Mock Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 'hell' } }
        Get-HUWindowsAppTheme | Should -BeExactly 'dark'
    }
}

Describe 'Farben am Schema vorbei: keine direkten Pinsel, keine neuen festen Farben ohne Rolle' {
    BeforeAll {
        $script:ColorFiles = @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File -Filter *.ps1) + @(Get-Item (Join-Path $script:Root 'Main.ps1'))
        # Ausnahmen: Datei, Kennwort der Stelle (steht in der Zeile des Treffers; leer = ganze Datei), Grund
        $script:BrushExceptions = @(
            @{ File = 'UI-Common.ps1'; Key = 'BrushConverter'; Reason = 'Get-HUBrush selbst: hier wird das Schema angewendet' }
            @{ File = 'UI-Common.ps1'; Key = 'Brushes]::White'; Reason = 'Get-HUBrush: Rueckfall bei ungueltiger Farbe' }
            @{ File = 'UI-Common.ps1'; Key = 'ColorConverter'; Reason = 'Abweichend-Tonung: Farbe wird davor per ConvertTo-HUThemeColor umgesetzt' }
            @{ File = 'UI-Analyse.ps1'; Key = 'FormattedText'; Reason = 'nur Breitenmessung der Auswahlliste, die Farbe wird nie gezeichnet' }
            @{ File = 'UI-Remote.ps1'; Key = 'DrawRectangle'; Reason = 'gezeichnetes Symbol fuer das Handy (Web-App-Symbol), kein Fenster der App' }
            @{ File = 'UI-Splash.ps1'; Key = ''; Reason = 'Startbildschirm bleibt wie er ist' }
        )
        # Obergrenze je Datei: Get-HUBrush mit festem '#...'-Wert OHNE Rolle. Nicht aufgefuehrte Dateien: 0. Nur kleiner werden lassen.
        $script:RoleCeiling = @{
            'UI-Analyse.ps1' = 0; 'UI-AppBackup.ps1' = 0; 'UI-Apps.ps1' = 0; 'UI-Common.ps1' = 0; 'UI-EntraRestore.ps1' = 0
            'UI-Extensions.ps1' = 0; 'UI-GroupPicker.ps1' = 0; 'UI-IntuneApps.ps1' = 0; 'UI-IntuneRem.ps1' = 0; 'UI-Jobs.ps1' = 0
            'UI-Maint.ps1' = 0; 'UI-Muster.ps1' = 0; 'UI-MusterApply.ps1' = 0; 'UI-QSParams.ps1' = 0; 'UI-QuickScript.ps1' = 0
            'UI-Recipes.ps1' = 0; 'UI-Remote.ps1' = 0; 'UI-RemParams.ps1' = 0; 'UI-Security.ps1' = 0; 'UI-Settings.ps1' = 0
            'UI-Teams.ps1' = 0; 'UI-Tenants.ps1' = 0; 'UI-TenantSetup.ps1' = 0; 'UI-Update.ps1' = 0; 'UI-WinUpdates.ps1' = 0
            'Addon.ps1' = 0
        }
        $script:BrushExceptionUsed = @{}
    }
    It 'kein direkter BrushConverter, ColorConverter, SolidColorBrush, Color::From oder [Brushes]:: (ausser Transparent) ausserhalb der Ausnahmeliste' {
        $bad = New-Object System.Collections.ArrayList
        foreach ($f in $script:ColorFiles) {
            $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch 'BrushConverter|ColorConverter|SolidColorBrush|Color\]::From|Brushes\]::(?!Transparent)') { continue }
                if ($lines[$i].TrimStart().StartsWith('#')) { continue }
                $ok = $false
                foreach ($e in $script:BrushExceptions) {
                    if ($e.File -eq $f.Name -and (-not $e.Key -or $lines[$i].Contains($e.Key))) { $ok = $true; $script:BrushExceptionUsed["$($e.File)|$($e.Key)"] = $true }
                }
                if (-not $ok) { [void]$bad.Add("$($f.Name):$($i + 1)") }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "diese Stellen setzen Farben am Schema vorbei (Get-HUBrush mit Rolle oder ConvertTo-HUThemeColor, sonst mit Grund in die Ausnahmeliste): $($bad -join ', ')"
    }
    It 'jede Ausnahme mit Kennwort trifft noch eine Stelle (keine veralteten Eintraege)' {
        foreach ($e in $script:BrushExceptions) {
            if (-not $e.Key) { continue }   # ganze Datei: darf auch ohne Treffer bleiben
            $script:BrushExceptionUsed.ContainsKey("$($e.File)|$($e.Key)") | Should -BeTrue -Because "$($e.File) / $($e.Key)"
        }
    }
    It 'Get-HUBrush mit festem #-Wert ohne Rolle: nie mehr als in der Tabelle' {
        $over = New-Object System.Collections.ArrayList
        foreach ($f in $script:ColorFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $calls = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Get-HUBrush' }, $true))
            $n = 0
            foreach ($c in $calls) { if (@($c.CommandElements).Count -le 2 -and $c.Extent.Text -match '#[0-9A-Fa-f]{6,8}') { $n++ } }
            $max = 0; if ($script:RoleCeiling.ContainsKey($f.Name)) { $max = $script:RoleCeiling[$f.Name] }
            if ($n -gt $max) { [void]$over.Add("$($f.Name): $n statt hoechstens $max") }
        }
        $over | Should -BeNullOrEmpty -Because "neue feste Farben brauchen eine Rolle (Get-HUBrush '#...' 'Fg' | 'Bg' | 'Border' | 'Btn' | 'BtnFg' | 'Status'): $($over -join '; ')"
    }
}

Describe 'Modus-Umschalter (Set-HUToggleLook) und Auswahlflaeche im hellen Schema' {
    BeforeAll {
        $script:Window = $null; $script:AppIcon = $null
        . (Join-Path $script:Root 'Functions\UI-Common.ps1')
        $script:FgProp = [System.Windows.Controls.Control]::ForegroundProperty
        function New-ToggleButton { return [System.Windows.Controls.Button]::new() }
        function Test-FgUnset($b) { return [object]::ReferenceEquals($b.ReadLocalValue($script:FgProp), [System.Windows.DependencyProperty]::UnsetValue) }
    }
    AfterAll { Use-Theme 'dark' }

    It 'dunkel: Hintergrund exakt der alte Wert (aktiv und inaktiv), Schrift nicht lokal gesetzt' {
        Use-Theme 'dark'
        $b = New-ToggleButton
        Set-HUToggleLook $b $true
        $b.Background.Color.ToString() | Should -Be '#FF1976D2'
        Test-FgUnset $b | Should -BeTrue
        Set-HUToggleLook $b $false
        $b.Background.Color.ToString() | Should -Be '#FF3E3E42'
        Test-FgUnset $b | Should -BeTrue
        Set-HUToggleLook $b $false '#1976D2' '#00695C'
        $b.Background.Color.ToString() | Should -Be '#FF00695C'
        Test-FgUnset $b | Should -BeTrue
    }
    It 'hell: aktiv = weisse Schrift auf ActiveColor' {
        Use-Theme 'light'
        $b = New-ToggleButton
        Set-HUToggleLook $b $true
        $b.Background.Color.ToString() | Should -Be '#FF1976D2'
        $b.Foreground.Color.ToString() | Should -Be '#FFFFFFFF'
        Set-HUToggleLook $b $true '#2E7D32'
        $b.Background.Color.ToString() | Should -Be '#FF2E7D32'
        $b.Foreground.Color.ToString() | Should -Be '#FFFFFFFF'
    }
    It 'hell: inaktiv = helle Feldflaeche und kein lokaler Schriftwert (auch nach aktiv)' {
        Use-Theme 'light'
        $b = New-ToggleButton
        Set-HUToggleLook $b $true
        Test-FgUnset $b | Should -BeFalse
        Set-HUToggleLook $b $false
        $b.Background.Color.ToString() | Should -Be (ConvertTo-HUThemeColor '#3E3E42' 'Bg').Replace('#', '#FF')
        $b.Background.Color.ToString() | Should -Be '#FFFFFDF9'
        Test-FgUnset $b | Should -BeTrue
    }
    It 'hell: inaktiv mit kraeftiger Farbe (#00695C bleibt) bekommt weisse Schrift' {
        Use-Theme 'light'
        $b = New-ToggleButton
        Set-HUToggleLook $b $false '#1976D2' '#00695C'
        $b.Background.Color.ToString() | Should -Be '#FF00695C'
        $b.Foreground.Color.ToString() | Should -Be '#FFFFFFFF'
        Set-HUToggleLook $b $true '#1976D2' '#00695C'
        $b.Background.Color.ToString() | Should -Be '#FF1976D2'
    }
    It 'ohne Knopf kein Fehler' {
        Use-Theme 'light'
        { Set-HUToggleLook $null $true } | Should -Not -Throw
    }
    It 'kein Aufrufer setzt Hintergrund oder Schrift eines Modus-Umschalters (btn...Mode...) mehr direkt' {
        $files = @(Get-ChildItem (Join-Path $script:Root 'Functions') -Filter *.ps1) + @(Get-ChildItem (Join-Path $script:Root 'Modules\Autopilot') -File -Filter *.ps1)
        $bad = New-Object System.Collections.ArrayList
        foreach ($f in $files) {
            if ($f.Name -eq 'UI-Common.ps1') { continue }   # Set-HUToggleLook selbst
            $lines = [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "\['btn\w*Mode\w*'\]\.(Background|Foreground)\s*=") { [void]$bad.Add("$($f.Name):$($i + 1)") }
            }
        }
        $bad | Should -BeNullOrEmpty -Because "Modus-Umschalter ueber Set-HUToggleLook setzen: $($bad -join ', ')"
    }
    It 'alle bekannten Umschalter laufen ueber Set-HUToggleLook' {
        $expect = @{
            'UI-Analyse.ps1'     = @('btnAnaModeAsg', 'btnAnaModeCmp', 'btnAnaModeBak', 'btnAnaModeSec')
            'UI-IntuneApps.ps1'  = @('btnAppModeLib', 'btnAppModeInt', 'btnAppModeUpd')
            'UI-IntuneRem.ps1'   = @('btnRemModeLib', 'btnRemModeInt')
            'UI-WinUpdates.ps1'  = @('btnRemModeWu')
        }
        foreach ($k in $expect.Keys) {
            $t = [IO.File]::ReadAllText((Join-Path (Join-Path $script:Root 'Functions') $k), [Text.Encoding]::UTF8)
            foreach ($n in $expect[$k]) { $t | Should -Match ("Set-HUToggleLook \`$c\['" + $n + "'\]") -Because "$k $n" }
        }
    }
    It 'hell: Auswahl in Listen (#094771, Rolle Bg) ist ein helles Blau mit gut lesbarer dunkler Schrift' {
        Use-Theme 'light'
        $sel = ConvertTo-HUThemeColor '#094771' 'Bg'
        $sel | Should -Be '#BFD6F0'
        $sel | Should -Not -Be (ConvertTo-HUThemeColor '#2A2D2E' 'Bg') -Because 'Auswahl muss sich vom Hover unterscheiden'
        function Get-RelLum([string]$h) {
            $v = foreach ($i in 1, 3, 5) { $x = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255.0; if ($x -le 0.03928) { $x / 12.92 } else { [math]::Pow(($x + 0.055) / 1.055, 2.4) } }
            return 0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2]
        }
        $fg = ConvertTo-HUThemeColor '#CCCCCC' 'Fg'
        $l1 = Get-RelLum $sel; $l2 = Get-RelLum $fg
        $ratio = ([math]::Max($l1, $l2) + 0.05) / ([math]::Min($l1, $l2) + 0.05)
        $ratio | Should -BeGreaterThan 7
    }
    It 'hell: Rolle Auto bleibt bei #3D6FB0 (Theme.xaml: Auswahlflaeche ohne Fokus mit weisser Schrift, White bleibt in Auto weiss)' {
        Use-Theme 'light'
        ConvertTo-HUThemeColor '#094771' 'Auto' | Should -Be '#3D6FB0'
        ConvertTo-HUThemeColor 'White' 'Auto' | Should -Be 'White'
    }
}
