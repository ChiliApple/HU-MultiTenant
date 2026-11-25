#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5: verschiebbare Bereiche (GridSplitter) merken, Functions\UI-State.ps1 (ab 2.6.24).
.NOTES
    WPF-Objekte ohne Fenster, nur im STA-Thread. Die Zustandsdatei liegt im Temp-Ordner, nie im echten Benutzerprofil.
    Waechter: jeder GridSplitter im Programm muss vom Kern gemerkt werden (Haupt-Reiter, Modul-Reiter oder Fenster mit
    Restore-HUDialogState). Sonst geht das Merken bei neuen Bereichen wieder verloren.
#>

BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Sta = ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $script:UserRoot = Join-Path ([IO.Path]::GetTempPath()) ('HUMtSp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $script:UserRoot)
    function Read-HUJsonFile([string]$Path) { if (Test-Path -LiteralPath $Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) } return $null }
    function Write-HUJsonFile([string]$Path, $Object, [int]$Depth = 5) { [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth $Depth)) }
    function Get-HUUiScaleValue { 1.0 }
    . (Join-Path $script:Root 'Functions\UI-State.ps1')
    $script:StateFilePath = Join-Path $script:UserRoot 'ui-state.json'

    function New-SplitPanel {
        $p = New-Object System.Windows.Controls.DockPanel
        $g = New-Object System.Windows.Controls.Grid; $g.Name = 'grdHaupt'
        foreach ($h in @(([System.Windows.GridLength]::new(1, 'Star')), ([System.Windows.GridLength]::new(5)), ([System.Windows.GridLength]::new(140)))) { $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = $h; $g.RowDefinitions.Add($rd) }
        $sp = New-Object System.Windows.Controls.GridSplitter; [System.Windows.Controls.Grid]::SetRow($sp, 1); [void]$g.Children.Add($sp)
        [void]$p.Children.Add($g)
        return $p
    }
}
AfterAll { Remove-Item -LiteralPath $script:UserRoot -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Verschiebbare Bereiche merken' {
    BeforeEach { $script:UIState = $null; $script:HUSplitRoots = @{}; $script:HUSplitLimited.Clear(); $script:HUSplitWant.Clear(); $script:HUSplitApplied.Clear(); Remove-Item -LiteralPath $script:StateFilePath -ErrorAction SilentlyContinue }

    It 'findet das Grid mit Splitter und liest Zeilenhoehen' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $p = New-SplitPanel
        @(Get-HUSplitterGrids $p).Count | Should -Be 1
        $snap = @(Get-HUSplitterSnapshot $p)
        $snap[0].G | Should -Be 'grdHaupt'
        $snap[0].R | Should -Be @('Star:1', 'Pixel:5', 'Pixel:140')
    }
    It 'Beenden und Neustart: verschobener Bereich kommt wieder' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $p = New-SplitPanel
        Register-HUSplitterState $p 'Reiter.tabAddonKinderschutz'
        @(Get-HUSplitterGrids $p)[0].RowDefinitions[2].Height = [System.Windows.GridLength]::new(320)   # so als haette man den Splitter gezogen
        Save-HUAllSplitterState; Save-HUUIState                                                       # wie Save-HUWindowState beim Beenden
        Test-Path $script:StateFilePath | Should -BeTrue
        $script:UIState = $null; $script:HUSplitRoots = @{}
        $p2 = New-SplitPanel
        Register-HUSplitterState $p2 'Reiter.tabAddonKinderschutz'
        @(Get-HUSplitterGrids $p2)[0].RowDefinitions[2].Height.Value | Should -Be 320
        @(Get-HUSplitterGrids $p2)[0].RowDefinitions[2].Height.IsAbsolute | Should -BeTrue
    }
    It 'Stern-Zeilen behalten ihr Verhaeltnis' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $p = New-SplitPanel
        Register-HUSplitterState $p 'Reiter.S'
        @(Get-HUSplitterGrids $p)[0].RowDefinitions[0].Height = [System.Windows.GridLength]::new(2.5, 'Star')
        Save-HUSplitterState 'Bereiche.Reiter.S'
        $script:UIState = $null; $script:HUSplitRoots = @{}
        $p2 = New-SplitPanel
        Register-HUSplitterState $p2 'Reiter.S'
        $h = @(Get-HUSplitterGrids $p2)[0].RowDefinitions[0].Height
        $h.IsStar | Should -BeTrue
        $h.Value | Should -Be 2.5
    }
    It 'geaenderte Oberflaeche (andere Zeilenzahl oder Art): nichts wiederherstellen' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        Set-HUStateValue 'Bereiche.Reiter.X' @([pscustomobject]@{ G = 'grdHaupt'; R = @('Star:9', 'Pixel:5'); C = @() })
        Set-HUStateValue 'Bereiche.Reiter.Y' @([pscustomobject]@{ G = 'grdHaupt'; R = @('Pixel:9', 'Pixel:5', 'Pixel:300'); C = @() })
        $p = New-SplitPanel; Register-HUSplitterState $p 'Reiter.X'
        @(Get-HUSplitterGrids $p)[0].RowDefinitions[2].Height.Value | Should -Be 140
        $p = New-SplitPanel; Register-HUSplitterState $p 'Reiter.Y'
        @(Get-HUSplitterGrids $p)[0].RowDefinitions[2].Height.Value | Should -Be 140
    }
    It 'laesst das Tag des Splitters dem Modul und meldet nur einmal an' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $p = New-SplitPanel
        $sp = @(@(Get-HUSplitterGrids $p)[0].Children)[0]; $sp.Tag = 'vom Modul'
        Register-HUSplitterState $p 'Reiter.Tag'
        Register-HUSplitterState $p 'Reiter.Tag'
        $sp.Tag | Should -Be 'vom Modul'
        $script:HUSplitOwner[$sp] | Should -Be 'Bereiche.Reiter.Tag'
    }
    It 'Fenster mit Restore-/Save-HUDialogState bekommen das automatisch' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $w = New-Object System.Windows.Window; $w.Content = New-SplitPanel
        Restore-HUDialogState $w 'TestFenster'
        @(Get-HUSplitterGrids $w)[0].RowDefinitions[2].Height = [System.Windows.GridLength]::new(222)
        Save-HUDialogState $w 'TestFenster'
        @((Get-HUStateValue 'Bereiche.Fenster.TestFenster')[0].R)[2] | Should -Be 'Pixel:222'
    }
    It 'Reiter in einem inneren TabControl (nicht angezeigt) wird mit erfasst' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $outer = New-Object System.Windows.Controls.TabItem
        $tc = New-Object System.Windows.Controls.TabControl
        $a = New-Object System.Windows.Controls.TabItem; $a.Content = New-Object System.Windows.Controls.TextBlock
        $b = New-Object System.Windows.Controls.TabItem; $b.Content = New-SplitPanel
        [void]$tc.Items.Add($a); [void]$tc.Items.Add($b); $outer.Content = $tc
        @(Get-HUSplitterGrids $outer).Count | Should -Be 1
    }
    It 'echter Modul-Reiter (Autopilot, Tab.xaml): Bereiche nach Beenden und Neustart wieder da' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $theme = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\Theme.xaml'), [Text.Encoding]::UTF8)
        $res = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>').Groups[1].Value
        $load = { [System.Windows.Markup.XamlReader]::Parse(([IO.File]::ReadAllText((Join-Path $script:Root 'Modules\Autopilot\Tab.xaml'), [Text.Encoding]::UTF8)).Replace('<!--HU:THEME-->', $res)) }
        $tab = & $load
        Register-HUSplitterState $tab 'Reiter.tabAddonAutopilot'
        $grids = @(Get-HUSplitterGrids $tab)
        $grids.Count | Should -Be 2
        # in jedem Grid die Zeile nach dem Trenner aendern (wie Ziehen)
        $want = @()
        foreach ($g in $grids) {
            $sp = @($g.Children | Where-Object { $_ -is [System.Windows.Controls.GridSplitter] })[0]
            $r = [System.Windows.Controls.Grid]::GetRow($sp) + 1
            if ($g.RowDefinitions[$r].Height.IsStar) { $g.RowDefinitions[$r].Height = [System.Windows.GridLength]::new(3, 'Star'); $want += 'Star:3' }
            else { $g.RowDefinitions[$r].Height = [System.Windows.GridLength]::new(333); $want += 'Pixel:333' }
        }
        Save-HUAllSplitterState; Save-HUUIState
        $script:UIState = $null; $script:HUSplitRoots = @{}
        $tab2 = & $load
        Register-HUSplitterState $tab2 'Reiter.tabAddonAutopilot'
        $i = 0
        foreach ($g in @(Get-HUSplitterGrids $tab2)) {
            $sp = @($g.Children | Where-Object { $_ -is [System.Windows.Controls.GridSplitter] })[0]
            $r = [System.Windows.Controls.Grid]::GetRow($sp) + 1
            ConvertTo-HUGridLengthText $g.RowDefinitions[$r].Height | Should -Be $want[$i]
            $i++
        }
        $i | Should -Be 2
    }
    It 'kleinere Flaeche (anderer Bildschirm): fester Bereich wird begrenzt, Trenner bleibt erreichbar' {
        if (-not $script:Sta) { Set-ItResult -Skipped -Because 'WPF braucht STA'; return }
        $p = New-SplitPanel
        $g = @(Get-HUSplitterGrids $p)[0]
        $g.RowDefinitions[2].Height = [System.Windows.GridLength]::new(900)   # gespeichert auf einem grossen Bildschirm
        $g.Measure([System.Windows.Size]::new(300, 500)); $g.Arrange([System.Windows.Rect]::new(0, 0, 300, 500))
        Limit-HUSplitterGrid $g
        $g.RowDefinitions[2].Height.Value | Should -BeLessOrEqual (500 - 5 - 80)
        $g.RowDefinitions[1].Height.Value | Should -Be 5   # Trenner selbst unveraendert
        # passt der Wert, bleibt er
        # gespeichert wird der gewuenschte Wert, nicht der gekuerzte
        Register-HUSplitterState $p 'Reiter.Klein'
        (@(Get-HUSplitterSnapshot $p)[0].R)[2] | Should -Be 'Pixel:900'
        # wieder genug Platz (Fenster gross): gewuenschter Wert kommt zurueck
        $g.Measure([System.Windows.Size]::new(300, 1200)); $g.Arrange([System.Windows.Rect]::new(0, 0, 300, 1200))
        Limit-HUSplitterGrid $g
        $g.RowDefinitions[2].Height.Value | Should -Be 900
        (@(Get-HUSplitterSnapshot $p)[0].R)[2] | Should -Be 'Pixel:900'
        # gekuerzt und danach anders verschoben (Tastatur, kein Loslassen-Ereignis): der neue Wert gilt, nicht der alte Wunsch
        $g.Measure([System.Windows.Size]::new(300, 500)); $g.Arrange([System.Windows.Rect]::new(0, 0, 300, 500))
        Limit-HUSplitterGrid $g
        $g.RowDefinitions[2].Height.Value | Should -BeLessThan 900
        $g.RowDefinitions[2].Height = [System.Windows.GridLength]::new(150)
        (@(Get-HUSplitterSnapshot $p)[0].R)[2] | Should -Be 'Pixel:150'
        $g.Measure([System.Windows.Size]::new(300, 1200)); $g.Arrange([System.Windows.Rect]::new(0, 0, 300, 1200))
        Limit-HUSplitterGrid $g
        $g.RowDefinitions[2].Height.Value | Should -Be 150
        # passt der Wert, bleibt er
        $g.RowDefinitions[2].Height = [System.Windows.GridLength]::new(200)
        $g.Measure([System.Windows.Size]::new(300, 500)); $g.Arrange([System.Windows.Rect]::new(0, 0, 300, 500))
        Limit-HUSplitterGrid $g
        $g.RowDefinitions[2].Height.Value | Should -Be 200
    }
}

Describe 'Verschiebbare Bereiche: Einbindung und Waechter' {
    It 'Kern: Haupt-Reiter, Modul-Reiter, Beenden und Fenster sind angeschlossen' {
        $st = Get-Content -LiteralPath (Join-Path $script:Root 'Functions\UI-State.ps1') -Raw
        $ad = Get-Content -LiteralPath (Join-Path $script:Root 'Functions\UI-Addons.ps1') -Raw
        $st | Should -Match 'Register-HUSplitterState \$t "Reiter\.\$\(\$t\.Name\)"'
        $st | Should -Match 'try \{ Save-HUAllSplitterState \}'
        $st | Should -Match 'Register-HUSplitterState \$Window "Fenster\.\$Key"'
        $st | Should -Match 'Save-HUSplitterState "Bereiche\.Fenster\.\$Key"'
        $ad | Should -Match 'Register-HUSplitterState \$tab "Reiter\.\$\(\$tab\.Name\)"'
        # Beenden speichert den Fensterzustand (und damit die Bereiche)
        (Get-Content -LiteralPath (Join-Path $script:Root 'Main.ps1') -Raw) | Should -Match 'Add_Closing\(\{[\s\S]*?Save-HUWindowState'
    }
    It 'jedes Unterfenster mit GridSplitter merkt seine Bereiche (Restore-HUDialogState)' {
        $miss = New-Object System.Collections.Generic.List[string]
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'Functions'), (Join-Path $script:Root 'Modules') -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $src = [IO.File]::ReadAllText($f.FullName)
            # Fenster als Text im Skript: je Fenster mit Splitter (<Window ... </Window>) ein Aufruf von Restore-HUDialogState
            $withSplit = @([regex]::Matches($src, '(?s)<Window\b.*?</Window>') | Where-Object { $_.Value -match '<GridSplitter' }).Count
            $restores = [regex]::Matches($src, 'Restore-HUDialogState\s+\$').Count
            if ($withSplit -gt $restores) { $miss.Add("$($f.Name) ($withSplit Fenster mit Trenner, $restores mit Restore-HUDialogState)") }
        }
        # Fenster als eigene XAML-Datei: das Skript, das sie laedt, muss Restore-HUDialogState aufrufen
        foreach ($x in @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'XAML') -Filter *.xaml -File)) {
            if ($x.BaseName -eq 'MainWindow') { continue }   # Hauptfenster: Reiter meldet Restore-HUWindowState an
            $xs = [IO.File]::ReadAllText($x.FullName)
            if ($xs -notmatch '<GridSplitter' -or $xs -notmatch '<Window\b') { continue }   # Kommentarkopf vor <Window ist erlaubt
            $users = @($files | Where-Object { ([IO.File]::ReadAllText($_.FullName)) -match "'$([regex]::Escape($x.BaseName))'" })
            if (-not @($users | Where-Object { ([IO.File]::ReadAllText($_.FullName)) -match 'Restore-HUDialogState' }).Count) { $miss.Add($x.Name) }
        }
        $miss | Should -BeNullOrEmpty -Because 'ein verschiebbarer Bereich ohne Speicherung geht beim Beenden verloren'
    }
    It 'Hauptfenster: jeder GridSplitter liegt in einem benannten Reiter oder ist eigens gemerkt' {
        $xs = [IO.File]::ReadAllText((Join-Path $script:Root 'XAML\MainWindow.xaml'))
        # Splitter ausserhalb der Reiter: nur die Liste links (splLeft, eigens gemerkt als LeftWidth)
        $tabsStart = $xs.IndexOf('x:Name="tabMain"')
        $tabsEnd = $xs.LastIndexOf('</TabControl>')
        $outside = @([regex]::Matches($xs, '<GridSplitter[^>]*>') | Where-Object { $_.Index -lt $tabsStart -or $_.Index -gt $tabsEnd })
        foreach ($m in $outside) { $m.Value | Should -Match 'x:Name="splLeft"' }
    }
}
