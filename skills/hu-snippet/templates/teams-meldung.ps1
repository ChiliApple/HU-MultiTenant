# Geraete ohne Synchronisierung - Meldung nach Teams (nur Anzahlen)
# Berechtigungen: DeviceManagementManagedDevices.Read.All
# @param Tage|int|Ohne Sync seit Tagen|30

$grenze = (Get-Date).AddDays(-$Tage)
$wv = $null
$dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices?$select=deviceName,lastSyncDateTime' -WarningVariable wv -WarningAction SilentlyContinue)
if ($wv) { Write-Error "[$TenantKey] Abfrage unvollstaendig, keine Meldung gesendet: $($wv -join ' | ')"; return }

$alt = @($dev | Where-Object { -not $_.lastSyncDateTime -or [datetime]$_.lastSyncDateTime -lt $grenze })
$alt | ForEach-Object { Write-Host $_.deviceName }   # Namen nur ins Protokoll, nicht in die Karte

$stufe = if ($alt.Count) { 'Warning' } else { 'OK' }
$r = Send-HUNotify -Level $stufe `
        -Title "$($TenantKey): $($alt.Count) Geraete ohne Sync" `
        -Preview "$($alt.Count) von $($dev.Count) Geraeten" `
        -Lines @("$($alt.Count) von $($dev.Count) Geraeten ohne Sync seit $Tage Tagen - Liste im Quick-Script-Verlauf")
Write-Host $r.Text
