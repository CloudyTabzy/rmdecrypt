# rmdecrypt — RPG Maker MV/MZ Asset Decryptor

> A fast, native port of [Petschko's RPG-Maker-MV/MZ Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter) written in Zig 0.16.

Decrypt (and re-encrypt) RPG Maker encrypted assets — images, audio, tilesets, and more — from the command line. No browser needed, no file picking, no ZIP downloads. Point it at a game folder and go.

## Features

- **Decrypt** `.rpgmvp`/`.png_` → `.png`, `.rpgmvm`/`.m4a_` → `.m4a`, `.rpgmvo`/`.ogg_` → `.ogg`
- **Re-encrypt** plain assets back to MV (`.rpgmvp`/`.rpgmvm`/`.rpgmvo`) or MZ (`.png_`/`.m4a_`/`.ogg_`) format
- **PNG recovery** — restore encrypted PNG files even without the encryption key
- **Auto key detection** — reads `encryptionKey` from `System.json` (walks the tree, finds it anywhere), searches `.js`/`.txt` files for `this._encryptionKey`, or derives the key from the first encrypted PNG
- **Recursive** — processes entire directory trees preserving folder structure
- **Compatibility controls** — verifies RPG Maker fake headers by default; accepts a custom 16-byte header when needed
- **Safe outputs** — refuses to replace existing output files unless explicitly told to overwrite or clean the output directory
- **Fast** — processes 27 MB of assets (~960 files) in ~0.3s

## Build

Requires Zig 0.16.0 or later.

```bash
zig build install -Doptimize=ReleaseFast --prefix zig-out
```

The CLI binary is at `zig-out/bin/rmdecrypt.exe`.

### GUI

A native Windows GUI (Nuklear + D3D11) is included:

```bash
zig build gui        # builds and launches zig-out/bin/rmdecrypt-gui.exe
```

It offers folder pickers and drag-and-drop, key auto-detection (including
encryption), a decrypt/encrypt mode toggle (MV/MZ), editable fake-header,
header-verification, overwrite, and guarded clean-output controls, a progress
bar, and a live activity log over the same core as the CLI.

## Usage

```text
rmdecrypt [options] <input_directory>

Decrypt options:
  --key, -k <hex>     32-char hex encryption key
  --output, -o <dir>  Output directory (default: <input>_decrypted)
  --ignore-header     Process files even if the fake header is invalid
  --header <hex>      Expected fake header (exactly 32 hex characters)
  --overwrite         Replace output files that already exist
  --clean-output      Delete the output directory before processing
  --detect-key        Print the detected key and exit without writing files
  --help, -h          Show this help

Encrypt options:
  --encrypt, -e       Re-encrypt plain assets back to RPG Maker format
  --mz                Use MZ extensions (.png_/.m4a_/.ogg_) instead of MV
  --key, -k <hex>     Encryption key (auto-detected when omitted)
  --output, -o <dir>  Output directory
```

### Examples

```bash
# Decrypt a game with automatic key detection
rmdecrypt "path/to/game"

# Decrypt with known key
rmdecrypt --key a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6 "path/to/game" --output "path/to/output"

# Re-encrypt assets for MV
rmdecrypt -e --key a1b2c3d4... "path/to/plain_assets" --output "path/to/output"

# Re-encrypt assets for MZ
rmdecrypt -e --mz --key a1b2c3d4... "path/to/plain_assets" --output "path/to/output"

# Re-encrypt using the key detected from a game project's System.json
rmdecrypt -e "path/to/game" --output "path/to/output"

# Only print the key found in a game directory
rmdecrypt --detect-key "path/to/game"

# Work with a known non-standard fake header, replacing old output files
rmdecrypt --header 5250474d560000000003010000000000 --overwrite "path/to/game"
```

## How It Works

RPG Maker's built-in encryption is a simple XOR scheme, not a strong cipher:

1. **Fake header** — 16 bytes are prepended to every encrypted file: `RPGMV\0\0\0\0\x03\x01\0\0\0\0\0`
2. **XOR** — The first 16 bytes of the *payload* (after the fake header) are XORed with the encryption key
3. **Everything after the first 16 bytes is plaintext** — only the start of the file is obfuscated

**Decryption**: strip the 16-byte fake header, XOR the next 16 bytes with the key, done.

**Key recovery (PNG)**: since every PNG starts with a known 16-byte signature (`\x89PNG\r\n\x1a\n...`), XORing the encrypted bytes with the known header reveals the key.

**PNG recovery (no key)**: strip both the fake header (16 B) and the encrypted payload header (16 B), then prepend the known PNG signature.

## Benchmark

> Tested on a Windows desktop, Ryzen 5 5600, NVMe SSD, 961 encrypted files (27.37 MB total) from a real game. Zig built with `-Doptimize=ReleaseFast`.

| Build | Avg time | Throughput | vs Node.js |
|-------|----------|------------|------------|
| Zig Debug | 455 ms | 60 MB/s | 0.6× slower |
| Zig ReleaseFast (sequential) | 251 ms | 109 MB/s | 1.4× faster |
| **Zig ReleaseFast (parallel)** | **213 ms** | **128 MB/s** | **2.4× faster** |
| Node.js (reference) | 506 ms | 54 MB/s | 1× baseline |

Optimization progression:

1. **XOR in-place** — eliminated the `allocator.dupe()` that copied every file's payload before XORing. Saved one allocation + copy per file.
2. **Directory cache** — `StringHashMap` tracking already-created parent directories, slashing redundant `mkdir` syscalls.
3. **Stack-allocated paths** — `bufPrint` on a 2 KB stack buffer instead of heap `concat` for every output path.
4. **Parallel workers** — per-thread `Io.Threaded` instances + atomic work-stealing across 8 workers. Each worker gets its own I/O completion port, allowing true concurrent file I/O.

## License

This project is a **port** of the original [RPG-Maker-MV-Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter) by Peter Dragicevic, released under the MIT License. This port is also MIT.
