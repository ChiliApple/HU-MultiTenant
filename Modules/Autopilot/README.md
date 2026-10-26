# HU-MultiTenant – Modul Autopilot

Mitgeliefertes Modul für **HU-MultiTenant** (ab 2.5.4, Mindestversion laut `addon.json` 2.5.2): eigener Reiter **Autopilot** für den ganzen Lebenslauf eines Windows-Geräts mit **Windows Autopilot (klassisch, mit Hardware-Hash)** – Hash sammeln, aufnehmen, Group Tag ändern, ausscheiden bzw. zurückziehen, mit Protokoll und Paket für die Eltern.

## Funktionen

**Kopf:** oben je Reiter genau eine Tenant-Auswahl – *Übersicht* und *Tags & Gruppen* mit Haken (mehrere Tenants), *Hash-Archiv*, *Aufnehmen* und *Ausscheiden* mit einem gemeinsamen Dropdown (ein Tenant, wird gemerkt). Ein Knopf **Laden** liest je Reiter das Passende. Fehlen Rechte, zeigt der Reiter ein Banner mit **Rechte erteilen …** (die fehlenden Rechte sind vorausgewählt).

- **Übersicht:** alle Autopilot-Geräte mit Ampel *Bereit / Warnung / Fehlt / Fehler* (bereit = Group Tag + Profil zugewiesen), Hersteller, Modell, Group Tag, Profilstatus, Registrierung, in Intune, Gerätename, **Benutzer (UPN)**, eingerichtet am, letzter Kontakt/Sync, Hinweis. Filter, „nur nicht bereit“, „nur ohne Intune“, Doppelklick = alle Details. **Tabelle / Export** (Excel/CSV, mit UPN, ohne Hash).
  - **Tag ändern …** für markierte Geräte eines Tenants: neuen Tag eintippen oder wählen, Anzeige von Gruppe und Profil des neuen Tags, Warnung bei eingerichteten Geräten (Gruppenwechsel wirkt sofort), Bestätigung mit Tenant-Namen. Geändert wird nur der Group Tag. Danach Nachverfolgung und **Tag-Änderung rückgängig …**.
- **Tags & Gruppen:** Anzahl Geräte je Group Tag (bereit, ohne Profil, in Intune).
- **Hash-Archiv** (je Tenant, verschlüsselt nur für diesen Windows-Benutzer):
  - **Dateien hinzufügen …** bzw. CSV/Excel/Ordner hineinziehen (Lieferanten-Datei, `Get-WindowsAutopilotInfo`). Geräte, die laut Autopilot zu einem anderen Tenant gehören, legt die App auf Wunsch gleich dort ab.
  - **Hash anfordern …:** führt das Wartungspaket **HU-AP-Hash** auf den markierten Geräten aus (bzw. auf allen Autopilot-Geräten ohne Hash). Das Gerät liest seinen Hash einmal, merkt ihn unter ProgramData und gibt ihn komprimiert an Intune zurück. Das Paket legt die App bei Bedarf an – **ohne Zuweisung**. **Hashes abholen** übernimmt die Ergebnisse (Prüfsumme geprüft).
  - Abgleich mit Autopilot (in Autopilot ja/nein, Geräte ohne Hash), „nur nicht in Autopilot“, **Ausgeschieden …** / **Ausgeschieden aufheben** (Hash bleibt, Gerät wird beim Aufnehmen nicht angeboten), **Export CSV** (Microsoft-Format, unverschlüsselt – mit Warnung), **Entfernen …**. Mehrere Hashes je Gerät bleiben erhalten, der neueste gilt.
- **Aufnehmen:** Geräte kommen aus dem Hash-Archiv (schon registrierte und ausgeschiedene ausgeblendet).
  1. **Group Tag** eintippen oder wählen (Tags der Geräte und aus den Regeln dynamischer Gruppen); erlaubt sind Buchstaben, Ziffern, `-` und `_`.
  2. **Gruppe:** welche dynamische Gruppe den Tag trifft – sicher (`-eq`, reine `-in`-Liste), „trifft mehrere Tags“ (`-startsWith`/`-contains`) oder „bitte prüfen“ (zusammengesetzt, `-ne`, nicht auswertbar). Ohne sichere Gruppe: **Gruppe anlegen …** (Sicherheitsgruppe, Regel immer `-eq`).
  3. **Profil** der Gruppe, mit Warnung, wenn die Geräte keines bekommen.
  4. **Vorschau & Import …** (Bestätigung mit Tenant-Namen, höchstens 500 Geräte): Import, Import-Einträge aufräumen, Autopilot-Sync einmal, Nachverfolgung alle 2 Minuten mit **Dauer bis Gruppe** und **Dauer bis Profil**. Fehlertexte nach Microsoft (806 schon registriert, 808 in anderem Tenant …).
- **Ausscheiden** (Abgänger, Rückgabe):
  - Suche oder **Liste …** (Abgängerliste mit Seriennummern oder UPNs als CSV, Excel oder Text – auch hineinziehen) markiert die Geräte. Je Gerät eine Vorab-Prüfung (privat, lange nicht synchronisiert, kein Hash, kein Benutzer).
  - **Ausscheiden …** (Gerät kommt zurück, wird zurückgesetzt): Benutzer im Autopilot-Eintrag aufheben → Autopilot-Eintrag entfernen → in der Liste nachlesen, bis er weg ist (höchstens 15 Minuten) → erst dann **Wipe**. Sonst kein Wipe, „Erneut versuchen“. Höchstens 25 Geräte je Durchgang.
  - **Zurückziehen …** (Gerät bleibt bei der Familie, Daten bleiben): BitLocker-Wiederherstellungsschlüssel lesen (ohne Schlüssel kein Zurückziehen) → Autopilot-Eintrag entfernen (schlägt das fehl: kein Zurückziehen) → Retire. Danach öffnet sich die **Übergabe-Bestätigung mit Schlüssel zum Drucken** – sie wird nicht gespeichert.
  - **Nachverfolgung:** Art, Autopilot, Wipe/Zurückziehen (wartet auf Gerät, vermutlich ausgeführt …), Intune – automatisch alle 2 Minuten (2 Stunden), einmal automatisch **Sync nachschieben**, **Sync senden**, **Erneut versuchen …**, **Intune-Eintrag löschen …** (nur nach erledigtem Wipe; meist entfernt Intune das Gerät selbst).
  - **Protokolle …:** je Gerät ein Ausscheidungsprotokoll (HTML) mit allen Schritten und dem Hardware-Hash sowie eine Import-CSV für die neue Schule. **Pakete für Eltern …:** je Gerät ein ZIP (Protokoll, Import-CSV, Hinweis für die Eltern) plus `Uebersicht.csv` und `Mailtext.txt` – ohne BitLocker-Schlüssel.

**Hinweise aus dem Test:** Ein Gerät im Energiesparmodus holt den Wipe erst nach dem Aufwecken ab. Nach dem Zurücksetzen kann der Bildschirm schwarz bleiben (Startton hörbar) – Deckel zu/auf hilft. Geräte, die bei der Familie bleiben, nie wipen, solange sie nicht vor Ort sind.

## Benötigte Rechte (App-Registrierung von HU-MultiTenant, Anwendungsberechtigungen)
| Zweck | Recht |
|---|---|
| Autopilot-Geräte, Group Tags, Profilstatus | DeviceManagementServiceConfig.Read.All |
| Abgleich mit Intune | DeviceManagementManagedDevices.Read.All |
| Ergebnisse der Wartung HU-AP-Hash | DeviceManagementScripts.Read.All |
| Hash anfordern (Paket anlegen, ausführen) | DeviceManagementScripts.ReadWrite.All, DeviceManagementManagedDevices.PrivilegedOperations.All |
| Aufnehmen: Import, Sync, Tag ändern; Ausscheiden: Autopilot-Eintrag entfernen, Benutzer aufheben | DeviceManagementServiceConfig.ReadWrite.All |
| Aufnehmen: Gruppen und Regeln lesen, Gruppe anlegen | Group.Read.All, Group.Create |
| Aufnehmen: Gruppenmitgliedschaft der Geräte | Device.Read.All |
| Ausscheiden/Zurückziehen: Wipe, Retire, Sync | DeviceManagementManagedDevices.PrivilegedOperations.All |
| Ausscheiden: Intune-Eintrag löschen | DeviceManagementManagedDevices.ReadWrite.All |
| Zurückziehen: BitLocker-Wiederherstellungsschlüssel (jeder Abruf steht im Entra-Überwachungsprotokoll) | BitlockerKey.Read.All |

Eine von der App angelegte Gruppe löscht die App nicht (dafür bräuchte sie Group.ReadWrite.All) – das geht im Entra-Portal. Profilstatus und Wartungsergebnisse kommen aus Microsoft Graph **beta**. Hash anfordern setzt Lizenzen voraus, die Remediations erlauben (z. B. A3/A5).

## Daten und Datenschutz
Alles liegt nur lokal im Datenordner des Moduls (`Get-HUAddonDataDir 'Autopilot'`, `%APPDATA%\HU-MultiTenant\AddonData\Autopilot\`) und wird mit der App-Sicherung gesichert:
- `HashArchiv_<Tenant>.dat`, `Ausscheiden_<Tenant>.dat` – verschlüsselt (DPAPI, nur dieser Windows-Benutzer). Auf einen anderen PC nur über die App-Sicherung.
- `Ausscheiden\<Tenant>\<Datum>\` – Protokolle, Import-CSV, Eltern-Pakete (personenbezogen). **Nach 6 Monaten** fragt die App beim Start, ob sie gelöscht werden sollen (nie automatisch).
- Benutzer aus Hash-Dateien werden nicht gespeichert. BitLocker-Schlüssel stehen nur auf der Übergabe zum Drucken (temporär, nach 10 Minuten bzw. beim nächsten Start gelöscht).

## Installation
Kommt ab **HU-MultiTenant 2.5.4** mit dem Programm (`Modules\Autopilot\`) und wird mit jedem App-Update aktualisiert – kein Token, keine eigene Signatur. Abschalten: in `Config\settings.json` `"modulesOff": ["Autopilot"]`. Zum Entwickeln lädt eine Fassung in `AddonsDev\Autopilot\` ohne Signatur und ersetzt die mitgelieferte.

## Veröffentlichen
Version in `addon.json` erhöhen und Abschnitt `## v<Version>` in `CHANGELOG.md` ergänzen; das Modul geht mit dem nächsten HU-MultiTenant-Release raus (Tests: `.github/tests/HU.ModAutopilot.Tests.ps1`).

## Grundlage
Konzept „Autopilot-Modul“ (Aufnehmen, Ausscheiden, Hash-Archiv) mit den Testpunkten T1–T9; Microsoft Learn (Windows Autopilot, Intune-Geräteaktionen, Microsoft Graph).
