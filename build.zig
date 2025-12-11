const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("clap", b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap"));

    exe_mod.addImport("pcm", b.dependency("pcm", .{
        .target = target,
        .optimize = optimize,
    }).module("pcm"));

    const exe = b.addExecutable(.{
        .name = "wavels",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addExecutable(.{
        .name = exe.name,
        .root_module = exe.root_module,
    });
    const check = b.step("check", "Check if the program compiles");
    check.dependOn(&check_exe.step);

    const run_unit_tests = b.addRunArtifact(b.addTest(.{
        .root_module = exe_mod,
    }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
