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

    hang();
}

fn hang() noreturn {
    while (true) {
        asm volatile ("wfe");
    }
}
