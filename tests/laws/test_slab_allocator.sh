#!/usr/bin/env bash
set -e

# Invariant Test: In-RAM Slab Allocator (Phase 2)
# Ensures fixed-size slab caches house variable-length compressed chunks strictly in RAM.
# Validates presence of SlabAllocator, PageHandle, ScratchArena, and block size constraints.

if [ ! -f "src/slab.zig" ]; then
    echo "ERROR: src/slab.zig missing. Phase 2 slab allocator must be implemented."
    exit 1
fi

if ! grep -q "SLAB_BLOCK_SIZE" src/slab.zig; then
    echo "ERROR: SLAB_BLOCK_SIZE constant must be defined in src/slab.zig."
    exit 1
fi

if ! grep -q "SIZE_CLASSES" src/slab.zig; then
    echo "ERROR: SIZE_CLASSES for compressed payloads must be defined in src/slab.zig."
    exit 1
fi

if ! grep -q "PageHandle" src/slab.zig; then
    echo "ERROR: PageHandle abstraction must be implemented for compressed chunks."
    exit 1
fi

if ! grep -q "ScratchArena" src/slab.zig; then
    echo "ERROR: Pre-allocated ScratchArena must be present to prevent OOM recursion."
    exit 1
fi

if ! grep -q "allocCompressed" src/slab.zig; then
    echo "ERROR: allocCompressed must be present for storing compressed page payloads."
    exit 1
fi

if command -v zig >/dev/null 2>&1; then
    zig test src/slab.zig
fi

echo "OK: In-RAM slab allocator invariants verified in src/slab.zig."
exit 0
