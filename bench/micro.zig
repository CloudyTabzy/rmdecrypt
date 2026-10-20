//! CPU-side microbenchmarks for the rmdecrypt core.
//!
//!   zig build bench                    # in-memory benches only
//!   zig build bench -- <game_dir>      # + plan / key detection on a real tree
//!
//! Each case reports the best-of-N mean time per operation. The "old" cases
//! reproduce the v1.0 code paths so the effect of each change is visible.

const std = @import("std");
const rmd = @import("rmdecrypt");
const decrypter = rmd.decrypter;
const processor = rmd.processor;
const Io = std.Io;

const rounds = 7;

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

/// Runs `func(ctx)` `iters` times per round and prints the best mean.
fn bench(io: Io, name: []const u8, iters: usize, ctx: anytype, comptime func: anytype) void {
    var best: f64 = std.math.inf(f64);
    for (0..rounds) |_| {
        const t0 = nowNs(io);
        for (0..iters) |_| func(ctx);
        const dt: f64 = @floatFromInt(nowNs(io) - t0);
        best = @min(best, dt / @as(f64, @floatFromInt(iters)));
    }
    if (best >= 1e6)
        std.debug.print("  {s:<44} {d:>10.2} ms/op\n", .{ name, best / 1e6 })
    else if (best >= 1e3)
        std.debug.print("  {s:<44} {d:>10.2} us/op\n", .{ name, best / 1e3 })
    else
        std.debug.print("  {s:<44} {d:>10.2} ns/op\n", .{ name, best });
}

const key: decrypter.Key = .{ 0x7a, 0x8e, 0xeb, 0xc8, 0x6a, 0xcc, 0xfb, 0x83, 0x44, 0x79, 0xf8, 0x28, 0xbe, 0x77, 0x1c, 0xa4 };

// ─── xor ──────────────────────────────────────────────────────────────────

const XorCtx = struct { buf: []u8, key_slice: []const u8 };

fn xorOld(c: *XorCtx) void {
    // v1.0: runtime-length key, modulo per byte.
    const len = @min(c.buf.len, 16);
    for (0..len) |i| c.buf[i] ^= c.key_slice[i % c.key_slice.len];
    std.mem.doNotOptimizeAway(c.buf.ptr);
}

fn xorNew(c: *XorCtx) void {
    decrypter.xorKey(c.buf, &key);
    std.mem.doNotOptimizeAway(c.buf.ptr);
}

// ─── whole-file transforms (bytes already in memory) ──────────────────────

const FileCtx = struct {
    gpa: std.mem.Allocator,
    /// Encrypted file image (fake header + payload).
    encrypted: []const u8,
    /// Plain asset image.
    plain: []const u8,
    /// Worker scratch, with 16 bytes of headroom in front of the file.
    scratch: []u8,
};

fn encryptOld(c: *FileCtx) void {
    // v1.0: XOR the read buffer, then concat(header, data) into a new
    // allocation that is written and freed.
    @memcpy(c.scratch[0..c.plain.len], c.plain); // stands in for the read
    const data = c.scratch[0..c.plain.len];
    for (0..@min(data.len, key.len)) |i| data[i] ^= key[i];
    const out = std.mem.concat(c.gpa, u8, &.{ &decrypter.DEFAULT_HEADER, data }) catch unreachable;
    std.mem.doNotOptimizeAway(out.ptr);
    c.gpa.free(out);
}

fn encryptNew(c: *FileCtx) void {
    @memcpy(c.scratch[16..][0..c.plain.len], c.plain); // the read, after headroom
    const opts: processor.Options = .{ .mode = .encrypt, .key = key };
    const out = processor.transform(c.scratch[0 .. 16 + c.plain.len], .{ .out_ext = "png_", .png = true }, &opts) catch unreachable;
    std.mem.doNotOptimizeAway(out.ptr);
}

fn restorePngOld(c: *FileCtx) void {
    // v1.0 keyless PNG path: allocate PNG header + body, copy, free.
    @memcpy(c.scratch[0..c.encrypted.len], c.encrypted);
    const data = c.scratch[0..c.encrypted.len];
    const result = c.gpa.alloc(u8, 16 + (data.len - 32)) catch unreachable;
    @memcpy(result[0..16], &decrypter.PNG_HEADER);
    @memcpy(result[16..], data[32..]);
    std.mem.doNotOptimizeAway(result.ptr);
    c.gpa.free(result);
}

fn restorePngNew(c: *FileCtx) void {
    @memcpy(c.scratch[16..][0..c.encrypted.len], c.encrypted);
    const opts: processor.Options = .{};
    const out = processor.transform(c.scratch[0 .. 16 + c.encrypted.len], .{ .out_ext = "png", .png = true }, &opts) catch unreachable;
    std.mem.doNotOptimizeAway(out.ptr);
}

fn copyOnly(c: *FileCtx) void {
    // Floor: the memcpy that models the read in every case above.
    @memcpy(c.scratch[16..][0..c.encrypted.len], c.encrypted);
    std.mem.doNotOptimizeAway(c.scratch.ptr);
}

// ─── classification ───────────────────────────────────────────────────────

const ClassifyCtx = struct { paths: []const []const u8 };

fn classifyAll(c: *ClassifyCtx) void {
    for (c.paths) |p| std.mem.doNotOptimizeAway(processor.classify(p, .decrypt, false));
}

// ─── real tree ────────────────────────────────────────────────────────────

const TreeCtx = struct { io: Io, gpa: std.mem.Allocator, dir: Io.Dir };

fn planTree(c: *TreeCtx) void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const p = processor.plan(c.io, arena.allocator(), c.dir, .decrypt) catch unreachable;
    std.mem.doNotOptimizeAway(p.files.len);
}

fn detectKey(c: *TreeCtx) void {
    std.mem.doNotOptimizeAway(rmd.key_detect.detect(c.io, c.gpa, c.dir) catch unreachable);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    std.debug.print("xor (16-byte block):\n", .{});
    var xbuf: [64]u8 = @splat(0x5A);
    var xctx: XorCtx = .{ .buf = &xbuf, .key_slice = &key };
    bench(io, "old: scalar loop, key[i % len]", 10_000_000, &xctx, xorOld);
    bench(io, "new: @Vector(16, u8) xor", 10_000_000, &xctx, xorNew);

    // p50 and p99 asset sizes of a real MZ game (961 files).
    for ([_]usize{ 5_906, 326_420 }) |size| {
        const plain = try gpa.alloc(u8, size);
        defer gpa.free(plain);
        for (plain, 0..) |*b, i| b.* = @truncate(i *% 31);
        const enc = try gpa.alloc(u8, size + 16);
        defer gpa.free(enc);
        @memcpy(enc[0..16], &decrypter.DEFAULT_HEADER);
        @memcpy(enc[16..], plain);
        const scratch = try gpa.alloc(u8, size + 64);
        defer gpa.free(scratch);
        var fctx: FileCtx = .{ .gpa = gpa, .encrypted = enc, .plain = plain, .scratch = scratch };

        std.debug.print("in-memory transform, {d} byte asset:\n", .{size});
        const iters: usize = if (size < 100_000) 200_000 else 5_000;
        bench(io, "floor: memcpy of the file (models the read)", iters, &fctx, copyOnly);
        bench(io, "old encrypt: xor + concat alloc/copy/free", iters, &fctx, encryptOld);
        bench(io, "new encrypt: header into read headroom", iters, &fctx, encryptNew);
        bench(io, "old keyless PNG: alloc + copy + free", iters, &fctx, restorePngOld);
        bench(io, "new keyless PNG: patch 16 bytes in place", iters, &fctx, restorePngNew);
    }

    std.debug.print("classify by extension:\n", .{});
    const sample = [_][]const u8{
        "img\\characters\\Actor1.png_", "audio\\se\\Cursor1.ogg_", "js\\plugins\\Foo.js",
        "img\\pictures\\cg01.rpgmvp",   "data\\Map001.json",       "fonts\\mplus-1m.woff",
    };
    var cctx: ClassifyCtx = .{ .paths = &sample };
    bench(io, "classify, 6 mixed paths", 1_000_000, &cctx, classifyAll);

    if (args.len > 1) {
        const dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
        defer dir.close(io);
        var tctx: TreeCtx = .{ .io = io, .gpa = gpa, .dir = dir };
        std.debug.print("real tree ({s}):\n", .{args[1]});
        bench(io, "plan: walk + classify + spread order", 20, &tctx, planTree);
        bench(io, "key detection", 200, &tctx, detectKey);
    }
}
