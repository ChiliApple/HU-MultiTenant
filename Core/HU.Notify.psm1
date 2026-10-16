#Requires -Version 5.1

<#
.SYNOPSIS
    HU.Notify - Teams-Benachrichtigungen (Workflows-Webhook, Adaptive Cards) fuer HU-MultiTenant.
.DESCRIPTION
    Sendet Meldungen als Adaptive Card an einen oder mehrere Teams-Workflows-Webhooks
    ("When a Teams webhook request is received"). Die alten Office-365-Connectors
    (webhook.office.com) sind abgeschaltet und werden abgewiesen.

    Ziele (Name, Adresse, Kategorien) liegen DPAPI-verschluesselt (CurrentUser, Entropy)
    in %APPDATA%\HU-MultiTenant\notify-targets.json - gleiche Ablage wie die App-Secrets.
    Die Adresse enthaelt die Signatur des Workflows und wird nie geloggt; im Protokoll
    erscheint nur eine 8-stellige Kurzkennung (SHA-256 der Adresse).

    Grundsaetze:
    - Senden wirft nie eine Ausnahme (eine Meldung darf keinen Vorgang stoeren).
    - Freitext aus Tenants (Namen, Fehlermeldungen) wird vor dem Einbau bereinigt
      (ConvertTo-HUNotifySafeText): Steuer-/Bidi-Zeichen, Markdown, Links.
    - Keine Secrets, Tokens, Recovery-Keys in Karten.
    - Logik ohne Oberflaeche, PowerShell 5.1 und 7 (Windows).
.NOTES
    Modul: HU.Notify.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
    Zielmaschine: Admin-PC (Benutzerkontext), auch im Headless-Lauf.
#>

# ============================================================================
# MODUL-VARIABLEN
# ============================================================================

$script:NotifyBasePath  = [System.IO.Path]::Combine($env:APPDATA, 'HU-MultiTenant')
$script:NotifyFile      = [System.IO.Path]::Combine($script:NotifyBasePath, 'notify-targets.json')
$script:NotifyHistFile  = [System.IO.Path]::Combine($script:NotifyBasePath, 'notify-history.json')
$script:NotifyEntropy   = [System.Text.Encoding]::UTF8.GetBytes('HU-Notify-v1')
$script:NotifyMaxTargets = 10
$script:NotifyMaxHistory = 300
$script:NotifyMaxLines   = 40
$script:NotifyMaxFacts   = 30
$script:NotifyMaxRows    = 25
$script:NotifyAppName    = 'HU-MultiTenant'

# Kategorien: Schluessel -> @(Bezeichnung, Standard ein/aus). Reihenfolge = Anzeige in der Oberflaeche.
$script:NotifyCats = [ordered]@{
    'Test'        = @('Testnachricht', $true)
    'Daily'       = @('Tages-Ampel (alle Tenants)', $true)
    'Devices'     = @('Geraete: nicht konform / kein Sync', $true)
    'Secrets'     = @('App-Secrets laufen ab', $true)
    'Licenses'    = @('Lizenzen knapp', $true)
    'Defender'    = @('Defender-Abweichungen', $true)
    'Apps'        = @('Apps: Updates / Rollout', $false)
    'Remediation' = @('Wartung: Ergebnisse', $false)
    'Change'      = @('Konfiguration geaendert (Backup-Vergleich)', $true)
    'Security'    = @('Sicherheit: Rollen, Anmeldungen', $true)
    'Jobs'        = @('Zeitgesteuerte Laeufe: Fehler', $true)
}

# Hosts der Workflows-App / Power Automate (nur Hinweis, kein harter Filter)
$script:NotifyKnownHosts = '(?i)(\.logic\.azure\.com|\.powerplatform\.com|\.powerautomate\.com|\.azure-apim\.net)$'

# ============================================================================
# HILFSFUNKTIONEN (intern)
# ============================================================================

function Write-HUNotifyModuleLog {
    # Loggt ueber Write-HULog, wenn das Logging-Modul geladen ist - sonst Verbose.
    param([string]$Message, [string]$Level = 'INFO')
    $cmd = Get-Command -Name 'Write-HULog' -ErrorAction SilentlyContinue
    if ($cmd) { try { Write-HULog -Message "[Notify] $Message" -Level $Level } catch { Write-Verbose "[Notify] $Message" } }
    else { Write-Verbose "[Notify] $Message" }
}

function Protect-HUNotifyText {
    param([Parameter(Mandatory)][string]$Text)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $b = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Text), $script:NotifyEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($b)
}

function Unprotect-HUNotifyText {
    param([Parameter(Mandatory)][string]$Cipher)
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $b = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Cipher), $script:NotifyEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($b)
}

function Get-HUNotifyUrlTag {
    <#
    .SYNOPSIS
        8-stellige Kurzkennung einer Webhook-Adresse fuer Protokolle (SHA-256, nie die Adresse selbst).
    #>
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '--------' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $h = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Url".Trim()))
        return (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Hide-HUNotifyUrl {
    # Entfernt Adressen aus Fehlermeldungen (die Adresse enthaelt die Signatur).
    param([string]$Text)
    return ("$Text" -replace 'https?://\S+', '(Webhook)')
}

function Get-HUNotifyDefaultCats {
    $c = @{}
    foreach ($n in $script:NotifyCats.Keys) { $c[$n] = [bool]$script:NotifyCats[$n][1] }
    return $c
}

function ConvertTo-HUNotifyCats {
    # Kategorien aus Objekt/Hashtable uebernehmen: unbekannte ignorieren, fehlende = Standard.
    param($Cats)
    $c = Get-HUNotifyDefaultCats
    if ($null -eq $Cats) { return $c }
    foreach ($n in @($c.Keys)) {
        $v = $null
        if ($Cats -is [System.Collections.IDictionary]) { if ($Cats.Contains($n)) { $v = $Cats[$n] } }
        elseif ($Cats.PSObject.Properties[$n]) { $v = $Cats.$n }
        if ($null -ne $v) { $c[$n] = [bool]$v }
    }
    return $c
}

function New-HUNotifyTargetObject {
    param($Raw)
    return [pscustomobject]@{
        Id      = "$($Raw.Id)"
        Name    = "$($Raw.Name)"
        Url     = "$($Raw.Url)"
        Enabled = if ($null -eq $Raw.Enabled) { $true } else { [bool]$Raw.Enabled }
        Cats    = ConvertTo-HUNotifyCats $Raw.Cats
        Created = "$($Raw.Created)"
    }
}

function Invoke-HUNotifyLocked {
    # Kurze prozessuebergreifende Sperre (GUI vs. Aufgabenplanung) um Lesen+Schreiben der Dateien
    param([Parameter(Mandatory)][scriptblock]$Do)
    $m = New-Object System.Threading.Mutex($false, 'Local\HU-MultiTenant_Notify')
    $got = $false
    try { $got = $m.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { Write-HUNotifyModuleLog 'Sperre nicht erhalten (5 s) - schreibe trotzdem' 'WARN' }
    try { & $Do } finally { if ($got) { try { $m.ReleaseMutex() } catch { } }; $m.Dispose() }
}

# ============================================================================
# PRUEFUNGEN
# ============================================================================

function Get-HUNotifyCategories {
    <#
    .SYNOPSIS
        Liefert die Kategorien (Key, Label, Default) in Anzeige-Reihenfolge.
    #>
    [CmdletBinding()]
    param()
    foreach ($k in $script:NotifyCats.Keys) {
        [pscustomobject]@{ Key = $k; Label = $script:NotifyCats[$k][0]; Default = [bool]$script:NotifyCats[$k][1] }
    }
}

function Test-HUWebhookUrl {
    <#
    .SYNOPSIS
        Prueft eine Webhook-Adresse. Rueckgabe: '' = in Ordnung, sonst Grund (Text).
    .DESCRIPTION
        Nur https. Alte Office-365-Connectors (webhook.office.com) werden abgewiesen,
        da seit Mai 2026 abgeschaltet. Private/lokale Hosts werden abgewiesen (SSRF-Schutz).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Url)
    $u = "$Url".Trim()
    if (-not $u) { return 'leer' }
    if ($u.Length -gt 2048) { return 'Adresse zu lang' }
    $x = $null
    if (-not [uri]::TryCreate($u, [UriKind]::Absolute, [ref]$x) -or $x.Scheme -ne 'https') { return 'keine https-Adresse' }
    if ($x.Host -match '(?i)(^|\.)webhook\.office\.com$') { return 'alte Office-365-Connector-Adresse - die Connectors sind abgeschaltet, bitte in Teams einen Workflow anlegen' }
    if ($x.Host -match '(?i)^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|198\.1[89]\.|0\.|\[::1\]|\[::ffff:|\[f[cd]|\[fe80)' -or $x.Host -notmatch '\.') { return 'lokale oder private Adresse nicht erlaubt' }
    if ($x.UserInfo) { return 'Benutzerangaben in der Adresse nicht erlaubt' }
    return ''
}

function Test-HUWebhookHostKnown {
    <#
    .SYNOPSIS
        Hinweis (kein Fehler): Adresse stammt erkennbar aus der Workflows-App / Power Automate.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Url)
    $x = $null
    if (-not [uri]::TryCreate("$Url".Trim(), [UriKind]::Absolute, [ref]$x)) { return $false }
    return [bool]($x.Host -match $script:NotifyKnownHosts)
}

function ConvertTo-HUNotifySafeText {
    <#
    .SYNOPSIS
        Bereinigt fremden Text fuer eine Karte: Steuer-/Bidi-Zeichen, Markdown, Links, Laenge.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text, [int]$Max = 400)
    $t = ("$Text" -replace '[\x00-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2066-\u2069]', ' ' `
                  -replace '[\[\]\*`<>~]', '' `
                  -replace '[_|#]', ' ' `
                  -replace '(?i)\b(https?|ftp|file)://', '$1 :// ' `
                  -replace '(?i)\bwww\.', 'www .' `
                  -replace '\s{2,}', ' ').Trim()
    if ($Max -gt 0 -and $t.Length -gt $Max) {
        $n = $Max
        if ([char]::IsHighSurrogate($t[$n - 1])) { $n-- }
        $t = $t.Substring(0, $n) + ' ...'
    }
    return $t
}

# ============================================================================
# ZIELE (SPEICHER)
# ============================================================================

function Get-HUNotifyConfig {
    <#
    .SYNOPSIS
        Liest die Ziele. Rueckgabe: @{ Configured; Targets; Error }.
    .DESCRIPTION
        Targets sind entschluesselt (Url im Klartext) - Objekt nur im Speicher halten, nie loggen.
    #>
    [CmdletBinding()]
    param()
    $r = [pscustomobject]@{ Configured = $false; Targets = @(); Error = '' }
    if (-not (Test-Path -LiteralPath $script:NotifyFile -PathType Leaf)) { return $r }
    try {
        $raw = Get-Content -LiteralPath $script:NotifyFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $raw.targets) { return $r }
        $json = Unprotect-HUNotifyText -Cipher "$($raw.targets)"
        $obj = $json | ConvertFrom-Json
        $list = if ($obj -and $obj.PSObject.Properties['items']) { @($obj.items) } else { @($obj) }   # aeltere Dateien: nacktes Array/Objekt
        $out = @()
        foreach ($t in $list) { if ($t -and "$($t.Url)".Trim()) { $out += New-HUNotifyTargetObject $t } }
        $r.Targets = @($out | Select-Object -First $script:NotifyMaxTargets)
        $r.Configured = ($r.Targets.Count -gt 0)
    }
    catch {
        $r.Error = Hide-HUNotifyUrl "$($_.Exception.Message)"
        Write-HUNotifyModuleLog "Ziele nicht lesbar: $($r.Error)" 'WARN'
    }
    return $r
}

function Set-HUNotifyTargets {
    <#
    .SYNOPSIS
        Speichert die gesamte Zielliste (verschluesselt). Rueckgabe: '' = gespeichert, sonst Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets)
    try {
        $clean = @()
        foreach ($t in @($Targets | Where-Object { $_ })) {
            $why = Test-HUWebhookUrl "$($t.Url)"
            if ($why) { return "Ziel '$($t.Name)': $why" }
            $o = New-HUNotifyTargetObject $t
            if (-not $o.Id) { $o.Id = ([guid]::NewGuid().ToString('N')).Substring(0, 8) }
            if (-not $o.Name) { $o.Name = 'Teams' }
            $o.Name = ConvertTo-HUNotifySafeText -Text $o.Name -Max 40
            if (-not $o.Created) { $o.Created = (Get-Date).ToString('s') }
            $clean += $o
        }
        if ($clean.Count -gt $script:NotifyMaxTargets) { return "Hoechstens $($script:NotifyMaxTargets) Ziele" }
        Invoke-HUNotifyLocked {
            if (-not (Test-Path -LiteralPath $script:NotifyBasePath)) { New-Item -Path $script:NotifyBasePath -ItemType Directory -Force | Out-Null }
            # PS 5.1: -InputObject mit Array erzeugt value/Count-Huelle - daher Array als Eigenschaft verpacken
            $plain = ([ordered]@{ v = 1; items = @($clean) } | ConvertTo-Json -Depth 6 -Compress)
            $doc = [ordered]@{ v = 1; scope = 'CurrentUser'; updated = (Get-Date).ToString('s'); targets = (Protect-HUNotifyText -Text $plain) }
            $tmp = "$($script:NotifyFile).tmp.$PID"
            [System.IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmp -Destination $script:NotifyFile -Force
        }
        Write-HUNotifyModuleLog "Ziele gespeichert: $($clean.Count)" 'OK'
        return ''
    }
    catch {
        $m = Hide-HUNotifyUrl "$($_.Exception.Message)"
        Write-HUNotifyModuleLog "Ziele nicht gespeichert: $m" 'ERROR'
        return "Speichern fehlgeschlagen: $m"
    }
}

function Add-HUNotifyTarget {
    <#
    .SYNOPSIS
        Fuegt ein Ziel hinzu (oder ersetzt es bei gleicher Id). Rueckgabe: '' oder Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Cats,
        [string]$Id = ''
    )
    $out = ''
    Invoke-HUNotifyLocked {
        $c = Get-HUNotifyConfig
        if ($c.Error) { $script:__huAddOut = "Ziele nicht lesbar: $($c.Error)"; return }
        $list = @($c.Targets | Where-Object { $_.Id -ne $Id })
        $list += [pscustomobject]@{ Id = $Id; Name = $Name; Url = $Url; Enabled = $true; Cats = $Cats; Created = '' }
        $script:__huAddOut = (Set-HUNotifyTargets -Targets $list)
    }
    $out = "$($script:__huAddOut)"; $script:__huAddOut = $null
    return $out
}

function Remove-HUNotifyTarget {
    <#
    .SYNOPSIS
        Entfernt ein Ziel anhand der Id. Rueckgabe: '' oder Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id)
    $out = ''
    Invoke-HUNotifyLocked {
        $c = Get-HUNotifyConfig
        if ($c.Error) { $script:__huAddOut = "Ziele nicht lesbar: $($c.Error)"; return }
        $script:__huAddOut = (Set-HUNotifyTargets -Targets @($c.Targets | Where-Object { $_.Id -ne $Id }))
    }
    $out = "$($script:__huAddOut)"; $script:__huAddOut = $null
    return $out
}

function Test-HUNotifyCat {
    <#
    .SYNOPSIS
        Ist die Kategorie fuer dieses Ziel eingeschaltet? (Ziel $null = Standardwert)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Target, [Parameter(Mandatory)][string]$Category)
    if (-not $script:NotifyCats.Contains($Category)) { return $false }
    if ($null -eq $Target -or $null -eq $Target.Cats) { return [bool]$script:NotifyCats[$Category][1] }
    $cats = $Target.Cats
    if ($cats -is [System.Collections.IDictionary]) { if ($cats.Contains($Category)) { return [bool]$cats[$Category] } }
    elseif ($cats.PSObject.Properties[$Category]) { return [bool]$cats.$Category }
    return [bool]$script:NotifyCats[$Category][1]
}

# ============================================================================
# KARTEN
# ============================================================================

function New-HUTeamsCard {
    <#
    .SYNOPSIS
        Baut eine Adaptive Card (Workflows-Format) als Objekt. ConvertTo-Json erzeugt den Body.
    .PARAMETER Title
        Ueberschrift (farbig nach Level).
    .PARAMETER Lines
        Textzeilen unter der Ueberschrift.
    .PARAMETER Level
        OK | Warning | Error | Info - bestimmt Farbe der Ueberschrift.
    .PARAMETER Facts
        Geordnete Hashtable Name -> Wert (FactSet), z.B. [ordered]@{ 'Geraete' = 412; 'Nicht konform' = 7 }.
    .PARAMETER Rows
        Tabellenzeilen fuer die Tenant-Ampel: Objekte mit Name, Status (OK|Warning|Error|Info), Text.
    .PARAMETER Actions
        Hashtables mit Title und Url (nur https) -> Action.OpenUrl.
    .PARAMETER Source
        Quelle in der Fusszeile (Standard: Computername).
    .PARAMETER Category
        Kategorie in der Fusszeile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines = @(),
        [ValidateSet('OK', 'Warning', 'Error', 'Info')][string]$Level = 'Info',
        [System.Collections.IDictionary]$Facts,
        [object[]]$Rows = @(),
        [hashtable[]]$Actions = @(),
        [string]$Source = '',
        [string]$Category = ''
    )
    $color = switch ($Level) { 'Error' { 'Attention' } 'Warning' { 'Warning' } 'OK' { 'Good' } default { 'Accent' } }
    $body = New-Object System.Collections.Generic.List[object]
    $body.Add([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text $Title -Max 200); weight = 'Bolder'; size = 'Medium'; wrap = $true; color = $color })

    $n = 0
    $allLines = @($Lines | Where-Object { "$_".Trim() })
    foreach ($l in $allLines) {
        if (++$n -gt $script:NotifyMaxLines) { $body.Add([ordered]@{ type = 'TextBlock'; text = "... und $($allLines.Count - $script:NotifyMaxLines) weitere Zeilen"; isSubtle = $true; wrap = $true }); break }
        $body.Add([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text $l); wrap = $true; spacing = 'Small' })
    }

    if ($Facts -and $Facts.Count) {
        $fs = New-Object System.Collections.Generic.List[object]
        $n = 0
        foreach ($k in $Facts.Keys) {
            if (++$n -gt $script:NotifyMaxFacts) { break }
            $fs.Add([ordered]@{ title = (ConvertTo-HUNotifySafeText -Text "$k" -Max 60); value = (ConvertTo-HUNotifySafeText -Text "$($Facts[$k])" -Max 200) })
        }
        $body.Add([ordered]@{ type = 'FactSet'; facts = $fs.ToArray(); spacing = 'Medium' })
    }

    if ($Rows -and @($Rows).Count) {
        $n = 0
        $allRows = @($Rows | Where-Object { $_ })
        foreach ($r in $allRows) {
            if (++$n -gt $script:NotifyMaxRows) { $body.Add([ordered]@{ type = 'TextBlock'; text = "... und $($allRows.Count - $script:NotifyMaxRows) weitere Zeilen"; isSubtle = $true; wrap = $true; spacing = 'Small' }); break }
            $st = "$($r.Status)"
            $dot = switch ($st) { 'OK' { "$([char]0xD83D)$([char]0xDFE2)" } 'Warning' { "$([char]0xD83D)$([char]0xDFE1)" } 'Error' { "$([char]0xD83D)$([char]0xDD34)" } default { [string][char]0x26AA } }
            $rc = switch ($st) { 'OK' { 'Good' } 'Warning' { 'Warning' } 'Error' { 'Attention' } default { 'Default' } }
            $cols = @(
                [ordered]@{ type = 'Column'; width = 'auto'; items = @([ordered]@{ type = 'TextBlock'; text = $dot; wrap = $false }) }
                [ordered]@{ type = 'Column'; width = '90px'; items = @([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text "$($r.Name)" -Max 40); weight = 'Bolder'; color = $rc; wrap = $true }) }
                [ordered]@{ type = 'Column'; width = 'stretch'; items = @([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text "$($r.Text)" -Max 300); wrap = $true }) }
            )
            $body.Add([ordered]@{ type = 'ColumnSet'; columns = $cols; spacing = 'Small' })
        }
    }

    $src = if ($Source) { $Source } else { [Environment]::MachineName }
    $foot = @((ConvertTo-HUNotifySafeText -Text $src -Max 40), (Get-Date).ToString('dd.MM.yyyy HH:mm'), $script:NotifyAppName)
    if ($Category) { $foot += (ConvertTo-HUNotifySafeText -Text $Category -Max 30) }
    $body.Add([ordered]@{ type = 'TextBlock'; text = ($foot -join '  |  '); isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium' })

    # fallbackText/speak/summary: Textauszug fuer Push-Vorschau und Clients ohne Kartendarstellung.
    # Inhalt: Titel plus erste Zeilen bzw. erste Ampel-Zeilen (Name: Text).
    $fbParts = @($Rows | Where-Object { $_ } | Select-Object -First 3 | ForEach-Object { "$($_.Name): $($_.Text)" })
    if (-not $fbParts.Count) { $fbParts = @($Lines | Where-Object { "$_".Trim() } | Select-Object -First 3) }
    $sep = ' ' + [char]0x2022 + ' '   # Aufzaehlungspunkt (ueberlebt die Textbereinigung, anders als |)
    $fb = ConvertTo-HUNotifySafeText -Text ("$Title" + $(if (@($fbParts).Count) { $sep + (@($fbParts) -join $sep) })) -Max 240
    $card = [ordered]@{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; fallbackText = $fb; speak = $fb; body = $body.ToArray() }
    $acts = @()
    foreach ($a in @($Actions | Where-Object { $_ })) {
        $au = "$($a.Url)".Trim(); $x = $null
        if ([uri]::TryCreate($au, [UriKind]::Absolute, [ref]$x) -and $x.Scheme -eq 'https') {
            $acts += [ordered]@{ type = 'Action.OpenUrl'; title = (ConvertTo-HUNotifySafeText -Text "$($a.Title)" -Max 40); url = $au }
        }
    }
    if ($acts.Count) { $card['actions'] = $acts }
    return [ordered]@{ type = 'message'; summary = $fb; text = $fb; attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = $card }) }
}

function ConvertTo-HUTeamsCardJson {
    <#
    .SYNOPSIS
        Karte -> JSON (kompakt). Prueft die Groesse (Teams: max. ca. 28 KB).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Card)
    $json = ConvertTo-Json -InputObject $Card -Depth 20 -Compress
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 27000) { throw 'Karte zu gross (max. 28 KB) - weniger Zeilen senden' }
    return $json
}

# ============================================================================
# SENDEN
# ============================================================================

function Send-HUTeamsCard {
    <#
    .SYNOPSIS
        Sendet eine Karte an eine Webhook-Adresse. Rueckgabe: '' = gesendet, sonst Grund. Wirft nie.
    .PARAMETER Card
        Objekt aus New-HUTeamsCard (oder fertiger JSON-String).
    .PARAMETER Url
        Webhook-Adresse (Workflows).
    .PARAMETER Retries
        Wiederholungen bei 429/5xx/Timeout (Standard 2, Wartezeit 3 s / 6 s).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Card,
        [Parameter(Mandatory)][string]$Url,
        [int]$Retries = 2
    )
    $why = Test-HUWebhookUrl $Url
    if ($why) { return "Webhook-Adresse ungueltig: $why" }
    try { $json = if ($Card -is [string]) { $Card } else { ConvertTo-HUTeamsCardJson -Card $Card } }
    catch { return "Karte ungueltig: $($_.Exception.Message)" }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $last = ''
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            $null = Invoke-WebRequest -Uri $Url.Trim() -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop
            return ''
        }
        catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            $last = Hide-HUNotifyUrl "$($_.Exception.Message)"
            $retry = ($code -eq 429 -or $code -ge 500 -or $code -eq 0)
            if ($code -eq 400) { return "Senden abgelehnt (400): Workflow erwartet eine Adaptive Card - Trigger 'When a Teams webhook request is received' pruefen" }
            if ($code -eq 401 -or $code -eq 403) { return "Senden abgelehnt ($code): Adresse/Signatur ungueltig - Workflow neu anlegen" }
            if ($code -eq 404) { return 'Senden abgelehnt (404): Workflow nicht gefunden - geloescht oder deaktiviert' }
            if (-not $retry -or $i -eq $Retries) { break }
            $wait = 3 * ($i + 1)
            try { $ra = [int]"$($_.Exception.Response.Headers['Retry-After'])"; if ($ra -gt 0) { $wait = [math]::Min(30, $ra) } } catch { }
            Start-Sleep -Seconds $wait
        }
    }
    return "Senden fehlgeschlagen: $last"
}

function Expand-HUNotifyHistoryNode {
    # Protokoll-Eintraege einsammeln - auch aus aelteren, verschachtelten Dateien (value/Count-Huellen)
    param($Node, [int]$Depth = 0)
    $out = @()
    if ($null -eq $Node -or $Depth -gt 20) { return $out }
    foreach ($n in @($Node)) {
        if ($null -eq $n) { continue }
        if ($n.PSObject.Properties['Time'] -and $n.PSObject.Properties['Target']) { $out += $n; continue }
        if ($n.PSObject.Properties['items']) { $out += Expand-HUNotifyHistoryNode -Node $n.items -Depth ($Depth + 1); continue }
        if ($n.PSObject.Properties['value']) { $out += Expand-HUNotifyHistoryNode -Node $n.value -Depth ($Depth + 1); continue }
    }
    return $out
}

function Add-HUNotifyHistory {
    # Protokoll (ohne Adressen): Zeit, Ziel, Kategorie, Titel, Ergebnis
    param([string]$TargetName, [string]$Tag, [string]$Category, [string]$Title, [string]$Result)
    try {
        Invoke-HUNotifyLocked {
            $list = @()
            if (Test-Path -LiteralPath $script:NotifyHistFile -PathType Leaf) {
                try { $list = @(Expand-HUNotifyHistoryNode -Node (Get-Content -LiteralPath $script:NotifyHistFile -Raw -Encoding UTF8 | ConvertFrom-Json)) }
                catch { try { Copy-Item -LiteralPath $script:NotifyHistFile -Destination "$($script:NotifyHistFile).bak" -Force } catch { }; $list = @() }
            }
            $list += [pscustomobject]@{ Time = (Get-Date).ToString('s'); Target = $TargetName; Tag = $Tag; Category = $Category; Title = (ConvertTo-HUNotifySafeText -Text $Title -Max 120); Result = (Hide-HUNotifyUrl $Result) }
            $list = @($list | Select-Object -Last $script:NotifyMaxHistory)
            if (-not (Test-Path -LiteralPath $script:NotifyBasePath)) { New-Item -Path $script:NotifyBasePath -ItemType Directory -Force | Out-Null }
            # PS 5.1: Array als Eigenschaft verpacken (sonst value/Count-Huelle)
            $json = ([ordered]@{ v = 1; items = @($list) } | ConvertTo-Json -Depth 5 -Compress)
            $tmp = "$($script:NotifyHistFile).tmp.$PID"
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tmp -Destination $script:NotifyHistFile -Force
        }
    }
    catch { Write-Verbose "[Notify] Protokoll nicht geschrieben: $($_.Exception.Message)" }
}

function Get-HUNotifyHistory {
    <#
    .SYNOPSIS
        Sendeprotokoll (neueste zuerst), ohne Adressen.
    #>
    [CmdletBinding()]
    param([int]$Last = 100)
    if (-not (Test-Path -LiteralPath $script:NotifyHistFile -PathType Leaf)) { return @() }
    try {
        $l = @(Expand-HUNotifyHistoryNode -Node (Get-Content -LiteralPath $script:NotifyHistFile -Raw -Encoding UTF8 | ConvertFrom-Json))
        $sel = @($l | Select-Object -Last $Last)   # Dateireihenfolge = chronologisch
        [array]::Reverse($sel)
        return $sel
    }
    catch { return @() }
}

function Send-HUNotify {
    <#
    .SYNOPSIS
        Meldung an alle eingeschalteten Ziele mit dieser Kategorie.
    .DESCRIPTION
        Wirft nie. Rueckgabe-Objekt: Ok (gesendet), Failed (fehlgeschlagen), Text (Protokolltext, '' = kein Ziel angesprochen).
        -TargetIds: nur diese Ziele; mit -IgnoreCategory auch, wenn die Kategorie dort aus ist.
    .EXAMPLE
        Send-HUNotify -Category Devices -Title 'HLW: 7 Geraete nicht konform' -Level Warning -Lines @('NB-123 (Maier T.)')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines = @(),
        [ValidateSet('OK', 'Warning', 'Error', 'Info')][string]$Level = 'Info',
        [System.Collections.IDictionary]$Facts,
        [object[]]$Rows = @(),
        [hashtable[]]$Actions = @(),
        [string]$Source = '',
        [string[]]$TargetIds = @(),
        [switch]$IgnoreCategory
    )
    $res = [pscustomobject]@{ Ok = 0; Failed = 0; Text = '' }
    if (-not $script:NotifyCats.Contains($Category)) { $res.Text = "Unbekannte Kategorie: $Category"; $res.Failed = 1; return $res }
    $c = Get-HUNotifyConfig
    if ($c.Error) { $res.Text = "Teams-Benachrichtigung: Ziele nicht lesbar: $($c.Error)"; $res.Failed = 1; return $res }
    if (-not $c.Configured) { return $res }
    try { $card = New-HUTeamsCard -Title $Title -Lines $Lines -Level $Level -Facts $Facts -Rows $Rows -Actions $Actions -Source $Source -Category $script:NotifyCats[$Category][0] }
    catch { $res.Failed = 1; $res.Text = "Karte nicht gebaut: $(Hide-HUNotifyUrl "$($_.Exception.Message)")"; return $res }
    $out = @()
    foreach ($t in @($c.Targets | Where-Object { $_ -and $_.Enabled })) {
        if ($TargetIds.Count -and ($TargetIds -notcontains $t.Id)) { continue }
        if (-not $IgnoreCategory -and -not (Test-HUNotifyCat -Target $t -Category $Category)) { continue }
        $r = Send-HUTeamsCard -Card $card -Url $t.Url
        if ($r) { $res.Failed++ } else { $res.Ok++ }
        $tag = Get-HUNotifyUrlTag $t.Url
        Add-HUNotifyHistory -TargetName $t.Name -Tag $tag -Category $Category -Title $Title -Result $(if ($r) { $r } else { 'gesendet' })
        Write-HUNotifyModuleLog "$($t.Name) [$tag] $Category - $(if ($r) { $r } else { 'gesendet' })" $(if ($r) { 'WARN' } else { 'OK' })
        $out += "$($t.Name): $(if ($r) { $r } else { 'gesendet' })"
    }
    if ($out.Count) { $res.Text = "Teams-Benachrichtigung: $($out -join '; ')" }
    return $res
}

function Send-HUNotifyTest {
    <#
    .SYNOPSIS
        Testnachricht an eine Adresse (noch ungespeichert) oder an ein gespeichertes Ziel. Rueckgabe: '' oder Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Url = '', [string]$TargetId = '', [string]$Name = 'Teams')
    if (-not $Url -and $TargetId) {
        $c = Get-HUNotifyConfig
        $t = $c.Targets | Where-Object { $_.Id -eq $TargetId } | Select-Object -First 1
        if (-not $t) { return 'Ziel nicht gefunden' }
        $Url = $t.Url; $Name = $t.Name
    }
    $card = New-HUTeamsCard -Title "$($script:NotifyAppName) - Testnachricht ($Name)" -Level OK -Lines @('Der Teams-Webhook funktioniert.') -Facts ([ordered]@{ 'Computer' = $env:COMPUTERNAME; 'Benutzer' = $env:USERNAME }) -Category 'Testnachricht'
    $r = Send-HUTeamsCard -Card $card -Url $Url -Retries 0
    Add-HUNotifyHistory -TargetName $Name -Tag (Get-HUNotifyUrlTag $Url) -Category 'Test' -Title 'Testnachricht' -Result $(if ($r) { $r } else { 'gesendet' })
    return $r
}

# ============================================================================
# EXPORT
# ============================================================================

Export-ModuleMember -Function @(
    'Get-HUNotifyCategories',
    'Test-HUWebhookUrl',
    'Test-HUWebhookHostKnown',
    'ConvertTo-HUNotifySafeText',
    'Get-HUNotifyUrlTag',
    'Get-HUNotifyConfig',
    'Set-HUNotifyTargets',
    'Add-HUNotifyTarget',
    'Remove-HUNotifyTarget',
    'Test-HUNotifyCat',
    'New-HUTeamsCard',
    'ConvertTo-HUTeamsCardJson',
    'Send-HUTeamsCard',
    'Send-HUNotify',
    'Send-HUNotifyTest',
    'Add-HUNotifyHistory',
    'Get-HUNotifyHistory'
)
