const std = @import("std");
const md = @import("md");

const usage =
    \\Usage: md '<program>' [options] [file]
    \\
    \\Evaluate a DSL program against a Markdown file.
    \\
    \\Options:
    \\  --json       Output in JSON format
    \\  --dir <path> Directory for incoming/exists/resolve
    \\  -i           Edit file in-place (for mutations)
    \\  --help       Show this help message
    \\
    \\If no file is given, reads from stdin.
    \\
    \\Examples:
    \\  md 'frontmatter | .title' notes.md
    \\  md 'headings | select(.depth == 2)' notes.md
    \\  md 'links | select(.kind == "wikilink")' notes.md
    \\  md 'frontmatter | set(.draft, false)' -i notes.md
    \\  md 'incoming' --dir ./vault/ notes.md
    \\  md 'stats | .words' notes.md
    \\
;

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
};

fn run(arena: std.mem.Allocator, out: *Output) !void {
    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // program name

    const first = arg_iter.next() orelse {
        out.writeErr(usage);
        return error.MissingArgument;
    };

    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        try out.write(usage);
        return;
    }

    var args: Args = .{ .program = first };
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            args.in_place = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            args.dir = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.write(usage);
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            // ignore unknown flags
        } else if (args.file == null) {
            args.file = arg;
        }
    }

    // Parse DSL program
    var parser = md.parser.Parser.init(arena, args.program);
    const node = parser.parse() orelse {
        var buf: [512]u8 = undefined;
        if (parser.formatError(&buf)) |msg| {
            out.writeErr("md: ");
            out.writeErr(msg);
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
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        try out_file.writeAll(output);
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
        error.MissingArgument => "missing argument, use --help for usage",
        error.ParseError, error.EvalError => return, // already printed
        else => @errorName(err),
    };
    out.writeErr("md: ");
    out.writeErr(msg);
    out.writeErr("\n");
}
