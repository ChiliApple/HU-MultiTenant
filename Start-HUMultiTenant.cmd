@echo off
rem HU-MultiTenant starten (ohne Administratorrechte).
rem Besser: HU-MultiTenant.exe - Einstellungen / Allgemein / Desktop-Verknuepfung (kein Konsolenfenster, eigenes Logo)
if not exist "%~dp0Main.ps1" (
  echo Main.ps1 nicht gefunden in %~dp0 - Pull.ps1 ausfuehren.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Main.ps1"
