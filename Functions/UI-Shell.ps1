#Requires -Version 5.1
<#
.SYNOPSIS
    Windows-Integration: Starter HU-MultiTenant.exe (mit Logo, ohne Konsolenfenster) und Verknuepfungen
    (Desktop, Startmenue - eigener Benutzer oder alle Benutzer).
.DESCRIPTION
    HU-MultiTenant.exe wird lokal aus dem C#-Quelltext unten erzeugt (nicht im Repo, kein fremdes Programm).
    Sie startet Main.ps1 unsichtbar - ohne Administratorrechte (Graph braucht keine) - mit PowerShell 7, wenn installiert,
    sonst mit Windows PowerShell 5.1. Einstellung: Config\powershell-host.txt (auto | 5 | 7), in den Einstellungen waehlbar.
    Aeltere Starter (nur 5.1) werden beim Programmstart automatisch ersetzt (Dateiversion $script:LauncherVersion).
    Die Verknuepfungen zeigen auf die EXE (eigenes Symbol, an die Taskleiste anheftbar); ohne EXE auf Start-HUMultiTenant.cmd.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:LauncherName = 'HU-MultiTenant.exe'
$script:LauncherVersion = '2.0.0'
$script:LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("HU-MultiTenant")]
[assembly: AssemblyFileVersion("2.0.0")]

public static class HUMultiTenantLauncher
{
    // PowerShell 7: Standard-Installation (winget/MSI) oder Microsoft Store
    static string FindPwsh()
    {
        string pf64 = Environment.GetEnvironmentVariable("ProgramW6432");
        string[] c = {
            string.IsNullOrEmpty(pf64) ? null : Path.Combine(pf64, @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe")
        };
        foreach (string p in c) { if (!string.IsNullOrEmpty(p) && File.Exists(p)) return p; }
        return null;
    }
    // Config\powershell-host.txt: auto (Standard) | 5 | 7
    static string HostSetting(string dir)
    {
        try
        {
            string f = Path.Combine(dir, @"Config\powershell-host.txt");
            if (File.Exists(f))
            {
                string v = File.ReadAllText(f).Trim().ToLowerInvariant();
                if (v == "5" || v == "7" || v == "auto") return v;
            }
        }
        catch { }
        return "auto";
    }

    [STAThread]
    public static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps1 = Path.Combine(dir, "Main.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show("Main.ps1 nicht gefunden in:\n" + dir + "\n\nPull.ps1 ausfuehren, um die Dateien zu laden.", "HU-MultiTenant", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        string mode = HostSetting(dir);
        string pwsh = (mode == "5") ? null : FindPwsh();
        if (mode == "7" && pwsh == null)
        {
            MessageBox.Show("In den Einstellungen ist PowerShell 7 gewaehlt, es ist aber nicht installiert.\n\nHU-MultiTenant startet mit Windows PowerShell 5.1.\nInstallieren: winget install Microsoft.PowerShell", "HU-MultiTenant", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        string exe = pwsh ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        // WPF braucht STA (Windows PowerShell startet immer so, pwsh nur mit -STA)
        string arg = "-NoProfile " + (pwsh != null ? "-STA " : "") + "-ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"";
        ProcessStartInfo psi = new ProcessStartInfo(exe, arg);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;
        try { Process.Start(psi); }
        catch (Exception ex)
        {
            if (pwsh == null) { MessageBox.Show(ex.Message, "HU-MultiTenant", MessageBoxButtons.OK, MessageBoxIcon.Error); return 2; }
            // pwsh liess sich nicht starten: Rueckfall auf Windows PowerShell 5.1
            try
            {
                ProcessStartInfo p5 = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"), "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
                p5.UseShellExecute = false; p5.CreateNoWindow = true; p5.WindowStyle = ProcessWindowStyle.Hidden; p5.WorkingDirectory = dir;
                Process.Start(p5);
            }
            catch (Exception ex2) { MessageBox.Show(ex2.Message, "HU-MultiTenant", MessageBoxButtons.OK, MessageBoxIcon.Error); return 2; }
        }
        return 0;
    }
}
'@

# ----------------------------------------------------------------------------
# Welche PowerShell startet die App? (gleiche Regel wie im Starter HU-MultiTenant.exe und in Start-HUMultiTenant.cmd)
# ----------------------------------------------------------------------------
function Get-HUPwshPath {
    $c = @()
    if ($env:ProgramW6432) { $c += (Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe') }
    if ($env:ProgramFiles) { $c += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') }
    if ($env:LOCALAPPDATA) { $c += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe') }
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return ''
}
function Get-HUPsHostFile { return (Join-Path $script:AppRoot 'Config\powershell-host.txt') }
# auto (Standard) | 5 | 7
function Get-HUPsHostSetting {
    $f = Get-HUPsHostFile
    try { if (Test-Path -LiteralPath $f) { $v = ([IO.File]::ReadAllText($f)).Trim().ToLowerInvariant(); if ($v -in 'auto', '5', '7') { return $v } } } catch { }
    return 'auto'
}
function Set-HUPsHostSetting([ValidateSet('auto', '5', '7')][string]$Value) {
    $f = Get-HUPsHostFile
    if ($Value -eq 'auto') { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }; return }
    [IO.File]::WriteAllText($f, $Value, (New-Object System.Text.UTF8Encoding $false))
}
# Programm und Argumente fuer einen Start von Main.ps1 (Neustart, Taskleiste). -Extra: weitere Argumente fuer Main.ps1
function Get-HUAppStartInfo([string]$Extra = '') {
    $mode = Get-HUPsHostSetting
    $pw = $(if ($mode -eq '5') { '' } else { Get-HUPwshPath })
    $exe = $(if ($pw) { $pw } else { [IO.Path]::Combine("$env:SystemRoot", 'System32\WindowsPowerShell\v1.0\powershell.exe') })
    $a = "-NoProfile $(if ($pw) { '-STA ' })-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $script:AppRoot 'Main.ps1')`"$(if ($Extra) { " $Extra" })"
    return [pscustomobject]@{ Exe = $exe; Args = $a; Is7 = [bool]$pw }
}
# Anzeige: laufende Version und was beim naechsten Start genommen wird
function Get-HUPsHostInfoText {
    $pw = Get-HUPwshPath
    $run = "Laeuft gerade mit $(if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' }) $($PSVersionTable.PSVersion)."
    $next = switch (Get-HUPsHostSetting) {
        '5' { 'Naechster Start: Windows PowerShell 5.1.' }
        '7' { $(if ($pw) { 'Naechster Start: PowerShell 7.' } else { 'PowerShell 7 ist nicht installiert - Start mit 5.1 (winget install Microsoft.PowerShell).' }) }
        default { $(if ($pw) { 'Naechster Start: PowerShell 7 (installiert).' } else { 'Naechster Start: Windows PowerShell 5.1 (PowerShell 7 nicht installiert).' }) }
    }
    return "$run $next"
}

# Dateiversion des vorhandenen Starters ('' = keiner oder alter Starter ohne Version)
function Get-HULauncherVersion {
    $exe = Join-Path $script:AppRoot $script:LauncherName
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    try { return "$((Get-Item -LiteralPath $exe).VersionInfo.FileVersion)".Trim() } catch { return '' }
}
# Starter erzeugen. Ohne -Force nur, wenn er fehlt oder aelter ist (bestehende Installationen bekommen so den neuen Starter).
# Uebersetzt wird mit csc.exe des .NET Framework (unter PS 5.1 und PS 7 gleich; PS 7 kann keine .exe per Add-Type erzeugen).
function New-HULauncher {
    param([switch]$Force)
    $exe = Join-Path $script:AppRoot $script:LauncherName
    $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
    if ((Test-Path -LiteralPath $exe) -and -not $Force -and (Get-HULauncherVersion) -eq $script:LauncherVersion) { return $true }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("HU-Starter-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $csc) { throw 'csc.exe (.NET Framework 4) nicht gefunden' }
        # alte Reste (*.old) aufraeumen - frueher gesperrte Starter
        Get-ChildItem -LiteralPath $script:AppRoot -Filter "$($script:LauncherName).*.old" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        [void](New-Item -ItemType Directory -Path $tmp -Force)
        $src = Join-Path $tmp 'Starter.cs'; $out = Join-Path $tmp $script:LauncherName
        [IO.File]::WriteAllText($src, $script:LauncherSource, (New-Object System.Text.UTF8Encoding $false))
        $a = @('/nologo', '/target:winexe', '/optimize+', "/out:$out", '/r:System.Windows.Forms.dll')
        if (Test-Path -LiteralPath $ico) { $a += "/win32icon:$ico" }
        $msg = & $csc @a $src 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw "csc: $((@($msg) | Select-Object -First 3) -join ' ')" }
        if (Test-Path -LiteralPath $exe) {
            try { Remove-Item -LiteralPath $exe -Force -ErrorAction Stop }
            catch {
                # gesperrt (OneDrive-Sync, Virenscanner, gerade gestartet): umbenennen geht meist trotzdem
                Rename-Item -LiteralPath $exe -NewName "$($script:LauncherName).$([guid]::NewGuid().ToString('N').Substring(0, 8)).old" -Force -ErrorAction Stop
            }
        }
        Move-Item -LiteralPath $out -Destination $exe -Force
        Write-HULogOK "Starter $($script:LauncherName) $($script:LauncherVersion) erstellt (PowerShell 7, wenn installiert, sonst 5.1)"
        return (Test-Path -LiteralPath $exe)
    } catch {
        Write-HULogWarn "Starter $($script:LauncherName) nicht erstellt: $($_.Exception.Message)"
        return (Test-Path -LiteralPath $exe)   # vorhandener Starter bleibt nutzbar
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Verknuepfung anlegen. -Location Desktop | StartMenu, -AllUsers = oeffentlicher Desktop / Startmenue aller Benutzer (Adminrechte)
function New-HUShortcut {
    param([ValidateSet('Desktop', 'StartMenu')][string]$Location = 'Desktop', [switch]$AllUsers)
    $exe = Join-Path $script:AppRoot $script:LauncherName
    [void](New-HULauncher -Force)   # immer neu erzeugen (aktuelles Logo, aktueller Ordner)
    $folder = switch ("$Location$([bool]$AllUsers)") {
        'DesktopFalse'   { [Environment]::GetFolderPath('Desktop') }
        'DesktopTrue'    { [Environment]::GetFolderPath('CommonDesktopDirectory') }
        'StartMenuFalse' { [Environment]::GetFolderPath('Programs') }
        'StartMenuTrue'  { [Environment]::GetFolderPath('CommonPrograms') }
    }
    if (-not $folder) { throw 'Zielordner nicht gefunden' }
    $lnk = Join-Path $folder 'HU-MultiTenant.lnk'
    $sh = New-Object -ComObject WScript.Shell
    try {
        $s = $sh.CreateShortcut($lnk)
        if (Test-Path -LiteralPath $exe) {
            $s.TargetPath = $exe
            $s.IconLocation = "$exe,0"
        } else {
            $s.TargetPath = Join-Path $script:AppRoot 'Start-HUMultiTenant.cmd'
            $s.WindowStyle = 7
            $s.IconLocation = "$(Join-Path $script:AppRoot 'Assets\icon.ico'),0"
        }
        $s.WorkingDirectory = $script:AppRoot
        $s.Description = 'HU-MultiTenant - Microsoft 365 / Intune fuer mehrere Tenants'
        $s.Save()
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
    return $lnk
}

# Gibt es schon eine Verknuepfung (eigener Desktop / Startmenue)?
function Test-HUShortcut {
    foreach ($f in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
        if ($f -and (Test-Path -LiteralPath (Join-Path $f 'HU-MultiTenant.lnk'))) { return $true }
    }
    return $false
}

# ============================================================================
# Taskleiste: eigenes Symbol statt PowerShell
#   Ohne eigene AppUserModelID gruppiert Windows das Fenster unter powershell.exe (PowerShell-Symbol).
#   Mit eigener ID nimmt die Taskleiste das Fenstersymbol; RelaunchCommand sorgt dafuer, dass
#   "An Taskleiste anheften" den Starter HU-MultiTenant.exe anheftet (nicht powershell.exe).
#   Quelle: learn.microsoft.com/windows/win32/shell/appids
# ============================================================================
$script:HUAppId = 'ChiliApple.HU-MultiTenant'
$script:HUTaskbarSource = @'
using System;
using System.Runtime.InteropServices;

public static class HUTaskbar
{
    [DllImport("shell32.dll")]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);

    [DllImport("shell32.dll")]
    private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant pv);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey { public Guid FmtId; public uint Pid; }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Vt;
        [FieldOffset(8)] public IntPtr Ptr;
        [FieldOffset(16)] public IntPtr Pad;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    // PKEY_AppUserModel_*: RelaunchCommand = 2, RelaunchIconResource = 3, RelaunchDisplayNameResource = 4, ID = 5
    private static readonly Guid AppUserModelFmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    private static void SetString(IPropertyStore store, uint pid, string value)
    {
        PropertyKey key = new PropertyKey { FmtId = AppUserModelFmt, Pid = pid };
        PropVariant pv = new PropVariant { Vt = 31, Ptr = Marshal.StringToCoTaskMemUni(value) };   // VT_LPWSTR
        try { store.SetValue(ref key, ref pv); }
        finally { PropVariantClear(ref pv); }
    }

    public static bool SetWindowAppId(IntPtr hwnd, string appId, string relaunchCommand, string displayName, string iconResource)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) { return false; }
        try
        {
            if (!String.IsNullOrEmpty(relaunchCommand)) { SetString(store, 2, relaunchCommand); }
            if (!String.IsNullOrEmpty(iconResource)) { SetString(store, 3, iconResource); }
            if (!String.IsNullOrEmpty(displayName)) { SetString(store, 4, displayName); }
            SetString(store, 5, appId);
            store.Commit();
            return true;
        }
        finally { Marshal.ReleaseComObject(store); }
    }
}
'@

# Vor dem ersten Fenster aufrufen
function Initialize-HUTaskbar {
    try {
        if (-not ('HUTaskbar' -as [type])) { Add-Type -TypeDefinition $script:HUTaskbarSource -Language CSharp -ErrorAction Stop }
        [void][HUTaskbar]::SetCurrentProcessExplicitAppUserModelID($script:HUAppId)
        return $true
    } catch { Write-HULogDebug "Taskleiste: $($_.Exception.Message)"; return $false }
}

# Hauptfenster: ID + Neustart-Befehl fuer "An Taskleiste anheften" (nach SourceInitialized)
function Set-HUWindowTaskbar($Window) {
    try {
        if (-not ('HUTaskbar' -as [type])) { return }
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $exe = Join-Path $script:AppRoot $script:LauncherName
        $cmd = if (Test-Path -LiteralPath $exe) { "`"$exe`"" } else { $si = Get-HUAppStartInfo; "`"$($si.Exe)`" $($si.Args)" }
        $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
        [void][HUTaskbar]::SetWindowAppId($hwnd, $script:HUAppId, $cmd, 'HU-MultiTenant', $(if (Test-Path -LiteralPath $ico) { $ico } else { '' }))
    } catch { Write-HULogDebug "Taskleiste: $($_.Exception.Message)" }
}
