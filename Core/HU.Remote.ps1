#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung (Kern): QR-Code, Kopplung, PIN, Zertifikate, Webserver-Anfragen - ohne Oberflaeche.
.DESCRIPTION
    Wird von UI-Remote.ps1 (Oberflaeche) und im Hintergrund-Runspace des Webservers geladen. Kein WPF-Code hier.
    - QR-Code (Byte-Modus, Fehlerkorrektur M, Version 1-10) ohne fremde Bibliothek
    - Geraete-Token (256 Bit, gespeichert wird nur der SHA256-Hash), Kopplungscode (6 Ziffern)
    - Fernbedienungs-PIN (nur Ziffern, mind. 4): gespeichert nur als PBKDF2-Hash, Pflicht bei jedem echten Lauf
    - Zertifikat: dieselbe CA wie HUMig ("HUMig Fernbedienung CA" je PC), eigenes Server-Zertifikat und eigener Port
    - Start eines Laufs in zwei Schritten: prepare (Pruefung, Zusammenfassung, Einmal-Bestaetigung 120 s) und run
    - Anfragen beantworten (Get-HURemoteResponse, ohne HttpListener testbar) und Webserver-Schleife
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

# ============================================================================
# GRUNDWERTE
# ============================================================================
$script:HURemoteAppId     = '{7d3f2b8e-5c41-4a6e-9f0d-2b8a61c4e937}'   # Kennung der HTTPS-Bindung (netsh http ... appid)
$script:HURemoteCaName    = 'HUMig Fernbedienung CA'                   # gemeinsam mit HUMig
$script:HURemoteCertName  = 'HU-MultiTenant Fernbedienung'
$script:HURemoteRuleSetup = 'HU-MultiTenant-Remote'                    # Firewall-Regel (einmalige Einrichtung)
$script:HURemoteDefaultPort = 8444   # HUMig nutzt 8443 - beide koennen gleichzeitig laufen
$script:HURemoteHUMigAppId = '2e99e3ca-a9bd-4634-8f4c-3cf57952321e'   # Kennung der HTTPS-Bindung von HUMig (wird nie veraendert)
$script:HURemoteMaxDevices  = 5
$script:HURemoteMaxBody     = 16384
$script:HURemoteMaxLines    = 2000
$script:HURemotePairMinutes = 10
$script:HURemoteConfirmSec  = 120   # Einmal-Bestaetigung (Review 031 B7)
$script:HURemoteTokenDays   = 90    # ungenutztes Handy verliert die Kopplung nach 90 Tagen (Review 031 B15)
$script:HURemotePinMin      = 4
$script:HURemotePinMax      = 12
$script:HURemotePinFails    = 3     # danach ist das Handy gesperrt, entsperren nur am PC (Review 031 B4)
$script:HURemotePinRounds   = 200000
$script:HURemotePrivateNets = @(@('10.0.0.0', '255.0.0.0'), @('172.16.0.0', '255.240.0.0'), @('192.168.0.0', '255.255.0.0'))
# Parameternamen, die nie gesetzt werden duerfen (Review 031 B5)
$script:HURemoteBlockedParams = '^(?i)(TenantKey|Schule|Token|Tenants|Settings|AppRoot|Host|Input|Args|Error|_|this|true|false|null|PSItem|Matches|LastExitCode|PSDefaultParameterValues|ExecutionContext|PWD|HOME|PID|ShellId|StackTrace|PS.*|.*Preference|__.*)$'

# ============================================================================
# QR-CODE (ISO/IEC 18004): Byte-Modus, Fehlerkorrektur M, Version 1-10
# ============================================================================
# je Version: Bloecke Gruppe 1 (Anzahl, Datenwoerter), Gruppe 2 (Anzahl, Datenwoerter), Korrekturwoerter je Block
$script:HURQrGfExp = $null; $script:HURQrGfLog = $null   # Tabellen, beim ersten QR-Code berechnet (vorbelegt wegen Set-StrictMode in Main.ps1)
$script:HURQrM = @{
    1 = @(1, 16, 0, 0, 10); 2 = @(1, 28, 0, 0, 16); 3 = @(1, 44, 0, 0, 26); 4 = @(2, 32, 0, 0, 18); 5 = @(2, 43, 0, 0, 24)
    6 = @(4, 27, 0, 0, 16); 7 = @(4, 31, 0, 0, 18); 8 = @(2, 38, 2, 39, 22); 9 = @(3, 36, 2, 37, 22); 10 = @(4, 43, 1, 44, 26)
}
$script:HURQrAlign = @{ 1 = @(); 2 = @(6, 18); 3 = @(6, 22); 4 = @(6, 26); 5 = @(6, 30); 6 = @(6, 34); 7 = @(6, 22, 38); 8 = @(6, 24, 42); 9 = @(6, 26, 46); 10 = @(6, 28, 50) }

# Galois-Feld 256 (Polynom 0x11D): Exponent- und Logarithmus-Tabellen
function Get-HURQrGf {
    if (-not $script:HURQrGfExp) {
        $exp = New-Object int[] 512
        $log = New-Object int[] 256
        $x = 1
        for ($i = 0; $i -lt 255; $i++) {
            $exp[$i] = $x; $log[$x] = $i
            $x = $x -shl 1
            if ($x -band 0x100) { $x = $x -bxor 0x11D }
        }
        for ($i = 255; $i -lt 512; $i++) { $exp[$i] = $exp[$i - 255] }
        $script:HURQrGfExp = $exp; $script:HURQrGfLog = $log
    }
}

# Reed-Solomon-Korrekturwoerter fuer einen Datenblock
function Get-HURQrEcc([byte[]]$Data, [int]$Count) {
    Get-HURQrGf
    $exp = $script:HURQrGfExp; $log = $script:HURQrGfLog
    # Generatorpolynom (x - a^0)(x - a^1)...(x - a^(Count-1)), Koeffizienten hoechster Grad zuerst
    $g = New-Object int[] ($Count + 1)
    $g[0] = 1
    for ($i = 0; $i -lt $Count; $i++) {
        for ($j = $i + 1; $j -ge 1; $j--) {
            $v = 0
            if ($g[$j - 1] -ne 0) { $v = $exp[$log[$g[$j - 1]] + $i] }
            $g[$j] = $g[$j] -bxor $v
        }
    }
    $rem = New-Object int[] $Count
    foreach ($d in $Data) {
        $f = ([int]$d) -bxor $rem[0]
        for ($k = 0; $k -lt $Count - 1; $k++) { $rem[$k] = $rem[$k + 1] }
        $rem[$Count - 1] = 0
        if ($f -ne 0) {
            $lf = $log[$f]
            for ($k = 0; $k -lt $Count; $k++) { if ($g[$k + 1] -ne 0) { $rem[$k] = $rem[$k] -bxor $exp[$lf + $log[$g[$k + 1]]] } }
        }
    }
    $out = New-Object byte[] $Count
    for ($k = 0; $k -lt $Count; $k++) { $out[$k] = [byte]$rem[$k] }
    return , $out
}

# Maskenmuster (x = Spalte, y = Zeile)
function Test-HURQrMask([int]$Mask, [int]$X, [int]$Y) {
    switch ($Mask) {
        0 { return (($X + $Y) % 2 -eq 0) }
        1 { return ($Y % 2 -eq 0) }
        2 { return ($X % 3 -eq 0) }
        3 { return (($X + $Y) % 3 -eq 0) }
        4 { return (([Math]::Floor($X / 3) + [Math]::Floor($Y / 2)) % 2 -eq 0) }
        5 { return ((($X * $Y) % 2 + ($X * $Y) % 3) -eq 0) }
        6 { return (((($X * $Y) % 2 + ($X * $Y) % 3) % 2) -eq 0) }
        default { return (((($X + $Y) % 2 + ($X * $Y) % 3) % 2) -eq 0) }
    }
}

# Strafpunkte einer fertigen Matrix (Regeln 1-4 der Norm), kleiner = besser lesbar
function Get-HURQrPenalty([byte[]]$M, [int]$N) {
    $p = 0
    $lines = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    for ($a = 0; $a -lt $N; $a++) {
        [void]$sb.Clear(); for ($b = 0; $b -lt $N; $b++) { [void]$sb.Append([char](48 + $M[$a * $N + $b])) }; $lines.Add($sb.ToString())
        [void]$sb.Clear(); for ($b = 0; $b -lt $N; $b++) { [void]$sb.Append([char](48 + $M[$b * $N + $a])) }; $lines.Add($sb.ToString())
    }
    foreach ($l in $lines) {
        # Regel 1: 5 und mehr gleiche Module in Folge
        foreach ($rm in [regex]::Matches($l, '0{5,}|1{5,}')) { $p += 3 + ($rm.Length - 5) }
        # Regel 3: 1011101 mit 4 hellen Modulen davor oder danach (ausserhalb der Matrix = hell)
        $pd = '0000' + $l + '0000'
        $i = $pd.IndexOf('1011101')
        while ($i -ge 0) {
            if ($pd.Substring($i - 4, 4) -eq '0000' -or ($i + 11 -le $pd.Length -and $pd.Substring($i + 7, 4) -eq '0000')) { $p += 40 }
            $i = $pd.IndexOf('1011101', $i + 1)
        }
    }
    # Regel 2: 2x2-Bloecke gleicher Farbe
    for ($y = 0; $y -lt $N - 1; $y++) {
        for ($x = 0; $x -lt $N - 1; $x++) {
            $k = $y * $N + $x; $c = $M[$k]
            if ($c -eq $M[$k + 1] -and $c -eq $M[$k + $N] -and $c -eq $M[$k + $N + 1]) { $p += 3 }
        }
    }
    # Regel 4: Anteil dunkler Module
    $dark = 0; foreach ($v in $M) { $dark += $v }
    $pct = $dark * 100.0 / ($N * $N)
    $p += [int][Math]::Floor([Math]::Abs($pct - 50) / 5) * 10
    return $p
}

# Text -> QR-Matrix. Rueckgabe: @{ Size; Version; Mask; Modules (byte[], Zeile fuer Zeile, 1 = dunkel) }
# -Mask 0..7 erzwingt eine Maske (Tests), sonst die mit den wenigsten Strafpunkten
function ConvertTo-HURQrMatrix {
    param([Parameter(Mandatory)][string]$Text, [int]$Mask = -1)
    $data = [Text.Encoding]::UTF8.GetBytes($Text)
    $ver = 0
    for ($v = 1; $v -le 10; $v++) {
        $b = $script:HURQrM[$v]
        $cap = $b[0] * $b[1] + $b[2] * $b[3]
        $ccBits = if ($v -le 9) { 8 } else { 16 }
        if (4 + $ccBits + 8 * $data.Length -le 8 * $cap) { $ver = $v; break }
    }
    if (-not $ver) { throw "Text zu lang fuer den QR-Code ($($data.Length) Bytes)" }
    $blk = $script:HURQrM[$ver]
    $cap = $blk[0] * $blk[1] + $blk[2] * $blk[3]
    $ccBits = if ($ver -le 9) { 8 } else { 16 }

    # Bitstrom: Modus 0100, Laenge, Daten, Abschluss, Fuellbytes
    $bits = New-Object System.Collections.Generic.List[byte]
    $add = { param([int]$Val, [int]$Len) for ($i = $Len - 1; $i -ge 0; $i--) { $bits.Add([byte](($Val -shr $i) -band 1)) } }
    & $add 4 4
    & $add $data.Length $ccBits
    foreach ($d in $data) { & $add ([int]$d) 8 }
    $max = 8 * $cap
    $t = [Math]::Min(4, $max - $bits.Count); & $add 0 $t
    while ($bits.Count % 8) { $bits.Add(0) }
    $pad = @(0xEC, 0x11); $pi = 0
    while ($bits.Count -lt $max) { & $add $pad[$pi % 2] 8; $pi++ }
    $cw = New-Object byte[] $cap
    for ($i = 0; $i -lt $cap; $i++) { $x = 0; for ($k = 0; $k -lt 8; $k++) { $x = ($x -shl 1) -bor $bits[$i * 8 + $k] }; $cw[$i] = [byte]$x }

    # Bloecke + Korrektur, verschraenkt
    $blocks = New-Object System.Collections.Generic.List[object]
    $eccs = New-Object System.Collections.Generic.List[object]
    $pos = 0
    foreach ($g in @(@($blk[0], $blk[1]), @($blk[2], $blk[3]))) {
        for ($i = 0; $i -lt $g[0]; $i++) {
            $part = New-Object byte[] $g[1]
            [Array]::Copy($cw, $pos, $part, 0, $g[1]); $pos += $g[1]
            $blocks.Add($part)
            $eccs.Add((Get-HURQrEcc $part $blk[4]))
        }
    }
    $final = New-Object System.Collections.Generic.List[byte]
    $maxLen = 0; foreach ($p in $blocks) { if ($p.Length -gt $maxLen) { $maxLen = $p.Length } }
    for ($i = 0; $i -lt $maxLen; $i++) { foreach ($p in $blocks) { if ($i -lt $p.Length) { $final.Add($p[$i]) } } }
    for ($i = 0; $i -lt $blk[4]; $i++) { foreach ($e in $eccs) { $final.Add($e[$i]) } }

    # Funktionsmuster
    $n = 17 + 4 * $ver
    $base = New-Object byte[] ($n * $n)
    $fn = New-Object bool[] ($n * $n)
    $set = { param([int]$X, [int]$Y, [int]$Dark) if ($X -ge 0 -and $Y -ge 0 -and $X -lt $n -and $Y -lt $n) { $base[$Y * $n + $X] = [byte]$Dark; $fn[$Y * $n + $X] = $true } }
    foreach ($o in @(@(0, 0), @(($n - 7), 0), @(0, ($n - 7)))) {
        for ($dy = -1; $dy -le 7; $dy++) {
            for ($dx = -1; $dx -le 7; $dx++) {
                $in = ($dx -ge 0 -and $dx -le 6 -and $dy -ge 0 -and $dy -le 6)
                $dark = 0
                if ($in) { $dist = [Math]::Max([Math]::Abs($dx - 3), [Math]::Abs($dy - 3)); if ($dist -ne 2 -and $dist -ne 4) { $dark = 1 } }
                & $set ($o[0] + $dx) ($o[1] + $dy) $dark
            }
        }
    }
    for ($i = 8; $i -lt $n - 8; $i++) { $d = if ($i % 2 -eq 0) { 1 } else { 0 }; & $set $i 6 $d; & $set 6 $i $d }
    $al = @($script:HURQrAlign[$ver])
    foreach ($ay in $al) {
        foreach ($ax in $al) {
            if (($ax -eq 6 -and $ay -eq 6) -or ($ax -eq 6 -and $ay -eq $al[-1]) -or ($ax -eq $al[-1] -and $ay -eq 6)) { continue }
            for ($dy = -2; $dy -le 2; $dy++) { for ($dx = -2; $dx -le 2; $dx++) { $d = if ([Math]::Max([Math]::Abs($dx), [Math]::Abs($dy)) -eq 1) { 0 } else { 1 }; & $set ($ax + $dx) ($ay + $dy) $d } }
        }
    }
    # Formatbereich reservieren (wird je Maske geschrieben), dunkles Modul
    for ($i = 0; $i -le 8; $i++) { if ($i -ne 6) { & $set 8 $i 0; & $set $i 8 0 } }
    for ($i = 0; $i -lt 8; $i++) { & $set ($n - 1 - $i) 8 0 }
    for ($i = 0; $i -lt 7; $i++) { & $set 8 ($n - 1 - $i) 0 }
    & $set 8 ($n - 8) 1
    # Versionsinformation (ab Version 7)
    if ($ver -ge 7) {
        $rem = $ver
        for ($i = 0; $i -lt 12; $i++) { $rem = ($rem -shl 1) -bxor ((($rem -shr 11) -band 1) * 0x1F25) }
        $vb = ($ver -shl 12) -bor $rem
        for ($i = 0; $i -lt 18; $i++) {
            $bit = ($vb -shr $i) -band 1
            $a = $n - 11 + ($i % 3); $b = [Math]::Floor($i / 3)
            & $set $a $b $bit; & $set $b $a $bit
        }
    }

    # Daten im Zickzack von unten rechts (Spalte 6 = Taktmuster wird uebersprungen)
    $total = $final.Count * 8
    $idx = 0
    $right = $n - 1
    while ($right -ge 1) {
        if ($right -eq 6) { $right = 5 }
        for ($vert = 0; $vert -lt $n; $vert++) {
            for ($j = 0; $j -lt 2; $j++) {
                $x = $right - $j
                $up = ((($right + 1) -band 2) -eq 0)
                $y = if ($up) { $n - 1 - $vert } else { $vert }
                if (-not $fn[$y * $n + $x] -and $idx -lt $total) {
                    $base[$y * $n + $x] = [byte](($final[$idx -shr 3] -shr (7 - ($idx -band 7))) -band 1)
                    $idx++
                }
            }
        }
        $right -= 2
    }

    # Maske anwenden + Formatinformation (Fehlerkorrektur M = 00)
    $build = {
        param([int]$Mk)
        $m = [byte[]]$base.Clone()
        for ($y = 0; $y -lt $n; $y++) {
            for ($x = 0; $x -lt $n; $x++) {
                $k = $y * $n + $x
                if ($fn[$k]) { continue }
                $inv = switch ($Mk) {
                    0 { ($x + $y) % 2 -eq 0 }
                    1 { $y % 2 -eq 0 }
                    2 { $x % 3 -eq 0 }
                    3 { ($x + $y) % 3 -eq 0 }
                    4 { (([Math]::Floor($x / 3) + [Math]::Floor($y / 2)) % 2) -eq 0 }
                    5 { ((($x * $y) % 2) + (($x * $y) % 3)) -eq 0 }
                    6 { (((($x * $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
                    default { (((($x + $y) % 2) + (($x * $y) % 3)) % 2) -eq 0 }
                }
                if ($inv) { $m[$k] = [byte](1 - $m[$k]) }
            }
        }
        $d5 = (0 -shl 3) -bor $Mk
        $r = $d5
        for ($i = 0; $i -lt 10; $i++) { $r = ($r -shl 1) -bxor ((($r -shr 9) -band 1) * 0x537) }
        $fb = (($d5 -shl 10) -bor $r) -bxor 0x5412
        $put = { param([int]$X, [int]$Y, [int]$Bit) $m[$Y * $n + $X] = [byte]$Bit }
        for ($i = 0; $i -le 5; $i++) { & $put 8 $i (($fb -shr $i) -band 1) }
        & $put 8 7 (($fb -shr 6) -band 1)
        & $put 8 8 (($fb -shr 7) -band 1)
        & $put 7 8 (($fb -shr 8) -band 1)
        for ($i = 9; $i -lt 15; $i++) { & $put (14 - $i) 8 (($fb -shr $i) -band 1) }
        for ($i = 0; $i -lt 8; $i++) { & $put ($n - 1 - $i) 8 (($fb -shr $i) -band 1) }
        for ($i = 8; $i -lt 15; $i++) { & $put 8 ($n - 15 + $i) (($fb -shr $i) -band 1) }
        & $put 8 ($n - 8) 1
        return , $m
    }
    $best = $null; $bestMask = 0; $bestPen = [int]::MaxValue
    $masks = if ($Mask -ge 0 -and $Mask -le 7) { @($Mask) } else { 0..7 }
    foreach ($mk in $masks) {
        $m = & $build $mk
        $pen = if (@($masks).Count -gt 1) { Get-HURQrPenalty $m $n } else { 0 }
        if ($pen -lt $bestPen) { $bestPen = $pen; $best = $m; $bestMask = $mk }
    }
    return [pscustomobject]@{ Size = $n; Version = $ver; Mask = $bestMask; Modules = $best }
}


# ============================================================================
# ZUFALL, TOKEN, HASH
# ============================================================================
function Get-HURemoteRandomBytes([int]$Count) {
    $b = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}
# Geraete-Token: 256 Bit, Base64url (ohne = + /)
function New-HURemoteToken {
    $b = Get-HURemoteRandomBytes 32
    return ([Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}
# Kopplungscode: 6 Ziffern, gleichverteilt (ohne Modulo-Verzerrung)
function New-HURemotePairCode {
    while ($true) {
        $b = Get-HURemoteRandomBytes 4
        $v = [BitConverter]::ToUInt32($b, 0)
        if ($v -lt 4294000000) { return ('{0:D6}' -f ($v % 1000000)) }
    }
}
function Get-HURemoteHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
# Vergleich in konstanter Zeit (verraet nicht, ab welcher Stelle sich zwei Werte unterscheiden)
function Test-HURemoteEqual([string]$A, [string]$B) {
    $ha = Get-HURemoteHash "$A"; $hb = Get-HURemoteHash "$B"
    $d = 0
    for ($i = 0; $i -lt $ha.Length; $i++) { $d = $d -bor ([int][char]$ha[$i] -bxor [int][char]$hb[$i]) }
    return ($d -eq 0)
}
# Geraetename: nur druckbare Zeichen, hoechstens 40
function ConvertTo-HURemoteDeviceName([string]$Name) {
    $n = ("$Name" -replace '[\x00-\x1F\x7F<>"`]', '').Trim()
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40).Trim() }
    if (-not $n) { $n = 'Handy' }
    return $n
}


# ============================================================================
# NETZWERK
# ============================================================================
function ConvertTo-HURemoteIpInt([string]$Ip) {
    $a = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    return ([uint32]$a[0] -shl 24) -bor ([uint32]$a[1] -shl 16) -bor ([uint32]$a[2] -shl 8) -bor [uint32]$a[3]
}
function Test-HURemotePrivateIp([string]$Ip) {
    try {
        $v = ConvertTo-HURemoteIpInt $Ip
        foreach ($n in $script:HURemotePrivateNets) { $m = ConvertTo-HURemoteIpInt $n[1]; if (($v -band $m) -eq ((ConvertTo-HURemoteIpInt $n[0]) -band $m)) { return $true } }
    } catch { }
    return $false
}
# IPv4-Adressen dieses PCs: @{ IP; Alias; Index; Gateway; Private }. Reihenfolge: mit Standard-Gateway, private, Rest
function Get-HURemoteIPv4List {
    $out = @()
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ("$($nic.OperationalStatus)" -ne 'Up' -or "$($nic.NetworkInterfaceType)" -eq 'Loopback') { continue }
            $p = $nic.GetIPProperties()
            $gw = @($p.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' }).Count -gt 0
            $idx = -1; try { $idx = $p.GetIPv4Properties().Index } catch { }
            foreach ($u in $p.UnicastAddresses) {
                if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ip = "$($u.Address)"
                if ($ip -like '169.254.*' -or $ip -like '127.*') { continue }
                $out += [pscustomobject]@{ IP = $ip; Alias = "$($nic.Name)"; Index = $idx; Gateway = $gw; Private = (Test-HURemotePrivateIp $ip) }
            }
        }
    } catch { }
    return @(Select-HURemoteIPs $out)
}
function Select-HURemoteIPs($List) {
    return @(@($List) | Where-Object { $_ } | Sort-Object @{ Expression = { -not $_.Gateway } }, @{ Expression = { -not $_.Private } }, @{ Expression = { $_.IP } })
}
# Netzwerkprofil (Domain/Private/Public) der Schnittstelle, leer = unbekannt
function Get-HURemoteNetCategory([int]$Index) {
    try { return "$((Get-NetConnectionProfile -InterfaceIndex $Index -ErrorAction Stop | Select-Object -First 1).NetworkCategory)" } catch { return '' }
}
# Port frei? (auch Bindungen anderer Programme ueber http.sys zaehlen, die Liste braucht keine Adminrechte)
function Test-HURemotePortFree([int]$Port) {
    try {
        foreach ($l in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) { if ($l.Port -eq $Port) { return $false } }
    } catch { }
    return $true
}
function Get-HURemoteFreePort([int]$Start) {
    for ($p = [Math]::Max(1025, $Start + 1); $p -lt [Math]::Min(65535, $Start + 200); $p++) { if (Test-HURemotePortFree $p) { return $p } }
    return 0
}
# Erlaubte Gegenstellen fuer die Firewall-Regel: lokales Subnetz + eingetragene Netze (a.b.c.d oder a.b.c.d/nn)
function Get-HURemoteFirewallRemote($Networks) {
    $r = @('LocalSubnet')
    foreach ($n in @($Networks)) {
        $x = "$n".Trim()
        if ($x -match '^(\d{1,3}\.){3}\d{1,3}(/(\d|[12]\d|3[0-2]))?$') {
            $ip = ($x -split '/')[0]
            $okIp = $true; foreach ($o in $ip.Split('.')) { if ([int]$o -gt 255) { $okIp = $false } }
            if ($okIp -and $r -notcontains $x) { $r += $x }
        }
    }
    return $r
}

# ============================================================================
# ZERTIFIKATE (eigene CA je PC, nur als Administrator)
# ============================================================================
# Namen dieses PCs fuer Zertifikate (klein, ohne Doppelte): Kurzname + vollstaendiger Name
function Get-HURemoteHostNames {
    $n = @("$env:COMPUTERNAME".ToLowerInvariant())
    try { $f = [System.Net.Dns]::GetHostEntry('localhost').HostName } catch { $f = '' }
    try { $d = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName; if ($d) { $f = "$env:COMPUTERNAME.$d" } } catch { }
    if ($f -and $f -match '\.' ) { $n += $f.ToLowerInvariant() }
    return @($n | Where-Object { $_ -match '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' } | Select-Object -Unique)
}
# Textform der Namensbeschraenkung: CA darf nur fuer diese Namen und private IPv4-Bereiche ausstellen
function Get-HURemoteNameConstraintText([string[]]$Names) {
    $p = @('subtree=include')
    foreach ($n in @($Names)) { $p += "DNS=$n" }
    foreach ($x in $script:HURemotePrivateNets) { $p += "IPAddress=$($x[0]),$($x[1])" }
    return ('2.5.29.30={critical}{text}' + ($p -join '&'))
}
# IPv4-Adressen und DNS-Namen aus der Erweiterung "Alternativer Antragstellername" (DER, sprachunabhaengig)
function Get-HURemoteSan([byte[]]$Raw) {
    $ips = @(); $dns = @()
    try {
        $i = 0
        if ($Raw[$i] -ne 0x30) { return [pscustomobject]@{ IPs = @(); Dns = @() } }
        $i++
        $len = [int]$Raw[$i]; $i++
        if ($len -band 0x80) { $nb = $len -band 0x7F; $len = 0; for ($k = 0; $k -lt $nb; $k++) { $len = ($len -shl 8) -bor $Raw[$i]; $i++ } }
        $end = $i + $len
        while ($i -lt $end) {
            $tag = $Raw[$i]; $i++
            $l = [int]$Raw[$i]; $i++
            if ($l -band 0x80) { $nb = $l -band 0x7F; $l = 0; for ($k = 0; $k -lt $nb; $k++) { $l = ($l -shl 8) -bor $Raw[$i]; $i++ } }
            if ($tag -eq 0x87 -and $l -eq 4) { $ips += ('{0}.{1}.{2}.{3}' -f $Raw[$i], $Raw[$i + 1], $Raw[$i + 2], $Raw[$i + 3]) }
            elseif ($tag -eq 0x82) { $dns += [Text.Encoding]::ASCII.GetString($Raw, $i, $l).ToLowerInvariant() }
            $i += $l
        }
    } catch { }
    return [pscustomobject]@{ IPs = $ips; Dns = $dns }
}
# SHA-256-Fingerabdruck eines Zertifikats in Vierergruppen (zum Vergleichen am Handy)
function Get-HURemoteFingerprint($Cert) {
    if (-not $Cert) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = ([BitConverter]::ToString($sha.ComputeHash($Cert.RawData))) -replace '-', '' } finally { $sha.Dispose() }
    return ((($h -split '(.{4})') | Where-Object { $_ }) -join ' ')
}
function Get-HURemoteCertSan($Cert) {
    $e = @($Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })[0]
    if (-not $e) { return [pscustomobject]@{ IPs = @(); Dns = @() } }
    return (Get-HURemoteSan $e.RawData)
}
function Get-HURemoteCa([string]$Store = 'LocalMachine') {
    $names = Get-HURemoteHostNames
    $c = @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object {
            $_.FriendlyName -eq $script:HURemoteCaName -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(60) -and $_.Subject -eq "CN=$($script:HURemoteCaName) ($($names[0]))"
        } | Sort-Object NotAfter -Descending)
    return $c[0]
}
function New-HURemoteCa([string]$Store = 'LocalMachine') {
    $names = Get-HURemoteHostNames
    $p = @{
        Type = 'Custom'; Subject = "CN=$($script:HURemoteCaName) ($($names[0]))"; FriendlyName = $script:HURemoteCaName
        KeyUsage = @('CertSign', 'CRLSign', 'DigitalSignature'); KeyAlgorithm = 'RSA'; KeyLength = 2048; HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'NonExportable'; NotAfter = (Get-Date).AddYears(10); CertStoreLocation = "Cert:\$Store\My"
        TextExtension = @('2.5.29.19={critical}{text}ca=1&pathlength=0', (Get-HURemoteNameConstraintText $names), '2.5.29.37={text}1.3.6.1.5.5.7.3.1')
    }
    return (New-SelfSignedCertificate @p)
}
# Server-Zertifikat passt, wenn es von der CA stammt, noch 30 Tage gilt und alle Adressen + Namen enthaelt
function Test-HURemoteServerCert($Cert, $Ca, [string[]]$Ips) {
    if (-not $Cert -or -not $Ca) { return $false }
    if ($Cert.Issuer -ne $Ca.Subject -or $Cert.NotAfter -lt (Get-Date).AddDays(30) -or -not $Cert.HasPrivateKey) { return $false }
    $san = Get-HURemoteCertSan $Cert
    foreach ($ip in @($Ips)) { if ($san.IPs -notcontains $ip) { return $false } }
    foreach ($n in @(Get-HURemoteHostNames)) { if ($san.Dns -notcontains $n) { return $false } }
    return $true
}
function Get-HURemoteServerCert($Ca, [string[]]$Ips, [string]$Store = 'LocalMachine') {
    $c = @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $script:HURemoteCertName } | Sort-Object NotAfter -Descending)
    foreach ($x in $c) { if (Test-HURemoteServerCert $x $Ca $Ips) { return $x } }
    return $null
}
# Laufzeit hoechstens 800 Tage (Apple verlangt <= 825 Tage)
function New-HURemoteServerCert($Ca, [string[]]$Ips, [string]$Store = 'LocalMachine') {
    $san = @(@(Get-HURemoteHostNames) | ForEach-Object { "DNS=$_" }) + @(@($Ips) | Where-Object { Test-HURemotePrivateIp $_ } | ForEach-Object { "IPAddress=$_" })
    $p = @{
        Type = 'Custom'; Subject = "CN=$($script:HURemoteCertName)"; FriendlyName = $script:HURemoteCertName; Signer = $Ca
        KeyUsage = @('DigitalSignature', 'KeyEncipherment'); KeyAlgorithm = 'RSA'; KeyLength = 2048; HashAlgorithm = 'SHA256'
        KeyExportPolicy = 'NonExportable'; NotAfter = (Get-Date).AddDays(800); CertStoreLocation = "Cert:\$Store\My"
        TextExtension = @(('2.5.29.17={text}' + ($san -join '&')), '2.5.29.37={text}1.3.6.1.5.5.7.3.1', '2.5.29.19={text}ca=0')
    }
    return (New-SelfSignedCertificate @p)
}
# Alte Server-Zertifikate der Fernbedienung entfernen (ausser $Keep)
# Zertifikate, die gerade an eine HTTPS-Bindung (z.B. Einrichtung fuer den Benutzer-Modus) gebunden sind, bleiben ($Keep: weitere)
function Remove-HURemoteOldCerts([string[]]$Keep, [string]$Store = 'LocalMachine', [int[]]$BoundPorts = @()) {
    $k = @($Keep | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() })
    foreach ($bp in @($BoundPorts | Where-Object { $_ -gt 0 })) { try { $b = Get-HURemoteBinding $bp; if ($b.State -eq 'Ours' -and $b.Thumb) { $k += $b.Thumb } } catch { } }
    foreach ($c in @(Get-ChildItem -Path "Cert:\$Store\My" -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $script:HURemoteCertName -and $k -notcontains $_.Thumbprint.ToUpperInvariant() })) {
        try { Remove-Item -LiteralPath "Cert:\$Store\My\$($c.Thumbprint)" -DeleteKey -ErrorAction Stop } catch { try { Remove-Item -LiteralPath "Cert:\$Store\My\$($c.Thumbprint)" -ErrorAction SilentlyContinue } catch { } }
    }
}

# ============================================================================
# HTTPS-BINDUNG, PORT-FREIGABE, FIREWALL (netsh / NetSecurity)
# ============================================================================
# Ausgabe von "netsh http show sslcert" auswerten (sprachunabhaengig): None | Ours | Foreign, Fingerabdruck
function ConvertFrom-HURemoteSslShow([string]$Text) {
    $th = ''
    $m = [regex]::Match("$Text", '(?i)\b([0-9a-f]{40})\b')
    if ($m.Success) { $th = $m.Groups[1].Value.ToUpperInvariant() }
    if (-not $th) { return [pscustomobject]@{ State = 'None'; Thumb = '' } }
    $ours = "$Text" -match [regex]::Escape($script:HURemoteAppId.Trim('{}'))
    return [pscustomobject]@{ State = $(if ($ours) { 'Ours' } else { 'Foreign' }); Thumb = $th }
}
# Gehoert eine fremde Bindung auf dem Port HUMig?
function Test-HURemoteHUMigPort([int]$Port) {
    $o = (& netsh.exe http show sslcert "ipport=0.0.0.0:$Port" 2>&1 | Out-String)
    return ("$o" -match [regex]::Escape($script:HURemoteHUMigAppId))
}
function Get-HURemoteBinding([int]$Port) {
    $o = (& netsh.exe http show sslcert "ipport=0.0.0.0:$Port" 2>&1 | Out-String)
    return (ConvertFrom-HURemoteSslShow $o)
}
function Set-HURemoteBinding([int]$Port, [string]$Thumb) {
    $b = Get-HURemoteBinding $Port
    if ($b.State -eq 'Foreign') { throw "Port $Port hat bereits eine HTTPS-Bindung eines anderen Programms (Fingerabdruck $($b.Thumb)) - anderen Port waehlen" }
    if ($b.State -eq 'Ours') {
        if ($b.Thumb -eq $Thumb.ToUpperInvariant()) { return }
        $o = & netsh.exe http delete sslcert "ipport=0.0.0.0:$Port" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "HTTPS-Bindung nicht entfernbar: $(@($o) -join ' ')" }
    }
    $o = & netsh.exe http add sslcert "ipport=0.0.0.0:$Port" "certhash=$Thumb" "appid=$($script:HURemoteAppId)" 'certstorename=MY' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "HTTPS-Bindung nicht moeglich: $(@($o) -join ' ')" }
}
function Remove-HURemoteBinding([int]$Port) {
    if ((Get-HURemoteBinding $Port).State -ne 'Ours') { return }
    [void](& netsh.exe http delete sslcert "ipport=0.0.0.0:$Port" 2>&1)
}
# URL-Reservierung (Port-Freigabe) des Benutzer-Modus: das eingerichtete Konto + Administratoren (BA), damit die
# Fernbedienung auf diesem Port auch als Administrator startet. Eine fremde Reservierung wird nie geloescht.
function Get-HURemoteUrlAclText([int]$Port) { return (& netsh.exe http show urlacl "url=https://+:$Port/" 2>&1 | Out-String) }
# Gehoert die Reservierung (falls vorhanden) uns? Text aus "netsh http show urlacl" (sprachunabhaengig ueber SID/SDDL)
function Test-HURemoteUrlAclOurs([string]$Text, [int]$Port, [string]$Sid) {
    if ("$Text" -notmatch [regex]::Escape("https://+:$Port/")) { return $true }   # keine Reservierung
    return ($Sid -and "$Text" -match [regex]::Escape("D:(A;;GX;;;$Sid)"))
}
function Set-HURemoteUrlAcl([int]$Port, [string]$Sid, [string]$OldSid = '') {
    if ($Sid -notmatch '^S-1-5-21-[\d-]+$') { throw "Benutzerkonto ungueltig ($Sid)" }
    $txt = Get-HURemoteUrlAclText $Port
    if (-not (Test-HURemoteUrlAclOurs $txt $Port $Sid) -and -not (Test-HURemoteUrlAclOurs $txt $Port $OldSid)) { throw "Port $Port ist bereits fuer ein anderes Programm/Konto reserviert (netsh http show urlacl) - anderen Port waehlen" }
    if ("$txt" -match [regex]::Escape("https://+:$Port/")) { [void](& netsh.exe http delete urlacl "url=https://+:$Port/" 2>&1) }
    $o = & netsh.exe http add urlacl "url=https://+:$Port/" "sddl=D:(A;;GX;;;$Sid)(A;;GX;;;BA)" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Port-Freigabe fuer das Benutzerkonto nicht moeglich: $(@($o) -join ' ')" }
}
function Remove-HURemoteUrlAcl([int]$Port, [string]$Sid) {
    $txt = Get-HURemoteUrlAclText $Port
    if ($Sid -and "$txt" -match [regex]::Escape("https://+:$Port/") -and (Test-HURemoteUrlAclOurs $txt $Port $Sid)) { [void](& netsh.exe http delete urlacl "url=https://+:$Port/" 2>&1) }
}
function Set-HURemoteFirewall([string]$Name, [int]$Port, $Remote) {
    Remove-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    $p = @{
        Name = $Name; DisplayName = "HU-MultiTenant Fernbedienung (TCP $Port)"; Group = 'HU-MultiTenant'; Direction = 'Inbound'; Action = 'Allow'
        Protocol = 'TCP'; LocalPort = "$Port"; Profile = @('Domain', 'Private'); RemoteAddress = @($Remote)
        Program = 'System'   # http.sys (Kernel) nimmt die Verbindungen an - ein anderes Programm auf dem Port bleibt gesperrt
        Description = 'HU-MultiTenant: Handy-Fernbedienung (nur Domaenen- und private Netze). Wird von HU-MultiTenant angelegt und entfernt.'
    }
    [void](New-NetFirewallRule @p -ErrorAction Stop)
}
function Remove-HURemoteFirewall([string]$Name) { Remove-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue }


# ============================================================================
# PUSH-MELDUNGEN (Web Push ohne Inhalt, VAPID)
# ============================================================================
# Das Handy wird ueber den Push-Dienst seines Browsers (Google, Apple, Mozilla, Microsoft) "angeklopft" - ohne Inhalt,
# die Dienste sehen also nur den Zeitpunkt. Die App holt die Details danach selbst vom PC (im selben Netz).
# Nur Adressen dieser Dienste werden angenommen (kein Senden an beliebige Adressen im Netz).
$script:HURPushHosts = @('fcm.googleapis.com', 'android.googleapis.com', 'web.push.apple.com', 'updates.push.services.mozilla.com')
$script:HURPushSuffix = @('.push.apple.com', '.notify.windows.com', '.push.services.mozilla.com')
$script:HURPushSub = 'https://github.com/ChiliApple/HU-MultiTenant'
function Test-HURemotePushEndpoint([string]$Url) {
    if (-not $Url -or $Url.Length -gt 1024) { return $false }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo -or $u.HostNameType -ne 'Dns') { return $false }
    $h = $u.DnsSafeHost.ToLowerInvariant()
    if ($script:HURPushHosts -contains $h) { return $true }
    foreach ($s in $script:HURPushSuffix) { if ($h.EndsWith($s) -and $h.Length -gt $s.Length) { return $true } }
    return $false
}
function ConvertTo-HURB64Url([byte[]]$Bytes) { return ([Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')) }
function Get-HURemotePushFile { return (Join-Path $env:APPDATA 'HU-MultiTenant\remote-push.json') }
# VAPID-Schluessel dieses PCs/Kontos (ECDSA P-256): privat nur DPAPI-geschuetzt (aktuelles Konto), Rueckgabe @{ Key (CngKey); Public (b64url, 65 Byte) }
function Get-HURemoteVapid([string]$Path = (Get-HURemotePushFile), [switch]$NoCreate) {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $ent = [Text.Encoding]::UTF8.GetBytes('HUMig-Push-VAPID')
    $key = $null
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $blob = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String("$($j.Private)"), $ent, 'CurrentUser')
            $key = [System.Security.Cryptography.CngKey]::Import($blob, [System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
        }
    } catch { $key = $null }
    if (-not $key) {
        if ($NoCreate) { return $null }
        $p = New-Object System.Security.Cryptography.CngKeyCreationParameters
        $p.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        $key = [System.Security.Cryptography.CngKey]::Create([System.Security.Cryptography.CngAlgorithm]::ECDsaP256, [NullString]::Value, $p)   # $null wuerde zu "" = benannter, dauerhafter Schluessel (kollidiert mit HUMig)
        $blob = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
        $prot = [System.Security.Cryptography.ProtectedData]::Protect($blob, $ent, 'CurrentUser')
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [IO.File]::WriteAllText($Path, ([pscustomobject]@{ Private = [Convert]::ToBase64String($prot); Created = (Get-Date).ToString('yyyy-MM-dd HH:mm') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }
    # oeffentlicher Schluessel: EccPublicBlob = 8 Byte Kopf + X (32) + Y (32) -> unkomprimierter Punkt 04|X|Y
    $pub = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
    $pt = New-Object byte[] 65; $pt[0] = 4; [Array]::Copy($pub, 8, $pt, 1, 64)
    return @{ Key = $key; Public = (ConvertTo-HURB64Url $pt) }
}
# VAPID-Anmeldung (JWT, ES256) fuer einen Push-Dienst: Aud = https://<host>, gilt 12 Stunden
function New-HURemoteVapidJwt($Vapid, [string]$Aud, [datetime]$Now = (Get-Date)) {
    $exp = [int64](($Now.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds) + 12 * 3600
    $u8 = New-Object Text.UTF8Encoding $false
    $h = ConvertTo-HURB64Url ($u8.GetBytes('{"typ":"JWT","alg":"ES256"}'))
    $c = ConvertTo-HURB64Url ($u8.GetBytes((ConvertTo-Json -Compress -InputObject ([ordered]@{ aud = $Aud; exp = $exp; sub = $script:HURPushSub }))))
    $ec = New-Object System.Security.Cryptography.ECDsaCng($Vapid.Key)
    try {
        $ec.HashAlgorithm = [System.Security.Cryptography.CngAlgorithm]::Sha256
        $sig = $ec.SignData($u8.GetBytes("$h.$c"))   # IEEE P1363 (r|s, 64 Byte) - wie JWS verlangt
    } finally { $ec.Dispose() }
    return "$h.$c.$(ConvertTo-HURB64Url $sig)"
}
$script:HURPushJwtCache = @{}
# Anfragen fuer alle Handys mit Push-Abo: @{ Hash; Name; Url; Auth }
function Get-HURemotePushRequests($Devices, $Vapid, [datetime]$Now = (Get-Date)) {
    $out = @()
    foreach ($k in @($Devices.Keys)) {
        $d = $Devices[$k]
        $ep = "$($d.PushEndpoint)"
        if (-not (Test-HURemotePushEndpoint $ep)) { continue }
        $u = [Uri]$ep
        $aud = "https://$($u.DnsSafeHost)"
        # Anmeldung je Push-Dienst hoechstens stuendlich neu (Apple drosselt haeufigere Erneuerung)
        $ck = "$($Vapid.Public)|$aud"; $c = $script:HURPushJwtCache[$ck]
        if ($c -and $c.Made -le $Now -and ($Now - $c.Made).TotalMinutes -lt 60) { $jwt = $c.Jwt }
        else { $jwt = New-HURemoteVapidJwt $Vapid $aud $Now; $script:HURPushJwtCache[$ck] = @{ Jwt = $jwt; Made = $Now } }
        $out += @{ Hash = $k; Name = "$($d.Name)"; Url = $ep; Auth = "vapid t=$jwt, k=$($Vapid.Public)" }
    }
    return ,@($out)
}
# Push senden (im Hintergrund-Runspace aufgerufen): leerer POST. Rueckgabe je Anfrage @{ Hash; Name; Code; Error }
$script:HURPushSendScript = {
    param($Reqs)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    foreach ($q in @($Reqs)) {
        $code = 0; $err = ''
        try {
            $w = [System.Net.HttpWebRequest]::Create($q.Url)
            $w.Method = 'POST'; $w.Timeout = 15000; $w.ReadWriteTimeout = 15000; $w.AllowAutoRedirect = $false
            $w.Headers.Add('Authorization', $q.Auth)
            $w.Headers.Add('TTL', '21600')
            $w.Headers.Add('Urgency', 'high')
            $w.ContentLength = 0
            $resp = $w.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; try { $_.Exception.Response.Close() } catch { } } else { $err = "$($_.Exception.Message)" }
        } catch { $err = "$($_.Exception.Message)" }
        @{ Hash = $q.Hash; Name = $q.Name; Url = $q.Url; Code = $code; Error = $err }
    }
}



# ============================================================================
# GEKOPPELTE GERAETE (je Windows-Benutzer: %APPDATA%\HU-MultiTenant\remote-devices.json, nur Hashes)
# ============================================================================
function Get-HURemoteDataDir { return (Join-Path $env:APPDATA 'HU-MultiTenant') }
function Get-HURemoteDeviceFile { return (Join-Path (Get-HURemoteDataDir) 'remote-devices.json') }
# Rueckgabe: synchronisierte Hashtable Hash -> @{ Id; Name; Created; LastSeen; LastIp; Locked; PinFails }
function Read-HURemoteDevices([string]$Path = (Get-HURemoteDeviceFile), [datetime]$Now = (Get-Date)) {
    $h = [hashtable]::Synchronized(@{})
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($d in @($j.Devices)) {
                if (-not $d -or "$($d.Hash)" -notmatch '^[0-9a-f]{64}$') { continue }
                # lange nicht benutzt -> Kopplung verfaellt (Review 031 B15)
                $seen = [datetime]::MinValue; try { $seen = [datetime]::ParseExact("$($d.LastSeen)", 'yyyy-MM-dd HH:mm', $null) } catch { }
                if ($seen -lt $Now.AddDays(-$script:HURemoteTokenDays)) { continue }
                $h["$($d.Hash)"] = @{ Id = "$($d.Id)"; Name = (ConvertTo-HURemoteDeviceName "$($d.Name)"); Created = "$($d.Created)"; LastSeen = "$($d.LastSeen)"; LastIp = "$($d.LastIp)"
                    Locked = [bool]($d.Locked -eq $true); PinFails = [int]$(try { [int]$d.PinFails } catch { 0 })
                    PushEndpoint = $(if (Test-HURemotePushEndpoint "$($d.PushEndpoint)") { "$($d.PushEndpoint)" } else { '' }) }
            }
        }
    } catch { }
    return , $h
}
function Save-HURemoteDevices($Devices, [string]$Path = (Get-HURemoteDeviceFile)) {
    $list = @()
    foreach ($k in @($Devices.Keys)) { $d = $Devices[$k]; if ($d) { $list += [pscustomobject]@{ Id = $d.Id; Name = $d.Name; Hash = $k; Created = $d.Created; LastSeen = $d.LastSeen; LastIp = $d.LastIp; Locked = [bool]$d.Locked; PinFails = [int]$d.PinFails; PushEndpoint = "$($d.PushEndpoint)" } } }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ([pscustomobject]@{ Devices = $list } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ============================================================================
# FERNBEDIENUNGS-PIN (nur Ziffern, 4-12 Stellen; gespeichert nur PBKDF2-SHA256 mit Salt)
# ============================================================================
function Get-HURemotePinFile { return (Join-Path (Get-HURemoteDataDir) 'remote-pin.json') }
function Test-HURemotePinFormat([string]$Pin) { return ("$Pin" -match "^\d{$($script:HURemotePinMin),$($script:HURemotePinMax)}$") }
function Get-HURemotePinHash([string]$Pin, [byte[]]$Salt, [int]$Rounds) {
    # Rfc2898DeriveBytes mit SHA256 gibt es ab .NET 4.7.2 (Windows 10/11 haben es)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Pin, $Salt, $Rounds, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return ([BitConverter]::ToString($kdf.GetBytes(32)) -replace '-', '').ToLowerInvariant() } finally { $kdf.Dispose() }
}
function Set-HURemotePin([string]$Pin, [string]$Path = (Get-HURemotePinFile)) {
    if (-not (Test-HURemotePinFormat $Pin)) { throw "PIN: nur Ziffern, $($script:HURemotePinMin) bis $($script:HURemotePinMax) Stellen" }
    $salt = Get-HURemoteRandomBytes 16
    $o = [pscustomobject]@{ v = 1; Salt = [Convert]::ToBase64String($salt); Rounds = $script:HURemotePinRounds; Hash = (Get-HURemotePinHash $Pin $salt $script:HURemotePinRounds); Set = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
# PIN-Daten (fuer den Webserver-Runspace einmal gelesen): $null = keine PIN eingerichtet
function Read-HURemotePin([string]$Path = (Get-HURemotePinFile)) {
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($j.Hash)" -notmatch '^[0-9a-f]{64}$' -or [int]$j.Rounds -lt 10000) { return $null }
        return @{ Salt = [Convert]::FromBase64String("$($j.Salt)"); Rounds = [int]$j.Rounds; Hash = "$($j.Hash)"; Set = "$($j.Set)" }
    } catch { return $null }
}
function Test-HURemotePin([string]$Pin, $PinData) {
    if (-not $PinData -or -not (Test-HURemotePinFormat $Pin)) { return $false }
    return (Test-HURemoteEqual (Get-HURemotePinHash $Pin $PinData.Salt $PinData.Rounds) $PinData.Hash)
}
# Kuerzel zum Abtippen (Echtlauf): 4 Zeichen ohne verwechselbare (0/O, 1/I/L)
function New-HURemoteShortCode {
    $a = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    $b = Get-HURemoteRandomBytes 4
    return (-join ($b | ForEach-Object { $a[$_ % $a.Length] }))
}

# ============================================================================
# PARAMETER VOM HANDY PRUEFEN (Review 031 B5)
# ============================================================================
# $Defs: @{ Name; Type; Label; Default; Choices } (aus dem hash-geprueften Code). $Values: Hashtable vom Handy.
# Rueckgabe: @{ Ok; Error; Values (Hashtable mit fertigen Werten fuer ALLE Parameter) }
function Test-HURemoteParams($Defs, $Values) {
    $out = @{}
    $known = @{}
    foreach ($d in @($Defs)) { if ($d) { $known["$($d.Name)".ToLowerInvariant()] = $d } }
    $given = @{}
    if ($Values) {
        $names = if ($Values -is [System.Collections.IDictionary]) { @($Values.Keys) } else { @($Values.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($n in $names) {
            $k = "$n".ToLowerInvariant()
            if (-not $known.ContainsKey($k)) { return @{ Ok = $false; Error = "Unbekannter Parameter '$n'" } }
            if ($given.ContainsKey($k)) { return @{ Ok = $false; Error = "Parameter '$n' doppelt" } }
            $given[$k] = $(if ($Values -is [System.Collections.IDictionary]) { $Values[$n] } else { $Values.$n })
        }
    }
    foreach ($d in @($Defs)) {
        if (-not $d) { continue }
        $n = "$($d.Name)"
        if ($n -match $script:HURemoteBlockedParams) { return @{ Ok = $false; Error = "Parameter '$n' ist nicht erlaubt (geschuetzter Name)" } }
        $raw = if ($given.ContainsKey($n.ToLowerInvariant())) { $given[$n.ToLowerInvariant()] } else { $d.Default }
        switch ("$($d.Type)") {
            'bool' {
                if ($raw -is [bool]) { $out[$n] = $raw }
                elseif ("$raw".Trim() -match '^(?i)(true|1|ja|yes|\$true|wahr)$') { $out[$n] = $true }
                elseif ("$raw".Trim() -match '^(?i)(false|0|nein|no|\$false|falsch|)$') { $out[$n] = $false }
                else { return @{ Ok = $false; Error = "'$($d.Label)': ja/nein erwartet" } }
            }
            'int' {
                $i = 0
                if (-not [int]::TryParse("$raw".Trim(), [ref]$i)) { return @{ Ok = $false; Error = "'$($d.Label)': '$raw' ist keine Zahl" } }
                $out[$n] = $i
            }
            'choice' {
                $c = @($d.Choices | ForEach-Object { "$_" })
                if ($c -cnotcontains "$raw") { return @{ Ok = $false; Error = "'$($d.Label)': '$raw' ist keine erlaubte Auswahl" } }
                $out[$n] = "$raw"
            }
            default {
                $s = "$raw"
                if ($s.Length -gt 256) { return @{ Ok = $false; Error = "'$($d.Label)': hoechstens 256 Zeichen" } }
                if ($s -match '[\x00-\x1F\x7F]') { return @{ Ok = $false; Error = "'$($d.Label)': nur eine Zeile, keine Steuerzeichen" } }
                $out[$n] = $s
            }
        }
    }
    return @{ Ok = $true; Error = ''; Values = $out }
}
# Echter Lauf? Item.Mode: 'read' = nie, 'write' = immer, ausser ein Probelauf-Schalter steht auf ja
$script:HURemoteDryRx = '^(?i)(DryRun|WhatIf|Probelauf)$'   # nur eindeutige Probelauf-Schalter (Review 032 B1: 'Test'/'Preview' bedeuten nicht sicher 'aendert nichts')
function Test-HURemoteLive($Item, [hashtable]$Values) {
    if ("$($Item.Mode)" -eq 'read') { return $false }
    foreach ($d in @($Item.Params)) {
        if ($d -and "$($d.Type)" -eq 'bool' -and "$($d.Name)" -match $script:HURemoteDryRx -and $Values.ContainsKey("$($d.Name)") -and $Values["$($d.Name)"] -eq $true) { return $false }
    }
    return $true
}
# Apps/Wartung vom Handy: Zuweisen/Aufheben pruefen. Rueckgabe @{ Ok; Error; Req; Lines; Title }
# Das Handy schickt nur Kennungen und Auswahlwerte; was ausgefuehrt wird, legt der PC fest.
$script:HURemoteGuidRx = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
function ConvertTo-HURemoteShortText([string]$Text, [int]$Max = 120) {
    $x = ("$Text" -replace '[\x00-\x1F]', ' ').Trim()
    if ($x.Length -gt $Max) { $x = $x.Substring(0, $Max) }
    return $x
}
function Test-HURemoteIntuneReq($X, [string]$Area) {
    $bad = { param($m) [pscustomobject]@{ Ok = $false; Error = $m; Req = $null; Lines = @(); Title = '' } }
    if (-not $X) { return (& $bad 'Angaben fehlen') }
    $op = "$($X.op)"; $id = "$($X.id)"
    if ($op -notin 'assign', 'unassign') { return (& $bad 'Unbekannte Aktion') }
    if ($id -notmatch $script:HURemoteGuidRx) { return (& $bad 'Ungueltige Kennung') }
    $name = ConvertTo-HURemoteShortText "$($X.name)" 200
    $what = if ($Area -eq 'app') { 'App' } else { 'Wartung' }
    $req = @{ Area = $Area; Op = $op; Id = $id; Name = $name }
    $lines = @(@{ Label = $what; Value = $(if ($name) { $name } else { $id }) })
    if ($op -eq 'unassign') {
        $keys = @(@($X.keys) | ForEach-Object { "$_" } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $keys.Count -or $keys.Count -gt 20) { return (& $bad 'Bitte 1 bis 20 Zuweisungen waehlen') }
        foreach ($k in $keys) { if ($k.Length -gt 300 -or $k -notmatch '^(group|exclude|allDevices|allUsers)\|') { return (& $bad 'Ungueltige Zuweisung') } }
        $req.Remove = [string[]]$keys
        $lbl = @($keys | ForEach-Object { $p = $_ -split '\|', 2; switch ($p[0]) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } 'exclude' { "Ausschluss: $($p[1])" } default { $p[1] } } })
        $lines += @{ Label = 'Aufheben'; Value = ($lbl -join ', ') }
        return [pscustomobject]@{ Ok = $true; Error = ''; Req = $req; Lines = $lines; Title = "${what}: Zuweisung aufheben" }
    }
    $kind = "$($X.kind)"
    if ($kind -notin 'group', 'exclude', 'allDevices', 'allUsers') { return (& $bad 'Ungueltiges Ziel') }
    $req.Kind = $kind; $req.GroupId = ''; $req.GroupName = ''
    if ($kind -in 'group', 'exclude') {
        if ("$($X.groupId)" -notmatch $script:HURemoteGuidRx) { return (& $bad 'Bitte eine Gruppe waehlen') }
        $req.GroupId = "$($X.groupId)"; $req.GroupName = ConvertTo-HURemoteShortText "$($X.groupName)" 256
    }
    $tl = switch ($kind) { 'allDevices' { 'Alle Geraete' } 'allUsers' { 'Alle Benutzer' } 'exclude' { "Ausschluss: $($req.GroupName)" } default { "Gruppe: $($req.GroupName)" } }
    $lines += @{ Label = 'Ziel'; Value = $tl }
    if ($Area -eq 'app') {
        $in = "$($X.intent)"
        if ($in -notin 'required', 'available', 'uninstall') { return (& $bad 'Ungueltige Zuweisungsart') }
        if ($in -eq 'available' -and $kind -eq 'allDevices') { return (& $bad "'Verfuegbar' geht nur fuer Benutzer bzw. Benutzergruppen") }
        $req.Intent = $in
        $lines += @{ Label = 'Art'; Value = $(switch ($in) { 'required' { 'Erforderlich' } 'available' { 'Verfuegbar' } default { 'Deinstallieren' } }) }
    }
    elseif ($kind -ne 'exclude') {
        $st = "$($X.schedule.type)"; $iv = 1; [void][int]::TryParse("$($X.schedule.interval)", [ref]$iv)
        $tm = "$($X.schedule.time)"; $dt = "$($X.schedule.date)"
        if ($st -notin 'once', 'hourly', 'daily') { return (& $bad 'Ungueltiger Zeitplan') }
        if ($st -eq 'hourly' -and ($iv -lt 1 -or $iv -gt 23)) { return (& $bad 'Stuendlich: alle 1 bis 23 Stunden') }
        if ($st -eq 'daily' -and ($iv -lt 1 -or $iv -gt 30)) { return (& $bad 'Taeglich: alle 1 bis 30 Tage') }
        if ($st -ne 'hourly' -and $tm -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { return (& $bad 'Uhrzeit als HH:mm') }
        if ($st -eq 'once') { $d = [datetime]::MinValue; if (-not [datetime]::TryParseExact($dt, 'yyyy-MM-dd', $null, 'None', [ref]$d) -or $d.Date -lt (Get-Date).Date) { return (& $bad 'Datum fehlt oder liegt in der Vergangenheit') } }
        $req.Schedule = @{ Type = $st; Interval = $iv; Time = $(if ($tm) { $tm } else { '08:00' }); Date = $dt }
        $lines += @{ Label = 'Zeitplan'; Value = $(switch ($st) { 'hourly' { "alle $iv Std." } 'once' { "einmal am $dt um $tm" } default { "$(if ($iv -gt 1) { "alle $iv Tage" } else { 'taeglich' }) um $tm" } }) }
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Req = $req; Lines = $lines; Title = "${what}: zuweisen" }
}

# Text fuer die Anzeige: Werte, die nach Kennwort aussehen, nie zeigen (Review 031 B17)
function Format-HURemoteParamText($Defs, [hashtable]$Values) {
    $l = @()
    foreach ($d in @($Defs)) {
        if (-not $d) { continue }
        $v = $Values["$($d.Name)"]
        $t = if ("$($d.Name) $($d.Label)" -match '(?i)pass|kennw|secret|token|key|pin') { '******' } elseif ($v -is [bool]) { $(if ($v) { 'ja' } else { 'nein' }) } else { "$v" }
        $l += [ordered]@{ label = "$($d.Label)"; value = $t; changed = ("$v" -ne "$($d.Default)" -and -not ($v -is [bool] -and $v -eq ("$($d.Default)" -match '^(?i)(true|1|ja|yes|\$true|wahr)$'))) }
    }
    return @(@($l | Where-Object { $_.changed }) + @($l | Where-Object { -not $_.changed }))
}

# ============================================================================
# ZUSTAND (zwischen Oberflaeche und Webserver geteilt)
# ============================================================================
function New-HURemoteState {
    return [hashtable]::Synchronized(@{
        Run = $true; Listening = $false; Error = ''; Port = $script:HURemoteDefaultPort; Version = ''; Pc = "$env:COMPUTERNAME"
        Started = (Get-Date); Devices = [hashtable]::Synchronized(@{}); DevDirty = $false; Pair = $null; Pin = $null
        Lines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); LineSeq = 0
        Items = [hashtable]::Synchronized(@{}); CatalogJson = '{"items":[],"tenants":[],"targets":[]}'; CatVer = 0
        Tenants = @(); Targets = @()
        Job = [hashtable]::Synchronized(@{ Running = $false; Title = ''; Kind = ''; By = ''; Live = $false; Started = $null; Ended = $null; Result = ''; Level = ''; Tenants = @(); Done = @() })
        Busy = ''                 # Grund, wenn am PC gerade etwas laeuft (Quick Script, Erweiterung, Teams) - dann kein Start vom Handy
        Nonces = [hashtable]::Synchronized(@{}); RunReq = $null; CancelReq = $null
        FailIp = [hashtable]::Synchronized(@{}); LogFile = ''; PushKey = ''
        Events = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        # Apps und Wartung (Intune): Leseanfragen vom Handy -> Warteschlange -> eigener Runspace -> Zwischenspeicher
        Intune = $true; IQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue)); ICache = [hashtable]::Synchronized(@{})
    })
}
# Kopplung oeffnen (Code 6 Ziffern, 10 Minuten, 5 Fehlversuche) - nur ueber den Knopf am PC
function Open-HURemotePairing($S, [int]$Minutes = $script:HURemotePairMinutes) {
    $S.Pair = [hashtable]::Synchronized(@{ Code = (New-HURemotePairCode); Until = (Get-Date).AddMinutes($Minutes); Fails = 0; Locked = $false })
    return $S.Pair.Code
}
function Close-HURemotePairing($S) { $S.Pair = $null }
# Zeile fuer die Live-Ausgabe (Ringpuffer); Level: Info, OK, Warn, Error, Head
function Add-HURemoteLineTo($S, [string]$Text, [string]$Level = 'Info') {
    $t = "$Text"
    if ($t.Length -gt 600) { $t = $t.Substring(0, 600) + ' ...' }
    [System.Threading.Monitor]::Enter($S.Lines.SyncRoot)
    try {
        $S.LineSeq++
        [void]$S.Lines.Add(@{ n = [int]$S.LineSeq; t = (Get-Date).ToString('HH:mm:ss'); l = $Level; z = $t })
        while ($S.Lines.Count -gt $script:HURemoteMaxLines) { $S.Lines.RemoveAt(0) }
    } finally { [System.Threading.Monitor]::Exit($S.Lines.SyncRoot) }
}

# ============================================================================
# ANFRAGEN BEANTWORTEN (ohne HttpListener testbar)
# ============================================================================
# $Req: @{ Method; Path; Query (Hashtable); Auth; Origin; Host; Body; Ip; Now }
# Rueckgabe: @{ Code; Type; Text oder Bytes; NoStore; Log; Headers }
function New-HURemoteJson([int]$Code, $Obj, [string]$Log = '') {
    $t = if ($Obj -is [string]) { $Obj } else { ConvertTo-Json -InputObject $Obj -Depth 8 -Compress }
    return @{ Code = $Code; Type = 'application/json; charset=utf-8'; Text = $t; NoStore = $true; Log = $Log; Headers = @{} }
}
function Add-HURemoteFail($S, [string]$Ip, [datetime]$Now) {
    $f = $S.FailIp[$Ip]
    if (-not $f -or $f.First -lt $Now.AddMinutes(-15)) { $f = @{ Count = 0; First = $Now; Until = [datetime]::MinValue } }
    $f.Count++
    if ($f.Count -ge 10) { $f.Until = $Now.AddMinutes(15) }
    $S.FailIp[$Ip] = $f
}
function Get-HURemoteJobJson($S, [datetime]$Now) {
    $j = $S.Job
    $sec = 0; try { if ($j.Started) { $end = if ($j.Ended) { [datetime]$j.Ended } else { $Now }; $sec = [int]($end - [datetime]$j.Started).TotalSeconds } } catch { }
    return [ordered]@{ running = [bool]$j.Running; title = "$($j.Title)"; kind = "$($j.Kind)"; by = "$($j.By)"; live = [bool]$j.Live
        started = $(if ($j.Started) { ([datetime]$j.Started).ToString('HH:mm:ss') } else { '' }); seconds = $sec
        result = "$($j.Result)"; level = "$($j.Level)"; tenants = @($j.Tenants); done = @($j.Done) }
}

function Get-HURemoteResponse($S, $Req) {
    $now = if ($Req.Now) { [datetime]$Req.Now } else { Get-Date }
    $path = "$($Req.Path)"
    $method = "$($Req.Method)".ToUpperInvariant()
    # statische Dateien (Seite, Skript, Design, Icons, Manifest, Service Worker, CA-Zertifikat)
    if (-not $path.StartsWith('/api/')) {
        if ($method -ne 'GET' -and $method -ne 'HEAD') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
        $key = if ($path -eq '/' -or $path -eq '') { '/index.html' } else { $path }
        $f = $S.Static[$key]
        if (-not $f) { return @{ Code = 404; Type = 'text/plain; charset=utf-8'; Text = 'Nicht gefunden'; NoStore = $true; Log = ''; Headers = @{} } }
        $h = @{}
        if ($f.Disposition) { $h['Content-Disposition'] = $f.Disposition }
        return @{ Code = 200; Type = $f.Type; Bytes = $f.Bytes; NoStore = [bool]$f.NoStore; Log = $(if ($key -eq '/ca.cer') { 'CA-Zertifikat geladen' } else { '' }); Headers = $h }
    }
    $fi = $S.FailIp[$Req.Ip]
    if ($fi -and $fi.Until -gt $now) { return (New-HURemoteJson 429 @{ ok = $false; error = 'Zu viele Fehlversuche - bitte 15 Minuten warten' } 'gesperrt (Fehlversuche)') }
    if ($method -ne 'GET' -and $method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
    # Schreibende Anfragen nur von der eigenen Seite (Origin muss zum Host passen)
    if ($method -eq 'POST' -and "$($Req.Origin)" -and "$($Req.Origin)" -ne "https://$($Req.Host)") { return (New-HURemoteJson 403 @{ ok = $false; error = 'Herkunft nicht erlaubt' } "abgelehnt (Origin $($Req.Origin))") }
    $body = $null
    if ($method -eq 'POST' -and "$($Req.Body)") { try { $body = "$($Req.Body)" | ConvertFrom-Json -ErrorAction Stop } catch { return (New-HURemoteJson 400 @{ ok = $false; error = 'Ungueltige Anfrage' }) } }

    # --- Koppeln (ohne Token): nur waehrend am PC das Kopplungsfenster offen ist
    if ($path -eq '/api/pair') {
        if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
        $pr = $S.Pair
        if (-not $pr -or $pr.Until -lt $now) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Kopplung ist nicht offen - in HU-MultiTenant den Knopf Remote FB druecken' } 'Kopplung nicht offen') }
        if ($pr.Locked) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Kopplung gesperrt (zu viele falsche Codes) - am PC neuen Code erzeugen' } 'Kopplung gesperrt') }
        $code = "$($body.code)" -replace '\s', ''
        if ($code -notmatch '^\d{6}$' -or -not (Test-HURemoteEqual $code $pr.Code)) {
            $pr.Fails++
            if ($pr.Fails -ge 5) { $pr.Locked = $true; $S.Events.Enqueue(@{ Kind = 'PairLocked' }) }
            Add-HURemoteFail $S $Req.Ip $now
            return (New-HURemoteJson 403 @{ ok = $false; error = $(if ($pr.Locked) { 'Falscher Code - Kopplung jetzt gesperrt' } else { "Falscher Code (noch $(5 - $pr.Fails) Versuche)" }) } 'falscher Kopplungscode')
        }
        if ($S.Devices.Count -ge $script:HURemoteMaxDevices) { return (New-HURemoteJson 409 @{ ok = $false; error = "Hoechstens $($script:HURemoteMaxDevices) Handys - am PC eines entfernen" } 'zu viele Geraete') }
        $name = ConvertTo-HURemoteDeviceName "$($body.name)"
        $tok = New-HURemoteToken
        $id = ((Get-HURemoteHash $tok).Substring(0, 8))
        $S.Devices[(Get-HURemoteHash $tok)] = @{ Id = $id; Name = $name; Created = $now.ToString('yyyy-MM-dd HH:mm'); LastSeen = $now.ToString('yyyy-MM-dd HH:mm'); LastIp = "$($Req.Ip)"; Locked = $false; PinFails = 0 }
        $S.DevDirty = $true
        # Code gilt nur einmal; danach ist die Kopplung zu (ein weiteres Handy: am PC erneut oeffnen)
        $S.Pair = $null
        $S.Events.Enqueue(@{ Kind = 'Paired'; Name = $name; Ip = "$($Req.Ip)" })
        return (New-HURemoteJson 200 @{ ok = $true; token = $tok; name = $name; pc = "$($S.Pc)" } "gekoppelt: $name")
    }

    # --- ab hier nur mit gueltigem Geraete-Token
    $dev = $null; $dh = ''
    if ("$($Req.Auth)" -match '^Bearer ([A-Za-z0-9_-]{20,100})$') { $dh = Get-HURemoteHash $Matches[1]; $dev = $S.Devices[$dh] }
    if (-not $dev) {
        Add-HURemoteFail $S $Req.Ip $now
        return (New-HURemoteJson 401 @{ ok = $false; error = 'Nicht gekoppelt' } 'ohne gueltiges Token')
    }
    $seen = $now.ToString('yyyy-MM-dd HH:mm')
    if ($dev.LastSeen -ne $seen -or $dev.LastIp -ne "$($Req.Ip)") { $dev.LastSeen = $seen; $dev.LastIp = "$($Req.Ip)"; $S.DevDirty = $true }

    switch ($path) {
        '/api/state' {
            $since = 0; try { $since = [int]"$($Req.Query['since'])" } catch { $since = 0 }
            $lines = @()
            $first = 0
            [System.Threading.Monitor]::Enter($S.Lines.SyncRoot)
            try {
                if ($S.Lines.Count) { $first = [int]$S.Lines[0].n }
                $lines = @($S.Lines | Where-Object { $_.n -gt $since } | ForEach-Object { [ordered]@{ n = $_.n; t = $_.t; l = $_.l; z = $_.z } })
            } finally { [System.Threading.Monitor]::Exit($S.Lines.SyncRoot) }
            $lost = if ($since -gt 0 -and $first -gt $since + 1) { $first - $since - 1 } else { 0 }
            return (New-HURemoteJson 200 ([ordered]@{ ok = $true; pc = "$($S.Pc)"; version = "$($S.Version)"; device = "$($dev.Name)"; locked = [bool]$dev.Locked
                    pin = [bool]$S.Pin; busy = "$($S.Busy)"; catVer = [int]$S.CatVer; seq = [int]$S.LineSeq; lost = $lost; lines = $lines; job = (Get-HURemoteJobJson $S $now) }))
        }
        '/api/catalog' {
            return (New-HURemoteJson 200 ('{"ok":true,"ver":' + [int]$S.CatVer + ',' + "$($S.CatalogJson)".TrimStart('{')))
        }
        '/api/prepare' {
            # Schritt 1: pruefen und zusammenfassen. Das Handy schickt nur Kennung, Tenants, Parameter, Ziel - nie Code.
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            if ($dev.Locked) { return (New-HURemoteJson 403 @{ ok = $false; error = 'Dieses Handy ist gesperrt (zu viele falsche PINs) - am PC entsperren' }) }
            $iid = "$($body.id)"
            $it = $null; if ($iid -match '^[0-9a-f]{16}$') { $it = $S.Items[$iid] }
            if (-not $it) { return (New-HURemoteJson 404 @{ ok = $false; error = 'Eintrag nicht (mehr) vorhanden - Liste wird aktualisiert' }) }
            if ($it.Stale) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Code wurde seit der Freigabe geaendert - am PC neu freigeben bzw. die Meldung neu speichern' }) }
            if ($S.Job.Running) { return (New-HURemoteJson 409 @{ ok = $false; error = "Es laeuft gerade: $($S.Job.Title)" }) }
            if ("$($S.Busy)") { return (New-HURemoteJson 409 @{ ok = $false; error = "Am PC laeuft gerade: $($S.Busy)" }) }
            # Tenants: nur bekannte, mindestens einer (kein automatisches "alle", Review 031 B22)
            $known = @($S.Tenants | ForEach-Object { "$($_.key)" })
            $tk = @(@($body.tenants) | ForEach-Object { "$_" } | Where-Object { $_ } | Select-Object -Unique)
            $iv = $null
            if ($it.Kind -eq 'intune') {
                if (-not $S.Intune) { return (New-HURemoteJson 403 @{ ok = $false; error = 'Apps und Wartung sind fuers Handy ausgeschaltet (am PC: Remote FB > Einstellungen)' }) }
                if ($tk.Count -ne 1) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Genau einen Tenant waehlen' }) }
                $iv = Test-HURemoteIntuneReq $body.intune "$($it.Area)"
                if (-not $iv.Ok) { return (New-HURemoteJson 400 @{ ok = $false; error = $iv.Error }) }
            }
            if ($it.Kind -ne 'teams' -or -not $it.FixedTenants) {
                if (-not $tk.Count) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Bitte mindestens einen Tenant waehlen' }) }
                foreach ($k in $tk) { if ($known -cnotcontains $k) { return (New-HURemoteJson 400 @{ ok = $false; error = "Unbekannter Tenant '$k'" }) } }
                if ($it.Kind -eq 'ext' -and $tk.Count -gt 5) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Hoechstens 5 Tenants je Lauf' }) }
            }
            $pv = Test-HURemoteParams $it.Params $body.params
            if (-not $pv.Ok) { return (New-HURemoteJson 400 @{ ok = $false; error = $pv.Error }) }
            # Teams: einmalig an ein gespeichertes Ziel (optional)
            $tgt = "$($body.target)"; $tgtName = ''
            if ($tgt) {
                if ($it.Kind -ne 'teams') { return (New-HURemoteJson 400 @{ ok = $false; error = 'Ziel nur bei Teams-Meldungen' }) }
                $tt = @($S.Targets | Where-Object { "$($_.id)" -eq $tgt })[0]
                if (-not $tt) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Unbekanntes Ziel' }) }
                $tgtName = "$($tt.name)"
            }
            $live = if ($iv) { $true } else { Test-HURemoteLive $it $pv.Values }   # Apps/Wartung aendern immer: Kuerzel + PIN
            if ($live -and -not $S.Pin) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Echter Lauf braucht eine Fernbedienungs-PIN - am PC unter Remote FB > Einstellungen festlegen' }) }
            $nb = Get-HURemoteRandomBytes 16
            $nonce = -join ($nb | ForEach-Object { $_.ToString('x2') })
            $short = if ($live) { New-HURemoteShortCode } else { '' }
            $tnames = @($tk | ForEach-Object { $k = $_; $x = @($S.Tenants | Where-Object { "$($_.key)" -eq $k })[0]; if ($x) { "$($x.name)" } else { $k } })
            $full = $false
            [System.Threading.Monitor]::Enter($S.Nonces.SyncRoot)
            try {
                # abgelaufene weg; je Handy gilt nur die neueste Bestaetigung (Zurueck + neu pruefen, Aufheben mehrerer
                # Zuweisungen nacheinander) - aeltere desselben Handys werden damit ungueltig
                foreach ($k in @($S.Nonces.Keys)) { if ($S.Nonces[$k].Exp -lt $now -or $S.Nonces[$k].Dev -eq $dh) { $S.Nonces.Remove($k) } }
                if ($S.Nonces.Count -ge 30) { $full = $true }
                else {
                    # an Geraet, Eintrag (inkl. Code-Stand), Tenants, Parameter und Ziel gebunden (Review 031 B15)
                    $S.Nonces[$nonce] = @{ Dev = $dh; Id = $iid; Hash = "$($it.Hash)"; Tenants = $tk; Values = $pv.Values; Target = $tgt; Live = $live; Short = $short; Exp = $now.AddSeconds($script:HURemoteConfirmSec); Intune = $(if ($iv) { $iv.Req } else { $null }) }
                }
            } finally { [System.Threading.Monitor]::Exit($S.Nonces.SyncRoot) }
            if ($full) { return (New-HURemoteJson 429 @{ ok = $false; error = 'Zu viele offene Anfragen - kurz warten' }) }
            $sum = [ordered]@{ title = $(if ($iv) { $iv.Title } else { "$($it.Name)" }); kind = "$($it.Kind)"; live = $live; tenants = $tnames
                params = @(if ($iv) { $iv.Lines | ForEach-Object { [ordered]@{ label = $_.Label; value = $_.Value; changed = $false } } } else { Format-HURemoteParamText $it.Params $pv.Values })   # @(): immer Liste (0/1 Eintrag)
                teams = $(if ($tgtName) { "einmalig an: $tgtName" } elseif ($it.Kind -eq 'teams') { "an: $($it.TargetText)" } else { '' })
                hint = $(if ($live) { "Aendert Daten in $($tk.Count) Tenant(s). Am PC steht 'gestartet von $($dev.Name)', an Teams geht ein Hinweis." } else { '' }) }
            return (New-HURemoteJson 200 ([ordered]@{ ok = $true; nonce = $nonce; seconds = $script:HURemoteConfirmSec; code = $short; summary = $sum }))
        }
        '/api/run' {
            # Schritt 2: Einmal-Bestaetigung (+ Kuerzel und PIN bei echtem Lauf). Falsche Eingabe verbraucht die Bestaetigung.
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            if ($dev.Locked) { return (New-HURemoteJson 403 @{ ok = $false; error = 'Dieses Handy ist gesperrt - am PC entsperren' }) }
            $nonce = "$($body.nonce)"
            if ($nonce -notmatch '^[0-9a-f]{32}$') { return (New-HURemoteJson 400 @{ ok = $false; error = 'Ungueltige Anfrage' }) }
            [System.Threading.Monitor]::Enter($S.Nonces.SyncRoot)
            try { $e = $S.Nonces[$nonce]; if ($e) { $S.Nonces.Remove($nonce) } } finally { [System.Threading.Monitor]::Exit($S.Nonces.SyncRoot) }
            if (-not $e -or $e.Dev -ne $dh -or $e.Exp -lt $now) { return (New-HURemoteJson 403 @{ ok = $false; error = 'Bestaetigung abgelaufen - bitte neu pruefen'; expired = $true } 'Start abgelehnt (Bestaetigung)') }
            if ($e.Live) {
                $codeOk = ("$($body.code)".Trim().ToUpperInvariant() -ceq "$($e.Short)")
                $pinOk = Test-HURemotePin "$($body.pin)" $S.Pin
                if (-not ($codeOk -and $pinOk)) {
                    if (-not $pinOk) {
                        $dev.PinFails = [int]$dev.PinFails + 1
                        if ($dev.PinFails -ge $script:HURemotePinFails) { $dev.Locked = $true; $S.Events.Enqueue(@{ Kind = 'DevLocked'; Name = "$($dev.Name)" }) }
                        $S.DevDirty = $true
                        Add-HURemoteFail $S $Req.Ip $now
                    }
                    $msg = if (-not $pinOk) { $(if ($dev.Locked) { 'Falsche PIN - Handy jetzt gesperrt (am PC entsperren)' } else { "Falsche PIN (noch $($script:HURemotePinFails - $dev.PinFails) Versuch(e))" }) } else { 'Kuerzel falsch' }
                    return (New-HURemoteJson 403 @{ ok = $false; error = "$msg - bitte neu pruefen"; expired = $true } "Echtlauf abgelehnt ($(if (-not $pinOk) { 'PIN' } else { 'Kuerzel' }))")
                }
                if ($dev.PinFails) { $dev.PinFails = 0; $S.DevDirty = $true }
            }
            $it = $S.Items[$e.Id]
            if (-not $it -or "$($it.Hash)" -ne "$($e.Hash)") { return (New-HURemoteJson 409 @{ ok = $false; error = 'Eintrag wurde inzwischen geaendert - bitte neu pruefen'; expired = $true }) }
            $busy = $false
            [System.Threading.Monitor]::Enter($S.Nonces.SyncRoot)
            try { if ($S.RunReq -or $S.Job.Running -or "$($S.Busy)") { $busy = $true } else { $S.RunReq = @{ Item = $it; Tenants = $e.Tenants; Values = $e.Values; Target = $e.Target; Live = $e.Live; Intune = $e.Intune; By = "$($dev.Name)"; DevId = "$($dev.Id)"; Ip = "$($Req.Ip)"; At = $now } } } finally { [System.Threading.Monitor]::Exit($S.Nonces.SyncRoot) }
            if ($busy) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Es laeuft gerade etwas - kurz warten' }) }
            return (New-HURemoteJson 202 @{ ok = $true } "Start angefordert: $($it.Name)$(if ($e.Live) { ' (ECHTER LAUF)' }) ($($dev.Name))")
        }
        '/api/intune' {
            # Apps/Wartung lesen: Liste, Details (Zuweisungen + Stand), Geraete, Gruppen. Antwort sofort aus dem
            # Zwischenspeicher oder "pending" - der PC liest im Hintergrund, das Handy fragt erneut.
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            if (-not $S.Intune) { return (New-HURemoteJson 403 @{ ok = $false; error = 'Apps und Wartung sind fuers Handy ausgeschaltet (am PC: Remote FB > Einstellungen)' }) }
            $op = "$($body.op)"; $area = "$($body.area)"; $tk = "$($body.tenant)"; $oid = "$($body.id)"
            if ($op -notin 'list', 'detail', 'devices', 'groups') { return (New-HURemoteJson 400 @{ ok = $false; error = 'Unbekannte Abfrage' }) }
            if ($op -eq 'groups') { $area = 'grp' } elseif ($area -notin 'app', 'rem') { return (New-HURemoteJson 400 @{ ok = $false; error = 'Unbekannter Bereich' }) }
            if (@($S.Tenants | ForEach-Object { "$($_.key)" }) -cnotcontains $tk) { return (New-HURemoteJson 400 @{ ok = $false; error = "Unbekannter Tenant '$tk'" }) }
            if ($op -in 'detail', 'devices') { if ($oid -notmatch $script:HURemoteGuidRx) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Ungueltige Kennung' }) } } else { $oid = '' }
            $key = "$op|$area|$tk|$oid"
            $ttl = switch ($op) { 'list' { 120 } 'detail' { 30 } 'devices' { 120 } default { 600 } }
            $force = ($body.force -eq $true)
            $res = $null; $full = $false
            [System.Threading.Monitor]::Enter($S.ICache.SyncRoot)
            try {
                $e = $S.ICache[$key]
                $age = if ($e) { ($now - $e.At).TotalSeconds } else { 1e9 }
                if ($e -and $e.State -eq 'pending' -and $age -lt 300) { $res = '{"ok":true,"pending":true}' }
                elseif ($e -and $e.State -ne 'pending' -and ($age -lt 3 -or (-not $force -and $age -lt $ttl))) {
                    $res = '{"ok":true,"pending":false,"at":"' + $e.At.ToString('HH:mm:ss') + '","error":' + (ConvertTo-Json -InputObject "$($e.Error)" -Compress) + ',"data":' + $(if ($e.Data) { $e.Data } else { 'null' }) + '}'
                }
                elseif ($S.IQueue.Count -ge 20) { $full = $true }
                else {
                    $S.ICache[$key] = @{ State = 'pending'; At = $now; Data = ''; Error = '' }
                    $S.IQueue.Enqueue(@{ Key = $key; Op = $op; Area = $area; Tenant = $tk; Id = $oid })
                    $res = '{"ok":true,"pending":true}'
                }
            } finally { [System.Threading.Monitor]::Exit($S.ICache.SyncRoot) }
            if ($full) { return (New-HURemoteJson 429 @{ ok = $false; error = 'Zu viele Abfragen - kurz warten' }) }
            return (New-HURemoteJson 200 $res)
        }
        '/api/cancel' {
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            if (-not ($body -and $body.confirm -eq $true)) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Bestaetigung fehlt' }) }
            if (-not $S.Job.Running) { return (New-HURemoteJson 409 @{ ok = $false; error = 'Es laeuft nichts' }) }
            $S.CancelReq = @{ By = "$($dev.Name)"; At = $now }
            return (New-HURemoteJson 202 @{ ok = $true } "Abbrechen angefordert ($($dev.Name))")
        }
        '/api/push' {
            # Push-Meldungen ohne Inhalt: GET = oeffentlicher Schluessel + Zustand, POST = Abo des Browsers eintragen
            if ($method -eq 'GET') { return (New-HURemoteJson 200 @{ ok = $true; key = "$($S.PushKey)"; on = [bool]"$($dev.PushEndpoint)" }) }
            if (-not "$($S.PushKey)") { return (New-HURemoteJson 409 @{ ok = $false; error = 'Push-Meldungen sind an diesem PC nicht verfuegbar' }) }
            $ep = "$($body.endpoint)"
            if (-not (Test-HURemotePushEndpoint $ep)) { return (New-HURemoteJson 400 @{ ok = $false; error = 'Push-Dienst nicht erlaubt' } 'Push-Abo abgelehnt (Adresse)') }
            $dev.PushEndpoint = $ep; $S.DevDirty = $true
            return (New-HURemoteJson 200 @{ ok = $true; on = $true } "Push-Meldungen an: $($dev.Name)")
        }
        '/api/push/off' {
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $dev.PushEndpoint = ''; $S.DevDirty = $true
            return (New-HURemoteJson 200 @{ ok = $true; on = $false } "Push-Meldungen aus: $($dev.Name)")
        }
        '/api/unpair' {
            if ($method -ne 'POST') { return (New-HURemoteJson 405 @{ ok = $false; error = 'Methode nicht erlaubt' }) }
            $S.Devices.Remove($dh); $S.DevDirty = $true
            $S.Events.Enqueue(@{ Kind = 'Unpaired'; Name = "$($dev.Name)" })
            return (New-HURemoteJson 200 @{ ok = $true } "entkoppelt: $($dev.Name)")
        }
    }
    return (New-HURemoteJson 404 @{ ok = $false; error = 'Nicht gefunden' })
}

# Sicherheits-Kopfzeilen fuer jede Antwort
$script:HURemoteHeaders = [ordered]@{
    'Content-Security-Policy' = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    'X-Content-Type-Options'  = 'nosniff'
    'X-Frame-Options'         = 'DENY'
    'Referrer-Policy'         = 'no-referrer'
    'Permissions-Policy'      = 'camera=(), microphone=(), geolocation=()'
    'Cross-Origin-Opener-Policy' = 'same-origin'
    'Cross-Origin-Resource-Policy' = 'same-origin'
}

# Zugriffsprotokoll (nie Token, Codes oder PIN)
function Write-HURemoteLog($S, [string]$Text) {
    if (-not $S.LogFile) { return }
    try { [IO.File]::AppendAllText($S.LogFile, ("{0}  {1}`r`n" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text), (New-Object Text.UTF8Encoding $false)) } catch { }
}

# Webserver-Schleife (im Hintergrund-Runspace). $S.Run = $false beendet sie.
function Start-HURemoteListenerLoop($S) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("https://+:$($S.Port)/")
    try {
        $tm = $l.TimeoutManager
        $tm.HeaderWait = [TimeSpan]::FromSeconds(10); $tm.EntityBody = [TimeSpan]::FromSeconds(10)
        $tm.IdleConnection = [TimeSpan]::FromSeconds(60); $tm.DrainEntityBody = [TimeSpan]::FromSeconds(10)
    } catch { }
    try { $l.Start() } catch { $S.Error = "Webserver nicht gestartet: $($_.Exception.Message)"; $S.Run = $false; return }
    $S.Listening = $true
    Write-HURemoteLog $S "Start: Port $($S.Port)"
    try {
        while ($S.Run) {
            $t = $l.GetContextAsync()
            while (-not $t.Wait(500)) { if (-not $S.Run) { break } }
            if (-not $S.Run) { break }
            $ctx = $null
            try { $ctx = $t.Result } catch { continue }
            $rq = $ctx.Request; $rs = $ctx.Response
            $ip = ''; try { $ip = "$($rq.RemoteEndPoint.Address)" } catch { }
            try {
                $body = ''
                if ($rq.HasEntityBody) {
                    if ($rq.ContentLength64 -gt $script:HURemoteMaxBody -or $rq.ContentLength64 -lt 0) { throw [System.IO.InvalidDataException]::new('zu gross') }
                    $buf = New-Object byte[] ([int]$rq.ContentLength64)
                    $read = 0
                    while ($read -lt $buf.Length) { $n = $rq.InputStream.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
                    $body = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
                }
                $q = @{}
                foreach ($k in @($rq.QueryString.AllKeys)) { if ($k) { $q[$k] = $rq.QueryString[$k] } }
                $res = Get-HURemoteResponse $S @{ Method = $rq.HttpMethod; Path = $rq.Url.AbsolutePath; Query = $q; Auth = "$($rq.Headers['Authorization'])"; Origin = "$($rq.Headers['Origin'])"; Host = "$($rq.Url.Authority)"; Body = $body; Ip = $ip; Now = (Get-Date) }
            } catch [System.IO.InvalidDataException] {
                $res = New-HURemoteJson 413 @{ ok = $false; error = 'Anfrage zu gross' } 'Anfrage zu gross'
            } catch {
                $res = New-HURemoteJson 500 @{ ok = $false; error = 'Interner Fehler' } "Fehler: $($_.Exception.Message)"
            }
            try {
                $rs.StatusCode = [int]$res.Code
                $rs.ContentType = $res.Type
                foreach ($h in $script:HURemoteHeaders.Keys) { $rs.Headers[$h] = $script:HURemoteHeaders[$h] }
                $rs.Headers['Cache-Control'] = $(if ($res.NoStore) { 'no-store' } else { 'no-cache' })
                foreach ($h in @($res.Headers.Keys)) { $rs.Headers[$h] = $res.Headers[$h] }
                $bytes = if ($null -ne $res.Bytes) { [byte[]]$res.Bytes } else { [Text.Encoding]::UTF8.GetBytes("$($res.Text)") }
                $rs.ContentLength64 = $bytes.Length
                if ($rq.HttpMethod -ne 'HEAD') { $rs.OutputStream.Write($bytes, 0, $bytes.Length) }
            } catch { } finally { try { $rs.Close() } catch { } }
            if ($res.Log -or [int]$res.Code -ge 400) { Write-HURemoteLog $S ("{0,-15} {1} {2} {3}{4}" -f $ip, $rq.HttpMethod, $rq.Url.AbsolutePath, $res.Code, $(if ($res.Log) { " - $($res.Log)" } else { '' })) }
        }
    } finally {
        $S.Listening = $false
        try { $l.Stop() } catch { }
        try { $l.Close() } catch { }
        Write-HURemoteLog $S 'Ende'
    }
}
