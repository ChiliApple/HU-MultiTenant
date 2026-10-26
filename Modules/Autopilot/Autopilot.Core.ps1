#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatzmodul Autopilot - Graph-Zugriffe (Stufe 1: nur lesen).
.DESCRIPTION
    Laeuft im Hintergrund-Auftrag von HU-MultiTenant (Module HU.Auth und HU.Graph geladen).
    Stufe 1 liest Autopilot-Geraete (klassisch, mit Hardware-Hash) und gleicht sie mit Intune ab. Es wird nichts geaendert.
    Profilstatus (deploymentProfileAssignmentStatus) gibt es nur in Graph beta - deshalb liest die Liste aus beta.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Grundlage: Konzept Autopilot-Modul.
    Quellen: https://learn.microsoft.com/graph/api/resources/intune-enrollment-windowsautopilotdeviceidentity?view=graph-rest-beta
#>

if (-not (Get-Command Write-HULog -ErrorAction SilentlyContinue)) {
    function Write-HULog([string]$Message, [string]$Level = 'INFO', [string]$Tenant = '') { Write-Host "[$Level] $Message" }
}

# ---------------------------------------------------------------------------------------------
# Rechte der HU-MultiTenant-App zum Lesen (Schreiben: DeviceManagementScripts.ReadWrite.All + ManagedDevices.PrivilegedOperations.All nur fuer 'Wartung starten') (Microsoft Graph, Anwendungsberechtigungen)
# ---------------------------------------------------------------------------------------------
$script:APRechte = @(
    @{ Name = 'DeviceManagementServiceConfig.Read.All';  Wofuer = 'Autopilot-Geraete, Group Tags und Profilstatus lesen' }
    @{ Name = 'DeviceManagementManagedDevices.Read.All'; Wofuer = 'Abgleich mit Intune (Geraetename, letzte Synchronisierung)' }
    @{ Name = 'DeviceManagementScripts.Read.All';        Wofuer = 'Hash-Archiv: Ergebnisse der Wartung HU-AP-Hash abholen' }
)

# Anzeige-Texte fuer Graph-Werte (Werte laut Graph beta)
$script:APProfilText = @{
    assignedInSync          = 'zugewiesen'
    assignedOutOfSync       = 'zugewiesen (nicht synchron)'
    assignedUnkownSyncState = 'zugewiesen'
    notAssigned             = 'kein Profil'
    pending                 = 'ausstehend'
    failed                  = 'fehlgeschlagen'
    unknown                 = 'unbekannt'
}
$script:APRegText = @{
    enrolled     = 'registriert'
    notContacted = 'nie gemeldet'
    pendingReset = 'Zuruecksetzen ausstehend'
    failed       = 'fehlgeschlagen'
    blocked      = 'blockiert'
    unknown      = 'unbekannt'
}

# ---------------------------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------------------------
function Get-APToken([string]$TenantKey, $Settings) {
    $t = Get-GraphToken -TenantKey $TenantKey -Settings $Settings
    if (-not $t) { throw "kein Token fuer $TenantKey (App-Registrierung bzw. Zertifikat pruefen)" }
    return $t
}
function ConvertTo-APUrl([string]$Endpoint, [string]$ApiVersion) {
    if ($Endpoint -match '^https://') { return $Endpoint }
    $v = if ($ApiVersion -eq 'beta') { 'beta' } else { 'v1.0' }
    return "https://graph.microsoft.com/$v/$($Endpoint.TrimStart('/'))"
}
# Lesen: wirft bei Fehler (403 deutlich als fehlendes Recht)
function Invoke-APGet([string]$Token, [string]$Endpoint, [string]$ApiVersion = 'v1.0') {
    $r = Invoke-GraphRequestWithRetry -Token $Token -Endpoint (ConvertTo-APUrl $Endpoint $ApiVersion)
    if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
        $ep = $Endpoint -replace '\?.*$', '' -replace '^https://graph\.microsoft\.com/(v1\.0|beta)', ''
        if ("$($r.StatusCode)" -eq '403') { throw "Recht fehlt (403) fuer $ep" }
        if ("$($r.StatusCode)" -eq '404') { throw "nicht gefunden (404): $ep" }
        throw "$($r.StatusCode) $($r.ErrorMessage)"
    }
    return $r
}
# Alle Seiten; ein Fehler bricht ab (kein stilles "leer")
function Get-APAll([string]$Token, [string]$Endpoint, [string]$ApiVersion = 'v1.0') {
    $out = New-Object System.Collections.ArrayList
    $next = ConvertTo-APUrl $Endpoint $ApiVersion
    $n = 0
    while ($next -and $n -lt 500) {
        $n++
        $r = Invoke-APGet $Token $next
        foreach ($v in @($r.value)) { if ($null -ne $v) { [void]$out.Add($v) } }
        $next = "$($r.'@odata.nextLink')"
    }
    if ($next) { Write-HULog -Message "Mehr als $n Seiten bei $($Endpoint -replace '\?.*$', '') - Liste unvollstaendig" -Level 'WARN' }
    return $out.ToArray()
}

# Fehlende Rechte eines Tenants aus dem Token (Claim roles). X.Read.All gilt auch durch X.ReadWrite.All als erfuellt.
# -Liste: andere Rechte pruefen (z. B. die fuer Aufnehmen). Group.Create gilt auch durch Group.ReadWrite.All als erfuellt.
function Get-APFehlendeRechte([string]$TenantKey, $Settings, [switch]$Neu, [string[]]$Liste, [string]$Art = '') {
    $r = [pscustomobject]@{ Tenant = $TenantKey; Fehlt = @(); Fehler = ''; Art = $Art }
    $namen = if (@($Liste).Count) { @($Liste) } else { @($script:APRechte | ForEach-Object { $_.Name }) }
    try {
        $p = @{ TenantKey = $TenantKey; Settings = $Settings }
        if ($Neu) { $p.ForceRefresh = $true }
        $tok = Get-GraphToken @p
        if (-not $tok) { $r.Fehler = 'kein Token'; return $r }
        $roles = @(Get-TokenPermissions -Token $tok)
        $r.Fehlt = @(foreach ($n in $namen) {
                $rw = $n -replace '\.Read\.All$', '.ReadWrite.All'
                if ($n -eq 'Group.Create') { $rw = 'Group.ReadWrite.All' }
                if ($roles -notcontains $n -and $roles -notcontains $rw) { $n }
            })
    } catch { $r.Fehler = "$($_.Exception.Message)" }
    return $r
}

# ---------------------------------------------------------------------------------------------
# Hilfen
# ---------------------------------------------------------------------------------------------
# Datum aus Graph (PS 5.1: Text, PS 7: DateTime) -> lokale Anzeige; leer bei fehlendem Wert oder 0001-01-01
function ConvertTo-APZeit($Wert) {
    if ($null -eq $Wert -or "$Wert" -eq '') { return '' }
    $d = $null
    if ($Wert -is [datetime]) { $d = $Wert }
    elseif ($Wert -is [datetimeoffset]) { $d = $Wert.UtcDateTime }
    else {
        $o = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse("$Wert", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$o)) { $d = $o.UtcDateTime } else { return '' }
    }
    if ($d.Year -lt 2000) { return '' }
    if ($d.Kind -ne [DateTimeKind]::Local) { $d = [datetime]::SpecifyKind($d, [DateTimeKind]::Utc).ToLocalTime() }
    return $d.ToString('yyyy-MM-dd HH:mm')
}
function Test-APLeereId([string]$Id) { return (-not $Id -or $Id -match '^[0-]+$') }
# Seriennummer fuer Vergleiche (Gross, ohne Leerzeichen)
function ConvertTo-APSerial([string]$S) { return ("$S" -replace '\s', '').ToUpperInvariant() }

# Ampel je Geraet (Konzept I1 "bereit fuer die Ausgabe": Group Tag + Profil zugewiesen)
function Get-APStatus([string]$ProfilRoh, [string]$GroupTag) {
    switch -Wildcard ($ProfilRoh) {
        'assigned*' {
            if (-not $GroupTag) { return @('Warnung', 'Profil zugewiesen, aber ohne Group Tag') }
            # assignedUnkownSyncState ist der Normalfall (Graph-Schreibweise so) - gilt als zugewiesen
            if ($ProfilRoh -eq 'assignedOutOfSync') { return @('Warnung', 'Profil zugewiesen, aber nicht synchron - Autopilot-Geraete synchronisieren') }
            return @('Bereit', '')
        }
        'pending' { return @('Warnung', 'Profil wird zugewiesen (ausstehend)') }
        'failed' { return @('Fehler', 'Profilzuweisung fehlgeschlagen') }
        'notAssigned' { return @('Fehlt', $(if ($GroupTag) { 'kein Profil - dynamische Gruppe bzw. Profil-Zuweisung pruefen' } else { 'kein Profil und kein Group Tag' })) }
        default { return @('Fehlt', 'Profilstatus unbekannt') }
    }
}

# Eine Zeile fuer die Uebersicht (ohne Hash). Benutzer fuer Anzeige und Inventar-Export (Udo 26.10.), nie ins Hash-Archiv.
function ConvertTo-APZeile($Ap, [hashtable]$IntuneById, [hashtable]$IntuneBySerial, [string]$TenantKey) {
    $ser = "$($Ap.serialNumber)"
    $prof = if ($Ap.PSObject.Properties['deploymentProfileAssignmentStatus']) { "$($Ap.deploymentProfileAssignmentStatus)" } else { 'unknown' }
    $reg = "$($Ap.enrollmentState)"
    $tag = "$($Ap.groupTag)"
    $mdId = "$($Ap.managedDeviceId)"
    $md = $null
    if (-not (Test-APLeereId $mdId) -and $IntuneById.ContainsKey($mdId)) { $md = $IntuneById[$mdId] }
    elseif ($ser -and $IntuneBySerial.ContainsKey((ConvertTo-APSerial $ser))) { $md = $IntuneBySerial[(ConvertTo-APSerial $ser)] }
    $st = Get-APStatus $prof $tag
    $hinweis = $st[1]
    if (-not $md -and -not (Test-APLeereId $mdId)) { $hinweis = (@($hinweis, 'Autopilot verweist auf ein Intune-Geraet, das es nicht mehr gibt') | Where-Object { $_ }) -join '; ' }
    $name = if ($md -and "$($md.deviceName)") { "$($md.deviceName)" } else { "$($Ap.displayName)" }
    return [pscustomobject]@{
        Tenant          = $TenantKey
        Status          = $st[0]
        Seriennummer    = $ser
        Hersteller      = "$($Ap.manufacturer)"
        Modell          = "$($Ap.model)"
        GroupTag        = $tag
        Profil          = $(if ($script:APProfilText.ContainsKey($prof)) { $script:APProfilText[$prof] } else { $prof })
        Registrierung   = $(if ($script:APRegText.ContainsKey($reg)) { $script:APRegText[$reg] } else { $reg })
        InIntune        = $(if ($md) { 'ja' } else { 'nein' })
        Eigentum        = $(if ($md) { switch ("$($md.managedDeviceOwnerType)") { 'company' { 'Firma' } 'personal' { 'privat' } default { "$($md.managedDeviceOwnerType)" } } } else { '' })
        Verwaltung      = $(if ($md) { "$($md.managementState)" } else { '' })
        LetzterSyncRoh  = $(if ($md) { "$($md.lastSyncDateTime)" } else { '' })
        ApBenutzer      = "$($Ap.userPrincipalName)"
        AadId           = $(if ($md) { "$($md.azureADDeviceId)" } else { "$($Ap.azureActiveDirectoryDeviceId)" })
        Geraetename     = $name
        # Benutzer: Primaerbenutzer laut Intune, sonst der in Autopilot zugewiesene (nur Anzeige, nicht ins Archiv/Export)
        Benutzer        = $(if ($md -and "$($md.userPrincipalName)") { "$($md.userPrincipalName)" } else { "$($Ap.userPrincipalName)" })
        LetzterKontakt  = (ConvertTo-APZeit $Ap.lastContactedDateTime)
        LetzterSync     = $(if ($md) { ConvertTo-APZeit $md.lastSyncDateTime } else { '' })
        # Autopilot liefert kein Import-/Registrierungsdatum (Graph) - naechstes Datum: Einrichtung in Intune
        EingerichtetAm  = $(if ($md) { ConvertTo-APZeit $md.enrolledDateTime } else { '' })
        Hinweis         = $hinweis
        ProfilRoh       = $prof
        AutopilotId     = "$($Ap.id)"
        IntuneId        = $(if ($md) { "$($md.id)" } else { '' })
    }
}

# ---------------------------------------------------------------------------------------------
# Uebersicht je Tenant (nur lesen)
# ---------------------------------------------------------------------------------------------
function Get-APUebersicht([string]$TenantKey, $Settings) {
    $tok = Get-APToken $TenantKey $Settings
    Write-HULog -Message 'Lese Autopilot-Geraete (Graph beta wegen Profilstatus) ...' -Level 'INFO' -Tenant $TenantKey
    $ap = @(Get-APAll $tok '/deviceManagement/windowsAutopilotDeviceIdentities' 'beta')
    Write-HULog -Message 'Lese Intune-Geraete (Windows) fuer den Abgleich ...' -Level 'INFO' -Tenant $TenantKey
    $md = @(Get-APAll $tok "/deviceManagement/managedDevices?`$select=id,deviceName,serialNumber,operatingSystem,lastSyncDateTime,enrolledDateTime,userPrincipalName,managedDeviceOwnerType,managementState,azureADDeviceId")
    $byId = @{}; $bySer = @{}
    foreach ($m in $md) {
        if ("$($m.operatingSystem)" -notlike 'Windows*') { continue }
        $byId["$($m.id)"] = $m
        $s = ConvertTo-APSerial "$($m.serialNumber)"
        if ($s -and $s -ne 'SYSTEMSERIALNUMBER' -and $s -ne 'DEFAULTSTRING' -and $s -ne '0') { $bySer[$s] = $m }
    }
    $rows = @(foreach ($a in $ap) { ConvertTo-APZeile $a $byId $bySer $TenantKey })
    $n = @{}; foreach ($r in $rows) { $n[$r.Status] = 1 + [int]$n[$r.Status] }
    $txt = (@('Bereit', 'Warnung', 'Fehlt', 'Fehler' | ForEach-Object { if ($n[$_]) { "$_ $($n[$_])" } }) -join ', ')
    Write-HULog -Message "$($rows.Count) Autopilot-Geraete$(if ($txt) { ": $txt" })" -Level $(if ($n['Fehlt'] -or $n['Fehler']) { 'WARN' } else { 'OK' }) -Tenant $TenantKey
    return $rows
}

# Zusammenfassung je Tenant + Group Tag (fuer "Tags & Gruppen")
function Get-APTagSummen([object[]]$Rows) {
    $out = @()
    foreach ($g in @($Rows | Group-Object { "$($_.Tenant)|$($_.GroupTag)" })) {
        $f = $g.Group[0]
        $out += [pscustomobject]@{
            Tenant     = "$($f.Tenant)"
            GroupTag   = $(if ("$($f.GroupTag)") { "$($f.GroupTag)" } else { '(ohne)' })
            Geraete    = $g.Count
            Bereit     = @($g.Group | Where-Object { $_.Status -eq 'Bereit' }).Count
            OhneProfil = @($g.Group | Where-Object { $_.ProfilRoh -in 'notAssigned', 'unknown', 'failed' }).Count
            InIntune   = @($g.Group | Where-Object { $_.InIntune -eq 'ja' }).Count
        }
    }
    return @($out | Sort-Object Tenant, GroupTag)
}

# ---------------------------------------------------------------------------------------------
# Hash per Wartung einsammeln (Konzept 4.6): ein Paket "HU-AP-Hash", nur Erkennung, SYSTEM.
# Das Geraet liest den Hash EINMAL, merkt ihn unter ProgramData und gibt ihn komprimiert aus:
#   HUAP|1|<Seriennummer>|<SHA256-12>|<Deflate+Base64>   (ca. 1.300 Zeichen, Limit 2.048)
# Graph: beta deviceHealthScripts, initiateOnDemandProactiveRemediation, deviceRunStates (getestet 26.10.)
# ---------------------------------------------------------------------------------------------
$script:APHashPaketName = 'HU-AP-Hash'
$script:APHashSkript = @'
# HU-AP-Hash - Erkennungsskript (Intune-Wartung), Zielmaschine: Windows-Geraet, laeuft als SYSTEM
# Liest den Autopilot-Hardware-Hash EINMAL und merkt ihn am Geraet (der Wert ist bei jedem Lesen anders),
# gibt ihn komprimiert in einer Zeile aus: HUAP|1|<Seriennummer>|<SHA256-12>|<Deflate+Base64>
# Kein Secret, keine Aenderung am System ausser der Merkdatei. Exit 0 = keine Korrektur.
$ErrorActionPreference = 'Stop'
try {
    $dir = Join-Path $env:ProgramData 'HU-MultiTenant'
    $f = Join-Path $dir 'AP-Hash.txt'
    $h = ''
    if (Test-Path -LiteralPath $f) { $h = "$(Get-Content -LiteralPath $f -Raw)".Trim() }
    $ok = $false
    if ($h) { try { $ok = ([Convert]::FromBase64String($h).Length -gt 1000) } catch { $ok = $false } }
    if (-not $ok) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # nur SYSTEM und Administratoren
            & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
        }
        $d = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
        $h = "$($d.DeviceHardwareData)".Trim()
        if (-not $h) { Write-Output 'HUAP|1|FEHLER|kein Hash lesbar'; exit 0 }
        # nur anlegen, wenn noch nicht vorhanden (zwei gleichzeitige Laeufe ueberschreiben sich nicht)
        $tmp = "$f.$PID.tmp"
        [IO.File]::WriteAllText($tmp, $h, (New-Object Text.UTF8Encoding($false)))
        try { [IO.File]::Move($tmp, $f) } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; if (-not $ok -and (Test-Path -LiteralPath $f)) { $h = "$(Get-Content -LiteralPath $f -Raw)".Trim() } }
    }
    $ser = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $s12 = (-join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($h)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 12) } finally { $sha.Dispose() }
    $roh = [Convert]::FromBase64String($h)
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionLevel]::Optimal)
    $ds.Write($roh, 0, $roh.Length); $ds.Dispose()
    Write-Output ("HUAP|1|{0}|{1}|{2}" -f $ser, $s12, [Convert]::ToBase64String($ms.ToArray()))
    exit 0
} catch {
    Write-Output "HUAP|1|FEHLER|$($_.Exception.Message)"
    exit 0
}
'@
$script:APBeta = 'https://graph.microsoft.com/beta/deviceManagement'

function Get-APHashPaket([string]$Token) {
    $p = @(Get-APAll $Token "$script:APBeta/deviceHealthScripts?`$select=id,displayName" | Where-Object { "$($_.displayName)" -eq $script:APHashPaketName })
    if ($p.Count) { return $p[0] }
    return $null
}
# Paket anlegen, falls es fehlt (ohne Zuweisung). Rueckgabe: Paket-ID
function Initialize-APHashPaket([string]$Token, [string]$TenantKey = '') {
    $p = Get-APHashPaket $Token
    if ($p) { return "$($p.id)" }
    $body = @{
        '@odata.type'          = '#microsoft.graph.deviceHealthScript'
        displayName            = $script:APHashPaketName
        description            = 'Liest den Autopilot-Hardware-Hash und gibt ihn komprimiert aus (angelegt von HU-MultiTenant). Keine Korrektur.'
        publisher              = 'HU-MultiTenant'
        runAsAccount           = 'system'
        runAs32Bit             = $false
        enforceSignatureCheck  = $false
        detectionScriptContent = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($script:APHashSkript))
        roleScopeTagIds        = @('0')
    }
    $r = Invoke-APWrite $Token "$script:APBeta/deviceHealthScripts" 'POST' $body
    Write-HULog -Message "Wartungspaket $script:APHashPaketName angelegt (ohne Zuweisung)" -Level 'OK' -Tenant $TenantKey
    return "$($r.id)"
}
# Einmalig senden (ohne Wiederholung) - fuer Wipe, Retire und Import (065 B3: eine Wiederholung nach 5xx kann doppelt ausloesen).
# 5xx/Timeout = Ergebnis unbekannt -> Fehlermeldung 'unbekannt', in Intune pruefen.
function Invoke-APEinmal([string]$Token, [string]$Endpoint, [hashtable]$Body) {
    $r = Invoke-GraphRequest -Token $Token -Endpoint (ConvertTo-APUrl $Endpoint 'v1.0') -Method POST -Body $Body
    if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
        $c = "$($r.StatusCode)"
        if ($c -eq '403') { throw "Recht fehlt (403) fuer POST $($Endpoint -replace '\?.*$', '')" }
        if ($c -match '^5' -or -not $c -or $c -eq '0') { throw "Ergebnis unbekannt ($c) - bitte in Intune pruefen, bevor erneut gesendet wird" }
        throw "$c $($r.ErrorMessage)"
    }
    return $r
}
function Invoke-APWrite([string]$Token, [string]$Endpoint, [string]$Method, [hashtable]$Body) {
    $r = Invoke-GraphRequestWithRetry -Token $Token -Endpoint (ConvertTo-APUrl $Endpoint 'v1.0') -Method $Method -Body $Body
    if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
        if ("$($r.StatusCode)" -eq '403') { throw "Recht fehlt (403) fuer $Method $($Endpoint -replace '\?.*$', '' -replace '^https://graph\.microsoft\.com/(v1\.0|beta)', '')" }
        throw "$($r.StatusCode) $($r.ErrorMessage)"
    }
    return $r
}
# Wartung jetzt auf einzelnen Geraeten ausfuehren (Intune-IDs). Rueckgabe je Geraet: Id, Ok, Fehler
function Start-APHashWartung([string]$TenantKey, $Settings, [string[]]$IntuneIds) {
    $tok = Get-APToken $TenantKey $Settings
    $pid0 = Initialize-APHashPaket $tok $TenantKey
    $n = 0
    foreach ($id in @($IntuneIds | Where-Object { $_ })) {
        $n++
        $ok = $true; $f = ''
        try { [void](Invoke-APWrite $tok "$script:APBeta/managedDevices/$id/initiateOnDemandProactiveRemediation" 'POST' @{ scriptPolicyId = $pid0 }) } catch { $ok = $false; $f = "$($_.Exception.Message)" }
        Write-HULog -Message "$n von $(@($IntuneIds).Count): $(if ($ok) { 'Wartung angestossen' } else { "Fehler: $f" })" -Level $(if ($ok) { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
        [pscustomobject]@{ APStart = $true; Id = $id; Ok = $ok; Fehler = $f }
        Start-Sleep -Milliseconds 300
    }
}
# Eine Ausgabezeile zerlegen. Rueckgabe: Seriennummer, Hash, Fehler
function ConvertFrom-APHashAusgabe([string]$Text) {
    $o = "$Text".Trim()
    $p = $o -split '\|'
    if ($p.Count -lt 3 -or $p[0] -ne 'HUAP') { return [pscustomobject]@{ Seriennummer = ''; Hash = ''; Fehler = $(if ($o) { 'unbekannte Ausgabe' } else { 'keine Ausgabe' }) } }
    if ($p[2] -eq 'FEHLER') { return [pscustomobject]@{ Seriennummer = ''; Hash = ''; Fehler = "Geraet: $(($p | Select-Object -Skip 3) -join '|')" } }
    if ($p.Count -lt 5) { return [pscustomobject]@{ Seriennummer = $p[2]; Hash = ''; Fehler = 'Ausgabe unvollstaendig' } }
    try {
        $in = New-Object IO.Compression.DeflateStream((New-Object IO.MemoryStream(, [Convert]::FromBase64String($p[4]))), [IO.Compression.CompressionMode]::Decompress)
        $out = New-Object IO.MemoryStream; $in.CopyTo($out); $in.Dispose()
        $h = [Convert]::ToBase64String($out.ToArray())
    } catch { return [pscustomobject]@{ Seriennummer = $p[2]; Hash = ''; Fehler = 'Entpacken fehlgeschlagen' } }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $s12 = (-join ($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($h)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 12) } finally { $sha.Dispose() }
    if ($s12 -ne $p[3]) { return [pscustomobject]@{ Seriennummer = $p[2]; Hash = ''; Fehler = 'Pruefsumme falsch' } }
    return [pscustomobject]@{ Seriennummer = $p[2]; Hash = $h; Fehler = '' }
}
# Alle Ausgaben des Pakets abholen. Rueckgabe je Geraet: APHash, Seriennummer, Hash, Gelesen, Geraet, Fehler
function Get-APHashAusgaben([string]$TenantKey, $Settings) {
    $tok = Get-APToken $TenantKey $Settings
    $p = Get-APHashPaket $tok
    if (-not $p) { Write-HULog -Message "Wartungspaket $script:APHashPaketName gibt es noch nicht - zuerst Wartung starten" -Level 'WARN' -Tenant $TenantKey; return }
    $st = @(Get-APAll $tok "$script:APBeta/deviceHealthScripts/$($p.id)/deviceRunStates?`$expand=managedDevice(`$select=deviceName,serialNumber)")
    $ok = 0
    foreach ($s in $st) {
        $r = ConvertFrom-APHashAusgabe "$($s.preRemediationDetectionScriptOutput)"
        if (-not $r.Fehler) { $ok++ }
        [pscustomobject]@{
            APHash       = $true
            Seriennummer = $(if ($r.Seriennummer) { $r.Seriennummer } else { "$($s.managedDevice.serialNumber)" })
            Hash         = $r.Hash
            Gelesen      = (ConvertTo-APZeit $s.lastStateUpdateDateTime)
            Geraet       = "$($s.managedDevice.deviceName)"
            Fehler       = $r.Fehler
        }
    }
    Write-HULog -Message "$($st.Count) Ergebnis(se) der Wartung, $ok mit gueltigem Hash" -Level $(if ($ok -eq $st.Count) { 'OK' } else { 'WARN' }) -Tenant $TenantKey
}

# Nur die Seriennummern der Autopilot-Geraete (schnell, fuer die Tenant-Pruefung beim Einlesen)
function Get-APSeriennummern([string]$TenantKey, $Settings) {
    $tok = Get-APToken $TenantKey $Settings
    # ohne $select: v1.0 mit $select=serialNumber liefert in einem Tenant 500 (Test 26.10.) - gleiche Abfrage wie die Uebersicht
    $ap = @(Get-APAll $tok '/deviceManagement/windowsAutopilotDeviceIdentities' 'beta')
    [pscustomobject]@{ APSerien = $true; Tenant = $TenantKey; Serien = [string[]]@($ap | ForEach-Object { "$($_.serialNumber)" }) }
}


# ---------------------------------------------------------------------------------------------
# Stufe 3 - Aufnehmen (Konzept Teil 3): Tags/Gruppen/Profile lesen, Gruppe anlegen, Import, Sync, Nachverfolgung
# Quellen: https://learn.microsoft.com/graph/api/intune-enrollment-importedwindowsautopilotdeviceidentity-import
#          https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotsettings-sync?view=graph-rest-beta
#          https://learn.microsoft.com/autopilot/add-devices#troubleshooting-registration-failures
#          https://learn.microsoft.com/entra/identity/users/groups-dynamic-membership (OrderID = Group Tag)
# ---------------------------------------------------------------------------------------------
$script:APRechteAufnehmen = @('DeviceManagementServiceConfig.ReadWrite.All', 'Group.Read.All', 'Group.Create', 'Device.Read.All')

# Group Tag: nur Buchstaben, Ziffern, - und _ (dann braucht die Gruppenregel kein Escaping)
function Test-APTagText([string]$Tag) { return ("$Tag" -match '^[A-Za-z0-9_-]{1,100}$') }
function New-APGruppenRegel([string]$Tag) { return "(device.devicePhysicalIds -any (_ -eq `"[OrderID]:$Tag`"))" }
function ConvertTo-APMailNick([string]$Name) {
    $n = ("$Name" -replace '[^A-Za-z0-9_.-]', '')
    if (-not $n) { $n = 'AP-Gruppe' }
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60) }
    return $n
}
# Regel einer dynamischen Gruppe: alle [OrderID]-Vergleiche + ob die Regel mehr enthaelt (dann nicht raten)
function Get-APRegelTerme([string]$Regel) {
    $terme = @(foreach ($m in [regex]::Matches("$Regel", '(?i)-(eq|ne|startsWith|notStartsWith|contains|notContains|match|notMatch)\s*"\[OrderID\]:([^"]*)"')) {
            [pscustomobject]@{ Op = $m.Groups[1].Value.ToLowerInvariant(); Wert = $m.Groups[2].Value }
        })
    # 065 B5: Listen  -in ["[OrderID]:A","[OrderID]:B"]  bzw. -notIn [...]
    foreach ($m in [regex]::Matches("$Regel", '(?i)-(in|notIn)\s*\[((?:\s*"[^"]*"\s*,?)*)\]')) {
        $op = $(if ($m.Groups[1].Value -match '(?i)^not') { 'ne' } else { 'eq' })
        foreach ($w in [regex]::Matches($m.Groups[2].Value, '(?i)"\[OrderID\]:([^"]*)"')) { $terme += [pscustomobject]@{ Op = $op; Wert = $w.Groups[1].Value } }
    }
    # eine reine -in-Liste mit genauen Werten gilt wie -eq (nicht zusammengesetzt)
    $nurListe = ($terme.Count -gt 1 -and "$Regel" -match '(?i)-in\s*\[' -and -not [regex]::IsMatch("$Regel", '(?i)-(eq|ne|startsWith|notStartsWith|contains|notContains|match|notMatch|notIn)\s*"'))
    $komplex = ($terme.Count -ne 1 -and -not $nurListe) -or ("$Regel" -match '(?i)\s-(and|or|not)\s') -or ([regex]::Matches("$Regel", '(?i)device\.').Count -gt 1)
    # OrderID kommt vor, aber nichts auswertbar -> nicht weglassen, sondern als unsicher zeigen
    $unklar = ("$Regel" -match '(?i)OrderID' -and -not $terme.Count)
    return [pscustomobject]@{ Terme = $terme; Komplex = [bool]$komplex; Unklar = [bool]$unklar }
}
# Welche dynamischen Gruppen treffen den Tag? Art: sicher (-eq), unsicher (zusammengesetzte Regel), mehrere (-startsWith/-contains)
function Find-APTagGruppen([string]$Tag, [object[]]$Gruppen) {
    $t = "$Tag".ToUpperInvariant()
    foreach ($g in @($Gruppen)) {
        if (-not $g) { continue }
        $info = Get-APRegelTerme "$($g.Regel)"
        $art = ''
        foreach ($x in $info.Terme) {
            $w = "$($x.Wert)".ToUpperInvariant()
            switch ($x.Op) {
                'eq' { if ($w -eq $t) { $art = $(if ($info.Komplex) { 'unsicher' } else { 'sicher' }) } }
                'startswith' { if ($t.StartsWith($w) -and -not $art) { $art = 'mehrere' } }
                'contains' { if ($t.Contains($w) -and -not $art) { $art = 'mehrere' } }
                'match' { if (-not $art) { try { if ($t -match $x.Wert) { $art = 'unsicher' } } catch { } } }
                'ne' { if (-not $art -and $w -ne $t) { $art = 'unsicher' } }
            }
        }
        if (-not $art -and $info.Unklar) { $art = 'unsicher' }
        if ($art) {
            [pscustomobject]@{ Id = "$($g.Id)"; Name = "$($g.Name)"; Art = $art; Regel = "$($g.Regel)"; Profile = @($g.Profile); Aktiv = "$($g.Verarbeitung)"; VonApp = [bool]($g.PSObject.Properties['VonApp'] -and $g.VonApp) }
        }
    }
}
# Fehlertexte beim Import (Learn: Troubleshooting registration failures, Fehler 806/808)
function Get-APImportFehlerText([string]$Name, $Code) {
    $n = "$Name"
    if ($n -match 'AssignedTo(Other|Another)Tenant' -or "$Code" -eq '808') { return 'in einem anderen Tenant registriert - Vorbesitzer bzw. Lieferant muss das Geraet freigeben (Fehler 808)' }
    if ($n -match 'AlreadyAssigned' -or "$Code" -eq '806') { return 'schon in diesem Tenant registriert (Fehler 806) - nicht erneut importieren' }
    if ($n -match 'Duplicated') { return 'doppelt im selben Import - nur ein Eintrag wird verarbeitet' }
    if ($n -match 'InvalidZtdHardwareHash') { return 'Hash ungueltig (Hersteller oder Seriennummer fehlen im Hash)' }
    if ($n -match 'StorageError') { return 'Fehler bei Microsoft (StorageError) - spaeter erneut versuchen' }
    if ($n -or "$Code") { return "$n $(if ("$Code") { "($Code)" })".Trim() }
    return 'unbekannter Fehler'
}

# Tags, dynamische Gruppen und Profile eines Tenants (nur lesen)
function Get-APAufInfo([string]$TenantKey, $Settings) {
    $tok = Get-APToken $TenantKey $Settings
    $ap = @(Get-APAll $tok '/deviceManagement/windowsAutopilotDeviceIdentities' 'beta')
    $serien = @{}; $tags = @{}
    foreach ($a in $ap) {
        $k = ConvertTo-APSerial "$($a.serialNumber)"; if (-not $k) { continue }
        $tg = "$($a.groupTag)"
        $serien[$k] = $tg
        $u = $tg.ToUpperInvariant()
        if (-not $tags.ContainsKey($u)) { $tags[$u] = [pscustomobject]@{ Tag = $tg; Anzahl = 0; Schreibweisen = @{} } }
        $tags[$u].Anzahl++; $tags[$u].Schreibweisen[$tg] = 1
    }
    Write-HULog -Message "$($ap.Count) Autopilot-Geraete, $(@($tags.Keys | Where-Object { $_ }).Count) Group Tags" -Level 'INFO' -Tenant $TenantKey
    # 065 B4: liegengebliebene Import-Eintraege (verarbeitet: complete/error) aufraeumen, offene nur melden
    try {
        $imp = @(Get-APAll $tok '/deviceManagement/importedWindowsAutopilotDeviceIdentities')
        $fertig = @($imp | Where-Object { "$($_.state.deviceImportStatus)" -in 'complete', 'error' })
        $weg = 0
        foreach ($x in $fertig) { $r = Invoke-GraphRequest -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($x.id)" -Method DELETE; if (-not ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError)) { $weg++ } }
        if ($imp.Count) { Write-HULog -Message "Import-Eintraege: $weg verarbeitete aufgeraeumt, $($imp.Count - $fertig.Count) noch in Arbeit" -Level 'INFO' -Tenant $TenantKey }
    } catch { Write-HULog -Message "Import-Eintraege nicht lesbar: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
    $gr = @(Get-APAll $tok "/groups?`$filter=groupTypes/any(c:c%20eq%20'DynamicMembership')&`$select=id,displayName,description,membershipRule,membershipRuleProcessingState&`$top=999")
    $gr = @($gr | Where-Object { "$($_.membershipRule)" -match '(?i)OrderID' })
    # Profile und ihre Zuweisungen (beta)
    $prof = @{}
    try {
        foreach ($p in @(Get-APAll $tok "$script:APBeta/windowsAutopilotDeploymentProfiles?`$expand=assignments")) {
            foreach ($as in @($p.assignments)) {
                $tg = $as.target; if (-not $tg) { continue }
                $gid = "$($tg.groupId)"; if (-not $gid) { continue }
                $aus = ("$($tg.'@odata.type')" -match 'exclusion')
                if (-not $prof.ContainsKey($gid)) { $prof[$gid] = @() }
                $prof[$gid] += "$($p.displayName)$(if ($aus) { ' (ausgeschlossen)' })"
            }
        }
    } catch { Write-HULog -Message "Profile nicht lesbar: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
    $gruppen = @(foreach ($g in $gr) {
            [pscustomobject]@{ Id = "$($g.id)"; Name = "$($g.displayName)"; Regel = "$($g.membershipRule)"; Verarbeitung = "$($g.membershipRuleProcessingState)"; VonApp = ("$($g.description)" -match 'angelegt von HU-MultiTenant'); Profile = @($(if ($prof.ContainsKey("$($g.id)")) { $prof["$($g.id)"] })) }
        })
    Write-HULog -Message "$($gruppen.Count) dynamische Gruppe(n) mit Group-Tag-Regel" -Level 'OK' -Tenant $TenantKey
    [pscustomobject]@{
        APAufInfo = $true; Tenant = $TenantKey; Serien = $serien
        Tags      = @($tags.Values | Where-Object { "$($_.Tag)" } | ForEach-Object { [pscustomobject]@{ Tag = $_.Tag; Anzahl = $_.Anzahl; Schreibweisen = @($_.Schreibweisen.Keys) } } | Sort-Object Tag)
        Gruppen   = $gruppen
    }
}

# Dynamische Sicherheitsgruppe fuer einen Tag anlegen (Regel immer -eq)
function New-APAufGruppe([string]$TenantKey, $Settings, [string]$Name, [string]$Tag) {
    if (-not (Test-APTagText $Tag)) { throw "Group Tag '$Tag' enthaelt unerlaubte Zeichen" }
    $tok = Get-APToken $TenantKey $Settings
    $regel = New-APGruppenRegel $Tag
    $body = @{
        displayName                   = $Name
        description                   = "Autopilot-Geraete mit Group Tag $Tag (angelegt von HU-MultiTenant)"
        mailEnabled                   = $false
        mailNickname                  = (ConvertTo-APMailNick $Name)
        securityEnabled               = $true
        groupTypes                    = @('DynamicMembership')
        membershipRule                = $regel
        membershipRuleProcessingState = 'On'
    }
    $r = Invoke-APWrite $tok '/groups' 'POST' $body
    Write-HULog -Message "Gruppe '$Name' angelegt (dynamisch, $regel)" -Level 'OK' -Tenant $TenantKey
    [pscustomobject]@{ APGruppeNeu = $true; Tenant = $TenantKey; Id = "$($r.id)"; Name = $Name; Regel = $regel; Tag = $Tag }
}
# Nur eine von der App angelegte Gruppe loeschen (Beschreibung wird geprueft). Testpunkt T9: geht das mit Group.Create?
function Remove-APAufGruppe([string]$TenantKey, $Settings, [string]$Id) {
    $tok = Get-APToken $TenantKey $Settings
    $g = Invoke-APGet $tok "/groups/$Id`?`$select=id,displayName,description"
    if ("$($g.description)" -notmatch 'angelegt von HU-MultiTenant') { throw "Gruppe '$($g.displayName)' wurde nicht von HU-MultiTenant angelegt - wird nicht geloescht" }
    $r = Invoke-GraphRequestWithRetry -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/groups/$Id" -Method DELETE
    $ok = -not ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError)
    $txt = if ($ok) { "Gruppe '$($g.displayName)' geloescht (30 Tage wiederherstellbar)" }
    elseif ("$($r.StatusCode)" -eq '403') { "Loeschen nicht erlaubt (403) - dafuer braucht die App Group.ReadWrite.All. Gruppe bitte im Entra-Portal loeschen." }
    else { "Loeschen fehlgeschlagen: $($r.StatusCode) $($r.ErrorMessage)" }
    Write-HULog -Message $txt -Level $(if ($ok) { 'OK' } else { 'WARN' }) -Tenant $TenantKey
    [pscustomobject]@{ APGruppeWeg = $true; Tenant = $TenantKey; Id = $Id; Ok = $ok; Text = $txt; Status = "$(if (-not $ok) { $r.StatusCode })" }
}

# Import: Geraete = Objekte mit Seriennummer, Hash, ProductId. Pakete zu 100, Status pollen, danach ALLE Import-Eintraege
# entfernen, dann einmal Autopilot-Sync (gedrosselt: 409 laeuft schon, 429 innerhalb 10 Minuten).
function Start-APAufImport([string]$TenantKey, $Settings, [object[]]$Geraete, [string]$Tag, [int]$MaxMinuten = 15) {
    if ($Tag -and -not (Test-APTagText $Tag)) { throw "Group Tag '$Tag' enthaelt unerlaubte Zeichen" }
    $tok = Get-APToken $TenantKey $Settings
    $liste = @($Geraete | Where-Object { $_ -and "$($_.Hash)" })
    $offen = @{}   # importId -> Seriennummer
    for ($i = 0; $i -lt $liste.Count; $i += 100) {
        $teil = @($liste[$i..([Math]::Min($i + 99, $liste.Count - 1))])
        $items = @(foreach ($g in $teil) {
                $o = @{ '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'; serialNumber = "$($g.Seriennummer)"; hardwareIdentifier = "$($g.Hash)" }
                if ($Tag) { $o.groupTag = $Tag }
                if ("$($g.ProductId)") { $o.productKey = "$($g.ProductId)" }
                $o
            })
        $r = Invoke-APEinmal $tok '/deviceManagement/importedWindowsAutopilotDeviceIdentities/import' @{ importedWindowsAutopilotDeviceIdentities = $items }
        foreach ($v in @($r.value)) { if ($v -and "$($v.id)") { $offen["$($v.id)"] = "$($v.serialNumber)" } }
        Write-HULog -Message "Import gesendet: $([Math]::Min($i + 100, $liste.Count)) von $($liste.Count)" -Level 'INFO' -Tenant $TenantKey
    }
    $alle = @($offen.Keys)
    $fertig = @{}
    $bis = (Get-Date).AddMinutes($MaxMinuten)
    while ($fertig.Count -lt $alle.Count -and (Get-Date) -lt $bis) {
        Start-Sleep -Seconds 15
        foreach ($id in $alle) {
            if ($fertig.ContainsKey($id)) { continue }
            try { $x = Invoke-APGet $tok "/deviceManagement/importedWindowsAutopilotDeviceIdentities/$id" } catch { continue }
            $st = "$($x.state.deviceImportStatus)"
            if ($st -eq 'complete' -or $st -eq 'error') { $fertig[$id] = $x }
        }
        Write-HULog -Message "Import: $($fertig.Count) von $($alle.Count) verarbeitet" -Level 'INFO' -Tenant $TenantKey
    }
    foreach ($id in $alle) {
        $x = if ($fertig.ContainsKey($id)) { $fertig[$id] } else { $null }
        $st = if ($x) { "$($x.state.deviceImportStatus)" } else { 'pending' }
        [pscustomobject]@{
            APAufErg     = $true; Tenant = $TenantKey; Seriennummer = $offen[$id]; Status = $st
            Fehler       = $(if ($st -eq 'error') { Get-APImportFehlerText "$($x.state.deviceErrorName)" $x.state.deviceErrorCode } elseif ($st -ne 'complete') { "nach $MaxMinuten Minuten noch nicht verarbeitet" } else { '' })
            Zeit         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    # aufraeumen: verarbeitete Import-Eintraege entfernen (noch offene bleiben, sonst bricht der Import ab)
    $weg = 0
    foreach ($id in @($fertig.Keys)) {
        $r = Invoke-GraphRequestWithRetry -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$id" -Method DELETE
        if (-not ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError)) { $weg++ }
    }
    Write-HULog -Message "$weg Import-Eintrag/-Eintraege entfernt$(if ($alle.Count -gt $fertig.Count) { ", $($alle.Count - $fertig.Count) noch offen (bleiben stehen)" })" -Level 'INFO' -Tenant $TenantKey
    # Sync einmal - ohne Wiederholung (429 wuerde sonst bis zu 10 Minuten warten)
    $s = Invoke-GraphRequest -Token $tok -Endpoint "$script:APBeta/windowsAutopilotSettings/sync" -Method POST
    $sc = if ($s -and $s.PSObject.Properties['IsError'] -and $s.IsError) { "$($s.StatusCode)" } else { '204' }
    $stxt = switch ($sc) { '204' { 'Autopilot-Sync gestartet' } '409' { 'Autopilot-Sync laeuft schon' } '429' { 'Autopilot-Sync lief vor weniger als 10 Minuten - kein neuer' } default { "Autopilot-Sync: Fehler $sc" } }
    Write-HULog -Message $stxt -Level $(if ($sc -in '204', '409', '429') { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
    [pscustomobject]@{ APAufSync = $true; Tenant = $TenantKey; Code = $sc; Text = $stxt }
}

# Nachverfolgung: Autopilot-Eintrag, Tag, Profilstatus und (optional) Mitgliedschaft in der Gruppe
function Get-APAufStatus([string]$TenantKey, $Settings, [string[]]$Serien, [string]$GruppeId) {
    $tok = Get-APToken $TenantKey $Settings
    $ap = @{}
    foreach ($a in @(Get-APAll $tok '/deviceManagement/windowsAutopilotDeviceIdentities' 'beta')) { $ap[(ConvertTo-APSerial "$($a.serialNumber)")] = $a }
    $mit = $null
    if ($GruppeId) {
        try {
            $mit = @{}
            foreach ($m in @(Get-APAll $tok "/groups/$GruppeId/members/microsoft.graph.device?`$select=id,deviceId")) { $mit["$($m.deviceId)".ToLowerInvariant()] = 1 }
        } catch { $mit = $null; Write-HULog -Message "Gruppenmitglieder nicht lesbar: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey }
    }
    foreach ($s in @($Serien)) {
        $a = $ap[(ConvertTo-APSerial $s)]
        $prof = if ($a -and $a.PSObject.Properties['deploymentProfileAssignmentStatus']) { "$($a.deploymentProfileAssignmentStatus)" } else { '' }
        $aad = if ($a) { "$($a.azureActiveDirectoryDeviceId)".ToLowerInvariant() } else { '' }
        [pscustomobject]@{
            APAufStat    = $true; Tenant = $TenantKey; Seriennummer = $s
            InAutopilot  = [bool]$a
            GroupTag     = $(if ($a) { "$($a.groupTag)" } else { '' })
            ProfilRoh    = $prof
            Profil       = $(if ($prof -and $script:APProfilText.ContainsKey($prof)) { $script:APProfilText[$prof] } else { $prof })
            InGruppe     = $(if ($null -eq $mit -or -not $a) { $null } elseif ($aad -and -not (Test-APLeereId $aad) -and $mit.ContainsKey($aad)) { $true } else { $false })
        }
    }
}


# Tag aendern (Konzept 3.6): updateDeviceProperties NUR mit groupTag im Body (leere Felder koennen Benutzer/Anzeigename leeren)
# Quelle: https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-updatedeviceproperties
function Set-APGroupTag([string]$TenantKey, $Settings, [object[]]$Geraete, [string]$Tag) {
    if (-not (Test-APTagText $Tag)) { throw "Group Tag '$Tag' enthaelt unerlaubte Zeichen" }
    $tok = Get-APToken $TenantKey $Settings
    $n = 0
    foreach ($g in @($Geraete | Where-Object { $_ -and "$($_.AutopilotId)" })) {
        $n++
        $ok = $true; $f = ''
        try { [void](Invoke-APWrite $tok "/deviceManagement/windowsAutopilotDeviceIdentities/$($g.AutopilotId)/updateDeviceProperties" 'POST' @{ groupTag = $Tag }) } catch { $ok = $false; $f = "$($_.Exception.Message)" }
        Write-HULog -Message "$n von $(@($Geraete).Count): $($g.Seriennummer) $(if ("$($g.Alt)") { $g.Alt } else { '(ohne)' }) -> $Tag$(if (-not $ok) { " - Fehler: $f" })" -Level $(if ($ok) { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
        [pscustomobject]@{ APTagErg = $true; Tenant = $TenantKey; Seriennummer = "$($g.Seriennummer)"; AutopilotId = "$($g.AutopilotId)"; Alt = "$($g.Alt)"; Neu = $Tag; Ok = $ok; Fehler = $f }
        Start-Sleep -Milliseconds 200
    }
}


# ---------------------------------------------------------------------------------------------
# Stufe 5 - Ausscheiden (Konzept Teil 4): Reihenfolge 4.4 - Benutzer im Autopilot-Eintrag aufheben -> Autopilot-Eintrag
# entfernen -> nachlesen, bis er weg ist (sonst KEIN Wipe) -> Wipe -> nach bestaetigtem Wipe Intune-Eintrag loeschen.
# Quellen: https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-unassignuserfromdevice
#          https://learn.microsoft.com/graph/api/intune-enrollment-windowsautopilotdeviceidentity-delete
#          https://learn.microsoft.com/graph/api/intune-devices-manageddevice-wipe (v1.0: keepEnrollmentData, keepUserData)
#          https://learn.microsoft.com/graph/api/resources/intune-devices-deviceactionresult (actionState)
# ---------------------------------------------------------------------------------------------
$script:APRechteAusscheiden = @('DeviceManagementServiceConfig.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementManagedDevices.ReadWrite.All')
# nur fuer Zurueckziehen: Wiederherstellungsschluessel lesen (jeder Abruf steht im Entra-Ueberwachungsprotokoll)
$script:APRechteZurueck = @('BitlockerKey.Read.All')

# Vorab-Pruefung je Geraet (4.2) - reine Funktion auf einer Zeile der Uebersicht. Rueckgabe: Ampel (gut/warn/fehler) + Text
function Get-APAusPruefung($Row, [bool]$HashDa, [int]$SyncTage = 30) {
    $t = @(); $amp = 'gut'
    if ("$($Row.InIntune)" -ne 'ja') { $t += 'nicht in Intune - kein Wipe moeglich (nur Autopilot-Eintrag entfernen)'; $amp = 'warn' }
    if ("$($Row.Eigentum)" -eq 'privat') { $t += 'privates Geraet - nicht ausscheiden (nur Zurueckziehen, folgt)'; $amp = 'fehler' }
    if ("$($Row.LetzterSyncRoh)") {
        $o = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse("$($Row.LetzterSyncRoh)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$o)) {
            $tage = [int]([datetimeoffset]::UtcNow - $o).TotalDays
            if ($tage -gt $SyncTage) { $t += "letzte Synchronisierung vor $tage Tagen - der Wipe kommt erst an, wenn sich das Geraet meldet"; if ($amp -eq 'gut') { $amp = 'warn' } }
        }
    }
    if ("$($Row.Verwaltung)" -match 'wipe|retire') { $t += "Intune-Status: $($Row.Verwaltung)"; if ($amp -eq 'gut') { $amp = 'warn' } }
    # fehlender Hash nur als Text (betrifft anfangs fast alle Geraete - sonst ist die ganze Liste gelb)
    if (-not $HashDa) { $t += 'kein Hash im Archiv (vorher Hash anfordern)' }
    if (-not "$($Row.Benutzer)") { $t += 'kein Primaerbenutzer (Raum-/Leihgeraet?)'; if ($amp -eq 'gut') { $amp = 'warn' } }
    return [pscustomobject]@{ Ampel = $amp; Text = ($t -join '; ') }
}

# Ausscheiden ausfuehren. Geraete: Seriennummer, AutopilotId, IntuneId, ApBenutzer. MaxWarte = Minuten, bis der Autopilot-Eintrag weg sein muss.
# Seriennummern, die gerade in Autopilot stehen (Liste - der Abruf einzelner Eintraege per ID liefert nach dem Loeschen
# noch lange das Objekt, Test 26.10.: Liste nach ca. 5 Min. leer, Einzelabruf nach 8 Min. noch da)
function Get-APApSet([string]$Token) {
    $h = @{}
    foreach ($a in @(Get-APAll $Token '/deviceManagement/windowsAutopilotDeviceIdentities' 'beta')) { $h[(ConvertTo-APSerial "$($a.serialNumber)")] = "$($a.id)" }
    return $h
}
# Ausscheiden ausfuehren. Geraete: Seriennummer, AutopilotId, IntuneId, ApBenutzer. MaxWarte = Minuten, bis der Autopilot-Eintrag weg sein muss.
function Start-APAusscheiden([string]$TenantKey, $Settings, [object[]]$Geraete, [int]$MaxWarte = 15) {
    $tok = Get-APToken $TenantKey $Settings
    $liste = @($Geraete | Where-Object { $_ })
    $stand = @{}
    foreach ($g in $liste) { $stand["$($g.Seriennummer)"] = [pscustomobject]@{ Benutzer = ''; Ap = ''; Wipe = ''; Fehler = @() } }
    $set = Get-APApSet $tok
    # 1.+2. Benutzer aufheben, Autopilot-Eintrag entfernen (nur wenn er laut Liste noch da ist)
    foreach ($g in $liste) {
        $x = $stand["$($g.Seriennummer)"]
        $k = ConvertTo-APSerial "$($g.Seriennummer)"
        if (-not $set.ContainsKey($k)) { $x.Ap = 'keiner'; Write-HULog -Message "$($g.Seriennummer): kein Autopilot-Eintrag (mehr)" -Level 'INFO' -Tenant $TenantKey; continue }
        $apId = "$($set[$k])"
        if ("$($g.ApBenutzer)") {
            try { [void](Invoke-APWrite $tok "/deviceManagement/windowsAutopilotDeviceIdentities/$apId/unassignUserFromDevice" 'POST' @{}); $x.Benutzer = 'aufgehoben' }
            catch { $x.Benutzer = 'Fehler'; $x.Fehler += "Benutzer aufheben: $($_.Exception.Message)" }
        }
        $r = Invoke-GraphRequestWithRetry -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$apId" -Method DELETE
        if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) { $x.Ap = 'Fehler'; $x.Fehler += "Autopilot entfernen: $($r.StatusCode) $($r.ErrorMessage)" } else { $x.Ap = 'entfernt' }
        Write-HULog -Message "$($g.Seriennummer): Autopilot-Eintrag $(if ($x.Ap -eq 'entfernt') { 'zum Entfernen gesendet' } else { 'NICHT entfernt' })" -Level $(if ($x.Ap -eq 'entfernt') { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
    }
    # 3. Liste nachlesen, bis alle entfernten Eintraege weg sind
    $offen = @($liste | Where-Object { $stand["$($_.Seriennummer)"].Ap -eq 'entfernt' })
    $bis = (Get-Date).AddMinutes($MaxWarte)
    while ($offen.Count -and (Get-Date) -lt $bis) {
        Start-Sleep -Seconds 30
        try { $set = Get-APApSet $tok } catch { Write-HULog -Message "Autopilot-Liste: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey; continue }
        $noch = @()
        foreach ($g in $offen) { if ($set.ContainsKey((ConvertTo-APSerial "$($g.Seriennummer)"))) { $noch += $g } else { $stand["$($g.Seriennummer)"].Ap = 'weg' } }
        $offen = $noch
        Write-HULog -Message "Autopilot: $(@($liste).Count - $offen.Count) von $(@($liste).Count) weg$(if ($offen.Count) { ' - warte ...' })" -Level 'INFO' -Tenant $TenantKey
    }
    # 4. Wipe nur, wenn der Autopilot-Eintrag sicher weg ist (oder es keinen gab)
    foreach ($g in $liste) {
        $x = $stand["$($g.Seriennummer)"]
        if ($x.Ap -notin 'weg', 'keiner') { $x.Wipe = 'nicht gesendet'; if ($x.Ap -eq 'entfernt') { $x.Fehler += "Autopilot-Eintrag nach $MaxWarte Minuten noch da - kein Wipe ('Erneut versuchen' spaeter)" }; continue }
        if (-not "$($g.IntuneId)") { $x.Wipe = 'kein Intune-Eintrag'; continue }
        try { [void](Invoke-APEinmal $tok "/deviceManagement/managedDevices/$($g.IntuneId)/wipe" @{ keepEnrollmentData = $false; keepUserData = $false }); $x.Wipe = 'gesendet' }
        catch { $m = "$($_.Exception.Message)"; $x.Wipe = $(if ($m -match 'unbekannt') { 'unbekannt' } else { 'Fehler' }); $x.Fehler += "Wipe: $m" }
        Write-HULog -Message "$($g.Seriennummer): Wipe $($x.Wipe)" -Level $(if ($x.Wipe -eq 'gesendet') { 'OK' } else { 'WARN' }) -Tenant $TenantKey
    }
    foreach ($g in $liste) {
        $x = $stand["$($g.Seriennummer)"]
        [pscustomobject]@{ APAusErg = $true; Tenant = $TenantKey; Seriennummer = "$($g.Seriennummer)"; Benutzer = $x.Benutzer; Autopilot = $x.Ap; Wipe = $x.Wipe; Fehler = ($x.Fehler -join '; '); Zeit = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    }
}
# Nachverfolgung: Intune-Status und Wipe-Aktion je Geraet (404 = Intune-Eintrag weg)
function Get-APAusStatus([string]$TenantKey, $Settings, [string[]]$IntuneIds) {
    $tok = Get-APToken $TenantKey $Settings
    foreach ($id in @($IntuneIds | Where-Object { $_ })) {
        $r = Invoke-GraphRequest -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$id`?`$select=id,deviceName,managementState,lastSyncDateTime,deviceActionResults"
        if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) {
            [pscustomobject]@{ APAusStat = $true; IntuneId = $id; Da = $false; Status = $(if ("$($r.StatusCode)" -eq '404') { 'Intune-Eintrag weg' } else { "Fehler $($r.StatusCode)" }); Wipe = ''; WipeZeit = ''; LetzterSync = '' }
            continue
        }
        $w = @(@($r.deviceActionResults) | Where-Object { "$($_.actionName)" -match '(?i)wipe|retire' } | Sort-Object { "$($_.lastUpdatedDateTime)" } -Descending)
        [pscustomobject]@{
            APAusStat = $true; IntuneId = $id; Da = $true; Status = "$($r.managementState)"
            Wipe = $(if ($w.Count) { "$($w[0].actionState)" } else { '' }); WipeZeit = $(if ($w.Count) { ConvertTo-APZeit $w[0].lastUpdatedDateTime } else { '' })
            LetzterSync = (ConvertTo-APZeit $r.lastSyncDateTime)
        }
    }
}
function Remove-APIntuneGeraete([string]$TenantKey, $Settings, [string[]]$IntuneIds) {
    $tok = Get-APToken $TenantKey $Settings
    foreach ($id in @($IntuneIds | Where-Object { $_ })) {
        $r = Invoke-GraphRequestWithRetry -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$id" -Method DELETE
        $ok = -not ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError)
        Write-HULog -Message "Intune-Eintrag $id $(if ($ok) { 'geloescht' } else { "NICHT geloescht: $($r.StatusCode) $($r.ErrorMessage)" })" -Level $(if ($ok) { 'OK' } else { 'WARN' }) -Tenant $TenantKey
        [pscustomobject]@{ APIntuneWeg = $true; IntuneId = $id; Ok = $ok; Fehler = $(if (-not $ok) { "$($r.StatusCode) $($r.ErrorMessage)" } else { '' }) }
    }
}

# Sync nachschieben (zweites Signal ueber WNS, falls das erste verloren ging) - hilft nicht bei ausgeschalteten Geraeten
# Quelle: https://learn.microsoft.com/graph/api/intune-devices-manageddevice-syncdevice (PrivilegedOperations.All)
function Send-APSync([string]$TenantKey, $Settings, [string[]]$IntuneIds) {
    $tok = Get-APToken $TenantKey $Settings
    foreach ($id in @($IntuneIds | Where-Object { $_ })) {
        $ok = $true; $f = ''
        try { [void](Invoke-APWrite $tok "/deviceManagement/managedDevices/$id/syncDevice" 'POST' @{}) } catch { $ok = $false; $f = "$($_.Exception.Message)" }
        Write-HULog -Message "Sync an $id $(if ($ok) { 'gesendet' } else { "fehlgeschlagen: $f" })" -Level $(if ($ok) { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
        [pscustomobject]@{ APSyncErg = $true; IntuneId = $id; Ok = $ok; Fehler = $f }
    }
}


# ---------------------------------------------------------------------------------------------
# Zurueckziehen (Konzept 4.3): Geraet bleibt bei der Familie, behaelt seine Daten und verlaesst die Verwaltung.
# Reihenfolge: BitLocker-Schluessel lesen (VOR dem Retire - er haengt am Entra-Objekt) -> Autopilot-Eintrag entfernen
# (optional, Standard an) -> Retire. Kein Schluessel lesbar -> kein Retire (Rueckfrage in der Oberflaeche).
# Quellen: https://learn.microsoft.com/graph/api/bitlockerrecoverykey-get (Schluessel nur mit $select=key, BitlockerKey.Read.All)
#          https://learn.microsoft.com/graph/api/intune-devices-manageddevice-retire
# ---------------------------------------------------------------------------------------------
function Get-APBitLocker([string]$Token, [string]$AadId) {
    if (-not $AadId -or (Test-APLeereId $AadId)) { return @() }
    $liste = @(Get-APAll $Token "/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId%20eq%20'$AadId'")
    foreach ($k in $liste) {
        $d = Invoke-APGet $Token "/informationProtection/bitlocker/recoveryKeys/$($k.id)?`$select=key"
        [pscustomobject]@{ Id = "$($k.id)"; Erstellt = (ConvertTo-APZeit $k.createdDateTime); Laufwerk = $(switch ("$($k.volumeType)") { '1' { 'Betriebssystem' } '2' { 'Daten (fest)' } '3' { 'Wechseldatentraeger' } default { "$($k.volumeType)" } }); Schluessel = "$($d.key)" }
    }
}
# Geraete: Seriennummer, IntuneId, AadId, ApBenutzer. OhneSchluessel = trotzdem zurueckziehen, wenn kein Schluessel lesbar ist.
function Start-APZurueckziehen([string]$TenantKey, $Settings, [object[]]$Geraete, [bool]$ApEntfernen = $true, [bool]$OhneSchluessel = $false) {
    $tok = Get-APToken $TenantKey $Settings
    $set = if ($ApEntfernen) { Get-APApSet $tok } else { @{} }
    foreach ($g in @($Geraete | Where-Object { $_ })) {
        $f = @(); $ap = ''; $ret = ''; $keys = @()
        try { $keys = @(Get-APBitLocker $tok "$($g.AadId)") } catch { $f += "BitLocker: $($_.Exception.Message)" }
        $mitKey = @($keys | Where-Object { $_.Schluessel }).Count
        Write-HULog -Message "$($g.Seriennummer): $mitKey BitLocker-Schluessel gelesen" -Level $(if ($mitKey) { 'INFO' } else { 'WARN' }) -Tenant $TenantKey
        if (-not $mitKey -and -not $OhneSchluessel) {
            $ret = 'nicht gesendet'; $f += 'kein BitLocker-Schluessel lesbar - nicht zurueckgezogen (erneut mit "auch ohne Schluessel")'
        } else {
            if ($ApEntfernen) {
                $k = ConvertTo-APSerial "$($g.Seriennummer)"
                if ($set.ContainsKey($k)) {
                    if ("$($g.ApBenutzer)") { try { [void](Invoke-APWrite $tok "/deviceManagement/windowsAutopilotDeviceIdentities/$($set[$k])/unassignUserFromDevice" 'POST' @{}) } catch { $f += "Benutzer aufheben: $($_.Exception.Message)" } }
                    $r = Invoke-GraphRequestWithRetry -Token $tok -Endpoint "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($set[$k])" -Method DELETE
                    $ap = if ($r -and $r.PSObject.Properties['IsError'] -and $r.IsError) { $f += "Autopilot entfernen: $($r.StatusCode) $($r.ErrorMessage)"; 'Fehler' } else { 'entfernt' }
                } else { $ap = 'keiner' }
            } else { $ap = 'bleibt' }
            # 065 B1: Autopilot-Eintrag nicht entfernt -> KEIN Retire (das Geraet wuerde beim Zuruecksetzen wieder ins Schul-Setup gehen)
            if ($ap -eq 'Fehler') { $ret = 'nicht gesendet'; $f += 'Autopilot-Eintrag nicht entfernt - nicht zurueckgezogen ("Erneut versuchen")' }
            elseif ("$($g.IntuneId)") {
                try { [void](Invoke-APEinmal $tok "/deviceManagement/managedDevices/$($g.IntuneId)/retire" @{}); $ret = 'gesendet' } catch { $m = "$($_.Exception.Message)"; $ret = $(if ($m -match 'unbekannt') { 'unbekannt' } else { 'Fehler' }); $f += "Zurueckziehen: $m" }
            } else { $ret = 'kein Intune-Eintrag' }
            Write-HULog -Message "$($g.Seriennummer): Zurueckziehen $ret" -Level $(if ($ret -eq 'gesendet') { 'OK' } else { 'WARN' }) -Tenant $TenantKey
        }
        [pscustomobject]@{ APZurErg = $true; Tenant = $TenantKey; Seriennummer = "$($g.Seriennummer)"; Autopilot = $ap; Retire = $ret; Schluessel = @($keys); Fehler = ($f -join '; ') }
    }
}
