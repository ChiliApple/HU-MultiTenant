#Requires -Version 5.1
<#
.SYNOPSIS
    Quick-Script-Snippets: Speicher (Config\quick-snippets.json) und Verwaltungsfenster.
.DESCRIPTION
    Eintrag: name, description (Kurzbeschreibung), category (Kategorie), code, created, modified, favorite (Stern).
    Favoriten stehen in der Auswahl im Quick Script oben.
    Aeltere Dateien (ohne description/modified) werden weiter gelesen und beim naechsten Speichern ergaenzt.
    Vor jedem Speichern wird die bisherige Datei als quick-snippets.json.bak gesichert.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:SnippetsPath = Join-Path $script:AppRoot 'Config\quick-snippets.json'
$script:SnippetReadError = ''   # gesetzt, wenn die Datei nicht lesbar ist -> dann wird NICHT gespeichert (sonst Datenverlust)

function ConvertTo-HUSnippet($s) {
    if ($null -eq $s) { return $null }
    $get = { param($n) if ($s.PSObject.Properties[$n] -and $null -ne $s.$n) { "$($s.$n)" } else { '' } }
    $name = (& $get 'name').Trim()
    if (-not $name) { return $null }
    $created = & $get 'created'
    $mod = & $get 'modified'
    return [pscustomobject][ordered]@{
        name        = $name
        description = (& $get 'description')
        code        = (& $get 'code')
        created     = $created
        modified    = $(if ($mod) { $mod } else { $created })
        favorite    = ($s.PSObject.Properties['favorite'] -and $s.favorite -eq $true)
        category    = (& $get 'category').Trim()
    }
}

function Get-HUSnippets {
    $script:SnippetReadError = ''
    if (-not (Test-Path -LiteralPath $script:SnippetsPath)) { return @() }
    try {
        $json = Get-Content -LiteralPath $script:SnippetsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json) { return @() }
        $raw = if ($json.PSObject.Properties['snippets']) { @($json.snippets) } else { @($json) }
        return @($raw | ForEach-Object { ConvertTo-HUSnippet $_ } | Where-Object { $_ })
    } catch {
        $script:SnippetReadError = $_.Exception.Message
        Write-HULogWarn "Snippet-Datei nicht lesbar: $($_.Exception.Message)"
        return @()
    }
}

# Erststart: noch keine Snippet-Datei -> mitgelieferte Beispiele uebernehmen
function Initialize-HUSnippetFile {
    $ex = Join-Path $script:AppRoot 'Config\quick-snippets.example.json'
    if (-not (Test-Path -LiteralPath $script:SnippetsPath) -and (Test-Path -LiteralPath $ex)) {
        try { Copy-Item -LiteralPath $ex -Destination $script:SnippetsPath -ErrorAction Stop } catch { }
    }
}

# ein Snippet nach Namen (oder $null)
function Get-HUSnippet([string]$Name) {
    if (-not $Name) { return $null }
    return (Get-HUSnippets | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Save-HUSnippets([object[]]$Snippets) {
    if ($script:SnippetReadError) {
        Show-HUMessage "Config\quick-snippets.json ist nicht lesbar - es wird nichts gespeichert, damit keine Snippets verloren gehen.`n`n$($script:SnippetReadError)`n`nDatei pruefen (Editor) oder die Sicherung quick-snippets.json.bak zurueckkopieren." -Icon Error
        return $false
    }
    try {
        $list = @($Snippets | Where-Object { $_ })
        Write-HUJsonFile -Path $script:SnippetsPath -Object ([pscustomobject]@{ snippets = $list }) -Depth 5 -Backup
        return $true
    } catch {
        Show-HUMessage "Snippet-Datei konnte nicht gespeichert werden:`n$($_.Exception.Message)" -Icon Error
        return $false
    }
}

function Get-HUNow { return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

# Snippet anlegen oder ersetzen (gleicher Name). Rueckgabe $true/$false
function Set-HUSnippet {
    param([string]$Name, [string]$Code, [string]$Description = '', [string]$OldName = '')
    $setDesc = $PSBoundParameters.ContainsKey('Description') -and $null -ne $PSBoundParameters['Description']
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($s in (Get-HUSnippets)) { $all.Add($s) }
    $key = if ($OldName) { $OldName } else { $Name }
    $idx = -1
    for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].name -eq $key) { $idx = $i; break } }
    $now = Get-HUNow
    if ($idx -ge 0) {
        $e = $all[$idx]
        $e.name = $Name
        $e.code = $Code
        if ($setDesc) { $e.description = $Description }
        $e.modified = $now
        # anderer Eintrag mit dem neuen Namen (Umbenennen auf vorhandenen Namen) -> ersetzt
        for ($i = $all.Count - 1; $i -ge 0; $i--) { if ($i -ne $idx -and $all[$i].name -eq $Name) { $all.RemoveAt($i) } }
    } else {
        $all.Add([pscustomobject][ordered]@{ name = $Name; description = "$Description"; code = $Code; created = $now; modified = $now; favorite = $false; category = '' })
    }
    return (Save-HUSnippets $all.ToArray())
}

function Format-HUShortDate([string]$Value) {
    try { return ([datetime]$Value).ToString('dd.MM.yy') } catch { return '' }
}

# Kategorien (alphabetisch, ohne leere)
function Get-HUSnippetCategories([object[]]$Snippets) {
    @($Snippets | ForEach-Object { "$($_.category)".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

# Reihenfolge nach Kategorie (alphabetisch, ohne Kategorie zuletzt), innerhalb wie gespeichert
function Sort-HUSnippetsByCategory([object[]]$Snippets) {
    $out = @()
    foreach ($cat in @(Get-HUSnippetCategories $Snippets)) { $out += @($Snippets | Where-Object { "$($_.category)".Trim() -eq $cat }) }
    $out += @($Snippets | Where-Object { -not "$($_.category)".Trim() })
    return $out
}

# Eintraege fuer die Auswahl im Quick Script: Favoriten zuerst, dann nach Kategorie
function Get-HUSnippetComboItems([object[]]$Snippets) {
    $fav = @($Snippets | Where-Object { $_.favorite -eq $true })
    $rest = @(Sort-HUSnippetsByCategory @($Snippets | Where-Object { $_.favorite -ne $true }))
    foreach ($s in @($fav + $rest)) {
        $d = "$($s.description)"
        [pscustomobject]@{
            Name = $s.name; Star = $(if ($s.favorite -eq $true) { [string][char]0x2605 } else { '' }); Fav = ($s.favorite -eq $true)
            CatShort = $(if ("$($s.category)") { "[$($s.category)]" } else { '' })
            DescShort = $(if ($d.Length -gt 70) { $d.Substring(0, 67) + '...' } else { $d }); Description = $d
        }
    }
}

# Snippets aus einer Datei hinzufuegen (Import, Beispiele). Gleiche Namen: Rueckfrage ersetzen / Kopie / abbrechen.
# Rueckgabe: neue Gesamtliste oder $null (abgebrochen / Fehler)
function Merge-HUSnippetFile([string]$Path, [object[]]$Existing, $Owner = $null) {
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $raw = if ($j.PSObject.Properties['snippets']) { @($j.snippets) } else { @($j) }
        $new = @($raw | ForEach-Object { ConvertTo-HUSnippet $_ } | Where-Object { $_ })
    } catch { Show-HUMessage "Datei nicht lesbar: $($_.Exception.Message)" -Icon Error -Owner $Owner; return $null }
    if (-not $new.Count) { Show-HUMessage 'Keine Snippets in der Datei gefunden.' -Icon Warning -Owner $Owner; return $null }
    $dup = @($new | Where-Object { $n = $_.name; @($Existing | Where-Object { $_.name -eq $n }).Count })
    $mode = 'add'
    if ($dup.Count) {
        $a = Confirm-HUYesNoCancel "$($dup.Count) Snippet(s) gibt es schon:`n$((@($dup | Select-Object -First 10 | ForEach-Object { $_.name })) -join "`n")`n`nJa = ersetzen, Nein = vorhandene behalten (nur neue hinzufuegen), Abbrechen = nichts importieren" -Owner $Owner
        if ($a -eq 'Cancel') { return $null }
        $mode = if ($a -eq 'Yes') { 'replace' } else { 'skip' }
    }
    $list = [System.Collections.Generic.List[object]]::new(); foreach ($x in $Existing) { $list.Add($x) }
    $added = 0
    foreach ($s in $new) {
        $ex = @($list | Where-Object { $_.name -eq $s.name })
        if ($ex.Count) { if ($mode -eq 'replace') { $list[$list.IndexOf($ex[0])] = $s; $added++ } }
        else { $list.Add($s); $added++ }
    }
    return [pscustomobject]@{ List = $list.ToArray(); Added = $added; Names = @($new | ForEach-Object { $_.name }) }
}

# Favorit setzen/umschalten (Hauptfenster). Rueckgabe: neuer Zustand oder $null
function Switch-HUSnippetFavorite([string]$Name) {
    $all = @(Get-HUSnippets)
    $s = $all | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $s) { return $null }
    $s.favorite = -not ($s.favorite -eq $true)
    if (-not (Save-HUSnippets $all)) { return $null }
    return $s.favorite
}

# Main-Fenster: Auswahlliste der Snippets fuellen
function Update-HUSnippetCombo([string]$Select = '') {
    $cmb = $script:Controls['cmbSnippets']
    $script:QS_SuppressSelect = $true
    try {
        $items = @(Get-HUSnippetComboItems (Get-HUSnippets))
        $cmb.ItemsSource = $items
        $cmb.SelectedItem = $null
        if ($Select) { foreach ($it in $items) { if ($it.Name -eq $Select) { $cmb.SelectedItem = $it; break } } }
    } finally { $script:QS_SuppressSelect = $false }
}

# ============================================================================
# Verwaltungsfenster
# ============================================================================
function Show-HUSnippetManager {
    $d = New-HUWindow 'SnippetManager'
    $w = $d.Window; $c = $d.C
    Restore-HUDialogState $w 'SnippetManager'
    $st = @{ All = @(Get-HUSnippets); Result = $null; Busy = $false; Busy2 = $false; Dirty = $false }

    $toItem = {
        param($s)
        $desc = "$($s.description)"
        [pscustomobject]@{
            Name = $s.name; DescLine = $(if ($desc) { $desc } else { '(keine Beschreibung)' })
            ModifiedShort = (Format-HUShortDate $s.modified); Src = $s
            Group = $(if ("$($s.category)") { "$($s.category)" } else { 'Ohne Kategorie' })
            Star = $(if ($s.favorite -eq $true) { [string][char]0x2605 } else { [string][char]0x2606 })
            StarColor = $(if ($s.favorite -eq $true) { '#FFC107' } else { '#555555' })
        }
    }
    $refresh = {
        param([string[]]$SelectNames = @())
        $f = "$($c.txtFilter.Text)".Trim()
        $c.txtFilterHint.Visibility = $(if ($f) { 'Collapsed' } else { 'Visible' })
        $onlyFav = ($c.chkOnlyFav.IsChecked -eq $true)
        $catSel = if ($c.cmbCatFilter.SelectedIndex -gt 0) { "$($c.cmbCatFilter.SelectedItem)" } else { '' }
        $list = @(Sort-HUSnippetsByCategory $st.All | Where-Object { -not $onlyFav -or $_.favorite -eq $true } | Where-Object { -not $catSel -or "$($_.category)" -eq $catSel } | Where-Object {
            -not $f -or $_.name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or "$($_.description)".IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or "$($_.code)".IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } | ForEach-Object { & $toItem $_ })
        $cv = [System.Windows.Data.ListCollectionView]::new([System.Collections.ArrayList]@($list))
        $cv.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new('Group'))
        $c.lstSnippets.ItemsSource = $cv
        # Kategorien fuer Filter und Bearbeiten
        $cats = @(Get-HUSnippetCategories $st.All)
        if ((@($c.cmbCategoryPick.Items) -join '|') -ne ($cats -join '|')) {
            $st.Busy2 = $true
            $c.cmbCategoryPick.Items.Clear(); foreach ($x in $cats) { [void]$c.cmbCategoryPick.Items.Add($x) }
            $fsel = "$($c.cmbCatFilter.SelectedItem)"
            $c.cmbCatFilter.Items.Clear(); [void]$c.cmbCatFilter.Items.Add('Alle Kategorien'); foreach ($x in $cats) { [void]$c.cmbCatFilter.Items.Add($x) }
            if ($cats -contains $fsel) { $c.cmbCatFilter.SelectedItem = $fsel } else { $c.cmbCatFilter.SelectedIndex = 0 }
            $st.Busy2 = $false
        }
        $nFav = @($st.All | Where-Object { $_.favorite -eq $true }).Count
        $c.txtCount.Text = $(if ($f -or $onlyFav) { "$($list.Count) von $($st.All.Count) Snippets" } else { "$($st.All.Count) Snippets" }) + $(if ($nFav) { ", $nFav Favoriten" } else { '' })
        if ($SelectNames.Count) {
            foreach ($it in $list) { if ($SelectNames -contains $it.Name) { [void]$c.lstSnippets.SelectedItems.Add($it) } }
            if ($c.lstSnippets.SelectedItem) { $c.lstSnippets.ScrollIntoView($c.lstSnippets.SelectedItem) }
        }
    }
    $persist = {
        if (Save-HUSnippets $st.All) { $st.Dirty = $true; return $true }
        $st.All = @(Get-HUSnippets); return $false
    }
    $current = { $it = $c.lstSnippets.SelectedItem; if ($it) { $it.Src } else { $null } }

    $c.lstSnippets.Add_SelectionChanged({
        $s = & $current
        $st.Busy = $true
        if ($s) {
            $c.txtName.Text = $s.name; $c.txtDesc.Text = $s.description; $c.txtCode.Text = $s.code; $c.txtCategory.Text = "$($s.category)"
            $lines = @("$($s.code)" -split "`n").Count
            $np = @(Get-HUQSParams $s.code).Count
            $last = Get-HUQSLastRunText $s.name
            $c.txtMeta.Text = "Erstellt $($s.created)  |  geaendert $($s.modified)  |  $lines Zeilen$(if ($np) { "  |  $np Parameter" })$(if ($last) { "`n$last" })"
        } else { $c.txtName.Text = ''; $c.txtDesc.Text = ''; $c.txtCode.Text = ''; $c.txtMeta.Text = ''; $c.txtCategory.Text = '' }
        $st.Busy = $false
        $c.btnApply.IsEnabled = $false
        $n = $c.lstSnippets.SelectedItems.Count
        $c.btnLoad.IsEnabled = ($n -eq 1)
        $c.btnDelete.IsEnabled = ($n -ge 1)
        $c.btnDuplicate.IsEnabled = ($n -eq 1)
        $c.btnFav.IsEnabled = ($n -ge 1)
        $c.txtName.IsEnabled = ($n -eq 1); $c.txtDesc.IsEnabled = ($n -eq 1)
        $c.txtCategory.IsEnabled = ($n -ge 1); $c.cmbCategoryPick.IsEnabled = ($n -ge 1)
        $c.btnHistory.IsEnabled = ($n -eq 1)
        if ($n -gt 1) {
            $cs = @($c.lstSnippets.SelectedItems | ForEach-Object { "$($_.Src.category)" } | Sort-Object -Unique)
            $st.Busy = $true; $c.txtCategory.Text = $(if ($cs.Count -eq 1) { $cs[0] } else { '' }); $st.Busy = $false
            $c.txtMeta.Text = "$n Snippets markiert - Kategorie wird fuer alle gesetzt"
        }
    })
    $markEdit = { if (-not $st.Busy -and (& $current)) { $c.btnApply.IsEnabled = $true } }
    $c.txtName.Add_TextChanged($markEdit)
    $c.txtCategory.Add_TextChanged({ if (-not $st.Busy -and $c.lstSnippets.SelectedItems.Count -ge 1) { $c.btnApply.IsEnabled = $true } })
    $c.cmbCategoryPick.Add_SelectionChanged({
        if ($st.Busy2 -or -not $c.cmbCategoryPick.SelectedItem) { return }
        $c.txtCategory.Text = "$($c.cmbCategoryPick.SelectedItem)"
        $st.Busy2 = $true; $c.cmbCategoryPick.SelectedIndex = -1; $st.Busy2 = $false
    })
    $c.cmbCatFilter.Add_SelectionChanged({ if (-not $st.Busy2) { & $refresh } })
    $c.btnHistory.Add_Click({ $s = & $current; if ($s) { Show-HUQSHistory $s.name } })
    $c.btnExamples.Add_Click({
        $ex = Join-Path $script:AppRoot 'Config\quick-snippets.example.json'
        if (-not (Test-Path -LiteralPath $ex)) { Show-HUMessage "Beispieldatei fehlt:`n$ex" -Icon Warning -Owner $w; return }
        $r = Merge-HUSnippetFile -Path $ex -Existing $st.All -Owner $w
        if (-not $r) { return }
        $st.All = $r.List
        if (& $persist) { & $refresh $r.Names; Show-HUMessage "$($r.Added) Beispiel-Snippet(s) hinzugefuegt (Kategorie 'Beispiele')." -Owner $w }
    })
    $c.txtDesc.Add_TextChanged($markEdit)
    $c.txtFilter.Add_TextChanged({ & $refresh })
    $c.chkOnlyFav.Add_Checked({ & $refresh })
    $c.chkOnlyFav.Add_Unchecked({ & $refresh })

    # Favorit: Klick auf den Stern in der Zeile oder Knopf (alle markierten)
    $toggleFav = {
        param([object[]]$Items)
        $items = @($Items | Where-Object { $_ })
        if (-not $items.Count) { return }
        $newVal = -not (@($items | Where-Object { $_.favorite -eq $true }).Count -eq $items.Count)
        foreach ($s in $items) { $s.favorite = $newVal }
        $keep = @($c.lstSnippets.SelectedItems | ForEach-Object { $_.Name })
        if (& $persist) { & $refresh $keep }
    }
    $c.lstSnippets.Add_PreviewMouseLeftButtonDown({
        param($s0, $e)
        $src = $e.OriginalSource
        if ($src -is [System.Windows.Controls.TextBlock] -and "$($src.Tag)" -eq 'star' -and $src.DataContext) {
            & $toggleFav @($src.DataContext.Src)
            $e.Handled = $true
        }
    })
    $c.btnFav.Add_Click({ & $toggleFav @($c.lstSnippets.SelectedItems | ForEach-Object { $_.Src }) })

    $c.btnApply.Add_Click({
        $cat = ($c.txtCategory.Text -replace '\s+', ' ').Trim()
        if ($c.lstSnippets.SelectedItems.Count -gt 1) {
            $sel = @($c.lstSnippets.SelectedItems | ForEach-Object { $_.Src })
            foreach ($x in $sel) { $x.category = $cat; $x.modified = Get-HUNow }
            if (& $persist) { & $refresh @($sel | ForEach-Object { $_.name }) }
            return
        }
        $s = & $current; if (-not $s) { return }
        $s.category = $cat
        $newName = $c.txtName.Text.Trim()
        if (-not $newName) { Show-HUMessage 'Der Name darf nicht leer sein.' -Icon Warning -Owner $w; return }
        if ($newName -ne $s.name -and @($st.All | Where-Object { $_.name -eq $newName }).Count) {
            if (-not (Confirm-HU "Es gibt bereits ein Snippet '$newName'. Ersetzen?" -Warning -Owner $w)) { return }
            $st.All = @($st.All | Where-Object { $_.name -ne $newName -or $_ -eq $s })
        }
        $old = $s.name
        $s.name = $newName
        $s.description = ($c.txtDesc.Text -replace '\s+', ' ').Trim()
        $s.modified = Get-HUNow
        if (& $persist) {
            if ($script:QS_Current -eq $old) { $script:QS_Current = $newName; $script:QS_CurrentCat = $cat }
            & $refresh @($newName)
        }
    })

    $c.btnDelete.Add_Click({
        $sel = @($c.lstSnippets.SelectedItems | ForEach-Object { $_.Src })
        if (-not $sel.Count) { return }
        $names = @($sel | ForEach-Object { $_.name })
        $txt = if ($names.Count -eq 1) { "Snippet '$($names[0])' loeschen?" } else { "$($names.Count) Snippets loeschen?`n`n" + (($names | Select-Object -First 15) -join "`n") }
        if (-not (Confirm-HU "$txt`n`n(Sicherung der vorherigen Fassung: Config\quick-snippets.json.bak)" -Warning -Owner $w)) { return }
        $st.All = @($st.All | Where-Object { $names -notcontains $_.name })
        if (& $persist) { & $refresh }
    })

    $c.btnDuplicate.Add_Click({
        $s = & $current; if (-not $s) { return }
        $n = "$($s.name) (Kopie)"; $i = 2
        while (@($st.All | Where-Object { $_.name -eq $n }).Count) { $n = "$($s.name) (Kopie $i)"; $i++ }
        $now = Get-HUNow
        $copy = [pscustomobject][ordered]@{ name = $n; description = $s.description; code = $s.code; created = $now; modified = $now; favorite = $false; category = $s.category }
        $list = [System.Collections.Generic.List[object]]::new(); foreach ($x in $st.All) { $list.Add($x); if ($x -eq $s) { $list.Add($copy) } }
        $st.All = $list.ToArray()
        if (& $persist) { & $refresh @($n) }
    })

    $move = {
        param([int]$Dir)
        $s = & $current; if (-not $s -or $c.lstSnippets.SelectedItems.Count -ne 1) { return }
        $list = [System.Collections.Generic.List[object]]::new(); foreach ($x in $st.All) { $list.Add($x) }
        $i = $list.IndexOf($s); $j = $i + $Dir
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
        $list.RemoveAt($i); $list.Insert($j, $s)
        $st.All = $list.ToArray()
        if (& $persist) { & $refresh @($s.name) }
    }
    $c.btnUp.Add_Click({ & $move -1 })
    $c.btnDown.Add_Click({ & $move 1 })
    $c.btnSortName.Add_Click({
        if (-not (Confirm-HU 'Alle Snippets nach Namen sortieren (A-Z)?' -Owner $w)) { return }
        $st.All = @($st.All | Sort-Object { $_.name })
        if (& $persist) { & $refresh }
    })
    $c.btnSortDate.Add_Click({
        if (-not (Confirm-HU 'Alle Snippets nach Aenderungsdatum sortieren (neueste zuerst)?' -Owner $w)) { return }
        $st.All = @($st.All | Sort-Object { try { [datetime]$_.modified } catch { [datetime]::MinValue } } -Descending)
        if (& $persist) { & $refresh }
    })

    $c.btnExport.Add_Click({
        $sel = @($c.lstSnippets.SelectedItems | ForEach-Object { $_.Src })
        if (-not $sel.Count) { $sel = @($st.All) }
        if (-not $sel.Count) { return }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'JSON (*.json)|*.json'
        $dlg.FileName = $(if ($sel.Count -eq 1) { ($sel[0].name -replace '[\\/:*?"<>|]', '_') + '.json' } else { "HU-MultiTenant-Snippets_$(Get-Date -Format 'yyyy-MM-dd').json" })
        if (-not $dlg.ShowDialog($w)) { return }
        try {
            Write-HUJsonFile -Path $dlg.FileName -Object ([pscustomobject]@{ snippets = @($sel) }) -Depth 5
            Show-HUMessage "$($sel.Count) Snippet(s) exportiert:`n$($dlg.FileName)" -Owner $w
        } catch { Show-HUMessage "Export fehlgeschlagen: $($_.Exception.Message)" -Icon Error -Owner $w }
    })

    $c.btnImport.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'JSON (*.json)|*.json|Alle Dateien (*.*)|*.*'
        if (-not $dlg.ShowDialog($w)) { return }
        $r = Merge-HUSnippetFile -Path $dlg.FileName -Existing $st.All -Owner $w
        if (-not $r) { return }
        $st.All = $r.List
        if (& $persist) { & $refresh $r.Names; Show-HUMessage "$($r.Added) Snippet(s) importiert." -Owner $w }
    })

    $load = {
        $s = & $current; if (-not $s -or $c.lstSnippets.SelectedItems.Count -ne 1) { return }
        if ($c.btnApply.IsEnabled) {
            $a = Confirm-HUYesNoCancel "Geaenderten Namen/Beschreibung von '$($s.name)' vorher uebernehmen?" -Owner $w
            if ($a -eq 'Cancel') { return }
            if ($a -eq 'Yes') { $c.btnApply.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)); $s = & $current; if (-not $s) { return } }
        }
        $st.Result = $s.name
        $w.Close()
    }
    $c.btnLoad.Add_Click($load)
    $c.lstSnippets.Add_MouseDoubleClick({ & $load })
    $c.btnClose.Add_Click({ $w.Close() })
    $w.Add_Closing({ Save-HUDialogState $w 'SnippetManager' })

    & $refresh $(if ($script:QS_Current) { @($script:QS_Current) } else { @() })
    if (-not $c.lstSnippets.SelectedItem) { $c.btnLoad.IsEnabled = $false; $c.btnDelete.IsEnabled = $false; $c.btnDuplicate.IsEnabled = $false; $c.btnApply.IsEnabled = $false; $c.btnFav.IsEnabled = $false }
    $w.Add_ContentRendered({ $c.txtFilter.Focus() })
    [void]$w.ShowDialog()

    # Rueckgabe: Name des zu ladenden Snippets; Liste im Hauptfenster aktualisieren
    Update-HUSnippetCombo -Select $script:QS_Current
    if ($script:QS_Current) { $s = Get-HUSnippet $script:QS_Current; $script:QS_CurrentDesc = $(if ($s) { "$($s.description)" } else { '' }); $script:QS_CurrentFav = [bool]($s -and $s.favorite -eq $true) }
    if ($st.Dirty -and $script:QS_Current -and -not @(Get-HUSnippets | Where-Object { $_.name -eq $script:QS_Current }).Count) {
        # geladenes Snippet wurde geloescht -> als neues (ungespeichertes) Snippet weiterfuehren
        $script:QS_Current = ''; $script:QS_SavedCode = $null
    }
    Update-HUQSSnippetInfo
    return $st.Result
}
