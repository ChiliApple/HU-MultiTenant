#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5): AD-Schema im Bericht "Inaktive Benutzer" (VirtualSchool, iPack, Eigene) - ohne Netzwerk.
.DESCRIPTION
    Die Schema-Abschnitte werden aus der Extension gelesen und mit Attrappen fuer Get-Settings und Protokoll ausgefuehrt.
    Pruefen ausserdem, dass die Runner die Einstellungen laden (sonst bleibt Get-Settings in der Extension leer).
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Root = $root
    $src = [System.IO.File]::ReadAllText((Join-Path $root 'Extensions\User\User-InactiveUsersReport.ps1'), [System.Text.Encoding]::UTF8).Replace("`r`n", "`n")

    $a = $src.IndexOf('# 1b. SCHULTYP-ERKENNUNG')
    $a = $src.LastIndexOf("`n", $src.LastIndexOf('# ====', $a)) + 1
    $b = $src.IndexOf('    $allUsers = Invoke-GraphRequestAll')
    $c = $src.IndexOf('        # --- Rolle + Klasse')
    $d = $src.IndexOf('        # --- Enriched Object ---')
    ($a -gt 0 -and $b -gt $a -and $c -gt $b -and $d -gt $c) | Should -BeTrue
    $schemaBlock = $src.Substring($a, $b - $a)
    $userBlock = $src.Substring($c, $d - $c)

    $script:Settings = $null
    function Get-Settings { return $script:Settings }
    function Write-HULog { param($Message, $Level, $Tenant) }
    function Write-HULogWarn { param($Message, $Tenant) $script:Warned = $true }

    $code = 'param($TenantKey, $user)' + "`n" + $schemaBlock + "`n" + 'foreach ($dummy in 1) {' + "`n" + $userBlock + "`n" + '}' + "`n" + 'return [pscustomobject]@{ Rolle = $rolle; Klasse = $klasse; Select = $selectFields }'
    $script:Probe = [scriptblock]::Create($code)

    function Use-Schema($schema, $role, $class) {
        $t = [pscustomobject]@{ key = 'T1'; adSchema = $schema }
        if ($null -ne $role) { $t | Add-Member -NotePropertyName adRoleAttr -NotePropertyValue $role }
        if ($null -ne $class) { $t | Add-Member -NotePropertyName adClassAttr -NotePropertyValue $class }
        $script:Settings = [pscustomobject]@{ tenants = @($t) }
    }
    $script:User = [pscustomobject]@{
        displayName = 'Muster Max, 3D'; jobTitle = 'Schueler'; department = '4B'; faxNumber = 'Lehrer'; officeLocation = '5C'
        employeeType = 'Student'
        onPremisesExtensionAttributes = [pscustomobject]@{ extensionAttribute1 = '7A'; extensionAttribute2 = $null }
    }
}

Describe 'AD-Schema im Bericht Inaktive Benutzer' {
    BeforeEach { $script:Warned = $false }

    It 'ohne Einstellungen: VirtualSchool (jobTitle / department)' {
        $script:Settings = $null
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be 'Schueler'
        $r.Klasse | Should -Be '4B'
    }
    It 'VirtualSchool' {
        Use-Schema 'VirtualSchool' $null $null
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be 'Schueler'
        $r.Klasse | Should -Be '4B'
    }
    It 'iPack (faxNumber / officeLocation)' {
        Use-Schema 'iPack' $null $null
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be 'Lehrer'
        $r.Klasse | Should -Be '5C'
    }
    It 'Eigene: einfache Attribute' {
        Use-Schema 'Eigene' 'employeeType' 'department'
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be 'Student'
        $r.Klasse | Should -Be '4B'
        $r.Select | Should -Match ',employeeType'
    }
    It 'Eigene: verschachteltes Attribut' {
        Use-Schema 'Eigene' 'jobTitle' 'onPremisesExtensionAttributes.extensionAttribute1'
        $r = & $script:Probe 'T1' $script:User
        $r.Klasse | Should -Be '7A'
        $r.Select | Should -Match ',onPremisesExtensionAttributes'
        $r.Select | Should -Not -Match 'extensionAttribute1'
    }
    It 'Eigene: leeres oder fehlendes Attribut ergibt leeren Text' {
        Use-Schema 'Eigene' 'gibtEsNicht' 'onPremisesExtensionAttributes.extensionAttribute2'
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be ''
        $r.Klasse | Should -Be ''
    }
    It 'Eigene: ungueltiger Attributname wird nicht abgefragt' {
        Use-Schema 'Eigene' 'jobTitle,id&$top=1' 'department'
        $r = & $script:Probe 'T1' $script:User
        $r.Rolle | Should -Be ''
        $r.Klasse | Should -Be '4B'
        $r.Select | Should -Not -Match 'top=1'
    }
    It 'Eigene ohne Attribute: Warnung, leere Spalten' {
        Use-Schema 'Eigene' '' ''
        $r = & $script:Probe 'T1' $script:User
        $script:Warned | Should -BeTrue
        $r.Rolle | Should -Be ''
    }
}

Describe 'Einstellungen im Extension-Lauf' {
    It 'PS5-Runspace laedt die Einstellungen vor dem Start' {
        $t = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Extensions.ps1'), [System.Text.Encoding]::UTF8)
        $t | Should -Match 'Import-TenantSettings -SettingsPath \(Join-Path \$AppRoot'
    }
    It 'PS7-Runner laedt die Einstellungen vor dem Start' {
        $t = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Core\Invoke-PS7Extension.ps1'), [System.Text.Encoding]::UTF8)
        $t | Should -Match 'Import-TenantSettings -SettingsPath \(Join-Path \$AppRoot'
    }
    It 'Einstellungsfenster kennt die Option Eigene mit zwei Attributfeldern' {
        $x = [System.IO.File]::ReadAllText((Join-Path $script:Root 'XAML\SettingsWindow.xaml'), [System.Text.Encoding]::UTF8)
        $x | Should -Match 'ComboBoxItem Content="Eigene"'
        $x | Should -Match 'x:Name="tRoleAttr"'
        $x | Should -Match 'x:Name="tClassAttr"'
        $u = [System.IO.File]::ReadAllText((Join-Path $script:Root 'Functions\UI-Settings.ps1'), [System.Text.Encoding]::UTF8)
        $u | Should -Match "'adRoleAttr'"
        $u | Should -Match "'adClassAttr'"
    }
}
