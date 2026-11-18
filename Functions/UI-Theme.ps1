#Requires -Version 5.1
<#
.SYNOPSIS
    Farbschema (Dunkel, Hell, wie Windows) fuer Kern und Module: Schema-Dateien laden, Farben und XAML umsetzen.
.DESCRIPTION
    Alle Oberflaechen sind dunkel gestaltet. Ein anderes Schema setzt die dunklen Farben beim Laden um, je nach Rolle:
      Bg (Flaechen, Zeilen), Fg (Text, Cursor), Border (Rahmen, Linien), Btn (graue Knopfflaeche), BtnFg (Schrift auf Knoepfen),
      Auto (ohne bekannte Rolle: Color=, Fill=, Get-HUBrush ohne Rolle), Status (Ampelfarben, nur ueber Get-HUBrush mit Rolle).
    Die Farbtabellen stehen NICHT im Code, sondern in Themes\<id>.json (Format siehe Read-HUThemeFile).
    Wirkt an den zentralen Ladestellen: New-HUWindow (alle Fenster, auch der Module), Reiter der Module, Toast, Get-HUBrush.
    Farbige Knoepfe (blau, gruen, rot, orange) bleiben, ihre weisse Schrift auch.
    Einstellung ui.theme: 'dark' | 'light' | 'system' (folgt dem App-Modus von Windows) | spaeter der Name einer eigenen Datei.
    Wirkt nach dem Neustart. Fehlt die Datei oder ist sie ungueltig, gilt 'dark'; die App scheitert daran nie.
.NOTES
    Dot-Source aus Main.ps1 VOR UI-Common. Keine Abhaengigkeit von WPF beim Laden. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
    Regel fuer die Tabellen: kein Zielwert darf in derselben Rolle selbst ein Schluessel sein (doppelt anwenden aendert nichts).
    Die Funktionsnamen Initialize-HUTheme, Get-HUThemeInfo, Get-HUTheme, Test-HULightTheme, Get-HUThemeList, Get-HUWindowsAppTheme,
    ConvertTo-HUThemeColor, ConvertTo-HUThemeXaml und Read-HUThemeFile sind die Schnittstelle fuer Module: stabil halten.
#>

# Zustand. Alles vorbelegt (StrictMode 1.0): ohne Initialize-HUTheme gilt Dunkel ohne Tabellen.
$script:HUThemeSetting = 'dark'        # Einstellung wie gewaehlt (dark | light | system | Name einer Datei)
$script:HUThemeId = 'dark'             # wirksames Schema
$script:HUThemeName = 'Dunkel'
$script:HUThemeKind = 'dark'           # dark | light, aus dem Feld "kind" der Datei
$script:HUThemeFile = ''
$script:HUThemeSchemaVersion = 1
$script:HUThemeWarning = ''            # Warnzeile vom letzten Initialize-HUTheme (leer = alles gut)
$script:HUThemeMaps = @{}              # Rolle -> @{ 'RRGGBB' = 'RRGGBB' } (ohne '#', gross)
$script:HUThemeLog = $null             # Protokollfarben des Schemas (Feld "log") oder $null
$script:HUThemeKeep = @()              # Farben, die bewusst bleiben (Feld "keep", nur fuer Tests)
$script:HUThemeActive = $false         # $true, wenn es Tabellen gibt (sonst sofortiger Ruecksprung)
$script:HUThemeCache = @{}
$script:HUThemeBlock = $null
$script:HUThemeAppRoot = ''
$script:HUThemeReadError = ''          # Grund, warum Read-HUThemeFile $null geliefert hat
$script:HUThemeXamlWarned = $false
$script:HUThemeRoleNames = @('Bg', 'Fg', 'Border', 'Btn', 'BtnFg', 'Auto', 'Status')
$script:HUThemeLogKeys = @('OK', 'WARN', 'ERROR', 'INFO', 'DEBUG', 'Text')

# Programmordner bestimmen: Parameter, sonst der zuletzt uebergebene, sonst $script:AppRoot der App
function Resolve-HUThemeAppRoot([string]$AppRoot = '') {
    if ($AppRoot) { return $AppRoot }
    if ($script:HUThemeAppRoot) { return $script:HUThemeAppRoot }
    $v = Get-Variable -Name AppRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($v) { return "$v" }
    return ''
}

# Ordner mit Schema-Dateien, in der Reihenfolge des Vorrangs (der erste mit passender Datei gewinnt).
# Spaeter hier den Ordner fuer eigene Schemata (%APPDATA%\HU-MultiTenant\themes) ergaenzen, sonst nichts aendern.
function Get-HUThemeFolders([string]$AppRoot = '') {
    $root = Resolve-HUThemeAppRoot $AppRoot
    $dirs = New-Object System.Collections.ArrayList
    if ($root) { [void]$dirs.Add((Join-Path $root 'Themes')) }
    return @($dirs.ToArray())
}

function Get-HUThemeProp($Object, [string]$Name) {
    # ,$v: Listen mit einem Eintrag nicht zu einem Einzelwert entpacken lassen
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $v = $Object.PSObject.Properties[$Name].Value; return ,$v }
    return $null
}

<#
.SYNOPSIS
    Eine Schema-Datei lesen und streng pruefen. Liefert das Schema oder $null (Grund in $script:HUThemeReadError).
.DESCRIPTION
    Format (UTF-8, Schluessel und Werte immer '#RRGGBB' gross):
      { "schema": 1, "id": "light", "name": "Hell", "kind": "light",
        "roles": { "Bg": { "#1E1E1E": "#F2EFE9" }, "Fg": {}, "Border": {}, "Btn": {}, "BtnFg": {}, "Auto": {}, "Status": {} },
        "log": { "OK": "#2E7D32", "WARN": "#C25E00", "ERROR": "#C62828", "INFO": "#1565C0", "DEBUG": "#6E675C", "Text": "#2E2A24" },
        "keep": [ "#1976D2" ] }
    Geprueft wird: JSON lesbar, schema = 1, id passt zum Dateinamen und zu ^[a-z0-9][a-z0-9_-]{0,31}$, kind = dark oder light,
    nur bekannte Rollen, jede Farbe genau '#RRGGBB' (nichts anderes, keine Ausdruecke), in keiner Rolle ist ein Zielwert zugleich
    Schluessel (keine Ketten). Unbekannte zusaetzliche Felder werden ignoriert (Vorwaertskompatibilitaet).
.OUTPUTS
    [pscustomobject] Id, Name, Kind, SchemaVersion, File, Roles (Rolle -> Hashtable ohne '#', gross), Log (Hashtable oder $null), Keep
#>
function Read-HUThemeFile([string]$Path) {
    $script:HUThemeReadError = ''
    $hexRx = '^#[0-9A-Fa-f]{6}\z'
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { $script:HUThemeReadError = 'Datei fehlt'; return $null }
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        $j = $null
        try { $j = [IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop } catch { $script:HUThemeReadError = 'kein gueltiges JSON'; return $null }
        if ($null -eq $j -or $j -isnot [pscustomobject]) { $script:HUThemeReadError = 'kein JSON-Objekt'; return $null }

        $sv = Get-HUThemeProp $j 'schema'
        if ($null -eq $sv -or $sv -is [string] -or $sv -is [bool] -or $sv -ne 1) { $script:HUThemeReadError = 'schema ist nicht 1'; return $null }
        $id = Get-HUThemeProp $j 'id'
        if ($id -isnot [string] -or $id -cnotmatch '^[a-z0-9][a-z0-9_-]{0,31}\z') { $script:HUThemeReadError = 'id ungueltig'; return $null }
        if ($id -cne $base) { $script:HUThemeReadError = 'id passt nicht zum Dateinamen'; return $null }
        $kind = Get-HUThemeProp $j 'kind'
        if ($kind -isnot [string] -or @('dark', 'light') -cnotcontains $kind) { $script:HUThemeReadError = 'kind ist weder dark noch light'; return $null }
        $name = Get-HUThemeProp $j 'name'
        if ($name -isnot [string] -or -not $name.Trim()) { $name = $id }

        $rolesObj = Get-HUThemeProp $j 'roles'
        if ($null -eq $rolesObj -or $rolesObj -isnot [pscustomobject]) { $script:HUThemeReadError = 'roles fehlt'; return $null }
        $roles = @{}
        foreach ($rp in $rolesObj.PSObject.Properties) {
            if ($script:HUThemeRoleNames -cnotcontains $rp.Name) { $script:HUThemeReadError = "unbekannte Rolle $($rp.Name)"; return $null }
            if ($null -eq $rp.Value -or $rp.Value -isnot [pscustomobject]) { $script:HUThemeReadError = "Rolle $($rp.Name) ist keine Tabelle"; return $null }
            $map = @{}
            foreach ($ep in $rp.Value.PSObject.Properties) {
                if ($ep.Name -cnotmatch $hexRx -or $ep.Value -isnot [string] -or $ep.Value -cnotmatch $hexRx) {
                    $script:HUThemeReadError = "Rolle $($rp.Name): Farbe ungueltig ($($ep.Name))"; return $null
                }
                $k = $ep.Name.Substring(1).ToUpperInvariant()
                if ($map.ContainsKey($k)) { $script:HUThemeReadError = "Rolle $($rp.Name): Schluessel doppelt ($($ep.Name))"; return $null }
                $map[$k] = $ep.Value.Substring(1).ToUpperInvariant()
            }
            foreach ($v in $map.Values) {
                if ($map.ContainsKey($v)) { $script:HUThemeReadError = "Rolle $($rp.Name): Kette ueber #$v"; return $null }
            }
            $roles[$rp.Name] = $map
        }

        $log = $null
        $logObj = Get-HUThemeProp $j 'log'
        if ($null -ne $logObj) {
            if ($logObj -isnot [pscustomobject]) { $script:HUThemeReadError = 'log ist kein Objekt'; return $null }
            $log = @{}
            foreach ($lk in $script:HUThemeLogKeys) {
                if (-not $logObj.PSObject.Properties[$lk]) { continue }
                $lv = $logObj.PSObject.Properties[$lk].Value
                if ($lv -isnot [string] -or $lv -cnotmatch $hexRx) { $script:HUThemeReadError = "log: Farbe $lk ungueltig"; return $null }
                $log[$lk] = $lv.ToUpperInvariant()
            }
            if (-not $log.Count) { $log = $null }
        }

        $keep = @()
        $keepObj = Get-HUThemeProp $j 'keep'
        if ($null -ne $keepObj) {
            if ($keepObj -isnot [System.Array]) { $script:HUThemeReadError = 'keep ist keine Liste'; return $null }
            foreach ($kv in $keepObj) {
                if ($kv -isnot [string] -or $kv -cnotmatch $hexRx) { $script:HUThemeReadError = 'keep: Farbe ungueltig'; return $null }
                $keep += $kv.ToUpperInvariant()
            }
        }
        return [pscustomobject]@{ Id = $id; Name = $name.Trim(); Kind = $kind; SchemaVersion = 1; File = $Path; Roles = $roles; Log = $log; Keep = $keep }
    } catch {
        $script:HUThemeReadError = "Fehler beim Lesen: $($_.Exception.Message)"
        return $null
    }
}

# Eine Warnzeile ins Protokoll (nur wenn Write-HULog da ist, sonst still); merkt sie fuer Get-HUThemeInfo
function Write-HUThemeWarning([string]$Text) {
    $script:HUThemeWarning = $Text
    try { if (Get-Command Write-HULog -ErrorAction SilentlyContinue) { Write-HULog -Message $Text -Level 'WARN' } } catch { }
}

<#
.SYNOPSIS
    Windows-Einstellung "App-Modus" lesen: 'light' oder 'dark'.
.DESCRIPTION
    HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize, Wert AppsUseLightTheme (1 = hell, 0 = dunkel).
    Der Registry-Wert ist von Microsoft nicht offiziell dokumentiert (Learn beschreibt nur UISettings aus WinRT:
    https://learn.microsoft.com/windows/apps/desktop/modernize/apply-windows-themes ). Bekannt ist: 1 = hell, 0 = dunkel.
    Fehlt Schluessel oder Wert, ist er nicht lesbar oder tritt ein Fehler auf (SYSTEM, geplante Aufgabe): 'dark'.
#>
function Get-HUWindowsAppTheme {
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ($null -ne $v -and "$v" -eq '1') { return 'light' }
    } catch { }
    return 'dark'
}

<#
.SYNOPSIS
    Einstellung in das wirksame Farbschema aufloesen und dessen Datei laden. Wirft nie.
.PARAMETER Setting
    'dark' | 'light' | 'system' | Name einer Schema-Datei. Leer oder ungueltig: 'dark'. 'system' folgt Get-HUWindowsAppTheme.
.PARAMETER AppRoot
    Programmordner mit Themes\ (sonst $script:AppRoot).
.NOTES
    Einstellung (Get-HUThemeInfo.Setting) und wirksames Schema (Get-HUThemeInfo.Id) werden getrennt gemerkt.
    Fehlt die Datei oder ist sie ungueltig: Schema dark, eine Warnzeile im Protokoll.
#>
function Initialize-HUTheme([string]$Setting = '', [string]$AppRoot = '') {
    # Grundzustand: Dunkel ohne Tabellen
    $script:HUThemeSetting = 'dark'; $script:HUThemeId = 'dark'; $script:HUThemeName = 'Dunkel'; $script:HUThemeKind = 'dark'
    $script:HUThemeFile = ''; $script:HUThemeSchemaVersion = 1; $script:HUThemeWarning = ''
    $script:HUThemeMaps = @{}; $script:HUThemeLog = $null; $script:HUThemeKeep = @(); $script:HUThemeActive = $false
    $script:HUThemeCache = @{}; $script:HUThemeBlock = $null; $script:HUThemeXamlWarned = $false
    try {
        $root = Resolve-HUThemeAppRoot $AppRoot
        $script:HUThemeAppRoot = $root
        $want = "$Setting".Trim().ToLowerInvariant()
        $eff = 'dark'
        $problem = ''
        if (-not $want) { $want = 'dark' }
        elseif ($want -ceq 'system') {
            $eff = "$(Get-HUWindowsAppTheme)".Trim().ToLowerInvariant()
            if ($eff -cne 'light') { $eff = 'dark' }
        }
        elseif ($want -cmatch '^[a-z0-9][a-z0-9_-]{0,31}\z') { $eff = $want }
        else { $problem = "Farbschema '$want' ist kein gueltiger Name"; $want = 'dark' }
        $script:HUThemeSetting = $want

        $th = $null
        if (-not $problem) {
            $why = 'Datei nicht gefunden'
            foreach ($dir in @(Get-HUThemeFolders $root)) {
                $path = Join-Path $dir "$eff.json"
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $th = Read-HUThemeFile $path
                if ($th) { break }
                $why = $script:HUThemeReadError
            }
            if (-not $th) { $problem = "Farbschema '$eff' nicht geladen ($why)" }
        }
        if ($th) {
            $script:HUThemeId = $th.Id; $script:HUThemeName = $th.Name; $script:HUThemeKind = $th.Kind
            $script:HUThemeFile = $th.File; $script:HUThemeSchemaVersion = $th.SchemaVersion
            $script:HUThemeMaps = $th.Roles; $script:HUThemeLog = $th.Log; $script:HUThemeKeep = @($th.Keep)
            foreach ($rk in $th.Roles.Keys) { if ($th.Roles[$rk].Count) { $script:HUThemeActive = $true } }
        } else {
            Write-HUThemeWarning "$problem - es gilt das dunkle Farbschema."
        }
    } catch {
        $script:HUThemeId = 'dark'; $script:HUThemeName = 'Dunkel'; $script:HUThemeKind = 'dark'; $script:HUThemeFile = ''
        $script:HUThemeMaps = @{}; $script:HUThemeLog = $null; $script:HUThemeActive = $false
        Write-HUThemeWarning "Farbschema nicht geladen ($($_.Exception.Message)) - es gilt das dunkle Farbschema."
    }
}

<#
.SYNOPSIS
    Angaben zum Farbschema: Setting (Einstellung), Id (wirksam), Name, IsLight, File, SchemaVersion, Warning (leer = keine).
#>
function Get-HUThemeInfo {
    return [pscustomobject]@{
        Setting       = $script:HUThemeSetting
        Id            = $script:HUThemeId
        Name          = $script:HUThemeName
        IsLight       = [bool]($script:HUThemeKind -ceq 'light')
        File          = $script:HUThemeFile
        SchemaVersion = $script:HUThemeSchemaVersion
        Warning       = $script:HUThemeWarning
    }
}

# Id des wirksamen Schemas
function Get-HUTheme { return $script:HUThemeId }

# $true bei hellem Schema (Feld "kind" der Datei, nicht der Name)
function Test-HULightTheme { return [bool]($script:HUThemeKind -ceq 'light') }

# Protokollfarben des Schemas (Feld "log": OK, WARN, ERROR, INFO, DEBUG, Text als '#RRGGBB') oder $null, wenn es keine gibt
function Get-HUThemeLogColors {
    if (-not $script:HUThemeLog) { return $null }
    $o = @{}
    foreach ($k in $script:HUThemeLog.Keys) { $o[$k] = $script:HUThemeLog[$k] }
    return $o
}

<#
.SYNOPSIS
    Alle gueltigen Schema-Dateien aus Themes\*.json (Id, Name, Kind, File). dark und light zuerst, der Rest nach Id.
#>
function Get-HUThemeList([string]$AppRoot = '') {
    $seen = @{}
    $items = New-Object System.Collections.ArrayList
    foreach ($dir in @(Get-HUThemeFolders $AppRoot)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $t = Read-HUThemeFile $f.FullName
            if (-not $t -or $seen.ContainsKey($t.Id)) { continue }
            $seen[$t.Id] = $true
            [void]$items.Add([pscustomobject]@{ Id = $t.Id; Name = $t.Name; Kind = $t.Kind; File = $t.File })
        }
    }
    $order = { switch ($_.Id) { 'dark' { '0' } 'light' { '1' } default { "2$($_.Id)" } } }
    return @($items.ToArray() | Sort-Object -Property @{ Expression = $order })
}

<#
.SYNOPSIS
    Eine Farbe ins wirksame Farbschema umsetzen. Im dunklen Schema (ohne Tabellen) unveraendert.
.PARAMETER Role
    Bg | Fg | Border | Btn | BtnFg | Status | Auto (Standard). Farben im Code am besten mit Rolle: Text = Fg, Flaeche = Bg.
    Unbekannte Rolle gilt als Auto.
.OUTPUTS
    [string] '#RRGGBB' bzw. '#AARRGGBB' (Deckkraft bleibt) oder die Eingabe, wenn nichts zu tun ist.
#>
function ConvertTo-HUThemeColor([string]$Color, [string]$Role = 'Auto') {
    if (-not $script:HUThemeActive -or -not $Color) { return $Color }
    $v = $Color.Trim()
    $alpha = ''
    if ($v -eq 'White') { $hex = 'FFFFFF' }
    elseif ($v -match '^#([0-9A-Fa-f]{2})?([0-9A-Fa-f]{6})$') { $alpha = "$($Matches[1])"; $hex = $Matches[2].ToUpperInvariant() }
    else { return $Color }
    if ($script:HUThemeRoleNames -cnotcontains $Role) { $Role = 'Auto' }
    $map = $script:HUThemeMaps[$Role]
    if (-not $map) { return $Color }
    if ($map.ContainsKey($hex)) { return "#$alpha$($map[$hex])" }
    return $Color
}

# Rolle einer Eigenschaft. $Btn: Knopf-Umfeld; $WhiteText: der Knopf hat weisse (oder keine eigene) Schrift
function Get-HUThemeRole([string]$Property, [bool]$Btn, [bool]$WhiteText) {
    $p = $Property; $i = $p.LastIndexOf('.'); if ($i -ge 0) { $p = $p.Substring($i + 1) }
    switch -regex ($p) {
        '^(Background|RowBackground|AlternatingRowBackground)$' { if ($Btn -and $WhiteText) { return 'Btn' } return 'Bg' }
        '^(Foreground|CaretBrush)$' { if ($Btn) { return 'BtnFg' } return 'Fg' }
        '^(BorderBrush|HorizontalGridLinesBrush|VerticalGridLinesBrush|Stroke)$' { return 'Border' }
        default { return 'Auto' }
    }
}

<#
.SYNOPSIS
    XAML-Text ins wirksame Farbschema umsetzen (nur Farben in Attributen und Settern). Im dunklen Schema unveraendert.
.DESCRIPTION
    Geht die Tags der Reihe nach durch und merkt sich das Umfeld (Knopf, Style mit TargetType Button). Setter mit TargetName
    (Hover in Vorlagen) zaehlen nicht als Knopfflaeche. Ergebnis wird je XAML-Text zwischengespeichert; der eingesetzte
    Theme-Teil (XAML\Theme.xaml) wird nur einmal umgesetzt. Im dunklen Schema kommt vor jeder Regex dasselbe String-Objekt zurueck.
    Bei einem Fehler in der Umsetzung kommt das Original zurueck (einmal protokolliert).
#>
function ConvertTo-HUThemeXaml([string]$Xaml) {
    if (-not $script:HUThemeActive -or -not $Xaml) { return $Xaml }
    if ($script:HUThemeCache.ContainsKey($Xaml)) { return $script:HUThemeCache[$Xaml] }
    try {
        # Der eingesetzte Theme-Teil steckt in fast jedem Fenster: nur einmal umsetzen, dann einsetzen
        if (-not $script:HUThemeBlock) {
            $script:HUThemeBlock = @{ Dark = ''; Light = '' }
            try {
                $tf = Join-Path (Join-Path (Resolve-HUThemeAppRoot) 'XAML') 'Theme.xaml'
                $tm = [regex]::Match([IO.File]::ReadAllText($tf, [Text.Encoding]::UTF8), '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
                if ($tm.Success -and $tm.Groups[1].Value.Length -gt 100) {
                    $dk = $tm.Groups[1].Value
                    $lt = ConvertTo-HUThemeXamlCore $dk
                    $script:HUThemeBlock.Dark = $dk
                    $script:HUThemeBlock.Light = $lt
                }
            } catch { }
        }
        $tb = $script:HUThemeBlock
        if ($tb.Dark -and $Xaml.Contains($tb.Dark)) {
            $out = (ConvertTo-HUThemeXamlCore ($Xaml.Replace($tb.Dark, '<!--HU:THEME-HELL-->'))).Replace('<!--HU:THEME-HELL-->', $tb.Light)
        } else { $out = ConvertTo-HUThemeXamlCore $Xaml }
        if ($script:HUThemeCache.Count -gt 200) { $script:HUThemeCache = @{} }
        $script:HUThemeCache[$Xaml] = $out
        return $out
    } catch {
        if (-not $script:HUThemeXamlWarned) {
            $script:HUThemeXamlWarned = $true
            try { if (Get-Command Write-HULog -ErrorAction SilentlyContinue) { Write-HULog -Message "Farbschema: XAML nicht umgesetzt ($($_.Exception.Message))" -Level 'WARN' } } catch { }
        }
        return $Xaml
    }
}

# Kern der XAML-Umsetzung (ohne Zwischenspeicher)
function ConvertTo-HUThemeXamlCore([string]$Xaml) {
    $tagRx = [regex]'<!--[\s\S]*?-->|<(/?)([A-Za-z_][\w:.]*)((?:"[^"]*"|''[^'']*''|[^''">])*?)(/?)>'
    $attRx = [regex]'(\s)([\w:.]+)(\s*=\s*)"([^"]*)"'
    $sb = New-Object System.Text.StringBuilder ($Xaml.Length + 256)
    $stack = New-Object System.Collections.ArrayList
    $pos = 0
    foreach ($m in $tagRx.Matches($Xaml)) {
        [void]$sb.Append($Xaml, $pos, $m.Index - $pos); $pos = $m.Index + $m.Length
        if ($m.Value.StartsWith('<!--')) { [void]$sb.Append($m.Value); continue }
        $name = $m.Groups[2].Value
        if ($m.Groups[1].Value -eq '/') {
            for ($i = $stack.Count - 1; $i -ge 0; $i--) { if ($stack[$i].N -eq $name) { $stack.RemoveRange($i, $stack.Count - $i); break } }
            [void]$sb.Append($m.Value); continue
        }
        $attrs = $m.Groups[3].Value
        $tt = ''; $mt = [regex]::Match($attrs, 'TargetType\s*=\s*"(?:\{x:Type\s+)?([\w:]+)\}?"'); if ($mt.Success) { $tt = $mt.Groups[1].Value }
        $btnHere = ($name -eq 'Button' -or $tt -match '(^|:)Button$')
        $btnAnc = $btnHere; if (-not $btnAnc) { foreach ($s in $stack) { if ($s.B) { $btnAnc = $true; break } } }
        if ($attrs -match '#[0-9A-Fa-f]{6}|"White"') {
            $isSetter = ($name -eq 'Setter')
            $setRole = ''
            $wT = $true
            if ($isSetter) {
                $prop = ''; $mp = [regex]::Match($attrs, '\sProperty\s*=\s*"([^"]*)"'); if ($mp.Success) { $prop = $mp.Groups[1].Value }
                $hasTarget = $attrs -match '\sTargetName\s*='
                # Knopf-Style: Standard DarkButton hat weisse Schrift
                $setRole = Get-HUThemeRole $prop ($btnAnc -and -not $hasTarget) $true
            } else {
                $mf = [regex]::Match($attrs, '\sForeground\s*=\s*"([^"]*)"')
                if ($mf.Success -and $mf.Groups[1].Value -notmatch '^(White|#(FF)?FFFFFF)$') { $wT = $false }
            }
            $ab = New-Object System.Text.StringBuilder
            $ap = 0
            foreach ($a in $attRx.Matches($attrs)) {
                [void]$ab.Append($attrs, $ap, $a.Index - $ap); $ap = $a.Index + $a.Length
                $an = $a.Groups[2].Value; $av = $a.Groups[4].Value
                if ($isSetter) { if ($an -eq 'Value') { $av = ConvertTo-HUThemeColor $av $setRole } }
                else { $av = ConvertTo-HUThemeColor $av (Get-HUThemeRole $an $btnAnc $wT) }
                [void]$ab.Append($a.Groups[1].Value).Append($an).Append($a.Groups[3].Value).Append('"').Append($av).Append('"')
            }
            [void]$ab.Append($attrs, $ap, $attrs.Length - $ap)
            $attrs = $ab.ToString()
        }
        $self = ($m.Groups[4].Value -eq '/')
        [void]$sb.Append('<').Append($name).Append($attrs).Append($(if ($self) { '/>' } else { '>' }))
        if (-not $self) { [void]$stack.Add(@{ N = $name; B = $btnHere }) }
    }
    [void]$sb.Append($Xaml, $pos, $Xaml.Length - $pos)
    return $sb.ToString()
}
