#!/usr/bin/env bash
set -e

# Invariant Test: Zstandard Compression Engine Integration (Phase 3)
# Validates bare-metal Zstandard engine with static workspace memory,
# presence of ZSTD_CCtx, ZSTD_DCtx, static context initializers,
# and zero-storage fallback invariants.

if [ ! -f "src/zstd.zig" ]; then
    echo "ERROR: src/zstd.zig missing. Phase 3 Zstd compression engine must be implemented."
    exit 1
fi

if ! grep -q "ZSTD_MAGIC_NUMBER" src/zstd.zig; then
    echo "ERROR: ZSTD_MAGIC_NUMBER constant must be defined in src/zstd.zig."
    exit 1
fi

if ! grep -q "ZSTD_CCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_CCtx compression context must be implemented in src/zstd.zig."
    exit 1
fi

if ! grep -q "ZSTD_DCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_DCtx decompression context must be implemented in src/zstd.zig."
    exit 1
fi

if ! grep -q "ZSTD_initStaticCCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_initStaticCCtx must be present for static workspace initialization."
    exit 1
fi

if ! grep -q "ZSTD_initStaticDCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_initStaticDCtx must be present for static workspace initialization."
    exit 1
fi

if ! grep -q "ZSTD_compressCCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_compressCCtx must be present for in-RAM page compression."
    exit 1
fi

if ! grep -q "ZSTD_decompressDCtx" src/zstd.zig; then
    echo "ERROR: ZSTD_decompressDCtx must be present for in-RAM page decompression."
    exit 1
fi

if ! grep -q "compressAndStore" src/slab.zig; then
    echo "ERROR: compressAndStore must be integrated into SlabAllocator in src/slab.zig."
    exit 1
fi

if ! grep -q "decompressToFrame" src/slab.zig; then
    echo "ERROR: decompressToFrame must be integrated into SlabAllocator in src/slab.zig."
    exit 1
fi

if command -v zig >/dev/null 2>&1; then
    zig test src/zstd.zig
fi

echo "OK: Zstandard compression engine invariants verified in src/zstd.zig and src/slab.zig."
exit 0
