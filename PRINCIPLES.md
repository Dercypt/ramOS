# ramOS Principles

### Defaults
- Variables must be immutable (`const`) by default.
- Memory allocations must be statically bounded where possible. Dynamic allocations must strictly fall back to the frame allocator and Zstd-backed slab pool.
- Build mode should default to `ReleaseSafe` to enforce Zig's runtime safety checks, acting as the primary isolation layer.

### Escalation Triggers
Any of the following actions require explicit architectural review:
- **Dependencies:** Introducing any external dependency beyond the Zstandard compression engine and the Limine bootloader protocol headers.
- **Unsafe Code:** Usage of `@ptrCast`, `@intToPtr`, or `asm` blocks outside of hardware initialization (Limine boot handoff, UART setup, early AArch64 exception vectors) and the core compression ring buffer.
- **Public API:** Any addition to the system call interface or core memory management API must be reviewed against the *Law of Absolute RAM Residency*.
