#Requires -Version 5.1
<#
.SYNOPSIS
    Assistent "Muster anwenden" (2.5.2): angehakte Muster-Pakete in genau einen Tenant uebertragen -
    Tenant -> Rechte (zeitweise erteilen) -> Zuordnen (Gruppen, Laender) -> Vorschau -> Ausfuehren -> Abschluss.
.NOTES
    Dot-Source aus Main.ps1. Logik in Core\HU.MusterApply.psm1 (Plan, Markierung, Sperre, Durchgang, Rueckgaengig).
    Schreibt nichts ohne Bestaetigung mit eingetipptem Tenant-Namen; Conditional Access immer neu und "Nur Bericht".
    Rechte: nur die fehlenden werden erteilt (Admin-Anmeldung im Browser), die Markierung steht VOR dem Erteilen;
    "Rechte zurueckgeben" entzieht genau die selbst erteilten. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:MA = $null   # offener Assistent (Zustand)

function Get-HUMaTenant([string]$Key) { return @($script:Settings.tenants | Where-Object { "$($_.key)" -eq $Key })[0] }

# Admin-Anmeldung (Browser) mit Rueckmeldung im UI-Takt; $OnLogin bekommt das Anmelde-Ergebnis
function Start-HUMaAdminLogin([string]$TenantKey, [scriptblock]$OnLogin, [string]$Sid = '') {
    $t = Get-HUMaTenant $TenantKey
    if (-not $t -or -not "$($t.tenantId)" -or -not "$($t.appId)") { Show-HUMessage 'Tenant-ID bzw. Anwendungs-ID fehlen in den Einstellungen.' -Icon Warning; return $false }
    $ctx = $null
    try { $ctx = Start-HUAdminLogin -TenantId "$($t.tenantId)" } catch { Show-HUMessage "Anmeldung nicht gestartet: $($_.Exception.Message)" -Icon Error; return $false }
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromMilliseconds(500)
    $st = @{ Ctx = $ctx; Timer = $tm; On = $OnLogin; Sid = $Sid }
    $tm.Tag = $st
    $tm.Add_Tick({
            $s = $this.Tag
            $res = $null
            try { $res = Receive-HUAdminLogin -Context $s.Ctx } catch { $res = [pscustomobject]@{ Ok = $false; Error = "$($_.Exception.Message)" } }
            if ($null -eq $res) { return }
            $this.Stop()
            & $s.On $res $s.Sid
        })
    $tm.Start()
    return $st
}
# Admin-Token noch mind. 3 Minuten gueltig? (dann ohne zweite Anmeldung zurueckgeben)
function Test-HUMaLoginValid($Login) {
    if (-not $Login -or -not "$($Login.Token)") { return $false }
    try { $p = ConvertFrom-HUJwtPayload "$($Login.Token)"; return ([DateTimeOffset]::FromUnixTimeSeconds([long]$p.exp).UtcDateTime -gt [datetime]::UtcNow.AddMinutes(3)) } catch { return $false }
}

# Sicher nichts erteilt (Anmeldung abgebrochen, Konto ohne Recht): geplante Rechte verwerfen, Markierung nur behalten, wenn schon etwas erteilt ist
function Clear-HUMaPlannedRights([string]$TenantKey) {
    try {
        $m = Get-HUMaMarker $TenantKey
        if (-not $m) { return }
        if (@($m.Added | Where-Object { "$_" }).Count) { [void](Write-HUMaMarker -TenantKey $TenantKey -ClearPlanned -Stage 'nichts erteilt') }
        else { Remove-HUMaMarker $TenantKey }
    } catch { }
}

# Rechte zurueckgeben (genau die selbst erteilten laut Markierung). Mit gueltigem Admin-Token sofort, sonst neue Anmeldung.
function Start-HUMaRevoke([string]$TenantKey, $Login = $null, [scriptblock]$Done = $null, $Owner = $null) {
    $m = Get-HUMaMarker $TenantKey
    # offen = erteilte plus geplante, die vorher nicht da waren (060 B1: auch nach Absturz zwischen Erteilen und Nachtragen)
    $added = @(Get-HUMaOpenRights $m)
    if (-not $added.Count) { Remove-HUMaMarker $TenantKey; if ($Done) { & $Done $true 'Es wurden keine Rechte dazugegeben - nichts zurueckzugeben.' }; return }
    $t = Get-HUMaTenant $TenantKey
    # Zustand fuer die Rueckmeldung (kein GetNewClosure: Funktionen des Programms waeren darin nicht sichtbar)
    $script:MaRev = @{ Tenant = $TenantKey; Added = $added; AppId = "$($t.appId)"; Done = $Done }
    $do = {
        param($L)
        $R = $script:MaRev; $TenantKey = $R.Tenant; $added = @($R.Added); $Done = $R.Done; $t = [pscustomobject]@{ appId = $R.AppId }
        if (-not $L.Ok) { if ($Done) { & $Done $false "Nicht zurueckgegeben: $($L.Error)" }; return }
        if (-not (Test-HUAdminCanGrant $L)) { if ($Done) { & $Done $false 'Das angemeldete Konto darf keine App-Rechte entziehen (Global Admin oder Privileged Role Admin noetig).' }; return }
        $rem = @()
        try { $rem = @(Remove-HUAppPermissions -Login $L -AppId "$($t.appId)" -Permissions $added) }
        catch { if ($Done) { & $Done $false "Zurueckgeben fehlgeschlagen: $(Get-HUSetupErrorText $_)" }; return }
        Remove-HUMaMarker $TenantKey
        try { Clear-TokenCache -TenantKey $TenantKey } catch { }
        Write-HULog -Message "Muster anwenden: Rechte zurueckgegeben ($(Get-HUAnaTenantName $TenantKey)): $(if ($rem.Count) { $rem -join ', ' } else { 'waren schon entzogen' }) (durch $($L.Upn))" -Level 'OK'
        if ($Done) { & $Done $true "Zurueckgegeben: $(if ($rem.Count) { $rem -join ', ' } else { 'waren schon entzogen' }).`nEin schon geholtes App-Token kann sie noch bis zu einer Stunde enthalten." }
    }
    if (Test-HUMaLoginValid $Login) { & $do $Login; return }
    if (-not (Confirm-HU -Warning "Rechte fuer $(Get-HUAnaTenantName $TenantKey) zurueckgeben?`n`n$($added -join "`n")`n`nEs oeffnet sich der Browser zur Admin-Anmeldung (Global Admin oder Privileged Role Admin)." -Owner $Owner)) { if ($Done) { & $Done $false 'abgebrochen' }; return }
    [void](Start-HUMaAdminLogin $TenantKey $do)
}

# Rechte mehrerer Tenants nacheinander zurueckgeben - mit den gemerkten Admin-Anmeldungen (gueltig ~60 Min), ohne neue Anmeldung.
# Abgelaufene Anmeldung -> fuer diesen Tenant Browser-Anmeldung. $Then bekommt ($alleOk, $berichtText).
function Start-HUMaRevokeAll([string[]]$Tenants, [hashtable]$Logins, [scriptblock]$Then = $null, $Owner = $null) {
    $list = @($Tenants | Where-Object { "$_" } | Select-Object -Unique | Where-Object { @(Get-HUMaOpenRights (Get-HUMaMarker $_)).Count })
    if (-not $list.Count) { if ($Then) { & $Then $true 'Es sind keine erteilten Rechte offen.' }; return }
    $script:MaRevAll = @{ List = $list; I = 0; Logins = $(if ($Logins) { $Logins } else { @{} }); Lines = New-Object System.Collections.Generic.List[string]; AllOk = $true; Then = $Then; Owner = $Owner }
    Invoke-HUMaRevokeAllNext
}
function Invoke-HUMaRevokeAllNext {
    $A = $script:MaRevAll; if (-not $A) { return }
    if ($A.I -ge @($A.List).Count) {
        $script:MaRevAll = $null
        if ($A.Then) { & $A.Then $A.AllOk ($A.Lines -join "`n") }
        return
    }
    $tk = "$($A.List[$A.I])"
    Start-HUMaRevoke $tk $A.Logins[$tk] {
        param($ok, $txt)
        $A2 = $script:MaRevAll; if (-not $A2) { return }
        $tk2 = "$($A2.List[$A2.I])"
        if (-not $ok) { $A2.AllOk = $false }
        $A2.Lines.Add("$(if ($ok) { 'OK  ' } else { 'NICHT' })  $(Get-HUAnaTenantName $tk2): $(("$txt" -split "`n")[0])")
        $A2.I++
        Invoke-HUMaRevokeAllNext
    } $A.Owner
}

# Beim Programmstart: noch erteilte Rechte aus einem abgebrochenen Ablauf melden (Absturz-Sicherung)
function Test-HUMaMarkerReminder {
    foreach ($m in @(Get-HUMaMarkers)) {
        $added = @(Get-HUMaOpenRights $m)
        $tk = "$($m.Tenant)"
        if (-not $added.Count) { Remove-HUMaMarker $tk; continue }
        $since = $null; try { $since = [datetime]::Parse("$($m.Since)", [Globalization.CultureInfo]::InvariantCulture) } catch { }
        $old = $since -and ((Get-Date) - $since).TotalHours -ge 24
        Write-HULogWarn "Muster anwenden: Rechte fuer $(Get-HUAnaTenantName $tk) seit $("$($m.Since)") noch erteilt: $($added -join ', ')"
        if (Confirm-HU "$(if ($old) { 'ACHTUNG - seit mehr als 24 Stunden: ' })'Muster anwenden' hat fuer $(Get-HUAnaTenantName $tk) Rechte erteilt, die noch nicht zurueckgegeben sind (seit $("$($m.Since)")):`n`n$($added -join "`n")`n`nJetzt zurueckgeben? (Browser-Anmeldung als Admin)`nNein = beim naechsten Start wieder fragen." -Warning) {
            Start-HUMaRevoke $tk $null { param($ok, $txt) Show-HUMessage $txt -Icon $(if ($ok) { 'Info' } else { 'Warning' }) }
            return   # eine Anmeldung nach der anderen
        }
    }
}

function Show-HUMusterApply {
    $sel = Get-HUMusterSelectionUi
    if (-not $sel) { Show-HUMessage 'Bitte links mindestens ein Paket anhaken - diese Pakete werden angewendet.' -Icon Info; return }
    if ($script:MA) { try { $script:MA.W.Activate() } catch { }; return }
    # 2.5.7: importierte, ungepruefte Pakete zuerst ansehen und bestaetigen (Udo 27.10.)
    if (-not (Confirm-HUMuChecked @($sel.Packages))) { return }
    $sel = Get-HUMusterSelectionUi
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Muster anwenden" Width="1100" Height="720" MinWidth="820" MinHeight="520" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0">
            <TextBlock x:Name="lblTitle" Foreground="#E0E0E0" FontSize="16" FontWeight="SemiBold" Text="Muster anwenden"/>
            <TextBlock x:Name="lblPkgs" Style="{StaticResource HintText}" FontSize="11" Margin="0,2,0,8" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel x:Name="pnlSteps" Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10"/>
        <Grid Grid.Row="2">
            <!-- 1 Tenant -->
            <StackPanel x:Name="pg1">
                <TextBlock Text="Ziel-Tenants (einer oder mehrere - werden nacheinander abgearbeitet, je Tenant eigene Rechte, Zuordnung und Vorschau)" Style="{StaticResource FieldLabel}" TextWrapping="Wrap"/>
                <WrapPanel x:Name="pnlTenants" Margin="0,6,0,10"
                           ToolTip="In diese Tenants werden die angehakten Pakete uebertragen - einer nach dem anderen. Fuer einen Tenant laeuft der Assistent nur einmal gleichzeitig."/>
                <TextBlock x:Name="lblT1" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap"/>
            </StackPanel>
            <!-- 2 Rechte -->
            <DockPanel x:Name="pg2" Visibility="Collapsed">
                <StackPanel DockPanel.Dock="Top">
                    <TextBlock x:Name="lblT2" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
                    <TextBlock x:Name="lblBg" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="btnGrant" Content="Anmelden und fehlende Rechte erteilen ..." Background="#A65A28" Style="{StaticResource DarkButton}" Padding="12,0" Margin="0,0,8,0"
                            ToolTip="Browser-Anmeldung als Global Admin oder Privileged Role Admin. Erteilt NUR die fehlenden Rechte und merkt sie sich - am Ende 'Rechte zurueckgeben'."/>
                    <Button x:Name="btnRecheck" Content="Neu pruefen" Style="{StaticResource ToolButton}" Padding="10,2" ToolTip="Rechte im Token und Notfallkonten erneut lesen"/>
                </StackPanel>
                <DataGrid x:Name="gridRights" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Recht (Anwendung)" Binding="{Binding Recht}" Width="340"/>
                        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="140"/>
                    </DataGrid.Columns>
                </DataGrid>
            </DockPanel>
            <!-- 3 Zuordnen -->
            <DockPanel x:Name="pg3" Visibility="Collapsed">
                <TextBlock x:Name="lblT3" DockPanel.Dock="Top" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="pnlMap"/></ScrollViewer>
            </DockPanel>
            <!-- 4 Vorschau -->
            <DockPanel x:Name="pg4" Visibility="Collapsed">
                <TextBlock x:Name="lblT4" DockPanel.Dock="Top" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
                    <Button x:Name="btnAllOn" Content="Alle auswaehlen" Style="{StaticResource ToolButton}" Padding="10,2" Margin="0,0,8,0" ToolTip="Alle anwendbaren Eintraege anhaken (auch Angleichen und Zusatzrichtlinien - danach pruefen)"/>
                    <Button x:Name="btnAllOff" Content="Alle abwaehlen" Style="{StaticResource ToolButton}" Padding="10,2" ToolTip="Alle Haken entfernen"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                    <TextBlock TextWrapping="Wrap" x:Name="lblType" Foreground="#FF8A65" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="txtType" Width="240" Style="{StaticResource DarkTextBox}" FontSize="12" ToolTip="Zur Sicherheit den Namen des Ziel-Tenants eintippen"/>
                </StackPanel>
                <DataGrid x:Name="gridPrev" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" HeadersVisibility="Column" CanUserAddRows="False" IsReadOnly="True"
                          ToolTip="Haken = wird angewendet. Gesperrte und schon gleiche Eintraege werden nie geschrieben.">
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Header="Anwenden" Width="80">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <CheckBox IsChecked="{Binding Take, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanTake}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Status" Binding="{Binding StatusText}" Width="110" IsReadOnly="True"/>
                        <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="140" IsReadOnly="True"/>
                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="320" IsReadOnly="True"/>
                        <DataGridTextColumn Header="Paket" Binding="{Binding Paket}" Width="180" IsReadOnly="True"/>
                        <DataGridTextColumn Header="Hinweis" Binding="{Binding Reason}" Width="*" IsReadOnly="True"/>
                    </DataGrid.Columns>
                </DataGrid>
            </DockPanel>
            <!-- 5 Ausfuehren / 6 Abschluss -->
            <DockPanel x:Name="pg5" Visibility="Collapsed">
                <StackPanel DockPanel.Dock="Top">
                    <TextBlock x:Name="lblT5" Foreground="#CCCCCC" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,6"/>
                    <ProgressBar x:Name="prg" Height="8" Minimum="0" Maximum="1" Value="0" Margin="0,0,0,8" Foreground="#4CAF50" Background="#333333"/>
                </StackPanel>
                <StackPanel x:Name="pnlDone" DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
                    <Button x:Name="btnUndo" Content="&#x21BA; Paket rueckgaengig ..." Style="{StaticResource ToolButton}" Padding="10,2" Margin="0,0,8,0"
                            ToolTip="Alles aus diesem Durchgang in umgekehrter Reihenfolge zuruecknehmen - nur, was seitdem unveraendert, nicht zugewiesen und nicht eingeschaltet ist"/>
                    <Button x:Name="btnRevoke" Content="Rechte zurueckgeben" Background="#A65A28" Style="{StaticResource DarkButton}" Padding="12,0" Margin="0,0,8,0"
                            ToolTip="Genau die Rechte entziehen, die dieser Ablauf erteilt hat - fuer alle bisher bearbeiteten Tenants auf einmal, ohne neue Anmeldung solange die Admin-Anmeldung gilt (ca. 60 Min)"/>
                    <Button x:Name="btnCopy" Content="Bericht kopieren" Style="{StaticResource ToolButton}" Padding="10,2" Margin="0,0,8,0" ToolTip="Ergebnis als Text in die Zwischenablage"/>
                    <Button x:Name="btnNextTenant" Background="#1976D2" Style="{StaticResource DarkButton}" Padding="12,0" Visibility="Collapsed"
                            ToolTip="Mit dem naechsten Tenant weitermachen - die erteilten Rechte bleiben bis zum Schluss und werden dann fuer alle Tenants gesammelt zurueckgegeben"/>
                </StackPanel>
                <DataGrid x:Name="gridRun" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Ergebnis" Binding="{Binding Ergebnis}" Width="110"/>
                        <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="140"/>
                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="320"/>
                        <DataGridTextColumn Header="Details" Binding="{Binding Text}" Width="*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </DockPanel>
        </Grid>
        <DockPanel Grid.Row="3" Margin="0,12,0,0" LastChildFill="False">
            <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock x:Name="dotBusy" Text="&#x25CF;" Foreground="#4CAF50" FontSize="13" Margin="0,0,6,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                <TextBlock TextWrapping="Wrap" x:Name="lblBusy" Foreground="#81C784" FontSize="12" VerticalAlignment="Center"/>
            </StackPanel>
            <Button x:Name="btnClose" DockPanel.Dock="Right" Content="Schliessen" Width="110" Background="#555555" Style="{StaticResource DarkButton}"/>
            <Button x:Name="btnNext" DockPanel.Dock="Right" Content="Weiter &#x2192;" MinWidth="130" Padding="12,0" Background="#1976D2" Style="{StaticResource DarkButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnBack" DockPanel.Dock="Right" Content="&#x2190; Zurueck" Width="110" Style="{StaticResource ToolButton}" Margin="0,0,8,0"/>
            <Button x:Name="btnStop" DockPanel.Dock="Right" Content="Abbrechen" Width="110" Background="#B71C1C" Style="{StaticResource DarkButton}" Margin="0,0,8,0" Visibility="Collapsed"
                    ToolTip="Nach dem laufenden Eintrag aufhoeren - der bis dahin geschriebene Stand bleibt rueckgaengig machbar"/>
        </DockPanel>
    </Grid>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $mt = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $mt.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $S = @{ W = $w; C = $c; LoginPending = $false; Sid = [guid]::NewGuid().ToString('N'); Closed = $false; LoginCtl = $null; Sel = $sel; Step = 1; Tenant = ''; Needed = @(); Rights = $null; RightsOk = $false; Bg = $null; Login = $null; Logins = @{}; Queue = @(); Off = @{}
        Rows = @(); Slots = $null; Groups = @{}; Countries = @{}; RunFile = ''; Running = $false; Cancel = [hashtable]::Synchronized(@{ Stop = $false }); Prog = [hashtable]::Synchronized(@{ Lines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Total = 0; Done = $false }) }
    $script:MA = $S
    $c.lblPkgs.Text = "Pakete: $($sel.Titles)"
    $S.Needed = @(Get-HUMaNeededPermissions @($sel.Packages | ForEach-Object { @($_.Items) }))
    # Notfallkonten sind Pflicht, sobald Entra/Conditional Access dabei ist (Intune allein braucht sie nicht)
    $S.NeedBg = [bool]@($sel.Packages | ForEach-Object { @($_.Items) } | Where-Object { (Get-HUMaItemKind "$($_.Typ)" "$($_.Id)") -notin '', 'intune' }).Count
    # Schrittleiste
    $names = @('1 Tenant', '2 Rechte', '3 Zuordnen', '4 Vorschau', '5 Ausfuehren', '6 Abschluss')
    $S.StepLbl = @(foreach ($n in $names) { $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $n; $t.Margin = '0,0,18,0'; $t.FontSize = 12; [void]$c.pnlSteps.Children.Add($t); $t })
    $S.TenantChecks = @(foreach ($t in @($script:Settings.tenants | Where-Object { $_ -and "$($_.key)" })) {
            $ch = New-Object System.Windows.Controls.CheckBox; try { $ch.Style = $w.FindResource('DarkCheckBox') } catch { }
            $ch.Content = (Get-HUAnaTenantName "$($t.key)"); $ch.Tag = "$($t.key)"; $ch.Margin = '0,2,18,2'; $ch.Foreground = Get-HUBrush '#E0E0E0'
            $ch.Add_Checked({ & $script:MA.Upd }); $ch.Add_Unchecked({ & $script:MA.Upd })
            [void]$c.pnlTenants.Children.Add($ch); $ch })
    $S.Queue = @(); $S.QIndex = 0
    $c.lblT1.Text = "Es werden $(@($sel.Packages | ForEach-Object { @($_.Items) }).Count) Eintraege aus $(@($sel.Packages).Count) Paket(en) geprueft. Conditional Access kommt immer NEU im Modus 'Nur Bericht' an, Intune ohne Zuweisungen; die Notfallkonten des Ziels werden ausgenommen.`n`nBenoetigte Schreibrechte: $(if ($S.Needed.Count) { $S.Needed -join ', ' } else { 'keine' })."

    $S.ShowStep = {
        param([int]$n)
        $S = $script:MA; $c = $S.C; $w = $S.W
        $S.Step = $n
        foreach ($i in 1..5) { $c["pg$i"].Visibility = 'Collapsed' }
        $c["pg$([Math]::Min($n, 5))"].Visibility = 'Visible'
        for ($i = 0; $i -lt $S.StepLbl.Count; $i++) {
            $S.StepLbl[$i].Foreground = Get-HUBrush $(if ($i + 1 -lt $n) { '#81C784' } elseif ($i + 1 -eq $n) { '#E0E0E0' } else { '#666666' })
            $S.StepLbl[$i].FontWeight = $(if ($i + 1 -eq $n) { 'SemiBold' } else { 'Normal' })
        }
        $c.btnBack.Visibility = $(if ($n -in 2, 3, 4) { 'Visible' } else { 'Collapsed' })
        $c.btnNext.Visibility = $(if ($n -le 4) { 'Visible' } else { 'Collapsed' })
        $c.btnNext.Content = $(if ($n -eq 4) { "$([char]0x2192) Anwenden" } else { "Weiter $([char]0x2192)" })
        $c.btnNext.Background = Get-HUBrush $(if ($n -eq 4) { '#A65A28' } else { '#1976D2' })
        & $S.Upd
    }
    $S.Upd = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        $ok = switch ($S.Step) {
            1 { [bool]@($S.TenantChecks | Where-Object { $_.IsChecked }).Count }
            2 { $S.RightsOk -and (-not $S.NeedBg -or ($S.Bg -and $S.Bg.Ok)) }
            3 { [bool]@($S.Rows).Count }
            4 { [bool]@($S.Prev | Where-Object { $_.Take }).Count -and "$($c.txtType.Text)".Trim() -eq (Get-HUAnaTenantName $S.Tenant) }
            default { $false }
        }
        $c.btnNext.IsEnabled = [bool]$ok -and -not $S.Busy
        $c.btnBack.IsEnabled = -not $S.Busy
    }
    $S.Busy = $false
    $S.SetBusy = {
        param([string]$t)
        $S = $script:MA; $c = $S.C
        $S.Busy = [bool]$t; $c.lblBusy.Text = $t
        # pulsierender gruener Punkt, solange gelesen/geschrieben wird (wie in der Analyse)
        $d = $c.dotBusy
        if ($t) {
            if ($d.Visibility -ne 'Visible') {
                $an = New-Object System.Windows.Media.Animation.DoubleAnimation
                $an.From = 1.0; $an.To = 0.2; $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
                $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                $d.Visibility = 'Visible'; $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
            }
        } else { $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $d.Opacity = 1.0; $d.Visibility = 'Collapsed' }
        & $S.Upd
    }

    # ---- Schritt 2: Rechte und Notfallkonten lesen
    $S.CheckRights = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        & $S.SetBusy 'Rechte und Notfallkonten werden gelesen ...'
        $c.lblT2.Text = "Benoetigt fuer die gewaehlten Pakete: $(if ($S.Needed.Count) { $S.Needed -join ', ' } else { 'keine Schreibrechte' }). Es werden nur fehlende Rechte erteilt - und am Ende genau diese wieder zurueckgegeben."
        [void](Start-HUJob -Name 'MaRights' -Quiet -Vars @{ TK = $S.Tenant; Need = @($S.Needed) } -Code {
                $roles = Get-HUMaTokenRoles $TK $Settings
                $bg = Test-HUEntraBreakGlass -TenantKey $TK -Settings $Settings
                [pscustomobject]@{ __Ma = $true; Roles = $roles; Bg = $bg }
            } -OnDone {
                param($Result, $Errors)
                $S2 = $script:MA; if (-not $S2) { return }
                & $S2.SetBusy ''
                $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Ma'] }) | Select-Object -First 1
                if (-not $r) { $S2.C.lblBg.Text = 'Lesen fehlgeschlagen (siehe Protokoll).'; return }
                $rows = Get-HUMaRightsRows @($S2.Needed) $r.Roles
                $S2.C.gridRights.ItemsSource = @($rows)
                $S2.Missing = @($rows | Where-Object { $_.Status -ne 'vorhanden' } | ForEach-Object { $_.Recht })
                $S2.Present = @($rows | Where-Object { $_.Status -eq 'vorhanden' } | ForEach-Object { $_.Recht })
                $S2.RightsOk = -not $S2.Missing.Count
                $S2.Bg = $r.Bg
                $S2.C.lblBg.Text = "Notfallkonten: $($r.Bg.Text)$(if (-not $S2.NeedBg) { ' (fuer diese Pakete nicht noetig)' })"
                $S2.C.lblBg.Foreground = Get-HUBrush $(if ($r.Bg.Ok) { '#81C784' } elseif (-not $S2.NeedBg) { '#AAAAAA' } else { '#EF5350' })
                $S2.C.btnGrant.IsEnabled = [bool]$S2.Missing.Count
                & $S2.Upd
            })
    }
    $c.btnRecheck.Add_Click({ & $script:MA.CheckRights })
    $c.btnGrant.Add_Click({
            $S2 = $script:MA
            $miss = @($S2.Missing)
            if (-not $miss.Count) { return }
            if (-not (Confirm-HU -Warning "Fuer $(Get-HUAnaTenantName $S2.Tenant) diese Rechte erteilen?`n`n$($miss -join "`n")`n`nNur fuer diesen Ablauf: am Ende 'Rechte zurueckgeben' entzieht genau diese wieder. Es oeffnet sich der Browser zur Admin-Anmeldung." -Owner $S2.W)) { return }
            # Markierung VOR dem Erteilen (Absturz-Sicherung)
            try { [void](Write-HUMaMarker -TenantKey $S2.Tenant -TenantName (Get-HUAnaTenantName $S2.Tenant) -Planned $miss -Before @($S2.Present) -Stage 'vor dem Erteilen') } catch { Show-HUMessage "Markierung nicht schreibbar - es wird nichts erteilt: $($_.Exception.Message)" -Icon Error -Owner $S2.W; return }
            & $S2.SetBusy 'Bitte im Browser als Admin anmelden ...'
            # Anmeldung laeuft: bis zur Rueckmeldung ist sicher nichts erteilt (erteilt wird erst danach)
            $S2.LoginPending = $true
            $ok = Start-HUMaAdminLogin $S2.Tenant {
                param($L, $Sid)
                $S3 = $script:MA
                # 069 B1: Fenster inzwischen geschlossen (oder ein neuer Assistent offen) -> nichts erteilen
                if (-not (Test-HUMaLoginCurrent $S3 $Sid)) { Write-HULog -Message 'Muster anwenden: Admin-Anmeldung kam nach dem Schliessen zurueck - nichts erteilt.' -Level 'WARN'; return }
                $S3.LoginPending = $false
                & $S3.SetBusy ''
                if (-not $L.Ok) { Clear-HUMaPlannedRights $S3.Tenant; Show-HUMessage "Nicht erteilt: $($L.Error)" -Icon Error -Owner $S3.W; return }
                if (-not (Test-HUAdminCanGrant $L)) { Clear-HUMaPlannedRights $S3.Tenant; Show-HUMessage 'Das angemeldete Konto darf keine App-Rechte erteilen (Global Admin oder Privileged Role Admin noetig). Nichts geaendert.' -Icon Warning -Owner $S3.W; return }
                $S3.Login = $L; $S3.Logins[$S3.Tenant] = $L
                $t = Get-HUMaTenant $S3.Tenant
                $added = @()
                try { $added = @(Add-HUAppPermissions -Login $L -AppId "$($t.appId)" -Permissions @($S3.Missing)) }
                # Fehler mittendrin: Markierung mit den geplanten Rechten bleibt (Teil kann erteilt sein) -> Zurueckgeben/Erinnerung greift
                catch { try { [void](Write-HUMaMarker -TenantKey $S3.Tenant -Stage 'Fehler beim Erteilen') } catch { }; Show-HUMessage "Erteilen fehlgeschlagen: $(Get-HUSetupErrorText $_)`n`nWas schon erteilt ist, gibt 'Rechte zurueckgeben' wieder zurueck." -Icon Error -Owner $S3.W; return }
                # geklappt: offen bleibt genau, was wirklich dazugekommen ist
                try { [void](Write-HUMaMarker -TenantKey $S3.Tenant -Added $added -ClearPlanned -Stage 'erteilt') } catch { }
                Write-HULog -Message "Muster anwenden: Rechte erteilt ($(Get-HUAnaTenantName $S3.Tenant)): $(if ($added.Count) { $added -join ', ' } else { 'schon vorhanden' }) (durch $($L.Upn))" -Level 'OK'
                try { Clear-TokenCache -TenantKey $S3.Tenant } catch { }
                # neues App-Token: erteilte Rechte stehen erst nach kurzer Zeit darin - bis zu 3 Minuten nachfragen
                & $S3.SetBusy 'Warte, bis die Rechte im Token stehen (bis zu 3 Minuten) ...'
                [void](Start-HUJob -Name 'MaWaitRights' -Quiet -Vars @{ TK = $S3.Tenant; Need = @($S3.Needed) } -Code {
                        $roles = $null
                        for ($i = 0; $i -lt 18; $i++) {
                            $roles = Get-HUMaTokenRoles $TK $Settings
                            if ($null -ne $roles -and -not @($Need | Where-Object { @($roles) -notcontains $_ }).Count) { break }
                            Start-Sleep -Seconds 10
                        }
                        [pscustomobject]@{ __Ma = $true; Roles = $roles }
                    } -OnDone {
                        param($Result, $Errors)
                        $S4 = $script:MA; if (-not $S4) { return }
                        & $S4.SetBusy ''
                        & $S4.CheckRights
                    })
            } $S2.Sid
            $S2.LoginCtl = $ok
            if (-not $ok) { $S2.LoginPending = $false; Clear-HUMaPlannedRights $S2.Tenant; & $S2.SetBusy '' }
        })

    # ---- Schritt 3: Plan lesen und Zuordnen aufbauen
    $S.BuildMap = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        $c.pnlMap.Children.Clear()
        $sl = $S.Slots
        $addTb = { param([string]$t, [string]$col = '#CCCCCC', [switch]$Bold) $b = New-Object System.Windows.Controls.TextBlock; $b.Text = $t; $b.Foreground = Get-HUBrush $col; $b.FontSize = 12; $b.TextWrapping = 'Wrap'; $b.Margin = '0,6,0,2'; if ($Bold) { $b.FontWeight = 'SemiBold' }; [void]$c.pnlMap.Children.Add($b) }
        if (-not @($sl.Slots).Count -and -not @($sl.Countries).Count) { & $addTb 'Keine Zuordnung noetig - die gewaehlten Pakete verweisen auf keine Gruppen und keine waehlbaren Laender.'; return }
        if (@($sl.Slots).Count) {
            & $addTb 'Gruppen: je Platz eine Gruppe im Ziel waehlen (gleichnamige sind vorgewaehlt, leer = nicht zuweisen). Gilt fuer alle Richtlinien mit diesem Platz.' -Bold
            foreach ($slot in @($sl.Slots)) {
                $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = '0,3,0,3'
                $tb = New-Object System.Windows.Controls.TextBlock; $tb.Text = "$(if ($slot.Feld -eq 'includeGroups') { 'Gilt fuer' } else { 'Ausgenommen' }) '$($slot.Slot)'"; $tb.Foreground = Get-HUBrush '#90CAF9'; $tb.FontSize = 12; $tb.MinWidth = 280; $tb.VerticalAlignment = 'Center'
                $tb.ToolTip = "Verwendet in: $(@($slot.Used) -join ', ')"
                $cb = New-Object System.Windows.Controls.ComboBox; try { $cb.Style = $w.FindResource('DarkComboBox') } catch { }
                $cb.MinWidth = 340; $cb.FontSize = 12; $cb.IsTextSearchEnabled = $true
                $first = New-Object System.Windows.Controls.ComboBoxItem; $first.Content = '(nicht zuweisen)'; $first.Tag = ''; [void]$cb.Items.Add($first)
                $selIx = 0; $ix = 0
                $want = $(if ($S.Groups.ContainsKey($slot.Slot)) { "$($S.Groups[$slot.Slot])" } else { "$($slot.Value)" })
                foreach ($g in @($slot.Choices)) { if (-not $g) { continue }; $ix++; $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = "$($g.Name)"; $ci.Tag = "$($g.Id)"; [void]$cb.Items.Add($ci); if ($want -and "$($g.Id)" -eq $want) { $selIx = $ix } }
                $cb.SelectedIndex = $selIx
                $S.Groups[$slot.Slot] = $(if ($selIx) { $want } else { '' })
                $cb.Tag = $slot.Slot
                $cb.Add_SelectionChanged({ $it = $this.SelectedItem; $script:MA.Groups["$($this.Tag)"] = $(if ($it) { "$($it.Tag)" } else { '' }) })
                [void]$sp.Children.Add($tb); [void]$sp.Children.Add($cb); [void]$c.pnlMap.Children.Add($sp)
            }
        }
        if (@($sl.Countries).Count) {
            & $addTb "Erlaubte Laender fuer '$(@($sl.Countries)[0].Ort)' (fest dabei bleibt, was das Paket vorgibt):" -Bold
            foreach ($k in @($sl.Countries)) {
                $ch = New-Object System.Windows.Controls.CheckBox; try { $ch.Style = $w.FindResource('DarkCheckBox') } catch { }
                $ch.Content = "$($k.Text)"; $ch.Foreground = Get-HUBrush '#90CAF9'; $ch.Margin = '0,2,0,2'; $ch.Tag = $k.Code
                $ch.IsChecked = $(if ($S.Countries.ContainsKey($k.Code)) { [bool]$S.Countries[$k.Code] } else { [bool]$k.Value })
                $S.Countries[$k.Code] = [bool]$ch.IsChecked
                $ch.Add_Checked({ $script:MA.Countries["$($this.Tag)"] = $true }); $ch.Add_Unchecked({ $script:MA.Countries["$($this.Tag)"] = $false })
                [void]$c.pnlMap.Children.Add($ch)
            }
        }
    }
    $S.LoadPlan = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        & $S.SetBusy 'Pakete werden fuer das Ziel geprueft ...'
        $c.lblT3.Text = 'Pakete werden im Ziel geprueft ...'
        [void](Start-HUJob -Name 'MaPlan' -Quiet -Vars @{ TK = $S.Tenant; Pk = @($S.Sel.Packages) } -Code {
                try { [pscustomobject]@{ __Ma = $true; Rows = @(Get-HUMaPlan -Settings $Settings -TargetKey $TK -Packages $Pk); Loc = (Get-HUMusterLocationNames @($Pk | ForEach-Object { $_.Folder })) } }
                catch { [pscustomobject]@{ __Ma = $true; Error = "$($_.Exception.Message)" } }
            } -OnDone {
                param($Result, $Errors)
                $S2 = $script:MA; if (-not $S2) { return }
                & $S2.SetBusy ''
                $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Ma'] }) | Select-Object -First 1
                if (-not $r -or $r.PSObject.Properties['Error']) { $S2.C.lblT3.Text = "Pruefen fehlgeschlagen: $(if ($r) { $r.Error } else { 'siehe Protokoll' })"; return }
                $S2.Rows = @($r.Rows); $S2.Loc = $r.Loc
                $S2.Slots = Get-HUMaSlots $S2.Rows
                $n = @($S2.Rows | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
                $S2.C.lblT3.Text = "Geprueft: $(@($S2.Rows).Count) Eintraege ($n)."
                & $S2.BuildMap
                & $S2.Upd
            })
    }

    # ---- Schritt 4: Vorschau
    $S.BuildPrev = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        foreach ($r in @($S.Rows | Where-Object { $_.Plan })) { Set-HUMaChoices $r.Plan $S.Groups $S.Countries }
        $map = @{ neu = 'Neu'; angleichen = 'Angleichen'; gleich = 'schon gleich'; wartet = 'Neu (nach Ort)'; gesperrt = 'GESPERRT' }
        # beim vorigen Tenant abgewaehlte Eintraege bleiben aus (nur Abwahl wird uebernommen - Angleichen/Zusatzkopien nie automatisch an)
        $S.Prev = @(foreach ($r in @($S.Rows)) {
                $off = $S.Off.ContainsKey("$($r.Typ)|$($r.Name)".ToLowerInvariant())
                [pscustomobject]@{ Take = ([bool]$r.Default -and -not $off); CanTake = ($r.Status -notin 'gesperrt', 'gleich'); StatusText = "$($map[$r.Status])"; Status = $r.Status; Typ = $r.Typ; Name = $r.Name; Paket = $r.Paket; Reason = $r.Reason; Row = $r }
            })
        $c.gridPrev.ItemsSource = $S.Prev
        $cnt = { param($st) @($script:MA.Rows | Where-Object { $_.Status -eq $st }).Count }
        $nOff = @($S.Prev | Where-Object { $_.Row.Default -and -not $_.Take }).Count
        $c.lblT4.Text = "$(if ($nOff) { "$nOff Eintrag/Eintraege wie beim vorigen Tenant abgewaehlt.   |   " })Neu: $((& $cnt 'neu') + (& $cnt 'wartet'))   |   Angleichen: $(& $cnt 'angleichen') (nur mit Haken - aendert Bestehendes)   |   schon gleich: $(& $cnt 'gleich')   |   gesperrt: $(& $cnt 'gesperrt')`nReihenfolge beim Anwenden: Orte -> Entra-Einstellungen -> Intune -> Conditional Access. Vor jedem Eintrag wird das Ziel erneut geprueft."
        $c.lblType.Text = "Zum Bestaetigen '$(Get-HUAnaTenantName $S.Tenant)' eintippen:"
        $c.txtType.Text = ''
        & $S.Upd
    }
    $c.gridPrev.Add_BeginningEdit({ param($sd, $e) $it = $e.Row.Item; if ($it -and $it.Status -in 'gesperrt', 'gleich') { $e.Cancel = $true } })
    $c.gridPrev.Add_CurrentCellChanged({ & $script:MA.Upd })
    $c.gridPrev.Add_PreviewMouseLeftButtonUp({ $t = $script:MA; if ($t) { [void]$t.W.Dispatcher.BeginInvoke([action]{ & $script:MA.Upd }) } })
    $c.txtType.Add_TextChanged({ & $script:MA.Upd })
    # Alle an/aus: nur anwendbare Zeilen (gesperrt/gleich bleiben aus); Raster neu zeichnen, weil die Zeilen keine Aenderungsmeldung senden
    $S.SetAll = {
        param([bool]$On)
        $S = $script:MA
        [void]$S.C.gridPrev.CommitEdit()
        foreach ($p in @($S.Prev)) { $p.Take = ($On -and $p.CanTake) }
        $S.C.gridPrev.Items.Refresh()
        & $S.Upd
    }
    $c.btnAllOn.Add_Click({ & $script:MA.SetAll $true })
    $c.btnAllOff.Add_Click({ & $script:MA.SetAll $false })

    # ---- Schritt 5: Ausfuehren (im Hintergrund, Fortschritt ueber geteilte Tabelle, Abbruch nach dem laufenden Eintrag)
    $S.Run = {
        $S = $script:MA; $c = $S.C; $w = $S.W
        $todo = @($S.Prev | Where-Object { $_.Take -and $_.Status -notin 'gesperrt', 'gleich' } | ForEach-Object { $_.Row } | Sort-Object Order, Typ, Name)
        if (-not $todo.Count) { return }
        # Abwahl fuer die naechsten Tenants merken; wieder angehakt -> vergessen
        foreach ($p in @($S.Prev | Where-Object { $_.CanTake })) {
            $k = "$($p.Typ)|$($p.Name)".ToLowerInvariant()
            if ($p.Take) { [void]$S.Off.Remove($k) } elseif ($p.Row.Default) { $S.Off[$k] = $true }
        }
        & $S.ShowStep 5
        $S.Running = $true; $S.Cancel.Stop = $false
        $S.Prog.Lines.Clear(); $S.Prog.Total = $todo.Count; $S.Prog.Done = $false; $S.Prog.Cur = ''
        $c.prg.Maximum = $todo.Count; $c.prg.Value = 0
        $c.btnStop.Visibility = 'Visible'; $c.btnClose.IsEnabled = $false
        & $S.SetBusy 'Wird angewendet ...'
        $c.lblT5.Text = "Wird angewendet: $($todo.Count) Eintraege nach $(Get-HUAnaTenantName $S.Tenant) ..."
        try { [void](Write-HUMaMarker -TenantKey $S.Tenant -Stage 'laeuft') } catch { }
        $rows = @($todo | ForEach-Object { [pscustomobject]@{ Order = $_.Order; Typ = $_.Typ; Name = $_.Name; Paket = $_.Paket; PaketId = $_.PaketId; Folder = $_.Folder; File = $_.File; Id = $_.Id; Source = $_.Source } })
        $tm = New-Object System.Windows.Threading.DispatcherTimer; $tm.Interval = [TimeSpan]::FromMilliseconds(600)
        $tm.Add_Tick({
                $S2 = $script:MA; if (-not $S2) { $this.Stop(); return }
                $S2.C.gridRun.ItemsSource = @($S2.Prog.Lines.ToArray())
                $S2.C.prg.Value = $S2.Prog.Lines.Count
                if (-not $S2.Prog.Done -and "$($S2.Prog.Cur)" -and -not $S2.Cancel.Stop) { $S2.C.lblT5.Text = "Wird angewendet ($($S2.Prog.Lines.Count + 1) von $($S2.Prog.Total)): $($S2.Prog.Cur) ..." }
                if ($S2.Prog.Done) { $this.Stop() }
            })
        $tm.Start()
        [void](Start-HUJob -Name 'MaRun' -Vars @{ TK = $S.Tenant; Rows = $rows; G = $S.Groups; K = $S.Countries; Loc = $(if ($S.Loc) { $S.Loc } else { @{} }); Cancel = $S.Cancel; Prog = $S.Prog; Pk = @($S.Sel.Packages | ForEach-Object { $_.Title }) } -Code {
                $run = New-HUMaRun -Settings $Settings -TenantKey $TK -Packages $Pk
                $state = 'fertig'
                foreach ($r in $Rows) {
                    if ($Cancel.Stop) { $state = 'abgebrochen'; [void]$Prog.Lines.Add([pscustomobject]@{ Ergebnis = 'ausgelassen'; Typ = $r.Typ; Name = $r.Name; Text = 'Abgebrochen - nicht angewendet' }); continue }
                    $Prog.Cur = "$($r.Typ): $($r.Name)"
                    $res = Invoke-HUMaStep -Settings $Settings -TargetKey $TK -Row $r -Run $run -Groups $G -Countries $K -LocNames $Loc
                    [void]$Prog.Lines.Add([pscustomobject]@{ Ergebnis = $(if ($res.Ok) { 'ok' } else { 'FEHLER' }); Typ = $r.Typ; Name = $r.Name; Text = "$($res.Text)" })
                    if (-not $res.Ok -and $state -eq 'fertig') { $state = 'mit Fehlern' }
                }
                Complete-HUMaRun $run $state
                $Prog.Done = $true
                [pscustomobject]@{ __Ma = $true; RunFile = $run.File; State = $state }
            } -OnDone {
                param($Result, $Errors)
                $S2 = $script:MA; if (-not $S2) { return }
                $S2.Prog.Done = $true
                $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Ma'] }) | Select-Object -First 1
                $S2.Running = $false
                & $S2.SetBusy ''
                $S2.C.btnStop.Visibility = 'Collapsed'; $S2.C.btnClose.IsEnabled = $true
                $S2.C.gridRun.ItemsSource = @($S2.Prog.Lines.ToArray())
                $S2.RunFile = $(if ($r) { $r.RunFile } else { '' })
                $ok = @($S2.Prog.Lines | Where-Object { $_.Ergebnis -eq 'ok' }).Count
                $S2.C.lblT5.Text = "Ergebnis: $ok von $($S2.Prog.Total) angewendet$(if ($r) { " ($($r.State))" }). Conditional Access steht auf 'Nur Bericht' - nach der Pruefung im Anmeldeprotokoll im Portal einschalten; Intune ohne Zuweisungen.`n$(if ($S2.QIndex -lt @($S2.Queue).Count - 1) { 'Die erteilten Rechte bleiben bis zum letzten Tenant und werden dann fuer alle gesammelt zurueckgegeben.' } elseif (@(& $S2.OpenRights).Count) { "Jetzt die erteilten Rechte zurueckgeben (Knopf unten, $(@(& $S2.OpenRights).Count) Tenant(s) auf einmal)." } else { 'Es sind keine erteilten Rechte offen.' })"
                for ($i = 0; $i -lt $S2.StepLbl.Count; $i++) { $S2.StepLbl[$i].Foreground = Get-HUBrush $(if ($i -lt 5) { '#81C784' } else { '#E0E0E0' }) }
                $S2.C.pnlDone.Visibility = 'Visible'
                $S2.C.btnUndo.IsEnabled = [bool]$S2.RunFile
                & $S2.UpdRevoke
                if ($S2.QIndex -lt @($S2.Queue).Count - 1) {
                    $S2.C.btnNextTenant.Content = "Weiter mit $(Get-HUAnaTenantName "$($S2.Queue[$S2.QIndex + 1])") $([char]0x2192)"
                    $S2.C.btnNextTenant.Visibility = 'Visible'
                }
            })
    }
    $c.btnStop.Add_Click({ $script:MA.Cancel.Stop = $true; $script:MA.C.btnStop.IsEnabled = $false; $script:MA.C.lblT5.Text = 'Wird nach dem laufenden Eintrag beendet ...' })
    # bisher bearbeitete Tenants des Durchgangs (bis einschliesslich aktuellem)
    $S.Visited = {
        $S = $script:MA
        $q = @($S.Queue); $n = [Math]::Min($S.QIndex, $q.Count - 1)
        $v = @(if ($q.Count) { $q[0..$n] }); if ($S.Tenant -and $v -notcontains $S.Tenant) { $v += $S.Tenant }
        return , @($v | Where-Object { "$_" })
    }
    $S.OpenRights = { $S = $script:MA; return , @(@(& $S.Visited) | Where-Object { @(Get-HUMaOpenRights (Get-HUMaMarker $_)).Count }) }
    $c.btnRevoke.Add_Click({
            $S2 = $script:MA
            & $S2.SetBusy 'Rechte werden zurueckgegeben ...'
            Start-HUMaRevokeAll @(& $S2.Visited) $S2.Logins { param($ok, $txt) $S3 = $script:MA; if ($S3) { & $S3.SetBusy ''; & $S3.UpdRevoke }; Show-HUMessage "Rechte zurueckgegeben:`n`n$txt$(if ($ok) { "`n`nEin schon geholtes App-Token kann sie noch bis zu einer Stunde enthalten." })" -Icon $(if ($ok) { 'Info' } else { 'Warning' }) -Owner $(if ($S3) { $S3.W }) } $S2.W
        })
    # Knopftext: wie viele Tenants haben noch offene Rechte
    $S.UpdRevoke = {
        $S = $script:MA; $o = @(& $S.OpenRights)
        $S.C.btnRevoke.Content = $(if ($o.Count -gt 1) { "Rechte zurueckgeben ($($o.Count) Tenants)" } elseif ($o.Count) { 'Rechte zurueckgeben' } else { 'Rechte zurueckgegeben' })
        $S.C.btnRevoke.IsEnabled = [bool]$o.Count
    }
    $c.btnUndo.Add_Click({
            $S2 = $script:MA
            if (-not $S2.RunFile) { return }
            if (-not (Confirm-HU "Alles aus diesem Durchgang in $(Get-HUAnaTenantName $S2.Tenant) zuruecknehmen?`n`nIn umgekehrter Reihenfolge; nur, was seitdem unveraendert, nicht zugewiesen und nicht eingeschaltet ist. Angeglichenes wird auf den gesicherten Stand zurueckgesetzt." -Warning -Owner $S2.W)) { return }
            & $S2.SetBusy 'Wird zurueckgenommen ...'
            [void](Start-HUJob -Name 'MaUndo' -Vars @{ F = $S2.RunFile } -Code { [pscustomobject]@{ __Ma = $true; Res = @(Undo-HUMaRun -Settings $Settings -File $F) } } -OnDone {
                    param($Result, $Errors)
                    $S3 = $script:MA; if (-not $S3) { return }
                    & $S3.SetBusy ''
                    $r = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__Ma'] }) | Select-Object -First 1
                    if (-not $r) { Show-HUMessage 'Rueckgaengig: kein Ergebnis (siehe Protokoll).' -Icon Error -Owner $S3.W; return }
                    $S3.C.gridRun.ItemsSource = @($r.Res | ForEach-Object { [pscustomobject]@{ Ergebnis = $(if ($_.Ok) { 'zurueck' } else { 'NICHT' }); Typ = $_.Typ; Name = $_.Name; Text = $_.Text } })
                    $bad = @($r.Res | Where-Object { -not $_.Ok }).Count
                    $S3.C.lblT5.Text = $(if ($bad) { "Rueckgaengig: $bad Eintrag/Eintraege NICHT zurueckgenommen (Grund in der Tabelle) - bitte im Portal pruefen." } else { 'Rueckgaengig: alles zurueckgenommen.' })
                })
        })
    $c.btnCopy.Add_Click({
            $S2 = $script:MA
            $txt = "Muster anwenden - $(Get-HUAnaTenantName $S2.Tenant) - $((Get-Date).ToString('dd.MM.yyyy HH:mm'))`r`nPakete: $($S2.Sel.Titles)`r`n`r`n" + ((@($S2.C.gridRun.ItemsSource) | ForEach-Object { "$($_.Ergebnis)`t$($_.Typ)`t$($_.Name)`t$($_.Text)" }) -join "`r`n")
            try { [System.Windows.Clipboard]::SetText($txt) } catch { }
        })

    # ---- naechster Tenant der Warteschlange: Sperre, Zustand je Tenant zuruecksetzen (Laenderwahl bleibt), dann Rechte
    $S.StartTenant = {
        $S = $script:MA; $c = $S.C
        $tk = "$($S.Queue[$S.QIndex])"
        if ($S.Tenant -and $S.Tenant -ne $tk) { Exit-HUMaLock $S.Tenant }
        try { Enter-HUMaLock $tk } catch { Show-HUMessage "$($_.Exception.Message)" -Icon Warning -Owner $S.W; return $false }
        $S.Tenant = $tk; $S.Rows = @(); $S.Groups = @{}; $S.RightsOk = $false; $S.Bg = $null; $S.Login = $null; $S.RunFile = ''; $S.Missing = @(); $S.Present = @()
        $S.Prog.Lines.Clear(); $S.Prog.Total = 0; $S.Prog.Done = $false
        $c.gridRun.ItemsSource = $null; $c.gridRights.ItemsSource = $null; $c.pnlMap.Children.Clear(); $c.lblBg.Text = ''
        $c.pnlDone.Visibility = 'Collapsed'; $c.btnNextTenant.Visibility = 'Collapsed'; $c.prg.Value = 0
        foreach ($ch in @($S.TenantChecks)) { $ch.IsEnabled = $false }
        $c.lblTitle.Text = "Muster anwenden - $(Get-HUAnaTenantName $tk)$(if (@($S.Queue).Count -gt 1) { "  (Tenant $($S.QIndex + 1) von $(@($S.Queue).Count))" })"
        & $S.ShowStep 2
        & $S.CheckRights
        return $true
    }
    $c.btnNextTenant.Add_Click({
            # Rechte bleiben (Markierung + gemerkte Anmeldung) und werden am Ende fuer alle Tenants gesammelt zurueckgegeben
            $S2 = $script:MA
            $m = Get-HUMaMarker $S2.Tenant
            if ($m -and -not @(Get-HUMaOpenRights $m).Count) { Remove-HUMaMarker $S2.Tenant }
            $S2.QIndex++; [void](& $S2.StartTenant)
        })

    # ---- Navigation
    $c.btnNext.Add_Click({
            $S2 = $script:MA
            switch ($S2.Step) {
                1 {
                    $S2.Queue = @($S2.TenantChecks | Where-Object { $_.IsChecked } | ForEach-Object { "$($_.Tag)" })
                    $S2.QIndex = 0
                    [void](& $S2.StartTenant)
                }
                2 { & $S2.ShowStep 3; if (-not @($S2.Rows).Count) { & $S2.LoadPlan } }
                3 { & $S2.BuildPrev; & $S2.ShowStep 4 }
                4 {
                    $n = @($S2.Prev | Where-Object { $_.Take -and $_.Status -notin 'gesperrt', 'gleich' }).Count
                    $al = @($S2.Prev | Where-Object { $_.Take -and $_.Status -eq 'angleichen' }).Count
                    if (-not (Confirm-HU "$n Eintrag/Eintraege jetzt nach $(Get-HUAnaTenantName $S2.Tenant) anwenden?$(if ($al) { "`n`nDavon $al ANGLEICHEN (bestehende Objekte werden geaendert, vorher gesichert)." })`n`nConditional Access: neu, Nur Bericht. Intune: ohne Zuweisungen." -Warning -Owner $S2.W)) { return }
                    & $S2.Run
                }
            }
        })
    $c.btnBack.Add_Click({
            $S2 = $script:MA
            if ($S2.Step -eq 2) {
                # zurueck zur Tenant-Auswahl nur vor dem ersten Tenant; danach geht es nur vorwaerts (Abschluss -> naechster Tenant)
                if ($S2.QIndex -gt 0) { return }
                $m = Get-HUMaMarker $S2.Tenant
                if (-not @(Get-HUMaOpenRights $m).Count) { if ($m) { Remove-HUMaMarker $S2.Tenant }; Exit-HUMaLock $S2.Tenant; $S2.Tenant = '' }
                foreach ($ch in @($S2.TenantChecks)) { $ch.IsEnabled = $true }
            }
            & $S2.ShowStep ($S2.Step - 1)
        })
    $c.btnClose.Add_Click({ $script:MA.W.Close() })
    $w.Add_Closing({
            param($sd, $e)
            $S2 = $script:MA; if (-not $S2) { return }
            if ($S2.Running) { Show-HUMessage 'Es wird gerade angewendet - erst abbrechen (Knopf Abbrechen) und das Ende abwarten.' -Icon Warning -Owner $S2.W; $e.Cancel = $true; return }
            # Schliessen, waehrend die Admin-Anmeldung noch offen ist: es wurde nichts erteilt -> geplante Rechte verwerfen, nicht nachfragen
            if ($S2.LoginPending -and $S2.Tenant) {
                Clear-HUMaPlannedRights $S2.Tenant; $S2.LoginPending = $false
                # 069 B1: auf die Anmeldung nicht mehr warten - kommt sie doch zurueck, wird nichts erteilt (Test-HUMaLoginCurrent)
                if ($S2.LoginCtl -is [hashtable] -and $S2.LoginCtl.Timer) { try { $S2.LoginCtl.Timer.Stop() } catch { } }
            }
            $open = @(& $S2.OpenRights)
            if ($open.Count) {
                $lst = ($open | ForEach-Object { "$(Get-HUAnaTenantName $_): $(@(Get-HUMaOpenRights (Get-HUMaMarker $_)) -join ', ')" }) -join "`n"
                $a = Confirm-HUYesNoCancel "Die erteilten Rechte sind noch nicht zurueckgegeben:`n`n$lst`n`nJa = jetzt alle zurueckgeben, Nein = spaeter (Erinnerung beim naechsten Start), Abbrechen = Fenster offen lassen." -Owner $S2.W
                if ($a -eq 'Cancel') { $e.Cancel = $true; return }
                if ($a -eq 'Yes') {
                    $e.Cancel = $true
                    & $S2.SetBusy 'Rechte werden zurueckgegeben ...'
                    Start-HUMaRevokeAll $open $S2.Logins { param($ok, $txt) $S3 = $script:MA; if ($S3) { & $S3.SetBusy '' }; Show-HUMessage "Rechte zurueckgegeben:`n`n$txt" -Icon $(if ($ok) { 'Info' } else { 'Warning' }) -Owner $(if ($S3) { $S3.W }); if ($ok -and $S3) { $S3.W.Close() } elseif ($S3) { & $S3.UpdRevoke } } $S2.W
                    return
                }
            }
            if ($S2.Tenant) { $m = Get-HUMaMarker $S2.Tenant; if ($m -and -not @(Get-HUMaOpenRights $m).Count) { Remove-HUMaMarker $S2.Tenant } }
            if ($S2.Tenant) { Exit-HUMaLock $S2.Tenant }
            $S2.Closed = $true
            $script:MA = $null
        })
    & $S.ShowStep 1
    $w.Show()
}
