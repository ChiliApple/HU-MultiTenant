#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.SecCatalog.psm1 - ohne Netzwerk, ohne Oberflaeche.
.NOTES
    Aufruf: Invoke-Pester .github\tests   (oder ueber Invoke-CITests.ps1)
    Der einzige Netzwerkzugriff (Invoke-HUSecFetch) wird ersetzt; die Daten stehen in $global:HUSecFx.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-Sec-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TestAppData -ItemType Directory -Force | Out-Null
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = $script:TestAppData
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking

    Mock -ModuleName HU.SecCatalog Get-HUSecTokenRoles { return @() }
    Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
        param($TenantKey, $Settings, $Endpoint, [switch]$All)
        $hit = $null
        foreach ($k in $global:HUSecFx.Keys) { if ($Endpoint -like "*$k*") { $hit = $global:HUSecFx[$k]; break } }
        if ($null -eq $hit) { throw 'nicht vorbereitet' }
        if ($hit -is [scriptblock]) { return (& $hit) }
        return $hit
    }

    function script:Fail([int]$Code) {
        $ex = New-Object System.Exception('Graph-Fehler'); $ex.Data['StatusCode'] = $Code
        return { throw $ex }.GetNewClosure()
    }
    function script:Skus([string[]]$Plans) {
        , @([pscustomobject]@{ servicePlans = @($Plans | ForEach-Object { [pscustomobject]@{ servicePlanName = $_; provisioningStatus = 'Success' } }) })
    }
    function script:Pol($state, $apps = @('All'), $users = @('All'), $grant = @('mfa'), $client = @('all'), $flows = $null) {
        [pscustomobject]@{ state = $state
            conditions = [pscustomobject]@{ users = [pscustomobject]@{ includeUsers = $users }; applications = [pscustomobject]@{ includeApplications = $apps }; clientAppTypes = $client; authenticationFlows = $flows }
            grantControls = [pscustomobject]@{ builtInControls = $grant; authenticationStrength = $null } }
    }
    function script:Run($id) { @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleIds @($id) | Where-Object { $_.RuleId -eq $id })[0] }
    function script:Base { $global:HUSecFx = @{ 'subscribedSkus' = (Skus @('AAD_PREMIUM')); 'authorizationPolicy' = [pscustomobject]@{ guestUserRoleId = '2af84b1e-32c8-42b7-82bc-daa82404023b'; allowInvitesFrom = 'adminsAndGuestInviters'; defaultUserRolePermissions = [pscustomobject]@{ permissionGrantPoliciesAssigned = @() } }; 'securityDefaults' = [pscustomobject]@{ isEnabled = $false }; 'eq%20false' = @(); 'conditionalAccess' = @((Pol 'enabled')) } }
}

AfterAll {
    $env:APPDATA = $script:OldAppData
    Remove-Variable HUSecFx -Scope Global -ErrorAction SilentlyContinue
    Remove-Module HU.SecCatalog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TestAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Sammler: Fehler sind nie OK' {
    BeforeEach { Base }
    It '403 ergibt Nicht pruefbar (Recht)' {
        $global:HUSecFx['conditionalAccess'] = Fail 403
        $r = Run 'A01'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Recht'; $r.Complete | Should -BeFalse
    }
    It '500 ergibt Nicht pruefbar (Technisch)' {
        $global:HUSecFx['conditionalAccess'] = Fail 500
        $r = Run 'A01'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Technisch'
    }
    It 'Lizenz fehlt (kein P1): CA-Regeln Nicht pruefbar (Lizenz), Policy-Regeln laufen weiter' {
        $global:HUSecFx['subscribedSkus'] = Skus @('EXCHANGE_S_STANDARD')
        $a = Run 'A01'; $a.Status | Should -Be 'NichtPruefbar'; $a.Reason | Should -Be 'Lizenz'
        (Run 'A14').Status | Should -Be 'OK'
    }
    It 'Lizenzliste nicht lesbar: Abruf entscheidet' {
        $global:HUSecFx['subscribedSkus'] = Fail 403
        (Run 'A01').Status | Should -Be 'OK'
    }
    It 'leere Liste ist bei A01 eine Abweichung, kein OK' {
        $global:HUSecFx['conditionalAccess'] = @()
        (Run 'A01').Status | Should -Be 'Abweichung'
    }
}

Describe 'Regeln' {
    BeforeEach { Base }
    It 'A01: nur Berichtsmodus ist Abweichung' {
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabledForReportingButNotEnforced'))
        (Run 'A01').Status | Should -Be 'Abweichung'
    }
    It 'A04: Legacy-Block aktiv = OK, nur Berichtsmodus = Abweichung' {
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled' -grant @('block') -client @('exchangeActiveSync', 'other')))
        (Run 'A04').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabledForReportingButNotEnforced' -grant @('block') -client @('exchangeActiveSync', 'other')))
        (Run 'A04').Status | Should -Be 'Abweichung'
    }
    It 'A14: eingeschraenkt OK, Standard-Gastrolle Abweichung' {
        (Run 'A14').Status | Should -Be 'OK'
        $global:HUSecFx['authorizationPolicy'].guestUserRoleId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'
        (Run 'A14').Status | Should -Be 'Abweichung'
    }
    It 'A15: everyone ist Abweichung' {
        $global:HUSecFx['authorizationPolicy'].allowInvitesFrom = 'everyone'
        (Run 'A15').Status | Should -Be 'Abweichung'
    }
    It 'A17: Benutzer-Consent aktiv ist Abweichung (Kritisch)' {
        $global:HUSecFx['authorizationPolicy'].defaultUserRolePermissions.permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-low')
        $r = Run 'A17'; $r.Status | Should -Be 'Abweichung'; $r.Sev | Should -Be 'Kritisch'
    }
    It 'A17: fehlendes Feld ist Nicht pruefbar, nicht OK' {
        $global:HUSecFx['authorizationPolicy'] = [pscustomobject]@{ guestUserRoleId = 'x' }
        (Run 'A17').Status | Should -Be 'NichtPruefbar'
    }
    It 'Einzelobjekt als Liste mit einem Eintrag (value) wird erkannt' {
        $o = $global:HUSecFx['authorizationPolicy']
        $global:HUSecFx['authorizationPolicy'] = [pscustomobject]@{ value = @($o) }
        (Run 'A14').Status | Should -Be 'OK'
    }
    It 'V5: Security Defaults aus und keine MFA-Richtlinie = Abweichung; mit MFA fuer alle = OK' {
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled' -grant @('block')))
        (Run 'V5').Status | Should -Be 'Abweichung'
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled'))
        (Run 'V5').Status | Should -Be 'OK'
    }
    It 'V11: Geraetecode-Flow blockiert = OK' {
        (Run 'V11').Status | Should -Be 'Abweichung'
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled' -grant @('block') -flows ([pscustomobject]@{ transferMethods = 'deviceCodeFlow' })))
        (Run 'V11').Status | Should -Be 'OK'
    }
    It 'A08: 2 Benutzer OK, 1 Abweichung, Gruppe = Nicht pruefbar' {
        $u = { [pscustomobject]@{ principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user' } } }
        $global:HUSecFx['roleAssignments'] = @((& $u), (& $u))
        (Run 'A08').Status | Should -Be 'OK'
        $global:HUSecFx['roleAssignments'] = @((& $u))
        (Run 'A08').Status | Should -Be 'Abweichung'
        $global:HUSecFx['roleAssignments'] = @((& $u), [pscustomobject]@{ principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group' } })
        (Run 'A08').Status | Should -Be 'NichtPruefbar'
    }
}

Describe 'Ausnahmen' {
    BeforeEach { Base; $global:HUSecFx['authorizationPolicy'].allowInvitesFrom = 'everyone'; Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'exceptions.json') -Force -ErrorAction SilentlyContinue }
    It 'Pflichtfelder: Begruendung mindestens 20 Zeichen' {
        { Add-HUSecException -RuleId 'A15' -TenantKey 'T1' -Reason 'kurz' -ValidUntil (Get-Date).AddDays(30) -Responsible 'Systembetreuung' } | Should -Throw
    }
    It 'Obergrenze: 12 Monate, bei Kritisch 3 Monate' {
        Test-HUSecExceptionInput -Reason ('x' * 25) -ValidUntil (Get-Date).AddMonths(13) -Sev 'Hoch' | Should -Match '12 Monate'
        Test-HUSecExceptionInput -Reason ('x' * 25) -ValidUntil (Get-Date).AddMonths(4) -Sev 'Kritisch' | Should -Match '3 Monate'
        Test-HUSecExceptionInput -Reason ('x' * 25) -ValidUntil (Get-Date).AddMonths(2) -Sev 'Kritisch' | Should -Be ''
    }
    It 'gueltige Ausnahme macht aus Abweichung eine Ausnahme (wird gezaehlt, nie OK)' {
        $null = Add-HUSecException -RuleId 'A15' -TenantKey 'T1' -Reason 'Befristeter Gastzugang fuer Projekt' -ValidUntil (Get-Date).AddMonths(2) -Responsible 'Systembetreuung' -Sev 'Hoch'
        $r = Run 'A15'; $r.Status | Should -Be 'Ausnahme'; $r.ExceptionId | Should -Not -BeNullOrEmpty
    }
    It 'abgelaufene Ausnahme gilt nicht mehr' {
        $null = Add-HUSecException -RuleId 'A15' -TenantKey 'T1' -Reason 'Befristeter Gastzugang fuer Projekt' -ValidUntil (Get-Date).AddMonths(2) -Responsible 'Systembetreuung' -Sev 'Hoch'
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleIds @('A15') -Now (Get-Date).AddMonths(3))[0]
        $r.Status | Should -Be 'Abweichung'
    }
}

Describe 'Sollwerte und Verlauf' {
    BeforeEach { Base }
    It 'Ueberschreibung je Tenant: A08 erlaubt 1 Global Admin' {
        $u = [pscustomobject]@{ principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user' } }
        $global:HUSecFx['roleAssignments'] = @($u)
        Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Value '{ "tenants": { "T1": { "A08": { "min": 1, "max": 4 } } } }' -Encoding UTF8
        (Run 'A08').Status | Should -Be 'OK'
        Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force
    }
    It 'unbekannte Regel in den Sollwerten ergibt einen Fehler, kein stilles Ignorieren' {
        Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Value '{ "global": { "Z99": { "x": 1 } } }' -Encoding UTF8
        $all = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleIds @('A14'))
        @($all | Where-Object { $_.Status -eq 'Fehler' }).Count | Should -BeGreaterThan 0
        Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force
    }
    It 'Snapshot enthaelt nur Status und Zahlen' {
        $res = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleIds @('A14', 'A15'))
        $f = Save-HUSecSnapshot -Results $res
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $names = @($j.rows[0].PSObject.Properties.Name | Sort-Object)
        ($names -join ',') | Should -Be 'count,exceptionId,reason,ruleId,status,tenant'
        (Get-Content -LiteralPath $f -Raw) | Should -Not -Match '@|[0-9a-f]{8}-[0-9a-f]{4}-'
    }
}

Describe 'Matrix' {
    BeforeEach { Base }
    It 'zeigt je Regel eine Zeile mit Zellen je Tenant; Unterschiede zwischen Tenants werden erkannt' {
        $a = @(Invoke-HUSecCatalog -TenantKey 'A' -Settings ([pscustomobject]@{}) -RuleIds @('A14', 'A15'))
        $global:HUSecFx['authorizationPolicy'].allowInvitesFrom = 'everyone'
        $b = @(Invoke-HUSecCatalog -TenantKey 'B' -Settings ([pscustomobject]@{}) -RuleIds @('A14', 'A15'))
        $m = @(Get-HUSecMatrix -Results @($a + $b) -Keys @('A', 'B'))
        $row = $m | Where-Object RuleId -eq 'A15'
        $row.Diff | Should -BeTrue
        $row.Dev | Should -BeTrue
        $row.Cells['A'].Status | Should -Be 'OK'
        $row.Cells['B'].Status | Should -Be 'Abweichung'
        ($m | Where-Object RuleId -eq 'A14').Diff | Should -BeFalse
    }
    It 'Regeln ohne Ergebnis haben leere Zellen, keine Abweichung' {
        $m = @(Get-HUSecMatrix -Results @() -Keys @('A'))
        @($m | Where-Object Dev).Count | Should -Be 0
        $m[0].Cells['A'] | Should -BeNullOrEmpty
    }
    It 'sortiert nach Schweregrad: Kritisch zuerst' {
        $m = @(Get-HUSecMatrix -Results @() -Keys @('A'))
        $m[0].Sev | Should -Be 'Kritisch'
    }
    It 'Abdeckung: nur OK, Abweichung und Ausnahme gelten als geprueft' {
        $global:HUSecFx['conditionalAccess'] = Fail 403
        $r = @(Invoke-HUSecCatalog -TenantKey 'A' -Settings ([pscustomobject]@{}))
        $c = Get-HUSecCoverage -Results $r -Key 'A'
        $c.Total | Should -Be @(Get-HUSecRules).Count
        $c.Checked | Should -BeLessThan $c.Total
        $c.Checked | Should -BeGreaterThan 0
    }
}

Describe 'Kurzerklaerung' {
    It 'jede Regel hat einen Erklaerungstext' {
        foreach ($r in (Get-HUSecRules)) { (Get-HUSecWhy $r.Id) | Should -Not -BeNullOrEmpty -Because $r.Id }
    }
}

Describe 'C02 und A17-Detail' {
    BeforeEach { Base }
    It 'C02: zaehlt Gastkonten und ist nur Info' {
        $global:HUSecFx['userType'] = @([pscustomobject]@{ id = '1' }, [pscustomobject]@{ id = '2' })
        $r = Run 'C02'; $r.Status | Should -Be 'Info'; $r.Count | Should -Be 2
    }
    It 'C02: Fehler beim Lesen ist Nicht pruefbar' {
        $global:HUSecFx['userType'] = Fail 403
        (Run 'C02').Status | Should -Be 'NichtPruefbar'
    }
    It 'A17: Detail nennt die Richtlinie' {
        $global:HUSecFx['authorizationPolicy'].defaultUserRolePermissions.permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-low')
        (Run 'A17').Detail | Should -BeLike '*verifizierte Herausgeber*'
    }
}

Describe 'A19, E01, E03, E04' {
    BeforeEach { Base }
    It 'A19: nur Apps ohne neuere Zugangsdaten zaehlen' {
        $old = (Get-Date).AddDays(-10).ToString('o'); $soon = (Get-Date).AddDays(10).ToString('o'); $far = (Get-Date).AddDays(200).ToString('o')
        $global:HUSecFx['applications'] = @(
            [pscustomobject]@{ displayName = 'rotiert'; passwordCredentials = @([pscustomobject]@{ endDateTime = $old }, [pscustomobject]@{ endDateTime = $far }); keyCredentials = @() },
            [pscustomobject]@{ displayName = 'bald'; passwordCredentials = @([pscustomobject]@{ endDateTime = $soon }); keyCredentials = @() },
            [pscustomobject]@{ displayName = 'tot'; passwordCredentials = @([pscustomobject]@{ endDateTime = $old }); keyCredentials = @() },
            [pscustomobject]@{ displayName = 'ohne'; passwordCredentials = @(); keyCredentials = @() })
        $r = Run 'A19'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 2
    }
    It 'A19: alles in Ordnung ist OK' {
        $global:HUSecFx['applications'] = @([pscustomobject]@{ displayName = 'x'; passwordCredentials = @([pscustomobject]@{ endDateTime = (Get-Date).AddDays(300).ToString('o') }); keyCredentials = @() })
        (Run 'A19').Status | Should -Be 'OK'
    }
    It 'E01: keine Richtlinie oder ohne Zuweisung ist Abweichung, sonst OK' {
        $global:HUSecFx['deviceCompliancePolicies'] = @()
        (Run 'E01').Status | Should -Be 'Abweichung'
        $global:HUSecFx['deviceCompliancePolicies'] = @([pscustomobject]@{ assignments = @() })
        (Run 'E01').Status | Should -Be 'Abweichung'
        $global:HUSecFx['deviceCompliancePolicies'] = @([pscustomobject]@{ assignments = @([pscustomobject]@{ id = 1 }) })
        (Run 'E01').Status | Should -Be 'OK'
    }
    It 'E03: Grenze in Prozent' {
        $d = @(1..100 | ForEach-Object { [pscustomobject]@{ complianceState = $(if ($_ -le 4) { 'noncompliant' } else { 'compliant' }); isEncrypted = $true; operatingSystem = 'Windows' } })
        $global:HUSecFx['managedDevices'] = $d
        (Run 'E03').Status | Should -Be 'OK'
        $d[10].complianceState = 'noncompliant'; $d[11].complianceState = 'noncompliant'
        (Run 'E03').Status | Should -Be 'Abweichung'
    }
    It 'E04: unverschluesselte Windows-Geraete, andere Systeme zaehlen nicht' {
        $d = @(1..20 | ForEach-Object { [pscustomobject]@{ complianceState = 'compliant'; isEncrypted = $true; operatingSystem = 'Windows' } })
        $d += [pscustomobject]@{ complianceState = 'compliant'; isEncrypted = $false; operatingSystem = 'Android' }
        $global:HUSecFx['managedDevices'] = $d
        (Run 'E04').Status | Should -Be 'OK'
        $d[0].isEncrypted = $false; $d[1].isEncrypted = $false
        (Run 'E04').Status | Should -Be 'Abweichung'
    }
    It 'E03: keine Geraete ist nur Info' {
        $global:HUSecFx['managedDevices'] = @()
        (Run 'E03').Status | Should -Be 'Info'
    }
}

Describe 'A02 und A03' {
    BeforeEach { Base }
    It 'A02: MFA fuer alle deckt Admins ab' {
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled'))
        (Run 'A02').Status | Should -Be 'OK'
    }
    It 'A02: nur einzelne Rollen abgedeckt ist Abweichung mit Namen' {
        $p = Pol 'enabled' @('All') @(); $p.conditions.users | Add-Member includeRoles @('62e90394-69f5-4237-9190-012177145e10') -Force
        $global:HUSecFx['conditionalAccess'] = @($p)
        $r = Run 'A02'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -BeLike '*Security Administrator*'; $r.Detail | Should -Not -BeLike '*Global Administrator*'
    }
    It 'A02: Berichtsmodus zaehlt nicht' {
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabledForReportingButNotEnforced'))
        (Run 'A02').Status | Should -Be 'Abweichung'
    }
    It 'A02: Security Defaults ist OK' {
        $global:HUSecFx['conditionalAccess'] = @()
        $global:HUSecFx['securityDefaults'].isEnabled = $true
        (Run 'A02').Status | Should -Be 'OK'
    }
    It 'A03: Gaeste ueber Gast-Bedingung oder fuer alle' {
        $p = Pol 'enabled' @('All') @(); $p.conditions.users | Add-Member includeGuestsOrExternalUsers ([pscustomobject]@{ guestOrExternalUserTypes = 'b2bCollaborationGuest,internalGuest' }) -Force
        $global:HUSecFx['conditionalAccess'] = @($p)
        (Run 'A03').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((Pol 'enabled' @('All') @()))
        (Run 'A03').Status | Should -Be 'Abweichung'
    }
}

Describe 'A02 Ausnahmen in Richtlinien' {
    BeforeEach { Base }
    It 'nennt ausgeschlossene Gruppen im Detail' {
        $p = Pol 'enabled' @('All') @(); $p.conditions.users | Add-Member includeRoles @('62e90394-69f5-4237-9190-012177145e10') -Force
        $p.conditions.users | Add-Member excludeGroups @('g1') -Force
        $global:HUSecFx['conditionalAccess'] = @($p)
        (Run 'A02').Detail | Should -BeLike '*1 Gruppe(n)*'
    }
}

Describe 'A09 und V15' {
    BeforeEach { Base }
    It 'A09: bis zur erlaubten Zahl ohne MFA ist OK, darueber Abweichung' {
        $global:HUSecFx['userRegistrationDetails'] = @(1..5 | ForEach-Object { [pscustomobject]@{ isAdmin = $true; isMfaRegistered = ($_ -gt 2) } })
        (Run 'A09').Status | Should -Be 'OK'
        $global:HUSecFx['userRegistrationDetails'] = @(1..5 | ForEach-Object { [pscustomobject]@{ isAdmin = $true; isMfaRegistered = ($_ -gt 3) } })
        $r = Run 'A09'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 3
    }
    It 'A09: Lizenz fehlt ist Nicht pruefbar (Lizenz)' {
        $global:HUSecFx['subscribedSkus'] = (Skus @('SOMETHING_ELSE'))
        $r = Run 'A09'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Lizenz'
    }
    It 'V15: verborgene Namen OK, sichtbare Abweichung, Feld fehlt nicht OK' {
        $global:HUSecFx['reportSettings'] = [pscustomobject]@{ displayConcealedNames = $true }
        (Run 'V15').Status | Should -Be 'OK'
        $global:HUSecFx['reportSettings'] = [pscustomobject]@{ displayConcealedNames = $false }
        (Run 'V15').Status | Should -Be 'Abweichung'
        $global:HUSecFx['reportSettings'] = [pscustomobject]@{ }
        (Run 'V15').Status | Should -Be 'NichtPruefbar'
    }
}

Describe 'Konten anzeigen (A09)' {
    BeforeEach { Base }
    It 'liefert nur Konten ohne MFA, mit letzter Anmeldung, ohne interne Id' {
        $global:HUSecFx['userRegistrationDetails'] = @(
            [pscustomobject]@{ id = 'u1'; userPrincipalName = 'b@x.at'; userDisplayName = 'B'; isAdmin = $true; isMfaRegistered = $false; methodsRegistered = @() },
            [pscustomobject]@{ id = 'u2'; userPrincipalName = 'a@x.at'; userDisplayName = 'A'; isAdmin = $true; isMfaRegistered = $true; methodsRegistered = @('x') },
            [pscustomobject]@{ id = 'u3'; userPrincipalName = 'a0@x.at'; userDisplayName = 'A0'; isAdmin = $true; isMfaRegistered = $false; methodsRegistered = @('sms') })
        $global:HUSecFx['signInActivity'] = [pscustomobject]@{ signInActivity = [pscustomobject]@{ lastSignInDateTime = '2026-05-01T10:00:00Z' } }
        $r = @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'A09')
        $r.Count | Should -Be 2
        $r[0].Anmeldename | Should -Be 'a0@x.at'
        $r[0].LetzteAnmeldung | Should -Be '2026-05-01'
        $r[0].PSObject.Properties['__Id'] | Should -BeNullOrEmpty
    }
    It 'Regel ohne Liste liefert nichts' {
        @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'A14').Count | Should -Be 0
    }
    It 'Lesefehler wird zum Fehler, nicht zu einer leeren Liste' {
        $global:HUSecFx['userRegistrationDetails'] = Fail 403
        { Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'A09' } | Should -Throw
    }
}

Describe 'Katalog-Detaillisten: kein Export (B1)' {
    BeforeAll {
        $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:Sec = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions\UI-Security.ps1') -Raw
        $script:Qs = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'Functions\UI-QSTable.ps1') -Raw
    }
    It 'jeder Show-HUQSTable-Aufruf im Katalog nutzt -NoExport' {
        $calls = [regex]::Matches($script:Sec, 'Show-HUQSTable[^\r\n]*Katalog-Liste[^\r\n]*')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) { $c.Value | Should -Match '-NoExport' }
    }
    It 'Show-HUQSTable kennt NoExport und sperrt Kopieren und Kontextmenue' {
        $script:Qs | Should -Match '\[switch\]\$NoExport'
        $script:Qs | Should -Match 'ClipboardCopyMode'
        $script:Qs | Should -Match 'ContextMenu = \$null'
    }
}
