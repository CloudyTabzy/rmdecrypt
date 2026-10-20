//! Library surface of the core, for tools that link it without the CLI or
//! GUI front ends (see `bench/`).

pub const decrypter = @import("decrypter.zig");
pub const extensions = @import("extensions.zig");
pub const key_detect = @import("key_detect.zig");
pub const processor = @import("processor.zig");
