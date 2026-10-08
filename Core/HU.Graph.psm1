#Requires -Version 5.1

<#
.SYNOPSIS
    HU.Graph - Graph API Wrapper für HU-MultiTenant.
.DESCRIPTION
    Zentraler Wrapper für Microsoft Graph API Aufrufe.
    - Invoke-GraphRequest: Einzelner Request
    - Invoke-GraphRequestWithRetry: Mit Retry-Logic (429/401/5xx)
    - Pagination: Automatisches Handling von @odata.nextLink
    - Convenience-Funktionen: Get-ManagedDevices, Get-DeviceComplianceStatus, Get-MalwareAlerts
.NOTES
    Modul: HU.Graph.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
#>

# ============================================================================
# MODUL-VARIABLEN
# ============================================================================

# Graph API Base URL
$script:GraphBaseUrl = 'https://graph.microsoft.com'

# API Version (v1.0 oder beta)
$script:ApiVersion = 'v1.0'

# Default Retry-Einstellungen
$script:DefaultMaxRetries = 3
$script:DefaultBackoffMs = @(1000, 2000, 4000)  # Exponential Backoff

# HTTP Status Codes die retried werden
$script:RetryableStatusCodes = @(429, 500, 502, 503, 504)

# ============================================================================
# CORE REQUEST FUNKTIONEN
# ============================================================================

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Führt einen einzelnen Graph API Request aus (ohne Retry).
    .PARAMETER Token
        Bearer Access Token
    .PARAMETER Endpoint
        API Endpoint relativ zu /v1.0 (z.B. "/deviceManagement/managedDevices")
    .PARAMETER Method
        HTTP Method: GET, POST, PATCH, DELETE
    .PARAMETER Body
        Request Body als Hashtable (wird zu JSON konvertiert)
    .PARAMETER ApiVersion
        API Version override (default: v1.0)
    .PARAMETER ContentType
        Content-Type Header (default: application/json)
    .OUTPUTS
        [PSCustomObject] API Response oder $null bei Fehler
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$Body,

        [string]$ApiVersion,

        [string]$ContentType = 'application/json'
    )

    process {
        # URI aufbauen
        $version = if ($ApiVersion) { $ApiVersion } else { $script:ApiVersion }
        $uri = if ($Endpoint.StartsWith('https://')) {
            $Endpoint  # Absolute URL (z.B. nextLink)
        }
        else {
            $cleanEndpoint = $Endpoint.TrimStart('/')
            "$($script:GraphBaseUrl)/$version/$cleanEndpoint"
        }

        # Headers
        $headers = @{
            Authorization  = "Bearer $Token"
            'Content-Type' = $ContentType
            Accept         = 'application/json'
        }

        # Request-Parameter
        $params = @{
            Uri         = $uri
            Headers     = $headers
            Method      = $Method
            ErrorAction = 'Stop'
        }

        # Body hinzufügen (nur bei POST/PATCH)
        if ($Body -and $Method -in @('POST', 'PATCH')) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }

        try {
            $response = Invoke-RestMethod @params
            return $response
        }
        catch {
            $statusCode = $null
            $errorDetail = $_.Exception.Message

            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode

                # Response Body lesen für detaillierte Fehlermeldung
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        $errorBody = $reader.ReadToEnd()
                        $reader.Close()

                        $errorJson = $errorBody | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($errorJson.error.message) {
                            $errorDetail = "$statusCode - $($errorJson.error.code): $($errorJson.error.message)"
                        }
                    }
                }
                catch { }
            }

            # Error-Objekt zurückgeben statt Exception werfen (Caller entscheidet)
            $errorResult = [PSCustomObject]@{
                IsError      = $true
                StatusCode   = $statusCode
                ErrorMessage = $errorDetail
                Endpoint     = $Endpoint
                Method       = $Method
            }

            Write-Verbose "[Graph] Fehler: $errorDetail"
            return $errorResult
        }
    }
}

function Invoke-GraphRequestWithRetry {
    <#
    .SYNOPSIS
        Graph API Request mit automatischer Retry-Logic.
    .DESCRIPTION
        Retry-Verhalten:
        - 429 (Throttled): Wartet Retry-After Header ab, dann Retry
        - 401 (Unauthorized): Token-Refresh via HU.Auth, dann 1x Retry
        - 5xx (Server-Error): Exponential Backoff, max 3 Retries
        - 403 (Forbidden): KEIN Retry (Permissions-Problem)
    .PARAMETER Token
        Bearer Access Token
    .PARAMETER Endpoint
        API Endpoint
    .PARAMETER Method
        HTTP Method
    .PARAMETER Body
        Request Body
    .PARAMETER TenantKey
        Tenant-Key für Token-Refresh bei 401
    .PARAMETER Settings
        Settings-Objekt für Token-Refresh
    .PARAMETER MaxRetries
        Max Retries (default: 3)
    .PARAMETER ApiVersion
        API Version override
    .OUTPUTS
        [PSCustomObject] API Response
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$Body,

        [string]$TenantKey,

        [PSCustomObject]$Settings,

        [int]$MaxRetries,

        [string]$ApiVersion
    )

    process {
        if (-not $MaxRetries) { $MaxRetries = $script:DefaultMaxRetries }

        $currentToken = $Token
        $retryCount = 0

        while ($retryCount -le $MaxRetries) {
            $requestParams = @{
                Token    = $currentToken
                Endpoint = $Endpoint
                Method   = $Method
            }
            if ($Body) { $requestParams.Body = $Body }
            if ($ApiVersion) { $requestParams.ApiVersion = $ApiVersion }

            $response = Invoke-GraphRequest @requestParams

            # Erfolg → kein IsError Property oder IsError = $false
            if (-not ($response.PSObject.Properties.Name -contains 'IsError') -or -not $response.IsError) {
                return $response
            }

            # Fehlerbehandlung
            $statusCode = $response.StatusCode

            # 403 → Permissions-Problem, kein Retry
            if ($statusCode -eq 403) {
                Write-Warning "[Graph] 403 Forbidden für $Endpoint - Permissions prüfen. Kein Retry."
                return $response
            }

            # 401 → Token-Refresh versuchen (1x)
            if ($statusCode -eq 401 -and $retryCount -eq 0 -and $TenantKey -and $Settings) {
                Write-Warning "[Graph] 401 für $Endpoint - versuche Token-Refresh..."
                $newToken = Invoke-TokenRefresh -TenantKey $TenantKey -Settings $Settings
                if ($newToken) {
                    $currentToken = $newToken
                    $retryCount++
                    continue
                }
                else {
                    Write-Warning "[Graph] Token-Refresh fehlgeschlagen."
                    return $response
                }
            }

            # 429 → Throttled, Retry-After beachten
            if ($statusCode -eq 429) {
                $retryAfter = 5  # Default 5 Sekunden
                # Retry-After Header ist im ErrorMessage nicht direkt verfügbar,
                # aber wir können es aus der Exception extrahieren falls möglich
                Write-Warning "[Graph] 429 Throttled für $Endpoint - warte ${retryAfter}s... (Retry $($retryCount + 1)/$MaxRetries)"
                Start-Sleep -Seconds $retryAfter
                $retryCount++
                continue
            }

            # 5xx → Exponential Backoff
            if ($statusCode -ge 500) {
                $backoffIndex = [Math]::Min($retryCount, $script:DefaultBackoffMs.Count - 1)
                $waitMs = $script:DefaultBackoffMs[$backoffIndex]
                Write-Warning "[Graph] $statusCode Server-Error für $Endpoint - warte ${waitMs}ms... (Retry $($retryCount + 1)/$MaxRetries)"
                Start-Sleep -Milliseconds $waitMs
                $retryCount++
                continue
            }

            # Alle anderen Fehler → kein Retry
            Write-Warning "[Graph] Fehler $statusCode für $Endpoint - kein Retry."
            return $response
        }

        Write-Warning "[Graph] Max Retries ($MaxRetries) erreicht für $Endpoint."
        return $response
    }
}

# ============================================================================
# PAGINATION
# ============================================================================

function Invoke-GraphRequestAll {
    <#
    .SYNOPSIS
        Graph API Request mit automatischer Pagination (@odata.nextLink).
    .DESCRIPTION
        Sammelt alle Seiten und gibt die kombinierte .value Collection zurück.
        Nutzt intern Invoke-GraphRequestWithRetry.
    .PARAMETER Token
        Bearer Access Token
    .PARAMETER Endpoint
        API Endpoint (erster Request)
    .PARAMETER TenantKey
        Für Token-Refresh
    .PARAMETER Settings
        Für Token-Refresh
    .PARAMETER MaxPages
        Safety-Limit: Maximale Anzahl Pages (default: 100)
    .OUTPUTS
        [PSCustomObject[]] Alle Ergebnisse aus .value
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [string]$TenantKey,
        [PSCustomObject]$Settings,

        [int]$MaxPages = 100
    )

    process {
        $allResults = [System.Collections.ArrayList]::new()
        $currentEndpoint = $Endpoint
        $pageCount = 0

        while ($currentEndpoint -and $pageCount -lt $MaxPages) {
            $pageCount++
            Write-Verbose "[Graph] Page ${pageCount}: ${currentEndpoint}"

            $requestParams = @{
                Token    = $Token
                Endpoint = $currentEndpoint
                Method   = 'GET'
            }
            if ($TenantKey) { $requestParams.TenantKey = $TenantKey }
            if ($Settings) { $requestParams.Settings = $Settings }

            $response = Invoke-GraphRequestWithRetry @requestParams

            # Fehler-Check
            if ($response.PSObject.Properties.Name -contains 'IsError' -and $response.IsError) {
                Write-Warning "[Graph] Pagination abgebrochen bei Page ${pageCount}: $($response.ErrorMessage)"
                break
            }

            # Ergebnisse sammeln
            if ($response.value) {
                foreach ($item in $response.value) {
                    [void]$allResults.Add($item)
                }
            }
            elseif ($response -and -not $response.PSObject.Properties.Name -contains '@odata.nextLink') {
                # Single-Object Response (kein value Array)
                [void]$allResults.Add($response)
            }

            # Nächste Seite
            $nextLink = $response.'@odata.nextLink'
            if ($nextLink) {
                $currentEndpoint = $nextLink  # Absolute URL
            }
            else {
                $currentEndpoint = $null
            }
        }

        if ($pageCount -ge $MaxPages) {
            Write-Warning "[Graph] MaxPages ($MaxPages) erreicht - möglicherweise unvollständig."
        }

        Write-Verbose "[Graph] Pagination fertig: $($allResults.Count) Ergebnisse in $pageCount Page(s)."
        return @($allResults)
    }
}

# ============================================================================
# CONVENIENCE-FUNKTIONEN (Intune / Device Management)
# ============================================================================

function Get-ManagedDevices {
    <#
    .SYNOPSIS
        Holt alle Intune Managed Devices für einen Tenant.
    .PARAMETER Token
        Access Token
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .PARAMETER Select
        Optional: $select Parameter für Graph API
    .OUTPUTS
        [PSCustomObject] @{ Count; Devices }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [string]$TenantKey,
        [PSCustomObject]$Settings,

        [string[]]$Select
    )

    process {
        $endpoint = '/deviceManagement/managedDevices?$top=999'

        if ($Select -and $Select.Count -gt 0) {
            $selectStr = $Select -join ','
            $endpoint += "&`$select=$selectStr"
        }

        $devices = Invoke-GraphRequestAll -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings

        return [PSCustomObject]@{
            Count   = $devices.Count
            Devices = $devices
        }
    }
}

function Get-DeviceComplianceStatus {
    <#
    .SYNOPSIS
        Holt den Compliance-Status eines einzelnen Devices.
    .PARAMETER Token
        Access Token
    .PARAMETER DeviceId
        Intune Device ID
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .OUTPUTS
        [PSCustomObject[]] Compliance-Status Einträge
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$DeviceId,

        [string]$TenantKey,
        [PSCustomObject]$Settings
    )

    process {
        $endpoint = "/deviceManagement/managedDevices/$DeviceId/deviceCompliancePolicyStates"

        $result = Invoke-GraphRequestWithRetry -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings

        if ($result.PSObject.Properties.Name -contains 'IsError' -and $result.IsError) {
            return @()
        }

        if ($result.value) {
            return @($result.value)
        }

        return @()
    }
}

function Get-CompliancePolicies {
    <#
    .SYNOPSIS
        Holt alle Compliance Policies des Tenants.
    .PARAMETER Token
        Access Token
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .OUTPUTS
        [PSCustomObject[]] Compliance Policies
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [string]$TenantKey,
        [PSCustomObject]$Settings
    )

    process {
        $endpoint = '/deviceManagement/deviceCompliancePolicies'
        return Invoke-GraphRequestAll -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings
    }
}

function Get-CompliancePolicyDeviceStatuses {
    <#
    .SYNOPSIS
        Holt Device-Statuses für eine bestimmte Compliance Policy.
    .PARAMETER Token
        Access Token
    .PARAMETER PolicyId
        Compliance Policy ID
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .OUTPUTS
        [PSCustomObject[]] Device Status Einträge
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$PolicyId,

        [string]$TenantKey,
        [PSCustomObject]$Settings
    )

    process {
        $endpoint = "/deviceManagement/deviceCompliancePolicies/$PolicyId/deviceStatuses"
        return Invoke-GraphRequestAll -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings
    }
}

function Get-MalwareAlerts {
    <#
    .SYNOPSIS
        Holt Security Alerts (Malware/Threats) vom Tenant.
    .PARAMETER Token
        Access Token
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .PARAMETER SeverityFilter
        Optional: Filter nach Severity (critical, high, medium, low)
    .OUTPUTS
        [PSCustomObject[]] Security Alerts
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [string]$TenantKey,
        [PSCustomObject]$Settings,

        [ValidateSet('critical', 'high', 'medium', 'low', '')]
        [string]$SeverityFilter
    )

    process {
        $endpoint = '/security/alerts_v2?$top=999'

        if ($SeverityFilter) {
            $endpoint += "&`$filter=severity eq '$SeverityFilter'"
        }

        return Invoke-GraphRequestAll -Token $Token -Endpoint $endpoint -TenantKey $TenantKey -Settings $Settings
    }
}

function Invoke-DeviceSync {
    <#
    .SYNOPSIS
        Sendet Sync-Befehl an ein einzelnes Managed Device.
    .PARAMETER Token
        Access Token
    .PARAMETER DeviceId
        Intune Device ID
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Settings
        Settings-Objekt
    .OUTPUTS
        [PSCustomObject] @{ Success; DeviceId; ErrorMessage }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$DeviceId,

        [string]$TenantKey,
        [PSCustomObject]$Settings
    )

    process {
        $endpoint = "/deviceManagement/managedDevices/$DeviceId/syncDevice"

        $response = Invoke-GraphRequestWithRetry -Token $Token -Endpoint $endpoint -Method 'POST' -TenantKey $TenantKey -Settings $Settings

        $isError = $response.PSObject.Properties.Name -contains 'IsError' -and $response.IsError

        return [PSCustomObject]@{
            Success      = -not $isError
            DeviceId     = $DeviceId
            ErrorMessage = if ($isError) { $response.ErrorMessage } else { '' }
        }
    }
}

function Test-GraphPermission {
    <#
    .SYNOPSIS
        Testet ob der Token eine bestimmte Permission hat.
    .DESCRIPTION
        Dekodiert das JWT und prüft den roles/scp Claim.
    .PARAMETER Token
        Access Token
    .PARAMETER Permission
        Zu prüfende Permission (z.B. "DeviceManagementManagedDevices.Read.All")
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$Permission
    )

    process {
        try {
            # JWT Payload dekodieren (Teil 2, Base64)
            $parts = $Token.Split('.')
            if ($parts.Count -lt 2) { return $false }

            $payload = $parts[1]
            # Base64 Padding
            $padding = 4 - ($payload.Length % 4)
            if ($padding -lt 4) { $payload += ('=' * $padding) }
            $payload = $payload.Replace('-', '+').Replace('_', '/')

            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
            $claims = $decoded | ConvertFrom-Json

            # Application Permissions = roles Claim
            if ($claims.roles) {
                return ($claims.roles -contains $Permission)
            }

            # Delegated Permissions = scp Claim
            if ($claims.scp) {
                $scopes = $claims.scp -split ' '
                return ($scopes -contains $Permission)
            }

            return $false
        }
        catch {
            Write-Verbose "[Graph] JWT-Dekodierung fehlgeschlagen: $_"
            return $false
        }
    }
}

function Get-TokenPermissions {
    <#
    .SYNOPSIS
        Gibt alle Permissions (Roles/Scopes) des Tokens zurück.
    .PARAMETER Token
        Access Token
    .OUTPUTS
        [string[]] Liste der Permissions
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    process {
        try {
            $parts = $Token.Split('.')
            if ($parts.Count -lt 2) { return @() }

            $payload = $parts[1]
            $padding = 4 - ($payload.Length % 4)
            if ($padding -lt 4) { $payload += ('=' * $padding) }
            $payload = $payload.Replace('-', '+').Replace('_', '/')

            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
            $claims = $decoded | ConvertFrom-Json

            $allPerms = [System.Collections.ArrayList]::new()

            # Application Permissions = roles Claim (Client Credentials Flow)
            if ($claims.roles -and @($claims.roles).Count -gt 0) {
                foreach ($r in @($claims.roles)) {
                    [void]$allPerms.Add($r)
                }
            }

            # Delegated Permissions = scp Claim (Auth Code Flow)
            if ($claims.scp) {
                foreach ($s in @($claims.scp -split ' ')) {
                    if ($s -and -not $allPerms.Contains($s)) {
                        [void]$allPerms.Add($s)
                    }
                }
            }

            return @($allPerms)
        }
        catch {
            return @()
        }
    }
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

function Invoke-GraphBatchGet {
    <#
    .SYNOPSIS
        Viele GET-Abfragen gebuendelt ueber Graph JSON-Batching (je 20 pro Anfrage).
    .DESCRIPTION
        Liefert eine Hashtable Schluessel -> Antwort-Body (nur Status 200). 429/5xx werden mit Wartezeit
        (Retry-After) bis zu 4-mal wiederholt. Quelle: learn.microsoft.com/graph/json-batching
    .PARAMETER Token
        Access Token
    .PARAMETER Requests
        Hashtable Schluessel -> relative URL (z. B. '/deviceManagement/managedDevices/<id>/windowsProtectionState')
    .PARAMETER OnProgress
        Optional: Scriptblock, wird nach jedem Paket mit (erledigt, gesamt) aufgerufen
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][hashtable]$Requests,
        [scriptblock]$OnProgress
    )
    $result = @{}
    $keys = @($Requests.Keys)
    for ($i = 0; $i -lt $keys.Count; $i += 20) {
        $pending = @($keys[$i..([Math]::Min($i + 19, $keys.Count - 1))])
        for ($try = 1; $try -le 4 -and $pending.Count; $try++) {
            $reqs = @(for ($j = 0; $j -lt $pending.Count; $j++) { @{ id = "$j"; method = 'GET'; url = "$($Requests[$pending[$j]])" } })
            $retry = @(); $wait = 0
            try {
                $resp = Invoke-GraphRequest -Token $Token -Endpoint '/$batch' -Method POST -Body @{ requests = $reqs }
                foreach ($r in @($resp.responses)) {
                    $k = $pending[[int]$r.id]
                    if ([int]$r.status -eq 200) { $result[$k] = $r.body }
                    elseif ([int]$r.status -eq 429 -or [int]$r.status -ge 500) {
                        $retry += $k
                        $ra = 0; try { $ra = [int]$r.headers.'Retry-After' } catch { }
                        $wait = [Math]::Max($wait, [Math]::Max($ra, 2))
                    }
                }
            } catch {
                Write-Verbose "Graph-Batch fehlgeschlagen: $($_.Exception.Message)"
                $retry = $pending; $wait = 5
            }
            $pending = $retry
            if ($pending.Count -and $try -lt 4) { Start-Sleep -Seconds ([Math]::Min($wait, 30)) }
        }
        if ($OnProgress) { try { & $OnProgress ([Math]::Min($i + 20, $keys.Count)) $keys.Count } catch { } }
    }
    return $result
}

Export-ModuleMember -Function @(
    'Invoke-GraphRequest'
    'Invoke-GraphRequestWithRetry'
    'Invoke-GraphRequestAll'
    'Invoke-GraphBatchGet'
    'Get-ManagedDevices'
    'Get-DeviceComplianceStatus'
    'Get-CompliancePolicies'
    'Get-CompliancePolicyDeviceStatuses'
    'Get-MalwareAlerts'
    'Invoke-DeviceSync'
    'Test-GraphPermission'
    'Get-TokenPermissions'
)