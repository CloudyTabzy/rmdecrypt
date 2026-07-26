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
├── build.zig           — Build config: CLI, GUI (Nuklear+D3D11), tests
├── build.zig.zon       — Package manifest; no external dependencies
├── README.md           — User-facing docs with benchmark
├── src/
│   ├── main.zig        — CLI entry: arg parsing, recursive walk, dispatch
│   ├── gui.zig         — GUI logic layer: rmd_zig_* exports + entry points
│   ├── gui_nk.c        — GUI widget tree (Nuklear, all UI lives in C)
│   ├── nk_shim.c       — GUI platform layer: Win32 window, D3D11, events
│   ├── win32_folder_dialog.zig — Native folder picker (IFileOpenDialog → SHBrowseForFolder)
│   ├── decrypter.zig   — Core: 16-byte RPG header, XOR cipher, PNG restore
│   ├── extensions.zig  — Extension mapping (encrypted ↔ normal, MV ↔ MZ)
│   └── key_detect.zig  — Auto-detect key from System.json, JS files, or PNG
├── vendor/
│   └── nuklear/        — Vendored nuklear.h + D3D11 backend headers
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

### Parallel I/O
The CLI uses per‑thread `Io.Threaded` instances + atomic work‑stealing
across 8 workers.  Each worker gets its own I/O completion port, enabling
true concurrent file I/O on Windows.

The GUI processes files in‑frame (15 per frame) to keep the UI responsive
without threading complexity.

### Performance
| Build | Time (961 files / 27 MB) | vs Node.js |
|---|---|---|
| Debug | 455 ms | 0.6× |
| ReleaseFast (sequential) | 251 ms | 1.4× |
| **ReleaseFast (parallel)** | **213 ms** | **2.4×** |

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

Layout: input/output folder rows (Browse buttons + drag‑and‑drop), key
field with auto‑detect, mode toggle (decrypt/encrypt + MV/MZ), progress
bar, scrollable status log.

The key field holds the key as a **32‑char hex string**; Zig converts it
to raw bytes at scan time (`key_detect.hexKeyToBytes`).  Auto‑detect
normalizes both sources (hex string from System.json/JS, raw bytes from
PNG derivation) to hex for display.

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

# Release build
zig build install -Doptimize=ReleaseFast --prefix zig-out
```

### Headless GUI self-test

The GUI has an environment-driven self-test (no clicking required;
the window flashes briefly). Set `RMD_TEST_INPUT` (required),
`RMD_TEST_OUTPUT`, `RMD_TEST_ENCRYPT=1`, `RMD_TEST_MZ=1`, then run
`rmdecrypt-gui.exe` — it auto-detects the key, runs the job to
completion, dumps the log to stdout and exits (0 = success, 3 = errors):

```bash
RMD_TEST_INPUT="C:\path\to\game" RMD_TEST_OUTPUT="C:\path\to\out" ./zig-out/bin/rmdecrypt-gui.exe
```

## CLI Reference

```
rmdecrypt [options] <input_directory>

  --key, -k <hex>     32‑char hex encryption key
  --output, -o <dir>  Output directory (default: <input>_decrypted)
  --ignore-header     Skip fake‑header verification warning
  --encrypt, -e       Re‑encrypt plain assets back to RPG Maker format
  --mz                Use MZ extensions (.png_/.m4a_/.ogg_)
  --help, -h          Show this help
```

Key auto‑detection (when `--key` is omitted):
1. Read `encryptionKey` from `System.json` (walks tree, finds anywhere)
2. Search `.js`/`.txt` files for `this._encryptionKey` assignment
3. Derive key from the first encrypted PNG in the input tree
4. If nothing works, PNG files are restored without a key, audio files skipped

## License

MIT — based on the original [RPG‑Maker‑MV‑Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter)
by Peter Dragicevic.
