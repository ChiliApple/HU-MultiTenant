#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.Transfer.psm1 (Uebertragen A: neu anlegen im Ziel) - ohne Netzwerk.
.NOTES
    Graph wird ersetzt: Lesen aus $global:TrFx (Endpunkt-Muster -> Antwort), Listen aus $global:TrList, Schreiben in $global:TrWrites.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $root 'Core\HU.Logging.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Intune.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'Core\HU.Transfer.psm1') -Force -DisableNameChecking
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-TR-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = $script:Tmp } }
    Mock -ModuleName HU.Transfer Write-HULog { }
    Mock -ModuleName HU.Transfer Resolve-HUFlatMapIds { param($TenantKey, $Settings, $Map) $Map }
    Mock -ModuleName HU.Transfer Get-HUIntuneGraphAll {
        param($TenantKey, $Settings, $Endpoint, [switch]$V1)
        foreach ($k in @($global:TrList.Keys)) { if ("$TenantKey|$Endpoint" -like "*$k*") { return @($global:TrList[$k]) } }
        return @()
    }
    Mock -ModuleName HU.Transfer Invoke-HUIntuneGraph {
        param($TenantKey, $Settings, $Endpoint, $Method = 'GET', $Body, [switch]$V1, [switch]$NoRetry)
        if ($Method -ne 'GET') { $global:TrWrites += [pscustomobject]@{ Tenant = $TenantKey; Method = $Method; Endpoint = $Endpoint }; return $null }
        foreach ($k in @($global:TrFx.Keys)) { if ("$TenantKey|$Endpoint" -like "*$k*") { return $global:TrFx[$k] } }
        $ex = New-Object System.Exception('404'); $ex.Data['StatusCode'] = 404; throw $ex
    }
    $script:Prof = {
        [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; id = 'p1'; displayName = 'Win Basis'; passwordRequired = $true; passwordMinimumLength = 8; roleScopeTagIds = @('0') }
    }
}

AfterAll {
    Remove-Module HU.Transfer -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Uebertragen A - Plan' {
    BeforeEach { $global:TrFx = @{}; $global:TrList = @{}; $global:TrWrites = @() }

    It 'zeigt alle Einstellungen, legt ohne Zuweisungen an, Standard-Markierung bleibt 0' {
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Q' -TargetKey 'Z'
        $p.Blocks.Count | Should -Be 0
        $p.ScopeTagIds | Should -Be @('0')
        @($p.Changes | Where-Object Feld -eq 'passwordMinimumLength')[0].Danach | Should -Be '8'
        @($p.Changes | Where-Object Feld -eq 'displayName')[0].Jetzt | Should -Be '(fehlt)'
    }
    It 'Name im Ziel schon vorhanden (Gross/klein, Leerzeichen egal) sperrt' {
        $global:TrList['Z|/deviceManagement/deviceConfigurations'] = @([pscustomobject]@{ id = 'x'; displayName = ' win basis ' })
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Q' -TargetKey 'Z'
        @($p.Blocks | Where-Object { $_ -like '*gibt es im Ziel schon*' }).Count | Should -Be 1
    }
    It 'Quelle = Ziel sperrt; nicht uebertragbare Art sperrt' {
        (Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Z' -TargetKey 'Z').Blocks[0] | Should -BeLike '*derselbe Tenant*'
        (Get-HUTransferPlan -Settings $script:Set -Typ 'Conditional Access' -SourceObj ([pscustomobject]@{ displayName = 'x' }) -SourceKey 'Q' -TargetKey 'Z').Blocks[0] | Should -BeLike '*nicht uebertragen*'
    }
    It 'Geheimnisse sperren: Einstellungskatalog-Geheimnis, OMA-URI verschluesselt, Kennwort-Feld' {
        $cat = [pscustomobject]@{ name = 'Kat'; settings = @([pscustomobject]@{ settingInstance = [pscustomobject]@{ simpleSettingValue = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSecretSettingValue'; valueState = 'encryptedValueToken'; value = 'tok' } } }) }
        @(Find-HUTrSecrets $cat).Count | Should -BeGreaterThan 0
        $oma = [pscustomobject]@{ displayName = 'Oma'; omaSettings = @([pscustomobject]@{ omaUri = './x'; isEncrypted = $true; secretReferenceValueId = 'r1'; value = '****' }) }
        @(Find-HUTrSecrets $oma).Count | Should -BeGreaterThan 0
        @(Find-HUTrSecrets ([pscustomobject]@{ displayName = 'k'; preSharedKey = 'abc' })).Count | Should -Be 1
        @(Find-HUTrSecrets (& $script:Prof)).Count | Should -Be 0
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $oma -SourceKey 'Q' -TargetKey 'Z'
        @($p.Blocks | Where-Object { $_ -like 'Geheimer Wert*' }).Count | Should -BeGreaterThan 0
    }
    It '047 B1: Verweise auf Objekte des Quell-Tenants sperren, Microsoft-Kennungen nicht' {
        $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; id = '11111111-0000-0000-0000-000000000001'; displayName = 'Comp'
            deviceCompliancePolicyScript = [pscustomobject]@{ deviceComplianceScriptId = '22222222-0000-0000-0000-000000000002'; rulesContent = 'x' }
            scheduledActionsForRule = @([pscustomobject]@{ scheduledActionConfigurations = @([pscustomobject]@{ actionType = 'block'; notificationTemplateId = '33333333-0000-0000-0000-000000000003' }) }) }
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Compliance' -SourceObj $o -SourceKey 'Q' -TargetKey 'Z'
        @($p.Blocks | Where-Object { $_ -like '*Quell-Tenants (deviceCompliancePolicyScript.deviceComplianceScriptId = 22222222*' }).Count | Should -Be 1
        @($p.Blocks | Where-Object { $_ -like '*33333333*' -or $_ -like '*11111111*' }).Count | Should -Be 0
        $cat = [pscustomobject]@{ name = 'Kat'; templateReference = [pscustomobject]@{ templateId = '44444444-0000-0000-0000-000000000004' }; settings = @([pscustomobject]@{ id = '0'; settingInstance = [pscustomobject]@{ settingDefinitionId = 'device_vendor_msft_x'; settingInstanceTemplateReference = [pscustomobject]@{ settingInstanceTemplateId = '55555555-0000-0000-0000-000000000005' } } }) }
        @(Find-HUTrForeignIds $cat).Count | Should -Be 0
        # Graph-Metadaten (Annotationen) enthalten die Quell-URL mit GUID - kein Verweis, wird nie mitgeschickt
        $ann = [pscustomobject]@{ name = 'Kat'; 'settings@odata.context' = 'https://graph.microsoft.com/beta/$metadata#deviceManagement/configurationPolicies(''77777777-0000-0000-0000-000000000007'')/settings'; fremd = '88888888-0000-0000-0000-000000000008' }
        @(Find-HUTrForeignIds $ann) | Should -Be @('fremd = 88888888-0000-0000-0000-000000000008')
    }
    It '047 B6: id nur oben und bei Einstellungen/Vorlagenwerten erlaubt, nicht verschachtelt' {
        $adm = [pscustomobject]@{ id = '11111111-0000-0000-0000-000000000001'; displayName = 'Adm'; definitionValues = @([pscustomobject]@{ id = '22222222-0000-0000-0000-000000000002'; presentationValues = @([pscustomobject]@{ id = '33333333-0000-0000-0000-000000000003'; value = 'x' }) }) }
        @(Find-HUTrForeignIds $adm).Count | Should -Be 0
        $deep = [pscustomobject]@{ id = '11111111-0000-0000-0000-000000000001'; displayName = 'Tief'; irgendwas = [pscustomobject]@{ id = '66666666-0000-0000-0000-000000000006' } }
        @(Find-HUTrForeignIds $deep) | Should -Be @('irgendwas.id = 66666666-0000-0000-0000-000000000006')
    }
    It '047 B3: Geheimnis-Namen enthalten statt genau; Kennwort-Regeln sind keine Geheimnisse' {
        @(Find-HUTrSecrets ([pscustomobject]@{ displayName = 'x'; certificatePassword = 'abc'; networkKey = 'k' })).Count | Should -Be 2
        @(Find-HUTrSecrets ([pscustomobject]@{ displayName = 'x'; passwordRequiredType = 'alphanumeric'; passwordMinimumLength = 8; passwordRequired = $true })).Count | Should -Be 0
    }
    It 'WLAN/VPN-Profile sperren (Zertifikats-/Geheimnis-Verweise)' {
        $wifi = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windowsWifiEnterpriseEAPConfiguration'; displayName = 'WLAN Schule'; ssid = 'S' }
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $wifi -SourceKey 'Q' -TargetKey 'Z'
        @($p.Blocks | Where-Object { $_ -like 'Profiltyp*' }).Count | Should -Be 1
    }
    It 'Bereichsmarkierung ueber den Namen: eindeutig -> Ziel-ID, fehlt -> Sperre' {
        $o = & $script:Prof; $o.roleScopeTagIds = @('0', '5')
        $global:TrList['Z|/deviceManagement/roleScopeTags'] = @([pscustomobject]@{ id = '0'; displayName = 'Default' }, [pscustomobject]@{ id = '9'; displayName = 'Schule' })
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $o -SourceKey 'Q' -TargetKey 'Z' -SourceTagNames @{ '5' = 'schule' }
        $p.Blocks.Count | Should -Be 0
        $p.ScopeTagIds | Should -Be @('0', '9')
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $o -SourceKey 'Q' -TargetKey 'Z' -SourceTagNames @{ '5' = 'Andere' }
        @($p.Blocks | Where-Object { $_ -like "Bereichsmarkierung 'Andere'*" }).Count | Should -Be 1
    }
    It 'Compliance: Benachrichtigungs-Aktion wird sichtbar weggelassen' {
        $c = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; displayName = 'Comp'; scheduledActionsForRule = @([pscustomobject]@{ scheduledActionConfigurations = @([pscustomobject]@{ actionType = 'block' }, [pscustomobject]@{ actionType = 'notification' }) }) }
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Compliance' -SourceObj $c -SourceKey 'Q' -TargetKey 'Z'
        @($p.Dropped | Where-Object { $_ -like '1 Benachrichtigungs*' }).Count | Should -Be 1
        @($p.Confirms | Where-Object { $_ -like '*NICHT uebernommen*' }).Count | Should -Be 1
        $p.Blocks.Count | Should -Be 0
        # 045 B5: ohne oder mit zwei block-Aktionen gesperrt
        $c.scheduledActionsForRule[0].scheduledActionConfigurations = @([pscustomobject]@{ actionType = 'notification' })
        @((Get-HUTransferPlan -Settings $script:Set -Typ 'Compliance' -SourceObj $c -SourceKey 'Q' -TargetKey 'Z').Blocks | Where-Object { $_ -like '*0 Aktion*' }).Count | Should -Be 1
    }
    It '045 B3/F2: Zertifikatsprofile sperren; Namen nur am Rand getrimmt' {
        $cert = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows81TrustedRootCertificate'; displayName = 'Root' }
        @((Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $cert -SourceKey 'Q' -TargetKey 'Z').Blocks | Where-Object { $_ -like 'Profiltyp*' }).Count | Should -Be 1
        $global:TrList['Z|/deviceManagement/deviceConfigurations'] = @([pscustomobject]@{ id = 'x'; displayName = 'Win  Basis' })
        (Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Q' -TargetKey 'Z').Blocks.Count | Should -Be 0
    }
}

Describe 'Uebertragen A - Schreiben und Rueckgaengig' {
    BeforeEach { $global:TrFx = @{}; $global:TrList = @{}; $global:TrWrites = @() }

    It 'legt an, prueft nach, schreibt Rueckgaengig-Datei; Rueckgaengig loescht nur unveraendert' {
        $src = & $script:Prof
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj $src -SourceKey 'Q' -TargetKey 'Z'
        Mock -ModuleName HU.Transfer New-HUIntuneObject { 'neu1' }
        $created = & $script:Prof; $created.id = 'neu1'
        Mock -ModuleName HU.Transfer Get-HUCompareObject { $global:TrCreated }
        $global:TrCreated = $created
        $r = Invoke-HUTransfer -Plan $p -Settings $script:Set -Now ([datetime]'2026-10-22 20:00')
        $r.Ok | Should -BeTrue
        $r.NewId | Should -Be 'neu1'
        Test-Path -LiteralPath $r.UndoFile | Should -BeTrue
        @(Get-HUTransferUndoList -Settings $script:Set -Keys @('Z')).Count | Should -Be 1
        # geaendert -> kein Loeschen
        $mod = & $script:Prof; $mod.id = 'neu1'; $mod.passwordMinimumLength = 12
        $global:TrCreated = $mod
        { Undo-HUTransfer -Settings $script:Set -File $r.UndoFile } | Should -Throw '*geaendert*'
        # 047 B5: ohne Fingerabdruck nur mit -Force
        $u = Get-Content -LiteralPath $r.UndoFile -Raw | ConvertFrom-Json; $u.Hash = ''
        $nh = $r.UndoFile -replace '\.json$', '-nohash_neu_x.json'; $u | ConvertTo-Json | Set-Content -LiteralPath $nh
        { Undo-HUTransfer -Settings $script:Set -File $nh } | Should -Throw '*keinen Fingerabdruck*'
        Remove-Item -LiteralPath $nh
        # zugewiesen -> kein Loeschen
        $global:TrCreated = $created
        $global:TrList['Z|/deviceManagement/deviceConfigurations/neu1/assignments'] = @([pscustomobject]@{ id = 'a1' })
        { Undo-HUTransfer -Settings $script:Set -File $r.UndoFile } | Should -Throw '*zugewiesen*'
        $global:TrList.Remove('Z|/deviceManagement/deviceConfigurations/neu1/assignments')
        # unveraendert und nicht zugewiesen -> loeschen, Datei umbenannt
        (Undo-HUTransfer -Settings $script:Set -File $r.UndoFile).Deleted | Should -BeTrue
        @($global:TrWrites | Where-Object Method -eq 'DELETE').Count | Should -Be 1
        @(Get-HUTransferUndoList -Settings $script:Set -Keys @('Z')).Count | Should -Be 0
    }
    It 'Nachpruefung meldet abweichende Einstellung' {
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Q' -TargetKey 'Z'
        Mock -ModuleName HU.Transfer New-HUIntuneObject { 'neu2' }
        Mock -ModuleName HU.Transfer Get-HUCompareObject { $o = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; id = 'neu2'; displayName = 'Win Basis'; passwordRequired = $true }; $o }
        $r = Invoke-HUTransfer -Plan $p -Settings $script:Set
        $r.Ok | Should -BeFalse
        @($r.Mismatch | Where-Object { $_ -like 'passwordMinimumLength*' }).Count | Should -Be 1
    }
    It 'inzwischen im Ziel angelegt -> nichts geschrieben' {
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Konfiguration' -SourceObj (& $script:Prof) -SourceKey 'Q' -TargetKey 'Z'
        $global:TrList['Z|/deviceManagement/deviceConfigurations'] = @([pscustomobject]@{ id = 'x'; displayName = 'Win Basis' })
        Mock -ModuleName HU.Transfer New-HUIntuneObject { throw 'darf nicht aufgerufen werden' }
        { Invoke-HUTransfer -Plan $p -Settings $script:Set } | Should -Throw '*inzwischen*'
    }
    It 'Administrative Vorlage unvollstaendig -> im Ziel wieder geloescht' {
        $p = Get-HUTransferPlan -Settings $script:Set -Typ 'Administrative Vorlage' -SourceObj ([pscustomobject]@{ displayName = 'ADMX'; definitionValues = @() }) -SourceKey 'Q' -TargetKey 'Z'
        Mock -ModuleName HU.Transfer New-HUIntuneObject { $ex = New-Object System.Exception('UNVOLLSTAENDIG angelegt: 1 von 2'); $ex.Data['NewId'] = 'halb'; throw $ex }
        { Invoke-HUTransfer -Plan $p -Settings $script:Set } | Should -Throw '*wieder geloescht*'
        @($global:TrWrites | Where-Object { $_.Method -eq 'DELETE' -and $_.Endpoint -like '*/halb' }).Count | Should -Be 1
    }
}
