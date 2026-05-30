const std = @import("std");
const errors = @import("errors.zig");

pub const header_size: usize = 16;
const page_id_offset: usize = 0;
const page_type_offset: usize = 8;
const order_offset: usize = 9;
const count_offset: usize = 10;
const reserved_offset: usize = 12;

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

pub const Error = errors.PageError;

pub fn encodeHeader(page: []u8, header: Header) Error!void {
    if (page.len < header_size) return error.PageTooSmall;

    writeInt(u64, page, page_id_offset, header.page_id);
    page[page_type_offset] = @intFromEnum(header.page_type);
    page[order_offset] = header.order;
    writeInt(u16, page, count_offset, header.count);
    writeInt(u32, page, reserved_offset, 0);
}

pub fn decodeHeader(page: []const u8) Error!Header {
    if (page.len < header_size) return error.PageTooSmall;

    return .{
        .page_id = readInt(u64, page, page_id_offset),
        .page_type = try decodePageType(page[page_type_offset]),
        .count = readInt(u16, page, count_offset),
        .order = page[order_offset],
    };
}

pub fn spanSize(base_page_size: u32, order: u8) Error!usize {
    if (!std.math.isPowerOfTwo(base_page_size)) return error.InvalidBasePageSize;

    var result = @as(u64, base_page_size);
    var i: u8 = 0;
    while (i < order) : (i += 1) {
        const doubled = std.math.mul(u64, result, 2) catch return error.SpanSizeOverflow;
        result = doubled;
    }

    return std.math.cast(usize, result) orelse return error.SpanSizeOverflow;
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

// TODO: repeat with meta.zig
fn writeInt(comptime T: type, page: []u8, offset: usize, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    std.mem.copyForwards(u8, page[offset .. offset + @sizeOf(T)], bytes[0..]);
}

// TODO: repeat with meta.zig
fn readInt(comptime T: type, page: []const u8, offset: usize) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.copyForwards(u8, bytes[0..], page[offset .. offset + @sizeOf(T)]);
    return std.mem.readInt(T, &bytes, .little);
}

// ==========tests==========

test "encodeHeader decodeHeader round trip preserves fields" {
    var page = [_]u8{0} ** 64;
    const header = Header{
        .page_id = 42,
        .page_type = .leaf,
        .count = 7,
        .order = 2,
    };

    try encodeHeader(page[0..], header);
    const decoded = try decodeHeader(page[0..]);

    try std.testing.expectEqualDeep(header, decoded);
}

test "decodeHeader rejects invalid page type" {
    var page = [_]u8{0} ** header_size;
    writeInt(u64, page[0..], page_id_offset, 1);
    page[page_type_offset] = 255;

    try std.testing.expectError(error.InvalidPageType, decodeHeader(page[0..]));
}

test "encodeHeader rejects page shorter than header" {
    var page = [_]u8{0} ** (header_size - 1);

    try std.testing.expectError(error.PageTooSmall, encodeHeader(page[0..], .{
        .page_id = 1,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }));
}

test "decodeHeader rejects page shorter than header" {
    var page = [_]u8{0} ** (header_size - 1);

    try std.testing.expectError(error.PageTooSmall, decodeHeader(page[0..]));
}

test "spanSize uses base page size when order is zero" {
    try std.testing.expectEqual(@as(usize, 4096), try spanSize(4096, 0));
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

test "decodeHeader leaves payload bytes untouched" {
    var page = [_]u8{0} ** 64;
    @memset(page[header_size..], 0xAB);

    try encodeHeader(page[0..], .{
        .page_id = 9,
        .page_type = .allocator,
        .count = 3,
        .order = 1,
    });

    _ = try decodeHeader(page[0..]);

    for (page[header_size..]) |byte| {
        try std.testing.expectEqual(@as(u8, 0xAB), byte);
    }
}
