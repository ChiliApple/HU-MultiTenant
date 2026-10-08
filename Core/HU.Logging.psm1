#Requires -Version 5.1

<#
.SYNOPSIS
    HU.Logging - GUI + File Logging für HU-MultiTenant.
.DESCRIPTION
    Farbiges Logging in WPF RichTextBox + File-Logging.
    Automatisches Token-Masking (CRITICAL: Token NIEMALS in Logs!).
    Log-Rotation bei maxFileSize.
    Max 500 Zeilen in GUI (Performance).
.NOTES
    Modul: HU.Logging.psm1
    Projekt: HU-MultiTenant
    Version: 1.0.0
#>

# ============================================================================
# MODUL-VARIABLEN
# ============================================================================

# Referenz auf die WPF RichTextBox (wird von Main.ps1 gesetzt)
$script:LogRichTextBox = $null

# Log-Buffer für History
$script:LogBuffer = [System.Collections.ArrayList]::new()

# Max Zeilen in GUI
$script:MaxGuiLogLines = 500

# Max Buffer-Einträge
$script:MaxBufferSize = 2000

# Aktuelle Log-Datei
$script:CurrentLogFile = $null

# Log-Level Hierarchie
$script:LogLevels = @{
    'DEBUG' = 0
    'INFO'  = 1
    'OK'    = 2
    'WARN'  = 3
    'ERROR' = 4
}

# Minimum Log-Level (default: INFO)
$script:MinLogLevel = 'INFO'

# Farb-Mapping für GUI
$script:LevelColors = @{
    'OK'    = '#4CAF50'   # Grün
    'WARN'  = '#FF9800'   # Orange
    'ERROR' = '#D32F2F'   # Rot
    'INFO'  = '#2196F3'   # Blau
    'DEBUG' = '#9E9E9E'   # Grau
}

# Symbol-Mapping
$script:LevelSymbols = @{
    'OK'    = [char]0x2713   # ✓
    'WARN'  = [char]0x26A0   # ⚠
    'ERROR' = [char]0x2717   # ✗
    'INFO'  = [char]0x2139   # ℹ
    'DEBUG' = [char]0x25CB   # ○
}

# Token-Pattern für Masking (Bearer Tokens, Client Secrets etc.)
$script:TokenPatterns = @(
    '(?i)(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'   # JWT
    '(?i)(Bearer\s+)[A-Za-z0-9_\-\.+/=]{20,}'                                  # Bearer Header
    '(?i)(client_secret[=:]\s*)[^\s&"'']{8,}'                                   # Client Secret in Body
    '(?i)(password[=:]\s*)[^\s&"'']{8,}'                                         # Password
    '(?i)([A-Za-z0-9]{8}~[A-Za-z0-9_\-\.]{30,})'                              # Azure Client Secret Format
)

# ============================================================================
# INITIALISIERUNG
# ============================================================================

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initialisiert das Logging-System.
    .PARAMETER LogFilePath
        Pfad zur Log-Datei. Platzhalter {date} wird durch aktuelles Datum ersetzt.
    .PARAMETER RichTextBox
        WPF RichTextBox-Referenz für GUI-Logging.
    .PARAMETER MinLevel
        Minimum Log-Level: DEBUG, INFO, OK, WARN, ERROR
    .PARAMETER MaxGuiLines
        Maximale Zeilen in der GUI RichTextBox.
    #>
    [CmdletBinding()]
    param(
        [string]$LogFilePath,

        [object]$RichTextBox,

        [ValidateSet('DEBUG', 'INFO', 'OK', 'WARN', 'ERROR')]
        [string]$MinLevel = 'INFO',

        [int]$MaxGuiLines = 500
    )

    process {
        # GUI-Referenz setzen
        if ($RichTextBox) {
            $script:LogRichTextBox = $RichTextBox
        }

        # Min-Level setzen
        $script:MinLogLevel = $MinLevel
        $script:MaxGuiLogLines = $MaxGuiLines

        # Log-Datei initialisieren
        if ($LogFilePath) {
            $resolvedPath = $LogFilePath -replace '\{date\}', (Get-Date -Format 'yyyy-MM-dd')
            $logDir = Split-Path -Path $resolvedPath -Parent
            if (-not (Test-Path $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            $script:CurrentLogFile = $resolvedPath
            Write-Verbose "[Logging] Log-Datei: $resolvedPath"
        }

        # Buffer leeren
        $script:LogBuffer.Clear()
    }
}

# ============================================================================
# TOKEN-MASKING
# ============================================================================

function Protect-LogMessage {
    <#
    .SYNOPSIS
        Maskiert sensitive Daten (Tokens, Secrets) in Log-Messages.
    .PARAMETER Message
        Die zu prüfende Nachricht.
    .OUTPUTS
        [string] Nachricht mit maskierten Token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    process {
        if ([string]::IsNullOrEmpty($Message)) { return $Message }

        $masked = $Message

        foreach ($pattern in $script:TokenPatterns) {
            $masked = [regex]::Replace($masked, $pattern, {
                param($m)
                $fullMatch = $m.Value
                $suffix = if ($fullMatch.Length -ge 5) { $fullMatch.Substring($fullMatch.Length - 5) } else { '****' }
                "[TOKEN_MASKED_$suffix]"
            })
        }

        return $masked
    }
}

# ============================================================================
# LOGGING-FUNKTIONEN
# ============================================================================

function Write-HULog {
    <#
    .SYNOPSIS
        Zentrale Log-Funktion – schreibt gleichzeitig in GUI und File.
    .PARAMETER Message
        Log-Nachricht
    .PARAMETER Level
        Log-Level: OK, WARN, ERROR, INFO, DEBUG
    .PARAMETER Tenant
        Optionaler Tenant-Name für Kontext
    .PARAMETER NoGui
        Nur in File loggen, nicht in GUI
    .PARAMETER NoFile
        Nur in GUI loggen, nicht in File
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('OK', 'WARN', 'ERROR', 'INFO', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$Tenant = '',

        [switch]$NoGui,
        [switch]$NoFile
    )

    process {
        # Level-Filter
        if ($script:LogLevels[$Level] -lt $script:LogLevels[$script:MinLogLevel]) {
            return
        }

        # Token-Masking anwenden
        $safeMessage = Protect-LogMessage -Message $Message

        # Timestamp
        $timestamp = Get-Date -Format 'HH:mm:ss'

        # Tenant-Part
        $tenantPart = if ($Tenant) { " [$Tenant]" } else { '' }

        # Symbol
        $symbol = $script:LevelSymbols[$Level]

        # Formatierte Zeile
        $formattedLine = "[$timestamp] $symbol [$Level]$tenantPart $safeMessage"

        # Buffer
        [void]$script:LogBuffer.Add([PSCustomObject]@{
            Timestamp = Get-Date
            Level     = $Level
            Tenant    = $Tenant
            Message   = $safeMessage
            Formatted = $formattedLine
        })

        # Buffer beschränken
        while ($script:LogBuffer.Count -gt $script:MaxBufferSize) {
            $script:LogBuffer.RemoveAt(0)
        }

        # GUI
        if (-not $NoGui) {
            Write-LogToGUI -FormattedLine $formattedLine -Level $Level
        }

        # File
        if (-not $NoFile -and $script:CurrentLogFile) {
            Write-LogToFile -FormattedLine $formattedLine
        }
    }
}

function Write-LogToGUI {
    <#
    .SYNOPSIS
        Schreibt eine formatierte Zeile in die WPF RichTextBox.
    .PARAMETER FormattedLine
        Bereits formatierte Log-Zeile
    .PARAMETER Level
        Log-Level für Farbgebung
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FormattedLine,

        [string]$Level = 'INFO'
    )

    process {
        if (-not $script:LogRichTextBox) { return }

        try {
            $color = $script:LevelColors[$Level]
            if (-not $color) { $color = '#CCCCCC' }

            # WPF Dispatcher verwenden falls nötig (UI-Thread)
            $action = {
                param($rtb, $line, $hexColor, $maxLines)

                $paragraph = New-Object System.Windows.Documents.Paragraph
                $run = New-Object System.Windows.Documents.Run($line)

                try {
                    $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hexColor)
                }
                catch {
                    $run.Foreground = [System.Windows.Media.Brushes]::White
                }

                $paragraph.Inlines.Add($run)
                $paragraph.Margin = [System.Windows.Thickness]::new(0)
                $paragraph.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
                $paragraph.FontSize = 11

                $rtb.Document.Blocks.Add($paragraph)

                # Max Zeilen einhalten
                while ($rtb.Document.Blocks.Count -gt $maxLines) {
                    $rtb.Document.Blocks.Remove($rtb.Document.Blocks.FirstBlock)
                }

                # Auto-Scroll
                $rtb.ScrollToEnd()
            }

            if ($script:LogRichTextBox.Dispatcher.CheckAccess()) {
                & $action $script:LogRichTextBox $FormattedLine $color $script:MaxGuiLogLines
            }
            else {
                $script:LogRichTextBox.Dispatcher.Invoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [System.Action[object, string, string, int]]$action,
                    $script:LogRichTextBox, $FormattedLine, $color, $script:MaxGuiLogLines
                )
            }
        }
        catch {
            # GUI-Logging darf nie Hauptprozess blockieren
            Write-Verbose "[Logging] GUI-Ausgabe fehlgeschlagen: $_"
        }
    }
}

function Write-LogToFile {
    <#
    .SYNOPSIS
        Schreibt eine formatierte Zeile in die Log-Datei.
    .PARAMETER FormattedLine
        Bereits formatierte Log-Zeile
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FormattedLine
    )

    process {
        if (-not $script:CurrentLogFile) { return }

        try {
            # Datei-Rotation prüfen (max 10 MB)
            if (Test-Path $script:CurrentLogFile) {
                $fileInfo = Get-Item $script:CurrentLogFile
                if ($fileInfo.Length -gt 10MB) {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentLogFile)
                    $ext = [System.IO.Path]::GetExtension($script:CurrentLogFile)
                    $dir = [System.IO.Path]::GetDirectoryName($script:CurrentLogFile)

                    # Nächste freie Versionsnummer finden
                    $version = 2
                    do {
                        $newPath = [System.IO.Path]::Combine($dir, "${baseName}_v${version}${ext}")
                        $version++
                    } while (Test-Path $newPath)

                    $script:CurrentLogFile = $newPath
                }
            }

            # Datumspräfix für File-Logging
            $fileLine = "[$(Get-Date -Format 'yyyy-MM-dd')] $FormattedLine"
            Add-Content -Path $script:CurrentLogFile -Value $fileLine -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Verbose "[Logging] File-Ausgabe fehlgeschlagen: $_"
        }
    }
}

# ============================================================================
# BUFFER & HISTORY
# ============================================================================

function Get-LogHistory {
    <#
    .SYNOPSIS
        Gibt den Log-Buffer zurück (optional gefiltert).
    .PARAMETER Level
        Filter nach Log-Level
    .PARAMETER Tenant
        Filter nach Tenant
    .PARAMETER Last
        Nur die letzten N Einträge
    .OUTPUTS
        [PSCustomObject[]] Log-Einträge
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [ValidateSet('OK', 'WARN', 'ERROR', 'INFO', 'DEBUG')]
        [string]$Level,

        [string]$Tenant,

        [int]$Last = 0
    )

    process {
        $result = $script:LogBuffer

        if ($Level) {
            $result = $result | Where-Object { $_.Level -eq $Level }
        }

        if ($Tenant) {
            $result = $result | Where-Object { $_.Tenant -eq $Tenant }
        }

        if ($Last -gt 0) {
            $result = $result | Select-Object -Last $Last
        }

        return @($result)
    }
}

function Clear-LogBuffer {
    <#
    .SYNOPSIS
        Leert den Log-Buffer und optional die GUI.
    .PARAMETER IncludeGui
        Auch die RichTextBox leeren.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeGui
    )

    process {
        $script:LogBuffer.Clear()

        if ($IncludeGui -and $script:LogRichTextBox) {
            try {
                if ($script:LogRichTextBox.Dispatcher.CheckAccess()) {
                    $script:LogRichTextBox.Document.Blocks.Clear()
                }
                else {
                    $script:LogRichTextBox.Dispatcher.Invoke(
                        [System.Windows.Threading.DispatcherPriority]::Background,
                        [System.Action]{ $script:LogRichTextBox.Document.Blocks.Clear() }
                    )
                }
            }
            catch {
                Write-Verbose "[Logging] GUI-Clear fehlgeschlagen: $_"
            }
        }
    }
}

function Get-CurrentLogFile {
    <#
    .SYNOPSIS
        Gibt den Pfad der aktuellen Log-Datei zurück.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    process {
        return $script:CurrentLogFile
    }
}

# ============================================================================
# CONVENIENCE-FUNKTIONEN
# ============================================================================

function Write-HULogOK {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant)
    Write-HULog -Message $Message -Level 'OK' -Tenant $Tenant
}

function Write-HULogWarn {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant)
    Write-HULog -Message $Message -Level 'WARN' -Tenant $Tenant
}

function Write-HULogError {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant)
    Write-HULog -Message $Message -Level 'ERROR' -Tenant $Tenant
}

function Write-HULogInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant)
    Write-HULog -Message $Message -Level 'INFO' -Tenant $Tenant
}

function Write-HULogDebug {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Message, [string]$Tenant)
    Write-HULog -Message $Message -Level 'DEBUG' -Tenant $Tenant
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function @(
    'Initialize-Logging'
    'Write-HULog'
    'Write-HULogOK'
    'Write-HULogWarn'
    'Write-HULogError'
    'Write-HULogInfo'
    'Write-HULogDebug'
    'Write-LogToGUI'
    'Write-LogToFile'
    'Protect-LogMessage'
    'Get-LogHistory'
    'Clear-LogBuffer'
    'Get-CurrentLogFile'
)
