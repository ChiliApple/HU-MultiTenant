# Intune-Geraete ohne Synchronisierung seit X Tagen
# Berechtigungen: DeviceManagementManagedDevices.Read.All
# @param Tage|int|Ohne Sync seit Tagen|30

$grenze = (Get-Date).AddDays(-$Tage)
$wv = $null
$dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices?$select=deviceName,userPrincipalName,lastSyncDateTime' -WarningVariable wv -WarningAction SilentlyContinue)
if ($wv) { Write-Error "[$TenantKey] Abfrage unvollstaendig, Abbruch: $($wv -join ' | ')"; return }

$alt = @($dev | Where-Object { -not $_.lastSyncDateTime -or [datetime]$_.lastSyncDateTime -lt $grenze })
Write-Host "$($alt.Count) von $($dev.Count) Geraeten ohne Sync seit $Tage Tagen" -ForegroundColor Yellow

foreach ($d in $alt) {
    [pscustomobject]@{
        Geraet      = $d.deviceName
        Benutzer    = $d.userPrincipalName
        LetzterSync = $(if ($d.lastSyncDateTime) { [datetime]$d.lastSyncDateTime } else { $null })
    }
}
