<#
.SYNOPSIS
    Geraete ohne Synchronisierung seit X Tagen (Beispiel-Extension, nur lesen)
.DESCRIPTION
    Listet Intune-Geraete, deren letzte Synchronisierung laenger her ist als der Schwellwert.
    Ausgabe im Protokoll und, wenn ImportExcel verfuegbar ist, als Excel-Bericht mit Dashboard.
.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All
.REQUIRED_ROLES
    Global Administrator
.CATEGORY
    Device
.TARGETS
    []
.BATCH_CAPABLE
    true
.DRY_RUN_CAPABLE
    false
.RUNTIME
    PS5
.MODE
    ReadOnly
.PARAM
    Tage|int|Ohne Sync seit Tagen|30
    Excel|bool|Excel-Bericht erstellen|true
.EXAMPLE
    . .\Device-BeispielSyncBericht.ps1
    Invoke-BeispielSyncBericht -TenantKey 'Schule-1' -Token $token -Tage 30
#>

# Hilfsfunktionen duerfen NICHT mit Invoke- beginnen (die Oberflaeche sucht die Einstiegsfunktion ueber dieses Praefix)
function Get-BeispielSyncBerichtPfad {
    param([Parameter(Mandatory)][string]$TenantKey)
    $wurzel = if ($AppRoot) { $AppRoot } else { (Get-Item $PSScriptRoot).Parent.Parent.FullName }
    $ziel = Join-Path $wurzel 'Reports'
    $cfg = Join-Path $wurzel 'Config\settings.json'
    if (Test-Path -LiteralPath $cfg) {
        try {
            $rep = (Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json).reporting
            if ($rep -and $rep.outputPath) {
                $ziel = if ("$($rep.outputPath)".StartsWith('.')) { Join-Path $wurzel $rep.outputPath } else { "$($rep.outputPath)" }
            }
        }
        catch { Write-HULogDebug "settings.json nicht lesbar: $($_.Exception.Message)" -Tenant $TenantKey }
    }
    $ordner = Join-Path $ziel ('HU-Reports_' + (Get-Date -Format 'yyyy-MM-dd'))
    if (-not (Test-Path -LiteralPath $ordner)) { New-Item -Path $ordner -ItemType Directory -Force | Out-Null }
    return (Join-Path $ordner ("SyncBericht_${TenantKey}_" + (Get-Date -Format 'HHmmss') + '.xlsx'))
}

function Invoke-BeispielSyncBericht {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [int]$Tage = 30,

        [bool]$Excel = $true
    )

    try {
        Write-HULogInfo "Lade Intune-Geraete ..." -Tenant $TenantKey
        $wv = $null
        $dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices?$select=deviceName,userPrincipalName,operatingSystem,lastSyncDateTime' -TenantKey $TenantKey -WarningVariable wv -WarningAction SilentlyContinue)
        if ($wv) { throw "Abfrage unvollstaendig: $($wv -join ' | ')" }
        Write-HULogOK "$($dev.Count) Geraete geladen." -Tenant $TenantKey

        $grenze = (Get-Date).AddDays(-$Tage)
        $zeilen = [System.Collections.ArrayList]::new()
        foreach ($d in $dev) {
            $sync = $null
            if ($d.lastSyncDateTime) { $sync = [datetime]$d.lastSyncDateTime }
            if ($sync -and $sync -ge $grenze) { continue }
            [void]$zeilen.Add([pscustomobject]@{
                    Geraet      = $d.deviceName
                    Benutzer    = $d.userPrincipalName
                    System      = $d.operatingSystem
                    LetzterSync = $(if ($sync) { $sync.ToString('yyyy-MM-dd') } else { 'nie' })
                    TageAlt     = $(if ($sync) { [int][Math]::Floor(((Get-Date) - $sync).TotalDays) } else { 9999 })
                })
        }

        $liste = @($zeilen | Sort-Object -Property TageAlt -Descending)
        if ($liste.Count) { Write-HULogWarn "$($liste.Count) von $($dev.Count) Geraeten ohne Sync seit $Tage Tagen." -Tenant $TenantKey }
        else { Write-HULogOK "Alle Geraete synchronisieren innerhalb von $Tage Tagen." -Tenant $TenantKey }
        $n = 0
        foreach ($z in $liste) {
            $n++
            Write-HULogInfo ("{0,-25} | {1,-30} | letzter Sync: {2}" -f $z.Geraet, $z.Benutzer, $z.LetzterSync) -Tenant $TenantKey
            if ($n % 25 -eq 0) { Write-HULogInfo "[$n/$($liste.Count)] ..." -Tenant $TenantKey }
        }

        $pfad = ''
        if ($Excel -and $liste.Count) {
            if (Initialize-HUExcel) {
                $pfad = Get-BeispielSyncBerichtPfad -TenantKey $TenantKey
                New-HUExcelReport -Data $liste -SheetName 'OhneSync' -ReportPath $pfad -PrimaryKeyColumn 'Geraet' -ConditionalColumns @('System')
                Add-HUExcelDashboard -WorkbookPath $pfad -TenantKey $TenantKey -ReportTitle 'Geraete ohne Sync' `
                    -Metrics ([ordered]@{ 'Geraete gesamt' = $dev.Count; 'Ohne Sync' = $liste.Count }) `
                    -SheetDataSources @(@{ SheetName = 'OhneSync'; RowCount = $liste.Count; Description = "Geraete ohne Sync seit $Tage Tagen" })
                Write-HULogOK "Excel-Bericht: $pfad" -Tenant $TenantKey
            }
            else { Write-HULogWarn 'ImportExcel nicht verfuegbar - kein Excel-Bericht.' -Tenant $TenantKey }
        }

        return [pscustomobject]@{ Success = $true; TenantKey = $TenantKey; Geraete = $dev.Count; OhneSync = $liste.Count; Bericht = $pfad }
    }
    catch {
        $zeile = if ($_.InvocationInfo.ScriptLineNumber) { " (Zeile $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
        Write-HULogError "Fehlgeschlagen: $($_.Exception.Message)$zeile" -Tenant $TenantKey
        throw   # ohne throw meldet die Oberflaeche trotzdem "Fertig"
    }
}
