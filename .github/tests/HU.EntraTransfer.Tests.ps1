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
    Mock -ModuleName HU.EntraRestore Get-HUSecBaseline { [pscustomobject]@{ Values = @{ V1 = @{ accounts = @('11111111-1111-1111-1111-111111111111') } } } }
}

AfterAll {
    Remove-Module HU.EntraRestore -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item function:global:New-EtFail -ErrorAction SilentlyContinue
}

Describe 'Entra uebertragen (2.4.4)' {
    BeforeEach {
        $global:EtFx = @{}; $global:EtList = @{}; $global:EtWrites = @(); $global:EtAfter = $null; $global:EtAfterKey = ''
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
        @($p.Confirms | Where-Object { $_ -like '*Block Ausland*' }).Count | Should -Be 1
        $src.id | Should -Be 'q-loc'
        # von keiner Richtlinie verwendet: keine Sperre (leere Liste ist nicht "nicht lesbar")
        $global:EtList['Z|/identity/conditionalAccess/policies'] = @()
        $p2 = Get-HUEntraTransferPlan -TargetKey 'Z' -Settings $script:Set -Typ 'Benannter Ort' -Id 'q-loc' -Name 'Schulnetz' -Backup $src -ResolveKey 'Q'
        $p2.Blocks.Count | Should -Be 0
        @($p2.Notes | Where-Object { $_ -like '*von keiner CA-Richtlinie*' }).Count | Should -Be 1
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
        # inzwischen im Portal geaendert -> gesperrt
        $global:EtFx['Z|/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; blockMsolPowerShell = $true; allowInvitesFrom = 'none' }
        { Undo-HUEntraTransfer -Settings $script:Set -File $r.UndoFile -U $u -CheckOnly } | Should -Throw '*geaendert*'
    }
}
