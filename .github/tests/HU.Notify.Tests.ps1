#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.Notify.psm1 - ohne Netzwerk, ohne Oberflaeche.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1)
    DPAPI-Tests laufen nur unter Windows.
#>

# Erkennung zur Discovery-Zeit (Pester wertet -Skip vor BeforeAll aus)
$script:IsWin = ($PSVersionTable.PSVersion.Major -le 5) -or [bool]$IsWindows

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AppRoot = $root
    # eigener, leerer APPDATA-Ordner, damit keine echten Ziele beruehrt werden
    $script:TestAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-Notify-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TestAppData -ItemType Directory -Force | Out-Null
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = $script:TestAppData
    Import-Module (Join-Path $root 'Core\HU.Notify.psm1') -Force -DisableNameChecking
}

AfterAll {
    $env:APPDATA = $script:OldAppData
    Remove-Module HU.Notify -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TestAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Teams: Webhook-Adresse (Test-HUWebhookUrl)' {
    It 'Workflows-Adresse ist in Ordnung' {
        Test-HUWebhookUrl 'https://prod-12.westeurope.logic.azure.com:443/workflows/abc/triggers/manual/paths/invoke?sig=x' | Should -Be ''
    }
    It 'alter Office-365-Connector wird abgewiesen' {
        Test-HUWebhookUrl 'https://contoso.webhook.office.com/webhookb2/abc' | Should -Match 'Connector'
    }
    It 'nur https' {
        Test-HUWebhookUrl 'http://prod-12.westeurope.logic.azure.com/x' | Should -Match 'https'
    }
    It 'private und lokale Hosts werden abgewiesen' {
        Test-HUWebhookUrl 'https://10.1.1.2/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://192.168.1.5/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://localhost/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://schulserver/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://[::ffff:127.0.0.1]/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://100.64.1.1/x' | Should -Not -Be ''
        Test-HUWebhookUrl 'https://198.18.0.1/x' | Should -Not -Be ''
    }
    It 'leer' { Test-HUWebhookUrl '   ' | Should -Be 'leer' }
    It 'bekannte Hosts werden erkannt (nur Hinweis)' {
        Test-HUWebhookHostKnown 'https://prod-12.westeurope.logic.azure.com/x' | Should -BeTrue
        Test-HUWebhookHostKnown 'https://example.org/x' | Should -BeFalse
    }
}

Describe 'Teams: Textbereinigung (ConvertTo-HUNotifySafeText)' {
    It 'entfernt Markdown, Steuerzeichen und entschaerft Links' {
        $t = ConvertTo-HUNotifySafeText ("Hallo [x] *fett* <b>t</b> https://evil.example " + [char]0x200E + [char]0x202E + " ende")
        $t | Should -Be 'Hallo x fett bt/b https :// evil.example ende'
    }
    It 'Unterstriche bleiben als Leerzeichen erhalten (SKU-/Geraetenamen)' {
        ConvertTo-HUNotifySafeText 'M365EDU_A3_FACULTY NB_123' | Should -Be 'M365EDU A3 FACULTY NB 123'
    }
    It 'kuerzt auf Max' {
        (ConvertTo-HUNotifySafeText ('a' * 500) -Max 100).Length | Should -Be 104
    }
    It 'zerschneidet kein Ersatzpaar' {
        $s = ('a' * 99) + [char]0xD83D + [char]0xDE00
        $t = ConvertTo-HUNotifySafeText $s -Max 100
        $t | Should -Be (('a' * 99) + ' ...')
    }
}

Describe 'Teams: Karte (New-HUTeamsCard)' {
    It 'baut eine Adaptive Card im Workflows-Format' {
        $c = New-HUTeamsCard -Title 'Titel' -Level Error -Lines @('z1', '', 'z2') -Facts ([ordered]@{ A = 1; B = 'x' }) -Source 'PC1' -Category 'Kat'
        $c.type | Should -Be 'message'
        $c.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        $card = $c.attachments[0].content
        $card.type | Should -Be 'AdaptiveCard'
        $card.version | Should -Be '1.4'
        $card.body[0].text | Should -Be 'Titel'
        $card.body[0].color | Should -Be 'Attention'
        @($card.body | Where-Object { $_.type -eq 'TextBlock' -and $_.spacing -eq 'Small' }).Count | Should -Be 2
        ($card.body | Where-Object { $_.type -eq 'FactSet' }).facts.Count | Should -Be 2
        $card.body[-1].text | Should -Match '^PC1  \|  .*HU-MultiTenant  \|  Kat$'
    }
    It 'Zeilen fuer die Tenant-Ampel mit Farbe' {
        $c = New-HUTeamsCard -Title 'T' -Rows @(@{ Name = 'HLW'; Status = 'OK'; Text = 'gut' }, @{ Name = 'Gym'; Status = 'Error'; Text = 'schlecht' })
        $cs = @($c.attachments[0].content.body | Where-Object { $_.type -eq 'ColumnSet' })
        $cs.Count | Should -Be 2
        $cs[1].columns[1].items[0].color | Should -Be 'Attention'
        $cs[1].columns[2].items[0].text | Should -Be 'schlecht'
    }
    It 'Aktionen nur mit https' {
        $c = New-HUTeamsCard -Title 'T' -Actions @(@{ Title = 'ok'; Url = 'https://contoso.sharepoint.com/x' }, @{ Title = 'nein'; Url = 'http://x.y/z' }, @{ Title = 'nein2'; Url = 'javascript:alert(1)' })
        $a = @($c.attachments[0].content.actions)
        $a.Count | Should -Be 1
        $a[0].type | Should -Be 'Action.OpenUrl'
    }
    It 'bereinigt Titel und Zeilen' {
        $c = New-HUTeamsCard -Title '[x] *T*' -Lines @('<b>a</b> https://e.x')
        $c.attachments[0].content.body[0].text | Should -Be 'x T'
        $c.attachments[0].content.body[1].text | Should -Be 'ba/b https :// e.x'
    }
    It 'begrenzt die Zeilenzahl' {
        $c = New-HUTeamsCard -Title 'T' -Lines @(1..60 | ForEach-Object { "z$_" })
        $tb = @($c.attachments[0].content.body | Where-Object { $_.type -eq 'TextBlock' })
        $tb[-2].text | Should -Match 'und 40 weitere Zeilen'   # 60 Zeilen, Grenze 20 (v2.1.10)
    }
    It 'begrenzt die Ampel-Zeilen mit Hinweis' {
        $c = New-HUTeamsCard -Title 'T' -Rows @(1..30 | ForEach-Object { @{ Name = "S$_"; Status = 'OK'; Text = 'x' } })
        @($c.attachments[0].content.body | Where-Object { $_.type -eq 'ColumnSet' }).Count | Should -Be 25
        @($c.attachments[0].content.body | Where-Object { $_.type -eq 'TextBlock' -and "$($_.text)" -match 'und 5 weitere' }).Count | Should -Be 1
    }
    It 'JSON ist kompakt und nicht zu gross' {
        $j = ConvertTo-HUTeamsCardJson (New-HUTeamsCard -Title 'T' -Lines @('a'))
        $j | Should -Match '^\{"type":"message"'
        $j | Should -Not -Match "`n"
        { ConvertTo-HUTeamsCardJson (New-HUTeamsCard -Title 'T' -Lines @(1..40 | ForEach-Object { 'x' * 400 }) -Facts ([ordered]@{ a = ('y' * 200) })) } | Should -Not -Throw
    }
}

Describe 'Teams: Kategorien' {
    It 'liefert Kategorien in Reihenfolge mit Standard' {
        $k = @(Get-HUNotifyCategories)
        $k.Count | Should -BeGreaterThan 5
        $k[0].Key | Should -Be 'Test'
        ($k | Where-Object Key -eq 'Daily').Default | Should -BeTrue
        ($k | Where-Object Key -eq 'Apps').Default | Should -BeFalse
    }
    It 'Test-HUNotifyCat: Standard, Ziel-Hashtable, Ziel-Objekt, unbekannt' {
        Test-HUNotifyCat -Target $null -Category 'Daily' | Should -BeTrue
        Test-HUNotifyCat -Target $null -Category 'Apps' | Should -BeFalse
        Test-HUNotifyCat -Target @{ Cats = @{ Apps = $true } } -Category 'Apps' | Should -BeTrue
        Test-HUNotifyCat -Target ([pscustomobject]@{ Cats = [pscustomobject]@{ Daily = $false } }) -Category 'Daily' | Should -BeFalse
        Test-HUNotifyCat -Target $null -Category 'Gibtsnicht' | Should -BeFalse
    }
}

Describe 'Teams: Protokoll-Kennung' {
    It 'Kurzkennung ist 8 Hex-Zeichen und enthaelt nicht die Adresse' {
        $t = Get-HUNotifyUrlTag 'https://prod-12.westeurope.logic.azure.com/workflows/abc?sig=geheim'
        $t | Should -Match '^[0-9a-f]{8}$'
        $t | Should -Not -Match 'geheim'
    }
}

Describe 'Teams: Senden (ohne Netz)' {
    It 'ungueltige Adresse wird nicht gesendet' {
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url 'https://x.webhook.office.com/a' | Should -Match 'ungueltig'
    }
    It 'Send-HUNotify ohne Ziele sendet nichts und wirft nicht' {
        $r = Send-HUNotify -Category 'Daily' -Title 'T'
        $r.Ok | Should -Be 0; $r.Failed | Should -Be 0; $r.Text | Should -Be ''
        (Send-HUNotify -Category 'Gibtsnicht' -Title 'T').Text | Should -Match 'Unbekannte Kategorie'
    }
    It 'Fehlermeldungen enthalten nie die Adresse' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { throw 'Fehler bei https://prod-1.logic.azure.com/workflows/abc?sig=geheim' }
        $r = Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url 'https://prod-1.logic.azure.com/workflows/abc?sig=geheim' -Retries 0
        $r | Should -Match 'fehlgeschlagen'
        $r | Should -Not -Match 'geheim'
    }
    It 'wirft nicht, wenn der Kartenbau scheitert (Review 029 B19)' {
        Mock -ModuleName HU.Notify Get-HUNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Targets = @([pscustomobject]@{ Id = 'aabbccdd'; Name = 'Z'; Url = 'https://prod-1.logic.azure.com/w'; Enabled = $true; Cats = $null }) } }
        Mock -ModuleName HU.Notify New-HUTeamsCard { throw 'kaputt https://prod-1.logic.azure.com/w?sig=geheim' }
        $r = Send-HUNotify -Category 'Daily' -Title 'T'
        $r.Failed | Should -Be 1
        $r.Text | Should -Match 'Karte nicht gebaut'
        $r.Text | Should -Not -Match 'geheim'
    }
    It 'sendet JSON per POST' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { param($Uri, $Method, $Body, $ContentType) $script:sent = [System.Text.Encoding]::UTF8.GetString($Body); return $null }
        Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'Hallo') -Url 'https://prod-1.logic.azure.com/workflows/abc' | Should -Be ''
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $ContentType -like 'application/json*' }
    }
}

Describe 'Teams: Sendeprotokoll (Datei)' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-history.json') -Force -ErrorAction SilentlyContinue }
    It 'drei Eintraege bleiben drei Eintraege (flaches Array, PS-5.1-sicher)' {
        1..3 | ForEach-Object { Add-HUNotifyHistory -TargetName "Z$_" -Tag 'aabbccdd' -Category 'Daily' -Title "T$_" -Result 'gesendet' }
        $h = @(Get-HUNotifyHistory)
        $h.Count | Should -Be 3
        $h[0].Target | Should -Be 'Z3'
        (Get-Content -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-history.json') -Raw) | Should -Match '^\{"v":1,"items":\['
    }
    It 'liest alte verschachtelte Dateien (value/Count) und repariert sie beim naechsten Eintrag' {
        $p = Join-Path $env:APPDATA 'HU-MultiTenant'
        if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
        '[{"value":[{"value":" ","Count":2},{"Time":"2026-10-16T19:54:51","Target":"A","Tag":"x","Category":"Licenses","Title":"L","Result":"gesendet"}],"Count":2},{"Time":"2026-10-16T20:00:16","Target":"A","Tag":"x","Category":"Defender","Title":"D","Result":"gesendet"}]' |
            Set-Content -LiteralPath (Join-Path $p 'notify-history.json') -Encoding UTF8
        @(Get-HUNotifyHistory).Count | Should -Be 2
        Add-HUNotifyHistory -TargetName 'B' -Tag 'y' -Category 'Daily' -Title 'N' -Result 'gesendet'
        $h = @(Get-HUNotifyHistory)
        $h.Count | Should -Be 3
        $h[0].Target | Should -Be 'B'
    }
}

Describe 'Teams: Ziele speichern (DPAPI, nur Windows)' -Skip:(-not $script:IsWin) {
    It 'speichert, liest, entfernt' {
        (Get-HUNotifyConfig).Configured | Should -BeFalse
        Add-HUNotifyTarget -Name 'Admin-Kanal' -Url 'https://prod-1.logic.azure.com/workflows/abc?sig=geheim' -Cats @{ Apps = $true } | Should -Be ''
        $c = Get-HUNotifyConfig
        $c.Configured | Should -BeTrue
        $c.Targets.Count | Should -Be 1
        $c.Targets[0].Name | Should -Be 'Admin-Kanal'
        $c.Targets[0].Url | Should -Match 'geheim'
        $c.Targets[0].Cats['Apps'] | Should -BeTrue
        $c.Targets[0].Cats['Daily'] | Should -BeTrue
        $c.Targets[0].Id | Should -Match '^[0-9a-f]{8}$'
        # Datei enthaelt die Adresse nicht im Klartext
        (Get-Content -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-targets.json') -Raw) | Should -Not -Match 'geheim'
        Remove-HUNotifyTarget -Id $c.Targets[0].Id | Should -Be ''
        (Get-HUNotifyConfig).Configured | Should -BeFalse
    }
    It 'weist ungueltige Adressen beim Speichern ab' {
        Add-HUNotifyTarget -Name 'x' -Url 'https://x.webhook.office.com/a' | Should -Match 'Connector'
    }
    It 'hoechstens 10 Ziele' {
        $l = @(1..11 | ForEach-Object { @{ Name = "t$_"; Url = "https://prod-$_.logic.azure.com/w" } })
        Set-HUNotifyTargets -Targets $l | Should -Match '10'
    }
}

Describe 'Teams: Kartengroesse und Push-Vorschau (v2.1.10)' {
    It 'riesige Karte wird stufenweise gekuerzt statt verworfen' {
        $long = '"x' * 200   # Anfuehrungszeichen werden in JSON immer maskiert (2 Byte) - auch unter PS 7
        $facts = [ordered]@{}; 1..30 | ForEach-Object { $facts["Fakt $_"] = $long }
        $c = New-HUTeamsCard -Title 'Gross' -Lines @(1..40 | ForEach-Object { "$_ $long" }) -Facts $facts -Rows @(1..25 | ForEach-Object { @{ Name = "T$_"; Status = 'Error'; Text = $long } })
        $j = ConvertTo-Json -InputObject $c -Depth 20 -Compress
        [System.Text.Encoding]::UTF8.GetByteCount($j) | Should -BeLessOrEqual 21000
        $j | Should -Match 'Gekuerzt'
        { ConvertTo-HUTeamsCardJson -Card $c } | Should -Not -Throw
    }
    It 'normale Karte bleibt ungekuerzt' {
        (ConvertTo-Json -InputObject (New-HUTeamsCard -Title 'T' -Lines @('a', 'b')) -Depth 20 -Compress) | Should -Not -Match 'gekuerzt'
    }
    It '-Preview ersetzt die Vorschau aus den Zeilen' {
        $c = New-HUTeamsCard -Title 'Ampel' -Rows @(@{ Name = 'HLW'; Status = 'Error'; Text = 'NB-GEHEIM-01 Bedrohung' }) -Preview '1 Geraet mit Befund (HLW)'
        $c.summary | Should -Match '1 Geraet mit Befund'
        $c.summary | Should -Not -Match 'NB-GEHEIM'
        $c.attachments[0].content.fallbackText | Should -Be $c.summary
    }
}

Describe 'Teams: eigene Kategorien (v2.1.10)' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-categories.json') -Force -ErrorAction SilentlyContinue }
    It 'anlegen: erscheint nach den eingebauten mit Custom-Kennung' {
        Add-HUNotifyCategory -Key 'Backup' -Label 'Backup: Ergebnisse' -Default $true | Should -Be ''
        $k = @(Get-HUNotifyCategories)
        $b = $k | Where-Object Key -eq 'Backup'
        $b.Custom | Should -BeTrue
        $b.Label | Should -Be 'Backup: Ergebnisse'
        $k[-1].Key | Should -Be 'Backup'
        ($k | Where-Object Key -eq 'Daily').Custom | Should -BeFalse
    }
    It 'Schluessel wird geprueft, eingebaute sind gesperrt' {
        Add-HUNotifyCategory -Key '1abc' -Label 'x' | Should -Match 'Schluessel'
        Add-HUNotifyCategory -Key 'a b' -Label 'x' | Should -Match 'Schluessel'
        Add-HUNotifyCategory -Key 'daily' -Label 'x' | Should -Match 'eingebaute'
        Add-HUNotifyCategory -Key 'Ok1' -Label '   ' | Should -Match 'Bezeichnung'
        Remove-HUNotifyCategory -Key 'Secrets' | Should -Match 'eingebaute'
    }
    It 'gleicher Schluessel aendert nur Bezeichnung/Standard' {
        Add-HUNotifyCategory -Key 'Drucker' -Label 'Drucker' -Default $true | Out-Null
        Add-HUNotifyCategory -Key 'Drucker' -Label 'Druckerfehler' -Default $false | Should -Be ''
        $d = @(Get-HUNotifyCategories | Where-Object Key -eq 'Drucker')
        $d.Count | Should -Be 1
        $d[0].Label | Should -Be 'Druckerfehler'
        Test-HUNotifyCat -Target $null -Category 'Drucker' | Should -BeFalse
    }
    It 'eine eigene Kategorie bleibt Array (PS 5.1) und Datei ist lesbar' {
        Add-HUNotifyCategory -Key 'Wsus' -Label 'WSUS' | Out-Null
        $raw = Get-Content -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-categories.json') -Raw | ConvertFrom-Json
        @($raw.items).Count | Should -Be 1
        $raw.items[0].Key | Should -Be 'Wsus'
    }
    It 'Send-HUNotify sendet mit eigener Kategorie, Fusszeile zeigt die Bezeichnung' {
        Add-HUNotifyCategory -Key 'Backup' -Label 'Backup: Ergebnisse' | Out-Null
        Mock -ModuleName HU.Notify Start-Sleep { }
        Mock -ModuleName HU.Notify Add-HUNotifyHistory { }
        Mock -ModuleName HU.Notify Get-HUNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Targets = @(
            [pscustomobject]@{ Id = 'aaaaaaaa'; Name = 'Admin'; Url = 'https://prod-1.logic.azure.com/w'; Enabled = $true; Cats = @{ Backup = $true } }
            [pscustomobject]@{ Id = 'bbbbbbbb'; Name = 'Direktion'; Url = 'https://prod-2.logic.azure.com/w'; Enabled = $true; Cats = @{ Backup = $false } }
        ) } }
        Mock -ModuleName HU.Notify Invoke-WebRequest { $script:SentBody = [System.Text.Encoding]::UTF8.GetString($Body); $null }
        $r = Send-HUNotify -Category 'Backup' -Title 'Backup HLW fertig' -Level OK
        $r.Ok | Should -Be 1; $r.Failed | Should -Be 0
        $r.Text | Should -Match 'Admin: gesendet'
        $r.Text | Should -Not -Match 'Direktion'
        $script:SentBody | Should -Match 'Backup: Ergebnisse'
    }
    It 'nach dem Entfernen: Unbekannte Kategorie' {
        Add-HUNotifyCategory -Key 'Weg' -Label 'Weg' | Out-Null
        Remove-HUNotifyCategory -Key 'Weg' | Should -Be ''
        (Send-HUNotify -Category 'Weg' -Title 'T').Text | Should -Match 'Unbekannte Kategorie'
        Remove-HUNotifyCategory -Key 'Weg' | Should -Match 'nicht gefunden'
    }
    It 'Haken unbekannter, gueltiger Schluessel bleiben am Ziel erhalten' {
        $c = InModuleScope HU.Notify { ConvertTo-HUNotifyCats @{ Kommt = $true; Daily = $false; 'bad key' = $true } }
        $c['Kommt'] | Should -BeTrue
        $c['Daily'] | Should -BeFalse
        $c.ContainsKey('bad key') | Should -BeFalse
    }
    It 'kaputte Kategorien-Datei: eingebaute funktionieren weiter' {
        New-Item -Path (Join-Path $env:APPDATA 'HU-MultiTenant') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-categories.json') -Value '{ kaputt' -Encoding UTF8
        @(Get-HUNotifyCategories).Count | Should -Be 11
        Test-HUNotifyCat -Target $null -Category 'Daily' | Should -BeTrue
    }
}

Describe 'Teams: Review 030' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-categories.json'), (Join-Path $env:APPDATA 'HU-MultiTenant\notify-history.json') -Force -ErrorAction SilentlyContinue }
    It 'B3: reservierte Schluessel werden abgewiesen, eingebaute Kategorien bleiben intakt' {
        foreach ($k in 'Keys', 'count', 'Values', 'Item', 'PSBase', 'Contains') { Add-HUNotifyCategory -Key $k -Label 'x' | Should -Match 'reserviert|eingebaute|Schluessel' }
        @(Get-HUNotifyCategories).Count | Should -Be 11
    }
    It 'B3: reservierter Schluessel von Hand in der Datei legt nichts lahm' {
        New-Item -Path (Join-Path $env:APPDATA 'HU-MultiTenant') -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $env:APPDATA 'HU-MultiTenant\notify-categories.json') -Encoding UTF8 -Value '{"v":1,"items":[{"Key":"Keys","Label":"x","Default":true},{"Key":"Backup","Label":"B","Default":false}]}'
        $k = @(Get-HUNotifyCategories)
        $k.Count | Should -Be 12
        ($k | Where-Object Key -eq 'Keys') | Should -BeNullOrEmpty
        $c = InModuleScope HU.Notify { ConvertTo-HUNotifyCats @{ Keys = $true; Daily = $false; Backup = $true } }
        $c['Daily'] | Should -BeFalse
        $c['Backup'] | Should -BeTrue
        $c.ContainsKey('Keys') | Should -BeFalse
    }
    It 'B3b: Fakten mit Zahlen-Schluessel und Schluessel Keys bleiben erhalten' {
        $c = New-HUTeamsCard -Title 'T' -Facts ([ordered]@{ 2024 = 'Jahr'; 5 = 'fuenf'; Keys = 'k'; A = '1' })
        $fs = @($c.attachments[0].content.body | Where-Object { $_.type -eq 'FactSet' })[0].facts
        @($fs | ForEach-Object { $_.value }) | Should -Be @('Jahr', 'fuenf', 'k', '1')
    }
    It 'B1: neue Kategorie ist standardmaessig AUS (Add-HUNotifyCategory -Default $false)' {
        Add-HUNotifyCategory -Key 'Backup' -Label 'B' -Default $false | Should -Be ''
        Test-HUNotifyCat -Target ([pscustomobject]@{ Cats = @{ Daily = $true } }) -Category 'Backup' | Should -BeFalse
    }
    It 'B5: hoechstens 5 Knoepfe, ueberlange Adressen fallen weg, auch mit 40 Aktionen unter der Grenze' {
        $acts = 1..40 | ForEach-Object { @{ Title = "Link $_"; Url = 'https://example.com/' + ('x' * 1000) } }
        $c = New-HUTeamsCard -Title 'T' -Actions $acts
        @($c.attachments[0].content.actions).Count | Should -Be 5
        [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $c -Depth 20 -Compress)) | Should -BeLessOrEqual 21000
        (New-HUTeamsCard -Title 'T' -Actions @(@{ Title = 'lang'; Url = 'https://example.com/' + ('y' * 3000) })).attachments[0].content.Contains('actions') | Should -BeFalse
    }
    It 'B5: Send-HUTeamsCard prueft auch fertige JSON-Texte gegen die Grenze' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        Send-HUTeamsCard -Card ('{"x":"' + ('a' * 30000) + '"}') -Url 'https://prod-1.logic.azure.com/w' | Should -Match 'zu gross'
        Should -Invoke -ModuleName HU.Notify Invoke-WebRequest -Times 0 -Exactly
    }
    It 'B9: Send-HUNotify schreibt das Protokoll einmal fuer alle Ziele' {
        Mock -ModuleName HU.Notify Start-Sleep { }
        Mock -ModuleName HU.Notify Invoke-WebRequest { $null }
        Mock -ModuleName HU.Notify Get-HUNotifyConfig { [pscustomobject]@{ Configured = $true; Error = ''; Targets = @(
            [pscustomobject]@{ Id = 'aaaaaaaa'; Name = 'A'; Url = 'https://prod-1.logic.azure.com/w'; Enabled = $true; Cats = $null }
            [pscustomobject]@{ Id = 'bbbbbbbb'; Name = 'B'; Url = 'https://prod-2.logic.azure.com/w'; Enabled = $true; Cats = $null }
        ) } }
        Mock -ModuleName HU.Notify Invoke-HUNotifyLocked { & $Do }
        (Send-HUNotify -Category Daily -Title 'Zwei').Ok | Should -Be 2
        Should -Invoke -ModuleName HU.Notify Invoke-HUNotifyLocked -Times 1 -Exactly
        @(Get-HUNotifyHistory | Where-Object Title -eq 'Zwei').Count | Should -Be 2
    }
    It 'B9: Sperre dauerhaft belegt -> zweiter Versuch, dann WARN im Log, wirft nicht' {
        Mock -ModuleName HU.Notify Start-Sleep { }
        Mock -ModuleName HU.Notify Invoke-HUNotifyLocked { throw 'Datei gerade gesperrt' }
        Mock -ModuleName HU.Notify Write-HUNotifyModuleLog { }
        { Add-HUNotifyHistory -TargetName 'A' -Tag 'x' -Category 'Daily' -Title 'T' -Result 'ok' } | Should -Not -Throw
        Should -Invoke -ModuleName HU.Notify Invoke-HUNotifyLocked -Times 2 -Exactly
        Should -Invoke -ModuleName HU.Notify Write-HUNotifyModuleLog -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Sendeprotokoll' }
    }
    It 'B6: Grundgrenze 21000 Byte - grosse Karten werden darunter gekuerzt' {
        $long = '"x' * 150
        $c = New-HUTeamsCard -Title 'T' -Lines @(1..20 | ForEach-Object { $long }) -Rows @(1..25 | ForEach-Object { @{ Name = "T$_"; Status = 'OK'; Text = $long } })
        [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $c -Depth 20 -Compress)) | Should -BeLessOrEqual 21000
    }
}
