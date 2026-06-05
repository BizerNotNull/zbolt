const std = @import("std");
const page = @import("page.zig");

pub const first_data_page_id: u64 = 2;
pub const allocator_max_order: usize = @bitSizeOf(u64);

pub const Error = error{
    InvalidPageOrder,
    PageIdOverflow,
    OutOfMemory,
    InvalidFreeBlock,
    FreeBlockOverlap,
    InvalidAllocatorState,
    AllocatorStateTooLarge,
};

const FreeBlockKey = struct {
    page_id: u64,
    order: u8,
};

const FreeBlockLocation = struct {
    order: u8,
    index: usize,
};

pub const PageAllocator = struct {
    high_water_mark: u64,
    free_lists: [allocator_max_order]std.ArrayList(u64),
    free_index: std.AutoHashMap(FreeBlockKey, FreeBlockLocation),

    /// Creates an in-memory buddy allocator seeded from the committed high water mark.
    ///
    /// Free lists are intentionally volatile until allocator state pages exist; callers
    /// that need rollback semantics should clone and commit by replacement.
    pub fn init(backing_allocator: std.mem.Allocator, high_water_mark: u64) PageAllocator {
        return .{
            .high_water_mark = high_water_mark,
            .free_lists = emptyFreeLists(),
            .free_index = std.AutoHashMap(FreeBlockKey, FreeBlockLocation).init(backing_allocator),
        };
    }

    pub fn deinit(self: *PageAllocator, backing_allocator: std.mem.Allocator) void {
        for (&self.free_lists) |*free_list| {
            free_list.deinit(backing_allocator);
        }
        self.free_index.deinit();
        self.* = PageAllocator.init(backing_allocator, 0);
    }

    pub fn clone(self: PageAllocator, backing_allocator: std.mem.Allocator) Error!PageAllocator {
        var cloned = PageAllocator.init(backing_allocator, self.high_water_mark);
        errdefer cloned.deinit(backing_allocator);

        for (self.free_lists, 0..) |free_list, order_index| {
            try cloned.free_lists[order_index].ensureTotalCapacity(backing_allocator, free_list.items.len);
            cloned.free_lists[order_index].appendSliceAssumeCapacity(free_list.items);

            const order = @as(u8, @intCast(order_index));
            for (free_list.items, 0..) |page_id, index| {
                try cloned.free_index.put(.{ .page_id = page_id, .order = order }, .{
                    .order = order,
                    .index = index,
                });
            }
        }

        return cloned;
    }

    pub fn peekNextPageId(self: PageAllocator) Error!u64 {
        return appendStartAfter(self.high_water_mark);
    }

    /// Compatibility helper for append-only callers.
    ///
    /// Buddy-aware allocation should call `allocate`; this helper does not inspect
    /// free lists, does not align to buddy boundaries, and is not used by tree writes.
    pub fn allocateNext(self: *PageAllocator, order: u8) Error!u64 {
        const span_page_count = try checkedSpanPageCount(order);
        const start_page_id = try self.peekNextPageId();
        self.high_water_mark = try spanEndPageId(start_page_id, span_page_count);
        return start_page_id;
    }

    pub fn allocate(self: *PageAllocator, backing_allocator: std.mem.Allocator, order: u8) Error!u64 {
        _ = try checkedSpanPageCount(order);

        const free_order = try self.findFreeOrder(order);
        if (free_order) |source_order| {
            const page_id = self.removeFreeBlock(source_order, self.free_lists[source_order].items.len - 1);
            return try self.splitFreeBlock(backing_allocator, page_id, source_order, order);
        }

        return try self.allocateFromAppend(backing_allocator, order);
    }

    pub fn release(self: *PageAllocator, backing_allocator: std.mem.Allocator, page_id: u64, order: u8) Error!void {
        try self.validateReleasableBlock(page_id, order);
        if (self.findOverlappingFreeBlock(page_id, order) != null) return error.FreeBlockOverlap;

        var merged_page_id = page_id;
        var merged_order = order;
        while (merged_order + 1 < allocator_max_order) {
            const buddy_page_id = try buddyPageId(merged_page_id, merged_order);
            const buddy_location = self.free_index.get(.{
                .page_id = buddy_page_id,
                .order = merged_order,
            }) orelse break;

            _ = self.removeFreeBlock(buddy_location.order, buddy_location.index);
            if (buddy_page_id < merged_page_id) merged_page_id = buddy_page_id;
            merged_order += 1;
        }

        try self.insertFreeBlock(backing_allocator, merged_page_id, merged_order);
    }

    pub fn currentHighWaterMark(self: PageAllocator) u64 {
        return self.high_water_mark;
    }

    pub fn containsFreeBlock(self: PageAllocator, page_id: u64, order: u8) bool {
        return self.free_index.contains(.{ .page_id = page_id, .order = order });
    }

    pub fn freeBlockCount(self: PageAllocator) Error!usize {
        var count: usize = 0;
        for (self.free_lists) |free_list| {
            count = std.math.add(usize, count, free_list.items.len) catch return error.AllocatorStateTooLarge;
        }
        return count;
    }

    pub fn allocatorStateOrder(self: PageAllocator, base_page_size: u32) (Error || page.Error)!u8 {
        const required_size = page.allocator.bytesNeededForEntries(try self.freeBlockCount()) catch return error.AllocatorStateTooLarge;
        return orderForSize(base_page_size, required_size);
    }

    pub fn encodeStatePageAlloc(
        self: PageAllocator,
        backing_allocator: std.mem.Allocator,
        base_page_size: u32,
        page_id: u64,
        order: u8,
    ) (Error || page.Error || page.LayoutError)![]u8 {
        const span_size = try page.spanSize(base_page_size, order);
        const state_page = try backing_allocator.alloc(u8, span_size);
        errdefer backing_allocator.free(state_page);

        var entries = std.ArrayList(page.AllocatorEntry).empty;
        defer entries.deinit(backing_allocator);
        try self.appendStateEntries(backing_allocator, &entries);

        _ = page.AllocatorPage.encodeInto(state_page, .{
            .page_id = page_id,
            .page_type = .allocator,
            .count = 0,
            .order = order,
        }, entries.items) catch |err| switch (err) {
            error.AllocatorStateTooLarge => return error.AllocatorStateTooLarge,
            error.InvalidAllocatorState => return error.InvalidAllocatorState,
            else => |other| return other,
        };

        return state_page;
    }

    pub fn restoreFromStatePage(
        backing_allocator: std.mem.Allocator,
        state_page_bytes: []const u8,
        high_water_mark: u64,
        allocator_root: u64,
    ) (Error || page.Error || page.LayoutError)!PageAllocator {
        const allocator_page = page.AllocatorPage.validate(state_page_bytes) catch |err| switch (err) {
            error.InvalidAllocatorState => return error.InvalidAllocatorState,
            error.AllocatorStateTooLarge => return error.AllocatorStateTooLarge,
            else => |other| return other,
        };
        if (allocator_page.header.page_id != allocator_root) return error.InvalidAllocatorState;

        const allocator_span_end = page.spanEndPageId(allocator_root, allocator_page.header.order) catch return error.InvalidAllocatorState;
        if (allocator_span_end > high_water_mark) return error.InvalidAllocatorState;

        var restored = PageAllocator.init(backing_allocator, high_water_mark);
        errdefer restored.deinit(backing_allocator);

        var index: u32 = 0;
        while (index < allocator_page.count()) : (index += 1) {
            const entry = try allocator_page.entry(index);
            try restored.insertRestoredFreeBlock(backing_allocator, entry.page_id, entry.order, allocator_root, allocator_page.header.order);
        }

        try restored.validateCanonicalFreeLists();
        return restored;
    }

    fn findFreeOrder(self: PageAllocator, order: u8) Error!?u8 {
        _ = try checkedSpanPageCount(order);

        var candidate_order = order;
        while (candidate_order < allocator_max_order) : (candidate_order += 1) {
            if (self.free_lists[candidate_order].items.len > 0) return candidate_order;
        }

        return null;
    }

    fn splitFreeBlock(
        self: *PageAllocator,
        backing_allocator: std.mem.Allocator,
        page_id: u64,
        source_order: u8,
        target_order: u8,
    ) Error!u64 {
        var current_order = source_order;
        while (current_order > target_order) {
            current_order -= 1;
            const right_page_id = std.math.add(u64, page_id, try checkedSpanPageCount(current_order)) catch return error.PageIdOverflow;
            try self.insertFreeBlock(backing_allocator, right_page_id, current_order);
        }

        return page_id;
    }

    fn allocateFromAppend(self: *PageAllocator, backing_allocator: std.mem.Allocator, order: u8) Error!u64 {
        const span_page_count = try checkedSpanPageCount(order);
        const raw_start = try appendStartAfter(self.high_water_mark);
        const start_page_id = try alignPageIdToOrder(raw_start, order);
        if (start_page_id > raw_start) {
            try self.insertPaddingGap(backing_allocator, raw_start, start_page_id - 1);
        }

        self.high_water_mark = try spanEndPageId(start_page_id, span_page_count);
        return start_page_id;
    }

    fn insertPaddingGap(self: *PageAllocator, backing_allocator: std.mem.Allocator, start_page_id: u64, end_page_id: u64) Error!void {
        var current_page_id = start_page_id;
        while (current_page_id <= end_page_id) {
            const order = try largestGapBlockOrder(current_page_id, end_page_id);
            try self.insertFreeBlock(backing_allocator, current_page_id, order);
            current_page_id = std.math.add(u64, current_page_id, try checkedSpanPageCount(order)) catch return error.PageIdOverflow;
        }
    }

    fn insertFreeBlock(self: *PageAllocator, backing_allocator: std.mem.Allocator, page_id: u64, order: u8) Error!void {
        try self.validateFreeBlockShape(page_id, order);
        if (self.findOverlappingFreeBlock(page_id, order) != null) return error.FreeBlockOverlap;

        const order_index = @as(usize, order);
        const index = self.free_lists[order_index].items.len;
        try self.free_lists[order_index].append(backing_allocator, page_id);
        errdefer _ = self.free_lists[order_index].pop();

        try self.free_index.put(.{ .page_id = page_id, .order = order }, .{
            .order = order,
            .index = index,
        });
    }

    fn appendStateEntries(
        self: PageAllocator,
        backing_allocator: std.mem.Allocator,
        entries: *std.ArrayList(page.AllocatorEntry),
    ) Error!void {
        for (self.free_lists, 0..) |free_list, order_index| {
            const order = @as(u8, @intCast(order_index));
            for (free_list.items) |page_id| {
                try entries.append(backing_allocator, .{
                    .page_id = page_id,
                    .order = order,
                });
            }
        }
    }

    fn insertRestoredFreeBlock(
        self: *PageAllocator,
        backing_allocator: std.mem.Allocator,
        page_id: u64,
        order: u8,
        allocator_root: u64,
        allocator_order: u8,
    ) Error!void {
        try self.validateReleasableBlock(page_id, order);
        if (spansOverlap(page_id, order, allocator_root, allocator_order)) return error.InvalidAllocatorState;
        if (self.free_index.contains(.{ .page_id = page_id, .order = order })) return error.InvalidAllocatorState;
        if (self.findOverlappingFreeBlock(page_id, order) != null) return error.InvalidAllocatorState;
        if (self.containsBuddyFreeBlock(page_id, order)) return error.InvalidAllocatorState;

        const order_index = @as(usize, order);
        const index = self.free_lists[order_index].items.len;
        try self.free_lists[order_index].append(backing_allocator, page_id);
        errdefer _ = self.free_lists[order_index].pop();

        try self.free_index.put(.{ .page_id = page_id, .order = order }, .{
            .order = order,
            .index = index,
        });
    }

    fn containsBuddyFreeBlock(self: PageAllocator, page_id: u64, order: u8) bool {
        const buddy_page_id = buddyPageId(page_id, order) catch return true;
        return self.free_index.contains(.{ .page_id = buddy_page_id, .order = order });
    }

    fn validateCanonicalFreeLists(self: PageAllocator) Error!void {
        var index_count: usize = 0;
        for (self.free_lists, 0..) |free_list, order_index| {
            const order = @as(u8, @intCast(order_index));
            for (free_list.items, 0..) |page_id, index| {
                const location = self.free_index.get(.{ .page_id = page_id, .order = order }) orelse return error.InvalidAllocatorState;
                if (location.order != order or location.index != index) return error.InvalidAllocatorState;
                if (self.containsBuddyFreeBlock(page_id, order)) return error.InvalidAllocatorState;
                index_count += 1;
            }
        }
        if (index_count != self.free_index.count()) return error.InvalidAllocatorState;
    }

    fn removeFreeBlock(self: *PageAllocator, order: u8, index: usize) u64 {
        const order_index = @as(usize, order);
        const removed_page_id = self.free_lists[order_index].items[index];
        _ = self.free_index.remove(.{ .page_id = removed_page_id, .order = order });

        const last_index = self.free_lists[order_index].items.len - 1;
        const moved_page_id = self.free_lists[order_index].swapRemove(index);
        _ = moved_page_id;

        if (index != last_index) {
            const replacement_page_id = self.free_lists[order_index].items[index];
            self.free_index.putAssumeCapacity(.{ .page_id = replacement_page_id, .order = order }, .{
                .order = order,
                .index = index,
            });
        }

        return removed_page_id;
    }

    fn validateReleasableBlock(self: PageAllocator, page_id: u64, order: u8) Error!void {
        try self.validateFreeBlockShape(page_id, order);
        const span_page_count = try checkedSpanPageCount(order);
        const end_page_id = try spanEndPageId(page_id, span_page_count);
        if (end_page_id > self.high_water_mark) return error.InvalidFreeBlock;
    }

    fn validateFreeBlockShape(self: PageAllocator, page_id: u64, order: u8) Error!void {
        _ = self;
        _ = try checkedSpanPageCount(order);
        if (page_id < first_data_page_id) return error.InvalidFreeBlock;
        if (!try isAlignedToOrder(page_id, order)) return error.InvalidFreeBlock;
    }

    fn findOverlappingFreeBlock(self: PageAllocator, page_id: u64, order: u8) ?FreeBlockKey {
        const span_page_count = checkedSpanPageCount(order) catch return .{ .page_id = page_id, .order = order };
        const end_page_id = spanEndPageId(page_id, span_page_count) catch return .{ .page_id = page_id, .order = order };

        for (self.free_lists, 0..) |free_list, free_order_index| {
            const free_order = @as(u8, @intCast(free_order_index));
            const free_span_page_count = checkedSpanPageCount(free_order) catch return .{ .page_id = page_id, .order = order };
            for (free_list.items) |free_page_id| {
                const free_end_page_id = spanEndPageId(free_page_id, free_span_page_count) catch return .{ .page_id = page_id, .order = order };
                if (page_id <= free_end_page_id and free_page_id <= end_page_id) {
                    return .{ .page_id = free_page_id, .order = free_order };
                }
            }
        }

        return null;
    }
};

pub fn buddyPageId(page_id: u64, order: u8) Error!u64 {
    _ = try checkedSpanPageCount(order);
    const offset = try dataRegionOffset(page_id);
    return std.math.add(u64, first_data_page_id, offset ^ (@as(u64, 1) << @intCast(order))) catch return error.PageIdOverflow;
}

pub fn isAlignedToOrder(page_id: u64, order: u8) Error!bool {
    const span_page_count = try checkedSpanPageCount(order);
    const offset = try dataRegionOffset(page_id);
    return offset % span_page_count == 0;
}

pub fn orderForSize(base_page_size: u32, required_size: usize) (Error || page.Error)!u8 {
    if (!std.math.isPowerOfTwo(base_page_size)) return error.InvalidBasePageSize;

    var order: u8 = 0;
    while (order < allocator_max_order) : (order += 1) {
        if (try page.spanSize(base_page_size, order) >= required_size) return order;
    }

    return error.AllocatorStateTooLarge;
}

fn emptyFreeLists() [allocator_max_order]std.ArrayList(u64) {
    return [_]std.ArrayList(u64){.empty} ** allocator_max_order;
}

fn checkedSpanPageCount(order: u8) Error!u64 {
    return page.spanPageCount(order) catch return error.InvalidPageOrder;
}

fn spanEndPageId(start_page_id: u64, span_page_count: u64) Error!u64 {
    return std.math.add(u64, start_page_id, span_page_count - 1) catch return error.PageIdOverflow;
}

fn appendStartAfter(high_water_mark: u64) Error!u64 {
    const raw_start = std.math.add(u64, high_water_mark, 1) catch return error.PageIdOverflow;
    return @max(first_data_page_id, raw_start);
}

fn dataRegionOffset(page_id: u64) Error!u64 {
    if (page_id < first_data_page_id) return error.InvalidFreeBlock;
    return page_id - first_data_page_id;
}

fn alignPageIdToOrder(page_id: u64, order: u8) Error!u64 {
    const span_page_count = try checkedSpanPageCount(order);
    const offset = try dataRegionOffset(page_id);
    const aligned_offset = std.mem.alignForward(u64, offset, span_page_count);
    return std.math.add(u64, first_data_page_id, aligned_offset) catch return error.PageIdOverflow;
}

fn largestGapBlockOrder(start_page_id: u64, end_page_id: u64) Error!u8 {
    var order: u8 = 0;
    while (order + 1 < allocator_max_order) {
        const next_order = order + 1;
        const next_span_page_count = try checkedSpanPageCount(next_order);
        if (!try isAlignedToOrder(start_page_id, next_order)) break;

        const next_end_page_id = spanEndPageId(start_page_id, next_span_page_count) catch break;
        if (next_end_page_id > end_page_id) break;
        order = next_order;
    }

    return order;
}

fn spansOverlap(left_page_id: u64, left_order: u8, right_page_id: u64, right_order: u8) bool {
    const left_span = checkedSpanPageCount(left_order) catch return true;
    const right_span = checkedSpanPageCount(right_order) catch return true;
    const left_end = spanEndPageId(left_page_id, left_span) catch return true;
    const right_end = spanEndPageId(right_page_id, right_span) catch return true;
    return left_page_id <= right_end and right_page_id <= left_end;
}

// ======tests======

test "peekNextPageId does not advance high water mark" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 7);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 8), try page_allocator.peekNextPageId());
    try std.testing.expectEqual(@as(u64, 8), try page_allocator.peekNextPageId());
    try std.testing.expectEqual(@as(u64, 7), page_allocator.currentHighWaterMark());
}

test "allocateNext order zero reserves one base page" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 2);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 3), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 3), page_allocator.currentHighWaterMark());
    try std.testing.expectEqual(@as(u64, 4), try page_allocator.peekNextPageId());
}

test "allocateNext order zero returns consecutive page ids" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 11);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 12), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 13), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 14), try page_allocator.allocateNext(0));
    try std.testing.expectEqual(@as(u64, 14), page_allocator.currentHighWaterMark());
}

test "allocateNext order one advances over two base pages" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 20);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 21), try page_allocator.allocateNext(1));
    try std.testing.expectEqual(@as(u64, 22), page_allocator.currentHighWaterMark());
}

test "allocateNext order two advances over four base pages" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 30);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 31), try page_allocator.allocateNext(2));
    try std.testing.expectEqual(@as(u64, 34), page_allocator.currentHighWaterMark());
}

test "allocateNext rejects start page overflow" {
    var page_allocator = PageAllocator.init(std.testing.allocator, std.math.maxInt(u64));
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectError(error.PageIdOverflow, page_allocator.peekNextPageId());
    try std.testing.expectError(error.PageIdOverflow, page_allocator.allocateNext(0));
}

test "allocateNext rejects span end overflow" {
    var page_allocator = PageAllocator.init(std.testing.allocator, std.math.maxInt(u64) - 1);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectError(error.PageIdOverflow, page_allocator.allocateNext(1));
}

test "allocateNext rejects invalid order" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 0);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidPageOrder, page_allocator.allocateNext(64));
}

test "buddy alignment uses page two as data region origin" {
    try std.testing.expect(try isAlignedToOrder(2, 1));
    try std.testing.expect(!(try isAlignedToOrder(3, 1)));
    try std.testing.expectEqual(@as(u64, 4), try buddyPageId(2, 1));
    try std.testing.expectEqual(@as(u64, 2), try buddyPageId(4, 1));
    try std.testing.expectError(error.InvalidFreeBlock, buddyPageId(0, 0));
    try std.testing.expectError(error.InvalidFreeBlock, buddyPageId(1, 0));
}

test "allocate aligns append fallback and frees padding gap" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 2);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 4), try page_allocator.allocate(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(u64, 5), page_allocator.currentHighWaterMark());
    try std.testing.expect(page_allocator.containsFreeBlock(3, 0));
}

test "allocate decomposes larger append padding gaps" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 6);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 10), try page_allocator.allocate(std.testing.allocator, 3));
    try std.testing.expectEqual(@as(u64, 17), page_allocator.currentHighWaterMark());
    try std.testing.expect(page_allocator.containsFreeBlock(7, 0));
    try std.testing.expect(page_allocator.containsFreeBlock(8, 1));
}

test "allocate reuses released block before appending" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 4, 1);

    try std.testing.expectEqual(@as(u64, 4), try page_allocator.allocate(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(u64, 5), page_allocator.currentHighWaterMark());
}

test "allocate splits a larger free block" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 4, 1);

    try std.testing.expectEqual(@as(u64, 4), try page_allocator.allocate(std.testing.allocator, 0));
    try std.testing.expect(page_allocator.containsFreeBlock(5, 0));
}

test "release merges buddy blocks across multiple orders" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 2, 0);
    try page_allocator.release(std.testing.allocator, 3, 0);
    try page_allocator.release(std.testing.allocator, 4, 0);
    try page_allocator.release(std.testing.allocator, 5, 0);

    try std.testing.expect(page_allocator.containsFreeBlock(2, 2));
    try std.testing.expectEqual(@as(u64, 2), try page_allocator.allocate(std.testing.allocator, 2));
}

test "release rejects exact double free" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 4, 1);

    try std.testing.expectError(error.FreeBlockOverlap, page_allocator.release(std.testing.allocator, 4, 1));
}

test "release rejects descendant overlap with larger free block" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 4, 1);

    try std.testing.expectError(error.FreeBlockOverlap, page_allocator.release(std.testing.allocator, 4, 0));
}

test "release rejects ancestor overlap with smaller free block" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try page_allocator.release(std.testing.allocator, 4, 0);

    try std.testing.expectError(error.FreeBlockOverlap, page_allocator.release(std.testing.allocator, 4, 1));
}

test "release rejects invalid and out of range blocks" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFreeBlock, page_allocator.release(std.testing.allocator, 3, 1));
    try std.testing.expectError(error.InvalidFreeBlock, page_allocator.release(std.testing.allocator, 6, 0));
    try std.testing.expectError(error.InvalidPageOrder, page_allocator.release(std.testing.allocator, 4, 64));
}

test "allocate rejects span end overflow after alignment" {
    var page_allocator = PageAllocator.init(std.testing.allocator, std.math.maxInt(u64) - 1);
    defer page_allocator.deinit(std.testing.allocator);

    try std.testing.expectError(error.PageIdOverflow, page_allocator.allocate(std.testing.allocator, 1));
}

test "clone isolates allocator mutations" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 5);
    defer page_allocator.deinit(std.testing.allocator);
    try page_allocator.release(std.testing.allocator, 4, 1);

    var cloned = try page_allocator.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 4), try cloned.allocate(std.testing.allocator, 1));
    try std.testing.expect(page_allocator.containsFreeBlock(4, 1));
}

fn encodeAllocatorStateFixture(root_page_id: u64, order: u8, entries: []const page.AllocatorEntry) ![]u8 {
    const bytes = try std.testing.allocator.alloc(u8, try page.spanSize(4096, order));
    errdefer std.testing.allocator.free(bytes);
    _ = try page.AllocatorPage.encodeInto(bytes, .{
        .page_id = root_page_id,
        .page_type = .allocator,
        .count = 0,
        .order = order,
    }, entries);
    return bytes;
}

test "allocator state round trips free lists without release merging" {
    var page_allocator = PageAllocator.init(std.testing.allocator, 9);
    defer page_allocator.deinit(std.testing.allocator);
    try page_allocator.release(std.testing.allocator, 4, 1);
    try page_allocator.release(std.testing.allocator, 8, 1);

    const state_page = try page_allocator.encodeStatePageAlloc(std.testing.allocator, 4096, 6, 0);
    defer std.testing.allocator.free(state_page);

    var restored = try PageAllocator.restoreFromStatePage(std.testing.allocator, state_page, 9, 6);
    defer restored.deinit(std.testing.allocator);

    try std.testing.expect(restored.containsFreeBlock(4, 1));
    try std.testing.expect(restored.containsFreeBlock(8, 1));
    try std.testing.expectEqual(@as(u64, 9), restored.currentHighWaterMark());
}

test "allocator state restore rejects duplicate free blocks" {
    const state_page = try encodeAllocatorStateFixture(6, 0, &.{
        .{ .page_id = 4, .order = 0 },
        .{ .page_id = 4, .order = 0 },
    });
    defer std.testing.allocator.free(state_page);

    try std.testing.expectError(error.InvalidAllocatorState, PageAllocator.restoreFromStatePage(std.testing.allocator, state_page, 8, 6));
}

test "allocator state restore rejects overlapping free blocks" {
    const state_page = try encodeAllocatorStateFixture(8, 0, &.{
        .{ .page_id = 4, .order = 1 },
        .{ .page_id = 5, .order = 0 },
    });
    defer std.testing.allocator.free(state_page);

    try std.testing.expectError(error.InvalidAllocatorState, PageAllocator.restoreFromStatePage(std.testing.allocator, state_page, 8, 8));
}

test "allocator state restore rejects unaligned and out of range blocks" {
    const unaligned_page = try encodeAllocatorStateFixture(8, 0, &.{.{ .page_id = 3, .order = 1 }});
    defer std.testing.allocator.free(unaligned_page);
    try std.testing.expectError(error.InvalidFreeBlock, PageAllocator.restoreFromStatePage(std.testing.allocator, unaligned_page, 8, 8));

    const out_of_range_page = try encodeAllocatorStateFixture(8, 0, &.{.{ .page_id = 9, .order = 0 }});
    defer std.testing.allocator.free(out_of_range_page);
    try std.testing.expectError(error.InvalidFreeBlock, PageAllocator.restoreFromStatePage(std.testing.allocator, out_of_range_page, 8, 8));
}

test "allocator state restore rejects free blocks covering allocator page span" {
    const state_page = try encodeAllocatorStateFixture(6, 0, &.{.{ .page_id = 6, .order = 0 }});
    defer std.testing.allocator.free(state_page);

    try std.testing.expectError(error.InvalidAllocatorState, PageAllocator.restoreFromStatePage(std.testing.allocator, state_page, 8, 6));
}

test "allocator state restore rejects canonical buddy pairs" {
    const state_page = try encodeAllocatorStateFixture(8, 0, &.{
        .{ .page_id = 4, .order = 0 },
        .{ .page_id = 5, .order = 0 },
    });
    defer std.testing.allocator.free(state_page);

    try std.testing.expectError(error.InvalidAllocatorState, PageAllocator.restoreFromStatePage(std.testing.allocator, state_page, 8, 8));
}
