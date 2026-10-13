const limine = @import("limine.zig");
const memory = @import("memory.zig");
const zstd = @import("zstd.zig");

// Limine base revision declaration
export var base_revision: limine.BaseRevision linksection(".requests") = .{};

// Request Higher-Half Direct Map (HHDM)
export var hhdm_request: limine.HhdmRequest linksection(".requests") = .{};

// Request Physical Memory Map
export var mmap_request: limine.MemoryMapRequest linksection(".requests") = .{};

// Minimal QEMU 'virt' UART PL011 physical address: 0x09000000
const QEMU_UART_PHYS_BASE: u64 = 0x09000000;

fn getUartAddress() ?[*]volatile u8 {
    if (hhdm_request.response) |resp| {
        // Higher-half direct physical memory mapping
        const virt_addr = resp.offset + QEMU_UART_PHYS_BASE;
        return @ptrFromInt(virt_addr);
    }
    return null;
}

pub fn uartPrint(msg: []const u8) void {
    if (getUartAddress()) |uart| {
        for (msg) |c| {
            uart[0] = c;
        }
    }
}

pub fn uartPrintU64(val: u64) void {
    var buf: [21]u8 = undefined;
    var v = val;
    var i: usize = buf.len;

    if (v == 0) {
        uartPrint("0");
        return;
    }

    while (v > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    uartPrint(buf[i..]);
}

export fn _start() callconv(.C) noreturn {
    // Verify Limine base revision
    if (!base_revision.isSupported()) {
        hang();
    }

    uartPrint("\r\n[ramOS] Booting AArch64 kernel with Limine HHDM...\r\n");
    uartPrint("[ramOS] Single Flat Address Space initialized (Zero TLB flushes).\r\n");

    const hhdm = hhdm_request.response orelse hang();
    const mmap = mmap_request.response orelse hang();

    uartPrint("[ramOS] Initializing Physical Frame Allocator (Phase 1)...\r\n");
    memory.global_pmm.init(hhdm.offset, mmap);

    uartPrint("[ramOS] Total Tracked Frames: ");
    uartPrintU64(memory.global_pmm.total_frames);
    uartPrint(" | Free Frames: ");
    uartPrintU64(memory.global_pmm.free_frames);
    uartPrint("\r\n");

    uartPrint("[ramOS] Compression Low Watermark: ");
    uartPrintU64(memory.global_pmm.watermark_low);
    uartPrint(" frames\r\n");

    uartPrint("[ramOS] Phase 1 initialization complete. Kernel operational.\r\n");

    uartPrint("[ramOS] Initializing In-RAM Slab Allocator (Phase 2)...\r\n");
    memory.slab.global_slab.init(&memory.global_pmm);

    uartPrint("[ramOS] Slab Caches configured: 7 size classes (64B to 4096B).\r\n");
    uartPrint("[ramOS] Pre-allocated Zstd Scratch Arena: ");
    uartPrintU64(memory.slab.global_slab.scratch_arena.size / 1024);
    uartPrint(" KiB\r\n");
    uartPrint("[ramOS] Page Handle Pool capacity: ");
    uartPrintU64(memory.slab.global_slab.handle_mgr.max_handles);
    uartPrint(" handles\r\n");

    uartPrint("[ramOS] Running In-RAM Slab Allocator self-tests...\r\n");
    testSlabAllocator();
    uartPrint("[ramOS] Slab Allocator self-tests passed successfully.\r\n");

    uartPrint("[ramOS] Phase 2 initialization complete. In-RAM Slab Pool operational.\r\n");

    uartPrint("[ramOS] Initializing bare-metal Zstandard Compression Engine (Phase 3)...\r\n");
    uartPrint("[ramOS] Zstd Static CCtx initialized: ");
    uartPrintU64(zstd.ZSTD_estimateCCtxSize(1) / 1024);
    uartPrint(" KiB static workspace\r\n");
    uartPrint("[ramOS] Zstd Static DCtx initialized: ");
    uartPrintU64(zstd.ZSTD_estimateDCtxSize() / 1024);
    uartPrint(" KiB static workspace\r\n");

    uartPrint("[ramOS] Running Zstandard Compression Engine self-tests...\r\n");
    testZstdCompression();
    uartPrint("[ramOS] Zstandard Compression self-tests passed successfully.\r\n");

    uartPrint("[ramOS] Phase 3 initialization complete. Bare-metal Zstd engine operational.\r\n");

    hang();
}

fn testZstdCompression() void {
    // 1. Test compression of a 4096-byte zeroed frame into slab pool
    var zero_page: [memory.PAGE_SIZE]u8 = undefined;
    @memset(&zero_page, 0);

    const zero_handle = memory.slab.global_slab.compressAndStore(&zero_page) orelse @panic("Failed to compress zeroed frame");
    if (!zero_handle.isValid()) @panic("Invalid zeroed page handle");

    const zero_comp_slice = memory.slab.global_slab.getCompressed(zero_handle) orelse @panic("Failed to get compressed zero slice");
    // Verify RLE frame is 11 bytes (compression ratio ~372x)
    if (zero_comp_slice.len != 11) @panic("Unexpected compressed size for zeroed page");

    var decomp_page: [memory.PAGE_SIZE]u8 = undefined;
    const decomp_len = memory.slab.global_slab.decompressToFrame(zero_handle, &decomp_page) catch @panic("Failed to decompress zeroed frame");
    if (decomp_len != memory.PAGE_SIZE) @panic("Decompressed zero frame length mismatch");

    for (decomp_page) |b| {
        if (b != 0) @panic("Decompressed zero frame content corrupted");
    }
    memory.slab.global_slab.freeCompressed(zero_handle);

    // 2. Test compression and decompression of a patterned frame
    var pattern_page: [memory.PAGE_SIZE]u8 = undefined;
    @memset(pattern_page[0..1000], 'R');
    @memset(pattern_page[1000..3000], 0);
    @memcpy(pattern_page[3000..3023], "ramOS Zstandard Phase 3");
    @memset(pattern_page[3023..4096], 'Z');

    const pat_handle = memory.slab.global_slab.compressAndStore(&pattern_page) orelse @panic("Failed to compress pattern frame");
    const pat_comp_slice = memory.slab.global_slab.getCompressed(pat_handle) orelse @panic("Failed to get pattern slice");
    if (pat_comp_slice.len >= memory.PAGE_SIZE) @panic("Pattern frame failed to achieve compression");

    const pat_decomp_len = memory.slab.global_slab.decompressToFrame(pat_handle, &decomp_page) catch @panic("Failed to decompress pattern frame");
    if (pat_decomp_len != memory.PAGE_SIZE) @panic("Decompressed pattern length mismatch");

    for (pattern_page, 0..) |expected_byte, i| {
        if (decomp_page[i] != expected_byte) @panic("Decompressed pattern content mismatch");
    }
    memory.slab.global_slab.freeCompressed(pat_handle);

    // 3. Test direct ZSTD C-compatible API with static contexts
    const cctx = memory.slab.global_slab.cctx orelse @panic("CCtx not initialized");
    const dctx = memory.slab.global_slab.dctx orelse @panic("DCtx not initialized");

    const test_str = "ramOS flat address space with bare-metal Zstandard compression engine.";
    var comp_direct: [128]u8 = undefined;
    const comp_direct_len = zstd.ZSTD_compressCCtx(cctx, &comp_direct, test_str, 1) catch @panic("ZSTD_compressCCtx failed");

    var decomp_direct: [128]u8 = undefined;
    const decomp_direct_len = zstd.ZSTD_decompressDCtx(dctx, &decomp_direct, comp_direct[0..comp_direct_len]) catch @panic("ZSTD_decompressDCtx failed");
    if (decomp_direct_len != test_str.len) @panic("Direct decompressed length mismatch");

    for (test_str, 0..) |expected, i| {
        if (decomp_direct[i] != expected) @panic("Direct decompressed content mismatch");
    }

    // 4. Test frame table integration with compressed handle
    const frame_phys = memory.global_pmm.allocFrame() orelse @panic("Failed to alloc physical frame");
    const frame_idx = frame_phys / memory.PAGE_SIZE;
    const meta_handle = memory.slab.global_slab.compressAndStore(&zero_page) orelse @panic("Failed to compress for frame meta");
    memory.global_pmm.frame_table[frame_idx].setCompressed(meta_handle);

    if (!memory.global_pmm.frame_table[frame_idx].isCompressed()) @panic("FrameMeta not marked as compressed");
    if (memory.global_pmm.frame_table[frame_idx].getCompressedHandle().id != meta_handle.id) @panic("FrameMeta handle mismatch");

    memory.slab.global_slab.freeCompressed(meta_handle);
    memory.global_pmm.freeFrame(frame_phys);
}

fn testSlabAllocator() void {
    // 1. Test raw slab allocation and freeing across size classes
    const ptr64 = memory.slab.global_slab.alloc(48) orelse @panic("Failed to allocate 48 bytes from slab");
    ptr64[0] = 0xAA;
    ptr64[47] = 0xBB;
    if (ptr64[0] != 0xAA or ptr64[47] != 0xBB) @panic("Slab memory corruption");
    memory.slab.global_slab.free(ptr64);

    const ptr1024 = memory.slab.global_slab.alloc(1000) orelse @panic("Failed to allocate 1000 bytes from slab");
    ptr1024[0] = 0x12;
    ptr1024[999] = 0x34;
    if (ptr1024[0] != 0x12 or ptr1024[999] != 0x34) @panic("Slab memory corruption");
    memory.slab.global_slab.free(ptr1024);

    // 2. Test compressed page storage and retrieval with PageHandle
    const dummy_payload = "ramOS compressed page test payload for Phase 2 slab verification.";
    const handle = memory.slab.global_slab.allocCompressed(dummy_payload) orelse @panic("Failed to allocate compressed payload handle");
    if (!handle.isValid()) @panic("Invalid compressed page handle");

    const retrieved = memory.slab.global_slab.getCompressed(handle) orelse @panic("Failed to retrieve compressed slice");
    if (retrieved.len != dummy_payload.len) @panic("Retrieved slice length mismatch");

    for (dummy_payload, 0..) |expected_byte, i| {
        if (retrieved[i] != expected_byte) @panic("Compressed payload content mismatch");
    }

    // 3. Test association with FrameMeta
    const frame_phys = memory.global_pmm.allocFrame() orelse @panic("Failed to alloc physical frame for test");
    const frame_idx = frame_phys / memory.PAGE_SIZE;
    memory.global_pmm.frame_table[frame_idx].setCompressed(handle);
    if (!memory.global_pmm.frame_table[frame_idx].isCompressed()) @panic("Frame state not marked as compressed");
    if (memory.global_pmm.frame_table[frame_idx].getCompressedHandle().id != handle.id) @panic("Frame handle mismatch");

    // Clean up
    memory.slab.global_slab.freeCompressed(handle);
    memory.global_pmm.freeFrame(frame_phys);
}

fn hang() noreturn {
    while (true) {
        asm volatile ("wfe");
    }
}
