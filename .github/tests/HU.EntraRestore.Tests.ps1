#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.EntraRestore.psm1 (Entra-Einstellungen zurueckschreiben) - ohne Netzwerk.
.NOTES
    Graph-Aufrufe werden ersetzt: Lesen aus $global:ErFx (Endpunkt-Muster -> Antwort), Schreiben landet in $global:ErWrites.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.EntraRestore.psm1') -Force -DisableNameChecking
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-ER-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:Tmp } }

    function global:New-ErFail([int]$Code) { $ex = New-Object System.Exception("Graph GET: $Code"); $ex.Data['StatusCode'] = $Code; return $ex }
    Mock -ModuleName HU.EntraRestore Write-HULog { }
    Mock -ModuleName HU.EntraRestore Invoke-HUIntuneGraph {
        param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
        if ($Method -ne 'GET') {
            $global:ErWrites += [pscustomobject]@{ Method = $Method; Endpoint = $Endpoint; Body = $Body }
            if ($global:ErWriteFail) { throw $global:ErWriteFail }
            if ($global:ErAfter) { $global:ErFx[$global:ErAfterKey] = $global:ErAfter }
            return $null
        }
        foreach ($k in @($global:ErFx.Keys | Sort-Object { $_.Length } -Descending)) {
            if ($Endpoint -like "*$k*") { $h = $global:ErFx[$k]; if ($h -is [scriptblock]) { return (& $h) }; return $h }
        }
        throw (New-ErFail 404)
    }
    Mock -ModuleName HU.EntraRestore Get-HUIntuneGraphAll {
        param($TenantKey, $Settings, $Endpoint, [switch]$V1)
        foreach ($k in @($global:ErList.Keys)) { if ($Endpoint -like "*$k*") { return @($global:ErList[$k]) } }
        return @()
    }
    Mock -ModuleName HU.EntraRestore Get-HUSecBaseline { [pscustomobject]@{ Values = @{ V1 = @{ accounts = @($global:ErBg) } } } }
}

AfterAll {
    Remove-Module HU.EntraRestore -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item function:global:New-ErFail -ErrorAction SilentlyContinue
}

Describe 'Entra zurueckschreiben' {
    BeforeEach {
        $global:ErFx = @{}; $global:ErList = @{}; $global:ErWrites = @(); $global:ErWriteFail = $null; $global:ErAfter = $null; $global:ErAfterKey = ''
        $global:ErBg = @('11111111-1111-1111-1111-111111111111')
        $global:ErFx['/users/11111111-1111-1111-1111-111111111111'] = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; accountEnabled = $true; userPrincipalName = 'notfall@schule.example' }
    }

    It 'nur die freigegebenen Arten' {
        Get-HUEntraRestoreKind 'Entra-Einstellung' 'authorizationPolicy' | Should -Be 'authz'
        Get-HUEntraRestoreKind 'Entra-Einstellung' 'adminConsentRequestPolicy' | Should -Be 'consent'
        Get-HUEntraRestoreKind 'Benannter Ort' 'x' | Should -Be 'location'
        Get-HUEntraRestoreKind 'Verzeichniseinstellung' 'x' | Should -Be 'groupSetting'
        Get-HUEntraRestoreKind 'Entra-Einstellung' 'authenticationMethodsPolicy' | Should -Be ''
        Get-HUEntraRestoreKind 'Entra-Einstellung' 'deviceRegistrationPolicy' | Should -Be ''
        Get-HUEntraRestoreKind 'Entra-Einstellung' 'securityDefaults' | Should -Be ''
    }

    Context 'Autorisierungsrichtlinie' {
        BeforeEach {
            $global:ErFx['/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; allowInvitesFrom = 'everyone'; allowedToUseSSPR = $true; blockMsolPowerShell = $true; guestUserRoleId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'
                defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $false; allowedToCreateSecurityGroups = $false; allowedToCreateTenants = $false; allowedToReadBitlockerKeysForOwnedDevice = $true; allowedToReadOtherUsers = $true; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team') } }
        }
        It 'schreibt nur Abweichungen, Unterobjekt vollstaendig, verworfene Felder werden gezeigt' {
            $bk = [pscustomobject]@{ id = 'authorizationPolicy'; displayName = 'Authorization Policy'; allowInvitesFrom = 'adminsAndGuestInviters'; allowedToUseSSPR = $true; blockMsolPowerShell = $true; neuesFeld = 1
                defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $true; allowedToCreateSecurityGroups = $false; allowedToCreateTenants = $false; allowedToReadBitlockerKeysForOwnedDevice = $true; allowedToReadOtherUsers = $true; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForOwnedResource.microsoft-dynamically-managed-permissions-for-team') } }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Name 'Autorisierung' -Backup $bk
            $p.Blocks.Count | Should -Be 0
            $p.Method | Should -Be 'PATCH'
            @($p.Changes.Feld) | Should -Be @('allowInvitesFrom', 'defaultUserRolePermissions.allowedToCreateApps')
            @($p.Body.Keys | Sort-Object) | Should -Be @('allowInvitesFrom', 'defaultUserRolePermissions')
            $p.Body.defaultUserRolePermissions.Count | Should -Be 6
            @($p.Dropped) | Should -Contain 'neuesFeld'
            @($p.Dropped) | Should -Not -Contain 'displayName'
            $p.BreakGlass.Ok | Should -BeTrue
        }
        It 'sperrt allowedToReadOtherUsers=false und fremde Gast-Rollen' {
            $bk = [pscustomobject]@{ guestUserRoleId = '00000000-0000-0000-0000-000000000001'
                defaultUserRolePermissions = [pscustomobject]@{ allowedToReadOtherUsers = $false } }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*allowedToReadOtherUsers*' }).Count | Should -Be 1
            @($p.Blocks | Where-Object { $_ -like '*guestUserRoleId*' }).Count | Should -Be 1
            $p.Body.ContainsKey('guestUserRoleId') | Should -BeFalse
        }
        It 'SSPR aus und Einladen niemand brauchen Bestaetigung; fehlende Zustimmungsrichtlinie sperrt' {
            $global:ErList['/policies/permissionGrantPolicies'] = @([pscustomobject]@{ id = 'microsoft-user-default-low' })
            $bk = [pscustomobject]@{ allowInvitesFrom = 'none'; allowedToUseSSPR = $false
                defaultUserRolePermissions = [pscustomobject]@{ permissionGrantPoliciesAssigned = @('managePermissionGrantsForSelf.eigene-richtlinie') } }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup $bk
            $p.Confirms.Count | Should -Be 3   # none, SSPR, entfernte OwnedResource-Rechte
            @($p.Blocks | Where-Object { $_ -like "*eigene-richtlinie*" }).Count | Should -Be 1
        }
        It 'ohne Notfallkonten kein Schreiben' {
            $global:ErBg = @()
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            @($p.Blocks | Where-Object { $_ -like '*Notfallkonten*' }).Count | Should -Be 1
            { Invoke-HUEntraRestore -Plan $p -Settings $script:Set } | Should -Throw '*Nicht zurueckgeschrieben*'
        }
        It 'deaktiviertes Notfallkonto sperrt' {
            $global:ErFx['/users/11111111-1111-1111-1111-111111111111'] = [pscustomobject]@{ accountEnabled = $false; userPrincipalName = 'notfall@schule.example' }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            @($p.Blocks | Where-Object { $_ -like '*deaktiviert*' }).Count | Should -Be 1
        }
        It 'schreibt, sichert vorher und prueft nach' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Name 'Autorisierung' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            $after = $global:ErFx['/policies/authorizationPolicy'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $after.allowInvitesFrom = 'adminsAndGuestInviters'
            $global:ErAfter = $after; $global:ErAfterKey = '/policies/authorizationPolicy'
            $r = Invoke-HUEntraRestore -Plan $p -Settings $script:Set
            $r.Ok | Should -BeTrue
            $global:ErWrites.Count | Should -Be 1
            $global:ErWrites[0].Method | Should -Be 'PATCH'
            $global:ErWrites[0].Body.allowInvitesFrom | Should -Be 'adminsAndGuestInviters'
            Test-Path -LiteralPath $r.BackupFile | Should -BeTrue
            $r.BackupFile | Should -BeLike '*_vor-zurueckschreiben*'
        }
        It 'Nachpruefung meldet Abweichung' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            $r = Invoke-HUEntraRestore -Plan $p -Settings $script:Set
            $r.Ok | Should -BeFalse
            @($r.Mismatch).Count | Should -Be 1
        }
        It 'bricht ab, wenn sich der Live-Stand seit der Vorschau geaendert hat' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            $global:ErFx['/policies/authorizationPolicy'].blockMsolPowerShell = $false
            { Invoke-HUEntraRestore -Plan $p -Settings $script:Set } | Should -Throw '*seit der Vorschau*'
            $global:ErWrites.Count | Should -Be 0
        }
        It 'fehlendes Schreibrecht wird verstaendlich gemeldet' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'adminsAndGuestInviters' })
            $global:ErWriteFail = New-ErFail 403
            { Invoke-HUEntraRestore -Plan $p -Settings $script:Set } | Should -Throw '*Policy.ReadWrite.Authorization*'
        }
        It 'nichts zu tun, wenn der Tenant schon dem Backup entspricht' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{ allowInvitesFrom = 'everyone' })
            $p.Changes.Count | Should -Be 0
            { Invoke-HUEntraRestore -Plan $p -Settings $script:Set } | Should -Throw '*Nichts zu schreiben*'
        }
    }

    Context 'Administratorzustimmung' {
        BeforeEach {
            $global:ErFx['/policies/adminConsentRequestPolicy'] = [pscustomobject]@{ id = 'x'; version = 3; isEnabled = $false; notifyReviewers = $false; remindersEnabled = $false; requestDurationInDays = 30; reviewers = @() }
        }
        It 'PUT mit allen fuenf Feldern, version nie' {
            $bk = [pscustomobject]@{ isEnabled = $true; notifyReviewers = $true; remindersEnabled = $true; requestDurationInDays = 30; version = 1
                reviewers = @([pscustomobject]@{ query = '/users/11111111-1111-1111-1111-111111111111'; queryType = 'MicrosoftGraph'; queryRoot = $null }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Backup $bk
            $p.Method | Should -Be 'PUT'
            $p.Blocks.Count | Should -Be 0
            @($p.Body.Keys | Sort-Object) | Should -Be @('isEnabled', 'notifyReviewers', 'remindersEnabled', 'requestDurationInDays', 'reviewers')
            $p.Body.reviewers[0].ContainsKey('queryRoot') | Should -BeFalse
            $p.BreakGlass | Should -BeFalse
        }
        It 'unbekannter Reviewer sperrt' {
            $bk = [pscustomobject]@{ isEnabled = $true; reviewers = @([pscustomobject]@{ query = '/users/22222222-2222-2222-2222-222222222222'; queryType = 'MicrosoftGraph' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*22222222*' }).Count | Should -Be 1
        }
    }

    Context 'Benannter Ort' {
        It 'geloeschter Ort wird nicht neu angelegt' {
            $bk = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'loc1'; displayName = 'Schule'; ipRanges = @([pscustomobject]@{ cidrAddress = '198.51.100.0/24' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Benannter Ort' -Id 'loc1' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*gibt es nicht mehr*' }).Count | Should -Be 1
        }
        It 'IP-Ort: ganze Liste mit Typen, vertrauenswuerdig braucht Bestaetigung' {
            $global:ErFx['/identity/conditionalAccess/namedLocations/loc1'] = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'loc1'; displayName = 'Schule'; isTrusted = $false
                ipRanges = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.iPv4CidrRange'; cidrAddress = '198.51.100.0/24' }) }
            $bk = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'loc1'; displayName = 'Schule'; isTrusted = $true; createdDateTime = 'x'
                ipRanges = @([pscustomobject]@{ cidrAddress = '198.51.100.0/24' }, [pscustomobject]@{ cidrAddress = '2001:db8::/48' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Benannter Ort' -Id 'loc1' -Backup $bk
            $p.Blocks.Count | Should -Be 0
            $p.Body['@odata.type'] | Should -Be '#microsoft.graph.ipNamedLocation'
            @($p.Body.ipRanges).Count | Should -Be 2
            $p.Body.ipRanges[1]['@odata.type'] | Should -Be '#microsoft.graph.iPv6CidrRange'
            $p.Confirms.Count | Should -Be 1
            $p.BreakGlass.Ok | Should -BeTrue
        }
        It 'Laender-Ort: isTrusted und countryLookupMethod werden nie gesendet' {
            $global:ErFx['/identity/conditionalAccess/namedLocations/c1'] = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'c1'; displayName = 'Erlaubt'; countriesAndRegions = @('AT'); includeUnknownCountriesAndRegions = $false; countryLookupMethod = 'clientIpAddress' }
            $bk = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'c1'; displayName = 'Erlaubt'; countriesAndRegions = @('AT', 'DE'); includeUnknownCountriesAndRegions = $false; countryLookupMethod = 'authenticatorAppGps'; isTrusted = $true }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Benannter Ort' -Id 'c1' -Backup $bk
            $p.Body.ContainsKey('isTrusted') | Should -BeFalse
            $p.Body.ContainsKey('countryLookupMethod') | Should -BeFalse
            @($p.Body.countriesAndRegions) | Should -Be @('AT', 'DE')
            @($p.Dropped) | Should -Contain 'countryLookupMethod'
        }
    }

    Context 'Verzeichniseinstellung' {
        BeforeEach {
            $global:ErList['/groupSettings'] = @([pscustomobject]@{ id = 'live1'; templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; displayName = 'Password Rule Settings'
                    values = @([pscustomobject]@{ name = 'LockoutThreshold'; value = '10' }, [pscustomobject]@{ name = 'LockoutDurationInSeconds'; value = '60' }, [pscustomobject]@{ name = 'EnableMSStandardBlockedWords'; value = 'true' }, [pscustomobject]@{ name = 'BannedPasswordList'; value = '' }) })
            $global:ErFx['/groupSettings/live1'] = $global:ErList['/groupSettings'][0]
        }
        It 'Kennwortregeln (Password Rule Settings): per App gesperrt (403 trotz Recht, Live-Test 24.10.)' {
            & (Get-Module HU.EntraRestore) { $script:HUErPwRuleBlocked = $true }
            $bk = [pscustomobject]@{ templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'LockoutThreshold'; value = '8' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Id 'x' -Name 'Password Rule Settings' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*per App nicht schreiben*' }).Count | Should -Be 1
        }

        It 'Zuordnung ueber templateId, ganze Liste ohne EnableMSStandardBlockedWords, P1 fehlt -> gesperrt' {
            & (Get-Module HU.EntraRestore) { $script:HUErPwRuleBlocked = $false }
            $global:ErList['/subscribedSkus'] = @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }) })
            $bk = [pscustomobject]@{ id = 'alt-id'; templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'LockoutThreshold'; value = '3' }, [pscustomobject]@{ name = 'EnableMSStandardBlockedWords'; value = 'false' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Id 'alt-id' -Backup $bk
            $p.Endpoint | Should -Be '/groupSettings/live1'
            @($p.Body.values.name) | Should -Not -Contain 'EnableMSStandardBlockedWords'
            @($p.Body.values).Count | Should -Be 3
            (@($p.Body.values) | Where-Object { $_.name -eq 'LockoutThreshold' }).value | Should -Be '3'
            @($p.Blocks | Where-Object { $_ -like '*P1*' }).Count | Should -Be 1
            @($p.Warnings).Count | Should -Be 1
        }
        It 'mit P1 kein Sperren, Nachpruefung ueber values[Name]' {
            & (Get-Module HU.EntraRestore) { $script:HUErPwRuleBlocked = $false }
            $global:ErList['/subscribedSkus'] = @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })
            $bk = [pscustomobject]@{ templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'LockoutThreshold'; value = '8' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Backup $bk
            $p.Blocks.Count | Should -Be 0
            $after = $global:ErFx['/groupSettings/live1'] | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            ($after.values | Where-Object { $_.name -eq 'LockoutThreshold' }).value = '8'
            $global:ErAfter = $after; $global:ErAfterKey = '/groupSettings/live1'
            (Invoke-HUEntraRestore -Plan $p -Settings $script:Set).Ok | Should -BeTrue
        }
        It 'fehlendes Objekt zur Vorlage wird nicht neu angelegt' {
            $bk = [pscustomobject]@{ templateId = '62375ab9-6b52-47ed-826b-58e47e0e304b'; values = @([pscustomobject]@{ name = 'EnableGroupCreation'; value = 'false' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*kein Einstellungsobjekt*' }).Count | Should -Be 1
        }
        It 'Gruppen anlegen aus braucht Bestaetigung, fehlende erlaubte Gruppe sperrt' {
            $global:ErList['/groupSettings'] = @([pscustomobject]@{ id = 'g1'; templateId = '62375ab9-6b52-47ed-826b-58e47e0e304b'; values = @([pscustomobject]@{ name = 'EnableGroupCreation'; value = 'true' }, [pscustomobject]@{ name = 'GroupCreationAllowedGroupId'; value = '' }) })
            $global:ErFx['/groupSettings/g1'] = $global:ErList['/groupSettings'][0]
            $bk = [pscustomobject]@{ templateId = '62375ab9-6b52-47ed-826b-58e47e0e304b'; values = @([pscustomobject]@{ name = 'EnableGroupCreation'; value = 'false' }, [pscustomobject]@{ name = 'GroupCreationAllowedGroupId'; value = '33333333-3333-3333-3333-333333333333' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Backup $bk
            $p.Confirms.Count | Should -Be 1
            @($p.Blocks | Where-Object { $_ -like '*33333333*' }).Count | Should -Be 1
        }
    }
    Context 'Nachbesserungen aus der Code-Pruefung 044' {
        It 'B1: lange Werte werden gekuerzt angezeigt, voll mitgefuehrt, Anzahl steht dabei' {
            $global:ErFx['/identity/conditionalAccess/namedLocations/loc1'] = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'loc1'; displayName = 'Schule'; isTrusted = $false; ipRanges = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.iPv4CidrRange'; cidrAddress = '198.51.100.0/24' }) }
            $many = @(1..40 | ForEach-Object { [pscustomobject]@{ cidrAddress = "203.0.113.$_/32" } })
            $bk = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.ipNamedLocation'; id = 'loc1'; displayName = 'Schule'; ipRanges = $many }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Benannter Ort' -Backup $bk
            $ch = @($p.Changes | Where-Object { $_.Feld -eq 'ipRanges' })[0]
            $ch.Gekuerzt | Should -BeTrue
            $ch.Danach | Should -BeLike '* ...'
            $ch.DanachVoll | Should -BeLike '*203.0.113.40/32*'
            $ch.Anzahl | Should -Be '1 -> 40'
            @($p.Body.ipRanges).Count | Should -Be 40
        }
        It 'B1: Kennwortliste mit Tabulatoren wird gezaehlt' {
            (Format-HUErValue ('a' * 400) -Full).Length | Should -Be 400
            # IP-Bereiche lesbar, auch ein einzelner (ausgepackter) Eintrag
            Format-HUErValue ([pscustomobject]@{ '@odata.type' = '#microsoft.graph.iPv4CidrRange'; cidrAddress = '192.0.2.0/24' }) | Should -Be '192.0.2.0/24'
            Format-HUErValue @([pscustomobject]@{ cidrAddress = '192.0.2.0/24' }, [pscustomobject]@{ cidrAddress = '198.51.100.0/24' }) | Should -Be '192.0.2.0/24, 198.51.100.0/24'
            (Format-HUErValue ('a' * 400)).Length | Should -Be 304
        }
        It 'B2: Rollen-Reviewer als Pfad wird erkannt und geprueft' {
            $global:ErFx['/policies/adminConsentRequestPolicy'] = [pscustomobject]@{ id = 'x'; isEnabled = $false; notifyReviewers = $false; remindersEnabled = $false; requestDurationInDays = 30; reviewers = @() }
            $global:ErFx['/roleManagement/directory/roleDefinitions/62e90394-69f5-4237-9190-012177145e10'] = [pscustomobject]@{ id = '62e90394-69f5-4237-9190-012177145e10' }
            $bk = [pscustomobject]@{ isEnabled = $true; reviewers = @([pscustomobject]@{ query = '/roleManagement/directory/roleDefinitions/62e90394-69f5-4237-9190-012177145e10'; queryType = 'MicrosoftGraph' }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Backup $bk
            $p.Blocks.Count | Should -Be 0
            $bk.reviewers[0].query = '/beta/roleManagement/directory/roleDefinitions/44444444-4444-4444-4444-444444444444'
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'adminConsentRequestPolicy' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*Reviewer-Rolle 44444444*' }).Count | Should -Be 1
        }
        It 'B3: Backup-Stand eines anderen Tenants bricht ab' {
            $set = [pscustomobject]@{ ui = $script:Set.ui; tenants = @([pscustomobject]@{ key = 'T'; tenantId = 'aaaaaaaa-0000-0000-0000-000000000001' }) }
            { Get-HUEntraRestorePlan -TenantKey 'T' -Settings $set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{}) -BackupIndex ([pscustomobject]@{ Tenant = 'X' }) } | Should -Throw '*denselben Tenant*'
            { Get-HUEntraRestorePlan -TenantKey 'T' -Settings $set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{}) -BackupIndex ([pscustomobject]@{ Tenant = 'T'; TenantId = 'bbbbbbbb-0000-0000-0000-000000000002' }) } | Should -Throw '*denselben Tenant*'
            $global:ErFx['/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; allowInvitesFrom = 'everyone' }
            { Get-HUEntraRestorePlan -TenantKey 'T' -Settings $set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup ([pscustomobject]@{}) -BackupIndex ([pscustomobject]@{ Tenant = 'T'; TenantId = 'aaaaaaaa-0000-0000-0000-000000000001' }) } | Should -Not -Throw
        }
        It 'B4: Sperrtexte sagen nicht mehr nur "wird nicht geschrieben"' {
            $src = Get-Content (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Core\HU.EntraRestore.psm1') -Raw
            $src | Should -Not -Match 'wird nicht geschrieben\.'
        }
        It 'B5: Kennwortliste landet nicht im Protokoll' {
            & (Get-Module HU.EntraRestore) { $script:HUErPwRuleBlocked = $false }
            $global:ErList['/subscribedSkus'] = @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })
            $global:ErList['/groupSettings'] = @([pscustomobject]@{ id = 'pw1'; templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'BannedPasswordList'; value = '' }) })
            $global:ErFx['/groupSettings/pw1'] = $global:ErList['/groupSettings'][0]
            $bk = [pscustomobject]@{ templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'BannedPasswordList'; value = "geheimwort1`tgeheimwort2" }) }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Verzeichniseinstellung' -Backup $bk
            $p.Changes[0].Anzahl | Should -Be '0 -> 2'
            $global:ErLog = @()
            Mock -ModuleName HU.EntraRestore Write-HULog { $global:ErLog += $Message }
            [void](Invoke-HUEntraRestore -Plan $p -Settings $script:Set)
            ($global:ErLog -join ' ') | Should -Not -BeLike '*geheimwort*'
            ($global:ErLog -join ' ') | Should -BeLike '*nicht protokolliert*'
        }
        It 'allowedToReadOtherUsers als Text "false" sperrt trotzdem' {
            $global:ErFx['/policies/authorizationPolicy'] = [pscustomobject]@{ id = 'authorizationPolicy'; defaultUserRolePermissions = [pscustomobject]@{ allowedToReadOtherUsers = $true } }
            $bk = [pscustomobject]@{ defaultUserRolePermissions = [pscustomobject]@{ allowedToReadOtherUsers = 'false' } }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Entra-Einstellung' -Id 'authorizationPolicy' -Backup $bk
            @($p.Blocks | Where-Object { $_ -like '*allowedToReadOtherUsers*' }).Count | Should -Be 1
        }
    }
    Context 'Conditional Access neu als Nur Bericht (2.3.4)' {
        BeforeEach {
            $global:ErFx['/groups/22222222-0000-0000-0000-000000000001'] = [pscustomobject]@{ id = 'g' }
            $global:ErFx['/identity/conditionalAccess/namedLocations/33333333-0000-0000-0000-000000000001'] = [pscustomobject]@{ id = 'l' }
            $global:ErFx['/policies/authenticationStrengthPolicies/00000000-0000-0000-0000-000000000004'] = [pscustomobject]@{ id = 'a' }
            $script:Ca = {
                [pscustomobject]@{ id = 'p1'; displayName = '201 - MFA'; state = 'enabled'; createdDateTime = '2026-01-01T00:00:00Z'; templateId = $null
                    conditions = [pscustomobject]@{ clientAppTypes = @('all')
                        users = [pscustomobject]@{ includeUsers = @('All'); excludeUsers = @('11111111-1111-1111-1111-111111111111'); includeGroups = @(); excludeGroups = @('22222222-0000-0000-0000-000000000001'); includeRoles = @() }
                        applications = [pscustomobject]@{ includeApplications = @('All'); excludeApplications = @(); includeUserActions = @() }
                        locations = [pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('33333333-0000-0000-0000-000000000001') } }
                    grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @(); 'authenticationStrength@odata.context' = 'x'
                        authenticationStrength = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; policyType = 'builtIn'; allowedCombinations = @('fido2') } }
                    sessionControls = $null }
            }
        }
        It 'POST als Nur Bericht, nur die beschreibbaren Teile, Staerke nur mit Kennung' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Id 'p1' -Name '201 - MFA' -Backup (& $script:Ca) -NewName '201 - MFA (wiederhergestellt 2026-10-01)'
            $p.Blocks.Count | Should -Be 0
            $p.Method | Should -Be 'POST'
            $p.Body.state | Should -Be 'enabledForReportingButNotEnforced'
            $p.Body.displayName | Should -Be '201 - MFA (wiederhergestellt 2026-10-01)'
            @($p.Body.Keys | Sort-Object) | Should -Be @('conditions', 'displayName', 'grantControls', 'state')
            $p.Body.grantControls.authenticationStrength.Keys | Should -Be @('id')
            $p.Body.grantControls.ContainsKey('authenticationStrength@odata.context') | Should -BeFalse
            $p.Body.ContainsKey('id') | Should -BeFalse
            @($p.Warnings).Count | Should -Be 0
        }
        It 'fehlende Gruppe oder fehlender Ort sperrt' {
            $global:ErFx.Remove('/groups/22222222-0000-0000-0000-000000000001')
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup (& $script:Ca)
            @($p.Blocks | Where-Object { $_ -like 'Gruppe 22222222*' }).Count | Should -Be 1
            { Invoke-HUEntraRestore -Plan $p -Settings $script:Set } | Should -Throw '*Nicht zurueckgeschrieben*'
            $global:ErWrites.Count | Should -Be 0
        }
        It 'Authentifizierungskontext und Dienstprinzipal werden geprueft, eigene Steuerelemente sperren' {
            $ca = & $script:Ca
            $ca.conditions.applications | Add-Member -NotePropertyName includeAuthenticationContextClassReferences -NotePropertyValue @('c1')
            $ca.conditions | Add-Member -NotePropertyName clientApplications -NotePropertyValue ([pscustomobject]@{ includeServicePrincipals = @('44444444-0000-0000-0000-000000000001') })
            $ca.grantControls | Add-Member -NotePropertyName customAuthenticationFactors -NotePropertyValue @('x1')
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            @($p.Blocks | Where-Object { $_ -like 'Authentifizierungskontext c1*' }).Count | Should -Be 1
            @($p.Blocks | Where-Object { $_ -like 'Dienstprinzipal 44444444*' }).Count | Should -Be 1
            @($p.Blocks | Where-Object { $_ -like 'Eigenes Steuerelement x1*' }).Count | Should -Be 1
        }
        It 'Notfallkonto nicht ausgenommen -> Warnung; konformes Geraet -> Bestaetigung; Benutzeraktion -> aus' {
            $ca = & $script:Ca
            $ca.conditions.users.excludeUsers = @()
            $ca.grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('compliantDevice') }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            @($p.Confirms | Where-Object { $_ -like '*Notfallkonto*' }).Count | Should -Be 1
            @($p.Confirms | Where-Object { $_ -like '*Geraetezertifikat*' }).Count | Should -Be 1
            $ca.conditions.applications.includeUserActions = @('urn:user:registersecurityinfo')
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            $p.Body.state | Should -Be 'disabled'
        }
        It '046 B1: ohne includeUserActions (Eigenschaft fehlt oder null) bleibt es Nur Bericht' {
            $ca = & $script:Ca
            $ca.conditions.applications.PSObject.Properties.Remove('includeUserActions')
            (Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca).Body.state | Should -Be 'enabledForReportingButNotEnforced'
            $ca.conditions.applications | Add-Member -NotePropertyName includeUserActions -NotePropertyValue $null -Force
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            $p.Body.state | Should -Be 'enabledForReportingButNotEnforced'
            @($p.Warnings | Where-Object { $_ -like '*Benutzeraktionen*' }).Count | Should -Be 0
        }
        It '046 B3/B5: Notfallkonto + konformes Geraet = Pflicht-Haken; verbundenes Geraet allein keine Zertifikat-Bestaetigung; Gruppen-Zusatz nur mit Gruppen' {
            $ca = & $script:Ca
            $ca.conditions.users.excludeUsers = @(); $ca.conditions.users.excludeGroups = $null
            $ca.grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('compliantDevice') }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            @($p.Confirms | Where-Object { $_ -like '*Notfallkonto*schon jetzt*' }).Count | Should -Be 1
            @($p.Confirms | Where-Object { $_ -like '*Gruppen hier nicht*' }).Count | Should -Be 0
            $ca.grantControls = [pscustomobject]@{ operator = 'OR'; builtInControls = @('domainJoinedDevice') }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            @($p.Confirms).Count | Should -Be 0
            @($p.Warnings | Where-Object { $_ -like '*Notfallkonto*' }).Count | Should -Be 1
        }
        It '046 B5: Authentifizierungskontext und Nutzungsbedingungen mit falschem Format sperren ohne Abfrage' {
            $ca = & $script:Ca
            $ca.conditions.applications | Add-Member -NotePropertyName includeAuthenticationContextClassReferences -NotePropertyValue @('c99', '../x') -Force
            $ca.grantControls | Add-Member -NotePropertyName termsOfUse -NotePropertyValue @('nicht-guid') -Force
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup $ca
            @($p.Blocks | Where-Object { $_ -like '*kein gueltiges Format*' }).Count | Should -Be 3
        }
        It 'legt an und prueft Zustand und Name nach, ohne Sicherung' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup (& $script:Ca) -NewName 'Neu'
            Mock -ModuleName HU.EntraRestore Invoke-HUIntuneGraph {
                param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
                if ($Method -eq 'POST') { $global:ErWrites += [pscustomobject]@{ Method = $Method; Endpoint = $Endpoint; Body = $Body }; return [pscustomobject]@{ id = 'neu1' } }
                if ($Endpoint -like '*/policies/neu1') { $o = $global:ErCaBody | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $o | Add-Member -NotePropertyName id -NotePropertyValue 'neu1' -Force; return $o }
                throw (New-ErFail 404)
            }
            $global:ErCaBody = $p.Body
            $r = Invoke-HUEntraRestore -Plan $p -Settings $script:Set
            $r.Ok | Should -BeTrue
            $r.NewId | Should -Be 'neu1'
            $r.BackupFile | Should -Be ''
            $global:ErWrites.Count | Should -Be 1
            $global:ErWrites[0].Endpoint | Should -Be '/identity/conditionalAccess/policies'
            # 046 B2: andere Steuerelemente nach dem Anlegen fallen auf
            $bad = $p.Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $bad.grantControls.builtInControls = @('block'); $global:ErCaBody = $bad
            (Invoke-HUEntraRestore -Plan $p -Settings $script:Set).Mismatch -join ' ' | Should -BeLike '*builtInControls*'
        }
        It 'gleicher Name schon im Tenant: Nummer anhaengen' {
            Mock -ModuleName HU.EntraRestore Get-HUIntuneGraphAll { param($TenantKey, $Settings, $Endpoint, [switch]$V1)
                if ($Endpoint -like '/identity/conditionalAccess/policies*') { return @([pscustomobject]@{ displayName = 'Neu (wiederhergestellt 2026-10-23)' }, [pscustomobject]@{ displayName = 'neu (wiederhergestellt 2026-10-23 2)' }) }
                return @() }
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup (& $script:Ca) -NewName 'Neu (wiederhergestellt 2026-10-23)'
            $p.Body.displayName | Should -Be 'Neu (wiederhergestellt 2026-10-23 3)'
            @($p.Notes | Where-Object { $_ -like '*gibt es schon*' }).Count | Should -Be 1
        }
        It 'neue Richtlinie erst nach Sekunden lesbar (404): wartet und prueft dann nach; bleibt 404, kein Fehler, sondern Hinweis mit Id' {
            $p = Get-HUEntraRestorePlan -TenantKey 'T' -Settings $script:Set -Typ 'Conditional Access' -Backup (& $script:Ca) -NewName 'Neu'
            InModuleScope HU.EntraRestore { $script:HUErReadDelays = @(0, 0, 0) }
            $global:ErCaBody = $p.Body; $global:ErGets = 0; $global:ErReadyAfter = 2
            Mock -ModuleName HU.EntraRestore Invoke-HUIntuneGraph {
                param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
                if ($Method -eq 'POST') { return [pscustomobject]@{ id = 'neu2' } }
                if ($Endpoint -like '*/policies/neu2') {
                    $global:ErGets++
                    if ($global:ErGets -le $global:ErReadyAfter) { throw (New-ErFail 404) }
                    $o = $global:ErCaBody | ConvertTo-Json -Depth 20 | ConvertFrom-Json; $o | Add-Member -NotePropertyName id -NotePropertyValue 'neu2' -Force; return $o
                }
                throw (New-ErFail 404)
            }
            $r = Invoke-HUEntraRestore -Plan $p -Settings $script:Set
            $r.Ok | Should -BeTrue
            $global:ErGets | Should -Be 3
            $global:ErGets = 0; $global:ErReadyAfter = 99
            $r = Invoke-HUEntraRestore -Plan $p -Settings $script:Set
            $r.Ok | Should -BeFalse
            $r.NewId | Should -Be 'neu2'
            ($r.Mismatch -join ' ') | Should -BeLike '*Angelegt (Id neu2)*nicht nachlesbar*'
            InModuleScope HU.EntraRestore { $script:HUErReadDelays = @(2, 3, 5, 5, 5, 10) }
        }
    }
}
