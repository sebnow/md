const std = @import("std");
const md = @import("md");

const usage =
    \\Usage: md '<program>' [options] [file]
    \\
    \\Evaluate a jq-inspired DSL program against a Markdown file.
    \\If no file is given, reads from stdin.
    \\
    \\Options:
    \\  --json              Output in JSON format
    \\  --dir <path>        Directory for incoming/exists/resolve
    \\  -i                  Edit file in-place (for mutations)
    \\  --arg NAME=VALUE    Bind a named parameter (repeatable)
    \\  --help              Show this help message
    \\
    \\Extractors:
    \\  frontmatter  YAML or TOML frontmatter as a record
    \\  body         Document body without frontmatter (string)
    \\  headings     Headings array: .depth, .text, .line, .source
    \\  links        Links array: .kind, .target, .text, .line, .source
    \\  tags         Inline tags array: .name, .line, .source
    \\  codeblocks   Code blocks array: .language, .content, .start_line, .end_line, .source
    \\  stats        Word and line counts: .lines, .words
    \\  comments     Comments array: .kind, .text, .line, .source
    \\  footnotes    Footnotes array: .label, .text, .line, .source
    \\  nodes        Block nodes array: .type, .text, .line, .source
    \\               Types: heading, paragraph, codeblock, comment, footnote
    \\               Type-specific: .depth, .language, .kind, .label
    \\  incoming     Files linking to input: .source, .kind, .line (needs --dir)
    \\
    \\Filtering:
    \\  select(pred)         Filter arrays by predicate
    \\  skip_until(pred)     Drop elements until predicate matches
    \\  take_until(pred)     Take elements until predicate matches
    \\  contains(.f, str)    Test if field contains substring
    \\  startswith(.f, str)  Test if field starts with prefix
    \\
    \\List operations:
    \\  first         First element
    \\  last          Last element
    \\  count         Length of array, string, or record
    \\  reverse       Reverse array order
    \\  unique        Deduplicate values
    \\  map(.field)   Extract field from each element
    \\  sort(.field)  Sort array by field
    \\  group(.field) Group into record keyed by field value
    \\
    \\Record operations:
    \\  keys          List record keys
    \\  has("name")   Check if field exists
    \\
    \\Format conversion:
    \\  yaml   Record to YAML text, or YAML text to record
    \\  toml   Record to TOML text, or TOML text to record
    \\
    \\Mutation:
    \\  set(.field, value)   Set a frontmatter field
    \\  del(.field)          Delete a frontmatter field
    \\  .field += [values]   Append to frontmatter array
    \\  replace(text)        Replace span identified by .source
    \\  append(text)         Insert text after span identified by .source
    \\
    \\Link validation:
    \\  exists    Add .exists boolean to link records
    \\  resolve   Add .path with resolved filesystem path
    \\
    \\Examples:
    \\  md 'frontmatter | .title' notes.md
    \\  md 'headings | select(.depth == 2)' notes.md
    \\  md 'links | select(.kind == "wikilink")' notes.md
    \\  md 'frontmatter | set(.draft, false)' -i notes.md
    \\  md 'incoming' --dir ./vault/ notes.md
    \\  md 'stats | .words' notes.md
    \\
    \\See md(1) for detailed documentation.
    \\
;

const ParamMap = md.eval.ParamMap;

const BindError = error{ MissingEquals, DuplicateName, FileReadFailed };

fn bindParam(arena: std.mem.Allocator, params: *ParamMap, spec: []const u8) BindError!void {
    const eq_pos = std.mem.indexOfScalar(u8, spec, '=') orelse return error.MissingEquals;
    const name = spec[0..eq_pos];
    const raw_value = spec[eq_pos + 1 ..];

    const value: []const u8 = if (raw_value.len > 0 and raw_value[0] == '@') blk: {
        if (raw_value.len > 1 and raw_value[1] == '@') {
            // @@ prefix: literal value beginning with @
            break :blk raw_value[1..];
        }
        const path = raw_value[1..];
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileReadFailed;
        defer file.close();
        break :blk file.readToEndAlloc(arena, max_file_size) catch return error.FileReadFailed;
    } else raw_value;

    const result = params.getOrPut(arena, name) catch @panic("out of memory");
    if (result.found_existing) return error.DuplicateName;
    result.value_ptr.* = value;
}

const max_file_size = 64 * 1024 * 1024; // 64 MiB

const Output = struct {
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    stdout_buf: [8192]u8 = undefined,
    stderr_buf: [1024]u8 = undefined,

    fn init() Output {
        var o: Output = .{
            .stdout = undefined,
            .stderr = undefined,
        };
        o.stdout = std.fs.File.stdout().writer(&o.stdout_buf);
        o.stderr = std.fs.File.stderr().writer(&o.stderr_buf);
        return o;
    }

    fn write(self: *Output, bytes: []const u8) !void {
        self.stdout.interface.writeAll(bytes) catch |err| {
            if (err == error.WriteFailed) {
                if (self.stdout.err) |e| {
                    if (e == error.BrokenPipe) std.process.exit(0);
                    return error.WriteFailed;
                }
            }
            return err;
        };
    }

    fn writeErr(self: *Output, bytes: []const u8) void {
        self.stderr.interface.writeAll(bytes) catch {};
    }

    fn flush(self: *Output) void {
        self.stdout.interface.flush() catch {};
        self.stderr.interface.flush() catch {};
    }
};

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = Output.init();
    defer out.flush();

    run(arena, &out) catch |err| {
        printError(&out, err);
        out.flush();
        std.process.exit(1);
    };
}

const Args = struct {
    program: []const u8,
    file: ?[]const u8 = null,
    json: bool = false,
    in_place: bool = false,
    dir: ?[]const u8 = null,
    params: ParamMap = .{},
};

fn run(arena: std.mem.Allocator, out: *Output) !void {
    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // program name

    var args: Args = .{ .program = undefined };
    var found_program = false;

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            args.in_place = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            args.dir = arg_iter.next() orelse {
                out.writeErr("md: --dir requires a value\n");
                return error.MissingArgument;
            };
        } else if (std.mem.eql(u8, arg, "--arg")) {
            const spec = arg_iter.next() orelse {
                out.writeErr("md: --arg requires NAME=VALUE\n");
                return error.MissingArgument;
            };
            bindParam(arena, &args.params, spec) catch |err| switch (err) {
                error.MissingEquals => {
                    out.writeErr("md: --arg: missing '=' in '");
                    out.writeErr(spec);
                    out.writeErr("'\n");
                    return error.MissingArgument;
                },
                error.DuplicateName => {
                    const eq = std.mem.indexOfScalar(u8, spec, '=').?;
                    out.writeErr("md: --arg: duplicate parameter '");
                    out.writeErr(spec[0..eq]);
                    out.writeErr("'\n");
                    return error.MissingArgument;
                },
                error.FileReadFailed => {
                    const eq = std.mem.indexOfScalar(u8, spec, '=').?;
                    out.writeErr("md: --arg: cannot read file '");
                    out.writeErr(spec[eq + 2 ..]); // skip '=' and '@'
                    out.writeErr("'\n");
                    return error.MissingArgument;
                },
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.write(usage);
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            out.writeErr("md: unknown option: ");
            out.writeErr(arg);
            out.writeErr("\n");
            return error.MissingArgument;
        } else if (!found_program) {
            args.program = arg;
            found_program = true;
        } else if (args.file == null) {
            args.file = arg;
        }
    }

    if (!found_program) {
        out.writeErr(usage);
        return error.MissingArgument;
    }

    // Parse DSL program
    var parser = md.parser.Parser.init(arena, args.program);
    const node = parser.parse() orelse {
        var buf: [512]u8 = undefined;
        if (parser.formatErrorWithPrefix("md: ".len, &buf)) |msg| {
            out.writeErr("md: ");
            out.writeErr(msg);
            out.writeErr("\n");
            const e = parser.err.?;
            if (md.lexer.diagnosticHint(args.program, e.pos, e.message)) |hint| {
                out.writeErr(hint);
                out.writeErr("\n");
            }
        } else {
            out.writeErr("md: failed to parse program\n");
        }
        return error.ParseError;
    };

    // Read input
    const content = try readInput(arena, args);

    // Evaluate
    var evaluator = md.eval.Evaluator.init(arena, content);
    evaluator.file_path = args.file;
    evaluator.dir_path = args.dir;
    evaluator.params = args.params;

    const result = evaluator.eval(node) orelse {
        if (evaluator.err) |eval_err| {
            out.writeErr("md: ");
            out.writeErr(eval_err.message);
            out.writeErr("\n");
        } else {
            out.writeErr("md: evaluation produced no result\n");
        }
        return error.EvalError;
    };

    // Handle in-place editing
    if (args.in_place) {
        const path = args.file orelse {
            out.writeErr("md: -i requires a file argument\n");
            return error.MissingArgument;
        };
        const output = switch (result) {
            .string => |s| s,
            else => {
                out.writeErr("md: -i requires the program to produce a document string\n");
                return error.EvalError;
            },
        };
        const cwd = std.fs.cwd();
        const tmp_path = std.fmt.allocPrint(arena, "{s}.tmp", .{path}) catch return error.WriteFailed;
        const tmp_file = try cwd.createFile(tmp_path, .{});
        tmp_file.writeAll(output) catch |err| {
            tmp_file.close();
            cwd.deleteFile(tmp_path) catch {};
            return err;
        };
        tmp_file.close();
        cwd.rename(tmp_path, path) catch |err| {
            cwd.deleteFile(tmp_path) catch {};
            return err;
        };
        return;
    }

    // Render output
    var buf = std.ArrayListUnmanaged(u8).empty;
    if (args.json) {
        result.renderJson(buf.writer(arena)) catch return error.WriteFailed;
        try out.write(buf.toOwnedSlice(arena) catch return error.WriteFailed);
        try out.write("\n");
    } else {
        result.renderPlain(buf.writer(arena)) catch return error.WriteFailed;
        const rendered = buf.toOwnedSlice(arena) catch return error.WriteFailed;
        try out.write(rendered);
        // Add trailing newline if output doesn't end with one
        if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
            try out.write("\n");
        }
    }
}

fn readInput(arena: std.mem.Allocator, args: Args) ![]const u8 {
    if (args.file) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        return try file.readToEndAlloc(arena, max_file_size);
    }
    return try std.fs.File.stdin().readToEndAlloc(arena, max_file_size);
}

fn printError(out: *Output, err: anyerror) void {
    const msg: []const u8 = switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.StreamTooLong => "file too large (maximum 64 MiB)",
        error.MissingArgument => "missing argument, use --help for usage",
        error.ParseError, error.EvalError => return, // already printed
        else => @errorName(err),
    };
    out.writeErr("md: ");
    out.writeErr(msg);
    out.writeErr("\n");
}

// Tests

const testing = std.testing;

test "bindParam literal value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try bindParam(arena.allocator(), &params, "x=hello world");
    try testing.expectEqualStrings("hello world", params.get("x").?);
}

test "bindParam value with equals sign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try bindParam(arena.allocator(), &params, "x=a=b");
    try testing.expectEqualStrings("a=b", params.get("x").?);
}

test "bindParam missing equals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try testing.expectError(error.MissingEquals, bindParam(arena.allocator(), &params, "xnoeq"));
}

test "bindParam duplicate name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try bindParam(arena.allocator(), &params, "x=a");
    try testing.expectError(error.DuplicateName, bindParam(arena.allocator(), &params, "x=b"));
}

test "bindParam file value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/val.txt", .{dir_path});
    defer testing.allocator.free(file_path);
    const f = try std.fs.createFileAbsolute(file_path, .{});
    try f.writeAll("content from file");
    f.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    const spec = try std.fmt.allocPrint(testing.allocator, "x=@{s}", .{file_path});
    defer testing.allocator.free(spec);
    try bindParam(arena.allocator(), &params, spec);
    try testing.expectEqualStrings("content from file", params.get("x").?);
}

test "bindParam file value with special chars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/notes.md", .{dir_path});
    defer testing.allocator.free(file_path);
    const content = "line one\n\"quoted\"\nback\\slash\n\nempty above\n";
    const f = try std.fs.createFileAbsolute(file_path, .{});
    try f.writeAll(content);
    f.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    const spec = try std.fmt.allocPrint(testing.allocator, "notes=@{s}", .{file_path});
    defer testing.allocator.free(spec);
    try bindParam(arena.allocator(), &params, spec);
    try testing.expectEqualStrings(content, params.get("notes").?);
}

test "bindParam double-at escapes literal at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try bindParam(arena.allocator(), &params, "x=@@foo");
    try testing.expectEqualStrings("@foo", params.get("x").?);
}

test "bindParam unreadable file returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var params = ParamMap{};
    try testing.expectError(error.FileReadFailed, bindParam(arena.allocator(), &params, "x=@/tmp/md_no_such_file_xyz_12345.txt"));
}
