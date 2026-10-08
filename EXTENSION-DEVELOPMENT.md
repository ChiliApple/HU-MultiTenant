# HU-MultiTenant — Extensions entwickeln

**Zweck:** Dieses Dokument ist die verbindliche Spezifikation für die Entwicklung von Extensions für HU-MultiTenant. Jede Regel hier basiert auf tatsächlich aufgetretenen Fehlern in Produktion.

**Stand:** v2.0 | **Zielgruppe:** Administratoren, die eigene Reports oder Aktionen bauen | **Runtime:** PowerShell 5.1 (Standard), PowerShell 7 (optional via `.RUNTIME`)

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
- `[switch]$WhatIf` NUR wenn `.DRY_RUN_CAPABLE = $true`
- **NIEMALS `[switch]$Verbose` deklarieren** — `[CmdletBinding()]` stellt `-Verbose` automatisch bereit. Manuelle Deklaration verursacht: `"Parameter mit dem Namen verbose wurde mehrfach definiert."`
- Rückgabewert: `[PSCustomObject]` mit mindestens `Success = $true/$false`

## 5. Verfügbare Core-Funktionen

Die Extension wird per dot-source in den Kontext geladen. Folgende Module sind automatisch verfügbar:

### HU.Logging

```powershell
# IMMER Write-HULog verwenden, NIEMALS Write-Host oder Write-Output
Write-HULog -Message 'Text' -Level 'INFO' -Tenant $TenantKey

# Verfügbare Level: OK, WARN, ERROR, INFO, DEBUG
# Tenant-Parameter ist optional aber EMPFOHLEN (erscheint als [TenantKey] im Log)
```

**WICHTIG:** `Write-Host` und `Write-Output` sind VERBOTEN in Extensions. Sie funktionieren nicht im Background-Thread und erzeugen keine Ausgabe in der GUI. Nur `Write-HULog` ist sichtbar.

### HU.Graph

```powershell
# Einzelner Request (ohne Retry)
$result = Invoke-GraphRequest -Token $Token -Endpoint '/deviceManagement/managedDevices' -Method GET

# Mit Retry (429/5xx, Exponential Backoff) — EMPFOHLEN
$result = Invoke-GraphRequestWithRetry -Token $Token -Endpoint '/deviceManagement/managedDevices' -TenantKey $TenantKey -Settings (Get-Settings)

# Automatische Pagination (alle Seiten sammeln) — FÜR GROSSE DATENMENGEN
$allItems = Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices' -TenantKey $TenantKey -Settings (Get-Settings)

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

### HU.Tenant

```powershell
$settings = Get-Settings                        # Globales Settings-Objekt
$tenant = Get-TenantByKey -TenantKey $TenantKey # Einzelner Tenant (.Key, .TenantId, .AppId, .Domain)
$allTenants = Get-AllTenants                     # Alle Tenants
```

### HU.Excel (Report-Generierung)

```powershell
# ImportExcel-Modul prüfen/installieren (am Anfang der Extension aufrufen)
if (-not (Initialize-HUExcel)) {
    Write-HULog -Message 'ImportExcel nicht verfuegbar' -Level 'ERROR' -Tenant $TenantKey
    return [PSCustomObject]@{ Success = $false; Error = 'ImportExcel not available' }
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

**WICHTIG:** Alle Excel-Reports verwenden ImportExcel (EPPlus-basiert). Excel-COM-Interop (`New-Object -ComObject Excel.Application`) ist **NICHT** mehr zulässig. Kein `Set-ExcelCellValue`, kein `ReleaseComObject`, kein COM-Cleanup nötig.

## 6. Extension-Struktur (Vollständiges Template)

```powershell
<#
.SYNOPSIS
    Kurze Beschreibung

.DESCRIPTION
    Detaillierte Beschreibung.

.REQUIRED_PERMISSIONS
    DeviceManagementManagedDevices.Read.All

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
    . .\MeineExtension.ps1
    Invoke-MeineExtension -TenantKey "Meine-Schule" -Token $token
#>

function Invoke-MeineExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantKey,

        [Parameter(Mandatory)]
        [string]$Token,

        [switch]$WhatIf
    )

    # ================================================================
    # 1. PERMISSION VALIDATION
    # ================================================================
    Write-HULog -Message 'Validating permissions...' -Level 'INFO' -Tenant $TenantKey

    $requiredPerm = 'DeviceManagementManagedDevices.Read.All'
    if (-not (Test-GraphPermission -Token $Token -Permission $requiredPerm)) {
        Write-HULog -Message "Missing permission: $requiredPerm" -Level 'ERROR' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = "Missing permission: $requiredPerm" }
    }
    Write-HULog -Message 'Permissions OK' -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 2. DRY-RUN CHECK
    # ================================================================
    if ($WhatIf) {
        Write-HULog -Message 'DRY-RUN: Simuliere Ausführung...' -Level 'WARN' -Tenant $TenantKey
        # ... Simulation ...
        return [PSCustomObject]@{ Success = $true; DryRun = $true; Message = 'Simulation abgeschlossen' }
    }

    # ================================================================
    # 3. DATEN ABRUFEN
    # ================================================================
    Write-HULog -Message 'Fetching data...' -Level 'INFO' -Tenant $TenantKey

    $result = Get-ManagedDevices -Token $Token -TenantKey $TenantKey -Settings (Get-Settings)
    if (-not $result -or $result.Count -eq 0) {
        Write-HULog -Message 'No data found.' -Level 'WARN' -Tenant $TenantKey
        return [PSCustomObject]@{ Success = $false; Error = 'No data' }
    }

    $devices = $result.Devices
    Write-HULog -Message "$($result.Count) device(s) retrieved." -Level 'OK' -Tenant $TenantKey

    # ================================================================
    # 4. DATEN VERARBEITEN
    # ================================================================
    $counter = 0
    foreach ($item in $devices) {
        $counter++
        # Fortschritt loggen (alle 25 Items)
        if ($counter % 25 -eq 0) {
            Write-HULog -Message "[$counter/$($result.Count)] Processing..." -Level 'INFO' -Tenant $TenantKey
        }
        # ... pro Item ...
    }

    # ================================================================
    # 5. REPORT GENERIEREN (optional, siehe HU.Excel Abschnitt oben)
    # ================================================================
    # Initialize-HUExcel → Export-Excel → Format-HUExcelWorkbook → Add-HUExcelDashboard

    # ================================================================
    # 6. ERGEBNIS
    # ================================================================
    Write-HULog -Message 'Extension completed successfully.' -Level 'OK' -Tenant $TenantKey

    return [PSCustomObject]@{
        Success      = $true
        TenantKey    = $TenantKey
        ItemCount    = $result.Count
        GeneratedAt  = Get-Date
    }
}
```

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
    Write-HULog -Message 'ImportExcel nicht verfuegbar.' -Level 'ERROR' -Tenant $TenantKey
    return [PSCustomObject]@{ Success = $false; Error = 'ImportExcel not available' }
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
    return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
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
    return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
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
- [ ] Rückgabe als `[PSCustomObject]` mit `Success`-Property
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
