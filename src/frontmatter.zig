const std = @import("std");

pub const Format = enum {
    yaml,
    toml,
};

pub const Frontmatter = struct {
    raw: []const u8,
    body: []const u8,
    format: Format,
};

/// Extract frontmatter and body from markdown content.
/// Supports YAML (`---` delimiters) and TOML (`+++` delimiters).
/// Returns null if no frontmatter is found.
/// All returned slices reference the input buffer — no allocations.
pub fn extract(content: []const u8) ?Frontmatter {
    if (extractWithDelimiter(content, "---")) |fm| {
        return .{ .raw = fm.raw, .body = fm.body, .format = .yaml };
    }
    if (extractWithDelimiter(content, "+++")) |fm| {
        return .{ .raw = fm.raw, .body = fm.body, .format = .toml };
    }
    return null;
}

fn extractWithDelimiter(content: []const u8, comptime delimiter: []const u8) ?struct { raw: []const u8, body: []const u8 } {
    const after_opening = skipDelimiter(content, 0, delimiter) orelse return null;

    var pos = after_opening;
    while (pos < content.len) {
        if (skipDelimiter(content, pos, delimiter)) |after_closing| {
            return .{
                .raw = content[after_opening..pos],
                .body = content[after_closing..],
            };
        }
        pos = nextLine(content, pos);
    }

    // No closing delimiter — lax: treat everything after opening as frontmatter
    return .{
        .raw = content[after_opening..],
        .body = "",
    };
}

/// If content[pos..] starts with `delimiter` followed by optional whitespace
/// and a newline (or EOF), returns the position after that line.
fn skipDelimiter(content: []const u8, pos: usize, comptime delimiter: []const u8) ?usize {
    if (content.len < pos + delimiter.len) return null;
    if (!std.mem.eql(u8, content[pos..][0..delimiter.len], delimiter)) return null;

    var i = pos + delimiter.len;
    // Reject longer runs (e.g. "----" is not "---")
    if (i < content.len and content[i] == delimiter[0]) return null;
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

pub const FieldOp = union(enum) {
    set: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

/// Apply a sequence of set/delete operations to YAML frontmatter.
/// If no frontmatter exists and there are set operations, one is created.
/// Returns a newly allocated string with the modified content.
pub fn editFields(allocator: std.mem.Allocator, content: []const u8, ops: []const FieldOp) std.mem.Allocator.Error![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;

    if (extract(content)) |fm| {
        const opening_end = @intFromPtr(fm.raw.ptr) - @intFromPtr(content.ptr);
        try result.appendSlice(allocator, content[0..opening_end]);

        // Track which set ops have been applied (replaced an existing key)
        var applied = try allocator.alloc(bool, ops.len);
        defer allocator.free(applied);
        @memset(applied, false);

        // Write existing lines, applying replacements and deletions
        var pos: usize = 0;
        while (pos < fm.raw.len) {
            const line_start = pos;
            pos = nextLine(fm.raw, pos);

            const line = fm.raw[line_start..pos];
            var deleted = false;

            for (ops, 0..) |op, i| {
                switch (op) {
                    .set => |s| {
                        if (matchesKey(fm.raw[line_start..], s.key)) {
                            try result.appendSlice(allocator, s.key);
                            try result.appendSlice(allocator, ": ");
                            try result.appendSlice(allocator, s.value);
                            try result.appendSlice(allocator, "\n");
                            applied[i] = true;
                            deleted = true;
                            break;
                        }
                    },
                    .delete => |key| {
                        if (matchesKey(fm.raw[line_start..], key)) {
                            deleted = true;
                            break;
                        }
                    },
                }
            }

            if (!deleted) {
                try result.appendSlice(allocator, line);
            }
        }

        // Append any set ops that didn't replace an existing key
        for (ops, 0..) |op, i| {
            switch (op) {
                .set => |s| {
                    if (!applied[i]) {
                        try result.appendSlice(allocator, s.key);
                        try result.appendSlice(allocator, ": ");
                        try result.appendSlice(allocator, s.value);
                        try result.appendSlice(allocator, "\n");
                    }
                },
                .delete => {},
            }
        }

        const body_with_delimiter = content[opening_end + fm.raw.len ..];
        try result.appendSlice(allocator, body_with_delimiter);
    } else {
        // No frontmatter — create one if there are set ops
        var has_sets = false;
        for (ops) |op| {
            if (op == .set) {
                has_sets = true;
                break;
            }
        }

        if (has_sets) {
            try result.appendSlice(allocator, "---\n");
            for (ops) |op| {
                switch (op) {
                    .set => |s| {
                        try result.appendSlice(allocator, s.key);
                        try result.appendSlice(allocator, ": ");
                        try result.appendSlice(allocator, s.value);
                        try result.appendSlice(allocator, "\n");
                    },
                    .delete => {},
                }
            }
            try result.appendSlice(allocator, "---\n");
            try result.appendSlice(allocator, content);
        } else {
            try result.appendSlice(allocator, content);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Convenience: set a single field.
pub fn setField(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return editFields(allocator, content, &.{.{ .set = .{ .key = key, .value = value } }});
}

/// Convenience: delete a single field.
pub fn deleteField(allocator: std.mem.Allocator, content: []const u8, key: []const u8) std.mem.Allocator.Error![]const u8 {
    return editFields(allocator, content, &.{.{ .delete = key }});
}

/// Check if a line starts with "key:" (with optional whitespace after colon).
fn matchesKey(line: []const u8, key: []const u8) bool {
    if (line.len < key.len + 1) return false;
    if (!std.mem.eql(u8, line[0..key.len], key)) return false;
    return line[key.len] == ':';
}

/// Convert raw YAML frontmatter to JSON.
/// Handles top-level key: value pairs with best-effort type detection.
/// Recognizes booleans, integers, floats, null, inline lists, block
/// sequences, and simple nested mappings.
pub fn toJson(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(allocator, '{');

    var first = true;
    var pos: usize = 0;
    while (pos < raw.len) {
        const line_start = pos;
        pos = nextLine(raw, pos);

        if (line_start == pos) break;
        const line = stripLineEnding(raw[line_start..pos]);
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') continue;

        // Find colon separator
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        if (key.len == 0) continue;

        // Value is everything after ":"
        var value = line[colon + 1 ..];
        while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) {
            value = value[1..];
        }

        if (!first) try out.append(allocator, ',');
        first = false;

        // Write key
        try out.append(allocator, '"');
        try appendJsonEscaped(&out, allocator, key);
        try out.append(allocator, '"');
        try out.append(allocator, ':');

        // Empty value: check continuation lines for block sequence or nested mapping
        if (value.len == 0) {
            pos = try appendBlockValue(&out, allocator, raw, pos);
        } else {
            try appendJsonValue(&out, allocator, value);
        }
    }

    try out.append(allocator, '}');
    try out.append(allocator, '\n');
    return out.toOwnedSlice(allocator);
}

/// Parse indented continuation lines as either a block sequence or nested mapping.
/// Returns the new position after consuming continuation lines.
fn appendBlockValue(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
    start_pos: usize,
) std.mem.Allocator.Error!usize {
    // Peek at first continuation line to determine type
    if (start_pos < raw.len) {
        const peek_line = stripLineEnding(raw[start_pos..nextLine(raw, start_pos)]);
        const trimmed = std.mem.trimLeft(u8, peek_line, " \t");

        if (trimmed.len > 0 and trimmed[0] == '-') {
            return appendBlockSequence(out, allocator, raw, start_pos);
        } else if (trimmed.len > 0 and (peek_line[0] == ' ' or peek_line[0] == '\t')) {
            return appendNestedMapping(out, allocator, raw, start_pos);
        }
    }

    // No continuation lines — null
    try out.appendSlice(allocator, "null");
    return start_pos;
}

/// Consume indented `- item` lines and emit a JSON array.
fn appendBlockSequence(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
    start_pos: usize,
) std.mem.Allocator.Error!usize {
    try out.append(allocator, '[');
    var pos = start_pos;
    var arr_first = true;

    while (pos < raw.len) {
        const line_start = pos;
        const next_pos = nextLine(raw, pos);
        const line = stripLineEnding(raw[line_start..next_pos]);

        // Stop at non-indented lines
        if (line.len == 0) break;
        if (line[0] != ' ' and line[0] != '\t') break;

        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            pos = next_pos;
            continue;
        }

        // Must be a "- item" line
        if (trimmed[0] != '-') break;

        pos = next_pos;

        // Extract item value after "- "
        var item = trimmed[1..];
        while (item.len > 0 and (item[0] == ' ' or item[0] == '\t')) {
            item = item[1..];
        }
        item = stripYamlQuotes(item);

        if (!arr_first) try out.append(allocator, ',');
        arr_first = false;

        try out.append(allocator, '"');
        try appendJsonEscaped(out, allocator, item);
        try out.append(allocator, '"');
    }

    try out.append(allocator, ']');
    return pos;
}

/// Consume indented `key: value` lines and emit a JSON object.
fn appendNestedMapping(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
    start_pos: usize,
) std.mem.Allocator.Error!usize {
    try out.append(allocator, '{');
    var pos = start_pos;
    var obj_first = true;

    while (pos < raw.len) {
        const line_start = pos;
        const next_pos = nextLine(raw, pos);
        const line = stripLineEnding(raw[line_start..next_pos]);

        if (line.len == 0) break;
        if (line[0] != ' ' and line[0] != '\t') break;

        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) {
            pos = next_pos;
            continue;
        }

        pos = next_pos;

        // Parse as key: value
        const nested_colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const nested_key = trimmed[0..nested_colon];
        if (nested_key.len == 0) continue;

        var nested_value = trimmed[nested_colon + 1 ..];
        while (nested_value.len > 0 and (nested_value[0] == ' ' or nested_value[0] == '\t')) {
            nested_value = nested_value[1..];
        }

        if (!obj_first) try out.append(allocator, ',');
        obj_first = false;

        try out.append(allocator, '"');
        try appendJsonEscaped(out, allocator, nested_key);
        try out.append(allocator, '"');
        try out.append(allocator, ':');
        try appendJsonValue(out, allocator, nested_value);
    }

    try out.append(allocator, '}');
    return pos;
}

fn appendJsonValue(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error!void {
    // Empty value or explicit null
    if (value.len == 0 or std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "~")) {
        try out.appendSlice(allocator, "null");
        return;
    }

    // Booleans
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
        try out.appendSlice(allocator, value);
        return;
    }

    // Integers
    if (isInteger(value)) {
        try out.appendSlice(allocator, value);
        return;
    }

    // Floats
    if (isFloat(value)) {
        try out.appendSlice(allocator, value);
        return;
    }

    // Inline YAML list: [a, b, c] → JSON array of strings
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        try out.append(allocator, '[');
        const inner = value[1 .. value.len - 1];
        var item_first = true;
        var iter = std.mem.splitScalar(u8, inner, ',');
        while (iter.next()) |item_raw| {
            var item = std.mem.trim(u8, item_raw, " \t");
            if (item.len == 0) continue;

            if (!item_first) try out.append(allocator, ',');
            item_first = false;

            // Strip YAML quotes from list items
            item = stripYamlQuotes(item);
            try out.append(allocator, '"');
            try appendJsonEscaped(out, allocator, item);
            try out.append(allocator, '"');
        }
        try out.append(allocator, ']');
        return;
    }

    // Quoted YAML string — strip quotes
    const unquoted = stripYamlQuotes(value);
    try out.append(allocator, '"');
    try appendJsonEscaped(out, allocator, unquoted);
    try out.append(allocator, '"');
}

fn stripYamlQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
}

fn isInteger(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    if (i == s.len) return false;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return true;
}

fn isFloat(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) i += 1;
    var has_dot = false;
    var has_digit = false;
    while (i < s.len) : (i += 1) {
        if (s[i] == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else {
            return false;
        }
    }
    return has_dot and has_digit;
}

fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[c >> 4]);
                    try out.append(allocator, hex[c & 0xf]);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
}

fn stripLineEnding(line: []const u8) []const u8 {
    var end = line.len;
    if (end > 0 and line[end - 1] == '\n') end -= 1;
    if (end > 0 and line[end - 1] == '\r') end -= 1;
    return line[0..end];
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
    try std.testing.expectEqual(Format.yaml, result.format);
}

// TOML frontmatter tests

test "toml frontmatter basic" {
    const input = "+++\ntitle = \"Hello\"\ndraft = true\n+++\n# Body\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title = \"Hello\"\ndraft = true\n", result.raw);
    try std.testing.expectEqualStrings("# Body\n", result.body);
    try std.testing.expectEqual(Format.toml, result.format);
}

test "toml frontmatter at EOF" {
    const input = "+++\ntitle = \"x\"\n+++";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("title = \"x\"\n", result.raw);
    try std.testing.expectEqualStrings("", result.body);
    try std.testing.expectEqual(Format.toml, result.format);
}

test "toml frontmatter empty" {
    const input = "+++\n+++\n# Body\n";
    const result = extract(input).?;
    try std.testing.expectEqualStrings("", result.raw);
    try std.testing.expectEqualStrings("# Body\n", result.body);
    try std.testing.expectEqual(Format.toml, result.format);
}

test "four pluses not treated as toml delimiter" {
    const result = extract("++++\ntitle = \"x\"\n+++\n");
    try std.testing.expectEqual(null, result);
}

test "yaml format tag" {
    const input = "---\ntitle: x\n---\n";
    const result = extract(input).?;
    try std.testing.expectEqual(Format.yaml, result.format);
}

// setField tests

test "setField: add to existing frontmatter" {
    const input = "---\ntitle: Hello\n---\nBody\n";
    const result = try setField(std.testing.allocator, input, "draft", "true");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\ndraft: true\n---\nBody\n", result);
}

test "setField: replace existing key" {
    const input = "---\ntitle: Old\ntags: [a]\n---\nBody\n";
    const result = try setField(std.testing.allocator, input, "title", "New");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: New\ntags: [a]\n---\nBody\n", result);
}

test "setField: create frontmatter when none exists" {
    const input = "# Body\n";
    const result = try setField(std.testing.allocator, input, "title", "Hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\n---\n# Body\n", result);
}

test "setField: create frontmatter on empty file" {
    const result = try setField(std.testing.allocator, "", "key", "val");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\nkey: val\n---\n", result);
}

// deleteField tests

test "deleteField: remove existing key" {
    const input = "---\ntitle: Hello\ndraft: true\n---\nBody\n";
    const result = try deleteField(std.testing.allocator, input, "draft");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\n---\nBody\n", result);
}

test "deleteField: key not found leaves file unchanged" {
    const input = "---\ntitle: Hello\n---\nBody\n";
    const result = try deleteField(std.testing.allocator, input, "nonexistent");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "deleteField: remove last key leaves empty frontmatter" {
    const input = "---\ntitle: Hello\n---\nBody\n";
    const result = try deleteField(std.testing.allocator, input, "title");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\n---\nBody\n", result);
}

test "deleteField: no frontmatter returns unchanged" {
    const input = "# Body\n";
    const result = try deleteField(std.testing.allocator, input, "title");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

// editFields tests

test "editFields: set multiple fields at once" {
    const input = "---\ntitle: Hello\n---\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .set = .{ .key = "draft", .value = "true" } },
        .{ .set = .{ .key = "author", .value = "me" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\ndraft: true\nauthor: me\n---\nBody\n", result);
}

test "editFields: delete multiple fields at once" {
    const input = "---\ntitle: Hello\ndraft: true\nauthor: me\n---\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .delete = "draft" },
        .{ .delete = "author" },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\n---\nBody\n", result);
}

test "editFields: mix set and delete" {
    const input = "---\ntitle: Old\ndraft: true\n---\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .set = .{ .key = "title", .value = "New" } },
        .{ .delete = "draft" },
        .{ .set = .{ .key = "status", .value = "published" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: New\nstatus: published\n---\nBody\n", result);
}

test "editFields: set multiple on empty file" {
    const result = try editFields(std.testing.allocator, "", &.{
        .{ .set = .{ .key = "title", .value = "Hello" } },
        .{ .set = .{ .key = "draft", .value = "true" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\ndraft: true\n---\n", result);
}

test "editFields: delete only on no frontmatter is noop" {
    const input = "# Body\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .delete = "title" },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

// toJson tests

test "toJson: simple key-value pairs" {
    const raw = "title: Hello\nauthor: me\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"title\":\"Hello\",\"author\":\"me\"}\n", result);
}

test "toJson: value with colon and spaces" {
    const raw = "url: https://example.com\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"url\":\"https://example.com\"}\n", result);
}

test "toJson: inline list preserved as string" {
    const raw = "tags: [a, b, c]\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"tags\":[\"a\",\"b\",\"c\"]}\n", result);
}

test "toJson: empty frontmatter" {
    const result = try toJson(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{}\n", result);
}

test "toJson: value with quotes escaped" {
    const raw = "title: He said \"hello\"\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"title\":\"He said \\\"hello\\\"\"}\n", result);
}

test "toJson: numeric and boolean values unquoted" {
    const raw = "count: 42\ndraft: true\nrating: 3.5\nenabled: false\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"count\":42,\"draft\":true,\"rating\":3.5,\"enabled\":false}\n", result);
}

test "toJson: quoted YAML strings unquoted in output" {
    const raw = "title: \"Hello World\"\nalt: 'single quoted'\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"title\":\"Hello World\",\"alt\":\"single quoted\"}\n", result);
}

test "toJson: null values" {
    const raw = "null_val: null\ntilde: ~\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"null_val\":null,\"tilde\":null}\n", result);
}

test "toJson: block sequence list" {
    const raw = "tags:\n  - alpha\n  - beta\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"tags\":[\"alpha\",\"beta\"]}\n", result);
}

test "toJson: block sequence followed by another key" {
    const raw = "tags:\n  - alpha\n  - beta\ntitle: Hello\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"tags\":[\"alpha\",\"beta\"],\"title\":\"Hello\"}\n", result);
}

test "toJson: block sequence single item" {
    const raw = "tags:\n  - only\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"tags\":[\"only\"]}\n", result);
}

test "toJson: empty key with no continuation is null" {
    const raw = "empty:\ntitle: Hello\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"empty\":null,\"title\":\"Hello\"}\n", result);
}

test "toJson: nested object skipped as raw string" {
    const raw = "metadata:\n  author: me\n  year: 2025\ntitle: Hello\n";
    const result = try toJson(std.testing.allocator, raw);
    defer std.testing.allocator.free(result);
    // Nested objects are best-effort: key-value continuation lines become a JSON object
    try std.testing.expectEqualStrings("{\"metadata\":{\"author\":\"me\",\"year\":2025},\"title\":\"Hello\"}\n", result);
}
