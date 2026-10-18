# HU-MultiTenant — Extensions entwickeln

**Zweck:** Dieses Dokument ist die verbindliche Spezifikation für die Entwicklung von Extensions für HU-MultiTenant. Jede Regel hier basiert auf tatsächlich aufgetretenen Fehlern in Produktion.

**Stand:** v2.0 | **Zielgruppe:** Administratoren, die eigene Reports oder Aktionen bauen | **Runtime:** PowerShell 5.1 (Standard), PowerShell 7 (optional via `.RUNTIME`)

**Geprüfte Vorlagen und Prüfprogramm:** [skills/hu-extension](skills/hu-extension/SKILL.md) (Abschnitt 18). Wer eine Extension mit einem Assistenzprogramm schreiben lässt, gibt ihm diese Anleitung mit.

---

## 1. Was ist eine Extension?

Eine Extension ist ein einzelnes `.ps1`-Skript im Ordner `Extensions/` (oder Unterordner), das:
- Einen strukturierten Metadata-Kommentarblock am Anfang hat
- Genau EINE exportierte Funktion `Invoke-<Name>` enthält
- Über die GUI gegen einen oder mehrere M365-Tenants ausgeführt wird
- Die Core-Module (HU.Logging, HU.Graph, etc.) nutzt
- In einem **Background-Thread** läuft (UI bleibt responsive)

## 2. Dateikonventionen

### Namensschema

```
Extensions/<Kategorie>/<Kategorie>-<Beschreibung>.ps1
```

Gültige Kategorie-Präfixe (aus `extensions-registry.json`):

| Präfix | Ordner | Beschreibung |
|---|---|---|
| `Device-` | `Extensions/Device/` | Intune Geräteverwaltung |
| `Policy-` | `Extensions/Policy/` | Compliance/Update Policies |
| `Security-` | `Extensions/Security/` | Defender, Threats |
| `User-` | `Extensions/User/` | Benutzerverwaltung |
| `Common-` | `Extensions/Common/` | Übergreifende Reports |

### Funktionsname

Der Funktionsname MUSS dem Schema `Invoke-<BeschreibungOhnePräfix>` folgen:

```
Device-DeviceReport.ps1        → function Invoke-DeviceReport
Policy-UpdateRingStatus.ps1    → function Invoke-UpdateRingStatus
Security-MalwareDetection.ps1  → function Invoke-MalwareDetection
```

## 3. Metadata-Header (PFLICHT)

Jede Extension MUSS diesen Comment-Block am Dateianfang haben. Der Parser (`HU.Extensions.psm1`) verwendet `[regex]::Split` mit einer Known-Keys Whitelist.

```powershell
<#
.SYNOPSIS
    Kurze Beschreibung (1 Zeile, wird in der GUI Extension-Liste angezeigt)

.DESCRIPTION
    Detaillierte Beschreibung. Wird im Extension-Details-Panel der GUI angezeigt.
    Kann mehrere Zeilen umfassen.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All
    DeviceManagementConfiguration.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Device

.TARGETS
    ["Schule-A", "Schule-B", "Schule-C"]

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $true

.RUNTIME
    PS5

.EXAMPLE
    . .\Device-DeviceReport.ps1
    Invoke-DeviceReport -TenantKey "Meine-Schule" -Token $token
#>
```

### Regeln für Metadata-Werte

| Key | Typ | Beschreibung |
|---|---|---|
| `.SYNOPSIS` | String | 1 Zeile, GUI-Kurztext |
| `.DESCRIPTION` | String | Mehrzeilig erlaubt |
| `.REQUIRED_PERMISSIONS` | Zeilenweise | Eine Permission pro Zeile, exakte Microsoft Graph Permission Names |
| `.REQUIRED_ROLES` | String | Azure AD Rolle (z.B. `Global Administrator`) |
| `.CATEGORY` | String | Exakt einer der Kategorie-Namen: `Device`, `Policy`, `Security`, `User`, `Common` |
| `.TARGETS` | JSON-Array | Valide Tenant-Keys als JSON-String-Array |
| `.BATCH_CAPABLE` | Bool | `$true` wenn Batch über mehrere Tenants möglich |
| `.DRY_RUN_CAPABLE` | Bool | `$true` wenn `-WhatIf` unterstützt wird |
| `.RUNTIME` | String | `PS5` (Default), `PS7`, oder `PS5\|PS7` — siehe Abschnitt 14 |
| `.MODE` | String | `ReadOnly` (Default) oder `ReadWrite` — siehe Abschnitt 15 |
| `.PARAM` | Mehrzeilig | Custom Parameters, Format: `Name\|Type\|Label\|Default\|Choices` — siehe Abschnitt 15 |
| `.EXAMPLE` | String | PowerShell-Aufrufbeispiel |

**KRITISCH:** Permission-Namen müssen EXAKT mit Microsoft Graph übereinstimmen (inkl. `.Read.All`, `.ReadWrite.All`). Der Parser behandelt Punkte in Permission-Namen korrekt — ABER nur weil er Known-Keys als Whitelist nutzt. Wenn ein Permission-Name wie `DeviceManagementManagedDevices.Read.All` auf `.All` endet, wird das `.All` NICHT als neuer Metadata-Key interpretiert.

**KRITISCH:** `.TARGETS` muss ein gültiges JSON-Array sein. Die Tenant-Keys müssen exakt den `key`-Werten aus `Config/settings.json` entsprechen.

## 4. Funktions-Signatur (PFLICHT)

```powershell
function Invoke-<Name> {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$WhatIf
    )

    # ... Implementierung ...
}
```

**Regeln:**
- `[CmdletBinding()]` ist PFLICHT
- `$TenantKey` und `$Token` sind PFLICHT-Parameter
- `[switch]$WhatIf` NUR wenn `.DRY_RUN_CAPABLE = $true` – und dann **ohne** `SupportsShouldProcess` im `[CmdletBinding()]` (sonst sind `WhatIf`/`Confirm` doppelt definiert und die Extension startet nicht)
- Nur **eine** Funktion mit `Invoke-` pro Datei; Hilfsfunktionen heißen `Get-…`, `Test-…`, `Format-…` (gestartet wird die erste `Invoke-*`-Funktion der Datei)
- **NIEMALS `[switch]$Verbose` deklarieren** — `[CmdletBinding()]` stellt `-Verbose` automatisch bereit. Manuelle Deklaration verursacht: `"Parameter mit dem Namen verbose wurde mehrfach definiert."`
- **Fehler = `throw`.** Die Oberfläche wertet nur aus, ob eine Ausnahme kam. Ein Rückgabeobjekt mit `Success = $false` wird **nicht** gelesen – die Oberfläche meldet trotzdem „Fertig“. Der äußere `catch` protokolliert und endet mit `throw`.
- Rückgabewert bei Erfolg: `[PSCustomObject]` (z. B. `Success = $true` plus Kennzahlen)

## 5. Verfügbare Core-Funktionen

Die Extension wird per dot-source in den Kontext geladen. Folgende Module sind automatisch verfügbar:

### HU.Logging

```powershell
# IMMER Write-HULog verwenden, NIEMALS Write-Host oder Write-Output
Write-HULog -Message 'Text' -Level 'INFO' -Tenant $TenantKey

# Kurzformen (Message an erster Stelle, dazu nur -Tenant):
Write-HULogInfo 'Text' -Tenant $TenantKey    # auch Write-HULogOK, Write-HULogWarn, Write-HULogError, Write-HULogDebug

# Verfügbare Level: OK, WARN, ERROR, INFO, DEBUG
# Tenant-Parameter ist optional aber EMPFOHLEN (erscheint als [TenantKey] im Log)
```

**WICHTIG:** `Write-Host` und `Write-Output` sind VERBOTEN in Extensions. Sie funktionieren nicht im Background-Thread und erzeugen keine Ausgabe in der GUI. Nur `Write-HULog` ist sichtbar.

### HU.Graph

```powershell
# Einzelner Request (ohne Retry)
$result = Invoke-GraphRequest -Token $Token -Endpoint '/deviceManagement/managedDevices' -Method GET

# Mit Retry (429/5xx, Exponential Backoff) — EMPFOHLEN
$result = Invoke-GraphRequestWithRetry -Token $Token -Endpoint '/deviceManagement/managedDevices' -TenantKey $TenantKey

# Automatische Pagination (alle Seiten sammeln) — FÜR GROSSE DATENMENGEN
$allItems = Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices' -TenantKey $TenantKey

# Convenience-Funktionen:
$devices = Get-ManagedDevices -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)
# Rückgabe: @{ Devices = [...]; Count = N }

$compliance = Get-DeviceComplianceStatus -Token $Token -DeviceId $id -TenantKey $TenantKey -Settings (Get-Settings)
$policies = Get-CompliancePolicies -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)
$alerts = Get-MalwareAlerts -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)

# Permission prüfen (prüft sowohl 'roles' als auch 'scp' Claims im JWT)
$ok = Test-GraphPermission -Token $Token -Permission 'DeviceManagementManagedDevices.Read.All'
$perms = Get-TokenPermissions -Token $Token  # Gibt ArrayList aller Permissions zurück
```

**Wichtig bei den drei Aufruf-Funktionen:**

- `Invoke-GraphRequest` und `Invoke-GraphRequestWithRetry` werfen bei HTTP-Fehlern **keine Ausnahme**, sondern liefern ein Objekt mit `IsError`, `StatusCode`, `ErrorMessage`. Das Ergebnis jedes ändernden Aufrufs prüfen (`if ($r.IsError) { … }`) und Fehler am Ende mit `throw` melden.
- `Invoke-GraphRequestAll` ist nur für **Listen** (`value`-Array). Für ein Einzelobjekt (`/users/<id>`) liefert es nichts – dort `Invoke-GraphRequest`. Fällt eine Folgeseite aus, kommen die bisherigen Einträge plus eine **Warnung**, keine Ausnahme: mit `-WarningVariable wv -WarningAction SilentlyContinue` abfangen und bei `$wv` mit `throw` abbrechen (vor ändernden Aufrufen Pflicht). `-ApiVersion` gibt es dort nicht; `beta` über die absolute Adresse `https://graph.microsoft.com/beta/…`.
- Methoden: `GET`, `POST`, `PATCH`, `DELETE` (kein `PUT`); `-Body` nur bei `POST`/`PATCH`, als Hashtable (kein JSON-Text). Eigene Header (`ConsistencyLevel`, `$count`, `$search`) gibt es nicht – clientseitig filtern.
- Eine absolute `https://`-Adresse wird unverändert aufgerufen, das Token geht mit: nur `https://graph.microsoft.com/…`.
- `-TenantKey` immer mitgeben (Token-Erneuerung bei langen Läufen, Zuordnung im Protokoll).

### HU.Tenant

Im Extension-Lauf (eigener Runspace) werden die Einstellungen **nicht geladen**: `Get-Settings` liefert `$null`, `Get-AllTenants` eine leere Liste (mit Warnung), `Get-TenantByKey` `$null`. Alles, was die Extension über den Tenant wissen muss, kommt über `-TenantKey`, `-Token` und die `.PARAM`-Felder.

```powershell
$settings = Get-Settings                        # im Extension-Lauf $null
$tenant = Get-TenantByKey -TenantKey $TenantKey # im Extension-Lauf $null
$allTenants = Get-AllTenants                     # im Extension-Lauf leer
```

### HU.Excel (Report-Generierung)

```powershell
# ImportExcel-Modul prüfen/installieren (am Anfang der Extension aufrufen)
if (-not (Initialize-HUExcel)) {
    Write-HULogError 'ImportExcel nicht verfuegbar' -Tenant $TenantKey
    throw 'ImportExcel nicht verfuegbar'
}

# Daten als Sheet exportieren (Export-Excel aus ImportExcel-Modul)
$data | Export-Excel -Path $reportPath -WorksheetName 'All-Devices' `
    -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *

# Weitere Sheets anfügen
$moreData | Export-Excel -Path $reportPath -WorksheetName 'Sheet2' -Append `
    -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *

# Einheitliches Design anwenden
Format-HUExcelWorkbook -WorkbookPath $reportPath `
    -PrimaryKeyColumn 'DeviceName' `
    -ConditionalColumns @('Compliant', 'ComplianceState', 'ThreatLevel')

# Spaltengruppen mit visueller Trennung
Set-HUExcelColumnGrouping -WorkbookPath $reportPath `
    -GroupDefinitions @(
        @{ Title = 'GERAET';     Columns = @('DeviceName', 'Owner', 'Model') }
        @{ Title = 'OS';         Columns = @('OS', 'OSVersion') }
        @{ Title = 'COMPLIANCE'; Columns = @('Compliant', 'ComplianceState', 'ThreatLevel') }
    )

# Dashboard mit KPIs + Sheet-Links (wird als erstes Sheet eingefügt)
$dashMetrics = [ordered]@{
    'Geraete gesamt' = $totalCount
    'Compliant'      = $compliantCount
    'Non-Compliant'  = $nonCompliantCount
}
$sheetLinks = @(
    @{ SheetName = 'All-Devices'; RowCount = $totalCount; Description = 'Alle Geraete' }
    @{ SheetName = 'Non-Compliant'; RowCount = $ncCount; Description = 'Nicht-konforme Geraete' }
)
Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey `
    -ReportTitle 'Device Report' -Metrics $dashMetrics -SheetDataSources $sheetLinks
```

### HU.Notify (Teams-Meldungen, ab v2.1.10)

```powershell
# Karte an bestimmte Teams-Ziele (Id steht im Reiter Teams unter dem gewaehlten Ziel)
$r = Send-HUNotify -TargetIds @('a1b2c3d4') -Source 'Backup-Erweiterung' -Title "$($TenantKey): Backup fertig" -Level OK `
        -Facts ([ordered]@{ Dateien = $n; Dauer = $dauer }) -Preview "$n Dateien gesichert"
if ($r.Failed) { Write-HULog -Message "Teams: $($r.Text)" -Level 'WARN' -Tenant $TenantKey }
```

- wirft nie; Rückgabe `Ok`, `Failed`, `Text` (ohne Webhook-Adressen; bei `Ok = 0` steht der Grund im Text)
- vor dem Start fragt HU-MultiTenant einmal, ob die Erweiterung an Teams senden darf; ohne "Ja" und im Probelauf (DryRun) sendet sie nichts
- nur in Extensions mit Standard-Runtime (Windows PowerShell 5.1), nicht bei `.RUNTIME PS7`
- keine Secrets, Kennwörter oder Recovery-Keys in Karten; Gerätenamen nur an Admin-Kanäle
- Erweiterungen laufen mit den Rechten des Admins – nur vertrauenswürdige Erweiterungen installieren; `Grant-HUSendApproval` **nie** in Erweiterungen aufrufen (die Freigabe gibt die Rückfrage vor dem Start)
- regelmäßige Meldungen mit Zeitplan lieber als Quick-Script-Snippet und Teams-Meldung "Aus Skript" bauen (Anleitung › Teams)

**WICHTIG:** Alle Excel-Reports verwenden ImportExcel (EPPlus-basiert). Excel-COM-Interop (`New-Object -ComObject Excel.Application`) ist **NICHT** mehr zulässig. Kein `Set-ExcelCellValue`, kein `ReleaseComObject`, kein COM-Cleanup nötig.

## 6. Extension-Struktur (geprüfte Vorlagen)

Beide Vorlagen liegen als Dateien in `skills/hu-extension/templates/`, sind vom Prüfprogramm ohne Befund akzeptiert und laufen in einem automatischen Test über den echten Lader gegen eine Graph-Attrappe. Datei kopieren, nach Schema umbenennen (Abschnitt 2), Kopf und Funktion anpassen.

**Vorlage 1 – Bericht (nur lesen, optional Excel):**

```powershell
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
```

**Vorlage 2 – Aktion (ändern, mit Probelauf):**

```powershell
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
```

Die leere Vorlage `Extensions/Template.ps1` (wird vom Lader ignoriert) enthält das Grundgerüst mit Hinweisen.

## 7. Excel-Report-Generierung (ImportExcel + HU.Excel.psm1)

### Warum ImportExcel statt Excel-COM?

Die ursprüngliche Excel-COM-Interop-Lösung wurde durch ImportExcel (EPPlus-basiert) ersetzt. Gründe:

| Problem (COM) | Lösung (ImportExcel) |
|---|---|
| Office muss lokal installiert sein | Kein Office nötig |
| Culture-abhängig (Int32/Double Marshalling) | Culture-unabhängig |
| COM-Cleanup nötig (ReleaseComObject, GC) | Kein Cleanup nötig |
| ~600 Zeilen pro Report-Script | ~250 Zeilen pro Report-Script |
| STA-Thread Pflicht | Kein Thread-Zwang |
| Excel-Prozess bleibt hängen bei Fehler | Kein Prozess |

### Standard-Pattern für Excel-Reports

```powershell
# ================================================================
# 0. IMPORTEXCEL PRUEFEN
# ================================================================

if (-not (Initialize-HUExcel)) {
    Write-HULogError 'ImportExcel nicht verfuegbar.' -Tenant $TenantKey
    throw 'ImportExcel nicht verfuegbar'
}

# ================================================================
# REPORT-PFAD (Standard-Pattern, siehe Abschnitt 8)
# ================================================================

# ... $reportPath ermitteln (auto-versioniert) ...

# ================================================================
# EXCEL GENERIEREN
# ================================================================

try {
    # Sheet 1: Hauptdaten
    $enrichedDevices | Export-Excel -Path $reportPath -WorksheetName 'All-Devices' `
        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion *

    # Sheet 2: Gefilterte Daten (Append!)
    $nonCompliantDevices | Export-Excel -Path $reportPath -WorksheetName 'Non-Compliant' `
        -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append

    # Leeres Sheet bei keinen Daten
    if ($filteredData.Count -eq 0) {
        @([PSCustomObject]@{ Info = 'Keine Daten gefunden.' }) |
            Export-Excel -Path $reportPath -WorksheetName 'SheetName' -Append
    }

    # Standard-Formatierung anwenden
    Format-HUExcelWorkbook -WorkbookPath $reportPath `
        -PrimaryKeyColumn 'DeviceName' `
        -ConditionalColumns @('Compliant', 'ComplianceState', 'ThreatLevel')

    # Spaltengruppen
    Set-HUExcelColumnGrouping -WorkbookPath $reportPath `
        -GroupDefinitions @(
            @{ Title = 'GERAET';     Columns = @('DeviceName', 'Owner', 'Model') }
            @{ Title = 'COMPLIANCE'; Columns = @('Compliant', 'ComplianceState') }
        )

    # Dashboard (wird automatisch als erstes Sheet eingefügt)
    $dashMetrics = [ordered]@{
        'Geraete gesamt' = $totalCount
        'Compliant'      = $compliantCount
    }
    $sheetLinks = @(
        @{ SheetName = 'All-Devices'; RowCount = $totalCount; Description = 'Alle Geraete' }
    )
    Add-HUExcelDashboard -WorkbookPath $reportPath -TenantKey $TenantKey `
        -ReportTitle 'Mein Report' -Metrics $dashMetrics -SheetDataSources $sheetLinks

    Write-HULog -Message "Report saved: $reportPath" -Level 'OK' -Tenant $TenantKey
}
catch {
    $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (line $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
    $errCmd = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
    Write-HULog -Message "Excel generation failed: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
    throw
}

# Report automatisch öffnen
if (Test-Path $reportPath) {
    Write-HULog -Message 'Opening report...' -Level 'INFO' -Tenant $TenantKey
    try { Start-Process -FilePath $reportPath }
    catch { Write-HULog -Message "Auto-open failed: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
}
```

### HU.Excel Funktionen im Detail

| Funktion | Beschreibung |
|---|---|
| `Initialize-HUExcel` | Prüft ob ImportExcel installiert ist, installiert automatisch bei Bedarf. Gibt `$true`/`$false` zurück. |
| `Format-HUExcelWorkbook` | Wendet einheitliches Design auf alle Sheets an: Header-Farbe #1F4E79 (weiße Schrift), AutoFilter via EPPlus Tables, Freeze Row 1, Alternating Rows (#F2F2F2), Conditional Formatting auf angegebenen Spalten, AutoFit mit Min/Max-Breiten. |
| `Add-HUExcelDashboard` | Erstellt KPI-Dashboard als erstes Sheet: farbige Metrik-Boxes, Sheet-Hyperlinks mit Row-Count. |
| `Set-HUExcelColumnGrouping` | Setzt Medium-Weight Right-Borders zwischen logischen Spaltengruppen. |
| `Set-HUExcelFreezePanes` | Freeze Panes für Zeilen und/oder Spalten (z.B. Header + erste 3 Spalten fixieren). |

### Design-Konstanten (in HU.Excel.psm1)

| Element | Wert | Verwendung |
|---|---|---|
| Header-Hintergrund | `#1F4E79` (Dunkelblau) | Alle Header-Zeilen |
| Header-Schrift | `#FFFFFF` (Weiß), Bold | Alle Header-Zeilen |
| Alt-Row | `#F2F2F2` (Hellgrau) | Jede zweite Datenzeile |
| Critical | `#FFE0E0` (Hellrot) | Conditional: critical, high, nein |
| Warning | `#FFF3E0` (Hellorange) | Conditional: warning, medium, pendingRestart |
| OK | `#E8F5E9` (Hellgrün) | Conditional: compliant, yes, clean, secured |
| Schriftart | Calibri 10pt | Global |

### VERBOTEN (Legacy-COM-Pattern)

Folgende Patterns sind seit der Migration zu ImportExcel **NICHT** mehr zulässig:

```powershell
# ❌ VERBOTEN — Excel-COM
$excel = New-Object -ComObject Excel.Application
Set-ExcelCellValue -Cell $cell -Value $val
$workbook.SaveAs($path, 51)
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj)
[System.GC]::Collect()
```

## 8. Report-Pfad Konventionen

```powershell
$scriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot  = (Get-Item $scriptRoot).Parent.Parent.FullName
$dateStamp    = Get-Date -Format 'yyyy-MM-dd'
$reportFolder = Join-Path $projectRoot "Reports\HU-Reports_$dateStamp"
$reportBase   = "<Kategorie>-Report_$TenantKey"

# Ordner erstellen
if (-not (Test-Path $reportFolder)) {
    New-Item -Path $reportFolder -ItemType Directory -Force | Out-Null
}

# Auto-Versionierung (v1, v2, v3, ...)
$version = 1
do {
    $reportFileName = "${reportBase}_v${version}.xlsx"
    $reportPath = Join-Path $reportFolder $reportFileName
    $version++
} while (Test-Path $reportPath)
```

## 9. Fehlerbehandlung (PFLICHT)

```powershell
# Jede Extension MUSS einen try/catch haben
try {
    # ... Hauptlogik ...
}
catch {
    # Zeilennummer + Code-Zeile im Error-Log (KRITISCH für Debugging)
    $errLine = if ($_.InvocationInfo.ScriptLineNumber) { " (line $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
    $errCmd = if ($_.InvocationInfo.Line) { " | Code: $($_.InvocationInfo.Line.Trim())" } else { '' }
    Write-HULog -Message "Failed: $($_.Exception.Message)${errLine}${errCmd}" -Level 'ERROR' -Tenant $TenantKey
    throw   # ohne throw meldet die Oberfläche „Fertig“, obwohl es fehlschlug
}
```

## 10. PowerShell 5.1 Besonderheiten

### Emoji-Encoding

```powershell
# ❌ FALSCH — Literal-Emoji in PS 5.1 ohne UTF-8 BOM
$status = "🟢 OK"           # Zeigt "Ş™ OK" an

# ✅ RICHTIG — ConvertFromUtf32
$green = [char]::ConvertFromUtf32(0x1F7E2)
$status = "$green OK"       # Zeigt "🟢 OK" an
```

### Array-Flattening

```powershell
# ConvertFrom-Json + @() kann verschachtelte Arrays erzeugen
$targets = @($parsed | ForEach-Object { $_ })  # Flattening
```

### Keine PowerShell-7-Syntax (außer mit `.RUNTIME PS7`, siehe Abschnitt 14)

- Kein `??` (null-coalescing)
- Kein `?.` (null-conditional)
- Kein `$x ??= 'default'`
- Kein `foreach-object -parallel`
- `ConvertTo-Json -Depth` Standard ist 2 (nicht unbegrenzt)

## 11. Graph API Hinweise

### Permission-Validierung

Permissions werden aus dem JWT-Token extrahiert (Base64-Decode des Payload). Es werden BEIDE Claims geprüft:
- `roles` — Application Permissions (Client Credentials Flow)
- `scp` — Delegated Permissions (falls vorhanden)

### Pagination

Graph API liefert max. 100 Items pro Request. Bei `Get-ManagedDevices` und anderen Convenience-Funktionen wird Pagination automatisch über `@odata.nextLink` behandelt.

### Rate Limiting

Bei HTTP 429 (Too Many Requests) wird automatisch mit Exponential Backoff gewartet (1s → 2s → 4s, max 3 Retries).

### Verfügbare Device-Properties

`managedDevices` liefert u.a.: `id`, `deviceName`, `userPrincipalName`, `model`, `operatingSystem`, `osVersion`, `serialNumber`, `complianceState`, `lastSyncDateTime`, `managedDeviceThreatLevel` (String-Enum: secured/low/medium/high/notSet).

**NICHT verfügbar:** Numerischer ThreatCount. Graph API liefert nur den ThreatLevel als String-Enum.

## 12. Checkliste für neue Extensions

Vor Auslieferung prüfen:

- [ ] Metadata-Header vollständig (alle 8 Keys vorhanden)
- [ ] Permission-Namen exakt (inkl. `.Read.All` / `.ReadWrite.All`)
- [ ] `.TARGETS` ist valides JSON-Array mit korrekten Tenant-Keys
- [ ] Funktionsname folgt Schema `Invoke-<Name>`
- [ ] `[CmdletBinding()]` vorhanden
- [ ] **KEIN `[switch]$Verbose` deklariert** (CmdletBinding liefert das automatisch)
- [ ] `$TenantKey` und `$Token` als Mandatory-Parameter
- [ ] NUR `Write-HULog` für Output (kein Write-Host, kein Write-Output)
- [ ] Fortschritt-Logging alle 25 Items
- [ ] Error-Handler mit Zeilennummer + Code-Zeile
- [ ] Fehler enden mit `throw` (der äußere `catch` protokolliert und wirft weiter); ein Rückgabeobjekt `Success = $false` wird von der Oberfläche nicht gelesen
- [ ] Ergebnis jedes ändernden Graph-Aufrufs auf `IsError` geprüft; `Invoke-GraphRequestAll` mit `-WarningVariable`
- [ ] Prüfprogramm `skills\hu-extension\tools\Test-HUExtension.ps1` ohne FEHLER
- [ ] DryRun-Logik wenn `.DRY_RUN_CAPABLE = $true`

### Zusätzlich bei Excel-Extensions (ImportExcel):

- [ ] `Initialize-HUExcel` am Anfang aufgerufen (prüft/installiert ImportExcel)
- [ ] Daten via `Export-Excel` mit `-NoNumberConversion *` exportiert
- [ ] `Format-HUExcelWorkbook` für einheitliches Design aufgerufen
- [ ] `Set-HUExcelColumnGrouping` für logische Spaltengruppen (falls mehrere Gruppen)
- [ ] `Add-HUExcelDashboard` mit KPI-Metriken + Sheet-Links
- [ ] Leere Sheets mit Platzhalter-Row (`@([PSCustomObject]@{ Info = '...' })`)
- [ ] Report öffnet sich automatisch nach Erstellung (`Start-Process`)
- [ ] **KEIN** Excel-COM (`New-Object -ComObject Excel.Application` ist VERBOTEN)

## 13. Häufige Fehler

| Fehler | Ursache | Lösung |
|---|---|---|
| `Parameter verbose mehrfach definiert` | `[switch]$Verbose` + `[CmdletBinding()]` | `$Verbose` entfernen |
| `Parameter WhatIf mehrfach definiert` | `SupportsShouldProcess` + eigenes `[switch]$WhatIf` | `[CmdletBinding()]` ohne `SupportsShouldProcess`, `$WhatIf` selbst abfragen |
| Oberfläche meldet „Fertig“, obwohl es fehlschlug | `catch` ohne `throw` (`Success = $false` wird nicht gelesen) | im `catch` mit `throw` enden |
| Extension fehlt in der Liste | erster Blockkommentar ohne `.SYNOPSIS`, oder Schlüssel und Wert in einer Zeile | `.SYNOPSIS` ergänzen, Schlüssel allein in der Zeile |
| Falsche Funktion gestartet | zweite Funktion mit `Invoke-` in der Datei | Hilfsfunktionen anders benennen |
| Liste unvollständig, Änderung trotzdem ausgeführt | `Invoke-GraphRequestAll` liefert bei Seitenfehler Teilergebnis + Warnung | `-WarningVariable wv -WarningAction SilentlyContinue`, bei `$wv` `throw` |
| Änderung ohne Fehlermeldung fehlgeschlagen | `Invoke-GraphRequest` wirft nicht, liefert `IsError` | Ergebnis prüfen |
| `Missing permission: X.Read` | Permission ohne `.All` Suffix | `.Read.All` verwenden |
| Target-Warnung `System.Object[]` | Verschachtelte Arrays (ConvertFrom-Json) | `@($parsed \| ForEach-Object { $_ })` |
| GUI friert ein | Synchrone Ausführung | Main.ps1 Background-Thread verwenden |
| Emoji zeigt `Ş™` | Literal-Emoji in PS 5.1 | `[char]::ConvertFromUtf32(0x1F7E2)` |
| ImportExcel nicht gefunden | Modul nicht installiert | `Initialize-HUExcel` aufrufen oder `Install-Module ImportExcel -Scope CurrentUser` |
| Export-Excel Zahlen als Text | String-Konvertierung | `-NoNumberConversion *` Parameter verwenden |
| Nested `Where-Object {}` in `@{}` | PS 5.1 Parser-Bug | Komplexe Expressions in Variable vor Hashtable auslagern |

## 14. PS7 Runtime-Support (`.RUNTIME` Metadata)

### Übersicht

Extensions können optional in PowerShell 7 (pwsh.exe) ausgeführt werden. Die GUI (Main.ps1) bleibt auf PS 5.1 — nur die Extension selbst läuft als Child-Process in PS7.

### `.RUNTIME` Werte

| Wert | Bedeutung | Ausführung |
|---|---|---|
| `PS5` (Default) | Nur PowerShell 5.1 | In-Process Background-Runspace |
| `PS7` | Nur PowerShell 7 | Child-Process `pwsh.exe` via `Invoke-PS7Extension.ps1` |
| `PS5\|PS7` | Beides möglich | PS7 bevorzugt wenn `pwsh.exe` verfügbar, Fallback PS5 |

### Architektur

```
Main.ps1 (PS 5.1 WPF)
├── PS5-Extension: [powershell]::Create() + Runspace (in-process)
└── PS7-Extension: Start-Process pwsh.exe
    └── Core/Invoke-PS7Extension.ps1 (Wrapper)
        ├── Lädt Core-Module (HU.Logging, HU.Graph, etc.)
        ├── Dot-sources Extension, findet Invoke-* Funktion
        ├── Schreibt Logs in GLEICHE Datei → GUI DispatcherTimer pollt
        └── Schreibt Result als JSON in Temp-Datei → Main.ps1 liest aus
```

### Wann PS7 verwenden?

- Extension nutzt PS7-only Features: `??`, `?.`, `ForEach-Object -Parallel`, Ternary `? :`
- Extension braucht neuere .NET APIs (z.B. `System.Text.Json`)
- Performance-kritische Datenverarbeitung (PS7 ist ~3x schneller)
- Module die nur PS7 unterstützen

### Metadata-Beispiel (PS7)

```powershell
<#
.SYNOPSIS
    PS7 Feature-Test

.DESCRIPTION
    Testet PS7-spezifische Features.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    Common

.TARGETS
    ["Schule-A", "Schule-B", "Schule-C"]

.BATCH_CAPABLE
    $true

.DRY_RUN_CAPABLE
    $true

.RUNTIME
    PS7

.EXAMPLE
    . .\Common-PS7Test.ps1
    Invoke-PS7Test -TenantKey "Meine-Schule" -Token $token
#>
```

### GUI-Kennzeichnung

Die GUI zeigt ein Runtime-Badge neben dem Extension-Titel:

| Runtime | Badge | Farbe |
|---|---|---|
| `PS5` | (kein Badge) | — |
| `PS7` | `PS7` | Grün (#4CAF50) |
| `PS5\|PS7` | `PS5\|PS7` | Blau (#2196F3) |

### Cancel-Verhalten

| Runtime | Cancel-Mechanismus |
|---|---|
| PS5 | `$bgPowerShell.Stop()` — Pipeline wird abgebrochen |
| PS7 | `$bgProcess.Kill()` — Child-Process wird terminiert |

### Voraussetzungen

- `pwsh.exe` muss im PATH verfügbar sein (wird bei Extension-Start geprüft mit `Get-Command pwsh`)
- Wenn `pwsh.exe` nicht gefunden wird und Runtime = `PS7`: Extension startet nicht, Fehlermeldung im Log
- Wenn `pwsh.exe` nicht gefunden wird und Runtime = `PS5|PS7`: Fallback auf PS5 In-Process

### PS7-spezifische Syntax (erlaubt bei `.RUNTIME PS7`)

```powershell
# Null-Coalescing
$name = $device.deviceName ?? 'Unknown'

# Null-Conditional
$count = $result?.Items?.Count

# Ternary
$status = $isCompliant ? 'OK' : 'FAIL'

# Parallel ForEach
$devices | ForEach-Object -Parallel {
    # ... parallel processing ...
} -ThrottleLimit 10

# Pipeline Chain
Get-Data || Write-Error "No data"
```

### Checkliste für PS7 Extensions

- [ ] `.RUNTIME PS7` oder `.RUNTIME PS5|PS7` im Metadata-Header
- [ ] Keine PS 5.1-only Patterns (z.B. `New-Object -ComObject`)
- [ ] Getestet mit `pwsh.exe` lokal
- [ ] Alle Core-Funktionen (Write-HULog, Invoke-GraphRequest etc.) funktionieren identisch in PS7
- [ ] Cancel via Process.Kill() getestet

## 15. Interactive Extensions (`.MODE` + `.PARAM`)

### Übersicht

Extensions können über `.MODE ReadWrite` als schreibend gekennzeichnet werden und über `.PARAM` eigene Eingabeparameter definieren. Die GUI rendert automatisch Input-Felder und zeigt Warnungen bei Write-Operationen.

### `.MODE` Werte

| Wert | Bedeutung | GUI-Verhalten |
|---|---|---|
| `ReadOnly` (Default) | Nur lesen, kein Schreibzugriff | Normaler Start |
| `ReadWrite` | Extension kann Änderungen am Tenant vornehmen | Oranges Badge `READ/WRITE` + zusätzlicher Bestätigungsdialog vor Live-Ausführung |

### `.PARAM` Syntax

Jeder Parameter auf einer eigenen Zeile im Format:

```
Name|Type|Label|Default|Choices
```

| Feld | Pflicht | Beschreibung |
|---|---|---|
| `Name` | Ja | Parameter-Name (muss dem `param()` Block der Funktion entsprechen) |
| `Type` | Ja | `string`, `int`, `bool`, `choice` |
| `Label` | Ja | Anzeige-Label in der GUI |
| `Default` | Nein | Standard-Wert (bei bool: `$true`/`$false`) |
| `Choices` | Nur bei `choice` | Semicolon-separierte Auswahl-Optionen |

### Metadata-Beispiel (ReadWrite mit Parameters)

```powershell
<#
.SYNOPSIS
    Benutzer-Lizenzen verwalten

.DESCRIPTION
    Weist M365-Lizenzen zu oder entfernt sie fuer einen Benutzer.

.REQUIRED_PERMISSIONS
    User.ReadWrite.All
    Directory.ReadWrite.All

.REQUIRED_ROLES
    Global Administrator

.CATEGORY
    User

.TARGETS
    ["Schule-A", "Schule-B", "Schule-C"]

.BATCH_CAPABLE
    $false

.DRY_RUN_CAPABLE
    $true

.MODE
    ReadWrite

.PARAM
    UserUPN|string|Ziel-Benutzer (UPN)|
    Action|choice|Aktion|Assign|Assign;Remove
    SkuName|string|Lizenz-SKU|STANDARDPACK

.RUNTIME
    PS5

.EXAMPLE
    . .\User-LicenseManagement.ps1
    Invoke-LicenseManagement -TenantKey "Meine-Schule" -Token $token -UserUPN "user@meine-schule.at" -Action "Assign"
#>

function Invoke-LicenseManagement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [string]$UserUPN,

        [ValidateSet('Assign', 'Remove')]
        [string]$Action = 'Assign',

        [string]$SkuName = 'STANDARDPACK',

        [switch]$WhatIf
    )

    # ... Implementierung ...
}
```

### GUI-Darstellung

Wenn eine Extension `.PARAM`-Einträge hat, erscheint unter den Permissions ein **"Extension Parameters"**-Panel mit:

| Type | GUI-Control |
|---|---|
| `string` | TextBox (Freitext-Eingabe) |
| `int` | TextBox (wird als Integer geparsed) |
| `bool` | CheckBox |
| `choice` | ComboBox (Dropdown mit vordefinierten Optionen) |

### Parameter-Übergabe

Die GUI sammelt die Werte und übergibt sie automatisch an die Extension-Funktion. Bedingung: Der `Name` im `.PARAM` muss **exakt** dem Parameter-Namen im `param()` Block entsprechen. Unbekannte Parameter werden ignoriert.

**PS5-Runspace:** Parameter werden als Hashtable via `Invoke-ExtensionScript -CustomParameters @{...}` übergeben.

**PS7-Process:** Parameter werden als JSON-Temp-Datei an `Invoke-PS7Extension.ps1 -CustomParamsFile` übergeben.

## 16. HTML-Dashboard Design Standard (v1.0)

Extensions mit Audit- oder Report-Funktionalität SOLLEN ein HTML-Dashboard generieren, das sich im Default-Browser öffnet.

### Design Tokens (CSS Custom Properties)

```css
:root {
    --bg-body: #0f172a;           /* Dunkelblauer Hintergrund */
    --bg-card: #1e293b;           /* Karten-Hintergrund */
    --bg-header: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    --border: #334155;            /* Rahmen */
    --text-primary: #e2e8f0;      /* Primärtext */
    --text-secondary: #94a3b8;    /* Sekundärtext, Labels */
    --text-muted: #64748b;        /* Dezenter Text */
    --text-bright: #f8fafc;       /* Heller Text */
    --accent-blue: #60a5fa;       /* Links, Highlights */
    --accent-blue-bg: #1e3a5f;    /* Badge-Hintergrund */
    --color-ok: #10b981;          /* Erfolg-Grün */
    --color-ok-bg: #064e3b;       /* Badge OK */
    --color-fail: #ef4444;        /* Fehler-Rot */
    --color-fail-bg: #7f1d1d;     /* Badge Fail */
    --color-manual: #f59e0b;      /* Warnung-Orange */
    --color-manual-bg: #78350f;   /* Badge Manual */
    --radius-lg: 12px;            /* Header, große Cards */
    --radius-md: 10px;            /* KPI, Table-Wrap */
    --radius-sm: 8px;             /* Area Cards */
    --radius-xs: 4px;             /* Badges */
}
```

### Pflicht-Layout-Elemente

Jedes Dashboard MUSS folgende Sektionen in dieser Reihenfolge enthalten:

| # | Sektion | CSS-Klasse | Beschreibung |
|---|---------|-----------|-------------|
| 1 | **Header** | `.header` | Titel + Shield-Icon links, Tenant + Datum + Version rechts |
| 2 | **KPI-Karten** | `.kpi-row` | Gesamtstatus (farbig), OK, Fehlt, Manuell, Gesamt |
| 3 | **Progress Bar** | `.progress-section` | Compliance-Fortschritt in Prozent |
| 4 | **Bereich-Übersicht** | `.areas-section` | Farbige Cards je Prüfbereich mit Icon + Stats |
| 5 | **Detail-Tabelle** | `.table-section` | Alle Ergebnisse mit Status-Badges |
| 6 | **Referenzen** | `.ref-section` | Links zu relevanten Vorgabe-Dokumenten |
| 7 | **Footer** | `.footer` | Tool-Name + Generierungs-Datum |

### Status-Badges

```html
<span class="badge ok">✓ Vorhanden</span>
<span class="badge fail">✗ Fehlt</span>
<span class="badge manual">⚠ Manuell prüfen</span>
<span class="badge unknown">? Unbekannt</span>
```

### Portal Deep-Links

Wenn die Extension `ResourceId` und `ResourceType` in `New-CheckResult` setzt, werden die Namen als klickbare Links zum jeweiligen Portal dargestellt.

Unterstützte ResourceTypes und deren URL-Pattern:

| ResourceType | Portal | URL-Pattern |
|---|---|---|
| `entraGroup` | Entra ID | `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/{id}` |
| `configurationPolicy` | Intune Settings Catalog | `https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/ConfigurationMenuBlade/~/overview/configurationId/{id}` |
| `deviceConfiguration` | Intune Legacy Config | `https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/DevicesConfigurationMenu/~/overview/configurationId/{id}` |
| `intent` | Intune Endpoint Security | `https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/IntentCustomDetailBlade/~/overview/intentId/{id}` |
| `defender` | Defender Portal | `https://security.microsoft.com/webcontentfilteringpolicy` |

### Interaktive Manuelle Checks

Items mit `Status = "Manuell pruefen"` erhalten eine Checkbox. Beim Abhaken:
- Zeile wird visuell als erledigt markiert (Opacity + grüner Badge)
- KPI-Karten werden live via JavaScript aktualisiert (OK +1, Manuell -1)
- Progress-Bar und Gesamtstatus werden neu berechnet
- Bei allen manuellen Checks abgehakt → Gesamtstatus kann auf COMPLIANT wechseln

### Erweiterte Mitglieder-Spalte

Für Entra-Gruppen zeigt die Mitglieder-Spalte:
- **Direktzahl** fett in Blau (`.member-count`)
- **Detail-Aufschlüsselung** darunter klein (`.member-detail`): z.B. "2 Devices, 1 Gruppe (→ 312 Geräte)"

### Print-Stylesheet

Jedes Dashboard MUSS `@media print` Styles enthalten, die Dark Mode → Light Mode konvertieren für Ausdrucke und PDF-Exporte.

### Checkliste für Interactive Extensions

- [ ] `.MODE ReadWrite` im Metadata-Header
- [ ] `.PARAM` Einträge mit korrekten Namen (müssen zum `param()` Block passen)
- [ ] `[switch]$WhatIf` PFLICHT für ReadWrite-Extensions (DryRun als Sicherheitsnetz)
- [ ] DryRun-Logik implementiert (zeigt was passieren WÜRDE)
- [ ] Permissions mit `.ReadWrite.All` statt `.Read.All`
- [ ] Alle Write-Operationen im DryRun nur geloggt, nicht ausgeführt
- [ ] Bestätigungs-Log vor jeder Schreiboperation: `Write-HULog "Executing: POST /users/..." -Level 'WARN'`

## 17. Vom Handy starten (Fernbedienung)

Erweiterungen erscheinen in der Handy-Fernbedienung erst nach Freigabe am PC (Knopf **Remote FB** › *Freigaben fürs Handy*). Gestartet wird am PC, je gewähltem Tenant (höchstens 5) in einem eigenen Runspace, mit `Invoke-ExtensionScript` wie im Reiter Extensions.

- nur Windows PowerShell 5.1 – Erweiterungen mit `.RUNTIME PS7` sind am Handy nicht verfügbar
- `.MODE ReadWrite` gilt immer als *ändert Daten*; mit `.DRY_RUN_CAPABLE` erscheint am Handy der Schalter *Probelauf* (Standard an = `-WhatIf`), ohne ihn ist jeder Lauf ein **echter Lauf** (Kürzel + PIN)
- `.PARAM`-Felder erscheinen am Handy (Typen wie im Reiter Extensions)
- Ausgabe: alles, was über `Write-HULog` (ab INFO) ins Protokoll geht, erscheint live am Handy; Reports bleiben am PC (der Dateiname wird gemeldet)
- keine Dialoge oder Eingaben – vom Handy sieht sie niemand
- nach jeder Änderung an der Datei ist die Freigabe ungültig, bis sie am PC neu gespeichert ist (Fingerabdruck)

## 18. Skill und Prüfprogramm (`skills/hu-extension`)

Der Ordner `skills/hu-extension` enthält alles, damit eine Extension beim ersten Versuch lädt und läuft – für Menschen ebenso wie für Assistenzprogramme, die den Code schreiben:

| Datei | Inhalt |
|---|---|
| `SKILL.md` | Anleitung in Kurzform: Kopf, Funktion, Graph-Aufrufe, Probelauf, Fallen, Checkliste, beide Vorlagen |
| `templates/` | die zwei geprüften Vorlagen (Bericht, Aktion) |
| `tools/Test-HUExtension.ps1` | statisches Prüfprogramm (Regeln E01–E16): Kopfblock, Funktionsname, `$WhatIf`/`SupportsShouldProcess`, `.PARAM`↔Parameter, Graph-Aufrufe, `throw`, Probelauf, Rechte |

```powershell
# Zielmaschine: beliebiger PC mit Windows PowerShell 5.1 oder PowerShell 7 (es wird nichts ausgeführt oder verbunden)
powershell -NoProfile -File skills\hu-extension\tools\Test-HUExtension.ps1 -Path .\Device-MeineExtension.ps1
```

`FEHLER` heißt: lädt nicht, läuft nicht oder ist unsicher. `WARNUNG`: prüfen. Weitergabe an ein Assistenzprogramm: den Ordner als Skill hinzufügen oder `SKILL.md` mitgeben – Einzelheiten in [skills/README.md](skills/README.md).
