#Requires -Version 5.1
<#
.SYNOPSIS
    Windows-Updates ueber mehrere Tenants (2.6.3, Schritt 1: nur lesen): Versionen und Patchstand der Geraete,
    Update-Ringe, Feature-, Qualitaets- und Treiber-Update-Profile mit Zuweisungen und Pausen.
.DESCRIPTION
    Graph (beta, nur lesend):
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
    return ($t -join ', ')
}

# Alles eines Tenants lesen. Fehler einzelner Teile landen in Errors (der Rest bleibt nutzbar).
function Get-HUWuInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantKey, [Parameter(Mandatory)]$Settings, [hashtable]$Catalog = $null, [datetime]$Now = (Get-Date))
    $inv = [pscustomobject]@{ Tenant = $TenantKey; Devices = @(); Policies = @(); Drivers = @(); Catalog = $Catalog; Errors = (New-Object System.Collections.Generic.List[string]) }
    $err = { param($what, $e) $m = "$($e.Exception.Message)"; if ($m -match '403|Forbidden|Authorization') { $m = 'Berechtigung fehlt' } elseif ($m -match '(?i)licen') { $m += ' (Windows-Lizenzueberpruefung?)' }; $inv.Errors.Add("${what}: $m") }
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
    } catch { & $err 'Geraete' $_ }
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
                $asg = @(); try { $asg = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "$($src.Ep)/$($o.id)/assignments") } catch { }
                $raw.Add(@{ Art = $src.Art; O = $o; Asg = $asg })
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
    $inv.Policies = @(foreach ($x in $raw) { ConvertTo-HUWuPolicyRow -Tenant $TenantKey -Art $x.Art -O $x.O -Asg $x.Asg -Names $names -Now $Now })
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
            $set = $(if ($ex) { "beschleunigt: $($ex.qualityUpdateRelease), Neustart nach $($ex.daysUntilForcedReboot) T." } else { 'Qualitaets-Update-Profil' })
            $warn = 'Expedite nach dem Ausrollen wieder entfernen (Microsoft-Empfehlung)'
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
    return [pscustomobject]@{ Tenant = $Tenant; Art = $Art; Name = $name; Einstellung = $set; Pause = $pause; Zuweisung = (Get-HUWuAssignText $Asg $Names); Hinweis = $warn; Id = "$($O.id)" }
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
        foreach ($i in $invs) {
            $col = $(if ($TenantNames.ContainsKey($i.Tenant)) { $TenantNames[$i.Tenant] } else { $i.Tenant })
            $x = @($g.Group | Where-Object { $_.Tenant -eq $i.Tenant })
            $o[$col] = $(if ($x.Count) { "$(($x | Measure-Object Geraete -Sum).Sum) ($(@($x | ForEach-Object { $_.Status } | Select-Object -Unique) -join '/'))" } else { '' })
        }
        $o['Geraete'] = ($g.Group | Measure-Object Geraete -Sum).Sum
        $o['Status'] = (@($g.Group | ForEach-Object { $_.Status } | Select-Object -Unique) -join '/')
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
        foreach ($i in $invs) {
            $d = @($i.Devices | Where-Object { $_.Version -eq $l })
            $col = $(if ($TenantNames.ContainsKey($i.Tenant)) { $TenantNames[$i.Tenant] } else { $i.Tenant })
            $o[$col] = $(if ($d.Count) { "$($d.Count) ($(@($d | Where-Object Patchstand -eq 'aktuell').Count) aktuell)" } else { '' })
        }
        $o['Gesamt'] = $all.Count
        $o['Aktuell %'] = $(if ($all.Count) { [int][Math]::Round(100 * @($all | Where-Object Patchstand -eq 'aktuell').Count / $all.Count) } else { 0 })
        # Support: letzter Sicherheitspatch der Version aelter als ~2,5 Monate = Microsoft liefert nichts mehr
        $last = $null
        if ($b -and $cat -and $cat.ContainsKey($b)) { $last = @(@($cat[$b]) | Where-Object { $_.Security -and $_.Date } | Sort-Object Date -Descending | Select-Object -First 1)[0] }
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
        Ampel = $(if (-not $n) { 'grau' } elseif ($alt -gt [Math]::Max(2, $n * 0.1)) { 'rot' } elseif ($alt -or $zur -gt $n * 0.2) { 'gelb' } else { 'gruen' })
    }
}

Export-ModuleMember -Function ConvertTo-HUWuJoinText, ConvertTo-HUWuDriverRow, Get-HUWuDriverMatrix, Get-HUWuBuildInfo, ConvertFrom-HUWuCatalog, Get-HUWuPatchState, Get-HUWuMissingCount, Get-HUWuLatestText, Get-HUWuInventory,
    ConvertTo-HUWuPolicyRow, Get-HUWuMatrix, Get-HUWuSummary, Get-HUWuAssignText
