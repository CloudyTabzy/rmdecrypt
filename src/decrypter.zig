//! RPG Maker MV/MZ asset "encryption" primitives.
//!
//! The scheme is a 16-byte fake header followed by the original file whose
//! first 16 bytes are XORed with a 16-byte key. Everything here works in
//! place on caller-owned buffers; nothing allocates.

const std = @import("std");

pub const header_len = 16;
pub const Key = [header_len]u8;
pub const Header = [header_len]u8;

pub const DEFAULT_HEADER: Header = .{
    0x52, 0x50, 0x47, 0x4D, 0x56, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub const PNG_HEADER: [16]u8 = .{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
};

/// Checks a fake RPG Maker header against a caller-supplied expected value.
pub fn verifyHeader(data: []const u8, expected: *const Header) bool {
    return data.len >= header_len and std.mem.eql(u8, data[0..header_len], expected);
}

/// XORs the first `min(data.len, 16)` bytes of `data` with `key`. The
/// operation is its own inverse, so it both encrypts and decrypts.
pub fn xorKey(data: []u8, key: *const Key) void {
    if (data.len >= header_len) {
        const V = @Vector(header_len, u8);
        const block: V = data[0..header_len].*;
        data[0..header_len].* = block ^ @as(V, key.*);
    } else {
        for (data, key[0..data.len]) |*b, k| b.* ^= k;
    }
}

/// Recovers the key from the first 32 bytes of an encrypted PNG: the
/// payload must start with the fixed 16-byte PNG signature + IHDR tag.
pub fn deriveKeyFromPng(data: []const u8) ?Key {
    if (data.len < header_len * 2) return null;
    const V = @Vector(header_len, u8);
    const encrypted: V = data[header_len..][0..header_len].*;
    return encrypted ^ @as(V, PNG_HEADER);
}

/// Parses a 32-character hex string into a key or header.
pub fn parseHex16(hex: []const u8) ?[16]u8 {
    if (hex.len != 32) return null;
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

test "header verification" {
    try std.testing.expect(verifyHeader(&DEFAULT_HEADER, &DEFAULT_HEADER));
    try std.testing.expect(!verifyHeader(&([_]u8{0} ** 16), &DEFAULT_HEADER));
    const custom: Header = @splat(0xA5);
    try std.testing.expect(verifyHeader(&custom, &custom));
    try std.testing.expect(!verifyHeader(custom[0..15], &custom));
}

test "xor roundtrip, long and short buffers" {
    var key: Key = undefined;
    for (&key, 0..) |*k, i| k.* = @intCast(i * 7 + 1);
    const original = [_]u8{0xAA} ** 40;

    var long = original;
    xorKey(&long, &key);
    try std.testing.expect(!std.mem.eql(u8, &long, &original));
    try std.testing.expectEqualSlices(u8, original[16..], long[16..]); // tail untouched
    xorKey(&long, &key);
    try std.testing.expectEqualSlices(u8, &original, &long);

    var short = [_]u8{ 1, 2, 3 };
    xorKey(&short, &key);
    try std.testing.expectEqualSlices(u8, &.{ 1 ^ 1, 2 ^ 8, 3 ^ 15 }, &short);
}

test "derive key from png" {
    var file: [40]u8 = undefined;
    @memcpy(file[0..16], &DEFAULT_HEADER);
    for (file[16..32], 0..) |*b, i| b.* = PNG_HEADER[i] ^ @as(u8, @intCast(i));
    const key = deriveKeyFromPng(&file).?;
    for (key, 0..) |k, i| try std.testing.expectEqual(@as(u8, @intCast(i)), k);
    try std.testing.expect(deriveKeyFromPng(file[0..31]) == null);
}

test "parse hex16" {
    const k = parseHex16("000102030405060708090a0B0c0D0e0F").?;
    for (k, 0..) |b, i| try std.testing.expectEqual(@as(u8, @intCast(i)), b);
    try std.testing.expect(parseHex16("0001") == null);
    try std.testing.expect(parseHex16("zz0102030405060708090a0b0c0d0e0f") == null);
}
