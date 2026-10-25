#Requires -Version 5.1
<#
.SYNOPSIS
    Reiter "Muster": Bibliothek der Muster-Pakete (Soll-Einstellungen) - anlegen, bearbeiten, duplizieren, loeschen und
    fuer den Tenant-Vergleich anhaken. Logik in Core\HU.Muster.psm1; hier nur die Oberflaeche.
.DESCRIPTION
    Pakete werden aus den Backup-Staenden der eigenen Tenants zusammengestellt (auch gemischt). Angehakte Pakete laufen im
    Tenant-Vergleich als Spalte "Muster" mit und sind dort Quelle fuers Uebertragen. Es wird nichts in Tenants geschrieben.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:MuPkgs = @()
$script:MuCur = ''
$script:MuDotWanted = $false
$script:MuListBusy = $false
$script:MuDetailName = ''

# --------------------------- Auswahl (angehakte Pakete) ---------------------------

function Get-HUMuSelIds { return @(@(Get-HUStateValue 'musterSel' @()) | Where-Object { "$_" } | ForEach-Object { "$_" }) }
function Set-HUMuSelIds([string[]]$Ids) {
    Set-HUStateValue 'musterSel' @(@($Ids) | Where-Object { $_ } | Select-Object -Unique)
    try { Save-HUUIState } catch { }
}
# Auswahl fuer Vergleich und Uebertragen ($null = nichts angehakt)
function Get-HUMusterSelectionUi {
    try { return (Get-HUMusterSelection $script:Settings (Get-HUMuSelIds)) } catch { return $null }
}

# Hinweis je Eintrag (z. B. von Microsoft verwaltete CA-Richtlinie: legt Microsoft in jedem Tenant selbst an, nicht uebertragbar)
# 2.5.1 Notiz im Tooltip der Bibliothek: gekuerzt und umbrochen (die ganze Notiz steht rechts im Paket)
function Get-HUMuTipNote([string]$Note, [int]$Max = 240, [int]$Line = 90) {
    $t = ("$Note" -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $cut = $t.LastIndexOf(' ', $Max); if ($cut -lt 20) { $cut = $Max }; $t = $t.Substring(0, $cut).TrimEnd(' ', ',', '.', ';') + ' ... (ganze Notiz rechts)' }
    $out = New-Object System.Text.StringBuilder; $len = 0
    foreach ($wd in $t.Split(' ')) {
        if ($len -and ($len + $wd.Length) -gt $Line) { [void]$out.Append("`n"); $len = 0 } elseif ($len) { [void]$out.Append(' '); $len++ }
        [void]$out.Append($wd); $len += $wd.Length
    }
    return $out.ToString()
}

function Get-HUMuItemHint([string]$Typ, [string]$Name, [string]$Source = '') {
    if ($Typ -eq 'Conditional Access' -and $Name -like 'Microsoft-managed:*') { return 'von Microsoft verwaltet, nicht uebertragbar' }
    if ((Test-HUMusterBuiltinSource $Source) -and $Typ -eq 'Conditional Access') { return 'Uebertragen: neu, Nur Bericht, ohne Zuweisung' }
    if ((Test-HUMusterBuiltinSource $Source) -and $Typ -eq 'Compliance') { return 'Uebertragen: neu, ohne Zuweisung' }
    return ''
}

function Get-HUMuStandText([string]$Stand) {
    try { return ([datetime]::ParseExact($Stand, 'yyyy-MM-dd_HHmmss', $null)).ToString('dd.MM.yyyy HH:mm') } catch { return $Stand }
}

# --------------------------- Lauf-Anzeige ---------------------------

function Test-HUMuJobRunning {
    $o = $script:Controls['rtbMu']
    if (-not $o -or -not $script:HUJobs) { return $false }
    foreach ($s in @($script:HUJobs.Values)) { if ($s -and -not $s.Done -and [object]::ReferenceEquals($s.Output, $o)) { return $true } }
    return $false
}
function Update-HUMuRunDot {
    $d = $script:Controls['dotMuRun']
    if (-not $d) { return }
    $on = [bool]$script:MuDotWanted -or (Test-HUMuJobRunning)
    if ($on) {
        if ($d.Visibility -eq 'Visible') { return }
        $an = New-Object System.Windows.Media.Animation.DoubleAnimation
        $an.From = 1.0; $an.To = 0.2; $an.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))
        $an.AutoReverse = $true; $an.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $d.Visibility = 'Visible'
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $an)
    } else {
        $d.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $d.Opacity = 1.0; $d.Visibility = 'Collapsed'
    }
}

# --------------------------- Bibliothek (links) ---------------------------

function Update-HUMuList([string]$SelectId = '') {
    $c = $script:Controls
    try { $script:MuPkgs = @(Get-HUMusterPackages $script:Settings) }
    catch { $script:MuPkgs = @(); Add-HURtbLine $c['rtbMu'] "Bibliothek nicht lesbar: $($_.Exception.Message)" '#EF5350' }
    # Auswahl nie automatisch leeren (z. B. Backup-Ordner kurz nicht erreichbar) - unbekannte Ids ignoriert Get-HUMusterSelection
    $sel = @(Get-HUMuSelIds)
    $words = @("$($c['txtMuFilter'].Text)" -split '\s+' | Where-Object { $_ })
    $rows = foreach ($p in $script:MuPkgs) {
        $ok = $true
        foreach ($w in $words) {
            if ($w.StartsWith('#')) { $t = $w.TrimStart('#'); if (-not $t) { continue }; if (-not @($p.Tags | Where-Object { $_ -like "*$t*" }).Count) { $ok = $false } }
            elseif (("$($p.Title) $($p.Category) $($p.Note) $($p.TagText)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false }
        }
        if (-not $ok) { continue }
        $herk = @($p.Sources | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', '
        $sub = @(@($p.TagText) + @($herk) | Where-Object { $_ }) -join '  |  '
        $lock = if ($p.BuiltIn) { "$([char]::ConvertFromUtf32(0x1F512)) " } else { '' }
        [pscustomobject]@{
            Id = $p.Id; Title = "$lock$($p.Title)"; Category = $p.Category; Count = $p.Count; Sel = ($sel -contains $p.Id); Sub = $sub
            Tip = "$($p.Title)$(if ($p.BuiltIn) { "`nMitgeliefert - schreibgeschuetzt, zum Anpassen duplizieren" })`n$($p.Category) - $($p.Count) Eintraege$(if ($p.Complete) { ' - Gesamtstand (im Vergleich zaehlt auch, was fehlt)' } else { ' - Teilpaket (prueft nur seine Eintraege)' })`nHerkunft: $herk`nGeaendert: $($p.ChangedText)$(if ($p.Note) { "`n$(Get-HUMuTipNote $p.Note)" })"
        }
    }
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView(@($rows))
    if ($view -and $view.CanGroup) { $view.GroupDescriptions.Clear(); [void]$view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('Category'))) }
    $script:MuListBusy = $true
    $c['lstMuPkg'].ItemsSource = $view
    $want = if ($SelectId) { $SelectId } else { $script:MuCur }
    $hit = @($rows | Where-Object { $_.Id -eq $want }) | Select-Object -First 1
    if (-not $hit) { $hit = @($rows) | Select-Object -First 1 }
    $c['lstMuPkg'].SelectedItem = $hit
    $script:MuListBusy = $false
    $script:MuCur = $(if ($hit) { $hit.Id } else { '' })
    Update-HUMuSelText
    Update-HUMuDetail
}

function Update-HUMuSelText {
    $c = $script:Controls
    $n = 0; try { $n = @(Get-HUMusterTrash $script:Settings).Count } catch { }
    $c['btnMuTrash'].Content = "$([char]::ConvertFromUtf32(0x1F5D1)) Papierkorb ($n)"
    $s = Get-HUMusterSelectionUi
    $c['lblMuSel'].Text = $(if ($s) { "Fuer den Vergleich angehakt: $($s.Titles)$(if (-not $s.Complete) { ' (Teilpakete: geprueft wird nur, was in den Paketen ist)' })" }
        elseif (@($script:MuPkgs).Count) { 'Haken setzen = Paket im Tenant-Vergleich als Spalte Muster verwenden.' }
        else { 'Noch keine Pakete. Mit + Neues Paket aus den Backup-Staenden zusammenstellen - oder in Analyse > Backup & Verlauf einen ganzen Stand als Muster festhalten.' })
}

# --------------------------- Paket (rechts) ---------------------------

function Get-HUMuCurPackage { return (@($script:MuPkgs | Where-Object { $_.Id -eq $script:MuCur }) | Select-Object -First 1) }

function Update-HUMuDetail {
    $c = $script:Controls
    $p = Get-HUMuCurPackage
    if (-not $p) {
        $c['lblMuTitle'].Text = 'Kein Paket gewaehlt'
        $c['lblMuMeta'].Text = 'Links ein Paket waehlen oder mit + Neues Paket eines anlegen.'
        $c['lblMuTags'].Text = ''; $c['lblMuNote'].Text = ''
        $c['pnlMuActions'].Visibility = 'Collapsed'
        $c['gridMuItems'].ItemsSource = @()
        Update-HUMuHint
        return
    }
    $c['pnlMuActions'].Visibility = 'Visible'
    $c['lblMuTitle'].Text = $p.Title
    $herk = @($p.Sources | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', '
    if ($p.BuiltIn) {
        $c['lblMuMeta'].Text = "$([char]::ConvertFromUtf32(0x1F512)) Mitgeliefert, schreibgeschuetzt  |  $($p.CopyCategory) (Teilpaket)  |  $($p.Count) Eintraege  |  Vorlage vom $(([datetime]::Parse($p.Changed, [Globalization.CultureInfo]::InvariantCulture)).ToString('dd.MM.yyyy'))  |  zum Anpassen: Duplizieren"
    } else {
        $c['lblMuMeta'].Text = "$($p.Category)$(if (-not $p.Complete) { ' (Teilpaket)' })  |  $($p.Count) Eintraege  |  Herkunft: $herk  |  geaendert $($p.ChangedText)$(if ($p.By) { " von $($p.By)" })"
    }
    foreach ($b in 'btnMuEdit', 'btnMuDel') {
        $c[$b].IsEnabled = -not $p.BuiltIn
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($c[$b], $true)
    }
    $c['btnMuEdit'].ToolTip = $(if ($p.BuiltIn) { 'Mitgelieferte Pakete sind schreibgeschuetzt - Duplizieren und die Kopie bearbeiten' } else { 'Name, Kategorie, Schlagwoerter, Notiz und Eintraege des Pakets aendern' })
    $c['btnMuDel'].ToolTip = $(if ($p.BuiltIn) { 'Mitgelieferte Pakete kommen mit dem Programm und lassen sich nicht loeschen' } else { 'Paket in den Papierkorb der Bibliothek verschieben' })
    $c['lblMuTags'].Text = $p.TagText
    $c['lblMuTags'].Visibility = $(if ($p.TagText) { 'Visible' } else { 'Collapsed' })
    $c['lblMuNote'].Text = "$($p.Note)$(if (@($p.Learn).Count) { "`nQuelle: $(@($p.Learn) -join '  ')" })"
    $c['lblMuNote'].Visibility = $(if ($c['lblMuNote'].Text) { 'Visible' } else { 'Collapsed' })
    $words = @("$($c['txtMuItemFilter'].Text)" -split '\s+' | Where-Object { $_ })
    $items = foreach ($it in @($p.Items)) {
        $o = [pscustomobject]@{ Typ = "$($it.Typ)"; Name = "$($it.Name)"; Herkunft = (Get-HUAnaTenantName "$($it.Source)"); StandText = (Get-HUMuStandText "$($it.Stand)"); Hinweis = (Get-HUMuItemHint "$($it.Typ)" "$($it.Name)" "$($it.Source)"); Source = "$($it.Source)"; File = "$($it.File)" }
        $ok = $true
        foreach ($w in $words) { if (("$($o.Typ) $($o.Name) $($o.Herkunft)").IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false } }
        if ($ok) { $o }
    }
    $c['gridMuItems'].ItemsSource = @($items | Sort-Object Typ, Name)
    Update-HUMuHint
}

function Update-HUMuHint {
    $c = $script:Controls
    Update-HUMuRunDot
    if (Test-HUMuJobRunning) { $c['lblMuHint'].Text = 'Arbeite ...'; return }
    $c['lblMuHint'].Text = 'Doppelklick auf einen Eintrag zeigt seine Einstellungen. Muster anwenden (gefuehrt in einen anderen oder neuen Tenant, mit Rechten nur fuer die Dauer des Ablaufs) folgt mit der naechsten Version.'
}

# Einstellungen eines Eintrags (Doppelklick) - immer mit Werten; Kennungen im Quell-Tenant zu Namen
function Show-HUMuItemDetail {
    $c = $script:Controls
    $r = $c['gridMuItems'].SelectedItem
    $p = Get-HUMuCurPackage
    if (-not $r -or -not $p) { return }
    if (-not $r.File) { Show-HUMessage "$($r.Typ) '$($r.Name)': Im Stand ist nur der Name gesichert (z. B. Apps) - keine Einstellungen." -Icon Info; return }
    $script:MuDetailName = "$($r.Typ): $($r.Name)"
    Add-HURtbLine $c['rtbMu'] "Lade Einstellungen von '$($r.Name)' ..." '#90CAF9'
    [void](Start-HUJob -Name 'MuDetail' -Quiet -Output $c['rtbMu'] -Vars @{ F = (Join-Path $p.Folder $r.File); Src = (Get-HUMusterResolveKey $script:Settings $r.Source) } -Code {
            $o = Read-HUBackupJson $F
            if ($o.PSObject.Properties['assignments']) { $o.PSObject.Properties.Remove('assignments') }
            $m = ConvertTo-HUFlatMap $o
            if ($Src) { try { $m = Resolve-HUFlatMapIds -TenantKey $Src -Settings $Settings -Map $m } catch { } }
            [pscustomobject]@{ __MuRows = @(@($m.Keys | Sort-Object) | ForEach-Object { [pscustomobject]@{ Einstellung = "$_"; Wert = "$($m[$_])" } }) }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and $_.PSObject.Properties['__MuRows'] }) | Select-Object -First 1
            Update-HUMuHint
            if (-not $d -or -not @($d.__MuRows).Count) { Show-HUMessage "$($script:MuDetailName)`n`nKeine Einstellungen gelesen." -Icon Info; return }
            Show-HUQSTable -Title "Muster - $($script:MuDetailName)" -Objects @($d.__MuRows) -FilePrefix 'Muster-Eintrag'
        })
    Update-HUMuHint
}

# --------------------------- Speichern, Duplizieren, Loeschen ---------------------------

function Start-HUMuSave($Spec, [string]$Id = '') {
    $c = $script:Controls
    Add-HURtbLine $c['rtbMu'] "Speichere Paket '$($Spec.Title)' ($(@($Spec.Items).Count) Eintraege) - Gruppennamen werden im Quell-Tenant nachgeschlagen ..." '#90CAF9'
    [void](Start-HUJob -Name 'MuSave' -Output $c['rtbMu'] -Vars @{ S = $Spec; PkgId = $Id } -Code {
            try {
                $r = Save-HUMusterPackage -Settings $Settings -Id $PkgId -Title $S.Title -Category $S.Category -Tags @($S.Tags) -Note $S.Note -Items @($S.Items) -Complete:([bool]($S.Category -eq 'Gesamtstand')) -ResolveGroups
                [pscustomobject]@{ __MuSaved = $r.Package.Id; Skipped = @($r.Skipped) }
            } catch { [pscustomobject]@{ __MuErr = "$($_.Exception.Message)" } }
        } -OnDone {
            param($Result, $Errors)
            $d = @($Result | Where-Object { $_ -and ($_.PSObject.Properties['__MuSaved'] -or $_.PSObject.Properties['__MuErr']) }) | Select-Object -First 1
            if (-not $d) { Show-HUMessage 'Paket nicht gespeichert (siehe Protokoll).' -Icon Error; Update-HUMuHint; return }
            if ($d.PSObject.Properties['__MuErr']) { Show-HUMessage "Paket nicht gespeichert:`n`n$($d.__MuErr)" -Icon Error; Update-HUMuHint; return }
            Update-HUMuList $d.__MuSaved
            if (@($d.Skipped).Count) { Show-HUMessage "Gespeichert. Doppelte Eintraege (gleiche Art und Name) wurden nur einmal uebernommen:`n`n$(@($d.Skipped | Select-Object -First 15) -join "`n")" -Icon Info }
        })
    Update-HUMuHint
}

function Start-HUMuNew {
    $spec = Show-HUMusterEditor $null
    if ($spec) { Start-HUMuSave $spec }
}

function Start-HUMuEdit {
    $p = Get-HUMuCurPackage
    if (-not $p) { return }
    if ($p.BuiltIn) { Show-HUMessage "'$($p.Title)' ist mitgeliefert und schreibgeschuetzt.`n`nMit Duplizieren entsteht eine eigene Kopie, die du bearbeiten kannst." -Icon Info; return }
    $spec = Show-HUMusterEditor $p
    if ($spec) { Start-HUMuSave $spec $p.Id }
}

function Start-HUMuDup {
    $p = Get-HUMuCurPackage
    if (-not $p) { return }
    $t = "$($p.Title) (Kopie)"; $i = 2
    while (@($script:MuPkgs | Where-Object { (ConvertTo-HUMuName $_.Title) -eq (ConvertTo-HUMuName $t) }).Count) { $t = "$($p.Title) (Kopie $i)"; $i++ }
    Start-HUMuSave ([pscustomobject]@{ Title = $t; Category = $(if ($p.BuiltIn) { $p.CopyCategory } else { $p.Category }); Tags = @($p.Tags); Note = $p.Note; Items = @(Get-HUMusterPackageItems $p) })
}

function Start-HUMuDelete {
    $p = Get-HUMuCurPackage
    if (-not $p) { return }
    if ($p.BuiltIn) { Show-HUMessage "'$($p.Title)' kommt mit dem Programm und laesst sich nicht loeschen. Nicht benoetigte Pakete einfach nicht anhaken." -Icon Info; return }
    if (-not (Confirm-HU "Paket '$($p.Title)' loeschen?`n`nEs wird in den Papierkorb der Bibliothek verschoben (Backups\_Muster\papierkorb) und laesst sich von dort zurueckholen. In Tenants wird nichts geaendert." -Warning)) { return }
    try {
        Remove-HUMusterPackage $script:Settings $p.Id
        Set-HUMuSelIds @(Get-HUMuSelIds | Where-Object { $_ -ne $p.Id })
        $script:MuCur = ''
        Add-HURtbLine $script:Controls['rtbMu'] "Paket '$($p.Title)' in den Papierkorb verschoben." '#81C784'
        Update-HUMuList
    } catch { Show-HUMessage "Nicht geloescht: $($_.Exception.Message)" -Icon Error }
}

# Zur Analyse wechseln und den Vergleich mit den angehakten Paketen starten
function Start-HUMuCompare {
    $c = $script:Controls
    if (-not @(Get-HUMuSelIds).Count) {
        if (-not $script:MuCur) { Show-HUMessage 'Bitte links mindestens ein Paket anhaken.' -Icon Info; return }
        Set-HUMuSelIds @($script:MuCur)
        Update-HUMuList
    }
    $c['chkCmpMuster'].IsChecked = $true
    try { $c['tabMain'].SelectedItem = $c['tabAnalyse'] } catch { }
    Set-HUAnaMode 'cmp'
    Start-HUCmpRun
}

# --------------------------- Paket-Editor (Fenster) ---------------------------

# Rueckgabe: @{ Title; Category; Tags; Note; Items } oder $null (abgebrochen)
function Show-HUMusterEditor($Package) {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1200" Height="700" MinWidth="860" MinHeight="480" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="Name des Pakets" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
                <TextBox x:Name="txtTitle" Style="{StaticResource DarkTextBox}" FontSize="12" MaxLength="120" ToolTip="Kurzer, eindeutiger Name, z. B. 'CA Grundschutz' oder 'Compliance Windows'"/>
            </StackPanel>
            <StackPanel Grid.Column="2">
                <TextBlock Text="Kategorie" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
                <ComboBox x:Name="cmbCat" Style="{StaticResource DarkComboBox}" Width="230"
                          ToolTip="Gesamtstand = ein ganzer Stand: im Vergleich zaehlt auch, was im Paket fehlt. Alle anderen Kategorien sind Teilpakete: geprueft wird nur, was im Paket ist."/>
            </StackPanel>
            <StackPanel Grid.Column="4">
                <TextBlock Text="Schlagwoerter" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
                <TextBox x:Name="txtTags" Style="{StaticResource DarkTextBox}" FontSize="12" MaxLength="200" ToolTip="Frei, mit Komma oder Leerzeichen getrennt, z. B. Pflicht, empfohlen, P1"/>
            </StackPanel>
        </Grid>
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <TextBlock Text="Notiz" Style="{StaticResource FieldLabel}" Margin="0,0,0,3"/>
            <TextBox x:Name="txtNote" Style="{StaticResource DarkTextBox}" FontSize="12" MaxLength="500" ToolTip="Wofuer das Paket gedacht ist, Besonderheiten (erscheint in der Bibliothek)"/>
            <TextBlock x:Name="lblCatHint" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="btnOk" Content="Speichern" Width="120" Background="#4CAF50" Style="{StaticResource DarkButton}" Margin="0,0,8,0" ToolTip="Paket in der Bibliothek speichern - es wird nichts in Tenants geschrieben"/>
                <Button x:Name="btnCancel" Content="Abbrechen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
            </StackPanel>
            <TextBlock x:Name="lblState" Foreground="#858585" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition x:Name="colSrc" Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition x:Name="colPkg" Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#252526" CornerRadius="4" Padding="10">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Aus einem Backup-Stand" Style="{StaticResource SectionTitle}" Margin="0,0,0,6"/>
                    <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                        <ComboBox x:Name="cmbTenant" Style="{StaticResource DarkComboBox}" Width="160" Margin="0,0,6,4" ToolTip="Tenant, aus dessen Backup die Eintraege kommen"/>
                        <ComboBox x:Name="cmbStand" Style="{StaticResource DarkComboBox}" Width="150" Margin="0,0,6,4" ToolTip="Vollstaendiger Backup-Stand (neuester oben)"/>
                        <ComboBox x:Name="cmbTyp" Style="{StaticResource DarkComboBox}" Width="190" Margin="0,0,6,4" ToolTip="Nur eine Art anzeigen"/>
                        <Grid Margin="0,0,0,4">
                            <TextBox x:Name="txtFilter" Style="{StaticResource DarkTextBox}" FontSize="12" Width="180" ToolTip="Text im Namen (mehrere Woerter: alle muessen vorkommen)"/>
                            <TextBlock x:Name="lblFilterHint" Text="Filtern ..." Foreground="#666666" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                        </Grid>
                    </WrapPanel>
                    <WrapPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <Button x:Name="btnAddAll" Content="Ganzen Stand uebernehmen" Style="{StaticResource ToolButton}" FontSize="11" Padding="8,2"
                                ToolTip="Alle Eintraege dieses Stands ins Paket - bei leerem Paket wird die Kategorie Gesamtstand vorgeschlagen"/>
                    </WrapPanel>
                    <DataGrid x:Name="gridSrc" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Extended"
                              ToolTip="Markieren (Strg/Umschalt fuer mehrere) und Hinzufuegen - oder Doppelklick">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="Auto"/>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="Auto"/>
                            <DataGridTextColumn Header="Hinweis" Binding="{Binding Hinweis}" Width="Auto"><DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#8A8A8A"/></Style></DataGridTextColumn.ElementStyle></DataGridTextColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="10,0">
                <Button x:Name="btnAdd" Content="Hinzufuegen &#x2192;" Background="#1976D2" Style="{StaticResource DarkButton}" FontSize="11" Margin="0,0,0,8" ToolTip="Markierte Eintraege ins Paket"/>
                <Button x:Name="btnRemove" Content="&#x2190; Entfernen" Style="{StaticResource ToolButton}" FontSize="11" Padding="8,3" ToolTip="Markierte Eintraege aus dem Paket nehmen"/>
            </StackPanel>
            <Border Grid.Column="2" Background="#252526" CornerRadius="4" Padding="10">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" x:Name="lblPkg" Text="Im Paket" Style="{StaticResource SectionTitle}" Margin="0,0,0,6"/>
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <TextBox x:Name="txtPkgFilter" Style="{StaticResource DarkTextBox}" FontSize="12" Width="220" HorizontalAlignment="Left" ToolTip="Eintraege im Paket filtern (Art, Name, Herkunft)"/>
                        <TextBlock x:Name="lblPkgFilterHint" Text="Filtern ..." Foreground="#666666" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                    </Grid>
                    <DataGrid x:Name="gridPkg" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Extended"
                              ToolTip="Markieren und Entfernen - oder Doppelklick">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Art" Binding="{Binding Typ}" Width="Auto"/>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="Auto"/>
                            <DataGridTextColumn Header="Herkunft" Binding="{Binding Herkunft}" Width="Auto"/>
                            <DataGridTextColumn Header="Stand" Binding="{Binding StandText}" Width="Auto"/>
                            <DataGridTextColumn Header="Hinweis" Binding="{Binding Hinweis}" Width="Auto"><DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="Foreground" Value="#8A8A8A"/></Style></DataGridTextColumn.ElementStyle></DataGridTextColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </Border>
        </Grid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = $(if ($Package) { "Muster-Paket bearbeiten - $($Package.Title)" } else { 'Neues Muster-Paket' })
    $st = @{ Result = $null; Items = (New-Object System.Collections.ArrayList); Src = @(); Busy = $false; OrigId = $(if ($Package) { $Package.Id } else { '' }) }
    $key = { param($i) "$($i.Typ)|$(ConvertTo-HUMuName "$($i.Name)")" }
    foreach ($cat in @(Get-HUMusterCategories)) { [void]$c.cmbCat.Items.Add($cat) }
    if ($Package) {
        $c.txtTitle.Text = $Package.Title; $c.cmbCat.SelectedItem = $Package.Category; $c.txtTags.Text = (@($Package.Tags) -join ', '); $c.txtNote.Text = $Package.Note
        foreach ($i in @(Get-HUMusterPackageItems $Package)) { [void]$st.Items.Add($i) }
    } else { $c.cmbCat.SelectedIndex = 0 }
    $catHint = {
        $c.lblCatHint.Text = $(if ("$($c.cmbCat.SelectedItem)" -eq 'Gesamtstand') { 'Gesamtstand: Im Tenant-Vergleich zaehlt auch als Abweichung, was im Paket fehlt - gedacht fuer einen ganzen Backup-Stand.' }
            else { 'Teilpaket: Im Tenant-Vergleich wird nur geprueft, was im Paket ist - alles andere bleibt neutral (Zelle "nicht im Paket").' })
    }
    & $catHint
    $c.cmbCat.Add_SelectionChanged($catHint)
    # Quell-Staende: nur vollstaendige
    $root = ''; try { $root = Get-HUBackupRoot $script:Settings } catch { }
    foreach ($t in @($script:Settings.tenants)) {
        $it = New-Object System.Windows.Controls.ComboBoxItem
        $it.Content = "$($t.displayName)"; $it.Tag = "$($t.key)"
        [void]$c.cmbTenant.Items.Add($it)
    }
    $refreshPkg = {
        $words = @("$($c.txtPkgFilter.Text)" -split '\s+' | Where-Object { $_ })
        $rows = foreach ($i in @($st.Items)) {
            $o = [pscustomobject]@{ Typ = $i.Typ; Name = $i.Name; Herkunft = (Get-HUAnaTenantName "$($i.Source)"); StandText = (Get-HUMuStandText "$($i.Stand)"); Hinweis = (Get-HUMuItemHint $i.Typ $i.Name "$($i.Source)"); Ref = $i }
            $ok = $true; foreach ($wd in $words) { if (("$($o.Typ) $($o.Name) $($o.Herkunft)").IndexOf($wd, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false } }
            if ($ok) { $o }
        }
        $c.gridPkg.ItemsSource = @($rows | Sort-Object Typ, Name)
        & $fitWidth
        $srcs = @($st.Items | ForEach-Object { "$($_.Source)" } | Where-Object { $_ } | Sort-Object -Unique)
        $c.lblPkg.Text = "Im Paket ($($st.Items.Count))"
        $c.lblState.Text = $(if ($st.Items.Count) { "$($st.Items.Count) Eintraege aus $(@($srcs | ForEach-Object { Get-HUAnaTenantName $_ }) -join ', '). Zuweisungen zaehlen im Vergleich nicht; beim Uebertragen werden sie nie mitgenommen." } else { 'Links Tenant und Stand waehlen, Eintraege markieren und hinzufuegen. Gemischt aus mehreren Tenants geht.' })
    }
    $refreshSrc = {
        $have = @{}; foreach ($i in @($st.Items)) { $have[(& $key $i)] = $true }
        $typ = "$($c.cmbTyp.SelectedItem)"
        $words = @("$($c.txtFilter.Text)" -split '\s+' | Where-Object { $_ })
        $rows = foreach ($i in @($st.Src)) {
            if ($have.ContainsKey((& $key $i))) { continue }
            if ($typ -and $typ -ne '(alle Arten)' -and $i.Typ -ne $typ) { continue }
            $ok = $true; foreach ($wd in $words) { if ("$($i.Name)".IndexOf($wd, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false } }
            if ($ok) { [pscustomobject]@{ Typ = $i.Typ; Name = $i.Name; Hinweis = (Get-HUMuItemHint $i.Typ $i.Name "$($i.Source)"); Ref = $i } }
        }
        $c.gridSrc.ItemsSource = @($rows | Sort-Object Typ, Name)
    }
    # Fenster so breit wie die Spalten beider Tabellen (globaler Standard), hoechstens 95 % des Bildschirms - nach dem Layout messen
    $fitWidth = {
        # erst nachdem die Spalten ihre Breite nach Inhalt haben (ContextIdle) messen; die beiden Seiten teilen sich den Platz nach Bedarf
        [void]$w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ContextIdle, [Action] {
                try {
                    $need = @(0.0, 0.0); $i = 0
                    foreach ($g in @($c.gridSrc, $c.gridPkg)) { foreach ($col in @($g.Columns)) { if ($col.Visibility -eq 'Visible') { $need[$i] += $col.ActualWidth } }; $need[$i] += 48; $i++ }
                    if ($need[0] -gt 100 -and $need[1] -gt 100) {
                        $c.colSrc.Width = New-Object System.Windows.GridLength($need[0], [System.Windows.GridUnitType]::Star)
                        $c.colPkg.Width = New-Object System.Windows.GridLength($need[1], [System.Windows.GridUnitType]::Star)
                    }
                    $total = ($need[0] + $need[1] + 150 + 60) * (Get-HUUiScaleValue)
                    $wa = [System.Windows.SystemParameters]::WorkArea
                    $max = [Math]::Floor($wa.Width * 0.95)
                    if ($total -gt $w.ActualWidth -and $w.WindowState -eq 'Normal') {
                        $w.Width = [Math]::Min($max, $total)
                        $w.Left = $wa.Left + [Math]::Max(0, ($wa.Width - $w.Width) / 2)
                    }
                } catch { }
            })
    }
    $loadStand = {
        $st.Src = @()
        $s = $c.cmbStand.SelectedItem
        $tk = "$($c.cmbTenant.SelectedItem.Tag)"
        if ($s -and $tk) { try { $st.Src = @(Get-HUMusterStandItems "$($s.Tag)" $tk) } catch { Show-HUMessage "Stand nicht lesbar: $($_.Exception.Message)" -Icon Error -Owner $w } }
        $st.Busy = $true
        $c.cmbTyp.Items.Clear(); [void]$c.cmbTyp.Items.Add('(alle Arten)')
        foreach ($t in @($st.Src | ForEach-Object { $_.Typ } | Sort-Object -Unique)) { [void]$c.cmbTyp.Items.Add($t) }
        $c.cmbTyp.SelectedIndex = 0
        $st.Busy = $false
        & $refreshSrc
        & $fitWidth
    }
    $c.cmbTenant.Add_SelectionChanged({
            $c.cmbStand.Items.Clear()
            $tk = "$($c.cmbTenant.SelectedItem.Tag)"
            if ($tk -and $root) {
                foreach ($b in @(Get-HUBackupList -Root $root -TenantKey $tk | Where-Object Complete)) {
                    $it = New-Object System.Windows.Controls.ComboBoxItem
                    $it.Content = $b.Label; $it.Tag = $b.Folder
                    [void]$c.cmbStand.Items.Add($it)
                }
            }
            if ($c.cmbStand.Items.Count) { $c.cmbStand.SelectedIndex = 0 } else { & $loadStand; $c.lblState.Text = "Fuer diesen Tenant gibt es noch keinen vollstaendigen Backup-Stand (Analyse > Backup & Verlauf > Backup jetzt)." }
        })
    $c.cmbStand.Add_SelectionChanged({ & $loadStand })
    $c.cmbTyp.Add_SelectionChanged({ if (-not $st.Busy) { & $refreshSrc } })
    $c.txtFilter.Add_TextChanged({ $c.lblFilterHint.Visibility = $(if ($c.txtFilter.Text) { 'Collapsed' } else { 'Visible' }); & $refreshSrc })
    $c.txtPkgFilter.Add_TextChanged({ $c.lblPkgFilterHint.Visibility = $(if ($c.txtPkgFilter.Text) { 'Collapsed' } else { 'Visible' }); & $refreshPkg })
    $add = {
        $sel = @($c.gridSrc.SelectedItems | ForEach-Object { $_.Ref })
        if (-not $sel.Count) { return }
        foreach ($i in $sel) { [void]$st.Items.Add($i) }
        & $refreshPkg; & $refreshSrc
    }
    $remove = {
        $sel = @($c.gridPkg.SelectedItems | ForEach-Object { $_.Ref })
        if (-not $sel.Count) { return }
        foreach ($i in $sel) { $st.Items.Remove($i) }
        & $refreshPkg; & $refreshSrc
    }
    $c.btnAdd.Add_Click($add)
    $c.gridSrc.Add_MouseDoubleClick($add)
    $c.btnRemove.Add_Click($remove)
    $c.gridPkg.Add_MouseDoubleClick($remove)
    $c.btnAddAll.Add_Click({
            if (-not @($st.Src).Count) { return }
            $wasEmpty = -not $st.Items.Count
            $have = @{}; foreach ($i in @($st.Items)) { $have[(& $key $i)] = $true }
            foreach ($i in @($st.Src)) { if (-not $have.ContainsKey((& $key $i))) { [void]$st.Items.Add($i) } }
            if ($wasEmpty) {
                $c.cmbCat.SelectedItem = 'Gesamtstand'
                if (-not $c.txtTitle.Text.Trim()) { $c.txtTitle.Text = "Gesamtstand $($c.cmbTenant.SelectedItem.Content) $(Get-HUMuStandText (Split-Path "$($c.cmbStand.SelectedItem.Tag)" -Leaf))" -replace ' \d{2}:\d{2}$', '' }
            }
            & $refreshPkg; & $refreshSrc
        })
    $c.btnOk.Add_Click({
            $t = $c.txtTitle.Text.Trim()
            if (-not $t) { Show-HUMessage 'Bitte einen Namen fuer das Paket eingeben.' -Icon Warning -Owner $w; return }
            if (-not $st.Items.Count) { Show-HUMessage 'Das Paket hat noch keine Eintraege.' -Icon Warning -Owner $w; return }
            $dup = @($script:MuPkgs | Where-Object { $_.Id -ne $st.OrigId -and (ConvertTo-HUMuName $_.Title) -eq (ConvertTo-HUMuName $t) })
            if ($dup.Count) { Show-HUMessage "Es gibt schon ein Paket '$($dup[0].Title)' - bitte einen anderen Namen waehlen." -Icon Warning -Owner $w; return }
            $st.Result = [pscustomobject]@{ Title = $t; Category = "$($c.cmbCat.SelectedItem)"; Tags = @(ConvertTo-HUMusterTags $c.txtTags.Text); Note = ($c.txtNote.Text -replace '\s+', ' ').Trim(); Items = @($st.Items) }
            $w.Close()
        })
    $c.btnCancel.Add_Click({ $w.Close() })
    $w.Add_ContentRendered({
            & $refreshPkg
            # Start: Tenant des letzten Eintrags, sonst der erste
            $pref = "$(if ($st.Items.Count) { $st.Items[$st.Items.Count - 1].Source })"
            $hit = @($c.cmbTenant.Items | Where-Object { "$($_.Tag)" -eq $pref }) | Select-Object -First 1
            if ($hit) { $c.cmbTenant.SelectedItem = $hit } elseif ($c.cmbTenant.Items.Count) { $c.cmbTenant.SelectedIndex = 0 }
            $c.txtTitle.Focus() | Out-Null
        })
    [void]$w.ShowDialog()
    return $st.Result
}

# --------------------------- Papierkorb ---------------------------

function Show-HUMusterTrash {
    $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="440" MinWidth="560" MinHeight="300" WindowStartupLocation="CenterOwner" Background="#1E1E1E" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <!--HU:THEME-->
    </Window.Resources>
    <DockPanel Margin="14">
        <TextBlock DockPanel.Dock="Top" Style="{StaticResource HintText}" TextWrapping="Wrap" Margin="0,0,0,8"
                   Text="Geloeschte Muster-Pakete. Zurueckholen stellt das Paket wieder in die Bibliothek (gibt es den Namen schon: Zusatz 'wiederhergestellt'). Endgueltig loeschen entfernt es von der Platte. In Tenants wird nichts geaendert."/>
        <DockPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="btnRestore" Content="&#x21BA; Zurueckholen" Width="130" Background="#388E3C" Style="{StaticResource DarkButton}" Margin="0,0,8,0" ToolTip="Markierte Pakete zurueck in die Bibliothek"/>
                <Button x:Name="btnDelete" Content="Endgueltig loeschen ..." Width="160" Background="#B71C1C" Style="{StaticResource DarkButton}" Margin="0,0,8,0" ToolTip="Markierte Pakete endgueltig von der Platte loeschen (mit Rueckfrage)"/>
                <Button x:Name="btnClose" Content="Schliessen" Width="100" Background="#555555" Style="{StaticResource DarkButton}" IsCancel="True"/>
            </StackPanel>
            <CheckBox x:Name="chkAuto" Content="Nach 90 Tagen automatisch endgueltig loeschen" Style="{StaticResource DarkCheckBox}" VerticalAlignment="Center"
                      ToolTip="Beim Programmstart werden Pakete, die laenger als 90 Tage im Papierkorb liegen, endgueltig geloescht"/>
        </DockPanel>
        <DataGrid x:Name="grid" Style="{StaticResource DarkDataGrid}" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column" SelectionMode="Extended">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Paket" Binding="{Binding Title}" Width="Auto"/>
                <DataGridTextColumn Header="Kategorie" Binding="{Binding Category}" Width="Auto"/>
                <DataGridTextColumn Header="Eintraege" Binding="{Binding Count}" Width="Auto"/>
                <DataGridTextColumn Header="Geloescht am" Binding="{Binding DeletedText}" Width="Auto"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $theme = Get-HUXaml 'Theme'
    $m = [regex]::Match($theme, '(?s)<ResourceDictionary[^>]*>(.*)</ResourceDictionary>')
    $d = New-HUWindow -XamlText ($x.Replace('<!--HU:THEME-->', $m.Groups[1].Value))
    $w = $d.Window; $c = $d.C
    $w.Title = 'Papierkorb der Muster-Bibliothek'
    $st = @{ Changed = $false }
    $load = { try { $c.grid.ItemsSource = @(Get-HUMusterTrash $script:Settings) } catch { $c.grid.ItemsSource = @() } }
    & $load
    $c.chkAuto.IsChecked = [bool](Get-HUStateValue 'muTrashAuto' $true)
    $c.chkAuto.Add_Checked({ Set-HUStateValue 'muTrashAuto' $true; try { Save-HUUIState } catch { } })
    $c.chkAuto.Add_Unchecked({ Set-HUStateValue 'muTrashAuto' $false; try { Save-HUUIState } catch { } })
    $c.btnRestore.Add_Click({
            $sel = @($c.grid.SelectedItems)
            if (-not $sel.Count) { Show-HUMessage 'Bitte Pakete markieren.' -Icon Info -Owner $w; return }
            $err = @()
            foreach ($t in $sel) { try { [void](Restore-HUMusterPackage $script:Settings $t.Folder); $st.Changed = $true } catch { $err += "$($t.Title): $($_.Exception.Message)" } }
            & $load
            if ($err.Count) { Show-HUMessage "Nicht zurueckgeholt:`n`n$($err -join "`n")" -Icon Warning -Owner $w }
        })
    $c.btnDelete.Add_Click({
            $sel = @($c.grid.SelectedItems)
            if (-not $sel.Count) { Show-HUMessage 'Bitte Pakete markieren.' -Icon Info -Owner $w; return }
            if (-not (Confirm-HU "$($sel.Count) Paket(e) endgueltig loeschen?`n`n$(@($sel | Select-Object -First 10 | ForEach-Object { "  $($_.Title)" }) -join "`n")`n`nDas laesst sich nicht rueckgaengig machen." -Warning -Owner $w)) { return }
            foreach ($t in $sel) { try { Remove-HUMusterTrashItem $script:Settings $t.Folder; $st.Changed = $true } catch { } }
            & $load
        })
    $c.btnClose.Add_Click({ $w.Close() })
    $c.grid.Add_MouseDoubleClick({ $c.btnRestore.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) })
    [void]$w.ShowDialog()
    Update-HUMuList
}

# --------------------------- Handler ---------------------------

function Register-HUMusterHandlers {
    $c = $script:Controls
    $c['btnMuNew'].Add_Click({ Start-HUMuNew })
    $c['btnMuEdit'].Add_Click({ Start-HUMuEdit })
    $c['btnMuDup'].Add_Click({ Start-HUMuDup })
    $c['btnMuDel'].Add_Click({ Start-HUMuDelete })
    $c['btnMuCompare'].Add_Click({ Start-HUMuCompare })
    $c['btnMuTrash'].Add_Click({ Show-HUMusterTrash })
    $c['gridMuItems'].Add_MouseDoubleClick({ Show-HUMuItemDetail })
    $c['txtMuFilter'].Add_TextChanged({ $script:Controls['lblMuFilterHint'].Visibility = $(if ($script:Controls['txtMuFilter'].Text) { 'Collapsed' } else { 'Visible' }); Update-HUMuList })
    $c['txtMuItemFilter'].Add_TextChanged({ $script:Controls['lblMuItemFilterHint'].Visibility = $(if ($script:Controls['txtMuItemFilter'].Text) { 'Collapsed' } else { 'Visible' }); Update-HUMuDetail })
    $c['lstMuPkg'].Add_SelectionChanged({
            if ($script:MuListBusy) { return }
            $it = $script:Controls['lstMuPkg'].SelectedItem
            $script:MuCur = $(if ($it) { "$($it.Id)" } else { '' })
            Update-HUMuDetail
        })
    # Haken in der Liste: Paket fuer den Vergleich an/aus (Klick auf die CheckBox in der Zeilenvorlage)
    $c['lstMuPkg'].AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
            param($s, $e)
            $cb = $e.OriginalSource
            if ($cb -isnot [System.Windows.Controls.CheckBox] -or -not "$($cb.Tag)") { return }
            $id = "$($cb.Tag)"
            $ids = @(Get-HUMuSelIds)
            if ([bool]$cb.IsChecked) { $ids = @($ids + $id) } else { $ids = @($ids | Where-Object { $_ -ne $id }) }
            Set-HUMuSelIds $ids
            Update-HUMuSelText
        })
    Set-HUListMenu $c['lstMuPkg'] @(
        @{ Header = 'Bearbeiten ...'; Action = { Start-HUMuEdit } }
        @{ Header = 'Duplizieren'; Action = { Start-HUMuDup } }
        @{ Header = 'Loeschen ...'; Action = { Start-HUMuDelete } }
    )
    Add-HUOutputMenu $c['rtbMu'] { $script:Controls['rtbMu'].Document.Blocks.Clear() }
    try { $h = [double](Get-HUStateValue 'muLogHeight' 110); if ($h -ge 50 -and $h -le 600) { $c['rtbMu'].Height = $h } } catch { }
    $c['thbMuLog'].Add_DragDelta({
            param($s, $e)
            $h = $script:Controls['rtbMu'].Height - $e.VerticalChange
            $script:Controls['rtbMu'].Height = [math]::Max(50, [math]::Min(600, $h))
        })
    $c['thbMuLog'].Add_DragCompleted({ Set-HUStateValue 'muLogHeight' ([int]$script:Controls['rtbMu'].Height) })
    # beim ersten Oeffnen des Reiters laden (die Bibliothek uebernimmt dabei einmalig das bisherige Muster)
    $c['tabMain'].Add_SelectionChanged({
            param($s, $e)
            if ($e.OriginalSource -ne $script:Controls['tabMain']) { return }
            if ($script:Controls['tabMain'].SelectedItem -eq $script:Controls['tabMuster']) { Update-HUMuList }
        })
    # bisheriges Muster einmalig uebernehmen - war im Vergleich der Haken "Muster" gesetzt, ist das neue Paket gleich angehakt
    try {
        $made = Initialize-HUMusterLibrary $script:Settings
        if ($made -and -not @(Get-HUMuSelIds).Count) { Set-HUMuSelIds @($made.Id) }
    } catch { Write-HULogWarn "Muster-Bibliothek: bisheriges Muster nicht uebernommen ($($_.Exception.Message))" }
    # Papierkorb: Pakete, die laenger als 90 Tage drin liegen, endgueltig loeschen (Haken im Papierkorb-Fenster, Standard an)
    if ([bool](Get-HUStateValue 'muTrashAuto' $true)) { try { [void](Clear-HUMusterTrash $script:Settings 90) } catch { } }
    # Reiter ist schon offen (z. B. beim Start wiederhergestellt): gleich laden
    if ($c['tabMain'].SelectedItem -eq $c['tabMuster']) { Update-HUMuList }
}
