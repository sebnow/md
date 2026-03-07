const std = @import("std");

pub const NodeType = enum {
    heading,
    paragraph,
    codeblock,
    comment,
    footnote,
};

pub const Node = struct {
    type: NodeType,
    text: []const u8,
    line: usize,
    /// Heading depth (1-6), only valid when type == .heading
    depth: u3 = 0,
    /// Code block language, only valid when type == .codeblock
    language: []const u8 = "",
    /// Comment kind ("html" or "obsidian"), only valid when type == .comment
    kind: []const u8 = "",
    /// Footnote label, only valid when type == .footnote
    label: []const u8 = "",
};

/// Parse the document body into a flat sequence of typed block nodes.
/// Frontmatter is skipped. All string fields reference the input buffer
/// (no copies). The returned slice is allocated from the provided allocator.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Node {
    const body = skipFrontmatter(content);
    var nodes: std.ArrayListUnmanaged(Node) = .empty;

    var line_num: usize = lineOffset(content, body);
    var pos: usize = 0;
    var para_start: ?usize = null;
    var para_line: usize = 0;

    while (pos < body.len) {
        const line_start = pos;
        const line_end = nextLineEnd(body, pos);
        const next = nextLineStart(body, line_end);
        const line = body[line_start..line_end];

        // Blank line: flush paragraph
        if (isBlankLine(line)) {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }
            pos = next;
            line_num += 1;
            continue;
        }

        // Fenced code block
        if (parseFenceOpen(line)) |fence| {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }

            const fence_start_line = line_num;
            const content_start = next;
            var content_end = next;
            pos = next;
            line_num += 1;

            while (pos < body.len) {
                const cl_start = pos;
                const cl_end = nextLineEnd(body, pos);
                pos = nextLineStart(body, cl_end);

                const closing_line = body[cl_start..cl_end];
                if (isClosingFence(closing_line, fence.char, fence.count)) {
                    line_num += 1;
                    break;
                }
                content_end = pos;
                line_num += 1;
            } else {
                content_end = body.len;
            }

            try nodes.append(allocator, .{
                .type = .codeblock,
                .text = body[content_start..content_end],
                .line = fence_start_line,
                .language = fence.language,
            });
            continue;
        }

        // ATX heading
        if (parseHeading(line)) |h| {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }
            try nodes.append(allocator, .{
                .type = .heading,
                .text = h.text,
                .line = line_num,
                .depth = h.depth,
            });
            pos = next;
            line_num += 1;
            continue;
        }

        // HTML comment on its own line(s)
        if (parseBlockHtmlComment(body, line_start)) |comment| {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }
            try nodes.append(allocator, .{
                .type = .comment,
                .text = comment.text,
                .line = line_num,
                .kind = "html",
            });
            line_num += comment.lines_consumed;
            pos = comment.end_pos;
            continue;
        }

        // Obsidian comment on its own line(s)
        if (parseBlockObsidianComment(body, line_start)) |comment| {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }
            try nodes.append(allocator, .{
                .type = .comment,
                .text = comment.text,
                .line = line_num,
                .kind = "obsidian",
            });
            line_num += comment.lines_consumed;
            pos = comment.end_pos;
            continue;
        }

        // Footnote definition
        if (parseFootnote(line)) |fn_info| {
            if (para_start) |ps| {
                try flushParagraph(&nodes, allocator, body, ps, line_start, para_line);
                para_start = null;
            }
            try nodes.append(allocator, .{
                .type = .footnote,
                .text = fn_info.text,
                .line = line_num,
                .label = fn_info.label,
            });
            pos = next;
            line_num += 1;
            continue;
        }

        // Otherwise: paragraph content
        if (para_start == null) {
            para_start = line_start;
            para_line = line_num;
        }
        pos = next;
        line_num += 1;
    }

    // Flush any trailing paragraph
    if (para_start) |ps| {
        try flushParagraph(&nodes, allocator, body, ps, body.len, para_line);
    }

    return nodes.toOwnedSlice(allocator);
}

fn flushParagraph(
    nodes: *std.ArrayListUnmanaged(Node),
    allocator: std.mem.Allocator,
    body: []const u8,
    start: usize,
    end: usize,
    line: usize,
) std.mem.Allocator.Error!void {
    // Trim trailing whitespace/newlines
    var trimmed_end = end;
    while (trimmed_end > start and (body[trimmed_end - 1] == '\n' or body[trimmed_end - 1] == '\r')) {
        trimmed_end -= 1;
    }
    if (trimmed_end > start) {
        try nodes.append(allocator, .{
            .type = .paragraph,
            .text = body[start..trimmed_end],
            .line = line,
        });
    }
}

const HeadingInfo = struct {
    depth: u3,
    text: []const u8,
};

fn parseHeading(line: []const u8) ?HeadingInfo {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    const hash_start = i;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    const hash_count = i - hash_start;

    if (hash_count == 0 or hash_count > 6) return null;
    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    var end = line.len;
    while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}

    if (end > i) {
        var trailing = end;
        while (trailing > i and line[trailing - 1] == '#') : (trailing -= 1) {}
        if (trailing < end and (trailing == i or line[trailing - 1] == ' ' or line[trailing - 1] == '\t')) {
            end = trailing;
            while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
        }
    }

    return .{ .depth = @intCast(hash_count), .text = line[i..end] };
}

const FenceInfo = struct {
    char: u8,
    count: usize,
    language: []const u8,
};

fn parseFenceOpen(line: []const u8) ?FenceInfo {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    if (i >= line.len) return null;
    const fence_char = line[i];
    if (fence_char != '`' and fence_char != '~') return null;

    const fence_start = i;
    while (i < line.len and line[i] == fence_char) : (i += 1) {}
    const fence_count = i - fence_start;

    if (fence_count < 3) return null;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const lang_start = i;
    var lang_end = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') {
        if (fence_char == '`' and line[i] == '`') return null;
        i += 1;
        lang_end = i;
    }

    return .{ .char = fence_char, .count = fence_count, .language = line[lang_start..lang_end] };
}

fn isClosingFence(line: []const u8, fence_char: u8, min_count: usize) bool {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    if (i >= line.len or line[i] != fence_char) return false;

    const fence_start = i;
    while (i < line.len and line[i] == fence_char) : (i += 1) {}
    const fence_count = i - fence_start;

    if (fence_count < min_count) return false;

    while (i < line.len) {
        if (line[i] != ' ' and line[i] != '\t') return false;
        i += 1;
    }
    return true;
}

const BlockComment = struct {
    text: []const u8,
    end_pos: usize,
    lines_consumed: usize,
};

fn parseBlockHtmlComment(body: []const u8, pos: usize) ?BlockComment {
    // Must start with <!-- at line beginning (after optional whitespace)
    var i = pos;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}

    if (i + 4 > body.len) return null;
    if (!std.mem.eql(u8, body[i .. i + 4], "<!--")) return null;

    // Check nothing before the marker except whitespace
    const text_start = i + 4;
    // Find -->
    var search = text_start;
    while (search + 3 <= body.len) {
        if (std.mem.eql(u8, body[search .. search + 3], "-->")) {
            const comment_end = search + 3;
            // Verify the rest of the closing line is blank
            var after = comment_end;
            while (after < body.len and body[after] != '\n' and body[after] != '\r') {
                if (body[after] != ' ' and body[after] != '\t') return null;
                after += 1;
            }
            // Advance past line ending
            if (after < body.len and body[after] == '\r') after += 1;
            if (after < body.len and body[after] == '\n') after += 1;

            const text = std.mem.trim(u8, body[text_start..search], " \t\r\n");
            var lines: usize = 1;
            for (body[pos..comment_end]) |c| {
                if (c == '\n') lines += 1;
            }
            return .{ .text = text, .end_pos = after, .lines_consumed = lines };
        }
        search += 1;
    }
    return null;
}

fn parseBlockObsidianComment(body: []const u8, pos: usize) ?BlockComment {
    var i = pos;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}

    if (i + 2 > body.len) return null;
    if (!std.mem.eql(u8, body[i .. i + 2], "%%")) return null;

    const text_start = i + 2;
    var search = text_start;
    while (search + 2 <= body.len) {
        if (std.mem.eql(u8, body[search .. search + 2], "%%")) {
            const comment_end = search + 2;
            var after = comment_end;
            while (after < body.len and body[after] != '\n' and body[after] != '\r') {
                if (body[after] != ' ' and body[after] != '\t') return null;
                after += 1;
            }
            if (after < body.len and body[after] == '\r') after += 1;
            if (after < body.len and body[after] == '\n') after += 1;

            const text = std.mem.trim(u8, body[text_start..search], " \t\r\n");
            var lines: usize = 1;
            for (body[pos..comment_end]) |c| {
                if (c == '\n') lines += 1;
            }
            return .{ .text = text, .end_pos = after, .lines_consumed = lines };
        }
        search += 1;
    }
    return null;
}

const FootnoteInfo = struct {
    label: []const u8,
    text: []const u8,
};

fn parseFootnote(line: []const u8) ?FootnoteInfo {
    if (line.len < 4) return null;
    if (line[0] != '[' or line[1] != '^') return null;

    var i: usize = 2;
    while (i < line.len and line[i] != ']') : (i += 1) {}
    if (i >= line.len) return null;

    const label = line[2..i];
    if (label.len == 0) return null;

    i += 1;
    if (i >= line.len or line[i] != ':') return null;
    i += 1;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    return .{ .label = label, .text = line[i..] };
}

fn skipFrontmatter(content: []const u8) []const u8 {
    const delimiters = [_][]const u8{ "---", "+++" };
    for (delimiters) |delim| {
        if (skipDelimiter(content, 0, delim)) |after_opening| {
            var pos = after_opening;
            while (pos < content.len) {
                if (skipDelimiter(content, pos, delim)) |after_closing| {
                    return content[after_closing..];
                }
                pos = nextLine(content, pos);
            }
            return "";
        }
    }
    return content;
}

fn skipDelimiter(content: []const u8, pos: usize, delim: []const u8) ?usize {
    if (content.len < pos + delim.len) return null;
    if (!std.mem.eql(u8, content[pos .. pos + delim.len], delim)) return null;

    var i = pos + delim.len;
    if (i < content.len and content[i] == delim[0]) return null;
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}

    if (i == content.len) return i;
    if (content[i] == '\n') return i + 1;
    if (content[i] == '\r') {
        i += 1;
        if (i < content.len and content[i] == '\n') i += 1;
        return i;
    }
    return null;
}

fn nextLine(content: []const u8, pos: usize) usize {
    var i = pos;
    while (i < content.len and content[i] != '\n') : (i += 1) {}
    if (i < content.len) i += 1;
    return i;
}

/// Count lines in content up to the start of the body slice.
fn lineOffset(content: []const u8, body: []const u8) usize {
    const body_start = @intFromPtr(body.ptr) - @intFromPtr(content.ptr);
    var line: usize = 1;
    for (content[0..body_start]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
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

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

// Tests

const testing = std.testing;

fn expectNodes(actual: []const Node, expected: []const Node) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.type, a.type);
        try testing.expectEqualStrings(e.text, a.text);
        try testing.expectEqual(e.line, a.line);
        if (e.type == .heading) try testing.expectEqual(e.depth, a.depth);
        if (e.type == .codeblock) try testing.expectEqualStrings(e.language, a.language);
        if (e.type == .comment) try testing.expectEqualStrings(e.kind, a.kind);
        if (e.type == .footnote) try testing.expectEqualStrings(e.label, a.label);
    }
}

test "empty document" {
    const result = try parse(testing.allocator, "");
    defer testing.allocator.free(result);
    try expectNodes(result, &.{});
}

test "single paragraph" {
    const result = try parse(testing.allocator, "Hello world.\n");
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "Hello world.", .line = 1 },
    });
}

test "heading" {
    const result = try parse(testing.allocator, "# Title\n");
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .heading, .text = "Title", .line = 1, .depth = 1 },
    });
}

test "heading then paragraph" {
    const input =
        \\# Title
        \\
        \\Some text here.
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .heading, .text = "Title", .line = 1, .depth = 1 },
        .{ .type = .paragraph, .text = "Some text here.", .line = 3 },
    });
}

test "multi-line paragraph" {
    const input =
        \\First line.
        \\Second line.
        \\Third line.
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "First line.\nSecond line.\nThird line.", .line = 1 },
    });
}

test "two paragraphs separated by blank line" {
    const input =
        \\First para.
        \\
        \\Second para.
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "First para.", .line = 1 },
        .{ .type = .paragraph, .text = "Second para.", .line = 3 },
    });
}

test "fenced code block" {
    const input =
        \\```go
        \\func main() {}
        \\```
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .codeblock, .text = "func main() {}\n", .line = 1, .language = "go" },
    });
}

test "code block without language" {
    const input =
        \\```
        \\some code
        \\```
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .codeblock, .text = "some code\n", .line = 1, .language = "" },
    });
}

test "unclosed code block" {
    const input =
        \\```go
        \\func main() {}
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .codeblock, .text = "func main() {}\n", .line = 1, .language = "go" },
    });
}

test "html comment block" {
    const input =
        \\<!-- a comment -->
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .comment, .text = "a comment", .line = 1, .kind = "html" },
    });
}

test "obsidian comment block" {
    const input =
        \\%% obsidian note %%
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .comment, .text = "obsidian note", .line = 1, .kind = "obsidian" },
    });
}

test "multiline html comment" {
    const input =
        \\<!-- multi
        \\line comment -->
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .comment, .text = "multi\nline comment", .line = 1, .kind = "html" },
    });
}

test "multiline obsidian comment" {
    const input =
        \\%% begin notes
        \\some content
        \\end notes %%
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .comment, .text = "begin notes\nsome content\nend notes", .line = 1, .kind = "obsidian" },
    });
}

test "footnote" {
    const result = try parse(testing.allocator, "[^1]: See the paper.\n");
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .footnote, .text = "See the paper.", .line = 1, .label = "1" },
    });
}

test "frontmatter is skipped" {
    const input =
        \\---
        \\title: Test
        \\---
        \\# Title
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .heading, .text = "Title", .line = 4, .depth = 1 },
    });
}

test "mixed document" {
    const input =
        \\---
        \\title: Test
        \\---
        \\# Introduction
        \\
        \\Some text here.
        \\
        \\## Methods
        \\
        \\```go
        \\func main() {}
        \\```
        \\
        \\<!-- TODO: add more -->
        \\
        \\More text.
        \\
        \\[^1]: A footnote.
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .heading, .text = "Introduction", .line = 4, .depth = 1 },
        .{ .type = .paragraph, .text = "Some text here.", .line = 6 },
        .{ .type = .heading, .text = "Methods", .line = 8, .depth = 2 },
        .{ .type = .codeblock, .text = "func main() {}\n", .line = 10, .language = "go" },
        .{ .type = .comment, .text = "TODO: add more", .line = 14, .kind = "html" },
        .{ .type = .paragraph, .text = "More text.", .line = 16 },
        .{ .type = .footnote, .text = "A footnote.", .line = 18, .label = "1" },
    });
}

test "heading interrupts paragraph" {
    const input =
        \\Some text.
        \\# Heading
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "Some text.", .line = 1 },
        .{ .type = .heading, .text = "Heading", .line = 2, .depth = 1 },
    });
}

test "code block interrupts paragraph" {
    const input =
        \\Some text.
        \\```
        \\code
        \\```
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "Some text.", .line = 1 },
        .{ .type = .codeblock, .text = "code\n", .line = 2, .language = "" },
    });
}

test "paragraph without trailing newline" {
    const result = try parse(testing.allocator, "No trailing newline");
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "No trailing newline", .line = 1 },
    });
}

test "tilde fenced code block" {
    const input =
        \\~~~python
        \\print('hi')
        \\~~~
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .codeblock, .text = "print('hi')\n", .line = 1, .language = "python" },
    });
}

test "inline comment not treated as block comment" {
    const input = "Some text <!-- inline --> more text.\n";
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    // The inline comment is part of the paragraph, not a separate node
    try expectNodes(result, &.{
        .{ .type = .paragraph, .text = "Some text <!-- inline --> more text.", .line = 1 },
    });
}

test "multiple headings at different depths" {
    const input =
        \\# H1
        \\## H2
        \\### H3
        \\
    ;
    const result = try parse(testing.allocator, input);
    defer testing.allocator.free(result);
    try expectNodes(result, &.{
        .{ .type = .heading, .text = "H1", .line = 1, .depth = 1 },
        .{ .type = .heading, .text = "H2", .line = 2, .depth = 2 },
        .{ .type = .heading, .text = "H3", .line = 3, .depth = 3 },
    });
}
