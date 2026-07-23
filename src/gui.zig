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

fn processFile(gpa: std.mem.Allocator, io: std.Io, input_dir: Dir, output_dir: Dir, s: *GuiState, path: []const u8) void {
    const ext_dot = Dir.path.extension(path);
    if (ext_dot.len == 0) return;
    const ext = ext_dot[1..];
    const enc = extensions.EncryptedExt.fromString(ext) orelse return;

    var in_file = input_dir.openFile(io, path, .{ .mode = .read_only }) catch {
        appendLog(gpa, s, "  fail: {s}: open error", .{path}, true);
        return;
    };
    defer in_file.close(io);
    const stat = in_file.stat(io) catch {
        appendLog(gpa, s, "  fail: {s}: stat error", .{path}, true);
        return;
    };
    const data = gpa.alloc(u8, stat.size) catch return;
    defer gpa.free(data);
    var rdr = in_file.reader(io, &.{});
    rdr.interface.readSliceAll(data) catch {
        appendLog(gpa, s, "  fail: {s}: read error", .{path}, true);
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
            appendLog(gpa, s, "  fail: {s}: write error", .{path}, true);
            return;
        };
        appendLog(gpa, s, "  decrypt: {s}", .{out_path}, false);
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
            appendLog(gpa, s, "  fail: {s}: write error", .{path}, true);
            return;
        };
        appendLog(gpa, s, "  encrypt: {s}", .{out_path}, false);
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
        .size = .{ .w = 740, .h = 560 },
        .min_size = .{ .w = 600, .h = 400 },
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

        // --- GUI ---
        {
            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .{ .x = 8, .y = 8 } });
            defer vbox.deinit();

            dvui.label(@src(), "rmdecrypt v{s}", .{VERSION}, .{ .font = .theme(.title) });
            dvui.labelNoFmt(@src(), "Decrypt or re-encrypt RPG Maker MV/MZ assets", .{}, .{});

            // Input folder
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
                defer row.deinit();
                dvui.labelNoFmt(@src(), "Input Folder", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5 });
                const te = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &s.input_list, .allocator = gpa, .limit = TEXT_LIMIT } }, .placeholder = "path/to/game" }, .{ .expand = .horizontal });
                defer te.deinit();
                if (dvui.button(@src(), "Browse", .{}, .{ .min_size_content = .{ .w = 80 } })) {
                    if (dvui.dialogNativeFolderSelect(gpa, .{ .title = "Select game folder" })) |maybe_p| {
                        if (maybe_p) |p| {
                            defer gpa.free(p);
                            s.input_list.clearRetainingCapacity();
                            s.input_list.appendSlice(gpa, p) catch {};
                            if (s.output_list.items.len == 0) {
                                s.output_list.clearRetainingCapacity();
                                s.output_list.appendSlice(gpa, p) catch {};
                                s.output_list.appendSlice(gpa, "_decrypted") catch {};
                            }
                        }
                    } else |_| {}
                }
            }

            // Output folder
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
                defer row.deinit();
                dvui.labelNoFmt(@src(), "Output Folder", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5 });
                const te = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &s.output_list, .allocator = gpa, .limit = TEXT_LIMIT } }, .placeholder = "output directory" }, .{ .expand = .horizontal });
                defer te.deinit();
                if (dvui.button(@src(), "Browse", .{}, .{ .min_size_content = .{ .w = 80 } })) {
                    if (dvui.dialogNativeFolderSelect(gpa, .{ .title = "Select output folder" })) |maybe_p| {
                        if (maybe_p) |p| {
                            defer gpa.free(p);
                            s.output_list.clearRetainingCapacity();
                            s.output_list.appendSlice(gpa, p) catch {};
                        }
                    } else |_| {}
                }
            }

            // Key
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
                defer row.deinit();
                dvui.labelNoFmt(@src(), "Key", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5 });
                const te = dvui.textEntry(@src(), .{ .text = .{ .array_list = .{ .backing = &s.key_list, .allocator = gpa, .limit = TEXT_LIMIT } }, .placeholder = "auto-detect or hex key" }, .{ .expand = .horizontal });
                defer te.deinit();
                if (dvui.button(@src(), "Auto-Detect", .{}, .{ .min_size_content = .{ .w = 100 } })) {
                    const ip = s.input_list.items;
                    if (ip.len > 0) {
                        if (Dir.cwd().openDir(init.io, ip, .{ .iterate = true, .access_sub_paths = true })) |id| {
                            defer id.close(init.io);
                            const detected = key_detect.detectFromInput(init.io, arena_alloc, id) catch null;
                            if (detected) |k| {
                                defer arena_alloc.free(k);
                                s.key_list.clearRetainingCapacity();
                                s.key_list.appendSlice(gpa, k) catch {};
                            } else {
                                dvui.dialog(@src(), .{}, .{ .title = "Key Not Found", .message = "Could not find an encryption key in that folder.", .modal = true, .ok_label = "OK" });
                            }
                        } else |_| {}
                    }
                }
            }

            // Mode
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 6 } });
                defer row.deinit();
                dvui.labelNoFmt(@src(), "Mode", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5 });
                _ = dvui.checkbox(@src(), &s.mode_decrypt, "Decrypt", .{});
                dvui.labelNoFmt(@src(), "  ", .{}, .{});
                var enc_val = !s.mode_decrypt;
                if (dvui.checkbox(@src(), &enc_val, "Encrypt", .{}))
                    s.mode_decrypt = !enc_val;
                dvui.labelNoFmt(@src(), "     ", .{}, .{});
                _ = dvui.checkbox(@src(), &s.mz, "MZ extensions", .{});
            }

            // Start button
            const can_start = s.input_list.items.len > 0 and s.status != .processing and s.status != .scanning;
            if (dvui.button(@src(), if (s.status == .idle or s.status == .done) "  Start Processing  " else "  Processing...  ", .{ .grayed = !can_start }, .{ .expand = .horizontal, .min_size_content = .{ .h = 34 } })) {
                if (can_start) {
                    const ip = s.input_list.items;
                    if (Dir.cwd().openDir(init.io, ip, .{ .iterate = true, .access_sub_paths = true })) |id| {
                        defer id.close(init.io);
                        s.status = .scanning;
                        // Collect files
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
                            dvui.dialog(@src(), .{}, .{ .title = "No Files", .message = "No matching files found in that folder.", .modal = true, .ok_label = "OK" });
                            s.status = .idle;
                        } else {
                            // Pre-create output dir
                            if (s.output_list.items.len > 0)
                                Dir.cwd().createDirPath(init.io, s.output_list.items) catch {};
                            s.status = .processing;
                        }
                    } else |_| {}
                }
            }

            // Progress
            if (s.status == .processing or s.status == .done) {
                const pct = if (s.total > 0) @as(f32, @floatFromInt(s.done_count)) / @as(f32, @floatFromInt(s.total)) else 0.0;
                dvui.progress(@src(), .{ .percent = pct }, .{ .expand = .horizontal, .min_size_content = .{ .h = 20 } });
                dvui.label(@src(), "{d} / {d} files  ({d} errors)", .{ s.done_count, s.total, s.err_count }, .{});
            }

            // Log
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .h = 150 } });
            defer scroll.deinit();
            for (s.log.items) |entry| {
                dvui.labelNoFmt(@src(), entry.msg, .{}, .{ .expand = .horizontal, .color_text = if (entry.err) dvui.Color.red else dvui.Color.green });
            }
            if (s.status == .done) {
                if (s.err_count > 0)
                    dvui.label(@src(), "Done — {d} files, {d} errors", .{ s.done_count, s.err_count }, .{ .color_text = dvui.Color.yellow })
                else
                    dvui.label(@src(), "Done — {d} files", .{s.done_count}, .{ .color_text = dvui.Color.green });
            }
        }

        // --- Per-frame batch processing ---
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
