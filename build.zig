const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("dweebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_compile_step = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zig build test
    const test_step = b.step("test", "Run unit tests");
    const run_lib_unit_tests = b.addRunArtifact(test_compile_step);
    test_step.dependOn(&run_lib_unit_tests.step);

    // zig build check
    const check_step = b.step("check", "Run the compiler without building");
    check_step.dependOn(&test_compile_step.step);
}
