#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests: Handy-Fernbedienung (Core\HU.Remote.ps1, Core\HU.RemoteRun.ps1, Core\HU.RemoteWeb.ps1) ohne Webserver.
.NOTES
    Zielmaschine: CI (Windows PowerShell 5.1) bzw. Admin-PC. Eigenes, leeres APPDATA - es entstehen keine echten Dateien.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-Remote-Test-" + [guid]::NewGuid().ToString('N'))
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = Join-Path $script:TestRoot 'appdata'
    New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null
    Set-StrictMode -Version 1.0   # wie Main.ps1
    . (Join-Path $root 'Core\HU.Remote.ps1')
    . (Join-Path $root 'Core\HU.RemoteRun.ps1')
    . (Join-Path $root 'Core\HU.RemoteWeb.ps1')
    # Programmordner-Attrappe fuer Laeufe: HU.Auth ohne Netz
    $script:App = Join-Path $script:TestRoot 'app'
    New-Item -Path (Join-Path $script:App 'Core') -ItemType Directory -Force | Out-Null
    foreach ($f in 'HU.Notify.psm1', 'HU.Graph.psm1', 'HU.QSParams.ps1', 'HU.QSRuntime.ps1') { Copy-Item (Join-Path $root "Core\$f") (Join-Path $script:App 'Core') }
    Set-Content -LiteralPath (Join-Path $script:App 'Core\HU.Auth.psm1') -Encoding UTF8 -Value @'
function Get-GraphToken { param($TenantKey, $Settings) "tok-$TenantKey" }
Export-ModuleMember -Function Get-GraphToken
'@
    function script:New-TestState {
        $S = New-HURemoteState
        $S.Static = @{}
        $S.Tenants = @([pscustomobject]@{ key = 'a'; name = 'A' }, [pscustomobject]@{ key = 'b'; name = 'B' })
        $S.Targets = @([pscustomobject]@{ id = 't1'; name = 'Admin' })
        $code = "# @param DryRun|bool|Probelauf|true`n# @param Modus|choice|Modus|X|X;Y`nWrite-Host ""T=`$TenantKey D=`$DryRun M=`$Modus"" -ForegroundColor Green"
        $S.Items['00000000000000a1'] = @{ Id = '00000000000000a1'; Kind = 'snippet'; Name = 'W'; Mode = 'write'; Code = $code; Hash = 'h1'
            Params = @([pscustomobject]@{ Name = 'DryRun'; Type = 'bool'; Label = 'Probelauf'; Default = 'true'; Choices = @() }, [pscustomobject]@{ Name = 'Modus'; Type = 'choice'; Label = 'Modus'; Default = 'X'; Choices = @('X', 'Y') }) }
        $S.Items['00000000000000b2'] = @{ Id = '00000000000000b2'; Kind = 'snippet'; Name = 'R'; Mode = 'read'; Code = "'lesen'"; Hash = 'h2'; Params = @() }
        $S.Pair = @{ Code = '123456'; Until = (Get-Date).AddMinutes(5); Fails = 0; Locked = $false }
        return $S
    }
    function script:Req($S, [string]$Method, [string]$Path, $Body = $null, [string]$Tok = '') {
        $b = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 5 -Compress } else { '' }
        $r = Get-HURemoteResponse $S @{ Method = $Method; Path = $Path; Body = $b; Ip = '10.0.0.9'; Host = 'pc:8444'; Origin = ''; Auth = $(if ($Tok) { "Bearer $Tok" } else { '' }); Query = @{} }
        $j = $null; try { $j = $r.Text | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ Code = $r.Code; J = $j }
    }
    function script:Pair($S) { return (Req $S POST '/api/pair' @{ code = '123456'; name = 'Test' }).J.token }
}
AfterAll { $env:APPDATA = $script:OldAppData; Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Fernbedienung: Kopplung und Zugang' {
    It 'koppelt nur mit richtigem Code; der Code gilt einmal' {
        $S = New-TestState
        (Req $S POST '/api/pair' @{ code = '000000' }).Code | Should -Be 403
        $t = Pair $S
        $t | Should -Match '^[A-Za-z0-9_-]{43}$'
        $S.Pair | Should -BeNullOrEmpty
        (Req $S POST '/api/pair' @{ code = '123456' }).Code | Should -Be 409
    }
    It 'ohne Token 401, nach 10 Fehlversuchen 429' {
        $S = New-TestState
        (Req $S GET '/api/state').Code | Should -Be 401
        1..10 | ForEach-Object { [void](Req $S GET '/api/state') }
        (Req $S GET '/api/state').Code | Should -Be 429
    }
    It 'POST von fremder Herkunft wird abgelehnt' {
        $S = New-TestState; $t = Pair $S
        $r = Get-HURemoteResponse $S @{ Method = 'POST'; Path = '/api/cancel'; Body = '{"confirm":true}'; Ip = '10.0.0.9'; Host = 'pc:8444'; Origin = 'https://evil'; Auth = "Bearer $t"; Query = @{} }
        $r.Code | Should -Be 403
    }
    It 'lange nicht benutztes Handy verliert die Kopplung (90 Tage)' {
        $S = New-TestState; $null = Pair $S
        $k = @($S.Devices.Keys)[0]; $S.Devices[$k].LastSeen = (Get-Date).AddDays(-100).ToString('yyyy-MM-dd HH:mm')
        $f = Join-Path $script:TestRoot 'dev.json'
        Save-HURemoteDevices $S.Devices $f
        (Read-HURemoteDevices $f).Count | Should -Be 0
    }
}

Describe 'Fernbedienung: Pruefen und Starten' {
    BeforeAll { Set-HURemotePin '4711' }
    It 'PIN: nur Ziffern, 4-12 Stellen; Hash statt PIN in der Datei' {
        { Set-HURemotePin '12a4' } | Should -Throw
        { Set-HURemotePin '123' } | Should -Throw
        Set-HURemotePin '4711'
        $raw = Get-Content (Get-HURemotePinFile) -Raw
        $raw | Should -Not -Match '4711'
        Test-HURemotePin '4711' (Read-HURemotePin) | Should -BeTrue
        Test-HURemotePin '4712' (Read-HURemotePin) | Should -BeFalse
    }
    It 'Zusammenfassung: Parameter immer als Liste (auch ohne bzw. mit einem Parameter)' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $r = Get-HURemoteResponse $S @{ Method = 'POST'; Path = '/api/prepare'; Body = (@{ id = '00000000000000b2'; tenants = @('a') } | ConvertTo-Json -Compress); Ip = '10.0.0.9'; Host = 'pc:8444'; Origin = ''; Auth = "Bearer $t"; Query = @{} }
        $r.Text | Should -Match '"params":\['
        $S.Nonces.Clear()
        $r = Get-HURemoteResponse $S @{ Method = 'POST'; Path = '/api/prepare'; Body = (@{ id = '00000000000000a1'; tenants = @('a'); params = @{ DryRun = $true } } | ConvertTo-Json -Compress); Ip = '10.0.0.9'; Host = 'pc:8444'; Origin = ''; Auth = "Bearer $t"; Query = @{} }
        $r.Text | Should -Match '"params":\['
    }
    It 'Probelauf (Schalter an) braucht weder Kuerzel noch PIN' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ DryRun = $true } } $t
        $p.Code | Should -Be 200
        $p.J.summary.live | Should -BeFalse
        $p.J.code | Should -BeNullOrEmpty
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce } $t).Code | Should -Be 202
        $S.RunReq.Live | Should -BeFalse
    }
    It 'echter Lauf: falsches Kuerzel oder falsche PIN verbraucht die Bestaetigung; 3 falsche PINs sperren' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a', 'b'); params = @{ DryRun = $false } } $t
        $p.J.summary.live | Should -BeTrue
        $p.J.code | Should -Match '^[A-Z2-9]{4}$'
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce; code = 'XXXX'; pin = '4711' } $t).Code | Should -Be 403
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce; code = $p.J.code; pin = '4711' } $t).Code | Should -Be 403   # verbraucht
        foreach ($i in 1..3) {
            $q = Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ DryRun = $false } } $t
            if ($q.Code -eq 200) { [void](Req $S POST '/api/run' @{ nonce = $q.J.nonce; code = $q.J.code; pin = '0000' } $t) }
        }
        (@($S.Devices.Values)[0]).Locked | Should -BeTrue
        (Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a') } $t).Code | Should -Be 403
    }
    It 'echter Lauf mit Kuerzel und PIN wird angenommen' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ DryRun = $false; Modus = 'Y' } } $t
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce; code = $p.J.code; pin = '4711' } $t).Code | Should -Be 202
        $S.RunReq.Live | Should -BeTrue
        $S.RunReq.Values['Modus'] | Should -Be 'Y'
    }
    It 'ohne PIN kein echter Lauf; nur lesend braucht keine PIN' {
        $S = New-TestState; $S.Pin = $null; $t = Pair $S
        (Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ DryRun = $false } } $t).Code | Should -Be 409
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @('a') } $t
        $p.Code | Should -Be 200; $p.J.summary.live | Should -BeFalse
    }
    It 'Parameter: unbekannt, falsche Auswahl, mehrzeilig und geschuetzte Namen werden abgewiesen' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        (Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ Token = 'x' } } $t).Code | Should -Be 400
        (Req $S POST '/api/prepare' @{ id = '00000000000000a1'; tenants = @('a'); params = @{ Modus = 'Z' } } $t).Code | Should -Be 400
        (Test-HURemoteParams @([pscustomobject]@{ Name = 'Gruppe'; Type = 'string'; Label = 'G'; Default = '' }) @{ Gruppe = "a`nb" }).Ok | Should -BeFalse
        (Test-HURemoteParams @([pscustomobject]@{ Name = 'WhatIfPreference'; Type = 'string'; Label = 'W'; Default = '' }) @{}).Ok | Should -BeFalse
        (Test-HURemoteParams @([pscustomobject]@{ Name = 'Tage'; Type = 'int'; Label = 'T'; Default = '5' }) @{ Tage = 'x' }).Ok | Should -BeFalse
    }
    It 'Tenants: mindestens einer, nur bekannte' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        (Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @() } $t).Code | Should -Be 400
        (Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @('zz') } $t).Code | Should -Be 400
    }
    It 'geaenderter Eintrag zwischen Pruefen und Start: nicht starten' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @('a') } $t
        $S.Items['00000000000000b2'].Hash = 'neu'
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce } $t).Code | Should -Be 409
    }
    It 'am PC laeuft etwas: kein Start vom Handy' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $S.Busy = 'Quick Script'
        (Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @('a') } $t).Code | Should -Be 409
    }
    It 'Bestaetigung gilt 120 Sekunden' {
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000b2'; tenants = @('a') } $t
        $p.J.seconds | Should -Be 120
        $S.Nonces[$p.J.nonce].Exp = (Get-Date).AddSeconds(-1)
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce } $t).Code | Should -Be 403
    }
}

Describe 'Fernbedienung: Lauf ohne Oberflaeche' {
    It 'Snippet laeuft je Tenant in eigenem Runspace mit den Werten vom Handy; Ausgabe im Ringpuffer' {
        $S = New-TestState
        $rq = @{ Item = $S.Items['00000000000000a1']; Tenants = @('a', 'b'); Values = @{ DryRun = $true; Modus = 'Y' }; Live = $false; By = 'Test' }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'a'; displayName = 'A' }, [pscustomobject]@{ key = 'b'; displayName = 'B' }) }
        Invoke-HURemoteRun $S $rq $set $script:App
        $txt = @($S.Lines | ForEach-Object { $_.z }) -join "`n"
        $txt | Should -Match 'T=a D=True M=Y'
        $txt | Should -Match 'T=b D=True M=Y'
        $S.Job.Level | Should -Be 'OK'
        @($S.Job.Done).Count | Should -Be 2
    }
    It 'Fehler in einem Tenant: teilweise; Token im Text wird ausgeblendet' {
        $S = New-TestState
        $it = @{ Kind = 'snippet'; Name = 'F'; Mode = 'read'; Code = "if (`$TenantKey -eq 'b') { throw ""kaputt `$Token eyJabcdefghijk.abcdefghijkl.abcdefghijkl"" }; 'ok'"; Params = @() }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'a' }, [pscustomobject]@{ key = 'b' }) }
        Invoke-HURemoteRun $S @{ Item = $it; Tenants = @('a', 'b'); Values = @{}; By = 'T' } $set $script:App
        $S.Job.Result | Should -Match 'teilweise'
        (@($S.Lines | ForEach-Object { $_.z }) -join ' ') | Should -Not -Match 'eyJabcdefghijk'
    }
    It 'Abbruch stoppt den laufenden Tenant und startet keinen weiteren' {
        $S = New-TestState
        $it = @{ Kind = 'snippet'; Name = 'L'; Mode = 'read'; Code = "Start-Sleep -Seconds 20"; Params = @() }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'a' }, [pscustomobject]@{ key = 'b' }) }
        # Abbruch kommt nach 2 s (wie vom Handy, aus einem anderen Thread)
        $bg = [powershell]::Create(); [void]$bg.AddScript({ param($x) Start-Sleep -Seconds 2; $x.CancelReq = @{ By = 'Test' } }).AddArgument($S); $h = $bg.BeginInvoke()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-HURemoteRun $S @{ Item = $it; Tenants = @('a', 'b'); Values = @{}; By = 'T' } $set $script:App
        [void]$bg.EndInvoke($h); $bg.Dispose()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
        $S.Job.Result | Should -Match 'abgebrochen'
    }
}

Describe 'Fernbedienung: Apps und Wartung (Intune)' {
    BeforeAll {
        Set-HURemotePin '4711'
        $script:G1 = '11111111-2222-3333-4444-555555555555'
        function script:New-IState { $S = New-TestState; $S.Pin = Read-HURemotePin; $S.Items['00000000000000c3'] = @{ Id = '00000000000000c3'; Kind = 'intune'; Area = 'app'; Name = 'Intune-Apps'; Mode = 'write'; Params = @(); Hash = 'intune'; Stale = $false; TargetText = '' }; $S.Items['00000000000000d4'] = @{ Id = '00000000000000d4'; Kind = 'intune'; Area = 'rem'; Name = 'Intune-Wartung'; Mode = 'write'; Params = @(); Hash = 'intune'; Stale = $false; TargetText = '' }; return $S }
    }
    It 'Zuweisen ist immer ein echter Lauf (Kuerzel + PIN), genau ein Tenant, Werte gehen geprueft in den Start' {
        $S = New-IState; $t = Pair $S
        $q = @{ op = 'assign'; id = $G1; name = 'Firefox'; kind = 'group'; groupId = $G1; groupName = 'Schueler'; intent = 'required' }
        (Req $S POST '/api/prepare' @{ id = '00000000000000c3'; tenants = @('a', 'b'); intune = $q } $t).Code | Should -Be 400
        $p = Req $S POST '/api/prepare' @{ id = '00000000000000c3'; tenants = @('a'); intune = $q } $t
        $p.Code | Should -Be 200
        $p.J.summary.live | Should -BeTrue
        $p.J.code | Should -Match '^[A-Z2-9]{4}$'
        (Req $S POST '/api/run' @{ nonce = $p.J.nonce; code = $p.J.code; pin = '4711' } $t).Code | Should -Be 202
        $S.RunReq.Intune.Intent | Should -Be 'required'
        $S.RunReq.Intune.GroupId | Should -Be $G1
        $S.RunReq.Intune.Area | Should -Be 'app'
    }
    It 'ungueltige Angaben werden abgelehnt' {
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = 'x'; kind = 'group' } 'app').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'group'; groupId = 'abc'; intent = 'required' } 'app').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'allDevices'; intent = 'available' } 'app').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'allDevices'; intent = 'delete' } 'app').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'allDevices'; schedule = @{ type = 'hourly'; interval = 30 } } 'rem').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'allDevices'; schedule = @{ type = 'once'; time = '08:00'; date = '2000-01-01' } } 'rem').Ok | Should -BeFalse
        (Test-HURemoteIntuneReq @{ op = 'unassign'; id = $G1; keys = @('foo') } 'app').Ok | Should -BeFalse
        $r = Test-HURemoteIntuneReq @{ op = 'assign'; id = $G1; kind = 'allDevices'; schedule = @{ type = 'daily'; interval = 1; time = '07:30' } } 'rem'
        $r.Ok | Should -BeTrue
        $r.Req.Schedule.Time | Should -Be '07:30'
        $u = Test-HURemoteIntuneReq @{ op = 'unassign'; id = $G1; keys = @('group|schueler') } 'rem'
        $u.Ok | Should -BeTrue
        @($u.Req.Remove) | Should -Be @('group|schueler')
    }
    It 'viele Pruefungen hintereinander: nie "zu viele offene Anfragen", nur die neueste Bestaetigung gilt' {
        $S = New-IState; $t = Pair $S
        $q = @{ op = 'unassign'; id = $G1; name = 'X'; keys = @('allDevices|') }
        $last = $null; $first = $null
        foreach ($i in 1..6) { $p = Req $S POST '/api/prepare' @{ id = '00000000000000c3'; tenants = @('a'); intune = $q } $t; $p.Code | Should -Be 200; if (-not $first) { $first = $p }; $last = $p }
        @($S.Nonces.Keys).Count | Should -Be 1
        (Req $S POST '/api/run' @{ nonce = $first.J.nonce; code = $first.J.code; pin = '4711' } $t).Code | Should -Be 403
        (Req $S POST '/api/run' @{ nonce = $last.J.nonce; code = $last.J.code; pin = '4711' } $t).Code | Should -Be 202
    }
    It 'Daten fuers Handy: Liste bleibt eine Liste (auch bei einem Eintrag), Zuweisungen lesbar' {
        function global:Get-HUTenantAppList { param($TenantKey, $Settings) [pscustomobject]@{ Id = $G1; Name = 'Firefox'; Typ = 'Win32'; Version = '1'; Assignments = @(1, 2) } }
        function global:Get-HUAppAssignmentRows { param($TenantKey, $Settings, $AppId) [pscustomobject]@{ Key = 'group|schueler'; Ziel = 'Schueler'; Kind = 'group'; Intent = 'required' } }
        function global:Get-HUAppInstallSummary { param($TenantKey, $Settings, $AppId) 'installiert 3 | fehlgeschlagen 1' }
        function global:Invoke-HUIntuneGraph { param($TenantKey, $Settings, $Endpoint) [pscustomobject]@{ displayName = 'Firefox'; description = ''; '@odata.type' = '#microsoft.graph.win32LobApp' } }
        function global:Get-HUAppKindFromType { param($T) 'win32' }
        try {
            $l = [object[]]@(Get-HURemoteIntuneData @{ Op = 'list'; Area = 'app'; Tenant = 'a'; Id = '' } $null)
            (ConvertTo-Json -InputObject $l -Compress) | Should -Match '^\[\{'
            $l[0].n | Should -Be 2
            $d = Get-HURemoteIntuneData @{ Op = 'detail'; Area = 'app'; Tenant = 'a'; Id = $G1 } $null
            $d.summary | Should -Match 'installiert 3'
            @($d.asg)[0].info | Should -Be 'Erforderlich'
            @($d.asg)[0].key | Should -Be 'group|schueler'
        } finally { foreach ($f in 'Get-HUTenantAppList', 'Get-HUAppAssignmentRows', 'Get-HUAppInstallSummary', 'Invoke-HUIntuneGraph', 'Get-HUAppKindFromType') { Remove-Item "function:global:$f" -ErrorAction SilentlyContinue } }
    }
    It 'Lesen: erst "pending", Anfrage in der Warteschlange; danach Ergebnis aus dem Zwischenspeicher' {
        $S = New-IState; $t = Pair $S
        $r = Req $S POST '/api/intune' @{ op = 'list'; area = 'app'; tenant = 'a' } $t
        $r.Code | Should -Be 200
        $r.J.pending | Should -BeTrue
        $S.IQueue.Count | Should -Be 1
        (Req $S POST '/api/intune' @{ op = 'list'; area = 'app'; tenant = 'a' } $t).J.pending | Should -BeTrue
        $S.IQueue.Count | Should -Be 1
        $q = $S.IQueue.Dequeue()
        $S.ICache[$q.Key] = @{ State = 'done'; At = (Get-Date); Data = '[{"id":"x","name":"Firefox"}]'; Error = '' }
        $d = Req $S POST '/api/intune' @{ op = 'list'; area = 'app'; tenant = 'a' } $t
        $d.J.pending | Should -BeFalse
        $d.J.data[0].name | Should -Be 'Firefox'
        (Req $S POST '/api/intune' @{ op = 'list'; area = 'app'; tenant = 'zz' } $t).Code | Should -Be 400
        (Req $S POST '/api/intune' @{ op = 'detail'; area = 'app'; tenant = 'a'; id = 'nope' } $t).Code | Should -Be 400
        $S.Intune = $false
        (Req $S POST '/api/intune' @{ op = 'list'; area = 'app'; tenant = 'a' } $t).Code | Should -Be 403
        (Req $S POST '/api/prepare' @{ id = '00000000000000c3'; tenants = @('a'); intune = @{ op = 'unassign'; id = $G1; keys = @('allDevices|') } } $t).Code | Should -Be 403
    }
}

Describe 'Fernbedienung: Sicherheit (Katalog lesen)' {
    It 'erst "pending" mit einer Anfrage in der Warteschlange, danach Ergebnis aus dem Zwischenspeicher; ausgeschaltet = 403' {
        $S = New-TestState; $t = Pair $S
        $r = Req $S POST '/api/sec' @{} $t
        $r.Code | Should -Be 200
        $r.J.pending | Should -BeTrue
        $S.IQueue.Count | Should -Be 1
        (Req $S POST '/api/sec' @{} $t).J.pending | Should -BeTrue
        $S.IQueue.Count | Should -Be 1
        $q = $S.IQueue.Dequeue()
        $q.Op | Should -Be 'sec'
        $S.ICache[$q.Key] = @{ State = 'done'; At = (Get-Date).AddMinutes(-2); Data = '{"rules":[{"id":"A01"}],"tenants":[],"cells":[]}'; Error = '' }
        $d = Req $S POST '/api/sec' @{} $t
        $d.J.pending | Should -BeFalse
        $d.J.data.rules[0].id | Should -Be 'A01'
        # Neu pruefen (force) nach mehr als 30 Sekunden: neue Anfrage
        (Req $S POST '/api/sec' @{ force = $true } $t).J.pending | Should -BeTrue
        $S.IQueue.Count | Should -Be 1
        $S.Sec = $false
        (Req $S POST '/api/sec' @{} $t).Code | Should -Be 403
        (Req $S GET '/api/sec' $null $t).Code | Should -Be 405
    }
    It 'ohne Kopplung: 401' {
        $S = New-TestState
        (Req $S POST '/api/sec' @{}).Code | Should -Be 401
    }
    It 'Tenant-Auswahl: nur bekannte Tenants, eigener Zwischenspeicher; peek startet keine Pruefung' {
        $S = New-TestState; $t = Pair $S
        $known = @(@($S.Tenants) | ForEach-Object { "$($_.key)" })
        $r = Req $S POST '/api/sec' @{ tenants = @($known[0], 'unbekannt'); peek = $true } $t
        $r.J.none | Should -BeTrue
        $S.IQueue.Count | Should -Be 0
        (Req $S POST '/api/sec' @{ tenants = @($known[0], 'unbekannt') } $t).J.pending | Should -BeTrue
        $q = $S.IQueue.Dequeue()
        @($q.Keys) | Should -Be @($known[0])
        $q.Key | Should -Be "sec|$($known[0])"
        $S.ICache[$q.Key] = @{ State = 'done'; At = (Get-Date); Data = '{"rules":[],"tenants":[],"cells":[]}'; Error = '' }
        (Req $S POST '/api/sec' @{ tenants = @($known[0]); peek = $true } $t).J.pending | Should -BeFalse
        (Req $S POST '/api/sec' @{ tenants = @($known[0]); peek = $true } $t).J.none | Should -BeNullOrEmpty
    }
    It 'Daten: Regeln nach Grad sortiert, je Tenant Ampel, Zellen ohne Detaillisten; Fehler eines Tenants bleibt bei diesem' {
        function global:Get-HUSecRules { @([pscustomobject]@{ Id = 'A40'; Sev = 'Mittel'; Area = 'Entra'; Title = 'M' }, [pscustomobject]@{ Id = 'A02'; Sev = 'Kritisch'; Area = 'Entra'; Title = 'K' }) }
        function global:Get-HUSecWhy($Id) { "warum $Id" }
        function global:Get-HUSecItemsLabel($Id) { 'Konten' }
        function global:Test-HUSecItemsExport($Id) { $false }
        function global:Invoke-HUSecCatalog { param($TenantKey, $Settings) if ($TenantKey -eq 'b') { throw 'kein Zugriff' }; @([pscustomobject]@{ RuleId = 'A02'; Status = 'Abweichung'; Reason = ''; Count = 3; Detail = 'drei' }, [pscustomobject]@{ RuleId = '-'; Status = 'Fehler' }) }
        function global:Get-HUSecLight { param($Results, $Key) [pscustomobject]@{ Color = $(if (@($Results).Count) { 'Gelb' } else { 'Grau' }); Ok = 0; Checked = @($Results).Count } }
        try {
            $S = New-TestState
            $d = Get-HURemoteSecData $S ([pscustomobject]@{})
            @($d.rules)[0].id | Should -Be 'A02'
            @($d.rules)[0].why | Should -Be 'warum A02'
            @($d.tenants).Count | Should -Be 2
            @($d.tenants)[0].light | Should -Be 'Gelb'
            @($d.tenants)[1].err | Should -BeLike '*kein Zugriff*'
            @($d.cells).Count | Should -Be 1
            @($d.cells)[0].c | Should -Be 3
            (@(@($d.cells)[0].Keys) -join ',') | Should -Be 't,r,s,x,c,d'
        } finally { foreach ($f in 'Get-HUSecRules', 'Get-HUSecWhy', 'Invoke-HUSecCatalog', 'Get-HUSecLight', 'Get-HUSecItemsLabel', 'Test-HUSecItemsExport') { Remove-Item "function:global:$f" -ErrorAction SilentlyContinue } }
    }
    It 'Detailliste: Personendaten nur nach PIN (dann 5 Minuten frei), Fehlversuche sperren; Liste ohne Personendaten ohne PIN' {
        Set-HURemotePin '4711'
        $S = New-TestState; $S.Pin = Read-HURemotePin; $t = Pair $S
        $dh = @($S.Devices.Keys)[0]
        (Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a' } $t).Code | Should -Be 400     # Regel ohne bekannte Liste
        $S.SecRules['A37'] = @{ Label = 'Konten'; Pii = $true }
        $S.SecRules['A42'] = @{ Label = 'Apps'; Pii = $false }
        (Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'zz' } $t).Code | Should -Be 400
        $r = Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a' } $t
        $r.Code | Should -Be 403; $r.J.pin | Should -BeTrue
        $S.IQueue.Count | Should -Be 0
        $w = Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a'; pin = '0000' } $t
        $w.Code | Should -Be 403; $w.J.error | Should -BeLike 'Falsche PIN*'
        $S.Devices[$dh].PinFails | Should -Be 1
        $ok = Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a'; pin = '4711' } $t
        $ok.J.pending | Should -BeTrue
        $S.Devices[$dh].PinFails | Should -Be 0
        $q = $S.IQueue.Dequeue(); $q.Op | Should -Be 'secitems'; $q.Id | Should -Be 'A37'; $q.Tenant | Should -Be 'a'
        $S.ICache[$q.Key] = @{ State = 'done'; At = (Get-Date); Data = '{"label":"Konten","cols":["Konto"],"rows":[["x@y"]],"total":1}'; Error = '' }
        # innerhalb der Freigabe ohne PIN
        $d = Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a' } $t
        $d.J.data.rows[0][0] | Should -Be 'x@y'
        # Freigabe abgelaufen: wieder PIN
        $S.SecGrant[$dh] = (Get-Date).AddMinutes(-1)
        (Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a' } $t).J.pin | Should -BeTrue
        # ohne Personendaten: ohne PIN
        (Req $S POST '/api/secitems' @{ rule = 'A42'; tenant = 'b' } $t).J.pending | Should -BeTrue
        # drei falsche PINs sperren das Handy
        1..3 | ForEach-Object { [void](Req $S POST '/api/secitems' @{ rule = 'A37'; tenant = 'a'; pin = '9999' } $t) }
        $S.Devices[$dh].Locked | Should -BeTrue
        (Req $S POST '/api/secitems' @{ rule = 'A42'; tenant = 'b' } $t).Code | Should -Be 403
    }
    It 'Detailliste: Spalten und Zeilen, sortiert, hoechstens 1000' {
        function global:Get-HUSecItems { param($TenantKey, $Settings, $RuleId) 1..1200 | ForEach-Object { [pscustomobject]@{ Konto = "u$($_.ToString('0000'))"; Rollen = 'GA' } } | Sort-Object Konto -Descending }
        function global:Get-HUSecRules { @([pscustomobject]@{ Id = 'A37'; ItemsSort = 'Konto' }) }
        function global:Get-HUSecItemsLabel($Id) { 'Konten' }
        try {
            $d = Get-HURemoteSecItems @{ Tenant = 'a'; Id = 'A37' } ([pscustomobject]@{})
            $d.label | Should -Be 'Konten'
            (@($d.cols) -join ',') | Should -Be 'Konto,Rollen'
            @($d.rows).Count | Should -Be 1000
            $d.total | Should -Be 1200
            @($d.rows)[0][0] | Should -Be 'u0001'
        } finally { foreach ($f in 'Get-HUSecItems', 'Get-HUSecRules', 'Get-HUSecItemsLabel') { Remove-Item "function:global:$f" -ErrorAction SilentlyContinue } }
    }
    It 'Webseite: Reiter Sicherheit ist zunaechst versteckt und haengt an Breite und Freigabe' {
        $f = Get-HURemoteWebFiles -Version '2.2.5' -Pc 'PC1'
        $html = [Text.Encoding]::UTF8.GetString($f['/index.html'].Bytes)
        $html | Should -Match 'id="tSec" class="hidden"'
        $html | Should -Match 'id="vSec"'
        $js = [Text.Encoding]::UTF8.GetString($f['/app.js'].Bytes)
        $js | Should -Match "min-width: 600px"
        $js | Should -Match "S\.secOn = j\.sec === true"
    }
}

Describe 'Fernbedienung: Webseite' {
    It 'liefert Seite, Skript, Design, Service Worker, Manifest; strenge CSP ohne Inline-Skript' {
        $f = Get-HURemoteWebFiles -Version '2.1.11' -Pc 'PC1'
        foreach ($k in '/index.html', '/app.js', '/app.css', '/sw.js', '/manifest.webmanifest') { $f.ContainsKey($k) | Should -BeTrue }
        $html = [Text.Encoding]::UTF8.GetString($f['/index.html'].Bytes)
        $html | Should -Not -Match '<script>[^<]'
        $html | Should -Not -Match 'onclick='
        $script:HURemoteHeaders['Content-Security-Policy'] | Should -Match "script-src 'self'"
        [Text.Encoding]::UTF8.GetString($f['/sw.js'].Bytes) | Should -Match 'humt-2\.1\.11'
    }
    It 'Review 032 B1: Probelauf nur an eindeutigen Schaltern' {
        foreach ($p in 'DryRun', 'WhatIf', 'Probelauf', 'dryrun') { $p | Should -Match $script:HURemoteDryRx }
        foreach ($p in 'Test', 'Preview', 'Simulation', 'TestMode') { $p | Should -Not -Match $script:HURemoteDryRx }
    }
    It 'Service-Worker-Cache wechselt mit dem Inhalt (Neuladen holt neue Seite)' {
        $a = [Text.Encoding]::UTF8.GetString((Get-HURemoteWebFiles -Version '2.1.11')['/sw.js'].Bytes)
        $old = $script:HURemoteJs
        try { $script:HURemoteJs = $old + "`n// x"; $b = [Text.Encoding]::UTF8.GetString((Get-HURemoteWebFiles -Version '2.1.11')['/sw.js'].Bytes) } finally { $script:HURemoteJs = $old }
        $a | Should -Not -Be $b
    }
    It 'QR-Code fuer die Adresse' {
        $q = ConvertTo-HURQrMatrix 'https://192.168.1.20:8444/#c=123456'
        $q.Size | Should -BeGreaterThan 20
    }
}
