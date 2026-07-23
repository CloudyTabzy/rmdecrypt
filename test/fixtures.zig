const std = @import("std");
const Dir = std.Io.Dir;
const decrypter = @import("../src/decrypter.zig");
const D = decrypter.DefaultDecrypter;

pub const TEST_KEY = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6";

pub fn createTestFixtures(io: std.Io, allocator: std.mem.Allocator, base_dir: Dir) !void {
    try createEncryptedPng(io, allocator, base_dir);
    try createEncryptedAudio(io, allocator, base_dir);
    try createSystemJson(io, allocator, base_dir);
    try createPlainPng(io, allocator, base_dir);
}

fn createEncryptedPng(io: std.Io, allocator: std.mem.Allocator, base_dir: Dir) !void {
    try base_dir.createDirPath(io, "data/pics");
    const png_body = "dummy png content " ** 4;
    const offset = 48;
    var file_bytes = try allocator.alloc(u8, decrypter.DEFAULT_HEADER.len + offset + png_body.len);
    defer allocator.free(file_bytes);

    @memcpy(file_bytes[0..16], &decrypter.DEFAULT_HEADER);

    const key = try hexToBytes(allocator, TEST_KEY);
    defer allocator.free(key);

    var payload = file_bytes[16..];
    for (0..offset) |i| {
        payload[i] = @intCast(i);
        if (i < key.len) payload[i] ^= key[i];
    }
    @memcpy(payload[offset..], png_body);

    try base_dir.writeFile(io, .{
        .sub_path = "data/pics/title.rpgmvp",
        .data = file_bytes,
    });
}

fn createEncryptedAudio(io: std.Io, allocator: std.mem.Allocator, base_dir: Dir) !void {
    try base_dir.createDirPath(io, "data/audio");
    const audio_body = "dummy audio data";
    const offset = 48;
    var file_bytes = try allocator.alloc(u8, decrypter.DEFAULT_HEADER.len + offset + audio_body.len);
    defer allocator.free(file_bytes);

    @memcpy(file_bytes[0..16], &decrypter.DEFAULT_HEADER);

    const key = try hexToBytes(allocator, TEST_KEY);
    defer allocator.free(key);

    var payload = file_bytes[16..];
    for (0..offset) |i| {
        payload[i] = @intCast(i);
        if (i < key.len) payload[i] ^= key[i];
    }
    @memcpy(payload[offset..], audio_body);

    try base_dir.writeFile(io, .{
        .sub_path = "data/audio/bgm.rpgmvm",
        .data = file_bytes,
    });
}

fn createSystemJson(io: std.Io, allocator: std.mem.Allocator, base_dir: Dir) !void {
    try base_dir.createDirPath(io, "www/data");
    const json = try std.fmt.allocPrint(allocator,
        \\{{"gameTitle":"TestGame","encryptionKey":"{s}"}}
    , .{TEST_KEY});
    defer allocator.free(json);

    try base_dir.writeFile(io, .{
        .sub_path = "www/data/System.json",
        .data = json,
    });
}

fn createPlainPng(io: std.Io, allocator: std.mem.Allocator, base_dir: Dir) !void {
    try base_dir.createDirPath(io, "data/pics");
    var header_and_body = try allocator.alloc(u8, decrypter.PNG_HEADER.len + 16);
    defer allocator.free(header_and_body);
    @memcpy(header_and_body[0..16], &decrypter.PNG_HEADER);
    @memcpy(header_and_body[16..], (&[_]u8{0xBB} ** 16));

    try base_dir.writeFile(io, .{
        .sub_path = "data/pics/splash.png_",
        .data = header_and_body,
    });
}

pub fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    var bytes = try allocator.alloc(u8, hex.len / 2);
    for (0..bytes.len) |i| {
        bytes[i] = try std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16);
    }
    return bytes;
}
