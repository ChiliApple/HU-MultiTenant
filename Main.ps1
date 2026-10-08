#Requires -Version 5.1
<#
.SYNOPSIS
    HU-MultiTenant - Microsoft 365 / Intune fuer mehrere Tenants (WPF, Graph API, Client Credentials).
.DESCRIPTION
    Startpunkt. Laedt Core-Module (Core\*.psm1), Oberflaeche (XAML\*.xaml) und Funktionen (Functions\*.ps1).
      Core\        Auth, Graph, Tenant, Logging, Extensions, Intune, Excel (auch von Extensions/Snippets genutzt)
      Functions\   Oberflaeche: Quick Script, Snippets, Extensions, Apps, Wartung, Tenants/Secrets, Einstellungen, Update
      XAML\        Fenster und gemeinsames Theme
    Start: HU-MultiTenant.exe (Einstellungen > Verknuepfung) oder Start-HUMultiTenant.cmd.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows 10/11, Windows PowerShell 5.1).
#>
param([switch]$ShowConsole, [string]$SmokeTest = '')

# Konsolenfenster ausblenden (nur die WPF-Oberflaeche ist sichtbar)
if (-not $ShowConsole) {
    try {
        Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("User32.dll")] public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
' -ErrorAction Stop
        $consolePtr = [Console.Window]::GetConsoleWindow()
        if ($consolePtr -ne [IntPtr]::Zero) { [void][Console.Window]::ShowWindow($consolePtr, 0) }
    } catch { }
}

# Version 1: nicht gesetzte Variablen sind ein Fehler (Tippfehler); fehlende Eigenschaften (JSON aelterer Versionen,
# leere Auswahl) liefern `$null - wie in HUMig/HU-AdminTool
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
$script:AppRoot = $PSScriptRoot

# Zustandsvariablen (StrictMode: vor dem ersten Lesen setzen)
$script:Window = $null; $script:Controls = @{}; $script:AppIcon = $null
$script:CurrentToken = $null; $script:UiScale = 1.0
$script:StartupDone = $false; $script:SkipCloseChecks = $false
$script:TenantSelectBusy = $false; $script:PersistBusy = $false
$script:SecretCheckDone = $null; $script:SettingsRefresh = $null; $script:UpdateQuiet = $false
$script:SignCtx = $null; $script:PubCtx = $null; $script:UpdMenuSign = @(); $script:ManualLocal = ''
$script:BgLogFile = $null; $script:BgLogLastLine = 0; $script:BgTenantKey = $null; $script:LogLevelColorMap = @{}
$script:SmokeTestFile = $SmokeTest; $script:SmokeTimer = $null; $script:SmokeCloser = $null; $script:LastDialog = $null; $script:SmokeSteps = @()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

function Show-HUFatal([string]$Text) {
    if ($SmokeTest) { "FEHLER $Text" | Set-Content -LiteralPath $SmokeTest -Encoding UTF8; exit 1 }
    [void][System.Windows.MessageBox]::Show($Text, 'HU-MultiTenant - Fehler', 'OK', 'Error')
    exit 1
}

# ============================================================================
# 1. VERSION, CORE-MODULE, FUNKTIONEN
# ============================================================================
$script:Version = '0.0.0'
try { $script:Version = "$((Get-Content (Join-Path $script:AppRoot 'Config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)" } catch { }

foreach ($mod in @('HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Extensions', 'HU.Intune')) {
    $modPath = Join-Path $script:AppRoot "Core\$mod.psm1"
    if (-not (Test-Path -LiteralPath $modPath)) { Show-HUFatal "Core-Modul fehlt: $modPath`n`nPull.ps1 ausfuehren, um die Dateien zu laden." }
    Import-Module $modPath -Force -DisableNameChecking
}
# optional (nur fuer Extensions mit Excel-Reports)
$modPath = Join-Path $script:AppRoot 'Core\HU.Excel.psm1'
if (Test-Path -LiteralPath $modPath) { try { Import-Module $modPath -Force -DisableNameChecking -ErrorAction Stop } catch { Write-Warning "HU.Excel: $($_.Exception.Message)" } }

foreach ($f in @('Core-Async', 'Core-Update', 'UI-Common', 'UI-State', 'UI-Tenants', 'UI-Snippets', 'UI-QSParams', 'UI-QSTable', 'UI-QSHistory', 'UI-QuickScript',
                 'UI-Extensions', 'UI-Permissions', 'UI-SecretSetup', 'UI-Shell', 'UI-Settings', 'UI-Update', 'UI-Jobs', 'UI-Apps', 'UI-Maint')) {
    $fp = Join-Path $script:AppRoot "Functions\$f.ps1"
    if (-not (Test-Path -LiteralPath $fp)) { Show-HUFatal "Datei fehlt: $fp`n`nPull.ps1 ausfuehren, um die Dateien zu laden." }
    . $fp
}

# ============================================================================
# 2. EINSTELLUNGEN (Erststart: leere settings.json anlegen)
# ============================================================================
$settingsPath = Join-Path $script:AppRoot 'Config\settings.json'
$script:FirstRun = $false
if (-not (Test-Path -LiteralPath $settingsPath)) {
    try { New-HUSettingsFile -Path $settingsPath; $script:FirstRun = $true } catch { Show-HUFatal "settings.json konnte nicht angelegt werden:`n$($_.Exception.Message)" }
}
$script:Settings = Import-TenantSettings -SettingsPath $settingsPath
if (-not $script:Settings) { Show-HUFatal "settings.json nicht lesbar:`n$settingsPath`n`nSicherung: settings.json.bak" }
$script:Settings = Initialize-HUSettingsDefaults $script:Settings
if (-not @($script:Settings.tenants).Count) { $script:FirstRun = $true }

$script:AppIcon = $null
$iconPath = Join-Path $script:AppRoot 'Assets\icon.ico'
if (Test-Path -LiteralPath $iconPath) { try { $script:AppIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create([System.Uri]::new($iconPath, [System.UriKind]::Absolute)) } catch { } }
# eigene Taskleisten-Gruppe (HU-Symbol statt PowerShell) - vor dem ersten Fenster
[void](Initialize-HUTaskbar)

# fehlende Client Secrets abfragen (vor dem Hauptfenster)
if (-not $script:FirstRun -and -not $SmokeTest) { [void](Show-SecretSetupDialog) }

# ============================================================================
# 3. HAUPTFENSTER
# ============================================================================
try {
    $d = New-HUWindow 'MainWindow'
} catch { Show-HUFatal "Oberflaeche konnte nicht geladen werden (XAML\MainWindow.xaml):`n$($_.Exception.Message)" }
$script:Window = $d.Window
$script:Controls = $d.C
if ($script:AppIcon) { $script:Window.Icon = $script:AppIcon; $script:Controls['imgLogo'].Source = $script:AppIcon }
$script:Window.Add_SourceInitialized({ Set-HUWindowTaskbar $script:Window })

$logFile = "$($script:Settings.logging.file)"
if (-not $logFile) { $logFile = './Logs/HU-MultiTenant_{date}.log' }
if (-not [System.IO.Path]::IsPathRooted($logFile)) { $logFile = Join-Path $script:AppRoot ($logFile -replace '^\.[\\/]', '') }
$minLevel = "$($script:Settings.logging.logLevel)".ToUpper()
if ($minLevel -notin 'DEBUG', 'INFO', 'OK', 'WARN', 'ERROR') { $minLevel = 'INFO' }
Initialize-Logging -LogFilePath $logFile -RichTextBox $script:Controls['rtbLog'] -MinLevel $minLevel -MaxGuiLines ([int]$script:Settings.ui.maxLogLines)

Initialize-AsyncPool -PoolSize 4

function Update-VersionDisplay {
    $isAdmin = Test-AdminPrivilege
    $script:Controls['txtVersion'].Text = "v$($script:Version)  |  $(if ($isAdmin) { 'Administrator' } else { 'Standardbenutzer' })"
    $script:Window.Title = "HU-MultiTenant v$($script:Version)"
}

# ============================================================================
# 4. EREIGNISSE
# ============================================================================
Register-HUTenantHandlers
Register-HUQuickScriptHandlers
Register-HUExtensionHandlers
Register-HUUpdateHandlers
Register-HUAppHandlers
Register-HURemHandlers
$script:Controls['btnSettings'].Add_Click({ Open-HUSettings })
# Rechtsklick in den Ausgaben: Kopieren / Alles kopieren / Ausgabe leeren
Add-HUOutputMenu $script:Controls['rtbQSOutput'] { $script:Controls['rtbQSOutput'].Document.Blocks.Clear() }
Add-HUOutputMenu $script:Controls['rtbLog'] { Clear-LogBuffer -IncludeGui }

# Tastatur: F1 Anleitung, Strg+0 Groesse 100 %, Quick-Script-Kuerzel
$script:Window.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ("$($e.Key)" -eq 'F1') { $e.Handled = $true; Show-HUManual; return }
    if ($ctrl -and "$($e.Key)" -in 'D0', 'NumPad0') { $e.Handled = $true; Set-HUUiScale 1.0; return }
    if (Invoke-HUQSKey $e) { $e.Handled = $true }
})
# Strg + Mausrad = Oberflaeche skalieren (im Skript-Editor: Schriftgroesse)
$script:Window.Add_PreviewMouseWheel({
    param($s, $e)
    if (-not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
    if ($script:Controls['txtQSEditor'].IsMouseOver) { return }
    Set-HUUiScale ($script:UiScale + $(if ($e.Delta -gt 0) { 0.1 } else { -0.1 }))
    $e.Handled = $true
})

$script:Window.Add_ContentRendered({
    if ($script:StartupDone) { return }
    $script:StartupDone = $true
    if ($script:SmokeTestFile) {
        # automatischer Test (CI): Fenster laeuft, Ergebnis schreiben, beenden
        $script:SmokeTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:SmokeTimer.Interval = [TimeSpan]::FromSeconds(2)
        $script:SmokeTimer.Add_Tick({
            $script:SmokeTimer.Stop()
            if ("$($script:SmokeTimer.Tag)" -eq 'run') {
                # Stufe 2: warten bis der Quick-Script-Lauf fertig ist
                if ($script:QS_Timer -and $script:QS_Timer.IsEnabled -and ((Get-Date) - $script:QS_Started).TotalSeconds -lt 60) { $script:SmokeTimer.Start(); return }
                $steps = @($script:SmokeSteps)
                $h = Get-HUQSHistory | Select-Object -First 1
                $ok = ($h -and @($h.Tenants).Count -ge 2 -and -not ($script:QS_Timer -and $script:QS_Timer.IsEnabled))
                $script:SmokeCloser.Stop()
                $tab = if ($script:Controls['tabMain'].SelectedItem -eq $script:Controls['tabQuickScript']) { 'QuickScript' } else { 'Extensions' }
                if ($ok) { "OK Version=$($script:Version) Tenants=$(@($script:Settings.tenants).Count) Extensions=$($script:ExtensionItems.Count) Tab=$tab Lauf=$($h.Result)/$($h.Errors)Fehler Schritte=$($steps -join ',')" | Set-Content -LiteralPath $script:SmokeTestFile -Encoding UTF8 }
                else { "FEHLER Lauf nicht abgeschlossen (Verlauf: $(if ($h) { $h | ConvertTo-Json -Compress }))" | Set-Content -LiteralPath $script:SmokeTestFile -Encoding UTF8 }
                $script:SkipCloseChecks = $true
                $script:Window.Close()
                return
            }
            $steps = @()
            try {
                # Dialoge oeffnen; ein zweiter Timer schliesst das jeweils offene Fenster nach kurzer Zeit
                $script:SmokeCloser = [System.Windows.Threading.DispatcherTimer]::new()
                $script:SmokeCloser.Interval = [TimeSpan]::FromMilliseconds(1200)
                $script:SmokeCloser.Add_Tick({ if ($script:LastDialog -and $script:LastDialog.IsVisible) { $script:LastDialog.Close() } })
                $script:SmokeCloser.Start()
                [void](Show-HUSettingsDialog -Tab 'Tenants'); $steps += 'Einstellungen'
                [void](Show-HUSnippetManager); $steps += 'Snippets'
                $first = Get-HUSnippets | Select-Object -First 1
                if ($first) { [void](Switch-HUSnippetFavorite $first.name); Update-HUSnippetCombo; if ($script:Controls['cmbSnippets'].Items[0].Fav) { $steps += 'Favorit' } }
                $script:Controls['tabMain'].SelectedItem = $script:Controls['tabExtensions']
                if ($script:Controls['lstExtensions'].Items.Count) { $script:Controls['lstExtensions'].SelectedIndex = 0; $steps += 'Extension-Details' }
                $script:Controls['tabMain'].SelectedItem = $script:Controls['tabQuickScript']
                $script:Controls['txtQSEditor'].Text = "# @param DryRun|bool|Nur anzeigen|true`n# @param Tage|int|Tage|30`n# @param Modus|choice|Modus|A|A;B`n[pscustomobject]@{ Tenant2 = `$TenantKey; Tage = `$Tage }"
                Update-HUQSParamPanel -Force
                if ($script:QSParamCtl.Count -ne 3) { throw "Parameterfelder: $($script:QSParamCtl.Count) statt 3" }
                $steps += 'Parameter'
                $script:QS_Objects.Add([pscustomobject]@{ Name = 'a'; Wert = 1; Liste = @(1, 2) }); $script:QS_Objects.Add([pscustomobject]@{ Name = 'b'; Neu = 'x' })
                Update-HUQSTableButton; Show-HUQSTable 'Test'; $steps += 'Tabelle'
                Add-HUQSHistory -Snippet 'Test' -Tenants @('Schule-1') -Seconds 1 -Result 'OK' -Errors 0 -Objects 2 -Lines @('x') -Code 'x'
                Show-HUQSHistory; $steps += 'Verlauf'
                $k1 = "$(@($script:Settings.tenants)[0].key)"
                $script:PermCache[$k1] = @{ Roles = @('User.Read.All', 'Organization.Read.All'); Error = ''; Time = Get-Date }
                Show-HUPermissions -TenantKey $k1; $steps += 'Berechtigungen'
                if (-not $script:Controls['rtbQSOutput'].ContextMenu -or -not $script:Controls['rtbLog'].ContextMenu) { throw 'Rechtsklick-Menue fehlt' }
                # Reiter Apps: Store-App und Win32-Erkennung im Formular
                $script:Controls['tabMain'].SelectedItem = $script:Controls['tabApps']
                $ta = ConvertTo-HUApp; $ta.Type = 'store'; $ta.Kind = 'store'; $ta.Name = 'Smoke-Store'; $ta.StoreId = '9NKSQGP7F2NH'; $ta.TargetKind = 'allDevices'
                $ta.Tenants = @("$(@($script:Settings.tenants)[0].key)")
                $script:AppLib.Add($ta); Update-HUAppList $ta.Id; Show-HUAppForm $ta; Save-HUAppForm
                if (@(Test-HUAppReady $ta).Count) { throw "Apps: $(@(Test-HUAppReady $ta) -join '; ')" }
                $tw = ConvertTo-HUApp; $tw.Name = 'Smoke-Win32'; $tw.Kind = 'exe'; $script:AppLib.Add($tw); Update-HUAppList $tw.Id; Show-HUAppForm $tw
                [void](Select-HUComboTag $script:Controls['cmbAppDetType'] 'file')
                $script:Controls['txtAppDetA'].Text = 'C:\Program Files\X'; $script:Controls['txtAppDetB'].Text = 'x.exe'; Save-HUAppForm
                if ($tw.Detection.Type -ne 'file' -or $tw.Detection.FileName -ne 'x.exe') { throw 'Apps: Erkennung wird nicht uebernommen' }
                if (-not (Set-HUAppIcon $tw "$env:windir\System32\notepad.exe" -Quiet) -or -not $script:Controls['imgAppIcon'].Source) { throw 'Apps: Symbol wird nicht uebernommen' }
                Remove-Item -LiteralPath (Get-HUAppIconPath $tw) -Force -ErrorAction SilentlyContinue
                [void]$script:AppLib.Remove($ta); [void]$script:AppLib.Remove($tw); $script:AppCurrent = $null; Update-HUAppList; Show-HUAppForm $null
                $steps += 'Apps'
                # Reiter Wartung: Beispiel uebernehmen und pruefen
                $script:Controls['tabMain'].SelectedItem = $script:Controls['tabMaint']
                $ex = @(Get-HURemExamples)
                if (-not $ex.Count) { throw 'Wartung: keine Beispiele' }
                Add-HURem $ex[0]
                if (-not (Invoke-HURemCheck)) { throw 'Wartung: Beispiel hat Pruef-Fehler' }
                [void]$script:RemLib.Remove($script:RemCurrent); $script:RemCurrent = $null; Update-HURemList; Show-HURemForm $null
                if (-not $script:Controls['rtbApps'].ContextMenu -or -not $script:Controls['rtbRem'].ContextMenu) { throw 'Rechtsklick-Menue Apps/Wartung fehlt' }
                $steps += 'Wartung'
                $script:Controls['tabMain'].SelectedItem = $script:Controls['tabQuickScript']
                $steps += 'Rechtsklick'
                if ('HUTaskbar' -as [type]) { $steps += 'Taskleiste' }
                Update-HUSecretDisplay; $steps += 'Secret-Anzeige'
                Save-HUWindowState; $steps += 'Fensterzustand'
                # Lauf auf zwei Tenants (ohne Secret -> je Tenant "Kein Token", Lauf muss sauber zu Ende gehen)
                foreach ($cb in $script:Controls['spQSTenants'].Children) { $cb.IsChecked = $true }
                if (@(Get-HUQSRunTenants).Count -lt 2) { throw 'Mehrfachauswahl wirkt nicht' }
                Start-HUQSRun; $steps += 'Lauf gestartet'
                $script:SmokeSteps = $steps
                $script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(500)
                $script:SmokeTimer.Tag = 'run'
                $script:SmokeTimer.Start()
                return
            } catch {
                "FEHLER nach [$($steps -join ',')]: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" | Set-Content -LiteralPath $script:SmokeTestFile -Encoding UTF8
            }
            $script:SkipCloseChecks = $true
            $script:Window.Close()
        })
        $script:SmokeTimer.Start()
        return
    }
    if ($script:FirstRun) {
        Write-HULogWarn 'Noch keine Tenants eingerichtet - Einstellungen > Tenants (Anleitung: F1).'
        Open-HUSettings 'Tenants'
        return
    }
    if ($script:Settings.ui.checkUpdatesOnStart -ne $false) { Invoke-UpdateCheck -Quiet }
    if ($script:Settings.ui.checkSecretsOnStart -ne $false) { Start-HUSecretCheckAll }
    else { Update-HUSecretDisplay -LogWarnings }
})

$script:Window.Add_Closing({
    param($s, $e)
    if (-not $script:SkipCloseChecks) {
        if ($script:IsRunning -and -not (Confirm-HU 'Eine Extension laeuft noch. Trotzdem beenden?' -Warning)) { $e.Cancel = $true; return }
        if (-not (Confirm-HUQSDiscard 'beenden')) { $e.Cancel = $true; return }
        if ((Test-HUJobRunning 'Apps') -or (Test-HUJobRunning 'Rem')) {
            if (-not (Confirm-HU 'Ein Upload/Auftrag in Apps oder Wartung laeuft noch und wird abgebrochen. Trotzdem beenden?' -Warning)) { $e.Cancel = $true; return }
        }
    }
    Save-HUWindowState
    Write-HULog -Message '=== Beenden: alle Tenants trennen ===' -Level 'INFO'
    foreach ($t in @($script:Settings.tenants)) {
        try { Clear-TokenCache -TenantKey $t.key; Update-TenantStatusCache -TenantKey $t.key -Connected $false } catch { }
        # "Secret speichern" aus -> Secret beim Beenden loeschen
        if ($t.PSObject.Properties['persistCredential'] -and $t.persistCredential -eq $false) {
            try { Remove-StoredCredential -TenantKey $t.key -Settings $script:Settings -Confirm:$false; Write-HULog -Message "Secret geloescht: $($t.key)" -Level 'WARN' } catch { }
        }
    }
    Close-HUQuickScript
    try { Close-HUApps; Close-HUMaint } catch { }
    try { if ($script:BgPowerShell) { $script:BgPowerShell.Stop() } } catch { }
    try { if ($script:BgProcess -and -not $script:BgProcess.HasExited) { $script:BgProcess.Kill() } } catch { }
    Close-AsyncPool
    Write-HULog -Message '=== HU-MultiTenant beendet ===' -Level 'INFO'
})

# ============================================================================
# 5. START
# ============================================================================
Write-HULogInfo "HU-MultiTenant v$($script:Version) startet ..."
Update-VersionDisplay
Update-TenantDropdown
Load-Extensions
Initialize-HUQuickScript
Initialize-HUApps
Initialize-HUMaint
Restore-HUWindowState
Select-HUStartTab
Write-HULogOK "Bereit - $(@($script:Settings.tenants).Count) Tenant(s), $($script:ExtensionItems.Count) Extension(s)."

[void]$script:Window.ShowDialog()
