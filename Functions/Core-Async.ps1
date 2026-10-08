#Requires -Version 5.1
<#
.SYNOPSIS
    Hintergrund-Aufgaben: RunspacePool + DispatcherTimer (gleicher Aufbau wie HUMig / HU-AdminTool).
.DESCRIPTION
    - OnComplete wird IMMER aufgerufen (auch bei Fehler/Timeout), Ergebnis als Text (Out-String)
    - liefert der Job keine Ausgabe, aber Fehler: "FEHLER: <Text>"
    - Timeout je Aufruf (-TimeoutSec, Standard 120 s); bei Timeout BeginStop (blockiert die Oberflaeche nicht)
    Verwendet fuer: Update-Pruefung, Secret-Pruefung beim Start, Anleitung laden, Versionsliste.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
.EXPORTS
    Initialize-AsyncPool, Invoke-AsyncCommand, Close-AsyncPool, Get-AsyncBusyCount
#>

$script:RunspacePool = $null
# laufende Hintergrund-Aufgaben je Kennung ('*' = alle)
$script:AsyncBusy = @{}
$script:AsyncBusyText = @{}
function Set-HMAsyncBusy([string]$Tag, [int]$Delta, [string]$Text = '') {
    foreach ($k in @('*', $Tag)) {
        if (-not $k) { continue }
        $n = [int]$script:AsyncBusy[$k] + $Delta; if ($n -lt 0) { $n = 0 }
        $script:AsyncBusy[$k] = $n
        if ($Delta -gt 0 -and $Text) { $script:AsyncBusyText[$k] = $Text }
        if ($n -eq 0) { $script:AsyncBusyText[$k] = '' }
    }
}
function Get-AsyncBusyCount([string]$Tag = '*') { return [int]$script:AsyncBusy[$Tag] }

function Initialize-AsyncPool {
    param([int]$PoolSize = 5)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $PoolSize, $iss, $Host)
    $script:RunspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
    $script:RunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $script:RunspacePool.Open()
    Write-Host "[OK] AsyncPool initialized with $PoolSize runspaces (STA)" -ForegroundColor Green
}

function Invoke-AsyncCommand {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Alias('Parameters')]
        [object[]]$ArgumentList,
        [scriptblock]$OnComplete,
        [object]$State = $null,
        [int]$TimeoutSec = 120,
        [string]$BusyTag = '',
        [string]$BusyText = ''
    )
    if (-not $script:RunspacePool) { Write-Host "[ASYNC ERROR] RunspacePool not initialized" -ForegroundColor Red; return }

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    $ps.AddScript($ScriptBlock.ToString()) | Out-Null
    if ($null -ne $ArgumentList) {
        foreach ($arg in $ArgumentList) { $ps.AddArgument($arg) | Out-Null }
    }

    $handle    = $ps.BeginInvoke()
    $startTime = Get-Date
    # Anzeige "laeuft": die Timer-Closure sieht keine Skript-Funktionen -> Funktion als Scriptblock mitgeben
    $busyFn    = ${function:Set-HMAsyncBusy}
    $busyTag   = $BusyTag
    try { & $busyFn $busyTag 1 $BusyText } catch { }
    $completed = [ref]$false
    $timeout   = $TimeoutSec
    $stateObj  = $State

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $stopState = @{ Handle = $null }
    $timer.Add_Tick({
        if ($completed.Value) {
            # Nach Timeout: warten bis BeginStop fertig ist, dann aufraeumen
            if ($stopState.Handle -and $stopState.Handle.IsCompleted) {
                $timer.Stop()
                try { $ps.EndStop($stopState.Handle) } catch { }
                try { $ps.Dispose() } catch { }
                $stopState.Handle = $null
            }
            return
        }
        if ($handle.IsCompleted) {
            $timer.Stop()
            $completed.Value = $true
            try { & $busyFn $busyTag -1 } catch { }
            $resultStr = $null
            try {
                $rawResult = $ps.EndInvoke($handle)
                if ($rawResult -and $rawResult.Count -gt 0) {
                    $resultStr = ($rawResult | Out-String).Trim()
                }
                if ([string]::IsNullOrWhiteSpace($resultStr) -and $ps.Streams.Error.Count -gt 0) {
                    $errs = @($ps.Streams.Error | ForEach-Object { $_.ToString() } | Where-Object { $_ } | Select-Object -Unique)
                    $resultStr = 'FEHLER: ' + ($errs -join ' | ')
                }
            }
            catch {
                $msg = $_.Exception.Message
                if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
                $resultStr = "FEHLER: $msg"
            }
            finally {
                try { $ps.Dispose() } catch { }
            }
            if ($OnComplete) {
                try { & $OnComplete $resultStr $stateObj }
                catch { Write-Host "[ASYNC OnComplete ERROR] $($_.Exception.Message)" -ForegroundColor Red }
            }
        }
        elseif (((Get-Date) - $startTime).TotalSeconds -gt $timeout) {
            $completed.Value = $true
            try { & $busyFn $busyTag -1 } catch { }
            # BeginStop statt Stop -> blockiert den UI-Thread nicht. Timer laeuft weiter bis Stop fertig -> dann Dispose.
            try { $stopState.Handle = $ps.BeginStop($null, $null) } catch { $stopState.Handle = $null }
            Write-Host "[ASYNC TIMEOUT] Job nach ${timeout}s abgebrochen" -ForegroundColor Yellow
            if ($OnComplete) {
                try { & $OnComplete "FEHLER: Timeout - keine Antwort nach $timeout Sekunden (Job abgebrochen)" $stateObj }
                catch { Write-Host "[ASYNC OnComplete ERROR] $($_.Exception.Message)" -ForegroundColor Red }
            }
            if (-not $stopState.Handle) { $timer.Stop(); try { $ps.Dispose() } catch { } }
        }
    }.GetNewClosure())
    $timer.Start()
}

function Close-AsyncPool {
    if ($script:RunspacePool) {
        try {
            $script:RunspacePool.Close()
            $script:RunspacePool.Dispose()
        } catch { }
        $script:RunspacePool = $null
        Write-Host "[OK] AsyncPool closed" -ForegroundColor Green
    }
}
