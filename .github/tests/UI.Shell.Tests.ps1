#Requires -Version 5.1
# Pester 5: Starter und Wahl der PowerShell (PowerShell 7, wenn installiert - sonst 5.1)
BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    function Write-HULogWarn { param($Message) }
    function Write-HULogOK { param($Message) }
    function Write-HULogDebug { param($Message) }
    . (Join-Path $root 'Functions\UI-Shell.ps1')
    $script:AppRoot = Join-Path $TestDrive 'app'
    [void](New-Item -ItemType Directory -Path (Join-Path $script:AppRoot 'Config') -Force)
    if (-not $env:SystemRoot) { $env:SystemRoot = 'C:\Windows' }
}
Describe 'PowerShell beim Start' {
    AfterEach { Remove-Item -LiteralPath (Get-HUPsHostFile) -Force -ErrorAction SilentlyContinue }
    It 'Standard auto: PowerShell 7 mit -STA, wenn installiert' {
        function Get-HUPwshPath { 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Get-HUPsHostSetting | Should -Be 'auto'
        $si = Get-HUAppStartInfo '-WaitForPid 42'
        $si.Exe | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $si.Is7 | Should -BeTrue
        $si.Args | Should -Match '-STA'
        $si.Args | Should -Match 'Main\.ps1" -WaitForPid 42$'
    }
    It 'auto ohne PowerShell 7 und Einstellung 5: Windows PowerShell 5.1 ohne -STA' {
        function Get-HUPwshPath { '' }
        $si = Get-HUAppStartInfo
        $si.Exe | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $si.Args | Should -Not -Match '-STA'
        function Get-HUPwshPath { 'C:\x\pwsh.exe' }
        Set-HUPsHostSetting '5'
        Get-HUPsHostSetting | Should -Be '5'
        (Get-HUAppStartInfo).Is7 | Should -BeFalse
    }
    It 'Einstellung speichern: auto loescht die Datei, ungueltiger Inhalt gilt als auto' {
        Set-HUPsHostSetting '7'; Test-Path -LiteralPath (Get-HUPsHostFile) | Should -BeTrue
        Set-HUPsHostSetting 'auto'; Test-Path -LiteralPath (Get-HUPsHostFile) | Should -BeFalse
        [IO.File]::WriteAllText((Get-HUPsHostFile), 'quatsch'); Get-HUPsHostSetting | Should -Be 'auto'
    }
    It 'Starter-Quelltext: gleiche Datei, gleiche Version, STA fuer pwsh' {
        $script:LauncherSource | Should -Match 'powershell-host\.txt'
        $script:LauncherSource | Should -Match ([regex]::Escape("AssemblyFileVersion(`"$script:LauncherVersion`")"))
        $script:LauncherSource | Should -Match '"-STA "'
        (Get-Content -LiteralPath (Join-Path $root 'Start-HUMultiTenant.cmd') -Raw) | Should -Match 'powershell-host\.txt'
        (Get-Content -LiteralPath (Join-Path $root 'Pull.ps1') -Raw) | Should -Match 'powershell-host\.txt'
    }
    It 'Starter laesst sich uebersetzen und traegt die Version (nur Windows)' -Skip:(-not ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5)) {
        Copy-Item -LiteralPath (Join-Path $root 'Assets') -Destination (Join-Path $script:AppRoot 'Assets') -Recurse -Force
        New-HULauncher -Force | Should -BeTrue
        Get-HULauncherVersion | Should -Be $script:LauncherVersion
        # aktueller Starter wird ohne -Force nicht neu gebaut
        $t = (Get-Item -LiteralPath (Join-Path $script:AppRoot 'HU-MultiTenant.exe')).LastWriteTimeUtc
        New-HULauncher | Should -BeTrue
        (Get-Item -LiteralPath (Join-Path $script:AppRoot 'HU-MultiTenant.exe')).LastWriteTimeUtc | Should -Be $t
    }
}
