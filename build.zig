const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Export the module
    // -------------------------------------------------------------------------
    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/pubsub.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -------------------------------------------------------------------------
    // Demo app
    // -------------------------------------------------------------------------
    const thread_exe = b.addExecutable(.{
        .name = "demo_threads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_threads.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
            },
        }),
    });

    b.installArtifact(thread_exe);

    const run_step = b.step("demo_threads", "Run the demo app using threads");

    const run_cmd = b.addRunArtifact(thread_exe);
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // Demo app using fibers and evented IO
    // -------------------------------------------------------------------------

    const fiber_exe = b.addExecutable(.{
        .name = "demo_fibers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo_fibers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
            },
        }),
    });

    // b.installArtifact(fiber_exe);

    const run_fiber_step = b.step("demo_fibers", "Run the demo app using fibers");

    const run_fiber_cmd = b.addRunArtifact(fiber_exe);
    run_fiber_step.dependOn(&run_fiber_cmd.step);

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
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
            },
        }),
    });

    const run_standalone_tests = b.addRunArtifact(standalone_tests);
    test_step.dependOn(&run_standalone_tests.step);
}
