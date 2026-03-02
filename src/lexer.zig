const std = @import("std");

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    pos: usize, // byte offset in source

    pub const Kind = enum {
        // Literals
        identifier,
        string,
        integer,
        float,

        // Keywords
        kw_and,
        kw_or,
        kw_not,
        kw_true,
        kw_false,
        kw_null,

        // Operators
        eq, // ==
        neq, // !=
        gte, // >=
        lte, // <=
        gt, // >
        lt, // <

        // Punctuation
        pipe, // |
        dot, // .
        comma, // ,
        lparen, // (
        rparen, // )

        // Special
        err,
        eof,
    };
};

/// Format a diagnostic message pointing to a position in the source.
/// Example output:
///   frontmatter | .title ==
///                         ^^ expected expression
pub fn formatError(source: []const u8, pos: usize, message: []const u8, buf: []u8) []const u8 {
    return formatErrorWithPrefix(source, pos, message, 0, buf);
}

pub fn formatErrorWithPrefix(source: []const u8, pos: usize, message: []const u8, prefix_len: usize, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writeError(source, pos, message, prefix_len, writer) catch {};
    return stream.getWritten();
}

fn writeError(source: []const u8, pos: usize, message: []const u8, prefix_len: usize, writer: anytype) !void {
    // Find the line containing pos
    var line_start: usize = 0;
    var idx: usize = 0;
    while (idx < pos and idx < source.len) : (idx += 1) {
        if (source[idx] == '\n') line_start = idx + 1;
    }

    var line_end: usize = pos;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line = source[line_start..line_end];
    const col = pos - line_start;

    try writer.writeAll(line);
    try writer.writeByte('\n');

    // Write caret at the right column, accounting for any prefix on the source line
    for (0..col + prefix_len) |_| {
        try writer.writeByte(' ');
    }
    try writer.writeByte('^');
    try writer.writeByte(' ');
    try writer.writeAll(message);
}

pub const Lexer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .text = "", .pos = self.pos };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '|' => return self.single(.pipe),
            '.' => return self.single(.dot),
            ',' => return self.single(.comma),
            '(' => return self.single(.lparen),
            ')' => return self.single(.rparen),
            '=' => {
                if (self.peek(1) == '=') return self.advance(.eq, 2);
                self.pos += 1;
                return .{ .kind = .err, .text = self.source[start..self.pos], .pos = start };
            },
            '!' => {
                if (self.peek(1) == '=') return self.advance(.neq, 2);
                self.pos += 1;
                return .{ .kind = .err, .text = self.source[start..self.pos], .pos = start };
            },
            '>' => {
                if (self.peek(1) == '=') return self.advance(.gte, 2);
                return self.single(.gt);
            },
            '<' => {
                if (self.peek(1) == '=') return self.advance(.lte, 2);
                return self.single(.lt);
            },
            '"' => return self.lexString(),
            else => {
                if (isDigit(c) or (c == '-' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
                    return self.lexNumber();
                }
                if (isIdentStart(c)) {
                    return self.lexIdentifier();
                }
                self.pos += 1;
                return .{ .kind = .err, .text = self.source[start..self.pos], .pos = start };
            },
        }
    }

    fn single(self: *Lexer, kind: Token.Kind) Token {
        const tok = Token{ .kind = kind, .text = self.source[self.pos .. self.pos + 1], .pos = self.pos };
        self.pos += 1;
        return tok;
    }

    fn advance(self: *Lexer, kind: Token.Kind, len: usize) Token {
        const tok = Token{ .kind = kind, .text = self.source[self.pos .. self.pos + len], .pos = self.pos };
        self.pos += len;
        return tok;
    }

    fn peek(self: *Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx < self.source.len) return self.source[idx];
        return null;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn lexString(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip opening quote
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                if (self.pos + 1 >= self.source.len) {
                    self.pos += 1;
                    return .{ .kind = .err, .text = self.source[start..self.pos], .pos = start };
                }
                self.pos += 2; // skip escape sequence
                continue;
            }
            if (c == '"') {
                self.pos += 1; // skip closing quote
                return .{ .kind = .string, .text = self.source[start..self.pos], .pos = start };
            }
            self.pos += 1;
        }
        // Unterminated string
        return .{ .kind = .err, .text = self.source[start..self.pos], .pos = start };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        if (self.source[self.pos] == '-') self.pos += 1;

        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.pos += 1;
        }

        // Check for float: need digit after dot to disambiguate from field access
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                self.pos += 1; // skip dot
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
                return .{ .kind = .float, .text = self.source[start..self.pos], .pos = start };
            }
        }

        return .{ .kind = .integer, .text = self.source[start..self.pos], .pos = start };
    }

    fn lexIdentifier(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        const kind: Token.Kind = keyword(text) orelse .identifier;
        return .{ .kind = kind, .text = text, .pos = start };
    }
};

fn keyword(text: []const u8) ?Token.Kind {
    const keywords = .{
        .{ "and", Token.Kind.kw_and },
        .{ "or", Token.Kind.kw_or },
        .{ "not", Token.Kind.kw_not },
        .{ "true", Token.Kind.kw_true },
        .{ "false", Token.Kind.kw_false },
        .{ "null", Token.Kind.kw_null },
    };
    inline for (keywords) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// Tests

const testing = std.testing;

fn expectTokens(source: []const u8, expected: []const Token.Kind) !void {
    var lex = Lexer.init(source);
    for (expected) |exp| {
        const tok = lex.next();
        try testing.expectEqual(exp, tok.kind);
    }
    try testing.expectEqual(Token.Kind.eof, lex.next().kind);
}

test "empty input" {
    var lex = Lexer.init("");
    try testing.expectEqual(Token.Kind.eof, lex.next().kind);
}

test "whitespace only" {
    var lex = Lexer.init("   \t\n  ");
    try testing.expectEqual(Token.Kind.eof, lex.next().kind);
}

test "identifier" {
    var lex = Lexer.init("frontmatter");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.identifier, tok.kind);
    try testing.expectEqualStrings("frontmatter", tok.text);
    try testing.expectEqual(@as(usize, 0), tok.pos);
}

test "multiple identifiers" {
    try expectTokens("headings select count", &.{ .identifier, .identifier, .identifier });
}

test "keywords" {
    try expectTokens("and or not true false null", &.{
        .kw_and, .kw_or, .kw_not, .kw_true, .kw_false, .kw_null,
    });
}

test "string literal" {
    var lex = Lexer.init("\"hello world\"");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.string, tok.kind);
    try testing.expectEqualStrings("\"hello world\"", tok.text);
}

test "string with escapes" {
    var lex = Lexer.init("\"line1\\nline2\"");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.string, tok.kind);
    try testing.expectEqualStrings("\"line1\\nline2\"", tok.text);
}

test "string with escaped quote" {
    var lex = Lexer.init("\"say \\\"hi\\\"\"");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.string, tok.kind);
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", tok.text);
}

test "unterminated string" {
    var lex = Lexer.init("\"oops");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.err, tok.kind);
    try testing.expectEqualStrings("\"oops", tok.text);
}

test "escape at end of string" {
    var lex = Lexer.init("\"trailing\\");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.err, tok.kind);
}

test "integer" {
    var lex = Lexer.init("42");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.integer, tok.kind);
    try testing.expectEqualStrings("42", tok.text);
}

test "negative integer" {
    var lex = Lexer.init("-7");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.integer, tok.kind);
    try testing.expectEqualStrings("-7", tok.text);
}

test "float" {
    var lex = Lexer.init("3.14");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.float, tok.kind);
    try testing.expectEqualStrings("3.14", tok.text);
}

test "integer followed by dot field" {
    try expectTokens("42.field", &.{ .integer, .dot, .identifier });
}

test "comparison operators" {
    try expectTokens("== != >= <= > <", &.{ .eq, .neq, .gte, .lte, .gt, .lt });
}

test "punctuation" {
    try expectTokens("| . , ( )", &.{ .pipe, .dot, .comma, .lparen, .rparen });
}

test "pipeline expression" {
    try expectTokens("frontmatter | .title", &.{ .identifier, .pipe, .dot, .identifier });
}

test "select expression" {
    try expectTokens(
        "select(.depth == 2)",
        &.{ .identifier, .lparen, .dot, .identifier, .eq, .integer, .rparen },
    );
}

test "complex pipeline" {
    try expectTokens(
        "headings | select(.depth >= 2 and .depth <= 3)",
        &.{
            .identifier, .pipe,       .identifier, .lparen,
            .dot,        .identifier, .gte,        .integer,
            .kw_and,     .dot,        .identifier,  .lte,
            .integer,    .rparen,
        },
    );
}

test "function call with string arg" {
    try expectTokens(
        "contains(.target, \"github\")",
        &.{ .identifier, .lparen, .dot, .identifier, .comma, .string, .rparen },
    );
}

test "comma operator" {
    try expectTokens(".title, .date", &.{ .dot, .identifier, .comma, .dot, .identifier });
}

test "negation" {
    try expectTokens("not (.language == \"\")", &.{
        .kw_not, .lparen, .dot, .identifier, .eq, .string, .rparen,
    });
}

test "set with bool literal" {
    try expectTokens(
        "set(.draft, false)",
        &.{ .identifier, .lparen, .dot, .identifier, .comma, .kw_false, .rparen },
    );
}

test "set with null" {
    try expectTokens(
        "set(.field, null)",
        &.{ .identifier, .lparen, .dot, .identifier, .comma, .kw_null, .rparen },
    );
}

test "nested field access" {
    try expectTokens(".author.name", &.{ .dot, .identifier, .dot, .identifier });
}

test "no whitespace between tokens" {
    try expectTokens("a|b", &.{ .identifier, .pipe, .identifier });
}

test "unknown character produces error" {
    var lex = Lexer.init("@");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.err, tok.kind);
    try testing.expectEqualStrings("@", tok.text);
    try testing.expectEqual(@as(usize, 0), tok.pos);
}

test "bare equals is error" {
    var lex = Lexer.init("=");
    try testing.expectEqual(Token.Kind.err, lex.next().kind);
}

test "bare bang is error" {
    var lex = Lexer.init("!");
    try testing.expectEqual(Token.Kind.err, lex.next().kind);
}

test "section with heading syntax" {
    try expectTokens(
        "section(\"## Methods\")",
        &.{ .identifier, .lparen, .string, .rparen },
    );
}

test "identifier with underscore" {
    var lex = Lexer.init("start_line");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.identifier, tok.kind);
    try testing.expectEqualStrings("start_line", tok.text);
}

test "identifier with digits" {
    var lex = Lexer.init("h2");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.identifier, tok.kind);
    try testing.expectEqualStrings("h2", tok.text);
}

test "negative sign without digit is not a number" {
    try expectTokens("- 5", &.{ .err, .integer });
}

test "zero" {
    var lex = Lexer.init("0");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.integer, tok.kind);
    try testing.expectEqualStrings("0", tok.text);
}

test "empty string literal" {
    var lex = Lexer.init("\"\"");
    const tok = lex.next();
    try testing.expectEqual(Token.Kind.string, tok.kind);
    try testing.expectEqualStrings("\"\"", tok.text);
}

test "token position tracking" {
    var lex = Lexer.init("a | b");
    const a = lex.next();
    try testing.expectEqual(@as(usize, 0), a.pos);
    const p = lex.next();
    try testing.expectEqual(@as(usize, 2), p.pos);
    const b = lex.next();
    try testing.expectEqual(@as(usize, 4), b.pos);
}

test "eof position at end" {
    var lex = Lexer.init("ab");
    _ = lex.next(); // "ab"
    const eof = lex.next();
    try testing.expectEqual(Token.Kind.eof, eof.kind);
    try testing.expectEqual(@as(usize, 2), eof.pos);
}

test "error position for unknown char" {
    var lex = Lexer.init("ok @ bad");
    _ = lex.next(); // ok
    const err_tok = lex.next();
    try testing.expectEqual(Token.Kind.err, err_tok.kind);
    try testing.expectEqual(@as(usize, 3), err_tok.pos);
}

test "formatError single line" {
    var buf: [256]u8 = undefined;
    const msg = formatError("frontmatter | .title ==", 23, "expected expression", &buf);
    try testing.expectEqualStrings(
        "frontmatter | .title ==\n" ++
            "                       ^ expected expression",
        msg,
    );
}

test "formatError at start" {
    var buf: [256]u8 = undefined;
    const msg = formatError("@foo", 0, "unexpected character", &buf);
    try testing.expectEqualStrings(
        "@foo\n" ++
            "^ unexpected character",
        msg,
    );
}

test "formatError mid token" {
    var buf: [256]u8 = undefined;
    const msg = formatError("select(.x = 1)", 10, "expected '=='", &buf);
    try testing.expectEqualStrings(
        "select(.x = 1)\n" ++
            "          ^ expected '=='",
        msg,
    );
}
