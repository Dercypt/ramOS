const limine = @import("limine.zig");
const memory = @import("memory.zig");

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

    hang();
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
