<#
.SYNOPSIS
    Wartung: Pruef- und Reparaturskript in der Windows Sandbox testen (Bibliothek und In Intune).
.DESCRIPTION
    Ablauf wie Intune: Erkennung -> bei exit 1 Reparatur -> Erkennung erneut, als SYSTEM bzw. Benutzer,
    64- oder 32-Bit, ohne Netzwerk, Zeitlimit 5 Minuten je Skript. Ergebnis landet in der Ausgabe der Wartung.
    Arbeitsordner: %LOCALAPPDATA%\HU-MultiTenant\Sandbox\Wartung (Skripte, Protokoll.txt, Ergebnis.txt).
#>

$script:RemSbWatch = $null
$script:RemSbTimer = $null
$script:RemSbTimeout = 300

function Test-HURemSandboxBusy { return [bool]$script:RemSbWatch }

function Update-HURemSandboxButtons {
    try { Update-HURemButtons } catch { }
    try { Update-HURintButtons } catch { }
}

function Start-HURemSandbox([string]$Name, [string]$Detection, [string]$Remediation, [string]$RunAs = 'system', [bool]$Use32 = $false) {
    if ($script:RemSbWatch) { Show-HUMessage 'Es laeuft bereits ein Sandbox-Test.' -Icon Info; return }
    if (-not "$Detection".Trim()) { Show-HUMessage 'Das Pruefskript ist leer.' -Icon Warning; return }
    if (-not (Test-HUSandboxAvailable)) { Show-HUSandboxSetup; return }
    if ($RunAs -ne 'user') { $RunAs = 'system' }
    $rtb = $script:Controls['rtbRem']
    $work = Join-Path (Get-HUWorkPath 'Sandbox') 'Wartung'
    Add-HURtbLine $rtb "=== Sandbox-Test: $Name ===" '#CE93D8'
    Add-HURtbLine $rtb "als $(if ($RunAs -eq 'user') { 'angemeldeter Benutzer' } else { 'SYSTEM' }), $(if ($Use32) { '32' } else { '64' })-Bit, ohne Netzwerk, Zeitlimit $([int]($script:RemSbTimeout / 60)) Min. je Skript" '#90CAF9'
    Add-HURtbLine $rtb 'Hinweis: frisches Windows - Software, die das Skript sucht oder entfernt, ist dort meist nicht installiert. Geprueft werden Ablauf, Exit-Codes, Ausgabe und Rechte.' '#858585'
    try {
        $file = Start-HURemSandboxTest -WorkFolder $work -Detection $Detection -Remediation $Remediation -RunAs $RunAs -Use32:$Use32 -TimeoutSeconds $script:RemSbTimeout
    } catch { Add-HURtbLine $rtb "Sandbox nicht gestartet: $($_.Exception.Message)" '#FF5252'; return }
    Add-HURtbLine $rtb 'Windows Sandbox startet - der Ablauf ist dort im Fenster zu sehen ...' '#81C784'
    $script:RemSbWatch = @{ File = $file; Work = $work; Started = Get-Date; Seen = $false; RunAs = $RunAs; HasFix = [bool]"$Remediation".Trim(); Name = $Name }
    if (-not $script:RemSbTimer) {
        $script:RemSbTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:RemSbTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:RemSbTimer.Add_Tick({ Update-HURemSandboxWatch })
    }
    $script:RemSbTimer.Start()
    Update-HURemSandboxButtons
}

function Stop-HURemSandboxWatch([string]$Text, [string]$Color = '#FFB74D') {
    $script:RemSbTimer.Stop()
    $script:RemSbWatch = $null
    if ($Text) { Add-HURtbLine $script:Controls['rtbRem'] $Text $Color }
    Update-HURemSandboxButtons
}

function Update-HURemSandboxWatch {
    $w = $script:RemSbWatch
    if (-not $w) { $script:RemSbTimer.Stop(); return }
    $secs = [int]((Get-Date) - $w.Started).TotalSeconds
    if (Test-Path -LiteralPath $w.File) {
        $res = $null
        try { $res = Get-Content -LiteralPath $w.File -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        if (-not $res) { return }
        Stop-HURemSandboxWatch ''
        Stop-HUSandbox
        Show-HURemSandboxResult $res $w
        return
    }
    $running = [bool](Get-Process -Name 'WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession', 'WindowsSandboxServer' -ErrorAction SilentlyContinue)
    if ($running) { $w.Seen = $true }
    if ($w.Seen -and -not $running) { Stop-HURemSandboxWatch "Sandbox wurde ohne Ergebnis geschlossen. Protokoll: $(Join-Path $w.Work 'Protokoll.txt')"; return }
    if (-not $w.Seen -and $secs -gt 180) { Stop-HURemSandboxWatch 'Sandbox startet nicht - laeuft die Virtualisierung? (Task-Manager > Leistung > CPU > Virtualisierung: Aktiviert)'; return }
    if ($secs -gt (3 * $script:RemSbTimeout + 600)) { Stop-HURemSandboxWatch 'Abbruch ohne Ergebnis - Sandbox bitte von Hand schliessen.'; return }
}

# Zeile je Schritt + Bewertung wie Intune
function Show-HURemSandboxResult($Res, $W) {
    $rtb = $script:Controls['rtbRem']
    $label = @{ 'Erkennung' = 'Erkennung'; 'Reparatur' = 'Reparatur'; 'Erkennung-danach' = 'Erkennung nach der Reparatur' }
    $steps = @($Res.Steps | Where-Object { $_ })
    foreach ($s in $steps) {
        $bits = if ("$($s.Bits)") { "$($s.Bits)-Bit" } else { '' }
        $code = if ($null -ne $s.ExitCode -and "$($s.ExitCode)" -ne '') { "exit $($s.ExitCode)" } else { 'kein Exit-Code' }
        $ok = (-not $s.TimedOut) -and -not "$($s.Error)" -and ("$($s.ExitCode)" -in '0', '1')
        Add-HURtbLine $rtb "[$($label["$($s.Tag)"])] $code - $($s.Seconds) s - als $($s.User) $bits".TrimEnd() $(if ($ok) { '#81C784' } else { '#FF5252' })
        if ($s.TimedOut) { Add-HURtbLine $rtb "  Zeitlimit ($([int]($script:RemSbTimeout / 60)) Min.) erreicht - Skript samt Unterprozessen abgebrochen (wartet es auf eine Eingabe oder ein Fenster?)" '#FF5252' }
        if ("$($s.Error)") { Add-HURtbLine $rtb "  $($s.Error)" '#FF5252' }
        if ($W.RunAs -eq 'system' -and "$($s.Sid)" -and "$($s.Sid)" -ne 'S-1-5-18') { Add-HURtbLine $rtb '  Lief NICHT als SYSTEM - Test nicht aussagekraeftig.' '#FF5252' }
        $out = "$($s.Out)".TrimEnd()
        if ($out) {
            $ls = @($out -split "`r?`n")
            foreach ($l in @($ls | Select-Object -First 30)) { Add-HURtbLine $rtb "  $l" '#E0E0E0' }
            if ($ls.Count -gt 30) { Add-HURtbLine $rtb "  ... ($($ls.Count - 30) weitere Zeilen in Ergebnis.txt)" '#858585' }
            if ($out.Length -gt 2048) { Add-HURtbLine $rtb "  Ausgabe hat $($out.Length) Zeichen - Intune speichert nur 2.048." '#FFB74D' }
        } elseif ("$($s.Tag)" -ne 'Reparatur') { Add-HURtbLine $rtb '  (keine Ausgabe - Intune zeigt dann eine leere Spalte)' '#858585' }
        $err = "$($s.Err)".Trim()
        if ($err) { foreach ($l in @(@($err -split "`r?`n") | Select-Object -First 15)) { Add-HURtbLine $rtb "  ! $l" '#FFB74D' } }
    }
    if ("$($Res.Error)") { Add-HURtbLine $rtb "Fehler im Testablauf: $($Res.Error)" '#FF5252' }
    $d1 = @($steps | Where-Object { $_.Tag -eq 'Erkennung' })[0]
    $fx = @($steps | Where-Object { $_.Tag -eq 'Reparatur' })[0]
    $d2 = @($steps | Where-Object { $_.Tag -eq 'Erkennung-danach' })[0]
    $e1 = if ($d1) { "$($d1.ExitCode)" } else { '' }
    $v = if ($d1 -and $d1.TimedOut) { @('Fehler: das Pruefskript hat das Zeitlimit erreicht.', '#FF5252') }
    elseif (-not $d1 -or $e1 -notin '0', '1') { @('Fehler: das Pruefskript muss mit exit 0 oder exit 1 enden.', '#FF5252') }
    elseif ($e1 -eq '0') { @('ohne Problem - die Reparatur wird nicht ausgefuehrt.', '#81C784') }
    elseif (-not $W.HasFix) { @('Problem gefunden - kein Reparaturskript, Intune meldet nur.', '#FFB74D') }
    elseif (-not $fx -or $fx.TimedOut -or "$($fx.ExitCode)" -ne '0') { @('Reparatur fehlgeschlagen (exit ungleich 0 oder Zeitlimit).', '#FF5252') }
    elseif ($d2 -and "$($d2.ExitCode)" -eq '0') { @('Problem gefunden und behoben.', '#81C784') }
    else { @('Reparatur lief, aber die Erkennung danach meldet das Problem noch - Intune zeigt "wieder aufgetreten"/fehlgeschlagen.', '#FFB74D') }
    Add-HURtbLine $rtb "Ergebnis wie in Intune: $($v[0])" $v[1]
    Add-HURtbLine $rtb "Protokoll und Ergebnis: $($W.Work)" '#858585'
}
