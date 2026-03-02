const std = @import("std");
const parser_mod = @import("parser.zig");
const value_mod = @import("value.zig");
const md = struct {
    const frontmatter = @import("frontmatter.zig");
    const headings = @import("headings.zig");
    const links = @import("links.zig");
    const codeblocks = @import("codeblocks.zig");
    const tags = @import("tags.zig");
};

const Node = parser_mod.Node;
const Value = value_mod.Value;

pub const EvalError = struct {
    message: []const u8,
    pos: usize,
};

pub const Evaluator = struct {
    arena: std.mem.Allocator,
    content: []const u8,
    err: ?EvalError,

    pub fn init(arena: std.mem.Allocator, content: []const u8) Evaluator {
        return .{ .arena = arena, .content = content, .err = null };
    }

    pub fn eval(self: *Evaluator, node: *const Node) ?Value {
        return switch (node.*) {
            .pipeline => |p| self.evalPipeline(p),
            .field_access => |fa| self.evalFieldAccess(fa, null),
            .fn_call => |fc| self.evalFnCall(fc, null),
            .literal => |lit| self.evalLiteral(lit),
            .binary => |bin| self.evalBinary(bin, null),
            .unary => |un| self.evalUnary(un, null),
            .comma => |c| self.evalComma(c),
        };
    }

    fn evalWithInput(self: *Evaluator, node: *const Node, input: Value) ?Value {
        return switch (node.*) {
            .pipeline => |p| self.evalPipelineWithInput(p, input),
            .field_access => |fa| self.evalFieldAccess(fa, input),
            .fn_call => |fc| self.evalFnCall(fc, input),
            .literal => |lit| self.evalLiteral(lit),
            .binary => |bin| self.evalBinary(bin, input),
            .unary => |un| self.evalUnary(un, input),
            .comma => |c| self.evalCommaWithInput(c, input),
        };
    }

    fn evalPipeline(self: *Evaluator, p: Node.Pipeline) ?Value {
        if (p.stages.len == 0) return null;

        var result = self.eval(p.stages[0]) orelse return null;
        for (p.stages[1..]) |stage| {
            result = self.evalWithInput(stage, result) orelse return null;
        }
        return result;
    }

    fn evalPipelineWithInput(self: *Evaluator, p: Node.Pipeline, input: Value) ?Value {
        if (p.stages.len == 0) return null;

        var result = self.evalWithInput(p.stages[0], input) orelse return null;
        for (p.stages[1..]) |stage| {
            result = self.evalWithInput(stage, result) orelse return null;
        }
        return result;
    }

    fn evalFieldAccess(self: *Evaluator, fa: Node.FieldAccess, input: ?Value) ?Value {
        var current: Value = input orelse {
            self.setError("field access requires input", 0);
            return null;
        };

        for (fa.parts) |part| {
            switch (current) {
                .record => |rec| {
                    current = rec.get(part) orelse return .null;
                },
                else => return .null,
            }
        }
        return current;
    }

    fn evalFnCall(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        // Extractors: operate on document content, ignore input
        if (fc.args.len == 0 and input == null) {
            return self.evalExtractor(fc.name);
        }
        // Extractors piped into: also ignore input value
        if (fc.args.len == 0) {
            if (self.isExtractor(fc.name)) {
                return self.evalExtractor(fc.name);
            }
        }

        // Built-in functions with args are handled in later commits
        // For now, treat unknown functions as errors
        self.setError("unknown function", 0);
        return null;
    }

    fn isExtractor(self: *Evaluator, name: []const u8) bool {
        _ = self;
        const extractors = [_][]const u8{
            "frontmatter", "body", "headings", "links",
            "tags",        "codeblocks", "stats",
        };
        for (extractors) |e| {
            if (std.mem.eql(u8, name, e)) return true;
        }
        return false;
    }

    fn evalExtractor(self: *Evaluator, name: []const u8) ?Value {
        if (std.mem.eql(u8, name, "frontmatter")) return self.extractFrontmatter();
        if (std.mem.eql(u8, name, "body")) return self.extractBody();
        if (std.mem.eql(u8, name, "headings")) return self.extractHeadings();
        if (std.mem.eql(u8, name, "links")) return self.extractLinks();
        if (std.mem.eql(u8, name, "tags")) return self.extractTags();
        if (std.mem.eql(u8, name, "codeblocks")) return self.extractCodeblocks();
        if (std.mem.eql(u8, name, "stats")) return self.extractStats();
        return null;
    }

    fn extractFrontmatter(self: *Evaluator) ?Value {
        const fm = md.frontmatter.extract(self.content) orelse return .null;
        return parseFrontmatterToValue(self.arena, fm.raw);
    }

    fn extractBody(self: *Evaluator) Value {
        if (md.frontmatter.extract(self.content)) |fm| {
            return .{ .string = fm.body };
        }
        return .{ .string = self.content };
    }

    fn extractHeadings(self: *Evaluator) ?Value {
        const parsed = md.headings.parse(self.arena, self.content) catch return null;
        const items = self.arena.alloc(Value, parsed.len) catch return null;
        for (parsed, 0..) |h, idx| {
            items[idx] = headingToValue(self.arena, h) catch return null;
        }
        return .{ .array = items };
    }

    fn extractLinks(self: *Evaluator) ?Value {
        const parsed = md.links.parse(self.arena, self.content) catch return null;
        const items = self.arena.alloc(Value, parsed.len) catch return null;
        for (parsed, 0..) |l, idx| {
            items[idx] = linkToValue(self.arena, l) catch return null;
        }
        return .{ .array = items };
    }

    fn extractTags(self: *Evaluator) ?Value {
        const parsed = md.tags.parse(self.arena, self.content) catch return null;
        const items = self.arena.alloc(Value, parsed.len) catch return null;
        for (parsed, 0..) |t, idx| {
            items[idx] = tagToValue(self.arena, t) catch return null;
        }
        return .{ .array = items };
    }

    fn extractCodeblocks(self: *Evaluator) ?Value {
        const parsed = md.codeblocks.parse(self.arena, self.content) catch return null;
        const items = self.arena.alloc(Value, parsed.len) catch return null;
        for (parsed, 0..) |b, idx| {
            items[idx] = codeblockToValue(self.arena, b) catch return null;
        }
        return .{ .array = items };
    }

    fn extractStats(self: *Evaluator) ?Value {
        const body = if (md.frontmatter.extract(self.content)) |fm| fm.body else self.content;

        var lines: usize = 0;
        var words: usize = 0;
        var in_word = false;
        for (body) |c| {
            if (c == '\n') lines += 1;
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                in_word = false;
            } else {
                if (!in_word) words += 1;
                in_word = true;
            }
        }
        if (body.len > 0 and body[body.len - 1] != '\n') lines += 1;

        return recordFromPairs(self.arena, &.{
            .{ "lines", .{ .int = @intCast(lines) } },
            .{ "words", .{ .int = @intCast(words) } },
        });
    }

    fn evalLiteral(self: *Evaluator, lit: Node.Literal) Value {
        _ = self;
        return switch (lit) {
            .string => |s| .{ .string = s },
            .integer => |n| .{ .int = n },
            .float => |f| .{ .float = f },
            .bool => |b| .{ .bool = b },
            .null => .null,
        };
    }

    fn evalBinary(self: *Evaluator, bin: Node.Binary, input: ?Value) ?Value {
        const left = if (input) |inp|
            self.evalWithInput(bin.left, inp)
        else
            self.eval(bin.left);
        const left_val = left orelse return null;

        const right = if (input) |inp|
            self.evalWithInput(bin.right, inp)
        else
            self.eval(bin.right);
        const right_val = right orelse return null;

        return switch (bin.op) {
            .eq => .{ .bool = left_val.eql(right_val) },
            .neq => .{ .bool = !left_val.eql(right_val) },
            .lt => .{ .bool = compareValues(left_val, right_val) == .lt },
            .gt => .{ .bool = compareValues(left_val, right_val) == .gt },
            .lte => blk: {
                const ord = compareValues(left_val, right_val);
                break :blk .{ .bool = ord == .lt or ord == .eq };
            },
            .gte => blk: {
                const ord = compareValues(left_val, right_val);
                break :blk .{ .bool = ord == .gt or ord == .eq };
            },
            .op_and => .{ .bool = isTruthy(left_val) and isTruthy(right_val) },
            .op_or => .{ .bool = isTruthy(left_val) or isTruthy(right_val) },
        };
    }

    fn evalUnary(self: *Evaluator, un: Node.Unary, input: ?Value) ?Value {
        const operand = if (input) |inp|
            self.evalWithInput(un.operand, inp)
        else
            self.eval(un.operand);
        const val = operand orelse return null;

        return switch (un.op) {
            .op_not => .{ .bool = !isTruthy(val) },
        };
    }

    fn evalComma(self: *Evaluator, c: Node.Comma) ?Value {
        const items = self.arena.alloc(Value, c.exprs.len) catch return null;
        for (c.exprs, 0..) |expr, idx| {
            items[idx] = self.eval(expr) orelse return null;
        }
        return .{ .array = items };
    }

    fn evalCommaWithInput(self: *Evaluator, c: Node.Comma, input: Value) ?Value {
        const items = self.arena.alloc(Value, c.exprs.len) catch return null;
        for (c.exprs, 0..) |expr, idx| {
            items[idx] = self.evalWithInput(expr, input) orelse return null;
        }
        return .{ .array = items };
    }

    fn setError(self: *Evaluator, message: []const u8, pos: usize) void {
        if (self.err == null) {
            self.err = .{ .message = message, .pos = pos };
        }
    }
};

// Value comparison for ordering
fn compareValues(a: Value, b: Value) std.math.Order {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return .eq; // incomparable types

    return switch (a) {
        .int => |n| std.math.order(n, b.int),
        .float => |f| std.math.order(f, b.float),
        .string => |s| std.mem.order(u8, s, b.string),
        .bool => |ab| {
            const ai: u1 = @intFromBool(ab);
            const bi: u1 = @intFromBool(b.bool);
            return std.math.order(ai, bi);
        },
        else => .eq,
    };
}

fn isTruthy(v: Value) bool {
    return switch (v) {
        .bool => |b| b,
        .null => false,
        .string => |s| s.len > 0,
        .int => |n| n != 0,
        .float => |f| f != 0.0,
        .array => |arr| arr.len > 0,
        .record => |rec| rec.keys.len > 0,
    };
}

// Type conversion helpers

fn headingToValue(arena: std.mem.Allocator, h: md.headings.Heading) std.mem.Allocator.Error!Value {
    return recordFromPairs(arena, &.{
        .{ "depth", .{ .int = @intCast(h.depth) } },
        .{ "text", .{ .string = h.text } },
        .{ "line", .{ .int = @intCast(h.line) } },
    }) orelse error.OutOfMemory;
}

fn linkToValue(arena: std.mem.Allocator, l: md.links.Link) std.mem.Allocator.Error!Value {
    return recordFromPairs(arena, &.{
        .{ "kind", .{ .string = @tagName(l.kind) } },
        .{ "target", .{ .string = l.target } },
        .{ "text", .{ .string = l.text } },
        .{ "line", .{ .int = @intCast(l.line) } },
    }) orelse error.OutOfMemory;
}

fn tagToValue(arena: std.mem.Allocator, t: md.tags.Tag) std.mem.Allocator.Error!Value {
    return recordFromPairs(arena, &.{
        .{ "name", .{ .string = t.name } },
        .{ "line", .{ .int = @intCast(t.line) } },
    }) orelse error.OutOfMemory;
}

fn codeblockToValue(arena: std.mem.Allocator, b: md.codeblocks.CodeBlock) std.mem.Allocator.Error!Value {
    return recordFromPairs(arena, &.{
        .{ "language", .{ .string = b.language } },
        .{ "content", .{ .string = b.content } },
        .{ "start_line", .{ .int = @intCast(b.start_line) } },
        .{ "end_line", .{ .int = @intCast(b.end_line) } },
    }) orelse error.OutOfMemory;
}

const KV = struct { []const u8, Value };

fn recordFromPairs(arena: std.mem.Allocator, pairs: []const KV) ?Value {
    const keys = arena.alloc([]const u8, pairs.len) catch return null;
    const vals = arena.alloc(Value, pairs.len) catch return null;
    for (pairs, 0..) |pair, idx| {
        keys[idx] = pair[0];
        vals[idx] = pair[1];
    }
    return .{ .record = .{ .keys = keys, .values = vals } };
}

// YAML frontmatter → Value.Record parser
// Adapted from frontmatter.toJson but produces Value directly.

pub fn parseFrontmatterToValue(arena: std.mem.Allocator, raw: []const u8) ?Value {
    var keys = std.ArrayListUnmanaged([]const u8).empty;
    var vals = std.ArrayListUnmanaged(Value).empty;

    var pos: usize = 0;
    while (pos < raw.len) {
        const line_start = pos;
        pos = nextLine(raw, pos);

        const line = stripLineEnding(raw[line_start..pos]);
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        if (key.len == 0) continue;

        var val_text = line[colon + 1 ..];
        while (val_text.len > 0 and (val_text[0] == ' ' or val_text[0] == '\t')) {
            val_text = val_text[1..];
        }

        keys.append(arena, key) catch return null;

        if (val_text.len == 0) {
            // Block value: sequence or nested mapping
            const block_result = parseBlockValue(arena, raw, pos) orelse return null;
            vals.append(arena, block_result.value) catch return null;
            pos = block_result.pos;
        } else {
            vals.append(arena, parseScalarValue(arena, val_text)) catch return null;
        }
    }

    const k = keys.toOwnedSlice(arena) catch return null;
    const v = vals.toOwnedSlice(arena) catch return null;
    return .{ .record = .{ .keys = k, .values = v } };
}

const BlockResult = struct {
    value: Value,
    pos: usize,
};

fn parseBlockValue(arena: std.mem.Allocator, raw: []const u8, start_pos: usize) ?BlockResult {
    if (start_pos < raw.len) {
        const peek_end = nextLine(raw, start_pos);
        const peek_line = stripLineEnding(raw[start_pos..peek_end]);
        const trimmed = std.mem.trimLeft(u8, peek_line, " \t");

        if (trimmed.len > 0 and trimmed[0] == '-') {
            return parseBlockSequence(arena, raw, start_pos);
        } else if (trimmed.len > 0 and (peek_line[0] == ' ' or peek_line[0] == '\t')) {
            return parseNestedMapping(arena, raw, start_pos);
        }
    }
    return .{ .value = .null, .pos = start_pos };
}

fn parseBlockSequence(arena: std.mem.Allocator, raw: []const u8, start_pos: usize) ?BlockResult {
    var items = std.ArrayListUnmanaged(Value).empty;
    var pos = start_pos;

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
        if (trimmed[0] != '-') break;

        var item_text = trimmed[1..];
        while (item_text.len > 0 and (item_text[0] == ' ' or item_text[0] == '\t')) {
            item_text = item_text[1..];
        }

        items.append(arena, parseScalarValue(arena, item_text)) catch return null;
        pos = next_pos;
    }

    const slice = items.toOwnedSlice(arena) catch return null;
    return .{ .value = .{ .array = slice }, .pos = pos };
}

fn parseNestedMapping(arena: std.mem.Allocator, raw: []const u8, start_pos: usize) ?BlockResult {
    var keys = std.ArrayListUnmanaged([]const u8).empty;
    var vals = std.ArrayListUnmanaged(Value).empty;
    var pos = start_pos;

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

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
            pos = next_pos;
            continue;
        };

        const key = trimmed[0..colon];
        var val_text = trimmed[colon + 1 ..];
        while (val_text.len > 0 and (val_text[0] == ' ' or val_text[0] == '\t')) {
            val_text = val_text[1..];
        }

        keys.append(arena, key) catch return null;
        vals.append(arena, parseScalarValue(arena, val_text)) catch return null;
        pos = next_pos;
    }

    const k = keys.toOwnedSlice(arena) catch return null;
    const v = vals.toOwnedSlice(arena) catch return null;
    return .{
        .value = .{ .record = .{ .keys = k, .values = v } },
        .pos = pos,
    };
}

fn parseScalarValue(arena: std.mem.Allocator, text: []const u8) Value {
    if (text.len == 0) return .null;

    // Boolean
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };

    // Null
    if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "~")) return .null;

    // Quoted string — strip quotes
    if (text.len >= 2) {
        if ((text[0] == '"' and text[text.len - 1] == '"') or
            (text[0] == '\'' and text[text.len - 1] == '\''))
        {
            return .{ .string = text[1 .. text.len - 1] };
        }
    }

    // Integer
    if (std.fmt.parseInt(i64, text, 10)) |n| {
        return .{ .int = n };
    } else |_| {}

    // Float
    if (std.fmt.parseFloat(f64, text)) |f| {
        // Only treat as float if it contains a dot (avoid "1e2" being float)
        if (std.mem.indexOfScalar(u8, text, '.') != null) {
            return .{ .float = f };
        }
    } else |_| {}

    // Inline list: [a, b, c]
    if (text[0] == '[' and text[text.len - 1] == ']') {
        return parseInlineList(arena, text[1 .. text.len - 1]);
    }

    // Plain string
    return .{ .string = text };
}

fn parseInlineList(arena: std.mem.Allocator, inner: []const u8) Value {
    var items = std.ArrayListUnmanaged(Value).empty;
    var pos: usize = 0;

    while (pos < inner.len) {
        // Skip whitespace
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) : (pos += 1) {}
        if (pos >= inner.len) break;

        // Find end of item (next comma or end)
        var end = pos;
        while (end < inner.len and inner[end] != ',') : (end += 1) {}

        // Trim trailing whitespace
        var item_end = end;
        while (item_end > pos and (inner[item_end - 1] == ' ' or inner[item_end - 1] == '\t')) {
            item_end -= 1;
        }

        if (item_end > pos) {
            items.append(arena, parseScalarValue(arena, inner[pos..item_end])) catch
                return .{ .array = &.{} };
        }

        pos = if (end < inner.len) end + 1 else end;
    }

    const slice = items.toOwnedSlice(arena) catch return .{ .array = &.{} };
    return .{ .array = slice };
}

fn nextLine(content: []const u8, pos: usize) usize {
    var p = pos;
    while (p < content.len and content[p] != '\n') : (p += 1) {}
    if (p < content.len) p += 1; // skip newline
    return p;
}

fn stripLineEnding(line: []const u8) []const u8 {
    var end = line.len;
    if (end > 0 and line[end - 1] == '\n') end -= 1;
    if (end > 0 and line[end - 1] == '\r') end -= 1;
    return line[0..end];
}

// Tests

const testing = std.testing;
const Parser = parser_mod.Parser;

fn testEval(program: []const u8, content: []const u8) ?Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var p = Parser.init(alloc, program);
    const node = p.parse() orelse return null;
    var evaluator = Evaluator.init(alloc, content);
    return evaluator.eval(node);
}

fn testRender(program: []const u8, content: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var p = Parser.init(alloc, program);
    const node = p.parse() orelse return null;
    var evaluator = Evaluator.init(alloc, content);
    const val = evaluator.eval(node) orelse return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    val.renderPlain(buf.writer(alloc)) catch return null;
    return buf.toOwnedSlice(alloc) catch null;
}

fn testRenderJson(program: []const u8, content: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var p = Parser.init(alloc, program);
    const node = p.parse() orelse return null;
    var evaluator = Evaluator.init(alloc, content);
    const val = evaluator.eval(node) orelse return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    val.renderJson(buf.writer(alloc)) catch return null;
    return buf.toOwnedSlice(alloc) catch null;
}

const test_doc =
    \\---
    \\title: Hello World
    \\draft: true
    \\count: 42
    \\tags: [go, zig]
    \\---
    \\# Introduction
    \\
    \\Some text with a [link](https://example.com) and [[wikilink]].
    \\
    \\## Methods
    \\
    \\More text here #tagged content.
    \\
    \\```go
    \\func main() {}
    \\```
    \\
;

test "frontmatter extracts record" {
    const val = testEval("frontmatter", test_doc).?;
    try testing.expect(val == .record);
    const title = val.record.get("title").?;
    try testing.expect(title == .string);
    try testing.expectEqualStrings("Hello World", title.string);
}

test "frontmatter field access" {
    const out = testRender("frontmatter | .title", test_doc).?;
    try testing.expectEqualStrings("Hello World", out);
}

test "frontmatter bool field" {
    const val = testEval("frontmatter | .draft", test_doc).?;
    try testing.expect(val == .bool);
    try testing.expectEqual(true, val.bool);
}

test "frontmatter int field" {
    const val = testEval("frontmatter | .count", test_doc).?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 42), val.int);
}

test "frontmatter inline list field" {
    const val = testEval("frontmatter | .tags", test_doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("go", val.array[0].string);
    try testing.expectEqualStrings("zig", val.array[1].string);
}

test "frontmatter missing field returns null" {
    const val = testEval("frontmatter | .nonexistent", test_doc).?;
    try testing.expect(val == .null);
}

test "frontmatter json" {
    const out = testRenderJson("frontmatter | .title", test_doc).?;
    try testing.expectEqualStrings("\"Hello World\"", out);
}

test "body extracts content without frontmatter" {
    const val = testEval("body", test_doc).?;
    try testing.expect(val == .string);
    try testing.expect(!std.mem.startsWith(u8, val.string, "---"));
    try testing.expect(std.mem.startsWith(u8, val.string, "# Introduction"));
}

test "body without frontmatter returns full content" {
    const val = testEval("body", "# Just a heading\n").?;
    try testing.expect(val == .string);
    try testing.expectEqualStrings("# Just a heading\n", val.string);
}

test "headings extracts array" {
    const val = testEval("headings", test_doc).?;
    try testing.expect(val == .array);
    try testing.expect(val.array.len >= 2);
    const first = val.array[0];
    try testing.expect(first == .record);
    try testing.expectEqualStrings("Introduction", first.record.get("text").?.string);
    try testing.expectEqual(@as(i64, 1), first.record.get("depth").?.int);
}

test "headings json" {
    const out = testRenderJson("headings", test_doc).?;
    try testing.expect(std.mem.startsWith(u8, out, "[{"));
    try testing.expect(std.mem.indexOf(u8, out, "\"Introduction\"") != null);
}

test "links extracts array" {
    const val = testEval("links", test_doc).?;
    try testing.expect(val == .array);
    try testing.expect(val.array.len >= 2);
    // Check standard link
    var found_standard = false;
    var found_wikilink = false;
    for (val.array) |l| {
        const kind = l.record.get("kind").?.string;
        if (std.mem.eql(u8, kind, "standard")) found_standard = true;
        if (std.mem.eql(u8, kind, "wikilink")) found_wikilink = true;
    }
    try testing.expect(found_standard);
    try testing.expect(found_wikilink);
}

test "tags extracts array" {
    const val = testEval("tags", test_doc).?;
    try testing.expect(val == .array);
    try testing.expect(val.array.len >= 1);
    const first = val.array[0];
    try testing.expect(first == .record);
    try testing.expectEqualStrings("tagged", first.record.get("name").?.string);
}

test "codeblocks extracts array" {
    const val = testEval("codeblocks", test_doc).?;
    try testing.expect(val == .array);
    try testing.expect(val.array.len >= 1);
    const first = val.array[0];
    try testing.expect(first == .record);
    try testing.expectEqualStrings("go", first.record.get("language").?.string);
    try testing.expectEqualStrings("func main() {}\n", first.record.get("content").?.string);
}

test "stats extracts record" {
    const val = testEval("stats", test_doc).?;
    try testing.expect(val == .record);
    const lines = val.record.get("lines").?.int;
    const words = val.record.get("words").?.int;
    try testing.expect(lines > 0);
    try testing.expect(words > 0);
}

test "stats field access" {
    const val = testEval("stats | .words", test_doc).?;
    try testing.expect(val == .int);
    try testing.expect(val.int > 0);
}

test "nested field access" {
    const doc =
        \\---
        \\author:
        \\  name: Alice
        \\  email: alice@example.com
        \\---
        \\content
        \\
    ;
    const val = testEval("frontmatter | .author.name", doc).?;
    try testing.expect(val == .string);
    try testing.expectEqualStrings("Alice", val.string);
}

test "pipeline three stages" {
    const val = testEval("frontmatter | .count", test_doc).?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 42), val.int);
}

test "comma produces array" {
    const val = testEval("frontmatter | .title, frontmatter | .count", test_doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("Hello World", val.array[0].string);
    try testing.expectEqual(@as(i64, 42), val.array[1].int);
}

test "comparison eq" {
    const val = testEval("frontmatter | .count == 42", test_doc);
    // This is field_access == literal, which is comparison in context
    // Actually this parses as: frontmatter | (.count == 42)
    // where .count == 42 evaluates with frontmatter record as input
    try testing.expect(val != null);
}

test "no frontmatter returns null" {
    const val = testEval("frontmatter", "# No frontmatter\n").?;
    try testing.expect(val == .null);
}

test "empty document" {
    const val = testEval("headings", "").?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "frontmatter block sequence" {
    const doc =
        \\---
        \\items:
        \\  - alpha
        \\  - beta
        \\  - gamma
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | .items", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqualStrings("alpha", val.array[0].string);
    try testing.expectEqualStrings("beta", val.array[1].string);
    try testing.expectEqualStrings("gamma", val.array[2].string);
}

test "frontmatter quoted string" {
    const doc =
        \\---
        \\title: "quoted value"
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | .title", doc).?;
    try testing.expect(val == .string);
    try testing.expectEqualStrings("quoted value", val.string);
}

test "plain render of array of records" {
    const out = testRender("headings", "# A\n## B\n").?;
    // Should produce readable output for each record
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "B") != null);
}
