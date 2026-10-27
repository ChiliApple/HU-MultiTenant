#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests fuer Core\HU.AppBackup.psm1 (2.5.9): Verschluesselung, Kopf, Manipulation, Kennwort.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.AppBackup.psm1') -Force -DisableNameChecking
    $script:Pw = 'Korrekt-Pferd-42'
    $script:Plain = [Text.Encoding]::UTF8.GetBytes(('Inhalt der Sicherung ' * 50))
        $script:Enc = Protect-HUAppBackupBytes -Plain $script:Plain -Password $script:Pw -Iterations 600000 -Header @{ App = '2.5.9'; Items = @('config/settings.json') }
}

Describe 'App-Sicherung: Verschluesselung' {
    It 'Hin und zurueck ergibt denselben Inhalt' {
        $r = Unprotect-HUAppBackupBytes -Data $script:Enc -Password $script:Pw
        [Text.Encoding]::UTF8.GetString($r.Plain) | Should -Be ([Text.Encoding]::UTF8.GetString($script:Plain))
        $r.Header.App | Should -Be '2.5.9'
    }
    It 'Kennung und Kopf sind lesbar, Inhalt nicht' {
        [Text.Encoding]::ASCII.GetString($script:Enc, 0, 7) | Should -Be 'HUSICH1'
        $h = Read-HUAppBackupHeader $script:Enc
        $h.Header.Kdf | Should -Be 'PBKDF2-SHA256'
        $h.Iter | Should -Be 600000
        [Text.Encoding]::UTF8.GetString($script:Enc) | Should -Not -Match 'Inhalt der Sicherung'
    }
    It 'Zwei Sicherungen desselben Inhalts unterscheiden sich (Salt/IV)' {
        $b = Protect-HUAppBackupBytes -Plain $script:Plain -Password $script:Pw -Iterations 600000
        [Convert]::ToBase64String($b) | Should -Not -Be ([Convert]::ToBase64String($script:Enc))
    }
    It 'Falsches Kennwort: einheitliche Meldung' {
        { Unprotect-HUAppBackupBytes -Data $script:Enc -Password 'Falsches-Kennwort' } | Should -Throw '*Kennwort falsch oder Datei veraendert*'
    }
    It 'Veraendertes Chiffrat: dieselbe Meldung' {
        $d = [byte[]]$script:Enc.Clone(); $d[$d.Length - 40] = $d[$d.Length - 40] -bxor 1
        { Unprotect-HUAppBackupBytes -Data $d -Password $script:Pw } | Should -Throw '*Kennwort falsch oder Datei veraendert*'
    }
    It 'Veraenderter Kopf (Items) wird erkannt' {
        $txt = [Text.Encoding]::UTF8.GetString($script:Enc)
        $i = $txt.IndexOf('settings.json')
        $d = [byte[]]$script:Enc.Clone(); $d[$i] = [byte][char]'S'
        { Unprotect-HUAppBackupBytes -Data $d -Password $script:Pw } | Should -Throw '*Kennwort falsch oder Datei veraendert*'
    }
    It 'Abgeschnittene Datei wird abgelehnt' {
        $d = New-Object byte[] ($script:Enc.Length - 5); [Array]::Copy($script:Enc, $d, $d.Length)
        { Unprotect-HUAppBackupBytes -Data $d -Password $script:Pw } | Should -Throw
    }
    It 'Fremde Datei: keine HU-Sicherung' {
        { Read-HUAppBackupHeader ([Text.Encoding]::UTF8.GetBytes('PK' + ('x' * 100))) } | Should -Throw '*Keine HU-Sicherung*'
    }
    It 'Zu wenige Iterationen im Kopf werden abgelehnt' {
        $txt = [Text.Encoding]::UTF8.GetString($script:Enc)
        $i = $txt.IndexOf('"Iter":600000')
        $d = [byte[]]$script:Enc.Clone(); $d[$i + 7] = [byte][char]'1'
        # "Iter":100000 -> unter der Grenze 600000
        { Read-HUAppBackupHeader $d } | Should -Throw '*Schluesselparameter*'
    }
}

Describe 'App-Sicherung: Kennwort' {
    It 'zu kurz' { Test-HUAbPassword 'kurz' | Should -Match 'zu kurz' }
    It 'Wiederholung abweichend' { Test-HUAbPassword 'Lang-genug-123' 'Lang-genug-124' | Should -Match 'nicht ueberein' }
    It 'in Ordnung' { Test-HUAbPassword 'Lang-genug-123' 'Lang-genug-123' | Should -BeNullOrEmpty }
    It 'SecureString wird akzeptiert' {
        $s = New-Object Security.SecureString; foreach ($ch in $script:Pw.ToCharArray()) { $s.AppendChar($ch) }
        $r = Unprotect-HUAppBackupBytes -Data $script:Enc -Password $s
        $r.Plain.Length | Should -Be $script:Plain.Length
    }
    It 'Verschluesseln mit zu kurzem Kennwort wirft' {
        { Protect-HUAppBackupBytes -Plain $script:Plain -Password 'kurz' -Iterations 600000 } | Should -Throw '*zu kurz*'
    }
}

Describe 'App-Sicherung: grosse Daten blockweise' {
    It 'Mehrere Bloecke und krumme Laenge' {
        $p = New-Object byte[] (200000 + 7); (New-Object Random 5).NextBytes($p)
        $e = Protect-HUAppBackupBytes -Plain $p -Password 'Lang-genug-123' -Iterations 600000
        $r = Unprotect-HUAppBackupBytes -Data $e -Password 'Lang-genug-123'
        [Convert]::ToBase64String($r.Plain) | Should -Be ([Convert]::ToBase64String($p))
    }
    It 'Genau ein Puffer (65536), ein Block, ein Byte' {
        foreach ($len in 65536, 16, 1) {
            $p = New-Object byte[] $len; (New-Object Random 9).NextBytes($p)
            $e = Protect-HUAppBackupBytes -Plain $p -Password 'Lang-genug-123' -Iterations 600000
            (Unprotect-HUAppBackupBytes -Data $e -Password 'Lang-genug-123').Plain.Length | Should -Be $len
        }
    }
}

Describe 'App-Sicherung: Inhalt, Sichern, Wiederherstellen' {
    BeforeAll {
        $script:Mk = {
            $b = Join-Path ([IO.Path]::GetTempPath()) ("HU-AB-" + [guid]::NewGuid().ToString('N'))
            $app = Join-Path $b 'app'; $dat = Join-Path $b 'data'; $bk = Join-Path $b 'backups'
            foreach ($d in (Join-Path $app 'Config\app-icons'), (Join-Path $dat 'AddonData/Kinderschutz/arch'), (Join-Path $dat 'katalog'), (Join-Path $bk '_Muster/frueher/alt'), (Join-Path $bk '_Muster/pakete/eigen-1'), (Join-Path $bk 'T1/2026')) {
                New-Item -ItemType Directory -Path ($d.Replace('\', [IO.Path]::DirectorySeparatorChar)) -Force | Out-Null }
            $cfg = (Join-Path $app 'Config').Replace('\', [IO.Path]::DirectorySeparatorChar)
            Set-Content -LiteralPath (Join-Path $cfg 'settings.json') -Value '{"tenants":[{"key":"T1"}],"ui":{}}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $cfg 'quick-snippets.json') -Value '{"snippets":[]}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $cfg 'teams-jobs.json') -Value '{"jobs":[{"Id":"a1","Name":"Ampel","Enabled":true,"Targets":["z1"]},{"Id":"a2","Name":"Ohne Ziel","Enabled":true,"Targets":["z9"]},{"Id":"a3","Name":"Aus","Enabled":false,"Targets":["z9"]}]}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $cfg 'version.json') -Value '{}' -Encoding UTF8
            [IO.File]::WriteAllBytes((Join-Path (Join-Path $cfg 'app-icons') 'abc.png'), [byte[]](1, 2, 3))
            foreach ($f in 'ui-state.json', 'remote.json', 'remote-marks.json', 'remote-devices.json', 'remote-pin.json', 'notify-targets.json', 'HU-SCHULE1.cred', 'muster-rechte-T1.json') { Set-Content -LiteralPath (Join-Path $dat $f) -Value "{`"f`":`"$f`"}" -Encoding UTF8 }
            Set-Content -LiteralPath (Join-Path $dat 'katalog/x.json') -Value '{}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $dat 'AddonData/Kinderschutz/arch/log.json') -Value '{"x":1}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bk '_Muster/frueher/alt/index.json') -Value '{}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bk '_Muster/pakete/eigen-1/paket.json') -Value '{"Title":"Eigen"}' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bk 'T1/2026/x.json') -Value '{"b":1}' -Encoding UTF8
            [pscustomobject]@{ B = $b; App = $app; Dat = $dat; Bk = $bk; Out = (Join-Path $b 'out') }
        }
        $script:E = & $script:Mk
        $script:Pw = 'Korrekt-Pferd-42'
    }
    It 'Positivliste: nur erlaubte Dateien, nie Secrets/Freigaben/Kopplungen/Cache' {
        $src = @(Get-HUAppBackupSources -AppRoot $E.App -DataRoot $E.Dat -BackupRoot $E.Bk)
        $n = @($src.Name)
        $n | Should -Contain 'config/settings.json'; $n | Should -Contain 'config/app-icons/abc.png'; $n | Should -Contain 'appdata/AddonData/Kinderschutz/arch/log.json'
        $n | Should -Contain 'appdata/ui-state.json'; $n | Should -Contain 'appdata/remote.json'
        foreach ($x in 'remote-marks', 'remote-devices', 'remote-pin', 'notify-targets', '.cred', 'muster-rechte', 'katalog', 'version.json', 'muster/', 'backups/') { @($n | Where-Object { $_ -like "*$x*" }).Count | Should -Be 0 -Because $x }
    }
    It 'Optional: Muster nur pakete/aktuell (nicht frueher), Tenant-Backups ohne _Muster' {
        $n = @((Get-HUAppBackupSources -AppRoot $E.App -DataRoot $E.Dat -BackupRoot $E.Bk -IncludeMuster -IncludeTenantBackups).Name)
        $n | Should -Contain 'muster/pakete/eigen-1/paket.json'; $n | Should -Not -Contain 'muster/frueher/alt/index.json'
        # aeltere Sicherungen mit frueher\ bleiben wiederherstellbar
        Resolve-HUAppBackupTarget 'muster/frueher/alt/index.json' $E.App $E.Dat $E.Bk | Should -Not -BeNullOrEmpty
        $n | Should -Contain 'backups/T1/2026/x.json'; @($n | Where-Object { $_ -like 'backups/_Muster*' }).Count | Should -Be 0
    }
    It 'Ziele: nur erlaubte Namen' {
        Resolve-HUAppBackupTarget 'config/settings.json' $E.App $E.Dat $E.Bk | Should -Not -BeNullOrEmpty
        foreach ($bad in 'config/../x.json', 'config/version.json', 'appdata/remote-marks.json', 'appdata/AddonData/../x', 'appdata/AddonData/1bad/x', 'backups/_Muster/x', 'C:/x', 'appdata/AddonData/K/a\b', 'config/app-icons/x.ps1') {
            Resolve-HUAppBackupTarget $bad $E.App $E.Dat $E.Bk | Should -BeNullOrEmpty -Because $bad }
    }
    It 'Sichern, oeffnen, wiederherstellen (mit Vorstand und pausierten Teams-Auftraegen)' {
        $src = @(Get-HUAppBackupSources -AppRoot $E.App -DataRoot $E.Dat -BackupRoot $E.Bk -IncludeMuster)
        $r = New-HUAppBackup -Sources $src -Password $Pw -Folder $E.Out -AppVersion '2.5.9' -Pc 'NB 001' -Modules @([pscustomobject]@{ Id = 'MCP'; Version = '0.3.2' })
        Split-Path -Leaf $r.Path | Should -Match '^HU-Sicherung_NB-001_\d{4}-\d{2}-\d{2}_\d{6}\.husicherung$'
        Test-Path -LiteralPath "$($r.Path).tmp" | Should -BeFalse
        $o = Open-HUAppBackup -Path $r.Path -Password $Pw -AppVersion '2.5.9' -AppRoot $E.App -DataRoot $E.Dat -BackupRoot $E.Bk
        $o.Errors.Count | Should -Be 0
        @($o.Rows).Count | Should -Be $src.Count
        # aendern, dann wiederherstellen
        $sp = Join-Path (Join-Path $E.App 'Config') 'settings.json'
        Set-Content -LiteralPath $sp -Value '{"tenants":[],"neu":true}' -Encoding UTF8
        $areas = @($o.Rows.Area | Select-Object -Unique)
        $w = Restore-HUAppBackup -Opened $o -Areas $areas -AppRoot $E.App -DataRoot $E.Dat -BackupRoot $E.Bk -KnownTargetIds @('z1') -SettingsValidator { param($f) $null -ne (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) }
        $w.Written | Should -Be $src.Count
        (Get-Content -LiteralPath $sp -Raw) | Should -Match '"T1"'
        Get-Content -LiteralPath (Join-Path $w.Before 'config/settings.json'.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Raw | Should -Match '"neu"'
        $w.Paused | Should -Be @('Ohne Ziel')
        $tj = Get-Content -LiteralPath (Join-Path (Join-Path $E.App 'Config') 'teams-jobs.json') -Raw | ConvertFrom-Json
        ($tj.jobs | Where-Object Id -eq 'a1').Enabled | Should -BeTrue
        ($tj.jobs | Where-Object Id -eq 'a2').Enabled | Should -BeFalse
        $w.Modules[0].Id | Should -Be 'MCP'
    }
    It 'settings.json, die sich nicht laden laesst: nichts geschrieben' {
        $src = @(Get-HUAppBackupSources -AppRoot $E.App -DataRoot $E.Dat)
        $r = New-HUAppBackup -Sources $src -Password $Pw -Folder $E.Out -AppVersion '2.5.9' -Now (Get-Date).AddSeconds(5)
        $o = Open-HUAppBackup -Path $r.Path -Password $Pw -AppVersion '2.5.9' -AppRoot $E.App -DataRoot $E.Dat
        $sp = Join-Path (Join-Path $E.App 'Config') 'settings.json'; $before = Get-Content -LiteralPath $sp -Raw
        { Restore-HUAppBackup -Opened $o -Areas @('Einstellungen (Tenants, Oberflaeche)', 'Quick-Script-Snippets') -AppRoot $E.App -DataRoot $E.Dat -SettingsValidator { param($f) $false } } | Should -Throw '*nichts geschrieben*'
        Get-Content -LiteralPath $sp -Raw | Should -Be $before
    }
    It 'Sicherung aus neuerer App wird abgelehnt' {
        $src = @(Get-HUAppBackupSources -AppRoot $E.App -DataRoot $E.Dat)
        $r = New-HUAppBackup -Sources $src -Password $Pw -Folder $E.Out -AppVersion '2.7.0' -Now (Get-Date).AddSeconds(10)
        $o = Open-HUAppBackup -Path $r.Path -Password $Pw -AppVersion '2.5.9' -AppRoot $E.App -DataRoot $E.Dat
        ($o.Errors -join ' ') | Should -Match 'zuerst aktualisieren'
    }
    It 'Falsches Kennwort: Fehler, nichts gelesen' {
        $f = @(Get-HUAppBackupList $E.Out)[0].FullName
        $o = Open-HUAppBackup -Path $f -Password 'Falsches-Kennwort' -AppVersion '2.5.9' -AppRoot $E.App -DataRoot $E.Dat
        ($o.Errors -join ' ') | Should -Match 'Kennwort falsch'
        $o.Entries.Count | Should -Be 0
    }
    It 'Aufbewahren: nur eigene Dateien, die neuesten bleiben' {
        $d = Join-Path $E.B 'keep'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $t0 = Get-Date '2026-01-01'
        for ($i = 0; $i -lt 4; $i++) { $f = Join-Path $d (Get-HUAppBackupFileName 'PC' $t0.AddDays($i)); Set-Content -LiteralPath $f -Value 'x'; (Get-Item $f).LastWriteTime = $t0.AddDays($i) }
        Set-Content -LiteralPath (Join-Path $d 'fremd.husicherung') -Value 'x'
        $rm = @(Remove-HUAppBackupOld -Folder $d -Keep 2 -Pc 'PC')
        $rm.Count | Should -Be 2
        @(Get-HUAppBackupList $d).Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $d 'fremd.husicherung') | Should -BeTrue
    }
    It 'Faellig nach Kalendertagen: taeglich/woechentlich/aus' {
        $now = Get-Date '2026-10-27T12:00:00'
        Test-HUAppBackupDue 'aus' '' $now | Should -BeFalse
        Test-HUAppBackupDue 'taeglich' '' $now | Should -BeTrue
        Test-HUAppBackupDue 'taeglich' '2026-10-27T00:05:00' $now | Should -BeFalse
        Test-HUAppBackupDue 'taeglich' '2026-10-26T23:50:00' $now | Should -BeTrue
        # durchlaufende App: kurz nach Mitternacht faellig, nicht vorher
        Test-HUAppBackupDue 'taeglich' '2026-10-27T00:10:00' (Get-Date '2026-10-27T23:59:00') | Should -BeFalse
        Test-HUAppBackupDue 'taeglich' '2026-10-27T00:10:00' (Get-Date '2026-10-28T00:05:00') | Should -BeTrue
        Test-HUAppBackupDue 'woechentlich' '2026-10-21T23:00:00' $now | Should -BeFalse
        Test-HUAppBackupDue 'woechentlich' '2026-10-20T08:00:00' $now | Should -BeTrue
    }
}

Describe 'App-Sicherung: Teams-Ziele (Udo 27.10.)' {
    BeforeAll { $script:E2 = & $script:Mk; $script:Pw2 = 'Korrekt-Pferd-42' }
    It 'Ziele gehen nur verschluesselt mit, Wiederherstellen ueber den Handler, Auftraege bleiben an' {
        $src = @(Get-HUAppBackupSources -AppRoot $E2.App -DataRoot $E2.Dat)
        $tz = [Text.Encoding]::UTF8.GetBytes('{"v":1,"items":[{"Id":"z9","Name":"IT","Url":"https://example.webhook.office.com/x"}]}')
        $r = New-HUAppBackup -Sources $src -Password $Pw2 -Folder $E2.Out -AppVersion '2.5.9' -Extra @{ 'special/teams-ziele.json' = $tz }
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($r.Path)) | Should -Not -Match 'example\.webhook\.office'
        $o = Open-HUAppBackup -Path $r.Path -Password $Pw2 -AppVersion '2.5.9' -AppRoot $E2.App -DataRoot $E2.Dat
        $o.Errors.Count | Should -Be 0
        ($o.Rows | Where-Object Name -eq 'special/teams-ziele.json').Area | Should -Be 'Teams-Ziele (Webhook-Adressen)'
        $script:Got = $null
        $w = Restore-HUAppBackup -Opened $o -Areas @('Teams-Ziele (Webhook-Adressen)', 'Teams-Auftraege') -AppRoot $E2.App -DataRoot $E2.Dat -KnownTargetIds @('z1') -SpecialHandler { param($n, $b) $script:Got = [Text.Encoding]::UTF8.GetString($b) }
        $script:Got | Should -Match '"z9"'
        @($w.Paused).Count | Should -Be 0
        # Vorstand enthaelt die alte (DPAPI-)Datei
        Test-Path -LiteralPath (Join-Path (Join-Path $w.Before 'appdata') 'notify-targets.json') | Should -BeTrue
    }
    It 'Fremde Sondernamen werden nicht gesichert' {
        $src = @(Get-HUAppBackupSources -AppRoot $E2.App -DataRoot $E2.Dat)
        { New-HUAppBackup -Sources $src -Password $Pw2 -Folder $E2.Out -AppVersion '2.5.9' -Extra @{ 'special/boese.json' = [byte[]](1) } -Now (Get-Date).AddSeconds(3) } | Should -Throw '*nicht erlaubt*'
    }
    It 'Sonderinhalt ohne Handler: nichts geschrieben' {
        $f = @(Get-HUAppBackupList $E2.Out)[0].FullName
        $o = Open-HUAppBackup -Path $f -Password $Pw2 -AppVersion '2.5.9' -AppRoot $E2.App -DataRoot $E2.Dat
        { Restore-HUAppBackup -Opened $o -Areas @('Teams-Ziele (Webhook-Adressen)') -AppRoot $E2.App -DataRoot $E2.Dat } | Should -Throw '*nichts geschrieben*'
    }
}

Describe 'App-Sicherung: Pruefbefunde 071' {
    It 'Aufraeumen nur mit eigenem PC-Namen (gemeinsamer Ordner)' {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("HU-AB-keep-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d -Force | Out-Null
        $t0 = Get-Date '2026-01-01'
        foreach ($pc in 'PC-A', 'PC-B') { for ($i = 0; $i -lt 3; $i++) { $f = Join-Path $d (Get-HUAppBackupFileName $pc $t0.AddDays($i)); Set-Content -LiteralPath $f -Value 'x'; (Get-Item $f).LastWriteTime = $t0.AddDays($i + $(if ($pc -eq 'PC-B') { 10 } else { 0 })) } }
        $rm = @(Remove-HUAppBackupOld -Folder $d -Keep 1 -Pc 'PC-A')
        $rm.Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $d -Filter 'HU-Sicherung_PC-B_*').Count | Should -Be 3
        @(Get-ChildItem -LiteralPath $d -Filter 'HU-Sicherung_PC-A_*').Count | Should -Be 1
    }
}

Describe 'App-Sicherung: Teams-Auftraege pausieren (072 G10)' {
    It 'Enabled "0"/"false" gilt als aus, "10" oder "falsey" nicht' {
        $j = '{"jobs":[{"Id":"a","Name":"Null","Enabled":"0","Targets":["x"]},{"Id":"b","Name":"Zehn","Enabled":"10","Targets":["x"]},{"Id":"c","Name":"Falsey","Enabled":"falsey","Targets":["x"]}]}'
        $r = Update-HUAbTeamsJobs ([Text.Encoding]::UTF8.GetBytes($j)) @()
        $r.Paused | Should -Not -Contain 'Null'
        $r.Paused | Should -Contain 'Zehn'
        $r.Paused | Should -Contain 'Falsey'
    }
}

Describe 'App-Sicherung: Skripte beim Wiederherstellen nicht vorgewaehlt (072 G2)' {
    It 'Snippets, Wartung, Teams-Auftraege und Teams-Ziele gelten als Code-Bereiche' {
        foreach ($n in 'config/quick-snippets.json', 'config/remediations.json', 'config/teams-jobs.json', 'special/teams-ziele.json') { Test-HUAppBackupCodeName $n | Should -BeTrue }
    }
    It 'Einstellungen, Apps, Muster und Backups sind keine Code-Bereiche' {
        foreach ($n in 'config/settings.json', 'config/apps.json', 'muster/bibliothek.json', 'appdata/ui-state.json') { Test-HUAppBackupCodeName $n | Should -BeFalse }
    }
    It 'jeder Code-Bereich hat einen Bereichsnamen' {
        foreach ($n in 'config/quick-snippets.json', 'config/remediations.json', 'config/teams-jobs.json', 'special/teams-ziele.json') { Get-HUAppBackupArea $n | Should -Not -BeNullOrEmpty }
    }
}

Describe 'App-Sicherung: Schutzpruefungen beim Oeffnen (072 G4)' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        $script:G4 = Join-Path ([IO.Path]::GetTempPath()) ("HU-G4-" + [guid]::NewGuid().ToString('N'))
        foreach ($d in 'app', 'data', 'bk') { New-Item -ItemType Directory -Path (Join-Path $script:G4 $d) -Force | Out-Null }
        $script:G4Pw = 'Korrekt-Pferd-42'
        # Sicherung von Hand bauen: Eintraege (Name -> byte[]) + Manifest (Name -> Sha256; $null = automatisch)
        $script:Build = {
            param([System.Collections.Specialized.OrderedDictionary]$Files, [hashtable]$ShaOverride = @{}, [string[]]$Skip = @(), [string]$App = '2.6.1', [switch]$NoManifest)
            $sha = { param([byte[]]$b) $h = [Security.Cryptography.SHA256]::Create(); try { -join ($h.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) } finally { $h.Dispose() } }
            $man = @(foreach ($k in $Files.Keys) { if ($Skip -contains $k) { continue }; [pscustomobject]@{ Name = $k; Sha256 = $(if ($ShaOverride.ContainsKey($k)) { $ShaOverride[$k] } else { & $sha $Files[$k] }); Changed = '2026-10-27T10:00:00' } })
            $ms = New-Object IO.MemoryStream
            $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($k in $Files.Keys) { $e = $zip.CreateEntry($k); $s = $e.Open(); try { $s.Write($Files[$k], 0, $Files[$k].Length) } finally { $s.Dispose() } }
                if (-not $NoManifest) {
                    $mb = [Text.Encoding]::UTF8.GetBytes((@{ Format = 1; Files = $man } | ConvertTo-Json -Depth 5))
                    $e = $zip.CreateEntry('meta/manifest.json'); $s = $e.Open(); try { $s.Write($mb, 0, $mb.Length) } finally { $s.Dispose() }
                }
            } finally { $zip.Dispose() }
            [void]$ms.Seek(0, 'Begin')
            $p = Join-Path $script:G4 ("t-" + [guid]::NewGuid().ToString('N') + '.husicherung')
            $fs = [IO.File]::Create($p)
            try { Protect-HUAppBackupStream -InStream $ms -OutStream $fs -Password $script:G4Pw -Iterations 600000 -Header @{ App = $App; Files = $Files.Count } } finally { $fs.Dispose(); $ms.Dispose() }
            $p
        }
        $script:OpenG4 = { param($p) Open-HUAppBackup -Path $p -Password $script:G4Pw -AppVersion '2.6.1' -AppRoot (Join-Path $script:G4 'app') -DataRoot (Join-Path $script:G4 'data') -BackupRoot (Join-Path $script:G4 'bk') }
        $script:B = { param([string]$t) [Text.Encoding]::UTF8.GetBytes($t) }
    }
    AfterAll { Remove-Item -LiteralPath $script:G4 -Recurse -Force -ErrorAction SilentlyContinue }
    It 'saubere Sicherung oeffnet ohne Fehler' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{"tenants":[]}') }
        $r = & $OpenG4 (& $Build $f)
        @($r.Errors).Count | Should -Be 0
        @($r.Rows).Count | Should -Be 1
    }
    It 'unerlaubter Name (Pfad nach draussen, fremde Datei) wird abgelehnt' {
        foreach ($bad in '../evil.ps1', 'config/../../x.json', 'appdata/HU-SCHULE1.cred', 'C:/Windows/x.txt') {
            $f = [ordered]@{ $bad = (& $B 'x') }
            $r = & $OpenG4 (& $Build $f)
            @($r.Errors | Where-Object { $_ -match 'kein erlaubter Inhalt' }).Count | Should -BeGreaterThan 0 -Because $bad
        }
    }
    It 'doppelter Name (Gross/Klein) wird abgelehnt' {
        $f = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        $f.Add('config/settings.json', (& $B '{}')); $f.Add('CONFIG/Settings.json', (& $B '{}'))
        $r = & $OpenG4 (& $Build $f)
        @($r.Errors | Where-Object { $_ -match 'doppelt' }).Count | Should -Be 1
    }
    It 'falsche Pruefsumme im Manifest wird erkannt' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{}') }
        $r = & $OpenG4 (& $Build $f -ShaOverride @{ 'config/settings.json' = ('0' * 64) })
        @($r.Errors | Where-Object { $_ -match 'Pruefsumme passt nicht' }).Count | Should -Be 1
    }
    It 'Datei nicht im Manifest bzw. Manifest fehlt' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{}'); 'config/apps.json' = (& $B '{}') }
        $r = & $OpenG4 (& $Build $f -Skip @('config/apps.json'))
        @($r.Errors | Where-Object { $_ -match 'nicht im Manifest' }).Count | Should -Be 1
        $r = & $OpenG4 (& $Build $f -NoManifest)
        @($r.Errors | Where-Object { $_ -match 'Manifest fehlt' }).Count | Should -Be 1
    }
    It 'Sicherung aus neuerer App wird abgelehnt' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{}') }
        $r = & $OpenG4 (& $Build $f -App '9.0.0')
        @($r.Errors | Where-Object { $_ -match 'zuerst aktualisieren' }).Count | Should -Be 1
    }
    It 'zu grosser Eintrag wird abgelehnt (Grenze im Test verkleinert)' {
        $f = [ordered]@{ 'config/settings.json' = (New-Object byte[] 4096) }
        $p = & $Build $f
        $mod = Get-Module HU.AppBackup
        $old = & $mod { $script:HUAbLimits.EntryBytes }
        try {
            & $mod { $script:HUAbLimits.EntryBytes = 1024 }
            $r = & $OpenG4 $p
            @($r.Errors | Where-Object { $_ -match 'zu gross' }).Count | Should -Be 1
        } finally { & $mod { param($v) $script:HUAbLimits.EntryBytes = $v } $old }
    }
    It 'falsches Kennwort: Meldung sagt, was zu pruefen ist' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{}') }
        $p = & $Build $f
        $r = Open-HUAppBackup -Path $p -Password 'Falsches-Kennwort-1' -AppVersion '2.6.1' -AppRoot (Join-Path $script:G4 'app') -DataRoot (Join-Path $script:G4 'data')
        (@($r.Errors) -join ' ') | Should -Match 'Tastaturbelegung'
        $r.Entries.Count | Should -Be 0
    }
    It 'G13: Quelle wird bei Bedarf lokal kopiert, Kopie verschwindet beim Schliessen' {
        $f = [ordered]@{ 'config/settings.json' = (& $B '{}') }
        $p = & $Build $f
        $mod = Get-Module HU.AppBackup
        $s = & $mod { param($x) Open-HUAbSourceStream $x -ForceCopy } $p
        try {
            $s.Name | Should -Match 'HU-Quelle-'
            $s.Length | Should -Be (Get-Item -LiteralPath $p).Length
            $tmp = $s.Name
        } finally { $s.Dispose() }
        Test-Path -LiteralPath $tmp | Should -BeFalse
    }
    It 'G12: PBKDF2 liefert dasselbe wie der Referenzwert (RFC 6070-artig, SHA-256)' {
        $mod = Get-Module HU.AppBackup
        $k = & $mod { Get-HUAbPbkdf2 ([Text.Encoding]::UTF8.GetBytes('password')) ([Text.Encoding]::UTF8.GetBytes('salt')) 1 }
        (-join ($k | ForEach-Object { $_.ToString('x2') })) | Should -Be '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b'
    }
}
