#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung: einmalige Einrichtung bzw. Entfernen (laeuft als Administrator, per UAC aus HU-MultiTenant gestartet).
.DESCRIPTION
    Install: CA (gemeinsam mit HUMig, nur falls noch keine da ist), Server-Zertifikat fuer die privaten IPv4-Adressen und
    Namen dieses PCs, HTTPS-Bindung (http.sys), Port-Freigabe fuer das Benutzerkonto (urlacl) und Firewall-Regel
    (Domaenen-/private Netze, lokales Subnetz + eingetragene Netze, z. B. das VPN). Danach startet die Fernbedienung
    ohne Adminrechte. Gestartet wird eine gepruefte Kopie aus %windir%\Temp\HU-RemoteSetup-<zufaellig>
    (je Lauf neu angelegt, Besitzer Administratoren, nur Administratoren duerfen schreiben; Pruefsummen vom Programm). Uninstall entfernt Bindung, Freigabe, Regel und Server-Zertifikat (die CA bleibt fuer HUMig).
    Das Ergebnis steht als JSON in -ResultFile.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Aufruf nur durch HU-MultiTenant (Knopf Remote FB > Einstellungen).
#>
param(
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall')][string]$Action,
    [Parameter(Mandatory)][ValidateRange(1025, 65535)][int]$Port,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-[\d-]+$')][string]$Sid,
    [ValidatePattern('^[0-9./,; ]*$')][string]$Networks = '',
    [Parameter(Mandatory)][string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$res = [ordered]@{ Ok = $false; Error = ''; Port = $Port; Thumb = ''; Ips = @(); CaFp = '' }
try {
    . (Join-Path $PSScriptRoot 'HU.Remote.ps1')
    if ($Action -eq 'Install') {
        $b = Get-HURemoteBinding $Port
        if ($b.State -eq 'Foreign') {
            $fp = Get-HURemoteFreePort $Port; if ($fp -eq 8443) { $fp = Get-HURemoteFreePort 8443 }
            throw "Port $Port wird bereits von $(if (Test-HURemoteHUMigPort $Port) { 'der HUMig-Fernbedienung' } else { 'einem anderen Programm' }) verwendet - bitte einen anderen Port waehlen$(if ($fp) { " (frei z. B. $fp)" })" }
        $ips = @(Get-HURemoteIPv4List | Where-Object { $_.Private } | ForEach-Object { $_.IP })
        if (-not $ips.Count) { throw 'Keine private IPv4-Adresse gefunden (10.x, 172.16-31.x, 192.168.x)' }
        $ca = Get-HURemoteCa
        if (-not $ca) { $ca = New-HURemoteCa }
        $cert = Get-HURemoteServerCert $ca $ips
        if (-not $cert) { $cert = New-HURemoteServerCert $ca $ips }
        Set-HURemoteBinding $Port $cert.Thumbprint
        Set-HURemoteUrlAcl $Port $Sid $Sid
        $nets = @("$Networks" -split '[,; ]+' | Where-Object { $_ })
        Set-HURemoteFirewall $script:HURemoteRuleSetup $Port (Get-HURemoteFirewallRemote $nets)
        Remove-HURemoteOldCerts $cert.Thumbprint -BoundPorts @($Port)
        $res.Thumb = $cert.Thumbprint; $res.Ips = $ips; $res.CaFp = Get-HURemoteFingerprint $ca
    }
    else {
        Remove-HURemoteBinding $Port
        Remove-HURemoteUrlAcl $Port $Sid
        Remove-HURemoteFirewall $script:HURemoteRuleSetup
        Remove-HURemoteOldCerts @()
    }
    $res.Ok = $true
}
catch { $res.Error = "$($_.Exception.Message)" }
[IO.File]::WriteAllText($ResultFile, ($res | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
