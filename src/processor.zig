//! Shared batch engine for the CLI and the GUI: discovers assets, plans the
//! work order, and decrypts / re-encrypts files on a pool of worker threads.
//!
//! Performance notes (measured on Windows/NTFS, see README "Benchmark"):
//! * The workload is metadata-bound: creating the output file costs far more
//!   than reading or transforming it (assets are typically a few KB).
//! * NTFS serializes file creation within one directory, so the work list is
//!   interleaved across directories (`spreadByDirectory`) to keep concurrent
//!   workers out of each other's way. This alone cut wall time by ~1/3.
//! * Each worker reuses one buffer and reads a file *after* 16 bytes of
//!   headroom, so every mode becomes a single in-place edit plus one write:
//!   decrypt writes `buf[32..]`, keyless PNG restore patches 16 bytes, and
//!   encrypt drops the fake header into the headroom. No per-file allocation
//!   and no copies.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const decrypter = @import("decrypter.zig");
const extensions = @import("extensions.zig");

const header_len = decrypter.header_len;

pub const Mode = enum { decrypt, encrypt };

pub const Options = struct {
    mode: Mode = .decrypt,
    /// Encrypt mode: emit MZ extensions (.png_ …) instead of MV (.rpgmvp …).
    mz: bool = false,
    /// Required to encrypt and to decrypt audio. Without it, decryption
    /// restores PNGs from their known header and rejects everything else.
    key: ?decrypter.Key = null,
    header: decrypter.Header = decrypter.DEFAULT_HEADER,
    verify_header: bool = true,
    overwrite: bool = false,
};

pub const Error = error{
    /// The fake header differs from `Options.header`.
    InvalidHeader,
    /// Shorter than the headers it is supposed to contain.
    FileTooSmall,
    /// The operation needs a key and none was provided.
    MissingKey,
    UnsupportedExtension,
};

/// A short human-readable reason for a per-file failure.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidHeader => "fake header mismatch (not an RPG Maker asset, or a custom header)",
        error.FileTooSmall => "file is too small to be an RPG Maker asset",
        error.MissingKey => "needs the encryption key (only PNGs can be restored without one)",
        error.PathAlreadyExists => "output file already exists (enable overwrite)",
        error.FileNotFound => "not found",
        error.AccessDenied, error.PermissionDenied => "access denied",
        error.NameTooLong => "path too long",
        error.AntivirusInterference => "blocked by antivirus",
        error.NoSpaceLeft => "disk full",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

/// What a processable input file turns into.
pub const Target = struct {
    out_ext: []const u8,
    png: bool,
};

/// Classifies `path` by extension for the given mode; null = not ours.
pub fn classify(path: []const u8, mode: Mode, mz: bool) ?Target {
    const ext = Dir.path.extension(path);
    if (ext.len < 2) return null;
    switch (mode) {
        .decrypt => {
            const e = extensions.EncryptedExt.fromString(ext[1..]) orelse return null;
            return .{ .out_ext = e.normalExt(), .png = e.isPng() };
        },
        .encrypt => {
            const e = extensions.NormalExt.fromString(ext[1..]) orelse return null;
            return .{ .out_ext = e.encryptedExt(mz), .png = e == .png };
        },
    }
}

/// Generous for RPG Maker trees, and small enough to live on the stack.
pub const max_rel_path = 4096;

/// `path` with its extension replaced by `new_ext` (no leading dot).
pub fn outputPath(buf: []u8, path: []const u8, new_ext: []const u8) error{NameTooLong}![]const u8 {
    const stem = path[0 .. path.len - Dir.path.extension(path).len];
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ stem, new_ext }) catch error.NameTooLong;
}

/// Applies the transform in place. `buf[0..16]` is headroom and the input
/// file's bytes follow it; returns the slice of `buf` to write out.
pub fn transform(buf: []u8, target: Target, opts: *const Options) Error![]u8 {
    std.debug.assert(buf.len >= header_len);
    const data = buf[header_len..];
    switch (opts.mode) {
        .encrypt => {
            const key = &(opts.key orelse return error.MissingKey);
            decrypter.xorKey(data, key);
            buf[0..header_len].* = opts.header;
            return buf;
        },
        .decrypt => {
            if (data.len < header_len) return error.FileTooSmall;
            if (opts.verify_header and !decrypter.verifyHeader(data, &opts.header)) return error.InvalidHeader;
            const payload = data[header_len..];
            if (opts.key) |*key| {
                decrypter.xorKey(payload, key);
                return payload;
            }
            if (!target.png) return error.MissingKey;
            if (payload.len < header_len) return error.FileTooSmall;
            payload[0..header_len].* = decrypter.PNG_HEADER;
            return payload;
        },
    }
}

/// Per-worker reusable read buffer.
pub const Scratch = struct {
    buf: []u8 = &.{},

    pub fn ensure(s: *Scratch, gpa: Allocator, len: usize) Allocator.Error![]u8 {
        if (s.buf.len < len) {
            const new_len = @max(len, s.buf.len * 2, 256 * 1024);
            gpa.free(s.buf);
            s.buf = &.{};
            s.buf = try gpa.alloc(u8, new_len);
        }
        return s.buf[0..len];
    }

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        gpa.free(s.buf);
        s.* = .{};
    }
};

/// Processes one file from `in_dir` into the mirrored location in `out_dir`.
/// The output's parent directory must already exist (see `createOutputDirs`).
pub fn processFile(
    io: Io,
    gpa: Allocator,
    in_dir: Dir,
    out_dir: Dir,
    path: []const u8,
    opts: *const Options,
    scratch: *Scratch,
) !void {
    const target = classify(path, opts.mode, opts.mz) orelse return error.UnsupportedExtension;
    // Fail before touching the disk when the outcome is already known.
    if (opts.key == null and (opts.mode == .encrypt or !target.png)) return error.MissingKey;

    var path_buf: [max_rel_path]u8 = undefined;
    const out_path = try outputPath(&path_buf, path, target.out_ext);

    const buf = read: {
        const file = try in_dir.openFile(io, path, .{});
        defer file.close(io);
        const size = std.math.cast(usize, try file.length(io)) orelse return error.OutOfMemory;
        const buf = try scratch.ensure(gpa, header_len + size);
        const n = try file.readPositionalAll(io, buf[header_len..], 0);
        break :read buf[0 .. header_len + n];
    };
    const out = try transform(buf, target, opts);
    try out_dir.writeFile(io, .{
        .sub_path = out_path,
        .data = out,
        .flags = .{ .exclusive = !opts.overwrite },
    });
}

// ─── planning ──────────────────────────────────────────────────────────────

pub const Plan = struct {
    /// Relative input paths in processing order.
    files: []const []const u8,
    /// Unique relative parent directories of `files` (outputs mirror them).
    dirs: []const []const u8,
    /// Directory entries the walker could not read.
    walk_errors: usize,
};

/// Walks `in_dir` and returns every processable file. All memory comes from
/// `arena`.
pub fn plan(io: Io, arena: Allocator, in_dir: Dir, mode: Mode) !Plan {
    var items: std.ArrayList(SpreadItem) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    var dir_index: std.StringHashMapUnmanaged(u32) = .empty;
    var walk_errors: usize = 0;

    var walker = try in_dir.walk(arena);
    defer walker.deinit();
    while (true) {
        // An unreadable subdirectory is reported and skipped; the walker has
        // already popped it, so the next call makes progress.
        const entry = (walker.next(io) catch {
            walk_errors += 1;
            continue;
        }) orelse break;
        if (entry.kind != .file) continue;
        if (classify(entry.basename, mode, false) == null) continue;

        const path = try arena.dupe(u8, entry.path);
        const dir = path[0 .. path.len - entry.basename.len -| 1];
        const gop = try dir_index.getOrPut(arena, dir);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(dirs.items.len);
            try dirs.append(arena, dir);
        }
        try items.append(arena, .{ .path = path, .dir = gop.value_ptr.*, .rank = 0 });
    }

    const files = try arena.alloc([]const u8, items.items.len);
    try spreadByDirectory(arena, items.items, dirs.items.len, files);
    return .{ .files = files, .dirs = dirs.items, .walk_errors = walk_errors };
}

const SpreadItem = struct { path: []const u8, dir: u32, rank: u32 };

/// Orders `items` so each directory's files are spread evenly over the whole
/// run (file k of a directory holding n files sits at position ≈ (k+½)/n).
/// Neighbouring work items — which run concurrently — then usually target
/// different directories.
fn spreadByDirectory(gpa: Allocator, items: []SpreadItem, dir_count: usize, out: [][]const u8) !void {
    const counts = try gpa.alloc(u32, dir_count);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (items) |*it| {
        it.rank = counts[it.dir];
        counts[it.dir] += 1;
    }
    const Ctx = struct {
        counts: []const u32,
        fn lessThan(ctx: @This(), a: SpreadItem, b: SpreadItem) bool {
            // (2·rank+1)/count compared by cross-multiplication: exact, no floats.
            const lhs = (2 * @as(u64, a.rank) + 1) * ctx.counts[b.dir];
            const rhs = (2 * @as(u64, b.rank) + 1) * ctx.counts[a.dir];
            return lhs < rhs or (lhs == rhs and a.dir < b.dir);
        }
    };
    std.sort.pdq(SpreadItem, items, Ctx{ .counts = counts }, Ctx.lessThan);
    for (items, out) |it, *o| o.* = it.path;
}

/// Creates every output directory up front so workers only create files.
/// Failures surface later as per-file errors.
pub fn createOutputDirs(io: Io, out_dir: Dir, p: Plan) void {
    for (p.dirs) |d| {
        if (d.len > 0) out_dir.createDirPath(io, d) catch {};
    }
}

// ─── parallel execution ───────────────────────────────────────────────────

/// Default worker count. The workload is bound by file-system metadata, not
/// CPU, and on NTFS throughput peaks around four concurrent writers.
pub fn defaultJobs() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(cpus, 1, 4);
}

pub const max_jobs = 64;

const ErrorInt = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

/// A batch running on worker threads. Results are published lock-free per
/// file, so a UI thread can poll `result` while the job runs.
pub const Job = struct {
    io: Io,
    gpa: Allocator,
    in_dir: Dir,
    out_dir: Dir,
    files: []const []const u8,
    opts: Options,
    /// 0 = pending, 1 = ok, otherwise 2 + @intFromError(err).
    results: []std.atomic.Value(u32),
    next: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),
    threads: [max_jobs]std.Thread = undefined,
    thread_count: usize = 0,

    pub fn init(io: Io, gpa: Allocator, in_dir: Dir, out_dir: Dir, files: []const []const u8, opts: Options) !Job {
        const results = try gpa.alloc(std.atomic.Value(u32), files.len);
        @memset(results, .init(0));
        return .{ .io = io, .gpa = gpa, .in_dir = in_dir, .out_dir = out_dir, .files = files, .opts = opts, .results = results };
    }

    pub fn deinit(job: *Job) void {
        job.join();
        job.gpa.free(job.results);
        job.* = undefined;
    }

    /// Starts `jobs` workers. `job` must stay at a fixed address until
    /// `join`. If no thread can be spawned the batch runs inline.
    pub fn start(job: *Job, jobs: usize) void {
        const n = std.math.clamp(@min(jobs, job.files.len), 1, max_jobs);
        for (0..n) |_| {
            job.threads[job.thread_count] = std.Thread.spawn(.{}, worker, .{job}) catch break;
            job.thread_count += 1;
        }
        if (job.thread_count == 0) worker(job);
    }

    pub fn join(job: *Job) void {
        for (job.threads[0..job.thread_count]) |t| t.join();
        job.thread_count = 0;
    }

    pub fn isDone(job: *const Job) bool {
        return job.completed.load(.acquire) == job.files.len;
    }

    /// null while file `i` is still pending.
    pub fn result(job: *const Job, i: usize) ?anyerror!void {
        return switch (job.results[i].load(.acquire)) {
            0 => null,
            1 => {},
            else => |code| @errorFromInt(@as(ErrorInt, @intCast(code - 2))),
        };
    }

    fn worker(job: *Job) void {
        var scratch: Scratch = .{};
        defer scratch.deinit(job.gpa);
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.files.len) break;
            const code: u32 = if (processFile(job.io, job.gpa, job.in_dir, job.out_dir, job.files[i], &job.opts, &scratch)) 1 else |err| 2 + @as(u32, @intFromError(err));
            job.results[i].store(code, .release);
            _ = job.completed.fetchAdd(1, .release);
        }
    }
};

// ─── output-directory safety ──────────────────────────────────────────────

/// Refuses to clean an output directory that is, contains, or lies inside
/// the input directory — any of those would destroy source files. Paths are
/// compared after resolving them, so aliases such as `game/.` or `./game`
/// cannot slip through.
pub fn checkCleanTarget(io: Io, gpa: Allocator, input: []const u8, output: []const u8) !void {
    const in_real = try Dir.cwd().realPathFileAlloc(io, input, gpa);
    defer gpa.free(in_real);
    const out_real = Dir.cwd().realPathFileAlloc(io, output, gpa) catch |err| switch (err) {
        error.FileNotFound => return, // nothing to delete
        else => |e| return e,
    };
    defer gpa.free(out_real);
    if (pathsOverlap(in_real, out_real)) return error.OutputOverlapsInput;
}

fn pathsOverlap(a: []const u8, b: []const u8) bool {
    return isWithin(a, b) or isWithin(b, a);
}

/// True when `child` equals `parent` or lies beneath it.
fn isWithin(child: []const u8, parent: []const u8) bool {
    const p = std.mem.trimEnd(u8, parent, "/\\");
    if (child.len < p.len) return false;
    const prefix_eq = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(child[0..p.len], p)
    else
        std.mem.eql(u8, child[0..p.len], p);
    if (!prefix_eq) return false;
    return child.len == p.len or child[p.len] == '/' or child[p.len] == '\\';
}

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_key: decrypter.Key = .{ 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0xa7, 0xb8, 0xc9, 0xd0, 0xe1, 0xf2, 0xa3, 0xb4, 0xc5, 0xd6 };

test "classify and outputPath" {
    try testing.expectEqualStrings("png", classify("a/b.rpgmvp", .decrypt, false).?.out_ext);
    try testing.expect(classify("a/b.OGG_", .decrypt, false).?.png == false);
    try testing.expect(classify("a/b.png", .decrypt, false) == null);
    try testing.expectEqualStrings("png_", classify("x.png", .encrypt, true).?.out_ext);
    try testing.expectEqualStrings("rpgmvm", classify("x.M4A", .encrypt, false).?.out_ext);
    try testing.expect(classify("noext", .encrypt, false) == null);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("img\\a.b.png", try outputPath(&buf, "img\\a.b.rpgmvp", "png"));
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NameTooLong, outputPath(&tiny, "abcdef.rpgmvp", "png"));
}

test "transform: encrypt then decrypt roundtrip, custom header" {
    const plain = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR and then the rest of the image";
    const custom: decrypter.Header = @splat(0x5A);
    var buf: [header_len + plain.len + header_len]u8 = undefined;

    @memcpy(buf[header_len..][0..plain.len], plain);
    const enc_opts: Options = .{ .mode = .encrypt, .key = test_key, .header = custom };
    const encrypted = try transform(buf[0 .. header_len + plain.len], .{ .out_ext = "png_", .png = true }, &enc_opts);
    try testing.expectEqual(header_len + plain.len, encrypted.len);
    try testing.expectEqualSlices(u8, &custom, encrypted[0..header_len]);

    // Re-read the encrypted file the way processFile would: after headroom.
    var buf2: [header_len * 2 + plain.len]u8 = undefined;
    @memcpy(buf2[header_len..], encrypted);
    const target: Target = .{ .out_ext = "png", .png = true };
    var dec_opts: Options = .{ .key = test_key };
    try testing.expectError(error.InvalidHeader, transform(&buf2, target, &dec_opts));
    dec_opts.header = custom;
    try testing.expectEqualStrings(plain, try transform(&buf2, target, &dec_opts));
}

test "transform: keyless PNG restore, audio needs key, short files" {
    var file: [header_len * 2 + 4]u8 = undefined;
    @memcpy(file[0..header_len], &decrypter.DEFAULT_HEADER);
    @memset(file[header_len..][0..header_len], 0x77); // encrypted bytes, unknown key
    @memcpy(file[header_len * 2 ..], "TAIL");
    var buf: [header_len + file.len]u8 = undefined;
    @memcpy(buf[header_len..], &file);

    const opts: Options = .{};
    try testing.expectError(error.MissingKey, transform(&buf, .{ .out_ext = "ogg", .png = false }, &opts));
    const restored = try transform(&buf, .{ .out_ext = "png", .png = true }, &opts);
    try testing.expectEqualSlices(u8, &decrypter.PNG_HEADER, restored[0..header_len]);
    try testing.expectEqualStrings("TAIL", restored[header_len..]);

    var short: [header_len + 10]u8 = undefined;
    try testing.expectError(error.FileTooSmall, transform(&short, .{ .out_ext = "png", .png = true }, &opts));
    // Header-only file with a key decrypts to an empty payload.
    var header_only: [header_len * 2]u8 = undefined;
    header_only[header_len..].* = decrypter.DEFAULT_HEADER;
    const keyed: Options = .{ .key = test_key };
    try testing.expectEqual(@as(usize, 0), (try transform(&header_only, .{ .out_ext = "png", .png = true }, &keyed)).len);
}

test "spreadByDirectory interleaves directories and keeps every file" {
    var items = [_]SpreadItem{
        .{ .path = "a1", .dir = 0, .rank = 0 }, .{ .path = "a2", .dir = 0, .rank = 0 },
        .{ .path = "a3", .dir = 0, .rank = 0 }, .{ .path = "a4", .dir = 0, .rank = 0 },
        .{ .path = "b1", .dir = 1, .rank = 0 }, .{ .path = "b2", .dir = 1, .rank = 0 },
    };
    var out: [items.len][]const u8 = undefined;
    try spreadByDirectory(testing.allocator, &items, 2, &out);
    const expected = [_][]const u8{ "a1", "b1", "a2", "a3", "b2", "a4" };
    for (expected, out) |e, o| try testing.expectEqualStrings(e, o);
}

test "isWithin / pathsOverlap" {
    try testing.expect(pathsOverlap("C:\\game", "C:\\game"));
    try testing.expect(pathsOverlap("C:\\game\\sub", "C:\\game"));
    try testing.expect(pathsOverlap("C:\\game", "C:\\game\\out"));
    try testing.expect(pathsOverlap("C:\\", "C:\\game"));
    try testing.expect(!pathsOverlap("C:\\game", "C:\\game_decrypted"));
    try testing.expect(!pathsOverlap("C:\\a\\game", "C:\\b\\game"));
    if (builtin.os.tag == .windows) try testing.expect(pathsOverlap("C:\\Game", "c:\\game\\x"));
}

test "end to end: plan, parallel job, overwrite protection, clean safety" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Fixture: two encrypted PNGs, one encrypted audio file, one bogus file.
    const body = "-pixels-" ** 8;
    var png: [header_len * 2 + body.len]u8 = undefined;
    @memcpy(png[0..header_len], &decrypter.DEFAULT_HEADER);
    png[header_len..][0..header_len].* = decrypter.PNG_HEADER;
    decrypter.xorKey(png[header_len..], &test_key);
    @memcpy(png[header_len * 2 ..], body);
    try tmp.dir.createDirPath(io, "in/img/pictures");
    try tmp.dir.createDirPath(io, "in/audio");
    try tmp.dir.writeFile(io, .{ .sub_path = "in/img/pictures/a.rpgmvp", .data = &png });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/img/b.png_", .data = &png });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/audio/c.rpgmvo", .data = &png });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/audio/bad.rpgmvo", .data = "tiny" });
    try tmp.dir.writeFile(io, .{ .sub_path = "in/readme.txt", .data = "ignored" });

    const in_dir = try tmp.dir.openDir(io, "in", .{ .iterate = true });
    defer in_dir.close(io);
    try tmp.dir.createDirPath(io, "out");
    const out_dir = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out_dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const p = try plan(io, arena_state.allocator(), in_dir, .decrypt);
    try testing.expectEqual(@as(usize, 4), p.files.len);
    createOutputDirs(io, out_dir, p);

    const run = struct {
        fn run(job_io: Io, a: Allocator, i: Dir, o: Dir, files: []const []const u8, opts: Options) ![2]usize {
            var job = try Job.init(job_io, a, i, o, files, opts);
            defer job.deinit();
            job.start(3);
            job.join();
            try testing.expect(job.isDone());
            var counts: [2]usize = .{ 0, 0 };
            for (0..files.len) |k| {
                if (job.result(k).?) {
                    counts[0] += 1;
                } else |_| {
                    counts[1] += 1;
                }
            }
            return counts;
        }
    }.run;

    try testing.expectEqual([2]usize{ 3, 1 }, try run(io, gpa, in_dir, out_dir, p.files, .{ .key = test_key }));
    const restored = try out_dir.readFileAlloc(io, "img/pictures/a.png", gpa, .unlimited);
    defer gpa.free(restored);
    try testing.expectEqualSlices(u8, &decrypter.PNG_HEADER, restored[0..header_len]);
    try testing.expectEqualStrings(body, restored[header_len..]);

    // Second run without overwrite: every existing output is refused.
    try testing.expectEqual([2]usize{ 0, 4 }, try run(io, gpa, in_dir, out_dir, p.files, .{ .key = test_key }));
    try testing.expectEqual([2]usize{ 3, 1 }, try run(io, gpa, in_dir, out_dir, p.files, .{ .key = test_key, .overwrite = true }));

    // Re-encrypt the decrypted tree and compare with the original bytes.
    const enc_plan = try plan(io, arena_state.allocator(), out_dir, .encrypt);
    try testing.expectEqual(@as(usize, 3), enc_plan.files.len); // a.png, b.png, c.ogg
    try tmp.dir.createDirPath(io, "re");
    const re_dir = try tmp.dir.openDir(io, "re", .{});
    defer re_dir.close(io);
    createOutputDirs(io, re_dir, enc_plan);
    try testing.expectEqual([2]usize{ 3, 0 }, try run(io, gpa, out_dir, re_dir, enc_plan.files, .{ .mode = .encrypt, .key = test_key }));
    const again = try re_dir.readFileAlloc(io, "img/pictures/a.rpgmvp", gpa, .unlimited);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, &png, again);

    // Clean-output safety resolves real paths.
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const in_abs = try Dir.path.join(gpa, &.{ root, "in" });
    defer gpa.free(in_abs);
    const in_alias = try Dir.path.join(gpa, &.{ root, "in", "img", ".." });
    defer gpa.free(in_alias);
    const out_abs = try Dir.path.join(gpa, &.{ root, "out" });
    defer gpa.free(out_abs);
    const missing = try Dir.path.join(gpa, &.{ root, "missing" });
    defer gpa.free(missing);
    try testing.expectError(error.OutputOverlapsInput, checkCleanTarget(io, gpa, in_abs, in_alias));
    try testing.expectError(error.OutputOverlapsInput, checkCleanTarget(io, gpa, in_abs, root));
    try checkCleanTarget(io, gpa, in_abs, out_abs);
    try checkCleanTarget(io, gpa, in_abs, missing);
}
