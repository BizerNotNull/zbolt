const std = @import("std");
const allocator_mod = @import("allocator.zig");
const db_mod = @import("db.zig");
const meta = @import("meta.zig");
const reclaim = @import("reclaim.zig");
const storage = @import("storage.zig");
const tree = @import("tree.zig");

pub const WriteTxError = error{
    WriteTransactionActive,
    WriteTransactionClosed,
    WriteTransactionFailed,
    NoPendingWrite,
};

pub const ReadTx = struct {
    db: ?*db_mod.DB,
    snapshot: tree.ReadSnapshot,
    txid: u64,

    /// Releases this read view.
    ///
    /// The transaction borrows the DB handle, must be used through a single
    /// mutable binding without copying, and is valid only while that DB
    /// remains open.
    pub fn deinit(self: *ReadTx) void {
        const db = self.db orelse return;
        self.db = null;
        db.reclaim.endRead(self.txid);
    }

    /// Returns an owned copy of the value visible to this read snapshot.
    pub fn get(self: *const ReadTx, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        std.debug.assert(self.db != null);
        return tree.lookupSnapshot(self.db.?, allocator, self.snapshot, key);
    }
};

pub const WriteTx = struct {
    db: *db_mod.DB,
    base_txid: u64,
    arena: std.heap.ArenaAllocator,
    working_page_allocator: allocator_mod.PageAllocator,
    view: ?UncommittedView,
    has_pending_write: bool,
    state: State,
    owns_working_page_allocator: bool,
    owns_arena: bool,

    const State = enum {
        open_clean,
        open_dirty,
        committed,
        rolled_back,
        failed,
    };

    /// Write transactions borrow the DB handle, own their working state, and
    /// must be used through a single mutable binding without copying.
    pub fn init(db: *db_mod.DB) !WriteTx {
        if (db.write_tx_active) return WriteTxError.WriteTransactionActive;
        try db.reclaim.releaseReusableIntoAllocator(db.allocator, &db.page_allocator);

        var working_page_allocator = try db.page_allocator.clone(db.allocator);
        errdefer working_page_allocator.deinit(db.allocator);

        db.write_tx_active = true;
        const base_snapshot = tree.ReadSnapshot{
            .root_page_id = db.root_page_id,
            .high_water_mark = db.high_water_mark,
        };
        var view = UncommittedView.init(db.allocator, db, base_snapshot);
        errdefer view.deinit();

        return .{
            .db = db,
            .base_txid = db.txid,
            .arena = std.heap.ArenaAllocator.init(db.allocator),
            .working_page_allocator = working_page_allocator,
            .view = view,
            .has_pending_write = false,
            .state = .open_clean,
            .owns_working_page_allocator = true,
            .owns_arena = true,
        };
    }

    pub fn put(self: *WriteTx, key: []const u8, value: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        const write_result = try tree.writePut(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            view.current_root_page_id,
            key,
            value,
        );
        try view.applyWriteResult(self.db.allocator, write_result);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    /// Ends the transaction, rolling back an active write if the caller exits
    /// without an explicit commit or rollback.
    pub fn deinit(self: *WriteTx) void {
        switch (self.state) {
            .open_clean, .open_dirty => {
                self.cleanupOwnedResources();
                self.db.write_tx_active = false;
                self.state = .rolled_back;
            },
            .committed, .rolled_back, .failed => {},
        }
    }

    pub fn commit(self: *WriteTx) !void {
        try self.ensureActiveForMutation();
        if (!self.has_pending_write) return WriteTxError.NoPendingWrite;
        errdefer self.fail();

        var staged_reclaim_pages: []const reclaim.ReleasedPage = &.{};
        if (self.view.?.reclaim_committed_pages.count() > 0) {
            try self.db.reclaim.ensurePendingCapacity(self.db.allocator, 1);
            staged_reclaim_pages = try self.view.?.ownedReclaimPagesAlloc(self.db.allocator);
        }
        errdefer if (staged_reclaim_pages.len > 0) self.db.allocator.free(staged_reclaim_pages);

        const staged_pages = try self.view.?.sortedStagedPagesAlloc(self.db.allocator);
        defer self.db.allocator.free(staged_pages);

        const baseline_page_allocator = self.working_page_allocator;
        self.working_page_allocator = movedPageAllocator(self.db.allocator);
        self.owns_working_page_allocator = false;

        var allocator_state = try db_mod.materializeAllocatorStatePage(self.db, baseline_page_allocator);
        defer self.db.allocator.free(allocator_state.bytes);
        errdefer allocator_state.page_allocator.deinit(self.db.allocator);
        std.debug.assert(self.base_txid == self.db.txid);

        const next_meta = meta.Meta{
            .page_size = self.db.page_size,
            .flags = self.db.flags,
            .root_page_id = self.view.?.current_root_page_id,
            .allocator_root = allocator_state.page_id,
            .high_water_mark = allocator_state.page_allocator.currentHighWaterMark(),
            .txid = self.db.txid + 1,
        };
        const next_meta_page = try meta.encode(self.db.allocator, next_meta);
        defer self.db.allocator.free(next_meta_page);

        const io = self.db.io_threaded.io();
        for (staged_pages) |pending_page| {
            try storage.writePageObject(&self.db.file, io, self.db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.writePageObject(&self.db.file, io, self.db.page_size, allocator_state.page_id, allocator_state.bytes);
        try storage.sync(self.db.file, io);

        const next_meta_slot = inactiveMetaSlot(self.db.meta_slot);
        try storage.writePageObject(&self.db.file, io, self.db.page_size, metaSlotPageId(next_meta_slot), next_meta_page);
        try storage.sync(self.db.file, io);

        db_mod.applyCommittedState(self.db, next_meta_slot, next_meta, allocator_state.page_allocator);
        allocator_state.page_allocator = movedPageAllocator(self.db.allocator);
        if (staged_reclaim_pages.len > 0) {
            self.db.reclaim.appendReleasedOwned(self.base_txid, staged_reclaim_pages);
            staged_reclaim_pages = &.{};
        }

        self.db.write_tx_active = false;
        self.cleanupOwnedResources();
        self.state = .committed;
    }

    pub fn rollback(self: *WriteTx) !void {
        switch (self.state) {
            .open_clean, .open_dirty => {
                self.cleanupOwnedResources();
                self.db.write_tx_active = false;
                self.state = .rolled_back;
            },
            .failed => return WriteTxError.WriteTransactionFailed,
            .committed, .rolled_back => return WriteTxError.WriteTransactionClosed,
        }
    }

    fn ensureActiveForMutation(self: *WriteTx) WriteTxError!void {
        return switch (self.state) {
            .open_clean, .open_dirty => {},
            .failed => WriteTxError.WriteTransactionFailed,
            .committed, .rolled_back => WriteTxError.WriteTransactionClosed,
        };
    }

    fn fail(self: *WriteTx) void {
        if (self.state != .open_clean and self.state != .open_dirty) return;
        self.cleanupOwnedResources();
        self.db.write_tx_active = false;
        self.state = .failed;
    }

    fn cleanupOwnedResources(self: *WriteTx) void {
        self.has_pending_write = false;

        if (self.view) |*view| {
            view.deinit();
            self.view = null;
        }

        if (self.owns_working_page_allocator) {
            self.working_page_allocator.deinit(self.db.allocator);
            self.working_page_allocator = movedPageAllocator(self.db.allocator);
            self.owns_working_page_allocator = false;
        }

        if (self.owns_arena) {
            self.arena.deinit();
            self.owns_arena = false;
        }
    }
};

const ReclaimPageKey = struct {
    page_id: u64,
    order: u8,
};

const UncommittedView = struct {
    db: *db_mod.DB,
    base_snapshot: tree.ReadSnapshot,
    current_root_page_id: u64,
    allocation_high_water_mark: u64,
    staged_pages: std.AutoHashMap(u64, tree.PendingPage),
    reclaim_committed_pages: std.AutoHashMap(ReclaimPageKey, void),

    fn init(allocator: std.mem.Allocator, db: *db_mod.DB, base_snapshot: tree.ReadSnapshot) UncommittedView {
        return .{
            .db = db,
            .base_snapshot = base_snapshot,
            .current_root_page_id = base_snapshot.root_page_id,
            .allocation_high_water_mark = base_snapshot.high_water_mark,
            .staged_pages = std.AutoHashMap(u64, tree.PendingPage).init(allocator),
            .reclaim_committed_pages = std.AutoHashMap(ReclaimPageKey, void).init(allocator),
        };
    }

    fn deinit(self: *UncommittedView) void {
        self.staged_pages.deinit();
        self.reclaim_committed_pages.deinit();
    }

    fn pageReader(self: *const UncommittedView) tree.PageReader {
        return .{
            .context = self,
            .read_page_fn = readPage,
        };
    }

    fn applyWriteResult(self: *UncommittedView, allocator: std.mem.Allocator, write_result: tree.WriteResult) !void {
        for (write_result.new_pages) |pending_page| {
            try self.staged_pages.put(pending_page.page_id, pending_page);
        }

        for (write_result.obsolete_pages) |obsolete_page| {
            if (self.staged_pages.remove(obsolete_page.page_id)) continue;
            try self.reclaim_committed_pages.put(.{
                .page_id = obsolete_page.page_id,
                .order = obsolete_page.order,
            }, {});
        }

        self.current_root_page_id = write_result.root_page_id;
        self.allocation_high_water_mark = write_result.allocation_high_water_mark;
        _ = allocator;
    }

    fn sortedStagedPagesAlloc(self: *const UncommittedView, allocator: std.mem.Allocator) ![]tree.PendingPage {
        var staged_pages = try allocator.alloc(tree.PendingPage, self.staged_pages.count());
        errdefer allocator.free(staged_pages);

        var iterator = self.staged_pages.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |pending_page| : (index += 1) {
            staged_pages[index] = pending_page.*;
        }

        std.sort.pdq(tree.PendingPage, staged_pages, {}, pendingPageLessThan);
        return staged_pages;
    }

    fn ownedReclaimPagesAlloc(self: *const UncommittedView, allocator: std.mem.Allocator) ![]reclaim.ReleasedPage {
        var reclaim_pages = try allocator.alloc(reclaim.ReleasedPage, self.reclaim_committed_pages.count());
        errdefer allocator.free(reclaim_pages);

        var iterator = self.reclaim_committed_pages.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |reclaim_key| : (index += 1) {
            reclaim_pages[index] = .{
                .page_id = reclaim_key.page_id,
                .order = reclaim_key.order,
            };
        }

        std.sort.pdq(reclaim.ReleasedPage, reclaim_pages, {}, reclaimPageLessThan);
        return reclaim_pages;
    }

    fn readPage(context: *const anyopaque, allocator: std.mem.Allocator, page_id: u64) !tree.PageRef {
        const self: *const UncommittedView = @ptrCast(@alignCast(context));
        if (self.staged_pages.get(page_id)) |pending_page| {
            return .{ .borrowed = pending_page.bytes };
        }

        return .{
            .owned = try self.db.readPageAllocAtHighWater(
                allocator,
                page_id,
                self.base_snapshot.high_water_mark,
            ),
        };
    }
};

fn pendingPageLessThan(_: void, lhs: tree.PendingPage, rhs: tree.PendingPage) bool {
    return lhs.page_id < rhs.page_id;
}

fn reclaimPageLessThan(_: void, lhs: reclaim.ReleasedPage, rhs: reclaim.ReleasedPage) bool {
    if (lhs.page_id != rhs.page_id) return lhs.page_id < rhs.page_id;
    return lhs.order < rhs.order;
}

fn movedPageAllocator(allocator: std.mem.Allocator) allocator_mod.PageAllocator {
    return allocator_mod.PageAllocator.init(allocator, 0);
}

fn inactiveMetaSlot(slot: meta.MetaSlot) meta.MetaSlot {
    return switch (slot) {
        .meta0 => .meta1,
        .meta1 => .meta0,
    };
}

fn metaSlotPageId(slot: meta.MetaSlot) u64 {
    return switch (slot) {
        .meta0 => 0,
        .meta1 => 1,
    };
}

// ======tests======
