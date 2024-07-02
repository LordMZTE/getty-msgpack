const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const getty_mod = b.dependency("getty", .{
        .target = target,
        .optimize = optimize,
    }).module("getty");

    const root_src = b.path("src/main.zig");

    _ = b.addModule("getty-msgpack", .{
        .root_source_file = root_src,
        .imports = &.{.{
            .name = "getty",
            .module = getty_mod,
        }},
    });

    const test_exe = b.addTest(.{
        .root_source_file = root_src,
        .target = target,
        .optimize = optimize,
    });

    test_exe.root_module.addImport("getty", getty_mod);

    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
