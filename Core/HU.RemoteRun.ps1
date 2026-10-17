#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung: Laeufe ohne Oberflaeche (Snippet, Erweiterung, Teams-Meldung) - Live-Ausgabe in den Zustand $S.
.DESCRIPTION
    Invoke-HURemoteRun laeuft in einem eigenen Hintergrund-Runspace (von UI-Remote.ps1 gestartet). Es oeffnet nie einen
    Dialog (Review 031 B2) und arbeitet je Tenant in einem frischen Runspace. Abbruch ueber $S.CancelReq.
    Jede Zeile geht in den Ringpuffer des Handys und vollstaendig in Logs\Remote\<Datum>.log.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft (Windows PowerShell 5.1).
#>

# PC waehrend eines Laufs wach halten (ES_CONTINUOUS | ES_SYSTEM_REQUIRED); Aus = Normalzustand
function Set-HURemoteAwake([bool]$On) {
    try {
        if (-not ('HURemote.Power' -as [type])) {
            Add-Type -Namespace HURemote -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
        }
        [void][HURemote.Power]::SetThreadExecutionState($(if ($On) { [uint32]0x80000001 } else { [uint32]0x80000000 }))
    } catch { }
}

# Objekt -> eine Textzeile (hoechstens 6 Eigenschaften)
function ConvertTo-HURemoteLine($o) {
    if ($null -eq $o) { return '' }
    if ($o -is [string] -or $o -is [ValueType]) { return "$o" }
    return ((@($o.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | Select-Object -First 6 | ForEach-Object { "$($_.Name): $($_.Value)" })) -join ' | ')
}

# Kennwoerter/Token in Zeilen nie ans Handy (Review 031 B17)
function Protect-HURemoteText([string]$Text, [string[]]$Secrets = @()) {
    $t = "$Text"
    foreach ($s in @($Secrets)) { if ("$s".Length -ge 8) { $t = $t.Replace("$s", '***') } }
    $t = $t -replace 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}', '***'   # JWT (Token)
    $t = $t -replace '(?i)((client_?secret|password|kennwort|passwort)\s*[=:]\s*)\S+', '$1***'
    return $t
}

# Streams eines Runspaces seit dem letzten Mal lesen -> Zeilen
function Read-HURemoteStreams($Ps, $Out, $Pos, $S, [string]$Prefix, [string[]]$Secrets, $Log) {
    $add = {
        param($txt, $lvl)
        $x = Protect-HURemoteText $txt $Secrets
        foreach ($ln in ("$x" -split "`r?`n")) {
            if (-not "$ln".Trim()) { continue }
            Add-HURemoteLineTo $S ("$Prefix$ln") $lvl
            if ($Log) { & $Log ("[$lvl] $Prefix$ln") }
        }
    }
    $info = $Ps.Streams.Information
    while ($Pos.Info -lt $info.Count) { $m = $info[$Pos.Info]; $Pos.Info++; $c = ''; try { $c = "$($m.MessageData.ForegroundColor)" } catch { }; & $add "$($m.MessageData)" $(switch -Regex ($c) { 'Green' { 'OK' } 'Yellow' { 'Warn' } 'Red' { 'Error' } default { 'Info' } }) }
    while ($Pos.Out -lt $Out.Count) { $o = $Out[$Pos.Out]; $Pos.Out++; & $add (ConvertTo-HURemoteLine $o) 'Info' }
    $w = $Ps.Streams.Warning
    while ($Pos.Warn -lt $w.Count) { & $add "$($w[$Pos.Warn].Message)" 'Warn'; $Pos.Warn++ }
    $e = $Ps.Streams.Error
    while ($Pos.Err -lt $e.Count) { $Pos.Errs++; & $add "$($e[$Pos.Err].Exception.Message)" 'Error'; $Pos.Err++ }
}

# Neue Zeilen einer Protokolldatei (Erweiterungen/Teams schreiben ueber Write-HULog)
function Read-HURemoteLogTail([string]$File, $Pos, $S, [string]$Prefix, [string[]]$Secrets, $Log) {
    if (-not (Test-Path -LiteralPath $File)) { return }
    try {
        $fs = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $Pos.Bytes) { return }
            [void]$fs.Seek($Pos.Bytes, 'Begin')
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $Pos.Bytes = $fs.Length
        } finally { $fs.Dispose() }
        foreach ($ln in ($txt -split "`r?`n")) {
            if (-not "$ln".Trim()) { continue }
            $lvl = if ($ln -match '\[ERROR\]') { 'Error' } elseif ($ln -match '\[WARN\]') { 'Warn' } elseif ($ln -match '\[OK\]') { 'OK' } elseif ($ln -match '\[DEBUG\]') { continue } else { 'Info' }
            if ($lvl -eq 'Error') { $Pos.Errs++ }
            # Zeitstempel/Stufe vorne weg - am Handy steht die Uhrzeit schon
            $z = Protect-HURemoteText ($ln -replace '^\[[^\]]*\]\s*\[[^\]]*\]\s*(\S+\s+)?\[[A-Z]+\]\s*', '') $Secrets
            Add-HURemoteLineTo $S ("$Prefix$z") $lvl
            if ($Log) { & $Log ("[$lvl] $Prefix$z") }
        }
    } catch { }
}

# Einen Kind-Runspace ausfuehren, dabei Zeilen weitergeben, Abbruch beachten. Rueckgabe: 'ok' | 'error' | 'cancel'
function Invoke-HURemoteChild($S, [hashtable]$Vars, [string]$Script, [string]$Prefix, [string[]]$Secrets, $Log, [string]$TailFile = '', [datetime]$Deadline = [datetime]::MaxValue) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $ps = $null; $res = 'ok'; $hung = $false
    $pos = @{ Info = 0; Out = 0; Warn = 0; Err = 0; Errs = 0; Bytes = 0L }
    try {
        $rs.Open()
        foreach ($e in $Vars.GetEnumerator()) { $rs.SessionStateProxy.SetVariable([string]$e.Key, $e.Value) }
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($Script)
        $out = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $inp = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $h = $ps.BeginInvoke($inp, $out)
        while (-not $h.IsCompleted) {
            [void]$h.AsyncWaitHandle.WaitOne(250)
            Read-HURemoteStreams $ps $out $pos $S $Prefix $Secrets $Log
            if ($TailFile) { Read-HURemoteLogTail $TailFile $pos $S $Prefix $Secrets $Log }
            if ($S.CancelReq -or (Get-Date) -gt $Deadline) {
                $res = 'cancel'
                if ((Get-Date) -gt $Deadline) { Add-HURemoteLineTo $S "${Prefix}Zeitlimit erreicht - abgebrochen" 'Error' }
                try { $sh = $ps.BeginStop($null, $null); if (-not $sh.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(10))) { $hung = $true } } catch { }
                break
            }
        }
        if (-not $hung) {
            try { [void]$ps.EndInvoke($h) } catch { if ($res -ne 'cancel') { $pos.Errs++; Add-HURemoteLineTo $S ("$Prefix" + (Protect-HURemoteText "$($_.Exception.Message)" $Secrets)) 'Error' } }
            Read-HURemoteStreams $ps $out $pos $S $Prefix $Secrets $Log
            if ($TailFile) { Read-HURemoteLogTail $TailFile $pos $S $Prefix $Secrets $Log }
        }
        if ($res -ne 'cancel' -and $pos.Errs) { $res = 'error' }
    } catch {
        $res = 'error'; Add-HURemoteLineTo $S ("$Prefix" + (Protect-HURemoteText "$($_.Exception.Message)" $Secrets)) 'Error'
    } finally {
        if (-not $hung) { if ($ps) { $ps.Dispose() }; $rs.Dispose() }
    }
    return $res
}

<#
.SYNOPSIS
    Fuehrt einen vom Handy bestaetigten Lauf aus. $Req: @{ Item; Tenants; Values; Target; Live; By }.
    $Settings ist eine Kopie (JSON), $AppRoot der Programmordner. Ergebnis steht in $S.Job.
#>
function Invoke-HURemoteRun($S, $Req, $Settings, [string]$AppRoot, [int]$LimitMin = 60) {
    $it = $Req.Item
    $j = $S.Job
    $j.Title = "$($it.Name)"; $j.Kind = "$($it.Kind)"; $j.By = "$($Req.By)"; $j.Live = [bool]$Req.Live
    $j.Started = Get-Date; $j.Ended = $null; $j.Result = ''; $j.Level = ''; $j.Done = @()
    $names = @{}; foreach ($t in @($Settings.tenants)) { if ($t -and "$($t.key)") { $names["$($t.key)"] = $(if ("$($t.displayName)") { "$($t.displayName)" } else { "$($t.key)" }) } }
    $tenants = @($Req.Tenants)
    $j.Tenants = @($tenants | ForEach-Object { $names["$_"] })
    $deadline = (Get-Date).AddMinutes($LimitMin)
    # vollstaendiges Protokoll des Laufs (Ringpuffer am Handy ist begrenzt, Review 031 B8)
    $logDir = Join-Path $AppRoot 'Logs\Remote'
    try { if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) } } catch { }
    $logFile = Join-Path $logDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
    $log = { param($l) try { [IO.File]::AppendAllText($logFile, ("{0}  {1}`r`n" -f (Get-Date).ToString('HH:mm:ss'), $l), (New-Object Text.UTF8Encoding $false)) } catch { } }.GetNewClosure()
    $secrets = @()
    $S.CancelReq = $null
    Set-HURemoteAwake $true
    $ok = 0; $bad = 0; $cancel = $false
    try {
        Add-HURemoteLineTo $S "=== $($it.Name) - gestartet vom Handy '$($Req.By)'$(if ($Req.Live) { ' - ECHTER LAUF' } else { '' }) ===" 'Head'
        & $log "=== $($it.Name) ($($it.Kind)) vom Handy '$($Req.By)' $(if ($Req.Live) { 'ECHTER LAUF' } else { '' }) Tenants: $($j.Tenants -join ', ')"
        # Pflicht-Hinweis an Teams bei echtem Lauf vom Handy (Review 031 B4): an die Ziele mit "Hinweis bei Problemen" (Kategorie Jobs)
        if ($Req.Live) {
            try {
                Import-Module (Join-Path $AppRoot 'Core\HU.Notify.psm1') -Force -DisableNameChecking -ErrorAction Stop
                Grant-HUSendApproval -Reason 'Hinweis Fernbedienung'
                $r = Send-HUNotify -Category Jobs -Level Warning -Source 'Fernbedienung' -Title "ECHTER LAUF vom Handy: $($it.Name)" -Lines @("Gestartet von '$($Req.By)' am PC $env:COMPUTERNAME", "Tenants: $($j.Tenants -join ', ')") -Preview "Echter Lauf vom Handy: $($it.Name)"
                if (-not $r.Ok) { Add-HURemoteLineTo $S "Teams-Hinweis nicht gesendet: $($r.Text)" 'Warn' }
            } catch { Add-HURemoteLineTo $S "Teams-Hinweis nicht gesendet: $($_.Exception.Message)" 'Warn' }
        }
        switch ("$($it.Kind)") {
            'snippet' {
                $code = "$($it.Code)"
                foreach ($tk in $tenants) {
                    if ($S.CancelReq -or (Get-Date) -gt $deadline) { $cancel = $true; break }
                    $nm = $names["$tk"]
                    Add-HURemoteLineTo $S "--- $nm ---" 'Head'
                    $vars = @{ AppRoot = $AppRoot; Settings = ($Settings | ConvertTo-Json -Depth 20 | ConvertFrom-Json); __Code = $code; __Tk = "$tk"; __Vals = $Req.Values; __Route = $it.Route; __Name = "$($it.Name)"; __Tenants = [string[]]$tenants }
                    $r = Invoke-HURemoteChild $S $vars {
                        foreach ($m in 'HU.Auth', 'HU.Graph', 'HU.Notify') { Import-Module (Join-Path $AppRoot "Core\$m.psm1") -Force -DisableNameChecking -ErrorAction Stop }
                        . (Join-Path $AppRoot 'Core\HU.QSParams.ps1')
                        . (Join-Path $AppRoot 'Core\HU.QSRuntime.ps1')
                        # Teams nur, wenn das Snippet zu einer Meldung gehoert (deren Ziele) - sonst gesperrt
                        if ($__Route) { Grant-HUSendApproval -Reason "Handy: $__Name"; Set-HUNotifyRoute -Name $__Route.Name -TargetIds @($__Route.TargetIds) }
                        $global:TenantKey = $__Tk; $global:Schule = $__Tk; $global:Tenants = $__Tenants
                        $global:Token = Get-HUToken -Tenant $__Tk
                        foreach ($k in @($__Vals.Keys)) { Set-Variable -Name $k -Value $__Vals[$k] -Scope Global }
                        $sb = [scriptblock]::Create($__Code)
                        do { & $sb } while ($false)
                    }.ToString() "" $secrets $log '' $deadline
                    $j.Done = @($j.Done) + @("$($nm): $r")
                    if ($r -eq 'ok') { $ok++ } elseif ($r -eq 'cancel') { $cancel = $true; break } else { $bad++ }
                }
            }
            'ext' {
                foreach ($tk in $tenants) {
                    if ($S.CancelReq -or (Get-Date) -gt $deadline) { $cancel = $true; break }
                    $nm = $names["$tk"]
                    Add-HURemoteLineTo $S "--- $nm ---" 'Head'
                    $tail = Join-Path ([IO.Path]::GetTempPath()) ("hu-remote-{0}.log" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
                    # Probelauf nur, wenn die Erweiterung ihn kann und er am Handy angehakt ist; 'nur lesend' laeuft normal
                    $dry = [bool]($Req.Values -and $Req.Values.ContainsKey('Probelauf') -and $Req.Values['Probelauf'] -eq $true)
                    $vars = @{ AppRoot = $AppRoot; Settings = $Settings; __Tk = "$tk"; __Path = "$($it.Path)"; __Hash = "$($it.Hash)"; __Vals = $Req.Values; __Dry = $dry; __Tail = $tail }
                    $r = Invoke-HURemoteChild $S $vars {
                        foreach ($m in 'HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Extensions', 'HU.Excel', 'HU.Notify') { $p = Join-Path $AppRoot "Core\$m.psm1"; if (Test-Path $p) { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } }
                        Initialize-Logging -LogFilePath $__Tail -MinLevel 'INFO'
                        $ext = @(Get-AllExtensions -SearchPaths @(Join-Path $AppRoot 'Extensions') -ForceRescan | Where-Object { $_.Path -eq $__Path })[0]
                        if (-not $ext) { throw 'Erweiterung nicht gefunden' }
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        try { $h = ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($__Path))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
                        if ($h -ne $__Hash) { throw 'Erweiterung wurde seit der Freigabe geaendert - am PC neu freigeben' }
                        $tok = Get-GraphToken -TenantKey $__Tk -Settings $Settings
                        $cp = @{}; foreach ($k in @($__Vals.Keys)) { if ($k -ne 'Probelauf') { $cp[$k] = $__Vals[$k] } }
                        $p = @{ Extension = $ext; TenantKey = $__Tk; Token = $tok; CustomParameters = $cp }
                        if ($__Dry) { $p.WhatIf = $true }
                        $res = Invoke-ExtensionScript @p
                        if ($res -and $res.PSObject.Properties['Success'] -and -not $res.Success) { throw "$($res.ErrorMessage)" }
                        foreach ($o in @($res.Output)) { if ($o -is [string] -and $o -match '\.(xlsx|html|csv)$') { Write-Host "Report am PC: $(Split-Path $o -Leaf)" -ForegroundColor Green } }
                    }.ToString() "" $secrets $log $tail $deadline
                    Remove-Item -LiteralPath $tail -Force -ErrorAction SilentlyContinue
                    $j.Done = @($j.Done) + @("$($nm): $r")
                    if ($r -eq 'ok') { $ok++ } elseif ($r -eq 'cancel') { $cancel = $true; break } else { $bad++ }
                }
            }
            'teams' {
                $tail = Join-Path ([IO.Path]::GetTempPath()) ("hu-remote-{0}.log" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
                $job = "$($it.JobJson)" | ConvertFrom-Json
                if (-not $it.FixedTenants) { $job.Tenants = @($tenants) }
                if (@($it.Params).Count) { $job.Options | Add-Member -NotePropertyName params -NotePropertyValue ([pscustomobject]$Req.Values) -Force }
                $ids = @(); if ("$($Req.Target)") { $ids = @("$($Req.Target)") }
                $vars = @{ AppRoot = $AppRoot; Settings = $Settings; __Job = $job; __Ids = $ids; __Tail = $tail }
                $r = Invoke-HURemoteChild $S $vars {
                    foreach ($m in 'HU.Logging', 'HU.Auth', 'HU.Tenant', 'HU.Graph', 'HU.Notify', 'HU.TeamsJobs') { $p = Join-Path $AppRoot "Core\$m.psm1"; if (Test-Path $p) { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } }
                    Initialize-Logging -LogFilePath $__Tail -MinLevel 'INFO'
                    Grant-HUSendApproval -Reason 'Handy: Meldung'   # Bestaetigung am Handy ist die Freigabe
                    $res = Invoke-HUTeamsJob -Job $__Job -Settings $Settings -AppRoot $AppRoot -TargetIds $__Ids
                    if ($res.Success) { Write-Host "$($res.Message)" -ForegroundColor Green } else { Write-Host "$($res.Message)" -ForegroundColor Red; Write-Error "$($res.Message)" -ErrorAction Continue }
                }.ToString() "" $secrets $log $tail $deadline
                Remove-Item -LiteralPath $tail -Force -ErrorAction SilentlyContinue
                if ($r -eq 'ok') { $ok++ } elseif ($r -eq 'cancel') { $cancel = $true } else { $bad++ }
            }
            default { Add-HURemoteLineTo $S "Unbekannte Art '$($it.Kind)'" 'Error'; $bad++ }
        }
    } catch {
        $bad++; Add-HURemoteLineTo $S "Fehler: $(Protect-HURemoteText "$($_.Exception.Message)" $secrets)" 'Error'
    } finally {
        Set-HURemoteAwake $false
        $total = @($tenants).Count; if ("$($it.Kind)" -eq 'teams') { $total = 1 }
        if ($cancel) { $j.Result = "abgebrochen ($ok von $total fertig)"; $j.Level = 'Warning' }
        elseif ($bad) { $j.Result = $(if ($ok) { "teilweise: $ok ok, $bad mit Fehler" } else { "Fehler ($bad)" }); $j.Level = 'Error' }
        else { $j.Result = $(if ("$($it.Kind)" -eq 'teams') { 'gesendet' } else { "OK ($ok Tenant$(if ($ok -ne 1) { 's' }))" }); $j.Level = 'OK' }
        $j.Ended = Get-Date
        Add-HURemoteLineTo $S "=== Ende: $($j.Result) ===" $(switch ($j.Level) { 'OK' { 'OK' } 'Warning' { 'Warn' } default { 'Error' } })
        & $log "=== Ende: $($j.Result)"
        $S.CancelReq = $null
    }
}
