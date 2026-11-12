# Tooltip edge-visibility test using *posted* window messages only: the real
# cursor never moves, and only this app's window is ever captured.
#
#   pwsh tools/gui-tests/tooltip-test.ps1 -Exe zig-out/bin/rmdecrypt-gui.exe -Prefix <dir>/tt
#
# Resizes the window narrow (like the reported bug), then sweeps the cursor
# over the header's right-hand strip to hover the theme toggle, whose tooltip
# "Switch to light/dark theme" is wide enough to overflow the right edge in
# stock Nuklear. Detects the tooltip by pixel diff against a no-hover
# baseline, saves <Prefix>-before/after.png and reports the tooltip bounding
# box, including its gap to the client edges: a clipped tooltip has a gap of
# ~0 on the edge it runs into; a clamped one is fully inside with a border.

param([string]$Exe, [string]$Prefix, [int]$Width = 460, [int]$Height = 360)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class P {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$WM_MOUSEMOVE = 0x0200
function LP([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
function Send-Mouse([int]$x, [int]$y) { [void][P]::PostMessage($h, $WM_MOUSEMOVE, [IntPtr]0, (LP $x $y)) }
function Client() {   # client-area-only capture of this window
    $r = New-Object P+RECT; [void][P]::GetClientRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap $r.R, $r.B
    $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
    [void][P]::PrintWindow($h, $dc, 3); $g.ReleaseHdc($dc); $g.Dispose()
    return $bmp
}
function Hex($c) { "{0:x2}{1:x2}{2:x2}" -f $c.R, $c.G, $c.B }
# Bounding box of pixels that differ from the baseline
function DiffBox($base, $cur, [int]$thr = 6) {
    $x0 = 99999; $y0 = 99999; $x1 = -1; $y1 = -1; $n = 0
    for ($y = 0; $y -lt $cur.Height; $y += 2) {
        for ($x = 0; $x -lt $cur.Width; $x += 2) {
            $a = $base.GetPixel($x, $y); $b = $cur.GetPixel($x, $y)
            if ([Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B) -gt $thr) {
                $n++
                if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
                if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
            }
        }
    }
    if ($x1 -lt 0) { return $null }
    return @{ X0 = $x0; Y0 = $y0; X1 = $x1; Y1 = $y1; N = $n }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
$psi.EnvironmentVariables["RMD_TEST_HOLD"] = "1"   # window only, no job
$p = [System.Diagnostics.Process]::Start($psi)
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $h = $p.MainWindowHandle
    [void][P]::SetWindowPos($h, [IntPtr]::Zero, 80, 80, $Width, $Height, 0x0014)
    Start-Sleep -Milliseconds 1200

    # park the (posted) cursor far from any tooltip target, then baseline
    Send-Mouse 5 ([int]($Height * 0.9)); Start-Sleep -Milliseconds 250
    $base = Client
    $base.Save("$Prefix-before.png")

    # sweep the header strip's right end to hover the theme toggle. Metrics
    # are DPI-scaled, so try a grid of plausible centres; first hit wins.
    $cw = $base.Width; $hit = $null
    foreach ($y in @(24, 32, 40, 48, 56)) {
        foreach ($dx in @(26, 34, 42, 50, 58, 66, 74)) {
            $x = $cw - $dx
            if ($x -lt 1) { continue }
            Send-Mouse $x $y; Start-Sleep -Milliseconds 180
            $cur = Client
            $d = DiffBox $base $cur
            if ($d -and $d.N -gt 60) { $hit = @{ X = $x; Y = $y; D = $d; Cur = $cur }; break }
            $cur.Dispose()
        }
        if ($hit) { break }
    }
    if (-not $hit) { $base.Dispose(); "NO TOOLTIP HOVERED (sweep missed the button?)"; return }

    $cur = $hit.Cur
    $cur.Save("$Prefix-after.png")
    $d = $hit.D
    "hovered theme toggle at ($($hit.X), $($hit.Y)), client $($cw)x$($base.Height)"
    "tooltip bbox: x $($d.X0)..$($d.X1)  y $($d.Y0)..$($d.Y1)  ($($d.N) changed px)"
    "gap right  = $($cw - 1 - $d.X1) px   (a clipped tooltip reads 0-1; a clamped one shows its border inside)"
    "gap bottom = $($base.Height - 1 - $d.Y1) px"
    if ($d.X1 -lt ($cw - 3)) { "RESULT: tooltip fully inside the window (right edge not at client border)" }
    else { "RESULT: tooltip touches/exceeds the right client edge - still clipped?" }

    # Coverage check: the tooltip must paint over EVERYTHING behind it, so
    # inside the box there must be no pixels identical to the no-hover
    # baseline whose color is NOT the main window background (left-over
    # slivers show the card/widgets through; bg-on-bg pixels are
    # legitimately identical). Rows start below the hovered button.
    $boxTop = [Math]::Max($d.Y0, $hit.Y + 12)
    $bgc = $base.GetPixel([Math]::Min($cw - 2, $d.X1 + 4), [int](($boxTop + $d.Y1) / 2))
    $uncovered = 0
    $r = 16   # corner-radius notch tolerance: outside the rounded box by design
    for ($y = $boxTop; $y -le $d.Y1; $y += 2) {
        for ($x = $d.X0; $x -le $d.X1; $x += 2) {
            $cx = [Math]::Min([Math]::Max($x, $d.X0 + $r), $d.X1 - $r)
            $cy = [Math]::Min([Math]::Max($y, $boxTop + $r), $d.Y1 - $r)
            if (($x - $cx) * ($x - $cx) + ($y - $cy) * ($y - $cy) -gt ($r + 2) * ($r + 2)) { continue }
            $a = $base.GetPixel($x, $y); $b = $cur.GetPixel($x, $y)
            if ($a.R -eq $b.R -and $a.G -eq $b.G -and $a.B -eq $b.B -and
                ([Math]::Abs($a.R - $bgc.R) + [Math]::Abs($a.G - $bgc.G) + [Math]::Abs($a.B - $bgc.B)) -gt 12) {
                $uncovered++
            }
        }
    }
    if ($uncovered -eq 0) { "RESULT: background fully covered (no slivers inside the box)" }
    else { "RESULT: $uncovered unchanged pixels inside the tooltip box - background leaks!" }
    $base.Dispose(); $cur.Dispose()
} finally {
    if (-not $p.HasExited) { $p.Kill() }
}
