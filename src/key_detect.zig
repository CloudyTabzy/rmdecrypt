const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;
const json = std.json;
const ascii = std.ascii;
const extensions = @import("extensions.zig");
const decrypter = @import("decrypter.zig");

const SystemInfo = struct {
    encryptionKey: ?[]const u8 = null,
};

fn tryParseSystemJson(io: Io, allocator: std.mem.Allocator, input_dir: Dir, path: []const u8) !?[]const u8 {
    const data = input_dir.readFileAllocOptions(
        io,
        path,
        allocator,
        .unlimited,
        .of(u8),
        null,
    ) catch return null;
    defer allocator.free(data);

    var parsed = json.parseFromSlice(SystemInfo, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value.encryptionKey) |k| {
        if (k.len > 0) {
            return try allocator.dupe(u8, k);
        }
    }
    return null;
}

pub fn detectFromSystemJson(io: Io, allocator: std.mem.Allocator, input_dir: Dir) !?[]const u8 {
    // Fast path: check known MV/MZ locations
    for (&[_][]const u8{ "www/data/System.json", "data/System.json" }) |sys_path| {
        if (try tryParseSystemJson(io, allocator, input_dir, sys_path)) |key| {
            return key;
        }
    }

    // Fallback: walk entire tree looking for System.json anywhere
    var walker = input_dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        if (!ascii.eqlIgnoreCase(entry.basename, "System.json")) continue;
        if (try tryParseSystemJson(io, allocator, input_dir, entry.path)) |key| {
            return key;
        }
    }

    return null;
}

pub fn detectFromEncryptedPng(io: Io, allocator: std.mem.Allocator, input_dir: Dir) !?[]const u8 {
    var walker = try input_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const ext_with_dot = Dir.path.extension(entry.basename);
        if (ext_with_dot.len == 0) continue;
        const ext = ext_with_dot[1..];

        if (extensions.EncryptedExt.fromString(ext)) |e| {
            if (!e.isPng()) continue;
        } else {
            continue;
        }

        const data = input_dir.readFileAllocOptions(
            io,
            entry.path,
            allocator,
            .unlimited,
            .of(u8),
            null,
        ) catch continue;
        defer allocator.free(data);

        const key = decrypter.DefaultDecrypter.deriveKeyFromPng(data, allocator) catch continue;
        return key;
    }

    return null;
}

fn searchKeyInFile(text: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        const marker = "this._encryptionKey";
        const marker_pos = std.mem.indexOf(u8, line, marker) orelse continue;
        const after = line[marker_pos + marker.len ..];
        const eq = std.mem.indexOfAny(u8, after, "=") orelse continue;
        const after_eq = std.mem.trim(u8, after[eq + 1 ..], " \t");
        if (after_eq.len == 0 or after_eq[0] != '"') continue;
        const close = std.mem.indexOfScalar(u8, after_eq[1..], '"') orelse continue;
        const val = after_eq[1..][0..close];
        return allocator.dupe(u8, val) catch null;
    }
    return null;
}

pub fn detectFromJsFiles(io: Io, allocator: std.mem.Allocator, input_dir: Dir) !?[]const u8 {
    var walker = input_dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch break orelse break;
        if (entry.kind != .file) continue;
        const ext = Dir.path.extension(entry.basename);
        if (!ascii.eqlIgnoreCase(ext, ".js") and !ascii.eqlIgnoreCase(ext, ".txt")) continue;

        const data = input_dir.readFileAllocOptions(io, entry.path, allocator, .unlimited, .of(u8), null) catch continue;
        defer allocator.free(data);

        if (searchKeyInFile(data, allocator)) |key| return key;
    }

    return null;
}

pub fn detectFromInput(io: Io, allocator: std.mem.Allocator, input_dir: Dir) !?[]const u8 {
    if (try detectFromSystemJson(io, allocator, input_dir)) |key| {
        return key;
    }
    if (try detectFromJsFiles(io, allocator, input_dir)) |key| {
        return key;
    }
    if (try detectFromEncryptedPng(io, allocator, input_dir)) |key| {
        return key;
    }
    return null;
}

fn isHexString(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!ascii.isHex(c)) return false;
    }
    return true;
}

pub fn validateKeyHex(s: []const u8) bool {
    return isHexString(s) and s.len % 2 == 0 and s.len > 0;
}

pub fn hexKeyToBytes(key_hex: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var bytes = try allocator.alloc(u8, key_hex.len / 2);
    for (0..bytes.len) |i| {
        bytes[i] = try std.fmt.parseInt(u8, key_hex[i * 2 ..][0..2], 16);
    }
    return bytes;
}

comptime {
    std.testing.refAllDecls(@This());
}

test "hex validation" {
    const t = std.testing;
    try t.expect(validateKeyHex("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"));
    try t.expect(validateKeyHex("A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6"));
    try t.expect(!validateKeyHex(""));
    try t.expect(!validateKeyHex("xyz"));
    try t.expect(!validateKeyHex("a1b2c3"));
}

test "hex to bytes" {
    const t = std.testing;
    const bytes = try hexKeyToBytes("0102ff", t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0xFF }, bytes);
}

test "search key in js file" {
    const t = std.testing;
    const js =
        \\var stuff = "nope";
        \\this._encryptionKey = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6";
        \\var more = "ok";
    ;
    const found = searchKeyInFile(js, t.allocator) orelse {
        @panic("key not found");
    };
    defer t.allocator.free(found);
    try t.expectEqualStrings("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", found);
}

test "search key with spaces" {
    const t = std.testing;
    const js =
        \\this._encryptionKey = "deadbeef0123456789abcdef01234567";
    ;
    const found = searchKeyInFile(js, t.allocator) orelse {
        @panic("key not found");
    };
    defer t.allocator.free(found);
    try t.expectEqualStrings("deadbeef0123456789abcdef01234567", found);
}

test "search key missing" {
    const t = std.testing;
    const js =
        \\var x = 1;
        \\var y = 2;
    ;
    try t.expect(searchKeyInFile(js, t.allocator) == null);
}
