#Requires -Version 5.1

<#
.SYNOPSIS
    HU.Tenant - Tenant Management für HU-MultiTenant.
.DESCRIPTION
    Laden/Verwalten der Tenant-Konfiguration aus settings.json.
    Aktueller Tenant (Session-State), Connection-Test via Graph API.
.NOTES
    Modul: HU.Tenant.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
#>

# ============================================================================
# MODUL-VARIABLEN
# ============================================================================

# Geladene Settings (PSCustomObject aus settings.json)
$script:Settings = $null

# Pfad zur settings.json
$script:SettingsPath = $null

# Aktuell ausgewählter Tenant (Key)
$script:CurrentTenantKey = $null

# Tenant-Status Cache: @{ "Schule-1" = @{ isConnected=$true; lastChecked=...; errorMessage="" } }
$script:TenantStatus = @{}

# ============================================================================
# SETTINGS LADEN
# ============================================================================

function Import-TenantSettings {
    <#
    .SYNOPSIS
        Lädt settings.json und initialisiert den Tenant-Manager.
    .PARAMETER SettingsPath
        Pfad zur settings.json. Standard: ./Config/settings.json relativ zum Skript-Root.
    .OUTPUTS
        [PSCustomObject] Settings-Objekt
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Position = 0)]
        [string]$SettingsPath
    )

    process {
        if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
            # Standard: relativ zum Modul-Verzeichnis → ../Config/settings.json
            $moduleDir = Split-Path -Parent $PSScriptRoot
            $SettingsPath = Join-Path $moduleDir 'Config\settings.json'
        }

        if (-not (Test-Path $SettingsPath)) {
            Write-Error "[Tenant] settings.json nicht gefunden: $SettingsPath"
            return $null
        }

        try {
            $json = Get-Content -Path $SettingsPath -Raw -Encoding UTF8 -ErrorAction Stop
            $script:Settings = $json | ConvertFrom-Json
            $script:SettingsPath = $SettingsPath

            # Primary Tenant als Default setzen
            $primary = $script:Settings.tenants | Where-Object { $_.isPrimary -eq $true } | Select-Object -First 1
            if ($primary) {
                $script:CurrentTenantKey = $primary.key
            }
            elseif ($script:Settings.tenants.Count -gt 0) {
                $script:CurrentTenantKey = $script:Settings.tenants[0].key
            }

            # Status-Cache initialisieren
            foreach ($t in $script:Settings.tenants) {
                $script:TenantStatus[$t.key] = @{
                    isConnected  = $false
                    lastChecked  = $null
                    errorMessage = ''
                    permissionsOk = $null
                }
            }

            Write-Verbose "[Tenant] Settings geladen: $($script:Settings.tenants.Count) Tenant(s), Primary: $($script:CurrentTenantKey)"
            return $script:Settings
        }
        catch {
            Write-Error "[Tenant] Fehler beim Laden der settings.json: $_"
            return $null
        }
    }
}

# ============================================================================
# TENANT ABFRAGEN
# ============================================================================

function Get-AllTenants {
    <#
    .SYNOPSIS
        Gibt alle konfigurierten Tenants zurück.
    .OUTPUTS
        [PSCustomObject[]] Array mit Tenant-Objekten (key, displayName, tenantId, domain, isConnected, statusIcon)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    process {
        if (-not $script:Settings) {
            Write-Warning "[Tenant] Settings nicht geladen. Zuerst Import-TenantSettings aufrufen."
            return @()
        }

        $result = foreach ($t in $script:Settings.tenants) {
            $status = $script:TenantStatus[$t.key]
            # Unicode escapes - avoids encoding issues with literal emojis in PS 5.1
            $iconWhite  = [char]::ConvertFromUtf32(0x26AA)  # ⚪
            $iconGreen  = [char]::ConvertFromUtf32(0x1F7E2) # 🟢
            $iconYellow = [char]::ConvertFromUtf32(0x1F7E1) # 🟡
            $iconRed    = [char]::ConvertFromUtf32(0x1F534) # 🔴

            $icon = if ($null -eq $status -or $null -eq $status.isConnected) {
                $iconWhite   # Unbekannt
            }
            elseif ($status.isConnected -and $status.permissionsOk -ne $false) {
                $iconGreen   # Connected
            }
            elseif ($status.permissionsOk -eq $false) {
                $iconYellow  # Permissions-Problem
            }
            else {
                $iconRed     # Disconnected
            }

            [PSCustomObject]@{
                Key          = $t.key
                DisplayName  = $t.displayName
                TenantId     = $t.tenantId
                AppId        = $t.appId
                Domain       = $t.domain
                CredentialName = $t.credentialName
                IsPrimary    = $t.isPrimary
                Tags         = $t.tags
                Notes        = $t.notes
                IsConnected  = if ($status) { $status.isConnected } else { $false }
                StatusIcon   = $icon
                LastChecked  = if ($status) { $status.lastChecked } else { $null }
            }
        }

        return @($result)
    }
}

function Get-TenantByKey {
    <#
    .SYNOPSIS
        Gibt einen einzelnen Tenant nach Key zurück.
    .PARAMETER TenantKey
        z.B. "Schule-1"
    .OUTPUTS
        [PSCustomObject] Tenant-Objekt oder $null
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey
    )

    process {
        $all = Get-AllTenants
        return $all | Where-Object { $_.Key -eq $TenantKey } | Select-Object -First 1
    }
}

function Get-CurrentTenant {
    <#
    .SYNOPSIS
        Gibt den aktuell ausgewählten Tenant zurück.
    .OUTPUTS
        [PSCustomObject] Aktueller Tenant
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        if (-not $script:CurrentTenantKey) {
            Write-Warning "[Tenant] Kein Tenant ausgewählt."
            return $null
        }
        return Get-TenantByKey -TenantKey $script:CurrentTenantKey
    }
}

function Get-CurrentTenantKey {
    <#
    .SYNOPSIS
        Gibt nur den Key des aktuellen Tenants zurück.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    process {
        return $script:CurrentTenantKey
    }
}

function Set-CurrentTenant {
    <#
    .SYNOPSIS
        Setzt den aktuell ausgewählten Tenant.
    .PARAMETER TenantKey
        Tenant-Key
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantKey
    )

    process {
        $tenant = $script:Settings.tenants | Where-Object { $_.key -eq $TenantKey }
        if (-not $tenant) {
            Write-Error "[Tenant] Tenant '$TenantKey' existiert nicht in settings.json."
            return
        }

        $script:CurrentTenantKey = $TenantKey
        Write-Verbose "[Tenant] Aktueller Tenant gesetzt: $TenantKey"
    }
}

# ============================================================================
# CONNECTION TEST
# ============================================================================

function Test-TenantConnection {
    <#
    .SYNOPSIS
        Testet die Verbindung zu einem Tenant via Graph API.
    .DESCRIPTION
        Holt Token via HU.Auth, testet GET /organization.
        Aktualisiert TenantStatus-Cache.
    .PARAMETER TenantKey
        Tenant-Key
    .PARAMETER Token
        Bereits vorhandener Token (optional – wird sonst über Get-GraphToken geholt)
    .OUTPUTS
        [PSCustomObject] @{ IsConnected; ErrorMessage; TenantKey }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [string]$Token
    )

    process {
        $result = [PSCustomObject]@{
            TenantKey    = $TenantKey
            IsConnected  = $false
            ErrorMessage = ''
        }

        # Token holen falls nicht übergeben
        if ([string]::IsNullOrWhiteSpace($Token)) {
            if (-not $script:Settings) {
                $result.ErrorMessage = 'Settings nicht geladen'
                Update-TenantStatusCache -TenantKey $TenantKey -Connected $false -Error $result.ErrorMessage
                return $result
            }

            $Token = Get-GraphToken -TenantKey $TenantKey -Settings $script:Settings
            if (-not $Token) {
                $result.ErrorMessage = 'Token konnte nicht abgerufen werden. Secret prüfen.'
                Update-TenantStatusCache -TenantKey $TenantKey -Connected $false -Error $result.ErrorMessage
                return $result
            }
        }

        # Test-Request: GET /organization (minimal, funktioniert mit fast allen Permissions)
        $uri = 'https://graph.microsoft.com/v1.0/organization'
        $headers = @{ Authorization = "Bearer $Token" }

        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop

            $result.IsConnected = $true
            Update-TenantStatusCache -TenantKey $TenantKey -Connected $true

            Write-Verbose "[Tenant] Connection OK für '$TenantKey'"
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 403) {
                $result.ErrorMessage = "403 Forbidden - Permissions fehlen"
                Update-TenantStatusCache -TenantKey $TenantKey -Connected $false -Error $result.ErrorMessage -PermissionsOk $false
            }
            elseif ($statusCode -eq 401) {
                $result.ErrorMessage = "401 Unauthorized - Token/Secret ungültig"
                Update-TenantStatusCache -TenantKey $TenantKey -Connected $false -Error $result.ErrorMessage
            }
            else {
                $result.ErrorMessage = "Verbindungsfehler: $($_.Exception.Message)"
                Update-TenantStatusCache -TenantKey $TenantKey -Connected $false -Error $result.ErrorMessage
            }
        }

        return $result
    }
}

function Get-TenantStatus {
    <#
    .SYNOPSIS
        Gibt den gecachten Status eines Tenants zurück.
    .PARAMETER TenantKey
        Tenant-Key
    .OUTPUTS
        [hashtable] Status-Objekt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey
    )

    process {
        if ($script:TenantStatus.ContainsKey($TenantKey)) {
            return $script:TenantStatus[$TenantKey]
        }
        return @{ isConnected = $false; lastChecked = $null; errorMessage = 'Noch nicht geprüft' }
    }
}

# ============================================================================
# SETTINGS ZUGRIFF
# ============================================================================

function Get-Settings {
    <#
    .SYNOPSIS
        Gibt das geladene Settings-Objekt zurück.
    .OUTPUTS
        [PSCustomObject]
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    process {
        return $script:Settings
    }
}

function Get-SettingsPath {
    <#
    .SYNOPSIS
        Gibt den Pfad der geladenen settings.json zurück.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    process {
        return $script:SettingsPath
    }
}

# ============================================================================
# HILFSFUNKTIONEN (Intern)
# ============================================================================

function Update-TenantStatusCache {
    [CmdletBinding()]
    param(
        [string]$TenantKey,
        [bool]$Connected,
        [string]$Error = '',
        [Nullable[bool]]$PermissionsOk = $null
    )

    process {
        if (-not $script:TenantStatus.ContainsKey($TenantKey)) {
            $script:TenantStatus[$TenantKey] = @{}
        }

        $script:TenantStatus[$TenantKey].isConnected = $Connected
        $script:TenantStatus[$TenantKey].lastChecked = Get-Date
        $script:TenantStatus[$TenantKey].errorMessage = $Error

        if ($null -ne $PermissionsOk) {
            $script:TenantStatus[$TenantKey].permissionsOk = $PermissionsOk
        }
    }
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function @(
    'Import-TenantSettings'
    'Get-AllTenants'
    'Get-TenantByKey'
    'Get-CurrentTenant'
    'Get-CurrentTenantKey'
    'Set-CurrentTenant'
    'Test-TenantConnection'
    'Get-TenantStatus'
    'Get-Settings'
    'Get-SettingsPath'
    'Update-TenantStatusCache'
)
