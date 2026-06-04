const std = @import("std");
const errors = @import("errors.zig");

pub const header_size: usize = 16;
pub const data_header_size: usize = 24;

const page_id_offset: usize = 0;
const page_type_offset: usize = 8;
const order_offset: usize = 9;
const count_offset: usize = 10;
const reserved_offset: usize = 12;

const lower_offset: usize = header_size;
const upper_offset: usize = header_size + 2;
const data_flags_offset: usize = header_size + 4;
const data_reserved_offset: usize = header_size + 6;

pub const PageType = enum(u8) {
    meta = 1,
    branch = 2,
    leaf = 3,
    allocator = 4,
};

pub const Header = struct {
    page_id: u64,
    page_type: PageType,
    count: u16,
    order: u8,
};

pub const DataHeader = struct {
    lower: u16,
    upper: u16,
    flags: u16,
};

pub const Error = errors.PageError;
pub const LayoutError = errors.PageLayoutError;

pub const leaf = @import("page/leaf.zig");
pub const branch = @import("page/branch.zig");

pub const LeafEntry = leaf.Entry;
pub const LeafEntryView = leaf.EntryView;
pub const LeafPage = leaf.LeafPage;
pub const BranchEntry = branch.Entry;
pub const BranchEntryView = branch.EntryView;
pub const BranchPage = branch.BranchPage;

pub fn encodeHeader(page_bytes: []u8, header: Header) Error!void {
    if (page_bytes.len < header_size) return error.PageTooSmall;

    writeInt(u64, page_bytes, page_id_offset, header.page_id);
    page_bytes[page_type_offset] = @intFromEnum(header.page_type);
    page_bytes[order_offset] = header.order;
    writeInt(u16, page_bytes, count_offset, header.count);
    writeInt(u32, page_bytes, reserved_offset, 0);
}

pub fn decodeHeader(page_bytes: []const u8) Error!Header {
    if (page_bytes.len < header_size) return error.PageTooSmall;

    return .{
        .page_id = readInt(u64, page_bytes, page_id_offset),
        .page_type = try decodePageType(page_bytes[page_type_offset]),
        .count = readInt(u16, page_bytes, count_offset),
        .order = page_bytes[order_offset],
    };
}

pub fn encodeDataHeader(page_bytes: []u8, header: DataHeader) (Error || LayoutError)!void {
    try ensureDataHeaderCapacity(page_bytes);

    writeInt(u16, page_bytes, lower_offset, header.lower);
    writeInt(u16, page_bytes, upper_offset, header.upper);
    writeInt(u16, page_bytes, data_flags_offset, header.flags);
    writeInt(u16, page_bytes, data_reserved_offset, 0);
}

pub fn decodeDataHeader(page_bytes: []const u8) (Error || LayoutError)!DataHeader {
    try ensureDataHeaderCapacity(page_bytes);

    return .{
        .lower = readInt(u16, page_bytes, lower_offset),
        .upper = readInt(u16, page_bytes, upper_offset),
        .flags = readInt(u16, page_bytes, data_flags_offset),
    };
}

pub fn ensureDataHeaderCapacity(page_bytes: []const u8) Error!void {
    if (page_bytes.len < data_header_size) return error.PageTooSmall;
}

pub fn validateDataBounds(page_len: usize, lower: u16, upper: u16) LayoutError!void {
    // `lower` grows forward and `upper` grows backward. If they cross, slot metadata
    // and payload bytes have overlapped, so we reject the page before exposing slices.
    if (lower < data_header_size) return error.InvalidPageLayout;
    if (lower > upper) return error.InvalidPageLayout;
    if (upper > page_len) return error.InvalidPageLayout;
}

pub fn validatePageType(actual: PageType, expected: PageType) LayoutError!void {
    if (actual != expected) return error.UnexpectedPageType;
}

pub fn validateEntryIndex(count: u16, index: u16) LayoutError!void {
    if (index >= count) return error.EntryOutOfBounds;
}

pub fn checkedCastU16(value: usize) LayoutError!u16 {
    return std.math.cast(u16, value) orelse error.PageFull;
}

pub fn checkedAdd(base: usize, extra: usize) LayoutError!usize {
    return std.math.add(usize, base, extra) catch error.InvalidPageLayout;
}

pub fn validateRange(page_len: usize, offset: usize, len: usize) LayoutError!void {
    const end = checkedAdd(offset, len) catch return error.EntryOutOfBounds;
    if (end > page_len) return error.EntryOutOfBounds;
}

pub fn spanPageCount(order: u8) Error!u64 {
    if (order >= @bitSizeOf(u64)) return error.InvalidPageOrder;
    return @as(u64, 1) << @intCast(order);
}

pub fn spanEndPageId(start_page_id: u64, order: u8) Error!u64 {
    const page_count = try spanPageCount(order);
    return std.math.add(u64, start_page_id, page_count - 1) catch error.PageIdOverflow;
}

pub fn spanSize(base_page_size: u32, order: u8) Error!usize {
    if (!std.math.isPowerOfTwo(base_page_size)) return error.InvalidBasePageSize;

    const page_count = try spanPageCount(order);
    const result = std.math.mul(u64, base_page_size, page_count) catch return error.SpanSizeOverflow;

    return std.math.cast(usize, result) orelse return error.SpanSizeOverflow;
}

pub fn maxOrderForSpanSize(base_page_size: u32, max_span_size: usize) Error!u8 {
    if (!std.math.isPowerOfTwo(base_page_size)) return error.InvalidBasePageSize;
    if (base_page_size > max_span_size) return error.InvalidBasePageSize;

    var order: u8 = 0;
    while (true) {
        const next_order = order + 1;
        if (next_order >= @bitSizeOf(u64)) return order;

        const next_size = spanSize(base_page_size, next_order) catch return order;
        if (next_size > max_span_size) return order;
        order = next_order;
    }
}

pub fn writeInt(comptime T: type, page_bytes: []u8, offset: usize, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    std.mem.copyForwards(u8, page_bytes[offset .. offset + @sizeOf(T)], bytes[0..]);
}

pub fn readInt(comptime T: type, page_bytes: []const u8, offset: usize) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.copyForwards(u8, bytes[0..], page_bytes[offset .. offset + @sizeOf(T)]);
    return std.mem.readInt(T, &bytes, .little);
}

fn decodePageType(raw: u8) Error!PageType {
    return switch (raw) {
        @intFromEnum(PageType.meta) => .meta,
        @intFromEnum(PageType.branch) => .branch,
        @intFromEnum(PageType.leaf) => .leaf,
        @intFromEnum(PageType.allocator) => .allocator,
        else => error.InvalidPageType,
    };
}

// ======tests======

test "encodeHeader decodeHeader round trip preserves fields" {
    var page_bytes = [_]u8{0} ** 64;
    const header = Header{
        .page_id = 42,
        .page_type = .leaf,
        .count = 7,
        .order = 2,
    };

    try encodeHeader(page_bytes[0..], header);
    const decoded = try decodeHeader(page_bytes[0..]);

    try std.testing.expectEqualDeep(header, decoded);
}

test "decodeHeader rejects invalid page type" {
    var page_bytes = [_]u8{0} ** header_size;
    writeInt(u64, page_bytes[0..], page_id_offset, 1);
    page_bytes[page_type_offset] = 255;

    try std.testing.expectError(error.InvalidPageType, decodeHeader(page_bytes[0..]));
}

test "encodeHeader rejects page shorter than header" {
    var page_bytes = [_]u8{0} ** (header_size - 1);

    try std.testing.expectError(error.PageTooSmall, encodeHeader(page_bytes[0..], .{
        .page_id = 1,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }));
}

test "decodeHeader rejects page shorter than header" {
    var page_bytes = [_]u8{0} ** (header_size - 1);

    try std.testing.expectError(error.PageTooSmall, decodeHeader(page_bytes[0..]));
}

test "encodeDataHeader decodeDataHeader round trip preserves fields" {
    var page_bytes = [_]u8{0} ** data_header_size;
    const header = DataHeader{
        .lower = data_header_size,
        .upper = data_header_size,
        .flags = 3,
    };

    try encodeDataHeader(page_bytes[0..], header);
    const decoded = try decodeDataHeader(page_bytes[0..]);

    try std.testing.expectEqualDeep(header, decoded);
}

test "validateDataBounds accepts empty-page bounds" {
    try validateDataBounds(4096, data_header_size, 4096);
}

test "validateDataBounds rejects lower larger than upper" {
    try std.testing.expectError(error.InvalidPageLayout, validateDataBounds(4096, 40, 32));
}

test "spanSize uses base page size when order is zero" {
    try std.testing.expectEqual(@as(usize, 4096), try spanSize(4096, 0));
}

test "spanPageCount shifts by order" {
    try std.testing.expectEqual(@as(u64, 1), try spanPageCount(0));
    try std.testing.expectEqual(@as(u64, 2), try spanPageCount(1));
    try std.testing.expectEqual(@as(u64, 4), try spanPageCount(2));
}

test "spanPageCount rejects invalid order" {
    try std.testing.expectError(error.InvalidPageOrder, spanPageCount(64));
}

test "spanEndPageId returns inclusive end page id" {
    try std.testing.expectEqual(@as(u64, 11), try spanEndPageId(8, 2));
}

test "spanEndPageId rejects page id overflow" {
    try std.testing.expectError(error.PageIdOverflow, spanEndPageId(std.math.maxInt(u64), 1));
}

test "spanSize shifts by order" {
    try std.testing.expectEqual(@as(usize, 32768), try spanSize(4096, 3));
}

test "spanSize rejects non power of two base page size" {
    try std.testing.expectError(error.InvalidBasePageSize, spanSize(3000, 1));
}

test "spanSize rejects overflow" {
    try std.testing.expectError(error.SpanSizeOverflow, spanSize(1 << 31, 33));
}

test "maxOrderForSpanSize derives u16-bounded tree span" {
    try std.testing.expectEqual(@as(u8, 3), try maxOrderForSpanSize(4096, std.math.maxInt(u16)));
    try std.testing.expectError(error.InvalidBasePageSize, maxOrderForSpanSize(65536, std.math.maxInt(u16)));
}

test "decodeHeader leaves payload bytes untouched" {
    var page_bytes = [_]u8{0} ** 64;
    @memset(page_bytes[header_size..], 0xAB);

    try encodeHeader(page_bytes[0..], .{
        .page_id = 9,
        .page_type = .allocator,
        .count = 3,
        .order = 1,
    });

    _ = try decodeHeader(page_bytes[0..]);

    for (page_bytes[header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xAB), byte);
    }
}
