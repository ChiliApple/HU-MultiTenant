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
        $tb[-2].text | Should -Match 'weitere Zeilen'
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
        Send-HUNotify -Category 'Daily' -Title 'T' | Should -Be ''
        Send-HUNotify -Category 'Gibtsnicht' -Title 'T' | Should -Match 'Unbekannte Kategorie'
    }
    It 'Fehlermeldungen enthalten nie die Adresse' {
        Mock -ModuleName HU.Notify Invoke-WebRequest { throw 'Fehler bei https://prod-1.logic.azure.com/workflows/abc?sig=geheim' }
        $r = Send-HUTeamsCard -Card (New-HUTeamsCard -Title 'T') -Url 'https://prod-1.logic.azure.com/workflows/abc?sig=geheim' -Retries 0
        $r | Should -Match 'fehlgeschlagen'
        $r | Should -Not -Match 'geheim'
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
