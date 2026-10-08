#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Apps": Win32-Apps (MSI/EXE) und Microsoft-Store-Apps an mehrere Tenants verteilen.
.DESCRIPTION
    Ablauf fuer Menschen:
      1. Setup-Datei hinzufuegen (Knopf oder auf die Liste ziehen) - Name, Version, Befehle, Erkennung werden ausgelesen.
      2. Testinstallation in der Windows Sandbox - ermittelt Erkennung und Deinstallation, der eigene PC bleibt sauber.
      3. Tenants und Ziel waehlen, "Hochladen & zuweisen" - Paket wird einmal gebaut und in jeden Tenant hochgeladen.
         Optional zuerst nur an eine Pilotgruppe, spaeter "Fuer alle freigeben".
      4. "Status" zeigt je Geraet, ob die Installation geklappt hat.
    Bibliothek: Config\apps.json (lokal, nicht im Repository). Pakete/Sandbox: %LOCALAPPDATA%\HU-MultiTenant.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:AppLib = New-Object System.Collections.Generic.List[object]
$script:AppCurrent = $null
$script:AppLoading = $false
$script:AppDetType = 'msi'
$script:AppSbWatch = $null
$script:AppSbTimer = $null

function Get-HUAppLibPath { return (Join-Path $script:AppRoot 'Config\apps.json') }
function Get-HUAppIconPath($App) { return (Join-Path $script:AppRoot "Config\app-icons\$($App.Id).png") }

# Symbol im Formular anzeigen (Datei wird nicht gesperrt)
function Update-HUAppIconView {
    $c = $script:Controls; $a = $script:AppCurrent
    $c['imgAppIcon'].Source = $null
    $has = $false
    if ($a) {
        $f = Get-HUAppIconPath $a
        if (Test-Path -LiteralPath $f) {
            try {
                $bi = New-Object System.Windows.Media.Imaging.BitmapImage
                $bi.BeginInit()
                $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bi.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
                $bi.UriSource = [Uri]::new($f)
                $bi.EndInit()
                $c['imgAppIcon'].Source = $bi
                $has = $true
            } catch { }
        }
    }
    $c['lblAppIconNone'].Visibility = $(if ($has) { 'Collapsed' } else { 'Visible' })
    $c['btnAppIconClear'].IsEnabled = $has
}

# Symbol aus Bild/ICO/EXE uebernehmen -> Config\app-icons\<Id>.png
function Set-HUAppIcon($App, [string]$Source, [int]$Index = 0, [switch]$Quiet) {
    if (-not $App) { return $false }
    try {
        [void](ConvertTo-HUIconPng -Path $Source -Index $Index -OutFile (Get-HUAppIconPath $App))
        if ($script:AppCurrent -and $script:AppCurrent.Id -eq $App.Id) { Update-HUAppIconView }
        return $true
    } catch {
        if (-not $Quiet) { Show-HUMessage "Symbol nicht uebernommen:`n$($_.Exception.Message)" -Icon Warning }
        return $false
    }
}

# ----------------------------------------------------------------------------
# Datenmodell
# ----------------------------------------------------------------------------
function New-HUAppDetection($Src = $null) {
    $d = [pscustomobject][ordered]@{ Type = 'registry'; ProductCode = ''; Version = ''; VersionCheck = $false; KeyPath = ''; ValueName = ''; Path = ''; FileName = ''; Script = ''; Check32 = $false }
    if ($Src) { foreach ($p in $d.PSObject.Properties.Name) { if ($Src.PSObject.Properties[$p] -and $null -ne $Src.$p) { $d.$p = $Src.$p } } }
    $d.VersionCheck = [bool]$d.VersionCheck; $d.Check32 = [bool]$d.Check32
    return $d
}

function ConvertTo-HUApp($Src = $null) {
    $a = [pscustomobject][ordered]@{
        Id = [guid]::NewGuid().ToString(); Type = 'win32'; Name = ''; Publisher = ''; Description = ''; Version = ''; Kind = ''; InstallerType = ''
        SetupPath = ''; WholeFolder = $false; InstallCmd = ''; UninstallCmd = ''; RunAs = 'system'; UpgradeCode = ''
        Detection = (New-HUAppDetection); StoreId = ''
        TargetKind = 'group'; TargetGroup = ''; Intent = 'required'; Pilot = $false; PilotGroup = ''; Deadline = ''; Notify = 'showAll'
        Tenants = @(); Deployments = @(); SandboxNote = ''; Created = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Modified = ''
    }
    if ($Src) {
        foreach ($p in $a.PSObject.Properties.Name) { if ($Src.PSObject.Properties[$p] -and $null -ne $Src.$p) { $a.$p = $Src.$p } }
        $a.Detection = New-HUAppDetection $Src.Detection
        $a.Tenants = @($a.Tenants | Where-Object { $_ } | ForEach-Object { "$_" })
        $a.Deployments = @($a.Deployments | Where-Object { $_ } | ForEach-Object { [pscustomobject][ordered]@{ Tenant = "$($_.Tenant)"; AppId = "$($_.AppId)"; Version = "$($_.Version)"; Signature = "$($_.Signature)"; Stage = "$($_.Stage)"; Time = "$($_.Time)" } })
        $a.WholeFolder = [bool]$a.WholeFolder; $a.Pilot = [bool]$a.Pilot
    }
    return $a
}

function Import-HUAppLib {
    $script:AppLib.Clear()
    $j = Read-HUJsonFile (Get-HUAppLibPath)
    if ($j -and $j.PSObject.Properties['apps']) { foreach ($a in @($j.apps)) { if ($a) { $script:AppLib.Add((ConvertTo-HUApp $a)) } } }
}

function Save-HUAppLib {
    try { Write-HUJsonFile -Path (Get-HUAppLibPath) -Object ([pscustomobject]@{ version = 1; apps = @($script:AppLib.ToArray()) }) -Depth 8 -Backup }
    catch { Write-HULogError "Apps speichern fehlgeschlagen: $($_.Exception.Message)" }
}

function Get-HUAppById([string]$Id) { return ($script:AppLib | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) }

function Get-HUAppDeployment($App, [string]$Tenant) { return (@($App.Deployments) | Where-Object { $_.Tenant -eq $Tenant } | Select-Object -First 1) }

function Set-HUAppDeployment($App, [string]$Tenant, [hashtable]$Values) {
    $d = Get-HUAppDeployment $App $Tenant
    if (-not $d) {
        $d = [pscustomobject][ordered]@{ Tenant = $Tenant; AppId = ''; Version = ''; Signature = ''; Stage = ''; Time = '' }
        $App.Deployments = @(@($App.Deployments) + $d)
    }
    foreach ($k in $Values.Keys) { $d.$k = $Values[$k] }
}

# ----------------------------------------------------------------------------
# Liste und Formular
# ----------------------------------------------------------------------------
function Get-HUAppKindText($App) {
    if ($App.Type -eq 'store') { return 'STORE' }
    $k = "$($App.Kind)".ToUpper()
    if ($App.Kind -eq 'exe' -and "$($App.InstallerType)" -and "$($App.InstallerType)" -ne 'unbekannt') { $k += " ($($App.InstallerType))" }
    return $k
}

function Update-HUAppList([string]$SelectId = '') {
    $lst = $script:Controls['lstApps']
    if (-not $SelectId -and $script:AppCurrent) { $SelectId = $script:AppCurrent.Id }
    $items = foreach ($a in ($script:AppLib | Sort-Object Name)) {
        $dep = @($a.Deployments | Where-Object { $_.AppId })
        $sub = "$(Get-HUAppKindText $a)$(if ($a.Version) { " | v$($a.Version)" })"
        if ($dep.Count) { $sub += " | $($dep.Count) Tenant(s)$(if (@($dep | Where-Object { $_.Stage -eq 'pilot' }).Count) { ', Pilot' })" }
        [pscustomobject]@{ Title = $(if ($a.Name) { $a.Name } else { '(ohne Name)' }); Sub = $sub; Id = $a.Id }
    }
    $script:AppLoading = $true
    try {
        $lst.ItemsSource = @($items)
        $sel = @($items) | Where-Object { $_.Id -eq $SelectId } | Select-Object -First 1
        if ($sel) { $lst.SelectedItem = $sel } else { $lst.SelectedIndex = -1 }
    } finally { $script:AppLoading = $false }
}

function Update-HUAppTenantChecks {
    $sp = $script:Controls['spAppTenants']
    $sp.Children.Clear()
    foreach ($t in @($script:Settings.tenants)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$($t.displayName)"
        $cb.Tag = "$($t.key)"
        $cb.Foreground = Get-HUBrush '#CCCCCC'
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 14, 2)
        [void]$sp.Children.Add($cb)
    }
}

function Get-HUCheckedTenants($Panel) { return @($Panel.Children | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" }) }
function Set-HUCheckedTenants($Panel, [string[]]$Keys) { foreach ($cb in $Panel.Children) { $cb.IsChecked = (@($Keys) -contains "$($cb.Tag)") } }

function Get-HUComboTag($Combo) { if ($Combo.SelectedItem) { return "$($Combo.SelectedItem.Tag)" }; return '' }

function Get-HUDeploymentText($Deployments) {
    $parts = foreach ($d in @($Deployments | Where-Object { $_.AppId -or $_.Stage })) {
        $st = switch ("$($d.Stage)") { 'pilot' { 'Pilot' } 'all' { 'alle' } default { 'nicht zugewiesen' } }
        "$(Get-HUTenantDisplayName $d.Tenant): $(if ($d.Version) { "v$($d.Version), " })$st$(if ($d.Time) { ", $($d.Time)" })"
    }
    if (-not @($parts).Count) { return 'Noch nicht verteilt.' }
    return "Verteilt: " + (@($parts) -join '  |  ')
}

# Erkennungsfelder je Art (Beschriftung/Sichtbarkeit) - Werte stehen im Detection-Objekt
function Update-HUAppDetUi {
    $c = $script:Controls
    $t = $script:AppDetType
    $vis = { param($el, [bool]$on) $el.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' }) }
    $isScript = ($t -eq 'script')
    foreach ($n in 'lblAppDetA', 'txtAppDetA', 'chkAppDetVer', 'txtAppDetVer') { & $vis $c[$n] (-not $isScript) }
    & $vis $c['lblAppDetB'] ($t -in 'registry', 'file')
    & $vis $c['txtAppDetB'] ($t -in 'registry', 'file')
    & $vis $c['chkAppDet32'] ($t -in 'registry', 'file')
    & $vis $c['txtAppDetScript'] $isScript
    switch ($t) {
        'msi' { $c['lblAppDetA'].Text = 'Produktcode'; $c['txtAppDetA'].ToolTip = '{GUID} aus der MSI - steht nach dem Hinzufuegen schon drin' }
        'registry' {
            $c['lblAppDetA'].Text = 'Schluessel'; $c['lblAppDetB'].Text = 'Wert (optional)'
            $c['txtAppDetA'].ToolTip = 'z. B. HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\MeineApp'
            $c['txtAppDetB'].ToolTip = 'z. B. DisplayVersion - leer = Schluessel muss nur vorhanden sein'
        }
        'file' {
            $c['lblAppDetA'].Text = 'Ordner'; $c['lblAppDetB'].Text = 'Datei/Ordner'
            $c['txtAppDetA'].ToolTip = 'z. B. C:\Program Files\MeineApp  (Umgebungsvariablen wie %ProgramFiles% sind erlaubt)'
            $c['txtAppDetB'].ToolTip = 'z. B. MeineApp.exe'
        }
    }
}

function Write-HUAppDetFields {
    # Formular -> Detection-Objekt (fuer die aktuell gezeigte Art)
    if (-not $script:AppCurrent) { return }
    $c = $script:Controls; $d = $script:AppCurrent.Detection
    switch ($script:AppDetType) {
        'msi' { $d.ProductCode = $c['txtAppDetA'].Text.Trim() }
        'registry' { $d.KeyPath = $c['txtAppDetA'].Text.Trim(); $d.ValueName = $c['txtAppDetB'].Text.Trim() }
        'file' { $d.Path = $c['txtAppDetA'].Text.Trim(); $d.FileName = $c['txtAppDetB'].Text.Trim() }
        'script' { $d.Script = $c['txtAppDetScript'].Text }
    }
    if ($script:AppDetType -ne 'script') { $d.VersionCheck = [bool]$c['chkAppDetVer'].IsChecked; $d.Version = $c['txtAppDetVer'].Text.Trim() }
    if ($script:AppDetType -in 'registry', 'file') { $d.Check32 = [bool]$c['chkAppDet32'].IsChecked }
    $d.Type = $script:AppDetType
}

function Read-HUAppDetFields {
    $c = $script:Controls; $d = $script:AppCurrent.Detection
    $c['txtAppDetA'].Text = switch ($script:AppDetType) { 'msi' { "$($d.ProductCode)" } 'registry' { "$($d.KeyPath)" } 'file' { "$($d.Path)" } default { '' } }
    $c['txtAppDetB'].Text = switch ($script:AppDetType) { 'registry' { "$($d.ValueName)" } 'file' { "$($d.FileName)" } default { '' } }
    $c['txtAppDetScript'].Text = "$($d.Script)"
    $c['chkAppDetVer'].IsChecked = [bool]$d.VersionCheck
    $c['txtAppDetVer'].Text = "$($d.Version)"
    $c['chkAppDet32'].IsChecked = [bool]$d.Check32
}

function Show-HUAppForm($App) {
    $c = $script:Controls
    $script:AppLoading = $true
    try {
        $script:AppCurrent = $App
        $c['pnlAppForm'].IsEnabled = [bool]$App
        if (-not $App) {
            foreach ($n in 'txtAppName', 'txtAppPublisher', 'txtAppVersion', 'txtAppDesc', 'txtAppSetup', 'txtAppInstall', 'txtAppUninstall', 'txtAppDetA', 'txtAppDetB', 'txtAppDetVer', 'txtAppStoreId', 'txtAppGroup', 'txtAppPilot', 'txtAppDeadline') { $c[$n].Text = '' }
            $c['txtAppKind'].Text = ''; $c['txtAppInfo'].Text = ''; $c['txtAppSandbox'].Text = ''
            foreach ($p in @(@('cmbAppTarget', 'group'), @('cmbAppIntent', 'required'), @('cmbAppNotify', 'showAll'), @('cmbAppRunAs', 'system'), @('cmbAppDetType', 'msi'))) { [void](Select-HUComboTag $c[$p[0]] $p[1]) }
            Set-HUCheckedTenants $c['spAppTenants'] @()
            $c['txtAppTenantState'].Text = 'Links eine App waehlen oder mit "+ Setup-Datei" hinzufuegen (auch per Ziehen auf die Liste).'
            Update-HUAppIconView
            Update-HUAppButtons
            return
        }
        $isStore = ($App.Type -eq 'store')
        $c['pnlAppWin32'].Visibility = $(if ($isStore) { 'Collapsed' } else { 'Visible' })
        $c['pnlAppStore'].Visibility = $(if ($isStore) { 'Visible' } else { 'Collapsed' })
        $c['txtAppName'].Text = "$($App.Name)"
        $c['txtAppKind'].Text = Get-HUAppKindText $App
        $c['txtAppPublisher'].Text = "$($App.Publisher)"
        $c['txtAppVersion'].Text = "$($App.Version)"
        $c['txtAppDesc'].Text = "$($App.Description)"
        $c['txtAppSetup'].Text = "$($App.SetupPath)"
        $c['chkAppWholeFolder'].IsChecked = [bool]$App.WholeFolder
        $c['txtAppInstall'].Text = "$($App.InstallCmd)"
        $c['txtAppUninstall'].Text = "$($App.UninstallCmd)"
        $c['txtAppInfo'].Text = $(if ($App.SetupPath -and -not (Test-Path -LiteralPath $App.SetupPath)) { 'Setup-Datei nicht gefunden - "Andere Datei ..." waehlen.' } else { '' })
        $script:AppDetType = $(if ("$($App.Detection.Type)") { "$($App.Detection.Type)" } else { 'registry' })
        Select-HUComboTag $c['cmbAppDetType'] $script:AppDetType
        Read-HUAppDetFields
        Update-HUAppDetUi
        $c['txtAppSandbox'].Text = "$($App.SandboxNote)"
        $c['txtAppStoreId'].Text = "$($App.StoreId)"
        Select-HUComboTag $c['cmbAppRunAs'] $(if ($App.RunAs) { $App.RunAs } else { 'system' })
        Set-HUCheckedTenants $c['spAppTenants'] @($App.Tenants)
        Select-HUComboTag $c['cmbAppTarget'] $App.TargetKind
        $c['txtAppGroup'].Text = "$($App.TargetGroup)"
        Select-HUComboTag $c['cmbAppIntent'] $App.Intent
        $c['chkAppPilot'].IsChecked = [bool]$App.Pilot
        $c['txtAppPilot'].Text = "$($App.PilotGroup)"
        $c['txtAppDeadline'].Text = "$($App.Deadline)"
        Select-HUComboTag $c['cmbAppNotify'] $App.Notify
        $c['txtAppTenantState'].Text = Get-HUDeploymentText $App.Deployments
        Update-HUAppTargetUi
        Update-HUAppIconView
    } finally { $script:AppLoading = $false }
    Update-HUAppButtons
}

function Update-HUAppTargetUi {
    $c = $script:Controls
    $c['txtAppGroup'].IsEnabled = ((Get-HUComboTag $c['cmbAppTarget']) -eq 'group')
    $c['txtAppPilot'].IsEnabled = [bool]$c['chkAppPilot'].IsChecked
    $c['btnAppGroupPick'].IsEnabled = $c['txtAppGroup'].IsEnabled
}

function Update-HUAppButtons {
    $c = $script:Controls; $a = $script:AppCurrent
    $busy = (Test-HUJobRunning 'Apps')
    $has = [bool]$a
    $deps = if ($a) { @($a.Deployments | Where-Object { $_.AppId }) } else { @() }
    $c['btnAppSave'].IsEnabled = $has
    $c['btnAppDeploy'].IsEnabled = $has -and -not $busy
    $c['btnAppRelease'].IsEnabled = $has -and -not $busy -and [bool]@($deps | Where-Object { $_.Stage -eq 'pilot' }).Count
    $c['btnAppStatus'].IsEnabled = $has -and -not $busy -and [bool]$deps.Count
    $c['btnAppRemove'].IsEnabled = $has
    $c['btnAppSandbox'].IsEnabled = $has -and $a.Type -ne 'store' -and -not $script:AppSbWatch -and -not (Test-HUJobRunning 'AppSandbox')
}

# Formular -> aktuelles App-Objekt
function Save-HUAppForm {
    $a = $script:AppCurrent
    if (-not $a -or $script:AppLoading) { return }
    $c = $script:Controls
    $a.Name = $c['txtAppName'].Text.Trim()
    $a.Publisher = $c['txtAppPublisher'].Text.Trim()
    $a.Version = $c['txtAppVersion'].Text.Trim()
    $a.Description = $c['txtAppDesc'].Text.Trim()
    $a.WholeFolder = [bool]$c['chkAppWholeFolder'].IsChecked
    $a.InstallCmd = $c['txtAppInstall'].Text.Trim()
    $a.UninstallCmd = $c['txtAppUninstall'].Text.Trim()
    Write-HUAppDetFields
    $a.StoreId = $c['txtAppStoreId'].Text.Trim().ToUpper()
    $a.RunAs = Get-HUComboTag $c['cmbAppRunAs']
    $a.Tenants = @(Get-HUCheckedTenants $c['spAppTenants'])
    $a.TargetKind = Get-HUComboTag $c['cmbAppTarget']
    $a.TargetGroup = $c['txtAppGroup'].Text.Trim()
    $a.Intent = Get-HUComboTag $c['cmbAppIntent']
    $a.Pilot = [bool]$c['chkAppPilot'].IsChecked
    $a.PilotGroup = $c['txtAppPilot'].Text.Trim()
    $a.Deadline = $c['txtAppDeadline'].Text.Trim()
    $a.Notify = Get-HUComboTag $c['cmbAppNotify']
    $a.Modified = Get-Date -Format 'yyyy-MM-dd HH:mm'
}

function Select-HUApp([string]$Id) {
    Save-HUAppForm
    Save-HUAppLib
    Show-HUAppForm (Get-HUAppById $Id)
}

# ----------------------------------------------------------------------------
# Hinzufuegen
# ----------------------------------------------------------------------------
function Add-HUAppFromFile([string]$Path) {
    if ($Path -notmatch '(?i)\.(msi|exe)$') { Show-HUMessage "Nur .msi- und .exe-Dateien.`n`n$Path" -Icon Warning; return }
    try { $info = Get-HUSetupInfo -Path $Path } catch { Show-HUMessage "Datei nicht lesbar:`n$($_.Exception.Message)" -Icon Error; return }
    Save-HUAppForm
    $existing = $script:AppLib | Where-Object { $_.Type -eq 'win32' -and $info.Name -and $_.Name -eq $info.Name } | Select-Object -First 1
    $a = $null
    if ($existing) {
        $ans = Confirm-HUYesNoCancel "'$($info.Name)' gibt es schon in der Bibliothek (v$($existing.Version)).`n`nJa = als neue Version dieser App uebernehmen (dieselbe Intune-App wird beim Hochladen aktualisiert)`nNein = als eigene App hinzufuegen"
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'Yes') { $a = $existing }
    }
    $isNew = -not $a
    if ($isNew) {
        $a = ConvertTo-HUApp
        $a.Name = $info.Name; $a.Publisher = $info.Publisher
        $a.Tenants = @(Get-HUStateValue 'appTenants' @())
        $a.TargetGroup = "$(Get-HUStateValue 'appLastGroup' '')"
    }
    $a.Kind = $info.Kind; $a.InstallerType = $info.InstallerType
    $a.Version = $info.Version
    $a.SetupPath = (Get-Item -LiteralPath $Path).FullName
    $a.InstallCmd = $info.InstallCmd
    if ($info.Kind -eq 'msi') {
        $a.UninstallCmd = $info.UninstallCmd; $a.UpgradeCode = $info.UpgradeCode
        $a.Detection = New-HUAppDetection $info.Detection
    } elseif ($isNew) {
        $a.Detection = New-HUAppDetection
    } elseif ($a.Detection.VersionCheck -and $info.Version) {
        $a.Detection.Version = $info.Version
    }
    # Zusatzdateien neben dem Setup (Transform, Konfiguration) -> ganzen Ordner vorschlagen
    $dir = Split-Path $a.SetupPath -Parent
    $others = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne (Split-Path $a.SetupPath -Leaf) -and $_.Extension -match '(?i)^\.(mst|cab|ini|xml|json|cfg|config|reg|txt|lic)$' })
    $big = (Split-Path $dir -Leaf) -match '(?i)^(downloads|desktop|documents|dokumente)$'
    $a.WholeFolder = ($others.Count -gt 0 -and -not $big)
    if ($isNew) { $script:AppLib.Add($a) }
    # Symbol aus der Setup-EXE (spaeter ersetzt die Testinstallation es durch das der installierten App)
    if ($info.Kind -eq 'exe' -and -not (Test-Path -LiteralPath (Get-HUAppIconPath $a))) { [void](Set-HUAppIcon $a $a.SetupPath -Quiet) }
    Save-HUAppLib
    Update-HUAppList $a.Id
    Show-HUAppForm $a
    $hint = $info.Hint
    if ($info.Kind -eq 'exe') { $hint += ' Tipp: "Testinstallation in der Windows Sandbox" ermittelt Erkennung und Deinstallation.' }
    if ($a.WholeFolder) { $hint += " Im Ordner liegen Zusatzdateien ($(@($others | Select-Object -First 3 | ForEach-Object Name) -join ', ')) - der ganze Ordner wird mitgepackt." }
    $script:Controls['txtAppInfo'].Text = $hint
    Add-HURtbLine $script:Controls['rtbApps'] "$(if ($isNew) { 'Hinzugefuegt' } else { 'Neue Version' }): $($a.Name) v$($a.Version) ($(Get-HUAppKindText $a))" '#81C784'
}

function Add-HUAppStore {
    Save-HUAppForm
    $id = ''
    try { $id = Get-HUStoreIdFromText ([System.Windows.Clipboard]::GetText()) } catch { }
    $a = ConvertTo-HUApp
    $a.Type = 'store'; $a.Kind = 'store'; $a.Name = 'Neue Store-App'
    $a.Tenants = @(Get-HUStateValue 'appTenants' @())
    $a.TargetGroup = "$(Get-HUStateValue 'appLastGroup' '')"
    $a.Detection = New-HUAppDetection
    $script:AppLib.Add($a)
    Update-HUAppList $a.Id
    Show-HUAppForm $a
    if ($id) { $script:Controls['txtAppStoreId'].Text = $id; Update-HUAppStoreInfo }
    else { Add-HURtbLine $script:Controls['rtbApps'] 'Store-App: auf apps.microsoft.com die App suchen und die Adresse (oder nur die ID) bei Store-ID einfuegen.' '#90CAF9' }
    $script:Controls['txtAppStoreId'].Focus() | Out-Null
}

function Update-HUAppStoreInfo {
    $c = $script:Controls; $a = $script:AppCurrent
    if (-not $a -or $a.Type -ne 'store') { return }
    $id = Get-HUStoreIdFromText $c['txtAppStoreId'].Text
    if (-not $id) { return }
    if ($c['txtAppStoreId'].Text -ne $id) { $c['txtAppStoreId'].Text = $id }
    if ($a.StoreId -eq $id -and $a.Name -ne 'Neue Store-App') { return }
    $a.StoreId = $id
    $old = $script:Window.Cursor; $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $info = Get-HUStoreAppInfo $id } finally { $script:Window.Cursor = $old }
    if ($info -and $info.Name) {
        if (-not $c['txtAppName'].Text.Trim() -or $c['txtAppName'].Text -eq 'Neue Store-App') { $c['txtAppName'].Text = $info.Name }
        if (-not $c['txtAppPublisher'].Text.Trim()) { $c['txtAppPublisher'].Text = $info.Publisher }
        if (-not $c['txtAppDesc'].Text.Trim()) { $c['txtAppDesc'].Text = $info.Description }
        Add-HURtbLine $c['rtbApps'] "Store-App gefunden: $($info.Name) ($($info.Publisher))" '#81C784'
    } else { Add-HURtbLine $c['rtbApps'] "Store-ID $id - Name konnte nicht abgerufen werden, bitte selbst eintragen." '#FFB74D' }
    if (-not (Test-Path -LiteralPath (Get-HUAppIconPath $a))) {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try { if (Save-HUStoreAppIcon $id (Get-HUAppIconPath $a)) { Add-HURtbLine $c['rtbApps'] 'Symbol aus dem Microsoft Store uebernommen.' '#81C784' } } finally { $script:Window.Cursor = $old }
        Update-HUAppIconView
    }
    Save-HUAppForm; Save-HUAppLib; Update-HUAppList $a.Id
}

function Remove-HUAppCurrent {
    $a = $script:AppCurrent
    if (-not $a) { return }
    $deps = @($a.Deployments | Where-Object { $_.AppId })
    $msg = "'$($a.Name)' aus der Bibliothek entfernen?"
    if ($deps.Count) { $msg += "`n`nIn Intune bleibt die App in $($deps.Count) Tenant(s) bestehen (dort bei Bedarf loeschen)." }
    if (-not (Confirm-HU $msg -Warning)) { return }
    [void]$script:AppLib.Remove($a)
    Remove-Item -LiteralPath (Get-HUAppIconPath $a) -Force -ErrorAction SilentlyContinue
    foreach ($sub in "Packages\$($a.Id)", "Sandbox\$($a.Id)") {
        $p = Join-Path (Join-Path $env:LOCALAPPDATA 'HU-MultiTenant') $sub
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $script:AppCurrent = $null
    Save-HUAppLib
    Update-HUAppList
    Show-HUAppForm $null
}

# ----------------------------------------------------------------------------
# Pruefen vor dem Hochladen
# ----------------------------------------------------------------------------
function ConvertTo-HUDeadline([string]$Text) {
    $t = "$Text".Trim()
    if (-not $t) { return $null }
    foreach ($f in 'd.M.yyyy H:mm', 'd.M.yyyy') {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, $f, [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) {
            if ($f -eq 'd.M.yyyy') { $d = $d.AddHours(16) }
            return $d
        }
    }
    throw "Frist '$t' nicht lesbar - Format TT.MM.JJJJ oder TT.MM.JJJJ HH:mm"
}

function Test-HUAppReady($App, [switch]$Release) {
    $err = New-Object System.Collections.Generic.List[string]
    if (-not $App.Name) { $err.Add('Name fehlt.') }
    if (-not @($App.Tenants).Count) { $err.Add('Kein Tenant angehakt.') }
    if ($App.TargetKind -eq 'group' -and -not $App.TargetGroup) { $err.Add('Zielgruppe fehlt (oder Ziel "Alle Geraete"/"Alle Benutzer" waehlen).') }
    if ($App.Pilot -and -not $Release -and -not $App.PilotGroup) { $err.Add('Pilotgruppe fehlt.') }
    try { [void](ConvertTo-HUDeadline $App.Deadline) } catch { $err.Add($_.Exception.Message) }
    if ($App.Type -eq 'store') {
        if (-not (Test-HUStoreId $App.StoreId)) { $err.Add('Store-ID fehlt oder ist ungueltig.') }
    } elseif (-not $Release) {
        if (-not $App.SetupPath -or -not (Test-Path -LiteralPath $App.SetupPath)) { $err.Add('Setup-Datei nicht gefunden.') }
        if (-not $App.InstallCmd) { $err.Add('Installationsbefehl fehlt.') }
        if (-not $App.UninstallCmd) { $err.Add('Deinstallationsbefehl fehlt (Intune verlangt ihn - Testinstallation in der Sandbox ermittelt ihn).') }
        try { [void](ConvertTo-HUDetectionRule $App.Detection) } catch { $err.Add("Erkennung: $($_.Exception.Message)") }
        if ($App.InstallCmd -and $App.SetupPath -and $App.InstallCmd -notmatch [regex]::Escape((Split-Path $App.SetupPath -Leaf)) -and $App.InstallCmd -notmatch '(?i)^(powershell|cmd|msiexec)') {
            $err.Add("Der Installationsbefehl enthaelt die Setup-Datei '$(Split-Path $App.SetupPath -Leaf)' nicht.")
        }
    }
    return $err.ToArray()
}

function Get-HUAppTargets($App, [switch]$Main) {
    if ($App.Pilot -and -not $Main) { return @(@{ Kind = 'group'; GroupName = $App.PilotGroup; Intent = $App.Intent }) }
    return @(@{ Kind = $App.TargetKind; GroupName = $App.TargetGroup; Intent = $App.Intent })
}

function Get-HUAppTargetText($App, [switch]$Main) {
    $intent = switch ($App.Intent) { 'available' { 'verfuegbar' } 'uninstall' { 'deinstallieren' } default { 'erforderlich' } }
    if ($App.Pilot -and -not $Main) { return "Pilotgruppe '$($App.PilotGroup)' ($intent)" }
    $t = switch ($App.TargetKind) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } default { "Gruppe '$($App.TargetGroup)'" } }
    return "$t ($intent)"
}

# ----------------------------------------------------------------------------
# Hochladen & zuweisen / Fuer alle freigeben (Hintergrund)
# ----------------------------------------------------------------------------
$script:AppDeployCode = {
    $results = New-Object System.Collections.Generic.List[object]
    $pkg = $null
    if ($Def.Type -eq 'win32' -and -not $Release) {
        $tool = Get-HUIntuneWinAppUtil -AppRoot $AppRoot -Download:$DownloadTool
        if (-not $tool) { throw 'IntuneWinAppUtil.exe fehlt (Tools-Ordner)' }
        $pkg = Get-HUAppPackage -ToolPath $tool -AppId $Def.Id -SetupPath $Def.SetupPath -WholeFolder ([bool]$Def.WholeFolder)
    }
    $w32 = [pscustomobject]@{
        Name = $Def.Name; Publisher = $Def.Publisher; Description = $Def.Description; Version = $Def.Version
        SetupFile = [IO.Path]::GetFileName("$($Def.SetupPath)"); InstallCmd = $Def.InstallCmd; UninstallCmd = $Def.UninstallCmd
        RunAs = $Def.RunAs; Kind = $Def.Kind; UpgradeCode = $Def.UpgradeCode; Detection = $Def.Detection; Restart = 'suppress'; IconFile = $Def.IconFile
    }
    foreach ($tk in $Tenants) {
        $r = [ordered]@{ Tenant = $tk; Ok = $false; AppId = ''; Signature = ''; Error = '' }
        try {
            Write-HULog -Message "--- $tk ---" -Level 'INFO' -Tenant $tk
            $dep = $Deployments[$tk]
            $appId = if ($dep) { "$($dep.AppId)" } else { '' }
            $existing = if ($appId) { Get-HUIntuneApp -TenantKey $tk -Settings $Settings -AppId $appId } else { $null }
            if ($appId -and -not $existing) { Write-HULog -Message 'Frueher hochgeladene App gibt es in Intune nicht mehr - wird neu angelegt' -Level 'WARN' -Tenant $tk; $appId = '' }
            if ($Release) {
                if (-not $existing) { throw 'App in diesem Tenant nicht gefunden - zuerst hochladen' }
                $r.AppId = $appId; $r.Signature = "$($dep.Signature)"
            } elseif ($Def.Type -eq 'store') {
                if (-not $existing) {
                    $new = New-HUStoreApp -TenantKey $tk -Settings $Settings -Def $Def
                    $appId = "$($new.id)"
                    Write-HULog -Message "Store-App angelegt ($($Def.StoreId))" -Level 'OK' -Tenant $tk
                } else {
                    Write-HULog -Message 'Store-App ist schon vorhanden' -Level 'INFO' -Tenant $tk
                    $ic = Get-HUIconContent "$($Def.IconFile)"
                    if ($ic) { [void](Invoke-HUIntuneGraph -TenantKey $tk -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$appId" -Method PATCH -Body @{ '@odata.type' = '#microsoft.graph.winGetApp'; largeIcon = $ic }); Write-HULog -Message 'Symbol aktualisiert' -Level 'OK' -Tenant $tk }
                }
                $r.AppId = $appId
            } else {
                if ($existing) {
                    Update-HUWin32App -TenantKey $tk -Settings $Settings -AppId $appId -Def $w32 -IntuneWinName $pkg.IntuneWinName
                    Write-HULog -Message "App aktualisiert (v$($Def.Version))" -Level 'OK' -Tenant $tk
                } else {
                    $new = New-HUWin32App -TenantKey $tk -Settings $Settings -Def $w32 -IntuneWinName $pkg.IntuneWinName
                    $appId = "$($new.id)"
                    Write-HULog -Message "App angelegt (v$($Def.Version))" -Level 'OK' -Tenant $tk
                }
                $r.AppId = $appId
                if (-not $existing -or "$($dep.Signature)" -ne "$($pkg.Signature)" -or "$($existing.committedContentVersion)" -eq '') {
                    Write-HULog -Message ("Lade Paket hoch ({0:N1} MB) ..." -f ($pkg.EncryptedSize / 1MB)) -Level 'INFO' -Tenant $tk
                    [void](Publish-HUWin32Content -TenantKey $tk -Settings $Settings -AppId $appId -Package $pkg)
                    Write-HULog -Message 'Paket hochgeladen' -Level 'OK' -Tenant $tk
                } else { Write-HULog -Message 'Paket unveraendert - kein erneuter Upload' -Level 'INFO' -Tenant $tk }
                $r.Signature = "$($pkg.Signature)"
            }
            $tg = @(Resolve-HUTargets -TenantKey $tk -Settings $Settings -Targets $Targets)
            $n = Set-HUAppAssignment -TenantKey $tk -Settings $Settings -AppId $appId -AppKind $(if ($Def.Type -eq 'store') { 'winget' } else { 'win32' }) -Targets $tg -Notifications $Notify -Deadline $Deadline
            Write-HULog -Message "Zugewiesen: $(@($tg | ForEach-Object { $_.Label }) -join ', ') - insgesamt $n Zuweisung(en)" -Level 'OK' -Tenant $tk
            $r.Ok = $true
        } catch {
            $r.Error = $_.Exception.Message
            $hint = ''
            if ($r.Error -match '403|Forbidden|Authorization') { $hint = ' -> Berechtigung DeviceManagementApps.ReadWrite.All (und Group.Read.All) in der App-Registrierung erteilen' }
            Write-HULog -Message "$($r.Error)$hint" -Level 'ERROR' -Tenant $tk
        }
        $results.Add([pscustomobject]$r)
    }
    $results.ToArray()
}

function Start-HUAppDeploy([switch]$Release) {
    Save-HUAppForm
    $a = $script:AppCurrent
    if (-not $a) { return }
    Save-HUAppLib
    $tenants = @($a.Tenants)
    if ($Release) { $tenants = @($a.Deployments | Where-Object { $_.Stage -eq 'pilot' -and $_.AppId } | ForEach-Object { $_.Tenant }) }
    $err = @(Test-HUAppReady $a -Release:$Release)
    if ($Release -and $tenants.Count) { $err = @($err | Where-Object { $_ -ne 'Kein Tenant angehakt.' }) }
    if ($err.Count) { Show-HUMessage ("Bitte zuerst ergaenzen:`n`n- " + ($err -join "`n- ")) 'Apps' -Icon Warning; return }

    $download = $false
    if ($a.Type -eq 'win32' -and -not $Release -and -not (Get-HUIntuneWinAppUtil -AppRoot $script:AppRoot)) {
        if (-not (Confirm-HU "Zum Paketieren wird das 'Microsoft Win32 Content Prep Tool' (IntuneWinAppUtil.exe) gebraucht.`nLaut Microsoft-Lizenz darf es nicht mitgeliefert werden.`n`nJetzt von github.com/microsoft laden? (Signatur wird geprueft, Ablage im Ordner Tools)")) { return }
        $download = $true
    }
    $names = @($tenants | ForEach-Object { Get-HUTenantDisplayName $_ }) -join ', '
    $what = if ($Release) { "Freigeben fuer: $(Get-HUAppTargetText $a -Main)" } else { "Ziel: $(Get-HUAppTargetText $a)" }
    $dl = ConvertTo-HUDeadline $a.Deadline
    $msg = "$($a.Name)$(if ($a.Version) { " v$($a.Version)" })`n`nTenants: $names`n$what$(if ($dl) { "`nFrist: $($dl.ToString('dd.MM.yyyy HH:mm'))" })"
    if (-not $Release -and $a.Type -eq 'win32' -and -not $a.SandboxNote) { $msg += "`n`nHinweis: noch keine Testinstallation in der Sandbox." }
    if (-not $Release -and -not (Test-Path -LiteralPath (Get-HUAppIconPath $a))) { $msg += "`nHinweis: ohne Symbol (im Unternehmensportal erscheint ein Platzhalter)." }
    if (-not (Confirm-HU "$msg`n`nJetzt $(if ($Release) { 'freigeben' } else { 'hochladen und zuweisen' })?")) { return }

    Set-HUStateValue 'appTenants' @($a.Tenants)
    if ($a.TargetGroup) { Set-HUStateValue 'appLastGroup' $a.TargetGroup }
    $deps = @{}
    foreach ($d in @($a.Deployments)) { $deps[$d.Tenant] = $d }
    $def = $a | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $ip = Get-HUAppIconPath $a
    $def | Add-Member -NotePropertyName IconFile -NotePropertyValue $(if (Test-Path -LiteralPath $ip) { $ip } else { '' }) -Force
    $script:AppJobApp = $a.Id
    $script:AppJobRelease = [bool]$Release
    $rtb = $script:Controls['rtbApps']
    Add-HURtbLine $rtb "=== $(if ($Release) { 'Freigabe' } else { 'Verteilung' }): $($a.Name) $(Get-Date -Format 'HH:mm:ss') ===" '#4FC3F7'
    [void](Start-HUJob -Name 'Apps' -Code $script:AppDeployCode -Output $rtb -Vars @{
        Def = $def; Tenants = $tenants; Deployments = $deps; Release = [bool]$Release; DownloadTool = $download
        Targets = @(Get-HUAppTargets $a -Main:$Release); Notify = $(if ($a.Notify) { $a.Notify } else { 'showAll' }); Deadline = $dl
    } -OnDone { param($Result, $Errors) Complete-HUAppDeploy $Result })
    Update-HUAppButtons
}

function Complete-HUAppDeploy($Result) {
    $a = Get-HUAppById $script:AppJobApp
    $okN = 0; $failN = 0
    if ($a) {
        foreach ($r in @($Result | Where-Object { $_ -and $_.PSObject.Properties['Tenant'] })) {
            if ($r.Ok) { $okN++ } else { $failN++ }
            if (-not $r.AppId) { continue }
            $v = @{ AppId = $r.AppId }
            if ($r.Signature) { $v.Signature = $r.Signature }
            if ($r.Ok) {
                $v.Time = Get-Date -Format 'dd.MM. HH:mm'
                $v.Stage = $(if ($script:AppJobRelease -or -not $a.Pilot) { 'all' } else { 'pilot' })
                if (-not $script:AppJobRelease) { $v.Version = $a.Version }
            }
            Set-HUAppDeployment $a $r.Tenant $v
        }
        Save-HUAppLib
        Update-HUAppList $a.Id
        if ($script:AppCurrent -and $script:AppCurrent.Id -eq $a.Id) { $script:Controls['txtAppTenantState'].Text = Get-HUDeploymentText $a.Deployments }
    }
    $col = if ($failN) { '#FFB74D' } else { '#81C784' }
    Add-HURtbLine $script:Controls['rtbApps'] "Ergebnis: $okN Tenant(s) ok$(if ($failN) { ", $failN mit Fehler" })$(if ($okN -and -not $script:AppJobRelease) { ' - Geraete holen die App beim naechsten Sync (meist innerhalb 1 Stunde).' })" $col
    Update-HUAppButtons
}

# ----------------------------------------------------------------------------
# Status je Geraet
# ----------------------------------------------------------------------------
function Start-HUAppStatus {
    $a = $script:AppCurrent
    if (-not $a) { return }
    $checked = @(Get-HUCheckedTenants $script:Controls['spAppTenants'])
    $deps = @($a.Deployments | Where-Object { $_.AppId })
    $sel = @($deps | Where-Object { $checked -contains $_.Tenant })
    if (-not $sel.Count) { $sel = $deps }
    $map = @{}; foreach ($d in $sel) { $map[$d.Tenant] = $d.AppId }
    $script:AppJobApp = $a.Id
    Add-HURtbLine $script:Controls['rtbApps'] "=== Status: $($a.Name) - Intune erstellt den Bericht, das dauert etwas ===" '#4FC3F7'
    [void](Start-HUJob -Name 'Apps' -Output $script:Controls['rtbApps'] -Vars @{ Map = $map } -Code {
            foreach ($tk in $Map.Keys) {
                try {
                    Write-HULog -Message 'Lese Installationsstatus ...' -Level 'INFO' -Tenant $tk
                    $rows = @(Get-HUAppInstallStatus -TenantKey $tk -Settings $Settings -AppId $Map[$tk])
                    $grp = @($rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
                    Write-HULog -Message "$($rows.Count) Geraet(e)$(if ($grp) { ": $grp" })" -Level 'OK' -Tenant $tk
                    foreach ($r in $rows) { $o = [ordered]@{ Tenant = $tk }; foreach ($p in $r.PSObject.Properties) { $o[$p.Name] = $p.Value }; [pscustomobject]$o }
                } catch { Write-HULog -Message $_.Exception.Message -Level 'ERROR' -Tenant $tk }
            }
        } -OnDone {
            param($Result, $Errors)
            $rows = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Geraet'] })
            Update-HUAppButtons
            $app = Get-HUAppById $script:AppJobApp
            if (-not $rows.Count) { Add-HURtbLine $script:Controls['rtbApps'] 'Noch keine Geraetedaten - Intune braucht nach dem Zuweisen oft 1-2 Stunden fuer den ersten Bericht.' '#FFB74D'; return }
            foreach ($r in $rows) { $r.Tenant = Get-HUTenantDisplayName $r.Tenant }
            Show-HUQSTable -Title "Status $(if ($app) { $app.Name })" -Objects $rows -FilePrefix 'App-Status'
        })
    Update-HUAppButtons
}

# ----------------------------------------------------------------------------
# Testinstallation in der Windows Sandbox
# ----------------------------------------------------------------------------
function Show-HUSandboxSetup {
    $caption = ''
    try { $caption = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption)" } catch { }
    if ($caption -match '(?i)\bHome\b') {
        Show-HUMessage "Die Testinstallation laeuft in der Windows Sandbox - die gibt es nicht in '$caption'.`n`nNoetig ist Windows 10/11 Pro, Education oder Enterprise." 'Windows Sandbox' -Icon Warning
        return
    }
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Sandbox einrichten" Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="20">
        <TextBlock Text="&#x1F9EA; Testinstallation braucht die Windows Sandbox" Foreground="#CE93D8" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,10"/>
        <TextBlock TextWrapping="Wrap" Foreground="#CCCCCC" FontSize="12" Margin="0,0,0,10"
                   Text="Die Sandbox ist ein Wegwerf-Windows: das Setup wird dort installiert, HU-MultiTenant liest Erkennung und Deinstallation aus, danach verschwindet alles. Dein PC bleibt sauber."/>
        <TextBlock Text="So geht's" Style="{StaticResource SectionTitle}"/>
        <TextBlock TextWrapping="Wrap" Foreground="#CCCCCC" FontSize="12" LineHeight="20">
            1. Unten auf "Sandbox jetzt aktivieren" klicken und die Windows-Abfrage (Administrator) bestaetigen.<LineBreak/>
            2. Warten, bis das blaue Fenster "Fertig" meldet.<LineBreak/>
            3. Windows neu starten - danach funktioniert die Testinstallation.
        </TextBlock>
        <TextBlock TextWrapping="Wrap" Style="{StaticResource HintText}" Margin="0,10,0,0"
                   Text="Voraussetzungen: Windows 10/11 Pro, Education oder Enterprise und eingeschaltete Virtualisierung im BIOS/UEFI (bei fast allen aktuellen PCs Standard). Klappt es nicht: Systemsteuerung &gt; Windows-Features &gt; 'Windows-Sandbox' anhaken."/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnHelp" Content="Anleitung (Microsoft)" Style="{StaticResource ToolButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnEnable" Content="Sandbox jetzt aktivieren" Background="#6A1B9A" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Schliessen" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $c.btnHelp.Add_Click({ Open-HUUrl 'https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-install' })
    $c.btnEnable.Add_Click({
            try {
                Enable-HUSandbox
                Write-HULogOK 'Windows Sandbox wird aktiviert - danach Windows neu starten.'
                $w.Close()
            } catch { Show-HUMessage "Nicht gestartet (Administrator-Abfrage abgelehnt?):`n$($_.Exception.Message)" -Icon Warning -Owner $w }
        })
    $c.btnCancel.Add_Click({ $w.Close() })
    [void]$w.ShowDialog()
}

function Start-HUAppSandbox {
    Save-HUAppForm
    $a = $script:AppCurrent
    if (-not $a -or $a.Type -ne 'win32') { return }
    Save-HUAppLib
    if (-not $a.SetupPath -or -not (Test-Path -LiteralPath $a.SetupPath)) { Show-HUMessage 'Setup-Datei nicht gefunden.' -Icon Warning; return }
    if (-not $a.InstallCmd) { Show-HUMessage 'Installationsbefehl fehlt.' -Icon Warning; return }
    if (-not (Test-HUSandboxAvailable)) { Show-HUSandboxSetup; return }
    $c = $script:Controls
    $testUn = [bool]$c['chkAppSandboxUninstall'].IsChecked
    if ($testUn -and -not $a.UninstallCmd) { $testUn = $false }
    $script:AppSbStart = @{ AppId = $a.Id; TestUn = $testUn; Uninstall = $a.UninstallCmd }
    $rtb = $c['rtbApps']
    Add-HURtbLine $rtb "=== Testinstallation: $($a.Name) ===" '#CE93D8'
    $c['txtAppSandbox'].Text = 'Sandbox wird vorbereitet ...'
    [void](Start-HUJob -Name 'AppSandbox' -Output $rtb -Vars @{
            Id = $a.Id; SetupPath = $a.SetupPath; WholeFolder = [bool]$a.WholeFolder; InstallCmd = $a.InstallCmd; UninstallCmd = $a.UninstallCmd
            TestUn = $testUn; KeepOpen = [bool]$c['chkAppSandboxKeep'].IsChecked
        } -Code {
            $src = Sync-HUAppSource -SetupPath $SetupPath -WholeFolder $WholeFolder -Destination (Join-Path (Get-HUWorkPath "Packages\$Id") 'src')
            if ($src.Copied) { Write-HULog -Message 'Setup in den lokalen Arbeitsordner kopiert' -Level 'INFO' }
            $res = Start-HUSandboxTest -SourceFolder $src.Folder -WorkFolder (Join-Path (Get-HUWorkPath 'Sandbox') $Id) -InstallCmd $InstallCmd -UninstallCmd $UninstallCmd -TestUninstall:$TestUn -KeepOpen:$KeepOpen
            Write-HULog -Message 'Windows Sandbox gestartet - die Installation laeuft dort sichtbar im eigenen Fenster.' -Level 'OK'
            $res
        } -OnDone {
            param($Result, $Errors)
            $file = "$(@($Result) | Where-Object { $_ } | Select-Object -Last 1)"
            if (@($Errors).Count -or -not $file) { $script:Controls['txtAppSandbox'].Text = 'Sandbox nicht gestartet - siehe Ausgabe.'; Update-HUAppButtons; return }
            Start-HUSandboxWatch $file
        })
    Update-HUAppButtons
}

function Start-HUSandboxWatch([string]$File) {
    $script:AppSbWatch = @{ File = $File; AppId = $script:AppSbStart.AppId; Started = Get-Date; Seen = $false; TestUn = $script:AppSbStart.TestUn }
    if (-not $script:AppSbTimer) {
        $script:AppSbTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:AppSbTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:AppSbTimer.Add_Tick({ Update-HUSandboxWatch })
    }
    $script:AppSbTimer.Start()
    Update-HUAppButtons
}

function Stop-HUSandboxWatch([string]$Text, [string]$Color = '#FFB74D') {
    $script:AppSbTimer.Stop()
    $id = $script:AppSbWatch.AppId
    $script:AppSbWatch = $null
    if ($Text) {
        Add-HURtbLine $script:Controls['rtbApps'] $Text $Color
        if ($script:AppCurrent -and $script:AppCurrent.Id -eq $id) { $script:Controls['txtAppSandbox'].Text = $Text }
    }
    Update-HUAppButtons
}

function Update-HUSandboxWatch {
    $w = $script:AppSbWatch
    if (-not $w) { $script:AppSbTimer.Stop(); return }
    $secs = [int]((Get-Date) - $w.Started).TotalSeconds
    if (Test-Path -LiteralPath $w.File) {
        $res = $null
        try { $res = Get-Content -LiteralPath $w.File -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        if (-not $res) { return }
        Stop-HUSandboxWatch ''
        Show-HUSandboxResult $res $w.AppId $w.TestUn
        return
    }
    $running = [bool](Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession', 'WindowsSandboxServer' -ErrorAction SilentlyContinue)
    if ($running) { $w.Seen = $true }
    if ($w.Seen -and -not $running) { Stop-HUSandboxWatch 'Sandbox wurde ohne Ergebnis geschlossen.'; return }
    if (-not $w.Seen -and $secs -gt 180) { Stop-HUSandboxWatch 'Sandbox startet nicht - laeuft die Virtualisierung? (Task-Manager > Leistung > CPU > Virtualisierung: Aktiviert)'; return }
    if ($secs -gt 3000) { Stop-HUSandboxWatch 'Abbruch nach 50 Minuten ohne Ergebnis - Sandbox bitte von Hand schliessen.'; return }
    if ($script:AppCurrent -and $script:AppCurrent.Id -eq $w.AppId) {
        $script:Controls['txtAppSandbox'].Text = "Sandbox laeuft ($([int]($secs / 60)):$('{0:D2}' -f ($secs % 60))) - Installation im Sandbox-Fenster ..."
    }
}

function Show-HUSandboxResult($Res, [string]$AppId, [bool]$TestUn) {
    $a = Get-HUAppById $AppId
    $rtb = $script:Controls['rtbApps']
    if (-not $a) { return }
    Show-HUWindowFront
    # passende App im Reiter zeigen
    $script:Controls['tabMain'].SelectedItem = $script:Controls['tabApps']
    if (-not $script:AppCurrent -or $script:AppCurrent.Id -ne $a.Id) { Save-HUAppForm; Update-HUAppList $a.Id; Show-HUAppForm $a }
    $code = $Res.ExitCode
    $okCodes = @(0, 1707, 3010, 1641)
    $lines = New-Object System.Collections.Generic.List[string]
    if ("$($Res.Error)") { $lines.Add("Fehler im Testskript: $($Res.Error)") }
    $codeText = switch ($code) {
        -999 { 'Zeitlimit 30 Min. - wartet das Setup auf eine Eingabe? Schalter fuer die stille Installation pruefen.' }
        3010 { 'erfolgreich, Neustart noetig (3010)' }
        1641 { 'erfolgreich, Setup hat Neustart ausgeloest (1641)' }
        0 { 'erfolgreich (0)' }
        default { "Exitcode $code" }
    }
    $ok = ($null -ne $code -and "$code" -match '^-?\d+$' -and $okCodes -contains [int]$code)
    $lines.Add("Installation: $codeText nach $($Res.Seconds) s")
    $entries = @($Res.NewEntries | Where-Object { $_ })
    $lines.Add("Neue Programme in 'Apps & Features': $($entries.Count)$(if ($entries.Count) { ' - ' + (@($entries | Select-Object -First 4 | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)".Trim() }) -join '; ') })")
    if ($Res.UninstallTested) {
        $lines.Add("Deinstallation: $(if ($Res.UninstallRemoved) { 'OK - Eintrag entfernt' } else { 'Eintrag noch vorhanden - Befehl pruefen' }) (Exitcode $($Res.UninstallExitCode))")
    } elseif (-not $TestUn) { $lines.Add('Deinstallation nicht getestet.') }
    foreach ($l in $lines) { Add-HURtbLine $rtb $l $(if ($ok) { '#CCCCCC' } else { '#FFB74D' }) }
    $a.SandboxNote = "Sandbox $(Get-Date -Format 'dd.MM. HH:mm'): " + ($lines -join ' | ')

    # Vorschlag fuer Erkennung und Deinstallation
    $prop = $null
    $e = Select-HUSandboxEntry -Entries $entries -AppName $a.Name
    if ($e) { $prop = ConvertFrom-HUSandboxEntry $e -InstallerType "$($a.InstallerType)" }
    $iconSrc = ''
    if ($prop -and $prop.IconFile) { $f = Join-Path (Join-Path (Get-HUWorkPath 'Sandbox') $AppId) $prop.IconFile; if (Test-Path -LiteralPath $f) { $iconSrc = $f } }
    $folders = @($Res.NewFolders | Where-Object { $_ -match '(?i)\\Program Files' })
    if ($ok -and ($prop -or $folders.Count)) {
        $msg = "Testinstallation $codeText.`n`nVorschlag:`n"
        if ($prop) {
            $det = $prop.Detection
            $msg += "  Erkennung: $(if ($det.Type -eq 'msi') { "MSI-Produktcode $($det.ProductCode)" } else { "Registry $($det.KeyPath)" })$(if ($det.VersionCheck) { ", Version >= $($det.Version)" })`n"
            if ($prop.UninstallCmd) { $msg += "  Deinstallation: $($prop.UninstallCmd)`n" }
            if ($prop.HKCU) { $msg += "`n  Achtung: die App installiert sich nur fuer den Benutzer - 'Ausfuehren als: Benutzer' waehlen.`n" }
            if ($iconSrc) { $msg += "  Symbol: aus der installierten App`n" }
        } else {
            $f = $folders[0]
            $msg += "  Erkennung: Ordner $f vorhanden (kein Eintrag in 'Apps & Features' gefunden)`n"
        }
        $msg += "`nUebernehmen?"
        if (Confirm-HU $msg 'Testinstallation') {
            if ($prop) {
                $a.Detection = New-HUAppDetection $prop.Detection
                if ($prop.UninstallCmd -and ($a.Kind -ne 'msi' -or -not $a.UninstallCmd)) { $a.UninstallCmd = $prop.UninstallCmd }
                if (-not $a.Version -and $prop.Version) { $a.Version = $prop.Version }
                if (-not $a.Publisher -and $prop.Publisher) { $a.Publisher = $prop.Publisher }
                if ($prop.HKCU) { $a.RunAs = 'user' }
                if ($iconSrc) { [void](Set-HUAppIcon $a $iconSrc -Quiet) }
            } else {
                $a.Detection = New-HUAppDetection ([pscustomobject]@{ Type = 'file'; Path = (Split-Path $folders[0] -Parent); FileName = (Split-Path $folders[0] -Leaf) })
            }
            Add-HURtbLine $rtb 'Vorschlag uebernommen.' '#81C784'
            if ($prop -and $prop.UninstallCmd -and -not $Res.UninstallTested) { Add-HURtbLine $rtb 'Tipp: Testinstallation noch einmal starten, um die Deinstallation mitzutesten.' '#90CAF9' }
        }
    } elseif (-not $ok) {
        Add-HURtbLine $rtb 'Installation nicht erfolgreich - Befehl/Schalter pruefen. "Sandbox offen lassen" anhaken, um im Sandbox-Fenster nachzusehen.' '#FFB74D'
    } else {
        Add-HURtbLine $rtb 'Keine Aenderung gefunden, aus der sich eine Erkennung ableiten laesst - Erkennung bitte selbst festlegen.' '#FFB74D'
    }
    Save-HUAppLib
    if ($script:AppCurrent -and $script:AppCurrent.Id -eq $a.Id) { Show-HUAppForm $a }
}

# ----------------------------------------------------------------------------
# Ereignisse
# ----------------------------------------------------------------------------
function Register-HUAppHandlers {
    $c = $script:Controls
    $c['lstApps'].Add_SelectionChanged({
            if ($script:AppLoading) { return }
            $it = $script:Controls['lstApps'].SelectedItem
            if ($it) { Select-HUApp $it.Id }
        })
    $c['lstApps'].Add_DragOver({ param($s, $e) $e.Effects = $(if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { 'Copy' } else { 'None' }); $e.Handled = $true })
    $c['lstApps'].Add_Drop({
            param($s, $e)
            foreach ($f in @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))) { Add-HUAppFromFile "$f" }
        })
    $c['btnAppAdd'].Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Setup (*.msi;*.exe)|*.msi;*.exe'
            $dlg.Title = 'Setup-Datei waehlen'
            if ($dlg.ShowDialog($script:Window)) { Add-HUAppFromFile $dlg.FileName }
        })
    $c['btnAppBrowse'].Add_Click({
            $a = $script:AppCurrent
            if (-not $a) { return }
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Setup (*.msi;*.exe)|*.msi;*.exe'
            if ($a.SetupPath) { $dir = Split-Path $a.SetupPath -Parent; if (Test-Path -LiteralPath $dir) { $dlg.InitialDirectory = $dir } }
            if ($dlg.ShowDialog($script:Window)) { Add-HUAppFromFile $dlg.FileName }
        })
    $c['btnAppAddStore'].Add_Click({ Add-HUAppStore })
    $c['btnAppGroupPick'].Add_Click({
            $c = $script:Controls
            $n = Show-HUGroupPicker -TenantKeys @(Get-HUCheckedTenants $c['spAppTenants']) -Current $c['txtAppGroup'].Text.Trim() -Title 'Zielgruppe waehlen'
            if ($n) { [void](Select-HUComboTag $c['cmbAppTarget'] 'group'); $c['txtAppGroup'].Text = $n; Update-HUAppTargetUi }
        })
    $c['btnAppPilotPick'].Add_Click({
            $c = $script:Controls
            $n = Show-HUGroupPicker -TenantKeys @(Get-HUCheckedTenants $c['spAppTenants']) -Current $c['txtAppPilot'].Text.Trim() -Title 'Pilotgruppe waehlen'
            if ($n) { $c['chkAppPilot'].IsChecked = $true; $c['txtAppPilot'].Text = $n; Update-HUAppTargetUi }
        })
    $c['btnAppIcon'].Add_Click({
            $a = $script:AppCurrent
            if (-not $a) { return }
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Bild, Symbol oder Programm|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.ico;*.exe;*.dll|Alle Dateien|*.*'
            $dlg.Title = 'Symbol fuer das Unternehmensportal'
            if ($a.SetupPath) { $dir = Split-Path $a.SetupPath -Parent; if (Test-Path -LiteralPath $dir) { $dlg.InitialDirectory = $dir } }
            if ($dlg.ShowDialog($script:Window)) { if (Set-HUAppIcon $a $dlg.FileName) { Add-HURtbLine $script:Controls['rtbApps'] "Symbol uebernommen - wird beim naechsten Hochladen gesetzt." '#81C784' } }
        })
    $c['btnAppIconClear'].Add_Click({
            $a = $script:AppCurrent
            if (-not $a) { return }
            Remove-Item -LiteralPath (Get-HUAppIconPath $a) -Force -ErrorAction SilentlyContinue
            Update-HUAppIconView
        })
    $c['btnAppRemove'].Add_Click({ Remove-HUAppCurrent })
    $c['btnAppStoreOpen'].Add_Click({
            $q = $script:Controls['txtAppName'].Text.Trim()
            if (-not $q -or $q -eq 'Neue Store-App') { Open-HUUrl 'https://apps.microsoft.com/' } else { Open-HUUrl "https://apps.microsoft.com/search?query=$([uri]::EscapeDataString($q))" }
        })
    $c['txtAppStoreId'].Add_LostFocus({ if (-not $script:AppLoading) { Update-HUAppStoreInfo } })
    $c['cmbAppDetType'].Add_SelectionChanged({
            if ($script:AppLoading -or -not $script:AppCurrent) { return }
            Write-HUAppDetFields
            $script:AppDetType = Get-HUComboTag $script:Controls['cmbAppDetType']
            $script:AppCurrent.Detection.Type = $script:AppDetType
            $script:AppLoading = $true
            try { Read-HUAppDetFields } finally { $script:AppLoading = $false }
            Update-HUAppDetUi
        })
    $c['cmbAppTarget'].Add_SelectionChanged({ Update-HUAppTargetUi })
    $c['chkAppPilot'].Add_Checked({ Update-HUAppTargetUi })
    $c['chkAppPilot'].Add_Unchecked({ Update-HUAppTargetUi })
    $c['txtAppName'].Add_LostFocus({ if (-not $script:AppLoading -and $script:AppCurrent) { Save-HUAppForm; Update-HUAppList } })
    $c['btnAppSave'].Add_Click({ Save-HUAppForm; Save-HUAppLib; Update-HUAppList; Add-HURtbLine $script:Controls['rtbApps'] "Gespeichert: $($script:AppCurrent.Name)" '#81C784' })
    $c['btnAppDeploy'].Add_Click({ Start-HUAppDeploy })
    $c['btnAppRelease'].Add_Click({ Start-HUAppDeploy -Release })
    $c['btnAppStatus'].Add_Click({ Start-HUAppStatus })
    $c['btnAppSandbox'].Add_Click({ Start-HUAppSandbox })
    $c['btnAppPackages'].Add_Click({ Open-HUPath (Get-HUWorkPath 'Packages') })
    Add-HUOutputMenu $c['rtbApps'] { $script:Controls['rtbApps'].Document.Blocks.Clear() }
}

function Initialize-HUApps {
    Import-HUAppLib
    Update-HUAppTenantChecks
    Update-HUAppList
    Show-HUAppForm $null
}

function Close-HUApps {
    Save-HUAppForm
    if ($script:AppLib.Count -or (Test-Path -LiteralPath (Get-HUAppLibPath))) { Save-HUAppLib }
}
