# HU-MultiTenant Changelog

## v2.6.4 (Stable, 28.10.2026)

Stable-Release der Testversionen 2.6.1 bis 2.6.3 – „Windows-Updates“. Alle Punkte im Detail stehen in den Abschnitten darunter.

### 🪟 WIN-Updates (Wartung)
- **Überblick über alle Tenants:**
  - Windows-Versionen mit Patchstand und Support-Ende
  - Geräte mit fehlenden Updates
  - anstehende Treiber
- **Ringe und Profile verwalten:**
  - Update-Ringe, Feature-Updates, Treiber-Richtlinien und Expedites anlegen, zuweisen, ändern, pausieren und löschen.
  - Update-Ringe lassen sich nur ohne Zuweisung löschen.
  - Vor jeder Änderung wird der Stand gesichert.
- **Vorlagen:** Ringe und Profile als Datei sichern und in anderen Tenants importieren, ohne Zuweisungen. Die Vorlagen kommen mit der App-Sicherung mit.
- **So geht's:** kurze Anleitungen mit Knöpfen, die gleich die richtige Stelle öffnen.

### 🔐 Rechte
- **Neue Tenants bekommen zuerst nur das Nötige:** Umfang *Nur lesen* bzw. *Lesen + verteilen*.
- **Spalte „App braucht“:** zeigt, welche Rechte die App wirklich nutzt und welche nicht gebraucht werden.
- **Fehlt ein Schreibrecht**, bietet die App es nach dem Lauf an.

### 🎨 Oberfläche
- **Fenster nie abgeschnitten:**
  - Alle Dialoge haben einen Anfasser und eine Mindestbreite.
  - Lange Texte und Häkchen brechen um.
  - Das Fenster für Client Secrets passt sich in der Höhe an.

### ⚠️ Nach dem Update
- **WIN-Updates ändern** braucht das Recht `DeviceManagementConfiguration.ReadWrite.All`. Die App bietet es an, wenn es fehlt.
- **Feature-, Treiber- und Expedite-Profile** wirken nur auf Entra- oder Hybrid-beigetretene Geräte mit Diagnosedaten mindestens „Erforderlich“ und einer Windows-Lizenz mit Autopatch-Berechtigung.

### ✅ Qualität
- 953 automatische Tests.

## v2.6.3 (Testversion)

Neu in der Wartung: **WIN-Updates** – Windows-Versionen, Patchstand und Treiber aller Tenants auf einen Blick, Ringe und Profile anlegen, zuweisen und übernehmen.

### 🪟 WIN-Updates (Wartung)
- **Übersicht:** Windows-Versionen je Tenant mit Patchstand (aktuell, 1 Update fehlt, veraltet), neuestem Sicherheitspatch und Support-Ende; Farben zeigen, wo es hakt. Doppelklick zeigt die Geräte dieser Version.
- **Geräte:** fehlende Updates, letzter Sync, Beitritt (Entra, Hybrid, nur registriert) und Besitz; Vorfilter per Häkchen und Textfilter, sortierbar.
- **Ringe und Profile:** Update-Ringe, Feature-Updates, Expedites, Qualitäts- und Treiber-Updates aller angehakten Tenants – gleicher Name in mehreren Tenants in einer Zeile, Hinweise bei auffälligen Einstellungen (z. B. alte Expedites, übersprungene Neustart-Prüfung).
- **Zuweisen und Einstellungen** wie in *Wartung › In Intune*: Gruppe zuweisen oder ausschließen, Aufschub, Fristen, aktive Zeit, Pause und Fortsetzen; vor jeder Änderung wird der Stand gesichert.
- **Neu anlegen:** Update-Ring, Feature-Update (Zielversion, sofort, ab Datum oder gestaffelt), Treiber-Richtlinie (automatisch mit Aufschub oder manuell) und Expedite – immer ohne Zuweisung.
- **Treiber:** anstehende Treiber aller Richtlinien mit betroffenen Geräten; markierte freigeben (ab Datum), aussetzen oder ablehnen.
- **Löschen:** Profile, auch mehrere markierte auf einmal; Update-Ringe nur, wenn sie nicht zugewiesen sind (vor dem Löschen frisch in Intune geprüft).
- **Vorlagen:** markierte Ringe und Profile als Datei sichern und in anderen Tenants importieren (auch per Hineinziehen) – ohne Zuweisungen, gleicher Name wird ausgelassen.
- **Export** der angezeigten Tabelle als Excel-Tabelle oder CSV.

### ❓ So geht's
- **Kurze Anleitungen mit Knöpfen** in einem kleinen Fenster, das offen bleibt: neue Windows-Version verteilen, Treiber automatisch verteilen, Sicherheitsupdate erzwingen, in andere Tenants übernehmen, Fehlersuche. Einheitlich aufgebaut, weitere Bereiche folgen.

### 💾 App-Sicherung
- **WIN-Updates-Vorlagen** und der Stand vor Änderungen werden immer mitgesichert.

## v2.6.2 (Testversion)

Kleine Verbesserungen.

### 🔐 Rechte
- **Rechte-Fenster:** neue Spalte **App braucht** (*Standard*, *Verteilen*, *bei Bedarf*); erteilte Rechte, die weder die App noch eine Extension oder ein Snippet nutzt, stehen als **nicht gebraucht** da. „Genutzt von“ zeigt jetzt auch Snippets (Zeile `# Berechtigungen:`). Lesen, das im erteilten ReadWrite-Recht enthalten ist, steht als (✔).

### 🔎 Analyse
- **Was bekommt …?** wertet jetzt auch **Qualitäts- und Treiber-Update-Richtlinien** aus.

### 🗺️ Doku
- **Einstieg:** „In 10 Minuten startklar“ ganz oben mit Hinweis „Neu hier?“, der erste Versuch ist Schritt 3; Tipps in „Morgens wissen, ob alles läuft“ (Secret-Countdown, Lizenzen, Not-Aus).

## v2.6.1 (Testversion)

Nacharbeiten zur Stable 2.6.0: weniger Rechte von Haus aus, mehr Schutz beim Import und Wiederherstellen.

### 🔐 Rechte
- **Tenant einrichten mit Umfang:** Knöpfe **Nur lesen** und **Lesen + verteilen**. Ein neuer Tenant startet mit *Lesen + verteilen* (Apps hochladen und zuweisen, Wartung anlegen, *Jetzt ausführen*); *Rechte erteilen* bei einem bestehenden Tenant startet mit *Nur lesen*. Weitreichende Rechte werden weiter eigens bestätigt.
- **Lesen für Apps und Wartung** braucht nur noch `DeviceManagementApps.Read.All` bzw. `DeviceManagementScripts.Read.All`.
- **Fehlt ein Schreibrecht** beim Hochladen, Zuweisen oder *Jetzt ausführen*, bietet die App nach dem Lauf an, genau dieses Recht zu erteilen („Nein“ vorgewählt). Bereits erteilte Rechte bleiben unverändert.

### ⭐ Muster-Bibliothek
- **Ungeprüfte Pakete einzeln bestätigen:** beim Anwenden eine Prüfansicht je Paket („Paket 1 von 3“); Abbrechen stoppt, vorher bestätigte Pakete bleiben bestätigt.
- **Import:** Herausgeber, Titel, Kategorie und Tags aus fremden Dateien werden bereinigt (Steuer- und Richtungszeichen) und gekürzt; der Herausgeber ist als „nicht verifiziert“ gekennzeichnet.

### 💾 App-Sicherung
- **Wiederherstellen:** Snippets, Wartungsskripte, Teams-Aufträge und Teams-Ziele sind **orange und nicht vorgewählt** – sie enthalten Skripte bzw. Webhook-Adressen. Nur anhaken, wenn die Sicherung von dir stammt.
- **Falsches Kennwort:** die Meldung sagt jetzt, was zu prüfen ist (Tastatur, richtige Datei, vollständig kopiert).
- **Sicherung auf Freigabe oder USB** wird vor dem Öffnen lokal kopiert; Prüfung und Entschlüsseln lesen so sicher dieselbe Datei. Liegen gebliebene Temp-Dateien früherer Läufe werden aufgeräumt.
- **PowerShell 7:** Schlüssel über das aktuelle .NET-Verfahren; unter PowerShell 5.1 klare Meldung, wenn .NET Framework 4.7.2 fehlt.

### 📱 Fernbedienung
- **Abbruch einer Teams-Meldung greift sofort:** nach dem Abbruch geht keine Karte mehr raus – auch nicht aus einem Skript, das gerade läuft oder hängt.

### 🎨 Oberfläche
- **Erster Start:** der Starter `HU-MultiTenant.exe` (eigenes Logo, ohne Konsolenfenster) wird gleich angelegt, dazu einmal die Frage nach einem Desktop-Symbol und das Angebot, den Einstieg im Browser zu öffnen.
- **Meldungsfenster für Screenreader:** Fenster, Symbol, Text und Knöpfe sind benannt; der vorgewählte Knopf wird als „(Enter)“ angesagt.

### 🗺️ Doku
- **Einstieg mit 12 Situationen:** neu „Die neuen Schüler-Notebooks sind da“ (Hash-Archiv, auch für die bestehende Flotte), „Schulschluss: Abgänger-Geräte“, „Sind wir sicher eingestellt?“ und „MFA für alle Lehrkräfte“. „Neuer PC“ und „Ich bin nicht am PC“ stehen nur noch in der Anleitung. **„In 10 Minuten startklar“ steht jetzt ganz oben** (mit Hinweis „Neu hier?“), der erste Versuch ist Schritt 3.
- Anleitung und Installation: Rechte-Umfang, Wiederherstellen, .NET Framework 4.7.2.

### ⚠️ Nach dem Update
- Bestehende Tenants behalten ihre Rechte. Wer einen Tenant bewusst nur lesend betreiben will, entzieht die Schreibrechte im Entra Admin Center.

## v2.6.0 (Stable, 27.10.2026)

Stable-Release der Testversionen 2.5.6 bis 2.5.9 – „Austausch und Sicherung“. Alle Punkte im Detail stehen in den Abschnitten darunter.

### ⭐ Muster-Bibliothek
- **Exportieren und importieren:** Pakete als Datei `.humuster` weitergeben – bereinigt (ohne Personen, Zuweisungen, Geheimnisse und Tenant-Kennungen) und beim Import geprüft; JSON-Dateien aus dem Portal oder der Community per Ziehen übernehmen. Importierte Pakete erst nach „Als geprüft bestätigen“ anwendbar.
- **Microsoft-Vorlagen holen:** Vorlagen für bedingten Zugriff direkt von Microsoft als neues Paket – gilt als geprüft (Quelle Microsoft), beim Anwenden immer im Modus *Nur Bericht*; Vorlagen mit Zusatzlizenz nicht vorgewählt. Braucht das Recht `Policy.Read.All`.
- **Prüfansicht mit Rohdaten** per Doppelklick; „Im Tenant-Vergleich ansehen“ nimmt das gezeigte Paket.

### 💾 App-Sicherung
- **Neuer Reiter „Sicherung“:** Einstellungen, Tenants, Snippets, Wartung, Apps, Teams-Aufträge samt Zielen, Fensterzustand und Daten der Zusatzmodule in eine verschlüsselte Datei (AES-256, Kennwort Pflicht); dazu standardmäßig die Muster-Bibliothek, auf Wunsch die Tenant-Backups.
- **Automatisch** täglich oder wöchentlich, **Prüfen** ohne zu schreiben, **Wiederherstellen** mit Auswahl, Vorstand und Neustart. Fortschritt in der Kopfzeile, Hinweis unten rechts.

### 🛡️ Sicherheitskatalog
- **V5** mit Sollwert für die Richtlinien des MFA-Grundschutzes, **A42** mit erlaubten Apps; auffällige Zeilen dezent eingefärbt.

### 🎨 Oberfläche
- **Rückfragen, die im Tenant schreiben, löschen oder Rechte erteilen, sind Warnungen:** „Nein“ ist vorgewählt (Enter, erkennbar am hellen Rahmen), der Ja-Knopf rot – z. B. Zuweisen, Ändern, Hochladen, Freigeben, Rechte erteilen, Einrichtung entfernen. Ein Test prüft das für alle Rückfragen.
- **Meldungen und Rückfragen im App-Stil** statt Windows-Meldungen; Ausgaben mit neuestem Ereignis oben, Umkehren und Löschen; Knöpfe nie abgeschnitten.

### 💻 Modul Autopilot 0.5.3
- Hash-Dateiname mit Seriennummer bzw. Tenant und Anzahl; Rückfragen zum Kennzeichnen, Gruppe anlegen und Rechte erteilen als Warnung.

### 🗺️ Doku
- **Einstieg:** neue Situationen „Ein Kollege soll meine Einstellungen haben“ (Muster exportieren, Microsoft-Vorlagen) und „Neuer PC“ (App-Sicherung); Anleitung, Funktionsübersicht, Roadmap und Installation (`Policy.Read.All` für Vorlagen) auf Stand 2.6.0.

### ⚠️ Bekannte Grenzen
- **App-Sicherung:** Secrets und Zertifikate sind an PC und Windows-Benutzer gebunden und nicht enthalten – nach dem Wiederherstellen auf einem neuen PC je Tenant neu einrichten; ebenso gekoppelte Handys und Freigaben der Fernbedienung. Zusatzmodule werden nur vermerkt und müssen neu installiert werden.
- **App-Sicherung:** beim Lesen höchstens 2 GB; die Automatik läuft nur, solange HU-MultiTenant geöffnet ist (oder beim nächsten Start). Bricht das Wiederherstellen mittendrin ab, liegt der vorige Stand unter `%APPDATA%\HU-MultiTenant\Wiederherstellung`.
- **App-Sicherung – Kennwort:** Ohne Kennwort ist eine Sicherung nicht zu öffnen – **vergessenes Kennwort = Sicherung verloren**. Das für die Automatik gespeicherte Kennwort gilt nur auf diesem PC für diesen Windows-Benutzer und hilft auf einem neuen PC nicht – Kennwort deshalb im Kennwort-Manager aufbewahren.
- **App-Sicherung – wie ein Geheimnis behandeln:** Die Datei enthält (verschlüsselt) Teams-Webhook-Adressen, Tenant-Einstellungen, Snippets und Wartungsskripte. Ordner nur für dich zugänglich wählen; Sicherungen **nur aus eigener Quelle wiederherstellen** – wiederhergestellte Snippets und Wartungsskripte laufen danach mit den Rechten der Tenants bzw. als SYSTEM auf den Geräten.
- **Muster-Austausch:** WLAN-, VPN- und Zertifikatprofile werden nicht exportiert, Skripte nur nach Einzelfreigabe. **Beim Import werden Skripte (Plattform-Skripte, Wartung) nie übernommen** – auch nicht, wenn sie beim Export freigegeben waren; fremde Skripte bitte selbst prüfen und von Hand anlegen. Workload-Identitäten und Nutzungsbedingungen in Conditional Access sind gesperrt (gibt es nur im eigenen Tenant); Gruppen, Orte und eigene Stärken gehen nur als Namen mit und werden beim Anwenden im Ziel zugeordnet. Pakete sind (noch) nicht signiert – die Prüfung beim Import ersetzt keine Vertrauensprüfung des Absenders.
- **Microsoft-Vorlagen:** Inhalt kommt unverändert von Microsoft (Graph); neue oder geänderte Vorlagen werden beim erneuten Holen (noch) nicht hervorgehoben.

## v2.5.9 (Testversion)

Dritte Stufe von 2.6.0 „Austausch und Sicherung“.

### 💾 App-Sicherung
- **Neuer Reiter „Sicherung“ in den Einstellungen:** sichert Einstellungen und Tenants, Quick-Script-Snippets, Wartungsskripte, Apps samt Symbolen, Teams-Aufträge **mit ihren Zielen (Webhook-Adressen)**, Fensterzustand, Fernbedienungs-Einstellungen und die Daten der Zusatzmodule in **eine Datei** (`.husicherung`). Auf Wunsch zusätzlich die eigenen Muster-Pakete samt Mustertenant und die Tenant-Backups.
- **Immer mit Kennwort verschlüsselt:** AES-256 mit Prüfsumme (HMAC-SHA256), Schlüssel aus dem Kennwort per PBKDF2 (600 000 Durchgänge). Ein falsches Kennwort und eine veränderte Datei werden gleich gemeldet; entschlüsselt wird erst nach der Prüfung.
- **Bewusst nicht enthalten:** Secrets und Zertifikate (an diesen PC gebunden), gekoppelte Handys, Freigaben der Fernbedienung und die Sperr-PIN – nach dem Wiederherstellen neu eintragen.
- **Automatisch** täglich oder wöchentlich nach Kalendertagen: beim ersten Start des Tages bzw. – wenn die App durchläuft – kurz nach Mitternacht (geprüft alle 15 Minuten; nach einem Fehlschlag frühestens nach einer Stunde erneut), mit gespeichertem Kennwort (Windows-Datenschutz, nur dieser Benutzer). Die neuesten *N* Sicherungen **dieses PCs** bleiben, ältere eigene werden gelöscht – in einem gemeinsamen Ordner bleiben die Sicherungen anderer PCs unberührt. Jede Sicherung wird nach dem Schreiben zurückgelesen und geprüft – auch auf Netzwerkfreigaben.
- **Sichtbar im Hauptfenster:** neben dem Schlüssel zeigt 💾 die letzte Sicherung (Tooltip), während einer Sicherung den Fortschritt in Prozent, bei einem Fehler ein orangefarbenes „!“; Klick öffnet Einstellungen › Sicherung. Im Reiter steht der Fortschritt bei „Letzte Sicherung“, der Knopf ist solange gesperrt.
- **Hinweis unten rechts** (im App-Stil) nach jeder automatischen Sicherung: erstellt (mit Dateien und Größe), fehlgeschlagen oder übersprungen (kein Kennwort gespeichert). Verschwindet von selbst (Fehler nach 20 s), bleibt stehen, solange die Maus darauf ist; Klick öffnet Einstellungen › Sicherung (nicht bei gesperrter App).
- **Sicherung prüfen:** Kennwort, Prüfsummen und Inhalt testen, ohne etwas zu schreiben.
- **Wiederherstellen:** Bereiche per Haken wählen (Stand in der Sicherung ↔ aktuell). Vorher wird der aktuelle Stand der betroffenen Dateien abgelegt (`%APPDATA%\HU-MultiTenant\Wiederherstellung`, die letzten 5). `settings.json` wird vorher probeweise geladen. Teams-Ziele werden auf dem neuen PC wieder verschlüsselt abgelegt; Teams-Aufträge, deren Ziel es danach nicht gibt, werden pausiert. Danach ein Hinweis: fehlende Secrets, nicht vorhandene Ordner, nicht installierte Zusatzmodule. Sicherungen aus einer neueren Version werden abgelehnt. Haken mit einem Klick, „Alle“ setzt bzw. entfernt alle. Danach startet die App **immer neu** (das Einstellungsfenster schließt ohne Speichern) – so kann kein alter Stand aus dem Speicher den wiederhergestellten überschreiben.

### 🎨 Oberfläche
- **Meldungen und Rückfragen im App-Stil:** alle Hinweise, Fehler und Ja/Nein-Fragen erscheinen jetzt im dunklen Design der App statt als Windows-Meldung – mit farbigem Symbol, Knöpfen in App-Farben und markierbarem Text (Strg+C kopiert die ganze Meldung). Das Fenster wächst mit dem Text; ein Rollbalken kommt erst, wenn der Text nicht mehr auf den Bildschirm passt. Bei Warnungen ist „Nein“ der Standard für Enter.

## v2.5.8 (Testversion)

Zweite Stufe von 2.6.0 „Austausch und Sicherung“.

### ⭐ Muster-Bibliothek
- **Microsoft-Vorlagen holen:** Knopf unten in der Bibliothek liest die Vorlagen für bedingten Zugriff direkt von Microsoft (Graph, `Policy.Read.All`). In der Prüfansicht mit Haken auswählen, Name vergeben – es entsteht ein neues Paket (Herausgeber Microsoft, schon geprüft). Beim Anwenden kommt jede Vorlage neu im Modus *Nur Bericht* an, ohne Konten und Gruppen, die Notfallkonten des Ziels ausgenommen.
- **„Im Tenant-Vergleich ansehen“** vergleicht das rechts gezeigte Paket (ist es nicht angehakt, kommt es zu den angehakten dazu) und zeigt alle Arten statt einer vorher gewählten. Steht ein Eintrag nur im Muster, heißt der Status jetzt **„nur im Muster (fehlt in allen Tenants)“** statt „nur in einem“.
- **Muster anwenden:** Schließen, während die Admin-Anmeldung noch offen ist, fragt nicht mehr nach „Rechte zurückgeben“. Kommt die Anmeldung danach doch noch zurück, wird **nichts** erteilt (nur im Protokoll vermerkt).
- **Vorlagen:** Vorlagen mit Zusatzlizenz (Entra ID P2, Workload ID Premium, Purview Insider-Risiko) sind nicht vorgewählt und nennen die Lizenz; eingebaute Authentifizierungsstärken (z. B. phishingresistente MFA) bleiben erhalten. Gelesen wird über den gewählten Tenant (die Vorlagen sind überall gleich). Das Paket zeigt als Herkunft „Microsoft-Vorlagen“.
- **Rohdaten in der Prüfansicht:** Doppelklick auf einen Eintrag zeigt ihn als JSON – genau so, wie er bereinigt in die Datei bzw. das Paket geht (Export, Import, Vorlagen, Bestätigen).

## v2.5.7 (Testversion)

Erste Stufe von 2.6.0 „Austausch und Sicherung“.

### ⭐ Muster-Bibliothek
- **Exportieren:** Paket als Datei `.humuster` speichern. Vorher zeigt eine **Prüfansicht**, was mitgeht und was gesperrt ist. Bereinigt werden Zuweisungen, Benutzer, IP-Bereiche, Prüfer der Administratorzustimmung, Bereichsmarkierungen (auf Standard) und Benachrichtigungen; Gruppen gehen nur als Name mit. Gesperrt sind Einträge mit Geheimnissen, Kennungen oder Domains eigener Tenants, Zertifikat-, WLAN- und VPN-Profile sowie Skripte ohne Einzelfreigabe. Namen, Beschreibungen, Links und Geräteregeln sind zum Ansehen markiert. Prüfsumme (SHA-256) zum Weitergeben.
- **Importieren:** Knopf oder Dateien auf die Bibliothek ziehen – `.humuster` oder **JSON-Dateien** aus dem Portal bzw. der Community (Conditional Access, benannte Orte, Authentifizierungsstärken, bekannte Intune-Objekte). Geprüft werden Größe, Anzahl, entpackte Größe, Pfade, Prüfsummen, Mindestversion, Verschachtelung und doppelte Schlüssel; bereinigt wird wie beim Export. Es entsteht immer ein **neues** Paket.
- **Ungeprüft:** Importierte Pakete sind gekennzeichnet und lassen sich erst nach **„Als geprüft bestätigen“** anwenden – rechts am Paket oder automatisch beim Start von „Muster anwenden“.
- **Speicherort direkt in der Prüfansicht:** „Speichern unter …“ öffnet den Dialog über der Prüfansicht (Abbrechen führt zurück); Start im zuletzt verwendeten Ordner, sonst in *Downloads*.
- **Prüfung 068 eingearbeitet:** Custom-Profile mit OMA-URI für WLAN, VPN oder Zertifikate sind gesperrt; eingebettete Inhalte (Base64, z. B. iOS/macOS-Profile) werden entpackt und auf Schlüssel, Zertifikate und Kennwörter geprüft. Gruppen-Platzhalter aus fremden Dateien erscheinen in der Prüfansicht, Ausnahme-Gruppen hervorgehoben. Ungeprüfte importierte Einträge lassen sich weder anwenden noch aus dem Tenant-Vergleich übertragen. Dazu strengere Prüfungen beim Lesen (ZIP-Verzeichnis gegen Einträge, 5 MB je Eintrag, Kommentare und kodierte doppelte Schlüssel in JSON, Tenant-Domains auch in Feldnamen).
- **Herkunft bleibt:** Importierte Pakete behalten Herausgeber und Kennzeichen auch beim Bearbeiten und erneuten Exportieren.

### 💻 Modul Autopilot 0.5.2
- **Hash speichern:** Der Dateiname enthält die Seriennummer (`Autopilot-Hash_<Seriennummer>_<Datum>.csv`, bei mehreren Geräten `Autopilot-Hash_<Tenant>_<Anzahl>-Geraete_<Datum>.csv`).

## v2.5.6 (Testversion)

### 🛡️ Sicherheitskatalog
- **V5 MFA-Grundschutz – neuer Sollwert `policies`:** Richtlinien, die zusammen den Grundschutz bilden (z. B. je Gruppe für Admins, Verwaltung, Lehrkräfte, Cloud-Konten, Gäste). Eintrag als Nummer am Namensanfang (`100` trifft „100 - …“, nicht „1000“) oder voller Name. Sind alle vorhanden und aktiv, ist V5 erfüllt; sonst nennt die Zelle, welche fehlt oder nicht aktiv ist. Die Liste „Richtlinien anzeigen“ zählt sie mit.
- **A42 Apps mit kritischen Rechten – neuer Sollwert `allowedApps`:** gewollte Apps (Anzeigename oder Objekt-ID, z. B. die Sync-App der Schulverwaltung) stehen weiter in der Liste, zählen aber nicht. Die Liste hat dazu die Spalte *Zaehlt* (Ja / dieses Programm / erlaubt).
- **Auffällige Zeilen dezent eingefärbt (global):** Listen im Katalog haben die Spalte *Bewertung* – z. B. K03 Lizenzen („überbucht“ / „ab 95 %“), K04 Fehlversuche, A42 zählende Apps, Richtlinien-Listen (V5, A24, A25 …) mit Richtlinien, die zählen würden, aber nicht aktiv sind. Bei V5 mit Sollwert zählen in der Liste nur die genannten Richtlinien. Diese Zeilen bekommen dieselbe dezente Färbung wie „abweichend“ in den Vergleichen. Auch im Detailfenster einer Regel sind Tenants mit *Abweichung* eingefärbt; die Färbung greift jetzt zuverlässig schon beim Öffnen des Fensters.

### 🔍 Prüfung (Review 066)
- **A42 erlaubte Apps sicher erkannt:** Am besten die Objekt-ID eintragen (steht jetzt als Spalte *ObjektId* in der Liste). Ein Anzeigename gilt nur, solange er unter den Apps mit kritischen Rechten eindeutig ist – gibt es eine gleichnamige zweite App, zählen beide und die Zelle nennt den Grund.
- **„Löschen“ in Ausgaben trifft nie einen fremden Knopf:** Ein eigener Knopf des Moduls wird nur übernommen, wenn er ausdrücklich markiert ist oder genau „Leeren“/„Ausgabe leeren“ heißt und in derselben Zelle über der Ausgabe sitzt; sonst leert „Löschen“ nur die Ausgabe.
- **Kleinere Härtungen:** Färbung erkennt „Abweichungen“ und übergeht „Abweichung: 0“ bzw. „nicht abweichend“; V5 nennt „nur Bericht“ eigens; Sollwert-Namen lehnen unsichtbare Steuer- und Formatzeichen ab.

### 🖥️ Oberfläche
- **Knöpfe nie abgeschnitten (global):** Knöpfe in Knopfleisten wachsen mit ihrer Beschriftung, auch wenn der Text erst später gesetzt wird (z. B. „Zustimmungen anzeigen“ im Sicherheitskatalog) – in allen Fenstern, Reitern und Modulen.
- **Ausgaben: neuestes Ereignis oben (global):** Jede Ausgabe (Protokoll, Quick Script, Apps, Wartung, Analyse, Muster, Module) zeigt das Neueste oben. Rechts oben sitzen die kleinen Knöpfe **Umkehren** (neuestes oben/unten, wird je Ausgabe gemerkt) und **Löschen**. Ein eigener „Leeren“-Knopf über der Ausgabe (z. B. in Modulen) wird dabei ausgeblendet, Löschen übernimmt seine Aufgabe.
- **Sicherheitskatalog – Doppelklick:** Im Detailfenster einer Regel öffnet ein Doppelklick auf eine Tenant-Zeile dieselbe Liste wie der Knopf (Konten, Richtlinien, Lizenzen … anzeigen) bzw. „Von Hand geprüft …“.
- **Entwicklungs-Module:** Ordner in `AddonsDev` mit `_` oder `.` am Anfang gelten als abgeschaltet und werden ohne Warnung übergangen.
- **Kopfzeile:** Die Zertifikat-Anzeige zeigt nur noch den farbigen Schlüssel (grün/orange/rot) – Ablaufdatum und Details je Tenant stehen im Tooltip.

### 🗺️ Doku
- **Neue Screenshots (v2.5.6):** Sicherheit, Muster, Autopilot, Quick Script, Apps und Wartung im README – Tenants anonymisiert (Schule A–E).
- **Autopilot V1 und V2:** Roadmap, Funktionsübersicht, Anleitung und Modul-README nennen das jetzige Modul V1 (klassisch, mit Hardware-Hash); V2 (Windows Autopilot device preparation) folgt im selben Reiter.

## v2.5.5 (Stable, 26.10.2026)

Stable-Release der Testversionen 2.5.1 bis 2.5.4 – „Muster-Bibliothek und Autopilot“. Alle Punkte im Detail stehen in den Abschnitten darunter.

### ⭐ Muster-Bibliothek
- **Mehrere Muster-Pakete** (Teilpaket oder Gesamtstand) mit Kategorien, Schlagwörtern und Herkunft; Vergleich mit Teilpaketen.
- **Mitgelieferte Pakete** nach Microsoft-Empfehlung, BMB Security Baseline V2.1 und Praxis-Set Schule.
- **Muster anwenden:** Assistent für einen oder mehrere Tenants – Rechte nur für die Dauer des Ablaufs, Zuordnen an einer Stelle, Vorschau fürs ganze Paket, Rückgängig fürs Paket.
- **Vergleich mit Muster:** Conditional Access gilt als „wie Muster“, wenn nur Status, Notfallkonten (Sollwert V1) oder Platzhalter abweichen – auch zwischen den Tenants.

### 💻 Modul Autopilot
- **Eigener Reiter**, mitgeliefert im Programm: Übersicht mit Ampel, Group Tag ändern, verschlüsseltes Hash-Archiv, Aufnehmen mit Gruppen- und Profil-Erkennung, Ausscheiden und Zurückziehen mit Protokoll und Eltern-Paket. Abschaltbar mit `"modulesOff": ["Autopilot"]`.

### 🛡️ Sicherheitskatalog
- **Handprüfungen M01–M05** für den Rest der Security Baseline (lokales AD, Ablauf von Freigabelinks), Bestätigung je Tenant für 12 Monate.
- **A17** mit Sollwert für die erlaubte Benutzerzustimmung.

### 📱 Fernbedienung
- **Anwesenheit am PC:** gesperrt, getrennte Sitzung oder 5 Minuten ohne Eingabe gilt als „weg“; Teams-Hinweis und Push bei Läufen von Zusatzmodulen danach.

### 🎨 Oberfläche
- **Markierte Zeilen bleiben dunkelblau** ohne Fokus; Auswahlfelder zum Eintippen; Zertifikat in der Kopfzeile; Fenstergröße gemerkt.

### ✅ Qualität
- **816 automatische Tests** bestanden.

## v2.5.4 (Testversion, Weg zu 2.5.5 Stable)

### 💻 Modul Autopilot (neu, 0.5.1)
- **Eigener Reiter Autopilot,** mitgeliefert im Programm (`Modules\Autopilot\`, kommt mit dem App-Update, abschaltbar mit `"modulesOff": ["Autopilot"]` in `Config\settings.json`): Übersicht mit Ampel, Group Tag ändern mit Rückgängig, verschlüsseltes Hash-Archiv je Tenant, Aufnehmen mit Erkennung von Gruppe und Profil, Ausscheiden (erst Autopilot-Eintrag entfernen, dann Wipe) und Zurückziehen für Geräte, die bei der Familie bleiben (BitLocker-Übergabe zum Drucken, dann Retire), Protokolle und ZIP-Pakete für Eltern. Eigenes Änderungsprotokoll: `Modules\Autopilot\CHANGELOG.md`.
- **Doku:** Karte in der Funktionsübersicht und eigener Abschnitt in der Anleitung (Update › Zusatzmodule).

### 🎨 Oberfläche
- **Markierte Zeilen bleiben dunkelblau,** auch wenn die Tabelle den Fokus verliert (vorher hellgrau) – für alle Tabellen.
- **Auswahlfelder zum Eintippen:** Der dunkle Stil für Auswahlfelder erlaubt jetzt auch `IsEditable` (Text eingeben und aus der Liste wählen).

### 🔑 Rechte
- **Rechtekatalog ergänzt** für das Modul Autopilot (nicht vorausgewählt): `DeviceManagementServiceConfig.ReadWrite.All`, `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementScripts.Read.All`, `Group.Create` und `BitlockerKey.Read.All` – letzteres gilt als weitreichend (rot, eigene Bestätigung).

### 🧩 Zusatzmodule
- **Mitgelieferte Module:** Neben signierten privaten Modulen (`Addons\`) lädt die App jetzt Module aus `Modules\<Id>\` – sie sind Teil des Programms und werden mit ihm geprüft und aktualisiert. Ein signiertes privates Modul gleicher Kennung ersetzt das mitgelieferte, `AddonsDev\` ersetzt beide (Entwicklung).
- **Schnittstelle:** `Test-HUUserAway` (App gesperrt, Sperrbildschirm, getrennte Sitzung oder 5 Minuten ohne Eingabe) steht Zusatzmodulen zur Verfügung. Startet ein Modul einen Lauf über die Fernbedienung, kennzeichnet es ihn mit `Origin = 'addon'` und gibt den Freigabeort mit (`ApprovedBy`: PC oder Handy).

### 🗺️ Doku
- **Roadmap aktualisiert:** 2.5.3 Handprüfungen, 2.5.4 Autopilot, 2.5.5 Stable; 2.6.0 Austausch und Sicherung (Export/Import, Microsoft-Vorlagen, App-Sicherung); Mail und Teams danach in 2.6.x.

## v2.5.3 (Testversion, Weg zu 2.5.5 Stable)

### 🛡️ Sicherheitskatalog
- **Handprüfungen für den Rest der Security Baseline (M01–M05):** Punkte, die Graph nicht liefert, stehen jetzt als Checkliste im Katalog (Bereich *Handpruefung*): lokales AD – Admin-Konten nicht delegierbar, keine Betriebssysteme ohne Support, keine Konten ohne Kennwortpflicht, LAPS und Tier-Konzept – sowie das Ablaufdatum von Freigabelinks in SharePoint/OneDrive.
- **Bestätigen je Tenant:** Details → *Von Hand geprueft …* mit kurzer Notiz und Rolle. Die Bestätigung gilt **12 Monate**, danach steht die Zeile wieder orange auf „? Manuell“. Zählt nicht zur Ampel und nicht zu „geprüft“, löst keine Teams-Meldung aus.
- **So behebst du es:** für jede Handprüfung Schritte und PowerShell-Abfragen für den Domänencontroller, mit Links auf Microsoft Learn – inklusive Hinweisen zu Sonderfällen (adminCount bleibt stehen, Protected Users, Computerkonten, Vertrauensstellungen) und Kontrolle per `Get-SPOTenant`.

### 🔍 Tenant-Vergleich
- **Vergleich mit Muster genauer:** Bei Conditional Access zählen in den Ausnahmen nur noch die eingestellten Notfallkonten des Tenants (Sollwert V1) nicht als Abweichung – weitere ausgenommene Konten schon. Auch **zwischen den Tenants** zählen verschieden viele Notfallkonten nicht mehr als Abweichung. Fehlt bei einem Tenant der Sollwert V1, nennt der Status das („Sollwert V1 fehlt: …“).

### 📱 Fernbedienung
- **Kein Push mehr, wenn du am PC bist:** Startet ein Zusatzmodul einen Lauf über die Fernbedienung und du hast ihn am PC freigegeben, kommt am Ende keine Meldung aufs Handy. „Am PC“ heißt: App und Windows entsperrt, Sitzung verbunden (keine getrennte Remotedesktop-Sitzung) und eine Eingabe in den letzten **5 Minuten**; eine Freigabe am Handy zählt nie als „am PC“. Lässt sich das nicht prüfen, gilt „weg“.
- **Teams-Hinweis und Protokoll** nennen bei solchen Läufen „über Zusatzmodul“ statt „vom Handy“; die Vorschau wiederholt den Titel nicht mehr, sondern nennt die Tenants. Bist du beim Start eines echten Laufs am PC (siehe oben), entfällt der Teams-Hinweis (nur im Protokoll vermerkt). Bist du am Ende nicht mehr da, kommt er **nachträglich** („Lauf lief unbeaufsichtigt weiter“). Echte Läufe vom Handy melden sich immer.

### 🧩 Zusatzmodule
- **Datenordner je Modul:** `Get-HUAddonDataDir <Id>` liefert `%APPDATA%\HU-MultiTenant\AddonData\<Id>\` (Schnittstelle für Zusatzmodule, `Functions\Core-Addons.ps1`). Die kommende App-Sicherung nimmt `AddonData\` komplett mit. Ohne `APPDATA` gibt es einen Fehler statt eines Ordners unter TEMP.

## v2.5.2 (Testversion, Weg zu 2.6.0)

### 🧭 Muster anwenden (Assistent)
- **Neuer Knopf im Reiter Muster:** *Muster anwenden …* überträgt die angehakten Pakete in einen oder mehrere Tenants – in 6 Schritten: Tenant, Rechte, Zuordnen, Vorschau, Ausführen, Abschluss.
- **Rechte nur für die Dauer des Ablaufs:** Der Assistent zeigt, welche Schreibrechte die Pakete brauchen, erteilt nach Admin-Anmeldung **nur die fehlenden** und gibt am Ende **genau diese** wieder zurück – auch nach Fehler oder Abbruch. Eine Markierung wird vor dem Erteilen geschrieben; stürzt das Programm ab, fragt es beim nächsten Start nach.
- **Zuordnen an einer Stelle:** Gruppen-Plätze aller Richtlinien und die Länderwahl einmal für das ganze Paket.
- **Eine Vorschau für alles:** Neu / Angleichen / schon gleich / gesperrt, Haken je Eintrag (Angleichen nur bewusst), *Alle auswählen* / *Alle abwählen*, Bestätigung mit dem Tenant-Namen.
- **Ausführen in fester Reihenfolge** (Orte → Entra → Intune → Conditional Access), vor jedem Eintrag erneut geprüft; Abbrechen nach dem laufenden Eintrag; **Paket rückgängig** nimmt alles in umgekehrter Reihenfolge zurück.
- **Mehrere Tenants nacheinander:** in Schritt 1 mehrere anhaken – je Tenant eigene Rechte, Zuordnung, Vorschau und Bestätigung; am Abschluss *Weiter mit …*. Was beim ersten Tenant abgewählt wurde, bleibt bei den folgenden abgewählt. **Rechte gesammelt zurück:** am Ende für alle Tenants auf einmal, mit den Admin-Anmeldungen des Durchgangs (ohne neue Anmeldung, solange diese gelten).
- **Fix:** Richtlinien mit Authentifizierungsstärke (z. B. 101) waren in der Vorschau gesperrt – die Stärke wird jetzt ohne nicht unterstützte Abfrage-Parameter gelesen.
- **Sicherer:** Rechte, die beim Erteilen schon geplant waren, gelten bis zur Bestätigung als offen – auch nach Absturz oder Fehler mittendrin kommt die Erinnerung. Hat sich das Ziel seit der Vorschau geändert (z. B. aus Neu wurde Angleichen), wird der Eintrag nicht geschrieben.
- Pro Tenant läuft der Assistent nur einmal gleichzeitig; ein pulsierender Punkt zeigt, solange gelesen oder geschrieben wird.

### 🛡️ Sicherheitskatalog
- **A17 Benutzer-Consent per Sollwert:** *keine* (Standard), *gering* (verifizierte Herausgeber, schwach eingestufte Berechtigungen) oder *empfohlen* (zusätzlich von Microsoft verwaltet) gilt als ok – alles andere mit Admin-Freigabe (A41).

### 🖥️ Oberfläche
- **Ablauf von Secret/Zertifikat in der Kopfzeile** in Höhe des Titels (Extensions und Quick Script: der gewählte Tenant; alle anderen Reiter: Sammelanzeige aller Tenants bzw. die zuerst ablaufende Schule) – in den Reitern Extensions und Quick Script entfernt.
- **Abweichungen dezent eingefärbt:** In Detail- und Ergebnisfenstern sind Zeilen mit „abweichend“ leicht hinterlegt.
- **Fenstergrößen** (z. B. Einstellungen) werden ohne Oberflächengröße gemerkt – das Fenster wächst beim Öffnen nicht mehr und bleibt auf dem Bildschirm.
- **Tenant-Vergleich:** Muster-Haken aus = Muster-Spalte sofort weg; Conditional Access gilt als gleich wie im Muster, wenn nur Status, Notfallkonten oder eingesetzte Rollen/Gruppen aus dem Tenant abweichen.
- **Reiter Muster:** Die Breite der Bibliothek (Unterteilung Bibliothek | Paket) wird gemerkt.
- **Notizen der Pakete** lesbarer: ein Punkt je Zeile, Quellen als anklickbare Links darunter.

### 🔗 Links
- **Link-Prüfung fürs Repo** (`.github/scripts/Test-HULinks.ps1`): findet tote und dauerhaft umgezogene Adressen in Code, Doku und mitgelieferten Mustern mit Fundstelle. Microsoft 365 Admin Center auf die neue Adresse `admin.cloud.microsoft` umgestellt.

## v2.5.1 (Testversion, Weg zu 2.6.0)

### ⭐ Muster-Bibliothek (neuer Reiter „Muster“)
- **Mehrere Muster:** Statt eines einzigen Mustertenants gibt es jetzt eine **Bibliothek von Paketen** – Teilpakete wie „Conditional Access komplett“ oder „Compliance Windows“ und ganze Stände.
- **Zusammenstellen:** *+ Neues Paket …* – Einträge aus den Backup-Ständen wählen, auch **gemischt aus mehreren Tenants**; jeder Eintrag merkt sich seine Herkunft. Gleiche Art und Name kommt nur einmal ins Paket.
- **Ordnen:** feste **Kategorien** (Conditional Access, Compliance, Entra-Grundschutz, Endpunktsicherheit/Defender, Updates, Gerätekonfiguration, Gesamtstand) und freie **Schlagwörter**; Suche nach Text oder `#Schlagwort`.
- Von Microsoft verwaltete CA-Richtlinien sind in Paket und Editor grau als „nicht übertragbar“ gekennzeichnet.
- **Bearbeiten, Duplizieren, Löschen** (Rechtsklick oder Knöpfe); Löschen verschiebt in den **Papierkorb** der Bibliothek – Knopf *Papierkorb (n)* unter der Liste: zurückholen oder endgültig löschen; nach 90 Tagen automatisch endgültig gelöscht (abschaltbar).
- **Namenskatalog je Paket:** Gruppen, Orte, Filter, Bereichsmarkierungen und Authentifizierungsstärken werden beim Speichern mit Namen festgehalten – nie Benutzer.
- **Übernahme:** Das bisherige Muster wird beim ersten Start einmalig als Paket „Gesamtstand … (bisheriges Muster)“ übernommen und ist angehakt, wenn noch nichts gewählt war.

### 🔒 Mitgelieferte Muster (Microsoft-Empfehlung, BMB Security Baseline V2.1, Praxis-Set Schule)
- **Neun fertige Pakete** kommen mit dem Programm und mit jedem Update – oben in der Bibliothek unter „Mitgeliefert“, einzeln anhakbar:
  - **CA-Grundschutz:** 100 Admin-Portale nur für Admin-Rollen, 102/103 MFA für Administratoren und Admin-Portale, 104 MFA für Azure-Verwaltung, 200 MFA für alle Benutzer, 204 MFA für Gäste mit Anmeldung alle 10 Stunden, 210 Registrierung der Sicherheitsinfos schützen, 901 Legacy-Authentifizierung blockieren.
  - **CA Phishing-resistente MFA für Admins (101):** FIDO2-Schlüssel, Windows Hello oder Zertifikat für 14 Admin-Rollen – erst einschalten, wenn alle Admins so eine Methode haben.
  - **CA Geoblock für Admins (903, Baseline 1.13):** benannter Ort „Erlaubte Länder“ – beim Übertragen die Länder **per Haken wählen** (Österreich immer, Deutschland/Schweiz/Liechtenstein vorgewählt, weitere Nachbarländer wählbar).
  - **CA Gerätekonformität (904/905):** „konformes Gerät oder MFA“ bzw. „konformes Gerät erforderlich“ (Gäste ausgenommen) – eine der beiden Varianten wählen.
  - **CA Schule (Praxis-Set):** 15 Richtlinien aus dem Schulbetrieb (100–906: Admins, MFA für Administration, Lehrer, Schüler, Cloud-User und Gäste, MFA außerhalb Österreichs, Device-Code-Flow und Legacy blockieren, Geoblock als Blacklist oder Whitelist, konformes Windows-Gerät, App-Einschränkungen für Office) mit drei Länder-Orten.
  - **Entra-Grundschutz Benutzereinstellungen (Baseline 1.5, 1.7, 1.14):** keine App-Registrierung, keine Sicherheitsgruppen und Tenants durch Benutzer, Gäste eingeschränkt, MSOL-PowerShell blockiert, Zustimmung zu Apps nur mit geringer Auswirkung.
  - **Compliance Windows, Android (Arbeitsprofil) und iOS/iPadOS** nach den Zero-Trust-Beispielen von Microsoft.
- **Sprechende Nummern:** 1xx Admins, 2xx MFA, 9xx Blockieren/Geräte – Namen dürfen im Ziel frei angepasst werden.
- **„100 – Admin-Portale“ immer aktuell:** Ausgenommen werden beim Übertragen alle eingebauten Admin-Rollen, die das Ziel in dem Moment hat (ohne Benutzer-, Gast- und Geräte-Rollen) – die Liste ändert Microsoft laufend. Sind die Rollen nicht lesbar, wird gesperrt (sonst wären alle Admins ausgesperrt).
- **Allgemein gehalten:** keine Tenant-Kennungen, Konten oder IP-Bereiche – nur Rollen, Microsoft-Apps, Länder und Schlüsselwörter. Alles läuft mit Entra ID P1.
- **Sicher beim Übertragen:** Conditional Access kommt als neue Richtlinie im Modus „Nur Bericht“ an, die Notfallkonten des Ziels sind ausgenommen; Compliance ohne Zuweisung.
- **Schreibgeschützt** (🔒): zum Anpassen *Duplizieren* – die Kopie landet unter ihrer echten Kategorie und ist frei bearbeitbar.

### 👥 Conditional Access übertragen
- **Gruppen gleich zuweisen:** In der Vorschau wählst du je Gruppen-Platz eine Gruppe des Ziels (z. B. Lehrer, Schüler, Ausnahmen) – gleichnamige Gruppen sind vorgewählt, leer = nicht zuweisen. Ein Hinweis erscheint, wenn eine Gruppe nichts ändert (Benutzer „Alle“) oder zugleich zugewiesen und ausgenommen ist. Gilt für die Plätze der mitgelieferten Pakete und für Gruppen in eigenen Mustern.
- **Benannte Orte aus dem Paket:** Orte mitgelieferter Pakete werden über ihren Namen im Ziel zugeordnet – zuerst den Ort übertragen, dann die Richtlinie.
- „alle Gäste und externen Benutzer“ bleibt als Ausnahme erhalten und ist als Benutzer per Haken wählbar; eine reine Rollen-Ausnahme (z. B. das Konto der Entra-Synchronisierung bei „Alle Benutzer“) geht nicht mehr verloren; eingebaute Authentifizierungsstärken werden im Ziel geprüft und mit Namen gezeigt.
- **Autorisierungsrichtlinie übertragen:** Zustimmungsrechte des Ziels für eigene Ressourcen (z. B. Teams) bleiben erhalten.

### 🔍 Tenant-Vergleich mit Paketen
- **Haken „Muster“** vergleicht die im Reiter Muster **angehakten Pakete** (eines oder mehrere).
- **Teilpakete** prüfen nur ihre eigenen Einträge – alles andere zählt nicht als Abweichung (Zelle „nicht im Paket“). Ein **Gesamtstand** prüft wie bisher alles.
- **Übertragen aus dem Muster** schlägt Namen (Gruppen, Orte, Bereichsmarkierungen) im Tenant nach, aus dem der jeweilige Eintrag stammt; Bereichsmarkierungen kommen aus dem Namenskatalog.
- **Zuordnung prüfen** und **Doppelklick-Details** arbeiten mit den angehakten Paketen.
- *Backup & Verlauf* › **Als Muster festhalten …** legt den Stand als Paket „Gesamtstand“ in der Bibliothek ab (Name frei wählbar).
- **Nur Muster-Einträge:** neuer Haken neben „Nur Unterschiede“ – zeigt nur die Zeilen der angehakten Pakete; bei Teilpaketen automatisch an.
- **Doppelklick-Details:** Die Muster-Spalte steht immer ganz links, die Tenants folgen in der Reihenfolge der Vergleichstabelle; Werte, die erst beim Übertragen aus dem Ziel kommen (Rollen, Gruppen-Plätze), stehen als Text statt „(leer)“.
- **Übertragen in mehrere Tenants:** *Abbrechen* beendet jetzt das ganze Übertragen; mit *Überspringen* geht es mit dem nächsten Ziel weiter.
- Steht derselbe Eintrag in mehreren angehakten Paketen, zählt die Fassung aus dem ersten Paket (Hinweis im Protokoll) – er wird nicht als „doppelt“ gemeldet.

### 🖥️ Oberfläche
- Reiter Muster: wird beim Start wiederhergestellt (Startreiter „Zuletzt“), die Extension-Liste links ist dort ausgeblendet; Bibliothek links (Breite ziehbar), Paket rechts, Protokoll unten (Höhe ziehbar), pulsierender Punkt bei laufenden Aufträgen, Tooltips an allen Steuerelementen; der Paket-Editor ist größenveränderbar mit Anfasser und öffnet so breit wie seine Spalten.

- **Kopfzeile zeigt den Update-Kanal** statt „Standardbenutzer“: *Kanal Stabil* (grün), *Kanal Test* (orange), bei Entwicklungsstand rot – ändert sich sofort mit der Einstellung.
- **Ergebnis-Tabellen:** Spalten höchstens 600 breit (von Hand breiter ziehbar), wenige schmale Spalten öffnen ein schmales Fenster; Tooltips der Bibliothek kürzen lange Notizen.
- **Oberflächengröße für alle Fenster:** Die Größe aus *Strg + Mausrad* (bzw. Einstellungen) gilt jetzt auch für alle weiteren Fenster (Tabellen, Vorschau, Dialoge) – vorher nur für das Hauptfenster. Fenster wachsen mit und bleiben ganz auf dem Bildschirm.

### ✅ Qualität
- 785 automatische Tests.

## v2.5.0 (Stable, 24.10.2026)

Stable-Release der Testversionen 2.4.1 bis 2.4.5 – „Angleichen und Übertragen“. Alle Punkte im Detail stehen in den Abschnitten darunter.

### → Übertragen und Angleichen (Intune)
- **Übertragen:** einen Intune-Eintrag aus einem Tenant oder dem Muster in Tenants neu anlegen, in denen er fehlt – ohne Zuweisungen, mit Vorschau je Ziel, Sperren (Geheimnisse, Quell-Verweise, WLAN/VPN/Zertifikate) und Nachprüfung.
- **Angleichen:** bestehende Einträge gleichen Namens auf den Stand der Quelle bringen (Konfiguration, Compliance, Feature-Update). Felder, die nur das Ziel hat, werden geleert; Zuweisungen des Ziels bleiben unberührt; vorher wird das Ziel erneut gelesen und gesichert.

### → Entra-Einstellungen und Conditional Access übertragen (aus dem Muster)
- **Autorisierungsrichtlinie, Administratorzustimmung, benannte Orte, Verzeichniseinstellungen** aus dem festgehaltenen Muster in andere Tenants – Gruppen über den Namen, Notfallkonten und Schreibrechte schon in der Vorschau geprüft.
- **Conditional Access** kommt immer als **neue** Richtlinie im Modus „Nur Bericht“ an, ohne Konten und Gruppen (Benutzer „Alle“ und eingebaute Rollen per Haken), die Notfallkonten des Ziels immer ausgenommen. Bestehende Richtlinien werden nie geändert.

### ↩️ Rückgängig
- Übertragenes wird gelöscht, Angeglichenes auf den gesicherten Stand zurückgesetzt – jeweils nur, solange seitdem unverändert (und bei Conditional Access nicht eingeschaltet). Das Fenster prüft je Zeile live, ob das möglich ist.

### 🔑 Entra-Schreibrechte nur zeitweise
- *Berechtigungen* › **Entra-Schreibrechte an/aus** erteilt bzw. entzieht nur die 4 Rechte für Übertragen und Zurückschreiben, je Tenant; Erinnerung, wenn sie länger als 7 Tage an sind.

### ⚡ Quick Script
- `.ps1`-Dateien lassen sich ins Codefeld ziehen (Hinweis bei fremden Skripten, nichts wird ausgeführt); der Editor startet leer.

### 🖥️ Oberfläche
- Spalten in allen Tabellen nach Inhalt, Anfasser rechts unten in allen Fenstern, Vergleichs-Details zeigen immer alle Werte, die gewählte Art im Tenant-Vergleich bleibt gespeichert, nach Übertragen und Rückgängig lädt der Vergleich verzögert neu (Entra braucht einige Sekunden). Das Arten-Dropdown ist so breit wie sein längster Eintrag.

### 🧪 Nach Live-Test korrigiert
- **Benannte Orte mit genau einem Land** (z. B. nur AT) wurden beim Angleichen und Zurückschreiben abgelehnt – behoben.
- **Rückgängig nach dem Angleichen** sperrte manchmal grundlos („geändert“), weil Entra direkt nach dem Schreiben noch den alten Stand lieferte – der Fingerabdruck stammt jetzt aus der Nachprüfung, Zeitstempel zählen nicht mehr.
- **Administratorzustimmung:** Reviewer, die es nur im Ziel gibt, fallen nicht mehr still weg – Pflicht-Haken mit Namen.
- **Kennwortregeln (Password Rule Settings)** lassen sich per App nicht schreiben (Microsoft lehnt trotz Berechtigung ab) – die Vorschau sperrt sie und verweist aufs Portal.
- Abgelehnte Schreibversuche zeigen Microsofts Fehlertext und legen den gesendeten Inhalt unter `Backups\<Tenant>\_fehler` ab.
- Conditional Access: Listen in Gewähren/Bedingungen werden immer als Liste geschickt; Namen der Reviewer-Rollen werden in der Vorschau aufgelöst.

### ⚠️ Bekannte Grenzen
- **Kennwortregeln** (Password Rule Settings) sind per App nicht schreibbar – im Portal unter *Schutz › Authentifizierungsmethoden › Kennwortschutz* einstellen.
- **Administratorzustimmung** übertragen ist live nur bis zur Vorschau geprüft.
- **Verzeichniseinstellung neu anlegen** ist nur durch automatische Tests abgedeckt; neu angelegte Verzeichniseinstellungen lassen sich nicht automatisch rückgängig machen.
- **WLAN-, VPN- und Zertifikatsprofile** werden nicht übertragen (Geheimnisse).
- **Einstellungskatalog und Administrative Vorlage** werden noch nicht angeglichen, nur neu angelegt.
- Änderungen an Compliance-**Aktionen** erscheinen im Verlauf noch nicht als eigene Zeile.

## v2.4.5 (Testversion, Weg zu 2.5.0)

### → Conditional Access übertragen (aus dem Muster)
- **Neu:** Im Tenant-Vergleich lässt sich eine Conditional-Access-Richtlinie mit *Übertragen …* in andere Tenants bringen. Quelle ist **immer der festgehaltene Mustertenant** (Haken *Muster aus Backup*).
- **Immer neu, immer „Nur Bericht“:** Im Ziel wird nie eine bestehende Richtlinie geändert. Es entsteht eine **neue** Richtlinie im Modus *Nur Bericht* – sie erzwingt nichts. Fehlt sie im Ziel, bekommt sie den Originalnamen; gibt es sie dort schon, heißt die neue „Name (von Muster)“ und läuft zum Vergleich neben der bestehenden. Richtlinien für Benutzeraktionen werden **ausgeschaltet** angelegt (Nur Bericht ist dort nicht möglich). Nach der Prüfung im Anmeldeprotokoll selbst einschalten und die alte entfernen.
- **Ohne Zuweisung (wie bei Intune):** Konten, Gruppen und Gäste werden nicht übertragen – die Vorschau zeigt, wem die Richtlinie im Muster zugewiesen ist, im Ziel selbst zuweisen. Benutzer „Alle“ und eingebaute Rollen (in jedem Tenant gleich) sind per Haken wählbar (vorausgewählt); sonst Benutzer „Keine“.
- **Notfallkonten:** Die Notfallkonten des Ziels werden immer als Ausnahme eingesetzt. Sind im Ziel keine hinterlegt oder ist eines deaktiviert, wird nicht übertragen.
- **Bedingungen** (Apps, Orte, Plattformen, Gewähren, Sitzung) werden übertragen; benannte Orte und eigene Authentifizierungsstärken über den Namen – genau ein Treffer, sonst gesperrt. Fehlt ein Ort im Ziel, zuerst den Ort übertragen.
- **Gesperrt:** eigene Rollen, Workload-Identitäten (Dienstprinzipale und Dienstprinzipal-Filter), Filterregeln mit Kennungen, Nutzungsbedingungen, eigene Steuerelemente, Apps, die es im Ziel nicht gibt, sowie von Microsoft verwaltete Richtlinien.
- **Rückgängig** löscht die neue Richtlinie – nur solange sie unverändert und nicht eingeschaltet ist.

### 🖥️ Oberfläche
- **Spaltenbreiten überall nach Inhalt:** In jeder Tabelle des Programms ist jede Textspalte so breit wie ihr Inhalt bzw. ihr Kopf (plus Abstand) – nichts mehr abgeschnitten oder aufgebläht, auch in Vorschau und Rückgängig. Diese beiden Fenster öffnen so breit wie ihre Spalten.
- **Anfasser rechts unten:** Jedes Fenster, dessen Größe sich ändern lässt, zeigt rechts unten den Anfasser zum Ziehen.
- **Rückgängig ohne angehakte Tenants** nimmt die Tenants des geladenen Vergleichs (vorher passierte nichts).

## v2.4.4 (Testversion, Weg zu 2.5.0)

### → Entra-Einstellungen übertragen (aus dem Muster)
- **Neu:** Im Tenant-Vergleich lassen sich **Autorisierungsrichtlinie**, **Administratorzustimmung**, **benannte Orte** und **Verzeichniseinstellungen** mit *Übertragen …* in andere Tenants bringen. Quelle ist **immer der festgehaltene Mustertenant** (bewusster Soll-Stand) – Haken *Muster aus Backup* setzen. Der Tenant, aus dem das Muster stammt, wird nicht angeboten (dafür gibt es Zurückschreiben).
- **Geprüft wird im Ziel:** Notfallkonten (hinterlegt und aktiv) für Autorisierungsrichtlinie und Orte, eigene Zustimmungsrichtlinien, Entra ID P1 für Kennwortregeln. Je Ziel eine Vorschau; bestätigt wird immer mit dem eingetippten Tenant-Namen.
- **Zuordnung über Namen:** Gruppen (Reviewer der Administratorzustimmung, Gruppe für die Gruppenerstellung) werden im Ziel über den Namen gesucht – genau ein Treffer, sonst gesperrt. Einzelne Benutzer als Reviewer werden nie übertragen.
- **Benannte Orte:** Fehlt der Ort im Ziel, wird er neu angelegt; gibt es ihn mit gleichem Namen, wird er nur nach bewusster Bestätigung geändert – die Vorschau nennt die Richtlinien, die ihn verwenden. „Vertrauenswürdig“ nennt die betroffenen Richtlinien mit „Alle vertrauenswürdigen Orte“; ist Conditional Access im Ziel nicht lesbar, wird es nicht gesetzt.
- **Verzeichniseinstellungen:** Fehlt die Einstellung im Ziel, wird sie mit der kompletten Werteliste neu angelegt (`EnableMSStandardBlockedWords` nie).
- **Rückgängig:** Geänderte Einstellungen werden mit derselben Logik wie beim Zurückschreiben auf den gesicherten Stand gesetzt (nur solange seitdem unverändert); neu angelegte Orte werden gelöscht, solange unverändert und von keiner Richtlinie verwendet. Neu angelegte Verzeichniseinstellungen werden nicht automatisch gelöscht.
- **Schreibrecht schon in der Vorschau:** Fehlt im Ziel das nötige Schreibrecht, steht das bereits in der Vorschau (gelber Hinweis) statt erst beim Schreiben.

### 🔑 Entra-Schreibrechte nur zeitweise
- **Neu:** *Berechtigungen* › Tenant › **Entra-Schreibrechte an …** erteilt nur die 4 Rechte für Übertragen/Zurückschreiben (`Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.Authorization`, `Policy.ReadWrite.ConsentRequest`, `GroupSettings.ReadWrite.All`) nur für diesen Tenant; **Entra-Schreibrechte aus …** entzieht genau diese wieder (Admin-Anmeldung im Browser). Andere Schreibrechte (Intune, Benutzer, Apps) bleiben unberührt.
- Die Statuszeile zeigt, ob die Entra-Schreibrechte an sind und seit wann. Sind sie länger als 7 Tage an, erinnert das Programm beim Start (einmal am Tag).
- Das Fenster *Berechtigungen* öffnet passend zur Bildschirmgröße, die Spalten sind ohne Scrollen lesbar; der Hinweistext steht unter den Knöpfen.

### ⚡ Quick Script
- **Geändert:** Beim Programmstart ist der Editor leer – das zuletzt geöffnete Snippet wird nicht mehr automatisch geladen.

## v2.4.3 (Testversion, Weg zu 2.5.0)

### ⚡ Quick Script
- **Neu:** Eine `.ps1`-, `.psm1`- oder `.txt`-Datei lässt sich direkt ins Codefeld ziehen – der Inhalt steht dann im Editor als neues Snippet (mit Strg+S speichern). Ungespeicherte Änderungen werden vorher abgefragt; ausgeführt wird nichts. Zeichenkodierung wird erkannt (UTF-8 mit/ohne BOM, UTF-16, ältere Windows-Dateien), höchstens 1 MB.
- Im leeren Codefeld steht dezent „Code hier schreiben oder einfügen oder eine .ps1-Datei hierher ziehen“.
- **Hinweis statt Sperre:** Sieht die Datei nicht nach einem HU-Snippet aus (kein `# @param`, `$Token` oder `Invoke-GraphRequest`), steht in der Ausgabe ein gelber Hinweis „Fremdes Skript“; auffällige Befehle (Löschen, Neustart, Invoke-Expression, Downloads, eigene Anmeldung, Start-Process, Datenträger, Ausführungsrichtlinie, HKLM) werden aufgelistet.

### → Angleichen sicherer
- **Gesperrt:** Hat das Objekt im **Ziel** einen geheimen Wert (z. B. verschlüsselter OMA-URI-Wert), wird nicht angeglichen – Rückgängig könnte ihn nicht wiederherstellen.
- **Vollständiger:** Felder, die nur das Ziel hat, werden auch in Unterobjekten geleert; Listen werden als leere Liste geschickt; schreibgeschützte „…IsSet"-Felder nie.
- **Compliance:** Unterschiede nur in den Aktionen (z. B. Kulanzfrist) sind jetzt in der Vorschau sichtbar und werden nachgeprüft; der Regelname kommt aus der Quelle.
- **Fehlerfälle:** Lehnt Intune das Angleichen ab, bleibt keine Rückgängig-Datei zurück (es wurde nichts geändert). Wird nur halb angeglichen (Einstellungen ja, Aktionen nein), meldet das Programm das deutlich und Rückgängig bleibt möglich.

## v2.4.2 (Testversion, Weg zu 2.5.0)

### → Übertragen: Angleichen bestehender Objekte
- **Neu:** Weicht ein Eintrag gleichen Namens in anderen Tenants ab, bietet *Übertragen …* jetzt auch **Angleichen** an: das bestehende Objekt im Ziel bekommt per PATCH die Einstellungen der Quelle. Vorschau zeigt nur die Unterschiede (gleiche Felder werden gezählt), auch Felder, die **nur im Ziel** einen Wert haben – die werden beim Angleichen geleert (volles Objekt, nichts bleibt still stehen); die Nachprüfung prüft in beide Richtungen. Zuweisungen und Bereichsmarkierungen des Ziels werden nie angefasst.
- **Arten:** Konfiguration, Compliance (Aktionen werden ersetzt, Benachrichtigungen bewusst bestätigen), Feature-Update. Einstellungskatalog und Administrative Vorlage werden noch nicht angeglichen (Update-Weg erst im Test-Tenant zu klären).
- **Sicher:** unmittelbar vor dem Schreiben wird das Ziel erneut gelesen – wurde es seit der Vorschau geändert, wird abgebrochen; der Ziel-Stand wird vorher als Rückgängig-Datei gesichert.
- **Fix:** Mit angehaktem Muster standen Einträge fälschlich auf „(nur anzeigen)“ – der Muster-Stand gilt jetzt wie vorgesehen als Quelle fürs Übertragen.
- **Neu:** Das Arten-Dropdown im Tenant-Vergleich zeigt hinter jeder Art, was damit geht: *übertragen + angleichen*, *neu anlegen* oder *nur vergleichen*.
- **Rückgängig:** stellt bei Angeglichenem den gesicherten Stand wieder her (nur solange seitdem unverändert); das Rückgängig-Fenster sagt jetzt je Zeile, was passiert (*LOESCHEN im Ziel* bzw. *Stand zuruecksetzen*) und prüft beim Öffnen live, ob das gerade möglich ist – mit Grund, wenn nicht; solche Zeilen lassen sich nicht ausführen. Das Ergebnis kommt je Eintrag als Dialog, auch Ablehnungen, die vorher nur im Protokoll standen.

## v2.4.1 (Testversion, Weg zu 2.5.0)

### → Übertragen statt Kopieren
- **Neu:** Tenant-Vergleich › *Übertragen …* ersetzt *Fehlendes kopieren*. Einen Eintrag markieren, Quelle wählen (Tenant oder Muster), Ziel-Tenants wählen; je Ziel eine **Vorschau** mit allen Einstellungen, Sperren und Hinweisen. Bei mehreren Zielen den Tenant-Namen zur Bestätigung eintippen.
- **Gesperrt:** gleicher Name im Ziel schon vorhanden; Verweise auf Objekte des Quell-Tenants (z. B. Compliance-Skript); Geheimnisse (verschlüsselte Werte, Kennwörter, Pre-Shared-Keys); WLAN-, VPN-, kabelgebundene, SCEP-, PKCS- und Zertifikatsprofile; genau eine Aktion „nicht konform markieren“ nötig, weggelassene Benachrichtigungen bewusst bestätigen; Bereichsmarkierungen, die es im Ziel nicht genau einmal gibt.
- **Sicher angelegt:** neu und ohne Zuweisungen; unmittelbar davor erneut geprüft; Bereichsmarkierungen über den Namen; unvollständige Administrative Vorlagen werden sofort wieder gelöscht; danach jede Einstellung mit der Quelle verglichen.
- **Neu:** Erfolgsmeldung und Abschlussmeldung erinnern ans Zuweisen im Ziel (Zuweisungen werden nicht übertragen).
- **Fix:** Graph-Metadaten-Zeilen (`…@odata.context`) sperrten das Übertragen fälschlich als Quell-Verweis – sie werden nie mitgeschickt und jetzt ignoriert. Knopf heißt nun *Vergleich einlesen*.
- **Rückgängig:** Tenant-Vergleich › *Rückgängig …* löscht übertragene Einträge wieder, nur wenn sie seitdem unverändert und nicht zugewiesen sind. Weicht die Nachprüfung ab, bietet die Meldung das Rückgängigmachen gleich an. Die Dateien liegen unter `_vor-uebertragen` und laufen mit den Backups ab.

## v2.4.0 (Stable, 23.10.2026)

Stable-Release der Testversionen 2.3.2 bis 2.3.5 – „Sichern und Wiederherstellen“. Alle Punkte im Detail stehen in den Abschnitten darunter.

### 💾 Backup für (fast) alles
- **Gesichert werden Intune, Conditional Access und die Entra-Einstellungen der Security Baseline:** alle Intune-Arten (auch App-Schutz, Registrierung, Zuweisungsfilter, Updates, Rollen), Conditional Access sowie Autorisierungsrichtlinie, Authentifizierungsmethoden, benannte Orte, Verzeichniseinstellungen u. a. **Nicht enthalten:** Exchange und Teams (kommen mit 2.6.0) sowie Geheimnisse – Kennwörter, Pre-Shared-Keys und private Schlüssel liefert Graph nicht aus und sie stehen nie im Backup.
- **Backups mit Ablaufdatum** (Standard 365 Tage); der neueste vollständige Stand und die jüngste Sicherung vor dem Zurückschreiben bleiben immer.

### ↩️ Wiederherstellen und Zurückschreiben
- **Intune:** Einträge aus einem Stand neu anlegen (ohne Zuweisungen, Name mit Zusatz).
- **Entra-Einstellungen:** Autorisierungsrichtlinie, Administratorzustimmung, benannte Orte und Verzeichniseinstellungen einzeln zurückschreiben – mit Vorschau „jetzt → danach“, Sperren, Notfallkonten-Prüfung, Sicherung unmittelbar vor dem Schreiben und Nachprüfung.
- **Conditional Access:** kommt als **neue** Richtlinie im Modus „Nur Bericht“ zurück; die bestehende bleibt unverändert. Richtlinien für Benutzeraktionen kommen ausgeschaltet zurück, weil es für sie keinen Nur-Bericht-Modus gibt.

### ⭐ Mustertenant und Zuordnung
- **Einen Backup-Stand als Soll-Stand festhalten**; im Tenant-Vergleich als eigene Spalte „Muster“, mit Farben (grün gleich, orange abweichend, rot fehlt).
- **Zuordnung prüfen** (nur lesen): Gruppen, benannte Orte, Filter und Bereichsmarkierungen der Quelle je Tenant – ok, fehlt oder mehrfach; dazu die Notfallkonten.

### 🔍 Verlauf ohne Fehlalarme
- Rollenzuweisungen, Defender-Heartbeat, Listen-Reihenfolge und gleichnamige Einstellungen zählen nicht mehr fälschlich als Änderung; Liste und Detailansicht sagen dasselbe, ohne dass echte Änderungen versteckt werden (gegengeprüft, eigene Tests).

### ⚠️ Bekannte Grenzen
- Wiederhergestellte WLAN-, VPN- und Zertifikatsprofile brauchen ihre Geheimnisse (Schlüssel, Kennwörter) danach neu – sie stehen nicht im Backup.
- Änderungen an Compliance-**Aktionen** (z. B. Kulanzfrist bis „nicht konform“) erscheinen im Verlauf noch nicht als eigene Zeile.
- Die Verzeichniseinstellung `EnableMSStandardBlockedWords` wird beim Zurückschreiben ausgelassen (von Microsoft eingestellt).

## v2.3.5 (Testversion, 23.10.2026, Weg zu 2.4.0)

### ⭐ Mustertenant als Soll-Stand
- **Neu:** Backup & Verlauf › *Als Muster festhalten …*: Ein vollständiger Backup-Stand eines Tenants wird zum Soll-Stand. Er liegt unter `Backups\_Muster`, läuft nicht ab, und ein neues Muster schiebt das alte nach `_Muster\frueher`.
- **Im Tenant-Vergleich:** Haken *Muster* – das Muster läuft als eigene Spalte mit, mit denselben Regeln für „abweichend“. Der Doppelklick zeigt die Einstellungen, Namen werden im Quell-Tenant des Musters nachgeschlagen. Aus dem Muster und ins Muster wird nicht kopiert.

### 🔗 Namenszuordnung prüfen (nur lesen)
- **Neu:** Tenant-Vergleich › *Zuordnung prüfen*: Welche Gruppen, benannten Orte, Zuweisungsfilter und Bereichsmarkierungen die Quelle verwendet (Muster, sonst der neueste vollständige Stand des ersten angehakten Tenants) – und ob es sie in den anderen Tenants unter demselben Namen genau einmal gibt: *ok*, *fehlt*, *mehrfach* oder *nicht prüfbar*.
- **Benutzer und Notfallkonten:** Einzelne Benutzer sind nicht zuordenbar; Notfallkonten werden beim Übertragen durch die des Ziels ersetzt. Dazu je Tenant, ob Notfallkonten hinterlegt und aktiv sind.
- **Grundlage** für das Übertragen ab 2.4.1; es wird nichts geschrieben.

### 🎨 Tenant-Vergleich: Farben
- **Schalter „Farben“** (wie im Sicherheitskatalog, bleibt gespeichert): grün = vorhanden und gleich wie das Muster (ohne Muster: wie die Mehrheit), orange = Einstellungen abweichend, rot = fehlt, grau = nicht lesbar.
- **Muster und Apps:** Apps stehen im Backup nur mit Namen; im Muster gelten sie jetzt als vorhanden statt „nicht lesbar“. Im Status steht „Muster“ statt der internen Kennung.

## v2.3.4 (Testversion, 23.10.2026, Weg zu 2.4.0)

### 🛡️ Conditional Access zurückschreiben – nur als „Nur Bericht“
- **Neu:** Eine Richtlinie aus einem Backup-Stand kommt als **neue** Richtlinie im Modus „Nur Bericht“ zurück, mit Vorschau wie bei den Entra-Einstellungen. Die bestehende Richtlinie bleibt unverändert.
- **Vorher geprüft:** Benutzer, Gruppen, Rollen, benannte Orte, Apps, Nutzungsbedingungen und Authentifizierungsstärke müssen im Tenant noch existieren, sonst wird nichts angelegt.
- **Hinweise:** Warnung, wenn Notfallkonten nicht ausgenommen sind; Bestätigung bei „konformes Gerät“ (Microsoft: Zertifikat-Abfragen auf macOS, iOS, Android auch im Nur-Bericht-Modus); Richtlinien für Benutzeraktionen kommen ausgeschaltet, weil es dort keinen Nur-Bericht-Modus gibt.
- **Nachgeprüft:** nach dem Anlegen werden Zustand, Name, Steuerelemente und die Anzahl der Benutzer, Apps und Orte gelesen und verglichen.
- **Vorschau:** Fenstertitel „Conditional Access wiederherstellen (Nur Bericht)“; sind alle Notfallkonten ausgenommen, steht das als Hinweis da; das vom Backup angehängte Feld `assignments` wird nicht mehr als „nicht geschrieben“ gemeldet.
- **Nachprüfung wartet:** Eine neue Richtlinie ist bei Microsoft oft erst nach einigen Sekunden lesbar. Das Nachlesen versucht es bis etwa 30 Sekunden lang; klappt es dann noch nicht, kommt ein Hinweis mit der Kennung statt der Fehlermeldung „nicht zurückgeschrieben“ (angelegt ist sie ja).
- **Eindeutiger Name:** Gibt es „… (wiederhergestellt Datum)“ schon (z. B. zweimal am selben Tag), bekommt die neue Richtlinie eine Nummer („… Datum 2)“).

### 💾 Backups mit Ablaufdatum
- **Neu:** Einstellungen › Allgemein › Backup: „höchstens … Tage“ (Standard 365, 0 = nie). Ältere Stände und Sicherungen vor dem Zurückschreiben werden beim nächsten Backup gelöscht; der neueste vollständige Stand und die jüngste Sicherung vor dem Zurückschreiben bleiben immer.

### 🔍 Verlauf und Tenant-Vergleich: keine versteckten Änderungen
- **Gleichnamige Einstellungen** (z. B. Computer und Benutzer in Administrativen Vorlagen) überschreiben sich in der Detailansicht nicht mehr (`#2`); eine Änderung an nur einer davon bleibt sichtbar. Treten solche doppelten Namen auf, bleibt die Liste vorsichtig bei „geändert“/„abweichend“.
- **Protokoll:** Zählt ein Eintrag trotz anderem Fingerabdruck als gleich (nur Reihenfolge oder ignorierte Felder), steht das mit Typ und Name im Protokoll.

## v2.3.3 (Testversion, 23.10.2026, Weg zu 2.4.0)

### ↩️ Entra-Einstellungen zurückschreiben (Etappe 1)
- **Neu:** Autorisierungsrichtlinie, Administratorzustimmung (Anfragen), benannte Orte und Verzeichniseinstellungen lassen sich aus einem Backup-Stand in denselben Tenant zurückschreiben – einzeln, unter *Backup & Verlauf* › *Wiederherstellen …*.
- **Vorschau:** je Feld „jetzt“ und „danach“, Sperren, Warnungen und einzeln abzuhakende Punkte; nicht geschriebene Felder werden genannt.
- **Sicher geschrieben:** nur dokumentiert beschreibbare Felder; unmittelbar davor erneut lesen (Abbruch bei Änderung), Live-Stand als Datei sichern, danach nachprüfen.
- **Vorschau zeigt alles:** bei Listen die Anzahl vorher → nachher; gekürzte Werte lassen sich aufklappen, geschrieben wird erst, wenn alle angesehen sind. Eine Sperre stoppt den ganzen Vorgang.
- **Vorschau lesbarer:** IP-Bereiche benannter Orte stehen als Adresse da (`192.0.2.0/24 → 198.51.100.0/24`) statt als JSON, auch im Protokoll; gibt es nur eine Zeile, ist sie gleich markiert und der volle Wert aufgeklappt (außer bei gekürzten Werten, die bewusst angesehen werden müssen).
- **Schutzregeln:** nur in denselben Tenant (Backups speichern jetzt auch die Tenant-ID); Kennwortliste nie im Klartext im Protokoll; Notfallkonten müssen hinterlegt und aktiv sein (Autorisierung, Orte); `allowedToReadOtherUsers = false` und fremde Gast-Rollen gesperrt; gelöschte Orte und fehlende Verzeichniseinstellungen werden nicht neu angelegt; Kennwortliste und Sperrschwelle nur mit Entra ID P1.
- **Neue Rechte (kein Standard, rot markiert):** `Policy.ReadWrite.Authorization`, `Policy.ReadWrite.ConsentRequest`, `GroupSettings.ReadWrite.All`; für Orte `Policy.ReadWrite.ConditionalAccess`.

### 🔍 Tenant-Vergleich: nicht mehr nur Intune
- **Neu verglichen:** alle weiteren Arten aus dem Backup – App-Schutz und App-Konfiguration, Registrierung, Zuweisungsfilter, ältere Endpunktsicherheit, Qualitäts- und Treiber-Updates, Intune-Rollen, Bereichsmarkierungen u. a. – und die Entra-Einstellungen (Autorisierungsrichtlinie, Sicherheitsstandards, Authentifizierungsmethoden, Cross-Tenant-Zugriff, benannte Orte, Verzeichniseinstellungen, Token- und Zustimmungsrichtlinien, SharePoint/OneDrive u. a.).
- **Einstellungen abweichend:** auch für diese Arten; IDs von Gruppen, Apps und Orten zählen dabei nicht. Doppelklick zeigt die Unterschiede ohne erneuten Abruf.
- **Bewusst nicht verglichen:** Domains, Organisation und Rollenzuweisungen – je Tenant naturgemäß verschieden.
- **Kopieren:** weiterhin nur die Intune-Grundarten; die neuen Arten werden vorerst nur verglichen.

### 💾 Backup
- **Rollenzuweisungen:** Rollen ohne Namen werden über die Rollenvorlagen benannt; sonst steht „Unbekannte Rolle“ mit Kennung da.
- **Rollenzuweisungen im Verlauf:** Vom Mitglied werden nur Kennung, Art und Name gesichert und verglichen. Wechselnde Benutzerdaten (Lizenzen, Dienstpläne) gelten nicht mehr als „Einstellungen geändert“ – auch beim Vergleich mit älteren Ständen.
- **Eindeutige Dateinamen im Stand:** Zwei Einträge mit gleichem langem Namen und gleichem Kennungs-Anfang (z. B. zwei Zuweisungen derselben Rolle) überschrieben sich gegenseitig die Datei. Jetzt bekommt jeder Eintrag seine eigene Datei; betroffene ältere Stände werden beim Vergleich nicht nachgerechnet.
- **Keine Fehlalarme durch Statuswerte:** `lastHeartbeatDateTime` (z. B. Defender-Connector) zählt nicht mehr als Änderung. Weichen zwei Stände ab, rechnet der Verlauf den Fingerabdruck aus den gespeicherten Dateien mit den heutigen Regeln nach – so verschwinden solche Fehlalarme auch gegenüber älteren Ständen.
- **Administrative Vorlagen:** Graph liefert die Werte einer Einstellung in wechselnder Reihenfolge. Sie werden jetzt über ihre Beschriftung zugeordnet; eine andere Reihenfolge gilt nicht mehr als Änderung, die Detailansicht zeigt nur echte Unterschiede.
- **Liste und Detailansicht sagen dasselbe:** Findet der Doppelklick keinen Unterschied (z. B. nur andere Reihenfolge einer einfachen Liste), steht der Eintrag auch in der Liste nicht mehr als „Einstellungen geändert“. Lange Werte werden nach 200 Zeichen mit Prüfsumme gekürzt, damit eine Änderung weiter hinten sichtbar bleibt.

### 🔧 Verbesserungen
- **Knöpfe, die in den Tenant schreiben,** sind jetzt gedämpft orange (Wiederherstellen, Fehlendes kopieren, Soll speichern); *Tabelle / Export* einheitlich violettblau.
- **Was bekommt …?:** Suche, Filter und Art in einer Zeile, solange der Platz reicht.
- **Tenant-Vergleich:** „Einstellungen abweichend“ nur noch, wenn auch der Doppelklick einen Unterschied zeigt (nicht mehr bei bloß anderer Reihenfolge oder anderen Kennungen).
- **Analyse, Lauf-Anzeige:** Der grüne Punkt pulsiert bei jedem Auftrag, der in die Analyse-Ausgabe schreibt – auch beim Nachladen per Doppelklick.

## v2.3.2 (Testversion, 22.10.2026, Weg zu 2.4.0)

### 💾 Backup: weitere Intune-Arten
- **Neu gesichert:** App-Schutz- und App-Konfigurationsrichtlinien, Registrierung (Einschränkungen, Statusseite/ESP, Windows Hello), Zuweisungsfilter, ältere Endpunktsicherheits-Richtlinien (mit Einstellungen), Qualitäts- und Treiber-Updates, Gerätekategorien, eigene Intune-Rollen (mit Zuweisungen) und Bereichsmarkierungen – jeweils mit Zuweisungen, wo es sie gibt.
- **Außerdem:** Compliance-Skripte, Benachrichtigungsvorlagen, Nutzungsbedingungen, Unternehmensportal-Branding, Richtliniensätze, App-Kategorien, Defender-Connector.
- **Entra-Rest:** Geräte-Registrierung (Beitritt, lokale Admins), eigene Authentifizierungsstärken, Token- und Zustimmungsrichtlinien, eigene Entra-Rollen, alle Rollenzuweisungen (Rolle – Mitglied), Ablauf von M365-Gruppen (nur mit `Directory.Read.All`, sonst still übersprungen), Organisation, SharePoint/OneDrive- und Berichtseinstellungen.
- **Nicht im Tenant vorhanden** (z. B. ohne passende Lizenz): wird ohne Fehler übersprungen.
- **Neue Standard-Rechte:** `DeviceManagementRBAC.Read.All` (Intune-Rollen und Bereichsmarkierungen), `Policy.Read.DeviceConfiguration` (Geräte-Registrierung), `Policy.Read.PermissionGrant` (Zustimmungsrichtlinien).

### 💾 Backup: Entra-Einstellungen der Baseline
- **Neu gesichert:** Autorisierungsrichtlinie, Sicherheitsstandards, Authentifizierungsmethoden, Administratorzustimmung (Anfragen), Cross-Tenant-Zugriff (Standard und Partner), benannte Orte, Verzeichniseinstellungen (u. a. Kennwortschutz und Sperrschwelle) und Kennwortablauf je Domain.
- **Verlauf:** Änderungen an diesen Einstellungen erscheinen wie bei Intune als „Einstellungen geändert“, Doppelklick zeigt Wert vorher und nachher.
- **Vergleich mit älteren Ständen:** Einträge, die es damals noch nicht im Backup gab, heißen „erstmals gesichert“ statt „neu“ und zählen bei *Nur Änderungen* nicht mit.
- **Lesbarere Details:** Listen werden über ihren Namen bzw. ihre Kennung gezeigt (z. B. `values[LockoutThreshold]`, `authenticationMethodConfigurations[Fido2]`) statt nur über die Position.
- **Fehlendes Recht:** Die betroffene Art wird nicht gesichert, der Stand bleibt vollständig, das Protokoll nennt das Recht (neu als Standard-Recht: `Domain.Read.All`).
- **Wiederherstellen:** Entra-Einstellungen noch nicht – kommt in einem der nächsten Schritte.

### 🔧 Verbesserungen
- **Backup & Verlauf, Auswahl Art:** neben dem Textfilter eine Auswahl, um nur eine Art zu sehen (z. B. *Entra-Rollenzuweisung*), mit Anzahl je Art; wirkt zusammen mit Textfilter und *Nur Änderungen*.
- **Reiterleiste bleibt stehen:** Beim Wechsel zwischen Extensions, Quick Script und den übrigen Reitern springen die Reiter nicht mehr – Extension-Liste und Tenant-Leiste liegen jetzt unter der Reiterleiste.
- **Neustart nach Zusatzmodul:** Die neue Fassung startet sofort und zeigt „wird neu gestartet …“, bis die alte geschlossen ist (bisher bis zu 30 Sekunden ohne Anzeige).

## v2.3.1 (Stable, 22.10.2026)

### 🧩 Zusatzmodule
- **Neu:** Zusatzmodule aus privaten Repositories – mit eigenem Reiter.
- **Hinterlegen:** Rechtsklick auf *Update* › *Zusatzmodule …*: Repository und Nur-Lese-Token eintragen. Der Token wird verschlüsselt nur für den eigenen Windows-Benutzer gespeichert.
- **Aktuell halten:** Beim Start wird im Hintergrund die neueste signierte Fassung geholt; sie wirkt nach dem nächsten Neustart.
- **Sicherheit:** Geladen wird nur, was mit dem Zertifikat des Herausgebers signiert ist. Jede Datei wird bei jedem Start gegen die signierte Prüfsummen-Liste geprüft; fremde oder veränderte Dateien verhindern das Laden.
- **Mindestversion:** Ein Modul gibt an, welche Version von HU-MultiTenant es braucht.

### 📱 Handy: Seiten für Zusatzmodule
- **Eigener Reiter:** Ein Zusatzmodul kann eigene Seiten mitbringen; sie erscheinen als zusätzlicher Reiter mit kurzem Namen und Symbol (bei mehreren Modulen als Auswahl oben).
- **Nur lesen, am PC:** Was abgefragt werden darf, legt das Modul fest und wird am PC geprüft (Datei im Modulordner, fester Funktionsname, bekannte Abfragen). Der Code läuft nur am PC im Hintergrund – das Handy bekommt nur Text.
- **Personendaten mit PIN:** Listen mit Namen nur nach PIN (gilt wie bei Sicherheit einige Minuten). Kennwörter immer mit PIN, nur für dieses Handy, einmal ausgeliefert und danach gelöscht; am Handy nach einer Minute ausgeblendet.
- **Abschaltbar:** *Remote FB › Einstellungen › Zusatzmodule am Handy*.
- **Auswahlfelder:** Tenant- und andere Auswahlfelder am Handy sehen jetzt wie Eingabefelder aus (mit Pfeil).

### 🔧 Verbesserungen
- **Rechte erteilen:** Nach dem Erteilen gelten alle gewählten Rechte als erteilt – *Weitere Rechte erteilen* fragt nicht mehr dieselben Rechte im selben Tenant erneut an.
- **Vorauswahl:** Wird das Fenster mit bestimmten Rechten geöffnet (z. B. aus einem Zusatzmodul), sind nur genau diese angehakt.
- **Tabellen überall:** Zellen und Spaltenköpfe haben Abstand nach rechts; Spalten sind mindestens so breit wie ihr Inhalt (bisher feste Breiten bleiben als Mindestbreite).
- **Zusatzmodul in Entwicklung:** Reiter ohne Zusatz „(Dev)“ – das Laden aus AddonsDev steht weiterhin im Protokoll.

## v2.3.0 (Stable, 21.10.2026)

- **Sicherheitskatalog, Ausnahmen fuer mehrere Tenants:** im Ausnahme-Fenster Tenants per Haken waehlen (mit "alle"); je Tenant entsteht eine eigene Ausnahme mit gleicher Begruendung und Ablauf. Hinweis, wenn ein angehakter Tenant die Regel gar nicht pruefen kann.
- **Sicherheitskatalog, Regeln abschalten:** Sollwert "Katalog disabled" (fuer alle oder je Tenant), z. B. A29, A30, K06 ohne P2. Die Regel wird dann gar nicht gelesen, die Zelle zeigt "aus" (auch am Handy), sie zaehlt weder in der Ampel noch im Soll-Stand. Regeln mit Mindeststandard lassen sich nicht abschalten.
- **Sicherheitskatalog, Teams-Meldung ruhiger:** neue Sollwerte "Katalog statusOnly" (nur Wechsel ok/Abweichung melden, nicht jede Aenderung der Anzahl; vorbelegt E03, E04, E16, K01, K04, K05, C03, C06) und "Katalog silent" (Regel gar nicht melden, auch nicht als "nicht mehr pruefbar"). Beides fuer alle oder je Tenant, wirkt nur auf die Teams-Meldung "Sicherheits-Aenderung" und den Hinweis "schlechter" beim Soll-Speichern; Matrix, Ampel und Handy bleiben unveraendert. Regeln mit Mindeststandard werden immer gemeldet.
- **Sicherheitskatalog, Teams-Meldung offen ueber Filter:** werden Zahlenaenderungen wegen "statusOnly" nicht gemeldet oder Regeln per "silent" stummgeschaltet, steht das als eigene Zeile in der Meldung ("Gefiltert ...: 3 Zahlenaenderungen ... nicht gemeldet; stumm: A30").
- **Sicherheitskatalog, Ausnahmen-Liste:** Ausnahmen ohne Wirkung (Regel abgeschaltet, beim letzten Pruefen nicht pruefbar, Regel unbekannt) stehen als "wirkungslos" in Orange, abgelaufene grau.
- **Sicherheitskatalog, Sollwerte je Tenant:** Hinweis im Fenster, dass ein Tenant-Wert den Wert fuer alle Tenants vollstaendig ersetzt (auch Listen); Katalog-Zeilen farblich abgesetzt.
- **Sicherheitskatalog, "So behebst du es":** zu einer Regel eine Kurzanleitung - wo im Portal, welche Schritte, Link auf den Microsoft-Learn-Artikel, Portal oeffnen, Pfad kopieren. Aufruf: Rechtsklick auf die Regel, F1 auf der markierten Zeile oder Knopf im Detailfenster; am Handy aufklappbar unter der Regel. Inhalt in `Docs/Behebung.json`, jede Anleitung gegen Microsoft Learn geprueft (mit Datum); die Datei kommt nur mit dem Release (signiert wie das Programm, kein Nachladen), wird trotzdem streng geprueft (Learn-Links nur auf Doku-Bereiche, feste Admin-Portale, Steuerzeichen entfernt, Datum echt). Monatlicher GitHub-Lauf prueft Links, Menuenamen und Aenderungsdatum der Learn-Seiten und meldet Befunde als Issue. Anleitungen fuer alle 68 Regeln; fuer kuenftige Regeln ohne Anleitung gibt es die Learn-Suche zur Regel.
- **Sicherheitskatalog, Teams-Meldung:** "Katalog statusOnly" nimmt Regeln mit Mindeststandard nicht an - bei ihnen wird jede Aenderung der Anzahl gemeldet.
- **Oberflaeche, Farben:** Neu-laden-Knoepfe in Apps und Wartung blau, der Knopf "Updates" in Apps abgesetzt (petrol), solange er nicht gewaehlt ist.
- **Oberflaeche, Reiter verschiebbar:** die Hauptreiter (Quick Script, Extensions, Apps, Wartung, Analyse, Teams) lassen sich mit der Maus an eine andere Stelle ziehen; die Reihenfolge wird mit der Fensterposition gespeichert. Rechtsklick auf einen Reiter: Reihenfolge zuruecksetzen.
- **Oberflaeche, Analyse-Leisten umbrechen:** in allen vier Analyse-Ansichten umbrechen Filter, Haken und Knoepfe bei schmalem Fenster in eine zweite Zeile, statt abgeschnitten zu werden.
- **Sicherheitskatalog, Regelliste sofort:** beim Oeffnen von Analyse > Sicherheit steht die Regelliste schon vor dem ersten Pruefen da (Spalten folgen den angehakten Tenants).

## v2.2.9 (Testversion, 21.10.2026, Weg zu 2.3.0)

- **Sicherheitskatalog, Rest der Security Baseline:** A43 keine Selbstregistrierung per E-Mail (Mittel), A44 Cross-Tenant-Standard B2B Direct Connect blockiert, Vertrauen in fremde MFA/Geraete zur Kenntnis (Mittel), A45 Apps mit kritischen delegierten Rechten fuer alle Benutzer (Hoch, Liste speicherbar; kritisch sind u. a. Mail, Dateien, Verzeichnis schreiben sowie Postfachzugriff ueber EAS, IMAP, POP und EWS; braucht laut Microsoft Directory.Read.All - ohne dieses Recht "? Recht"), A46 SharePoint/OneDrive teilen nach aussen hoechstens mit bestehenden Gaesten (Mittel). Jetzt 68 Regeln.
- **Doku:** Anleitung und Roadmap erklaeren die Regelnummern (A, V, C, E, K).
- **Handy, Reiter Sicherheit, schneller:** ausgeblendete Grade und Bereiche werden beim Pruefen gar nicht gelesen (vorher alle 64 Regeln, 2 bis 3 Minuten). Die Kopfzeile nennt "n von 64 Regeln geprueft" und weist auf nicht geladene Grade/Bereiche hin.
- **Handy, Reiter Sicherheit:** Listen zu Regeln mit neuen Buchstaben (K01 bis K06) liessen sich nicht oeffnen ("Zu dieser Regel gibt es keine Liste") - die Pruefung der Regelnummer kannte nur A, C, E und V.

## v2.2.8 (Testversion, 21.10.2026, Weg zu 2.3.0)

- **Sicherheitskatalog, Pruefpaket Konten, Lizenzen und Anmeldungen (alle lesend, keine neuen Rechte):** K01 aktive Konten ohne erfolgreiche Anmeldung seit mehr als 180 Tagen (Mittel; Sollwerte Tage und Gruppen, z. B. nur Lehrkraefte), K02 deaktivierte Konten mit Lizenz (Niedrig), K03 Lizenzen ab 95 % belegt oder ueberbucht (Mittel, Liste speicherbar), K04 Haeufung falscher Kennwoerter je Konto in 24 Stunden (Hoch, ab 20), K05 erfolgreiche Anmeldungen aus nicht erlaubten Laendern in 24 Stunden (Mittel; Sollwerte Laendercodes, Standard AT, DE, und ausgenommene Konten, z. B. Admin mit VPN; Liste je Konto, Land und Ort zusammengefasst mit Anzahl, Apps, Adressen, erster und letzter Zeit). Jetzt 64 Regeln.
- **Sicherheitskatalog, Details:** "(unvollstaendig gelesen)" nur noch, wenn wirklich gelesen wurde (nicht bei Lizenz, Recht, Handpruefung); der Listen-Knopf erscheint nur, wenn mindestens ein Tenant pruefbar war, und meldet einen nicht pruefbaren Tenant statt eines Fehlers.
- **Sicherheitskatalog, Lizenz vor Recht:** fehlt die Lizenz, steht "? Lizenz" auch dann, wenn zusaetzlich das Recht fehlt (vorher "? Recht", z. B. K06 ohne P2).
- **Sicherheitskatalog, Matrix:** Grade wie Bereiche per Haken (vorher Auswahlliste ohne "Niedrig"); Schalter "Farben" faerbt die Zeichen (gruen ok, rot Abweichung, orange Ausnahme, grau nicht pruefbar), Einstellung bleibt gespeichert.
- **Sicherheitskatalog K06 gefaehrdete Benutzer (Hoch):** liest die gefaehrdeten Benutzer aus Entra ID Protection. Graph liefert die Daten nur mit Entra ID P2 (Microsoft Learn, im Betrieb mit P1 bestaetigt); ohne P2 steht "? Lizenz", ohne Abruf. Das Leserecht IdentityRiskyUser.Read.All ist deshalb nicht vorausgewaehlt und nur mit P2 noetig. Verweigert Graph trotzdem wegen der Lizenz, steht ebenfalls "? Lizenz" statt "? Recht".
- **Sicherheitskatalog E05:** Graph liefert die Compliance-Grundeinstellung der App nicht (im Betrieb mit allen Abfragevarianten bestaetigt) - jetzt "? Manuell" mit Weg im Intune Admin Center statt "? Technik"; E16 listet nur noch Alarme mit Schweregrad hoch und mittel, die neuesten zuerst.

## v2.2.7 (Testversion, 21.10.2026, Weg zu 2.3.0)

- **Sicherheitskatalog, Pruefpaket Intune (alle lesend, keine neuen Rechte):** E05 Geraete ohne Compliance-Richtlinie gelten als nicht konform (Hoch), E06 Windows-Mindestversion in der Compliance (Mittel), E07 Update-Ring zugewiesen und Qualitaetsupdates hoechstens 7 Tage zurueckgestellt (Hoch, Sollwert), E08 BitLocker-, E09 Antivirus-, E10 Firewall-Richtlinie (eine zugewiesene Sicherheits-Baseline zaehlt ersatzweise), E11 Windows LAPS (Hoch), E12 Geraete ohne Sync seit mehr als 30 Tagen (zur Kenntnis, Sollwert), E13 ASR-Regeln, E14 EDR-Onboarding, E15 Defender for Endpoint mit Intune verbunden (Mittel), E16 offene Defender-Alarme hoch oder mittel (Hoch). Jetzt 58 Regeln.
- **Handy, Reiter Sicherheit:** Tenants waehlen und mit "Pruefen" starten (beim Oeffnen wird nur ein vorhandenes Ergebnis gezeigt, keine Pruefung gestartet); Grad und Bereich per Haken ein- und ausblenden, die Ampel zaehlt dann nur die angezeigten Regeln. Auswahl bleibt am Handy gespeichert.

## v2.2.6 (Testversion, 21.10.2026, Weg zu 2.3.0)

- **Sicherheitskatalog, Pruefpaket Teams und Gruppen (alle lesend, keine neuen Rechte):** C03 Teams und M365-Gruppen ohne Besitzer (Mittel, Liste speicherbar), C04 nur ein Besitzer (Niedrig, zur Kenntnis), C05 oeffentliche Teams und Gruppen (Mittel, Liste speicherbar), C06 Gaeste in Teams und M365-Gruppen (Hoch, Liste je Gast und Gruppe; am Handy mit PIN), C07 wer Teams und Gruppen anlegen darf (Mittel), C08 Gaeste als Gruppenbesitzer (Niedrig). Jetzt 46 Regeln. Grenzen: Ablaufrichtlinie fuer Gruppen braeuchte Directory.Read.All und fehlt bewusst; Einstellungen aus dem Teams Admin Center liefert Graph nicht.
- **Sicherheitskatalog, Ampel:** folgt der Auswahl (Grad, Bereich, Suchtext) und heisst dann "Ampel (nur Auswahl: n Regeln)"; "Nur Abweichungen" aendert sie nicht.
- **Sicherheitskatalog, Filter:** Bereiche per Haken statt Auswahlliste (einzelne Bereiche ausblenden, Auswahl bleibt gespeichert); die Spalte Regel zeigt die Anzahl der angezeigten Regeln.
- **C06 bei vielen Teams:** Mitglieder werden gebuendelt gelesen (je 20 Gruppen ein Abruf), Obergrenze 5000 Teams/Gruppen; Obergrenzen und aehnliche Gruende stehen jetzt im Klartext statt "Abruf fehlgeschlagen".
- **Sicherheitskatalog, Sollwerte ...:** neuer Knopf unter Analyse > Sicherheit. Sollwerte fuer alle Tenants oder je Tenant eintragen, z. B. Notfallkonten (V1 accounts), Admin-Gruppen (A25), Schwellen; Spalten Wert, Alle Tenants, Standard, Bedeutung. Objekt-IDs und Zahlen werden vor dem Speichern geprueft, leer entfernt den eigenen Wert, andere Eintraege der Datei bleiben erhalten. Vorher nur per Bearbeiten von baseline.json.
- **Roadmap neu geordnet:** 2.3.0 weitere Pruefpakete, 2.4.0 Sichern und Wiederherstellen, 2.5.0 Angleichen und Uebertragen (baut auf der Sicherung auf), 2.6.0 Mail und Teams.
- **Sicherheitskatalog A23 (Gaeste-Anmeldehaeufigkeit):** zaehlt nur noch, wenn Gaeste sich spaetestens nach 24 Stunden bzw. jedes Mal neu anmelden (Sollwert `A23 maxHours`); Tage werden in Stunden umgerechnet; eine Richtlinie fuer alle Benutzer zaehlt auch fuer Gaeste (Review 037 B14).
- **V1-Liste:** die Namen der Ausnahmen werden gesammelt aufgeloest (je 15 IDs ein Abruf) statt hoechstens 40 einzeln; geloeschte Objekte werden als "geloescht oder nicht gefunden" angezeigt (B16).
- **Soll speichern:** ist der neue Stand schlechter als der bisherige Soll, nennt die Rueckfrage die Regeln; die Teams-Meldung "Sicherheits-Aenderung" schickt einmal einen Hinweis, auch wenn sonst nichts zu melden ist (Review 038 B7).

## v2.2.5 (Stable, 21.10.2026)

Abschluss der Roadmap-Stufe "Sicherheitsanalyse". Enthaelt alles aus den Testversionen 2.2.2 bis 2.2.4.

- **Sicherheitskatalog V1 (Notfallkonten):** ausgenommene Gruppen werden aufgeloest (auch verschachtelt). Mit hinterlegten Notfallkonten (Sollwert `V1 accounts`, Objekt-IDs) muss jedes in jeder aussperrfaehigen Richtlinie ausgenommen sein; ohne Sollwert muss mindestens ein Konto in allen ausgenommen sein. Platzhalter und Rollen zaehlen nicht; nicht lesbare Gruppe = nicht pruefbar (Review 037 B4).
- **A24 Geoblock:** zaehlt nur noch Richtlinien fuer alle Benutzer und alle Apps mit Laender-Standorten (Sperr- oder Erlaubnisliste); IP-Orte, Benutzeraktionen, Geraetecode-Flow, Client-Apps, Plattform und Risiko zaehlen nicht. Ausnahmen werden genannt (B5).
- **A25 Adminportale:** Ausnahmen nur fuer Admin-Rollen, hinterlegte Admin-Gruppen (Sollwert `A25 adminGroups`) und hoechstens 4 einzelne Konten bzw. die Notfallkonten; sonst "zu breite Ausnahme". Hinweis auf die gesperrte Microsoft-365-Selbstinstallationsseite (B6).
- **A27 veraltete Admin-Konten:** Rollen ueber Gruppen werden aufgeloest, Dienstprinzipale genannt; gezaehlt nur die letzte erfolgreiche Anmeldung (Fehlversuche nicht); Abruf seitenweise statt je Konto (Drosselung); Notfallkonten ausgenommen; Datumswerte kulturunabhaengig (B7, B8, B9, B19).
- **A30 Anmelderisiko:** OK bei Blockieren oder MFA mit Anmeldehaeufigkeit "jedes Mal" fuer Risiko mittel/hoch; P2 ueber die Plan-ID erkannt; ohne P2 Hinweis auf den P1-Ersatz (B11). **A29:** auch ID Governance zaehlt (B18).
- **A42:** auch Mail.Read, Files.Read.All und Sites.Read.All gelten als kritisch (alle Postfaecher bzw. Dateien lesbar).
- **A37 Admin-Rollen nur Cloud-Konten:** zaehlt jetzt auch Konten mit Rolle ueber eine rollenzuweisbare Gruppe; die Liste nennt die Gruppe.
- **A28:** Einstellung ueber die Vorlage (templateId) gefunden (B12). **A26:** Alter ab der letzten Einladung (B13). **Sollwerte:** ungueltige Zahlen werden gemeldet, der Standard bleibt (B15).
- **Handy-Fernbedienung:** pulsierender Punkt im Reiter Sicherheit, solange geprueft oder eine Liste geladen wird.

Bekannte Grenzen (nach Stable): A23 wertet jede Anmeldehaeufigkeit fuer Gaeste (kein Hoechstwert), V1 loest bis zu 40 Namen in der Liste auf und erkennt verwaiste Objekt-IDs in den Ausnahmen nicht, A42 erfasst keine delegierten Zustimmungen fuer alle Benutzer, die Teams-Meldung warnt nicht, wenn ein neuer Soll-Stand schlechter ist als der vorige. Die Ampel-Schwellen bleiben (Rot ab 10).

- **Handy-Fernbedienung, Reiter Sicherheit:** Sicherheitskatalog aller Tenants am Handy - Ampel, Matrix mit Status und Zahl, Regel antippen fuer Begruendung und Kurztext je Tenant, Filter und "nur Abweichungen". Der Reiter erscheint erst ab 600 Pixel Breite (Tablet, Foldable offen, Querformat). Der PC prueft im Hintergrund nur lesend und merkt sich das Ergebnis 15 Minuten; Neu pruefen per Knopf. Wie am PC je Tenant ein Knopf fuer die Liste (z. B. "Konten anzeigen"): Listen mit Personendaten nur nach PIN, danach 5 Minuten frei; falsche PINs zaehlen wie beim Starten (3 = Handy gesperrt). Nur Anzeige, kein Kopieren, nichts am Handy gespeichert; die Matrix selbst braucht keine PIN. Abschaltbar unter Remote FB > Einstellungen (Standard an).
- **Rechte-Beschreibungen** (Einrichtung, INSTALL): nennen jetzt auch die Verwendung im Sicherheitskatalog. `RoleManagement.Read.Directory` ist dort nicht mehr "optional" beschrieben - ohne das Recht sind A08, A27 und A37 nicht pruefbar.
- **Analyse, Protokoll unten:** die Hoehe laesst sich am Balken darueber ziehen (60 bis 800 Pixel) und wird gemerkt. Vorher war sie fest.
- **Sicherheitskatalog A42:** die App-Liste (nur App-Namen und Rechte, keine Personendaten) laesst sich als CSV oder Excel speichern und kopieren. Listen mit Personendaten bleiben nur zur Anzeige.
- **Sicherheitskatalog, neue Regeln (alle lesend, keine neuen Rechte):** A37 Admin-Rollen nur fuer reine Cloud-Konten (Hoch), A38 Verzeichnissynchronisierung laeuft regelmaessig (Hoch; Sollwert hoechstens 180 Minuten seit dem letzten Sync, je Tenant in baseline.json aenderbar), A39 Sync-Fehler bei Benutzern und Gruppen mit Liste (Mittel), A40 SMS und Sprachanruf als Anmeldemethode aus (Mittel; E-Mail-Code wird wegen Gaesten nicht gewertet), A41 Admin-Zustimmungs-Workflow an (Mittel), A42 Apps mit kritischen Anwendungsrechten auf Microsoft Graph (Hoch; die App dieses Programms wird angezeigt, aber nicht mitgezaehlt). Jetzt 40 Regeln.
- **Sicherheitskatalog A32:** bei AADSTS500011 steht jetzt der Hinweis, Secure Score einmal im Defender-Portal zu oeffnen. Danach lieferte Graph den Wert (im Betrieb beobachtet).
- **Sicherheitskatalog, neue Regeln im Bereich SharePoint** (gleicher Abruf wie A33, kein neues Recht): A34 Legacy-Authentifizierung ausgeschaltet (Mittel), A35 Externe Benutzer duerfen Freigaben nicht weitergeben (Niedrig), A36 Domaenen-Einschraenkung und Leerlauf-Abmeldung (nur zur Kenntnis). 
- **Teams-Meldung Sicherheits-Aenderung:** Aenderungen zeigen einen Pfeil statt der Leerstelle, z. B. "Anzahl 3 → 4" und "OK → Abweichung" (das bisherige ">" wurde von der Textbereinigung entfernt).
- **Teams-Meldung Sicherheits-Aenderung:** die Kennzahl heisst jetzt "Heute nicht pruefbar (im Soll pruefbar)" und zaehlt nur Regeln, die beim Speichern des Solls pruefbar waren und jetzt nicht mehr; dauerhaft nicht pruefbare Regeln (manuell, Lizenz) zaehlen nicht mehr mit.
- **Teams-Karten:** Pfade in den Hinweiszeilen (Secret-Ablauf, Sicherheits-Aenderung) nutzen › statt >, das die Textbereinigung entfernte ("Analyse Sicherheit Soll speichern" statt "Analyse › Sicherheit › Soll speichern").

## v2.2.4 (Testversion, 20.10.2026)

- **Sicherheitskatalog, Konten anzeigen:** waehrend die Liste geladen wird, zeigt der Knopf "Lade ..." (gesperrt), der Mauszeiger ist eine Sanduhr und der gruene Punkt im Hauptfenster blinkt. Vorher sah es aus, als haengt das Programm. Ein Fehler oder eine leere Antwort wird jetzt immer gemeldet.

- **Sicherheitskatalog, Conditional Access:** die Richtlinien kommen aus v1.0; zusaetzlich wird beta gelesen und eine dort vorhandene, in v1.0 fehlende Richtlinie ergaenzt (Hinweis "nur ueber beta sichtbar"). Grund: v1.0 liess in einem Tenant eine aktive Richtlinie (Geraetecode-Flow blockiert) aus, V11 meldete deshalb zu Unrecht eine Abweichung. Ursache nicht geklaert. Schlaegt beta fehl, gilt v1.0 allein.
- **Sicherheitskatalog, Soll-Stand:** Knopf "Soll speichern" (Analyse > Sicherheit) speichert den aktuellen Pruefstand (nur Status und Zahlen, lokal). Neue Teams-Meldung "Sicherheits-Aenderung": prueft taeglich nach Zeitplan und sendet nur, wenn sich gegen das Soll etwas aendert (Status oder Anzahl, schlechter zuerst). Nicht pruefbare Regeln gelten nicht als Aenderung und loesen allein nichts aus. Ohne gespeichertes Soll wird nichts gesendet (Hinweis, Code 3). Verglichen werden Status und Zaehler, keine Objekte; im Soll stehen nur Regel, Tenant, Status und Anzahl.
- **Sicherheitskatalog, "Pruefung verloren":** war eine Regel im Soll pruefbar und ist an 3 Laeufen in Folge nicht pruefbar (z. B. Recht entzogen), meldet die Teams-Meldung das einmal; sonst wuerde ein Verstoss lautlos verschwinden. Zaehler nur lokal (Regel, Tenant, Anzahl), Reset bei "Soll speichern".
- **Sicherheitskatalog, V1 (Notfallkonten):** geprueft werden nur aktive Richtlinien fuer alle Benutzer oder Admin-Rollen, die blockieren oder etwas verlangen (MFA, Geraet, Nutzungsbedingungen ...). Reine Sitzungs- und Berichtsrichtlinien brauchen keine Ausnahme (Microsoft Learn).
- **Sicherheitskatalog, Ampel:** letzte Zeile der Matrix, je Tenant in derselben Spalte: farbiger Punkt (Rot = ab 10 nicht erfuellte Regeln, Gelb = 1 bis 9, Gruen = keine, Grau = nichts geprueft) und "x von y" geprueften Regeln in Ordnung. Fuellt sich waehrend der Pruefung Tenant fuer Tenant.
- **Sicherheitskatalog, neue Regel A33 (Mittel, Bereich SharePoint):** prueft, ob die Freigabe an "Jeden" per Link ohne Anmeldung erlaubt ist. Braucht das lesende Recht `SharePointTenantSettings.Read.All` (neu, vorausgewaehlt). Ob Freigabelinks ein Ablaufdatum haben, liefert Graph nicht und wird daher nicht geprueft. Neuer Filter "SharePoint".
- **Sicherheitskatalog A29 (PIM-Lizenz):** ohne Entra ID P2 zeigt die Matrix jetzt "? Lizenz" statt "i Info".
- **Sicherheitskatalog A31 (Partner-Organisationen):** leere Spalten heissen jetzt "Standard" (Partner nutzt die Einstellung des Tenants); Spalte "MfaAkzeptiert".
- **Sicherheitskatalog A32 (Secure Score):** Fehler AADSTS500011 (Dienst im Tenant nicht bereitgestellt) zeigt jetzt Klartext, bleibt aber "? Technik" - die Ursache (Lizenz oder nicht) ist nicht belegt.
- **Quick Script Runner:** neue Beispiel-Favoriten "Alle Geraete synchronisieren" und "Alle MDM Defender Intelligence aktualisieren" (nur bei Neuinstallation).
- **Sicherheitskatalog A21 (MSOL-PowerShell blockiert):** das Feld ist nur mit dem weitreichenden Schreibrecht `Policy.ReadWrite.Authorization` lesbar. Das fordert das Programm nicht mehr an; A21 zeigt "? Manuell" mit Hinweis (im Entra Admin Center selbst pruefen).
- **Sicherheitskatalog A33:** ein unbekannter Wert (z. B. unknownFutureValue) gilt als "? Technik", nicht als OK.

## v2.2.3 (Testversion, 19.10.2026)

- **Doku (F1):** die Seiten kommen weiterhin von GitHub (Fassung der installierten Version), werden aber jetzt zusammen mit den anderen Seiten und den Bildern unter ihrem echten Namen in einen Temp-Ordner geladen. Die Links zwischen den Seiten (z. B. Roadmap) und die Screenshots funktionieren dadurch auch dort; vorher fuehrten sie ins Leere.

## v2.2.2 (Testversion, 19.10.2026)

- **Sicherheitskatalog, neue Regeln nach BMBWF Security Baseline V2.1 (jetzt 30 Regeln):** MSOL-PowerShell blockiert (A21), Benutzerrechte Apps/Sicherheitsgruppen/Tenants (A22), Gaeste-Sitzungsdauer (A23), Geoblock (A24), Notfallkonten in allen Richtlinien ausgenommen (V1), Adminportale fuer Benutzer gesperrt (A25), offene Gaesteinladungen (A26), veraltete Admin-Konten (A27), Kennwortschutz lokales AD (A28), PIM-Lizenz (A29), riskante Anmeldungen blockiert (A30), Partner-Organisationen (A31), Secure Score (A32, braucht SecurityEvents.Read.All).
- **Katalog-Oberflaeche:** Filter nach Bereich und Schweregrad, Zeilen nach Schweregrad dezent eingefaerbt, Detailknopf zeigt je nach Regel Konten, Richtlinien (mit Namen der Ausnahmen), Einladungen oder Partner. Ergebnisfenster passt sich der Spaltenbreite an.
- **Rechtenamen mit Bindestrich:** die Pruefung in den Snippet- und Extension-Pruefprogrammen lehnt `User-OnPremisesSyncBehavior.ReadWrite.All`, `Group-...` und `Contacts-...` nicht mehr ab.
- **Graph-Aufrufe:** neuer Schalter `-ThrowOnError` bei `Invoke-GraphRequest` und `Invoke-GraphRequestWithRetry` (auch im Quick Script Runner): bei HTTP-Fehlern (z. B. 403) wird eine Exception geworfen, `try/catch` greift. Ohne den Schalter bleibt alles wie bisher (Fehlerobjekt mit `IsError`).
- **POST ohne Body** (z. B. `.../restore`): schickt `{}` mit Content-Type `application/json`, kein 415 mehr.

- **Analyse > Sicherheit:** neue Ansicht mit Matrix (Regeln als Zeilen, Tenants als Spalten), Filter, Doppelklick-Details, Ausnahmen mit Begruendung und Ablaufdatum, Tabelle/Export. Nur lesend; jeder Lauf wird im Verlauf gespeichert.

### Sicherheitsanalyse (Grundgeruest, noch ohne Oberflaeche)
- **Neues Modul `Core\HU.SecCatalog.psm1`:** Regeln pruefen Tenant-Einstellungen, nur lesend. Ergebnis je Regel und Tenant:
  OK, Abweichung, Ausnahme, Nicht pruefbar (Grund: Recht, Lizenz, Technisch, Manuell) oder Fehler. Ein Abruffehler,
  fehlendes Recht oder fehlende Lizenz erscheint nie als OK.
- Erste Regeln: A01 Conditional-Access-Richtlinien aktiv, A04 Legacy-Anmeldung blockiert, A08 Anzahl Global Administratoren,
  A14 Gastrolle eingeschraenkt, A15 wer Gaeste einladen darf, A17 Benutzer-Consent, V5 MFA-Grundschutz, V11 Geraetecode-Flow.
- Ausnahmen je Regel und Tenant mit Pflichtbegruendung und Ablaufdatum (hoechstens 12 Monate, bei Kritisch 3); abgelaufen
  = wieder Abweichung. Sollwerte: Standard im Code, Ueberschreibung je Tenant; Regeln mit Mindeststandard lassen sich nicht abschalten.
- Verlauf: je Lauf nur Status und Zahlen (keine Namen oder IDs), 24 Monate. Ablage unter `%APPDATA%\HU-MultiTenant\katalog\`.
- Doku-Seiten: neue Seite Roadmap; `?`-Knopf (Rechtsklick) und Update-Menue oeffnen Anleitung, Funktionen oder Roadmap.
  `Show-HUManual` nimmt nur diese festen Seiten an, jede Seite hat eine eigene Temp-Datei.
- Tests: `HU.SecCatalog.Tests.ps1`, `HU.Docs.Tests.ps1`.

## v2.2.1

### AD-Schema "Eigene" (Bericht Inaktive Benutzer)
- **Neue Option "Eigene"** unter Einstellungen > Tenants > AD-Schema: Rolle und Klasse kommen aus frei waehlbaren
  Benutzer-Attributen (z. B. `employeeType`, `department` oder `onPremisesExtensionAttributes.extensionAttribute1`).
  Damit passt der Bericht auch fuer Tenants, die weder dem Schema VirtualSchool noch iPack folgen. Es werden nur einfache
  Attributnamen angenommen; fehlt ein Attribut, bleibt die Spalte leer.
- **Fehler behoben:** Extensions bekamen keine Einstellungen (`Get-Settings` war im Extension-Lauf leer). Dadurch galt im
  Bericht Inaktive Benutzer immer VirtualSchool, auch wenn bei einem Tenant iPack eingestellt war. PS5-Runspace und
  PS7-Runner laden jetzt die `settings.json` vor dem Start; `Get-Settings`, `Get-TenantByKey` und `Get-AllTenants`
  liefern in der Oberflaeche die Tenant-Einstellungen (ohne Secrets).

### KI-Skills
- **Skills `hu-snippet` und `hu-extension`** im Ordner `skills\`: Anleitung, geprueften Vorlagen und ein Pruefprogramm
  (`Test-HUSnippet.ps1`, `Test-HUExtension.ps1`), damit ein KI-Assistent Snippets und Extensions schreibt, die beim ersten
  Lauf funktionieren. Einbinden als Skill oder `SKILL.md` in den Chat geben; Einzelheiten in `skills\README.md`.
- Anleitung: eigener Abschnitt "KI-Skills"; Funktionen: eigene Kachel; Einstieg: Hinweis und Frage in den Haeufigen
  Fragen.
- `SNIPPET-DEVELOPMENT.md` und `EXTENSION-DEVELOPMENT.md` auf den Stand des Programmcodes gebracht (Fehlerobjekt der
  Graph-Aufrufe, Listen mit Seitenfehlern, was im Snippet- und Extension-Lauf fehlt); Vorlagen ersetzt durch die
  geprueften Dateien. `Extensions\Template.ps1` neu.
- Automatische Tests fuer Pruefprogramme und Vorlagen (`Skills.Tests.ps1`, `Extensions.InactiveUsers.Tests.ps1`).

## v2.2.0

### Tenant einrichten mit Zertifikat (neu)
- **Einrichten (Admin-Anmeldung):** ein Global Administrator meldet sich einmal im Browser an (Microsoft-App "Microsoft
  Graph Command Line Tools", Auth Code + PKCE). HU-MultiTenant legt die App-Registrierung "HU-MultiTenant" samt Service
  Principal an, erzeugt auf diesem PC ein nicht exportierbares Zertifikat (RSA 3072, 12 Monate), erteilt die gewaehlten
  Rechte (Administratorzustimmung), testet die Anmeldung und traegt den Tenant ein. Bei einem Fehler wird Angelegtes
  wieder entfernt. Beim ersten Start wird die Einrichtung angeboten; sonst Einstellungen > Tenants > Tenant einrichten.
- **Anmeldung per Zertifikat** (signiertes JWT, PS256) statt Client Secret - nichts zum Kopieren oder Abtippen.
  Bestehende Tenants werden beim Einrichten an der Tenant-ID erkannt (Schluessel und Einstellungen bleiben); danach die
  alte App-Registrierung mit Secret im Entra Admin Center loeschen.
- **Zertifikat erneuern:** 30 Tage vor Ablauf automatisch beim Start (ohne Admin, addKey/removeKey mit Nachweis), von
  Hand mit Einstellungen > Tenants > Zertifikat erneuern. "Zertifikat auf diesem PC loeschen" sperrt einen Tenant.
- **Fehlende Rechte erteilen:** Knopf im Fenster Berechtigungen - zeigt erteilt/fehlt, waehlt fehlende Standard-Rechte
  und die der gewaehlten Extension vor, weitere frei waehlbar (z. B. fuer eigene Skripte). Nur hinzufuegen, nie
  entfernen; auch fuer manuell angelegte Tenants.
- **Weitreichende Rechte** (Mail, Dateien, Benutzer/Gruppen/Apps/Rollen schreiben, Policy.ReadWrite ...) sind rot und
  werden eigens bestaetigt - nicht gesperrt. Liste und Standard-Rechte: `Config\graph-permissions.json`.
- **Not-Aus** loescht auch die Zertifikate von HU-MultiTenant auf diesem PC.
- Alte Secrets werden nach der Einrichtung (und beim Start fuer bereits umgestellte Tenants) auf diesem PC geloescht -
  nur wenn das Zertifikat vorhanden ist.
- Manuell mit App-ID und Secret geht weiterhin ("+ Manuell").
- Nach der Admin-Anmeldung zeigt das Fenster, ob fuer "Microsoft Graph Command Line Tools" schon weitere Zustimmungen
  bestehen - insbesondere eine Zustimmung fuer alle Benutzer (dafuer liest die Einrichtung zusaetzlich mit
  `Directory.Read.All`). Nur Anzeige mit Link ins Entra Admin Center; Empfehlung "Zuweisung erforderlich".
- Geraeteaktionen (`PrivilegedOperations.All`) und Wartungsskripte (`DeviceManagementScripts.ReadWrite.All`) gelten als
  weitreichend (rot, eigene Bestaetigung); Liste weitreichender Rechte ergaenzt.
- Einrichtung verlangt Global Administrator oder Privileged Role Administrator zusammen mit (Cloud) Application
  Administrator; Rechte erteilen weiterhin auch mit Privileged Role Administrator.
- Zertifikat erneuern: der alte Schluessel an der App und das alte Zertifikat werden erst entfernt, wenn das neue
  gespeichert ist; fehlt das eingetragene
  Zertifikat, wird ein passendes vorhandenes angeboten. Schluessel-ID wird gemerkt (removeKey ohne Nachschlagen).
- Anmeldung im Browser: Antworten mit fremdem state werden ignoriert statt die Anmeldung abzubrechen; ist der Port auf
  ::1 belegt, wird ein anderer genommen.

### Doku
- Neu: Seiten **Einstieg** (Situationen aus dem Alltag) und **Funktionen** (Top 10, alle Bereiche) im Stil von HUMig,
  Reiter oben auf allen drei Seiten.
- README gekuerzt: nur noch Kopf, Bilder, Schnellstart und Lizenz - Funktionen, Extensions und Sicherheit stehen auf den
  Seiten Einstieg, Funktionen und Anleitung.
- Anleitung, INSTALL und README: Einrichtung per Admin-Anmeldung, Zertifikat, Rechte erteilen; Rechtetabelle ergaenzt
  (`DeviceManagementServiceConfig.Read.All`, `SecurityAlert.Read.All`, `Directory.Read.All` optional).
- INSTALL: Erstinstallation per ZIP ist nur dieses eine Mal ungeprueft - Updates pruefen Pruefsummen und Signatur.

## v2.1.12

Uebernahme des Vorab-Stands 2.1.9 (PR #12) auf 2.1.11. Startbildschirm und Maskierung der Quick-Script-Protokolle waren
schon in 2.1.10 enthalten.

### Apps
- **Skript als Setup:** neben MSI und EXE jetzt auch PowerShell-Skripte (`.ps1`) und Batch-Dateien (`.cmd`, `.bat`) - z. B.
  Plugin-Installer ohne eigenes Setup. Name und Version kommen aus dem Ordnernamen (`HUScroll-0.5.2` ergibt HUScroll,
  0.5.2), der ganze Ordner wird mitgepackt. Hat das Skript die Schalter `-AllUsers`/`-Uninstall`, werden Installations- und
  Deinstallationsbefehl damit vorgeschlagen.
- **Setup-Ordner:** Setups werden beim Hinzufuegen nach `<Setup-Ordner>\<App>\<Version>` kopiert (letzte zwei Versionen je
  App bleiben) - Downloads kann danach aufgeraeumt werden. Vorschlag OneDrive\HU-MultiTenant-Setups, aenderbar unter
  Einstellungen > Allgemein; "Vorhandene uebernehmen" holt bestehende Bibliotheks-Apps nach.
- **Testinstallation mit Abhaengigkeiten:** Abhaengigkeiten aus der Bibliothek werden in der Sandbox vorher installiert
  (z. B. Greenshot vor einem Greenshot-Plugin); Abhaengigkeiten nur aus Intune werden als Hinweis genannt.
- **Testinstallation prueft die Erkennungsregel** nach der Installation und nach der Deinstallation (Datei/Ordner,
  Registry, MSI-Produktcode) - "NICHT gefunden" heisst, Intune wuerde die Installation als fehlgeschlagen melden.
- **Testinstallation wie Intune:** Befehle starten in der Sandbox aus einem 32-Bit-Prozess wie bei der Intune Management
  Extension (wahlweise "Start 64-Bit (eigener PC)"). Skript- und Batch-Setups werden mit `%SystemRoot%\Sysnative\...`
  vorgeschlagen und laufen damit auch unter Intune als 64-Bit (Program Files statt Program Files (x86)).
- **Ohne Eintrag in "Apps & Features"** (Skripte, Plugins): neue Programmdateien (EXE/DLL) werden erkannt und als
  Datei-Erkennung mit Version vorgeschlagen; der Deinstallationstest meldet "nicht pruefbar" statt eines falschen "OK".

### Behoben
- **Absturz bei "+ Setup ..."** (vorher "+ MSI / EXE ..."): das Programm beendete sich nach der Dateiauswahl.
- Fehler in einer Schaltflaeche beenden nicht mehr das ganze Programm - sie werden protokolliert, das Programm laeuft weiter.
- Sperre: Meldung "Verzoegerte Aktion: Die Variable $state ..." 30 s nach dem Entsperren entfernt.
- Sandbox-Fenster startete winzig: das kleine Fenster beim Herunterfahren der Sandbox wurde als Lage gemerkt; jetzt nur
  Groessen ab 800x500. Testinstallation: klarer Hinweis, wenn keine Erkennungsregel festgelegt ist.

## v2.1.11

### Handy-Fernbedienung (neu)
- Snippets, Erweiterungen und Teams-Meldungen vom Handy am PC starten: Web-App (PWA) im Heimnetz bzw. ueber das VPN des
  Routers, responsiv fuer Handy, Foldable und Tablet. Knopf "Remote FB" oben rechts: Ein/Aus, Kopplung per QR-Code,
  gekoppelte Handys, PIN, Freigaben, Einrichtung.
- Am Handy: Tenants (vorausgewaehlt wie am Snippet bzw. an der Meldung) und `@param`-Felder waehlen, Zusammenfassung
  pruefen, starten; Live-Ausgabe, Ergebnis je Tenant, Abbrechen. Teams-Meldungen auch einmalig an ein gespeichertes Ziel.
- Echter Lauf (Einstufung "aendert Daten" ohne angehakten Probelauf): roter Bestaetigungsschritt, Kuerzel abtippen und
  Fernbedienungs-PIN (nur Ziffern, mind. 4 Stellen; am PC nur als PBKDF2-Pruefwert). Falsche Eingabe verbraucht die
  Bestaetigung, 3 falsche PINs sperren das Handy (entsperren nur am PC). Bestaetigung 120 s gueltig. Hinweis an Teams
  (Ziele mit "Hinweis, wenn eine zeitgesteuerte Meldung nicht laufen kann") bei jedem echten Lauf vom Handy.
- Freigaben fuers Handy je Snippet/Erweiterung mit Pflicht-Einstufung "nur lesend" / "aendert Daten" und Fingerabdruck
  (SHA-256): geaenderter Code ist erst nach neuer Freigabe startbar. Parameter vom Handy nur fuer deklarierte
  `@param`-Felder, Auswahl/Laenge geprueft, geschuetzte Namen ($Token, $TenantKey, *Preference ...) gesperrt.
- Laeufe ohne Oberflaeche: je Tenant ein frischer Runspace, nie ein Dialog am PC (auch bei gesperrter App - abschaltbar),
  gemeinsame Laufsperre mit Quick Script, Erweiterungen und "Jetzt senden". Titelleiste und Protokoll zeigen
  "Remote FB". Client Secrets und Webhook-Adressen bleiben am PC; was ein Skript selbst ausgibt, erscheint am Handy.
  Vollstaendiges Protokoll in Logs\Remote (aufgeraeumt nach logging.retentionDays). Haengt ein Lauf nach dem Abbruch,
  bleibt die Laufsperre bis zum echten Ende.
- Probelauf erkennt das Handy nur an eindeutigen Schaltern (DryRun, WhatIf, Probelauf); alles andere gilt als echter Lauf.
- Freigaben: wurde der Code seit der Freigabe geaendert, fragt das Speichern mit Liste nach (Nein = bleibt gesperrt).
- Not-Aus beendet auch die Fernbedienung, entfernt die gekoppelten Handys und schaltet den Autostart aus.
- Einrichtung: gestartet wird als Administrator eine gepruefte Kopie (SHA-256) in einem je Lauf neu angelegten, nur fuer
  Administratoren beschreibbaren Ordner (%windir%\Temp, zufaelliger Name, Besitzer und Rechte geprueft), Zusatznetze nur als Ziffern/Punkt/Schraegstrich.
- Teams-Meldung vom Handy: Bestaetigung "Sendet jetzt eine Teams-Meldung an ..." und Knopf "Jetzt senden"; Reiter und
  Hinweistexte kontrastreicher. Herunterziehen bleibt auf der Seite (auch Art Snippets/Erweiterungen/Meldungen).
- Intune am Handy (Reiter "Intune"): Apps und Wartungsskripte je Tenant, Installationsstand bzw. Ergebnis (Anzahl und
  Liste je Geraet mit Filter), Zuweisungen aufheben und setzen (Gruppe suchen, Ausschluss, alle Geraete/Benutzer; Apps:
  Erforderlich/Verfuegbar/Deinstallieren; Wartung: Zeitplan) - Aendern immer mit Kuerzel + PIN, abschaltbar.
- Empfohlen nur fuer sichere Homeoffice-Umgebungen (eigener PC, eigenes Heimnetz bzw. eigenes VPN).
- Ausgabe am Handy: Filterfeld (zeigt nur passende Zeilen) und kleine Symbole - letzten Lauf mit derselben Auswahl wiederholen (wieder mit Bestaetigung), in die Zwischenablage kopieren, Anzeige leeren.
- Push-Meldungen ueber den Handy-Browser: Ende eines Laufs mit Ergebnis (der Inhalt kommt direkt vom PC, nur im
  Heimnetz/VPN; sonst "Lauf beendet").
- Einmalige Einrichtung per UAC (Zertifikat - dieselbe CA wie HUMig -, HTTPS-Bindung, Port-Freigabe fuer das Konto,
  Firewall-Regel fuer lokales Subnetz + eingetragene Netze); danach ohne Adminrechte. Port 8444 (HUMig 8443), eine
  Bindung von HUMig wird erkannt und nie veraendert. PC wach halten waehrend eines Laufs (einstellbar: solange an).
- Kopplung nur ueber den Knopf am PC (Code 6 Ziffern, 10 Minuten, einmal gueltig), hoechstens 5 Handys, ungenutzte
  Kopplungen verfallen nach 90 Tagen, "Alle entfernen" fuer ein verlorenes Handy.

### README
- Reiter Teams (v2.1.10) und Handy-Fernbedienung in der Funktionsuebersicht.

## v2.1.10

### Startbildschirm wieder da
- Logo, Name und Version erscheinen sofort beim Start, darunter was gerade geladen wird; schliesst sich, sobald das
  Hauptfenster da ist (war im Vorab-Stand 2.1.9 gebaut, aber nicht in main). Nie bei geplanten Aufgaben (Headless).

### Neu: Teams-Meldungen - eingebaut oder aus eigenem Skript
- Reiter Teams neu geordnet: links **Ziele** (Kanaele), rechts **Meldungen** in zwei Gruppen - *Eingebaute Meldungen*
  (Tages-Ampel, Secret-Countdown, Lizenzen knapp, Defender-Alarm) und *Meldungen aus Skripten*. Jede Meldung hat
  dieselben Einstellungen: Ziele ("Senden an"), Tenants, "Jetzt senden" und auf Wunsch einen Zeitplan (Aufgabenplanung).
- **Meldung aus Skript:** unter der eingebauten Meldung steht immer das Feld *oder Meldung aus Skript* mit allen gespeicherten Quick-Script-Snippets. Das Snippet
  laeuft je Tenant mit den Werten seiner `@param`-Felder (an der Meldung, wie oben im Quick Script); jedes `Send-HUNotify -Title ...` darin geht an die Ziele
  der Meldung - eine Kategorie braucht es nicht. Zwei Einstellungen an der Meldung: *Skript laeuft je Tenant* (Standard) oder
  *einmal* (`$Tenants` = angehakte Tenants, eigene Schleife); *Ausgabe als Karte senden* (Standard aus) - dann geht die Ausgabe
  (Objekte/Text, sonst die Write-Host-Zeilen) als eine Karte, wenn das Skript kein `Send-HUNotify` aufruft. Je Lauf ein eigener,
  frischer Runspace; Zaehler gelten auch nach `exit`/`break` im Skript.
  **Achtung beim Update (Skript-Meldungen aus den Testversionen):**
  - Sie senden keine Ausgabe-Karte mehr, bis an der Meldung der Haken *Ausgabe als Karte senden* gesetzt und sie neu
    gespeichert ist (Karten aus `Send-HUNotify` gehen weiter raus).
  - Sie laufen je Tenant. Skripte mit eigener Schleife ueber alle Schulen mit *Skript laeuft: einmal* neu speichern -
    sonst laufen sie N x N-mal (Graph-Drosselung 429).
- Tagesprotokolle (`Logs\HU-MultiTenant_*.log`) aelter als `logging.retentionDays` (Standard 30 Tage) werden beim Start
  geloescht - wie schon die Quick-Script-Protokolle.
- Skript-Meldungen merken sich beim Speichern einen Fingerabdruck (SHA-256) des Snippets; wurde es danach geaendert,
  laeuft die Meldung erst nach erneutem Speichern wieder ("! Skript geaendert" in der Liste). Steht ein
  Probelauf-Schalter (DryRun ...) im Standard auf aus, fragt "Speichern" und "Jetzt senden" vorher "ECHTER LAUF". Geplant ueber `Main.ps1 -Headless -Job <Id>` (nur gespeicherte
  Meldungen und Snippets, kein freier Code), Laufzeit hoechstens 25 Minuten (Aufgabenplanung bricht nach 30 ab; "von der Aufgabenplanung abgebrochen" im Reiter). Exit-Codes
  wie bei den eingebauten Meldungen; gesendet mit Skriptfehler bei einem Tenant = 2 ("gesendet, Skriptfehler bei ...").
- Im Quick-Script-Editor gehen die Karten eines Snippets, das zu einer Meldung gehoert, an deren Ziele; ein Snippet ohne
  Meldung sendet nur, wenn es Ziele selbst nennt (`-TargetIds`, alte Kategorie) und die Rueckfrage mit Ja beantwortet wird.
- Am Ziel steht nur noch ein Haken: Hinweis, wenn eine zeitgesteuerte Meldung nicht laufen kann. Die Begriffe "Art" und
  "Kategorie" sind aus der Oberflaeche verschwunden. Eigene Kategorien aus den Testversionen bleiben gespeichert und
  funktionieren fuer Erweiterungen weiter; Skripte ausserhalb von HU-MultiTenant senden mit `-TargetIds`.
- **Rueckfrage vor dem Senden:** Snippets (im Editor) und Erweiterungen, die senden koennen, fragen einmal vor dem Start
  (Ja = senden, Nein = ohne Teams ausfuehren, Abbrechen). "Jetzt senden" und geplante Meldungen fragen nicht - die
  gespeicherte Meldung ist die Freigabe. Erweiterungen im Probelauf senden nie. `Send-HUNotify`/`Send-HUTeamsCard`
  unterstuetzen `-WhatIf`. Gesperrt wird im Modul selbst: ohne Freigabe sendet ein Lauf nichts - auch nicht ueber Alias,
  Hilfsdatei oder eigenen Import (Skripte ausserhalb: `Grant-HUSendApproval`). Keine Frage, wenn sicher niemand die
  Meldung bekommt; bei Ok = 0 steht der Grund im Ergebnis statt eines leeren Textes.

### Teams: Push-Vorschau und Datenschutz
- Jede eingebaute Meldung liefert einen eigenen Vorschautext fuer die Handy-Benachrichtigung - ohne Geraetenamen:
  Tages-Ampel "4 gruen, 1 gelb, 0 rot (gelb: Schule A) - 1234 Geraete, 7 nicht konform", Secret-Countdown mit dem
  dringendsten Tenant, Lizenzen mit der knappsten SKU, Defender mit Anzahl und betroffenen Tenants.
- Neue Option an der Meldung **Geraetenamen ausblenden (Defender-Alarm)**: die Karte nennt dann nur die Anzahl je
  Zustand - fuer Kanaele mit breiterem Publikum.

### Teams: Robustheit (Review 029, offene Punkte und Lueckentests)
- Karten zu gross: statt die Meldung zu verwerfen, kuerzt HU-MultiTenant stufenweise (weniger/kuerzere Zeilen,
  Fakten, Ampel-Zeilen, zuletzt ohne Knoepfe) auf hoechstens ca. 21 KB und vermerkt "Gekuerzt". Grundgrenzen 20 Zeilen,
  15 Fakten, 25 Ampel-Zeilen, 5 Knoepfe.
- Webhook-Adresse mit Weiterleitung (z. B. Kurzlink): unter Windows PowerShell 5.1 jetzt sofort "Senden abgelehnt
  (Umleitung)" statt drei Versuchen mit unklarer Meldung; Zeitueberschreitungen werden nur noch einmal wiederholt.
- Sperren: ist die Datei laenger als 5 s gesperrt, wird der Vorgang abgebrochen und gemeldet statt ungesperrt
  zu schreiben (Auftraege, Ziele, Kategorien). Das Sendeprotokoll fasst nach 1,5 s einmal nach und schreibt
  sonst eine Warnung ins Log; je Meldung wird es nur einmal geschrieben. Ziele speichern liest und schreibt unter der Sperre.
- Schluessel wie `Keys` oder `Count` sind fuer eigene Kategorien gesperrt (sie haetten alle Meldungen lahmgelegt);
  Fakten mit Zahlen-Schluessel (`2024 = ...`) bleiben erhalten.
- Senden je Ziel hoechstens ca. 45 s inkl. Wiederholungen.
- Headless-Fehlerkarte kuerzt Pfade (`<Programmordner>`, `<Profil>`), damit kein Benutzername im Kanal steht.
- Auftrag: "Geraetenamen ausblenden" nur beim Defender-Alarm waehlbar; ein unklarer Wert in der Datei blendet aus.
- Ziel-Id wird im Reiter angezeigt (fuer `Send-HUNotify -TargetIds`).
- `teams-jobs.json` nicht lesbar: die letzte gueltige Sicherung (`.bak`) wird verwendet (Warnung im Log).
- `"Enabled": "false"` als Text (von Hand bearbeitet) gilt als aus.
- Kartentitel mit deutschem Wochentag unabhaengig von der Sprache des Kontos ("Fr 16.10.").
- Auftrags-Id wird beim Speichern und beim Anlegen der Aufgabe geprueft (nur 8 Hex-Zeichen), Kommandozeile mit
  Anfuehrungszeichen.
- Tages-Ampel: "Secret-Ablauf unbekannt (kein Ablaufdatum)" als Hinweis, wenn das Secret kein Enddatum liefert.
- **Exit-Codes** des Headless-Laufs (Aufgabenplanung "Letztes Ergebnis"): 0 OK/nichts zu melden, 1 Fehler,
  2 teilweise gesendet, 3 Konfiguration (Auftrag/Ziele/Tenants/settings.json). Der Reiter zeigt den Code als Text.
- Die Lueckentests aus Review 029 sind als `.github\tests\*.Review029.Tests.ps1` Teil der CI.

### Quick Script
- **Protokolldateien maskieren Secrets und Token** (z. B. ein neu angelegtes Client Secret, das ein Snippet ausgibt) - vorher standen sie im Klartext in `Logs\QuickScript\*.log` (aus PR #12 vorgezogen)

## v2.1.9 (Vorab-Release, nicht freigegeben - aufgegangen in v2.1.10)

### Neu: Reiter Teams - Meldungen in Teams-Kanaele
- **Ziele:** Teams-Workflows-Webhooks ("When a Teams webhook request is received") mit Name und Kategorien. Adressen
  liegen DPAPI-verschluesselt im Benutzerprofil (`%APPDATA%\HU-MultiTenant\notify-targets.json`), nie im Log; im
  Protokoll erscheint nur eine Kurzkennung. Alte Office-365-Connector-Adressen (webhook.office.com) werden abgewiesen
  (seit Mai 2026 abgeschaltet). Test-Knopf sendet eine Testkarte.
- **Zeitgesteuerte Meldungen:** Auftraege (`Config\teams-jobs.json`, lokal) mit Uhrzeit, Wochentagen und Tenants.
  Erste Art **Tages-Ampel**: je Tenant Geraete, nicht konform, ohne Sync, Ablauf des App-Secrets - eine Karte mit
  einer Zeile je Tenant (gruen/gelb/rot). Weitere Arten, die nur bei Befund senden: **Secret-Countdown**
  (App-Secrets unter der Warnschwelle), **Lizenzen knapp** (SKUs mit weniger als 5 freien Lizenzen) und
  **Defender-Alarm** (Geraete mit gemeldeter Bedrohung oder Fehlkonfiguration). "Jetzt senden" aus der Oberflaeche oder als Aufgabe in der Windows-
  Aufgabenplanung (`\HU-MultiTenant\Teams-<Id>`, eigenes Konto, ohne erhoehte Rechte, nur bei Anmeldung).
- **Ohne Oberflaeche:** `Main.ps1 -Headless -Job <Id>` fuehrt genau einen gespeicherten Auftrag aus (heute Exit 0/1/2/3, siehe v2.1.10);
  freie Skripte sind in diesem Modus nicht moeglich. Fehlschlaege werden als Karte (Kategorie "Zeitgesteuerte
  Laeufe") gemeldet.
- Auftraege senden an die dort angehakten Ziele (keines angehakt = alle aktiven Ziele); "An Kanal ..." sendet einmalig an ein bestimmtes Ziel, z. B. an die Direktion. Die Kategorien am Ziel gelten fuer Meldungen ohne Auftrag (Test, Fehler zeitgesteuerter Laeufe, kuenftige Alarme).
- Sendeprotokoll im Reiter (Zeit, Ziel, Kategorie, Titel, Ergebnis; ohne Adressen).
- Externe Code-Pruefung (Review 029) eingearbeitet: keine Ziele am Auftrag ist jetzt ein Fehler statt "an alle";
  ein Auftrag gilt nur als erfolgreich, wenn alle Ziele wirklich beliefert wurden (sonst Fehler, auch im
  Headless-Exit-Code); fruehe Headless-Abbrueche melden sich als Karte "Zeitgesteuerte Laeufe"; Schreibzugriffe
  auf Auftraege und Sendeprotokoll laufen unter einer Prozess-Sperre (GUI vs. Aufgabenplanung) mit eindeutigen
  Temp-Dateien, ein kaputtes Protokoll wird nach .bak gesichert statt ueberschrieben; Webhook-Pruefung deckt
  weitere private Bereiche ab und folgt keinen Weiterleitungen; Unterstriche in SKU-/Geraetenamen bleiben als
  Leerzeichen erhalten; abgeschnittene Ampel-Zeilen zeigen "und N weitere"; Retry beachtet Retry-After;
  Warnschwelle 0 faellt auf 30 Tage zurueck; auslaufende Lizenz-SKUs werden mitgeprueft; Headless legt keine
  leere settings.json mehr an. Nach der Gegenpruefung zusaetzlich: auch die Oberflaeche und die Ziel-Ablage
  schreiben unter der Prozess-Sperre; Tenant-Eintraege ohne Schluessel werden uebersprungen statt den Lauf
  abzubrechen; ein fehlgeschlagener Kartenbau wird als Fehler gemeldet statt zu werfen.
- Feinschliff nach den ersten Live-Tests: Auftragsliste zeigt die Art mit an; bei Standardnamen folgt der Name der
  gewaehlten Art; "Nichts zu melden" nennt den Grund (z. B. fruehester Secret-Ablauf, knappste SKU); die
  Benachrichtigungs-Vorschau am Handy zeigt - nach dem Workflow-Umbau (Anleitung > Teams) - Titel plus die ersten
  Ampel-Zeilen, getrennt mit Aufzaehlungspunkten (ab v2.1.10 eigener Vorschautext je Art).
- Neue Core-Module `HU.Notify.psm1` (Karten, Ziele, Senden) und `HU.TeamsJobs.psm1` (Auftraege, Kennzahlen,
  Aufgabenplanung) - ohne Oberflaeche, fuer Extensions und Snippets nutzbar: `Send-HUNotify -Category ... -Title ...`.
- Reiter Teams als Start-Reiter waehlbar; Tests fuer Karten, Adressen, Textbereinigung, Ziele (Windows) und Auftraege.

## v2.1.8 (2026-10-10)

### Update (Pull.ps1)
- Wiederherstellung nach einem abgebrochenen Update funktionierte unter Windows PowerShell 5.1 nicht, sobald mehr als eine
  Datei im Journal stand (`ConvertFrom-Json` gibt ein Array als ein einziges Objekt aus - die Schleife lief einmal mit allen
  Pfaden zusammen und stellte nichts zurueck, das Journal wurde trotzdem geloescht). Jetzt wird jede Datei einzeln
  zurueckgestellt; das Journal wird nur geloescht, wenn das gelungen ist.
- Abschluss in der richtigen Reihenfolge: zuerst das Journal loeschen, dann die Sicherungen (vorher umgekehrt - ein Abbruch
  mitten im Aufraeumen konnte beim naechsten Start einen Mischstand herstellen). Laesst sich das Journal nicht schreiben, wird
  abgebrochen, bevor etwas ersetzt wird.
- Wiederholungen beim Ersetzen sichern die bisherige Datei nicht mehr doppelt; scheitert eine Datei endgueltig, wird ihre
  Sicherung sofort zurueckgestellt. Absolute Pfade in der Dateiliste werden beim Aufraeumen ignoriert.
- Update-Bibliothek auf dem Stand von HUMig: Release-Liste ohne Zwischenspeicher (ein gerade signiertes Release erscheint
  sofort), Ausweichweg beim Laden von Pruefsumme/Signatur (bei HTTP 503 von github.com ueber die API).
- Automatischer Test des Update-Wegs jetzt mit abgebrochenem Update (zwei Dateien im Journal), eigenen Dateien und Pfad
  ausserhalb.
- **Wirkt verzoegert:** Ein Update laeuft immer mit dem bisher installierten Pull.ps1 - die Korrektur greift ab dem naechsten
  Update nach 2.1.8.

## v2.1.7 (in Arbeit)

Sicherheits- und Robustheits-Update nach einer gezielten Code-Pruefung.

### Behoben (wichtig)
- **Bibliothek bei kaputter Datei:** ist `apps.json` oder `remediations.json` nicht lesbar (z. B. OneDrive-Konflikt), erscheint eine Meldung und die Bibliothek wird **nicht** leer ueberschrieben; die Sicherung `.bak` wird nur noch von einer gueltigen Datei erneuert
- **Backup:** ist gar nichts lesbar (z. B. Secret abgelaufen), entsteht kein leerer Stand; teilweise gelesene Staende sind als "unvollstaendig" markiert und verdraengen beim Aufraeumen keine vollstaendigen; im Verlauf erscheinen nicht gelesene Eintraege als "unbekannt" statt "geloescht"/"neu", nicht lesbare Zuweisungen als "Zuweisungen nicht lesbar"
- **Gleichnamige Apps/Wartungsskripte in einem Tenant:** in der Liste als "DOPPELT in ..." markiert; Aenderungen und Loeschen werden in diesem Tenant gesperrt (sonst traefe es ein zufaelliges Objekt)
- **Gleichnamige Gruppen:** Zuweisen bricht mit Hinweis ab statt die erste zu nehmen; Zuweisung entfernen wird verweigert, wenn der Name auf mehrere Gruppen zeigt
- **Tenant-Vergleich:** nicht lesbare Arten/Tenants stehen als "?" bzw. "nicht lesbar" statt "fehlt" - so wird nichts doppelt kopiert; im Tenant doppelte Eintraege werden nicht kopiert
- **Keine Duplikate in Intune:** Anlegen wird bei Serverfehler 500/502/504 nicht mehr automatisch wiederholt; scheitert nur der Paket-Upload, merkt sich die Bibliothek die angelegte App und der naechste Versuch aktualisiert sie
- **Unvollstaendige Abfragen:** Graph-Abfragen mit sehr vielen Seiten oder haengendem Seitenlink brechen mit Fehler ab statt ein Teilergebnis zu liefern
- **App-Updates:** "in Intune geloescht" nur bei echtem 404 und nur fuer genau die gepruefte App-Id; Pruefen und Hochladen laufen nicht gleichzeitig
- **Administrative Vorlagen kopieren/wiederherstellen:** fehlen Einstellungen, wird das als Fehler gemeldet ("UNVOLLSTAENDIG - nicht zuweisen") statt als OK
- **Update nie halb fertig:** Pull.ps1 sichert jede bisherige Datei vor dem Ersetzen; ist eine Datei gesperrt, wird alles zurueckgestellt. Ein abgebrochenes Update wird beim naechsten Pull automatisch zurueckgesetzt, das Programm startet bis dahin nicht (Hinweis). Wirkt ab dem Update **nach** 2.1.7 (das Update laeuft immer mit dem bisher installierten Pull.ps1)
- **Veraltete Programmdateien:** Dateien, die es in der neuen Version nicht mehr gibt, werden beim Update entfernt (nur fruehere Programmdateien, nie `Config`, `Logs`, `Reports`, `Backups`, `Templates`, `Tools`); greift ab dem zweiten Update nach 2.1.7 (die Liste der installierten Dateien entsteht erst beim ersten)
- **Nur eine Instanz:** ein zweiter Start aus demselben Ordner wird abgelehnt (zwei Instanzen ueberschrieben sich Bibliothek und Einstellungen)

### Verbessert
- Apps: Testinstallation in der Sandbox endet mit einem Gesamtergebnis (OK / mit Hinweisen / fehlgeschlagen), farbig markiert
- Windows Sandbox (Apps und Wartung): Fenstergroesse und -position werden gemerkt und beim naechsten Test wiederhergestellt
- Wartungsskript aktualisieren laesst Bereichsmarkierungen (Scope-Tags) aus dem Portal unveraendert
- Compliance kopieren: nicht uebernommene Benachrichtigungs-Aktionen werden gemeldet
- Kategorie loeschen: bei mehreren gleichnamigen wird nichts geloescht
- Protokoll und Support-ZIP maskieren auch Entra-Client-Secrets im aktuellen Format; Support-ZIP: App-Bibliothek standardmaessig nicht mehr dabei
- Anleitung: Testinstallation in der Sandbox auch ohne Intune nutzbar - Setups vor der Installation am eigenen PC gefahrlos ausprobieren
- Release signieren / freigeben (Herausgeber): Ablauf steht im Protokoll und in der Ausgabe des gerade offenen Reiters - Zertifikat, neuestes Release, Releases ohne Pruefsumme, Ergebnis; am Ende zusaetzlich eine Meldung (auch wenn es nichts zu signieren gibt)
- Einstellungen: Warnung, wenn der Backup-Ordner in OneDrive oder im Programmordner liegt

### Intern
- CI testet den Update-Weg jetzt auch als Update ueber eine bestehende Installation (veraltete Datei entfernt, Config unberuehrt, keine Reste)
- Code-Pruefung: Parameter `-Error` in `Update-TenantStatusCache` heisst jetzt `-ErrorMessage` (ueberdeckte die automatische Variable), ungenutzte Variablen und doppelte Dashboard-Daten in zwei Extensions entfernt

## v2.1.6 (2026-10-09)

### Neu: Reiter Analyse
- **Was bekommt ...?** - alle Apps, Profile, Richtlinien, Wartungs- und Plattformskripte, Feature-Updates und Autopilot-Profile, die eine Gruppe, ein Geraet oder ein Benutzer in den angehakten Tenants bekommt: ueber verschachtelte Gruppen, Alle Geraete / Alle Benutzer und mit Ausschluessen. Benutzer auch ohne Domain (passt in jedem Tenant), inklusive seiner Intune-Geraete. Filter nach Text und Art, Alle Geraete/Benutzer ausblendbar, Tabelle und Export
- **Tenant-Vergleich** - Profile, Einstellungskatalog, Administrative Vorlagen, Compliance, Wartung, Plattform-Skripte, Feature-Updates, Autopilot, Conditional Access und Apps nebeneinander: fehlt, nur in einem, doppelt, Einstellungen abweichend. Doppelklick zeigt die abweichenden Einstellungen je Tenant - Gruppen, Benutzer, Rollen, Cloud-Apps und Orte mit Namen statt ID, Listen als "gleich: N + Zusaetzliches". Markierte fehlende Eintraege in andere Tenants kopieren (ohne Zuweisungen)
- **Backup & Verlauf** - Konfiguration sichern (alle oben genannten Arten mit Zuweisungen, Apps als Liste), automatisch einmal taeglich beim Start (Standard an). Zwei Staende vergleichen: neu, geloescht, Einstellungen / Zuweisungen / Beschreibung geaendert, umbenannt - mit "Geaendert von" aus dem Intune-Protokoll. Doppelklick zeigt vorher/nachher. Eintraege aus einem alten Stand neu anlegen (Name mit Zusatz, ohne Zuweisungen, Conditional Access deaktiviert). Ablage lokal, Ordner und Anzahl Staende in den Einstellungen

### Neu: Apps
- **Updates** (neben Bibliothek und In Intune) - prueft die Setup-Apps der Bibliothek gegen winget: Bibliothek, neueste Version und tatsaechlicher Stand in Intune je Tenant. winget-ID bei eindeutigem Namen automatisch, sonst per Suche. "Neue Version holen" laedt den Installer und uebernimmt ihn als neue Version der App (eigene Installationsschalter bleiben, alter Sandbox-Hinweis wird geleert) - danach wie gewohnt Testinstallation und Hochladen mit Pilotgruppe. Quelle waehlbar (Einstellungen > Allgemein, Standard winget). In Intune geloeschte Apps werden erkannt und die Verteilung in der Bibliothek zurueckgesetzt
- **Kategorien** fuer das Unternehmensportal - mit Komma getrennt oder "Auswahl ..." aus den angehakten Tenants, dort auch anlegen und loeschen (mit Rueckfrage); fehlende werden beim Hochladen je Tenant gemeldet. Auch unter In Intune (Eigenschaften), mit Anzeige abweichender Kategorien

### Neu: Wartung
- **Duplizieren** per Rechtsklick in der linken Liste - Bibliothek: lokale Kopie; In Intune: Kopie mit neuem Namen in denselben Tenants, ohne Zuweisungen

### Verbessert
- Ergebnis-Tabellen: lange Werte werden umgebrochen, Spalten lassen sich beliebig breit ziehen

### Hinweise
- Neue Berechtigungen je nach Nutzung (INSTALL.md): `Policy.Read.All` (Conditional Access in Vergleich/Backup), `Device.Read.All` (Was bekommt ein Geraet), `DeviceManagementConfiguration.ReadWrite.All` (Kopieren/Wiederherstellen), optional `RoleManagement.Read.Directory` und `Policy.ReadWrite.ConditionalAccess`
- Backup sichert die Intune-Konfiguration und Conditional Access - kein vollstaendiges Tenant-Backup (keine Benutzer, Gruppen, Postfaecher, Dateien, App-Pakete)
- Backups enthalten Skripte und Richtlinien im Klartext - Standardablage ist lokal (`%LOCALAPPDATA%`), nicht im Programmordner
- Apps > Updates braucht winget (App-Installer aus dem Microsoft Store)

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
