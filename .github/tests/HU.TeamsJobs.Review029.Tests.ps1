#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) aus dem Review 029 (Lueckentests von Grok) fuer Core\HU.TeamsJobs.psm1 und Main.ps1 -Headless.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1). Ohne Netzwerk (Mocks).
    Tests mit [029] im Namen waren beim Stand 1362001/ec1b03a rot und sind seit v2.1.10 behoben.
#>

$script:IsWin = ($PSVersionTable.PSVersion.Major -le 5) -or [bool]$IsWindows

BeforeAll {
    $script:Repo = if ($env:HU_REPO) { $env:HU_REPO } else { Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-TeamsJobsQ-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path (Join-Path $script:TestRoot 'Config') -ItemType Directory -Force | Out-Null
    if (-not $env:APPDATA) { $env:APPDATA = $script:TestRoot }
    Import-Module (Join-Path $script:Repo 'Core\HU.Notify.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:Repo 'Core\HU.TeamsJobs.psm1') -Force -DisableNameChecking
    $script:JobsFile = Join-Path $script:TestRoot 'Config\teams-jobs.json'
    $script:Set1 = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; displayName = 'HLW' }); ui = [pscustomobject]@{ secretWarnDays = 30 } }
}

AfterAll {
    Remove-Module HU.TeamsJobs, HU.Notify -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Q: 0 Tenants / kaputte settings' {
    It '[029] settings ohne tenants-Eigenschaft -> "Keine Tenants" (nicht Parameterbindungsfehler)' {
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'x') -Settings ([pscustomobject]@{ ui = $null }) -AppRoot $script:TestRoot -NoSend
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'Keine Tenants'
    }
    It '[029] tenants = $null -> "Keine Tenants"' {
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'x') -Settings ([pscustomobject]@{ tenants = $null }) -AppRoot $script:TestRoot -NoSend
        $r.Message | Should -Match 'Keine Tenants'
    }
    It '[029] Tenant ohne key wird nicht als leerer Schluessel abgefragt' {
        Mock -ModuleName HU.TeamsJobs Get-HUDailyTenantStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Devices = 1; NonCompliant = 0; Stale = 0; StaleDays = 7; NoPolicy = 0; SecretDays = 99; SecretStatus = 'OK' } }
        $s = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }, [pscustomobject]@{ displayName = 'ohne key' }) }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'x') -Settings $s -AppRoot $script:TestRoot -NoSend
        $r.Message | Should -Not -Match 'Cannot bind|Argument'
    }
    It 'ui.secretWarnDays fehlt/Text -> Standard 30, kein Fehler' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 20; DisplayName = 'x'; Status = 'OK' } }
        $s = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1' }); ui = [pscustomobject]@{ secretWarnDays = 'abc' } }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'x' -Kind Secrets) -Settings $s -AppRoot $script:TestRoot -NoSend
        $r.Spec.Rows.Count | Should -Be 1
    }
    It 'Daily mit 0 Statuszeilen liefert gueltige Spec' {
        $s = New-HUDailyCardSpec -Statuses @()
        $s.Level | Should -Be 'OK'
        $s.Facts['Tenants'] | Should -Be '0 von 0 erreichbar'
    }
}

Describe 'Q: teams-jobs.json kaputt / Grenzfaelle' {
    BeforeEach { Remove-Item -LiteralPath $script:JobsFile, "$($script:JobsFile).bak" -Force -ErrorAction SilentlyContinue }
    It 'kaputte Datei: Get-HUTeamsJobs wirft verstaendlich' {
        Set-Content -LiteralPath $script:JobsFile -Value '{ "jobs": [ {' -Encoding UTF8
        { Get-HUTeamsJobs -AppRoot $script:TestRoot } | Should -Throw '*teams-jobs.json nicht lesbar*'
    }
    It 'kaputte Datei: Update-HUTeamsJobResult wirft nicht und ueberschreibt die Datei nicht' {
        Set-Content -LiteralPath $script:JobsFile -Value '{ kaputt' -Encoding UTF8
        { Update-HUTeamsJobResult -AppRoot $script:TestRoot -Id 'abcdef12' -Result 'OK' } | Should -Not -Throw
        (Get-Content -LiteralPath $script:JobsFile -Raw) | Should -Match 'kaputt'
    }
    It '[029] kaputte Datei mit gueltiger .bak: Auftraege werden aus .bak gelesen' {
        $j = New-HUTeamsJob -Name 'Ampel'
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)   # erzeugt .bak
        Set-Content -LiteralPath $script:JobsFile -Value '{ kaputt' -Encoding UTF8
        @(Get-HUTeamsJobs -AppRoot $script:TestRoot).Count | Should -Be 1
    }
    It 'leere Datei / jobs fehlt -> leeres Array' {
        Set-Content -LiteralPath $script:JobsFile -Value '{ "v": 1 }' -Encoding UTF8
        @(Get-HUTeamsJobs -AppRoot $script:TestRoot).Count | Should -Be 0
    }
    It 'genau EIN Auftrag mit EINEM Tag/Tenant bleibt nach Speichern/Lesen ein Array (PS 5.1)' {
        $j = New-HUTeamsJob -Name 'Ein' -Tenants @('T1') -Days @(3) -Targets @('aaaaaaaa')
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        (Get-Content -LiteralPath $script:JobsFile -Raw) | Should -Match '"jobs":\s*\['
        $r = Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id
        , $r.Days | Should -BeOfType [object[]]
        @($r.Days)[0] | Should -Be 3
        @($r.Tenants)[0] | Should -Be 'T1'
    }
    It 'Umlaute im Namen ueberleben Speichern/Lesen (UTF-8 ohne BOM + Lesen mit -Encoding UTF8)' {
        $n = "Tages-Ampel M$([char]0xFC)nchen $([char]0xC4)$([char]0xDF)"
        $j = New-HUTeamsJob -Name $n
        Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        (Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id).Name | Should -Be $n
    }
    It '[029] Enabled als Text "false" (von Hand bearbeitet) gilt als aus' {
        Set-Content -LiteralPath $script:JobsFile -Value '{ "v":1, "jobs":[ { "Id":"abcdef12", "Name":"x", "Kind":"Daily", "Enabled":"false" } ] }' -Encoding UTF8
        [bool](Get-HUTeamsJob -AppRoot $script:TestRoot -Id 'abcdef12').Enabled | Should -BeFalse
    }
    It 'Options mit Text-Zahl ("14") werden als Zahl genutzt' {
        Mock -ModuleName HU.TeamsJobs Get-HUDailyTenantStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Devices = 1; NonCompliant = 0; Stale = 0; StaleDays = $StaleDays; NoPolicy = 0; SecretDays = 99; SecretStatus = 'OK' } }
        $j = New-HUTeamsJob -Name 'x' -Options @{ staleDays = '14' }
        Invoke-HUTeamsJob -Job $j -Settings $script:Set1 -AppRoot $script:TestRoot -NoSend | Out-Null
        Should -Invoke -ModuleName HU.TeamsJobs Get-HUDailyTenantStatus -ParameterFilter { $StaleDays -eq 14 }
    }
}

Describe 'Q: Invoke-HUTeamsJob wertet die Send-HUNotify-Rueckgabe aus' {
    BeforeEach {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { [pscustomobject]@{ Key = $TenantKey; Name = $TenantKey; Ok = $true; Error = ''; Days = 5; DisplayName = 'x'; Status = 'OK' } }
        Mock -ModuleName HU.TeamsJobs Update-HUTeamsJobResult { }
    }
    It 'alle gesendet -> Success' {
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 2; Failed = 0; Text = 'Teams-Benachrichtigung: A: gesendet; B: gesendet' } }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $script:Set1 -AppRoot $script:TestRoot
        $r.Success | Should -BeTrue
        Should -Invoke -ModuleName HU.TeamsJobs Send-HUNotify -ParameterFilter { $Category -eq 'Secrets' -and $IgnoreCategory }
    }
    It 'Teilerfolg -> KEIN Success, Meldung "Teilweise"' {
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 1; Failed = 1; Text = 'A: gesendet; B: Senden abgelehnt (404)' } }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $script:Set1 -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse
        $r.Message | Should -Match 'Teilweise'
        Should -Invoke -ModuleName HU.TeamsJobs Update-HUTeamsJobResult -ParameterFilter { $Result -like 'FEHLER*' }
    }
    It 'Ziele am Auftrag gespeichert, aber keines mehr da -> "Ziel nicht gefunden"' {
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 0; Failed = 0; Text = '' } }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets -Targets @('deadbeef')) -Settings $script:Set1 -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse; $r.Message | Should -Match 'Ziel nicht gefunden'
    }
    It 'einmalige TargetIds haben Vorrang vor gespeicherten' {
        Mock -ModuleName HU.TeamsJobs Send-HUNotify { [pscustomobject]@{ Ok = 1; Failed = 0; Text = 'x' } }
        Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets -Targets @('aaaaaaaa')) -Settings $script:Set1 -AppRoot $script:TestRoot -TargetIds @('bbbbbbbb') | Out-Null
        Should -Invoke -ModuleName HU.TeamsJobs Send-HUNotify -ParameterFilter { @($TargetIds) -join ',' -eq 'bbbbbbbb' }
    }
    It 'Ausnahme in der Datenerhebung -> wirft nicht, Meldung ohne Adresse' {
        Mock -ModuleName HU.TeamsJobs Get-HUSecretStatus { throw 'Boom https://prod-1.logic.azure.com/x?sig=geheim' }
        $r = Invoke-HUTeamsJob -Job (New-HUTeamsJob -Name 'S' -Kind Secrets) -Settings $script:Set1 -AppRoot $script:TestRoot
        $r.Success | Should -BeFalse; $r.Message | Should -Not -Match 'geheim'
    }
    It '[029] Titel-Wochentag ist unabhaengig von der Kultur des Aufgabenkontos deutsch' -Tag 'Culture' {
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'en-US'
            $s = New-HUDailyCardSpec -Statuses @()
            $s.Title | Should -Match ' - (Mo|Di|Mi|Do|Fr|Sa|So) \d\d\.\d\d\.$'
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'Q: Sperre teams-jobs.json' {
    It '[029] Sperre belegt: Update-HUTeamsJobResult schreibt nicht ungesperrt' {
        Remove-Item -LiteralPath $script:JobsFile -Force -ErrorAction SilentlyContinue
        $j = New-HUTeamsJob -Name 'L'; Set-HUTeamsJobs -AppRoot $script:TestRoot -Jobs @($j)
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ $m = New-Object System.Threading.Mutex($false, 'Local\HU-MultiTenant_TeamsJobs'); [void]$m.WaitOne(); Start-Sleep -Seconds 8; $m.ReleaseMutex(); $m.Dispose() })
        $h = $ps.BeginInvoke(); Start-Sleep -Milliseconds 500
        Update-HUTeamsJobResult -AppRoot $script:TestRoot -Id $j.Id -Result 'ungesperrt'
        $lr = (Get-HUTeamsJob -AppRoot $script:TestRoot -Id $j.Id).LastResult
        $ps.EndInvoke($h); $ps.Dispose()
        $lr | Should -Not -Be 'ungesperrt'
    }
}

Describe 'Q: Main.ps1 -Headless Exit-Codes (nur Windows, ohne Netz)' -Skip:(-not $script:IsWin) {
    BeforeAll {
        $script:Ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        function Invoke-Headless([string[]]$ExtraArgs) {
            $p = Start-Process -FilePath $script:Ps51 -ArgumentList (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $script:Repo 'Main.ps1')`"", '-Headless') + $ExtraArgs) -PassThru -Wait -WindowStyle Hidden
            return $p.ExitCode
        }
    }
    # B24: Konfigurationsfehler (Auftrag fehlt/ungueltig, settings.json fehlt) = Exit 3
    It 'ohne -Job -> Exit 3' { Invoke-Headless @() | Should -Be 3 }
    It 'ungueltige Id -> Exit 3' { Invoke-Headless @('-Job', 'XYZ') | Should -Be 3 }
    It 'unbekannte Id -> Exit 3' { Invoke-Headless @('-Job', 'deadbeef') | Should -Be 3 }
}
