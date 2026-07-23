const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDL2Backend = @import("sdl2-backend");
const decrypter = @import("decrypter.zig");
const extensions = @import("extensions.zig");
const key_detect = @import("key_detect.zig");
const Dir = std.Io.Dir;

const VERSION = "0.1.0";
const BATCH_SIZE = 15;
const TEXT_LIMIT = 1024;

const Status = enum { idle, scanning, processing, done };

const LogEntry = struct { msg: []const u8, err: bool };

const GuiState = struct {
    input_list: std.ArrayList(u8) = .empty,
    output_list: std.ArrayList(u8) = .empty,
    key_list: std.ArrayList(u8) = .empty,
    mode_decrypt: bool = true,
    mz: bool = false,
    status: Status = .idle,
    files: std.ArrayList([]const u8) = .empty,
    idx: usize = 0,
    done_count: usize = 0,
    err_count: usize = 0,
    total: usize = 0,
    log: std.ArrayList(LogEntry) = .empty,
};

fn appendLog(gpa: std.mem.Allocator, s: *GuiState, comptime fmt: []const u8, args: anytype, err: bool) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    s.log.append(gpa, LogEntry{ .msg = msg, .err = err }) catch {};
}

/// Card-style section with subtle border, rounded corners, and a header.
/// Use via: `var c = card(@src(), "Title"); defer c.deinit(); ...content...`
const Card = struct {
    box: *dvui.BoxWidget,

    pub fn init(src: std.builtin.SourceLocation, title: []const u8) Card {
        // Outer box: rounded, subtle border, subtle fill (window style), small margin.
        const card_opts: dvui.Options = .{
            .style = .window,
            .background = true,
            .border = dvui.Rect.all(1),
            .corners = dvui.CornerRect.all(8),
            .padding = dvui.Rect.all(14),
            .margin = .{ .y = 6 },
            .expand = .horizontal,
        };
        const box = dvui.box(src, .{ .dir = .vertical }, card_opts);
        if (title.len > 0) {
            dvui.labelNoFmt(src, title, .{}, .{
                .font = dvui.Font.theme(.heading),
                .margin = .{ .x = 0, .y = 0, .w = 0, .h = 8 },
            });
        }
        return .{ .box = box };
    }

    pub fn deinit(self: *Card) void {
        self.box.deinit();
    }
};

/// Path row: [icon] [label] [text entry ──────────] [Browse button]
/// `base_id` must be unique per call to this function (caller's responsibility),
/// and each sibling within this row uses `base_id * 10 + i`.
fn pathRow(
    src: std.builtin.SourceLocation,
    base_id: usize,
    icon_tvg: []const u8,
    label_str: []const u8,
    text_buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    dialog_title: []const u8,
    auto_fill_output: bool,
    state: *GuiState,
    is_output: bool,
) void {
    const row_id = base_id * 10;
    var row = dvui.box(src, .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 }, .id_extra = row_id });
    defer row.deinit();

    // Icon
    dvui.icon(src, label_str, icon_tvg, .{}, .{
        .min_size_content = .{ .h = 18, .w = 18 },
        .gravity_y = 0.5,
        .margin = .{ .w = 8 },
        .id_extra = row_id + 1,
    });
    // Label
    dvui.labelNoFmt(src, label_str, .{}, .{
        .min_size_content = .{ .w = 110 },
        .gravity_y = 0.5,
        .font = dvui.Font.theme(.heading),
        .id_extra = row_id + 2,
    });
    // Text entry
    {
        const te = dvui.textEntry(src, .{
            .text = .{ .array_list = .{ .backing = text_buf, .allocator = gpa, .limit = TEXT_LIMIT } },
            .placeholder = if (is_output) "output directory" else "path/to/game",
        }, .{ .expand = .horizontal, .id_extra = row_id + 3 });
        te.deinit();
    }
    _ = dvui.spacer(src, .{ .min_size_content = .width(6), .id_extra = row_id + 4 });
    // Browse button (outside the text entry!)
    if (dvui.button(src, "Browse", .{}, .{
        .min_size_content = .{ .w = 90, .h = 28 },
        .style = .control,
        .id_extra = row_id + 5,
    })) {
        if (dvui.dialogNativeFolderSelect(gpa, .{ .title = dialog_title })) |maybe_p| {
            if (maybe_p) |p| {
                defer gpa.free(p);
                text_buf.clearRetainingCapacity();
                text_buf.appendSlice(gpa, p) catch {};
                if (auto_fill_output and !is_output) {
                    // Mirror into output if empty
                    if (state.output_list.items.len == 0) {
                        state.output_list.clearRetainingCapacity();
                        state.output_list.appendSlice(gpa, p) catch {};
                        state.output_list.appendSlice(gpa, "_decrypted") catch {};
                    }
                }
            }
        } else |_| {}
    }
}

fn processFile(gpa: std.mem.Allocator, io: std.Io, input_dir: Dir, output_dir: Dir, s: *GuiState, path: []const u8) void {
    const ext_dot = Dir.path.extension(path);
    if (ext_dot.len == 0) return;
    const ext = ext_dot[1..];
    const enc = extensions.EncryptedExt.fromString(ext) orelse return;

    var in_file = input_dir.openFile(io, path, .{ .mode = .read_only }) catch {
        appendLog(gpa, s, "  ✗ {s}: open error", .{path}, true);
        return;
    };
    defer in_file.close(io);
    const stat = in_file.stat(io) catch {
        appendLog(gpa, s, "  ✗ {s}: stat error", .{path}, true);
        return;
    };
    const data = gpa.alloc(u8, stat.size) catch return;
    defer gpa.free(data);
    var rdr = in_file.reader(io, &.{});
    rdr.interface.readSliceAll(data) catch {
        appendLog(gpa, s, "  ✗ {s}: read error", .{path}, true);
        return;
    };

    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return;
    var pbuf: [2048]u8 = undefined;

    if (s.mode_decrypt) {
        const out_path = std.fmt.bufPrint(&pbuf, "{s}.{s}", .{ path[0..dot], enc.normalExt() }) catch return;
        const parent = Dir.path.dirname(out_path);
        if (parent) |d| {
            if (d.len > 0) output_dir.createDirPath(io, d) catch {};
        }
        const payload = data[decrypter.DEFAULT_HEADER.len..];
        for (0..@min(payload.len, s.key_list.items.len)) |i|
            payload[i] ^= s.key_list.items[i];
        output_dir.writeFile(io, .{ .sub_path = out_path, .data = payload }) catch {
            appendLog(gpa, s, "  ✗ {s}: write error", .{path}, true);
            return;
        };
        appendLog(gpa, s, "  ✓ {s}", .{out_path}, false);
    } else {
        const norm = extensions.NormalExt.fromString(ext) orelse return;
        const enc_ext_str = norm.encryptedExt(s.mz);
        const out_path = std.fmt.bufPrint(&pbuf, "{s}.{s}", .{ path[0..dot], enc_ext_str }) catch return;
        const parent = Dir.path.dirname(out_path);
        if (parent) |d| {
            if (d.len > 0) output_dir.createDirPath(io, d) catch {};
        }
        for (0..@min(data.len, s.key_list.items.len)) |i|
            data[i] ^= s.key_list.items[i];
        const out_data = std.mem.concat(gpa, u8, &.{ decrypter.DEFAULT_HEADER[0..], data }) catch return;
        defer gpa.free(out_data);
        output_dir.writeFile(io, .{ .sub_path = out_path, .data = out_data }) catch {
            appendLog(gpa, s, "  ✗ {s}: write error", .{path}, true);
            return;
        };
        appendLog(gpa, s, "  ✓ {s}", .{out_path}, false);
    }
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows)
        dvui.Backend.Common.windowsAttachConsole() catch {};
    SDL2Backend.enableSDLLogging();

    const gpa = init.gpa;
    const arena = init.arena;
    const arena_alloc = arena.allocator();

    var backend = try SDL2Backend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 820, .h = 680 },
        .min_size = .{ .w = 680, .h = 520 },
        .vsync = true,
        .title = "rmdecrypt v" ++ VERSION ++ " — RPG Maker MV/MZ Asset Tool",
    });
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var s: GuiState = .{};
    defer {
        s.input_list.deinit(gpa);
        s.output_list.deinit(gpa);
        s.key_list.deinit(gpa);
        s.files.deinit(gpa);
        s.log.deinit(gpa);
    }

    var interrupted = false;
    while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        try backend.addAllEvents(&win);

        // ── Root vertical layout ──────────────────────────────────────────────
        {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .{ .x = 14, .y = 14 } });
            defer vbox.deinit();

            // ── Header (icon + title + subtitle) ─────────────────────────────
            {
                var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .h = 8 } });
                defer hrow.deinit();

                dvui.icon(@src(), "app_logo", dvui.entypo.lock, .{}, .{
                    .min_size_content = .{ .h = 32, .w = 32 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = 10 },
                    .color_text = dvui.Color{ .r = 0x35, .g = 0x84, .b = 0xe4 },
                });
                {
                    var vcol = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5 });
                    defer vcol.deinit();
                    dvui.label(@src(), "rmdecrypt v{s}", .{VERSION}, .{
                        .font = dvui.Font.theme(.title),
                    });
                    dvui.labelNoFmt(@src(), "Decrypt or re-encrypt RPG Maker MV/MZ assets", .{}, .{ .font = dvui.Font.theme(.body) });
                }
            }

            // ── Folders card ─────────────────────────────────────────────────
            {
                var c = Card.init(@src(), "Folders");
                defer c.deinit();
                pathRow(@src(), 1, dvui.entypo.folder, "Input Folder", &s.input_list, gpa, "Select game folder", true, &s, false);
                pathRow(@src(), 2, dvui.entypo.archive, "Output Folder", &s.output_list, gpa, "Select output folder", false, &s, true);
            }

            // ── Encryption key card ─────────────────────────────────────────
            {
                var c = Card.init(@src(), "Encryption Key");
                defer c.deinit();

                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 }, .id_extra = 10 });
                defer row.deinit();

                dvui.icon(@src(), "key_icon", dvui.entypo.key, .{}, .{
                    .min_size_content = .{ .h = 18, .w = 18 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = 8 },
                    .id_extra = 10,
                });
                dvui.labelNoFmt(@src(), "Key", .{}, .{
                    .min_size_content = .{ .w = 110 },
                    .gravity_y = 0.5,
                    .font = dvui.Font.theme(.heading),
                    .id_extra = 10,
                });
                {
                    const te = dvui.textEntry(@src(), .{
                        .text = .{ .array_list = .{ .backing = &s.key_list, .allocator = gpa, .limit = TEXT_LIMIT } },
                        .placeholder = "auto-detect or 32-char hex key",
                    }, .{ .expand = .horizontal, .id_extra = 10 });
                    te.deinit();
                }
                _ = dvui.spacer(@src(), .{ .min_size_content = .width(6), .id_extra = 10 });
                if (dvui.button(@src(), "Auto-Detect", .{}, .{
                    .min_size_content = .{ .w = 120, .h = 28 },
                    .style = .control,
                    .id_extra = 10,
                })) {
                    const ip = s.input_list.items;
                    if (ip.len > 0) {
                        if (Dir.cwd().openDir(init.io, ip, .{ .iterate = true, .access_sub_paths = true })) |id| {
                            defer id.close(init.io);
                            const detected = key_detect.detectFromInput(init.io, arena_alloc, id) catch null;
                            if (detected) |k| {
                                defer arena_alloc.free(k);
                                s.key_list.clearRetainingCapacity();
                                s.key_list.appendSlice(gpa, k) catch {};
                                appendLog(gpa, &s, "  ✓ Key detected: {s}", .{k}, false);
                            } else {
                                dvui.dialog(@src(), .{}, .{
                                    .title = "Key Not Found",
                                    .message = "Could not find an encryption key in that folder. PNG files will still be restored without a key, but audio files cannot be processed.",
                                    .modal = true,
                                    .ok_label = "OK",
                                });
                            }
                        } else |_| {}
                    }
                }

                // ── Key status line ────────────────────────────────────────
                {
                    var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .expand = .horizontal,
                        .margin = .{ .y = 4 },
                    });
                    defer srow.deinit();
                    _ = dvui.spacer(@src(), .{ .min_size_content = .width(26) });

                    if (s.key_list.items.len == 16) {
                        dvui.icon(@src(), "ok", dvui.entypo.check, .{}, .{
                            .min_size_content = .{ .h = 14, .w = 14 },
                            .gravity_y = 0.5,
                            .margin = .{ .w = 4 },
                            .color_text = dvui.Color{ .r = 0x33, .g = 0xd1, .b = 0x7a },
                        });
                        dvui.labelNoFmt(@src(), "Key ready (16 bytes)", .{}, .{
                            .color_text = dvui.Color{ .r = 0x33, .g = 0xd1, .b = 0x7a },
                            .gravity_y = 0.5,
                            .margin = .{ .x = 4 },
                        });
                    } else if (s.key_list.items.len > 0) {
                        dvui.icon(@src(), "warn", dvui.entypo.warning, .{}, .{
                            .min_size_content = .{ .h = 14, .w = 14 },
                            .gravity_y = 0.5,
                            .margin = .{ .w = 4 },
                            .color_text = dvui.Color{ .r = 0xff, .g = 0xc1, .b = 0x07 },
                        });
                        dvui.label(@src(), "Invalid key length ({d} bytes — need 16)", .{s.key_list.items.len}, .{
                            .color_text = dvui.Color{ .r = 0xff, .g = 0xc1, .b = 0x07 },
                            .gravity_y = 0.5,
                            .margin = .{ .x = 4 },
                        });
                    } else {
                        dvui.icon(@src(), "info", dvui.entypo.info, .{}, .{
                            .min_size_content = .{ .h = 14, .w = 14 },
                            .gravity_y = 0.5,
                            .margin = .{ .w = 4 },
                            .color_text = dvui.Color{ .r = 0x90, .g = 0x90, .b = 0x90 },
                        });
                        dvui.labelNoFmt(@src(), "No key set — PNG files will be restored without decryption", .{}, .{
                            .color_text = dvui.Color{ .r = 0x90, .g = 0x90, .b = 0x90 },
                            .gravity_y = 0.5,
                            .margin = .{ .x = 4 },
                        });
                    }
                }
            }

            // ── Options card ─────────────────────────────────────────────────
            {
                var c = Card.init(@src(), "Options");
                defer c.deinit();

                var row1 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 2 }, .id_extra = 20 });
                defer row1.deinit();
                dvui.icon(@src(), "mode", dvui.entypo.cog, .{}, .{
                    .min_size_content = .{ .h = 18, .w = 18 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = 8 },
                    .id_extra = 20,
                });
                dvui.labelNoFmt(@src(), "Mode", .{}, .{
                    .min_size_content = .{ .w = 110 },
                    .gravity_y = 0.5,
                    .font = dvui.Font.theme(.heading),
                    .id_extra = 20,
                });

                // Decrypt chip
                if (dvui.button(
                    @src(),
                    if (s.mode_decrypt) "  ✓ Decrypt  " else "    Decrypt  ",
                    .{},
                    .{
                        .style = if (s.mode_decrypt) .highlight else .control,
                        .min_size_content = .{ .h = 28 },
                        .margin = .{ .w = 4 },
                        .id_extra = 21,
                    },
                )) s.mode_decrypt = true;
                // Encrypt chip
                if (dvui.button(
                    @src(),
                    if (!s.mode_decrypt) "  ✓ Encrypt  " else "    Encrypt  ",
                    .{},
                    .{
                        .style = if (!s.mode_decrypt) .highlight else .control,
                        .min_size_content = .{ .h = 28 },
                        .margin = .{ .w = 4 },
                        .id_extra = 22,
                    },
                )) s.mode_decrypt = false;

                _ = dvui.spacer(@src(), .{ .min_size_content = .width(20), .id_extra = 20 });
                dvui.labelNoFmt(@src(), "Format:", .{}, .{
                    .gravity_y = 0.5,
                    .margin = .{ .w = 8 },
                    .id_extra = 20,
                });
                if (dvui.button(@src(), if (!s.mz) "  ✓ MV  " else "    MV  ", .{}, .{
                    .style = if (!s.mz) .highlight else .control,
                    .min_size_content = .{ .h = 28 },
                    .margin = .{ .w = 4 },
                    .id_extra = 23,
                })) s.mz = false;
                if (dvui.button(@src(), if (s.mz) "  ✓ MZ  " else "    MZ  ", .{}, .{
                    .style = if (s.mz) .highlight else .control,
                    .min_size_content = .{ .h = 28 },
                    .margin = .{ .w = 4 },
                    .id_extra = 24,
                })) s.mz = true;

                // Hint
                {
                    var hrow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 6 }, .id_extra = 25 });
                    defer hrow.deinit();
                    _ = dvui.spacer(@src(), .{ .min_size_content = .width(26), .id_extra = 25 });
                    const hint = if (s.mode_decrypt)
                        (if (s.mz) "Will decrypt .png_ .m4a_ .ogg_ → .png .m4a .ogg" else "Will decrypt .rpgmvp .rpgmvm .rpgmvo → .png .m4a .ogg")
                    else
                        (if (s.mz) "Will encrypt .png .m4a .ogg → .png_ .m4a_ .ogg_" else "Will encrypt .png .m4a .ogg → .rpgmvp .rpgmvm .rpgmvo");
                    dvui.icon(@src(), "info2", dvui.entypo.info, .{}, .{
                        .min_size_content = .{ .h = 12, .w = 12 },
                        .gravity_y = 0.5,
                        .margin = .{ .w = 4 },
                        .color_text = dvui.Color{ .r = 0x90, .g = 0x90, .b = 0x90 },
                        .id_extra = 25,
                    });
                    dvui.labelNoFmt(@src(), hint, .{}, .{
                        .color_text = dvui.Color{ .r = 0x90, .g = 0x90, .b = 0x90 },
                        .gravity_y = 0.5,
                        .margin = .{ .x = 4 },
                        .id_extra = 25,
                    });
                }
            }

            // ── Action button ────────────────────────────────────────────────
            {
                const can_start = s.input_list.items.len > 0 and s.status != .processing and s.status != .scanning;
                const label = switch (s.status) {
                    .idle, .done => if (s.mode_decrypt) "  ⬇  Start Decryption  " else "  ⬆  Start Encryption  ",
                    .scanning => "  ⏳ Scanning…  ",
                    .processing => "  ⚙  Processing…  ",
                };
                if (dvui.button(@src(), label, .{ .grayed = !can_start }, .{
                    .style = if (can_start) .highlight else .control,
                    .expand = .horizontal,
                    .min_size_content = .{ .h = 42 },
                    .font = dvui.Font.theme(.heading),
                    .margin = .{ .y = 8 },
                    .corners = dvui.CornerRect.all(8),
                })) {
                    if (can_start) {
                        const ip = s.input_list.items;
                        if (Dir.cwd().openDir(init.io, ip, .{ .iterate = true, .access_sub_paths = true })) |id| {
                            defer id.close(init.io);
                            s.status = .scanning;
                            s.files.clearRetainingCapacity();
                            s.log.clearRetainingCapacity();
                            s.idx = 0;
                            s.done_count = 0;
                            s.err_count = 0;
                            s.total = 0;
                            var walker = id.walk(gpa) catch {
                                s.status = .idle;
                                return;
                            };
                            defer walker.deinit();
                            while (true) {
                                const entry = walker.next(init.io) catch break orelse break;
                                if (entry.kind != .file) continue;
                                const ed = Dir.path.extension(entry.basename);
                                if (ed.len == 0) continue;
                                if (s.mode_decrypt) {
                                    if (extensions.EncryptedExt.fromString(ed[1..]) != null)
                                        s.files.append(gpa, gpa.dupe(u8, entry.path) catch continue) catch {};
                                } else {
                                    if (extensions.NormalExt.fromString(ed[1..]) != null)
                                        s.files.append(gpa, gpa.dupe(u8, entry.path) catch continue) catch {};
                                }
                            }
                            s.total = s.files.items.len;
                            if (s.total == 0) {
                                dvui.dialog(@src(), .{}, .{
                                    .title = "No Files",
                                    .message = "No matching files found in that folder.",
                                    .modal = true,
                                    .ok_label = "OK",
                                });
                                s.status = .idle;
                            } else {
                                if (s.output_list.items.len > 0)
                                    Dir.cwd().createDirPath(init.io, s.output_list.items) catch {};
                                appendLog(gpa, &s, "  → Found {d} files", .{s.total}, false);
                                s.status = .processing;
                            }
                        } else |_| {}
                    }
                }
            }

            // ── Progress card ────────────────────────────────────────────────
            if (s.status == .processing or s.status == .done) {
                var c = Card.init(@src(), "Progress");
                defer c.deinit();

                const pct = if (s.total > 0) @as(f32, @floatFromInt(s.done_count)) / @as(f32, @floatFromInt(s.total)) else 0.0;
                dvui.progress(@src(), .{ .percent = pct }, .{
                    .expand = .horizontal,
                    .min_size_content = .{ .h = 18 },
                    .corners = dvui.CornerRect.all(4),
                });

                var srow = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 6 } });
                defer srow.deinit();

                // Stat: processed
                dvui.icon(@src(), "ok2", dvui.entypo.check, .{}, .{
                    .min_size_content = .{ .h = 14, .w = 14 },
                    .gravity_y = 0.5,
                    .margin = .{ .w = 4 },
                    .color_text = dvui.Color{ .r = 0x33, .g = 0xd1, .b = 0x7a },
                });
                dvui.label(@src(), "{d} / {d}", .{ s.done_count, s.total }, .{ .gravity_y = 0.5, .margin = .{ .x = 4 } });
                if (s.err_count > 0) {
                    _ = dvui.spacer(@src(), .{ .min_size_content = .width(20) });
                    dvui.icon(@src(), "err", dvui.entypo.circle_with_cross, .{}, .{
                        .min_size_content = .{ .h = 14, .w = 14 },
                        .gravity_y = 0.5,
                        .margin = .{ .w = 4 },
                        .color_text = dvui.Color{ .r = 0xff, .g = 0x6b, .b = 0x6b },
                    });
                    dvui.label(@src(), "{d} errors", .{s.err_count}, .{
                        .gravity_y = 0.5,
                        .color_text = dvui.Color{ .r = 0xff, .g = 0x6b, .b = 0x6b },
                        .margin = .{ .x = 4 },
                    });
                }
                _ = dvui.spacer(@src(), .{ .expand = .horizontal });
                dvui.label(@src(), "{d:.0}%", .{pct * 100.0}, .{ .gravity_y = 0.5 });
            }

            // ── Activity log card ────────────────────────────────────────────
            {
                var c = Card.init(@src(), "Activity Log");
                defer c.deinit();

                var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .h = 140 } });
                defer scroll.deinit();

                if (s.log.items.len == 0 and s.status == .idle) {
                    dvui.labelNoFmt(@src(), "  No activity yet. Pick a folder and press Start.", .{}, .{
                        .color_text = dvui.Color{ .r = 0x80, .g = 0x80, .b = 0x80 },
                        .margin = .{ .y = 4 },
                    });
                } else {
                    for (s.log.items) |entry| {
                        dvui.labelNoFmt(@src(), entry.msg, .{}, .{
                            .expand = .horizontal,
                            .font = dvui.Font.theme(.mono),
                            .color_text = if (entry.err) dvui.Color{ .r = 0xff, .g = 0x6b, .b = 0x6b } else dvui.Color{ .r = 0x80, .g = 0xc0, .b = 0x80 },
                        });
                    }
                }

                if (s.status == .done) {
                    _ = dvui.spacer(@src(), .{ .min_size_content = .height(6) });
                    if (s.err_count > 0) {
                        dvui.icon(@src(), "warn2", dvui.entypo.warning, .{}, .{
                            .min_size_content = .{ .h = 16, .w = 16 },
                            .gravity_y = 0.5,
                            .margin = .{ .w = 4 },
                            .color_text = dvui.Color{ .r = 0xff, .g = 0xc1, .b = 0x07 },
                        });
                        dvui.label(@src(), "Done — {d} files, {d} errors", .{ s.done_count, s.err_count }, .{
                            .color_text = dvui.Color{ .r = 0xff, .g = 0xc1, .b = 0x07 },
                            .font = dvui.Font.theme(.heading),
                            .gravity_y = 0.5,
                            .margin = .{ .x = 4 },
                        });
                    } else {
                        dvui.icon(@src(), "ok3", dvui.entypo.check, .{}, .{
                            .min_size_content = .{ .h = 16, .w = 16 },
                            .gravity_y = 0.5,
                            .margin = .{ .w = 4 },
                            .color_text = dvui.Color{ .r = 0x33, .g = 0xd1, .b = 0x7a },
                        });
                        dvui.label(@src(), "Done — {d} files processed", .{s.done_count}, .{
                            .color_text = dvui.Color{ .r = 0x33, .g = 0xd1, .b = 0x7a },
                            .font = dvui.Font.theme(.heading),
                            .gravity_y = 0.5,
                            .margin = .{ .x = 4 },
                        });
                    }
                }
            }

            // ── Footer ────────────────────────────────────────────────────────
            _ = dvui.spacer(@src(), .{ .min_size_content = .height(2) });
            var fbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer fbox.deinit();
            _ = dvui.spacer(@src(), .{ .expand = .horizontal });
            dvui.labelNoFmt(@src(), "rmdecrypt v" ++ VERSION ++ "  ·  RPG Maker MV/MZ decrypter", .{}, .{
                .color_text = dvui.Color{ .r = 0x70, .g = 0x70, .b = 0x70 },
                .font = dvui.Font.theme(.body),
            });
        }

        // ── Per-frame batch processing ─────────────────────────────────────
        if (s.status == .processing) {
            const start = s.idx;
            const end = @min(start + BATCH_SIZE, s.files.items.len);
            if (start < end and s.output_list.items.len > 0) {
                const out_path = s.output_list.items;
                if (Dir.cwd().openDir(init.io, out_path, .{})) |od| {
                    defer od.close(init.io);
                    const inp = s.input_list.items;
                    if (Dir.cwd().openDir(init.io, inp, .{ .iterate = true, .access_sub_paths = true })) |id| {
                        defer id.close(init.io);
                        for (s.files.items[start..end]) |fp| {
                            processFile(gpa, init.io, id, od, &s, fp);
                            s.done_count += 1;
                        }
                    } else |_| break;
                } else |_| break;
                s.idx = end;
            }
            if (s.done_count >= s.total)
                s.status = .done;
        }

        const end_micros = try win.end(.{});
        const wait_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_micros);
    }
}
