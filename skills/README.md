# Skills für Assistenzprogramme (KI)

Wer Snippets oder Extensions für HU-MultiTenant nicht selbst von Hand schreiben will, kann ein Assistenzprogramm (KI-Chat, Programmier-Assistent) damit beauftragen. Damit der Code beim ersten Versuch läuft, liegen hier zwei fertige Anleitungen samt Prüfprogramm:

| Ordner | Wofür | Prüfregeln |
|---|---|---|
| [hu-snippet](hu-snippet/SKILL.md) | Quick-Script-Snippets (`Snippets/*.ps1`) | S01–S16 |
| [hu-extension](hu-extension/SKILL.md) | Extensions (`Extensions/*.ps1`) | E01–E16 |

Jeder Ordner enthält:

- `SKILL.md` – die Anleitung für das Assistenzprogramm (Laufzeit, Graph-Regeln, typische Fehler, Checkliste)
- `templates/` – geprüfte Vorlagen zum Anpassen
- `tools/` – statisches Prüfprogramm (`Test-HUSnippet.ps1`, `Test-HUExtension.ps1`)

## So nutzt du es

**Variante A – als Skill hinzufügen:** Ordner `skills/hu-snippet` bzw. `skills/hu-extension` im Assistenzprogramm als Skill einbinden (Ordner in dessen Skill-Verzeichnis kopieren). Danach reicht eine Bitte wie „Schreibe ein Snippet, das …“.

**Variante B – ohne Skill-Funktion:** `SKILL.md` (und bei Bedarf eine Vorlage) in den Chat kopieren oder hochladen und dazusagen: „Halte dich genau an diese Anleitung.“

## Ergebnis prüfen

Das Prüfprogramm führt nichts aus und verbindet sich mit nichts; es liest nur den Code.

```powershell
# Zielmaschine: beliebiger PC mit Windows PowerShell 5.1 oder PowerShell 7
powershell -NoProfile -File skills\hu-snippet\tools\Test-HUSnippet.ps1 -Path .\mein-snippet.ps1
powershell -NoProfile -File skills\hu-extension\tools\Test-HUExtension.ps1 -Path .\Device-MeinReport.ps1
```

- `FEHLER` – läuft so nicht oder ist unsicher → beheben
- `WARNUNG` – prüfen, ob es Absicht ist

Der Assistent sollte das Programm selbst ausführen und alle Fehler beheben, bevor er den Code übergibt. Steht kein PowerShell zur Verfügung, die Checkliste am Ende der `SKILL.md` durchgehen.

## Wichtig vor dem ersten Einsatz

- Neue Snippets und Extensions zuerst in **einem** Test-Tenant und mit **Probelauf** (`DryRun`/`-WhatIf`) ausprobieren.
- Der Prüfer erkennt typische Fehler, ersetzt aber keinen Test. Der Code gehört immer geprüft, bevor er in Schulen läuft.
- Die Skills beschreiben den Stand der Programmversion, mit der sie ausgeliefert werden.

Hintergrund: [SNIPPET-DEVELOPMENT.md](../SNIPPET-DEVELOPMENT.md) · [EXTENSION-DEVELOPMENT.md](../EXTENSION-DEVELOPMENT.md)
