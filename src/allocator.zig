const std = @import("std");
const page = @import("page.zig");

pub const Error = error{
    InvalidPageOrder,
    PageIdOverflow,
};

pub const PageAllocator = struct {
    high_water_mark: u64,

    /// Creates an append-only allocator seeded from the committed high water mark.
    pub fn init(high_water_mark: u64) PageAllocator {
        return .{ .high_water_mark = high_water_mark };
    }

    /// Returns the first base page id that the next allocation would reserve.
    pub fn peekNextPageId(self: PageAllocator) Error!u64 {
        return std.math.add(u64, self.high_water_mark, 1) catch error.PageIdOverflow;
    }

    /// Reserves the next contiguous span of base pages.
    ///
    /// `order` follows the page-object convention: an order 0 object reserves
    /// one base page, order 1 reserves two, and so on. This allocator only
    /// appends spans after the current high water mark; it does not reclaim,
    /// split, or merge free space.
    pub fn allocateNext(self: *PageAllocator, order: u8) Error!u64 {
        const span_page_count = page.spanPageCount(order) catch return error.InvalidPageOrder;
        const start_page_id = try self.peekNextPageId();
        const last_page_offset = span_page_count - 1;
        const next_high_water_mark = std.math.add(u64, start_page_id, last_page_offset) catch return error.PageIdOverflow;

        self.high_water_mark = next_high_water_mark;
        return start_page_id;
    }

    pub fn currentHighWaterMark(self: PageAllocator) u64 {
        return self.high_water_mark;
    }
};

// ======tests======

test "peekNextPageId does not advance high water mark" {
    var page_allocator = PageAllocator.init(7);

    try std.testing.expectEqual(@as(u64, 8), try page_allocator.peekNextPageId());
    try std.testing.expectEqual(@as(u64, 8), try page_allocator.peekNextPageId());
    try std.testing.expectEqual(@as(u64, 7), page_allocator.currentHighWaterMark());
}

test "allocateNext order zero reserves one base page" {
    var page_allocator = PageAllocator.init(2);

    try std.testing.expectEqual(@as(u64, 3), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 3), page_allocator.currentHighWaterMark());
    try std.testing.expectEqual(@as(u64, 4), try page_allocator.peekNextPageId());
}

test "allocateNext order zero returns consecutive page ids" {
    var page_allocator = PageAllocator.init(11);

    try std.testing.expectEqual(@as(u64, 12), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 13), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 14), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 14), page_allocator.currentHighWaterMark());
}

test "allocateNext order one advances over two base pages" {
    var page_allocator = PageAllocator.init(20);

    try std.testing.expectEqual(@as(u64, 21), try page_allocator.allocateNext(1));
    try std.testing.expectEqual(@as(u64, 22), page_allocator.currentHighWaterMark());
}

test "allocateNext order two advances over four base pages" {
    var page_allocator = PageAllocator.init(30);

    try std.testing.expectEqual(@as(u64, 31), try page_allocator.allocateNext(2));
    try std.testing.expectEqual(@as(u64, 34), page_allocator.currentHighWaterMark());
}

test "allocateNext rejects start page overflow" {
    var page_allocator = PageAllocator.init(std.math.maxInt(u64));

    try std.testing.expectError(error.PageIdOverflow, page_allocator.peekNextPageId());
    try std.testing.expectError(error.PageIdOverflow, page_allocator.allocateNext(0));
}

test "allocateNext rejects span end overflow" {
    var page_allocator = PageAllocator.init(std.math.maxInt(u64) - 1);

    try std.testing.expectError(error.PageIdOverflow, page_allocator.allocateNext(1));
}

test "allocateNext rejects invalid order" {
    var page_allocator = PageAllocator.init(0);

    try std.testing.expectError(error.InvalidPageOrder, page_allocator.allocateNext(64));
}
