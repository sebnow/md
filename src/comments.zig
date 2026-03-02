const std = @import("std");

pub const CommentKind = enum {
    html,
    obsidian,
};

pub const Comment = struct {
    kind: CommentKind,
    text: []const u8,
    line: usize,
};

/// Parse HTML comments (`<!-- ... -->`) and Obsidian comments (`%% ... %%`)
/// from markdown content. Returns comments as a slice allocated from the
/// provided allocator. All string fields reference the input buffer.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error![]const Comment {
    var comments: std.ArrayListUnmanaged(Comment) = .empty;

    var pos: usize = 0;
    var line: usize = 1;

    while (pos < content.len) {
        if (content[pos] == '\n') {
            line += 1;
            pos += 1;
            continue;
        }

        // HTML comment: <!-- ... -->
        if (pos + 4 <= content.len and std.mem.eql(u8, content[pos .. pos + 4], "<!--")) {
            const start_line = line;
            const text_start = pos + 4;
            if (findEnd(content, text_start, "-->")) |end_pos| {
                const text = std.mem.trim(u8, content[text_start..end_pos], " \t\r\n");
                try comments.append(allocator, .{
                    .kind = .html,
                    .text = text,
                    .line = start_line,
                });
                // Count newlines within the comment
                for (content[pos .. end_pos + 3]) |c| {
                    if (c == '\n') line += 1;
                }
                pos = end_pos + 3; // skip -->
                continue;
            }
        }

        // Obsidian comment: %% ... %%
        if (pos + 2 <= content.len and std.mem.eql(u8, content[pos .. pos + 2], "%%")) {
            const start_line = line;
            const text_start = pos + 2;
            if (findEnd(content, text_start, "%%")) |end_pos| {
                const text = std.mem.trim(u8, content[text_start..end_pos], " \t\r\n");
                try comments.append(allocator, .{
                    .kind = .obsidian,
                    .text = text,
                    .line = start_line,
                });
                for (content[pos .. end_pos + 2]) |c| {
                    if (c == '\n') line += 1;
                }
                pos = end_pos + 2; // skip %%
                continue;
            }
        }

        pos += 1;
    }

    return comments.toOwnedSlice(allocator);
}

fn findEnd(content: []const u8, start: usize, marker: []const u8) ?usize {
    var pos = start;
    while (pos + marker.len <= content.len) {
        if (std.mem.eql(u8, content[pos .. pos + marker.len], marker)) {
            return pos;
        }
        pos += 1;
    }
    return null;
}

// Tests

const testing = std.testing;

test "no comments" {
    const result = try parse(testing.allocator, "# Hello\nSome text.\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "html comment" {
    const result = try parse(testing.allocator, "text <!-- a comment --> more\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(CommentKind.html, result[0].kind);
    try testing.expectEqualStrings("a comment", result[0].text);
    try testing.expectEqual(@as(usize, 1), result[0].line);
}

test "obsidian comment" {
    const result = try parse(testing.allocator, "text %% obsidian note %% more\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(CommentKind.obsidian, result[0].kind);
    try testing.expectEqualStrings("obsidian note", result[0].text);
}

test "multiline html comment" {
    const content =
        \\line 1
        \\<!-- multi
        \\line comment -->
        \\line 4
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(CommentKind.html, result[0].kind);
    try testing.expectEqual(@as(usize, 2), result[0].line);
    try testing.expectEqualStrings("multi\nline comment", result[0].text);
}

test "multiline obsidian comment" {
    const content =
        \\%% begin notes
        \\some notes here
        \\end notes %%
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(CommentKind.obsidian, result[0].kind);
    try testing.expectEqualStrings("begin notes\nsome notes here\nend notes", result[0].text);
}

test "mixed comment types" {
    const content =
        \\<!-- html comment -->
        \\%% obsidian comment %%
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(CommentKind.html, result[0].kind);
    try testing.expectEqual(CommentKind.obsidian, result[1].kind);
}

test "unterminated html comment ignored" {
    const result = try parse(testing.allocator, "<!-- never closed\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "unterminated obsidian comment ignored" {
    const result = try parse(testing.allocator, "%% never closed\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "empty html comment" {
    const result = try parse(testing.allocator, "<!---->\n");
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("", result[0].text);
}

test "comment line numbers" {
    const content =
        \\line 1
        \\line 2
        \\<!-- comment on line 3 -->
        \\line 4
        \\%% comment on line 5 %%
        \\
    ;
    const result = try parse(testing.allocator, content);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(usize, 3), result[0].line);
    try testing.expectEqual(@as(usize, 5), result[1].line);
}
