//! rmdecrypt GUI — Zig logic layer.
//!
//! C-UI / Zig-logic architecture: all Nuklear/Win32 UI code
//! lives in C (`nk_shim.c` window plumbing + `gui_nk.c` widget tree); this
//! file only exports the application logic the C side calls (`rmd_zig_*`)
//! and the process entry points that forward into `rmd_gui_main()`.
//!
//! Threading: every export runs on the UI thread. A started job processes
//! files on `processor.Job` worker threads, which publish per-file results
//! lock-free; `rmd_zig_step` drains them into the log on the UI thread, so
//! the log and all other globals stay single-threaded.

const std = @import("std");
const decrypter = @import("decrypter.zig");
const key_detect = @import("key_detect.zig");
const processor = @import("processor.zig");
const win32_folder_dialog = @import("win32_folder_dialog");
const Dir = std.Io.Dir;

/// Thread-safe: worker threads allocate their read buffers from it.
const gpa = std.heap.smp_allocator;

var g_threaded: std.Io.Threaded = undefined;
var g_threaded_ready = false;

fn io() std.Io {
    if (!g_threaded_ready) {
        g_threaded = .init(gpa, .{});
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

// ─── log (fixed-capacity ring; oldest entries are evicted) ─────────────────

const LogEntry = struct { msg: [:0]const u8, err: bool };

const Log = struct {
    const cap = 2000;
    entries: [cap]LogEntry = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(l: *Log, msg: []const u8, err: bool) void {
        const z = gpa.dupeZ(u8, msg) catch return;
        if (l.len == cap) {
            gpa.free(l.entries[l.head].msg);
            l.entries[l.head] = .{ .msg = z, .err = err };
            l.head = (l.head + 1) % cap;
        } else {
            l.entries[(l.head + l.len) % cap] = .{ .msg = z, .err = err };
            l.len += 1;
        }
    }

    fn get(l: *const Log, i: usize) LogEntry {
        return l.entries[(l.head + i) % cap];
    }

    fn clear(l: *Log) void {
        for (0..l.len) |i| gpa.free(l.get(i).msg);
        l.* = .{};
    }
};

var g_log: Log = .{};

fn logFmt(comptime fmt: []const u8, args: anytype, err: bool) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        buf[buf.len - 3 ..].* = "...".*;
        break :blk &buf;
    };
    g_log.push(msg, err);
}

// ─── job state ─────────────────────────────────────────────────────────────

const State = struct {
    arena: std.heap.ArenaAllocator = .init(gpa),
    files: []const []const u8 = &.{},
    in_dir: ?Dir = null,
    out_dir: ?Dir = null,
    opts: processor.Options = .{},
    job: ?*processor.Job = null,
    /// Results already moved into the log (what the progress bar shows).
    drained: usize = 0,
    errors: usize = 0,

    fn reset(s: *State) void {
        if (s.job) |job| {
            job.deinit(); // joins the workers
            gpa.destroy(job);
        }
        if (s.in_dir) |d| d.close(io());
        if (s.out_dir) |d| d.close(io());
        s.arena.deinit();
        s.* = .{};
    }
};

var g: State = .{};

// ─── exports called from gui_nk.c ───────────────────────────────────────

export fn rmd_zig_is_dir(path: [*:0]const u8) c_int {
    const p = std.mem.sliceTo(path, 0);
    if (p.len == 0) return 0;
    var dir = Dir.cwd().openDir(io(), p, .{}) catch return 0;
    dir.close(io());
    return 1;
}

fn copyOut(src: []const u8, out: [*]u8, max: c_int) c_int {
    if (max <= 0) return 0;
    const n = @min(src.len, @as(usize, @intCast(max - 1)));
    @memcpy(out[0..n], src[0..n]);
    out[n] = 0;
    return @intCast(n);
}

export fn rmd_zig_pick_folder(title: [*:0]const u8, out: [*]u8, max: c_int) c_int {
    const p = (win32_folder_dialog.selectFolder(gpa, std.mem.sliceTo(title, 0)) catch null) orelse return 0;
    defer gpa.free(p);
    return copyOut(p, out, max);
}

/// Writes the detected key as a hex string into `out`. Returns its length,
/// or 0 when no key could be found.
export fn rmd_zig_detect_key(input: [*:0]const u8, out: [*]u8, max: c_int) c_int {
    const ip = std.mem.sliceTo(input, 0);
    if (ip.len == 0) return 0;
    var dir = Dir.cwd().openDir(io(), ip, .{ .iterate = true }) catch {
        logFmt("  x cannot open input folder: {s}", .{ip}, true);
        return 0;
    };
    defer dir.close(io());
    const found = (key_detect.detect(io(), gpa, dir) catch null) orelse return 0;
    const hex = found.hex();
    logFmt("  + key detected ({s}): {s}", .{ found.source.describe(), &hex }, false);
    return copyOut(&hex, out, max);
}

/// Validates the settings, discovers the files to process and prepares the
/// output folder. Returns the number of files found, 0 when there are none,
/// or -1 on error (details are in the log).
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
    g.reset();
    g_log.clear();
    return scan(
        std.mem.sliceTo(input, 0),
        std.mem.sliceTo(output, 0),
        std.mem.sliceTo(key_hex, 0),
        std.mem.sliceTo(header_hex, 0),
        decrypt != 0,
        mz != 0,
        ignore_header != 0,
        overwrite != 0,
        clean_output != 0,
    ) catch |err| {
        logFmt("  x {s}", .{processor.describeError(err)}, true);
        g.reset();
        return -1;
    };
}

fn scan(ip: []const u8, op_opt: []const u8, kh: []const u8, hh: []const u8, decrypt: bool, mz: bool, ignore_header: bool, overwrite: bool, clean_output: bool) !c_int {
    var opts: processor.Options = .{
        .mode = if (decrypt) .decrypt else .encrypt,
        .mz = mz,
        .verify_header = !ignore_header,
        .overwrite = overwrite,
    };
    if (kh.len > 0) {
        opts.key = decrypter.parseHex16(kh) orelse {
            logFmt("  x invalid key: need exactly 32 hex characters (got {d})", .{kh.len}, true);
            return -1;
        };
    }
    opts.header = decrypter.parseHex16(hh) orelse {
        logFmt("  x fake header must be exactly 32 hexadecimal characters", .{}, true);
        return -1;
    };

    const in_dir = Dir.cwd().openDir(io(), ip, .{ .iterate = true }) catch {
        logFmt("  x cannot open input folder: {s}", .{ip}, true);
        return -1;
    };
    g.in_dir = in_dir;
    const op = if (op_opt.len > 0) op_opt else ip;

    if (opts.key == null) {
        if (try key_detect.detect(io(), gpa, in_dir)) |found| {
            opts.key = found.key;
            logFmt("  + key auto-detected ({s})", .{found.source.describe()}, false);
        } else if (opts.mode == .encrypt) {
            logFmt("  x encryption needs a key; auto-detection failed", .{}, true);
            return -1;
        } else {
            logFmt("  ! no key found - PNGs will be restored, audio cannot be decrypted", .{}, true);
        }
    }

    const plan = try processor.plan(io(), g.arena.allocator(), in_dir, opts.mode);
    if (plan.walk_errors > 0) logFmt("  ! {d} folder(s) could not be read", .{plan.walk_errors}, true);
    if (plan.files.len == 0) {
        logFmt("  x no matching files found in that folder", .{}, true);
        return 0;
    }

    if (clean_output) {
        processor.checkCleanTarget(io(), gpa, ip, op) catch |err| {
            if (err == error.OutputOverlapsInput) {
                logFmt("  x refusing to clean: the output folder overlaps the input folder", .{}, true);
            } else {
                logFmt("  x cannot verify the output folder: {s}", .{processor.describeError(err)}, true);
            }
            return -1;
        };
        Dir.cwd().deleteTree(io(), op) catch {
            logFmt("  x could not clean output folder: {s}", .{op}, true);
            return -1;
        };
    }
    Dir.cwd().createDirPath(io(), op) catch {
        logFmt("  x could not create output folder: {s}", .{op}, true);
        return -1;
    };
    const out_dir = Dir.cwd().openDir(io(), op, .{}) catch {
        logFmt("  x cannot open output folder: {s}", .{op}, true);
        return -1;
    };
    g.out_dir = out_dir;
    processor.createOutputDirs(io(), out_dir, plan);

    g.files = plan.files;
    g.opts = opts;
    logFmt("  -> found {d} files", .{plan.files.len}, false);
    return @intCast(plan.files.len);
}

/// Called once per frame while the UI is processing: starts the job on the
/// first call, then moves finished results into the log. `batch` is kept
/// for ABI compatibility; work now runs on background threads.
export fn rmd_zig_step(batch: c_int) void {
    _ = batch;
    if (g.drained >= g.files.len) return;
    const job = g.job orelse start: {
        const job = gpa.create(processor.Job) catch return failAll("out of memory");
        job.* = processor.Job.init(io(), gpa, g.in_dir.?, g.out_dir.?, g.files, g.opts) catch {
            gpa.destroy(job);
            return failAll("out of memory");
        };
        g.job = job;
        job.start(processor.defaultJobs());
        break :start job;
    };

    while (g.drained < g.files.len) : (g.drained += 1) {
        const path = g.files[g.drained];
        const res = job.result(g.drained) orelse break;
        if (res) {
            var buf: [processor.max_rel_path]u8 = undefined;
            const target = processor.classify(path, g.opts.mode, g.opts.mz).?;
            logFmt("  + {s}", .{processor.outputPath(&buf, path, target.out_ext) catch path}, false);
        } else |err| {
            g.errors += 1;
            logFmt("  x {s}: {s}", .{ path, processor.describeError(err) }, true);
        }
    }

    if (g.drained == g.files.len) {
        job.join();
        if (g.errors > 0) {
            logFmt("  done - {d} files, {d} errors", .{ g.drained, g.errors }, true);
        } else {
            logFmt("  done - {d} files processed", .{g.drained}, false);
        }
    }
}

fn failAll(reason: []const u8) void {
    logFmt("  x {s}", .{reason}, true);
    g.errors = g.files.len;
    g.drained = g.files.len;
}

export fn rmd_zig_progress(done: *c_int, total: *c_int, errors: *c_int) void {
    done.* = @intCast(g.drained);
    total.* = @intCast(g.files.len);
    errors.* = @intCast(g.errors);
}

export fn rmd_zig_log(msg: [*:0]const u8, is_err: c_int) void {
    g_log.push(std.mem.sliceTo(msg, 0), is_err != 0);
}

export fn rmd_zig_log_count() c_int {
    return @intCast(g_log.len);
}

/// The returned string stays valid until the next log call.
export fn rmd_zig_log_get(i: c_int, is_err: *c_int) ?[*:0]const u8 {
    if (i < 0 or i >= g_log.len) return null;
    const e = g_log.get(@intCast(i));
    is_err.* = @intFromBool(e.err);
    return e.msg.ptr;
}

export fn rmd_zig_log_clear() void {
    g_log.clear();
}

// ─── entry points (UI lives in gui_nk.c) ────────────────────────────────

extern fn rmd_gui_main() c_int;

pub fn main() u8 {
    return @intCast(rmd_gui_main());
}

export fn WinMain(_: ?*anyopaque, _: ?*anyopaque, _: ?[*:0]u8, _: c_int) c_int {
    return rmd_gui_main();
}
