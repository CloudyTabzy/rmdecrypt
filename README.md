# rmdecrypt — RPG Maker MV/MZ Asset Decryptor

> A fast, native port of [Petschko's RPG-Maker-MV/MZ Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter) written in Zig 0.16.

Decrypt (and re-encrypt) RPG Maker encrypted assets — images, audio, tilesets, and more — from the command line or a native Windows GUI. No browser, Java runtime, or ZIP workflow required. Point it at a game folder and go.

## Version 1.2.0

`v1.2.0` is a GUI release: a compact card layout, live window resizing that
re-lays out continuously (no more black areas while dragging an edge), and a
rewritten log scrollbar (thumb-only hover, 1:1 drag, faster wheel).
`v1.1.0` before it brought the shared processing core, several correctness
and safety fixes (including a `--clean-output` data-loss bug), a ~1.5×
faster CLI (~2.8× faster than the original JavaScript implementation on
Node.js) and a ~2.6× faster GUI. See [CHANGELOG.md](CHANGELOG.md).

## Features

- **Decrypt** `.rpgmvp`/`.png_` → `.png`, `.rpgmvm`/`.m4a_` → `.m4a`, `.rpgmvo`/`.ogg_` → `.ogg`
- **Re-encrypt** plain assets back to MV (`.rpgmvp`/`.rpgmvm`/`.rpgmvo`) or MZ (`.png_`/`.m4a_`/`.ogg_`) format
- **PNG recovery** — restore encrypted PNG files even without the encryption key
- **Auto key detection** — reads `encryptionKey` from `System.json` (walks the tree, finds it anywhere), searches `.js`/`.txt` files for `this._encryptionKey`, or derives the key from the first encrypted PNG. Malformed keys are skipped, not used.
- **Recursive** — processes entire directory trees preserving folder structure
- **Compatibility controls** — verifies RPG Maker fake headers by default; accepts a custom 16-byte header when needed
- **Safe outputs** — never replaces existing files unless told to; `--clean-output` refuses any output folder that is, contains, or lies inside the input folder
- **Fast** — 961 files / 28.7 MB in ~130 ms; 2.8× faster than the original JavaScript implementation (see [Benchmark](#benchmark))

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

The window is a single compact form of rounded cards — **Folders**,
**Encryption Key** and **Options** (side by side on wide windows, stacked on
narrow ones) — followed by the Start button, a progress bar with status, and
an **Activity Log** card that fills the remaining height. It offers folder
pickers and drag-and-drop, key auto-detection (including for encryption),
decrypt/encrypt and MV/MZ choices, an editable fake header with reset and
validation, header-verification, overwrite and guarded clean-output options,
dark/light Tokyo Night themes, and DPI-aware sizing. The layout adapts live
while the window is resized, and jobs run on background worker threads over
the same core as the CLI, so the window stays responsive — even while it is
being dragged or resized mid-job.

## Usage

```text
rmdecrypt [options] <input_directory>

  --key, -k <hex>     32-char hex encryption key (auto-detected when omitted)
  --output, -o <dir>  Output directory (default: <input>_decrypted / _encrypted)
  --encrypt, -e       Re-encrypt plain .png/.m4a/.ogg back to RPG Maker format
  --mz                With --encrypt: write MZ extensions (.png_/.m4a_/.ogg_)
  --ignore-header     Process files even when their fake header differs
  --header <hex>      Fake header to expect / write (32 hex chars)
  --overwrite         Replace output files that already exist
  --clean-output      Delete the output directory first (refused if it
                      overlaps the input directory)
  --detect-key        Print the detected key to stdout and exit
  --jobs, -j <n>      Worker threads (default: min(CPUs, 4))
  --help, -h          Show this help
```

Exit status: `0` success, `1` failure (including any file that could not be
processed — each failure is listed with its reason), `2` invalid command line.

> `--clean-output` permanently removes the selected output directory before
> processing. Paths are resolved first, so the tool refuses an output that is
> the input, an ancestor of it, or inside it (including aliases like
> `game/.`). Still verify the output path before using this option.

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

# Only print the key found in a game directory (stdout; source on stderr)
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

> Windows 11, NVMe SSD, Windows Defender real-time protection on. Input: a
> real MZ game, 961 encrypted files (28.7 MB; median file 5.9 KB,
> 530 files in one directory) inside a 1,333-entry tree. `-Doptimize=ReleaseFast`,
> Node.js 25.8. 25 interleaved runs per tool (round-robin, fresh output
> directory each run); **all four tools produced byte-identical output trees**.

| Tool | min | median | rmdecrypt is |
|------|-----|--------|-----------|
| **rmdecrypt v1.1.0 / v1.2.0** ¹ | **126 ms** | **134 ms** | — |
| rmdecrypt v1.0.0 | 188 ms | 197 ms | 1.47× faster |
| Original JS on Node.js — async, 64 files in flight | 231 ms | 242 ms | 1.81× faster |
| Original JS on Node.js — synchronous | 339 ms | 370 ms | 2.77× faster |

¹ Measured with the 1.1.0 build; the CLI and processing core are unchanged
in 1.2.0 (a GUI-only release).

| GUI self-test (includes window + D3D11 startup) | median |
|---|---|
| v1.0.0 (15 files per frame on the UI thread) | ~1,250 ms |
| **v1.1.0** (background workers) | **~475 ms** (~2.6×) |

**About the Node.js baseline.** The original project is a browser app
(FileReader in, Blob/ZIP out), so there is no Node CLI to run as-is.
`bench/node_original.js` loads the **unmodified** `scripts/Decrypter.js` from
the original repository into Node and calls its own `decrypt()` (fake-header
check, slice, XOR) for every file, replacing only the browser I/O with
`node:fs`; the key comes from `System.json` via `JSON.parse`, as in the
original. The synchronous variant is the straightforward port; the async one
(`--async`, `fs.promises` with 64 files in flight on libuv's thread pool) is
the best Node could reasonably do. Node's times include ~43 ms of runtime
startup (rmdecrypt: ~10 ms); without it the ratios are ≈2.6× (sync) and ≈1.6× (async).
The v1.0 README quoted a 482 ms Node figure whose harness was not kept; these
numbers replace it.

Absolute times drift with background load on this machine (Defender scans new
files) — the same binaries measured 30–40% slower in a busier session — so
compare tools only within one interleaved run, as `bench/e2e.py` does.

### Where the time goes

Profiling one file at a time (`bench/io_strategies.zig` started out as this
profiler) shows the job is bound by file-system metadata, not CPU:

| step (961 files, 1 thread) | total |
|---|---|
| create output file | 144 ms |
| write | 52 ms |
| close output | 31 ms |
| open input | 24 ms |
| read | 22 ms |
| mkdir, stat, close input | 14 ms |
| XOR / transform (all files) | < 0.1 ms |

That rules out CPU tricks like SIMD or memory mapping. What helped:

1. **Spread the work across directories.** NTFS serializes file creation
   within one directory, and RPG Maker puts hundreds of assets in
   `img/characters`. Workers taking files in walk order all hit the same
   directory at once. The planner now orders work so each directory's files
   are spread evenly through the run (file *k* of *n* sits at position
   ≈ (*k*+½)/*n*), which keeps concurrent creates in different directories:

   | median ms | 1 thread | 2 | 4 | 6 | 8 | 16 |
   |---|---|---|---|---|---|---|
   | walk order | 224 | 597 | 215 | 292 | 313 | 334 |
   | spread order | 236 | 154 | **138** | **130** | 179 | 145 |

2. **Four workers by default.** Throughput peaks at 4–6 concurrent writers and
   falls off past that; `--jobs` overrides it.
3. **Zero-copy transforms.** Each worker reads a file into one reused buffer
   *after* 16 bytes of headroom, so every mode is an in-place edit plus a
   single write: decrypt writes `buf[32..]`, keyless PNG restore patches 16
   bytes, and encrypt drops the fake header into the headroom. v1.0 allocated
   and copied for encrypt and keyless PNG. This barely shows end to end, but
   it removes per-file allocation (p99 asset, 326 KB: encrypt 83.7 → 7.2 µs,
   PNG restore 92.8 → 7.8 µs, i.e. down to the memcpy floor).
4. **One tree walk for key detection** instead of up to three, and only the
   first 32 bytes of a PNG are read to derive a key.

Things that were measured and **not** adopted: preallocating output size via
`NtCreateFile` AllocationSize, and creating files relative to cached
per-directory handles (both neutral or slightly worse); a `@Vector` XOR is
kept for its fixed-size key type, not for speed (1.5 ns either way).

Tip: on volumes with NTFS 8.3 short-name generation enabled, creating many
files in one directory is slower still; `fsutil 8dot3name` (admin) controls
this system-wide.

### Reproducing

```bash
zig build bench -Doptimize=ReleaseFast -- "path/to/game"                     # CPU microbenchmarks
zig build bench-io -Doptimize=ReleaseFast -- "path/to/game" "path/to/scratch" 7 # I/O strategy matrix
python -I bench/e2e.py 20 "path/to/game" old=old.exe new=zig-out/bin/rmdecrypt.exe     "node=node|C:/full/path/to/bench/node_original.js"     "node-async=node|C:/full/path/to/bench/node_original.js --async"
```

`bench/node_original.js` expects the original project next to this one
(`../RPG-Maker-MV-Decrypter-master/scripts/Decrypter.js`); pass
`--decrypter <path>` otherwise. On Windows give Node a Windows-style path.

## License

This project is a **port** of the original [RPG-Maker-MV-Decrypter](https://github.com/Petschko/RPG-Maker-MV-Decrypter) by Peter Dragicevic, released under the MIT License. This port is also MIT.
