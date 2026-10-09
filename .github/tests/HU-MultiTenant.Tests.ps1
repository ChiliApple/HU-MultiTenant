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

Describe 'Apps: Kategorien (Set-HUAppCategories)' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'setzt nur vorhandene, fuegt hinzu und entfernt ueberzaehlige' {
        InModuleScope HU.Intune {
            $script:calls = New-Object System.Collections.Generic.List[string]
            Mock Get-HUIntuneGraphAll {
                if ($Endpoint -like '*/mobileAppCategories') { return @([pscustomobject]@{ id = 'c1'; displayName = 'Schule' }, [pscustomobject]@{ id = 'c2'; displayName = 'Alt' }) }
                return @([pscustomobject]@{ id = 'c2' })
            }
            Mock Invoke-HUIntuneGraph { $script:calls.Add("$Method $Endpoint") }
            $r = Set-HUAppCategories -TenantKey 't' -Settings ([pscustomobject]@{}) -AppId 'a1' -Names @('Schule', 'Gibtsnicht', 'Schule')
            $r | Should -Match 'nicht vorhanden: Gibtsnicht'
            $script:calls | Should -Not -Contain 'POST /deviceAppManagement/mobileAppCategories'
            $script:calls | Should -Contain 'POST /deviceAppManagement/mobileApps/a1/categories/$ref'
            $script:calls | Should -Contain 'DELETE /deviceAppManagement/mobileApps/a1/categories/c2/$ref'
        }
    }
    It 'keine passende Kategorie -> nichts entfernen' {
        InModuleScope HU.Intune {
            Mock Get-HUIntuneGraphAll { return @([pscustomobject]@{ id = 'c1'; displayName = 'Schule' }) }
            Mock Invoke-HUIntuneGraph { throw 'darf nicht aufgerufen werden' }
            Set-HUAppCategories -TenantKey 't' -Settings ([pscustomobject]@{}) -AppId 'a1' -Names @('Gibtsnicht') | Should -Match 'nichts geaendert'
        }
    }
    It 'leere Liste aendert nichts' {
        InModuleScope HU.Intune {
            Mock Invoke-HUIntuneGraph { throw 'darf nicht aufgerufen werden' }
            Mock Get-HUIntuneGraphAll { throw 'darf nicht aufgerufen werden' }
            Set-HUAppCategories -TenantKey 't' -Settings ([pscustomobject]@{}) -AppId 'a1' -Names @(' ', '') | Should -Be ''
        }
    }
}

Describe 'Analyse: Zuweisungen' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'Gruppe, verschachtelt, Alle Geraete, Ausschluss' {
        $t = @{ Groups = @{ 'g1' = 'Schueler'; 'p1' = 'Alle Schueler (ueber Schueler)' }; AllDevices = $true; AllUsers = $false }
        $a = @([pscustomobject]@{ intent = 'required'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'p1' } })
        $m = Test-HUAssignmentMatch $a $t
        $m.Via | Should -Be @('Alle Schueler (ueber Schueler)'); $m.Intent | Should -Be @('required'); $m.Excluded.Count | Should -Be 0
        $m2 = Test-HUAssignmentMatch @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }, [pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g1' } }) $t
        $m2.Via | Should -Be @('Alle Geraete'); $m2.Excluded | Should -Be @('Schueler')
        Test-HUAssignmentMatch @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }) $t | Should -BeNullOrEmpty
        Test-HUAssignmentMatch @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'zz' } }) $t | Should -BeNullOrEmpty
    }
    It 'Bericht: Zeilen je Objektart, Fehler einer Art bricht nicht ab' {
        if (-not (Get-Command Write-HULog -ErrorAction SilentlyContinue)) { function global:Write-HULog { param($Message, $Level, $Tenant) } }
        InModuleScope HU.Intune {
            Mock Resolve-HUAssignmentTarget { @{ Label = 'Schueler'; Groups = @{ 'g1' = 'Schueler' }; AllDevices = $true; AllUsers = $true; Note = '' } }
            Mock Get-HUIntuneGraphAll {
                if ($Endpoint -like '/deviceAppManagement/mobileApps*') { return @([pscustomobject]@{ displayName = '7-Zip'; assignments = @([pscustomobject]@{ intent = 'required'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }) }) }
                if ($Endpoint -like '*configurationPolicies*') { return @([pscustomobject]@{ name = 'Edge'; assignments = @([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) }) }
                if ($Endpoint -like '*deviceHealthScripts*') { throw '403' }
                return @()
            }
            $r = @(Get-HUAssignmentReport -TenantKey 't' -Settings ([pscustomobject]@{}) -Kind group -Name 'Schueler')
            $r.Count | Should -Be 2
            ($r | Where-Object Typ -eq 'App').Absicht | Should -Be 'Erforderlich'
            ($r | Where-Object Typ -eq 'Einstellungskatalog').Ueber | Should -Be 'Alle Geraete'
        }
    }
    It 'Benutzer ohne Domain: UPN-Anfang, mit Intune-Geraeten und deren Gruppen' {
        InModuleScope HU.Intune {
            Mock Invoke-HUIntuneGraph {
                if ($Endpoint -like '/users?*startswith*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'u1'; displayName = 'Max'; userPrincipalName = 'max@schule.at' }) } }
                if ($Endpoint -like '/devices?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'd1' }) } }
                throw "unerwartet: $Endpoint"
            }
            Mock Get-HUIntuneGraphAll {
                if ($Endpoint -like '/users/u1/transitiveMemberOf*') { return @([pscustomobject]@{ id = 'gu'; displayName = '3A' }) }
                if ($Endpoint -like '/deviceManagement/managedDevices*') { return @([pscustomobject]@{ id = 'm1'; deviceName = 'NB01'; azureADDeviceId = 'aad1' }) }
                if ($Endpoint -like '/devices/d1/transitiveMemberOf*') { return @([pscustomobject]@{ id = 'gd'; displayName = 'MDM-Notebooks' }) }
                return @()
            }
            $t = Resolve-HUAssignmentTarget -TenantKey 't' -Settings ([pscustomobject]@{}) -Kind user -Name 'max'
            $t.Label | Should -Match '^max@schule\.at'
            $t.Groups['gu'] | Should -Match '3A'
            $t.Groups['gd'] | Should -Match 'MDM-Notebooks.*NB01'
            $t.AllDevices | Should -BeTrue
            $t.AllUsers | Should -BeTrue
        }
    }
}

Describe 'Release-Texte' {
    It 'keine @-Erwaehnungen ausserhalb von Code (GitHub macht daraus Benutzer-Erwaehnungen/Contributors)' {
        $bad = @()
        foreach ($f in 'CHANGELOG.md', 'README.md') {
            $n = 0
            foreach ($ln in Get-Content -LiteralPath (Join-Path $script:AppRoot $f) -Encoding UTF8) {
                $n++
                $plain = [regex]::Replace($ln, '`[^`]*`', '')
                if ($plain -match '(?<![\w.])@[A-Za-z0-9][A-Za-z0-9-]*') { $bad += "${f}:$n $($Matches[0])" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Wartung: @param-Felder' {
    It 'Wert setzen und wieder lesen (Sonderzeichen, Zahl, Ja/Nein)' {
        $code = "# @param Pw|string|Passwort|`n# @param Max|int|Max|3`n# @param On|bool|An|true`nexit 0"
        $c = Set-HURemParamValues $code @{ Pw = "a'b’c # d" } -FillDefaults
        $v = Get-HURemParamValues $c
        $v.Pw | Should -BeExactly "a'b’c # d"
        $v.Max | Should -Be 3
        $v.On | Should -BeTrue
        $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($c, [ref]$null, [ref]$e); @($e).Count | Should -Be 0
    }
    It 'vorhandene Wertzeile wird ersetzt, nicht verdoppelt' {
        $c = Set-HURemParamValues "# @param X|string|X|`n`$X = 'alt'  # @value`nexit 0" @{ X = 'neu' }
        ([regex]::Matches($c, '@value')).Count | Should -Be 1
        (Get-HURemParamValues $c).X | Should -Be 'neu'
    }
    It 'mehrzeiliger Text und ungueltige Zahl werden abgelehnt' {
        { Set-HURemParamValues "# @param X|string|X|" @{ X = "a`nb" } } | Should -Throw
        { Set-HURemParamValues "# @param N|int|N|" @{ N = 'abc' } } | Should -Throw
    }
    It 'Pruefung: Verwendung vor dem Feld, param()-Block, Funktion' {
        @(Test-HURemParams "Write-Output `$X`n# @param X|string|X|`n`$X = 'a'  # @value" | Where-Object Stufe -eq 'Fehler').Count | Should -Be 1
        @(Test-HURemParams "param(`$a)`n# @param X|string|X|`n`$X = 'a'  # @value" | Where-Object Stufe -eq 'Fehler').Count | Should -BeGreaterThan 0
        @(Test-HURemParams "function F {`n# @param X|string|X|`n`$X = 'a'  # @value`n}" | Where-Object Stufe -eq 'Fehler').Count | Should -Be 1
        @(Test-HURemParams "# @param X|string|X|`n`$X = 'a'  # @value`nWrite-Output `$X").Count | Should -Be 0
    }
    It 'Zuweisungen am Anfang werden zu Feldern' {
        $code = "`$Name = 'GymAdmin'`n`$N = 5`n`$B = `$true`n`$D = Get-Date`n`$Spaet = 'x'"
        @(Get-HURemParamCandidates $code | ForEach-Object Name) | Should -Be @('Name', 'N', 'B')
        $c = Convert-HURemAssignToParam $code @('Name', 'N', 'B')
        $v = Get-HURemParamValues $c
        $v.Name | Should -Be 'GymAdmin'; $v.N | Should -Be 5; $v.B | Should -BeTrue
        @(Get-HUQSParams $c).Count | Should -Be 3
        @(Test-HURemParams $c).Count | Should -Be 0
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

Describe 'Intune: Seitenweises Lesen und App-Liste' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking
        if (-not (Get-Command Write-HULog -ErrorAction SilentlyContinue)) { function global:Write-HULog { param($Message, $Level, $Tenant) } }
    }
    It 'liefert einzelne Eintraege (nicht ein verschachteltes Array) und filtert Windows-Apps' {
        Mock -ModuleName HU.Intune Invoke-HUIntuneGraph {
            if ($Endpoint -like '*mobileApps*') {
                [pscustomobject]@{ value = @(
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobApp'; id = '1'; displayName = 'VLC'; displayVersion = '3'; publisher = 'V'; assignments = @([pscustomobject]@{ intent = 'required'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }) }
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.iosStoreApp'; id = '2'; displayName = 'iOS'; assignments = @() }
                        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.winGetApp'; id = '3'; displayName = 'Teams'; assignments = @() }
                    ) }
            } else { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g1'; displayName = 'Schueler' }) } }
        }
        @(Get-HUIntuneGraphAll -TenantKey 't' -Settings @{} -Endpoint '/deviceAppManagement/mobileApps').Count | Should -Be 3
        $l = @(Get-HUTenantAppList -TenantKey 't' -Settings @{})
        $l.Count | Should -Be 2
        ($l | Where-Object Name -eq 'VLC').Assignments[0].Ziel | Should -Be 'Schueler'
        ($l | Where-Object Name -eq 'Teams').Kind | Should -Be 'winget'
    }
}

Describe 'Support: Anonymisieren' {
    BeforeAll { . (Join-Path $script:AppRoot 'Functions\UI-Support.ps1') }
    It 'ersetzt Namen, Mails, IDs, IPs und Tokens' {
        $map = @(@{ From = 'Musterschule Nord'; To = 'Tenant-1' }, @{ From = 'musterschule.example'; To = 'Tenant-1' })
        $t = ConvertTo-HURedacted 'Musterschule Nord: max.muster@musterschule.example an 192.0.2.10 id 0f0f0f0f-1234-4abc-9def-0123456789ab Bearer eyJhbGciOiJSUzI1NiIs.eyJhdWQiOiJodHRwczov.abc sig=XYZ' $map
        $t | Should -Not -Match 'Musterschule|max\.muster|192\.0\.2\.10|1234-4abc|XYZ'
        $t | Should -Match 'Tenant-1'
        $t | Should -Match '0f0f0f0f-\*\*\*\*'
    }
}

Describe 'Intune: Inno-Deinstallation (Greenshot-Fall)' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It '/SILENT wird zu /VERYSILENT, laufende App wird vorher beendet, kein doppeltes Anhaengen' {
        $e = ConvertFrom-HUSandboxEntry ([pscustomobject]@{ Key = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Greenshot_is1'; DisplayName = 'Greenshot'; DisplayVersion = '1.3'
                UninstallString = '"C:\Program Files\Greenshot\unins000.exe"'; QuietUninstallString = '"C:\Program Files\Greenshot\unins000.exe" /SILENT'; DisplayIcon = 'C:\Program Files\Greenshot\Greenshot.exe' }) 'Inno Setup'
        $e.UninstallCmd | Should -Be 'cmd.exe /c "taskkill /f /im "Greenshot.exe" >nul 2>&1 & "C:\Program Files\Greenshot\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"'
        Add-HUSilentUninstall $e.UninstallCmd 'Inno Setup' | Should -Be $e.UninstallCmd
        (Get-HUExeInstallerType -Path $PSCommandPath).Type | Should -Not -BeNullOrEmpty
    }
}

Describe 'Wartung: vorhandene Skripte lesen' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'liest Zeitplaene, Zuweisungen, Skripttext und Status' {
        (ConvertFrom-HURunSchedule ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceHealthScriptDailySchedule'; interval = 2; time = '07:30:00.0000000'; useUtc = $false })).Text | Should -Be 'alle 2 Tage um 07:30'
        $o = ConvertFrom-HURunSchedule ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceHealthScriptRunOnceSchedule'; interval = 1; time = '7:05:00'; date = '2026-10-12'; useUtc = $false })
        $o.Type | Should -Be 'once'; $o.Date | Should -Be '12.10.2026'; $o.Time | Should -Be '07:05'
        (ConvertFrom-HURunSchedule ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'; interval = 4 })).Text | Should -Be 'alle 4 Std.'
        $a = ConvertFrom-HURemAssignment ([pscustomobject]@{ target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g1' }; runRemediationScript = $true; runSchedule = $null }) @{ g1 = 'Lehrer' }
        $a.Key | Should -Be 'exclude|lehrer'; $a.Zeitplan | Should -Be ''
        ConvertFrom-HUBase64Text ([Convert]::ToBase64String([byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('exit 1'))) | Should -Be 'exit 1'
        ConvertFrom-HUBase64Text (ConvertTo-HUBase64Utf8 "Write-Output 'Ä'") | Should -Be "Write-Output 'Ä'"
        ConvertTo-HUInstallStateText '3' | Should -Be 'Nicht installiert'
        ConvertTo-HUInstallStateText 'Installed' | Should -Be 'Installiert'
    }
}

Describe 'App-Updates: winget' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Winget.psm1') -Force -DisableNameChecking }
    It 'Versionen vergleichen' {
        Compare-HUVersion '24.08' '24.09' | Should -Be -1
        Compare-HUVersion '1.10' '1.9' | Should -Be 1
        Compare-HUVersion 'v3.0' '3.0.0.0' | Should -Be 0
        Compare-HUVersion '131.0.6778.86' '131.0.6778.109' | Should -Be -1
        Compare-HUVersion '2.0' '2.0-beta' | Should -Not -Be 0
    }
    It 'Suchtabelle zerlegen (deutsche Kopfzeile, Fortschritt davor)' {
        $lines = @(
            '   - ',
            'Name                ID                 Version   Übereinstimmung  Quelle',
            '-------------------------------------------------------------------------',
            '7-Zip               7zip.7zip          24.09                      winget',
            '7-Zip ZS            mcmilk.7zip-zstd   24.09.0.0 Tag: 7zip        winget'
        )
        $r = @(ConvertFrom-HUWingetTable $lines)
        $r.Count | Should -Be 2
        $r[0].Id | Should -Be '7zip.7zip'
        $r[0].Version | Should -Be '24.09'
        $r[1].Id | Should -Be 'mcmilk.7zip-zstd'
    }
    It 'neueste Version aus winget show (ohne Modul)' {
        InModuleScope HU.Winget {
            Mock Test-HUWingetModule { $false }
            Mock Invoke-HUWinget { @('Gefunden 7-Zip [7zip.7zip]', 'Version: 24.09', 'Herausgeber: Igor Pavlov') }
            Get-HUWingetLatest '7zip.7zip' | Should -Be '24.09'
        }
    }
}

Describe 'App-Updates: Build-Angaben' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Winget.psm1') -Force -DisableNameChecking }
    It '+Build zaehlt nicht' {
        Compare-HUVersion '1.3.323+7f37e7a' '1.3.323' | Should -Be 0
        Compare-HUVersion '1.3.323+7f37e7a' '1.3.324' | Should -Be -1
    }
}

Describe 'Analyse: Tenant-Vergleich' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking
        if (-not (Get-Command Write-HULog -ErrorAction SilentlyContinue)) { function global:Write-HULog { param($Message, $Level, $Tenant) } }
    }
    It 'Fingerabdruck ignoriert IDs, Zeitstempel und Namen' {
        $a = '{"id":"1","displayName":"A","createdDateTime":"x","@odata.type":"#microsoft.graph.windows10GeneralConfiguration","passwordRequired":true,"list":[{"id":"9","v":1}]}' | ConvertFrom-Json
        $b = '{"id":"2","displayName":"B","createdDateTime":"y","@odata.type":"#microsoft.graph.windows10GeneralConfiguration","passwordRequired":true,"list":[{"id":"8","v":1}]}' | ConvertFrom-Json
        $c = '{"id":"3","displayName":"A","@odata.type":"#microsoft.graph.windows10GeneralConfiguration","passwordRequired":false,"list":[{"v":1}]}' | ConvertFrom-Json
        Get-HUCompareHash $a | Should -Be (Get-HUCompareHash $b)
        Get-HUCompareHash $a | Should -Not -Be (Get-HUCompareHash $c)
    }
    It 'Matrix: fehlt, abweichend, ueberall' {
        $rows = @(
            [pscustomobject]@{ Tenant = 't1'; Typ = 'Compliance'; Name = 'Win'; Id = 'a'; Hash = 'h1'; Copy = 'compliance' }
            [pscustomobject]@{ Tenant = 't2'; Typ = 'Compliance'; Name = 'win'; Id = 'b'; Hash = 'h2'; Copy = 'compliance' }
            [pscustomobject]@{ Tenant = 't1'; Typ = 'Wartung'; Name = 'Disk'; Id = 'c'; Hash = ''; Copy = 'generic' }
        )
        $m = @(Get-HUCompareMatrix $rows @('t1', 't2'))
        $w = $m | Where-Object Typ -eq 'Wartung'
        $w.Missing | Should -Be @('t2'); $w.Status | Should -Match 'nur in einem'
        $cp = $m | Where-Object Typ -eq 'Compliance'
        $cp.Missing.Count | Should -Be 0; $cp.Status | Should -Match 'abweichend'
    }
    It 'Kopieren (generisch): ohne IDs/Zuweisungen, mit Inhalt, POST in den Ziel-Tenant' {
        InModuleScope HU.Intune {
            $script:posted = $null
            Mock Invoke-HUIntuneGraph {
                if ($Method -eq 'POST') { $script:posted = @{ T = $TenantKey; E = $Endpoint; B = $Body }; return [pscustomobject]@{ id = 'neu' } }
                return ('{"id":"s1","displayName":"Disk","createdDateTime":"x","isGlobalScript":false,"detectionScriptContent":"ZQ==","assignments":[{"id":"z"}],"@odata.context":"ctx"}' | ConvertFrom-Json)
            }
            Copy-HUIntuneObject -Typ 'Wartung' -SourceTenant 'a' -SourceId 's1' -TargetTenant 'b' -Settings ([pscustomobject]@{}) | Should -Be 'neu'
            $script:posted.T | Should -Be 'b'
            $script:posted.E | Should -Be '/deviceManagement/deviceHealthScripts'
            $script:posted.B.ContainsKey('id') | Should -BeFalse
            $script:posted.B.ContainsKey('assignments') | Should -BeFalse
            $script:posted.B.ContainsKey('@odata.context') | Should -BeFalse
            $script:posted.B.detectionScriptContent | Should -Be 'ZQ=='
        }
    }
    It 'nur anzeigen: Conditional Access wird nicht kopiert' {
        { Copy-HUIntuneObject -Typ 'Conditional Access' -SourceTenant 'a' -SourceId 'x' -TargetTenant 'b' -Settings ([pscustomobject]@{}) } | Should -Throw
    }
}

Describe 'Analyse: Vergleich-Details' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'nur abweichende Einstellungen, Katalog nach settingDefinitionId (Reihenfolge egal)' {
        $a = '{"id":"1","name":"X","settings":[{"id":"0","settingInstance":{"settingDefinitionId":"s_a","choiceSettingValue":{"value":"on"}}},{"id":"1","settingInstance":{"settingDefinitionId":"s_b","simpleSettingValue":{"value":5}}}]}' | ConvertFrom-Json
        $b = '{"id":"2","name":"X","settings":[{"id":"0","settingInstance":{"settingDefinitionId":"s_b","simpleSettingValue":{"value":7}}},{"id":"1","settingInstance":{"settingDefinitionId":"s_a","choiceSettingValue":{"value":"on"}}}]}' | ConvertFrom-Json
        $d = @(Get-HUCompareDiff @{ t1 = (ConvertTo-HUFlatMap $a); t2 = (ConvertTo-HUFlatMap $b) } @('t1', 't2'))
        $d.Count | Should -Be 1
        $d[0].Einstellung | Should -Match 's_b'
        $d[0].T0 | Should -Be '5'; $d[0].T1 | Should -Be '7'
    }
    It 'lange Skriptinhalte als Kurzform, fehlende Werte als (nicht gesetzt)' {
        $m1 = ConvertTo-HUFlatMap ([pscustomobject]@{ detectionScriptContent = ('QUJD' * 50); extra = 'x' })
        $m2 = ConvertTo-HUFlatMap ([pscustomobject]@{ detectionScriptContent = ('QUJE' * 50) })
        $m1.detectionScriptContent | Should -Match '^\(Inhalt, 200 Zeichen'
        $d = @(Get-HUCompareDiff @{ a = $m1; b = $m2 } @('a', 'b'))
        ($d | Where-Object Einstellung -eq 'extra').T1 | Should -Be '(nicht gesetzt)'
        $d.Count | Should -Be 2
    }
}

Describe 'Analyse: IDs je Tenant aufloesen' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'gleiche Gruppe mit verschiedenen IDs ist kein Unterschied' {
        InModuleScope HU.Intune {
            Mock Get-HUIntuneGraphAll { @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Oesterreich' }) }
            Mock Invoke-HUIntuneGraph { if ($Endpoint -like '/groups/*') { [pscustomobject]@{ displayName = 'Lehrer' } } else { throw '404' } }
            $m1 = Resolve-HUFlatMapIds -TenantKey 'a' -Settings ([pscustomobject]@{}) -Map @{ 'conditions.users.includeGroups' = 'aaaaaaaa-0000-0000-0000-000000000001'; 'conditions.locations.excludeLocations' = '11111111-1111-1111-1111-111111111111' }
            $m2 = Resolve-HUFlatMapIds -TenantKey 'b' -Settings ([pscustomobject]@{}) -Map @{ 'conditions.users.includeGroups' = 'bbbbbbbb-0000-0000-0000-000000000002'; 'conditions.locations.excludeLocations' = '11111111-1111-1111-1111-111111111111' }
            $m1['conditions.users.includeGroups'] | Should -Be 'Lehrer (Gruppe)'
            $m1['conditions.locations.excludeLocations'] | Should -Be 'Oesterreich (Ort)'
            @(Get-HUCompareDiff @{ a = $m1; b = $m2 } @('a', 'b')).Count | Should -Be 0
        }
    }
}

Describe 'Analyse: Listen im Vergleich' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'zeigt gemeinsame Anzahl und je Tenant nur das Zusaetzliche' {
        $d = @(Get-HUCompareDiff @{ a = @{ r = 'A, B, C' }; b = @{ r = 'A, B, D, E' } } @('a', 'b'))
        $d[0].T0 | Should -Be '(gleich: 2) + C'
        $d[0].T1 | Should -Be '(gleich: 2) + D, E'
    }
}

Describe 'Backup und Verlauf' {
    BeforeAll {
        Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking
        if (-not (Get-Command Write-HULog -ErrorAction SilentlyContinue)) { function global:Write-HULog { param($Message, $Level, $Tenant) } }
        $script:bakRoot = Join-Path ([IO.Path]::GetTempPath()) ("hu-bak-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    }
    AfterAll { Remove-Item -LiteralPath $script:bakRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'sichert, vergleicht zwei Staende (geaendert, neu, geloescht, Zuweisung) und zeigt Details' {
        InModuleScope HU.Intune -Parameters @{ Root = $script:bakRoot } {
            param($Root)
            $script:val = 1; $script:grp = 'g1'; $script:extra = $false
            Mock Get-HUIntuneGraphAll {
                if ($Endpoint -like '*/assignments') { return @([pscustomobject]@{ intent = 'apply'; target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $script:grp } }) }
                if ($Endpoint -eq '/deviceManagement/deviceHealthScripts') {
                    $l = @([pscustomobject]@{ id = 'r1'; displayName = 'Disk' })
                    if ($script:extra) { $l += [pscustomobject]@{ id = 'r2'; displayName = 'Neu' } }
                    return $l
                }
                if ($Endpoint -eq '/deviceManagement/deviceCompliancePolicies' -and -not $script:extra) { return @([pscustomobject]@{ id = 'c1'; displayName = 'Alt' }) }
                return @()
            }
            Mock Invoke-HUIntuneGraph { [pscustomobject]@{ id = ($Endpoint -split '/')[-1] -replace '\?.*$', ''; displayName = 'x'; detectionScriptContent = 'QQ=='; runAsAccount = 'system'; value = $script:val } }
            $b1 = Save-HUTenantBackup -TenantKey 'T1' -Settings ([pscustomobject]@{}) -Root $Root
            Start-Sleep -Milliseconds 1100
            $script:val = 2; $script:grp = 'g2'; $script:extra = $true
            $b2 = Save-HUTenantBackup -TenantKey 'T1' -Settings ([pscustomobject]@{}) -Root $Root
            @(Get-HUBackupList -Root $Root -TenantKey 'T1').Count | Should -Be 2
            $rows = @(Compare-HUBackups -FolderA $b1.Folder -FolderB $b2.Folder)
            ($rows | Where-Object Id -eq 'r1').Aenderung | Should -Match 'Einstellungen geaendert'
            ($rows | Where-Object Id -eq 'r1').Aenderung | Should -Match 'Zuweisungen geaendert'
            ($rows | Where-Object Id -eq 'r2').Aenderung | Should -Be 'neu'
            ($rows | Where-Object Id -eq 'c1').Aenderung | Should -Be 'geloescht'
            $r1 = $rows | Where-Object Id -eq 'r1'
            $d = @(Get-HUBackupItemDiff $r1.FileA $r1.FileB)
            ($d | Where-Object Einstellung -eq 'value').T1 | Should -Be '2'
            @($d | Where-Object { $_.Einstellung -like 'assignments*' }).Count | Should -BeGreaterThan 0
            Remove-HUOldBackups -Root $Root -TenantKey 'T1' -Keep 1 | Should -Be 1
        }
    }
    It 'Wiederherstellen legt neu an (Name mit Zusatz, ohne Zuweisungen, CA deaktiviert)' {
        InModuleScope HU.Intune -Parameters @{ Root = $script:bakRoot } {
            param($Root)
            $f = Join-Path $Root 'ca.json'
            Write-HUJsonFile $f ([pscustomobject]@{ id = 'p1'; displayName = '201 - MFA'; state = 'enabled'; assignments = @(); conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeGroups = @('g1') } } })
            $script:posted = $null
            Mock Invoke-HUIntuneGraph { $script:posted = @{ E = $Endpoint; B = $Body }; [pscustomobject]@{ id = 'neu' } }
            Restore-HUBackupItem -TenantKey 'T1' -Settings ([pscustomobject]@{}) -Typ 'Conditional Access' -File $f -Name '201 - MFA (wiederhergestellt)' | Should -Be 'neu'
            $script:posted.B.state | Should -Be 'disabled'
            $script:posted.B.displayName | Should -Be '201 - MFA (wiederhergestellt)'
            $script:posted.B.ContainsKey('id') | Should -BeFalse
            $script:posted.B.ContainsKey('assignments') | Should -BeFalse
        }
    }
}

Describe 'Backup: Administrative Vorlagen' {
    BeforeAll { Import-Module (Join-Path $script:AppRoot 'Core\HU.Intune.psm1') -Force -DisableNameChecking }
    It 'liest Einstellungen getrennt (expand hoechstens 2 Ebenen)' {
        InModuleScope HU.Intune {
            Mock Invoke-HUIntuneGraph { if ($Endpoint -match 'expand') { throw 'zu tief' }; [pscustomobject]@{ id = 'a1'; displayName = 'Zeitsync' } }
            Mock Get-HUIntuneGraphAll { @([pscustomobject]@{ enabled = $true; definition = [pscustomobject]@{ id = 'd1'; displayName = 'NTP' } }) }
            $o = Get-HUCompareObject -TenantKey 't' -Settings ([pscustomobject]@{}) -Typ 'Administrative Vorlage' -Id 'a1'
            @($o.definitionValues).Count | Should -Be 1
            Should -Invoke Get-HUIntuneGraphAll -ParameterFilter { $Endpoint -like '*/definitionValues?$expand=definition,presentationValues($expand=presentation)' }
        }
    }
}
