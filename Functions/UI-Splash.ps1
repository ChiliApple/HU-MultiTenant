#Requires -Version 5.1
<#
.SYNOPSIS
    Abschied vom Startbildschirm: Das Logo verwandelt sich in einen kleinen Saugroboter, der den Startbildschirm
    in drei Bahnen im Zickzack aufsaugt (dahinter wird der Startbildschirm durchsichtig).
.DESCRIPTION
    Laeuft nach dem Aufbau des Hauptfensters (Close-HUSplash -Animate in Main.ps1), rund 2 Sekunden, blockiert nichts.
    Klick auf den Startbildschirm = sofort fertig. Aus: Einstellungen > Allgemein > Startanimation (ui.splashAnimation),
    ausserdem wenn Windows-Animationen ausgeschaltet sind. Alles mit WPF-Formen gezeichnet, keine Bilddateien.
.NOTES
    Dot-Source aus Main.ps1. Zielmaschine: der PC, auf dem HU-MultiTenant laeuft.
#>

$script:SplashAnim = $null

# Startanimation erlaubt? (Einstellung, Windows-Animationen, nicht im Starttest)
function Test-HUSplashAnimOn {
    if ($script:SmokeTestFile) { return $false }
    try { if ($script:Settings -and $script:Settings.ui -and $script:Settings.ui.PSObject.Properties['splashAnimation'] -and -not [bool]$script:Settings.ui.splashAnimation) { return $false } } catch { }
    try { if (-not [System.Windows.SystemParameters]::ClientAreaAnimation) { return $false } } catch { }
    return $true
}

# Kreisbogen (Grad, 0 = vorne/rechts, im Uhrzeigersinn) als Geometrie - Zahlen immer mit Punkt (Kultur unabhaengig)
function New-HUSplashArc([double]$R, [double]$A1, [double]$A2) {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $p1x = $R * [Math]::Cos($A1 * [Math]::PI / 180); $p1y = $R * [Math]::Sin($A1 * [Math]::PI / 180)
    $p2x = $R * [Math]::Cos($A2 * [Math]::PI / 180); $p2y = $R * [Math]::Sin($A2 * [Math]::PI / 180)
    $large = $(if ([Math]::Abs($A2 - $A1) -gt 180) { 1 } else { 0 })
    return [System.Windows.Media.Geometry]::Parse([string]::Format($ci, 'M {0:0.##},{1:0.##} A {2:0.##},{2:0.##} 0 {5} 1 {3:0.##},{4:0.##}', $p1x, $p1y, $R, $p2x, $p2y, $large))
}
function Get-HUSplashBrush([string]$Hex) { return [System.Windows.Media.BrushConverter]::new().ConvertFrom($Hex) }

# Der Roboter: Mittelpunkt bei (0,0), vorne = +x. Rueckgabe: Teile, die pro Bild bewegt werden.
function New-HUSplashBot([double]$R) {
    $root = New-Object System.Windows.Controls.Canvas
    $root.IsHitTestVisible = $false
    $add = { param($el, [double]$x, [double]$y) [System.Windows.Controls.Canvas]::SetLeft($el, $x); [System.Windows.Controls.Canvas]::SetTop($el, $y); [void]$root.Children.Add($el) }

    # Schatten
    $sh = New-Object System.Windows.Shapes.Ellipse
    $sh.Width = 2 * $R; $sh.Height = 2 * $R; $sh.Fill = Get-HUSplashBrush '#000000'; $sh.Opacity = 0.45
    $bl = New-Object System.Windows.Media.Effects.BlurEffect; $bl.Radius = 7; $sh.Effect = $bl
    & $add $sh (-$R + 3) (-$R + 5)

    # Seitenbuersten (schauen vorne seitlich unter dem Gehaeuse hervor)
    $brushes = @()
    foreach ($side in -1, 1) {
        $bc = New-Object System.Windows.Controls.Canvas
        $rt = New-Object System.Windows.Media.RotateTransform
        $bc.RenderTransform = $rt
        foreach ($k in 0..2) {
            $ln = New-Object System.Windows.Shapes.Line
            $a = $k * 120 * [Math]::PI / 180
            $ln.X1 = 0; $ln.Y1 = 0; $ln.X2 = 0.42 * $R * [Math]::Cos($a); $ln.Y2 = 0.42 * $R * [Math]::Sin($a)
            $ln.Stroke = Get-HUSplashBrush '#B0B0B0'; $ln.StrokeThickness = 1.6; $ln.StrokeStartLineCap = 'Round'; $ln.StrokeEndLineCap = 'Round'
            [void]$bc.Children.Add($ln)
        }
        $hub = New-Object System.Windows.Shapes.Ellipse; $hub.Width = 5; $hub.Height = 5; $hub.Fill = Get-HUSplashBrush '#707070'
        [System.Windows.Controls.Canvas]::SetLeft($hub, -2.5); [System.Windows.Controls.Canvas]::SetTop($hub, -2.5); [void]$bc.Children.Add($hub)
        & $add $bc (0.58 * $R) ($side * 0.8 * $R)
        $brushes += , @($rt, $side)
    }

    # Gehaeuse
    $body = New-Object System.Windows.Shapes.Ellipse
    $body.Width = 2 * $R; $body.Height = 2 * $R
    $g = New-Object System.Windows.Media.RadialGradientBrush
    $g.GradientOrigin = New-Object System.Windows.Point 0.35, 0.3; $g.Center = New-Object System.Windows.Point 0.45, 0.4; $g.RadiusX = 0.7; $g.RadiusY = 0.7
    foreach ($st in @(@('#FF505050', 0.0), @('#FF2A2A2A', 0.65), @('#FF161616', 1.0))) { [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($st[0])), $st[1])) }
    $body.Fill = $g; $body.Stroke = Get-HUSplashBrush '#B9A88A'; $body.StrokeThickness = 2
    & $add $body (-$R) (-$R)

    # Stossfaenger vorne
    $bump = New-Object System.Windows.Shapes.Path
    $bump.Data = New-HUSplashArc ($R - 3.5) -62 62; $bump.Stroke = Get-HUSplashBrush '#8A8A8A'; $bump.StrokeThickness = 3; $bump.StrokeStartLineCap = 'Round'; $bump.StrokeEndLineCap = 'Round'
    & $add $bump 0 0

    # Deckel
    $top = New-Object System.Windows.Shapes.Ellipse
    $top.Width = 1.2 * $R; $top.Height = 1.2 * $R; $top.Fill = Get-HUSplashBrush '#FF1F1F1F'; $top.Stroke = Get-HUSplashBrush '#FF3E3E3E'; $top.StrokeThickness = 1.5
    & $add $top (-0.6 * $R - 0.08 * $R) (-0.6 * $R)

    # leuchtender Sensor vorne
    $led = New-Object System.Windows.Shapes.Path
    $led.Data = New-HUSplashArc ($R - 9) -34 34; $led.Stroke = Get-HUSplashBrush '#FF4FC3F7'; $led.StrokeThickness = 3.2; $led.StrokeStartLineCap = 'Round'; $led.StrokeEndLineCap = 'Round'
    $glow = New-Object System.Windows.Media.Effects.DropShadowEffect; $glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#FF4FC3F7'); $glow.BlurRadius = 12; $glow.ShadowDepth = 0; $glow.Opacity = 1
    $led.Effect = $glow
    & $add $led 0 0

    # Aufschrift (bleibt aufrecht, auch wenn der Roboter nach links faehrt)
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = 'HU'; $tx.FontSize = [Math]::Max(9, 0.42 * $R); $tx.FontWeight = 'Bold'; $tx.Foreground = Get-HUSplashBrush '#FFB9A88A'
    $tx.Width = 2 * $R; $tx.TextAlignment = 'Center'
    $trt = New-Object System.Windows.Media.RotateTransform; $tx.RenderTransform = $trt; $tx.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
    & $add $tx (-$R - 0.08 * $R) (-0.68 * $tx.FontSize)

    $sc = New-Object System.Windows.Media.ScaleTransform
    $ro = New-Object System.Windows.Media.RotateTransform
    $tr = New-Object System.Windows.Media.TranslateTransform
    $tg = New-Object System.Windows.Media.TransformGroup
    [void]$tg.Children.Add($sc); [void]$tg.Children.Add($ro); [void]$tg.Children.Add($tr)
    $root.RenderTransform = $tg
    return @{ Root = $root; Scale = $sc; Rot = $ro; Tr = $tr; Brushes = $brushes; Led = $led; Glow = $glow; TextRot = $trt }
}

# Animation starten. $false = nicht moeglich (dann schliesst der Aufrufer sofort).
function Start-HUSplashSweep {
    $w = $script:Splash
    if (-not $w -or $script:SplashAnim) { return $false }
    $bd = $w.FindName('bd'); $ov = $w.FindName('ov'); $img = $w.FindName('img')
    if (-not $bd -or -not $ov) { return $false }
    $W = [double]$bd.ActualWidth; $H = [double]$bd.ActualHeight
    if ($W -lt 100 -or $H -lt 100) { return $false }
    $lane = $H / 3
    $r = [Math]::Round([Math]::Min($lane * 0.34, 38))

    # Mitte des Logos (Start der Verwandlung)
    $p0 = New-Object System.Windows.Point ($W / 2), ($H * 0.3)
    try { if ($img -and $img.ActualWidth -gt 0) { $p0 = $img.TranslatePoint((New-Object System.Windows.Point ($img.ActualWidth / 2), ($img.ActualHeight / 2)), $bd) } } catch { }

    # Aufgesaugte Flaeche: Startbildschirm minus drei wachsende Bahnen
    $full = New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect 0, 0, $W, $H), 12, 12
    $lanes = @(0..2 | ForEach-Object { New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect 0, 0, 0, 0) })
    $grp = New-Object System.Windows.Media.GeometryGroup
    foreach ($l in $lanes) { [void]$grp.Children.Add($l) }
    $bd.Clip = New-Object System.Windows.Media.CombinedGeometry ([System.Windows.Media.GeometryCombineMode]::Exclude), $full, $grp

    # Staubkoerner, die vor dem Roboter eingesaugt werden
    $rnd = New-Object System.Random
    $dust = @()
    foreach ($li in 0..2) {
        foreach ($k in 1..9) {
            $e = New-Object System.Windows.Shapes.Ellipse
            $s = 2.5 + $rnd.NextDouble() * 3
            $e.Width = $s; $e.Height = $s
            $e.Fill = Get-HUSplashBrush $(if ($rnd.Next(3) -eq 0) { '#FF8A8A8A' } else { '#FFB9A88A' })
            $e.IsHitTestVisible = $false
            $x = $W * (0.12 + 0.8 * $rnd.NextDouble()); $y = $lane * ($li + 0.5) + ($rnd.NextDouble() - 0.5) * $lane * 0.55
            [System.Windows.Controls.Canvas]::SetLeft($e, $x - $s / 2); [System.Windows.Controls.Canvas]::SetTop($e, $y - $s / 2)
            [void]$ov.Children.Add($e)
            $dust += @{ E = $e; X = $x; Y = $y; S = $s; Lane = $li }
        }
    }
    $bot = New-HUSplashBot $r
    $bot.Scale.ScaleX = 0; $bot.Scale.ScaleY = 0
    $bot.Tr.X = $p0.X; $bot.Tr.Y = $p0.Y
    [void]$ov.Children.Add($bot.Root)

    # Logo schrumpft um seine Mitte
    $ist = $null
    if ($img) { $ist = New-Object System.Windows.Media.ScaleTransform; $img.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5; $img.RenderTransform = $ist }

    # Fahrplan (ms): Verwandlung, Fahrt zur ersten Bahn, drei Bahnen mit Wenden
    $y = @(0..2 | ForEach-Object { $lane * ($_ + 0.5) })
    $seg = @(
        @{ K = 'morph'; D = 430 }
        @{ K = 'move'; D = 280; X0 = $p0.X; Y0 = $p0.Y; X1 = $r * 0.9; Y1 = $y[0]; A0 = 0; A1 = 0 }
        @{ K = 'lane'; D = 470; L = 0; X0 = $r * 0.9; X1 = $W + 0.6 * $r; Dir = 1 }
        @{ K = 'turn'; D = 200; X0 = $W + 0.6 * $r; Y0 = $y[0]; X1 = $W - 0.9 * $r; Y1 = $y[1]; A0 = 0; A1 = 180; Done = 0 }
        @{ K = 'lane'; D = 470; L = 1; X0 = $W - 0.9 * $r; X1 = -0.6 * $r; Dir = -1 }
        @{ K = 'turn'; D = 200; X0 = -0.6 * $r; Y0 = $y[1]; X1 = 0.9 * $r; Y1 = $y[2]; A0 = 180; A1 = 360; Done = 1 }
        @{ K = 'lane'; D = 520; L = 2; X0 = 0.9 * $r; X1 = $W + 1.6 * $r; Dir = 1 }
    )
    $t = 0; foreach ($s in $seg) { $s.T = $t; $t += $s.D }
    $script:SplashAnim = @{ W = $W; H = $H; Lane = $lane; R = $r; Bd = $bd; Lanes = $lanes; Bot = $bot; Dust = $dust; Img = $img; ImgScale = $ist
        Seg = $seg; Total = $t; SW = [System.Diagnostics.Stopwatch]::StartNew(); Handler = $null; Last = 0 }
    $h = [System.EventHandler] { try { Update-HUSplashSweep } catch { Stop-HUSplashSweep } }
    $script:SplashAnim.Handler = $h
    [System.Windows.Media.CompositionTarget]::add_Rendering($h)
    # Klick = sofort fertig
    try { $w.Add_MouseLeftButtonDown({ Stop-HUSplashSweep }) } catch { }
    return $true
}

function Get-HUEaseInOut([double]$x) { if ($x -lt 0.5) { return 2 * $x * $x } else { return 1 - [Math]::Pow(-2 * $x + 2, 2) / 2 } }
function Get-HUEaseOutBack([double]$x) { $c1 = 1.70158; $c3 = $c1 + 1; return 1 + $c3 * [Math]::Pow($x - 1, 3) + $c1 * [Math]::Pow($x - 1, 2) }

# ein Bild der Animation
function Update-HUSplashSweep {
    $A = $script:SplashAnim
    if (-not $A) { return }
    $t = [double]$A.SW.ElapsedMilliseconds
    if ($t -ge $A.Total) { Stop-HUSplashSweep; return }
    $dt = ($t - $A.Last) / 1000.0; $A.Last = $t
    $s = @($A.Seg | Where-Object { $t -ge $_.T -and $t -lt ($_.T + $_.D) })[0]
    $u = ($t - $s.T) / $s.D
    $b = $A.Bot; $r = $A.R
    $x = $b.Tr.X; $y = $b.Tr.Y; $ang = $b.Rot.Angle; $dir = 0; $curLane = -1
    switch ($s.K) {
        'morph' {
            $k = Get-HUEaseOutBack $u
            $b.Scale.ScaleX = $k * 1.35; $b.Scale.ScaleY = $k * 1.35
            $ang = -360 * (1 - (Get-HUEaseInOut $u))
            if ($A.ImgScale) { $q = [Math]::Max(0, 1 - $u * 1.4); $A.ImgScale.ScaleX = $q; $A.ImgScale.ScaleY = $q; $A.Img.Opacity = $q }
        }
        'move' {
            $k = Get-HUEaseInOut $u
            $x = $s.X0 + ($s.X1 - $s.X0) * $k; $y = $s.Y0 + ($s.Y1 - $s.Y0) * $k
            $z = 1.35 - 0.35 * $k; $b.Scale.ScaleX = $z; $b.Scale.ScaleY = $z; $ang = 0
            if ($A.Img) { $A.Img.Opacity = 0 }
        }
        'lane' {
            $k = $u   # gleichmaessig saugen
            $x = $s.X0 + ($s.X1 - $s.X0) * $k; $y = $A.Lane * ($s.L + 0.5)
            $b.Scale.ScaleX = 1; $b.Scale.ScaleY = 1
            $ang = $(if ($s.Dir -gt 0) { 0 } else { 180 })
            $dir = $s.Dir; $curLane = $s.L
            # Bahn bis knapp vor die Saugkante aufsaugen
            $front = $x + $dir * 0.35 * $r
            $rect = $(if ($dir -gt 0) { New-Object System.Windows.Rect 0, ($A.Lane * $s.L), ([Math]::Max(0, [Math]::Min($A.W, $front))), ($A.Lane + 0.5) } else { $l0 = [Math]::Max(0, [Math]::Min($A.W, $front)); New-Object System.Windows.Rect $l0, ($A.Lane * $s.L), ($A.W - $l0), ($A.Lane + 0.5) })
            $A.Lanes[$s.L].Rect = $rect
        }
        'turn' {
            $k = Get-HUEaseInOut $u
            $x = $s.X0 + ($s.X1 - $s.X0) * $k; $y = $s.Y0 + ($s.Y1 - $s.Y0) * $k
            $ang = $s.A0 + ($s.A1 - $s.A0) * $k
            $A.Lanes[$s.Done].Rect = New-Object System.Windows.Rect 0, ($A.Lane * $s.Done), $A.W, ($A.Lane + 0.5)
        }
    }
    $b.Tr.X = $x; $b.Tr.Y = $y; $b.Rot.Angle = $ang
    $b.TextRot.Angle = - $ang
    # Buersten drehen, Sensor pulsiert
    foreach ($br in $b.Brushes) { $br[0].Angle = ($br[0].Angle + $br[1] * -900 * $dt) % 360 }
    $b.Glow.BlurRadius = 9 + 6 * (0.5 + 0.5 * [Math]::Sin($t / 90))
    # Staub einsaugen
    foreach ($d in $A.Dust) {
        if ($d.E.Visibility -ne 'Visible') { continue }
        if ($d.Lane -lt $curLane -or ($curLane -lt 0 -and $s.K -eq 'turn' -and $d.Lane -le $s.Done)) { $d.E.Visibility = 'Collapsed'; continue }
        if ($d.Lane -ne $curLane) { continue }
        $ahead = ($d.X - $x) * $dir
        if ($ahead -lt -0.1 * $r) { $d.E.Visibility = 'Collapsed'; continue }
        if ($ahead -lt 1.9 * $r) {
            $k = 1 - ($ahead + 0.1 * $r) / (2.0 * $r); $k = [Math]::Max(0, [Math]::Min(1, $k)); $k2 = $k * $k
            $tx = $x + $dir * 0.8 * $r; $ty = $y
            $nx = $d.X + ($tx - $d.X) * $k2; $ny = $d.Y + ($ty - $d.Y) * $k2
            $sz = $d.S * (1 - 0.6 * $k)
            $d.E.Width = $sz; $d.E.Height = $sz
            [System.Windows.Controls.Canvas]::SetLeft($d.E, $nx - $sz / 2); [System.Windows.Controls.Canvas]::SetTop($d.E, $ny - $sz / 2)
            $d.E.Opacity = 1 - 0.7 * $k
        }
    }
}

# Ende (oder Klick): Animation abmelden, Startbildschirm schliessen
function Stop-HUSplashSweep {
    $A = $script:SplashAnim
    $script:SplashAnim = $null
    if ($A -and $A.Handler) { try { [System.Windows.Media.CompositionTarget]::remove_Rendering($A.Handler) } catch { } }
    if ($script:Splash) { try { $script:Splash.Close() } catch { } }
    $script:Splash = $null; $script:SplashStatus = $null
}
