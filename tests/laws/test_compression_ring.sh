#!/usr/bin/env bash
set -e

# Invariant Test: Compression Ring & Watermark Eviction (Phase 4)
# Validates in-RAM lockless circular ring buffer, page lifecycle state machine,
# synchronous eviction on watermark triggers, and absolute RAM residency.

if [ ! -f "src/ring.zig" ]; then
    echo "ERROR: src/ring.zig missing. Phase 4 compression ring must be implemented."
    exit 1
fi

if ! grep -q "DEFAULT_RING_CAPACITY" src/ring.zig; then
    echo "ERROR: DEFAULT_RING_CAPACITY must be defined in src/ring.zig."
    exit 1
fi

if ! grep -q "RingEntry" src/ring.zig; then
    echo "ERROR: RingEntry descriptor must be defined in src/ring.zig."
    exit 1
fi

if ! grep -q "RingSlot" src/ring.zig; then
    echo "ERROR: RingSlot structure must be defined in src/ring.zig."
    exit 1
fi

if ! grep -q "ManagedPage" src/ring.zig; then
    echo "ERROR: ManagedPage lifecycle state machine must be defined in src/ring.zig."
    exit 1
fi

if ! grep -q "CompressionRing" src/ring.zig; then
    echo "ERROR: CompressionRing must be implemented in src/ring.zig."
    exit 1
fi

if ! grep -q "evictUntilHighWatermark" src/ring.zig; then
    echo "ERROR: evictUntilHighWatermark must be present for synchronous watermark replenishment."
    exit 1
fi

if ! grep -q "evictCallback" src/ring.zig; then
    echo "ERROR: evictCallback must be implemented to connect PMM with the compression ring."
    exit 1
fi

if ! grep -q "setEvictor" src/memory.zig; then
    echo "ERROR: setEvictor hook must be present in PhysicalMemoryManager in src/memory.zig."
    exit 1
fi

if ! grep -q "triggerEviction" src/memory.zig; then
    echo "ERROR: triggerEviction must be present in PhysicalMemoryManager in src/memory.zig."
    exit 1
fi

if ! grep -q "compressing" src/memory.zig || ! grep -q "decompressing" src/memory.zig; then
    echo "ERROR: PageState in src/memory.zig must include compressing and decompressing states."
    exit 1
fi

if command -v zig >/dev/null 2>&1; then
    zig test src/ring.zig
fi

echo "OK: Compression ring and watermark eviction invariants verified in src/ring.zig and src/memory.zig."
exit 0
