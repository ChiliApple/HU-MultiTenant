<#
.SYNOPSIS
    [Kurze Beschreibung des Scripts]

.DESCRIPTION
    [Detaillierte Beschreibung]

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Device

.TARGETS
    []

.BATCH_CAPABLE
    $false

.DRY_RUN_CAPABLE
    $false

.EXAMPLE
    . .\Template.ps1
    Invoke-TemplateAction -TenantKey "Schule-1" -Token $token
#>

function Invoke-TemplateAction {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$WhatIf
    )

    # ── Logging (HU.Logging muss geladen sein) ──
    Write-HULog -Message "Starte Template-Action..." -Level 'INFO' -Tenant $TenantKey

    if ($WhatIf) {
        Write-HULog -Message "DRY-RUN: Keine Änderungen durchgeführt." -Level 'WARN' -Tenant $TenantKey
        return [PSCustomObject]@{ DryRun = $true; Message = "Keine Aktion (DRY-RUN)" }
    }

    # ── Hauptlogik ──
    try {
        # Graph API Aufruf (HU.Graph muss geladen sein)
        # $result = Invoke-GraphRequestWithRetry -Token $Token -Endpoint '/...' -TenantKey $TenantKey

        Write-HULog -Message "Template-Action erfolgreich abgeschlossen." -Level 'OK' -Tenant $TenantKey

        return [PSCustomObject]@{
            Success = $true
            Data    = @()
        }
    }
    catch {
        Write-HULog -Message "Fehler: $($_.Exception.Message)" -Level 'ERROR' -Tenant $TenantKey
        throw
    }
}
