#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) aus dem Review 029 (Lueckentests von Grok) fuer Core\HU.Notify.psm1.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1). Ohne Netzwerk (Mocks).
    Tests mit [029] im Namen waren beim Stand 1362001/ec1b03a rot und sind seit v2.1.10 behoben.
#>

BeforeAll {
    $script:Repo = if ($env:HU_REPO) { $env:HU_REPO } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    $script:TestAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-NotifyQ-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TestAppData -ItemType Directory -Force | Out-Null
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = $script:TestAppData
    Import-Module (Join-Path $script:Repo 'Core\HU.Notify.psm1') -Force -DisableNameChecking
    $script:HistFile = Join-Path $script:TestAppData 'HU-MultiTenant\notify-history.json'

    function New-TestTarget([string]$Id, [string]$Name, [string]$Url, [bool]$Enabled = $true, $Cats = $null) {
        [pscustomobject]@{ Id = $Id; Name = $Name; Url = $Url; Enabled = $Enabled; Cats = $Cats; Created = '' }
    }
    $script:UrlA = 'https://prod-1.logic.azure.com/workflows/aaa?sig=geheimA'
    $script:UrlB = 'https://prod-2.logic.azure.com/workflows/bbb?sig=geheimB'
}

AfterAll {
    $env:APPDATA = $script:OldAppData
    Remove-Module HU.Notify -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TestAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Q: Send-HUNotify Rueckgabe {Ok; Failed; Text}' {
    BeforeEach {
        Remove-Item -LiteralPath $script:HistFile -Force -ErrorAction SilentlyContinue
        Mock -ModuleName HU.Notify Start-Sleep { }
        Mock -ModuleName HU.Notify Get-HUNotifyConfig {
            [pscustomobject]@{ Configured = $true; Error = ''; Targets = @(
                [pscustomobject]@{ Id = 'aaaaaaaa'; Name = 'Kanal A'; Url = 'https://prod-1.logic.azure.com/workflows/aaa?sig=geheimA'; Enabled = $true; Cats = @{ Daily = $true }; Created = '' }
                [pscustomobject]@{ Id = 'bbbbbbbb'; Name = 'Kanal B'; Url = 'https://prod-2.logic.azure.com/workflows/bbb?sig=geheimB'; Enabled = $true; Cats = @{ Daily = $true }; Created = '' }
            ) }
        }
    }
    It 'alle Ziele erfolgreich: Ok=2, Failed=0, Text nennt beide, ohne Adresse' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        $r = Send-HUNotify -Category Daily -Title 'T'
        $r.Ok | Should -Be 2; $r.Failed | Should -Be 0
        $r.Text | Should -Match 'Kanal A: gesendet'; $r.Text | Should -Match 'Kanal B: gesendet'
        $r.Text | Should -Not -Match 'geheim'
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 2 -Exactly
    }
    It 'Teilerfolg: ein Ziel 404, eines ok -> Ok=1, Failed=1' {
        Mock -ModuleName HU.Notify Invoke-WebRequest {
            if ($Uri -like '*bbb*') { $e = [System.Net.WebException]::new('Not Found'); $e | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404; Headers = @{} }) -Force; throw $e }
            $null
        }
        $r = Send-HUNotify -Category Daily -Title 'T'
        $r.Ok | Should -Be 1; $r.Failed | Should -Be 1
        $r.Text | Should -Match 'Kanal B: Senden abgelehnt \(404\)'
        $r.Text | Should -Not -Match 'geheim'
        @(Get-HUNotifyHistory).Count | Should -Be 2
    }
    It 'kein passendes Ziel (Kategorie aus) -> Ok=0, Failed=0, Text leer, nichts gesendet' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        $r = Send-HUNotify -Category Apps -Title 'T'    # Apps ist standardmaessig aus
        $r.Ok | Should -Be 0; $r.Failed | Should -Be 0; $r.Text | Should -Be ''
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 0 -Exactly
    }
    It 'TargetIds, die es nicht gibt -> nichts gesendet; -IgnoreCategory sendet auch bei Kategorie aus' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        (Send-HUNotify -Category Daily -Title 'T' -TargetIds @('ffffffff')).Ok | Should -Be 0
        (Send-HUNotify -Category Apps -Title 'T' -TargetIds @('aaaaaaaa') -IgnoreCategory).Ok | Should -Be 1
    }
    It 'ausgeschaltetes Ziel wird uebersprungen' {
        Mock -ModuleName HU.Notify Get-HUNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Targets = @([pscustomobject]@{ Id = 'aaaaaaaa'; Name = 'A'; Url = 'https://prod-1.logic.azure.com/w'; Enabled = $false; Cats = $null; Created = '' }) } }
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        $r = Send-HUNotify -Category Daily -Title 'T'
        $r.Ok + $r.Failed | Should -Be 0
    }
    It 'Ziele nicht lesbar (DPAPI/Datei kaputt) -> Failed=1, Text mit Grund' {
        Mock -ModuleName HU.Notify Get-HUNotifyConfig { [pscustomobject]@{ Configured = $false; Error = 'Schluessel ungueltig'; Targets = @() } }
        $r = Send-HUNotify -Category Daily -Title 'T'
        $r.Failed | Should -Be 1; $r.Text | Should -Match 'nicht lesbar'
    }
    It '[029] wirft nie - auch wenn der Kartenbau scheitert' {
        Mock -ModuleName HU.Notify New-HUTeamsCard { throw 'kaputt' }
        { Send-HUNotify -Category Daily -Title 'T' } | Should -Not -Throw
    }
}

Describe 'Q: Send-HUTeamsCard Fehlercodes, Wiederholungen, 302' {
    BeforeEach { Mock -ModuleName HU.Notify Start-Sleep { } }
    It '429 mit Retry-After: 3 Versuche, Wartezeit aus Header (max 30 s)' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $e = [System.Net.WebException]::new('Too Many'); $e | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = '99' } }) -Force; throw $e }
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url $script:UrlA | Should -Match 'fehlgeschlagen'
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke -ModuleName HU.Notify Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }
    It '401/403/400 -> sofort Abbruch mit Klartext, keine Wiederholung' {
        foreach ($code in 400, 401, 403) {
            Mock -ModuleName HU.Notify Invoke-WebRequest { $e = [System.Net.WebException]::new('x'); $e | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $code; Headers = @{} }) -Force; throw $e }.GetNewClosure()
            Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url $script:UrlA | Should -Match "\($code\)"
        }
    }
    It '[029] 302 unter PS 5.1 (-MaximumRedirection 0 wirft InvalidOperationException ohne Response): kein Erfolg UND keine Wiederholung' {
        # PS 5.1: "Die maximale Umleitungsanzahl wurde ueberschritten" - Exception ohne .Response -> $code = 0 -> wird als Timeout behandelt
        Mock -ModuleName HU.Notify Invoke-WebRequest { throw [System.InvalidOperationException]::new('The maximum redirection count has been exceeded. To increase the number of redirections allowed, supply a higher value to the -MaximumRedirection parameter.') }
        $r = Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url $script:UrlA
        $r | Should -Not -BeNullOrEmpty
        $r | Should -Match '(?i)umleitung|redirect|302'
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 1 -Exactly   # POST nicht 3x wiederholen
    }
    It '302 mit Response (PS 7): kein Erfolg, keine Wiederholung' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $e = [System.Exception]::new('Found'); $e | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 302; Headers = @{} }) -Force; throw $e }
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url $script:UrlA | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 1 -Exactly
    }
    It 'Invoke-WebRequest wird mit -MaximumRedirection 0 und -UseBasicParsing aufgerufen' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url $script:UrlA | Should -Be ''
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 1 -ParameterFilter { $MaximumRedirection -eq 0 -and $UseBasicParsing }
    }
    It 'Body ist UTF-8 (Umlaute bleiben erhalten, unabhaengig von der Codepage)' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $script:Body = $Body; $null }
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'Geraete: Muenchen Groesse Aerger Oe') -Url $script:UrlA | Out-Null
        $script:Body | Should -BeOfType [byte]
        [System.Text.Encoding]::UTF8.GetString($script:Body) | Should -Match 'Muenchen'
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title "Gr$([char]0xF6)$([char]0xDF)e") -Url $script:UrlA | Out-Null
        [System.Text.Encoding]::UTF8.GetString($script:Body) | Should -Match "Gr$([char]0xF6)$([char]0xDF)e"
    }
}

Describe 'Q: Kartengroesse (27 KB)' {
    BeforeAll {
        $script:Long = ("Ae&'x " * 80)
        $script:MaxLines = 1..40 | ForEach-Object { "$_ $script:Long" }
        $script:MaxFacts = [ordered]@{}; 1..30 | ForEach-Object { $script:MaxFacts["Fakt $_ $script:Long"] = $script:Long }
        $script:MaxRows = 1..25 | ForEach-Object { @{ Name = "T$_"; Status = 'Error'; Text = $script:Long } }
    }
    # Seit v2.1.10 kuerzt New-HUTeamsCard selbst; die harte Grenze in ConvertTo-HUTeamsCardJson bleibt als Netz
    # fuer von Hand gebaute Karten - daher hier eine Karte, die an New-HUTeamsCard vorbei vergroessert wird.
    It 'ConvertTo-HUTeamsCardJson wirft ueber 27000 Byte' {
        $c = New-HUTeamsCard -Title 'T'
        $c.attachments[0].content.body = @($c.attachments[0].content.body) + @([ordered]@{ type = 'TextBlock'; text = ('x' * 30000) })
        { ConvertTo-HUTeamsCardJson -Card $c } | Should -Throw '*zu gross*'
    }
    It 'Send-HUTeamsCard meldet zu grosse Karte als Grund statt zu werfen' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        $c = New-HUTeamsCard -Title 'T'
        $c.attachments[0].content.body = @($c.attachments[0].content.body) + @([ordered]@{ type = 'TextBlock'; text = ('x' * 30000) })
        Send-HUTeamsCard -Card $c -Url $script:UrlA | Should -Match 'zu gross'
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 0 -Exactly
    }
    It '[029] Karte innerhalb der eigenen Grenzen (40 Zeilen, 30 Fakten, 25 Ampelzeilen) passt in 27 KB' {
        $c = New-HUTeamsCard -Title 'T' -Lines $script:MaxLines -Facts $script:MaxFacts -Rows $script:MaxRows
        $j = ConvertTo-Json -InputObject $c -Depth 20 -Compress
        [System.Text.Encoding]::UTF8.GetByteCount($j) | Should -BeLessOrEqual 27000
    }
    It 'Tages-Ampel mit 25 Tenants und langen Fehlertexten passt in 27 KB' {
        $c = New-HUTeamsCard -Title 'Tages-Ampel' -Rows $script:MaxRows -Facts ([ordered]@{ a = 1; b = 2; c = 3; d = 'x von y' })
        { ConvertTo-HUTeamsCardJson -Card $c } | Should -Not -Throw
    }
    It 'tief verschachtelte Karte (ColumnSet > Column > TextBlock) wird nicht abgeschnitten (-Depth)' {
        $c = New-HUTeamsCard -Title 'T' -Rows @(@{ Name = 'HLW'; Status = 'OK'; Text = 'alles gut' })
        $j = ConvertTo-HUTeamsCardJson -Card $c
        $j | Should -Match '"text":"alles gut"'
        $j | Should -Not -Match 'System\.Collections'
    }
}

Describe 'Q: Sendeprotokoll robust (kaputte Datei, Sperre, parallel)' {
    BeforeEach { Remove-Item -LiteralPath $script:HistFile, "$($script:HistFile).bak" -Force -ErrorAction SilentlyContinue }
    It 'kaputte notify-history.json -> .bak und neu beginnen, wirft nicht' {
        New-Item -Path (Split-Path $script:HistFile) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $script:HistFile -Value '{ kaputt' -Encoding UTF8
        { Add-HUNotifyHistory -TargetName 'A' -Tag 'x' -Category 'Daily' -Title 'T' -Result 'gesendet' } | Should -Not -Throw
        Test-Path -LiteralPath "$($script:HistFile).bak" | Should -BeTrue
        @(Get-HUNotifyHistory).Count | Should -Be 1
    }
    It 'einzelner Eintrag bleibt Array (PS-5.1-Unwrapping)' {
        Add-HUNotifyHistory -TargetName 'A' -Tag 'x' -Category 'Daily' -Title 'T' -Result 'gesendet'
        $h = Get-HUNotifyHistory
        @($h).Count | Should -Be 1
        @($h)[0].Target | Should -Be 'A'
    }
    It 'Protokoll begrenzt auf 300 Eintraege' {
        1..305 | ForEach-Object { Add-HUNotifyHistory -TargetName "Z$_" -Tag 'x' -Category 'Daily' -Title 'T' -Result 'ok' }
        @(Get-HUNotifyHistory -Last 1000).Count | Should -Be 300
        @(Get-HUNotifyHistory)[0].Target | Should -Be 'Z305'
    }
    It '[029] Sperre belegt (WaitOne-Timeout): es wird NICHT ohne Sperre geschrieben' {
        # anderer Thread haelt die Sperre 8 s; Invoke-HUNotifyLocked wartet 5 s und laeuft dann trotzdem
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ $m = New-Object System.Threading.Mutex($false, 'Local\HU-MultiTenant_Notify'); [void]$m.WaitOne(); Start-Sleep -Seconds 8; $m.ReleaseMutex(); $m.Dispose() })
        $h = $ps.BeginInvoke()
        Start-Sleep -Milliseconds 500
        Add-HUNotifyHistory -TargetName 'ohneSperre' -Tag 'x' -Category 'Daily' -Title 'T' -Result 'ok'
        $written = @(Get-HUNotifyHistory | Where-Object Target -eq 'ohneSperre').Count
        $ps.EndInvoke($h); $ps.Dispose()
        $written | Should -Be 0 -Because 'nach Timeout darf die Datei nicht ungesperrt gelesen+geschrieben werden (lost update)'
    }
    It 'parallele Laeufe (2 Prozesse x 15 Eintraege) verlieren keine Eintraege' {
        $exe = (Get-Process -Id $PID).Path
        $mod = Join-Path $script:Repo 'Core\HU.Notify.psm1'
        $cmd = "`$env:APPDATA='$($script:TestAppData)'; Import-Module '$mod' -DisableNameChecking; 1..15 | % { Add-HUNotifyHistory -TargetName ('P'+`$PID) -Tag 'x' -Category 'Daily' -Title 'T' -Result 'ok' }"
        $p = 1..2 | ForEach-Object { Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-Command', $cmd -PassThru }
        $p | ForEach-Object { $_.WaitForExit(60000) | Out-Null }
        @(Get-HUNotifyHistory -Last 1000).Count | Should -Be 30
    }
}
