const std = @import("std");

pub const frontmatter = @import("frontmatter.zig");

test {
    std.testing.refAllDecls(@This());
}
