const std = @import("std");
const errors = @import("errors.zig");

pub const magic: u32 = 0x544C425A; // "ZBLT"
pub const version: u32 = 1;
pub const encoded_size: usize = 52;

const checksum_offset = 48;

pub const Meta = struct {
    page_size: u32,
    flags: u32,
    root_page_id: u64,
    allocator_root: u64,
    // the largest page id that has ever been allocated
    high_water_mark: u64,
    txid: u64,
};

pub const MetaSlot = enum {
    meta0,
    meta1,
};

pub const SelectedMeta = struct {
    slot: MetaSlot,
    meta: Meta,
};

pub const Error = errors.MetaError;

// encode meta struct to a byte array
pub fn encode(allocator: std.mem.Allocator, meta: Meta) Error![]u8 {
    try validate(meta, meta.page_size);

    const page = try allocator.alloc(u8, meta.page_size);
    errdefer allocator.free(page);

    @memset(page, 0);

    writeInt(u32, page, 0, magic);
    writeInt(u32, page, 4, version);
    writeInt(u32, page, 8, meta.page_size);
    writeInt(u32, page, 12, meta.flags);
    writeInt(u64, page, 16, meta.root_page_id);
    writeInt(u64, page, 24, meta.allocator_root);
    writeInt(u64, page, 32, meta.high_water_mark);
    writeInt(u64, page, 40, meta.txid);
    writeInt(u32, page, checksum_offset, checksum(page));

    return page;
}

pub fn decode(page: []const u8) Error!Meta {
    try verifyChecksum(page);

    const meta = Meta{
        .page_size = readInt(u32, page, 8),
        .flags = readInt(u32, page, 12),
        .root_page_id = readInt(u64, page, 16),
        .allocator_root = readInt(u64, page, 24),
        .high_water_mark = readInt(u64, page, 32),
        .txid = readInt(u64, page, 40),
    };

    try validateMagicAndVersion(page);
    try validate(meta, page.len);

    return meta;
}

// validate meta
// pagesize must be a power of two and at least as large as the meta header
// pagesize must not less than the encoded meta size
// the page_len must equal to the meta page size
// root_page_id and allocator_root must not larger than high_water_mark
pub fn validate(meta: Meta, page_len: usize) Error!void {
    if (!std.math.isPowerOfTwo(meta.page_size)) return error.InvalidPageSize;
    if (meta.page_size < encoded_size) return error.PageTooSmall;
    if (page_len != meta.page_size) return error.PageLengthMismatch;
    if (meta.root_page_id > meta.high_water_mark) return error.RootPageOutOfRange;
    if (meta.allocator_root > meta.high_water_mark) return error.AllocatorRootOutOfRange;
}

pub fn verifyChecksum(page: []const u8) Error!void {
    if (page.len < encoded_size) return error.PageTooSmall;
    if (readInt(u32, page, checksum_offset) != checksum(page)) return error.InvalidChecksum;
}

pub fn selectNewestValid(meta0_page: []const u8, meta1_page: []const u8) Error!SelectedMeta {
    const meta0 = decode(meta0_page) catch null;
    const meta1 = decode(meta1_page) catch null;

    if (meta0 == null and meta1 == null) return error.NoValidMetaPage;
    if (meta0 != null and meta1 == null) return .{ .slot = .meta0, .meta = meta0.? };
    if (meta0 == null and meta1 != null) return .{ .slot = .meta1, .meta = meta1.? };

    if (meta0.?.txid >= meta1.?.txid) {
        return .{ .slot = .meta0, .meta = meta0.? };
    }

    return .{ .slot = .meta1, .meta = meta1.? };
}

fn validateMagicAndVersion(page: []const u8) Error!void {
    if (page.len < encoded_size) return error.PageTooSmall;
    if (readInt(u32, page, 0) != magic) return error.InvalidMagic;
    if (readInt(u32, page, 4) != version) return error.InvalidVersion;
}

fn checksum(page: []const u8) u32 {
    var scratch: [encoded_size]u8 = undefined;
    // TODO: triple crc.update may be better
    std.mem.copyForwards(u8, scratch[0..], page[0..encoded_size]);
    @memset(scratch[checksum_offset .. checksum_offset + @sizeOf(u32)], 0);
    return std.hash.Crc32.hash(scratch[0..]);
}

// little endian
fn writeInt(comptime T: type, page: []u8, offset: usize, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    std.mem.copyForwards(u8, page[offset .. offset + @sizeOf(T)], bytes[0..]);
}

// little endian
fn readInt(comptime T: type, page: []const u8, offset: usize) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.copyForwards(u8, bytes[0..], page[offset .. offset + @sizeOf(T)]);
    return std.mem.readInt(T, &bytes, .little);
}

// ======tests=====

test "encode decode round trip preserves fields" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 7,
        .root_page_id = 2,
        .allocator_root = 3,
        .high_water_mark = 9,
        .txid = 42,
    };

    const page = try encode(std.testing.allocator, meta);
    defer std.testing.allocator.free(page);

    try std.testing.expectEqual(@as(usize, meta.page_size), page.len);

    const decoded = try decode(page);
    try std.testing.expectEqualDeep(meta, decoded);
}

test "verifyChecksum accepts a valid meta page" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 1,
        .root_page_id = 2,
        .allocator_root = 2,
        .high_water_mark = 2,
        .txid = 1,
    };

    const page = try encode(std.testing.allocator, meta);
    defer std.testing.allocator.free(page);

    try verifyChecksum(page);
}

test "decode rejects page with modified payload and stale checksum" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 2,
        .high_water_mark = 4,
        .txid = 3,
    };

    const page = try encode(std.testing.allocator, meta);
    defer std.testing.allocator.free(page);

    page[16] ^= 0x01;

    try std.testing.expectError(error.InvalidChecksum, decode(page));
}

test "encode rejects non power of two page size" {
    const meta = Meta{
        .page_size = 3000,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 0,
    };

    try std.testing.expectError(error.InvalidPageSize, encode(std.testing.allocator, meta));
}

test "encode rejects page size smaller than meta header" {
    const meta = Meta{
        .page_size = 32,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 0,
    };

    try std.testing.expectError(error.PageTooSmall, encode(std.testing.allocator, meta));
}

test "encode rejects root page id larger than high water mark" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 5,
        .allocator_root = 1,
        .high_water_mark = 4,
        .txid = 0,
    };

    try std.testing.expectError(error.RootPageOutOfRange, encode(std.testing.allocator, meta));
}

test "encode rejects allocator root larger than high water mark" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 4,
        .allocator_root = 5,
        .high_water_mark = 4,
        .txid = 0,
    };

    try std.testing.expectError(error.AllocatorRootOutOfRange, encode(std.testing.allocator, meta));
}

test "decode rejects wrong magic with a valid checksum" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 0,
    };

    const page = try encode(std.testing.allocator, meta);
    defer std.testing.allocator.free(page);

    writeInt(u32, page, 0, magic + 1);
    writeInt(u32, page, checksum_offset, checksum(page));

    try std.testing.expectError(error.InvalidMagic, decode(page));
}

test "decode rejects wrong version with a valid checksum" {
    const meta = Meta{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 0,
    };

    const page = try encode(std.testing.allocator, meta);
    defer std.testing.allocator.free(page);

    writeInt(u32, page, 4, version + 1);
    writeInt(u32, page, checksum_offset, checksum(page));

    try std.testing.expectError(error.InvalidVersion, decode(page));
}

test "selectNewestValid chooses higher txid when both pages are valid" {
    const meta0_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 2,
        .high_water_mark = 2,
        .txid = 7,
    });
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 3,
        .allocator_root = 3,
        .high_water_mark = 3,
        .txid = 8,
    });
    defer std.testing.allocator.free(meta1_page);

    const selected = try selectNewestValid(meta0_page, meta1_page);
    try std.testing.expectEqual(MetaSlot.meta1, selected.slot);
    try std.testing.expectEqual(@as(u64, 8), selected.meta.txid);
}

test "selectNewestValid chooses the only valid page" {
    const meta0_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 2,
        .high_water_mark = 2,
        .txid = 7,
    });
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 3,
        .allocator_root = 3,
        .high_water_mark = 3,
        .txid = 8,
    });
    defer std.testing.allocator.free(meta1_page);

    meta1_page[12] ^= 0xFF;

    const selected = try selectNewestValid(meta0_page, meta1_page);
    try std.testing.expectEqual(MetaSlot.meta0, selected.slot);
    try std.testing.expectEqual(@as(u64, 7), selected.meta.txid);
}

test "selectNewestValid rejects when both pages are invalid" {
    const meta0_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 1,
    });
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .txid = 2,
    });
    defer std.testing.allocator.free(meta1_page);

    meta0_page[8] ^= 0xFF;
    meta1_page[8] ^= 0xFF;

    try std.testing.expectError(error.NoValidMetaPage, selectNewestValid(meta0_page, meta1_page));
}

test "selectNewestValid prefers meta0 when txid ties" {
    const meta0_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 2,
        .high_water_mark = 2,
        .txid = 9,
    });
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try encode(std.testing.allocator, .{
        .page_size = 4096,
        .flags = 1,
        .root_page_id = 3,
        .allocator_root = 3,
        .high_water_mark = 3,
        .txid = 9,
    });
    defer std.testing.allocator.free(meta1_page);

    const selected = try selectNewestValid(meta0_page, meta1_page);
    try std.testing.expectEqual(MetaSlot.meta0, selected.slot);
    try std.testing.expectEqual(@as(u32, 0), selected.meta.flags);
}
