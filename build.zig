const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const zgraphql_module = b.addModule("zgraphql", .{
        .root_source_file = b.path("src/zgraphql.zig"),
    });

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zgraphql.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Compile-all probe: force semantic analysis of every public function so
    // dead-code regressions (uncalled pub fns with compile errors) are caught.
    // Compiled as an object (not run) — the comptime block takes each pub
    // function's address, forcing its body to be type-checked.
    const compile_all_step = b.step("compile-all", "Force-compile every public API");
    const compile_all_obj = b.addObject(.{
        .name = "compile_all",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compile_all_step.dependOn(&compile_all_obj.step);
    // Also compile the probe as part of `zig build test` so local test runs
    // catch dead-code regressions too.
    test_step.dependOn(&compile_all_obj.step);

    // Integration tests
    const integration_test_step = b.step("integration-test", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("zgraphql", zgraphql_module);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Examples
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "basic", .path = "examples/basic.zig" },
        .{ .name = "server", .path = "examples/server.zig" },
        .{ .name = "subscription", .path = "examples/subscription.zig" },
        .{ .name = "dataloader", .path = "examples/dataloader.zig" },
        .{ .name = "typesafe", .path = "examples/typesafe.zig" },
        .{ .name = "distributed-cache", .path = "examples/distributed_cache.zig" },
        .{ .name = "tenant", .path = "examples/tenant.zig" },
        .{ .name = "database", .path = "examples/database.zig" },
        .{ .name = "complex", .path = "examples/complex.zig" },
        .{ .name = "benchmark", .path = "bench/benchmark.zig" },
    };

    const examples_step = b.step("examples", "Build all examples");

    inline for (examples) |example| {
        const exe_module = b.createModule(.{
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        exe_module.addImport("zgraphql", zgraphql_module);

        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = exe_module,
        });

        b.installArtifact(exe);
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(
            b.fmt("run-{s}", .{example.name}),
            b.fmt("Run the {s} example", .{example.name}),
        );
        run_step.dependOn(&run_cmd.step);
    }

    // Fuzz targets
    const fuzz_parser_exe = b.addExecutable(.{
        .name = "parser-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/parser_fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_parser_exe.root_module.addImport("zgraphql", zgraphql_module);
    b.installArtifact(fuzz_parser_exe);

    const fuzz_json_exe = b.addExecutable(.{
        .name = "json-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/json_fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz_json_exe.root_module.addImport("zgraphql", zgraphql_module);
    b.installArtifact(fuzz_json_exe);

    const run_parser_fuzz = b.addRunArtifact(fuzz_parser_exe);
    const fuzz_parser_step = b.step("run-parser-fuzz", "Run parser fuzz test");
    fuzz_parser_step.dependOn(&run_parser_fuzz.step);

    const run_json_fuzz = b.addRunArtifact(fuzz_json_exe);
    const fuzz_json_step = b.step("run-json-fuzz", "Run JSON fuzz test");
    fuzz_json_step.dependOn(&run_json_fuzz.step);

    // Stress test
    const stress_exe = b.addExecutable(.{
        .name = "stress-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/stress_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stress_exe.root_module.addImport("zgraphql", zgraphql_module);
    b.installArtifact(stress_exe);

    const run_stress = b.addRunArtifact(stress_exe);
    const stress_step = b.step("run-stress-test", "Run long-running stress test");
    stress_step.dependOn(&run_stress.step);
}
