#Requires -Version 5.1
<#
.SYNOPSIS
    HU.Setup - Ersteinrichtung eines Tenants mit Zertifikat, Rechte erweitern, Zertifikat erneuern.
.DESCRIPTION
    Admin-Anmeldung im Systembrowser (Auth Code + PKCE, Antwort an http://localhost:<Port>) mit der Microsoft-App
    "Microsoft Graph Command Line Tools" - keine eigene Setup-App noetig. Delegierte Rechte nur fuer diese Sitzung:
    Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, User.Read. Das Admin-Token bleibt im Speicher.
    Danach meldet sich HU-MultiTenant nur noch mit einem nicht exportierbaren Zertifikat an (HU.Auth).
    Quellen: learn.microsoft.com/entra/identity-platform/v2-oauth2-auth-code-flow
             learn.microsoft.com/entra/identity-platform/certificate-credentials
             learn.microsoft.com/graph/api/application-post-applications
             learn.microsoft.com/graph/api/serviceprincipal-post-approleassignedto
             learn.microsoft.com/graph/application-rollkey-prooftoken (addKey/removeKey)
.NOTES
    Benoetigt HU.Auth (New-HUClientAssertion, ConvertTo-HUBase64Url).
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1, ohne Adminrechte).
#>

$script:SetupClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:SetupScopes = 'https://graph.microsoft.com/Application.ReadWrite.All https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All https://graph.microsoft.com/User.Read'
$script:GlobalAdminRole = '62e90394-69f5-4237-9190-012177145e10'
$script:PrivRoleAdminRole = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
$script:AppTag = 'HU-MultiTenant'

# ============================================================================
# Hilfen
# ============================================================================
function ConvertFrom-HUJwtPayload([string]$Jwt) {
    $p = "$Jwt".Split('.')[1]
    if (-not $p) { return $null }
    $p = $p.Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json)
}

# Fehlertext aus Graph/Entra (nie Header, nie Token)
function Get-HUSetupErrorText($Err) {
    $m = "$($Err.Exception.Message)"
    try {
        $j = "$($Err.ErrorDetails.Message)" | ConvertFrom-Json
        if ($j.error.message) { $m = "$($j.error.code): $($j.error.message)" }
        elseif ($j.error_description) { $m = "$($j.error): $((("$($j.error_description)") -split "`r?`n")[0])" }
    } catch { }
    return $m
}

# Graph-Aufruf mit Wiederholung, solange Entra ein gerade angelegtes Objekt noch nicht kennt (Replikation)
function Invoke-HUSetupGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token, [string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body = $null, [int]$Tries = 1)
    $h = @{ Authorization = "Bearer $Token" }
    $j = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 10 -Compress } else { $null }
    for ($i = 1; $i -le $Tries; $i++) {
        try {
            $uri = "https://graph.microsoft.com/v1.0$Path"
            if ($j) { return (Invoke-RestMethod -Method $Method -Uri $uri -Headers $h -Body ([System.Text.Encoding]::UTF8.GetBytes($j)) -ContentType 'application/json; charset=utf-8' -ErrorAction Stop) }
            return (Invoke-RestMethod -Method $Method -Uri $uri -Headers $h -ErrorAction Stop)
        } catch {
            $e = Get-HUSetupErrorText $_
            if ($i -lt $Tries -and $e -match 'Request_ResourceNotFound|does not reference a valid|does not exist|NotFound|Too ?Many|429|503|ServiceUnavailable') {
                Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $i))); continue
            }
            throw "$Method $Path : $e"
        }
    }
}

# Rechte-Liste (Config\graph-permissions.json)
function Get-HUPermissionCatalog([string]$AppRoot) {
    $f = Join-Path $AppRoot 'Config\graph-permissions.json'
    return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Test-HUPermissionRisky([string]$Name, $Catalog) {
    foreach ($p in @($Catalog.risky)) { if ($Name -like "$p") { return $true } }
    return $false
}

# ============================================================================
# Admin-Anmeldung im Browser (nicht blockierend: Start -> im UI-Takt Receive -> Stop)
# ============================================================================
function Start-HUAdminLogin {
    <#
    .SYNOPSIS
        Oeffnet den Browser zur Admin-Anmeldung. Rueckgabe: Kontext fuer Receive-HUAdminLogin/Stop-HUAdminLogin.
    .PARAMETER TenantId
        Fester Tenant (Rechte erweitern, Zertifikat neu) - leer bei der Ersteinrichtung ('organizations').
    #>
    [CmdletBinding()]
    param([string]$TenantId = '')
    $rnd = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
    $verifier = ConvertTo-HUBase64Url $rnd
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $challenge = ConvertTo-HUBase64Url ($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))) } finally { $sha.Dispose() }
    $state = [guid]::NewGuid().ToString('N')
    # freier Port auf 127.0.0.1, zusaetzlich ::1 ("localhost" kann im Browser IPv6 sein) - TcpListener braucht keine Adminrechte
    $l4 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $l4.Start()
    $port = ([System.Net.IPEndPoint]$l4.LocalEndpoint).Port
    $l6 = $null; try { $l6 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Loopback, $port); $l6.Start() } catch { $l6 = $null }
    $authority = if ($TenantId -match '^[0-9a-fA-F-]{36}$') { $TenantId } else { 'organizations' }
    $redirect = "http://localhost:$port/"
    $q = [ordered]@{ client_id = $script:SetupClientId; response_type = 'code'; redirect_uri = $redirect; response_mode = 'query'; scope = $script:SetupScopes
        state = $state; code_challenge = $challenge; code_challenge_method = 'S256'; prompt = 'select_account' }
    $url = "https://login.microsoftonline.com/$authority/oauth2/v2.0/authorize?" + (($q.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString("$($_.Value)"))" }) -join '&')
    Start-Process $url
    return [pscustomobject]@{ L4 = $l4; L6 = $l6; Port = $port; Redirect = $redirect; State = $state; Verifier = $verifier; Authority = $authority; Started = (Get-Date) }
}

function Receive-HUAdminLogin {
    <#
    .SYNOPSIS
        Pruefen, ob der Browser geantwortet hat. Rueckgabe: $null (wartet noch) oder @{ Ok; Error; Token; Tid; Upn; Name; Roles }.
        Nach einer Antwort (auch Fehler) ist der Kontext beendet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [int]$TimeoutMinutes = 5)
    $client = $null
    if ($Context.L4.Pending()) { $client = $Context.L4.AcceptTcpClient() }
    elseif ($Context.L6 -and $Context.L6.Pending()) { $client = $Context.L6.AcceptTcpClient() }
    if (-not $client) {
        if (((Get-Date) - $Context.Started).TotalMinutes -gt $TimeoutMinutes) { Stop-HUAdminLogin $Context; return [pscustomobject]@{ Ok = $false; Error = "Keine Anmeldung innerhalb von $TimeoutMinutes Minuten" } }
        return $null
    }
    # Browser oeffnen manchmal Vorab-Verbindungen ohne Anfrage oder holen /favicon.ico: die ignorieren und weiter warten
    $first = ''
    try {
        $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        try { $first = $reader.ReadLine() } catch { $first = '' }
        $m = [regex]::Match("$first", '^GET (/\?\S*) HTTP')
        $isAnswer = $m.Success -and $m.Groups[1].Value -match '[?&](code|error)='
        if (-not $isAnswer) {
            try { $nf = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); $stream.Write($nf, 0, $nf.Length) } catch { }
            try { $client.Close() } catch { }
            return $null
        }
        $html = '<!doctype html><meta charset="utf-8"><title>HU-MultiTenant</title><body style="font-family:Segoe UI,sans-serif;background:#1e1e1e;color:#ddd;padding:40px"><h2>Anmeldung abgeschlossen</h2><p>Dieses Fenster kann geschlossen werden - weiter in HU-MultiTenant.</p></body>'
        $b = [System.Text.Encoding]::UTF8.GetBytes($html)
        $hdr = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($hdr, 0, $hdr.Length); $stream.Write($b, 0, $b.Length); $stream.Flush()
    } catch { } finally { try { $client.Close() } catch { } }
    Stop-HUAdminLogin $Context
    $res = [pscustomobject]@{ Ok = $false; Error = ''; Token = ''; Tid = ''; Upn = ''; Name = ''; Roles = @() }
    Add-Type -AssemblyName System.Web
    $qs = [System.Web.HttpUtility]::ParseQueryString(([Uri]("http://localhost$($m.Groups[1].Value)")).Query)
    if ($qs['error']) { $res.Error = "Anmeldung abgelehnt: $($qs['error']) - $((("$($qs['error_description'])") -split "`r?`n")[0])"; return $res }
    if ($qs['state'] -ne $Context.State) { $res.Error = 'Antwort passt nicht zur Anmeldung (state) - abgebrochen'; return $res }
    if (-not $qs['code']) { $res.Error = 'Kein Code in der Antwort'; return $res }
    $body = @{ client_id = $script:SetupClientId; grant_type = 'authorization_code'; code = $qs['code']; redirect_uri = $Context.Redirect; code_verifier = $Context.Verifier; scope = $script:SetupScopes }
    try { $t = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($Context.Authority)/oauth2/v2.0/token" -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop }
    catch { $res.Error = "Anmeldung fehlgeschlagen: $(Get-HUSetupErrorText $_)"; return $res }
    $p = ConvertFrom-HUJwtPayload $t.access_token
    $res.Ok = $true; $res.Token = $t.access_token; $res.Tid = "$($p.tid)"; $res.Upn = "$($p.upn)"; $res.Name = "$($p.name)"; $res.Roles = @($p.wids)
    return $res
}

function Stop-HUAdminLogin($Context) {
    if (-not $Context) { return }
    try { $Context.L4.Stop() } catch { }
    try { if ($Context.L6) { $Context.L6.Stop() } } catch { }
}

# Darf das angemeldete Konto Rechte erteilen? (Global Administrator oder Privileged Role Administrator)
function Test-HUAdminCanGrant($Login) {
    return (@($Login.Roles) -contains $script:GlobalAdminRole -or @($Login.Roles) -contains $script:PrivRoleAdminRole)
}

# ============================================================================
# Graph: Organisation, Rechte, App anlegen
# ============================================================================
function Get-HUSetupOrganization([Parameter(Mandatory)][string]$Token) {
    $o = @((Invoke-HUSetupGraph -Token $Token -Path '/organization?$select=id,displayName,verifiedDomains').value)[0]
    $dom = @($o.verifiedDomains | Where-Object { $_.isDefault }) | Select-Object -First 1
    $init = @($o.verifiedDomains | Where-Object { $_.isInitial }) | Select-Object -First 1
    return [pscustomobject]@{ Id = "$($o.id)"; Name = "$($o.displayName)"; Domain = "$(if ($dom) { $dom.name } elseif ($init) { $init.name })"; Initial = "$(if ($init) { $init.name })" }
}

# Graph-Service-Principal des Tenants und Rechte-Name -> ID (nur Anwendungsrechte)
function Get-HUGraphRoleMap([Parameter(Mandatory)][string]$Token) {
    $sp = @((Invoke-HUSetupGraph -Token $Token -Path "/servicePrincipals?`$filter=appId eq '$($script:GraphAppId)'&`$select=id,appRoles").value)[0]
    if (-not $sp) { throw 'Microsoft-Graph-Service-Principal im Tenant nicht gefunden' }
    $map = @{}
    foreach ($r in @($sp.appRoles)) { if (@($r.allowedMemberTypes) -contains 'Application' -and $r.isEnabled -ne $false) { $map["$($r.value)"] = "$($r.id)" } }
    return [pscustomobject]@{ SpId = "$($sp.id)"; Roles = $map }
}

# Neues Zertifikat im Benutzerspeicher: nicht exportierbar, Software-KSP (CNG, noetig fuer PS256), RSA 3072
function New-HUTenantCertificate([string]$TenantId, [int]$Months = 12) {
    $short = if ($TenantId.Length -ge 8) { $TenantId.Substring(0, 8) } else { $TenantId }
    return (New-SelfSignedCertificate -CertStoreLocation 'Cert:\CurrentUser\My' -Subject "CN=HU-MultiTenant $short $env:COMPUTERNAME" `
            -KeyExportPolicy NonExportable -Provider 'Microsoft Software Key Storage Provider' -KeyAlgorithm RSA -KeyLength 3072 `
            -HashAlgorithm SHA256 -KeyUsage DigitalSignature -NotAfter (Get-Date).AddMonths($Months) -ErrorAction Stop)
}

# Zertifikat samt privatem Schluessel aus dem Benutzerspeicher loeschen
function Remove-HUCertLocal([string]$Thumbprint) {
    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { return $false }
    $p = "Cert:\CurrentUser\My\$Thumbprint"
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    Remove-Item -LiteralPath $p -DeleteKey -ErrorAction Stop
    return $true
}

# Token der App per Zertifikat (mit Warten auf Replikation), Rueckgabe: Payload des Tokens
function Get-HUAppTokenByCert($Cert, [string]$AppId, [string]$TenantId, [int]$MaxSeconds = 150) {
    $url = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $start = Get-Date; $i = 0
    while ($true) {
        $i++
        try {
            $a = New-HUClientAssertion -Certificate $Cert -Issuer $AppId -Audience $url
            $t = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop -Body @{
                client_id = $AppId; grant_type = 'client_credentials'; scope = 'https://graph.microsoft.com/.default'
                client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = $a }
            return [pscustomobject]@{ Token = $t.access_token; Payload = (ConvertFrom-HUJwtPayload $t.access_token) }
        } catch {
            $e = Get-HUSetupErrorText $_
            if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds -or $e -notmatch 'AADSTS700016|AADSTS7000215|AADSTS700027|AADSTS7000112|AADSTS70002') { throw "Anmeldung mit Zertifikat: $e" }
            Start-Sleep -Seconds ([Math]::Min(20, [Math]::Pow(2, $i)))
        }
    }
}

function New-HUTenantSetup {
    <#
    .SYNOPSIS
        Legt im Tenant die App-Registrierung "HU-MultiTenant" mit Zertifikat an und erteilt die gewaehlten Rechte.
    .DESCRIPTION
        Schritte: Zertifikat (lokal) -> App -> Service Principal -> Rechte (Admin-Zustimmung) -> Anmeldung per
        Zertifikat und Lesetest. Bei einem Fehler wird Angelegtes wieder entfernt (App, SP, Zertifikat).
        Rueckgabe: Tenant-Eintrag fuer settings.json (ohne Geheimnis).
    .PARAMETER OnStep
        Scriptblock (Text, Level) fuer die Fortschrittsanzeige.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Login,
        [Parameter(Mandatory)][string[]]$Permissions,
        [Parameter(Mandatory)][string]$Key,
        [string]$DisplayName = '',
        [int]$CertMonths = 12,
        [scriptblock]$OnStep = { param($t, $l) }
    )
    $tok = $Login.Token; $tid = $Login.Tid
    $made = [ordered]@{ Cert = $null; AppObjectId = ''; SpId = '' }
    try {
        & $OnStep 'Organisation lesen ...' 'Info'
        $org = Get-HUSetupOrganization $tok
        & $OnStep 'Rechte im Tenant nachschlagen ...' 'Info'
        $gm = Get-HUGraphRoleMap $tok
        $miss = @($Permissions | Where-Object { -not $gm.Roles.ContainsKey($_) })
        if ($miss.Count) { throw "Diese Rechte gibt es in Microsoft Graph nicht: $($miss -join ', ')" }
        & $OnStep 'Zertifikat auf diesem PC erzeugen (nicht exportierbar) ...' 'Info'
        $cert = New-HUTenantCertificate -TenantId $tid -Months $CertMonths
        $made.Cert = $cert
        & $OnStep "Zertifikat $($cert.Thumbprint.Substring(0, 8))... gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy'))" 'OK'
        & $OnStep 'App-Registrierung anlegen ...' 'Info'
        $who = if ($Login.Upn -match '^(.)[^@]*(@.+)$') { "$($Matches[1])***$($Matches[2])" } else { '' }
        $app = Invoke-HUSetupGraph -Token $tok -Method POST -Path '/applications' -Body @{
            displayName = 'HU-MultiTenant'; signInAudience = 'AzureADMyOrg'; tags = @($script:AppTag)
            notes = "Angelegt von HU-MultiTenant am $((Get-Date).ToString('yyyy-MM-dd')) auf $env:COMPUTERNAME$(if ($who) { " ($who)" }). Anmeldung nur per Zertifikat."
            keyCredentials = @(@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = [Convert]::ToBase64String($cert.RawData); displayName = "HU-MultiTenant $env:COMPUTERNAME" })
            requiredResourceAccess = @(@{ resourceAppId = $script:GraphAppId; resourceAccess = @($Permissions | ForEach-Object { @{ id = $gm.Roles[$_]; type = 'Role' } }) })
        }
        $made.AppObjectId = "$($app.id)"
        & $OnStep "App angelegt: $($app.appId)" 'OK'
        $sp = Invoke-HUSetupGraph -Token $tok -Method POST -Path '/servicePrincipals' -Body @{ appId = "$($app.appId)"; tags = @($script:AppTag, 'WindowsAzureActiveDirectoryIntegratedApp') } -Tries 8
        $made.SpId = "$($sp.id)"
        & $OnStep 'Service Principal angelegt' 'OK'
        & $OnStep "Rechte erteilen ($($Permissions.Count)) ..." 'Info'
        foreach ($p in $Permissions) {
            [void](Invoke-HUSetupGraph -Token $tok -Method POST -Path "/servicePrincipals/$($gm.SpId)/appRoleAssignedTo" -Tries 8 -Body @{ principalId = "$($sp.id)"; resourceId = $gm.SpId; appRoleId = $gm.Roles[$p] })
        }
        & $OnStep 'Rechte erteilt (Admin-Zustimmung)' 'OK'
        & $OnStep 'Anmeldung mit Zertifikat testen (Entra braucht dafuer bis zu 2 Minuten) ...' 'Info'
        $at = Get-HUAppTokenByCert -Cert $cert -AppId "$($app.appId)" -TenantId $tid
        if ("$($at.Payload.tid)" -ne $tid) { throw 'Token gehoert zu einem anderen Tenant - abgebrochen' }
        & $OnStep "Anmeldung mit Zertifikat OK$(if (@($at.Payload.roles).Count) { " ($(@($at.Payload.roles).Count) Rechte im Token)" } else { ' (Rechte erscheinen erst nach einigen Minuten im Token)' })" 'OK'
        return [pscustomobject][ordered]@{
            key = $Key; displayName = $(if ($DisplayName) { $DisplayName } else { $org.Name }); tenantId = $tid; appId = "$($app.appId)"; domain = $org.Domain
            auth = 'certificate'; certThumbprint = $cert.Thumbprint; appObjectId = "$($app.id)"; spId = "$($sp.id)"; credentialName = ''
        }
    } catch {
        $err = "$($_.Exception.Message)"
        & $OnStep "FEHLER: $err" 'Error'
        & $OnStep 'Raeume Angelegtes wieder auf ...' 'Warn'
        if ($made.SpId) { try { [void](Invoke-HUSetupGraph -Token $tok -Method DELETE -Path "/servicePrincipals/$($made.SpId)") } catch { & $OnStep "Service Principal nicht entfernt: $($_.Exception.Message)" 'Warn' } }
        if ($made.AppObjectId) {
            try { [void](Invoke-HUSetupGraph -Token $tok -Method DELETE -Path "/applications/$($made.AppObjectId)"); try { [void](Invoke-HUSetupGraph -Token $tok -Method DELETE -Path "/directory/deletedItems/$($made.AppObjectId)") } catch { } }
            catch { & $OnStep "App nicht entfernt (bitte im Portal loeschen): $($_.Exception.Message)" 'Warn' }
        }
        if ($made.Cert) { try { [void](Remove-HUCertLocal $made.Cert.Thumbprint) } catch { } }
        throw $err
    }
}

# ============================================================================
# Rechte erweitern (fehlende Anwendungsrechte erteilen)
# ============================================================================
function Get-HUAppGrantedRoles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$AppId)
    $sp = @((Invoke-HUSetupGraph -Token $Token -Path "/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId,displayName").value)[0]
    if (-not $sp) { throw "Service Principal der App $AppId nicht gefunden" }
    $asg = @((Invoke-HUSetupGraph -Token $Token -Path "/servicePrincipals/$($sp.id)/appRoleAssignments?`$top=999").value)
    return [pscustomobject]@{ SpId = "$($sp.id)"; Assignments = $asg }
}

function Add-HUAppPermissions {
    <#
    .SYNOPSIS
        Erteilt der HU-MultiTenant-App eines Tenants fehlende Anwendungsrechte (nur hinzufuegen, nie entfernen).
        Rueckgabe: Liste der neu erteilten Rechte.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Login, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string[]]$Permissions)
    $tok = $Login.Token
    $gm = Get-HUGraphRoleMap $tok
    $miss = @($Permissions | Where-Object { -not $gm.Roles.ContainsKey($_) })
    if ($miss.Count) { throw "Diese Rechte gibt es in Microsoft Graph nicht: $($miss -join ', ')" }
    $cur = Get-HUAppGrantedRoles -Token $tok -AppId $AppId
    $have = @($cur.Assignments | Where-Object { "$($_.resourceId)" -eq $gm.SpId } | ForEach-Object { "$($_.appRoleId)" })
    $added = @()
    foreach ($p in $Permissions) {
        $rid = $gm.Roles[$p]
        if ($have -contains $rid) { continue }
        [void](Invoke-HUSetupGraph -Token $tok -Method POST -Path "/servicePrincipals/$($gm.SpId)/appRoleAssignedTo" -Tries 4 -Body @{ principalId = $cur.SpId; resourceId = $gm.SpId; appRoleId = $rid })
        $added += $p
    }
    # Liste der angeforderten Rechte an der App nachziehen (Anzeige im Portal unter "API-Berechtigungen")
    if ($added.Count) {
        try {
            $app = Invoke-HUSetupGraph -Token $tok -Path "/applications(appId='$AppId')?`$select=id,requiredResourceAccess"
            $rra = @($app.requiredResourceAccess)
            $g = @($rra | Where-Object { "$($_.resourceAppId)" -eq $script:GraphAppId })[0]
            $acc = @(); if ($g) { $acc = @($g.resourceAccess | ForEach-Object { @{ id = "$($_.id)"; type = "$($_.type)" } }) }
            foreach ($p in $added) { $acc += @{ id = $gm.Roles[$p]; type = 'Role' } }
            $new = @($rra | Where-Object { "$($_.resourceAppId)" -ne $script:GraphAppId } | ForEach-Object { @{ resourceAppId = "$($_.resourceAppId)"; resourceAccess = @($_.resourceAccess | ForEach-Object { @{ id = "$($_.id)"; type = "$($_.type)" } }) } })
            $new += @{ resourceAppId = $script:GraphAppId; resourceAccess = $acc }
            [void](Invoke-HUSetupGraph -Token $tok -Method PATCH -Path "/applications/$($app.id)" -Body @{ requiredResourceAccess = @($new) })
        } catch { }
    }
    return $added
}

# ============================================================================
# Zertifikat erneuern
# ============================================================================
function Update-HUTenantCertificate {
    <#
    .SYNOPSIS
        Erneuert das Zertifikat eines Tenants ohne Admin: neues Zertifikat, addKey mit Nachweis (signiert vom alten),
        Test mit dem neuen, removeKey des alten, altes lokal loeschen. Rueckgabe: neuer Thumbprint.
    .DESCRIPTION
        Geht nur, solange das alte Zertifikat noch gueltig ist (sonst: Tenant neu einrichten / Zertifikat mit
        Admin-Anmeldung hinzufuegen). Quelle: learn.microsoft.com/graph/application-rollkey-prooftoken
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Tenant, [int]$Months = 12)
    $old = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($Tenant.certThumbprint)" -ErrorAction SilentlyContinue
    if (-not $old -or -not $old.HasPrivateKey) { throw 'Altes Zertifikat fehlt auf diesem PC' }
    if ($old.NotAfter -lt (Get-Date)) { throw 'Altes Zertifikat ist abgelaufen - bitte Tenant neu einrichten (Admin-Anmeldung)' }
    if ("$($Tenant.appObjectId)" -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Objekt-ID der App fehlt (appObjectId) - bitte Tenant neu einrichten' }
    $tid = "$($Tenant.tenantId)"; $appId = "$($Tenant.appId)"; $oid = "$($Tenant.appObjectId)"
    $tk = Get-HUAppTokenByCert -Cert $old -AppId $appId -TenantId $tid -MaxSeconds 10
    $new = New-HUTenantCertificate -TenantId $tid -Months $Months
    try {
        $proof = New-HUClientAssertion -Certificate $old -Issuer $oid -Audience '00000002-0000-0000-c000-000000000000' -Alg RS256
        $kc = Invoke-HUSetupGraph -Token $tk.Token -Method POST -Path "/applications/$oid/addKey" -Body @{
            keyCredential = @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = [Convert]::ToBase64String($new.RawData); displayName = "HU-MultiTenant $env:COMPUTERNAME" }
            passwordCredential = $null; proof = $proof }
        [void](Get-HUAppTokenByCert -Cert $new -AppId $appId -TenantId $tid)
    } catch {
        try { [void](Remove-HUCertLocal $new.Thumbprint) } catch { }
        throw "Erneuern fehlgeschlagen: $($_.Exception.Message)"
    }
    # altes Zertifikat an der App entfernen (Nachweis jetzt mit dem neuen) und lokal loeschen
    try {
        $app = Invoke-HUSetupGraph -Token $tk.Token -Path "/applications/$oid`?`$select=keyCredentials"
        $oldThumb = [Convert]::ToBase64String($old.GetCertHash())
        $k = @($app.keyCredentials | Where-Object { "$($_.customKeyIdentifier)" -eq $oldThumb })[0]
        if ($k) {
            $proof2 = New-HUClientAssertion -Certificate $new -Issuer $oid -Audience '00000002-0000-0000-c000-000000000000' -Alg RS256
            $tk2 = Get-HUAppTokenByCert -Cert $new -AppId $appId -TenantId $tid
            [void](Invoke-HUSetupGraph -Token $tk2.Token -Method POST -Path "/applications/$oid/removeKey" -Body @{ keyId = "$($k.keyId)"; proof = $proof2 })
        }
    } catch { Write-Warning "Altes Zertifikat an der App nicht entfernt: $($_.Exception.Message)" }
    try { [void](Remove-HUCertLocal $old.Thumbprint) } catch { }
    return $new.Thumbprint
}

Export-ModuleMember -Function @(
    'Remove-HUCertLocal',
    'ConvertFrom-HUJwtPayload', 'Get-HUSetupErrorText', 'Invoke-HUSetupGraph', 'Get-HUPermissionCatalog', 'Test-HUPermissionRisky',
    'Start-HUAdminLogin', 'Receive-HUAdminLogin', 'Stop-HUAdminLogin', 'Test-HUAdminCanGrant',
    'Get-HUSetupOrganization', 'Get-HUGraphRoleMap', 'New-HUTenantCertificate', 'Get-HUAppTokenByCert', 'New-HUTenantSetup',
    'Get-HUAppGrantedRoles', 'Add-HUAppPermissions', 'Update-HUTenantCertificate'
)
