const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("md", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "md",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "md", .module = lib_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Install man page
    b.installFile("doc/md.1", "share/man/man1/md.1");

    // Install shell completions
    b.installFile("completions/md.bash", "share/bash-completion/completions/md");
    b.installFile("completions/md.zsh", "share/zsh/site-functions/_md");
    b.installFile("completions/md.fish", "share/fish/vendor_completions.d/md.fish");

    const run_step = b.step("run", "Run md");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
