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
}
# Patchstand: "aktuell" = neuestes Sicherheitsupdate des Builds; "zurueck" = hoechstens so viele Tage aelter
$script:HUWuLagDays = 40
$script:HUWuStaleDays = 30

# '10.0.26200.6899' -> @{ Build; Ubr; Product; Version; Label }
function Get-HUWuBuildInfo([string]$OsVersion) {
    $r = [pscustomobject]@{ Build = 0; Ubr = 0; Product = ''; Version = ''; Label = 'unbekannt' }
    $p = @("$OsVersion".Trim() -split '\.')
    if ($p.Count -lt 3) { return $r }
    $b = 0; $u = 0
    if (-not [int]::TryParse($p[2], [ref]$b)) { return $r }
    if ($p.Count -ge 4) { [void][int]::TryParse($p[3], [ref]$u) }
    $r.Build = $b; $r.Ubr = $u
    if ($script:HUWuBuilds.ContainsKey($b)) { $r.Product = $script:HUWuBuilds[$b][0]; $r.Version = $script:HUWuBuilds[$b][1] }
    else { $r.Product = $(if ($b -ge 22000) { 'Windows 11' } else { 'Windows 10' }); $r.Version = "Build $b" }
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
            $map[$b].Add([pscustomobject]@{ Ubr = $u; Date = $d; Security = $sec; Name = "$($it.displayName)"; Kb = "$($it.kbArticleId)" })
        }
    }
    $out = @{}
    foreach ($k in $map.Keys) { $out[$k] = @($map[$k] | Sort-Object Ubr -Descending) }
    return $out
}

# Patchstand eines Geraets: aktuell | zurueck | veraltet | unbekannt (Katalog fehlt oder Build nicht darin)
function Get-HUWuPatchState($Info, [hashtable]$Catalog) {
    if (-not $Info -or -not $Info.Build -or -not $Catalog -or -not $Catalog.ContainsKey($Info.Build)) { return 'unbekannt' }
    $revs = @($Catalog[$Info.Build])
    $latest = @($revs | Where-Object { $_.Security } | Select-Object -First 1)[0]
    if (-not $latest) { $latest = $revs[0] }
    if ($Info.Ubr -ge $latest.Ubr) { return 'aktuell' }
    # Datum des installierten Stands: groesste bekannte Revision <= installierte
    $own = @($revs | Where-Object { $_.Ubr -le $Info.Ubr } | Select-Object -First 1)[0]
    if (-not $own -or -not $own.Date -or -not $latest.Date) { return 'veraltet' }
    if (($latest.Date - $own.Date).TotalDays -le $script:HUWuLagDays) { return 'zurueck' }
    return 'veraltet'
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
    $inv = [pscustomobject]@{ Tenant = $TenantKey; Devices = @(); Policies = @(); Catalog = $Catalog; Errors = (New-Object System.Collections.Generic.List[string]) }
    $err = { param($what, $e) $m = "$($e.Exception.Message)"; if ($m -match '403|Forbidden|Authorization') { $m = 'Berechtigung fehlt' } elseif ($m -match '(?i)licen') { $m += ' (Windows-Lizenzueberpruefung?)' }; $inv.Errors.Add("${what}: $m") }
    # Katalog (je Tenant gleich - wird nur einmal gelesen und weitergereicht)
    if (-not $inv.Catalog) {
        try { $inv.Catalog = ConvertFrom-HUWuCatalog @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/deviceManagement/windowsUpdateCatalogItems') }
        catch { & $err 'Update-Katalog' $_; $inv.Catalog = @{} }
    }
    # Geraete
    try {
        $sel = 'id,deviceName,osVersion,lastSyncDateTime,userPrincipalName,managedDeviceOwnerType,model,operatingSystem'
        $devs = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint "/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=$sel")
        $inv.Devices = @(foreach ($d in $devs) {
                $bi = Get-HUWuBuildInfo "$($d.osVersion)"
                $sync = Get-HUWuDate $d.lastSyncDateTime
                [pscustomobject]@{
                    Tenant = $TenantKey; Geraet = "$($d.deviceName)"; Benutzer = "$($d.userPrincipalName)"; Version = $bi.Label; Build = "$($d.osVersion)"
                    Patchstand = (Get-HUWuPatchState $bi $inv.Catalog); LetzterSync = $(if ($sync) { $sync.ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { '' })
                    OhneSync = [bool](-not $sync -or ($Now - $sync).TotalDays -gt $script:HUWuStaleDays)
                    Besitz = "$($d.managedDeviceOwnerType)"; Modell = "$($d.model)"; BuildNr = $bi.Build; Id = "$($d.id)"
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
            $set = "Qualitaet $(& $g 'qualityUpdatesDeferralPeriodInDays') T., Feature $(& $g 'featureUpdatesDeferralPeriodInDays') T.; Frist $(& $g 'deadlineForQualityUpdatesInDays')/$(& $g 'deadlineForFeatureUpdatesInDays') T."
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
        'Treiber-Update' { $set = "Freigabe: $(& $g 'approvalType')$(if ($null -ne (& $g 'deploymentDeferralInDays')) { ", Aufschub $(& $g 'deploymentDeferralInDays') T." })" }
    }
    $name = "$(& $g 'displayName')"
    return [pscustomobject]@{ Tenant = $Tenant; Art = $Art; Name = $name; Einstellung = $set; Pause = $pause; Zuweisung = (Get-HUWuAssignText $Asg $Names); Hinweis = $warn; Id = "$($O.id)" }
}

# Uebersicht: je Version eine Zeile, je Tenant "Anzahl (davon aktuell)"; dazu Summen fuer Patchstand und ohne Sync
function Get-HUWuMatrix([object[]]$Inventories, [hashtable]$TenantNames = @{}) {
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
        Text = "$n Geraete: $akt aktuell, $zur 1 Monat zurueck, $alt aelter$(if ($ohne) { ", $ohne ohne Sync > $($script:HUWuStaleDays) T." })"
        Haupt = $(if ($top) { "meist $($top.Name)" } else { '' })
        Total = $n; Current = $akt; Behind = $zur; Old = $alt; Stale = $ohne
        Ampel = $(if (-not $n) { 'grau' } elseif ($alt -gt [Math]::Max(2, $n * 0.1)) { 'rot' } elseif ($alt -or $zur -gt $n * 0.2) { 'gelb' } else { 'gruen' })
    }
}

Export-ModuleMember -Function Get-HUWuBuildInfo, ConvertFrom-HUWuCatalog, Get-HUWuPatchState, Get-HUWuLatestText, Get-HUWuInventory,
    ConvertTo-HUWuPolicyRow, Get-HUWuMatrix, Get-HUWuSummary, Get-HUWuAssignText
