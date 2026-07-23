const std = @import("std");
const ascii = std.ascii;

pub const NormalExt = enum {
    png,
    m4a,
    ogg,

    pub fn encryptedExt(self: NormalExt, mz: bool) []const u8 {
        return switch (self) {
            .png => if (mz) "png_" else "rpgmvp",
            .m4a => if (mz) "m4a_" else "rpgmvm",
            .ogg => if (mz) "ogg_" else "rpgmvo",
        };
    }

    pub fn fromString(s: []const u8) ?NormalExt {
        if (ascii.eqlIgnoreCase(s, "png")) return .png;
        if (ascii.eqlIgnoreCase(s, "m4a")) return .m4a;
        if (ascii.eqlIgnoreCase(s, "ogg")) return .ogg;
        return null;
    }
};

pub const EncryptedExt = enum {
    rpgmvp,
    png_,
    rpgmvm,
    m4a_,
    rpgmvo,
    ogg_,

    pub fn isPng(self: EncryptedExt) bool {
        return switch (self) {
            .rpgmvp, .png_ => true,
            else => false,
        };
    }

    pub fn normalExt(self: EncryptedExt) []const u8 {
        return switch (self) {
            .rpgmvp, .png_ => "png",
            .rpgmvm, .m4a_ => "m4a",
            .rpgmvo, .ogg_ => "ogg",
        };
    }

    pub fn fromString(s: []const u8) ?EncryptedExt {
        if (ascii.eqlIgnoreCase(s, "rpgmvp")) return .rpgmvp;
        if (ascii.eqlIgnoreCase(s, "png_")) return .png_;
        if (ascii.eqlIgnoreCase(s, "rpgmvm")) return .rpgmvm;
        if (ascii.eqlIgnoreCase(s, "m4a_")) return .m4a_;
        if (ascii.eqlIgnoreCase(s, "rpgmvo")) return .rpgmvo;
        if (ascii.eqlIgnoreCase(s, "ogg_")) return .ogg_;
        return null;
    }
};

pub fn isEncryptedExt(s: []const u8) bool {
    return EncryptedExt.fromString(s) != null;
}

pub fn normalExtension(s: []const u8) []const u8 {
    if (EncryptedExt.fromString(s)) |e| return e.normalExt();
    return s;
}

comptime {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(NormalExt);
}

test "normal extension mapping" {
    const t = std.testing;
    try t.expectEqualStrings("rpgmvp", NormalExt.png.encryptedExt(false));
    try t.expectEqualStrings("png_", NormalExt.png.encryptedExt(true));
    try t.expectEqualStrings("rpgmvm", NormalExt.m4a.encryptedExt(false));
    try t.expectEqualStrings("m4a_", NormalExt.m4a.encryptedExt(true));
    try t.expectEqualStrings("rpgmvo", NormalExt.ogg.encryptedExt(false));
    try t.expectEqualStrings("ogg_", NormalExt.ogg.encryptedExt(true));
}

test "extension mapping" {
    const t = std.testing;
    try t.expectEqualStrings("png", normalExtension("rpgmvp"));
    try t.expectEqualStrings("png", normalExtension("png_"));
    try t.expectEqualStrings("m4a", normalExtension("rpgmvm"));
    try t.expectEqualStrings("m4a", normalExtension("m4a_"));
    try t.expectEqualStrings("ogg", normalExtension("rpgmvo"));
    try t.expectEqualStrings("ogg", normalExtension("ogg_"));
}

test "extension detection" {
    const t = std.testing;
    try t.expect(isEncryptedExt("rpgmvp"));
    try t.expect(isEncryptedExt("PNG_"));
    try t.expect(!isEncryptedExt("png"));
    try t.expect(!isEncryptedExt("txt"));
}
