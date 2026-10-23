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

    const iso_cmd = b.addSystemCommand(&.{
        "/bin/bash",
        "scripts/build_iso.sh",
    });
    iso_cmd.step.dependOn(kernel_step);

    const iso_step = b.step("iso", "Assemble bootable ISO image with Limine UEFI and kernel");
    iso_step.dependOn(&iso_cmd.step);

    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt",
        "-cpu",
        "cortex-a57",
        "-display",
        "none",
        "-serial",
        "stdio",
        "-bios",
        "QEMU_EFI.fd",
        "-cdrom",
        "image.iso",
    });
    run_cmd.step.dependOn(iso_step);

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&run_cmd.step);

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

    const task_tests = b.addTest(.{
        .root_source_file = b.path("src/task.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });

    const run_task_tests = b.addRunArtifact(task_tests);

    const memory_tests = b.addTest(.{
        .root_source_file = b.path("src/memory.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = optimize,
    });

    const run_memory_tests = b.addRunArtifact(memory_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_slab_tests.step);
    test_step.dependOn(&run_zstd_tests.step);
    test_step.dependOn(&run_ring_tests.step);
    test_step.dependOn(&run_task_tests.step);
    test_step.dependOn(&run_memory_tests.step);
}
