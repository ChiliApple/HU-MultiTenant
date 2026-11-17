#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer die Ansicht "Einfach" (Grundschutz) und das Aenderungsprotokoll (L-Regeln) in Core\HU.SecCatalog.psm1.
.NOTES
    Ohne Netzwerk: Invoke-HUSecFetch wird ersetzt, die Daten stehen in $global:HUSecEfx. Nur kuenstliche Testdaten.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:TestAppData = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-SecE-Test-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $script:TestAppData -ItemType Directory -Force | Out-Null
    $script:OldAppData = $env:APPDATA
    $env:APPDATA = $script:TestAppData
    Import-Module (Join-Path $root 'Core\HU.SecCatalog.psm1') -Force -DisableNameChecking

    Mock -ModuleName HU.SecCatalog Get-HUSecTokenRoles { return @() }
    Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
        param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
        [void]$global:HUSecEeps.Add("$Endpoint")
        foreach ($k in $global:HUSecEfx.Keys) { if ($Endpoint -like "*$k*") { return $global:HUSecEfx[$k] } }
        # Standard: keine rollenzuweisbaren Gruppen (L01 fragt sie seit 2.6.18 ab)
        if ($Endpoint -like '*isAssignableToRole*') { return @() }
        throw 'nicht vorbereitet'
    }

    function script:Ev([string]$Cat, [string]$Act, [string]$When = '2026-11-10T08:00:00Z', [string]$User = 'admin@contoso.test', [string]$AppId = '', [string]$TargetId = 't1', [string]$TargetName = 'Ziel 1', [object[]]$Props = @()) {
        $by = [pscustomobject]@{
            user = $(if ($User) { [pscustomobject]@{ userPrincipalName = $User } } else { $null })
            app  = $(if ($AppId) { [pscustomobject]@{ appId = $AppId; displayName = 'Portal-App' } } else { $null })
        }
        [pscustomobject]@{ category = $Cat; activityDisplayName = $Act; activityDateTime = $When; result = 'success'; initiatedBy = $by
            targetResources = @([pscustomobject]@{ id = $TargetId; displayName = $TargetName; userPrincipalName = ''; modifiedProperties = @($Props) }) }
    }
    function script:Res([string]$Id, [string]$Status, [string]$Tenant = 'T1', $Count = $null) {
        [pscustomobject]@{ RuleId = $Id; Tenant = $Tenant; Status = $Status; Reason = ''; Count = $Count; Detail = ''; Complete = $true; ExceptionId = '' }
    }
    $script:Dash = [string][char]0x2013
}

AfterAll {
    $env:APPDATA = $script:OldAppData
    Remove-Item -LiteralPath $script:TestAppData -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name HUSecEfx, HUSecEeps -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Grundschutz-Liste (Get-HUSecBasicIds)' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path $script:TestAppData 'HU-MultiTenant') -Recurse -Force -ErrorAction SilentlyContinue }

    It 'liefert ohne Sollwert die 15 Standardregeln, alle im Katalog vorhanden' {
        $ids = @(Get-HUSecBasicIds)
        $ids.Count | Should -Be 15
        $known = @(Get-HUSecRules | ForEach-Object { $_.Id })
        foreach ($i in $ids) { $known | Should -Contain $i }
        $ids | Should -Contain 'V5'
        $ids | Should -Contain 'E11'
    }

    It 'nimmt den Sollwert Katalog.basic, auch mit Regeln des Mindeststandards' {
        @(Save-HUSecBaselineEdit -Values @{ 'Katalog.basic' = 'v5, A02 E01' }).Count | Should -Be 0
        @(Get-HUSecBasicIds) | Should -Be @('A02', 'E01', 'V5')
    }

    It 'lehnt unbekannte Nummern beim Speichern ab' {
        $err = @(Save-HUSecBaselineEdit -Values @{ 'Katalog.basic' = 'V5, X99' })
        $err.Count | Should -Be 1
        $err[0] | Should -Match 'X99'
    }

    It 'faellt bei leerem Sollwert auf den Standard zurueck' {
        @(Save-HUSecBaselineEdit -Values @{ 'Katalog.basic' = 'A02' }).Count | Should -Be 0
        @(Save-HUSecBaselineEdit -Values @{ 'Katalog.basic' = '' }).Count | Should -Be 0
        @(Get-HUSecBasicIds).Count | Should -Be 15
    }
}

Describe 'Fortschritt Einfach (Get-HUSecBasicLight)' {
    It 'ist gruen, wenn alle gepruefte Grundschutz-Regeln erfuellt sind; nicht pruefbar zaehlt nur in Total' {
        $rows = @((Res 'V5' 'OK'), (Res 'A04' 'OK'), (Res 'A08' 'NichtPruefbar'), (Res 'A19' 'Abweichung' -Count 2))
        $l = Get-HUSecBasicLight -Results $rows -Key 'T1' -Ids @('V5', 'A04', 'A08')
        $l.Color | Should -Be 'Gruen'
        $l.Ok | Should -Be 2
        $l.Total | Should -Be 3
        $l.NotCheckable | Should -Be 1
    }

    It 'ist rot, sobald eine kritische Regel offen ist, auch bei nur einer Abweichung' {
        $rows = @((Res 'V5' 'Abweichung'), (Res 'A04' 'OK'))
        (Get-HUSecBasicLight -Results $rows -Key 'T1' -Ids @('V5', 'A04')).Color | Should -Be 'Rot'
    }

    It 'ist gelb bei offener Regel ohne kritischen Grad' {
        $rows = @((Res 'V5' 'OK'), (Res 'A04' 'Abweichung'))
        (Get-HUSecBasicLight -Results $rows -Key 'T1' -Ids @('V5', 'A04')).Color | Should -Be 'Gelb'
    }

    It 'zaehlt Fehler in Total, aber nicht als erfuellt' {
        $rows = @((Res 'V5' 'OK'), (Res 'A04' 'Fehler'))
        $l = Get-HUSecBasicLight -Results $rows -Key 'T1' -Ids @('V5', 'A04')
        $l.Total | Should -Be 2
        $l.Ok | Should -Be 1
        $l.Color | Should -Be 'Gelb'
    }

    It 'ist nie gruen, wenn eine kritische Regel nicht pruefbar ist (2.6.18)' {
        $rows = @((Res 'V5' 'NichtPruefbar'), (Res 'A04' 'OK'))
        $l = Get-HUSecBasicLight -Results $rows -Key 'T1' -Ids @('V5', 'A04')
        $l.Color | Should -Be 'Gelb'
        $l.CriticalNotCheckable | Should -Be 1
        (Get-HUSecBasicLight -Results @((Res 'V5' 'NichtPruefbar' -Tenant 'T2'), (Res 'A04' 'OK')) -Key 'T1' -Ids @('V5', 'A04')).Color | Should -Be 'Gruen'
    }

    It 'ist grau ohne gepruefte Regel und zaehlt Ausnahmen als erfuellt' {
        (Get-HUSecBasicLight -Results @((Res 'V5' 'NichtPruefbar')) -Key 'T1' -Ids @('V5')).Color | Should -Be 'Grau'
        (Get-HUSecBasicLight -Results @((Res 'V5' 'Ausnahme')) -Key 'T1' -Ids @('V5')).Ok | Should -Be 1
    }
}

Describe 'Aenderungsprotokoll: Zuordnung (Get-HUSecAuditKind)' {
    It 'erkennt Rollenvergaben, aber keine PIM-Aktivierung und kein Entfernen' {
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add member to role') | Should -Be 'Rolle'
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add eligible member to role') | Should -Be 'Rolle'
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add member to role completed (PIM activation)') | Should -Be ''
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Remove member from role') | Should -Be ''
    }

    It 'erkennt Secrets und Zertifikate trotz Gedankenstrich und Leerzeichen am Ende' {
        Get-HUSecAuditKind (Ev 'ApplicationManagement' "Update application $($script:Dash) Certificates and secrets management ") | Should -Be 'Zugangsdaten'
        Get-HUSecAuditKind (Ev 'ApplicationManagement' 'Add service principal credentials') | Should -Be 'Zugangsdaten'
    }

    It 'erkennt App-Rechte, Domaenen und bedingten Zugriff; Alltagsereignisse sind nicht heikel' {
        Get-HUSecAuditKind (Ev 'ApplicationManagement' 'Consent to application') | Should -Be 'AppRechte'
        Get-HUSecAuditKind (Ev 'ApplicationManagement' 'Add app role assignment to service principal') | Should -Be 'AppRechte'
        Get-HUSecAuditKind (Ev 'DirectoryManagement' 'Set domain authentication') | Should -Be 'Domaene'
        Get-HUSecAuditKind (Ev 'DirectoryManagement' 'Set Company Information') | Should -Be ''
        Get-HUSecAuditKind (Ev 'Policy' 'Update conditional access policy') | Should -Be 'CA'
        Get-HUSecAuditKind (Ev 'Policy' 'Update policy') | Should -Be ''
        Get-HUSecAuditKind (Ev 'UserManagement' 'Update user') | Should -Be ''
    }

    It 'beachtet die Kategorie (gleicher Name in falscher Kategorie zaehlt nicht)' {
        Get-HUSecAuditKind (Ev 'Policy' 'Add member to role') | Should -Be ''
    }
}

Describe 'Aenderungsprotokoll: Listenzeile und Auswertung' {
    It 'kennzeichnet Eintraege dieser App (nur App, kein Benutzer) als Eigen' {
        $r = ConvertTo-HUSecAuditRow (Ev 'Policy' 'Add conditional access policy' -User '' -AppId 'OWN-APP') 'own-app'
        $r.Eigen | Should -BeTrue
        $r.Von | Should -Be 'HU-MultiTenant'
    }

    It 'nennt bei Portal-Aenderungen den Benutzer, nicht die Portal-App' {
        $r = ConvertTo-HUSecAuditRow (Ev 'Policy' 'Update conditional access policy' -User 'admin@contoso.test' -AppId 'portal') 'own-app'
        $r.Eigen | Should -BeFalse
        $r.Von | Should -Be 'admin@contoso.test'
    }

    It 'zeigt Microsoft (System) ohne Ausloeser und den Rollennamen vor dem Ziel' {
        $p = @([pscustomobject]@{ displayName = 'Role.DisplayName'; newValue = '"Global Administrator"' })
        $r = ConvertTo-HUSecAuditRow (Ev 'RoleManagement' 'Add member to role' -User '' -TargetName 'Test Konto' -Props $p) ''
        $r.Von | Should -Be 'Microsoft (System)'
        $r.Ziel | Should -Be 'Test Konto (Global Administrator)'
        $r.Art | Should -Be 'Admin-Rolle vergeben'
    }

    It 'erkennt eigene Eintraege auch nur ueber die servicePrincipalId und nennt sonst den App-Namen' {
        $e = Ev 'ApplicationManagement' 'Add service principal credentials' -User ''
        $e.initiatedBy.app = [pscustomobject]@{ appId = $null; servicePrincipalId = 'OWN-SP'; displayName = 'HU-MultiTenant' }
        $r = ConvertTo-HUSecAuditRow $e 'own-app' 'own-sp'
        $r.Eigen | Should -BeTrue
        $r2 = ConvertTo-HUSecAuditRow $e 'own-app' 'anderer-sp'
        $r2.Eigen | Should -BeFalse
        $r2.Von | Should -Be 'App: HU-MultiTenant'
    }

    It 'zaehlt ein fremdes Secret an der eigenen App (Benutzer als Ausloeser) nicht als eigen' {
        $e = Ev 'ApplicationManagement' 'Add service principal credentials' -User 'jemand@contoso.test' -TargetId 'own-app-object'
        (ConvertTo-HUSecAuditRow $e 'own-app' 'own-sp').Eigen | Should -BeFalse
    }

    It 'zaehlt PIM-Zuweisungen, aber keine PIM-Aktivierungen' {
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add member to role in PIM completed (permanent)') | Should -Be 'Rolle'
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add eligible member to role in PIM completed (permanent)') | Should -Be 'Rolle'
        Get-HUSecAuditKind (Ev 'RoleManagement' 'Add member to role requested (PIM activation)') | Should -Be ''
    }

    It 'zaehlt geloeschte Secrets nicht (gleicher Ereignisname wie beim Hinzufuegen)' {
        $act = "Update application $($script:Dash) Certificates and secrets management "
        $kd = { param($o, $n) @([pscustomobject]@{ displayName = 'KeyDescription'; oldValue = $o; newValue = $n }) }
        $add = Ev 'ApplicationManagement' $act -Props (& $kd '["[KeyIdentifier=1,KeyType=Password]"]' '["[KeyIdentifier=1,KeyType=Password]","[KeyIdentifier=2,KeyType=Password]"]')
        $del = Ev 'ApplicationManagement' $act -Props (& $kd '["[KeyIdentifier=1,KeyType=Password]","[KeyIdentifier=2,KeyType=Password]"]' '["[KeyIdentifier=1,KeyType=Password]"]')
        Get-HUSecAuditKind $add | Should -Be 'Zugangsdaten'
        Get-HUSecAuditKind $del | Should -Be ''
        Get-HUSecAuditKind (Ev 'ApplicationManagement' $act) | Should -Be 'Zugangsdaten'
    }

    It 'zaehlt einen Austausch im selben Ereignis (einer weg, einer neu) als neues Secret (2.6.18)' {
        $act = "Update application $($script:Dash) Certificates and secrets management "
        $kd = { param($o, $n) @([pscustomobject]@{ displayName = 'KeyDescription'; oldValue = $o; newValue = $n }) }
        $swap = Ev 'ApplicationManagement' $act -Props (& $kd '["[KeyIdentifier=aaaa-1,KeyType=Password,KeyUsage=Verify,DisplayName=alt]"]' '["[KeyIdentifier=bbbb-2,KeyType=Password,KeyUsage=Verify,DisplayName=neu]"]')
        Get-HUSecAuditKind $swap | Should -Be 'Zugangsdaten'
        $same = Ev 'ApplicationManagement' $act -Props (& $kd '["[KeyIdentifier=AAAA-1,KeyType=Password]"]' '["[KeyIdentifier=aaaa-1,KeyType=Password]"]')
        Get-HUSecAuditKind $same | Should -Be ''
    }

    It 'nimmt bei App-Rechten die App (Stelle 1) statt der Ressource (Stelle 0) und ergaenzt fehlende Namen' {
        $res = { param($p, $v) [pscustomobject]@{ id = 'graph'; displayName = 'Microsoft Graph'; userPrincipalName = ''; modifiedProperties = @([pscustomobject]@{ displayName = $p; newValue = "`"$v`"" }) } }
        $app = { param($id, $n) [pscustomobject]@{ id = $id; displayName = $n; userPrincipalName = ''; modifiedProperties = @() } }
        $e1 = Ev 'ApplicationManagement' 'Add app role assignment to service principal' -When '2026-11-10T08:00:00Z'; $e1.targetResources = @((& $res 'AppRole.Value' 'User.Read.All'), (& $app 'sp1' 'App Eins'))
        $e2 = Ev 'ApplicationManagement' 'Add delegated permission grant' -When '2026-11-11T08:00:00Z'; $e2.targetResources = @((& $res 'DelegatedPermissionGrant.Scope' 'Mail.Read'), (& $app 'sp2' ''))
        $e3 = Ev 'ApplicationManagement' 'Consent to application' -When '2026-11-11T08:00:01Z'; $e3.targetResources = @((& $app 'sp2' 'App Zwei'))
        $fact = [pscustomobject]@{ OwnAppId = ''; Days = 30; Rows = @($e1, $e2, $e3) }
        $rows = @(Get-HUSecAuditRows $fact @('AppRechte'))
        @($rows | Where-Object { $_.Ziel -eq 'App Eins: User.Read.All (Microsoft Graph)' }).Count | Should -Be 1
        @($rows | Where-Object { $_.Ziel -eq 'App Zwei: Mail.Read (Microsoft Graph)' }).Count | Should -Be 1
        (Get-HUSecAuditEval $fact @('AppRechte') 'App(s)').Count | Should -Be 2
    }

    It 'nimmt den App-Namen aus den Eigenschaften der Ressource, wenn Microsoft als Namen nur die App-ID eintraegt' {
        $res = [pscustomobject]@{ id = 'graph'; displayName = 'Microsoft Graph'; userPrincipalName = ''; modifiedProperties = @(
                [pscustomobject]@{ displayName = 'AppRole.Value'; newValue = '"Application.Read.All"' },
                [pscustomobject]@{ displayName = 'ServicePrincipal.DisplayName'; newValue = '"Test-App Upload"' }) }
        $app = [pscustomobject]@{ id = 'sp9'; displayName = '11111111-2222-3333-4444-555555555555'; userPrincipalName = ''; modifiedProperties = @() }
        $e = Ev 'ApplicationManagement' 'Add app role assignment to service principal'; $e.targetResources = @($res, $app)
        (ConvertTo-HUSecAuditRow $e '').Ziel | Should -Be 'Test-App Upload: Application.Read.All (Microsoft Graph)'
        $res.modifiedProperties = @($res.modifiedProperties[0])
        $fact = [pscustomobject]@{ OwnAppId = ''; Days = 30; Rows = @($e) }
        @(Get-HUSecAuditRows $fact)[0].Ziel | Should -Be '(Name unbekannt): Application.Read.All (Microsoft Graph)'
    }

    It 'liefert den Zeitpunkt des neuesten gezaehlten Ereignisses (ohne eigene)' {
        $fact = [pscustomobject]@{ OwnAppId = 'own-app'; Days = 30; Rows = @(
                (Ev 'Policy' 'Update conditional access policy' -When '2026-11-05T08:00:00Z'),
                (Ev 'Policy' 'Delete conditional access policy' -When '2026-11-09T08:00:00Z'),
                (Ev 'Policy' 'Add conditional access policy' -When '2026-11-12T08:00:00Z' -User '' -AppId 'OWN-APP')) }
        $e = Get-HUSecAuditEval $fact @('CA') 'Richtlinie(n)'
        "$($e.Latest)" | Should -Match '^2026-11-09T08:00:00'
    }

    It 'zaehlt betroffene Ziele statt Ereignisse und laesst eigene Eintraege weg' {
        $fact = [pscustomobject]@{ OwnAppId = 'own-app'; Days = 30; Rows = @(
                (Ev 'ApplicationManagement' 'Add app role assignment to service principal' -TargetId 'app1'),
                (Ev 'ApplicationManagement' 'Add app role assignment to service principal' -TargetId 'app1'),
                (Ev 'ApplicationManagement' 'Consent to application' -TargetId 'app2'),
                (Ev 'ApplicationManagement' 'Add app role assignment to service principal' -TargetId 'app3' -User '' -AppId 'OWN-APP'),
                (Ev 'UserManagement' 'Update user')) }
        $e = Get-HUSecAuditEval $fact @('AppRechte') 'App(s)'
        $e.Status | Should -Be 'Abweichung'
        $e.Count | Should -Be 2
        $e.Detail | Should -Match '3 Ereignis\(se\) zu 2 App\(s\) in 30 Tagen; 1 durch HU-MultiTenant'
        @(Get-HUSecAuditRows $fact @('AppRechte')).Count | Should -Be 4
    }

    It 'meldet ohne Ereignis OK und mit -Info nur einen Hinweis' {
        $fact = [pscustomobject]@{ OwnAppId = ''; Days = 7; Rows = @((Ev 'Policy' 'Update conditional access policy' -TargetId 'p1')) }
        (Get-HUSecAuditEval $fact @('Rolle') 'Konto/Konten').Status | Should -Be 'OK'
        $i = Get-HUSecAuditEval $fact @('CA') 'Richtlinie(n)' -Info
        $i.Status | Should -Be 'Info'
        $i.Count | Should -Be 1
        $i.Detail | Should -Match 'in 7 Tagen'
    }

    It 'sortiert die Liste neueste zuerst' {
        $fact = [pscustomobject]@{ OwnAppId = ''; Days = 30; Rows = @(
                (Ev 'Policy' 'Update conditional access policy' -When '2026-11-01T08:00:00Z'),
                (Ev 'Policy' 'Delete conditional access policy' -When '2026-11-12T08:00:00Z')) }
        @(Get-HUSecAuditRows $fact)[0].Ereignis | Should -Be 'Delete conditional access policy'
    }
}

Describe 'Aenderungsprotokoll im Katalog (L01-L05)' {
    BeforeEach {
        $global:HUSecEeps = New-Object System.Collections.Generic.List[string]
        $global:HUSecEfx = @{
            'subscribedSkus' = , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })
            "'RoleManagement'" = @((Ev 'RoleManagement' 'Add member to role' -TargetId 'u1'))
            "'DirectoryManagement'" = @((Ev 'DirectoryManagement' 'Set Company Information'))
            "'ApplicationManagement'" = @((Ev 'ApplicationManagement' "Update application $($script:Dash) Certificates and secrets management " -User '' -AppId 'OWN-APP' -TargetId 'a1'))
            "'Policy'" = @((Ev 'Policy' 'Update conditional access policy' -TargetId 'p1'), (Ev 'Policy' 'Delete conditional access policy' -TargetId 'p2'))
        }
        $script:Set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'OWN-APP' }) }
    }

    It 'fragt je Kategorie gefiltert ab und wertet alle fuenf Regeln aus' {
        $res = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01', 'L02', 'L03', 'L04', 'L05'))
        $by = @{}; foreach ($r in $res) { $by[$r.RuleId] = $r }
        $by['L01'].Status | Should -Be 'Abweichung'
        $by['L01'].Count | Should -Be 1
        $by['L02'].Status | Should -Be 'OK'
        $by['L03'].Status | Should -Be 'Info'
        $by['L03'].Detail | Should -Match '1 durch HU-MultiTenant'
        $by['L04'].Status | Should -Be 'Info'
        $by['L05'].Status | Should -Be 'Info'
        $by['L05'].Count | Should -Be 2
        $aud = @($global:HUSecEeps | Where-Object { $_ -like '*directoryAudits*' })
        $aud.Count | Should -Be 4
        foreach ($e in $aud) { $e | Should -Match 'activityDateTime%20ge%20.*category%20eq%20' }
    }

    It 'nennt ohne P1 nur 7 Tage (Aufbewahrung laut Microsoft)' {
        $global:HUSecEfx['subscribedSkus'] = , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }) })
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $r.Detail | Should -Match 'in 7 Tagen'
    }

    It 'liefert die Gesamtliste mit Tenant-Spalte ohne Hilfsfelder' {
        $rows = @(Get-HUSecChanges -TenantKey 'T1' -Settings $script:Set)
        $rows.Count | Should -Be 4
        # __Detail ist versteckt (Detailfenster), sichtbar bleiben nur diese Spalten
        ($rows[0].PSObject.Properties.Name -join ',') | Should -Be 'Zeit,Tenant,Art,Ereignis,Ziel,Von,Ergebnis,__Detail'
        @($rows | Where-Object { $_.Von -eq 'HU-MultiTenant' }).Count | Should -Be 1
    }

    It 'meldet ein fehlendes Recht als nicht pruefbar' {
        Mock -ModuleName HU.SecCatalog Get-HUSecTokenRoles { return @('Policy.Read.All') }
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $r.Status | Should -Be 'NichtPruefbar'
        $r.Reason | Should -Be 'Recht'
    }

    It 'haben eine Erklaerung, eine Detailliste mit Personendaten (kein Export) und eine Anleitung' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $fix = Get-Content (Join-Path $root 'Docs\Behebung.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($id in 'L01', 'L02', 'L03', 'L04', 'L05') {
            Get-HUSecWhy $id | Should -Not -BeNullOrEmpty
            Test-HUSecItemsExport $id | Should -BeFalse
            Get-HUSecItemsLabel $id | Should -Be 'Ereignisse'
            $fix.rules.PSObject.Properties[$id] | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Soll-Vergleich bei gleitendem Zeitraum (Rolling)' {
    BeforeAll {
        $script:Ref = [pscustomobject]@{ time = '2026-11-01T00:00:00Z'; rows = @(
                [pscustomobject]@{ ruleId = 'L02'; tenant = 'T1'; status = 'Abweichung'; count = 12 },
                [pscustomobject]@{ ruleId = 'L01'; tenant = 'T1'; status = 'OK'; count = 0 },
                [pscustomobject]@{ ruleId = 'A19'; tenant = 'T1'; status = 'Abweichung'; count = 3 }) }
        function script:ResL([string]$Id, [string]$Status, $Count, [string]$Latest) { $r = Res $Id $Status -Count $Count; $r | Add-Member -NotePropertyName Latest -NotePropertyValue $Latest; $r }
    }

    It 'meldet ein neues Ereignis nach dem Soll-Zeitpunkt, auch wenn die Zahl gesunken ist' {
        $c = @((Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 5 '2026-11-10T08:00:00.0000000Z')) -Reference $script:Ref).Changes)
        $c.Count | Should -Be 1
        $c[0].Kind | Should -Be 'Neu'
        $c[0].Worse | Should -BeTrue
    }

    It 'meldet nichts, wenn das neueste Ereignis vor dem Soll liegt, auch bei geaenderter Zahl' {
        @((Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 4 '2026-10-20T08:00:00.0000000Z')) -Reference $script:Ref).Changes).Count | Should -Be 0
    }

    It 'meldet die erste Rollenvergabe nach einem ruhigen Soll und nichts bei Rueckkehr zu OK oder Ausnahme' {
        @((Compare-HUSecReference -Results @((ResL 'L01' 'Abweichung' 1 '2026-11-03T08:00:00.0000000Z')) -Reference $script:Ref).Changes).Count | Should -Be 1
        @((Compare-HUSecReference -Results @((ResL 'L02' 'OK' 0 '')) -Reference $script:Ref).Changes).Count | Should -Be 0
        @((Compare-HUSecReference -Results @((ResL 'L02' 'Ausnahme' 7 '2026-11-10T08:00:00.0000000Z')) -Reference $script:Ref).Changes).Count | Should -Be 0
    }

    It 'meldet ein Ereignis zwischen Pruefen und Soll speichern (Schwelle = neuestes Ereignis im Soll)' {
        $ref = [pscustomobject]@{ time = '2026-11-15T00:00:00Z'; rows = @([pscustomobject]@{ ruleId = 'L02'; tenant = 'T1'; status = 'Abweichung'; count = 1; latest = '2026-11-10T00:00:00.0000000Z' }) }
        @((Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 2 '2026-11-12T08:00:00.0000000Z')) -Reference $ref).Changes).Count | Should -Be 1
        @((Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 1 '2026-11-10T00:00:00.0000000Z')) -Reference $ref).Changes).Count | Should -Be 0
        $quiet = [pscustomobject]@{ time = '2026-11-15T00:00:00Z'; rows = @([pscustomobject]@{ ruleId = 'L01'; tenant = 'T1'; status = 'OK'; count = 0; latest = '' }) }
        @((Compare-HUSecReference -Results @((ResL 'L01' 'Abweichung' 1 '2026-11-14T08:00:00.0000000Z')) -Reference $quiet).Changes).Count | Should -Be 1
    }

    It 'speichert im Soll das neueste Ereignis nur fuer Regeln mit Zeitpunkt' {
        $f = Save-HUSecReference -Results @((ResL 'L01' 'OK' 0 ''), (ResL 'L02' 'Abweichung' 1 '2026-11-10T00:00:00.0000000Z'), (Res 'A19' 'OK'))
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $byId = @{}; foreach ($x in $j.rows) { $byId["$($x.ruleId)"] = $x }
        [bool]$byId['L01'].PSObject.Properties['latest'] | Should -BeTrue
        "$($byId['L01'].latest)" | Should -Be ''
        # PS 7 liest den Zeittext als Datum zurueck, 5.1 als Text - beides muss dasselbe UTC-Datum ergeben
        ([datetime]$byId['L02'].latest).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-11-10 00:00'
        $cmp = Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 2 '2026-11-12T08:00:00.0000000Z')) -Reference (Get-HUSecReference)
        @($cmp.Changes).Count | Should -Be 1
        [bool]$byId['A19'].PSObject.Properties['latest'] | Should -BeFalse
    }

    It 'meldet sinkende Zahlen bei normalen Regeln weiterhin' {
        @((Compare-HUSecReference -Results @((Res 'A19' 'Abweichung' -Count 1)) -Reference $script:Ref).Changes).Count | Should -Be 1
    }

    It 'meldet die Hinweis-Regeln L03 bis L05 nie und zaehlt sie nicht in der Ampel' {
        $ref = [pscustomobject]@{ time = '2026-11-01T00:00:00Z'; rows = @([pscustomobject]@{ ruleId = 'L04'; tenant = 'T1'; status = 'Info'; count = 3 }) }
        @((Compare-HUSecReference -Results @((ResL 'L04' 'Info' 9 '2026-11-10T08:00:00.0000000Z')) -Reference $ref).Changes).Count | Should -Be 0
        foreach ($id in 'L03', 'L04', 'L05') { (@(Get-HUSecRules | Where-Object { $_.Id -eq $id })[0]).Sev | Should -Be 'Niedrig' }
        $l = Get-HUSecLight -Results @((Res 'L03' 'Info' -Count 2), (Res 'L04' 'Info' -Count 5), (Res 'L01' 'OK')) -Key 'T1'
        $l.Deviations | Should -Be 0
        $l.Color | Should -Be 'Gruen'
    }

    It 'nennt das neue Ereignis in der Teams-Karte verstaendlich' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'Core\HU.Notify.psm1') -Force -DisableNameChecking
        $nf = & (Get-Module HU.Notify) { $script:NotifyFile }
        if (-not "$nf".StartsWith($script:TestAppData)) { throw "Teams-Ziele zeigen nicht in den Testordner ($nf) - Abbruch" }
        Import-Module (Join-Path $root 'Core\HU.TeamsJobs.psm1') -Force -DisableNameChecking
        $cmp = Compare-HUSecReference -Results @((ResL 'L02' 'Abweichung' 5 '2026-11-10T08:00:00.0000000Z')) -Reference $script:Ref
        $spec = New-HUSecDriftCardSpec -Compare $cmp -Names @{ T1 = 'Schule 1' }
        ($spec.Rows | ForEach-Object { $_.Text }) -join ' ' | Should -Match 'L02 .*neues Ereignis seit dem Soll-Stand, jetzt 5'
        Remove-Module HU.TeamsJobs, HU.Notify -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Detailliste der L-Regeln' {
    It 'steht neueste zuerst' {
        $global:HUSecEeps = New-Object System.Collections.Generic.List[string]
        $global:HUSecEfx = @{
            'subscribedSkus' = , @()
            "'RoleManagement'" = @(); "'DirectoryManagement'" = @(); "'ApplicationManagement'" = @()
            "'Policy'" = @((Ev 'Policy' 'Update conditional access policy' -When '2026-11-01T08:00:00Z'), (Ev 'Policy' 'Delete conditional access policy' -When '2026-11-12T08:00:00Z'))
        }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'x' }) }
        @(Get-HUSecItems -TenantKey 'T1' -Settings $set -RuleId 'L05')[0].Ereignis | Should -Be 'Delete conditional access policy'
    }

    It 'liefert Details nur mit -KeepDetail (Remote FB und MCP bekommen sie nie)' {
        $global:HUSecEeps = New-Object System.Collections.Generic.List[string]
        $global:HUSecEfx = @{ 'subscribedSkus' = , @(); "'RoleManagement'" = @(); "'DirectoryManagement'" = @(); "'ApplicationManagement'" = @()
            "'Policy'" = @((Ev 'Policy' 'Update conditional access policy')) }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'x' }) }
        $plain = @(Get-HUSecItems -TenantKey 'T1' -Settings $set -RuleId 'L05')
        @($plain[0].PSObject.Properties.Name | Where-Object { $_ -like '__*' }).Count | Should -Be 0
        $ui = @(Get-HUSecItems -TenantKey 'T1' -Settings $set -RuleId 'L05' -KeepDetail)
        @($ui[0].__Detail).Count | Should -BeGreaterThan 3
        @(Get-HUSecChanges -TenantKey 'T1' -Settings $set)[0].__Detail | Should -Not -BeNullOrEmpty
    }
}

Describe 'Detailfenster je Ereignis' {
    It 'macht Text, JSON-Text und doppelt kodiertes JSON flach' {
        (ConvertFrom-HUSecAuditValue '"Global Administrator"')[''] | Should -Be 'Global Administrator'
        ((ConvertFrom-HUSecAuditValue '["a","b"]')[''] -join ', ') | Should -Be 'a, b'
        (ConvertFrom-HUSecAuditValue 'kein json')[''] | Should -Be 'kein json'
        @((ConvertFrom-HUSecAuditValue '').Keys).Count | Should -Be 0
        $pol = '{"displayName":"100 - MFA","state":"enabled","conditions":{"users":{"excludeUsers":["u1","u2"]}}}'
        $f = ConvertFrom-HUSecAuditValue (($pol | ConvertTo-Json))   # doppelt kodiert wie bei Microsoft
        $f['state'] | Should -Be 'enabled'
        ($f['conditions.users.excludeUsers'] -join ', ') | Should -Be 'u1, u2'
    }

    It 'laesst Texte wie Zahlen, Wahrheitswerte und Telefonnummern unveraendert (auch in PS 7)' {
        (ConvertFrom-HUSecAuditValue '0012')[''] | Should -BeExactly '0012'
        (ConvertFrom-HUSecAuditValue '"0012"')[''] | Should -BeExactly '0012'
        (ConvertFrom-HUSecAuditValue 'true')[''] | Should -BeExactly 'true'
        (ConvertFrom-HUSecAuditValue '"1e5"')[''] | Should -BeExactly '1e5'
        @((ConvertFrom-HUSecAuditValue '["0664123456"]')[''])[0] | Should -BeExactly '0664123456'
        (ConvertFrom-HUSecAuditValue '{"a":"2026-11-17T10:00:00"}')['a'] | Should -Match '^2026-11-17T10:00:00'
    }

    It 'zeigt Aenderungen der Gross- und Kleinschreibung und Listen je Eintrag als neu oder entfernt' {
        $e = Ev 'ApplicationManagement' 'Update application' -Props @([pscustomobject]@{ displayName = 'DisplayName'; oldValue = '"Abc"'; newValue = '"abc"' })
        @(ConvertTo-HUSecAuditDetail $e | Where-Object { $_.Feld -eq 'DisplayName' }).Count | Should -Be 1
        $long = 'x' * 150
        $old = (@(1..5 | ForEach-Object { "[KeyIdentifier=$_,DisplayName=$long]" }) | ConvertTo-Json -Compress)
        $new = (@(1..6 | ForEach-Object { "[KeyIdentifier=$_,DisplayName=$long]" }) | ConvertTo-Json -Compress)
        $k = Ev 'ApplicationManagement' "Update application $($script:Dash) Certificates and secrets management " -Props @([pscustomobject]@{ displayName = 'KeyDescription'; oldValue = $old; newValue = $new })
        $rows = @(ConvertTo-HUSecAuditDetail $k | Where-Object { $_.Feld -like 'KeyDescription*' })
        $rows.Count | Should -Be 1
        $rows[0].Feld | Should -Be 'KeyDescription (neu)'
        $rows[0].Nachher | Should -Match '^\[KeyIdentifier=6,'
    }

    It 'berechnet Details nur auf Anforderung (Regelauswertung und Teams-Pruefung ohne)' {
        $fact = [pscustomobject]@{ OwnAppId = ''; Days = 30; Rows = @((Ev 'Policy' 'Update conditional access policy'), (Ev 'RoleManagement' 'Add member to role')) }
        @(@(Get-HUSecAuditRows $fact) | Where-Object { @($_.__Detail).Count }).Count | Should -Be 0
        $w = @(Get-HUSecAuditRows $fact @('CA') -WithDetail)
        @($w[0].__Detail).Count | Should -BeGreaterThan 3
    }

    It 'zeigt Ausloeser mit IP, alle Bloecke und bei Aenderungen nur abweichende Einstellungen' {
        $old = '{"displayName":"100 - MFA","state":"enabledForReportingButNotEnforced","conditions":{"users":{"excludeUsers":["u1"]}}}'
        $new = '{"displayName":"100 - MFA","state":"enabled","conditions":{"users":{"excludeUsers":["u1"]}}}'
        $p = @([pscustomobject]@{ displayName = 'ConditionalAccessPolicy'; oldValue = ($old | ConvertTo-Json); newValue = ($new | ConvertTo-Json) })
        $e = Ev 'Policy' 'Update conditional access policy' -Props $p
        $e.initiatedBy.user | Add-Member -NotePropertyName ipAddress -NotePropertyValue '192.0.2.10'
        $e | Add-Member -NotePropertyName correlationId -NotePropertyValue 'c-1'
        $e | Add-Member -NotePropertyName additionalDetails -NotePropertyValue @([pscustomobject]@{ key = 'User-Agent'; value = 'Test' })
        $d = @(ConvertTo-HUSecAuditDetail $e)
        ($d[0].PSObject.Properties.Name -join ',') | Should -Be 'Bereich,Feld,Vorher,Nachher'
        @($d | Where-Object { $_.Feld -eq 'IP-Adresse' -and $_.Nachher -eq '192.0.2.10' }).Count | Should -Be 1
        @($d | Where-Object { $_.Feld -eq 'Korrelations-ID' }).Count | Should -Be 1
        @($d | Where-Object { $_.Bereich -eq 'Weitere Angaben' -and $_.Feld -eq 'User-Agent' }).Count | Should -Be 1
        $chg = @($d | Where-Object { $_.Feld -like 'ConditionalAccessPolicy*' })
        $chg.Count | Should -Be 1
        $chg[0].Feld | Should -Be 'ConditionalAccessPolicy.state'
        $chg[0].Vorher | Should -Be 'enabledForReportingButNotEnforced'
        $chg[0].Nachher | Should -Be 'enabled'
    }

    It 'zeigt bei neu angelegten Eintraegen alle Werte, kuerzt lange Werte und begrenzt die Zeilen' {
        $new = '{"displayName":"Neu","state":"enabled"}'
        $e = Ev 'Policy' 'Add conditional access policy' -Props @([pscustomobject]@{ displayName = 'ConditionalAccessPolicy'; oldValue = ''; newValue = ($new | ConvertTo-Json) })
        @(ConvertTo-HUSecAuditDetail $e | Where-Object { $_.Feld -like 'ConditionalAccessPolicy*' }).Count | Should -Be 2
        $long = Ev 'Policy' 'Update policy' -Props @([pscustomobject]@{ displayName = 'X'; oldValue = ''; newValue = ('"' + ('a' * 900) + '"') })
        (@(ConvertTo-HUSecAuditDetail $long -MaxLen 100 | Where-Object { $_.Feld -eq 'X' })[0].Nachher) | Should -Match '\.\.\. \(900 Zeichen\)$'
        $roles = (@(1..30 | ForEach-Object { [guid]::NewGuid().ToString() }) | ConvertTo-Json -Compress)
        $add = Ev 'Policy' 'Add conditional access policy' -Props @([pscustomobject]@{ displayName = 'excludeRoles'; oldValue = ''; newValue = $roles })
        $lr = @(ConvertTo-HUSecAuditDetail $add -MaxLen 200 | Where-Object { $_.Feld -like 'excludeRoles*' })
        $lr.Count | Should -Be 30
        $lr[0].Feld | Should -Be 'excludeRoles [1]'
        @($lr | Where-Object { $_.Nachher -match 'Zeichen\)$' }).Count | Should -Be 0
        $many = @(ConvertTo-HUSecAuditDetail $long -MaxRows 3)
        $many.Count | Should -Be 4
        $many[-1].Feld | Should -Be 'gekuerzt'
    }

    It 'blendet versteckte Felder in der Tabelle nur auf Wunsch aus' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        . (Join-Path $root 'Functions\UI-QSTable.ps1')
        $o = [pscustomobject]@{ Zeit = '1'; __Detail = @('x') }
        (ConvertTo-HUQSRows @($o)).Columns | Should -Contain '__Detail'
        (ConvertTo-HUQSRows @($o) -SkipHidden).Columns | Should -Not -Contain '__Detail'
    }
}

Describe 'Ausnahmen bei gleitendem Zeitraum (2.6.18)' {
    BeforeEach { Remove-Item -LiteralPath (Join-Path $script:TestAppData 'HU-MultiTenant') -Recurse -Force -ErrorAction SilentlyContinue }

    It 'deckt nur Ereignisse bis zum Anlegen, ein spaeteres hebt sie auf' {
        $ex = [pscustomobject]@{ id = 'e1'; ruleId = 'L01'; tenant = 'T1'; objectId = '-'; created = '2026-11-10T12:00:00.0000000Z'; validUntil = '2027-01-01T00:00:00.0000000Z' }
        $now = [datetime]'2026-11-20'
        $old = Res 'L01' 'Abweichung' -Count 1; $old | Add-Member -NotePropertyName Latest -NotePropertyValue '2026-11-10T08:00:00.0000000Z'
        $new = Res 'L01' 'Abweichung' -Count 2; $new | Add-Member -NotePropertyName Latest -NotePropertyValue '2026-11-12T08:00:00.0000000Z'
        (Find-HUSecException $old @($ex) $now).id | Should -Be 'e1'
        Find-HUSecException $new @($ex) $now | Should -BeNullOrEmpty
    }

    It 'aendert nichts an Regeln ohne Zeitpunkt' {
        $ex = [pscustomobject]@{ id = 'e2'; ruleId = 'A19'; tenant = 'T1'; objectId = '-'; created = '2026-11-10T12:00:00.0000000Z'; validUntil = '2027-01-01T00:00:00.0000000Z' }
        (Find-HUSecException (Res 'A19' 'Abweichung' -Count 3) @($ex) ([datetime]'2026-11-20')).id | Should -Be 'e2'
    }

    It 'gilt auch fuer gespeicherte und wieder gelesene Ausnahmen (Datum aus JSON, PS 5.1 und 7)' {
        $x = Add-HUSecException -RuleId 'L02' -TenantKey 'T1' -Reason 'Domaene fuer die neue Website gewollt' -ValidUntil (Get-Date).AddMonths(2) -Responsible 'Systembetreuung'
        $saved = @(Get-HUSecExceptions)
        $saved.Count | Should -Be 1
        $before = Res 'L02' 'Abweichung' -Count 1; $before | Add-Member -NotePropertyName Latest -NotePropertyValue (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        $after = Res 'L02' 'Abweichung' -Count 2; $after | Add-Member -NotePropertyName Latest -NotePropertyValue (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
        (Find-HUSecException $before $saved).id | Should -Be $x.id
        Find-HUSecException $after $saved | Should -BeNullOrEmpty
        Get-HUSecExceptionState -Exception $saved[0] -Results @($after) | Should -Be 'wirkungslos: neues Ereignis nach dem Anlegen'
        Get-HUSecExceptionState -Exception $saved[0] -Results @($before) | Should -Be 'aktiv'
    }

    It 'deckt mit CoversUntil nur das beim letzten Pruefen gesehene Ereignis, nicht spaetere vor dem Anlegen' {
        $seen = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
        $x = Add-HUSecException -RuleId 'L01' -TenantKey 'T1' -Reason 'Neue Lehrkraft als Helpdesk-Admin' -ValidUntil (Get-Date).AddMonths(1) -Responsible 'Systembetreuung' -CoversUntil $seen
        $saved = @(Get-HUSecExceptions)
        $same = Res 'L01' 'Abweichung' -Count 1; $same | Add-Member -NotePropertyName Latest -NotePropertyValue $seen
        $between = Res 'L01' 'Abweichung' -Count 2; $between | Add-Member -NotePropertyName Latest -NotePropertyValue (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        (Find-HUSecException $same $saved).id | Should -Be $x.id
        Find-HUSecException $between $saved | Should -BeNullOrEmpty
        [void](Add-HUSecException -RuleId 'L01' -TenantKey 'T1' -Reason 'Ausnahme ohne gesehenes Ereignis' -ValidUntil (Get-Date).AddMonths(1) -Responsible 'Systembetreuung' -CoversUntil '')
        Find-HUSecException $same @(Get-HUSecExceptions) | Should -BeNullOrEmpty
    }

    It 'laesst ein neues Ereignis trotz Ausnahme im Katalog als Abweichung stehen' {
        $global:HUSecEeps = New-Object System.Collections.Generic.List[string]
        $global:HUSecEfx = @{
            'subscribedSkus' = , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })
            "'RoleManagement'" = @((Ev 'RoleManagement' 'Add member to role' -TargetId 'u1' -When (Get-Date).ToUniversalTime().AddHours(1).ToString('o')))
            "'DirectoryManagement'" = @(); "'ApplicationManagement'" = @(); "'Policy'" = @()
        }
        [void](Add-HUSecException -RuleId 'L01' -TenantKey 'T1' -Reason 'Neue Lehrkraft als Helpdesk-Admin' -ValidUntil (Get-Date).AddMonths(1) -Responsible 'Systembetreuung')
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'OWN-APP' }) }
        (@(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $set -RuleIds @('L01'))[0]).Status | Should -Be 'Abweichung'
        $global:HUSecEfx["'RoleManagement'"] = @((Ev 'RoleManagement' 'Add member to role' -TargetId 'u1' -When (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')))
        (@(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $set -RuleIds @('L01'))[0]).Status | Should -Be 'Ausnahme'
    }
}

Describe 'L01 mit Gruppen mit Admin-Rolle (2.6.18)' {
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $script:TestAppData 'HU-MultiTenant') -Recurse -Force -ErrorAction SilentlyContinue
        $global:HUSecEeps = New-Object System.Collections.Generic.List[string]
        $grpAdd = Ev 'GroupManagement' 'Add member to group' -TargetId 'u7' -TargetName 'Neue Lehrkraft' -When (Get-Date).ToUniversalTime().AddDays(-1).ToString('o') -Props @([pscustomobject]@{ displayName = 'Group.DisplayName'; newValue = '"Helpdesk-Admins"' })
        $global:HUSecEfx = @{
            'subscribedSkus' = , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })
            "'RoleManagement'" = @(); "'DirectoryManagement'" = @(); "'ApplicationManagement'" = @(); "'Policy'" = @()
            'isAssignableToRole' = @([pscustomobject]@{ id = 'g1'; displayName = 'Helpdesk-Admins' })
            'GroupManagement' = @($grpAdd)
        }
        $script:Set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'OWN-APP' }) }
    }

    It 'zaehlt eine Aufnahme in eine Gruppe mit Admin-Rolle und nennt die Gruppe' {
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $r.Status | Should -Be 'Abweichung'
        $r.Count | Should -Be 1
        $r.Detail | Should -Match '1 Gruppe\(n\) mit Admin-Rolle mitgeprueft'
        "$($r.Latest)" | Should -Not -BeNullOrEmpty
        $q = @($global:HUSecEeps | Where-Object { $_ -like '*GroupManagement*' })
        $q.Count | Should -Be 1
        [uri]::UnescapeDataString($q[0]) | Should -Match "targetResources/any\(t:t/id eq 'g1'\)"
        $row = @(Get-HUSecItems -TenantKey 'T1' -Settings $script:Set -RuleId 'L01')[0]
        $row.Ziel | Should -Be 'Neue Lehrkraft (Gruppe mit Admin-Rolle: Helpdesk-Admins)'
        $row.Art | Should -Be 'Admin-Rolle ueber Gruppe'
    }

    It 'fragt ohne solche Gruppen nicht weiter nach' {
        $global:HUSecEfx['isAssignableToRole'] = @()
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $r.Status | Should -Be 'OK'
        @($global:HUSecEeps | Where-Object { $_ -like '*GroupManagement*' }).Count | Should -Be 0
    }

    It 'macht nur L01 nicht pruefbar, wenn die Gruppen nicht lesbar sind' {
        Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
            param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
            if ($Endpoint -like '*isAssignableToRole*') { $e = New-Object System.Exception('gedrosselt'); $e.Data['StatusCode'] = 429; throw $e }
            if ($Endpoint -like '*subscribedSkus*') { return , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) }
            if ($Endpoint -like '*directoryAudits*') { return @() }
            if ($Endpoint -like '*servicePrincipals*') { return @() }
            throw 'nicht vorbereitet'
        }
        $res = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01', 'L02'))
        $by = @{}; foreach ($x in $res) { $by[$x.RuleId] = $x }
        $by['L01'].Status | Should -Be 'NichtPruefbar'
        $by['L01'].Detail | Should -Match 'HTTP 429'
        $by['L02'].Status | Should -Be 'OK'
    }

    It 'laesst eine direkte Rollenvergabe rot, auch wenn die Gruppen nicht lesbar sind, und meldet fehlendes Recht als Recht' {
        $when = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
        $global:HUSecRoleEv = @((Ev 'RoleManagement' 'Add member to role' -TargetId 'u1' -When $when))
        $global:HUSecGrpCode = 429
        Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
            param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
            if ($Endpoint -like '*isAssignableToRole*') { $e = New-Object System.Exception('x'); $e.Data['StatusCode'] = $global:HUSecGrpCode; throw $e }
            if ($Endpoint -like '*subscribedSkus*') { return , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) }
            if ($Endpoint -like "*'RoleManagement'*") { return $global:HUSecRoleEv }
            if ($Endpoint -like '*directoryAudits*' -or $Endpoint -like '*servicePrincipals*') { return @() }
            throw 'nicht vorbereitet'
        }
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $r.Status | Should -Be 'Abweichung'
        $r.Complete | Should -BeFalse
        $r.Detail | Should -Match 'nicht lesbar \(HTTP 429\)'
        "$($r.Latest)" | Should -Not -BeNullOrEmpty
        $rows = @(Get-HUSecChanges -TenantKey 'T1' -Settings $script:Set)
        @($rows | Where-Object { $_.Art -eq 'Hinweis' }).Count | Should -Be 1
        $global:HUSecRoleEv = @(); $global:HUSecGrpCode = 403
        $n = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))[0]
        $n.Status | Should -Be 'NichtPruefbar'
        $n.Reason | Should -Be 'Recht'
        Remove-Variable -Name HUSecRoleEv, HUSecGrpCode -Scope Global -ErrorAction SilentlyContinue
    }

    It 'fragt bei 16 Gruppen in zwei Abrufen und liest die echte Form (Stelle 1 = Gruppe)' {
        $global:HUSecEfx['isAssignableToRole'] = @(1..16 | ForEach-Object { [pscustomobject]@{ id = "g$_"; displayName = "Gruppe $_" } })
        $e = Ev 'GroupManagement' 'Add member to group' -TargetId 'u8' -TargetName 'Konto Acht' -When (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
        $e.targetResources = @($e.targetResources[0], [pscustomobject]@{ id = 'g16'; displayName = 'Gruppe 16'; type = 'Group'; modifiedProperties = @() })
        $global:HUSecEfx['GroupManagement'] = @($e)
        [void](Invoke-HUSecCatalog -TenantKey 'T1' -Settings $script:Set -RuleIds @('L01'))
        $q = @($global:HUSecEeps | Where-Object { $_ -like '*GroupManagement*' } | ForEach-Object { [uri]::UnescapeDataString($_) })
        $q.Count | Should -Be 2
        $q[0] | Should -Match "t/id eq 'g15'\)"
        $q[1] | Should -Match "any\(t:t/id eq 'g16'\)"
        $row = @(Get-HUSecItems -TenantKey 'T1' -Settings $script:Set -RuleId 'L01')[0]
        $row.Ziel | Should -Be 'Konto Acht (Gruppe mit Admin-Rolle: Gruppe 16)'
    }

    It 'zaehlt Gruppenaenderungen ohne Markierung aus dem gezielten Abruf nie als Rolle' {
        Get-HUSecAuditKind (Ev 'GroupManagement' 'Add member to group') | Should -Be ''
    }
}

Describe 'A27 mit Gruppen eines Partners (2.6.18)' {
    It 'bewertet Partner-Gruppen nicht, statt die Regel abzubrechen' {
        Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
            param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
            if ($Endpoint -like '*roleAssignments*') {
                return @([pscustomobject]@{ principalId = 'u1'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; displayName = 'Admin Eins' } },
                    [pscustomobject]@{ principalId = 'g9'; roleDefinitionId = 'e8611ab8-c189-46e8-94e1-60213ab1f814'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; displayName = 'AdminAgents @( Firma Test , firma.test )' } },
                    [pscustomobject]@{ principalId = 'g9'; roleDefinitionId = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; displayName = 'AdminAgents @( Firma Test , firma.test )' } })
            }
            if ($Endpoint -like '/groups/g9/members*') { $e = New-Object System.Exception('nicht gefunden'); $e.Data['StatusCode'] = 404; throw $e }
            if ($Endpoint -like '/users?*') { return @([pscustomobject]@{ id = 'u1'; userPrincipalName = 'admin1@contoso.test'; accountEnabled = $true; createdDateTime = '2025-01-01T00:00:00Z'; signInActivity = [pscustomobject]@{ lastSuccessfulSignInDateTime = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o') } }) }
            if ($Endpoint -like '*subscribedSkus*') { return , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) }
            throw 'nicht vorbereitet'
        }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'OWN-APP' }) }
        $r = @(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $set -RuleIds @('A27'))[0]
        $r.Status | Should -Be 'OK'
        $r.Detail | Should -Match '1 Gruppe\(n\) eines Partners'
        $r.Detail | Should -Match 'AdminAgents: Privileged Role Administrator und 1 weitere'
        Should -Invoke -ModuleName HU.SecCatalog Invoke-HUSecFetch -Times 1 -Exactly -ParameterFilter { $Endpoint -like '/groups/g9/members*' }
    }

    It 'nennt Partner-Gruppen ohne bekannte Rolle mit der Anzahl und kuerzt lange Rollenlisten' {
        $m = InModuleScope HU.SecCatalog { Format-HUSecExtGroups @([pscustomobject]@{ name = 'Gruppe X @( Firma , firma.test )'; roles = @('aaaa', 'bbbb') }) }
        $m | Should -Be 'Gruppe X: 2 Rolle(n)'
        $l = InModuleScope HU.SecCatalog { Format-HUSecExtGroups @([pscustomobject]@{ name = 'AdminAgents'; roles = @('fe930be7-5e62-47db-91af-98c3a49a38b1', '62e90394-69f5-4237-9190-012177145e10', '7be44c8a-adaf-4e2a-84d6-ab2649e08a13', '729827e3-9c14-49f7-bb1b-9608f156bbb8', 'cccc') }) }
        $l | Should -Be 'AdminAgents: Global Administrator, Privileged Authentication Administrator, User Administrator und 2 weitere'
    }

    It 'bricht bei anderen Fehlern weiter ab (nicht pruefbar statt falsch gruen)' {
        Mock -ModuleName HU.SecCatalog Invoke-HUSecFetch {
            param($TenantKey, $Settings, $Endpoint, [switch]$All, [switch]$Beta)
            if ($Endpoint -like '*roleAssignments*') { return @([pscustomobject]@{ principalId = 'g9'; principal = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.group'; displayName = 'Gruppe' } }) }
            if ($Endpoint -like '/groups/g9/members*') { $e = New-Object System.Exception('gedrosselt'); $e.Data['StatusCode'] = 429; throw $e }
            if ($Endpoint -like '*subscribedSkus*') { return , @([pscustomobject]@{ servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) }
            throw 'nicht vorbereitet'
        }
        $set = [pscustomobject]@{ tenants = @([pscustomobject]@{ key = 'T1'; appId = 'OWN-APP' }) }
        (@(Invoke-HUSecCatalog -TenantKey 'T1' -Settings $set -RuleIds @('A27'))[0]).Status | Should -Not -Be 'OK'
    }
}
