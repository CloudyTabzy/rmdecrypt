//! Encryption-key discovery for RPG Maker MV/MZ projects.
//!
//! Sources, in priority order:
//!   1. `encryptionKey` in System.json (known MV/MZ locations first, then
//!      anywhere in the tree)
//!   2. a `this._encryptionKey = "..."` assignment in a .js/.txt file
//!   3. derivation from the first encrypted PNG (known plaintext header)
//!
//! Every candidate is validated, so a malformed key in one source falls
//! through to the next instead of being used as-is.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const extensions = @import("extensions.zig");
const decrypter = @import("decrypter.zig");

pub const Key = decrypter.Key;

pub const Source = enum {
    system_json,
    js_file,
    encrypted_png,

    pub fn describe(s: Source) []const u8 {
        return switch (s) {
            .system_json => "System.json",
            .js_file => "script assignment",
            .encrypted_png => "derived from encrypted PNG",
        };
    }
};

pub const Detected = struct {
    key: Key,
    source: Source,

    pub fn hex(d: Detected) [32]u8 {
        return std.fmt.bytesToHex(d.key, .lower);
    }
};

/// Upper bound for text files we are willing to scan. Real System.json and
/// plugin files are far smaller; this only guards against pathological input.
const max_text_bytes = 64 << 20;

const known_system_json = [_][]const u8{ "www/data/System.json", "data/System.json" };

pub fn detect(io: Io, gpa: std.mem.Allocator, input_dir: Dir) !?Detected {
    for (known_system_json) |p| {
        if (try keyFromSystemJson(io, gpa, input_dir, p)) |k| return .{ .key = k, .source = .system_json };
    }

    // One walk gathers every fallback candidate; System.json still wins if it
    // turns up anywhere, so it is checked as soon as it is seen.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scripts: std.ArrayList([]const u8) = .empty;
    var first_png: ?[]const u8 = null;

    var walker = try input_dir.walk(gpa);
    defer walker.deinit();
    while (true) {
        // An unreadable subdirectory is skipped; the walker has already
        // popped it, so continuing cannot loop forever.
        const entry = (walker.next(io) catch continue) orelse break;
        if (entry.kind != .file) continue;
        const ext = Dir.path.extension(entry.basename);
        if (ascii.eqlIgnoreCase(entry.basename, "System.json")) {
            if (try keyFromSystemJson(io, gpa, input_dir, entry.path)) |k| return .{ .key = k, .source = .system_json };
        } else if (ascii.eqlIgnoreCase(ext, ".js") or ascii.eqlIgnoreCase(ext, ".txt")) {
            try scripts.append(arena, try arena.dupe(u8, entry.path));
        } else if (first_png == null and ext.len > 1) {
            const e = extensions.EncryptedExt.fromString(ext[1..]) orelse continue;
            if (e.isPng()) first_png = try arena.dupe(u8, entry.path);
        }
    }

    for (scripts.items) |p| {
        const text = readSmallFile(io, gpa, input_dir, p) orelse continue;
        defer gpa.free(text);
        if (findScriptKey(text)) |k| return .{ .key = k, .source = .js_file };
    }

    if (first_png) |p| {
        if (keyFromPng(io, input_dir, p)) |k| return .{ .key = k, .source = .encrypted_png };
    }
    return null;
}

fn readSmallFile(io: Io, gpa: std.mem.Allocator, dir: Dir, path: []const u8) ?[]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(max_text_bytes)) catch null;
}

fn keyFromSystemJson(io: Io, gpa: std.mem.Allocator, dir: Dir, path: []const u8) !?Key {
    const data = readSmallFile(io, gpa, dir, path) orelse return null;
    defer gpa.free(data);
    const SystemInfo = struct { encryptionKey: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(SystemInfo, gpa, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    return decrypter.parseHex16(parsed.value.encryptionKey orelse return null);
}

/// Finds `this._encryptionKey = "<32 hex>"` anywhere in `text`.
fn findScriptKey(text: []const u8) ?Key {
    const marker = "this._encryptionKey";
    var pos: usize = 0;
    while (std.mem.findPos(u8, text, pos, marker)) |hit| {
        pos = hit + marker.len;
        var rest = text[pos..];
        rest = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];
        const eq = std.mem.findScalar(u8, rest, '=') orelse continue;
        const value = std.mem.trimStart(u8, rest[eq + 1 ..], " \t");
        if (value.len == 0 or value[0] != '"') continue;
        const close = std.mem.findScalar(u8, value[1..], '"') orelse continue;
        if (decrypter.parseHex16(value[1..][0..close])) |k| return k;
    }
    return null;
}

fn keyFromPng(io: Io, dir: Dir, path: []const u8) ?Key {
    const file = dir.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var head: [decrypter.header_len * 2]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return null;
    return decrypter.deriveKeyFromPng(head[0..n]);
}

test "script key search" {
    const t = std.testing;
    const js =
        \\var stuff = "nope";
        \\  this._encryptionKey = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6";
        \\var more = "ok";
    ;
    const k = findScriptKey(js).?;
    try t.expectEqualStrings("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", &std.fmt.bytesToHex(k, .lower));

    try t.expect(findScriptKey("var x = 1;\nvar y = 2;") == null);
    // A malformed first assignment must not hide a valid later one.
    const two =
        \\this._encryptionKey = "short";
        \\this._encryptionKey="deadbeef0123456789abcdef01234567";
    ;
    try t.expectEqualStrings("deadbeef0123456789abcdef01234567", &std.fmt.bytesToHex(findScriptKey(two).?, .lower));
    // The value must be on the same line as the marker.
    try t.expect(findScriptKey("this._encryptionKey\n= \"deadbeef0123456789abcdef01234567\"") == null);
}

test "detect: System.json beats scripts and PNG; invalid keys fall through" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Encrypted PNG whose derived key is 0x00..0x0f.
    var png: [48]u8 = @splat(0xEE);
    @memcpy(png[0..16], &decrypter.DEFAULT_HEADER);
    for (png[16..32], 0..) |*b, i| b.* = decrypter.PNG_HEADER[i] ^ @as(u8, @intCast(i));
    try tmp.dir.createDirPath(io, "img");
    try tmp.dir.writeFile(io, .{ .sub_path = "img/a.rpgmvp", .data = &png });
    var d = (try detect(io, t.allocator, tmp.dir)).?;
    try t.expectEqual(Source.encrypted_png, d.source);
    try t.expectEqualStrings("000102030405060708090a0b0c0d0e0f", &d.hex());

    try tmp.dir.createDirPath(io, "js");
    try tmp.dir.writeFile(io, .{ .sub_path = "js/rpg_core.js", .data = "this._encryptionKey = \"11111111111111111111111111111111\";" });
    d = (try detect(io, t.allocator, tmp.dir)).?;
    try t.expectEqual(Source.js_file, d.source);

    // Malformed System.json key is ignored rather than used verbatim.
    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.writeFile(io, .{ .sub_path = "data/System.json", .data = "{\"encryptionKey\":\"not-hex\"}" });
    d = (try detect(io, t.allocator, tmp.dir)).?;
    try t.expectEqual(Source.js_file, d.source);

    try tmp.dir.writeFile(io, .{ .sub_path = "data/System.json", .data = "{\"gameTitle\":\"x\",\"encryptionKey\":\"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6\"}" });
    d = (try detect(io, t.allocator, tmp.dir)).?;
    try t.expectEqual(Source.system_json, d.source);
    try t.expectEqualStrings("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", &d.hex());
}

test "detect: nothing found" {
    const t = std.testing;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "readme.md", .data = "hello" });
    try t.expect((try detect(t.io, t.allocator, tmp.dir)) == null);
}
