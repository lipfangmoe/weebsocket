const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const ws_module = b.addModule("weebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_compile_step = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const autobahn_client_compile_step = b.addExecutable(.{
        .name = "weebsocket",
        .root_source_file = b.path("autobahn/client_test/src/autobahn_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    autobahn_client_compile_step.root_module.addImport("weebsocket", ws_module);

    // zig build test
    const test_step = b.step("test", "Run unit tests");
    const run_lib_unit_tests = b.addRunArtifact(test_compile_step);
    test_step.dependOn(&run_lib_unit_tests.step);

    // zig build autobahn-client
    const run_autobahn_client = b.addRunArtifact(autobahn_client_compile_step);
    const autobahn_test_client_step = b.step("autobahn-client-test", "Run Autobahn Client Tests");
    autobahn_test_client_step.dependOn(&run_autobahn_client.step);

    // zig build check
    const check_step = b.step("check", "Run the compiler without building");
    check_step.dependOn(&test_compile_step.step);
    check_step.dependOn(&autobahn_client_compile_step.step);
}
