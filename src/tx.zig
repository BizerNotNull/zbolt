const std = @import("std");
const allocator_mod = @import("allocator.zig");
const db_mod = @import("db.zig");
const meta = @import("meta.zig");
const storage = @import("storage.zig");
const tree = @import("tree.zig");

pub const WriteTxError = error{
    WriteTransactionActive,
    WriteTransactionClosed,
    WriteTransactionFailed,
    WriteTransactionAlreadyUsed,
    NoPendingWrite,
};

pub const ReadTx = struct {
    db: *db_mod.DB,
    snapshot: tree.ReadSnapshot,
    txid: u64,

    /// Releases this read view.
    ///
    /// The transaction borrows the DB handle and is valid only while that DB
    /// remains open. The no-op lifecycle hook is where future reader tracking
    /// can detach snapshots before reclaimed pages are reused.
    pub fn deinit(self: *ReadTx) void {
        _ = self;
    }

    /// Returns an owned copy of the value visible to this read snapshot.
    pub fn get(self: *const ReadTx, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return tree.lookupSnapshot(self.db, allocator, self.snapshot, key);
    }
};

pub const WriteTx = struct {
    db: *db_mod.DB,
    snapshot: tree.ReadSnapshot,
    base_txid: u64,
    arena: std.heap.ArenaAllocator,
    working_page_allocator: allocator_mod.PageAllocator,
    write_result: ?tree.WriteResult,
    put_attempted: bool,
    state: State,
    owns_working_page_allocator: bool,
    owns_arena: bool,

    const State = enum {
        active,
        committed,
        rolled_back,
        failed,
    };

    /// Write transactions borrow the DB handle, own their working state, and
    /// must be used through a single mutable binding without copying.
    pub fn init(db: *db_mod.DB) !WriteTx {
        if (db.write_tx_active) return WriteTxError.WriteTransactionActive;

        var working_page_allocator = try db.page_allocator.clone(db.allocator);
        errdefer working_page_allocator.deinit(db.allocator);

        db.write_tx_active = true;
        return .{
            .db = db,
            .snapshot = .{
                .root_page_id = db.root_page_id,
                .high_water_mark = db.high_water_mark,
            },
            .base_txid = db.txid,
            .arena = std.heap.ArenaAllocator.init(db.allocator),
            .working_page_allocator = working_page_allocator,
            .write_result = null,
            .put_attempted = false,
            .state = .active,
            .owns_working_page_allocator = true,
            .owns_arena = true,
        };
    }

    pub fn put(self: *WriteTx, key: []const u8, value: []const u8) !void {
        try self.ensureActiveForMutation();
        if (self.put_attempted) return WriteTxError.WriteTransactionAlreadyUsed;
        self.put_attempted = true;

        self.write_result = try tree.writePut(
            self.db,
            self.arena.allocator(),
            &self.working_page_allocator,
            key,
            value,
        );
    }

    /// Ends the transaction, rolling back an active write if the caller exits
    /// without an explicit commit or rollback.
    pub fn deinit(self: *WriteTx) void {
        switch (self.state) {
            .active => {
                self.cleanupOwnedResources();
                self.db.write_tx_active = false;
                self.state = .rolled_back;
            },
            .committed, .rolled_back, .failed => {},
        }
    }

    pub fn commit(self: *WriteTx) !void {
        try self.ensureActiveForMutation();
        const write_result = self.write_result orelse return WriteTxError.NoPendingWrite;
        errdefer self.fail();

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
            .root_page_id = write_result.root_page_id,
            .allocator_root = allocator_state.page_id,
            .high_water_mark = allocator_state.page_allocator.currentHighWaterMark(),
            .txid = self.db.txid + 1,
        };
        const next_meta_page = try meta.encode(self.db.allocator, next_meta);
        defer self.db.allocator.free(next_meta_page);

        const io = self.db.io_threaded.io();
        for (write_result.pages) |pending_page| {
            try storage.writePageObject(&self.db.file, io, self.db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.writePageObject(&self.db.file, io, self.db.page_size, allocator_state.page_id, allocator_state.bytes);
        try storage.sync(self.db.file, io);

        const next_meta_slot = inactiveMetaSlot(self.db.meta_slot);
        try storage.writePageObject(&self.db.file, io, self.db.page_size, metaSlotPageId(next_meta_slot), next_meta_page);
        try storage.sync(self.db.file, io);

        db_mod.applyCommittedState(self.db, next_meta_slot, next_meta, allocator_state.page_allocator);
        allocator_state.page_allocator = movedPageAllocator(self.db.allocator);

        self.db.write_tx_active = false;
        self.cleanupOwnedResources();
        self.state = .committed;
    }

    pub fn rollback(self: *WriteTx) !void {
        switch (self.state) {
            .active => {
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
            .active => {},
            .failed => WriteTxError.WriteTransactionFailed,
            .committed, .rolled_back => WriteTxError.WriteTransactionClosed,
        };
    }

    fn fail(self: *WriteTx) void {
        if (self.state != .active) return;
        self.cleanupOwnedResources();
        self.db.write_tx_active = false;
        self.state = .failed;
    }

    fn cleanupOwnedResources(self: *WriteTx) void {
        self.write_result = null;
        self.put_attempted = false;

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
