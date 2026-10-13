const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .large,
    });

    kernel.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(kernel);

    const kernel_step = b.step("kernel", "Build the ramOS AArch64 kernel");
    kernel_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const slab_tests = b.addTest(.{
        .root_source_file = b.path("src/slab.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });

    const run_slab_tests = b.addRunArtifact(slab_tests);

    const zstd_tests = b.addTest(.{
        .root_source_file = b.path("src/zstd.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });

    const run_zstd_tests = b.addRunArtifact(zstd_tests);

    const ring_tests = b.addTest(.{
        .root_source_file = b.path("src/ring.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });

    const run_ring_tests = b.addRunArtifact(ring_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_slab_tests.step);
    test_step.dependOn(&run_zstd_tests.step);
    test_step.dependOn(&run_ring_tests.step);
}
