const limine = @import("limine.zig");

pub const PAGE_SIZE: usize = 4096;

pub const PageState = enum(u8) {
    free = 0,
    active = 1,
    cold = 2,
    compressed = 3,
};

pub const FrameMeta = struct {
    state: PageState = .free,
    ref_count: u32 = 0,
    compressed_handle: u32 = 0, // Points into the Zstd slab pool if compressed
};

pub const PhysicalMemoryManager = struct {
    hhdm_offset: u64 = 0,
    total_frames: usize = 0,
    free_frames: usize = 0,
    watermark_low: usize = 0,
    watermark_high: usize = 0,

    // Bitmap for 4 KiB frame allocation
    bitmap: [*]u8 = undefined,
    bitmap_size_bytes: usize = 0,

    // Frame metadata array
    frame_table: [*]FrameMeta = undefined,
    max_phys_addr: u64 = 0,

    pub fn physToVirt(self: *const PhysicalMemoryManager, phys: u64) [*]u8 {
        return @ptrFromInt(phys + self.hhdm_offset);
    }

    pub fn virtToPhys(self: *const PhysicalMemoryManager, virt: usize) u64 {
        return @as(u64, @intCast(virt)) - self.hhdm_offset;
    }

    pub fn init(
        self: *PhysicalMemoryManager,
        hhdm_offset: u64,
        mmap: *const limine.MemoryMapResponse,
    ) void {
        self.hhdm_offset = hhdm_offset;

        // 1. Determine highest usable physical address
        var highest_addr: u64 = 0;
        var i: usize = 0;
        while (i < mmap.entry_count) : (i += 1) {
            const entry = mmap.entries[i];
            if (entry.type == .usable) {
                const top = entry.base + entry.length;
                if (top > highest_addr) {
                    highest_addr = top;
                }
            }
        }

        self.max_phys_addr = highest_addr;
        self.total_frames = @intCast(highest_addr / PAGE_SIZE);
        self.free_frames = 0;

        // Set compression watermarks (10% low watermark, 20% high watermark)
        self.watermark_low = self.total_frames / 10;
        self.watermark_high = self.total_frames / 5;

        // Calculate size needed for allocation bitmap (1 bit per 4 KiB frame)
        self.bitmap_size_bytes = (self.total_frames + 7) / 8;
        const bitmap_frames_needed = (self.bitmap_size_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

        // Find the first usable entry with enough space to place our bitmap and frame table
        const frame_table_size_bytes = self.total_frames * @sizeOf(FrameMeta);
        const meta_frames_needed = (frame_table_size_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
        const total_reserved_frames = bitmap_frames_needed + meta_frames_needed;

        var reserved_phys: u64 = 0;
        var found_storage = false;

        i = 0;
        while (i < mmap.entry_count) : (i += 1) {
            const entry = mmap.entries[i];
            if (entry.type == .usable and entry.length >= (total_reserved_frames * PAGE_SIZE)) {
                reserved_phys = entry.base;
                found_storage = true;
                break;
            }
        }

        if (!found_storage) {
            @panic("Insufficient contiguous physical memory to allocate frame metadata");
        }

        // Initialize bitmap in the HHDM address space
        self.bitmap = self.physToVirt(reserved_phys);
        // Initially mark all frames as allocated (1 = busy/unavailable)
        @memset(self.bitmap[0..self.bitmap_size_bytes], 0xFF);

        // Frame table is placed immediately after the bitmap
        const frame_table_phys = reserved_phys + (bitmap_frames_needed * PAGE_SIZE);
        self.frame_table = @ptrCast(@alignCast(self.physToVirt(frame_table_phys)));

        // Clear frame table
        var f: usize = 0;
        while (f < self.total_frames) : (f += 1) {
            self.frame_table[f] = .{
                .state = .free,
                .ref_count = 0,
                .compressed_handle = 0,
            };
        }

        // 2. Mark usable regions as free (0 = free)
        i = 0;
        while (i < mmap.entry_count) : (i += 1) {
            const entry = mmap.entries[i];
            if (entry.type == .usable) {
                var addr = entry.base;
                const end = entry.base + entry.length;
                while (addr + PAGE_SIZE <= end) : (addr += PAGE_SIZE) {
                    const frame_idx = addr / PAGE_SIZE;
                    self.setBit(frame_idx, false);
                    self.free_frames += 1;
                }
            }
        }

        // 3. Mark the metadata storage frames themselves as allocated
        var r: usize = 0;
        while (r < total_reserved_frames) : (r += 1) {
            const frame_idx = (reserved_phys / PAGE_SIZE) + r;
            self.setBit(frame_idx, true);
            self.frame_table[frame_idx].state = .active;
            if (self.free_frames > 0) self.free_frames -= 1;
        }
    }

    fn setBit(self: *PhysicalMemoryManager, frame_idx: u64, occupied: bool) void {
        const byte_idx = frame_idx / 8;
        const bit_idx: u3 = @intCast(frame_idx % 8);
        const mask = @as(u8, 1) << bit_idx;

        if (occupied) {
            self.bitmap[byte_idx] |= mask;
        } else {
            self.bitmap[byte_idx] &= ~mask;
        }
    }

    fn isBitSet(self: *const PhysicalMemoryManager, frame_idx: u64) bool {
        const byte_idx = frame_idx / 8;
        const bit_idx: u3 = @intCast(frame_idx % 8);
        return (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    /// Allocate a single 4 KiB physical frame
    pub fn allocFrame(self: *PhysicalMemoryManager) ?u64 {
        var frame_idx: u64 = 0;
        while (frame_idx < self.total_frames) : (frame_idx += 1) {
            if (!self.isBitSet(frame_idx)) {
                self.setBit(frame_idx, true);
                self.free_frames -= 1;
                self.frame_table[frame_idx].state = .active;
                self.frame_table[frame_idx].ref_count = 1;
                return frame_idx * PAGE_SIZE;
            }
        }
        return null;
    }

    /// Free a previously allocated physical frame
    pub fn freeFrame(self: *PhysicalMemoryManager, phys: u64) void {
        const frame_idx = phys / PAGE_SIZE;
        if (frame_idx >= self.total_frames) return;

        if (self.isBitSet(frame_idx)) {
            self.setBit(frame_idx, false);
            self.free_frames += 1;
            self.frame_table[frame_idx].state = .free;
            self.frame_table[frame_idx].ref_count = 0;
            self.frame_table[frame_idx].compressed_handle = 0;
        }
    }

    pub fn isLowMemory(self: *const PhysicalMemoryManager) bool {
        return self.free_frames <= self.watermark_low;
    }
};

pub var global_pmm: PhysicalMemoryManager = .{};
