#Requires -Version 5.1
<#
.SYNOPSIS
    Quick Script Runner: Ad-hoc-PowerShell im Tenant-Kontext (eigener Runspace, Ausgabe in Echtzeit).
.DESCRIPTION
    Im Skript verfuegbar: $Token, $TenantKey, $Schule (= TenantKey), $Settings, $AppRoot, Get-HUToken,
    die Module HU.Auth und HU.Graph (Invoke-GraphRequest, Alias Invoke-AdminGraphRequest) und die Snippet-Parameter
    (# @param ...) als Variablen. Mehrere Tenants: das Skript laeuft je Tenant einmal (Core\HU.QSRuntime.ps1).
    Tasten: Strg+Enter / F5 = ausfuehren, F8 = nur Markierung, Strg+S = speichern, Strg+N = neu,
            Strg+Mausrad im Editor = Schriftgroesse, Esc = laufendes Skript abbrechen.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:QS_Token       = $null
$script:QS_TenantKey   = $null
$script:QS_PS          = $null
$script:QS_RS          = $null
$script:QS_Timer       = $null
$script:QS_AsyncHandle = $null
$script:QS_OutputColl  = $null
$script:QS_Idx         = @{ Out = 0; Info = 0; Warn = 0; Err = 0 }
$script:QS_Spinner     = 0
$script:QS_Stopping    = $false
$script:QS_Started     = $null
$script:QS_Current     = ''      # Name des geladenen Snippets ('' = neu)
$script:QS_SavedCode   = $null   # Code beim letzten Laden/Speichern -> ungespeicherte Aenderungen erkennen
$script:QS_SuppressSelect = $false
$script:QS_CurrentFav = $false
$script:QS_CurrentCat = ''
$script:QS_RunTenants = @()
$script:QS_ErrCount = 0
$script:QS_RunCode = ''
$script:QS_RunName = ''
$script:QS_CurrentDesc = ''    # Kurzbeschreibung des geladenen Snippets (nicht bei jedem Tastendruck neu lesen)

function Write-QSOutput {
    param([string]$Text, [string]$Color = '#D4D4D4')
    if ($null -ne $script:QS_RunLines) { $script:QS_RunLines.Add($Text) }
    $rtb = $script:Controls['rtbQSOutput']
    $para = [System.Windows.Documents.Paragraph]::new()
    $para.Margin = [System.Windows.Thickness]::new(0)
    $run = [System.Windows.Documents.Run]::new($Text)
    $run.Foreground = Get-HUBrush $Color
    $para.Inlines.Add($run)
    $rtb.Document.Blocks.Add($para)
    while ($rtb.Document.Blocks.Count -gt 5000) { $rtb.Document.Blocks.Remove($rtb.Document.Blocks.FirstBlock) }
    $rtb.ScrollToEnd()
}

# ============================================================================
# Snippet im Editor: Anzeige, ungespeicherte Aenderungen
# ============================================================================
function Test-HUQSDirty {
    $t = $script:Controls['txtQSEditor'].Text
    if ($null -eq $script:QS_SavedCode) { return [bool]("$t".Trim()) }
    return ($t -cne $script:QS_SavedCode)
}

function Update-HUQSSnippetInfo {
    $c = $script:Controls
    $dirty = Test-HUQSDirty
    $c['txtSnippetDirty'].Text = $(if ($dirty) { [string][char]0x25CF } else { '' })
    $c['txtSnippetDirty'].ToolTip = $(if ($dirty) { 'Ungespeicherte Aenderungen (Strg+S)' } else { $null })
    $fav = ($script:QS_Current -and $script:QS_CurrentFav)
    $c['btnSnippetFav'].Text = $(if ($fav) { [string][char]0x2605 } else { [string][char]0x2606 })
    $c['btnSnippetFav'].Foreground = Get-HUBrush $(if ($fav) { '#FFC107' } elseif ($script:QS_Current) { '#888888' } else { '#444444' })
    if ($script:QS_Current) {
        $c['txtSnippetName'].Text = $script:QS_Current
        $c['txtSnippetDesc'].Text = $(if ($script:QS_CurrentDesc) { $script:QS_CurrentDesc } else { '(keine Beschreibung - Speichern unter ... oder Verwalten)' })
        $c['txtSnippetCat'].Text = $script:QS_CurrentCat
        $c['bdSnippetCat'].Visibility = $(if ($script:QS_CurrentCat) { 'Visible' } else { 'Collapsed' })
    } else {
        $c['bdSnippetCat'].Visibility = 'Collapsed'
        $c['txtSnippetName'].Text = '(neues Snippet)'
        $c['txtSnippetDesc'].Text = $(if ($dirty) { 'noch nicht gespeichert' } else { '' })
    }
}

# $true = weitermachen (gespeichert oder verworfen), $false = abgebrochen
function Confirm-HUQSDiscard([string]$Action = 'fortfahren') {
    if (-not (Test-HUQSDirty)) { return $true }
    $n = if ($script:QS_Current) { "'$($script:QS_Current)'" } else { 'Das neue Snippet' }
    $a = Confirm-HUYesNoCancel "$n hat ungespeicherte Aenderungen.`n`nJa = speichern und $Action`nNein = verwerfen und $Action`nAbbrechen = zurueck zum Editor" 'Quick Script'
    if ($a -eq 'Cancel') { return $false }
    if ($a -eq 'Yes') { return (Save-HUQSSnippet) }
    return $true
}

function Open-HUQSSnippet([string]$Name) {
    $s = Get-HUSnippet $Name
    if (-not $s) { Write-QSOutput "[WARN] Snippet '$Name' nicht gefunden." '#FF9800'; return }
    $script:Controls['txtQSEditor'].Text = $s.code
    $script:QS_Current = $s.name
    $script:QS_CurrentDesc = "$($s.description)"
    $script:QS_CurrentFav = ($s.favorite -eq $true)
    $script:QS_SavedCode = $script:Controls['txtQSEditor'].Text
    $script:QS_CurrentCat = "$($s.category)"
    Set-HUStateValue 'lastSnippet' $s.name
    Update-HUSnippetCombo -Select $s.name
    Update-HUQSParamPanel -Force
    Update-HUQSSnippetInfo
    Write-QSOutput "[INFO] Snippet '$($s.name)' geladen." '#4FC3F7'
}

function New-HUQSSnippet {
    if (-not (Confirm-HUQSDiscard 'neu beginnen')) { return }
    $script:Controls['txtQSEditor'].Text = ''
    $script:QS_Current = ''
    $script:QS_CurrentDesc = ''
    $script:QS_CurrentFav = $false
    $script:QS_CurrentCat = ''
    $script:QS_SavedCode = $null
    Update-HUSnippetCombo
    Update-HUQSParamPanel -Force
    Update-HUQSSnippetInfo
    $script:Controls['txtQSEditor'].Focus() | Out-Null
}

# Speichern (Strg+S). Ohne geladenes Snippet oder mit -As: Name + Beschreibung abfragen.
function Save-HUQSSnippet([switch]$As) {
    $code = $script:Controls['txtQSEditor'].Text
    if (-not "$code".Trim()) { Show-HUMessage 'Der Editor ist leer - nichts zu speichern.' 'Quick Script' -Icon Warning; return $false }
    $name = $script:QS_Current
    $desc = $null
    if ($As -or -not $name) {
        $cur = Get-HUSnippet $script:QS_Current
        $r = Read-HUNameDescription -Title $(if ($As) { 'Speichern unter' } else { 'Snippet speichern' }) `
            -Name $(if ($As -and $name) { "$name (Kopie)" } else { $name }) -Description $(if ($cur) { $cur.description } else { '' }) `
            -Hint 'Die Kurzbeschreibung wird in der Snippet-Liste neben dem Namen angezeigt.'
        if (-not $r) { return $false }
        if ($r.Name -ne $script:QS_Current -and @(Get-HUSnippets | Where-Object { $_.name -eq $r.Name }).Count) {
            if (-not (Confirm-HU "Snippet '$($r.Name)' gibt es schon. Ueberschreiben?" 'Quick Script' -Warning)) { return $false }
        }
        $name = $r.Name; $desc = $r.Description
    }
    $ok = if ($null -ne $desc) { Set-HUSnippet -Name $name -Code $code -Description $desc } else { Set-HUSnippet -Name $name -Code $code }
    if (-not $ok) { return $false }
    $script:QS_Current = $name
    $saved = Get-HUSnippet $name; $script:QS_CurrentDesc = $(if ($saved) { "$($saved.description)" } else { '' }); $script:QS_CurrentFav = [bool]($saved -and $saved.favorite -eq $true); $script:QS_CurrentCat = $(if ($saved) { "$($saved.category)" } else { '' })
    $script:QS_SavedCode = $code
    Set-HUStateValue 'lastSnippet' $name
    Update-HUSnippetCombo -Select $name
    Update-HUQSSnippetInfo
    Write-QSOutput "[OK] Snippet '$name' gespeichert." '#4CAF50'
    return $true
}

# ============================================================================
# Verbinden
# ============================================================================
function Set-HUQSConnected([bool]$On, [string]$Text = '', [string]$Color = '#858585') {
    $c = $script:Controls
    $c['txtQSStatus'].Text = $Text
    $c['txtQSStatus'].Foreground = Get-HUBrush $Color
    $c['btnQSDisconnect'].IsEnabled = $On
    $c['btnQSRun'].IsEnabled = ((@(Get-HUQSRunTenants).Count -gt 0) -and -not ($script:QS_Timer -and $script:QS_Timer.IsEnabled))
}

function Connect-HUQS {
    $k = Get-HUQSTenantKey
    if (-not $k) { Set-HUQSConnected $false 'Kein Tenant ausgewaehlt.' '#FF9800'; return $false }
    $t = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1
    Set-HUQSConnected $false "Verbinde $($t.displayName) ..." '#858585'
    $script:Controls['btnQSConnect'].IsEnabled = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $tok = $null
        try { $tok = Get-GraphToken -TenantKey $k -Settings $script:Settings -ErrorAction Stop } catch { Write-HULogDebug "QS-Verbindung: $($_.Exception.Message)" -Tenant $k }
        if ($tok) {
            $script:QS_Token = $tok; $script:QS_TenantKey = $k
            Set-HUQSConnected $true "Verbunden: $($t.displayName)" '#4CAF50'
            Update-TenantStatusCache -TenantKey $k -Connected $true
            Update-HUSecretExpiry $k $tok
            return $true
        }
        $script:QS_Token = $null; $script:QS_TenantKey = $null
        Set-HUQSConnected $false 'Verbindung fehlgeschlagen - Secret pruefen (Einstellungen > Tenants).' '#D32F2F'
        return $false
    } finally {
        $script:Controls['btnQSConnect'].IsEnabled = $true
        $script:Window.Cursor = $null
    }
}

function Disconnect-HUQS {
    $script:QS_Token = $null; $script:QS_TenantKey = $null
    Set-HUQSConnected $false 'Nicht verbunden' '#858585'
}

# ============================================================================
# Ausfuehren / Abbrechen
# ============================================================================
function Start-HUQSRun([switch]$Selection) {
    $ed = $script:Controls['txtQSEditor']
    $isSel = ($Selection -and $ed.SelectionLength -gt 0)
    $code = if ($isSel) { $ed.SelectedText } else { $ed.Text }
    if (-not "$code".Trim()) { Write-QSOutput '[WARN] Editor ist leer.' '#FF9800'; return }
    if ($script:QS_Timer -and $script:QS_Timer.IsEnabled) { Write-QSOutput '[WARN] Es laeuft bereits ein Skript.' '#FF9800'; return }
    $tenants = @(Get-HUQSRunTenants)
    if (-not $tenants.Count) { Write-QSOutput '[WARN] Kein Tenant ausgewaehlt.' '#FF9800'; return }

    # Parameter (Felder ueber dem Editor)
    try { Update-HUQSParamPanel; $pv = Get-HUQSParamValues } catch { Show-HUMessage "$($_.Exception.Message)" 'Parameter' -Icon Warning; return }
    $names = @($tenants | ForEach-Object { $k = $_; $t = $script:Settings.tenants | Where-Object { $_.key -eq $k } | Select-Object -First 1; if ($t) { "$($t.displayName)" } else { $k } })
    if (Test-HUQSLiveRun $script:QSParamDefs $pv) {
        if (-not (Confirm-HU "ECHTER LAUF - Aenderungen werden ausgefuehrt!`n`nSnippet: $(if ($script:QS_Current) { $script:QS_Current } else { '(Editor)' })`nTenants: $($names -join ', ')`n`nFortfahren?" 'Quick Script - Live' -Warning)) { return }
    }

    $what = if ($isSel) { 'Markierung' } elseif ($script:QS_Current) { $script:QS_Current } else { 'Editor' }
    $script:QS_RunLines = [System.Collections.Generic.List[string]]::new()
    $script:QS_Objects.Clear()
    Update-HUQSTableButton
    Write-QSOutput "--- $what @ $(Get-Date -Format 'HH:mm:ss') [$($names -join ', ')] ---" '#4FC3F7'
    if ($pv.Count) { Write-QSOutput ("    Parameter: " + ((@($pv.Keys | Sort-Object) | ForEach-Object { "$_=$($pv[$_])" }) -join '  ')) '#888888' }
    foreach ($o in @(Get-HUQSOverriddenParams $code)) { Write-QSOutput "[INFO] `$$o wird im Code gesetzt - das Feld '$o' wirkt dadurch nicht (Zuweisung im Code entfernen)." '#4FC3F7' }

    $c = $script:Controls
    $c['btnQSRun'].IsEnabled = $false
    $c['btnQSStop'].IsEnabled = $true
    $script:QS_Spinner = 0
    $script:QS_Stopping = $false
    $script:QS_Started = Get-Date
    $script:QS_Idx = @{ Out = 0; Info = 0; Warn = 0; Err = 0 }
    $script:QS_ErrCount = 0
    $script:QS_RunTenants = $tenants
    $script:QS_RunCode = $code
    $script:QS_RunName = $(if ($isSel) { "$what ($($script:QS_Current))" } else { $what })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Settings', $script:Settings)
    $rs.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
    $rs.SessionStateProxy.SetVariable('__UserCode', $code)
    $rs.SessionStateProxy.SetVariable('__Tenants', [string[]]$tenants)
    $rs.SessionStateProxy.SetVariable('__Params', $pv)
    $rs.SessionStateProxy.SetVariable('__Multi', ($tenants.Count -gt 1))

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Import-Module (Join-Path $AppRoot 'Core\HU.Auth.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        Import-Module (Join-Path $AppRoot 'Core\HU.Graph.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        . (Join-Path $AppRoot 'Core\HU.QSRuntime.ps1')
        $__sb = [scriptblock]::Create($__UserCode)
        $__i = 0
        foreach ($__tk in $__Tenants) {
            $__i++
            $global:TenantKey = $__tk
            $global:Schule = $__tk
            if ($__Multi) { Write-Host '' ; Write-Host ("===== [{0}/{1}] {2} =====" -f $__i, $__Tenants.Count, $__tk) -ForegroundColor Cyan }
            try { $global:Token = Get-HUToken -Tenant $__tk }
            catch { Write-Error "[$__tk] Kein Token: $($_.Exception.Message)"; continue }
            foreach ($__k in $__Params.Keys) { Set-Variable -Name $__k -Value $__Params[$__k] -Scope Global }
            try {
                & $__sb | ForEach-Object {
                    if ($__Multi -and $null -ne $_ -and $_.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
                        $_ | Add-Member -NotePropertyName 'Tenant' -NotePropertyValue $__tk -Force -PassThru
                    } else { $_ }
                }
            } catch {
                Write-Error "[$__tk] $($_.Exception.Message)"
            }
        }
    }.ToString())
    $outColl = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $inColl = [System.Management.Automation.PSDataCollection[PSObject]]::new()
    $inColl.Complete()
    $script:QS_PS = $ps
    $script:QS_RS = $rs
    $script:QS_OutputColl = $outColl
    $script:QS_AsyncHandle = $ps.BeginInvoke($inColl, $outColl)
    $c['txtQSStatus'].Text = "Laeuft auf $($names -join ', ') ..."
    $c['txtQSStatus'].Foreground = Get-HUBrush '#4FC3F7'

    if (-not $script:QS_Timer) {
        $script:QS_Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:QS_Timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:QS_Timer.Add_Tick({ Invoke-HUQSPoll })
    }
    $script:QS_Timer.Start()
}

# Neue Eintraege aus allen Streams ausgeben (UI-Thread)
function Read-HUQSStreams {
    $ps = $script:QS_PS
    if (-not $ps) { return }
    $coll = $script:QS_OutputColl
    $cnt = $coll.Count
    $added = $false
    while ($script:QS_Idx.Out -lt $cnt) {
        $o = $coll[$script:QS_Idx.Out]
        if ((Test-HUQSTableObject $o) -and $script:QS_Objects.Count -lt 100000) { $script:QS_Objects.Add($o); $added = $true }
        $txt = ($o | Out-String).TrimEnd()
        if ($txt) { Write-QSOutput $txt '#D4D4D4' }
        $script:QS_Idx.Out++
    }
    if ($added) { Update-HUQSTableButton }
    $info = $ps.Streams.Information
    $cnt = $info.Count
    while ($script:QS_Idx.Info -lt $cnt) {
        $msg = $info[$script:QS_Idx.Info].MessageData
        if ($msg -is [System.Management.Automation.HostInformationMessage]) {
            $col = switch ("$($msg.ForegroundColor)") {
                'Green' { '#4CAF50' } 'DarkGreen' { '#388E3C' } 'Cyan' { '#4FC3F7' } 'DarkCyan' { '#26A69A' }
                'Yellow' { '#FFC107' } 'DarkYellow' { '#FF9800' } 'Red' { '#F44336' } 'DarkRed' { '#C62828' }
                'Magenta' { '#CE93D8' } 'Blue' { '#64B5F6' } 'Gray' { '#9E9E9E' } 'DarkGray' { '#666666' }
                'White' { '#EEEEEE' } default { '#CCCCCC' }
            }
            if ("$($msg.Message)".Trim()) { Write-QSOutput $msg.Message $col }
        } else {
            $s = ($msg | Out-String).TrimEnd()
            if ($s) { Write-QSOutput $s '#CCCCCC' }
        }
        $script:QS_Idx.Info++
    }
    $warn = $ps.Streams.Warning
    $cnt = $warn.Count
    while ($script:QS_Idx.Warn -lt $cnt) { Write-QSOutput "[WARN] $($warn[$script:QS_Idx.Warn])" '#FF9800'; $script:QS_Idx.Warn++ }
    $errs = $ps.Streams.Error
    $cnt = $errs.Count
    while ($script:QS_Idx.Err -lt $cnt) {
        $e = $errs[$script:QS_Idx.Err]
        $script:QS_ErrCount++
        Write-QSOutput "[ERROR] $($e.Exception.Message)" '#F44336'
        if ($e.InvocationInfo -and $e.InvocationInfo.ScriptLineNumber -gt 0) { Write-QSOutput "        Zeile $($e.InvocationInfo.ScriptLineNumber): $("$($e.InvocationInfo.Line)".Trim())" '#888888' }
        $script:QS_Idx.Err++
    }
}

function Invoke-HUQSPoll {
    try { Read-HUQSStreams } catch { }
    $spin = @('|', '/', '-', '\')
    $script:QS_Spinner = ($script:QS_Spinner + 1) % 4
    $sec = [int]((Get-Date) - $script:QS_Started).TotalSeconds
    $script:Controls['btnQSRun'].Content = "$($spin[$script:QS_Spinner]) laeuft ... ${sec}s"
    if ($script:QS_AsyncHandle -and -not $script:QS_AsyncHandle.IsCompleted) { return }
    $script:QS_Timer.Stop()
    try { Read-HUQSStreams } catch { }
    $stopped = $script:QS_Stopping
    try { [void]$script:QS_PS.EndInvoke($script:QS_AsyncHandle) }
    catch {
        if (-not $stopped) { Write-QSOutput "[ERROR] $($_.Exception.InnerException.Message)$(if (-not $_.Exception.InnerException) { $_.Exception.Message })" '#F44336' }
    }
    $secs = ((Get-Date) - $script:QS_Started).TotalSeconds
    $dur = [Math]::Round($secs, 1)
    $nObj = $script:QS_Objects.Count
    $result = if ($stopped) { 'Abgebrochen' } elseif ($script:QS_ErrCount) { 'Fehler' } else { 'OK' }
    $tail = "$(if ($script:QS_ErrCount) { ", $($script:QS_ErrCount) Fehler" })$(if ($nObj) { ", $nObj Objekte - Knopf Tabelle" })"
    if ($stopped) { Write-QSOutput "--- Abgebrochen nach ${dur}s$tail ---" '#FF9800' }
    elseif ($script:QS_ErrCount) { Write-QSOutput "--- Fertig mit Fehlern (${dur}s$tail) ---" '#FF9800' }
    else { Write-QSOutput "--- Fertig (${dur}s$tail) ---" '#4CAF50' }
    $lines = if ($script:QS_RunLines) { $script:QS_RunLines.ToArray() } else { @() }
    $script:QS_RunLines = $null
    Add-HUQSHistory -Snippet $script:QS_RunName -Tenants $script:QS_RunTenants -Seconds $secs -Result $result -Errors $script:QS_ErrCount -Objects $nObj -Lines $lines -Code $script:QS_RunCode
    $script:Controls['txtQSStatus'].Text = "Letzter Lauf $(Get-Date -Format 'HH:mm'): $result ($dur s)"
    $script:Controls['txtQSStatus'].Foreground = Get-HUBrush $(if ($result -eq 'OK') { '#4CAF50' } else { '#FF9800' })
    Update-HUQSTableButton
    Reset-HUQSRunner
}

function Reset-HUQSRunner {
    try { if ($script:QS_PS) { $script:QS_PS.Dispose() } } catch { }
    try { if ($script:QS_RS) { $script:QS_RS.Dispose() } } catch { }
    $script:QS_PS = $null; $script:QS_RS = $null; $script:QS_OutputColl = $null; $script:QS_AsyncHandle = $null
    $c = $script:Controls
    $c['btnQSRun'].Content = "$([char]0x25B6) Ausf$([char]0xFC)hren"
    $c['btnQSRun'].IsEnabled = (@(Get-HUQSRunTenants).Count -gt 0)
    $c['btnQSStop'].IsEnabled = $false
}

function Stop-HUQSRun {
    if (-not $script:QS_PS -or -not ($script:QS_Timer -and $script:QS_Timer.IsEnabled)) { return }
    $script:QS_Stopping = $true
    $script:Controls['btnQSStop'].IsEnabled = $false
    Write-QSOutput '[WARN] Abbruch angefordert ...' '#FF9800'
    try { [void]$script:QS_PS.BeginStop($null, $null) } catch { }
}

# ============================================================================
# Ereignisse
# ============================================================================
function Register-HUQuickScriptHandlers {
    $c = $script:Controls

    $c['cmbQSTenant'].Add_SelectionChanged({
        if ($script:TenantSelectBusy) { return }
        $k = Get-HUQSTenantKey
        if ($k) { Set-HUStateValue 'qsTenantKey' $k }
        if ($script:QS_Token -and $k -ne $script:QS_TenantKey) { Disconnect-HUQS; $script:Controls['txtQSStatus'].Text = 'Tenant gewechselt - beim Ausfuehren wird automatisch verbunden' }
        Update-HUSecretDisplay
        Update-HUQSMultiDisplay
    })
    $c['btnQSConnect'].Add_Click({ [void](Connect-HUQS) })
    $c['btnQSDisconnect'].Add_Click({ Disconnect-HUQS })
    $c['btnQSRun'].Add_Click({ Start-HUQSRun })
    $c['btnQSStop'].Add_Click({ Stop-HUQSRun })
    $c['btnQSTable'].Add_Click({ Show-HUQSTable $script:QS_RunName })
    $c['btnQSHistory'].Add_Click({ Show-HUQSHistory })
    Register-HUQSParamHandlers
    $c['btnQSClear'].Add_Click({ $script:Controls['rtbQSOutput'].Document.Blocks.Clear() })
    $c['btnQSCopy'].Add_Click({
        $doc = $script:Controls['rtbQSOutput'].Document
        $txt = [System.Windows.Documents.TextRange]::new($doc.ContentStart, $doc.ContentEnd).Text
        if ("$txt".Trim()) { try { [System.Windows.Clipboard]::SetText($txt) } catch { } }
    })

    $c['btnSnippetNew'].Add_Click({ New-HUQSSnippet })
    $c['btnSnippetFav'].Add_MouseLeftButtonUp({
        if (-not $script:QS_Current) { Write-QSOutput '[INFO] Erst speichern, dann als Favorit markieren.' '#4FC3F7'; return }
        $v = Switch-HUSnippetFavorite $script:QS_Current
        if ($null -ne $v) { $script:QS_CurrentFav = [bool]$v; Update-HUSnippetCombo -Select $script:QS_Current; Update-HUQSSnippetInfo }
    })
    $c['btnSnippetSave'].Add_Click({ [void](Save-HUQSSnippet) })
    $c['btnSnippetSaveAs'].Add_Click({ [void](Save-HUQSSnippet -As) })
    $c['btnSnippetManage'].Add_Click({
        $sel = Show-HUSnippetManager
        if ($sel -and $sel -ne $script:QS_Current) { if (Confirm-HUQSDiscard 'laden') { Open-HUQSSnippet $sel } }
        elseif ($sel) { if (-not (Test-HUQSDirty)) { Open-HUQSSnippet $sel } }
    })
    $c['cmbSnippets'].Add_SelectionChanged({
        if ($script:QS_SuppressSelect) { return }
        $it = $script:Controls['cmbSnippets'].SelectedItem
        if (-not $it -or $it.Name -eq $script:QS_Current) { return }
        if (Confirm-HUQSDiscard 'wechseln') { Open-HUQSSnippet $it.Name }
        else { Update-HUSnippetCombo -Select $script:QS_Current }
    })

    $c['txtQSEditor'].Add_TextChanged({ Update-HUQSSnippetInfo; if ($script:Controls['txtQSEditor'].Text -match '@param' -or $script:QSParamDefs.Count) { Start-HUQSParamRefresh } })
    $c['txtQSEditor'].Add_PreviewMouseWheel({
        param($s, $e)
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
            $fs = $s.FontSize + $(if ($e.Delta -gt 0) { 1 } else { -1 })
            $s.FontSize = [Math]::Max(8, [Math]::Min(32, $fs))
            $e.Handled = $true
        }
    })
}

# Tastenkuerzel (aus dem PreviewKeyDown des Hauptfensters). Rueckgabe $true = behandelt
function Invoke-HUQSKey($e) {
    if ($script:Controls['tabMain'].SelectedItem -ne $script:Controls['tabQuickScript']) { return $false }
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $key = if ("$($e.Key)" -eq 'System') { "$($e.SystemKey)" } else { "$($e.Key)" }
    if (($ctrl -and $key -eq 'Return') -or (-not $ctrl -and $key -eq 'F5')) { if (-not ($script:QS_Timer -and $script:QS_Timer.IsEnabled)) { Start-HUQSRun }; return $true }
    if (-not $ctrl -and $key -eq 'F8') { Start-HUQSRun -Selection; return $true }
    if ($ctrl -and $key -eq 'S') { [void](Save-HUQSSnippet); return $true }
    if ($ctrl -and $key -eq 'N') { New-HUQSSnippet; return $true }
    if (-not $ctrl -and $key -eq 'Escape' -and $script:QS_Timer -and $script:QS_Timer.IsEnabled) { Stop-HUQSRun; return $true }
    return $false
}

function Initialize-HUQuickScript {
    Initialize-HUSnippetFile
    Update-HUQSTenantChecks
    Clear-HUQSHistoryOld
    Update-HUSnippetCombo
    $last = Get-HUStateValue 'lastSnippet'
    if ($last -and @(Get-HUSnippets | Where-Object { $_.name -eq $last }).Count) {
        $script:QS_SuppressSelect = $true
        try { Open-HUQSSnippet $last } finally { $script:QS_SuppressSelect = $false }
        $script:Controls['rtbQSOutput'].Document.Blocks.Clear()
    } else { Update-HUQSSnippetInfo }
    Update-HUQSMultiDisplay
}

function Close-HUQuickScript {
    if ($script:QS_Timer -and $script:QS_Timer.IsEnabled) { $script:QS_Timer.Stop() }
    if ($script:QS_PS) { try { $script:QS_PS.Stop() } catch { }; try { $script:QS_PS.Dispose() } catch { } }
    if ($script:QS_RS) { try { $script:QS_RS.Dispose() } catch { } }
}
