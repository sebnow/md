const std = @import("std");

pub const Heading = struct {
    depth: u3,
    text: []const u8,
    line: usize,
    source: []const u8 = "",
};

/// Parse ATX headings from markdown content.
/// Returns headings as a slice allocated from the provided allocator.
/// Caller owns the returned slice.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Heading {
    var headings: std.ArrayListUnmanaged(Heading) = .empty;

    var line_num: usize = 1;
    var pos: usize = 0;
    while (pos < content.len) {
        const line_start = pos;
        const line_end = nextLineEnd(content, pos);
        pos = nextLineStart(content, line_end);

        const line = content[line_start..line_end];
        if (parseLine(line)) |heading_info| {
            try headings.append(allocator, .{
                .depth = heading_info.depth,
                .text = heading_info.text,
                .line = line_num,
                .source = line,
            });
        }
        line_num += 1;
    }

    return headings.toOwnedSlice(allocator);
}

const HeadingInfo = struct {
    depth: u3,
    text: []const u8,
};

fn parseLine(line: []const u8) ?HeadingInfo {
    var i: usize = 0;

    // Skip up to 3 leading spaces (CommonMark spec)
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    // Count '#' characters (1-6)
    const hash_start = i;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    const hash_count = i - hash_start;

    if (hash_count == 0 or hash_count > 6) return null;

    // Must be followed by space or end of line
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

    // Skip whitespace after hashes
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // The rest is the heading text, trim trailing whitespace and optional closing hashes
    var end = line.len;
    while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}

    // Remove optional trailing '#' sequence (with optional trailing spaces already removed)
    if (end > i) {
        var trailing = end;
        while (trailing > i and line[trailing - 1] == '#') : (trailing -= 1) {}
        // Closing hashes must be preceded by a space
        if (trailing < end and (trailing == i or line[trailing - 1] == ' ' or line[trailing - 1] == '\t')) {
            end = trailing;
            // Trim trailing whitespace before closing hashes
            while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
        }
    }

    return .{
        .depth = @intCast(hash_count),
        .text = line[i..end],
    };
}

fn nextLineEnd(content: []const u8, pos: usize) usize {
    var i = pos;
    while (i < content.len and content[i] != '\n' and content[i] != '\r') : (i += 1) {}
    return i;
}

fn nextLineStart(content: []const u8, line_end: usize) usize {
    var i = line_end;
    if (i < content.len and content[i] == '\r') i += 1;
    if (i < content.len and content[i] == '\n') i += 1;
    return i;
}

fn expectHeadings(actual: []const Heading, expected: []const Heading) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e.depth, a.depth);
        try std.testing.expectEqualStrings(e.text, a.text);
        try std.testing.expectEqual(e.line, a.line);
    }
}

test "no headings" {
    const result = try parse(std.testing.allocator, "Just some text\nwith no headings\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{});
}

test "single heading" {
    const result = try parse(std.testing.allocator, "# Hello\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "Hello", .line = 1 },
    });
}

test "multiple heading depths" {
    const input = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "H1", .line = 1 },
        .{ .depth = 2, .text = "H2", .line = 2 },
        .{ .depth = 3, .text = "H3", .line = 3 },
        .{ .depth = 4, .text = "H4", .line = 4 },
        .{ .depth = 5, .text = "H5", .line = 5 },
        .{ .depth = 6, .text = "H6", .line = 6 },
    });
}

test "seven hashes not a heading" {
    const result = try parse(std.testing.allocator, "####### Not a heading\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{});
}

test "no space after hash not a heading" {
    const result = try parse(std.testing.allocator, "#NoSpace\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{});
}

test "trailing closing hashes" {
    const result = try parse(std.testing.allocator, "## Hello ##\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 2, .text = "Hello", .line = 1 },
    });
}

test "empty heading" {
    const result = try parse(std.testing.allocator, "## \n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 2, .text = "", .line = 1 },
    });
}

test "heading at end of file without newline" {
    const result = try parse(std.testing.allocator, "# Last");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "Last", .line = 1 },
    });
}

test "headings with interleaved content" {
    const input = "# Title\nSome text\n## Section\nMore text\n### Sub\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "Title", .line = 1 },
        .{ .depth = 2, .text = "Section", .line = 3 },
        .{ .depth = 3, .text = "Sub", .line = 5 },
    });
}

test "up to 3 leading spaces allowed" {
    const result = try parse(std.testing.allocator, "   # Indented\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "Indented", .line = 1 },
    });
}

test "4 leading spaces not a heading" {
    const result = try parse(std.testing.allocator, "    # Code block\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{});
}

test "CRLF line endings" {
    const input = "# First\r\n## Second\r\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "First", .line = 1 },
        .{ .depth = 2, .text = "Second", .line = 2 },
    });
}

test "hash only is empty heading" {
    const result = try parse(std.testing.allocator, "#\n");
    defer std.testing.allocator.free(result);
    try expectHeadings(result, &.{
        .{ .depth = 1, .text = "", .line = 1 },
    });
}
