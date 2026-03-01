const std = @import("std");

pub const LinkKind = enum {
    standard,
    image,
    wikilink,
    embed,
};

pub const Link = struct {
    kind: LinkKind,
    target: []const u8,
    text: []const u8,
    line: usize,
};

/// Parse all links from markdown content.
/// Returns links as a slice allocated from the provided allocator.
/// All string fields reference the input buffer — no string copies.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Link {
    var links: std.ArrayListUnmanaged(Link) = .empty;

    var line_num: usize = 1;
    var pos: usize = 0;
    while (pos < content.len) {
        if (content[pos] == '\n') {
            line_num += 1;
            pos += 1;
            continue;
        }

        // Try wikilink/embed: ![[...]] or [[...]]
        if (parseWikilink(content, pos)) |result| {
            try links.append(allocator, .{
                .kind = result.kind,
                .target = result.target,
                .text = result.text,
                .line = line_num,
            });
            pos = result.end;
            continue;
        }

        // Try image/standard link: ![...](...) or [...](...)]
        if (parseStandardLink(content, pos)) |result| {
            try links.append(allocator, .{
                .kind = result.kind,
                .target = result.target,
                .text = result.text,
                .line = line_num,
            });
            pos = result.end;
            continue;
        }

        pos += 1;
    }

    return links.toOwnedSlice(allocator);
}

const ParseResult = struct {
    kind: LinkKind,
    target: []const u8,
    text: []const u8,
    end: usize,
};

fn parseWikilink(content: []const u8, pos: usize) ?ParseResult {
    var i = pos;
    var kind: LinkKind = .wikilink;

    if (i < content.len and content[i] == '!') {
        kind = .embed;
        i += 1;
    }

    if (i + 1 >= content.len or content[i] != '[' or content[i + 1] != '[') return null;
    i += 2;

    const target_start = i;

    // Find closing ]]  — wikilinks cannot span lines
    while (i < content.len and content[i] != '\n' and content[i] != '\r') {
        if (i + 1 < content.len and content[i] == ']' and content[i + 1] == ']') {
            const inner = content[target_start..i];

            // Check for pipe alias: [[target|alias]]
            if (std.mem.indexOfScalar(u8, inner, '|')) |pipe_pos| {
                return .{
                    .kind = kind,
                    .target = inner[0..pipe_pos],
                    .text = inner[pipe_pos + 1 ..],
                    .end = i + 2,
                };
            }

            return .{
                .kind = kind,
                .target = inner,
                .text = inner,
                .end = i + 2,
            };
        }
        i += 1;
    }

    // No closing ]] found — not a valid wikilink
    return null;
}

fn parseStandardLink(content: []const u8, pos: usize) ?ParseResult {
    var i = pos;
    var kind: LinkKind = .standard;

    if (i < content.len and content[i] == '!') {
        kind = .image;
        i += 1;
    }

    if (i >= content.len or content[i] != '[') return null;
    i += 1;

    const text_start = i;

    // Find closing ] — allow nested content but not newlines for lax parsing
    var bracket_depth: usize = 1;
    while (i < content.len and content[i] != '\n' and content[i] != '\r') {
        if (content[i] == '[') {
            bracket_depth += 1;
        } else if (content[i] == ']') {
            bracket_depth -= 1;
            if (bracket_depth == 0) break;
        }
        i += 1;
    }

    if (bracket_depth != 0) return null;
    const text_end = i;
    i += 1; // skip ]

    // Must be immediately followed by (
    if (i >= content.len or content[i] != '(') return null;
    i += 1;

    const url_start = i;

    // Find closing ) — no newlines
    while (i < content.len and content[i] != '\n' and content[i] != '\r' and content[i] != ')') {
        i += 1;
    }

    if (i >= content.len or content[i] != ')') return null;
    const url_end = i;
    i += 1; // skip )

    return .{
        .kind = kind,
        .target = content[url_start..url_end],
        .text = content[text_start..text_end],
        .end = i,
    };
}

fn expectLinks(actual: []const Link, expected: []const Link) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e.kind, a.kind);
        try std.testing.expectEqualStrings(e.target, a.target);
        try std.testing.expectEqualStrings(e.text, a.text);
        try std.testing.expectEqual(e.line, a.line);
    }
}

test "no links" {
    const result = try parse(std.testing.allocator, "Just some text\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{});
}

test "standard link" {
    const result = try parse(std.testing.allocator, "See [click here](https://example.com) for info\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .standard, .target = "https://example.com", .text = "click here", .line = 1 },
    });
}

test "image link" {
    const result = try parse(std.testing.allocator, "![alt text](image.png)\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .image, .target = "image.png", .text = "alt text", .line = 1 },
    });
}

test "wikilink" {
    const result = try parse(std.testing.allocator, "See [[other note]] for details\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .wikilink, .target = "other note", .text = "other note", .line = 1 },
    });
}

test "wikilink with alias" {
    const result = try parse(std.testing.allocator, "See [[target|display text]] here\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .wikilink, .target = "target", .text = "display text", .line = 1 },
    });
}

test "embed wikilink" {
    const result = try parse(std.testing.allocator, "![[embedded note]]\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .embed, .target = "embedded note", .text = "embedded note", .line = 1 },
    });
}

test "relative file link" {
    const result = try parse(std.testing.allocator, "[doc](./path/to/file.md)\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .standard, .target = "./path/to/file.md", .text = "doc", .line = 1 },
    });
}

test "multiple links on different lines" {
    const input = "# Title\n[a](b.md)\ntext\n[[c]]\n![d](e.png)\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .standard, .target = "b.md", .text = "a", .line = 2 },
        .{ .kind = .wikilink, .target = "c", .text = "c", .line = 4 },
        .{ .kind = .image, .target = "e.png", .text = "d", .line = 5 },
    });
}

test "multiple links on same line" {
    const input = "See [a](b) and [[c]] here\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .standard, .target = "b", .text = "a", .line = 1 },
        .{ .kind = .wikilink, .target = "c", .text = "c", .line = 1 },
    });
}

test "unclosed bracket not a link" {
    const result = try parse(std.testing.allocator, "[incomplete(url)\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{});
}

test "bracket without parens not a link" {
    const result = try parse(std.testing.allocator, "[text] no parens\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{});
}

test "unclosed wikilink not a link" {
    const result = try parse(std.testing.allocator, "[[unclosed\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{});
}

test "empty wikilink" {
    const result = try parse(std.testing.allocator, "[[]]\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .wikilink, .target = "", .text = "", .line = 1 },
    });
}

test "wikilink with heading anchor" {
    const result = try parse(std.testing.allocator, "[[page#section]]\n");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .wikilink, .target = "page#section", .text = "page#section", .line = 1 },
    });
}

test "link at end of file without newline" {
    const result = try parse(std.testing.allocator, "[[note]]");
    defer std.testing.allocator.free(result);
    try expectLinks(result, &.{
        .{ .kind = .wikilink, .target = "note", .text = "note", .line = 1 },
    });
}
