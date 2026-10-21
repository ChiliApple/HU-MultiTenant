#Requires -Version 5.1

<#
.SYNOPSIS
    HU.TeamsJobs - zeitgesteuerte Teams-Meldungen (Auftraege, Datenerhebung, Aufgabenplanung) fuer HU-MultiTenant.
.DESCRIPTION
    Eine Meldung (intern: Auftrag/Job) beschreibt, WAS wann an welche Ziele gemeldet wird.
    Eingebaute Meldungen:
      Kind 'Daily'    Tages-Ampel: je Tenant Geraete, nicht konform, ohne Sync, Secret-Ablauf. Sendet immer.
      Kind 'Secrets'  Secret-Countdown: App-Secrets, die in <= warnDays ablaufen. Sendet nur bei Befund.
      Kind 'Licenses' Lizenzen knapp: SKUs mit weniger als minFree freien Lizenzen. Sendet nur bei Befund.
      Kind 'Defender' Defender-Alarm: Geraete mit gemeldeter Bedrohung oder Fehlkonfiguration. Sendet nur bei Befund.
      Kind 'SecDrift' Sicherheits-Aenderung: Sicherheitskatalog gegen den gespeicherten Soll-Stand (Analyse > Sicherheit > Soll speichern). Sendet nur bei Aenderung.
    Meldung aus Skript:
      Kind 'Script'   fuehrt ein gespeichertes Quick-Script-Snippet (Options.snippet = Name) je Tenant aus, mit den
                      Werten seiner @param-Zeilen (an der Meldung gespeichert, sonst Standard). Jedes Send-HUNotify im Snippet geht an die Ziele der Meldung.
                      Ruft das Snippet kein Send-HUNotify auf, wird seine Ausgabe (Objekte/Text, sonst Write-Host) als eine Karte
                      gesendet. Nutzt es keinen Tenant-Bezug ($TenantKey/$Token ...), laeuft es nur einmal.
    Meldungen liegen in Config\teams-jobs.json (lokal, nicht im Repository). Sie enthalten keine Adressen -
    gesendet wird ueber die Ziele aus HU.Notify (am Auftrag gespeicherte Ziel-Ids).

    Ausfuehrung:
      - aus der Oberflaeche (Reiter Teams > "Jetzt senden")
      - zeitgesteuert ueber die Windows-Aufgabenplanung, Aufgabe \HU-MultiTenant\Teams-<Id>, laeuft im Konto des
        Benutzers (DPAPI-Secrets, LogonType Interactive, ohne erhoehte Rechte) und ruft
        Main.ps1 -Headless -Job <Id>  auf. Der Headless-Lauf kennt NUR gespeicherte Auftraege und die darin
        genannten gespeicherten Snippets (Config\quick-snippets.json) - keinen freien Code von der Kommandozeile.

    Logik ohne Oberflaeche, PowerShell 5.1 und 7 (Windows).
.NOTES
    Modul: HU.TeamsJobs.psm1
    Projekt: HU-MultiTenant
    Version: 1.1.0
    Zielmaschine: Admin-PC (Benutzerkontext).
#>

$script:TeamsJobsFile = 'Config\teams-jobs.json'
$script:TeamsTaskPath = '\HU-MultiTenant\'
$script:TeamsTaskPrefix = 'Teams-'
$script:TeamsJobKinds = @('Daily', 'Secrets', 'Licenses', 'Defender', 'SecDrift', 'Script')
$script:TeamsScriptTimeoutMin = 25   # Meldung aus Skript: laengste Laufzeit (Aufgabenplanung bricht nach 30 min ab, Review 030 B40)
$script:TeamsJobIdPattern = '^[0-9a-f]{8}$'
$script:TeamsDayNames = @('So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa')   # [DayOfWeek] 0 = Sonntag

function Get-HUTeamsDateLabel {
    # Datum fuer Kartentitel, unabhaengig von der Kultur des Kontos (Review 029 B22/Q8): "Fr 16.10."
    param([datetime]$Date = (Get-Date))
    return "$($script:TeamsDayNames[[int]$Date.DayOfWeek]) $($Date.ToString('dd.MM.', [cultureinfo]::InvariantCulture))"
}

function Get-HUTeamsCountText {
    # "1 Tenant" / "2 Tenants" (Review 030 B22)
    param([int]$Count, [string]$One, [string]$Many)
    return "$Count $(if ($Count -eq 1) { $One } else { $Many })"
}

function ConvertTo-HUTeamsBool {
    # Von Hand bearbeitete Dateien: "false"/"0"/"nein" als Text gelten als aus (Review 029 B21/Q7)
    param($Value, [bool]$Default = $true)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return ("$Value".Trim() -notmatch '^(?i)(false|0|no|nein|aus|off|)$') }
    return [bool]$Value
}

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
        [ValidateSet('Daily', 'Secrets', 'Licenses', 'Defender', 'SecDrift', 'Script')][string]$Kind = 'Daily',
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
        $raw = $null
        try { $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch {
            # Review 029 B20/Q6: kaputte Datei -> letzte gueltige Sicherung verwenden (sonst Fehler wie bisher)
            $err = $_.Exception.Message
            $bak = "$p.bak"
            if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { throw $err }
            try { $raw = Get-Content -LiteralPath $bak -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw $err }
            $log = Get-Command Write-HULog -ErrorAction SilentlyContinue
            if ($log) { Write-HULog -Message "[TeamsJobs] teams-jobs.json nicht lesbar ($err) - verwende teams-jobs.json.bak" -Level WARN }
        }
        $list = @($raw.jobs | Where-Object { $_ -and "$($_.Id)" })
        foreach ($j in $list) {
            foreach ($k in 'Tenants', 'Days', 'Targets') { if (-not $j.PSObject.Properties[$k] -or $null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force } }
            foreach ($k in 'LastRun', 'LastResult', 'Time', 'Category') { if (-not $j.PSObject.Properties[$k] -or $null -eq $j.$k) { $j | Add-Member -NotePropertyName $k -NotePropertyValue '' -Force } }
            $j | Add-Member -NotePropertyName Enabled -NotePropertyValue (ConvertTo-HUTeamsBool $(if ($j.PSObject.Properties['Enabled']) { $j.Enabled }) $true) -Force
            if (-not $j.PSObject.Properties['Options'] -or $null -eq $j.Options) { $j | Add-Member -NotePropertyName Options -NotePropertyValue ([pscustomobject]@{}) -Force }
        }
        return $list
    }
    catch { throw "teams-jobs.json nicht lesbar: $($_.Exception.Message)" }
}

function Invoke-HUTeamsJobsLocked {
    # Kurze prozessuebergreifende Sperre (GUI vs. Aufgabenplanung) um Lesen+Schreiben von teams-jobs.json
    param([Parameter(Mandatory)][scriptblock]$Do)
    $m = New-Object System.Threading.Mutex($false, 'Local\HU-MultiTenant_TeamsJobs')
    $got = $false
    try { $got = $m.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        # Review 029 Q2: nach Zeitueberschreitung NICHT ungesperrt lesen+schreiben (lost update) - Aufrufer faengt ab
        $m.Dispose()
        $log = Get-Command Write-HULog -ErrorAction SilentlyContinue; if ($log) { Write-HULog -Message '[TeamsJobs] Sperre nicht erhalten (5 s) - Vorgang abgebrochen' -Level WARN }
        throw 'teams-jobs.json gerade gesperrt (anderer HU-MultiTenant-Vorgang) - bitte erneut versuchen'
    }
    try { & $Do } finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
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
        if ("$($j.Id)" -notmatch $script:TeamsJobIdPattern) { throw "Auftrags-Id ungueltig: '$($j.Id)'" }
        if ("$($j.Time)" -and "$($j.Time)" -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "Uhrzeit ungueltig: $($j.Time) (HH:mm)" }
    }
    $doc = [ordered]@{ v = 1; updated = (Get-Date).ToString('s'); jobs = @($Jobs) }
    $json = ConvertTo-Json -InputObject $doc -Depth 8
    $tmp = "$p.tmp.$PID"
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
        Invoke-HUTeamsJobsLocked {
            $jobs = @(Get-HUTeamsJobs -AppRoot $AppRoot)
            $j = $jobs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
            if (-not $j) { return }
            $j.LastRun = (Get-Date).ToString('s')
            $j.LastResult = "$Result"
            Set-HUTeamsJobs -AppRoot $AppRoot -Jobs $jobs
        }
    }
    catch {
        $log = Get-Command Write-HULog -ErrorAction SilentlyContinue
        if ($log) { Write-HULog -Message "[TeamsJobs] Ergebnis nicht gespeichert: $($_.Exception.Message)" -Level WARN } else { Write-Verbose "[TeamsJobs] Ergebnis nicht gespeichert: $($_.Exception.Message)" }
    }
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
        elseif ($s.Ok -and "$($s.SecretStatus)" -ne 'OK') { $parts += 'Secret-Ablauf unbekannt'; $lvl = [math]::Max($lvl, 1); $worst = [math]::Max($worst, 1) }
        elseif ($s.Ok) { $parts += 'Secret-Ablauf unbekannt (kein Ablaufdatum)' }   # B8c: OK, aber kein Enddatum - nur Hinweis
        $worst = [math]::Max($worst, $lvl)
        $rows += @{ Name = $s.Name; Status = @('OK', 'Warning', 'Error')[$lvl]; Text = ($parts -join ', ') }
    }
    $facts = [ordered]@{ 'Geraete gesamt' = $sumDev; 'Nicht konform' = $sumNc; 'Ohne Sync' = $sumStale; 'Tenants' = "$(@($Statuses | Where-Object { $_.Ok }).Count) von $(@($Statuses).Count) erreichbar" }
    # Push-Vorschau (B16): Zusammenfassung ohne Geraetenamen - Ampel je Tenant + Summen
    $yel = @($rows | Where-Object { $_.Status -eq 'Warning' } | ForEach-Object { "$($_.Name)" })
    $red = @($rows | Where-Object { $_.Status -eq 'Error' } | ForEach-Object { "$($_.Name)" })
    $pv = "$(@($rows).Count - $yel.Count - $red.Count) gruen, $($yel.Count) gelb, $($red.Count) rot"
    if ($red.Count) { $pv += " (rot: $($red -join ', '))" }
    elseif ($yel.Count) { $pv += " (gelb: $($yel -join ', '))" }
    $pv += " - $sumDev Geraete, $sumNc nicht konform"
    return @{
        Title   = "$Title - $(Get-HUTeamsDateLabel)"
        Level   = @('OK', 'Warning', 'Error')[$worst]
        Rows    = $rows
        Facts   = $facts
        Lines   = $secretLines
        Preview = $pv
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
    [pscustomobject]@{ Key = 'SecDrift'; Label = 'Sicherheits-Aenderung'; Category = 'Security'; OnlyFindings = $true }
    [pscustomobject]@{ Key = 'Script';   Label = 'Aus Skript';       Category = '';         OnlyFindings = $true }
}

function Get-HUTeamsSnippetCode {
    <#
    .SYNOPSIS
        Code eines gespeicherten Quick-Script-Snippets (Config\quick-snippets.json). Wirft, wenn es fehlt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Name)
    $p = Join-Path $AppRoot 'Config\quick-snippets.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Snippet '$Name' nicht gefunden (keine Snippet-Datei)" }
    $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $raw = if ($json.PSObject.Properties['snippets']) { @($json.snippets) } else { @($json) }
    $s = @($raw | Where-Object { $_ -and "$($_.name)".Trim() -eq $Name.Trim() }) | Select-Object -First 1
    if (-not $s -or -not "$($s.code)".Trim()) { throw "Snippet '$Name' nicht gefunden (Quick Script > Snippets - umbenannt oder geloescht?)" }
    return "$($s.code)"
}

function Get-HUTeamsCodeHash {
    <#
    .SYNOPSIS
        SHA-256 des Skript-Codes (Zeilenenden vereinheitlicht) - Fingerabdruck fuer die Freigabe einer Skript-Meldung (Review 030 B33).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Code)
    $norm = ("$Code" -replace "`r`n", "`n").TrimEnd()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-HUTeamsScript {
    <#
    .SYNOPSIS
        Meldung aus Skript: Snippet in eigenen, frischen Runspaces ausfuehren (Review 030 B35); Send-HUNotify geht an die
        Ziele der Meldung.
    .PARAMETER RunOnce
        Skript laeuft EINMAL (eigene Schleife ueber $Tenants = die gewaehlten Tenant-Schluessel); ohne Schalter je Tenant mit
        $TenantKey/$Token. Ausdrueckliche Einstellung an der Meldung statt Textsuche (Review 030 B38).
    .PARAMETER SendOutput
        Ruft das Skript kein Send-HUNotify auf, geht seine Ausgabe als EINE Karte an die Ziele - Objekte/Text, sonst die
        Write-Host-Zeilen. Standard aus: dann gehen nur Karten aus Send-HUNotify raus (Review 030 B37).
    .OUTPUTS
        @{ Calls; Ok; Failed; Errors }  (Calls = Anzahl Send-HUNotify-Aufrufe, inkl. Ausgabe-Karte)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Tenants,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][string]$AppRoot,
        [string[]]$TargetIds = @(),
        [System.Collections.IDictionary]$Params = @{},   # Werte fuer die @param-Zeilen (an der Meldung gespeichert); fehlende = Standard
        [switch]$RunOnce,
        [switch]$SendOutput
    )
    $out = [pscustomobject]@{ Calls = 0; Ok = 0; Failed = 0; Errors = @() }
    $errs = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[string]
    $deadline = (Get-Date).AddMinutes($script:TeamsScriptTimeoutMin)
    $log = Get-Command Write-HULog -ErrorAction SilentlyContinue
    $dn = @{}; foreach ($x in @($Settings.tenants)) { if ($x -and "$($x.key)") { $dn["$($x.key)"] = $(if ("$($x.displayName)") { "$($x.displayName)" } else { "$($x.key)" }) } }
    $runs = @(if ($RunOnce) { '*' } else { $Tenants })   # @( ) aussen: sonst wird aus einem Tenant ein String und $runs[0] ein Buchstabe
    $multi = (-not $RunOnce) -and $runs.Count -gt 1
    foreach ($tk in $runs) {
        $tag = if ($RunOnce) { 'einmal' } else { $tk }
        $left = ($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0) { $errs.Add("[$tag] uebersprungen - Zeitlimit $($script:TeamsScriptTimeoutMin) Minuten erreicht"); continue }
        $rs = [runspacefactory]::CreateRunspace()
        $ps = $null; $hung = $false
        try {
            $rs.Open()
            # Kopie je Lauf (Review 030 B35): Aenderungen des Skripts an $Settings wirken nicht auf den naechsten Tenant
            $rs.SessionStateProxy.SetVariable('Settings', ($Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json))
            $rs.SessionStateProxy.SetVariable('AppRoot', $AppRoot)
            $rs.SessionStateProxy.SetVariable('__Code', $Code)
            $rs.SessionStateProxy.SetVariable('__Name', $Name)
            $rs.SessionStateProxy.SetVariable('__Tk', $(if ($RunOnce) { '' } else { $tk }))
            $rs.SessionStateProxy.SetVariable('__Tenants', [string[]]@($Tenants))
            $rs.SessionStateProxy.SetVariable('__Multi', $multi)
            $rs.SessionStateProxy.SetVariable('__Label', $(if ($dn.ContainsKey("$tk")) { $dn["$tk"] } else { "$tk" }))
            $rs.SessionStateProxy.SetVariable('__Ids', [string[]]@($TargetIds))
            $rs.SessionStateProxy.SetVariable('__Vals', $Params)
            $rs.SessionStateProxy.SetVariable('__Collect', [bool]$SendOutput)
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript({
                # Ergebnis lebt in globalen Listen - der Aufrufer liest sie auch nach exit/break/Zeitlimit (Review 030 B39)
                $global:__HUErr = New-Object System.Collections.Generic.List[string]
                $global:__HUOut = New-Object System.Collections.Generic.List[string]
                $who = if ($__Tk) { $__Tk } else { 'einmal' }
                foreach ($m in 'HU.Auth', 'HU.Graph', 'HU.Notify') { Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking -ErrorAction Stop }
                . (Join-Path $AppRoot 'Core\HU.QSParams.ps1')
                . (Join-Path $AppRoot 'Core\HU.QSRuntime.ps1')
                Grant-HUSendApproval -Reason "Meldung $__Name"     # gespeicherte Meldung = freigegeben (Review 030 B4a/B33)
                Set-HUNotifyRoute -Name $__Name -TargetIds $__Ids
                $global:Tenants = [string[]]$__Tenants             # einmal-Modus: Schleife ueber die gewaehlten Tenants
                $tokOk = $true
                if ($__Tk) {
                    $global:TenantKey = $__Tk; $global:Schule = $__Tk
                    try { $global:Token = Get-HUToken -Tenant $__Tk } catch { $global:__HUErr.Add("[$who] Kein Token: $($_.Exception.Message)"); $tokOk = $false }
                }
                if ($tokOk) {
                    # @param-Zeilen: Wert der Meldung, sonst Standard (wie die Felder im Quick Script)
                    foreach ($p in @(Get-HUQSParams $__Code)) {
                        $raw = if ($__Vals -and $__Vals.Contains($p.Name)) { $__Vals[$p.Name] } else { $p.Default }
                        try { Set-Variable -Name $p.Name -Value (ConvertTo-HUQSParamValue $p $raw) -Scope Global } catch { $global:__HUErr.Add("[$who] Parameter $($p.Name): $($_.Exception.Message)") }
                    }
                    $res = @()
                    try {
                        $sb = [scriptblock]::Create($__Code)
                        do { $res = @(& $sb) } while ($false)   # ein verirrtes break/continue endet hier
                    } catch { $global:__HUErr.Add("[$who] $($_.Exception.Message)") }
                    if ($__Collect) {
                        foreach ($o in $res) {
                            if ($null -eq $o -or $global:__HUOut.Count -ge 60) { continue }
                            $txt = if ($o -is [string] -or $o -is [ValueType]) { "$o" } else { (@($o.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | Select-Object -First 6 | ForEach-Object { "$($_.Name): $($_.Value)" }) -join ' | ') }
                            if ("$txt".Trim()) { $global:__HUOut.Add($(if ($__Multi) { "$($__Label): $txt" } else { "$txt" })) }
                        }
                    }
                }
            }.ToString())
            $h = $ps.BeginInvoke()
            if (-not $h.AsyncWaitHandle.WaitOne([TimeSpan]::FromMilliseconds($left))) {
                # Review 030 B53: Stop wartet auf blockierende .NET-Aufrufe - hoechstens 10 s, dann aufgeben
                $errs.Add("[$tag] abgebrochen - Zeitlimit $($script:TeamsScriptTimeoutMin) Minuten erreicht")
                try { $sh = $ps.BeginStop($null, $null); if (-not $sh.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(10))) { $hung = $true; $errs.Add("[$tag] haengt - Lauf aufgegeben") } } catch { }
            }
            else {
                try { [void]$ps.EndInvoke($h) } catch { $errs.Add("[$tag] $($_.Exception.Message)") }
            }
            if (-not $hung) {
                foreach ($se in @($ps.Streams.Error | Select-Object -First 3)) { $errs.Add("[$tag] $($se.Exception.Message)") }
                $hostLines = @(@($ps.Streams.Information) | ForEach-Object { "$($_.MessageData)".TrimEnd() } | Where-Object { "$_".Trim() })
                if ($log) { foreach ($s in @($hostLines | Select-Object -First 30)) { Write-HULog -Message "[Teams] $($Name) [$tag]: $s" -Level INFO } }
                # Zaehler und Ausgabe aus dem (noch offenen) Runspace lesen - auch nach exit oder Abbruch
                $q = [powershell]::Create(); $q.Runspace = $rs
                try {
                    [void]$q.AddScript({ $r = Get-HUNotifyRoute; [pscustomobject]@{ Calls = [int]$r.Calls; Ok = [int]$r.Ok; Failed = [int]$r.Failed; Errors = @($global:__HUErr); Lines = @($global:__HUOut) } }.ToString())
                    $d = @($q.Invoke()) | Select-Object -First 1
                } catch { $d = $null } finally { $q.Dispose() }
                if ($d) {
                    $out.Calls += $d.Calls; $out.Ok += $d.Ok; $out.Failed += $d.Failed
                    foreach ($x in @($d.Errors)) { if ($x) { $errs.Add("$x") } }
                    if ($SendOutput -and $d.Calls -eq 0) {
                        # Je Meldung wird entschieden: Ausgabe (Objekte/Text, sonst Write-Host) als Karte
                        $src = if (@($d.Lines).Count) { @($d.Lines) } else { @($hostLines | ForEach-Object { if ($multi) { "$($dn["$tk"]): $_" } else { "$_" } }) }
                        foreach ($x in $src) { if ($x -and $lines.Count -lt 60) { $lines.Add("$x") } }
                    }
                }
                else { $errs.Add("[$tag] Ergebnis nicht lesbar") }
            }
        }
        catch { $errs.Add("[$tag] $($_.Exception.Message)") }
        finally {
            if (-not $hung) { if ($ps) { $ps.Dispose() }; $rs.Dispose() }   # haengender Lauf: nicht blockierend entsorgen
        }
    }
    # Ausgabe-Karte (nur mit -SendOutput und ohne Send-HUNotify im Skript)
    if ($SendOutput -and $out.Calls -eq 0 -and $lines.Count) {
        $prev = Get-HUNotifyRoute   # Review 030 B56: Route des Aufrufers danach wiederherstellen
        try {
            Set-HUNotifyRoute -Name $Name -TargetIds $TargetIds
            $one = (-not $RunOnce) -and $runs.Count -eq 1
            # ein Tenant: Name des Tenants in den Titel (bei mehreren steht er vor jeder Zeile)
            $ttl = if ($one) { "$Name - $($dn["$($runs[0])"])" } else { $Name }
            # Vorschau ohne den Namen (den setzt der Workflow schon davor)
            $pvw = if ($one) { "$($dn["$($runs[0])"]) - $($lines.Count) Eintraege" } else { "$($lines.Count) Eintraege" }
            [void](Send-HUNotify -Title $ttl -Level Info -Lines @($lines) -Preview $pvw)
            $rt = Get-HUNotifyRoute
            $out.Calls += $rt.Calls; $out.Ok += $rt.Ok; $out.Failed += $rt.Failed
        }
        catch { $errs.Add("Ausgabe-Karte: $($_.Exception.Message)") }
        finally { if ($prev) { Set-HUNotifyRoute -Name $prev.Name -TargetIds @($prev.TargetIds) } else { Clear-HUNotifyRoute } }
    }
    $out.Errors = @($errs)
    return $out
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
    $first = @($Statuses | Where-Object { $_.Ok -and $null -ne $_.Days -and $_.Days -le $WarnDays }) | Sort-Object Days | Select-Object -First 1
    $pv = "$(Get-HUTeamsCountText $rows.Count 'Tenant' 'Tenants') betroffen"
    if ($first) { $pv += $(if ($first.Days -le 0) { " - $($first.Name): App-Secret ABGELAUFEN" } else { " - zuerst $($first.Name) in $($first.Days) Tagen" }) }
    return @{
        Preview = $pv
        Title = "$Title - $(Get-HUTeamsDateLabel)"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = [ordered]@{ 'Warnschwelle' = "$WarnDays Tage oder weniger"; 'Betroffen' = $rows.Count }
        Lines = @("App-Registrierung: Entra admin center $([char]0x203A) App-Registrierungen $([char]0x203A) Zertifikate und Geheimnisse. Neues Secret danach in HU-MultiTenant unter Einstellungen $([char]0x203A) Tenants eintragen.")
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
        $r.Skus = @($skus | Where-Object { "$($_.capabilityStatus)" -in 'Enabled', 'Warning' } | ForEach-Object {
            $total = [int]$_.prepaidUnits.enabled
            $nm = "$($_.skuPartNumber)$(if ("$($_.capabilityStatus)" -eq 'Warning') { ' (laeuft aus)' })"
            [pscustomobject]@{ Sku = $nm; Total = $total; Used = [int]$_.consumedUnits; Free = ($total - [int]$_.consumedUnits) }
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
    $tight = @($Statuses | Where-Object { $_.Ok } | ForEach-Object { $tn = $_.Name; @($_.Skus) | Where-Object { $_ -and $_.Total -gt 0 -and $_.Free -lt $MinFree } | ForEach-Object { [pscustomobject]@{ T = $tn; Sku = $_.Sku; Free = $_.Free } } }) | Sort-Object Free | Select-Object -First 1
    $pv = "$(Get-HUTeamsCountText $rows.Count 'Tenant' 'Tenants') betroffen"
    if ($tight) { $pv += " - knappste: $($tight.T) $($tight.Sku) $(if ($tight.Free -lt 0) { "ueberbucht ($($tight.Free))" } else { "noch $($tight.Free) frei" })" }
    return @{
        Preview = $pv
        Title = "$Title - $(Get-HUTeamsDateLabel)"
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Statuses, [int]$MaxDevices = 10, [string]$Title = 'Defender-Alarm', [switch]$MaskDevices)
    $rows = @(); $worst = 0
    foreach ($s in $Statuses) {
        if (-not $s.Ok) { $rows += @{ Name = $s.Name; Status = 'Error'; Text = "$($s.Error)" }; $worst = 2; continue }
        if (-not @($s.Findings).Count) { continue }
        if ($MaskDevices) {
            # B10: Geraetenamen ausblenden (Kanal mit breiterem Publikum) - nur Anzahl je Zustand
            $order = @('kompromittiert', 'Bedrohung (hoch)', 'Bedrohung (mittel)', 'fehlkonfiguriert')   # nach Dringlichkeit (Review 030 B22)
            $txt = (@($s.Findings | Group-Object State | Sort-Object { $i = [array]::IndexOf($order, "$($_.Name)"); if ($i -lt 0) { 99 } else { $i } } | ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ', ') + ' - Geraetenamen ausgeblendet'
        }
        else {
            $names = @($s.Findings | Select-Object -First $MaxDevices | ForEach-Object { "$($_.Device) ($($_.State))" })
            $more = @($s.Findings).Count - $names.Count
            $txt = ConvertTo-HUNotifySafeText -Text ($names -join ', ') -Max 260
            if ($more -gt 0) { $txt += " und $more weitere" }
        }
        $rows += @{ Name = $s.Name; Status = 'Error'; Text = $txt }
        $worst = 2
    }
    if (-not $rows.Count) { return $null }
    $total = 0; foreach ($s in $Statuses) { $total += @($s.Findings).Count }
    $hit = @($Statuses | Where-Object { $_.Ok -and @($_.Findings).Count } | ForEach-Object { "$($_.Name)" })
    $bad = @($Statuses | Where-Object { -not $_.Ok }).Count
    # Push-Vorschau ohne Geraetenamen (B16)
    $pv = "$(Get-HUTeamsCountText $total 'Geraet' 'Geraete') mit Befund$(if ($hit.Count) { " ($($hit -join ', '))" })$(if ($bad) { ", $(Get-HUTeamsCountText $bad 'Tenant' 'Tenants') nicht lesbar" })"
    return @{
        Preview = $pv
        Title = "$Title - $(Get-HUTeamsDateLabel)"
        Level = @('OK', 'Warning', 'Error')[$worst]
        Rows  = $rows
        Facts = [ordered]@{ 'Geraete mit Befund' = $total }
        Lines = @('Quelle: von Defender an Intune gemeldeter Bedrohungszustand der Geraete.')
    }
}

function New-HUSecDriftCardSpec {
    <#
    .SYNOPSIS
        Karteninhalt Sicherheits-Aenderung (reine Funktion): Aenderungen gegen den gespeicherten Soll-Stand. $null = nichts zu melden.
    .PARAMETER Compare
        Ergebnis von Compare-HUSecReference (Changes, Unchecked, Since).
    .PARAMETER Names
        Anzeigenamen je Tenant-Schluessel (sonst der Schluessel).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Compare, [hashtable]$Names = @{}, [string]$Title = 'Sicherheits-Aenderung', [int]$MaxPerTenant = 4, [object[]]$Lost = @(), [int]$SollWorse = 0, [string]$SollPrev = '')
    $ch = @($Compare.Changes)
    $Lost = @($Lost | Where-Object { $_ })
    if (-not $ch.Count -and -not $Lost.Count -and $SollWorse -le 0) { return $null }
    $rows = @()
    $ar = ' ' + [char]0x2192 + ' '   # Pfeil (ueberlebt die Textbereinigung, anders als >)
    foreach ($g in ($ch | Group-Object Tenant | Sort-Object Name)) {
        $nm = if ($Names.ContainsKey("$($g.Name)")) { "$($Names["$($g.Name)"])" } else { "$($g.Name)" }
        $items = @($g.Group)
        $txt = (@($items | Select-Object -First $MaxPerTenant | ForEach-Object {
                    $w = if ($_.Kind -eq 'Anzahl') { "Anzahl $($_.WasCount)$ar$($_.IsCount)" } else { "$($_.Was)$ar$($_.Is)" }
                    "$($_.RuleId) $($_.Title) ($w)"
                }) -join '; ')
        if ($items.Count -gt $MaxPerTenant) { $txt += " und $($items.Count - $MaxPerTenant) weitere" }
        $bad = @($items | Where-Object { $_.Worse }).Count
        $rows += @{ Name = $nm; Status = $(if ($bad) { 'Error' } else { 'Warning' }); Text = (ConvertTo-HUNotifySafeText -Text $txt -Max 400) }
    }
    foreach ($g in ($Lost | Group-Object Tenant | Sort-Object Name)) {
        $nm = if ($Names.ContainsKey("$($g.Name)")) { "$($Names["$($g.Name)"])" } else { "$($g.Name)" }
        $txt = (@($g.Group | Select-Object -First $MaxPerTenant | ForEach-Object { "$($_.RuleId) $($_.Title) (seit $($_.Runs) Laeufen nicht pruefbar$(if ($_.Reason) { ": $($_.Reason)" }))" }) -join '; ')
        $rows += @{ Name = "$nm - Pruefung verloren"; Status = 'Error'; Text = (ConvertTo-HUNotifySafeText -Text $txt -Max 400) }
    }
    $worse = @($ch | Where-Object { $_.Worse }).Count
    $tn = @($ch | Select-Object -ExpandProperty Tenant -Unique).Count
    $pv = if ($ch.Count) { "$(Get-HUTeamsCountText $ch.Count 'Aenderung' 'Aenderungen') in $(Get-HUTeamsCountText $tn 'Tenant' 'Tenants')$(if ($worse) { ", $worse schlechter" })" } else { '' }
    if ($Lost.Count) { $pv = ("$pv$(if ($pv) { ', ' })$(Get-HUTeamsCountText $Lost.Count 'Pruefung' 'Pruefungen') verloren").Trim() }
    if ($SollWorse -gt 0 -and -not $pv) { $pv = "Soll-Stand geaendert: $(Get-HUTeamsCountText $SollWorse 'Regel' 'Regeln') schlechter als vorher" }
    $facts = [ordered]@{ 'Aenderungen' = $ch.Count; 'davon schlechter' = $worse }
    if ($Lost.Count) { $facts['Pruefung verloren'] = $Lost.Count }
    if ($Compare.Unchecked -gt 0) { $facts['Heute nicht pruefbar (im Soll pruefbar)'] = $Compare.Unchecked }
    # Fusszeile: bewusst gefilterte Meldungen (Sollwerte Katalog statusOnly / silent) offenlegen
    $flt = @()
    $hid = 0; try { $hid = [int]$Compare.HiddenCount } catch { }
    $sil = @(); try { $sil = @($Compare.Silent | Where-Object { $_ }) } catch { }
    if ($hid -gt 0) { $flt += "$(Get-HUTeamsCountText $hid 'Zahlenaenderung' 'Zahlenaenderungen') bei Nur-Status-Regeln nicht gemeldet" }
    if ($sil.Count) { $flt += "stumm: $($sil -join ', ')" }
    $fline = if ($flt.Count) { "Gefiltert (Sollwerte Katalog statusOnly/silent): $($flt -join '; ')." } else { '' }
    $since = ''
    try { if ($Compare.Since) { $since = ([datetime]$Compare.Since).ToLocalTime().ToString('dd.MM.yyyy HH:mm', [cultureinfo]::InvariantCulture) } } catch { }
    return @{
        Preview = $pv
        Title = "$Title - $(Get-HUTeamsDateLabel)"
        Level = $(if ($worse -or $Lost.Count) { 'Error' } else { 'Warning' })   # Soll schlechter allein: Warnung
        Rows  = $rows
        Facts = $facts
        Lines = @(@("Vergleich mit dem gespeicherten Soll-Stand$(if ($since) { " vom $since" }). Neuen Stand uebernehmen: Analyse $([char]0x203A) Sicherheit $([char]0x203A) Soll speichern.") + @(if ($SollWorse -gt 0) { "Hinweis: Der Soll-Stand$(if ($since) { " vom $since" }) ist bei $(Get-HUTeamsCountText $SollWorse 'Regel' 'Regeln') schlechter als der vorige - diese Verschlechterungen werden nicht mehr als Aenderung gemeldet." }) + @(if ($fline) { $fline }))
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
        @{ Success; Message; Sent; Spec; Code }
        Code (= Exit-Code im Headless-Lauf, B24): 0 OK/nichts zu melden, 1 Fehler, 2 teilweise gesendet, 3 Konfiguration (Tenants/Ziele/Art)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][PSCustomObject]$Settings,
        [Parameter(Mandatory)][string]$AppRoot,
        [switch]$NoSend,
        [string[]]$TargetIds = @()
    )
    $res = [pscustomobject]@{ Success = $false; Message = ''; Sent = ''; Spec = $null; Code = 1 }
    try {
        $keys = @($Job.Tenants | Where-Object { "$_" })
        if (-not $keys.Count) { $keys = @($Settings.tenants | ForEach-Object { "$($_.key)" } | Where-Object { "$_" }) }   # Eintraege ohne key ueberspringen (Review 029 B18)
        if (-not $keys.Count) { $res.Message = 'Keine Tenants'; $res.Code = 3; return $res }
        $log = Get-Command Write-HULog -ErrorAction SilentlyContinue
        $warn = 30; try { $warn = [int]$Settings.ui.secretWarnDays } catch { }
        if ($warn -le 0) { $warn = 30 }
        $opt = { param($n, $d) try { if ($Job.Options.PSObject.Properties[$n]) { return [int]$Job.Options.$n } } catch { }; return $d }
        $spec = $null
        $detail = ''
        $readLog = { param($k) if ($log) { Write-HULog -Message "[Teams] $($Job.Name): $k lesen ..." -Level INFO } }
        if ("$($Job.Kind)" -eq 'Script') {
            # Meldung aus Skript: das Snippet sendet selbst (Send-HUNotify), an die Ziele dieser Meldung
            $sn = "$($Job.Options.snippet)"
            if (-not $sn) { $res.Message = 'Kein Skript gewaehlt'; $res.Code = 3; return $res }
            try { $code = Get-HUTeamsSnippetCode -AppRoot $AppRoot -Name $sn } catch { $res.Message = "$($_.Exception.Message)"; $res.Code = 3; return $res }
            # Review 030 B33: nur der beim Speichern bestaetigte Code laeuft
            $want = "$(if ($Job.Options.PSObject.Properties['snippetHash']) { $Job.Options.snippetHash })"
            if (-not $want -or $want -ne (Get-HUTeamsCodeHash $code)) { $res.Message = "Skript '$sn' wurde seit dem Speichern der Meldung geaendert - nichts ausgefuehrt. Meldung im Reiter Teams pruefen und neu speichern."; $res.Code = 3; return $res }
            if ($NoSend) { $res.Success = $true; $res.Code = 0; $res.Message = 'Vorschau (Skript wird nicht ausgefuehrt)'; return $res }
            $ids = @($TargetIds | Where-Object { "$_" }); if (-not $ids.Count) { $ids = @($Job.Targets | Where-Object { "$_" }) }
            if ($log) { Write-HULog -Message "[Teams] $($Job.Name): Skript '$sn' auf $($keys.Count) Tenant(s) ..." -Level INFO }
            $pv = [ordered]@{}
            if ($Job.Options.PSObject.Properties['params'] -and $Job.Options.params) { foreach ($pp in $Job.Options.params.PSObject.Properties) { $pv[$pp.Name] = $pp.Value } }
            # Review 030 B38/B37: Laufart und Ausgabe-Karte sind feste Einstellungen der Meldung
            # von Hand bearbeitet: "false"/"0"/"nein"/Unbekanntes = aus; nur 'once' = einmal (Review 030 B69/S1)
            $once = [bool]($Job.Options.PSObject.Properties['runMode'] -and "$($Job.Options.runMode)".Trim() -eq 'once')
            $sendOut = [bool]($Job.Options.PSObject.Properties['sendOutput'] -and (ConvertTo-HUTeamsBool $Job.Options.sendOutput -Default $false))
            $sr = Invoke-HUTeamsScript -Code $code -Name "$($Job.Name)" -Tenants $keys -Settings $Settings -AppRoot $AppRoot -TargetIds $ids -Params $pv -RunOnce:$once -SendOutput:$sendOut
            $errTxt = $(if (@($sr.Errors).Count) { " - Fehler: $((@($sr.Errors) | Select-Object -First 2) -join '; ')$(if (@($sr.Errors).Count -gt 2) { " (+$(@($sr.Errors).Count - 2))" })" } else { '' })
            $cards = Get-HUTeamsCountText $sr.Calls 'Meldung' 'Meldungen'
            $res.Sent = "$($sr.Ok) gesendet, $($sr.Failed) fehlgeschlagen"
            if ($sr.Calls -eq 0) {
                if (@($sr.Errors).Count) { $res.Code = 1; $res.Message = "Nichts gesendet$errTxt" }
                else { $res.Success = $true; $res.Code = 0; $res.Message = "Nichts zu melden - das Skript hat nichts gesendet$(if (-not $sendOut) { ' (Ausgabe als Karte: aus)' })" }
            }
            elseif ($sr.Ok -gt 0 -and $sr.Failed -eq 0 -and -not @($sr.Errors).Count) { $res.Success = $true; $res.Code = 0; $res.Message = "$(Get-HUTeamsCountText $sr.Ok 'Karte' 'Karten') gesendet ($cards)" }
            elseif ($sr.Ok -gt 0 -and $sr.Failed -eq 0) { $res.Code = 2; $res.Message = "$(Get-HUTeamsCountText $sr.Ok 'Karte' 'Karten') gesendet, Skriptfehler bei $(@($sr.Errors).Count) Lauf/Laeufen$errTxt" }   # Review 030 B43
            elseif ($sr.Ok -gt 0) { $res.Code = 2; $res.Message = "Teilweise gesendet: $($sr.Ok) ok, $($sr.Failed) fehlgeschlagen$errTxt" }
            elseif ($sr.Failed -eq 0) { $res.Code = 3; $res.Message = "Kein aktives Ziel - NICHTS gesendet ($cards).$errTxt" }
            else { $res.Code = 1; $res.Message = "Nicht gesendet: $($sr.Failed) fehlgeschlagen$errTxt" }
            return $res
        }
        switch ("$($Job.Kind)") {
            'Daily' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUDailyTenantStatus -TenantKey $k -Settings $Settings -StaleDays (& $opt 'staleDays' 7) }
                $spec = New-HUDailyCardSpec -Statuses $st -SecretWarnDays $warn -Title "$($Job.Name)"
            }
            'Secrets' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUSecretStatus -TenantKey $k -Settings $Settings }
                $spec = New-HUSecretsCardSpec -Statuses $st -WarnDays (& $opt 'warnDays' $warn) -Title "$($Job.Name)"
                $next = @($st | Where-Object { $null -ne $_.Days }) | Sort-Object Days | Select-Object -First 1
                if ($next) { $detail = "fruehester Secret-Ablauf: $($next.Name) in $($next.Days) Tagen" }
            }
            'Licenses' {
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HULicenseStatus -TenantKey $k -Settings $Settings }
                $spec = New-HULicenseCardSpec -Statuses $st -MinFree (& $opt 'minFree' 5) -Title "$($Job.Name)"
                $low = @($st | ForEach-Object { $_.Skus } | Where-Object { $_ -and $_.Total -gt 0 }) | Sort-Object Free | Select-Object -First 1
                if ($low) { $detail = "knappste SKU: $($low.Sku) mit $($low.Free) frei" }
            }
            'Defender' {
                # Review 030 B7: fail-closed - ein vorhandener, aber unklarer Wert maskiert
                $mask = $false
                if ($Job.Options -and $Job.Options.PSObject.Properties['maskDevices']) {
                    $mv = $Job.Options.maskDevices
                    $mask = if ($mv -is [string] -and "$mv".Trim() -notmatch '^(?i)(false|0|no|nein|aus|off|true|1|yes|ja|an|on|)$') { $true } else { ConvertTo-HUTeamsBool $mv $true }
                    if ($mv -is [string] -and "$mv".Trim() -notmatch '^(?i)(false|0|no|nein|aus|off|true|1|yes|ja|an|on|)$' -and $log) { Write-HULog -Message "[Teams] $($Job.Name): maskDevices '$mv' nicht lesbar - Geraetenamen werden ausgeblendet" -Level WARN }
                }
                $st = @(); foreach ($k in $keys) { & $readLog $k; $st += Get-HUDefenderStatus -TenantKey $k -Settings $Settings }
                $spec = New-HUDefenderCardSpec -Statuses $st -Title "$($Job.Name)" -MaskDevices:$mask
                $detail = "$((@($st | ForEach-Object { @($_.Findings).Count }) | Measure-Object -Sum).Sum) Geraete mit Befund, $(@($st | Where-Object { -not $_.Ok }).Count) Tenants nicht lesbar"
            }
            'SecDrift' {
                $ref = $null; try { $ref = Get-HUSecReference } catch { }
                if (-not $ref) { $res.Message = 'Kein Soll-Stand gespeichert (Analyse > Sicherheit > Soll speichern) - nichts verglichen'; $res.Code = 3; return $res }
                $all = @(); $names = @{}
                foreach ($k in $keys) {
                    & $readLog $k
                    $tt = $Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1
                    $names[$k] = "$(if ($tt) { $tt.displayName } else { $k })"
                    try { $all += @(Invoke-HUSecCatalog -TenantKey $k -Settings $Settings) } catch { if ($log) { Write-HULog -Message "[Teams] $($Job.Name): $k Katalog fehlgeschlagen: $($_.Exception.Message)" -Level WARN } }
                }
                $cmp = Compare-HUSecReference -Results $all -Reference $ref -Keys $keys
                $lost = @(); try { $lost = @(Update-HUSecLost -Results $all -Reference $ref -Keys $keys -NoWrite:$NoSend) } catch { }
                $sw = 0; try { if ($ref.PSObject.Properties['worse'] -and -not [bool]$ref.worseShown) { $sw = [int]$ref.worse } } catch { $sw = 0 }
                $spec = New-HUSecDriftCardSpec -Compare $cmp -Names $names -Title "$($Job.Name)" -Lost $lost -SollWorse $sw
                $detail = "$(@($cmp.Changes).Count) Aenderungen, $($cmp.Unchecked) nicht pruefbar, $($lost.Count) Pruefungen verloren"
            }
            default { $res.Message = "Unbekannte Auftragsart: $($Job.Kind)"; $res.Code = 3; return $res }
        }
        $res.Spec = $spec
        if ($null -eq $spec) { $res.Success = $true; $res.Code = 0; $res.Message = "Nichts zu melden - keine Karte gesendet$(if ($detail) { " ($detail)" })"; return $res }
        if ($NoSend) { $res.Success = $true; $res.Code = 0; $res.Message = 'Vorschau'; return $res }
        $cat = "$((Get-HUTeamsKinds | Where-Object { $_.Key -eq "$($Job.Kind)" }).Category)"; if (-not $cat) { $cat = 'Daily' }
        # Ziele: einmalige Auswahl > am Auftrag gespeicherte > alle aktiven
        $ids = @($TargetIds | Where-Object { "$_" })
        if (-not $ids.Count) { $ids = @($Job.Targets | Where-Object { "$_" }) }
        $sent = Send-HUNotify -Category $cat -Title $spec.Title -Level $spec.Level -Rows $spec.Rows -Facts $spec.Facts -Lines $spec.Lines -Source "$([Environment]::MachineName)" -TargetIds $ids -IgnoreCategory -Preview "$($spec.Preview)"
        $res.Sent = "$($sent.Text)"
        # Hinweis "Soll schlechter" nur einmal: nach erfolgreichem Senden vermerken
        if ("$($Job.Kind)" -eq 'SecDrift' -and $sent.Ok -gt 0 -and [int](Get-Variable sw -ValueOnly -ErrorAction SilentlyContinue) -gt 0) { try { Set-HUSecReferenceWorseShown } catch { } }
        if ($sent.Ok -gt 0 -and $sent.Failed -eq 0) { $res.Success = $true; $res.Code = 0; $res.Message = "$($sent.Text)" }
        elseif ($sent.Ok -eq 0 -and $sent.Failed -eq 0) { $res.Code = 3; $res.Message = $(if ($ids.Count) { 'Ziel nicht gefunden oder ausgeschaltet - NICHTS gesendet. Ziele am Auftrag pruefen.' } else { 'Kein aktives Ziel - NICHTS gesendet.' }) }
        elseif ($sent.Ok -gt 0) { $res.Code = 2; $res.Message = "Teilweise gesendet: $($sent.Text)" }
        else { $res.Message = "Nicht gesendet: $($sent.Text)" }
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
    # B15: nur 8 Hex-Zeichen - die Id landet in Aufgabenname und Kommandozeile
    if ("$($Job.Id)" -notmatch $script:TeamsJobIdPattern) { throw "Auftrags-Id ungueltig: '$($Job.Id)'" }
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
        if ("$($Job.Id)" -notmatch $script:TeamsJobIdPattern) { return "Auftrags-Id ungueltig: '$($Job.Id)'" }
        if ("$AppRoot" -match '["%]') { return 'Programmordner enthaelt unzulaessige Zeichen (" oder %) - Aufgabe nicht angelegt' }
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$main`" -Headless -Job `"$($Job.Id)`""
        $a = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $AppRoot
        $at = [datetime]::ParseExact("$($Job.Time)", 'H:mm', [cultureinfo]::InvariantCulture)
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
    'Invoke-HUTeamsJobsLocked',
    'Get-HUTeamsJobsPath',
    'New-HUTeamsJob',
    'Get-HUTeamsJobs',
    'Get-HUTeamsJob',
    'Set-HUTeamsJobs',
    'Update-HUTeamsJobResult',
    'Get-HUTeamsKinds',
    'Get-HUTeamsSnippetCode',
    'Invoke-HUTeamsScript',
    'Get-HUTeamsCodeHash',
    'Get-HUTeamsDateLabel',
    'Get-HUDailyTenantStatus',
    'New-HUDailyCardSpec',
    'Get-HUSecretStatus',
    'New-HUSecretsCardSpec',
    'Get-HULicenseStatus',
    'New-HULicenseCardSpec',
    'Get-HUDefenderStatus',
    'New-HUDefenderCardSpec',
    'New-HUSecDriftCardSpec',
    'Invoke-HUTeamsJob',
    'Get-HUTeamsJobTaskName',
    'Get-HUTeamsJobTask',
    'Register-HUTeamsJobTask',
    'Unregister-HUTeamsJobTask'
)
