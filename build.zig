const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "additional filters") orelse &.{};

    const ws_module = b.addModule("weebsocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const autobahn_client_module = b.addModule("autobahn_client", .{
        .root_source_file = b.path("autobahn/client_test/src/autobahn_client.zig"),
        .imports = &.{.{ .name = "weebsocket", .module = ws_module }},
        .target = target,
        .optimize = optimize,
    });

    const test_compile_step = b.addTest(.{ .root_module = ws_module, .filters = test_filters, .use_llvm = true });

    const autobahn_client_compile_step = b.addExecutable(.{ .name = "weebsocket", .root_module = autobahn_client_module, .use_llvm = true });

    // zig build example
    //const example_step = b.step("example", "Build the example shown in the README");
    //const example_module = b.createModule(.{
    //    .root_source_file = b.path("./examples/example_from_readme.zig"),
    //    .optimize = .Debug,
    //    .target = target,
    //    .imports = &.{.{ .name = "weebsocket", .module = ws_module }},
    //});
    //const example_exe = b.addExecutable(.{ .name = "example", .root_module = example_module, .use_llvm = false });
    //const example_artifact = b.addInstallArtifact(example_exe, .{});
    //example_step.dependOn(&example_artifact.step);

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

    const test_compile_check_step = b.addTest(.{ .name = "check-test", .root_module = ws_module });
    const autobahn_client_compile_check_step = b.addExecutable(.{ .name = "autobahn-check", .root_module = autobahn_client_module });
    check_step.dependOn(&test_compile_check_step.step);
    check_step.dependOn(&autobahn_client_compile_check_step.step);
}
