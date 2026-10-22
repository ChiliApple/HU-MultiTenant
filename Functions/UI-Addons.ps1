#Requires -Version 5.1
<#
.SYNOPSIS
    Zusatzmodule in der Oberflaeche: Reiter einbauen, Token hinterlegen, beim Start im Hintergrund aktualisieren.
.NOTES
    Dot-Source aus Main.ps1 (nach Core-Addons.ps1). Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:LoadedAddons = @()

# Reiter eines (bereits gepruefen) Moduls in das Hauptfenster einbauen und die benannten Elemente registrieren
function Add-HUAddonTab($Info) {
    $x = Get-Content -LiteralPath (Join-Path $Info.Dir $Info.Xaml) -Raw -Encoding UTF8
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $x = $x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value)
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($x))
    try { $tab = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    if (-not ($tab -is [System.Windows.Controls.TabItem])) { throw 'Tab.xaml: Wurzel muss <TabItem> sein' }
    $names = @{}
    foreach ($m in [regex]::Matches($x, 'x:Name="([A-Za-z0-9_]+)"')) {
        $n = $m.Groups[1].Value
        if ($names.ContainsKey($n)) { continue }
        if ($script:Controls.ContainsKey($n)) { throw "Tab.xaml: Name '$n' gibt es im Programm schon" }
        $el = $tab.FindName($n); if ($el) { $names[$n] = $el }
    }
    foreach ($n in $names.Keys) { $script:Controls[$n] = $names[$n] }
    if (-not $tab.Name) { $tab.Name = "tabAddon$($Info.Id)" }
    if ($Info.Header -and -not $tab.Header) { $tab.Header = $Info.Header }
    if (-not $tab.Style) { try { $tab.Style = $script:Window.FindResource('DarkTabItem') } catch { } }
    $tab.Tag = 'addon'
    $script:Controls[$tab.Name] = $tab
    [void]$script:Controls['tabMain'].Items.Add($tab)
}

# Beim Start: wartende Fassungen uebernehmen, gepruefte Module laden. Gibt die zu ladenden Skripte zurueck
# (Main.ps1 laedt sie selbst per Dot-Source, damit ihre Funktionen im Programm-Bereich liegen).
function Get-HUAddonStartList {
    $dir = Get-HUAddonsDir
    try { Use-HUAddonPending $dir } catch { Write-HULogWarn "Zusatzmodule: Uebernahme fehlgeschlagen: $($_.Exception.Message)" }
    $cfg = $null; try { $cfg = Update-UpdateConfig } catch { }
    $tp = if ($cfg -and $cfg.SignerThumbprint) { $cfg.SignerThumbprint } else { $script:HMDefaultSigner }
    $ok = @()
    foreach ($i in @(Get-HUAddonsToLoad $dir ([Version]$script:Version) $tp)) {
        if ($i.Error) { Write-HULogWarn "Zusatzmodul $(if ($i.Id) { $i.Id } else { Split-Path $i.Dir -Leaf }) nicht geladen: $($i.Error)"; continue }
        $ok += $i
    }
    # Entwicklung: AddonsDev\<Id>\ wird OHNE Signatur geladen und ersetzt ein installiertes Modul gleicher Kennung.
    # Kein zusaetzliches Risiko: wer in den Programmordner schreiben kann, kann auch Main.ps1 aendern.
    $dev = Join-Path $script:AppRoot 'AddonsDev'
    if (Test-Path -LiteralPath $dev) {
        foreach ($d in @(Get-ChildItem -LiteralPath $dev -Directory -ErrorAction SilentlyContinue)) {
            $i = Read-HUAddonInfo $d.FullName
            if (-not $i.Error -and $i.Id -ne $d.Name) { $i.Error = "Ordnername '$($d.Name)' passt nicht zur Kennung '$($i.Id)'" }
            if (-not $i.Error -and [Version]$script:Version -lt $i.MinApp) { $i.Error = "braucht HU-MultiTenant $($i.MinApp)" }
            if ($i.Error) { Write-HULogWarn "Zusatzmodul $($d.Name) (Entwicklung) nicht geladen: $($i.Error)"; continue }
            $ok = @($ok | Where-Object { $_.Id -ne $i.Id })
            $ok += $i
            Write-HULogWarn "Zusatzmodul $($i.Id) $($i.Version) aus AddonsDev geladen - Entwicklung, ohne Signaturpruefung"
        }
    }
    return $ok
}

# Im Hintergrund: fuer jedes hinterlegte Modul die neueste signierte Fassung holen (wirkt nach dem Neustart)
function Start-HUAddonUpdate([switch]$Loud) {
    $src = @(Get-HUAddonSources)
    if (-not $src.Count) { if ($Loud) { Write-HULogInfo 'Zusatzmodule: keines hinterlegt' }; return }
    $cfg = $null; try { $cfg = Update-UpdateConfig } catch { }
    $tp = if ($cfg -and $cfg.SignerThumbprint) { $cfg.SignerThumbprint } else { $script:HMDefaultSigner }
    $chan = if ($cfg) { "$($cfg.Channel)" } else { 'Stable' }
    $script:AddonUpdateLoud = [bool]$Loud
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $addonLib, $sources, $dir, $ver, $chan, $tp)
        . $lib; . $addonLib
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $out = @()
        foreach ($s in @($sources)) {
            $r = Install-HUAddon -Owner $s.Owner -Repo $s.Repo -Token $s.Token -AddonsDir $dir -AppVersion ([Version]$ver) -Channel $chan -Thumbprint $tp
            $out += "$($r.Status)|$($s.Owner)/$($s.Repo)|$($r.Text)"
        }
        return ($out -join "`n")
    } -ArgumentList @($script:UpdateLib, (Join-Path $script:AppRoot 'Functions\Core-Addons.ps1'), $src, (Get-HUAddonsDir), "$($script:Version)", $chan, $tp) -TimeoutSec 300 -OnComplete {
        param($result)
        $neu = @()
        foreach ($ln in @("$result" -split "`n" | Where-Object { $_ })) {
            $p = $ln -split '\|', 3
            switch ($p[0]) {
                'Neu' { Write-HULogOK "Zusatzmodul: $($p[2])"; $neu += ($p[2] -replace ' geladen - .*$', '') }
                'Aktuell' { if ($script:AddonUpdateLoud) { Write-HULogInfo "Zusatzmodul: $($p[2])" } }
                default { Write-HULogWarn "Zusatzmodul $($p[1]): $($p[2])" }
            }
        }
        if ($neu.Count) { Show-HUAddonRestartPrompt $neu }
    }
}

# Hinweis nach dem Laden einer neuen Fassung: jetzt neu starten?
function Show-HUAddonRestartPrompt([string[]]$Names) {
    $txt = "Zusatzmodul geladen:`n`n  $($Names -join "`n  ")`n`nEs wird nach einem Neustart von HU-MultiTenant aktiv. Jetzt neu starten?"
    if (-not (Confirm-HU $txt 'Zusatzmodule')) { Write-HULogInfo 'Zusatzmodul wird beim naechsten Start geladen.'; return }
    try { if (-not (Confirm-HUQSDiscard 'neu starten')) { return } } catch { }
    Restart-HUApp
}

# HU-MultiTenant beenden und neu starten: die neue Instanz startet sofort, zeigt "wird neu gestartet" und wartet,
# bis diese beendet ist (Main.ps1 -WaitForPid). Kein Hilfsprozess mit verschluesseltem Befehl (wird von Virenschutz
# und Angriffsflaechen-Regeln gern blockiert).
function Restart-HUApp {
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $main = Join-Path $script:AppRoot 'Main.ps1'
        Start-Process -FilePath $exe -WorkingDirectory $script:AppRoot -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$main`" -WaitForPid $PID" | Out-Null
        Write-HULogOK 'HU-MultiTenant wird neu gestartet ...'
        $script:SkipCloseChecks = $true
        $script:Window.Close()
    } catch { Write-HULogError "Neustart fehlgeschlagen: $($_.Exception.Message)" }
}

# Fenster: Zusatzmodul hinterlegen (Repository + Nur-Lese-Token) oder entfernen
function Show-HUAddonDialog {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Zusatzmodule" Width="560" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="16">
        <TextBlock Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Zusatzmodule liegen in privaten Repositories. Mit dem Nur-Lese-Token, das du vom Herausgeber bekommst, laedt HU-MultiTenant das Modul und haelt es aktuell. Geladen wird nur, was mit dem Zertifikat des Herausgebers signiert ist. Der Token wird verschluesselt nur fuer deinen Windows-Benutzer gespeichert."/>
        <TextBlock Text="Hinterlegt" Foreground="#AAAAAA" FontSize="11"/>
        <ListBox x:Name="lstSrc" Height="80" Margin="0,2,0,10" Background="#252526" Foreground="#CCCCCC" BorderBrush="#3E3E42"/>
        <TextBlock Text="Repository (Besitzer/Name)" Foreground="#AAAAAA" FontSize="11"/>
        <TextBox x:Name="txtRepo" Style="{StaticResource DarkTextBox}" Margin="0,2,0,8"/>
        <TextBlock Text="Nur-Lese-Token" Foreground="#AAAAAA" FontSize="11"/>
        <PasswordBox x:Name="pwdTok" Margin="0,2,0,12" Background="#2D2D30" Foreground="White" BorderBrush="#3E3E42" Padding="4,3"/>
        <WrapPanel HorizontalAlignment="Right">
            <Button x:Name="btnDel" Content="Markiertes entfernen" Width="160" Background="#C62828" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnAdd" Content="Hinterlegen und laden" Width="170" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </WrapPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $fill = {
        $c.lstSrc.Items.Clear()
        $loaded = @($script:LoadedAddons | ForEach-Object { "$($_.Title) $($_.Version)" })
        foreach ($s in @(Get-HUAddonSources)) { [void]$c.lstSrc.Items.Add("$($s.Owner)/$($s.Repo)") }
        if ($loaded.Count) { $w.Title = "Zusatzmodule - geladen: $($loaded -join ', ')" }
    }
    & $fill
    $c.btnAdd.Add_Click({
            $parts = "$($c.txtRepo.Text)".Trim() -split '/', 2
            if ($parts.Count -ne 2 -or -not (Test-HUAddonRepoName $parts[0] $parts[1])) { Show-HUMessage 'Repository bitte als Besitzer/Name eingeben.' -Icon Info -Owner $w; return }
            if (-not $c.pwdTok.SecurePassword.Length) { Show-HUMessage 'Bitte den Token eingeben.' -Icon Info -Owner $w; return }
            try { Save-HUAddonToken $parts[0] $parts[1] $c.pwdTok.SecurePassword } catch { Show-HUMessage "Nicht gespeichert: $($_.Exception.Message)" -Icon Warning -Owner $w; return }
            $c.pwdTok.Clear(); $c.txtRepo.Text = ''
            & $fill
            Write-HULogInfo "Zusatzmodul $($parts[0])/$($parts[1]) hinterlegt - wird geladen ..."
            Start-HUAddonUpdate -Loud
        })
    $c.btnDel.Add_Click({
            $sel = "$($c.lstSrc.SelectedItem)"
            if (-not $sel) { return }
            if (-not (Confirm-HU "Token fuer $sel entfernen? Das Modul wird dann nicht mehr aktualisiert; der Ordner unter Addons bleibt, bis du ihn loeschst." 'Zusatzmodul')) { return }
            $p = $sel -split '/', 2; Remove-HUAddonToken $p[0] $p[1]; & $fill
        })
    [void]$w.ShowDialog()
}
