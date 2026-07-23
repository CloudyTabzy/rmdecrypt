# rmdecrypt — RPG Maker MV/MZ Asset Decryptor

## Overview

A fast, native command-line and GUI tool for decrypting and re-encrypting
RPG Maker encrypted assets.  Written in **Zig 0.16** with **DVUI** (SDL2)
for the graphical interface.

Converts encrypted files (`.rpgmvp`/`.png_`/`.rpgmvm`/`.m4a_`/`.rpgmvo`/`.ogg_`)
back to their standard formats (`.png`/`.m4a`/`.ogg`) — and vice versa.

## Project Structure

```
rmdecrypt/
├── build.zig           — Build config: CLI, GUI (SDL2+DVUI), tests
├── build.zig.zon       — Package manifest; dvui is a local path dep
├── README.md           — User-facing docs with benchmark
├── src/
│   ├── main.zig        — CLI entry: arg parsing, recursive walk, dispatch
│   ├── gui.zig         — GUI entry: DVUI + SDL2 window, native dialogs
│   ├── decrypter.zig   — Core: 16-byte RPG header, XOR cipher, PNG restore
│   ├── extensions.zig  — Extension mapping (encrypted ↔ normal, MV ↔ MZ)
│   └── key_detect.zig  — Auto-detect key from System.json, JS files, or PNG
└── zig-out/
    └── bin/
        ├── rmdecrypt.exe      — CLI (zig build / zig build run)
        └── rmdecrypt-gui.exe   — GUI (zig build gui)
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

### DVUI GUI
The GUI is built with [DVUI](https://github.com/david-vanderson/dvui)
(SDL2 backend) — a retained‑mode immediate‑mode hybrid GUI for Zig.
Native file dialogs use `tinyfiledialogs`.

Layout: input/output folder pickers, key auto‑detect button, mode toggle
(decrypt/encrypt + MZ), progress bar, scrollable status log.

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
