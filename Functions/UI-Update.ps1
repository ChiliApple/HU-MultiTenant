#Requires -Version 5.1
<#
.SYNOPSIS
    Update (GitHub-Releases, Kanal Stabil/Test, Pruefsumme + Signatur), Info-Fenster, Anleitung (F1),
    Release signieren / freigeben (nur Herausgeber).
.DESCRIPTION
    Gleicher Ablauf wie HUMig und HU-AdminTool:
      - Start: Pruefung im Hintergrund, bei neuer Version wird der Knopf 'Update' gold
      - Klick: Pull.ps1 (wartet auf Tool-Ende, laedt + prueft ALLE Dateien, ersetzt erst dann, startet neu)
      - Rechtsklick: andere Version / Einstellungen / jetzt pruefen / Info / Anleitung / GitHub-Token / signieren / freigeben
    Einstellungen: Config\update.json (Kanal, Signaturpflicht, Quelle). Installierte Version: Config\installed.json.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:ConfigDir = Join-Path $script:AppRoot 'Config'
$script:UpdateLib = Join-Path $script:AppRoot 'Functions\Core-Update.ps1'
$script:UpdateCfg = $null
$script:UpdateAvailable = $false
$script:UpdateRemoteVer = ''

function Update-UpdateConfig {
    if (-not (Get-Command Get-HMUpdateConfig -ErrorAction SilentlyContinue)) { return $null }
    $script:UpdateCfg = Get-HMUpdateConfig $script:ConfigDir
    return $script:UpdateCfg
}
function Format-HUChannel([string]$Channel) { if ($Channel -eq 'Test') { 'Test' } elseif ($Channel -eq 'Branch') { 'Entwicklung (Branch)' } else { 'Stabil' } }

function Get-GitHubTokenFile {
    $u = ("$($env:USERDOMAIN)_$($env:USERNAME)" -replace '[^\w\.\-]', '_')
    return (Join-Path $script:ConfigDir "GitHubToken_$u.xml")
}
function Read-GitHubToken {
    if ("$env:HU_GITHUB_TOKEN".Trim()) { return "$env:HU_GITHUB_TOKEN".Trim() }
    $f = Get-GitHubTokenFile
    if (Test-Path -LiteralPath $f) {
        try { $c = Import-Clixml -Path $f -ErrorAction Stop; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { }
    }
    return ''
}
function Save-GitHubTokenFromPrompt([string]$File, [string]$Message) {
    $c = $null
    try { $c = Get-Credential -UserName 'github' -Message $Message } catch { $c = $null }
    if (-not $c -or -not $c.GetNetworkCredential().Password.Trim()) { Write-HULogWarn 'Kein Token eingegeben'; return $false }
    try {
        $d = Split-Path $File -Parent
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $c | Export-Clixml -Path $File -Force -ErrorAction Stop
        return $true
    } catch { Write-HULogError "Token nicht gespeichert: $($_.Exception.Message)"; return $false }
}
function Get-HUInstalledInfo { return (Read-HUJsonFile (Join-Path $script:ConfigDir 'installed.json')) }

function Set-HUUpdateButton([string]$RemoteVer = '', [bool]$Pre = $false) {
    $b = $script:Controls['btnUpdate']
    if ($RemoteVer) {
        $b.Content = "Update v$RemoteVer$(if ($Pre) { ' (Test)' })"
        $b.Background = [System.Windows.Media.Brushes]::Gold
        $b.Foreground = Get-HUBrush '#1E1E1E'
        $b.FontWeight = 'Bold'
    } else {
        $b.Content = 'Update'
        $b.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
        $b.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
        $b.ClearValue([System.Windows.Controls.Control]::FontWeightProperty)
    }
}

# Update-Pruefung im Hintergrund. -Quiet: nur bei neuer Version etwas protokollieren
function Invoke-UpdateCheck([switch]$Quiet) {
    $cfg = Update-UpdateConfig
    if (-not $cfg) { Write-HULogWarn 'Update-Pruefung: Functions\Core-Update.ps1 fehlt - Pull.ps1 ausfuehren'; return }
    $script:UpdateQuiet = [bool]$Quiet
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $token, $cfg)
        try {
            . $lib
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            if ($cfg.UseBranch) {
                $h = @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HU-MultiTenant' }
                if ($token) { $h['Authorization'] = "token $token" }
                $r = Invoke-WebRequest "https://api.github.com/repos/$($cfg.Owner)/$($cfg.Repo)/contents/Config/version.json?ref=$($cfg.Branch)" -Headers $h -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                $text = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
                $v = ($text | ConvertFrom-Json).version
                if ($v) { return "REL:$v|Branch $($cfg.Branch)|False" }
                return 'ERR:Version im Branch nicht gefunden'
            }
            $rel = Select-HMRelease @(Get-HMReleases $cfg.Owner $cfg.Repo $token) $cfg.Channel -SignedOnly:$cfg.RequireSignature
            if (-not $rel) { return 'NONE' }
            return "REL:$($rel.Version)|$($rel.Tag)|$($rel.Prerelease)"
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -in 401, 403, 404) { return "AUTH:$code|$([bool]$token)" }
            return "ERR:$($_.Exception.Message)"
        }
    } -ArgumentList @($script:UpdateLib, (Read-GitHubToken), $cfg) -TimeoutSec 45 -OnComplete {
        param($result)
        $r = "$result".Trim()
        $cfg = $script:UpdateCfg
        $chan = if ($cfg.UseBranch) { "Branch $($cfg.Branch)" } else { "Kanal $(Format-HUChannel $cfg.Channel)" }
        if ($r -match '^REL:([^|]+)\|([^|]*)\|(True|False)$') {
            $remote = $Matches[1].Trim(); $pre = ($Matches[3] -eq 'True')
            $cmp = 0
            try { $cmp = ([Version]$remote).CompareTo([Version]$script:Version) } catch { $cmp = 0 }
            if ($cmp -gt 0) {
                $script:UpdateAvailable = $true; $script:UpdateRemoteVer = $remote
                Write-HULogWarn "UPDATE VERFUEGBAR: v$remote$(if ($pre) { ' (Test)' }) - installiert v$($script:Version), $chan - Knopf 'Update' oben rechts"
                Set-HUUpdateButton $remote $pre
            } else {
                $script:UpdateAvailable = $false
                if (-not $script:UpdateQuiet) { Write-HULogOK "Version aktuell: v$($script:Version) ($chan$(if ($cfg.RequireSignature) { ', nur signierte Updates' }))" }
                Set-HUUpdateButton
            }
        } elseif ($r -eq 'NONE') {
            if (-not $script:UpdateQuiet) { Write-HULogInfo "Update-Pruefung: kein $(if ($cfg.RequireSignature) { 'signiertes ' })Release im $chan" }
        } elseif ($r -match '^AUTH:(\d+)\|(True|False)$') {
            if (-not $script:UpdateQuiet -or $Matches[2] -eq 'True') { Write-HULogWarn "Update-Pruefung: $($cfg.Owner)/$($cfg.Repo) nicht erreichbar (HTTP $($Matches[1]))$(if ($Matches[2] -eq 'True') { ' - gespeicherter GitHub-Token abgelehnt' } else { ' - privates Repo? Rechtsklick auf Update > GitHub-Token' })" }
        } else {
            if (-not $script:UpdateQuiet) { Write-HULogWarn "Update-Pruefung: $($r -replace '^(ERR:|FEHLER:)\s*', '')" } else { Write-HULogDebug "Update-Pruefung: $r" }
        }
    }
}

function Start-HUPull([string]$Version = '') {
    $pullScript = Join-Path $script:AppRoot 'Pull.ps1'
    if (-not (Test-Path -LiteralPath $pullScript)) { Write-HULogError "Pull.ps1 nicht gefunden: $pullScript"; return }
    $cfg = Update-UpdateConfig
    $what = if ($Version) { "Version $Version" }
            elseif ($cfg -and $cfg.UseBranch) { "den Entwicklungsstand (Branch $($cfg.Branch), ohne Pruefsumme)" }
            elseif ($script:UpdateAvailable) { "v$($script:UpdateRemoteVer)" }
            else { "die neueste Version im Kanal $(Format-HUChannel $(if ($cfg) { $cfg.Channel } else { 'Stable' }))" }
    $check = if ($cfg -and $cfg.RequireSignature -and -not $cfg.UseBranch) { 'Pruefsumme + Signatur werden geprueft' } elseif ($cfg -and $cfg.UseBranch) { 'OHNE Pruefung' } else { 'Pruefsumme wird geprueft' }
    if (-not (Confirm-HU "HU-MultiTenant schliessen, $what von GitHub laden und neu starten?`n`n  Installiert:  v$($script:Version)`n  $check`n`nEinstellungen, Snippets und Secrets bleiben erhalten.$(if (Test-HUQSDirty) { "`n`nACHTUNG: Das Snippet im Editor hat ungespeicherte Aenderungen!" })" 'Update')) { return }
    if (-not (Confirm-HUQSDiscard 'aktualisieren')) { return }
    try {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$pullScript`" -Target `"$($script:AppRoot)`" -WaitPid $PID"
        if ($Version) { $argLine += " -Version $Version" }
        Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $script:AppRoot | Out-Null
        Write-HULogOK 'Update gestartet - HU-MultiTenant wird beendet und neu gestartet.'
        $script:SkipCloseChecks = $true
        $script:Window.Close()
    } catch { Write-HULogError "Update-Start fehlgeschlagen: $($_.Exception.Message)" }
}

# Einfaches Auswahlfenster mit Tabelle (Versionen). Rueckgabe: gewaehlte Zeile oder $null
function Show-HUTableDialog {
    param([string]$Title, [string]$Hint, [object[]]$Rows, [string]$OkText = 'OK', [int]$Width = 900, [int]$Height = 480)
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="12">
        <TextBlock x:Name="lblHint" DockPanel.Dock="Top" Style="{StaticResource HintText}" FontSize="11" Margin="0,0,0,8"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="btnOk" Width="200" Background="#4CAF50" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="True"/>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = $Title; $w.Width = $Width; $w.Height = $Height
    $c.lblHint.Text = $Hint
    $c.btnOk.Content = $OkText
    $c.grid.ItemsSource = @($Rows)
    $st = @{ Sel = $null }
    $c.btnOk.Add_Click({ if ($c.grid.SelectedItem) { $st.Sel = $c.grid.SelectedItem; $w.Close() } })
    $c.grid.Add_MouseDoubleClick({ if ($c.grid.SelectedItem) { $st.Sel = $c.grid.SelectedItem; $w.Close() } })
    [void]$w.ShowDialog()
    return $st.Sel
}

function Show-HUVersionPicker {
    $cfg = Update-UpdateConfig
    if (-not $cfg) { Write-HULogError 'Functions\Core-Update.ps1 fehlt - Pull.ps1 ausfuehren'; return }
    Write-HULogInfo 'Versionen werden von GitHub gelesen ...'
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $token, $owner, $repo)
        try {
            . $lib
            $l = @(Get-HMReleases $owner $repo $token | ForEach-Object {
                [pscustomobject]@{ Version = "$($_.Version)"; Tag = $_.Tag; Prerelease = [bool]$_.Prerelease; Date = $_.Date; Notes = $_.Notes; Manifest = [bool]$_.ManifestUrl; Signature = [bool]$_.SignatureUrl }
            })
            return ('LIST:' + (ConvertTo-Json -InputObject @($l) -Compress -Depth 3))
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            if ($code -in 401, 403, 404) { return "ERR:Repo nicht erreichbar (HTTP $code)" }
            return "ERR:$($_.Exception.Message)"
        }
    } -ArgumentList @($script:UpdateLib, (Read-GitHubToken), $cfg.Owner, $cfg.Repo) -TimeoutSec 40 -OnComplete {
        param($result)
        $r = "$result".Trim()
        if ($r -notmatch '^LIST:') { Write-HULogError "Versionen nicht lesbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"; return }
        $list = @()
        try { $list = @(($r.Substring(5) | ConvertFrom-Json) | Where-Object { $_ -and $_.Version }) } catch { Write-HULogError "Versionsliste nicht lesbar: $($_.Exception.Message)"; return }
        if (-not $list.Count) { Write-HULogWarn 'Keine Releases gefunden.'; return }
        $rows = foreach ($x in $list) {
            $cmp = 0; try { $cmp = ([Version]"$($x.Version)").CompareTo([Version]$script:Version) } catch { }
            $first = @("$($x.Notes)" -split "`r?`n" | Where-Object { "$_".Trim() -and "$_" -notmatch '^\s*#' } | ForEach-Object { ("$_".Trim().TrimStart('-', ' ', '*') -replace '\*\*|`', '') })[0]
            [pscustomobject][ordered]@{
                Version = "$($x.Version)"; Kanal = $(if ($x.Prerelease) { 'Test' } else { 'Stabil' })
                Stand = $(if ($cmp -eq 0) { 'installiert' } elseif ($cmp -lt 0) { 'aelter' } else { 'neuer' })
                Datum = "$($x.Date)"; Pruefsumme = $(if ($x.Manifest) { 'ja' } else { 'nein' }); Signatur = $(if ($x.Signature) { 'ja' } else { 'nein' }); Aenderungen = "$first"
            }
        }
        $sel = Show-HUTableDialog -Title 'HU-MultiTenant - Version waehlen' -OkText 'Diese Version installieren' -Rows @($rows) `
            -Hint "Installiert: v$($script:Version). Version markieren, dann installieren. Einstellungen, Snippets und Secrets bleiben erhalten.$(if ($script:UpdateCfg.RequireSignature) { ' Nur signierte Versionen sind installierbar.' })"
        if (-not $sel) { return }
        if ($script:UpdateCfg.RequireSignature -and $sel.Signatur -ne 'ja') { Show-HUMessage "Version $($sel.Version) ist nicht signiert und kann nicht installiert werden (Einstellungen > Update)." -Icon Warning; return }
        Start-HUPull -Version $sel.Version
    }
}

# --- Herausgeber: Release signieren / freigeben (Zertifikat mit privatem Schluessel nur auf dessen PC) ---
# Schreib-Token zum Signieren/Freigeben: Hauptprogramm wie bisher, Zusatzmodul-Repositories je eigener Datei
function Get-HUSignTokenFile([string]$Owner = '', [string]$Repo = '') {
    if ($Repo) { return (Join-Path $env:APPDATA "HU-MultiTenant\GitHubSignToken-$Owner`_$Repo.xml") }
    return (Join-Path $env:APPDATA 'HU-MultiTenant\GitHubSignToken.xml')
}
function Read-HUSignToken([string]$Owner = '', [string]$Repo = '') {
    $f = Get-HUSignTokenFile $Owner $Repo
    if (Test-Path -LiteralPath $f) { try { $c = Import-Clixml -Path $f; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { } }
    return ''
}
function Test-HUCanSign {
    $c = Update-UpdateConfig
    if (-not $c -or -not (Get-Command Get-HMSigningCert -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Get-HMSigningCert $c.SignerThumbprint)
}
function Get-HUSignTokenOrPrompt([object]$Cfg, [switch]$Addon) {
    $o = if ($Addon) { "$($Cfg.Owner)" } else { '' }; $r = if ($Addon) { "$($Cfg.Repo)" } else { '' }
    $tok = Read-HUSignToken $o $r
    if ($tok) { return $tok }
    if (-not (Save-GitHubTokenFromPrompt (Get-HUSignTokenFile $o $r) "GitHub-Token mit Schreibrecht fuer $($Cfg.Owner)/$($Cfg.Repo) (Fine-grained PAT, 'Contents: Read and write'). Wird verschluesselt nur fuer deinen Windows-Benutzer gespeichert.")) { return '' }
    return (Read-HUSignToken $o $r)
}

# Zusatzmodul-Repository zum Signieren/Freigeben waehlen (nur hinterlegte Module); $null = abgebrochen
function Select-HUAddonSignTarget([string]$What) {
    $src = @(Get-HUAddonSources)
    if (-not $src.Count) { Show-HUMessage 'Kein Zusatzmodul hinterlegt (Rechtsklick auf Update > Zusatzmodule ...).' 'Zusatzmodul' -Icon Info; return $null }
    foreach ($s in $src) {
        if ($src.Count -eq 1 -or (Confirm-HU "$What fuer $($s.Owner)/$($s.Repo)?" 'Zusatzmodul')) { return $s }
    }
    return $null
}

# Signieren/Freigeben: ins Protokoll UND in die Ausgabe des gerade offenen Reiters (ohne Reiterwechsel)
function Write-HUPub([string]$Text, [ValidateSet('OK', 'WARN', 'ERROR', 'INFO')][string]$Level = 'INFO') {
    switch ($Level) { 'OK' { Write-HULogOK $Text } 'WARN' { Write-HULogWarn $Text } 'ERROR' { Write-HULogError $Text } default { Write-HULogInfo $Text } }
    try {
        $c = $script:Controls
        $map = @{ tabQuickScript = 'rtbQSOutput'; tabApps = 'rtbApps'; tabMaint = 'rtbRem'; tabAnalyse = 'rtbAna' }
        $sel = $c['tabMain'].SelectedItem
        foreach ($k in $map.Keys) {
            if ($c[$k] -and $sel -eq $c[$k] -and $c[$map[$k]]) {
                $col = switch ($Level) { 'OK' { '#81C784' } 'WARN' { '#FFB74D' } 'ERROR' { '#FF5252' } default { '#CCCCCC' } }
                Add-HURtbLine $c[$map[$k]] "[$((Get-Date).ToString('HH:mm:ss'))] $Text" $col
            }
        }
    } catch { }
}

# --- Warten auf das neue Release: Nach dem Merge laufen erst die automatischen Tests (einige Minuten),
# erst danach gibt es das Release mit Pruefsummen-Datei. Bis dahin hiess es frueher "Nichts zu signieren". ---
$script:RelWait = $null
$script:RelWaitTimer = $null
function Start-HUReleaseWait($Ctx) {
    $script:RelWait = $Ctx
    if (-not $script:RelWaitTimer) {
        $t = [System.Windows.Threading.DispatcherTimer]::new()
        $t.Interval = [TimeSpan]::FromSeconds(20)
        $t.Add_Tick({ Update-HUReleaseWait })
        $script:RelWaitTimer = $t
    }
    $script:RelWaitTimer.Start()
    Write-HUPub "Warte auf das neue Release von $($Ctx.Owner)/$($Ctx.Repo) (Abfrage alle 20 s, hoechstens 15 Min.). Erneut 'Release signieren' bricht das Warten ab." INFO
}
function Stop-HUReleaseWait {
    if ($script:RelWaitTimer) { $script:RelWaitTimer.Stop() }
    $script:RelWait = $null
}
function Update-HUReleaseWait {
    $w = $script:RelWait
    if (-not $w) { Stop-HUReleaseWait; return }
    if ($w.Busy) { return }
    if (((Get-Date) - $w.Started).TotalMinutes -gt 15) {
        Stop-HUReleaseWait
        $msg = "Nach 15 Minuten gibt es noch kein neues Release mit Pruefsummen-Datei ($($w.Owner)/$($w.Repo)).`n`nAuf GitHub unter 'Actions' nachsehen, ob die automatischen Tests noch laufen oder fehlgeschlagen sind. Danach erneut 'Release signieren'."
        Write-HUPub 'Warten beendet: nach 15 Minuten noch kein neues Release.' WARN
        Show-HUMessage $msg 'Release signieren' -Icon Warning
        return
    }
    $w.Busy = $true
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $tok, $owner, $repo)
        try { . $lib; $st = Get-HMMainBuildState $owner $repo $tok; return "ST:$(Get-HMBuildWaitState $st)|$($st.Tag)|$($st.AgeMin)" }
        catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:UpdateLib, $w.Token, $w.Owner, $w.Repo) -TimeoutSec 40 -OnComplete {
        param($res)
        $w = $script:RelWait
        if (-not $w) { return }
        $w.Busy = $false
        $s = "$res".Trim()
        if ($s -match '^ST:Ready\|([^|]*)\|') {
            $tag = $Matches[1]; Stop-HUReleaseWait
            Write-HUPub "$tag ist da (mit Pruefsummen-Datei) - weiter mit Signieren." OK
            Start-HUReleaseSigning -Addon:$w.Addon -Target $w.Target
            return
        }
        if ($s -match '^ST:None') {
            Stop-HUReleaseWait
            $msg = "Fuer den neuesten Stand auf main entsteht kein Release: Entweder wurde die Version nicht erhoeht, oder die automatischen Tests sind fehlgeschlagen (auf GitHub unter 'Actions' nachsehen)."
            Write-HUPub $msg WARN; Show-HUMessage $msg 'Release signieren' -Icon Warning
            return
        }
        if ($s -match '^ST:Building\|[^|]*\|(\d+)') { Write-HUPub "Noch nicht fertig (Merge vor $($Matches[1]) Min.) - warte weiter ..." INFO; return }
        Write-HUPub "Abfrage fehlgeschlagen, versuche es weiter: $($s -replace '^ERR:\s*', '')" WARN
    }
}

function Start-HUReleaseSigning([switch]$Addon, [object]$Target = $null) {
    if ($script:RelWait) {
        if (Confirm-HU "Es wird noch auf das neue Release von $($script:RelWait.Owner)/$($script:RelWait.Repo) gewartet.`n`nWarten abbrechen?" 'Release signieren') { Stop-HUReleaseWait; Write-HUPub 'Warten auf das neue Release abgebrochen.' WARN } # Warnung: nein - nur Warten; signiert wird erst nach eigener Rueckfrage
        return
    }
    $cfg = Update-UpdateConfig
    if (-not $cfg) { return }
    if ($Addon) {
        $t = $(if ($Target) { $Target } else { Select-HUAddonSignTarget 'Release signieren' }); if (-not $t) { return }
        $cfg = [pscustomobject]@{ Owner = $t.Owner; Repo = $t.Repo; SignerThumbprint = $cfg.SignerThumbprint }
    }
    Write-HUPub "=== Release signieren ($($cfg.Owner)/$($cfg.Repo)) ===" INFO
    $cert = Get-HMSigningCert $cfg.SignerThumbprint
    if (-not $cert) {
        Write-HUPub "Signatur-Zertifikat $($cfg.SignerThumbprint) mit privatem Schluessel ist auf diesem PC nicht vorhanden (oder abgelaufen)." ERROR
        Show-HUMessage "Signatur-Zertifikat $($cfg.SignerThumbprint) mit privatem Schluessel ist auf diesem PC nicht vorhanden (oder abgelaufen)." 'Release signieren' -Icon Error
        return
    }
    Write-HUPub "Zertifikat: $($cert.Subject) - gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy'))" INFO
    $tok = Get-HUSignTokenOrPrompt $cfg -Addon:$Addon
    if (-not $tok) { Write-HUPub 'Abgebrochen: kein GitHub-Token mit Schreibrecht.' WARN; return }
    $script:SignCtx = [pscustomobject]@{ Owner = $cfg.Owner; Repo = $cfg.Repo; Thumb = $cfg.SignerThumbprint; Token = $tok; Addon = [bool]$Addon }
    Write-HUPub 'Releases werden gelesen ...' INFO
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $tok, $owner, $repo)
        try {
            . $lib
            $all = @(Get-HMReleases $owner $repo $tok)
            $l = @($all | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl } | ForEach-Object { "$($_.Tag)" })
            $noMan = @($all | Where-Object { -not $_.ManifestUrl } | Select-Object -First 5 | ForEach-Object { "$($_.Tag)" })
            $newest = @($all | Select-Object -First 1)[0]
            $nInfo = if ($newest) { "$($newest.Tag) ($(if ($newest.Prerelease) { 'Vorab' } else { 'freigegeben' }), $(if ($newest.SignatureUrl) { 'signiert' } elseif ($newest.ManifestUrl) { 'nicht signiert' } else { 'ohne Pruefsumme' }))" } else { '-' }
            # wird main gerade gebaut? (Fehler hier stoeren das Signieren nicht)
            $b = 'None;0'
            try { $st = Get-HMMainBuildState $owner $repo $tok; $b = "$(Get-HMBuildWaitState $st);$($st.AgeMin)" } catch { }
            return ('TAGS:' + ($l -join ',') + '|' + ($noMan -join ',') + '|' + $nInfo + '|' + $b)
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:UpdateLib, $tok, $cfg.Owner, $cfg.Repo) -TimeoutSec 40 -OnComplete {
        param($result)
        $r = "$result".Trim()
        if ($r -notmatch '^TAGS:([^|]*)\|([^|]*)\|([^|]*)\|(\w+);(\d+)$') {
            $msg = "Releases nicht lesbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"
            Write-HUPub $msg ERROR; Show-HUMessage $msg 'Release signieren' -Icon Error
            $script:SignCtx = $null; return
        }
        $tags = @($Matches[1] -split ',' | Where-Object { $_ }); $noMan = "$($Matches[2])"; $newest = "$($Matches[3])"; $build = "$($Matches[4])"; $age = "$($Matches[5])"
        Write-HUPub "Neuestes Release: $newest" INFO
        if ($noMan) { Write-HUPub "Ohne Pruefsummen-Datei (automatische Tests noch nicht fertig oder fehlgeschlagen): $noMan" WARN }
        if (-not $tags.Count -and $build -eq 'Building') {
            # Merge ist erst ein paar Minuten her: Release kommt erst nach den automatischen Tests
            $sc = $script:SignCtx; $script:SignCtx = $null
            Write-HUPub "Neue Version wird gerade gebaut (Merge vor $age Min.)." INFO
            if (Confirm-HU "Die neue Version wird gerade gebaut: Die automatischen Tests laufen seit $age Min. (meist 6 bis 8 Min.). Erst danach legt GitHub das Release mit Pruefsummen-Datei an.`n`nWarten und dann signieren?`n`n(Die App fragt alle 20 Sekunden nach, hoechstens 15 Minuten. Vor dem Signieren kommt wie immer die Rueckfrage.)" 'Release signieren') { # Warnung: nein - nur Warten; signiert wird erst nach eigener Rueckfrage
                $tgt = $(if ($sc.Addon) { [pscustomobject]@{ Owner = $sc.Owner; Repo = $sc.Repo } } else { $null })
                Start-HUReleaseWait ([pscustomobject]@{ Owner = $sc.Owner; Repo = $sc.Repo; Token = $sc.Token; Addon = [bool]$sc.Addon; Target = $tgt; Started = Get-Date; Busy = $false })
            } else { Write-HUPub 'Nicht gewartet.' WARN }
            return
        }
        if (-not $tags.Count) {
            $msg = "Nichts zu signieren - alle Releases mit Pruefsumme sind bereits signiert.`n`nNeuestes Release: $newest$(if ($noMan) { "`nOhne Pruefsumme: $noMan" })`n`nEine neue Version entsteht erst mit dem Merge nach main (danach ein paar Minuten warten, bis die automatischen Tests die Pruefsummen-Datei angehaengt haben)."
            Write-HUPub 'Nichts zu signieren - alle Releases mit Pruefsumme sind bereits signiert.' OK
            Show-HUMessage $msg 'Release signieren'
            $script:SignCtx = $null; return
        }
        Write-HUPub "Nicht signiert: $($tags -join ', ')" INFO
        if (-not (Confirm-HU -Warning "Diese Releases jetzt signieren?`n`n$($tags -join ', ')`n`nDanach werden sie allen Installationen angeboten (je nach Kanal Stabil/Test)." 'Release signieren')) { Write-HUPub 'Signieren abgebrochen.' WARN; $script:SignCtx = $null; return }
        Write-HUPub "Signiere $($tags -join ', ') ... (Pruefsumme laden, signieren, Signatur pruefen, hochladen)" INFO
        $sc = $script:SignCtx
        $script:SignTokFile = if ($sc.Addon) { Get-HUSignTokenFile $sc.Owner $sc.Repo } else { Get-HUSignTokenFile }
        Invoke-AsyncCommand -ScriptBlock {
            param($lib, $owner, $repo, $tp, $tok, $tags)
            try {
                . $lib
                $items = @(Invoke-HMReleaseSigning $owner $repo $tp $tok $tags | ForEach-Object { [pscustomobject]@{ Tag = "$($_.Tag)"; Ok = [bool]$_.Ok; Text = "$($_.Text)" } })
                return ('RES:' + (ConvertTo-Json -Depth 10 -InputObject @($items) -Compress))
            } catch { return "ERR:$($_.Exception.Message)" }
        } -ArgumentList @($script:UpdateLib, $sc.Owner, $sc.Repo, $sc.Thumb, $sc.Token, [string[]]$tags) -TimeoutSec 180 -OnComplete {
            param($res)
            $script:SignCtx = $null
            $s = "$res".Trim()
            if ($s -notmatch '^RES:') {
                $msg = "Signieren fehlgeschlagen: $($s -replace '^(ERR:|FEHLER:)\s*', '')"
                Write-HUPub $msg ERROR; Show-HUMessage $msg 'Release signieren' -Icon Error; return
            }
            $items = @(($s.Substring(4) | ConvertFrom-Json) | Where-Object { $_ })
            foreach ($x in $items) { if ($x.Ok) { Write-HUPub "$($x.Tag): $($x.Text)" OK } else { Write-HUPub "$($x.Tag): $($x.Text)" ERROR } }
            $bad = @($items | Where-Object { -not $_.Ok })
            $sum = ($items | ForEach-Object { "$($_.Tag): $($_.Text)" }) -join "`n"
            if ($bad.Count) { Show-HUMessage "Signieren mit Fehlern:`n`n$sum" 'Release signieren' -Icon Error }
            else { Show-HUMessage "Signiert:`n`n$sum`n`nNaechster Schritt: Rechtsklick auf Update > Release freigeben." 'Release signieren' }
            if (@($items | Where-Object { -not $_.Ok -and "$($_.Text)" -match 'Schreibrecht' }).Count) {
                Remove-Item -LiteralPath $script:SignTokFile -Force -ErrorAction SilentlyContinue
                Write-HUPub 'Gespeicherter Schreib-Token geloescht - beim naechsten Signieren neu eingeben.' WARN
            }
            Invoke-UpdateCheck
        }
    }
}

function Start-HUReleasePublish([switch]$Addon) {
    $cfg = Update-UpdateConfig
    if (-not $cfg) { return }
    if ($Addon) {
        $t = Select-HUAddonSignTarget 'Release freigeben'; if (-not $t) { return }
        $cfg = [pscustomobject]@{ Owner = $t.Owner; Repo = $t.Repo; SignerThumbprint = $cfg.SignerThumbprint }
    }
    Write-HUPub "=== Release freigeben ($($cfg.Owner)/$($cfg.Repo)) ===" INFO
    $tok = Get-HUSignTokenOrPrompt $cfg -Addon:$Addon
    if (-not $tok) { Write-HUPub 'Abgebrochen: kein GitHub-Token mit Schreibrecht.' WARN; return }
    $script:PubCtx = [pscustomobject]@{ Owner = $cfg.Owner; Repo = $cfg.Repo; Thumb = $cfg.SignerThumbprint; Token = $tok; Addon = [bool]$Addon }
    $script:PubTokFile = if ($Addon) { Get-HUSignTokenFile $cfg.Owner $cfg.Repo } else { Get-HUSignTokenFile }
    Write-HUPub 'Signierte Vorab-Releases werden gesucht ...' INFO
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $tok, $owner, $repo)
        try {
            . $lib
            $l = @(Get-HMReleases $owner $repo $tok)
            $stable = @($l | Where-Object { -not $_.Prerelease } | Select-Object -First 1)[0]
            $cand = @($l | Where-Object { $_.Prerelease -and $_.ManifestUrl -and $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | Select-Object -First 1)[0]
            $unsigned = @($l | Where-Object { $_.Prerelease -and -not $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | ForEach-Object { $_.Tag })
            $b = 'None'
            try { $b = Get-HMBuildWaitState (Get-HMMainBuildState $owner $repo $tok) } catch { }
            return "PUB:$(if ($cand) { $cand.Tag })|$(if ($stable) { $stable.Tag })|$($unsigned -join ',')|$b"
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:UpdateLib, $tok, $cfg.Owner, $cfg.Repo) -TimeoutSec 40 -OnComplete {
        param($result)
        $r = "$result".Trim()
        if ($r -notmatch '^PUB:([^|]*)\|([^|]*)\|([^|]*)\|(\w+)$') {
            $msg = "Releases nicht lesbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"
            Write-HUPub $msg ERROR; Show-HUMessage $msg 'Release freigeben' -Icon Error
            $script:PubCtx = $null; return
        }
        $tag = $Matches[1]; $stable = $Matches[2]; $uns = $Matches[3]; $build = $Matches[4]
        Write-HUPub "Bisher freigegeben: $(if ($stable) { $stable } else { '-' })" INFO
        if (-not $tag) {
            $msg = "Kein signiertes Vorab-Release neuer als $(if ($stable) { $stable } else { '(keines)' }).$(if ($uns) { " Noch nicht signiert: $uns - zuerst 'Release signieren'." })"
            if ($build -eq 'Building') { $msg += "`n`nDie neue Version wird gerade gebaut (automatische Tests laufen). Zuerst 'Release signieren' - das wartet auf Wunsch, bis das Release da ist." }
            Write-HUPub $msg WARN; Show-HUMessage $msg 'Release freigeben' -Icon Warning
            $script:PubCtx = $null; return
        }
        Write-HUPub "Kandidat: $tag (signiert)" INFO
        if (-not (Confirm-HU -Warning "$tag jetzt freigeben?`n`nDanach ist es im Kanal Stabil die neueste Version und wird ALLEN Installationen als Update angeboten.`nBisher freigegeben: $(if ($stable) { $stable } else { '-' })" 'Release freigeben')) { Write-HUPub 'Freigabe abgebrochen.' WARN; $script:PubCtx = $null; return }
        Write-HUPub "Gebe $tag frei ... (Signatur wird vorher erneut geprueft)" INFO
        $pc = $script:PubCtx
        Invoke-AsyncCommand -ScriptBlock {
            param($lib, $owner, $repo, $tag, $tp, $tok)
            try { . $lib; Publish-HMRelease $owner $repo $tag $tp $tok; return "OK:$tag" }
            catch {
                $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
                if ($code -in 401, 403, 404) { return "AUTH:kein Schreibrecht (HTTP $code) - Token pruefen" }
                return "ERR:$($_.Exception.Message)"
            }
        } -ArgumentList @($script:UpdateLib, $pc.Owner, $pc.Repo, $tag, $pc.Thumb, $pc.Token) -TimeoutSec 60 -OnComplete {
            param($res)
            $script:PubCtx = $null
            $s = "$res".Trim()
            if ($s -match '^OK:(.+)$') { $t = $Matches[1]; Write-HUPub "${t}: freigegeben (Kanal Stabil)" OK; Show-HUMessage "$t ist freigegeben (Kanal Stabil) und wird allen Installationen als Update angeboten." 'Release freigeben'; Invoke-UpdateCheck }
            elseif ($s -match '^AUTH:(.+)$') { $msg = "Freigabe fehlgeschlagen: $($Matches[1])"; Write-HUPub $msg ERROR; Remove-Item -LiteralPath $script:PubTokFile -Force -ErrorAction SilentlyContinue; Show-HUMessage "$msg`n`nGespeicherter Token wurde geloescht - beim naechsten Versuch neu eingeben." 'Release freigeben' -Icon Error }
            else { $msg = "Freigabe fehlgeschlagen: $($s -replace '^(ERR:|FEHLER:)\s*', '')"; Write-HUPub $msg ERROR; Show-HUMessage $msg 'Release freigeben' -Icon Error }
        }
    }
}

# --- Info-Fenster ---
function Show-HUAbout {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Info" Width="500" MinWidth="500" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip" Background="#1E1E1E" ShowInTaskbar="False">
  <StackPanel Margin="20">
    <Image x:Name="img" Width="96" Height="96" RenderOptions.BitmapScalingMode="HighQuality"/>
    <TextBlock Text="HU-MultiTenant" FontSize="26" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,8,0,0"/>
    <TextBlock Text="Microsoft 365 / Intune fuer mehrere Tenants" FontSize="13" Foreground="#AAAAAA" HorizontalAlignment="Center"/>
    <TextBlock x:Name="ver" FontSize="12" Foreground="#4FC3F7" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <TextBlock TextWrapping="Wrap" x:Name="src" FontSize="11" Foreground="#4FC3F7" HorizontalAlignment="Center" Margin="0,6,0,0" Cursor="Hand" TextDecorations="Underline"/>
    <TextBlock x:Name="lic" Text="Nutzungslizenz - siehe LICENSE" FontSize="11" Foreground="#4FC3F7" HorizontalAlignment="Center" Margin="0,2,0,0" Cursor="Hand" TextDecorations="Underline"/>
  </StackPanel>
</Window>
'@
    $d = New-HUWindow -XamlText $x
    $w = $d.Window; $c = $d.C
    if ($script:AppIcon) { $c.img.Source = $script:AppIcon }
    $inst = Get-HUInstalledInfo
    $uc = Update-UpdateConfig
    $chk = if ($inst -and $inst.PSObject.Properties['Check'] -and "$($inst.Check)") { "$($inst.Check)" } else { '' }
    $chan = if (-not $uc) { '?' } elseif ($uc.UseBranch) { "Branch $($uc.Branch)" } else { Format-HUChannel $uc.Channel }
    $c.ver.Text = "Version $($script:Version)  |  PowerShell $($PSVersionTable.PSVersion)`nKanal $chan$(if ($uc -and $uc.RequireSignature) { ', nur signierte Updates' })" + $(if ($chk) { "`ninstalliert $($inst.Date), geprueft: $chk" } else { '' })
    $repoUrl = if ($uc) { "https://github.com/$($uc.Owner)/$($uc.Repo)" } else { 'https://github.com/ChiliApple/HU-MultiTenant' }
    $c.src.Text = $repoUrl -replace '^https://', ''
    $c.src.Add_MouseLeftButtonUp({ Open-HUUrl $repoUrl })
    $c.lic.Add_MouseLeftButtonUp({ $lf = Join-Path $script:AppRoot 'LICENSE'; if (Test-Path -LiteralPath $lf) { Start-Process notepad.exe -ArgumentList "`"$lf`"" } else { Open-HUUrl "$repoUrl/blob/main/LICENSE" } })
    [void]$w.ShowDialog()
}

# --- Doku-Seiten (F1 = Anleitung): Fassung der installierten Version von GitHub, sonst die mitgelieferte ---
# Nur feste Seiten; der Aufrufer gibt nie einen Pfad oder Dateinamen vor.
$script:HUDocPages = [ordered]@{ Anleitung = 'Anleitung.html'; Einstieg = 'Einstieg.html'; Funktionen = 'Funktionen.html'; Roadmap = 'Roadmap.html' }
$script:HUDocImages = @('screenshot-quickscript.png', 'screenshot-apps.png', 'screenshot-sperre.png', 'screenshot-wartung.png', 'screenshot-sicherheit.png', 'screenshot-muster.png', 'screenshot-autopilot.png')
function Show-HUManual {
    param([ValidateSet('Anleitung', 'Einstieg', 'Funktionen', 'Roadmap')][string]$Page = 'Anleitung')
    $file = $script:HUDocPages[$Page]
    $local = Join-Path $script:AppRoot "Docs\$file"
    $cfg = Update-UpdateConfig
    $ref = if ($cfg -and $cfg.UseBranch) { $cfg.Branch } else { "v$($script:Version)" }
    $tmpDir = Join-Path $env:TEMP 'HU-MultiTenant_Docs'   # alle Seiten + Bilder unter ihrem echten Namen, damit die Links untereinander funktionieren
    $onDone = {
        param($r)
        $r = "$r".Trim()
        $f = if ($r -match '^OK:(.+)$') { $Matches[1] } elseif (Test-Path -LiteralPath $local) { $local } else { $null }
        if (-not $f) { Write-HULogError "Doku-Seite $Page nicht verfuegbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"; return }
        Open-HUUrl $f
    }.GetNewClosure()
    Invoke-AsyncCommand -ScriptBlock {
        param($token, $owner, $repo, $ref, $dir, $file, $all)
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $get = {
                param($name, $must)
                $t = Join-Path $dir $name
                $rel = "Docs/$name"
                try {
                    $tmp = "$t.part"
                    if ($token) { Invoke-WebRequest "https://api.github.com/repos/$owner/$repo/contents/${rel}?ref=$ref" -Headers @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HU-MultiTenant'; Authorization = "token $token" } -UseBasicParsing -TimeoutSec 15 -OutFile $tmp -ErrorAction Stop }
                    else { Invoke-WebRequest "https://raw.githubusercontent.com/$owner/$repo/$ref/$rel" -Headers @{ 'User-Agent' = 'HU-MultiTenant' } -UseBasicParsing -TimeoutSec 15 -OutFile $tmp -ErrorAction Stop }
                    Move-Item -LiteralPath $tmp -Destination $t -Force
                } catch { Remove-Item -LiteralPath "$t.part" -Force -ErrorAction SilentlyContinue; if ($must) { throw } }
            }
            & $get $file $true                                   # gewuenschte Seite muss kommen
            foreach ($n in $all) { if ($n -ne $file) { & $get $n $false } }   # Rest (andere Seiten, Bilder) nur wenn erreichbar
            $target = Join-Path $dir $file
            if ((Get-Item -LiteralPath $target).Length -lt 1000) { return 'ERR:Datei leer' }
            return "OK:$target"
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @((Read-GitHubToken), $(if ($cfg) { $cfg.Owner } else { 'ChiliApple' }), $(if ($cfg) { $cfg.Repo } else { 'HU-MultiTenant' }), $ref, $tmpDir, $file, (@($script:HUDocPages.Values) + @($script:HUDocImages))) -TimeoutSec 60 -OnComplete $onDone
}

function Register-HUUpdateHandlers {
    $b = $script:Controls['btnUpdate']
    $b.Add_Click({ Start-HUPull })
    $b.ToolTip = "Update von GitHub (Release, Pruefsumme + Signatur) - Tool wird geschlossen und neu gestartet. Gold = neue Version.`nRechtsklick: andere Version, Einstellungen, Info, GitHub-Token"
    $cm = New-Object System.Windows.Controls.ContextMenu
    $add = { param($h, $sb) $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $h; $mi.Add_Click($sb); [void]$cm.Items.Add($mi); $mi }
    [void](& $add 'Andere Version / Vorversion installieren ...' { Show-HUVersionPicker })
    [void](& $add 'Update-Einstellungen (Kanal, Signatur) ...' { Open-HUSettings 'Update' })
    [void](& $add 'Jetzt nach Updates suchen' { Invoke-UpdateCheck; try { Start-HUAddonUpdate -Loud } catch { } })
    [void](& $add 'Zusatzmodule ...' { Show-HUAddonDialog })
    [void](& $add 'Info ...' { Show-HUAbout })
    [void](& $add 'Anleitung (F1)' { Show-HUManual })
    [void](& $add 'Roadmap - wie es weitergeht' { Show-HUManual -Page 'Roadmap' })
    [void]$cm.Items.Add((New-Object System.Windows.Controls.Separator))
    [void](& $add 'GitHub-Token (nur privates Repo) ...' {
        $f = Get-GitHubTokenFile
        $has = Test-Path -LiteralPath $f
        $a = Confirm-HUYesNoCancel "Gespeicherter GitHub-Token: $(if ($has) { 'vorhanden' } else { 'keiner' })`n`nNur fuer PRIVATE Repos noetig (Fine-grained PAT, nur 'Contents: Read').`n`nJa = Token eingeben/ersetzen`nNein = gespeicherten Token loeschen`nAbbrechen = nichts tun" 'GitHub-Token'
        if ($a -eq 'Yes') { if (Save-GitHubTokenFromPrompt $f 'GitHub-Token (Nur-Lese) als Kennwort eingeben (DPAPI, nur fuer deinen Benutzer lesbar)') { Write-HULogOK 'GitHub-Token gespeichert'; Invoke-UpdateCheck } }
        elseif ($a -eq 'No' -and $has) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; Write-HULogOK 'GitHub-Token geloescht' }
    })
    $sep = New-Object System.Windows.Controls.Separator
    [void]$cm.Items.Add($sep)
    $miSign = & $add 'Release signieren (Herausgeber) ...' { Start-HUReleaseSigning }
    $miPub = & $add 'Release freigeben (Herausgeber) ...' { Start-HUReleasePublish }
    $miASign = & $add 'Zusatzmodul: Release signieren (Herausgeber) ...' { Start-HUReleaseSigning -Addon }
    $miAPub = & $add 'Zusatzmodul: Release freigeben (Herausgeber) ...' { Start-HUReleasePublish -Addon }
    $script:UpdMenuSign = @($sep, $miSign, $miPub, $miASign, $miAPub)
    $cm.Add_Opened({ $v = $(if (Test-HUCanSign) { 'Visible' } else { 'Collapsed' }); foreach ($m in $script:UpdMenuSign) { $m.Visibility = $v } })
    $b.ContextMenu = $cm
    $script:Controls['btnHelp'].Add_Click({ Show-HUManual })
    $hm = New-Object System.Windows.Controls.ContextMenu
    foreach ($p in @(@('Anleitung (F1)', 'Anleitung', 'Schritt-fuer-Schritt-Anleitung'), @('Funktionen', 'Funktionen', 'Alle Funktionen auf einer Seite'), @('Roadmap - wie es weitergeht', 'Roadmap', 'Ueberblick ueber die naechsten Versionen'))) {
        $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $p[0]; $mi.Tag = $p[1]; $mi.ToolTip = $p[2]
        $mi.Add_Click({ param($s, $e) Show-HUManual -Page "$($s.Tag)" }); [void]$hm.Items.Add($mi)
    }
    $script:Controls['btnHelp'].ContextMenu = $hm
    $script:Controls['btnHelp'].ToolTip = "Anleitung (F1)`nRechtsklick: Funktionen, Roadmap"
}
