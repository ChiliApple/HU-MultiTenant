#Requires -Version 5.1
<#
.SYNOPSIS
    Support: sammelt Protokolle und Konfiguration (anonymisiert) in ein ZIP und oeffnet eine E-Mail
    oder ein GitHub-Issue.
.DESCRIPTION
    Anonymisiert werden: E-Mail-Adressen/UPNs, GUIDs (Tenant-, Client-, Geraete-IDs), IP-Adressen, Tokens,
    Windows-Benutzer- und Computername, Tenant-Namen und -Domaenen (-> Tenant-1, Tenant-2 ...).
    Nie enthalten: Client Secrets, GitHub-Token, Snippets, Reports, Quick-Script-Ausgaben.
    Der Inhalt kann vor dem Senden angesehen werden ("ZIP ansehen").
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

# Ersetzungsliste fuer Tenants (Name, Schluessel, Domaene -> Tenant-N)
function Get-HURedactMap {
    $map = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($t in @($script:Settings.tenants)) {
        $i++
        foreach ($v in @("$($t.displayName)", "$($t.key)", "$($t.domain)") | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending) {
            $map.Add(@{ From = $v; To = "Tenant-$i" })
        }
    }
    foreach ($v in @($env:USERNAME, $env:COMPUTERNAME, $env:USERDOMAIN) | Where-Object { $_ -and $_.Length -ge 3 }) { $map.Add(@{ From = $v; To = '<anonym>' }) }
    return $map.ToArray()
}

# Text anonymisieren (Reihenfolge: bekannte Namen, dann Muster)
function ConvertTo-HURedacted([string]$Text, [object[]]$Map = @()) {
    if (-not $Text) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]*', '<token>')
    $t = [regex]::Replace($t, '(?i)(sig|secret|password|passwort|token|key)=([^&\s"]+)', '$1=<entfernt>')
    $t = [regex]::Replace($t, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}', '<mail>')
    foreach ($m in @($Map | Sort-Object { "$($_.From)".Length } -Descending)) { $t = [regex]::Replace($t, [regex]::Escape("$($m.From)"), "$($m.To)", 'IgnoreCase') }
    $t = [regex]::Replace($t, '(?i)\b([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '$1-****')
    $t = [regex]::Replace($t, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<ip>')
    return $t
}

function Get-HUSupportInfo {
    $os = ''; try { $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $os = "$($o.Caption) $($o.Version) (Build $($o.BuildNumber))" } catch { $os = [Environment]::OSVersion.VersionString }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("HU-MultiTenant v$($script:Version)")
    try { $cfg = Update-UpdateConfig; if ($cfg) { $lines.Add("Update-Kanal: $($cfg.Channel), Quelle: $($cfg.Owner)/$($cfg.Repo)") } } catch { }
    $lines.Add("Windows: $os, $(if ([Environment]::Is64BitOperatingSystem) { '64' } else { '32' }) Bit")
    $lines.Add("PowerShell: $($PSVersionTable.PSVersion), .NET CLR $($PSVersionTable.CLRVersion), Sprache $([Globalization.CultureInfo]::CurrentUICulture.Name)")
    $lines.Add("Administrator: $(Test-AdminPrivilege), Oberflaechengroesse: $($script:UiScale)")
    $lines.Add("Windows Sandbox: $(if (Test-HUSandboxAvailable) { 'aktiviert' } else { 'nicht aktiviert' }), IntuneWinAppUtil: $(if (Get-HUIntuneWinAppUtil -AppRoot $script:AppRoot) { 'vorhanden' } else { 'fehlt' })")
    $lines.Add("ImportExcel: $(if (Get-Module -ListAvailable -Name ImportExcel) { 'vorhanden' } else { 'fehlt' })")
    $lines.Add("Tenants: $(@($script:Settings.tenants).Count), Apps in der Bibliothek: $($script:AppLib.Count), Wartungspakete: $($script:RemLib.Count)")
    $i = 0
    foreach ($t in @($script:Settings.tenants)) {
        $i++
        $p = $script:PermCache["$($t.key)"]
        $sec = ''; try { $si = Get-HUSecretInfo "$($t.key)"; if ($si) { $sec = " | $("$($si.Text)" -replace '^\S+\s', '')" } } catch { }
        $lines.Add("Tenant-$($i): Berechtigungen $(if ($p) { if ($p.Error) { "Fehler: $($p.Error)" } else { @($p.Roles | Sort-Object) -join ', ' } } else { '(nicht gelesen - Knopf Berechtigungen)' })$sec")
    }
    return $lines.ToArray()
}

# Ordner mit den Supportdateien bauen und zippen; liefert den ZIP-Pfad
function New-HUSupportZip {
    param([string]$Description = '', [hashtable]$Include = @{}, [switch]$NoAnonymize)
    $map = if ($NoAnonymize) { @() } else { Get-HURedactMap }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $root = Join-Path ([IO.Path]::GetTempPath()) "HU-Support_$stamp"
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding $true
    $put = {
        param([string]$Name, [string]$Text)
        $f = Join-Path $root $Name
        $d = Split-Path $f -Parent; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        [IO.File]::WriteAllText($f, (ConvertTo-HURedacted $Text $map), $utf8)
    }
    $tail = { param([string]$Path, [int]$MaxBytes = 2MB)
        $fi = Get-Item -LiteralPath $Path
        if ($fi.Length -le $MaxBytes) { return [IO.File]::ReadAllText($Path) }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); try { [void]$fs.Seek(-$MaxBytes, 'End'); $b = New-Object byte[] $MaxBytes; [void]$fs.Read($b, 0, $MaxBytes) } finally { $fs.Dispose() }
        return "... (gekuerzt)`r`n" + [Text.Encoding]::UTF8.GetString($b)
    }
    $readme = @("HU-MultiTenant Support-Paket $stamp", '', 'Beschreibung:', $Description, '', '--- System ---') + @(Get-HUSupportInfo)
    & $put 'info.txt' ($readme -join "`r`n")

    if ($Include.Logs) {
        $logDir = Join-Path $script:AppRoot 'Logs'
        foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter 'HU-MultiTenant_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
            try { & $put "Logs\$($f.Name)" (& $tail $f.FullName) } catch { }
        }
        foreach ($n in 'rtbApps', 'rtbRem', 'rtbLog') {
            $r = $script:Controls[$n]
            if ($r) { try { & $put "Ausgabe\$n.txt" ((New-Object System.Windows.Documents.TextRange($r.Document.ContentStart, $r.Document.ContentEnd)).Text) } catch { } }
        }
    }
    if ($Include.Sandbox) {
        $sb = Join-Path (Join-Path $env:LOCALAPPDATA 'HU-MultiTenant') 'Sandbox'
        foreach ($d in @(Get-ChildItem -LiteralPath $sb -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
            $app = Get-HUAppById $d.Name
            $label = if ($app) { ($app.Name -replace '[\\/:*?"<>|]', '_') } else { $d.Name.Substring(0, 8) }
            foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Include *.json, *.log, *.txt -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 5MB })) {
                try { & $put ("Testinstallation\$label\" + $f.FullName.Substring($d.FullName.Length + 1)) (& $tail $f.FullName) } catch { }
            }
        }
    }
    if ($Include.Library) {
        $f = Join-Path $script:AppRoot 'Config\apps.json'
        if (Test-Path -LiteralPath $f) { & $put 'Konfiguration\apps.json' ([IO.File]::ReadAllText($f)) }
    }
    if ($Include.Maint) {
        $f = Join-Path $script:AppRoot 'Config\remediations.json'
        if (Test-Path -LiteralPath $f) { & $put 'Konfiguration\remediations.json' ([IO.File]::ReadAllText($f)) }
    }
    if ($Include.Settings) {
        $s = Get-Content (Join-Path $script:AppRoot 'Config\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $i = 0
        foreach ($t in @($s.tenants)) { $i++; foreach ($p in @($t.PSObject.Properties)) { if ($p.Name -match '(?i)secret|password|cert|thumb') { $t.PSObject.Properties.Remove($p.Name) } } }
        & $put 'Konfiguration\settings.json' ($s | ConvertTo-Json -Depth 8)
        foreach ($n in 'version.json', 'update.json', 'installed.json') {
            $f = Join-Path $script:AppRoot "Config\$n"
            if (Test-Path -LiteralPath $f) { & $put "Konfiguration\$n" ((Get-Content -LiteralPath $f -Raw -Encoding UTF8) -replace '(?i)"[^"]*token[^"]*"\s*:\s*"[^"]*"', '"token": "<entfernt>"') }
        }
    }
    $zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "HU-MultiTenant-Support_$stamp.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $zip)
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    return $zip
}

function Send-HUSupportMail([string]$To, [string]$Subject, [string]$Body, [string]$Zip) {
    # klassisches Outlook: Entwurf mit Anhang; sonst Standard-Mailprogramm ohne Anhang + Explorer mit ZIP
    try {
        $o = New-Object -ComObject Outlook.Application -ErrorAction Stop
        $m = $o.CreateItem(0)
        if ($To) { $m.To = $To }
        $m.Subject = $Subject; $m.Body = $Body
        [void]$m.Attachments.Add($Zip)
        $m.Display()
        return 'outlook'
    } catch { }
    $u = "mailto:$([uri]::EscapeDataString($To))?subject=$([uri]::EscapeDataString($Subject))&body=$([uri]::EscapeDataString($Body + "`r`n`r`n(Bitte die ZIP-Datei vom Desktop anhaengen: $(Split-Path $Zip -Leaf))"))"
    Open-HUUrl $u
    try { Start-Process explorer.exe -ArgumentList "/select,`"$Zip`"" } catch { }
    return 'mailto'
}

function Show-HUSupport {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Support" Width="640" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock Text="&#x1F6DF; Support anfragen" Foreground="#4FC3F7" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <TextBlock Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Packt Protokolle und Einstellungen in ein ZIP auf dem Desktop. Namen von Tenants, Domaenen, Benutzern (E-Mail/UPN), IDs, IP-Adressen und dein Windows-Benutzer werden ersetzt. Nie enthalten: Client Secrets, Tokens, Snippets, Reports, Quick-Script-Ausgaben."/>
        <TextBlock Text="Was ist passiert? (Schritte, Fehlermeldung, erwartetes Ergebnis)" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <TextBox x:Name="txtDesc" Style="{StaticResource DarkTextBox}" AcceptsReturn="True" TextWrapping="Wrap" Height="90" VerticalScrollBarVisibility="Auto"/>
        <TextBlock Text="Mitsenden" Style="{StaticResource SectionTitle}" Margin="0,10,0,4"/>
        <WrapPanel>
            <CheckBox x:Name="chkLogs" Content="Protokolle (3 Tage) und Ausgaben" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,2,16,2"/>
            <CheckBox x:Name="chkSandbox" Content="Testinstallationen (Sandbox)" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,2,16,2"/>
            <CheckBox x:Name="chkSettings" Content="Einstellungen (ohne Secrets)" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,2,16,2"/>
            <CheckBox x:Name="chkLibrary" Content="App-Bibliothek (Befehle, Erkennung)" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,2,16,2"/>
            <CheckBox x:Name="chkMaint" Content="Wartungsskripte" Style="{StaticResource DarkCheckBox}" Margin="0,2,16,2"/>
        </WrapPanel>
        <CheckBox x:Name="chkAnon" Content="Anonymisieren (empfohlen)" IsChecked="True" Style="{StaticResource DarkCheckBox}" Margin="0,8,0,0"/>
        <DockPanel Margin="0,10,0,0">
            <TextBlock Text="E-Mail an" Style="{StaticResource FieldLabel}" Width="80"/>
            <TextBox x:Name="txtTo" Style="{StaticResource DarkTextBox}"/>
        </DockPanel>
        <TextBlock x:Name="lblState" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <WrapPanel HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="btnView" Content="ZIP erstellen und ansehen" Style="{StaticResource ToolButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnIssue" Content="GitHub-Issue ..." Background="#3E3E42" Style="{StaticResource DarkButton}" Margin="0,0,8,0"
                    ToolTip="Oeffnet ein neues Issue im Browser (mit deinem GitHub-Konto) - mit Beschreibung und Systeminfo, ohne Protokolle"/>
            <Button x:Name="btnMail" Content="Per E-Mail senden" Background="#1976D2" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Schliessen" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </WrapPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $c.txtTo.Text = "$(Get-HUStateValue 'supportMail' '')"
    $state = @{ Zip = '' }
    $build = {
        $old = $w.Cursor; $w.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $inc = @{ Logs = [bool]$c.chkLogs.IsChecked; Sandbox = [bool]$c.chkSandbox.IsChecked; Settings = [bool]$c.chkSettings.IsChecked; Library = [bool]$c.chkLibrary.IsChecked; Maint = [bool]$c.chkMaint.IsChecked }
            $state.Zip = New-HUSupportZip -Description $c.txtDesc.Text.Trim() -Include $inc -NoAnonymize:(-not $c.chkAnon.IsChecked)
            $c.lblState.Text = "Erstellt: $($state.Zip) ($([Math]::Round((Get-Item -LiteralPath $state.Zip).Length / 1KB)) KB)"
            return $true
        } catch { Show-HUMessage "ZIP konnte nicht erstellt werden:`n$($_.Exception.Message)" -Icon Error -Owner $w; return $false }
        finally { $w.Cursor = $old }
    }
    $c.btnView.Add_Click({ if (& $build) { try { Start-Process explorer.exe -ArgumentList "/select,`"$($state.Zip)`"" } catch { } } })
    $c.btnMail.Add_Click({
            if (-not $c.txtDesc.Text.Trim()) { Show-HUMessage 'Bitte kurz beschreiben, was passiert ist.' -Icon Warning -Owner $w; return }
            if (-not (& $build)) { return }
            Set-HUStateValue 'supportMail' $c.txtTo.Text.Trim()
            $how = Send-HUSupportMail -To $c.txtTo.Text.Trim() -Subject "HU-MultiTenant v$($script:Version) - Support" -Body ($c.txtDesc.Text.Trim() + "`r`n`r`n--`r`nHU-MultiTenant v$($script:Version)") -Zip $state.Zip
            $c.lblState.Text = $(if ($how -eq 'outlook') { 'Outlook-Entwurf mit Anhang geoeffnet.' } else { "E-Mail geoeffnet - bitte die ZIP-Datei vom Desktop anhaengen ($(Split-Path $state.Zip -Leaf))." })
        })
    $c.btnIssue.Add_Click({
            if (-not $c.txtDesc.Text.Trim()) { Show-HUMessage 'Bitte kurz beschreiben, was passiert ist.' -Icon Warning -Owner $w; return }
            $cfg = $null; try { $cfg = Update-UpdateConfig } catch { }
            $owner = if ($cfg -and $cfg.Owner) { $cfg.Owner } else { 'ChiliApple' }; $repo = if ($cfg -and $cfg.Repo) { $cfg.Repo } else { 'HU-MultiTenant' }
            $map = Get-HURedactMap
            $body = (ConvertTo-HURedacted $c.txtDesc.Text.Trim() $map) + "`n`n### System`n``````n" + ((Get-HUSupportInfo | ForEach-Object { ConvertTo-HURedacted $_ $map }) -join "`n") + "`n``````"
            if ($body.Length -gt 6000) { $body = $body.Substring(0, 6000) }
            $first = ($c.txtDesc.Text.Trim() -split "`r?`n")[0]; if ($first.Length -gt 70) { $first = $first.Substring(0, 70) + ' ...' }
            if (-not (Confirm-HU "Issues sind oeffentlich sichtbar.`n`nIm Browser wird ein neues Issue mit deiner Beschreibung und der (anonymisierten) Systeminfo vorbereitet - ohne Protokolle. Das ZIP nur anhaengen, wenn du den Inhalt vorher angesehen hast.`n`nWeiter?" -Owner $w)) { return }
            Open-HUUrl "https://github.com/$owner/$repo/issues/new?title=$([uri]::EscapeDataString("[v$($script:Version)] " + (ConvertTo-HURedacted $first $map)))&body=$([uri]::EscapeDataString($body))"
        })
    $c.btnCancel.Add_Click({ $w.Close() })
    $w.Add_ContentRendered({ $c.txtDesc.Focus() | Out-Null })
    [void]$w.ShowDialog()
}
