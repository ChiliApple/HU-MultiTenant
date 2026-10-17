# HU-MultiTenant — Snippets schreiben

Referenz für eigene Quick-Script-Snippets (ab v2.0). Gilt für eigene Snippets ebenso wie für übernommene Skripte.
Bedienung (Mehrere Tenants, Tabelle, Verlauf, Snippet-Verwaltung): [Anleitung](https://chiliapple.github.io/HU-MultiTenant/Docs/Anleitung.html#qs).
Reports mit eigener Oberfläche im Extensions-Reiter: [EXTENSION-DEVELOPMENT.md](EXTENSION-DEVELOPMENT.md).

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
| `Invoke-GraphRequest -Token -Endpoint [-Method] [-Body] [-ApiVersion]` | ein Graph-Aufruf, Rückgabe = Antwortobjekt |
| `Invoke-GraphRequestAll -Token -Endpoint` | alle Seiten (`@odata.nextLink`), Rückgabe = Liste der `value`-Einträge |
| `Invoke-GraphRequestWithRetry` | wie `Invoke-GraphRequest`, wiederholt bei 429/5xx |
| `Get-HUToken [-Tenant <Schlüssel>]` | Token eines anderen Tenants |
| `Send-HUNotify -Title [-Level] [-Lines] [-Facts] [-Rows] [-Preview]` | Karte an die Ziele der Teams-Meldung, zu der das Snippet gehört (ab v2.1.10) – siehe unten |

- `-Endpoint` relativ (`'/users?$select=id,displayName'` → v1.0) oder absolut (`'https://graph.microsoft.com/beta/...'`)
- `-Method`: `GET` (Standard), `POST`, `PATCH`, `DELETE`; `-Body` als Hashtable
- Tokens, die an diese Funktionen übergeben werden, erneuert das Programm bei langen Läufen automatisch
- **nicht** `-Uri`/`-Headers` an `Invoke-GraphRequest` übergeben – das sind Parameter von `Invoke-RestMethod`

## 3. Regeln

- kein `param()`, kein `#Requires`, kein Dot-Source, kein `Import-Module` der HU-Module
- keine PowerShell-7-Syntax (`??`, `?.`, `? :`, `ForEach-Object -Parallel`)
- `$TenantKey` nicht selbst setzen – der Tenant kommt aus der Auswahl bzw. *Mehrere*
- einstellbare Werte als **Parameter** (Abschnitt 4), nicht als `$Wert = …` oben im Code
- Snippets, die etwas ändern: Parameter `DryRun` mit Standard `true`
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

```powershell
# Intune-Geraete ohne Synchronisierung seit X Tagen
# Berechtigungen: DeviceManagementManagedDevices.Read.All
# @param Tage|int|Ohne Sync seit Tagen|30

$grenze = (Get-Date).AddDays(-$Tage)
$dev = @(Invoke-GraphRequestAll -Token $Token -Endpoint '/deviceManagement/managedDevices?$select=deviceName,userPrincipalName,lastSyncDateTime')
$alt = @($dev | Where-Object { [datetime]$_.lastSyncDateTime -lt $grenze })
Write-Host "$($alt.Count) von $($dev.Count) Geraeten ohne Sync seit $Tage Tagen" -ForegroundColor Yellow

foreach ($d in $alt) {
    [pscustomobject]@{
        Geraet      = $d.deviceName
        Benutzer    = $d.userPrincipalName
        LetzterSync = ([datetime]$d.lastSyncDateTime).ToLocalTime()
    }
}
```

## 7. Vorlage: ändern

```powershell
# Geraet synchronisieren
# Berechtigungen: DeviceManagementManagedDevices.PrivilegedOperations.All
# @param Geraetename|string|Geraetename|
# @param DryRun|bool|Probelauf (nur anzeigen)|true

if (-not $Geraetename) { Write-Warning 'Geraetename fehlt'; return }
$d = @(Invoke-GraphRequestAll -Token $Token -Endpoint "/deviceManagement/managedDevices?`$filter=deviceName eq '$Geraetename'&`$select=id,deviceName")
if (-not $d.Count) { Write-Warning "[$TenantKey] $Geraetename nicht gefunden"; return }

foreach ($x in $d) {
    if ($DryRun) { Write-Host "[DRY-RUN] wuerde $($x.deviceName) synchronisieren" -ForegroundColor Yellow; continue }
    Invoke-GraphRequest -Token $Token -Endpoint "/deviceManagement/managedDevices/$($x.id)/syncDevice" -Method POST | Out-Null
    Write-Host "$($x.deviceName) synchronisiert" -ForegroundColor Green
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
- Ausgabe (`Write-Host`, Objekte, Warnungen, Fehler) erscheint live am Handy; Token und Kennwörter werden ausgeblendet, trotzdem keine Geheimnisse ausgeben
- keine Eingaben (`Read-Host`, `Out-GridView`, Dialoge) – vom Handy sieht sie niemand; der Lauf hängt sonst bis zum Abbruch
- nach jeder Änderung am Code ist die Freigabe ungültig, bis sie am PC neu gespeichert ist (Fingerabdruck)
- `Send-HUNotify` sendet vom Handy nur, wenn das Snippet zu einer Teams-Meldung gehört (an deren Ziele)

## 10. Grenzen

- kein PowerShell 7 (nur Extensions mit `.RUNTIME PS7`)
- kein `Connect-ExchangeOnline` (braucht Zertifikats-Anmeldung)
- nach neuen Berechtigungen in Entra: Programm neu starten (Token-Cache)
