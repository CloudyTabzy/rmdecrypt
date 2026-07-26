//! rmdecrypt GUI — Zig logic layer.
//!
//! Following the btworkshop_zig architecture: all Nuklear/Win32 UI code
//! lives in C (`nk_shim.c` window plumbing + `gui_nk.c` widget tree); this
//! file only exports the application logic the C side calls (`rmd_zig_*`)
//! and the process entry points that forward into `rmd_gui_main()`.

const std = @import("std");
const decrypter = @import("decrypter.zig");
const extensions = @import("extensions.zig");
const key_detect = @import("key_detect.zig");
const win32_folder_dialog = @import("win32_folder_dialog");
const Dir = std.Io.Dir;

const LOG_CAP = 1000;

// ─── globals (single UI thread; set up lazily on first export call) ─────

const gpa = std.heap.page_allocator;

var g_threaded: ?*std.Io.Threaded = null;
var g_io: std.Io = undefined;

fn ensureInit() void {
    if (g_threaded != null) return;
    const t = gpa.create(std.Io.Threaded) catch @panic("out of memory");
    t.* = std.Io.Threaded.init(gpa, .{});
    g_threaded = t;
    g_io = t.io();
}

fn io() std.Io {
    ensureInit();
    return g_io;
}

const LogEntry = struct { msg: [:0]const u8, err: bool };

const Job = struct {
    files: std.ArrayList([]const u8) = .empty,
    idx: usize = 0,
    done: usize = 0,
    errors: usize = 0,
    total: usize = 0,
    input: []u8 = &.{},
    output: []u8 = &.{},
    key: []u8 = &.{}, // raw key bytes (empty = no key)
    decrypt: bool = true,
    mz: bool = false,
    ignore_header: bool = false,
    overwrite: bool = false,
    clean_output: bool = false,
    header: [decrypter.DEFAULT_HEADER.len]u8 = decrypter.DEFAULT_HEADER,

    fn reset(self: *Job) void {
        for (self.files.items) |f| gpa.free(f);
        self.files.clearRetainingCapacity();
        self.idx = 0;
        self.done = 0;
        self.errors = 0;
        self.total = 0;
        gpa.free(self.input);
        gpa.free(self.output);
        gpa.free(self.key);
        self.input = &.{};
        self.output = &.{};
        self.key = &.{};
    }
};

var g_job: Job = .{};
var g_log: std.ArrayList(LogEntry) = .empty;

// ─── log ────────────────────────────────────────────────────────────────

fn logFmt(comptime fmt: []const u8, args: anytype, err: bool) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(msg);
    logSlice(msg, err);
}

fn logSlice(msg: []const u8, err: bool) void {
    if (g_log.items.len >= LOG_CAP) {
        const old = g_log.orderedRemove(0);
        gpa.free(old.msg);
    }
    const z = gpa.allocSentinel(u8, msg.len, 0) catch return;
    @memcpy(z[0..msg.len], msg);
    g_log.append(gpa, .{ .msg = z, .err = err }) catch {};
}

// ─── file processing ────────────────────────────────────────────────────

fn processFile(input_dir: Dir, output_dir: Dir, path: []const u8) void {
    const ext_dot = Dir.path.extension(path);
    if (ext_dot.len == 0) return;
    const ext = ext_dot[1..];
    // Per-mode extension gate (encrypt mode must NOT hit the EncryptedExt
    // check — plain .png/.m4a/.ogg inputs would be silently skipped).
    if (g_job.decrypt) {
        if (extensions.EncryptedExt.fromString(ext) == null) return;
    } else {
        if (extensions.NormalExt.fromString(ext) == null) return;
    }

    var in_file = input_dir.openFile(io(), path, .{ .mode = .read_only }) catch {
        logFmt("  x {s}: open error", .{path}, true);
        g_job.errors += 1;
        return;
    };
    defer in_file.close(io());
    const stat = in_file.stat(io()) catch {
        logFmt("  x {s}: stat error", .{path}, true);
        g_job.errors += 1;
        return;
    };
    const data = gpa.alloc(u8, stat.size) catch return;
    defer gpa.free(data);
    var rdr = in_file.reader(io(), &.{});
    rdr.interface.readSliceAll(data) catch {
        logFmt("  x {s}: read error", .{path}, true);
        g_job.errors += 1;
        return;
    };

    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return;
    var pbuf: [2048]u8 = undefined;
    const key = g_job.key;

    if (g_job.decrypt) {
        if (data.len < decrypter.DEFAULT_HEADER.len) {
            logFmt("  x {s}: file is smaller than the RPG Maker header", .{path}, true);
            g_job.errors += 1;
            return;
        }
        if (!g_job.ignore_header and !decrypter.verifyHeaderAgainst(data, g_job.header[0..])) {
            logFmt("  x {s}: invalid RPG Maker header (enable Ignore header to force)", .{path}, true);
            g_job.errors += 1;
            return;
        }
        const enc = extensions.EncryptedExt.fromString(ext).?;
        const out_path = std.fmt.bufPrint(&pbuf, "{s}.{s}", .{ path[0..dot], enc.normalExt() }) catch return;
        if (Dir.path.dirname(out_path)) |d| {
            if (d.len > 0) output_dir.createDirPath(io(), d) catch {};
        }
        var restored: ?[]u8 = null;
        defer if (restored) |bytes| gpa.free(bytes);
        const output_data: []const u8 = if (key.len > 0) blk: {
            const payload = data[decrypter.DEFAULT_HEADER.len..];
            for (0..@min(payload.len, key.len)) |i| payload[i] ^= key[i];
            break :blk payload;
        } else if (enc.isPng()) blk: {
            restored = decrypter.DefaultDecrypter.restorePng(data, gpa) catch {
                logFmt("  x {s}: cannot restore PNG", .{path}, true);
                g_job.errors += 1;
                return;
            };
            break :blk restored.?;
        } else {
            logFmt("  x {s}: no key; audio skipped", .{path}, true);
            g_job.errors += 1;
            return;
        };
        output_dir.writeFile(io(), .{ .sub_path = out_path, .data = output_data, .flags = .{ .exclusive = !g_job.overwrite } }) catch {
            logFmt("  x {s}: write error", .{path}, true);
            g_job.errors += 1;
            return;
        };
        logFmt("  + {s}", .{out_path}, false);
    } else {
        const norm = extensions.NormalExt.fromString(ext) orelse return;
        const out_path = std.fmt.bufPrint(&pbuf, "{s}.{s}", .{ path[0..dot], norm.encryptedExt(g_job.mz) }) catch return;
        if (Dir.path.dirname(out_path)) |d| {
            if (d.len > 0) output_dir.createDirPath(io(), d) catch {};
        }
        for (0..@min(data.len, key.len)) |i|
            data[i] ^= key[i];
        const out_data = std.mem.concat(gpa, u8, &.{ g_job.header[0..], data }) catch return;
        defer gpa.free(out_data);
        output_dir.writeFile(io(), .{ .sub_path = out_path, .data = out_data, .flags = .{ .exclusive = !g_job.overwrite } }) catch {
            logFmt("  x {s}: write error", .{path}, true);
            g_job.errors += 1;
            return;
        };
        logFmt("  + {s}", .{out_path}, false);
    }
}

// ─── exports called from gui_nk.c ───────────────────────────────────────

export fn rmd_zig_is_dir(path: [*:0]const u8) c_int {
    const p = std.mem.sliceTo(path, 0);
    if (p.len == 0) return 0;
    var dir = Dir.cwd().openDir(io(), p, .{ .iterate = true }) catch return 0;
    dir.close(io());
    return 1;
}

export fn rmd_zig_pick_folder(title: [*:0]const u8, out: [*]u8, max: c_int) c_int {
    const t = std.mem.sliceTo(title, 0);
    const p = (win32_folder_dialog.selectFolder(gpa, t) catch null) orelse return 0;
    defer gpa.free(p);
    const n: usize = @intCast(@max(0, max - 1));
    const copy = @min(p.len, n);
    @memcpy(out[0..copy], p[0..copy]);
    out[copy] = 0;
    return @intCast(copy);
}

/// Writes the detected key as a hex string into `out`. Returns its length,
/// or 0 when no key could be found.
export fn rmd_zig_detect_key(input: [*:0]const u8, out: [*]u8, max: c_int) c_int {
    const ip = std.mem.sliceTo(input, 0);
    if (ip.len == 0) return 0;
    var id = Dir.cwd().openDir(io(), ip, .{ .iterate = true, .access_sub_paths = true }) catch {
        logFmt("  x cannot open input folder: {s}", .{ip}, true);
        return 0;
    };
    defer id.close(io());

    const k = (key_detect.detectFromInput(io(), gpa, id) catch null) orelse return 0;
    defer gpa.free(k);

    // detectFromInput yields a hex string (System.json / JS files) or raw
    // key bytes (PNG-derived). Normalize to hex for the UI field.
    var hex_buf: [64]u8 = undefined;
    const hex: []const u8 = if (key_detect.validateKeyHex(k))
        k
    else blk: {
        if (k.len * 2 > hex_buf.len) return 0;
        const charset = "0123456789abcdef";
        for (k, 0..) |b, i| {
            hex_buf[i * 2] = charset[b >> 4];
            hex_buf[i * 2 + 1] = charset[b & 15];
        }
        break :blk hex_buf[0 .. k.len * 2];
    };

    const n: usize = @intCast(@max(0, max - 1));
    const copy = @min(hex.len, n);
    @memcpy(out[0..copy], hex[0..copy]);
    out[copy] = 0;
    logFmt("  + key detected: {s}", .{hex[0..copy]}, false);
    return @intCast(copy);
}

/// Scans `input` for processable files and stores the job. Returns the
/// number of files found, or <= 0 on failure.
export fn rmd_zig_scan(
    input: [*:0]const u8,
    output: [*:0]const u8,
    key_hex: [*:0]const u8,
    header_hex: [*:0]const u8,
    decrypt: c_int,
    mz: c_int,
    ignore_header: c_int,
    overwrite: c_int,
    clean_output: c_int,
) c_int {
    const ip = std.mem.sliceTo(input, 0);
    const op = std.mem.sliceTo(output, 0);
    const kh = std.mem.sliceTo(key_hex, 0);
    const hh = std.mem.sliceTo(header_hex, 0);

    g_job.reset();
    g_log.clearRetainingCapacity();

    // Convert the UI's hex key to raw bytes (empty = no key).
    if (kh.len > 0) {
        if (!key_detect.validateKeyHex(kh)) {
            logFmt("  x invalid key: need an even number of hex chars (got {d})", .{kh.len}, true);
            return -1;
        }
        g_job.key = key_detect.hexKeyToBytes(kh, gpa) catch {
            logFmt("  x invalid key characters", .{}, true);
            return -1;
        };
    }

    var id = Dir.cwd().openDir(io(), ip, .{ .iterate = true, .access_sub_paths = true }) catch {
        logFmt("  x cannot open input folder: {s}", .{ip}, true);
        return -1;
    };
    defer id.close(io());

    g_job.decrypt = decrypt != 0;
    g_job.mz = mz != 0;
    g_job.ignore_header = ignore_header != 0;
    g_job.overwrite = overwrite != 0;
    g_job.clean_output = clean_output != 0;
    if (!key_detect.validateKeyHex(hh)) {
        logFmt("  x fake header must be exactly 32 hexadecimal characters", .{}, true);
        return -1;
    }
    const parsed_header = key_detect.hexKeyToBytes(hh, gpa) catch return -1;
    defer gpa.free(parsed_header);
    @memcpy(g_job.header[0..], parsed_header);
    g_job.input = gpa.dupe(u8, ip) catch return -1;
    g_job.output = gpa.dupe(u8, if (op.len > 0) op else ip) catch return -1;

    if (g_job.clean_output) {
        if (std.mem.eql(u8, g_job.input, g_job.output)) {
            logFmt("  x refusing to clean an output folder that is also the input folder", .{}, true);
            return -1;
        }
        Dir.cwd().deleteTree(io(), g_job.output) catch {
            logFmt("  x could not clean output folder: {s}", .{g_job.output}, true);
            return -1;
        };
    }

    if (g_job.key.len == 0) {
        const detected = key_detect.detectFromInput(io(), gpa, id) catch null;
        if (detected) |found| {
            defer gpa.free(found);
            g_job.key = if (key_detect.validateKeyHex(found))
                key_detect.hexKeyToBytes(found, gpa) catch return -1
            else
                gpa.dupe(u8, found) catch return -1;
            logFmt("  + key auto-detected", .{}, false);
        } else if (!g_job.decrypt) {
            logFmt("  x encryption needs a key; auto-detection failed", .{}, true);
            return -1;
        }
    }

    var walker = id.walk(gpa) catch return -1;
    defer walker.deinit();
    while (true) {
        const entry = walker.next(io()) catch break orelse break;
        if (entry.kind != .file) continue;
        const ed = Dir.path.extension(entry.basename);
        if (ed.len == 0) continue;
        if (g_job.decrypt) {
            if (extensions.EncryptedExt.fromString(ed[1..]) != null)
                g_job.files.append(gpa, gpa.dupe(u8, entry.path) catch continue) catch {};
        } else {
            if (extensions.NormalExt.fromString(ed[1..]) != null)
                g_job.files.append(gpa, gpa.dupe(u8, entry.path) catch continue) catch {};
        }
    }
    g_job.total = g_job.files.items.len;
    if (g_job.total == 0) {
        logFmt("  x no matching files found in that folder", .{}, true);
        return 0;
    }

    Dir.cwd().createDirPath(io(), g_job.output) catch {
        logFmt("  x could not create output folder: {s}", .{g_job.output}, true);
        return -1;
    };
    logFmt("  -> found {d} files", .{g_job.total}, false);
    return @intCast(g_job.total);
}

/// Processes up to `batch` files of the current job (called once per frame
/// while the UI reports "processing").
export fn rmd_zig_step(batch: c_int) void {
    const start = g_job.idx;
    const end = @min(start + @as(usize, @intCast(@max(1, batch))), g_job.files.items.len);
    if (start >= end) return;

    var od = Dir.cwd().openDir(io(), g_job.output, .{}) catch {
        logFmt("  x cannot open output folder: {s}", .{g_job.output}, true);
        g_job.idx = g_job.files.items.len;
        g_job.done = g_job.total;
        return;
    };
    defer od.close(io());
    var id = Dir.cwd().openDir(io(), g_job.input, .{ .iterate = true, .access_sub_paths = true }) catch {
        logFmt("  x cannot open input folder: {s}", .{g_job.input}, true);
        g_job.idx = g_job.files.items.len;
        g_job.done = g_job.total;
        return;
    };
    defer id.close(io());

    for (g_job.files.items[start..end]) |fp| {
        processFile(id, od, fp);
        g_job.done += 1;
    }
    g_job.idx = end;

    if (g_job.done >= g_job.total) {
        if (g_job.errors > 0) {
            logFmt("  done - {d} files, {d} errors", .{ g_job.done, g_job.errors }, true);
        } else {
            logFmt("  done - {d} files processed", .{g_job.done}, false);
        }
    }
}

export fn rmd_zig_progress(done: *c_int, total: *c_int, errors: *c_int) void {
    done.* = @intCast(g_job.done);
    total.* = @intCast(g_job.total);
    errors.* = @intCast(g_job.errors);
}

export fn rmd_zig_log(msg: [*:0]const u8, is_err: c_int) void {
    logSlice(std.mem.sliceTo(msg, 0), is_err != 0);
}

export fn rmd_zig_log_count() c_int {
    return @intCast(g_log.items.len);
}

export fn rmd_zig_log_get(i: c_int, is_err: *c_int) ?[*:0]const u8 {
    if (i < 0 or i >= g_log.items.len) return null;
    const e = g_log.items[@intCast(i)];
    is_err.* = @intFromBool(e.err);
    return e.msg.ptr;
}

export fn rmd_zig_log_clear() void {
    for (g_log.items) |e| gpa.free(e.msg);
    g_log.clearRetainingCapacity();
}

// ─── entry points (UI lives in gui_nk.c) ────────────────────────────────

extern fn rmd_gui_main() c_int;

pub fn main() u8 {
    return @intCast(rmd_gui_main());
}

export fn WinMain(_: ?*anyopaque, _: ?*anyopaque, _: ?[*:0]u8, _: c_int) c_int {
    return rmd_gui_main();
}
