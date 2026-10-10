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
function Get-HUSignTokenFile { return (Join-Path $env:APPDATA 'HU-MultiTenant\GitHubSignToken.xml') }
function Read-HUSignToken {
    $f = Get-HUSignTokenFile
    if (Test-Path -LiteralPath $f) { try { $c = Import-Clixml -Path $f; if ($c -is [System.Management.Automation.PSCredential]) { return $c.GetNetworkCredential().Password.Trim() } } catch { } }
    return ''
}
function Test-HUCanSign {
    $c = Update-UpdateConfig
    if (-not $c -or -not (Get-Command Get-HMSigningCert -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Get-HMSigningCert $c.SignerThumbprint)
}
function Get-HUSignTokenOrPrompt([object]$Cfg) {
    $tok = Read-HUSignToken
    if ($tok) { return $tok }
    if (-not (Save-GitHubTokenFromPrompt (Get-HUSignTokenFile) "GitHub-Token mit Schreibrecht fuer $($Cfg.Owner)/$($Cfg.Repo) (Fine-grained PAT, 'Contents: Read and write'). Wird verschluesselt nur fuer deinen Windows-Benutzer gespeichert.")) { return '' }
    return (Read-HUSignToken)
}

# Protokoll sichtbar machen (liegt im Reiter Extensions) - Signieren/Freigeben schreiben dorthin
function Show-HUProtocolTab {
    try { $c = $script:Controls; if ($c['tabMain'] -and $c['tabExtensions'] -and $c['tabMain'].SelectedItem -ne $c['tabExtensions']) { $c['tabMain'].SelectedItem = $c['tabExtensions'] } } catch { }
}

function Start-HUReleaseSigning {
    $cfg = Update-UpdateConfig
    if (-not $cfg) { return }
    Show-HUProtocolTab
    Write-HULogInfo "=== Release signieren ($($cfg.Owner)/$($cfg.Repo)) ==="
    $cert = Get-HMSigningCert $cfg.SignerThumbprint
    if (-not $cert) {
        Write-HULogError "Signatur-Zertifikat $($cfg.SignerThumbprint) mit privatem Schluessel ist auf diesem PC nicht vorhanden (oder abgelaufen)."
        Show-HUMessage "Signatur-Zertifikat $($cfg.SignerThumbprint) mit privatem Schluessel ist auf diesem PC nicht vorhanden (oder abgelaufen)." 'Release signieren' -Icon Error
        return
    }
    Write-HULogInfo "Zertifikat: $($cert.Subject) - gueltig bis $($cert.NotAfter.ToString('dd.MM.yyyy'))"
    $tok = Get-HUSignTokenOrPrompt $cfg
    if (-not $tok) { Write-HULogWarn 'Abgebrochen: kein GitHub-Token mit Schreibrecht.'; return }
    $script:SignCtx = [pscustomobject]@{ Owner = $cfg.Owner; Repo = $cfg.Repo; Thumb = $cfg.SignerThumbprint; Token = $tok }
    Write-HULogInfo 'Releases werden gelesen ...'
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $tok, $owner, $repo)
        try {
            . $lib
            $all = @(Get-HMReleases $owner $repo $tok)
            $l = @($all | Where-Object { $_.ManifestUrl -and -not $_.SignatureUrl } | ForEach-Object { "$($_.Tag)" })
            $noMan = @($all | Where-Object { -not $_.ManifestUrl } | Select-Object -First 5 | ForEach-Object { "$($_.Tag)" })
            $newest = @($all | Select-Object -First 1)[0]
            $nInfo = if ($newest) { "$($newest.Tag) ($(if ($newest.Prerelease) { 'Vorab' } else { 'freigegeben' }), $(if ($newest.SignatureUrl) { 'signiert' } elseif ($newest.ManifestUrl) { 'nicht signiert' } else { 'ohne Pruefsumme' }))" } else { '-' }
            return ('TAGS:' + ($l -join ',') + '|' + ($noMan -join ',') + '|' + $nInfo)
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:UpdateLib, $tok, $cfg.Owner, $cfg.Repo) -TimeoutSec 40 -OnComplete {
        param($result)
        $r = "$result".Trim()
        if ($r -notmatch '^TAGS:([^|]*)\|([^|]*)\|(.*)$') {
            $msg = "Releases nicht lesbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"
            Write-HULogError $msg; Show-HUMessage $msg 'Release signieren' -Icon Error
            $script:SignCtx = $null; return
        }
        $tags = @($Matches[1] -split ',' | Where-Object { $_ }); $noMan = "$($Matches[2])"; $newest = "$($Matches[3])"
        Write-HULogInfo "Neuestes Release: $newest"
        if ($noMan) { Write-HULogWarn "Ohne Pruefsummen-Datei (automatische Tests noch nicht fertig oder fehlgeschlagen): $noMan" }
        if (-not $tags.Count) {
            $msg = "Nichts zu signieren - alle Releases mit Pruefsumme sind bereits signiert.`n`nNeuestes Release: $newest$(if ($noMan) { "`nOhne Pruefsumme: $noMan" })`n`nEine neue Version entsteht erst mit dem Merge nach main (danach ein paar Minuten warten, bis die automatischen Tests die Pruefsummen-Datei angehaengt haben)."
            Write-HULogOK 'Nichts zu signieren - alle Releases mit Pruefsumme sind bereits signiert.'
            Show-HUMessage $msg 'Release signieren'
            $script:SignCtx = $null; return
        }
        Write-HULogInfo "Nicht signiert: $($tags -join ', ')"
        if (-not (Confirm-HU "Diese Releases jetzt signieren?`n`n$($tags -join ', ')`n`nDanach werden sie allen Installationen angeboten (je nach Kanal Stabil/Test)." 'Release signieren')) { Write-HULogWarn 'Signieren abgebrochen.'; $script:SignCtx = $null; return }
        Write-HULogInfo "Signiere $($tags -join ', ') ... (Pruefsumme laden, signieren, Signatur pruefen, hochladen)"
        $sc = $script:SignCtx
        Invoke-AsyncCommand -ScriptBlock {
            param($lib, $owner, $repo, $tp, $tok, $tags)
            try {
                . $lib
                $items = @(Invoke-HMReleaseSigning $owner $repo $tp $tok $tags | ForEach-Object { [pscustomobject]@{ Tag = "$($_.Tag)"; Ok = [bool]$_.Ok; Text = "$($_.Text)" } })
                return ('RES:' + (ConvertTo-Json -InputObject @($items) -Compress))
            } catch { return "ERR:$($_.Exception.Message)" }
        } -ArgumentList @($script:UpdateLib, $sc.Owner, $sc.Repo, $sc.Thumb, $sc.Token, [string[]]$tags) -TimeoutSec 180 -OnComplete {
            param($res)
            $script:SignCtx = $null
            $s = "$res".Trim()
            if ($s -notmatch '^RES:') {
                $msg = "Signieren fehlgeschlagen: $($s -replace '^(ERR:|FEHLER:)\s*', '')"
                Write-HULogError $msg; Show-HUMessage $msg 'Release signieren' -Icon Error; return
            }
            $items = @(($s.Substring(4) | ConvertFrom-Json) | Where-Object { $_ })
            foreach ($x in $items) { if ($x.Ok) { Write-HULogOK "$($x.Tag): $($x.Text)" } else { Write-HULogError "$($x.Tag): $($x.Text)" } }
            $bad = @($items | Where-Object { -not $_.Ok })
            $sum = ($items | ForEach-Object { "$($_.Tag): $($_.Text)" }) -join "`n"
            if ($bad.Count) { Show-HUMessage "Signieren mit Fehlern:`n`n$sum" 'Release signieren' -Icon Error }
            else { Show-HUMessage "Signiert:`n`n$sum`n`nNaechster Schritt: Rechtsklick auf Update > Release freigeben." 'Release signieren' }
            if (@($items | Where-Object { -not $_.Ok -and "$($_.Text)" -match 'Schreibrecht' }).Count) {
                Remove-Item -LiteralPath (Get-HUSignTokenFile) -Force -ErrorAction SilentlyContinue
                Write-HULogWarn 'Gespeicherter Schreib-Token geloescht - beim naechsten Signieren neu eingeben.'
            }
            Invoke-UpdateCheck
        }
    }
}

function Start-HUReleasePublish {
    $cfg = Update-UpdateConfig
    if (-not $cfg) { return }
    Show-HUProtocolTab
    Write-HULogInfo "=== Release freigeben ($($cfg.Owner)/$($cfg.Repo)) ==="
    $tok = Get-HUSignTokenOrPrompt $cfg
    if (-not $tok) { Write-HULogWarn 'Abgebrochen: kein GitHub-Token mit Schreibrecht.'; return }
    $script:PubCtx = [pscustomobject]@{ Owner = $cfg.Owner; Repo = $cfg.Repo; Thumb = $cfg.SignerThumbprint; Token = $tok }
    Write-HULogInfo 'Signierte Vorab-Releases werden gesucht ...'
    Invoke-AsyncCommand -ScriptBlock {
        param($lib, $tok, $owner, $repo)
        try {
            . $lib
            $l = @(Get-HMReleases $owner $repo $tok)
            $stable = @($l | Where-Object { -not $_.Prerelease } | Select-Object -First 1)[0]
            $cand = @($l | Where-Object { $_.Prerelease -and $_.ManifestUrl -and $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | Select-Object -First 1)[0]
            $unsigned = @($l | Where-Object { $_.Prerelease -and -not $_.SignatureUrl -and (-not $stable -or $_.Version -gt $stable.Version) } | ForEach-Object { $_.Tag })
            return "PUB:$(if ($cand) { $cand.Tag })|$(if ($stable) { $stable.Tag })|$($unsigned -join ',')"
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @($script:UpdateLib, $tok, $cfg.Owner, $cfg.Repo) -TimeoutSec 40 -OnComplete {
        param($result)
        $r = "$result".Trim()
        if ($r -notmatch '^PUB:([^|]*)\|([^|]*)\|(.*)$') {
            $msg = "Releases nicht lesbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"
            Write-HULogError $msg; Show-HUMessage $msg 'Release freigeben' -Icon Error
            $script:PubCtx = $null; return
        }
        $tag = $Matches[1]; $stable = $Matches[2]; $uns = $Matches[3]
        Write-HULogInfo "Bisher freigegeben: $(if ($stable) { $stable } else { '-' })"
        if (-not $tag) {
            $msg = "Kein signiertes Vorab-Release neuer als $(if ($stable) { $stable } else { '(keines)' }).$(if ($uns) { " Noch nicht signiert: $uns - zuerst 'Release signieren'." })"
            Write-HULogWarn $msg; Show-HUMessage $msg 'Release freigeben' -Icon Warning
            $script:PubCtx = $null; return
        }
        Write-HULogInfo "Kandidat: $tag (signiert)"
        if (-not (Confirm-HU "$tag jetzt freigeben?`n`nDanach ist es im Kanal Stabil die neueste Version und wird ALLEN Installationen als Update angeboten.`nBisher freigegeben: $(if ($stable) { $stable } else { '-' })" 'Release freigeben')) { Write-HULogWarn 'Freigabe abgebrochen.'; $script:PubCtx = $null; return }
        Write-HULogInfo "Gebe $tag frei ... (Signatur wird vorher erneut geprueft)"
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
            if ($s -match '^OK:(.+)$') { $t = $Matches[1]; Write-HULogOK "${t}: freigegeben (Kanal Stabil)"; Show-HUMessage "$t ist freigegeben (Kanal Stabil) und wird allen Installationen als Update angeboten." 'Release freigeben'; Invoke-UpdateCheck }
            elseif ($s -match '^AUTH:(.+)$') { $msg = "Freigabe fehlgeschlagen: $($Matches[1])"; Write-HULogError $msg; Remove-Item -LiteralPath (Get-HUSignTokenFile) -Force -ErrorAction SilentlyContinue; Show-HUMessage "$msg`n`nGespeicherter Token wurde geloescht - beim naechsten Versuch neu eingeben." 'Release freigeben' -Icon Error }
            else { $msg = "Freigabe fehlgeschlagen: $($s -replace '^(ERR:|FEHLER:)\s*', '')"; Write-HULogError $msg; Show-HUMessage $msg 'Release freigeben' -Icon Error }
        }
    }
}

# --- Info-Fenster ---
function Show-HUAbout {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Info" Width="500" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
  <StackPanel Margin="20">
    <Image x:Name="img" Width="96" Height="96" RenderOptions.BitmapScalingMode="HighQuality"/>
    <TextBlock Text="HU-MultiTenant" FontSize="26" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,8,0,0"/>
    <TextBlock Text="Microsoft 365 / Intune fuer mehrere Tenants" FontSize="13" Foreground="#AAAAAA" HorizontalAlignment="Center"/>
    <TextBlock x:Name="ver" FontSize="12" Foreground="#4FC3F7" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0"/>
    <TextBlock x:Name="src" FontSize="11" Foreground="#4FC3F7" HorizontalAlignment="Center" Margin="0,6,0,0" Cursor="Hand" TextDecorations="Underline"/>
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

# --- Anleitung (F1): Fassung der installierten Version von GitHub, sonst die mitgelieferte ---
function Show-HUManual {
    $script:ManualLocal = Join-Path $script:AppRoot 'Docs\Anleitung.html'
    $cfg = Update-UpdateConfig
    $ref = if ($cfg -and $cfg.UseBranch) { $cfg.Branch } else { "v$($script:Version)" }
    $tmpTarget = Join-Path $env:TEMP 'HU-MultiTenant_Anleitung.html'
    Invoke-AsyncCommand -ScriptBlock {
        param($token, $owner, $repo, $ref, $target)
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $rel = 'Docs/Anleitung.html'
            if ($token) { Invoke-WebRequest "https://api.github.com/repos/$owner/$repo/contents/${rel}?ref=$ref" -Headers @{ Accept = 'application/vnd.github.v3.raw'; 'User-Agent' = 'HU-MultiTenant'; Authorization = "token $token" } -UseBasicParsing -TimeoutSec 15 -OutFile $target -ErrorAction Stop }
            else { Invoke-WebRequest "https://raw.githubusercontent.com/$owner/$repo/$ref/$rel" -Headers @{ 'User-Agent' = 'HU-MultiTenant' } -UseBasicParsing -TimeoutSec 15 -OutFile $target -ErrorAction Stop }
            if ((Get-Item -LiteralPath $target).Length -lt 1000) { return 'ERR:Datei leer' }
            return "OK:$target"
        } catch { return "ERR:$($_.Exception.Message)" }
    } -ArgumentList @((Read-GitHubToken), $(if ($cfg) { $cfg.Owner } else { 'ChiliApple' }), $(if ($cfg) { $cfg.Repo } else { 'HU-MultiTenant' }), $ref, $tmpTarget) -TimeoutSec 25 -OnComplete {
        param($r)
        $r = "$r".Trim()
        $f = if ($r -match '^OK:(.+)$') { $Matches[1] } elseif (Test-Path -LiteralPath $script:ManualLocal) { $script:ManualLocal } else { $null }
        if (-not $f) { Write-HULogError "Anleitung nicht verfuegbar: $($r -replace '^(ERR:|FEHLER:)\s*', '')"; return }
        Open-HUUrl $f
    }
}

function Register-HUUpdateHandlers {
    $b = $script:Controls['btnUpdate']
    $b.Add_Click({ Start-HUPull })
    $b.ToolTip = "Update von GitHub (Release, Pruefsumme + Signatur) - Tool wird geschlossen und neu gestartet. Gold = neue Version.`nRechtsklick: andere Version, Einstellungen, Info, GitHub-Token"
    $cm = New-Object System.Windows.Controls.ContextMenu
    $add = { param($h, $sb) $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = $h; $mi.Add_Click($sb); [void]$cm.Items.Add($mi); $mi }
    [void](& $add 'Andere Version / Vorversion installieren ...' { Show-HUVersionPicker })
    [void](& $add 'Update-Einstellungen (Kanal, Signatur) ...' { Open-HUSettings 'Update' })
    [void](& $add 'Jetzt nach Updates suchen' { Invoke-UpdateCheck })
    [void](& $add 'Info ...' { Show-HUAbout })
    [void](& $add 'Anleitung (F1)' { Show-HUManual })
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
    $script:UpdMenuSign = @($sep, $miSign, $miPub)
    $cm.Add_Opened({ $v = $(if (Test-HUCanSign) { 'Visible' } else { 'Collapsed' }); foreach ($m in $script:UpdMenuSign) { $m.Visibility = $v } })
    $b.ContextMenu = $cm
    $script:Controls['btnHelp'].Add_Click({ Show-HUManual })
}
