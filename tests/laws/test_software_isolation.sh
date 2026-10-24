#!/usr/bin/env bash
set -e

# Invariant Test: Law of Software-Enforced Isolation (LAWS.md:7)
# Memory safety, task isolation, and access control must be guaranteed entirely by
# Zig's compile-time semantics and runtime safety checks (ReleaseSafe).
# Key tables (bitmap, frame_table, slots, entries) must be stored as bounded slices ([]T)
# rather than multi-item pointers ([*]T) to prevent silent buffer overruns.

# 1. PhysicalMemoryManager bitmap and frame_table must be slices
if grep -q "bitmap: \[\*\]u8" src/memory.zig; then
    echo "ERROR: PhysicalMemoryManager.bitmap must not be a multi-item pointer ([*]u8)."
    exit 1
fi

if ! grep -q "bitmap: \[\]u8" src/memory.zig; then
    echo "ERROR: PhysicalMemoryManager.bitmap must be a slice ([]u8) for bounds checking."
    exit 1
fi

if grep -q "frame_table: \[\*\]FrameMeta" src/memory.zig; then
    echo "ERROR: PhysicalMemoryManager.frame_table must not be a multi-item pointer ([*]FrameMeta)."
    exit 1
fi

if ! grep -q "frame_table: \[\]FrameMeta" src/memory.zig; then
    echo "ERROR: PhysicalMemoryManager.frame_table must be a slice ([]FrameMeta) for bounds checking."
    exit 1
fi

# 2. CompressionRing slots must be a slice
if grep -q "slots: \[\*\]RingSlot" src/ring.zig; then
    echo "ERROR: CompressionRing.slots must not be a multi-item pointer ([*]RingSlot)."
    exit 1
fi

if ! grep -q "slots: \[\]RingSlot" src/ring.zig; then
    echo "ERROR: CompressionRing.slots must be a slice ([]RingSlot) for bounds checking."
    exit 1
fi

# 3. PageHandleManager entries must be a slice
if grep -q "entries: \[\*\]HandleEntry" src/slab.zig; then
    echo "ERROR: PageHandleManager.entries must not be a multi-item pointer ([*]HandleEntry)."
    exit 1
fi

if ! grep -q "entries: \[\]HandleEntry" src/slab.zig; then
    echo "ERROR: PageHandleManager.entries must be a slice ([]HandleEntry) for bounds checking."
    exit 1
fi

echo "OK: Software-enforced isolation slice bounds invariants verified in memory, ring, and slab."
exit 0
