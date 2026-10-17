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
    Version: 1.1.0
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
$script:NotifyMaxLines   = 20
$script:NotifyMaxFacts   = 15
$script:NotifyMaxRows    = 25
$script:NotifyMaxBytes   = 21000   # Teams nennt ca. 28 KB, zaehlt serverseitig aber rund 18 % mehr (Review 030 B6)
$script:NotifyMaxActions = 5
$script:NotifyAppName    = 'HU-MultiTenant'

# Eigene Kategorien (Klartext, keine Geheimnisse) - fuer eigene Skripte/Snippets/Erweiterungen
$script:NotifyCatFile        = [System.IO.Path]::Combine($script:NotifyBasePath, 'notify-categories.json')
$script:NotifyMaxCustomCats  = 30
$script:NotifyCatKeyPattern  = '^[A-Za-z][A-Za-z0-9]{1,23}$'
# Namen, die bei Hashtables/Dictionaries Eigenschaften verdecken wuerden (Review 030 B3) - nie als Schluessel
$script:NotifyCatReserved    = @('Keys', 'Values', 'Count', 'Item', 'Items', 'Contains', 'ContainsKey', 'ContainsValue', 'PSBase', 'PSObject', 'PSTypeNames', 'Comparer', 'IsReadOnly', 'IsFixedSize', 'IsSynchronized', 'SyncRoot', 'Keys', 'GetEnumerator')
$script:NotifyCatFileMax     = 65536
$script:NotifyCustomCache    = $null

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
# Sendefreigabe (Review 030 B4a): ohne Freigabe sendet Send-HUTeamsCard nichts. Die App selbst (Main.ps1, Auftrags-Runspace)
# gibt frei; Snippet- und Erweiterungs-Runspaces nur nach "Ja" in der Teams-Rueckfrage. Ein neu geladenes Modul ist gesperrt -
# auch wenn ein Snippet HU.Notify selbst importiert oder ueber Alias/Hilfsdatei sendet.
$script:NotifySendApproval = $null
# Meldung (v2.1.10): laeuft ein Skript als "Meldung aus Skript", gehen alle Send-HUNotify-Aufrufe an die Ziele dieser Meldung
# (Kategorie egal). Gesetzt nur vom Lauf (Auftrag, Quick Script) - das Skript selbst muss nichts tun.
$script:NotifyRoute = $null
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

function Test-HUNotifyCatKey {
    # gueltiger Schluessel fuer eigene Kategorien: Muster, nicht reserviert, nicht eingebaut
    param([string]$Key)
    return ("$Key" -match $script:NotifyCatKeyPattern -and $script:NotifyCatReserved -notcontains "$Key" -and -not $script:NotifyCats.Contains("$Key"))
}

function Get-HUNotifyCustomCats {
    # Eigene Kategorien aus notify-categories.json (zwischengespeichert bis zur naechsten Aenderung der Datei)
    param([switch]$NoCache)
    $out = @()
    if (-not (Test-Path -LiteralPath $script:NotifyCatFile -PathType Leaf)) { $script:NotifyCustomCache = $null; return $out }
    try {
        $fi = Get-Item -LiteralPath $script:NotifyCatFile
        $stamp = "$($fi.LastWriteTimeUtc.Ticks)/$($fi.Length)"
        if (-not $NoCache -and $script:NotifyCustomCache -and $script:NotifyCustomCache.Stamp -eq $stamp) { return @($script:NotifyCustomCache.Items) }
        if ($fi.Length -gt $script:NotifyCatFileMax) { throw "Datei zu gross ($($fi.Length) Byte)" }
        $raw = Get-Content -LiteralPath $script:NotifyCatFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $seen = @{}
        foreach ($i in @($raw.items | Where-Object { $_ } | Select-Object -First $script:NotifyMaxCustomCats)) {
            $k = "$($i.Key)"
            if (-not (Test-HUNotifyCatKey $k) -or $seen.ContainsKey($k)) { continue }   # defekte Eintraege einzeln verwerfen
            $seen[$k] = $true
            $lbl = ConvertTo-HUNotifySafeText -Text "$($i.Label)" -Max 40
            if (-not $lbl) { $lbl = $k }
            $out += [pscustomobject]@{ Key = $k; Label = $lbl; Default = [bool]$i.Default }
        }
        $script:NotifyCustomCache = @{ Stamp = $stamp; Items = $out }
    }
    catch { Write-HUNotifyModuleLog "Eigene Kategorien nicht lesbar: $($_.Exception.Message)" 'WARN' }
    return $out
}

function Get-HUNotifyCatMap {
    # Alle Kategorien: Schluessel -> @(Bezeichnung, Standard, Eigene). Eingebaute zuerst.
    $m = [ordered]@{}
    foreach ($k in $script:NotifyCats.PSBase.Keys) { $m[$k] = @($script:NotifyCats[$k][0], [bool]$script:NotifyCats[$k][1], $false) }
    foreach ($c in @(Get-HUNotifyCustomCats)) { if (-not $m.Contains($c.Key)) { $m[$c.Key] = @($c.Label, [bool]$c.Default, $true) } }
    return $m
}

function Get-HUNotifyDefaultCats {
    $c = @{}
    $map = Get-HUNotifyCatMap
    foreach ($n in @($map.PSBase.Keys)) { $c[$n] = [bool]$map[$n][1] }
    return $c
}

function ConvertTo-HUNotifyCats {
    # Kategorien aus Objekt/Hashtable uebernehmen: unbekannte ignorieren, fehlende = Standard.
    param($Cats)
    $c = Get-HUNotifyDefaultCats
    if ($null -eq $Cats) { return $c }
    foreach ($n in @($c.PSBase.Keys)) {
        $v = $null
        if ($Cats -is [System.Collections.IDictionary]) { if ($Cats.Contains($n)) { $v = $Cats[$n] } }
        elseif ($Cats.PSObject.Properties[$n]) { $v = $Cats.$n }
        if ($null -ne $v) { $c[$n] = [bool]$v }
    }
    # Haken fuer gerade nicht bekannte, aber gueltige Schluessel behalten (eigene Kategorie, Datei kurz nicht lesbar) - hoechstens 30
    $names = if ($Cats -is [System.Collections.IDictionary]) { @($Cats.PSBase.Keys) } else { @($Cats.PSObject.Properties | ForEach-Object { $_.Name }) }
    $extra = 0
    foreach ($n in $names) {
        if ($c.ContainsKey("$n") -or -not (Test-HUNotifyCatKey "$n")) { continue }
        if (++$extra -gt $script:NotifyMaxCustomCats) { break }
        $v = if ($Cats -is [System.Collections.IDictionary]) { $Cats[$n] } else { $Cats.$n }
        if ($null -ne $v) { $c["$n"] = [bool]$v }
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
    if (-not $got) {
        # Review 029 Q2: nach Zeitueberschreitung NICHT ungesperrt lesen+schreiben (lost update) - Aufrufer faengt ab
        $m.Dispose()
        Write-HUNotifyModuleLog 'Sperre nicht erhalten (5 s) - Vorgang abgebrochen' 'WARN'
        throw 'Datei gerade gesperrt (anderer HU-MultiTenant-Vorgang) - bitte erneut versuchen'
    }
    try { & $Do } finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
}

# ============================================================================
# PRUEFUNGEN
# ============================================================================

function Get-HUNotifyCategories {
    <#
    .SYNOPSIS
        Liefert die Kategorien (Key, Label, Default, Custom) in Anzeige-Reihenfolge: eingebaute, dann eigene.
    #>
    [CmdletBinding()]
    param()
    $map = Get-HUNotifyCatMap
    foreach ($k in @($map.PSBase.Keys)) {
        [pscustomobject]@{ Key = $k; Label = $map[$k][0]; Default = [bool]$map[$k][1]; Custom = [bool]$map[$k][2] }
    }
}

function Set-HUNotifyCustomCats {
    # Schreibt die eigenen Kategorien (unter der Notify-Sperre aufrufen)
    param([AllowEmptyCollection()][object[]]$Items)
    if (-not (Test-Path -LiteralPath $script:NotifyBasePath)) { New-Item -Path $script:NotifyBasePath -ItemType Directory -Force | Out-Null }
    # eine Datei aus einer neueren Version nicht mit dem alten Format ueberschreiben (Review 030 B8)
    if (Test-Path -LiteralPath $script:NotifyCatFile -PathType Leaf) {
        $ver = 1; try { $ver = [int](Get-Content -LiteralPath $script:NotifyCatFile -Raw -Encoding UTF8 | ConvertFrom-Json).v } catch { }
        if ($ver -gt 1) { throw "notify-categories.json stammt aus einer neueren Version (v$ver) - bitte HU-MultiTenant aktualisieren" }
    }
    $list = @($Items | Where-Object { $_ } | ForEach-Object { [ordered]@{ Key = "$($_.Key)"; Label = "$($_.Label)"; Default = [bool]$_.Default } })
    # PS 5.1: Array als Eigenschaft verpacken (sonst value/Count-Huelle)
    $json = ([ordered]@{ v = 1; items = @($list) } | ConvertTo-Json -Depth 4)
    $tmp = "$($script:NotifyCatFile).tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:NotifyCatFile -Force
    $script:NotifyCustomCache = $null
}

function Add-HUNotifyCategory {
    <#
    .SYNOPSIS
        Legt eine eigene Kategorie an (oder aendert Bezeichnung/Standard bei gleichem Schluessel). Rueckgabe: '' oder Grund.
    .PARAMETER Key
        Schluessel fuer Skripte (Send-HUNotify -Category <Key>): Buchstabe, dann Buchstaben/Ziffern, 2-24 Zeichen.
    .PARAMETER Label
        Anzeigename in der Oberflaeche und in der Fusszeile der Karte.
    .PARAMETER Default
        Fuer Ziele, die diese Kategorie noch nicht kennen, ein- oder ausgeschaltet.
    .EXAMPLE
        Add-HUNotifyCategory -Key 'Backup' -Label 'Backup: Ergebnisse' -Default $true
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Label, [bool]$Default = $true)
    $k = "$Key".Trim()
    if ($k -notmatch $script:NotifyCatKeyPattern) { return 'Schluessel: 2-24 Zeichen, nur A-Z, a-z und Ziffern, am Anfang ein Buchstabe - keine Umlaute, Leer- oder Sonderzeichen (z. B. Backup, Drucker2)' }
    if ($script:NotifyCats.Contains($k)) { return "'$k' ist eine eingebaute Kategorie - bitte einen anderen Schluessel waehlen" }
    if ($script:NotifyCatReserved -contains $k) { return "'$k' ist ein reservierter Name - bitte einen anderen Schluessel waehlen (z. B. $($k)Alarm)" }
    $l = ConvertTo-HUNotifySafeText -Text $Label -Max 40
    if (-not $l) { return 'Bitte eine Bezeichnung eingeben' }
    try {
        Invoke-HUNotifyLocked {
            $cur = @(Get-HUNotifyCustomCats -NoCache)
            $old = $cur | Where-Object { $_.Key -eq $k } | Select-Object -First 1
            if (-not $old -and $cur.Count -ge $script:NotifyMaxCustomCats) { $script:__huAddOut = "Hoechstens $($script:NotifyMaxCustomCats) eigene Kategorien"; return }
            $list = @($cur | Where-Object { $_.Key -ne $k })
            $list += [pscustomobject]@{ Key = $(if ($old) { $old.Key } else { $k }); Label = $l; Default = $Default }
            Set-HUNotifyCustomCats -Items $list
            $script:__huAddOut = ''
        }
    }
    catch { $script:__huAddOut = "Kategorie nicht gespeichert: $($_.Exception.Message)" }
    $out = "$($script:__huAddOut)"; $script:__huAddOut = $null
    if (-not $out) { Write-HUNotifyModuleLog "Eigene Kategorie '$k' ($l) gespeichert" 'OK' }
    return $out
}

function Remove-HUNotifyCategory {
    <#
    .SYNOPSIS
        Entfernt eine eigene Kategorie. Eingebaute Kategorien koennen nicht entfernt werden. Rueckgabe: '' oder Grund.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Key)
    $k = "$Key".Trim()
    if ($script:NotifyCats.Contains($k)) { return "'$k' ist eine eingebaute Kategorie und kann nicht entfernt werden" }
    try {
        Invoke-HUNotifyLocked {
            $cur = @(Get-HUNotifyCustomCats -NoCache)
            if (-not ($cur | Where-Object { $_.Key -eq $k })) { $script:__huAddOut = "Kategorie '$k' nicht gefunden"; return }
            Set-HUNotifyCustomCats -Items @($cur | Where-Object { $_.Key -ne $k })
            $script:__huAddOut = ''
            # Haken an allen Zielen entfernen (Review 030 B28) - sonst gaelte er nach erneutem Anlegen wieder
            $c = Get-HUNotifyConfig
            if (-not $c.Error -and @($c.Targets | Where-Object { $_.Cats -and $_.Cats.ContainsKey($k) }).Count) {
                foreach ($t in @($c.Targets)) { if ($t.Cats -and $t.Cats.ContainsKey($k)) { $t.Cats.Remove($k) } }
                $w = Set-HUNotifyTargets -Targets @($c.Targets)
                if ($w) { Write-HUNotifyModuleLog "Kategorie '$k': Haken an den Zielen nicht bereinigt: $w" 'WARN' }
            }
        }
    }
    catch { $script:__huAddOut = "Kategorie nicht entfernt: $($_.Exception.Message)" }
    $out = "$($script:__huAddOut)"; $script:__huAddOut = $null
    if (-not $out) { Write-HUNotifyModuleLog "Eigene Kategorie '$k' entfernt" 'OK' }
    return $out
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
    try {
        Invoke-HUNotifyLocked {
            $c = Get-HUNotifyConfig
            if ($c.Error) { $script:__huAddOut = "Ziele nicht lesbar: $($c.Error)"; return }
            $list = @($c.Targets | Where-Object { $_.Id -ne $Id })
            $list += [pscustomobject]@{ Id = $Id; Name = $Name; Url = $Url; Enabled = $true; Cats = $Cats; Created = '' }
            $script:__huAddOut = (Set-HUNotifyTargets -Targets $list)
        }
    }
    catch { $script:__huAddOut = Hide-HUNotifyUrl "$($_.Exception.Message)" }
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
    try {
        Invoke-HUNotifyLocked {
            $c = Get-HUNotifyConfig
            if ($c.Error) { $script:__huAddOut = "Ziele nicht lesbar: $($c.Error)"; return }
            $script:__huAddOut = (Set-HUNotifyTargets -Targets @($c.Targets | Where-Object { $_.Id -ne $Id }))
        }
    }
    catch { $script:__huAddOut = Hide-HUNotifyUrl "$($_.Exception.Message)" }
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
    $map = Get-HUNotifyCatMap
    if (-not $map.Contains($Category)) { return $false }
    if ($null -eq $Target -or $null -eq $Target.Cats) { return [bool]$map[$Category][1] }
    $cats = $Target.Cats
    if ($cats -is [System.Collections.IDictionary]) { if ($cats.Contains($Category)) { return [bool]$cats[$Category] } }
    elseif ($cats.PSObject.Properties[$Category]) { return [bool]$cats.$Category }
    return [bool]$map[$Category][1]
}

# ============================================================================
# KARTEN
# ============================================================================

function New-HUTeamsCard {
    <#
    .SYNOPSIS
        Baut eine Adaptive Card (Workflows-Format) als Objekt. ConvertTo-Json erzeugt den Body.
    .DESCRIPTION
        Die Karte bleibt immer unter der Teams-Grenze (ca. 28 KB): ist sie zu gross, wird stufenweise
        gekuerzt (weniger/kuerzere Zeilen, Fakten, Ampel-Zeilen) und ein Hinweis "gekuerzt" eingefuegt.
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
    .PARAMETER Preview
        Text fuer die Push-Vorschau (Handy/Banner). Leer = Titel plus erste Ampel-Zeilen bzw. Zeilen.
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
        [string]$Category = '',
        [string]$Preview = ''
    )
    $color = switch ($Level) { 'Error' { 'Attention' } 'Warning' { 'Warning' } 'OK' { 'Good' } default { 'Accent' } }
    $allLines = @($Lines | Where-Object { "$_".Trim() })
    $allRows = @($Rows | Where-Object { $_ })
    # Fakten ueber den Enumerator lesen: Zahlen-Schluessel ([ordered]@{ 2024 = ... }) und Schluessel wie 'Keys' bleiben erhalten (Review 030 B3b)
    $factKeys = New-Object System.Collections.Generic.List[object]; $factVals = New-Object System.Collections.Generic.List[object]
    if ($Facts) { foreach ($e in $Facts.GetEnumerator()) { $factKeys.Add($e.Key); $factVals.Add($e.Value) } }

    # fallbackText/speak/summary: Textauszug fuer Push-Vorschau und Clients ohne Kartendarstellung.
    $sep = ' ' + [char]0x2022 + ' '   # Aufzaehlungspunkt (ueberlebt die Textbereinigung, anders als |)
    if ("$Preview".Trim()) { $fbParts = @("$Preview".Trim()) }
    else {
        $fbParts = @($allRows | Select-Object -First 3 | ForEach-Object { "$($_.Name): $($_.Text)" })
        if (-not $fbParts.Count) { $fbParts = @($allLines | Select-Object -First 3) }
    }
    $fb = ConvertTo-HUNotifySafeText -Text ("$Title" + $(if (@($fbParts).Count) { $sep + (@($fbParts) -join $sep) })) -Max 240

    $acts = @()
    foreach ($a in @($Actions | Where-Object { $_ } | Select-Object -First $script:NotifyMaxActions)) {   # Review 030 B5: hoechstens 5, Adresse <= 2048
        $au = "$($a.Url)".Trim(); $x = $null
        if ($au.Length -le 2048 -and [uri]::TryCreate($au, [UriKind]::Absolute, [ref]$x) -and $x.Scheme -eq 'https') {
            $acts += [ordered]@{ type = 'Action.OpenUrl'; title = (ConvertTo-HUNotifySafeText -Text "$($a.Title)" -Max 40); url = $au }
        }
    }
    $src = if ($Source) { $Source } else { [Environment]::MachineName }
    $foot = @((ConvertTo-HUNotifySafeText -Text $src -Max 40), (Get-Date).ToString('dd.MM.yyyy HH:mm'), $script:NotifyAppName)
    if ($Category) { $foot += (ConvertTo-HUNotifySafeText -Text $Category -Max 30) }

    # Stufen: ist die Karte zu gross, schrittweise kuerzen (Review 029 B7c/Q3) - Stufe 0 = normale Grenzen
    $steps = @(
        @{ Lines = $script:NotifyMaxLines; LineLen = 300; Facts = $script:NotifyMaxFacts; FactLen = 200; Rows = $script:NotifyMaxRows; RowLen = 300 }
        @{ Lines = 10; LineLen = 200; Facts = 10; FactLen = 120; Rows = 15; RowLen = 160 }
        @{ Lines = 5;  LineLen = 120; Facts = 6;  FactLen = 80;  Rows = 8;  RowLen = 100 }
        @{ Lines = 3;  LineLen = 80;  Facts = 4;  FactLen = 50;  Rows = 5;  RowLen = 60 }
    )
    $msg = $null
    for ($lvl = 0; $lvl -lt $steps.Count; $lvl++) {
        $st = $steps[$lvl]
        $body = New-Object System.Collections.Generic.List[object]
        $body.Add([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text $Title -Max 200); weight = 'Bolder'; size = 'Medium'; wrap = $true; color = $color })

        $n = 0
        foreach ($l in $allLines) {
            if (++$n -gt $st.Lines) { $body.Add([ordered]@{ type = 'TextBlock'; text = "... und $($allLines.Count - $st.Lines) weitere Zeilen"; isSubtle = $true; wrap = $true }); break }
            $body.Add([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text $l -Max $st.LineLen); wrap = $true; spacing = 'Small' })
        }

        if ($factKeys.Count) {
            $fs = New-Object System.Collections.Generic.List[object]
            $n = 0
            for ($fi = 0; $fi -lt $factKeys.Count; $fi++) {
                if (++$n -gt $st.Facts) { $fs.Add([ordered]@{ title = '...'; value = "und $($factKeys.Count - $st.Facts) weitere" }); break }
                $fs.Add([ordered]@{ title = (ConvertTo-HUNotifySafeText -Text "$($factKeys[$fi])" -Max 60); value = (ConvertTo-HUNotifySafeText -Text "$($factVals[$fi])" -Max $st.FactLen) })
            }
            $body.Add([ordered]@{ type = 'FactSet'; facts = $fs.ToArray(); spacing = 'Medium' })
        }

        $n = 0
        foreach ($r in $allRows) {
            if (++$n -gt $st.Rows) { $body.Add([ordered]@{ type = 'TextBlock'; text = "... und $($allRows.Count - $st.Rows) weitere Zeilen"; isSubtle = $true; wrap = $true; spacing = 'Small' }); break }
            $rs = "$($r.Status)"
            $dot = switch ($rs) { 'OK' { "$([char]0xD83D)$([char]0xDFE2)" } 'Warning' { "$([char]0xD83D)$([char]0xDFE1)" } 'Error' { "$([char]0xD83D)$([char]0xDD34)" } default { [string][char]0x26AA } }
            $rc = switch ($rs) { 'OK' { 'Good' } 'Warning' { 'Warning' } 'Error' { 'Attention' } default { 'Default' } }
            $cols = @(
                [ordered]@{ type = 'Column'; width = 'auto'; items = @([ordered]@{ type = 'TextBlock'; text = $dot; wrap = $false }) }
                [ordered]@{ type = 'Column'; width = '90px'; items = @([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text "$($r.Name)" -Max 40); weight = 'Bolder'; color = $rc; wrap = $true }) }
                [ordered]@{ type = 'Column'; width = 'stretch'; items = @([ordered]@{ type = 'TextBlock'; text = (ConvertTo-HUNotifySafeText -Text "$($r.Text)" -Max $st.RowLen); wrap = $true }) }
            )
            $body.Add([ordered]@{ type = 'ColumnSet'; columns = $cols; spacing = 'Small' })
        }

        if ($lvl -gt 0) { $body.Add([ordered]@{ type = 'TextBlock'; text = 'Gekuerzt: Nicht alle Eintraege passen in eine Teams-Karte. Die vollstaendige Liste hat das IT-Team (HU-MultiTenant).'; isSubtle = $true; color = 'Warning'; wrap = $true; spacing = 'Medium' }) }
        $body.Add([ordered]@{ type = 'TextBlock'; text = ($foot -join '  |  '); isSubtle = $true; size = 'Small'; wrap = $true; spacing = 'Medium' })

        $card = [ordered]@{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; fallbackText = $fb; speak = $fb; body = $body.ToArray() }
        if ($acts.Count -and $lvl -lt $steps.Count - 1) { $card['actions'] = $acts }   # letzte Stufe: ohne Knoepfe
        $msg = [ordered]@{ type = 'message'; summary = $fb; text = $fb; attachments = @([ordered]@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null; content = $card }) }
        $size = [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $msg -Depth 20 -Compress))
        if ($size -le $script:NotifyMaxBytes) { break }
        if ($lvl -lt $steps.Count - 1) { Write-HUNotifyModuleLog "Karte '$(ConvertTo-HUNotifySafeText -Text $Title -Max 60)' zu gross ($size Byte) - wird gekuerzt (Stufe $($lvl + 1))" 'WARN' }
        else { Write-HUNotifyModuleLog "Karte '$(ConvertTo-HUNotifySafeText -Text $Title -Max 60)' auch gekuerzt zu gross ($size Byte) - Senden wird abgelehnt" 'ERROR' }
    }
    return $msg
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

function Grant-HUSendApproval {
    <#
    .SYNOPSIS
        Gibt das Senden fuer diese Modulinstanz frei (App-Start, Auftraege, Snippet-Lauf nach "Ja"). Review 030 B4a.
    #>
    [CmdletBinding()]
    param([string]$Reason = 'App')
    $script:NotifySendApproval = [pscustomobject]@{ Reason = $Reason; Since = Get-Date }
}

function Revoke-HUSendApproval {
    <#
    .SYNOPSIS
        Nimmt die Sendefreigabe zurueck.
    #>
    [CmdletBinding()]
    param()
    $script:NotifySendApproval = $null
}

function Set-HUNotifyRoute {
    <#
    .SYNOPSIS
        Ab jetzt gehen Send-HUNotify-Aufrufe an die Ziele dieser Meldung (leer = alle aktiven Ziele), Kategorie egal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string[]]$TargetIds = @())
    $script:NotifyRoute = [pscustomobject]@{ Name = $Name; TargetIds = @($TargetIds | Where-Object { "$_" }); Ok = 0; Failed = 0; Calls = 0 }
}

function Clear-HUNotifyRoute {
    <#
    .SYNOPSIS
        Meldungs-Route entfernen (danach wieder Kategorien).
    #>
    [CmdletBinding()]
    param()
    $script:NotifyRoute = $null
}

function Get-HUNotifyRoute {
    <#
    .SYNOPSIS
        Aktuelle Meldungs-Route mit Zaehlern (Calls, Ok, Failed) oder $null.
    #>
    [CmdletBinding()]
    param()
    return $script:NotifyRoute
}

function Test-HUSendApproval {
    <#
    .SYNOPSIS
        Ist Senden in dieser Modulinstanz freigegeben?
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ($null -ne $script:NotifySendApproval)
}

function Send-HUTeamsCard {
    <#
    .SYNOPSIS
        Sendet eine Karte an eine Webhook-Adresse. Rueckgabe: '' = gesendet, sonst Grund. Wirft nie.
    .PARAMETER Card
        Objekt aus New-HUTeamsCard (oder fertiger JSON-String).
    .PARAMETER Url
        Webhook-Adresse (Workflows).
    .PARAMETER Retries
        Wiederholungen bei 429/5xx (Standard 2, Wartezeit 3 s / 6 s bzw. Retry-After); Zeitueberschreitung nur einmal.
        Umleitungen (3xx) werden nie wiederholt und nie gefolgt.
    .PARAMETER Target
        Anzeigename des Ziels fuer -WhatIf/-Confirm (nie die Adresse - sie enthaelt die Signatur).
    .NOTES
        -WhatIf und -Confirm werden unterstuetzt (Review 030 B4). Bewusst ConfirmImpact Medium: kein automatischer
        Dialog bei jedem Aufruf (WPF/Headless haben keine Konsole). Die Rueckfrage je Snippet-/Erweiterungslauf macht die
        Oberflaeche einmal vor dem Start.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Card,
        [Parameter(Mandatory)][string]$Url,
        [int]$Retries = 2,
        [string]$Target = '(Webhook)'
    )
    if ($null -eq $script:NotifySendApproval) {
        Write-HUNotifyModuleLog "Karte an '$Target' nicht freigegeben - nichts gesendet" 'WARN'
        return 'Nicht freigegeben - nichts gesendet'
    }
    $why = Test-HUWebhookUrl $Url
    if ($why) { return "Webhook-Adresse ungueltig: $why" }
    try {
        $json = if ($Card -is [string]) { $Card } else { ConvertTo-HUTeamsCardJson -Card $Card }
        if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 27000) { throw 'Karte zu gross (max. 28 KB) - weniger Zeilen senden' }   # auch fertige JSON-Texte (Review 030 B5)
    }
    catch { return "Karte ungueltig: $($_.Exception.Message)" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    if (-not $PSCmdlet.ShouldProcess($Target, "Teams-Karte senden ($($bytes.Length) Byte)")) { return 'Nicht gesendet (Probelauf/abgelehnt)' }
    $last = ''
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $Url.Trim() -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop
            # B14: eine Umleitung, die nicht als Fehler kommt, ist trotzdem kein Erfolg
            $sc = 0; try { if ($resp) { $sc = [int]$resp.StatusCode } } catch { }
            if ($sc -ge 300 -and $sc -lt 400) { return "Senden abgelehnt (Umleitung $sc): die Adresse leitet weiter - bitte die vollstaendige Workflow-Adresse aus Teams eintragen (kein Kurzlink)" }
            return ''
        }
        catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            $last = Hide-HUNotifyUrl "$($_.Exception.Message)"
            # Review 029 B14/Q4: PS 5.1 wirft bei -MaximumRedirection 0 eine InvalidOperationException ohne Response
            $isRedirect = ($code -ge 300 -and $code -lt 400) -or ($code -eq 0 -and $_.Exception -is [System.InvalidOperationException] -and "$($_.Exception.Message)" -match '(?i)redirect|umleitung')
            if ($isRedirect) { return "Senden abgelehnt (Umleitung$(if ($code) { " $code" })): die Adresse leitet weiter - bitte die vollstaendige Workflow-Adresse aus Teams eintragen (kein Kurzlink)" }
            # B23: Zeitueberschreitung (kein Statuscode) nur einmal wiederholen
            $retry = ($code -eq 429 -or $code -ge 500 -or ($code -eq 0 -and $i -eq 0))
            if ($code -eq 400) { return "Senden abgelehnt (400): Workflow erwartet eine Adaptive Card - Trigger 'When a Teams webhook request is received' pruefen" }
            if ($code -eq 401 -or $code -eq 403) { return "Senden abgelehnt ($code): Adresse/Signatur ungueltig - Workflow neu anlegen" }
            if ($code -eq 404) { return 'Senden abgelehnt (404): Workflow nicht gefunden - geloescht oder deaktiviert' }
            if (-not $retry -or $i -eq $Retries) { break }
            $wait = 3 * ($i + 1)
            try { $ra = [int]"$($_.Exception.Response.Headers['Retry-After'])"; if ($ra -gt 0) { $wait = [math]::Min(30, $ra) } } catch { }
            # Review 030 B17: hoechstens ca. 45 s je Ziel (Timeouts + Wartezeiten zusammen)
            if ($sw.Elapsed.TotalSeconds + $wait -gt 45) { break }
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
    # Protokoll (ohne Adressen): Zeit, Ziel, Kategorie, Titel, Ergebnis. -Entries schreibt mehrere Eintraege in einem Zug.
    param([string]$TargetName, [string]$Tag, [string]$Category, [string]$Title, [string]$Result, [object[]]$Entries)
    $new = @()
    if ($Entries) { $new = @($Entries | Where-Object { $_ }) }
    else { $new = @([pscustomobject]@{ TargetName = $TargetName; Tag = $Tag; Category = $Category; Title = $Title; Result = $Result }) }
    $now = (Get-Date).ToString('s')
    $rows = @($new | ForEach-Object { [pscustomobject]@{ Time = $now; Target = "$($_.TargetName)"; Tag = "$($_.Tag)"; Category = "$($_.Category)"; Title = (ConvertTo-HUNotifySafeText -Text "$($_.Title)" -Max 120); Result = (Hide-HUNotifyUrl "$($_.Result)") } })
    for ($try = 1; $try -le 2; $try++) {
        try {
            Invoke-HUNotifyLocked {
                $list = @()
                if (Test-Path -LiteralPath $script:NotifyHistFile -PathType Leaf) {
                    try { $list = @(Expand-HUNotifyHistoryNode -Node (Get-Content -LiteralPath $script:NotifyHistFile -Raw -Encoding UTF8 | ConvertFrom-Json)) }
                    catch { try { Copy-Item -LiteralPath $script:NotifyHistFile -Destination "$($script:NotifyHistFile).bak" -Force } catch { }; $list = @() }
                }
                $list += $rows
                $list = @($list | Select-Object -Last $script:NotifyMaxHistory)
                if (-not (Test-Path -LiteralPath $script:NotifyBasePath)) { New-Item -Path $script:NotifyBasePath -ItemType Directory -Force | Out-Null }
                # PS 5.1: Array als Eigenschaft verpacken (sonst value/Count-Huelle)
                $json = ([ordered]@{ v = 1; items = @($list) } | ConvertTo-Json -Depth 5 -Compress)
                $tmp = "$($script:NotifyHistFile).tmp.$PID"
                [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $tmp -Destination $script:NotifyHistFile -Force
            }
            return
        }
        catch {
            # Review 030 B9: nicht stumm verwerfen - einmal nachfassen, dann im Log festhalten
            if ($try -eq 1) { Start-Sleep -Milliseconds 1500; continue }
            Write-HUNotifyModuleLog "Sendeprotokoll nicht geschrieben ($(@($rows).Count) Eintrag/Eintraege): $($_.Exception.Message)" 'WARN'
        }
    }
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
        Wirft nie. Rueckgabe-Objekt: Ok (gesendet), Failed (fehlgeschlagen), Text (Protokolltext; bei Ok=0/Failed=0 der Grund,
        warum kein Ziel angesprochen wurde). Ohne Sendefreigabe (Grant-HUSendApproval) wird nichts gesendet.
        -TargetIds: nur diese Ziele; mit -IgnoreCategory auch, wenn die Kategorie dort aus ist.
        -Preview: eigener Text fuer die Push-Vorschau (sonst Titel plus erste Zeilen).
        -Category: eingebaute Kategorie oder eigene (Reiter Teams > Kategorien > + Kategorie).
    .EXAMPLE
        Send-HUNotify -Category Devices -Title 'HLW: 7 Geraete nicht konform' -Level Warning -Lines @('NB-123 (Maier T.)')
    .EXAMPLE
        Send-HUNotify -Category Backup -Title 'Backup HLW fertig' -Level OK -Facts ([ordered]@{ Dauer = '12 min'; Dateien = 4211 })
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Category = '',
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines = @(),
        [ValidateSet('OK', 'Warning', 'Error', 'Info')][string]$Level = 'Info',
        [System.Collections.IDictionary]$Facts,
        [object[]]$Rows = @(),
        [hashtable[]]$Actions = @(),
        [string]$Source = '',
        [string[]]$TargetIds = @(),
        [switch]$IgnoreCategory,
        [string]$Preview = ''
    )
    $res = [pscustomobject]@{ Ok = 0; Failed = 0; Text = '' }
    $route = $script:NotifyRoute
    if ($route) {
        # Meldung aus Skript: Ziele der Meldung, Kategorie egal (Fusszeile/Protokoll zeigen den Namen der Meldung)
        $route.Calls++
        $TargetIds = @($route.TargetIds); $IgnoreCategory = $true
        $catLabel = "$($route.Name)"; $histCat = "$($route.Name)"
    }
    else {
        $map = Get-HUNotifyCatMap
        if (-not $Category -and $TargetIds.Count) { $IgnoreCategory = $true; $Category = 'Skript' }   # eigenes Skript: direkt an diese Ziele
        elseif (-not $Category) { $res.Text = "Teams: nichts gesendet - dieses Skript ist keiner Meldung zugeordnet (Reiter Teams > Meldungen > + Neu > 'oder Meldung aus Skript')"; return $res }
        if ($Category -eq 'Skript' -and $IgnoreCategory) { $map = [ordered]@{ Skript = @($(if ($Source) { $Source } else { 'Skript' }), $false, $true) } }
        if (-not $map.Contains($Category)) { $res.Text = "Unbekannte Kategorie: $Category - nichts gesendet. Skript im Reiter Teams als 'Meldung aus Skript' anlegen."; $res.Failed = 1; return $res }
        $catLabel = $map[$Category][0]; $histCat = $Category
    }
    $c = Get-HUNotifyConfig
    if ($c.Error) { $res.Text = "Teams-Benachrichtigung: Ziele nicht lesbar: $($c.Error)"; $res.Failed = 1; if ($route) { $route.Failed++ }; return $res }
    if (-not $c.Configured) { $res.Text = 'Teams: kein Ziel eingerichtet - nichts gesendet'; return $res }
    try { $card = New-HUTeamsCard -Title $Title -Lines $Lines -Level $Level -Facts $Facts -Rows $Rows -Actions $Actions -Source $Source -Category $catLabel -Preview $Preview }
    catch { $res.Failed = 1; $res.Text = "Karte nicht gebaut: $(Hide-HUNotifyUrl "$($_.Exception.Message)")"; if ($route) { $route.Failed++ }; return $res }
    $out = @(); $hist = @(); $blocked = $false
    foreach ($t in @($c.Targets | Where-Object { $_ -and $_.Enabled })) {
        if ($TargetIds.Count -and ($TargetIds -notcontains $t.Id)) { continue }
        if (-not $IgnoreCategory -and -not (Test-HUNotifyCat -Target $t -Category $Category)) { continue }
        if ($null -eq $script:NotifySendApproval) { $blocked = $true; break }   # Sendefreigabe fehlt (Review 030 B4a)
        # -WhatIf ausdruecklich weiterreichen (Script-Module erben es nicht zuverlaessig), nie nachfragen
        $r = Send-HUTeamsCard -Card $card -Url $t.Url -Target $t.Name -WhatIf:$WhatIfPreference -Confirm:$false
        if ($r) { $res.Failed++ } else { $res.Ok++ }
        $tag = Get-HUNotifyUrlTag $t.Url
        $hist += [pscustomobject]@{ TargetName = $t.Name; Tag = $tag; Category = $histCat; Title = $Title; Result = $(if ($r) { $r } else { 'gesendet' }) }
        Write-HUNotifyModuleLog "$($t.Name) [$tag] $histCat - $(if ($r) { $r } else { 'gesendet' })" $(if ($r) { 'WARN' } else { 'OK' })
        $out += "$($t.Name): $(if ($r) { $r } else { 'gesendet' })"
    }
    if ($hist.Count) { Add-HUNotifyHistory -Entries $hist }   # ein Schreibvorgang je Meldung (Review 030 B9)
    if ($blocked) {
        Write-HUNotifyModuleLog "$histCat - nicht freigegeben, nichts gesendet" 'WARN'
        $res.Text = 'Teams: fuer diesen Lauf nicht freigegeben - nichts gesendet'
    }
    elseif ($out.Count) { $res.Text = "Teams-Benachrichtigung: $($out -join '; ')" }
    elseif ($route) { $res.Text = "Teams: Meldung '$($route.Name)' hat kein aktives Ziel - nichts gesendet" }
    elseif ($TargetIds.Count) { $res.Text = "Teams: keines der angegebenen Ziele ist aktiv$(if (-not $IgnoreCategory) { " bzw. hat Kategorie '$Category' angehakt" }) - nichts gesendet" }
    else { $res.Text = "Teams: kein aktives Ziel hat Kategorie '$Category' angehakt - nichts gesendet" }
    if ($route) { $route.Ok += $res.Ok; $route.Failed += $res.Failed }
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
    $r = Send-HUTeamsCard -Card $card -Url $Url -Retries 0 -Target $Name -Confirm:$false
    Add-HUNotifyHistory -TargetName $Name -Tag (Get-HUNotifyUrlTag $Url) -Category 'Test' -Title 'Testnachricht' -Result $(if ($r) { $r } else { 'gesendet' })
    return $r
}

# ============================================================================
# EXPORT
# ============================================================================

Export-ModuleMember -Function @(
    'Get-HUNotifyCategories',
    'Add-HUNotifyCategory',
    'Remove-HUNotifyCategory',
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
    'Grant-HUSendApproval',
    'Revoke-HUSendApproval',
    'Test-HUSendApproval',
    'Set-HUNotifyRoute',
    'Clear-HUNotifyRoute',
    'Get-HUNotifyRoute',
    'Send-HUNotifyTest',
    'Add-HUNotifyHistory',
    'Invoke-HUNotifyLocked',
    'Get-HUNotifyHistory'
)
