#Requires -Version 5.1
<#
.SYNOPSIS
    Laufzeit fuer Quick Scripts (wird im Runspace des Quick Script Runners per Dot-Source geladen).
.DESCRIPTION
    - Get-HUToken [-Tenant <Key>]  : Token eines Tenants (Standard: der gerade laufende), wird automatisch erneuert
    - Invoke-GraphRequest / Invoke-GraphRequestWithRetry / Invoke-GraphRequestAll:
      Stellvertreter fuer die gleichnamigen HU.Graph-Funktionen. Wird ein Token uebergeben, das von Get-HUToken
      (bzw. als $Token) ausgegeben wurde, wird es vor jedem Aufruf durch ein gueltiges ersetzt - lange Laeufe
      (> 50 min, z. B. Massenaenderungen) brechen dadurch nicht mehr mit HTTP 401 ab.
    Voraussetzung im Runspace: HU.Auth und HU.Graph importiert, $Settings und $TenantKey global gesetzt.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

# Token -> Tenant (fuer die automatische Erneuerung)
$script:HUQSTokenTenant = @{}

function Get-HUToken {
    param([string]$Tenant = '')
    # globale Variablen des Runspace (Stellvertreter-Funktionen haben eigene $TenantKey/$Settings-Parameter)
    if (-not $Tenant) { $Tenant = $global:TenantKey }
    if (-not $Tenant) { throw 'Get-HUToken: kein Tenant angegeben' }
    $t = Get-GraphToken -TenantKey $Tenant -Settings $global:Settings -ErrorAction Stop
    if (-not $t) { throw "Kein Token fuer '$Tenant' (Secret pruefen)" }
    $script:HUQSTokenTenant[$t] = $Tenant
    return $t
}

# bekanntes Token -> aktuelles Token desselben Tenants (Get-GraphToken liefert bis zum Ablauf aus dem Cache)
function Update-HUQSToken([string]$Token) {
    if ($Token -and $script:HUQSTokenTenant.ContainsKey($Token)) {
        try { return (Get-HUToken -Tenant $script:HUQSTokenTenant[$Token]) } catch { return $Token }
    }
    return $Token
}

function Invoke-GraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body,
        [string]$ApiVersion,
        [string]$ContentType = 'application/json'
    )
    $PSBoundParameters['Token'] = Update-HUQSToken $Token
    HU.Graph\Invoke-GraphRequest @PSBoundParameters
}

function Invoke-GraphRequestWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body,
        [string]$TenantKey,
        [PSCustomObject]$Settings,
        [int]$MaxRetries,
        [string]$ApiVersion
    )
    $PSBoundParameters['Token'] = Update-HUQSToken $Token
    HU.Graph\Invoke-GraphRequestWithRetry @PSBoundParameters
}

function Invoke-GraphRequestAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Endpoint,
        [string]$TenantKey,
        [PSCustomObject]$Settings,
        [int]$MaxPages = 100
    )
    $PSBoundParameters['Token'] = Update-HUQSToken $Token
    HU.Graph\Invoke-GraphRequestAll @PSBoundParameters
}

Set-Alias -Name Invoke-AdminGraphRequest -Value Invoke-GraphRequest -Scope Global -ErrorAction SilentlyContinue
