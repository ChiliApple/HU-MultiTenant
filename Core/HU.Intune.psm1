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
        [switch]$V1,
        [switch]$NoRetry
    )
    $max = if ($NoRetry) { 1 } else { 4 }
    for ($try = 1; $try -le $max; $try++) {
        $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop
        if (-not $tok) { throw "Kein Token fuer '$TenantKey' (Secret pruefen)" }
        $ver = if ($V1) { 'v1.0' } else { 'beta' }
        $r = Invoke-HUGraphRaw -Token $tok -Endpoint $Endpoint -Method $Method -Body $Body -Version $ver
        if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
            # Anlegen (POST): nur bei 429/503 wiederholen - bei 500/502/504 kann Intune das Objekt trotzdem angelegt haben (sonst Duplikate)
            $retryCodes = if ($Method -eq 'POST') { @(429, 503) } else { @(429, 500, 502, 503, 504) }
            if ($r.StatusCode -in $retryCodes -and $try -lt $max) {
                # 429: Retry-After von Intune beachten; Serverfehler: kurz warten (2, 4, 6 s)
                $wait = if ($r.StatusCode -eq 429 -and $r.RetryAfter -gt 0) { [Math]::Min(30, $r.RetryAfter) } elseif ($r.StatusCode -eq 429) { 5 * $try } else { 2 * $try }
                Start-Sleep -Seconds $wait; continue
            }
            $ex = New-Object System.Exception("Graph $Method $($Endpoint -replace '\?.*$', ''): $($r.ErrorMessage)")
            $ex.Data['StatusCode'] = [int]$r.StatusCode
            throw $ex
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
        $json = if ($Body) { $Body | ConvertTo-Json -Depth 50 -Compress } else { '{}' }
        $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $res = Invoke-RestMethod @p
        # PS 5.1: grosse Antworten (> 2 MB) liefert Invoke-RestMethod als Text statt als Objekt
        if ($res -is [string] -and $res.TrimStart().StartsWith('{')) { $res = $res | ConvertFrom-Json }
        return $res
    }
    catch {
        $code = $null; $msg = $_.Exception.Message; $ra = 0
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $ra = [int]"$($_.Exception.Response.Headers['Retry-After'])" } catch { }
            try {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $j = $sr.ReadToEnd() | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($j.error.message) { $msg = "$code - $($j.error.code): $($j.error.message)" }
            } catch { }
        }
        return [pscustomobject]@{ IsError = $true; StatusCode = $code; ErrorMessage = $msg; Endpoint = $Endpoint; Method = $Method; RetryAfter = $ra }
    }
}

function Get-HUIntuneGraphAll {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Endpoint, [switch]$V1)
    $out = New-Object System.Collections.Generic.List[object]
    $next = $Endpoint
    $n = 0
    $prev = ''
    while ($next -and $n -lt 500) {
        $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $next -V1:$V1
        foreach ($v in @($r.value)) { if ($null -ne $v) { $out.Add($v) } }
        $prev = $next
        $next = $r.'@odata.nextLink'
        if ($next -and $next -eq $prev) { throw "Graph $($Endpoint -replace '\?.*$', ''): Seitenabruf haengt (gleicher nextLink) - Ergebnis unvollstaendig" }
        $n++
    }
    # Teilergebnis nie still zurueckgeben (sonst gilt Fehlendes als 'fehlt' oder 'geloescht')
    if ($next) { throw "Graph $($Endpoint -replace '\?.*$', ''): mehr als $n Seiten - Ergebnis unvollstaendig" }
    return $out.ToArray()
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
    $hit = @($r.value)
    # gleichnamige Gruppen: nicht raten (sonst landet die Zuweisung bei der falschen Gruppe)
    if ($hit.Count -gt 1) { throw "Gruppe '$Name' gibt es $($hit.Count)-mal in diesem Tenant - bitte eindeutig benennen" }
    return ($hit | Select-Object -First 1)
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
        @{ Type = 'Inno Setup'; Pattern = 'Inno Setup'; Silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /ALLUSERS' }
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
    # Skript als Setup (z. B. Plugin-Installer ohne MSI/EXE): Name/Version aus dem Ordnernamen ("HUScroll-0.5.2"),
    # Schalter -AllUsers/-Uninstall uebernehmen, wenn das Skript sie hat. Ganzer Ordner wird mitgepackt.
    if ($file.Extension -match '(?i)^\.(ps1|cmd|bat)$') {
        $dirName = Split-Path $file.DirectoryName -Leaf
        $ver = ''; $nm = [IO.Path]::GetFileNameWithoutExtension($name)
        if ($dirName -notmatch '(?i)^(downloads|desktop|documents|dokumente)$') {
            if ($dirName -match '^(.+?)[\s_\-]+v?(\d+(?:\.\d+){1,3})$') { $nm = $Matches[1]; $ver = $Matches[2] } else { $nm = $dirName }
        }
        if ($file.Extension -ieq '.ps1') {
            $params = @()
            try {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                if ($ast.ParamBlock) { $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
            } catch { }
            $base = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$name`""
            if ($params -contains 'AllUsers') { $base += ' -AllUsers' }
            $un = if ($params -contains 'Uninstall') { "$base -Uninstall" } else { '' }
            $hint = 'PowerShell-Skript: der ganze Ordner wird mitgepackt. Erkennung (z. B. Datei) selbst festlegen.'
            if ($params -contains 'AllUsers') { $hint += ' Schalter -AllUsers uebernommen.' }
            if (-not $un) { $hint += ' Deinstallationsbefehl fehlt - selbst eintragen.' }
            $hint += ' Intune startet das Skript in einer 32-Bit-PowerShell - Pfade unter Program Files beachten.'
            return [pscustomobject]@{
                Kind = 'script'; FileName = $name; Name = $nm; Publisher = ''; Version = $ver; ProductCode = ''; UpgradeCode = ''; InstallerType = 'PowerShell'
                InstallCmd = $base; UninstallCmd = $un; Detection = $null; Hint = $hint
            }
        }
        return [pscustomobject]@{
            Kind = 'script'; FileName = $name; Name = $nm; Publisher = ''; Version = $ver; ProductCode = ''; UpgradeCode = ''; InstallerType = 'Batch'
            InstallCmd = "cmd.exe /c `"$name`""; UninstallCmd = ''; Detection = $null
            Hint = 'Batch-Datei: der ganze Ordner wird mitgepackt. Deinstallationsbefehl und Erkennung selbst festlegen.'
        }
    }
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
#        Restart (suppress|basedOnReturnCode|allow|force), Detection (Type msi|registry|file|script ...), Kind (msi|exe|script)
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
    if ($Def.PSObject.Properties['Owner'] -and "$($Def.Owner)".Trim()) { $p.owner = "$($Def.Owner)".Trim() }
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
        if ($h.Kind -in 'group', 'exclude') {
            $g = Find-HUGroup -TenantKey $TenantKey -Settings $Settings -Name "$($t.GroupName)"
            if (-not $g) { throw "Gruppe '$($t.GroupName)' gibt es in diesem Tenant nicht" }
            $h.GroupId = "$($g.id)"; $h.Label = $(if ($h.Kind -eq 'exclude') { "Ausschluss '$($g.displayName)'" } else { "Gruppe '$($g.displayName)'" })
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

# $true, wenn das Bild nach Rauschen aussieht: mittlerer Farbsprung zwischen Nachbarpixeln (deckende Pixel) sehr hoch.
# Echte Symbole liegen bei ca. 5-30, Rauschen bei 200+ (Summe der RGB-Differenzen, max. 765).
function Test-HUIconNoise($Bitmap) {
    $w = $Bitmap.Width; $h = $Bitmap.Height
    if ($w -lt 2) { return $false }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = New-Object byte[] ($data.Stride * $h)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    } finally { $Bitmap.UnlockBits($data) }
    $sum = 0; $n = 0
    $step = [Math]::Max(1, [int]($h / 64))
    for ($y = 0; $y -lt $h; $y += $step) {
        $row = $y * $data.Stride
        for ($x = 0; $x -lt $w - 1; $x++) {
            $i = $row + 4 * $x
            if ($bytes[$i + 3] -lt 128 -or $bytes[$i + 7] -lt 128) { continue }
            $sum += [Math]::Abs($bytes[$i] - $bytes[$i + 4]) + [Math]::Abs($bytes[$i + 1] - $bytes[$i + 5]) + [Math]::Abs($bytes[$i + 2] - $bytes[$i + 6])
            $n++
        }
    }
    if ($n -lt 20) { return $false }
    return (($sum / $n) -gt 120)
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
        # manche Programme liefern beim Auslesen nur Bildrauschen -> nicht uebernehmen (vorhandenes Symbol bleibt)
        if (Test-HUIconNoise $out) { $out.Dispose(); throw 'Symbol unbrauchbar (nur Bildrauschen) - bitte ein Bild oder die Setup-Datei waehlen' }
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
# HU-MultiTenant: Installation ohne neue Desktop-Verknuepfungen. Protokoll: %ProgramData%\HU-MultiTenant\Logs\HU-Install.log
`$log = Join-Path `$env:ProgramData 'HU-MultiTenant\Logs\HU-Install.log'
try { New-Item -ItemType Directory -Path (Split-Path `$log) -Force | Out-Null } catch { }
function W([string]`$t) { try { Add-Content -LiteralPath `$log -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), `$t) -Encoding UTF8 } catch { } }
`$dirs = @("`$env:PUBLIC\Desktop", [Environment]::GetFolderPath('Desktop'), "`$env:SystemDrive\Users\Default\Desktop") | Where-Object { `$_ } | Select-Object -Unique
`$before = @(Get-ChildItem -Path `$dirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | ForEach-Object { `$_.FullName })
`$gone = `$false
W ('Start: ' + '$c')
`$p = Start-Process -FilePath "`$env:ComSpec" -ArgumentList '/c', ('"' + '$c' + '"') -WorkingDirectory `$PSScriptRoot -WindowStyle Hidden -Wait -PassThru
W "Setup beendet, Exitcode `$(`$p.ExitCode)"
# manche Setups legen Verknuepfungen erst kurz nach dem Ende an -> 30 s lang nachsehen
for (`$i = 0; `$i -lt 15; `$i++) {
    foreach (`$l in @(Get-ChildItem -Path `$dirs -Filter *.lnk -Force -ErrorAction SilentlyContinue | Where-Object { `$before -notcontains `$_.FullName })) {
        try { Remove-Item -LiteralPath `$l.FullName -Force -ErrorAction Stop; W "Desktop-Verknuepfung entfernt: `$(`$l.FullName)"; `$gone = `$true } catch { W "Nicht entfernt: `$(`$l.FullName) - `$(`$_.Exception.Message)" }
    }
    Start-Sleep -Seconds 2
}
# Desktop neu zeichnen lassen (sonst bleibt ein leeres Symbol stehen, bis jemand F5 drueckt)
if (`$gone) { try { Add-Type -Namespace HU -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b);'; [HU.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) } catch { } }
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
# App-Kategorien (Unternehmensportal) per Name setzen. Nur vorhandene Kategorien - fehlende werden gemeldet, nicht angelegt.
# Gesetzt wird genau die Liste; leere Liste = nichts aendern. Rueckgabe: Text fuer das Protokoll.
function Get-HUTenantAppCategories([string]$TenantKey, $Settings) {
    return @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceAppManagement/mobileAppCategories' | ForEach-Object { [pscustomobject]@{ Id = "$($_.id)"; Name = "$($_.displayName)" } })
}

function New-HUAppCategory([string]$TenantKey, $Settings, [string]$Name) {
    $n = "$Name".Trim()
    if (-not $n) { throw 'Kategoriename fehlt' }
    if (@(Get-HUTenantAppCategories $TenantKey $Settings | Where-Object { $_.Name -eq $n }).Count) { return $false }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceAppManagement/mobileAppCategories' -Method POST -Body @{ '@odata.type' = '#microsoft.graph.mobileAppCategory'; displayName = $n })
    return $true
}

function Remove-HUAppCategory([string]$TenantKey, $Settings, [string]$Name) {
    $hit = @(Get-HUTenantAppCategories $TenantKey $Settings | Where-Object { $_.Name -eq "$Name".Trim() })
    if ($hit.Count -gt 1) { throw "Kategorie '$Name' gibt es $($hit.Count)-mal - nicht geloescht, bitte im Intune-Portal bereinigen" }
    foreach ($h in $hit) { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileAppCategories/$($h.Id)" -Method DELETE) }
    return [bool]$hit.Count
}

function Get-HUAppCategoryNames([string]$TenantKey, $Settings, [string]$AppId) {
    return @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/categories" | ForEach-Object { "$($_.displayName)" } | Sort-Object)
}

function Set-HUAppCategories {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [string[]]$Names = @())
    $want = @($Names | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $want.Count) { return '' }
    $all = @(Get-HUTenantAppCategories $TenantKey $Settings)
    $ids = @(); $missing = @(); $set = @()
    foreach ($n in $want) {
        $hit = @($all | Where-Object { $_.Name -eq $n })[0]
        if ($hit) { $ids += $hit.Id; $set += $n } else { $missing += $n }
    }
    # keine einzige passende Kategorie -> nichts aendern (sonst wuerden vorhandene entfernt)
    if (-not $ids.Count) { return "Kategorien: in diesem Tenant nicht vorhanden: $($missing -join ', ') - nichts geaendert" }
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/categories" | ForEach-Object { "$($_.id)" })
    foreach ($id in $ids) {
        if ($cur -notcontains $id) {
            [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/categories/`$ref" -Method POST -Body @{ '@odata.id' = "https://graph.microsoft.com/beta/deviceAppManagement/mobileAppCategories/$id" })
        }
    }
    foreach ($id in $cur) {
        if ($ids -notcontains $id) { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/categories/$id/`$ref" -Method DELETE) }
    }
    return "Kategorien: $($set -join ', ')$(if ($missing.Count) { " (in diesem Tenant nicht vorhanden: $($missing -join ', '))" })"
}

# Autor aus den Einstellungen (ui.author) - fuer Besitzer der Apps und Herausgeber der Wartungsskripte
function Get-HUAuthor($Settings, [string]$Default = '') {
    $a = ''
    try { if ($Settings -and $Settings.ui -and $Settings.ui.PSObject.Properties['author']) { $a = "$($Settings.ui.author)".Trim() } } catch { }
    if ($a) { return $a }
    return $Default
}

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
    $w32 | Add-Member -NotePropertyName Owner -NotePropertyValue (Get-HUAuthor $Settings) -Force
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
        try { [void](Publish-HUWin32Content -TenantKey $TenantKey -Settings $Settings -AppId $AppId -Package $Package) }
        catch {
            # App ist angelegt, nur der Inhalt fehlt: AppId mitgeben, damit der naechste Versuch dieselbe App aktualisiert (statt eine zweite anzulegen)
            $ex = New-Object System.Exception("$($Def.Name): Paket-Upload fehlgeschlagen ($($_.Exception.Message)) - die App ist in Intune angelegt, der naechste Versuch laedt das Paket erneut hoch", $_.Exception)
            $ex.Data['AppId'] = $AppId
            throw $ex
        }
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
    $own = Get-HUAuthor $Settings
    if ($own) { $body.owner = $own }
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
    if (-not $ids.Count) { return $map }
    # getByIds braucht Directory.Read.All - mit Group.Read.All stattdessen die Gruppenliste lesen
    try {
        for ($i = 0; $i -lt $ids.Count; $i += 1000) {
            $chunk = @($ids[$i..([Math]::Min($i + 999, $ids.Count - 1))])
            $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/directoryObjects/getByIds' -Method POST -Body @{ ids = $chunk; types = @('group') } -V1
            foreach ($g in @($r.value)) { $map["$($g.id)"] = "$($g.displayName)" }
        }
        return $map
    } catch { }
    try {
        foreach ($g in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/groups?$select=id,displayName&$top=999' -V1)) { $map["$($g.id)"] = "$($g.displayName)" }
    } catch { Write-HULog -Message "Gruppennamen nicht lesbar (Group.Read.All?) - es werden IDs angezeigt" -Level 'WARN' -Tenant $TenantKey }
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
    Write-HULog -Message "$($all.Count) App(s) gelesen, davon $($win.Count) fuer Windows" -Level 'INFO' -Tenant $TenantKey
    foreach ($a in $win) {
        $t = ("$($a.'@odata.type')" -replace '^#?microsoft\.graph\.', '')
        [pscustomobject]@{
            Name = "$($a.displayName)"; Typ = $script:WinAppTypes[$t]; OType = $t; Kind = (Get-HUAppKindFromType $t)
            Version = "$($a.displayVersion)"; Publisher = "$($a.publisher)"; Description = "$($a.description)"; Id = "$($a.id)"
            Modified = "$($a.lastModifiedDateTime)"; State = "$($a.publishingState)"; IsAssigned = [bool]$a.isAssigned
            Assignments = @(@($a.assignments) | Where-Object { $_ } | ForEach-Object { ConvertFrom-HUAssignment $_ $names })
        }
    }
}

# Installationsstand einer App (Anzahl Geraete) - derselbe Bericht wie im Intune-Portal (getAppStatusOverviewReport).
# Rueckgabe: Text; "noch keine Rueckmeldung", wenn Intune noch keine Daten hat; leer bei Fehler (Grund im Protokoll).
# (installSummary liefert bei Win32/Store-Apps "Resource not found" und wird nicht mehr verwendet.)
function Get-HUAppInstallSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    try {
        $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/reports/getAppStatusOverviewReport' -Method POST -Body @{ filter = "(ApplicationId eq '$AppId')" } -NoRetry
        if ($r -is [byte[]]) { $r = [Text.Encoding]::UTF8.GetString($r) }
        if ($r -is [string]) { $r = $r | ConvertFrom-Json }
    } catch { Write-HULog -Message "Installationsstand nicht lesbar: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey; return '' }
    $cols = @($r.Schema | ForEach-Object { "$($_.Column)" })
    $row = @($r.Values)[0]
    if (-not $cols.Count -or -not $row) { return 'noch keine Rueckmeldung von Geraeten' }
    $vals = @{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $vals[$cols[$i]] = $row[$i] }
    $get = { param($n) $k = @($vals.Keys | Where-Object { $_ -ieq $n })[0]; if ($k) { [int]"0$($vals[$k])" } else { $null } }
    $parts = @()
    foreach ($m in @(@('InstalledDeviceCount', 'installiert'), @('FailedDeviceCount', 'fehlgeschlagen'), @('PendingInstallDeviceCount', 'ausstehend'), @('NotInstalledDeviceCount', 'nicht installiert'), @('NotApplicableDeviceCount', 'nicht zutreffend'))) {
        $v = & $get $m[0]
        if ($null -ne $v -and ($v -gt 0 -or $m[0] -in 'InstalledDeviceCount', 'FailedDeviceCount')) { $parts += "$($m[1]) $v" }
    }
    if (-not $parts.Count) { Write-HULog -Message "Installationsstand: unbekannte Spalten ($($cols -join ', '))" -Level 'WARN' -Tenant $TenantKey; return '' }
    return ($parts -join ' | ')
}

# Zuweisungen einer App direkt lesen (genauer als $expand in der Liste)
function Get-HUAppAssignmentRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assignments")
    $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids @($cur | ForEach-Object { $_.target.groupId })
    foreach ($a in $cur) { ConvertFrom-HUAssignment $a $names }
}

# Zuweisungen entfernen, deren Key (Art|Gruppenname) in -Keys steht
# Zuweisungen werden ueber den Gruppennamen gewaehlt: zeigt ein Name auf mehrere Gruppen, nichts entfernen
function Assert-HUAssignmentKeysUnique([object[]]$Rows, [string[]]$Keys) {
    foreach ($k in $Keys) {
        $ids = @($Rows | Where-Object { $_.Key -eq $k -and $_.GroupId } | ForEach-Object { $_.GroupId } | Select-Object -Unique)
        if ($ids.Count -gt 1) { throw "Zuweisung '$(($k -split '\|', 2)[-1])' gibt es fuer $($ids.Count) gleichnamige Gruppen - nicht entfernt. Bitte im Intune-Portal entfernen oder die Gruppen eindeutig benennen" }
    }
}

function Remove-HUAppAssignments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string[]]$Keys)
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/assignments")
    $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids @($cur | ForEach-Object { $_.target.groupId })
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = 0
    Assert-HUAssignmentKeysUnique -Rows @($cur | ForEach-Object { ConvertFrom-HUAssignment $_ $names }) -Keys $Keys
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

# Beziehungen der App: eigene (Abhaengigkeiten, Ersetzungen) und umgekehrte (wird benoetigt von, ersetzt durch - nur Anzeige)
function Get-HUAppRelationRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    foreach ($r in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceAppManagement/mobileApps/$AppId/relationships")) {
        $par = ("$($r.targetType)" -eq 'parent')
        $isDep = "$($r.'@odata.type')" -match 'Dependency'
        [pscustomobject]@{
            Parent = $par
            Art = $(if ($par) { $(if ($isDep) { 'Benoetigt von' } else { 'Ersetzt durch' }) } elseif ($isDep) { 'Abhaengigkeit' } else { 'Ersetzt' }); TargetId = "$($r.targetId)"; App = "$($r.targetDisplayName)"; Version = "$($r.targetDisplayVersion)"
            Typ = $(if ($isDep) { $(if ($r.dependencyType -eq 'detect') { 'nur pruefen' } else { 'automatisch installieren' }) } else { $(if ($r.supersedenceType -eq 'replace') { 'ersetzen (alte deinstallieren)' } else { 'aktualisieren' }) })
            Raw = $(if ($isDep) { @{ '@odata.type' = '#microsoft.graph.mobileAppDependency'; targetId = "$($r.targetId)"; dependencyType = "$($r.dependencyType)" } } else { @{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = "$($r.targetId)"; supersedenceType = "$($r.supersedenceType)" } })
            Key = "$(if ($par) { 'par' } elseif ($isDep) { 'dep' } else { 'sup' })|$("$($r.targetDisplayName)".ToLower())"
        }
    }
}

# Beziehungen aendern: -Add @(@{ Art = 'dep'|'sup'; TargetId; Type = 'autoInstall'|'detect'|'update'|'replace' }), -RemoveKeys 'dep|name'
function Set-HUAppRelations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId, [object[]]$Add = @(), [string[]]$RemoveKeys = @())
    $rows = @(Get-HUAppRelationRows -TenantKey $TenantKey -Settings $Settings -AppId $AppId | Where-Object { -not $_.Parent })
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
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$ReportName, [string]$Filter = '', [string[]]$Select = @(), [int]$MaxSeconds = 180, [string]$Localization = '')
    $body = @{ reportName = $ReportName; format = 'csv' }
    if ($Localization) { $body.localizationType = $Localization }
    if ($Filter) { $body.filter = $Filter }
    if ($Select.Count) { $body.select = $Select }
    $job = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/reports/exportJobs' -Method POST -Body $body
    $start = Get-Date
    while ("$($job.status)" -ne 'completed') {
        if ("$($job.status)" -eq 'failed') { throw "Report $ReportName fehlgeschlagen" }
        if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds) { throw "Report ${ReportName}: Zeitueberschreitung" }
        Start-Sleep -Seconds 3
        # einzelne 503 beim Abfragen des Berichtsstatus sind bei Intune normal -> weiter warten
        try { $job = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/reports/exportJobs('$($job.id)')" }
        catch { if (((Get-Date) - $start).TotalSeconds -gt $MaxSeconds) { throw }; Start-Sleep -Seconds 5 }
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
        '0X87D300C9' = 'Intune hat das Warten aufgegeben (Setup lief zu lange / wartete auf Eingabe) - stille Schalter pruefen'
    }
    if ($map.ContainsKey($h)) { return $map[$h] }
    return ''
}

function ConvertTo-HUInstallStateText([string]$State) {
    # Zahlen laut Intune resultantAppState (unsicher, Fallback falls der Report keine Texte liefert)
    $v = "$State".Trim()
    $map = @{
        '1' = 'Installiert'; 'installed' = 'Installiert'
        '2' = 'Fehlgeschlagen'; 'failed' = 'Fehlgeschlagen'
        '3' = 'Nicht installiert'; 'not installed' = 'Nicht installiert'; 'notinstalled' = 'Nicht installiert'
        '4' = 'Deinstallation fehlgeschlagen'; 'uninstall failed' = 'Deinstallation fehlgeschlagen'; 'uninstallfailed' = 'Deinstallation fehlgeschlagen'
        '5' = 'Installation ausstehend'; 'install pending' = 'Installation ausstehend'; 'pending install' = 'Installation ausstehend'; 'pendinginstall' = 'Installation ausstehend'
        '99' = 'Unbekannt'; 'unknown' = 'Unbekannt'
        '-1' = 'Nicht anwendbar'; 'not applicable' = 'Nicht anwendbar'; 'notapplicable' = 'Nicht anwendbar'
    }
    $k = $v.ToLower()
    if ($map.ContainsKey($k)) { return $map[$k] }
    return $v
}

function Get-HUReportValue($Row, [string]$Name) {
    # bevorzugt die lokalisierte Spalte (<Name>_loc), sonst den Rohwert
    $loc = $Row.PSObject.Properties["${Name}_loc"]
    if ($loc -and "$($loc.Value)".Trim()) { return "$($loc.Value)" }
    $p = $Row.PSObject.Properties[$Name]
    if ($p) { return "$($p.Value)" }
    return ''
}

function Get-HUAppInstallStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$AppId)
    $rows = Invoke-HUExportReport -TenantKey $TenantKey -Settings $Settings -ReportName 'DeviceInstallStatusByApp' -Filter "(ApplicationId eq '$AppId')" `
        -Select @('DeviceName', 'UserPrincipalName', 'Platform', 'AppVersion', 'InstallState', 'InstallStateDetail', 'HexErrorCode', 'LastModifiedDateTime') `
        -Localization 'LocalizedValuesAsAdditionalColumn'
    foreach ($r in $rows) {
        $detail = Get-HUReportValue $r 'InstallStateDetail'
        if ($detail -match '^-?\d+$') { $detail = '' }   # reine Zahlencodes ohne Text sagen nichts aus
        [pscustomobject][ordered]@{
            Geraet   = "$($r.DeviceName)"
            Benutzer = "$($r.UserPrincipalName)"
            Status   = (ConvertTo-HUInstallStateText (Get-HUReportValue $r 'InstallState'))
            Detail   = $detail
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
            # Bereichsmarkierungen (Scope-Tags) aus dem Portal nicht ueberschreiben - nur beim Neuanlegen setzen
            $body.Remove('roleScopeTagIds')
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
        # Ausschluss: kein Zeitplan
        if ("$($t.Kind)" -eq 'exclude') { $list[(Get-HUTargetKey $tg)] = @{ target = $tg; runRemediationScript = $false; runSchedule = $null }; continue }
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
# Wartung "In Intune": vorhandene Wartungsskripte lesen, aendern, loeschen
# ============================================================================
function ConvertFrom-HUBase64Text([string]$B64) {
    if (-not "$B64".Trim()) { return '' }
    try { $b = [Convert]::FromBase64String("$B64") } catch { return '' }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return (New-Object System.Text.UTF8Encoding $false).GetString($b, 3, $b.Length - 3) }
    return (New-Object System.Text.UTF8Encoding $false).GetString($b)
}

# runSchedule -> Felder (Type daily|hourly|once, Interval, Time HH:mm, Date TT.MM.JJJJ) und Text
function ConvertFrom-HURunSchedule($S) {
    $r = [ordered]@{ Type = 'daily'; Interval = 1; Time = '08:00'; Date = ''; Text = '' }
    if (-not $S) { $r.Text = '(kein Zeitplan)'; return [pscustomobject]$r }
    $type = "$($S.'@odata.type')"
    $iv = 1; if ([int]::TryParse("$($S.interval)", [ref]$iv)) { $r.Interval = [Math]::Max(1, $iv) }
    if ("$($S.time)" -match '^(\d{1,2}):(\d{2})') { $r.Time = '{0:00}:{1}' -f [int]$Matches[1], $Matches[2] }
    $utc = $(if ($S.useUtc) { ' (UTC)' } else { '' })
    if ($type -match 'Hourly') { $r.Type = 'hourly'; $r.Text = "alle $($r.Interval) Std." }
    elseif ($type -match 'RunOnce') {
        $r.Type = 'once'
        if ("$($S.date)" -match '^(\d{4})-(\d{2})-(\d{2})') { $r.Date = "$($Matches[3]).$($Matches[2]).$($Matches[1])" }
        $r.Text = "einmal am $($r.Date) um $($r.Time)$utc"
    } else { $r.Text = "$(if ($r.Interval -gt 1) { "alle $($r.Interval) Tage" } else { 'taeglich' }) um $($r.Time)$utc" }
    return [pscustomobject]$r
}

# Zuweisung eines Wartungsskripts -> lesbare Zeile; Key = Art|Gruppenname wie bei Apps
function ConvertFrom-HURemAssignment($A, [hashtable]$Names = @{}) {
    $b = ConvertFrom-HUAssignment ([pscustomobject]@{ target = $A.target; intent = ''; settings = $null }) $Names
    $sc = ConvertFrom-HURunSchedule $A.runSchedule
    return [pscustomobject]@{
        Key = $b.Key; Kind = $b.Kind; GroupId = $b.GroupId; GroupName = $b.GroupName; Ziel = $b.Ziel
        Zeitplan = $(if ($b.Kind -eq 'exclude') { '' } else { $sc.Text }); Reparatur = $(if ($b.Kind -eq 'exclude') { '' } elseif ($A.runRemediationScript) { 'ja' } else { 'nein' })
        Schedule = $sc
    }
}

# Alle Wartungsskripte eines Tenants (mit Zuweisungen, wenn Intune $expand erlaubt)
function Get-HUTenantRemediationList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $withAsg = $true
    try { $all = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/deviceHealthScripts?$expand=assignments') }
    catch {
        if ("$($_.Exception.Message)" -match '403|Forbidden|Authorization') { throw }
        $withAsg = $false
        $all = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/deviceHealthScripts')
    }
    $names = @{}
    if ($withAsg) {
        $gids = @($all | ForEach-Object { @($_.assignments) } | Where-Object { $_ } | ForEach-Object { $_.target.groupId } | Where-Object { $_ })
        if ($gids.Count) { $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids $gids }
    }
    Write-HULog -Message "$($all.Count) Wartungsskript(e) gelesen" -Level 'INFO' -Tenant $TenantKey
    foreach ($s in $all) {
        [pscustomobject]@{
            Name = "$($s.displayName)"; Description = "$($s.description)"; Publisher = "$($s.publisher)"; Id = "$($s.id)"
            RunAs = $(if ("$($s.runAsAccount)" -eq 'user') { 'user' } else { 'system' }); RunAs32 = [bool]$s.runAs32Bit
            Global = [bool]$s.isGlobalScript; Version = "$($s.version)"; Modified = "$($s.lastModifiedDateTime)"
            HasRemediation = $(if ($s.PSObject.Properties['remediationScriptContent']) { [bool]"$($s.remediationScriptContent)".Trim() } else { $null })
            AssignKnown = $withAsg
            Assignments = @(if ($withAsg) { @($s.assignments) | Where-Object { $_ } | ForEach-Object { ConvertFrom-HURemAssignment $_ $names } })
        }
    }
}

# Skripte, Zuweisungen und Zusammenfassung eines Wartungsskripts
function Get-HURemediationDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id)
    $s = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id"
    $asg = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/assignments")
    $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids @($asg | ForEach-Object { $_.target.groupId })
    $sum = ''
    try {
        $x = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/runSummary" -NoRetry
        if ($x) {
            $err = [int]"0$($x.detectionScriptErrorDeviceCount)" + [int]"0$($x.remediationScriptErrorDeviceCount)"
            $sum = "ohne Problem $([int]"0$($x.noIssueDetectedDeviceCount)") | Problem $([int]"0$($x.issueDetectedDeviceCount)") | behoben $([int]"0$($x.issueRemediatedDeviceCount)") | wieder aufgetreten $([int]"0$($x.issueReoccurredDeviceCount)") | Fehler $err | ausstehend $([int]"0$($x.detectionScriptPendingDeviceCount)")"
            try { if ($x.lastScriptRunDateTime) { $sum += " | letzter Lauf $(([datetime]$x.lastScriptRunDateTime).ToLocalTime().ToString('dd.MM. HH:mm'))" } } catch { }
        }
    } catch { }
    return [pscustomobject]@{
        Tenant = $TenantKey; Id = $Id; Name = "$($s.displayName)"; Description = "$($s.description)"; Publisher = "$($s.publisher)"
        RunAs = $(if ("$($s.runAsAccount)" -eq 'user') { 'user' } else { 'system' }); RunAs32 = [bool]$s.runAs32Bit; Global = [bool]$s.isGlobalScript
        Detection = (ConvertFrom-HUBase64Text "$($s.detectionScriptContent)"); Remediation = (ConvertFrom-HUBase64Text "$($s.remediationScriptContent)")
        Assignments = @($asg | ForEach-Object { ConvertFrom-HURemAssignment $_ $names }); Summary = $sum
    }
}

# Zuweisungen entfernen, deren Key (Art|Gruppenname) in -Keys steht
function Remove-HURemediationAssignments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string[]]$Keys)
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/assignments")
    $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids @($cur | ForEach-Object { $_.target.groupId })
    $keep = New-Object System.Collections.Generic.List[object]
    $removed = 0
    Assert-HUAssignmentKeysUnique -Rows @($cur | ForEach-Object { ConvertFrom-HURemAssignment $_ $names }) -Keys $Keys
    foreach ($a in $cur) {
        if ($Keys -contains (ConvertFrom-HURemAssignment $a $names).Key) { $removed++; continue }
        $keep.Add(@{ target = $a.target; runRemediationScript = [bool]$a.runRemediationScript; runSchedule = $a.runSchedule })
    }
    if ($removed) { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id/assign" -Method POST -Body @{ deviceHealthScriptAssignments = @($keep.ToArray()) }) }
    return $removed
}

# Felder aendern (nur die uebergebenen Schluessel: Name, Description, RunAs, RunAs32, Detection, Remediation)
function Update-HURemediation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Values)
    $body = @{ '@odata.type' = '#microsoft.graph.deviceHealthScript' }
    if ($Values.ContainsKey('Name')) { $body.displayName = "$($Values.Name)" }
    if ($Values.ContainsKey('Description')) { $body.description = "$($Values.Description)" }
    if ($Values.ContainsKey('RunAs')) { $body.runAsAccount = $(if ("$($Values.RunAs)" -eq 'user') { 'user' } else { 'system' }) }
    if ($Values.ContainsKey('RunAs32')) { $body.runAs32Bit = [bool]$Values.RunAs32 }
    if ($Values.ContainsKey('Detection')) { $body.detectionScriptContent = (ConvertTo-HUBase64Utf8 "$($Values.Detection)") }
    if ($Values.ContainsKey('Remediation')) { $body.remediationScriptContent = (ConvertTo-HUBase64Utf8 "$($Values.Remediation)") }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id" -Method PATCH -Body $body)
}

function Remove-HURemediation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id)
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceHealthScripts/$Id" -Method DELETE)
}

# ============================================================================
# Pruefung eines Wartungsskripts (ohne Ausfuehrung)
# ============================================================================
# @param-Felder der Wartungsskripte (gemeinsam mit Quick Script)
. (Join-Path $PSScriptRoot 'HU.QSParams.ps1')

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
    foreach ($x in @(Test-HURemParams $Code $name)) { & $add $x.Stufe $x.Hinweis }
    $rx = @(
        @{ P = '(?im)\b(Restart-Computer|Stop-Computer)\b|\bshutdown(\.exe)?\s+[/-][rs]'; L = 'Fehler'; T = 'Kein Neustart/Herunterfahren in Wartungsskripten (Intune-Vorgabe).' }
        @{ P = '(?im)\b(Read-Host|Out-GridView|Pause)\b|\[Console\]::ReadKey'; L = 'Fehler'; T = 'Keine Eingaben/Fenster - das Skript laeuft unbeaufsichtigt.' }
        @{ P = '(?im)\?\?|\?\.\w'; L = 'Warnung'; T = 'Moeglicherweise PowerShell-7-Syntax (?? / ?.) - Intune nutzt Windows PowerShell 5.1.' }
        @{ P = '(?im)\bInvoke-Expression\b|\biex\b'; L = 'Warnung'; T = 'Invoke-Expression vermeiden.' }
        @{ P = '[A-Za-z0-9_.\-]{3}\dQ~[A-Za-z0-9_.\-~]{30,}|(?im)\$\w*secret\w*\s*=\s*["''][^"'']{16,}'; L = 'Warnung'; T = 'Enthaelt offenbar ein App-Secret im Klartext - liegt auf jedem Geraet lesbar (Intune-Cache, Protokolle). Besser ohne Secret loesen oder ein Zertifikat/eine eigene App mit minimalen Rechten verwenden.' }
        @{ P = '(?im)\$\w*(pw|pwd|pass|passwort|password|kennwort)\w*\s*=\s*["''](?![a-z]:\\|\\\\|https?:)[^"'']{4,}["'']|ConvertTo-SecureString\s+(-String\s+)?["''][^"'']+["'']\s+-AsPlainText|\bnet(\.exe)?\s+user\s+\S+\s+["'']?[^\s/*"'']{4,}'; L = 'Warnung'; T = 'Enthaelt offenbar ein Passwort im Klartext - lesbar fuer alle mit Leserecht auf Wartungsskripte in Intune und fuer lokale Administratoren auf den Geraeten (Intune-Cache). Wenn bewusst so gewollt: Hinweis ignorieren.' }
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
- Eigene Funktionen nur in Verb-Nomen-Form benennen (z. B. Test-AdminMember), keine Kurznamen - sonst kann ein Alias greifen.
- Werte, die man spaeter aendern moechte (Namen, Passwoerter, Pfade, Zahlen, Ja/Nein), ganz oben in BEIDEN Skripten gleich als Feld anlegen - je zwei Zeilen, vor jeder Verwendung und ausserhalb von Funktionen:
  # @param Name|Typ|Beschriftung|Standard
  `$Name = 'Wert'  # @value
  Typ ist string, int, bool oder choice (bei choice: # @param Name|choice|Beschriftung|Standard|A;B;C). Bei int steht der Wert ohne Anfuehrungszeichen, bei bool als `$true/`$false. Keinen param()-Block verwenden.
Pruefskript:
- exit 1, wenn das Problem vorliegt (dann laeuft die Reparatur), sonst exit 0.
- Vor dem exit eine kurze Statusmeldung ausgeben.
Reparaturskript:
- Behebt das Problem; exit 0 bei Erfolg, exit 1 bei Fehler, mit kurzer Meldung.
- Bei Fehlern die Meldung zusaetzlich mit [Console]::Error.WriteLine() ausgeben - Intune zeigt von der Reparatur nur die Fehlerausgabe an.
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
$result = [ordered]@{ Deps = @(); DetectInstall = $null; DetectUninstall = $null; ExitCode = $null; Seconds = 0; NewEntries = @(); NewFolders = @(); UninstallTested = $false; UninstallExitCode = $null; UninstallRemoved = $null; Error = ''; InstallWindows = @(); UninstallWindows = @(); InstallLog = ''; UninstallLog = ''; DesktopLinks = @(); WrapperLog = @() }
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
# Erkennungsregel wie Intune pruefen (Datei/Ordner, Registry, MSI-Produktcode); $null = nicht pruefbar
function Test-Det {
    $d = $cfg.Detect
    if (-not $d -or -not $d.Type) { return $null }
    switch ($d.Type) {
        'file' {
            $raw = "$($d.Path)"
            if ($d.Check32) { $raw = $raw -replace '(?i)%ProgramFiles%', '%ProgramFiles(x86)%' }
            $base = [Environment]::ExpandEnvironmentVariables($raw)
            if (-not $base) { return $null }
            $p = if ("$($d.FileName)") { Join-Path $base $d.FileName } else { $base }
            return (Test-Path -LiteralPath $p)
        }
        'registry' {
            if (-not "$($d.KeyPath)") { return $null }
            $kp = "$($d.KeyPath)"
            if ($d.Check32 -and $kp -notmatch '(?i)\\WOW6432Node\\') { $kp = $kp -replace '(?i)^(HKEY_LOCAL_MACHINE|HKLM:?)\\SOFTWARE\\', '$1\SOFTWARE\WOW6432Node\' }
            $k = "Registry::$kp"
            if (-not (Test-Path -LiteralPath $k)) { return $false }
            if ("$($d.ValueName)") { return ($null -ne (Get-ItemProperty -LiteralPath $k -Name $d.ValueName -ErrorAction SilentlyContinue)) }
            return $true
        }
        'msi' {
            if (-not "$($d.ProductCode)") { return $null }
            foreach ($r in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') { if (Test-Path -LiteralPath (Join-Path $r $d.ProductCode)) { return $true } }
            return $false
        }
    }
    return $null
}
function Get-Dirs { @(Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
$script:Windows = @()
# Fenstergroesse pruefen: Inno/Delphi-Setups haben auch bei /VERYSILENT ein unsichtbares 0x0-Hauptfenster
try {
    Add-Type -Namespace HUSb -Name Win -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
"@ -ErrorAction Stop
    $script:CanRect = $true
} catch { $script:CanRect = $false }
function Test-RealWindow([IntPtr]$H) {
    if (-not $script:CanRect) { return $true }
    if (-not [HUSb.Win]::IsWindowVisible($H)) { return $false }
    $r = New-Object HUSb.Win+RECT
    if (-not [HUSb.Win]::GetWindowRect($H, [ref]$r)) { return $true }
    $script:LastRect = "$($r.Right - $r.Left)x$($r.Bottom - $r.Top) @ $($r.Left),$($r.Top)"
    # zu klein oder ausserhalb des Bildschirms (z. B. -32000) -> kein echtes Fenster
    return (($r.Right - $r.Left) -ge 80 -and ($r.Bottom - $r.Top) -ge 40 -and $r.Right -gt 0 -and $r.Bottom -gt 0 -and $r.Left -gt -10000 -and $r.Top -gt -10000)
}
$script:LastRect = ''
# Befehl ausfuehren; Ausgabe nach C:\HUTest\logs\<Tag>-ausgabe.txt, bei msiexec ein ausfuehrliches MSI-Protokoll.
# Sichtbare Fenster neuer Prozesse merken (unter Intune wuerde ein Dialog haengen).
function Invoke-Cmd([string]$Line, [int]$Minutes, [string]$Tag = 'install', [string]$Dir = 'C:\HUInstall') {
    New-Item -ItemType Directory -Path 'C:\HUTest\logs' -Force | Out-Null
    $run = $Line
    if ($run -match '(?i)\bmsiexec(\.exe)?\b' -and $run -notmatch '(?i)\s/l[\*a-z+!]*\s') { $run += " /l*v `"C:\HUTest\logs\$Tag-msi.log`"" }
    $runCmd = Join-Path $Dir '__run.cmd'
    Set-Content -LiteralPath $runCmd -Value "@echo off`r`n$run > `"C:\HUTest\logs\$Tag-ausgabe.txt`" 2>&1`r`nexit /b %errorlevel%" -Encoding Default
    $base = @(Get-Process | ForEach-Object { $_.Id })
    $seen = @{}
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $runCmd -WorkingDirectory $Dir -PassThru -WindowStyle Hidden
    $end = (Get-Date).AddMinutes($Minutes)
    while (-not $p.HasExited) {
        foreach ($w in @(Get-Process | Where-Object { $base -notcontains $_.Id -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -and $_.ProcessName -notmatch '^(explorer|conhost|cmd|powershell|ShellExperienceHost|SearchHost|StartMenuExperienceHost)$' })) {
            $script:LastRect = ''
            if (-not (Test-RealWindow $w.MainWindowHandle)) { continue }
            $seen["$($w.ProcessName): $($w.MainWindowTitle) [$($script:LastRect)]"] = $true
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
    # Abhaengigkeiten aus der Bibliothek zuerst (zaehlen nicht als neue Programme dieser App)
    $di = 0
    foreach ($d in @($cfg.Deps | Where-Object { $_ })) {
        $di++
        New-Item -ItemType Directory -Path $d.Dir -Force | Out-Null
        Copy-Item -Path (Join-Path $d.Src '*') -Destination $d.Dir -Recurse -Force
        Write-Host "Abhaengigkeit $($d.Name): $($d.Cmd)" -ForegroundColor Yellow
        $dt = Get-Date
        $dx = Invoke-Cmd $d.Cmd 30 "dep$di" $d.Dir
        $result.Deps += [pscustomobject]@{ Name = "$($d.Name)"; ExitCode = $dx; Log = $(if ($dx -notin 0, 1707, 3010, 1641) { Get-LogText $dt "dep$di" } else { '' }) }
        if ($dx -notin 0, 1707, 3010, 1641) { throw "Abhaengigkeit '$($d.Name)' fehlgeschlagen (Exitcode $dx) - App selbst nicht installiert" }
    }
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
    $result.DetectInstall = Test-Det
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
    Start-Sleep -Seconds 5
    $result.DesktopLinks = @(Get-ChildItem -Path $lnkDirs -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object { $lnkBefore -notcontains $_.FullName } | ForEach-Object { $_.Name })
    $wl = Join-Path $env:ProgramData 'HU-MultiTenant\Logs\HU-Install.log'
    if (Test-Path $wl) { $result.WrapperLog = @(Get-Content $wl -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { "$_" }) }
    Write-Host "Exitcode $($result.ExitCode) nach $($result.Seconds) s, neue Programme: $(@($result.NewEntries).Count)$(if (@($result.DesktopLinks).Count) { ', Desktop-Verknuepfungen: ' + (@($result.DesktopLinks) -join ', ') })" -ForegroundColor Green
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
        $result.DetectUninstall = Test-Det
    }
} catch { $result.Error = $_.Exception.Message }
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'C:\HUTest\result.json' -Encoding UTF8
Write-Host ''
Write-Host 'Fertig - Ergebnis steht in HU-MultiTenant.' -ForegroundColor Green
# HU-MultiTenant schliesst die Sandbox von aussen; nur falls das nicht klappt, hier nach 90 s herunterfahren
if (-not $cfg.KeepOpen) { Write-Host 'Sandbox wird von HU-MultiTenant geschlossen ...'; Start-Sleep -Seconds 90; shutdown.exe /s /t 0 }
else { Write-Host 'Sandbox bleibt offen (zum Nachsehen). Schliessen mit dem X oben rechts.' -ForegroundColor Yellow }
'@

# Laufende Windows Sandbox von aussen schliessen (ohne Rueckfrage/Fehlermeldung im Sandbox-Fenster).
# Ab Windows 11 24H2 ueber "wsb stop", sonst Sandbox-Fenster beenden. Laeuft unsichtbar im Hintergrund.
function Stop-HUSandbox {
    $cmd = @'
$ErrorActionPreference = 'SilentlyContinue'
$wsb = Get-Command wsb.exe -ErrorAction SilentlyContinue
if ($wsb) {
    $ids = @([regex]::Matches(((& $wsb.Source list) -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    foreach ($i in $ids) { & $wsb.Source stop --id $i | Out-Null }
    Start-Sleep -Seconds 3
}
Get-Process -Name 'WindowsSandboxRemoteSession', 'WindowsSandboxClient', 'WindowsSandbox' -ErrorAction SilentlyContinue | Stop-Process -Force
'@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc -WindowStyle Hidden } catch { }
}

function Start-HUSandboxTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$InstallCmd,
        [string]$UninstallCmd = '',
        [switch]$TestUninstall,
        [switch]$KeepOpen,
        # Abhaengigkeiten aus der Bibliothek, werden vorher installiert: je @{ Name; Folder (Host); Cmd }
        [object[]]$Dependencies = @(),
        # Erkennungsregel der App (Type file|registry|msi) - wird nach Installation/Deinstallation geprueft
        $Detection = $null
    )
    if (-not (Test-HUSandboxAvailable)) { throw 'Windows Sandbox ist nicht aktiviert' }
    if (Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue) { throw 'Es laeuft bereits eine Windows Sandbox - bitte zuerst schliessen (nur eine gleichzeitig moeglich).' }
    if (Test-Path -LiteralPath $WorkFolder) { Remove-Item -LiteralPath $WorkFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'HUTest.ps1'), $script:SandboxScript, $utf8)
    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $deps = @(); $depMaps = ''; $i = 0
    foreach ($d in @($Dependencies | Where-Object { $_ })) {
        $i++
        $deps += [ordered]@{ Name = "$($d.Name)"; Cmd = "$($d.Cmd)"; Src = "C:\HUDepSrc\$i"; Dir = "C:\HUDep\$i" }
        $depMaps += "`n    <MappedFolder><HostFolder>$(& $esc "$($d.Folder)")</HostFolder><SandboxFolder>C:\HUDepSrc\$i</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
    }
    $cfg = [ordered]@{ Install = $InstallCmd; Uninstall = $UninstallCmd; TestUninstall = [bool]$TestUninstall; KeepOpen = [bool]$KeepOpen; Deps = @($deps)
        Detect = $(if ($Detection -and "$($Detection.Type)" -in 'file', 'registry', 'msi') { [ordered]@{ Type = "$($Detection.Type)"; Path = "$($Detection.Path)"; FileName = "$($Detection.FileName)"; KeyPath = "$($Detection.KeyPath)"; ValueName = "$($Detection.ValueName)"; ProductCode = "$($Detection.ProductCode)"; Check32 = [bool]$Detection.Check32 } } else { $null }) }
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'config.json'), (ConvertTo-Json -InputObject $cfg -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    $wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder><HostFolder>$(& $esc $SourceFolder)</HostFolder><SandboxFolder>C:\HUSource</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$(& $esc $WorkFolder)</HostFolder><SandboxFolder>C:\HUTest</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>$depMaps
  </MappedFolders>
  <LogonCommand><Command>cmd.exe /c start "HU-MultiTenant Testinstallation" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File C:\HUTest\HUTest.ps1</Command></LogonCommand>
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
    if (-not $c -or $c -match '(?i)msiexec|^cmd(\.exe)?\s+/c\s|^powershell') { return $c }
    $inno = $c -match '(?i)unins\d{3}\.exe'
    if (-not $inno -and $c -match '(?i)(^|\s)(/S|/silent|/verysilent|/quiet|/qn|--silent|-s)(\s|$)') { return $c }
    if ($c.StartsWith('"')) { $exe = $c.Substring(1, $c.IndexOf('"', 1) - 1); $rest = $c.Substring($c.IndexOf('"', 1) + 1).Trim() }
    else { $m = [regex]::Match($c, '(?i)^(.+?\.exe)(.*)$'); if (-not $m.Success) { return $c }; $exe = $m.Groups[1].Value.Trim(); $rest = $m.Groups[2].Value.Trim() }
    $leaf = ($exe -split '[\\/]')[-1]
    # Inno-Deinstaller: /SILENT zeigt Fortschritt und Rueckfragen -> immer /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
    if ($inno) { $rest = ($rest -replace '(?i)(^|\s)/(VERY)?SILENT\b|(^|\s)/SUPPRESSMSGBOXES\b|(^|\s)/NORESTART\b', ' ').Trim() }
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
    if (-not $un) { $un = "$($Entry.UninstallString)" }
    if ($un -match '(?i)msiexec(\.exe)?\s+/[ix]\s*(\{[0-9A-F-]{36}\})') { $un = "msiexec /x $($Matches[2]) /qn /norestart" }
    elseif ($un) {
        $un = Add-HUSilentUninstall $un $InstallerType
        # laufende App vorher beenden (sonst fragt der Deinstaller nach) - Programmname aus DisplayIcon
        $ico = if ($Entry.PSObject.Properties['DisplayIcon']) { (("$($Entry.DisplayIcon)" -replace ',\s*-?\d+\s*$', '').Trim().Trim('"') -split '[\\/]')[-1] } else { '' }
        if ($ico -match '(?i)^[^"&|<>]+\.exe$' -and $ico -notmatch '(?i)^unins|uninst') { $un = "cmd.exe /c `"taskkill /f /im `"$ico`" >nul 2>&1 & $un`"" }
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

# ----------------------------------------------------------------------------
# Wartungsskripte (Remediations) in der Windows Sandbox testen - Ablauf wie Intune:
# Erkennung -> bei exit 1 Reparatur -> Erkennung erneut; als SYSTEM (geplanter Task) bzw. als Benutzer,
# 64- oder 32-Bit-PowerShell, ohne Netzwerk, Zeitlimit je Skript mit Abbruch des ganzen Prozessbaums.
# ----------------------------------------------------------------------------
$script:RemSandboxStep = @'
param([string]$Tag, [string]$Script, [int]$Use32 = 0, [int]$Timeout = 300)
$ErrorActionPreference = 'Continue'
$o = [ordered]@{ Tag = $Tag; User = ''; Sid = ''; ExitCode = $null; Out = ''; Err = ''; Seconds = 0; TimedOut = $false; Bits = $(if ($Use32) { 32 } else { 64 }); Error = '' }
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent(); $o.User = "$($id.Name)"; $o.Sid = "$($id.User.Value)"
    $exe = if ($Use32) { Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Timeout * 1000)) {
        $o.TimedOut = $true
        & "$env:windir\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null
        [void]$p.WaitForExit(10000)
    } else { $o.ExitCode = $p.ExitCode }
    $o.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($so.Wait(5000)) { $o.Out = "$($so.Result)" }
    if ($se.Wait(5000)) { $o.Err = "$($se.Result)" }
} catch { $o.Error = "$($_.Exception.Message)" }
$tmp = "C:\HURun\step-$Tag.tmp"
[IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
Move-Item -LiteralPath $tmp -Destination "C:\HURun\step-$Tag.json" -Force
'@

$script:RemSandboxRunner = @'
$ErrorActionPreference = 'Continue'
try { Start-Transcript -LiteralPath 'C:\HUTest\Protokoll.txt' -Force | Out-Null } catch { }
$res = [ordered]@{ Steps = @(); Error = ''; RunAs = ''; Bits = 64; Started = (Get-Date).ToString('s'); Finished = '' }
trap { $res.Error += "Zeile $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message) "; continue }
$cfg = Get-Content -LiteralPath 'C:\HUTest\config.json' -Raw | ConvertFrom-Json
$res.RunAs = "$($cfg.RunAs)"; $res.Bits = $(if ($cfg.Use32) { 32 } else { 64 })
$ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Skripte auf die lokale Platte kopieren - der eingebundene Host-Ordner ist fuer SYSTEM evtl. nicht lesbar
New-Item -ItemType Directory -Path 'C:\HURun' -Force | Out-Null
foreach ($f in 'Detection.ps1', 'Remediation.ps1', 'HUStep.ps1') { Copy-Item -LiteralPath "C:\HUTest\$f" -Destination "C:\HURun\$f" -Force }

function Invoke-HUTestStep([string]$Tag, [string]$File) {
    $out = "C:\HURun\step-$Tag.json"
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\HURun\HUStep.ps1 -Tag $Tag -Script $File -Use32 $([int][bool]$cfg.Use32) -Timeout $($cfg.Timeout)"
    Write-Host ""
    Write-Host "--- $Tag ($File) ---" -ForegroundColor Cyan
    if ($cfg.RunAs -eq 'system') {
        $name = "HU-Test-$Tag"
        $act = New-ScheduledTaskAction -Execute $ps -Argument $arg
        $pri = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ([int]$cfg.Timeout + 120))
        Register-ScheduledTask -TaskName $name -Action $act -Principal $pri -Settings $set -Force | Out-Null
        Start-ScheduledTask -TaskName $name | Out-Null
    } else {
        Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden | Out-Null
    }
    $end = (Get-Date).AddSeconds([int]$cfg.Timeout + 60)
    while (-not (Test-Path -LiteralPath $out) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 500 }
    if ($cfg.RunAs -eq 'system') { try { Unregister-ScheduledTask -TaskName "HU-Test-$Tag" -Confirm:$false } catch { } }
    if (-not (Test-Path -LiteralPath $out)) {
        $s = [pscustomobject]@{ Tag = $Tag; User = ''; ExitCode = $null; Out = ''; Err = ''; Seconds = 0; TimedOut = $true; Bits = $res.Bits; Error = 'Kein Ergebnis vom Schritt (Task nicht gestartet oder haengt)' }
    } else { $s = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json }
    Write-Host ("Exit {0} - {1} s - als {2}{3}" -f $s.ExitCode, $s.Seconds, $s.User, $(if ($s.TimedOut) { ' - ZEITLIMIT' } else { '' }))
    if ("$($s.Out)".Trim()) { Write-Host "$($s.Out)".Trim() }
    if ("$($s.Err)".Trim()) { Write-Host "$($s.Err)".Trim() -ForegroundColor Yellow }
    return $s
}

$d1 = Invoke-HUTestStep 'Erkennung' 'C:\HURun\Detection.ps1'
$res.Steps += $d1
if ($d1.ExitCode -eq 1 -and $cfg.HasFix) {
    $res.Steps += (Invoke-HUTestStep 'Reparatur' 'C:\HURun\Remediation.ps1')
    $res.Steps += (Invoke-HUTestStep 'Erkennung-danach' 'C:\HURun\Detection.ps1')
}
$res.Finished = (Get-Date).ToString('s')
$lines = foreach ($s in $res.Steps) { "[$($s.Tag)] Exit $($s.ExitCode), $($s.Seconds) s, als $($s.User)$(if ($s.TimedOut) { ', ZEITLIMIT' })`r`n$("$($s.Out)".Trim())`r`n$("$($s.Err)".Trim())`r`n" }
try { Stop-Transcript | Out-Null } catch { }
[IO.File]::WriteAllText('C:\HUTest\Ergebnis.txt', ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $true))
[IO.File]::WriteAllText('C:\HUTest\Ergebnis.tmp', ($res | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
Move-Item -LiteralPath 'C:\HUTest\Ergebnis.tmp' -Destination 'C:\HUTest\Ergebnis.json' -Force
Write-Host ""
Write-Host 'Fertig. Ergebnis: C:\HUTest\Ergebnis.txt (beim ersten Lauf auch in HU-MultiTenant). Erneut testen: & C:\HUTest\HURemTest.ps1' -ForegroundColor Green
'@

function Start-HURemSandboxTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$Detection,
        [string]$Remediation = '',
        [ValidateSet('system', 'user')][string]$RunAs = 'system',
        [switch]$Use32,
        [int]$TimeoutSeconds = 300,
        [switch]$KeepOpen
    )
    if (-not (Test-HUSandboxAvailable)) { throw 'Windows Sandbox ist nicht aktiviert' }
    if (Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue) { throw 'Es laeuft bereits eine Windows Sandbox - bitte zuerst schliessen (nur eine gleichzeitig moeglich).' }
    if (Test-Path -LiteralPath $WorkFolder) { Remove-Item -LiteralPath $WorkFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    # Skripte wie beim Hochladen nach Intune: UTF-8 ohne BOM
    $noBom = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'Detection.ps1'), $Detection, $noBom)
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'Remediation.ps1'), $Remediation, $noBom)
    $bom = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'HURemTest.ps1'), $script:RemSandboxRunner, $bom)
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'HUStep.ps1'), $script:RemSandboxStep, $bom)
    $cfg = [ordered]@{ RunAs = $RunAs; Use32 = [bool]$Use32; Timeout = $TimeoutSeconds; HasFix = [bool]"$Remediation".Trim() }
    [IO.File]::WriteAllText((Join-Path $WorkFolder 'config.json'), ($cfg | ConvertTo-Json), $noBom)
    $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $wsb = @"
<Configuration>
  <Networking>Disable</Networking>
  <MappedFolders>
    <MappedFolder><HostFolder>$(& $esc $WorkFolder)</HostFolder><SandboxFolder>C:\HUTest</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>cmd.exe /c start "HU-MultiTenant Wartungstest" powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File C:\HUTest\HURemTest.ps1</Command></LogonCommand>
</Configuration>
"@
    $wsbFile = Join-Path $WorkFolder 'HURemTest.wsb'
    [IO.File]::WriteAllText($wsbFile, $wsb, $noBom)
    Start-Process -FilePath $wsbFile
    return (Join-Path $WorkFolder 'Ergebnis.json')
}

# ============================================================================
# Analyse: Was bekommt eine Gruppe / ein Geraet / ein Benutzer? (je Tenant)
# ============================================================================
# Objektarten mit Zuweisungen (beta, $expand=assignments). Name = Eigenschaft fuer den Anzeigenamen.
function Get-HUAssignmentSources {
    return @(
        @{ Typ = 'App'; Ep = '/deviceAppManagement/mobileApps?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Konfiguration'; Ep = '/deviceManagement/deviceConfigurations?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Einstellungskatalog'; Ep = '/deviceManagement/configurationPolicies?$expand=assignments'; Name = 'name' }
        @{ Typ = 'Administrative Vorlage'; Ep = '/deviceManagement/groupPolicyConfigurations?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Compliance'; Ep = '/deviceManagement/deviceCompliancePolicies?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Wartung'; Ep = '/deviceManagement/deviceHealthScripts?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Plattform-Skript'; Ep = '/deviceManagement/deviceManagementScripts?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Feature-Update'; Ep = '/deviceManagement/windowsFeatureUpdateProfiles?$expand=assignments'; Name = 'displayName' }
        @{ Typ = 'Autopilot-Profil'; Ep = '/deviceManagement/windowsAutopilotDeploymentProfiles?$expand=assignments'; Name = 'displayName' }
    )
}

# Ziel aufloesen: Gruppen (inkl. uebergeordneter), und ob "Alle Geraete"/"Alle Benutzer" greifen.
# Kind: group | device | user. Rueckgabe: @{ Label; Groups = @{ id -> Name (Herkunft) }; AllDevices; AllUsers; Note }
function Resolve-HUAssignmentTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [ValidateSet('group', 'device', 'user')][string]$Kind, [Parameter(Mandatory)][string]$Name)
    $esc = { param($s) [uri]::EscapeDataString("$s".Replace("'", "''")) }
    $t = @{ Label = $Name; Groups = @{}; AllDevices = $false; AllUsers = $false; Note = '' }
    $addParents = {
        param($Path, $From)
        foreach ($g in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$Path/transitiveMemberOf/microsoft.graph.group?`$select=id,displayName" -V1)) {
            if (-not $t.Groups.ContainsKey("$($g.id)")) { $t.Groups["$($g.id)"] = "$($g.displayName) ($From)" }
        }
    }
    switch ($Kind) {
        'group' {
            $g = @((Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/groups?`$filter=displayName eq '$(& $esc $Name)'&`$select=id,displayName" -V1).value)
            if (-not $g.Count) { return $null }
            $t.Groups["$($g[0].id)"] = "$($g[0].displayName)"
            & $addParents "/groups/$($g[0].id)" "ueber $($g[0].displayName)"
            $t.AllDevices = $true; $t.AllUsers = $true
            $t.Note = 'Alle Geraete/Alle Benutzer gelten fuer die Mitglieder der Gruppe (je nachdem, ob Geraete oder Benutzer drin sind).'
        }
        'user' {
            $u = $null
            $gu = { param($f) @((Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/users?`$filter=$f&`$select=id,displayName,userPrincipalName" -V1).value) }
            if ($Name -match '@') {
                try { $u = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/users/$([uri]::EscapeDataString($Name))?`$select=id,displayName,userPrincipalName" -V1 } catch { }
            } else {
                # ohne Domain: Benutzername vor dem @ (je Tenant passend), sonst Kurzname
                $r = @(& $gu "startswith(userPrincipalName,'$(& $esc ($Name + '@'))')")
                if (-not $r.Count) { $r = @(& $gu "mailNickname eq '$(& $esc $Name)'") }
                if ($r.Count -gt 1) { $t.Note = "'$Name' passt auf $($r.Count) Benutzer - verwendet wird $($r[0].userPrincipalName)." }
                $u = $r | Select-Object -First 1
            }
            if (-not $u) { $r = @(& $gu "displayName eq '$(& $esc $Name)'"); $u = $r | Select-Object -First 1 }
            if (-not $u) { return $null }
            $t.Label = "$($u.userPrincipalName)"
            & $addParents "/users/$($u.id)" 'Benutzer'
            $t.AllUsers = $true
            # Intune-Geraete des Benutzers (primaerer Benutzer) mit ihren Gruppen
            $md = @()
            try { $md = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=userPrincipalName eq '$(& $esc "$($u.userPrincipalName)")'&`$select=id,deviceName,azureADDeviceId") } catch { }
            $names = @()
            foreach ($d in $md) {
                $aad = "$($d.azureADDeviceId)"
                $names += "$($d.deviceName)"
                $t.AllDevices = $true
                if (-not $aad -or $aad -eq '00000000-0000-0000-0000-000000000000') { continue }
                $dev = @((Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/devices?`$filter=deviceId eq '$aad'&`$select=id" -V1).value) | Select-Object -First 1
                if ($dev) { & $addParents "/devices/$($dev.id)" "Geraet $($d.deviceName)" }
            }
            if ($names.Count) { $t.Label += " (Geraete: $($names -join ', '))"; $t.Note = (@($t.Note, "Mit $($names.Count) Intune-Geraet(en) des Benutzers: $($names -join ', ').") | Where-Object { $_ }) -join ' ' }
        }
        'device' {
            $md = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=deviceName eq '$(& $esc $Name)'&`$select=id,deviceName,azureADDeviceId,userPrincipalName,userId")
            $aad = ''; $uid = ''
            if ($md.Count) { $aad = "$($md[0].azureADDeviceId)"; $uid = "$($md[0].userId)"; $t.Label = "$($md[0].deviceName)$(if ($md[0].userPrincipalName) { " / $($md[0].userPrincipalName)" })" }
            $dev = $null
            if ($aad -and $aad -ne '00000000-0000-0000-0000-000000000000') { $dev = @((Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/devices?`$filter=deviceId eq '$aad'&`$select=id" -V1).value) | Select-Object -First 1 }
            if (-not $dev) { $dev = @((Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/devices?`$filter=displayName eq '$(& $esc $Name)'&`$select=id" -V1).value) | Select-Object -First 1 }
            if (-not $md.Count -and -not $dev) { return $null }
            if ($dev) { & $addParents "/devices/$($dev.id)" 'Geraet' }
            $t.AllDevices = $true
            if ($uid) { & $addParents "/users/$uid" 'Hauptbenutzer'; $t.AllUsers = $true }
            if ($md.Count -gt 1) { $t.Note = "Geraetename gibt es $($md.Count)-mal - verwendet wird der erste Eintrag." }
        }
    }
    return $t
}

# Zuweisungen eines Objekts gegen das Ziel pruefen -> $null oder @{ Via; Excluded; Intent; Filter }
function Test-HUAssignmentMatch($Assignments, $Target) {
    $via = @(); $excl = @(); $intent = @(); $filter = $false
    foreach ($a in @($Assignments)) {
        if (-not $a -or -not $a.target) { continue }
        $tt = "$($a.target.'@odata.type')"
        $gid = "$($a.target.groupId)"
        $hit = $null
        switch -Wildcard ($tt) {
            '*exclusionGroupAssignmentTarget' { if ($Target.Groups.ContainsKey($gid)) { $excl += $Target.Groups[$gid] }; continue }
            '*groupAssignmentTarget' { if ($Target.Groups.ContainsKey($gid)) { $hit = $Target.Groups[$gid] } }
            '*allDevicesAssignmentTarget' { if ($Target.AllDevices) { $hit = 'Alle Geraete' } }
            '*allLicensedUsersAssignmentTarget' { if ($Target.AllUsers) { $hit = 'Alle Benutzer' } }
        }
        if ($hit) {
            $via += $hit
            if ($a.PSObject.Properties['intent'] -and "$($a.intent)") { $intent += "$($a.intent)" }
            if ("$($a.target.deviceAndAppManagementAssignmentFilterId)" -and "$($a.target.deviceAndAppManagementAssignmentFilterId)" -ne '00000000-0000-0000-0000-000000000000') { $filter = $true }
        }
    }
    if (-not $via.Count -and -not $excl.Count) { return $null }
    return @{ Via = @($via | Select-Object -Unique); Excluded = @($excl | Select-Object -Unique); Intent = @($intent | Select-Object -Unique); Filter = $filter }
}

function ConvertTo-HUIntentText([string]$Intent) {
    switch ($Intent) { 'required' { 'Erforderlich' } 'available' { 'Verfuegbar' } 'availableWithoutEnrollment' { 'Verfuegbar (ohne Registrierung)' } 'uninstall' { 'Deinstallieren' } default { $Intent } }
}

# Bericht je Tenant: Zeilen @{ Tenant; Typ; Name; Absicht; Ueber; Status; Filter }
function Get-HUAssignmentReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [ValidateSet('group', 'device', 'user')][string]$Kind, [Parameter(Mandatory)][string]$Name)
    $t = Resolve-HUAssignmentTarget -TenantKey $TenantKey -Settings $Settings -Kind $Kind -Name $Name
    if (-not $t) { Write-HULog -Message "'$Name' nicht gefunden" -Level 'WARN' -Tenant $TenantKey; return }
    Write-HULog -Message "$($t.Label): $($t.Groups.Count) Gruppe(n) beruecksichtigt" -Level 'INFO' -Tenant $TenantKey
    if ($t.Note) { Write-HULog -Message $t.Note -Level 'INFO' -Tenant $TenantKey }
    foreach ($src in Get-HUAssignmentSources) {
        $items = $null
        try { $items = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $src.Ep) }
        catch { Write-HULog -Message "$($src.Typ): nicht lesbar ($($_.Exception.Message))" -Level 'WARN' -Tenant $TenantKey; continue }
        foreach ($o in $items) {
            $m = Test-HUAssignmentMatch $o.assignments $t
            if (-not $m) { continue }
            [pscustomobject]@{
                Tenant  = $TenantKey
                Typ     = $src.Typ
                Name    = "$($o.($src.Name))"
                Absicht = (@($m.Intent | ForEach-Object { ConvertTo-HUIntentText $_ }) -join ', ')
                Ueber   = (@($m.Via) -join ', ')
                Status  = $(if ($m.Excluded.Count) { "ausgeschlossen ($(@($m.Excluded) -join ', '))" } else { 'zugewiesen' })
                Filter  = $(if ($m.Filter) { 'ja' } else { '' })
            }
        }
    }
}

# ============================================================================
# Tenant-Vergleich: Bestand je Tenant, Fingerabdruck, Kopieren fehlender Objekte (ohne Zuweisungen)
# ============================================================================
# Copy: generic = Objekt holen, Verwaltungsfelder entfernen, neu anlegen; catalog/compliance = eigene Aufbereitung; '' = nur anzeigen
function Get-HUCompareSources {
    return @(
        @{ Typ = 'Konfiguration'; Ep = '/deviceManagement/deviceConfigurations'; Base = '/deviceManagement/deviceConfigurations'; Name = 'displayName'; Copy = 'generic'; Hash = $true }
        @{ Typ = 'Einstellungskatalog'; Ep = '/deviceManagement/configurationPolicies'; Base = '/deviceManagement/configurationPolicies'; Name = 'name'; Copy = 'catalog'; Hash = $false }
        @{ Typ = 'Administrative Vorlage'; Ep = '/deviceManagement/groupPolicyConfigurations'; Base = '/deviceManagement/groupPolicyConfigurations'; Name = 'displayName'; Copy = 'admx'; Hash = $false }
        @{ Typ = 'Compliance'; Ep = '/deviceManagement/deviceCompliancePolicies'; Base = '/deviceManagement/deviceCompliancePolicies'; Name = 'displayName'; Copy = 'compliance'; Hash = $true }
        @{ Typ = 'Wartung'; Ep = '/deviceManagement/deviceHealthScripts'; Base = '/deviceManagement/deviceHealthScripts'; Name = 'displayName'; Copy = 'generic'; Hash = $false }
        @{ Typ = 'Plattform-Skript'; Ep = '/deviceManagement/deviceManagementScripts'; Base = '/deviceManagement/deviceManagementScripts'; Name = 'displayName'; Copy = 'generic'; Hash = $false }
        @{ Typ = 'Feature-Update'; Ep = '/deviceManagement/windowsFeatureUpdateProfiles'; Base = '/deviceManagement/windowsFeatureUpdateProfiles'; Name = 'displayName'; Copy = 'generic'; Hash = $true }
        @{ Typ = 'Autopilot-Profil'; Ep = '/deviceManagement/windowsAutopilotDeploymentProfiles'; Base = ''; Name = 'displayName'; Copy = ''; Hash = $true }
        @{ Typ = 'Conditional Access'; Ep = '/identity/conditionalAccess/policies'; Base = ''; Name = 'displayName'; Copy = ''; Hash = $false }
        @{ Typ = 'App'; Ep = '/deviceAppManagement/mobileApps?$select=id,displayName'; Base = ''; Name = 'displayName'; Copy = ''; Hash = $false }
    )
}

# Verwaltungsfelder, die beim Vergleich und Kopieren nicht zaehlen
$script:HUCmpSkip = @('id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'assignments', 'roleScopeTagIds', 'supportsScopeTags', 'isAssigned',
    'deviceManagementApplicabilityRuleOsEdition', 'deviceManagementApplicabilityRuleOsVersion', 'deviceManagementApplicabilityRuleDeviceMode',
    'settingCount', 'creationSource', 'priorityMetaData', 'isGlobalScript', 'highestAvailableVersion', 'deviceHealthScriptType', 'detectionScriptParameters',
    'remediationScriptParameters', 'scheduledActionsForRule', 'deployableContentDisplayName', 'endOfSupportDate', 'templateId', 'modifiedDateTime')

function ConvertTo-HUCleanObject($Obj, [string[]]$Skip = $script:HUCmpSkip) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [string] -or $Obj -is [ValueType]) { return $Obj }
    if ($Obj -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in @($Obj.Keys | Sort-Object)) {
            if ("$k" -in $Skip -or "$k" -match '@odata\.(context|navigationLink|associationLink|etag)$|^@odata\.(context|etag)$') { continue }
            $v = $Obj[$k]; if ($null -eq $v) { continue }
            $h["$k"] = ConvertTo-HUCleanObject $v $Skip
        }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable]) { return ,@($Obj | ForEach-Object { ConvertTo-HUCleanObject $_ $Skip }) }
    $h = [ordered]@{}
    foreach ($p in @($Obj.PSObject.Properties | Sort-Object Name)) {
        if ($p.Name -in $Skip -or $p.Name -match '@odata\.(navigationLink|associationLink|etag)$|^@odata\.(context|etag)$|@odata\.context$') { continue }
        if ($null -eq $p.Value) { continue }
        $h[$p.Name] = ConvertTo-HUCleanObject $p.Value $Skip
    }
    return $h
}

# Fingerabdruck der Einstellungen (ohne Name/Beschreibung/IDs) - gleich = gleiche Werte laut Graph-Liste
function Get-HUCompareHash($Obj) {
    $c = ConvertTo-HUCleanObject $Obj ($script:HUCmpSkip + @('displayName', 'name', 'description'))
    $json = $c | ConvertTo-Json -Depth 50 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$json"))) -replace '-', '').Substring(0, 16) } finally { $sha.Dispose() }
}

# Bestand eines Tenants -> Zeilen Typ, Name, Id, Hash, Copy
function Get-HUCompareInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [string[]]$Types = @())
    foreach ($src in Get-HUCompareSources) {
        if (@($Types).Count -and $Types -notcontains $src.Typ) { continue }
        $items = $null
        try { $items = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $src.Ep -V1:($src.Typ -eq 'Conditional Access')) }
        catch {
            Write-HULog -Message "$($src.Typ): nicht lesbar ($($_.Exception.Message))" -Level 'WARN' -Tenant $TenantKey
            # Fehler als eigene Zeile: im Vergleich 'nicht lesbar' statt 'fehlt' (sonst wuerde Vorhandenes kopiert)
            [pscustomobject]@{ Tenant = $TenantKey; Typ = $src.Typ; Name = ''; Id = ''; Hash = ''; Copy = ''; Error = "$($_.Exception.Message)" }
            continue
        }
        $n = 0
        foreach ($o in $items) {
            if ($src.Typ -eq 'Wartung' -and $o.isGlobalScript) { continue }
            $name = "$($o.($src.Name))"
            if (-not $name) { continue }
            $n++
            [pscustomobject]@{ Tenant = $TenantKey; Typ = $src.Typ; Name = $name; Id = "$($o.id)"; Hash = $(if ($src.Hash) { Get-HUCompareHash $o } else { '' }); Copy = $src.Copy }
        }
        Write-HULog -Message "$($src.Typ): $n" -Level 'INFO' -Tenant $TenantKey
    }
}

# Matrix aus den Bestaenden: je Typ+Name eine Zeile, je Tenant vorhanden/fehlt, Status
function Get-HUCompareMatrix([object[]]$Rows, [string[]]$Keys) {
    # nicht lesbare Arten je Tenant (Typ '*' = ganzer Tenant)
    $failed = @{}
    foreach ($e in @($Rows | Where-Object { $_.PSObject.Properties['Error'] -and $_.Error })) { $failed["$($e.Tenant)|$($e.Typ)"] = $true }
    $groups = @($Rows | Where-Object { "$($_.Name)" } | Group-Object { "$($_.Typ)|$($_.Name.ToLowerInvariant())" })
    foreach ($g in $groups) {
        $first = $g.Group[0]
        $have = @($g.Group | ForEach-Object { $_.Tenant } | Select-Object -Unique)
        $unk = @($Keys | Where-Object { $have -notcontains $_ -and ($failed["$_|$($first.Typ)"] -or $failed["$_|*"]) })
        $miss = @($Keys | Where-Object { $have -notcontains $_ -and $unk -notcontains $_ })
        $hashes = @($g.Group | Where-Object { $_.Hash } | ForEach-Object { $_.Hash } | Select-Object -Unique)
        $dupe = @($g.Group | Group-Object Tenant | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $st = if (-not $miss.Count -and -not $unk.Count) { 'ueberall' } elseif (-not $miss.Count) { 'vorhanden, wo lesbar' } elseif ($have.Count -eq 1 -and $Keys.Count -gt 1 -and -not $unk.Count) { 'nur in einem' } else { 'fehlt teilweise' }
        if ($unk.Count) { $st += ", nicht lesbar in $($unk -join ', ')" }
        if ($hashes.Count -gt 1) { $st += ', Einstellungen abweichend' }
        if ($dupe.Count) { $st += ', doppelt' }
        [pscustomobject]@{ Typ = $first.Typ; Name = $first.Name; Have = $have; Missing = $miss; Unknown = $unk; Status = $st; Copy = $first.Copy; Items = @($g.Group); Diff = ($miss.Count -gt 0 -or $unk.Count -gt 0 -or $hashes.Count -gt 1 -or $dupe.Count -gt 0); Dupe = ($dupe.Count -gt 0) }
    }
}

function ConvertTo-HUHashtable($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { $h = @{}; foreach ($k in $Obj.Keys) { $h["$k"] = ConvertTo-HUHashtable $Obj[$k] }; return $h }
    if ($Obj -is [string] -or $Obj -is [ValueType]) { return $Obj }
    if ($Obj -is [System.Collections.IEnumerable]) { return ,@($Obj | ForEach-Object { ConvertTo-HUHashtable $_ }) }
    $h = @{}; foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HUHashtable $p.Value }; return $h
}

# Objekt neu anlegen aus einem vollstaendig gelesenen Objekt (Get-HUCompareObject / Backup-Datei), ohne Zuweisungen -> neue Id
# -Name: anderer Name (z. B. "... (wiederhergestellt)"). Conditional Access nur mit -AllowCA (wird deaktiviert angelegt).
function New-HUIntuneObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)]$Obj, [string]$Name = '', [switch]$AllowCA)
    $src = Get-HUCompareSources | Where-Object { $_.Typ -eq $Typ } | Select-Object -First 1
    if (-not $src) { throw "Unbekannte Art: $Typ" }
    $o = $Obj
    $base = ($src.Ep -replace '\?.*$', '')
    $nameProp = $src.Name
    switch ($Typ) {
        'Einstellungskatalog' {
            $body = @{
                name = "$($o.name)"; description = "$($o.description)"; platforms = "$($o.platforms)"; technologies = "$($o.technologies)"; roleScopeTagIds = @('0')
                settings = @(@($o.settings) | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSetting'; settingInstance = (ConvertTo-HUHashtable (ConvertTo-HUCleanObject $_.settingInstance @())) } })
            }
            if ($o.templateReference -and "$($o.templateReference.templateId)") { $body.templateReference = @{ templateId = "$($o.templateReference.templateId)" } }
        }
        'Compliance' {
            $body = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $o)
            $acts = @(@($o.scheduledActionsForRule) | ForEach-Object { @($_.scheduledActionConfigurations) } | Where-Object { $_ } | ForEach-Object {
                    @{ actionType = "$($_.actionType)"; gracePeriodHours = [int]$_.gracePeriodHours; notificationTemplateId = ''; notificationMessageCCList = @() } })
            # Benachrichtigungsvorlagen gibt es nur im Quell-Tenant -> nur Sperren/Markieren uebernehmen
            $drop = @($acts | Where-Object { $_.actionType -in 'notification', 'pushNotification' })
            if ($drop.Count) { Write-HULog -Message "Compliance '$($o.displayName)': $($drop.Count) Benachrichtigungs-Aktion(en) nicht uebernommen - im Portal ergaenzen" -Level 'WARN' -Tenant $TenantKey }
            $acts = @($acts | Where-Object { $_.actionType -ne 'notification' -and $_.actionType -ne 'pushNotification' })
            if (-not $acts.Count) { $acts = @(@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = ''; notificationMessageCCList = @() }) }
            $body.scheduledActionsForRule = @(@{ ruleName = 'PasswordRequired'; scheduledActionConfigurations = $acts })
            $body.roleScopeTagIds = @('0')
        }
        'Administrative Vorlage' {
            $body = @{ displayName = "$($o.displayName)"; description = "$($o.description)"; roleScopeTagIds = @('0') }
        }
        'Conditional Access' {
            if (-not $AllowCA) { throw 'Conditional Access wird nicht in andere Tenants kopiert (Gruppen-IDs verschieden)' }
            $body = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $o)
            $body.state = 'disabled'
        }
        default {
            if (-not $src.Copy) { throw "$Typ kann nicht angelegt werden" }
            $body = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $o)
            $body.roleScopeTagIds = @('0')
        }
    }
    if ($Typ -eq 'Conditional Access') { $body.Remove('roleScopeTagIds') }
    if ($Name) { $body[$nameProp] = $Name }
    foreach ($k in @('definitionValues', 'settings@odata.context')) { if ($Typ -ne 'Einstellungskatalog' -and $body.ContainsKey($k)) { $body.Remove($k) } }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $base -Method POST -Body $body -V1:($Typ -eq 'Conditional Access')
    $newId = "$($r.id)"
    if ($Typ -eq 'Administrative Vorlage') {
        $gb = 'https://graph.microsoft.com/beta/deviceManagement/groupPolicyDefinitions'
        $dvFail = 0; $dvTotal = 0
        foreach ($dv in @($o.definitionValues)) {
            $defId = "$($dv.definition.id)"
            if (-not $defId) { continue }
            $pv = @(@($dv.presentationValues) | Where-Object { $_.presentation -and $_.presentation.id } | ForEach-Object {
                    $h = ConvertTo-HUHashtable (ConvertTo-HUCleanObject $_ @('id', 'createdDateTime', 'lastModifiedDateTime', 'presentation', 'definitionValue'))
                    $h['presentation@odata.bind'] = "$gb('$defId')/presentations('$($_.presentation.id)')"
                    $h })
            $dvb = @{ enabled = [bool]$dv.enabled; 'definition@odata.bind' = "$gb('$defId')"; presentationValues = $pv }
            $dvTotal++
            try { [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$base/$newId/definitionValues" -Method POST -Body $dvb) }
            catch { $dvFail++; Write-HULog -Message "Administrative Vorlage '$($o.displayName)': Einstellung '$($dv.definition.displayName)' nicht uebernommen ($($_.Exception.Message))" -Level 'WARN' -Tenant $TenantKey }
        }
        # halb fertig darf nicht als OK gelten
        if ($dvFail) { throw "UNVOLLSTAENDIG angelegt: $dvFail von $dvTotal Einstellungen fehlen - '$(if ($Name) { $Name } else { $o.displayName })' NICHT zuweisen, im Portal pruefen oder loeschen" }
    }
    return $newId
}

# Objekt aus einem Tenant in einen anderen kopieren (ohne Zuweisungen) -> neue Id
function Copy-HUIntuneObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)][string]$SourceTenant, [Parameter(Mandatory)][string]$SourceId, [Parameter(Mandatory)][string]$TargetTenant, [Parameter(Mandatory)]$Settings)
    $src = Get-HUCompareSources | Where-Object { $_.Typ -eq $Typ } | Select-Object -First 1
    if (-not $src -or -not $src.Copy) { throw "$Typ kann nicht kopiert werden" }
    $o = Get-HUCompareObject -TenantKey $SourceTenant -Settings $Settings -Typ $Typ -Id $SourceId
    return (New-HUIntuneObject -TenantKey $TargetTenant -Settings $Settings -Typ $Typ -Obj $o)
}

# Objekt vollstaendig holen (fuer die Detail-Ansicht im Vergleich)
function Get-HUCompareObject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)][string]$Id)
    $src = Get-HUCompareSources | Where-Object { $_.Typ -eq $Typ } | Select-Object -First 1
    if (-not $src) { throw "Unbekannte Art: $Typ" }
    $base = ($src.Ep -replace '\?.*$', '')
    $q = switch ($Typ) {
        'Einstellungskatalog' { '?$expand=settings' }
        'Compliance' { '?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)' }
        default { '' }
    }
    $o = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$base/$Id$q" -V1:($Typ -eq 'Conditional Access')
    if ($Typ -eq 'Administrative Vorlage') {
        # $expand nur 1 Ebene tief erlaubt: Einstellungen mit Definition, dann je Einstellung die Werte mit Praesentation
        $dv = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$base/$Id/definitionValues?`$expand=definition")
        foreach ($d in $dv) {
            $pv = @()
            try { $pv = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$base/$Id/definitionValues/$($d.id)/presentationValues?`$expand=presentation") } catch { }
            $d | Add-Member -NotePropertyName 'presentationValues' -NotePropertyValue $pv -Force
        }
        $o | Add-Member -NotePropertyName 'definitionValues' -NotePropertyValue $dv -Force
    }
    return $o
}

# Objekt zu Pfad -> Wert flach machen. Listenelemente mit settingDefinitionId/definition werden darueber benannt (Reihenfolge egal).
function ConvertTo-HUFlatMap($Obj, [string]$Prefix = '', [hashtable]$Map = $null, [switch]$WithAssignments) {
    if ($null -eq $Map) { $Map = @{} }
    $skip = @($script:HUCmpSkip | Where-Object { -not $WithAssignments -or $_ -ne 'assignments' }) + @('displayName', 'name', 'description', '@odata.context', 'settingInstanceTemplateReference', 'settingValueTemplateReference', 'definition@odata.bind', 'presentation@odata.bind')
    if ($null -eq $Obj) { return $Map }
    if ($Obj -is [string] -or $Obj -is [ValueType]) {
        $v = "$Obj"
        if ($v.Length -gt 120 -and $v -match '^[A-Za-z0-9+/=\r\n]+$') {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($v))) -replace '-', '').Substring(0, 8) } finally { $sha.Dispose() }
            $v = "(Inhalt, $($v.Length) Zeichen, #$h)"
        } elseif ($v.Length -gt 200) { $v = $v.Substring(0, 200) + ' ...' }
        $Map[$(if ($Prefix) { $Prefix } else { '(Wert)' })] = $v
        return $Map
    }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Collections.IDictionary])) {
        $list = @($Obj)
        if (-not $list.Count) { $Map[$Prefix] = '(leer)'; return $Map }
        $simple = @($list | Where-Object { $_ -is [string] -or $_ -is [ValueType] })
        if ($simple.Count -eq $list.Count) { $Map[$Prefix] = (@($list | ForEach-Object { "$_" } | Sort-Object) -join ', '); return $Map }
        $i = 0
        foreach ($e in $list) {
            $k = "$i"
            if ($e.PSObject.Properties['settingDefinitionId'] -and "$($e.settingDefinitionId)") { $k = "$($e.settingDefinitionId)" }
            elseif ($e.PSObject.Properties['settingInstance'] -and $e.settingInstance.settingDefinitionId) { $k = "$($e.settingInstance.settingDefinitionId)" }
            elseif ($e.PSObject.Properties['definition'] -and $e.definition.displayName) { $k = "$($e.definition.displayName)" }
            elseif ($e.PSObject.Properties['actionType']) { $k = "$($e.actionType)" }
            elseif ($e.PSObject.Properties['target'] -and $e.target) { $k = "$(("$($e.target.'@odata.type')" -replace '^#microsoft\.graph\.', '' -replace 'AssignmentTarget$', '')) $($e.target.groupId)".Trim() }
            [void](ConvertTo-HUFlatMap $e "$Prefix[$k]" $Map -WithAssignments:$WithAssignments)
            $i++
        }
        return $Map
    }
    $props = if ($Obj -is [System.Collections.IDictionary]) { @($Obj.Keys | ForEach-Object { [pscustomobject]@{ Name = "$_"; Value = $Obj[$_] } }) } else { @($Obj.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }) }
    foreach ($p in $props) {
        if ($p.Name -in $skip -or $p.Name -match '@odata\.(context|navigationLink|associationLink|etag)$|^id$') { continue }
        if ($null -eq $p.Value) { continue }
        if ($p.Name -eq '@odata.type' -and $Prefix) { continue }
        [void](ConvertTo-HUFlatMap $p.Value $(if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }) $Map -WithAssignments:$WithAssignments)
    }
    return $Map
}

# Unterschiede zwischen den flachen Maps je Tenant -> Zeilen Einstellung, T0..Tn
function Get-HUCompareDiff([hashtable]$Maps, [string[]]$Keys) {
    $paths = @($Keys | ForEach-Object { if ($Maps[$_]) { $Maps[$_].Keys } } | Sort-Object -Unique)
    foreach ($p in $paths) {
        $vals = @($Keys | ForEach-Object { if ($Maps[$_] -and $Maps[$_].ContainsKey($p)) { "$($Maps[$_][$p])" } else { '(nicht gesetzt)' } })
        if (@($vals | Select-Object -Unique).Count -le 1) { continue }
        # Listen: gemeinsame Eintraege zusammenfassen, je Tenant nur das Zusaetzliche zeigen
        $lists = @($vals | ForEach-Object { ,@("$_" -split ', ' | Where-Object { $_ -and $_ -notin '(nicht gesetzt)', '(leer)' }) })
        if (@($vals | Where-Object { "$_" -match ', ' }).Count) {
            $common = @($lists[0] | Where-Object { $e = $_; @($lists | Where-Object { $_ -notcontains $e }).Count -eq 0 })
            if ($common.Count) {
                $vals = @(for ($i = 0; $i -lt $lists.Count; $i++) {
                        $extra = @($lists[$i] | Where-Object { $common -notcontains $_ })
                        "(gleich: $($common.Count))$(if ($extra.Count) { ' + ' + ($extra -join ', ') } else { '' })"
                    })
            }
        }
        $o = [ordered]@{ Einstellung = ($p -replace '^device_vendor_msft_policy_config_', '' -replace '\[device_vendor_msft_policy_config_', '[') }
        for ($i = 0; $i -lt $Keys.Count; $i++) { $o["T$i"] = $vals[$i] }
        [pscustomobject]$o
    }
}

# GUIDs in den Werten (Gruppen, Benutzer, benannte Orte) durch Namen ersetzen - IDs sind je Tenant verschieden
function Resolve-HUFlatMapIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][hashtable]$Map, [int]$Max = 80)
    $rx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $ids = @($Map.Keys | Where-Object { $_ -notmatch '(?i)(definitionId|templateId|@odata)' } | ForEach-Object { [regex]::Matches("$($Map[$_])", $rx) | ForEach-Object { $_.Value.ToLowerInvariant() } } | Select-Object -Unique)
    if (-not $ids.Count) { return $Map }
    $names = @{}
    try { foreach ($l in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/identity/conditionalAccess/namedLocations?$select=id,displayName' -V1)) { $names["$($l.id)".ToLowerInvariant()] = "$($l.displayName) (Ort)" } } catch { }
    # Rollen (Vorlagen-IDs, in allen Tenants gleich) - je nach Berechtigung ueber eine der beiden Listen
    try { foreach ($r in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/roleManagement/directory/roleDefinitions?$select=id,templateId,displayName' -V1)) { foreach ($x in @($r.id, $r.templateId)) { if ($x -and -not $names.ContainsKey("$x".ToLowerInvariant())) { $names["$x".ToLowerInvariant()] = "$($r.displayName) (Rolle)" } } } } catch {
        try { foreach ($r in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/directoryRoleTemplates?$select=id,displayName' -V1)) { if (-not $names.ContainsKey("$($r.id)".ToLowerInvariant())) { $names["$($r.id)".ToLowerInvariant()] = "$($r.displayName) (Rolle)" } } } catch { }
    }
    foreach ($id in @($ids | Select-Object -First $Max)) {
        if ($names.ContainsKey($id)) { continue }
        foreach ($t in @(@{ P = 'groups'; S = 'displayName'; L = 'Gruppe' }, @{ P = 'users'; S = 'userPrincipalName'; L = 'Benutzer' }, @{ P = 'servicePrincipals'; S = 'displayName'; L = 'App' })) {
            try { $o = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/$($t.P)/$id`?`$select=$($t.S)" -V1 -NoRetry; if ($o) { $names[$id] = "$($o.($t.S)) ($($t.L))"; break } } catch { }
        }
        # Cloud-Apps in Conditional Access: Anwendungs-ID (appId), nicht Objekt-ID
        if (-not $names.ContainsKey($id)) {
            try { $o = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/servicePrincipals(appId='$id')?`$select=displayName" -V1 -NoRetry; if ($o -and $o.displayName) { $names[$id] = "$($o.displayName) (App)" } } catch { }
        }
    }
    foreach ($k in @($Map.Keys)) {
        if ($k -match '(?i)(definitionId|templateId|@odata)') { continue }
        $v = "$($Map[$k])"
        if ($v -notmatch $rx) { continue }
        $Map[$k] = [regex]::Replace($v, $rx, { param($m) $n = $names[$m.Value.ToLowerInvariant()]; if ($n) { $n } else { $m.Value } })
        # Listen neu sortieren (Namen statt IDs)
        if ($Map[$k] -match ', ') { $Map[$k] = (@($Map[$k] -split ', ' | Sort-Object) -join ', ') }
    }
    return $Map
}

# ============================================================================
# Konfigurations-Backup: Stand je Tenant als JSON-Dateien, Verlauf vergleichen, einzelne Eintraege wiederherstellen
# Ablage: <Root>\<Tenant>\<yyyy-MM-dd_HHmmss>\<Typ>\<Name>__<Id>.json + index.json
# ============================================================================
function Get-HUBackupRoot($Settings) {
    $p = ''
    try { if ($Settings.PSObject.Properties['ui'] -and $Settings.ui -and $Settings.ui.PSObject.Properties['backupPath']) { $p = "$($Settings.ui.backupPath)" } } catch { }
    if (-not $p) { $p = Join-Path (Get-HUWorkPath) 'Backups' }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function ConvertTo-HUSafeFileName([string]$Name, [int]$Max = 80) {
    $n = ("$Name" -replace '[\\/:*?"<>|\x00-\x1f]', '_').Trim(' ', '.')
    if (-not $n) { $n = '_' }
    if ($n.Length -gt $Max) { $n = $n.Substring(0, $Max) }
    return $n
}

function Write-HUBackupJson([string]$Path, $Obj) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 60), (New-Object Text.UTF8Encoding($false)))
}

function Read-HUBackupJson([string]$Path) { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }

# Fingerabdruck der Zuweisungen (Ziel, Absicht, Filter) - Reihenfolge egal
function Get-HUAssignmentHash($Assignments) {
    $parts = @(@($Assignments) | Where-Object { $_ -and $_.target } | ForEach-Object {
            "$($_.target.'@odata.type')|$($_.target.groupId)|$($_.intent)|$($_.target.deviceAndAppManagementAssignmentFilterId)|$($_.target.deviceAndAppManagementAssignmentFilterType)" } | Sort-Object)
    return ($parts -join ';')
}

# Backup eines Tenants -> Ordner des Stands
function Save-HUTenantBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [string]$Root = '', [string[]]$Types = @())
    if (-not $Root) { $Root = Get-HUBackupRoot $Settings }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $dir = Join-Path (Join-Path $Root (ConvertTo-HUSafeFileName $TenantKey)) $stamp
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $index = New-Object System.Collections.Generic.List[object]
    $errors = 0
    $failedTypes = New-Object System.Collections.Generic.List[string]
    $failedIds = New-Object System.Collections.Generic.List[string]
    foreach ($src in Get-HUCompareSources) {
        if (@($Types).Count -and $Types -notcontains $src.Typ) { continue }
        $items = $null
        try { $items = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $src.Ep -V1:($src.Typ -eq 'Conditional Access')) }
        catch { Write-HULog -Message "$($src.Typ): nicht lesbar ($($_.Exception.Message))" -Level 'WARN' -Tenant $TenantKey; $errors++; $failedTypes.Add($src.Typ); continue }
        if ($src.Typ -eq 'App') {
            # Apps nur als Liste (Inhalte liegen in der Bibliothek bzw. im Store)
            $rows = @($items | ForEach-Object { [pscustomobject]@{ id = "$($_.id)"; displayName = "$($_.displayName)" } })
            Write-HUBackupJson (Join-Path $dir 'App\_liste.json') $rows
            foreach ($a in $rows) { $index.Add([pscustomobject]@{ Typ = 'App'; Name = $a.displayName; Id = $a.id; File = ''; Hash = ''; AHash = '' }) }
            Write-HULog -Message "App: $($rows.Count) (nur Liste)" -Level 'INFO' -Tenant $TenantKey
            continue
        }
        $n = 0
        foreach ($it in $items) {
            if ($src.Typ -eq 'Wartung' -and $it.isGlobalScript) { continue }
            $name = "$($it.($src.Name))"
            try {
                $full = Get-HUCompareObject -TenantKey $TenantKey -Settings $Settings -Typ $src.Typ -Id "$($it.id)"
                $asg = @(); $asgOk = $true
                if ($src.Typ -ne 'Conditional Access') {
                    try { $asg = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($src.Ep -replace '\?.*$', '')/$($it.id)/assignments") }
                    catch { $asgOk = $false; Write-HULog -Message "$($src.Typ) '$name': Zuweisungen nicht lesbar ($($_.Exception.Message))" -Level 'WARN' -Tenant $TenantKey }
                }
                $full | Add-Member -NotePropertyName 'assignments' -NotePropertyValue $asg -Force
                $rel = "$(ConvertTo-HUSafeFileName $src.Typ)\$(ConvertTo-HUSafeFileName $name 60)__$("$($it.id)".Substring(0, [Math]::Min(8, "$($it.id)".Length))).json"
                Write-HUBackupJson (Join-Path $dir $rel) $full
                $index.Add([pscustomobject]@{ Typ = $src.Typ; Name = $name; Id = "$($it.id)"; File = $rel; Hash = (Get-HUCompareHash $full); AHash = $(if ($asgOk) { Get-HUAssignmentHash $asg } else { '?' }); Desc = "$($full.description)" })
                $n++
            } catch { Write-HULog -Message "$($src.Typ) '$name': $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey; $errors++; $failedIds.Add("$($src.Typ)|$($it.id)") }
        }
        Write-HULog -Message "$($src.Typ): $n gesichert" -Level 'INFO' -Tenant $TenantKey
    }
    # nichts lesbar (z. B. Secret abgelaufen): keinen leeren Stand anlegen - er wuerde gute Staende verdraengen
    if (-not $index.Count -and $errors) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Backup fehlgeschlagen - nichts lesbar ($errors Fehler). Secret und Berechtigungen pruefen"
    }
    Write-HUBackupJson (Join-Path $dir 'index.json') ([pscustomobject]@{ Tenant = $TenantKey; Time = (Get-Date).ToString('s'); Errors = $errors; Complete = ($errors -eq 0); FailedTypes = $failedTypes.ToArray(); FailedIds = $failedIds.ToArray(); Items = $index.ToArray() })
    return [pscustomobject]@{ Tenant = $TenantKey; Folder = $dir; Count = $index.Count; Errors = $errors; Complete = ($errors -eq 0) }
}

# Staende eines Tenants (neueste zuerst)
function Get-HUBackupList {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$TenantKey)
    $d = Join-Path $Root (ConvertTo-HUSafeFileName $TenantKey)
    if (-not (Test-Path -LiteralPath $d)) { return @() }
    $list = foreach ($f in @(Get-ChildItem -LiteralPath $d -Directory | Sort-Object Name -Descending)) {
        $ix = Join-Path $f.FullName 'index.json'
        if (-not (Test-Path -LiteralPath $ix)) { continue }
        $t = $null; try { $t = [datetime]::ParseExact($f.Name, 'yyyy-MM-dd_HHmmss', $null) } catch { $t = $f.CreationTime }
        $complete = $true
        try { $ixo = Read-HUBackupJson $ix; if ($ixo.PSObject.Properties['Complete']) { $complete = [bool]$ixo.Complete } elseif ([int]$ixo.Errors -gt 0) { $complete = $false } } catch { $complete = $false }
        [pscustomobject]@{ Name = $f.Name; Folder = $f.FullName; Time = $t; Complete = $complete; Label = "$($t.ToString('dd.MM.yyyy HH:mm'))$(if (-not $complete) { ' (unvollst.)' })" }
    }
    return @($list)
}

# alte Staende entfernen (die neuesten $Keep bleiben)
function Remove-HUOldBackups {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$TenantKey, [int]$Keep = 30)
    if ($Keep -lt 1) { return 0 }
    # nur vollstaendige Staende zaehlen; unvollstaendige bleiben nur, solange sie neuer als der aelteste behaltene vollstaendige sind
    $all = @(Get-HUBackupList -Root $Root -TenantKey $TenantKey)
    $keepFull = @($all | Where-Object Complete | Select-Object -First $Keep)
    $limit = if ($keepFull.Count -ge $Keep) { $keepFull[-1].Time } else { [datetime]::MinValue }
    $old = @($all | Where-Object { ($_.Complete -and $keepFull -notcontains $_) -or (-not $_.Complete -and $_.Time -lt $limit) })
    foreach ($o in $old) { Remove-Item -LiteralPath $o.Folder -Recurse -Force -ErrorAction SilentlyContinue }
    return $old.Count
}

# zwei Staende vergleichen (A = aelter, B = neuer) -> Zeilen Typ, Name, Aenderung, FileA, FileB
function Compare-HUBackups {
    param([Parameter(Mandatory)][string]$FolderA, [Parameter(Mandatory)][string]$FolderB)
    $ia = Read-HUBackupJson (Join-Path $FolderA 'index.json')
    $ib = Read-HUBackupJson (Join-Path $FolderB 'index.json')
    $a = @($ia.Items); $b = @($ib.Items)
    # nicht gelesene Arten/Eintraege: dort ist 'fehlt' kein 'geloescht' bzw. 'neu'
    $failA = @($ia.FailedTypes) + @(); $failB = @($ib.FailedTypes) + @()
    $failIdA = @($ia.FailedIds) + @(); $failIdB = @($ib.FailedIds) + @()
    $byIdA = @{}; foreach ($x in $a) { $byIdA["$($x.Typ)|$($x.Id)"] = $x }
    $seen = @{}
    foreach ($y in $b) {
        $k = "$($y.Typ)|$($y.Id)"; $seen[$k] = $true
        $x = $byIdA[$k]
        $ch = if (-not $x -and ($failA -contains $y.Typ -or $failIdA -contains $k)) { 'unbekannt (aelterer Stand unvollstaendig)' } elseif (-not $x) { 'neu' } else {
            $c = @()
            if ("$($x.Name)" -ne "$($y.Name)") { $c += "umbenannt (vorher '$($x.Name)')" }
            if ($x.PSObject.Properties['Desc'] -and $y.PSObject.Properties['Desc'] -and "$($x.Desc)" -ne "$($y.Desc)") { $c += 'Beschreibung geaendert' }
            if ("$($x.Hash)" -ne "$($y.Hash)") { $c += 'Einstellungen geaendert' }
            if ("$($x.AHash)" -eq '?' -or "$($y.AHash)" -eq '?') { $c += 'Zuweisungen nicht lesbar' }
            elseif ("$($x.AHash)" -ne "$($y.AHash)") { $c += 'Zuweisungen geaendert' }
            if ($c.Count) { $c -join ', ' } else { 'gleich' }
        }
        [pscustomobject]@{ Typ = $y.Typ; Name = $y.Name; Aenderung = $ch; Id = $y.Id; FileA = $(if ($x -and $x.File) { Join-Path $FolderA $x.File } else { '' }); FileB = $(if ($y.File) { Join-Path $FolderB $y.File } else { '' }) }
    }
    foreach ($x in $a) {
        if ($seen["$($x.Typ)|$($x.Id)"]) { continue }
        $gone = if ($failB -contains $x.Typ -or $failIdB -contains "$($x.Typ)|$($x.Id)") { 'unbekannt (neuerer Stand unvollstaendig)' } else { 'geloescht' }
        [pscustomobject]@{ Typ = $x.Typ; Name = $x.Name; Aenderung = $gone; Id = $x.Id; FileA = $(if ($x.File) { Join-Path $FolderA $x.File } else { '' }); FileB = '' }
    }
}

# Unterschiede zwischen zwei Backup-Dateien desselben Objekts (inkl. Zuweisungen)
function Get-HUBackupItemDiff {
    param([string]$FileA, [string]$FileB)
    $oa = if ($FileA -and (Test-Path -LiteralPath $FileA)) { Read-HUBackupJson $FileA } else { $null }
    $ob = if ($FileB -and (Test-Path -LiteralPath $FileB)) { Read-HUBackupJson $FileB } else { $null }
    $ma = if ($oa) { ConvertTo-HUFlatMap $oa -WithAssignments } else { @{} }
    $mb = if ($ob) { ConvertTo-HUFlatMap $ob -WithAssignments } else { @{} }
    # Name und Beschreibung zaehlen im Verlauf mit (im Tenant-Vergleich nicht)
    foreach ($f in 'displayName', 'name', 'description') {
        foreach ($pair in @(@($oa, $ma), @($ob, $mb))) { if ($pair[0] -and $pair[0].PSObject.Properties[$f] -and "$($pair[0].$f)") { $pair[1][$f] = "$($pair[0].$f)" } }
    }
    return @(Get-HUCompareDiff @{ A = $ma; B = $mb } @('A', 'B'))
}

# einen Eintrag aus einer Backup-Datei neu anlegen (ohne Zuweisungen)
function Restore-HUBackupItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Typ, [Parameter(Mandatory)][string]$File, [string]$Name = '')
    $o = Read-HUBackupJson $File
    return (New-HUIntuneObject -TenantKey $TenantKey -Settings $Settings -Typ $Typ -Obj $o -Name $Name -AllowCA)
}

# Intune-Ueberwachungsprotokoll (wer hat wann was geaendert) - fuer den Verlauf
function Get-HUAuditEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [datetime]$From, [datetime]$To)
    $f = "activityDateTime ge $($From.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) and activityDateTime le $($To.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $ev = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/auditEvents?`$filter=$([uri]::EscapeDataString($f))")
    foreach ($e in $ev) {
        $who = "$($e.actor.userPrincipalName)"; if (-not $who) { $who = "$($e.actor.applicationDisplayName)" }
        foreach ($r in @($e.resources)) {
            [pscustomobject]@{ Time = [datetime]$e.activityDateTime; Actor = $who; Activity = "$($e.activity)"; Operation = "$($e.activityOperationType)"; ResourceId = "$($r.resourceId)"; Resource = "$($r.displayName)" }
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-HUIntuneGraph', 'Get-HUIntuneGraphAll', 'Assert-HUAssignmentKeysUnique', 'ConvertTo-HUBase64Utf8', 'Find-HUGroup', 'Find-HUManagedDevice', 'ConvertTo-HUGroupRow', 'Get-HUTenantGroups', 'ConvertTo-HUW32Row', 'Get-HUTenantWin32Apps', 'Find-HUWin32AppByName',
    'Read-HUMsiInfo', 'Get-HUExeInstallerType', 'Get-HUSetupInfo',
    'Get-HUIntuneWinAppUtil', 'New-HUIntuneWinPackage',
    'Get-HUDefaultReturnCodes', 'ConvertTo-HUDetectionRule', 'ConvertTo-HUWin32Payload',
    'Get-HUIntuneApp', 'New-HUWin32App', 'Update-HUWin32App', 'Publish-HUWin32Content', 'New-HUStoreApp',
    'Set-HUAppAssignment', 'Wait-HUAppPublished',
    'Get-HUAppKindFromType', 'Get-HUGroupNames', 'ConvertFrom-HUAssignment', 'Get-HUTenantAppList', 'Get-HUAppAssignmentRows', 'Remove-HUAppAssignments', 'Update-HUAppProperties',
    'Get-HUAppIconBytes', 'Get-HUAppInstallSummary', 'Get-HUAppRelationRows', 'Set-HUAppRelations', 'Remove-HUIntuneApp', 'Invoke-HUExportReport', 'Get-HUErrorText', 'ConvertTo-HUInstallStateText', 'Get-HUAppInstallStatus',
    'ConvertTo-HURemediationPayload', 'Publish-HURemediation', 'New-HURunSchedule', 'Set-HURemediationAssignment',
    'Get-HURemediationRunStates', 'Start-HURemediationOnDevice', 'ConvertFrom-HUBase64Text', 'ConvertFrom-HURunSchedule', 'ConvertFrom-HURemAssignment', 'Get-HUTenantRemediationList', 'Get-HURemediationDetail', 'Remove-HURemediationAssignments', 'Update-HURemediation', 'Remove-HURemediation', 'Test-HURemediationScript', 'Get-HUAiPrompt', 'Split-HUAiAnswer',
    'Test-HUSandboxAvailable', 'Enable-HUSandbox', 'Start-HUSandboxTest', 'Start-HURemSandboxTest', 'Stop-HUSandbox', 'ConvertFrom-HUSandboxEntry',
    'Get-HUWorkPath', 'Get-HUAuthor', 'Get-HUAssignmentSources', 'Resolve-HUAssignmentTarget', 'Test-HUAssignmentMatch', 'ConvertTo-HUIntentText', 'Get-HUAssignmentReport', 'Get-HUCompareSources', 'ConvertTo-HUCleanObject', 'Get-HUCompareHash', 'Get-HUCompareInventory', 'Get-HUCompareMatrix', 'ConvertTo-HUHashtable', 'New-HUIntuneObject', 'Copy-HUIntuneObject', 'Get-HUCompareObject', 'ConvertTo-HUFlatMap', 'Get-HUCompareDiff', 'Resolve-HUFlatMapIds', 'Get-HUBackupRoot', 'ConvertTo-HUSafeFileName', 'Write-HUBackupJson', 'Read-HUBackupJson', 'Get-HUAssignmentHash', 'Save-HUTenantBackup', 'Get-HUBackupList', 'Remove-HUOldBackups', 'Compare-HUBackups', 'Get-HUBackupItemDiff', 'Restore-HUBackupItem', 'Get-HUAuditEvents', 'Get-HUTenantAppCategories', 'New-HUAppCategory', 'Remove-HUAppCategory', 'Get-HUAppCategoryNames', 'Set-HUAppCategories', 'Sync-HUAppSource', 'Get-HUAppPackage', 'Resolve-HUTargets', 'Test-HUStoreId', 'Get-HUStoreIdFromText', 'Get-HUStoreAppInfo', 'Add-HUSilentUninstall',
    'New-HUInstallWrapper', 'Get-HUInstallPlan', 'New-HUWin32Def', 'Publish-HUWin32App', 'Get-HUDependencyBody', 'Set-HUAppDependencies',
    'ConvertTo-HUIconPng', 'Get-HUIconContent', 'Save-HUStoreAppIcon', 'Split-HUIconLocation', 'Select-HUSandboxEntry'
)
