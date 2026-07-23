const std = @import("std");
const Dir = std.Io.Dir;
const extensions = @import("extensions.zig");
const decrypter = @import("decrypter.zig");
const key_detect = @import("key_detect.zig");

const D = decrypter.DefaultDecrypter;

const VERSION = "0.1.0";

const CliResult = struct {
    input_dir: []const u8,
    output_dir: []const u8,
    key_hex: ?[]const u8,
    key_valid: bool,
    no_key_mode: bool,
    ignore_header: bool,
    encrypt_mode: bool,
    mz_mode: bool,
    help: bool,
};

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !CliResult {
    var input_dir: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var key_hex: ?[]const u8 = null;
    var ignore_header = false;
    var encrypt_mode = false;
    var mz_mode = false;
    var help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --key requires a hex key argument\n", .{});
                help = true;
                continue;
            }
            key_hex = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --output requires a directory argument\n", .{});
                help = true;
                continue;
            }
            output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--ignore-header")) {
            ignore_header = true;
        } else if (std.mem.eql(u8, arg, "--encrypt") or std.mem.eql(u8, arg, "-e")) {
            encrypt_mode = true;
        } else if (std.mem.eql(u8, arg, "--mz")) {
            mz_mode = true;
        } else if (input_dir == null) {
            input_dir = arg;
        } else {
            std.debug.print("error: unexpected argument: {s}\n", .{arg});
            help = true;
        }
    }

    if (!help and input_dir == null) {
        std.debug.print("error: input directory is required\n", .{});
        help = true;
    }

    var key_valid = false;
    var no_key_mode = false;
    if (key_hex) |k| {
        key_valid = key_detect.validateKeyHex(k);
        if (!key_valid) {
            std.debug.print("error: key must be a valid hex string (even length, 0-9 a-f A-F)\n", .{});
        }
    } else if (!help) {
        no_key_mode = true;
    }

    const in = input_dir orelse "";
    const out = if (output_dir) |o| o else try std.mem.concat(allocator, u8, &.{ in, "_decrypted" });

    return CliResult{
        .input_dir = in,
        .output_dir = out,
        .key_hex = key_hex,
        .key_valid = key_valid,
        .no_key_mode = no_key_mode,
        .ignore_header = ignore_header,
        .encrypt_mode = encrypt_mode,
        .mz_mode = mz_mode,
        .help = help,
    };
}

fn printUsage() void {
    const usage =
        \\rmdecrypt v{s} - RPG Maker asset decryptor
        \\
        \\Usage:
        \\  rmdecrypt [options] <input_directory>
        \\
        \\Decrypt options (default):
        \\  --key, -k <hex>     32-char hex encryption key
        \\  --output, -o <dir>  Output directory (default: <input>_decrypted)
        \\  --ignore-header     Skip fake-header verification warning
        \\  --help, -h          Show this help
        \\
        \\Encrypt options:
        \\  --encrypt, -e       Re-encrypt plain assets back to RPG Maker format
        \\  --mz                Use MZ extensions (.png_/.m4a_/.ogg_) instead of MV
        \\  --key, -k <hex>     Encryption key (required with --encrypt)
        \\  --output, -o <dir>  Output directory
        \\
        \\Key detection (when --key is omitted, decrypt mode only):
        \\  1. Read encryptionKey from System.json (walks tree, finds anywhere)
        \\  2. Search .js/.txt files for this._encryptionKey assignment
        \\  3. Derive key from the first encrypted PNG in the input tree
        \\  4. If nothing works, PNG files are restored without a key,
        \\     audio files are skipped
        \\
    ;
    std.debug.print(usage, .{VERSION});
}

const WorkerContext = struct {
    files: []const []const u8,
    input_dir: Dir,
    output_dir: Dir,
    key_bytes: ?[]const u8,
    ignore_header: bool,
    encrypt_mode: bool,
    mz_mode: bool,
    gpa: std.mem.Allocator,
    next: *std.atomic.Value(usize),
    processed: *std.atomic.Value(usize),
    errors: *std.atomic.Value(usize),
};

fn processOneFile(io: std.Io, gpa: std.mem.Allocator, input_dir: Dir, output_dir: Dir, entry_path: []const u8, key_bytes: ?[]const u8, ignore_header: bool, encrypt_mode: bool, mz_mode: bool) !void {
    const ext_with_dot = Dir.path.extension(entry_path);
    if (ext_with_dot.len == 0) return;
    const ext = ext_with_dot[1..];

    if (encrypt_mode) {
        const norm_ext = extensions.NormalExt.fromString(ext) orelse return;
        const key = key_bytes orelse return;

        var in_file = try input_dir.openFile(io, entry_path, .{ .mode = .read_only });
        defer in_file.close(io);
        const file_size = (try in_file.stat(io)).size;
        const data = try gpa.alloc(u8, file_size);
        defer gpa.free(data);
        var rdr = in_file.reader(io, &.{});
        try rdr.interface.readSliceAll(data);

        var path_buf: [2048]u8 = undefined;
        const dot = std.mem.lastIndexOfScalar(u8, entry_path, '.') orelse entry_path.len;
        const out_path = try std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ entry_path[0..dot], norm_ext.encryptedExt(mz_mode) });

        const dirname = Dir.path.dirname(out_path);
        if (dirname) |parent| {
            if (parent.len > 0)
                output_dir.createDirPath(io, parent) catch {};
        }

        for (0..@min(data.len, key.len)) |i| data[i] ^= key[i];
        const out = try std.mem.concat(gpa, u8, &.{ decrypter.DEFAULT_HEADER[0..], data });
        defer gpa.free(out);
        try output_dir.writeFile(io, .{ .sub_path = out_path, .data = out });
        return;
    }

    const enc_ext = extensions.EncryptedExt.fromString(ext) orelse return;

    var in_file = try input_dir.openFile(io, entry_path, .{ .mode = .read_only });
    defer in_file.close(io);
    const file_size = (try in_file.stat(io)).size;
    const data = try gpa.alloc(u8, file_size);
    defer gpa.free(data);
    var reader = in_file.reader(io, &.{});
    try reader.interface.readSliceAll(data);

    if (data.len < decrypter.DEFAULT_HEADER.len) return;

    const dot = std.mem.lastIndexOfScalar(u8, entry_path, '.') orelse entry_path.len;
    var path_buf: [2048]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ entry_path[0..dot], enc_ext.normalExt() });

    const dirname = Dir.path.dirname(out_path);
    if (dirname) |parent| {
        if (parent.len > 0)
            output_dir.createDirPath(io, parent) catch {};
    }

    if (key_bytes) |key| {
        if (!ignore_header and !D.verifyHeader(data)) {}
        const payload = data[decrypter.DEFAULT_HEADER.len..];
        for (0..@min(payload.len, key.len)) |i| payload[i] ^= key[i];
        try output_dir.writeFile(io, .{ .sub_path = out_path, .data = payload });
    } else if (enc_ext.isPng()) {
        const result = try D.restorePng(data, gpa);
        defer gpa.free(result);
        try output_dir.writeFile(io, .{ .sub_path = out_path, .data = result });
    }
}

fn workerFn(ctx: *const WorkerContext) void {
    var threaded = std.Io.Threaded.init(ctx.gpa, .{});
    defer threaded.deinit();
    const worker_io = threaded.io();

    while (true) {
        const idx = ctx.next.fetchAdd(1, .monotonic);
        if (idx >= ctx.files.len) break;
        processOneFile(worker_io, ctx.gpa, ctx.input_dir, ctx.output_dir, ctx.files[idx], ctx.key_bytes, ctx.ignore_header, ctx.encrypt_mode, ctx.mz_mode) catch {
            _ = ctx.errors.fetchAdd(1, .monotonic);
        };
        _ = ctx.processed.fetchAdd(1, .monotonic);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    const cli = try parseArgs(allocator, args);

    if (cli.help or cli.input_dir.len == 0) {
        printUsage();
        return;
    }

    if (cli.key_hex != null and !cli.key_valid) {
        printUsage();
        return;
    }

    if (cli.encrypt_mode and cli.key_hex == null) {
        std.debug.print("error: --encrypt requires --key\n", .{});
        return;
    }

    std.debug.print("rmdecrypt v{s}\n", .{VERSION});
    std.debug.print("  input:  {s}\n", .{cli.input_dir});
    std.debug.print("  output: {s}\n", .{cli.output_dir});
    if (cli.encrypt_mode) std.debug.print("  mode:   encrypt\n", .{});

    var key_bytes: ?[]const u8 = null;
    defer if (key_bytes) |kb| allocator.free(kb);

    if (cli.key_hex) |hex| {
        const kb = try key_detect.hexKeyToBytes(hex, allocator);
        std.debug.print("  key:    {s}\n", .{cli.key_hex.?});
        key_bytes = kb;
    } else {
        std.debug.print("  key:    auto-detecting...\n", .{});
        const input_dir_open = Dir.cwd().openDir(io, cli.input_dir, .{ .iterate = true, .access_sub_paths = true }) catch |err| {
            std.debug.print("error: could not open input directory: {s}\n", .{@errorName(err)});
            return;
        };
        defer input_dir_open.close(io);
        const detected = try key_detect.detectFromInput(io, allocator, input_dir_open);
        if (detected) |k| {
            std.debug.print("  key:    auto-detected: {s}\n", .{k});
            key_bytes = try key_detect.hexKeyToBytes(k, allocator);
            allocator.free(k);
        } else {
            std.debug.print("  key:    not found, PNG files will be restored, audio files skipped\n", .{});
        }
    }

    const input_dir = Dir.cwd().openDir(io, cli.input_dir, .{ .iterate = true, .access_sub_paths = true }) catch |err| {
        std.debug.print("error: could not open input directory: {s}\n", .{@errorName(err)});
        return;
    };
    defer input_dir.close(io);

    Dir.cwd().createDirPath(io, cli.output_dir) catch |err| {
        std.debug.print("error: could not create output directory: {s}\n", .{@errorName(err)});
        return;
    };
    const output_dir = Dir.cwd().openDir(io, cli.output_dir, .{}) catch |err| {
        std.debug.print("error: could not open output directory: {s}\n", .{@errorName(err)});
        return;
    };
    defer output_dir.close(io);

    // Phase 1: collect all encrypted file paths
    var file_list: std.ArrayList([]const u8) = .empty;
    {
        var walker = input_dir.walk(allocator) catch |err| {
            std.debug.print("error: could not walk input directory: {s}\n", .{@errorName(err)});
            return;
        };
        defer walker.deinit();
        while (true) {
            const entry = walker.next(io) catch continue orelse break;
            if (entry.kind != .file) continue;
            const ext_dot = Dir.path.extension(entry.basename);
            if (ext_dot.len == 0) continue;
            if (extensions.EncryptedExt.fromString(ext_dot[1..]) == null) continue;
            try file_list.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    // Phase 2: pre-create unique output directories
    {
        var created = std.StringHashMap(void).init(allocator);
        defer created.deinit();
        for (file_list.items) |path| {
            const ext_dot = Dir.path.extension(path);
            if (ext_dot.len == 0) continue;
            const enc = extensions.EncryptedExt.fromString(ext_dot[1..]) orelse continue;
            const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse continue;
            var buf: [2048]u8 = undefined;
            const out = std.fmt.bufPrint(&buf, "{s}.{s}", .{ path[0..dot], enc.normalExt() }) catch continue;
            const dir = Dir.path.dirname(out);
            if (dir) |d| {
                if (d.len > 0) {
                    const gop = created.getOrPut(d) catch continue;
                    if (!gop.found_existing) output_dir.createDirPath(io, d) catch {};
                }
            }
        }
    }

    // Phase 3: parallel processing
    const n_cpus = try std.Thread.getCpuCount();
    const n_workers = @min(n_cpus, 8);

    var next = std.atomic.Value(usize).init(0);
    var processed = std.atomic.Value(usize).init(0);
    var errors = std.atomic.Value(usize).init(0);

    const ctx = WorkerContext{
        .files = file_list.items,
        .input_dir = input_dir,
        .output_dir = output_dir,
        .key_bytes = key_bytes,
        .ignore_header = cli.ignore_header,
        .encrypt_mode = cli.encrypt_mode,
        .mz_mode = cli.mz_mode,
        .gpa = init.gpa,
        .next = &next,
        .processed = &processed,
        .errors = &errors,
    };

    var threads: [8]std.Thread = undefined;
    var thread_count: usize = 0;
    for (0..n_workers) |_| {
        threads[thread_count] = try std.Thread.spawn(.{}, workerFn, .{&ctx});
        thread_count += 1;
    }
    for (0..thread_count) |i| {
        threads[i].join();
    }

    const p = processed.load(.monotonic);
    const e = errors.load(.monotonic);
    if (e > 0) {
        std.debug.print("\n{d} files processed, {d} errors\n", .{ p, e });
    } else {
        std.debug.print("\n{d} files processed successfully\n", .{p});
    }
}
