# HU-MultiTenant Changelog

## v2.1.6 (in Arbeit)

### Neu
- **Wartung: Duplizieren** per Rechtsklick in der linken Liste - Bibliothek: lokale Kopie; In Intune: Kopie mit neuem Namen in denselben Tenants, ohne Zuweisungen
- **Apps: Kategorien** fuer das Unternehmensportal (mit Komma getrennt oder "Auswahl ..." aus den angehakten Tenants); Kategorien in der Auswahl anlegen und loeschen (mit Rueckfrage); fehlende werden beim Hochladen je Tenant gemeldet; auch unter Apps > In Intune (Eigenschaften), mit Anzeige abweichender Kategorien je Tenant

## v2.1.5 (2026-10-09)

### Neu
- Einstellungen > Allgemein: **Autor** - steht in Intune bei Apps als Besitzer und bei Wartungsskripten als Herausgeber (statt "HU-MultiTenant")
- **Wartung: Felder fuer Werte** - `# @param`-Zeilen (wie im Quick Script) werden zu Eingabefeldern ueber den Skripten; der Wert steht direkt im Skript (`# @value`) und wird genau so hochgeladen, daher auch unter In Intune aenderbar. "Werte als Felder uebernehmen" wandelt einfache Zuweisungen am Skriptanfang um; Pruefen meldet falsche Platzierung

### Verbessert
- Rechtsklick-Menues (z. B. Ausgabe: Kopieren / Alles kopieren / Ausgabe leeren) im dunklen Stil, ohne helle Symbolspalte
- KI-Prompt fuer Wartungsskripte: Werte als `@param`-Felder, Funktionsnamen in Verb-Nomen-Form, Reparaturfehler zusaetzlich auf die Fehlerausgabe (Intune zeigt nur diese)
- Wartung > Pruefen: warnt jetzt auch bei Passwoertern im Klartext (Variablen wie $Password/$Kennwort, ConvertTo-SecureString mit festem Text, net user) - nur Hinweis, blockiert nichts

## v2.1.4 (2026-10-09)

### Neu
- **Wartung: In Sandbox testen** (Bibliothek und In Intune): Pruef- und Reparaturskript laufen in der Windows Sandbox wie bei Intune - als SYSTEM bzw. Benutzer, 64/32-Bit, ohne Netzwerk, Zeitlimit 5 Min. je Skript; Ergebnis je Schritt (Exit-Code, Dauer, Konto, Ausgabe, Warnung ueber 2.048 Zeichen) und Bewertung wie in Intune; "Sandbox offen lassen" zum Nachstellen weiterer Faelle (in der Sandbox erneut: `& C:\HUTest\HURemTest.ps1`)

## v2.1.3 (2026-10-09)

### Behoben
- Wartung > In Intune: "Aenderungen speichern", "In andere Tenants kopieren" und "In Bibliothek uebernehmen" blieben nach dem Laden der Details gesperrt (seit 2.1.1)

## v2.1.2 (2026-10-08)

### Neu
- **Sperre**: HU-MultiTenant nach einstellbarer Zeit ohne Eingabe in der App sperren, auf Wunsch auch beim Start; entsperren mit Windows Hello (Dialog mittig über der App, ab Windows 11) oder einer eigenen PIN (nur als Hash gespeichert, 5 Fehlversuche = 30 s Pause); Strg+L sperrt sofort; beim Sperren werden zwischengespeicherte Tokens verworfen (Einstellungen > Allgemein > Sperre)
- **Not-Aus** (⛔ oben rechts): nach Rückfrage alle lokal gespeicherten Secrets löschen, Verbindungen trennen, beenden und die App-Registrierungen der Tenants zum Widerrufen öffnen

### Behoben
- App-Symbol: liefert ein Programm beim Auslesen nur Bildrauschen (z. B. nach der Testinstallation), wird es nicht mehr uebernommen - das vorhandene Symbol bleibt

## v2.1.1 (2026-10-08)

### Verbessert
- In Intune (Apps und Wartung): Details laden je Tenant gleichzeitig, jeder Tenant erscheint, sobald er da ist
- Apps > In Intune: Installationsstand je Tenant oben (installiert, fehlgeschlagen, ausstehend, nicht installiert)
- Entfernte Zuweisungen verschwinden sofort aus der Anzeige; nach jeder Aenderung wird nach ein paar Sekunden nochmal neu geladen (Intune liefert Aenderungen oft verzoegert)
- Kuerzere Wartezeiten bei voruebergehenden Intune-Fehlern, bei Drosselung (429) wird die Vorgabe von Intune beachtet
- Behoben: "--- fertig ---" wiederholte sich endlos, wenn zwei Auftraege gleichen Namens knapp hintereinander liefen
- In Intune (Apps und Wartung): kleiner Knopf "alle" neben den Tenant-Haken (alle an / alle aus), auch beim Verteilen in der Bibliothek
- Neuer Tenant heisst "Neuer Tenant n" / "Tenant-n" statt "Neue Schule"

## v2.1.0 (2026-10-08)

### Neu: Reiter Apps
- **Bibliothek**: MSI, EXE und Microsoft-Store-Apps an mehrere Tenants verteilen - Setup hineinziehen, Name, Version, Befehle und Erkennung werden ausgelesen (MSI vollstaendig; EXE: Inno, NSIS, InstallShield, WiX, Advanced Installer, Squirrel); Paket wird einmal gebaut und je Tenant hochgeladen
- **Testinstallation in der Windows Sandbox**: schlaegt Erkennung, stille Deinstallation und Symbol vor, testet die Deinstallation mit, meldet Fenster, Desktop-Verknuepfungen und Installationen ins Benutzerprofil, zeigt bei Fehlern die Protokolle; schliesst die Sandbox selbst. Inno-Setups: /ALLUSERS beim Installieren, /VERYSILENT und Beenden der laufenden App beim Deinstallieren
- **Zuweisen**: Gruppe (per Name je Tenant), Alle Geraete, Alle Benutzer oder keine Zuweisung; Erforderlich/Verfuegbar/Deinstallieren, Frist, Hinweise; optional Pilotgruppe mit "Fuer alle freigeben"
- **Neue Version**: neue Setup-Datei aktualisiert dieselbe Intune-App, auch wenn die Version im Namen steht
- **Abhaengigkeiten** aus der Bibliothek oder aus Intune (Treiber, Laufzeitumgebungen), automatisch mitinstallieren oder nur pruefen
- **Symbol** fuer das Unternehmensportal (Bild, ICO, EXE, Microsoft Store) und **Ohne Desktop-Verknuepfung**
- **Status** je Geraet im Klartext mit Fehlerhinweis und Export
- **In Intune**: alle vorhandenen Windows-Apps verwalten - Zuweisungen, Abhaengigkeiten/Ersetzungen, Eigenschaften und Symbol, Status, Loeschen

### Neu: Reiter Wartung (Remediations)
- **Bibliothek**: Pruef- und Reparaturskript mit KI erstellen (Prompt kopieren, Antwort einfuegen), automatisch pruefen (exit 1, Neustart, Eingaben, PowerShell-7-Syntax, Benutzerpfade, Secrets im Klartext), mit Zeitplan verteilen, Ergebnisse je Geraet, sofort auf einem Geraet ausfuehren; 5 Beispiele
- **In Intune**: alle vorhandenen Wartungsskripte inkl. Microsoft - Zusammenfassung, Zuweisungen mit Zeitplan, Skripte und Eigenschaften aendern, Ergebnisse, in die Bibliothek uebernehmen, **in andere Tenants kopieren** (auf Wunsch mit Zuweisungen; fehlende Gruppe: nicht zuweisen oder Alle Geraete), Loeschen

### Fuer beide "In Intune"-Ansichten
- Mehrere Tenants gleichzeitig, gleiche Namen zusammengefasst; Liste zeigt "nur: ..." / "fehlt: ..."
- Loeschen: Tenants per Haken waehlen, danach doppelte Rueckfrage
- Abweichende Skripte je Tenant werden nur nach Aenderung und Rueckfrage ueberschrieben

### Weiteres
- **Gruppen suchen** (Lupe): Gruppen der angehakten Tenants mit Filter, zeigt wo eine fehlt
- **Support**-Knopf: Protokolle und Einstellungen anonymisiert als ZIP, per E-Mail oder GitHub-Issue (ohne Protokolle)
- Tenant-Leiste (Verbinden/Trennen) nur noch im Reiter Extensions; Klick auf eine Extension wechselt dorthin; in Apps und Wartung ist die Extension-Liste ausgeblendet
- Start-Reiter auch Apps oder Wartung; Aufteilungen in Apps und Wartung bleiben gespeichert
- Neue Berechtigungen (nur fuer die neuen Reiter): DeviceManagementApps.ReadWrite.All, DeviceManagementScripts.ReadWrite.All, Group.Read.All; fuer "Jetzt auf Geraet" DeviceManagementManagedDevices.PrivilegedOperations.All

## v2.0.2 (2026-10-08)

### Geaendert
- **Extensions aufgeraeumt** (12 auf 7):
  - neu **Device-DeviceReport** ersetzt Device-AllDevicesReport, Device-StaleDevicesReport und Device-SyncStatusExport: ein Excel-Report mit Sync-Ampel, Blaettern Sync-Warnung, Cleanup-Gefahr und Nicht-konform (mit den nicht erfuellten Richtlinien), Parameter *Nur Windows-Geraete*
  - **Security-DefenderStatusReport** liest den Defender-Status in Graph-Batches zu je 20 Geraeten statt einzeln (284 Geraete in rund 8 Sekunden); nur noch Windows-Geraete werden abgefragt; Anzahl der Update-Ringe wird wieder angezeigt
  - neue Core-Funktion `Invoke-GraphBatchGet` (Graph JSON-Batching mit Wiederholung bei 429/5xx) - auch fuer eigene Extensions
  - Meldungen und Excel-Beschriftungen der Extensions durchgehend Deutsch; Ampelfarben im Excel erkennen auch Kritisch/Warnung/Cleanup-Gefahr
  - reine Lese-Reports ohne Dry-Run-Haken (MFA-Status, inaktive Benutzer, Lizenzen)

### Entfernt
- Extensions **Security-AllDevicesReport** (fragte Defender-Warnungen mit der falschen Berechtigung ab), **Security-AppAssignmentAudit** (ersetzt durch die Enterprise-App-Inventur), **Common-TenantHealthDashboard** (gleiches Ergebnis wie das Beispiel-Snippet *Tenant-Uebersicht*). Unveraenderte Kopien dieser sechs alten Extensions entfernt HU-MultiTenant beim Start selbst; selbst angepasste bleiben liegen
- Extension **Security-BMBKinderschutzAudit** und der Ordner `Extensions\Security\BMB-Referenz` sind nicht mehr Teil des Programms. Wer sie bereits hat, behaelt sie: beim Update bleiben Dateien, die es im Repository nicht gibt, unveraendert.

## v2.0.1 (2026-10-07)

### Neu
- **Berechtigungen** (Knopf oben rechts): erteilte Graph-Anwendungsberechtigungen je Tenant mit Risiko, Beschreibung und welche Extension sie nutzt; Status der Berechtigungen der gewaehlten Extension; **Alle Tenants vergleichen** als Tabelle. Das Token wird mit dem gespeicherten Secret geholt - Verbinden ist nicht noetig
- **Rechtsklick** in der Ausgabe (Quick Script und Extensions): Kopieren, Alles kopieren, Ausgabe leeren

### Behoben
- Taskleiste zeigte das PowerShell-Symbol statt des HU-Logos; Anheften an die Taskleiste startet jetzt HU-MultiTenant
- HU-Logo fehlte in einzelnen Fenstern (Berechtigungen, Secret-Abfrage beim Start)
- Berechtigungs-Fenster meldete "fehlt", solange der Tenant nicht verbunden war
- Beschreibung und Risiko fuer weitere Berechtigungen (z. B. Organization.Read.All) ergaenzt

## v2.0.0 (2026-10-07)

### Neu
- **Quick Script ist der Start-Reiter** (einstellbar: Quick Script, Extensions oder zuletzt verwendet)
- **Snippet-Verwaltung** im eigenen Fenster: Liste mit Name, **Kurzbeschreibung** und Aenderungsdatum, Suche in Name/Beschreibung/Code, umbenennen, Beschreibung bearbeiten, Reihenfolge (▲▼, A-Z, neueste zuerst), duplizieren, mehrere loeschen, **Import/Export** (JSON)
- **Favoriten**: Stern in der Snippet-Verwaltung (Klick auf den Stern oder Knopf, auch fuer mehrere), Filter *nur Favoriten*, Stern-Knopf im Quick Script fuer das geladene Snippet; Favoriten stehen in der Auswahl ganz oben
- Snippet-Auswahl laedt sofort, Name und Beschreibung stehen unter der Auswahl, Punkt ● = ungespeicherte Aenderungen (Rueckfrage beim Wechseln und Beenden), *Speichern* / *Speichern unter* / *Neu*
- Quick Script: **Abbrechen** (auch Esc), **Strg+Enter / F5** ausfuehren, **F8** nur Markierung, Strg+S, Strg+N, Laufzeit im Knopf, Ausgabe kopieren, Fehler mit Zeilennummer, automatisch verbinden beim Ausfuehren, zuletzt geladenes Snippet und Tenant werden gemerkt
- **Secret-Ablauf je Tenant**: Graph (`Application.Read.All`) liefert das Ablaufdatum genau des verwendeten Secrets (erkannt an den ersten 3 Zeichen), sonst manuelles Datum; Anzeige neben dem Tenant und im Quick Script, Warnung in der Titelleiste (Standard 30 Tage), Pruefung beim Verbinden und beim Start im Hintergrund (hoechstens einmal am Tag)
- **Einstellungen**: Tenants anlegen/bearbeiten/sortieren, Secret eingeben, Verbindung + Secret pruefen, gespeichertes Secret loeschen, App im Entra Admin Center oeffnen, geschuetzte App-IDs; Start-Reiter, Oberflaechengroesse, Protokoll-Stufe, Reports-Ordner, Warnschwelle; Update-Kanal und Signaturpflicht
- **Starter HU-MultiTenant.exe** (lokal erzeugt, Logo, kein Konsolenfenster) und **Verknuepfung** auf Desktop / im Startmenue / fuer alle Benutzer
- **Fenster merken**: Position, Groesse, maximiert, Breite der Extension-Liste, Aufteilung Editor/Ausgabe und Details/Protokoll, Schriftgroesse im Editor; **Strg + Mausrad** skaliert die Oberflaeche (Strg + 0 = 100 %)
- **Update** wie HUMig/HU-AdminTool: Pull.ps1, Kanal Stabil/Test, SHA-256 je Datei, nur signierte Releases, Vorversion per Klick, Gold-Knopf bei neuer Version, Info-Fenster
- **Anleitung** (F1, `Docs/Anleitung.html`)
- Erststart ohne `settings.json`: leere Konfiguration wird angelegt, Einstellungen oeffnen sich
- Extensions: **Device-StaleSyncMonitor** (aktive Benutzer, Geraet synct nicht), **Security-EnterpriseAppInventory** (Inventur und Aufraeumen der Enterprise-Apps), **Device-SyncStatusExport**
- **Quick Script ueber mehrere Tenants**: Knopf *Mehrere* - ab 2 Haken laeuft das Skript je Tenant einmal (`$Token`, `$TenantKey` je Durchlauf), Ausgaben bekommen eine Spalte *Tenant*, Fehler werden je Tenant gemeldet
- **Snippet-Parameter**: `# @param Name|Typ|Beschriftung|Standard|Auswahl` im Code erzeugt Eingabefelder (Haken, Zahl, Text, Auswahl) ueber dem Editor; Werte bleiben je Snippet erhalten. `DryRun`/`WhatIf` aus = Rueckfrage vor dem echten Lauf
- **Tabelle**: Objekte aus dem Skript (`[pscustomobject]`) als Tabelle mit Filter, **CSV-** und **Excel-Export** (ImportExcel), kopieren fuer Excel
- **Token-Erneuerung**: `Get-HUToken` und die Graph-Funktionen erneuern das Token waehrend langer Laeufe automatisch
- **Beispiel-Snippets** (12, Kategorie *Beispiele*): Tenant-Uebersicht, Geraete ohne Sync, nicht konforme Geraete, inaktive Benutzer, Lizenzen, MFA-Registrierung, Gast-Konten, Autopilot, ablaufende App-Secrets, Geraet synchronisieren, Gruppenmitglieder, Vorlage - beim ersten Start oder per *Beispiele* in der Verwaltung
- **Kategorien** fuer Snippets: gruppierte Liste, Filter, Kategorie fuer mehrere Snippets auf einmal; Kategorie auch in der Auswahl
- **Verlauf** je Lauf (Zeit, Snippet, Tenants, Dauer, Ergebnis) mit vollstaendigem Protokoll in `Logs\QuickScript\`; *Zuletzt ausgefuehrt* in der Verwaltung
- Knoepfe *Log-Ordner* und *Reports*, Kennzeichnung *SCHREIBT* fuer Extensions mit Schreibzugriff
- Automatische Tests (GitHub Actions, Windows PowerShell 5.1): Syntax, BOM, XAML und Steuerelemente, PSScriptAnalyzer, Pester, Starttest

### Geaendert
- Aufbau wie HUMig/HU-AdminTool: `Main.ps1` startet nur noch, Oberflaeche in `XAML\` (gemeinsames Theme), Funktionen in `Functions\`
- Oberflaeche und Protokollmeldungen durchgehend Deutsch
- Enterprise-App-Inventur: Schutzliste ohne feste App-ID - die App-IDs aller Tenants aus `settings.json` sind automatisch geschuetzt, weitere ueber *geschuetzte App-IDs*
- `settings.json`, `quick-snippets.json` werden atomar geschrieben (Sicherung `.bak`)
- Lizenz: Nutzung frei (wie HUMig/HU-AdminTool), eigene Extensions und Snippets ausdruecklich erlaubt

### Behoben
- Fensterposition wurde gespeichert, aber nie wiederhergestellt (CenterScreen hatte Vorrang)
- zuletzt gewaehlter Tenant wurde beim Beenden geloescht
- Umlaute im Knopf *Ausfuehren* (Datei ohne UTF-8-BOM)
- Secret wurde mit `ConvertTo-SecureString -AsPlainText` erzeugt (PSScriptAnalyzer-Fehler)

### Entfernt
- `Publish-ToGitHub.ps1` (ZIP-Verteilung) - ersetzt durch Pull.ps1 und Releases

## v1.3.0 (2026-04-05)

### Neue Funktionen

- **Quick Script Runner** (Tab "⚡ Quick Script"): Eigener Tab im rechten Panel fuer Ad-hoc PowerShell-Skripte direkt in der GUI
  - Eigener Tenant-Selector (unabhaengig vom Haupt-Connect)
  - Script-Editor (Consolas, AcceptsTab, kein Wordwrap, horizontaler Scrollbalken)
  - Async-Ausfuehrung im separaten Runspace - GUI friert nicht ein
  - Echtzeit-Streaming: Write-Output und Write-Host (inkl. -ForegroundColor) erscheinen sofort Zeile fuer Zeile
  - Spinner im AUSFUEHREN-Button zeigt laufende Ausfuehrung
  - Error-, Warning- und Information-Stream werden farbig ausgegeben
- **Snippet-Verwaltung**: Skripte benennen, speichern, laden und loeschen
  - Gespeichert in Config\quick-snippets.json
  - Dropdown mit allen gespeicherten Snippets
  - Ueberschreiben-Bestaetigung bei gleichem Namen
- **Fenstergroesse wird gespeichert**: Beim Schliessen werden Width/Height/Left/Top in ui-state.json gespeichert und beim naechsten Start wiederhergestellt (Monitor-safe)
- **Resizable Editor/Output**: GridSplitter zwischen Editor und Output-Box (ziehbar)
- **Compatibility-Alias**: Invoke-AdminGraphRequest -> Invoke-GraphRequest wird automatisch gesetzt

### Fixes

- Snippet-Speichern: List Cast-Crash bei leerem Array behoben
- Snippet-Speichern: List.Remove() Referenz-Bug behoben (Index-basierte Filterung)
- Snippet-Loeschen: Gleicher Referenz-Bug behoben
- MessageBox-Enum-Vergleich: korrekte Enum-Pruefung
- Delete-Button: DockPanel LastChildFill=False - Button streckte sich auf volle Breite
- Connect Quick Script: Get-CachedToken -> Get-GraphToken
- Alle Snippet-Handler mit try/catch abgesichert


## v1.2.5 (2026-04-02)

### Neue Funktionen
- **DarkComboBox XAML-Style**: Vollständiges ControlTemplate für Extension-Parameter Dropdowns — konsistentes Dark Theme in geschlossenem und offenem Zustand
- **Bereich-Cards dynamisch**: Area-Cards (z.B. "Defender Portal") aktualisieren sich live wenn manuelle Checks abgehakt werden (Icon, Farbe, Stats)

### Fixes
- **Mitglieder-Spalte 0 statt Zahl**: PowerShell Type Coercion Bug (`0 -ne ""` = false) behoben
- **Mitglieder immer 0**: `@odata.type` aus `$select` entfernt — Graph gibt dieses Feld automatisch zurück, explizites Selektieren verursachte stillen Fehler
- **Verschachtelte Gruppen (0)**: `$count` Endpoint entfernt (braucht `ConsistencyLevel: eventual`), direkte Paginierung stattdessen

## v1.2.4 (2026-04-02)

### Fixes
- **Dropdown-Text zu hell**: ComboBox-Popup im Dark Theme jetzt mit korrektem `ItemContainerStyle` (dunkler Hintergrund + helle Schrift)
- **Policy-Zuweisung False-Positive**: `Set-PolicyAssignment` prüft Zuweisung jetzt per GET-Verifizierung statt Response-Auswertung — kein Fehl-Alarm mehr bei erfolgreichem Assign
- **Assignment-Body**: `@odata.type` und `deviceAndAppManagementAssignmentFilterType` für Settings Catalog Policies ergänzt

## v1.2.3 (2026-04-02)

### Neue Funktionen
- **Portal Deep-Links im Dashboard**: Alle Audit-Ergebnisse mit ResourceId sind klickbare Links zum jeweiligen Portal (Entra, Intune Settings Catalog, Legacy Config, Endpoint Security, Defender)
- **Erweiterte Mitglieder-Spalte**: Zeigt Geräte, Gruppen und geschachtelte Mitgliederzahlen (z.B. "2 Devices + 1 Gruppe (312 Geräte)")
- **Interaktive manuelle Checks**: Defender-Portal-Prüfungen im Dashboard abhakbar — KPIs, Progress und Gesamtstatus werden live aktualisiert
- **Dashboard Design Standard**: CSS Custom Properties (`:root`), dokumentiert in EXTENSION-DEVELOPMENT.md §16 als Vorlage für alle Extensions

### Fixes
- **ResourceId/ResourceType** auf alle `New-CheckResult`-Aufrufe erweitert (Settings Catalog, OMA-URI, EDR, Store, Defender)

## v1.2.2 (2026-04-02)

### Neue Funktionen
- **BMB Kinderschutz Extension** (`Security-BMBKinderschutzAudit.ps1`): Vollständige Integration in HU-MultiTenant Framework
- **HTML-Dashboard**: Dark-Mode Dashboard mit KPI-Cards, Progress-Bar, Bereich-Übersicht, Detail-Tabelle
- **3 Modi**: Audit, SetUp (automatische Policy-Erstellung), Export (Template-Export)
- **BMB-Referenz-Ordner**: Vorgaben und CCCS-Namenskonventionen exportiert

### Fixes
- **WhatIf Parameter-Duplikat**: `[CmdletBinding()]` statt `[CmdletBinding(SupportsShouldProcess)]`
- **Beta URL Bug**: Fehlender `/` in `Get-KSAllPages` → Settings Catalog Policies wurden nicht gefunden
- **MDE Policy nicht gefunden**: Dritter Suchpfad über Endpoint Security Intents (beta API)
- **CCCS-Win-MicrosoftStoreBlockieren**: Wiederhergestellt nach versehentlicher Entfernung
