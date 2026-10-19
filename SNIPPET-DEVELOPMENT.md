# HU-MultiTenant — Snippets schreiben

Referenz für eigene Quick-Script-Snippets (ab v2.0). Gilt für eigene Snippets ebenso wie für übernommene Skripte.
Bedienung (Mehrere Tenants, Tabelle, Verlauf, Snippet-Verwaltung): [Anleitung](https://chiliapple.github.io/HU-MultiTenant/Docs/Anleitung.html#qs).
Reports mit eigener Oberfläche im Extensions-Reiter: [EXTENSION-DEVELOPMENT.md](EXTENSION-DEVELOPMENT.md).
Geprüfte Vorlagen und Prüfprogramm (auch zum Weitergeben an ein Assistenzprogramm, das Snippets schreibt): [skills/hu-snippet](skills/hu-snippet/SKILL.md), siehe Abschnitt 11.

## 1. Laufzeit

- eigener Runspace, **Windows PowerShell 5.1**, die Oberfläche bleibt bedienbar
- läuft für den gewählten Tenant – oder bei *Mehrere ▾* mit mindestens zwei Haken **einmal je Tenant** nacheinander
- ein Fehler bricht nur den laufenden Tenant ab
- Rechte: die **Anwendungsberechtigungen** der App-Registrierung (keine delegierten Rechte)

## 2. Im Skript verfügbar

| Name | Inhalt |
|---|---|
| `$Token` | Access Token des laufenden Tenants |
| `$TenantKey` / `$Schule` | Schlüssel des laufenden Tenants (z. B. `Schule-1`) |
| `$Settings` | alle Tenants: `$Settings.tenants` mit `key`, `displayName`, `tenantId`, `appId` |
| `$AppRoot` | Programmordner, z. B. `Join-Path $AppRoot 'Reports'` |
| `Invoke-GraphRequest -Token -Endpoint [-Method] [-Body] [-ApiVersion] [-ContentType] [-ThrowOnError]` | ein Graph-Aufruf, Rückgabe = Antwortobjekt – bei einem HTTP-Fehler **kein Fehler, sondern ein Objekt** mit `IsError`, `StatusCode`, `ErrorMessage` |
| `Invoke-GraphRequestAll -Token -Endpoint [-TenantKey] [-Settings] [-MaxPages]` | alle Seiten (`@odata.nextLink`), Rückgabe = Liste der `value`-Einträge – nur für **Listen** |
| `Invoke-GraphRequestWithRetry -Token -Endpoint [-Method] [-Body] [-TenantKey] [-Settings] [-MaxRetries] [-ApiVersion] [-ThrowOnError]` | wie `Invoke-GraphRequest`, wiederholt bei 429/5xx |
| `Get-HUToken [-Tenant <Schlüssel>]` | Token eines anderen Tenants |
| `Send-HUNotify -Title [-Level] [-Lines] [-Facts] [-Rows] [-Preview]` | Karte an die Ziele der Teams-Meldung, zu der das Snippet gehört (ab v2.1.10) – siehe unten |

- `-Endpoint` relativ (`'/users?$select=id,displayName'` → v1.0) oder absolut (`'https://graph.microsoft.com/beta/...'`); `beta` auch über `-ApiVersion beta` (nicht bei `Invoke-GraphRequestAll`). Eine absolute Adresse wird unverändert aufgerufen und das Token geht mit: **nur** `https://graph.microsoft.com/…`
- `$select`, `$filter`, `$top` in **einfachen** Anführungszeichen schreiben (in doppelten liest PowerShell sie als Variable); Werte in Filtern mit `[uri]::EscapeDataString(…)` kodieren
- `-Method`: `GET` (Standard), `POST`, `PATCH`, `DELETE` (kein `PUT`); `POST` ohne `-Body` schickt `{}` mit Content-Type `application/json` (z. B. `.../restore`); `-Body` nur bei `POST`/`PATCH`, als **Hashtable** (kein JSON-Text, kein `ConvertTo-Json`)
- keine eigenen Header: `ConsistencyLevel`, `$count`, `$search` gehen nicht – clientseitig filtern
- Tokens, die an diese Funktionen übergeben werden, erneuert das Programm bei langen Läufen automatisch
- **nicht** `-Uri`/`-Headers` an `Invoke-GraphRequest` übergeben – das sind Parameter von `Invoke-RestMethod`; kein `Invoke-RestMethod` gegen Graph
- **Fehlerobjekt:** `Invoke-GraphRequest`/`Invoke-GraphRequestWithRetry` werfen bei HTTP-Fehlern standardmaessig nicht; mit `-ThrowOnError` kommt stattdessen eine Exception (fuer `try/catch`). Das Ergebnis jedes **ändernden** Aufrufs auf `IsError` prüfen (siehe Vorlage „ändern“)
- **`Invoke-GraphRequestAll` nur für Listen.** Für ein Einzelobjekt (`/users/<id>`) liefert es nichts – dort `Invoke-GraphRequest`. Fällt eine Folgeseite aus, kommen die bisherigen Einträge plus eine **Warnung** (keine Ausnahme): mit `-WarningVariable wv -WarningAction SilentlyContinue` abfangen und bei `$wv` abbrechen – vor ändernden Aufrufen Pflicht
- **nicht vorhanden** im Snippet-Lauf: `Write-HULog*`, `Get-Settings`/`Get-TenantByKey`/`Get-AllTenants`, die Excel-Funktionen – dafür `Write-Host`/`Write-Warning`, `$Settings`/`$TenantKey`, Ergebnisobjekte bzw. eine Extension

## 3. Regeln

- kein `param()`, kein `#Requires`, kein Dot-Source, kein `Import-Module` der HU-Module
- keine PowerShell-7-Syntax (`??`, `?.`, `? :`, `ForEach-Object -Parallel`)
- `$TenantKey` nicht selbst setzen – der Tenant kommt aus der Auswahl bzw. *Mehrere*
- einstellbare Werte als **Parameter** (Abschnitt 4), nicht als `$Wert = …` oben im Code
- Snippets, die etwas ändern: Parameter `DryRun` mit Standard `true`; **jeder** ändernde Aufruf steht hinter der Abfrage (`if ($DryRun) { anzeigen } else { ändern }`)
- nur ASCII im Code (`ae`, `oe`, `ue`), keine Eingaben (`Read-Host`, `Out-GridView`), kein `Connect-*`
- Kopf: erste Zeile Kurzbeschreibung, zweite Zeile `# Berechtigungen: …`

## 4. Parameter

Zeilen der Form `# @param Name|Typ|Beschriftung|Standard|Auswahl` werden zu Eingabefeldern über dem Editor. Der Wert steht im Skript als `$Name`.

| Typ | Feld | Beispiel |
|---|---|---|
| `bool` | Haken | `# @param DryRun\|bool\|Probelauf (nur anzeigen)\|true` |
| `int` | Zahl | `# @param Tage\|int\|Ohne Sync seit Tagen\|30` |
| `string` | Text | `# @param Gruppe\|string\|Gruppenname\|` |
| `choice` | Auswahl | `# @param OS\|choice\|Betriebssystem\|Windows\|Windows;iOS;Android` |

- `DryRun`, `WhatIf`, `Probelauf` (Haken aus) = echter Lauf → das Programm fragt vor dem Start nach
- die Variable im Code **nicht** neu zuweisen – sonst wirkt das Feld nicht (die Ausgabe weist darauf hin)
- kein `|` im Standardwert; Listen als Text mit `;` und im Code zerlegen:
  `$Liste = @($ListeText -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })`

## 5. Ausgabe

- **Ergebnisse als Objekte** ausgeben – sie landen zusätzlich in der Tabelle (Filter, CSV, Excel); bei mehreren Tenants kommt die Spalte *Tenant* automatisch dazu
- kein `Format-Table` / `Out-String` für Ergebnisdaten
- Meldungen: `Write-Host … -ForegroundColor Cyan/Green/Yellow`, `Write-Warning`, `Write-Error` (rot, mit Zeilennummer)

## 6. Vorlage: lesen

Die Vorlagen liegen als Dateien in `skills/hu-snippet/templates/` und sind vom Prüfprogramm ohne Befund akzeptiert; ein automatischer Test lässt sie gegen eine Graph-Attrappe laufen.

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

## 7. Vorlage: ändern

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

Weitere Beispiele: Snippet-Verwaltung › **Beispiele** (Datei `Config\quick-snippets.example.json`).

### Teams-Meldung aus einem Snippet ("Meldung aus Skript")

Das Snippet entscheidet, **ob** und **was** gemeldet wird; die Meldung im Reiter **Teams** entscheidet, **an wen** und **wann**.

1. Snippet schreiben und speichern, z. B. "Drucker-Status".
2. Reiter **Teams** › Meldungen › *+ Neu* › Feld **oder Meldung aus Skript**: Snippet wählen, Ziele anhaken, Tenants wählen › *Speichern*.
3. *Jetzt senden* zum Ausprobieren, *Aufgabe anlegen* für den Zeitplan.

```powershell
$alt | ForEach-Object { Write-Host $_.deviceName }   # Geraetenamen nur ins Protokoll
$r = Send-HUNotify -Level Warning `
        -Title "$($TenantKey): $($alt.Count) Geraete ohne Sync" `
        -Preview "$($alt.Count) von $($dev.Count) Geraeten" `
        -Lines @("$($alt.Count) von $($dev.Count) Geraeten ohne Sync - Liste im Quick-Script-Verlauf")
Write-Host $r.Text          # Ergebnis je Ziel, ohne Adressen; $r.Ok / $r.Failed = Anzahl
```

- keine Kategorie nötig – jede Karte geht an die Ziele der Meldung
- nach jeder Änderung am Snippet die Meldung im Reiter Teams **neu speichern** – sonst läuft sie nicht (Fingerabdruck); `DryRun`-Standard aus = Rückfrage „ECHTER LAUF“ beim Speichern
- **Skript läuft** (Einstellung an der Meldung): *je Tenant* (Standard, mit `$TenantKey`/`$Token`) oder *einmal* – dann enthält `$Tenants` die angehakten Tenant-Schlüssel, Tokens holt das Skript selbst (`foreach ($k in $Tenants) { $t = Get-HUToken -Tenant $k; ... }`)
- **Ausgabe als Karte senden** (Einstellung an der Meldung, Standard aus): ohne `Send-HUNotify` geht die Ausgabe des Snippets (Objekte/Text, sonst die `Write-Host`-Zeilen) als **eine** Karte – kann Gerätenamen enthalten; aus = `Write-Host` nur ins Log
- geplant / *Jetzt senden*: läuft je Tenant (oder einmal, siehe oben) mit den Werten der `# @param`-Felder, die an der Meldung stehen (gleiche Felder wie im Quick Script, je Meldung gespeichert)
- im Quick-Script-Editor: gehört das Snippet zu einer Meldung, fragt HU-MultiTenant einmal (Ja / Nein = ohne Teams / Abbrechen) und sendet an deren Ziele; ohne Meldung sendet es nur, wenn es Ziele selbst nennt (`-TargetIds`, alte Kategorie) und Du mit Ja antwortest
- `-WhatIf` = nur anzeigen, was gesendet würde
- wirft nie – ein Teams-Fehler bricht das Snippet nicht ab
- `-Level` `OK` | `Warning` | `Error` | `Info`; `-Facts` als `[ordered]@{ Name = Wert }`; `-Rows` als `@{ Name; Status; Text }` (Ampel)
- `-Preview` = Text der Handy-Benachrichtigung – **keine Secrets/Kennwörter** in Karten; Gerätenamen nur in Meldungen, die ausschließlich Admin-Kanäle haben (im Zweifel nur Anzahlen senden)
- Snippets laufen mit Deinen Rechten – fremde Snippets vorher lesen; `Grant-HUSendApproval` **nie** in Snippets aufrufen (die Freigabe gibt die Rückfrage bzw. die gespeicherte Meldung)
- als Meldung: je Lauf ein eigener Runspace – `$global:`-Zwischenspeicher gelten nur für diesen Tenant
- *je Tenant* sendet jeder Tenant eine eigene Karte – für eine Sammelkarte *Skript läuft: einmal* wählen, im Skript über `$Tenants` laufen und einmal senden
- *Ausgabe als Karte* aus: `Write-Host`-Zeilen gehen (höchstens 30 je Lauf) ins Tagesprotokoll `Logs\HU-MultiTenant_<Datum>.log` – aufbewahrt `logging.retentionDays` Tage (Standard 30)
- Details und alle Parameter: Anleitung (F1) › Teams › Meldungen aus Skripten

## 8. Vorhandene Skripte übernehmen

1. `param(...)` und feste Werte oben → `# @param`-Zeilen
2. `#Requires`, Dot-Source, eigene Token-Funktionen entfernen → `$Token` bzw. `Get-HUToken -Tenant …`
3. eigene Schleife über alle Tenants entfernen → *Mehrere ▾* (außer das Skript braucht Daten aus zwei Tenants gleichzeitig)
4. `Invoke-RestMethod` gegen `graph.microsoft.com` → `Invoke-GraphRequest` / `Invoke-GraphRequestAll`
5. Ergebnislisten als `[pscustomobject]` ausgeben statt als Text
6. lokale Pfade → `string`-Parameter mit dem bisherigen Wert als Standard

## 9. Vom Handy starten

Ein Snippet erscheint in der Handy-Fernbedienung erst, wenn es am PC freigegeben ist (Knopf **Remote FB** › *Freigaben fürs Handy*: *nur lesend* oder *ändert Daten*). Danach gilt:

- läuft **je Tenant in einem eigenen Runspace** mit `$TenantKey`, `$Token`, `$Tenants` (alle gewählten) und den `@param`-Werten vom Handy – wie eine Meldung aus Skript
- die `@param`-Felder erscheinen am Handy; `choice` nur aus der Liste, `string` höchstens 256 Zeichen, eine Zeile
- *ändert Daten* = **echter Lauf** (Kürzel + PIN am Handy), außer ein Probelauf-Schalter (`DryRun`, `WhatIf`, `Probelauf` …) ist angehakt – deshalb bei ändernden Snippets immer `# @param DryRun|bool|Probelauf|true`
- Ausgabe (`Write-Host`, Objekte, Warnungen, Fehler) erscheint live am Handy; was das Skript ausgibt, sieht das Handy – also keine Secrets, Token oder Kennwörter ausgeben
- keine Eingaben (`Read-Host`, `Out-GridView`, Dialoge) – vom Handy sieht sie niemand; der Lauf hängt sonst bis zum Abbruch
- nach jeder Änderung am Code ist die Freigabe ungültig, bis sie am PC neu gespeichert ist (Fingerabdruck)
- `Send-HUNotify` sendet vom Handy nur, wenn das Snippet zu einer Teams-Meldung gehört (an deren Ziele)

## 10. Grenzen

- kein PowerShell 7 (nur Extensions mit `.RUNTIME PS7`)
- kein `Connect-ExchangeOnline` (braucht Zertifikats-Anmeldung)
- nach neuen Berechtigungen in Entra: Programm neu starten (Token-Cache)

## 11. Skill und Prüfprogramm (`skills/hu-snippet`)

Der Ordner `skills/hu-snippet` enthält alles, damit ein Snippet beim ersten Versuch läuft – für Menschen ebenso wie für Assistenzprogramme, die den Code schreiben:

| Datei | Inhalt |
|---|---|
| `SKILL.md` | Anleitung in Kurzform: Laufzeit, Kopf und Felder, Graph-Aufrufe, Probelauf, Fallen, Checkliste, drei Vorlagen |
| `templates/` | `lesen.ps1`, `aendern.ps1` (mit Probelauf), `teams-meldung.ps1` |
| `tools/Test-HUSnippet.ps1` | statisches Prüfprogramm (Regeln S01–S16): Syntax, PowerShell-7-Syntax, Felder, Graph-Aufrufe, Probelauf, `IsError`, Rechte, Token |

```powershell
# Zielmaschine: beliebiger PC mit Windows PowerShell 5.1 oder PowerShell 7 (es wird nichts ausgeführt oder verbunden)
powershell -NoProfile -File skills\hu-snippet\tools\Test-HUSnippet.ps1 -Path .\mein-snippet.ps1
```

`FEHLER` heißt: läuft so nicht oder ist unsicher. `WARNUNG`: prüfen. Weitergabe an ein Assistenzprogramm: den Ordner als Skill hinzufügen oder `SKILL.md` mitgeben – Einzelheiten in [skills/README.md](skills/README.md).
