const std = @import("std");

pub const DEFAULT_HEADER: [16]u8 = .{
    0x52, 0x50, 0x47, 0x4D, 0x56, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
};

pub const PNG_HEADER: [16]u8 = .{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
};

pub fn Decrypter(comptime header_len: comptime_int) type {
    return struct {
        const Self = @This();

        pub const header_len_bytes = header_len;

        pub fn verifyHeader(data: []const u8) bool {
            if (data.len < header_len) return false;
            for (data[0..header_len], 0..) |byte, i| {
                if (byte != DEFAULT_HEADER[i]) return false;
            }
            return true;
        }

        pub fn xorBytes(data: []u8, key: []const u8) void {
            const len = @min(data.len, header_len);
            for (0..len) |i| {
                data[i] ^= key[i % key.len];
            }
        }

        pub fn decrypt(data: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
            if (data.len < header_len) return error.FileTooSmall;
            const result = try allocator.dupe(u8, data[header_len..]);
            xorBytes(result, key);
            return result;
        }

        pub fn encrypt(data: []const u8, key: []const u8, allocator: std.mem.Allocator) ![]u8 {
            const result = try allocator.dupe(u8, data);
            xorBytes(result, key);
            const out = try allocator.alloc(u8, header_len + result.len);
            @memcpy(out[0..header_len], &DEFAULT_HEADER);
            @memcpy(out[header_len..], result);
            allocator.free(result);
            return out;
        }

        pub fn restorePng(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
            const skip = header_len * 2;
            if (data.len < skip) return error.FileTooSmall;
            var result = try allocator.alloc(u8, PNG_HEADER.len + (data.len - skip));
            @memcpy(result[0..PNG_HEADER.len], &PNG_HEADER);
            @memcpy(result[PNG_HEADER.len..], data[skip..]);
            return result;
        }

        pub fn deriveKeyFromPng(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
            if (data.len < header_len * 2) return error.FileTooSmall;
            var key = try allocator.alloc(u8, header_len);
            const encrypted_bytes = data[header_len..][0..header_len];
            for (0..header_len) |i| {
                key[i] = PNG_HEADER[i] ^ encrypted_bytes[i];
            }
            return key;
        }
    };
}

pub const DefaultDecrypter = Decrypter(16);

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(DefaultDecrypter);
}

test "header verification" {
    const D = DefaultDecrypter;
    try std.testing.expect(D.verifyHeader(&DEFAULT_HEADER));
    try std.testing.expect(!D.verifyHeader(&[_]u8{0} ** 16));
}

test "decrypt roundtrip" {
    const alloc = std.testing.allocator;
    const D = DefaultDecrypter;

    var key_bytes = try alloc.alloc(u8, 16);
    defer alloc.free(key_bytes);
    for (0..16) |i| key_bytes[i] = @intCast(i);

    const plaintext = [_]u8{0xAA} ** 32;

    const encrypted = try D.encrypt(&plaintext, key_bytes, alloc);
    defer alloc.free(encrypted);

    try std.testing.expect(D.verifyHeader(encrypted[0..16]));

    const decrypted = try D.decrypt(encrypted, key_bytes, alloc);
    defer alloc.free(decrypted);

    try std.testing.expectEqualSlices(u8, &plaintext, decrypted);
}

test "restore png" {
    const alloc = std.testing.allocator;
    const D = DefaultDecrypter;

    const fake_header = DEFAULT_HEADER;
    var enc_header: [16]u8 = undefined;
    for (0..16) |i| enc_header[i] = PNG_HEADER[i] ^ @as(u8, @intCast(i));

    var file_data = try alloc.alloc(u8, 16 + 16 + 8);
    defer alloc.free(file_data);
    @memcpy(file_data[0..16], &fake_header);
    @memcpy(file_data[16..32], &enc_header);
    @memcpy(file_data[32..], &[_]u8{0xBB} ** 8);

    const restored = try D.restorePng(file_data, alloc);
    defer alloc.free(restored);

    try std.testing.expectEqualSlices(u8, &PNG_HEADER, restored[0..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xBB} ** 8, restored[16..]);
}

test "derive key from png" {
    const alloc = std.testing.allocator;
    const D = DefaultDecrypter;

    var encrypted_bytes: [16]u8 = undefined;
    for (0..16) |i| encrypted_bytes[i] = PNG_HEADER[i] ^ @as(u8, @intCast(i));

    var file_data = try alloc.alloc(u8, 16 + 16);
    defer alloc.free(file_data);
    @memcpy(file_data[0..16], &DEFAULT_HEADER);
    @memcpy(file_data[16..], &encrypted_bytes);

    const derived = try D.deriveKeyFromPng(file_data, alloc);
    defer alloc.free(derived);

    for (0..16) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), derived[i]);
    }
}
