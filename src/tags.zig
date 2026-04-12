const std = @import("std");

pub const Tag = struct {
    name: []const u8,
    line: usize,
    source: []const u8 = "",
};

/// Parse inline #tags from markdown content.
/// Tags must start with # followed by alphanumeric characters, hyphens,
/// underscores, or forward slashes (for nested tags like #project/sub).
/// Tags must be preceded by whitespace or start of line to avoid matching
/// headings or anchor links.
/// Returns deduplicated tags allocated from the provided allocator.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Tag {
    var tags: std.ArrayListUnmanaged(Tag) = .empty;
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var line_num: usize = 1;
    var pos: usize = 0;
    while (pos < content.len) {
        if (content[pos] == '\n') {
            line_num += 1;
            pos += 1;
            continue;
        }

        if (content[pos] == '#') {
            // Must be preceded by whitespace or start of line
            const preceded_by_space = pos == 0 or
                content[pos - 1] == ' ' or
                content[pos - 1] == '\t' or
                content[pos - 1] == '\n' or
                content[pos - 1] == '\r';

            if (preceded_by_space) {
                const tag_start = pos + 1;
                var tag_end = tag_start;

                // Skip heading hashes (## etc.)
                if (tag_end < content.len and content[tag_end] == '#') {
                    pos += 1;
                    continue;
                }

                while (tag_end < content.len and isTagChar(content[tag_end])) : (tag_end += 1) {}

                if (tag_end > tag_start) {
                    const name = content[tag_start..tag_end];
                    const entry = try seen.getOrPut(allocator, name);
                    if (!entry.found_existing) {
                        try tags.append(allocator, .{
                            .name = name,
                            .line = line_num,
                            .source = content[pos..tag_end],
                        });
                    }
                    pos = tag_end;
                    continue;
                }
            }
        }

        pos += 1;
    }

    return tags.toOwnedSlice(allocator);
}

fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/';
}

fn expectTags(actual: []const Tag, expected: []const Tag) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqualStrings(e.name, a.name);
        try std.testing.expectEqual(e.line, a.line);
    }
}

test "no tags" {
    const result = try parse(std.testing.allocator, "Just some text\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{});
}

test "single tag" {
    const result = try parse(std.testing.allocator, "Hello #world\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "world", .line = 1 },
    });
}

test "tag at start of line" {
    const result = try parse(std.testing.allocator, "#tag\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "tag", .line = 1 },
    });
}

test "multiple tags" {
    const input = "#first some text #second\nmore #third\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "first", .line = 1 },
        .{ .name = "second", .line = 1 },
        .{ .name = "third", .line = 2 },
    });
}

test "deduplicated tags" {
    const input = "#dup text #dup\n#dup again\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "dup", .line = 1 },
    });
}

test "nested tag with slash" {
    const result = try parse(std.testing.allocator, "#project/sub-task\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "project/sub-task", .line = 1 },
    });
}

test "tag with hyphen and underscore" {
    const result = try parse(std.testing.allocator, "#my-tag_v2\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "my-tag_v2", .line = 1 },
    });
}

test "heading not a tag" {
    const result = try parse(std.testing.allocator, "## Heading\n### Another\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{});
}

test "hash in middle of word not a tag" {
    const result = try parse(std.testing.allocator, "foo#bar\n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{});
}

test "bare hash not a tag" {
    const result = try parse(std.testing.allocator, "# \n");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{});
}

test "tag at end of file without newline" {
    const result = try parse(std.testing.allocator, "text #final");
    defer std.testing.allocator.free(result);
    try expectTags(result, &.{
        .{ .name = "final", .line = 1 },
    });
}
