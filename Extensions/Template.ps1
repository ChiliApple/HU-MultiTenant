<#
.SYNOPSIS
    [Kurze Beschreibung des Scripts]

.DESCRIPTION
    [Detaillierte Beschreibung]
    Vorlage: Datei kopieren, umbenennen (Kategorie-Name.ps1, z.B. Device-MeinBericht.ps1) und anpassen.
    Fertige, geprueft lauffaehige Beispiele und die Pruefwerkzeuge: Ordner skills\hu-extension.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Device

.TARGETS
    []

.BATCH_CAPABLE
    false

.DRY_RUN_CAPABLE
    false

.RUNTIME
    PS5

.MODE
    ReadOnly

.PARAM
    Tage|int|Beispiel-Eingabefeld (Tage)|30

.EXAMPLE
    . .\Template.ps1
    Invoke-TemplateAction -TenantKey 'Schule-1' -Token $token -Tage 30

.NOTES
    - Schreibend (POST/PATCH/DELETE)? Dann .MODE ReadWrite, .DRY_RUN_CAPABLE true und [switch]$WhatIf
      in param() - SupportsShouldProcess NICHT zusaetzlich verwenden (sonst "defined multiple times").
    - Fehler muessen mit throw enden, sonst meldet die Oberflaeche "Fertig".
    - Hilfsfunktionen duerfen nicht mit Invoke- beginnen.
#>

function Invoke-TemplateAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [int]$Tage = 30
    )

    try {
        Write-HULogInfo "Starte Template-Action ..." -Tenant $TenantKey

        # Lesen: Invoke-GraphRequestAll liefert bei einer Listen-Abfrage alle Eintraege. Bricht eine Seite ab,
        # kommen die bisherigen Eintraege plus eine Warnung - deshalb mit -WarningVariable abfangen.
        $wv = $null
        $daten = @(Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices?$select=deviceName' -TenantKey $TenantKey -WarningVariable wv -WarningAction SilentlyContinue)
        if ($wv) { throw "Abfrage unvollstaendig: $($wv -join ' | ')" }

        Write-HULogOK "$($daten.Count) Eintraege gelesen." -Tenant $TenantKey
        return [PSCustomObject]@{
            Success = $true
            Anzahl  = $daten.Count
        }
    }
    catch {
        Write-HULogError "Fehlgeschlagen: $($_.Exception.Message)" -Tenant $TenantKey
        throw
    }
}
