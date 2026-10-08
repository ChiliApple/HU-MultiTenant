#Requires -Version 5.1
<#
.SYNOPSIS
    Intune per Microsoft Graph: Win32-Apps (MSI/EXE) paketieren, hochladen, zuweisen und auswerten,
    Microsoft-Store-Apps (neu), Wartungsskripte (Remediations), Testinstallation in der Windows Sandbox.
.DESCRIPTION
    Alle Graph-Aufrufe holen das Token je Aufruf ueber Get-GraphToken (Cache bis kurz vor Ablauf) - lange
    Uploads brechen dadurch nicht mit 401 ab. Fehler werden als Ausnahme geworfen (Klartext).
    Endpunkte: deviceAppManagement/mobileApps (beta), deviceManagement/deviceHealthScripts (beta),
    deviceManagement/reports/exportJobs (beta).
    Quellen: learn.microsoft.com/graph/api/resources/intune-apps-win32lobapp
             learn.microsoft.com/graph/api/intune-apps-mobileappcontentfile-commit
             learn.microsoft.com/graph/api/intune-devices-devicehealthscript-create?view=graph-rest-beta
             learn.microsoft.com/intune/device-management/reports/export-graph-apis
             learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file
.NOTES
    Benoetigt HU.Auth (Get-GraphToken) und HU.Logging (Write-HULog).
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

$script:ChunkSize = 6MB
$script:RenewAfterMinutes = 7

# ============================================================================
# Graph-Hilfen
# ============================================================================
function Invoke-HUIntuneGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantKey,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [hashtable]$Body,
        [switch]$V1
    )
    for ($try = 1; $try -le 4; $try++) {
        $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop
        if (-not $tok) { throw "Kein Token fuer '$TenantKey' (Secret pruefen)" }
        $ver = if ($V1) { 'v1.0' } else { 'beta' }
        $r = Invoke-HUGraphRaw -Token $tok -Endpoint $Endpoint -Method $Method -Body $Body -Version $ver
        if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
            if ($r.StatusCode -in 429, 500, 502, 503, 504 -and $try -lt 4) { Start-Sleep -Seconds (5 * $try); continue }
            throw "Graph $Method $($Endpoint -replace '\?.*$', ''): $($r.ErrorMessage)"
        }
        return $r
    }
}

# Eigener Aufruf statt Invoke-GraphRequest: Body als UTF-8-Bytes (PS 5.1 schickt Text sonst als ISO-8859-1 - Umlaute
# in Namen/Beschreibungen kaemen kaputt an), Fehler als Objekt wie HU.Graph.
function Invoke-HUGraphRaw {
    param([string]$Token, [string]$Endpoint, [string]$Method = 'GET', [hashtable]$Body, [string]$Version = 'beta')
    $uri = if ($Endpoint.StartsWith('https://')) { $Endpoint } else { "https://graph.microsoft.com/$Version/$($Endpoint.TrimStart('/'))" }
    $p = @{ Uri = $uri; Method = $Method; Headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }; ErrorAction = 'Stop'; UseBasicParsing = $true }
    if ($Method -in 'POST', 'PATCH') {
        $json = if ($Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '{}' }
        $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try { return (Invoke-RestMethod @p) }
    catch {
        $code = $null; $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $j = $sr.ReadToEnd() | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($j.error.message) { $msg = "$code - $($j.error.code): $($j.error.message)" }
            } catch { }
        }
        return [pscustomobject]@{ IsError = $true; StatusCode = $code; ErrorMessage = $msg; Endpoint = $Endpoint; Method = $Method }
    }
}

function Get-HUIntuneGraphAll {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Endpoint, [switch]$V1)
    $out = New-Object System.Collections.Generic.List[object]
    $next = $Endpoint
    $n = 0
    while ($next -and $n -lt 200) {
        $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $next -V1:$V1
        foreach ($v in @($r.value)) { if ($null -ne $v) { $out.Add($v) } }
        $next = $r.'@odata.nextLink'
        $n++
    }
    return , $out.ToArray()
}

function ConvertTo-HUBase64Utf8([string]$Text) {
    # Intune-Skripte: UTF-8 ohne BOM (Pflicht bei Signaturpruefung, sonst unschaedlich)
    return [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding $false).GetBytes("$Text"))
}

function Find-HUGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $f = [uri]::EscapeDataString("displayName eq '$($Name.Replace("'", "''"))'")
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/groups?`$filter=$f&`$select=id,displayName" -V1
    return (@($r.value) | Select-Object -First 1)
}

# Gruppen eines Tenants, die Intune zuweisen kann (Sicherheits- und Microsoft-365-Gruppen)
function ConvertTo-HUGroupRow($G) {
    $types = @($G.groupTypes)
    $unified = $types -contains 'Unified'
    if (-not $unified -and -not $G.securityEnabled) { return $null }
    $t = if ($unified) { 'Microsoft 365' } else { 'Sicherheit' }
    if ($types -contains 'DynamicMembership') { $t += ' (dynamisch)' }
    return [pscustomobject]@{ Name = "$($G.displayName)"; Typ = $t; Id = "$($G.id)" }
}

function Get-HUTenantGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $all = Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/groups?$select=id,displayName,groupTypes,securityEnabled,mailEnabled&$top=999' -V1
    foreach ($g in $all) { $r = ConvertTo-HUGroupRow $g; if ($r -and $r.Name) { $r } }
}

# Win32-Apps eines Tenants (fuer Abhaengigkeiten aus Intune)
function ConvertTo-HUW32Row($A) {
    return [pscustomobject]@{ Name = "$($A.displayName)"; Version = "$($A.displayVersion)"; Publisher = "$($A.publisher)"; Id = "$($A.id)"; Modified = "$($A.lastModifiedDateTime)" }
}

function Get-HUTenantWin32Apps {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $f = [uri]::EscapeDataString("isof('microsoft.graph.win32LobApp')")
    $all = Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps?`$filter=$f"
    foreach ($a in $all) { if ("$($a.'@odata.type')" -match 'win32LobApp' -and "$($a.displayName)") { ConvertTo-HUW32Row $a } }
}

# Win32-App per Anzeigename; bei mehreren gleichen Namens die zuletzt geaenderte
function Find-HUWin32AppByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $hits = @(Get-HUTenantWin32Apps -TenantKey $TenantKey -Settings $Settings | Where-Object { $_.Name -eq $Name })
    if ($hits.Count -gt 1) { Write-HULog -Message "'$Name' gibt es $($hits.Count)-mal - verwendet wird die zuletzt geaenderte" -Level 'WARN' -Tenant $TenantKey }
    return (@($hits | Sort-Object { try { [datetime]$_.Modified } catch { [datetime]::MinValue } } -Descending) | Select-Object -First 1)
}

function Find-HUManagedDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $f = [uri]::EscapeDataString("deviceName eq '$($Name.Replace("'", "''"))'")
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=$f&`$select=id,deviceName,userPrincipalName,lastSyncDateTime" -V1
    return @($r.value)
}

# ============================================================================
# Setup-Dateien lesen (MSI/EXE) - Vorschlaege fuer Befehle und Erkennung
# ============================================================================
function Read-HUMsiInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $installer = $null; $db = $null
    $info = [ordered]@{}
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        foreach ($prop in 'ProductName', 'Manufacturer', 'ProductVersion', 'ProductCode', 'UpgradeCode') {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property = '$prop'"))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            $info[$prop] = if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) } else { '' }
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        }
    } finally {
        if ($db) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
        if ($installer) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
    return [pscustomobject]$info
}

# Installer-Typ einer EXE an typischen Kennungen erkennen (Hersteller-Schalter fuer stille Installation)
function Get-HUExeInstallerType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $max = 24MB
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $len = [int][Math]::Min($fs.Length, $max)
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
    } finally { $fs.Dispose() }
    $txt = [System.Text.Encoding]::GetEncoding(28591).GetString($buf)
    $types = @(
        @{ Type = 'Inno Setup'; Pattern = 'Inno Setup'; Silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
        @{ Type = 'NSIS'; Pattern = 'Nullsoft'; Silent = '/S' }
        @{ Type = 'WiX Burn'; Pattern = '.wixburn'; Silent = '/quiet /norestart' }
        @{ Type = 'InstallShield'; Pattern = 'InstallShield'; Silent = '/s /v"/qn REBOOT=ReallySuppress"' }
        @{ Type = 'Advanced Installer'; Pattern = 'Advanced Installer'; Silent = '/exenoui /qn /norestart' }
        @{ Type = 'Squirrel'; Pattern = 'Squirrel'; Silent = '--silent' }
    )
    foreach ($t in $types) { if ($txt.IndexOf($t.Pattern, [StringComparison]::Ordinal) -ge 0) { return [pscustomobject]$t } }
    return [pscustomobject]@{ Type = 'unbekannt'; Pattern = ''; Silent = '' }
}

function Get-HUSetupInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $name = $file.Name
    if ($file.Extension -ieq '.msi') {
        $m = Read-HUMsiInfo -Path $file.FullName
        return [pscustomobject]@{
            Kind = 'msi'; FileName = $name; Name = "$($m.ProductName)"; Publisher = "$($m.Manufacturer)"; Version = "$($m.ProductVersion)"
            ProductCode = "$($m.ProductCode)"; UpgradeCode = "$($m.UpgradeCode)"; InstallerType = 'MSI'
            InstallCmd = "msiexec /i `"$name`" /qn /norestart"
            UninstallCmd = $(if ($m.ProductCode) { "msiexec /x $($m.ProductCode) /qn /norestart" } else { '' })
            Detection = [pscustomobject]@{ Type = 'msi'; ProductCode = "$($m.ProductCode)"; Version = "$($m.ProductVersion)"; VersionCheck = $true }
            Hint = 'Befehle und Erkennung aus der MSI gelesen.'
        }
    }
    $vi = $file.VersionInfo
    $t = Get-HUExeInstallerType -Path $file.FullName
    $ver = "$($vi.ProductVersion)".Trim(); if (-not $ver) { $ver = "$($vi.FileVersion)".Trim() }
    return [pscustomobject]@{
        Kind = 'exe'; FileName = $name
        Name = $(if ("$($vi.ProductName)".Trim()) { "$($vi.ProductName)".Trim() } else { [IO.Path]::GetFileNameWithoutExtension($name) })
        Publisher = "$($vi.CompanyName)".Trim(); Version = $ver; ProductCode = ''; UpgradeCode = ''; InstallerType = $t.Type
        InstallCmd = $(if ($t.Silent) { "`"$name`" $($t.Silent)" } else { "`"$name`" " })
        UninstallCmd = ''
        Detection = $null
        Hint = $(if ($t.Silent) { "Installer erkannt: $($t.Type). Erkennung und Deinstallation am besten per Testinstallation in der Sandbox ermitteln." }
            else { 'Installer-Typ nicht erkannt - Schalter fuer stille Installation beim Hersteller nachsehen (oft /S, /silent, /quiet), dann Testinstallation in der Sandbox.' })
    }
}

# ============================================================================
# Paket (.intunewin) mit dem Microsoft Win32 Content Prep Tool
#   Das Tool darf laut Microsoft-Lizenz nicht mitgeliefert werden - es wird auf Wunsch von
#   github.com/microsoft/Microsoft-Win32-Content-Prep-Tool geladen und die Signatur geprueft.
# ============================================================================
function Get-HUIntuneWinAppUtil {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [switch]$Download)
    $exe = Join-Path $AppRoot 'Tools\IntuneWinAppUtil.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    if (-not $Download) { return $null }
    $dir = Split-Path $exe -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $tmp = "$exe.download"
    Invoke-WebRequest -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe' -OutFile $tmp -UseBasicParsing -Headers @{ 'User-Agent' = 'HU-MultiTenant' }
    $sig = Get-AuthenticodeSignature -LiteralPath $tmp
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'O=Microsoft Corporation') {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "IntuneWinAppUtil.exe: Signatur ungueltig ($($sig.Status)) - Datei verworfen"
    }
    Move-Item -LiteralPath $tmp -Destination $exe -Force
    return $exe
}

function New-HUIntuneWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolPath,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$OutputFolder
    )
    if (-not (Test-Path -LiteralPath (Join-Path $SourceFolder $SetupFile))) { throw "Setup-Datei fehlt im Quellordner: $SetupFile" }
    if (Test-Path -LiteralPath $OutputFolder) { Remove-Item -LiteralPath $OutputFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ToolPath
    $psi.Arguments = "-c `"$SourceFolder`" -s `"$SetupFile`" -o `"$OutputFolder`" -q"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $so = $proc.StandardOutput.ReadToEndAsync(); $se = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "IntuneWinAppUtil.exe Fehler $($proc.ExitCode): $($se.Result) $($so.Result)".Trim() }
    $pkg = Get-ChildItem -LiteralPath $OutputFolder -Filter '*.intunewin' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $pkg) { throw 'Keine .intunewin-Datei erzeugt' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ex = Join-Path $OutputFolder '_extract'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($pkg.FullName, $ex)
    $detFile = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'Detection.xml' | Select-Object -First 1
    $encFile = Get-ChildItem -LiteralPath $ex -Recurse -Filter 'IntunePackage.intunewin' | Select-Object -First 1
    if (-not $detFile -or -not $encFile) { throw '.intunewin unvollstaendig (Detection.xml oder IntunePackage.intunewin fehlt)' }
    [xml]$xml = Get-Content -LiteralPath $detFile.FullName -Raw -Encoding UTF8
    $ai = $xml.ApplicationInfo
    $e = $ai.EncryptionInfo
    $upload = Join-Path $OutputFolder 'upload.bin'
    Move-Item -LiteralPath $encFile.FullName -Destination $upload -Force
    Remove-Item -LiteralPath $ex -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        IntuneWinFile   = $pkg.FullName
        IntuneWinName   = $pkg.Name
        UploadFile      = $upload
        UnencryptedSize = [long]$ai.UnencryptedContentSize
        EncryptedSize   = (Get-Item -LiteralPath $upload).Length
        EncryptionInfo  = @{
            '@odata.type'        = '#microsoft.graph.fileEncryptionInfo'
            encryptionKey        = "$($e.EncryptionKey)"
            macKey               = "$($e.MacKey)"
            initializationVector = "$($e.InitializationVector)"
            mac                  = "$($e.Mac)"
            profileIdentifier    = "$($e.ProfileIdentifier)"
            fileDigest           = "$($e.FileDigest)"
            fileDigestAlgorithm  = "$($e.FileDigestAlgorithm)"
        }
        MsiProductCode  = "$($ai.MsiInfo.MsiProductCode)"
        MsiVersion      = "$($ai.MsiInfo.MsiProductVersion)"
    }
}

# ============================================================================
# Win32-App: Daten -> Graph
#   Def: Name, Publisher, Description, Version, SetupFile, InstallCmd, UninstallCmd, RunAs (system|user),
#        Restart (suppress|basedOnReturnCode|allow|force), Detection (Type msi|registry|file|script ...), Kind (msi|exe)
# ============================================================================
function Get-HUDefaultReturnCodes {
    return @(
        @{ returnCode = 0; type = 'success' }
        @{ returnCode = 1707; type = 'success' }
        @{ returnCode = 3010; type = 'softReboot' }
        @{ returnCode = 1641; type = 'hardReboot' }
        @{ returnCode = 1618; type = 'retry' }
    )
}

function ConvertTo-HUDetectionRule($Det) {
    if (-not $Det -or -not "$($Det.Type)") { throw 'Keine Erkennungsregel festgelegt' }
    $check = $false
    if ($Det.PSObject.Properties['Check32']) { $check = [bool]$Det.Check32 }
    $vc = $false
    if ($Det.PSObject.Properties['VersionCheck']) { $vc = [bool]$Det.VersionCheck -and "$($Det.Version)" }
    switch ("$($Det.Type)") {
        'msi' {
            if ("$($Det.ProductCode)" -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "MSI-Produktcode ungueltig: '$($Det.ProductCode)'" }
            return @{
                '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'
                productCode = "$($Det.ProductCode)"
                productVersionOperator = $(if ($vc) { 'greaterThanOrEqual' } else { 'notConfigured' })
                productVersion = $(if ($vc) { "$($Det.Version)" } else { $null })
            }
        }
        'registry' {
            if (-not "$($Det.KeyPath)") { throw 'Registry-Erkennung: Schluessel fehlt' }
            $useVer = $vc -and "$($Det.ValueName)"
            return @{
                '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'detection'
                check32BitOn64System = $check; keyPath = "$($Det.KeyPath)"
                valueName = $(if ("$($Det.ValueName)") { "$($Det.ValueName)" } else { $null })
                operationType = $(if ($useVer) { 'version' } else { 'exists' })
                operator = $(if ($useVer) { 'greaterThanOrEqual' } else { 'notConfigured' })
                comparisonValue = $(if ($useVer) { "$($Det.Version)" } else { $null })
            }
        }
        'file' {
            if (-not "$($Det.Path)" -or -not "$($Det.FileName)") { throw 'Datei-Erkennung: Ordner und Datei angeben' }
            return @{
                '@odata.type' = '#microsoft.graph.win32LobAppFileSystemRule'; ruleType = 'detection'
                check32BitOn64System = $check; path = "$($Det.Path)"; fileOrFolderName = "$($Det.FileName)"
                operationType = $(if ($vc) { 'version' } else { 'exists' })
                operator = $(if ($vc) { 'greaterThanOrEqual' } else { 'notConfigured' })
                comparisonValue = $(if ($vc) { "$($Det.Version)" } else { $null })
            }
        }
        'script' {
            if (-not "$($Det.Script)".Trim()) { throw 'Skript-Erkennung: Skript fehlt' }
            return @{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'
                displayName = $null; enforceSignatureCheck = $false; runAs32Bit = $false; runAsAccount = $null
                scriptContent = (ConvertTo-HUBase64Utf8 "$($Det.Script)")
                operationType = 'notConfigured'; operator = 'notConfigured'; comparisonValue = $null
            }
        }
        default { throw "Unbekannte Erkennungsart: $($Det.Type)" }
    }
}

function ConvertTo-HUWin32Payload($Def, [string]$IntuneWinName = '') {
    foreach ($k in 'Name', 'InstallCmd', 'UninstallCmd', 'SetupFile') { if (-not "$($Def.$k)".Trim()) { throw "Feld fehlt: $k" } }
    $p = @{
        '@odata.type'                  = '#microsoft.graph.win32LobApp'
        displayName                    = "$($Def.Name)"
        description                    = $(if ("$($Def.Description)".Trim()) { "$($Def.Description)" } else { "$($Def.Name)" })
        publisher                      = $(if ("$($Def.Publisher)".Trim()) { "$($Def.Publisher)" } else { '-' })
        displayVersion                 = "$($Def.Version)"
        installCommandLine             = "$($Def.InstallCmd)"
        uninstallCommandLine           = "$($Def.UninstallCmd)"
        setupFilePath                  = "$($Def.SetupFile)"
        installExperience              = @{
            '@odata.type'         = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount          = $(if ("$($Def.RunAs)" -eq 'user') { 'user' } else { 'system' })
            deviceRestartBehavior = $(if ("$($Def.Restart)") { "$($Def.Restart)" } else { 'suppress' })
        }
        returnCodes                    = @(Get-HUDefaultReturnCodes)
        rules                          = @(ConvertTo-HUDetectionRule $Def.Detection)
        applicableArchitectures        = 'x64'
        minimumSupportedWindowsRelease = '1903'
    }
    if ($IntuneWinName) { $p.fileName = $IntuneWinName }
    if ($Def.PSObject.Properties['IconFile']) { $ic = Get-HUIconContent "$($Def.IconFile)"; if ($ic) { $p.largeIcon = $ic } }
    if ("$($Def.Kind)" -eq 'msi' -and "$($Def.Detection.ProductCode)") {
        $p.msiInformation = @{
            '@odata.type' = '#microsoft.graph.win32LobAppMsiInformation'
            productCode = "$($Def.Detection.ProductCode)"; productVersion = "$($Def.Version)"
            upgradeCode = $(if ("$($Def.UpgradeCode)") { "$($Def.UpgradeCode)" } else { $null })
            requiresReboot = $false; packageType = 'perMachine'; productName = "$($Def.Name)"; publisher = "$($Def.Publisher)"
        }
    }
    return $p
}

function Get-HUIntuneApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    try { return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId") }
    catch { if ("$($_.Exception.Message)" -match '404|NotFound|ResourceNotFound') { return $null }; throw }
}

function New-HUWin32App {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Def, [string]$IntuneWinName = '')
    $body = ConvertTo-HUWin32Payload $Def $IntuneWinName
    return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceAppManagement/mobileApps' -Method POST -Body $body)
}

function Update-HUWin32App {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)]$Def, [string]$IntuneWinName = '')
    $body = ConvertTo-HUWin32Payload $Def $IntuneWinName
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId" -Method PATCH -Body $body)
}

# Inhalt hochladen: contentVersion -> file -> Azure-Blob (Bloecke) -> commit -> committedContentVersion
function Publish-HUWin32Content {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)]$Package)
    $base = "/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions"
    $cv = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $base -Method POST -Body @{}
    $fbase = "$base/$($cv.id)/files"
    $f = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $fbase -Method POST -Body @{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'; name = "$($Package.IntuneWinName)"
        size = [long]$Package.UnencryptedSize; sizeEncrypted = [long]$Package.EncryptedSize; manifest = $null; isDependency = $false
    }
    $furl = "$fbase/$($f.id)"
    $file = Wait-HUContentFileState -TenantKey $TenantKey -Settings $Settings -Url $furl -Wanted 'azureStorageUriRequestSuccess' -Fail 'azureStorageUriRequestFailed', 'azureStorageUriRequestTimedOut'

    # --- Bloecke an Azure Storage (Datei wird gestreamt, nicht komplett in den Speicher geladen)
    $sas = "$($file.azureStorageUri)"
    $sasTime = Get-Date
    $total = (Get-Item -LiteralPath $Package.UploadFile).Length
    $count = [int][Math]::Ceiling($total / $script:ChunkSize)
    $ids = New-Object System.Collections.Generic.List[string]
    $fs = [System.IO.File]::OpenRead($Package.UploadFile)
    try {
        $buf = New-Object byte[] $script:ChunkSize
        for ($i = 0; $i -lt $count; $i++) {
            if (((Get-Date) - $sasTime).TotalMinutes -ge $script:RenewAfterMinutes) {
                [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$furl/renewUpload" -Method POST -Body @{})
                $file = Wait-HUContentFileState -TenantKey $TenantKey -Settings $Settings -Url $furl -Wanted 'azureStorageUriRenewalSuccess' -Fail 'azureStorageUriRenewalFailed', 'azureStorageUriRenewalTimedOut'
                $sas = "$($file.azureStorageUri)"; $sasTime = Get-Date
            }
            $read = $fs.Read($buf, 0, $script:ChunkSize)
            $id = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('block{0:D6}' -f $i)))
            $ids.Add($id)
            $ok = $false; $last = ''
            for ($t = 1; $t -le 4 -and -not $ok; $t++) {
                try { Send-HUBlobBytes -Uri "$sas&comp=block&blockid=$([uri]::EscapeDataString($id))" -Bytes $buf -Length $read -BlockBlob; $ok = $true }
                catch { $last = $_.Exception.Message; Start-Sleep -Seconds (3 * $t) }
            }
            if (-not $ok) { throw "Upload Block $($i + 1)/$count fehlgeschlagen: $last" }
            if ($count -gt 1 -and (($i + 1) % 10 -eq 0 -or $i + 1 -eq $count)) {
                Write-HULog -Message ("Hochgeladen: {0:N0} von {1:N0} MB" -f ([Math]::Min(($i + 1) * $script:ChunkSize, $total) / 1MB), ($total / 1MB)) -Level 'INFO' -Tenant $TenantKey
            }
        }
    } finally { $fs.Dispose() }
    $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    $xb = [Text.Encoding]::UTF8.GetBytes($xml)
    Send-HUBlobBytes -Uri "$sas&comp=blocklist" -Bytes $xb -Length $xb.Length -ContentType 'application/xml'

    # --- abschliessen
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$furl/commit" -Method POST -Body @{ fileEncryptionInfo = $Package.EncryptionInfo })
    [void](Wait-HUContentFileState -TenantKey $TenantKey -Settings $Settings -Url $furl -Wanted 'commitFileSuccess' -Fail 'commitFileFailed', 'commitFileTimedOut' -MaxSeconds 900)
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId" -Method PATCH -Body @{
            '@odata.type' = '#microsoft.graph.win32LobApp'; committedContentVersion = "$($cv.id)"
        })
    return "$($cv.id)"
}

function Wait-HUContentFileState {
    param([string]$TenantKey, $Settings, [string]$Url, [string]$Wanted, [string[]]$Fail, [int]$MaxSeconds = 300)
    $start = Get-Date
    while ($true) {
        $f = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $Url
        $s = "$($f.uploadState)"
        if ($s -eq $Wanted) { return $f }
        if ($Fail -contains $s) { throw "Intune meldet beim Hochladen: $s" }
        if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds) { throw "Zeitueberschreitung beim Hochladen (Status: $s)" }
        Start-Sleep -Seconds 3
    }
}

function Send-HUBlobBytes {
    param([string]$Uri, [byte[]]$Bytes, [int]$Length, [switch]$BlockBlob, [string]$ContentType = '')
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = 'PUT'
    $req.Timeout = 300000
    $req.ReadWriteTimeout = 300000
    if ($BlockBlob) { $req.Headers.Add('x-ms-blob-type', 'BlockBlob') }
    if ($ContentType) { $req.ContentType = $ContentType }
    $req.ContentLength = $Length
    $st = $req.GetRequestStream()
    try { $st.Write($Bytes, 0, $Length) } finally { $st.Close() }
    $resp = $req.GetResponse()
    $resp.Close()
}

# ============================================================================
# Lokaler Arbeitsbereich (nicht im Programmordner - der liegt oft in OneDrive)
# ============================================================================
function Get-HUWorkPath([string]$Sub = '') {
    $base = Join-Path $env:LOCALAPPDATA 'HU-MultiTenant'
    $p = if ($Sub) { Join-Path $base $Sub } else { $base }
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

# Setup-Datei (oder ganzen Ordner) in einen lokalen Quellordner spiegeln. Kennung aus Pfad/Groesse/Zeit:
# unveraendert -> nichts kopieren. Liefert @{ Folder; SetupFile; Signature }.
function Sync-HUAppSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SetupPath, [bool]$WholeFolder = $false, [Parameter(Mandatory)][string]$Destination, [hashtable]$Extra = @{})
    if (-not (Test-Path -LiteralPath $SetupPath)) { throw "Setup-Datei nicht gefunden: $SetupPath" }
    $setup = Get-Item -LiteralPath $SetupPath
    $dir = $setup.DirectoryName
    $files = if ($WholeFolder) { @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force) } else { @($setup) }
    $sum = 0L
    $lines = @(foreach ($f in $files) { $sum += $f.Length; '{0}|{1}|{2}' -f $f.FullName.Substring($dir.Length), $f.Length, $f.LastWriteTimeUtc.Ticks })
    foreach ($k in @($Extra.Keys | Sort-Object)) { $lines += "extra|$k|$($Extra[$k])" }
    if ($sum -gt 8GB) { throw 'Quelle groesser als 8 GB - Intune erlaubt hoechstens 30 GB, aber das ist fuer die meisten Netze unrealistisch. Ordner pruefen.' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $sig = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-', '')
    $sigFile = "$Destination.sig"
    if ((Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $sigFile) -and (Get-Content -LiteralPath $sigFile -Raw).Trim() -eq $sig) {
        return [pscustomobject]@{ Folder = $Destination; SetupFile = $setup.Name; Signature = $sig; Copied = $false }
    }
    $writeExtra = { foreach ($k in $Extra.Keys) { [IO.File]::WriteAllText((Join-Path $Destination $k), "$($Extra[$k])", (New-Object System.Text.UTF8Encoding $true)) } }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if ($WholeFolder) { Copy-Item -Path (Join-Path $dir '*') -Destination $Destination -Recurse -Force }
    else { Copy-Item -LiteralPath $setup.FullName -Destination $Destination -Force }
    & $writeExtra
    Set-Content -LiteralPath $sigFile -Value $sig -Encoding ASCII
    return [pscustomobject]@{ Folder = $Destination; SetupFile = $setup.Name; Signature = $sig; Copied = $true }
}

# Paket bauen oder aus dem Zwischenspeicher nehmen (gleiche Quelle -> gleiches Paket)
function Get-HUAppPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ToolPath, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$SetupPath, [bool]$WholeFolder = $false, [hashtable]$Extra = @{})
    $root = Get-HUWorkPath "Packages\$AppId"
    $src = Sync-HUAppSource -SetupPath $SetupPath -WholeFolder $WholeFolder -Destination (Join-Path $root 'src') -Extra $Extra
    $info = Join-Path $root 'package.json'
    if (-not $src.Copied -and (Test-Path -LiteralPath $info)) {
        $p = Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($p.Signature)" -eq $src.Signature -and (Test-Path -LiteralPath "$($p.UploadFile)")) {
            $enc = @{}; foreach ($pr in $p.EncryptionInfo.PSObject.Properties) { $enc[$pr.Name] = $pr.Value }
            $p.EncryptionInfo = $enc
            Write-HULog -Message 'Paket unveraendert - vorhandenes Paket wird verwendet' -Level 'INFO'
            return $p
        }
    }
    Write-HULog -Message "Paketiere $($src.SetupFile) ..." -Level 'INFO'
    $pkg = New-HUIntuneWinPackage -ToolPath $ToolPath -SourceFolder $src.Folder -SetupFile $src.SetupFile -OutputFolder (Join-Path $root 'out')
    $pkg | Add-Member -NotePropertyName Signature -NotePropertyValue $src.Signature -Force
    [IO.File]::WriteAllText($info, ($pkg | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    Write-HULog -Message ("Paket erstellt: {0} ({1:N1} MB)" -f $pkg.IntuneWinName, ($pkg.EncryptedSize / 1MB)) -Level 'OK'
    return $pkg
}

# Ziele mit Gruppennamen -> Ziele mit GroupId (je Tenant). Fehlende Gruppe = Ausnahme.
function Resolve-HUTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][object[]]$Targets)
    foreach ($t in $Targets) {
        $h = @{ Kind = "$($t.Kind)"; Intent = "$($t.Intent)"; GroupId = ''; Label = '' }
        if ($h.Kind -eq 'group') {
            $g = Find-HUGroup -TenantKey $TenantKey -Settings $Settings -Name "$($t.GroupName)"
            if (-not $g) { throw "Gruppe '$($t.GroupName)' gibt es in diesem Tenant nicht" }
            $h.GroupId = "$($g.id)"; $h.Label = "Gruppe '$($g.displayName)'"
        } else { $h.Label = $(if ($h.Kind -eq 'allUsers') { 'Alle Benutzer' } else { 'Alle Geraete' }) }
        $h
    }
}

function Test-HUStoreId([string]$Id) { return ("$Id".Trim() -match '^(9[A-Za-z0-9]{11}|XP[A-Za-z0-9]{12})$') }

# Store-ID aus Text/Adresse holen (apps.microsoft.com/detail/9NKSQGP7F2NH?hl=de)
function Get-HUStoreIdFromText([string]$Text) {
    $m = [regex]::Match("$Text", '(?i)(?<![A-Z0-9])(9[A-Z0-9]{11}|XP[A-Z0-9]{12})(?![A-Z0-9])')
    if ($m.Success) { return $m.Value.ToUpper() }
    return ''
}

# Name/Hersteller einer Store-App (dieselbe Quelle, die winget fuer "msstore" nutzt). Fehler -> $null.
function Get-HUStoreAppInfo([string]$StoreId) {
    try {
        $r = Invoke-RestMethod -Uri "https://storeedgefd.dsx.mp.microsoft.com/v9.0/packageManifests/$StoreId" -UseBasicParsing -TimeoutSec 8
        $loc = @($r.Data.Versions)[0].DefaultLocale
        if (-not $loc) { return $null }
        return [pscustomobject]@{ Name = "$($loc.PackageName)"; Publisher = "$($loc.Publisher)"; Description = "$($loc.ShortDescription)" }
    } catch { return $null }
}

# ============================================================================
# App-Symbol (Unternehmensportal): Bild/ICO/EXE -> PNG (max. 256 px) -> largeIcon
# ============================================================================
function Initialize-HUIconNative {
    if ('HUTools.IconNative' -as [type]) { return }
    Add-Type -Namespace 'HUTools' -Name 'IconNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, System.IntPtr[] phicon, int[] piconid, uint nIcons, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
'@
}

# "C:\x\app.exe,0" / "\"C:\x\app.exe\",-101" -> @{ Path; Index }
function Split-HUIconLocation([string]$Text) {
    $t = "$Text".Trim()
    $idx = 0
    $m = [regex]::Match($t, '^(.*?),\s*(-?\d+)\s*$')
    if ($m.Success) { $t = $m.Groups[1].Value; $idx = [int]$m.Groups[2].Value }
    return [pscustomobject]@{ Path = [Environment]::ExpandEnvironmentVariables($t.Trim().Trim('"')); Index = $idx }
}

function ConvertTo-HUIconPng {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OutFile, [int]$Index = 0, [int]$MaxSize = 256)
    Add-Type -AssemblyName System.Drawing
    if (-not (Test-Path -LiteralPath $Path)) { throw "Datei nicht gefunden: $Path" }
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    $bmp = $null
    if ($ext -in '.exe', '.dll') {
        Initialize-HUIconNative
        foreach ($size in 256, 128, 64, 48, 32) {
            $h = New-Object IntPtr[] 1; $id = New-Object int[] 1
            $n = [HUTools.IconNative]::PrivateExtractIcons($Path, $Index, $size, $size, $h, $id, 1, 0)
            if ($n -ge 1 -and $h[0] -ne [IntPtr]::Zero) {
                try { $bmp = ([System.Drawing.Icon]::FromHandle($h[0])).ToBitmap() } finally { [void][HUTools.IconNative]::DestroyIcon($h[0]) }
                break
            }
        }
        if (-not $bmp) { $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($Path); if ($ic) { $bmp = $ic.ToBitmap() } }
        if (-not $bmp) { throw 'Kein Symbol in der Datei gefunden' }
    } elseif ($ext -eq '.ico') {
        $ic = New-Object System.Drawing.Icon($Path, 256, 256)
        try { $bmp = $ic.ToBitmap() } finally { $ic.Dispose() }
    } else {
        $fs = [IO.File]::OpenRead($Path)
        try { $img = [System.Drawing.Image]::FromStream($fs); $bmp = New-Object System.Drawing.Bitmap($img); $img.Dispose() } finally { $fs.Dispose() }
    }
    try {
        $w = $bmp.Width; $hgt = $bmp.Height
        $scale = [Math]::Min(1.0, $MaxSize / [double][Math]::Max($w, $hgt))
        $nw = [Math]::Max(1, [int]($w * $scale)); $nh = [Math]::Max(1, [int]($hgt * $scale))
        $out = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($out)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($bmp, 0, 0, $nw, $nh)
        } finally { $g.Dispose() }
        $dir = Split-Path $OutFile -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$OutFile.tmp"
        $out.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        $out.Dispose()
        Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    } finally { $bmp.Dispose() }
    return $OutFile
}

function Get-HUIconContent([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    return @{ '@odata.type' = '#microsoft.graph.mimeContent'; type = 'image/png'; value = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }
}

# Logo einer Store-App (Produktkatalog des Microsoft Store, ohne Anmeldung). Fehler -> $false.
function Save-HUStoreAppIcon([string]$StoreId, [string]$OutFile) {
    try {
        $r = Invoke-RestMethod -Uri "https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=$StoreId&market=AT&languages=de-AT,en-US,neutral" -UseBasicParsing -TimeoutSec 8
        $imgs = @(@($r.Products)[0].LocalizedProperties | ForEach-Object { $_.Images } | Where-Object { $_ })
        $pick = @($imgs | Where-Object { $_.ImagePurpose -in 'Tile', 'Logo', 'BoxArt' } | Sort-Object @{ Expression = { switch ($_.ImagePurpose) { 'Tile' { 0 } 'Logo' { 1 } default { 2 } } } }, @{ Expression = { [Math]::Abs(300 - [int]$_.Width) } })[0]
        if (-not $pick) { return $false }
        $uri = "$($pick.Uri)"; if ($uri.StartsWith('//')) { $uri = "https:$uri" }
        $tmp = "$OutFile.download"
        Invoke-WebRequest -Uri $uri -OutFile $tmp -UseBasicParsing -TimeoutSec 15
        try { [void](ConvertTo-HUIconPng -Path $tmp -OutFile $OutFile) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

# ============================================================================
# Win32-App je Tenant anlegen/aktualisieren und Inhalt hochladen; Abhaengigkeiten setzen
# ============================================================================
# Huelle um den Installationsbefehl: neue Desktop-Verknuepfungen (Allgemeiner und eigener Desktop) danach entfernen.
# Liegt als HU-Install.ps1 im Paket; der Exitcode des Setups bleibt erhalten.
function New-HUInstallWrapper([string]$Cmd) {
    $c = "$Cmd".Replace("'", "''")
    return @"
# HU-MultiTenant: Installation ohne neue Desktop-Verknuepfungen
`$dirs = @("`$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'))
`$before = @(Get-ChildItem -Path `$dirs -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { `$_.FullName })
`$p = Start-Process -FilePath "`$env:ComSpec" -ArgumentList '/c', ('"' + '$c' + '"') -WorkingDirectory `$PSScriptRoot -WindowStyle Hidden -Wait -PassThru
Get-ChildItem -Path `$dirs -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { `$before -notcontains `$_.FullName } | Remove-Item -Force -ErrorAction SilentlyContinue
exit `$p.ExitCode
"@
}

# Befehl, den Intune (bzw. die Sandbox) ausfuehrt, und Zusatzdateien fuer das Paket
function Get-HUInstallPlan($Def, [switch]$Sandbox) {
    $no = $Def.PSObject.Properties['NoDesktop'] -and [bool]$Def.NoDesktop
    if (-not $no) { return [pscustomobject]@{ Cmd = "$($Def.InstallCmd)"; Extra = @{} } }
    $ps = if ($Sandbox) { 'powershell.exe' } else { '%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
    return [pscustomobject]@{ Cmd = "$ps -NoProfile -ExecutionPolicy Bypass -File .\HU-Install.ps1"; Extra = @{ 'HU-Install.ps1' = (New-HUInstallWrapper "$($Def.InstallCmd)") } }
}

# Bibliotheks-Eintrag -> Def fuer ConvertTo-HUWin32Payload
function New-HUWin32Def($Def) {
    return [pscustomobject]@{
        Name = $Def.Name; Publisher = $Def.Publisher; Description = $Def.Description; Version = $Def.Version
        SetupFile = ("$($Def.SetupPath)" -split '[\\/]')[-1]; InstallCmd = (Get-HUInstallPlan $Def).Cmd; UninstallCmd = $Def.UninstallCmd
        RunAs = $Def.RunAs; Kind = $Def.Kind; UpgradeCode = $Def.UpgradeCode; Detection = $Def.Detection; Restart = 'suppress'
        IconFile = $(if ($Def.PSObject.Properties['IconFile']) { "$($Def.IconFile)" } else { '' })
    }
}

# Liefert @{ AppId; Signature }. Laedt nur hoch, wenn neu, Paket geaendert oder noch kein Inhalt.
function Publish-HUWin32App {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Def, [Parameter(Mandatory)]$Package,
        [string]$AppId = '', [string]$LastSignature = '')
    $w32 = New-HUWin32Def $Def
    $existing = if ($AppId) { Get-HUIntuneApp -TenantKey $TenantKey -Settings $Settings -AppId $AppId } else { $null }
    if ($AppId -and -not $existing) { Write-HULog -Message "$($Def.Name): frueher hochgeladene App gibt es in Intune nicht mehr - wird neu angelegt" -Level 'WARN' -Tenant $TenantKey; $AppId = '' }
    if ($existing) {
        Update-HUWin32App -TenantKey $TenantKey -Settings $Settings -AppId $AppId -Def $w32 -IntuneWinName $Package.IntuneWinName
        Write-HULog -Message "$($Def.Name): aktualisiert (v$($Def.Version))" -Level 'OK' -Tenant $TenantKey
    } else {
        $new = New-HUWin32App -TenantKey $TenantKey -Settings $Settings -Def $w32 -IntuneWinName $Package.IntuneWinName
        $AppId = "$($new.id)"
        Write-HULog -Message "$($Def.Name): angelegt (v$($Def.Version))" -Level 'OK' -Tenant $TenantKey
    }
    $res = [pscustomobject]@{ AppId = $AppId; Signature = '' }
    if (-not $existing -or $LastSignature -ne "$($Package.Signature)" -or -not "$($existing.committedContentVersion)") {
        Write-HULog -Message ("{0}: lade Paket hoch ({1:N1} MB) ..." -f $Def.Name, ($Package.EncryptedSize / 1MB)) -Level 'INFO' -Tenant $TenantKey
        [void](Publish-HUWin32Content -TenantKey $TenantKey -Settings $Settings -AppId $AppId -Package $Package)
        Write-HULog -Message "$($Def.Name): Paket hochgeladen" -Level 'OK' -Tenant $TenantKey
    } else { Write-HULog -Message "$($Def.Name): Paket unveraendert - kein erneuter Upload" -Level 'INFO' -Tenant $TenantKey }
    $res.Signature = "$($Package.Signature)"
    return $res
}

# Abhaengigkeiten einer Win32-App setzen. "updateRelationships" ersetzt alle Beziehungen -
# vorhandene Ersetzungen (Supersedence) bleiben erhalten, Abhaengigkeiten werden durch die Liste ersetzt.
function Get-HUDependencyBody([object[]]$Existing, [string[]]$DependencyIds, [bool]$AutoInstall = $true) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Existing)) {
        if (-not $r -or "$($r.targetType)" -ne 'child' -or "$($r.'@odata.type')" -notmatch 'Supersedence') { continue }
        $list.Add(@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = "$($r.targetId)"; supersedenceType = "$($r.supersedenceType)" })
    }
    foreach ($id in @($DependencyIds | Where-Object { $_ } | Select-Object -Unique)) {
        $list.Add(@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = "$id"; dependencyType = $(if ($AutoInstall) { 'autoInstall' } else { 'detect' }) })
    }
    return @{ relationships = @($list.ToArray()) }
}

function Set-HUAppDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [string[]]$DependencyIds = @(), [bool]$AutoInstall = $true)
    $rel = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/relationships")
    $body = Get-HUDependencyBody -Existing $rel -DependencyIds $DependencyIds -AutoInstall $AutoInstall
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/updateRelationships" -Method POST -Body $body)
    return @($DependencyIds).Count
}

# ============================================================================
# Microsoft Store App (neu) = winGetApp (beta)
# ============================================================================
function New-HUStoreApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Def)
    if (-not (Test-HUStoreId "$($Def.StoreId)")) { throw "Store-ID ungueltig: '$($Def.StoreId)' (z. B. 9NKSQGP7F2NH oder XP89DCGQ3K6VLD)" }
    $body = @{
        '@odata.type'     = '#microsoft.graph.winGetApp'
        displayName       = "$($Def.Name)"
        description       = $(if ("$($Def.Description)".Trim()) { "$($Def.Description)" } else { "$($Def.Name)" })
        publisher         = $(if ("$($Def.Publisher)".Trim()) { "$($Def.Publisher)" } else { '-' })
        packageIdentifier = "$($Def.StoreId)".ToUpper()
        installExperience = @{ '@odata.type' = '#microsoft.graph.winGetAppInstallExperience'; runAsAccount = $(if ("$($Def.RunAs)" -eq 'user') { 'user' } else { 'system' }) }
    }
    if ($Def.PSObject.Properties['IconFile']) { $ic = Get-HUIconContent "$($Def.IconFile)"; if ($ic) { $body.largeIcon = $ic } }
    return (Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceAppManagement/mobileApps' -Method POST -Body $body)
}

# ============================================================================
# Zuweisungen - vorhandene werden gelesen und zusammengefuehrt ("assign" ersetzt sonst alle)
#   Target: @{ Kind = 'group'|'allDevices'|'allUsers'; GroupId; Intent = 'required'|'available'|'uninstall' }
# ============================================================================
function Get-HUTargetKey($t) {
    $type = "$($t.'@odata.type')"
    if ($type -match 'groupAssignmentTarget') { return "$type|$($t.groupId)" }
    return $type
}

function New-HUAssignmentTarget($Target) {
    switch ("$($Target.Kind)") {
        'allDevices' { return @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
        'allUsers' { return @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
        'exclude' { return @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = "$($Target.GroupId)" } }
        default { return @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = "$($Target.GroupId)" } }
    }
}

function Wait-HUAppPublished {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [int]$MaxSeconds = 300)
    $start = Get-Date; $said = $false
    while ($true) {
        $a = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId"
        $st = "$($a.publishingState)"
        if (-not $st -or $st -eq 'published') { return }
        if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds) { throw "App ist nach $MaxSeconds s noch nicht bereit (Status: $st) - spaeter erneut 'Hochladen & zuweisen' (Paket wird nicht noch einmal hochgeladen)" }
        if (-not $said) { Write-HULog -Message "Intune verarbeitet die App noch ($st) - warte ..." -Level 'INFO' -Tenant $TenantKey; $said = $true }
        Start-Sleep -Seconds 10
    }
}

function Set-HUAppAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId,
        [ValidateSet('win32', 'winget', 'other')][string]$AppKind = 'win32',
        [Parameter(Mandatory)][object[]]$Targets,
        [ValidateSet('showAll', 'showReboot', 'hideAll')][string]$Notifications = 'showAll',
        $Deadline = $null
    )
    $setType = if ($AppKind -eq 'winget') { '#microsoft.graph.winGetAppAssignmentSettings' } else { '#microsoft.graph.win32LobAppAssignmentSettings' }
    # Zuweisen geht erst, wenn Intune die App fertig verarbeitet hat (publishingState = published)
    Wait-HUAppPublished -TenantKey $TenantKey -Settings $Settings -AppId $AppId
    $list = [ordered]@{}
    foreach ($a in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assignments")) {
        $h = @{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = "$($a.intent)"; target = $a.target }
        if ($a.settings) { $h.settings = $a.settings }
        $list[(Get-HUTargetKey $a.target)] = $h
    }
    foreach ($t in $Targets) {
        $tg = New-HUAssignmentTarget $t
        $its = $null
        if ($Deadline -and "$($t.Intent)" -eq 'required') {
            $its = @{ '@odata.type' = '#microsoft.graph.mobileAppInstallTimeSettings'; useLocalTime = $true; startDateTime = $null; deadlineDateTime = ([datetime]$Deadline).ToString('s') }
        }
        $st = $null
        if ($AppKind -ne 'other' -and "$($t.Kind)" -ne 'exclude') {
            $st = @{ '@odata.type' = $setType; notifications = $Notifications; installTimeSettings = $its; restartSettings = $null }
            if ($AppKind -eq 'win32') { $st.deliveryOptimizationPriority = 'notConfigured' }
        }
        $h = @{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = "$($t.Intent)"; target = $tg }
        if ($st) { $h.settings = $st }
        $list[(Get-HUTargetKey $tg)] = $h
    }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assign" -Method POST -Body @{ mobileAppAssignments = @($list.Values) })
    return $list.Count
}

# ============================================================================
# Vorhandene Apps in Intune verwalten (Liste, Zuweisungen, Eigenschaften, Beziehungen, Loeschen)
# ============================================================================
$script:WinAppTypes = @{
    'win32LobApp' = 'Win32'; 'winGetApp' = 'Store (neu)'; 'windowsMobileMSI' = 'MSI (LOB)'; 'officeSuiteApp' = 'Microsoft 365 Apps'
    'windowsMicrosoftEdgeApp' = 'Microsoft Edge'; 'windowsUniversalAppX' = 'MSIX/AppX'; 'windowsWebApp' = 'Weblink'; 'webApp' = 'Weblink'
    'microsoftStoreForBusinessApp' = 'Store (alt)'; 'windowsStoreApp' = 'Store (alt)'; 'win32CatalogApp' = 'Win32 (Katalog)'
}

function Get-HUAppKindFromType([string]$OdataType) {
    $t = ($OdataType -replace '^#?microsoft\.graph\.', '')
    if ($t -in 'win32LobApp', 'win32CatalogApp') { return 'win32' }
    if ($t -eq 'winGetApp') { return 'winget' }
    return 'other'
}

# Gruppen-IDs -> Namen (ein Aufruf je 1000 IDs)
function Get-HUGroupNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [string[]]$Ids)
    $map = @{}
    $ids = @($Ids | Where-Object { $_ } | Select-Object -Unique)
    for ($i = 0; $i -lt $ids.Count; $i += 1000) {
        $chunk = @($ids[$i..([Math]::Min($i + 999, $ids.Count - 1))])
        $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/directoryObjects/getByIds' -Method POST -Body @{ ids = $chunk; types = @('group') } -V1
        foreach ($g in @($r.value)) { $map["$($g.id)"] = "$($g.displayName)" }
    }
    return $map
}

# Zuweisung -> lesbare Zeile; Key = Art|Gruppenname (gleich ueber Tenants hinweg)
function ConvertFrom-HUAssignment($A, [hashtable]$Names = @{}) {
    $t = $A.target
    $type = "$($t.'@odata.type')"
    $kind = if ($type -match 'exclusionGroup') { 'exclude' } elseif ($type -match 'allDevices') { 'allDevices' } elseif ($type -match 'allLicensedUsers') { 'allUsers' } else { 'group' }
    $gn = if ($t.groupId) { $(if ($Names.ContainsKey("$($t.groupId)")) { $Names["$($t.groupId)"] } else { "(Gruppe $($t.groupId))" }) } else { '' }
    $label = switch ($kind) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } 'exclude' { "Ausschluss: $gn" } default { $gn } }
    $dl = ''
    try { if ($A.settings.installTimeSettings.deadlineDateTime) { $dl = ([datetime]$A.settings.installTimeSettings.deadlineDateTime).ToString('dd.MM.yyyy HH:mm') } } catch { }
    return [pscustomobject]@{
        Key = "$kind|$($gn.ToLower())"; Kind = $kind; GroupId = "$($t.groupId)"; GroupName = $gn; Ziel = $label
        Intent = "$($A.intent)"; Notify = $(if ($A.settings) { "$($A.settings.notifications)" } else { '' }); Deadline = $dl
    }
}

# Alle Windows-Apps eines Tenants mit Zuweisungen (Gruppennamen aufgeloest)
function Get-HUTenantAppList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $all = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceAppManagement/mobileApps?$expand=assignments')
    $win = @($all | Where-Object { $script:WinAppTypes.ContainsKey(("$($_.'@odata.type')" -replace '^#?microsoft\.graph\.', '')) })
    $gids = @($win | ForEach-Object { @($_.assignments) } | ForEach-Object { $_.target.groupId } | Where-Object { $_ })
    $names = if ($gids.Count) { Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids $gids } else { @{} }
    foreach ($a in $win) {
        $t = ("$($a.'@odata.type')" -replace '^#?microsoft\.graph\.', '')
        [pscustomobject]@{
            Name = "$($a.displayName)"; Typ = $script:WinAppTypes[$t]; OType = $t; Kind = (Get-HUAppKindFromType $t)
            Version = "$($a.displayVersion)"; Publisher = "$($a.publisher)"; Description = "$($a.description)"; Id = "$($a.id)"
            Modified = "$($a.lastModifiedDateTime)"; State = "$($a.publishingState)"
            Assignments = @(@($a.assignments) | Where-Object { $_ } | ForEach-Object { ConvertFrom-HUAssignment $_ $names })
        }
    }
}

# Zuweisungen entfernen, deren Key (Art|Gruppenname) in -Keys steht
function Remove-HUAppAssignments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string[]]$Keys)
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assignments")
    $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids @($cur | ForEach-Object { $_.target.groupId })
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = 0
    foreach ($a in $cur) {
        if ($Keys -contains (ConvertFrom-HUAssignment $a $names).Key) { $removed++; continue }
        $h = @{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = "$($a.intent)"; target = $a.target }
        if ($a.settings) { $h.settings = $a.settings }
        $keep.Add($h)
    }
    if ($removed) { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assign" -Method POST -Body @{ mobileAppAssignments = @($keep.ToArray()) }) }
    return $removed
}

# Name, Beschreibung, Hersteller, Symbol aendern (leere Werte bleiben unveraendert)
function Update-HUAppProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$OType,
        [string]$Name = '', [string]$Description = '', [string]$Publisher = '', [string]$IconFile = '')
    $b = @{ '@odata.type' = "#microsoft.graph.$OType" }
    if ($Name) { $b.displayName = $Name }
    if ($Description) { $b.description = $Description }
    if ($Publisher) { $b.publisher = $Publisher }
    if ($IconFile) { $ic = Get-HUIconContent $IconFile; if ($ic) { $b.largeIcon = $ic } }
    if ($b.Count -le 1) { return }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId" -Method PATCH -Body $b)
}

function Get-HUAppIconBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    $a = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId"
    if ($a.largeIcon -and $a.largeIcon.value) { return [Convert]::FromBase64String("$($a.largeIcon.value)") }
    return $null
}

# Beziehungen, bei denen die App die Quelle ist (Abhaengigkeiten, Ersetzungen)
function Get-HUAppRelationRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    foreach ($r in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/relationships")) {
        if ("$($r.targetType)" -ne 'child') { continue }
        $isDep = "$($r.'@odata.type')" -match 'Dependency'
        [pscustomobject]@{
            Art = $(if ($isDep) { 'Abhaengigkeit' } else { 'Ersetzt' }); TargetId = "$($r.targetId)"; App = "$($r.targetDisplayName)"; Version = "$($r.targetDisplayVersion)"
            Typ = $(if ($isDep) { $(if ($r.dependencyType -eq 'detect') { 'nur pruefen' } else { 'automatisch installieren' }) } else { $(if ($r.supersedenceType -eq 'replace') { 'ersetzen (alte deinstallieren)' } else { 'aktualisieren' }) })
            Raw = $(if ($isDep) { @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = "$($r.targetId)"; dependencyType = "$($r.dependencyType)" } } else { @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = "$($r.targetId)"; supersedenceType = "$($r.supersedenceType)" } })
            Key = "$(if ($isDep) { 'dep' } else { 'sup' })|$("$($r.targetDisplayName)".ToLower())"
        }
    }
}

# Beziehungen aendern: -Add @(@{ Art = 'dep'|'sup'; TargetId; Type = 'autoInstall'|'detect'|'update'|'replace' }), -RemoveKeys 'dep|name'
function Set-HUAppRelations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [object[]]$Add = @(), [string[]]$RemoveKeys = @())
    $rows = @(Get-HUAppRelationRows -TenantKey $TenantKey -Settings $Settings -AppId $AppId)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) { if ($RemoveKeys -notcontains $r.Key -and -not @($Add | Where-Object { $_.TargetId -eq $r.TargetId }).Count) { $list.Add($r.Raw) } }
    foreach ($a in @($Add)) {
        if ($a.Art -eq 'sup') { $list.Add(@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = "$($a.TargetId)"; supersedenceType = $(if ($a.Type -eq 'replace') { 'replace' } else { 'update' }) }) }
        else { $list.Add(@{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = "$($a.TargetId)"; dependencyType = $(if ($a.Type -eq 'detect') { 'detect' } else { 'autoInstall' }) }) }
    }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/updateRelationships" -Method POST -Body @{ relationships = @($list.ToArray()) })
    return $list.Count
}

function Remove-HUIntuneApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId" -Method DELETE)
}

# ============================================================================
# Installationsstatus (Export-Report DeviceInstallStatusByApp)
# ============================================================================
function Invoke-HUExportReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$ReportName, [string]$Filter = '', [string[]]$Select = @(), [int]$MaxSeconds = 180)
    $body = @{ reportName = $ReportName; format = 'csv' }
    if ($Filter) { $body.filter = $Filter }
    if ($Select.Count) { $body.select = $Select }
    $job = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/reports/exportJobs' -Method POST -Body $body
    $start = Get-Date
    while ("$($job.status)" -ne 'completed') {
        if ("$($job.status)" -eq 'failed') { throw "Report $ReportName fehlgeschlagen" }
        if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds) { throw "Report ${ReportName}: Zeitueberschreitung" }
        Start-Sleep -Seconds 3
        $job = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/reports/exportJobs('$($job.id)')"
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("hu-report-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $zip = Join-Path $tmp 'r.zip'
        Invoke-WebRequest -Uri "$($job.url)" -OutFile $zip -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $tmp 'x'))
        $csv = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Filter '*.csv' | Select-Object -First 1
        if (-not $csv) { return @() }
        return @(Import-Csv -LiteralPath $csv.FullName -Encoding UTF8)
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-HUErrorText([string]$Hex) {
    $h = "$Hex".Trim().ToUpper()
    $map = @{
        '0X87D1041C' = 'Installation lief, aber die Erkennungsregel findet die App nicht - Erkennung pruefen'
        '0X80070643' = 'Schwerer Fehler bei der Installation (MSI 1603)'
        '0X80070652' = 'Eine andere Installation laeuft gerade (1618) - wird wiederholt'
        '0X80070653' = 'Installationspaket nicht lesbar (1619) - Dateiname im Befehl pruefen'
        '0X80070002' = 'Datei nicht gefunden - Befehl/Setup-Datei pruefen'
        '0X80070005' = 'Zugriff verweigert - Kontext System/Benutzer pruefen'
    }
    if ($map.ContainsKey($h)) { return $map[$h] }
    return ''
}

function Get-HUAppInstallStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    $rows = Invoke-HUExportReport -TenantKey $TenantKey -Settings $Settings -ReportName 'DeviceInstallStatusByApp' -Filter "(ApplicationId eq '$AppId')" `
        -Select @('DeviceName', 'UserPrincipalName', 'Platform', 'AppVersion', 'InstallState', 'InstallStateDetail', 'HexErrorCode', 'LastModifiedDateTime')
    foreach ($r in $rows) {
        [pscustomobject][ordered]@{
            Geraet   = "$($r.DeviceName)"
            Benutzer = "$($r.UserPrincipalName)"
            Status   = "$($r.InstallState)"
            Detail   = "$($r.InstallStateDetail)"
            Version  = "$($r.AppVersion)"
            Fehler   = "$($r.HexErrorCode)"
            Hinweis  = (Get-HUErrorText "$($r.HexErrorCode)")
            Zeit     = "$($r.LastModifiedDateTime)"
        }
    }
}

# ============================================================================
# Wartungsskripte (Remediations / deviceHealthScripts, beta)
#   Def: Name, Description, Publisher, Detection, Remediation, RunAs (system|user), RunAs32 (bool)
# ============================================================================
function ConvertTo-HURemediationPayload($Def) {
    if (-not "$($Def.Name)".Trim()) { throw 'Name fehlt' }
    if (-not "$($Def.Detection)".Trim()) { throw 'Pruefskript fehlt' }
    return @{
        '@odata.type'            = '#microsoft.graph.deviceHealthScript'
        displayName              = "$($Def.Name)"
        description              = "$($Def.Description)"
        publisher                = $(if ("$($Def.Publisher)".Trim()) { "$($Def.Publisher)" } else { 'HU-MultiTenant' })
        runAsAccount             = $(if ("$($Def.RunAs)" -eq 'user') { 'user' } else { 'system' })
        runAs32Bit               = [bool]$Def.RunAs32
        enforceSignatureCheck    = $false
        detectionScriptContent   = (ConvertTo-HUBase64Utf8 "$($Def.Detection)")
        remediationScriptContent = (ConvertTo-HUBase64Utf8 "$($Def.Remediation)")
        roleScopeTagIds          = @('0')
    }
}

function Publish-HURemediation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Def, [string]$Id = '')
    $body = ConvertTo-HURemediationPayload $Def
    if ($Id) {
        $exists = $true
        try { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id") }
        catch { if ("$($_.Exception.Message)" -match '404|NotFound') { $exists = $false } else { throw } }
        if ($exists) {
            [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id" -Method PATCH -Body $body)
            return $Id
        }
    }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/deviceHealthScripts' -Method POST -Body $body
    return "$($r.id)"
}

# Schedule: @{ Type = 'daily'|'hourly'|'once'; Interval = 1; Time = '08:00'; Date = 'yyyy-MM-dd' }
function New-HURunSchedule($Schedule) {
    $time = "$($Schedule.Time)"; if ($time -notmatch '^\d{1,2}:\d{2}$') { $time = '08:00' }
    $t = ([datetime]::ParseExact($time, 'H:mm', $null)).ToString('HH:mm:ss') + '.0000000'
    $iv = [Math]::Max(1, [int]$Schedule.Interval)
    switch ("$($Schedule.Type)") {
        'hourly' { return @{ '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'; interval = [Math]::Min($iv, 23) } }
        'once' {
            $d = "$($Schedule.Date)"; if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { $d = (Get-Date).AddDays(1).ToString('yyyy-MM-dd') }
            return @{ '@odata.type' = '#microsoft.graph.deviceHealthScriptRunOnceSchedule'; interval = 1; useUtc = $false; time = $t; date = $d }
        }
        default { return @{ '@odata.type' = '#microsoft.graph.deviceHealthScriptDailySchedule'; interval = $iv; useUtc = $false; time = $t } }
    }
}

function Set-HURemediationAssignment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][object[]]$Targets, [Parameter(Mandatory)]$Schedule, [bool]$RunRemediation = $true)
    $list = [ordered]@{}
    foreach ($a in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/assignments")) {
        $list[(Get-HUTargetKey $a.target)] = @{ target = $a.target; runRemediationScript = [bool]$a.runRemediationScript; runSchedule = $a.runSchedule }
    }
    foreach ($t in $Targets) {
        $tg = New-HUAssignmentTarget $t
        $list[(Get-HUTargetKey $tg)] = @{ target = $tg; runRemediationScript = $RunRemediation; runSchedule = (New-HURunSchedule $Schedule) }
    }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/assign" -Method POST -Body @{ deviceHealthScriptAssignments = @($list.Values) })
    return $list.Count
}

function Get-HURemediationRunStates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id)
    $sel = [uri]::EscapeDataString('managedDevice($select=id,deviceName,userPrincipalName)')
    $states = Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/deviceRunStates?`$expand=$sel"
    $det = @{ success = 'kein Problem'; fail = 'Problem gefunden'; scriptError = 'Skriptfehler'; pending = 'ausstehend'; notApplicable = 'nicht zutreffend'; unknown = 'unbekannt' }
    $rem = @{ success = 'behoben'; remediationFailed = 'Reparatur fehlgeschlagen'; scriptError = 'Skriptfehler'; skipped = 'nicht noetig'; unknown = '-' }
    foreach ($s in $states) {
        $out = "$($s.postRemediationDetectionScriptOutput)"; if (-not $out) { $out = "$($s.preRemediationDetectionScriptOutput)" }
        $err = "$($s.remediationScriptError)"; if (-not $err) { $err = "$($s.preRemediationDetectionScriptError)" }
        [pscustomobject][ordered]@{
            Geraet    = "$($s.managedDevice.deviceName)"
            Benutzer  = "$($s.managedDevice.userPrincipalName)"
            Pruefung  = $(if ($det.ContainsKey("$($s.detectionState)")) { $det["$($s.detectionState)"] } else { "$($s.detectionState)" })
            Reparatur = $(if ($rem.ContainsKey("$($s.remediationState)")) { $rem["$($s.remediationState)"] } else { "$($s.remediationState)" })
            Zeit      = $(try { ([datetime]$s.lastStateUpdateDateTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { "$($s.lastStateUpdateDateTime)" })
            Ausgabe   = $out
            Fehler    = $err
            DeviceId  = "$($s.managedDevice.id)"
        }
    }
}

function Start-HURemediationOnDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$DeviceId, [Parameter(Mandatory)][string]$Id)
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices/$DeviceId/initiateOnDemandProactiveRemediation" -Method POST -Body @{ scriptPolicyId = $Id })
}

# ============================================================================
# Pruefung eines Wartungsskripts (ohne Ausfuehrung)
# ============================================================================
function Test-HURemediationScript {
    [CmdletBinding()]
    param([string]$Code, [ValidateSet('detection', 'remediation')][string]$Kind = 'detection', [string]$RunAs = 'system')
    $res = New-Object System.Collections.Generic.List[object]
    $add = { param($l, $t) $res.Add([pscustomobject]@{ Stufe = $l; Hinweis = $t }) }
    $name = if ($Kind -eq 'detection') { 'Pruefskript' } else { 'Reparaturskript' }
    if (-not "$Code".Trim()) {
        if ($Kind -eq 'remediation') { & $add 'Info' 'Kein Reparaturskript - es wird nur geprueft und berichtet.' } else { & $add 'Fehler' 'Pruefskript fehlt.' }
        return $res.ToArray()
    }
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tok, [ref]$err)
    foreach ($e in @($err)) { & $add 'Fehler' "${name}: Zeile $($e.Extent.StartLineNumber): $($e.Message)" }
    $rx = @(
        @{ P = '(?im)\b(Restart-Computer|Stop-Computer)\b|\bshutdown(\.exe)?\s+[/-][rs]'; L = 'Fehler'; T = 'Kein Neustart/Herunterfahren in Wartungsskripten (Intune-Vorgabe).' }
        @{ P = '(?im)\b(Read-Host|Out-GridView|Pause)\b|\[Console\]::ReadKey'; L = 'Fehler'; T = 'Keine Eingaben/Fenster - das Skript laeuft unbeaufsichtigt.' }
        @{ P = '(?im)\?\?|\?\.\w'; L = 'Warnung'; T = 'Moeglicherweise PowerShell-7-Syntax (?? / ?.) - Intune nutzt Windows PowerShell 5.1.' }
        @{ P = '(?im)\bInvoke-Expression\b|\biex\b'; L = 'Warnung'; T = 'Invoke-Expression vermeiden.' }
    )
    foreach ($r in $rx) { if ($Code -match $r.P) { & $add $r.L "${name}: $($r.T)" } }
    if ($Kind -eq 'detection') {
        if ($Code -notmatch '(?im)\bexit\s+1\b') { & $add 'Fehler' 'Pruefskript: "exit 1" fehlt - nur damit erkennt Intune ein Problem und startet die Reparatur.' }
        if ($Code -notmatch '(?im)\bexit\s+0\b') { & $add 'Warnung' 'Pruefskript: "exit 0" fehlt - fuer den Fall "alles in Ordnung" empfohlen.' }
        if ($Code -notmatch '(?im)\b(Write-Output|Write-Host)\b') { & $add 'Warnung' 'Pruefskript: keine Ausgabe - eine kurze Meldung (Write-Output) erscheint spaeter in der Auswertung.' }
    } else {
        if ($Code -match '(?im)\bexit\s+1\b') { & $add 'Info' 'Reparaturskript: "exit 1" wird als fehlgeschlagene Reparatur gewertet.' }
    }
    if ($RunAs -ne 'user' -and $Code -match '(?im)HKCU:|\$env:USERPROFILE|\$env:APPDATA') { & $add 'Warnung' "${name}: Benutzerpfade (HKCU, USERPROFILE) - das Skript laeuft als SYSTEM, nicht als angemeldeter Benutzer." }
    if (-not @($res | Where-Object { $_.Stufe -in 'Fehler', 'Warnung' }).Count) { & $add 'OK' "${name}: keine Probleme gefunden." }
    return $res.ToArray()
}

# Vorlage fuer KI-Assistenten (Text zum Kopieren)
function Get-HUAiPrompt {
    [CmdletBinding()]
    param([ValidateSet('remediation', 'appDetection')][string]$Kind = 'remediation', [string]$Task = '')
    $t = if ("$Task".Trim()) { "$Task".Trim() } else { '<HIER BESCHREIBEN, WAS GEPRUEFT UND REPARIERT WERDEN SOLL>' }
    if ($Kind -eq 'appDetection') {
        return @"
Schreibe ein PowerShell-Erkennungsskript fuer eine Microsoft-Intune-Win32-App.
App: $t
Regeln:
- Windows PowerShell 5.1, keine PowerShell-7-Syntax, keine Module, keine Eingaben.
- Laeuft als SYSTEM (64 Bit). Benutzerpfade (HKCU, AppData) gibt es nicht.
- Ist die App installiert: eine kurze Zeile mit Write-Output ausgeben UND exit 0.
- Ist sie nicht installiert: nichts ausgeben und exit 0 (Intune wertet "keine Ausgabe" als nicht installiert).
- Pruefe Version mit [version]-Vergleich, wenn eine Mindestversion angegeben ist.
Gib nur das Skript aus, ohne Erklaerung.
"@
    }
    return @"
Schreibe ein Paar PowerShell-Skripte fuer Microsoft Intune Remediations (Pruefskript + Reparaturskript).
Aufgabe: $t
Regeln fuer beide Skripte:
- Windows PowerShell 5.1, keine PowerShell-7-Syntax, keine zusaetzlichen Module, keine Eingaben/Fenster.
- Laufen als SYSTEM (64 Bit) auf Windows 11 Education. Kein Neustart, kein Herunterfahren.
- Ausgabe kurz halten (unter 2.000 Zeichen), eine aussagekraeftige Zeile mit Write-Output.
- Fehler mit try/catch abfangen.
Pruefskript:
- exit 1, wenn das Problem vorliegt (dann laeuft die Reparatur), sonst exit 0.
- Vor dem exit eine kurze Statusmeldung ausgeben.
Reparaturskript:
- Behebt das Problem; exit 0 bei Erfolg, exit 1 bei Fehler, mit kurzer Meldung.
Gib die beiden Skripte getrennt aus, ueberschrieben mit "### Pruefskript" und "### Reparaturskript", ohne weitere Erklaerung.
"@
}

# Antwort einer KI in Pruef- und Reparaturskript zerlegen (Ueberschriften oder ```-Bloecke)
function Split-HUAiAnswer([string]$Text) {
    $blocks = @([regex]::Matches($Text, '(?s)```(?:powershell|ps1|ps)?\s*\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value.TrimEnd() })
    if ($blocks.Count -ge 2) { return [pscustomobject]@{ Detection = $blocks[0]; Remediation = $blocks[1] } }
    $m = [regex]::Match($Text, '(?s)###\s*Pr(?:ue|ü)fskript\s*\r?\n(.*?)(?:###\s*Reparaturskript\s*\r?\n(.*))?$')
    if ($m.Success) { return [pscustomobject]@{ Detection = $m.Groups[1].Value.Trim(); Remediation = $m.Groups[2].Value.Trim() } }
    if ($blocks.Count -eq 1) { return [pscustomobject]@{ Detection = $blocks[0]; Remediation = '' } }
    return [pscustomobject]@{ Detection = $Text.Trim(); Remediation = '' }
}

# ============================================================================
# Testinstallation in der Windows Sandbox
#   Quellordner wird schreibgeschuetzt eingebunden, Arbeitsordner beschreibbar. Im Sandbox-Fenster
#   laeuft HUTest.ps1: Uninstall-Eintraege vorher/nachher, Installation, optional Deinstallationstest,
#   Ergebnis nach result.json. Danach faehrt die Sandbox herunter (ausser "offen lassen").
# ============================================================================
function Test-HUSandboxAvailable { return (Test-Path -LiteralPath (Join-Path $env:windir 'System32\WindowsSandbox.exe')) }

function Enable-HUSandbox {
    $cmd = 'Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All -NoRestart; Write-Host ""; Write-Host "Fertig - bitte Windows neu starten." -ForegroundColor Green; Start-Sleep -Seconds 8'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

$script:SandboxScript = @'
$ErrorActionPreference = 'Continue'
$cfg = Get-Content -LiteralPath 'C:\HUTest\config.json' -Raw | ConvertFrom-Json
$result = [ordered]@{ ExitCode = $null; Seconds = 0; NewEntries = @(); NewFolders = @(); UninstallTested = $false; UninstallExitCode = $null; UninstallRemoved = $null; Error = ''; InstallWindows = @(); UninstallWindows = @(); InstallLog = ''; UninstallLog = ''; DesktopLinks = @() }
function Get-Snap {
    $l = @()
    foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path $p)) { continue }
        foreach ($k in Get-ChildItem $p -ErrorAction SilentlyContinue) {
            $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            $l += [pscustomobject]@{ Key = $k.Name; DisplayName = "$($v.DisplayName)"; DisplayVersion = "$($v.DisplayVersion)"; Publisher = "$($v.Publisher)"
                UninstallString = "$($v.UninstallString)"; QuietUninstallString = "$($v.QuietUninstallString)"; InstallLocation = "$($v.InstallLocation)"; DisplayIcon = "$($v.DisplayIcon)"; IconFile = '' }
        }
    }
    $l
}
function Get-Dirs { @(Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
$script:Windows = @()
# Befehl ausfuehren; Ausgabe nach C:\HUTest\logs\<Tag>-ausgabe.txt, bei msiexec ein ausfuehrliches MSI-Protokoll.
# Sichtbare Fenster neuer Prozesse merken (unter Intune wuerde ein Dialog haengen).
function Invoke-Cmd([string]$Line, [int]$Minutes, [string]$Tag = 'install') {
    New-Item -ItemType Directory -Path 'C:\HUTest\logs' -Force | Out-Null
    $run = $Line
    if ($run -match '(?i)\bmsiexec(\.exe)?\b' -and $run -notmatch '(?i)\s/l[\*a-z+!]*\s') { $run += " /l*v `"C:\HUTest\logs\$Tag-msi.log`"" }
    Set-Content -LiteralPath 'C:\HUInstall\__run.cmd' -Value "@echo off`r`n$run > `"C:\HUTest\logs\$Tag-ausgabe.txt`" 2>&1`r`nexit /b %errorlevel%" -Encoding Default
    $base = @(Get-Process | ForEach-Object { $_.Id })
    $seen = @{}
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'C:\HUInstall\__run.cmd' -WorkingDirectory 'C:\HUInstall' -PassThru -WindowStyle Hidden
    $end = (Get-Date).AddMinutes($Minutes)
    while (-not $p.HasExited) {
        foreach ($w in @(Get-Process | Where-Object { $base -notcontains $_.Id -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -and $_.ProcessName -notmatch '^(explorer|conhost|cmd|powershell|ShellExperienceHost|SearchHost|StartMenuExperienceHost)$' })) {
            $seen["$($w.ProcessName): $($w.MainWindowTitle)"] = $true
        }
        if ((Get-Date) -gt $end) { try { $p.Kill() } catch { }; $script:Windows = @($seen.Keys); return -999 }
        Start-Sleep -Milliseconds 700
    }
    $script:Windows = @($seen.Keys)
    return $p.ExitCode
}

# Protokolle seit $Since einsammeln: Befehlsausgabe, MSI-Protokoll (Fehlerzeilen), neue Log-Dateien in TEMP, MSI-Ereignisse
function Get-LogText([datetime]$Since, [string]$Tag) {
    $parts = New-Object System.Collections.Generic.List[string]
    $out = "C:\HUTest\logs\$Tag-ausgabe.txt"
    if ((Test-Path $out) -and (Get-Item $out).Length) { $parts.Add("[Ausgabe des Befehls]`r`n" + ((Get-Content $out -Tail 40) -join "`r`n")) }
    $msi = "C:\HUTest\logs\$Tag-msi.log"
    if (Test-Path $msi) {
        $all = @(Get-Content $msi -ErrorAction SilentlyContinue)
        $hits = @($all | Select-String -Pattern 'Return value 3|Fehler \d{4}|Error \d{4}|error code|CustomAction .* returned actual error' | Select-Object -First 15 | ForEach-Object { $_.Line })
        $parts.Add("[MSI-Protokoll $Tag-msi.log - Fehlerzeilen]`r`n" + $(if ($hits.Count) { $hits -join "`r`n" } else { '(keine Fehlerzeilen)' }) + "`r`n...`r`n" + (($all | Select-Object -Last 15) -join "`r`n"))
    }
    $logs = @(Get-ChildItem -Path $env:TEMP, "$env:windir\Temp" -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since -and $_.Length -lt 20MB -and $_.FullName -notmatch '\\HUTest\\' } | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    foreach ($l in $logs) {
        try { Copy-Item -LiteralPath $l.FullName -Destination "C:\HUTest\logs\$Tag-$($l.Name)" -Force } catch { }
        $parts.Add("[$($l.FullName)]`r`n" + ((Get-Content -LiteralPath $l.FullName -Tail 30 -ErrorAction SilentlyContinue) -join "`r`n"))
    }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $Since } -MaxEvents 8 -ErrorAction SilentlyContinue)
    if ($ev.Count) { $parts.Add("[Ereignisanzeige MsiInstaller]`r`n" + (@($ev | ForEach-Object { "$($_.TimeCreated.ToString('HH:mm:ss')) $($_.Id): $(($_.Message -replace '\s+', ' ').Trim())" }) -join "`r`n")) }
    $t = $parts -join "`r`n`r`n"
    if ($t.Length -gt 12000) { $t = $t.Substring(0, 12000) + "`r`n... (gekuerzt - vollstaendig im Ordner logs)" }
    return $t
}
try {
    Write-Host 'HU-MultiTenant Testinstallation' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path 'C:\HUInstall' -Force | Out-Null
    Copy-Item -Path 'C:\HUSource\*' -Destination 'C:\HUInstall' -Recurse -Force
    $before = @(Get-Snap); $dirsBefore = Get-Dirs
    $lnkDirs = @("$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'))
    $lnkBefore = @(Get-ChildItem -Path $lnkDirs -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Write-Host "Installiere: $($cfg.Install)" -ForegroundColor Yellow
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $t0 = Get-Date
    $result.ExitCode = Invoke-Cmd $cfg.Install 30 'install'
    $result.InstallWindows = @($script:Windows)
    $result.InstallLog = Get-LogText $t0 'install'
    $result.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    $keys = @($before | ForEach-Object { $_.Key })
    $after = @(Get-Snap)
    $result.NewEntries = @($after | Where-Object { $keys -notcontains $_.Key })
    $changed = @($after | Where-Object { $keys -contains $_.Key } | Where-Object { $k = $_.Key; $b = $before | Where-Object { $_.Key -eq $k } | Select-Object -First 1; $b.DisplayVersion -ne $_.DisplayVersion })
    $result.NewEntries += $changed
    # Symbole der neuen Programme als PNG ablegen (fuer das Unternehmensportal)
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -Namespace 'HUSb' -Name 'Icon' -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern uint PrivateExtractIcons(string f, int i, int cx, int cy, System.IntPtr[] h, int[] id, uint n, uint fl);'
        $n = 0
        foreach ($e in @($result.NewEntries)) {
            $n++
            $loc = "$($e.DisplayIcon)".Trim()
            if (-not $loc -and $e.InstallLocation) { $x = Get-ChildItem -LiteralPath $e.InstallLocation -Filter *.exe -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '(?i)unins|setup|update|helper|crash' } | Sort-Object Length -Descending | Select-Object -First 1; if ($x) { $loc = $x.FullName } }
            if (-not $loc) { continue }
            $idx = 0; $mm = [regex]::Match($loc, '^(.*?),\s*(-?\d+)\s*$'); if ($mm.Success) { $loc = $mm.Groups[1].Value; $idx = [int]$mm.Groups[2].Value }
            $loc = [Environment]::ExpandEnvironmentVariables($loc.Trim().Trim('"'))
            if (-not (Test-Path -LiteralPath $loc)) { continue }
            $bmp = $null
            if ($loc -match '(?i)\.ico$') { $bmp = (New-Object System.Drawing.Icon($loc, 256, 256)).ToBitmap() }
            else {
                $h = New-Object IntPtr[] 1; $id = New-Object int[] 1
                if ([HUSb.Icon]::PrivateExtractIcons($loc, $idx, 256, 256, $h, $id, 1, 0) -ge 1 -and $h[0] -ne [IntPtr]::Zero) { $bmp = ([System.Drawing.Icon]::FromHandle($h[0])).ToBitmap() }
            }
            if ($bmp) { $f = "icon_$n.png"; $bmp.Save("C:\HUTest\$f", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $e.IconFile = $f }
        }
    } catch { }
    $result.NewFolders = @(Get-Dirs | Where-Object { $dirsBefore -notcontains $_ })
    $result.DesktopLinks = @(Get-ChildItem -Path $lnkDirs -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $lnkBefore -notcontains $_.FullName } | ForEach-Object { $_.Name })
    Write-Host "Exitcode $($result.ExitCode), neue Eintraege: $(@($result.NewEntries).Count)" -ForegroundColor Green
    if ($cfg.TestUninstall -and "$($cfg.Uninstall)".Trim()) {
        Write-Host "Deinstalliere: $($cfg.Uninstall)" -ForegroundColor Yellow
        $result.UninstallTested = $true
        $t1 = Get-Date
        $result.UninstallExitCode = Invoke-Cmd $cfg.Uninstall 15 'uninstall'
        $result.UninstallWindows = @($script:Windows)
        # manche Deinstaller (NSIS) starten eine Kopie und kehren sofort zurueck -> bis 2 Minuten auf das Entfernen warten
        for ($i = 0; $i -lt 40; $i++) {
            $nowKeys = @(Get-Snap | ForEach-Object { $_.Key })
            $result.UninstallRemoved = -not @($result.NewEntries | Where-Object { $nowKeys -contains $_.Key }).Count
            if ($result.UninstallRemoved) { break }
            Start-Sleep -Seconds 3
        }
        $result.UninstallLog = Get-LogText $t1 'uninstall'
    }
} catch { $result.Error = $_.Exception.Message }
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'C:\HUTest\result.json' -Encoding UTF8
Write-Host 'Fertig.' -ForegroundColor Green
if (-not $cfg.KeepOpen) { Start-Sleep -Seconds 3; shutdown.exe /s /t 0 }
'@

function Start-HUSandboxTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$InstallCmd,
        [string]$UninstallCmd = '',
        [switch]$TestUninstall,
        [switch]$KeepOpen
    )
    if (-not (Test-HUSandboxAvailable)) { throw 'Windows Sandbox ist nicht aktiviert' }
    if (Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue) { throw 'Es laeuft bereits eine Windows Sandbox - bitte zuerst schliessen (nur eine gleichzeitig moeglich).' }
    if (Test-Path -LiteralPath $WorkFolder) { Remove-Item -LiteralPath $WorkFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'HUTest.ps1'), $script:SandboxScript, $utf8)
    $cfg = [ordered]@{ Install = $InstallCmd; Uninstall = $UninstallCmd; TestUninstall = [bool]$TestUninstall; KeepOpen = [bool]$KeepOpen }
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'config.json'), ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder><HostFolder>$(& $esc $SourceFolder)</HostFolder><SandboxFolder>C:\HUSource</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$(& $esc $WorkFolder)</HostFolder><SandboxFolder>C:\HUTest</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HUTest\HUTest.ps1</Command></LogonCommand>
</Configuration>
"@
    $wsbFile = Join-Path $WorkFolder 'HUTest.wsb'
    [IO.File]::WriteAllText($wsbFile, $wsb, (New-Object System.Text.UTF8Encoding $false))
    Start-Process -FilePath $wsbFile
    return (Join-Path $WorkFolder 'result.json')
}

# Vorschlag fuer Erkennung/Deinstallation aus dem Sandbox-Ergebnis
# Deinstallationsbefehl ohne Stummschaltung -> passenden Schalter ergaenzen (NSIS /S, Inno /VERYSILENT ...)
function Add-HUSilentUninstall([string]$Cmd, [string]$InstallerType = '') {
    $c = "$Cmd".Trim()
    if (-not $c -or $c -match '(?i)msiexec') { return $c }
    if ($c -match '(?i)(^|\s)(/S|/silent|/verysilent|/quiet|/qn|--silent|-s)(\s|$)') { return $c }
    if ($c.StartsWith('"')) { $exe = $c.Substring(1, $c.IndexOf('"', 1) - 1); $rest = $c.Substring($c.IndexOf('"', 1) + 1).Trim() }
    else { $m = [regex]::Match($c, '(?i)^(.+?\.exe)(.*)$'); if (-not $m.Success) { return $c }; $exe = $m.Groups[1].Value.Trim(); $rest = $m.Groups[2].Value.Trim() }
    $leaf = ($exe -split '[\\/]')[-1]
    $sw = ''
    if ($leaf -match '(?i)^unins\d{3}\.exe$' -or $InstallerType -eq 'Inno Setup') { $sw = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    elseif ($InstallerType -eq 'NSIS' -or $leaf -match '(?i)^(uninst|uninstall|uninstaller)\.exe$') { $sw = '/S' }
    if (-not $sw) { return $c }
    return ("`"$exe`" $rest $sw" -replace '\s+', ' ').Trim()
}

function ConvertFrom-HUSandboxEntry($Entry, [string]$InstallerType = '') {
    $key = "$($Entry.Key)"
    $is32 = $key -match '\\WOW6432Node\\'
    $kp = ($key -replace '^HKEY_CURRENT_USER', 'HKEY_CURRENT_USER') -replace '\\WOW6432Node\\', '\'
    $un = "$($Entry.QuietUninstallString)"
    if (-not $un) {
        $un = "$($Entry.UninstallString)"
        if ($un -match '(?i)msiexec(\.exe)?\s+/[ix]\s*(\{[0-9A-F-]{36}\})') { $un = "msiexec /x $($Matches[2]) /qn /norestart" }
        else { $un = Add-HUSilentUninstall $un $InstallerType }
    }
    $pc = ''
    if ((Split-Path $key -Leaf) -match '^\{[0-9A-Fa-f-]{36}\}$') { $pc = Split-Path $key -Leaf }
    $det = if ($pc) { [pscustomobject]@{ Type = 'msi'; ProductCode = $pc; Version = "$($Entry.DisplayVersion)"; VersionCheck = [bool]"$($Entry.DisplayVersion)" } }
    else { [pscustomobject]@{ Type = 'registry'; KeyPath = $kp; ValueName = $(if ("$($Entry.DisplayVersion)") { 'DisplayVersion' } else { '' }); Version = "$($Entry.DisplayVersion)"; VersionCheck = [bool]"$($Entry.DisplayVersion)"; Check32 = $is32 } }
    $icon = if ($Entry.PSObject.Properties['IconFile']) { "$($Entry.IconFile)" } else { '' }
    return [pscustomobject]@{ DisplayName = "$($Entry.DisplayName)"; Version = "$($Entry.DisplayVersion)"; Publisher = "$($Entry.Publisher)"; UninstallCmd = $un; Detection = $det; HKCU = ($key -match '^HKEY_CURRENT_USER'); IconFile = $icon }
}

# Aus den neuen Uninstall-Eintraegen den passenden waehlen (Name aehnlich, sonst der mit Deinstallationsbefehl)
function Select-HUSandboxEntry([object[]]$Entries, [string]$AppName = '') {
    $list = @($Entries | Where-Object { $_ -and "$($_.DisplayName)" })
    if (-not $list.Count) { return $null }
    $words = @(("$AppName" -split '[^\p{L}\p{N}]+') | Where-Object { $_.Length -ge 3 })
    $scored = foreach ($e in $list) {
        $n = 0
        foreach ($w in $words) { if ("$($e.DisplayName)" -match [regex]::Escape($w)) { $n += 2 } }
        if ("$($e.QuietUninstallString)$($e.UninstallString)") { $n += 1 }
        if ("$($e.DisplayName)" -match '(?i)redistributable|runtime|update for|webview2') { $n -= 3 }
        [pscustomobject]@{ E = $e; N = $n }
    }
    return (@($scored | Sort-Object N -Descending)[0].E)
}

Export-ModuleMember -Function @(
    'Invoke-HUIntuneGraph', 'Get-HUIntuneGraphAll', 'ConvertTo-HUBase64Utf8', 'Find-HUGroup', 'Find-HUManagedDevice', 'ConvertTo-HUGroupRow', 'Get-HUTenantGroups', 'ConvertTo-HUW32Row', 'Get-HUTenantWin32Apps', 'Find-HUWin32AppByName',
    'Read-HUMsiInfo', 'Get-HUExeInstallerType', 'Get-HUSetupInfo',
    'Get-HUIntuneWinAppUtil', 'New-HUIntuneWinPackage',
    'Get-HUDefaultReturnCodes', 'ConvertTo-HUDetectionRule', 'ConvertTo-HUWin32Payload',
    'Get-HUIntuneApp', 'New-HUWin32App', 'Update-HUWin32App', 'Publish-HUWin32Content', 'New-HUStoreApp',
    'Set-HUAppAssignment', 'Wait-HUAppPublished',
    'Get-HUAppKindFromType', 'Get-HUGroupNames', 'ConvertFrom-HUAssignment', 'Get-HUTenantAppList', 'Remove-HUAppAssignments', 'Update-HUAppProperties',
    'Get-HUAppIconBytes', 'Get-HUAppRelationRows', 'Set-HUAppRelations', 'Remove-HUIntuneApp', 'Invoke-HUExportReport', 'Get-HUErrorText', 'Get-HUAppInstallStatus',
    'ConvertTo-HURemediationPayload', 'Publish-HURemediation', 'New-HURunSchedule', 'Set-HURemediationAssignment',
    'Get-HURemediationRunStates', 'Start-HURemediationOnDevice', 'Test-HURemediationScript', 'Get-HUAiPrompt', 'Split-HUAiAnswer',
    'Test-HUSandboxAvailable', 'Enable-HUSandbox', 'Start-HUSandboxTest', 'ConvertFrom-HUSandboxEntry',
    'Get-HUWorkPath', 'Sync-HUAppSource', 'Get-HUAppPackage', 'Resolve-HUTargets', 'Test-HUStoreId', 'Get-HUStoreIdFromText', 'Get-HUStoreAppInfo', 'Add-HUSilentUninstall',
    'New-HUInstallWrapper', 'Get-HUInstallPlan', 'New-HUWin32Def', 'Publish-HUWin32App', 'Get-HUDependencyBody', 'Set-HUAppDependencies',
    'ConvertTo-HUIconPng', 'Get-HUIconContent', 'Save-HUStoreAppIcon', 'Split-HUIconLocation', 'Select-HUSandboxEntry'
)
