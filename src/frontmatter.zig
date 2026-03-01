const std = @import("std");

pub const Frontmatter = struct {
    raw: []const u8,
    body: []const u8,
};

/// Extract YAML frontmatter and body from markdown content.
/// Frontmatter must start at the beginning of the document with `---`
/// followed by a newline, and end with `---` followed by a newline or EOF.
/// Returns null if no frontmatter is found.
/// All returned slices reference the input buffer — no allocations.
pub fn extract(content: []const u8) ?Frontmatter {
    // Must start with "---" followed by newline
    const after_opening = skipDelimiter(content, 0) orelse return null;

    // Find the closing delimiter
    var pos = after_opening;
    while (pos < content.len) {
        if (skipDelimiter(content, pos)) |after_closing| {
            return .{
                .raw = content[after_opening..pos],
                .body = content[after_closing..],
            };
        }
        // Advance to next line
        pos = nextLine(content, pos);
    }

    // No closing delimiter — lax: treat everything after opening as frontmatter
    return .{
        .raw = content[after_opening..],
        .body = "",
    };
}

/// If content[pos..] starts with "---" followed by optional whitespace and a
/// newline (or EOF), returns the position after that line. Otherwise null.
fn skipDelimiter(content: []const u8, pos: usize) ?usize {
    if (content.len < pos + 3) return null;
    if (!std.mem.eql(u8, content[pos..][0..3], "---")) return null;

    var i = pos + 3;
    // Allow trailing whitespace on the delimiter line
    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}

    if (i == content.len) return i; // EOF after delimiter
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
    if (i < content.len) i += 1; // skip past '\n'
    return i;
}

test "no frontmatter" {
    const result = extract("# Hello\nWorld\n");
    try std.testing.expectEqual(null, result);
}

test "no frontmatter when delimiter not at start" {
    const result = extract("some text\n---\ntitle: x\n---\n");
    try std.testing.expectEqual(null, result);
}

test "empty frontmatter" {
    const result = extract("---\n---\n# Body\n").?;
    try std.testing.expectEqualStrings("", result.raw);
    try std.testing.expectEqualStrings("# Body\n", result.body);
}

test "basic frontmatter" {
    const input = "---\ntitle: Hello\ntags: [a, b]\n---\n# Body\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: Hello\ntags: [a, b]\n", result.raw);
    try std.testing.expectEqualStrings("# Body\n", result.body);
}

test "frontmatter with trailing whitespace on delimiters" {
    const input = "---  \ntitle: x\n---\t\nBody\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: x\n", result.raw);
    try std.testing.expectEqualStrings("Body\n", result.body);
}

test "frontmatter with CRLF line endings" {
    const input = "---\r\ntitle: x\r\n---\r\nBody\r\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: x\r\n", result.raw);
    try std.testing.expectEqualStrings("Body\r\n", result.body);
}

test "unclosed frontmatter treated leniently" {
    const input = "---\ntitle: x\nno closing\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: x\nno closing\n", result.raw);
    try std.testing.expectEqualStrings("", result.body);
}

test "dashes in content not confused with delimiter" {
    const input = "---\ntitle: x\nlist:\n  - item\n---\nBody\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: x\nlist:\n  - item\n", result.raw);
    try std.testing.expectEqualStrings("Body\n", result.body);
}

test "four dashes not treated as delimiter" {
    const input = "---\ntitle: x\n----\nBody\n";
    const result = extract(input).?;
    // "----" is not a valid delimiter, so frontmatter is unclosed
    try std.testing.expectEqualStrings("title: x\n----\nBody\n", result.raw);
    try std.testing.expectEqualStrings("", result.body);
}

test "body only, no frontmatter" {
    const result = extract("");
    try std.testing.expectEqual(null, result);
}

test "delimiter at EOF" {
    const input = "---\ntitle: x\n---";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title: x\n", result.raw);
    try std.testing.expectEqualStrings("", result.body);
}
