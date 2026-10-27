#Requires -Version 5.1
# 2.5.6 Ausgabefenster global: neuestes Ereignis oben (Standard), Knopf "Umkehren" = klassisch unten
# Logik von Add-HUOutputBlock / Switch-HUOutputOrder mit nachgebauter Block-Liste (ohne WPF)

BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Root = $root
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Functions\UI-Common.ps1'), [ref]$null, [ref]$null)
    foreach ($n in 'Add-HUOutputBlock', 'Switch-HUOutputOrder', 'Get-HUOutputStateKey') {
        $fn = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }.GetNewClosure(), $true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Set-HUStateValue($Name, $Value) { $script:State[$Name] = $Value }
    if (-not ('HUFakeBlocks' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Collections;
public class HUFakeBlocks : IEnumerable {
    public ArrayList L = new ArrayList();
    public int Count { get { return L.Count; } }
    public object FirstBlock { get { return L.Count > 0 ? L[0] : null; } }
    public object LastBlock { get { return L.Count > 0 ? L[L.Count - 1] : null; } }
    public void Add(object b) { L.Add(b); }
    public void InsertBefore(object r, object b) { L.Insert(L.IndexOf(r), b); }
    public bool Remove(object b) { int i = L.IndexOf(b); if (i < 0) return false; L.RemoveAt(i); return true; }
    public void Clear() { L.Clear(); }
    public IEnumerator GetEnumerator() { return L.GetEnumerator(); }
}
'@
    }
    $script:NewRtb = {
        param($tag)
        $b = [HUFakeBlocks]::new()
        $doc = [pscustomobject]@{ Blocks = $b; Tag = $tag }
        $r = [pscustomobject]@{ Name = 'rtbTest'; Document = $doc; Scrolled = '' }
        $r | Add-Member ScriptMethod ScrollToEnd { $this.Scrolled = 'end' }
        $r | Add-Member ScriptMethod ScrollToHome { $this.Scrolled = 'home' }
        $r
    }
    function Lines($r) { @($r.Document.Blocks) -join ',' }
}

Describe 'Ausgabe: neuestes oben' {
    BeforeEach { $script:State = @{} }
    It 'Standard (top): neue Zeile oben, Begrenzung wirft die aelteste (unten) raus' {
        $r = & $script:NewRtb 'top'
        foreach ($x in 'a', 'b', 'c', 'd') { Add-HUOutputBlock $r $x 3 }
        Lines $r | Should -Be 'd,c,b'
        $r.Scrolled | Should -Be 'home'
    }
    It 'ohne Merker (nicht eingehaengt) ebenfalls oben' {
        $r = & $script:NewRtb $null
        Add-HUOutputBlock $r 'a'; Add-HUOutputBlock $r 'b'
        Lines $r | Should -Be 'b,a'
    }
    It 'bottom: klassisch unten, aelteste oben raus' {
        $r = & $script:NewRtb 'bottom'
        foreach ($x in 'a', 'b', 'c', 'd') { Add-HUOutputBlock $r $x 3 }
        Lines $r | Should -Be 'b,c,d'
        $r.Scrolled | Should -Be 'end'
    }
    It 'Umkehren dreht den Inhalt, wechselt den Merker und merkt ihn je Ausgabe' {
        $r = & $script:NewRtb 'top'
        foreach ($x in 'a', 'b', 'c') { Add-HUOutputBlock $r $x }
        Switch-HUOutputOrder $r
        Lines $r | Should -Be 'a,b,c'
        $r.Document.Tag | Should -Be 'bottom'
        $script:State['outBottom_rtbTest'] | Should -Be 'ja'
        Add-HUOutputBlock $r 'd'; Lines $r | Should -Be 'a,b,c,d'
        Switch-HUOutputOrder $r
        Lines $r | Should -Be 'd,c,b,a'; $script:State['outBottom_rtbTest'] | Should -Be 'nein'
    }
}

Describe 'Ausgabe: alle Schreiber gehen ueber die gemeinsame Logik' {
    It 'kein Schreiber haengt mehr selbst unten an und scrollt ans Ende' {
        foreach ($f in 'Functions\UI-Jobs.ps1', 'Functions\UI-QuickScript.ps1', 'Functions\UI-Extensions.ps1') {
            $src = Get-Content -Raw -LiteralPath (Join-Path $script:Root $f)
            $src | Should -Not -Match 'ScrollToEnd' -Because $f
            $src | Should -Match 'Add-HUOutputBlock' -Because $f
        }
        $log = Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Core\HU.Logging.psm1')
        $log | Should -Match "Tag\)`" -eq 'bottom'"
        $log | Should -Match 'Blocks\.LastBlock'
    }
    It 'Knoepfe werden global eingehaengt: Hauptfenster, jedes Fenster, Modul-Reiter' {
        (Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Main.ps1')) | Should -Match 'Set-HUOutputTools \$script:Window'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Functions\UI-Common.ps1')) | Should -Match 'Set-HUOutputTools \$w'
        (Get-Content -Raw -LiteralPath (Join-Path $script:Root 'Functions\UI-Addons.ps1')) | Should -Match 'Set-HUOutputTools \$tab'
    }
}
