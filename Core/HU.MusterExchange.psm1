#Requires -Version 5.1
<#
.SYNOPSIS
    Muster-Pakete austauschen (2.5.7): Export als .humuster (ZIP), Import mit Schutz, JSON-Import aus Portal und Community.
.DESCRIPTION
    Konzept: Muster-Export-Import 2.5.7 (Projekt-Doku), Pruefungen 056 und 067.
    - Bereinigung (Export und Import gleich): keine Zuweisungen, Benutzer, IP-Bereiche, Pruefer, Metadaten, Bereichsmarkierungen
      (-> Standard 0), Benachrichtigungen; Gruppen nur als Name (Platzhalter fuer das Anwenden); Geheimnisse, fremde Kennungen,
      Tenant-IDs und Domains, Profile mit Zertifikat/WLAN/VPN -> Eintrag gesperrt.
    - Import: Groesse, Anzahl, entpackte Groesse (beim Lesen gezaehlt), Kompressionsrate, JSON-Tiefe (eigene Pruefung - PS 5.1
      kennt -Depth beim Lesen nicht), doppelte JSON-Schluessel, Pfade (.., absolut, Laufwerk, :, reservierte Namen, Punkt/Leerzeichen
      am Ende, Doppelte nach Gross/klein und Unicode), verschluesselte Eintraege, Pruefsummen, Format und Mindestversion.
    - Importierte Pakete sind "ungeprueft"; Anwenden erst nach Bestaetigung in der Pruefansicht (Udo 27.10.).
    Schreibt nie in einen Tenant.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Braucht HU.Intune (Backup-JSON), HU.Transfer (Geheimnisse, fremde
    Kennungen) und HU.Muster (Bibliothek).
#>

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ Grenzen ------------------------------------------------------------------
$script:HUMxLimits = @{ EntryBytes = 5MB; ArchiveBytes = 20MB; Files = 2000; TotalBytes = 100MB; Ratio = 100; Depth = 64; JsonBytes = 20MB; JsonFiles = 200 }
$script:HUMxFormat = 1
$script:HUMxSource = 'importiert'

# Arten, die exportiert werden duerfen (Entra-Einstellung nur diese Kennungen)
$script:HUMxTypes = @('Conditional Access', 'Benannter Ort', 'Authentifizierungsstaerke', 'Entra-Einstellung', 'Verzeichniseinstellung', 'Compliance',
    'Einstellungskatalog', 'Konfiguration', 'Administrative Vorlage', 'Feature-Update', 'Plattform-Skript', 'Wartung')
$script:HUMxEntraIds = @('authorizationPolicy', 'adminConsentRequestPolicy', 'securityDefaults', 'authenticationMethodsPolicy')
$script:HUMxScriptTypes = @('Plattform-Skript', 'Wartung')
# erlaubter @odata.type auf oberster Ebene je Art (fehlt er, ist das auch in Ordnung)
$script:HUMxOdata = @{
    'Conditional Access'        = '^#microsoft\.graph\.conditionalAccessPolicy$'
    'Benannter Ort'             = '^#microsoft\.graph\.(countryNamedLocation|ipNamedLocation)$'
    'Authentifizierungsstaerke' = '^#microsoft\.graph\.authenticationStrengthPolicy$'
    'Entra-Einstellung'         = '^#microsoft\.graph\.(authorizationPolicy|adminConsentRequestPolicy|identitySecurityDefaultsEnforcementPolicy|authenticationMethodsPolicy)$'
    'Verzeichniseinstellung'    = '^#microsoft\.graph\.groupSetting$'
    'Compliance'                = '^#microsoft\.graph\.[A-Za-z0-9]+CompliancePolicy$'
    'Einstellungskatalog'       = '^#microsoft\.graph\.deviceManagementConfigurationPolicy$'
    'Konfiguration'             = '^#microsoft\.graph\.[A-Za-z0-9]+$'
    'Administrative Vorlage'    = '^#microsoft\.graph\.groupPolicyConfiguration$'
    'Feature-Update'            = '^#microsoft\.graph\.windowsFeatureUpdateProfile$'
    'Plattform-Skript'          = '^#microsoft\.graph\.deviceManagementScript$'
    'Wartung'                   = '^#microsoft\.graph\.deviceHealthScript$'
}
# Profile mit Zertifikat, WLAN, VPN, abgeleiteten Anmeldedaten (067 B1d) - nie exportiert
$script:HUMxRefTypes = '(?i)(wifi|wi-fi|vpn|wired|scep|pkcs|derivedcredential|certificate|trustedroot|importedpfx)'
# Metadaten, die nie mitgehen (in jeder Tiefe)
$script:HUMxMetaNames = @('createdDateTime', 'lastModifiedDateTime', 'modifiedDateTime', 'createdBy', 'lastModifiedBy', 'version', 'deletedDateTime', 'creationSource',
    'createdByAppId', 'lastModifiedByAppId', 'supportsScopeTags', 'isAssigned', 'assignments', 'deviceStatuses', 'userStatuses', 'deviceStatusOverview', 'userStatusOverview',
    'deviceSettingStateSummaries', 'settingCount', 'priorityMetaData')
# OMA-URI-Pfade, die WLAN-/VPN-Profile oder Zertifikate tragen (068 B2)
$script:HUMxOmaBlock = '(?i)/(WiFi|VPNv2|ClientCertificateInstall|RootCATrustedCertificates|CertificateStore|PassportForWork|eUICCs)/'
$script:HUMxGuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:HUMxUserKeywords = @('All', 'None', 'GuestsOrExternalUsers')
$script:HUMxBaseFiles = @('manifest.json', 'paket.json', 'index.json', 'names.json')

function Get-HUMxLimits { return $script:HUMxLimits.Clone() }
function Get-HUMxImportSource { return $script:HUMxSource }

# ------------------------------------------------------------------ Hilfen ------------------------------------------------------------------
function Get-HUMxProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] }; return $null }
    $p = $Obj.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null
}
function Set-HUMxProp($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value } else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function Remove-HUMxProp($Obj, [string]$Name) { if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties.Remove($Name); return $true }; return $false }
function Copy-HUMxObject($Obj) { if ($null -eq $Obj) { return $null }; return ($Obj | ConvertTo-Json -Depth 64 -Compress | ConvertFrom-Json) }

function Get-HUMxSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# Dateiname aus einem Titel (067 B6): nur sichere Zeichen, kurz
# 072 G21: Freitext aus fremden Dateien (Herausgeber, Titel, Kategorie, Tags) - Steuer- und Richtungszeichen raus,
# Leerraum zusammenfassen, Laenge begrenzen. Angezeigt wird es nur als Angabe (nicht verifiziert).
function ConvertTo-HUMxPlainText([string]$Text, [int]$Max = 200) {
    $t = [regex]::Replace("$Text", '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ')
    $t = [regex]::Replace($t, '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).TrimEnd() + '...' }
    return $t
}

function ConvertTo-HUMxFileName([string]$Title, [datetime]$Now = (Get-Date)) {
    $t = ("$Title" -replace '[^\p{L}\p{Nd} ._()-]', '_') -replace '\s+', ' '
    $t = $t.Trim(' ', '.', '_')
    if (-not $t) { $t = 'Muster' }
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60).Trim(' ', '.', '_') }
    return "$($t)_$($Now.ToString('yyyy-MM-dd')).humuster"
}

# Kennungen und Domains der eigenen Tenants (Werte damit -> Eintrag gesperrt)
function Get-HUMxTenantMarkers($Settings) {
    $m = New-Object System.Collections.Generic.List[string]
    foreach ($t in @($Settings.tenants | Where-Object { $_ })) {
        foreach ($f in 'tenantId', 'domain', 'defaultDomain', 'primaryDomain', 'appId', 'clientId') {
            $v = "$(Get-HUMxProp $t $f)".Trim()
            if ($v -and $v -notmatch '[<>]' -and $v.Length -ge 6) { $m.Add($v.ToLowerInvariant()) }
        }
        foreach ($d in @(Get-HUMxProp $t 'domains')) { $v = "$d".Trim(); if ($v.Length -ge 6) { $m.Add($v.ToLowerInvariant()) } }
    }
    return @($m | Sort-Object -Unique)
}

# alle Textwerte (Pfad = Wert) eines Objekts
function Get-HUMxStrings($Obj, [string]$Path = '') {
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Obj) { return $out.ToArray() }
    if ($Obj -is [string]) { $out.Add([pscustomobject]@{ Path = $Path; Value = $Obj }); return $out.ToArray() }
    if ($Obj -is [ValueType]) { return $out.ToArray() }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Collections.IDictionary])) {
        $i = 0; foreach ($e in $Obj) { foreach ($x in (Get-HUMxStrings $e "$Path[$i]")) { $out.Add($x) }; $i++ }
        return $out.ToArray()
    }
    foreach ($p in $Obj.PSObject.Properties) {
        $pp = $(if ($Path) { "$Path.$($p.Name)" } else { $p.Name })
        # 068 B8: auch Eigenschaftsnamen (frei erfundene Felder in JSON-Dateien) pruefen
        $out.Add([pscustomobject]@{ Path = "$pp (Name)"; Value = "$($p.Name)" })
        foreach ($x in (Get-HUMxStrings $p.Value $pp)) { $out.Add($x) }
    }
    return $out.ToArray()
}

# Metadaten in jeder Tiefe entfernen -> Anzahl
function Remove-HUMxMeta($Obj, [int]$Depth = 0) {
    $n = 0
    if ($null -eq $Obj -or $Obj -is [string] -or $Obj -is [ValueType] -or $Depth -gt 80) { return 0 }
    if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [System.Collections.IDictionary])) { foreach ($e in $Obj) { $n += Remove-HUMxMeta $e ($Depth + 1) }; return $n }
    foreach ($p in @($Obj.PSObject.Properties)) {
        if ($script:HUMxMetaNames -contains $p.Name -or $p.Name -eq '@odata.context' -or $p.Name -like '*@odata.context' -or $p.Name -like '*@odata.navigationLink' -or $p.Name -like '*@odata.associationLink' -or $p.Name -like '*@odata.etag') {
            $Obj.PSObject.Properties.Remove($p.Name); $n++; continue
        }
        $n += Remove-HUMxMeta $p.Value ($Depth + 1)
    }
    return $n
}

# ------------------------------------------------------------------ Bereinigung ------------------------------------------------------------------
# Ein Eintrag -> @{ Obj; Status ('ok'|'gesperrt'); Reasons; Removed; Marks; P2 }
# $GroupNames: Gruppen-Id (klein) -> Name (aus dem Namenskatalog), fuer die Platzhalter beim Anwenden
function Invoke-HUMusterSanitize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Typ, [string]$Id = '', [string]$Name = '', [Parameter(Mandatory)]$Obj, [hashtable]$GroupNames = @{}, [string[]]$TenantMarkers = @(), [switch]$AllowScript)
    $res = [pscustomobject]@{ Obj = $null; Status = 'ok'; Reasons = (New-Object System.Collections.Generic.List[string]); Removed = (New-Object System.Collections.Generic.List[string]); Marks = (New-Object System.Collections.Generic.List[string]); P2 = $false }
    $block = { param([string]$r) $res.Status = 'gesperrt'; if (-not $res.Reasons.Contains($r)) { $res.Reasons.Add($r) } }
    $rem = { param([string]$r) if (-not $res.Removed.Contains($r)) { $res.Removed.Add($r) } }
    $mark = { param([string]$r) if (-not $res.Marks.Contains($r)) { $res.Marks.Add($r) } }
    if ($script:HUMxTypes -notcontains $Typ) { & $block "$Typ wird nicht exportiert (nur Sicherheits- und Geraete-Einstellungen)."; return $res }
    if ($Typ -eq 'Entra-Einstellung' -and $script:HUMxEntraIds -notcontains $Id) { & $block "Entra-Einstellung '$Id' wird nicht exportiert (tenant-eigen)."; return $res }
    $o = Copy-HUMxObject $Obj
    if ($null -eq $o -or $o -is [string] -or $o -is [ValueType] -or $o -is [array]) { & $block 'Eintrag ist kein einzelnes Objekt.'; return $res }
    $res.Obj = $o
    $ot = "$(Get-HUMxProp $o '@odata.type')"
    if ($ot -and -not ($ot -match $script:HUMxOdata[$Typ])) { & $block "Unbekannter Typ '$ot' fuer $Typ." }
    if ($ot -match $script:HUMxRefTypes) { & $block 'Profil mit Zertifikat, WLAN, VPN oder Anmeldedaten - wird nie exportiert.' }
    # Metadaten, eigene Kennung, Zuweisungen
    $nm = Remove-HUMxMeta $o
    if ($nm) { & $rem 'Metadaten und Zuweisungen' }
    if (Remove-HUMxProp $o 'id') { }
    # Bereichsmarkierungen -> Standard (067 B1b)
    if ($o.PSObject.Properties['roleScopeTagIds']) {
        if (@($o.roleScopeTagIds | Where-Object { "$_" -ne '0' }).Count) { & $rem 'Bereichsmarkierungen (auf Standard gesetzt)' }
        $o.roleScopeTagIds = [object[]]@('0')
    }
    switch ($Typ) {
        'Conditional Access' {
            $c = Get-HUMxProp $o 'conditions'; $u = Get-HUMxProp $c 'users'
            if ($u) {
                foreach ($f in 'includeUsers', 'excludeUsers') {
                    $all = @(Get-HUMxProp $u $f | Where-Object { "$_" })
                    $keep = @($all | Where-Object { $script:HUMxUserKeywords -contains "$_" })
                    if ($all.Count -ne $keep.Count) { & $rem 'Benutzer (beim Anwenden: Notfallkonten des Ziels ausgenommen)' }
                    if ($u.PSObject.Properties[$f]) { $u.$f = [object[]]$keep }
                }
                # Gruppen -> Platzhalter (Name), beim Anwenden im Ziel zuordnen
                $hg = New-Object System.Collections.Generic.List[object]
                # 068 B1: Platzhalter aus der Datei nur gueltig (Feld include/excludeGroups, Name Text <= 256) und immer sichtbar
                foreach ($x in @(Get-HUMxProp $o 'huGruppen' | Where-Object { $_ })) {
                    $xf = "$(Get-HUMxProp $x 'feld')"; $xn = Get-HUMxProp $x 'name'
                    if ($xf -notin 'includeGroups', 'excludeGroups' -or $xn -isnot [string] -or -not "$xn".Trim() -or "$xn".Length -gt 256 -or "$xn" -match '[\x00-\x1f]') { & $rem 'ungueltiger Gruppen-Platzhalter aus der Datei'; continue }
                    $hg.Add([pscustomobject]@{ feld = $xf; name = "$xn".Trim() })
                    & $mark "$(if ($xf -eq 'excludeGroups') { 'AUSNAHME-Gruppe' } else { 'Gruppe' }) (aus Datei): $("$xn".Trim())"
                }
                foreach ($f in 'includeGroups', 'excludeGroups') {
                    foreach ($g in @(Get-HUMxProp $u $f | Where-Object { "$_" })) {
                        $gn = if ($GroupNames.ContainsKey("$g".ToLowerInvariant())) { "$($GroupNames["$g".ToLowerInvariant()])" } else { "unbekannte Gruppe $("$g".Substring(0, [Math]::Min(8, "$g".Length)))" }
                        $hg.Add([pscustomobject]@{ feld = $f; name = $gn }); & $mark "$(if ($f -eq 'excludeGroups') { 'AUSNAHME-Gruppe' } else { 'Gruppe' }): $gn"
                    }
                    if ($u.PSObject.Properties[$f] -and @($u.$f).Count) { & $rem 'Gruppen-Kennungen (nur Name, beim Anwenden zuordnen)' }
                    if ($u.PSObject.Properties[$f]) { $u.$f = [object[]]@() }
                }
                if ($hg.Count) { Set-HUMxProp $o 'huGruppen' ([object[]]$hg.ToArray()) }
                # Gaeste bestimmter Tenants (067 B1a): fremde Tenant-Kennungen -> Bedingung entfernen
                foreach ($f in 'includeGuestsOrExternalUsers', 'excludeGuestsOrExternalUsers') {
                    $gx = Get-HUMxProp $u $f
                    if ($gx -and "$(Get-HUMxProp (Get-HUMxProp $gx 'externalTenants') 'membershipKind')" -ne 'all') { [void](Remove-HUMxProp $u $f); & $rem 'Gaeste bestimmter Tenants (Tenant-Kennungen)' }
                }
            }
            $ap = Get-HUMxProp $c 'applications'
            foreach ($f in 'includeApplications', 'excludeApplications') { if (@(Get-HUMxProp $ap $f | Where-Object { "$_" -match $script:HUMxGuidRx }).Count) { & $mark 'App-Kennungen: nur Microsoft-Apps sind in jedem Tenant gleich' } }
            if (@(Get-HUMxProp $ap 'includeAuthenticationContextClassReferences' | Where-Object { "$_" }).Count) { & $mark 'Authentifizierungskontext (muss im Ziel vorhanden sein)' }
            if (@(Get-HUMxProp (Get-HUMxProp $c 'clientApplications') 'includeServicePrincipals' | Where-Object { "$_" }).Count) { & $block 'Workload-Identitaeten (Dienstprinzipale des Tenants).' }
            if (@(Get-HUMxProp (Get-HUMxProp $o 'grantControls') 'termsOfUse' | Where-Object { "$_" }).Count) { & $block 'Nutzungsbedingungen (gibt es nur im eigenen Tenant).' }
            $rule = "$(Get-HUMxProp (Get-HUMxProp (Get-HUMxProp $c 'devices') 'deviceFilter') 'rule')"
            if ($rule) { & $mark "Geraetefilter-Regel: $rule" }
            # 069 B3: Zusatzlizenz noetig -> P2-Kennzeichen (nicht vorgewaehlt), Hinweis je Lizenz
            $lic = [ordered]@{ signInRiskLevels = 'Entra ID P2 (Anmelderisiko)'; userRiskLevels = 'Entra ID P2 (Benutzerrisiko)'; servicePrincipalRiskLevels = 'Workload ID Premium (Dienstprinzipal-Risiko)'; insiderRiskLevels = 'Microsoft Purview Insider-Risiko' }
            $need = @(foreach ($f in $lic.Keys) { if (@(Get-HUMxProp $c $f | Where-Object { "$_" }).Count) { $lic[$f] } })
            if (@(Get-HUMxProp (Get-HUMxProp $c 'clientApplications') 'includeServicePrincipals' | Where-Object { "$_" }).Count -or @(Get-HUMxProp (Get-HUMxProp $c 'clientApplications') 'servicePrincipalFilter' | Where-Object { $_ }).Count) { $need += 'Workload ID Premium (Workload-Identitaeten)' }
            if ($need.Count) { $res.P2 = $true; & $mark "braucht Zusatzlizenz: $(($need | Select-Object -Unique) -join ', ') - mit P1 nicht nutzbar" }
            # Staerke: nur Kennung und Name behalten
            $as = Get-HUMxProp (Get-HUMxProp $o 'grantControls') 'authenticationStrength'
            if ($as) { foreach ($p in @($as.PSObject.Properties | Where-Object { $_.Name -notin 'id', 'displayName' })) { $as.PSObject.Properties.Remove($p.Name) } }
        }
        'Benannter Ort' {
            if ($o.PSObject.Properties['ipRanges']) {
                if (@($o.ipRanges).Count) { & $rem 'IP-Bereiche (beim Anwenden eigene eintragen)' }
                $o.ipRanges = [object[]]@()
            }
        }
        'Entra-Einstellung' {
            if ($Id -eq 'adminConsentRequestPolicy' -and $o.PSObject.Properties['reviewers']) {
                if (@($o.reviewers).Count) { & $rem 'Pruefer der Administratorzustimmung' }
                $o.reviewers = [object[]]@()
            }
        }
        { $_ -in 'Konfiguration', 'Einstellungskatalog' } {
            # 068 B2: Custom-Profile koennen WLAN, VPN und Zertifikate ueber OMA-URI tragen - Pfade sperren, eingebettete Inhalte pruefen
            foreach ($om in @(Get-HUMxProp $o 'omaSettings' | Where-Object { $_ })) {
                $uri = "$(Get-HUMxProp $om 'omaUri')"
                if ($uri -match $script:HUMxOmaBlock) { & $block "OMA-URI mit WLAN, VPN oder Zertifikat ($uri)." }
            }
            foreach ($s0 in @(Get-HUMxStrings $o)) {
                if ($s0.Path -match '(?i)(^|\.)(settingDefinitionId)$' -and "$($s0.Value)" -match '(?i)(wifi|vpnv2|clientcertificateinstall|rootcatrustedcertificates|_wlan_|_vpn_)') { & $block "Einstellung fuer WLAN, VPN oder Zertifikat ($($s0.Value))." }
            }
        }
        'Compliance' {
            # 067 B1c: Benachrichtigungen (Vorlage, CC-Liste) gehoeren dem Tenant
            foreach ($r in @(Get-HUMxProp $o 'scheduledActionsForRule' | Where-Object { $_ })) {
                $cfg = @(Get-HUMxProp $r 'scheduledActionConfigurations' | Where-Object { $_ })
                $keep = @($cfg | Where-Object { "$(Get-HUMxProp $_ 'actionType')" -ne 'notification' })
                if ($keep.Count -ne $cfg.Count) { & $rem 'Benachrichtigungen (Vorlage und CC-Liste)' }
                foreach ($k in $keep) {
                    foreach ($f in 'notificationTemplateId', 'notificationMessageCCList') { if ($k.PSObject.Properties[$f]) { $k.PSObject.Properties.Remove($f) } }
                }
                if ($r.PSObject.Properties['scheduledActionConfigurations']) { $r.scheduledActionConfigurations = [object[]]$keep }
                foreach ($f in 'id') { [void](Remove-HUMxProp $r $f) }
            }
        }
    }
    if ($script:HUMxScriptTypes -contains $Typ) {
        if (-not $AllowScript) { & $block 'Skript - nur nach Ansicht einzeln freigeben.' }
        else {
            $txt = ''
            try { $txt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$(Get-HUMxProp $o 'scriptContent')$(Get-HUMxProp $o 'detectionScriptContent')")) } catch { }
            # 072 (Gemini B3): UTF-16-kodierte Skripte (Nullbytes zwischen den Zeichen) vor der Pruefung bereinigen
            $txt = "$txt" -replace "`0", ''
            if ($txt -match '(?i)(password|passwort|kennwort|secret|apikey|api_key|token)\s*[=:]') { & $block 'Skript enthaelt vermutlich ein Kennwort oder einen Schluessel.' }
        }
    }
    # 068 B2: eingebettete Inhalte (Base64-Werte, z. B. omaSettingBase64, iOS/macOS-payload, Zertifikate) entpacken und pruefen
    foreach ($s1 in @(Get-HUMxStrings $o)) {
        $v = "$($s1.Value)"
        # 072 (Gemini B3): auch kurze Werte pruefen (ab 12 Zeichen; Base64 ab 24), Name und Beschreibung nicht (die markiert die Pruefansicht)
        if ($v.Length -lt 12 -or $s1.Path -match '(?i)(scriptContent|detectionScriptContent|remediationScriptContent)$' -or $s1.Path -match '(?i)(^|\.)(displayName|description)$') { continue }
        $txt = $null
        if ($v.Length -ge 24 -and $v -match '^[A-Za-z0-9+/=\s]+$' -and ($v.Trim().Length % 4) -eq 0) { try { $txt = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v.Trim()))) -replace "`0", '' } catch { $txt = $null } }
        $hay = if ($null -ne $txt) { $txt } else { $v }
        if ($hay -match '(?i)(-----BEGIN|<keyMaterial>|<sharedKey>|PayloadContent.{0,200}pkcs12|\bpassword\b\s*[=:<>]|<Password>|PreSharedKey|\bpsk\b)') { & $block "Eingebetteter Inhalt in '$($s1.Path)' enthaelt Schluessel, Zertifikat oder Kennwort." }
        elseif ($null -ne $txt -and $txt -match '[\x20-\x7e]{20}') { & $mark "eingebetteter Inhalt (Base64) in '$($s1.Path)' - bitte ansehen" }
        if ($null -ne $txt) { foreach ($tm in @($TenantMarkers)) { if ($tm -and $txt.ToLowerInvariant().Contains($tm)) { & $block "Eingebetteter Inhalt in '$($s1.Path)' nennt einen eigenen Tenant." ; break } } }
    }
    # Geheimnisse und fremde Kennungen (wie beim Uebertragen)
    try { foreach ($h in @(Find-HUTrSecrets $o)) { & $block "Geheimer Wert ($h)." } } catch { }
    if ($Typ -ne 'Conditional Access') {
        try {
            $fid = @(Find-HUTrForeignIds $o)
            if ($fid.Count) { & $block "Kennungen aus dem Quell-Tenant ($(@($fid | Select-Object -First 3) -join '; '))." }
        } catch { }
    }
    # Tenant-Kennungen und eigene Domains im Wert
    $strings = @(Get-HUMxStrings $o)
    foreach ($s in $strings) {
        $v = "$($s.Value)".ToLowerInvariant()
        foreach ($tm in @($TenantMarkers)) { if ($tm -and $v.Contains($tm)) { & $block "Kennung oder Domain eines eigenen Tenants in '$($s.Path)'."; break } }
        if ($v -match '[a-z0-9-]+\.onmicrosoft\.com') { & $block "Tenant-Domain in '$($s.Path)'." }
    }
    # Freitexte markieren (067 B1e): Name, Beschreibung, Mail, Links, Pfade
    $dn = "$(Get-HUMxProp $o 'displayName')"; if (-not $dn) { $dn = "$(Get-HUMxProp $o 'name')" }
    if ($dn) { & $mark "Name: $dn" }
    $ds = "$(Get-HUMxProp $o 'description')"; if ($ds) { & $mark "Beschreibung: $(if ($ds.Length -gt 120) { $ds.Substring(0, 120) + ' ...' } else { $ds })" }
    foreach ($s in $strings) {
        $v = "$($s.Value)"
        if ($s.Path -in 'displayName', 'name', 'description', '@odata.type' -or $s.Path.EndsWith(' (Name)')) { continue }
        if ($v -match '@' -and $v -notmatch '^#microsoft') { & $mark "Wert mit @ in '$($s.Path)'" }
        elseif ($v -match '(?i)https?://') { & $mark "Link in '$($s.Path)'" }
        elseif ($v -match '^\\\\') { & $mark "Netzwerkpfad in '$($s.Path)'" }
    }
    return $res
}

# Namenskatalog fuer die Datei: nur Orte und Staerken (Gruppen gehen als Platzhalter im Eintrag mit; Benutzer nie;
# Filter und Bereichsmarkierungen entfallen mit Zuweisungen bzw. Standard-Markierung)
function Get-HUMxCatalog([object[]]$Names) {
    return @(@($Names) | Where-Object { $_ -and "$($_.Art)" -in 'Benannter Ort', 'Authentifizierungsstaerke' -and "$($_.Id)" -and "$($_.Name)" } |
        ForEach-Object { [pscustomobject]@{ Art = "$($_.Art)"; Id = "$($_.Id)"; Name = "$($_.Name)"; Source = $script:HUMxSource } })
}

# ------------------------------------------------------------------ Export ------------------------------------------------------------------
# Plan fuer die Pruefansicht: je Eintrag Status und Gruende, plus Namenskatalog. Schreibt nichts.
function Get-HUMusterExportPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Package, [string[]]$AllowScripts = @())
    $markers = Get-HUMxTenantMarkers $Settings
    $names = @()
    try { $nf = Join-Path $Package.Folder 'names.json'; if (Test-Path -LiteralPath $nf) { $names = @((Read-HUBackupJson $nf).Items) } } catch { }
    $gn = @{}
    foreach ($n in @($names | Where-Object { "$($_.Art)" -eq 'Gruppe' -and "$($_.Id)" -and "$($_.Name)" })) { $gn["$($n.Id)".ToLowerInvariant()] = "$($n.Name)" }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($Package.Items)) {
        $typ = "$($it.Typ)"; $nm = "$($it.Name)"
        $row = [pscustomobject]@{ Typ = $typ; Name = $nm; Id = "$($it.Id)"; Status = 'ok'; Grund = ''; Entfernt = ''; Hinweise = ''; P2 = $false; Obj = $null; IsScript = ($script:HUMxScriptTypes -contains $typ) }
        if (-not "$($it.File)") {
            # nur Namenseintrag (z. B. Bereichsmarkierung, Staerke ohne Datei) - geht nicht mit
            $row.Status = 'entfaellt'; $row.Grund = 'nur Name im Paket, keine Einstellungen'; $rows.Add($row); continue
        }
        try { $obj = Read-HUBackupJson (Join-Path $Package.Folder $it.File) } catch { $row.Status = 'gesperrt'; $row.Grund = "Datei nicht lesbar ($($_.Exception.Message))"; $rows.Add($row); continue }
        $s = Invoke-HUMusterSanitize -Typ $typ -Id "$($it.Id)" -Name $nm -Obj $obj -GroupNames $gn -TenantMarkers $markers -AllowScript:($AllowScripts -contains "$typ|$nm")
        $row.Status = $s.Status; $row.Grund = ($s.Reasons -join ' '); $row.Entfernt = ($s.Removed -join '; '); $row.Hinweise = ($s.Marks -join ' | '); $row.P2 = $s.P2; $row.Obj = $s.Obj
        $rows.Add($row)
    }
    $cat = @(Get-HUMxCatalog $names)
    $origin = "$($Package.Origin)"
    return [pscustomobject]@{
        Package = $Package; Rows = $rows.ToArray(); Names = $cat
        NameMarks = @($cat | ForEach-Object { "$($_.Art): $($_.Name)" })
        Ok = @($rows | Where-Object { $_.Status -eq 'ok' }).Count; Blocked = @($rows | Where-Object { $_.Status -eq 'gesperrt' }).Count
        # 067 B7: importierte Pakete behalten Herkunft und urspruenglichen Herausgeber
        Origin = $(if ($origin -in 'importiert', 'vorlage') { 'importiert' } elseif ($origin -eq 'mitgeliefert') { 'mitgeliefert' } else { 'eigen' })
        OrigPublisher = $(if ($origin -in 'importiert', 'vorlage' -and $Package.PSObject.Properties['Publisher']) { "$($Package.Publisher)" } else { '' })
    }
}

# Plan als .humuster schreiben -> @{ Path; Sha256; Count }
function Save-HUMusterExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Path, [string]$Publisher = '', [string]$Note = '', [Parameter(Mandatory)][string]$AppVersion, [datetime]$Now = (Get-Date))
    $ok = @($Plan.Rows | Where-Object { $_.Status -eq 'ok' -and $_.Obj })
    if (-not $ok.Count) { throw 'Nichts zu exportieren - alle Eintraege sind gesperrt oder ohne Einstellungen.' }
    $p = $Plan.Package
    $files = [ordered]@{}
    $enc = New-Object Text.UTF8Encoding($false)
    $ix = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($r in $ok) {
        $n++
        $f = "$(ConvertTo-HUSafeFileName $r.Typ 40)/$('{0:D3}' -f $n)_$(ConvertTo-HUSafeFileName $r.Name 60).json"
        $files[$f] = $enc.GetBytes(($r.Obj | ConvertTo-Json -Depth 60))
        $xid = $(if ($r.Typ -eq 'Benannter Ort' -and "$($r.Id)" -match $script:HUMxGuidRx) { "$($r.Id)" } else { "export-$('{0:D3}' -f $n)" })
        $ix.Add([pscustomobject]@{ Typ = $r.Typ; Name = $r.Name; Id = $xid; File = $f; Source = $script:HUMxSource; Stand = $Now.ToString('yyyy-MM-dd_HHmmss') })
    }
    $pub = "$Publisher".Trim(); if (-not $pub -and $Plan.OrigPublisher) { $pub = $Plan.OrigPublisher }
    $files['index.json'] = $enc.GetBytes(([pscustomobject]@{ Tenant = '__MUSTER__'; Errors = 0; Complete = $true; FailedTypes = @(); Items = $ix.ToArray() } | ConvertTo-Json -Depth 10))
    $files['names.json'] = $enc.GetBytes(([pscustomobject]@{ Format = 1; Items = @($Plan.Names) } | ConvertTo-Json -Depth 10))
    $cat = $(if ("$($p.CopyCategory)") { "$($p.CopyCategory)" } else { "$($p.Category)" })
    $files['paket.json'] = $enc.GetBytes(([pscustomobject]@{ Format = 1; Title = "$($p.Title)"; Category = $cat; Tags = @($p.Tags); Note = "$($p.Note)"; Learn = @($p.Learn); Complete = [bool]$p.Complete; Origin = $Plan.Origin } | ConvertTo-Json -Depth 10))
    $removed = @{}
    foreach ($r in @($Plan.Rows)) { foreach ($x in @("$($r.Entfernt)" -split '; ' | Where-Object { $_ })) { if ($removed.ContainsKey($x)) { $removed[$x]++ } else { $removed[$x] = 1 } } }
    $man = [pscustomobject]@{
        Format = $script:HUMxFormat; MinApp = '2.5.7'; Exported = $Now.ToUniversalTime().ToString('o'); App = $AppVersion; Publisher = $pub; Note = "$Note"
        Count = $ok.Count; Blocked = @($Plan.Rows | Where-Object { $_.Status -eq 'gesperrt' }).Count
        Removed = @($removed.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Was = $_; Anzahl = $removed[$_] } })
        Files = @($files.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Sha256 = (Get-HUMxSha256 $files[$_]) } })
    }
    $files['manifest.json'] = $enc.GetBytes(($man | ConvertTo-Json -Depth 10))
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $fs = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($k in @('manifest.json') + @($files.Keys | Where-Object { $_ -ne 'manifest.json' })) {
                $e = $zip.CreateEntry($k, [System.IO.Compression.CompressionLevel]::Optimal)
                $s = $e.Open(); try { $s.Write($files[$k], 0, $files[$k].Length) } finally { $s.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    $sha = Get-HUMxSha256 ([IO.File]::ReadAllBytes($Path))
    Write-HULog -Message "Muster-Paket '$($p.Title)' exportiert: $($ok.Count) Eintraege, $($man.Blocked) gesperrt (SHA-256 $sha)" -Level 'OK'
    return [pscustomobject]@{ Path = $Path; Sha256 = $sha; Count = $ok.Count }
}

# ------------------------------------------------------------------ JSON-Pruefung ------------------------------------------------------------------
# Tiefe und doppelte Schluessel pruefen, BEVOR geparst wird (067 B3): PS 5.1 kennt -Depth beim Lesen nicht.
# -> '' (in Ordnung) oder Fehlertext
function Test-HUMxJsonText([string]$Text, [int]$MaxDepth = 64) {
    if ($null -eq $Text) { return 'leer' }
    $depth = 0
    $stack = New-Object System.Collections.Generic.List[object]   # je Ebene: $null (Liste) oder HashSet der Schluessel
    $expectKey = $false
    $i = 0; $len = $Text.Length
    while ($i -lt $len) {
        $ch = $Text[$i]
        if ($ch -eq '"') {
            $sb = New-Object System.Text.StringBuilder   # wie in der Datei (fuer die Meldung)
            $db = New-Object System.Text.StringBuilder   # aufgeloest wie von ConvertFrom-Json (fuer den Vergleich)
            $i++
            $closed = $false
            while ($i -lt $len) {
                $c2 = $Text[$i]
                if ($c2 -eq '\') {
                    if ($i + 1 -ge $len) { $i++; continue }
                    $e = $Text[$i + 1]
                    [void]$sb.Append($c2).Append($e)
                    # 072 (Gemini B1): alle JSON-Escapes aufloesen - "a\/b" ist derselbe Schluessel wie "a/b", "\\u0061" ist kein "a"
                    # (kein continue im switch - das wuerde nur den switch verlassen)
                    $step = 2
                    $hx = $(if ($e -ceq 'u' -and $i + 5 -lt $len) { $Text.Substring($i + 2, 4) } else { '' })
                    if ($e -ceq 'u' -and $hx -match '^[0-9a-fA-F]{4}$') { [void]$sb.Append($hx); [void]$db.Append([char][Convert]::ToInt32($hx, 16)); $step = 6 }
                    elseif ($e -ceq 'b') { [void]$db.Append([char]8) } elseif ($e -ceq 'f') { [void]$db.Append([char]12) } elseif ($e -ceq 'n') { [void]$db.Append("`n") }
                    elseif ($e -ceq 'r') { [void]$db.Append("`r") } elseif ($e -ceq 't') { [void]$db.Append("`t") } else { [void]$db.Append($e) }
                    $i += $step; continue
                }
                if ($c2 -eq '"') { $closed = $true; break }
                [void]$sb.Append($c2); [void]$db.Append($c2); $i++
            }
            if (-not $closed) { return 'Text nicht abgeschlossen' }
            $i++
            if ($expectKey) {
                $j = $i; while ($j -lt $len -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                if ($j -lt $len -and $Text[$j] -eq ':') {
                    $set = $stack[$stack.Count - 1]
                    # gleiche Schluessel auch bei anderer Gross-/Kleinschreibung oder Unicode-Form ablehnen
                    $k = $db.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
                    if ($set -and -not $set.Add($k)) { return "doppelter Schluessel '$($sb.ToString())'" }
                    $expectKey = $false
                }
            }
            continue
        }
        switch ($ch) {
            '{' { $depth++; if ($depth -gt $MaxDepth) { return "zu tief verschachtelt (mehr als $MaxDepth Ebenen)" }; $stack.Add((New-Object 'System.Collections.Generic.HashSet[string]')); $expectKey = $true }
            '[' { $depth++; if ($depth -gt $MaxDepth) { return "zu tief verschachtelt (mehr als $MaxDepth Ebenen)" }; $stack.Add($null); $expectKey = $false }
            '}' { $depth--; if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; $expectKey = $false }
            ']' { $depth--; if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; $expectKey = $false }
            ',' { $expectKey = ($stack.Count -and $null -ne $stack[$stack.Count - 1]) }
            '/' { return 'Kommentare sind nicht erlaubt' }
        }
        if ($depth -lt 0) { return 'Klammern passen nicht' }
        $i++
    }
    if ($depth -ne 0) { return 'Klammern passen nicht' }
    return ''
}

function ConvertFrom-HUMxJson([string]$Text, [string]$What) {
    $t = "$Text".TrimStart([char]0xFEFF)
    $err = Test-HUMxJsonText $t $script:HUMxLimits.Depth
    if ($err) { throw "${What}: $err" }
    try { return ($t | ConvertFrom-Json -ErrorAction Stop) } catch { throw "${What}: kein gueltiges JSON ($($_.Exception.Message))" }
}

# ------------------------------------------------------------------ ZIP-Pruefung ------------------------------------------------------------------
# Name eines ZIP-Eintrags pruefen (067 B2) -> '' oder Fehler
function Test-HUMxEntryName([string]$Name) {
    if (-not $Name) { return 'leerer Name' }
    if ($Name -match '[\x00-\x1f]') { return 'Steuerzeichen im Namen' }
    if ($Name.Contains(':')) { return 'Doppelpunkt (Laufwerk oder NTFS-Stream)' }
    $n = $Name.Replace('\', '/')
    if ($n.StartsWith('/')) { return 'absoluter Pfad' }
    foreach ($seg in $n.Split('/')) {
        if ($seg -eq '') { return 'leerer Pfadteil' }
        if ($seg -in '.', '..') { return 'Pfad mit . oder ..' }
        if ($seg.EndsWith('.') -or $seg.EndsWith(' ')) { return 'Punkt oder Leerzeichen am Ende' }
        if ($seg -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$') { return "reservierter Name '$seg'" }
    }
    return ''
}

# Zentralverzeichnis lesen (Flags, Groessen) - .NET Framework zeigt verschluesselte Eintraege nicht an
function Get-HUMxZipDirectory([byte[]]$Bytes) {
    $len = $Bytes.Length
    $eocd = -1
    for ($i = $len - 22; $i -ge [Math]::Max(0, $len - 22 - 65535); $i--) {
        if ($Bytes[$i] -eq 0x50 -and $Bytes[$i + 1] -eq 0x4B -and $Bytes[$i + 2] -eq 0x05 -and $Bytes[$i + 3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw 'kein ZIP-Archiv (Verzeichnis fehlt)' }
    $count = [BitConverter]::ToUInt16($Bytes, $eocd + 10)
    $off = [BitConverter]::ToUInt32($Bytes, $eocd + 16)
    if ($count -eq 0xFFFF -or $off -eq 0xFFFFFFFF) { throw 'ZIP64 wird nicht unterstuetzt' }
    $out = New-Object System.Collections.Generic.List[object]
    $p = [int64]$off
    for ($k = 0; $k -lt $count; $k++) {
        if ($p + 46 -gt $len -or [BitConverter]::ToUInt32($Bytes, [int]$p) -ne 0x02014B50) { throw 'ZIP-Verzeichnis beschaedigt' }
        $flags = [BitConverter]::ToUInt16($Bytes, [int]$p + 8)
        $csize = [BitConverter]::ToUInt32($Bytes, [int]$p + 20); $usize = [BitConverter]::ToUInt32($Bytes, [int]$p + 24)
        $nl = [BitConverter]::ToUInt16($Bytes, [int]$p + 28); $el = [BitConverter]::ToUInt16($Bytes, [int]$p + 30); $cl = [BitConverter]::ToUInt16($Bytes, [int]$p + 32)
        $extAttr = [BitConverter]::ToUInt32($Bytes, [int]$p + 38)
        $name = [Text.Encoding]::UTF8.GetString($Bytes, [int]$p + 46, $nl)
        $out.Add([pscustomobject]@{ Name = $name; Encrypted = [bool]($flags -band 1); CSize = $csize; USize = $usize; Unix = ($extAttr -shr 16) })
        $p += 46 + $nl + $el + $cl
    }
    return $out.ToArray()
}

# .humuster pruefen und lesen -> @{ Ok; Errors; Manifest; Paket; Index; Names; Entries (Datei -> Objekt); Sha256 }
function Test-HUMusterArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$AppVersion)
    $res = [pscustomobject]@{ Ok = $false; Errors = (New-Object System.Collections.Generic.List[string]); Manifest = $null; Paket = $null; Index = $null; Names = @(); Entries = @{}; Sha256 = '' }
    $L = $script:HUMxLimits
    if ([IO.Path]::GetExtension($Path) -ine '.humuster') { $res.Errors.Add('Nur Dateien mit der Endung .humuster.'); return $res }
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $fi) { $res.Errors.Add('Datei nicht gefunden.'); return $res }
    if ($fi.Length -gt $L.ArchiveBytes) { $res.Errors.Add("Datei zu gross ($([math]::Round($fi.Length / 1MB, 1)) MB, erlaubt $($L.ArchiveBytes / 1MB) MB)."); return $res }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $res.Sha256 = Get-HUMxSha256 $bytes
    try { $dir = @(Get-HUMxZipDirectory $bytes) } catch { $res.Errors.Add("Archiv: $($_.Exception.Message)."); return $res }
    if ($dir.Count -gt $L.Files) { $res.Errors.Add("Zu viele Dateien ($($dir.Count), erlaubt $($L.Files))."); return $res }
    $seen = @{}
    foreach ($d in $dir) {
        $e = Test-HUMxEntryName $d.Name
        if ($e) { $res.Errors.Add("'$($d.Name)': $e."); continue }
        if ($d.Encrypted) { $res.Errors.Add("'$($d.Name)': verschluesselter Eintrag."); continue }
        if ((($d.Unix -band 0xF000) -eq 0xA000)) { $res.Errors.Add("'$($d.Name)': Verknuepfung (Link)."); continue }
        $k = $d.Name.Replace('\', '/').Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
        if ($seen.ContainsKey($k)) { $res.Errors.Add("'$($d.Name)': doppelt (Gross/klein oder Unicode-Form)."); continue }
        $seen[$k] = $true
    }
    if ($res.Errors.Count) { return $res }
    # Inhalte lesen - entpackte Groesse beim Lesen zaehlen, nicht der Angabe im Archiv trauen
    $texts = @{}
    $ms = New-Object IO.MemoryStream(, $bytes)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $total = [int64]0
            # 068 B5: gleiche Liste wie im selbst gelesenen Verzeichnis (Anzahl und Namen) - sonst sehen Pruefung und Lesen verschiedenes
            $zn = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
            $dn = @($dir | ForEach-Object { $_.Name.Replace('\', '/') } | Sort-Object)
            if ($zn.Count -ne $dn.Count -or (($zn -join "`n") -cne ($dn -join "`n"))) { throw 'ZIP-Verzeichnis passt nicht zu den Eintraegen (Namen unterschiedlich kodiert?).' }
            foreach ($ze in $zip.Entries) {
                if ($ze.FullName.EndsWith('/') -and $ze.Length -gt 0) { throw "'$($ze.FullName)': Ordner mit Inhalt." }
                $nm = $ze.FullName.Replace('\', '/')
                if ($nm.EndsWith('/')) { continue }
                $cs = [int64]$ze.CompressedLength
                $limit = [Math]::Min([Math]::Min([int64]$L.TotalBytes - $total, [int64]$L.EntryBytes), [Math]::Max([int64]4096, $cs * $L.Ratio))
                $s = $ze.Open(); $buf = New-Object byte[] 65536; $out = New-Object IO.MemoryStream
                try {
                    while (($r = $s.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $r)
                        if ($out.Length -gt $limit) { throw "'$nm': entpackt zu gross oder zu stark gepackt (Schutz vor ZIP-Bomben)." }
                    }
                } finally { $s.Dispose() }
                $total += $out.Length
                $texts[$nm] = $out.ToArray()
            }
        } finally { $zip.Dispose() }
    } catch { $res.Errors.Add("$($_.Exception.Message)"); return $res } finally { $ms.Dispose() }
    foreach ($b in $script:HUMxBaseFiles) { if (-not $texts.ContainsKey($b)) { $res.Errors.Add("$b fehlt.") } }
    if ($res.Errors.Count) { return $res }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $read = { param([string]$n) ConvertFrom-HUMxJson ($utf8.GetString($texts[$n])) $n }
    try {
        $man = & $read 'manifest.json'
        if ([int]"0$($man.Format)" -ne $script:HUMxFormat) { $res.Errors.Add("Unbekanntes Format ($($man.Format)).") }
        $min = $null; try { $min = [version]"$($man.MinApp)" } catch { }
        if (-not $min) { $res.Errors.Add('Mindestversion fehlt.') }
        elseif ($min -gt [version]$AppVersion) { $res.Errors.Add("Braucht HU-MultiTenant $min (hier $AppVersion) - bitte zuerst aktualisieren.") }
        # Pruefsummen: jede Datei muss im Manifest stehen und passen, jede Angabe muss eine Datei haben
        $listed = @{}
        foreach ($f in @($man.Files)) { $listed["$($f.Name)".Replace('\', '/')] = "$($f.Sha256)".ToLowerInvariant() }
        foreach ($n in @($texts.Keys | Where-Object { $_ -ne 'manifest.json' })) {
            if (-not $listed.ContainsKey($n)) { $res.Errors.Add("'$n' steht nicht im Manifest."); continue }
            if ((Get-HUMxSha256 $texts[$n]) -ne $listed[$n]) { $res.Errors.Add("'$n': Pruefsumme passt nicht (veraendert).") }
        }
        foreach ($n in @($listed.Keys)) { if (-not $texts.ContainsKey($n)) { $res.Errors.Add("'$n' fehlt im Archiv.") } }
        if ($res.Errors.Count) { return $res }
        $res.Manifest = $man
        $res.Paket = & $read 'paket.json'
        $res.Index = & $read 'index.json'
        $res.Names = @((& $read 'names.json').Items | Where-Object { $_ })
        # nur bekannte Dateien: Basisdateien und die Eintraege laut Index
        $want = @{}
        foreach ($it in @($res.Index.Items)) {
            $typ = "$($it.Typ)"
            if ($script:HUMxTypes -notcontains $typ) { $res.Errors.Add("Unbekannte Art '$typ' im Index."); continue }
            $f = "$($it.File)".Replace('\', '/')
            if (-not $f -or -not $texts.ContainsKey($f)) { $res.Errors.Add("Eintrag '$($it.Name)': Datei fehlt."); continue }
            $want[$f] = $it
        }
        foreach ($n in @($texts.Keys)) { if ($script:HUMxBaseFiles -notcontains $n -and -not $want.ContainsKey($n)) { $res.Errors.Add("Unbekannte Datei '$n'.") } }
        if ($res.Errors.Count) { return $res }
        foreach ($f in @($want.Keys)) {
            $o = & $read $f
            $typ = "$($want[$f].Typ)"
            $ot = "$(Get-HUMxProp $o '@odata.type')"
            if ($ot -and $ot -notmatch $script:HUMxOdata[$typ]) { $res.Errors.Add("'$f': Typ '$ot' passt nicht zu $typ."); continue }
            $res.Entries[$f] = $o
        }
    } catch { $res.Errors.Add("$($_.Exception.Message)") }
    $res.Ok = -not $res.Errors.Count
    return $res
}

# ------------------------------------------------------------------ JSON-Dateien erkennen ------------------------------------------------------------------
# 067 B4: Erkennung auch ohne @odata.type -> Art oder ''
function Get-HUMxJsonKind($O) {
    if ($null -eq $O -or $O -is [string] -or $O -is [ValueType]) { return '' }
    $ot = "$(Get-HUMxProp $O '@odata.type')"
    if ($ot) {
        foreach ($k in 'Conditional Access', 'Benannter Ort', 'Authentifizierungsstaerke', 'Compliance', 'Einstellungskatalog', 'Administrative Vorlage', 'Feature-Update') { if ($ot -match $script:HUMxOdata[$k]) { return $k } }
        if ($ot -match $script:HUMxRefTypes) { return 'Konfiguration' }   # wird dann gesperrt (Grund sichtbar)
        if ($ot -match '(?i)^#microsoft\.graph\.[A-Za-z0-9]+(Configuration|ConfigurationProfile|CustomConfiguration|GeneralConfiguration)$') { return 'Konfiguration' }
        return ''
    }
    if ((Get-HUMxProp $O 'conditions') -and ((Get-HUMxProp $O 'grantControls') -or (Get-HUMxProp $O 'sessionControls'))) { return 'Conditional Access' }
    if ($O.PSObject.Properties['ipRanges'] -or $O.PSObject.Properties['countriesAndRegions']) { return 'Benannter Ort' }
    if ($O.PSObject.Properties['allowedCombinations']) { return 'Authentifizierungsstaerke' }
    if ($O.PSObject.Properties['settings'] -and $O.PSObject.Properties['technologies'] -and $O.PSObject.Properties['platforms']) { return 'Einstellungskatalog' }
    return ''
}

# Objekte aus einer JSON-Datei: einzelnes Objekt, Liste oder Huelle { value: [...] } (Graph); Huellfelder werden ignoriert
function Get-HUMxJsonObjects($J) {
    if ($null -eq $J) { return @() }
    if ($J -is [array]) { return @($J) }
    $v = Get-HUMxProp $J 'value'
    if ($v -is [array] -and -not (Get-HUMxJsonKind $J)) { return @($v) }
    return @($J)
}

# ------------------------------------------------------------------ Import ------------------------------------------------------------------
# Plan aus einer .humuster-Datei oder JSON-Dateien -> @{ Ok; Errors; Kind ('humuster'|'json'); Title; Category; Tags; Note; Learn; Publisher;
# Sha256; Rows (Typ, Name, Status, Grund, Entfernt, Hinweise, Obj); Names; NameMarks }
function Get-HUMusterImportPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string[]]$Paths, [Parameter(Mandatory)][string]$AppVersion, [datetime]$Now = (Get-Date))
    $plan = [pscustomobject]@{ Ok = $false; Errors = (New-Object System.Collections.Generic.List[string]); Kind = ''; Title = ''; Category = 'Conditional Access'; Tags = @(); Note = ''; Learn = @()
        Publisher = ''; Exported = ''; Sha256 = ''; Rows = @(); Names = @(); NameMarks = @(); Origin = 'importiert' }
    $markers = Get-HUMxTenantMarkers $Settings
    $rows = New-Object System.Collections.Generic.List[object]
    $Paths = @($Paths | Where-Object { "$_" })
    $hum = @($Paths | Where-Object { [IO.Path]::GetExtension($_) -ieq '.humuster' })
    $json = @($Paths | Where-Object { [IO.Path]::GetExtension($_) -ieq '.json' })
    if ($hum.Count -and $json.Count) { $plan.Errors.Add('Bitte .humuster und .json nicht gemischt importieren.'); return $plan }
    if ($hum.Count -gt 1) { $plan.Errors.Add('Bitte nur eine .humuster-Datei auf einmal importieren.'); return $plan }
    if (-not $hum.Count -and -not $json.Count) { $plan.Errors.Add('Nur .humuster- oder .json-Dateien.'); return $plan }
    if ($hum.Count) {
        $plan.Kind = 'humuster'
        $a = Test-HUMusterArchive -Path $hum[0] -AppVersion $AppVersion
        $plan.Sha256 = $a.Sha256
        if (-not $a.Ok) { foreach ($e in $a.Errors) { $plan.Errors.Add($e) }; return $plan }
        $p = $a.Paket
        $plan.Title = ConvertTo-HUMxPlainText "$($p.Title)" 200; if (-not $plan.Title) { $plan.Title = "Import $($Now.ToString('dd.MM.yyyy'))" }
        $plan.Category = ConvertTo-HUMxPlainText "$($p.Category)" 60; $plan.Tags = @($p.Tags | ForEach-Object { ConvertTo-HUMxPlainText "$_" 40 } | Where-Object { $_ } | Select-Object -First 20)
        $plan.Note = "$($p.Note)"; if ($plan.Note.Length -gt 4000) { $plan.Note = $plan.Note.Substring(0, 4000) }
        $plan.Learn = @($p.Learn | Where-Object { "$_" -match '^https://' } | ForEach-Object { "$_" } | Select-Object -First 10)
        $plan.Publisher = ConvertTo-HUMxPlainText "$($a.Manifest.Publisher)" 80; $plan.Exported = ConvertTo-HUMxPlainText "$($a.Manifest.Exported)" 40
        $plan.Names = @(Get-HUMxCatalog $a.Names)
        foreach ($it in @($a.Index.Items)) {
            $f = "$($it.File)".Replace('\', '/')
            $s = Invoke-HUMusterSanitize -Typ "$($it.Typ)" -Id "$($it.Id)" -Name "$($it.Name)" -Obj $a.Entries[$f] -TenantMarkers $markers
            $rows.Add([pscustomobject]@{ Typ = "$($it.Typ)"; Name = "$($it.Name)"; Id = "$($it.Id)"; Status = $s.Status; Grund = ($s.Reasons -join ' '); Entfernt = ($s.Removed -join '; '); Hinweise = ($s.Marks -join ' | '); P2 = $s.P2; Obj = $s.Obj; IsScript = $false })
        }
    } else {
        $plan.Kind = 'json'
        $plan.Title = "Import $($Now.ToString('dd.MM.yyyy HH:mm'))"
        if ($json.Count -gt $script:HUMxLimits.JsonFiles) { $plan.Errors.Add("Zu viele Dateien ($($json.Count), erlaubt $($script:HUMxLimits.JsonFiles))."); return $plan }
        $total = [int64]0
        $kinds = @{}
        foreach ($jp in $json) {
            $fn = [IO.Path]::GetFileName($jp)
            $fi = Get-Item -LiteralPath $jp -ErrorAction SilentlyContinue
            if (-not $fi) { $rows.Add([pscustomobject]@{ Typ = ''; Name = $fn; Id = ''; Status = 'gesperrt'; Grund = 'Datei nicht gefunden.'; Entfernt = ''; Hinweise = ''; P2 = $false; Obj = $null; IsScript = $false }); continue }
            $total += $fi.Length
            if ($fi.Length -gt $script:HUMxLimits.JsonBytes -or $total -gt $script:HUMxLimits.TotalBytes) { $plan.Errors.Add("$fn`: zu gross."); return $plan }
            $j = $null
            try { $j = ConvertFrom-HUMxJson ([IO.File]::ReadAllText($jp, [Text.Encoding]::UTF8)) $fn }
            catch { $rows.Add([pscustomobject]@{ Typ = ''; Name = $fn; Id = ''; Status = 'gesperrt'; Grund = "$($_.Exception.Message)"; Entfernt = ''; Hinweise = ''; P2 = $false; Obj = $null; IsScript = $false }); continue }
            $n = 0
            foreach ($o in @(Get-HUMxJsonObjects $j)) {
                $n++
                $kind = Get-HUMxJsonKind $o
                $nm = "$(Get-HUMxProp $o 'displayName')"; if (-not $nm) { $nm = "$(Get-HUMxProp $o 'name')" }; if (-not $nm) { $nm = "$fn #$n" }
                if (-not $kind) { $rows.Add([pscustomobject]@{ Typ = '(nicht erkannt)'; Name = $nm; Id = ''; Status = 'gesperrt'; Grund = 'Nicht erkannt - nur Conditional Access, benannte Orte, Authentifizierungsstaerken und bekannte Intune-Objekte.'; Entfernt = ''; Hinweise = ''; P2 = $false; Obj = $null; IsScript = $false }); continue }
                # Kennung eines Orts merken: CA-Richtlinien im selben Import verweisen darauf
                $oid = $(if ($kind -eq 'Benannter Ort') { "$(Get-HUMxProp $o 'id')" } else { '' })
                $s = Invoke-HUMusterSanitize -Typ $kind -Name $nm -Obj $o -TenantMarkers $markers
                if ($kind -eq 'Benannter Ort' -and $s.Obj -and "$(Get-HUMxProp $s.Obj '@odata.type')" -eq '') {
                    Set-HUMxProp $s.Obj '@odata.type' $(if ((Get-HUMxProp $o 'countriesAndRegions')) { '#microsoft.graph.countryNamedLocation' } else { '#microsoft.graph.ipNamedLocation' })
                }
                if ($s.Obj) { $kinds[$kind] = $true }
                $rows.Add([pscustomobject]@{ Typ = $kind; Name = $nm; Id = $oid; Status = $s.Status; Grund = ($s.Reasons -join ' '); Entfernt = ($s.Removed -join '; '); Hinweise = ($s.Marks -join ' | '); P2 = $s.P2; Obj = $s.Obj; IsScript = $false })
            }
        }
        $okRows = @($rows | Where-Object { $_.Status -eq 'ok' })
        if ($okRows.Count -eq 1) { $plan.Title = "$($okRows[0].Name)" }
        $plan.Category = $(if ($kinds.Count -eq 1 -and $kinds.ContainsKey('Compliance')) { 'Compliance' } elseif ($kinds.Count -eq 1 -and $kinds.ContainsKey('Conditional Access')) { 'Conditional Access' } elseif ($kinds.Count -gt 1) { 'Gesamtstand' } else { 'Conditional Access' })
        # Orte aus den Dateien: Namen fuer Verweise in CA-Richtlinien (gleiche Kennung)
        $plan.Names = @($rows | Where-Object { $_.Typ -eq 'Benannter Ort' -and $_.Status -eq 'ok' -and "$($_.Id)" -match $script:HUMxGuidRx } |
            ForEach-Object { [pscustomobject]@{ Art = 'Benannter Ort'; Id = "$($_.Id)"; Name = "$($_.Name)"; Source = $script:HUMxSource } })
    }
    # doppelte Art + Name: nur der erste
    $seen = @{}
    foreach ($r in $rows) {
        if ($r.Status -ne 'ok') { continue }
        $k = "$($r.Typ)|$("$($r.Name)".Trim().ToLowerInvariant())"
        if ($seen.ContainsKey($k)) { $r.Status = 'gesperrt'; $r.Grund = 'Gleicher Name schon im Import (nur der erste wird uebernommen).' } else { $seen[$k] = $true }
    }
    $plan.Rows = $rows.ToArray()
    $plan.NameMarks = @($plan.Names | ForEach-Object { "$($_.Art): $($_.Name)" })
    if (-not @($rows | Where-Object { $_.Status -eq 'ok' }).Count) { $plan.Errors.Add('Keine uebernehmbaren Eintraege.') }
    $plan.Ok = -not $plan.Errors.Count
    return $plan
}

# Plan als neues Paket in die Bibliothek (nie ueber ein vorhandenes) -> Paket
function Save-HUMusterImport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Plan, [string]$Title = '', [string[]]$OnlyKeys = $null, [switch]$Checked, [datetime]$Now = (Get-Date))
    if (-not $Plan.Ok) { throw "Import nicht moeglich: $($Plan.Errors -join ' ')" }
    # 2.5.8: nur ausgewaehlte Eintraege (Microsoft-Vorlagen: Haken in der Pruefansicht)
    if ($null -ne $OnlyKeys) {
        foreach ($r in @($Plan.Rows)) { if ($r.Status -eq 'ok' -and $OnlyKeys -notcontains "$($r.Typ)|$($r.Name)") { $r.Status = 'abgewaehlt' } }
        if (-not @($Plan.Rows | Where-Object { $_.Status -eq 'ok' }).Count) { throw 'Keine Vorlage ausgewaehlt.' }
    }
    $ok = @($Plan.Rows | Where-Object { $_.Status -eq 'ok' -and $_.Obj })
    $t = "$Title".Trim(); if (-not $t) { $t = $Plan.Title }
    # Titel frei machen (vorhandenes Paket gleichen Titels bleibt unberuehrt)
    $taken = @(Get-HUMusterPackages $Settings | ForEach-Object { "$($_.Title)".Trim().ToLowerInvariant() })
    $base = $t; $i = 1
    while ($taken -contains $t.ToLowerInvariant()) { $i++; $t = "$base ($i)" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "HU-MultiTenant\import-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $items = New-Object System.Collections.Generic.List[object]
        $n = 0
        foreach ($r in $ok) {
            $n++
            $f = "e\$('{0:D3}' -f $n).json"
            Write-HUBackupJson (Join-Path $tmp $f) $r.Obj
            $xid = $(if ($r.Typ -eq 'Benannter Ort' -and "$($r.Id)" -match $script:HUMxGuidRx) { "$($r.Id)" } else { "import-$('{0:D3}' -f $n)" })
            $items.Add([pscustomobject]@{ Typ = $r.Typ; Name = $r.Name; Id = $xid; File = $f; Folder = $tmp; Source = $script:HUMxSource; Stand = $Now.ToString('yyyy-MM-dd_HHmmss') })
        }
        # Namenskatalog der Datei mitgeben (ueber names.json im Quellordner)
        Write-HUBackupJson (Join-Path $tmp 'names.json') ([pscustomobject]@{ Format = 1; Items = @($Plan.Names) })
        Write-HUBackupJson (Join-Path $tmp 'index.json') ([pscustomobject]@{ Tenant = '__MUSTER__'; Errors = 0; Complete = $true; FailedTypes = @(); Items = @($items | ForEach-Object { [pscustomobject]@{ Typ = $_.Typ; Name = $_.Name; Id = $_.Id; File = $_.File; Source = $_.Source; Stand = $_.Stand } }) })
        $cats = @(Get-HUMusterCategories)
        $cat = $(if ($cats -contains $Plan.Category -and $Plan.Category -ne 'Mitgeliefert') { $Plan.Category } else { 'Conditional Access' })
        $extra = @{ Publisher = "$($Plan.Publisher)"; Imported = $Now.ToString('s'); ImportSha256 = "$($Plan.Sha256)"; ImportKind = "$($Plan.Kind)"; Checked = [bool]$Checked; Learn = @($Plan.Learn) }
        $r = Save-HUMusterPackage -Settings $Settings -Title $t -Category $cat -Tags @($Plan.Tags) -Note "$($Plan.Note)" -Items $items.ToArray() -Origin $(if ("$($Plan.Origin)" -eq 'vorlage') { 'vorlage' } else { 'importiert' }) -By "$($Plan.Publisher)" -Extra $extra -Now $Now
        Write-HULog -Message "Muster importiert: '$t' ($($ok.Count) Eintraege, $(@($Plan.Rows | Where-Object { $_.Status -ne 'ok' }).Count) nicht uebernommen) - $(if ($Checked) { 'geprueft' } else { 'ungeprueft' })$(if ("$($Plan.Origin)" -eq 'vorlage') { ', Microsoft-Vorlagen' })" -Level 'OK'
        return $r.Package
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------ Microsoft-Vorlagen (2.5.8) ------------------------------------------------------------------
# Vorlagen fuer bedingten Zugriff (Graph v1.0 /identity/conditionalAccess/templates, Recht Policy.Read.All) -> Plan wie beim Import.
# Jede Vorlage wird eine CA-Richtlinie im Modus Nur Bericht; bereinigt wie ein Import (z. B. "Current administrator will be excluded").
$script:HUMxTplLearn = @('https://learn.microsoft.com/entra/identity/conditional-access/concept-conditional-access-policy-common', 'https://learn.microsoft.com/graph/api/conditionalaccessroot-list-templates')
function ConvertFrom-HUMxTemplates([object[]]$Templates, [string[]]$TenantMarkers = @(), [datetime]$Now = (Get-Date)) {
    $plan = [pscustomobject]@{ Ok = $false; Errors = (New-Object System.Collections.Generic.List[string]); Kind = 'microsoft'; Title = "Microsoft-Vorlagen $($Now.ToString('dd.MM.yyyy'))"; Category = 'Conditional Access'
        Tags = @('Microsoft-Vorlage'); Note = ''; Learn = $script:HUMxTplLearn; Publisher = 'Microsoft (Vorlagen fuer bedingten Zugriff)'; Exported = ''; Sha256 = ''; Rows = @(); Names = @(); NameMarks = @(); Origin = 'vorlage' }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Templates | Where-Object { $_ })) {
        $nm = "$(Get-HUMxProp $t 'name')".Trim()
        $d = Get-HUMxProp $t 'details'
        if (-not $nm -or -not $d) { continue }
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.conditionalAccessPolicy'; displayName = $nm; state = 'enabledForReportingButNotEnforced'
            conditions = (Get-HUMxProp $d 'conditions'); grantControls = (Get-HUMxProp $d 'grantControls'); sessionControls = (Get-HUMxProp $d 'sessionControls') }
        $s = Invoke-HUMusterSanitize -Typ 'Conditional Access' -Name $nm -Obj $o -TenantMarkers $TenantMarkers
        $desc = "$(Get-HUMxProp $t 'description')"; $sc = "$(Get-HUMxProp $t 'scenarios')"
        $hin = @(@($(if ($sc) { "Szenarien: $sc" })) + @($(if ($desc) { $desc })) + @($s.Marks | Where-Object { $_ -notlike 'Name: *' }) | Where-Object { $_ }) -join ' | '
        # Vorlagen haben keine Zuweisungen - "Metadaten und Zuweisungen" waere hier nur Rauschen
        $rem = @($s.Removed | Where-Object { $_ -ne 'Metadaten und Zuweisungen' })
        # Entra ID P1: Vorlagen mit Risiko-Bedingung (P2) sind nicht vorgewaehlt
        $rows.Add([pscustomobject]@{ Typ = 'Conditional Access'; Name = $nm; Id = "$(Get-HUMxProp $t 'id')"; Status = $s.Status; Grund = ($s.Reasons -join ' '); Entfernt = ($rem -join '; '); Hinweise = $hin; P2 = $s.P2; Obj = $s.Obj; IsScript = $false; Pick = (-not $s.P2) })
    }
    $plan.Rows = $rows.ToArray()
    $plan.Note = "Vorlagen von Microsoft (Graph, Stand $($Now.ToString('dd.MM.yyyy'))). Beim Anwenden: neu, Nur Bericht, Notfallkonten des Ziels ausgenommen; Rollen und Apps sind in jedem Tenant gleich."
    if (-not @($rows | Where-Object { $_.Status -eq 'ok' }).Count) { $plan.Errors.Add('Keine Vorlagen gelesen.') }
    $plan.Ok = -not $plan.Errors.Count
    return $plan
}
function Get-HUMusterTemplatePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$TenantKey)
    $tpl = @(Get-HUIntuneGraphAll -TenantKey $TenantKey -Settings $Settings -Endpoint '/identity/conditionalAccess/templates' -V1)
    return (ConvertFrom-HUMxTemplates $tpl (Get-HUMxTenantMarkers $Settings))
}

# Pruefansicht fuer ein vorhandenes (importiertes) Paket vor dem Anwenden: Eintraege mit Hinweisen, ohne Bereinigung zu aendern
function Get-HUMusterReviewRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Package)
    $markers = Get-HUMxTenantMarkers $Settings
    foreach ($it in @($Package.Items)) {
        $o = $null; try { if ("$($it.File)") { $o = Read-HUBackupJson (Join-Path $Package.Folder $it.File) } } catch { }
        if (-not $o) { [pscustomobject]@{ Paket = "$($Package.Title)"; Typ = "$($it.Typ)"; Name = "$($it.Name)"; Status = 'ohne Datei'; Hinweise = '' }; continue }
        $s = Invoke-HUMusterSanitize -Typ "$($it.Typ)" -Id "$($it.Id)" -Name "$($it.Name)" -Obj $o -TenantMarkers $markers
        [pscustomobject]@{ Paket = "$($Package.Title)"; Typ = "$($it.Typ)"; Name = "$($it.Name)"; Status = $s.Status; Hinweise = (@($s.Reasons) + @($s.Marks) -join ' | '); Obj = $o }
    }
}

Export-ModuleMember -Function Get-HUMxLimits, Get-HUMxImportSource, ConvertTo-HUMxFileName, ConvertTo-HUMxPlainText, Get-HUMxTenantMarkers, Invoke-HUMusterSanitize, Get-HUMusterExportPlan, Save-HUMusterExport,
    Test-HUMxJsonText, ConvertFrom-HUMxJson, Test-HUMxEntryName, Get-HUMxZipDirectory, Test-HUMusterArchive, Get-HUMxJsonKind, Get-HUMxJsonObjects,
    Get-HUMusterImportPlan, Save-HUMusterImport, Get-HUMusterReviewRows, ConvertFrom-HUMxTemplates, Get-HUMusterTemplatePlan
