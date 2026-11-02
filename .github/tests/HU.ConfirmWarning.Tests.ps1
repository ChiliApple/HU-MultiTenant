#Requires -Version 5.1
<#
.SYNOPSIS
    072 G1: Rueckfragen, die im Tenant schreiben, loeschen oder Rechte erteilen, haben -Warning (Enter = Nein).
#>
Describe 'Rueckfragen mit -Warning' {
    It 'schreibende und loeschende Confirm-HU-Aufrufe sind Warnungen' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $rx = '(?i)(loeschen|entfernen|entziehen|zuweisen|hochladen|freigeben|erteilen|anlegen|ueberschreiben|ersetzen|signieren|erneuern)'
        $bad = foreach ($f in @(Get-ChildItem -Path (Join-Path $root 'Functions'), (Join-Path $root 'Modules') -Recurse -Include *.ps1)) {
            $n = 0
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                $n++
                if ($l -match '\bConfirm-HU\s' -and $l -notmatch 'function Confirm-HU' -and $l -match $rx -and $l -notmatch '-Warning' -and $l -notmatch '# Warnung: nein') { "$($f.Name):$n" }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Sperre und offene Rueckfragen (2.6.7)' {
    It 'Sperre verbirgt bei Unterfenstern nur den Inhalt (Visibility=Hidden am Fenster beendet ShowDialog)' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $src = [IO.File]::ReadAllText((Join-Path $root 'Functions\UI-Lock.ps1'))
        $m = [regex]::Match($src, '(?s)function Lock-HUApp.*?\r?\n}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Not -Match '\$ow\.Visibility\s*='
        $m.Value | Should -Match '\$ow\.Content\.Visibility = ''Hidden'''
    }
}
