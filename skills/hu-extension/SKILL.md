---
name: hu-extension
description: Schreibt, prüft und ändert Extensions (Reports und Aktionen mit eigener Oberfläche im Reiter Extensions) für HU-MultiTenant (Windows PowerShell 5.1, Microsoft Graph, mehrere M365/Intune-Tenants, Excel-Berichte). Verwenden, wenn eine Extension für HU-MultiTenant entstehen oder angepasst werden soll.
---

# HU-MultiTenant: Extensions schreiben

Eine Extension ist eine einzelne `.ps1`-Datei im Ordner `Extensions\`. Das Programm liest den Kopfkommentar, zeigt die Extension im Reiter *Extensions* mit Eingabefeldern an und ruft ihre Funktion `Invoke-...` je Tenant auf. Der Lader ist streng: Eine Extension mit falschem Kopf wird **stillschweigend nicht angezeigt**, ein falsch gebauter Funktionskopf verhindert den Start, und ein Fehler, der nicht per `throw` weitergegeben wird, erscheint als "Fertig". Diese Anleitung enthält nur Regeln, die gegen den Programmcode geprüft sind, zwei lauffähige Vorlagen und ein Prüfprogramm.

Für kleine Einzelaufgaben ohne Excel-Bericht genügt meist ein Snippet (Skill `hu-snippet`). Eine Extension lohnt sich bei Berichten mit Excel/Dashboard, vielen Eingabefeldern oder wenn sie dauerhaft in der Liste stehen soll.

## Vorgehen (in dieser Reihenfolge)

1. **Aufgabe einordnen:** nur lesen/Bericht (Vorlage 1) oder ändern (Vorlage 2, mit Probelauf).
2. **Vorlage kopieren**, Datei nach Schema benennen, Funktion und Kopf anpassen.
3. **Rechte bestimmen:** genaue Graph-Namen der Anwendungsberechtigungen, die die Endpunkte brauchen. Nichts erfinden, im Zweifel nachschlagen.
4. **Prüfen** (Abschnitt "Prüfen"), Fehler beheben, Warnungen lesen.
5. **Abgeben:** die `.ps1`-Datei. Dazu Hinweis auf nötige Rechte und ob die Extension etwas ändert. Ablegen unter `Extensions\<Kategorie>\`; eigene Extensions bleiben bei Programm-Updates erhalten.

Ohne Möglichkeit, das Prüfprogramm auszuführen: Checkliste am Ende von Hand durchgehen und das in der Antwort sagen.

## Datei und Name

- Pfad: `Extensions\<Kategorie>\<Kategorie>-<Name>.ps1`. Gesucht wird in `Extensions\` einschließlich Unterordnern; `Template.ps1` wird ignoriert.
- Kategorie-Präfix: `Device-`, `Policy-`, `Security-`, `User-`, `Common-` (ohne passendes Präfix und ohne `.CATEGORY` gilt die Datei als "Uncategorized").
- Einstiegsfunktion: `Invoke-<Name ohne Kategorie>`, z. B. `Device-SyncBericht.ps1` → `Invoke-SyncBericht`. Gestartet wird die **erste** Funktion mit `Invoke-` in der Datei. **Hilfsfunktionen dürfen nicht mit `Invoke-` beginnen** (`Get-`, `Test-`, `Format-` ...).
- Kodierung: nur ASCII (`ae`, `oe`, `ue`, `ss`) oder UTF-8 **mit BOM**. Emoji über `[char]::ConvertFromUtf32(0x1F7E2)`.

## Kopfkommentar

Der **erste** Blockkommentar der Datei. Jeder Schlüssel steht **allein in einer Zeile**, der Wert darunter. Fehlt `.SYNOPSIS` (und `.DESCRIPTION`), wird die Datei übersprungen.

| Schlüssel | Inhalt |
|---|---|
| `.SYNOPSIS` | Kurzbeschreibung (erscheint in der Liste) |
| `.DESCRIPTION` | ausführlich |
| `.REQUIRED_PERMISSIONS` | **ein Recht je Zeile** (oder Komma), exakte Graph-Namen; das Programm prüft sie vor dem Start gegen das Token |
| `.REQUIRED_ROLES` | z. B. `Global Administrator` (Hinweis) |
| `.CATEGORY` | z. B. `Device` |
| `.TARGETS` | JSON-Liste erlaubter Tenant-Schlüssel, `[]` = alle |
| `.BATCH_CAPABLE` | `true`/`false`: auf mehrere Tenants nacheinander startbar |
| `.DRY_RUN_CAPABLE` | `true`/`false`: hat einen Probelauf (siehe unten) |
| `.RUNTIME` | `PS5` (Standard, Windows PowerShell 5.1) oder `PS7` (eigener Prozess, eingeschränkt: nur wenn wirklich nötig) |
| `.MODE` | `ReadOnly` (Standard) oder `ReadWrite` (fragt vor einem echten Lauf, also nicht im Probelauf, nach) |
| `.PARAM` | Eingabefelder, **eine Zeile je Feld**: `Name|Typ|Beschriftung|Standard|Auswahl1;Auswahl2` |
| `.EXAMPLE`, `.NOTES` | frei |

- `.PARAM`-Typen: `string`, `int`, `bool`, `choice` (5. Feld = Liste). Mindestens 3 Felder, sonst wird die Zeile ignoriert. Kein `|` im Text.
- Jedes `.PARAM` braucht einen **gleichnamigen Parameter** in der Funktion. Übergeben wird nur, was die Funktion deklariert; ein nicht deklariertes Feld geht verloren. Typen angleichen: `int` → `[int]`, `bool` → `[bool]` (nicht `[switch]`), `string`/`choice` → `[string]`.
- `.REQUIRED_PERMISSIONS`: ein Name je Zeile ohne Zusatztext. Ein Recht, das die Einrichtung nicht vergibt (`Config\graph-permissions.json`), muss im Tenant nachgetragen werden.

## Funktion

```powershell
function Invoke-Beispiel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TenantKey,
        [Parameter(Mandatory)] [string]$Token,
        [int]$Tage = 30,          # je .PARAM ein Parameter
        [switch]$WhatIf           # nur bei .DRY_RUN_CAPABLE true
    )
    try { ... return [pscustomobject]@{ Success = $true; ... } }
    catch { Write-HULogError "Fehlgeschlagen: $($_.Exception.Message)" -Tenant $TenantKey; throw }
}
```

1. `TenantKey` und `Token` sind Pflicht und werden immer übergeben.
2. **`[switch]$WhatIf` ist ein eigener Parameter.** Mit `[CmdletBinding()]` existieren schon `Verbose`, `Debug`, `ErrorAction`, `WarningAction`, `ErrorVariable`, `WarningVariable`, `InformationAction`, `InformationVariable`, `OutVariable`, `OutBuffer`, `PipelineVariable`. Wer einen davon zusätzlich deklariert, bekommt *"Parameter defined multiple times"* und die Extension startet nicht. **`SupportsShouldProcess` und ein eigenes `[switch]$WhatIf` zusammen** scheitern genauso (auch `$Confirm`). Deshalb: `[CmdletBinding()]` ohne `SupportsShouldProcess`, `$WhatIf` selbst deklarieren und selbst abfragen.
3. `-WhatIf` wird nur übergeben, wenn `.DRY_RUN_CAPABLE true` steht und der Anwender Probelauf wählt. `.DRY_RUN_CAPABLE true` ohne `[switch]$WhatIf` in der Funktion lässt den Aufruf scheitern; `[switch]$WhatIf` ohne `true` im Kopf wird nie gefüllt.
4. **Fehler = `throw`.** Das Programm wertet nur aus, ob eine Ausnahme kam. Ein Rückgabeobjekt `Success = $false` wird **nicht** gelesen, die Oberfläche meldet "Fertig". Der äußere `catch` loggt und endet mit `throw`.
5. Rückgabe: ein `[pscustomobject]` (Kennzahlen, Pfad des Berichts) oder nichts. Unbeabsichtigte Ausgaben (`.Add()` auf `ArrayList`) mit `[void]`/`| Out-Null` unterdrücken, sonst landen sie in der Rückgabe.

## Laufzeit (Fakten)

- Windows PowerShell 5.1, eigener Runspace im Hintergrund. Geladen: `HU.Logging`, `HU.Auth`, `HU.Tenant`, `HU.Graph`, `HU.Extensions`, `HU.Excel`, `HU.Notify`. Nichts davon importieren.
- **Protokoll:** `Write-HULogInfo`, `Write-HULogOK`, `Write-HULogWarn`, `Write-HULogError`, `Write-HULogDebug` (`-Message` als erster Wert, `-Tenant $TenantKey`). `Write-Host` und `Write-Output` erscheinen im Protokoll **nicht**. Auch `Write-HULog -Message ... -Level 'ERROR'` geht.
- `Get-Settings`, `Get-TenantByKey` und `Get-AllTenants` liefern nur in der App-Oberfläche Daten (sonst `$null` bzw. leer): nicht darauf bauen. Was die Extension braucht, kommt über `-TenantKey`, `-Token` und die `.PARAM`-Felder.
- Keine Eingaben (`Read-Host`, `Out-GridView`, Dialoge), kein `Connect-*`, kein `Invoke-Expression`.
- Nie `$Token` ausgeben, loggen oder in Dateien schreiben.

## Graph-Aufrufe

Die Funktionen aus `HU.Graph` (gleiche wie im Snippet-Skill):

| Funktion | Parameter | Rückgabe |
|---|---|---|
| `Invoke-GraphRequest` | `-Token -Endpoint [-Method] [-Body] [-ApiVersion] [-ContentType]` | Antwort oder **Fehlerobjekt** |
| `Invoke-GraphRequestWithRetry` | `-Token -Endpoint [-Method] [-Body] [-TenantKey] [-Settings] [-MaxRetries] [-ApiVersion]` | wie oben; Wiederholung bei 429/5xx, Token-Erneuerung bei 401 (mit `-TenantKey`) |
| `Invoke-GraphRequestAll` | `-Token -Endpoint [-TenantKey] [-Settings] [-MaxPages]` | alle Einträge einer Liste |

1. **Kein Fehler als Ausnahme:** `Invoke-GraphRequest`/`...WithRetry` liefern bei HTTP-Fehlern ein Objekt mit `IsError`, `StatusCode`, `ErrorMessage`. Ergebnis ändernder Aufrufe immer prüfen (Vorlage 2) und bei Fehlern am Ende mit `throw` melden.
2. **`...All` nur für Listen.** Für Einzelobjekte (`/users/<id>`, `/organization/<id>`) liefert es nichts: `Invoke-GraphRequest`.
3. **`...All` bricht still ab:** fällt eine Folgeseite aus, kommen die bisherigen Einträge plus eine Warnung. Immer `-WarningVariable wv -WarningAction SilentlyContinue` anhängen und bei `$wv` mit `throw` abbrechen. Vor ändernden Aufrufen Pflicht.
4. Immer `-TenantKey $TenantKey` mitgeben (Token-Erneuerung, Protokoll).
5. Methoden nur `GET`, `POST`, `PATCH`, `DELETE` (kein `PUT`); `-Body` nur bei `POST`/`PATCH`, als Hashtable (nicht JSON-Text, nicht `ConvertTo-Json`).
6. Keine eigenen Header (`ConsistencyLevel`, `$count`, `$search` gehen nicht): clientseitig filtern.
7. Relativer Endpunkt (`'/users?$select=id'` = v1.0) oder absolut `https://graph.microsoft.com/...`. Version nicht in den Pfad; `beta` über `-ApiVersion beta` (nicht bei `...All`) oder absolute Adresse. **Nie eine fremde `https://`-Adresse**: sie wird unverändert aufgerufen, das Token ginge mit.
8. `$select`/`$filter`/`$top` in **einfachen** Anführungszeichen. Filterwerte mit `[uri]::EscapeDataString` kodieren, `'` im Wert verdoppeln.
9. Kein `Invoke-RestMethod` gegen Graph.

## Ändernde Extensions

- `.MODE ReadWrite` **und** `.DRY_RUN_CAPABLE true` **und** `[switch]$WhatIf`.
- **Jeder** ändernde Aufruf (POST/PATCH/DELETE) steht hinter `if ($WhatIf) { ...nur melden...; continue }` bzw. `else`. Eine abgeleitete Variable ist erlaubt (`$live = -not $WhatIf -and ...`), wenn sie den Schreibzweig steuert.
- Vor dem Ändern die Liste vollständig lesen (Regel 3), das Ziel eindeutig bestimmen, je Aufruf `IsError` prüfen, zählen, am Ende bei Fehlern `throw`.
- Zusätzliche Sicherung bei gefährlichen Aktionen (Löschen): Bestätigungsfeld, das den Tenant-Schlüssel enthalten muss.
- Schreibende Rechte (`...ReadWrite...`, `...PrivilegedOperations...`) in `.REQUIRED_PERMISSIONS`.

## Excel-Bericht und Pfad

- `Initialize-HUExcel` → `$true`, wenn das Modul ImportExcel nutzbar ist; sonst Hinweis loggen und ohne Bericht weiterlaufen.
- `New-HUExcelReport -Data <Zeilen> -SheetName -ReportPath [-PrimaryKeyColumn] [-ConditionalColumns]`, danach `Add-HUExcelDashboard -WorkbookPath -TenantKey -ReportTitle -Metrics ([ordered]@{...}) -SheetDataSources @(@{ SheetName; RowCount; Description })`.
- Leere Tabellen mit Platzhalterzeile (`[pscustomobject]@{ Info = 'Keine Daten' }`), sonst Fehler beim Schreiben.
- Pfad wie in Vorlage 1: `$AppRoot` bzw. zwei Ordner über dem Skript, `reporting.outputPath` aus `Config\settings.json`, Unterordner `HU-Reports_yyyy-MM-dd`. Kein Excel-COM.

## Typische Fehler

| Falsch | Richtig |
|---|---|
| `[CmdletBinding(SupportsShouldProcess)]` + `[switch]$WhatIf` | `[CmdletBinding()]` + `[switch]$WhatIf` |
| `[switch]$Verbose` o. ä. zusätzlich deklarieren | weglassen (kommt mit `[CmdletBinding()]`) |
| `catch { return @{ Success = $false } }` | `catch { Write-HULogError ...; throw }` |
| Hilfsfunktion `Invoke-Helper` | `Get-Helper` / `Test-Helper` |
| `.DRY_RUN_CAPABLE true` ohne `$WhatIf` im Code | beides oder keins |
| `.MODE ReadOnly`, aber POST/PATCH/DELETE im Code | `.MODE ReadWrite` |
| `.PARAM Tage|int|...` ohne `[int]$Tage` | Parameter deklarieren |
| `Write-Host` für Fortschritt | `Write-HULogInfo` |
| `Get-Settings` / `Get-AllTenants` / `Get-TenantByKey` | Parameter / `-TenantKey` |
| `Invoke-GraphRequestAll` ohne `-WarningVariable` | wie in den Vorlagen |
| ändernder Aufruf ohne `IsError`-Prüfung | prüfen, zählen, `throw` |
| Kopf nicht als erster Blockkommentar, Schlüssel und Wert in einer Zeile | Schlüssel allein in der Zeile |
| mehrere Rechte in einer Zeile mit Erklärtext | ein Recht je Zeile |

## Prüfen

Statisch, es wird nichts ausgeführt oder verbunden (Windows PowerShell 5.1 oder PowerShell 7):

```powershell
powershell -NoProfile -File skills\hu-extension\tools\Test-HUExtension.ps1 -Path .\Device-MeineExtension.ps1
```

`FEHLER` = lädt nicht, läuft nicht oder unsicher (beheben). `WARNUNG` = prüfen. Exitcode 1 bei Fehlern.

| Regel | Prüft |
|---|---|
| E01 | Syntaxfehler |
| E02 | PowerShell-7-Syntax (bei `.RUNTIME PS5`) |
| E03 | Kopfblock: erster Blockkommentar, `.SYNOPSIS`, Modus, Werte, `.TARGETS`, `.PARAM`-Zeilen, Kategorie |
| E04 | Einstiegsfunktion `Invoke-*` (genau eine), `TenantKey`/`Token`, Namenskonvention |
| E05 | `$WhatIf` und `.DRY_RUN_CAPABLE` passen zusammen; doppelt definierte Parameter, `SupportsShouldProcess` |
| E06 | `.PARAM` ↔ Funktionsparameter (Namen, Typen) |
| E07 | verbotene/wirkungslose Befehle (`Read-Host`, `Connect-*`, `Write-Host`, `Get-Settings`, `Write-HULog*`-Parameter ...) |
| E08 | Graph-Aufrufe: Parameter, Methode, Body, Endpunkt, `-TenantKey` |
| E09 | äußerer `catch` endet mit `throw`; `Success = $false` wirkungslos |
| E10 | `$Token` ausgegeben oder in Text gebaut |
| E11 | `.MODE`/`.DRY_RUN_CAPABLE`/`$WhatIf` und jeder ändernde Aufruf hinter der Probelauf-Abfrage |
| E12 | `IsError` nicht geprüft, Ergebnis verworfen, `...All` ohne `-WarningVariable` |
| E13 | Rückgabewerte von `.Add()` landen in der Ausgabe |
| E14 | `.REQUIRED_PERMISSIONS`: Namen gültig und bekannt |
| E15 | Rechte passen zu den Endpunkten (nur Hinweis) |
| E16 | Nicht-ASCII-Zeichen |

Das Prüfprogramm erkennt Regelverstöße, nicht fachliche Fehler. Eine Vorlage unverändert zu übernehmen heißt: sie ist geprüft; jede eigene Abweichung selbst prüfen. Zusätzlich hilft ein Probelauf im Programm gegen einen Test-Tenant.

## Vorlagen

Beide Vorlagen sind geprüft (Prüfprogramm ohne Befund) und laufen in einem automatischen Test mit dem echten Lader und einer Graph-Attrappe.

### Vorlage 1: Bericht (nur lesen, optional Excel)

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

### Vorlage 2: Aktion (ändern, mit Probelauf)

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

## Checkliste vor der Abgabe

- [ ] Datei `Extensions\<Kategorie>\<Kategorie>-<Name>.ps1`, nur ASCII oder UTF-8 mit BOM
- [ ] Kopf ist der erste Blockkommentar; `.SYNOPSIS`, `.REQUIRED_PERMISSIONS` (ein Recht je Zeile), `.CATEGORY`, `.MODE`, `.DRY_RUN_CAPABLE`, `.PARAM`
- [ ] genau eine `Invoke-*`-Funktion mit Pflicht-`TenantKey` und `Token`; Hilfsfunktionen ohne `Invoke-`
- [ ] jedes `.PARAM` hat einen passenden Funktionsparameter; `$WhatIf` nur mit `DRY_RUN_CAPABLE true`, ohne `SupportsShouldProcess`
- [ ] Graph: `-TenantKey` mitgegeben, `...All` mit `-WarningVariable`, `IsError` geprüft, keine fremden Adressen
- [ ] ändernd: `ReadWrite`, jeder Schreibaufruf hinter `$WhatIf`, schreibende Rechte im Kopf
- [ ] äußerer `catch` loggt und endet mit `throw`
- [ ] Protokoll über `Write-HULog*`; `$Token` nirgends ausgegeben
- [ ] Prüfprogramm ohne FEHLER
