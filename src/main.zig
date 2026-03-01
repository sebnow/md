const std = @import("std");
const md = @import("md");

const usage =
    \\Usage: md <command> [options] [file]
    \\
    \\Commands:
    \\  body         Output document body without frontmatter
    \\  frontmatter  Output or edit YAML frontmatter
    \\  headings     List headings with depth and line numbers
    \\  links        List outgoing links
    \\  tags         List tags
    \\  codeblocks   List fenced code blocks
    \\  stats        Show document statistics
    \\  section      Extract content under a heading
    \\
    \\Options:
    \\  --json       Output in JSON format
    \\  --help       Show this help message
    \\
    \\If no file is given, reads from stdin.
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

fn run(arena: std.mem.Allocator, out: *Output) !void {
    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // program name

    const command = arg_iter.next() orelse {
        out.writeErr(usage);
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try out.write(usage);
        return;
    }

    const handlers = .{
        .{ "body", cmdBody },
        .{ "frontmatter", cmdFrontmatter },
        .{ "headings", cmdHeadings },
        .{ "links", cmdLinks },
        .{ "tags", cmdTags },
        .{ "codeblocks", cmdCodeblocks },
        .{ "stats", cmdStats },
        .{ "section", cmdSection },
    };

    inline for (handlers) |entry| {
        if (std.mem.eql(u8, command, entry[0])) {
            return entry[1](arena, &arg_iter, out);
        }
    }

    out.writeErr("md: unknown command '");
    out.writeErr(command);
    out.writeErr("'\n");
    return error.UnknownCommand;
}

const Args = struct {
    json: bool = false,
    incoming: bool = false,
    dir: ?[]const u8 = null,
    file: ?[]const u8 = null,
    positional: ?[]const u8 = null,
};

fn parseArgs(iter: *std.process.ArgIterator) Args {
    var result: Args = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--incoming")) {
            result.incoming = true;
        } else if (std.mem.eql(u8, arg, "--dir")) {
            result.dir = iter.next();
        } else if (arg.len > 0 and arg[0] == '-') {
            // Ignore unknown flags for forward compatibility
        } else if (result.positional == null and result.file == null) {
            result.positional = arg;
        } else if (result.file == null) {
            result.file = arg;
        }
    }
    return result;
}

fn readInput(arena: std.mem.Allocator, args: Args) ![]const u8 {
    const path = args.file orelse args.positional;
    if (path) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        return try file.readToEndAlloc(arena, max_file_size);
    }
    return try std.fs.File.stdin().readToEndAlloc(arena, max_file_size);
}

fn readInputWithFile(arena: std.mem.Allocator, args: Args) ![]const u8 {
    if (args.file) |p| {
        const file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        return try file.readToEndAlloc(arena, max_file_size);
    }
    if (args.positional == null) {
        return try std.fs.File.stdin().readToEndAlloc(arena, max_file_size);
    }
    return error.MissingFile;
}

fn cmdBody(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);

    if (md.frontmatter.extract(content)) |fm| {
        try out.write(fm.body);
    } else {
        try out.write(content);
    }
}

fn cmdFrontmatter(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    // Peek at next arg to check for sub-subcommands (set, delete)
    const first_arg = iter.next();
    if (first_arg) |sub| {
        if (std.mem.eql(u8, sub, "set")) {
            return cmdFrontmatterSet(arena, iter, out);
        }
        if (std.mem.eql(u8, sub, "delete")) {
            return cmdFrontmatterDelete(arena, iter, out);
        }
    }

    // Regular frontmatter output — re-parse args with first_arg as potential file/flag
    var args: Args = .{};
    if (first_arg) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            args.json = true;
        } else if (a.len > 0 and a[0] != '-') {
            args.positional = a;
        }
    }
    const more = parseArgs(iter);
    if (more.json) args.json = true;
    if (args.positional == null) args.positional = more.positional;
    if (args.file == null) args.file = more.file;

    const content = try readInput(arena, args);

    if (md.frontmatter.extract(content)) |fm| {
        try out.write(fm.raw);
    }
}

fn cmdFrontmatterSet(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    var in_place = false;
    var file_path: ?[]const u8 = null;
    var ops: std.ArrayListUnmanaged(md.frontmatter.FieldOp) = .empty;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            in_place = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            continue;
        } else if (file_path == null) {
            file_path = arg;
        } else {
            // key-value pair: this arg is the key, next is the value
            const value = iter.next() orelse {
                return error.MissingArgument;
            };
            try ops.append(arena, .{ .set = .{ .key = arg, .value = value } });
        }
    }

    const path = file_path orelse return error.MissingArgument;
    if (ops.items.len == 0) return error.MissingArgument;

    const content = blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, max_file_size);
    };

    const result = try md.frontmatter.editFields(arena, content, ops.items);

    if (in_place) {
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        try out_file.writeAll(result);
    } else {
        try out.write(result);
    }
}

fn cmdFrontmatterDelete(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    var in_place = false;
    var file_path: ?[]const u8 = null;
    var ops: std.ArrayListUnmanaged(md.frontmatter.FieldOp) = .empty;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            in_place = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            continue;
        } else if (file_path == null) {
            file_path = arg;
        } else {
            try ops.append(arena, .{ .delete = arg });
        }
    }

    const path = file_path orelse return error.MissingArgument;
    if (ops.items.len == 0) return error.MissingArgument;

    const content = blk: {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, max_file_size);
    };

    const result = try md.frontmatter.editFields(arena, content, ops.items);

    if (in_place) {
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        try out_file.writeAll(result);
    } else {
        try out.write(result);
    }
}

fn cmdHeadings(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_headings = try md.headings.parse(arena, content);

    if (args.json) {
        try writeJsonHeadings(out, parsed_headings);
    } else {
        for (parsed_headings) |h| {
            var line_buf: [32]u8 = undefined;
            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{h.line}) catch unreachable;
            try out.write(line_str);
            try out.write(":");
            var depth_idx: u3 = 0;
            while (depth_idx < h.depth) : (depth_idx += 1) {
                try out.write("#");
            }
            try out.write(" ");
            try out.write(h.text);
            try out.write("\n");
        }
    }
}

fn cmdLinks(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);

    if (args.incoming) {
        return cmdLinksIncoming(arena, args, out);
    }

    const content = try readInput(arena, args);
    const parsed_links = try md.links.parse(arena, content);

    if (args.json) {
        try writeJsonLinks(out, parsed_links);
    } else {
        for (parsed_links) |l| {
            try out.write(@tagName(l.kind));
            try out.write("\t");
            try out.write(l.target);
            try out.write("\n");
        }
    }
}

const IncomingLink = struct {
    source_path: []const u8,
    link: md.links.Link,
};

fn cmdLinksIncoming(arena: std.mem.Allocator, args: Args, out: *Output) !void {
    const target_path = args.positional orelse {
        return error.MissingArgument;
    };

    const target_basename = std.fs.path.stem(target_path);
    const target_dir = std.fs.path.dirname(target_path);
    const scan_dir_path = args.dir orelse target_dir orelse ".";

    var incoming: std.ArrayListUnmanaged(IncomingLink) = .empty;

    var dir = std.fs.cwd().openDir(scan_dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            out.writeErr("md: directory not found: ");
            out.writeErr(scan_dir_path);
            out.writeErr("\n");
        }
        return err;
    };
    defer dir.close();

    try scanDirForLinks(arena, dir, scan_dir_path, target_path, target_basename, &incoming);

    if (args.json) {
        try out.write("[");
        for (incoming.items, 0..) |item, idx| {
            if (idx > 0) try out.write(",");
            try out.write("{\"source\":\"");
            try writeJsonEscaped(out, item.source_path);
            try out.write("\",\"kind\":\"");
            try out.write(@tagName(item.link.kind));
            try out.write("\",\"line\":");
            var buf: [32]u8 = undefined;
            try out.write(std.fmt.bufPrint(&buf, "{d}", .{item.link.line}) catch unreachable);
            try out.write("}");
        }
        try out.write("]\n");
    } else {
        for (incoming.items) |item| {
            try out.write(item.source_path);
            try out.write("\t");
            try out.write(@tagName(item.link.kind));
            var buf: [32]u8 = undefined;
            try out.write("\t");
            try out.write(std.fmt.bufPrint(&buf, "{d}", .{item.link.line}) catch unreachable);
            try out.write("\n");
        }
    }
}

fn scanDirForLinks(
    arena: std.mem.Allocator,
    dir: std.fs.Dir,
    dir_path: []const u8,
    target_path: []const u8,
    target_basename: []const u8,
    incoming: *std.ArrayListUnmanaged(IncomingLink),
) !void {
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isMarkdownFile(entry.basename)) continue;

        const source_path = try std.fs.path.join(arena, &.{ dir_path, entry.path });

        if (std.mem.eql(u8, source_path, target_path)) continue;

        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(arena, max_file_size) catch continue;

        const links = try md.links.parse(arena, content);
        for (links) |link| {
            if (linkMatchesTarget(link, target_path, target_basename, source_path)) {
                try incoming.append(arena, .{
                    .source_path = source_path,
                    .link = link,
                });
            }
        }
    }
}

fn linkMatchesTarget(
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
        std.heap.page_allocator,
        &.{ source_dir, link_target },
    ) catch return false;

    const target_resolved = std.fs.path.resolve(
        std.heap.page_allocator,
        &.{target_path},
    ) catch return false;

    return std.mem.eql(u8, resolved, target_resolved);
}

fn isMarkdownFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") or
        std.mem.endsWith(u8, name, ".MD") or
        std.mem.endsWith(u8, name, ".markdown") or
        std.mem.endsWith(u8, name, ".Markdown") or
        std.mem.endsWith(u8, name, ".MARKDOWN");
}

fn cmdTags(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_tags = try md.tags.parse(arena, content);

    if (args.json) {
        try writeJsonTags(out, parsed_tags);
    } else {
        for (parsed_tags) |t| {
            try out.write(t.name);
            try out.write("\n");
        }
    }
}

fn cmdCodeblocks(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_blocks = try md.codeblocks.parse(arena, content);

    if (args.json) {
        try writeJsonCodeblocks(out, parsed_blocks);
    } else {
        for (parsed_blocks) |b| {
            var line_buf: [64]u8 = undefined;
            const range = std.fmt.bufPrint(&line_buf, "{d}-{d}", .{ b.start_line, b.end_line }) catch unreachable;
            try out.write(range);
            try out.write("\t");
            if (b.language.len > 0) {
                try out.write(b.language);
            } else {
                try out.write("(none)");
            }
            try out.write("\n");
        }
    }
}

fn cmdStats(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);

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

    if (args.json) {
        try out.write("{\"lines\":");
        var buf: [32]u8 = undefined;
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{lines}) catch unreachable);
        try out.write(",\"words\":");
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{words}) catch unreachable);
        try out.write("}\n");
    } else {
        var buf: [32]u8 = undefined;
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{lines}) catch unreachable);
        try out.write(" lines\n");
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{words}) catch unreachable);
        try out.write(" words\n");
    }
}

fn cmdSection(arena: std.mem.Allocator, iter: *std.process.ArgIterator, out: *Output) !void {
    const args = parseArgs(iter);
    const heading_pattern = args.positional orelse {
        return error.MissingArgument;
    };
    const content = try readInputWithFile(arena, args);
    const parsed_headings = try md.headings.parse(arena, content);

    for (parsed_headings, 0..) |h, idx| {
        if (!matchesHeading(h, heading_pattern)) continue;

        var end_pos = content.len;
        for (parsed_headings[idx + 1 ..]) |next_h| {
            if (next_h.depth <= h.depth) {
                end_pos = lineStartPos(content, next_h.line);
                break;
            }
        }

        const start_pos = lineStartPos(content, h.line + 1);
        if (start_pos <= end_pos) {
            try out.write(content[start_pos..end_pos]);
        }
        break;
    }
}

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

// JSON output helpers

fn writeJsonHeadings(out: *Output, parsed_headings: []const md.headings.Heading) !void {
    try out.write("[");
    for (parsed_headings, 0..) |h, idx| {
        if (idx > 0) try out.write(",");
        try out.write("{\"depth\":");
        var buf: [32]u8 = undefined;
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{h.depth}) catch unreachable);
        try out.write(",\"text\":\"");
        try writeJsonEscaped(out, h.text);
        try out.write("\",\"line\":");
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{h.line}) catch unreachable);
        try out.write("}");
    }
    try out.write("]\n");
}

fn writeJsonLinks(out: *Output, parsed_links: []const md.links.Link) !void {
    try out.write("[");
    for (parsed_links, 0..) |l, idx| {
        if (idx > 0) try out.write(",");
        try out.write("{\"kind\":\"");
        try out.write(@tagName(l.kind));
        try out.write("\",\"target\":\"");
        try writeJsonEscaped(out, l.target);
        try out.write("\",\"text\":\"");
        try writeJsonEscaped(out, l.text);
        try out.write("\",\"line\":");
        var buf: [32]u8 = undefined;
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{l.line}) catch unreachable);
        try out.write("}");
    }
    try out.write("]\n");
}

fn writeJsonTags(out: *Output, parsed_tags: []const md.tags.Tag) !void {
    try out.write("[");
    for (parsed_tags, 0..) |t, idx| {
        if (idx > 0) try out.write(",");
        try out.write("\"");
        try writeJsonEscaped(out, t.name);
        try out.write("\"");
    }
    try out.write("]\n");
}

fn writeJsonCodeblocks(out: *Output, parsed_blocks: []const md.codeblocks.CodeBlock) !void {
    try out.write("[");
    for (parsed_blocks, 0..) |b, idx| {
        if (idx > 0) try out.write(",");
        try out.write("{\"language\":\"");
        try writeJsonEscaped(out, b.language);
        try out.write("\",\"start_line\":");
        var buf: [32]u8 = undefined;
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{b.start_line}) catch unreachable);
        try out.write(",\"end_line\":");
        try out.write(std.fmt.bufPrint(&buf, "{d}", .{b.end_line}) catch unreachable);
        try out.write("}");
    }
    try out.write("]\n");
}

fn writeJsonEscaped(out: *Output, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.write("\\\""),
            '\\' => try out.write("\\\\"),
            '\n' => try out.write("\\n"),
            '\r' => try out.write("\\r"),
            '\t' => try out.write("\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.write(&buf);
                } else {
                    try out.write(&.{c});
                }
            },
        }
    }
}

fn printError(out: *Output, err: anyerror) void {
    const msg: []const u8 = switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.MissingCommand => "missing command, use --help for usage",
        error.UnknownCommand => "unknown command, use --help for usage",
        error.MissingArgument => "missing required argument",
        error.MissingFile => "missing file argument",
        else => @errorName(err),
    };
    out.writeErr("md: ");
    out.writeErr(msg);
    out.writeErr("\n");
}
