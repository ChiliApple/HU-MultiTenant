#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer 2.4.4 Entra uebertragen (Core\HU.EntraRestore.psm1: Get-HUEntraTransferPlan, Invoke-HUEntraTransfer,
    Undo-HUEntraTransfer) - ohne Netzwerk.
.NOTES
    Graph wird ersetzt: Lesen aus $global:EtFx (Endpunkt-Muster -> Antwort), Listen aus $global:EtList, Schreiben in $global:EtWrites.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.EntraRestore.psm1') -Force -DisableNameChecking
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-ET-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:Tmp } }
    function global:New-EtFail([int]$Code) { $ex = New-Object System.Exception("Graph: $Code"); $ex.Data['StatusCode'] = $Code; return $ex }
    Mock -ModuleName HU.EntraRestore Write-HULog { }
    Mock -ModuleName HU.EntraRestore Start-Sleep { }
    Mock -ModuleName HU.EntraRestore Resolve-HUFlatMapIds { param($TenantKey, $Settings, $Map) $Map }
    Mock -ModuleName HU.EntraRestore Invoke-HUIntuneGraph {
        param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
        if ($Method -ne 'GET') {
            $global:EtWrites += [pscustomobject]@{ Tenant = $TenantKey; Method = $Method; Endpoint = $Endpoint; Body = $Body }
            if ($Method -eq 'POST') {
                $o = [pscustomobject]@{ id = 'neu1' }
                foreach ($k in $Body.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Body[$k] -Force }
                $global:EtFx["$Endpoint/neu1"] = $o
                return $o
            }
            if ($global:EtAfterKey) { $global:EtFx[$global:EtAfterKey] = $global:EtAfter }
            return $null
        }
        foreach ($k in @($global:EtFx.Keys | Sort-Object { $_.Length } -Descending)) { if ("$TenantKey|$Endpoint" -like "*$k*") { return $global:EtFx[$k] } }
        throw (New-EtFail 404)
    }
    Mock -ModuleName HU.EntraRestore Get-HUIntuneGraphAll {
        param($TenantKey, $Settings, $Endpoint, [switch]$V1)
        foreach ($k in @($global:EtList.Keys | Sort-Object { $_.Length } -Descending)) { if ("$TenantKey|$Endpoint" -like "*$k*") { return @($global:EtList[$k]) } }
        return @()
    }
    Mock -ModuleName HU.EntraRestore Get-HUSecBaseline {
        param($TenantKey, $Rules)
        $acc = if ($global:EtBg -and $global:EtBg.ContainsKey("$TenantKey")) { @($global:EtBg["$TenantKey"]) } else { @('11111111-1111-1111-1111-111111111111') }
        [pscustomobject]@{ Values = @{ V1 = @{ accounts = $acc } } }
    }
}

AfterAll {
    Remove-Module HU.EntraRestore -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item function:global:New-EtFail -ErrorAction SilentlyContinue
}

Describe 'Entra uebertragen (2.4.4)' {
    BeforeEach {
        $global:EtFx = @{}; $global:EtList = @{}; $global:EtWrites = @(); $global:EtAfter = $null; $global:EtAfterKey = ''; $global:EtBg = @{}
        $global:EtFx['Z|/users/11111111-1111-1111-1111-111111111111'] = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; accountEnabled = $true; userPrincipalName = 'notfall@ziel.example' }
    }

    It 'Ziel = Tenant des Musters sperrt; nicht freigegebene Art wirft' {
        $p = Get-HUEntraTransferPlan -TargetKey 'Q' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ blockMsolPowerShell = $true }) -ResolveKey 'Q'
        $p.Blocks[0] | Should -BeLike '*Muster stammt*'
        { Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authenticationMethodsPolicy' -Backup ([pscustomobject]@{}) -ResolveKey 'Q' } | Should -Throw '*nicht uebertragen*'
    }

    It 'Benannter Ort fehlt im Ziel: NEU anlegen, vertrauenswuerdig mit Anzahl betroffener Richtlinien, Nachpruefung, Rueckgaengig = loeschen' {
        $global:EtList['Z|/identity/conditionalAccess/policies'] = @([pscustomobject]@{ displayName = 'MFA ausser vertrauenswuerdig'; state = 'enabled'; conditions = [pscustomobject]@{ locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('AllTrusted') } } })
        $src = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'q-loc'; displayName = 'Schulnetz'; isTrusted = $true; ipRanges = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.iPv4CidrRange'; cidrAddress = '198.51.100.0/24' }) }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q-loc' -Name 'Schulnetz' -Backup $src -ResolveKey 'Q'
        $p.Blocks.Count | Should -Be 0
        $p.Method | Should -Be 'POST'
        $p.Body.ContainsKey('id') | Should -BeFalse
        @($p.Confirms | Where-Object { $_ -like "*1 Richtlinie(n)*MFA ausser vertrauenswuerdig*" }).Count | Should -Be 1
        $p.BreakGlass.Ok | Should -BeTrue
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Mismatch | Should -BeNullOrEmpty
        $r.Ok | Should -BeTrue
        @($global:EtWrites | Where-Object Method -eq 'POST').Count | Should -Be 1
        $u = Read-HUBackupJson $r.UndoFile
        "$($u.Kind)" | Should -Be 'entraCreated'
        (Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly).Text | Should -Be 'Loeschen moeglich'
        $res = Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u
        $res.Deleted | Should -BeTrue
        @($global:EtWrites | Where-Object Method -eq 'DELETE').Count | Should -Be 1
    }

    It '045 Ue-11: fehlendes Schreibrecht steht schon in der Vorschau (Hinweis, keine Sperre)' {
        $pl = '{"roles":["Policy.Read.All"]}'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pl)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $global:EtTok = "e30.$b64.sig"
        function global:Get-GraphToken { param($TenantKey, $Settings) $global:EtTok }
        $src = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'q'; displayName = 'only Austria'; countriesAndRegions = @('AT'); includeUnknownCountriesAndRegions = $false }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q' -Name 'only Austria' -Backup $src -ResolveKey 'Q'
        $p.Blocks.Count | Should -Be 0
        @($p.Warnings | Where-Object { $_ -like 'Schreibrecht Policy.ReadWrite.ConditionalAccess*' }).Count | Should -Be 1
        Remove-Item function:global:Get-GraphToken -ErrorAction SilentlyContinue
    }

    It 'Benannter Ort gleichen Namens im Ziel: aendern nur mit Haken, verwendende Richtlinien genannt' {
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'z-loc'; displayName = 'schulnetz ' })
        $global:EtFx['Z|/identity/conditionalAccess/namedLocations/z-loc'] = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'z-loc'; displayName = 'Schulnetz'; isTrusted = $false; ipRanges = @([pscustomobject]@{ cidrAddress = '192.0.2.0/24' }) }
        $global:EtList['Z|/identity/conditionalAccess/policies'] = @([pscustomobject]@{ displayName = 'Block Ausland'; state = 'enabled'; conditions = [pscustomobject]@{ locations = [pscustomobject]@{ excludeLocations = @('z-loc') } } })
        $src = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'q-loc'; displayName = 'Schulnetz'; isTrusted = $false; ipRanges = @([pscustomobject]@{ cidrAddress = '198.51.100.0/24' }) }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q-loc' -Name 'Schulnetz' -Backup $src -ResolveKey 'Q'
        $p.Method | Should -Be 'PATCH'
        $p.Endpoint | Should -BeLike '*/z-loc'
        # Anzahl: Liste mit einem Eintrag zaehlt 1, nicht 0
        $c1 = @($p.Changes | Where-Object { $_.Feld -eq 'ipRanges' })[0]
        $c1.Anzahl | Should -Be '1 -> 1'
        @($p.Confirms | Where-Object { $_ -like '*Block Ausland*' }).Count | Should -Be 1
        $src.id | Should -Be 'q-loc'
        # von keiner Richtlinie verwendet: keine Sperre (leere Liste ist nicht "nicht lesbar")
        $global:EtList['Z|/identity/conditionalAccess/policies'] = @()
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q-loc' -Name 'Schulnetz' -Backup $src -ResolveKey 'Q'
        $p2.Blocks.Count | Should -Be 0
        @($p2.Notes | Where-Object { $_ -like '*von keiner CA-Richtlinie*' }).Count | Should -Be 1
    }

    It 'Benannter Ort (Laender) angleichen auf genau ein Land: Liste mit einem Eintrag, kein Text (Graph 400)' {
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'z-c'; displayName = 'only Austria' })
        $global:EtFx['Z|/identity/conditionalAccess/namedLocations/z-c'] = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'z-c'; displayName = 'only Austria'; countriesAndRegions = @('DE', 'AT'); includeUnknownCountriesAndRegions = $false }
        $src = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'q-c'; displayName = 'only Austria'; countriesAndRegions = @('AT'); includeUnknownCountriesAndRegions = $false }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q-c' -Name 'only Austria' -Backup $src -ResolveKey 'Q'
        $p.Method | Should -Be 'PATCH'
        ($p.Body | ConvertTo-Json -Depth 10 -Compress) | Should -BeLike '*"countriesAndRegions":`["AT"`]*'
        $p.Changes[0].Anzahl | Should -Be "2 -> 1"
    }

    It 'Administratorzustimmung: Benutzer-Reviewer sperrt, Gruppe wird ueber den Namen zugeordnet' {
        $global:EtFx['Z|/policies/adminConsentRequestPolicy'] = [pscustomobject]@{ isEnabled = $false; notifyReviewers = $false; remindersEnabled = $false; requestDurationInDays = 30; reviewers = @() }
        $global:EtFx['Q|/groups/aaaaaaaa-0000-0000-0000-000000000001'] = [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000001'; displayName = 'IT-Admins' }
        $global:EtList['Z|/groups?'] = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000002'; displayName = 'it-admins' })
        $global:EtFx['Z|/groups/bbbbbbbb-0000-0000-0000-000000000002'] = [pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000002' }
        $src = [pscustomobject]@{ isEnabled = $true; notifyReviewers = $true; remindersEnabled = $true; requestDurationInDays = 14; reviewers = @([pscustomobject]@{ query = '/groups/aaaaaaaa-0000-0000-0000-000000000001/transitiveMembers'; queryType = 'MicrosoftGraph' }) }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Name 'Administratorzustimmung' -Backup $src -ResolveKey 'Q'
        $p.Blocks.Count | Should -Be 0
        @($p.Body.reviewers)[0].query | Should -Be '/groups/bbbbbbbb-0000-0000-0000-000000000002/transitiveMembers'
        # Reviewer nur im Ziel: Pflicht-Haken mit Namen (PUT ersetzt die Liste)
        $global:EtFx['Z|/policies/adminConsentRequestPolicy'] = [pscustomobject]@{ isEnabled = $true; notifyReviewers = $false; remindersEnabled = $false; requestDurationInDays = 30; reviewers = @([pscustomobject]@{ query = '/v1.0/users/dddddddd-0000-0000-0000-000000000004'; queryType = 'MicrosoftGraph' }) }
        $global:EtFx['Z|/users/dddddddd-0000-0000-0000-000000000004'] = [pscustomobject]@{ userPrincipalName = 'reviewer@ziel.example' }
        $px = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Name 'Administratorzustimmung' -Backup $src -ResolveKey 'Q'
        @($px.Confirms | Where-Object { $_ -like '*fallen weg*reviewer@ziel.example*' }).Count | Should -Be 1
        $src2 = [pscustomobject]@{ isEnabled = $true; reviewers = @([pscustomobject]@{ query = '/users/cccccccc-0000-0000-0000-000000000003'; queryType = 'MicrosoftGraph' }) }
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Name 'Administratorzustimmung' -Backup $src2 -ResolveKey 'Q'
        @($p2.Blocks | Where-Object { $_ -like '*einzelner Benutzer*' }).Count | Should -Be 1
    }

    It 'Verzeichniseinstellung fehlt im Ziel: POST mit kompletter Liste, Gruppe zugeordnet, EnableMSStandardBlockedWords nie, kein Rueckgaengig' {
        $global:EtFx['Q|/groups/aaaaaaaa-0000-0000-0000-000000000001'] = [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000001'; displayName = 'Teams-Ersteller' }
        $global:EtList['Z|/groups?'] = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000002'; displayName = 'Teams-Ersteller' })
        $src = [pscustomobject]@{ templateId = '62375ab9-6b52-47ed-826b-58e47e0e304b'; displayName = 'Group.Unified'; values = @(
                [pscustomobject]@{ name = 'EnableGroupCreation'; value = 'false' }, [pscustomobject]@{ name = 'GroupCreationAllowedGroupId'; value = 'aaaaaaaa-0000-0000-0000-000000000001' },
                [pscustomobject]@{ name = 'EnableMSStandardBlockedWords'; value = 'true' }, [pscustomobject]@{ name = 'UsageGuidelinesUrl'; value = '' }) }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Id 'x' -Name 'Group.Unified' -Backup $src -ResolveKey 'Q'
        $p.Blocks.Count | Should -Be 0
        $p.Method | Should -Be 'POST'
        $names = @($p.Body.values | ForEach-Object { $_.name })
        $names | Should -Not -Contain 'EnableMSStandardBlockedWords'
        $names | Should -Contain 'UsageGuidelinesUrl'
        @($p.Body.values | Where-Object { $_.name -eq 'GroupCreationAllowedGroupId' })[0].value | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        @($p.Confirms | Where-Object { $_ -like 'EnableGroupCreation = false*' }).Count | Should -Be 1
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Ok | Should -BeTrue
        $r.UndoFile | Should -BeNullOrEmpty
    }

    It 'Autorisierungsrichtlinie: angleichen mit Sicherung, Rueckgaengig nur solange unveraendert' {
        $live = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $false; allowInvitesFrom = 'everyone' }
        $global:EtFx['Z|/policies/authorizationPolicy'] = $live
        $global:EtAfterKey = 'Z|/policies/authorizationPolicy'
        $global:EtAfter = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true; allowInvitesFrom = 'everyone' }
        $src = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true; allowInvitesFrom = 'everyone' }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Name 'Autorisierungsrichtlinie' -Backup $src -ResolveKey 'Q'
        $p.Blocks.Count | Should -Be 0
        $p.Changes.Count | Should -Be 1
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Ok | Should -BeTrue
        $u = Read-HUBackupJson $r.UndoFile
        "$($u.Kind)" | Should -Be 'entraChanged'
        (Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly).Text | Should -Be 'Zuruecksetzen moeglich'
        # nur ein neuer Zeitstempel (von Entra gesetzt) sperrt nicht (053 B6)
        $global:EtFx['Z|/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true; allowInvitesFrom = 'everyone'; modifiedDateTime = '2026-10-24T10:00:00Z' }
        (Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly).Text | Should -Be 'Zuruecksetzen moeglich'
        # inzwischen im Portal geaendert -> gesperrt
        $global:EtFx['Z|/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true; allowInvitesFrom = 'none' }
        { Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly } | Should -Throw '*geaendert*'
    }
}

Describe 'Conditional Access uebertragen (2.4.5)' {
    BeforeEach {
        $global:EtFx = @{}; $global:EtList = @{}; $global:EtWrites = @(); $global:EtAfter = $null; $global:EtAfterKey = ''
        # Notfallkonten: Quelle q-bg, Ziel z-bg (je Tenant verschieden)
        $global:EtBg = @{ Q = @('aaaa0000-0000-0000-0000-00000000000b'); Z = @('bbbb0000-0000-0000-0000-00000000000b') }
        $global:EtFx['Z|/users/bbbb0000-0000-0000-0000-00000000000b'] = [pscustomobject]@{ id = 'bbbb0000-0000-0000-0000-00000000000b'; accountEnabled = $true; userPrincipalName = 'notfall@ziel.example' }
        $global:EtFx['Q|/groups/aaaaaaaa-0000-0000-0000-000000000001'] = [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-000000000001'; displayName = 'Lehrer' }
        $global:EtList['Z|/groups?'] = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000002'; displayName = 'lehrer'; securityEnabled = $true },
            [pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000003'; displayName = 'Schueler'; securityEnabled = $true },
            [pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000009'; displayName = 'Verteiler'; securityEnabled = $false; groupTypes = @() })
        $global:EtFx['Z|/groups/bbbbbbbb-0000-0000-0000-000000000002'] = [pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-000000000002' }
        $global:EtFx['Q|/identity/conditionalAccess/namedLocations/aaaaaaaa-0000-0000-0000-0000000000c1'] = [pscustomobject]@{ id = 'aaaaaaaa-0000-0000-0000-0000000000c1'; displayName = 'Schulnetz' }
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-0000000000c2'; displayName = 'Schulnetz' })
        $global:EtFx['Z|/identity/conditionalAccess/namedLocations/bbbbbbbb-0000-0000-0000-0000000000c2'] = [pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-0000000000c2' }
        $script:Ca = {
            [pscustomobject]@{ id = 'q-pol'; displayName = '201 MFA Lehrer'; state = 'enabled'; createdDateTime = '2025-01-01T00:00:00Z'
                conditions = [pscustomobject]@{
                    users = [pscustomobject]@{ includeUsers = @(); excludeUsers = @('aaaa0000-0000-0000-0000-00000000000b'); includeGroups = @('aaaaaaaa-0000-0000-0000-000000000001'); excludeGroups = @(); includeRoles = @(); excludeRoles = @() }
                    applications = [pscustomobject]@{ includeApplications = @('All'); excludeApplications = @() }
                    locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('aaaaaaaa-0000-0000-0000-0000000000c1') }
                    clientAppTypes = @('all') }
                grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('mfa') } }
        }
    }

    It 'Neu als Nur Bericht OHNE Zuweisung: Benutzer Keine, nur Notfallkonten des Ziels ausgenommen, Ort ueber den Namen, Rueckgaengig nur solange nicht eingeschaltet' {
        $src = & $script:Ca
        $src.conditions.users.excludeUsers = @('aaaa0000-0000-0000-0000-00000000000b', 'eeee0000-0000-0000-0000-000000000005')
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '201 MFA Lehrer' -Backup $src -ResolveKey 'Q' -SourceLabel 'Muster'
        $p.Blocks | Should -BeNullOrEmpty
        $p.Method | Should -Be 'POST'
        # fehlt im Ziel -> Originalname
        $p.Body.displayName | Should -Be '201 MFA Lehrer'
        $p.Body.state | Should -Be 'enabledForReportingButNotEnforced'
        @($p.Body.conditions.users.includeUsers) | Should -Be @('None')
        @($p.Body.conditions.users.excludeUsers) | Should -Be @('bbbb0000-0000-0000-0000-00000000000b')
        # keine Liste in der Liste (Graph 400 "does not match the schema")
        ($p.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"excludeUsers":`["bbbb0000-0000-0000-0000-00000000000b"`]*'
        @($p.Body.conditions.users.includeGroups | Where-Object { $_ }).Count | Should -Be 0
        @($p.Body.conditions.locations.excludeLocations) | Should -Be @('bbbbbbbb-0000-0000-0000-0000000000c2')
        # 2.5.1 Gruppen sind waehlbar (gleichnamige vorgewaehlt) - nur Konten bleiben in der Warnung
        @($p.Warnings | Where-Object { $_ -like '*Gruppen: Lehrer*' }).Count | Should -Be 0
        @($p.Warnings | Where-Object { $_ -like '*Ausnahmen Konten*' }).Count | Should -Be 1
        $go = @($p.Options | Where-Object Kind -eq 'group')
        $go.Count | Should -Be 1
        $go[0].Value | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        @($go[0].Choices | ForEach-Object Name) -join '|' | Should -Be 'lehrer|Schueler'
        $go[0].Value = ''   # wie bisher ohne Zuweisung uebertragen
        $p.BreakGlass.Ok | Should -BeTrue
        # Quelle bleibt unberuehrt
        @($src.conditions.users.includeGroups) | Should -Be @('aaaaaaaa-0000-0000-0000-000000000001')
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Ok | Should -BeTrue
        @($global:EtWrites | Where-Object Method -eq 'POST').Count | Should -Be 1
        $u = Read-HUBackupJson $r.UndoFile
        "$($u.Kind)" | Should -Be 'entraCreated'
        "$($u.Typ)" | Should -Be 'Conditional Access'
        (Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly).Text | Should -Be 'Loeschen moeglich'
        # 045 F5: eingeschaltet -> nicht loeschen
        $global:EtFx['/identity/conditionalAccess/policies/neu1'].state = 'enabled'
        { Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly } | Should -Throw '*EINGESCHALTET*'
    }

    It 'Mitgelieferte Vorlage (Registrierung der Sicherheitsinfos): Alle Benutzer, Gaeste-Ausnahme bleibt, Benutzeraktion -> ausgeschaltet' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $f = @(Get-ChildItem -LiteralPath (Join-Path $root 'Muster\mitgeliefert-ca-grundschutz') -Recurse -Filter '*Sicherheitsinfos*.json')[0]
        $src = Read-HUBackupJson $f.FullName
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'mitgeliefert-ca-grundschutz-04' -Name $src.displayName -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p.Blocks | Should -BeNullOrEmpty
        @($p.Body.conditions.users.includeUsers) | Should -Be @('All')
        @($p.Body.conditions.users.excludeUsers) | Should -Be @('bbbb0000-0000-0000-0000-00000000000b')
        $p.Body.conditions.users.excludeGuestsOrExternalUsers.externalTenants.membershipKind | Should -Be 'all'
        $p.Body.conditions.users.excludeGuestsOrExternalUsers.externalTenants.'@odata.type' | Should -Be '#microsoft.graph.conditionalAccessAllExternalTenants'
        $p.Body.state | Should -Be 'disabled'
        @($p.Body.conditions.applications.includeUserActions) | Should -Be @('urn:user:registersecurityinfo')
        @($p.Body.conditions.locations.excludeLocations) | Should -Be @('AllTrusted')
    }

    It 'Mitgelieferte Vorlagen: MFA fuer Gaeste (Haken Gaeste), MFA fuer alle behaelt Rollen-Ausnahme, Phishing-resistent prueft eingebaute Staerke' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $rd = { param($n) Read-HUBackupJson (@(Get-ChildItem -LiteralPath (Join-Path $root 'Muster') -Recurse -Filter "*$n*.json")[0].FullName) }
        $dsId = 'd29b2b05-8046-44ba-8758-1e26182fcf32'
        $global:EtFx["Z|/roleManagement/directory/roleDefinitions/$dsId"] = [pscustomobject]@{ id = $dsId; isBuiltIn = $true; displayName = 'Directory Synchronization Accounts' }
        # Gaeste: Benutzer leer + includeGuestsOrExternalUsers; ohne Haken -> Keine
        $g = & $rd 'MFA_fuer_Gaeste'
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'g' -Name $g.displayName -Backup $g -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p.Blocks | Should -BeNullOrEmpty
        @($p.Body.conditions.users.includeUsers).Count | Should -Be 0
        $p.Body.conditions.users.includeGuestsOrExternalUsers.externalTenants.membershipKind | Should -Be 'all'
        @($p.Options | Where-Object Key -eq 'guests').Count | Should -Be 1
        @($p.Warnings | Where-Object { $_ -like '*Gaeste*' }).Count | Should -Be 0
        ($p.Options | Where-Object Key -eq 'guests').Value = $false
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Ok | Should -BeTrue
        $w = @($global:EtWrites | Where-Object Method -eq 'POST')[-1]
        ($w.Body | ConvertTo-Json -Depth 20 -Compress) | Should -Not -BeLike '*includeGuestsOrExternalUsers*'
        ($w.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"includeUsers":`["None"`]*'
        # MFA fuer alle: Haken 'Alle' bleibt an -> Ausnahme Directory Synchronization Accounts wird mitgeschickt
        $a = & $rd 'MFA_fuer_alle_Benutzer'
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'a' -Name $a.displayName -Backup $a -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p2.Blocks | Should -BeNullOrEmpty
        [void](Invoke-HUEntraTransfer -Plan $p2 -Settings $script:Set)
        $w2 = @($global:EtWrites | Where-Object Method -eq 'POST')[-1]
        ($w2.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike ('*"excludeRoles":`["' + $dsId + '"`]*')
        ($w2.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"includeUsers":`["All"`]*'
        # Phishing-resistent: eingebaute Staerke im Ziel lesbar -> Hinweis; nicht lesbar -> Sperre
        $ph = & $rd 'Phishing-resistente'
        $global:EtFx['Z|/roleManagement/directory/roleDefinitions/'] = [pscustomobject]@{ id = 'r'; isBuiltIn = $true; displayName = 'Admin-Rolle' }
        $global:EtFx['Z|/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000004'] = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; policyType = 'builtIn' }
        $p3 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'ph' -Name $ph.displayName -Backup $ph -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p3.Blocks | Should -BeNullOrEmpty
        @($p3.Notes | Where-Object { $_ -like "*Phishing-resistant MFA*eingebaut*" }).Count | Should -Be 1
        $p3.Body.grantControls.authenticationStrength.id | Should -Be '00000000-0000-0000-0000-000000000004'
        # Einzelabruf ohne $select (Learn: keine OData-Parameter; mit $select sperrte die Vorschau im Test 25.10.)
        Should -Invoke -ModuleName HU.EntraRestore Invoke-HUIntuneGraph -Times 0 -ParameterFilter { $Endpoint -like '/policies/authenticationStrengthPolicies/*select*' }
        $global:EtFx.Remove('Z|/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000004')
        $p4 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'ph' -Name $ph.displayName -Backup $ph -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        @($p4.Blocks | Where-Object { $_ -like '*Authentifizierungsstaerke*nicht lesbar*' }).Count | Should -Be 1
    }

    It "Gibt es die Richtlinie im Ziel schon: neue heisst '(von Muster)', die bestehende bleibt" {
        $global:EtList['Z|/identity/conditionalAccess/policies'] = @([pscustomobject]@{ displayName = '201 mfa lehrer'; state = 'enabled' })
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '201 MFA Lehrer' -Backup (& $script:Ca) -ResolveKey 'Q' -SourceLabel 'Muster'
        $p.Body.displayName | Should -Be '201 MFA Lehrer (von Muster)'
    }

    It 'Rollen: eingebaute werden angeboten (Haken), ohne Haken Benutzer Keine; eigene Rolle sperrt' {
        $rid = '62e90394-69f5-4237-9190-012177145e10'
        $global:EtFx["Z|/roleManagement/directory/roleDefinitions/$rid"] = [pscustomobject]@{ id = $rid; isBuiltIn = $true; displayName = 'Global Administrator' }
        $src = & $script:Ca
        $src.conditions.users.includeGroups = @(); $src.conditions.users.includeRoles = @($rid)
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '102' -Backup $src -ResolveKey 'Q' -SourceLabel 'Muster'
        $p.Blocks | Should -BeNullOrEmpty
        @($p.Options).Count | Should -Be 1
        $p.Options[0].Text | Should -BeLike '*Global Administrator*'
        @($p.Body.conditions.users.includeRoles) | Should -Be @($rid)
        # 053 B1: Rollen-Pfad sendet eine leere Liste, nicht null
        ($p.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"includeUsers":`[`]*'
        [void](Invoke-HUEntraTransfer -Plan $p -Settings $script:Set)
        (@($global:EtWrites | Where-Object Method -eq 'POST')[-1].Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"includeUsers":`[`]*'
        $global:EtWrites = @()
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '102' -Backup $src -ResolveKey 'Q' -SourceLabel 'Muster'
        $p.Options[0].Value = $false
        [void](Invoke-HUEntraTransfer -Plan $p -Settings $script:Set)
        $w = @($global:EtWrites | Where-Object Method -eq 'POST')[0]
        @($w.Body.conditions.users.includeUsers) | Should -Be @('None')
        @($w.Body.conditions.users.includeRoles | Where-Object { $_ }).Count | Should -Be 0

        $global:EtFx["Z|/roleManagement/directory/roleDefinitions/$rid"] = [pscustomobject]@{ id = $rid; isBuiltIn = $false; displayName = 'Eigene Rolle' }
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '102' -Backup $src -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p2.Blocks | Where-Object { $_ -like '*eigene Rolle*' }).Count | Should -Be 1
    }

    It "Benutzer 'Alle' ist waehlbar: mit Haken All, ohne Haken None" {
        $src = & $script:Ca
        $src.conditions.users.includeUsers = @('All'); $src.conditions.users.includeGroups = @()
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '901' -Backup $src -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p.Body.conditions.users.includeUsers) | Should -Be @('All')
        @($p.Options | Where-Object Key -eq 'allUsers').Count | Should -Be 1
        $p.Options[0].Value = $false
        [void](Invoke-HUEntraTransfer -Plan $p -Settings $script:Set)
        @(@($global:EtWrites | Where-Object Method -eq 'POST')[0].Body.conditions.users.includeUsers) | Should -Be @('None')
        # Liste, kein einzelner Text (Graph 400)
        (@($global:EtWrites | Where-Object Method -eq 'POST')[0].Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"includeUsers":`["None"`]*'
    }

    It '2.5.1 Gruppen-Plaetze (huGruppen): gewaehlte Gruppen werden zugewiesen, ohne Auswahl Benutzer Keine' {
        $src = & $script:Ca
        $src.conditions.users.includeGroups = @(); $src.conditions.users.excludeUsers = @()
        $src | Add-Member -NotePropertyName huGruppen -NotePropertyValue @([pscustomobject]@{ feld = 'includeGroups'; name = 'Schueler' }, [pscustomobject]@{ feld = 'excludeGroups'; name = 'Ausnahmen MFA' })
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '202 MFA Schueler' -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert' -SourceNames @{ 'aaaaaaaa-0000-0000-0000-0000000000c1' = 'Schulnetz' }
        $p.Blocks | Should -BeNullOrEmpty
        # Ort ueber den Namen aus dem Paket (mitgeliefert: in keinem Tenant nachlesbar)
        @($p.Body.conditions.locations.excludeLocations) | Should -Be @('bbbbbbbb-0000-0000-0000-0000000000c2')
        $go = @($p.Options | Where-Object Kind -eq 'group')
        $go.Count | Should -Be 2
        $go[0].Value | Should -Be 'bbbbbbbb-0000-0000-0000-000000000003'
        $go[1].Value | Should -Be ''
        ($p.Body | ConvertTo-Json -Depth 20 -Compress) | Should -Not -BeLike '*huGruppen*'
        $go[1].Value = 'bbbbbbbb-0000-0000-0000-000000000002'
        [void](Invoke-HUEntraTransfer -Plan $p -Settings $script:Set)
        $j = (@($global:EtWrites | Where-Object Method -eq 'POST')[-1].Body | ConvertTo-Json -Depth 20 -Compress)
        $j | Should -BeLike '*"includeGroups":`["bbbbbbbb-0000-0000-0000-000000000003"`]*'
        $j | Should -BeLike '*"excludeGroups":`["bbbbbbbb-0000-0000-0000-000000000002"`]*'
        $j | Should -BeLike '*"includeUsers":`[`]*'
        # nichts gewaehlt -> Keine
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '202 MFA Schueler' -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert' -SourceNames @{ 'aaaaaaaa-0000-0000-0000-0000000000c1' = 'Schulnetz' }
        foreach ($o in @($p2.Options | Where-Object Kind -eq 'group')) { $o.Value = '' }
        [void](Invoke-HUEntraTransfer -Plan $p2 -Settings $script:Set)
        $j2 = (@($global:EtWrites | Where-Object Method -eq 'POST')[-1].Body | ConvertTo-Json -Depth 20 -Compress)
        $j2 | Should -BeLike '*"includeUsers":`["None"`]*'
        $j2 | Should -BeLike '*"includeGroups":`[`]*'
    }

    It '2.5.1 Gruppen im Ziel nicht lesbar: Hinweis, keine Plaetze, Gruppen in der Warnung' {
        $global:EtList.Remove('Z|/groups?')
        Mock -ModuleName HU.EntraRestore Get-HUIntuneGraphAll -ParameterFilter { $Endpoint -like '/groups?*' } { throw (New-EtFail 403) }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name '201 MFA Lehrer' -Backup (& $script:Ca) -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p.Options | Where-Object Kind -eq 'group').Count | Should -Be 0
        @($p.Warnings | Where-Object { $_ -like '*Gruppen im Ziel nicht lesbar*' }).Count | Should -Be 1
        @($p.Warnings | Where-Object { $_ -like '*NICHT uebertragen*Gruppen: Lehrer*' }).Count | Should -Be 1
    }

    It 'Mitgeliefertes Praxis-Set Schule: alle Richtlinien planbar (Orte ueber Paket-Namen, Gruppen-Plaetze)' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $pk = Join-Path $root 'Muster\mitgeliefert-ca-schule-praxis'
        $ix = Read-HUBackupJson (Join-Path $pk 'index.json')
        $names = @{}; foreach ($it in @($ix.Items | Where-Object Typ -eq 'Benannter Ort')) { $names["$($it.Id)".ToLowerInvariant()] = "$($it.Name)" }
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @($ix.Items | Where-Object Typ -eq 'Benannter Ort' | ForEach-Object { [pscustomobject]@{ id = "z-$($_.Name)"; displayName = $_.Name } })
        $global:EtFx['Z|/roleManagement/directory/roleDefinitions/'] = [pscustomobject]@{ id = 'r'; isBuiltIn = $true; displayName = 'Rolle' }
        $global:EtFx['Z|/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000004'] = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; policyType = 'builtIn' }
        # Live-Test 25.10.: Quelle mitgeliefert hat KEINE Notfallkonten (leere Liste) - darf nicht scheitern
        $global:EtBg['mitgeliefert'] = @($null)
        # 100: alle eingebauten Rollen des Ziels (eigene Rolle nicht)
        $global:EtList['Z|/roleManagement/directory/roleDefinitions'] = @(
            [pscustomobject]@{ id = '62e90394-69f5-4237-9190-012177145e10'; templateId = '62e90394-69f5-4237-9190-012177145e10'; displayName = 'Global Administrator'; isBuiltIn = $true },
            [pscustomobject]@{ id = '3a2c62db-5318-420d-8d74-23affee5d9d5'; templateId = '3a2c62db-5318-420d-8d74-23affee5d9d5'; displayName = 'Intune Administrator'; isBuiltIn = $true },
            [pscustomobject]@{ id = 'cccccccc-0000-0000-0000-000000000001'; templateId = 'cccccccc-0000-0000-0000-000000000001'; displayName = 'Eigene Rolle'; isBuiltIn = $false },
            # 059 B1/B3: Benutzer-/Gast-Rollen nie ausnehmen, abgeschaltete nicht, ohne templateId -> id
            [pscustomobject]@{ id = 'a0b1b346-4d3e-4e8b-98f8-753987be4970'; templateId = 'a0b1b346-4d3e-4e8b-98f8-753987be4970'; displayName = 'User'; isBuiltIn = $true },
            [pscustomobject]@{ id = '10dae51f-b6af-4016-8d66-8c2a99b929b3'; templateId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'; displayName = 'Guest User'; isBuiltIn = $true },
            [pscustomobject]@{ id = 'dddddddd-0000-0000-0000-000000000001'; templateId = 'dddddddd-0000-0000-0000-000000000001'; displayName = 'Abgeschaltet'; isBuiltIn = $true; isEnabled = $false },
            [pscustomobject]@{ id = '194ae4cb-b126-40b2-bd5b-6091b380977d'; displayName = 'Security Administrator'; isBuiltIn = $true })
        $n = 0
        foreach ($it in @($ix.Items | Where-Object Typ -eq 'Conditional Access')) {
            $src = Read-HUBackupJson (Join-Path $pk $it.File)
            $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id $it.Id -Name $it.Name -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert' -SourceNames $names
            $p.Blocks | Should -BeNullOrEmpty -Because $it.Name
            (Invoke-HUEntraTransfer -Plan $p -Settings $script:Set).Ok | Should -BeTrue -Because $it.Name
            $n++
            if ($it.Name -eq '201 - MFA Lehrer') { @($p.Options | Where-Object Kind -eq 'group' | ForEach-Object Slot) -join '|' | Should -Be 'Lehrer|Ausnahmen MFA Lehrer' }
            if ($it.Name -like '100 *') {
                @($p.Body.conditions.users.excludeRoles) -join ',' | Should -Be '62e90394-69f5-4237-9190-012177145e10,3a2c62db-5318-420d-8d74-23affee5d9d5,194ae4cb-b126-40b2-bd5b-6091b380977d'
                @($p.Body.conditions.users.includeUsers) | Should -Be @('All')
                ($p.Body | ConvertTo-Json -Depth 20 -Compress) | Should -Not -BeLike '*huRollen*'
                @($p.Notes | Where-Object { $_ -like '*alle 3 eingebauten Admin-Rollen*' }).Count | Should -Be 1
            }
            if ($it.Name -like '900 *') { $p.Body.conditions.authenticationFlows.transferMethods | Should -Be 'deviceCodeFlow' }
            if ($it.Name -like '902 *') { @($p.Body.conditions.locations.includeLocations) | Should -Be @('z-Geblockte Standorte') }
        }
        $n | Should -Be 15
        # Rollen im Ziel nicht lesbar -> 100 gesperrt (sonst waeren alle Admins ausgesperrt)
        Mock -ModuleName HU.EntraRestore Get-HUIntuneGraphAll -ParameterFilter { $Endpoint -like '/roleManagement/directory/roleDefinitions*' } { throw (New-EtFail 403) }
        $i100 = @($ix.Items | Where-Object { $_.Name -like '100 *' })[0]
        $p100 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id $i100.Id -Name $i100.Name -Backup (Read-HUBackupJson (Join-Path $pk $i100.File)) -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert' -SourceNames $names
        @($p100.Blocks | Where-Object { $_ -like '*Rollen im Ziel nicht lesbar*' }).Count | Should -Be 1
    }

    It '2.5.1 Laenderwahl beim Ort: fest + angehakt wird geschrieben, vorhandener Ort sperrt' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $src = Read-HUBackupJson (@(Get-ChildItem -LiteralPath (Join-Path $root 'Muster\mitgeliefert-ca-geoblock-admins') -Recurse -Filter '*Laender*.json')[0].FullName)
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @()
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id $src.id -Name $src.displayName -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p.Blocks | Should -BeNullOrEmpty
        $p.Method | Should -Be 'POST'
        @($p.CountryFixed) | Should -Be @('AT')
        @($p.Options).Count | Should -Be 8
        @($p.Options | Where-Object Value | ForEach-Object Key) -join ',' | Should -Be 'country:DE,country:CH,country:LI'
        $p.Body.ContainsKey('huLaenderwahl') | Should -BeFalse
        ($p.Options | Where-Object Key -eq 'country:CH').Value = $false
        ($p.Options | Where-Object Key -eq 'country:SI').Value = $true
        $r = Invoke-HUEntraTransfer -Plan $p -Settings $script:Set
        $r.Mismatch | Should -BeNullOrEmpty
        $w = @($global:EtWrites | Where-Object Method -eq 'POST')[-1]
        @($w.Body.countriesAndRegions) -join ',' | Should -Be 'AT,DE,LI,SI'
        # nur ein Land: trotzdem Liste
        foreach ($o in $p.Options) { $o.Value = $false }
        InModuleScope HU.EntraRestore -Parameters @{ P = $p } { param($P) Set-HUErTrCountryBody $P }
        ($p.Body | ConvertTo-Json -Depth 5 -Compress) | Should -BeLike '*"countriesAndRegions":`["AT"`]*'
        ($p.Changes | Where-Object Feld -eq 'countriesAndRegions').Anzahl | Should -Be '0 -> 1'
        # vorhanden -> gesperrt
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'x'; displayName = $src.displayName; '@odata.type' = '#microsoft.graph.countryNamedLocation'; countriesAndRegions = @('AT') })
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id $src.id -Name $src.displayName -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        @($p2.Blocks | Where-Object { $_ -like '*gibt es im Ziel schon*Laenderwahl*' }).Count | Should -Be 1
    }

    It '2.5.1 Autorisierungsrichtlinie aus dem Muster: Zustimmungsrechte fuer eigene Ressourcen des Ziels bleiben' {
        $global:EtFx['Z|/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $false
            defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $true; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-legacy', 'ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team') } }
        $global:EtList['Z|/policies/permissionGrantPolicies'] = @()
        $src = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true
            defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-low') } }
        $p = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Name 'Autorisierungsrichtlinie' -Backup $src -ResolveKey 'mitgeliefert' -SourceLabel 'Mitgeliefert'
        $p.Blocks | Should -BeNullOrEmpty
        @($p.Body.defaultUserRolePermissions.permissionGrantPoliciesAssigned) -join ',' | Should -Be 'ManagePermissionGrantsForSelf.microsoft-user-default-low,ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team'
        @($p.Confirms | Where-Object { $_ -like '*eigene Apps*' }).Count | Should -Be 0
        # Muster bleibt unberuehrt
        @($src.defaultUserRolePermissions.permissionGrantPoliciesAssigned).Count | Should -Be 1
    }

    It '045 F1/Ue-5: fehlende Notfallkonten im Ziel, Ort fehlt, Dienstprinzipale sperren' {
        $global:EtBg['Z'] = @()
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup (& $script:Ca) -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p2.Blocks | Where-Object { $_ -like '*keine Notfallkonten*' }).Count | Should -Be 1
        $global:EtBg['Z'] = @('bbbb0000-0000-0000-0000-00000000000b')

        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @()
        $p3 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup (& $script:Ca) -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p3.Blocks | Where-Object { $_ -like "*Ort 'Schulnetz'*zuerst den Ort*" }).Count | Should -Be 1

        $src4 = & $script:Ca
        $src4.conditions | Add-Member -NotePropertyName clientApplications -NotePropertyValue ([pscustomobject]@{ includeServicePrincipals = @('dddd0000-0000-0000-0000-000000000004') })
        $global:EtList['Z|/identity/conditionalAccess/namedLocations'] = @([pscustomobject]@{ id = 'bbbbbbbb-0000-0000-0000-0000000000c2'; displayName = 'Schulnetz' })
        $p4 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup $src4 -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p4.Blocks | Where-Object { $_ -like '*Workload-Identitaeten*' }).Count | Should -Be 1
        # 054 B1: ein einzelner Wert wird im Body zur Liste
        $src7 = & $script:Ca
        $src7.grantControls.builtInControls = 'mfa'
        $p7 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup $src7 -ResolveKey 'Q' -SourceLabel 'Muster'
        ($p7.Body | ConvertTo-Json -Depth 20 -Compress) | Should -BeLike '*"builtInControls":`["mfa"`]*'
        # 053 B2/B3: eigene Steuerelemente und Dienstprinzipal-Filter sperren
        $src5 = & $script:Ca
        $src5.grantControls | Add-Member -NotePropertyName customAuthenticationFactors -NotePropertyValue @('MeinControl')
        $p5 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup $src5 -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p5.Blocks | Where-Object { $_ -like '*customAuthenticationFactors*' }).Count | Should -Be 1
        $src6 = & $script:Ca
        $src6.conditions | Add-Member -NotePropertyName clientApplications -NotePropertyValue ([pscustomobject]@{ servicePrincipalFilter = [pscustomobject]@{ mode = 'include'; rule = 'CustomSecurityAttribute.Schule_Typ -eq "x"' } })
        $p6 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Conditional Access' -Id 'q-pol' -Name 'x' -Backup $src6 -ResolveKey 'Q' -SourceLabel 'Muster'
        @($p6.Blocks | Where-Object { $_ -like '*servicePrincipalFilter*' }).Count | Should -Be 1
        @($global:EtWrites).Count | Should -Be 0
    }
}
