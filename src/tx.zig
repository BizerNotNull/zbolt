const std = @import("std");
const allocator_mod = @import("allocator.zig");
const db_mod = @import("db.zig");
const meta = @import("meta.zig");
const namespace = @import("namespace.zig");
const page = @import("page.zig");
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
    snapshot_source: tree.SnapshotSource,
    txid: u64,

    /// Releases this read view.
    ///
    /// The transaction borrows the DB handle, must be used through a single
    /// mutable binding without copying, and is valid only while that DB
    /// remains open.
    pub fn deinit(self: *ReadTx) void {
        const db = self.db orelse return;
        self.db = null;
        self.snapshot_source.file.close(self.snapshot_source.io);
        db.reclaim.endRead(self.txid);
    }

    /// Returns an owned copy of the value visible to this read snapshot.
    pub fn get(self: *const ReadTx, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        std.debug.assert(self.db != null);
        const entry = try tree.lookupEntrySnapshotSource(&self.snapshot_source, allocator, key);
        return rootEntryValueOrError(allocator, entry);
    }

    /// Returns an owned copy of the value stored inside `bucket` for `key`.
    pub fn getInBucket(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        std.debug.assert(self.db != null);
        const bucket_root_page_id = try self.bucketRootPageId(allocator, bucket);
        const entry = try tree.lookupEntrySnapshotSourceAtRoot(&self.snapshot_source, allocator, bucket_root_page_id, key);
        return rootEntryValueOrError(allocator, entry);
    }

    /// Returns whether `bucket` exists in this snapshot and is a bucket namespace entry.
    pub fn bucketExists(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        std.debug.assert(self.db != null);
        const entry = try tree.lookupEntrySnapshotSource(&self.snapshot_source, allocator, bucket);
        return try lookupEntryIsBucket(allocator, entry);
    }

    /// Returns the top-level bucket names visible in this snapshot in key order.
    pub fn bucketNamesAlloc(self: *const ReadTx, allocator: std.mem.Allocator) !namespace.BucketNames {
        std.debug.assert(self.db != null);
        var bucket_cursor = self.cursor();
        defer bucket_cursor.deinit();
        return collectBucketNamesAlloc(&bucket_cursor, allocator);
    }

    fn bucketRootPageId(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8) !u64 {
        const entry = try tree.lookupEntrySnapshotSource(&self.snapshot_source, allocator, bucket);
        return try bucketRootPageIdFromLookup(allocator, entry);
    }

    /// Opens a read-only cursor pinned to this transaction's snapshot.
    pub fn cursor(self: *const ReadTx) tree.Cursor {
        std.debug.assert(self.db != null);
        return tree.Cursor.init(
            &self.snapshot_source,
            &self.db,
            self.db.?.allocator,
            self.snapshot.root_page_id,
        );
    }

    /// Opens a read-only cursor pinned to the snapshot root of `bucket`.
    pub fn cursorInBucket(self: *const ReadTx, bucket: []const u8) !tree.Cursor {
        std.debug.assert(self.db != null);
        const bucket_root_page_id = try self.bucketRootPageId(self.db.?.allocator, bucket);
        return tree.Cursor.init(
            &self.snapshot_source,
            &self.db,
            self.db.?.allocator,
            bucket_root_page_id,
        );
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
        try ensureRootKeyMutable(view.pageReader(), self.arena.allocator(), view.current_root_page_id, key);
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
        try view.applyRootWriteResult(self.db.allocator, write_result);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn delete(self: *WriteTx, key: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        try ensureRootKeyMutable(view.pageReader(), self.arena.allocator(), view.current_root_page_id, key);
        const delete_mutation = try tree.writeDelete(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            view.current_root_page_id,
            key,
        );
        switch (delete_mutation) {
            .unchanged => {},
            .changed => |write_result| {
                try view.applyRootWriteResult(self.db.allocator, write_result);
                self.has_pending_write = true;
                self.state = .open_dirty;
            },
        }
    }

    pub fn createBucket(self: *WriteTx, bucket: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        const existing = try tree.lookupEntryPageReader(view.pageReader(), self.arena.allocator(), view.current_root_page_id, bucket);
        if (existing) |owned_entry| {
            var owned = owned_entry;
            defer owned.deinit(self.arena.allocator());
            if (namespace.isBucketFlags(owned.flags)) return error.BucketAlreadyExists;
            return error.BucketNameConflict;
        }

        // Buckets are indexed in the root tree, but each bucket still owns an
        // independent subtree rooted at its own empty leaf page.
        const empty_root_page = try tree.allocateEmptyLeafPageAlloc(self.arena.allocator(), self.db.page_size);
        const bucket_root_page_id = try view.stageAllocatedPage(self.db.allocator, &self.working_page_allocator, self.db.page_size, empty_root_page);
        const bucket_record = try namespace.encodeBucketRecord(bucket_root_page_id);
        const write_result = try tree.writePutWithFlags(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            view.current_root_page_id,
            bucket,
            bucket_record[0..],
            namespace.bucket_entry_flag,
        );
        try view.applyRootWriteResult(self.db.allocator, write_result);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn deleteBucket(self: *WriteTx, bucket: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        const bucket_root_page_id = try currentBucketRootPageId(view, self.arena.allocator(), bucket);

        const delete_bucket_result = try tree.writeDelete(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            view.current_root_page_id,
            bucket,
        );
        switch (delete_bucket_result) {
            .unchanged => return error.BucketNotFound,
            .changed => |write_result| try view.applyRootWriteResult(self.db.allocator, write_result),
        }

        // Removing the bucket name only detaches the namespace entry. The
        // previous bucket subtree remains visible to older snapshots, so its
        // committed pages must enter reclaim as a whole.
        const released_pages = try collectCommittedTreePagesAlloc(view.pageReader(), self.arena.allocator(), bucket_root_page_id);
        defer self.arena.allocator().free(released_pages);
        try view.appendReleasedPages(self.db.allocator, released_pages);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn putInBucket(self: *WriteTx, bucket: []const u8, key: []const u8, value: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        const bucket_root_page_id = try currentBucketRootPageId(view, self.arena.allocator(), bucket);
        const bucket_write = try tree.writePut(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            bucket_root_page_id,
            key,
            value,
        );
        try view.applyDetachedWriteResult(self.db.allocator, bucket_write);

        const bucket_record = try namespace.encodeBucketRecord(bucket_write.root_page_id);
        const root_update = try tree.writePutWithFlags(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            view.current_root_page_id,
            bucket,
            bucket_record[0..],
            namespace.bucket_entry_flag,
        );
        try view.applyRootWriteResult(self.db.allocator, root_update);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn deleteInBucket(self: *WriteTx, bucket: []const u8, key: []const u8) !void {
        try self.ensureActiveForMutation();
        const view = &self.view.?;
        const bucket_root_page_id = try currentBucketRootPageId(view, self.arena.allocator(), bucket);
        const delete_mutation = try tree.writeDelete(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            bucket_root_page_id,
            key,
        );
        switch (delete_mutation) {
            .unchanged => {},
            .changed => |write_result| {
                try view.applyDetachedWriteResult(self.db.allocator, write_result);
                const bucket_record = try namespace.encodeBucketRecord(write_result.root_page_id);
                const root_update = try tree.writePutWithFlags(
                    view.pageReader(),
                    self.arena.allocator(),
                    self.db.allocator,
                    self.db.page_size,
                    &self.working_page_allocator,
                    view.current_root_page_id,
                    bucket,
                    bucket_record[0..],
                    namespace.bucket_entry_flag,
                );
                try view.applyRootWriteResult(self.db.allocator, root_update);
                self.has_pending_write = true;
                self.state = .open_dirty;
            },
        }
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

        const allocator_root_release = try db_mod.currentAllocatorRootRelease(self.db);
        const staged_reclaim_page_count = self.view.?.reclaim_committed_pages.count() + if (allocator_root_release == null) @as(usize, 0) else @as(usize, 1);

        var staged_reclaim_pages: []const reclaim.ReleasedPage = &.{};
        if (staged_reclaim_page_count > 0) {
            try self.db.reclaim.ensurePendingCapacity(self.db.allocator, 1);
            var owned_pages = try self.db.allocator.alloc(reclaim.ReleasedPage, staged_reclaim_page_count);
            errdefer self.db.allocator.free(owned_pages);

            var index: usize = 0;
            if (self.view.?.reclaim_committed_pages.count() > 0) {
                const tree_reclaim_pages = try self.view.?.ownedReclaimPagesAlloc(self.db.allocator);
                defer self.db.allocator.free(tree_reclaim_pages);
                @memcpy(owned_pages[0..tree_reclaim_pages.len], tree_reclaim_pages);
                index = tree_reclaim_pages.len;
            }
            if (allocator_root_release) |released_page| {
                owned_pages[index] = released_page;
            }
            std.sort.pdq(reclaim.ReleasedPage, owned_pages, {}, reclaimPageLessThan);
            staged_reclaim_pages = owned_pages;
        }
        errdefer if (staged_reclaim_pages.len > 0) self.db.allocator.free(staged_reclaim_pages);

        var pending_records = std.ArrayList(page.AllocatorStateRecord).empty;
        defer pending_records.deinit(self.db.allocator);
        try self.db.reclaim.appendStateRecords(self.db.allocator, &pending_records);
        for (staged_reclaim_pages) |released_page| {
            try pending_records.append(self.db.allocator, .{
                .kind = .pending,
                .page_id = released_page.page_id,
                .order = released_page.order,
                .visible_through_txid = self.base_txid,
            });
        }

        const staged_pages = try self.view.?.sortedStagedPagesAlloc(self.db.allocator);
        defer self.db.allocator.free(staged_pages);

        const baseline_page_allocator = self.working_page_allocator;
        self.working_page_allocator = movedPageAllocator(self.db.allocator);
        self.owns_working_page_allocator = false;

        var allocator_state = try db_mod.materializeAllocatorStatePage(self.db, baseline_page_allocator, pending_records.items);
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

        for (staged_pages) |pending_page| {
            try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, allocator_state.page_id, allocator_state.bytes);
        try storage.sync(self.db.file, self.db.io);

        const next_meta_slot = inactiveMetaSlot(self.db.meta_slot);
        try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, metaSlotPageId(next_meta_slot), next_meta_page);
        try storage.sync(self.db.file, self.db.io);

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

fn rootEntryValueOrError(allocator: std.mem.Allocator, entry: ?tree.LookupEntry) !?[]u8 {
    const owned_entry = entry orelse return null;
    switch (try namespace.decodeRootEntry(owned_entry.value, owned_entry.flags)) {
        .value => return owned_entry.value,
        .bucket => {
            var rejected_entry = owned_entry;
            rejected_entry.deinit(allocator);
            return error.KeyBelongsToBucket;
        },
    }
}

fn ensureRootKeyMutable(page_reader: tree.PageReader, allocator: std.mem.Allocator, root_page_id: u64, key: []const u8) !void {
    const entry = try tree.lookupEntryPageReader(page_reader, allocator, root_page_id, key);
    if (entry) |owned_entry| {
        var owned = owned_entry;
        defer owned.deinit(allocator);
        if (namespace.isBucketFlags(owned.flags)) return error.KeyBelongsToBucket;
    }
}

fn bucketRootPageIdFromLookup(allocator: std.mem.Allocator, entry: ?tree.LookupEntry) !u64 {
    const owned_entry = entry orelse return error.BucketNotFound;
    defer {
        var released_entry = owned_entry;
        released_entry.deinit(allocator);
    }

    return switch (try namespace.decodeRootEntry(owned_entry.value, owned_entry.flags)) {
        .bucket => |record| record.root_page_id,
        .value => error.KeyNotBucket,
    };
}

fn currentBucketRootPageId(view: *const UncommittedView, allocator: std.mem.Allocator, bucket: []const u8) !u64 {
    const entry = try tree.lookupEntryPageReader(view.pageReader(), allocator, view.current_root_page_id, bucket);
    return try bucketRootPageIdFromLookup(allocator, entry);
}

fn lookupEntryIsBucket(allocator: std.mem.Allocator, entry: ?tree.LookupEntry) !bool {
    const owned_entry = entry orelse return false;
    defer {
        var released_entry = owned_entry;
        released_entry.deinit(allocator);
    }

    return switch (try namespace.decodeRootEntry(owned_entry.value, owned_entry.flags)) {
        .bucket => true,
        .value => false,
    };
}

fn collectBucketNamesAlloc(cursor: *tree.Cursor, allocator: std.mem.Allocator) !namespace.BucketNames {
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var next_record = try cursor.first(allocator);
    while (next_record) |record| {
        var owned_record = record;
        defer owned_record.deinit(allocator);

        switch (try namespace.decodeRootEntry(owned_record.value, owned_record.flags)) {
            .value => {},
            .bucket => {
                const owned_name = try allocator.dupe(u8, owned_record.key);
                errdefer allocator.free(owned_name);
                try names.append(allocator, owned_name);
            },
        }

        next_record = try cursor.next(allocator);
    }

    return .{
        .items = try names.toOwnedSlice(allocator),
    };
}

fn collectCommittedTreePagesAlloc(page_reader: tree.PageReader, allocator: std.mem.Allocator, root_page_id: u64) ![]reclaim.ReleasedPage {
    var released_pages = std.ArrayList(reclaim.ReleasedPage).empty;
    defer released_pages.deinit(allocator);

    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();

    try appendCommittedTreePages(&released_pages, &visited, page_reader, allocator, root_page_id);
    return released_pages.toOwnedSlice(allocator);
}

fn appendCommittedTreePages(
    released_pages: *std.ArrayList(reclaim.ReleasedPage),
    visited: *std.AutoHashMap(u64, void),
    page_reader: tree.PageReader,
    allocator: std.mem.Allocator,
    page_id: u64,
) !void {
    if (visited.contains(page_id)) return;
    try visited.put(page_id, {});

    const page_ref = try page_reader.readPage(allocator, page_id);
    defer page_ref.deinit(allocator);

    const page_bytes = page_ref.bytes();
    const header = try page.decodeHeader(page_bytes);
    try released_pages.append(allocator, .{
        .page_id = header.page_id,
        .order = header.order,
    });

    switch (header.page_type) {
        .leaf => {},
        .branch => {
            const branch_page = try page.BranchPage.validate(page_bytes);
            var index: u16 = 0;
            while (index < branch_page.count()) : (index += 1) {
                const child_entry = try branch_page.entry(index);
                try appendCommittedTreePages(released_pages, visited, page_reader, allocator, child_entry.child_page_id);
            }
        },
        else => return error.UnexpectedPageType,
    }
}

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

    fn applyRootWriteResult(self: *UncommittedView, allocator: std.mem.Allocator, write_result: tree.WriteResult) !void {
        try self.applyDetachedWriteResult(allocator, write_result);
        self.current_root_page_id = write_result.root_page_id;
    }

    fn applyDetachedWriteResult(self: *UncommittedView, allocator: std.mem.Allocator, write_result: tree.WriteResult) !void {
        for (write_result.new_pages) |pending_page| {
            try self.staged_pages.put(pending_page.page_id, pending_page);
        }

        try self.appendReleasedPages(allocator, write_result.obsolete_pages);

        self.allocation_high_water_mark = write_result.allocation_high_water_mark;
    }

    fn appendReleasedPages(self: *UncommittedView, allocator: std.mem.Allocator, released_pages: []const reclaim.ReleasedPage) !void {
        for (released_pages) |released_page| {
            if (self.staged_pages.remove(released_page.page_id)) continue;
            try self.reclaim_committed_pages.put(.{
                .page_id = released_page.page_id,
                .order = released_page.order,
            }, {});
        }
        _ = allocator;
    }

    fn stageAllocatedPage(
        self: *UncommittedView,
        backing_allocator: std.mem.Allocator,
        page_allocator: *allocator_mod.PageAllocator,
        page_size: u32,
        bytes: []u8,
    ) !u64 {
        var header = try page.decodeHeader(bytes);
        const span_size = try page.spanSize(page_size, header.order);
        if (bytes.len != span_size) return error.InvalidPageLayout;

        const page_id = try page_allocator.allocate(backing_allocator, header.order);
        header.page_id = page_id;
        try page.encodeHeader(bytes, header);

        try self.staged_pages.put(page_id, .{
            .page_id = page_id,
            .bytes = bytes,
        });
        self.allocation_high_water_mark = page_allocator.currentHighWaterMark();
        return page_id;
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
