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
        param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
        $global:HUSecBeta = [bool]$Beta
        $global:HUSecEp = "$Endpoint"
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

    It 'Konten anzeigen zeigt Ladeanzeige (Knopf, Sanduhr, Punkt) und beendet sie in jedem Fall' {
        $script:Sec | Should -Match 'function Set-HUSecBusy'
        $script:Sec | Should -Match '-Window \$w -Button \$ctl\.btnList'
        $script:Sec | Should -Match "Content = 'Lade \.\.\.'"
        ([regex]::Matches($script:Sec, 'Set-HUSecBusy \$false')).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'A21 ist manuell (kein Schreibrecht angefordert)' {
    BeforeEach { Base; $global:HUSecFx['authorizationPolicy'] = [pscustomobject]@{ blockMsolPowerShell = $true; guestUserRoleId = '2af84b1e-32c8-42b7-82bc-daa82404023b' } }
    It 'ohne das Recht: Nicht pruefbar (Manuell) mit Klartext' {
        Mock -ModuleName HU.SecCatalog Get-HUSecTokenRoles { return @('Policy.Read.All') }
        $r = Run 'A21'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Manuell'; $r.Detail | Should -BeLike '*Entra Admin Center*'
    }
    It 'die uebrigen Regeln auf der Berechtigungsrichtlinie brauchen weiter nur Policy.Read.All' {
        Mock -ModuleName HU.SecCatalog Get-HUSecTokenRoles { return @('Policy.Read.All') }
        (Run 'A14').Reason | Should -Not -Be 'Recht'
    }
}

Describe 'Anmeldefehler AADSTS500011 in Klartext' {
    BeforeEach { Base }
    It 'A32: Fehler 400 mit AADSTS500011 zeigt verstaendlichen Text statt Rohmeldung' {
        $global:HUSecFx['secureScores'] = { $ex = New-Object System.Exception('Graph-Fehler: AADSTS500011: The resource principal named https://mgmt-tenantdiscoverygw-prd.securitycenter.microsoft.com was not found'); $ex.Data['StatusCode'] = 400; throw $ex }
        $r = Run 'A32'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Technisch'
        $r.Detail | Should -BeLike '*AADSTS500011*'; $r.Detail | Should -Not -BeLike '*resource principal*'
    }
}

Describe 'A33 externe Freigabe ohne Anmeldung' {
    BeforeEach { Base }
    It 'anonyme Links erlaubt: Abweichung' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ sharingCapability = 'externalUserAndGuestSharing' }
        (Run 'A33').Status | Should -Be 'Abweichung'
    }
    It 'nur angemeldete Gaeste: OK' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ sharingCapability = 'externalUserSharingOnly' }
        (Run 'A33').Status | Should -Be 'OK'
    }
    It 'unbekannter Wert (unknownFutureValue): nicht pruefbar Technisch, nicht OK' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ sharingCapability = 'unknownFutureValue' }
        $r = Run 'A33'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Technisch'
    }
    It 'Feld fehlt: nicht pruefbar, nicht OK' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ x = 1 }
        (Run 'A33').Status | Should -Be 'NichtPruefbar'
    }
}

Describe 'Ampel je Tenant (Get-HUSecLight)' {
    function script:MkRes($id, $st) { [pscustomobject]@{ Tenant = 'T'; RuleId = $id; Status = $st; Reason = $null; Count = 0 } }
    It 'Zaehlung ok von geprueft, kritische Abweichung zaehlt je Schweregrad' {
        $l = Get-HUSecLight -Key 'T' -Results @((MkRes 'A17' 'Abweichung'), (MkRes 'A03' 'OK'), (MkRes 'A04' 'OK'), (MkRes 'A30' 'NichtPruefbar'))
        $l.Ok | Should -Be 2; $l.Checked | Should -Be 3; $l.BySev['Kritisch'] | Should -Be 1; $l.NotCheckable | Should -Be 1; $l.Color | Should -Be 'Gelb'
    }
    It 'Rot ab 10 nicht erfuellten Regeln, 9 sind noch Gelb' {
        $ids = 'A01','A02','A03','A04','A08','A09','A14','A15','A17','A19'
        (Get-HUSecLight -Key 'T' -Results @($ids[0..8] | ForEach-Object { MkRes $_ 'Abweichung' })).Color | Should -Be 'Gelb'
        (Get-HUSecLight -Key 'T' -Results @($ids | ForEach-Object { MkRes $_ 'Abweichung' })).Color | Should -Be 'Rot'
    }
    It 'Gelb bei einzelner Abweichung' {
        (Get-HUSecLight -Key 'T' -Results @((MkRes 'A08' 'Abweichung'), (MkRes 'A03' 'OK'))).Color | Should -Be 'Gelb'
    }
    It 'Gruen ohne Abweichung, Ausnahme zaehlt als in Ordnung' {
        $l = Get-HUSecLight -Key 'T' -Results @((MkRes 'A03' 'OK'), (MkRes 'A17' 'Ausnahme'))
        $l.Color | Should -Be 'Gruen'; $l.Ok | Should -Be 2
    }
    It 'Grau, wenn nichts geprueft wurde (nur nicht pruefbar)' {
        (Get-HUSecLight -Key 'T' -Results @((MkRes 'A30' 'NichtPruefbar'))).Color | Should -Be 'Grau'
    }
}

Describe 'Soll-Stand: speichern und vergleichen' {
    BeforeAll { function script:Mk($t, $id, $st, $cnt = 0) { [pscustomobject]@{ Tenant = $t; RuleId = $id; Title = 'x'; Sev = 'Hoch'; Status = $st; Reason = ''; Count = $cnt; ExceptionId = '' } } }
    It 'ohne gespeicherten Stand: $null' {
        Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'soll.json') -Force -ErrorAction SilentlyContinue
        Get-HUSecReference | Should -BeNullOrEmpty
    }
    It 'Soll enthaelt nur Status und Zahlen' {
        $f = Save-HUSecReference -Results @((Mk 'T1' 'A03' 'OK'), (Mk 'T1' 'A04' 'Abweichung' 3))
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        (@($j.rows[0].PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be 'count,reason,ruleId,status,tenant'
        (Get-HUSecReference).rows.Count | Should -Be 2
    }
    It 'gleicher Stand: keine Aenderung' {
        $c = Compare-HUSecReference -Results @((Mk 'T1' 'A03' 'OK'), (Mk 'T1' 'A04' 'Abweichung' 3)) -Reference (Get-HUSecReference)
        @($c.Changes).Count | Should -Be 0
    }
    It 'Status- und Anzahl-Aenderung, schlechter zuerst' {
        $c = Compare-HUSecReference -Results @((Mk 'T1' 'A03' 'Abweichung' 1), (Mk 'T1' 'A04' 'Abweichung' 2)) -Reference (Get-HUSecReference)
        @($c.Changes).Count | Should -Be 2
        $c.Changes[0].RuleId | Should -Be 'A03'
        $c.Changes[0].Worse | Should -BeTrue
        $c.Changes[1].Kind | Should -Be 'Anzahl'
        $c.Changes[1].Worse | Should -BeFalse
    }
    It 'nicht pruefbar ist keine Aenderung, wird nur gezaehlt' {
        $c = Compare-HUSecReference -Results @((Mk 'T1' 'A03' 'NichtPruefbar')) -Reference (Get-HUSecReference)
        @($c.Changes).Count | Should -Be 0
        $c.Unchecked | Should -Be 1
    }
    It 'dauerhaft nicht pruefbar (schon im Soll) wird nicht gezaehlt' {
        Save-HUSecReference -Results @((Mk 'T9' 'A03' 'NichtPruefbar'), (Mk 'T9' 'A04' 'OK')) | Out-Null
        $c = Compare-HUSecReference -Results @((Mk 'T9' 'A03' 'NichtPruefbar'), (Mk 'T9' 'A04' 'NichtPruefbar')) -Reference (Get-HUSecReference)
        $c.Unchecked | Should -Be 1
    }
    It 'Regeln ohne Eintrag im Soll und nicht gewaehlte Tenants werden uebergangen' {
        $c = Compare-HUSecReference -Results @((Mk 'T1' 'A99' 'Abweichung'), (Mk 'T2' 'A03' 'Abweichung')) -Reference (Get-HUSecReference) -Keys @('T1')
        @($c.Changes).Count | Should -Be 0
    }
}

Describe 'Conditional Access: v1.0 fuehrt, beta ergaenzt' {
    BeforeEach { Base }
    It 'Richtlinie nur in beta: wird ergaenzt und markiert' {
        $a = (Pol 'enabled'); $a | Add-Member id 'a' -Force
        $b = (Pol 'enabled'); $b | Add-Member id 'b' -Force
        $global:HUSecFx['conditionalAccess'] = { if ($global:HUSecBeta) { @($a, $b) } else { @($a) } }
        $ctx = New-HUSecContext -TenantKey 'T1' -Settings ([pscustomobject]@{})
        $ca = @((Get-HUSecFact -Ctx $ctx -Key 'ca').Data)
        $ca.Count | Should -Be 2
        @($ca | Where-Object { $_.PSObject.Properties['__OnlyBeta'] }).Count | Should -Be 1
    }
    It 'beta schlaegt fehl: nur v1.0, kein Fehler' {
        $a = (Pol 'enabled'); $a | Add-Member id 'a' -Force
        $global:HUSecFx['conditionalAccess'] = { if ($global:HUSecBeta) { throw 'beta kaputt' } else { @($a) } }
        $ctx = New-HUSecContext -TenantKey 'T1' -Settings ([pscustomobject]@{})
        @((Get-HUSecFact -Ctx $ctx -Key 'ca').Data).Count | Should -Be 1
    }
}

Describe 'V1: nur blockierende oder einschraenkende Richtlinien' {
    It 'reine Sitzungsrichtlinie ohne Grant braucht keine Ausnahme' {
        $p = Pol 'enabled' -grant @(); $p.grantControls.builtInControls = @()
        InModuleScope HU.SecCatalog -Parameters @{ p = $p } { param($p) Test-HUSecCaRestricts $p } | Should -BeFalse
    }
    It 'MFA-Richtlinie braucht eine' {
        $p = Pol 'enabled'
        InModuleScope HU.SecCatalog -Parameters @{ p = $p } { param($p) Test-HUSecCaRestricts $p } | Should -BeTrue
    }
}

Describe 'Pruefung verloren (3 Laeufe in Folge nicht pruefbar)' {
    BeforeAll { function script:Mk2($id, $st) { [pscustomobject]@{ Tenant = 'T1'; RuleId = $id; Title = 'x'; Sev = 'Hoch'; Status = $st; Reason = 'Recht'; Count = 0; ExceptionId = '' } } }
    It 'erst im dritten Lauf, nur einmal, Reset bei pruefbar' {
        Save-HUSecReference -Results @((Mk2 'A03' 'OK')) | Out-Null
        $ref = Get-HUSecReference
        @(Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference $ref).Count | Should -Be 0
        @(Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference $ref).Count | Should -Be 0
        @(Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference $ref).Count | Should -Be 1
        @(Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference $ref).Count | Should -Be 0
        @(Update-HUSecLost -Results @((Mk2 'A03' 'OK')) -Reference $ref).Count | Should -Be 0
        @(Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference $ref).Count | Should -Be 0
    }
    It 'Zaehlerdatei enthaelt nur Schluessel, Anzahl, Flag' {
        Update-HUSecLost -Results @((Mk2 'A03' 'NichtPruefbar')) -Reference (Get-HUSecReference) | Out-Null
        $j = Get-Content -LiteralPath (Join-Path (Get-HUSecPath) 'soll-verloren.json') -Raw | ConvertFrom-Json
        (@($j.rows[0].PSObject.Properties.Name | Sort-Object) -join ',') | Should -Be 'key,reported,runs'
    }
    It 'neuer Soll-Stand setzt die Zaehler zurueck' {
        Save-HUSecReference -Results @((Mk2 'A03' 'OK')) | Out-Null
        Test-Path (Join-Path (Get-HUSecPath) 'soll-verloren.json') | Should -BeFalse
    }
}

Describe 'A34 bis A36 SharePoint-Zusatzfelder' {
    BeforeEach { Base }
    It 'A34: Legacy-Auth erlaubt = Abweichung, aus = OK, Feld fehlt = nicht pruefbar' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ isLegacyAuthProtocolsEnabled = $true }; (Run 'A34').Status | Should -Be 'Abweichung'
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ isLegacyAuthProtocolsEnabled = $false }; (Run 'A34').Status | Should -Be 'OK'
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ x = 1 }; (Run 'A34').Status | Should -Be 'NichtPruefbar'
    }
    It 'A35: Weitergabe erlaubt = Abweichung, aus = OK, Feld fehlt = nicht pruefbar' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ isResharingByExternalUsersEnabled = $true }; (Run 'A35').Status | Should -Be 'Abweichung'
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ isResharingByExternalUsersEnabled = $false }; (Run 'A35').Status | Should -Be 'OK'
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ x = 1 }; (Run 'A35').Status | Should -Be 'NichtPruefbar'
    }
    It 'A36: nur Info, mit Klartext; Felder fehlen = nicht pruefbar' {
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ sharingDomainRestrictionMode = 'allowList'; idleSessionSignOut = [pscustomobject]@{ isEnabled = $true; signOutAfterInSeconds = 3600 } }
        $r = Run 'A36'; $r.Status | Should -Be 'Info'; $r.Detail | Should -BeLike '*nur erlaubte Domaenen*'; $r.Detail | Should -BeLike '*60 Min*'
        $global:HUSecFx['sharepoint/settings'] = [pscustomobject]@{ x = 1 }; (Run 'A36').Status | Should -Be 'NichtPruefbar'
    }
}

Describe 'A37 bis A42 neue Regeln' {
    BeforeEach { Base }
    It 'A37: synchronisiertes Admin-Konto ist Abweichung, Cloud-Konto OK' {
        $global:HUSecFx['roleDefinitions'] = @([pscustomobject]@{ id = 'r1'; displayName = 'Global Administrator' })
        $global:HUSecFx['roleAssignments'] = @([pscustomobject]@{ principalId = 'u1'; roleDefinitionId = 'r1'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user' } },
                                               [pscustomobject]@{ principalId = 'u2'; roleDefinitionId = 'r1'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user' } })
        $global:HUSecFx['id%20in'] = @([pscustomobject]@{ id = 'u1'; userPrincipalName = 'a@x'; onPremisesSyncEnabled = $true }, [pscustomobject]@{ id = 'u2'; userPrincipalName = 'b@x'; onPremisesSyncEnabled = $null })
        $r = Run 'A37'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $global:HUSecFx['id%20in'] = @([pscustomobject]@{ id = 'u1'; userPrincipalName = 'a@x'; onPremisesSyncEnabled = $null }, [pscustomobject]@{ id = 'u2'; userPrincipalName = 'b@x'; onPremisesSyncEnabled = $false })
        (Run 'A37').Status | Should -Be 'OK'
    }
    It 'A38: Sync aelter als 3 Stunden ist Abweichung, frisch OK, ohne Sync nicht anwendbar' {
        $global:HUSecFx['/organization'] = [pscustomobject]@{ onPremisesSyncEnabled = $true; onPremisesLastSyncDateTime = [datetime]::UtcNow.AddHours(-5).ToString('o') }
        (Run 'A38').Status | Should -Be 'Abweichung'
        $global:HUSecFx['/organization'] = [pscustomobject]@{ onPremisesSyncEnabled = $true; onPremisesLastSyncDateTime = [datetime]::UtcNow.AddMinutes(-10).ToString('o') }
        (Run 'A38').Status | Should -Be 'OK'
        $global:HUSecFx['/organization'] = [pscustomobject]@{ onPremisesSyncEnabled = $null }
        $r = Run 'A38'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'NichtAnwendbar'
    }
    It 'A39: Sync-Fehler werden gezaehlt und gelistet' {
        $global:HUSecFx['onPremisesProvisioningErrors'] = { if ($global:HUSecEp -like '/users*') { @([pscustomobject]@{ userPrincipalName = 'a@x'; onPremisesProvisioningErrors = @([pscustomobject]@{ propertyCausingError = 'ProxyAddress'; value = 'smtp:a@x'; occurredDateTime = '2026-10-01T00:00:00Z' }) }, [pscustomobject]@{ userPrincipalName = 'b@x'; onPremisesProvisioningErrors = @() }) } else { @() } }
        $r = Run 'A39'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $global:HUSecFx['onPremisesProvisioningErrors'] = { @() }
        (Run 'A39').Status | Should -Be 'OK'
    }
    It 'A40: SMS an ist Abweichung, E-Mail allein zaehlt nicht' {
        $global:HUSecFx['authenticationMethodsPolicy'] = [pscustomobject]@{ authenticationMethodConfigurations = @([pscustomobject]@{ id = 'Sms'; state = 'enabled' }, [pscustomobject]@{ id = 'Voice'; state = 'disabled' }, [pscustomobject]@{ id = 'Email'; state = 'enabled' }) }
        $r = Run 'A40'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $global:HUSecFx['authenticationMethodsPolicy'] = [pscustomobject]@{ authenticationMethodConfigurations = @([pscustomobject]@{ id = 'Sms'; state = 'disabled' }, [pscustomobject]@{ id = 'Email'; state = 'enabled' }) }
        (Run 'A40').Status | Should -Be 'OK'
        $global:HUSecFx['authenticationMethodsPolicy'] = [pscustomobject]@{ x = 1 }
        (Run 'A40').Status | Should -Be 'NichtPruefbar'
    }
    It 'A41: Workflow aus ist Abweichung, an ist OK' {
        $global:HUSecFx['adminConsentRequestPolicy'] = [pscustomobject]@{ isEnabled = $false }; (Run 'A41').Status | Should -Be 'Abweichung'
        $global:HUSecFx['adminConsentRequestPolicy'] = [pscustomobject]@{ isEnabled = $true }; (Run 'A41').Status | Should -Be 'OK'
    }
    It 'A42: kritische Rechte fremder Apps zaehlen, die eigene App nicht' {
        $global:HUSecFx['servicePrincipals'] = {
            if ($global:HUSecEp -like '*appRoleAssignedTo*') {
                @([pscustomobject]@{ principalId = 'sp1'; principalDisplayName = 'Fremd'; appRoleId = 'r1' }, [pscustomobject]@{ principalId = 'sp1'; principalDisplayName = 'Fremd'; appRoleId = 'r2' },
                  [pscustomobject]@{ principalId = 'own'; principalDisplayName = 'Eigen'; appRoleId = 'r1' }, [pscustomobject]@{ principalId = 'sp2'; principalDisplayName = 'Harmlos'; appRoleId = 'r2' })
            }
            elseif ($global:HUSecEp -like '*00000003*') { [pscustomobject]@{ id = 'g'; appRoles = @([pscustomobject]@{ id = 'r1'; value = 'Directory.ReadWrite.All' }, [pscustomobject]@{ id = 'r2'; value = 'User.Read.All' }) } }
            else { [pscustomobject]@{ id = 'own' } }
        }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'my-app' }) }
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $set -RuleIds @('A42') | Where-Object { $_.RuleId -eq 'A42' })[0]
        $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $r.Detail | Should -BeLike '*nicht mitgezaehlt*'
    }
}

Describe 'V1 (037 B4): gemeinsames bzw. hinterlegtes Notfallkonto' {
    BeforeAll {
        function script:VPol([string[]]$exU = @(), [string[]]$exG = @(), [string[]]$exR = @(), $state = 'enabled', $users = @('All')) {
            $p = Pol $state -users $users
            $p.conditions.users | Add-Member excludeUsers $exU -Force
            $p.conditions.users | Add-Member excludeGroups $exG -Force
            $p.conditions.users | Add-Member excludeRoles $exR -Force
            $p | Add-Member id ([guid]::NewGuid().ToString()) -Force; $p | Add-Member displayName 'P' -Force
            $p
        }
        $script:BG1 = '11111111-1111-1111-1111-111111111111'; $script:BG2 = '22222222-2222-2222-2222-222222222222'
    }
    BeforeEach {
        Base
        Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue
        $global:HUSecFx['transitiveMembers'] = { if ($global:HUSecEp -like '*/groups/aaaaaaaa-0000-0000-0000-000000000001/*') { @([pscustomobject]@{ id = $script:BG1 }) } elseif ($global:HUSecEp -like '*/groups/aaaaaaaa-0000-0000-0000-000000000002/*') { @() } else { $ex = New-Object System.Exception('x'); $ex.Data['StatusCode'] = 500; throw $ex } }
    }
    It 'dasselbe Konto direkt in allen: OK' {
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1)), (VPol @($BG1, $BG2)))
        (Run 'V1').Status | Should -Be 'OK'
    }
    It 'direkt und ueber Gruppe: OK; GUID in Grossbuchstaben zaehlt gleich' {
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1.ToUpper())), (VPol @() @('aaaaaaaa-0000-0000-0000-000000000001')))
        (Run 'V1').Status | Should -Be 'OK'
    }
    It 'verschiedene Konten je Richtlinie: Abweichung' {
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1)), (VPol @($BG2)))
        $r = Run 'V1'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -BeLike '*kein Konto ist in allen*'
    }
    It 'eine Richtlinie ohne Ausnahme, nur Rollen, nur Platzhalter oder leere Gruppe: Abweichung' {
        foreach ($second in @((VPol), (VPol @() @() @('r1')), (VPol @('GuestsOrExternalUsers')), (VPol @() @('aaaaaaaa-0000-0000-0000-000000000002')))) {
            $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1)), $second)
            $r = Run 'V1'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        }
    }
    It 'Gruppe nicht lesbar: nicht pruefbar, nie OK' {
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1) @('bbbbbbbb-0000-0000-0000-000000000009')))
        $r = Run 'V1'; $r.Status | Should -Be 'NichtPruefbar'; $r.Reason | Should -Be 'Technisch'
    }
    It 'Berichtsmodus und reine Gruppenrichtlinie zaehlen nicht: Info' {
        $global:HUSecFx['conditionalAccess'] = @((VPol @() @() @() 'enabledForReportingButNotEnforced'), (VPol @() @() @() 'enabled' @('u1')))
        (Run 'V1').Status | Should -Be 'Info'
    }
    It 'mehr als 4 gemeinsame Ausnahmen: OK mit Hinweis' {
        $many = 1..5 | ForEach-Object { "0000000$_-0000-0000-0000-000000000000" }
        $global:HUSecFx['conditionalAccess'] = @((VPol $many), (VPol $many))
        $r = Run 'V1'; $r.Status | Should -Be 'OK'; $r.Detail | Should -BeLike '*mehr als ueblich*'
    }
    It 'hinterlegte Notfallkonten: fehlt eines in einer Richtlinie = Abweichung, sonst OK; ungueltige ID wird ignoriert' {
        $j = [pscustomobject]@{ global = [pscustomobject]@{ V1 = [pscustomobject]@{ accounts = @($BG1, $BG2, 'kein-guid') } } }
        $j | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1, $BG2)), (VPol @($BG1)))
        $r = Run 'V1'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $global:HUSecFx['conditionalAccess'] = @((VPol @($BG1, $BG2)), (VPol @($BG2) @('aaaaaaaa-0000-0000-0000-000000000001')))
        (Run 'V1').Status | Should -Be 'OK'
    }
}

Describe 'A24 Geoblock (037 B5)' {
    BeforeAll {
        function script:GPol($inc = @('c1'), $exc = @(), $users = @('All'), [hashtable]$More = @{}) {
            $p = Pol 'enabled' -users $users -grant @('block')
            $p.conditions | Add-Member locations ([pscustomobject]@{ includeLocations = $inc; excludeLocations = $exc }) -Force
            foreach ($k in $More.Keys) { $p.conditions | Add-Member $k $More[$k] -Force }
            $p | Add-Member displayName 'G' -Force
            $p
        }
    }
    BeforeEach {
        Base
        $script:Locs = @([pscustomobject]@{ id = 'c1'; '@odata.type' = '#microsoft.graph.countryNamedLocation' }, [pscustomobject]@{ id = 'ip1'; '@odata.type' = '#microsoft.graph.ipNamedLocation' })
        $script:GP = @()
        # ein Schluessel fuer beide Adressen (namedLocations enthaelt auch 'conditionalAccess'): nach Adresse unterscheiden
        $global:HUSecFx['conditionalAccess'] = { if ($global:HUSecEp -like '*namedLocations*') { $script:Locs } else { $script:GP } }
    }
    It 'Laender-Sperrliste und Erlaubnisliste (alle ausser Laender bzw. vertrauenswuerdige) zaehlen' {
        $script:GP = @((GPol @('c1'))); (Run 'A24').Status | Should -Be 'OK'
        $script:GP = @((GPol @('All') @('c1'))); (Run 'A24').Status | Should -Be 'OK'
        $script:GP = @((GPol @('All') @('AllTrusted'))); (Run 'A24').Status | Should -Be 'OK'
    }
    It 'reine IP-Orte, Einzelbenutzer, Benutzeraktion, Geraetecode-Flow, Client-Apps, Plattform zaehlen nicht' {
        $cases = @(
            (GPol @('ip1')),
            (GPol @('c1') @() @('u1')),
            (GPol @('c1') @() @('All') @{ authenticationFlows = [pscustomobject]@{ transferMethods = 'deviceCodeFlow' } }),
            (GPol @('c1') @() @('All') @{ clientAppTypes = @('exchangeActiveSync') }),
            (GPol @('c1') @() @('All') @{ platforms = [pscustomobject]@{ includePlatforms = @('android') } })
        )
        $ua = GPol @('c1'); $ua.conditions.applications | Add-Member includeUserActions @('urn:user:registersecurityinfo') -Force; $cases += $ua
        $ex = GPol @('c1'); $ex.conditions.applications | Add-Member excludeApplications @('app1') -Force; $cases += $ex
        foreach ($c in $cases) { $script:GP = @($c); (Run 'A24').Status | Should -Be 'Abweichung' }
    }
    It 'Berichtsmodus: Abweichung mit Hinweis; Ausnahmen werden genannt' {
        $p = GPol @('c1'); $p.state = 'enabledForReportingButNotEnforced'
        $script:GP = @($p); (Run 'A24').Detail | Should -BeLike '*Berichtsmodus*'
        $q = GPol @('c1'); $q.conditions.users | Add-Member excludeGroups @('g1') -Force
        $script:GP = @($q); $r = Run 'A24'; $r.Status | Should -Be 'OK'; $r.Detail | Should -BeLike '*Ausnahmen pruefen*'
    }
}

Describe 'A25 Adminportale (037 B6)' {
    BeforeAll {
        function script:APol($exR = @('r1'), $exG = @(), $exU = @(), $state = 'enabled') {
            $p = Pol $state -apps @('MicrosoftAdminPortals') -grant @('block')
            $p.conditions.users | Add-Member excludeRoles $exR -Force
            $p.conditions.users | Add-Member excludeGroups $exG -Force
            $p.conditions.users | Add-Member excludeUsers $exU -Force
            $p | Add-Member displayName 'AP' -Force
            $p
        }
    }
    BeforeEach { Base; Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue }
    It 'nur Admin-Rollen ausgenommen: OK; bis 4 Einzelkonten erlaubt' {
        $global:HUSecFx['conditionalAccess'] = @((APol @('r1') @() @('a', 'b'))); (Run 'A25').Status | Should -Be 'OK'
    }
    It 'fremde Gruppe oder mehr als 4 Konten: Abweichung (zu breite Ausnahme); keine Admin-Ausnahme: Abweichung' {
        $global:HUSecFx['conditionalAccess'] = @((APol @('r1') @('99999999-0000-0000-0000-000000000000')))
        $r = Run 'A25'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -BeLike '*zu breite Ausnahme*'
        $global:HUSecFx['conditionalAccess'] = @((APol @('r1') @() @('a', 'b', 'c', 'd', 'e'))); (Run 'A25').Status | Should -Be 'Abweichung'
        $global:HUSecFx['conditionalAccess'] = @((APol @() @() @('a'))); (Run 'A25').Status | Should -Be 'Abweichung'
    }
    It 'hinterlegte Admin-Gruppe zaehlt als Admin-Ausnahme' {
        $gid = '99999999-0000-0000-0000-000000000000'
        [pscustomobject]@{ global = [pscustomobject]@{ A25 = [pscustomobject]@{ adminGroups = @($gid) } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        $global:HUSecFx['conditionalAccess'] = @((APol @() @($gid.ToUpper()))); (Run 'A25').Status | Should -Be 'OK'
    }
}

Describe 'A27 veraltete Admin-Konten (037 B7/B8/B9/B19)' {
    BeforeAll {
        function script:Asg($id, $type = 'user') { [pscustomobject]@{ principalId = $id; principal = [pscustomobject]@{ '@odata.type' = "#microsoft.graph.$type"; displayName = "N$id" } } }
        function script:Usr($id, $ok = $null, $any = $null, $created = '2020-01-01T00:00:00Z', $enabled = $true) {
            $o = [pscustomobject]@{ id = $id; userPrincipalName = "$id@x"; createdDateTime = $created; signInActivity = $(if ($ok -or $any) { [pscustomobject]@{ lastSuccessfulSignInDateTime = $ok; lastSignInDateTime = $any } } else { $null }) }
            if ($null -ne $enabled) { $o | Add-Member accountEnabled $enabled }
            $o
        }
        $script:Rec = [datetime]::UtcNow.AddDays(-10).ToString('o'); $script:Old = [datetime]::UtcNow.AddDays(-120).ToString('o')
    }
    BeforeEach { Base; Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue }
    It 'erfolgreich vor 10 Tagen OK, vor 120 Tagen Abweichung; nur Fehlversuch zaehlt nicht als Aktivitaet' {
        $global:HUSecFx['roleAssignments'] = @((Asg 'u1'), (Asg 'u2'), (Asg 'u3'))
        $global:HUSecFx['/users?'] = @((Usr 'u1' $Rec), (Usr 'u2' $Old), (Usr 'u3' $null $Rec), (Usr 'x9' $Old))
        $r = Run 'A27'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 2
        $r.Detail | Should -BeLike '*unbekannt*'
    }
    It 'nie angemeldet: altes Konto Abweichung, neues Konto OK; accountEnabled fehlt = aktiv, false = ignoriert' {
        $global:HUSecFx['roleAssignments'] = @((Asg 'u1'), (Asg 'u2'), (Asg 'u3'), (Asg 'u4'))
        $global:HUSecFx['/users?'] = @((Usr 'u1' $null $null '2020-01-01T00:00:00Z'), (Usr 'u2' $null $null ([datetime]::UtcNow.AddDays(-5).ToString('o'))), (Usr 'u3' $Old $null '2020-01-01T00:00:00Z' $null), (Usr 'u4' $Old $null '2020-01-01T00:00:00Z' $false))
        $r = Run 'A27'; $r.Count | Should -Be 2; $r.Detail | Should -BeLike '*nie angemeldet*'
    }
    It 'Rolle ueber Gruppe wird aufgeloest, Dienstprinzipal gezaehlt, Notfallkonto ausgenommen' {
        $global:HUSecFx['roleAssignments'] = @((Asg 'g1' 'group'), (Asg 'sp1' 'servicePrincipal'), (Asg '11111111-1111-1111-1111-111111111111'))
        $global:HUSecFx['/members/'] = @([pscustomobject]@{ id = 'u5' })
        $global:HUSecFx['/users?'] = @((Usr 'u5' $Old), (Usr '11111111-1111-1111-1111-111111111111' $Old))
        [pscustomobject]@{ global = [pscustomobject]@{ V1 = [pscustomobject]@{ accounts = @('11111111-1111-1111-1111-111111111111') } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        $r = Run 'A27'; $r.Count | Should -Be 1; $r.Detail | Should -BeLike '*1 ueber Gruppe*'; $r.Detail | Should -BeLike '*1 Dienstprinzipal*'
    }
    It 'Ersatz lastSignInDateTime nur vor dem 1.12.2023' {
        $global:HUSecFx['roleAssignments'] = @((Asg 'u1'))
        $global:HUSecFx['/users?'] = @((Usr 'u1' $null '2023-06-01T00:00:00Z'))
        $r = Run 'A27'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -Not -BeLike '*unbekannt*'
    }
}

Describe 'Datum kulturunabhaengig (037 B9)' {
    It 'String mit Z, mit Offset und DateTime ergeben denselben UTC-Zeitpunkt, auch in deutscher Kultur' {
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'de-AT'
            InModuleScope HU.SecCatalog {
                $a = ConvertTo-HUSecUtc '2026-01-31T22:00:00Z'
                $b = ConvertTo-HUSecUtc '2026-02-01T00:00:00+02:00'
                $c = ConvertTo-HUSecUtc ([datetime]::new(2026, 1, 31, 22, 0, 0, [DateTimeKind]::Utc))
                $a | Should -Be $b; $a | Should -Be $c; $a.Kind | Should -Be 'Utc'
                ConvertTo-HUSecUtc 'kein Datum' | Should -BeNullOrEmpty
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'A30 Anmelderisiko und A29 Lizenz (037 B11/B18)' {
    BeforeAll {
        function script:SkuP2($status = 'Success', $cap = 'Enabled') { , @([pscustomobject]@{ capabilityStatus = $cap; servicePlans = @([pscustomobject]@{ servicePlanId = 'eec0eb4f-6444-4f95-aba0-50c24d67f998'; servicePlanName = 'X'; provisioningStatus = $status }, [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) }
        function script:RPol($levels = @('high'), $grant = @('block'), $freq = $null) {
            $p = Pol 'enabled' -grant $grant
            $p.conditions | Add-Member signInRiskLevels $levels -Force
            if ($freq) { $p | Add-Member sessionControls ([pscustomobject]@{ signInFrequency = [pscustomobject]@{ frequencyInterval = $freq } }) -Force }
            $p | Add-Member displayName 'R' -Force
            $p
        }
    }
    BeforeEach { Base }
    It 'ohne P2 bzw. P2 gesperrt: nicht pruefbar (Lizenz) mit P1-Ersatz' {
        (Run 'A30').Reason | Should -Be 'Lizenz'
        $global:HUSecFx['subscribedSkus'] = (SkuP2 'Success' 'Suspended'); (Run 'A30').Reason | Should -Be 'Lizenz'
        (Run 'A30').Detail | Should -BeLike '*Ersatz mit P1*'
    }
    It 'P2 per Plan-ID erkannt; Block bei hoch OK, MFA nur mit "jedes Mal" OK, nur niedrig Abweichung' {
        $global:HUSecFx['subscribedSkus'] = (SkuP2)
        $global:HUSecFx['conditionalAccess'] = @((RPol @('high'))); (Run 'A30').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((RPol @('medium') @('mfa') 'everyTime')); (Run 'A30').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((RPol @('medium') @('mfa'))); (Run 'A30').Status | Should -Be 'Abweichung'
        $global:HUSecFx['conditionalAccess'] = @((RPol @('low'))); (Run 'A30').Status | Should -Be 'Abweichung'
        (Run 'A29').Status | Should -Be 'Info'
    }
}

Describe 'A28 Vorlage, A26 Einladungsalter, Sollwerte pruefen (037 B12/B13/B15)' {
    BeforeEach { Base; Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue }
    It 'A28 waehlt nach templateId, auch bei anderem Anzeigenamen' {
        $global:HUSecFx['groupSettings'] = @([pscustomobject]@{ displayName = 'Anders'; templateId = '5cf42378-d67d-4f36-ba46-e8b86229381d'; values = @([pscustomobject]@{ name = 'EnableBannedPasswordCheckOnPremises'; value = 'true' }, [pscustomobject]@{ name = 'BannedPasswordCheckOnPremisesMode'; value = 'Enforce' }) })
        (Run 'A28').Status | Should -Be 'OK'
    }
    It 'A26 rechnet ab der letzten Einladung (externalUserStateChangeDateTime)' {
        $global:HUSecFx["userType%20eq%20'Guest'"] = @([pscustomobject]@{ id = 'g'; externalUserState = 'PendingAcceptance'; createdDateTime = '2020-01-01T00:00:00Z'; externalUserStateChangeDateTime = [datetime]::UtcNow.AddDays(-3).ToString('o') })
        (Run 'A26').Status | Should -Be 'OK'
    }
    It 'ungueltiger Zahlen-Sollwert: Standard bleibt, Fehler wird gemeldet' {
        [pscustomobject]@{ global = [pscustomobject]@{ A27 = [pscustomobject]@{ staleDays = 'neunzig' } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        $bl = Get-HUSecBaseline -TenantKey 'T1' -Rules (InModuleScope HU.SecCatalog { Get-HUSecRules })
        $bl.Values['A27'].staleDays | Should -Be 90
        @($bl.Errors) -join ' ' | Should -BeLike '*A27.staleDays ungueltig*'
    }
}

Describe 'A37 auch ueber Gruppenrollen' {
    BeforeEach { Base }
    It 'Mitglied einer rollenzuweisbaren Gruppe aus dem lokalen AD zaehlt, Rolle mit Gruppenname in der Liste' {
        $global:HUSecFx['roleDefinitions'] = @([pscustomobject]@{ id = 'r1'; displayName = 'Global Administrator' })
        $global:HUSecFx['roleAssignments'] = @([pscustomobject]@{ principalId = 'u1'; roleDefinitionId = 'r1'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user' } },
                                               [pscustomobject]@{ principalId = 'g1'; roleDefinitionId = 'r1'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; displayName = 'Admins' } })
        $global:HUSecFx['/members/'] = @([pscustomobject]@{ id = 'u2' })
        $global:HUSecFx['id%20in'] = @([pscustomobject]@{ id = 'u1'; userPrincipalName = 'a@x'; onPremisesSyncEnabled = $null }, [pscustomobject]@{ id = 'u2'; userPrincipalName = 'b@x'; onPremisesSyncEnabled = $true })
        $r = Run 'A37'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1; $r.Detail | Should -BeLike '1 von 2*'
        $items = @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'A37')
        $items[0].Rollen | Should -BeLike '*ueber Gruppe Admins*'
    }
}

Describe 'A23 Hoechstwert Anmeldehaeufigkeit (037 B14)' {
    BeforeAll {
        function script:SPol($type = 'hours', $value = 12, $interval = 'timeBased', $guests = $true, $users = @('u1')) {
            $p = Pol 'enabled' -users $users -grant @()
            if ($guests) { $p.conditions.users | Add-Member includeGuestsOrExternalUsers ([pscustomobject]@{ guestOrExternalUserTypes = 'b2bCollaborationGuest' }) -Force }
            $p | Add-Member sessionControls ([pscustomobject]@{ signInFrequency = [pscustomobject]@{ isEnabled = $true; type = $type; value = $value; frequencyInterval = $interval } }) -Force
            $p | Add-Member displayName 'S' -Force
            $p
        }
    }
    BeforeEach { Base; Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue }
    It '12 Stunden OK, 7 Tage Abweichung, jedes Mal OK, alle Benutzer zaehlt fuer Gaeste' {
        $global:HUSecFx['conditionalAccess'] = @((SPol 'hours' 12)); (Run 'A23').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((SPol 'days' 7)); $r = Run 'A23'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -BeLike '*168 Stunden*'
        $global:HUSecFx['conditionalAccess'] = @((SPol $null $null 'everyTime')); (Run 'A23').Status | Should -Be 'OK'
        $global:HUSecFx['conditionalAccess'] = @((SPol 'hours' 8 'timeBased' $false @('All'))); (Run 'A23').Status | Should -Be 'OK'
    }
    It 'Sollwert maxHours erlaubt 7 Tage' {
        [pscustomobject]@{ global = [pscustomobject]@{ A23 = [pscustomobject]@{ maxHours = 168 } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        $global:HUSecFx['conditionalAccess'] = @((SPol 'days' 7)); (Run 'A23').Status | Should -Be 'OK'
    }
}

Describe 'V1-Liste: Namen gesammelt aufgeloest (037 B16)' {
    BeforeEach { Base }
    It 'loest ueber 40 Ausnahmen in Bloecken auf und markiert geloeschte' {
        $ids = 1..45 | ForEach-Object { '{0:x8}-0000-0000-0000-000000000000' -f $_ }
        $p = Pol 'enabled'; $p.conditions.users | Add-Member excludeUsers @($ids + '{0:x8}-0000-0000-0000-000000000000' -f 999) -Force; $p.conditions.users | Add-Member excludeGroups @() -Force
        $p | Add-Member id 'p1' -Force; $p | Add-Member displayName 'P' -Force
        $global:HUSecFx['conditionalAccess'] = @($p)
        $global:HUSecFx['/users?$filter=id%20in'] = { $m = [regex]::Matches($global:HUSecEp, "'([0-9a-f-]{36})'"); @($m | ForEach-Object { $v = $_.Groups[1].Value; if ($v -notlike '000003e7*') { [pscustomobject]@{ id = $v; userPrincipalName = "u-$($v.Substring(0,8))@x" } } }) }
        $it = @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'V1')
        $it[0].Ausnahmen | Should -BeLike '*u-0000002d@x*'
        $it[0].Ausnahmen | Should -BeLike '*(geloescht oder nicht gefunden)*'
        $it[0].Ausnahmen | Should -Not -BeLike '*nicht abgefragt*'
    }
}

Describe 'Soll schlechter als voriger (038 B7)' {
    BeforeAll { function script:Mk3($id, $st, $cnt = 0) { [pscustomobject]@{ Tenant = 'T1'; RuleId = $id; Title = 'x'; Sev = 'Hoch'; Status = $st; Reason = ''; Count = $cnt; ExceptionId = '' } } }
    It 'merkt beim Speichern die Zahl der Verschlechterungen und die Vorschau zeigt sie vorher' {
        Save-HUSecReference -Results @((Mk3 'A03' 'OK'), (Mk3 'A04' 'Abweichung' 1)) | Out-Null
        (Get-HUSecReference).worse | Should -Be 0
        @(Get-HUSecReferenceWorse -Results @((Mk3 'A03' 'Abweichung' 1), (Mk3 'A04' 'Abweichung' 3))).Count | Should -Be 2
        Save-HUSecReference -Results @((Mk3 'A03' 'Abweichung' 1), (Mk3 'A04' 'Abweichung' 3)) | Out-Null
        $r = Get-HUSecReference; $r.worse | Should -Be 2; [bool]$r.worseShown | Should -BeFalse; "$($r.prevTime)" | Should -Not -BeNullOrEmpty
        Set-HUSecReferenceWorseShown
        [bool](Get-HUSecReference).worseShown | Should -BeTrue
    }
}

Describe 'Sollwerte-Dialog: lesen und speichern' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Force -ErrorAction SilentlyContinue }
    It 'speichert je Tenant, behaelt andere Eintraege, prueft IDs und Zahlen, leer entfernt' {
        # bestehende Datei mit fremdem Eintrag
        [pscustomobject]@{ global = [pscustomobject]@{ A27 = [pscustomobject]@{ staleDays = 60; enabled = $true } }; tenants = [pscustomobject]@{ T2 = [pscustomobject]@{ A08 = [pscustomobject]@{ max = 5 } } } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Encoding UTF8
        @(Save-HUSecBaselineEdit -Scope 'T1' -Values @{ 'V1.accounts' = 'kein-guid' }).Count | Should -Be 1
        @(Save-HUSecBaselineEdit -Scope 'T1' -Values @{ 'A27.staleDays' = '99999' }).Count | Should -Be 1
        @(Save-HUSecBaselineEdit -Scope 'T1' -Values @{ 'V1.accounts' = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE; 11111111-1111-1111-1111-111111111111'; 'A23.maxHours' = '168' }).Count | Should -Be 0
        $rows = @(Get-HUSecBaselineEdit -Scope 'T1')
        ($rows | Where-Object { $_.Rule -eq 'V1' }).Value | Should -Be '11111111-1111-1111-1111-111111111111, aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        ($rows | Where-Object { $_.Rule -eq 'A27' }).Global | Should -Be '60'
        ($rows | Where-Object { $_.Rule -eq 'A27' }).Default | Should -Be '90'
        $bl = Get-HUSecBaseline -TenantKey 'T1' -Rules (InModuleScope HU.SecCatalog { Get-HUSecRules })
        @($bl.Values['V1'].accounts).Count | Should -Be 2
        $bl.Values['A23'].maxHours | Should -Be 168
        $bl.Values['A27'].staleDays | Should -Be 60
        (Get-HUSecBaseline -TenantKey 'T2' -Rules (InModuleScope HU.SecCatalog { Get-HUSecRules })).Values['A08'].max | Should -Be 5
        # leer = entfernen; einzelne ID bleibt eine Liste
        @(Save-HUSecBaselineEdit -Scope 'T1' -Values @{ 'A23.maxHours' = ''; 'V1.accounts' = '11111111-1111-1111-1111-111111111111' }).Count | Should -Be 0
        $j = Get-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Raw | ConvertFrom-Json
        $j.tenants.T1.PSObject.Properties['A23'] | Should -BeNullOrEmpty
        @($j.tenants.T1.V1.accounts).Count | Should -Be 1
        (Get-Content -LiteralPath (Join-Path (Get-HUSecPath) 'baseline.json') -Raw) | Should -Match '"accounts":\s*\['
        $j.global.A27.enabled | Should -BeTrue
    }
}


Describe 'Teams und Gruppen (C03 bis C08)' {
    BeforeEach {
        Base
        $o = { param($n) @(1..$n | ForEach-Object { [pscustomobject]@{ id = "o$_"; displayName = "Besitzer $_" } }) }
        $global:HUSecFx['groupTypes'] = @(
            [pscustomobject]@{ id = 'g1'; displayName = 'Klasse 1A'; visibility = 'HiddenMembership'; resourceProvisioningOptions = @('Team'); owners = (& $o 2) },
            [pscustomobject]@{ id = 'g2'; displayName = 'Konferenz'; visibility = 'Public'; resourceProvisioningOptions = @('Team'); owners = (& $o 1) },
            [pscustomobject]@{ id = 'g3'; displayName = 'Alt'; visibility = 'Private'; resourceProvisioningOptions = @(); owners = @() })
    }
    It 'C03: Gruppe ohne Besitzer ist Abweichung, Liste exportierbar' {
        $r = Run 'C03'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1; $r.Detail | Should -Match 'davon 0 Teams'
        $it = @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'C03'); $it.Count | Should -Be 1; $it[0].Gruppe | Should -Be 'Alt'; $it[0].Art | Should -Be 'Gruppe'
        Test-HUSecItemsExport 'C03' | Should -BeTrue
    }
    It 'C03: ohne owners-Feld nicht pruefbar, ohne Gruppen OK' {
        $global:HUSecFx['groupTypes'] = @([pscustomobject]@{ id = 'g1'; displayName = 'X'; visibility = 'Private' })
        (Run 'C03').Status | Should -Be 'NichtPruefbar'
        $global:HUSecFx['groupTypes'] = @()
        (Run 'C03').Status | Should -Be 'OK'
    }
    It 'C04: ein Besitzer ist Info mit Name, Liste nicht exportierbar' {
        $r = Run 'C04'; $r.Status | Should -Be 'Info'; $r.Count | Should -Be 1
        @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'C04')[0].Besitzer | Should -Be 'Besitzer 1'
        Test-HUSecItemsExport 'C04' | Should -BeFalse
    }
    It 'C05: oeffentliche Gruppe ist Abweichung' {
        $r = Run 'C05'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1
        $global:HUSecFx['groupTypes'] = @([pscustomobject]@{ id = 'g1'; displayName = 'X'; visibility = 'Private'; owners = @() })
        (Run 'C05').Status | Should -Be 'OK'
    }
    It 'C06: Gast in Team wird gefunden, nicht lesbare Gruppe macht unvollstaendig' {
        $global:HUSecFx['userType'] = @([pscustomobject]@{ id = 'GUEST1'; displayName = 'Gast Eins'; mail = 'g@extern'; externalUserState = 'Accepted' })
        # Mitglieder kommen gebuendelt; g3 fehlt (Fehler), g1 hat eine Folgeseite und wird einzeln nachgelesen
        Mock -ModuleName HU.SecCatalog Invoke-HUSecBatch { @{ g1 = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'x' }); '@odata.nextLink' = 'https://next' }; g2 = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'guest1' }, [pscustomobject]@{ id = 'x' }) } } }
        $global:HUSecFx['/members/'] = { $global:HUSecG1 = $true; @([pscustomobject]@{ id = 'x' }, [pscustomobject]@{ id = 'y' }) }
        $r = Run 'C06'; $r.Status | Should -Be 'Abweichung'; $r.Count | Should -Be 1; $r.Detail | Should -Match '1 Gruppe\(n\) nicht lesbar'
        $it = @(Get-HUSecItems -TenantKey 'T1' -Settings ([pscustomobject]@{}) -RuleId 'C06'); $it[0].Gruppe | Should -Be 'Konferenz'; $it[0].Art | Should -Be 'Team'
        $global:HUSecG1 | Should -BeTrue
        Test-HUSecItemsExport 'C06' | Should -BeFalse
    }
    It 'C06: Obergrenze erscheint im Klartext' {
        $global:HUSecFx['userType'] = @([pscustomobject]@{ id = 'GUEST1'; displayName = 'Gast' })
        $global:HUSecFx['groupTypes'] = @(1..5001 | ForEach-Object { [pscustomobject]@{ id = "g$_"; displayName = 'x'; owners = @() } })
        $r = Run 'C06'; $r.Status | Should -Be 'NichtPruefbar'; $r.Detail | Should -Match 'mehr als 5000'
    }
    It 'C06: ohne Gaeste OK ohne Gruppenabruf' {
        $global:HUSecFx['userType'] = @()
        $global:HUSecFx['groupTypes'] = Fail 500
        (Run 'C06').Status | Should -Be 'OK'
    }
    It 'C07/C08: Standard (keine Einstellung) - alle duerfen anlegen, Gaeste keine Besitzer' {
        $global:HUSecFx['/groupSettings'] = @()
        $r = Run 'C07'; $r.Status | Should -Be 'Abweichung'; $r.Detail | Should -Match 'Standard'
        (Run 'C08').Status | Should -Be 'OK'
    }
    It 'C07/C08: Anlegen nur fuer eine Gruppe, Gaeste als Besitzer erlaubt' {
        $global:HUSecFx['/groupSettings'] = @([pscustomobject]@{ templateId = '62375ab9-6b52-47ed-826b-58e47e0e304b'; values = @(
                    [pscustomobject]@{ name = 'EnableGroupCreation'; value = 'False' },
                    [pscustomobject]@{ name = 'GroupCreationAllowedGroupId'; value = '11111111-1111-1111-1111-111111111111' },
                    [pscustomobject]@{ name = 'AllowGuestsToBeGroupOwner'; value = 'True' }) })
        $global:HUSecFx['?$select=displayName'] = [pscustomobject]@{ displayName = 'Lehrkraefte' }
        $r = Run 'C07'; $r.Status | Should -Be 'OK'; $r.Detail | Should -Match 'Lehrkraefte'
        (Run 'C08').Status | Should -Be 'Abweichung'
    }
}

Describe 'Ampel folgt der Auswahl (Grad, Bereich, Suchtext)' {
    It 'Ampel nutzt die Auswahl ohne Status-Filter' {
        $sec = Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Functions\UI-Security.ps1') -Raw
        $sec | Should -Match 'Get-HUSecVisibleRows -NoStatusFilter'
        $sec | Should -Match 'Ampel \(nur Auswahl'
    }
    It 'Bereiche per Haken (ausgeblendete werden gespeichert), Regel-Spalte zeigt die Anzahl' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $sec = Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Security.ps1') -Raw
        $x = Get-Content -LiteralPath (Join-Path $root 'XAML\MainWindow.xaml') -Raw
        $x | Should -Match 'x:Name="popSecArea"'
        $x | Should -Not -Match 'cmbSecArea'
        # ein einzelnes Paar in @(@(...)) wird von PowerShell flachgeklopft (Startfehler 2.2.6-Test)
        $sec | Should -Not -Match "foreach \(\`$pair in @\(@\('[^']+', '[^']+'\)\)\)"
        $sec | Should -Match "Get-HUStateValue 'secAreaOff'"
        $sec | Should -Match 'Regel \(\$\(@\(Get-HUSecVisibleRows\)\.Count\)\)'
    }
}
