const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zig_cli_module = b.addModule("zig-cli", .{
        .source_file = std.Build.FileSource.relative("deps/zig-cli/src/main.zig"),
    });

    const zig_cli = b.addStaticLibrary(.{
        .name = "zig-cli",
        .root_source_file = .{ .path = "deps/zig-cli/src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zig_cli);

    const rem_module = b.addModule("rem", .{
        .source_file = std.Build.FileSource.relative("deps/rem/rem.zig"),
    });

    const rem = b.addStaticLibrary(.{
        .name = "rem",
        .root_source_file = .{ .path = "deps/rem/rem.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(rem);

    const exe = b.addExecutable(.{
        .name = "zanga",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zig-cli", zig_cli_module);
    exe.addModule("rem", rem_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
