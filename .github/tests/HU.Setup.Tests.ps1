#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5): Anmeldung per Zertifikat (HU.Auth) und Ersteinrichtung/Rechte (HU.Setup) - ohne Netzwerk.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1)
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AppRoot = $root
    if (-not $env:APPDATA) { $env:APPDATA = [System.IO.Path]::GetTempPath() }
    Import-Module (Join-Path $root 'Core\HU.Auth.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Setup.psm1') -Force -DisableNameChecking

    # Testzertifikat mit privatem Schluessel (nur im Speicher)
    function New-TestCert {
        $isWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
        $rsa = if ($isWin) { New-Object System.Security.Cryptography.RSACng 2048 } else { [System.Security.Cryptography.RSA]::Create(2048) }
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest('CN=HU-Test', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(30))
    }
    function ConvertFrom-B64Url([string]$s) {
        $s = $s.Replace('-', '+').Replace('_', '/'); switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
        return [Convert]::FromBase64String($s)
    }
    $script:Cert = New-TestCert
}

Describe 'Zertifikat: New-HUClientAssertion' {
    It 'PS256: Kopf mit x5t#S256, Claims, Signatur pruefbar' {
        $jwt = New-HUClientAssertion -Certificate $script:Cert -Issuer 'app-1' -Audience 'https://login/t/token'
        $p = $jwt.Split('.')
        $p.Count | Should -Be 3
        $h = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $p[0])) | ConvertFrom-Json
        $h.alg | Should -Be 'PS256'
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $h.'x5t#S256' | Should -Be (ConvertTo-HUBase64Url ($sha.ComputeHash($script:Cert.RawData)))
        $c = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $p[1])) | ConvertFrom-Json
        $c.iss | Should -Be 'app-1'; $c.sub | Should -Be 'app-1'; $c.aud | Should -Be 'https://login/t/token'
        ($c.exp - $c.iat) | Should -Be 600; ($c.iat - $c.nbf) | Should -Be 60
        $pub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:Cert)
        $pub.VerifyData([Text.Encoding]::ASCII.GetBytes("$($p[0]).$($p[1])"), (ConvertFrom-B64Url $p[2]), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss) | Should -BeTrue
    }
    It 'RS256 (Nachweis fuer addKey): x5t (SHA-1), PKCS#1' {
        $jwt = New-HUClientAssertion -Certificate $script:Cert -Issuer 'obj-1' -Audience '00000002-0000-0000-c000-000000000000' -Alg RS256
        $p = $jwt.Split('.')
        $h = [Text.Encoding]::UTF8.GetString((ConvertFrom-B64Url $p[0])) | ConvertFrom-Json
        $h.alg | Should -Be 'RS256'
        $h.x5t | Should -Be (ConvertTo-HUBase64Url $script:Cert.GetCertHash())
        $pub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:Cert)
        $pub.VerifyData([Text.Encoding]::ASCII.GetBytes("$($p[0]).$($p[1])"), (ConvertFrom-B64Url $p[2]), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1) | Should -BeTrue
    }
    It 'ohne privaten Schluessel: Fehler' {
        $pubOnly = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $script:Cert.RawData)
        { New-HUClientAssertion -Certificate $pubOnly -Issuer 'a' -Audience 'b' } | Should -Throw
    }
}

Describe 'Zertifikat: Get-GraphToken' {
    BeforeEach { Clear-TokenCache }
    It 'sendet client_assertion und kein client_secret' {
        $s = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; tenantId = '11111111-1111-1111-1111-111111111111'; appId = '22222222-2222-2222-2222-222222222222'; auth = 'certificate'; certThumbprint = $script:Cert.Thumbprint }) }
        $c = $script:Cert
        Mock -ModuleName HU.Auth Get-HUTenantCertificate { $c }
        Mock -ModuleName HU.Auth Get-StoredCredential { throw 'Secret darf nicht gelesen werden' }
        Mock -ModuleName HU.Auth Invoke-RestMethod { $script:LastBody = $Body; [pscustomobject]@{ access_token = 'tok-12345'; expires_in = 3600 } }
        Get-GraphToken -TenantKey 'T1' -Settings $s | Should -Be 'tok-12345'
        $script:LastBody.client_assertion_type | Should -Be 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $script:LastBody.client_assertion | Should -Match '^[\w-]+\.[\w-]+\.[\w-]+$'
        $script:LastBody.ContainsKey('client_secret') | Should -BeFalse
    }
    It 'fehlendes Zertifikat: kein Token, Hinweis neu einrichten' {
        $s = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T2'; tenantId = '11111111-1111-1111-1111-111111111111'; appId = '22222222-2222-2222-2222-222222222222'; auth = 'certificate'; certThumbprint = ('A' * 40) }) }
        Mock -ModuleName HU.Auth Get-HUTenantCertificate { $null }
        Mock -ModuleName HU.Auth Invoke-RestMethod { throw 'darf nicht aufgerufen werden' }
        $err = $null
        Get-GraphToken -TenantKey 'T2' -Settings $s -ErrorVariable err -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        "$err" | Should -Match 'neu einrichten'
    }
    It 'Test-HUTenantCertAuth nur bei auth=certificate' {
        Test-HUTenantCertAuth ([pscustomobject]@{ auth = 'certificate' }) | Should -BeTrue
        Test-HUTenantCertAuth ([pscustomobject]@{ key = 'x' }) | Should -BeFalse
        Test-HUTenantCertAuth $null | Should -BeFalse
    }
}

Describe 'Rechte-Katalog (Config\graph-permissions.json)' {
    BeforeAll { $script:Cat = Get-HUPermissionCatalog $script:AppRoot }
    It 'Namen eindeutig, Standard-Rechte vorhanden' {
        $n = @($script:Cat.permissions | ForEach-Object { "$($_.name)" })
        ($n | Select-Object -Unique).Count | Should -Be $n.Count
        @($script:Cat.permissions | Where-Object { $_.default -eq $true }).Count | Should -BeGreaterThan 5
        $n | Should -Contain 'Organization.Read.All'
    }
    It 'weitreichend unter den Standard-Rechten nur Geraeteaktionen und Wartungsskripte (Review 033 Frage 3)' {
        $r = @($script:Cat.permissions | Where-Object { $_.default -eq $true -and (Test-HUPermissionRisky $_.name $script:Cat) } | ForEach-Object { "$($_.name)" } | Sort-Object)
        $r | Should -Be @('DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementScripts.ReadWrite.All')
    }
    It 'risky-Eintraege ohne Platzhalter sehen wie Rechtenamen aus' {
        foreach ($x in @($script:Cat.risky | Where-Object { $_ -notmatch '\*' })) { $x | Should -Match '^[A-Za-z-]+(\.[A-Za-z]+)+$' }
    }
    It 'erkennt weitreichende Rechte (auch mit Platzhalter)' {
        Test-HUPermissionRisky 'Mail.Send' $script:Cat | Should -BeTrue
        Test-HUPermissionRisky 'Application.ReadWrite.All' $script:Cat | Should -BeTrue
        Test-HUPermissionRisky 'Policy.ReadWrite.ConditionalAccess' $script:Cat | Should -BeTrue
        Test-HUPermissionRisky 'User.Read.All' $script:Cat | Should -BeFalse
        Test-HUPermissionRisky 'DeviceManagementApps.ReadWrite.All' $script:Cat | Should -BeFalse
    }
}

Describe 'Admin-Anmeldung: Antwort an localhost' {
    It 'ignoriert Vorab-Verbindungen und favicon, meldet Ablehnung, Rollenpruefung' {
        Mock -ModuleName HU.Setup Start-Process { }
        $ctx = Start-HUAdminLogin
        try {
            $ctx.Port | Should -BeGreaterThan 0
            Receive-HUAdminLogin -Context $ctx | Should -BeNullOrEmpty
            $send = {
                param($line)
                $tc = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $ctx.Port)
                $ns = $tc.GetStream(); $b = [Text.Encoding]::ASCII.GetBytes("$line`r`nHost: localhost`r`n`r`n"); $ns.Write($b, 0, $b.Length); $ns.Flush()
                Start-Sleep -Milliseconds 200
                $r = Receive-HUAdminLogin -Context $ctx
                try { $tc.Close() } catch { }
                return $r
            }
            & $send 'GET /favicon.ico HTTP/1.1' | Should -BeNullOrEmpty
            $r = & $send "GET /?error=access_denied&error_description=abgelehnt&state=$($ctx.State) HTTP/1.1"
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'access_denied'
        } finally { Stop-HUAdminLogin $ctx }
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @('62e90394-69f5-4237-9190-012177145e10') }) | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @('e8611ab8-c189-46e8-94e1-60213ab1f814') }) | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @('9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3') }) | Should -BeFalse
    }
    It 'falscher state wird ignoriert, danach zaehlt die echte Antwort (Review 033 B4)' {
        Mock -ModuleName HU.Setup Start-Process { }
        $ctx = Start-HUAdminLogin
        try {
            $send = {
                param($line)
                $tc = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $ctx.Port)
                $ns = $tc.GetStream(); $b = [Text.Encoding]::ASCII.GetBytes("$line`r`n`r`n"); $ns.Write($b, 0, $b.Length); $ns.Flush()
                Start-Sleep -Milliseconds 200
                $r = Receive-HUAdminLogin -Context $ctx
                try { $tc.Close() } catch { }
                return $r
            }
            & $send 'GET /?error=access_denied&state=fremd HTTP/1.1' | Should -BeNullOrEmpty
            & $send 'GET /?code=abc&state=fremd HTTP/1.1' | Should -BeNullOrEmpty
            $r = & $send "GET /?error=access_denied&state=$($ctx.State) HTTP/1.1"
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'access_denied'
        } finally { Stop-HUAdminLogin $ctx }
    }
    It 'Rollen: Einrichtung braucht GA oder PRA + App-Admin, Rechte erteilen reicht PRA (Review 033 B8)' {
        $ga = '62e90394-69f5-4237-9190-012177145e10'; $pra = 'e8611ab8-c189-46e8-94e1-60213ab1f814'; $caa = '158c047a-c907-4556-b7ef-446551a6b5f7'; $aa = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($ga) }) -ForSetup | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($pra) }) -ForSetup | Should -BeFalse
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($pra, $caa) }) -ForSetup | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($pra, $aa) }) -ForSetup | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($pra) }) | Should -BeTrue
        Test-HUAdminCanGrant ([pscustomobject]@{ Roles = @($aa) }) | Should -BeFalse
    }
    It 'zusaetzliche Zustimmungen im Token werden erkannt (Review 033 B2)' {
        $enc = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $tok = "x.$(& $enc @{ scp = 'Application.ReadWrite.All AppRoleAssignment.ReadWrite.All Directory.Read.All User.Read openid profile' }).y"
        @(Get-HUExtraScopes ([pscustomobject]@{ Token = $tok })).Count | Should -Be 0
        $tok2 = "x.$(& $enc @{ scp = 'Application.ReadWrite.All User.Read Mail.Send Directory.ReadWrite.All' }).y"
        Get-HUExtraScopes ([pscustomobject]@{ Token = $tok2 }) | Should -Be @('Directory.ReadWrite.All', 'Mail.Send')
    }
    It 'Zustimmung fuer alle Benutzer wird erkannt, ohne etwas zu aendern' {
        $script:Methods = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            $script:Methods.Add("$Method")
            if ($Path -match 'filter=appId') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'sp-cli' }) } }
            return [pscustomobject]@{ value = @([pscustomobject]@{ consentType = 'Principal'; scope = 'User.Read' }, [pscustomobject]@{ consentType = 'AllPrincipals'; scope = 'Application.ReadWrite.All User.Read' }) }
        }
        $r = Get-HUGraphCliConsent -Token 't'
        $r.Checked | Should -BeTrue
        $r.AllPrincipals | Should -BeTrue
        $r.Scopes | Should -Contain 'Application.ReadWrite.All'
        @($script:Methods | Where-Object { $_ -and $_ -ne 'GET' }).Count | Should -Be 0
    }
}

Describe 'Zertifikat erneuern: Update-HUTenantCertificate (Review 033 B1/B3)' {
    BeforeEach {
        $c = $script:Cert
        $script:New = New-TestCert
        $n = $script:New
        Mock -ModuleName HU.Setup Get-Item { $c }
        Mock -ModuleName HU.Setup New-HUTenantCertificate { $n }
        Mock -ModuleName HU.Setup Get-HUAppTokenByCert { [pscustomobject]@{ Token = 't'; Payload = $null } }
        Mock -ModuleName HU.Setup Remove-HUCertLocal { $true }
        $script:Calls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            $script:Calls.Add("$Method $Path")
            if ($Path -like '*/addKey') { return [pscustomobject]@{ keyId = '11111111-2222-3333-4444-555555555555' } }
            return $null
        }
        $script:T = [pscustomobject]@{ key = 'T'; tenantId = '33333333-3333-3333-3333-333333333333'; appId = '44444444-4444-4444-4444-444444444444'
            appObjectId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; certThumbprint = $c.Thumbprint; certKeyId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
    }
    It 'nur addKey + Test - kein removeKey, altes Zertifikat bleibt lokal (B1/B14)' {
        $r = Update-HUTenantCertificate -Tenant $script:T
        $r.Thumbprint | Should -Be $script:New.Thumbprint
        $r.OldThumbprint | Should -Be $script:Cert.Thumbprint
        $r.KeyId | Should -Be '11111111-2222-3333-4444-555555555555'
        $r.OldKeyId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        @($script:Calls) | Should -Be @('POST /applications/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/addKey')
        Should -Invoke -ModuleName HU.Setup Remove-HUCertLocal -Times 0 -Exactly
    }
    It 'Remove-HUTenantOldKey: removeKey mit gespeicherter keyId, ohne GET' {
        $n = $script:New
        Mock -ModuleName HU.Setup Get-Item { $n }
        $t2 = $script:T.PSObject.Copy(); $t2.certThumbprint = $n.Thumbprint
        Remove-HUTenantOldKey -Tenant $t2 -OldThumbprint $script:Cert.Thumbprint -OldKeyId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' | Should -BeNullOrEmpty
        @($script:Calls) | Should -Be @('POST /applications/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/removeKey')
    }
    It 'Remove-HUTenantOldKey: keyId ueber den Fingerabdruck nachschlagen' {
        $n = $script:New; $old = $script:Cert
        Mock -ModuleName HU.Setup Get-Item { $n }
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            $script:Calls.Add("$Method $Path")
            if ($Path -like '*select=keyCredentials') { return [pscustomobject]@{ keyCredentials = @([pscustomobject]@{ keyId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; customKeyIdentifier = [Convert]::ToBase64String($old.GetCertHash()) }) } }
            if ($Path -like '*/removeKey') { $Body.keyId | Should -Be 'cccccccc-cccc-cccc-cccc-cccccccccccc' }
            return $null
        }
        $t2 = $script:T.PSObject.Copy(); $t2.certThumbprint = $n.Thumbprint
        Remove-HUTenantOldKey -Tenant $t2 -OldThumbprint $old.Thumbprint | Should -BeNullOrEmpty
        $script:Calls | Should -Contain 'POST /applications/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/removeKey'
    }
    It 'Fehler bei addKey: neues Zertifikat weg, altes unberuehrt' {
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph { throw 'Forbidden' }
        { Update-HUTenantCertificate -Tenant $script:T } | Should -Throw '*Erneuern fehlgeschlagen*'
        Should -Invoke -ModuleName HU.Setup Remove-HUCertLocal -Times 1 -Exactly -ParameterFilter { $Thumbprint -eq $script:New.Thumbprint }
    }
}

Describe 'Ersteinrichtung: New-HUTenantSetup' {
    BeforeAll {
        $script:Login = [pscustomobject]@{ Token = 'adm'; Tid = '33333333-3333-3333-3333-333333333333'; Upn = 'admin@schule.at'; Roles = @('62e90394-69f5-4237-9190-012177145e10') }
    }
    BeforeEach {
        $c = $script:Cert
        Mock -ModuleName HU.Setup Get-HUSetupOrganization { [pscustomobject]@{ Id = 'o'; Name = 'Schule'; Domain = 'schule.at'; Initial = 'schule.onmicrosoft.com' } }
        Mock -ModuleName HU.Setup Get-HUGraphRoleMap { [pscustomobject]@{ SpId = 'graph-sp'; Roles = @{ 'User.Read.All' = 'r1'; 'Organization.Read.All' = 'r2' } } }
        Mock -ModuleName HU.Setup New-HUTenantCertificate { $c }
        Mock -ModuleName HU.Setup Remove-HUCertLocal { $true }
        Mock -ModuleName HU.Setup Get-HUAppTokenByCert { [pscustomobject]@{ Token = 't'; Payload = [pscustomobject]@{ tid = '33333333-3333-3333-3333-333333333333'; roles = @('User.Read.All') } } }
    }
    It 'legt App, SP und Rechte an und liefert den Tenant-Eintrag' {
        $script:Calls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            $script:Calls.Add("$Method $Path")
            if ($Path -eq '/applications') { $Body.keyCredentials[0].type | Should -Be 'AsymmetricX509Cert'; return [pscustomobject]@{ id = 'app-obj'; appId = '44444444-4444-4444-4444-444444444444' } }
            if ($Path -eq '/servicePrincipals') { return [pscustomobject]@{ id = 'sp-1' } }
            return [pscustomobject]@{ id = 'x' }
        }
        $r = New-HUTenantSetup -Login $script:Login -Permissions @('User.Read.All', 'Organization.Read.All') -Key 'Schule'
        $r.auth | Should -Be 'certificate'
        $r.appId | Should -Be '44444444-4444-4444-4444-444444444444'
        $r.certThumbprint | Should -Be $script:Cert.Thumbprint
        $r.appObjectId | Should -Be 'app-obj'
        $r.displayName | Should -Be 'Schule'
        $r.domain | Should -Be 'schule.at'
        @($script:Calls | Where-Object { $_ -like 'POST */appRoleAssignedTo' }).Count | Should -Be 2
        @($script:Calls | Where-Object { $_ -like 'DELETE*' }).Count | Should -Be 0
    }
    It 'unbekanntes Recht: Abbruch vor dem Anlegen' {
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph { throw 'darf nicht aufgerufen werden' }
        { New-HUTenantSetup -Login $script:Login -Permissions @('Gibt.Es.Nicht') -Key 'S' } | Should -Throw '*gibt es in Microsoft Graph nicht*'
        Should -Invoke -ModuleName HU.Setup New-HUTenantCertificate -Times 0 -Exactly
    }
    It 'Fehler beim Rechte-Erteilen: raeumt SP, App und Zertifikat wieder weg' {
        $script:Calls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            $script:Calls.Add("$Method $Path")
            if ($Path -eq '/applications') { return [pscustomobject]@{ id = 'app-obj'; appId = '44444444-4444-4444-4444-444444444444' } }
            if ($Path -eq '/servicePrincipals') { return [pscustomobject]@{ id = 'sp-1' } }
            if ($Path -like '*/appRoleAssignedTo') { throw 'Authorization_RequestDenied' }
            return $null
        }
        { New-HUTenantSetup -Login $script:Login -Permissions @('User.Read.All') -Key 'S' } | Should -Throw '*Authorization_RequestDenied*'
        $script:Calls | Should -Contain 'DELETE /servicePrincipals/sp-1'
        $script:Calls | Should -Contain 'DELETE /applications/app-obj'
        Should -Invoke -ModuleName HU.Setup Remove-HUCertLocal -Times 1 -Exactly
    }
}

Describe 'Rechte erweitern: Add-HUAppPermissions' {
    It 'erteilt nur fehlende Rechte' {
        $script:Posted = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName HU.Setup Get-HUGraphRoleMap { [pscustomobject]@{ SpId = 'graph-sp'; Roles = @{ 'User.Read.All' = 'r1'; 'Mail.Send' = 'r2' } } }
        Mock -ModuleName HU.Setup Get-HUAppGrantedRoles { [pscustomobject]@{ SpId = 'sp-1'; Assignments = @([pscustomobject]@{ resourceId = 'graph-sp'; appRoleId = 'r1' }) } }
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            if ($Method -eq 'POST') { $script:Posted.Add("$($Body.appRoleId)") }
            if ($Method -eq 'GET' -or -not $Method) { return [pscustomobject]@{ id = 'app-obj'; requiredResourceAccess = @() } }
            return $null
        }
        $added = @(Add-HUAppPermissions -Login ([pscustomobject]@{ Token = 'adm' }) -AppId '44444444-4444-4444-4444-444444444444' -Permissions @('User.Read.All', 'Mail.Send'))
        $added | Should -Be @('Mail.Send')
        @($script:Posted) | Should -Be @('r2')
    }
}

Describe 'Schreibrechte entziehen: Remove-HUAppPermissions' {
    It 'entzieht genau die angegebenen Rechte, andere bleiben; App-Liste wird nachgezogen' {
        $script:Deleted = New-Object System.Collections.Generic.List[string]
        $script:Patched = $null
        Mock -ModuleName HU.Setup Get-HUGraphRoleMap { [pscustomobject]@{ SpId = 'graph-sp'; Roles = @{ 'Policy.ReadWrite.ConditionalAccess' = 'rCA'; 'User.Read.All' = 'rU'; 'Policy.ReadWrite.Authorization' = 'rA' } } }
        Mock -ModuleName HU.Setup Get-HUAppGrantedRoles { [pscustomobject]@{ SpId = 'sp-1'; Assignments = @(
                    [pscustomobject]@{ id = 'a1'; resourceId = 'graph-sp'; appRoleId = 'rCA' }, [pscustomobject]@{ id = 'a2'; resourceId = 'graph-sp'; appRoleId = 'rU' }) } }
        Mock -ModuleName HU.Setup Invoke-HUSetupGraph {
            if ($Method -eq 'DELETE') { $script:Deleted.Add("$Path") }
            if ($Method -eq 'PATCH') { $script:Patched = $Body }
            if ($Method -eq 'GET' -or -not $Method) { return [pscustomobject]@{ id = 'app-obj'; requiredResourceAccess = @([pscustomobject]@{ resourceAppId = '00000003-0000-0000-c000-000000000000'; resourceAccess = @([pscustomobject]@{ id = 'rCA'; type = 'Role' }, [pscustomobject]@{ id = 'rU'; type = 'Role' }) }) } }
            return $null
        }
        $r = @(Remove-HUAppPermissions -Login ([pscustomobject]@{ Token = 'adm' }) -AppId '44444444-4444-4444-4444-444444444444' -Permissions @('Policy.ReadWrite.ConditionalAccess', 'Policy.ReadWrite.Authorization'))
        $r | Should -Be @('Policy.ReadWrite.ConditionalAccess')
        @($script:Deleted) | Should -Be @('/servicePrincipals/graph-sp/appRoleAssignedTo/a1')
        @($script:Patched.requiredResourceAccess[0].resourceAccess | ForEach-Object { $_.id }) | Should -Be @('rU')
    }
}

Describe 'Alte Secrets nach Umstellung loeschen (Remove-HUObsoleteSecret)' {
    BeforeAll {
        function Write-HULogInfo { param($Message, $Tenant) }
        function Write-HULogWarn { param($Message, $Tenant) }
        . (Join-Path $script:AppRoot 'Functions\UI-TenantSetup.ps1')
        $script:Settings = [pscustomobject]@{ credentials = [pscustomobject]@{ credentialNamePrefix = 'HU-' }; tenants = @() }
    }
    It 'loescht nur bei Zertifikat-Tenant mit vorhandenem Zertifikat und gespeichertem Secret' {
        $c = $script:Cert
        Mock Get-HUTenantCertificate { $c }
        Mock Get-StoredCredential { $s = New-Object System.Security.SecureString; $s.AppendChar('x'); $s }
        Mock Remove-StoredCredential { }
        Remove-HUObsoleteSecret ([pscustomobject]@{ key = 'T1'; auth = 'certificate'; certThumbprint = $c.Thumbprint }) | Should -BeTrue
        Should -Invoke Remove-StoredCredential -Times 1 -Exactly
    }
    It 'Secret-Tenant: nie loeschen' {
        Mock Remove-StoredCredential { }
        Remove-HUObsoleteSecret ([pscustomobject]@{ key = 'T2' }) | Should -BeFalse
        Should -Invoke Remove-StoredCredential -Times 0 -Exactly
    }
    It 'Zertifikat fehlt auf diesem PC: Secret bleibt' {
        Mock Get-HUTenantCertificate { $null }
        Mock Remove-StoredCredential { }
        Remove-HUObsoleteSecret ([pscustomobject]@{ key = 'T3'; auth = 'certificate'; certThumbprint = ('A' * 40) }) | Should -BeFalse
        Should -Invoke Remove-StoredCredential -Times 0 -Exactly
    }
}

Describe 'Rechte erteilen: nach dem Erteilen nicht dieselben Rechte wieder anbieten' {
    BeforeAll {
        function Write-HULogInfo { param($Message, $Tenant) }
        function Write-HULogWarn { param($Message, $Tenant) }
        . (Join-Path $script:AppRoot 'Functions\UI-TenantSetup.ps1')
    }
    It 'gewaehlte, schon vorhandene Rechte gelten danach als erteilt; Auswahl ist leer' {
        Set-StrictMode -Version 1.0
        Mock Add-HUTsuLog { }
        Mock Update-HUTsuPermList { }
        Mock Clear-TokenCache { }
        $script:PermCache = @{}
        $script:TSU = @{ Mode = 'Grant'; Tenant = [pscustomobject]@{ key = 'T1' }; Granted = @('User.Read.All'); Sel = @('Group.Read.All', 'DeviceLocalCredential.Read.All')
            Result = $null; Phase = 'Work'; C = @{ btnStart = [pscustomobject]@{ Content = '' }; lstLog = [pscustomobject]@{ Items = @() } } }
        Complete-HUTsuWork ([pscustomobject]@{ Added = @('DeviceLocalCredential.Read.All') })
        $script:TSU.Granted | Should -Contain 'Group.Read.All'
        $script:TSU.Granted | Should -Contain 'DeviceLocalCredential.Read.All'
        @($script:TSU.Sel).Count | Should -Be 0
        $script:TSU.Phase | Should -Be 'Idle'
        @($script:TSU.Result) | Should -Be @('DeviceLocalCredential.Read.All')
        Set-StrictMode -Off
    }
}
