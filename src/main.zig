const std = @import("std");
const md = @import("md");

const usage =
    \\Usage: md <command> [options] [file]
    \\
    \\Commands:
    \\  body         Output document body without frontmatter
    \\  frontmatter  Output frontmatter as JSON
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    run(arena) catch |err| {
        printError(err);
        std.process.exit(1);
    };
}

fn run(arena: std.mem.Allocator) !void {
    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // program name

    const command = arg_iter.next() orelse {
        try writeAll(stdErr(), usage);
        return error.MissingCommand;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try writeAll(stdOut(), usage);
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
            return entry[1](arena, &arg_iter);
        }
    }

    try writeAll(stdErr(), "md: unknown command '");
    try writeAll(stdErr(), command);
    try writeAll(stdErr(), "'\n");
    return error.UnknownCommand;
}

const Args = struct {
    json: bool = false,
    file: ?[]const u8 = null,
    positional: ?[]const u8 = null,
};

fn parseArgs(iter: *std.process.ArgIterator) Args {
    var result: Args = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            // Ignore unknown flags for forward compatibility
        } else if (result.positional == null and result.file == null) {
            // First positional — could be either a sub-argument or file
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

fn cmdBody(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);

    if (md.frontmatter.extract(content)) |fm| {
        try writeAll(stdOut(), fm.body);
    } else {
        try writeAll(stdOut(), content);
    }
}

fn cmdFrontmatter(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);

    if (md.frontmatter.extract(content)) |fm| {
        if (args.json) {
            try writeAll(stdOut(), fm.raw);
        } else {
            try writeAll(stdOut(), fm.raw);
        }
    }
    // No frontmatter — output nothing
}

fn cmdHeadings(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_headings = try md.headings.parse(arena, content);

    if (args.json) {
        try writeJsonHeadings(parsed_headings);
    } else {
        for (parsed_headings) |h| {
            var line_buf: [32]u8 = undefined;
            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{h.line}) catch unreachable;
            try writeAll(stdOut(), line_str);
            try writeAll(stdOut(), ":");
            var depth_idx: u3 = 0;
            while (depth_idx < h.depth) : (depth_idx += 1) {
                try writeAll(stdOut(), "#");
            }
            try writeAll(stdOut(), " ");
            try writeAll(stdOut(), h.text);
            try writeAll(stdOut(), "\n");
        }
    }
}

fn cmdLinks(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_links = try md.links.parse(arena, content);

    if (args.json) {
        try writeJsonLinks(parsed_links);
    } else {
        for (parsed_links) |l| {
            try writeAll(stdOut(), @tagName(l.kind));
            try writeAll(stdOut(), "\t");
            try writeAll(stdOut(), l.target);
            try writeAll(stdOut(), "\n");
        }
    }
}

fn cmdTags(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_tags = try md.tags.parse(arena, content);

    if (args.json) {
        try writeJsonTags(parsed_tags);
    } else {
        for (parsed_tags) |t| {
            try writeAll(stdOut(), t.name);
            try writeAll(stdOut(), "\n");
        }
    }
}

fn cmdCodeblocks(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    const content = try readInput(arena, args);
    const parsed_blocks = try md.codeblocks.parse(arena, content);

    if (args.json) {
        try writeJsonCodeblocks(parsed_blocks);
    } else {
        for (parsed_blocks) |b| {
            var line_buf: [64]u8 = undefined;
            const range = std.fmt.bufPrint(&line_buf, "{d}-{d}", .{ b.start_line, b.end_line }) catch unreachable;
            try writeAll(stdOut(), range);
            try writeAll(stdOut(), "\t");
            if (b.language.len > 0) {
                try writeAll(stdOut(), b.language);
            } else {
                try writeAll(stdOut(), "(none)");
            }
            try writeAll(stdOut(), "\n");
        }
    }
}

fn cmdStats(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
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
    // Count final line if file doesn't end with newline
    if (body.len > 0 and body[body.len - 1] != '\n') lines += 1;

    if (args.json) {
        try writeAll(stdOut(), "{\"lines\":");
        var buf: [32]u8 = undefined;
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{lines}) catch unreachable);
        try writeAll(stdOut(), ",\"words\":");
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{words}) catch unreachable);
        try writeAll(stdOut(), "}\n");
    } else {
        var buf: [32]u8 = undefined;
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{lines}) catch unreachable);
        try writeAll(stdOut(), " lines\n");
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{words}) catch unreachable);
        try writeAll(stdOut(), " words\n");
    }
}

fn cmdSection(arena: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const args = parseArgs(iter);
    // For section, the first positional is the heading pattern, second is file
    const heading_pattern = args.positional orelse {
        try writeAll(stdErr(), "md section: missing heading argument\n");
        return error.MissingArgument;
    };
    // Re-read input using file (not positional)
    const content = try readInputWithFile(arena, args);
    const parsed_headings = try md.headings.parse(arena, content);

    // Find matching heading
    for (parsed_headings, 0..) |h, idx| {
        if (!matchesHeading(h, heading_pattern)) continue;

        // Find the end: next heading of same or lesser depth
        var end_pos = content.len;
        for (parsed_headings[idx + 1 ..]) |next_h| {
            if (next_h.depth <= h.depth) {
                end_pos = lineStartPos(content, next_h.line);
                break;
            }
        }

        // Find start of content (line after the heading)
        const start_pos = lineStartPos(content, h.line + 1);
        if (start_pos <= end_pos) {
            try writeAll(stdOut(), content[start_pos..end_pos]);
        }
        break;
    }
}

fn matchesHeading(h: md.headings.Heading, pattern: []const u8) bool {
    // Pattern can be "## Heading" or just "Heading"
    var p = pattern;

    // Strip leading #'s and whitespace
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

fn writeJsonHeadings(parsed_headings: []const md.headings.Heading) !void {
    try writeAll(stdOut(), "[");
    for (parsed_headings, 0..) |h, idx| {
        if (idx > 0) try writeAll(stdOut(), ",");
        try writeAll(stdOut(), "{\"depth\":");
        var buf: [32]u8 = undefined;
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{h.depth}) catch unreachable);
        try writeAll(stdOut(), ",\"text\":\"");
        try writeJsonEscaped(stdOut(), h.text);
        try writeAll(stdOut(), "\",\"line\":");
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{h.line}) catch unreachable);
        try writeAll(stdOut(), "}");
    }
    try writeAll(stdOut(), "]\n");
}

fn writeJsonLinks(parsed_links: []const md.links.Link) !void {
    try writeAll(stdOut(), "[");
    for (parsed_links, 0..) |l, idx| {
        if (idx > 0) try writeAll(stdOut(), ",");
        try writeAll(stdOut(), "{\"kind\":\"");
        try writeAll(stdOut(), @tagName(l.kind));
        try writeAll(stdOut(), "\",\"target\":\"");
        try writeJsonEscaped(stdOut(), l.target);
        try writeAll(stdOut(), "\",\"text\":\"");
        try writeJsonEscaped(stdOut(), l.text);
        try writeAll(stdOut(), "\",\"line\":");
        var buf: [32]u8 = undefined;
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{l.line}) catch unreachable);
        try writeAll(stdOut(), "}");
    }
    try writeAll(stdOut(), "]\n");
}

fn writeJsonTags(parsed_tags: []const md.tags.Tag) !void {
    try writeAll(stdOut(), "[");
    for (parsed_tags, 0..) |t, idx| {
        if (idx > 0) try writeAll(stdOut(), ",");
        try writeAll(stdOut(), "\"");
        try writeJsonEscaped(stdOut(), t.name);
        try writeAll(stdOut(), "\"");
    }
    try writeAll(stdOut(), "]\n");
}

fn writeJsonCodeblocks(parsed_blocks: []const md.codeblocks.CodeBlock) !void {
    try writeAll(stdOut(), "[");
    for (parsed_blocks, 0..) |b, idx| {
        if (idx > 0) try writeAll(stdOut(), ",");
        try writeAll(stdOut(), "{\"language\":\"");
        try writeJsonEscaped(stdOut(), b.language);
        try writeAll(stdOut(), "\",\"start_line\":");
        var buf: [32]u8 = undefined;
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{b.start_line}) catch unreachable);
        try writeAll(stdOut(), ",\"end_line\":");
        try writeAll(stdOut(), std.fmt.bufPrint(&buf, "{d}", .{b.end_line}) catch unreachable);
        try writeAll(stdOut(), "}");
    }
    try writeAll(stdOut(), "]\n");
}

fn writeJsonEscaped(out: std.fs.File, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writeAll(out, "\\\""),
            '\\' => try writeAll(out, "\\\\"),
            '\n' => try writeAll(out, "\\n"),
            '\r' => try writeAll(out, "\\r"),
            '\t' => try writeAll(out, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try writeAll(out, &buf);
                } else {
                    try writeAll(out, &.{c});
                }
            },
        }
    }
}

fn stdOut() std.fs.File {
    return std.fs.File.stdout();
}

fn stdErr() std.fs.File {
    return std.fs.File.stderr();
}

fn writeAll(file: std.fs.File, bytes: []const u8) !void {
    file.writeAll(bytes) catch |err| {
        if (err == error.BrokenPipe) std.process.exit(0);
        return err;
    };
}

fn printError(err: anyerror) void {
    const msg: []const u8 = switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.MissingCommand => "missing command, use --help for usage",
        error.UnknownCommand => "unknown command, use --help for usage",
        error.MissingArgument => "missing required argument",
        error.MissingFile => "missing file argument",
        else => @errorName(err),
    };
    std.fs.File.stderr().writeAll("md: ") catch {};
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
}
