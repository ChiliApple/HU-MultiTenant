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
