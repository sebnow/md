const std = @import("std");
const lexer_mod = @import("lexer.zig");
const Token = lexer_mod.Token;
const Lexer = lexer_mod.Lexer;

pub const Node = union(enum) {
    pipeline: Pipeline,
    field_access: FieldAccess,
    fn_call: FnCall,
    literal: Literal,
    binary: Binary,
    unary: Unary,
    comma: Comma,

    pub const Pipeline = struct {
        stages: []const *const Node,
    };

    pub const FieldAccess = struct {
        parts: []const []const u8,
    };

    pub const FnCall = struct {
        name: []const u8,
        args: []const *const Node,
    };

    pub const Literal = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
        bool: bool,
        null,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: *const Node,
        right: *const Node,
    };

    pub const BinaryOp = enum {
        eq,
        neq,
        lt,
        gt,
        lte,
        gte,
        op_and,
        op_or,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *const Node,
    };

    pub const UnaryOp = enum {
        op_not,
    };

    pub const Comma = struct {
        exprs: []const *const Node,
    };
};

pub const ParseError = struct {
    message: []const u8,
    pos: usize,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    prev_end: usize,
    arena: std.mem.Allocator,
    err: ?ParseError,
    depth: u16 = 0,

    const max_depth = 256;

    pub fn init(arena: std.mem.Allocator, source: []const u8) Parser {
        var lex = Lexer.init(source);
        const first = lex.next();
        return .{
            .lexer = lex,
            .current = first,
            .prev_end = 0,
            .arena = arena,
            .err = null,
        };
    }

    pub fn parse(self: *Parser) ?*const Node {
        const result = self.parseComma() orelse return null;
        if (self.current.kind != .eof) {
            self.setError("unexpected token", self.current.pos);
            return null;
        }
        return result;
    }

    // comma = pipeline (',' pipeline)*
    // Comma at the top level produces multiple outputs from the same input.
    fn parseComma(self: *Parser) ?*const Node {
        const first = self.parsePipeline() orelse return null;

        if (self.current.kind != .comma) return first;

        var exprs = std.ArrayListUnmanaged(*const Node).empty;
        exprs.append(self.arena, first) catch @panic("out of memory");

        while (self.current.kind == .comma) {
            self.advance();
            const expr = self.parsePipeline() orelse return null;
            exprs.append(self.arena, expr) catch @panic("out of memory");
        }

        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .comma = .{ .exprs = exprs.toOwnedSlice(self.arena) catch @panic("out of memory") } };
        return node;
    }

    // pipeline = or_expr ('|' or_expr)*
    fn parsePipeline(self: *Parser) ?*const Node {
        const first = self.parseOr() orelse return null;

        if (self.current.kind != .pipe) return first;

        var stages = std.ArrayListUnmanaged(*const Node).empty;
        stages.append(self.arena, first) catch @panic("out of memory");

        while (self.current.kind == .pipe) {
            self.advance();
            const stage = self.parseOr() orelse return null;
            stages.append(self.arena, stage) catch @panic("out of memory");
        }

        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .pipeline = .{ .stages = stages.toOwnedSlice(self.arena) catch @panic("out of memory") } };
        return node;
    }

    // or_expr = and_expr ('or' and_expr)*
    fn parseOr(self: *Parser) ?*const Node {
        var left = self.parseAnd() orelse return null;

        while (self.current.kind == .kw_or) {
            self.advance();
            const right = self.parseAnd() orelse return null;
            const node = self.arena.create(Node) catch @panic("out of memory");
            node.* = .{ .binary = .{ .op = .op_or, .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    // and_expr = not_expr ('and' not_expr)*
    fn parseAnd(self: *Parser) ?*const Node {
        var left = self.parseNot() orelse return null;

        while (self.current.kind == .kw_and) {
            self.advance();
            const right = self.parseNot() orelse return null;
            const node = self.arena.create(Node) catch @panic("out of memory");
            node.* = .{ .binary = .{ .op = .op_and, .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    // not_expr = 'not' not_expr | comparison
    fn parseNot(self: *Parser) ?*const Node {
        if (self.current.kind == .kw_not) {
            if (self.depth >= max_depth) {
                self.setError("expression nested too deeply", self.current.pos);
                return null;
            }
            self.depth += 1;
            defer self.depth -= 1;
            self.advance();
            const operand = self.parseNot() orelse return null;
            const node = self.arena.create(Node) catch @panic("out of memory");
            node.* = .{ .unary = .{ .op = .op_not, .operand = operand } };
            return node;
        }
        return self.parseComparison();
    }

    // comparison = postfix (('==' | '!=' | '<' | '>' | '<=' | '>=') postfix)?
    fn parseComparison(self: *Parser) ?*const Node {
        const left = self.parsePostfix() orelse return null;

        const op: Node.BinaryOp = switch (self.current.kind) {
            .eq => .eq,
            .neq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            else => return left,
        };

        self.advance();
        const right = self.parsePostfix() orelse return null;
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .binary = .{ .op = op, .left = left, .right = right } };
        return node;
    }

    // postfix = primary ('.' identifier)*
    fn parsePostfix(self: *Parser) ?*const Node {
        var result = self.parsePrimary() orelse return null;

        while (self.current.kind == .dot) {
            // Check if this dot starts a field access on the result
            // vs being a standalone .field (which parsePrimary handles)
            self.advance();
            if (self.current.kind != .identifier) {
                self.setError("expected field name after '.'", self.current.pos);
                return null;
            }
            // Wrap as a function-call-like field access on the result
            // This handles: expr.field (e.g., first.text)
            const parts = self.arena.alloc([]const u8, 1) catch @panic("out of memory");
            parts[0] = self.current.text;
            self.advance();
            const access = self.arena.create(Node) catch @panic("out of memory");
            access.* = .{ .field_access = .{ .parts = parts } };

            // Create a pipeline: result | .field
            const stages = self.arena.alloc(*const Node, 2) catch @panic("out of memory");
            stages[0] = result;
            stages[1] = access;
            const pipe = self.arena.create(Node) catch @panic("out of memory");
            pipe.* = .{ .pipeline = .{ .stages = stages } };
            result = pipe;
        }

        return result;
    }

    // primary = '.' identifier ('.' identifier)*   -- field access
    //         | identifier '(' args? ')'           -- function call
    //         | identifier                          -- bare identifier (extractor)
    //         | literal
    //         | '(' comma ')'                      -- grouping
    fn parsePrimary(self: *Parser) ?*const Node {
        switch (self.current.kind) {
            .dot => return self.parseFieldAccess(),
            .identifier => return self.parseIdentOrCall(),
            .string => return self.parseStringLiteral(),
            .integer => return self.parseIntLiteral(),
            .float => return self.parseFloatLiteral(),
            .kw_true => return self.parseBoolLiteral(true),
            .kw_false => return self.parseBoolLiteral(false),
            .kw_null => return self.parseNullLiteral(),
            .lparen => return self.parseGroup(),
            .err => {
                self.setError("unexpected character", self.current.pos);
                return null;
            },
            .eof => {
                self.setError("unexpected end of input", self.current.pos);
                return null;
            },
            else => {
                self.setError("unexpected token", self.current.pos);
                return null;
            },
        }
    }

    // '.' identifier ('.' identifier)*
    fn parseFieldAccess(self: *Parser) ?*const Node {
        var parts = std.ArrayListUnmanaged([]const u8).empty;

        while (self.current.kind == .dot) {
            self.advance();
            if (self.current.kind != .identifier) {
                self.setError("expected field name after '.'", self.current.pos);
                return null;
            }
            parts.append(self.arena, self.current.text) catch @panic("out of memory");
            self.advance();
        }

        if (parts.items.len == 0) {
            self.setError("expected field name after '.'", self.current.pos);
            return null;
        }

        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .field_access = .{ .parts = parts.toOwnedSlice(self.arena) catch @panic("out of memory") } };
        return node;
    }

    // identifier ('(' args? ')')?
    fn parseIdentOrCall(self: *Parser) ?*const Node {
        const name = self.current.text;
        self.advance();

        if (self.current.kind != .lparen) {
            // Bare identifier (extractor like frontmatter, headings, etc.)
            const node = self.arena.create(Node) catch @panic("out of memory");
            node.* = .{ .fn_call = .{ .name = name, .args = &.{} } };
            return node;
        }

        // Function call
        self.advance(); // skip '('

        var args = std.ArrayListUnmanaged(*const Node).empty;
        if (self.current.kind != .rparen) {
            const first = self.parsePipeline() orelse return null;
            args.append(self.arena, first) catch @panic("out of memory");

            while (self.current.kind == .comma) {
                self.advance();
                const arg = self.parsePipeline() orelse return null;
                args.append(self.arena, arg) catch @panic("out of memory");
            }
        }

        if (self.current.kind != .rparen) {
            self.setError("expected ')'", self.current.pos);
            return null;
        }
        self.advance();

        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .fn_call = .{ .name = name, .args = args.toOwnedSlice(self.arena) catch @panic("out of memory") } };
        return node;
    }

    fn parseStringLiteral(self: *Parser) ?*const Node {
        const raw = self.current.text;
        // Strip quotes
        const content = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
        self.advance();
        const unescaped = unescapeString(self.arena, content);
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .literal = .{ .string = unescaped } };
        return node;
    }

    fn parseIntLiteral(self: *Parser) ?*const Node {
        const n = std.fmt.parseInt(i64, self.current.text, 10) catch {
            self.setError("invalid integer", self.current.pos);
            return null;
        };
        self.advance();
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .literal = .{ .integer = n } };
        return node;
    }

    fn parseFloatLiteral(self: *Parser) ?*const Node {
        const f = std.fmt.parseFloat(f64, self.current.text) catch {
            self.setError("invalid float", self.current.pos);
            return null;
        };
        self.advance();
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .literal = .{ .float = f } };
        return node;
    }

    fn parseBoolLiteral(self: *Parser, val: bool) ?*const Node {
        self.advance();
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .literal = .{ .bool = val } };
        return node;
    }

    fn parseNullLiteral(self: *Parser) ?*const Node {
        self.advance();
        const node = self.arena.create(Node) catch @panic("out of memory");
        node.* = .{ .literal = .null };
        return node;
    }

    fn parseGroup(self: *Parser) ?*const Node {
        if (self.depth >= max_depth) {
            self.setError("expression nested too deeply", self.current.pos);
            return null;
        }
        self.depth += 1;
        defer self.depth -= 1;
        self.advance(); // skip '('
        const inner = self.parseComma() orelse return null;
        if (self.current.kind != .rparen) {
            self.setError("expected ')'", self.current.pos);
            return null;
        }
        self.advance();
        return inner;
    }

    fn advance(self: *Parser) void {
        self.prev_end = self.current.pos + self.current.text.len;
        self.current = self.lexer.next();
    }

    fn setError(self: *Parser, message: []const u8, pos: usize) void {
        if (self.err == null) {
            self.err = .{ .message = message, .pos = pos };
        }
    }

    /// Format the parse error as a diagnostic string.
    /// Returns null if no error occurred.
    pub fn formatError(self: *Parser, buf: []u8) ?[]const u8 {
        return self.formatErrorWithPrefix(0, buf);
    }

    pub fn formatErrorWithPrefix(self: *Parser, prefix_len: usize, buf: []u8) ?[]const u8 {
        const e = self.err orelse return null;
        return lexer_mod.formatErrorWithPrefix(self.lexer.source, e.pos, e.message, prefix_len, buf);
    }
};

fn unescapeString(arena: std.mem.Allocator, content: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, content, '\\') == null) return content;

    var buf = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            const next = content[i + 1];
            const replacement: u8 = switch (next) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => {
                    buf.append(arena, content[i]) catch @panic("out of memory");
                    i += 1;
                    continue;
                },
            };
            buf.append(arena, replacement) catch @panic("out of memory");
            i += 2;
        } else {
            buf.append(arena, content[i]) catch @panic("out of memory");
            i += 1;
        }
    }
    return buf.toOwnedSlice(arena) catch @panic("out of memory");
}

// Tests

const testing = std.testing;

fn testParse(source: []const u8) ?*const Node {
    // Use page_allocator to avoid leak detection on arena internals.
    // Arena memory is freed in bulk — individual allocations are not
    // tracked, so the testing allocator would report false leaks.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var parser = Parser.init(arena.allocator(), source);
    return parser.parse();
}

fn testParseErr(source: []const u8) ParseError {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var parser = Parser.init(arena.allocator(), source);
    const result = parser.parse();
    testing.expect(result == null) catch unreachable;
    return parser.err.?;
}

test "bare extractor" {
    const node = testParse("frontmatter").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("frontmatter", node.fn_call.name);
    try testing.expectEqual(@as(usize, 0), node.fn_call.args.len);
}

test "field access" {
    const node = testParse(".title").?;
    try testing.expect(node.* == .field_access);
    try testing.expectEqual(@as(usize, 1), node.field_access.parts.len);
    try testing.expectEqualStrings("title", node.field_access.parts[0]);
}

test "nested field access" {
    const node = testParse(".author.name").?;
    try testing.expect(node.* == .field_access);
    try testing.expectEqual(@as(usize, 2), node.field_access.parts.len);
    try testing.expectEqualStrings("author", node.field_access.parts[0]);
    try testing.expectEqualStrings("name", node.field_access.parts[1]);
}

test "pipeline" {
    const node = testParse("frontmatter | .title").?;
    try testing.expect(node.* == .pipeline);
    try testing.expectEqual(@as(usize, 2), node.pipeline.stages.len);
    try testing.expect(node.pipeline.stages[0].* == .fn_call);
    try testing.expect(node.pipeline.stages[1].* == .field_access);
}

test "three-stage pipeline" {
    const node = testParse("headings | select(.depth == 2) | count").?;
    try testing.expect(node.* == .pipeline);
    try testing.expectEqual(@as(usize, 3), node.pipeline.stages.len);
}

test "function call no args" {
    const node = testParse("keys").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("keys", node.fn_call.name);
}

test "function call with string arg" {
    const node = testParse("section(\"## Methods\")").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("section", node.fn_call.name);
    try testing.expectEqual(@as(usize, 1), node.fn_call.args.len);
    try testing.expect(node.fn_call.args[0].* == .literal);
    try testing.expectEqualStrings("## Methods", node.fn_call.args[0].literal.string);
}

test "function call with two args" {
    const node = testParse("set(.title, \"New\")").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("set", node.fn_call.name);
    try testing.expectEqual(@as(usize, 2), node.fn_call.args.len);
}

test "select with comparison" {
    const node = testParse("select(.depth == 2)").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("select", node.fn_call.name);
    try testing.expectEqual(@as(usize, 1), node.fn_call.args.len);
    const pred = node.fn_call.args[0];
    try testing.expect(pred.* == .binary);
    try testing.expectEqual(Node.BinaryOp.eq, pred.binary.op);
}

test "comparison operators" {
    const ops = [_]struct { src: []const u8, op: Node.BinaryOp }{
        .{ .src = ".a == 1", .op = .eq },
        .{ .src = ".a != 1", .op = .neq },
        .{ .src = ".a < 1", .op = .lt },
        .{ .src = ".a > 1", .op = .gt },
        .{ .src = ".a <= 1", .op = .lte },
        .{ .src = ".a >= 1", .op = .gte },
    };
    for (ops) |case| {
        const node = testParse(case.src).?;
        try testing.expect(node.* == .binary);
        try testing.expectEqual(case.op, node.binary.op);
    }
}

test "and expression" {
    const node = testParse(".a == 1 and .b == 2").?;
    try testing.expect(node.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_and, node.binary.op);
    try testing.expect(node.binary.left.* == .binary);
    try testing.expect(node.binary.right.* == .binary);
}

test "or expression" {
    const node = testParse(".a == 1 or .b == 2").?;
    try testing.expect(node.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_or, node.binary.op);
}

test "and binds tighter than or" {
    // a or b and c  =>  a or (b and c)
    const node = testParse(".a == 1 or .b == 2 and .c == 3").?;
    try testing.expect(node.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_or, node.binary.op);
    try testing.expect(node.binary.right.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_and, node.binary.right.binary.op);
}

test "not expression" {
    const node = testParse("not .draft").?;
    try testing.expect(node.* == .unary);
    try testing.expectEqual(Node.UnaryOp.op_not, node.unary.op);
}

test "not with parenthesized expression" {
    const node = testParse("not (.language == \"\")").?;
    try testing.expect(node.* == .unary);
    try testing.expect(node.unary.operand.* == .binary);
}

test "comma operator" {
    const node = testParse(".title, .date").?;
    try testing.expect(node.* == .comma);
    try testing.expectEqual(@as(usize, 2), node.comma.exprs.len);
}

test "comma with pipelines" {
    const node = testParse("headings | count, links | count").?;
    try testing.expect(node.* == .comma);
    try testing.expectEqual(@as(usize, 2), node.comma.exprs.len);
    try testing.expect(node.comma.exprs[0].* == .pipeline);
    try testing.expect(node.comma.exprs[1].* == .pipeline);
}

test "integer literal" {
    const node = testParse("42").?;
    try testing.expect(node.* == .literal);
    try testing.expectEqual(@as(i64, 42), node.literal.integer);
}

test "negative integer literal" {
    const node = testParse("-7").?;
    try testing.expect(node.* == .literal);
    try testing.expectEqual(@as(i64, -7), node.literal.integer);
}

test "float literal" {
    const node = testParse("3.14").?;
    try testing.expect(node.* == .literal);
    try testing.expectEqual(@as(f64, 3.14), node.literal.float);
}

test "bool literal true" {
    const node = testParse("true").?;
    try testing.expect(node.* == .literal);
    try testing.expectEqual(true, node.literal.bool);
}

test "bool literal false" {
    const node = testParse("false").?;
    try testing.expect(node.* == .literal);
    try testing.expectEqual(false, node.literal.bool);
}

test "null literal" {
    const node = testParse("null").?;
    try testing.expect(node.* == .literal);
    try testing.expect(node.literal == .null);
}

test "grouped expression" {
    const node = testParse("(.a == 1)").?;
    try testing.expect(node.* == .binary);
}

test "contains function call" {
    const node = testParse("contains(.target, \"github\")").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("contains", node.fn_call.name);
    try testing.expectEqual(@as(usize, 2), node.fn_call.args.len);
}

test "complex: select with and" {
    const node = testParse("select(.depth >= 2 and .depth <= 3)").?;
    try testing.expect(node.* == .fn_call);
    const pred = node.fn_call.args[0];
    try testing.expect(pred.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_and, pred.binary.op);
}

test "complex: select with or" {
    const node = testParse("select(.language == \"go\" or .language == \"zig\")").?;
    try testing.expect(node.* == .fn_call);
    const pred = node.fn_call.args[0];
    try testing.expect(pred.* == .binary);
    try testing.expectEqual(Node.BinaryOp.op_or, pred.binary.op);
}

test "complex: full pipeline" {
    const node = testParse("codeblocks | select(.language == \"go\") | first | .content").?;
    try testing.expect(node.* == .pipeline);
    try testing.expectEqual(@as(usize, 4), node.pipeline.stages.len);
}

test "complex: set chained" {
    const node = testParse("frontmatter | set(.title, \"New\") | set(.draft, false)").?;
    try testing.expect(node.* == .pipeline);
    try testing.expectEqual(@as(usize, 3), node.pipeline.stages.len);
}

test "error: empty input" {
    const err = testParseErr("");
    try testing.expectEqualStrings("unexpected end of input", err.message);
}

test "error: missing closing paren" {
    const err = testParseErr("select(.a == 1");
    try testing.expectEqualStrings("expected ')'", err.message);
}

test "error: missing field name after dot" {
    const err = testParseErr(". ");
    try testing.expectEqualStrings("expected field name after '.'", err.message);
}

test "error: unexpected token after valid expr" {
    const err = testParseErr("frontmatter )");
    try testing.expectEqualStrings("unexpected token", err.message);
}

test "error: bare operator" {
    const err = testParseErr("==");
    try testing.expectEqualStrings("unexpected token", err.message);
}

test "error: formatError produces diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var parser = Parser.init(arena.allocator(), "select(.x = 1)");
    _ = parser.parse();
    var buf: [256]u8 = undefined;
    const msg = parser.formatError(&buf).?;
    // Should contain the source line and a caret
    try testing.expect(std.mem.indexOf(u8, msg, "^") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "select(.x = 1)") != null);
}

test "error: unknown character" {
    const err = testParseErr("@");
    try testing.expectEqualStrings("unexpected character", err.message);
}

test "error: deeply nested not" {
    // 300 levels of "not " exceeds max_depth (256)
    const err = testParseErr("not " ** 300 ++ ".x");
    try testing.expectEqualStrings("expression nested too deeply", err.message);
}

test "error: deeply nested parens" {
    const err = testParseErr("(" ** 300 ++ ".x" ++ ")" ** 300);
    try testing.expectEqualStrings("expression nested too deeply", err.message);
}

test "function call with pipeline arg" {
    // contains(.target, "github") inside select
    const node = testParse("select(contains(.target, \"github\"))").?;
    try testing.expect(node.* == .fn_call);
    try testing.expectEqualStrings("select", node.fn_call.name);
    const inner = node.fn_call.args[0];
    try testing.expect(inner.* == .fn_call);
    try testing.expectEqualStrings("contains", inner.fn_call.name);
}
