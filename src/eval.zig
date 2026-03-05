const std = @import("std");
const parser_mod = @import("parser.zig");
const value_mod = @import("value.zig");
const md = struct {
    const frontmatter = @import("frontmatter.zig");
    const headings = @import("headings.zig");
    const links = @import("links.zig");
    const codeblocks = @import("codeblocks.zig");
    const tags = @import("tags.zig");
    const comments = @import("comments.zig");
    const footnotes = @import("footnotes.zig");
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
    file_path: ?[]const u8,
    dir_path: ?[]const u8,

    pub fn init(arena: std.mem.Allocator, content: []const u8) Evaluator {
        return .{
            .arena = arena,
            .content = content,
            .err = null,
            .file_path = null,
            .dir_path = null,
        };
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
        // Extractors: operate on document content, or piped string input
        if (fc.args.len == 0 and self.isExtractor(fc.name)) {
            if (input) |inp| {
                // When piped a string (e.g. from section()), parse that instead
                if (inp == .string) {
                    return self.evalExtractorOnContent(fc.name, inp.string);
                }
            }
            return self.evalExtractor(fc.name);
        }

        // select(predicate): filter arrays
        if (std.mem.eql(u8, fc.name, "select")) {
            return self.evalSelect(fc, input);
        }

        // contains(field, substring)
        if (std.mem.eql(u8, fc.name, "contains")) {
            return self.evalContains(fc, input);
        }

        // startswith(field, prefix)
        if (std.mem.eql(u8, fc.name, "startswith")) {
            return self.evalStartswith(fc, input);
        }

        // map(.field): extract field from each element
        if (std.mem.eql(u8, fc.name, "map")) {
            return self.evalMap(fc, input);
        }

        // sort(.field): sort array by field
        if (std.mem.eql(u8, fc.name, "sort")) {
            return self.evalSort(fc, input);
        }

        // group(.field): group array by field
        if (std.mem.eql(u8, fc.name, "group")) {
            return self.evalGroup(fc, input);
        }

        // set(.field, value): modify frontmatter field
        if (std.mem.eql(u8, fc.name, "set")) {
            return self.evalSet(fc, input);
        }

        // del(.field): delete frontmatter field
        if (std.mem.eql(u8, fc.name, "del")) {
            return self.evalDel(fc, input);
        }

        // section("heading"): extract section content
        if (std.mem.eql(u8, fc.name, "section")) {
            return self.evalSection(fc);
        }

        // replace("text"): replace section/mutation content
        if (std.mem.eql(u8, fc.name, "replace")) {
            return self.evalReplace(fc, input);
        }

        // append("text"): append to section/mutation content
        if (std.mem.eql(u8, fc.name, "append")) {
            return self.evalAppend(fc, input);
        }

        // keys: list record keys
        if (std.mem.eql(u8, fc.name, "keys")) {
            return self.evalKeys(input);
        }

        // has("field"): check if record has field
        if (std.mem.eql(u8, fc.name, "has")) {
            return self.evalHas(fc, input);
        }

        // No-arg builtins that operate on input
        if (fc.args.len == 0 and input != null) {
            if (std.mem.eql(u8, fc.name, "first")) return self.evalFirst(input.?);
            if (std.mem.eql(u8, fc.name, "last")) return self.evalLast(input.?);
            if (std.mem.eql(u8, fc.name, "count")) return self.evalCount(input.?);
            if (std.mem.eql(u8, fc.name, "unique")) return self.evalUnique(input.?);
            if (std.mem.eql(u8, fc.name, "reverse")) return self.evalReverse(input.?);
            if (std.mem.eql(u8, fc.name, "exists")) return self.evalExists(input.?);
            if (std.mem.eql(u8, fc.name, "resolve")) return self.evalResolve(input.?);
            if (std.mem.eql(u8, fc.name, "yaml")) return self.evalYaml(input.?);
            if (std.mem.eql(u8, fc.name, "toml")) return self.evalToml(input.?);
        }

        self.setErrorFmt("unknown function: {s}", .{fc.name});
        return null;
    }

    fn isExtractor(self: *Evaluator, name: []const u8) bool {
        _ = self;
        const extractors = [_][]const u8{
            "frontmatter", "body",      "headings",  "links",
            "tags",        "codeblocks", "stats",    "comments",
            "footnotes",   "incoming",
        };
        for (extractors) |e| {
            if (std.mem.eql(u8, name, e)) return true;
        }
        return false;
    }

    fn evalExtractor(self: *Evaluator, name: []const u8) ?Value {
        return self.evalExtractorOnContent(name, self.content);
    }

    fn evalExtractorOnContent(self: *Evaluator, name: []const u8, content: []const u8) ?Value {
        if (std.mem.eql(u8, name, "frontmatter")) return self.extractFrontmatterFrom(content);
        if (std.mem.eql(u8, name, "body")) return self.extractBodyFrom(content);
        if (std.mem.eql(u8, name, "headings")) return self.extractHeadingsFrom(content);
        if (std.mem.eql(u8, name, "links")) return self.extractLinksFrom(content);
        if (std.mem.eql(u8, name, "tags")) return self.extractTagsFrom(content);
        if (std.mem.eql(u8, name, "codeblocks")) return self.extractCodeblocksFrom(content);
        if (std.mem.eql(u8, name, "stats")) return self.extractStatsFrom(content);
        if (std.mem.eql(u8, name, "comments")) return self.extractCommentsFrom(content);
        if (std.mem.eql(u8, name, "footnotes")) return self.extractFootnotesFrom(content);
        if (std.mem.eql(u8, name, "incoming")) return self.extractIncoming();
        return null;
    }

    fn evalSelect(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("select() requires exactly one argument", 0);
            return null;
        }
        const predicate = fc.args[0];
        const inp = input orelse {
            self.setError("select() requires input", 0);
            return null;
        };

        switch (inp) {
            .array => |arr| {
                var results = std.ArrayListUnmanaged(Value).empty;
                for (arr) |item| {
                    const pred_val = self.evalWithInput(predicate, item) orelse continue;
                    if (isTruthy(pred_val)) {
                        results.append(self.arena, item) catch @panic("out of memory");
                    }
                }
                const slice = results.toOwnedSlice(self.arena) catch @panic("out of memory");
                return .{ .array = slice };
            },
            else => {
                // select on a single value: return it if predicate is true, null otherwise
                const pred_val = self.evalWithInput(predicate, inp) orelse return null;
                if (isTruthy(pred_val)) return inp;
                return .null;
            },
        }
    }

    fn evalContains(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 2) {
            self.setError("contains() requires two arguments", 0);
            return null;
        }

        const inp = input orelse .null;
        const field_val = self.evalWithInput(fc.args[0], inp) orelse return null;
        const substr_val = self.evalWithInput(fc.args[1], inp) orelse return null;

        const haystack = switch (field_val) {
            .string => |s| s,
            else => return .{ .bool = false },
        };
        const needle = switch (substr_val) {
            .string => |s| s,
            else => return .{ .bool = false },
        };

        return .{ .bool = std.mem.indexOf(u8, haystack, needle) != null };
    }

    fn evalStartswith(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 2) {
            self.setError("startswith() requires two arguments", 0);
            return null;
        }

        const inp = input orelse .null;
        const field_val = self.evalWithInput(fc.args[0], inp) orelse return null;
        const prefix_val = self.evalWithInput(fc.args[1], inp) orelse return null;

        const haystack = switch (field_val) {
            .string => |s| s,
            else => return .{ .bool = false },
        };
        const prefix = switch (prefix_val) {
            .string => |s| s,
            else => return .{ .bool = false },
        };

        return .{ .bool = std.mem.startsWith(u8, haystack, prefix) };
    }

    fn evalFirst(self: *Evaluator, input: Value) ?Value {
        _ = self;
        return switch (input) {
            .array => |arr| if (arr.len > 0) arr[0] else .null,
            else => input,
        };
    }

    fn evalLast(self: *Evaluator, input: Value) ?Value {
        _ = self;
        return switch (input) {
            .array => |arr| if (arr.len > 0) arr[arr.len - 1] else .null,
            else => input,
        };
    }

    fn evalCount(self: *Evaluator, input: Value) ?Value {
        _ = self;
        return switch (input) {
            .array => |arr| .{ .int = @intCast(arr.len) },
            .string => |s| .{ .int = @intCast(s.len) },
            .record => |rec| .{ .int = @intCast(rec.keys.len) },
            else => .{ .int = 1 },
        };
    }

    fn evalUnique(self: *Evaluator, input: Value) ?Value {
        const arr = switch (input) {
            .array => |a| a,
            else => return input,
        };

        var results = std.ArrayListUnmanaged(Value).empty;
        for (arr) |item| {
            var found = false;
            for (results.items) |existing| {
                if (item.eql(existing)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                results.append(self.arena, item) catch @panic("out of memory");
            }
        }
        const slice = results.toOwnedSlice(self.arena) catch @panic("out of memory");
        return .{ .array = slice };
    }

    fn evalReverse(self: *Evaluator, input: Value) ?Value {
        const arr = switch (input) {
            .array => |a| a,
            else => return input,
        };

        const reversed = self.arena.alloc(Value, arr.len) catch @panic("out of memory");
        for (arr, 0..) |item, idx| {
            reversed[arr.len - 1 - idx] = item;
        }
        return .{ .array = reversed };
    }

    fn evalMap(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("map() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("map() requires input", 0);
            return null;
        };
        const arr = switch (inp) {
            .array => |a| a,
            else => {
                // map on single value
                return self.evalWithInput(fc.args[0], inp);
            },
        };

        const results = self.arena.alloc(Value, arr.len) catch @panic("out of memory");
        for (arr, 0..) |item, idx| {
            results[idx] = self.evalWithInput(fc.args[0], item) orelse .null;
        }
        return .{ .array = results };
    }

    fn evalSort(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("sort() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("sort() requires input", 0);
            return null;
        };
        const arr = switch (inp) {
            .array => |a| a,
            else => return inp,
        };

        const sorted = self.arena.alloc(Value, arr.len) catch @panic("out of memory");
        @memcpy(sorted, arr);

        const key_expr = fc.args[0];
        const ctx = SortContext{ .evaluator = self, .key_expr = key_expr };
        std.mem.sort(Value, sorted, ctx, SortContext.lessThan);

        return .{ .array = sorted };
    }

    fn evalGroup(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("group() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("group() requires input", 0);
            return null;
        };
        const arr = switch (inp) {
            .array => |a| a,
            else => return inp,
        };

        const key_expr = fc.args[0];

        // Collect unique group keys and their items
        var group_keys = std.ArrayListUnmanaged(Value).empty;
        var group_items = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)).empty;

        for (arr) |item| {
            const key_val = self.evalWithInput(key_expr, item) orelse .null;

            var found_idx: ?usize = null;
            for (group_keys.items, 0..) |existing, idx| {
                if (key_val.eql(existing)) {
                    found_idx = idx;
                    break;
                }
            }

            if (found_idx) |idx| {
                group_items.items[idx].append(self.arena, item) catch @panic("out of memory");
            } else {
                group_keys.append(self.arena, key_val) catch @panic("out of memory");
                var new_list = std.ArrayListUnmanaged(Value).empty;
                new_list.append(self.arena, item) catch @panic("out of memory");
                group_items.append(self.arena, new_list) catch @panic("out of memory");
            }
        }

        // Build result: record with key → array
        const keys = self.arena.alloc([]const u8, group_keys.items.len) catch @panic("out of memory");
        const vals = self.arena.alloc(Value, group_keys.items.len) catch @panic("out of memory");

        for (group_keys.items, 0..) |key_val, idx| {
            // Convert key to string for record key
            keys[idx] = switch (key_val) {
                .string => |s| s,
                else => blk: {
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    key_val.renderPlain(buf.writer(self.arena)) catch break :blk "";
                    break :blk buf.toOwnedSlice(self.arena) catch "";
                },
            };
            var items_list = group_items.items[idx];
            const slice = items_list.toOwnedSlice(self.arena) catch @panic("out of memory");
            vals[idx] = .{ .array = slice };
        }

        return .{ .record = .{ .keys = keys, .values = vals } };
    }

    fn evalSet(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 2) {
            self.setError("set() requires two arguments: field and value", 0);
            return null;
        }

        // Extract field name from first arg (must be .field)
        const field_name = self.extractFieldName(fc.args[0]) orelse {
            self.setError("set() first argument must be a field access (.field)", 0);
            return null;
        };

        // Evaluate the value expression
        const val = if (input) |inp|
            self.evalWithInput(fc.args[1], inp)
        else
            self.eval(fc.args[1]);
        const set_val = val orelse return null;

        // Render value to string for YAML
        const val_str = valueToYamlScalar(self.arena, set_val) orelse return null;

        // Use piped document string if available, otherwise self.content
        const doc = if (input) |inp| switch (inp) {
            .string => |s| s,
            else => self.content,
        } else self.content;

        // Apply mutation using existing editFields
        const ops = self.arena.alloc(md.frontmatter.FieldOp, 1) catch @panic("out of memory");
        ops[0] = .{ .set = .{ .key = field_name, .value = val_str } };
        const result = md.frontmatter.editFields(self.arena, doc, ops) catch @panic("out of memory");
        return .{ .string = result };
    }

    fn evalDel(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("del() requires exactly one argument: field", 0);
            return null;
        }

        const field_name = self.extractFieldName(fc.args[0]) orelse {
            self.setError("del() argument must be a field access (.field)", 0);
            return null;
        };

        // Use piped document string if available, otherwise self.content
        const doc = if (input) |inp| switch (inp) {
            .string => |s| s,
            else => self.content,
        } else self.content;

        const ops = self.arena.alloc(md.frontmatter.FieldOp, 1) catch @panic("out of memory");
        ops[0] = .{ .delete = field_name };
        const result = md.frontmatter.editFields(self.arena, doc, ops) catch @panic("out of memory");
        return .{ .string = result };
    }

    fn evalSection(self: *Evaluator, fc: Node.FnCall) ?Value {
        if (fc.args.len != 1) {
            self.setError("section() requires exactly one argument", 0);
            return null;
        }

        // Evaluate argument to get heading pattern
        const arg_val = self.eval(fc.args[0]) orelse return null;
        const pattern = switch (arg_val) {
            .string => |s| s,
            else => {
                self.setError("section() argument must be a string", 0);
                return null;
            },
        };

        const parsed_headings = md.headings.parse(self.arena, self.content) catch @panic("out of memory");

        for (parsed_headings, 0..) |h, idx| {
            if (!matchesHeading(h, pattern)) continue;

            var end_pos = self.content.len;
            for (parsed_headings[idx + 1 ..]) |next_h| {
                if (next_h.depth <= h.depth) {
                    end_pos = lineStartPos(self.content, next_h.line);
                    break;
                }
            }

            const start_pos = lineStartPos(self.content, h.line + 1);
            if (start_pos <= end_pos) {
                // Return a section value that carries position info for mutations
                return .{ .string = self.content[start_pos..end_pos] };
            }
            return .{ .string = "" };
        }

        return .null;
    }

    fn evalReplace(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("replace() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("replace() requires input", 0);
            return null;
        };

        const section_text = switch (inp) {
            .string => |s| s,
            else => {
                self.setError("replace() input must be a string (section)", 0);
                return null;
            },
        };

        const replacement_val = self.eval(fc.args[0]) orelse return null;
        const replacement = switch (replacement_val) {
            .string => |s| s,
            else => {
                self.setError("replace() argument must be a string", 0);
                return null;
            },
        };

        // Use pointer arithmetic to find exact position when section_text
        // is a slice of self.content (from section()). Falls back to
        // substring search for other cases.
        const pos = sliceOffset(self.content, section_text) orelse
            std.mem.indexOf(u8, self.content, section_text);

        if (pos) |p| {
            var result = std.ArrayListUnmanaged(u8).empty;
            result.appendSlice(self.arena, self.content[0..p]) catch @panic("out of memory");
            result.appendSlice(self.arena, replacement) catch @panic("out of memory");
            result.appendSlice(self.arena, self.content[p + section_text.len ..]) catch @panic("out of memory");
            return .{ .string = result.toOwnedSlice(self.arena) catch @panic("out of memory") };
        }

        return .{ .string = self.content };
    }

    fn evalAppend(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("append() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("append() requires input", 0);
            return null;
        };

        const section_text = switch (inp) {
            .string => |s| s,
            else => {
                self.setError("append() input must be a string (section)", 0);
                return null;
            },
        };

        const append_val = self.eval(fc.args[0]) orelse return null;
        const append_text = switch (append_val) {
            .string => |s| s,
            else => {
                self.setError("append() argument must be a string", 0);
                return null;
            },
        };

        const pos = sliceOffset(self.content, section_text) orelse
            std.mem.indexOf(u8, self.content, section_text);

        if (pos) |p| {
            const insert_pos = p + section_text.len;
            var result = std.ArrayListUnmanaged(u8).empty;
            result.appendSlice(self.arena, self.content[0..insert_pos]) catch @panic("out of memory");
            result.appendSlice(self.arena, append_text) catch @panic("out of memory");
            result.appendSlice(self.arena, self.content[insert_pos..]) catch @panic("out of memory");
            return .{ .string = result.toOwnedSlice(self.arena) catch @panic("out of memory") };
        }

        return .{ .string = self.content };
    }

    fn evalKeys(self: *Evaluator, input: ?Value) ?Value {
        const inp = input orelse {
            self.setError("keys requires input", 0);
            return null;
        };
        switch (inp) {
            .record => |rec| {
                const items = self.arena.alloc(Value, rec.keys.len) catch @panic("out of memory");
                for (rec.keys, 0..) |key, idx| {
                    items[idx] = .{ .string = key };
                }
                return .{ .array = items };
            },
            else => return .null,
        }
    }

    fn evalHas(self: *Evaluator, fc: Node.FnCall, input: ?Value) ?Value {
        if (fc.args.len != 1) {
            self.setError("has() requires exactly one argument", 0);
            return null;
        }
        const inp = input orelse {
            self.setError("has() requires input", 0);
            return null;
        };

        const arg_val = self.eval(fc.args[0]) orelse return null;
        const field_name = switch (arg_val) {
            .string => |s| s,
            else => {
                self.setError("has() argument must be a string", 0);
                return null;
            },
        };

        switch (inp) {
            .record => |rec| return .{ .bool = rec.get(field_name) != null },
            else => return .{ .bool = false },
        }
    }

    /// Bidirectional YAML conversion:
    /// - record → YAML text
    /// - string → record (parse YAML)
    fn evalYaml(self: *Evaluator, input: Value) ?Value {
        switch (input) {
            .record => |rec| {
                var buf = std.ArrayListUnmanaged(u8).empty;
                renderRecordAsYaml(self.arena, &buf, rec, 0) catch @panic("out of memory");
                return .{ .string = buf.toOwnedSlice(self.arena) catch @panic("out of memory") };
            },
            .string => |s| {
                return parseFrontmatterToValue(self.arena, s);
            },
            else => {
                self.setError("yaml requires a record or string as input", 0);
                return null;
            },
        }
    }

    /// Bidirectional TOML conversion:
    /// - record → TOML text
    /// - string → record (parse TOML)
    fn evalToml(self: *Evaluator, input: Value) ?Value {
        switch (input) {
            .record => |rec| {
                var buf = std.ArrayListUnmanaged(u8).empty;
                renderRecordAsToml(self.arena, &buf, rec) catch @panic("out of memory");
                return .{ .string = buf.toOwnedSlice(self.arena) catch @panic("out of memory") };
            },
            .string => |s| {
                return parseTomlToValue(self.arena, s);
            },
            else => {
                self.setError("toml requires a record or string as input", 0);
                return null;
            },
        }
    }

    fn extractFieldName(self: *Evaluator, node: *const Node) ?[]const u8 {
        _ = self;
        switch (node.*) {
            .field_access => |fa| {
                if (fa.parts.len == 1) return fa.parts[0];
                return null;
            },
            else => return null,
        }
    }

    fn extractFrontmatterFrom(self: *Evaluator, content: []const u8) ?Value {
        const fm = md.frontmatter.extract(content) orelse return .null;
        return switch (fm.format) {
            .yaml => parseFrontmatterToValue(self.arena, fm.raw),
            .toml => parseTomlToValue(self.arena, fm.raw),
        };
    }

    fn extractBodyFrom(_: *Evaluator, content: []const u8) Value {
        if (md.frontmatter.extract(content)) |fm| {
            return .{ .string = fm.body };
        }
        return .{ .string = content };
    }

    fn extractHeadingsFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.headings.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |h, idx| {
            items[idx] = headingToValue(self.arena, h);
        }
        return .{ .array = items };
    }

    fn extractLinksFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.links.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |l, idx| {
            items[idx] = linkToValue(self.arena, l);
        }
        return .{ .array = items };
    }

    fn extractTagsFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.tags.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |t, idx| {
            items[idx] = tagToValue(self.arena, t);
        }
        return .{ .array = items };
    }

    fn extractCodeblocksFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.codeblocks.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |b, idx| {
            items[idx] = codeblockToValue(self.arena, b);
        }
        return .{ .array = items };
    }

    fn extractStatsFrom(self: *Evaluator, content: []const u8) ?Value {
        const body = if (md.frontmatter.extract(content)) |fm| fm.body else content;

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

    fn extractCommentsFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.comments.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |c, idx| {
            items[idx] = commentToValue(self.arena, c);
        }
        return .{ .array = items };
    }

    fn extractFootnotesFrom(self: *Evaluator, content: []const u8) ?Value {
        const parsed = md.footnotes.parse(self.arena, content) catch @panic("out of memory");
        const items = self.arena.alloc(Value, parsed.len) catch @panic("out of memory");
        for (parsed, 0..) |f, idx| {
            items[idx] = footnoteToValue(self.arena, f);
        }
        return .{ .array = items };
    }

    fn extractIncoming(self: *Evaluator) ?Value {
        const file_path = self.file_path orelse {
            self.setError("incoming requires a file path", 0);
            return null;
        };

        const target_basename = std.fs.path.stem(file_path);
        const target_dir = std.fs.path.dirname(file_path);
        const scan_dir_path = self.dir_path orelse target_dir orelse ".";

        var dir = std.fs.cwd().openDir(scan_dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                self.setError("incoming: directory not found", 0);
            }
            return null;
        };
        defer dir.close();

        var results = std.ArrayListUnmanaged(Value).empty;
        scanIncoming(self.arena, dir, scan_dir_path, file_path, target_basename, &results) catch @panic("out of memory");
        return .{ .array = results.toOwnedSlice(self.arena) catch @panic("out of memory") };
    }

    fn evalExists(self: *Evaluator, input: Value) ?Value {
        switch (input) {
            .array => |arr| {
                const items = self.arena.alloc(Value, arr.len) catch @panic("out of memory");
                for (arr, 0..) |item, idx| {
                    items[idx] = self.addExistsField(item) orelse return null;
                }
                return .{ .array = items };
            },
            .record => return self.addExistsField(input),
            else => {
                self.setError("exists requires link records as input", 0);
                return null;
            },
        }
    }

    fn addExistsField(self: *Evaluator, val: Value) ?Value {
        const rec = switch (val) {
            .record => |r| r,
            else => {
                self.setError("exists requires link records as input", 0);
                return null;
            },
        };

        const target = rec.get("target") orelse {
            self.setError("exists: record has no target field", 0);
            return null;
        };
        const target_str = switch (target) {
            .string => |s| s,
            else => {
                self.setError("exists: target must be a string", 0);
                return null;
            },
        };

        const kind = rec.get("kind");
        const kind_str = if (kind) |k| switch (k) {
            .string => |s| s,
            else => null,
        } else null;

        const file_exists = self.checkLinkExists(target_str, kind_str);

        return self.recordSetField(rec, "exists", .{ .bool = file_exists });
    }

    fn checkLinkExists(self: *Evaluator, target: []const u8, kind: ?[]const u8) bool {
        // Strip fragment
        const path = if (std.mem.indexOfScalar(u8, target, '#')) |hash|
            target[0..hash]
        else
            target;

        if (path.len == 0) return true; // anchor-only link
        if (std.mem.indexOf(u8, path, "://") != null) return true; // URL

        const is_wiki = if (kind) |k|
            std.mem.eql(u8, k, "wikilink") or std.mem.eql(u8, k, "embed")
        else
            false;

        const base_dir = if (is_wiki)
            self.dir_path orelse self.fileDir()
        else
            self.fileDir();

        const dir_path = base_dir orelse return false;
        var dir = std.fs.cwd().openDir(dir_path, .{}) catch return false;
        defer dir.close();

        if (dir.statFile(path)) |_| return true else |_| {}

        const with_md = std.fmt.allocPrint(self.arena, "{s}.md", .{path}) catch return false;
        if (dir.statFile(with_md)) |_| return true else |_| {}

        return false;
    }

    fn fileDir(self: *Evaluator) ?[]const u8 {
        return if (self.file_path) |fp| std.fs.path.dirname(fp) orelse "." else null;
    }

    fn evalResolve(self: *Evaluator, input: Value) ?Value {
        switch (input) {
            .array => |arr| {
                const items = self.arena.alloc(Value, arr.len) catch @panic("out of memory");
                for (arr, 0..) |item, idx| {
                    items[idx] = self.addResolvedField(item) orelse return null;
                }
                return .{ .array = items };
            },
            .record => return self.addResolvedField(input),
            else => {
                self.setError("resolve requires link records as input", 0);
                return null;
            },
        }
    }

    fn addResolvedField(self: *Evaluator, val: Value) ?Value {
        const rec = switch (val) {
            .record => |r| r,
            else => {
                self.setError("resolve requires link records as input", 0);
                return null;
            },
        };

        const target = rec.get("target") orelse {
            self.setError("resolve: record has no target field", 0);
            return null;
        };
        const target_str = switch (target) {
            .string => |s| s,
            else => {
                self.setError("resolve: target must be a string", 0);
                return null;
            },
        };

        const kind = rec.get("kind");
        const kind_str = if (kind) |k| switch (k) {
            .string => |s| s,
            else => null,
        } else null;

        const resolved = self.resolveLinkPath(target_str, kind_str);

        return self.recordSetField(rec, "path", .{ .string = resolved });
    }

    /// Set or replace a field on a record. If the key already exists, its
    /// value is updated in place. Otherwise a new key-value pair is appended.
    fn recordSetField(self: *Evaluator, rec: Value.Record, key: []const u8, val: Value) ?Value {
        // Check for existing key
        for (rec.keys, 0..) |k, idx| {
            if (std.mem.eql(u8, k, key)) {
                const new_vals = self.arena.alloc(Value, rec.values.len) catch @panic("out of memory");
                @memcpy(new_vals, rec.values);
                new_vals[idx] = val;
                return .{ .record = .{ .keys = rec.keys, .values = new_vals } };
            }
        }

        // Append new field
        const new_keys = self.arena.alloc([]const u8, rec.keys.len + 1) catch @panic("out of memory");
        const new_vals = self.arena.alloc(Value, rec.values.len + 1) catch @panic("out of memory");
        @memcpy(new_keys[0..rec.keys.len], rec.keys);
        @memcpy(new_vals[0..rec.values.len], rec.values);
        new_keys[rec.keys.len] = key;
        new_vals[rec.values.len] = val;
        return .{ .record = .{ .keys = new_keys, .values = new_vals } };
    }

    fn resolveLinkPath(self: *Evaluator, target: []const u8, kind: ?[]const u8) []const u8 {
        const path = if (std.mem.indexOfScalar(u8, target, '#')) |hash|
            target[0..hash]
        else
            target;

        if (path.len == 0) return target; // anchor-only
        if (std.mem.indexOf(u8, path, "://") != null) return target; // URL

        const is_wiki = if (kind) |k|
            std.mem.eql(u8, k, "wikilink") or std.mem.eql(u8, k, "embed")
        else
            false;

        const base_dir = if (is_wiki)
            self.dir_path orelse self.fileDir()
        else
            self.fileDir();

        const dir_str = base_dir orelse return target;
        var dir = std.fs.cwd().openDir(dir_str, .{}) catch return target;
        defer dir.close();
        if (dir.statFile(path)) |_| {
            return std.fs.path.join(self.arena, &.{ dir_str, path }) catch return target;
        } else |_| {}

        const with_md = std.fmt.allocPrint(self.arena, "{s}.md", .{path}) catch return target;
        if (dir.statFile(with_md)) |_| {
            return std.fs.path.join(self.arena, &.{ dir_str, with_md }) catch return target;
        } else |_| {}

        return target;
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
        const items = self.arena.alloc(Value, c.exprs.len) catch @panic("out of memory");
        for (c.exprs, 0..) |expr, idx| {
            items[idx] = self.eval(expr) orelse return null;
        }
        return .{ .array = items };
    }

    fn evalCommaWithInput(self: *Evaluator, c: Node.Comma, input: Value) ?Value {
        const items = self.arena.alloc(Value, c.exprs.len) catch @panic("out of memory");
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

    fn setErrorFmt(self: *Evaluator, comptime fmt: []const u8, args: anytype) void {
        if (self.err == null) {
            const message = std.fmt.allocPrint(self.arena, fmt, args) catch @panic("out of memory");
            self.err = .{ .message = message, .pos = 0 };
        }
    }
};

fn matchesHeading(h: md.headings.Heading, pattern: []const u8) bool {
    var p = pattern;

    var expected_depth: ?u3 = null;
    if (p.len > 0 and p[0] == '#') {
        var depth: u3 = 0;
        var i: usize = 0;
        while (i < p.len and p[i] == '#') : (i += 1) {
            if (depth < 6) depth += 1;
        }
        expected_depth = depth;
        while (i < p.len and (p[i] == ' ' or p[i] == '\t')) : (i += 1) {}
        p = p[i..];
    }

    if (expected_depth) |d| {
        if (h.depth != d) return false;
    }

    return std.mem.eql(u8, h.text, p);
}

fn lineStartPos(content: []const u8, target_line: usize) usize {
    var line: usize = 1;
    var pos: usize = 0;
    while (pos < content.len and line < target_line) {
        if (content[pos] == '\n') line += 1;
        pos += 1;
    }
    return pos;
}

/// If `sub` is a slice of `container`, return its byte offset.
/// Returns null if `sub` points outside `container`.
const max_file_size = 10 * 1024 * 1024; // 10 MB

fn scanIncoming(
    arena: std.mem.Allocator,
    dir: std.fs.Dir,
    dir_path: []const u8,
    target_path: []const u8,
    target_basename: []const u8,
    results: *std.ArrayListUnmanaged(Value),
) std.mem.Allocator.Error!void {
    var walker = dir.walk(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer walker.deinit();

    // Per-file allocator that resets after each file to avoid accumulating
    // all file contents in the main arena.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    while (true) {
        const entry = walker.next() catch continue orelse break;
        if (entry.kind != .file) continue;
        if (!isMarkdownFile(entry.basename)) continue;

        defer _ = scratch.reset(.retain_capacity);
        const scratch_alloc = scratch.allocator();

        const source_path = std.fs.path.join(scratch_alloc, &.{ dir_path, entry.path }) catch continue;
        if (std.mem.eql(u8, source_path, target_path)) continue;

        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(scratch_alloc, max_file_size) catch continue;

        const links = md.links.parse(scratch_alloc, content) catch continue;
        for (links) |link| {
            if (linkMatchesTarget(scratch_alloc, link, target_path, target_basename, source_path)) {
                const source = try arena.dupe(u8, source_path);
                const val = recordFromPairs(arena, &.{
                    .{ "source", .{ .string = source } },
                    .{ "kind", .{ .string = @tagName(link.kind) } },
                    .{ "line", .{ .int = @intCast(link.line) } },
                });
                try results.append(arena, val);
            }
        }
    }
}

fn linkMatchesTarget(
    arena: std.mem.Allocator,
    link: md.links.Link,
    target_path: []const u8,
    target_basename: []const u8,
    source_path: []const u8,
) bool {
    const link_target = link.target;

    if (link.kind == .wikilink or link.kind == .embed) {
        const name = if (std.mem.indexOfScalar(u8, link_target, '#')) |hash_pos|
            link_target[0..hash_pos]
        else
            link_target;
        return std.mem.eql(u8, name, target_basename);
    }

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const resolved = std.fs.path.resolve(
        arena,
        &.{ source_dir, link_target },
    ) catch @panic("out of memory");

    const target_resolved = std.fs.path.resolve(
        arena,
        &.{target_path},
    ) catch @panic("out of memory");

    return std.mem.eql(u8, resolved, target_resolved);
}

fn isMarkdownFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or
        std.mem.endsWith(u8, name, ".MD") or
        std.mem.endsWith(u8, name, ".markdown") or
        std.mem.endsWith(u8, name, ".Markdown") or
        std.mem.endsWith(u8, name, ".MARKDOWN");
}

fn sliceOffset(container: []const u8, sub: []const u8) ?usize {
    const container_start = @intFromPtr(container.ptr);
    const container_end = container_start + container.len;
    const sub_start = @intFromPtr(sub.ptr);
    const sub_end = sub_start + sub.len;
    if (sub_start >= container_start and sub_end <= container_end) {
        return sub_start - container_start;
    }
    return null;
}

fn renderRecordAsYaml(
    arena: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    rec: Value.Record,
    indent: usize,
) std.mem.Allocator.Error!void {
    const w = buf.writer(arena);
    for (rec.keys, rec.values) |key, val| {
        try writeIndent(w, indent);
        try w.writeAll(key);
        try w.writeAll(":");
        switch (val) {
            .record => |nested| {
                try w.writeByte('\n');
                try renderRecordAsYaml(arena, buf, nested, indent + 2);
            },
            .array => |arr| {
                try w.writeByte('\n');
                for (arr) |item| {
                    try writeIndent(w, indent + 2);
                    try w.writeAll("- ");
                    try renderValueAsYamlInline(w, item);
                    try w.writeByte('\n');
                }
            },
            else => {
                try w.writeByte(' ');
                try renderValueAsYamlInline(w, val);
                try w.writeByte('\n');
            },
        }
    }
}

fn renderValueAsYamlInline(writer: anytype, val: Value) !void {
    switch (val) {
        .string => |s| try writer.writeAll(s),
        .int => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try renderValueAsYamlInline(writer, item);
            }
            try writer.writeByte(']');
        },
        .record => try writer.writeAll("{}"),
    }
}

fn writeIndent(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.writeByte(' ');
}

// TOML rendering (record → TOML text)

fn renderRecordAsToml(
    arena: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    rec: Value.Record,
) std.mem.Allocator.Error!void {
    const w = buf.writer(arena);

    // Render simple key-value pairs first, then tables
    for (rec.keys, rec.values) |key, val| {
        switch (val) {
            .record => continue,
            else => {
                try w.writeAll(key);
                try w.writeAll(" = ");
                try renderValueAsTomlInline(w, val);
                try w.writeByte('\n');
            },
        }
    }

    // Render nested records as [table] sections
    for (rec.keys, rec.values) |key, val| {
        switch (val) {
            .record => |nested| {
                try w.writeByte('\n');
                try w.writeByte('[');
                try w.writeAll(key);
                try w.writeAll("]\n");
                for (nested.keys, nested.values) |nk, nv| {
                    try w.writeAll(nk);
                    try w.writeAll(" = ");
                    try renderValueAsTomlInline(w, nv);
                    try w.writeByte('\n');
                }
            },
            else => continue,
        }
    }
}

fn renderValueAsTomlInline(writer: anytype, val: Value) !void {
    switch (val) {
        .string => |s| {
            try writer.writeByte('"');
            try writeTomlEscaped(writer, s);
            try writer.writeByte('"');
        },
        .int => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("\"\""),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try renderValueAsTomlInline(writer, item);
            }
            try writer.writeByte(']');
        },
        .record => try writer.writeAll("{}"),
    }
}

fn writeTomlEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

// TOML parsing (string → record)

pub fn parseTomlToValue(arena: std.mem.Allocator, raw: []const u8) ?Value {
    var keys = std.ArrayListUnmanaged([]const u8).empty;
    var vals = std.ArrayListUnmanaged(Value).empty;

    // Track current table for [section] headers
    var current_keys: *std.ArrayListUnmanaged([]const u8) = &keys;
    var current_vals: *std.ArrayListUnmanaged(Value) = &vals;

    // Storage for nested table sections
    var table_keys_storage = std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
    var table_vals_storage = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)).empty;
    var table_names = std.ArrayListUnmanaged([]const u8).empty;

    var pos: usize = 0;
    while (pos < raw.len) {
        const line_start = pos;
        pos = nextLine(raw, pos);
        const line = stripLineEnding(raw[line_start..pos]);

        // Skip empty lines and comments
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // [table] header
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const table_name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");

            const tk = std.ArrayListUnmanaged([]const u8).empty;
            const tv = std.ArrayListUnmanaged(Value).empty;
            table_keys_storage.append(arena, tk) catch @panic("out of memory");
            table_vals_storage.append(arena, tv) catch @panic("out of memory");
            table_names.append(arena, table_name) catch @panic("out of memory");

            const last_idx = table_keys_storage.items.len - 1;
            current_keys = &table_keys_storage.items[last_idx];
            current_vals = &table_vals_storage.items[last_idx];
            continue;
        }

        // key = value
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trimRight(u8, trimmed[0..eq_pos], " \t");
        if (key.len == 0) continue;
        var val_text = std.mem.trimLeft(u8, trimmed[eq_pos + 1 ..], " \t");
        _ = &val_text;

        current_keys.append(arena, key) catch @panic("out of memory");
        current_vals.append(arena, parseTomlValue(arena, val_text)) catch @panic("out of memory");
    }

    // Merge table sections into top-level record
    for (table_names.items, 0..) |name, idx| {
        const tk = table_keys_storage.items[idx].toOwnedSlice(arena) catch @panic("out of memory");
        const tv = table_vals_storage.items[idx].toOwnedSlice(arena) catch @panic("out of memory");
        keys.append(arena, name) catch @panic("out of memory");
        vals.append(arena, .{ .record = .{ .keys = tk, .values = tv } }) catch @panic("out of memory");
    }

    const k = keys.toOwnedSlice(arena) catch @panic("out of memory");
    const v = vals.toOwnedSlice(arena) catch @panic("out of memory");
    return .{ .record = .{ .keys = k, .values = v } };
}

fn parseTomlValue(arena: std.mem.Allocator, text: []const u8) Value {
    if (text.len == 0) return .null;

    // Boolean
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };

    // Quoted string
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return .{ .string = text[1 .. text.len - 1] };
    }
    if (text.len >= 2 and text[0] == '\'' and text[text.len - 1] == '\'') {
        return .{ .string = text[1 .. text.len - 1] };
    }

    // Array: [a, b, c]
    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
        return parseTomlArray(arena, text[1 .. text.len - 1]);
    }

    // Integer
    if (std.fmt.parseInt(i64, text, 10)) |n| {
        return .{ .int = n };
    } else |_| {}

    // Float
    if (std.fmt.parseFloat(f64, text)) |f| {
        if (std.mem.indexOfScalar(u8, text, '.') != null) {
            return .{ .float = f };
        }
    } else |_| {}

    // Bare string (unusual in TOML but handle leniently)
    return .{ .string = text };
}

fn parseTomlArray(arena: std.mem.Allocator, inner: []const u8) Value {
    var items = std.ArrayListUnmanaged(Value).empty;
    var pos: usize = 0;

    while (pos < inner.len) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) : (pos += 1) {}
        if (pos >= inner.len) break;

        // Handle quoted strings (don't split on commas inside quotes)
        if (inner[pos] == '"' or inner[pos] == '\'') {
            const quote = inner[pos];
            const start = pos;
            pos += 1;
            while (pos < inner.len and inner[pos] != quote) : (pos += 1) {}
            if (pos < inner.len) pos += 1; // skip closing quote
            items.append(arena, parseTomlValue(arena, inner[start..pos])) catch
                return .{ .array = &.{} };
            // Skip comma
            while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t' or inner[pos] == ',')) : (pos += 1) {}
        } else {
            const start = pos;
            while (pos < inner.len and inner[pos] != ',') : (pos += 1) {}
            var end = pos;
            while (end > start and (inner[end - 1] == ' ' or inner[end - 1] == '\t')) : (end -= 1) {}
            if (end > start) {
                items.append(arena, parseTomlValue(arena, inner[start..end])) catch
                    return .{ .array = &.{} };
            }
            if (pos < inner.len) pos += 1; // skip comma
        }
    }

    const slice = items.toOwnedSlice(arena) catch return .{ .array = &.{} };
    return .{ .array = slice };
}

fn valueToYamlScalar(arena: std.mem.Allocator, val: Value) ?[]const u8 {
    return switch (val) {
        .string => |s| s,
        .int => |n| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.writer(arena).print("{d}", .{n}) catch @panic("out of memory");
            break :blk buf.toOwnedSlice(arena) catch null;
        },
        .float => |f| blk: {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            buf.writer(arena).print("{d}", .{f}) catch @panic("out of memory");
            break :blk buf.toOwnedSlice(arena) catch null;
        },
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => null,
    };
}

const SortContext = struct {
    evaluator: *Evaluator,
    key_expr: *const Node,

    fn lessThan(ctx: SortContext, a: Value, b: Value) bool {
        const a_key = ctx.evaluator.evalWithInput(ctx.key_expr, a) orelse .null;
        const b_key = ctx.evaluator.evalWithInput(ctx.key_expr, b) orelse .null;
        return compareValues(a_key, b_key) == .lt;
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

fn headingToValue(arena: std.mem.Allocator, h: md.headings.Heading) Value {
    return recordFromPairs(arena, &.{
        .{ "depth", .{ .int = @intCast(h.depth) } },
        .{ "text", .{ .string = h.text } },
        .{ "line", .{ .int = @intCast(h.line) } },
    });
}

fn linkToValue(arena: std.mem.Allocator, l: md.links.Link) Value {
    return recordFromPairs(arena, &.{
        .{ "kind", .{ .string = @tagName(l.kind) } },
        .{ "target", .{ .string = l.target } },
        .{ "text", .{ .string = l.text } },
        .{ "line", .{ .int = @intCast(l.line) } },
    });
}

fn tagToValue(arena: std.mem.Allocator, t: md.tags.Tag) Value {
    return recordFromPairs(arena, &.{
        .{ "name", .{ .string = t.name } },
        .{ "line", .{ .int = @intCast(t.line) } },
    });
}

fn codeblockToValue(arena: std.mem.Allocator, b: md.codeblocks.CodeBlock) Value {
    return recordFromPairs(arena, &.{
        .{ "language", .{ .string = b.language } },
        .{ "content", .{ .string = b.content } },
        .{ "start_line", .{ .int = @intCast(b.start_line) } },
        .{ "end_line", .{ .int = @intCast(b.end_line) } },
    });
}

fn commentToValue(arena: std.mem.Allocator, c: md.comments.Comment) Value {
    return recordFromPairs(arena, &.{
        .{ "kind", .{ .string = @tagName(c.kind) } },
        .{ "text", .{ .string = c.text } },
        .{ "line", .{ .int = @intCast(c.line) } },
    });
}

fn footnoteToValue(arena: std.mem.Allocator, f: md.footnotes.Footnote) Value {
    return recordFromPairs(arena, &.{
        .{ "label", .{ .string = f.label } },
        .{ "text", .{ .string = f.text } },
        .{ "line", .{ .int = @intCast(f.line) } },
    });
}

const KV = struct { []const u8, Value };

fn recordFromPairs(arena: std.mem.Allocator, pairs: []const KV) Value {
    const keys = arena.alloc([]const u8, pairs.len) catch @panic("out of memory");
    const vals = arena.alloc(Value, pairs.len) catch @panic("out of memory");
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

        keys.append(arena, key) catch @panic("out of memory");

        if (val_text.len == 0) {
            // Block value: sequence or nested mapping
            const block_result = parseBlockValue(arena, raw, pos) orelse return null;
            vals.append(arena, block_result.value) catch @panic("out of memory");
            pos = block_result.pos;
        } else {
            vals.append(arena, parseScalarValue(arena, val_text)) catch @panic("out of memory");
        }
    }

    const k = keys.toOwnedSlice(arena) catch @panic("out of memory");
    const v = vals.toOwnedSlice(arena) catch @panic("out of memory");
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

        items.append(arena, parseScalarValue(arena, item_text)) catch @panic("out of memory");
        pos = next_pos;
    }

    const slice = items.toOwnedSlice(arena) catch @panic("out of memory");
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

        keys.append(arena, key) catch @panic("out of memory");
        vals.append(arena, parseScalarValue(arena, val_text)) catch @panic("out of memory");
        pos = next_pos;
    }

    const k = keys.toOwnedSlice(arena) catch @panic("out of memory");
    const v = vals.toOwnedSlice(arena) catch @panic("out of memory");
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

test "comments extracts array" {
    const doc = "text\n<!-- html comment -->\nmore\n%% obsidian comment %%\n";
    const val = testEval("comments", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("html", val.array[0].record.get("kind").?.string);
    try testing.expectEqualStrings("html comment", val.array[0].record.get("text").?.string);
    try testing.expectEqualStrings("obsidian", val.array[1].record.get("kind").?.string);
    try testing.expectEqualStrings("obsidian comment", val.array[1].record.get("text").?.string);
}

test "comments select by kind" {
    const doc = "<!-- a -->\n%% b %%\n<!-- c -->\n";
    const val = testEval("comments | select(.kind == \"obsidian\")", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("b", val.array[0].record.get("text").?.string);
}

test "comments empty document" {
    const val = testEval("comments", "no comments here\n").?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "footnotes extracts array" {
    const doc = "Some text.\n\n[^1]: First note\n[^ref]: Second note\n";
    const val = testEval("footnotes", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("1", val.array[0].record.get("label").?.string);
    try testing.expectEqualStrings("First note", val.array[0].record.get("text").?.string);
    try testing.expectEqualStrings("ref", val.array[1].record.get("label").?.string);
}

test "footnotes field access" {
    const doc = "[^abc]: Some footnote text\n";
    const val = testEval("footnotes | first | .text", doc).?;
    try testing.expect(val == .string);
    try testing.expectEqualStrings("Some footnote text", val.string);
}

test "footnotes count" {
    const doc = "[^a]: One\n[^b]: Two\n[^c]: Three\n";
    const val = testEval("footnotes | count", doc).?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 3), val.int);
}

test "footnotes empty document" {
    const val = testEval("footnotes", "no footnotes\n").?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
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

// select() tests

test "select filters array by field equality" {
    const val = testEval(
        "headings | select(.depth == 2)",
        "# H1\n## H2a\n### H3\n## H2b\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("H2a", val.array[0].record.get("text").?.string);
    try testing.expectEqualStrings("H2b", val.array[1].record.get("text").?.string);
}

test "select with not equal" {
    const val = testEval(
        "headings | select(.depth != 1)",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

test "select with greater than" {
    const val = testEval(
        "headings | select(.depth > 1)",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

test "select with less than or equal" {
    const val = testEval(
        "headings | select(.depth <= 2)",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

test "select with and" {
    const val = testEval(
        "headings | select(.depth >= 2 and .depth <= 2)",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("H2", val.array[0].record.get("text").?.string);
}

test "select with or" {
    const val = testEval(
        "headings | select(.depth == 1 or .depth == 3)",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

test "select with not" {
    const val = testEval(
        "headings | select(not (.depth == 1))",
        "# H1\n## H2\n### H3\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

test "select returns empty array when nothing matches" {
    const val = testEval(
        "headings | select(.depth == 5)",
        "# H1\n## H2\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "select on links by kind" {
    const doc = "Check [link](https://example.com) and [[wikilink]].\n";
    const val = testEval("links | select(.kind == \"wikilink\")", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("wikilink", val.array[0].record.get("target").?.string);
}

test "select on codeblocks by language" {
    const doc = "```go\nfunc main() {}\n```\n```zig\nconst x = 1;\n```\n";
    const val = testEval("codeblocks | select(.language == \"go\")", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
}

// contains() tests

test "contains on field" {
    const doc = "Visit [GitHub](https://github.com/foo) today.\n";
    const val = testEval(
        "links | select(contains(.target, \"github\"))",
        doc,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
}

test "contains no match" {
    const doc = "Visit [Example](https://example.com) today.\n";
    const val = testEval(
        "links | select(contains(.target, \"github\"))",
        doc,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "contains on heading text" {
    const val = testEval(
        "headings | select(contains(.text, \"API\"))",
        "# Intro\n## API Reference\n## Other\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("API Reference", val.array[0].record.get("text").?.string);
}

// startswith() tests

test "startswith on field" {
    const doc = "Visit [a](https://example.com) and [b](ftp://files.com).\n";
    const val = testEval(
        "links | select(startswith(.target, \"https\"))",
        doc,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
}

test "startswith no match" {
    const doc = "Visit [a](ftp://files.com).\n";
    const val = testEval(
        "links | select(startswith(.target, \"https\"))",
        doc,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "select string equality on tags" {
    const doc = "Some #draft and #review text.\n";
    const val = testEval("tags | select(.name == \"draft\")", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("draft", val.array[0].record.get("name").?.string);
}

// first, last, count tests

test "first on array" {
    const val = testEval("headings | first", "# A\n## B\n### C\n").?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("A", val.record.get("text").?.string);
}

test "first on empty array" {
    const val = testEval("headings | first", "no headings\n").?;
    try testing.expect(val == .null);
}

test "last on array" {
    const val = testEval("headings | last", "# A\n## B\n### C\n").?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("C", val.record.get("text").?.string);
}

test "count on array" {
    const val = testEval("headings | count", "# A\n## B\n### C\n").?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 3), val.int);
}

test "count on empty array" {
    const val = testEval("headings | count", "no headings\n").?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 0), val.int);
}

test "count after select" {
    const val = testEval(
        "headings | select(.depth == 2) | count",
        "# A\n## B\n## C\n### D\n",
    ).?;
    try testing.expect(val == .int);
    try testing.expectEqual(@as(i64, 2), val.int);
}

// map tests

test "map extracts field" {
    const val = testEval(
        "headings | map(.text)",
        "# A\n## B\n### C\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqualStrings("A", val.array[0].string);
    try testing.expectEqualStrings("B", val.array[1].string);
    try testing.expectEqualStrings("C", val.array[2].string);
}

test "map on links targets" {
    const doc = "Visit [a](https://a.com) and [b](https://b.com).\n";
    const val = testEval("links | map(.target)", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("https://a.com", val.array[0].string);
    try testing.expectEqualStrings("https://b.com", val.array[1].string);
}

// unique tests

test "unique deduplicates strings" {
    const val = testEval(
        "links | map(.target) | unique",
        "[a](https://x.com) and [b](https://x.com) and [c](https://y.com).\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
}

// reverse tests

test "reverse array" {
    const val = testEval(
        "headings | map(.text) | reverse",
        "# A\n## B\n### C\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqualStrings("C", val.array[0].string);
    try testing.expectEqualStrings("B", val.array[1].string);
    try testing.expectEqualStrings("A", val.array[2].string);
}

// sort tests

test "sort by field" {
    const val = testEval(
        "headings | sort(.depth) | map(.text)",
        "### C\n# A\n## B\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqualStrings("A", val.array[0].string);
    try testing.expectEqualStrings("B", val.array[1].string);
    try testing.expectEqualStrings("C", val.array[2].string);
}

test "sort reverse" {
    const val = testEval(
        "headings | sort(.depth) | reverse | map(.text)",
        "### C\n# A\n## B\n",
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqualStrings("C", val.array[0].string);
}

// group tests

test "group by field" {
    const val = testEval(
        "links | group(.kind)",
        "[a](https://a.com) and [[b]] and [c](https://c.com).\n",
    ).?;
    try testing.expect(val == .record);
    const standard = val.record.get("standard");
    try testing.expect(standard != null);
    try testing.expect(standard.? == .array);
    try testing.expectEqual(@as(usize, 2), standard.?.array.len);
    const wikilink = val.record.get("wikilink");
    try testing.expect(wikilink != null);
    try testing.expectEqual(@as(usize, 1), wikilink.?.array.len);
}

// Chained operations

test "select then first then field access" {
    const val = testEval(
        "codeblocks | select(.language == \"go\") | first | .content",
        "```go\nfunc main() {}\n```\n```zig\nconst x = 1;\n```\n",
    ).?;
    try testing.expect(val == .string);
    try testing.expectEqualStrings("func main() {}\n", val.string);
}

// Frontmatter mutation tests

test "set modifies frontmatter field" {
    const doc =
        \\---
        \\title: Old
        \\draft: true
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.title, \"New\")", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "title: New") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "body") != null);
}

test "set adds new field" {
    const doc =
        \\---
        \\title: Hello
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.tags, \"review\")", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "tags: review") != null);
}

test "set with bool value" {
    const doc =
        \\---
        \\title: Hello
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.draft, false)", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "draft: false") != null);
}

test "set with int value" {
    const doc =
        \\---
        \\title: Hello
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.count, 42)", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "count: 42") != null);
}

test "del removes field" {
    const doc =
        \\---
        \\title: Hello
        \\draft: true
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | del(.draft)", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "draft") == null);
    try testing.expect(std.mem.indexOf(u8, val.string, "title: Hello") != null);
}

test "chained set applies both mutations" {
    const doc =
        \\---
        \\title: Old
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.title, \"New\") | set(.draft, false)", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "title: New") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "draft: false") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "body") != null);
}

test "chained set and del" {
    const doc =
        \\---
        \\title: Hello
        \\draft: true
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | set(.title, \"Updated\") | del(.draft)", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "title: Updated") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "draft") == null);
}

// Section tests

test "section extracts content" {
    const doc =
        \\# Intro
        \\intro text
        \\## Methods
        \\methods text
        \\## Results
        \\results text
        \\
    ;
    const val = testEval("section(\"## Methods\")", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "methods text") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "results text") == null);
}

test "section with depth-agnostic match" {
    const doc =
        \\# Intro
        \\intro text
        \\## Methods
        \\methods text
        \\## Results
        \\results text
        \\
    ;
    const val = testEval("section(\"Methods\")", doc).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "methods text") != null);
}

test "section not found returns null" {
    const val = testEval("section(\"## Missing\")", "# Intro\ntext\n").?;
    try testing.expect(val == .null);
}

test "section replace" {
    const doc =
        \\# Intro
        \\intro text
        \\## Methods
        \\old methods
        \\## Results
        \\results text
        \\
    ;
    const val = testEval(
        "section(\"## Methods\") | replace(\"new methods\\n\")",
        doc,
    ).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "new methods") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "old methods") == null);
    try testing.expect(std.mem.indexOf(u8, val.string, "results text") != null);
}

test "section append" {
    const doc =
        \\# Intro
        \\intro text
        \\## Methods
        \\existing methods
        \\## Results
        \\results text
        \\
    ;
    const val = testEval(
        "section(\"## Methods\") | append(\"added text\\n\")",
        doc,
    ).?;
    try testing.expect(val == .string);
    try testing.expect(std.mem.indexOf(u8, val.string, "existing methods") != null);
    try testing.expect(std.mem.indexOf(u8, val.string, "added text") != null);
}

// keys and has tests

test "section piped to headings extracts only section headings" {
    const doc =
        \\# Intro
        \\intro text
        \\## Methods
        \\### Sub Method
        \\method details
        \\## Results
        \\### Sub Result
        \\results text
        \\
    ;
    const val = testEval("section(\"## Methods\") | headings", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("Sub Method", val.array[0].record.get("text").?.string);
}

test "section piped to links extracts only section links" {
    const doc =
        \\# Intro
        \\See [intro](https://intro.com).
        \\## Methods
        \\See [method](https://method.com) and [[wiki]].
        \\## Results
        \\See [result](https://result.com).
        \\
    ;
    const val = testEval("section(\"## Methods\") | links", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);
    try testing.expectEqualStrings("https://method.com", val.array[0].record.get("target").?.string);
    try testing.expectEqualStrings("wiki", val.array[1].record.get("target").?.string);
}

test "section piped to tags extracts only section tags" {
    const doc =
        \\# Intro
        \\#intro-tag
        \\## Methods
        \\#method-tag content
        \\## Results
        \\#result-tag
        \\
    ;
    const val = testEval("section(\"## Methods\") | tags", doc).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("method-tag", val.array[0].record.get("name").?.string);
}

test "keys on frontmatter" {
    const val = testEval("frontmatter | keys", test_doc).?;
    try testing.expect(val == .array);
    var found_title = false;
    var found_draft = false;
    for (val.array) |item| {
        if (std.mem.eql(u8, item.string, "title")) found_title = true;
        if (std.mem.eql(u8, item.string, "draft")) found_draft = true;
    }
    try testing.expect(found_title);
    try testing.expect(found_draft);
}

test "has existing field" {
    const val = testEval("frontmatter | has(\"title\")", test_doc).?;
    try testing.expect(val == .bool);
    try testing.expectEqual(true, val.bool);
}

test "has missing field" {
    const val = testEval("frontmatter | has(\"nonexistent\")", test_doc).?;
    try testing.expect(val == .bool);
    try testing.expectEqual(false, val.bool);
}

test "keys on non-record returns null" {
    const val = testEval("body | keys", test_doc).?;
    try testing.expect(val == .null);
}

// Filesystem-aware builtin helpers

fn testEvalWithPaths(
    program: []const u8,
    content: []const u8,
    file_path: ?[]const u8,
    dir_path: ?[]const u8,
) ?Value {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    var p = Parser.init(alloc, program);
    const node = p.parse() orelse return null;
    var evaluator = Evaluator.init(alloc, content);
    evaluator.file_path = file_path;
    evaluator.dir_path = dir_path;
    return evaluator.eval(node);
}

fn setupTestDir(alloc: std.mem.Allocator) !struct { dir: std.fs.Dir, path: []const u8 } {
    const tmp_path = try std.fmt.allocPrint(alloc, "/tmp/md-test-{d}", .{std.time.milliTimestamp()});
    std.fs.cwd().makeDir(tmp_path) catch {};
    const dir = try std.fs.cwd().openDir(tmp_path, .{ .iterate = true });
    return .{ .dir = dir, .path = tmp_path };
}

fn writeTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

// incoming tests

test "incoming finds linking files" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "target.md", "# Target\nSome content.\n");
    try writeTestFile(tmp.dir, "linker.md", "See [[target]] for details.\n");
    try writeTestFile(tmp.dir, "other.md", "No links here.\n");

    const target = try std.fs.path.join(alloc, &.{ tmp.path, "target.md" });
    const val = testEvalWithPaths("incoming", "# Target\n", target, tmp.path).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("wikilink", val.array[0].record.get("kind").?.string);
}

test "incoming returns empty when no links" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "target.md", "# Target\n");
    try writeTestFile(tmp.dir, "other.md", "No links.\n");

    const target = try std.fs.path.join(alloc, &.{ tmp.path, "target.md" });
    const val = testEvalWithPaths("incoming", "# Target\n", target, tmp.path).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 0), val.array.len);
}

test "incoming without file_path produces error" {
    const val = testEvalWithPaths("incoming", "content\n", null, null);
    try testing.expect(val == null);
}

// exists tests

test "exists adds field to link records" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "existing.md", "# Exists\n");

    const doc = "See [[existing]] and [[missing]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths("links | exists", doc, fp, tmp.path).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 2), val.array.len);

    const first = val.array[0];
    try testing.expectEqualStrings("existing", first.record.get("target").?.string);
    try testing.expectEqual(true, first.record.get("exists").?.bool);

    const second = val.array[1];
    try testing.expectEqualStrings("missing", second.record.get("target").?.string);
    try testing.expectEqual(false, second.record.get("exists").?.bool);
}

test "exists with select filters broken links" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "good.md", "# Good\n");

    const doc = "See [[good]] and [[bad]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths(
        "links | exists | select(.exists == false)",
        doc,
        fp,
        tmp.path,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("bad", val.array[0].record.get("target").?.string);
}

// resolve tests

test "resolve adds path to link records" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "target.md", "# Target\n");

    const doc = "See [[target]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths("links | resolve", doc, fp, tmp.path).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);

    const resolved = val.array[0].record.get("path").?.string;
    try testing.expect(std.mem.endsWith(u8, resolved, "target.md"));
}

test "resolve on unresolvable link returns original target" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    const doc = "See [[nonexistent]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths("links | resolve", doc, fp, tmp.path).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 1), val.array.len);
    try testing.expectEqualStrings("nonexistent", val.array[0].record.get("path").?.string);
}

test "exists called twice does not duplicate keys" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "target.md", "# Target\n");

    const doc = "See [[target]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths("links | exists | exists", doc, fp, tmp.path).?;
    try testing.expect(val == .array);
    const rec = val.array[0].record;
    // Count occurrences of "exists" key — should be exactly 1
    var count: usize = 0;
    for (rec.keys) |k| {
        if (std.mem.eql(u8, k, "exists")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "resolve called twice does not duplicate keys" {
    const alloc = std.heap.page_allocator;
    const tmp = try setupTestDir(alloc);
    defer std.fs.cwd().deleteTree(tmp.path) catch {};

    try writeTestFile(tmp.dir, "target.md", "# Target\n");

    const doc = "See [[target]].\n";
    const fp = try std.fs.path.join(alloc, &.{ tmp.path, "source.md" });
    const val = testEvalWithPaths("links | resolve | resolve", doc, fp, tmp.path).?;
    try testing.expect(val == .array);
    const rec = val.array[0].record;
    var count: usize = 0;
    for (rec.keys) |k| {
        if (std.mem.eql(u8, k, "path")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// yaml builtin tests

test "yaml: record to yaml text" {
    const doc =
        \\---
        \\title: Hello
        \\draft: true
        \\count: 42
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | yaml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "title: Hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, "draft: true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count: 42") != null);
}

test "yaml: string to record" {
    const yaml_text = "title: Parsed\nauthor: Alice\n";
    // Wrap in a document so we can pipe it
    const doc =
        \\---
        \\content: placeholder
        \\---
        \\body
        \\
    ;
    // Use a pipeline that produces the yaml string then parses it
    _ = doc;
    // Directly test yaml parsing via eval: use a literal wouldn't work,
    // so test via codeblock extraction
    const code_doc = "```yaml\ntitle: Parsed\nauthor: Alice\n```\n";
    const val = testEval(
        "codeblocks | first | .content | yaml",
        code_doc,
    ).?;
    _ = yaml_text;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("Parsed", val.record.get("title").?.string);
    try testing.expectEqualStrings("Alice", val.record.get("author").?.string);
}

test "yaml: record with array fields" {
    const doc =
        \\---
        \\tags:
        \\  - alpha
        \\  - beta
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | yaml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "tags:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- alpha") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- beta") != null);
}

test "yaml: record with nested record" {
    const doc =
        \\---
        \\author:
        \\  name: Alice
        \\  email: alice@example.com
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | yaml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "author:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  name: Alice") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  email: alice@example.com") != null);
}

test "yaml: roundtrip record -> yaml -> record" {
    const doc =
        \\---
        \\title: Roundtrip
        \\draft: false
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | yaml | yaml", doc).?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("Roundtrip", val.record.get("title").?.string);
    try testing.expectEqual(false, val.record.get("draft").?.bool);
}

// toml builtin tests

test "toml: record to toml text" {
    const doc =
        \\---
        \\title: Hello
        \\draft: true
        \\count: 42
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | toml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "title = \"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "draft = true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count = 42") != null);
}

test "toml: string to record" {
    const code_doc = "```toml\ntitle = \"Parsed\"\ncount = 7\n```\n";
    const val = testEval(
        "codeblocks | first | .content | toml",
        code_doc,
    ).?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("Parsed", val.record.get("title").?.string);
    try testing.expectEqual(@as(i64, 7), val.record.get("count").?.int);
}

test "toml: record with array" {
    const doc =
        \\---
        \\tags: [alpha, beta]
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | toml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "tags = [\"alpha\", \"beta\"]") != null);
}

test "toml: parse array" {
    const code_doc = "```toml\ntags = [\"a\", \"b\", \"c\"]\n```\n";
    const val = testEval(
        "codeblocks | first | .content | toml | .tags",
        code_doc,
    ).?;
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 3), val.array.len);
    try testing.expectEqualStrings("a", val.array[0].string);
}

test "toml: parse section headers" {
    const code_doc = "```toml\ntitle = \"Doc\"\n\n[author]\nname = \"Alice\"\nemail = \"a@b.com\"\n```\n";
    const val = testEval(
        "codeblocks | first | .content | toml",
        code_doc,
    ).?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("Doc", val.record.get("title").?.string);
    const author = val.record.get("author").?;
    try testing.expect(author == .record);
    try testing.expectEqualStrings("Alice", author.record.get("name").?.string);
}

test "toml: record with nested record renders as table" {
    const doc =
        \\---
        \\title: Hello
        \\author:
        \\  name: Alice
        \\---
        \\body
        \\
    ;
    const out = testRender("frontmatter | toml", doc).?;
    try testing.expect(std.mem.indexOf(u8, out, "title = \"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[author]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"Alice\"") != null);
}

test "toml: roundtrip record -> toml -> record" {
    const doc =
        \\---
        \\title: Roundtrip
        \\draft: false
        \\count: 5
        \\---
        \\body
        \\
    ;
    const val = testEval("frontmatter | toml | toml", doc).?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("Roundtrip", val.record.get("title").?.string);
    try testing.expectEqual(false, val.record.get("draft").?.bool);
    try testing.expectEqual(@as(i64, 5), val.record.get("count").?.int);
}

test "toml: frontmatter from toml document" {
    const doc = "+++\ntitle = \"TOML Doc\"\ndraft = true\n+++\n# Body\n";
    const val = testEval("frontmatter", doc).?;
    try testing.expect(val == .record);
    try testing.expectEqualStrings("TOML Doc", val.record.get("title").?.string);
    try testing.expectEqual(true, val.record.get("draft").?.bool);
}
