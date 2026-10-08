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

## 8. Vorhandene Skripte übernehmen

1. `param(...)` und feste Werte oben → `# @param`-Zeilen
2. `#Requires`, Dot-Source, eigene Token-Funktionen entfernen → `$Token` bzw. `Get-HUToken -Tenant …`
3. eigene Schleife über alle Tenants entfernen → *Mehrere ▾* (außer das Skript braucht Daten aus zwei Tenants gleichzeitig)
4. `Invoke-RestMethod` gegen `graph.microsoft.com` → `Invoke-GraphRequest` / `Invoke-GraphRequestAll`
5. Ergebnislisten als `[pscustomobject]` ausgeben statt als Text
6. lokale Pfade → `string`-Parameter mit dem bisherigen Wert als Standard

## 9. Grenzen

- kein PowerShell 7 (nur Extensions mit `.RUNTIME PS7`)
- kein `Connect-ExchangeOnline` (braucht Zertifikats-Anmeldung)
- nach neuen Berechtigungen in Entra: Programm neu starten (Token-Cache)
