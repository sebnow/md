const std = @import("std");

pub const Footnote = struct {
    label: []const u8,
    text: []const u8,
    line: usize,
};

/// Parse footnote definitions (`[^label]: text`) from markdown content.
/// Returns footnotes as a slice allocated from the provided allocator.
/// All string fields reference the input buffer.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Footnote {
    var footnotes: std.ArrayListUnmanaged(Footnote) = .empty;

    var line_num: usize = 1;
    var pos: usize = 0;
    while (pos < content.len) {
        const line_start = pos;
        const line_end = nextLineEnd(content, pos);
        pos = nextLineStart(content, line_end);

        const line = content[line_start..line_end];
        if (parseLine(line)) |fn_info| {
            try footnotes.append(allocator, .{
                .label = fn_info.label,
                .text = fn_info.text,
                .line = line_num,
            });
        }
        line_num += 1;
    }

    return footnotes.toOwnedSlice(allocator);
}

const FootnoteInfo = struct {
    label: []const u8,
    text: []const u8,
};

fn parseLine(line: []const u8) ?FootnoteInfo {
    // Must start with [^
    if (line.len < 4) return null; // minimum: [^x]:
    if (line[0] != '[' or line[1] != '^') return null;

    // Find closing ]
    var i: usize = 2;
    while (i < line.len and line[i] != ']') : (i += 1) {}
    if (i >= line.len) return null;

    const label = line[2..i];
    if (label.len == 0) return null;

    i += 1; // skip ]

    // Must be followed by :
    if (i >= line.len or line[i] != ':') return null;
    i += 1; // skip :

    // Skip whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const text = line[i..];
    return .{ .label = label, .text = text };
}

fn nextLineEnd(content: []const u8, pos: usize) usize {
    var p = pos;
    while (p < content.len and content[p] != '\n') : (p += 1) {}
    return p;
}

fn nextLineStart(content: []const u8, line_end: usize) usize {
    if (line_end < content.len and content[line_end] == '\n') return line_end + 1;
    return line_end;
}

// Tests

const testing = std.testing;

test "no footnotes" {
    const result = try parse(testing.allocator, "# Hello\nSome text.\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "single footnote" {
    const result = try parse(testing.allocator, "[^1]: See the original paper.\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("1", result[0].label);
    try testing.expectEqualStrings("See the original paper.", result[0].text);
    try testing.expectEqual(@as(usize, 1), result[0].line);
}

test "named footnote" {
    const result = try parse(testing.allocator, "[^note]: This was later disproven.\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("note", result[0].label);
    try testing.expectEqualStrings("This was later disproven.", result[0].text);
}

test "multiple footnotes" {
    const content =
        \\Some text.
        \\
        \\[^1]: First footnote.
        \\[^2]: Second footnote.
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("1", result[0].label);
    try testing.expectEqual(@as(usize, 3), result[0].line);
    try testing.expectEqualStrings("2", result[1].label);
    try testing.expectEqual(@as(usize, 4), result[1].line);
}

test "footnote with no text" {
    const result = try parse(testing.allocator, "[^empty]:\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("empty", result[0].label);
    try testing.expectEqualStrings("", result[0].text);
}

test "not a footnote: no caret" {
    const result = try parse(testing.allocator, "[1]: not a footnote\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "not a footnote: no colon" {
    const result = try parse(testing.allocator, "[^label] no colon\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "footnote with extra whitespace" {
    const result = try parse(testing.allocator, "[^ws]:   spaced out\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("spaced out", result[0].text);
}

test "footnote among other content" {
    const content =
        \\# Title
        \\
        \\Some text with [^ref] reference.
        \\
        \\[^ref]: The reference text.
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("ref", result[0].label);
    try testing.expectEqual(@as(usize, 5), result[0].line);
}
