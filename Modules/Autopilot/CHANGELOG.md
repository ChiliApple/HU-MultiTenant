# Changelog – Zusatzmodul Autopilot

## v0.5.3 – 27.10.2026 (mit HU-MultiTenant 2.6.0 Stable)

### 🛡️ Sicherheit
- **Rückfragen mit Warnung:** „Als ausgeschieden kennzeichnen“, „Dynamische Gruppe anlegen“ und „Fehlende Leserechte erteilen“ fragen als Warnung – Enter bedeutet „Nein“.

## v0.5.2 – 27.10.2026 (mit HU-MultiTenant 2.5.7 Test)

### 💾 Hash-Archiv
- **Dateiname mit Seriennummer:** „Hashes speichern …“ schlägt `Autopilot-Hash_<Seriennummer>_<Datum>.csv` vor, bei mehreren Geräten `Autopilot-Hash_<Tenant>_<Anzahl>-Geraete_<Datum>.csv`.

## v0.5.1 – 26.10.2026 (mit HU-MultiTenant 2.5.5 Stable)

### 🏷️ Anzeige
- Hinweis „Testversion“ im Kopf des Reiters entfernt.


### 🐛 Behoben (Prüfung 26.10.)
- **Zurückziehen:** Lässt sich der Autopilot-Eintrag nicht entfernen, wird **nicht** zurückgezogen – sonst ginge das Gerät beim nächsten Zurücksetzen wieder ins Schul-Setup. „Erneut versuchen“ hilft weiter.
- **Ausscheiden und Zurückziehen** sperren sich gegenseitig (vorher konnte ein zweiter Durchgang das Ergebnis des ersten überschreiben).
- **Wipe, Zurückziehen und Import** werden genau einmal gesendet (keine automatische Wiederholung). Antwortet Microsoft mit einem Serverfehler, steht „unbekannt – in Intune prüfen“.
- **Intune-Eintrag weg** heißt jetzt „vermutlich ausgeführt“; hat Intune die Ausführung nicht gemeldet, steht „nicht bestätigt“ im Protokoll.
- **Status prüfen** und **Intune-Eintrag löschen** kommen sich nicht mehr in die Quere.

### ✨ Verbessert
- **Gruppen-Erkennung:** Regeln mit Listen (`-in [...]`) werden erkannt, eine reine Liste gilt wie `-eq`; `-ne`/`-notIn` und nicht auswertbare Regeln mit Group Tag werden als „bitte prüfen“ gezeigt statt weggelassen.
- **Aufnehmen → Laden** räumt liegengebliebene, schon verarbeitete Import-Einträge auf (noch laufende bleiben).
- Hinweis nach dem Zurückziehen: Übergabe drucken und danach den Browser-Tab schließen.

### 🔐 Datenschutz
- **Aufbewahrung 6 Monate:** Beim Start fragt die App, ob Ordner mit Ausscheidungsprotokollen und Eltern-Paketen, die älter als 6 Monate sind, gelöscht werden sollen – nie automatisch. Abgeschlossene Vorgänge in der Nachverfolgung, die älter sind, werden dabei mit entfernt. Das Hash-Archiv bleibt.

## v0.5.0 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu – Ausscheiden
- **Liste reinziehen:** Abgängerliste (CSV, Excel oder Text, eine Spalte reicht) mit Seriennummern oder UPNs auf die Tabelle ziehen oder **„Liste …“** – die passenden Geräte werden markiert, Einträge ohne Treffer stehen im Protokoll.
- **Zurückziehen …** für Geräte, die bei der Familie bleiben: BitLocker-Wiederherstellungsschlüssel lesen (ohne Schlüssel kein Zurückziehen – „Erneut versuchen“ fragt dann „auch ohne Schlüssel?“) → Autopilot-Eintrag entfernen → Zurückziehen. Die Daten bleiben auf dem Gerät. Deutlicher Hinweis: Das Gerät bleibt im Schul-Entra angemeldet, Anmeldung nur mit dem Schulkonto.
- **Übergabe-Bestätigung** mit BitLocker-Schlüssel und Unterschriftsfeldern öffnet sich nach dem Zurückziehen im Browser **zum Drucken** – sie wird nicht gespeichert (nach 10 Minuten bzw. beim nächsten Start gelöscht), der Schlüssel steht in keinem Protokoll.
- **Pakete für Eltern …:** je markiertem Vorgang ein ZIP `<Seriennummer>_<Nachname>_Ausscheiden.zip` mit Ausscheidungsprotokoll, Import-CSV für die neue Schule und einem Hinweis für die Eltern, dazu `Uebersicht.csv` (Spalte für die Mailadresse der Eltern) und `Mailtext.txt` – ohne BitLocker-Schlüssel.
- **Nachverfolgung:** Spalte „Art“ (Ausscheiden / Zurückziehen).

### 🔐 Rechte
- **Zurückziehen:** zusätzlich BitlockerKey.Read.All (jeder Abruf steht im Entra-Überwachungsprotokoll) und DeviceManagementManagedDevices.PrivilegedOperations.All (Retire).

## v0.4.0 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu – Ausscheiden
- **Reiter „Ausscheiden“** (ein Tenant, oben „Laden“): Suche über Seriennummer, Gerätename, Benutzer (UPN) und Group Tag, Geräte markieren, **„Ausscheiden …“**.
- **Vorab-Prüfung je Gerät:** nicht in Intune, privates Gerät (wird nicht ausgeschieden – Zurückziehen folgt), letzte Synchronisierung älter als 30 Tage, Wipe/Retire schon offen, kein Hash im Archiv, kein Primärbenutzer.
- **Reihenfolge laut Konzept:** Benutzer im Autopilot-Eintrag aufheben → Autopilot-Eintrag entfernen → in der Autopilot-Liste nachlesen, bis er weg ist (höchstens 15 Minuten) → erst dann **Wipe** (Benutzer- und Registrierungsdaten werden nicht behalten). Ist der Eintrag dann noch da, gibt es **keinen Wipe** – mit **„Erneut versuchen …“** in der Nachverfolgung wird später neu geprüft und dann der Wipe gesendet.
- **Bestätigung** mit eingetipptem Tenant-Namen (ab 6 Geräten auch die Anzahl), höchstens 25 Geräte je Durchgang.
- **Nachverfolgung** unten: Autopilot, Wipe-Status (wartet auf Gerät / läuft / erledigt / fehlgeschlagen), Intune – automatisch alle 2 Minuten (2 Stunden lang), sonst „Status prüfen“. Die Vorgänge bleiben nach einem Neustart erhalten (verschlüsselt wie das Hash-Archiv).
- **Sync nachschieben:** Ist der Wipe 3 Minuten nach dem Senden noch nicht angekommen, schickt die App einmal automatisch einen Sync hinterher (zweites Signal an das Gerät); dazu der Knopf **„Sync senden“**. Bei ausgeschalteten Geräten hilft das nicht – sie holen den Wipe beim nächsten Einschalten ab.
- **Intune-Eintrag löschen …** erst nach erledigtem Wipe; das Entra-Geräteobjekt bleibt.
- **Protokoll je Gerät** (HTML zum Drucken) mit allen Schritten und dem Hardware-Hash, dazu eine **Import-CSV für die neue Schule** – „Protokolle …“ öffnet den Ordner. Im Hash-Archiv werden die Geräte als ausgeschieden gekennzeichnet.

### 🐛 Behoben (Test 26.10.)
- **Autopilot-Eintrag „hartnäckig“:** Der Einzelabruf per ID liefert einen gelöschten Eintrag noch lange (Test: nach 8 Minuten noch da, in der Liste schon weg). Geprüft wird jetzt über die Liste.

### 🔐 Rechte
- **Ausscheiden:** DeviceManagementServiceConfig.ReadWrite.All (Benutzer aufheben, Autopilot-Eintrag entfernen), DeviceManagementManagedDevices.PrivilegedOperations.All (Wipe, Sync), DeviceManagementManagedDevices.ReadWrite.All (Intune-Eintrag löschen). Fehlen sie, zeigt der Reiter ein Banner mit „Rechte erteilen …“.

## v0.3.0 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu – Aufnehmen
- **Reiter „Aufnehmen“:** Geräte kommen direkt aus dem Hash-Archiv des Tenants. Schon registrierte sind ausgeblendet (einblendbar, grau), Geräte aus dem Autopilot eines anderen Tenants rot markiert. „Alle neuen markieren“.
- **Laden** (im Reiter Aufnehmen) liest Group Tags (mit Anzahl, Groß/klein gilt als gleich), dynamische Gruppen mit Group-Tag-Regel und die zugewiesenen Autopilot-Profile – ändert nichts.
- **1. Group Tag:** vorhandenen wählen oder neu eintippen – zur Auswahl stehen die Tags der Geräte **und** die Tags aus den Regeln dynamischer Gruppen (z. B. ein neuer Jahrgang, der noch keine Geräte hat); erlaubt sind nur Buchstaben, Ziffern, `-` und `_`.
- **2. Gruppe:** zeigt, welche dynamische Gruppe den Tag trifft – sicher (`-eq`), „trifft mehrere Tags“ (`-startsWith`/`-contains`) oder „zusammengesetzte Regel – bitte prüfen“. Ohne sichere Gruppe: **Gruppe anlegen …** (Sicherheitsgruppe, Regel immer `-eq`, Verarbeitung ein) und **Angelegte Gruppe löschen …** als Rückgängig (nur Gruppen mit „angelegt von HU-MultiTenant“).
- **3. Profil:** Profil der Gruppe; Warnung, wenn die Geräte keines bekommen.
- **4. Vorschau & Import:** Bestätigung mit eingetipptem Tenant-Namen (ab 6 Geräten auch die Anzahl), höchstens 500 Geräte je Durchgang. Danach werden **alle** Import-Einträge entfernt und der Autopilot-Sync einmal ausgelöst (läuft er schon oder lief er vor weniger als 10 Minuten, wird das nur gemeldet).
- **Nachverfolgung:** „Status prüfen“ bzw. automatisch alle 2 Minuten (höchstens 2 Stunden): in Autopilot, in der Gruppe, Profil – mit **Dauer bis Gruppe** und **Dauer bis Profil** getrennt. Grün = bereit für die Ausgabe.
- **Tag ändern** (Übersicht, markierte Geräte eines Tenants): neuer Tag eintippen oder wählen, Anzeige von Gruppe und Profil des neuen Tags, Warnung bei schon eingerichteten Geräten (Gruppenwechsel wirkt sofort), Bestätigung mit Tenant-Namen. Geändert wird **nur der Group Tag** – Benutzer und Anzeigename bleiben. Danach Nachverfolgung (Gruppe, Profil) und **„Tag-Änderung rückgängig …“** (vorheriger Tag).
- **Fehlertexte beim Import** nach Microsoft (806 schon registriert, 808 in anderem Tenant → Vorbesitzer bzw. Lieferant muss freigeben, doppelt, Hash ungültig).
- **Rechte nur für den Ablauf:** fehlen sie, zeigt der Reiter ein Banner mit „Rechte erteilen …“.

- **Ausgeschieden kennzeichnen** (Hash-Archiv): „Ausgeschieden …“ setzt für die markierten Geräte ein Datum (neue Spalte), „Ausgeschieden aufheben“ nimmt es zurück. Der Hash bleibt im Archiv. Beim Aufnehmen werden ausgeschiedene Geräte nicht angeboten (einblendbar, grau, nie importiert). Die Kennzeichnung entfernt nichts aus Autopilot.

### ✨ Verbessert
- **Eine Tenant-Auswahl je Reiter:** Übersicht und Tags & Gruppen zeigen oben die Checkboxen (mehrere Tenants), Hash-Archiv, Aufnehmen und Ausscheiden an derselben Stelle ein Dropdown (ein Tenant, gilt für alle drei Reiter und wird gemerkt). Die eigenen Dropdowns in den Reitern sind weg.
- **Ein „Laden“-Knopf** für alles: Übersicht/Tags lesen die markierten Tenants, Hash-Archiv die Geräte des gewählten Tenants (für „Hash anfordern“), Aufnehmen Tags, Gruppen, Profile und Rechte.
- **Orange Knöpfe** (ändernde Aktionen) gedämpfter, nicht mehr so grell.
- **Tabelle / Export** der Übersicht enthält jetzt auch den **Benutzer (UPN)** (ohne Hash).
- **Hash-Archiv:** Knöpfe heißen jetzt **„Hash anfordern …“** (über die Wartung am Gerät) und **„Hashes abholen“**.
- **Markierte Zeilen** bleiben auch ohne Fokus dunkelblau (vorher hellgrau, z. B. während ein Dialog offen war).

### 🔐 Rechte
- **Aufnehmen:** DeviceManagementServiceConfig.ReadWrite.All (Import, Sync), Group.Read.All (Gruppen/Regeln), Group.Create (Gruppe anlegen), Device.Read.All (Gruppenmitgliedschaft der Geräte).
- **Angelegte Gruppe löschen:** laut Microsoft nur mit Group.ReadWrite.All – ob es mit Group.Create für die eigene Gruppe geht, ist Testpunkt T9. Ohne Recht meldet die App das und die Gruppe wird im Entra-Portal gelöscht.

## v0.2.0 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu – Hash-Archiv
- **Reiter „Hash-Archiv“** je Tenant, **verschlüsselt** (DPAPI, nur dieser Windows-Benutzer) im Datenordner für Zusatzmodule.
- **Dateien reinziehen** oder „Dateien hinzufügen …“: CSV (Komma oder Semikolon) und Excel, auch ganze Ordner. Erkannt werden Lieferanten-Dateien und Get-WindowsAutopilotInfo. Zeilen ohne Seriennummer oder mit ungültigem Hash werden übersprungen und gemeldet. Benutzer aus der Datei werden **nicht** gespeichert.
- **Hash per Wartung einsammeln:**
  - **„Hash anfordern …“** führt das Paket **HU-AP-Hash** auf den markierten Geräten aus (bzw. auf allen Autopilot-Geräten ohne Hash). Das Paket wird bei Bedarf angelegt – **ohne Zuweisung**. Bestätigung mit eingetipptem Tenant-Namen, ab 6 Geräten zusätzlich die Anzahl.
  - **„Hashes abholen“** liest die Ergebnisse, entpackt und prüft sie (Prüfsumme) und übernimmt gültige Hashes ins Archiv.
  - Am Gerät: Hash wird einmal gelesen, unter ProgramData gemerkt (nur SYSTEM/Administratoren) und komprimiert ausgegeben (eine Zeile, ca. 1.300 Zeichen). Kein Secret am Gerät.
- **Spalte „Benutzer (UPN)“** auch im Hash-Archiv (aus der Übersicht, nur Anzeige – nicht im Archiv gespeichert).
- **Falscher Tenant erkannt:** Stehen Geräte aus einer Datei laut Autopilot in einem anderen Tenant, fragt die App (die Seriennummern aller Tenants holt sie dafür selbst, die Übersicht muss nicht geladen sein) und legt sie auf Wunsch gleich dort ins Archiv. Geräte, die in keinem Autopilot stehen, gehen mit, wenn die Mehrheit ihrer Datei zu diesem Tenant gehört.
- **Abgleich** mit der Übersicht: Autopilot-Geräte ohne Hash werden mit angezeigt (orange) und gezählt.
- **„In Autopilot“ sofort befüllt:** ja/nein steht auch ohne geladene Übersicht da (die App holt die Seriennummern im Hintergrund, höchstens alle 10 Minuten neu). Die Summenzeile zählt Geräte mit Hash, die nicht (mehr) in Autopilot stehen.
- **Filter „nur nicht in Autopilot“:** zeigt nur Geräte mit Hash, die in Autopilot fehlen (z. B. Abgänger) – zum gezielten Markieren und Entfernen.
- **Export CSV** (Microsoft-Format) der markierten Geräte – mit Warnung, die Datei ist unverschlüsselt. **Entfernen** einzelner Geräte.
- **Sortierung:** neueste oben (zuletzt eingelesen, sonst zuletzt in Intune eingerichtet); Spalte „Eingerichtet am“; Spaltenklick sortiert und dreht um.
- Mehrere Hashes je Gerät bleiben erhalten (der Hash ist bei jedem Lesen am Gerät anders), der neueste gilt.

### 🐛 Behoben
- **Protokoll:** Meldestufe „SUCCESS“ gibt es im Programm nicht – jetzt „OK“ (Fehlermeldung beim Abholen, Hash wurde trotzdem übernommen).
- **Tenant-Prüfung beim Einlesen:** Fehler 500 von Intune bei einem Tenant (Abfrage mit `$select`) – jetzt dieselbe Abfrage wie die Übersicht.
- **Speichern des Archivs:** „Der Pfad hat ein ungültiges Format“ beim zweiten Speichern behoben.

### 🔐 Rechte
- **Lesen:** zusätzlich DeviceManagementScripts.Read.All.
- **Wartung starten:** DeviceManagementScripts.ReadWrite.All, DeviceManagementManagedDevices.PrivilegedOperations.All.

## v0.1.3 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu
- **Spalte „Benutzer (UPN)“:** Primärbenutzer laut Intune, sonst der in Autopilot zugewiesene – auch im Detailfenster und im Filter. Der Inventar-Export bleibt ohne Benutzer.

### 🐛 Behoben
- **Spaltenbreiten:** werden nach jedem Laden, Filtern und Sortieren neu berechnet (vorher wuchsen sie nur); jede Spalte hat eine Höchstbreite.

## v0.1.2 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu
- **Spalte „Eingerichtet am“:** Datum der Einrichtung in Intune (Autopilot selbst liefert kein Registrierungsdatum), auch im Detailfenster und Export.
- **Sortierung:** zuletzt eingerichtete Geräte oben; Klick auf eine Spalte sortiert, nochmals Klick dreht um. Die gewählte Sortierung bleibt beim Neuladen erhalten.

## v0.1.1 – 26.10.2026 (Testversion, nur lokal)

### 🐛 Behoben
- **Status:** Profilstatus „zugewiesen (Sync unbekannt)“ ist bei Intune der Normalfall und gilt jetzt als **Bereit** (vorher Warnung bei fast allen Geräten). Warnung nur noch bei „nicht synchron“.

## v0.1.0 – 26.10.2026 (Testversion, nur lokal)

### 🆕 Neu
- **Reiter Autopilot** mit Tenant-Auswahl, Rechte-Hinweis und Ausgabefeld.
- **Übersicht (nur lesen):** alle Autopilot-Geräte der markierten Tenants mit Status (Bereit, Warnung, Fehlt, Fehler), Seriennummer, Hersteller, Modell, Group Tag, Profilstatus, Registrierung, Abgleich mit Intune (Gerätename, letzter Sync) und Hinweis.
  - **Filter:** Text, „nur nicht bereit“, „nur ohne Intune“.
  - **Doppelklick:** Detailfenster mit allen Werten (größenveränderbar, Größe wird gemerkt).
  - **Tabelle / Export:** Inventar ohne Benutzer und ohne Hash.
- **Tags & Gruppen:** Anzahl Geräte je Group Tag (bereit, ohne Profil, in Intune).
- Platzhalter für Aufnehmen, Ausscheiden und Hash-Archiv.

### 🔐 Rechte
- **Lesen:** DeviceManagementServiceConfig.Read.All, DeviceManagementManagedDevices.Read.All.
