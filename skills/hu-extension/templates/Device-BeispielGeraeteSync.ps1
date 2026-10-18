<#
.SYNOPSIS
    Intune-Geraet per Name synchronisieren (Beispiel-Extension, schreibend, mit Probelauf)
.DESCRIPTION
    Sucht Geraete mit genau diesem Namen und stoesst die Synchronisierung an.
    Im Probelauf (-WhatIf) wird nur angezeigt, was passieren wuerde.
.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All
    DeviceManagementManagedDevices.PrivilegedOperations.All
.REQUIRED_ROLES
    Global Administrator
.CATEGORY
    Device
.TARGETS
    []
.BATCH_CAPABLE
    false
.DRY_RUN_CAPABLE
    true
.RUNTIME
    PS5
.MODE
    ReadWrite
.PARAM
    Geraetename|string|Geraetename (genau)|
.EXAMPLE
    . .\Device-BeispielGeraeteSync.ps1
    Invoke-BeispielGeraeteSync -TenantKey 'Schule-1' -Token $token -Geraetename 'NB-123' -WhatIf
#>

function Invoke-BeispielGeraeteSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [string]$Geraetename,

        [switch]$WhatIf
    )

    try {
        $name = "$Geraetename".Trim()
        if (-not $name) { throw 'Bitte einen Geraetenamen eintragen.' }

        $filter = "deviceName eq '" + ($name -replace "'", "''") + "'"
        $wv = $null
        $dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint ('/deviceManagement/managedDevices?$select=id,deviceName&$filter=' + [uri]::EscapeDataString($filter)) -TenantKey $TenantKey -WarningVariable wv -WarningAction SilentlyContinue)
        if ($wv) { throw "Abfrage unvollstaendig, nichts geaendert: $($wv -join ' | ')" }
        if (-not $dev.Count) { Write-HULogWarn "'$name' nicht gefunden." -Tenant $TenantKey; return [pscustomobject]@{ Success = $true; Geaendert = 0 } }

        $ok = 0
        $fehler = 0
        foreach ($d in $dev) {
            if ($WhatIf) {
                Write-HULogWarn "PROBELAUF: wuerde $($d.deviceName) synchronisieren." -Tenant $TenantKey
                continue
            }
            Write-HULogWarn "Fuehre aus: POST syncDevice fuer $($d.deviceName)" -Tenant $TenantKey
            $r = Invoke-GraphRequestWithRetry -Token $Token -Method POST -Endpoint "/deviceManagement/managedDevices/$($d.id)/syncDevice" -TenantKey $TenantKey
            if ($null -ne $r -and $null -ne $r.PSObject.Properties['IsError'] -and $r.IsError -eq $true) {
                $fehler++
                Write-HULogError "$($d.deviceName): Fehler $($r.StatusCode) $($r.ErrorMessage)" -Tenant $TenantKey
            }
            else {
                $ok++
                Write-HULogOK "$($d.deviceName): Sync gesendet." -Tenant $TenantKey
            }
        }
        if ($fehler) { throw "$fehler von $($dev.Count) Geraeten mit Fehler (siehe Protokoll)." }
        return [pscustomobject]@{ Success = $true; Geaendert = $ok; Probelauf = [bool]$WhatIf }
    }
    catch {
        $zeile = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        Write-HULogError "Fehlgeschlagen: $($_.Exception.Message)$zeile" -Tenant $TenantKey
        throw
    }
}
