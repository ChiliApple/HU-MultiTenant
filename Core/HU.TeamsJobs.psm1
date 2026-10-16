#Requires -Version 5.1

<#
.SYNOPSIS
    HU.TeamsJobs - zeitgesteuerte Teams-Meldungen (Auftraege, Datenerhebung, Aufgabenplanung) fuer HU-MultiTenant.
.DESCRIPTION
    Ein Auftrag (Job) beschreibt, WAS wann an Teams gemeldet wird:
      Kind 'Daily'    Tages-Ampel: je Tenant Geraete, nicht konform, ohne Sync, Secret-Ablauf. Sendet immer.
      Kind 'Secrets'  Secret-Countdown: App-Secrets, die in <= warnDays ablaufen. Sendet nur bei Befund.
      Kind 'Licenses' Lizenzen knapp: SKUs mit weniger als minFree freien Lizenzen. Sendet nur bei Befund.
      Kind 'Defender' Defender-Alarm: Geraete mit gemeldeter Bedrohung oder Fehlkonfiguration. Sendet nur bei Befund.
    Auftraege liegen in Config\teams-jobs.json (lokal, nicht im Repository). Sie enthalten keine Adressen -
    gesendet wird ueber die Ziele aus HU.Notify (Kategorie des Auftrags).

    Ausfuehrung:
      - aus der Oberflaeche (Reiter Teams > "Jetzt senden")
      - zeitgesteuert ueber die Windows-Aufgabenplanung, Aufgabe \HU-MultiTenant\Teams-<Id>, laeuft im Konto des
        Benutzers (DPAPI-Secrets, LogonType Interactive, ohne erhoehte Rechte) und ruft
        Main.ps1 -Headless -Job <Id>  auf. Der Headless-Lauf kennt NUR gespeicherte Auftraege - keine freien Skripte.

    Logik ohne Oberflaeche, PowerShell 5.1 und 7 (Windows).
.NOTES
    Modul: HU.TeamsJobs.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
    Zielmaschine: Admin-PC (Benutzerkontext).
#>

$script:TeamsJobsFile = 'Config\teams-jobs.json'
$script:TeamsTaskPath = '\HU-MultiTenant\'
$script:TeamsTaskPrefix = 'Teams-'
$script:TeamsJobKinds = @('Daily', 'Secrets', 'Licenses', 'Defender')

# ============================================================================
# AUFTRAEGE (SPEICHER)
# ============================================================================

function Get-HUTeamsJobsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)
    return (Join-Path $AppRoot $script:TeamsJobsFile)
}

function New-HUTeamsJob {
    <#
    .SYNOPSIS
        Neues Auftrags-Objekt (noch nicht gespeichert).
    .PARAMETER Tenants
        Tenant-Schluessel; leer = alle Tenants aus settings.json.
    .PARAMETER Time
        Uhrzeit HH:mm (lokal) fuer die Aufgabenplanung.
    .PARAMETER Days
        Wochentage 1..7 (Mo=1); leer = taeglich.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Daily', 'Secrets', 'Licenses', 'Defender')][string]$Kind = 'Daily',
        [string[]]$Tenants = @(),
        [string]$Time = '07:00',
        [int[]]$Days = @(),
        [string]$Category = 'Daily',
        [string[]]$Targets = @(),
        [bool]$Enabled = $true,
        [hashtable]$Options = @{}
    )
    return [pscustomobject]@{
        Id         = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
        Name       = $Name
        Kind       = $Kind
        Enabled    = $Enabled
        Tenants    = @($Tenants)
        Targets    = @($Targets)
        Time       = $Time
        Days       = @($Days)
        Category   = $Category
        Options    = [pscustomobject]$Options
        Created    = (Get-Date).ToString('s')
        LastRun    = ''
        LastResult = ''
    }
}

function Get-HUTeamsJobs {
    <#
    .SYNOPSIS
        Liest alle Auftraege. Rueckgabe: Array (leer, wenn keine Datei).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)
    $p = Get-HUTeamsJobsPath -AppRoot $AppRoot
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $list = @($raw.jobs | Where-Object { $_ -and "$($_.Id)" })
        foreach ($j in $list) {
            foreach ($k in 'Tenants', 'Days', 'Targets') { if (-not $j.PSObject.Properties[$k] -or $null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force } }
            foreach ($k in 'LastRun', 'LastResult', 'Time', 'Category') { if (-not $j.PSObject.Properties[$k] -or $null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue '' -Force } }
            if (-not $j.PSObject.Properties['Enabled']) { $j | Add-Member -NotePropertyName Enabled -NotePropertyValue $true -Force }
            if (-not $j.PSObject.Properties['Options'] -or $null -eq $j.Options) { $j | Add-Member -NotePropertyName Options -NotePropertyValue ([pscustomobject]@{}) -Force }
        }
        return $list
    }
    catch { throw "teams-jobs.json nicht lesbar: $($_.Exception.Message)" }
}

function Set-HUTeamsJobs {
    <#
    .SYNOPSIS
        Schreibt alle Auftraege (atomar, mit .bak der letzten gueltigen Datei).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Jobs)
    $p = Get-HUTeamsJobsPath -AppRoot $AppRoot
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($j in $Jobs) {
        if ($j.Kind -notin $script:TeamsJobKinds) { throw "Unbekannte Auftragsart: $($j.Kind)" }
        if ("$($j.Time)" -and "$($j.Time)" -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "Uhrzeit ungueltig: $($j.Time) (HH:mm)" }
    }
    $doc = [ordered]@{ v = 1; updated = (Get-Date).ToString('s'); jobs = @($Jobs) }
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    $tmp = "$p.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $p) { try { $null = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json; Copy-Item -LiteralPath $p -Destination "$p.bak" -Force } catch { } }
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

function Get-HUTeamsJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Id)
    return (Get-HUTeamsJobs -AppRoot $AppRoot | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Update-HUTeamsJobResult {
    # LastRun/LastResult eines Auftrags nachtragen (andere Felder bleiben, wie sie in der Datei stehen)
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Id, [string]$Result)
    try {
        $jobs = @(Get-HUTeamsJobs -AppRoot $AppRoot)
        $j = $jobs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        if (-not $j) { return }
        $j.LastRun = (Get-Date).ToString('s')
        $j.LastResult = "$Result"
        Set-HUTeamsJobs -AppRoot $AppRoot -Jobs $jobs
    }
    catch { Write-Verbose "[TeamsJobs] Ergebnis nicht gespeichert: $($_.Exception.Message)" }
}

# ============================================================================
# DATENERHEBUNG
# ============================================================================

function ConvertTo-HUDateOrNull {
    # Graph-Zeitstempel (ISO 8601, UTC) -> lokale Zeit; $null, wenn leer oder nicht lesbar (PS 5.1 und 7)
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ([datetime]::Parse($Text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime() } catch { return $null }
}

function Get-HUDailyTenantStatus {
    <#
    .SYNOPSIS
        Kennzahlen eines Tenants fuer die Tages-Ampel (Graph, nur lesend).
    .OUTPUTS
        Key, Name, Ok (Token/Abfrage), Error, Devices, NonCompliant, Stale, StaleDays, SecretDays, SecretStatus
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantKey,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [int]$StaleDays = 7
    )
    $t = $Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    $r = [pscustomobject]@{
        Key = $TenantKey; Name = "$(if ($t) { $t.displayName } else { $TenantKey })"; Ok = $false; Error = ''
        Devices = 0; NonCompliant = 0; Stale = 0; StaleDays = $StaleDays; NoPolicy = 0
        SecretDays = $null; SecretStatus = ''
    }
    if (-not $t) { $r.Error = 'Tenant nicht in settings.json'; return $r }
    $tok = $null
    try { $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop } catch { $r.Error = "Token: $($_.Exception.Message)"; return $r }
    if (-not $tok) { $r.Error = 'Kein Token (Secret fehlt oder abgelaufen)'; return $r }
    try {
        $ep = '/deviceManagement/managedDevices?$select=id,complianceState,lastSyncDateTime&$top=999'
        $devs = @(Invoke-GraphRequestAll -Token $tok -Endpoint $ep -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop)
        $limit = (Get-Date).AddDays(-$StaleDays)
        $r.Devices = $devs.Count
        $r.NonCompliant = @($devs | Where-Object { "$($_.complianceState)" -eq 'noncompliant' }).Count
        $r.NoPolicy = @($devs | Where-Object { "$($_.complianceState)" -in 'unknown', 'notApplicable' }).Count
        $r.Stale = @($devs | Where-Object { $d = ConvertTo-HUDateOrNull "$($_.lastSyncDateTime)"; ($null -eq $d) -or ($d -lt $limit) }).Count
        $r.Ok = $true
    }
    catch { $r.Error = "Geraete: $(($_.Exception.Message) -replace '\s+', ' ')" }
    try {
        $s = Get-AppSecretExpiry -TenantKey $TenantKey -Settings $Settings -Token $tok -ErrorAction Stop
        $r.SecretStatus = "$($s.Status)"
        if ($s.Status -eq 'OK' -and $s.EndDate) { $r.SecretDays = [int][math]::Floor(([datetime]$s.EndDate - (Get-Date)).TotalDays) }
    }
    catch { $r.SecretStatus = 'Error' }
    return $r
}

function New-HUDailyCardSpec {
    <#
    .SYNOPSIS
        Baut aus den Tenant-Kennzahlen die Karteninhalte (reine Funktion, testbar).
    .OUTPUTS
        @{ Title; Level; Rows; Facts; Lines }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statuses,
        [int]$SecretWarnDays = 30,
        [int]$NonCompliantWarn = 1,
        [int]$StaleWarn = 5,
        [string]$Title = 'Tages-Ampel'
    )
    $rows = @(); $worst = 0
    $sumDev = 0; $sumNc = 0; $sumStale = 0; $secretLines = @()
    foreach ($s in $Statuses) {
        $lvl = 0; $parts = @()
        if (-not $s.Ok) {
            $lvl = 2; $parts += "nicht erreichbar: $($s.Error)"
        }
        else {
            $sumDev += $s.Devices; $sumNc += $s.NonCompliant; $sumStale += $s.Stale
            $parts += "$($s.Devices) Geraete"
            if ($s.NonCompliant -ge $NonCompliantWarn -and $s.NonCompliant -gt 0) { $parts += "$($s.NonCompliant) nicht konform"; $lvl = [math]::Max($lvl, 1) }
            if ($s.Stale -ge $StaleWarn -and $s.Stale -gt 0) { $parts += "$($s.Stale) ohne Sync seit $($s.StaleDays) Tagen"; $lvl = [math]::Max($lvl, 1) }
            if ($s.NonCompliant -gt 0 -and $s.Devices -gt 0 -and ($s.NonCompliant / $s.Devices) -ge 0.1) { $lvl = 2 }
        }
        if ($null -ne $s.SecretDays) {
            if ($s.SecretDays -le 0) { $parts += 'App-Secret ABGELAUFEN'; $lvl = 2; $secretLines += "$($s.Name): App-Secret abgelaufen" }
            elseif ($s.SecretDays -le $SecretWarnDays) { $parts += "App-Secret noch $($s.SecretDays) Tage"; $lvl = [math]::Max($lvl, 1); $secretLines += "$($s.Name): App-Secret laeuft in $($s.SecretDays) Tagen ab" }
        }
        elseif ($s.Ok -and $s.SecretStatus -eq 'NoPermission') { $parts += 'Secret-Ablauf nicht lesbar (Application.Read.All)' }
        $worst = [math]::Max($worst, $lvl)
        $rows += @{ Name = $s.Name; Status = @('OK', 'Warning', 'Error')[$lvl]; Text = ($parts -join ', ') }
    }
    $facts = [ordered]@{ 'Geraete gesamt' = $sumDev; 'Nicht konform' = $sumNc; 'Ohne Sync' = $sumStale; 'Tenants' = "$(@($Statuses | Where-Object { $_.Ok }).Count) von $(@($Statuses).Count) erreichbar" }
    return @{
        Title = "$Title - $((Get-Date).ToString('ddd dd.MM.'))"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = $facts
        Lines = $secretLines
    }
}


function Get-HUTeamsKinds {
    <#
    .SYNOPSIS
        Verfuegbare Auftragsarten (Key, Label, Category, OnlyFindings) fuer die Oberflaeche.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{ Key = 'Daily';    Label = 'Tages-Ampel';      Category = 'Daily';    OnlyFindings = $false }
    [pscustomobject]@{ Key = 'Secrets';  Label = 'Secret-Countdown'; Category = 'Secrets';  OnlyFindings = $true }
    [pscustomobject]@{ Key = 'Licenses'; Label = 'Lizenzen knapp';   Category = 'Licenses'; OnlyFindings = $true }
    [pscustomobject]@{ Key = 'Defender'; Label = 'Defender-Alarm';   Category = 'Defender'; OnlyFindings = $true }
}

function Get-HUSecretStatus {
    <#
    .SYNOPSIS
        Secret-Ablauf eines Tenants (Graph, nur lesend). Braucht Application.Read.All.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)][PSCustomObject]$Settings)
    $t = $Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    $r = [pscustomobject]@{ Key = $TenantKey; Name = "$(if ($t) { $t.displayName } else { $TenantKey })"; Ok = $false; Error = ''; Days = $null; DisplayName = ''; Status = '' }
    $tok = $null
    try { $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop } catch { $r.Error = "Token: $($_.Exception.Message)"; return $r }
    if (-not $tok) { $r.Error = 'Kein Token (Secret fehlt oder abgelaufen)'; return $r }
    try {
        $sec = Get-AppSecretExpiry -TenantKey $TenantKey -Settings $Settings -Token $tok -ErrorAction Stop
        $r.Status = "$($sec.Status)"; $r.DisplayName = "$($sec.DisplayName)"; $r.Ok = $true
        if ($sec.Status -eq 'OK' -and $sec.EndDate) { $r.Days = [int][math]::Floor(([datetime]$sec.EndDate - (Get-Date)).TotalDays) }
        elseif ($sec.Status -ne 'OK') { $r.Ok = $false; $r.Error = $(if ($sec.Status -eq 'NoPermission') { 'Secret-Ablauf nicht lesbar (Application.Read.All fehlt)' } else { "$($sec.Error)" }) }
    }
    catch { $r.Error = "Secret: $(($_.Exception.Message) -replace '\s+', ' ')" }
    return $r
}

function New-HUSecretsCardSpec {
    <#
    .SYNOPSIS
        Karteninhalt Secret-Countdown (reine Funktion). $null = nichts zu melden.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statuses, [int]$WarnDays = 30, [string]$Title = 'Secret-Countdown')
    $rows = @(); $worst = 0
    foreach ($s in $Statuses) {
        if (-not $s.Ok) { $rows += @{ Name = $s.Name; Status = 'Error'; Text = "$($s.Error)" }; $worst = 2; continue }
        if ($null -eq $s.Days) { continue }
        if ($s.Days -le 0) { $rows += @{ Name = $s.Name; Status = 'Error'; Text = "App-Secret ABGELAUFEN ($($s.DisplayName))" }; $worst = 2 }
        elseif ($s.Days -le $WarnDays) { $rows += @{ Name = $s.Name; Status = 'Warning'; Text = "App-Secret laeuft in $($s.Days) Tagen ab ($($s.DisplayName))" }; $worst = [math]::Max($worst, 1) }
    }
    if (-not $rows.Count) { return $null }
    return @{
        Title = "$Title - $((Get-Date).ToString('ddd dd.MM.'))"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = [ordered]@{ 'Warnschwelle' = "unter $WarnDays Tagen"; 'Betroffen' = $rows.Count }
        Lines = @('App-Registrierung: Entra admin center > App-Registrierungen > Zertifikate und Geheimnisse. Neues Secret danach in HU-MultiTenant unter Einstellungen > Tenants eintragen.')
    }
}

function Get-HULicenseStatus {
    <#
    .SYNOPSIS
        Lizenzbestand eines Tenants (/subscribedSkus). Braucht Organization.Read.All.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)][PSCustomObject]$Settings)
    $t = $Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    $r = [pscustomobject]@{ Key = $TenantKey; Name = "$(if ($t) { $t.displayName } else { $TenantKey })"; Ok = $false; Error = ''; Skus = @() }
    $tok = $null
    try { $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop } catch { $r.Error = "Token: $($_.Exception.Message)"; return $r }
    if (-not $tok) { $r.Error = 'Kein Token (Secret fehlt oder abgelaufen)'; return $r }
    try {
        $skus = @(Invoke-GraphRequestAll -Token $tok -Endpoint '/subscribedSkus' -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop)
        $r.Skus = @($skus | Where-Object { "$($_.capabilityStatus)" -eq 'Enabled' } | ForEach-Object {
            $total = [int]$_.prepaidUnits.enabled
            [pscustomobject]@{ Sku = "$($_.skuPartNumber)"; Total = $total; Used = [int]$_.consumedUnits; Free = ($total - [int]$_.consumedUnits) }
        })
        $r.Ok = $true
    }
    catch { $r.Error = "Lizenzen: $(($_.Exception.Message) -replace '\s+', ' ')" }
    return $r
}

function New-HULicenseCardSpec {
    <#
    .SYNOPSIS
        Karteninhalt Lizenzen knapp (reine Funktion). $null = nichts zu melden.
        Gemeldet werden SKUs mit weniger als MinFree freien Lizenzen (unbegrenzte/0-Kontingente ausgenommen).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statuses, [int]$MinFree = 5, [string]$Title = 'Lizenzen knapp')
    $rows = @(); $worst = 0
    foreach ($s in $Statuses) {
        if (-not $s.Ok) { $rows += @{ Name = $s.Name; Status = 'Error'; Text = "$($s.Error)" }; $worst = 2; continue }
        $low = @($s.Skus | Where-Object { $_.Total -gt 0 -and $_.Free -lt $MinFree })
        if (-not $low.Count) { continue }
        $txt = @($low | Sort-Object Free | ForEach-Object { "$($_.Sku): noch $($_.Free) von $($_.Total) frei" }) -join '; '
        $over = @($low | Where-Object { $_.Free -lt 0 })
        $lvl = if ($over.Count) { 2 } else { 1 }
        $worst = [math]::Max($worst, $lvl)
        $rows += @{ Name = $s.Name; Status = @('OK', 'Warning', 'Error')[$lvl]; Text = $txt }
    }
    if (-not $rows.Count) { return $null }
    return @{
        Title = "$Title - $((Get-Date).ToString('ddd dd.MM.'))"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = [ordered]@{ 'Warnschwelle' = "weniger als $MinFree frei"; 'Tenants betroffen' = $rows.Count }
        Lines = @()
    }
}

function Get-HUDefenderStatus {
    <#
    .SYNOPSIS
        Defender-/Bedrohungszustand der Geraete eines Tenants (partnerReportedThreatState aus Intune).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)][PSCustomObject]$Settings)
    $t = $Settings.tenants | Where-Object { $_.key -eq $TenantKey } | Select-Object -First 1
    $r = [pscustomobject]@{ Key = $TenantKey; Name = "$(if ($t) { $t.displayName } else { $TenantKey })"; Ok = $false; Error = ''; Devices = 0; Findings = @() }
    $tok = $null
    try { $tok = Get-GraphToken -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop } catch { $r.Error = "Token: $($_.Exception.Message)"; return $r }
    if (-not $tok) { $r.Error = 'Kein Token (Secret fehlt oder abgelaufen)'; return $r }
    try {
        $ep = '/deviceManagement/managedDevices?$select=id,deviceName,partnerReportedThreatState&$top=999'
        $devs = @(Invoke-GraphRequestAll -Token $tok -Endpoint $ep -TenantKey $TenantKey -Settings $Settings -ErrorAction Stop)
        $r.Devices = $devs.Count
        $bad = @{ 'highSeverity' = 'Bedrohung (hoch)'; 'mediumSeverity' = 'Bedrohung (mittel)'; 'compromised' = 'kompromittiert'; 'misconfigured' = 'fehlkonfiguriert' }
        $r.Findings = @($devs | Where-Object { $bad.ContainsKey("$($_.partnerReportedThreatState)") } | ForEach-Object {
            [pscustomobject]@{ Device = "$($_.deviceName)"; State = $bad["$($_.partnerReportedThreatState)"] }
        })
        $r.Ok = $true
    }
    catch { $r.Error = "Defender: $(($_.Exception.Message) -replace '\s+', ' ')" }
    return $r
}

function New-HUDefenderCardSpec {
    <#
    .SYNOPSIS
        Karteninhalt Defender-Alarm (reine Funktion). $null = nichts zu melden.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statuses, [int]$MaxDevices = 10, [string]$Title = 'Defender-Alarm')
    $rows = @(); $worst = 0
    foreach ($s in $Statuses) {
        if (-not $s.Ok) { $rows += @{ Name = $s.Name; Status = 'Error'; Text = "$($s.Error)" }; $worst = 2; continue }
        if (-not @($s.Findings).Count) { continue }
        $names = @($s.Findings | Select-Object -First $MaxDevices | ForEach-Object { "$($_.Device) ($($_.State))" })
        $more = @($s.Findings).Count - $names.Count
        $txt = ($names -join ', ') + $(if ($more -gt 0) { " und $more weitere" })
        $rows += @{ Name = $s.Name; Status = 'Error'; Text = $txt }
        $worst = 2
    }
    if (-not $rows.Count) { return $null }
    return @{
        Title = "$Title - $((Get-Date).ToString('ddd dd.MM.'))"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = [ordered]@{ 'Geraete mit Befund' = (@($Statuses | ForEach-Object { @($_.Findings).Count } | Measure-Object -Sum).Sum) }
        Lines = @('Quelle: von Defender an Intune gemeldeter Bedrohungszustand der Geraete.')
    }
}

# ============================================================================
# AUSFUEHRUNG
# ============================================================================

function Invoke-HUTeamsJob {
    <#
    .SYNOPSIS
        Fuehrt einen Auftrag aus und sendet die Karte an die Teams-Ziele. Wirft nie.
    .PARAMETER TargetIds
        Einmalig nur an diese Ziele senden (statt der am Auftrag gespeicherten Ziele).
    .OUTPUTS
        @{ Success; Message; Sent; Spec }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][string]$AppRoot,
        [switch]$NoSend,
        [string[]]$TargetIds = @()
    )
    $res = [pscustomobject]@{ Success = $false; Message = ''; Sent = ''; Spec = $null }
    try {
        $keys = @($Job.Tenants | Where-Object { "$_" })
        if (-not $keys.Count) { $keys = @($Settings.tenants | ForEach-Object { "$($_.key)" }) }
        if (-not $keys.Count) { $res.Message = 'Keine Tenants'; return $res }
        $log = Get-Command Write-HULog -ErrorAction SilentlyContinue
        $warn = 30; try { $warn = [int]$Settings.ui.secretWarnDays } catch { }
        $opt = { param($n, $d) try { if ($Job.Options.PSObject.Properties[$n]) { return [int]$Job.Options.$n } } catch { }; return $d }
        $spec = $null
        $readLog = { param($k) if ($log) { Write-HULog -Message "[Teams] $($Job.Name): $k lesen ..." -Level INFO } }
        switch ("$($Job.Kind)") {
            'Daily' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUDailyTenantStatus -TenantKey $k -Settings $Settings -StaleDays (& $opt 'staleDays' 7) }
                $spec = New-HUDailyCardSpec -Statuses $st -SecretWarnDays $warn -Title "$($Job.Name)"
            }
            'Secrets' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUSecretStatus -TenantKey $k -Settings $Settings }
                $spec = New-HUSecretsCardSpec -Statuses $st -WarnDays (& $opt 'warnDays' $warn) -Title "$($Job.Name)"
            }
            'Licenses' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HULicenseStatus -TenantKey $k -Settings $Settings }
                $spec = New-HULicenseCardSpec -Statuses $st -MinFree (& $opt 'minFree' 5) -Title "$($Job.Name)"
            }
            'Defender' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUDefenderStatus -TenantKey $k -Settings $Settings }
                $spec = New-HUDefenderCardSpec -Statuses $st -Title "$($Job.Name)"
            }
            default { $res.Message = "Unbekannte Auftragsart: $($Job.Kind)"; return $res }
        }
        $res.Spec = $spec
        if ($null -eq $spec) { $res.Success = $true; $res.Message = 'Nichts zu melden - keine Karte gesendet'; return $res }
        if ($NoSend) { $res.Success = $true; $res.Message = 'Vorschau'; return $res }
        $cat = "$((Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($Job.Kind)" }).Category)"; if (-not $cat) { $cat = 'Daily' }
        # Ziele: einmalige Auswahl > am Auftrag gespeicherte > alle aktiven
        $ids = @($TargetIds | Where-Object { "$_" })
        if (-not $ids.Count) { $ids = @($Job.Targets | Where-Object { "$_" }) }
        $sent = Send-HUNotify -Category $cat -Title $spec.Title -Level $spec.Level -Rows $spec.Rows -Facts $spec.Facts -Lines $spec.Lines -Source "$([Environment]::MachineName)" -TargetIds $ids -IgnoreCategory
        $res.Sent = $sent
        if (-not $sent) { $res.Message = $(if ($ids.Count) { 'Ziel nicht gefunden oder ausgeschaltet - nichts gesendet' } else { 'Kein aktives Ziel - nichts gesendet' }); $res.Success = $true }
        elseif ($sent -match '(?i)gesendet') { $res.Success = $true; $res.Message = $sent }
        else { $res.Message = $sent }
    }
    catch { $res.Message = "Fehler: $(($_.Exception.Message) -replace 'https?://\S+', '(Webhook)')" }
    finally {
        if ($Job.Id -and -not $NoSend) { Update-HUTeamsJobResult -AppRoot $AppRoot -Id "$($Job.Id)" -Result $(if ($res.Success) { "OK $($res.Message)" } else { "FEHLER $($res.Message)" }) }
    }
    return $res
}

# ============================================================================
# AUFGABENPLANUNG
# ============================================================================

function Get-HUTeamsJobTaskName {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Job)
    return "$($script:TeamsTaskPrefix)$($Job.Id)"
}

function Get-HUTeamsJobTask {
    <#
    .SYNOPSIS
        Zustand der Aufgabe. Rueckgabe: @{ Exists; State; NextRun; LastRun; LastResult }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Job)
    $r = [pscustomobject]@{ Exists = $false; State = ''; NextRun = $null; LastRun = $null; LastResult = $null }
    try {
        $t = Get-ScheduledTask -TaskName (Get-HUTeamsJobTaskName $Job) -TaskPath $script:TeamsTaskPath -ErrorAction Stop
        $r.Exists = $true; $r.State = "$($t.State)"
        $i = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        if ($i) { $r.NextRun = $i.NextRunTime; $r.LastRun = $i.LastRunTime; $r.LastResult = $i.LastTaskResult }
    }
    catch { }
    return $r
}

function Register-HUTeamsJobTask {
    <#
    .SYNOPSIS
        Legt die Aufgabe fuer einen Auftrag an (im Konto des Benutzers, ohne erhoehte Rechte). Rueckgabe: '' oder Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$AppRoot)
    try {
        $main = Join-Path $AppRoot 'Main.ps1'
        if (-not (Test-Path -LiteralPath $main)) { return "Main.ps1 nicht gefunden: $main" }
        if ("$($Job.Time)" -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { return "Uhrzeit ungueltig: $($Job.Time)" }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$main`" -Headless -Job $($Job.Id)"
        $a = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $AppRoot
        $at = [datetime]::ParseExact("$($Job.Time)", 'H:mm', $null)
        $days = @($Job.Days | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 7 })
        if ($days.Count) {
            $dow = @($days | ForEach-Object { @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')[$_ - 1] })
            $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dow -At $at
        }
        else { $trg = New-ScheduledTaskTrigger -Daily -At $at }
        $uid = "$env:USERDOMAIN\$env:USERNAME"
        $pr = New-ScheduledTaskPrincipal -UserId $uid -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $desc = "HU-MultiTenant: Teams-Meldung '$($Job.Name)' ($($Job.Kind)). Verwalten: HU-MultiTenant > Teams."
        Register-ScheduledTask -TaskName (Get-HUTeamsJobTaskName $Job) -TaskPath $script:TeamsTaskPath -Action $a -Trigger $trg -Principal $pr -Settings $set -Description $desc -Force -ErrorAction Stop | Out-Null
        return ''
    }
    catch { return "Aufgabe nicht angelegt: $($_.Exception.Message)" }
}

function Unregister-HUTeamsJobTask {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Job)
    try {
        $n = Get-HUTeamsJobTaskName $Job
        if (Get-ScheduledTask -TaskName $n -TaskPath $script:TeamsTaskPath -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $n -TaskPath $script:TeamsTaskPath -Confirm:$false -ErrorAction Stop
        }
        return ''
    }
    catch { return "Aufgabe nicht entfernt: $($_.Exception.Message)" }
}

Export-ModuleMember -Function @(
    'Get-HUTeamsJobsPath',
    'New-HUTeamsJob',
    'Get-HUTeamsJobs',
    'Get-HUTeamsJob',
    'Set-HUTeamsJobs',
    'Update-HUTeamsJobResult',
    'Get-HUTeamsKinds',
    'Get-HUDailyTenantStatus',
    'New-HUDailyCardSpec',
    'Get-HUSecretStatus',
    'New-HUSecretsCardSpec',
    'Get-HULicenseStatus',
    'New-HULicenseCardSpec',
    'Get-HUDefenderStatus',
    'New-HUDefenderCardSpec',
    'Invoke-HUTeamsJob',
    'Get-HUTeamsJobTaskName',
    'Get-HUTeamsJobTask',
    'Register-HUTeamsJobTask',
    'Unregister-HUTeamsJobTask'
)
