@echo off
rem HU-MultiTenant starten (ohne Administratorrechte).
rem Besser: HU-MultiTenant.exe - Einstellungen / Allgemein / Desktop-Verknuepfung (kein Konsolenfenster, eigenes Logo)
rem PowerShell 7, wenn installiert - sonst Windows PowerShell 5.1. Config\powershell-host.txt: auto (Standard) | 5 | 7
if not exist "%~dp0Main.ps1" (
  echo Main.ps1 nicht gefunden in %~dp0 - Pull.ps1 ausfuehren.
  pause
  exit /b 1
)
set "HUMODE=auto"
if exist "%~dp0Config\powershell-host.txt" set /p HUMODE=<"%~dp0Config\powershell-host.txt"
set "HUPWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not exist "%HUPWSH%" set "HUPWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if /i not "%HUMODE%"=="5" if exist "%HUPWSH%" (
  start "" "%HUPWSH%" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Main.ps1"
  exit /b 0
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Main.ps1"
