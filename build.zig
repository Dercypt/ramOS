const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{
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
}
