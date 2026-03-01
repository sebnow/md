const std = @import("std");

pub const CodeBlock = struct {
    language: []const u8,
    content: []const u8,
    start_line: usize,
    end_line: usize,
};

/// Parse fenced code blocks from markdown content.
/// Supports both backtick (```) and tilde (~~~) fences.
/// Returns code blocks as a slice allocated from the provided allocator.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const CodeBlock {
    var blocks: std.ArrayListUnmanaged(CodeBlock) = .empty;

    var line_num: usize = 1;
    var pos: usize = 0;
    while (pos < content.len) {
        const line_start = pos;
        const line_end = nextLineEnd(content, pos);
        const next = nextLineStart(content, line_end);

        const line = content[line_start..line_end];
        if (parseFenceOpen(line)) |fence| {
            const content_start_line = line_num + 1;
            const content_start = next;
            var content_end = next;
            var end_line = content_start_line;
            pos = next;

            // Scan for closing fence
            while (pos < content.len) {
                const cl_start = pos;
                const cl_end = nextLineEnd(content, pos);
                pos = nextLineStart(content, cl_end);
                line_num += 1;

                const closing_line = content[cl_start..cl_end];
                if (isClosingFence(closing_line, fence.char, fence.count)) {
                    end_line = line_num;
                    break;
                }
                content_end = pos;
            } else {
                // Unclosed fence — lax: treat rest of file as code block content
                content_end = content.len;
                end_line = line_num;
            }

            try blocks.append(allocator, .{
                .language = fence.language,
                .content = content[content_start..content_end],
                .start_line = content_start_line - 1, // line of the opening fence
                .end_line = end_line,
            });

            line_num += 1;
            continue;
        }

        pos = next;
        line_num += 1;
    }

    return blocks.toOwnedSlice(allocator);
}

const FenceInfo = struct {
    char: u8,
    count: usize,
    language: []const u8,
};

fn parseFenceOpen(line: []const u8) ?FenceInfo {
    var i: usize = 0;

    // Skip up to 3 leading spaces
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    if (i >= line.len) return null;
    const fence_char = line[i];
    if (fence_char != '`' and fence_char != '~') return null;

    const fence_start = i;
    while (i < line.len and line[i] == fence_char) : (i += 1) {}
    const fence_count = i - fence_start;

    if (fence_count < 3) return null;

    // Skip whitespace before language
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Backtick fences cannot contain backticks in the info string
    const lang_start = i;
    var lang_end = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') {
        if (fence_char == '`' and line[i] == '`') return null;
        i += 1;
        lang_end = i;
    }

    return .{
        .char = fence_char,
        .count = fence_count,
        .language = line[lang_start..lang_end],
    };
}

fn isClosingFence(line: []const u8, fence_char: u8, min_count: usize) bool {
    var i: usize = 0;

    // Skip up to 3 leading spaces
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}

    if (i >= line.len or line[i] != fence_char) return false;

    const fence_start = i;
    while (i < line.len and line[i] == fence_char) : (i += 1) {}
    const fence_count = i - fence_start;

    if (fence_count < min_count) return false;

    // Only trailing whitespace allowed
    while (i < line.len) {
        if (line[i] != ' ' and line[i] != '\t') return false;
        i += 1;
    }

    return true;
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

fn expectBlocks(actual: []const CodeBlock, expected: []const CodeBlock) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqualStrings(e.language, a.language);
        try std.testing.expectEqualStrings(e.content, a.content);
        try std.testing.expectEqual(e.start_line, a.start_line);
        try std.testing.expectEqual(e.end_line, a.end_line);
    }
}

test "no code blocks" {
    const result = try parse(std.testing.allocator, "Just text\n");
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{});
}

test "basic backtick code block" {
    const input = "```\nhello\n```\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "", .content = "hello\n", .start_line = 1, .end_line = 3 },
    });
}

test "code block with language" {
    const input = "```zig\nconst x = 1;\n```\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "zig", .content = "const x = 1;\n", .start_line = 1, .end_line = 3 },
    });
}

test "tilde fence" {
    const input = "~~~python\nprint('hi')\n~~~\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "python", .content = "print('hi')\n", .start_line = 1, .end_line = 3 },
    });
}

test "unclosed code block" {
    const input = "```go\nfunc main() {}\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "go", .content = "func main() {}\n", .start_line = 1, .end_line = 2 },
    });
}

test "multiple code blocks" {
    const input = "```js\na\n```\ntext\n```py\nb\n```\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "js", .content = "a\n", .start_line = 1, .end_line = 3 },
        .{ .language = "py", .content = "b\n", .start_line = 5, .end_line = 7 },
    });
}

test "closing fence needs at least same count" {
    const input = "````\ncode\n```\nstill code\n````\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "", .content = "code\n```\nstill code\n", .start_line = 1, .end_line = 5 },
    });
}

test "two backticks not a fence" {
    const result = try parse(std.testing.allocator, "``not a fence``\n");
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{});
}

test "empty code block" {
    const input = "```\n```\n";
    const result = try parse(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try expectBlocks(result, &.{
        .{ .language = "", .content = "", .start_line = 1, .end_line = 2 },
    });
}
