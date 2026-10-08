#Requires -Version 5.1
<#
.SYNOPSIS
    Sperre: HU-MultiTenant nach einstellbarer Zeit ohne Eingabe (und auf Wunsch beim Start) sperren.
    Entsperren mit Windows Hello oder einer eigenen PIN (Ersatz, falls Hello nicht verfuegbar ist).
.DESCRIPTION
    Einstellungen in settings.json (ui.lockEnabled, ui.lockMinutes, ui.lockOnStart).
    PIN nur als PBKDF2-Hash (SHA-256, 100.000 Runden, Salt) in %APPDATA%\HU-MultiTenant\lock.json.
    Leerlauf = keine Maus/Tastatur am ganzen PC (GetLastInputInfo). Strg+L sperrt sofort.
    Kein starker Schutz: wer am entsperrten Windows sitzt, kommt mit Aufwand an die Secrets des Benutzers.
    Der eigentliche Schutz bleibt die Windows-Sperre.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:LockActive = $false
$script:LockTimer = $null
$script:LockFails = 0
$script:LockBlockedUntil = [datetime]::MinValue

function Initialize-HULockNative {
    if ('HUTools.LockNative' -as [type]) { return }
    Add-Type -Namespace 'HUTools' -Name 'LockNative' -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
public static uint IdleMilliseconds() {
    LASTINPUTINFO l = new LASTINPUTINFO();
    l.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(l);
    if (!GetLastInputInfo(ref l)) { return 0; }
    return unchecked((uint)System.Environment.TickCount - l.dwTime);
}
'@
}

function Get-HULockConfig {
    $u = $script:Settings.ui
    $m = 10; [void][int]::TryParse("$(Get-HUProp $u 'lockMinutes' 10)", [ref]$m)
    return [pscustomobject]@{
        Enabled = [bool](Get-HUProp $u 'lockEnabled' $false)
        Minutes = [Math]::Max(1, [Math]::Min(240, $m))
        OnStart = [bool](Get-HUProp $u 'lockOnStart' $true)
    }
}

# ----------------------------------------------------------------------------
# PIN (nur Hash)
# ----------------------------------------------------------------------------
function Get-HULockPinPath { return (Join-Path $env:APPDATA 'HU-MultiTenant\lock.json') }

function Get-HUPinHash([string]$Pin, [byte[]]$Salt, [int]$Rounds) {
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Pin, $Salt, $Rounds, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

function Set-HULockPin([string]$Pin) {
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.Dispose()
    $rounds = 100000
    $o = [pscustomobject]@{ v = 1; alg = 'PBKDF2-SHA256'; rounds = $rounds; salt = [Convert]::ToBase64String($salt); hash = [Convert]::ToBase64String((Get-HUPinHash $Pin $salt $rounds)) }
    $p = Get-HULockPinPath
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}

function Test-HULockPinSet { return (Test-Path -LiteralPath (Get-HULockPinPath)) }

function Test-HULockPin([string]$Pin) {
    try {
        $o = Get-Content -LiteralPath (Get-HULockPinPath) -Raw | ConvertFrom-Json
        $h = Get-HUPinHash $Pin ([Convert]::FromBase64String($o.salt)) ([int]$o.rounds)
        $want = [Convert]::FromBase64String($o.hash)
        if ($h.Length -ne $want.Length) { return $false }
        $diff = 0; for ($i = 0; $i -lt $h.Length; $i++) { $diff = $diff -bor ($h[$i] -bxor $want[$i]) }
        return ($diff -eq 0)
    } catch { return $false }
}

# PIN festlegen (Dialog). Rueckgabe $true wenn gesetzt.
function Show-HULockPinDialog($Owner = $null) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PIN festlegen" Width="380" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize" Background="#1E1E1E" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="18">
        <TextBlock Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Die PIN entsperrt HU-MultiTenant, wenn Windows Hello nicht verfuegbar ist. Mindestens 4 Zeichen; gespeichert wird nur ein Pruefwert (Hash), nicht die PIN."/>
        <TextBlock Text="PIN" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
        <PasswordBox x:Name="pw1" Height="28" Background="#2D2D2D" Foreground="White" BorderBrush="#3E3E42" Padding="6,3"/>
        <TextBlock Text="PIN wiederholen" Style="{StaticResource FieldLabel}" Margin="0,10,0,3"/>
        <PasswordBox x:Name="pw2" Height="28" Background="#2D2D2D" Foreground="White" BorderBrush="#3E3E42" Padding="6,3"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="btnOk" Content="Speichern" Width="110" Background="#388E3C" Style="{StaticResource DarkButton}" IsDefault="True" Margin="0,0,8,0"/>
            <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    if ($Owner) { try { $w.Owner = $Owner } catch { } }
    $state = @{ Ok = $false }
    $c.btnOk.Add_Click({
            $p1 = $c.pw1.Password; $p2 = $c.pw2.Password
            if ($p1.Length -lt 4) { Show-HUMessage 'Die PIN braucht mindestens 4 Zeichen.' -Icon Warning -Owner $w; return }
            if ($p1 -ne $p2) { Show-HUMessage 'Die beiden Eingaben stimmen nicht ueberein.' -Icon Warning -Owner $w; return }
            try { Set-HULockPin $p1; $state.Ok = $true; $w.Close() } catch { Show-HUMessage "PIN nicht gespeichert: $($_.Exception.Message)" -Icon Error -Owner $w }
        })
    $w.Add_ContentRendered({ $c.pw1.Focus() })
    [void]$w.ShowDialog()
    return $state.Ok
}

# ----------------------------------------------------------------------------
# Windows Hello (WinRT UserConsentVerifier) - im eigenen Runspace, die Oberflaeche bleibt bedienbar
# ----------------------------------------------------------------------------
$script:HelloCode = {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Security.Credentials.UI.UserConsentVerifier,Windows.Security.Credentials.UI,ContentType=WindowsRuntime]
        $asTask = @([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $await = { param($Op, [type]$T) $t = $asTask.MakeGenericMethod($T).Invoke($null, @($Op)); [void]$t.Wait(-1); $t.Result }
        $avail = & $await ([Windows.Security.Credentials.UI.UserConsentVerifier]::CheckAvailabilityAsync()) ([Windows.Security.Credentials.UI.UserConsentVerifierAvailability])
        if ("$avail" -ne 'Available') { return "nicht verfuegbar ($avail)" }
        $r = & $await ([Windows.Security.Credentials.UI.UserConsentVerifier]::RequestVerificationAsync('HU-MultiTenant entsperren')) ([Windows.Security.Credentials.UI.UserConsentVerificationResult])
        return "$r"
    } catch { return "Fehler: $($_.Exception.Message)" }
}

function Start-HUHelloVerify([scriptblock]$OnDone) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:HelloCode)
    $st = @{ PS = $ps; RS = $rs; H = $ps.BeginInvoke(); OnDone = $OnDone; Ticks = 0 }
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(300)
    $t.Tag = $st
    $t.Add_Tick({
            $s = $this.Tag
            $s.Ticks++
            # Hello-Dialog nach vorne holen (erscheint bei Desktop-Programmen sonst manchmal dahinter)
            if ($s.Ticks -le 12) { try { $h = [HUTools.LockNative]::FindWindow('Credential Dialog Xaml Host', $null); if ($h -ne [IntPtr]::Zero) { [void][HUTools.LockNative]::SetForegroundWindow($h) } } catch { } }
            if (-not $s.H.IsCompleted) { return }
            $this.Stop()
            $res = ''
            try { $res = "$(@($s.PS.EndInvoke($s.H))[0])" } catch { $res = "Fehler: $($_.Exception.Message)" }
            try { $s.PS.Dispose(); $s.RS.Dispose() } catch { }
            & $s.OnDone $res
        })
    $t.Start()
}

# ----------------------------------------------------------------------------
# Sperren / Entsperren
# ----------------------------------------------------------------------------
function Lock-HUApp([switch]$AtStart) {
    if ($script:LockActive) { return }
    $cfg = Get-HULockConfig
    if (-not $cfg.Enabled) { return }
    $script:LockActive = $true
    try { Clear-TokenCache } catch { }
    $main = $script:Window
    # Inhalt und offene Unterfenster verbergen
    $hidden = @()
    try { $main.Content.Visibility = 'Hidden' } catch { }
    foreach ($ow in @($main.OwnedWindows)) { if ($ow.IsVisible) { $ow.Visibility = 'Hidden'; $hidden += $ow } }
    try { Show-HULockDialog -AtStart:$AtStart } finally {
        try { $main.Content.Visibility = 'Visible' } catch { }
        foreach ($ow in $hidden) { try { $ow.Visibility = 'Visible' } catch { } }
        $script:LockActive = $false
    }
}

function Show-HULockDialog([switch]$AtStart) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HU-MultiTenant gesperrt" Width="400" SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="False" Background="#1E1E1E" BorderBrush="#3E3E42" BorderThickness="1" ShowInTaskbar="False">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <StackPanel Margin="24,20">
        <TextBlock Text="&#x1F512; HU-MultiTenant gesperrt" Foreground="#E0E0E0" FontSize="18" FontWeight="SemiBold" HorizontalAlignment="Center"/>
        <TextBlock x:Name="lblWhy" Style="{StaticResource HintText}" HorizontalAlignment="Center" Margin="0,4,0,16"/>
        <Button x:Name="btnHello" Content="Mit Windows Hello entsperren" Background="#1976D2" Style="{StaticResource DarkButton}" FontSize="13" Padding="10,8"/>
        <TextBlock x:Name="lblPin" Text="oder PIN:" Style="{StaticResource HintText}" Margin="0,14,0,4"/>
        <DockPanel x:Name="pnlPin">
            <Button x:Name="btnPin" DockPanel.Dock="Right" Content="Entsperren" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="6,0,0,0" IsDefault="True"/>
            <PasswordBox x:Name="pw" Height="30" Background="#2D2D2D" Foreground="White" BorderBrush="#3E3E42" Padding="6,4"/>
        </DockPanel>
        <TextBlock x:Name="lblMsg" Foreground="#FFB74D" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <TextBlock HorizontalAlignment="Right" Margin="0,14,0,0">
            <Hyperlink x:Name="lnkExit" Foreground="#858585">HU-MultiTenant beenden</Hyperlink>
        </TextBlock>
    </StackPanel>
</Window>
'@
    Initialize-HULockNative
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    try { $w.Owner = $script:Window } catch { }
    $cfg = Get-HULockConfig
    $c.lblWhy.Text = $(if ($AtStart) { 'Bitte entsperren, um zu beginnen.' } else { "Gesperrt nach $($cfg.Minutes) Minute(n) ohne Eingabe bzw. mit Strg+L." })
    $hasPin = Test-HULockPinSet
    if (-not $hasPin) { $c.lblPin.Visibility = 'Collapsed'; $c.pnlPin.Visibility = 'Collapsed' }
    $state = @{ Unlocked = $false; Exit = $false; Busy = $false }
    $unlock = { $state.Unlocked = $true; $script:LockFails = 0; $w.Close() }
    $hello = {
        if ($state.Busy) { return }
        $state.Busy = $true; $c.btnHello.IsEnabled = $false; $c.lblMsg.Text = 'Windows Hello ...'
        Start-HUHelloVerify -OnDone {
            param($r)
            $state.Busy = $false; $c.btnHello.IsEnabled = $true
            if ($r -eq 'Verified') { & $unlock; return }
            $c.lblMsg.Text = $(if ($r -match '^nicht verfuegbar') { "Windows Hello ist $r$(if ($hasPin) { ' - bitte die PIN verwenden.' } else { ' - in den Einstellungen eine PIN festlegen.' })" } elseif ($r -eq 'Canceled') { 'Abgebrochen.' } else { "Nicht entsperrt: $r" })
        }
    }
    $c.btnHello.Add_Click($hello)
    $c.btnPin.Add_Click({
            if ((Get-Date) -lt $script:LockBlockedUntil) { $c.lblMsg.Text = "Zu viele Fehlversuche - bitte $([int]($script:LockBlockedUntil - (Get-Date)).TotalSeconds + 1) s warten."; return }
            if (Test-HULockPin $c.pw.Password) { & $unlock; return }
            $script:LockFails++
            $c.pw.Clear()
            if ($script:LockFails -ge 5) { $script:LockBlockedUntil = (Get-Date).AddSeconds(30); $script:LockFails = 0; $c.lblMsg.Text = 'PIN falsch - 30 Sekunden gesperrt.' }
            else { $c.lblMsg.Text = "PIN falsch ($($script:LockFails) von 5)." }
        })
    $c.lnkExit.Add_Click({ $state.Exit = $true; $w.Close() })
    # Schliessen nur durch Entsperren oder "beenden"
    $w.Add_Closing({ param($s, $e) if (-not ($state.Unlocked -or $state.Exit)) { $e.Cancel = $true } })
    $w.Add_ContentRendered({ if ($c.pnlPin.Visibility -eq 'Visible') { $c.pw.Focus() } else { $c.btnHello.Focus() }; & $hello })
    [void]$w.ShowDialog()
    if ($state.Exit) {
        $script:LockActive = $false
        try { $script:Window.Content.Visibility = 'Visible' } catch { }
        $script:Window.Close()
    }
}

# Leerlauf pruefen (alle 15 s)
function Start-HULockTimer {
    Initialize-HULockNative
    if ($script:LockTimer) { $script:LockTimer.Stop() }
    $script:LockTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:LockTimer.Interval = [TimeSpan]::FromSeconds(15)
    $script:LockTimer.Add_Tick({
            if ($script:LockActive) { return }
            $cfg = Get-HULockConfig
            if (-not $cfg.Enabled) { return }
            if ([HUTools.LockNative]::IdleMilliseconds() -ge [uint32]($cfg.Minutes * 60000)) { Lock-HUApp }
        })
    $script:LockTimer.Start()
}
