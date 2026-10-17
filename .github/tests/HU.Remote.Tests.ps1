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
    It 'QR-Code fuer die Adresse' {
        $q = ConvertTo-HURQrMatrix 'https://192.168.1.20:8444/#c=123456'
        $q.Size | Should -BeGreaterThan 20
    }
}
