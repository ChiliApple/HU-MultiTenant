#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter Extensions: Liste, Details, Parameter, Ausfuehren (PS5-Runspace oder PS7-Prozess), Abbrechen, Protokoll,
    Berechtigungs-Assistent (Setup Guide).
.NOTES
    Aus Main.ps1 (v1.3) uebernommen. Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:SelectedExtension = $null
$script:IsRunning = $false
$script:CancelRequested = $false
$script:BgIsPS7 = $false
$script:BgProcess = $null
$script:BgResultFile = $null
$script:BgPowerShell = $null
$script:BgAsyncResult = $null
$script:BgRunspace = $null
$script:CustomParamControls = @{}
$script:ExtensionItems = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()

# Extensions, die nicht mehr mitgeliefert werden: unveraenderte Kopien (gleiche Pruefsumme wie ausgeliefert)
# werden beim Start entfernt - Pull.ps1 laesst Dateien, die es im Repository nicht mehr gibt, liegen.
# Selbst geaenderte Dateien (andere Pruefsumme) bleiben unangetastet.
$script:RetiredExtensions = @{
    'Extensions\Device\Device-AllDevicesReport.ps1'           = 'a403cbc907f28cd0ff67a622d62c77aacfd6e1734187aa268180f6aa6eed0302'
    'Extensions\Device\Device-StaleDevicesReport.ps1'         = '531a28586b8f5d89f53de904a0c64c02e4a0642dcedbdd9e38d693b0a12eb4c1'
    'Extensions\Device\Device-SyncStatusExport.ps1'           = '055acce83123a6fbb231387532fd968b52e3941d41ed37e86a94975e8ba6f0d3'
    'Extensions\Security\Security-AllDevicesReport.ps1'       = '6ca8592bdc78acaffec796aa67c51baafb2c88b3bea5e3b2223c90b80d5a8cb7'
    'Extensions\Security\Security-AppAssignmentAudit.ps1'     = 'a040a5da4754fe7b273c4b20c9ca7d139a15ad375837c18b4d4cc836197e2fc0'
    'Extensions\Common\Common-TenantHealthDashboard.ps1'      = 'efd0e5ff7bd265cfbc48504b74fedb820e10eec6c638f501ef780c34f04556c3'
}
$script:RetiredChecked = $false

function Remove-HURetiredExtensions {
    if ($script:RetiredChecked) { return }
    $script:RetiredChecked = $true
    foreach ($rel in $script:RetiredExtensions.Keys) {
        $f = Join-Path $script:AppRoot $rel
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
            if ($h -eq $script:RetiredExtensions[$rel]) {
                Remove-Item -LiteralPath $f -Force -ErrorAction Stop
                Write-HULogInfo "Nicht mehr mitgelieferte Extension entfernt: $rel"
                $dir = Split-Path $f -Parent
                if (-not @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
            }
        } catch { Write-HULogDebug "Extension ${rel}: $($_.Exception.Message)" }
    }
}

function Load-Extensions {
    Remove-HURetiredExtensions
    $extensions = Get-AllExtensions -ForceRescan
    $script:ExtensionItems.Clear()

    foreach ($ext in $extensions) {
        $item = [PSCustomObject]@{
            Name           = $ext.Name
            Category       = "[$($ext.Category)]"
            Synopsis       = $ext.Synopsis
            DryRunVisible  = if ($ext.DryRunCapable) { 'Visible' } else { 'Collapsed' }
            BatchVisible   = if ($ext.BatchCapable) { 'Visible' } else { 'Collapsed' }
            WriteVisible   = if ("$($ext.Mode)" -eq 'ReadWrite') { 'Visible' } else { 'Collapsed' }
            ExtensionObj   = $ext
        }
        $script:ExtensionItems.Add($item)
    }

    $script:Controls['lstExtensions'].ItemsSource = $script:ExtensionItems
    Write-HULogInfo "$((@($extensions)).Count) Extension(s) geladen."
}

function Show-ExtensionDetails {
    param([PSCustomObject]$Extension)

    $script:SelectedExtension = $Extension
    $script:Controls['txtExtTitle'].Text = $Extension.Name
    $script:Controls['txtExtSynopsis'].Text = $Extension.Synopsis

    # Runtime badge (PS5 = hidden, PS7 = green badge, PS5|PS7 = blue badge)
    $rtBadge = $script:Controls['txtExtRuntime']
    $extRuntime = if ($Extension.Runtime) { $Extension.Runtime } else { 'PS5' }
    if ($extRuntime -eq 'PS7') {
        $rtBadge.Text = 'PS7'
        $rtBadge.Background = Get-HUBrush ('#4CAF50')
        $rtBadge.Visibility = [System.Windows.Visibility]::Visible
    }
    elseif ($extRuntime -eq 'PS5|PS7') {
        $rtBadge.Text = 'PS5|PS7'
        $rtBadge.Background = Get-HUBrush ('#2196F3')
        $rtBadge.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $rtBadge.Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Mode badge (ReadOnly = hidden, ReadWrite = orange badge)
    $modeBadge = $script:Controls['txtExtMode']
    $extMode = if ($Extension.Mode) { $Extension.Mode } else { 'ReadOnly' }
    if ($extMode -eq 'ReadWrite') {
        $modeBadge.Text = 'READ/WRITE'
        $modeBadge.Background = Get-HUBrush ('#E6820E')
        $modeBadge.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $modeBadge.Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Description (show if different from synopsis)
    if ($Extension.Description -and $Extension.Description -ne $Extension.Synopsis) {
        $script:Controls['txtExtDescription'].Text = $Extension.Description
        $script:Controls['txtExtDescription'].Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $script:Controls['txtExtDescription'].Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Permissions list
    $script:Controls['lstPermissions'].Items.Clear()
    foreach ($p in $Extension.RequiredPermissions) {
        $script:Controls['lstPermissions'].Items.Add($p) | Out-Null
    }

    # Dry-Run checkbox
    $script:Controls['chkDryRun'].IsEnabled = $Extension.DryRunCapable
    if (-not $Extension.DryRunCapable) {
        $script:Controls['chkDryRun'].IsChecked = $false
    }

    # Custom Parameters panel
    $paramPanel = $script:Controls['spCustomParams']
    $paramBorder = $script:Controls['pnlCustomParams']
    $paramPanel.Children.Clear()
    $script:CustomParamControls = @{}

    if ($Extension.CustomParameters -and $Extension.CustomParameters.Count -gt 0) {
        foreach ($cp in $Extension.CustomParameters) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = "$($cp.Label):"
            $label.Foreground = Get-HUBrush ('#CCCCCC')
            $label.FontSize = 10
            $label.Width = 140
            $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.DockPanel]::SetDock($label, [System.Windows.Controls.Dock]::Left)
            $row.Children.Add($label) | Out-Null

            switch ($cp.Type.ToLower()) {
                'bool' {
                    $chk = New-Object System.Windows.Controls.CheckBox
                    $chk.IsChecked = ($cp.Default -eq '$true' -or $cp.Default -eq 'true')
                    $chk.Foreground = Get-HUBrush ('#CCCCCC')
                    $chk.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $row.Children.Add($chk) | Out-Null
                    $script:CustomParamControls[$cp.Name] = @{ Control = $chk; Type = 'bool' }
                }
                'choice' {
                    $cmb = New-Object System.Windows.Controls.ComboBox
                    $cmb.Style = $script:Window.FindResource('DarkComboBox')
                    foreach ($choice in $cp.Choices) {
                        $cmb.Items.Add($choice.Trim()) | Out-Null
                    }
                    if ($cp.Default) { $cmb.SelectedItem = $cp.Default }
                    elseif ($cmb.Items.Count -gt 0) { $cmb.SelectedIndex = 0 }
                    $row.Children.Add($cmb) | Out-Null
                    $script:CustomParamControls[$cp.Name] = @{ Control = $cmb; Type = 'choice' }
                }
                default {
                    # string, int — TextBox
                    $txt = New-Object System.Windows.Controls.TextBox
                    $txt.Background = Get-HUBrush ('#3E3E42')
                    $txt.Foreground = Get-HUBrush ('#CCCCCC')
                    $txt.BorderBrush = Get-HUBrush ('#555555')
                    $txt.FontSize = 10
                    $txt.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
                    $txt.Text = $cp.Default
                    $row.Children.Add($txt) | Out-Null
                    $script:CustomParamControls[$cp.Name] = @{ Control = $txt; Type = $cp.Type.ToLower() }
                }
            }

            $paramPanel.Children.Add($row) | Out-Null
        }
        $paramBorder.Visibility = [System.Windows.Visibility]::Visible
    }
    else {
        $paramBorder.Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Enable start button
    $script:Controls['btnStart'].IsEnabled = $true

    # Dry-Run banner
    Update-DryRunBanner
}

function Update-DryRunBanner {
    if ($script:Controls['chkDryRun'].IsChecked -eq $true) {
        $script:Controls['txtDryRunBanner'].Text = "DRY-RUN - es wird nichts geaendert"
    }
    else {
        $script:Controls['txtDryRunBanner'].Text = ''
    }
}

# ============================================================================
# Ereignisse
# ============================================================================
function Register-HUExtensionHandlers {
    # --- Extension Selected ---
    $script:Controls['lstExtensions'].Add_SelectionChanged({
        $selectedItem = $script:Controls['lstExtensions'].SelectedItem
        if ($selectedItem -and $selectedItem.ExtensionObj) {
            Show-ExtensionDetails -Extension $selectedItem.ExtensionObj
        }
    })

    # --- Extension Search ---
    $script:Controls['txtExtSearch'].Add_TextChanged({
        $filter = $script:Controls['txtExtSearch'].Text
        $script:Controls['txtExtSearchHint'].Visibility = $(if ($filter) { 'Collapsed' } else { 'Visible' })
        if ([string]::IsNullOrWhiteSpace($filter)) {
            $script:Controls['lstExtensions'].ItemsSource = $script:ExtensionItems
            return
        }

        $filtered = $script:ExtensionItems | Where-Object {
            "$($_.Name)".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or "$($_.Synopsis)".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or "$($_.Category)".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        $script:Controls['lstExtensions'].ItemsSource = @($filtered)
    })

    # --- Dry-Run Checkbox ---
    $script:Controls['chkDryRun'].Add_Checked({ Update-DryRunBanner })
    $script:Controls['chkDryRun'].Add_Unchecked({ Update-DryRunBanner })

    # --- START Button ---
    $script:Controls['btnStart'].Add_Click({
        if ($script:IsRunning) { return }
        if (-not $script:SelectedExtension) {
            Write-HULogWarn 'Keine Extension ausgewaehlt.'
            return
        }

        $tenantKey = Get-SelectedTenantKey
        if (-not $tenantKey) {
            Write-HULogWarn 'Kein Tenant ausgewaehlt.'
            return
        }

        # Get token if not cached
        if (-not $script:CurrentToken -or -not (Test-TokenValid -TenantKey $tenantKey -Settings $script:Settings)) {
            Write-HULogInfo "Hole Token fuer $tenantKey ..." -Tenant $tenantKey
            try { $script:CurrentToken = Get-GraphToken -TenantKey $tenantKey -Settings $script:Settings -ErrorAction Stop } catch { $script:CurrentToken = $null; Write-HULogDebug "Token: $($_.Exception.Message)" -Tenant $tenantKey }
            if (-not $script:CurrentToken) {
                Write-HULogError 'Kein Token - Secret pruefen (Einstellungen > Tenants).' -Tenant $tenantKey
                return
            }
            # Token erfolgreich geholt → Status auf Connected setzen
            Update-TenantStatusCache -TenantKey $tenantKey -Connected $true
            Update-TenantStatus -TenantKey $tenantKey
            Update-HUTenantItemSuffixes
        }

        # Target validation
        $targetCheck = Test-ExtensionTargets -Extension $script:SelectedExtension -TenantKey $tenantKey
        if (-not $targetCheck.IsAllowed) {
            if (-not (Confirm-HU "$($targetCheck.Warning)`n`nTrotzdem fortfahren?" 'Ziel-Warnung' -Warning)) { return }
        }

        # Permission validation
        $permCheck = Validate-ExtensionPermissions -Extension $script:SelectedExtension -Token $script:CurrentToken
        if (-not $permCheck.IsValid) {
            $missingList = $permCheck.MissingPermissions -join ', '
            Write-HULogError "Fehlende Berechtigungen: $missingList" -Tenant $tenantKey
            Show-HUMessage "Fehlende Berechtigungen:`n$missingList`n`nEinrichten: Knopf 'Berechtigungen' oben rechts." 'Berechtigungen' -Icon Error
            return
        }

        # Dry-Run confirmation
        $isDryRun = $script:Controls['chkDryRun'].IsChecked -eq $true
        $modeText = if ($isDryRun) { 'DRY-RUN (keine Aenderungen)' } else { 'LIVE' }

        # ReadWrite warning for write-capable extensions
        $extMode = if ($script:SelectedExtension.Mode) { $script:SelectedExtension.Mode } else { 'ReadOnly' }
        if ($extMode -eq 'ReadWrite' -and -not $isDryRun) {
            $rwConfirm = [System.Windows.MessageBox]::Show(
                "ACHTUNG: Diese Extension kann Aenderungen am Tenant '$tenantKey' vornehmen!`n`n" +
                "Extension: $($script:SelectedExtension.Name)`n" +
                "Mode: READ/WRITE (Schreibzugriff)`n`n" +
                "Sicher fortfahren?",
                'Write-Access Warnung',
                'YesNo', 'Warning'
            )
            if ($rwConfirm -ne 'Yes') { return }
        }

        # Collect custom parameters
        $customParamValues = @{}
        if ($script:CustomParamControls -and $script:CustomParamControls.Count -gt 0) {
            foreach ($paramName in $script:CustomParamControls.Keys) {
                $paramInfo = $script:CustomParamControls[$paramName]
                switch ($paramInfo.Type) {
                    'bool'   { $customParamValues[$paramName] = $paramInfo.Control.IsChecked -eq $true }
                    'choice' { $customParamValues[$paramName] = $paramInfo.Control.SelectedItem }
                    'int'    {
                        $intVal = 0
                        if ([int]::TryParse($paramInfo.Control.Text, [ref]$intVal)) {
                            $customParamValues[$paramName] = $intVal
                        } else {
                            $customParamValues[$paramName] = $paramInfo.Control.Text
                        }
                    }
                    default  { $customParamValues[$paramName] = $paramInfo.Control.Text }
                }
            }
        }

        if (-not (Confirm-HU "'$($script:SelectedExtension.Name)' auf '$tenantKey' ausfuehren?`nModus: $modeText" 'Ausfuehren')) { return }

        # Execute in background to keep GUI responsive
        $script:IsRunning = $true
        $script:CancelRequested = $false
        $script:Controls['btnStart'].IsEnabled = $false
        $script:Controls['btnCancel'].IsEnabled = $true

        Write-HULogInfo "Starte '$($script:SelectedExtension.Name)' [$modeText] ..." -Tenant $tenantKey

        # Capture variables for background use
        $bgExtension = $script:SelectedExtension
        $bgTenantKey = $tenantKey
        $bgToken     = $script:CurrentToken
        $bgDryRun    = $isDryRun

        # Resolve log file path for the background runspace (same file as main GUI)
        $bgLogFile = Get-CurrentLogFile

        # Determine runtime: PS5 (in-process Runspace) or PS7 (pwsh.exe child process)
        $extensionRuntime = if ($bgExtension.Runtime) { $bgExtension.Runtime } else { 'PS5' }
        $usePS7 = ($extensionRuntime -eq 'PS7')

        # Check PS7 availability if needed
        if ($usePS7) {
            $pwshPath = $null
            $pwshCmd = Get-Command 'pwsh' -ErrorAction SilentlyContinue
            if ($pwshCmd) {
                $pwshPath = $pwshCmd.Source
            }
            elseif (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe') {
                $pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
            }

            if (-not $pwshPath) {
                Write-HULogError 'PowerShell 7 (pwsh.exe) nicht gefunden - diese Extension braucht PowerShell 7.' -Tenant $tenantKey
                $script:IsRunning = $false
                $script:Controls['btnStart'].IsEnabled = $true
                $script:Controls['btnCancel'].IsEnabled = $false
                return
            }
            Write-HULogInfo "PowerShell 7: $pwshPath" -Tenant $tenantKey
        }

        # === EXECUTION MODE: PS7 (pwsh.exe child process) ===
        if ($usePS7) {
            $wrapperScript = Join-Path $script:AppRoot 'Core\Invoke-PS7Extension.ps1'
            if (-not (Test-Path $wrapperScript)) {
                Write-HULogError "PS7-Starter fehlt: $wrapperScript" -Tenant $tenantKey
                $script:IsRunning = $false
                $script:Controls['btnStart'].IsEnabled = $true
                $script:Controls['btnCancel'].IsEnabled = $false
                return
            }

            # Temp-Datei fuer JSON-Result
            $resultFile = [System.IO.Path]::GetTempFileName()

            $pwshArgs = @(
                '-NoProfile'
                '-NonInteractive'
                '-ExecutionPolicy', 'Bypass'
                '-File', $wrapperScript
                '-AppRoot', $script:AppRoot
                '-ExtensionPath', $bgExtension.Path
                '-TenantKey', $bgTenantKey
                '-Token', $bgToken
                '-LogFile', $bgLogFile
                '-ResultFile', $resultFile
            )
            if ($bgDryRun) { $pwshArgs += '-IsDryRun' }

            # Custom parameters as JSON temp file
            if ($customParamValues -and $customParamValues.Count -gt 0) {
                $paramFile = [System.IO.Path]::GetTempFileName()
                $customParamValues | ConvertTo-Json -Depth 5 | Set-Content -Path $paramFile -Encoding UTF8
                $pwshArgs += @('-CustomParamsFile', $paramFile)
            }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $pwshPath
            $psi.Arguments = ($pwshArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

            $bgProcess = [System.Diagnostics.Process]::Start($psi)

            # Store background state
            $script:BgPowerShell  = $null
            $script:BgAsyncResult = $null
            $script:BgRunspace    = $null
            $script:BgProcess     = $bgProcess
            $script:BgResultFile  = $resultFile
            $script:BgTenantKey   = $bgTenantKey
            $script:BgIsPS7       = $true
        }
        # === EXECUTION MODE: PS5 (in-process Runspace, wie bisher) ===
        else {
            $bgRunspace = [runspacefactory]::CreateRunspace()
            $bgRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
            $bgRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $bgRunspace.Open()

            $bgRunspace.SessionStateProxy.SetVariable('Extension', $bgExtension)
            $bgRunspace.SessionStateProxy.SetVariable('TenantKey', $bgTenantKey)
            $bgRunspace.SessionStateProxy.SetVariable('Token', $bgToken)
            $bgRunspace.SessionStateProxy.SetVariable('IsDryRun', $bgDryRun)
            $bgRunspace.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
            $bgRunspace.SessionStateProxy.SetVariable('BgLogFile', $bgLogFile)
            $bgRunspace.SessionStateProxy.SetVariable('BgCustomParams', $customParamValues)

            $bgPowerShell = [powershell]::Create()
            $bgPowerShell.Runspace = $bgRunspace

            [void]$bgPowerShell.AddScript({
                param()

                $coreModules = @('HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Extensions', 'HU.Excel')
                foreach ($mod in $coreModules) {
                    $modPath = Join-Path $AppRoot "Core\$mod.psm1"
                    if (Test-Path $modPath) {
                        Import-Module $modPath -Force -DisableNameChecking
                    }
                }

                Initialize-Logging -LogFilePath $BgLogFile -MinLevel 'DEBUG'

                $execParams = @{
                    Extension        = $Extension
                    TenantKey        = $TenantKey
                    Token            = $Token
                    CustomParameters = $BgCustomParams
                }
                if ($IsDryRun) { $execParams.WhatIf = $true }

                try {
                    $result = Invoke-ExtensionScript @execParams
                    return $result
                }
                catch {
                    return [PSCustomObject]@{
                        Success      = $false
                        ErrorMessage = $_.Exception.Message
                        Duration     = [TimeSpan]::Zero
                    }
                }
            })

            $bgAsyncResult = $bgPowerShell.BeginInvoke()

            # Store background state
            $script:BgPowerShell  = $bgPowerShell
            $script:BgAsyncResult = $bgAsyncResult
            $script:BgRunspace    = $bgRunspace
            $script:BgProcess     = $null
            $script:BgResultFile  = $null
            $script:BgTenantKey   = $bgTenantKey
            $script:BgIsPS7       = $false
        }

        # Log-file polling: track last read position (line count before BG start)
        $script:BgLogLastLine = 0
        if ($bgLogFile -and (Test-Path $bgLogFile)) {
            $script:BgLogLastLine = @(Get-Content $bgLogFile -ErrorAction SilentlyContinue).Count
        }
        $script:BgLogFile = $bgLogFile

        # Color mapping for log-level detection in polled lines
        $script:LogLevelColorMap = @{
            'ERROR' = '#FF4444'
            'WARN'  = '#FFEB3B'
            'OK'    = '#4CAF50'
            'INFO'  = '#2196F3'
            'DEBUG' = '#888888'
        }

        # Single DispatcherTimer: polls log file + checks completion
        $pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $pollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $pollTimer.Add_Tick({
            # --- LOG FILE POLLING ---
            if ($script:BgLogFile -and (Test-Path $script:BgLogFile)) {
                try {
                    $allLines = @(Get-Content $script:BgLogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
                    if ($allLines.Count -gt $script:BgLogLastLine) {
                        $rtb = $script:Controls['rtbLog']
                        for ($i = $script:BgLogLastLine; $i -lt $allLines.Count; $i++) {
                            $line = $allLines[$i]

                            # Detect log level from formatted line for color
                            $color = '#CCCCCC'
                            foreach ($lvl in $script:LogLevelColorMap.Keys) {
                                if ($line -match "\[$lvl\]") {
                                    $color = $script:LogLevelColorMap[$lvl]
                                    break
                                }
                            }

                            # Append to RichTextBox (we are already on UI thread via Dispatcher)
                            $paragraph = New-Object System.Windows.Documents.Paragraph
                            $run = New-Object System.Windows.Documents.Run($line)
                            try {
                                $run.Foreground = Get-HUBrush ($color)
                            }
                            catch {
                                $run.Foreground = [System.Windows.Media.Brushes]::White
                            }
                            $paragraph.Inlines.Add($run)
                            $paragraph.Margin = [System.Windows.Thickness]::new(0)
                            $paragraph.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
                            $paragraph.FontSize = 11
                            $rtb.Document.Blocks.Add($paragraph)

                            # Limit GUI lines
                            while ($rtb.Document.Blocks.Count -gt 500) {
                                $rtb.Document.Blocks.Remove($rtb.Document.Blocks.FirstBlock)
                            }
                        }
                        $rtb.ScrollToEnd()
                        $script:BgLogLastLine = $allLines.Count
                    }
                }
                catch {
                    # Log polling must never crash the timer
                }
            }

            # --- COMPLETION CHECK ---
            # Determine if background task has finished (PS5 Runspace or PS7 Process)
            $isCompleted = $false
            if ($script:BgIsPS7) {
                $isCompleted = ($null -ne $script:BgProcess -and $script:BgProcess.HasExited)
            }
            else {
                $isCompleted = ($null -ne $script:BgAsyncResult -and $script:BgAsyncResult.IsCompleted)
            }

            if ($isCompleted) {
                $this.Stop()

                # Final log poll (catch last lines written before completion)
                if ($script:BgLogFile -and (Test-Path $script:BgLogFile)) {
                    try {
                        $finalLines = @(Get-Content $script:BgLogFile -Encoding UTF8 -ErrorAction SilentlyContinue)
                        $rtb = $script:Controls['rtbLog']
                        for ($i = $script:BgLogLastLine; $i -lt $finalLines.Count; $i++) {
                            $line = $finalLines[$i]
                            $color = '#CCCCCC'
                            foreach ($lvl in $script:LogLevelColorMap.Keys) {
                                if ($line -match "\[$lvl\]") {
                                    $color = $script:LogLevelColorMap[$lvl]
                                    break
                                }
                            }
                            $paragraph = New-Object System.Windows.Documents.Paragraph
                            $run = New-Object System.Windows.Documents.Run($line)
                            try { $run.Foreground = Get-HUBrush ($color) }
                            catch { $run.Foreground = [System.Windows.Media.Brushes]::White }
                            $paragraph.Inlines.Add($run)
                            $paragraph.Margin = [System.Windows.Thickness]::new(0)
                            $paragraph.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
                            $paragraph.FontSize = 11
                            $rtb.Document.Blocks.Add($paragraph)
                        }
                        $rtb.ScrollToEnd()
                    }
                    catch {}
                }

                try {
                    if ($script:CancelRequested) {
                        Write-HULogWarn 'Vom Benutzer abgebrochen.' -Tenant $script:BgTenantKey
                    }
                    elseif ($script:BgIsPS7) {
                        # === PS7: Read result from JSON file ===
                        if ($script:BgResultFile -and (Test-Path $script:BgResultFile)) {
                            try {
                                $jsonContent = Get-Content $script:BgResultFile -Raw -Encoding UTF8
                                $result = $jsonContent | ConvertFrom-Json
                                if ($result.Success) {
                                    $duration = '?'
                                    if ($result.Duration) {
                                        try { $duration = [math]::Round([TimeSpan]::Parse($result.Duration).TotalSeconds, 1) } catch { }
                                    }
                                    Write-HULogOK "Fertig in ${duration}s (PS7)" -Tenant $script:BgTenantKey
                                }
                                else {
                                    Write-HULogError "Fehlgeschlagen: $($result.ErrorMessage)" -Tenant $script:BgTenantKey
                                }
                            }
                            catch {
                                Write-HULogError "PS7-Ergebnis nicht lesbar: $($_.Exception.Message)" -Tenant $script:BgTenantKey
                            }
                            finally {
                                Remove-Item $script:BgResultFile -Force -ErrorAction SilentlyContinue
                            }
                        }
                        else {
                            $exitCode = $script:BgProcess.ExitCode
                            if ($exitCode -eq 0) {
                                Write-HULogOK 'Fertig (PS7, ohne Ergebnisdatei).' -Tenant $script:BgTenantKey
                            }
                            else {
                                Write-HULogError "PS7-Prozess beendet mit Exitcode $exitCode" -Tenant $script:BgTenantKey
                            }
                        }
                    }
                    else {
                        # === PS5: EndInvoke on Runspace ===
                        $results = $script:BgPowerShell.EndInvoke($script:BgAsyncResult)
                        $result = $results | Select-Object -Last 1

                        if ($result -and $result.Success) {
                            $duration = if ($result.Duration) { [math]::Round($result.Duration.TotalSeconds, 1) } else { '?' }
                            Write-HULogOK "Fertig in ${duration}s" -Tenant $script:BgTenantKey
                        }
                        elseif ($result) {
                            Write-HULogError "Fehlgeschlagen: $($result.ErrorMessage)" -Tenant $script:BgTenantKey
                        }
                        else {
                            Write-HULogWarn "Das Skript hat kein Ergebnis geliefert." -Tenant $script:BgTenantKey
                        }

                        if ($script:BgPowerShell.Streams.Error.Count -gt 0) {
                            foreach ($err in $script:BgPowerShell.Streams.Error) {
                                Write-HULogError "Fehler: $($err.Exception.Message)" -Tenant $script:BgTenantKey
                            }
                        }
                    }
                }
                catch {
                    if ($script:CancelRequested) {
                        Write-HULogWarn 'Vom Benutzer abgebrochen.' -Tenant $script:BgTenantKey
                    }
                    else {
                        Write-HULogError "Ergebnis nicht auswertbar: $($_.Exception.Message)" -Tenant $script:BgTenantKey
                    }
                }
                finally {
                    # Cleanup: PS5 Runspace or PS7 Process
                    if ($script:BgPowerShell) {
                        try { $script:BgPowerShell.Dispose() } catch { }
                    }
                    if ($script:BgRunspace) {
                        try { $script:BgRunspace.Dispose() } catch { }
                    }
                    if ($script:BgProcess) {
                        try { if (-not $script:BgProcess.HasExited) { $script:BgProcess.Kill() } } catch { }
                        try { $script:BgProcess.Dispose() } catch { }
                    }
                    $script:IsRunning = $false
                    $script:Controls['btnStart'].IsEnabled = $true
                    $script:Controls['btnCancel'].IsEnabled = $false
                }
            }
        })
        $pollTimer.Start()
    })

    # --- CANCEL Button ---
    $script:Controls['btnCancel'].Add_Click({
        if (-not $script:IsRunning) { return }
        $script:CancelRequested = $true
        $tenantKey = Get-SelectedTenantKey
        Write-HULogWarn 'Abbruch angefordert - Hintergrundausfuehrung wird gestoppt ...' -Tenant $tenantKey

        try {
            if ($script:BgIsPS7 -and $script:BgProcess) {
                # PS7: Kill the pwsh.exe child process
                if (-not $script:BgProcess.HasExited) {
                    $script:BgProcess.Kill()
                }
            }
            elseif ($script:BgPowerShell) {
                # PS5: Stop the in-process PowerShell pipeline
                $script:BgPowerShell.Stop()
            }
        }
        catch {
            Write-HULogWarn "Stoppen fehlgeschlagen: $($_.Exception.Message)" -Tenant $tenantKey
        }
    })

    # --- Clear Log Button ---
    $script:Controls['btnClearLog'].Add_Click({
        Clear-LogBuffer -IncludeGui
    })

    # --- Reload Extensions Button (Sync-Symbol ↻) ---
    $script:Controls['btnReloadExt'].Add_MouseLeftButtonUp({
        Write-HULogInfo 'Extensions werden neu geladen ...'
        Load-Extensions
        $script:Controls['txtExtSearch'].Text = ''
        Write-HULogOK "Extensions neu geladen: $($script:ExtensionItems.Count)"
    })
    $script:Controls['btnReloadExt'].Add_MouseEnter({ $script:Controls['btnReloadExt'].Foreground = Get-HUBrush ('#4CAF50') })
    $script:Controls['btnReloadExt'].Add_MouseLeave({ $script:Controls['btnReloadExt'].Foreground = Get-HUBrush ('#858585') })

    # --- Berechtigungs-Assistent ---
    $script:Controls['btnSetupGuide'].Add_Click({
        Show-HUPermissions -TenantKey (Get-SelectedTenantKey)
    })

    # --- Ordner oeffnen ---
    $script:Controls['btnOpenLogFolder'].Add_Click({
        $f = Get-CurrentLogFile
        Open-HUPath $(if ($f) { Split-Path $f -Parent } else { Join-Path $script:AppRoot 'Logs' })
    })
    $script:Controls['btnOpenReports'].Add_Click({ Open-HUPath (Get-HUReportsPath) })
}

# Reports-Ordner aus settings.json (reporting.outputPath, relativ zum Programmordner)
function Get-HUReportsPath {
    $p = './Reports'
    try { if ($script:Settings.reporting.outputPath) { $p = "$($script:Settings.reporting.outputPath)" } } catch { }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:AppRoot ($p -replace '^\.[\\/]', '') }
    return $p
}
