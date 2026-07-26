# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-07-26

### Changed

- Enlarged all GUI fonts slightly while preserving DPI-aware scaling.
- Made folder fields, headings, mode controls, progress text, and status rows
  responsive; wide path fields are now capped instead of stretching across
  the entire window.

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
