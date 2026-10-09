#Requires -Version 5.1
<#
.SYNOPSIS
    Snippet-Parameter fuer Quick Scripts: Kopfzeilen im Code werden zu Eingabefeldern ueber dem Editor.
.DESCRIPTION
    Format (gleich wie .PARAM bei Extensions):  # @param Name|Typ|Beschriftung|Standard|Auswahl1;Auswahl2
    Typen: bool, int, string, choice. Der Wert steht im Skript als Variable $Name zur Verfuegung.
    Wird von der Oberflaeche (UI-QSParams.ps1) und den Pester-Tests geladen.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

# ============================================================================
# Snippet-Parameter (auch in der Oberflaeche verwendet)
#   # @param DryRun|bool|Nur anzeigen, nichts aendern|true
#   # @param Tage|int|Inaktiv seit Tagen|90
#   # @param Gruppe|string|Gruppenname|
#   # @param Modus|choice|Modus|Audit|Audit;SetUp;Export
# ============================================================================
function ConvertFrom-HUQSParamLine([string]$Line) {
    $m = [regex]::Match($Line, '^\s*#\s*@param\s+(.+?)\s*$')
    if (-not $m.Success) { return $null }
    $p = $m.Groups[1].Value -split '\|'
    $name = "$($p[0])".Trim().TrimStart('$')
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $null }
    $type = if ($p.Count -gt 1 -and "$($p[1])".Trim()) { "$($p[1])".Trim().ToLower() } else { 'string' }
    if ($type -notin 'bool', 'int', 'string', 'choice') { $type = 'string' }
    $choices = @()
    if ($p.Count -gt 4) { $choices = @("$($p[4])" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($type -eq 'choice' -and -not $choices.Count) { $type = 'string' }
    return [pscustomobject]@{
        Name    = $name
        Type    = $type
        Label   = $(if ($p.Count -gt 2 -and "$($p[2])".Trim()) { "$($p[2])".Trim() } else { $name })
        Default = $(if ($p.Count -gt 3) { "$($p[3])".Trim() } else { '' })
        Choices = $choices
    }
}

function Get-HUQSParams([string]$Code) {
    $list = @()
    $seen = @{}
    foreach ($ln in ("$Code" -split "`r?`n")) {
        if ($ln -notmatch '@param') { continue }
        $p = ConvertFrom-HUQSParamLine $ln
        if ($p -and -not $seen.ContainsKey($p.Name.ToLower())) { $seen[$p.Name.ToLower()] = $true; $list += $p }
    }
    return $list
}

# Text aus dem Eingabefeld in den Typ des Parameters umwandeln
function ConvertTo-HUQSParamValue($Param, $Value) {
    switch ($Param.Type) {
        'bool' { if ($Value -is [bool]) { return $Value }; return ("$Value".Trim() -match '^(true|1|ja|yes|\$true|wahr)$') }
        'int' { $i = 0; if ([int]::TryParse("$Value".Trim(), [ref]$i)) { return $i }; throw "'$($Param.Label)': '$Value' ist keine Zahl" }
        default { return "$Value" }
    }
}

# Schutz-Parameter: DryRun / WhatIf / Simulation / Test / Probelauf = false -> echter Lauf
function Test-HUQSLiveRun([object[]]$Params, [hashtable]$Values) {
    foreach ($p in @($Params)) {
        if ($p.Type -eq 'bool' -and $p.Name -match '^(DryRun|WhatIf|Simulation|Simulate|Test|TestMode|Probelauf|NurAnzeigen|Preview)$' -and $Values.ContainsKey($p.Name) -and -not $Values[$p.Name]) { return $true }
    }
    return $false
}

# ============================================================================
# Wartungsskripte (Remediations): @param-Felder, deren Wert DIREKT im Skript steht
#   # @param PwPlain|string|Passwort|
#   $PwPlain = 'Geheim'  # @value
# Intune kennt keine Parameter - was im Editor steht, wird genau so hochgeladen. Die Felder
# aendern nur die @value-Zeile. So bleiben die Werte auch beim Lesen aus Intune erhalten.
# ============================================================================
function Get-HURemParamValueRx([string]$Name) { return ('^(\s*)\$' + [regex]::Escape($Name) + '\s*=\s*(.*?)\s*#\s*@value\s*$') }

# Literal aus einer @value-Zeile lesen (ueber den PowerShell-Parser, also auch mit '' und typografischen Anfuehrungszeichen)
function ConvertFrom-HURemParamLiteral([string]$Text) {
    $t = "$Text".Trim()
    if (-not $t) { return '' }
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$null, [ref]$err)
    if (@($err).Count -or @($ast.EndBlock.Statements).Count -ne 1) { return $t }
    $st = $ast.EndBlock.Statements[0]
    if ($st -is [System.Management.Automation.Language.PipelineAst] -and @($st.PipelineElements).Count -eq 1 -and $st.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $e = $st.PipelineElements[0].Expression
        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $e.Value }
        if ($e -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $e.Value }
        if ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.VariablePath.UserPath -in 'true', 'false') { return ($e.VariablePath.UserPath -eq 'true') }
    }
    return $t
}

# Wert als PowerShell-Literal fuer die @value-Zeile (Text immer in einfachen Anfuehrungszeichen, sicher maskiert)
function ConvertTo-HURemParamLiteral($Param, $Value) {
    switch ($Param.Type) {
        'bool' { if (ConvertTo-HUQSParamValue $Param $Value) { return '$true' } else { return '$false' } }
        'int' {
            if ("$Value".Trim() -eq '') { return '0' }
            return "$(ConvertTo-HUQSParamValue $Param $Value)"
        }
        default {
            $s = "$Value"
            if ($s -match "[`r`n]") { throw "'$($Param.Label)': nur eine Zeile erlaubt" }
            # alle Zeichen, die PowerShell als einfaches Anfuehrungszeichen wertet, verdoppeln
            return "'" + [regex]::Replace($s, "(['‘’‚‛])", '$1$1') + "'"
        }
    }
}

# Aktuelle Werte (Name -> Wert) aus den @value-Zeilen
function Get-HURemParamValues([string]$Code) {
    $h = @{}
    $lines = @("$Code" -split "`r?`n")
    foreach ($p in @(Get-HUQSParams $Code)) {
        $rx = Get-HURemParamValueRx $p.Name
        foreach ($ln in $lines) { $m = [regex]::Match($ln, $rx); if ($m.Success) { $h[$p.Name] = ConvertFrom-HURemParamLiteral $m.Groups[2].Value; break } }
    }
    return $h
}

# @value-Zeilen setzen: Values = Name -> Wert. -FillDefaults: fehlende @value-Zeilen mit dem Standard ergaenzen.
function Set-HURemParamValues([string]$Code, [hashtable]$Values = @{}, [switch]$FillDefaults) {
    if (-not "$Code".Trim()) { return $Code }
    $nl = if ($Code -match "`r`n") { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ("$Code" -split "`r?`n")) { $lines.Add($l) }
    foreach ($p in @(Get-HUQSParams $Code)) {
        $rx = Get-HURemParamValueRx $p.Name
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ([regex]::IsMatch($lines[$i], $rx)) { $idx = $i; break } }
        if ($Values.ContainsKey($p.Name)) { $val = $Values[$p.Name] }
        elseif ($idx -lt 0 -and $FillDefaults) { $val = $p.Default }
        else { continue }
        $lit = ConvertTo-HURemParamLiteral $p $val
        if ($idx -ge 0) {
            $indent = [regex]::Match($lines[$idx], $rx).Groups[1].Value
            $lines[$idx] = "$indent`$$($p.Name) = $lit  # @value"
        } else {
            $pi = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { $d = ConvertFrom-HUQSParamLine $lines[$i]; if ($d -and $d.Name -eq $p.Name) { $pi = $i; break } }
            if ($pi -lt 0) { continue }
            $indent = [regex]::Match($lines[$pi], '^\s*').Value
            $lines.Insert($pi + 1, "$indent`$$($p.Name) = $lit  # @value")
        }
    }
    return ($lines -join $nl)
}

# Pruefung der @param-Felder eines Wartungsskripts -> Liste @{ Stufe; Hinweis }
function Test-HURemParams([string]$Code, [string]$Name = 'Skript') {
    $out = New-Object System.Collections.Generic.List[object]
    $defs = @(Get-HUQSParams $Code)
    if (-not $defs.Count) { return $out.ToArray() }
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$err)
    if (@($err).Count) { return $out.ToArray() }
    if ($ast.ParamBlock) { $out.Add([pscustomobject]@{ Stufe = 'Fehler'; Hinweis = "${Name}: @param-Felder und ein param()-Block vertragen sich nicht - Werte bitte nur ueber @param setzen." }) }
    $lines = @("$Code" -split "`r?`n")
    $vars = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    foreach ($p in $defs) {
        $rx = Get-HURemParamValueRx $p.Name
        $vl = 0
        for ($i = 0; $i -lt $lines.Count; $i++) { if ([regex]::IsMatch($lines[$i], $rx)) { $vl = $i + 1; break } }
        if (-not $vl) { $out.Add([pscustomobject]@{ Stufe = 'Warnung'; Hinweis = "${Name}: Feld '$($p.Label)' hat noch keine Wertzeile - beim Speichern wird der Standard eingesetzt." }); continue }
        try { $v = ConvertFrom-HURemParamLiteral ([regex]::Match($lines[$vl - 1], $rx).Groups[2].Value); [void](ConvertTo-HURemParamLiteral $p $v) }
        catch { $out.Add([pscustomobject]@{ Stufe = 'Fehler'; Hinweis = "${Name}: Feld '$($p.Label)': $($_.Exception.Message)" }) }
        $asg = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.StartLineNumber -eq $vl }, $true))[0]
        if ($asg -and -not ($asg.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $asg.Parent.Parent -eq $ast)) {
            $out.Add([pscustomobject]@{ Stufe = 'Fehler'; Hinweis = "${Name}: Feld '$($p.Label)' steht nicht auf oberster Ebene (z. B. in einer Funktion) - die @param-Zeile bitte an den Skriptanfang." })
        }
        $early = @($vars | Where-Object { $_.VariablePath.UserPath -eq $p.Name -and $_.Extent.StartLineNumber -lt $vl } | Select-Object -First 1)
        if ($early.Count) { $out.Add([pscustomobject]@{ Stufe = 'Fehler'; Hinweis = "${Name}: `$$($p.Name) wird in Zeile $($early[0].Extent.StartLineNumber) verwendet, bevor das Feld gesetzt ist - die @param-Zeile bitte nach oben." }) }
    }
    return $out.ToArray()
}

# Einfache Zuweisungen am Skriptanfang (Text, ganze Zahl, $true/$false), die sich in Felder umwandeln lassen
function Get-HURemParamCandidates([string]$Code) {
    $out = @()
    if (-not "$Code".Trim()) { return $out }
    $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$err)
    if (@($err).Count -or $ast.ParamBlock -or -not $ast.EndBlock) { return $out }
    $have = @{}; foreach ($d in @(Get-HUQSParams $Code)) { $have[$d.Name.ToLower()] = $true }
    $lines = @("$Code" -split "`r?`n")
    foreach ($st in @($ast.EndBlock.Statements)) {
        if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
        if (-not ($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($st.Operator)" -eq 'Equals' -and $st.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { break }
        $vn = $st.Left.VariablePath.UserPath
        $r = $st.Right
        $e = $null
        if ($r -is [System.Management.Automation.Language.CommandExpressionAst]) { $e = $r.Expression }
        elseif ($r -is [System.Management.Automation.Language.PipelineAst] -and @($r.PipelineElements).Count -eq 1 -and $r.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $e = $r.PipelineElements[0].Expression }
        $type = $null; $val = $null
        if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst] -and "$($e.StringConstantType)" -in 'SingleQuoted', 'DoubleQuoted') { $type = 'string'; $val = $e.Value }
        elseif ($e -is [System.Management.Automation.Language.ConstantExpressionAst] -and $e.Value -is [int]) { $type = 'int'; $val = $e.Value }
        elseif ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.VariablePath.UserPath -in 'true', 'false') { $type = 'bool'; $val = ($e.VariablePath.UserPath -eq 'true') }
        if (-not $type) { break }
        $ln = $st.Extent.StartLineNumber
        if ($st.Extent.EndLineNumber -ne $ln -or $vn -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $have.ContainsKey($vn.ToLower())) { continue }
        # nur ganze Zeilen (ggf. mit Kommentar dahinter)
        $rest = $lines[$ln - 1].Substring([Math]::Min($lines[$ln - 1].Length, $st.Extent.EndColumnNumber - 1)).Trim()
        if ($rest -and -not $rest.StartsWith('#')) { continue }
        if ($lines[$ln - 1].Substring(0, $st.Extent.StartColumnNumber - 1).Trim()) { continue }
        $out += [pscustomobject]@{ Name = $vn; Type = $type; Value = $val; Line = $ln }
    }
    return $out
}

# Zuweisungen (Kandidaten) in @param-Feld + @value-Zeile umwandeln
function Convert-HURemAssignToParam([string]$Code, [string[]]$Names) {
    $cands = @(Get-HURemParamCandidates $Code | Where-Object { $Names -contains $_.Name })
    if (-not $cands.Count) { return $Code }
    $nl = if ($Code -match "`r`n") { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ("$Code" -split "`r?`n")) { $lines.Add($l) }
    foreach ($c in @($cands | Sort-Object Line -Descending)) {
        $indent = [regex]::Match($lines[$c.Line - 1], '^\s*').Value
        $p = [pscustomobject]@{ Name = $c.Name; Type = $c.Type; Label = $c.Name; Default = ''; Choices = @() }
        $lines[$c.Line - 1] = "$indent`$$($c.Name) = $(ConvertTo-HURemParamLiteral $p $c.Value)  # @value"
        $lines.Insert($c.Line - 1, "$indent# @param $($c.Name)|$($c.Type)|$($c.Name)|")
    }
    return ($lines -join $nl)
}
