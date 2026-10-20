# Live (modal) resize test. WARNING: this drives the REAL mouse for about
# two seconds - don't touch the mouse while it runs. A modal move/size loop
# only starts from genuine input, so this cannot be done with posted
# messages. The test window is made topmost so the synthetic press can only
# land on it, and the cursor is restored afterwards.
#
#   pwsh tools/gui-tests/live-resize-test.ps1 -Exe zig-out/bin/rmdecrypt-gui.exe `
#        -GameDir <game> -Output <out_dir> -Prefix <dir>/rs
#
# Grabs the bottom-right resize border, drags it out 240x150 px, and captures
# the window (PrintWindow, app window only) while the button is still held
# (<Prefix>-during.png) and after release (<Prefix>-after.png). A correct
# build shows a fully re-laid-out window in -during; v1.0/1.1 showed black.
param(
    [string]$Exe, [string]$Prefix, [string]$GameDir, [string]$Output
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class M {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
# Captures only this app's window (PrintWindow on its handle), never the
# screen, so other windows on the desktop can't end up in a capture.
function Shot([string]$path) {
    $r = New-Object M+RECT
    [void][M]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc()
    [void][M]::PrintWindow($h, $dc, 2)
    $g.ReleaseHdc($dc)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
$psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.EnvironmentVariables["RMD_TEST_INPUT"] = $GameDir
$psi.EnvironmentVariables["RMD_TEST_OUTPUT"] = $Output
$psi.EnvironmentVariables["RMD_TEST_HOLD"] = "1"
$p = [System.Diagnostics.Process]::Start($psi)
$saved = New-Object M+POINT
[void][M]::GetCursorPos([ref]$saved)
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $h = $p.MainWindowHandle
    # topmost: synthetic clicks can then only ever land on this window
    [void][M]::SetWindowPos($h, [IntPtr](-1), 60, 60, 1000, 720, 0)
    [void][M]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 2500
    $r = New-Object M+RECT
    [void][M]::GetWindowRect($h, [ref]$r)

    # inner edge of the resize border (DWM's invisible border is ~7 px)
    $x = $r.R - 3; $y = $r.B - 3
    [void][M]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 300
    [M]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
    for ($i = 1; $i -le 30; $i++) {
        [void][M]::SetCursorPos($x + $i * 8, $y + $i * 5); Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 400                          # held, not moving
    Shot "$Prefix-during.png"
    [M]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
    Start-Sleep -Milliseconds 500
    [void][M]::GetWindowRect($h, [ref]$r)
    Shot "$Prefix-after.png"
    "window after drag: $($r.R - $r.L)x$($r.B - $r.T)"
} finally {
    [M]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    [void][M]::SetCursorPos($saved.X, $saved.Y)
    if (-not $p.HasExited) { $p.Kill() }
}
