#Requires -Version 5.1

<#
.SYNOPSIS
    HU.Auth - Authentifizierung & Credential Management für HU-MultiTenant.
.DESCRIPTION
    OAuth2 Client Credentials Flow gegen Microsoft Graph API.
    Credential-Speicherung: Windows Credential Manager (DPAPI) → DPAPI-File Fallback → RAM-Only.
    Token-Caching mit TTL (50 min Standard).
    Token werden NIEMALS in Logs geschrieben.
.NOTES
    Modul: HU.Auth.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
#>

# ============================================================================
# MODUL-VARIABLEN (Script-Scope)
# ============================================================================

# Token-Cache: Hashtable mit TenantKey als Key
$script:TokenCache = @{}

# Standard TTL in Sekunden (50 Minuten = 3000s, MS Token Lifetime ~60min)
$script:DefaultTokenTTL = 3000

# Max Retry bei 401
$script:MaxAuthRetries = 2

# OAuth2 Token-Endpoint Template
$script:TokenEndpointTemplate = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/token'

# Graph API Scope für Client Credentials
$script:GraphScope = 'https://graph.microsoft.com/.default'

# DPAPI Credential-Ordner
$script:CredentialBasePath = [System.IO.Path]::Combine($env:APPDATA, 'HU-MultiTenant')

# ============================================================================
# CREDENTIAL MANAGEMENT
# ============================================================================

function Get-StoredCredential {
    <#
    .SYNOPSIS
        Lädt gespeichertes Client Secret für einen Tenant.
    .DESCRIPTION
        Reihenfolge:
        1. DPAPI-verschlüsselte .cred Datei ($env:APPDATA\HU-MultiTenant\{CredName}.cred)
        2. Falls nicht vorhanden: $null (Caller muss Interactive Fallback handhaben)
    .PARAMETER TenantKey
        Tenant-Schlüssel aus settings.json (z.B. "Schule-1")
    .PARAMETER Settings
        Geladenes Settings-Objekt (enthält credentialName pro Tenant)
    .OUTPUTS
        [System.Security.SecureString] oder $null
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    process {
        $tenant = $Settings.tenants | Where-Object { $_.key -eq $TenantKey }
        if (-not $tenant) {
            Write-Warning "Tenant '$TenantKey' nicht in settings.json gefunden."
            return $null
        }

        $credName = $tenant.credentialName
        if ([string]::IsNullOrWhiteSpace($credName)) {
            $credName = "$($Settings.credentials.credentialNamePrefix)$TenantKey"
        }

        # Versuche DPAPI-File
        $credPath = [System.IO.Path]::Combine($script:CredentialBasePath, "$credName.cred")

        if (Test-Path -Path $credPath -PathType Leaf) {
            try {
                $cred = Import-Clixml -Path $credPath
                if ($cred -is [System.Management.Automation.PSCredential]) {
                    Write-Verbose "[Auth] Credential geladen aus DPAPI-File: $credName"
                    return $cred.Password
                }
            }
            catch {
                Write-Warning "[Auth] DPAPI-File beschädigt oder nicht lesbar: $credPath - $_"
            }
        }

        Write-Verbose "[Auth] Kein gespeichertes Credential für '$credName' gefunden."
        return $null
    }
}

function Save-StoredCredential {
    <#
    .SYNOPSIS
        Speichert Client Secret für einen Tenant als DPAPI-verschlüsselte Datei.
    .PARAMETER TenantKey
        Tenant-Schlüssel aus settings.json
    .PARAMETER SecretValue
        Client Secret als Klartext-String (wird sofort in SecureString konvertiert)
    .PARAMETER Settings
        Geladenes Settings-Objekt
    .OUTPUTS
        [bool] $true bei Erfolg
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SecretValue,

        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    process {
        $tenant = $Settings.tenants | Where-Object { $_.key -eq $TenantKey }
        if (-not $tenant) {
            Write-Warning "Tenant '$TenantKey' nicht in settings.json gefunden."
            return $false
        }

        $credName = $tenant.credentialName
        if ([string]::IsNullOrWhiteSpace($credName)) {
            $credName = "$($Settings.credentials.credentialNamePrefix)$TenantKey"
        }

        # Sicherstellen, dass Ordner existiert
        if (-not (Test-Path -Path $script:CredentialBasePath)) {
            New-Item -Path $script:CredentialBasePath -ItemType Directory -Force | Out-Null
        }

        $credPath = [System.IO.Path]::Combine($script:CredentialBasePath, "$credName.cred")

        try {
            $secureSecret = New-Object System.Security.SecureString
            foreach ($ch in $SecretValue.ToCharArray()) { $secureSecret.AppendChar($ch) }
            $secureSecret.MakeReadOnly()
            $cred = [System.Management.Automation.PSCredential]::new($credName, $secureSecret)
            $cred | Export-Clixml -Path $credPath -Force

            Write-Verbose "[Auth] Secret gespeichert: $credName → $credPath"
            return $true
        }
        catch {
            Write-Warning "[Auth] Fehler beim Speichern des Credentials: $_"
            return $false
        }
    }
}

function Remove-StoredCredential {
    <#
    .SYNOPSIS
        Löscht gespeichertes Credential für einen Tenant.
    .PARAMETER TenantKey
        Tenant-Schlüssel
    .PARAMETER Settings
        Settings-Objekt
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    process {
        $tenant = $Settings.tenants | Where-Object { $_.key -eq $TenantKey }
        if (-not $tenant) { return }

        $credName = $tenant.credentialName
        if ([string]::IsNullOrWhiteSpace($credName)) {
            $credName = "$($Settings.credentials.credentialNamePrefix)$TenantKey"
        }

        $credPath = [System.IO.Path]::Combine($script:CredentialBasePath, "$credName.cred")

        if ((Test-Path $credPath) -and $PSCmdlet.ShouldProcess($credPath, 'Credential löschen')) {
            Remove-Item -Path $credPath -Force
            Write-Verbose "[Auth] Credential gelöscht: $credName"
        }

        # Cache leeren
        if ($script:TokenCache.ContainsKey($TenantKey)) {
            $script:TokenCache.Remove($TenantKey)
        }
    }
}

# ============================================================================
# TOKEN MANAGEMENT
# ============================================================================

function Get-GraphToken {
    <#
    .SYNOPSIS
        Holt oder cached einen OAuth2 Access Token für den angegebenen Tenant.
    .DESCRIPTION
        1. Prüft ob gecachter Token noch gültig (TTL)
        2. Falls ja → return cached Token
        3. Falls nein → Client Credentials Flow gegen login.microsoftonline.com
        4. Bei 401 → Retry (max 2x)
    .PARAMETER TenantKey
        Tenant-Schlüssel
    .PARAMETER Settings
        Settings-Objekt
    .PARAMETER ForceRefresh
        Token-Cache ignorieren und neu anfordern
    .OUTPUTS
        [string] Access Token oder $null bei Fehler
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [PSCustomObject]$Settings,

        [switch]$ForceRefresh
    )

    process {
        # 1. Cache prüfen
        if (-not $ForceRefresh -and $script:TokenCache.ContainsKey($TenantKey)) {
            $cached = $script:TokenCache[$TenantKey]
            $elapsed = (Get-Date) - $cached.AcquiredAt
            $ttl = if ($Settings.credentials.tokenCacheTTL) { $Settings.credentials.tokenCacheTTL } else { $script:DefaultTokenTTL }

            if ($elapsed.TotalSeconds -lt $ttl) {
                Write-Verbose "[Auth] Token aus Cache für '$TenantKey' (verbleibend: $([math]::Round($ttl - $elapsed.TotalSeconds))s)"
                return $cached.AccessToken
            }
            Write-Verbose "[Auth] Token abgelaufen für '$TenantKey' - hole neuen..."
        }

        # 2. Tenant-Daten laden
        $tenant = $Settings.tenants | Where-Object { $_.key -eq $TenantKey }
        if (-not $tenant) {
            Write-Error "[Auth] Tenant '$TenantKey' nicht in settings.json gefunden."
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($tenant.tenantId) -or [string]::IsNullOrWhiteSpace($tenant.appId)) {
            Write-Error "[Auth] TenantId oder AppId fehlt für '$TenantKey'."
            return $null
        }

        # 3. Secret laden
        $secureSecret = Get-StoredCredential -TenantKey $TenantKey -Settings $Settings
        if (-not $secureSecret) {
            Write-Error "[Auth] Kein Secret für '$TenantKey' gefunden. Bitte über GUI eingeben."
            return $null
        }

        # SecureString → Klartext für HTTP Body
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
        try {
            $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        # 4. Token Request (Client Credentials Flow)
        $tokenUrl = $script:TokenEndpointTemplate -f $tenant.tenantId
        $body = @{
            grant_type    = 'client_credentials'
            client_id     = $tenant.appId
            client_secret = $plainSecret
            scope         = $script:GraphScope
        }

        # Klartext-Secret sofort nullen
        $plainSecret = $null

        $retryCount = 0
        $token = $null

        while ($retryCount -le $script:MaxAuthRetries) {
            try {
                $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                $token = $response.access_token

                if ([string]::IsNullOrWhiteSpace($token)) {
                    Write-Error "[Auth] Token-Response enthält keinen access_token."
                    return $null
                }

                # Cache aktualisieren
                $script:TokenCache[$TenantKey] = @{
                    AccessToken = $token
                    AcquiredAt  = Get-Date
                    ExpiresIn   = if ($response.expires_in) { $response.expires_in } else { 3600 }
                }

                $maskedToken = '[TOKEN_MASKED_' + $token.Substring([Math]::Max(0, $token.Length - 5)) + ']'
                Write-Verbose "[Auth] Token erhalten für '$TenantKey': $maskedToken"
                return $token
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }

                if ($statusCode -eq 401 -and $retryCount -lt $script:MaxAuthRetries) {
                    $retryCount++
                    Write-Warning "[Auth] 401 Unauthorized für '$TenantKey' - Retry $retryCount/$($script:MaxAuthRetries)..."
                    Start-Sleep -Seconds (1 * $retryCount)
                    continue
                }

                Write-Error "[Auth] Token-Anfrage fehlgeschlagen für '$TenantKey': $($_.Exception.Message)"
                return $null
            }
        }

        return $null
    }
}

function Invoke-TokenRefresh {
    <#
    .SYNOPSIS
        Erzwingt Token-Refresh für einen Tenant.
    .PARAMETER TenantKey
        Tenant-Schlüssel
    .PARAMETER Settings
        Settings-Objekt
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [PSCustomObject]$Settings
    )

    process {
        return Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ForceRefresh
    }
}

function Clear-TokenCache {
    <#
    .SYNOPSIS
        Leert den gesamten Token-Cache oder für einen spezifischen Tenant.
    .PARAMETER TenantKey
        Optional: Nur Cache für diesen Tenant leeren. Ohne Parameter: gesamter Cache.
    #>
    [CmdletBinding()]
    param(
        [string]$TenantKey
    )

    process {
        if ($TenantKey) {
            if ($script:TokenCache.ContainsKey($TenantKey)) {
                $script:TokenCache.Remove($TenantKey)
                Write-Verbose "[Auth] Token-Cache geleert für '$TenantKey'"
            }
        }
        else {
            $script:TokenCache.Clear()
            Write-Verbose "[Auth] Gesamter Token-Cache geleert"
        }
    }
}

function Test-TokenValid {
    <#
    .SYNOPSIS
        Prüft ob ein gecachter Token für den Tenant noch gültig ist.
    .PARAMETER TenantKey
        Tenant-Schlüssel
    .PARAMETER Settings
        Settings-Objekt
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [PSCustomObject]$Settings
    )

    process {
        if (-not $script:TokenCache.ContainsKey($TenantKey)) {
            return $false
        }

        $cached = $script:TokenCache[$TenantKey]
        $elapsed = (Get-Date) - $cached.AcquiredAt
        $ttl = $script:DefaultTokenTTL
        if ($Settings -and $Settings.credentials.tokenCacheTTL) {
            $ttl = $Settings.credentials.tokenCacheTTL
        }

        return ($elapsed.TotalSeconds -lt $ttl)
    }
}

# ============================================================================
# ADMIN CHECK
# ============================================================================

function Test-AdminPrivilege {
    <#
    .SYNOPSIS
        Prüft ob der aktuelle Prozess mit erhöhten Rechten läuft.
    .OUTPUTS
        [bool] $true wenn Admin
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    process {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]$identity
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch {
            return $false
        }
    }
}

# ============================================================================
# HILFSFUNKTIONEN
# ============================================================================

function Get-TokenMasked {
    <#
    .SYNOPSIS
        Maskiert einen Token für Log-Ausgabe.
    .PARAMETER Token
        Der zu maskierende Token-String
    .OUTPUTS
        [string] Maskierter Token
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    process {
        if ($Token.Length -le 5) {
            return '[TOKEN_MASKED_*****]'
        }
        return "[TOKEN_MASKED_$($Token.Substring($Token.Length - 5))]"
    }
}

# ============================================================================
# SECRET-ABLAUF (App-Registrierung)
# ============================================================================

function Select-AppSecretMatch {
    <#
    .SYNOPSIS
        Waehlt aus den passwordCredentials einer App das Secret, das HU-MultiTenant verwendet.
    .DESCRIPTION
        Graph liefert je Secret 'hint' = die ersten 3 Zeichen. Stimmt der Hint des gespeicherten Secrets
        mit genau einem Eintrag ueberein, ist das Ablaufdatum eindeutig (Matched = $true).
        Sonst: das naechste noch gueltige Ablaufdatum aller Secrets (Matched = $false).
    .OUTPUTS
        [PSCustomObject] EndDate (DateTime oder $null), Matched, DisplayName, Count
    #>
    [CmdletBinding()]
    param(
        [object[]]$PasswordCredentials,
        [string]$Hint
    )
    $creds = @($PasswordCredentials | Where-Object { $_ -and $_.PSObject.Properties['endDateTime'] -and $_.endDateTime })
    $parsed = @(foreach ($c in $creds) {
        $end = $null
        try { $end = ([datetime]::Parse("$($c.endDateTime)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).ToLocalTime() } catch { }
        if ($end) {
            [pscustomobject]@{
                End  = $end
                Hint = $(if ($c.PSObject.Properties['hint']) { "$($c.hint)" } else { '' })
                Name = $(if ($c.PSObject.Properties['displayName']) { "$($c.displayName)" } else { '' })
            }
        }
    })
    $res = [pscustomobject]@{ EndDate = $null; Matched = $false; DisplayName = ''; Count = $parsed.Count }
    if (-not $parsed.Count) { return $res }
    if ($Hint) {
        $m = @($parsed | Where-Object { $_.Hint -and $_.Hint -ceq $Hint })
        if ($m.Count -ge 1) {
            $pick = @($m | Sort-Object End -Descending)[0]
            $res.EndDate = $pick.End; $res.Matched = $true; $res.DisplayName = $pick.Name
            return $res
        }
    }
    $valid = @($parsed | Where-Object { $_.End -gt (Get-Date) } | Sort-Object End)
    $pick = if ($valid.Count) { $valid[0] } else { @($parsed | Sort-Object End -Descending)[0] }
    $res.EndDate = $pick.End; $res.DisplayName = $pick.Name
    return $res
}

function Get-AppSecretExpiry {
    <#
    .SYNOPSIS
        Liest das Ablaufdatum des Client Secrets der eigenen App-Registrierung (Graph).
    .DESCRIPTION
        GET /applications(appId='...')?$select=displayName,passwordCredentials
        Benoetigt die Application-Berechtigung Application.Read.All (sonst Status 'NoPermission').
        Das verwendete Secret wird ueber die ersten 3 Zeichen (hint) erkannt.
    .OUTPUTS
        [PSCustomObject] Status (OK | NoPermission | Error), EndDate, Matched, DisplayName, Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantKey,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][string]$Token
    )
    $out = [pscustomobject]@{ Status = 'Error'; EndDate = $null; Matched = $false; DisplayName = ''; Error = '' }
    $tenant = $Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    if (-not $tenant -or -not "$($tenant.appId)") { $out.Error = 'AppId fehlt'; return $out }

    $hint = ''
    $sec = Get-StoredCredential -TenantKey $TenantKey -Settings $Settings
    if ($sec) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr); if ($plain.Length -ge 3) { $hint = $plain.Substring(0, 3) } }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $plain = $null }
    }

    $uri = "https://graph.microsoft.com/v1.0/applications(appId='$($tenant.appId)')?`$select=displayName,passwordCredentials"
    try {
        $app = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -Method Get -TimeoutSec 20 -ErrorAction Stop
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 403) { $out.Status = 'NoPermission'; $out.Error = 'Application.Read.All fehlt' }
        else { $out.Error = $(if ($code) { "HTTP $code" } else { $_.Exception.Message }) }
        return $out
    }
    $m = Select-AppSecretMatch -PasswordCredentials @($app.passwordCredentials) -Hint $hint
    $out.Status = 'OK'
    $out.EndDate = $m.EndDate
    $out.Matched = $m.Matched
    $out.DisplayName = "$($app.displayName)"
    if (-not $m.EndDate) { $out.Error = 'keine Secrets an der App gefunden' }
    return $out
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function @(
    'Get-StoredCredential'
    'Save-StoredCredential'
    'Remove-StoredCredential'
    'Get-GraphToken'
    'Invoke-TokenRefresh'
    'Clear-TokenCache'
    'Test-TokenValid'
    'Test-AdminPrivilege'
    'Get-TokenMasked'
    'Select-AppSecretMatch'
    'Get-AppSecretExpiry'
)
