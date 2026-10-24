const std = @import("std");
const limine = @import("limine.zig");
pub const slab = @import("slab.zig");

pub const PAGE_SIZE: usize = 4096;

pub const PageState = enum(u8) {
    free = 0,
    active = 1,
    cold = 2,
    compressing = 3,
    compressed = 4,
    decompressing = 5,
    reserved = 6,
};

pub const FrameMeta = struct {
    state: PageState = .free,
    ref_count: u32 = 0,

    pub fn setReserved(self: *FrameMeta) void {
        self.state = .reserved;
        self.ref_count = 0;
    }

    pub fn setCold(self: *FrameMeta) void {
        self.state = .cold;
    }

    pub fn setActive(self: *FrameMeta) void {
        self.state = .active;
    }

    pub fn setCompressing(self: *FrameMeta) void {
        self.state = .compressing;
    }

    pub fn setDecompressing(self: *FrameMeta) void {
        self.state = .decompressing;
    }

    pub fn setFree(self: *FrameMeta) void {
        self.state = .free;
        self.ref_count = 0;
    }
};

pub const PhysicalMemoryManager = struct {
    hhdm_offset: u64 = 0,
    total_frames: usize = 0,
    max_frames: usize = 0,
    free_frames: usize = 0,
    watermark_low: usize = 0,
    watermark_high: usize = 0,
    evict_fn: ?*const fn (*PhysicalMemoryManager, usize) usize = null,
    is_evicting: bool = false,

    // Bitmap for 4 KiB frame allocation
    bitmap: []u8 = &[_]u8{},
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

        // 1. Determine highest usable physical address and total usable frames
        var highest_addr: u64 = 0;
        var usable_frames: usize = 0;
        var i: usize = 0;
        while (i < mmap.entry_count) : (i += 1) {
            const entry = mmap.entries[i];
            if (entry.type == .usable) {
                const top = entry.base + entry.length;
                if (top > highest_addr) {
                    highest_addr = top;
                }
                usable_frames += @intCast(entry.length / PAGE_SIZE);
            }
        }

        self.max_phys_addr = highest_addr;
        self.max_frames = @intCast(highest_addr / PAGE_SIZE);
        self.total_frames = usable_frames;
        self.free_frames = 0;

        // Set compression watermarks (10% low watermark, 20% high watermark) based strictly on usable frames
        self.watermark_low = self.total_frames / 10;
        self.watermark_high = self.total_frames / 5;

        // Calculate size needed for allocation bitmap (1 bit per 4 KiB frame up to max_frames)
        self.bitmap_size_bytes = (self.max_frames + 7) / 8;
        const bitmap_frames_needed = (self.bitmap_size_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

        // Find the first usable entry with enough space to place our bitmap and frame table
        const frame_table_size_bytes = self.max_frames * @sizeOf(FrameMeta);
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
        const bitmap_ptr: [*]u8 = self.physToVirt(reserved_phys);
        self.bitmap = bitmap_ptr[0..self.bitmap_size_bytes];
        // Initially mark all frames as allocated/busy (1 = busy/unavailable)
        @memset(self.bitmap, 0xFF);

        // Frame table is placed immediately after the bitmap
        const frame_table_phys = reserved_phys + (bitmap_frames_needed * PAGE_SIZE);
        self.frame_table = @ptrCast(@alignCast(self.physToVirt(frame_table_phys)));

        // Initialize ALL frame table slots to reserved state before unmasking usable frames
        var f: usize = 0;
        while (f < self.max_frames) : (f += 1) {
            self.frame_table[f] = .{
                .state = .reserved,
                .ref_count = 0,
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
                    self.frame_table[frame_idx].state = .free;
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
        const byte_idx: usize = @intCast(frame_idx / 8);
        const bit_idx: u3 = @intCast(frame_idx % 8);
        const mask = @as(u8, 1) << bit_idx;

        if (occupied) {
            self.bitmap[byte_idx] |= mask;
        } else {
            self.bitmap[byte_idx] &= ~mask;
        }
    }

    fn isBitSet(self: *const PhysicalMemoryManager, frame_idx: u64) bool {
        const byte_idx: usize = @intCast(frame_idx / 8);
        const bit_idx: u3 = @intCast(frame_idx % 8);
        return (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn setEvictor(self: *PhysicalMemoryManager, evict_fn: *const fn (*PhysicalMemoryManager, usize) usize) void {
        self.evict_fn = evict_fn;
    }

    pub fn triggerEviction(self: *PhysicalMemoryManager, target_free: usize) usize {
        if (self.is_evicting) return 0;
        if (self.evict_fn) |evict| {
            self.is_evicting = true;
            defer self.is_evicting = false;
            return evict(self, target_free);
        }
        return 0;
    }

    pub fn markFrameCold(self: *PhysicalMemoryManager, frame_idx: usize) bool {
        if (frame_idx >= self.max_frames) return false;
        if (self.frame_table[frame_idx].state == .active) {
            self.frame_table[frame_idx].state = .cold;
            return true;
        }
        return false;
    }

    pub fn markCold(self: *PhysicalMemoryManager, phys: u64) bool {
        return self.markFrameCold(phys / PAGE_SIZE);
    }

    pub fn isCold(self: *const PhysicalMemoryManager, frame_idx: usize) bool {
        if (frame_idx >= self.max_frames) return false;
        return self.frame_table[frame_idx].state == .cold;
    }

    /// Allocate contiguous physical frames with specified frame alignment (in frame units).
    /// If memory pressure breaches watermark_low or cannot satisfy count, triggers synchronous
    /// eviction up to @max(watermark_high, count) to prevent multi-frame under-eviction starvation.
    pub fn allocContiguousFrames(self: *PhysicalMemoryManager, count: usize, alignment: usize) ?u64 {
        if (count == 0) return null;

        // Synchronous eviction path: if memory is low or insufficient for allocation,
        // compress cold pages until free frames meet or exceed the high watermark or requested count.
        if (!self.is_evicting and (self.free_frames <= self.watermark_low or self.free_frames < count)) {
            _ = self.triggerEviction(@max(self.watermark_high, count));
        }

        if (self.free_frames < count) return null;

        const align_val = if (alignment == 0) 1 else alignment;
        var frame_idx: usize = 0;
        while (frame_idx + count <= self.max_frames) {
            const rem = frame_idx % align_val;
            if (rem != 0) {
                frame_idx += align_val - rem;
                continue;
            }

            var all_free = true;
            var offset: usize = 0;
            while (offset < count) : (offset += 1) {
                if (self.isBitSet(@intCast(frame_idx + offset))) {
                    all_free = false;
                    frame_idx += offset + 1;
                    break;
                }
            }

            if (all_free) {
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const idx = frame_idx + i;
                    self.setBit(@intCast(idx), true);
                    self.frame_table[idx].state = .active;
                    self.frame_table[idx].ref_count = 1;
                }
                self.free_frames -= count;

                // Synchronously evict if this allocation dropped free frames to or below the low watermark
                if (!self.is_evicting and self.free_frames <= self.watermark_low) {
                    _ = self.triggerEviction(self.watermark_high);
                }

                return @as(u64, @intCast(frame_idx)) * PAGE_SIZE;
            }
        }
        return null;
    }

    /// Allocate a single 4 KiB physical frame
    pub fn allocFrame(self: *PhysicalMemoryManager) ?u64 {
        return self.allocContiguousFrames(1, 1);
    }

    /// Free contiguous physical frames
    pub fn freeContiguousFrames(self: *PhysicalMemoryManager, phys: u64, count: usize) void {
        const start_idx = phys / PAGE_SIZE;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const frame_idx = start_idx + i;
            if (frame_idx >= self.max_frames) break;

            if (self.isBitSet(frame_idx)) {
                self.setBit(frame_idx, false);
                self.free_frames += 1;
                self.frame_table[frame_idx].state = .free;
                self.frame_table[frame_idx].ref_count = 0;
            }
        }
    }

    /// Free a previously allocated physical frame
    pub fn freeFrame(self: *PhysicalMemoryManager, phys: u64) void {
        self.freeContiguousFrames(phys, 1);
    }

    pub fn isLowMemory(self: *const PhysicalMemoryManager) bool {
        return self.free_frames <= self.watermark_low;
    }
};

pub var global_pmm: PhysicalMemoryManager = .{};

test "discontiguous physical RAM initializes total_frames and watermarks accurately and reserves holes" {
    // Simulate 384 KiB RAM buffer (96 frames)
    const mock_ram_size: usize = 384 * 1024;
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: PhysicalMemoryManager = .{};

    // Simulate memory map with a hole:
    // Frames 0..31 (128 KiB) unmapped/hole (e.g. MMIO)
    // Frames 32..95 (256 KiB = 64 usable frames) usable DRAM
    var hole_entry = std.mem.zeroes(limine.MemoryMapEntry);
    hole_entry.base = 0;
    hole_entry.length = 128 * 1024;
    hole_entry.type = .reserved;

    var usable_entry = std.mem.zeroes(limine.MemoryMapEntry);
    usable_entry.base = 128 * 1024; // frame 32
    usable_entry.length = 256 * 1024; // 64 usable frames
    usable_entry.type = .usable;

    var entries = [_]*limine.MemoryMapEntry{ &hole_entry, &usable_entry };
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 2,
        .entries = &entries,
    };

    pmm.init(base_addr, &mock_mmap);

    // Verify max_frames covers address space up to highest_addr (96 frames)
    try std.testing.expectEqual(@as(usize, 96), pmm.max_frames);
    // Verify total_frames strictly equals the sum of usable entries (64 frames)
    try std.testing.expectEqual(@as(usize, 64), pmm.total_frames);

    // Verify watermarks are computed from usable frames (64), not max_frames (96)
    try std.testing.expectEqual(@as(usize, 64 / 10), pmm.watermark_low);
    try std.testing.expectEqual(@as(usize, 64 / 5), pmm.watermark_high);

    // Verify unmapped hole frames (0..31) are marked .reserved in frame_table
    var f: usize = 0;
    while (f < 32) : (f += 1) {
        try std.testing.expectEqual(PageState.reserved, pmm.frame_table[f].state);
    }

    // Verify allocation returns a frame from usable range (>= 128 KiB)
    const phys = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    try std.testing.expect(phys >= 128 * 1024);
    try std.testing.expect(phys < 384 * 1024);
    try std.testing.expectEqual(PageState.active, pmm.frame_table[phys / PAGE_SIZE].state);

    // Free the frame and verify transition to .free
    pmm.freeFrame(phys);
    try std.testing.expectEqual(PageState.free, pmm.frame_table[phys / PAGE_SIZE].state);
}

test "allocContiguousFrames evicts to max of watermark_high and requested frame count" {
    const mock_ram_size: usize = 512 * 1024; // 128 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entries = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entries,
    };

    pmm.init(base_addr, &mock_mmap);

    const EvictState = struct {
        var targets: [8]usize = undefined;
        var target_count: usize = 0;

        fn mockEvict(p: *PhysicalMemoryManager, target: usize) usize {
            if (target_count < targets.len) {
                targets[target_count] = target;
                target_count += 1;
            }
            var freed: usize = 0;
            var idx: usize = 0;
            while (p.free_frames < target and idx < p.max_frames) : (idx += 1) {
                if (p.isBitSet(@intCast(idx)) and p.frame_table[idx].state == .cold) {
                    p.freeFrame(@as(u64, @intCast(idx)) * PAGE_SIZE);
                    freed += 1;
                }
            }
            return freed;
        }
    };

    pmm.setEvictor(EvictState.mockEvict);

    pmm.watermark_low = 2;
    pmm.watermark_high = 5;

    // Allocate all usable frames
    while (pmm.allocFrame()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), pmm.free_frames);

    // Free 6 contiguous frames: frames 10..15
    const free_start = 10 * PAGE_SIZE;
    pmm.freeContiguousFrames(free_start, 6);
    try std.testing.expectEqual(@as(usize, 6), pmm.free_frames);

    // Mark adjacent 4 frames (frames 16..19) as cold
    var c: usize = 0;
    while (c < 4) : (c += 1) {
        pmm.frame_table[16 + c].state = .cold;
    }

    // watermark_high (5) <= free_frames (6) < count (10)
    const count: usize = 10;
    EvictState.target_count = 0;

    const alloc_result = pmm.allocContiguousFrames(count, 1);
    try std.testing.expect(alloc_result != null);
    try std.testing.expectEqual(@as(u64, @intCast(free_start)), alloc_result.?);
    // Initial eviction before allocation must target @max(watermark_high, count) == 10
    try std.testing.expect(EvictState.target_count >= 1);
    try std.testing.expectEqual(@as(usize, 10), EvictState.targets[0]);
}

test "PhysicalMemoryManager stores bitmap as bounded slice for software-enforced isolation" {
    const mock_ram_size: usize = 128 * 1024;
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: PhysicalMemoryManager = .{};

    var usable_entry = std.mem.zeroes(limine.MemoryMapEntry);
    usable_entry.base = 0;
    usable_entry.length = mock_ram_size;
    usable_entry.type = .usable;

    var entries = [_]*limine.MemoryMapEntry{&usable_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entries,
    };

    pmm.init(base_addr, &mock_mmap);

    try std.testing.expectEqual(@TypeOf(pmm.bitmap), []u8);
    try std.testing.expectEqual(pmm.bitmap_size_bytes, pmm.bitmap.len);
    try std.testing.expect(pmm.bitmap.len > 0);
}
