<#
.SYNOPSIS
    Prueft eine Extension fuer HU-MultiTenant gegen die Regeln des Laders und der Laufzeit (Windows PowerShell 5.1).
.DESCRIPTION
    Rein statisch (Parser/AST), es wird nichts ausgefuehrt und nichts verbunden. Laeuft unter Windows PowerShell 5.1 und PowerShell 7.
    FEHLER  = die Extension wird nicht geladen, laeuft so nicht oder ist unsicher - muss behoben werden.
    WARNUNG = pruefen und im Zweifel anpassen.
    Rueckgabe: Befundobjekte (Stufe, Regel, Zeile, Text). Ohne -Quiet zusaetzlich Textausgabe und Exitcode 1 bei Fehlern.
.PARAMETER Path
    Die Extension-Datei (.ps1, UTF-8).
.PARAMETER Code
    Alternativ der Code als Text.
.PARAMETER Quiet
    Keine Textausgabe, kein Exitcode (fuer Tests).
.EXAMPLE
    .\Test-HUExtension.ps1 -Path .\Device-MeineExtension.ps1
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
    return ($Name -match '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9\-]*)+$')
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
$fileName = if ($Path) { [System.IO.Path]::GetFileName($Path) } else { '' }

$tokens = $null
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errs)

# E01 Syntax
foreach ($e in @($errs)) { Add-Finding 'FEHLER' 'E01' $e.Extent.StartLineNumber "Syntaxfehler: $($e.Message)" }

# E03 Kopfblock (so liest ihn der Lader: erster Blockkommentar der Datei, Schluessel allein in einer Zeile)
$open = '<' + '#'
$close = '#' + '>'
$bm = [regex]::Match($Code, [regex]::Escape($open) + '([\s\S]*?)' + [regex]::Escape($close))
$hdr = @{}
$hdrLine = 1
if (-not $bm.Success) {
    Add-Finding 'FEHLER' 'E03' 1 'Kein Kopfblock (Blockkommentar mit .SYNOPSIS) am Dateianfang - der Lader ueberspringt die Datei.'
}
else {
    $hdrLine = ($Code.Substring(0, $bm.Index) -split "`n").Count
    if ($bm.Index -gt 0 -and $Code.Substring(0, $bm.Index).Trim().Length -gt 0) {
        Add-Finding 'WARNUNG' 'E03' 1 'Vor dem Kopfblock steht anderer Code/Kommentar - der Lader nimmt den ERSTEN Blockkommentar der Datei; der Kopfblock gehoert an den Anfang.'
    }
    $keys = 'SYNOPSIS|DESCRIPTION|REQUIRED_PERMISSIONS|REQUIRED_ROLES|CATEGORY|TARGETS|BATCH_CAPABLE|DRY_RUN_CAPABLE|RUNTIME|MODE|PARAM|EXAMPLE|NOTES'
    $parts = [regex]::Split($bm.Groups[1].Value, "(?m)^\s*\.($keys)\s*$")
    for ($i = 1; $i -lt $parts.Count - 1; $i += 2) {
        $k = $parts[$i].Trim().ToUpper()
        if (-not $hdr.ContainsKey($k)) { $hdr[$k] = $parts[$i + 1].Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($hdr['SYNOPSIS']) -and [string]::IsNullOrWhiteSpace($hdr['DESCRIPTION'])) {
        Add-Finding 'FEHLER' 'E03' $hdrLine 'Im ersten Blockkommentar fehlt .SYNOPSIS (und .DESCRIPTION) - der Lader ueberspringt die Datei. Jeder Schluessel steht allein in einer Zeile, der Text darunter.'
    }
    elseif ([string]::IsNullOrWhiteSpace($hdr['SYNOPSIS'])) { Add-Finding 'WARNUNG' 'E03' $hdrLine '.SYNOPSIS fehlt - die Kurzbeschreibung erscheint in der Liste.' }
    if ($hdr.ContainsKey('MODE') -and $hdr['MODE'] -notmatch '^\s*(ReadOnly|ReadWrite)\s*$') { Add-Finding 'WARNUNG' 'E03' $hdrLine ".MODE '$($hdr['MODE'])': erlaubt sind ReadOnly und ReadWrite (alles andere gilt als ReadOnly, nur Write/Manage/ReadWrite als schreibend)." }
    foreach ($bk in @('BATCH_CAPABLE', 'DRY_RUN_CAPABLE')) {
        if ($hdr.ContainsKey($bk) -and $hdr[$bk].Trim().ToLower() -notin @('true', 'false', '$true', '$false', '1', '0', 'yes', 'no', 'ja', 'nein')) { Add-Finding 'WARNUNG' 'E03' $hdrLine ".$bk '$($hdr[$bk])': true oder false schreiben (alles ausser true/1/yes/ja gilt als false)." }
    }
    if ($hdr.ContainsKey('RUNTIME') -and $hdr['RUNTIME'].Trim().ToUpper() -ne 'PS5') { Add-Finding 'WARNUNG' 'E03' $hdrLine ".RUNTIME '$($hdr['RUNTIME'])': fuer Windows PowerShell 5.1 (Standard) PS5 schreiben; PS7 nur, wenn die Extension wirklich PowerShell 7 braucht." }
    if ($hdr.ContainsKey('TARGETS') -and $hdr['TARGETS'].Trim()) {
        try { $null = $hdr['TARGETS'] | ConvertFrom-Json -ErrorAction Stop }
        catch { Add-Finding 'WARNUNG' 'E03' $hdrLine '.TARGETS ist kein gueltiges JSON (Beispiel: ["Schule-1","Schule-2"] oder []) - der Lader faellt auf Komma-Trennung zurueck.' }
    }
    if (-not $hdr.ContainsKey('CATEGORY') -and $fileName -and $fileName -notmatch '^(Device|Policy|Security|User|Common)-') { Add-Finding 'WARNUNG' 'E03' $hdrLine '.CATEGORY fehlt und der Dateiname gibt keine Kategorie vor (Praefix Device-, Policy-, Security-, User- oder Common-).' }
    if ($hdr.ContainsKey('PARAM')) {
        foreach ($pl in @($hdr['PARAM'] -split '[\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $pp = $pl -split '\|'
            if ($pp.Count -lt 3) { Add-Finding 'FEHLER' 'E03' $hdrLine ".PARAM-Zeile '$pl': Format Name|Typ|Beschriftung|Standard|Auswahl1;Auswahl2 (mindestens 3 Felder) - die Zeile wird sonst ignoriert."; continue }
            if ($pp.Count -gt 5) { Add-Finding 'WARNUNG' 'E03' $hdrLine ".PARAM-Zeile '$pl': zu viele Felder - ein | im Text?" }
            if ($pp[1].Trim().ToLower() -notin @('string', 'int', 'bool', 'choice')) { Add-Finding 'WARNUNG' 'E03' $hdrLine ".PARAM $($pp[0].Trim()): unbekannter Typ '$($pp[1].Trim())' (erlaubt: string, int, bool, choice)." }
            if ($pp.Count -ge 4 -and $pp[1].Trim().ToLower() -eq 'int' -and $pp[3].Trim() -notmatch '^-?\d+$') { Add-Finding 'WARNUNG' 'E03' $hdrLine ".PARAM $($pp[0].Trim()): Standard fuer int muss eine ganze Zahl sein." }
            if ($pp.Count -ge 4 -and $pp[1].Trim().ToLower() -eq 'bool' -and $pp[3].Trim().ToLower() -notin @('true', 'false')) { Add-Finding 'WARNUNG' 'E03' $hdrLine ".PARAM $($pp[0].Trim()): Standard fuer bool bitte true oder false." }
        }
    }
}

# E02 PowerShell-7-Syntax (nur wenn die Extension unter Windows PowerShell 5.1 laeuft, also nicht .RUNTIME PS7)
$rt = if ($hdr.ContainsKey('RUNTIME')) { $hdr['RUNTIME'].Trim().ToUpper() } else { 'PS5' }
if ($rt -match 'PS7|PWSH' -and $rt -notmatch 'PS5') { Add-Finding 'WARNUNG' 'E02' $hdrLine '.RUNTIME PS7: laeuft in einem eigenen PowerShell-7-Prozess; Hilfsfunktionen der App (Write-HULog*, Graph-Funktionen) stehen dort nur eingeschraenkt zur Verfuegung - dieses Pruefprogramm prueft nach den Regeln fuer Windows PowerShell 5.1.' }
else { Find-HUPs7Syntax $ast 'E02' }

# E04 Einstiegsfunktion: erste Funktion mit Invoke-* (Hilfsfunktionen duerfen nicht so heissen)
$funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
$allFuncs = @(Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] })
$entries = @($funcs | Where-Object { $_.Name -like 'Invoke-*' })
$main = $null
if (-not $entries.Count) { Add-Finding 'FEHLER' 'E04' 1 'Keine Funktion Invoke-* in der Datei - die Oberflaeche findet die Einstiegsfunktion ueber dieses Praefix.' }
else {
    $main = $entries[0]
    if ($entries.Count -gt 1) { Add-Finding 'FEHLER' 'E04' $entries[1].Extent.StartLineNumber "Zweite Funktion $($entries[1].Name) mit Invoke-: gestartet wird $($main.Name) (die erste). Hilfsfunktionen anders benennen (Get-, Test-, Format- ...)." }
    if ($fileName) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $expect = 'Invoke-' + ($base -replace '^[A-Za-z]+-', '')
        if ($main.Name -ne $expect) { Add-Finding 'WARNUNG' 'E04' $main.Extent.StartLineNumber "Funktionsname $($main.Name): Konvention ist Invoke-<Dateiname ohne Kategorie> (hier $expect)." }
    }
}
$mainParams = @{}
if ($main) {
    $pb = $main.Body.ParamBlock
    if (-not $pb) { Add-Finding 'FEHLER' 'E04' $main.Extent.StartLineNumber "$($main.Name) hat keinen param()-Block mit -TenantKey und -Token." }
    else {
        foreach ($pa in @($pb.Parameters)) { $mainParams[$pa.Name.VariablePath.UserPath.ToLower()] = $pa }
        foreach ($req in @('TenantKey', 'Token')) {
            if (-not $mainParams.ContainsKey($req.ToLower())) { Add-Finding 'FEHLER' 'E04' $pb.Extent.StartLineNumber "Pflichtparameter [string]`$$req fehlt - die Oberflaeche uebergibt immer -TenantKey und -Token." }
        }
        $cb = @($main.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
        $sps = $cb.Count -gt 0 -and (@($cb[0].NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }).Count -gt 0)
        foreach ($cn2 in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
            if ($cb.Count -gt 0 -and $mainParams.ContainsKey($cn2.ToLower())) { Add-Finding 'FEHLER' 'E05' $mainParams[$cn2.ToLower()].Extent.StartLineNumber "Parameter -$cn2 ist mit [CmdletBinding()] schon vorhanden - 'Parameter defined multiple times', die Extension laedt nicht. Entfernen." }
        }
        if ($sps) {
            Add-Finding 'WARNUNG' 'E05' $cb[0].Extent.StartLineNumber 'SupportsShouldProcess: der Probelauf kommt als eigener Parameter [switch]$WhatIf (DRY_RUN_CAPABLE true), nicht ueber ShouldProcess - ohne SupportsShouldProcess arbeiten.'
            if ($mainParams.ContainsKey('whatif') -or $mainParams.ContainsKey('confirm')) { Add-Finding 'FEHLER' 'E05' $cb[0].Extent.StartLineNumber 'SupportsShouldProcess UND eigener -WhatIf/-Confirm: "defined multiple times", die Extension laedt nicht.' }
        }
        $dry = $hdr.ContainsKey('DRY_RUN_CAPABLE') -and $hdr['DRY_RUN_CAPABLE'].Trim().ToLower() -in @('true', '$true', '1', 'yes', 'ja')
        if ($dry -and -not $mainParams.ContainsKey('whatif')) { Add-Finding 'FEHLER' 'E05' $pb.Extent.StartLineNumber '.DRY_RUN_CAPABLE ist true, aber die Funktion hat kein [switch]$WhatIf - die Oberflaeche zeigt "Probelauf", der dann nichts bewirkt (und der Aufruf mit -WhatIf scheitert).' }
        if (-not $dry -and $mainParams.ContainsKey('whatif')) { Add-Finding 'WARNUNG' 'E05' $mainParams['whatif'].Extent.StartLineNumber '[switch]$WhatIf ist deklariert, aber .DRY_RUN_CAPABLE ist nicht true - die Oberflaeche uebergibt -WhatIf dann nie.' }
        if ($mainParams.ContainsKey('whatif') -and $mainParams['whatif'].StaticType -and $mainParams['whatif'].StaticType.Name -ne 'SwitchParameter') { Add-Finding 'FEHLER' 'E05' $mainParams['whatif'].Extent.StartLineNumber '-WhatIf muss [switch] sein.' }
    }
}

# E06 .PARAM-Felder passend zur Funktion (nur deklarierte Parameter werden uebergeben)
if ($main -and $main.Body.ParamBlock -and $hdr.ContainsKey('PARAM')) {
    $hdrNames = @{}
    foreach ($pl in @($hdr['PARAM'] -split '[\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $pp = $pl -split '\|'
        if ($pp.Count -lt 3) { continue }
        $nm = $pp[0].Trim()
        $hdrNames[$nm.ToLower()] = $true
        if (-not $mainParams.ContainsKey($nm.ToLower())) { Add-Finding 'FEHLER' 'E06' $hdrLine ".PARAM $($nm): die Funktion hat keinen Parameter -$nm - der Wert aus der Oberflaeche geht verloren."; continue }
        $st = $mainParams[$nm.ToLower()].StaticType
        $ty = $pp[1].Trim().ToLower()
        if ($st) {
            $stn = $st.Name
            if ($ty -eq 'int' -and $stn -notin @('Int32', 'Int64', 'Double', 'Object')) { Add-Finding 'WARNUNG' 'E06' $mainParams[$nm.ToLower()].Extent.StartLineNumber ".PARAM $nm ist int, der Funktionsparameter aber [$stn]." }
            if ($ty -eq 'bool' -and $stn -notin @('Boolean', 'SwitchParameter', 'Object')) { Add-Finding 'WARNUNG' 'E06' $mainParams[$nm.ToLower()].Extent.StartLineNumber ".PARAM $nm ist bool, der Funktionsparameter aber [$stn]." }
            if ($ty -eq 'bool' -and $stn -eq 'SwitchParameter') { Add-Finding 'WARNUNG' 'E06' $mainParams[$nm.ToLower()].Extent.StartLineNumber ".PARAM $nm (bool) als [switch]: die Oberflaeche uebergibt einen Wert - [bool] verwenden." }
        }
    }
    foreach ($k in @($mainParams.Keys)) {
        if ($k -in @('tenantkey', 'token', 'whatif')) { continue }
        if (-not $hdrNames.ContainsKey($k)) { Add-Finding 'WARNUNG' 'E06' $mainParams[$k].Extent.StartLineNumber "Parameter -$($mainParams[$k].Name.VariablePath.UserPath) hat keine .PARAM-Zeile - in der Oberflaeche gibt es kein Eingabefeld, er behaelt seinen Standardwert."; }
    }
}
elseif ($main -and $main.Body.ParamBlock) {
    foreach ($k in @($mainParams.Keys)) {
        if ($k -in @('tenantkey', 'token', 'whatif')) { continue }
        Add-Finding 'WARNUNG' 'E06' $mainParams[$k].Extent.StartLineNumber "Parameter -$($mainParams[$k].Name.VariablePath.UserPath) hat keine .PARAM-Zeile - in der Oberflaeche gibt es kein Eingabefeld, er behaelt seinen Standardwert."
    }
}

# Befehle sammeln
$cmds = @(Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.CommandAst] })

# E07 verbotene / wirkungslose Befehle
foreach ($c in $cmds) {
    $cn = "$($c.GetCommandName())"
    if (-not $cn) { continue }
    $ln = $c.Extent.StartLineNumber
    if ($c.InvocationOperator -eq 'Dot' -and $c.Extent.StartLineNumber -gt $hdrLine + 1 -and -not ($c.Extent.Text -match '^\.\s+\.\\')) { Add-Finding 'WARNUNG' 'E07' $ln 'Dot-Source in der Extension: Hilfsfunktionen gehoeren in dieselbe Datei.' }
    if ($cn -in @('Read-Host', 'Out-GridView', 'Get-Credential', 'Pause', 'Clear-Host')) { Add-Finding 'FEHLER' 'E07' $ln "$cn braucht eine Eingabe/Oberflaeche - im Hintergrundlauf sieht sie niemand (Lauf haengt)." }
    elseif ($cn -match '^Connect-') { Add-Finding 'FEHLER' 'E07' $ln "$cn ist nicht moeglich: die Extension laeuft mit dem Token der App; Verbinden-Befehle und Exchange Online gehen hier nicht." }
    elseif ($cn -in @('Invoke-Expression', 'iex')) { Add-Finding 'FEHLER' 'E07' $ln 'Invoke-Expression ist nicht erlaubt (fuehrt beliebigen Text aus).' }
    elseif ($cn -in @('Write-Host', 'Write-Output')) { Add-Finding 'WARNUNG' 'E07' $ln "$cn ist im Protokoll der Oberflaeche nicht sichtbar - Write-HULogInfo / Write-HULogOK / Write-HULogWarn / Write-HULogError verwenden." }
    elseif ($cn -in @('Get-Settings', 'Get-AllTenants', 'Get-TenantByKey')) { Add-Finding 'WARNUNG' 'E07' $ln "$cn liefert nur in der App-Oberflaeche Daten (sonst `$null bzw. leer) - Werte besser ueber -TenantKey/-Token bzw. Parameter beziehen." }
    elseif ($cn -in @('Grant-HUSendApproval', 'Revoke-HUSendApproval', 'Set-HUNotifyRoute', 'Clear-HUNotifyRoute', 'Set-HUNotifyTargets', 'Add-HUNotifyTarget', 'Remove-HUNotifyTarget')) { Add-Finding 'FEHLER' 'E07' $ln "$cn nie aus einer Extension aufrufen - die Freigabe gibt die Rueckfrage bzw. die gespeicherte Meldung." }
    elseif ($cn -in @('Install-Module', 'Install-Package', 'Set-ExecutionPolicy', 'Import-Module')) {
        $mn = if ($cn -eq 'Import-Module') { Get-HULeadingString (@($c.CommandElements)[1]) } else { '' }
        if ($mn -match 'HU\.|HU-') { Add-Finding 'FEHLER' 'E07' $ln 'Die HU-Module sind im Lauf schon geladen - kein Import-Module.' }
        elseif ($cn -ne 'Import-Module') { Add-Finding 'WARNUNG' 'E07' $ln "$cn veraendert den Rechner - in einer Extension nicht ueblich." }
        else { Add-Finding 'WARNUNG' 'E07' $ln "Import-Module $mn : auf anderen Rechnern evtl. nicht vorhanden." }
    }
    elseif ($cn -in @('Invoke-RestMethod', 'Invoke-WebRequest', 'irm', 'iwr', 'curl', 'wget')) {
        if ($c.Extent.Text -match 'graph\.microsoft\.com') { Add-Finding 'FEHLER' 'E07' $ln "Graph-Aufrufe ueber Invoke-GraphRequest / Invoke-GraphRequestAll / Invoke-GraphRequestWithRetry (Token, Wiederholung und Tokenerneuerung sind dort eingebaut), nicht ueber $cn." }
        else { Add-Finding 'WARNUNG' 'E07' $ln "$cn ruft eine andere Adresse auf - sicher, dass das gewollt ist (Daten verlassen den Tenant)?" }
    }
    elseif ($cn -match '^Write-HULog(Info|OK|Warn|Error|Debug)?$') {
        foreach ($e in @($c.CommandElements)) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -notin @('Message', 'Tenant', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction')) {
                if ($cn -eq 'Write-HULog') { continue }
                Add-Finding 'FEHLER' 'E07' $ln "$cn hat keinen Parameter -$($e.ParameterName) (vorhanden: -Message, -Tenant)."
            }
        }
    }
}

# E08 Graph-Aufrufe; E08 schliesst die Pruefung der Parameter und Endpunkte ein
$mutations = @(Test-HUGraphCalls $cmds 'E')
foreach ($c in @($cmds | Where-Object { "$($_.GetCommandName())" -in @('Invoke-GraphRequestWithRetry', 'Invoke-GraphRequestAll') })) {
    if (-not (Test-HUHasParam $c 'TenantKey')) { Add-Finding 'WARNUNG' 'E08' $c.Extent.StartLineNumber "$($c.GetCommandName()) ohne -TenantKey: bei Token-Ablauf kann nicht erneuert werden und das Protokoll weiss nicht, zu welchem Tenant es gehoert." }
}

# E10 Token
Test-HUSecretUse $ast 'Token' 'E10'

# E11 Modus und Probelauf
$isRW = $hdr.ContainsKey('MODE') -and $hdr['MODE'] -match 'ReadWrite|Write|Manage'
$dryOn = $hdr.ContainsKey('DRY_RUN_CAPABLE') -and $hdr['DRY_RUN_CAPABLE'].Trim().ToLower() -in @('true', '$true', '1', 'yes', 'ja')
if ($mutations.Count) {
    if (-not $isRW) { Add-Finding 'FEHLER' 'E11' $mutations[0].Line "Die Extension aendert Daten ($($mutations[0].Cmd) $($mutations[0].Method)), .MODE steht aber nicht auf ReadWrite - die Oberflaeche behandelt sie als ReadOnly (keine Rueckfrage vor dem Schreiben)." }
    if (-not $dryOn) { Add-Finding 'WARNUNG' 'E11' $mutations[0].Line 'Die Extension aendert Daten, ist aber nicht DRY_RUN_CAPABLE - ohne Probelauf (switch WhatIf) gibt es keine Vorschau vor dem Schreiben.' }
    elseif ($mainParams.ContainsKey('whatif')) {
        $used = @(Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'WhatIf' })
        if ($used.Count -le 1) { Add-Finding 'FEHLER' 'E11' $mainParams['whatif'].Extent.StartLineNumber '$WhatIf wird im Code nie abgefragt - der Probelauf aendert trotzdem.' }
        else { Test-HUGuard $ast $mutations 'WhatIf' 'E' }
    }
}
elseif ($isRW) { Add-Finding 'WARNUNG' 'E11' $hdrLine '.MODE ist ReadWrite, im Code wurde aber kein aendernder Graph-Aufruf erkannt (POST/PATCH/DELETE) - stimmt der Modus?' }

# E12 Fehlerobjekt IsError und unvollstaendige Listen
Test-HUResultHandling $cmds $mutations $Code 'E'

# E09 Fehler muessen die Oberflaeche erreichen: aeusserer catch endet mit throw
if ($main) {
    $outerTry = @($main.Body.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
    foreach ($t in $outerTry) {
        foreach ($cc in @($t.CatchClauses)) {
            $hasThrow = @(Get-HUNodes $cc.Body { param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }).Count
            if (-not $hasThrow) { Add-Finding 'FEHLER' 'E09' $cc.Extent.StartLineNumber 'Der aeussere catch endet ohne throw - die Oberflaeche wertet nur aus, ob eine Ausnahme kam, und meldet sonst "Fertig", obwohl es fehlschlug. Am Ende des catch "throw" schreiben.' }
        }
    }
    $hasSuccessFalse = [regex]::IsMatch($Code, 'Success\s*=\s*\$false')
    if ($hasSuccessFalse) { Add-Finding 'WARNUNG' 'E09' $main.Extent.StartLineNumber 'Success = $false im Rueckgabeobjekt wird von der Oberflaeche nicht ausgewertet (Erfolg = es kam keine Ausnahme). Bei Fehlern throw verwenden.' }
}

# E13 Rueckgabe (Methodenaufrufe ohne [void])
foreach ($ie in (Get-HUNodes $ast { param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] })) {
    $mn = "$($ie.Member.Value)"
    if ($mn -in @('Add', 'Remove', 'Insert', 'AddRange') -and $ie.Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and $ie.Parent.Parent -is [System.Management.Automation.Language.PipelineAst] -and @($ie.Parent.Parent.PipelineElements).Count -eq 1 -and $ie.Parent.Parent.Parent -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
        Add-Finding 'WARNUNG' 'E13' $ie.Extent.StartLineNumber ".$mn(...) ohne [void] oder | Out-Null: bei einer ArrayList landet der Rueckgabewert (Index) in der Ausgabe der Funktion."
    }
}

# E14 Rechte im Kopf
$perms = @()
$permKnown = $null
$permFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'Config', 'graph-permissions.json'))
if (Test-Path -LiteralPath $permFile) {
    try { $permKnown = @((Get-Content -LiteralPath $permFile -Raw -Encoding UTF8 | ConvertFrom-Json).permissions | ForEach-Object { $_.name }) } catch { $permKnown = $null }
}
if (-not $hdr.ContainsKey('REQUIRED_PERMISSIONS')) { Add-Finding 'WARNUNG' 'E14' $hdrLine '.REQUIRED_PERMISSIONS fehlt - ohne Angabe kann die App vor dem Start nicht pruefen, ob der Tenant die Rechte hat.' }
else {
    foreach ($item in @($hdr['REQUIRED_PERMISSIONS'] -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^(keine|none|-)$' })) {
        if ($item -match '\s') { Add-Finding 'WARNUNG' 'E14' $hdrLine "'$item': pro Recht ein Name ohne Zusatztext (eine Zeile je Recht)."; continue }
        if (-not (Test-HUPermName $item)) { Add-Finding 'FEHLER' 'E14' $hdrLine "'$item' ist kein gueltiger Graph-Rechtename (Beispiel: DeviceManagementManagedDevices.Read.All)."; continue }
        $perms += $item
        if ($permKnown -and ($permKnown -notcontains $item)) { Add-Finding 'WARNUNG' 'E14' $hdrLine "'$item' steht nicht in Config\graph-permissions.json - die Einrichtung vergibt es nicht automatisch; im Tenant nachtragen (Rechte-Dialog) oder weglassen." }
    }
}

# E15 Rechte passend zu den Endpunkten (nur Hinweise)
if ($hdr.ContainsKey('REQUIRED_PERMISSIONS')) { Test-HUPermCoverage $cmds $mutations $perms 'E' }

# E16 Zeichen
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '[^\x00-\x7F]') { Add-Finding 'WARNUNG' 'E16' ($i + 1) 'Nicht-ASCII-Zeichen (Umlaute, Sonderzeichen): in Skripten ae/oe/ue schreiben (oder die Datei als UTF-8 mit BOM speichern, sonst droht Zeichensalat unter Windows PowerShell 5.1).'; break }
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
