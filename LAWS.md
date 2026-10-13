# ramOS Laws

These are the non-negotiable domain invariants that define the core architecture of ramOS:

1. **Law of Absolute RAM Residency:** The kernel must never page memory out to secondary storage (no disk swap). All allocations, active or cold, must reside strictly in physical RAM.
2. **Law of the Single Flat Space:** All tasks and kernel modules must share a single, unified 64-bit address space. Hardware context switching (e.g., swapping TTBR0_EL1 on AArch64) is strictly prohibited to eliminate TLB flush latency.
3. **Law of Software-Enforced Isolation:** Memory safety, task isolation, and access control must be guaranteed entirely by Zig's compile-time semantics and runtime safety checks (`ReleaseSafe`), completely bypassing hardware MMU protection rings for user isolation.
4. **Law of Synchronous In-Memory Compression:** The frame allocator must synchronously compress least-recently-used (cold) pages into the in-RAM compressed slab pool (via Zstandard) when free physical frames drop below the critical low-water mark.
