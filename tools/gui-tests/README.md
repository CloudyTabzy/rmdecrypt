# GUI test tools

PowerShell helpers used to verify the Nuklear GUI (see AGENTS.md, "Headless
GUI self-test"). All of them launch `rmdecrypt-gui.exe` with the self-test
environment (`RMD_TEST_INPUT`/`RMD_TEST_OUTPUT`, `RMD_TEST_HOLD=1`), capture
only the app's own window with `PrintWindow`, and kill the process at the end.

| Script | Input | Checks |
|---|---|---|
| `screenshot.ps1` | none | Saves a PNG of the populated window (dark or `-Light`, optional size). |
| `scrollbar-test.ps1` | posted messages (real cursor untouched) | Thumb-only hover, 1:1 drag, drag held through overshoot, re-grab, wheel scrolling. |
| `live-resize-test.ps1` | **real mouse, ~2 s** | Captures the window mid-resize (button held) to prove it re-lays out instead of showing black. |
| `tooltip-test.ps1` | posted messages (real cursor untouched) | Hovers the theme toggle in a narrow window. Asserts (1) the tooltip is clamped fully inside the client area instead of being cut off, and (2) its background fully covers everything behind it - no unchanged pixels inside the rounded box except the corner notches, i.e. no edge slivers leaking the UI behind. |

Run them on a release build (`zig build -Doptimize=ReleaseFast`) from the
`rmdecrypt` directory; pass Windows-style paths.
