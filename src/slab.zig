const memory = @import("memory.zig");
pub const zstd = @import("zstd.zig");

/// Fixed slab block size: 64 KiB (16 x 4 KiB physical frames)
pub const SLAB_BLOCK_SIZE: usize = 64 * 1024;
pub const SLAB_FRAMES_PER_BLOCK: usize = SLAB_BLOCK_SIZE / memory.PAGE_SIZE;

/// Size classes for variable-length compressed page payloads (up to 4096 bytes)
pub const SIZE_CLASSES = [_]usize{ 64, 128, 256, 512, 1024, 2048, 4096 };
pub const NUM_SIZE_CLASSES: usize = SIZE_CLASSES.len;
pub const MAX_SLOT_SIZE: usize = SIZE_CLASSES[SIZE_CLASSES.len - 1];

pub const END_OF_LIST: u16 = 0xFFFF;

/// Map a requested allocation size to the matching size class index
pub fn sizeToClassIndex(size: usize) ?usize {
    if (size == 0 or size > MAX_SLOT_SIZE) return null;
    inline for (SIZE_CLASSES, 0..) |class_size, idx| {
        if (size <= class_size) return idx;
    }
    return null;
}

/// A 64 KiB slab block housing fixed-size slots for a specific size class
pub const SlabBlock = struct {
    next: ?*SlabBlock = null,
    prev: ?*SlabBlock = null,
    cache: ?*SlabCache = null,
    phys_addr: u64 = 0,
    slot_size: u32 = 0,
    total_slots: u16 = 0,
    free_slots: u16 = 0,
    free_head: u16 = 0,
    _padding: [24]u8 = [_]u8{0} ** 24,

    pub const HEADER_SIZE: usize = 64;

    pub fn payloadStart(self: *const SlabBlock) [*]u8 {
        const base = @as(usize, @intFromPtr(self));
        return @ptrFromInt(base + HEADER_SIZE);
    }

    pub fn init(self: *SlabBlock, phys_addr: u64, cache: *SlabCache, slot_size: u32) void {
        self.next = null;
        self.prev = null;
        self.cache = cache;
        self.phys_addr = phys_addr;
        self.slot_size = slot_size;

        const usable_bytes = SLAB_BLOCK_SIZE - HEADER_SIZE;
        const count: u16 = @intCast(usable_bytes / slot_size);
        self.total_slots = count;
        self.free_slots = count;
        self.free_head = 0;

        const payload = self.payloadStart();
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const slot_ptr = payload + (@as(usize, i) * slot_size);
            const next_idx = if (i + 1 < count) i + 1 else END_OF_LIST;
            const next_field: *u16 = @ptrCast(@alignCast(slot_ptr));
            next_field.* = next_idx;
        }
    }

    pub fn allocSlot(self: *SlabBlock) ?[*]u8 {
        if (self.free_slots == 0 or self.free_head == END_OF_LIST) return null;
        const slot_idx = self.free_head;
        const payload = self.payloadStart();
        const slot_ptr = payload + (@as(usize, slot_idx) * self.slot_size);

        const next_field: *const u16 = @ptrCast(@alignCast(slot_ptr));
        self.free_head = next_field.*;
        self.free_slots -= 1;

        @memset(slot_ptr[0..self.slot_size], 0);
        return slot_ptr;
    }

    pub fn freeSlot(self: *SlabBlock, ptr: [*]u8) void {
        const payload = self.payloadStart();
        const slot_offset = @as(usize, @intFromPtr(ptr)) - @as(usize, @intFromPtr(payload));
        const slot_idx: u16 = @intCast(slot_offset / self.slot_size);

        const next_field: *u16 = @ptrCast(@alignCast(ptr));
        next_field.* = self.free_head;
        self.free_head = slot_idx;
        self.free_slots += 1;
    }

    pub fn fromPointer(ptr: [*]u8) *SlabBlock {
        const block_addr = @as(usize, @intFromPtr(ptr)) & ~(SLAB_BLOCK_SIZE - 1);
        return @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(block_addr))));
    }
};

/// Slab cache managing slab blocks of a single size class
pub const SlabCache = struct {
    slot_size: usize = 0,
    partial_list: ?*SlabBlock = null,
    full_list: ?*SlabBlock = null,
    free_list: ?*SlabBlock = null,
    total_slabs: usize = 0,
    active_allocations: usize = 0,
    allocator: ?*SlabAllocator = null,

    pub fn init(self: *SlabCache, slot_size: usize) void {
        self.slot_size = slot_size;
        self.partial_list = null;
        self.full_list = null;
        self.free_list = null;
        self.total_slabs = 0;
        self.active_allocations = 0;
        self.allocator = null;
    }

    fn pushList(head: *?*SlabBlock, block: *SlabBlock) void {
        block.next = head.*;
        block.prev = null;
        if (head.*) |first| {
            first.prev = block;
        }
        head.* = block;
    }

    fn removeList(head: *?*SlabBlock, block: *SlabBlock) void {
        if (block.prev) |p| {
            p.next = block.next;
        } else {
            head.* = block.next;
        }
        if (block.next) |n| {
            n.prev = block.prev;
        }
        block.next = null;
        block.prev = null;
    }

    pub fn preallocateBlock(self: *SlabCache, pmm: *memory.PhysicalMemoryManager) bool {
        const phys = pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK) orelse return false;
        const virt: [*]u8 = pmm.physToVirt(phys);
        const block: *SlabBlock = @ptrCast(@alignCast(virt));
        block.init(phys, self, @intCast(self.slot_size));
        self.total_slabs += 1;
        pushList(&self.free_list, block);
        return true;
    }

    pub fn attachBlock(self: *SlabCache, block: *SlabBlock, phys_addr: u64) void {
        block.init(phys_addr, self, @intCast(self.slot_size));
        self.total_slabs += 1;
        pushList(&self.free_list, block);
    }

    pub fn alloc(self: *SlabCache, pmm: *memory.PhysicalMemoryManager) ?[*]u8 {
        // 1. Partial slabs with available slots
        if (self.partial_list) |block| {
            const slot = block.allocSlot() orelse return null;
            self.active_allocations += 1;
            if (block.free_slots == 0) {
                removeList(&self.partial_list, block);
                pushList(&self.full_list, block);
            }
            return slot;
        }

        // 2. Cached completely free slabs
        if (self.free_list) |block| {
            removeList(&self.free_list, block);
            pushList(&self.partial_list, block);
            const slot = block.allocSlot() orelse return null;
            self.active_allocations += 1;
            if (block.free_slots == 0) {
                removeList(&self.partial_list, block);
                pushList(&self.full_list, block);
            }
            return slot;
        }

        // 3. Allocate a new 64 KiB slab block from PMM (16 contiguous frames)
        if (!self.preallocateBlock(pmm)) {
            // Under memory pressure when 16 contiguous frames are unavailable from PMM,
            // pull from the pre-allocated reserve pool to prevent eviction starvation.
            if (self.allocator) |allocator| {
                if (allocator.popReserveBlock()) |res_block| {
                    self.attachBlock(res_block, res_block.phys_addr);
                } else {
                    return null;
                }
            } else {
                return null;
            }
        }

        if (self.free_list) |block| {
            removeList(&self.free_list, block);
            pushList(&self.partial_list, block);
            const slot = block.allocSlot() orelse return null;
            self.active_allocations += 1;
            if (block.free_slots == 0) {
                removeList(&self.partial_list, block);
                pushList(&self.full_list, block);
            }
            return slot;
        }
        return null;
    }

    pub fn free(self: *SlabCache, pmm: *memory.PhysicalMemoryManager, ptr: [*]u8) void {
        const block = SlabBlock.fromPointer(ptr);
        const was_full = (block.free_slots == 0);

        block.freeSlot(ptr);
        if (self.active_allocations > 0) self.active_allocations -= 1;

        if (was_full) {
            removeList(&self.full_list, block);
            pushList(&self.partial_list, block);
        }

        // When a slab block is completely empty, cache up to 1 free block, otherwise return to PMM
        if (block.free_slots == block.total_slots) {
            removeList(&self.partial_list, block);
            if (self.free_list == null) {
                pushList(&self.free_list, block);
            } else {
                self.total_slabs -= 1;
                pmm.freeContiguousFrames(block.phys_addr, SLAB_FRAMES_PER_BLOCK);
            }
        }
    }
};

/// Handle representing a compressed page stored in the slab pool
pub const PageHandle = struct {
    id: u32 = 0,

    pub const invalid: PageHandle = .{ .id = 0 };

    pub fn isValid(self: PageHandle) bool {
        return self.id != 0;
    }

    pub fn toU32(self: PageHandle) u32 {
        return self.id;
    }

    pub fn fromU32(id: u32) PageHandle {
        return .{ .id = id };
    }
};

pub const HandleEntry = struct {
    ptr: [*]u8 = undefined,
    size: u16 = 0,
    class_idx: u8 = 0,
    in_use: bool = false,
    next_free: u32 = 0,
};

/// Table managing handles to compressed pages in the in-RAM slab pool
pub const PageHandleManager = struct {
    entries: [*]HandleEntry = undefined,
    max_handles: usize = 0,
    free_head: u32 = 0,
    active_handles: usize = 0,
    phys_addr: u64 = 0,

    pub fn init(self: *PageHandleManager, pmm: *memory.PhysicalMemoryManager, max_handles: usize) bool {
        self.max_handles = max_handles;
        const bytes_needed = max_handles * @sizeOf(HandleEntry);
        const frames_needed = (bytes_needed + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE;

        const phys = pmm.allocContiguousFrames(frames_needed, 1) orelse return false;
        self.phys_addr = phys;
        self.entries = @ptrCast(@alignCast(pmm.physToVirt(phys)));
        self.active_handles = 0;

        var i: u32 = 1;
        while (i < max_handles) : (i += 1) {
            self.entries[i] = .{
                .ptr = undefined,
                .size = 0,
                .class_idx = 0,
                .in_use = false,
                .next_free = if (i + 1 < max_handles) i + 1 else 0,
            };
        }
        self.free_head = 1;
        return true;
    }

    pub fn allocHandle(self: *PageHandleManager, ptr: [*]u8, size: u16, class_idx: u8) ?PageHandle {
        if (self.free_head == 0 or self.free_head >= self.max_handles) return null;
        const id = self.free_head;
        self.free_head = self.entries[id].next_free;

        self.entries[id] = .{
            .ptr = ptr,
            .size = size,
            .class_idx = class_idx,
            .in_use = true,
            .next_free = 0,
        };
        self.active_handles += 1;
        return PageHandle{ .id = id };
    }

    pub fn freeHandle(self: *PageHandleManager, handle: PageHandle) ?HandleEntry {
        if (!handle.isValid() or handle.id >= self.max_handles) return null;
        if (!self.entries[handle.id].in_use) return null;

        const old_entry = self.entries[handle.id];
        self.entries[handle.id] = .{
            .ptr = undefined,
            .size = 0,
            .class_idx = 0,
            .in_use = false,
            .next_free = self.free_head,
        };
        self.free_head = handle.id;
        if (self.active_handles > 0) self.active_handles -= 1;
        return old_entry;
    }

    pub fn getSlice(self: *const PageHandleManager, handle: PageHandle) ?[]u8 {
        if (!handle.isValid() or handle.id >= self.max_handles) return null;
        if (!self.entries[handle.id].in_use) return null;
        return self.entries[handle.id].ptr[0..self.entries[handle.id].size];
    }
};

/// Pre-allocated, unpageable memory buffer reserved for Zstd working state
pub const ScratchArena = struct {
    phys_addr: u64 = 0,
    virt_addr: [*]u8 = undefined,
    size: usize = 0,

    pub fn init(self: *ScratchArena, pmm: *memory.PhysicalMemoryManager, size: usize) bool {
        const frames = (size + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE;
        const phys = pmm.allocContiguousFrames(frames, 1) orelse return false;
        self.phys_addr = phys;
        self.virt_addr = pmm.physToVirt(phys);
        self.size = size;
        @memset(self.virt_addr[0..self.size], 0);
        return true;
    }

    pub fn getSlice(self: *const ScratchArena) []u8 {
        return self.virt_addr[0..self.size];
    }
};

pub const MAX_RESERVE_BLOCKS: usize = 64;
pub const EMERGENCY_CLASS_IDX: u8 = 0xFF;

/// Global In-RAM Slab Allocator managing fixed-size caches for variable-length compressed chunks
pub const SlabAllocator = struct {
    pmm: *memory.PhysicalMemoryManager = undefined,
    caches: [NUM_SIZE_CLASSES]SlabCache = undefined,
    handle_mgr: PageHandleManager = .{},
    scratch_arena: ScratchArena = .{},
    cctx: ?*zstd.ZSTD_CCtx = null,
    dctx: ?*zstd.ZSTD_DCtx = null,
    initialized: bool = false,
    reserve_blocks: [MAX_RESERVE_BLOCKS]?*SlabBlock = [_]?*SlabBlock{null} ** MAX_RESERVE_BLOCKS,
    reserve_count: usize = 0,

    pub fn popReserveBlock(self: *SlabAllocator) ?*SlabBlock {
        if (self.reserve_count == 0) return null;
        self.reserve_count -= 1;
        const block = self.reserve_blocks[self.reserve_count];
        self.reserve_blocks[self.reserve_count] = null;
        return block;
    }

    pub fn reserveBlocksCount(self: *const SlabAllocator) usize {
        return self.reserve_count;
    }

    pub fn init(self: *SlabAllocator, pmm: *memory.PhysicalMemoryManager) void {
        self.pmm = pmm;
        self.reserve_count = 0;
        for (&self.reserve_blocks) |*b| {
            b.* = null;
        }

        for (SIZE_CLASSES, 0..) |size, i| {
            self.caches[i].init(size);
            self.caches[i].allocator = self;
            // Pre-allocate at least one SlabBlock per size class so that eviction into
            // existing caches is guaranteed to have spare slots without demanding 16
            // contiguous free frames during an active low-memory state.
            if (!self.caches[i].preallocateBlock(pmm)) {
                @panic("Failed to pre-allocate slab block for size class");
            }
        }

        // Dynamically allocate a pool of reserve slab blocks at boot sized to match
        // the maximum expected eviction volume (up to watermark_high or ring capacity).
        // Each 64 KiB block holds 15 slots for the 4096-byte class, and more for smaller classes.
        const max_eviction = if (pmm.watermark_high > 0) pmm.watermark_high else 1024;
        const reserve_needed = @min(MAX_RESERVE_BLOCKS, (max_eviction + 14) / 15);
        // Cap reserve allocation to at most 25% of free physical frames
        const max_reserve_frames = pmm.free_frames / 4;
        const max_allowed_reserves = max_reserve_frames / SLAB_FRAMES_PER_BLOCK;
        const target_reserves = @min(reserve_needed, max_allowed_reserves);

        var r: usize = 0;
        while (r < target_reserves) : (r += 1) {
            const phys = pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK) orelse break;
            const virt: [*]u8 = pmm.physToVirt(phys);
            const block: *SlabBlock = @ptrCast(@alignCast(virt));
            block.phys_addr = phys;
            self.reserve_blocks[self.reserve_count] = block;
            self.reserve_count += 1;
        }

        // Initialize 16,384 handles for compressed page pool
        if (!self.handle_mgr.init(pmm, 16384)) {
            @panic("Failed to allocate slab handle manager table");
        }

        // Reserve 256 KiB fixed scratch arena for Zstandard working state
        const SCRATCH_ARENA_SIZE: usize = 256 * 1024;
        if (!self.scratch_arena.init(pmm, SCRATCH_ARENA_SIZE)) {
            @panic("Failed to allocate Zstd fixed scratch arena");
        }

        // Initialize pre-allocated Zstandard compression and decompression contexts in static scratch arena
        const scratch_slice = self.scratch_arena.getSlice();
        const half = scratch_slice.len / 2;
        self.cctx = zstd.ZSTD_initStaticCCtx(scratch_slice[0..half]);
        self.dctx = zstd.ZSTD_initStaticDCtx(scratch_slice[half..]);

        if (self.cctx == null or self.dctx == null) {
            @panic("Failed to initialize static Zstd contexts");
        }

        self.initialized = true;
    }

    /// Allocate raw memory of given size (up to 4096 bytes)
    pub fn alloc(self: *SlabAllocator, size: usize) ?[*]u8 {
        const class_idx = sizeToClassIndex(size) orelse return null;
        return self.caches[class_idx].alloc(self.pmm);
    }

    /// Free raw memory allocated via alloc()
    pub fn free(self: *SlabAllocator, ptr: [*]u8) void {
        const block = SlabBlock.fromPointer(ptr);
        if (block.cache) |cache| {
            cache.free(self.pmm, ptr);
        }
    }

    /// Store a compressed page payload in the slab pool and return a PageHandle.
    /// Falls back to allocating single 4 KiB frames for emergency slab storage
    /// when under memory pressure and 16 contiguous frames are unavailable.
    pub fn allocCompressed(self: *SlabAllocator, data: []const u8) ?PageHandle {
        if (data.len == 0 or data.len > memory.PAGE_SIZE) return null;
        const class_idx = sizeToClassIndex(data.len) orelse return null;

        // 1. Try standard / reserve slab cache allocation
        if (self.caches[class_idx].alloc(self.pmm)) |slot| {
            @memcpy(slot[0..data.len], data);
            if (self.handle_mgr.allocHandle(slot, @intCast(data.len), @intCast(class_idx))) |handle| {
                return handle;
            } else {
                self.caches[class_idx].free(self.pmm, slot);
                return null;
            }
        }

        // 2. Emergency fallback: allocate a single 4 KiB frame for emergency slab storage
        // when contiguous 64 KiB (16-frame) slab blocks cannot be allocated under memory pressure.
        if (self.pmm.allocFrame()) |single_phys| {
            const emergency_ptr: [*]u8 = self.pmm.physToVirt(single_phys);
            @memcpy(emergency_ptr[0..data.len], data);
            if (self.handle_mgr.allocHandle(emergency_ptr, @intCast(data.len), EMERGENCY_CLASS_IDX)) |handle| {
                return handle;
            } else {
                self.pmm.freeFrame(single_phys);
                return null;
            }
        }

        return null;
    }

    /// Retrieve compressed page slice given a PageHandle
    pub fn getCompressed(self: *const SlabAllocator, handle: PageHandle) ?[]const u8 {
        return self.handle_mgr.getSlice(handle);
    }

    /// Free a compressed page from the slab pool
    pub fn freeCompressed(self: *SlabAllocator, handle: PageHandle) void {
        if (self.handle_mgr.freeHandle(handle)) |entry| {
            if (entry.class_idx == EMERGENCY_CLASS_IDX) {
                // Free emergency single 4 KiB frame directly back to PMM
                const phys = self.pmm.virtToPhys(@intFromPtr(entry.ptr));
                self.pmm.freeFrame(phys);
            } else {
                self.caches[entry.class_idx].free(self.pmm, entry.ptr);
            }
        }
    }

    /// Synchronously compress an uncompressed 4 KiB frame and store the compressed payload into the slab pool.
    /// If the compressed frame exceeds PAGE_SIZE (e.g. high-entropy payload lacking RLE runs),
    /// eviction is aborted for this frame and error.IncompressiblePage is explicitly returned.
    pub fn compressAndStore(self: *SlabAllocator, frame_data: []const u8) !PageHandle {
        if (frame_data.len > memory.PAGE_SIZE) return error.CompressionFailed;
        const cctx = self.cctx orelse return error.ContextNotInitialized;
        var comp_buf: [zstd.ZSTD_compressBound(memory.PAGE_SIZE)]u8 = undefined;
        const comp_len = cctx.compress(&comp_buf, frame_data, 1) catch return error.CompressionFailed;
        if (comp_len > memory.PAGE_SIZE) {
            return error.IncompressiblePage;
        }
        return self.allocCompressed(comp_buf[0..comp_len]) orelse error.OutOfMemory;
    }

    /// Retrieve and decompress a compressed page payload back into a 4 KiB destination frame
    pub fn decompressToFrame(self: *const SlabAllocator, handle: PageHandle, dest_frame: []u8) !usize {
        const dctx = self.dctx orelse return error.ContextNotInitialized;
        const comp_slice = self.getCompressed(handle) orelse return error.InvalidHandle;
        return dctx.decompress(dest_frame, comp_slice);
    }

    /// Total active slab blocks across all size caches
    pub fn totalSlabBlocks(self: *const SlabAllocator) usize {
        var total: usize = 0;
        for (self.caches) |cache| {
            total += cache.total_slabs;
        }
        return total;
    }

    /// Total active allocations across all size caches
    pub fn totalActiveAllocations(self: *const SlabAllocator) usize {
        var total: usize = 0;
        for (self.caches) |cache| {
            total += cache.active_allocations;
        }
        return total;
    }

    /// Total active compressed page handles
    pub fn activeCompressedPages(self: *const SlabAllocator) usize {
        return self.handle_mgr.active_handles;
    }
};

pub var global_slab: SlabAllocator = .{};

test "size to class index mapping" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?usize, null), sizeToClassIndex(0));
    try std.testing.expectEqual(@as(?usize, 0), sizeToClassIndex(1));
    try std.testing.expectEqual(@as(?usize, 0), sizeToClassIndex(64));
    try std.testing.expectEqual(@as(?usize, 1), sizeToClassIndex(65));
    try std.testing.expectEqual(@as(?usize, 1), sizeToClassIndex(128));
    try std.testing.expectEqual(@as(?usize, 2), sizeToClassIndex(200));
    try std.testing.expectEqual(@as(?usize, 3), sizeToClassIndex(500));
    try std.testing.expectEqual(@as(?usize, 4), sizeToClassIndex(1000));
    try std.testing.expectEqual(@as(?usize, 5), sizeToClassIndex(2000));
    try std.testing.expectEqual(@as(?usize, 6), sizeToClassIndex(4000));
    try std.testing.expectEqual(@as(?usize, 6), sizeToClassIndex(4096));
    try std.testing.expectEqual(@as(?usize, null), sizeToClassIndex(4097));
}

test "page handle validation" {
    const std = @import("std");
    const h = PageHandle.fromU32(1234);
    try std.testing.expect(h.isValid());
    try std.testing.expectEqual(@as(u32, 1234), h.toU32());
    try std.testing.expect(!PageHandle.invalid.isValid());
}

test "compressAndStore rejects incompressible high entropy page" {
    const std = @import("std");
    const limine = @import("limine.zig");

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

    var slab_alloc: SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // High entropy page that cannot be RLE-compressed
    var high_entropy_page: [memory.PAGE_SIZE]u8 = undefined;
    for (&high_entropy_page, 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    const result = slab_alloc.compressAndStore(&high_entropy_page);
    try std.testing.expectError(error.IncompressiblePage, result);
}

test "pre-allocated slab blocks prevent deadlock when free frames drop below 16" {
    const std = @import("std");
    const limine = @import("limine.zig");

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

    var slab_alloc: SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Verify all size classes have at least one pre-allocated slab block
    try std.testing.expectEqual(NUM_SIZE_CLASSES, slab_alloc.totalSlabBlocks());

    // Exhaust physical frames until free frames drop below 16
    while (pmm.free_frames > 4) {
        _ = pmm.allocFrame() orelse break;
    }
    try std.testing.expect(pmm.free_frames < 16);

    // Allocating 16 contiguous frames fails because free_frames < 16
    try std.testing.expectEqual(@as(?u64, null), pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK));

    // Storing compressed data into existing pre-allocated slabs succeeds despite low physical memory
    const test_payload = "Pre-allocated slab block saves the day under low physical memory!";
    const handle = slab_alloc.allocCompressed(test_payload) orelse return error.TestUnexpectedResult;
    try std.testing.expect(handle.isValid());

    const retrieved = slab_alloc.getCompressed(handle) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, test_payload, retrieved);

    // Test compressing a 4 KiB frame into the pre-allocated slab when free frames < 16
    var page_data: [memory.PAGE_SIZE]u8 = undefined;
    @memset(page_data[0..memory.PAGE_SIZE], 'A');
    const comp_handle = try slab_alloc.compressAndStore(&page_data);
    try std.testing.expect(comp_handle.isValid());

    var decomp_dest: [memory.PAGE_SIZE]u8 = undefined;
    const decomp_len = try slab_alloc.decompressToFrame(comp_handle, &decomp_dest);
    try std.testing.expectEqual(memory.PAGE_SIZE, decomp_len);
    try std.testing.expectEqualSlices(u8, &page_data, &decomp_dest);

    slab_alloc.freeCompressed(handle);
    slab_alloc.freeCompressed(comp_handle);
}

test "prevent slab allocation starvation during low-memory eviction with reserve blocks" {
    const std = @import("std");
    const limine = @import("limine.zig");

    // 4 MiB RAM = 1024 frames
    const mock_ram_size: usize = 4 * 1024 * 1024;
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

    var slab_alloc: SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Initial 4096-byte slab block has 15 slots.
    // Fill all 15 slots of the 4096-byte class with 3500-byte payloads.
    var handles: [16]PageHandle = undefined;
    var payload: [3500]u8 = undefined;

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        @memset(&payload, @truncate(i + 1));
        handles[i] = slab_alloc.allocCompressed(&payload) orelse return error.TestUnexpectedResult;
        try std.testing.expect(handles[i].isValid());
    }

    // Now exhaust physical memory so contiguous 16 frames are unavailable
    while (pmm.free_frames > 5) {
        _ = pmm.allocFrame() orelse break;
    }

    // Ensure 16 contiguous frames cannot be allocated
    try std.testing.expectEqual(@as(?u64, null), pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK));

    // The 16th allocation would fail in the old code because 15 slots are full
    // and allocating 16 contiguous frames for a new block fails under memory pressure.
    // With reserve blocks / emergency fallback, allocation succeeds without deadlocking.
    @memset(&payload, 0xEE);
    handles[15] = slab_alloc.allocCompressed(&payload) orelse return error.TestUnexpectedResult;
    try std.testing.expect(handles[15].isValid());

    // Verify bit-for-bit retrieval of the 16th allocation
    const retrieved = slab_alloc.getCompressed(handles[15]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &payload, retrieved);

    // Clean up
    var j: usize = 0;
    while (j <= 15) : (j += 1) {
        slab_alloc.freeCompressed(handles[j]);
    }
}

test "emergency single frame fallback when reserve pool and contiguous memory are exhausted" {
    const std = @import("std");
    const limine = @import("limine.zig");

    const mock_ram_size: usize = 2 * 1024 * 1024;
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

    var slab_alloc: SlabAllocator = .{};
    slab_alloc.init(&pmm);

    // Deplete any reserve blocks in slab_alloc
    while (slab_alloc.popReserveBlock()) |_| {}

    // Fill all 15 slots of the 4096 size class with 3500-byte payloads
    var handles: [16]PageHandle = undefined;
    var payload: [3500]u8 = undefined;
    @memset(&payload, 0x42);

    var i: usize = 0;
    while (i < 15) : (i += 1) {
        handles[i] = slab_alloc.allocCompressed(&payload) orelse return error.TestUnexpectedResult;
        try std.testing.expect(handles[i].isValid());
    }

    // Now drain free frames so fewer than 16 remain
    while (pmm.free_frames > 3) {
        _ = pmm.allocFrame() orelse break;
    }

    // Contiguous 16 frames unavailable:
    try std.testing.expectEqual(@as(?u64, null), pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK));

    // Storing a 16th page must fall back to emergency single frame
    handles[15] = slab_alloc.allocCompressed(&payload) orelse return error.TestUnexpectedResult;
    try std.testing.expect(handles[15].isValid());

    // Verify it is tracked as emergency
    const entry = slab_alloc.handle_mgr.entries[handles[15].id];
    try std.testing.expectEqual(EMERGENCY_CLASS_IDX, entry.class_idx);

    // Verify retrieved slice and clean up
    const retrieved = slab_alloc.getCompressed(handles[15]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &payload, retrieved);

    for (handles) |h| {
        slab_alloc.freeCompressed(h);
    }
}

test "allocCompressed reclaims allocated slab slot when handle table is exhausted" {
    const std = @import("std");
    const limine = @import("limine.zig");

    const mock_ram_size: usize = 2 * 1024 * 1024;
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

    var slab_alloc: SlabAllocator = .{};
    slab_alloc.init(&pmm);

    const class_idx = sizeToClassIndex(64).?;
    const initial_active = slab_alloc.caches[class_idx].active_allocations;

    // Simulate handle exhaustion by invalidating free_head
    slab_alloc.handle_mgr.free_head = 0;

    const payload = [_]u8{0x5A} ** 64;
    const result = slab_alloc.allocCompressed(&payload);

    try std.testing.expectEqual(@as(?PageHandle, null), result);
    // Ensure the slot allocated in slab_alloc.caches was freed back and not leaked
    try std.testing.expectEqual(initial_active, slab_alloc.caches[class_idx].active_allocations);
}
