#Requires -Version 5.1
<#
.SYNOPSIS
    Windows-Updates ueber mehrere Tenants (ab 2.6.3): Versionen und Patchstand der Geraete,
    Update-Ringe, Feature-, Qualitaets- und Treiber-Update-Profile mit Zuweisungen und Pausen.
.DESCRIPTION
    Graph (beta; lesen, ab Schritt 2 auch anlegen, aendern, zuweisen, loeschen):
      /deviceManagement/managedDevices                     Windows-Geraete (osVersion, letzter Sync)
      /deviceManagement/windowsUpdateCatalogItems          Qualitaets-Updates mit Build-Revisionen und Datum (Patchstand)
      /deviceManagement/deviceConfigurations               Update-Ringe (windowsUpdateForBusinessConfiguration)
      /deviceManagement/windowsFeatureUpdateProfiles       Zielversion (z. B. Windows 11, Version 25H2)
      /deviceManagement/windowsQualityUpdateProfiles       Expedite-Richtlinien
      /deviceManagement/windowsQualityUpdatePolicies       Qualitaets-Update-Richtlinien
      /deviceManagement/windowsDriverUpdateProfiles        Treiber-Updates
    Rechte: DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All, Group.Read.All.
    Quellen: learn.microsoft.com/graph/api/resources/intune-deviceconfig-windowsupdateforbusinessconfiguration,
             learn.microsoft.com/graph/api/resources/intune-softwareupdate-windowsqualityupdatecatalogitem (beta)
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Nutzt Invoke-HUIntuneGraph/Get-HUIntuneGraphAll aus HU.Intune.
#>

# Windows-Build -> Version (Windows 11 ab Build 22000). Unbekannte Builds erscheinen als "Build N".
$script:HUWuBuilds = @{   # Hashtable (nicht [ordered]: dort waere [int] ein Positions-Index)
    19044 = @('Windows 10', '21H2'); 19045 = @('Windows 10', '22H2')
    22000 = @('Windows 11', '21H2'); 22621 = @('Windows 11', '22H2'); 22631 = @('Windows 11', '23H2')
    26100 = @('Windows 11', '24H2'); 26200 = @('Windows 11', '25H2')
    # Server und LTSC melden sich ebenfalls als "Windows"
    14393 = @('Windows 10', '1607 / Server 2016'); 17763 = @('Windows 10', '1809 LTSC / Server 2019'); 20348 = @('Windows Server', '2022')
}
# Neuere Versionen (z. B. 26H2) liefert der Update-Katalog von Microsoft selbst (versionName/productName) - die Liste oben ist nur der Rueckfall.
$script:HUWuStaleDays = 30
$script:HUWuSupportDays = 75   # kein Sicherheitspatch seit so vielen Tagen = Version ohne Support

# '10.0.26200.6899' -> @{ Build; Ubr; Product; Version; Label }. Mit -Catalog: Name aus dem Microsoft-Katalog (auch neue Versionen)
function Get-HUWuBuildInfo([string]$OsVersion, [hashtable]$Catalog = $null) {
    $r = [pscustomobject]@{ Build = 0; Ubr = 0; Product = ''; Version = ''; Label = 'unbekannt' }
    $p = @("$OsVersion".Trim() -split '\.')
    if ($p.Count -lt 3) { return $r }
    $b = 0; $u = 0
    if (-not [int]::TryParse($p[2], [ref]$b)) { return $r }
    if ($p.Count -ge 4) { [void][int]::TryParse($p[3], [ref]$u) }
    $r.Build = $b; $r.Ubr = $u
    $named = $null
    if ($Catalog -and $Catalog.ContainsKey($b)) { $named = @(@($Catalog[$b]) | Where-Object { $_.VersionName } | Select-Object -First 1)[0] }
    if ($named) { $r.Product = $(if ($named.ProductName) { $named.ProductName } else { 'Windows' }); $r.Version = $named.VersionName }
    elseif ($script:HUWuBuilds.ContainsKey($b)) { $r.Product = $script:HUWuBuilds[$b][0]; $r.Version = $script:HUWuBuilds[$b][1] }
    else { $r.Product = $(if ($b -ge 22000) { 'Windows 11' } else { 'Windows 10' }); $r.Version = "Build $b (Vorschau oder unbekannt)" }
    $r.Label = $(if ($r.Version -like "Build *") { "$($r.Product) $($r.Version)" } else { "$($r.Product) $($r.Version) ($b)" })
    return $r
}

# Qualitaets-Update-Katalog -> Build -> Liste @{ Ubr; Date; Security; Name } (neueste zuerst)
function ConvertFrom-HUWuCatalog([object[]]$Items) {
    $map = @{}
    foreach ($it in @($Items)) {
        if (-not $it -or "$($it.'@odata.type')" -notmatch 'windowsQualityUpdateCatalogItem') { continue }
        $sec = "$($it.classification)" -eq 'security'
        foreach ($rv in @($it.productRevisions)) {
            $ob = $rv.osBuild
            if (-not $ob) { continue }
            $b = 0; $u = 0
            if (-not [int]::TryParse("$($ob.buildNumber)", [ref]$b) -or -not [int]::TryParse("$($ob.updateBuildRevision)", [ref]$u)) { continue }
            $d = $null
            foreach ($v in "$($rv.releaseDateTime)", "$($it.releaseDateTime)") { if ($v) { try { $d = [datetime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture); break } catch { } } }
            if (-not $map.ContainsKey($b)) { $map[$b] = New-Object System.Collections.Generic.List[object] }
            $map[$b].Add([pscustomobject]@{ Ubr = $u; Date = $d; Security = $sec; Name = "$($it.displayName)"; Kb = "$($it.kbArticleId)"; VersionName = "$($rv.versionName)"; ProductName = "$($rv.productName)" })
        }
    }
    $out = @{}
    foreach ($k in $map.Keys) { $out[$k] = @($map[$k] | Sort-Object Ubr -Descending) }
    return $out
}

# Patchstand eines Geraets: Anzahl Sicherheitsupdates des Builds, die neuer sind als der installierte Stand.
# 0 = aktuell, 1 = zurueck (ein Monat), 2+ = veraltet; ohne Katalog-Eintrag fuer den Build = unbekannt.
# (Zaehlen statt Datum: der Katalog enthaelt nicht jeden aelteren Stand.)
function Get-HUWuPatchState($Info, [hashtable]$Catalog) {
    if (-not $Info -or -not $Info.Build -or -not $Catalog -or -not $Catalog.ContainsKey($Info.Build)) { return 'unbekannt' }
    $sec = @(@($Catalog[$Info.Build]) | Where-Object { $_.Security })
    if (-not $sec.Count) { return 'unbekannt' }
    $newer = @($sec | Where-Object { $_.Ubr -gt $Info.Ubr } | Select-Object -ExpandProperty Ubr -Unique).Count
    if ($newer -eq 0) { return 'aktuell' }
    if ($newer -eq 1) { return 'zurueck' }
    return 'veraltet'
}

# Wie viele Sicherheitsupdates fehlen (fuer die Geraeteliste)
function Get-HUWuMissingCount($Info, [hashtable]$Catalog) {
    if (-not $Info -or -not $Info.Build -or -not $Catalog -or -not $Catalog.ContainsKey($Info.Build)) { return $null }
    return @(@($Catalog[$Info.Build]) | Where-Object { $_.Security -and $_.Ubr -gt $Info.Ubr } | Select-Object -ExpandProperty Ubr -Unique).Count
}

# Neuestes Sicherheitsupdate je Build (fuer die Anzeige)
function Get-HUWuLatestText([hashtable]$Catalog, [int]$Build) {
    if (-not $Catalog -or -not $Catalog.ContainsKey($Build)) { return '' }
    $l = @(@($Catalog[$Build]) | Where-Object { $_.Security } | Select-Object -First 1)[0]
    if (-not $l) { return '' }
    return "$Build.$($l.Ubr)$(if ($l.Date) { " vom $($l.Date.ToString('dd.MM.yyyy'))" })"
}

function Get-HUWuDate($v) {
    if (-not "$v") { return $null }
    try { $d = [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture); if ($d.Year -lt 2000) { return $null }; return $d } catch { return $null }
}

# Zuweisungen als Text (Gruppen ueber Namen)
function Get-HUWuAssignText([object[]]$Assignments, [hashtable]$Names) {
    $t = @(foreach ($a in @($Assignments | Where-Object { $_ })) {
            try { "$((ConvertFrom-HUAssignment ([pscustomobject]@{ target = $a.target; intent = ''; settings = $null }) $Names).Ziel)" } catch { '?' }
        })
    if (-not $t.Count) { return 'nicht zugewiesen' }
    # Einschliessen zuerst, Ausschluesse dahinter - sonst liest sich 'Ausschluss: X, Alle Geraete' wie zwei Ausschluesse
    $inc = @($t | Where-Object { $_ -notlike 'Ausschluss*' }); $exc = @($t | Where-Object { $_ -like 'Ausschluss*' })
    return ((@(($inc -join ', '), ($exc -join ', ')) | Where-Object { $_ }) -join '; ')
}

# Alles eines Tenants lesen. Fehler einzelner Teile landen in Errors (der Rest bleibt nutzbar).
function Get-HUWuInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [hashtable]$Catalog = $null, [datetime]$Now = (Get-Date))
    $inv = [pscustomobject]@{ Tenant = $TenantKey; Devices = @(); Policies = @(); Drivers = @(); Catalog = $Catalog; Errors = (New-Object System.Collections.Generic.List[string]) }
    # 074 B13/B14: Lizenz vor Recht pruefen, beim Recht den Namen nennen
    $err = { param($what, $e, $right = 'DeviceManagementConfiguration.Read.All')
        $m = "$($e.Exception.Message)"
        if ($m -match '(?i)licen|lizenz|autopatch') { $m = "Windows-Lizenz mit Autopatch-Berechtigung fehlt? ($m)" }
        elseif ($m -match '403|Forbidden|Authorization') { $m = "Berechtigung fehlt: $right - unter Rechte erteilen" }
        elseif ($m -match '429|Too ?Many') { $m = 'Intune drosselt gerade (429) - spaeter neu laden' }
        $inv.Errors.Add("${what} nicht lesbar: $m") }
    # Katalog (je Tenant gleich - wird nur einmal gelesen und weitergereicht)
    if (-not $inv.Catalog) {
        try { $inv.Catalog = ConvertFrom-HUWuCatalog @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsUpdateCatalogItems') }
        catch { & $err 'Update-Katalog' $_; $inv.Catalog = @{} }
    }
    # Geraete
    try {
        $sel = 'id,deviceName,osVersion,lastSyncDateTime,userPrincipalName,managedDeviceOwnerType,model,operatingSystem,joinType'
        $devs = $null
        try { $devs = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$sel") }
        catch { $devs = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$($sel -replace ',joinType', '')") }   # Rueckfall ohne joinType
        $inv.Devices = @(foreach ($d in $devs) {
                $bi = Get-HUWuBuildInfo "$($d.osVersion)" $inv.Catalog
                $sync = Get-HUWuDate $d.lastSyncDateTime
                [pscustomobject]@{
                    Tenant = $TenantKey; Geraet = "$($d.deviceName)"; Benutzer = "$($d.userPrincipalName)"; Version = $bi.Label; Build = "$($d.osVersion)"
                    Patchstand = (Get-HUWuPatchState $bi $inv.Catalog); Fehlend = (Get-HUWuMissingCount $bi $inv.Catalog); LetzterSync = $(if ($sync) { $sync.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' })
                    OhneSync = [bool](-not $sync -or ($Now - $sync).TotalDays -gt $script:HUWuStaleDays)
                    Besitz = "$($d.managedDeviceOwnerType)"; Modell = "$($d.model)"; BuildNr = $bi.Build; Id = "$($d.id)"
                    Beitritt = (ConvertTo-HUWuJoinText "$($d.PSObject.Properties['joinType'] | ForEach-Object { $_.Value })")
                }
            })
    } catch { & $err 'Geraete' $_ 'DeviceManagementManagedDevices.Read.All'; $inv | Add-Member -NotePropertyName DevicesFailed -NotePropertyValue $true -Force }
    # Ringe und Profile
    $raw = New-Object System.Collections.Generic.List[object]
    try {
        $rings = $null
        try { $rings = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/deviceConfigurations?`$filter=isof('microsoft.graph.windowsUpdateForBusinessConfiguration')&`$expand=assignments") }
        catch { $rings = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/deviceConfigurations?$expand=assignments') }   # Rueckfall ohne Typ-Filter
        foreach ($r in @($rings | Where-Object { "$($_.'@odata.type')" -match 'windowsUpdateForBusinessConfiguration' })) { $raw.Add(@{ Art = 'Update-Ring'; O = $r; Asg = @($r.assignments) }) }
    } catch { & $err 'Update-Ringe' $_ }
    foreach ($src in @(
            @{ Art = 'Feature-Update'; Ep = '/deviceManagement/windowsFeatureUpdateProfiles' }
            @{ Art = 'Expedite'; Ep = '/deviceManagement/windowsQualityUpdateProfiles' }
            @{ Art = 'Qualitaets-Update'; Ep = '/deviceManagement/windowsQualityUpdatePolicies' }
            @{ Art = 'Treiber-Update'; Ep = '/deviceManagement/windowsDriverUpdateProfiles' })) {
        try {
            foreach ($o in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint $src.Ep)) {
                $asg = @(); $asgErr = $false
                try { $asg = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($src.Ep)/$($o.id)/assignments") } catch { $asgErr = $true; & $err "Zuweisungen von '$($o.displayName)'" $_ }
                $raw.Add(@{ Art = $src.Art; O = $o; Asg = $asg; AsgErr = $asgErr })
                if ($src.Art -eq 'Treiber-Update') {
                    # anstehende Treiber dieser Richtlinie (learn.microsoft.com/graph/api/resources/intune-softwareupdate-windowsdriverupdateinventory)
                    try {
                        $inv.Drivers = @($inv.Drivers) + @(foreach ($dr in @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($src.Ep)/$($o.id)/driverInventories")) {
                                ConvertTo-HUWuDriverRow -Tenant $TenantKey -ProfileId "$($o.id)" -ProfileName "$($o.displayName)" -D $dr
                            })
                    } catch { & $err "Treiber '$($o.displayName)'" $_ }
                }
            }
        } catch { & $err $src.Art $_ }
    }
    $gids = @($raw | ForEach-Object { @($_.Asg) } | Where-Object { $_ -and $_.target } | ForEach-Object { "$($_.target.groupId)" } | Where-Object { $_ } | Select-Object -Unique)
    $names = @{}; if ($gids.Count) { try { $names = Get-HUGroupNames -TenantKey $TenantKey -Settings $Settings -Ids $gids } catch { } }
    $inv.Policies = @(foreach ($x in $raw) {
            $row = ConvertTo-HUWuPolicyRow -Tenant $TenantKey -Art $x.Art -O $x.O -Asg $x.Asg -Names $names -Now $Now
            # 074 B14: nicht lesbare Zuweisungen nicht als "nicht zugewiesen" zeigen
            if ($x.AsgErr) { $row.Zuweisung = 'nicht lesbar (siehe Protokoll)'; $row.Hinweis = (@('Zuweisungen nicht lesbar', $row.Hinweis) | Where-Object { $_ }) -join '; ' }
            $row
        })
    # deviceReporting der Treiber-Richtlinie ist oft 0, obwohl Geraete Treiber melden - betroffene Geraete aus der Treiberliste zaehlen
    foreach ($p in @($inv.Policies | Where-Object { $_.Art -eq 'Treiber-Update' })) {
        if ("$($p.Zuweisung)" -like 'nicht lesbar*') { continue }
        Update-HUWuDriverPolicyRow $p @($inv.Drivers)
        # Tenant ohne Geraete: dass keine Treiber gemeldet werden, ist dann kein Problem
        if (-not @($inv.Devices).Count) { $p.Hinweis = (@("$($p.Hinweis)" -split '; ' | Where-Object { $_ -and $_ -notlike 'Noch keine Treiber gemeldet*' -and $_ -notlike 'Keine Geraete melden*' }) -join '; ') }
    }
    return $inv
}

# Ring/Profil -> Zeile: Art, Name, Einstellung, Pause, Zuweisung
function ConvertTo-HUWuPolicyRow([string]$Tenant, [string]$Art, $O, [object[]]$Asg, [hashtable]$Names, [datetime]$Now = (Get-Date)) {
    $g = { param($n) if ($O.PSObject.Properties[$n]) { $O.$n } else { $null } }
    $set = ''; $pause = ''; $warn = ''
    switch ($Art) {
        'Update-Ring' {
            $dq = & $g 'deadlineForQualityUpdatesInDays'; $df = & $g 'deadlineForFeatureUpdatesInDays'
            $set = "Aufschub Qualitaet $(& $g 'qualityUpdatesDeferralPeriodInDays') T., Feature $(& $g 'featureUpdatesDeferralPeriodInDays') T.; Frist $(if ($null -ne $dq -or $null -ne $df) { "Qualitaet $(if ($null -ne $dq) { "$dq T." } else { '-' }), Feature $(if ($null -ne $df) { "$df T." } else { '-' })" } else { '-' })"
            $gp = & $g 'deadlineGracePeriodInDays'
            if (($null -ne $dq -or $null -ne $df) -and $null -ne $gp) { $set += ", Nachfrist $gp T." }
            $is = & $g 'installationSchedule'
            $ah = ''
            if ($is -and $is.PSObject.Properties['activeHoursStart']) { $ah = "$("$($is.activeHoursStart)".PadRight(5).Substring(0, 5))-$("$($is.activeHoursEnd)".PadRight(5).Substring(0, 5))".Trim() }
            if ($ah) { $set += "; aktive Zeit $ah" }
            if ((& $g 'skipChecksBeforeRestart') -eq $true) { $set += '; Neustart-Pruefung: ueberspringen'; $warn = 'Neustart-Pruefung ueberspringen (fuer Ladewagen gedacht)' }
            $p = @()
            foreach ($k in @(@('quality', 'Qualitaet'), @('feature', 'Feature'))) {
                if ((& $g "$($k[0])UpdatesPaused") -eq $true) {
                    $ex = Get-HUWuDate (& $g "$($k[0])UpdatesPauseExpiryDateTime")
                    $p += "$($k[1]) bis $(if ($ex) { $ex.ToLocalTime().ToString('dd.MM.') } else { '?' })"
                    if ($ex -and ($ex - $Now).TotalDays -le 3) { $warn = (@($warn, "$($k[1])-Pause endet $($ex.ToLocalTime().ToString('dd.MM.'))") | Where-Object { $_ }) -join '; ' }
                }
            }
            $pause = $p -join ', '
        }
        'Feature-Update' {
            $set = "Zielversion: $(& $g 'featureUpdateVersion')"
            $ro = & $g 'rolloutSettings'
            if ($ro) {
                $s1 = Get-HUWuDate $ro.offerStartDateTimeInUTC; $s2 = Get-HUWuDate $ro.offerEndDateTimeInUTC
                if ($s1 -and $s2) { $set += "; gestaffelt $($s1.ToString('dd.MM.'))-$($s2.ToString('dd.MM.yyyy'))" } elseif ($s1) { $set += "; ab $($s1.ToString('dd.MM.yyyy'))" }
            }
            $eos = Get-HUWuDate (& $g 'endOfSupportDate')
            if ($eos) { $set += "; Support bis $($eos.ToString('dd.MM.yyyy'))"; if ($eos -lt $Now.AddDays(90)) { $warn = 'Support der Zielversion endet bald' } }
        }
        'Expedite' {
            $ex = & $g 'expeditedUpdateSettings'
            $rel = $(if ($ex) { Get-HUWuDate $ex.qualityUpdateRelease } else { $null })
            $set = $(if ($ex) { "beschleunigt: Update vom $(if ($rel) { $rel.ToString('dd.MM.yyyy') } else { "$($ex.qualityUpdateRelease)" }), Neustart nach $($ex.daysUntilForcedReboot) T." } else { 'Qualitaets-Update-Profil' })
            $warn = $(if ($rel -and ($Now - $rel).TotalDays -gt 60) { "altes Expedite ($($rel.ToString('MM/yyyy'))) - entfernen (Microsoft-Empfehlung)" } else { 'nach dem Ausrollen wieder entfernen (Microsoft-Empfehlung)' })
        }
        'Qualitaets-Update' { $set = "$(if (& $g 'hotpatchEnabled') { 'Hotpatch an' } else { 'Hotpatch aus' })" }
        'Treiber-Update' {
            $at = "$(& $g 'approvalType')"
            $set = "Freigabe: $(if ($at -eq 'automatic') { 'automatisch (empfohlene)' } elseif ($at -eq 'manual') { 'manuell' } else { $at })$(if ($at -eq 'automatic' -and $null -ne (& $g 'deploymentDeferralInDays')) { ", Aufschub $(& $g 'deploymentDeferralInDays') T." })"
            $rep = & $g 'deviceReporting'; $nu = & $g 'newUpdates'
            if ($null -ne $rep) { $set += "; $rep Geraet(e) melden" }
            if ($nu) { $set += "; $nu zu pruefen" }
            $sy = & $g 'inventorySyncStatus'
            if ($sy) { $ls = Get-HUWuDate $sy.lastSuccessfulSyncDateTime; if ($ls) { $set += "; Abgleich $($ls.ToLocalTime().ToString('dd.MM.'))" }; if ("$($sy.driverInventorySyncState)" -and "$($sy.driverInventorySyncState)" -ne 'success') { $warn = "Treiber-Abgleich: $($sy.driverInventorySyncState)" } }
            if ($null -ne $rep -and [int]$rep -eq 0) { $warn = 'Keine Geraete melden - Geraete muessen Entra- oder Hybrid-beigetreten sein, Diagnosedaten mindestens Erforderlich, Dienst wlidsvc an, Windows-Lizenz mit Autopatch-Berechtigung' }
            elseif ($nu) { $warn = (@($warn, "$nu Treiber zu pruefen") | Where-Object { $_ }) -join '; ' }
        }
    }
    $name = "$(& $g 'displayName')"
    # Zuweisungen einzeln (Schluessel + Text) fuer den Bereich "Zuweisungen" wie in der Wartung
    $al = @(foreach ($a in @($Asg | Where-Object { $_ -and $_.target })) {
            $z = '?'; try { $z = "$((ConvertFrom-HUAssignment ([pscustomobject]@{ target = $a.target; intent = ''; settings = $null }) $Names).Ziel)" } catch { }
            [pscustomobject]@{ Key = (Get-HUWuTargetKey $a.target); Ziel = $z }
        })
    return [pscustomobject]@{ Tenant = $Tenant; Art = $Art; Name = $name; Einstellung = $set; Pause = $pause; Zuweisung = (Get-HUWuAssignText $Asg $Names); Hinweis = $warn; Id = "$($O.id)"; AsgList = $al; Raw = $O }
}

function Update-HUWuDriverPolicyRow($Row, [object[]]$Drivers) {
    $mine = @($Drivers | Where-Object { $_ -and $_.ProfilId -eq $Row.Id })
    $dev = 0; foreach ($d in $mine) { if ([int]$d.Geraete -gt $dev) { $dev = [int]$d.Geraete } }
    $Row.Einstellung = ($Row.Einstellung -replace '; \d+ Geraet\(e\) melden', '') + "; $($mine.Count) Treiber, bis $dev betroffene Geraete"
    if ($dev -gt 0 -and $Row.Hinweis -like 'Keine Geraete melden*') { $Row.Hinweis = '' }
    elseif (-not $mine.Count -and -not @($Row.AsgList).Count) { $Row.Hinweis = (@("$($Row.Hinweis)" -split '; ' | Where-Object { $_ -and $_ -notlike 'Keine Geraete melden*' }) -join '; ') }   # nicht zugewiesen: kein Geraet kann melden
    elseif (-not $mine.Count -and $Row.Hinweis -notlike 'Keine Geraete melden*') { $Row.Hinweis = (@($Row.Hinweis, 'Noch keine Treiber gemeldet - Geraete muessen Entra- oder Hybrid-beigetreten sein, Diagnosedaten mindestens Erforderlich') | Where-Object { $_ }) -join '; ' }
}

# joinType -> Text (Feature-, Qualitaets- und Treiber-Profile wirken nur bei Entra- oder Hybrid-Beitritt)
function ConvertTo-HUWuJoinText([string]$J) {
    switch ($J) {
        'azureADJoined' { return 'Entra' }
        'hybridAzureADJoined' { return 'Hybrid' }
        'azureADRegistered' { return 'nur registriert' }
        default { return $(if ($J) { $J } else { 'unbekannt' }) }
    }
}

# Treiber aus driverInventories -> Zeile
function ConvertTo-HUWuDriverRow([string]$Tenant, [string]$ProfileId, [string]$ProfileName, $D) {
    $st = switch ("$($D.approvalStatus)") { 'needsReview' { 'pruefen' } 'approved' { 'freigegeben' } 'declined' { 'abgelehnt' } 'suspended' { 'ausgesetzt' } default { "$($D.approvalStatus)" } }
    $cat = switch ("$($D.category)") { 'recommended' { 'empfohlen' } 'previouslyApproved' { 'frueher freigegeben' } 'other' { 'sonstige' } default { "$($D.category)" } }
    $rel = Get-HUWuDate $D.releaseDateTime; $dep = Get-HUWuDate $D.deployDateTime
    $n = 0; [void][int]::TryParse("$($D.applicableDeviceCount)", [ref]$n)
    return [pscustomobject]@{
        Tenant = $Tenant; ProfilId = $ProfileId; Profil = $ProfileName; Id = "$($D.id)"
        Treiber = "$($D.name)"; Version = "$($D.version)"; Hersteller = "$($D.manufacturer)"; Klasse = "$($D.driverClass)"; Kategorie = $cat
        Datum = $(if ($rel) { $rel.ToString('yyyy-MM-dd') } else { '' }); Geraete = $n; Status = $st   # ISO: sortiert richtig
        Ab = $(if ($dep -and $st -eq 'freigegeben') { $dep.ToLocalTime().ToString('dd.MM.yyyy') } else { '' })
    }
}

# Treiber ueber Tenants: gleicher Name + Version = eine Zeile, je Tenant "Geraete (Status)"
function Get-HUWuDriverMatrix([object[]]$Inventories, [hashtable]$TenantNames = @{}, [scriptblock]$Filter = $null) {
    $invs = @($Inventories | Where-Object { $_ })
    $all = @($invs | ForEach-Object { @($_.Drivers) } | Where-Object { $_ -and (-not $Filter -or (& $Filter $_)) })
    $rows = foreach ($g in @($all | Group-Object { "$($_.Treiber)|$($_.Version)" })) {
        $f = @($g.Group)[0]
        $o = [ordered]@{ Treiber = $f.Treiber; Version = $f.Version; Hersteller = $f.Hersteller; Klasse = $f.Klasse; Kategorie = $f.Kategorie; Datum = $f.Datum }
        foreach ($i in @($invs | Where-Object { @($_.Drivers).Count })) {
            $col = $(if ($TenantNames.ContainsKey($i.Tenant)) { $TenantNames[$i.Tenant] } else { $i.Tenant })
            if ($o.Contains($col) -or $col -in 'Gesamt', 'Aktuell %', 'Support', 'Geraete', 'Status', 'Key') { $col = "$col ($($i.Tenant))" }   # 074 B26: gleicher Name nicht still ueberschreiben
            $x = @($g.Group | Where-Object { $_.Tenant -eq $i.Tenant })
            $o[$col] = $(if ($x.Count) { "$(($x | Measure-Object Geraete -Sum).Sum) ($(@($x | ForEach-Object { $_.Status } | Select-Object -Unique) -join '/'))" } else { '' })
        }
        $o['Geraete'] = ($g.Group | Measure-Object Geraete -Sum).Sum
        $o['Status'] = (@($g.Group | ForEach-Object { $_.Status } | Select-Object -Unique) -join '/')
        $o['Key'] = "$($g.Name)"   # Treiber|Version - fuer Aktionen (Spalte wird nicht angezeigt)
        [pscustomobject]$o
    }
    return @($rows | Sort-Object @{ e = { if ($_.Status -match 'pruefen') { 0 } else { 1 } } }, @{ e = { $_.Geraete }; Descending = $true }, Treiber)
}

# Uebersicht: je Version eine Zeile, je Tenant "Anzahl (davon aktuell)"; dazu Summen fuer Patchstand und ohne Sync
function Get-HUWuMatrix([object[]]$Inventories, [hashtable]$TenantNames = @{}, [datetime]$Now = (Get-Date)) {
    $invs = @($Inventories | Where-Object { $_ })
    $labels = @($invs | ForEach-Object { @($_.Devices) } | Group-Object Version | Sort-Object @{ e = { @($_.Group)[0].BuildNr }; Descending = $true } | ForEach-Object { $_.Name })
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($l in $labels) {
        $o = [ordered]@{ Version = $l }
        $all = @($invs | ForEach-Object { @($_.Devices) } | Where-Object { $_.Version -eq $l })
        $b = @($all)[0].BuildNr
        $cat = $null; foreach ($i0 in $invs) { if ($i0.Catalog -and $i0.Catalog.Count) { $cat = $i0.Catalog; break } }
        $o['Neuester Patch'] = $(if ($b -and $cat) { Get-HUWuLatestText $cat $b } else { '' })
        foreach ($i in @($invs | Where-Object { @($_.Devices).Count })) {   # Tenant ohne Geraete (z. B. ohne Intune): keine leere Spalte
            $d = @($i.Devices | Where-Object { $_.Version -eq $l })
            $col = $(if ($TenantNames.ContainsKey($i.Tenant)) { $TenantNames[$i.Tenant] } else { $i.Tenant })
            if ($o.Contains($col) -or $col -in 'Gesamt', 'Aktuell %', 'Support', 'Geraete', 'Status', 'Key') { $col = "$col ($($i.Tenant))" }   # 074 B26: gleicher Name nicht still ueberschreiben
            $o[$col] = $(if ($d.Count) { "$($d.Count) ($(@($d | Where-Object Patchstand -eq 'aktuell').Count) aktuell)" } else { '' })
        }
        $o['Gesamt'] = $all.Count
        $o['Aktuell %'] = $(if ($all.Count) { [int][Math]::Round(100 * @($all | Where-Object Patchstand -eq 'aktuell').Count / $all.Count) } else { 0 })
        # Support: letzter Sicherheitspatch der Version aelter als ~2,5 Monate = Microsoft liefert nichts mehr
        $last = $null
        # derselbe Eintrag wie "Neuester Patch" (hoechste Revision) - nicht das juengste Datum, das kann aus einem Sammel-Eintrag stammen
        if ($b -and $cat -and $cat.ContainsKey($b)) { $last = @(@($cat[$b]) | Where-Object { $_.Security } | Select-Object -First 1)[0] }
        if ($last -and -not $last.Date) { $last = $null }
        $o['Support'] = $(if (-not $last) { '?' } elseif (($Now - $last.Date).TotalDays -gt $script:HUWuSupportDays) { 'abgelaufen' } else { 'laeuft' })
        $rows.Add([pscustomobject]$o)
    }
    return $rows.ToArray()
}

# Kurzfassung je Tenant fuer die Liste links
function Get-HUWuSummary($Inventory) {
    $d = @($Inventory.Devices)
    $n = $d.Count
    $akt = @($d | Where-Object Patchstand -eq 'aktuell').Count
    $zur = @($d | Where-Object Patchstand -eq 'zurueck').Count
    $alt = @($d | Where-Object Patchstand -eq 'veraltet').Count
    $ohne = @($d | Where-Object OhneSync).Count
    $top = @($d | Group-Object Version | Sort-Object Count -Descending | Select-Object -First 1)[0]
    return [pscustomobject]@{
        Text = "$n Geraete: $akt aktuell, $zur mit 1 fehlenden Update, $alt veraltet$(if ($ohne) { ", $ohne ohne Sync > $($script:HUWuStaleDays) T." })"
        Haupt = $(if ($top) { "meist $($top.Name)" } else { '' })
        Total = $n; Current = $akt; Behind = $zur; Old = $alt; Stale = $ohne
        Ampel = $(if (-not $n) { 'grau' } elseif ($alt -gt [Math]::Max(2.0, $n * 0.1)) { 'rot' } elseif ($alt -or $zur -gt $n * 0.2) { 'gelb' } else { 'gruen' })
    }
}

# ============================================================================
# Schritt 2: aendern (Graph beta, DeviceManagementConfiguration.ReadWrite.All). Vor jeder Aenderung wird das
# Objekt unter %APPDATA%\HU-MultiTenant\WinUpdates-vorher abgelegt.
# ============================================================================
$script:HUWuEp = @{
    'Update-Ring'       = @{ Ep = '/deviceManagement/deviceConfigurations'; AsgType = '#microsoft.graph.deviceConfigurationAssignment'; Type = '#microsoft.graph.windowsUpdateForBusinessConfiguration'; AllOk = $true }
    'Feature-Update'    = @{ Ep = '/deviceManagement/windowsFeatureUpdateProfiles'; AsgType = '#microsoft.graph.windowsFeatureUpdateProfileAssignment'; Type = '#microsoft.graph.windowsFeatureUpdateProfile'; AllOk = $false }
    'Expedite'          = @{ Ep = '/deviceManagement/windowsQualityUpdateProfiles'; AsgType = '#microsoft.graph.windowsQualityUpdateProfileAssignment'; Type = '#microsoft.graph.windowsQualityUpdateProfile'; AllOk = $false }
    'Treiber-Update'    = @{ Ep = '/deviceManagement/windowsDriverUpdateProfiles'; AsgType = '#microsoft.graph.windowsDriverUpdateProfileAssignment'; Type = '#microsoft.graph.windowsDriverUpdateProfile'; AllOk = $false }
    'Qualitaets-Update' = @{ Ep = '/deviceManagement/windowsQualityUpdatePolicies'; AsgType = '#microsoft.graph.windowsQualityUpdatePolicyAssignment'; Type = '#microsoft.graph.windowsQualityUpdatePolicy'; AllOk = $false }
}
function Get-HUWuEpInfo([string]$Art) { if ($script:HUWuEp.ContainsKey($Art)) { return $script:HUWuEp[$Art] }; throw "Unbekannte Art '$Art'" }

# Stand vor einer Aenderung sichern (JSON). Rueckgabe: Pfad.
# 074 B5: Zuweisungen werden mitgesichert (Eigenschaft "assignments"; beim Import werden sie verworfen).
function Save-HUWuBefore([string]$TenantKey, [string]$Art, $Obj, [string]$Root = '', [object[]]$Assignments = $null) {
    if (-not $Root) { $Root = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'HU-MultiTenant\WinUpdates-vorher' }
    if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    $safe = ("$TenantKey`_$Art`_$($Obj.id)" -replace '[^A-Za-z0-9_.-]', '_')
    $f = Join-Path $Root ("{0}_{1}.json" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    if ($null -ne $Assignments) {
        $Obj = $Obj | Select-Object -Property * -ExcludeProperty 'assignments'
        $Obj | Add-Member -NotePropertyName 'assignments' -NotePropertyValue @($Assignments) -Force
    }
    [IO.File]::WriteAllText($f, ($Obj | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    return $f
}

# Zuweisungen frisch aus Intune lesen. Fehlt "value" (Teilfehler, Drosselung), wird nicht geraten (074 B31).
function Get-HUWuAssignmentsFresh([string]$TenantKey, $Settings, [string]$Art, [string]$Id) {
    $e = Get-HUWuEpInfo $Art
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id/assignments"
    if (-not $r -or -not $r.PSObject.Properties['value']) { throw "Zuweisungen von '$Id' nicht lesbar - zur Sicherheit nichts geloescht" }
    return @($r.value | Where-Object { $_ })
}

# Ziel (Kind group|exclude|allDevices|allUsers, GroupId) -> Graph-Ziel
function ConvertTo-HUWuTarget($T) {
    switch ("$($T.Kind)") {
        'group' { return @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = "$($T.GroupId)" } }
        'exclude' { return @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = "$($T.GroupId)" } }
        'allDevices' { return @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
        'allUsers' { return @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
        default { throw "Unbekanntes Ziel '$($T.Kind)'" }
    }
}

# Schluessel eines vorhandenen Ziels (gleiches Ziel nicht doppelt)
function Get-HUWuTargetKey($Target) {
    $ty = "$($Target.'@odata.type')"
    $k = if ($ty -match 'exclusionGroup') { 'exclude' } elseif ($ty -match 'allDevices') { 'allDevices' } elseif ($ty -match 'allLicensedUsers') { 'allUsers' } else { 'group' }
    return "$k|$("$($Target.groupId)".ToLower())"
}

# Zuweisungen setzen: Add = neue Ziele, RemoveKeys = Schluessel (Get-HUWuTargetKey) zum Entfernen.
# assign ersetzt die komplette Liste - deshalb erst lesen, dann gesamt schreiben. Rueckgabe: Anzahl danach.
# 074 B2: ein schon vorhandenes Ziel bleibt unveraendert (samt Zuweisungsfilter) und wird nur gemeldet.
# 074 B5: Stand samt Zuweisungen wird vorher gesichert. Danach wird zurueckgelesen und verglichen.
# -Info (Hashtable) bekommt: Skipped (schon vorhandene Ziele), Backup (Datei), Mismatch (Text, wenn Intune anders aussieht).
function Set-HUWuAssignment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Art, [Parameter(Mandatory)][string]$Id,
        [object[]]$Add = @(), [string[]]$RemoveKeys = @(), [string]$BackupRoot = '', [hashtable]$Info = $null)
    $e = Get-HUWuEpInfo $Art
    foreach ($a in @($Add)) { if (-not $e.AllOk -and "$($a.Kind)" -in 'allDevices', 'allUsers') { throw "$Art laesst sich nur Geraetegruppen zuweisen (Microsoft), nicht 'Alle Geraete' oder 'Alle Benutzer'" } }
    $cur = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id/assignments")
    $before = $null; try { $before = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id" } catch { }
    if (-not $before) { $before = [pscustomobject]@{ id = $Id } }
    $file = Save-HUWuBefore $TenantKey $Art $before $BackupRoot $cur
    $map = [ordered]@{}
    foreach ($c in $cur) { if ($c.target) { $map[(Get-HUWuTargetKey $c.target)] = $c.target } }
    foreach ($k in @($RemoveKeys)) { if ($map.Contains("$k".ToLower())) { $map.Remove("$k".ToLower()) } elseif ($map.Contains("$k")) { $map.Remove("$k") } }
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Add)) {
        $t = ConvertTo-HUWuTarget $a; $k = Get-HUWuTargetKey ([pscustomobject]$t)
        if ($map.Contains($k)) { $skipped.Add($k); continue }   # vorhandenes Ziel nicht ersetzen - sonst ginge ein Filter verloren
        $map[$k] = $t
    }
    if ($Info) { $Info['Skipped'] = $skipped.ToArray(); $Info['Backup'] = $file; $Info['Mismatch'] = '' }
    if (-not @($RemoveKeys).Count -and $skipped.Count -eq @($Add).Count) { return $map.Count }   # nichts zu tun
    $body = @{ assignments = @(foreach ($t in $map.Values) { @{ '@odata.type' = $e.AsgType; target = $t } }) }
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id/assign" -Method POST -Body $body)
    # zuruecklesen: stimmt die Liste? (Intune kann kurz verzoegert sein - dann nur Hinweis, kein Fehler)
    try {
        $after = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id/assignments" | Where-Object { $_ -and $_.target } | ForEach-Object { Get-HUWuTargetKey $_.target } | Sort-Object)
        $want = @($map.Keys | Sort-Object)
        if (($after -join ',') -ne ($want -join ',') -and $Info) { $Info['Mismatch'] = "Intune zeigt danach $($after.Count) statt $($want.Count) Zuweisung(en) - bitte neu laden und pruefen (Stand vorher: $file)" }
    } catch { if ($Info) { $Info['Mismatch'] = "Zuweisungen danach nicht lesbar - bitte neu laden und pruefen (Stand vorher: $file)" } }
    return $map.Count
}

# Einstellungen aendern (PATCH). Changes = nur die Felder, die sich aendern sollen. Vorher sichern.
function Set-HUWuSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Art, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Changes, [string]$BackupRoot = '')
    $e = Get-HUWuEpInfo $Art
    # 074 B11: die Freigabeart einer Treiber-Richtlinie laesst sich nach dem Anlegen nicht aendern (Microsoft Learn)
    if ($Art -eq 'Treiber-Update' -and $Changes.ContainsKey('approvalType')) { throw 'Die Freigabeart (automatisch/manuell) einer Treiber-Richtlinie laesst sich nicht aendern - dafuer eine neue Richtlinie anlegen' }
    $before = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id"
    # 074 B6: nur Felder senden, die sich in DIESEM Tenant wirklich aendern (sonst gleicht Speichern alle Tenants an)
    $body = @{ '@odata.type' = $e.Type }
    foreach ($k in $Changes.Keys) {
        if ($before -and $before.PSObject.Properties[$k]) {
            $old = ConvertTo-Json -InputObject $before.$k -Depth 10 -Compress; $new = ConvertTo-Json -InputObject $Changes[$k] -Depth 10 -Compress
            if ($old -eq $new) { continue }
        }
        $body[$k] = $Changes[$k]
    }
    if ($body.Count -le 1) { return '' }   # nichts zu aendern - keine Sicherung, kein PATCH (075 Nachpruefung)
    $file = Save-HUWuBefore $TenantKey $Art $before $BackupRoot
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id" -Method PATCH -Body $body)
    return $file
}

# Ring: Pause setzen/aufheben (What quality|feature, Action pause|resume|extend)
function Set-HUWuRingPause {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Id,
        [ValidateSet('quality', 'feature')][string]$What, [ValidateSet('pause', 'resume', 'extend')][string]$Action, [string]$BackupRoot = '')
    if ($Action -eq 'extend') {
        $ep = "/deviceManagement/deviceConfigurations/$Id/$(if ($What -eq 'quality') { 'extendQualityUpdatesPause' } else { 'extendFeatureUpdatesPause' })"
        [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint $ep -Method POST -Body @{})
        return ''
    }
    return (Set-HUWuSettings -TenantKey $TenantKey -Settings $Settings -Art 'Update-Ring' -Id $Id -Changes @{ "$($What)UpdatesPaused" = ($Action -eq 'pause') } -BackupRoot $BackupRoot)
}

# Katalog: Zielversionen (Feature-Updates) und beschleunigbare Sicherheitsupdates
function Get-HUWuCatalogChoices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings)
    $items = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsUpdateCatalogItems')
    $feat = @($items | Where-Object { "$($_.'@odata.type')" -match 'windowsFeatureUpdateCatalogItem' -and "$($_.version)" } | ForEach-Object {
            $eos = Get-HUWuDate $_.endOfSupportDate
            [pscustomobject]@{ Version = "$($_.version)"; Name = "$($_.displayName)"; EndOfSupport = $eos; Text = "$($_.version)$(if ($eos) { " (Support bis $($eos.ToString('dd.MM.yyyy')))" })" }
        } | Sort-Object Version -Descending -Unique)
    $exp = @($items | Where-Object { "$($_.'@odata.type')" -match 'windowsQualityUpdateCatalogItem' -and $_.isExpeditable -eq $true } | ForEach-Object {
            $d = Get-HUWuDate $_.releaseDateTime
            [pscustomobject]@{ Release = "$($_.releaseDateTime)"; Date = $d; Name = "$($_.displayName)"; Security = ("$($_.classification)" -eq 'security')
                Text = "$($_.displayName)$(if ($d) { " vom $($d.ToString('dd.MM.yyyy'))" })$(if ("$($_.classification)" -ne 'security') { ' (kein Sicherheitsupdate)' })" }
        } | Sort-Object Date -Descending)
    return [pscustomobject]@{ Features = $feat; Expeditable = $exp }
}

# Neues Feature-Update-Profil (ohne Zuweisung). Rollout: @{ Mode = 'now'|'date'|'gradual'; Start; End; Interval }
function New-HUWuFeatureProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version,
        [hashtable]$Rollout = @{ Mode = 'now' }, [bool]$Win10Fallback = $false, [string]$Description = '')
    $body = @{ '@odata.type' = '#microsoft.graph.windowsFeatureUpdateProfile'; displayName = $Name; description = $Description; featureUpdateVersion = $Version
        installLatestWindows10OnWindows11IneligibleDevice = $Win10Fallback; roleScopeTagIds = @('0') }
    $ro = ConvertTo-HUWuRollout $Rollout
    if ($ro) { $body.rolloutSettings = $ro }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsFeatureUpdateProfiles' -Method POST -Body $body
    return "$($r.id)"
}

function ConvertTo-HUWuRollout([hashtable]$R) {
    if (-not $R -or "$($R.Mode)" -eq 'now') { return $null }
    $iso = { param($d) ([datetime]$d).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $o = @{ '@odata.type' = '#microsoft.graph.windowsUpdateRolloutSettings'; offerStartDateTimeInUTC = (& $iso $R.Start) }
    if ("$($R.Mode)" -eq 'gradual') { $o.offerEndDateTimeInUTC = (& $iso $R.End); $o.offerIntervalInDays = [int]$R.Interval }
    return $o
}

# Neue Expedite-Richtlinie (ohne Zuweisung)
function New-HUWuExpedite {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Release, [ValidateRange(0, 2)][int]$RebootDays = 1)
    $body = @{ '@odata.type' = '#microsoft.graph.windowsQualityUpdateProfile'; displayName = $Name; roleScopeTagIds = @('0')
        expeditedUpdateSettings = @{ '@odata.type' = '#microsoft.graph.expeditedWindowsQualityUpdateSettings'; qualityUpdateRelease = $Release; daysUntilForcedReboot = $RebootDays } }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsQualityUpdateProfiles' -Method POST -Body $body
    return "$($r.id)"
}

# Neuer Update-Ring (ohne Zuweisung). Feature-Aufschub 0 - die Zielversion kommt ueber das Feature-Update-Profil.
# Felder laut Graph beta windowsUpdateForBusinessConfiguration; Zeiten als 'HH:mm'.
function New-HUWuRing {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name,
        [ValidateRange(0, 30)][int]$QualityDeferral = 3, [ValidateRange(0, 30)][int]$QualityDeadline = 3, [ValidateRange(0, 30)][int]$FeatureDeadline = 7,
        [ValidateRange(0, 7)][int]$Grace = 2, [string]$ActiveStart = '07:00', [string]$ActiveEnd = '15:00', [bool]$UserPause = $false, [string]$Description = '', [bool]$AllowWin11 = $false)
    $body = New-HUWuRingBody -Name $Name -QualityDeferral $QualityDeferral -QualityDeadline $QualityDeadline -FeatureDeadline $FeatureDeadline -Grace $Grace -ActiveStart $ActiveStart -ActiveEnd $ActiveEnd -UserPause $UserPause -Description $Description -AllowWin11 $AllowWin11
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/deviceConfigurations' -Method POST -Body $body
    return "$($r.id)"
}

function New-HUWuRingBody([string]$Name, [int]$QualityDeferral, [int]$QualityDeadline, [int]$FeatureDeadline, [int]$Grace, [string]$ActiveStart, [string]$ActiveEnd, [bool]$UserPause, [string]$Description = '', [bool]$AllowWin11 = $false) {
    $tm = { param($t) $d = [datetime]::MinValue; if (-not [datetime]::TryParseExact("$t".Trim(), [string[]]@('HH:mm', 'H:mm'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { throw "Uhrzeit '$t' ungueltig (HH:mm)" }; $d.ToString('HH:mm') + ':00.0000000' }
    return @{
        '@odata.type' = '#microsoft.graph.windowsUpdateForBusinessConfiguration'; displayName = $Name; description = $Description; roleScopeTagIds = @('0')
        automaticUpdateMode = 'autoInstallAtMaintenanceTime'; microsoftUpdateServiceAllowed = $true; driversExcluded = $false; businessReadyUpdatesOnly = 'all'
        qualityUpdatesDeferralPeriodInDays = $QualityDeferral; featureUpdatesDeferralPeriodInDays = 0; qualityUpdatesPaused = $false; featureUpdatesPaused = $false
        deadlineForQualityUpdatesInDays = $QualityDeadline; deadlineForFeatureUpdatesInDays = $FeatureDeadline; deadlineGracePeriodInDays = $Grace; postponeRebootUntilAfterDeadline = $false
        skipChecksBeforeRestart = $false; featureUpdatesRollbackWindowInDays = 10; allowWindows11Upgrade = $AllowWin11   # 074 B10: Standard aus
        userPauseAccess = $(if ($UserPause) { 'enabled' } else { 'disabled' }); userWindowsUpdateScanAccess = 'enabled'; updateNotificationLevel = 'defaultNotifications'
        installationSchedule = @{ '@odata.type' = '#microsoft.graph.windowsUpdateActiveHoursInstall'; activeHoursStart = (& $tm $ActiveStart); activeHoursEnd = (& $tm $ActiveEnd) }
    }
}

# Neue Treiber-Richtlinie (ohne Zuweisung). Aufschub gilt nur bei automatischer Freigabe.
function New-HUWuDriverProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name,
        [ValidateSet('automatic', 'manual')][string]$Approval = 'automatic', [ValidateRange(0, 30)][int]$DeferDays = 7, [string]$Description = '')
    $body = @{ '@odata.type' = '#microsoft.graph.windowsDriverUpdateProfile'; displayName = $Name; description = $Description; approvalType = $Approval; roleScopeTagIds = @('0') }
    if ($Approval -eq 'automatic') { $body.deploymentDeferralInDays = $DeferDays }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsDriverUpdateProfiles' -Method POST -Body $body
    return "$($r.id)"
}

# --- Sichern / Importieren (JSON-Datei, ohne Zuweisungen) ---
$script:HUWuExportSkip = @('id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'assignments', 'supportsScopeTags', 'roleScopeTagIds',
    'deviceManagementApplicabilityRuleOsEdition', 'deviceManagementApplicabilityRuleOsVersion', 'deviceManagementApplicabilityRuleDeviceMode',
    'deviceReporting', 'newUpdates', 'inventorySyncStatus', 'releaseDateDisplayName', 'deployableContentDisplayName', 'endOfSupportDate',
    'qualityUpdatesPauseStartDate', 'featureUpdatesPauseStartDate', 'qualityUpdatesPauseExpiryDateTime', 'featureUpdatesPauseExpiryDateTime',
    'qualityUpdatesRollbackStartDateTime', 'featureUpdatesRollbackStartDateTime', 'qualityUpdatesWillBeRolledBack', 'featureUpdatesWillBeRolledBack')

# Graph-Objekt -> Body zum Neuanlegen (Verwaltungsfelder weg, Pause aus, alte Verteilzeitraeume weg)
function ConvertTo-HUWuExportBody([string]$Art, $Raw, [datetime]$Now = (Get-Date)) {
    $ep = Get-HUWuEpInfo $Art
    $b = @{ '@odata.type' = $ep.Type }   # Hashtable: Invoke-HUIntuneGraph will [hashtable]
    foreach ($pp in @($Raw.PSObject.Properties)) {
        $n = "$($pp.Name)"
        if ($n -like '*@odata*' -or $n -eq '@odata.type' -or $script:HUWuExportSkip -contains $n) { continue }
        $b[$n] = $pp.Value
    }
    if ($Art -eq 'Update-Ring') { $b['qualityUpdatesPaused'] = $false; $b['featureUpdatesPaused'] = $false }
    if ($b.ContainsKey('rolloutSettings')) {
        $st = $(if ($b['rolloutSettings']) { Get-HUWuDate $b['rolloutSettings'].offerStartDateTimeInUTC } else { $null })
        if (-not $st -or $st -lt $Now) { $b.Remove('rolloutSettings') }   # Zeitraum liegt in der Vergangenheit -> sofort verfuegbar
    }
    return $b
}

function New-HUWuExportDoc([object[]]$Rows, [hashtable]$Names = @{}, [datetime]$Now = (Get-Date)) {
    $seen = @{}
    $items = @(foreach ($r in @($Rows)) {
            $k = "$($r.Art)|$($r.Name)"
            if ($seen.ContainsKey($k) -or -not $r.Raw) { continue }
            $seen[$k] = 1
            # Werte vorher berechnen: $(if ...) direkt im [ordered]-Literal wirft "Argument types do not match"
            $q = "$($r.Tenant)"; if ($Names.ContainsKey($q)) { $q = "$($Names[$q])" }
            $body = ConvertTo-HUWuExportBody $r.Art $r.Raw $Now
            [pscustomobject]@{ Art = "$($r.Art)"; Name = "$($r.Name)"; Quelle = $q; Body = $body }
        })
    return [pscustomobject]@{ Format = 'HU-WinUpdates'; FormatVersion = 1; Erstellt = $Now.ToString('yyyy-MM-dd HH:mm'); Items = $items }
}

# Datei lesen und pruefen. Rueckgabe: Liste @{ Art; Name; Quelle; Body(hashtable) }
# 074 B3: Datei hoechstens 1 MB und 50 Eintraege; Verwaltungsfelder, Zuweisungen und fremde @odata-Angaben werden verworfen,
# Name ohne Steuerzeichen (max. 120). Angelegt wird immer unter dem angezeigten Namen.
function Read-HUWuExportFile([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 1MB) { throw 'Datei zu gross (max. 1 MB) - keine WIN-Updates-Vorlage' }
    $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ("$($j.Format)" -ne 'HU-WinUpdates') { throw 'Keine WIN-Updates-Sicherung (Format fehlt)' }
    if (@($j.Items).Count -gt 50) { throw 'Zu viele Eintraege (max. 50)' }
    return @(foreach ($it in @($j.Items)) {
            if (-not $script:HUWuEp.ContainsKey("$($it.Art)") -or -not "$($it.Name)") { continue }
            $name = ([regex]::Replace("$($it.Name)", '[\p{Cc}\p{Cf}]', ' ') -replace '\s+', ' ').Trim()
            if ($name.Length -gt 120) { $name = $name.Substring(0, 120) }
            if (-not $name) { continue }
            $h = @{}
            foreach ($pp in @($it.Body.PSObject.Properties)) {
                $n = "$($pp.Name)"
                if ($n -like '*@odata*' -or $script:HUWuExportSkip -contains $n) { continue }
                $h[$n] = $pp.Value
            }
            $h['@odata.type'] = (Get-HUWuEpInfo "$($it.Art)").Type
            $h['roleScopeTagIds'] = @('0')
            $h['displayName'] = $name
            [pscustomobject]@{ Art = "$($it.Art)"; Name = $name; Quelle = "$($it.Quelle)"; Body = $h }
        })
}

# Aus Sicherung anlegen (ohne Zuweisung). Name optional ueberschreiben.
function New-HUWuFromBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Art, [Parameter(Mandatory)]$Body, [string]$Name = '')
    $b = @{}; foreach ($k in @($Body.Keys)) { $b[$k] = $Body[$k] }
    if ($Name) { $b['displayName'] = $Name }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint (Get-HUWuEpInfo $Art).Ep -Method POST -Body $b
    return "$($r.id)"
}

# Treiber: approve | decline | suspend fuer mehrere Treiber einer Richtlinie. Rueckgabe: bulkDriverActionResult
function Invoke-HUWuDriverAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$ProfileId,
        [ValidateSet('approve', 'decline', 'suspend')][string]$Action, [Parameter(Mandatory)][string[]]$DriverIds, [datetime]$Date = (Get-Date))
    $body = @{ actionName = $Action; driverIds = @($DriverIds) }
    if ($Action -eq 'approve') { $body.deploymentDate = $Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $r = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/windowsDriverUpdateProfiles/$ProfileId/executeAction" -Method POST -Body $body
    if ($r -and $r.PSObject.Properties['value']) { return $r.value }
    return $r
}

# Profil loeschen (vorher sichern, samt Zuweisungen). 074 B1: zugewiesene Update-Ringe nie;
# zugewiesene Feature- und Treiber-Profile nur mit -Force (App: zweite Rueckfrage; MCP: nie).
function Remove-HUWuProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Art, [Parameter(Mandatory)][string]$Id, [string]$BackupRoot = '', [switch]$Force)
    $e = Get-HUWuEpInfo $Art
    # frisch nachgesehen, nicht aus der Anzeige
    $asg = @(Get-HUWuAssignmentsFresh $TenantKey $Settings $Art $Id)
    if ($asg.Count) {
        if ($Art -eq 'Update-Ring') { throw 'Update-Ring ist zugewiesen - erst die Zuweisungen entfernen, dann loeschen' }
        if ($Art -in 'Feature-Update', 'Treiber-Update' -and -not $Force) { throw "$Art ist zugewiesen ($($asg.Count) Zuweisung(en)) - erst die Zuweisungen entfernen, dann loeschen" }
    }
    $before = Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id"
    $f = Save-HUWuBefore $TenantKey $Art $before $BackupRoot $asg
    [void](Invoke-HUIntuneGraph -TenantKey $TenantKey -Settings $Settings -Endpoint "$($e.Ep)/$Id" -Method DELETE)
    return $f
}

# Zeilen gleicher Art+Name ueber Tenants zusammenfassen (wie Wartung > In Intune)
function Get-HUWuPolicyGroups([object[]]$Inventories, [hashtable]$TenantNames = @{}) {
    $all = @($Inventories | Where-Object { $_ } | ForEach-Object { @($_.Policies) })
    foreach ($g in @($all | Group-Object { "$($_.Art)|$("$($_.Name)".ToLower())" } | Sort-Object Name)) {
        $items = @($g.Group)
        $f = $items[0]
        $tn = @($items | ForEach-Object { if ($TenantNames.ContainsKey($_.Tenant)) { $TenantNames[$_.Tenant] } else { $_.Tenant } })
        $sets = @($items | ForEach-Object { $_.Einstellung } | Select-Object -Unique)
        $asg = @($items | ForEach-Object { $_.Zuweisung } | Select-Object -Unique)
        [pscustomobject]@{
            Key = "$($g.Name)"; Art = $f.Art; Name = $f.Name; Tenants = ($tn -join ', ')
            Einstellung = $(if ($sets.Count -le 1) { $sets[0] } else { "je Tenant verschieden ($($sets.Count))" })
            Pause = (@($items | ForEach-Object { $_.Pause } | Where-Object { $_ } | Select-Object -Unique) -join '; ')
            Zuweisung = $(if ($asg.Count -le 1) { $asg[0] } else { 'je Tenant verschieden' })
            Hinweis = (@($items | ForEach-Object { $_.Hinweis } | Where-Object { $_ } | Select-Object -Unique) -join '; ')
            Items = $items
        }
    }
}

Export-ModuleMember -Function ConvertTo-HUWuExportBody, New-HUWuExportDoc, Read-HUWuExportFile, New-HUWuFromBody, New-HUWuRing, New-HUWuRingBody, New-HUWuDriverProfile, Get-HUWuEpInfo, Save-HUWuBefore, ConvertTo-HUWuTarget, Get-HUWuTargetKey, Set-HUWuAssignment, Set-HUWuSettings, Set-HUWuRingPause,
    Get-HUWuCatalogChoices, New-HUWuFeatureProfile, Remove-HUWuProfile, Get-HUWuAssignmentsFresh, ConvertTo-HUWuRollout, New-HUWuExpedite, Invoke-HUWuDriverAction, Get-HUWuPolicyGroups,
    ConvertTo-HUWuJoinText, ConvertTo-HUWuDriverRow, Get-HUWuDriverMatrix, Get-HUWuBuildInfo, ConvertFrom-HUWuCatalog, Get-HUWuPatchState, Get-HUWuMissingCount, Get-HUWuLatestText, Get-HUWuInventory,
    ConvertTo-HUWuPolicyRow, Get-HUWuMatrix, Get-HUWuSummary, Get-HUWuAssignText
