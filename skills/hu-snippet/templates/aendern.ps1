# Intune-Geraet per Name synchronisieren
# Berechtigungen: DeviceManagementManagedDevices.Read.All, DeviceManagementManagedDevices.PrivilegedOperations.All
# @param Geraetename|string|Geraetename (genau)|
# @param DryRun|bool|Probelauf (nur anzeigen)|true

function Test-FehlerAntwort($Antwort) {
    return ($null -ne $Antwort -and $null -ne $Antwort.PSObject.Properties['IsError'] -and $Antwort.IsError -eq $true)
}

$name = "$Geraetename".Trim()
if (-not $name) { Write-Warning 'Bitte oben im Feld Geraetename einen Namen eintragen.'; return }

$filter = "deviceName eq '" + ($name -replace "'", "''") + "'"
$wv = $null
$dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint ('/deviceManagement/managedDevices?$select=id,deviceName&$filter=' + [uri]::EscapeDataString($filter)) -WarningVariable wv -WarningAction SilentlyContinue)
if ($wv) { Write-Error "[$TenantKey] Abfrage unvollstaendig, nichts geaendert: $($wv -join ' | ')"; return }
if (-not $dev.Count) { Write-Warning "[$TenantKey] '$name' nicht gefunden"; return }

foreach ($d in $dev) {
    if ($DryRun) {
        $status = 'Probelauf'
        Write-Host "[Probelauf] wuerde $($d.deviceName) synchronisieren" -ForegroundColor Yellow
    }
    else {
        $r = Invoke-GraphRequestWithRetry -Token $Token -Method POST -Endpoint "/deviceManagement/managedDevices/$($d.id)/syncDevice"
        if (Test-FehlerAntwort $r) {
            $status = "Fehler $($r.StatusCode): $($r.ErrorMessage)"
            Write-Host "$($d.deviceName): $status" -ForegroundColor Red
        }
        else {
            $status = 'Sync gesendet'
            Write-Host "$($d.deviceName): $status" -ForegroundColor Green
        }
    }
    [pscustomobject]@{ Geraet = $d.deviceName; Ergebnis = $status }
}
