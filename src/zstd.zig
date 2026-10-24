//! RFC 8878 Zstandard RLE Frame Encoder and Decompressor
//!
//! ramOS integrates a freestanding RFC 8878 frame encoder designed for zero-allocation
//! in-RAM kernel page compression.
//!
//! ### Encoding Architecture & Scope
//! This engine implements bare-metal RFC 8878 framing restricted to Run-Length Encoded (RLE)
//! blocks and raw uncompressed blocks. It emits standard Zstandard frames containing:
//!   - Zstandard Magic Number (0xFD2FB528)
//!   - Frame Header Descriptor (Single Segment, FCS field)
//!   - RLE Blocks (Type 1) for repetitive byte sequences (>= MIN_RLE_RUN bytes)
//!   - Raw Blocks (Type 0) as fallback for non-uniform chunks
//!
//! ### Incompressibility, Header Accounting, and Truncation Invariants
//! Because complex entropy coding stages (Finite State Entropy / Huffman) are intentionally
//! omitted to preserve freestanding bare-metal determinism and avoid dynamic allocation,
//! high-entropy input pages lacking byte runs cannot achieve compression. In such cases,
//! RFC 8878 raw block framing appends frame headers (7 bytes) and raw block headers (3 bytes),
//! expanding a 4096-byte page to 4106 bytes.
//!
//! To preserve lossless decompression and framing correctness:
//!   - **Truncation Guard:** If static chunk capacity is exhausted before scanning the full
//!     source (`src_pos < src.len`), `compress` immediately takes the single Raw block
//!     fallback to prevent emitting truncated frames that mismatch the Frame Content Size (FCS).
//!   - **Frame Header Accounting:** When evaluating whether chunking achieves compression,
//!     frame header overhead (`out_pos`) is accounted for (`out_pos + total_block_bytes >= src.len`).
//!     If chunking expands past `src.len`, it immediately falls back to a single Raw block.
//!
//! Downstream memory management subsystems (`compressAndStore` and `ManagedPage.compress`)
//! must verify `comp_len <= memory.PAGE_SIZE`. If `comp_len > memory.PAGE_SIZE`, the page
//! must be marked as incompressible, eviction must be skipped, and `error.IncompressiblePage`
//! must be returned to avoid failing slab class lookups (`sizeToClassIndex()`).
//!
//! ### Decompression
//! Decompression is fully RFC 8878 compliant via Zig's standard library Zstandard decoder.

const std = @import("std");

/// RFC 8878 Zstandard Magic Number (0xFD2FB528, little-endian: [0x28, 0xB5, 0x2F, 0xFD])
pub const ZSTD_MAGIC_NUMBER: u32 = 0xFD2FB528;

pub const DEFAULT_COMPRESSION_LEVEL: i32 = 1;
pub const MIN_COMPRESSION_LEVEL: i32 = 1;
pub const MAX_COMPRESSION_LEVEL: i32 = 19;

/// Minimum contiguous run of matching bytes to encode as an RLE block
pub const MIN_RLE_RUN: usize = 8;

/// Standard maximum single page frame size (4 KiB)
pub const MAX_FRAME_SIZE: usize = 4096;

pub const ZstdError = error{
    DstSizeTooSmall,
    SrcSizeTooLarge,
    WorkspaceTooSmall,
    MalformedHeader,
    MalformedBlock,
    ChecksumMismatch,
    BadMagic,
    BadContentSize,
    CorruptedData,
    UnknownContentSizeUnsupported,
    ContentTooLarge,
    WindowSizeUnknown,
    DictionaryIdFlagUnsupported,
    ReservedBitSet,
    EndOfStream,
};

pub fn ZSTD_getErrorName(err: anyerror) []const u8 {
    return @errorName(err);
}

/// Calculate safe upper bound for compressed frame buffer
pub fn ZSTD_compressBound(src_size: usize) usize {
    // 9 bytes frame header + 3 bytes block header per chunk + margin
    return src_size + (src_size / 8) + 64;
}

pub fn ZSTD_estimateCCtxSize(compression_level: i32) usize {
    _ = compression_level;
    return 128 * 1024; // 128 KiB static workspace
}

pub fn ZSTD_estimateDCtxSize() usize {
    return 128 * 1024; // 128 KiB static workspace
}

const Chunk = struct {
    is_rle: bool,
    byte: u8,
    start: usize,
    len: usize,
};

/// Compression context operating strictly within pre-allocated static workspace memory
pub const ZSTD_CCtx = struct {
    workspace: []u8,
    compression_level: i32 = DEFAULT_COMPRESSION_LEVEL,
    total_compressed: usize = 0,
    total_uncompressed: usize = 0,

    pub fn init(workspace: []u8) !*ZSTD_CCtx {
        if (workspace.len < @sizeOf(ZSTD_CCtx) + 1024) {
            return error.WorkspaceTooSmall;
        }

        const ctx: *ZSTD_CCtx = @ptrCast(@alignCast(workspace.ptr));
        const remaining = workspace[@sizeOf(ZSTD_CCtx)..];
        ctx.* = .{
            .workspace = remaining,
            .compression_level = DEFAULT_COMPRESSION_LEVEL,
            .total_compressed = 0,
            .total_uncompressed = 0,
        };
        return ctx;
    }

    pub fn reset(self: *ZSTD_CCtx) void {
        self.compression_level = DEFAULT_COMPRESSION_LEVEL;
        self.total_compressed = 0;
        self.total_uncompressed = 0;
    }

    /// Compress src into dst using RFC 8878 Zstandard framing (RLE and raw blocks).
    /// Note: This is an RLE frame encoder. If the payload has high entropy and cannot be
    /// compressed using RLE runs (>= MIN_RLE_RUN), or if chunk buffer capacity is reached
    /// before consuming all input, raw framing will be used, producing output larger than
    /// src.len (up to src.len + 10 bytes for standard single-segment frames).
    pub fn compress(
        self: *ZSTD_CCtx,
        dst: []u8,
        src: []const u8,
        compression_level: i32,
    ) ZstdError!usize {
        self.compression_level = compression_level;

        if (src.len == 0) {
            if (dst.len < 9) return error.DstSizeTooSmall;
            // Empty frame: Magic (4) + FHD (1) + FCS (1) + Last Raw block size 0 (3)
            std.mem.writeInt(u32, dst[0..4], ZSTD_MAGIC_NUMBER, .little);
            dst[4] = 0x20; // Single segment, 1-byte FCS
            dst[5] = 0x00; // FCS = 0
            // Block header: last=1, type=0 (raw), size=0
            dst[6] = 0x01;
            dst[7] = 0x00;
            dst[8] = 0x00;
            return 9;
        }

        // 1. Write RFC 8878 Frame Header (Single Segment)
        var out_pos: usize = 0;
        if (dst.len < 10) return error.DstSizeTooSmall;

        std.mem.writeInt(u32, dst[0..4], ZSTD_MAGIC_NUMBER, .little);
        out_pos += 4;

        if (src.len <= 255) {
            dst[out_pos] = 0x20; // Single segment, 1-byte FCS
            out_pos += 1;
            dst[out_pos] = @as(u8, @intCast(src.len));
            out_pos += 1;
        } else if (src.len <= 65535 + 256) {
            if (dst.len < out_pos + 3) return error.DstSizeTooSmall;
            dst[out_pos] = 0x60; // Single segment, 2-byte FCS (actual size = value + 256)
            out_pos += 1;
            const fcs_val: u16 = @intCast(src.len - 256);
            std.mem.writeInt(u16, dst[out_pos..][0..2], fcs_val, .little);
            out_pos += 2;
        } else {
            if (dst.len < out_pos + 5) return error.DstSizeTooSmall;
            dst[out_pos] = 0xA0; // Single segment, 4-byte FCS
            out_pos += 1;
            const fcs_val: u32 = @intCast(src.len);
            std.mem.writeInt(u32, dst[out_pos..][0..4], fcs_val, .little);
            out_pos += 4;
        }

        // 2. Fast check: is the entire input uniform (all matching bytes)?
        var all_uniform = true;
        const first_byte = src[0];
        for (src[1..]) |b| {
            if (b != first_byte) {
                all_uniform = false;
                break;
            }
        }

        if (all_uniform) {
            // Emit a single RLE block for the entire frame
            if (dst.len < out_pos + 4) return error.DstSizeTooSmall;
            const header_val: u24 = 1 | (1 << 1) | (@as(u24, @intCast(src.len)) << 3);
            dst[out_pos] = @truncate(header_val);
            dst[out_pos + 1] = @truncate(header_val >> 8);
            dst[out_pos + 2] = @truncate(header_val >> 16);
            out_pos += 3;
            dst[out_pos] = first_byte;
            out_pos += 1;

            self.total_compressed += out_pos;
            self.total_uncompressed += src.len;
            return out_pos;
        }

        // 3. Multi-chunk segmentation using static workspace
        const max_chunks = self.workspace.len / @sizeOf(Chunk);
        if (max_chunks < 2) return error.WorkspaceTooSmall;
        const chunk_buf: [*]Chunk = @ptrCast(@alignCast(self.workspace.ptr));

        var chunk_count: usize = 0;
        var src_pos: usize = 0;

        while (src_pos < src.len and chunk_count < max_chunks) {
            const b = src[src_pos];
            var run_len: usize = 1;
            while (src_pos + run_len < src.len and src[src_pos + run_len] == b) {
                run_len += 1;
            }

            if (run_len >= MIN_RLE_RUN) {
                chunk_buf[chunk_count] = .{
                    .is_rle = true,
                    .byte = b,
                    .start = src_pos,
                    .len = run_len,
                };
                chunk_count += 1;
                src_pos += run_len;
            } else {
                // Accumulate raw bytes until next run or end
                const raw_start = src_pos;
                src_pos += run_len;
                while (src_pos < src.len) {
                    const b2 = src[src_pos];
                    var run_len2: usize = 1;
                    while (src_pos + run_len2 < src.len and src[src_pos + run_len2] == b2) {
                        run_len2 += 1;
                    }
                    if (run_len2 >= MIN_RLE_RUN) {
                        break;
                    }
                    src_pos += run_len2;
                }

                chunk_buf[chunk_count] = .{
                    .is_rle = false,
                    .byte = 0,
                    .start = raw_start,
                    .len = src_pos - raw_start,
                };
                chunk_count += 1;
            }
        }

        // Calculate expected compressed payload size across all chunks
        var total_block_bytes: usize = 0;
        for (chunk_buf[0..chunk_count]) |chk| {
            if (chk.is_rle) {
                total_block_bytes += 4; // 3 bytes header + 1 byte payload
            } else {
                total_block_bytes += 3 + chk.len; // 3 bytes header + raw payload
            }
        }

        // If chunking did not achieve compression (accounting for frame header overhead),
        // or chunk buffer was exhausted before consuming src, fallback to a single Raw block
        if (src_pos < src.len or out_pos + total_block_bytes >= src.len or chunk_count == 0) {
            if (dst.len < out_pos + 3 + src.len) return error.DstSizeTooSmall;
            const header_val: u24 = 1 | (0 << 1) | (@as(u24, @intCast(src.len)) << 3);
            dst[out_pos] = @truncate(header_val);
            dst[out_pos + 1] = @truncate(header_val >> 8);
            dst[out_pos + 2] = @truncate(header_val >> 16);
            out_pos += 3;
            @memcpy(dst[out_pos .. out_pos + src.len], src);
            out_pos += src.len;

            self.total_compressed += out_pos;
            self.total_uncompressed += src.len;
            return out_pos;
        }

        // Emit encoded blocks
        for (chunk_buf[0..chunk_count], 0..) |chk, idx| {
            const is_last: u24 = if (idx == chunk_count - 1) 1 else 0;
            if (chk.is_rle) {
                if (dst.len < out_pos + 4) return error.DstSizeTooSmall;
                const header_val: u24 = is_last | (1 << 1) | (@as(u24, @intCast(chk.len)) << 3);
                dst[out_pos] = @truncate(header_val);
                dst[out_pos + 1] = @truncate(header_val >> 8);
                dst[out_pos + 2] = @truncate(header_val >> 16);
                out_pos += 3;
                dst[out_pos] = chk.byte;
                out_pos += 1;
            } else {
                if (dst.len < out_pos + 3 + chk.len) return error.DstSizeTooSmall;
                const header_val: u24 = is_last | (0 << 1) | (@as(u24, @intCast(chk.len)) << 3);
                dst[out_pos] = @truncate(header_val);
                dst[out_pos + 1] = @truncate(header_val >> 8);
                dst[out_pos + 2] = @truncate(header_val >> 16);
                out_pos += 3;
                @memcpy(dst[out_pos .. out_pos + chk.len], src[chk.start .. chk.start + chk.len]);
                out_pos += chk.len;
            }
        }

        self.total_compressed += out_pos;
        self.total_uncompressed += src.len;
        return out_pos;
    }
};

/// Decompression context operating strictly within pre-allocated static workspace memory
pub const ZSTD_DCtx = struct {
    workspace: []u8,
    total_decompressed: usize = 0,

    pub fn init(workspace: []u8) !*ZSTD_DCtx {
        if (workspace.len < @sizeOf(ZSTD_DCtx) + 1024) {
            return error.WorkspaceTooSmall;
        }

        const ctx: *ZSTD_DCtx = @ptrCast(@alignCast(workspace.ptr));
        const remaining = workspace[@sizeOf(ZSTD_DCtx)..];
        ctx.* = .{
            .workspace = remaining,
            .total_decompressed = 0,
        };
        return ctx;
    }

    pub fn reset(self: *ZSTD_DCtx) void {
        self.total_decompressed = 0;
    }

    /// Decompress a standard RFC 8878 Zstandard frame into dst
    pub fn decompress(self: *ZSTD_DCtx, dst: []u8, src: []const u8) ZstdError!usize {
        if (src.len < 4) return error.EndOfStream;
        const magic = std.mem.readInt(u32, src[0..4], .little);
        if (magic != ZSTD_MAGIC_NUMBER) return error.BadMagic;

        const res = std.compress.zstd.decompress.decodeZstandardFrame(dst, src, false) catch |err| switch (err) {
            error.UnknownContentSizeUnsupported => return error.UnknownContentSizeUnsupported,
            error.ContentTooLarge => return error.ContentTooLarge,
            error.ContentSizeTooLarge => return error.ContentTooLarge,
            error.WindowSizeUnknown => return error.WindowSizeUnknown,
            error.DictionaryIdFlagUnsupported => return error.DictionaryIdFlagUnsupported,
            error.ChecksumFailure => return error.ChecksumMismatch,
            error.ReservedBitSet => return error.ReservedBitSet,
            error.EndOfStream => return error.EndOfStream,
            error.BadContentSize => return error.BadContentSize,
            else => return error.CorruptedData,
        };

        self.total_decompressed += res.write_count;
        return res.write_count;
    }
};

/// Initialize compression context within pre-allocated static workspace memory
pub fn ZSTD_initStaticCCtx(workspace: []u8) ?*ZSTD_CCtx {
    return ZSTD_CCtx.init(workspace) catch null;
}

/// Initialize decompression context within pre-allocated static workspace memory
pub fn ZSTD_initStaticDCtx(workspace: []u8) ?*ZSTD_DCtx {
    return ZSTD_DCtx.init(workspace) catch null;
}

pub fn ZSTD_compressCCtx(
    cctx: *ZSTD_CCtx,
    dst: []u8,
    src: []const u8,
    compression_level: i32,
) !usize {
    return cctx.compress(dst, src, compression_level);
}

pub fn ZSTD_decompressDCtx(
    dctx: *ZSTD_DCtx,
    dst: []u8,
    src: []const u8,
) !usize {
    return dctx.decompress(dst, src);
}

test "zstd static context initialization and estimation" {
    const cctx_est = ZSTD_estimateCCtxSize(1);
    const dctx_est = ZSTD_estimateDCtxSize();
    try std.testing.expect(cctx_est > 0);
    try std.testing.expect(dctx_est > 0);

    var c_ws: [128 * 1024]u8 = undefined;
    var d_ws: [128 * 1024]u8 = undefined;

    const cctx = ZSTD_initStaticCCtx(&c_ws) orelse return error.TestUnexpectedResult;
    const dctx = ZSTD_initStaticDCtx(&d_ws) orelse return error.TestUnexpectedResult;

    try std.testing.expect(cctx.workspace.len > 0);
    try std.testing.expect(dctx.workspace.len > 0);
}

test "zstd compression and decompression roundtrip" {
    var c_ws: [128 * 1024]u8 = undefined;
    var d_ws: [128 * 1024]u8 = undefined;

    const cctx = ZSTD_initStaticCCtx(&c_ws).?;
    const dctx = ZSTD_initStaticDCtx(&d_ws).?;

    // 1. Zeroed 4 KiB frame (typical cold physical frame)
    const zero_page = [_]u8{0} ** 4096;
    var compressed_buf: [8192]u8 = undefined;
    var decompressed_buf: [4096]u8 = undefined;

    const zero_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, &zero_page, 1);
    // RFC 8878 RLE frame: 7 bytes header + 3 bytes block header + 1 byte value = 11 bytes
    try std.testing.expectEqual(@as(usize, 11), zero_comp_len);

    const zero_decomp_len = try ZSTD_decompressDCtx(dctx, &decompressed_buf, compressed_buf[0..zero_comp_len]);
    try std.testing.expectEqual(@as(usize, 4096), zero_decomp_len);
    try std.testing.expectEqualSlices(u8, &zero_page, &decompressed_buf);

    // 2. Uniform pattern 4 KiB frame
    const uniform_page = [_]u8{'X'} ** 4096;
    const uniform_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, &uniform_page, 1);
    try std.testing.expectEqual(@as(usize, 11), uniform_comp_len);

    const uniform_decomp_len = try ZSTD_decompressDCtx(dctx, &decompressed_buf, compressed_buf[0..uniform_comp_len]);
    try std.testing.expectEqual(@as(usize, 4096), uniform_decomp_len);
    try std.testing.expectEqualSlices(u8, &uniform_page, &decompressed_buf);

    // 3. Mixed page with runs and raw sections
    var mixed_page: [4096]u8 = undefined;
    @memset(mixed_page[0..500], 'A');
    @memset(mixed_page[500..2500], 0);
    @memcpy(mixed_page[2500..2520], "ramOS flat space OS!");
    @memset(mixed_page[2520..4096], 0xFF);

    const mixed_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, &mixed_page, 1);
    try std.testing.expect(mixed_comp_len < 100);

    const mixed_decomp_len = try ZSTD_decompressDCtx(dctx, &decompressed_buf, compressed_buf[0..mixed_comp_len]);
    try std.testing.expectEqual(@as(usize, 4096), mixed_decomp_len);
    try std.testing.expectEqualSlices(u8, &mixed_page, &decompressed_buf);

    // 4. Heterogeneous data page
    const text_payload = "Operating System with In-Memory Compression and Flat Address Space";
    const text_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, text_payload, 1);
    var text_out: [128]u8 = undefined;
    const text_decomp_len = try ZSTD_decompressDCtx(dctx, &text_out, compressed_buf[0..text_comp_len]);
    try std.testing.expectEqual(text_payload.len, text_decomp_len);
    try std.testing.expectEqualStrings(text_payload, text_out[0..text_decomp_len]);

    // 5. Empty payload
    const empty_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, "", 1);
    var empty_out: [16]u8 = undefined;
    const empty_decomp_len = try ZSTD_decompressDCtx(dctx, &empty_out, compressed_buf[0..empty_comp_len]);
    try std.testing.expectEqual(@as(usize, 0), empty_decomp_len);

    // 6. High-entropy incompressible 4 KiB frame
    var high_entropy_page: [4096]u8 = undefined;
    for (&high_entropy_page, 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    const high_entropy_comp_len = try ZSTD_compressCCtx(cctx, &compressed_buf, &high_entropy_page, 1);
    // Frame header (7 bytes) + Raw block header (3 bytes) + Payload (4096 bytes) = 4106 bytes
    try std.testing.expect(high_entropy_comp_len > 4096);
    try std.testing.expectEqual(@as(usize, 4106), high_entropy_comp_len);

    const high_decomp_len = try ZSTD_decompressDCtx(dctx, &decompressed_buf, compressed_buf[0..high_entropy_comp_len]);
    try std.testing.expectEqual(@as(usize, 4096), high_decomp_len);
    try std.testing.expectEqualSlices(u8, &high_entropy_page, &decompressed_buf);
}

test "zstd chunk buffer exhaustion falls back to raw block and avoids silent truncation" {
    // Allocate minimum CCtx workspace to bound max_chunks
    var small_ws: [@sizeOf(ZSTD_CCtx) + 1024]u8 = undefined;
    var d_ws: [128 * 1024]u8 = undefined;

    const cctx = (try ZSTD_CCtx.init(&small_ws));
    const dctx = (try ZSTD_DCtx.init(&d_ws));

    // Create 4096-byte payload with many alternating 8-byte runs (exceeding max_chunks)
    var payload: [4096]u8 = undefined;
    for (0..4096 / 8) |i| {
        const val: u8 = @intCast(i % 250);
        @memset(payload[i * 8 .. (i + 1) * 8], val);
    }

    var comp_buf: [8192]u8 = undefined;
    var decomp_buf: [4096]u8 = undefined;

    const comp_len = try cctx.compress(&comp_buf, &payload, 1);
    const decomp_len = try dctx.decompress(&decomp_buf, comp_buf[0..comp_len]);

    try std.testing.expectEqual(@as(usize, 4096), decomp_len);
    try std.testing.expectEqualSlices(u8, &payload, &decomp_buf);
}

test "zstd frame header accounting triggers raw fallback when total frame expands past src.len" {
    var c_ws: [128 * 1024]u8 = undefined;
    var d_ws: [128 * 1024]u8 = undefined;

    const cctx = (try ZSTD_CCtx.init(&c_ws));
    const dctx = (try ZSTD_DCtx.init(&d_ws));

    // Payload: 8 bytes run of 'A' + 4088 bytes of non-repeating pattern
    // Chunk 0: RLE (8 bytes src -> 3-byte header + 1-byte value = 4 bytes)
    // Chunk 1: Raw (4088 bytes src -> 3-byte header + 4088 bytes payload = 4091 bytes)
    // total_block_bytes = 4095 (< 4096), but out_pos is 7 bytes (frame header).
    // Total multi-chunk frame would be 7 + 4095 = 4102 bytes (> 4096).
    // With frame header accounting (out_pos + total_block_bytes >= src.len),
    // compress must recognize non-compression and take the single Raw block fallback (4106 bytes).
    var payload: [4096]u8 = undefined;
    @memset(payload[0..8], 'A');
    for (payload[8..], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    var comp_buf: [8192]u8 = undefined;
    var decomp_buf: [4096]u8 = undefined;

    const comp_len = try cctx.compress(&comp_buf, &payload, 1);
    // Should fallback to single raw block: frame header (7) + raw block header (3) + payload (4096) = 4106
    try std.testing.expectEqual(@as(usize, 4106), comp_len);

    const decomp_len = try dctx.decompress(&decomp_buf, comp_buf[0..comp_len]);
    try std.testing.expectEqual(@as(usize, 4096), decomp_len);
    try std.testing.expectEqualSlices(u8, &payload, &decomp_buf);
}

test "zstd edge cases: small payloads and compression threshold boundary" {
    var c_ws: [128 * 1024]u8 = undefined;
    var d_ws: [128 * 1024]u8 = undefined;

    const cctx = (try ZSTD_CCtx.init(&c_ws));
    const dctx = (try ZSTD_DCtx.init(&d_ws));

    // Case A: Small payload (<= 255 bytes, 6-byte frame header) where block headers cause expansion
    // src.len = 64: 8 bytes 'A' + 56 bytes raw
    // Chunk 0 (RLE): 4 bytes, Chunk 1 (Raw): 59 bytes. total_block_bytes = 63 (< 64).
    // out_pos + total_block_bytes = 6 + 63 = 69 (>= 64).
    // Must fall back to raw block: 6 (frame header) + 3 (block header) + 64 = 73 bytes.
    var small_payload: [64]u8 = undefined;
    @memset(small_payload[0..8], 'A');
    for (small_payload[8..], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    var comp_buf: [8192]u8 = undefined;
    var decomp_buf: [4096]u8 = undefined;

    const small_comp_len = try cctx.compress(&comp_buf, &small_payload, 1);
    try std.testing.expectEqual(@as(usize, 73), small_comp_len);

    const small_decomp_len = try dctx.decompress(&decomp_buf, comp_buf[0..small_comp_len]);
    try std.testing.expectEqual(@as(usize, 64), small_decomp_len);
    try std.testing.expectEqualSlices(u8, &small_payload, decomp_buf[0..small_decomp_len]);

    // Case B: Boundary where multi-chunk encoding genuinely beats src.len
    // 32 bytes 'A' (4 bytes) + 4064 bytes raw (4067 bytes).
    // total_block_bytes = 4071. out_pos (7) + 4071 = 4078 (< 4096).
    // Must retain multi-chunk encoding without raw fallback.
    var compressible_payload: [4096]u8 = undefined;
    @memset(compressible_payload[0..32], 'A');
    for (compressible_payload[32..], 0..) |*b, i| {
        b.* = @truncate((i *% 101 +% 37) & 0xFF);
    }

    const comp_bound_len = try cctx.compress(&comp_buf, &compressible_payload, 1);
    try std.testing.expectEqual(@as(usize, 4078), comp_bound_len);

    const decomp_bound_len = try dctx.decompress(&decomp_buf, comp_buf[0..comp_bound_len]);
    try std.testing.expectEqual(@as(usize, 4096), decomp_bound_len);
    try std.testing.expectEqualSlices(u8, &compressible_payload, decomp_buf[0..decomp_bound_len]);
}
