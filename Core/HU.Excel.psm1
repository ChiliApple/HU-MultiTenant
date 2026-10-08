# ============================================================================
# HU.Excel.psm1 — Zentrale Excel-Formatierung fuer HU-MultiTenant Reports
# ============================================================================
# Verwendet ImportExcel-Modul (EPPlus, kein Office noetig).
# Stellt einheitliches Design fuer ALLE Reports sicher.
#
# WICHTIG PS 5.1:
#   - KEIN 4-Parameter-Indexer: $ws.Cells[$r1,$c1,$r2,$c2] ist VERBOTEN
#     (PS 5.1 interpretiert Kommas als Array-Elemente, nicht als Indexer-Params)
#   - Stattdessen IMMER String-Adressen: $ws.Cells["A1:F10"]
#   - Alle Arithmetik in [int]-Variablen VOR dem Cells-Zugriff
# ============================================================================

# ============================================================================
# MODUL-INITIALISIERUNG
# ============================================================================

$script:ImportExcelAvailable = $false

function Initialize-HUExcel {
    <#
    .SYNOPSIS
        Prueft ob ImportExcel verfuegbar ist, installiert bei Bedarf.
    .OUTPUTS
        [bool] $true wenn ImportExcel bereit
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    process {
        if ($script:ImportExcelAvailable) { return $true }

        $mod = Get-Module -Name ImportExcel -ErrorAction SilentlyContinue
        if ($mod) {
            $script:ImportExcelAvailable = $true
            return $true
        }

        $installed = Get-Module -Name ImportExcel -ListAvailable -ErrorAction SilentlyContinue
        if ($installed) {
            Import-Module ImportExcel -Force -DisableNameChecking
            $script:ImportExcelAvailable = $true
            return $true
        }

        try {
            Write-Verbose 'ImportExcel nicht gefunden — installiere...'
            Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Import-Module ImportExcel -Force -DisableNameChecking
            $script:ImportExcelAvailable = $true
            return $true
        }
        catch {
            Write-Warning "ImportExcel konnte nicht installiert werden: $($_.Exception.Message)"
            return $false
        }
    }
}

# ============================================================================
# HELPER: Spalten-Nummer → Excel-Buchstabe (1=A, 26=Z, 27=AA, ...)
# ============================================================================

function ConvertTo-ExcelColumnLetter {
    param([int]$ColumnNumber)
    $letter = ''
    while ($ColumnNumber -gt 0) {
        $mod = ($ColumnNumber - 1) % 26
        $letter = [string][char](65 + $mod) + $letter
        $ColumnNumber = [math]::Floor(($ColumnNumber - 1) / 26)
    }
    return $letter
}

# HELPER: Erzeugt Excel-Adresse "A1" oder "A1:F10" aus Zeile/Spalte
function Get-ExcelAddress {
    param(
        [int]$Row1,
        [int]$Col1,
        [int]$Row2 = 0,
        [int]$Col2 = 0
    )
    $c1 = ConvertTo-ExcelColumnLetter -ColumnNumber $Col1
    if ($Row2 -gt 0 -and $Col2 -gt 0) {
        $c2 = ConvertTo-ExcelColumnLetter -ColumnNumber $Col2
        return "${c1}${Row1}:${c2}${Row2}"
    }
    return "${c1}${Row1}"
}

# ============================================================================
# DESIGN-KONSTANTEN
# ============================================================================

$script:HUDesign = @{
    # Header
    HeaderBgColor      = '#1F4E79'
    HeaderFontColor    = '#FFFFFF'
    HeaderFontName     = 'Calibri'
    HeaderFontSize     = 11
    HeaderFontBold     = $true

    # Daten
    DataFontName       = 'Calibri'
    DataFontSize       = 11
    AltRowColor        = '#F2F2F2'

    # Conditional Formatting
    CriticalBgColor    = '#FF0000'
    CriticalFontColor  = '#FFFFFF'
    WarningBgColor     = '#FFC000'
    WarningFontColor   = '#000000'
    OkBgColor          = '#70AD47'
    OkFontColor        = '#000000'

    # Spaltenbreiten
    ColWidthMin        = 12
    ColWidthMax        = 50
    PrimaryColWidth    = 25
    DateColWidth       = 18
    StatusColWidth     = 15

    # Dashboard
    DashboardBgColor   = '#1B2A4A'
    KpiBoxHeight       = 3
    KpiBoxWidth        = 2
}

# Woerter fuer Conditional Formatting
$script:CriticalWords = @('Critical', 'Kritisch', 'Cleanup-Gefahr', 'ERROR', 'Fehler', 'Deaktiviert', 'Non-Compliant', 'noncompliant', 'nicht konform')
$script:WarningWords  = @('Warning', 'Warnung', 'Pending', 'PendingRestart', 'Ueberfaellig', 'Nein', 'unknown')
$script:OkWords       = @('Clean', 'OK', 'Compliant', 'compliant', 'Aktiviert', 'Ja', 'secured')

# ============================================================================
# FORMAT-HUEXCELWORKBOOK
# ============================================================================

function Format-HUExcelWorkbook {
    <#
    .SYNOPSIS
        Wendet das HU-Standard-Design auf ein Excel-Workbook an.
    .PARAMETER WorkbookPath
        Pfad zur .xlsx Datei
    .PARAMETER PrimaryKeyColumn
        Name der Primaer-Spalte (breitere Anzeige). Default: erste Spalte.
    .PARAMETER SheetNames
        Optional: nur bestimmte Sheets formatieren. Default: alle.
    .PARAMETER ConditionalColumns
        Optional: Spalten-Namen fuer Conditional Formatting (Status-Spalten).
    .PARAMETER SkipSheets
        Optional: Sheet-Namen die uebersprungen werden sollen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [string]$PrimaryKeyColumn,

        [string[]]$SheetNames,

        [string[]]$ConditionalColumns,

        [string[]]$SkipSheets = @('Dashboard')
    )

    process {
        if (-not (Test-Path $WorkbookPath)) {
            Write-Warning "Workbook nicht gefunden: $WorkbookPath"
            return
        }

        $pkg = Open-ExcelPackage -Path $WorkbookPath

        try {
            $sheetsToFormat = if ($SheetNames -and $SheetNames.Count -gt 0) {
                $pkg.Workbook.Worksheets | Where-Object { $SheetNames -contains $_.Name }
            } else {
                $pkg.Workbook.Worksheets | Where-Object { $SkipSheets -notcontains $_.Name }
            }

            foreach ($ws in $sheetsToFormat) {
                if ($null -eq $ws.Dimension) { continue }

                [int]$startRow = $ws.Dimension.Start.Row
                [int]$endRow   = $ws.Dimension.End.Row
                [int]$startCol = $ws.Dimension.Start.Column
                [int]$endCol   = $ws.Dimension.End.Column

                if ($endRow -lt 1 -or $endCol -lt 1) { continue }

                # --- 1. Header-Row Formatting ---
                for ([int]$col = $startCol; $col -le $endCol; $col++) {
                    $addr = Get-ExcelAddress -Row1 $startRow -Col1 $col
                    $cell = $ws.Cells[$addr]
                    $cell.Style.Font.Bold           = $true
                    $cell.Style.Font.Name            = $script:HUDesign.HeaderFontName
                    $cell.Style.Font.Size            = $script:HUDesign.HeaderFontSize
                    $cell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.HeaderFontColor))
                    $cell.Style.Fill.PatternType     = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                    $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.HeaderBgColor))
                    $cell.Style.HorizontalAlignment  = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
                    $cell.Style.VerticalAlignment    = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center
                    $cell.Style.Border.Bottom.Style  = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
                }

                # --- 2. AutoFilter via Table ---
                try {
                    if ($ws.Tables.Count -eq 0) {
                        $rangeAddr = Get-ExcelAddress -Row1 $startRow -Col1 $startCol -Row2 $endRow -Col2 $endCol
                        $tableName = "Table_$($ws.Name -replace '[^a-zA-Z0-9]','')"
                        $table = $ws.Tables.Add($ws.Cells[$rangeAddr], $tableName)
                        $table.TableStyle = [OfficeOpenXml.Table.TableStyles]::None
                        $table.ShowFilter = $true
                    }
                } catch {
                    try { $ws.Cells[$ws.Dimension.Address].AutoFilter = $true } catch { }
                }

                # --- 3. Freeze Panes (Header-Zeile fixieren) ---
                $ws.View.FreezePanes(2, 1)

                # --- 4. Alternating Row Colors + Data Font ---
                for ([int]$row = ($startRow + 1); $row -le $endRow; $row++) {
                    [bool]$isEven = (($row - $startRow) % 2 -eq 0)

                    for ([int]$col = $startCol; $col -le $endCol; $col++) {
                        $addr = Get-ExcelAddress -Row1 $row -Col1 $col
                        $cell = $ws.Cells[$addr]

                        # Daten-Font
                        $cell.Style.Font.Name = $script:HUDesign.DataFontName
                        $cell.Style.Font.Size = $script:HUDesign.DataFontSize

                        # Alternating Rows
                        if ($isEven -and $cell.Style.Fill.PatternType -eq [OfficeOpenXml.Style.ExcelFillStyle]::None) {
                            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.AltRowColor))
                        }
                    }
                }

                # --- 5. AutoFit Column Widths (mit Min/Max) ---
                $headerNames = @{}
                for ([int]$col = $startCol; $col -le $endCol; $col++) {
                    $addr = Get-ExcelAddress -Row1 $startRow -Col1 $col
                    $headerVal = $ws.Cells[$addr].Text
                    $headerNames[$col] = $headerVal

                    $ws.Column($col).AutoFit()
                    $currentWidth = $ws.Column($col).Width

                    [double]$minW = $script:HUDesign.ColWidthMin
                    [double]$maxW = $script:HUDesign.ColWidthMax

                    if ($PrimaryKeyColumn -and $headerVal -eq $PrimaryKeyColumn) {
                        $minW = $script:HUDesign.PrimaryColWidth
                    }
                    if ($headerVal -match 'Date|Sync|Scan|Zeit') {
                        $minW = $script:HUDesign.DateColWidth
                    }
                    if ($headerVal -match 'Status|State|Compliance|Defender') {
                        $minW = $script:HUDesign.StatusColWidth
                    }

                    if ($currentWidth -lt $minW) { $ws.Column($col).Width = $minW }
                    if ($currentWidth -gt $maxW) { $ws.Column($col).Width = $maxW }
                }

                # --- 6. Conditional Formatting ---
                $condCols = @()
                if ($ConditionalColumns -and $ConditionalColumns.Count -gt 0) {
                    for ([int]$col = $startCol; $col -le $endCol; $col++) {
                        if ($ConditionalColumns -contains $headerNames[$col]) {
                            $condCols += $col
                        }
                    }
                } else {
                    for ([int]$col = $startCol; $col -le $endCol; $col++) {
                        $h = $headerNames[$col]
                        if ($h -match 'Status|State|Compliance|Defender|Threat|Malware|Signatur|Echtzeitschutz|Manipulationsschutz|ProductStatus|MalwareFound') {
                            $condCols += $col
                        }
                    }
                }

                foreach ($col in $condCols) {
                    for ([int]$row = ($startRow + 1); $row -le $endRow; $row++) {
                        $addr = Get-ExcelAddress -Row1 $row -Col1 $col
                        $cellValue = [string]$ws.Cells[$addr].Text

                        $isCritical = $false
                        $isWarning  = $false
                        $isOk       = $false

                        foreach ($w in $script:CriticalWords) {
                            if ($cellValue -eq $w -or $cellValue -like "*$w*") { $isCritical = $true; break }
                        }
                        if (-not $isCritical) {
                            foreach ($w in $script:OkWords) {
                                if ($cellValue -eq $w) { $isOk = $true; break }
                            }
                        }
                        if (-not $isCritical -and -not $isOk) {
                            foreach ($w in $script:WarningWords) {
                                if ($cellValue -eq $w -or $cellValue -like "*$w*") { $isWarning = $true; break }
                            }
                        }

                        $cell = $ws.Cells[$addr]
                        if ($isCritical) {
                            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.CriticalBgColor))
                            $cell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.CriticalFontColor))
                        }
                        elseif ($isWarning) {
                            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.WarningBgColor))
                            $cell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.WarningFontColor))
                        }
                        elseif ($isOk) {
                            $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                            $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.OkBgColor))
                            $cell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($script:HUDesign.OkFontColor))
                        }
                    }
                }
            }

            Close-ExcelPackage $pkg
        }
        catch {
            try { Close-ExcelPackage $pkg -NoSave } catch { }
            throw
        }
    }
}

# ============================================================================
# ADD-HUEXCELDASHBOARD
# ============================================================================

function Add-HUExcelDashboard {
    <#
    .SYNOPSIS
        Fuegt ein Dashboard-Sheet mit KPIs und Sheet-Links hinzu.
    .PARAMETER WorkbookPath
        Pfad zur .xlsx Datei
    .PARAMETER TenantKey
        Tenant-Name fuer Titel
    .PARAMETER ReportTitle
        Report-Titel
    .PARAMETER Metrics
        [ordered] Hashtable mit KPI-Name → Wert.
    .PARAMETER SheetDataSources
        Array von @{ SheetName; RowCount; Description } fuer Hyperlinks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [string]$TenantKey,

        [string]$ReportTitle = 'Report',

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Metrics,

        [hashtable[]]$SheetDataSources
    )

    process {
        $pkg = Open-ExcelPackage -Path $WorkbookPath

        try {
            $wsDash = $pkg.Workbook.Worksheets.Add('Dashboard')
            $pkg.Workbook.Worksheets.MoveToStart('Dashboard')
            $wsDash.View.ShowGridLines = $false

            # --- Dashboard-Hintergrund: helles Grau fuer gesamten sichtbaren Bereich ---
            $bgColor = [System.Drawing.ColorTranslator]::FromHtml('#F0F2F5')
            $bgAddr = Get-ExcelAddress -Row1 1 -Col1 1 -Row2 40 -Col2 10
            $bgRange = $wsDash.Cells[$bgAddr]
            $bgRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $bgRange.Style.Fill.BackgroundColor.SetColor($bgColor)

            # --- Titel-Bar (Zeile 1, dunkelblauer Balken) ---
            $titleBarAddr = Get-ExcelAddress -Row1 1 -Col1 1 -Row2 1 -Col2 8
            $titleBar = $wsDash.Cells[$titleBarAddr]
            $titleBar.Merge = $true
            $titleBar.Value = "$ReportTitle - $TenantKey"
            $titleBar.Style.Font.Size = 16
            $titleBar.Style.Font.Bold = $true
            $titleBar.Style.Font.Name = 'Calibri'
            $titleBar.Style.Font.Color.SetColor([System.Drawing.Color]::White)
            $titleBar.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $titleBar.Style.Fill.BackgroundColor.SetColor([System.Drawing.ColorTranslator]::FromHtml('#1F4E79'))
            $titleBar.Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center
            $wsDash.Row(1).Height = 36

            # Datum (Zeile 2)
            $dateAddr = Get-ExcelAddress -Row1 2 -Col1 1 -Row2 2 -Col2 6
            $dateRange = $wsDash.Cells[$dateAddr]
            $dateRange.Merge = $true
            $dateRange.Value = "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            $dateRange.Style.Font.Italic = $true
            $dateRange.Style.Font.Size = 10
            $dateRange.Style.Font.Name = 'Calibri'
            $dateRange.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#666666'))

            # --- KPI-Boxes ---
            [int]$row = 4
            [int]$col = 1
            [int]$kpiIndex = 0
            [int]$maxPerRow = 3

            foreach ($kpiName in $Metrics.Keys) {
                $kpiValue = $Metrics[$kpiName]

                [int]$boxRow = $row
                [int]$boxCol = $col
                [int]$boxColEnd = $col + 1

                # --- Wert-Zelle (weisse Karte mit farbigem linken Rand) ---
                $valAddr = Get-ExcelAddress -Row1 $boxRow -Col1 $boxCol -Row2 $boxRow -Col2 $boxColEnd
                $valCell = $wsDash.Cells[$valAddr]
                $valCell.Merge = $true
                $valCell.Value = $kpiValue
                $valCell.Style.Font.Size = 26
                $valCell.Style.Font.Bold = $true
                $valCell.Style.Font.Name = 'Calibri'
                $valCell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
                $valCell.Style.VerticalAlignment   = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Center

                # Weisse Karte als Hintergrund
                $valCell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $valCell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::White)

                # Farbe fuer Akzent-Rand links + Schriftfarbe basierend auf KPI-Name
                $accentColor = '#1F4E79'
                $fontColor = '#1F4E79'
                if ($kpiName -match 'Critical|Kritisch|Cleanup|Fehler|Error|Deaktiviert|Non-Compliant|nicht konform') {
                    $accentColor = '#C00000'; $fontColor = '#C00000'
                }
                elseif ($kpiName -match 'Warning|Warnung|Pending|Ueberfaellig|abgelaufen|veraltet|Malware') {
                    $accentColor = '#E6820E'; $fontColor = '#E6820E'
                }
                elseif ($kpiName -match 'Compliant$|^Compliant|OK|Clean|secured') {
                    $accentColor = '#2E7D32'; $fontColor = '#2E7D32'
                }

                $valCell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($fontColor))

                # Farbiger linker Rand als Akzent
                $leftBorderAddr = Get-ExcelAddress -Row1 $boxRow -Col1 $boxCol
                $wsDash.Cells[$leftBorderAddr].Style.Border.Left.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thick
                $wsDash.Cells[$leftBorderAddr].Style.Border.Left.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($accentColor))

                # Dezente Umrandung
                $valCell.Style.Border.Top.Style    = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
                $valCell.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::None
                $valCell.Style.Border.Top.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#DCDCDC'))

                # --- Label-Zelle (darunter, gleiche weisse Karte) ---
                [int]$lblRow = $boxRow + 1
                $lblAddr = Get-ExcelAddress -Row1 $lblRow -Col1 $boxCol -Row2 $lblRow -Col2 $boxColEnd
                $lblCell = $wsDash.Cells[$lblAddr]
                $lblCell.Merge = $true
                $lblCell.Value = $kpiName
                $lblCell.Style.Font.Size = 9
                $lblCell.Style.Font.Name = 'Calibri'
                $lblCell.Style.Font.Bold = $true
                $lblCell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
                $lblCell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#555555'))
                $lblCell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
                $lblCell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::White)
                $lblCell.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
                $lblCell.Style.Border.Bottom.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#DCDCDC'))

                # Linker Akzent-Rand auch auf Label
                $leftLblAddr = Get-ExcelAddress -Row1 $lblRow -Col1 $boxCol
                $wsDash.Cells[$leftLblAddr].Style.Border.Left.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thick
                $wsDash.Cells[$leftLblAddr].Style.Border.Left.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml($accentColor))

                $kpiIndex++
                $col = $col + 3

                if ($kpiIndex % $maxPerRow -eq 0) {
                    $row = $row + 3
                    $col = 1
                }
            }

            if ($kpiIndex % $maxPerRow -ne 0) {
                $row = $row + 3
            }

            # --- Sheet-Links (in weisser Box) ---
            if ($SheetDataSources -and $SheetDataSources.Count -gt 0) {
                $row = $row + 1
                $linkHeaderAddr = Get-ExcelAddress -Row1 $row -Col1 1
                $wsDash.Cells[$linkHeaderAddr].Value = 'Detail-Sheets:'
                $wsDash.Cells[$linkHeaderAddr].Style.Font.Bold = $true
                $wsDash.Cells[$linkHeaderAddr].Style.Font.Size = 11
                $wsDash.Cells[$linkHeaderAddr].Style.Font.Name = 'Calibri'
                $wsDash.Cells[$linkHeaderAddr].Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#333333'))
                $row = $row + 1

                foreach ($src in $SheetDataSources) {
                    $linkText = "$($src.SheetName) ($($src.RowCount) Eintraege)"
                    if ($src.Description) {
                        $linkText = $linkText + " - $($src.Description)"
                    }

                    $linkAddr = Get-ExcelAddress -Row1 $row -Col1 1
                    $linkCell = $wsDash.Cells[$linkAddr]
                    $linkCell.Value = $linkText
                    $linkCell.Style.Font.UnderLine = $true
                    $linkCell.Style.Font.Size = 10
                    $linkCell.Style.Font.Color.SetColor([System.Drawing.ColorTranslator]::FromHtml('#1F4E79'))

                    try {
                        $safeSheetName = $src.SheetName -replace "'", "''"
                        $linkCell.Hyperlink = [System.Uri]::new("#'$safeSheetName'!A1", [System.UriKind]::Relative)
                    } catch { }

                    $row = $row + 1
                }
            }

            # Spaltenbreiten
            for ([int]$c = 1; $c -le 8; $c++) {
                $wsDash.Column($c).Width = 18
            }

            Close-ExcelPackage $pkg
        }
        catch {
            try { Close-ExcelPackage $pkg -NoSave } catch { }
            throw
        }
    }
}

# ============================================================================
# SET-HUEXCELCOLUMNGROUPING
# ============================================================================

function Set-HUExcelColumnGrouping {
    <#
    .SYNOPSIS
        Fuegt visuelle Spalten-Gruppierung hinzu (vertikale Trennlinien).
    .PARAMETER WorkbookPath
        Pfad zur .xlsx Datei
    .PARAMETER GroupDefinitions
        Array von @{ Title; Columns = @('Col1', 'Col2') }
    .PARAMETER SheetNames
        Optional: nur bestimmte Sheets. Default: alle ausser Dashboard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [hashtable[]]$GroupDefinitions,

        [string[]]$SheetNames,

        [string[]]$SkipSheets = @('Dashboard')
    )

    process {
        $pkg = Open-ExcelPackage -Path $WorkbookPath

        try {
            $sheets = if ($SheetNames -and $SheetNames.Count -gt 0) {
                $pkg.Workbook.Worksheets | Where-Object { $SheetNames -contains $_.Name }
            } else {
                $pkg.Workbook.Worksheets | Where-Object { $SkipSheets -notcontains $_.Name }
            }

            foreach ($ws in $sheets) {
                if ($null -eq $ws.Dimension) { continue }

                [int]$startRow = $ws.Dimension.Start.Row
                [int]$endRow   = $ws.Dimension.End.Row
                [int]$startCol = $ws.Dimension.Start.Column
                [int]$endCol   = $ws.Dimension.End.Column

                # Header-Namen zu Spalten-Nummern mappen
                $headerMap = @{}
                for ([int]$col = $startCol; $col -le $endCol; $col++) {
                    $addr = Get-ExcelAddress -Row1 $startRow -Col1 $col
                    $headerMap[$ws.Cells[$addr].Text] = $col
                }

                foreach ($grp in $GroupDefinitions) {
                    [int]$lastColInGroup = 0
                    foreach ($colName in $grp.Columns) {
                        if ($headerMap.ContainsKey($colName)) {
                            [int]$colNum = $headerMap[$colName]
                            if ($colNum -gt $lastColInGroup) {
                                $lastColInGroup = $colNum
                            }
                        }
                    }

                    if ($lastColInGroup -gt 0 -and $lastColInGroup -lt $endCol) {
                        for ([int]$row = $startRow; $row -le $endRow; $row++) {
                            $addr = Get-ExcelAddress -Row1 $row -Col1 $lastColInGroup
                            $ws.Cells[$addr].Style.Border.Right.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Medium
                            $ws.Cells[$addr].Style.Border.Right.Color.SetColor([System.Drawing.Color]::FromArgb(100, 100, 100))
                        }
                    }
                }
            }

            Close-ExcelPackage $pkg
        }
        catch {
            try { Close-ExcelPackage $pkg -NoSave } catch { }
            throw
        }
    }
}

# ============================================================================
# HILFSFUNKTIONEN
# ============================================================================

function New-HUExcelReport {
    <#
    .SYNOPSIS
        Erstellt einen neuen Excel-Report mit Daten und Standard-Formatierung.
    .PARAMETER Data
        Array von PSCustomObject (Datenzeilen)
    .PARAMETER SheetName
        Name des Datenblatts
    .PARAMETER ReportPath
        Ziel-Pfad fuer die .xlsx Datei
    .PARAMETER PrimaryKeyColumn
        Name der Primaer-Spalte (breitere Anzeige)
    .PARAMETER ConditionalColumns
        Spalten fuer Conditional Formatting
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Data,

        [string]$SheetName = 'Data',

        [Parameter(Mandatory)]
        [string]$ReportPath,

        [string]$PrimaryKeyColumn,

        [string[]]$ConditionalColumns
    )

    process {
        $Data | Export-Excel -Path $ReportPath -WorksheetName $SheetName `
            -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -ClearSheet

        Format-HUExcelWorkbook -WorkbookPath $ReportPath `
            -PrimaryKeyColumn $PrimaryKeyColumn `
            -ConditionalColumns $ConditionalColumns

        return $ReportPath
    }
}

function Add-HUExcelSheet {
    <#
    .SYNOPSIS
        Fuegt ein weiteres Daten-Sheet zu einem bestehenden Workbook hinzu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Data,

        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [string]$SheetName = 'Sheet2'
    )

    process {
        $Data | Export-Excel -Path $WorkbookPath -WorksheetName $SheetName `
            -AutoSize -FreezeTopRow -BoldTopRow -NoNumberConversion * -Append
    }
}

function Set-HUExcelFreezePanes {
    <#
    .SYNOPSIS
        Setzt Freeze Panes fuer ein bestimmtes Sheet (Zeilen + Spalten).
    .PARAMETER FreezeRow
        Erste nicht-fixierte Zeile (2 = Header fixiert)
    .PARAMETER FreezeColumn
        Erste nicht-fixierte Spalte (4 = Spalten A-C fixiert)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [string]$SheetName,

        [int]$FreezeRow = 2,
        [int]$FreezeColumn = 1
    )

    process {
        $pkg = Open-ExcelPackage -Path $WorkbookPath
        try {
            $ws = $pkg.Workbook.Worksheets[$SheetName]
            if ($ws) {
                $ws.View.FreezePanes($FreezeRow, $FreezeColumn)
            }
            Close-ExcelPackage $pkg
        }
        catch {
            try { Close-ExcelPackage $pkg -NoSave } catch { }
            throw
        }
    }
}

# ============================================================================
# MODULE EXPORTS
# ============================================================================

Export-ModuleMember -Function @(
    'Initialize-HUExcel'
    'Format-HUExcelWorkbook'
    'Add-HUExcelDashboard'
    'Set-HUExcelColumnGrouping'
    'New-HUExcelReport'
    'Add-HUExcelSheet'
    'Set-HUExcelFreezePanes'
)
