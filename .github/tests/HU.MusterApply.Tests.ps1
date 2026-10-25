#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Core\HU.MusterApply.psm1 (2.5.2 Muster anwenden) - ohne Netzwerk.
.NOTES
    Plan- und Schreib-Funktionen aus HU.Transfer/HU.EntraRestore werden im Modul HU.MusterApply ersetzt.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach ($m in 'HU.Logging', 'HU.Intune', 'HU.SecCatalog', 'HU.EntraRestore', 'HU.Muster', 'HU.Transfer', 'HU.MusterApply') { Import-Module (Join-Path $root "Core\$m.psm1") -Force -DisableNameChecking }
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-MA-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Set = [pscustomobject]@{ ui = [pscustomobject]@{ backupPath = (Join-Path $script:Tmp 'Backups') }; tenants = @([pscustomobject]@{ key = 'T1' }) }
    Set-HUMaStateRoot (Join-Path $script:Tmp 'state')
    # Testpaket: Ort, CA (verweist auf den Ort), Compliance, Autorisierung
    $script:Pk = Join-Path $script:Tmp 'paket'
    foreach ($d in 'Benannter_Ort', 'Conditional_Access', 'Compliance', 'Entra-Einstellung') { New-Item -ItemType Directory -Path (Join-Path $script:Pk $d) -Force | Out-Null }
    $w = { param($f, $o) [IO.File]::WriteAllText((Join-Path $script:Pk $f), ($o | ConvertTo-Json -Depth 10)) }
    & $w 'Benannter_Ort/001.json' @{ '@odata.type' = '#microsoft.graph.countryNamedLocation'; id = 'loc-1'; displayName = 'Erlaubte Laender'; countriesAndRegions = @('AT') }
    & $w 'Conditional_Access/002.json' @{ displayName = '903 - Geoblock'; state = 'enabledForReportingButNotEnforced'; conditions = @{} }
    & $w 'Compliance/003.json' @{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; displayName = 'Win'; bitLockerEnabled = $true }
    & $w 'Entra-Einstellung/004.json' @{ id = 'authorizationPolicy'; blockMsolPowerShell = $true }
    $script:Pkg = [pscustomobject]@{ Id = 'p1'; Title = 'Testpaket'; Folder = $script:Pk; Items = @(
            [pscustomobject]@{ Typ = 'Conditional Access'; Name = '903 - Geoblock'; Id = 'ca-1'; File = 'Conditional_Access/002.json'; Source = 'mitgeliefert' }
            [pscustomobject]@{ Typ = 'Compliance'; Name = 'Win'; Id = 'c-1'; File = 'Compliance/003.json'; Source = 'mitgeliefert' }
            [pscustomobject]@{ Typ = 'Benannter Ort'; Name = 'Erlaubte Laender'; Id = 'loc-1'; File = 'Benannter_Ort/001.json'; Source = 'mitgeliefert' }
            [pscustomobject]@{ Typ = 'Entra-Einstellung'; Name = 'Autorisierungsrichtlinie'; Id = 'authorizationPolicy'; File = 'Entra-Einstellung/004.json'; Source = 'mitgeliefert' }
        ) }
    function global:New-MaPlan([string]$Kind = 'transferNew', [string]$Method = 'POST', [string[]]$Blocks = @(), [string]$Name = 'x', [int]$Changes = 1) {
        $p = [pscustomobject]@{ Kind = $Kind; Method = $Method; Body = @{ displayName = $Name }; Changes = New-Object System.Collections.Generic.List[object]; Blocks = New-Object System.Collections.Generic.List[string] }
        for ($i = 0; $i -lt $Changes; $i++) { $p.Changes.Add([pscustomobject]@{ Feld = "f$i"; Expected = 1 }) }
        foreach ($b in $Blocks) { $p.Blocks.Add($b) }
        return $p
    }
    Mock -ModuleName HU.MusterApply Get-HUMusterLocationNames { @{ 'loc-1' = 'Erlaubte Laender' } }
    Mock -ModuleName HU.MusterApply Get-HUMusterTagNames { @{} }
}

AfterAll {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item function:global:New-MaPlan -ErrorAction SilentlyContinue
}

Describe 'Muster anwenden (2.5.2): Rechte, Reihenfolge, Markierung, Sperre' {
    It 'Schreibrechte je Art, jedes Recht nur einmal' {
        Get-HUMaPermission 'Conditional Access' 'x' | Should -Be 'Policy.ReadWrite.ConditionalAccess'
        Get-HUMaPermission 'Benannter Ort' 'x' | Should -Be 'Policy.ReadWrite.ConditionalAccess'
        Get-HUMaPermission 'Entra-Einstellung' 'authorizationPolicy' | Should -Be 'Policy.ReadWrite.Authorization'
        Get-HUMaPermission 'Wartung' 'x' | Should -Be 'DeviceManagementScripts.ReadWrite.All'
        Get-HUMaPermission 'Compliance' 'x' | Should -Be 'DeviceManagementConfiguration.ReadWrite.All'
        Get-HUMaPermission 'App' 'x' | Should -Be ''
        (Get-HUMaNeededPermissions $script:Pkg.Items) -join ',' | Should -Be 'DeviceManagementConfiguration.ReadWrite.All,Policy.ReadWrite.Authorization,Policy.ReadWrite.ConditionalAccess'
    }
    It 'Reihenfolge: Orte, Entra, Intune, Conditional Access' {
        @('Conditional Access', 'Compliance', 'Benannter Ort', 'Entra-Einstellung') | ForEach-Object { Get-HUMaOrder $_ $(if ($_ -eq 'Entra-Einstellung') { 'authorizationPolicy' } else { 'x' }) } | Should -Be @(40, 30, 10, 20)
    }
    It 'Markierung vor dem Erteilen, hinzugefuegte Rechte gehen nie verloren, Loeschen erst am Ende' {
        $m = Write-HUMaMarker -TenantKey 'T1' -TenantName 'Ziel' -Planned @('A', 'B')
        $m.Stage | Should -Be 'vor dem Erteilen'
        @((Get-HUMaMarker 'T1').Added).Count | Should -Be 0
        [void](Write-HUMaMarker -TenantKey 'T1' -Added @('A') -Stage 'erteilt')
        [void](Write-HUMaMarker -TenantKey 'T1' -Added @() -Stage 'laeuft')
        @((Get-HUMaMarker 'T1').Added) | Should -Be @('A')
        (Get-HUMaMarker 'T1').Since | Should -Be $m.Since
        @(Get-HUMaMarkers | Where-Object { $_.Tenant -eq 'T1' }).Count | Should -Be 1
        Remove-HUMaMarker 'T1'
        Get-HUMaMarker 'T1' | Should -BeNullOrEmpty
    }
    It 'Offene Rechte (060 B1): geplante zaehlen bis zum Nachtragen mit, vorher vorhandene nie' {
        [void](Write-HUMaMarker -TenantKey 'T3' -Planned @('A', 'B') -Before @('C'))
        @(Get-HUMaOpenRights (Get-HUMaMarker 'T3')) | Should -Be @('A', 'B')
        # Absturz zwischen Erteilen und Nachtragen: Markierung ohne Added bleibt offen
        @(Get-HUMaOpenRights (Get-HUMaMarker 'T3')).Count | Should -Be 2
        # erfolgreich erteilt, B war schon da (kommt nicht zurueck) -> offen nur A
        [void](Write-HUMaMarker -TenantKey 'T3' -Added @('A') -ClearPlanned -Stage 'erteilt')
        @(Get-HUMaOpenRights (Get-HUMaMarker 'T3')) | Should -Be @('A')
        # spaeterer Durchgang plant C (war vorher da) und D -> offen A, D
        [void](Write-HUMaMarker -TenantKey 'T3' -Planned @('C', 'D'))
        @(Get-HUMaOpenRights (Get-HUMaMarker 'T3')) | Should -Be @('A', 'D')
        @(Get-HUMaOpenRights $null).Count | Should -Be 0
        Remove-HUMaMarker 'T3'
    }
    It 'Sperre (060 B4): fremder PC wird nicht still uebernommen, alte Sperre nach 12 Stunden schon' {
        $lf = Join-Path (Get-HUMaStateRoot) 'muster-sperre-T4.lock'
        [IO.File]::WriteAllText($lf, (@{ Tenant = 'T4'; Pid = 1; Host = 'ANDERER-PC'; Time = (Get-Date).ToString('s') } | ConvertTo-Json))
        { Enter-HUMaLock 'T4' } | Should -Throw '*ANDERER-PC*'
        [IO.File]::WriteAllText($lf, (@{ Tenant = 'T4'; Pid = 1; Host = 'ANDERER-PC'; Time = (Get-Date).AddHours(-13).ToString('s') } | ConvertTo-Json))
        { Enter-HUMaLock 'T4' } | Should -Not -Throw
        (Get-Content $lf -Raw | ConvertFrom-Json).Pid | Should -Be $PID
        Exit-HUMaLock 'T4'
    }
    It 'Sperre: zweite Instanz mit lebendem Prozess abgelehnt, verwaiste Sperre uebernommen' {
        Enter-HUMaLock 'T1'
        Test-Path (Join-Path (Get-HUMaStateRoot) 'muster-sperre-T1.lock') | Should -BeTrue
        Exit-HUMaLock 'T1'
        Test-Path (Join-Path (Get-HUMaStateRoot) 'muster-sperre-T1.lock') | Should -BeFalse
        $other = @(Get-Process | Where-Object { $_.Id -ne $PID -and $_.Id -gt 4 })[0]
        $lf = Join-Path (Get-HUMaStateRoot) 'muster-sperre-T2.lock'
        [IO.File]::WriteAllText($lf, (@{ Tenant = 'T2'; Pid = $other.Id; Host = "$env:COMPUTERNAME"; Time = 'jetzt' } | ConvertTo-Json))
        { Enter-HUMaLock 'T2' } | Should -Throw '*anderen Fenster*'
        [IO.File]::WriteAllText($lf, (@{ Tenant = 'T2'; Pid = 2147483000; Host = "$env:COMPUTERNAME"; Time = 'alt' } | ConvertTo-Json))
        { Enter-HUMaLock 'T2' } | Should -Not -Throw
        Exit-HUMaLock 'T2'
    }
}

Describe 'Muster anwenden (2.5.2): Paket-Plan' {
    It 'Status: neu (an), angleichen (aus), CA zusaetzlich (aus), wartet auf Ort im selben Durchgang' {
        Mock -ModuleName HU.MusterApply Get-HUTransferPlan { New-MaPlan -Name 'Win' }
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan {
            param($TargetKey, $Settings, $Typ, $Id, $Name, $Backup, $ResolveKey, $SourceLabel, $SourceNames)
            switch ($Typ) {
                'Benannter Ort' { New-MaPlan -Kind 'location' -Name $Name }
                'Entra-Einstellung' { New-MaPlan -Kind 'authz' -Method 'PATCH' }
                'Conditional Access' { New-MaPlan -Kind 'caNew' -Blocks @("Den Ort 'Erlaubte Laender' gibt es im Ziel nicht - zuerst den Ort uebertragen.") }
            }
        }
        $rows = @(Get-HUMaPlan -Settings $script:Set -TargetKey 'Z' -Packages @($script:Pkg))
        @($rows | ForEach-Object Typ) | Should -Be @('Benannter Ort', 'Entra-Einstellung', 'Compliance', 'Conditional Access')
        @($rows | ForEach-Object Status) | Should -Be @('neu', 'angleichen', 'neu', 'wartet')
        @($rows | ForEach-Object Default) | Should -Be @($true, $false, $true, $true)
        # ohne neuen Ort im Durchgang: gesperrt
        $r = Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $script:Pkg.Items[0]
        $r.Status | Should -Be 'gesperrt'
        $r.Reason | Should -BeLike "*Den Ort 'Erlaubte Laender'*"
    }
    It 'gleich, gesperrt, nicht anwendbare Art, CA gibt es schon (von Muster) = aus' {
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan { New-MaPlan -Kind 'authz' -Blocks @('Im Ziel schon gleich wie im Muster - nichts zu uebertragen.') }
        (Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $script:Pkg.Items[3]).Status | Should -Be 'gleich'
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan { New-MaPlan -Kind 'caNew' -Name '903 - Geoblock (von Muster)' }
        $r = Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $script:Pkg.Items[0]
        $r.Status | Should -Be 'neu'; $r.Default | Should -BeFalse; $r.Reason | Should -BeLike '*zusaetzlich*'
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan { New-MaPlan -Kind 'caNew' -Blocks @('Im Ziel sind keine Notfallkonten hinterlegt') }
        (Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $script:Pkg.Items[0]).Status | Should -Be 'gesperrt'
        $app = [pscustomobject]@{ Typ = 'App'; Name = 'Teams'; Id = 'a'; File = 'x.json'; Source = 'T1' }
        (Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $app).Reason | Should -BeLike '*nicht angewendet*'
    }
    It 'Intune: Name im Ziel vorhanden -> Angleichen-Plan fuer das gefundene Objekt' {
        Mock -ModuleName HU.MusterApply Get-HUTransferPlan { New-MaPlan -Blocks @("'Win' gibt es im Ziel schon (Angleichen bestehender Objekte kommt mit 2.4.2).") }
        Mock -ModuleName HU.MusterApply Get-HUIntuneGraphAll { @([pscustomobject]@{ id = 'z-win'; displayName = 'win' }) }
        Mock -ModuleName HU.MusterApply Get-HUTransferAlignPlan { param($Settings, $Typ, $SourceObj, $SourceKey, $ResolveKey, $SourceLabel, $TargetKey, $TargetId) $p = New-MaPlan -Kind 'transferAlign'; $p | Add-Member -NotePropertyName TargetId -NotePropertyValue $TargetId; $p }
        $r = Get-HUMaRow -Settings $script:Set -TargetKey 'Z' -Package $script:Pkg -Item $script:Pkg.Items[1]
        $r.Status | Should -Be 'angleichen'
        $r.Plan.TargetId | Should -Be 'z-win'
        $r.Default | Should -BeFalse
    }
    It 'Plaetze und Laender je Name einmal, Auswahl wird in Plaene uebernommen' {
        $mk = { param($slot, $feld) [pscustomobject]@{ Key = "group:1"; Kind = 'group'; Feld = $feld; Slot = $slot; Value = ''; Choices = @([pscustomobject]@{ Id = 'g1'; Name = 'Lehrer' }) } }
        $p1 = New-MaPlan -Kind 'caNew'; $p1 | Add-Member -NotePropertyName Options -NotePropertyValue @((& $mk 'Lehrer' 'includeGroups'), (& $mk 'Ausnahmen' 'excludeGroups'))
        $p2 = New-MaPlan -Kind 'caNew'; $p2 | Add-Member -NotePropertyName Options -NotePropertyValue @((& $mk 'Lehrer' 'includeGroups'))
        $p3 = New-MaPlan -Kind 'location'; $p3 | Add-Member -NotePropertyName Options -NotePropertyValue @([pscustomobject]@{ Key = 'country:DE'; Value = $true; Text = 'Erlaubt: Deutschland (DE)' })
        $rows = @([pscustomobject]@{ Name = '201'; Status = 'neu'; Plan = $p1 }, [pscustomobject]@{ Name = '202'; Status = 'wartet'; Plan = $p2 }, [pscustomobject]@{ Name = 'Ort'; Status = 'neu'; Plan = $p3 })
        $s = Get-HUMaSlots $rows
        @($s.Slots | ForEach-Object Slot) | Should -Be @('Lehrer', 'Ausnahmen')
        @($s.Slots[0].Used) -join ',' | Should -Be '201,202'
        $s.Countries[0].Code | Should -Be 'DE'
        Set-HUMaChoices $p2 @{ Lehrer = 'g1' } @{}
        $p2.Options[0].Value | Should -Be 'g1'
        Set-HUMaChoices $p3 @{} @{ DE = $false }
        $p3.Options[0].Value | Should -BeFalse
    }
}

Describe 'Muster anwenden (2.5.2): Ausfuehren und Paket-Rueckgaengig' {
    It 'Schritt: frisch geplant, geschrieben, im Durchgang festgehalten; gesperrt = nichts geschrieben' {
        Mock -ModuleName HU.MusterApply Get-HUTransferPlan { New-MaPlan -Name 'Win' }
        Mock -ModuleName HU.MusterApply Invoke-HUTransfer { [pscustomobject]@{ Ok = $true; UndoFile = 'C:\undo\win.json'; Mismatch = @() } }
        $run = New-HUMaRun -Settings $script:Set -TenantKey 'Z' -Packages @('Testpaket')
        Test-Path $run.File | Should -BeTrue
        $row = [pscustomobject]@{ Typ = 'Compliance'; Name = 'Win'; Paket = 'Testpaket'; PaketId = 'p1'; Folder = $script:Pk; File = 'Compliance/003.json'; Id = 'c-1'; Source = 'mitgeliefert' }
        $r = Invoke-HUMaStep -Settings $script:Set -TargetKey 'Z' -Row $row -Run $run
        $r.Ok | Should -BeTrue
        Should -Invoke -ModuleName HU.MusterApply Invoke-HUTransfer -Times 1
        Mock -ModuleName HU.MusterApply Get-HUTransferPlan { New-MaPlan -Blocks @('Geheimer Wert') }
        $r2 = Invoke-HUMaStep -Settings $script:Set -TargetKey 'Z' -Row $row -Run $run
        $r2.Ok | Should -BeFalse
        Should -Invoke -ModuleName HU.MusterApply Invoke-HUTransfer -Times 1
        $saved = Read-HUBackupJson $run.File
        @($saved.Steps).Count | Should -Be 2
        $saved.Steps[0].UndoFile | Should -Be 'C:\undo\win.json'
    }
    It 'Stand seit der Vorschau geaendert (060 B2): neu -> angleichen bzw. CA-Zusatzkopie wird nicht geschrieben; wartet -> neu schon' {
        $run = New-HUMaRun -Settings $script:Set -TenantKey 'Z' -Packages @('Testpaket')
        Mock -ModuleName HU.MusterApply Invoke-HUTransfer { [pscustomobject]@{ Ok = $true; UndoFile = ''; Mismatch = @() } }
        Mock -ModuleName HU.MusterApply Invoke-HUTransferAlign { [pscustomobject]@{ Ok = $true; UndoFile = ''; Mismatch = @() } }
        Mock -ModuleName HU.MusterApply Invoke-HUEntraTransfer { [pscustomobject]@{ Ok = $true; UndoFile = ''; Mismatch = @() } }
        # Intune: in der Vorschau neu, jetzt gibt es den Namen -> angleichen
        Mock -ModuleName HU.MusterApply Get-HUTransferPlan { New-MaPlan -Blocks @("'Win' gibt es im Ziel schon (Angleichen bestehender Objekte kommt mit 2.4.2).") }
        Mock -ModuleName HU.MusterApply Get-HUIntuneGraphAll { @([pscustomobject]@{ id = 'z-win'; displayName = 'win' }) }
        Mock -ModuleName HU.MusterApply Get-HUTransferAlignPlan { $p = New-MaPlan -Kind 'transferAlign'; $p.Changes = @([pscustomobject]@{ Expected = 'x' }); $p }
        $row = [pscustomobject]@{ Typ = 'Compliance'; Name = 'Win'; Paket = 'Testpaket'; PaketId = 'p1'; Folder = $script:Pk; File = 'Compliance/003.json'; Id = 'c-1'; Source = 'mitgeliefert'; Status = 'neu'; Reason = '' }
        $r = Invoke-HUMaStep -Settings $script:Set -TargetKey 'Z' -Row $row -Run $run
        $r.Ok | Should -BeFalse; $r.Text | Should -BeLike '*seit der Vorschau*'
        Should -Invoke -ModuleName HU.MusterApply Invoke-HUTransferAlign -Times 0
        # CA: in der Vorschau neu, jetzt Zusatzkopie (von Muster)
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan { New-MaPlan -Kind 'caNew' -Name '903 - Geoblock (von Muster)' }
        $ca = [pscustomobject]@{ Typ = 'Conditional Access'; Name = '903 - Geoblock'; Paket = 'Testpaket'; PaketId = 'p1'; Folder = $script:Pk; File = 'Conditional_Access/002.json'; Id = 'ca-1'; Source = 'mitgeliefert'; Status = 'neu'; Reason = '' }
        (Invoke-HUMaStep -Settings $script:Set -TargetKey 'Z' -Row $ca -Run $run).Text | Should -BeLike '*Zusatzkopie*'
        Should -Invoke -ModuleName HU.MusterApply Invoke-HUEntraTransfer -Times 0
        # wartet -> neu (Ort inzwischen angelegt) wird geschrieben
        Mock -ModuleName HU.MusterApply Get-HUEntraTransferPlan { New-MaPlan -Kind 'caNew' -Name '903 - Geoblock' }
        $ca.Status = 'wartet'
        (Invoke-HUMaStep -Settings $script:Set -TargetKey 'Z' -Row $ca -Run $run).Ok | Should -BeTrue
        Should -Invoke -ModuleName HU.MusterApply Invoke-HUEntraTransfer -Times 1
    }
    It 'Paket rueckgaengig in umgekehrter Reihenfolge; Fehler in einem Schritt = Rest trotzdem, Durchgang bleibt offen' {
        $run = New-HUMaRun -Settings $script:Set -TenantKey 'Z2' -Packages @('Testpaket') -Now (Get-Date).AddMinutes(1)
        $uf = foreach ($n in 'ort', 'win', 'ca') { $f = Join-Path $script:Tmp "undo-$n.json"; Set-Content -LiteralPath $f -Value '{}'; $f }
        Add-HUMaRunStep $run 'Benannter Ort' 'Ort' $true $uf[0] 'neu'
        Add-HUMaRunStep $run 'Compliance' 'Win' $true $uf[1] 'neu'
        Add-HUMaRunStep $run 'Conditional Access' 'CA' $true $uf[2] 'neu'
        Add-HUMaRunStep $run 'Compliance' 'Gesperrt' $false '' 'Nicht angewendet'
        $global:MaOrder = @()
        Mock -ModuleName HU.MusterApply Undo-HUTransfer { param($Settings, $File, [switch]$CheckOnly) $global:MaOrder += (Split-Path $File -Leaf); if ($File -like '*win*') { throw 'inzwischen zugewiesen' }; [pscustomobject]@{ Text = 'geloescht' } }
        $res = @(Undo-HUMaRun -Settings $script:Set -File $run.File)
        $global:MaOrder | Should -Be @('undo-ca.json', 'undo-win.json', 'undo-ort.json')
        @($res | Where-Object { -not $_.Ok }).Count | Should -Be 1
        (Read-HUBackupJson $run.File).State | Should -Be 'laeuft'
        Mock -ModuleName HU.MusterApply Undo-HUTransfer { [pscustomobject]@{ Text = 'ok' } }
        [void](Undo-HUMaRun -Settings $script:Set -File $run.File)
        (Read-HUBackupJson $run.File).State | Should -Be 'rueckgaengig'
        @(Get-HUMaRuns $script:Set 'Z2').Count | Should -Be 1
        Remove-Variable -Name MaOrder -Scope Global -ErrorAction SilentlyContinue
    }
}
