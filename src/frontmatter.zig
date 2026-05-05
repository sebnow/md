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

/// Apply a sequence of set/delete operations to frontmatter.
/// Detects YAML vs TOML from the existing delimiters and uses the
/// appropriate key-value syntax. If no frontmatter exists and there
/// are set operations, YAML frontmatter is created by default.
/// Returns a newly allocated string with the modified content.
pub fn editFields(allocator: std.mem.Allocator, content: []const u8, ops: []const FieldOp) std.mem.Allocator.Error![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;

    if (extract(content)) |fm| {
        const sep: []const u8 = if (fm.format == .toml) " = " else ": ";
        const is_toml = fm.format == .toml;

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
                        const matches = if (is_toml)
                            matchesKeyToml(fm.raw[line_start..], s.key)
                        else
                            matchesKey(fm.raw[line_start..], s.key);
                        if (matches) {
                            try result.appendSlice(allocator, s.key);
                            try result.appendSlice(allocator, sep);
                            try result.appendSlice(allocator, s.value);
                            try result.appendSlice(allocator, "\n");
                            applied[i] = true;
                            deleted = true;
                            break;
                        }
                    },
                    .delete => |key| {
                        const matches = if (is_toml)
                            matchesKeyToml(fm.raw[line_start..], key)
                        else
                            matchesKey(fm.raw[line_start..], key);
                        if (matches) {
                            deleted = true;
                            break;
                        }
                    },
                }
            }

            if (!deleted) {
                try result.appendSlice(allocator, line);
            } else if (!is_toml) {
                // Skip YAML continuation lines (indented lines belonging
                // to this key's multi-line value: block sequences, nested mappings)
                while (pos < fm.raw.len and (fm.raw[pos] == ' ' or fm.raw[pos] == '\t')) {
                    pos = nextLine(fm.raw, pos);
                }
            }
        }

        // Append any set ops that didn't replace an existing key
        for (ops, 0..) |op, i| {
            switch (op) {
                .set => |s| {
                    if (!applied[i]) {
                        try result.appendSlice(allocator, s.key);
                        try result.appendSlice(allocator, sep);
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
        // No frontmatter — create YAML by default if there are set ops
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

/// Append scalar items to a YAML array field, preserving all other content byte-for-byte.
/// `new_items` are pre-serialized YAML scalar strings.
/// - Block sequence: appends `  - <item>` lines after the last existing item.
/// - Inline sequence `[a, b]`: inserts items before the closing `]`.
/// - Field absent, null, or empty: creates a new block sequence with the items.
/// Returns a newly allocated string; does not modify `content`.
pub fn appendToArrayField(
    allocator: std.mem.Allocator,
    content: []const u8,
    key: []const u8,
    new_items: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (new_items.len == 0) return allocator.dupe(u8, content);

    const fm = extract(content) orelse {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        try result.appendSlice(allocator, "---\n");
        try result.appendSlice(allocator, key);
        try result.appendSlice(allocator, ":\n");
        for (new_items) |item| {
            try result.appendSlice(allocator, "  - ");
            try result.appendSlice(allocator, item);
            try result.appendSlice(allocator, "\n");
        }
        try result.appendSlice(allocator, "---\n");
        try result.appendSlice(allocator, content);
        return result.toOwnedSlice(allocator);
    };

    const opening_end = @intFromPtr(fm.raw.ptr) - @intFromPtr(content.ptr);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    try result.appendSlice(allocator, content[0..opening_end]);

    var pos: usize = 0;
    var found = false;

    while (pos < fm.raw.len) {
        const line_start = pos;
        pos = nextLine(fm.raw, pos);
        const line = fm.raw[line_start..pos];

        if (!found and matchesKey(line, key)) {
            found = true;

            // Determine the value on the same line (after "key:")
            var trim_pos: usize = key.len + 1;
            while (trim_pos < line.len and (line[trim_pos] == ' ' or line[trim_pos] == '\t')) {
                trim_pos += 1;
            }
            const rest = line[trim_pos..]; // e.g. "[a, b]\n" or "\n" or "null\n"

            const is_null_value = std.mem.eql(u8, std.mem.trimRight(u8, rest, " \t\r\n"), "null") or
                std.mem.eql(u8, std.mem.trimRight(u8, rest, " \t\r\n"), "~");
            const is_empty_value = rest.len == 0 or rest[0] == '\n' or rest[0] == '\r' or is_null_value;

            if (!is_empty_value and rest[0] == '[') {
                // Inline sequence: insert items before the closing ']'
                const bracket_end = std.mem.lastIndexOfScalar(u8, rest, ']') orelse {
                    // Malformed inline array: write line as-is and fall through
                    try result.appendSlice(allocator, line);
                    continue;
                };
                const bracket_in_line = trim_pos + bracket_end;

                try result.appendSlice(allocator, line[0..bracket_in_line]);

                const inner = std.mem.trim(u8, rest[1..bracket_end], " \t");
                for (new_items, 0..) |item, idx| {
                    if (inner.len > 0 or idx > 0) {
                        try result.appendSlice(allocator, ", ");
                    }
                    try result.appendSlice(allocator, item);
                }

                try result.appendSlice(allocator, line[bracket_in_line..]);
            } else {
                // Block sequence or null/empty: write key line, then existing items, then new items
                if (is_null_value) {
                    // Replace "key: null" / "key: ~" with bare "key:" line
                    try result.appendSlice(allocator, key);
                    try result.appendSlice(allocator, ":\n");
                } else {
                    try result.appendSlice(allocator, line);
                }

                // Write existing indented block items
                while (pos < fm.raw.len and (fm.raw[pos] == ' ' or fm.raw[pos] == '\t')) {
                    const item_line_start = pos;
                    pos = nextLine(fm.raw, pos);
                    try result.appendSlice(allocator, fm.raw[item_line_start..pos]);
                }

                // Append new items
                for (new_items) |item| {
                    try result.appendSlice(allocator, "  - ");
                    try result.appendSlice(allocator, item);
                    try result.appendSlice(allocator, "\n");
                }
            }
        } else {
            try result.appendSlice(allocator, line);
        }
    }

    if (!found) {
        // Append new field as block sequence before the closing delimiter
        try result.appendSlice(allocator, key);
        try result.appendSlice(allocator, ":\n");
        for (new_items) |item| {
            try result.appendSlice(allocator, "  - ");
            try result.appendSlice(allocator, item);
            try result.appendSlice(allocator, "\n");
        }
    }

    try result.appendSlice(allocator, content[opening_end + fm.raw.len ..]);
    return result.toOwnedSlice(allocator);
}

/// Check if a YAML line starts with "key:".
fn matchesKey(line: []const u8, key: []const u8) bool {
    if (line.len < key.len + 1) return false;
    if (!std.mem.eql(u8, line[0..key.len], key)) return false;
    return line[key.len] == ':';
}

/// Check if a TOML line starts with "key" followed by optional whitespace and "=".
fn matchesKeyToml(line: []const u8, key: []const u8) bool {
    if (line.len < key.len + 1) return false;
    if (!std.mem.eql(u8, line[0..key.len], key)) return false;
    var i = key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == '=';
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

test "deleteField: remove key with block sequence value" {
    const input = "---\ntitle: Architecture Overview\nstatus: draft\nreviewers:\n  - alice\n  - bob\n---\n";
    const result = try deleteField(std.testing.allocator, input, "reviewers");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Architecture Overview\nstatus: draft\n---\n", result);
}

test "deleteField: remove key with nested mapping value" {
    const input = "---\ntitle: Hello\nauthor:\n  name: Alice\n  email: alice@example.com\ntags: [a, b]\n---\nBody\n";
    const result = try deleteField(std.testing.allocator, input, "author");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\ntags: [a, b]\n---\nBody\n", result);
}

test "setField: replace key with block sequence value" {
    const input = "---\ntitle: Hello\nreviewers:\n  - alice\n  - bob\n---\nBody\n";
    const result = try setField(std.testing.allocator, input, "reviewers", "[charlie]");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\nreviewers: [charlie]\n---\nBody\n", result);
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

// TOML editFields tests

test "editFields: TOML set replaces existing key" {
    const input = "+++\ntitle = \"Old\"\ndraft = true\n+++\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .set = .{ .key = "title", .value = "\"New\"" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("+++\ntitle = \"New\"\ndraft = true\n+++\nBody\n", result);
}

test "editFields: TOML set adds new key" {
    const input = "+++\ntitle = \"Hello\"\n+++\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .set = .{ .key = "draft", .value = "true" } },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("+++\ntitle = \"Hello\"\ndraft = true\n+++\nBody\n", result);
}

test "editFields: TOML delete key" {
    const input = "+++\ntitle = \"Hello\"\ndraft = true\n+++\nBody\n";
    const result = try editFields(std.testing.allocator, input, &.{
        .{ .delete = "draft" },
    });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("+++\ntitle = \"Hello\"\n+++\nBody\n", result);
}

// appendToArrayField tests

test "appendToArrayField: append to block sequence" {
    const input = "---\ntags:\n  - a\n  - b\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"c"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags:\n  - a\n  - b\n  - c\n---\nBody\n", result);
}

test "appendToArrayField: append to inline sequence" {
    const input = "---\ntags: [a, b]\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"c"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags: [a, b, c]\n---\nBody\n", result);
}

test "appendToArrayField: append to empty inline sequence" {
    const input = "---\ntags: []\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"a"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags: [a]\n---\nBody\n", result);
}

test "appendToArrayField: field absent creates block sequence" {
    const input = "---\ntitle: Hello\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"a"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\ntags:\n  - a\n---\nBody\n", result);
}

test "appendToArrayField: empty field (null) creates block sequence" {
    const input = "---\ntitle: Hello\naliases:\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "aliases", &.{"foo"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntitle: Hello\naliases:\n  - foo\n---\nBody\n", result);
}

test "appendToArrayField: no frontmatter creates YAML frontmatter" {
    const input = "# Body\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"a"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags:\n  - a\n---\n# Body\n", result);
}

test "appendToArrayField: preserves other fields byte-for-byte" {
    const input = "---\npartOf: \"[[Brainly Payments System]]\"\nconniePageId: \"12345\"\ntags:\n  - old\n---\nBody\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"new"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "---\npartOf: \"[[Brainly Payments System]]\"\nconniePageId: \"12345\"\ntags:\n  - old\n  - new\n---\nBody\n",
        result,
    );
}

test "appendToArrayField: append multiple items to block sequence" {
    const input = "---\ntags:\n  - a\n---\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{ "b", "c" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags:\n  - a\n  - b\n  - c\n---\n", result);
}

test "appendToArrayField: append multiple items to inline sequence" {
    const input = "---\ntags: [a]\n---\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{ "b", "c" });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags: [a, b, c]\n---\n", result);
}

test "appendToArrayField: field with null value becomes block sequence" {
    const input = "---\ntags: null\n---\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{"a"});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("---\ntags:\n  - a\n---\n", result);
}

test "appendToArrayField: zero new items returns unchanged content" {
    const input = "---\ntags: [a]\n---\n";
    const result = try appendToArrayField(std.testing.allocator, input, "tags", &.{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}
