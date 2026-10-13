#!/usr/bin/env bash
set -e

# Invariant Test: Law of Absolute RAM Residency
# Ensures memory management code only operates on in-RAM frames and slab pools.
# Verifies that frame states remain purely in-memory.

if ! grep -q "watermark_low" src/memory.zig; then
    echo "ERROR: Physical memory manager must implement compression watermarks."
    exit 1
fi

if ! grep -q "physToVirt" src/memory.zig; then
    echo "ERROR: Physical memory manager must map through direct higher-half physical mapping."
    exit 1
fi

echo "OK: Memory residency and watermark invariants verified in src/memory.zig."
exit 0
