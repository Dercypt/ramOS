const memory = @import("memory.zig");

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

    pub fn init(self: *SlabCache, slot_size: usize) void {
        self.slot_size = slot_size;
        self.partial_list = null;
        self.full_list = null;
        self.free_list = null;
        self.total_slabs = 0;
        self.active_allocations = 0;
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
        const phys = pmm.allocContiguousFrames(SLAB_FRAMES_PER_BLOCK, SLAB_FRAMES_PER_BLOCK) orelse return null;
        const virt: [*]u8 = pmm.physToVirt(phys);
        const block: *SlabBlock = @ptrCast(@alignCast(virt));
        block.init(phys, self, @intCast(self.slot_size));
        self.total_slabs += 1;

        pushList(&self.partial_list, block);
        const slot = block.allocSlot() orelse return null;
        self.active_allocations += 1;
        if (block.free_slots == 0) {
            removeList(&self.partial_list, block);
            pushList(&self.full_list, block);
        }
        return slot;
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

/// Global In-RAM Slab Allocator managing fixed-size caches for variable-length compressed chunks
pub const SlabAllocator = struct {
    pmm: *memory.PhysicalMemoryManager = undefined,
    caches: [NUM_SIZE_CLASSES]SlabCache = undefined,
    handle_mgr: PageHandleManager = .{},
    scratch_arena: ScratchArena = .{},
    initialized: bool = false,

    pub fn init(self: *SlabAllocator, pmm: *memory.PhysicalMemoryManager) void {
        self.pmm = pmm;
        for (SIZE_CLASSES, 0..) |size, i| {
            self.caches[i].init(size);
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

    /// Store a compressed page payload in the slab pool and return a PageHandle
    pub fn allocCompressed(self: *SlabAllocator, data: []const u8) ?PageHandle {
        if (data.len == 0 or data.len > memory.PAGE_SIZE) return null;
        const class_idx = sizeToClassIndex(data.len) orelse return null;
        const slot = self.caches[class_idx].alloc(self.pmm) orelse return null;
        @memcpy(slot[0..data.len], data);
        return self.handle_mgr.allocHandle(slot, @intCast(data.len), @intCast(class_idx));
    }

    /// Retrieve compressed page slice given a PageHandle
    pub fn getCompressed(self: *const SlabAllocator, handle: PageHandle) ?[]const u8 {
        return self.handle_mgr.getSlice(handle);
    }

    /// Free a compressed page from the slab pool
    pub fn freeCompressed(self: *SlabAllocator, handle: PageHandle) void {
        if (self.handle_mgr.freeHandle(handle)) |entry| {
            self.caches[entry.class_idx].free(self.pmm, entry.ptr);
        }
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
