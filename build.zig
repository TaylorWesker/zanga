const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zig_cli_module = b.dependency("zig-cli", .{});

    const rem_module = b.addModule("rem", .{
        .root_source_file = std.Build.LazyPath.relative("deps/rem/rem.zig"),
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

    exe.root_module.addImport("zig-cli", zig_cli_module.module("zig-cli"));
    exe.root_module.addImport("rem", rem_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
