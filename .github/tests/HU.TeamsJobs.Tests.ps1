#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.TeamsJobs.psm1 - ohne Netzwerk, ohne Oberflaeche, ohne Aufgabenplanung.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-TeamsJobs-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path (Join-Path $script:TestRoot 'Config') -ItemType Directory -Force | Out-Null
    Import-Module (Join-Path $root 'Core\HU.Notify.psm1') -Force -DisableNameChecking
    Grant-HUSendApproval -Reason 'Test'
    Import-Module (Join-Path $root 'Core\HU.TeamsJobs.psm1') -Force -DisableNameChecking
}

AfterAll {
    Remove-Module HU.TeamsJobs, HU.Notify -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Teams-Auftraege: Speicher' {
    It 'leer ohne Datei' { @(Get-HUTeamsJobs -AppRoot $script:TestRoot).Count | Should -Be 0 }
    It 'anlegen, lesen, Ergebnis nachtragen' {
        $j = New-HUTeamsJob -Name 'Ampel' -Time '07:00' -Tenants @('T1', 'T2') -Days @(1, 5)
        $j.Id | Should -Match '^[0-9a-f]{8}$'
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        $r = @(Get-HUTeamsJobs -AppRoot $script:TestRoot)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Ampel'
        @($r[0].Tenants).Count | Should -Be 2
        @($r[0].Days) | Should -Be @(1, 5)
        $r[0].Enabled | Should -BeTrue
        Update-HUTeamsJobResult -AppRoot $script:TestRoot -Id $j.Id -Result 'OK gesendet'
        (Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id).LastResult | Should -Be 'OK gesendet'
        (Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id).LastRun | Should -Not -BeNullOrEmpty
    }
    It 'weist ungueltige Uhrzeit und Art ab' {
        $j = New-HUTeamsJob -Name 'x'; $j.Time = '25:00'
        { Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j) } | Should -Throw
        $j2 = New-HUTeamsJob -Name 'y'; $j2.Kind = 'Fremd'
        { Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j2) } | Should -Throw
    }
    It 'Aufgabenname aus Id' {
        $j = New-HUTeamsJob -Name 'x'
        Get-HUTeamsJobTaskName $j | Should -Be "Teams-$($j.Id)"
    }
}

Describe 'Teams-Auftraege: Tages-Ampel (New-HUDailyCardSpec)' {
    It 'alles gruen' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 100; NonCompliant = 0; Stale = 1; StaleDays = 7; NoPolicy = 0; SecretDays = 200; SecretStatus = 'OK' }
        )
        $s = New-HUDailyCardSpec -Statuses $st
        $s.Level | Should -Be 'OK'
        $s.Rows[0].Status | Should -Be 'OK'
        $s.Rows[0].Text | Should -Be '100 Geraete'
        $s.Facts['Geraete gesamt'] | Should -Be 100
        $s.Facts['Tenants'] | Should -Be '1 von 1 erreichbar'
        $s.Title | Should -Match '^Tages-Ampel - '
    }
    It 'gelb bei nicht konform / ohne Sync / Secret bald' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'Gym'; Ok = $true; Error = ''; Devices = 300; NonCompliant = 3; Stale = 2; StaleDays = 7; NoPolicy = 0; SecretDays = 12; SecretStatus = 'OK' }
        )
        $s = New-HUDailyCardSpec -Statuses $st -SecretWarnDays 30
        $s.Level | Should -Be 'Warning'
        $s.Rows[0].Status | Should -Be 'Warning'
        $s.Rows[0].Text | Should -Match '3 nicht konform'
        $s.Rows[0].Text | Should -Not -Match 'ohne Sync'      # 2 < StaleWarn 5
        $s.Rows[0].Text | Should -Match 'App-Secret noch 12 Tage'
        @($s.Lines).Count | Should -Be 1
    }
    It 'rot bei Fehler, abgelaufenem Secret oder >= 10 % nicht konform' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'A'; Ok = $false; Error = 'Token: abgelaufen'; Devices = 0; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = $null; SecretStatus = '' }
            [pscustomobject]@{ Key = 'B'; Name = 'B'; Ok = $true; Error = ''; Devices = 50; NonCompliant = 5; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = $null; SecretStatus = 'NoPermission' }
            [pscustomobject]@{ Key = 'C'; Name = 'C'; Ok = $true; Error = ''; Devices = 10; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = -3; SecretStatus = 'OK' }
        )
        $s = New-HUDailyCardSpec -Statuses $st
        $s.Level | Should -Be 'Error'
        $s.Rows[0].Status | Should -Be 'Error'
        $s.Rows[0].Text | Should -Match 'nicht erreichbar'
        $s.Rows[1].Status | Should -Be 'Error'
        $s.Rows[1].Text | Should -Match 'Application.Read.All'
        $s.Rows[2].Status | Should -Be 'Error'
        $s.Rows[2].Text | Should -Match 'ABGELAUFEN'
        $s.Facts['Tenants'] | Should -Be '2 von 3 erreichbar'
        $s.Facts['Geraete gesamt'] | Should -Be 60
    }
    It 'ergibt eine gueltige Karte' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 1; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = 99; SecretStatus = 'OK' })
        $s = New-HUDailyCardSpec -Statuses $st
        $card = New-HUTeamsCard -Title $s.Title -Level $s.Level -Rows $s.Rows -Facts $s.Facts -Lines $s.Lines
        { ConvertTo-HUTeamsCardJson $card } | Should -Not -Throw
    }
}

Describe 'Teams-Auftraege: Ausfuehrung ohne Ziele' {
    It 'Invoke-HUTeamsJob ohne Tenants meldet Fehler, wirft nicht' {
        $j = New-HUTeamsJob -Name 'x'
        $settings = [pscustomobject]@{ tenants = @(); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'Keine Tenants'
    }
    It 'ueberspringt Tenant-Eintraege ohne key (Review 029 B18)' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 5; DisplayName = 'x'; Status = 'OK' } }
        $j = New-HUTeamsJob -Name 'SC' -Kind 'Secrets'
        $settings = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }, [pscustomobject]@{ displayName = 'ohne key' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot -NoSend
        $r.Success | Should -BeTrue
        @($r.Spec.Rows).Count | Should -Be 1
    }
    It 'tenants = null ergibt Keine Tenants, keinen Bindungsfehler (Review 029 B18)' {
        $j = New-HUTeamsJob -Name 'SC' -Kind 'Secrets'
        $settings = [pscustomobject]@{ tenants = $null; ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse
        $r.Message | Should -Be 'Keine Tenants'
    }
    It 'Vorschau (NoSend) nutzt die Kennzahlen' {
        Mock -ModuleName HU.TeamsJobs Get-HUDailyTenantStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Devices = 5; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = 50; SecretStatus = 'OK' } }
        $j = New-HUTeamsJob -Name 'Ampel'
        $settings = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }, [pscustomobject]@{ key = 'T2' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot -NoSend
        $r.Success | Should -BeTrue
        @($r.Spec.Rows).Count | Should -Be 2
        $r.Spec.Facts['Geraete gesamt'] | Should -Be 10
    }
}

Describe 'Teams-Auftraege: Arten mit Befund-Logik' {
    It 'Kinds-Liste und Kategorien' {
        $k = @(Get-HUTeamsKinds)
        $k.Key | Should -Be @('Daily', 'Secrets', 'Licenses', 'Defender', 'Script')
        ($k | Where-Object Key -eq 'Daily').OnlyFindings | Should -BeFalse
        ($k | Where-Object Key -eq 'Secrets').Category | Should -Be 'Secrets'
    }
    It 'Secret-Countdown: nichts zu melden -> $null' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Days = 200; DisplayName = 'x'; Status = 'OK' })
        New-HUSecretsCardSpec -Statuses $st -WarnDays 30 | Should -BeNullOrEmpty
    }
    It 'Secret-Countdown: Warnung und Abgelaufen' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Days = 12; DisplayName = 'neu'; Status = 'OK' }
            [pscustomobject]@{ Key = 'B'; Name = 'Gym'; Ok = $true; Error = ''; Days = -1; DisplayName = 'alt'; Status = 'OK' }
            [pscustomobject]@{ Key = 'C'; Name = 'BORG'; Ok = $false; Error = 'Kein Token (Secret fehlt oder abgelaufen)'; Days = $null; DisplayName = ''; Status = '' }
        )
        $s = New-HUSecretsCardSpec -Statuses $st -WarnDays 30
        $s.Level | Should -Be 'Error'
        @($s.Rows).Count | Should -Be 3
        $s.Rows[0].Text | Should -Match '12 Tagen'
        $s.Rows[1].Text | Should -Match 'ABGELAUFEN'
    }
    It 'Lizenzen: nur knappe SKUs, Ueberbuchung rot' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Skus = @(
                [pscustomobject]@{ Sku = 'A3-FACULTY'; Total = 100; Used = 98; Free = 2 }
                [pscustomobject]@{ Sku = 'A1-STUDENT'; Total = 500; Used = 100; Free = 400 }
            ) }
            [pscustomobject]@{ Key = 'B'; Name = 'Gym'; Ok = $true; Error = ''; Skus = @(
                [pscustomobject]@{ Sku = 'A3'; Total = 10; Used = 12; Free = -2 }
            ) }
            [pscustomobject]@{ Key = 'C'; Name = 'BORG'; Ok = $true; Error = ''; Skus = @(
                [pscustomobject]@{ Sku = 'FLOW_FREE'; Total = 0; Used = 0; Free = 0 }
            ) }
        )
        $s = New-HULicenseCardSpec -Statuses $st -MinFree 5
        @($s.Rows).Count | Should -Be 2
        $s.Rows[0].Status | Should -Be 'Warning'
        $s.Rows[0].Text | Should -Match 'A3-FACULTY: noch 2 von 100 frei'
        $s.Rows[0].Text | Should -Not -Match 'A1-STUDENT'
        $s.Rows[1].Status | Should -Be 'Error'
        $s.Level | Should -Be 'Error'
    }
    It 'Lizenzen: alles ausreichend -> $null' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Skus = @([pscustomobject]@{ Sku = 'A3'; Total = 100; Used = 50; Free = 50 }) })
        New-HULicenseCardSpec -Statuses $st | Should -BeNullOrEmpty
    }
    It 'Defender: Befunde mit Geraeteliste, Deckel bei 10' {
        $f = @(1..12 | ForEach-Object { [pscustomobject]@{ Device = "NB-$_"; State = 'Bedrohung (hoch)' } })
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 100; Findings = $f }
            [pscustomobject]@{ Key = 'B'; Name = 'Gym'; Ok = $true; Error = ''; Devices = 50; Findings = @() }
        )
        $s = New-HUDefenderCardSpec -Statuses $st
        @($s.Rows).Count | Should -Be 1
        $s.Rows[0].Text | Should -Match 'und 2 weitere'
        $s.Facts['Geraete mit Befund'] | Should -Be 12
        $s.Level | Should -Be 'Error'
    }
    It 'Defender: alles sauber -> $null' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 100; Findings = @() })
        New-HUDefenderCardSpec -Statuses $st | Should -BeNullOrEmpty
    }
    It 'Invoke: Befund-Art ohne Befund sendet nichts und ist OK' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 300; DisplayName = 'x'; Status = 'OK' } }
        $j = New-HUTeamsJob -Name 'SC' -Kind 'Secrets'
        $settings = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot
        $r.Success | Should -BeTrue
        $r.Message | Should -Match 'Nichts zu melden'
    }
    It 'Invoke: Befund ohne erreichbares Ziel ist KEIN Erfolg (Review 029 B2)' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 5; DisplayName = 'x'; Status = 'OK' } }
        $j = New-HUTeamsJob -Name 'SC' -Kind 'Secrets'
        $settings = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
        $r = Invoke-HUTeamsJob -Job $j -Settings $settings -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'NICHTS gesendet'
    }
}

Describe 'Teams-Auftraege: v2.1.10 (Vorschau, Exit-Codes, Kultur, Ids)' {
    It 'Datumsbeschriftung ist deutsch und kulturunabhaengig' {
        Get-HUTeamsDateLabel -Date ([datetime]'2026-10-16') | Should -Be 'Fr 16.10.'
        Get-HUTeamsDateLabel -Date ([datetime]'2026-10-18') | Should -Be 'So 18.10.'
    }
    It 'Tages-Ampel: Vorschau mit Ampel-Zaehlung und Summen' {
        $st = @(
            [pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 100; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = 200; SecretStatus = 'OK' }
            [pscustomobject]@{ Key = 'B'; Name = 'BORG'; Ok = $false; Error = 'Token'; Devices = 0; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = $null; SecretStatus = '' }
        )
        $s = New-HUDailyCardSpec -Statuses $st
        $s.Preview | Should -Match '1 gruen, 0 gelb, 1 rot'
        $s.Preview | Should -Match 'rot: BORG'
        $s.Preview | Should -Match '100 Geraete'
    }
    It 'Tages-Ampel: OK ohne Ablaufdatum -> Hinweis, keine Warnung (B8c)' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 10; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = $null; SecretStatus = 'OK' })
        $s = New-HUDailyCardSpec -Statuses $st
        $s.Rows[0].Text | Should -Match 'kein Ablaufdatum'
        $s.Level | Should -Be 'OK'
    }
    It 'Defender: Vorschau ohne Geraetenamen, Maskierung blendet Namen aus (B10/B16)' {
        $st = @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 5; Findings = @(
            [pscustomobject]@{ Device = 'PC-GEHEIM-1'; State = 'Bedrohung (hoch)' }
            [pscustomobject]@{ Device = 'PC-GEHEIM-2'; State = 'Bedrohung (hoch)' }
        ) })
        $s = New-HUDefenderCardSpec -Statuses $st
        $s.Preview | Should -Match '2 Geraet'
        $s.Preview | Should -Not -Match 'GEHEIM'
        $s.Rows[0].Text | Should -Match 'PC-GEHEIM-1'
        $m = New-HUDefenderCardSpec -Statuses $st -MaskDevices
        $m.Rows[0].Text | Should -Not -Match 'GEHEIM'
        $m.Rows[0].Text | Should -Match '2x Bedrohung'
        $m.Facts['Geraete mit Befund'] | Should -Be 2
    }
    It 'Secrets/Lizenzen: Vorschau nennt den dringendsten Fall' {
        $s = New-HUSecretsCardSpec -Statuses @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Days = 12; DisplayName = 'x'; Status = 'OK' }, [pscustomobject]@{ Key = 'B'; Name = 'Gym'; Ok = $true; Error = ''; Days = 5; DisplayName = 'y'; Status = 'OK' }) -WarnDays 30
        $s.Preview | Should -Match 'zuerst Gym in 5 Tagen'
        $l = New-HULicenseCardSpec -Statuses @([pscustomobject]@{ Key = 'A'; Name = 'EUGym'; Ok = $true; Error = ''; Skus = @([pscustomobject]@{ Sku = 'A3'; Total = 10; Used = 11; Free = -1 }) })
        $l.Preview | Should -Match 'EUGym A3 ueberbucht'
    }
    It 'Invoke-HUTeamsJob: Code 0/2/3 und Vorschau wird uebergeben' {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 3; DisplayName = 'x'; Status = 'OK' } }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }) }
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 1; Failed = 0; Text = 'A: gesendet' } }
        (Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $set -AppRoot $script:TestRoot).Code | Should -Be 0
        Should -Invoke -ModuleName HU.TeamsJobs Send-HUNotify -ParameterFilter { $Preview -match 'T1' }
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 1; Failed = 1; Text = 'A: gesendet; B: 404' } }
        (Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $set -AppRoot $script:TestRoot).Code | Should -Be 2
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 0; Failed = 0; Text = '' } }
        (Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $set -AppRoot $script:TestRoot).Code | Should -Be 3
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 0; Failed = 1; Text = 'A: 401' } }
        (Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $set -AppRoot $script:TestRoot).Code | Should -Be 1
        (Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S') -Settings ([pscustomobject]@{ tenants = @() }) -AppRoot $script:TestRoot).Code | Should -Be 3
    }
    It 'ungueltige Auftrags-Id wird fuer Aufgabe und Speicher abgewiesen (B15)' {
        $j = New-HUTeamsJob -Name 'x'; $j.Id = 'ab"; calc'
        { Get-HUTeamsJobTaskName -Job $j } | Should -Throw '*ungueltig*'
        Register-HUTeamsJobTask -Job $j -AppRoot $script:TestRoot | Should -Match 'ungueltig|nicht gefunden'
        { Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j) } | Should -Throw '*ungueltig*'
    }
    It 'Defender-Option maskDevices kommt im Auftrag an' {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Get-HUDefenderStatus { [pscustomobject]@{ Key = 'T1'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 1; Findings = @([pscustomobject]@{ Device = 'PC-X'; State = 'kompromittiert' }) } }
        $j = New-HUTeamsJob -Name 'D' -Kind Defender -Options @{ maskDevices = 1 }
        $r = Invoke-HUTeamsJob -Job $j -Settings ([pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }) }) -AppRoot $script:TestRoot -NoSend
        $r.Spec.Rows[0].Text | Should -Not -Match 'PC-X'
    }
}

Describe 'Meldung aus Skript (v2.1.10)' {
    BeforeAll {
        $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:App = Join-Path $script:TestRoot 'app'
        New-Item -Path (Join-Path $script:App 'Core') -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $script:App 'Config') -ItemType Directory -Force | Out-Null
        foreach ($f in 'HU.Notify.psm1', 'HU.Graph.psm1', 'HU.QSParams.ps1', 'HU.QSRuntime.ps1') { Copy-Item (Join-Path $repo "Core\$f") (Join-Path $script:App 'Core') }
        # Attrappe statt HU.Auth: Token ohne Netz, Tenant 'bad' hat kein Secret
        Set-Content -LiteralPath (Join-Path $script:App 'Core\HU.Auth.psm1') -Encoding UTF8 -Value @'
function Get-GraphToken { param($TenantKey, $Settings) if ($TenantKey -eq 'bad') { throw 'kein Secret' }; "tok-$TenantKey" }
Export-ModuleMember -Function Get-GraphToken
'@
        $code = "# @param Anzahl|int|Anzahl|3`nSend-HUNotify -Title `"`$TenantKey`" -Lines @(`"`$Anzahl Drucker offline`")"
        @{ snippets = @(@{ name = 'Drucker'; code = $code }, @{ name = 'Nur Ausgabe'; code = "[pscustomobject]@{ Tenant = `$TenantKey; Offen = 2 }" }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:App 'Config\quick-snippets.json') -Encoding UTF8
        # eigenes, leeres Profil: auf einem echten Admin-PC duerfen keine Karten an echte Kanaele gehen
        $script:OldAppData = $env:APPDATA
        $env:APPDATA = Join-Path $script:TestRoot 'appdata'
        $script:Set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'a' }, [pscustomobject]@{ key = 'bad' }) }
    }
    AfterAll { $env:APPDATA = $script:OldAppData }
    It 'fehlendes Snippet -> Code 3' {
        $j = New-HUTeamsJob -Name 'X' -Kind Script -Options @{ snippet = 'Weg' }; $j.Id = ''
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App
        $r.Code | Should -Be 3; $r.Message | Should -Match "Snippet 'Weg' nicht gefunden"
    }
    It 'ohne Skript -> Code 3' {
        $j = New-HUTeamsJob -Name 'X' -Kind Script; $j.Id = ''
        (Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App).Code | Should -Be 3
    }
    It 'laeuft je Tenant mit @param-Standardwerten, Send-HUNotify geht an die Meldung (hier: kein Ziel)' {
        $j = New-HUTeamsJob -Name 'Drucker-Status' -Kind Script -Options @{ snippet = 'Drucker'; snippetHash = (Get-HUTeamsCodeHash (Get-HUTeamsSnippetCode -AppRoot $script:App -Name 'Drucker')) }; $j.Id = ''
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App
        $r.Code | Should -Be 3
        $r.Message | Should -Match '1 Meldung'
        $r.Message | Should -Match '\[bad\] Kein Token'
    }
    It 'ohne Send-HUNotify: Ausgabe wird als eine Karte gesendet (hier: kein Ziel)' {
        $j = New-HUTeamsJob -Name 'Ausgabe' -Kind Script -Options @{ snippet = 'Nur Ausgabe'; snippetHash = (Get-HUTeamsCodeHash (Get-HUTeamsSnippetCode -AppRoot $script:App -Name 'Nur Ausgabe')) }; $j.Id = ''
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App
        $r.Message | Should -Match '1 Meldung'
        $r.Code | Should -Be 3
    }
    It 'B33: geaendertes oder unbestaetigtes Skript laeuft nicht (Code 3)' {
        $j = New-HUTeamsJob -Name 'X' -Kind Script -Options @{ snippet = 'Drucker'; snippetHash = 'abc' }; $j.Id = ''
        $r = Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App
        $r.Code | Should -Be 3; $r.Message | Should -Match 'geaendert'
        $j = New-HUTeamsJob -Name 'X' -Kind Script -Options @{ snippet = 'Drucker' }; $j.Id = ''
        (Invoke-HUTeamsJob -Job $j -Settings $script:Set -AppRoot $script:App).Code | Should -Be 3
    }
    It 'B33: Fingerabdruck unabhaengig von CRLF/LF' {
        Get-HUTeamsCodeHash "a`r`nb" | Should -Be (Get-HUTeamsCodeHash "a`nb")
        Get-HUTeamsCodeHash 'a' | Should -Not -Be (Get-HUTeamsCodeHash 'b')
    }
    It 'B35: je Tenant ein frischer Runspace - Variablen bleiben nicht haengen' {
        $code = "if (`$global:Merker) { throw 'Variable aus dem vorigen Tenant' }; `$global:Merker = 1; 'NEU'"
        $r = Invoke-HUTeamsScript -Code $code -Name 'R' -Tenants @('a', 'b') -Settings $script:Set -AppRoot $script:App
        # haette Tenant b die Variable von a gesehen, stuende ein Fehler in Errors
        $r.Calls | Should -Be 1
        @($r.Errors).Count | Should -Be 0
    }
    It 'ohne Ausgabe: Write-Host-Zeilen gehen als Karte; ohne Tenant-Bezug nur ein Lauf' {
        $r = Invoke-HUTeamsScript -Code "Write-Host 'Zeile A'" -Name 'W' -Tenants @('a', 'b') -Settings $script:Set -AppRoot $script:App
        $r.Calls | Should -Be 1
        @($r.Errors).Count | Should -Be 0
    }
    It '@param-Werte der Meldung gehen vor dem Standard' {
        $code = "# @param Anzahl|int|Anzahl|3`nif (`$Anzahl -ne 7) { throw `"Anzahl ist `$Anzahl`" }; 'ok'"
        $r = Invoke-HUTeamsScript -Code $code -Name 'P' -Tenants @('a') -Settings $script:Set -AppRoot $script:App -Params @{ Anzahl = '7' }
        @($r.Errors).Count | Should -Be 0
        $r = Invoke-HUTeamsScript -Code $code -Name 'P' -Tenants @('a') -Settings $script:Set -AppRoot $script:App
        @($r.Errors) -join ' ' | Should -Match 'Anzahl ist 3'
    }
    It 'Get-HUTeamsSnippetCode liefert den Code' {
        Get-HUTeamsSnippetCode -AppRoot $script:App -Name 'Drucker' | Should -Match 'Send-HUNotify'
    }
}

Describe 'Teams-Auftraege: Review 030' {
    BeforeAll {
        $script:DefSt = [pscustomobject]@{ Key = 'T1'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 3; Findings = @(
            [pscustomobject]@{ Device = 'PC-A'; State = 'fehlkonfiguriert' }
            [pscustomobject]@{ Device = 'PC-B'; State = 'kompromittiert' }
        ) }
    }
    It 'B7: maskDevices fail-closed - unklarer Text blendet aus, false/0 zeigt Namen' {
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
        Mock -ModuleName HU.TeamsJobs Get-HUDefenderStatus { $script:DefSt }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }) }
        foreach ($v in @('true', 'ja', '1 ', 'vielleicht', $true, 1)) {
            $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'D' -Kind Defender -Options @{ maskDevices = $v }) -Settings $set -AppRoot $script:TestRoot -NoSend
            $r.Spec.Rows[0].Text | Should -Not -Match 'PC-' -Because "maskDevices = '$v'"
        }
        foreach ($v in @('false', '0', 'nein', $false, 0)) {
            $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'D' -Kind Defender -Options @{ maskDevices = $v }) -Settings $set -AppRoot $script:TestRoot -NoSend
            $r.Spec.Rows[0].Text | Should -Match 'PC-A' -Because "maskDevices = '$v'"
        }
    }
    It 'B22: Maskierung nach Dringlichkeit, Ein-/Mehrzahl in der Vorschau' {
        $m = New-HUDefenderCardSpec -Statuses @($script:DefSt) -MaskDevices
        $m.Rows[0].Text | Should -Match '^1x kompromittiert, 1x fehlkonfiguriert'
        $m.Preview | Should -Match '^2 Geraete mit Befund'
        $one = [pscustomobject]@{ Key = 'T1'; Name = 'HLW'; Ok = $true; Error = ''; Devices = 1; Findings = @([pscustomobject]@{ Device = 'X'; State = 'kompromittiert' }) }
        (New-HUDefenderCardSpec -Statuses @($one)).Preview | Should -Match '^1 Geraet mit Befund'
        (New-HUSecretsCardSpec -Statuses @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Days = 5; DisplayName = 'x'; Status = 'OK' })).Preview | Should -Match '^1 Tenant betroffen'
    }
    It 'B29: Secret-Countdown meldet bei genau N Tagen, Text "N Tage oder weniger"' {
        $s = New-HUSecretsCardSpec -Statuses @([pscustomobject]@{ Key = 'A'; Name = 'HLW'; Ok = $true; Error = ''; Days = 30; DisplayName = 'x'; Status = 'OK' }) -WarnDays 30
        $s | Should -Not -BeNullOrEmpty
        $s.Facts['Warnschwelle'] | Should -Be '30 Tage oder weniger'
    }
}
