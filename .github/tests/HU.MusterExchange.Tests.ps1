#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests fuer Core\HU.MusterExchange.psm1 (2.5.7): Bereinigung, Export, Import-Schutz, JSON-Import, ungeprueft.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach ($m in 'HU.Logging', 'HU.Intune', 'HU.SecCatalog', 'HU.EntraRestore', 'HU.Muster', 'HU.Transfer', 'HU.MusterExchange') { Import-Module (Join-Path $root "Core\$m.psm1") -Force -DisableNameChecking }
    Mock -ModuleName HU.Muster Write-HULog { }
    Mock -ModuleName HU.MusterExchange Write-HULog { }
    Set-HUMusterBuiltinRoot (Join-Path ([IO.Path]::GetTempPath()) 'HU-MX-keine-mitgelieferten')
    $script:Ver = '2.5.7'
    $script:NewBase = { $b = Join-Path ([IO.Path]::GetTempPath()) ("HU-MX-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $b -Force | Out-Null; $b }
    $script:Set = { param($b) [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $b }; backupPath = $b; tenants = @([pscustomobject]@{ key = 'T1'; displayName = 'Schule A'; tenantId = '11111111-2222-3333-4444-555555555555'; domain = 'schule-a.at' }) } }
    $script:Ca = {
        [pscustomobject]@{ id = 'ca1'; displayName = '201 - MFA Lehrer'; state = 'enabled'; createdDateTime = '2026-01-01T00:00:00Z'
            conditions = [pscustomobject]@{
                users = [pscustomobject]@{ includeUsers = @('All', 'bbbbbbbb-0000-0000-0000-000000000001'); excludeUsers = @('bbbbbbbb-0000-0000-0000-000000000002'); includeGroups = @('aaaaaaaa-0000-0000-0000-000000000001'); excludeGroups = @()
                    includeRoles = @(); excludeRoles = @(); excludeGuestsOrExternalUsers = [pscustomobject]@{ guestOrExternalUserTypes = 'b2bCollaborationGuest'; externalTenants = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.conditionalAccessEnumeratedExternalTenants'; membershipKind = 'enumerated'; members = @('99999999-0000-0000-0000-000000000009') } } }
                applications = [pscustomobject]@{ includeApplications = @('All') }
                locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('dddddddd-0000-0000-0000-000000000001') } }
            grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('mfa'); authenticationStrength = $null } }
    }
    # Paket in einer Bibliothek anlegen
    $script:MkPkg = {
        param($Set, [object[]]$Objs)
        $src = Join-Path $Set.backupPath 'T1\2026-10-27_000000'
        $items = foreach ($x in $Objs) {
            $f = "$($x.Typ)\$($x.Name).json"
            Write-HUBackupJson (Join-Path $src $f) $x.O
            [pscustomobject]@{ Typ = $x.Typ; Name = $x.Name; Id = $(if ($x.Id) { $x.Id } else { "id-$($x.Name)" }); File = $f; Folder = $src; Source = 'T1'; Stand = '2026-10-27_000000' }
        }
        Write-HUBackupJson (Join-Path $src 'index.json') ([pscustomobject]@{ Tenant = 'T1'; Errors = 0; Complete = $true; Items = @($items | ForEach-Object { [pscustomobject]@{ Typ = $_.Typ; Name = $_.Name; Id = $_.Id; File = $_.File } }) })
        (Save-HUMusterPackage -Settings $Set -Title 'Testpaket' -Category 'Conditional Access' -Items @($items)).Package
    }
}

Describe 'Bereinigung (067 B1)' {
    It 'CA: Benutzer, Gruppen-Kennungen, Gaeste bestimmter Tenants, Metadaten weg; Gruppen als Platzhalter' {
        $s = Invoke-HUMusterSanitize -Typ 'Conditional Access' -Obj (& $script:Ca) -GroupNames @{ 'aaaaaaaa-0000-0000-0000-000000000001' = 'Lehrer' }
        $s.Status | Should -Be 'ok'
        $u = $s.Obj.conditions.users
        @($u.includeUsers) -join ',' | Should -Be 'All'
        @($u.excludeUsers).Count | Should -Be 0
        @($u.includeGroups).Count | Should -Be 0
        $u.PSObject.Properties['excludeGuestsOrExternalUsers'] | Should -BeNullOrEmpty
        $s.Obj.huGruppen[0].name | Should -Be 'Lehrer'; $s.Obj.huGruppen[0].feld | Should -Be 'includeGroups'
        $s.Obj.PSObject.Properties['id'] | Should -BeNullOrEmpty
        $s.Obj.PSObject.Properties['createdDateTime'] | Should -BeNullOrEmpty
        ($s.Obj | ConvertTo-Json -Depth 20) | Should -Not -Match '99999999-0000'
        ($s.Removed -join ' ') | Should -Match 'Gaeste bestimmter Tenants'
        ($s.Marks -join ' ') | Should -Match 'Name: 201 - MFA Lehrer'
    }
    It 'CA: Risiko-Bedingung = braucht P2; Nutzungsbedingungen und Workload-Identitaeten gesperrt' {
        $o = & $script:Ca; $o.conditions | Add-Member -NotePropertyName signInRiskLevels -NotePropertyValue @('high')
        $s = Invoke-HUMusterSanitize -Typ 'Conditional Access' -Obj $o
        $s.P2 | Should -BeTrue; ($s.Marks -join ' ') | Should -Match 'P2'
        $o.grantControls | Add-Member -NotePropertyName termsOfUse -NotePropertyValue @('t1')
        (Invoke-HUMusterSanitize -Typ 'Conditional Access' -Obj $o).Status | Should -Be 'gesperrt'
    }
    It 'Intune: Bereichsmarkierungen auf 0, Zuweisungen weg; Compliance-Benachrichtigung und CC-Liste weg' {
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; id = 'c1'; displayName = 'Win'; roleScopeTagIds = @('0', '7'); assignments = @([pscustomobject]@{ target = 'x' })
            scheduledActionsForRule = @([pscustomobject]@{ ruleName = 'PasswordRequired'; scheduledActionConfigurations = @(
                        [pscustomobject]@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = ''; notificationMessageCCList = @() },
                        [pscustomobject]@{ actionType = 'notification'; gracePeriodHours = 24; notificationTemplateId = 'eeeeeeee-0000-0000-0000-000000000001'; notificationMessageCCList = @('ffffffff-0000-0000-0000-000000000001') }) }) }
        $s = Invoke-HUMusterSanitize -Typ 'Compliance' -Obj $o
        $s.Status | Should -Be 'ok'
        @($s.Obj.roleScopeTagIds) -join ',' | Should -Be '0'
        $s.Obj.PSObject.Properties['assignments'] | Should -BeNullOrEmpty
        @($s.Obj.scheduledActionsForRule[0].scheduledActionConfigurations).Count | Should -Be 1
        $s.Obj.scheduledActionsForRule[0].scheduledActionConfigurations[0].PSObject.Properties['notificationMessageCCList'] | Should -BeNullOrEmpty
    }
    It 'WLAN/VPN/Zertifikat und verschluesselte OMA-Werte sperren den ganzen Eintrag' {
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows81WifiImportConfiguration'; displayName = 'WLAN' })).Status | Should -Be 'gesperrt'
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows81TrustedRootCertificate'; displayName = 'Root' })).Status | Should -Be 'gesperrt'
        $oma = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = 'OMA'; omaSettings = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.omaSettingString'; omaUri = './x'; isEncrypted = $true; value = '***' }) }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj $oma).Status | Should -Be 'gesperrt'
    }
    It 'Tenant-ID, eigene Domain und onmicrosoft-Domain im Wert sperren' {
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'OneDrive'; x = 'KFM 11111111-2222-3333-4444-555555555555' }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj $o -TenantMarkers @('11111111-2222-3333-4444-555555555555')).Status | Should -Be 'gesperrt'
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'x'; y = 'https://contoso.onmicrosoft.com' }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj $o).Status | Should -Be 'gesperrt'
    }
    It 'IP-Bereiche weg, Laender bleiben; Pruefer der Admin-Zustimmung weg; unbekannte Arten gesperrt' {
        $s = Invoke-HUMusterSanitize -Typ 'Benannter Ort' -Obj ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; displayName = 'Netz'; ipRanges = @([pscustomobject]@{ cidrAddress = '10.0.0.0/8' }) })
        @($s.Obj.ipRanges).Count | Should -Be 0
        $s = Invoke-HUMusterSanitize -Typ 'Benannter Ort' -Obj ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; displayName = 'AT'; countriesAndRegions = @('AT') })
        @($s.Obj.countriesAndRegions) -join ',' | Should -Be 'AT'
        $s = Invoke-HUMusterSanitize -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Obj ([pscustomobject]@{ isEnabled = $true; reviewers = @([pscustomobject]@{ query = '/users/bbbbbbbb-0000-0000-0000-000000000001' }) })
        @($s.Obj.reviewers).Count | Should -Be 0; $s.Status | Should -Be 'ok'
        (Invoke-HUMusterSanitize -Typ 'App' -Obj ([pscustomobject]@{ displayName = 'x' })).Status | Should -Be 'gesperrt'
        (Invoke-HUMusterSanitize -Typ 'Entra-Einstellung' -Id 'crossTenantAccessDefault' -Obj ([pscustomobject]@{ x = 1 })).Status | Should -Be 'gesperrt'
    }
    It 'Skripte nur mit Freigabe, nie mit Kennwort' {
        $sc = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceManagementScript'; displayName = 'S'; scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Write-Host hallo')) }
        (Invoke-HUMusterSanitize -Typ 'Plattform-Skript' -Obj $sc).Status | Should -Be 'gesperrt'
        (Invoke-HUMusterSanitize -Typ 'Plattform-Skript' -Obj $sc -AllowScript).Status | Should -Be 'ok'
        $sc.scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('$password = "x"'))
        (Invoke-HUMusterSanitize -Typ 'Plattform-Skript' -Obj $sc -AllowScript).Status | Should -Be 'gesperrt'
    }
}

Describe 'Review 068' {
    It 'B1: huGruppen aus der Datei nur gueltig, Ausnahmen sichtbar' {
        $o = & $script:Ca
        $o | Add-Member -NotePropertyName huGruppen -NotePropertyValue @([pscustomobject]@{ feld = 'excludeGroups'; name = 'Lehrer' }, [pscustomobject]@{ feld = 'includeUsers'; name = 'x' }, [pscustomobject]@{ feld = 'includeGroups'; name = @('a') })
        $s = Invoke-HUMusterSanitize -Typ 'Conditional Access' -Obj $o
        @($s.Obj.huGruppen | Where-Object { $_.name -eq 'Lehrer' -and $_.feld -eq 'excludeGroups' }).Count | Should -Be 1
        @($s.Obj.huGruppen | Where-Object { $_.feld -eq 'includeUsers' }).Count | Should -Be 0
        ($s.Marks -join ' ') | Should -Match 'AUSNAHME-Gruppe \(aus Datei\): Lehrer'
        ($s.Removed -join ' ') | Should -Match 'ungueltiger Gruppen-Platzhalter'
    }
    It 'B2: OMA-URI WLAN/VPN/Zertifikat gesperrt, eingebettetes Zertifikat oder Kennwort gesperrt, harmloser Inhalt markiert' {
        $oma = { param($uri, $v) [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = 'OMA'; omaSettings = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.omaSettingString'; omaUri = $uri; value = $v }) } }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj (& $oma './Vendor/MSFT/WiFi/Profile/Schule/WlanXml' '<WLANProfile/>')).Status | Should -Be 'gesperrt'
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj (& $oma './Device/Vendor/MSFT/VPNv2/X/ProfileXML' 'x')).Status | Should -Be 'gesperrt'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("-----BEGIN CERTIFICATE-----`nMIIB" + ('A' * 80)))
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj (& $oma './Vendor/MSFT/Policy/Config/X' $b64)).Status | Should -Be 'gesperrt'
        $ok64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('<plist><dict><key>AllowCamera</key><false/></dict></plist>' + (' ' * 40)))
        $s = Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj (& $oma './Vendor/MSFT/Policy/Config/X' $ok64)
        $s.Status | Should -Be 'ok'; ($s.Marks -join ' ') | Should -Match 'eingebetteter Inhalt'
    }
    It 'B3: Uebertragen/Anwenden importierter Eintraege nur aus bestaetigten Paketen' {
        Test-HUMusterTransferAllowed 'T1' $null | Should -Be ''
        Test-HUMusterTransferAllowed 'importiert' $true | Should -Be ''
        Test-HUMusterTransferAllowed 'importiert' $false | Should -Not -Be ''
        Test-HUMusterTransferAllowed 'importiert' $null | Should -Not -Be ''
    }
    It 'B6/B8: \u-Schluessel als doppelt erkannt, Kommentare abgelehnt; Tenant-Marker im Eigenschaftsnamen gesperrt' {
        Test-HUMxJsonText '{"id":1,"\u0069d":2}' | Should -Match 'doppelt'
        Test-HUMxJsonText '{"a":1 /* "x */ }' | Should -Match 'Kommentar'
        Test-HUMxJsonText '{"url":"https://x/y"}' | Should -Be ''
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'x'; 'contoso.onmicrosoft.com' = 1 }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Obj $o).Status | Should -Be 'gesperrt'
    }
}

Describe 'JSON-Pruefung vor dem Parsen (067 B3)' {
    It 'Tiefe ueber der Grenze, doppelte Schluessel (auch Gross/klein) werden abgelehnt' {
        Test-HUMxJsonText ('[' * 70 + ']' * 70) 64 | Should -Match 'tief'
        Test-HUMxJsonText ('[' * 10 + ']' * 10) 64 | Should -Be ''
        Test-HUMxJsonText '{"a":1,"A":2}' | Should -Match 'doppelt'
        Test-HUMxJsonText '{"a":{"b":1},"c":{"b":2}}' | Should -Be ''
        Test-HUMxJsonText '{"a":"x\"}{[","b":[1,{"a":2}]}' | Should -Be ''
        Test-HUMxJsonText '{"a":[1,2}' | Should -Not -Be ''
    }
}

Describe 'ZIP-Namen (067 B2)' {
    It 'lehnt .., absolute Pfade, Laufwerk/Streams, reservierte Namen, Punkt am Ende ab' {
        foreach ($n in '../x.json', '/x.json', 'C:/x.json', 'a/x.json:zone', 'CON.json', 'a/nul', 'a./x.json', 'a /x.json', 'a//b.json') { Test-HUMxEntryName $n | Should -Not -Be '' -Because $n }
        Test-HUMxEntryName 'Conditional_Access/001_x.json' | Should -Be ''
    }
}

Describe 'Export und Import (Rundlauf und manipulierte Archive)' {
    BeforeAll {
        $script:B = & $script:NewBase; $script:S = & $script:Set $script:B
        $cmp = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; id = 'c1'; displayName = 'Win Compliance'; passwordRequired = $true; roleScopeTagIds = @('0') }
        $wifi = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows81WifiImportConfiguration'; id = 'w1'; displayName = 'WLAN Schule' }
        $script:Pkg = & $script:MkPkg $script:S @(@{ Typ = 'Conditional Access'; Name = '201 - MFA Lehrer'; O = (& $script:Ca) }, @{ Typ = 'Compliance'; Name = 'Win Compliance'; O = $cmp }, @{ Typ = 'Konfiguration'; Name = 'WLAN Schule'; O = $wifi })
        $script:Plan = Get-HUMusterExportPlan -Settings $script:S -Package $script:Pkg
        $script:File = Join-Path $script:B 'out\Test.humuster'
        $script:Out = Save-HUMusterExport -Plan $script:Plan -Path $script:File -Publisher 'IT-Team' -AppVersion $script:Ver
    }
    It 'Export: WLAN gesperrt, Rest in der Datei, keine Benutzer- oder Tenant-Kennungen' {
        @($script:Plan.Rows | Where-Object Status -eq 'gesperrt').Name | Should -Be 'WLAN Schule'
        $script:Out.Count | Should -Be 2
        $a = Test-HUMusterArchive -Path $script:File -AppVersion $script:Ver
        $a.Ok | Should -BeTrue
        $a.Manifest.Publisher | Should -Be 'IT-Team'
        $all = ($a.Entries.Values | ConvertTo-Json -Depth 30)
        $all | Should -Not -Match 'bbbbbbbb-0000'
        $all | Should -Not -Match '11111111-2222'
        @($a.Index.Items | Where-Object { $_.Source -ne 'importiert' }).Count | Should -Be 0
    }
    It 'Import: neues Paket, ungeprueft, Herausgeber; nie ueber ein vorhandenes' {
        $ip = Get-HUMusterImportPlan -Settings $script:S -Paths @($script:File) -AppVersion $script:Ver
        $ip.Ok | Should -BeTrue
        $p = Save-HUMusterImport -Settings $script:S -Plan $ip
        $p.Origin | Should -Be 'importiert'; $p.Checked | Should -BeFalse; $p.Publisher | Should -Be 'IT-Team'
        $p.Title | Should -Be 'Testpaket (2)'
        @($p.Items).Count | Should -Be 2
        @($p.Items | ForEach-Object { $_.Source } | Sort-Object -Unique) -join ',' | Should -Be 'importiert'
        $c = Set-HUMusterChecked -Settings $script:S -Id $p.Id
        $c.Checked | Should -BeTrue
        # Bearbeiten behaelt Herkunft und Herausgeber (067 B7)
        $e = (Save-HUMusterPackage -Settings $script:S -Id $p.Id -Title $p.Title -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $c)).Package
        $e.Origin | Should -Be 'importiert'; $e.Publisher | Should -Be 'IT-Team'; $e.Checked | Should -BeTrue
        (Get-HUMusterExportPlan -Settings $script:S -Package $e).OrigPublisher | Should -Be 'IT-Team'
        # 068 P5: Kopie eines importierten Pakets bleibt ungeprueft (auch wenn das Original bestaetigt war)
        $k = (Save-HUMusterPackage -Settings $script:S -Title 'Kopie davon' -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $e)).Package
        $k.Origin | Should -Be 'eigen'; $k.Checked | Should -BeFalse
        # bestaetigt, dann ohne neue importierte Eintraege bearbeitet -> bleibt bestaetigt
        $k2 = Set-HUMusterChecked -Settings $script:S -Id $k.Id
        (Save-HUMusterPackage -Settings $script:S -Id $k2.Id -Title $k2.Title -Category 'Conditional Access' -Items @(Get-HUMusterPackageItems $k2)).Package.Checked | Should -BeTrue
    }
    It 'veraenderte Datei, unbekannte Datei, zu hohe Mindestversion, falsche Endung' {
        $mk = {
            param([hashtable]$Files)
            $f = Join-Path $script:B ("m-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.humuster')
            $fs = [IO.File]::Open($f, 'CreateNew'); $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            foreach ($k in $Files.Keys) { $e = $z.CreateEntry($k); $s = $e.Open(); $b = [Text.Encoding]::UTF8.GetBytes($Files[$k]); $s.Write($b, 0, $b.Length); $s.Dispose() }
            $z.Dispose(); $fs.Dispose(); $f
        }
        # Original auslesen
        $ms = [IO.File]::OpenRead($script:File); $z = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
        $orig = @{}; foreach ($e in $z.Entries) { $r = New-Object IO.StreamReader($e.Open()); $orig[$e.FullName] = $r.ReadToEnd(); $r.Dispose() }; $z.Dispose(); $ms.Dispose()
        $x = $orig.Clone(); $k = @($x.Keys | Where-Object { $_ -like 'Compliance/*' })[0]; $x[$k] = $x[$k].Replace('true', 'false')
        (Test-HUMusterArchive -Path (& $mk $x) -AppVersion $script:Ver).Errors -join ' ' | Should -Match 'Pruefsumme'
        $x = $orig.Clone(); $x['extra.ps1'] = 'Write-Host'
        (Test-HUMusterArchive -Path (& $mk $x) -AppVersion $script:Ver).Errors -join ' ' | Should -Match 'Manifest|Unbekannte'
        (Test-HUMusterArchive -Path $script:File -AppVersion '2.5.6').Errors -join ' ' | Should -Match 'Braucht'
        $j = Join-Path $script:B 'x.zip'; Copy-Item $script:File $j
        (Test-HUMusterArchive -Path $j -AppVersion $script:Ver).Ok | Should -BeFalse
        # doppelte Namen nach Gross/klein
        $f = Join-Path $script:B 'dup.humuster'
        $fs = [IO.File]::Open($f, 'CreateNew'); $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($k in 'index.json', 'INDEX.json') { $e = $z.CreateEntry($k); $st = $e.Open(); $st.WriteByte(123); $st.Dispose() }
        $z.Dispose(); $fs.Dispose()
        (Test-HUMusterArchive -Path $f -AppVersion $script:Ver).Errors -join ' ' | Should -Match 'doppelt'
    }
    It 'ZIP-Bombe: stark gepackter Eintrag wird beim Lesen abgebrochen' {
        $f = Join-Path $script:B 'bomb.humuster'
        $fs = [IO.File]::Open($f, 'CreateNew'); $z = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        $e = $z.CreateEntry('manifest.json'); $s = $e.Open(); $b = [Text.Encoding]::ASCII.GetBytes(' ' * 5MB); $s.Write($b, 0, $b.Length); $s.Dispose()
        $z.Dispose(); $fs.Dispose()
        (Test-HUMusterArchive -Path $f -AppVersion $script:Ver).Errors -join ' ' | Should -Match 'ZIP-Bomben'
    }
}

Describe 'JSON-Import (067 C, B4)' {
    BeforeAll { $script:B2 = & $script:NewBase; $script:S2 = & $script:Set $script:B2 }
    It 'erkennt CA ohne @odata.type, Orte, Staerken, Einstellungskatalog; Huelle value[]; Unbekanntes nicht uebernommen' {
        Get-HUMxJsonKind ([pscustomobject]@{ conditions = 1; grantControls = 1 }) | Should -Be 'Conditional Access'
        Get-HUMxJsonKind ([pscustomobject]@{ countriesAndRegions = @('AT') }) | Should -Be 'Benannter Ort'
        Get-HUMxJsonKind ([pscustomobject]@{ allowedCombinations = @('fido2') }) | Should -Be 'Authentifizierungsstaerke'
        Get-HUMxJsonKind ([pscustomobject]@{ settings = @(); technologies = 'mdm'; platforms = 'windows10' }) | Should -Be 'Einstellungskatalog'
        Get-HUMxJsonKind ([pscustomobject]@{ foo = 1 }) | Should -Be ''
        $f1 = Join-Path $script:B2 'ca.json'; [IO.File]::WriteAllText($f1, ((& $script:Ca) | ConvertTo-Json -Depth 20))
        $f2 = Join-Path $script:B2 'viele.json'; [IO.File]::WriteAllText($f2, ([pscustomobject]@{ '@odata.context' = 'x'; value = @([pscustomobject]@{ id = 'dddddddd-0000-0000-0000-000000000001'; displayName = 'Erlaubte Laender'; countriesAndRegions = @('AT') }, [pscustomobject]@{ foo = 1 }) } | ConvertTo-Json -Depth 10))
        $ip = Get-HUMusterImportPlan -Settings $script:S2 -Paths @($f1, $f2) -AppVersion $script:Ver
        $ip.Ok | Should -BeTrue
        @($ip.Rows | Where-Object Status -eq 'ok').Count | Should -Be 2
        @($ip.Rows | Where-Object Typ -eq '(nicht erkannt)').Count | Should -Be 1
        $ip.Names[0].Name | Should -Be 'Erlaubte Laender'
        $p = Save-HUMusterImport -Settings $script:S2 -Plan $ip
        $p.Checked | Should -BeFalse
        (@($p.Items | Where-Object Typ -eq 'Benannter Ort')[0]).Id | Should -Be 'dddddddd-0000-0000-0000-000000000001'
        $ca = Read-HUBackupJson (Join-Path $p.Folder (@($p.Items | Where-Object Typ -eq 'Conditional Access')[0]).File)
        @($ca.conditions.users.excludeUsers).Count | Should -Be 0
        $ca.huGruppen[0].name | Should -Match 'unbekannte Gruppe'
    }
    It 'zu tiefe oder doppelte Schluessel -> Eintrag gesperrt mit Grund' {
        $f = Join-Path $script:B2 'tief.json'; [IO.File]::WriteAllText($f, ('[' * 70 + ']' * 70))
        $f2 = Join-Path $script:B2 'ok.json'; [IO.File]::WriteAllText($f2, ([pscustomobject]@{ displayName = 'AT'; countriesAndRegions = @('AT') } | ConvertTo-Json))
        $ip = Get-HUMusterImportPlan -Settings $script:S2 -Paths @($f, $f2) -AppVersion $script:Ver
        (@($ip.Rows | Where-Object Name -eq 'tief.json')[0]).Grund | Should -Match 'tief'
        $ip.Ok | Should -BeTrue
    }
}

Describe 'Dateiname (067 B6)' {
    It 'nur sichere Zeichen, Datum dran' {
        ConvertTo-HUMxFileName 'CA <Schule> / "Praxis"' ([datetime]'2026-10-27') | Should -Be 'CA _Schule_ _ _Praxis_2026-10-27.humuster'
    }
}

Describe 'Microsoft-Vorlagen (2.5.8)' {
    It 'Vorlage -> CA Nur Bericht, Platzhalter-Text in excludeUsers entfernt, nur ausgewaehlte, geprueft' {
        $t = [pscustomobject]@{ name = 'Require multifactor authentication for admins'; description = 'MFA fuer Admins'; id = 'c7503427-338e-4c5e-902d-abe252abfb43'; scenarios = 'secureFoundation,zeroTrust'
            details = [pscustomobject]@{ sessionControls = $null; grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('mfa'); termsOfUse = @() }
                conditions = [pscustomobject]@{ clientAppTypes = @('all'); applications = [pscustomobject]@{ includeApplications = @('All') }
                    users = [pscustomobject]@{ includeUsers = @(); excludeUsers = @('Current administrator will be excluded'); includeRoles = @('62e90394-69f5-4237-9190-012177145e10') } } } }
        $t2 = [pscustomobject]@{ name = 'Block legacy authentication'; id = 'x'; details = [pscustomobject]@{ grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('block') }; conditions = [pscustomobject]@{ clientAppTypes = @('exchangeActiveSync', 'other'); applications = [pscustomobject]@{ includeApplications = @('All') }; users = [pscustomobject]@{ includeUsers = @('All') } } } }
        $pl = ConvertFrom-HUMxTemplates @($t, $t2)
        $pl.Ok | Should -BeTrue
        @($pl.Rows).Count | Should -Be 2
        $r = $pl.Rows[0]
        $r.Obj.state | Should -Be 'enabledForReportingButNotEnforced'
        @($r.Obj.conditions.users.excludeUsers).Count | Should -Be 0
        $r.Hinweise | Should -Match 'secureFoundation'
        $r.Pick | Should -BeTrue; $r.Entfernt | Should -Not -Match 'Metadaten'
        $b = & $script:NewBase; $set = & $script:Set $b
        $p = Save-HUMusterImport -Settings $set -Plan $pl -OnlyKeys @('Conditional Access|Block legacy authentication') -Checked
        @($p.Items).Count | Should -Be 1
        $p.Checked | Should -BeTrue
        $p.Publisher | Should -Match 'Microsoft'; $p.Origin | Should -Be 'vorlage'
    }
}

Describe 'Microsoft-Vorlagen: Lizenzen und eingebaute Staerken (069 B3)' {
    It 'Eingebaute Authentifizierungsstaerke bleibt (ok, vorgewaehlt), nur id/displayName' {
        $t = [pscustomobject]@{ name = 'Require phishing-resistant MFA for admins'; id = 'p'; details = [pscustomobject]@{
                grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @(); authenticationStrength = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; allowedCombinations = @('fido2') } }
                conditions = [pscustomobject]@{ clientAppTypes = @('all'); applications = [pscustomobject]@{ includeApplications = @('All') }; users = [pscustomobject]@{ includeRoles = @('62e90394-69f5-4237-9190-012177145e10') } } } }
        $r = (ConvertFrom-HUMxTemplates @($t)).Rows[0]
        $r.Status | Should -Be 'ok'; $r.Pick | Should -BeTrue
        $r.Obj.grantControls.authenticationStrength.id | Should -Be '00000000-0000-0000-0000-000000000004'
        $r.Obj.grantControls.authenticationStrength.PSObject.Properties['allowedCombinations'] | Should -BeNullOrEmpty
    }
    It 'Insider-Risiko und Dienstprinzipal-Risiko: nicht vorgewaehlt, Lizenz genannt' {
        foreach ($f in 'insiderRiskLevels', 'servicePrincipalRiskLevels') {
            $c = [pscustomobject]@{ clientAppTypes = @('all'); applications = [pscustomobject]@{ includeApplications = @('All') }; users = [pscustomobject]@{ includeUsers = @('All') } }
            $c | Add-Member -NotePropertyName $f -NotePropertyValue @('high')
            $t = [pscustomobject]@{ name = "Vorlage $f"; id = 'x'; details = [pscustomobject]@{ grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('block') }; conditions = $c } }
            $r = (ConvertFrom-HUMxTemplates @($t)).Rows[0]
            $r.Pick | Should -BeFalse
            $r.Hinweise | Should -Match $(if ($f -eq 'insiderRiskLevels') { 'Purview' } else { 'Workload ID Premium' })
        }
    }
}

Describe 'Pruefbefunde 072 (Gemini)' {
    It 'B1: doppelte Schluessel auch mit JSON-Escapes (a\/b = a/b), kein Fehlalarm bei \\u0061' {
        Test-HUMxJsonText '{"a/b":1,"a\/b":2}' | Should -Match 'doppelt'
        Test-HUMxJsonText '{"a":1,"a":2}' | Should -Match 'doppelt'
        Test-HUMxJsonText '{"\\u0061":1,"a":2}' | Should -BeNullOrEmpty
        Test-HUMxJsonText '{"x":"ä\"\\","y":[1,2]}' | Should -BeNullOrEmpty
    }
    It 'B3: kurzes Kennwort im OMA-Wert wird gesperrt' {
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = 'Test'; omaSettings = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.omaSettingString'; omaUri = './Vendor/MSFT/Policy/Config/Test/X'; value = '<Password>Geheim1!</Password>' }) }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Name 'Test' -Obj $o).Status | Should -Be 'gesperrt'
    }
    It 'B3: UTF-16-kodiertes Base64 mit Kennwort wird erkannt' {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('net user x /add; <Password>Geheim1!</Password>'))
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = 'Test'; omaSettings = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.omaSettingBase64'; omaUri = './Vendor/MSFT/Policy/Config/Test/Y'; value = $b64 }) }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Name 'Test' -Obj $o).Status | Should -Be 'gesperrt'
    }
    It 'B3: Name/Beschreibung mit "Password:" sperrt nicht' {
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'Password: 12 Zeichen'; description = 'Password: mindestens 12'; passwordRequired = $true }
        (Invoke-HUMusterSanitize -Typ 'Konfiguration' -Name 'Password: 12 Zeichen' -Obj $o).Status | Should -Be 'ok'
    }
}
