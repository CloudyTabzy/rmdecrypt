# Log-scrollbar behavior test using *posted* window messages only: the real
# cursor never moves, and only this app's window is ever captured.
#
#   pwsh tools/gui-tests/scrollbar-test.ps1 -Exe zig-out/bin/rmdecrypt-gui.exe `
#        -GameDir <game> -Output <out_dir> -Prefix <dir>/sc
#
# Runs a job so the log is long, then checks: thumb highlights only when the
# mouse is on it (not the empty track, not beside it); dragging moves it 1:1
# and holds through an overshoot past the top; re-grab works; the wheel
# scrolls the log. Thumb detection assumes the dark theme's scrollbar colours
# (3b4261 / 545c7e / 7aa2f7) and a 1200x800 window. Captures go to <Prefix>-*.png.
param([string]$Exe, [string]$GameDir, [string]$Output, [string]$Prefix)
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
$WM_MOUSEMOVE = 0x0200; $WM_LBUTTONDOWN = 0x0201; $WM_LBUTTONUP = 0x0202
function LP([int]$x, [int]$y) { [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF)) }
function Send-Mouse([int]$x, [int]$y, [int]$btn = 0) { [void][P]::PostMessage($h, $WM_MOUSEMOVE, [IntPtr]$btn, (LP $x $y)) }
function Client() {   # client-area-only capture of this window
    $r = New-Object P+RECT; [void][P]::GetClientRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap $r.R, $r.B
    $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
    [void][P]::PrintWindow($h, $dc, 3); $g.ReleaseHdc($dc); $g.Dispose()
    return $bmp
}
function Hex($c) { "{0:x2}{1:x2}{2:x2}" -f $c.R, $c.G, $c.B }
# Thumb = pixels of one of the three thumb colours in the right-hand strip
# of the log card (lower half of the window).
$thumbColors = @("3b4261", "545c7e", "7aa2f7")
function FindThumb($bmp) {
    $minY = 99999; $maxY = -1; $xs = @()
    for ($x = $bmp.Width - 60; $x -lt $bmp.Width - 10; $x++) {
        for ($y = [int]($bmp.Height * 0.66); $y -lt $bmp.Height - 10; $y++) {
            if ($thumbColors -contains (Hex $bmp.GetPixel($x, $y))) {
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }; $xs += $x
            }
        }
    }
    if ($maxY -lt 0) { return $null }
    $cx = [int](($xs | Measure-Object -Average).Average)
    return @{ X = $cx; Top = $minY; Bottom = $maxY; Mid = [int](($minY + $maxY) / 2) }
}
$psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
$psi.EnvironmentVariables["RMD_TEST_INPUT"] = $GameDir
$psi.EnvironmentVariables["RMD_TEST_OUTPUT"] = $Output
$psi.EnvironmentVariables["RMD_TEST_HOLD"] = "1"
$p = [System.Diagnostics.Process]::Start($psi)
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $h = $p.MainWindowHandle
    [void][P]::SetWindowPos($h, [IntPtr]::Zero, 80, 80, 1200, 800, 0x0014)  # no z-order change, no activation
    Start-Sleep -Milliseconds 2500
    $bmp = Client; $t = FindThumb $bmp; $bmp.Save("$Prefix-0.png"); $bmp.Dispose()
    if (-not $t) { "no thumb found"; return }
    "thumb at x=$($t.X) y=$($t.Top)..$($t.Bottom) (h=$($t.Bottom - $t.Top + 1))"

    $checks = @(
        @{ Name = "mouse far away";               X = $t.X - 300; Y = $t.Mid },
        @{ Name = "mouse on empty track above";   X = $t.X;       Y = $t.Top - 60 },
        @{ Name = "mouse 12px right of thumb";    X = $t.X + 12;  Y = $t.Mid },
        @{ Name = "mouse on thumb";               X = $t.X;       Y = $t.Mid }
    )
    foreach ($c in $checks) {
        Send-Mouse $c.X $c.Y; Start-Sleep -Milliseconds 200
        $bmp = Client; $col = Hex $bmp.GetPixel($t.X, $t.Mid); $bmp.Dispose()
        $state = switch ($col) { "3b4261" { "normal" } "545c7e" { "HOVER" } "7aa2f7" { "ACTIVE" } default { "other($col)" } }
        "{0,-30} -> thumb {1}" -f $c.Name, $state
    }

    # drag up 80 px in 2 px steps, holding the button (wParam MK_LBUTTON)
    [void][P]::PostMessage($h, $WM_LBUTTONDOWN, [IntPtr]1, (LP $t.X $t.Mid)); Start-Sleep -Milliseconds 60
    for ($i = 1; $i -le 40; $i++) { Send-Mouse $t.X ($t.Mid - $i * 2) 1; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 200
    $bmp = Client; $d = FindThumb $bmp; $bmp.Save("$Prefix-drag.png")
    $col = Hex $bmp.GetPixel($d.X, $d.Mid); $bmp.Dispose()
    "after dragging 80 px up     -> thumb moved $($t.Top - $d.Top) px, colour $col (active = 7aa2f7)"

    # keep holding and overshoot far past the top of the track and sideways
    for ($i = 1; $i -le 20; $i++) { Send-Mouse ($t.X + 40) ($d.Mid - $i * 30) 1; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 200
    $bmp = Client; $o = FindThumb $bmp
    if (-not $o) {
        # the thumb left the lower-half search band: search the whole strip
        $o = @{ Top = -1 }
        for ($y = [int]($bmp.Height * 0.66); $y -lt $bmp.Height; $y++) { if ($thumbColors -contains (Hex $bmp.GetPixel($t.X, $y))) { $o.Top = $y; break } }
    }
    $bmp.Save("$Prefix-top.png"); $bmp.Dispose()
    "after overshooting the top   -> thumb top at y=$($o.Top) (still dragging: drag held)"
    [void][P]::PostMessage($h, $WM_LBUTTONUP, [IntPtr]0, (LP ($t.X + 40) 0)); Start-Sleep -Milliseconds 200

    # drag back down from the top to prove the grip still works after release/regrab
    $bmp = Client
    $top = -1; for ($y = [int]($bmp.Height * 0.66); $y -lt $bmp.Height; $y++) { if ($thumbColors -contains (Hex $bmp.GetPixel($t.X, $y))) { $top = $y; break } }
    $bmp.Dispose()
    Send-Mouse $t.X ($top + 10); Start-Sleep -Milliseconds 100   # a real mouse arrives first
    [void][P]::PostMessage($h, $WM_LBUTTONDOWN, [IntPtr]1, (LP $t.X ($top + 10))); Start-Sleep -Milliseconds 60
    for ($i = 1; $i -le 25; $i++) { Send-Mouse $t.X ($top + 10 + $i * 2) 1; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 200
    $bmp = Client; $top2 = -1; for ($y = [int]($bmp.Height * 0.66); $y -lt $bmp.Height; $y++) { if ($thumbColors -contains (Hex $bmp.GetPixel($t.X, $y))) { $top2 = $y; break } }
    $bmp.Save("$Prefix-regrab.png"); $bmp.Dispose()
    [void][P]::PostMessage($h, $WM_LBUTTONUP, [IntPtr]0, (LP $t.X ($top + 60)))
    "re-grab and drag 50 px down  -> thumb moved $($top2 - $top) px"
    # mouse wheel over the log text: compare the log text region before and
    # after 3 notches down (content movement, not thumb pixels)
    function LogSig() {
        $b = Client; $sig = ""
        for ($y = [int]($b.Height * 0.78); $y -lt $b.Height - 20; $y += 3) { $sig += Hex $b.GetPixel(70, $y); $sig += Hex $b.GetPixel(110, $y) }
        $b.Dispose(); return $sig
    }
    Send-Mouse ($t.X - 400) ([int](($t.Mid + $top2) / 2)); Start-Sleep -Milliseconds 150
    $before = LogSig
    $bmp = Client; $bmp.Save("$Prefix-wheel0.png"); $bmp.Dispose()
    for ($i = 0; $i -lt 3; $i++) {
        # move + wheel back to back: a real cursor resting over the window
        # generates its own WM_MOUSEMOVEs and would otherwise win
        Send-Mouse ($t.X - 400) ([int](($t.Mid + $top2) / 2))
        [void][P]::PostMessage($h, 0x020A, [IntPtr]((-120) -shl 16), (LP 0 0)); Start-Sleep -Milliseconds 120
    }
    Start-Sleep -Milliseconds 200
    $after = LogSig
    $bmp = Client; $bmp.Save("$Prefix-wheel1.png"); $bmp.Dispose()
    "3 wheel notches down         -> log content changed: $($before -ne $after)"
} finally {
    if (-not $p.HasExited) { $p.Kill() }
}
