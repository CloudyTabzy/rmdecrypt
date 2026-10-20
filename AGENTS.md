# rmdecrypt — RPG Maker MV/MZ Asset Decryptor

## Overview

A fast, native command-line and GUI tool for decrypting and re-encrypting
RPG Maker encrypted assets.  Written in **Zig 0.16**; the GUI is a native
Win32 app built on **Nuklear** (D3D11 backend) — no SDL, no browser.

Converts encrypted files (`.rpgmvp`/`.png_`/`.rpgmvm`/`.m4a_`/`.rpgmvo`/`.ogg_`)
back to their standard formats (`.png`/`.m4a`/`.ogg`) — and vice versa.

## Project Structure

```
rmdecrypt/
├── build.zig           — Build config: CLI, GUI (Nuklear+D3D11), tests, benches
├── build.zig.zon       — Package manifest; no external dependencies
├── README.md           — User-facing docs with benchmark
├── src/
│   ├── main.zig        — CLI entry: arg parsing, reporting, exit codes
│   ├── processor.zig   — Shared core: plan (walk + spread order), in-place
│   │                     transform, parallel Job, clean-output safety
│   ├── lib.zig         — Library root re-exporting the core (for bench/)
│   ├── gui.zig         — GUI logic layer: rmd_zig_* exports + entry points
│   ├── gui_nk.c        — GUI widget tree (Nuklear, all UI lives in C)
│   ├── nk_shim.c       — GUI platform layer: Win32 window, D3D11, events
│   ├── win32_folder_dialog.zig — Native folder picker (IFileOpenDialog → SHBrowseForFolder)
│   ├── decrypter.zig   — Primitives: header check, XOR, PNG key derivation, hex
│   ├── extensions.zig  — Extension mapping (encrypted ↔ normal, MV ↔ MZ)
│   └── key_detect.zig  — Auto-detect key from System.json, JS files, or PNG
├── bench/
│   ├── micro.zig       — CPU microbenchmarks (zig build bench)
│   ├── io_strategies.zig — Work-order × thread-count matrix (zig build bench-io)
│   ├── e2e.py          — Interleaved end-to-end CLI comparison + output check
│   └── node_original.js — Original Decrypter.js under Node.js (JS baseline)
├── tools/
│   └── gui-tests/      — GUI screenshot, scrollbar and live-resize test scripts
├── vendor/
│   └── nuklear/        — Vendored nuklear.h (patched, see below) + D3D11 backend
└── zig-out/
    └── bin/
        ├── rmdecrypt.exe      — CLI (zig build / zig build run)
        └── rmdecrypt-gui.exe  — GUI (zig build gui)
```

## Key Design Decisions

### Port from JavaScript
The original decrypter by Peter Dragicevic was a browser‑based HTML+JS app.
This port extracts the core algorithm and exposes it through both a CLI
and a native GUI — no browser needed.

### Encryption Scheme (not a real cipher)
RPG Maker's "encryption" is a trivial XOR of the first 16 payload bytes:

1. A 16‑byte fake header (`RPGMV\0...`) is prepended to every file.
2. The first 16 bytes of the payload (after the header) are XORed with
   a 16‑byte key.
3. Everything beyond byte 32 is plaintext.

**Decryption**: strip header, XOR 16 bytes → done.
**PNG recovery** (no key): strip 32 bytes, prepend known PNG signature
`\x89PNG\r\n\x1a\n...`
**Key derivation**: `key[i] = known_png_header[i] ^ encrypted_payload[i]`

### Shared core (`processor.zig`)
CLI and GUI are thin front ends over one module; do not reintroduce
per-front-end copies of the per-file logic (that is how they drifted apart
and grew different bugs before v1.1.0).

- `plan` walks the input once, keeps processable files, and orders them with
  `spreadByDirectory`.
- `processFile` reads a file into a reused per-worker `Scratch` buffer
  *after* 16 bytes of headroom; `transform` then works in place and returns
  the slice to write (decrypt: `buf[32..]`; keyless PNG: patch 16 bytes;
  encrypt: fake header into the headroom). One read, one write, no copies.
- `Job` runs files on `std.Thread` workers sharing the process `Io`
  (`Io.Threaded` makes plain blocking `Nt*` calls on Windows; per-thread
  instances bring nothing). Each worker publishes a per-file result as an
  atomic `u32` (0 pending, 1 ok, 2+error code), so the GUI can poll results
  without locks while the CLI reads them after `join`.
- `checkCleanTarget` resolves both paths and refuses to clean an output that
  is, contains, or lies inside the input. Always call it before `deleteTree`.

### Performance model
The workload is **file-system-metadata bound**: creating output files costs
far more than everything else, and XOR/transform work is < 0.1% of the
runtime. NTFS serializes creates within a directory, so:

- Work is interleaved across directories (file k of n at ≈ (k+½)/n of the
  run), which cut wall time ~1/3 vs walk order.
- `defaultJobs()` = min(CPUs, 4); throughput peaks at 4–6 writers and drops
  beyond. Re-measure with `zig build bench-io` before changing it.
- Measured and rejected: NtCreateFile AllocationSize preallocation and
  per-directory handle creates (neutral or worse).

| Build (961 files / 28.7 MB, ReleaseFast) | median | vs v1.0.0 |
|---|---|---|
| Original JS on Node.js, sync / async | 370 / 242 ms | — |
| v1.0.0 CLI | 197 ms | 1.00× |
| **v1.1.0+ CLI** (core unchanged in 1.2.0) | **134 ms** | **1.47×** (2.77× / 1.81× vs Node) |
| v1.0.0 GUI self-test | ~1,250 ms | 1.00× |
| **v1.1.0 GUI self-test** | **~475 ms** | **~2.6×** |

Benchmark with interleaved runs (`bench/e2e.py`): Defender scanning makes
single runs noisy.

### GUI processing
`rmd_zig_scan` validates, detects the key, plans and prepares the output
(UI thread). The first `rmd_zig_step` starts a `processor.Job`; each frame's
`rmd_zig_step` drains finished results into the log in order. Progress
reports the drained count, so `done >= total` implies the summary line is
logged. The log is a fixed ring buffer (`Log.cap`); a string from
`rmd_zig_log_get` is valid until the next log call. All `rmd_zig_*` exports
must stay on the UI thread.

### Nuklear GUI (C UI / Zig logic split)
The GUI follows the same architecture as the sibling `btworkshop_zig`
project: **all Nuklear widget code lives in C**, Zig only exports
application logic.  This avoids the entire class of `@cImport` ABI issues
(struct‑by‑value calls into the single‑header library) and keeps the UI
code byte‑identical to upstream Nuklear demo patterns.

- `nk_shim.c` — the Nuklear implementation TU (`NK_IMPLEMENTATION` +
  `NK_D3D11_IMPLEMENTATION`), Win32 window, D3D11 device/swap‑chain
  (hardware → WARP fallback), WndProc (including `WM_DROPFILES` for
  drag‑and‑drop), DPI awareness, font stash (Segoe UI regular/bold/italic/
  title + Segoe MDL2 Assets icons, fetched via `nkshim_font()`), message
  pump and present.  Exports a tiny `nkshim_*` API.
- `gui_nk.c` — the widget tree (folders, key, options, progress, colored
  scrollable log).  Declarations‑only TU; the feature defines MUST match
  `nk_shim.c` (Nuklear's ABI depends on them).  Tokyo Night dark + light
  (day) themes with a title‑bar toggle, MDL2 icon glyphs in
  headings/status lines.
- `gui.zig` — exports `rmd_zig_*` (is_dir, pick_folder, detect_key, scan,
  step, progress, log access) called from C; `main`/`WinMain` forward to
  `rmd_gui_main()`.

Layout (`draw()` in `gui_nk.c`): header row, then rounded **cards**
(Nuklear groups with `NK_WINDOW_BORDER | NK_WINDOW_NO_SCROLLBAR`) for
Folders, Encryption Key and Options, the Start button + progress area, and
an Activity Log card that takes the remaining height. Rules that keep it
neat:

- **Use template rows** (`nk_layout_row_template_*`) for multi-column rows.
  They subtract Nuklear's inter-item spacing; hand-computed `NK_STATIC`
  widths that sum to the full width overflow by `spacing.x` per gap and clip
  the right edge (the v1.0 bug behind the cut-off button corners).
- **Never end a template row with `nk_spacing()`**: spacing in the last
  column wraps to a new row. Use `nk_label(ctx, "", ...)` as a filler.
- **Scale every metric with `S()`** (`nkshim_dpi_scale()`); fonts are baked
  at the window's DPI.
- Card heights are computed up front (`card_h()` = rows + gaps + padding +
  border), because a card has no scrollbar. Add a row → update its `*_h()`.
- The main window only scrolls when the form plus `LOG_MIN_H` does not fit;
  otherwise it reserves no scrollbar so both margins match.
- The log owns its scroll offsets (`g.log_sx/log_sy`); snap by setting
  `log_sy`, not `nk_group_set_scroll()`.
- Key/Options sit side by side above `WIDE_MIN`, stacked below it.

Vendored Nuklear patches (search `rmdecrypt patch` in `nuklear.h`; re-apply
if Nuklear is ever updated):
- `style.window.group_background` — card background for group panels.
- `nk_rgb_factor` fades alpha instead of darkening RGB (disabled widgets
  recede on the light theme too).
- `nk_do_scrollbarv` — rewritten vertical scrollbar body. One geometry for
  draw, hover, press and drag: minimum thumb length, hover only on the
  thumb, 1:1 drag that re-anchors the press point on the *same* thumb it
  draws (the stock code re-centres it on the stock thumb, so any geometry
  tweak outside this function breaks dragging), track click pages, wheel
  ≥ 3 text lines per notch. Horizontal scrollbars are stock.
The patched header must stay shared by `nk_shim.c` and `gui_nk.c`.

Live resize (`nk_shim.c`): Windows runs a *modal* move/size loop inside
`DispatchMessage` while an edge or the title bar is dragged, which blocks
the app's frame loop. `gui_nk.c` registers its whole frame (`frame()`:
draw + step + render) with `nkshim_set_frame_callback`, and the WndProc
calls it on every `WM_SIZE` and from a 16 ms timer between
`WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`. Those calls happen inside the pump's
`nk_input_begin/end` bracket, so `frame_from_wndproc()` closes and reopens
it, and a re-entrancy guard skips nested frames (e.g. from a modal dialog's
own message loop). Anything per-frame must live in `frame()`, not in the
`while (nkshim_pump_events())` loop, or it will stall during resizes.

The key field holds the key as a **32-char hex string**; Zig parses it at
scan time (`decrypter.parseHex16`). Auto-detect always returns hex
(`key_detect.Detected.hex()`), whatever the source.

Link libs (Windows): `user32 gdi32 d3d11 dxguid shell32 ole32`.
Precompiled shader headers are used — no d3dcompiler needed.

## Development

```bash
# CLI
zig build run -- <input_dir> [--key <hex>] [--output <dir>]

# GUI
zig build gui

# Tests
zig build test

# Benchmarks (use ReleaseFast)
zig build bench -Doptimize=ReleaseFast -- <game_dir>
zig build bench-io -Doptimize=ReleaseFast -- <game_dir> <scratch_dir> [reps]
python -I bench/e2e.py 20 <game_dir> old=<old.exe> new=zig-out/bin/rmdecrypt.exe

# Release build
zig build install -Doptimize=ReleaseFast --prefix zig-out
```

### Locked build artifacts

When a requested rebuild is blocked because a project-local executable is
running, first verify the process path is inside this repository's
`zig-out/bin/` directory. It is then authorized to terminate that verified
process with `Stop-Process -Force` and rerun the build; do not terminate
unrelated processes with the same executable name.

### Headless GUI self-test

The GUI has an environment-driven self-test (no clicking required;
the window flashes briefly). Set `RMD_TEST_INPUT` (required),
`RMD_TEST_OUTPUT`, `RMD_TEST_ENCRYPT=1`, `RMD_TEST_MZ=1`, `RMD_TEST_KEY=<hex>`
(otherwise auto-detected), `RMD_TEST_LIGHT=1`, then run `rmdecrypt-gui.exe` —
it runs the job to completion, dumps the log to stdout and exits
(0 = success, 2 = job could not start, 3 = errors). `RMD_TEST_HOLD=1` keeps
the window open afterwards instead, for screenshots of a populated UI
(capture it with `PrintWindow(..., PW_RENDERFULLCONTENT)` on the app's own
window handle — never a screen capture, which can record other windows).
For interaction tests, post `WM_MOUSEMOVE`/`WM_LBUTTONDOWN`/… to the window
instead of moving the real cursor; post a move right before each wheel
event, since a real cursor resting over the window emits its own moves. Ready-made scripts for all of this are in `tools/gui-tests/`.

```bash
RMD_TEST_INPUT="C:\path\to\game" RMD_TEST_OUTPUT="C:\path\to\out" ./zig-out/bin/rmdecrypt-gui.exe
```

## CLI Reference

```
rmdecrypt [options] <input_directory>

  --key, -k <hex>     32-char hex encryption key (auto-detected when omitted)
  --output, -o <dir>  Output directory (default: <input>_decrypted / _encrypted)
  --encrypt, -e       Re-encrypt plain assets back to RPG Maker format
  --mz                With --encrypt: MZ extensions (.png_/.m4a_/.ogg_)
  --ignore-header     Process files even when their fake header differs
  --header <hex>      Fake header to expect / write (32 hex chars)
  --overwrite         Replace output files that already exist
  --clean-output      Delete the output dir first (refused if it overlaps input)
  --detect-key        Print the detected key to stdout and exit
  --jobs, -j <n>      Worker threads (default: min(CPUs, 4))
  --help, -h          Show this help
```

Exit status: 0 success, 1 failure (any file not processed), 2 usage error.

Key auto-detection (when `--key` is omitted, including encryption), via one
tree walk; each candidate must be exactly 32 hex chars or it is skipped:
1. `encryptionKey` in `System.json` (known MV/MZ paths, then anywhere)
2. `this._encryptionKey = "..."` in `.js`/`.txt` files
3. Derived from the first encrypted PNG (reads only its first 32 bytes)
4. If nothing works: PNGs are restored without a key, audio files are
   reported as failures, and `--encrypt` aborts.

## License

MIT — based on the original [RPG‑Maker‑MV‑Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter)
by Peter Dragicevic.
