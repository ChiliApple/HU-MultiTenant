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
    It 'fehlende Schema-Datei (Programmordner ohne Themes): dark, eine Warnzeile, kein Fehler' {
        $r = Join-Path $script:Tmp ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $r -Force)
        foreach ($s in 'light', 'dark', 'system') {
            $script:LogLines.Clear()
            { Initialize-HUTheme -Setting $s -AppRoot $r } | Should -Not -Throw
            Get-HUTheme | Should -BeExactly 'dark'
            Test-HULightTheme | Should -BeFalse
            $script:LogLines.Count | Should -Be 1 -Because $s
        }
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
    It 'ohne Themes-Ordner: leere Liste, kein Fehler' {
        @(Get-HUThemeList -AppRoot (Join-Path $script:Tmp 'gibt-es-nicht')).Count | Should -Be 0
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
    }
}

Describe 'Farbschema umschalten: Switch-HUThemeQuick und Test-HURestartAllowed (Fenster und Neustart gestubbt)' {
    BeforeAll {
        . (Join-Path $script:Root 'Functions\UI-Settings.ps1')
        $script:Calls = New-Object System.Collections.ArrayList
        $script:Window = $null
        $script:Answer = $true; $script:Discard = $true; $script:JobRunning = $false; $script:SaveOk = $true
        function Confirm-HU { param([string]$Text, [string]$Title = 'HU-MultiTenant', [switch]$Warning, $Owner = $null) [void]$script:Calls.Add("Confirm:$Title"); return $script:Answer }
        function Confirm-HUQSDiscard { param([string]$Action = 'fortfahren') return $script:Discard }
        function Test-HUJobRunning { param([string]$Name) return $script:JobRunning }
        function Show-HUMessage { param([string]$Text, [string]$Title = 'HU-MultiTenant', $Icon = 'Info', $Owner = $null) [void]$script:Calls.Add('Message') }
        function Save-HUSettings { [void]$script:Calls.Add('Save'); return $script:SaveOk }
        function Restart-HUApp { [void]$script:Calls.Add('Restart') }
        function Write-HULogOK { param($Message) }
    }
    BeforeEach {
        $script:Calls.Clear()
        $script:Answer = $true; $script:Discard = $true; $script:JobRunning = $false; $script:SaveOk = $true
        $script:IsRunning = $false
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
    }
    It 'laufender Auftrag und Nein: nichts gespeichert, kein Neustart' {
        Use-Theme 'dark'
        $script:JobRunning = $true
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
}
