#Requires -Version 5.1
<#
.SYNOPSIS
    Dialoge einheitlich: nichts abgeschnitten. Fenster mit Anfasser und Mindestbreite, lange Texte umbrechen.
    Ausnahmen: kleine Hinweis-Toasts, das Meldungsfenster (passt sich selbst an den Inhalt an) und der Startbildschirm (fest, ohne Rahmen).
#>
Describe 'Dialoge: Groesse und Umbruch' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:Dialogs = foreach ($f in @(Get-ChildItem -Path (Join-Path $root 'Functions') -Filter *.ps1)) {
            $s = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($s, "(?s)@['""]\s*\r?\n(<Window\b.*?</Window>)\s*\r?\n['""]@")) {
                $fn = [regex]::Matches($s.Substring(0, $m.Index), 'function ([A-Za-z-]+)')
                [pscustomobject]@{ File = $f.Name; Fn = $(if ($fn.Count) { $fn[$fn.Count - 1].Groups[1].Value } else { '' }); Xaml = $m.Groups[1].Value }
            }
        }
        $script:Skip = @('Show-HUToast', 'Show-HUDialogBox', 'Get-HUSplashXaml')
    }
    It 'gefunden' { @($Dialogs).Count | Should -BeGreaterThan 15 }
    It 'kein fest kleines Fenster: Anfasser und Mindestbreite' {
        $bad = foreach ($d in @($Dialogs | Where-Object { $Skip -notcontains $_.Fn })) {
            $head = [regex]::Match($d.Xaml, '(?s)<Window\b[^>]*>').Value
            if ($head -match 'ResizeMode="NoResize"' -or ($head -match '\bWidth="\d+"' -and $head -notmatch 'MinWidth=')) { "$($d.File) $($d.Fn)" }
        }
        @($bad) | Should -BeNullOrEmpty
    }
    It 'lange Texte brechen um (TextBlock mit TextWrapping oder HintText, CheckBox mit innerem TextBlock)' {
        $bad = foreach ($d in @($Dialogs | Where-Object { $_.Fn -ne 'Get-HUSplashXaml' })) {
            foreach ($t in [regex]::Matches($d.Xaml, '(?s)<(TextBlock|CheckBox|RadioButton)\b[^>]*>')) {
                $tag = $t.Value
                $txt = [regex]::Match($tag, '\b(?:Text|Content)="([^"]*)"')
                if (-not $txt.Success -or $txt.Groups[1].Value.Length -le 45 -or $txt.Groups[1].Value -match '\$') { continue }
                if ($t.Groups[1].Value -eq 'TextBlock' -and ($tag -match 'TextWrapping' -or $tag -match 'HintText')) { continue }
                "$($d.File) $($d.Fn): $($txt.Groups[1].Value.Substring(0, 40))"
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}
