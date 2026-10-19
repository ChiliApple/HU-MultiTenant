<#
.SYNOPSIS
    Prueft ein Quick-Script-Snippet fuer HU-MultiTenant gegen die Regeln der Laufzeit (Windows PowerShell 5.1).
.DESCRIPTION
    Rein statisch (Parser/AST), es wird nichts ausgefuehrt und nichts verbunden. Laeuft unter Windows PowerShell 5.1 und PowerShell 7.
    FEHLER  = das Snippet laeuft so nicht oder ist unsicher - muss behoben werden.
    WARNUNG = pruefen und im Zweifel anpassen.
    Rueckgabe: Befundobjekte (Stufe, Regel, Zeile, Text). Ohne -Quiet zusaetzlich Textausgabe und Exitcode 1 bei Fehlern.
.PARAMETER Path
    Datei mit dem Snippet-Code (UTF-8).
.PARAMETER Code
    Alternativ der Code als Text.
.PARAMETER Quiet
    Keine Textausgabe, kein Exitcode (fuer Tests).
.EXAMPLE
    .\Test-HUSnippet.ps1 -Path .\mein-snippet.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [string]$Code,
    [switch]$Quiet
)

#region Gemeinsam (in Test-HUSnippet.ps1 und Test-HUExtension.ps1 identisch halten)
$script:Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding([string]$Level, [string]$Rule, [int]$Line, [string]$Text) {
    $script:Findings.Add([pscustomobject]@{ Stufe = $Level; Regel = $Rule; Zeile = $Line; Text = $Text })
}
function Get-HUNodes($Ast, [scriptblock]$Filter) {
    return @($Ast.FindAll($Filter, $true))
}
function Get-HUNamedArg($Cmd, [string]$Name) {
    $el = @($Cmd.CommandElements)
    for ($i = 0; $i -lt $el.Count; $i++) {
        if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $el[$i].ParameterName -eq $Name) {
            if ($el[$i].Argument) { return $el[$i].Argument }
            if ($i + 1 -lt $el.Count -and $el[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { return $el[$i + 1] }
            return $null
        }
    }
    return $null
}
function Test-HUHasParam($Cmd, [string]$Name) {
    foreach ($e in @($Cmd.CommandElements)) {
        if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq $Name) { return $true }
    }
    return $false
}
function Get-HULeadingString($Ast) {
    if ($null -eq $Ast) { return $null }
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $Ast.Value }
    if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $Ast.Value }
    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) { return (Get-HULeadingString $Ast.Pipeline) }
    if ($Ast -is [System.Management.Automation.Language.PipelineAst]) {
        if (@($Ast.PipelineElements).Count -eq 1) { return (Get-HULeadingString $Ast.PipelineElements[0]) }
        return $null
    }
    if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) { return (Get-HULeadingString $Ast.Expression) }
    if ($Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($Ast.Operator)" -eq 'Plus') { return (Get-HULeadingString $Ast.Left) }
    return $null
}
function Find-HUPs7Syntax($Ast, [string]$Rule) {
    # Knotentypen, die es in Windows PowerShell 5.1 nicht gibt (unter 5.1 meldet schon der Parser einen Syntaxfehler)
    $seen = @{}
    foreach ($n in (Get-HUNodes $Ast { $true })) {
        $t = $n.GetType().Name
        $what = $null
        if ($t -eq 'TernaryExpressionAst') { $what = 'Ternary-Operator (? :)' }
        elseif ($t -eq 'PipelineChainAst') { $what = 'Pipeline-Kette (&& oder ||)' }
        elseif ($t -eq 'BinaryExpressionAst' -and "$($n.Operator)" -eq 'QuestionQuestion') { $what = 'Null-Coalescing (??)' }
        elseif ($t -eq 'AssignmentStatementAst' -and "$($n.Operator)" -eq 'QuestionQuestionEquals') { $what = 'Null-Coalescing-Zuweisung (??=)' }
        elseif (($t -eq 'MemberExpressionAst' -or $t -eq 'InvokeMemberExpressionAst' -or $t -eq 'IndexExpressionAst') -and $n.PSObject.Properties['NullConditional'] -and $n.NullConditional) { $what = 'Null-Conditional (?. oder ?[])' }
        elseif ($t -eq 'CommandAst') {
            $cn = "$($n.GetCommandName())"
            if ($cn -eq 'ForEach-Object' -and (Test-HUHasParam $n 'Parallel')) { $what = 'ForEach-Object -Parallel' }
            foreach ($pair in @(@('ConvertFrom-Json', 'AsHashtable'), @('Get-Content', 'AsByteStream'), @('Invoke-RestMethod', 'SkipHttpErrorCheck'), @('Invoke-WebRequest', 'SkipHttpErrorCheck'), @('Invoke-RestMethod', 'SkipCertificateCheck'), @('Get-Date', 'AsUTC'), @('Invoke-RestMethod', 'Authentication'))) {
                if ($cn -eq $pair[0] -and (Test-HUHasParam $n $pair[1])) { $what = "$($pair[0]) -$($pair[1]) (nur PowerShell 7)" }
            }
        }
        if ($what) {
            $key = "$($n.Extent.StartLineNumber)|$what"
            if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; Add-Finding 'FEHLER' $Rule $n.Extent.StartLineNumber "$what gibt es in Windows PowerShell 5.1 nicht" }
        }
    }
}
function Test-HUSecretUse($Ast, [string]$VarName, [string]$Rule) {
    # Token/Secret darf nicht ausgegeben, in Zeichenketten gebaut oder gespeichert werden
    $outCmds = @('Write-Host', 'Write-Output', 'Write-Warning', 'Write-Error', 'Write-Verbose', 'Write-Information', 'Write-HULog', 'Write-HULogInfo', 'Write-HULogOK', 'Write-HULogWarn', 'Write-HULogError', 'Write-HULogDebug', 'Out-String', 'Out-File', 'Set-Content', 'Add-Content', 'Export-Csv', 'Send-HUNotify', 'Format-List', 'Format-Table')
    foreach ($v in (Get-HUNodes $Ast { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] })) {
        if ($v.VariablePath.UserPath -ne $VarName) { continue }
        $p = $v.Parent
        $depth = 0
        $bad = $null
        while ($p -and $depth -lt 12) {
            if ($p -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $bad = "`$$VarName steht in einer Zeichenkette (nie selbst Header bauen, nie ausgeben)"; break }
            if ($p -is [System.Management.Automation.Language.CommandAst]) {
                $cn = "$($p.GetCommandName())"
                if ($outCmds -contains $cn) { $bad = "`$$VarName wird an $cn uebergeben (Ausgabe/Speichern)" }
                break
            }
            if ($p -is [System.Management.Automation.Language.CommandExpressionAst]) {
                if ($p.Parent -is [System.Management.Automation.Language.PipelineAst] -and -not ($p.Parent.Parent -is [System.Management.Automation.Language.AssignmentStatementAst])) { $bad = "`$$VarName steht allein in einer Zeile und landet in der Ausgabe" }
                break
            }
            if ($p -is [System.Management.Automation.Language.AssignmentStatementAst]) { break }
            $p = $p.Parent
            $depth++
        }
        if ($bad) { Add-Finding 'FEHLER' $Rule $v.Extent.StartLineNumber $bad }
    }
}
# Graph-Aufrufe (Invoke-GraphRequest, ...WithRetry, ...All): Parameter, Methode, Body, Endpoint. Rueckgabe: aendernde Aufrufe.
function Test-HUGraphCalls($Cmds, [string]$Pfx) {
    $graphFns = @('Invoke-GraphRequest', 'Invoke-GraphRequestWithRetry', 'Invoke-GraphRequestAll', 'Invoke-AdminGraphRequest')
    $rule = "${Pfx}08"
    $mut = @()
    foreach ($c in @($Cmds | Where-Object { $_ })) {
        $cn = "$($c.GetCommandName())"
        $ln = $c.Extent.StartLineNumber
        if ($cn -eq 'Invoke-DeviceSync') { $mut += [pscustomobject]@{ Line = $ln; Cmd = $cn; Call = $c; Method = 'POST' }; continue }
        if ($graphFns -notcontains $cn) { continue }
        $allowed = switch ($cn) {
            'Invoke-GraphRequestWithRetry' { @('Token', 'Endpoint', 'Method', 'Body', 'TenantKey', 'Settings', 'MaxRetries', 'ApiVersion') }
            'Invoke-GraphRequestAll' { @('Token', 'Endpoint', 'TenantKey', 'Settings', 'MaxPages') }
            default { @('Token', 'Endpoint', 'Method', 'Body', 'ApiVersion', 'ContentType') }
        }
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction')
        foreach ($e in @($c.CommandElements)) {
            if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $pn = $e.ParameterName
            $hit = @($allowed + $common | Where-Object { $_.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase) })
            if (-not $hit.Count) {
                $hint = if ($pn -in @('Uri', 'Headers', 'UseBasicParsing')) { ' (das sind Parameter von Invoke-RestMethod)' } else { '' }
                Add-Finding 'FEHLER' $rule $ln "$cn hat keinen Parameter -$pn$hint - vorhanden: $(($allowed | ForEach-Object { '-' + $_ }) -join ' ')."
            }
        }
        if (-not (Test-HUHasParam $c 'Token')) { Add-Finding 'FEHLER' $rule $ln "$cn ohne -Token (`$Token uebergeben)." }
        if (-not (Test-HUHasParam $c 'Endpoint')) { Add-Finding 'FEHLER' $rule $ln "$cn ohne -Endpoint." }
        $methodArg = Get-HUNamedArg $c 'Method'
        $methodVal = $null
        if ($methodArg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $methodVal = $methodArg.Value.ToUpper() }
        if ($methodArg) {
            if ($methodVal -and $methodVal -notin @('GET', 'POST', 'PATCH', 'DELETE')) { Add-Finding 'FEHLER' $rule $ln "-Method $methodVal gibt es hier nicht (erlaubt: GET, POST, PATCH, DELETE; PUT ist nicht moeglich)." }
            if (-not $methodVal -or $methodVal -ne 'GET') { $mut += [pscustomobject]@{ Line = $ln; Cmd = $cn; Call = $c; Method = $(if ($methodVal) { $methodVal } else { '?' }) } }
        }
        if ($cn -eq 'Invoke-GraphRequestAll' -and $methodArg) { Add-Finding 'FEHLER' $rule $ln 'Invoke-GraphRequestAll liest nur (GET) und kennt kein -Method.' }
        $bodyArg = Get-HUNamedArg $c 'Body'
        if ($bodyArg) {
            if ($bodyArg -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $bodyArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { Add-Finding 'FEHLER' $rule $ln '-Body ist eine Hashtable (@{ ... }), kein JSON-Text - die Funktion wandelt selbst um.' }
            if (@(Get-HUNodes $bodyArg { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$($n.GetCommandName())" -eq 'ConvertTo-Json' }).Count) { Add-Finding 'FEHLER' $rule $ln '-Body nicht mit ConvertTo-Json uebergeben - eine Hashtable genuegt, sonst wird doppelt umgewandelt.' }
            if ($methodVal -eq 'DELETE' -or $methodVal -eq 'GET') { Add-Finding 'WARNUNG' $rule $ln "-Body wird bei $methodVal nicht gesendet (nur bei POST und PATCH)." }
        }
        $epArg = Get-HUNamedArg $c 'Endpoint'
        $ep = Get-HULeadingString $epArg
        if ($ep) {
            $epT = $ep.Trim()
            if ($epT -match '^/?(v1\.0|beta)/') { Add-Finding 'FEHLER' $rule $ln "Endpoint '$epT': Version nicht in den Pfad schreiben - -ApiVersion beta oder die absolute Adresse https://graph.microsoft.com/beta/... verwenden." }
            if ($epT -match '^https?://' -and $epT -notmatch '^https://graph\.microsoft\.com/') { Add-Finding 'FEHLER' $rule $ln "Endpoint '$epT': nur https://graph.microsoft.com ist erlaubt." }
            if ($epT -match '^[^/h]' -and $epT -notmatch '^https://') { Add-Finding 'WARNUNG' $rule $ln "Endpoint '$epT' sollte mit / beginnen." }
            if ($cn -eq 'Invoke-GraphRequestAll' -and $epT -match '^/?(me|users/[^/?]+|groups/[^/?]+|devices/[^/?]+|servicePrincipals/[^/?]+|applications/[^/?]+|deviceManagement/managedDevices/[^/?]+|organization/[^/?]+)(\?.*)?$') {
                Add-Finding 'FEHLER' $rule $ln "Endpoint '$epT' liefert ein Einzelobjekt - Invoke-GraphRequestAll gibt dafuer NICHTS zurueck. Invoke-GraphRequest verwenden."
            }
            if ($epT -match '[?&]\$count=true|\$search=') { Add-Finding 'WARNUNG' $rule $ln 'Erweiterte Abfragen (ConsistencyLevel: eventual, $count, $search) werden nicht unterstuetzt - es gibt keinen Parameter fuer eigene Header; clientseitig filtern.' }
        }
        if ($epArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $epArg.Extent.Text -match '\$(select|filter|top|expand|orderby|skip)\b' -and $epArg.Extent.Text -notmatch '`\$(select|filter|top|expand|orderby|skip)') {
            Add-Finding 'FEHLER' $rule $ln 'In einer Zeichenkette mit doppelten Anfuehrungszeichen wird $select/$filter/$top als Variable gelesen - einfache Anfuehrungszeichen oder `$ davor schreiben.'
        }
    }
    return $mut
}
# Jede aendernde Stelle muss im Probelauf uebersprungen werden ($GuardName = Name des Probelauf-Schalters).
# Abgeleitete Variablen zaehlen mit, z.B. $live = (-not $WhatIf) -and ($Bestaetigung -eq $TenantKey)
function Test-HUGuard($Ast, $Mutations, [string]$GuardName, [string]$Pfx) {
    $rule = "${Pfx}11"
    $gn = [regex]::Escape($GuardName)
    $names = @(@{ Name = $GuardName; Live = $false })
    foreach ($a in (Get-HUNodes $Ast { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] })) {
        $l = $a.Left
        if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
        if ($l -isnot [System.Management.Automation.Language.VariableExpressionAst] -or $l.VariablePath.UserPath -eq $GuardName) { continue }
        $rt = $a.Right.Extent.Text
        if ($rt -match ('\$' + $gn + '\b')) {
            $names += @{ Name = $l.VariablePath.UserPath; Live = [bool]($rt -match ('(-not|!)\s*\(?\s*\$' + $gn + '\b')) }
        }
    }
    foreach ($m in $Mutations) {
        $state = 'none'
        $child = $m.Call
        $p = $m.Call.Parent
        $d = 0
        while ($p -and $d -lt 60 -and $state -eq 'none') {
            if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                $inElse = $p.ElseClause -and $child.Extent.StartOffset -ge $p.ElseClause.Extent.StartOffset -and $child.Extent.EndOffset -le $p.ElseClause.Extent.EndOffset
                foreach ($cl in @($p.Clauses)) {
                    $cond = $cl.Item1.Extent.Text
                    $inBody = $child.Extent.StartOffset -ge $cl.Item2.Extent.StartOffset -and $child.Extent.EndOffset -le $cl.Item2.Extent.EndOffset
                    foreach ($nm in $names) {
                        $nx = [regex]::Escape($nm.Name)
                        if ($cond -notmatch ('\$' + $nx + '\b')) { continue }
                        $neg = ($cond -match ('(-not|!)\s*\(?\s*\$' + $nx + '\b')) -or ($cond -match ('\$' + $nx + '\s+-eq\s+\$false'))
                        $liveWhenTrue = if ($nm.Live) { -not $neg } else { $neg }   # Zweig laeuft nur im echten Lauf
                        if ($inBody) { $state = $(if ($liveWhenTrue) { 'ok' } else { 'reversed' }); break }
                        if ($inElse) { $state = $(if ($liveWhenTrue) { 'reversed' } else { 'ok' }); break }
                    }
                    if ($state -ne 'none') { break }
                }
            }
            $child = $p
            $p = $p.Parent
            $d++
        }
        if ($state -eq 'none') {
            # Early-Exit-Muster: if (<Probelauf>) { ...; continue/return/break } weiter oben im selben Block
            $blk = $m.Call.Parent
            $dd = 0
            while ($blk -and -not ($blk -is [System.Management.Automation.Language.StatementBlockAst] -or $blk -is [System.Management.Automation.Language.NamedBlockAst]) -and $dd -lt 60) { $blk = $blk.Parent; $dd++ }
            if ($blk) {
                foreach ($st in @($blk.Statements)) {
                    if ($st.Extent.StartOffset -ge $m.Call.Extent.StartOffset) { break }
                    if ($st -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
                    $cond = $st.Clauses[0].Item1.Extent.Text
                    foreach ($nm in $names) {
                        $nx = [regex]::Escape($nm.Name)
                        if ($cond -notmatch ('\$' + $nx + '\b')) { continue }
                        $neg = $cond -match ('(-not|!)\s*\(?\s*\$' + $nx + '\b')
                        $dryWhenTrue = if ($nm.Live) { $neg } else { -not $neg }
                        if ($dryWhenTrue -and $st.Clauses[0].Item2.Extent.Text -match '\b(continue|return|break)\b') { $state = 'ok' }
                    }
                }
            }
        }
        if ($state -eq 'reversed') { Add-Finding 'FEHLER' $rule $m.Line "Diese aendernde Stelle wird ausgefuehrt, WENN der Probelauf aktiv ist (`$$GuardName) - die Bedingung ist vertauscht (Probelauf darf nichts aendern)." }
        elseif ($state -eq 'none') { Add-Finding 'FEHLER' $rule $m.Line "Diese aendernde Stelle steht nicht hinter einer Abfrage von `$$GuardName und wuerde auch im Probelauf ausgefuehrt." }
    }
}
# Fehlerobjekt IsError, verworfene Ergebnisse, unvollstaendige Listen
function Test-HUResultHandling($Cmds, $Mutations, [string]$Code, [string]$Pfx) {
    $rule = "${Pfx}12"
    $Cmds = @($Cmds | Where-Object { $_ })
    $Mutations = @($Mutations | Where-Object { $_ })
    $single = @($Cmds | Where-Object { "$($_.GetCommandName())" -in @('Invoke-GraphRequest', 'Invoke-GraphRequestWithRetry', 'Invoke-AdminGraphRequest') })
    if ($single.Count -and $Code -notmatch 'IsError') {
        Add-Finding 'WARNUNG' $rule $single[0].Extent.StartLineNumber 'Invoke-GraphRequest liefert bei HTTP-Fehlern KEINE Ausnahme, sondern ein Objekt mit IsError/StatusCode/ErrorMessage - das Ergebnis muss auf IsError geprueft werden.'
    }
    foreach ($m in $Mutations) {
        if ($m.Cmd -eq 'Invoke-DeviceSync') { continue }
        $par = $m.Call.Parent
        if ($par -is [System.Management.Automation.Language.PipelineAst] -and ($par.Parent -is [System.Management.Automation.Language.NamedBlockAst] -or $par.Parent -is [System.Management.Automation.Language.StatementBlockAst])) {
            Add-Finding 'WARNUNG' $rule $m.Line "Das Ergebnis dieses $($m.Method)-Aufrufs wird verworfen - ein Fehler (IsError) bliebe unbemerkt."
        }
    }
    $allCalls = @($Cmds | Where-Object { "$($_.GetCommandName())" -eq 'Invoke-GraphRequestAll' })
    if ($allCalls.Count) {
        $hasWv = @($allCalls | Where-Object { Test-HUHasParam $_ 'WarningVariable' }).Count
        if (-not $hasWv -and $Code -notmatch '3>&1') {
            Add-Finding 'WARNUNG' $rule $allCalls[0].Extent.StartLineNumber 'Bricht eine Seite der Abfrage ab, liefert Invoke-GraphRequestAll die bis dahin gelesenen Eintraege und nur eine Warnung - mit -WarningVariable wv -WarningAction SilentlyContinue abfangen und bei $wv abbrechen (besonders vor aendernden Aufrufen).'
        }
    }
}
# Passen die angegebenen Rechte zu den Endpunkten? (nur Hinweise)
function Test-HUPermCoverage($Cmds, $Mutations, [string[]]$Perms, [string]$Pfx) {
    $rule = "${Pfx}15"
    $Cmds = @($Cmds | Where-Object { $_ })
    $Mutations = @($Mutations | Where-Object { $_ })
    $graphFns = @('Invoke-GraphRequest', 'Invoke-GraphRequestWithRetry', 'Invoke-GraphRequestAll', 'Invoke-AdminGraphRequest')
    $map = @(
        @{ Rx = '^/?users\b'; Any = @('User.Read.All', 'User.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All', 'User.ReadBasic.All') },
        @{ Rx = '^/?groups\b'; Any = @('Group.Read.All', 'Group.ReadWrite.All', 'GroupMember.Read.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All') },
        @{ Rx = '^/?devices\b'; Any = @('Device.Read.All', 'Directory.Read.All', 'Directory.ReadWrite.All', 'Device.ReadWrite.All') },
        @{ Rx = '^/?deviceManagement/managedDevices'; Any = @('DeviceManagementManagedDevices.Read.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All') },
        @{ Rx = '^/?deviceManagement/(deviceConfigurations|configurationPolicies|deviceCompliancePolicies|windowsFeatureUpdateProfiles|windowsQualityUpdateProfiles|intents|templates|groupPolicyConfigurations)'; Any = @('DeviceManagementConfiguration.Read.All', 'DeviceManagementConfiguration.ReadWrite.All') },
        @{ Rx = '^/?deviceManagement/windowsAutopilot'; Any = @('DeviceManagementServiceConfig.Read.All', 'DeviceManagementServiceConfig.ReadWrite.All') },
        @{ Rx = '^/?deviceManagement/(deviceManagementScripts|deviceHealthScripts|deviceShellScripts)'; Any = @('DeviceManagementScripts.Read.All', 'DeviceManagementScripts.ReadWrite.All') },
        @{ Rx = '^/?deviceAppManagement'; Any = @('DeviceManagementApps.Read.All', 'DeviceManagementApps.ReadWrite.All') },
        @{ Rx = '^/?organization\b'; Any = @('Organization.Read.All', 'Organization.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All') },
        @{ Rx = '^/?subscribedSkus\b'; Any = @('Organization.Read.All', 'Directory.Read.All', 'LicenseAssignment.Read.All', 'User.Read.All', 'Directory.ReadWrite.All') },
        @{ Rx = '^/?(identity/conditionalAccess|policies/conditionalAccessPolicies)'; Any = @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess') },
        @{ Rx = '^/?(applications|servicePrincipals)\b'; Any = @('Application.Read.All', 'Application.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All') },
        @{ Rx = '^/?auditLogs/'; Any = @('AuditLog.Read.All') },
        @{ Rx = '^/?(reports|beta/reports)/'; Any = @('Reports.Read.All', 'AuditLog.Read.All') },
        @{ Rx = '^/?(directoryRoles|roleManagement)'; Any = @('RoleManagement.Read.Directory', 'RoleManagement.ReadWrite.Directory', 'Directory.Read.All', 'Directory.ReadWrite.All') },
        @{ Rx = '^/?security/'; Any = @('SecurityAlert.Read.All', 'SecurityEvents.Read.All', 'SecurityIncident.Read.All', 'SecurityAlert.ReadWrite.All') }
    )
    $seenMap = @{}
    foreach ($c in @($Cmds | Where-Object { $graphFns -contains "$($_.GetCommandName())" })) {
        $epText = "$(Get-HULeadingString (Get-HUNamedArg $c 'Endpoint'))".Trim()
        if (-not $epText) { continue }
        $epPath = $epText -replace '^https://graph\.microsoft\.com/(v1\.0|beta)', ''
        foreach ($mp in $map) {
            if ($epPath -match $mp.Rx) {
                $have = @($mp.Any | Where-Object { $Perms -contains $_ })
                $k = "$($mp.Rx)"
                if (-not $have.Count -and -not $seenMap.ContainsKey($k)) {
                    $seenMap[$k] = $true
                    Add-Finding 'WARNUNG' $rule $c.Extent.StartLineNumber "Endpoint '$epText': bei den Rechten fehlt ein passendes (eines davon: $($mp.Any -join ', '))."
                }
                break
            }
        }
        if ("$($c.Extent.Text)" -match 'signInActivity' -or $epText -match '^/?auditLogs/') {
            if ($Perms -notcontains 'AuditLog.Read.All' -and -not $seenMap.ContainsKey('signin')) { $seenMap['signin'] = $true; Add-Finding 'WARNUNG' $rule $c.Extent.StartLineNumber 'signInActivity / auditLogs brauchen zusaetzlich AuditLog.Read.All (und User.Read.All).' }
        }
    }
    if (@($Mutations).Count -and $Perms.Count -and -not @($Perms | Where-Object { $_ -match 'ReadWrite|PrivilegedOperations|\.Write\.' }).Count) {
        Add-Finding 'WARNUNG' $rule $Mutations[0].Line 'Es werden Daten geaendert, bei den Rechten steht aber kein schreibendes (ReadWrite / PrivilegedOperations).'
    }
}
# Ein Recht pruefen: Name gueltig? ($true = ok)
function Test-HUPermName([string]$Name) {
    return ($Name -match '^[A-Za-z][A-Za-z0-9\-]*(\.[A-Za-z][A-Za-z0-9\-]*)+$')
}
#endregion Gemeinsam

# ---------------------------------------------------------------------------
# Eingabe lesen
# ---------------------------------------------------------------------------
if (-not $Code) {
    if (-not $Path) { throw 'Bitte -Path oder -Code angeben.' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Datei nicht gefunden: $Path" }
    $Code = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)
}
$Code = $Code.TrimStart([char]0xFEFF)
$lines = @($Code -split "`r?`n")

$tokens = $null
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errs)

# S01 Syntax
foreach ($e in @($errs)) { Add-Finding 'FEHLER' 'S01' $e.Extent.StartLineNumber "Syntaxfehler: $($e.Message)" }

# S02 PowerShell-7-Syntax
Find-HUPs7Syntax $ast 'S02'

# S03 param()/#Requires/Dot-Source
if ($ast.ParamBlock) { Add-Finding 'FEHLER' 'S03' $ast.ParamBlock.Extent.StartLineNumber 'Kein param()-Block im Snippet - Eingaben als "# @param"-Zeilen anlegen.' }
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*#\s*requires\b') { Add-Finding 'FEHLER' 'S03' ($i + 1) 'Kein #Requires im Snippet.' }
}
foreach ($c in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.CommandAst] })) {
    if ($c.InvocationOperator -eq 'Dot') { Add-Finding 'FEHLER' 'S03' $c.Extent.StartLineNumber 'Kein Dot-Source im Snippet.' }
}

# S04 Laufzeitvariablen
$runtimeVars = @('TenantKey', 'Token', 'Schule', 'Settings', 'AppRoot', 'Tenants')
foreach ($a in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] })) {
    $l = $a.Left
    if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
    if ($l -is [System.Management.Automation.Language.VariableExpressionAst] -and ($runtimeVars -contains $l.VariablePath.UserPath)) {
        Add-Finding 'FEHLER' 'S04' $a.Extent.StartLineNumber "`$$($l.VariablePath.UserPath) setzt die Laufzeit selbst - nicht zuweisen."
    }
}
foreach ($f in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] })) {
    if ($runtimeVars -contains $f.Variable.VariablePath.UserPath) { Add-Finding 'FEHLER' 'S04' $f.Extent.StartLineNumber "Schleifenvariable `$$($f.Variable.VariablePath.UserPath) ueberschreibt eine Laufzeitvariable." }
}

# S05 @param-Zeilen
$reserved = @('Token', 'TenantKey', 'Schule', 'Settings', 'AppRoot', 'Tenants', 'Input', 'Args', 'Error', 'Host', 'Home', 'PID', 'PSItem', 'Matches', 'Profile', 'ShellId', 'true', 'false', 'null', 'StackTrace', 'This', 'Pwd', 'MyInvocation', 'PSCmdlet', 'PSBoundParameters', 'ExecutionContext', 'Event', 'Sender', 'PSVersionTable', 'PSScriptRoot', 'PSCommandPath', 'ErrorActionPreference', 'WarningPreference', 'VerbosePreference', 'ConfirmPreference', 'WhatIfPreference')
$paramDefs = @()
$seenNames = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], '^\s*#\s*@param\s+(.+?)\s*$')
    if (-not $m.Success) { continue }
    $p = $m.Groups[1].Value -split '\|'
    $name = "$($p[0])".Trim().TrimStart('$')
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Add-Finding 'FEHLER' 'S05' ($i + 1) "@param: ungueltiger Name '$name' - die Zeile wird ignoriert."; continue }
    if ($reserved -contains $name) { Add-Finding 'FEHLER' 'S05' ($i + 1) "@param: Name '$name' ist eine reservierte oder von der Laufzeit belegte Variable." }
    if ($seenNames.ContainsKey($name.ToLower())) { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param: '$name' kommt doppelt vor - nur die erste Zeile zaehlt."; continue }
    $seenNames[$name.ToLower()] = $true
    $type = if ($p.Count -gt 1 -and "$($p[1])".Trim()) { "$($p[1])".Trim().ToLower() } else { 'string' }
    if ($type -notin @('bool', 'int', 'string', 'choice')) { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): unbekannter Typ '$type' - wird als string behandelt (erlaubt: bool, int, string, choice)."; $type = 'string' }
    $default = if ($p.Count -gt 3) { "$($p[3])".Trim() } else { '' }
    $choices = @()
    if ($p.Count -gt 4) { $choices = @("$($p[4])" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($type -eq 'choice') {
        if (-not $choices.Count) { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): choice ohne Auswahlliste (5. Feld, mit ; getrennt) - wird als string behandelt." }
        elseif ($choices -notcontains $default) { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): Standard '$default' steht nicht in der Auswahlliste." }
    }
    if ($type -eq 'bool' -and $default -notmatch '^(true|false)$') { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): Standard fuer bool bitte true oder false." }
    if ($type -eq 'int' -and $default -notmatch '^-?\d+$') { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): Standard fuer int muss eine ganze Zahl sein (leer wird 0 oder Fehler)." }
    if ($p.Count -gt 5) { Add-Finding 'WARNUNG' 'S05' ($i + 1) "@param $($name): zu viele Felder - ein | im Text? Das Trennzeichen darf in Beschriftung/Standard nicht vorkommen." }
    $paramDefs += [pscustomobject]@{ Name = $name; Type = $type; Default = $default; Line = $i + 1 }
}

# S06 Zuweisung an @param-Variablen
foreach ($a in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] })) {
    $l = $a.Left
    if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
    if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) {
        foreach ($pd in $paramDefs) {
            if ($l.VariablePath.UserPath -eq $pd.Name) { Add-Finding 'FEHLER' 'S06' $a.Extent.StartLineNumber "`$$($pd.Name) ist ein @param-Feld und wird hier ueberschrieben - das Feld wirkt dann nicht (eigene Variable verwenden)." }
        }
    }
}

# Befehle sammeln
$cmds = @(Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.CommandAst] })
$graphFns = @('Invoke-GraphRequest', 'Invoke-GraphRequestWithRetry', 'Invoke-GraphRequestAll', 'Invoke-AdminGraphRequest')
$mutations = @()

foreach ($c in $cmds) {
    $cn = "$($c.GetCommandName())"
    if (-not $cn) { continue }
    $ln = $c.Extent.StartLineNumber

    # S07 verbotene / nicht verfuegbare Befehle
    if ($cn -in @('Read-Host', 'Out-GridView', 'Get-Credential', 'Pause', 'Clear-Host')) { Add-Finding 'FEHLER' 'S07' $ln "$cn braucht eine Eingabe/Oberflaeche - im Snippet-Lauf sieht sie niemand (Lauf haengt)." }
    elseif ($cn -match '^Connect-') { Add-Finding 'FEHLER' 'S07' $ln "$cn ist nicht moeglich: das Snippet laeuft mit dem Token der App (Anwendungsberechtigungen); Exchange Online und Verbinden-Befehle gehen hier nicht." }
    elseif ($cn -match '^Write-HULog') { Add-Finding 'FEHLER' 'S07' $ln "$cn gibt es im Snippet-Lauf nicht (nur in Extensions) - Write-Host / Write-Warning / Write-Error verwenden." }
    elseif ($cn -in @('Get-Settings', 'Get-TenantByKey', 'Get-AllTenants', 'Get-CurrentTenant', 'Get-CurrentTenantKey', 'Set-CurrentTenant', 'Import-TenantSettings')) { Add-Finding 'FEHLER' 'S07' $ln "$cn gibt es im Snippet-Lauf nicht - `$Settings (Variable) und `$TenantKey verwenden." }
    elseif ($cn -in @('Initialize-HUExcel', 'New-HUExcelReport', 'Format-HUExcelWorkbook', 'Add-HUExcelDashboard', 'Set-HUExcelColumnGrouping', 'Add-HUExcelSheet', 'Set-HUExcelFreezePanes', 'Export-Excel')) { Add-Finding 'FEHLER' 'S07' $ln "$cn gibt es im Snippet-Lauf nicht - Ergebnisse als Objekte ausgeben (Tabelle > CSV/Excel in der Oberflaeche) oder eine Extension schreiben." }
    elseif ($cn -in @('Grant-HUSendApproval', 'Revoke-HUSendApproval', 'Set-HUNotifyRoute', 'Clear-HUNotifyRoute', 'Set-HUNotifyTargets', 'Add-HUNotifyTarget', 'Remove-HUNotifyTarget')) { Add-Finding 'FEHLER' 'S07' $ln "$cn nie im Snippet aufrufen - die Freigabe gibt die Rueckfrage bzw. die gespeicherte Meldung." }
    elseif ($cn -in @('Invoke-Expression', 'iex')) { Add-Finding 'FEHLER' 'S07' $ln 'Invoke-Expression ist nicht erlaubt (fuehrt beliebigen Text aus).' }
    elseif ($cn -eq 'Import-Module') {
        $mn = Get-HULeadingString (@($c.CommandElements)[1])
        if ($mn -match 'HU\.|HU-') { Add-Finding 'FEHLER' 'S07' $ln 'Die HU-Module sind im Snippet-Lauf schon geladen - kein Import-Module.' }
        else { Add-Finding 'WARNUNG' 'S07' $ln "Import-Module $mn : auf anderen Rechnern evtl. nicht vorhanden." }
    }
    elseif ($cn -in @('Install-Module', 'Install-Package', 'Set-ExecutionPolicy')) { Add-Finding 'WARNUNG' 'S07' $ln "$cn veraendert den Rechner - im Snippet nicht ueblich." }
    elseif ($cn -in @('Format-Table', 'Format-List', 'Out-String', 'ft', 'fl')) { Add-Finding 'WARNUNG' 'S07' $ln "$cn macht aus Ergebnissen Text - Ergebnisse als [pscustomobject] ausgeben (Tabelle, Filter, CSV, Excel)." }
    elseif ($cn -in @('Invoke-RestMethod', 'Invoke-WebRequest', 'irm', 'iwr', 'curl', 'wget')) {
        $allText = $c.Extent.Text
        if ($allText -match 'graph\.microsoft\.com') { Add-Finding 'FEHLER' 'S07' $ln "Graph-Aufrufe ueber Invoke-GraphRequest / Invoke-GraphRequestAll (Token, Wiederholung und Tokenerneuerung sind dort eingebaut), nicht ueber $cn." }
        else { Add-Finding 'WARNUNG' 'S07' $ln "$cn ruft eine andere Adresse auf - sicher, dass das gewollt ist (Daten verlassen den Tenant)?" }
    }

    # S09 Send-HUNotify
    if ($cn -eq 'Send-HUNotify') {
        $okP = @('Category', 'Title', 'Lines', 'Level', 'Facts', 'Rows', 'Actions', 'Source', 'TargetIds', 'IgnoreCategory', 'Preview', 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
        foreach ($e in @($c.CommandElements)) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and ($okP -notcontains $e.ParameterName)) { Add-Finding 'FEHLER' 'S09' $ln "Send-HUNotify hat keinen Parameter -$($e.ParameterName)." }
        }
        if (-not (Test-HUHasParam $c 'Title')) { Add-Finding 'FEHLER' 'S09' $ln 'Send-HUNotify braucht -Title.' }
        $lv = Get-HUNamedArg $c 'Level'
        if ($lv -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $lv.Value -notin @('OK', 'Warning', 'Error', 'Info')) { Add-Finding 'FEHLER' 'S09' $ln "Send-HUNotify -Level '$($lv.Value)': erlaubt sind OK, Warning, Error, Info." }
        if ($c.Extent.Text -match '\.(deviceName|userPrincipalName|displayName|mail|givenName|surname)\b') { Add-Finding 'WARNUNG' 'S09' $ln 'Personen- oder Geraetenamen in einer Teams-Karte: nur an reine Admin-Kanaele senden, sonst nur Anzahlen melden.' }
    }
}

# S08 Graph-Aufrufe (Parameter, Methode, Body, Endpoint); liefert die aendernden Aufrufe
$mutations = @(Test-HUGraphCalls $cmds 'S')

# S10 Token/Secrets
Test-HUSecretUse $ast 'Token' 'S10'

# S11 aendernde Aufrufe brauchen einen Probelauf-Schalter
$guardRx = '^(DryRun|WhatIf|Simulation|Simulate|Test|TestMode|Probelauf|NurAnzeigen|Preview)$'
$guard = @($paramDefs | Where-Object { $_.Type -eq 'bool' -and $_.Name -match $guardRx })
if ($mutations.Count) {
    if (-not $guard.Count) {
        Add-Finding 'FEHLER' 'S11' $mutations[0].Line "Das Snippet aendert Daten ($($mutations[0].Cmd) $($mutations[0].Method)), hat aber kein bool-@param DryRun (erlaubte Namen: DryRun, WhatIf, Simulation, Simulate, Test, TestMode, Probelauf, NurAnzeigen, Preview) - ohne den erkennt das Programm den echten Lauf nicht und fragt nicht nach."
    }
    else {
        $g = $guard[0]
        if ($g.Default -ne 'true') { Add-Finding 'WARNUNG' 'S11' $g.Line "Der Standard von $($g.Name) sollte true sein (Probelauf), damit nichts versehentlich geaendert wird." }
        $used = @(Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $g.Name })
        if (-not $used.Count) { Add-Finding 'FEHLER' 'S11' $g.Line "`$$($g.Name) wird im Code nie abgefragt - der Probelauf-Schalter hat keine Wirkung." }
        else { Test-HUGuard $ast $mutations $g.Name 'S' }
    }
}

# S12 Fehlerobjekt IsError und unvollstaendige Listen
Test-HUResultHandling $cmds $mutations $Code 'S'


# S13 Ausgabe: Methodenaufrufe ohne [void]
foreach ($ie in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] })) {
    $mn = "$($ie.Member.Value)"
    if ($mn -in @('Add', 'Remove', 'Insert', 'AddRange') -and $ie.Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and $ie.Parent.Parent -is [System.Management.Automation.Language.PipelineAst] -and @($ie.Parent.Parent.PipelineElements).Count -eq 1 -and $ie.Parent.Parent.Parent -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
        Add-Finding 'WARNUNG' 'S13' $ie.Extent.StartLineNumber ".$mn(...) ohne [void] oder | Out-Null: bei einer ArrayList landet der Rueckgabewert (Index) in der Ausgabe und damit in der Tabelle."
    }
}

# S14 Kopf und Rechte
$first = if ($lines.Count) { $lines[0].Trim() } else { '' }
if (-not $first.StartsWith('#') -or $first.Length -lt 3) { Add-Finding 'WARNUNG' 'S14' 1 'Erste Zeile soll die Kurzbeschreibung als Kommentar sein (# Beschreibung).' }
$permLine = $null
for ($i = 0; $i -lt [Math]::Min($lines.Count, 6); $i++) { if ($lines[$i] -match '^\s*#\s*Berechtigungen\s*:\s*(.*)$') { $permLine = $matches[1]; if ($i -ne 1) { Add-Finding 'WARNUNG' 'S14' ($i + 1) 'Die Zeile "# Berechtigungen: ..." gehoert in die zweite Zeile.' }; break } }
$perms = @()
if ($null -eq $permLine) { Add-Finding 'WARNUNG' 'S14' 2 'Zweite Zeile "# Berechtigungen: Name1, Name2" fehlt (exakte Graph-Namen; "keine" falls nur Eigenes).' }
else {
    $permText = ($permLine -replace '\([^)]*\)', '').Trim()
    if ($permLine -match '\(' -and $permLine -notmatch '\)') { Add-Finding 'WARNUNG' 'S14' 2 'Klammer in der Rechte-Zeile nicht geschlossen.' }
    foreach ($item in @($permText -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(keine|none|-)$' })) {
        if ($item -match '^\.+$') { Add-Finding 'WARNUNG' 'S14' 2 'Platzhalter in der Rechte-Zeile - die echten Rechtenamen eintragen.'; continue }
        if ($item -match '\s') { Add-Finding 'WARNUNG' 'S14' 2 "'$item': Text in der Rechte-Zeile - Rechte mit Komma trennen, Erklaerungen in Klammern dahinter."; continue }
        if ($item -notmatch '^[A-Za-z][A-Za-z0-9\-]*(\.[A-Za-z][A-Za-z0-9\-]*)+$') { Add-Finding 'FEHLER' 'S14' 2 "'$item' ist kein gueltiger Graph-Rechtename (Beispiel: DeviceManagementManagedDevices.Read.All)."; continue }
        $perms += $item
    }
}

# S15 Rechte passend zu den Endpunkten (nur Hinweise)
if ($perms.Count -or $null -ne $permLine) { Test-HUPermCoverage $cmds $mutations $perms 'S' }


# S16 Zeichen
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '[^\x00-\x7F]') { Add-Finding 'WARNUNG' 'S16' ($i + 1) 'Nicht-ASCII-Zeichen (Umlaute, Sonderzeichen): in Skripten ae/oe/ue schreiben und Emoji ueber [char]::ConvertFromUtf32(0x...) bilden - sonst droht Zeichensalat.'; break }
}

# ---------------------------------------------------------------------------
# Ausgabe
# ---------------------------------------------------------------------------
$result = @($script:Findings | Sort-Object @{ Expression = { if ($_.Stufe -eq 'FEHLER') { 0 } else { 1 } } }, Zeile)
if ($Quiet) { return $result }

$nErr = @($result | Where-Object { $_.Stufe -eq 'FEHLER' }).Count
$nWarn = @($result | Where-Object { $_.Stufe -eq 'WARNUNG' }).Count
foreach ($f in $result) {
    $col = if ($f.Stufe -eq 'FEHLER') { 'Red' } else { 'Yellow' }
    Write-Host ("{0,-8} [{1}] Zeile {2}: {3}" -f $f.Stufe, $f.Regel, $f.Zeile, $f.Text) -ForegroundColor $col
}
if (-not $result.Count) { Write-Host 'ERGEBNIS: keine Befunde.' -ForegroundColor Green }
else { Write-Host "ERGEBNIS: $nErr Fehler, $nWarn Warnungen." -ForegroundColor $(if ($nErr) { 'Red' } else { 'Yellow' }) }
if ($nErr) { exit 1 } else { exit 0 }
