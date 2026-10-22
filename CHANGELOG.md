# HU-MultiTenant Changelog

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
- Groks Lueckentests aus Review 029 sind als `.github\tests\*.Review029.Tests.ps1` Teil der CI.

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
