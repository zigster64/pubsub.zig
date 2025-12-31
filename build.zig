const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "pubsub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // TEST CONFIGURATION
    // -------------------------------------------------------------------------
    const test_step = b.step("test", "Run all tests");

    // A. Run tests inside the module itself (if any inline tests exist)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // B. Run the standalone 'tests.zig' file we created
    // We need to give it access to the 'pubsub' module so it can import it
    const standalone_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // This allows @import("pubsub.zig") inside tests.zig to work
    // Or simpler: tests.zig just uses @import("pubsub.zig") relative path
    // forcing the test runner to know about the file mapping isn't strictly necessary
    // if they are in the same folder, but adding the module is cleaner:
    standalone_tests.root_module.addImport("pubsub_module", mod);

    const run_standalone_tests = b.addRunArtifact(standalone_tests);
    test_step.dependOn(&run_standalone_tests.step);
}
