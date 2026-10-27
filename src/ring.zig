const std = @import("std");
const builtin = @import("builtin");
pub const memory = @import("memory.zig");
pub const slab = @import("slab.zig");
pub const zstd = @import("zstd.zig");
pub const limine = @import("limine.zig");

/// Default capacity for the in-memory compression ring buffer (must be a power of 2)
pub const DEFAULT_RING_CAPACITY: usize = 1024;

/// Status of an entry within the compression ring buffer
pub const RingEntryStatus = enum(u8) {
    empty = 0,
    pending = 1,
    compressing = 2,
    compressed = 3,
    error_failed = 4,
};

/// Entry descriptor enqueued into the circular compression ring buffer
pub const RingEntry = struct {
    frame_idx: usize = 0,
    phys_addr: u64 = 0,
    handle: slab.PageHandle = slab.PageHandle.invalid,
    compressed_size: u32 = 0,
    managed_page: ?*ManagedPage = null,
    status: RingEntryStatus = .empty,
    sequence: u64 = 0,
};

/// Slot structure for Dmitry Vyukov's MPMC lockless bounded ring buffer
pub const RingSlot = struct {
    sequence: usize = 0,
    entry: RingEntry = .{},
};

/// Page lifecycle state machine tracking an in-RAM page through active, cold,
/// compressing, compressed, and decompressing states without disk paging.
pub const ManagedPage = struct {
    state: memory.PageState = .free,
    phys_addr: u64 = 0,
    handle: slab.PageHandle = slab.PageHandle.invalid,
    compressed_size: u32 = 0,
    access_count: u32 = 0,
    in_ring: bool = false,

    pub const invalid: ManagedPage = .{};

    /// Initialize a newly allocated physical frame as an active page
    pub fn initActive(phys_addr: u64) ManagedPage {
        return .{
            .state = .active,
            .phys_addr = phys_addr,
            .handle = slab.PageHandle.invalid,
            .compressed_size = 0,
            .access_count = 1,
            .in_ring = false,
        };
    }

    /// Mark this active page as cold (candidate for compression eviction)
    pub fn markCold(self: *ManagedPage, pmm: *memory.PhysicalMemoryManager) bool {
        if (self.state != .active) return false;
        self.state = .cold;
        _ = pmm.markCold(self.phys_addr);
        return true;
    }

    /// Mark this cold page as active again (e.g. when task is scheduled to run)
    pub fn markActive(self: *ManagedPage, pmm: ?*memory.PhysicalMemoryManager) bool {
        if (self.state != .cold) return false;
        self.state = .active;
        if (pmm) |p| {
            _ = p.markActive(self.phys_addr);
        }
        return true;
    }

    pub fn isCold(self: *const ManagedPage) bool {
        return self.state == .cold;
    }

    pub fn isCompressed(self: *const ManagedPage) bool {
        return self.state == .compressed and self.handle.isValid();
    }

    pub fn isActive(self: *const ManagedPage) bool {
        return self.state == .active;
    }

    /// Synchronously compress this cold page into the in-RAM slab pool,
    /// freeing the underlying physical frame back to the PMM free frame pool.
    pub fn compress(
        self: *ManagedPage,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) !slab.PageHandle {
        if (self.state != .cold and self.state != .active) return error.InvalidPageState;
        self.state = .compressing;
        const frame_idx = self.phys_addr / memory.PAGE_SIZE;
        if (frame_idx < pmm.max_frames) {
            pmm.frame_table[frame_idx].state = .compressing;
        }

        const was_evicting = pmm.is_evicting;
        pmm.is_evicting = true;
        defer pmm.is_evicting = was_evicting;

        const virt: [*]const u8 = pmm.physToVirt(self.phys_addr);
        const frame_slice = virt[0..memory.PAGE_SIZE];

        const handle = slab_alloc.compressAndStore(frame_slice) catch |err| {
            if (err == error.IncompressiblePage) {
                self.state = .active;
                if (frame_idx < pmm.max_frames) {
                    pmm.frame_table[frame_idx].state = .active;
                }
            } else {
                self.state = .cold;
                if (frame_idx < pmm.max_frames) {
                    pmm.frame_table[frame_idx].state = .cold;
                }
            }
            return err;
        };

        const comp_slice = slab_alloc.getCompressed(handle);
        const comp_len: u32 = if (comp_slice) |s| @intCast(s.len) else 0;

        // Return uncompressed physical frame to PMM free pool
        const old_phys = self.phys_addr;
        pmm.freeFrame(old_phys);

        self.handle = handle;
        self.phys_addr = 0;
        self.compressed_size = comp_len;
        self.state = .compressed;

        return handle;
    }

    /// Access this page: if currently compressed, synchronously allocate a free physical frame
    /// and decompress the payload back into physical RAM.
    pub fn access(
        self: *ManagedPage,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) ![*]u8 {
        if (self.state == .active or self.state == .cold) {
            self.state = .active;
            const frame_idx = self.phys_addr / memory.PAGE_SIZE;
            if (frame_idx < pmm.max_frames) {
                pmm.frame_table[frame_idx].state = .active;
            }
            self.access_count += 1;
            return pmm.physToVirt(self.phys_addr);
        }

        if (self.state == .compressed) {
            self.state = .decompressing;

            // Allocate a new physical frame from PMM
            const new_phys = pmm.allocFrame() orelse {
                self.state = .compressed;
                return error.OutOfMemory;
            };

            const virt: [*]u8 = pmm.physToVirt(new_phys);
            const frame_slice = virt[0..memory.PAGE_SIZE];

            const decomp_len = slab_alloc.decompressToFrame(self.handle, frame_slice) catch |err| {
                pmm.freeFrame(new_phys);
                self.state = .compressed;
                return err;
            };

            if (decomp_len != memory.PAGE_SIZE) {
                pmm.freeFrame(new_phys);
                self.state = .compressed;
                return error.DecompressionLengthMismatch;
            }

            // Free the compressed slab payload
            slab_alloc.freeCompressed(self.handle);

            self.phys_addr = new_phys;
            self.handle = slab.PageHandle.invalid;
            self.compressed_size = 0;
            self.state = .active;
            self.access_count += 1;

            const frame_idx = new_phys / memory.PAGE_SIZE;
            if (frame_idx < pmm.max_frames) {
                pmm.frame_table[frame_idx].state = .active;
            }

            return virt;
        }

        return error.InvalidPageState;
    }

    /// Deallocate this page, freeing either its physical frame or compressed slab payload
    pub fn deallocate(
        self: *ManagedPage,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) void {
        if (self.state == .active or self.state == .cold or self.state == .compressing) {
            if (self.phys_addr != 0) {
                pmm.freeFrame(self.phys_addr);
            }
        } else if (self.state == .compressed) {
            if (self.handle.isValid()) {
                slab_alloc.freeCompressed(self.handle);
            }
        }
        self.state = .free;
        self.phys_addr = 0;
        self.handle = slab.PageHandle.invalid;
        self.compressed_size = 0;
        self.in_ring = false;
    }
};

/// Lockless in-RAM circular ring buffer orchestrating cold page compression
/// and synchronous eviction when free physical frames breach the low watermark.
pub const CompressionRing = struct {
    slots: []RingSlot = &[_]RingSlot{},
    capacity: usize = 0,
    mask: usize = 0,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    total_enqueued: usize = 0,
    total_evicted: usize = 0,
    total_bytes_compressed: usize = 0,
    total_bytes_saved: usize = 0,
    initialized: bool = false,

    // Pre-allocated static storage to guarantee zero-deadlock eviction
    static_slots: [DEFAULT_RING_CAPACITY]RingSlot = undefined,

    /// Hardware memory barrier constrained to core compression ring buffer
    pub inline fn dmb() void {
        if (builtin.cpu.arch == .aarch64) {
            asm volatile ("dmb ish" ::: "memory");
        } else {
            @fence(.seq_cst);
        }
    }

    /// Initialize the global compression ring with pre-allocated static storage
    pub fn init(
        self: *CompressionRing,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) void {
        _ = slab_alloc;
        self.initWithBuffer(self.static_slots[0..]);
        if (self == &global_ring) {
            pmm.setEvictor(evictCallback);
        }
    }

    /// Initialize the ring buffer over a specified pre-allocated slice
    pub fn initWithBuffer(self: *CompressionRing, buffer: []RingSlot) void {
        const cap = buffer.len;
        // Enforce power-of-two capacity for lockless bitwise masking
        if ((cap & (cap - 1)) != 0 or cap == 0) {
            @panic("Compression ring capacity must be a power of two");
        }

        self.capacity = cap;
        self.mask = cap - 1;
        self.slots = buffer;
        self.head = 0;
        self.tail = 0;
        self.count = 0;
        self.total_enqueued = 0;
        self.total_evicted = 0;
        self.total_bytes_compressed = 0;
        self.total_bytes_saved = 0;

        for (buffer, 0..) |*slot, i| {
            slot.sequence = i;
            slot.entry = .{};
        }

        self.initialized = true;
    }

    /// Lockless enqueue of a cold page eviction descriptor (Dmitry Vyukov MPMC bounded algorithm)
    pub fn enqueue(self: *CompressionRing, entry: RingEntry) bool {
        var pos = @atomicLoad(usize, &self.tail, .monotonic);
        while (true) {
            const slot = &self.slots[pos & self.mask];
            const seq = @atomicLoad(usize, &slot.sequence, .acquire);
            const diff = @as(isize, @bitCast(seq -% pos));
            if (diff == 0) {
                if (@cmpxchgWeak(usize, &self.tail, pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                } else {
                    slot.entry = entry;
                    dmb();
                    @atomicStore(usize, &slot.sequence, pos +% 1, .release);
                    _ = @atomicRmw(usize, &self.count, .Add, 1, .monotonic);
                    _ = @atomicRmw(usize, &self.total_enqueued, .Add, 1, .monotonic);
                    return true;
                }
            } else if (diff < 0) {
                return false; // Ring buffer is full
            } else {
                pos = @atomicLoad(usize, &self.tail, .monotonic);
            }
        }
    }

    /// Lockless dequeue of the oldest cold page eviction descriptor
    pub fn dequeue(self: *CompressionRing) ?RingEntry {
        var pos = @atomicLoad(usize, &self.head, .monotonic);
        while (true) {
            const slot = &self.slots[pos & self.mask];
            const seq = @atomicLoad(usize, &slot.sequence, .acquire);
            const diff = @as(isize, @bitCast(seq -% (pos +% 1)));
            if (diff == 0) {
                if (@cmpxchgWeak(usize, &self.head, pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                } else {
                    const entry = slot.entry;
                    if (entry.managed_page) |mp| {
                        mp.in_ring = false;
                    }
                    dmb();
                    @atomicStore(usize, &slot.sequence, pos +% self.capacity, .release);
                    _ = @atomicRmw(usize, &self.count, .Sub, 1, .monotonic);
                    return entry;
                }
            } else if (diff < 0) {
                return null; // Ring buffer is empty
            } else {
                pos = @atomicLoad(usize, &self.head, .monotonic);
            }
        }
    }

    /// Enqueue a candidate ManagedPage
    pub fn enqueueManagedPage(self: *CompressionRing, page: *ManagedPage) bool {
        if (page.in_ring) return false;
        const frame_idx = page.phys_addr / memory.PAGE_SIZE;
        const success = self.enqueue(.{
            .frame_idx = frame_idx,
            .phys_addr = page.phys_addr,
            .handle = slab.PageHandle.invalid,
            .compressed_size = 0,
            .managed_page = page,
            .status = .pending,
            .sequence = @intCast(self.total_enqueued),
        });
        if (success) {
            page.in_ring = true;
        }
        return success;
    }

    pub fn getCount(self: *const CompressionRing) usize {
        return @atomicLoad(usize, &self.count, .monotonic);
    }

    pub fn isEmpty(self: *const CompressionRing) bool {
        return self.getCount() == 0;
    }

    pub fn isFull(self: *const CompressionRing) bool {
        return self.getCount() >= self.capacity;
    }

    /// Evict a single cold page: compresses via Zstd into the slab pool and frees
    /// the physical frame back to physical memory manager.
    /// Compression eviction is strictly restricted to ManagedPage instances.
    /// If compression fails due to slab pool exhaustion (OutOfMemory), the cold page
    /// entry is immediately re-enqueued into the ring to prevent orphaning.
    pub fn evictOne(
        self: *CompressionRing,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) ?RingEntry {
        const was_evicting = pmm.is_evicting;
        pmm.is_evicting = true;
        defer pmm.is_evicting = was_evicting;

        // Process entries from circular ring buffer, restricted exclusively to ManagedPage instances
        while (self.dequeue()) |entry| {
            const mp = entry.managed_page orelse continue;
            if (!mp.isCold()) continue;

            const handle = mp.compress(pmm, slab_alloc) catch |err| {
                if (err == error.IncompressiblePage) {
                    // Page is incompressible; eviction transitions it to active and skips it
                    continue;
                }
                // Slab exhaustion: preserve entry in ring to prevent orphaning cold page
                mp.in_ring = true;
                _ = self.enqueue(entry);
                return null;
            };

            var res = entry;
            res.handle = handle;
            res.status = .compressed;
            res.compressed_size = mp.compressed_size;
            _ = @atomicRmw(usize, &self.total_evicted, .Add, 1, .monotonic);
            _ = @atomicRmw(usize, &self.total_bytes_compressed, .Add, memory.PAGE_SIZE, .monotonic);
            const saved = if (mp.compressed_size < memory.PAGE_SIZE) memory.PAGE_SIZE - mp.compressed_size else 0;
            _ = @atomicRmw(usize, &self.total_bytes_saved, .Add, saved, .monotonic);
            return res;
        }

        return null;
    }

    /// Evict cold pages until free physical frames meet or exceed target_free
    pub fn evictUntil(
        self: *CompressionRing,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
        target_free: usize,
    ) usize {
        const was_evicting = pmm.is_evicting;
        pmm.is_evicting = true;
        defer pmm.is_evicting = was_evicting;

        var evicted_count: usize = 0;
        var max_attempts = self.getCount() + pmm.total_frames;
        while (pmm.free_frames < target_free and max_attempts > 0) : (max_attempts -= 1) {
            if (self.evictOne(pmm, slab_alloc) != null) {
                evicted_count += 1;
            } else {
                break; // No progress possible (ring empty or compression pool exhausted)
            }
        }
        return evicted_count;
    }

    /// Synchronous eviction path: compress cold pages until free frames exceed high watermark
    pub fn evictUntilHighWatermark(
        self: *CompressionRing,
        pmm: *memory.PhysicalMemoryManager,
        slab_alloc: *slab.SlabAllocator,
    ) usize {
        return self.evictUntil(pmm, slab_alloc, pmm.watermark_high);
    }
};

/// Global In-Memory Compression Ring instance
pub var global_ring: CompressionRing = .{};

/// Eviction callback wired into PhysicalMemoryManager
pub fn evictCallback(pmm: *memory.PhysicalMemoryManager, target_free: usize) usize {
    return global_ring.evictUntil(pmm, &slab.global_slab, target_free);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "lockless ring buffer enqueue and dequeue" {
    var ring: CompressionRing = .{};
    var test_slots: [8]RingSlot = undefined;
    ring.initWithBuffer(&test_slots);

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ring.getCount());

    // Enqueue 8 entries to fill the ring
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const ok = ring.enqueue(.{
            .frame_idx = i,
            .phys_addr = @as(u64, @intCast(i * 4096)),
            .status = .pending,
        });
        try std.testing.expect(ok);
    }

    try std.testing.expect(ring.isFull());
    try std.testing.expectEqual(@as(usize, 8), ring.getCount());

    // Next enqueue should fail as ring is full
    const full_ok = ring.enqueue(.{
        .frame_idx = 99,
        .phys_addr = 99 * 4096,
        .status = .pending,
    });
    try std.testing.expect(!full_ok);

    // Dequeue in FIFO order
    i = 0;
    while (i < 8) : (i += 1) {
        const entry = ring.dequeue() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(i, entry.frame_idx);
        try std.testing.expectEqual(@as(u64, @intCast(i * 4096)), entry.phys_addr);
    }

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(?RingEntry, null), ring.dequeue());
}

test "managed page lifecycle transitions and compression roundtrip" {
    // Setup simulated memory manager and slab allocator in test buffer
    const mock_ram_size: usize = 2 * 1024 * 1024; // 2 MiB
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    // Construct mock memory map response
    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Warm up slab allocator cache so a slab block is pre-allocated
    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    // 1. Allocate an active frame and wrap in ManagedPage
    const phys = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    var page = ManagedPage.initActive(phys);
    try std.testing.expect(page.isActive());
    try std.testing.expectEqual(memory.PageState.active, page.state);

    // Write distinctive test pattern into active page
    const virt: [*]u8 = pmm.physToVirt(phys);
    @memset(virt[0..1000], 'P');
    @memset(virt[1000..3000], 0);
    @memcpy(virt[3000..3020], "Phase 4 Ring Test!!!");
    @memset(virt[3020..4096], 'Z');

    // 2. Mark cold and reactivate with markActive
    try std.testing.expect(page.markCold(&pmm));
    try std.testing.expect(page.isCold());
    try std.testing.expectEqual(memory.PageState.cold, page.state);

    try std.testing.expect(page.markActive(&pmm));
    try std.testing.expect(page.isActive());
    try std.testing.expectEqual(memory.PageState.active, page.state);

    // Re-mark cold for subsequent compression test
    try std.testing.expect(page.markCold(&pmm));
    try std.testing.expect(page.isCold());

    // 3. Compress into slab pool
    const initial_free = pmm.free_frames;
    const handle = try page.compress(&pmm, &slab_alloc);
    try std.testing.expect(handle.isValid());
    try std.testing.expect(page.isCompressed());
    try std.testing.expectEqual(memory.PageState.compressed, page.state);
    try std.testing.expectEqual(@as(u64, 0), page.phys_addr);
    // Compressing returned 1 physical frame back to free pool
    try std.testing.expectEqual(initial_free + 1, pmm.free_frames);

    // 4. Access: triggers synchronous decompression into a newly allocated frame
    const restored_virt = try page.access(&pmm, &slab_alloc);
    try std.testing.expect(page.isActive());
    try std.testing.expectEqual(memory.PageState.active, page.state);
    try std.testing.expect(page.phys_addr != 0);

    // Verify bit-for-bit data integrity
    try std.testing.expectEqual(@as(u8, 'P'), restored_virt[0]);
    try std.testing.expectEqual(@as(u8, 0), restored_virt[1500]);
    try std.testing.expectEqualStrings("Phase 4 Ring Test!!!", restored_virt[3000..3020]);
    try std.testing.expectEqual(@as(u8, 'Z'), restored_virt[4000]);

    // 5. Deallocate
    page.deallocate(&pmm, &slab_alloc);
    try std.testing.expectEqual(memory.PageState.free, page.state);
}

test "watermark eviction replenishes free frames" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Pre-allocate slab block for uniform pages
    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // Allocate 10 frames and mark them cold
    var cold_pages: [10]ManagedPage = undefined;
    for (&cold_pages) |*cp| {
        const p = pmm.allocFrame() orelse return error.TestUnexpectedResult;
        const v: [*]u8 = pmm.physToVirt(p);
        @memset(v[0..memory.PAGE_SIZE], 'A');
        cp.* = ManagedPage.initActive(p);
        _ = cp.markCold(&pmm);
        _ = ring.enqueueManagedPage(cp);
    }

    try std.testing.expectEqual(@as(usize, 10), ring.getCount());

    // Configure test watermarks: target high watermark = free_frames + 5
    const target_high = pmm.free_frames + 5;
    pmm.watermark_high = target_high;
    pmm.watermark_low = pmm.free_frames; // Hit low watermark

    const evicted = ring.evictUntilHighWatermark(&pmm, &slab_alloc);
    try std.testing.expect(evicted >= 5);
    try std.testing.expect(pmm.free_frames >= target_high);

    // Clean up
    for (&cold_pages) |*cp| {
        cp.deallocate(&pmm, &slab_alloc);
    }
}

test "synchronous eviction triggered during allocation under memory pressure" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Pre-allocate slab block for uniform pages
    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    // Use a custom test ring and wire it up as evictor
    const Context = struct {
        var test_ring: CompressionRing = .{};
        var test_slab: *slab.SlabAllocator = undefined;

        fn evict(p: *memory.PhysicalMemoryManager, target: usize) usize {
            return test_ring.evictUntil(p, test_slab, target);
        }
    };

    Context.test_ring.initWithBuffer(Context.test_ring.static_slots[0..]);
    Context.test_slab = &slab_alloc;
    pmm.setEvictor(Context.evict);

    // Allocate 5 frames and mark them cold
    var cold_pages: [5]ManagedPage = undefined;
    for (&cold_pages) |*cp| {
        const p = pmm.allocFrame() orelse return error.TestUnexpectedResult;
        const v: [*]u8 = pmm.physToVirt(p);
        @memset(v[0..memory.PAGE_SIZE], 'Z');
        cp.* = ManagedPage.initActive(p);
        _ = cp.markCold(&pmm);
        _ = Context.test_ring.enqueueManagedPage(cp);
    }

    // Set watermarks so free_frames <= watermark_low
    pmm.watermark_low = pmm.free_frames;
    pmm.watermark_high = pmm.free_frames + 3;

    // Trigger allocation: allocFrame should detect free_frames <= watermark_low
    // and synchronously evict cold pages until free_frames >= watermark_high
    const new_frame = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    try std.testing.expect(new_frame != 0);
    try std.testing.expect(pmm.free_frames >= pmm.watermark_high - 1);

    pmm.freeFrame(new_frame);
    for (&cold_pages) |*cp| {
        cp.deallocate(&pmm, &slab_alloc);
    }
}

test "managed page skips eviction and returns error.IncompressiblePage for high entropy data" {
    const mock_ram_size: usize = 2 * 1024 * 1024; // 2 MiB
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const phys = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    var page = ManagedPage.initActive(phys);

    // Populate with high entropy bytes
    const virt: [*]u8 = pmm.physToVirt(phys);
    for (virt[0..memory.PAGE_SIZE], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    _ = page.markCold(&pmm);
    const initial_free = pmm.free_frames;

    // Compression should explicitly return error.IncompressiblePage
    const comp_result = page.compress(&pmm, &slab_alloc);
    try std.testing.expectError(error.IncompressiblePage, comp_result);

    // Eviction was skipped: page remains in physical RAM, frame was not freed,
    // and frame transitions to .active so subsequent passes skip it
    try std.testing.expectEqual(initial_free, pmm.free_frames);
    try std.testing.expectEqual(phys, page.phys_addr);
    try std.testing.expect(!page.isCompressed());
    try std.testing.expect(page.isActive());
    try std.testing.expectEqual(memory.PageState.active, page.state);
    try std.testing.expectEqual(memory.PageState.active, pmm.frame_table[phys / memory.PAGE_SIZE].state);

    // Clean up
    page.deallocate(&pmm, &slab_alloc);
}

test "watermark eviction skips incompressible page and continues with compressible pages" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Warm up slab allocator
    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // Page 1: high entropy incompressible page
    const p1 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v1: [*]u8 = pmm.physToVirt(p1);
    for (v1[0..memory.PAGE_SIZE], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }
    var incomp_page = ManagedPage.initActive(p1);
    _ = incomp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&incomp_page);

    // Page 2: compressible uniform page
    const p2 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v2: [*]u8 = pmm.physToVirt(p2);
    @memset(v2[0..memory.PAGE_SIZE], 'U');
    var comp_page = ManagedPage.initActive(p2);
    _ = comp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&comp_page);

    try std.testing.expectEqual(@as(usize, 2), ring.getCount());

    const target_free = pmm.free_frames + 1;
    const evicted = ring.evictUntil(&pmm, &slab_alloc, target_free);

    // Incompressible page was skipped and transitioned to .active, compressible page was evicted
    try std.testing.expectEqual(@as(usize, 1), evicted);
    try std.testing.expect(incomp_page.isActive());
    try std.testing.expectEqual(memory.PageState.active, incomp_page.state);
    try std.testing.expectEqual(memory.PageState.active, pmm.frame_table[p1 / memory.PAGE_SIZE].state);
    try std.testing.expect(incomp_page.phys_addr != 0);
    try std.testing.expect(comp_page.isCompressed());
    try std.testing.expectEqual(@as(u64, 0), comp_page.phys_addr);

    // Clean up
    incomp_page.deallocate(&pmm, &slab_alloc);
    comp_page.deallocate(&pmm, &slab_alloc);
}

test "eviction ignores raw frames and does not scavenge pmm frame table" {
    const mock_ram_size: usize = 2 * 1024 * 1024; // 2 MiB
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // 1. Allocate a raw unmanaged frame and mark it cold in pmm
    const raw_phys = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v: [*]u8 = pmm.physToVirt(raw_phys);
    @memset(v[0..memory.PAGE_SIZE], 'R');
    _ = pmm.markCold(raw_phys);

    const initial_free = pmm.free_frames;

    // 2. evictOne with empty ring must NOT scavenge raw frame from pmm frame_table
    try std.testing.expect(ring.isEmpty());
    const scavenge_result = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expectEqual(@as(?RingEntry, null), scavenge_result);
    try std.testing.expectEqual(initial_free, pmm.free_frames);
    try std.testing.expectEqual(memory.PageState.cold, pmm.frame_table[raw_phys / memory.PAGE_SIZE].state);

    // 3. Even if a raw entry without a managed page was enqueued into the ring, evictOne skips it
    _ = ring.enqueue(.{
        .frame_idx = raw_phys / memory.PAGE_SIZE,
        .phys_addr = raw_phys,
        .managed_page = null,
        .status = .pending,
    });
    try std.testing.expectEqual(@as(usize, 1), ring.getCount());

    const queued_raw_result = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expectEqual(@as(?RingEntry, null), queued_raw_result);
    try std.testing.expectEqual(initial_free, pmm.free_frames);
    try std.testing.expectEqual(memory.PageState.cold, pmm.frame_table[raw_phys / memory.PAGE_SIZE].state);

    // Clean up
    pmm.freeFrame(raw_phys);
}

test "incompressible page transition to active prevents starvation loop in subsequent eviction" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // Create an incompressible page
    const p1 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v1: [*]u8 = pmm.physToVirt(p1);
    for (v1[0..memory.PAGE_SIZE], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }
    var incomp_page = ManagedPage.initActive(p1);
    _ = incomp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&incomp_page);

    // First eviction pass tries to compress incomp_page and skips it
    const res1 = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expectEqual(@as(?RingEntry, null), res1);
    try std.testing.expect(incomp_page.isActive());
    try std.testing.expectEqual(memory.PageState.active, pmm.frame_table[p1 / memory.PAGE_SIZE].state);

    // If incomp_page was re-enqueued, a subsequent eviction pass immediately skips it
    // because it is .active (not .cold)
    _ = ring.enqueueManagedPage(&incomp_page);

    // Queue another compressible page after it
    const p2 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v2: [*]u8 = pmm.physToVirt(p2);
    @memset(v2[0..memory.PAGE_SIZE], 'M');
    var comp_page = ManagedPage.initActive(p2);
    _ = comp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&comp_page);

    // Next evictOne must immediately skip incomp_page and successfully evict comp_page
    const res2 = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expect(res2 != null);
    try std.testing.expect(comp_page.isCompressed());

    incomp_page.deallocate(&pmm, &slab_alloc);
    comp_page.deallocate(&pmm, &slab_alloc);
}

test "eviction halts cleanly when slab pool is exhausted without zero-gain emergency frames" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // Deplete reserve blocks in slab_alloc
    while (slab_alloc.popReserveBlock()) |_| {}

    // Allocate frame for the cold test page before draining PMM
    const p1 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v1: [*]u8 = pmm.physToVirt(p1);
    @memset(v1[0..memory.PAGE_SIZE], 'A');
    var comp_page = ManagedPage.initActive(p1);
    _ = comp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&comp_page);

    // Drain PMM so fewer than 16 contiguous frames remain; slab allocator cannot allocate new blocks
    while (pmm.free_frames > 3) {
        _ = pmm.allocFrame() orelse break;
    }
    try std.testing.expectEqual(@as(?u64, null), pmm.allocContiguousFrames(slab.SLAB_FRAMES_PER_BLOCK, slab.SLAB_FRAMES_PER_BLOCK));

    // Exhaust all remaining slots across existing pre-allocated size classes
    var dummy_handles: [2500]slab.PageHandle = undefined;
    var dummy_count: usize = 0;
    for (&slab_alloc.caches, 0..) |*cache, c_idx| {
        while (cache.alloc(&pmm)) |slot| {
            if (slab_alloc.handle_mgr.allocHandle(slot, 16, @intCast(c_idx))) |h| {
                dummy_handles[dummy_count] = h;
                dummy_count += 1;
            } else {
                cache.free(&pmm, slot);
                break;
            }
        }
    }

    const free_before = pmm.free_frames;

    // Eviction attempt must return 0 because slab pool cannot allocate,
    // and must NOT consume a single frame for emergency storage (zero net gain).
    const evicted = ring.evictUntil(&pmm, &slab_alloc, pmm.watermark_high);
    try std.testing.expectEqual(@as(usize, 0), evicted);

    // Free frames must not have been consumed
    try std.testing.expectEqual(free_before, pmm.free_frames);

    // Page should remain cold and unevicted
    try std.testing.expect(comp_page.isCold());

    // Clean up
    comp_page.deallocate(&pmm, &slab_alloc);
    var d: usize = 0;
    while (d < dummy_count) : (d += 1) {
        slab_alloc.freeCompressed(dummy_handles[d]);
    }
}

test "eviction preserves cold page in ring on slab exhaustion without orphaning" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    var ring: CompressionRing = .{};
    ring.init(&pmm, &slab_alloc);

    // Deplete reserve blocks in slab_alloc
    while (slab_alloc.popReserveBlock()) |_| {}

    // Allocate frame for the cold test page before exhausting PMM
    const p1 = pmm.allocFrame() orelse return error.TestUnexpectedResult;
    const v1: [*]u8 = pmm.physToVirt(p1);
    @memset(v1[0..memory.PAGE_SIZE], 'K');
    var comp_page = ManagedPage.initActive(p1);
    _ = comp_page.markCold(&pmm);
    _ = ring.enqueueManagedPage(&comp_page);

    // Drain PMM free frames below slab block allocation requirement
    while (pmm.free_frames > 3) {
        _ = pmm.allocFrame() orelse break;
    }

    // Exhaust all remaining slots across existing slab caches
    var dummy_handles: [2500]slab.PageHandle = undefined;
    var dummy_count: usize = 0;
    for (&slab_alloc.caches, 0..) |*cache, c_idx| {
        while (cache.alloc(&pmm)) |slot| {
            if (slab_alloc.handle_mgr.allocHandle(slot, 16, @intCast(c_idx))) |h| {
                dummy_handles[dummy_count] = h;
                dummy_count += 1;
            } else {
                cache.free(&pmm, slot);
                break;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 1), ring.getCount());

    // 1. evictOne must fail because slab pool cannot allocate, returning null
    const fail_evict = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expectEqual(@as(?RingEntry, null), fail_evict);

    // 2. Cold page must NOT be orphaned: it must remain .cold and stay enqueued in the ring
    try std.testing.expect(comp_page.isCold());
    try std.testing.expectEqual(memory.PageState.cold, comp_page.state);
    try std.testing.expectEqual(@as(usize, 1), ring.getCount());

    // 3. Free dummy slab allocations to replenish slab capacity
    while (dummy_count > 0) {
        dummy_count -= 1;
        slab_alloc.freeCompressed(dummy_handles[dummy_count]);
    }

    // 4. Subsequent eviction should now successfully evict the retained cold page
    const ok_evict = ring.evictOne(&pmm, &slab_alloc);
    try std.testing.expect(ok_evict != null);
    try std.testing.expect(comp_page.isCompressed());
    try std.testing.expectEqual(@as(usize, 0), ring.getCount());

    // Clean up
    comp_page.deallocate(&pmm, &slab_alloc);
}

test "allocContiguousFrames evicts cold pages up to count when count exceeds high watermark" {
    const mock_ram_size: usize = 4 * 1024 * 1024; // 4 MiB = 1024 frames
    var mock_ram: [mock_ram_size]u8 align(64 * 1024) = undefined;
    @memset(&mock_ram, 0);

    const base_addr = @as(usize, @intFromPtr(&mock_ram[0]));
    var pmm: memory.PhysicalMemoryManager = .{};

    var mmap_entry = std.mem.zeroes(limine.MemoryMapEntry);
    mmap_entry.base = 0;
    mmap_entry.length = mock_ram_size;
    mmap_entry.type = .usable;

    var entry_ptrs = [_]*limine.MemoryMapEntry{&mmap_entry};
    const mock_mmap = limine.MemoryMapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = &entry_ptrs,
    };

    pmm.init(base_addr, &mock_mmap);

    var slab_alloc: slab.SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const warmup = slab_alloc.allocCompressed("warmup") orelse return error.TestUnexpectedResult;
    slab_alloc.freeCompressed(warmup);

    const Context = struct {
        var test_ring: CompressionRing = .{};
        var test_slab: *slab.SlabAllocator = undefined;

        fn evict(p: *memory.PhysicalMemoryManager, target: usize) usize {
            return test_ring.evictUntil(p, test_slab, target);
        }
    };

    Context.test_ring.initWithBuffer(Context.test_ring.static_slots[0..]);
    Context.test_slab = &slab_alloc;
    pmm.setEvictor(Context.evict);

    // Inhibit eviction during test setup and memory draining
    pmm.is_evicting = true;

    // Allocate 10 contiguous frames and mark them cold
    var cold_pages: [10]ManagedPage = undefined;
    for (&cold_pages) |*cp| {
        const p = pmm.allocFrame() orelse return error.TestUnexpectedResult;
        const v: [*]u8 = pmm.physToVirt(p);
        @memset(v[0..memory.PAGE_SIZE], 'M');
        cp.* = ManagedPage.initActive(p);
        _ = cp.markCold(&pmm);
        _ = Context.test_ring.enqueueManagedPage(cp);
    }

    // Drain all remaining free frames
    while (pmm.allocFrame()) |_| {}
    try std.testing.expectEqual(@as(usize, 0), pmm.free_frames);

    // Re-enable eviction for the test
    pmm.is_evicting = false;

    // watermark_low (2), watermark_high (3), count (6)
    // Target eviction must be @max(watermark_high, count) == 6
    // Before fix: triggerEviction(3) only freed 3 frames, failing count (6)
    // With fix: triggerEviction(6) frees 6 contiguous cold frames
    pmm.watermark_low = 2;
    pmm.watermark_high = 3;

    const count: usize = 6;
    const contiguous_block = pmm.allocContiguousFrames(count, 1);
    try std.testing.expect(contiguous_block != null);

    pmm.freeContiguousFrames(contiguous_block.?, count);
    for (&cold_pages) |*cp| {
        cp.deallocate(&pmm, &slab_alloc);
    }
}

test "CompressionRing stores slots as bounded slice for software-enforced isolation" {
    var ring = CompressionRing{};
    var test_slots: [8]RingSlot = undefined;
    ring.initWithBuffer(&test_slots);

    try std.testing.expectEqual(@TypeOf(ring.slots), []RingSlot);
    try std.testing.expectEqual(ring.capacity, ring.slots.len);
    try std.testing.expectEqual(@as(usize, 8), ring.slots.len);
}
