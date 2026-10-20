//! File-system strategy microbenchmark: how work order and worker count
//! affect the decrypt pipeline (open, length, read, close, create, write,
//! close) on a real game tree. This is the experiment behind
//! `processor.spreadByDirectory` and `processor.defaultJobs`.
//!
//!   zig build bench-io -Doptimize=ReleaseFast -- <game_dir> <scratch_dir> [reps]
//!
//! `scratch_dir` receives (and loses) one output tree per run. Configs are
//! interleaved so background noise (antivirus, indexing, thermal) hits all
//! of them equally; the median per cell is reported.

const std = @import("std");
const rmd = @import("rmdecrypt");
const processor = rmd.processor;
const Io = std.Io;
const Dir = Io.Dir;

const Order = enum { walk, spread };

const Ctx = struct {
    io: Io,
    in_dir: Dir,
    out_dir: Dir,
    files: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),

    fn worker(c: *Ctx) void {
        var scratch: processor.Scratch = .{};
        defer scratch.deinit(std.heap.smp_allocator);
        // An all-zero key makes the XOR a no-op, so every file (audio too)
        // goes through the full read/transform/write path identically.
        const opts: processor.Options = .{ .key = @splat(0), .verify_header = false };
        while (true) {
            const i = c.next.fetchAdd(1, .monotonic);
            if (i >= c.files.len) break;
            processor.processFile(c.io, std.heap.smp_allocator, c.in_dir, c.out_dir, c.files[i], &opts, &scratch) catch |err|
                std.debug.panic("{s}: {s}", .{ c.files[i], @errorName(err) });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: io_strategies <game_dir> <scratch_dir> [reps]\n", .{});
        return error.InvalidArgs;
    }
    const in_dir = try Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer in_dir.close(io);
    const scratch_root = args[2];
    const reps = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 7;

    // The planner's output is spread order; recover walk order by sorting
    // paths, which groups each directory's files together as a walk does.
    const p = try processor.plan(io, arena, in_dir, .decrypt);
    const walk_order = try arena.dupe([]const u8, p.files);
    std.mem.sort([]const u8, walk_order, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    std.debug.print("{d} files in {d} directories, {d} reps\n", .{ p.files.len, p.dirs.len, reps });

    const thread_counts = [_]usize{ 1, 2, 4, 6, 8, 16 };
    const orders = [_]Order{ .walk, .spread };
    var samples: [orders.len][thread_counts.len]std.ArrayList(i96) = undefined;
    for (&samples) |*row| for (row) |*s| {
        s.* = .empty;
    };

    var run_id: usize = 0;
    for (0..reps) |_| for (thread_counts, 0..) |nt, ti| for (orders, 0..) |order, oi| {
        run_id += 1;
        const out_name = try std.fmt.allocPrint(arena, "{s}/run{d}", .{ scratch_root, run_id });
        try Dir.cwd().createDirPath(io, out_name);
        const out_dir = try Dir.cwd().openDir(io, out_name, .{});
        processor.createOutputDirs(io, out_dir, p);

        var ctx: Ctx = .{ .io = io, .in_dir = in_dir, .out_dir = out_dir, .files = if (order == .walk) walk_order else p.files };
        var threads: [16]std.Thread = undefined;
        const t0 = Io.Clock.awake.now(io).toNanoseconds();
        for (threads[0..nt]) |*t| t.* = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});
        for (threads[0..nt]) |t| t.join();
        try samples[oi][ti].append(arena, Io.Clock.awake.now(io).toNanoseconds() - t0);

        out_dir.close(io);
        Dir.cwd().deleteTree(io, out_name) catch {};
    };

    std.debug.print("\nmedian wall time (ms) for the file pipeline\n{s:>10}", .{"threads"});
    for (thread_counts) |nt| std.debug.print("{d:>9}", .{nt});
    std.debug.print("\n", .{});
    for (orders, 0..) |order, oi| {
        std.debug.print("{s:>10}", .{@tagName(order)});
        for (0..thread_counts.len) |ti| {
            const s = samples[oi][ti].items;
            std.mem.sort(i96, s, {}, std.sort.asc(i96));
            std.debug.print("{d:>9.1}", .{@as(f64, @floatFromInt(s[s.len / 2])) / 1e6});
        }
        std.debug.print("\n", .{});
    }
}
