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
        $k.Key | Should -Be @('Daily', 'Secrets', 'Licenses', 'Defender')
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
}
