// Limine Boot Protocol definitions for Zig (Limine Protocol v7 / Base Revision 3)

pub const BaseRevision = extern struct {
    id: [2]u64 = .{ 0xf9562b2d3616ae62, 0x27e46200216658a2 },
    revision: u64 = 3,

    pub fn isSupported(self: *const BaseRevision) bool {
        return self.revision == 0;
    }
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48d2dcb38de828a6, 0x8a30d01ced43e496 },
    revision: u64 = 0,
    response: ?*const HhdmResponse = null,
};

pub const MemoryMapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemoryMapEntryType,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemoryMapEntry,
};

pub const MemoryMapRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a14e6, 0xe310acda30e7d778 },
    revision: u64 = 0,
    response: ?*const MemoryMapResponse = null,
};
