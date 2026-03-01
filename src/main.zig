const std = @import("std");

pub fn main() !void {
    var buf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    try stderr.interface.print("md: not yet implemented\n", .{});
    try stderr.interface.flush();
    std.process.exit(1);
}
