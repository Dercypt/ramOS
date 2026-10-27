# ramOS

A specialized bare-metal operating system for AArch64 where physical RAM is the sole storage and execution tier.

ramOS eliminates secondary storage swap, per-process page tables, and hardware context-switch latency by combining:
1. **Single Flat 64-bit Address Space:** All tasks and kernel modules share the Limine Higher-Half Direct Map (HHDM) with zero hardware translation table swaps (`TTBR0_EL1`) or TLB flushes.
2. **In-RAM Zstandard Compression Ring:** Cold physical frames are synchronously compressed into an in-memory slab pool when memory pressure reaches critical watermarks.
3. **Software-Enforced Memory Safety:** Isolation and memory bounds are guaranteed entirely at the language level by Zig's compile-time types and `ReleaseSafe` runtime slice bounds checking.
4. **No Storage Fallbacks:** Absolutely no disk or block storage drivers for swapping.

---

## Toolchain & Requirements

The following toolchain versions and host utilities are required to build and run ramOS:

| Tool | Recommended / Minimum Version | Purpose |
| :--- | :--- | :--- |
| **Zig** | `0.13.0` | Kernel compiler and unit test harness |
| **QEMU** | `>= 7.0` (`qemu-system-aarch64`) | AArch64 `virt` board virtualization |
| **xorriso** | `>= 1.5.0` | Writes El Torito UEFI boot headers for `image.iso` |
| **curl** | Standard system curl | Automatically fetches Limine UEFI binaries and `QEMU_EFI.fd` |
| **bash** | `>= 3.2` | Orchestrates the build and verification harness |

> [!IMPORTANT]
> macOS includes `hdiutil makehybrid`, but `hdiutil` **does not** write El Torito UEFI boot headers. While `scripts/build_iso.sh` can fall back to `hdiutil` for staging validation, `xorriso` (`brew install xorriso`) is strictly required to create ISOs that boot in QEMU.

### Installation

#### macOS (Homebrew)
```bash
brew install zig qemu xorriso
```

#### Ubuntu / Debian
```bash
sudo apt update
sudo apt install -y curl xorriso qemu-system-arm qemu-efi-aarch64
# Ensure Zig 0.13.0 is installed from https://ziglang.org/download/
```

---

## Building

Build tasks are managed via Zig's build system and helper scripts:

```bash
# Build the AArch64 kernel in ReleaseSafe mode (outputs zig-out/bin/kernel.elf)
zig build kernel

# Assemble the bootable Limine UEFI ISO image (outputs image.iso)
zig build iso

# Launch the kernel inside QEMU with Limine UEFI firmware
zig build run
```

Firmware binaries (`boot/limine/BOOTAA64.EFI`, `boot/limine/limine-uefi-cd.bin`, and `QEMU_EFI.fd`) are automatically downloaded via `scripts/build_iso.sh` on demand if not present locally.

---

## Testing & Verification

ramOS uses a strict architectural governance harness to guarantee all domain laws remain intact:

```bash
# Run the complete verification pipeline (formatting, ReleaseSafe build, all law invariant tests, and ISO build)
./verify.sh

# Run verification pipeline and launch kernel in QEMU upon passing
./verify.sh --qemu
# Alternatively:
RUN_QEMU=1 ./verify.sh

# Run Zig unit test suites (slab allocator, zstd compression, compression ring, task switcher)
zig build test
```

### Invariant Test Suite (`tests/laws/`)
- `test_compression_ring.sh`: Validates circular ring buffer, scratch arena safety, and watermark eviction loops.
- `test_flat_address_space.sh`: Verifies single flat address space and register-only cooperative context switching without TTBR0 swaps or TLB invalidations.
- `test_memory_residency.sh`: Asserts strict in-RAM residency and memory discovery.
- `test_no_disk_drivers.sh`: Scans codebase for illegal secondary storage or block device driver implementations.
- `test_slab_allocator.sh`: Enforces bounded slab pools and fixed scratch context sizes.
- `test_software_isolation.sh`: Verifies slice-based bounds checking for key kernel tables.
- `test_zstd_compression.sh`: Tests compression engine correctness, roundtrip fidelity, and high-entropy error handling.

---

## Architecture & Governance

- [LAWS.md](LAWS.md): The four non-negotiable architectural laws of ramOS.
- [PRINCIPLES.md](PRINCIPLES.md): Defaults, memory invariants, and architectural escalation triggers.
- [DESIGN.md](DESIGN.md): Architectural specification, memory topology, page lifecycle state machine, and scheduling models.
- [HARNESS.md](HARNESS.md): Governance harness specification.
- [AGENTS.md](AGENTS.md): Operational directives for AI agents modifying this repository.

---

## License

This project is licensed under the [MIT License](LICENSE).
