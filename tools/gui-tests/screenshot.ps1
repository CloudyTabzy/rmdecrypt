# Screenshot of the GUI window via PrintWindow(PW_RENDERFULLCONTENT) on the
# app's own window handle - never a screen grab, so other windows on the
# desktop can't end up in the image. No input is sent.
#
#   pwsh tools/gui-tests/screenshot.ps1 -Exe zig-out/bin/rmdecrypt-gui.exe -Out shot.png `
#        [-GameDir <game> -Output <out_dir>] [-Light] [-Width 900 -Height 700]
#
# With -GameDir the GUI runs its self-test job (RMD_TEST_INPUT/OUTPUT) and is
# held open (RMD_TEST_HOLD=1) so the shot shows a populated UI. The process
# is killed afterwards.
param(
    [string]$Exe,
    [string]$Out,
    [string]$GameDir = "",
    [string]$Output = "",
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$Light,
    [int]$WaitMs = 2500
)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$psi = New-Object System.Diagnostics.ProcessStartInfo $Exe
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
if ($GameDir) {
    $psi.EnvironmentVariables["RMD_TEST_INPUT"] = $GameDir
    $psi.EnvironmentVariables["RMD_TEST_OUTPUT"] = $Output
    $psi.EnvironmentVariables["RMD_TEST_HOLD"] = "1"
}
if ($Light) { $psi.EnvironmentVariables["RMD_TEST_LIGHT"] = "1" }
$p = [System.Diagnostics.Process]::Start($psi)
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $h = $p.MainWindowHandle
    if ($Width -gt 0) { [void][W]::SetWindowPos($h, [IntPtr]::Zero, 40, 40, $Width, $Height, 0x0004) }
    Start-Sleep -Milliseconds $WaitMs
    $r = New-Object W+RECT
    [void][W]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $gfx.GetHdc()
    [void][W]::PrintWindow($h, $dc, 2)
    $gfx.ReleaseHdc($dc)
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    "saved $Out ($($bmp.Width)x$($bmp.Height))"
} finally {
    if (-not $p.HasExited) { $p.Kill() }
}
