#Requires -Version 5.1
<#
.SYNOPSIS
    Hintergrund-Auftraege fuer die Reiter Apps und Wartung: eigener Runspace, Live-Protokoll in eine RichTextBox.
.DESCRIPTION
    Start-HUJob -Name 'Apps' -Code { ... } -Vars @{ ... } -Output $rtb -OnDone { param($Result, $Errors) ... }
    Im Auftrag stehen bereit: HU.Logging/HU.Auth/HU.Tenant/HU.Graph/HU.Intune, $AppRoot, $Settings und alle -Vars.
    Write-HULog im Auftrag erscheint sofort in -Output (Datei wird alle 0,4 s nachgelesen).
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:HUJobs = @{}

function Add-HURtbLine($Rtb, [string]$Text, [string]$Color = '#CCCCCC') {
    if (-not $Rtb) { return }
    $p = New-Object System.Windows.Documents.Paragraph
    $r = New-Object System.Windows.Documents.Run($Text)
    $r.Foreground = Get-HUBrush $Color
    [void]$p.Inlines.Add($r)
    $p.Margin = [System.Windows.Thickness]::new(0)
    $Rtb.Document.Blocks.Add($p)
    while ($Rtb.Document.Blocks.Count -gt 1500) { $Rtb.Document.Blocks.Remove($Rtb.Document.Blocks.FirstBlock) }
    $Rtb.ScrollToEnd()
}

function Get-HULogLineColor([string]$Line) {
    if ($Line -match '\[ERROR\]') { return '#FF5252' }
    if ($Line -match '\[WARN\]') { return '#FFB74D' }
    if ($Line -match '\[OK\]') { return '#81C784' }
    if ($Line -match '\[DEBUG\]') { return '#777777' }
    return '#90CAF9'
}

function Test-HUJobRunning([string]$Name) {
    $j = $script:HUJobs[$Name]
    return ($j -and -not $j.Handle.IsCompleted)
}

function Start-HUJob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Code,
        [hashtable]$Vars = @{},
        $Output = $null,
        [scriptblock]$OnDone = $null
    )
    if (Test-HUJobRunning $Name) { Show-HUMessage 'Es laeuft bereits ein Auftrag - bitte warten.' -Icon Warning; return $false }
    $log = Join-Path ([IO.Path]::GetTempPath()) ("hu-job-{0}-{1}.log" -f $Name, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('AppRoot', $script:AppRoot)
    $rs.SessionStateProxy.SetVariable('Settings', $script:Settings)
    $rs.SessionStateProxy.SetVariable('__JobLog', $log)
    $rs.SessionStateProxy.SetVariable('__JobCode', $Code.ToString())
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            foreach ($m in 'HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Intune') {
                Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking -ErrorAction Stop
            }
            Initialize-Logging -LogFilePath $__JobLog -MinLevel 'INFO'
            & ([scriptblock]::Create($__JobCode))
        })
    $state = @{ Name = $Name; PS = $ps; RS = $rs; Log = $log; Pos = 0L; Output = $Output; OnDone = $OnDone; Started = Get-Date; Timer = $null; Handle = $null }
    $state.Handle = $ps.BeginInvoke()
    $script:HUJobs[$Name] = $state
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(400)
    $t.Tag = $Name
    $t.Add_Tick({ Update-HUJob "$($this.Tag)" })
    $state.Timer = $t
    $t.Start()
    return $true
}

function Read-HUJobLog($State) {
    if (-not (Test-Path -LiteralPath $State.Log)) { return }
    try {
        $fs = [IO.File]::Open($State.Log, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $State.Pos) { return }
            [void]$fs.Seek($State.Pos, 'Begin')
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $State.Pos = $fs.Length
        } finally { $fs.Dispose() }
        foreach ($ln in ($txt -split "`r?`n")) { if ($ln.Trim()) { Add-HURtbLine $State.Output $ln (Get-HULogLineColor $ln) } }
    } catch { }
}

function Update-HUJob([string]$Name) {
    $s = $script:HUJobs[$Name]
    if (-not $s) { return }
    Read-HUJobLog $s
    if (-not $s.Handle.IsCompleted) { return }
    $s.Timer.Stop()
    $result = $null; $errs = @()
    try { $result = $s.PS.EndInvoke($s.Handle) } catch { $errs += $_.Exception.InnerException.Message; if (-not $errs[-1]) { $errs[-1] = $_.Exception.Message } }
    $errs += @($s.PS.Streams.Error | ForEach-Object { "$($_.Exception.Message)" })
    Read-HUJobLog $s
    foreach ($e in $errs) { if ($e) { Add-HURtbLine $s.Output "[FEHLER] $e" '#FF5252' } }
    try { $s.PS.Dispose(); $s.RS.Dispose() } catch { }
    Remove-Item -LiteralPath $s.Log -Force -ErrorAction SilentlyContinue
    $secs = [Math]::Round(((Get-Date) - $s.Started).TotalSeconds, 1)
    Add-HURtbLine $s.Output "--- fertig ($secs s) ---" '#666666'
    if ($s.OnDone) { try { & $s.OnDone @($result) @($errs | Where-Object { $_ }) } catch { Add-HURtbLine $s.Output "[FEHLER] $($_.Exception.Message)" '#FF5252' } }
}
