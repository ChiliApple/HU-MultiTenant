# Installation

## Voraussetzungen
- Windows 10/11, **Windows PowerShell 5.1** (vorinstalliert) – PowerShell 7 ist nicht nötig (nur für Extensions mit `.RUNTIME PS7`)
- Internet: `login.microsoftonline.com`, `graph.microsoft.com`; für Updates `api.github.com`, `raw.githubusercontent.com`
- je Tenant eine **App-Registrierung** (Client Credentials, siehe unten)
- für Excel-Reports das Modul **ImportExcel** (wird beim ersten Report installiert; Excel selbst ist nicht nötig)
- für **Apps › Updates** der Windows Paket-Manager **winget** (App-Installer aus dem Microsoft Store, ab Windows 10 1809 meist vorhanden); das Modul `Microsoft.WinGet.Client` wird genutzt, wenn installiert
- für die Testinstallation die **Windows Sandbox** (Windows Pro/Enterprise/Education, wird auf Wunsch aktiviert)
- keine Administratorrechte nötig

## Installieren
1. `Pull.ps1` aus dem Repository in einen leeren Ordner legen und ausführen:
   `powershell -ExecutionPolicy Bypass -File Pull.ps1`
   (ohne Zielordner: `%USERPROFILE%\Desktop\HU-MultiTenant`; jeder andere Ordner geht auch – Updates landen immer dort, wo das Tool liegt)
2. Erster Start mit **Start-HUMultiTenant.cmd**.

Alternativ: Repository als ZIP laden und entpacken (dann ohne Prüfsumme/Signatur).

## App-Registrierung (je Tenant)
1. **Entra Admin Center › Anwendungen › App-Registrierungen › Neue Registrierung** – Name z. B. `HU-MultiTenant`, nur dieses Verzeichnis, keine Umleitungs-URI.
2. **Anwendungs-ID (Client-ID)** und **Verzeichnis-ID (Tenant-ID)** notieren.
3. **API-Berechtigungen › Microsoft Graph › Anwendungsberechtigungen** – je nach genutzten Extensions, danach **Administratorzustimmung erteilen**:

| Berechtigung | wofür |
|---|---|
| `Application.Read.All` | **Secret-Ablaufdatum anzeigen** (empfohlen), Enterprise-App-Inventur |
| `DeviceManagementManagedDevices.Read.All` | Geräte-Reports, Compliance, Defender |
| `DeviceManagementConfiguration.Read.All` | Richtlinien |
| `User.Read.All` | Benutzer-Reports, Lizenzen, Sync-Monitor |
| `AuditLog.Read.All` | MFA-Status, inaktive Benutzer (signInActivity) |
| `Organization.Read.All` | Tenant-Übersicht, Lizenzen |
| `Directory.Read.All` | Enterprise-App-Inventur |
| `DeviceManagementApps.ReadWrite.All` | Reiter **Apps** (hochladen, zuweisen, Status) |
| `DeviceManagementScripts.ReadWrite.All` | Reiter **Wartung** (Remediations) |
| `Group.Read.All` | Apps/Wartung: Zielgruppe per Name finden |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | Wartung: *Jetzt auf Gerät ausführen* |
| `Policy.Read.All` | Analyse: Conditional Access im Vergleich und Backup, Namen benannter Orte |
| `Device.Read.All` | Analyse: *Was bekommt …?* für Geräte (Gerätegruppen) |
| `DeviceManagementConfiguration.ReadWrite.All` | Analyse: fehlende Profile/Richtlinien in andere Tenants kopieren, aus Backup wiederherstellen (zum Lesen reicht `Read.All`) |
| `RoleManagement.Read.Directory` | optional: Rollennamen statt IDs im Tenant-Vergleich |
| `Policy.ReadWrite.ConditionalAccess` | optional: Conditional Access aus Backup wiederherstellen (wird deaktiviert angelegt) |

   Jede Extension zeigt ihre Berechtigungen im Reiter *Extensions*; der Knopf **Berechtigungen** vergleicht sie mit dem Token.
   Schreibende Extensions (`READ/WRITE`) brauchen zusätzlich die passenden `ReadWrite`-Berechtigungen.
4. **Zertifikate & Geheimnisse › Neuer geheimer Clientschlüssel** – den **Wert** sofort kopieren (wird nur einmal angezeigt).

## Danach
Tenant anlegen, Secret eintragen, Verknüpfung: **[Anleitung](Docs/Anleitung.html) › Einrichten** (im Programm **F1**).

## Update
Im Programm über den Knopf **Update** (Details in der Anleitung) oder von Hand:
`powershell -ExecutionPolicy Bypass -File Pull.ps1` – bestimmte Version: `-Version 2.0.0`.
Einstellungen, Snippets, Apps- und Wartungs-Bibliothek, Protokolle, Reports und eigene Extensions bleiben erhalten.

## Von v1.x umsteigen
`Pull.ps1` in den bestehenden Ordner legen und ausführen. Tenants, Snippets und gespeicherte Secrets werden übernommen. Nicht mehr gebraucht: `Publish-ToGitHub.ps1`, `HU-MultiTenant-Distribution*`.

## Fehlerbehebung
| Meldung | Lösung |
|---|---|
| *Skript kann nicht geladen werden* | über `HU-MultiTenant.exe` / `Start-HUMultiTenant.cmd` starten (setzen `-ExecutionPolicy Bypass`) |
| *Kein Token – Secret prüfen* | Secret abgelaufen oder falsch: Einstellungen › Tenants › Secret eingeben |
| *Fehlende Berechtigungen* | Knopf **Berechtigungen** – zeigt, was fehlt; danach Administratorzustimmung erteilen und neu verbinden |
| *Secret-Ablauf unbekannt* | `Application.Read.All` erteilen oder Datum manuell eintragen |
| Excel-Report schlägt fehl | `Install-Module ImportExcel -Scope CurrentUser` |
| Wartung: Fehler mit *license* | Intune Admin Center › Mandantenverwaltung › Connectors und Token › Windows-Datenverarbeitung › *Windows-Lizenzüberprüfung* einschalten (A3/E3 nötig) |
| Testinstallation: Sandbox fehlt | Knopf im Hinweisfenster aktiviert sie (Admin, Neustart); Windows Home hat keine Sandbox |
| Oberfläche zu klein/groß | Strg + Mausrad, Strg + 0 = 100 % |

## Selbsttest (Entwicklung)
Im Repository-Klon: `powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1` – dieselben Prüfungen wie auf GitHub
(Syntax, XAML, PSScriptAnalyzer, Pester). Starttest: `.\Main.ps1 -SmokeTest $env:TEMP\smoke.txt`.
