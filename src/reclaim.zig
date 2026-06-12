const std = @import("std");
const allocator_mod = @import("allocator.zig");
const page = @import("page.zig");

pub const ReleasedPage = struct {
    page_id: u64,
    order: u8,
};

const PendingRelease = struct {
    visible_through_txid: u64,
    pages: []const ReleasedPage,
};

pub const State = struct {
    active_readers: std.AutoHashMap(u64, usize),
    active_reader_count: usize,
    pending: std.ArrayList(PendingRelease),

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .active_readers = std.AutoHashMap(u64, usize).init(allocator),
            .active_reader_count = 0,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.pending.items) |pending_release| {
            allocator.free(pending_release.pages);
        }
        self.pending.deinit(allocator);
        self.active_readers.deinit();
        self.* = State.init(allocator);
    }

    pub fn beginRead(self: *State, reader_txid: u64) !void {
        const gop = try self.active_readers.getOrPut(reader_txid);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
        self.active_reader_count += 1;
    }

    pub fn endRead(self: *State, reader_txid: u64) void {
        const count_ptr = self.active_readers.getPtr(reader_txid) orelse unreachable;
        std.debug.assert(count_ptr.* > 0);

        count_ptr.* -= 1;
        self.active_reader_count -= 1;

        if (count_ptr.* == 0) {
            const removed = self.active_readers.remove(reader_txid);
            std.debug.assert(removed);
        }
    }

    pub fn activeReaderCount(self: *const State) usize {
        return self.active_reader_count;
    }

    pub fn oldestActiveReaderTxid(self: *const State) ?u64 {
        var iterator = self.active_readers.iterator();
        var oldest_txid: ?u64 = null;
        while (iterator.next()) |entry| {
            const txid = entry.key_ptr.*;
            if (oldest_txid == null or txid < oldest_txid.?) {
                oldest_txid = txid;
            }
        }
        return oldest_txid;
    }

    pub fn isSafeToReuse(self: *const State, visible_through_txid: u64) bool {
        const oldest_reader_txid = self.oldestActiveReaderTxid() orelse return true;
        return oldest_reader_txid > visible_through_txid;
    }

    pub fn ensurePendingCapacity(self: *State, allocator: std.mem.Allocator, additional: usize) !void {
        try self.pending.ensureUnusedCapacity(allocator, additional);
    }

    pub fn appendReleasedOwned(self: *State, visible_through_txid: u64, released_pages_owned: []const ReleasedPage) void {
        std.debug.assert(released_pages_owned.len > 0);

        self.pending.appendAssumeCapacity(.{
            .visible_through_txid = visible_through_txid,
            .pages = released_pages_owned,
        });
    }

    pub fn initFromStateRecords(allocator: std.mem.Allocator, records: []const page.AllocatorStateRecord) !State {
        var state = State.init(allocator);
        errdefer state.deinit(allocator);

        var sorted_records = try allocator.dupe(page.AllocatorStateRecord, records);
        defer allocator.free(sorted_records);
        std.sort.pdq(page.AllocatorStateRecord, sorted_records, {}, stateRecordLessThan);

        try state.pending.ensureTotalCapacity(allocator, sorted_records.len);
        var start: usize = 0;
        while (start < sorted_records.len) {
            const visible_through_txid = sorted_records[start].visible_through_txid;
            var end = start + 1;
            while (end < sorted_records.len and sorted_records[end].visible_through_txid == visible_through_txid) : (end += 1) {}

            const pages = try allocator.alloc(ReleasedPage, end - start);
            for (sorted_records[start..end], 0..) |record, index| {
                std.debug.assert(record.kind == .pending);
                pages[index] = .{
                    .page_id = record.page_id,
                    .order = record.order,
                };
            }
            state.pending.appendAssumeCapacity(.{
                .visible_through_txid = visible_through_txid,
                .pages = pages,
            });

            start = end;
        }

        return state;
    }

    fn stateRecordLessThan(_: void, lhs: page.AllocatorStateRecord, rhs: page.AllocatorStateRecord) bool {
        if (lhs.visible_through_txid != rhs.visible_through_txid) {
            return lhs.visible_through_txid < rhs.visible_through_txid;
        }
        if (lhs.page_id != rhs.page_id) {
            return lhs.page_id < rhs.page_id;
        }
        return lhs.order < rhs.order;
    }

    pub fn appendStateRecords(
        self: *const State,
        allocator: std.mem.Allocator,
        records: *std.ArrayList(page.AllocatorStateRecord),
    ) !void {
        for (self.pending.items) |pending_release| {
            for (pending_release.pages) |released_page| {
                try records.append(allocator, .{
                    .kind = .pending,
                    .page_id = released_page.page_id,
                    .order = released_page.order,
                    .visible_through_txid = pending_release.visible_through_txid,
                });
            }
        }
    }

    pub fn releaseReusableIntoAllocator(
        self: *State,
        backing_allocator: std.mem.Allocator,
        page_allocator: *allocator_mod.PageAllocator,
    ) !void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending_release = self.pending.items[index];
            if (!self.isSafeToReuse(pending_release.visible_through_txid)) {
                index += 1;
                continue;
            }

            for (pending_release.pages) |released_page| {
                try page_allocator.release(
                    backing_allocator,
                    released_page.page_id,
                    released_page.order,
                );
            }

            backing_allocator.free(pending_release.pages);
            _ = self.pending.swapRemove(index);
        }
    }
};

// ======tests======

test "reclaim state groups restored records by visible txid" {
    var state = try State.initFromStateRecords(std.testing.allocator, &.{
        .{ .kind = .pending, .page_id = 8, .order = 0, .visible_through_txid = 2 },
        .{ .kind = .pending, .page_id = 4, .order = 0, .visible_through_txid = 1 },
        .{ .kind = .pending, .page_id = 5, .order = 0, .visible_through_txid = 1 },
    });
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), state.pending.items.len);
    try std.testing.expectEqual(@as(u64, 1), state.pending.items[0].visible_through_txid);
    try std.testing.expectEqual(@as(usize, 2), state.pending.items[0].pages.len);
    try std.testing.expectEqual(@as(u64, 2), state.pending.items[1].visible_through_txid);
    try std.testing.expectEqual(@as(usize, 1), state.pending.items[1].pages.len);
}
