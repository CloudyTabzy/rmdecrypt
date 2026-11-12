const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const decrypter = @import("decrypter.zig");
const key_detect = @import("key_detect.zig");
const processor = @import("processor.zig");

const VERSION = @import("build_options").version;

/// Exit codes: 0 = success, 1 = runtime failure (including any file that
/// could not be processed), 2 = invalid command line.
const exit_failure: u8 = 1;
const exit_usage: u8 = 2;

/// At most this many per-file failures are listed individually.
const max_reported_failures = 20;

const Cli = struct {
    input_dir: []const u8 = "",
    output_dir: ?[]const u8 = null,
    key: ?decrypter.Key = null,
    header: decrypter.Header = decrypter.DEFAULT_HEADER,
    ignore_header: bool = false,
    overwrite: bool = false,
    clean_output: bool = false,
    detect_key_only: bool = false,
    encrypt: bool = false,
    mz: bool = false,
    jobs: ?usize = null,
    help: bool = false,
};

const ParseError = error{InvalidArgs};

fn parseArgs(args: []const [:0]const u8) ParseError!Cli {
    var cli: Cli = .{};
    var input: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (eqlAny(arg, &.{ "--help", "-h" })) {
            cli.help = true;
        } else if (eqlAny(arg, &.{ "--key", "-k" })) {
            const v = try value(args, &i, arg);
            cli.key = decrypter.parseHex16(v) orelse
                return usageError("--key must be exactly 32 hex characters (got {d})", .{v.len});
        } else if (eqlAny(arg, &.{ "--output", "-o" })) {
            cli.output_dir = try value(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--header")) {
            cli.header = decrypter.parseHex16(try value(args, &i, arg)) orelse
                return usageError("--header must be exactly 32 hex characters", .{});
        } else if (eqlAny(arg, &.{ "--jobs", "-j" })) {
            const v = try value(args, &i, arg);
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            if (n == 0 or n > processor.max_jobs)
                return usageError("--jobs must be between 1 and {d}", .{processor.max_jobs});
            cli.jobs = n;
        } else if (std.mem.eql(u8, arg, "--ignore-header")) {
            cli.ignore_header = true;
        } else if (std.mem.eql(u8, arg, "--overwrite")) {
            cli.overwrite = true;
        } else if (std.mem.eql(u8, arg, "--clean-output")) {
            cli.clean_output = true;
        } else if (std.mem.eql(u8, arg, "--detect-key")) {
            cli.detect_key_only = true;
        } else if (eqlAny(arg, &.{ "--encrypt", "-e" })) {
            cli.encrypt = true;
        } else if (std.mem.eql(u8, arg, "--mz")) {
            cli.mz = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return usageError("unknown option: {s}", .{arg});
        } else if (input == null) {
            input = arg;
        } else {
            return usageError("unexpected argument: {s}", .{arg});
        }
    }
    if (cli.help) return cli;
    cli.input_dir = input orelse return usageError("input directory is required", .{});
    return cli;
}

fn eqlAny(arg: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, arg, n)) return true;
    return false;
}

fn value(args: []const [:0]const u8, i: *usize, flag: []const u8) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return usageError("{s} requires a value", .{flag});
    return args[i.*];
}

fn usageError(comptime fmt: []const u8, args: anytype) ParseError {
    // Tests exercise the error paths; keep their stderr clean.
    if (!builtin.is_test) std.debug.print("error: " ++ fmt ++ "\n(run with --help for usage)\n", args);
    return error.InvalidArgs;
}

/// `<input>_decrypted` / `<input>_encrypted`, ignoring trailing separators so
/// `game/` does not turn into `game/_decrypted` inside the input.
fn defaultOutputDir(arena: std.mem.Allocator, input: []const u8, encrypt: bool) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, input, "/\\");
    const base = if (trimmed.len == 0 or (trimmed.len == 2 and trimmed[1] == ':')) input else trimmed;
    return std.mem.concat(arena, u8, &.{ base, if (encrypt) "_encrypted" else "_decrypted" });
}

test "parse arguments" {
    const t = std.testing;
    const cli = try parseArgs(&.{ "rmdecrypt", "-k", "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "--header", "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5", "-j", "3", "game", "--mz", "-e" });
    try t.expectEqualStrings("game", cli.input_dir);
    try t.expectEqual(@as(u8, 0xa1), cli.key.?[0]);
    try t.expectEqualSlices(u8, &([_]u8{0xA5} ** 16), &cli.header);
    try t.expectEqual(@as(?usize, 3), cli.jobs);
    try t.expect(cli.encrypt and cli.mz);
    try t.expect((try parseArgs(&.{ "rmdecrypt", "--help" })).help);
    try t.expectError(error.InvalidArgs, parseArgs(&.{ "rmdecrypt", "--key", "abcd", "game" }));
    try t.expectError(error.InvalidArgs, parseArgs(&.{ "rmdecrypt", "--verbose", "game" }));
    try t.expectError(error.InvalidArgs, parseArgs(&.{ "rmdecrypt", "a", "b" }));
    try t.expectError(error.InvalidArgs, parseArgs(&.{"rmdecrypt"}));
    try t.expectError(error.InvalidArgs, parseArgs(&.{ "rmdecrypt", "game", "-j", "0" }));
    try t.expectError(error.InvalidArgs, parseArgs(&.{ "rmdecrypt", "game", "-o" }));
}

test "default output dir" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("game_decrypted", try defaultOutputDir(a, "game", false));
    try t.expectEqualStrings("C:\\x\\game_encrypted", try defaultOutputDir(a, "C:\\x\\game\\", true));
    try t.expectEqualStrings("game_decrypted", try defaultOutputDir(a, "game//", false));
}

fn printUsage() void {
    const usage =
        \\rmdecrypt v{s} - RPG Maker MV/MZ asset decryptor
        \\
        \\Usage:
        \\  rmdecrypt [options] <input_directory>
        \\
        \\Options:
        \\  --key, -k <hex>     32-char hex encryption key (auto-detected when omitted)
        \\  --output, -o <dir>  Output directory (default: <input>_decrypted / _encrypted)
        \\  --encrypt, -e       Re-encrypt plain .png/.m4a/.ogg back to RPG Maker format
        \\  --mz                With --encrypt: write MZ extensions (.png_/.m4a_/.ogg_)
        \\  --ignore-header     Process files even when their fake header differs
        \\  --header <hex>      Fake header to expect / write (32 hex chars)
        \\  --overwrite         Replace output files that already exist
        \\  --clean-output      Delete the output directory first (refused if it
        \\                      overlaps the input directory)
        \\  --detect-key        Print the detected key to stdout and exit
        \\  --jobs, -j <n>      Worker threads (default: {d})
        \\  --help, -h          Show this help
        \\
        \\Key detection (when --key is omitted):
        \\  1. encryptionKey in System.json (known locations, then anywhere)
        \\  2. this._encryptionKey = "..." in a .js/.txt file
        \\  3. derived from the first encrypted PNG
        \\  Without a key, PNGs are restored from their known header and audio
        \\  files are reported as failures; --encrypt requires a key.
        \\
        \\Exit status: 0 success, 1 failure (any file not processed), 2 usage error.
        \\
    ;
    std.debug.print(usage, .{ VERSION, processor.defaultJobs() });
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(args) catch return exit_usage;
    if (cli.help) {
        printUsage();
        return 0;
    }
    return run(io, init.gpa, arena, cli) catch |err| {
        std.debug.print("error: {s}\n", .{processor.describeError(err)});
        return exit_failure;
    };
}

fn run(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cli: Cli) !u8 {
    const input_dir = Dir.cwd().openDir(io, cli.input_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("error: cannot open input directory '{s}': {s}\n", .{ cli.input_dir, processor.describeError(err) });
        return exit_failure;
    };
    defer input_dir.close(io);

    if (cli.detect_key_only) {
        const found = try key_detect.detect(io, gpa, input_dir) orelse {
            std.debug.print("error: no encryption key found\n", .{});
            return exit_failure;
        };
        var buf: [64]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &buf);
        try stdout.interface.print("{s}\n", .{&found.hex()});
        try stdout.interface.flush();
        std.debug.print("(source: {s})\n", .{found.source.describe()});
        return 0;
    }

    const output_path = cli.output_dir orelse try defaultOutputDir(arena, cli.input_dir, cli.encrypt);
    std.debug.print("rmdecrypt v{s}\n  input:  {s}\n  output: {s}\n  mode:   {s}\n", .{
        VERSION,                                        cli.input_dir, output_path,
        if (!cli.encrypt) "decrypt" else if (cli.mz) "encrypt (MZ)" else "encrypt (MV)",
    });

    var key = cli.key;
    if (key) |k| {
        std.debug.print("  key:    {s}\n", .{&std.fmt.bytesToHex(k, .lower)});
    } else if (try key_detect.detect(io, gpa, input_dir)) |found| {
        key = found.key;
        std.debug.print("  key:    {s} (auto-detected: {s})\n", .{ &found.hex(), found.source.describe() });
    } else if (cli.encrypt) {
        std.debug.print("error: --encrypt needs a key and none could be detected; pass --key\n", .{});
        return exit_failure;
    } else {
        std.debug.print("  key:    not found - PNGs will be restored, audio files cannot be decrypted\n", .{});
    }

    if (cli.clean_output) {
        processor.checkCleanTarget(io, gpa, cli.input_dir, output_path) catch |err| {
            if (err == error.OutputOverlapsInput) {
                std.debug.print("error: refusing --clean-output: output directory overlaps the input directory\n", .{});
            } else {
                std.debug.print("error: cannot verify --clean-output target: {s}\n", .{processor.describeError(err)});
            }
            return exit_failure;
        };
        Dir.cwd().deleteTree(io, output_path) catch |err| {
            std.debug.print("error: could not clean output directory: {s}\n", .{processor.describeError(err)});
            return exit_failure;
        };
    }

    const start = Io.Clock.awake.now(io);
    const mode: processor.Mode = if (cli.encrypt) .encrypt else .decrypt;
    const plan = try processor.plan(io, arena, input_dir, mode);
    if (plan.walk_errors > 0) std.debug.print("warning: {d} director{s} could not be read\n", .{ plan.walk_errors, if (plan.walk_errors == 1) "y" else "ies" });
    if (plan.files.len == 0) {
        std.debug.print("\nno {s} files found\n", .{if (cli.encrypt) ".png/.m4a/.ogg" else "encrypted"});
        return exit_failure;
    }

    Dir.cwd().createDirPath(io, output_path) catch |err| {
        std.debug.print("error: could not create output directory: {s}\n", .{processor.describeError(err)});
        return exit_failure;
    };
    const output_dir = Dir.cwd().openDir(io, output_path, .{}) catch |err| {
        std.debug.print("error: could not open output directory: {s}\n", .{processor.describeError(err)});
        return exit_failure;
    };
    defer output_dir.close(io);
    processor.createOutputDirs(io, output_dir, plan);

    var job = try processor.Job.init(io, gpa, input_dir, output_dir, plan.files, .{
        .mode = mode,
        .mz = cli.mz,
        .key = key,
        .header = cli.header,
        .verify_header = !cli.ignore_header,
        .overwrite = cli.overwrite,
    });
    defer job.deinit();
    job.start(cli.jobs orelse processor.defaultJobs());
    job.join();
    const elapsed_ms = @as(f64, @floatFromInt(start.durationTo(Io.Clock.awake.now(io)).toNanoseconds())) / 1e6;

    var failed: usize = 0;
    for (plan.files, 0..) |path, i| {
        job.result(i).? catch |err| {
            failed += 1;
            if (failed <= max_reported_failures) std.debug.print("  x {s}: {s}\n", .{ path, processor.describeError(err) });
        };
    }
    if (failed > max_reported_failures) std.debug.print("  ... and {d} more\n", .{failed - max_reported_failures});

    const ok = plan.files.len - failed;
    if (failed > 0) {
        std.debug.print("\n{d} files processed, {d} failed ({d:.0} ms)\n", .{ ok, failed, elapsed_ms });
        return exit_failure;
    }
    std.debug.print("\n{d} files processed successfully ({d:.0} ms)\n", .{ ok, elapsed_ms });
    return 0;
}

test {
    _ = decrypter;
    _ = key_detect;
    _ = processor;
    _ = @import("extensions.zig");
}
