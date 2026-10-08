#Requires -Version 5.1
<#
.SYNOPSIS
    Windows-Integration: Starter HU-MultiTenant.exe (mit Logo, ohne Konsolenfenster) und Verknuepfungen
    (Desktop, Startmenue - eigener Benutzer oder alle Benutzer).
.DESCRIPTION
    HU-MultiTenant.exe wird lokal aus dem C#-Quelltext unten erzeugt (nicht im Repo, kein fremdes Programm).
    Sie startet Windows PowerShell 5.1 unsichtbar mit Main.ps1 - ohne Administratorrechte (Graph braucht keine).
    Die Verknuepfungen zeigen auf die EXE (eigenes Symbol, an die Taskleiste anheftbar); ohne EXE auf Start-HUMultiTenant.cmd.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:LauncherName = 'HU-MultiTenant.exe'
$script:LauncherSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public static class HUMultiTenantLauncher
{
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
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;
        try { Process.Start(psi); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "HU-MultiTenant", MessageBoxButtons.OK, MessageBoxIcon.Error); return 2; }
        return 0;
    }
}
'@

function New-HULauncher {
    param([switch]$Force)
    $exe = Join-Path $script:AppRoot $script:LauncherName
    $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
    if ((Test-Path -LiteralPath $exe) -and -not $Force) { return $true }
    try {
        # alte Reste (*.old) aufraeumen - frueher gesperrte Starter
        Get-ChildItem -LiteralPath $script:AppRoot -Filter "$($script:LauncherName).*.old" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $exe) {
            try { Remove-Item -LiteralPath $exe -Force -ErrorAction Stop }
            catch {
                # gesperrt (OneDrive-Sync, Virenscanner, gerade gestartet): umbenennen geht meist trotzdem
                Rename-Item -LiteralPath $exe -NewName "$($script:LauncherName).$([guid]::NewGuid().ToString('N').Substring(0, 8)).old" -Force -ErrorAction Stop
            }
        }
        $cp = New-Object System.CodeDom.Compiler.CompilerParameters
        $cp.GenerateExecutable = $true
        $cp.GenerateInMemory = $false
        $cp.OutputAssembly = $exe
        $cp.CompilerOptions = '/target:winexe /optimize+' + $(if (Test-Path -LiteralPath $ico) { " /win32icon:`"$ico`"" } else { '' })
        [void]$cp.ReferencedAssemblies.Add('System.dll')
        [void]$cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')
        # eindeutiger Typname (mehrfaches Erzeugen in einer Sitzung)
        $src = $script:LauncherSource -replace 'HUMultiTenantLauncher', ('HUMultiTenantLauncher' + [guid]::NewGuid().ToString('N'))
        Add-Type -TypeDefinition $src -Language CSharp -CompilerParameters $cp -ErrorAction Stop
        return (Test-Path -LiteralPath $exe)
    } catch {
        Write-HULogWarn "Starter $($script:LauncherName) nicht erstellt: $($_.Exception.Message)"
        return (Test-Path -LiteralPath $exe)   # vorhandener Starter bleibt nutzbar
    }
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
        $cmd = if (Test-Path -LiteralPath $exe) { "`"$exe`"" } else {
            "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $script:AppRoot 'Main.ps1')`""
        }
        $ico = Join-Path $script:AppRoot 'Assets\icon.ico'
        [void][HUTaskbar]::SetWindowAppId($hwnd, $script:HUAppId, $cmd, 'HU-MultiTenant', $(if (Test-Path -LiteralPath $ico) { $ico } else { '' }))
    } catch { Write-HULogDebug "Taskleiste: $($_.Exception.Message)" }
}
