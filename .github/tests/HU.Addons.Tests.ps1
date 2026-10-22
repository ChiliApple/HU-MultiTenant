#Requires -Version 5.1
<#
.SYNOPSIS
    Pester-Tests (Pester 5) fuer Zusatzmodule (Functions\Core-Addons.ps1): Pruefen, Laden, Installieren - ohne Netzwerk.
#>

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . (Join-Path $root 'Functions\Core-Update.ps1')
    . (Join-Path $root 'Functions\Core-Addons.ps1')
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("HU-Addon-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
    # Test-Zertifikat (selbst signiert, nur im Speicher)
    function script:New-TestCert([string]$Cn) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList "CN=$Cn", $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $c = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(30))
        # ueber PFX neu laden, damit der private Schluessel auch unter Windows PowerShell 5.1 fuer SignedCms nutzbar ist
        [byte[]]$pfx = $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'x')
        return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, 'x', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    }
    $script:Cert = New-TestCert 'HU Test Signer'
    $script:Other = New-TestCert 'Fremd'
    # Modul-Ordner bauen: Dateien + signierte Pruefsummen-Datei
    function script:New-TestAddon([string]$Dir, [string]$Id = 'Testmodul', [string]$MinApp = '2.3.1', $Cert = $script:Cert, [string]$Version = '1.0.0') {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $j = [ordered]@{ id = $Id; title = 'Test'; version = $Version; minApp = $MinApp; tab = [ordered]@{ header = 'Test'; xaml = 'Tab.xaml'; script = 'Addon.ps1'; init = "Initialize-HUAddon$Id" } }
        [System.IO.File]::WriteAllText((Join-Path $Dir 'addon.json'), ($j | ConvertTo-Json -Depth 4))
        [System.IO.File]::WriteAllText((Join-Path $Dir 'Tab.xaml'), '<TabItem xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Header="Test"/>')
        [System.IO.File]::WriteAllText((Join-Path $Dir 'Addon.ps1'), "function Initialize-HUAddon$Id { }")
        $lines = foreach ($f in 'Addon.ps1', 'Tab.xaml', 'addon.json') { "$(Get-HMFileSha256 (Join-Path $Dir $f))  $f" }
        $man = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
        [System.IO.File]::WriteAllBytes((Join-Path $Dir 'addon.sha256'), $man)
        [System.IO.File]::WriteAllBytes((Join-Path $Dir 'addon.sha256.p7s'), (New-HMManifestSignature $man $Cert))
    }
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Zusatzmodule: Pruefen' {
    It 'gueltiges Modul wird akzeptiert und geladen' {
        $base = Join-Path $script:Tmp 'a1'; New-TestAddon (Join-Path $base 'Testmodul')
        Test-HUAddonFiles (Join-Path $base 'Testmodul') $script:Cert.Thumbprint | Should -Be ''
        # weitere Dateien ohne Skript-Endung (z. B. README) sind erlaubt
        Set-Content -LiteralPath (Join-Path $base 'Testmodul\Notiz.md') -Value 'x'
        Test-HUAddonFiles (Join-Path $base 'Testmodul') $script:Cert.Thumbprint | Should -Be ''
        $l = @(Get-HUAddonsToLoad $base ([Version]'2.3.1') $script:Cert.Thumbprint)
        $l.Count | Should -Be 1; $l[0].Error | Should -Be ''; $l[0].Init | Should -Be 'Initialize-HUAddonTestmodul'
    }
    It 'fremdes Zertifikat, veraenderte und zusaetzliche Dateien werden abgelehnt' {
        $d = Join-Path $script:Tmp 'a2\Testmodul'; New-TestAddon $d -Cert $script:Other
        Test-HUAddonFiles $d $script:Cert.Thumbprint | Should -Match 'anderen Zertifikat'
        $d = Join-Path $script:Tmp 'a3\Testmodul'; New-TestAddon $d
        Add-Content -LiteralPath (Join-Path $d 'Addon.ps1') -Value 'Write-Host boese'
        Test-HUAddonFiles $d $script:Cert.Thumbprint | Should -Match 'veraendert'
        $d = Join-Path $script:Tmp 'a4\Testmodul'; New-TestAddon $d
        Set-Content -LiteralPath (Join-Path $d 'Extra.ps1') -Value 'x'
        Test-HUAddonFiles $d $script:Cert.Thumbprint | Should -Match 'fremde Datei'
        Remove-Item -LiteralPath (Join-Path $d 'addon.sha256.p7s')
        Test-HUAddonFiles $d $script:Cert.Thumbprint | Should -Match 'fehlt'
    }
    It 'Mindestversion, Ordnername und addon.json werden geprueft' {
        $base = Join-Path $script:Tmp 'a5'; New-TestAddon (Join-Path $base 'Testmodul') -MinApp '2.4.0'
        (@(Get-HUAddonsToLoad $base ([Version]'2.3.1') $script:Cert.Thumbprint))[0].Error | Should -Match '2.4.0'
        $base = Join-Path $script:Tmp 'a6'; New-TestAddon (Join-Path $base 'Anderer') -Id 'Testmodul'
        (@(Get-HUAddonsToLoad $base ([Version]'2.3.1') $script:Cert.Thumbprint))[0].Error | Should -Match 'Ordnername'
        $d = Join-Path $script:Tmp 'a7'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'addon.json') -Value '{"id":"Test","version":"1.0","minApp":"2.3.1","tab":{"xaml":"..\\boese.xaml","script":"Addon.ps1","init":"Initialize-HUAddonTest"}}'
        (Read-HUAddonInfo $d).Error | Should -Match 'tab'
        Set-Content -LiteralPath (Join-Path $d 'addon.json') -Value '{"id":"Test","version":"1.0","minApp":"2.3.1","tab":{"xaml":"Tab.xaml","script":"Addon.ps1","init":"Remove-Item"}}'
        (Read-HUAddonInfo $d).Error | Should -Match 'tab'
        Set-Content -LiteralPath (Join-Path $d 'addon.json') -Value '{"id":"1x","version":"1.0","minApp":"2.3.1"}'
        (Read-HUAddonInfo $d).Error | Should -Match 'Kennung'
    }
    It 'wartende Fassung wird beim Start uebernommen' {
        $base = Join-Path $script:Tmp 'a8'
        New-TestAddon (Join-Path $base 'Testmodul') -Version '1.0.0'
        New-TestAddon (Join-Path $base '.pending\Testmodul') -Version '1.1.0'
        Use-HUAddonPending $base
        (Read-HUAddonInfo (Join-Path $base 'Testmodul')).Version | Should -Be ([Version]'1.1.0')
        Test-Path -LiteralPath (Join-Path $base '.pending\Testmodul') | Should -BeFalse
    }
}

Describe 'Zusatzmodule: Installieren (ohne Netzwerk)' {
    BeforeAll {
        $script:Src = Join-Path $script:Tmp 'src\Testmodul'; New-TestAddon $script:Src -Version '1.2.0'
        $script:Man = [System.IO.File]::ReadAllBytes((Join-Path $script:Src 'addon.sha256'))
        $script:Sig = [System.IO.File]::ReadAllBytes((Join-Path $script:Src 'addon.sha256.p7s'))
    }
    BeforeEach {
        Mock Get-HMReleases { @([pscustomobject]@{ Version = [Version]'1.2.0'; Tag = 'v1.2.0'; Prerelease = $false; ManifestUrl = 'm'; ManifestApi = 'm'; SignatureUrl = 's'; SignatureApi = 's' }) }
        Mock Get-HMReleaseAsset { param($Url) if ($Url -eq 'm') { , $script:Man } else { , $script:Sig } }
        Mock Invoke-WebRequest { param($Uri, $Headers, $OutFile) $n = [uri]::UnescapeDataString((($Uri -split '/contents/')[1] -split '\?')[0]); Copy-Item -LiteralPath (Join-Path $script:Src $n) -Destination $OutFile -Force }
    }
    It 'laedt, prueft und legt die Fassung zum naechsten Start bereit' {
        $dir = Join-Path $script:Tmp 'inst1'
        $r = Install-HUAddon -Owner 'o' -Repo 'r' -Token 't' -AddonsDir $dir -AppVersion ([Version]'2.3.1') -Thumbprint $script:Cert.Thumbprint
        $r.Status | Should -Be 'Neu'; $r.Id | Should -Be 'Testmodul'
        Test-HUAddonFiles (Join-Path $dir '.pending\Testmodul') $script:Cert.Thumbprint | Should -Be ''
        Use-HUAddonPending $dir
        (Install-HUAddon -Owner 'o' -Repo 'r' -Token 't' -AddonsDir $dir -AppVersion ([Version]'2.3.1') -Thumbprint $script:Cert.Thumbprint).Status | Should -Be 'Aktuell'
    }
    It 'falsches Zertifikat, veraenderte Datei oder zu alte Programmversion: nichts wird abgelegt' {
        $dir = Join-Path $script:Tmp 'inst2'
        (Install-HUAddon -Owner 'o' -Repo 'r' -Token 't' -AddonsDir $dir -AppVersion ([Version]'2.3.1') -Thumbprint $script:Other.Thumbprint).Status | Should -Be 'Fehler'
        (Install-HUAddon -Owner 'o' -Repo 'r' -Token 't' -AddonsDir $dir -AppVersion ([Version]'2.3.0') -Thumbprint $script:Cert.Thumbprint).Text | Should -Match '2.3.1'
        Mock Invoke-WebRequest { param($Uri, $Headers, $OutFile) Set-Content -LiteralPath $OutFile -Value 'manipuliert' }
        (Install-HUAddon -Owner 'o' -Repo 'r' -Token 't' -AddonsDir $dir -AppVersion ([Version]'2.3.1') -Thumbprint $script:Cert.Thumbprint).Text | Should -Match 'Pruefsumme'
        Test-Path -LiteralPath (Join-Path $dir '.pending\Testmodul') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $dir '.staging') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Zusatzmodule: Einbindung' {
    It 'Main laedt Module nach den Handlern, Update-Menue hat den Eintrag, Reiter blendet Extension-Liste aus' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $main = Get-Content -LiteralPath (Join-Path $root 'Main.ps1') -Raw
        $main | Should -Match "'Core-Addons'"
        $main | Should -Match 'Get-HUAddonStartList'
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Update.ps1') -Raw) | Should -Match 'Show-HUAddonDialog'
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-State.ps1') -Raw) | Should -Match "Tag\)`" -eq 'addon'"
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-State.ps1') -Raw) | Should -Match "mode -like 'tab\*'"
        (Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) | Should -Match '(?m)^Addons/'
        (Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) | Should -Match '(?m)^AddonsDev/'
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Addons.ps1') -Raw) | Should -Match "'AddonsDev'"
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Remote.ps1') -Raw) | Should -Match 'Get-HUAddonRemoteItems'
        (Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Update.ps1') -Raw) | Should -Match 'Start-HUReleaseSigning -Addon'
    }
}

Describe 'Zusatzmodule: Neustart' {
    It 'startet die neue Instanz direkt (wartet auf diese), ohne verschluesselten Hilfsbefehl' {
        $ui = Get-Content -LiteralPath (Join-Path $root 'Functions\UI-Addons.ps1') -Raw
        $fn = [regex]::Match($ui, '(?s)function Restart-HUApp \{.*?\n\}').Value
        $fn | Should -Match '-WaitForPid \$PID'
        $fn | Should -Not -Match 'EncodedCommand'
        $main = Get-Content -LiteralPath (Join-Path $root 'Main.ps1') -Raw
        $main | Should -Match '\[int\]\$WaitForPid = 0'
        # Warten vor der Einzelinstanz-Pruefung, sonst meldet die neue Instanz "laeuft bereits"
        $main.IndexOf('$WaitForPid -gt 0') | Should -BeLessThan $main.IndexOf('Local\HU-MultiTenant_')
    }
}
