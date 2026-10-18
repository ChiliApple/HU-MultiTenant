<h1 align="center"><img src="Assets/logo64.png" width="44" alt="" align="absmiddle"/> HU-MultiTenant</h1>

<p align="center"><b>Microsoft 365 und Intune für mehrere Tenants – aus einer Oberfläche</b><br>
Ad-hoc-PowerShell im Tenant-Kontext mit Snippet-Bibliothek, fertige Reports als Extensions, App-Verteilung mit Update-Erkennung, Wartungsskripte, Tenant-Vergleich und Konfigurations-Backup, Meldungen in Teams.<br>
Gebaut für Schulen mit mehreren Standorten – passt für jede Umgebung mit mehreren M365-Tenants.</p>

<p align="center">
  <a href="https://github.com/ChiliApple/HU-MultiTenant/releases/latest"><img src="https://img.shields.io/github/v/release/ChiliApple/HU-MultiTenant?label=Version&color=b9a88a" alt="Version"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/Microsoft%20Graph-Zertifikat-2E7D32" alt="Microsoft Graph">
  <img src="https://img.shields.io/badge/Oberfl%C3%A4che-WPF-8839ef" alt="WPF">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-Nutzung%20frei-orange" alt="Lizenz"></a>
</p>

<p align="center">
  <a href="https://chiliapple.github.io/HU-MultiTenant/Docs/Einstieg.html"><b>Einstieg</b></a> ·
  <a href="https://chiliapple.github.io/HU-MultiTenant/Docs/Funktionen.html"><b>Funktionen</b></a> ·
  <a href="https://chiliapple.github.io/HU-MultiTenant/Docs/Anleitung.html"><b>Anleitung</b></a> ·
  <a href="INSTALL.md">Installation</a> ·
  <a href="SNIPPET-DEVELOPMENT.md">Snippets schreiben</a> ·
  <a href="EXTENSION-DEVELOPMENT.md">Extensions entwickeln</a> ·
  <a href="CHANGELOG.md">Änderungen</a> ·
  <a href="LICENSE">Lizenz</a>
</p>

<p align="center">
  <a href="Docs/screenshot.png"><img src="Docs/screenshot.png" width="200" alt="Quick Script"/></a>
  <a href="Docs/screenshot-extensions.png"><img src="Docs/screenshot-extensions.png" width="200" alt="Extensions"/></a>
  <a href="Docs/screenshot-apps.png"><img src="Docs/screenshot-apps.png" width="200" alt="Apps"/></a>
  <a href="Docs/screenshot-wartung.png"><img src="Docs/screenshot-wartung.png" width="200" alt="Wartung"/></a>
  <br><sub>Quick Script · Extensions · Apps · Wartung – zum Vergrößern anklicken</sub>
</p>

---

## Schnellstart

1. `Pull.ps1` in einen leeren Ordner legen und ausführen: `powershell -ExecutionPolicy Bypass -File Pull.ps1`
2. **Start-HUMultiTenant.cmd** → **Tenant einrichten** → als Global Admin im Browser anmelden → fertig (je Tenant wiederholen)
3. Alternativ eigene App-Registrierung mit Secret: [INSTALL.md](INSTALL.md) → **Einstellungen › Tenants › + Manuell**

Was das Programm kann und wie es geht:

- **[Einstieg](https://chiliapple.github.io/HU-MultiTenant/Docs/Einstieg.html)** – typische Situationen aus dem Alltag
- **[Funktionen](https://chiliapple.github.io/HU-MultiTenant/Docs/Funktionen.html)** – alles auf einer Seite
- **[Anleitung](https://chiliapple.github.io/HU-MultiTenant/Docs/Anleitung.html)** – Schritt für Schritt, im Programm mit **F1**

---

**Lizenz:** kostenlose Nutzung erlaubt, Veränderung und Weitergabe veränderter Fassungen nicht – Details in [LICENSE](LICENSE) (deutsch und englisch).
*License: free to use, modification and redistribution of modified versions not permitted – see [LICENSE](LICENSE) (German and English).*
