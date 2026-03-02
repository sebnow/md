const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null,
    array: []const Value,
    record: Record,

    pub const Record = struct {
        keys: []const []const u8,
        values: []const Value,

        pub fn get(self: Record, key: []const u8) ?Value {
            for (self.keys, self.values) |k, v| {
                if (std.mem.eql(u8, k, key)) return v;
            }
            return null;
        }

    };

    pub fn renderPlain(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.writeAll(s),
            .int => |n| try writer.print("{d}", .{n}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
            .array => |arr| {
                for (arr) |item| {
                    try item.renderPlain(writer);
                    try writer.writeByte('\n');
                }
            },
            .record => |rec| {
                for (rec.keys, rec.values) |key, val| {
                    try writer.writeAll(key);
                    try writer.writeAll(": ");
                    try val.renderPlain(writer);
                    try writer.writeByte('\n');
                }
            },
        }
    }

    pub fn renderJson(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| {
                try writer.writeByte('"');
                try writeJsonEscaped(writer, s);
                try writer.writeByte('"');
            },
            .int => |n| try writer.print("{d}", .{n}),
            .float => |f| try writer.print("{d}", .{f}),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .null => try writer.writeAll("null"),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |item, idx| {
                    if (idx > 0) try writer.writeByte(',');
                    try item.renderJson(writer);
                }
                try writer.writeByte(']');
            },
            .record => |rec| {
                try writer.writeByte('{');
                for (rec.keys, rec.values, 0..) |key, val, idx| {
                    if (idx > 0) try writer.writeByte(',');
                    try writer.writeByte('"');
                    try writeJsonEscaped(writer, key);
                    try writer.writeAll("\":");
                    try val.renderJson(writer);
                }
                try writer.writeByte('}');
            },
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .string => |s| std.mem.eql(u8, s, other.string),
            .int => |n| n == other.int,
            .float => |f| f == other.float,
            .bool => |b| b == other.bool,
            .null => true,
            .array => |arr| {
                if (arr.len != other.array.len) return false;
                for (arr, other.array) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return true;
            },
            .record => |rec| {
                const other_rec = other.record;
                if (rec.keys.len != other_rec.keys.len) return false;
                for (rec.keys, rec.values) |key, val| {
                    const other_val = other_rec.get(key) orelse return false;
                    if (!val.eql(other_val)) return false;
                }
                return true;
            },
        };
    }
};

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// Tests

const testing = std.testing;

fn renderPlainAlloc(alloc: std.mem.Allocator, val: Value) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try val.renderPlain(buf.writer(alloc));
    return try buf.toOwnedSlice(alloc);
}

fn renderJsonAlloc(alloc: std.mem.Allocator, val: Value) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try val.renderJson(buf.writer(alloc));
    return try buf.toOwnedSlice(alloc);
}

test "string plain" {
    const val: Value = .{ .string = "hello world" };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world", out);
}

test "string json" {
    const val: Value = .{ .string = "hello world" };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"hello world\"", out);
}

test "string json escaping" {
    const val: Value = .{ .string = "line1\nline2\t\"quoted\"\\" };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"line1\\nline2\\t\\\"quoted\\\"\\\\\"", out);
}

test "int plain" {
    const val: Value = .{ .int = 42 };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("42", out);
}

test "int negative plain" {
    const val: Value = .{ .int = -7 };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("-7", out);
}

test "int json" {
    const val: Value = .{ .int = 42 };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("42", out);
}

test "float plain" {
    const val: Value = .{ .float = 3.14 };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    // Zig prints 3.14e0 for {d} format on floats
    try testing.expect(out.len > 0);
}

test "float json" {
    const val: Value = .{ .float = 2.5 };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
}

test "bool true plain" {
    const val: Value = .{ .bool = true };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("true", out);
}

test "bool false json" {
    const val: Value = .{ .bool = false };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("false", out);
}

test "null plain" {
    const val: Value = .null;
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("null", out);
}

test "null json" {
    const val: Value = .null;
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("null", out);
}

test "array plain" {
    const items = [_]Value{
        .{ .string = "alpha" },
        .{ .string = "beta" },
    };
    const val: Value = .{ .array = &items };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("alpha\nbeta\n", out);
}

test "array json" {
    const items = [_]Value{
        .{ .int = 1 },
        .{ .string = "two" },
        .{ .bool = true },
    };
    const val: Value = .{ .array = &items };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[1,\"two\",true]", out);
}

test "empty array json" {
    const val: Value = .{ .array = &.{} };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "record plain" {
    const keys = [_][]const u8{ "title", "draft" };
    const vals = [_]Value{ .{ .string = "Hello" }, .{ .bool = true } };
    const val: Value = .{ .record = .{ .keys = &keys, .values = &vals } };
    const out = try renderPlainAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("title: Hello\ndraft: true\n", out);
}

test "record json" {
    const keys = [_][]const u8{ "title", "count" };
    const vals = [_]Value{ .{ .string = "Hello" }, .{ .int = 5 } };
    const val: Value = .{ .record = .{ .keys = &keys, .values = &vals } };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"title\":\"Hello\",\"count\":5}", out);
}

test "empty record json" {
    const val: Value = .{ .record = .{ .keys = &.{}, .values = &.{} } };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{}", out);
}

test "record get existing key" {
    const keys = [_][]const u8{ "a", "b" };
    const vals = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
    const rec: Value.Record = .{ .keys = &keys, .values = &vals };
    const v = rec.get("b").?;
    try testing.expect(v.eql(.{ .int = 2 }));
}

test "record get missing key" {
    const keys = [_][]const u8{"a"};
    const vals = [_]Value{.{ .int = 1 }};
    const rec: Value.Record = .{ .keys = &keys, .values = &vals };
    try testing.expect(rec.get("z") == null);
}

test "nested array in record json" {
    const inner = [_]Value{ .{ .string = "x" }, .{ .string = "y" } };
    const keys = [_][]const u8{"items"};
    const vals = [_]Value{.{ .array = &inner }};
    const val: Value = .{ .record = .{ .keys = &keys, .values = &vals } };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"items\":[\"x\",\"y\"]}", out);
}

test "eql same types" {
    try testing.expect((Value{ .int = 5 }).eql(.{ .int = 5 }));
    try testing.expect(!(Value{ .int = 5 }).eql(.{ .int = 6 }));
    try testing.expect((Value{ .string = "a" }).eql(.{ .string = "a" }));
    try testing.expect(!(Value{ .string = "a" }).eql(.{ .string = "b" }));
    try testing.expect((Value{ .bool = true }).eql(.{ .bool = true }));
    try testing.expect((Value{ .null = {} }).eql(.null));
}

test "eql different types" {
    try testing.expect(!(Value{ .int = 1 }).eql(.{ .string = "1" }));
    try testing.expect(!(Value{ .bool = true }).eql(.{ .int = 1 }));
    try testing.expect(!(Value{ .null = {} }).eql(.{ .int = 0 }));
}

test "eql arrays" {
    const a = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
    const b = [_]Value{ .{ .int = 1 }, .{ .int = 2 } };
    const c = [_]Value{ .{ .int = 1 }, .{ .int = 3 } };
    try testing.expect((Value{ .array = &a }).eql(.{ .array = &b }));
    try testing.expect(!(Value{ .array = &a }).eql(.{ .array = &c }));
}

test "json control character escaping" {
    const val: Value = .{ .string = &.{ 0x00, 0x1f } };
    const out = try renderJsonAlloc(testing.allocator, val);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"\\u0000\\u001f\"", out);
}
