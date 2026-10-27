# Installation

## Voraussetzungen
- Windows 10/11, **Windows PowerShell 5.1** (vorinstalliert) – PowerShell 7 ist nicht nötig (nur für Extensions mit `.RUNTIME PS7`)
- Internet: `login.microsoftonline.com`, `graph.microsoft.com`; für Updates `api.github.com`, `raw.githubusercontent.com`
- je Tenant einmalig ein Konto mit der Rolle **Global Administrator** (oder Privileged Role Administrator zusammen mit Application Administrator) – HU-MultiTenant legt die App-Registrierung selbst an (siehe unten); alternativ eine selbst angelegte App-Registrierung mit Secret
- für Excel-Reports das Modul **ImportExcel** (wird beim ersten Report installiert; Excel selbst ist nicht nötig)
- für **Apps › Updates** der Windows Paket-Manager **winget** (App-Installer aus dem Microsoft Store, ab Windows 10 1809 meist vorhanden); das Modul `Microsoft.WinGet.Client` wird genutzt, wenn installiert
- für die Testinstallation die **Windows Sandbox** (Windows Pro/Enterprise/Education, wird auf Wunsch aktiviert)
- keine Administratorrechte nötig (Ausnahme: die Handy-Fernbedienung wird einmal mit Administratorrechten eingerichtet – Zertifikat, HTTPS-Bindung, Firewall-Regel; danach läuft auch sie ohne; Remote FB wird nur für sichere Homeoffice-Umgebungen empfohlen)

## Installieren
1. `Pull.ps1` aus dem Repository in einen leeren Ordner legen und ausführen:
   `powershell -ExecutionPolicy Bypass -File Pull.ps1`
   (ohne Zielordner: `%USERPROFILE%\Desktop\HU-MultiTenant`; jeder andere Ordner geht auch – Updates landen immer dort, wo das Tool liegt)
2. Erster Start mit **Start-HUMultiTenant.cmd**.

Alternativ: Repository als ZIP laden und entpacken. Dabei werden Prüfsummen und Signatur nur bei dieser Erstinstallation nicht geprüft – alle späteren Updates (Knopf **Update** bzw. `Pull.ps1`) prüfen jede Datei per SHA-256 und die Signatur des Releases.

## Tenant einrichten (empfohlen)
Im Programm **Einstellungen › Tenants › Tenant einrichten (Admin-Anmeldung) …** (beim ersten Start wird das angeboten):
1. Schlüssel eingeben, Rechte prüfen (Standard ist vorausgewählt, siehe Tabelle; weitere frei wählbar, weitreichende rot mit eigener Bestätigung).
2. **Im Browser anmelden und einrichten** – als Global Administrator anmelden, bei *Microsoft Graph Command Line Tools* **Akzeptieren**. Das Häkchen *„Zustimmung im Namen Ihrer Organisation“* **nicht** setzen.
   Erscheint **kein** Zustimmungsdialog, besteht für diese Microsoft-App schon eine Zustimmung – möglicherweise **für alle Benutzer** (z. B. von früherem `Connect-MgGraph`). HU-MultiTenant zeigt das nach der Anmeldung an, ändert aber nichts. Prüfen unter Entra Admin Center › Unternehmensanwendungen › *Microsoft Graph Command Line Tools* › Berechtigungen. Empfehlung: dort unter Eigenschaften **„Zuweisung erforderlich“** einschalten und nur die Admin-Konten zuweisen.
3. HU-MultiTenant legt die App-Registrierung **HU-MultiTenant** an (nur dieses Verzeichnis, Anmeldung nur per Zertifikat), erzeugt auf diesem PC ein **nicht exportierbares Zertifikat** (Benutzer-Zertifikatspeicher, RSA 3072, 12 Monate), erteilt die Rechte samt Administratorzustimmung, testet die Anmeldung und trägt den Tenant ein. Bei einem Fehler wird Angelegtes wieder entfernt.

Das Admin-Token wird nur für diesen Vorgang im Speicher gehalten. Die Anmeldung nutzt die Microsoft-App *Microsoft Graph Command Line Tools* mit den delegierten Rechten `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` (nur lesen: bestehende Zustimmungen erkennen) und `User.Read` (Auth Code + PKCE, Antwort an `http://localhost:<Port>`).
Fehlende Rechte später: **Berechtigungen › Fehlende Rechte erteilen …** (gleiche Anmeldung, nur hinzufügen). Das Zertifikat wird 30 Tage vor Ablauf beim Start automatisch erneuert (ohne Admin).
Umsteigen von Secret: bestehenden Tenant einfach einrichten (wird an der Tenant-ID erkannt, Schlüssel bleibt), danach die alte App-Registrierung im Entra Admin Center löschen.

## App-Registrierung manuell (mit Secret)
1. **Entra Admin Center › Anwendungen › App-Registrierungen › Neue Registrierung** – Name z. B. `HU-MultiTenant`, nur dieses Verzeichnis, keine Umleitungs-URI.
2. **Anwendungs-ID (Client-ID)** und **Verzeichnis-ID (Tenant-ID)** notieren.
3. **API-Berechtigungen › Microsoft Graph › Anwendungsberechtigungen** – je nach genutzten Extensions, danach **Administratorzustimmung erteilen**:

| Berechtigung | wofür |
|---|---|
| `Application.Read.All` | **Secret-Ablaufdatum anzeigen** (empfohlen), Enterprise-App-Inventur, Sicherheitskatalog (A19, App-Rechte A42) |
| `DeviceManagementManagedDevices.Read.All` | Geräte-Reports, Compliance, Defender |
| `DeviceManagementConfiguration.Read.All` | Richtlinien |
| `DeviceManagementServiceConfig.Read.All` | Autopilot-Profile, Defender-Report |
| `User.Read.All` | Benutzer-Reports, Lizenzen, Sync-Monitor, Sicherheitskatalog (Gäste, Admin-Konten, Sync-Fehler) |
| `AuditLog.Read.All` | MFA-Status, inaktive Benutzer (signInActivity) |
| `Organization.Read.All` | Tenant-Übersicht, Lizenzen, Sicherheitskatalog (Lizenzen, Verzeichnissync A38) |
| `SecurityAlert.Read.All` | Teams: Defender-Alarm, Defender-Report |
| `Directory.Read.All` | optional: ältere Extensions (Enterprise-App-Inventur: Berechtigungen) |
| `DeviceManagementApps.Read.All` | Reiter **Apps**: *In Intune* und Installationsstand lesen |
| `DeviceManagementScripts.Read.All` | Reiter **Wartung**: *In Intune* und Ergebnisse lesen |
| `DeviceManagementApps.ReadWrite.All` | erst bei Bedarf: Reiter **Apps** hochladen, zuweisen, aufheben; Remote FB › Intune |
| `DeviceManagementScripts.ReadWrite.All` | erst bei Bedarf: Reiter **Wartung** anlegen, zuweisen; Remote FB › Intune – **weitreichend**: erlaubt Skripte als SYSTEM auf allen verwalteten Geräten |
| `Group.Read.All` | Apps/Wartung: Zielgruppe per Name finden, Sicherheitskatalog (Sync-Fehler A39) |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | erst bei Bedarf: Wartung: *Jetzt auf Gerät ausführen*, Sync – **weitreichend**: erlaubt auch Löschen, Zurücksetzen und Außerbetriebnahme von Geräten |
| `Policy.Read.All` | Analyse: Conditional Access im Vergleich und Backup, Namen benannter Orte; Sicherheitskatalog (Richtlinien, Anmeldemethoden, Zustimmungs-Workflow); Muster: Microsoft-Vorlagen für bedingten Zugriff holen |
| `SharePointTenantSettings.Read.All` | Sicherheitskatalog: externe Freigabe (A33), nur lesend |
| `Device.Read.All` | Analyse: *Was bekommt …?* für Geräte (Gerätegruppen) |
| `DeviceManagementConfiguration.ReadWrite.All` | Analyse: fehlende Profile/Richtlinien in andere Tenants kopieren, aus Backup wiederherstellen (zum Lesen reicht `Read.All`) |
| `RoleManagement.Read.Directory` | Rollennamen statt IDs im Tenant-Vergleich; Sicherheitskatalog (Admin-Rollen A08, A27, A37 – ohne das Recht nicht prüfbar) |
| `Policy.ReadWrite.ConditionalAccess` | optional: Conditional Access aus Backup wiederherstellen (wird deaktiviert angelegt) |

   Bei der Einrichtung im Programm sind nur die lesenden Rechte vorausgewählt (Liste: `Config\graph-permissions.json`). Schreibrechte (*erst bei Bedarf*, *optional*) erteilst du, wenn du sie brauchst: Fehlt eines beim Hochladen, Zuweisen oder *Jetzt ausführen*, bietet die App an, genau dieses Recht zu erteilen. *Weitreichende* Rechte werden dabei eigens bestätigt.
   Jede Extension zeigt ihre Berechtigungen im Reiter *Extensions*; der Knopf **Berechtigungen** vergleicht sie mit dem Token.
   Schreibende Extensions (`READ/WRITE`) brauchen zusätzlich die passenden `ReadWrite`-Berechtigungen.
4. **Zertifikate & Geheimnisse › Neuer geheimer Clientschlüssel** – den **Wert** sofort kopieren (wird nur einmal angezeigt).

## Danach
Tenant einrichten bzw. anlegen, Verknüpfung: **[Anleitung](Docs/Anleitung.html) › Einrichten** (im Programm **F1**).

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
| *Zertifikat fehlt auf diesem PC* | anderer PC/Benutzer oder gelöscht: Tenant auf diesem PC einrichten |
| Einrichtung: *Diesem Konto fehlt die Rolle …* | Konto ohne passende Rolle oder Rolle per PIM nicht aktiviert |
| Einrichtung: *ACHTUNG … Zustimmung für alle Benutzer* | siehe Schritt 2 oben: Zustimmung im Entra Admin Center prüfen, „Zuweisung erforderlich“ einschalten |
| Einrichtung: Browser zeigt *Anmeldung abgeschlossen*, Programm wartet | Firewall/Proxy blockiert `localhost` – nach 5 Minuten bricht die Anmeldung ab; manuell anlegen |
| *Fehlende Berechtigungen* | Knopf **Berechtigungen** › **Fehlende Rechte erteilen …** – danach nach etwa 1 Minute neu lesen |
| *Secret-Ablauf unbekannt* | `Application.Read.All` erteilen oder Datum manuell eintragen |
| Excel-Report schlägt fehl | `Install-Module ImportExcel -Scope CurrentUser` |
| Wartung: Fehler mit *license* | Intune Admin Center › Mandantenverwaltung › Connectors und Token › Windows-Datenverarbeitung › *Windows-Lizenzüberprüfung* einschalten (A3/E3 nötig) |
| Testinstallation: Sandbox fehlt | Knopf im Hinweisfenster aktiviert sie (Admin, Neustart); Windows Home hat keine Sandbox |
| Oberfläche zu klein/groß | Strg + Mausrad, Strg + 0 = 100 % |

## Selbsttest (Entwicklung)
Im Repository-Klon: `powershell -NoProfile -ExecutionPolicy Bypass -File .github\tests\Invoke-CITests.ps1` – dieselben Prüfungen wie auf GitHub
(Syntax, XAML, PSScriptAnalyzer, Pester). Starttest: `.\Main.ps1 -SmokeTest $env:TEMP\smoke.txt`.
