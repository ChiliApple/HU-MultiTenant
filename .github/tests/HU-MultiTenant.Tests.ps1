#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer reine Funktionen von HU-MultiTenant - ohne Netzwerk, ohne Oberflaeche.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1)
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AppRoot = $root
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase }
    if (-not $env:APPDATA) { $env:APPDATA = [System.IO.Path]::GetTempPath() }
    Import-Module (Join-Path $root 'Core\HU.Auth.psm1') -Force -DisableNameChecking
    function Write-HULogWarn { param($Message) }
    function Write-HULogDebug { param($Message) }
    . (Join-Path $root 'Functions\UI-Common.ps1')
    . (Join-Path $root 'Functions\UI-State.ps1')
    . (Join-Path $root 'Functions\UI-Snippets.ps1')
    . (Join-Path $root 'Functions\UI-Settings.ps1')
    . (Join-Path $root 'Functions\UI-Tenants.ps1')
    . (Join-Path $root 'Functions\Core-Update.ps1')
    . (Join-Path $root 'Core\HU.QSParams.ps1')
    . (Join-Path $root 'Functions\UI-QSTable.ps1')
}

Describe 'Secret-Ablauf: Select-AppSecretMatch' {
    It 'erkennt das gespeicherte Secret am Hint' {
        $creds = @(
            [pscustomobject]@{ hint = 'abc'; displayName = 'alt'; endDateTime = '2026-01-01T00:00:00Z' }
            [pscustomobject]@{ hint = 'xYz'; displayName = 'neu'; endDateTime = '2031-06-30T12:00:00Z' }
        )
        $r = Select-AppSecretMatch -PasswordCredentials $creds -Hint 'xYz'
        $r.Matched | Should -BeTrue
        $r.DisplayName | Should -Be 'neu'
        $r.EndDate.Year | Should -Be 2031
    }
    It 'Hint ist case-sensitiv' {
        $creds = @([pscustomobject]@{ hint = 'xyz'; displayName = 'a'; endDateTime = '2031-06-30T12:00:00Z' })
        (Select-AppSecretMatch -PasswordCredentials $creds -Hint 'XYZ').Matched | Should -BeFalse
    }
    It 'ohne Treffer: naechstes noch gueltiges Secret' {
        $creds = @(
            [pscustomobject]@{ hint = 'aaa'; displayName = 'abgelaufen'; endDateTime = '2020-01-01T00:00:00Z' }
            [pscustomobject]@{ hint = 'bbb'; displayName = 'spaet'; endDateTime = '2035-01-01T00:00:00Z' }
            [pscustomobject]@{ hint = 'ccc'; displayName = 'frueh'; endDateTime = '2033-01-01T00:00:00Z' }
        )
        $r = Select-AppSecretMatch -PasswordCredentials $creds -Hint 'zzz'
        $r.Matched | Should -BeFalse
        $r.DisplayName | Should -Be 'frueh'
    }
    It 'keine Secrets: kein Datum' {
        (Select-AppSecretMatch -PasswordCredentials @() -Hint 'abc').EndDate | Should -BeNullOrEmpty
    }
}

Describe 'Secret-Ablauf: Anzeige (Get-HUSecretInfo)' {
    BeforeEach {
        $script:Settings = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; displayName = 'Schule 1' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $script:SecretCache = @{}
    }
    It 'Stufen nach Resttagen' {
        $script:SecretCache['T1'] = [pscustomobject]@{ Status = 'OK'; EndDate = (Get-Date).AddDays(100).ToString('s'); Matched = $true; Checked = (Get-Date).ToString('s'); Error = '' }
        (Get-HUSecretInfo 'T1').Level | Should -Be 'OK'
        $script:SecretCache['T1'].EndDate = (Get-Date).AddDays(20).ToString('s')
        (Get-HUSecretInfo 'T1').Level | Should -Be 'Warn'
        $script:SecretCache['T1'].EndDate = (Get-Date).AddDays(3).ToString('s')
        (Get-HUSecretInfo 'T1').Level | Should -Be 'Critical'
        $script:SecretCache['T1'].EndDate = (Get-Date).AddDays(-2).ToString('s')
        (Get-HUSecretInfo 'T1').Level | Should -Be 'Expired'
    }
    It 'manuelles Datum, wenn Graph nichts liefert' {
        $script:Settings.tenants[0] | Add-Member -NotePropertyName secretExpires -NotePropertyValue ((Get-Date).AddDays(200).ToString('yyyy-MM-dd'))
        $i = Get-HUSecretInfo 'T1'
        $i.Source | Should -Be 'manuell'
        $i.Days | Should -BeGreaterThan 190
    }
    It 'unbekannt ohne Daten' {
        (Get-HUSecretInfo 'T1').Level | Should -Be 'Unknown'
    }
}

Describe 'Snippets: Speicher' {
    BeforeEach {
        $script:SnippetsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("hu-snip-$([guid]::NewGuid().ToString('N')).json")
    }
    AfterEach { Remove-Item "$script:SnippetsPath*" -Force -ErrorAction SilentlyContinue }

    It 'liest alte Dateien ohne Beschreibung' {
        '{ "snippets": [ { "name": "A", "code": "1", "created": "2026-01-02 10:00:00" } ] }' | Set-Content $script:SnippetsPath -Encoding UTF8
        $s = @(Get-HUSnippets)
        $s.Count | Should -Be 1
        $s[0].description | Should -Be ''
        $s[0].modified | Should -Be '2026-01-02 10:00:00'
    }
    It 'anlegen, aendern, umbenennen, Sicherung' {
        Set-HUSnippet -Name 'Eins' -Code 'Get-Date' -Description 'Datum' | Should -BeTrue
        Set-HUSnippet -Name 'Zwei' -Code '1+1' | Should -BeTrue
        @(Get-HUSnippets).Count | Should -Be 2
        Set-HUSnippet -Name 'Eins' -Code 'Get-Date -Format s' | Should -BeTrue
        $e = @(Get-HUSnippets | Where-Object name -eq 'Eins')[0]
        $e.code | Should -Be 'Get-Date -Format s'
        $e.description | Should -Be 'Datum'
        Set-HUSnippet -Name 'Eins neu' -Code $e.code -OldName 'Eins' | Should -BeTrue
        @(Get-HUSnippets).name | Should -Contain 'Eins neu'
        @(Get-HUSnippets).name | Should -Not -Contain 'Eins'
        Test-Path "$($script:SnippetsPath).bak" | Should -BeTrue
    }
    It 'ein einzelnes Snippet bleibt ein JSON-Array' {
        Set-HUSnippet -Name 'Solo' -Code 'x' | Should -BeTrue
        (Get-Content $script:SnippetsPath -Raw) | Should -Match '"snippets":\s*\['
    }
    It 'Favoriten: Standard aus, umschalten, in der Auswahl oben' {
        Set-HUSnippet -Name 'A' -Code '1' | Should -BeTrue
        Set-HUSnippet -Name 'B' -Code '2' | Should -BeTrue
        Set-HUSnippet -Name 'C' -Code '3' | Should -BeTrue
        @(Get-HUSnippets | Where-Object favorite).Count | Should -Be 0
        Switch-HUSnippetFavorite 'C' | Should -BeTrue
        $items = @(Get-HUSnippetComboItems (Get-HUSnippets))
        $items[0].Name | Should -Be 'C'
        $items[0].Fav | Should -BeTrue
        $items[1].Name | Should -Be 'A'
        Set-HUSnippet -Name 'C' -Code '33' | Should -BeTrue
        (Get-HUSnippet 'C').favorite | Should -BeTrue
        Switch-HUSnippetFavorite 'C' | Should -BeFalse
    }
    It 'Umlaute bleiben erhalten' {
        Set-HUSnippet -Name 'Geräte prüfen' -Code '"Größe"' -Description 'für Schüler' | Should -BeTrue
        $e = @(Get-HUSnippets)[0]
        $e.name | Should -Be 'Geräte prüfen'
        $e.description | Should -Be 'für Schüler'
    }
}

Describe 'Einstellungen' {
    It 'ergaenzt fehlende Abschnitte' {
        $s = Initialize-HUSettingsDefaults ([pscustomobject]@{ tenants = @() })
        $s.ui.startTab | Should -Be 'QuickScript'
        $s.ui.secretWarnDays | Should -Be 30
        $s.credentials.credentialNamePrefix | Should -Be 'HU-'
        $s.logging.logLevel | Should -Be 'Info'
    }
    It 'behaelt vorhandene Werte' {
        $s = Initialize-HUSettingsDefaults ([pscustomobject]@{ tenants = @(); ui = [pscustomobject]@{ startTab = 'Extensions' } })
        $s.ui.startTab | Should -Be 'Extensions'
    }
    It 'GUID-Pruefung' {
        Test-HUGuid '5c0ffee0-1234-4abc-8def-0123456789ab' | Should -BeTrue
        Test-HUGuid '<TENANT-ID>' | Should -BeFalse
    }
}

Describe 'Fensterzustand' {
    It 'Verhaeltnis zweier Hoehen' {
        Get-HURatio 300 100 | Should -Be 0.75
        Get-HURatio 0 0 | Should -Be 0
    }
}

Describe 'Update-Bibliothek' {
    It 'Pruefsummen-Datei lesen' {
        $m = ConvertFrom-HMManifest ("{0}  Main.ps1`n{1}  Core/HU.Auth.psm1`n" -f ('a' * 64), ('B' * 64))
        $m['Main.ps1'] | Should -Be ('a' * 64)
        $m['Core/HU.Auth.psm1'] | Should -Be ('b' * 64)
    }
    It 'Kanal Stabil ignoriert Vorab-Releases' {
        $rel = @(
            [pscustomobject]@{ Version = [version]'2.0.1'; Prerelease = $true; ManifestUrl = 'x'; SignatureUrl = 'y' }
            [pscustomobject]@{ Version = [version]'2.0.0'; Prerelease = $false; ManifestUrl = 'x'; SignatureUrl = 'y' }
        )
        (Select-HMRelease $rel 'Stable').Version | Should -Be ([version]'2.0.0')
        (Select-HMRelease $rel 'Test').Version | Should -Be ([version]'2.0.1')
    }
    It 'offizielle Quelle: Signaturpflicht' {
        $cfg = Get-HMUpdateConfig (Join-Path ([System.IO.Path]::GetTempPath()) 'gibt-es-nicht')
        $cfg.Repo | Should -Be 'HU-MultiTenant'
        $cfg.RequireSignature | Should -BeTrue
    }
}

Describe 'Snippet-Parameter' {
    It 'liest @param-Zeilen (Format wie .PARAM)' {
        $code = "# @param DryRun|bool|Nur anzeigen|true`n# @param Tage|int|Tage|30`n# @param Modus|choice|Modus|B|A;B;C`n# @param Name`n# @param 1kaputt|int`nWrite-Host x"
        $p = @(Get-HUQSParams $code)
        $p.Count | Should -Be 4
        $p[0].Type | Should -Be 'bool'
        $p[2].Choices | Should -Be @('A', 'B', 'C')
        $p[3].Type | Should -Be 'string'
        $p[3].Label | Should -Be 'Name'
    }
    It 'Werte typisieren' {
        $b = [pscustomobject]@{ Name = 'X'; Type = 'bool'; Label = 'X' }
        ConvertTo-HUQSParamValue $b 'true' | Should -BeTrue
        ConvertTo-HUQSParamValue $b 'nein' | Should -BeFalse
        $i = [pscustomobject]@{ Name = 'T'; Type = 'int'; Label = 'Tage' }
        ConvertTo-HUQSParamValue $i ' 42 ' | Should -Be 42
        { ConvertTo-HUQSParamValue $i 'abc' } | Should -Throw
    }
    It 'erkennt echten Lauf (DryRun aus)' {
        $p = @(Get-HUQSParams "# @param DryRun|bool|x|true")
        Test-HUQSLiveRun $p @{ DryRun = $true } | Should -BeFalse
        Test-HUQSLiveRun $p @{ DryRun = $false } | Should -BeTrue
        Test-HUQSLiveRun @(Get-HUQSParams "# @param Export|bool|x|true") @{ Export = $false } | Should -BeFalse
    }
}

Describe 'Tabelle' {
    It 'nur echte Objekte' {
        Test-HUQSTableObject 'text' | Should -BeFalse
        Test-HUQSTableObject 5 | Should -BeFalse
        Test-HUQSTableObject (Get-Date) | Should -BeFalse
        Test-HUQSTableObject ([pscustomobject]@{ a = 1 }) | Should -BeTrue
        Test-HUQSTableObject @{ a = 1 } | Should -BeTrue
    }
    It 'Spalten vereinigen, Listen verbinden, @odata weglassen' {
        $r = ConvertTo-HUQSRows @([pscustomobject]@{ A = 1; L = @('x', 'y'); '@odata.type' = 't' }, [pscustomobject]@{ B = 'z' })
        $r.Columns | Should -Be @('A', 'L', 'B')
        $r.Rows[0].L | Should -Be 'x, y'
        $r.Rows[1].A | Should -Be ''
        $r.Rows[1].B | Should -Be 'z'
    }
}

Describe 'Snippet-Kategorien' {
    BeforeEach { $script:SnippetsPath = Join-Path ([System.IO.Path]::GetTempPath()) ("hu-snip-$([guid]::NewGuid().ToString('N')).json") }
    AfterEach { Remove-Item "$script:SnippetsPath*" -Force -ErrorAction SilentlyContinue }
    It 'Favoriten zuerst, dann Kategorien alphabetisch, ohne Kategorie zuletzt' {
        '{ "snippets": [ {"name":"u1","code":"1"}, {"name":"i1","code":"1","category":"Intune"}, {"name":"b1","code":"1","category":"Benutzer"}, {"name":"f1","code":"1","category":"Intune","favorite":true}, {"name":"i2","code":"1","category":"Intune"} ] }' | Set-Content $script:SnippetsPath -Encoding UTF8
        $items = @(Get-HUSnippetComboItems (Get-HUSnippets))
        ($items | ForEach-Object Name) -join ',' | Should -Be 'f1,b1,i1,i2,u1'
        $items[1].CatShort | Should -Be '[Benutzer]'
        Get-HUSnippetCategories (Get-HUSnippets) | Should -Be @('Benutzer', 'Intune')
    }
    It 'Beispiel-Snippets sind gueltig' {
        $ex = Join-Path $script:AppRoot 'Config\quick-snippets.example.json'
        $j = Get-Content $ex -Raw -Encoding UTF8 | ConvertFrom-Json
        @($j.snippets).Count | Should -BeGreaterThan 8
        foreach ($s in $j.snippets) {
            $t = $null; $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($s.code, [ref]$t, [ref]$e)
            "$($s.name): $($e.Count)" | Should -Be "$($s.name): 0"
            $s.description | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Quick-Script-Laufzeit' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Graph.psm1') -Force -DisableNameChecking
        . (Join-Path $script:AppRoot 'Core\HU.QSRuntime.ps1')
    }
    It 'Get-HUToken merkt sich den Tenant, Update-HUQSToken holt ein aktuelles Token' {
        $global:Settings = [pscustomobject]@{ tenants = @() }
        $global:TenantKey = 'T1'
        $script:calls = 0
        Mock Get-GraphToken { $script:calls++; "tok-$TenantKey-$($script:calls)" }
        $t1 = Get-HUToken
        $t1 | Should -Be 'tok-T1-1'
        Update-HUQSToken $t1 | Should -Be 'tok-T1-2'
        Update-HUQSToken 'fremd' | Should -Be 'fremd'
        (Get-HUToken -Tenant 'T2') | Should -Be 'tok-T2-3'
    }
}

Describe 'Graph-Batch (Invoke-GraphBatchGet)' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Graph.psm1') -Force -DisableNameChecking
    }
    It 'teilt in Pakete zu 20 und liefert nur Status 200' {
        $script:calls = 0
        Mock -ModuleName HU.Graph Invoke-GraphRequest {
            $script:calls++
            [pscustomobject]@{ responses = @($Body.requests | ForEach-Object { [pscustomobject]@{ id = $_.id; status = $(if ($_.url -like '*x3') { 404 } else { 200 }); body = [pscustomobject]@{ url = $_.url } } }) }
        }
        $req = @{}; 1..45 | ForEach-Object { $req["k$_"] = "/u/x$_" }
        $r = Invoke-GraphBatchGet -Token 't' -Requests $req
        $script:calls | Should -Be 3
        $r.Count | Should -Be 44
        $r['k7'].url | Should -Be '/u/x7'
    }
    It 'wiederholt 429 nach Wartezeit' {
        $script:n = 0
        Mock -ModuleName HU.Graph Start-Sleep { }
        Mock -ModuleName HU.Graph Invoke-GraphRequest {
            $script:n++
            $st = if ($script:n -eq 1) { 429 } else { 200 }
            [pscustomobject]@{ responses = @($Body.requests | ForEach-Object { [pscustomobject]@{ id = $_.id; status = $st; headers = [pscustomobject]@{ 'Retry-After' = '1' }; body = 'ok' } }) }
        }
        $r = Invoke-GraphBatchGet -Token 't' -Requests @{ a = '/a'; b = '/b' }
        $script:n | Should -Be 2
        $r.Count | Should -Be 2
    }
}

Describe 'Intune: Apps und Wartung (HU.Intune)' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    }
    It 'MSI-Erkennung mit Mindestversion' {
        $r = ConvertTo-HUDetectionRule ([pscustomobject]@{ Type = 'msi'; ProductCode = '{11111111-2222-3333-4444-555555555555}'; Version = '1.2.3'; VersionCheck = $true })
        $r['@odata.type'] | Should -Be '#microsoft.graph.win32LobAppProductCodeRule'
        $r.productVersionOperator | Should -Be 'greaterThanOrEqual'
        $r.productVersion | Should -Be '1.2.3'
    }
    It 'Registry-Erkennung ohne Wert = vorhanden' {
        $r = ConvertTo-HUDetectionRule ([pscustomobject]@{ Type = 'registry'; KeyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\X'; ValueName = ''; Check32 = $true })
        $r.operationType | Should -Be 'exists'
        $r.check32BitOn64System | Should -BeTrue
    }
    It 'ungueltige Erkennung wird abgelehnt' {
        { ConvertTo-HUDetectionRule ([pscustomobject]@{ Type = 'msi'; ProductCode = 'abc' }) } | Should -Throw
        { ConvertTo-HUDetectionRule ([pscustomobject]@{ Type = 'file'; Path = 'C:\X' }) } | Should -Throw
    }
    It 'Win32-Payload: Pflichtfelder, Kontext, MSI-Info' {
        $def = [pscustomobject]@{ Name = 'Test'; Publisher = ''; Description = ''; Version = '1.0'; SetupFile = 'a.msi'; InstallCmd = 'msiexec /i "a.msi" /qn'; UninstallCmd = 'msiexec /x {11111111-2222-3333-4444-555555555555} /qn'
            RunAs = 'user'; Kind = 'msi'; UpgradeCode = ''; Detection = [pscustomobject]@{ Type = 'msi'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
        $p = ConvertTo-HUWin32Payload $def 'a.intunewin'
        $p.fileName | Should -Be 'a.intunewin'
        $p.installExperience.runAsAccount | Should -Be 'user'
        $p.installExperience.deviceRestartBehavior | Should -Be 'suppress'
        $p.publisher | Should -Be '-'
        $p.msiInformation.productCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
        @($p.rules).Count | Should -Be 1
        $def.UninstallCmd = ''
        { ConvertTo-HUWin32Payload $def } | Should -Throw
    }
    It 'Zeitplan taeglich / stuendlich / einmal' {
        $d = New-HURunSchedule @{ Type = 'daily'; Interval = 2; Time = '7:30' }
        $d['@odata.type'] | Should -Be '#microsoft.graph.deviceHealthScriptDailySchedule'
        $d.time | Should -Be '07:30:00.0000000'
        $d.interval | Should -Be 2
        (New-HURunSchedule @{ Type = 'hourly'; Interval = 50 }).interval | Should -Be 23
        (New-HURunSchedule @{ Type = 'once'; Time = '08:00'; Date = '2026-11-02' }).date | Should -Be '2026-11-02'
    }
    It 'Remediation-Payload: Base64 UTF-8 ohne BOM' {
        $p = ConvertTo-HURemediationPayload ([pscustomobject]@{ Name = 'X'; Description = ''; Detection = "Write-Output 'ä'; exit 0"; Remediation = ''; RunAs = 'system'; RunAs32 = $false })
        $bytes = [Convert]::FromBase64String($p.detectionScriptContent)
        $bytes[0] | Should -Not -Be 0xEF
        [Text.Encoding]::UTF8.GetString($bytes) | Should -Match 'ä'
        $p.runAsAccount | Should -Be 'system'
    }
    It 'Skriptpruefung findet typische Fehler' {
        $r = @(Test-HURemediationScript -Code "Write-Output 'x'`nRestart-Computer`nexit 0" -Kind detection)
        @($r | Where-Object { $_.Stufe -eq 'Fehler' }).Count | Should -Be 2
        $ok = @(Test-HURemediationScript -Code "if (1) { Write-Output 'p'; exit 1 }`nWrite-Output 'ok'; exit 0" -Kind detection)
        @($ok | Where-Object { $_.Stufe -in 'Fehler', 'Warnung' }).Count | Should -Be 0
        @(Test-HURemediationScript -Code 'Set-ItemProperty HKCU:\X -Name a -Value 1' -Kind remediation -RunAs system | Where-Object { $_.Stufe -eq 'Warnung' }).Count | Should -BeGreaterThan 0
    }
    It 'KI-Antwort wird aufgeteilt (Codebloecke und Ueberschriften)' {
        $t = "Hier:`n``````powershell`nexit 1`n```````n``````powershell`nexit 0`n``````"
        $s = Split-HUAiAnswer $t
        $s.Detection | Should -Be 'exit 1'
        $s.Remediation | Should -Be 'exit 0'
        $s2 = Split-HUAiAnswer "### Pruefskript`nA`n### Reparaturskript`nB"
        $s2.Detection | Should -Be 'A'
        $s2.Remediation | Should -Be 'B'
        (Get-HUAiPrompt -Task 'Test') | Should -Match '### Pruefskript'
    }
    It 'Sandbox-Ergebnis -> Erkennung und Deinstallation' {
        $msi = ConvertFrom-HUSandboxEntry ([pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{11111111-2222-3333-4444-555555555555}'; DisplayName = 'A'; DisplayVersion = '2.0'; UninstallString = 'MsiExec.exe /I{11111111-2222-3333-4444-555555555555}'; QuietUninstallString = '' })
        $msi.Detection.Type | Should -Be 'msi'
        $msi.UninstallCmd | Should -Be 'msiexec /x {11111111-2222-3333-4444-555555555555} /qn /norestart'
        $reg = ConvertFrom-HUSandboxEntry ([pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Foo_is1'; DisplayName = 'Foo'; DisplayVersion = '1.5'; UninstallString = 'x'; QuietUninstallString = '"C:\Foo\unins000.exe" /SILENT' })
        $reg.Detection.Type | Should -Be 'registry'
        $reg.Detection.Check32 | Should -BeTrue
        $reg.Detection.KeyPath | Should -Not -Match 'WOW6432Node'
        $reg.UninstallCmd | Should -Match 'unins000'
        $best = Select-HUSandboxEntry -Entries @([pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2015 Redistributable'; UninstallString = 'x' }, [pscustomobject]@{ DisplayName = 'Foo Editor'; UninstallString = 'y' }) -AppName 'Foo Editor 3'
        $best.DisplayName | Should -Be 'Foo Editor'
    }
    It 'Store-ID erkennen' {
        Get-HUStoreIdFromText 'https://apps.microsoft.com/detail/9nksqgp7f2nh?hl=de-at' | Should -Be '9NKSQGP7F2NH'
        Get-HUStoreIdFromText 'XP89DCGQ3K6VLD' | Should -Be 'XP89DCGQ3K6VLD'
        Test-HUStoreId 'ABC' | Should -BeFalse
    }
    It 'Quellordner wird nur bei Aenderung neu kopiert' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hu-src-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$tmp\in" -Force | Out-Null
        Set-Content -LiteralPath "$tmp\in\setup.exe" -Value 'x'
        Set-Content -LiteralPath "$tmp\in\config.ini" -Value 'y'
        $a = Sync-HUAppSource -SetupPath "$tmp\in\setup.exe" -WholeFolder $true -Destination "$tmp\out"
        $a.Copied | Should -BeTrue
        @(Get-ChildItem "$tmp\out").Count | Should -Be 2
        (Sync-HUAppSource -SetupPath "$tmp\in\setup.exe" -WholeFolder $true -Destination "$tmp\out").Copied | Should -BeFalse
        $b = Sync-HUAppSource -SetupPath "$tmp\in\setup.exe" -WholeFolder $false -Destination "$tmp\out"
        $b.Copied | Should -BeTrue
        @(Get-ChildItem "$tmp\out").Count | Should -Be 1
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

Describe 'Intune: App-Symbol' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    }
    It 'Symbol-Ort aus DisplayIcon lesen' {
        $l = Split-HUIconLocation '"C:\Program Files\Foo\foo.exe",-101'
        $l.Path | Should -Be 'C:\Program Files\Foo\foo.exe'
        $l.Index | Should -Be -101
        (Split-HUIconLocation 'C:\x\a.ico').Index | Should -Be 0
    }
    It 'Bild wird auf 256 px verkleinert und als largeIcon mitgegeben' -Skip:($env:OS -ne 'Windows_NT') {
        Add-Type -AssemblyName System.Drawing
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hu-icon-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $b = New-Object System.Drawing.Bitmap(400, 200); $b.Save("$tmp\in.jpg", [System.Drawing.Imaging.ImageFormat]::Jpeg); $b.Dispose()
        [void](ConvertTo-HUIconPng -Path "$tmp\in.jpg" -OutFile "$tmp\out.png")
        $img = [System.Drawing.Image]::FromFile("$tmp\out.png"); $img.Width | Should -Be 256; $img.Height | Should -Be 128; $img.Dispose()
        [void](ConvertTo-HUIconPng -Path "$env:windir\System32\notepad.exe" -OutFile "$tmp\np.png")
        (Get-Item "$tmp\np.png").Length | Should -BeGreaterThan 100
        $def = [pscustomobject]@{ Name = 'T'; Version = '1'; SetupFile = 's.exe'; InstallCmd = 's.exe /S'; UninstallCmd = 'u.exe /S'; RunAs = 'system'; Kind = 'exe'
            Detection = [pscustomobject]@{ Type = 'file'; Path = 'C:\T'; FileName = 't.exe' }; IconFile = "$tmp\out.png" }
        $p = ConvertTo-HUWin32Payload $def
        $p.largeIcon.type | Should -Be 'image/png'
        $p.largeIcon.value.Length | Should -BeGreaterThan 100
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

Describe 'Intune: Gruppen' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'nur zuweisbare Gruppen, Typ lesbar' {
        (ConvertTo-HUGroupRow ([pscustomobject]@{ id = '1'; displayName = 'A'; groupTypes = @(); securityEnabled = $true })).Typ | Should -Be 'Sicherheit'
        (ConvertTo-HUGroupRow ([pscustomobject]@{ id = '2'; displayName = 'B'; groupTypes = @('Unified', 'DynamicMembership'); securityEnabled = $false })).Typ | Should -Be 'Microsoft 365 (dynamisch)'
        ConvertTo-HUGroupRow ([pscustomobject]@{ id = '3'; displayName = 'Verteiler'; groupTypes = @(); securityEnabled = $false; mailEnabled = $true }) | Should -BeNullOrEmpty
    }
}

Describe 'Intune: stille Deinstallation' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'ergaenzt NSIS-, Inno- und laesst MSI/stille Befehle in Ruhe' {
        Add-HUSilentUninstall '"C:\Program Files (x86)\VideoLAN\VLC\uninstall.exe"' 'NSIS' | Should -Be '"C:\Program Files (x86)\VideoLAN\VLC\uninstall.exe" /S'
        Add-HUSilentUninstall 'C:\Program Files\Foo\unins000.exe' | Should -Be '"C:\Program Files\Foo\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        Add-HUSilentUninstall '"C:\x\setup.exe" --uninstall' | Should -Be '"C:\x\setup.exe" --uninstall'
        Add-HUSilentUninstall '"C:\x\uninstall.exe" /S' | Should -Be '"C:\x\uninstall.exe" /S'
        Add-HUSilentUninstall 'MsiExec.exe /X{1}' | Should -Be 'MsiExec.exe /X{1}'
        $e = ConvertFrom-HUSandboxEntry ([pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player'; DisplayName = 'VLC media player'; DisplayVersion = '3.0.23'; UninstallString = '"C:\Program Files (x86)\VideoLAN\VLC\uninstall.exe"'; QuietUninstallString = '' }) -InstallerType 'NSIS'
        $e.UninstallCmd | Should -Match '/S$'
    }
}

Describe 'Intune: Abhaengigkeiten' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'ersetzt Abhaengigkeiten, behaelt Ersetzungen (Supersedence)' {
        $ex = @(
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetType = 'child'; targetId = 'old'; supersedenceType = 'update' }
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetType = 'child'; targetId = 'gone'; dependencyType = 'autoInstall' }
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetType = 'parent'; targetId = 'parentApp'; dependencyType = 'autoInstall' }
        )
        $b = Get-HUDependencyBody -Existing $ex -DependencyIds @('drv', 'rt', 'drv') -AutoInstall $true
        $r = @($b.relationships)
        $r.Count | Should -Be 3
        @($r | Where-Object { $_['@odata.type'] -match 'Supersedence' }).Count | Should -Be 1
        @($r | Where-Object { $_.targetId -eq 'gone' }).Count | Should -Be 0
        @($r | Where-Object { $_['@odata.type'] -match 'Dependency' } | ForEach-Object { $_.dependencyType } | Select-Object -Unique) | Should -Be 'autoInstall'
        (@((Get-HUDependencyBody -Existing @() -DependencyIds @('x') -AutoInstall $false).relationships)[0]).dependencyType | Should -Be 'detect'
        ((Get-HUDependencyBody -Existing @() -DependencyIds @()) | ConvertTo-Json -Compress) | Should -Be '{"relationships":[]}'
    }
}

Describe 'Intune: vorhandene Apps und Installationshuelle' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'Zuweisung wird lesbar und ueber Tenants vergleichbar' {
        $a = [pscustomobject]@{ intent = 'required'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' }; settings = [pscustomobject]@{ notifications = 'hideAll'; installTimeSettings = $null } }
        $r = ConvertFrom-HUAssignment $a @{ g1 = 'Schueler' }
        $r.Key | Should -Be 'group|schueler'
        $r.Ziel | Should -Be 'Schueler'
        $r.Notify | Should -Be 'hideAll'
        $x = ConvertFrom-HUAssignment ([pscustomobject]@{ intent = 'required'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g1' } }) @{ g1 = 'Lehrer' }
        $x.Ziel | Should -Be 'Ausschluss: Lehrer'
        (ConvertFrom-HUAssignment ([pscustomobject]@{ intent = 'available'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } })).Kind | Should -Be 'allUsers'
        Get-HUAppKindFromType '#microsoft.graph.winGetApp' | Should -Be 'winget'
        Get-HUAppKindFromType 'officeSuiteApp' | Should -Be 'other'
    }
    It 'ohne Desktop-Verknuepfung: Huelle und Befehl' {
        $p = Get-HUInstallPlan ([pscustomobject]@{ InstallCmd = '"vlc.exe" /S'; NoDesktop = $true })
        $p.Cmd | Should -Match 'Sysnative.*HU-Install\.ps1'
        $p.Extra['HU-Install.ps1'] | Should -Match 'exit \$p\.ExitCode'
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($p.Extra['HU-Install.ps1'], [ref]$null, [ref]$e); @($e).Count | Should -Be 0
        (Get-HUInstallPlan ([pscustomobject]@{ InstallCmd = 'a.exe'; NoDesktop = $true }) -Sandbox).Cmd | Should -Match '^powershell\.exe'
        (Get-HUInstallPlan ([pscustomobject]@{ InstallCmd = 'a.exe /S'; NoDesktop = $false })).Cmd | Should -Be 'a.exe /S'
    }
}
