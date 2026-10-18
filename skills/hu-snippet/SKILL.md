---
name: hu-snippet
description: Schreibt, prüft und ändert Quick-Script-Snippets für HU-MultiTenant (Windows PowerShell 5.1, Microsoft Graph, mehrere M365/Intune-Tenants). Verwenden, wenn ein Snippet, Quick Script oder "Meldung aus Skript" für HU-MultiTenant entstehen oder ein vorhandenes Skript dafür übernommen werden soll.
---

# HU-MultiTenant: Quick-Script-Snippets schreiben

Ein Snippet ist ein einzelnes PowerShell-Skript, das HU-MultiTenant für einen oder mehrere Tenants ausführt. Es hat feste Regeln der Laufzeit. Wer sie nicht einhält, bekommt ein Skript, das nicht startet, nichts anzeigt oder im Probelauf trotzdem ändert. Diese Anleitung enthält nur Regeln, die gegen den Programmcode geprüft sind, drei lauffähige Vorlagen und ein Prüfprogramm.

## Vorgehen (in dieser Reihenfolge)

1. **Aufgabe einordnen:** nur lesen (Vorlage 1), etwas ändern (Vorlage 2) oder eine Teams-Meldung senden (Vorlage 3).
2. **Vorlage kopieren** und anpassen. Nicht aus dem Gedächtnis schreiben: Abschnitt "Typische Fehler" zeigt, was dabei regelmäßig schiefgeht.
3. **Rechte bestimmen:** genaue Graph-Namen der Anwendungsberechtigungen, die die Endpunkte brauchen (Microsoft Learn: Graph-Berechtigungsreferenz). Nichts erfinden, im Zweifel nachschlagen.
4. **Prüfen** (Abschnitt "Prüfen"). Fehler beheben, Warnungen lesen und begründet beheben oder bewusst lassen.
5. **Abgeben:** die `.ps1`-Datei (UTF-8). Zusätzlich Hinweis, welche Rechte der Tenant braucht und ob das Snippet etwas ändert.

Ohne Möglichkeit, das Prüfprogramm auszuführen, die Checkliste am Ende Punkt für Punkt von Hand durchgehen und das in der Antwort sagen.

## Laufzeit (Fakten)

- eigener Runspace, **Windows PowerShell 5.1**, kein PowerShell 7
- bei mehreren gewählten Tenants läuft das Skript **einmal je Tenant nacheinander**; ein Fehler beendet nur den laufenden Tenant
- Rechte = **Anwendungsberechtigungen** der App-Registrierung des Tenants (keine delegierten Rechte, kein Benutzerkontext)
- geladen sind `HU.Auth`, `HU.Graph`, `HU.Notify` und die Laufzeit-Hüllen der Graph-Funktionen. **Nicht vorhanden:** `Write-HULog*`, `Get-Settings`, `Get-TenantByKey`, `Get-AllTenants`, die Excel-Funktionen (`Initialize-HUExcel` usw.)
- ohne Bildschirm: `Read-Host`, `Out-GridView`, `Get-Credential` und Dialoge lassen den Lauf hängen
- `Connect-*` (Exchange Online, Mg-Module) geht nicht

| Variable | Inhalt |
|---|---|
| `$Token` | Access Token des laufenden Tenants |
| `$TenantKey`, `$Schule` | Schlüssel des laufenden Tenants (z. B. `Schule-1`) |
| `$Settings` | Einstellungen, u. a. `$Settings.tenants` (`key`, `displayName`, `tenantId`, `appId`) |
| `$AppRoot` | Programmordner |
| `$Name` | je `# @param Name|...`-Zeile der Wert des Eingabefelds |
| `$Tenants` | nur bei Meldungen "einmal" und vom Handy: Schlüssel aller gewählten Tenants |

Diese Variablen nie neu zuweisen (auch nicht als `foreach`-Schleifenvariable). `Get-HUToken -Tenant <Schlüssel>` liefert das Token eines anderen Tenants.

## Kopf und Eingabefelder

```
# Kurzbeschreibung (erste Zeile)
# Berechtigungen: Recht1.Read.All, Recht2.ReadWrite.All
# @param Name|Typ|Beschriftung|Standard|Auswahl1;Auswahl2
```

- Zeile 1 = Kurzbeschreibung als Kommentar, Zeile 2 = `# Berechtigungen:` mit exakten Graph-Namen, durch Komma getrennt (`keine`, wenn nichts nötig ist; Erklärungen nur in Klammern dahinter)
- Typen: `bool` (Haken, Standard `true`/`false`), `int` (ganze Zahl), `string`, `choice` (5. Feld = Liste mit `;`, Standard muss darin stehen)
- Feldtrennzeichen ist `|`: es darf in Beschriftung und Standard nicht vorkommen. Listen als Text mit `;` und im Code zerlegen:
  `$Liste = @($ListeText -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })`
- Namen: Buchstaben, Ziffern, Unterstrich; nicht `Token`, `TenantKey`, `Schule`, `Settings`, `AppRoot`, `Tenants` und keine PowerShell-Automatikvariablen (`Input`, `Args`, `Error`, `Host`, `Matches` ...)
- Die Variable im Code **nicht neu zuweisen**, sonst wirkt das Feld nicht. Eigene Variable verwenden.
- Kein `param()`, kein `#Requires`, kein Dot-Source, kein `Import-Module` der HU-Module. Werte, die der Anwender ändern soll, als `# @param`, nicht als `$Wert = ...` oben im Code.

## Graph-Aufrufe

| Funktion | Parameter | Rückgabe |
|---|---|---|
| `Invoke-GraphRequest` (Alias `Invoke-AdminGraphRequest`) | `-Token -Endpoint [-Method] [-Body] [-ApiVersion] [-ContentType]` | die Antwort, bei HTTP-Fehler ein **Fehlerobjekt** (s. u.) |
| `Invoke-GraphRequestWithRetry` | `-Token -Endpoint [-Method] [-Body] [-TenantKey] [-Settings] [-MaxRetries] [-ApiVersion]` | wie oben; wiederholt bei 429/5xx |
| `Invoke-GraphRequestAll` | `-Token -Endpoint [-TenantKey] [-Settings] [-MaxPages]` | alle Einträge aus `value` über alle Seiten (nur Listen-Endpunkte) |

Regeln, die man leicht übersieht:

1. **Kein Fehler als Ausnahme.** `Invoke-GraphRequest` und `...WithRetry` werfen bei HTTP-Fehlern nicht. Sie liefern ein Objekt mit `IsError`, `StatusCode`, `ErrorMessage`, `Endpoint`, `Method`. Jedes Ergebnis eines **ändernden** Aufrufs daraufhin prüfen (Vorlage 2: Hilfsfunktion `Test-FehlerAntwort`). Ein Aufruf, dessen Ergebnis verworfen wird, meldet Misserfolg nie.
2. **`...All` nur für Listen.** Für Einzelobjekte (`/users/<id>`, `/organization/<id>`, `/me`) liefert `Invoke-GraphRequestAll` **nichts**. Dort `Invoke-GraphRequest`.
3. **`...All` bricht still ab.** Schlägt eine Folgeseite fehl, kommen die bisherigen Einträge plus eine **Warnung**, aber keine Ausnahme. Immer `-WarningVariable wv -WarningAction SilentlyContinue` anhängen und bei `$wv` abbrechen (Vorlagen). Vor ändernden Aufrufen ist das Pflicht, sonst ändert das Skript auf Grundlage einer unvollständigen Liste.
4. **Nur diese Methoden:** `GET` (Standard), `POST`, `PATCH`, `DELETE`. Kein `PUT`. `-Body` nur bei `POST`/`PATCH`.
5. **`-Body` ist eine Hashtable** (`@{ accountEnabled = $false }`), nie JSON-Text und nicht mit `ConvertTo-Json` (die Funktion wandelt selbst um, Tiefe 10).
6. **Keine eigenen Header.** Es gibt kein `-Headers`/`-Uri`. Damit sind `ConsistencyLevel: eventual`, `$count=true` und `$search` nicht möglich: clientseitig filtern.
7. **Endpunkt:** relativ (`'/users?$select=id,displayName'` = v1.0) oder absolut `https://graph.microsoft.com/...`. Version nicht in den Pfad schreiben; `beta` über `-ApiVersion beta` (nicht bei `...All`) oder über die absolute Adresse `https://graph.microsoft.com/beta/...`. **Niemals** eine fremde `https://`-Adresse: eine absolute Adresse wird unverändert aufgerufen, das Token ginge mit.
8. **`$select`, `$filter`, `$top`** nur in **einfachen** Anführungszeichen schreiben (`'/users?$top=5'`). In doppelten liest PowerShell `$top` als Variable. Werte in Filtern mit `[uri]::EscapeDataString(...)` kodieren, einfache Anführungszeichen im Wert verdoppeln (`-replace "'", "''"`).
9. **Kein `Invoke-RestMethod` gegen Graph.** Token-Erneuerung bei langen Läufen und Wiederholung stecken nur in den drei Funktionen.
10. 204/leere Antwort bei `POST`/`PATCH`/`DELETE` ist normal (kein Fehler, Ergebnis ist leer).

## Ausgabe

- Ergebnisse als `[pscustomobject]` **ausgeben** (landen in der Tabelle mit Filter, CSV, Excel; bei mehreren Tenants kommt die Spalte *Tenant* von selbst dazu). Kein `Format-Table`, `Format-List`, `Out-String`.
- Meldungen: `Write-Host ... -ForegroundColor`, `Write-Warning`, `Write-Error` (rot, mit Zeilennummer).
- Methoden, die Werte zurückgeben (`ArrayList.Add`, `HashSet.Add`), mit `[void]` oder `| Out-Null` schlucken, sonst landet die Zahl in der Tabelle.
- Nichts ausgeben, was nicht jeder sehen darf: **nie `$Token`** oder Secrets in Text, Tabelle oder Karte.
- Nur ASCII im Code (`ae`, `oe`, `ue`, `ss`; Emoji über `[char]::ConvertFromUtf32(0x1F7E2)`), sonst droht Zeichensalat unter Windows PowerShell 5.1.

## Snippets, die etwas ändern

- `# @param DryRun|bool|Probelauf (nur anzeigen)|true`: Name aus `DryRun`, `WhatIf`, `Simulation`, `Simulate`, `Test`, `TestMode`, `Probelauf`, `NurAnzeigen`, `Preview`. Haken **aus** = echter Lauf; erst daran erkennt das Programm den echten Lauf und fragt vor dem Start nach (auch vom Handy aus).
- **Jeder** ändernde Aufruf steht hinter der Abfrage (`if ($DryRun) { ...anzeigen... } else { ...ändern... }`) oder wird vorher mit `continue`/`return` übersprungen.
- Standard des Schalters ist `true`.
- Vor dem Ändern: Liste vollständig lesen (Regel 3), Ziel eindeutig bestimmen (keine Teilzeichenfolgen, die mehr treffen), Ergebnis je Aufruf prüfen (Regel 1) und im Ergebnisobjekt melden.
- Nie eine Bestätigung per `Read-Host` einbauen: den Schalter benutzen.

## Meldung nach Teams ("Meldung aus Skript")

`Send-HUNotify -Title <Text> [-Level OK|Warning|Error|Info] [-Lines <Text[]>] [-Facts <geordnete Hashtable>] [-Rows <Liste aus @{Name;Status;Text}>] [-Preview <Text>] [-WhatIf]` sendet eine Karte an die Ziele der Meldung, zu der das Snippet gehört (Reiter Teams). Rückgabe: `.Text`, `.Ok`, `.Failed`. Wirft nie.

- nur **Anzahlen** in die Karte, keine Personen- oder Gerätenamen (Namen mit `Write-Host` nur ins Protokoll)
- keine Secrets, Kennwörter oder Token in Karten
- nie `Grant-HUSendApproval`, `Set-HUNotifyRoute` und ähnliche Freigabefunktionen aufrufen
- nach jeder Änderung am Snippet die Meldung im Reiter Teams neu speichern

## Typische Fehler

| Falsch | Richtig |
|---|---|
| `Invoke-GraphRequest -Uri ... -Headers ...` | `-Token $Token -Endpoint '/...'` |
| `Invoke-RestMethod https://graph.microsoft.com/...` | `Invoke-GraphRequest` / `Invoke-GraphRequestAll` |
| `-Endpoint '/v1.0/users'` oder `'/beta/users'` | `'/users'`; beta: `-ApiVersion beta` |
| `-Endpoint "/users?$top=5"` | `'/users?$top=5'` |
| `-Method PUT` | gibt es nicht; `PATCH`/`POST` verwenden |
| `-Body '{"a":1}'` oder `-Body (@{a=1} | ConvertTo-Json)` | `-Body @{ a = 1 }` |
| `Invoke-GraphRequestAll -Endpoint "/users/$id"` | `Invoke-GraphRequest` (Einzelobjekt) |
| ändernder Aufruf ohne Prüfung des Ergebnisses | `IsError` prüfen (Vorlage 2) |
| `...All` ohne `-WarningVariable` | wie in den Vorlagen |
| `$DryRun`-Zweig vertauscht (`if ($DryRun) { ändern }`) | `if ($DryRun) { anzeigen } else { ändern }` |
| `$TenantKey = ...`, `$Token = ...` | nie zuweisen |
| `param(...)` am Anfang | `# @param`-Zeilen |
| `Write-HULogInfo` | `Write-Host` (Logfunktionen gibt es nur in Extensions) |
| `Get-Settings`, `Get-AllTenants` | `$Settings`, `$TenantKey` |
| `Read-Host` für Bestätigung | `bool`-Feld `DryRun` |
| `$a = $b ?? 'x'`, `$x?.Name`, `? :` | `if (...) { } else { }` |
| `$Tage = 30` oben im Code | `# @param Tage|int|Tage|30` |

## Prüfen

Statisch, nichts wird ausgeführt oder verbunden. Auf einem Rechner mit Windows PowerShell 5.1 oder PowerShell 7:

```powershell
powershell -NoProfile -File skills\hu-snippet\tools\Test-HUSnippet.ps1 -Path .\mein-snippet.ps1
```

Ausgabe: `FEHLER` (läuft so nicht oder ist unsicher: beheben), `WARNUNG` (prüfen). Exitcode 1 bei Fehlern. Regeln:

| Regel | Prüft |
|---|---|
| S01 | Syntaxfehler |
| S02 | PowerShell-7-Syntax (`??`, `?.`, `? :`, `&&`, `-Parallel`, `-AsHashtable` ...) |
| S03 | `param()`, `#Requires`, Dot-Source |
| S04 | Laufzeitvariablen zugewiesen |
| S05 | `# @param`-Zeilen (Name, Typ, Standard, Auswahl) |
| S06 | `@param`-Variable im Code überschrieben |
| S07 | nicht verfügbare oder gefährliche Befehle (`Read-Host`, `Connect-*`, `Write-HULog*`, `Invoke-Expression`, `Invoke-RestMethod` gegen Graph ...) |
| S08 | Graph-Aufrufe: Parameter, Methode, Body, Endpunkt, Anführungszeichen |
| S09 | `Send-HUNotify`: Parameter, Level, Namen in Karten |
| S10 | `$Token` ausgegeben oder in Text gebaut |
| S11 | ändernde Aufrufe ohne (oder mit vertauschtem) Probelauf-Schalter |
| S12 | `IsError` nicht geprüft, Ergebnis verworfen, `...All` ohne `-WarningVariable` |
| S13 | Rückgabewerte von `.Add()` landen in der Ausgabe |
| S14 | Kopf (Zeile 1 und 2), Rechtenamen |
| S15 | Rechte passen zu den Endpunkten (nur Hinweis) |
| S16 | Nicht-ASCII-Zeichen |

Das Prüfprogramm findet Regelverstöße, kann aber nicht wissen, ob das Skript fachlich richtig ist. Vorlage unverändert zu übernehmen heißt: sie ist geprüft. Jede eigene Abweichung selbst nachdenken und prüfen.

## Vorlagen

Jede Vorlage ist geprüft (Prüfprogramm ohne Befund) und läuft in einem automatischen Test gegen eine Graph-Attrappe.

### Vorlage 1: lesen

```powershell
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
```

### Vorlage 2: ändern (mit Probelauf)

```powershell
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
```

### Vorlage 3: Meldung nach Teams (nur Anzahlen)

```powershell
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
```

## Snippet ins Programm bringen

- einzeln: Reiter Quick Script › **Neu**, Code einfügen, **Speichern unter ...** (Name und Beschreibung)
- als Datei (mehrere auf einmal, weitergeben): **Verwalten ... › Importieren ...** mit einer JSON-Datei im Format von `Config\quick-snippets.example.json`; gleiche Namen werden auf Nachfrage ersetzt oder behalten. Erzeugen:

```powershell
@{ snippets = @(@{ name = 'Name'; category = 'Eigene'; description = 'Kurzbeschreibung'; code = [string](Get-Content .\mein-snippet.ps1 -Raw -Encoding UTF8) }) } |
    ConvertTo-Json -Depth 4 | Set-Content .\snippets.json -Encoding UTF8
```

- Snippets laufen mit den Rechten der App-Registrierung: fremde Snippets vorher lesen.

## Checkliste vor der Abgabe

- [ ] Zeile 1 Kurzbeschreibung, Zeile 2 `# Berechtigungen:` mit exakten Namen, die zu den Endpunkten passen
- [ ] kein `param()`, `#Requires`, Dot-Source, Import-Module; keine PowerShell-7-Syntax; nur ASCII
- [ ] jede einstellbare Größe ist ein `# @param`; keine Zuweisung an Feldvariablen oder Laufzeitvariablen
- [ ] jeder Graph-Aufruf: `-Token $Token -Endpoint`, Methode GET/POST/PATCH/DELETE, `-Body` Hashtable, `$`-Optionen in einfachen Anführungszeichen
- [ ] Listen mit `...All` + `-WarningVariable`, Einzelobjekte mit `Invoke-GraphRequest`
- [ ] jedes Ergebnis eines ändernden Aufrufs auf `IsError` geprüft
- [ ] ändernd: `DryRun` (Standard `true`), jeder ändernde Aufruf hinter der Abfrage
- [ ] Ergebnisse als `[pscustomobject]`; `$Token` nirgends ausgegeben; in Teams-Karten nur Anzahlen
- [ ] Prüfprogramm ohne FEHLER
