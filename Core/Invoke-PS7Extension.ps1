# ============================================================================
# Invoke-PS7Extension.ps1 — Wrapper fuer Extension-Ausfuehrung in PowerShell 7
# ============================================================================
# Wird von Main.ps1 (PS 5.1) via Start-Process pwsh.exe aufgerufen.
# Laedt Core-Module, fuehrt die Extension aus, schreibt Result als JSON.
#
# Parameter (alle Mandatory):
#   -AppRoot       Projektverzeichnis (fuer Core-Module)
#   -ExtensionPath Pfad zum .ps1 Extension-Script
#   -TenantKey     Tenant-Key String
#   -Token         Graph API Access Token
#   -LogFile       Pfad zur gemeinsamen Log-Datei
#   -ResultFile    Pfad fuer JSON-Result (wird geschrieben)
#   -IsDryRun      Switch fuer DryRun-Modus
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AppRoot,

    [Parameter(Mandatory)]
    [string]$ExtensionPath,

    [Parameter(Mandatory)]
    [string]$TenantKey,

    [Parameter(Mandatory)]
    [string]$Token,

    [Parameter(Mandatory)]
    [string]$LogFile,

    [Parameter(Mandatory)]
    [string]$ResultFile,

    [switch]$IsDryRun,

    [string]$CustomParamsFile = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 1. CORE-MODULE LADEN
# ============================================================================

$coreModules = @('HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Extensions', 'HU.Excel')
foreach ($mod in $coreModules) {
    $modPath = Join-Path $AppRoot "Core\$mod.psm1"
    if (Test-Path $modPath) {
        try {
            Import-Module $modPath -Force -DisableNameChecking -ErrorAction Stop
        }
        catch {
            # HU.Excel ist optional, Rest ist kritisch
            if ($mod -ne 'HU.Excel') {
                $errResult = [PSCustomObject]@{
                    Success      = $false
                    ErrorMessage = "Modul $mod nicht ladbar: $($_.Exception.Message)"
                    Duration     = [TimeSpan]::Zero
                }
                $errResult | ConvertTo-Json -Depth 5 | Set-Content -Path $ResultFile -Encoding UTF8
                exit 1
            }
        }
    }
}

# ============================================================================
# 2. LOGGING INITIALISIEREN (gleiche Datei wie Main.ps1 GUI-Polling)
# ============================================================================

try {
    Initialize-Logging -LogFilePath $LogFile -MinLevel 'DEBUG'
}
catch {
    Write-Warning "Logging init failed: $($_.Exception.Message)"
}

# ============================================================================
# 3. EXTENSION LADEN + AUSFUEHREN
# ============================================================================

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    # Extension dot-sourcen
    if (-not (Test-Path $ExtensionPath)) {
        throw "Extension script not found: $ExtensionPath"
    }

    . $ExtensionPath

    # Invoke-* Funktion finden (Convention: genau eine pro Extension)
    $mainFunction = Get-Command -Name 'Invoke-*' -CommandType Function -ErrorAction SilentlyContinue |
        Where-Object { $_.ScriptBlock.File -eq $ExtensionPath } |
        Select-Object -First 1

    if (-not $mainFunction) {
        throw "No Invoke-* entry function found in extension."
    }

    # Parameter zusammenbauen
    $invokeParams = @{
        TenantKey = $TenantKey
        Token     = $Token
    }
    if ($IsDryRun) {
        $invokeParams['WhatIf'] = $true
    }

    # Custom Parameters laden (aus JSON Temp-Datei)
    if ($CustomParamsFile -and (Test-Path $CustomParamsFile)) {
        try {
            $cpJson = Get-Content -Path $CustomParamsFile -Raw -Encoding UTF8
            $cpHash = $cpJson | ConvertFrom-Json
            $funcParams = $mainFunction.Parameters
            foreach ($prop in $cpHash.PSObject.Properties) {
                if ($funcParams.ContainsKey($prop.Name)) {
                    $invokeParams[$prop.Name] = $prop.Value
                }
            }
            # Cleanup temp file
            Remove-Item -Path $CustomParamsFile -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-HULog -Message "Parameter nicht lesbar: $($_.Exception.Message)" -Level 'WARN' -Tenant $TenantKey
        }
    }

    # Ausfuehren
    $output = & $mainFunction.Name @invokeParams

    $stopwatch.Stop()

    $result = [PSCustomObject]@{
        Success       = $true
        Output        = $output
        ErrorMessage  = ''
        Duration      = $stopwatch.Elapsed
        ExtensionName = [System.IO.Path]::GetFileNameWithoutExtension($ExtensionPath)
        WasDryRun     = $IsDryRun.IsPresent
        Runtime       = 'PS7'
    }
}
catch {
    $stopwatch.Stop()

    $errLine = ''
    $errCmd  = ''
    if ($_.InvocationInfo.ScriptLineNumber) {
        $errLine = " (line $($_.InvocationInfo.ScriptLineNumber))"
    }
    if ($_.InvocationInfo.Line) {
        $errCmd = " | Code: $($_.InvocationInfo.Line.Trim())"
    }

    $errMsg = "$($_.Exception.Message)${errLine}${errCmd}"

    try {
        Write-HULog -Message "PS7-Extension fehlgeschlagen: $errMsg" -Level 'ERROR' -Tenant $TenantKey
    }
    catch { }

    $result = [PSCustomObject]@{
        Success       = $false
        Output        = $null
        ErrorMessage  = $errMsg
        Duration      = $stopwatch.Elapsed
        ExtensionName = [System.IO.Path]::GetFileNameWithoutExtension($ExtensionPath)
        WasDryRun     = $IsDryRun.IsPresent
        Runtime       = 'PS7'
    }
}

# ============================================================================
# 4. RESULT ALS JSON SCHREIBEN
# ============================================================================

try {
    $result | ConvertTo-Json -Depth 10 | Set-Content -Path $ResultFile -Encoding UTF8
}
catch {
    # Fallback: minimal result
    $fallback = @{ Success = $false; ErrorMessage = $_.Exception.Message }
    $fallback | ConvertTo-Json | Set-Content -Path $ResultFile -Encoding UTF8
}

# Exit-Code: 0 = OK, 1 = Fehler
if ($result.Success) { exit 0 } else { exit 1 }
