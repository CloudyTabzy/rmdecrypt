# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.1] - 2026-11-12

Point release: two code-quality fixes found while branding.

### Fixed

- **Tooltip hover ownership.** `field_row` and the theme toggle queried
  hover with `nk_widget_is_hovered()`, which peeks the *next* layout slot,
  not the widget it belongs to - an accident of call ordering decided
  which rectangle actually triggered the tip. Both sites now test the
  button's own `ctx->last_widget_state & NK_WIDGET_STATE_HOVER` right
  after drawing it: hover belongs to the button the tooltip describes,
  at any position inside it. Verified with posted-message probes on the
  toggle (main window) and the Detect button (inside a group card).

### Changed

- **Single-sourced version string.** The version now lives only in
  `build.zig.zon`'s `.version`; `build.zig` reads it from the manifest
  text and injects it into the CLI via a `build_options` module and into
  the GUI C code via `-DRMD_VERSION`, replacing three hand-edited
  literals per release (a real hazard: they had already drifted once).

## [1.5.0] - 2026-11-12

GUI polish release: the tooltips behave, the window has a face, and the
vendored GUI library is current.

### Added

- **App icon.** A multi-resolution `rmdecrypt.ico` (16–256 px, the slime
  bandit emblem) is compiled into the GUI executable via
  `resources/app.rc` + `addWin32ResourceFile`; the window class is now a
  `WNDCLASSEX` that loads it for the title bar / taskbar (`hIcon`) and a
  true 16 px `hIconSm`. Before, the app wore the stock Windows
  `IDI_APPLICATION` icon everywhere.
- **Branding assets.** `assets/` holds the README wordmark banner, the
  256 px icon preview and the icon master; the banner opens the README.
- **`tools/gui-tests/tooltip-test.ps1`** — posted-message headless check
  that a tooltip is (1) fully inside the window and (2) fully opaque over
  whatever is behind it (no unchanged pixels inside the rounded box except
  the corner notches).
- **`vendor/nuklear/rmdecrypt-nuklear.patch`** captures the whole fork
  against pristine v4.13.4; verified byte-exact on re-apply. AGENTS.md
  documents the bump workflow.

### Changed

- **Vendored Nuklear v4.13.3 → v4.13.4.** 12 of 13 fork hunks applied
  cleanly; the single conflict (tooltip width) merged in our favor —
  upstream fixed only the width line, our patch also compacts the height
  and fixes the box shape. Gained upstream fixes: nonblocking-popup
  `buf.active` leak, font oversampling, utf8 `NUL`/`remove_runes`
  off-by-one, `global_alpha` applied once per `stroke_poly_line`. The
  vendored d3d11 backend is byte-identical between the tags.
- **Tooltip box compacted.** Sized from `popup_padding` only
  (`TT_PAD_X`/`TT_PAD_Y` in `gui_nk.c`, DPI-scaled) instead of the main
  window's padding doubled by the popup panel's inset — which made the box
  fat with a dead gutter on the right — and the row is offset so the text
  sits vertically centered.

### Fixed

- **Tooltips clipped at window edges.** `nk_tooltip_begin_offset` now
  clamps the tooltip into the parent panel's visible clip rect, nudging it
  back the minimum needed so it stays near the cursor but never renders
  cut off by the HWND.
- **Tooltip edge slivers and corner tabs.** Dynamic panels never get the
  rounded body fill; upstream instead painted the box with square fills
  (a per-row rect in `nk_panel_layout`, edge strips in `nk_panel_end`)
  that stuck flat tabs out of the rounded border's corner arcs, and the
  popup's content-rect scissor left unpainted slivers at each end through
  which the UI behind showed. Tooltips now draw one rounded background —
  emitted between real scissor commands so it reaches the border — and the
  square fills are skipped for tooltip panels.
- Version bumped to 1.5.0 (CLI, GUI title, package manifest).
- `LICENSE` file added (MIT; matches the README's claim) with attribution
  to the original RPG-Maker-MV-Decrypter.

## [1.2.0] - 2026-10-21

GUI release: a redesigned layout, live window resizing, and a scrollbar
that works.

### Fixed

- **Black area while resizing.** Dragging a window edge (or the title bar)
  makes Windows run a modal move/size loop inside `DispatchMessage`, which
  froze the app's frame loop until the mouse was released, so the newly
  exposed area stayed black and the layout stale. The window procedure now
  renders frames itself during that loop — on every `WM_SIZE` and from a
  16 ms timer between `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` — so the layout
  adapts continuously while resizing, and progress/log keep updating while
  the window is dragged mid-job. Maximize, restore and snap re-render
  immediately too, and GDI background erasing (a flash source) is disabled.
- **Log scrollbar hover and drag.** Stock Nuklear highlighted the thumb
  whenever the mouse was anywhere over the (invisible) track, and the
  minimum-thumb patch from the redesign drew the thumb somewhere other than
  where Nuklear hit-tested and dragged it, so dragging lost its grip after a
  few pixels. The vertical scrollbar is now one self-consistent
  implementation: a minimum thumb length, hover/press only on the thumb
  itself, 1:1 drag that holds through overshooting either end, click on the
  track to page, and a mouse wheel step of at least three text lines (stock
  was 10% of the view — less than one log line per notch).
- When minimized, a frame's draw commands were never consumed (the backend
  only clears them while it has a render target).
- At medium widths the key field was too narrow for a 32-character key, and
  a lone checkbox ("Clean output folder first") was cut short.
- GUI: buttons at the right edge (theme toggle, Browse) had their right
  corners clipped. Static rows summed item widths to the full width and
  ignored Nuklear's 10 px inter-item spacing, overflowing by 10 px per gap.
- GUI: the activity log never actually snapped to the newest entry —
  `nk_group_set_scroll()` wrote Nuklear's internal offsets while the log
  group reads its own.
- GUI self-test exited 0 when the job could not start (e.g. no key for
  encryption); it now exits 2.

### Changed

- **Redesigned GUI layout.** Compact rounded cards (Folders, Encryption
  Key, Options, Activity Log) with one shared label column, template rows
  that fill the width exactly, Key/Options side by side on wide windows and
  stacked on narrow ones, a square theme toggle with a tooltip, a stable
  progress area with a status line (ready / processing / done / errors), and
  a log card that fills the remaining height (the form only scrolls when the
  window is too short for it). Layout metrics now scale with DPI like the
  fonts already did. Added fake-header reset and validation, a log Clear
  button, and the Format choice is disabled while decrypting (it only
  affects encryption). Inputs are disabled while a job runs.
- Vendored Nuklear patches (marked `rmdecrypt patch` in `nuklear.h`): a
  `group_background` style for card panels, disabled widgets fade by alpha
  instead of darkening (so they recede on the light theme), and a rewritten
  vertical scrollbar (see Fixed).
- Key/Options cards go side by side only when the key field can show all
  32 hex characters (measured from the font, so it holds at any DPI); the key
  row's button is now a compact "Detect" with a tooltip, as is "Reset".
- Version bumped to 1.2.0 (CLI, GUI title, package manifest).

### Added

- `bench/node_original.js`: runs the original project's unmodified
  `Decrypter.js` under Node.js (synchronous and `--async` variants) as the
  JavaScript baseline. rmdecrypt is 2.77× / 1.81× faster than those, with
  byte-identical output (README "Benchmark").
- GUI self-test variables `RMD_TEST_KEY` (skip auto-detection) and
  `RMD_TEST_HOLD` (keep the window open, for screenshots).

## [1.1.0] - 2026-10-21

### Fixed

- **`--clean-output` could delete the input.** The only guard was a
  string comparison, so an output folder that was a parent of the input
  (`-o game` for input `game/sub`), an alias (`game/.`), or inside it was
  deleted along with the source files. Both front ends now resolve the paths
  and refuse any output that is, contains, or lies inside the input.
- **PNG-derived keys crashed the CLI.** When the key came from an encrypted
  PNG (no System.json or script key), the raw key bytes were parsed as hex:
  the CLI printed garbage and exited with `error: InvalidCharacter`.
- **Encrypting without a key reported success.** Every file was silently
  skipped and the run ended with "N files processed successfully". It is now
  an error.
- **Malformed detected keys were used verbatim.** A System.json or script
  key that was not 32 hex characters was used as raw bytes (GUI) or crashed
  the run (CLI). Invalid candidates now fall through to the next source.
- **Folder picker double-released the COM dialog** on Cancel (and on
  allocation failure) — an `errdefer` released it a second time after the
  explicit release. The dialog title was also passed to `SetTitle` without a
  NUL terminator (buffer over-read).
- GUI: clearing the log leaked every message; the log is now a ring buffer
  that frees evicted entries.
- CLI exit status was 0 even when the input folder could not be opened or
  files failed. It is now 0 = success, 1 = failure, 2 = usage error.
- Per-file failures were only counted. Both front ends now list each failed
  file with a reason (header mismatch, output exists, needs key, …).
- An unknown `--option` was taken as the input directory; it is now rejected.
- Key detection stopped at the first unreadable subdirectory; it now skips
  it and continues.
- Default output for `game/` (trailing separator) was `game/_decrypted`,
  inside the input. Trailing separators are now ignored, and encrypt mode
  defaults to `<input>_encrypted`.
- Misleading message: invalid keys were reported as needing "even length";
  a key must be exactly 32 hex characters.

### Changed

- **New shared core, `src/processor.zig`.** The CLI and GUI previously had
  separate, diverging copies of the per-file logic (which is how the GUI and
  CLI ended up with different bugs). Planning, the transform, parallel
  execution, error descriptions and clean-output safety now live in one
  tested module.
- **CLI ~1.47× faster** (median 191 → 130 ms on a 961-file game). The
  planner spreads work across directories so concurrent workers stop
  contending on NTFS per-directory locks. The default is 4 workers
  (measured optimum), overridable with `--jobs`.
- **GUI ~2.6× faster and responsive during jobs.** Files are processed on
  background workers instead of 15 per frame on the UI thread (which capped
  throughput at ~900 files/s at 60 Hz). Results are drained into the log
  each frame.
- Zero-copy transforms: files are read after 16 bytes of headroom, so
  encrypt and keyless PNG restore no longer allocate and copy each file.
  One reusable buffer per worker replaces the 256 KB stack buffer and the
  per-file heap allocation for larger files.
- Key detection walks the tree once instead of up to three times, reads only
  32 bytes of a PNG to derive a key, and reports which source the key came
  from.
- `--detect-key` prints the key to **stdout** (the source goes to stderr),
  so it can be captured by scripts.
- The CLI prints elapsed time; workers share the process `Io` instance
  instead of creating one `Io.Threaded` each.
- `decrypter.zig` API: fixed-size `Key`/`Header` types and allocation-free
  `xorKey`, `verifyHeader`, `deriveKeyFromPng`, `parseHex16`.
- Uses Zig 0.16's `std.mem.find*` names instead of the deprecated
  `indexOf*` aliases.

### Added

- `--jobs, -j <n>` worker-thread option.
- Benchmarks: `zig build bench` (CPU microbenchmarks), `zig build bench-io`
  (file-system strategy matrix), and `bench/e2e.py` (interleaved end-to-end
  comparison with output verification). See README "Benchmark".
- Tests for key-detection priority and fall-through, script-key parsing, the
  in-place transforms, work ordering, path-overlap checks, argument parsing,
  and an end-to-end plan → parallel job → overwrite protection → re-encrypt
  round trip (14 → 19 tests).

### Removed

- `test/fixtures.zig`: it was never referenced, and it could not compile
  because it imported outside its module root. Its fixtures are now built
  inside the tests that use them.

## [1.0.0] - 2026-07-26

### Added

- First stable release of the native RPG Maker MV/MZ asset decryptor.
- Native Windows GUI with folder pickers, drag-and-drop, automatic key
  detection, MV/MZ encrypt/decrypt controls, safe output options, and a live
  activity log.
- CLI compatibility and safety controls: custom fake headers, strict header
  verification, `--overwrite`, `--clean-output`, and `--detect-key`.

### Changed

- The GUI now uses larger DPI-aware fonts and responsive column sizing. Its
  main form scrolls vertically on compact displays while the activity log
  keeps an independent scrollbar for lengthy output.

### Fixed

- Encryption now scans plain assets correctly and can auto-detect a project
  key when `--key` is omitted.
- Keyless GUI decryptions restore PNG files instead of writing encrypted
  payload bytes.

## [0.2.2] - 2026-07-26

### Changed

- Enlarged all GUI fonts slightly while preserving DPI-aware scaling.
- Made folder fields, headings, mode controls, progress text, and status rows
  responsive without imposing a fixed-width layout.

### Fixed

- The main form now scrolls vertically on small windowed displays, keeping the
  Activity Log reachable; fixed-width rows no longer force a horizontal
  scrollbar.

## [0.2.1] - 2026-07-24

### Fixed

- **Folder picker now opens the modern Windows Explorer dialog.**
  `IID_IFileOpenDialog` in `src/win32_folder_dialog.zig` was declared with a
  wrong final byte (`...D96E` — a value circulating in older docs and code
  samples — instead of the correct `...D960`). `QueryInterface` therefore
  returned `E_NOINTERFACE` and the app silently fell back to the legacy
  `SHBrowseForFolder` tree dialog on every machine. Verified against the
  system `shobjidl.h` and with a standalone COM probe.
- **Cancel no longer double-prompts.** Pressing Cancel in the modern dialog
  previously fell through to the legacy `SHBrowseForFolder` dialog, popping a
  second picker on top of the first. Cancellation is now reported as a
  distinct `error.Canceled` and stops the picker chain; the legacy dialog is
  only used when the modern COM class is genuinely unavailable.

### Changed

- `CoCreateInstance` / `GetResult` out-parameters in the folder picker now use
  the proven `*?*anyopaque` + null-initialized pattern instead of
  `**anyopaque` + `undefined`.
- Corrected misleading comments in `src/win32_folder_dialog.zig`: the
  documented `CLSID_FileOpenDialog` was right all along; the earlier claim
  that comdlg32.dll does not implement `IFileOpenDialog` on this install was
  wrong.

## [0.2.0] - 2026-07

### Added

- Native GUI (`rmdecrypt-gui`) built on Nuklear with a C shim, replacing the
  previous DVUI-based interface.
- Catppuccin-inspired dark mode with a light-mode toggle button.
- Larger UI fonts with bold/italic variants and icons.
- Native Windows folder picker (`src/win32_folder_dialog.zig`): modern
  `IFileOpenDialog` with `SHBrowseForFolder` as fallback.
- Drag-and-drop of folders from Explorer onto the window to fill the next
  empty folder field.
- Card-based layout, visual hierarchy, and 16:9 default window size.

## [0.1.0] - 2026-07

### Added

- Initial release: Zig port of the RPG Maker MV/MZ asset decrypter.
- Decrypt/re-encrypt `.rpgmvp`, `.rpgmvm`, `.rpgmvo` to `.png`, `.m4a`, `.ogg`.
- Encryption-key auto-detection from the project's `System.json`.
- CLI (`rmdecrypt`) with batch directory processing.
