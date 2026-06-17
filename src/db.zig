const std = @import("std");
const errors = @import("errors.zig");
const allocator_mod = @import("allocator.zig");
const compact_mod = @import("compact.zig");
const meta = @import("meta.zig");
const namespace = @import("namespace.zig");
const page = @import("page.zig");
const reclaim = @import("reclaim.zig");
const storage = @import("storage.zig");
const tree = @import("tree.zig");
const tx = @import("tx.zig");

const default_page_size: u32 = 4096;
const bootstrap_page_count: u64 = 3;
const allocator_state_max_span_size: usize = 16 * 1024 * 1024;

pub const MaterializedAllocatorState = struct {
    page_id: u64,
    bytes: []u8,
    page_allocator: allocator_mod.PageAllocator,
};

const RecoverableSnapshot = struct {
    slot: meta.MetaSlot,
    meta: meta.Meta,
    page_allocator: allocator_mod.PageAllocator,
    reclaim_state: reclaim.State,
};

const MetaPages = struct {
    meta0: []u8,
    meta1: []u8,

    fn deinit(self: *MetaPages, allocator: std.mem.Allocator) void {
        allocator.free(self.meta0);
        allocator.free(self.meta1);
        self.* = undefined;
    }
};

pub const DB = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_open: bool,
    path: []u8,
    meta_slot: meta.MetaSlot,
    page_size: u32,
    flags: u32,
    root_page_id: u64,
    allocator_root: u64,
    high_water_mark: u64,
    page_allocator: allocator_mod.PageAllocator,
    reclaim: reclaim.State,
    txid: u64,
    write_tx_active: bool,

    pub fn close(self: *DB) void {
        // Active WriteTx values borrow this DB and must be ended before close.
        std.debug.assert(!self.write_tx_active);
        std.debug.assert(self.reclaim.activeReaderCount() == 0);
        if (self.file_open) {
            self.file.close(self.io);
            self.file_open = false;
        }
        self.reclaim.deinit(self.allocator);
        self.page_allocator.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Returns an owned copy of the value for `key`, or `null` when the key is absent.
    pub fn get(self: *DB, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.get(allocator, key);
    }

    /// Returns an owned copy of the value stored in `bucket` for `key`.
    pub fn getInBucket(self: *DB, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        const bucket_path = [_][]const u8{bucket};
        return self.getInBucketPath(allocator, bucket_path[0..], key);
    }

    /// Returns an owned copy of the value stored in the bucket at
    /// `bucket_path` for `key`.
    pub fn getInBucketPath(
        self: *DB,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.getInBucketPath(allocator, bucket_path, key);
    }

    /// Returns whether `bucket` exists in the latest committed snapshot.
    pub fn bucketExists(self: *DB, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketExistsInBucketPath(allocator, parent_bucket_path[0..], bucket);
    }

    /// Returns whether `bucket` exists inside the bucket at
    /// `parent_bucket_path` in the latest committed snapshot.
    pub fn bucketExistsInBucketPath(
        self: *DB,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    /// Returns the top-level bucket names in key order.
    pub fn bucketNamesAlloc(self: *DB, allocator: std.mem.Allocator) !namespace.BucketNames {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path[0..]);
    }

    /// Returns the direct child bucket names inside the bucket at
    /// `parent_bucket_path` in key order.
    pub fn bucketNamesInBucketPathAlloc(
        self: *DB,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    /// Returns owned records whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanAlloc(self: *DB, allocator: std.mem.Allocator, bounds: tx.ScanBounds) !tx.ScanRecords {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.scanAlloc(allocator, bounds);
    }

    /// Returns owned records from `bucket` whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketAlloc(self: *DB, allocator: std.mem.Allocator, bucket: []const u8, bounds: tx.ScanBounds) !tx.ScanRecords {
        const bucket_path = [_][]const u8{bucket};
        return self.scanInBucketPathAlloc(allocator, bucket_path[0..], bounds);
    }

    /// Returns owned records from the bucket at `bucket_path` whose keys fall
    /// within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketPathAlloc(
        self: *DB,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: tx.ScanBounds,
    ) !tx.ScanRecords {
        var read_tx = try self.beginRead();
        defer read_tx.deinit();

        return read_tx.scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Opens a cursor over the latest committed root snapshot and owns its read transaction.
    pub fn cursor(self: *DB) !tx.ManagedCursor {
        return tx.ManagedCursor.init(self);
    }

    /// Opens a stable read snapshot that owns its underlying transaction.
    pub fn readView(self: *DB) !tx.ManagedReadView {
        return tx.ManagedReadView.init(self);
    }

    /// Opens a stable read snapshot rooted at the direct child bucket `bucket`.
    pub fn readViewInBucket(self: *DB, bucket: []const u8) !tx.ManagedBucketView {
        const bucket_path = [_][]const u8{bucket};
        return self.readViewInBucketPath(bucket_path[0..]);
    }

    /// Opens a stable read snapshot rooted at the descendant bucket
    /// `bucket_path`.
    pub fn readViewInBucketPath(self: *DB, bucket_path: []const []const u8) !tx.ManagedBucketView {
        return tx.ManagedBucketView.initInBucketPath(self, bucket_path);
    }

    /// Opens a cursor over the latest committed snapshot root of `bucket`.
    pub fn cursorInBucket(self: *DB, bucket: []const u8) !tx.ManagedCursor {
        const bucket_path = [_][]const u8{bucket};
        return self.cursorInBucketPath(bucket_path[0..]);
    }

    /// Opens a cursor over the latest committed snapshot root of the bucket at
    /// `bucket_path`.
    pub fn cursorInBucketPath(self: *DB, bucket_path: []const []const u8) !tx.ManagedCursor {
        return try tx.ManagedCursor.initInBucketPath(self, bucket_path);
    }

    /// Opens a read-only view over the currently committed root.
    pub fn beginRead(self: *DB) !tx.ReadTx {
        const snapshot = tree.ReadSnapshot{
            .root_page_id = self.root_page_id,
            .high_water_mark = self.high_water_mark,
        };
        const snapshot_file = try std.Io.Dir.openFileAbsolute(self.io, self.path, .{
            .mode = .read_only,
        });
        errdefer snapshot_file.close(self.io);
        try self.reclaim.beginRead(self.txid);
        return .{
            .db = self,
            .snapshot = snapshot,
            .snapshot_source = tree.SnapshotSource.init(self, snapshot, snapshot_file),
            .txid = self.txid,
        };
    }

    /// Opens the single writer slot for one explicit write transaction.
    pub fn beginWrite(self: *DB) !tx.WriteTx {
        return tx.WriteTx.init(self);
    }

    /// Commits a single-key update by copy-on-writing the affected tree path.
    pub fn put(self: *DB, key: []const u8, value: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.put(key, value);
        try write_tx.commit();
    }

    pub fn createBucket(self: *DB, bucket: []const u8) !void {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.createBucketInBucketPath(parent_bucket_path[0..], bucket);
    }

    pub fn createBucketInBucketPath(self: *DB, parent_bucket_path: []const []const u8, bucket: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.createBucketInBucketPath(parent_bucket_path, bucket);
        try write_tx.commit();
    }

    pub fn putInBucket(self: *DB, bucket: []const u8, key: []const u8, value: []const u8) !void {
        const bucket_path = [_][]const u8{bucket};
        return self.putInBucketPath(bucket_path[0..], key, value);
    }

    pub fn putInBucketPath(self: *DB, bucket_path: []const []const u8, key: []const u8, value: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.putInBucketPath(bucket_path, key, value);
        try write_tx.commit();
    }

    /// Deletes `key` when it exists and otherwise leaves the committed state unchanged.
    pub fn delete(self: *DB, key: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.delete(key);
        if (write_tx.has_pending_write) {
            try write_tx.commit();
        }
    }

    pub fn deleteInBucket(self: *DB, bucket: []const u8, key: []const u8) !void {
        const bucket_path = [_][]const u8{bucket};
        return self.deleteInBucketPath(bucket_path[0..], key);
    }

    pub fn deleteInBucketPath(self: *DB, bucket_path: []const []const u8, key: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.deleteInBucketPath(bucket_path, key);
        if (write_tx.has_pending_write) {
            try write_tx.commit();
        }
    }

    pub fn deleteBucket(self: *DB, bucket: []const u8) !void {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.deleteBucketInBucketPath(parent_bucket_path[0..], bucket);
    }

    pub fn deleteBucketInBucketPath(self: *DB, parent_bucket_path: []const []const u8, bucket: []const u8) !void {
        var write_tx = try self.beginWrite();
        defer write_tx.deinit();
        try write_tx.deleteBucketInBucketPath(parent_bucket_path, bucket);
        try write_tx.commit();
    }

    pub fn readPageAlloc(self: *DB, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
        return readTreePageObjectAlloc(allocator, &self.file, self.io, page_id, self.page_size, self.high_water_mark);
    }

    pub fn readPageAllocAtHighWater(self: *DB, allocator: std.mem.Allocator, page_id: u64, high_water_mark: u64) ![]u8 {
        return readTreePageObjectAlloc(allocator, &self.file, self.io, page_id, self.page_size, high_water_mark);
    }

    /// Rewrites the latest committed snapshot into a compact replacement file.
    pub fn compact(self: *DB, allocator: std.mem.Allocator) !void {
        if (self.write_tx_active) return error.WriteTransactionActive;

        const snapshot = tree.ReadSnapshot{
            .root_page_id = self.root_page_id,
            .high_water_mark = self.high_water_mark,
        };
        var snapshot_page_reader = tree.SnapshotPageReader.init(self, snapshot);
        var walker = compact_mod.SnapshotTreeWalker.init(allocator, snapshot_page_reader.pageReader(), snapshot);
        defer walker.deinit();

        try walker.walk();
        try walker.rewritePages();

        const compact_meta = meta.Meta{
            .page_size = self.page_size,
            .flags = self.flags,
            .root_page_id = try walker.rootPageId(),
            .allocator_root = 0,
            .high_water_mark = try walker.highWaterMark(),
            .txid = self.txid,
        };

        const temp_path = try std.fmt.allocPrint(allocator, "{s}.compact.tmp", .{self.path});
        defer allocator.free(temp_path);
        const backup_path = try std.fmt.allocPrint(allocator, "{s}.compact.bak", .{self.path});
        defer allocator.free(backup_path);

        errdefer compact_mod.deleteFileIfExists(temp_path, self.io) catch {};

        try compact_mod.FileReplacement.writeCompactedFile(
            allocator,
            temp_path,
            self.io,
            self.page_size,
            walker.descriptors.items,
            compact_meta,
        );
        try validateCompactedFile(allocator, self.io, temp_path, compact_meta);

        self.file.close(self.io);
        self.file_open = false;
        compact_mod.FileReplacement.replaceFileWithRollback(self.path, temp_path, backup_path, self.io) catch |err| {
            switch (err) {
                error.FileReplaceRollbackFailed => return err,
                else => {
                    self.file = try std.Io.Dir.openFileAbsolute(self.io, self.path, .{ .mode = .read_write });
                    self.file_open = true;
                    return err;
                },
            }
        };

        self.file = try std.Io.Dir.openFileAbsolute(self.io, self.path, .{ .mode = .read_write });
        self.file_open = true;
        try reloadCompactedStateFromOpenFile(self);
    }
};

/// Opens a database handle that borrows the caller-provided `io` context for
/// all file operations during the DB lifetime.
pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*DB {
    var db = try allocator.create(DB);
    errdefer allocator.destroy(db);

    const owned_path = try allocator.dupe(u8, path);

    db.* = .{
        .allocator = allocator,
        .io = io,
        .file = undefined,
        .file_open = false,
        .path = owned_path,
        .meta_slot = .meta0,
        .page_size = 0,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .page_allocator = allocator_mod.PageAllocator.init(allocator, 0),
        .reclaim = reclaim.State.init(allocator),
        .txid = 0,
        .write_tx_active = false,
    };
    errdefer db.reclaim.deinit(allocator);
    errdefer allocator.free(db.path);
    errdefer db.page_allocator.deinit(allocator);

    db.file = storage.openDatabaseFileAbsolute(io, path) catch |err| switch (err) {
        error.DatabaseLocked => return errors.DbOpenError.DatabaseLocked,
        else => return err,
    };
    db.file_open = true;

    errdefer if (db.file_open) db.file.close(io);

    try recoverOrInitialize(db);

    return db;
}

pub fn materializeAllocatorStatePage(
    db: *DB,
    baseline_page_allocator: allocator_mod.PageAllocator,
    pending_records: []const page.AllocatorStateRecord,
) !MaterializedAllocatorState {
    var baseline = baseline_page_allocator;
    errdefer baseline.deinit(db.allocator);

    var desired_order = try baseline.allocatorStateOrder(db.page_size, pending_records.len);
    while (true) {
        var candidate = try baseline.clone(db.allocator);
        errdefer candidate.deinit(db.allocator);

        const page_id = try candidate.allocate(db.allocator, desired_order);
        const required_order = try candidate.allocatorStateOrder(db.page_size, pending_records.len);
        if (required_order <= desired_order) {
            const state_page = try candidate.encodeStatePageAlloc(db.allocator, db.page_size, page_id, desired_order, pending_records);
            errdefer db.allocator.free(state_page);

            baseline.deinit(db.allocator);
            baseline = movedPageAllocator(db.allocator);
            const final_candidate = candidate;
            candidate = movedPageAllocator(db.allocator);
            return .{
                .page_id = page_id,
                .bytes = state_page,
                .page_allocator = final_candidate,
            };
        }

        candidate.deinit(db.allocator);
        candidate = movedPageAllocator(db.allocator);
        desired_order = required_order;
    }
}

pub fn currentAllocatorRootRelease(db: *DB) !?reclaim.ReleasedPage {
    if (db.allocator_root == 0) return null;

    const allocator_page = try readAllocatorStatePageObjectAlloc(
        db.allocator,
        &db.file,
        db.io,
        db.allocator_root,
        db.page_size,
        db.high_water_mark,
    );
    defer db.allocator.free(allocator_page);

    const header = try page.decodeHeader(allocator_page);
    if (header.page_id != db.allocator_root) return error.InvalidAllocatorState;
    if (header.page_type != .allocator) return error.InvalidAllocatorState;

    return .{
        .page_id = db.allocator_root,
        .order = header.order,
    };
}

pub fn applyCommittedState(
    db: *DB,
    next_meta_slot: meta.MetaSlot,
    next_meta: meta.Meta,
    next_page_allocator: allocator_mod.PageAllocator,
) void {
    db.meta_slot = next_meta_slot;
    db.flags = next_meta.flags;
    db.root_page_id = next_meta.root_page_id;
    db.allocator_root = next_meta.allocator_root;
    db.high_water_mark = next_meta.high_water_mark;
    var previous_page_allocator = db.page_allocator;
    db.page_allocator = next_page_allocator;
    previous_page_allocator.deinit(db.allocator);
    db.txid = next_meta.txid;
}

fn recoverOrInitialize(db: *DB) !void {
    const io = db.io;
    const stat = try db.file.stat(io);

    if (stat.size == 0) {
        try initializeEmptyDatabase(db);
    } else if (stat.size < @as(u64, default_page_size) * 2) {
        return errors.DbOpenError.DatabaseFileTooSmall;
    }

    try reloadCommittedStateFromOpenFile(db);
}

pub fn reloadCommittedStateFromOpenFile(db: *DB) !void {
    const io = db.io;
    var selected = loadNewestRecoverableSnapshot(db.allocator, &db.file, io, default_page_size) catch |err| switch (err) {
        error.NoValidMetaPage => return errors.DbOpenError.InvalidDatabaseFile,
        else => return err,
    };
    errdefer selected.page_allocator.deinit(db.allocator);
    errdefer selected.reclaim_state.deinit(db.allocator);

    db.meta_slot = selected.slot;
    db.page_size = selected.meta.page_size;
    db.flags = selected.meta.flags;
    db.root_page_id = selected.meta.root_page_id;
    db.allocator_root = selected.meta.allocator_root;
    db.high_water_mark = selected.meta.high_water_mark;
    var previous_page_allocator = db.page_allocator;
    db.page_allocator = selected.page_allocator;
    previous_page_allocator.deinit(db.allocator);
    selected.page_allocator = movedPageAllocator(db.allocator);
    var previous_reclaim = db.reclaim;
    db.reclaim = selected.reclaim_state;
    previous_reclaim.deinit(db.allocator);
    selected.reclaim_state = reclaim.State.init(db.allocator);
    db.txid = selected.meta.txid;
    try db.reclaim.releaseReusableIntoAllocator(db.allocator, &db.page_allocator);
}

fn reloadCompactedStateFromOpenFile(db: *DB) !void {
    const io = db.io;
    var selected = loadNewestRecoverableSnapshot(db.allocator, &db.file, io, default_page_size) catch |err| switch (err) {
        error.NoValidMetaPage => return errors.DbOpenError.InvalidDatabaseFile,
        else => return err,
    };
    defer selected.page_allocator.deinit(db.allocator);
    defer selected.reclaim_state.deinit(db.allocator);

    db.meta_slot = selected.slot;
    db.page_size = selected.meta.page_size;
    db.flags = selected.meta.flags;
    db.root_page_id = selected.meta.root_page_id;
    db.allocator_root = selected.meta.allocator_root;
    db.high_water_mark = selected.meta.high_water_mark;

    var previous_page_allocator = db.page_allocator;
    db.page_allocator = selected.page_allocator;
    previous_page_allocator.deinit(db.allocator);
    selected.page_allocator = movedPageAllocator(db.allocator);

    // Active readers still own handles to the pre-compact file, so only the
    // pending reclaim list is replaced here; their reader bookkeeping must
    // survive until each snapshot closes.
    db.reclaim.clearPending(db.allocator);
    db.txid = selected.meta.txid;
}

fn initializeEmptyDatabase(db: *DB) !void {
    const initial_meta = meta.Meta{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 0,
    };

    const meta0_page = try meta.encode(db.allocator, initial_meta);
    defer db.allocator.free(meta0_page);

    const meta1_page = try meta.encode(db.allocator, initial_meta);
    defer db.allocator.free(meta1_page);

    const root_page = try allocateEmptyRootPage(db.allocator, default_page_size, initial_meta.root_page_id);
    defer db.allocator.free(root_page);

    const io = db.io;
    // A valid meta page is the recovery commit point, so the bootstrap root
    // must reach durable storage before either meta page can reference it.
    try storage.writePageObject(&db.file, io, default_page_size, initial_meta.root_page_id, root_page);
    try storage.sync(db.file, io);
    try storage.writePageObject(&db.file, io, default_page_size, 0, meta0_page);
    try storage.writePageObject(&db.file, io, default_page_size, 1, meta1_page);
    try storage.sync(db.file, io);
}

fn loadSelectedMeta(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !meta.SelectedMeta {
    var meta_pages = try readMetaPagesAlloc(allocator, file, io, page_size);
    defer meta_pages.deinit(allocator);

    return meta.selectNewestValid(meta_pages.meta0, meta_pages.meta1);
}

fn loadNewestRecoverableSnapshot(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !RecoverableSnapshot {
    var meta_pages = try readMetaPagesAlloc(allocator, file, io, page_size);
    defer meta_pages.deinit(allocator);

    const snapshot0 = try tryLoadRecoverableSnapshotForMeta(
        allocator,
        file,
        io,
        meta.MetaSlot.meta0,
        meta_pages.meta0,
    );
    const snapshot1 = try tryLoadRecoverableSnapshotForMeta(
        allocator,
        file,
        io,
        meta.MetaSlot.meta1,
        meta_pages.meta1,
    );

    return selectNewestRecoverableSnapshot(allocator, snapshot0, snapshot1);
}

fn readMetaPagesAlloc(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !MetaPages {
    const meta0_page = try storage.readPageAlloc(allocator, file, io, 0, page_size);
    errdefer allocator.free(meta0_page);
    const meta1_page = try storage.readPageAlloc(allocator, file, io, 1, page_size);

    return .{
        .meta0 = meta0_page,
        .meta1 = meta1_page,
    };
}

fn tryLoadRecoverableSnapshotForMeta(
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    io: std.Io,
    slot: meta.MetaSlot,
    meta_page: []const u8,
) !?RecoverableSnapshot {
    return loadRecoverableSnapshotForMeta(allocator, file, io, slot, meta_page) catch |err| switch (err) {
        error.InvalidMagic,
        error.InvalidVersion,
        error.InvalidChecksum,
        error.InvalidPageSize,
        error.PageTooSmall,
        error.PageLengthMismatch,
        error.RootPageOutOfRange,
        error.AllocatorRootOutOfRange,
        error.InvalidAllocatorState,
        error.AllocatorStateTooLarge,
        error.InvalidPageType,
        error.InvalidBasePageSize,
        error.InvalidPageOrder,
        error.PageIdOverflow,
        error.SpanSizeOverflow,
        error.UnexpectedPageType,
        error.InvalidPageLayout,
        error.EntryOutOfBounds,
        error.EntriesNotSorted,
        error.PageFull,
        error.InvalidFreeBlock,
        error.FreeBlockOverlap,
        => null,
        else => return err,
    };
}

fn selectNewestRecoverableSnapshot(
    allocator: std.mem.Allocator,
    snapshot0: ?RecoverableSnapshot,
    snapshot1: ?RecoverableSnapshot,
) !RecoverableSnapshot {
    if (snapshot0 == null and snapshot1 == null) return error.NoValidMetaPage;
    if (snapshot0 != null and snapshot1 == null) return snapshot0.?;
    if (snapshot0 == null and snapshot1 != null) return snapshot1.?;

    if (snapshot0.?.meta.txid >= snapshot1.?.meta.txid) {
        var older = snapshot1.?;
        defer older.page_allocator.deinit(allocator);
        defer older.reclaim_state.deinit(allocator);
        return snapshot0.?;
    }

    var older = snapshot0.?;
    defer older.page_allocator.deinit(allocator);
    defer older.reclaim_state.deinit(allocator);
    return snapshot1.?;
}

fn loadRecoverableSnapshotForMeta(
    allocator: std.mem.Allocator,
    file: *std.Io.File,
    io: std.Io,
    slot: meta.MetaSlot,
    meta_page: []const u8,
) !RecoverableSnapshot {
    const decoded_meta = try meta.decode(meta_page);

    var page_allocator = allocator_mod.PageAllocator.init(allocator, decoded_meta.high_water_mark);
    errdefer page_allocator.deinit(allocator);
    var reclaim_state = reclaim.State.init(allocator);
    errdefer reclaim_state.deinit(allocator);

    if (decoded_meta.allocator_root != 0) {
        const state_page = try readAllocatorStatePageObjectAlloc(
            allocator,
            file,
            io,
            decoded_meta.allocator_root,
            decoded_meta.page_size,
            decoded_meta.high_water_mark,
        );
        defer allocator.free(state_page);

        var restored_state = try allocator_mod.PageAllocator.restoreStateFromPage(
            allocator,
            state_page,
            decoded_meta.high_water_mark,
            decoded_meta.allocator_root,
        );
        defer restored_state.deinit(allocator);

        for (restored_state.pending_records) |pending_record| {
            if (pending_record.visible_through_txid > decoded_meta.txid) return error.InvalidAllocatorState;
        }

        page_allocator.deinit(allocator);
        page_allocator = restored_state.takePageAllocator(allocator);

        reclaim_state.deinit(allocator);
        reclaim_state = try reclaim.State.initFromStateRecords(allocator, restored_state.pending_records);
    }

    return .{
        .slot = slot,
        .meta = decoded_meta,
        .page_allocator = page_allocator,
        .reclaim_state = reclaim_state,
    };
}

fn readTreePageObjectAlloc(
    allocator: std.mem.Allocator,
    file: *const std.Io.File,
    io: std.Io,
    page_id: u64,
    base_page_size: u32,
    high_water_mark: u64,
) ![]u8 {
    return storage.readPageObjectAlloc(
        allocator,
        file,
        io,
        page_id,
        base_page_size,
        high_water_mark,
        try page.maxOrderForSpanSize(base_page_size, std.math.maxInt(u16)),
    );
}

fn readAllocatorStatePageObjectAlloc(
    allocator: std.mem.Allocator,
    file: *const std.Io.File,
    io: std.Io,
    page_id: u64,
    base_page_size: u32,
    high_water_mark: u64,
) ![]u8 {
    return storage.readPageObjectAlloc(
        allocator,
        file,
        io,
        page_id,
        base_page_size,
        high_water_mark,
        try allocator_mod.orderForSize(base_page_size, allocator_state_max_span_size),
    );
}

fn allocateEmptyRootPage(allocator: std.mem.Allocator, page_size: u32, page_id: u64) ![]u8 {
    const root_page = try allocator.alloc(u8, page_size);
    errdefer allocator.free(root_page);
    @memset(root_page, 0);

    // The bootstrap root is a real empty leaf page so the open path never has to special-case
    // page 2 as an untyped placeholder during validation or later tree traversal.
    try page.LeafPage.init(root_page, .{
        .page_id = page_id,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    });

    return root_page;
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

fn validateCompactedFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, expected_meta: meta.Meta) !void {
    const compacted = try open(allocator, io, path);
    defer compacted.close();

    if (compacted.root_page_id != expected_meta.root_page_id) return error.TempFileValidationFailed;
    if (compacted.high_water_mark != expected_meta.high_water_mark) return error.TempFileValidationFailed;
    if (compacted.txid != expected_meta.txid) return error.TempFileValidationFailed;
    if (compacted.allocator_root != expected_meta.allocator_root) return error.TempFileValidationFailed;

    const root_page = try compacted.readPageAlloc(allocator, compacted.root_page_id);
    defer allocator.free(root_page);
    const header = try page.decodeHeader(root_page);
    switch (header.page_type) {
        .leaf, .branch => {},
        else => return error.TempFileValidationFailed,
    }
}

fn tempFilePath(buf: []u8, tmp_dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

fn bootstrapFile(path: []const u8) !void {
    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const seeded_meta = meta.Meta{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 0,
    };

    const meta0_page = try meta.encode(std.testing.allocator, seeded_meta);
    defer std.testing.allocator.free(meta0_page);
    const meta1_page = try meta.encode(std.testing.allocator, seeded_meta);
    defer std.testing.allocator.free(meta1_page);
    const root_page = try allocateEmptyRootPage(std.testing.allocator, default_page_size, seeded_meta.root_page_id);
    defer std.testing.allocator.free(root_page);

    try storage.writePageObject(&file, io, default_page_size, 0, meta0_page);
    try storage.writePageObject(&file, io, default_page_size, 1, meta1_page);
    try storage.writePageObject(&file, io, default_page_size, 2, root_page);
}

fn writeSeededDatabase(path: []const u8, meta0: meta.Meta, meta1: meta.Meta) !void {
    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const meta0_page = try meta.encode(std.testing.allocator, meta0);
    defer std.testing.allocator.free(meta0_page);
    const meta1_page = try meta.encode(std.testing.allocator, meta1);
    defer std.testing.allocator.free(meta1_page);

    const root_size = @max(meta0.page_size, meta1.page_size);
    const root_page = try allocateEmptyRootPage(std.testing.allocator, root_size, 2);
    defer std.testing.allocator.free(root_page);

    try storage.writePageObject(&file, io, default_page_size, 0, meta0_page);
    try storage.writePageObject(&file, io, default_page_size, 1, meta1_page);
    try storage.writePageObject(&file, io, default_page_size, 2, root_page);
}

fn writeTreeDatabase(path: []const u8, root_page_id: u64, pages: []const []const u8) !void {
    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    var high_water_mark: u64 = 1;
    for (pages) |page_bytes| {
        high_water_mark += try page.spanPageCount((try page.decodeHeader(page_bytes)).order);
    }
    const seeded_meta = meta.Meta{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = root_page_id,
        .allocator_root = 0,
        .high_water_mark = high_water_mark,
        .txid = 0,
    };

    const meta0_page = try meta.encode(std.testing.allocator, seeded_meta);
    defer std.testing.allocator.free(meta0_page);
    const meta1_page = try meta.encode(std.testing.allocator, seeded_meta);
    defer std.testing.allocator.free(meta1_page);

    try storage.writePageObject(&file, io, default_page_size, 0, meta0_page);
    try storage.writePageObject(&file, io, default_page_size, 1, meta1_page);

    var next_page_id: u64 = 2;
    for (pages) |page_bytes| {
        try storage.writePageObject(&file, io, default_page_size, next_page_id, page_bytes);
        next_page_id += try page.spanPageCount((try page.decodeHeader(page_bytes)).order);
    }
}

fn generatedKey(buf: []u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>4}", .{index});
}

fn fillFixedValue(buf: []u8, byte: u8) []const u8 {
    @memset(buf, byte);
    return buf;
}

fn appendGeneratedLeafEntries(
    entries: *std.ArrayList(page.LeafEntry),
    allocator: std.mem.Allocator,
    start: usize,
    count: usize,
    value_len: usize,
) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, start + index);
        const value = try allocator.alloc(u8, value_len);
        @memset(value, 'x');

        try entries.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = value,
            .flags = 0,
        });
    }
}

fn encodeLeafFixture(page_id: u64, entries: []const page.LeafEntry) ![default_page_size]u8 {
    var leaf_page = [_]u8{0} ** default_page_size;
    _ = try page.LeafPage.encodeInto(leaf_page[0..], .{
        .page_id = page_id,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, entries);
    return leaf_page;
}

fn expectBranchRootMatchesChildren(db: *DB, expected_count: u16) !void {
    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);

    const branch_page = try page.BranchPage.validate(root_page);
    try std.testing.expectEqual(expected_count, branch_page.count());

    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const branch_entry = try branch_page.entry(index);
        const child_page_bytes = try db.readPageAlloc(std.testing.allocator, branch_entry.child_page_id);
        defer std.testing.allocator.free(child_page_bytes);

        const child_leaf = try page.LeafPage.validate(child_page_bytes);
        try std.testing.expect(child_leaf.count() > 0);

        const child_max = try child_leaf.entry(child_leaf.count() - 1);
        try std.testing.expectEqualSlices(u8, child_max.key, branch_entry.key);
    }
}

fn expectDbValue(db: *DB, key: []const u8, expected: []const u8) !void {
    const value = (try db.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, expected, value);
}

fn expectDbMissing(db: *DB, key: []const u8) !void {
    const value = try db.get(std.testing.allocator, key);
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

const RecoveryMetaFixture = struct {
    txid: u64,
    root_page_id: u64,
    allocator_root: u64 = 0,
    flags: u32 = 0,

    fn toMeta(self: RecoveryMetaFixture) meta.Meta {
        return .{
            .page_size = default_page_size,
            .flags = self.flags,
            .root_page_id = self.root_page_id,
            .allocator_root = self.allocator_root,
            .high_water_mark = @max(@as(u64, 2), @max(self.root_page_id, self.allocator_root)),
            .txid = self.txid,
        };
    }
};

const RecoveryFault = enum {
    none,
    corrupt_meta,
};

const RecoveryExpectation = union(enum) {
    selected: struct {
        slot: meta.MetaSlot,
        root_page_id: u64,
        txid: u64,
    },
    invalid_database,
};

const RecoveryScenario = struct {
    meta0: RecoveryMetaFixture,
    meta1: RecoveryMetaFixture,
    meta0_fault: RecoveryFault = .none,
    meta1_fault: RecoveryFault = .none,
    expected: RecoveryExpectation,
};

fn applyMetaFault(path: []const u8, slot: meta.MetaSlot, fault: RecoveryFault) !void {
    if (fault == .none) return;

    const io = std.testing.io;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer file.close(io);

    const page_id = metaSlotPageId(slot);
    const page_bytes = try storage.readPageAlloc(std.testing.allocator, &file, io, page_id, default_page_size);
    defer std.testing.allocator.free(page_bytes);

    var invalid_page = try std.testing.allocator.dupe(u8, page_bytes);
    defer std.testing.allocator.free(invalid_page);

    switch (fault) {
        // Flip a payload byte without recomputing the checksum to model the
        // repo's existing checksum/partial-write corruption path.
        .corrupt_meta => invalid_page[12] ^= 0xFF,
        .none => unreachable,
    }

    try storage.writePageObject(&file, io, default_page_size, page_id, invalid_page);
}

fn runRecoveryScenario(path: []const u8, scenario: RecoveryScenario) !void {
    try writeSeededDatabase(path, scenario.meta0.toMeta(), scenario.meta1.toMeta());
    try applyMetaFault(path, .meta0, scenario.meta0_fault);
    try applyMetaFault(path, .meta1, scenario.meta1_fault);

    switch (scenario.expected) {
        .selected => |expected| {
            const db = try open(std.testing.allocator, std.testing.io, path);
            defer db.close();

            try std.testing.expectEqual(expected.slot, db.meta_slot);
            try std.testing.expectEqual(default_page_size, db.page_size);
            try std.testing.expectEqual(expected.root_page_id, db.root_page_id);
            try std.testing.expectEqual(expected.txid, db.txid);
        },
        .invalid_database => {
            try std.testing.expectError(
                errors.DbOpenError.InvalidDatabaseFile,
                open(std.testing.allocator, std.testing.io, path),
            );
        },
    }
}

fn expectBucketValue(db: *DB, bucket: []const u8, key: []const u8, expected: []const u8) !void {
    const value = (try db.getInBucket(std.testing.allocator, bucket, key)).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, expected, value);
}

fn expectBucketMissing(db: *DB, bucket: []const u8, key: []const u8) !void {
    const value = try db.getInBucket(std.testing.allocator, bucket, key);
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

fn expectBucketPathValue(db: *DB, bucket_path: []const []const u8, key: []const u8, expected: []const u8) !void {
    const value = (try db.getInBucketPath(std.testing.allocator, bucket_path, key)).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, expected, value);
}

fn expectBucketPathMissing(db: *DB, bucket_path: []const []const u8, key: []const u8) !void {
    const value = try db.getInBucketPath(std.testing.allocator, bucket_path, key);
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

fn expectBucketNames(names: namespace.BucketNames, expected: []const []const u8) !void {
    var owned_names = names;
    defer owned_names.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected.len, owned_names.items.len);
    for (expected, 0..) |expected_name, index| {
        try std.testing.expectEqualSlices(u8, expected_name, owned_names.items[index]);
    }
}

fn expectCursorRecord(record: tree.CursorRecord, expected_key: []const u8, expected_value: []const u8) !void {
    try std.testing.expectEqualSlices(u8, expected_key, record.key);
    try std.testing.expectEqualSlices(u8, expected_value, record.value);
}

fn expectScanRecords(records: tx.ScanRecords, expected: []const struct { key: []const u8, value: []const u8 }) !void {
    var owned_records = records;
    defer owned_records.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected.len, owned_records.items.len);
    for (expected, owned_records.items) |expected_record, actual_record| {
        try std.testing.expectEqualSlices(u8, expected_record.key, actual_record.key);
        try std.testing.expectEqualSlices(u8, expected_record.value, actual_record.value);
    }
}

fn expectReadTxValue(read_tx: tx.ReadTx, key: []const u8, expected: []const u8) !void {
    const value = (try read_tx.get(std.testing.allocator, key)).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, expected, value);
}

fn expectReadTxMissing(read_tx: tx.ReadTx, key: []const u8) !void {
    const value = try read_tx.get(std.testing.allocator, key);
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

fn stagedPageBytes(write_tx: *tx.WriteTx, page_id: u64) []const u8 {
    return write_tx.view.?.staged_pages.get(page_id).?.bytes;
}

fn stagedRootBranch(write_tx: *tx.WriteTx) !page.BranchPage {
    const root_page = stagedPageBytes(write_tx, write_tx.view.?.current_root_page_id);
    return page.BranchPage.validate(root_page);
}

fn expectBranchUpperBoundKeysAreReadable(db: *DB) !void {
    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);

    const branch_page = try page.BranchPage.validate(root_page);
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const branch_entry = try branch_page.entry(index);
        const value = try db.get(std.testing.allocator, branch_entry.key);
        defer if (value) |owned| std.testing.allocator.free(owned);
        try std.testing.expect(value != null);
    }
}

fn expectThreeLevelBranchRootMatchesLeaves(db: *DB, expected_root_id: u64) !void {
    try std.testing.expectEqual(expected_root_id, db.root_page_id);

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);

    const root_branch = try page.BranchPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 2), root_branch.count());

    var root_index: u16 = 0;
    while (root_index < root_branch.count()) : (root_index += 1) {
        const root_entry = try root_branch.entry(root_index);
        const branch_child_page = try db.readPageAlloc(std.testing.allocator, root_entry.child_page_id);
        defer std.testing.allocator.free(branch_child_page);

        const branch_child = try page.BranchPage.validate(branch_child_page);
        try std.testing.expect(branch_child.count() > 0);

        const branch_child_max = try branch_child.entry(branch_child.count() - 1);
        try std.testing.expectEqualSlices(u8, branch_child_max.key, root_entry.key);

        var child_index: u16 = 0;
        while (child_index < branch_child.count()) : (child_index += 1) {
            const branch_entry = try branch_child.entry(child_index);
            const leaf_page_bytes = try db.readPageAlloc(std.testing.allocator, branch_entry.child_page_id);
            defer std.testing.allocator.free(leaf_page_bytes);

            const leaf = try page.LeafPage.validate(leaf_page_bytes);
            try std.testing.expect(leaf.count() > 0);

            const leaf_max = try leaf.entry(leaf.count() - 1);
            try std.testing.expectEqualSlices(u8, leaf_max.key, branch_entry.key);

            const value = try db.get(std.testing.allocator, branch_entry.key);
            defer if (value) |owned| std.testing.allocator.free(owned);
            try std.testing.expect(value != null);
        }
    }
}

const TreeBounds = struct {
    min_key: []const u8,
    max_key: []const u8,
    leaf_depth: u32,
};

fn assertTreeInvariants(db: *DB) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var reachable = std.ArrayList(u64).empty;
    _ = try assertSubtreeInvariants(
        db,
        arena.allocator(),
        &reachable,
        db.root_page_id,
        0,
        null,
        null,
    );
}

fn assertSubtreeInvariants(
    db: *DB,
    allocator: std.mem.Allocator,
    reachable: *std.ArrayList(u64),
    page_id: u64,
    depth: u32,
    lower_exclusive: ?[]const u8,
    upper_inclusive: ?[]const u8,
) anyerror!TreeBounds {
    try std.testing.expect(page_id <= db.high_water_mark);
    for (reachable.items) |seen| {
        try std.testing.expect(seen != page_id);
    }
    try reachable.append(allocator, page_id);

    const page_bytes = try db.readPageAlloc(std.testing.allocator, page_id);
    defer std.testing.allocator.free(page_bytes);

    const header = try page.decodeHeader(page_bytes);
    return switch (header.page_type) {
        .leaf => blk: {
            const leaf_page = try page.LeafPage.validate(page_bytes);
            break :blk try assertLeafInvariants(allocator, leaf_page, depth, lower_exclusive, upper_inclusive);
        },
        .branch => blk: {
            const branch_page = try page.BranchPage.validate(page_bytes);
            break :blk try assertBranchInvariants(db, allocator, reachable, branch_page, depth, lower_exclusive, upper_inclusive);
        },
        else => error.UnexpectedPageType,
    };
}

fn assertLeafInvariants(
    allocator: std.mem.Allocator,
    leaf_page: page.LeafPage,
    depth: u32,
    lower_exclusive: ?[]const u8,
    upper_inclusive: ?[]const u8,
) !TreeBounds {
    try std.testing.expect(leaf_page.count() > 0);

    var previous_key: ?[]const u8 = null;
    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const entry = try leaf_page.entry(index);
        try expectKeyInRange(entry.key, lower_exclusive, upper_inclusive);
        if (previous_key) |previous| {
            try std.testing.expect(std.mem.order(u8, previous, entry.key) == .lt);
        }
        previous_key = entry.key;
    }

    const first = try leaf_page.entry(0);
    const last = try leaf_page.entry(leaf_page.count() - 1);
    return .{
        .min_key = try allocator.dupe(u8, first.key),
        .max_key = try allocator.dupe(u8, last.key),
        .leaf_depth = depth,
    };
}

fn assertBranchInvariants(
    db: *DB,
    allocator: std.mem.Allocator,
    reachable: *std.ArrayList(u64),
    branch_page: page.BranchPage,
    depth: u32,
    lower_exclusive: ?[]const u8,
    upper_inclusive: ?[]const u8,
) anyerror!TreeBounds {
    try std.testing.expect(branch_page.count() > 0);

    var previous_upper = lower_exclusive;
    var previous_leaf_depth: ?u32 = null;
    var min_key: ?[]const u8 = null;
    var max_key: ?[]const u8 = null;

    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const entry = try branch_page.entry(index);
        try expectKeyInRange(entry.key, previous_upper, upper_inclusive);

        const child_bounds = try assertSubtreeInvariants(
            db,
            allocator,
            reachable,
            entry.child_page_id,
            depth + 1,
            previous_upper,
            entry.key,
        );
        try std.testing.expectEqualSlices(u8, child_bounds.max_key, entry.key);

        if (previous_leaf_depth) |leaf_depth| {
            try std.testing.expectEqual(leaf_depth, child_bounds.leaf_depth);
        } else {
            previous_leaf_depth = child_bounds.leaf_depth;
            min_key = child_bounds.min_key;
        }

        previous_upper = entry.key;
        max_key = child_bounds.max_key;
    }

    return .{
        .min_key = min_key.?,
        .max_key = max_key.?,
        .leaf_depth = previous_leaf_depth.?,
    };
}

fn expectKeyInRange(key: []const u8, lower_exclusive: ?[]const u8, upper_inclusive: ?[]const u8) !void {
    if (lower_exclusive) |lower| {
        try std.testing.expect(std.mem.order(u8, lower, key) == .lt);
    }
    if (upper_inclusive) |upper| {
        try std.testing.expect(std.mem.order(u8, key, upper) != .gt);
    }
}

// ======tests======

test "open returns DB for an existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "existing.db");
    try bootstrapFile(path);

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const stat = try db.file.stat(db.io);
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u64, default_page_size) * bootstrap_page_count, stat.size);
    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 0), db.txid);
}

test "open creates and returns DB for a missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "created.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const stat = try tmp.dir.statFile(std.testing.io, "created.db", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u64, default_page_size) * bootstrap_page_count, stat.size);
    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 0), db.txid);
}

test "open accepts caller-managed threaded io" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "threaded.db");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const db = try open(std.testing.allocator, threaded.io(), path);
    defer db.close();

    const stat = try db.file.stat(db.io);
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
}

test "caller-managed threaded io supports put and reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "threaded-put.db");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    {
        const db = try open(std.testing.allocator, threaded.io(), path);
        defer db.close();
        try db.put("alpha", "beta");
    }

    {
        const reopened = try open(std.testing.allocator, threaded.io(), path);
        defer reopened.close();

        const value = try reopened.get(std.testing.allocator, "alpha");
        defer if (value) |owned| std.testing.allocator.free(owned);

        try std.testing.expect(value != null);
        try std.testing.expectEqualStrings("beta", value.?);
    }
}

test "open initializes empty file with meta0 meta1 and root page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "initialized.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const stat = try db.file.stat(db.io);
    try std.testing.expectEqual(@as(u64, default_page_size) * bootstrap_page_count, stat.size);
    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 0), db.txid);
}

test "open writes identical valid meta pages on bootstrap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bootstrap-meta.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const meta0_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io, 0, default_page_size);
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io, 1, default_page_size);
    defer std.testing.allocator.free(meta1_page);

    const decoded0 = try meta.decode(meta0_page);
    const decoded1 = try meta.decode(meta1_page);
    const expected = meta.Meta{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 0,
    };

    try std.testing.expectEqualDeep(expected, decoded0);
    try std.testing.expectEqualDeep(expected, decoded1);
}

test "open bootstraps a valid empty leaf root page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bootstrap-root.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const root_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io, 2, default_page_size);
    defer std.testing.allocator.free(root_page);

    const leaf_page = try page.LeafPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 0), leaf_page.count());
}

test "open rejects bootstrap root written without committed meta pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "half-bootstrap.db");

    const root_page = try allocateEmptyRootPage(std.testing.allocator, default_page_size, 2);
    defer std.testing.allocator.free(root_page);

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = true,
        });
        defer file.close(io);

        try storage.writePageObject(&file, io, default_page_size, 2, root_page);
        try storage.sync(file, io);
    }

    try std.testing.expectError(errors.DbOpenError.InvalidDatabaseFile, open(std.testing.allocator, std.testing.io, path));
}

test "open recovers cached state from an existing valid database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-valid.db");

    try writeSeededDatabase(path, .{
        .page_size = default_page_size,
        .flags = 1,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 4,
    }, .{
        .page_size = default_page_size,
        .flags = 2,
        .root_page_id = 3,
        .allocator_root = 0,
        .high_water_mark = 3,
        .txid = 9,
    });

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 3), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 9), db.txid);
}

test "loadNewestRecoverableSnapshot prefers meta0 when txids tie" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-tie-prefers-meta0.db");

    try writeSeededDatabase(path, .{
        .page_size = default_page_size,
        .flags = 11,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 5,
    }, .{
        .page_size = default_page_size,
        .flags = 22,
        .root_page_id = 3,
        .allocator_root = 0,
        .high_water_mark = 3,
        .txid = 5,
    });

    const io = std.testing.io;
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var snapshot = try loadNewestRecoverableSnapshot(std.testing.allocator, &file, io, default_page_size);
    defer {
        snapshot.page_allocator.deinit(std.testing.allocator);
        snapshot.reclaim_state.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(meta.MetaSlot.meta0, snapshot.slot);
    try std.testing.expectEqual(@as(u32, 11), snapshot.meta.flags);
    try std.testing.expectEqual(@as(u64, 2), snapshot.meta.root_page_id);
    try std.testing.expectEqual(@as(u64, 5), snapshot.meta.txid);
}

// These meta recovery matrix tests strengthen the reopen path coverage for
// issue #57 and the broader recovery tracking under issue #46. "stale" means
// a lower committed txid; the on-disk format does not have a separate
// uncommitted-meta marker, so distinct failure paths are modeled as either an
// invalid meta page or a valid meta page that references an unrecoverable
// snapshot.

test "open selects meta0 when meta0 is the newest valid snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-meta0-newest.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 9, .root_page_id = 2 },
        .meta1 = .{ .txid = 7, .root_page_id = 3 },
        .expected = .{ .selected = .{
            .slot = .meta0,
            .root_page_id = 2,
            .txid = 9,
        } },
    });
}

test "open selects meta1 when meta1 is the newest valid snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-meta1-newest.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 7, .root_page_id = 2 },
        .meta1 = .{ .txid = 9, .root_page_id = 3 },
        .expected = .{ .selected = .{
            .slot = .meta1,
            .root_page_id = 3,
            .txid = 9,
        } },
    });
}

test "open prefers meta0 when both valid meta pages have the same txid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-tie-open-prefers-meta0.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 5, .root_page_id = 2, .flags = 11 },
        .meta1 = .{ .txid = 5, .root_page_id = 3, .flags = 22 },
        .expected = .{ .selected = .{
            .slot = .meta0,
            .root_page_id = 2,
            .txid = 5,
        } },
    });
}

test "open falls back to meta0 when meta1 is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-meta1-corrupt.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 8, .root_page_id = 2 },
        .meta1 = .{ .txid = 9, .root_page_id = 3 },
        .meta1_fault = .corrupt_meta,
        .expected = .{ .selected = .{
            .slot = .meta0,
            .root_page_id = 2,
            .txid = 8,
        } },
    });
}

test "open falls back to meta1 when meta0 is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-meta0-corrupt.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 9, .root_page_id = 2 },
        .meta1 = .{ .txid = 8, .root_page_id = 3 },
        .meta0_fault = .corrupt_meta,
        .expected = .{ .selected = .{
            .slot = .meta1,
            .root_page_id = 3,
            .txid = 8,
        } },
    });
}

test "open falls back to stale meta0 when newer meta1 is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-stale-meta0.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 7, .root_page_id = 2 },
        .meta1 = .{ .txid = 9, .root_page_id = 3 },
        .meta1_fault = .corrupt_meta,
        .expected = .{ .selected = .{
            .slot = .meta0,
            .root_page_id = 2,
            .txid = 7,
        } },
    });
}

test "open falls back to stale meta1 when newer meta0 is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-stale-meta1.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 9, .root_page_id = 2 },
        .meta1 = .{ .txid = 7, .root_page_id = 3 },
        .meta0_fault = .corrupt_meta,
        .expected = .{ .selected = .{
            .slot = .meta1,
            .root_page_id = 3,
            .txid = 7,
        } },
    });
}

test "open rejects existing invalid non-empty file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "invalid.db",
        .data = "not-a-database",
        .flags = .{ .read = true, .truncate = false },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "invalid.db");

    try std.testing.expectError(errors.DbOpenError.DatabaseFileTooSmall, open(std.testing.allocator, std.testing.io, path));
}

test "open rejects too-small non-empty file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "too-small.db",
        .data = "tiny",
        .flags = .{ .read = true, .truncate = false },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "too-small.db");

    try std.testing.expectError(errors.DbOpenError.DatabaseFileTooSmall, open(std.testing.allocator, std.testing.io, path));
}

test "open maps invalid meta recovery into centralized db error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bad-meta.db");

    try runRecoveryScenario(path, .{
        .meta0 = .{ .txid = 1, .root_page_id = 2 },
        .meta1 = .{ .txid = 2, .root_page_id = 3 },
        .meta0_fault = .corrupt_meta,
        .meta1_fault = .corrupt_meta,
        .expected = .invalid_database,
    });
}

test "open fails with database locked while another handle owns the exclusive lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "open-locked.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectError(errors.DbOpenError.DatabaseLocked, open(std.testing.allocator, std.testing.io, path));
}

test "open succeeds again after the previous handle closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "open-after-close.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        db.close();
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(default_page_size, reopened.page_size);
}

test "put commits a new root leaf and updates selected meta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-commit.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");

    try std.testing.expectEqual(meta.MetaSlot.meta1, db.meta_slot);
    try std.testing.expectEqual(@as(u64, 3), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 4), db.high_water_mark);
    try std.testing.expectEqual(@as(u64, 4), db.allocator_root);
    try std.testing.expectEqual(@as(u64, 1), db.txid);

    const value = (try db.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, "one", value);

    const selected = try loadSelectedMeta(std.testing.allocator, &db.file, db.io, db.page_size);
    try std.testing.expectEqual(meta.MetaSlot.meta1, selected.slot);
    try std.testing.expectEqual(@as(u64, 3), selected.meta.root_page_id);
    try std.testing.expectEqual(@as(u64, 4), selected.meta.allocator_root);
    try std.testing.expectEqual(@as(u64, 4), selected.meta.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), selected.meta.txid);
}

test "read transaction keeps old snapshot after later commits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "read-tx-snapshot.db");
    var value_buf = [_]u8{'x'} ** 160;

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        var index: usize = 0;
        while (index < 24) : (index += 1) {
            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, index);
            try db.put(key, value_buf[0..]);
        }
        try expectBranchRootMatchesChildren(db, 2);

        var read_tx = try db.beginRead();
        defer read_tx.deinit();

        try db.put("k0000", "updated");
        try db.put("zzzz", "tail");

        const old_value = (try read_tx.get(std.testing.allocator, "k0000")).?;
        defer std.testing.allocator.free(old_value);
        try std.testing.expectEqualSlices(u8, value_buf[0..], old_value);

        const old_tail = try read_tx.get(std.testing.allocator, "zzzz");
        defer if (old_tail) |owned| std.testing.allocator.free(owned);
        try std.testing.expect(old_tail == null);

        try expectDbValue(db, "k0000", "updated");
        try expectDbValue(db, "zzzz", "tail");
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try expectDbValue(reopened, "k0000", "updated");
    try expectDbValue(reopened, "zzzz", "tail");
}

test "read transaction uses captured high water for higher-order root leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "read-tx-high-water.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var large_value = [_]u8{'L'} ** 7000;
    try db.put("large", large_value[0..]);

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try std.testing.expect(read_tx.snapshot.high_water_mark > read_tx.snapshot.root_page_id);
    const current_high_water_mark = db.high_water_mark;
    // Lower the live DB bound after opening the transaction so this test fails
    // if ReadTx accidentally reads through the current DB high-water mark.
    db.high_water_mark = read_tx.snapshot.root_page_id;
    defer db.high_water_mark = current_high_water_mark;

    const snapshot_value = (try read_tx.get(std.testing.allocator, "large")).?;
    defer std.testing.allocator.free(snapshot_value);
    try std.testing.expectEqualSlices(u8, large_value[0..], snapshot_value);

    try std.testing.expectError(error.EntryOutOfBounds, db.get(std.testing.allocator, "large"));
}

test "reopen ignores dirty pages written before meta switch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "dirty-before-meta.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("alpha", "one");
        const old_root_page_id = db.root_page_id;
        const old_high_water_mark = db.high_water_mark;
        const old_txid = db.txid;

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var working_page_allocator = try db.page_allocator.clone(std.testing.allocator);
        defer working_page_allocator.deinit(std.testing.allocator);

        var page_reader = tree.SnapshotPageReader.init(db, .{
            .root_page_id = db.root_page_id,
            .high_water_mark = db.high_water_mark,
        });
        const write_result = try tree.writePut(
            page_reader.pageReader(),
            arena.allocator(),
            db.allocator,
            db.page_size,
            &working_page_allocator,
            db.root_page_id,
            "beta",
            "two",
        );
        const io = db.io;
        for (write_result.new_pages) |pending_page| {
            try storage.writePageObject(&db.file, io, db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.sync(db.file, io);

        try std.testing.expectEqual(old_root_page_id, db.root_page_id);
        try std.testing.expectEqual(old_high_water_mark, db.high_water_mark);
        try std.testing.expectEqual(old_txid, db.txid);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(u64, 3), reopened.root_page_id);
    try std.testing.expectEqual(@as(u64, 4), reopened.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), reopened.txid);

    try expectDbValue(reopened, "alpha", "one");
    const beta = try reopened.get(std.testing.allocator, "beta");
    defer if (beta) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(beta == null);
}

test "reopen selects inactive meta after data and allocator pages are durable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "meta-after-data.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("alpha", "one");

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var working_page_allocator = try db.page_allocator.clone(std.testing.allocator);
        errdefer working_page_allocator.deinit(std.testing.allocator);

        var page_reader = tree.SnapshotPageReader.init(db, .{
            .root_page_id = db.root_page_id,
            .high_water_mark = db.high_water_mark,
        });
        const write_result = try tree.writePut(
            page_reader.pageReader(),
            arena.allocator(),
            db.allocator,
            db.page_size,
            &working_page_allocator,
            db.root_page_id,
            "beta",
            "two",
        );
        const baseline_page_allocator = working_page_allocator;
        working_page_allocator = movedPageAllocator(std.testing.allocator);

        var allocator_state = try materializeAllocatorStatePage(db, baseline_page_allocator, &.{});
        defer std.testing.allocator.free(allocator_state.bytes);
        defer allocator_state.page_allocator.deinit(std.testing.allocator);

        const next_meta = meta.Meta{
            .page_size = db.page_size,
            .flags = db.flags,
            .root_page_id = write_result.root_page_id,
            .allocator_root = allocator_state.page_id,
            .high_water_mark = allocator_state.page_allocator.currentHighWaterMark(),
            .txid = db.txid + 1,
        };
        const next_meta_page = try meta.encode(std.testing.allocator, next_meta);
        defer std.testing.allocator.free(next_meta_page);

        const io = db.io;
        for (write_result.new_pages) |pending_page| {
            try storage.writePageObject(&db.file, io, db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.writePageObject(&db.file, io, db.page_size, allocator_state.page_id, allocator_state.bytes);
        try storage.sync(db.file, io);

        const next_meta_slot = inactiveMetaSlot(db.meta_slot);
        try storage.writePageObject(&db.file, io, db.page_size, metaSlotPageId(next_meta_slot), next_meta_page);
        try storage.sync(db.file, io);

        try std.testing.expectEqual(@as(u64, 3), db.root_page_id);
        try std.testing.expectEqual(@as(u64, 1), db.txid);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(u64, 5), reopened.root_page_id);
    try std.testing.expectEqual(@as(u64, 6), reopened.high_water_mark);
    try std.testing.expectEqual(@as(u64, 2), reopened.txid);
    try expectDbValue(reopened, "alpha", "one");
    try expectDbValue(reopened, "beta", "two");
}

test "put inserts in sorted order and overwrites existing keys across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-overwrite.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("beta", "two");
        try db.put("alpha", "one");
        try db.put("beta", "updated");

        try std.testing.expectEqual(meta.MetaSlot.meta1, db.meta_slot);
        try std.testing.expect(db.root_page_id >= 3);
        try std.testing.expect(db.high_water_mark >= db.root_page_id);
        try std.testing.expectEqual(@as(u64, 3), db.txid);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    const alpha = (try reopened.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(alpha);
    try std.testing.expectEqualSlices(u8, "one", alpha);

    const beta = (try reopened.get(std.testing.allocator, "beta")).?;
    defer std.testing.allocator.free(beta);
    try std.testing.expectEqualSlices(u8, "updated", beta);

    const root_page = try reopened.readPageAlloc(std.testing.allocator, reopened.root_page_id);
    defer std.testing.allocator.free(root_page);

    const root_leaf = try page.LeafPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 2), root_leaf.count());

    const first = try root_leaf.entry(0);
    try std.testing.expectEqualSlices(u8, "alpha", first.key);
    try std.testing.expectEqualSlices(u8, "one", first.value);

    const second = try root_leaf.entry(1);
    try std.testing.expectEqualSlices(u8, "beta", second.key);
    try std.testing.expectEqualSlices(u8, "updated", second.value);
}

test "put splits a full root leaf into a branch root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-root-split.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        var value_buf: [160]u8 = undefined;
        const value = fillFixedValue(&value_buf, 'x');

        var index: usize = 0;
        while (index < 24) : (index += 1) {
            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, index);
            try db.put(key, value);
        }

        try std.testing.expect(db.high_water_mark < 52);
        try std.testing.expectEqual(@as(u64, 24), db.txid);
        try expectBranchRootMatchesChildren(db, 2);

        const selected = try loadSelectedMeta(std.testing.allocator, &db.file, db.io, db.page_size);
        try std.testing.expectEqual(db.root_page_id, selected.meta.root_page_id);
        try std.testing.expectEqual(db.high_water_mark, selected.meta.high_water_mark);
        try std.testing.expectEqual(db.txid, selected.meta.txid);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    var index: usize = 0;
    while (index < 24) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);

        const value = (try reopened.get(std.testing.allocator, key)).?;
        defer std.testing.allocator.free(value);
        try std.testing.expectEqual(@as(usize, 160), value.len);
        try std.testing.expectEqual(@as(u8, 'x'), value[0]);
    }

    try expectBranchRootMatchesChildren(reopened, 2);
}

test "put updates a branch-root leaf child without changing its upper bound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-branch-update.db");

    var branch_root = [_]u8{0} ** default_page_size;
    _ = try page.BranchPage.encodeInto(branch_root[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 4 },
    });

    const left_leaf = try encodeLeafFixture(3, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });
    const right_leaf = try encodeLeafFixture(4, &.{
        .{ .key = "gamma", .value = "three", .flags = 0 },
        .{ .key = "omega", .value = "last", .flags = 0 },
    });

    try writeTreeDatabase(path, 2, &.{
        branch_root[0..],
        left_leaf[0..],
        right_leaf[0..],
    });

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "updated");

    try std.testing.expectEqual(@as(u64, 6), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 7), db.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), db.txid);

    const value = (try db.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, "updated", value);
    try expectBranchRootMatchesChildren(db, 2);

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const branch_page = try page.BranchPage.validate(root_page);
    const first = try branch_page.entry(0);
    try std.testing.expectEqualSlices(u8, "beta", first.key);
}

test "put appends past the largest branch upper bound into the rightmost child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-branch-append.db");

    var branch_root = [_]u8{0} ** default_page_size;
    _ = try page.BranchPage.encodeInto(branch_root[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 4 },
    });

    const left_leaf = try encodeLeafFixture(3, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });
    const right_leaf = try encodeLeafFixture(4, &.{
        .{ .key = "gamma", .value = "three", .flags = 0 },
        .{ .key = "omega", .value = "last", .flags = 0 },
    });

    try writeTreeDatabase(path, 2, &.{
        branch_root[0..],
        left_leaf[0..],
        right_leaf[0..],
    });

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("zzzz", "tail");

    const value = (try db.get(std.testing.allocator, "zzzz")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, "tail", value);
    try expectBranchRootMatchesChildren(db, 2);

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const branch_page = try page.BranchPage.validate(root_page);
    const second = try branch_page.entry(1);
    try std.testing.expectEqualSlices(u8, "zzzz", second.key);
}

test "put splits a full branch child leaf and updates the branch root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-child-split.db");

    var left_entries = std.ArrayList(page.LeafEntry).empty;
    try appendGeneratedLeafEntries(&left_entries, std.testing.allocator, 0, 1, 160);
    defer {
        for (left_entries.items) |entry| {
            std.testing.allocator.free(entry.key);
            std.testing.allocator.free(entry.value);
        }
        left_entries.deinit(std.testing.allocator);
    }

    var right_entries = std.ArrayList(page.LeafEntry).empty;
    try appendGeneratedLeafEntries(&right_entries, std.testing.allocator, 1, 23, 160);
    defer {
        for (right_entries.items) |entry| {
            std.testing.allocator.free(entry.key);
            std.testing.allocator.free(entry.value);
        }
        right_entries.deinit(std.testing.allocator);
    }

    const left_leaf = try encodeLeafFixture(3, left_entries.items);
    const right_leaf = try encodeLeafFixture(4, right_entries.items);

    var branch_root = [_]u8{0} ** default_page_size;
    _ = try page.BranchPage.encodeInto(branch_root[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = left_entries.items[left_entries.items.len - 1].key, .child_page_id = 3 },
        .{ .key = right_entries.items[right_entries.items.len - 1].key, .child_page_id = 4 },
    });

    try writeTreeDatabase(path, 2, &.{
        branch_root[0..],
        left_leaf[0..],
        right_leaf[0..],
    });

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        const old_high_water_mark = db.high_water_mark;
        const old_txid = db.txid;

        var value_buf: [160]u8 = undefined;
        try db.put("zzzz", fillFixedValue(&value_buf, 'y'));

        try std.testing.expectEqual(old_txid + 1, db.txid);
        try std.testing.expectEqual(old_high_water_mark + 3, db.root_page_id);
        try std.testing.expectEqual(old_high_water_mark + 4, db.high_water_mark);
        try expectBranchRootMatchesChildren(db, 3);
        try expectBranchUpperBoundKeysAreReadable(db);

        try expectDbValue(db, "k0000", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(db, "k0001", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(db, "k0023", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(db, "zzzz", fillFixedValue(&value_buf, 'y'));
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    var value_buf: [160]u8 = undefined;
    try expectDbValue(reopened, "k0000", fillFixedValue(&value_buf, 'x'));
    try expectDbValue(reopened, "k0001", fillFixedValue(&value_buf, 'x'));
    try expectDbValue(reopened, "k0023", fillFixedValue(&value_buf, 'x'));
    try expectDbValue(reopened, "zzzz", fillFixedValue(&value_buf, 'y'));
    try expectBranchRootMatchesChildren(reopened, 3);
    try expectBranchUpperBoundKeysAreReadable(reopened);
}

test "put splits branch root after a child leaf split fills the root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-child-split-root-full.db");

    const branch_entry_count = 239;

    var child_pages = std.ArrayList([]u8).empty;
    defer {
        for (child_pages.items) |page_bytes| {
            std.testing.allocator.free(page_bytes);
        }
        child_pages.deinit(std.testing.allocator);
    }

    var branch_entries = std.ArrayList(page.BranchEntry).empty;
    defer {
        for (branch_entries.items) |entry| {
            std.testing.allocator.free(entry.key);
        }
        branch_entries.deinit(std.testing.allocator);
    }

    var index: usize = 0;
    while (index < branch_entry_count - 1) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        const child_page_id = 3 + index;

        const leaf_page = try std.testing.allocator.alloc(u8, default_page_size);
        @memset(leaf_page, 0);
        _ = try page.LeafPage.encodeInto(leaf_page, .{
            .page_id = child_page_id,
            .page_type = .leaf,
            .count = 0,
            .order = 0,
        }, &.{
            .{ .key = key, .value = "v", .flags = 0 },
        });

        try child_pages.append(std.testing.allocator, leaf_page);
        try branch_entries.append(std.testing.allocator, .{
            .key = try std.testing.allocator.dupe(u8, key),
            .child_page_id = child_page_id,
        });
    }

    var target_entries = std.ArrayList(page.LeafEntry).empty;
    try appendGeneratedLeafEntries(&target_entries, std.testing.allocator, branch_entry_count - 1, 23, 160);
    defer {
        for (target_entries.items) |entry| {
            std.testing.allocator.free(entry.key);
            std.testing.allocator.free(entry.value);
        }
        target_entries.deinit(std.testing.allocator);
    }

    const target_page_id = 3 + branch_entry_count - 1;
    const target_leaf_page = try std.testing.allocator.alloc(u8, default_page_size);
    @memset(target_leaf_page, 0);
    _ = try page.LeafPage.encodeInto(target_leaf_page, .{
        .page_id = target_page_id,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, target_entries.items);
    try child_pages.append(std.testing.allocator, target_leaf_page);
    try branch_entries.append(std.testing.allocator, .{
        .key = try std.testing.allocator.dupe(u8, target_entries.items[target_entries.items.len - 1].key),
        .child_page_id = target_page_id,
    });

    const root_page = try std.testing.allocator.alloc(u8, default_page_size);
    defer std.testing.allocator.free(root_page);
    @memset(root_page, 0);
    _ = try page.BranchPage.encodeInto(root_page, .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, branch_entries.items);

    var pages = std.ArrayList([]const u8).empty;
    defer pages.deinit(std.testing.allocator);
    try pages.append(std.testing.allocator, root_page);
    for (child_pages.items) |child_page| {
        try pages.append(std.testing.allocator, child_page);
    }

    try writeTreeDatabase(path, 2, pages.items);

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        const old_high_water_mark = db.high_water_mark;
        const old_txid = db.txid;

        var value_buf: [160]u8 = undefined;
        try db.put("zzzz", fillFixedValue(&value_buf, 'y'));

        try std.testing.expectEqual(old_txid + 1, db.txid);
        try std.testing.expectEqual(old_high_water_mark + 5, db.root_page_id);
        try std.testing.expectEqual(old_high_water_mark + 6, db.high_water_mark);
        try expectThreeLevelBranchRootMatchesLeaves(db, old_high_water_mark + 5);

        try expectDbValue(db, "k0000", "v");
        try expectDbValue(db, "k0237", "v");
        try expectDbValue(db, "k0238", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(db, "k0260", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(db, "zzzz", fillFixedValue(&value_buf, 'y'));
    }

    {
        const reopened = try open(std.testing.allocator, std.testing.io, path);
        defer reopened.close();

        try std.testing.expectEqual(@as(u64, 246), reopened.root_page_id);
        try std.testing.expectEqual(@as(u64, 247), reopened.high_water_mark);
        try std.testing.expectEqual(@as(u64, 1), reopened.txid);
        try expectThreeLevelBranchRootMatchesLeaves(reopened, 246);
        try assertTreeInvariants(reopened);

        var value_buf: [160]u8 = undefined;
        try expectDbValue(reopened, "k0000", "v");
        try expectDbValue(reopened, "k0237", "v");
        try expectDbValue(reopened, "k0238", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(reopened, "k0260", fillFixedValue(&value_buf, 'x'));
        try expectDbValue(reopened, "zzzz", fillFixedValue(&value_buf, 'y'));

        try reopened.put("k0000", "updated");
        try reopened.put("zzzzz", "tail");
        try reopened.put("a0000", "head");
        var huge_value = [_]u8{'h'} ** 3500;
        try reopened.put("k0238", huge_value[0..]);
        try expectDbValue(reopened, "a0000", "head");
        try expectDbValue(reopened, "k0000", "updated");
        try expectDbValue(reopened, "k0238", huge_value[0..]);
        try expectDbValue(reopened, "zzzzz", "tail");
        try assertTreeInvariants(reopened);
    }

    const final_reopen = try open(std.testing.allocator, std.testing.io, path);
    defer final_reopen.close();
    var huge_value = [_]u8{'h'} ** 3500;
    try expectDbValue(final_reopen, "a0000", "head");
    try expectDbValue(final_reopen, "k0000", "updated");
    try expectDbValue(final_reopen, "k0238", huge_value[0..]);
    try expectDbValue(final_reopen, "zzzzz", "tail");
    try assertTreeInvariants(final_reopen);
}

test "put matches deterministic oracle across reopen cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-oracle.db");

    const key_count = 96;
    var present = [_]bool{false} ** key_count;
    var expected_len = [_]usize{0} ** key_count;
    var expected_byte = [_]u8{0} ** key_count;
    var state: u64 = 0xB01DBA5E;

    {
        var db = try open(std.testing.allocator, std.testing.io, path);

        var op_index: usize = 0;
        while (op_index < 260) : (op_index += 1) {
            const raw = nextPseudoRandom(&state);
            const key_index = raw % key_count;
            const value_len = 12 + ((raw >> 8) % 190);
            const value_byte: u8 = @intCast('a' + (raw % 23));

            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, key_index);
            const value = try std.testing.allocator.alloc(u8, value_len);
            defer std.testing.allocator.free(value);
            @memset(value, value_byte);

            try db.put(key, value);
            present[key_index] = true;
            expected_len[key_index] = value_len;
            expected_byte[key_index] = value_byte;

            if (op_index % 29 == 28) {
                try assertOracleMatches(db, &present, &expected_len, &expected_byte);
                try assertTreeInvariants(db);
                db.close();
                db = try open(std.testing.allocator, std.testing.io, path);
            }
        }

        try assertOracleMatches(db, &present, &expected_len, &expected_byte);
        try assertTreeInvariants(db);
        db.close();
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try assertOracleMatches(reopened, &present, &expected_len, &expected_byte);
    try assertTreeInvariants(reopened);
}

fn nextPseudoRandom(state: *u64) usize {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @intCast(state.* >> 16);
}

fn assertOracleMatches(
    db: *DB,
    present: *const [96]bool,
    expected_len: *const [96]usize,
    expected_byte: *const [96]u8,
) !void {
    var index: usize = 0;
    while (index < present.len) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        const value = try db.get(std.testing.allocator, key);
        defer if (value) |owned| std.testing.allocator.free(owned);

        if (present[index]) {
            try std.testing.expect(value != null);
            try std.testing.expectEqual(expected_len[index], value.?.len);
            if (value.?.len > 0) {
                try std.testing.expectEqual(expected_byte[index], value.?[0]);
                try std.testing.expectEqual(expected_byte[index], value.?[value.?.len - 1]);
            }
        } else {
            try std.testing.expect(value == null);
        }
    }

    const missing = try db.get(std.testing.allocator, "zz-nope");
    defer if (missing) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(missing == null);
}

test "put rejects non-tree root pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-non-tree-root.db");

    try bootstrapFile(path);

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        var branch_root = [_]u8{0} ** default_page_size;
        try page.encodeHeader(branch_root[0..], .{
            .page_id = 2,
            .page_type = .allocator,
            .count = 0,
            .order = 0,
        });
        try page.encodeDataHeader(branch_root[0..], .{
            .lower = page.data_header_size,
            .upper = default_page_size,
            .flags = 0,
        });
        try storage.writePageObject(&file, io, default_page_size, 2, branch_root[0..]);
    }

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectError(error.UnexpectedPageType, db.put("alpha", "one"));
}

fn encodeLeafObjectFixture(allocator: std.mem.Allocator, page_id: u64, order: u8, entries: []const page.LeafEntry) ![]u8 {
    const span_size = try page.spanSize(default_page_size, order);
    const leaf_page = try allocator.alloc(u8, span_size);
    errdefer allocator.free(leaf_page);
    @memset(leaf_page, 0);

    _ = try page.LeafPage.encodeInto(leaf_page, .{
        .page_id = page_id,
        .page_type = .leaf,
        .count = 0,
        .order = order,
    }, entries);

    return leaf_page;
}

test "writePageObject stores order one and two objects at base-page offsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "page-object-offsets.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const order1_page = try encodeLeafObjectFixture(std.testing.allocator, 2, 1, &.{
        .{ .key = "a", .value = "one", .flags = 0 },
    });
    defer std.testing.allocator.free(order1_page);

    const order2_page = try encodeLeafObjectFixture(std.testing.allocator, 4, 2, &.{
        .{ .key = "b", .value = "two", .flags = 0 },
    });
    defer std.testing.allocator.free(order2_page);

    try storage.writePageObject(&file, io, default_page_size, 2, order1_page);
    try storage.writePageObject(&file, io, default_page_size, 4, order2_page);

    const read_order1 = try readTreePageObjectAlloc(std.testing.allocator, &file, io, 2, default_page_size, 7);
    defer std.testing.allocator.free(read_order1);
    try std.testing.expectEqual(order1_page.len, read_order1.len);
    try std.testing.expectEqualSlices(u8, order1_page, read_order1);

    const read_order2 = try readTreePageObjectAlloc(std.testing.allocator, &file, io, 4, default_page_size, 7);
    defer std.testing.allocator.free(read_order2);
    try std.testing.expectEqual(order2_page.len, read_order2.len);
    try std.testing.expectEqualSlices(u8, order2_page, read_order2);
}

test "writePageObject writes order zero page after a higher-order object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "page-object-after-high-order.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const order1_page = try encodeLeafObjectFixture(std.testing.allocator, 2, 1, &.{
        .{ .key = "wide", .value = "left", .flags = 0 },
    });
    defer std.testing.allocator.free(order1_page);
    const order0_page = try encodeLeafObjectFixture(std.testing.allocator, 4, 0, &.{
        .{ .key = "tail", .value = "right", .flags = 0 },
    });
    defer std.testing.allocator.free(order0_page);

    try storage.writePageObject(&file, io, default_page_size, 2, order1_page);
    try storage.writePageObject(&file, io, default_page_size, 4, order0_page);

    const read_tail = try readTreePageObjectAlloc(std.testing.allocator, &file, io, 4, default_page_size, 4);
    defer std.testing.allocator.free(read_tail);
    const tail = try page.LeafPage.validate(read_tail);
    const entry = try tail.entry(0);
    try std.testing.expectEqualSlices(u8, "tail", entry.key);
    try std.testing.expectEqualSlices(u8, "right", entry.value);
}

test "put stores a single large value in a higher-order root leaf across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-large-root-leaf.db");

    var large_value = [_]u8{'L'} ** 7000;

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("large", large_value[0..]);
        try std.testing.expectEqual(@as(u64, 4), db.root_page_id);
        try std.testing.expectEqual(@as(u64, 5), db.high_water_mark);
        try std.testing.expectEqual(@as(u64, 3), db.allocator_root);
        try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));

        const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
        defer std.testing.allocator.free(root_page);
        const root_header = try page.decodeHeader(root_page);
        try std.testing.expectEqual(@as(u8, 1), root_header.order);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    const value = (try reopened.get(std.testing.allocator, "large")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, large_value[0..], value);
}

test "put failure does not commit working allocator state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-too-large-keeps-allocator.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const initial_high_water_mark = db.high_water_mark;
    const initial_txid = db.txid;
    const huge_value = try std.testing.allocator.alloc(u8, 70000);
    defer std.testing.allocator.free(huge_value);
    @memset(huge_value, 'H');

    try std.testing.expectError(error.KeyValueTooLarge, db.put("huge", huge_value));
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));

    var large_value = [_]u8{'L'} ** 7000;
    try db.put("large", large_value[0..]);
    try std.testing.expectEqual(@as(u64, 4), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 5), db.high_water_mark);
    try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));
}

test "open keeps legacy allocator_root zero as empty free lists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "legacy-empty-allocator.db");
    try bootstrapFile(path);

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectEqual(@as(u64, 0), db.allocator_root);
    try std.testing.expectEqual(@as(usize, 0), try db.page_allocator.freeBlockCount());
}

test "open restores older snapshot when newer allocator state is corrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "allocator-state-fallback.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();
        try db.put("old", "one");
        try db.put("new", "two");

        const newest_allocator_root = db.allocator_root;
        const io = db.io;
        var allocator_state = try readAllocatorStatePageObjectAlloc(
            std.testing.allocator,
            &db.file,
            io,
            newest_allocator_root,
            db.page_size,
            db.high_water_mark,
        );
        defer std.testing.allocator.free(allocator_state);

        allocator_state[8] = @intFromEnum(page.PageType.leaf);
        try storage.writePageObject(&db.file, io, db.page_size, newest_allocator_root, allocator_state);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(u64, 1), reopened.txid);
    try expectDbValue(reopened, "old", "one");
    const value = try reopened.get(std.testing.allocator, "new");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "open restores older snapshot when newer allocator pending txid is impossible" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "allocator-state-pending-txid-fallback.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();
        try db.put("old", "one");
        try db.put("new", "two");

        const newest_allocator_root = db.allocator_root;
        const io = db.io;
        const allocator_state = try readAllocatorStatePageObjectAlloc(
            std.testing.allocator,
            &db.file,
            io,
            newest_allocator_root,
            db.page_size,
            db.high_water_mark,
        );
        defer std.testing.allocator.free(allocator_state);
        const header = try page.decodeHeader(allocator_state);

        const invalid_state = try std.testing.allocator.alloc(u8, allocator_state.len);
        defer std.testing.allocator.free(invalid_state);
        _ = try page.AllocatorStatePage.encodeInto(invalid_state, .{
            .page_id = newest_allocator_root,
            .page_type = .allocator,
            .count = 0,
            .order = header.order,
        }, &.{.{
            .kind = .pending,
            .page_id = 3,
            .order = 0,
            .visible_through_txid = db.txid + 1,
        }});
        try storage.writePageObject(&db.file, io, db.page_size, newest_allocator_root, invalid_state);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(u64, 1), reopened.txid);
    try expectDbValue(reopened, "old", "one");
    const value = try reopened.get(std.testing.allocator, "new");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "open ignores allocator state page that is not referenced by meta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "unreferenced-allocator-state.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();
        try db.put("old", "one");

        var candidate = try db.page_allocator.clone(db.allocator);
        defer candidate.deinit(db.allocator);
        const unreferenced_root = try candidate.allocate(db.allocator, 0);
        const state_page = try candidate.encodeStatePageAlloc(std.testing.allocator, db.page_size, unreferenced_root, 0, &.{});
        defer std.testing.allocator.free(state_page);
        try storage.writePageObject(&db.file, db.io, db.page_size, unreferenced_root, state_page);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(u64, 1), reopened.txid);
    try expectDbValue(reopened, "old", "one");
}

test "open restores order greater than zero allocator state pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "higher-order-allocator-state.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();
        db.page_allocator.high_water_mark = 2040;

        var index: u64 = 0;
        while (index < 510) : (index += 1) {
            try db.page_allocator.release(db.allocator, 4 + index * 4, 0);
        }

        try db.put("alpha", "one");
        const allocator_state = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
        defer std.testing.allocator.free(allocator_state);
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    const state_page = try readAllocatorStatePageObjectAlloc(
        std.testing.allocator,
        &reopened.file,
        reopened.io,
        reopened.allocator_root,
        reopened.page_size,
        reopened.high_water_mark,
    );
    defer std.testing.allocator.free(state_page);

    const header = try page.decodeHeader(state_page);
    try std.testing.expect(header.order > 0);
    try expectDbValue(reopened, "alpha", "one");
}

test "allocator state fixed point retry discards failed candidate allocations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "allocator-state-fixed-point.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();
    db.page_allocator.high_water_mark = 2040;

    var index: u64 = 0;
    while (index < 510) : (index += 1) {
        try db.page_allocator.release(db.allocator, 4 + index * 4, 0);
    }

    try db.put("alpha", "one");

    const state_page = try readAllocatorStatePageObjectAlloc(
        std.testing.allocator,
        &db.file,
        db.io,
        db.allocator_root,
        db.page_size,
        db.high_water_mark,
    );
    defer std.testing.allocator.free(state_page);

    const header = try page.decodeHeader(state_page);
    try std.testing.expectEqual(@as(u8, 2), header.order);
    try std.testing.expect(db.page_allocator.containsFreeBlock(2041, 0));
    try std.testing.expect(!db.page_allocator.containsFreeBlock(2042, 1));
}

test "root leaf split uses actual non adjacent allocated page ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-root-split-non-adjacent-free.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var value_buf: [160]u8 = undefined;
    const value = fillFixedValue(&value_buf, 'x');

    var index: usize = 0;
    while (index < 23) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value);
    }

    db.high_water_mark = 52;
    db.page_allocator.high_water_mark = 52;
    for (db.reclaim.pending.items) |pending_release| {
        db.allocator.free(pending_release.pages);
    }
    db.reclaim.pending.clearRetainingCapacity();
    try db.page_allocator.release(db.allocator, 50, 0);
    try db.page_allocator.release(db.allocator, 52, 0);

    var key_buf: [5]u8 = undefined;
    const split_key = try generatedKey(&key_buf, 23);
    try db.put(split_key, value);

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const root_branch = try page.BranchPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 2), root_branch.count());

    const left_entry = try root_branch.entry(0);
    const right_entry = try root_branch.entry(1);
    try std.testing.expect(left_entry.child_page_id == 50 or left_entry.child_page_id == 52);
    try std.testing.expect(right_entry.child_page_id == 50 or right_entry.child_page_id == 52);
    try std.testing.expect(left_entry.child_page_id != right_entry.child_page_id);
    try std.testing.expect(left_entry.child_page_id + 1 != right_entry.child_page_id);
    try std.testing.expect(right_entry.child_page_id + 1 != left_entry.child_page_id);
}

test "put rejects a single value larger than the u16-bounded tree page span" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-too-large-root-leaf.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const huge_value = try std.testing.allocator.alloc(u8, 40000);
    defer std.testing.allocator.free(huge_value);
    @memset(huge_value, 'H');

    try std.testing.expectError(error.KeyValueTooLarge, db.put("huge", huge_value));
}

test "readPageAlloc rejects page object order beyond the tree layout limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bad-page-object-order.db");

    try bootstrapFile(path);

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        var root_page = [_]u8{0} ** default_page_size;
        try page.LeafPage.init(root_page[0..], .{
            .page_id = 2,
            .page_type = .leaf,
            .count = 0,
            .order = 4,
        });
        try storage.writePageObject(&file, io, default_page_size, 2, root_page[0..]);
    }

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectError(error.InvalidPageOrder, db.readPageAlloc(std.testing.allocator, 2));
}

test "readPageAlloc rejects page object spans beyond the high water mark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "page-object-past-hwm.db");

    try bootstrapFile(path);

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        const root_page = try encodeLeafObjectFixture(std.testing.allocator, 2, 1, &.{});
        defer std.testing.allocator.free(root_page);
        try storage.writePageObject(&file, io, default_page_size, 2, root_page);
    }

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectError(error.EntryOutOfBounds, db.readPageAlloc(std.testing.allocator, 2));
}

test "readPageAlloc rejects page objects whose header id does not match the requested id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "page-object-id-mismatch.db");

    try bootstrapFile(path);

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        var root_page = [_]u8{0} ** default_page_size;
        try page.LeafPage.init(root_page[0..], .{
            .page_id = 3,
            .page_type = .leaf,
            .count = 0,
            .order = 0,
        });
        try storage.writePageObject(&file, io, default_page_size, 2, root_page[0..]);
    }

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expectError(error.InvalidPageLayout, db.readPageAlloc(std.testing.allocator, 2));
}

test "explicit write transaction commit persists a staged put" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-commit.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.put("alpha", "one");
    try write_tx.commit();

    try std.testing.expectEqual(@as(u64, 1), db.txid);
    try expectDbValue(db, "alpha", "one");
}

test "explicit write transaction rollback discards staged pages and preserves committed state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-rollback.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const initial_txid = db.txid;
    const initial_high_water_mark = db.high_water_mark;

    var write_tx = try db.beginWrite();
    try write_tx.put("alpha", "one");
    try write_tx.rollback();

    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expect(!db.write_tx_active);
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.pending.items.len);

    const value = try db.get(std.testing.allocator, "alpha");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "write transaction exposes a single writer slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-single-writer.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try std.testing.expectError(tx.WriteTxError.WriteTransactionActive, db.beginWrite());
}

test "write transaction deinit releases the writer slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-deinit.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    {
        var write_tx = try db.beginWrite();
        try write_tx.put("alpha", "one");
        write_tx.deinit();
    }

    try std.testing.expect(!db.write_tx_active);

    var next_write_tx = try db.beginWrite();
    defer next_write_tx.deinit();
    try next_write_tx.put("beta", "two");
    try next_write_tx.commit();
    try expectDbValue(db, "beta", "two");
}

test "write transaction commits multiple staged puts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-single-put.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "one");
    try write_tx.put("beta", "two");
    try write_tx.commit();

    try expectDbValue(db, "alpha", "one");
    try expectDbValue(db, "beta", "two");
}

test "write transaction keeps the last value for repeated puts to the same key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-repeat-key.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "one");
    try write_tx.put("alpha", "two");
    try write_tx.commit();

    try expectDbValue(db, "alpha", "two");
}

test "write transaction reads its staged root writes through get scan and cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-staged-root-reads.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "two");
    try write_tx.put("beta", "three");

    const staged_alpha = (try write_tx.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(staged_alpha);
    try std.testing.expectEqualSlices(u8, "two", staged_alpha);

    try expectScanRecords(
        try write_tx.scanAlloc(std.testing.allocator, .{
            .start_inclusive = "alpha",
            .end_exclusive = "z",
        }),
        &.{
            .{ .key = "alpha", .value = "two" },
            .{ .key = "beta", .value = "three" },
        },
    );

    var cursor = try write_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alpha", "two");

    var second = (try cursor.next(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try expectCursorRecord(second, "beta", "three");

    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    try expectDbValue(db, "alpha", "one");
    try expectDbMissing(db, "beta");
}

test "write transaction reads staged nested bucket changes before commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-staged-bucket-reads.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("orgs");

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.createBucketInBucketPath(orgs_path[0..], "engineering");
    try write_tx.putInBucketPath(engineering_path[0..], "alice", "admin");
    try write_tx.putInBucketPath(engineering_path[0..], "bob", "reader");

    try std.testing.expect(try write_tx.bucketExistsInBucketPath(std.testing.allocator, orgs_path[0..], "engineering"));

    const staged_alice = (try write_tx.getInBucketPath(std.testing.allocator, engineering_path[0..], "alice")).?;
    defer std.testing.allocator.free(staged_alice);
    try std.testing.expectEqualSlices(u8, "admin", staged_alice);

    try expectBucketNames(
        try write_tx.bucketNamesInBucketPathAlloc(std.testing.allocator, orgs_path[0..]),
        &.{"engineering"},
    );

    try expectScanRecords(
        try write_tx.scanInBucketPathAlloc(std.testing.allocator, engineering_path[0..], .{
            .start_inclusive = "a",
            .end_exclusive = "z",
        }),
        &.{
            .{ .key = "alice", .value = "admin" },
            .{ .key = "bob", .value = "reader" },
        },
    );

    var cursor = try write_tx.cursorInBucketPath(engineering_path[0..]);
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "admin");

    try std.testing.expectError(error.BucketNotFound, db.getInBucketPath(std.testing.allocator, engineering_path[0..], "alice"));
}

test "write transaction keeps earlier staged pages that are still referenced by the final root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-staged-page-survives.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        var value_buf = [_]u8{'x'} ** 160;
        var index: usize = 0;
        while (index < 24) : (index += 1) {
            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, index);
            try db.put(key, value_buf[0..]);
        }

        var write_tx = try db.beginWrite();
        defer write_tx.rollback() catch {};

        try write_tx.put("k0000", "left");

        const first_root_page_id = write_tx.view.?.current_root_page_id;
        const first_root_page = stagedPageBytes(&write_tx, first_root_page_id);
        const first_root_branch = try page.BranchPage.validate(first_root_page);
        const first_left_child = try first_root_branch.entry(0);
        const first_right_child = try first_root_branch.entry(1);

        try write_tx.put("k0023", "right");

        try std.testing.expect(!write_tx.view.?.staged_pages.contains(first_root_page_id));
        try std.testing.expect(write_tx.view.?.staged_pages.contains(first_left_child.child_page_id));

        const second_root_branch = try stagedRootBranch(&write_tx);
        try std.testing.expectEqual(@as(u16, 2), second_root_branch.count());
        const second_left_child = try second_root_branch.entry(0);
        const second_right_child = try second_root_branch.entry(1);
        try std.testing.expectEqual(first_left_child.child_page_id, second_left_child.child_page_id);
        try std.testing.expect(second_right_child.child_page_id != first_right_child.child_page_id);

        try write_tx.commit();

        try expectDbValue(db, "k0000", "left");
        try expectDbValue(db, "k0023", "right");
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectDbValue(reopened, "k0000", "left");
    try expectDbValue(reopened, "k0023", "right");
}

test "db delete removes a committed key and persists the change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "db-delete-persist.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("alpha", "one");
        try db.put("beta", "two");

        try db.delete("alpha");

        try expectDbMissing(db, "alpha");
        try expectDbValue(db, "beta", "two");
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectDbMissing(reopened, "alpha");
    try expectDbValue(reopened, "beta", "two");
}

test "db delete missing key is a no-op for txid high water mark and reclaim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "db-delete-missing.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    const initial_txid = db.txid;
    const initial_high_water_mark = db.high_water_mark;

    try db.delete("missing");

    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.pending.items.len);
    try expectDbValue(db, "alpha", "one");
}

test "write transaction delete can be combined with staged puts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-delete-with-put.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("beta", "two");
    try write_tx.delete("alpha");
    try write_tx.commit();

    try expectDbMissing(db, "alpha");
    try expectDbValue(db, "beta", "two");
}

test "write transaction delete of a staged key still allows commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-delete-staged-key.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "one");
    try write_tx.put("beta", "two");
    try write_tx.delete("alpha");
    try write_tx.commit();

    try expectDbMissing(db, "alpha");
    try expectDbValue(db, "beta", "two");
}

test "db delete collapses a merged two leaf root back into one leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "db-delete-root-collapse.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 24) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    const root_before = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_before);
    _ = try page.BranchPage.validate(root_before);

    try db.delete("k0000");

    const root_after = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_after);
    const root_leaf = try page.LeafPage.validate(root_after);
    try std.testing.expect(root_leaf.count() > 0);
    try expectDbMissing(db, "k0000");
    try expectDbValue(db, "k0023", value_buf[0..]);
    try assertTreeInvariants(db);
}

test "db delete of the final key leaves an empty root leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "db-delete-final-key.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    try db.delete("alpha");

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const root_leaf = try page.LeafPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 0), root_leaf.count());
    try expectDbMissing(db, "alpha");
}

test "write transaction does not reclaim superseded staged pages as committed pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-staged-vs-committed-reclaim.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "zero");

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "one");
    try std.testing.expectEqual(@as(usize, 1), write_tx.view.?.reclaim_committed_pages.count());

    try write_tx.put("alpha", "two");
    try std.testing.expectEqual(@as(usize, 1), write_tx.view.?.reclaim_committed_pages.count());

    try write_tx.commit();
    try std.testing.expectEqual(@as(usize, 1), db.reclaim.pending.items.len);
    try std.testing.expectEqual(@as(usize, 2), db.reclaim.pending.items[0].pages.len);
    try expectDbValue(db, "alpha", "two");
}

test "read transaction keeps its snapshot after an explicit write commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-read-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    const snapshot_root_page_id = read_tx.snapshot.root_page_id;
    const snapshot_high_water_mark = read_tx.snapshot.high_water_mark;
    const committed_root_page_id = db.root_page_id;
    const committed_high_water_mark = db.high_water_mark;

    var write_tx = try db.beginWrite();
    try write_tx.put("beta", "two");
    try write_tx.commit();

    const snapshot_value = try read_tx.get(std.testing.allocator, "beta");
    defer if (snapshot_value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(snapshot_value == null);
    try std.testing.expectEqual(snapshot_root_page_id, read_tx.snapshot.root_page_id);
    try std.testing.expectEqual(snapshot_high_water_mark, read_tx.snapshot.high_water_mark);
    try std.testing.expect(db.root_page_id != committed_root_page_id);
    try std.testing.expect(db.high_water_mark != committed_high_water_mark);
    try expectDbValue(db, "beta", "two");
}

test "commit failure releases the writer slot and leaves the transaction failed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-commit-failure.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.put("alpha", "one");

    const initial_txid = db.txid;
    const initial_high_water_mark = db.high_water_mark;
    const io = db.io;
    db.file.close(io);
    db.file_open = false;

    var commit_failed = false;
    write_tx.commit() catch {
        commit_failed = true;
    };
    try std.testing.expect(commit_failed);
    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expect(!db.write_tx_active);
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.pending.items.len);
    try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.put("beta", "two"));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.commit());
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.rollback());

    db.file = try std.Io.Dir.openFileAbsolute(io, db.path, .{ .mode = .read_write });
    db.file_open = true;

    var next_write_tx = try db.beginWrite();
    try next_write_tx.put("beta", "two");
    try next_write_tx.commit();
    try expectDbValue(db, "beta", "two");
}

test "write transaction commit without a staged write returns NoPendingWrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-no-pending-write.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try std.testing.expectError(tx.WriteTxError.NoPendingWrite, write_tx.commit());
    try std.testing.expect(db.write_tx_active);
}

test "rolled back write transaction rejects put commit and rollback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-closed-after-rollback.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.rollback();

    try std.testing.expect(!db.write_tx_active);
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.put("alpha", "one"));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.get(std.testing.allocator, "alpha"));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.cursor());
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.scanAlloc(std.testing.allocator, .{}));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.commit());
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.rollback());
}

test "reclaim reuses released pages on the next write when no readers block reuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "reclaim-reuses-without-readers.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    try db.put("alpha", "two");

    try std.testing.expectEqual(@as(usize, 1), db.reclaim.pending.items.len);
    try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));
    const high_water_mark_before_reuse = db.high_water_mark;

    try db.put("alpha", "three");

    try std.testing.expectEqual(high_water_mark_before_reuse, db.high_water_mark);
    try expectDbValue(db, "alpha", "three");
}

test "reclaim keeps released pages pending while a read transaction is still active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "reclaim-blocked-by-reader.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try db.put("alpha", "two");
    try std.testing.expectEqual(@as(usize, 1), db.reclaim.pending.items.len);
    try std.testing.expect(!db.page_allocator.containsFreeBlock(3, 0));

    try db.put("alpha", "three");

    try std.testing.expect(db.root_page_id != 3);
    try std.testing.expectEqual(@as(usize, 2), db.reclaim.pending.items.len);
    try expectDbValue(db, "alpha", "three");
}

test "reclaim reuses released pages after the blocking read transaction ends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "reclaim-reuses-after-reader-ends.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    try db.put("alpha", "two");

    try std.testing.expectEqual(@as(usize, 1), db.reclaim.pending.items.len);
    read_tx.deinit();
    const high_water_mark_before_reuse = db.high_water_mark;

    try db.put("alpha", "three");

    try std.testing.expectEqual(high_water_mark_before_reuse, db.high_water_mark);
    try expectDbValue(db, "alpha", "three");
}

test "reopen restores and safely releases persisted pending reclaim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "reclaim-pending-restored-on-reopen.db");
    var released_allocator_root: reclaim.ReleasedPage = undefined;

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("alpha", "one");
        released_allocator_root = (try currentAllocatorRootRelease(db)).?;
        try db.put("alpha", "two");

        try std.testing.expectEqual(@as(usize, 1), db.reclaim.pending.items.len);
        try std.testing.expectEqual(@as(usize, 0), try db.page_allocator.freeBlockCount());
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();

    try std.testing.expectEqual(@as(usize, 0), reopened.reclaim.pending.items.len);
    try std.testing.expect(reopened.page_allocator.containsFreeBlock(3, 0));
    try std.testing.expect(reopened.page_allocator.containsFreeBlock(released_allocator_root.page_id, released_allocator_root.order));
    try expectDbValue(reopened, "alpha", "two");
    const high_water_mark_before_reuse = reopened.high_water_mark;

    try reopened.put("alpha", "three");
    try std.testing.expectEqual(high_water_mark_before_reuse, reopened.high_water_mark);
    try expectDbValue(reopened, "alpha", "three");
}

test "compact rewrites an empty database into a reopenable file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-empty.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.compact(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 2), db.high_water_mark);
    try std.testing.expectEqual(@as(u64, 0), db.allocator_root);

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try std.testing.expectEqual(@as(u64, 2), reopened.root_page_id);
    try std.testing.expectEqual(@as(u64, 2), reopened.high_water_mark);
}

test "compact preserves data clears pending reclaim and shrinks the high water mark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-shrinks.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    var read_tx = try db.beginRead();
    try db.put("alpha", "two");
    try db.put("alpha", "three");

    try std.testing.expect(db.high_water_mark > 2);
    try std.testing.expect(db.reclaim.pending.items.len > 0);
    read_tx.deinit();

    const high_water_mark_before = db.high_water_mark;
    try db.compact(std.testing.allocator);

    try std.testing.expect(db.high_water_mark < high_water_mark_before);
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.pending.items.len);
    try std.testing.expectEqual(@as(u64, 0), db.allocator_root);
    try expectDbValue(db, "alpha", "three");

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectDbValue(reopened, "alpha", "three");
    try std.testing.expectEqual(db.high_water_mark, reopened.high_water_mark);
}

test "compact preserves cursor order across a multi-level tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-cursor.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 261) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    try db.compact(std.testing.allocator);

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var count: usize = 0;
    while (try (if (count == 0) cursor.first(std.testing.allocator) else cursor.next(std.testing.allocator))) |record| {
        var owned = record;
        defer owned.deinit(std.testing.allocator);
        var key_buf: [5]u8 = undefined;
        const expected = try generatedKey(&key_buf, count);
        try std.testing.expectEqualSlices(u8, expected, owned.key);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 261), count);
}

test "compact preserves higher-order leaf pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-large-value.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var large_value = [_]u8{'L'} ** 7000;
    try db.put("large", large_value[0..]);

    const before = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(before);
    const before_header = try page.decodeHeader(before);

    try db.compact(std.testing.allocator);
    try expectDbValue(db, "large", large_value[0..]);

    const after = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(after);
    const after_header = try page.decodeHeader(after);
    try std.testing.expectEqual(before_header.order, after_header.order);
}

test "compact keeps active read transactions on their original snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-active-reader.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    try db.put("beta", "two");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try db.put("alpha", "three");
    try db.put("gamma", "four");

    try expectReadTxValue(read_tx, "alpha", "one");
    try expectReadTxMissing(read_tx, "gamma");

    try db.compact(std.testing.allocator);

    try expectReadTxValue(read_tx, "alpha", "one");
    try expectReadTxMissing(read_tx, "gamma");

    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var count: usize = 0;
    while (try (if (count == 0) cursor.first(std.testing.allocator) else cursor.next(std.testing.allocator))) |record| {
        var owned = record;
        defer owned.deinit(std.testing.allocator);

        switch (count) {
            0 => {
                try std.testing.expectEqualSlices(u8, "alpha", owned.key);
                try std.testing.expectEqualSlices(u8, "one", owned.value);
            },
            1 => {
                try std.testing.expectEqualSlices(u8, "beta", owned.key);
                try std.testing.expectEqualSlices(u8, "two", owned.value);
            },
            else => return error.UnexpectedRecordCount,
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    try expectDbValue(db, "alpha", "three");
    try expectDbValue(db, "gamma", "four");
}

test "compact rejects an active write transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "compact-active-write.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};
    try std.testing.expectError(error.WriteTransactionActive, db.compact(std.testing.allocator));
}

test "bucket create put delete round trips across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-round-trip.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.createBucket("users");
        try db.putInBucket("users", "alice", "admin");
        try db.putInBucket("users", "bob", "reader");
        try expectBucketValue(db, "users", "alice", "admin");
        try expectBucketValue(db, "users", "bob", "reader");
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectBucketValue(reopened, "users", "alice", "admin");
    try expectBucketValue(reopened, "users", "bob", "reader");

    try reopened.deleteInBucket("users", "alice");
    try expectBucketMissing(reopened, "users", "alice");
    try reopened.deleteBucket("users");
    try std.testing.expectError(error.BucketNotFound, reopened.getInBucket(std.testing.allocator, "users", "bob"));
}

test "bucket names are protected from root key operations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-root-guards.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try std.testing.expectError(error.KeyBelongsToBucket, db.get(std.testing.allocator, "users"));
    try std.testing.expectError(error.KeyBelongsToBucket, db.put("users", "conflict"));
    try std.testing.expectError(error.KeyBelongsToBucket, db.delete("users"));

    try db.put("plain", "value");
    try std.testing.expectError(error.BucketNameConflict, db.createBucket("plain"));
    try std.testing.expectError(error.KeyNotBucket, db.putInBucket("plain", "alice", "admin"));
}

test "bucketExists distinguishes buckets from plain root keys and tracks deletes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-exists.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try std.testing.expect(!(try db.bucketExists(std.testing.allocator, "users")));
    try db.put("plain", "value");
    try db.createBucket("users");

    try std.testing.expect(try db.bucketExists(std.testing.allocator, "users"));
    try std.testing.expect(!(try db.bucketExists(std.testing.allocator, "plain")));

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    try std.testing.expect(try read_tx.bucketExists(std.testing.allocator, "users"));
    try std.testing.expect(!(try read_tx.bucketExists(std.testing.allocator, "plain")));

    try db.deleteBucket("users");

    try std.testing.expect(!(try db.bucketExists(std.testing.allocator, "users")));
    try std.testing.expect(try read_tx.bucketExists(std.testing.allocator, "users"));
}

test "bucketNamesAlloc returns only bucket names in key order across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-names.db");

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.put("plain", "value");
        try db.createBucket("users");
        try db.createBucket("archive");
        try db.createBucket("zeta");

        try expectBucketNames(try db.bucketNamesAlloc(std.testing.allocator), &.{ "archive", "users", "zeta" });
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectBucketNames(try reopened.bucketNamesAlloc(std.testing.allocator), &.{ "archive", "users", "zeta" });
}

test "bucketNamesAlloc keeps read snapshots stable after namespace changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-names-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.createBucket("teams");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try db.createBucket("archive");
    try db.deleteBucket("teams");
    try db.put("plain", "value");

    try expectBucketNames(try read_tx.bucketNamesAlloc(std.testing.allocator), &.{ "teams", "users" });
    try expectBucketNames(try db.bucketNamesAlloc(std.testing.allocator), &.{ "archive", "users" });
}

test "bucket writes keep earlier read snapshots stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try db.putInBucket("users", "alice", "two");
    try db.putInBucket("users", "bob", "three");

    const alice_before = (try read_tx.getInBucket(std.testing.allocator, "users", "alice")).?;
    defer std.testing.allocator.free(alice_before);
    try std.testing.expectEqualSlices(u8, "one", alice_before);

    const bob_before = try read_tx.getInBucket(std.testing.allocator, "users", "bob");
    defer if (bob_before) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(bob_before == null);

    try expectBucketValue(db, "users", "alice", "two");
    try expectBucketValue(db, "users", "bob", "three");
}

test "bucket cursor traverses entries in order and supports seek" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-cursor.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "gamma", "three");
    try db.putInBucket("users", "alpha", "one");
    try db.putInBucket("users", "omega", "four");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = try read_tx.cursorInBucket("users");
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alpha", "one");

    var seek = (try cursor.seek(std.testing.allocator, "delta")).?;
    defer seek.deinit(std.testing.allocator);
    try expectCursorRecord(seek, "gamma", "three");

    var next = (try cursor.next(std.testing.allocator)).?;
    defer next.deinit(std.testing.allocator);
    try expectCursorRecord(next, "omega", "four");

    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);

    var last = (try cursor.last(std.testing.allocator)).?;
    defer last.deinit(std.testing.allocator);
    try expectCursorRecord(last, "omega", "four");

    var prev = (try cursor.prev(std.testing.allocator)).?;
    defer prev.deinit(std.testing.allocator);
    try expectCursorRecord(prev, "gamma", "three");
}

test "bucket cursor reports missing and non-bucket namespace entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-cursor-errors.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("plain", "value");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try std.testing.expectError(error.BucketNotFound, read_tx.cursorInBucket("users"));
    try std.testing.expectError(error.KeyNotBucket, read_tx.cursorInBucket("plain"));
}

test "bucket cursor keeps its snapshot stable after bucket writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-cursor-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = try read_tx.cursorInBucket("users");
    defer cursor.deinit();

    try db.putInBucket("users", "alice", "two");
    try db.putInBucket("users", "bob", "three");

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");
    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    try std.testing.expect((try cursor.seek(std.testing.allocator, "bob")) == null);

    try expectBucketValue(db, "users", "alice", "two");
    try expectBucketValue(db, "users", "bob", "three");
}

test "deleteBucket keeps the removed bucket visible to older snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-delete-reclaim.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");
    try db.putInBucket("users", "bob", "two");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    try db.deleteBucket("users");

    const alice_before = (try read_tx.getInBucket(std.testing.allocator, "users", "alice")).?;
    defer std.testing.allocator.free(alice_before);
    try std.testing.expectEqualSlices(u8, "one", alice_before);

    try std.testing.expectError(error.BucketNotFound, db.getInBucket(std.testing.allocator, "users", "alice"));
}

test "bucket cursor keeps the removed bucket visible to older snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bucket-cursor-delete-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");
    try db.putInBucket("users", "bob", "two");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = try read_tx.cursorInBucket("users");
    defer cursor.deinit();

    try db.deleteBucket("users");

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");

    var second = (try cursor.next(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try expectCursorRecord(second, "bob", "two");

    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    try std.testing.expectError(error.BucketNotFound, db.getInBucket(std.testing.allocator, "users", "alice"));
}

test "nested bucket create put delete round trips across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "nested-bucket-round-trip.db");

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    {
        const db = try open(std.testing.allocator, std.testing.io, path);
        defer db.close();

        try db.createBucket("orgs");
        try db.createBucketInBucketPath(orgs_path[0..], "engineering");
        try db.putInBucketPath(engineering_path[0..], "alice", "admin");
        try db.putInBucketPath(engineering_path[0..], "bob", "reader");
        try expectBucketPathValue(db, engineering_path[0..], "alice", "admin");
        try expectBucketPathValue(db, engineering_path[0..], "bob", "reader");
    }

    const reopened = try open(std.testing.allocator, std.testing.io, path);
    defer reopened.close();
    try expectBucketPathValue(reopened, engineering_path[0..], "alice", "admin");
    try expectBucketPathValue(reopened, engineering_path[0..], "bob", "reader");

    try reopened.deleteInBucketPath(engineering_path[0..], "alice");
    try expectBucketPathMissing(reopened, engineering_path[0..], "alice");
    try reopened.deleteBucketInBucketPath(orgs_path[0..], "engineering");
    try std.testing.expectError(error.BucketNotFound, reopened.getInBucketPath(std.testing.allocator, engineering_path[0..], "bob"));
}

test "nested bucket names and existence stay scoped to the parent bucket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "nested-bucket-names.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const orgs_path = [_][]const u8{"orgs"};
    const plain_path = [_][]const u8{ "orgs", "plain" };

    try db.createBucket("orgs");
    try db.createBucketInBucketPath(orgs_path[0..], "engineering");
    try db.createBucketInBucketPath(orgs_path[0..], "finance");
    try db.putInBucketPath(orgs_path[0..], "plain", "value");

    try std.testing.expect(try db.bucketExistsInBucketPath(std.testing.allocator, orgs_path[0..], "engineering"));
    try std.testing.expect(try db.bucketExistsInBucketPath(std.testing.allocator, orgs_path[0..], "finance"));
    try std.testing.expect(!(try db.bucketExistsInBucketPath(std.testing.allocator, orgs_path[0..], "plain")));
    try expectBucketNames(
        try db.bucketNamesInBucketPathAlloc(std.testing.allocator, orgs_path[0..]),
        &.{ "engineering", "finance" },
    );

    try std.testing.expectError(error.BucketNameConflict, db.createBucketInBucketPath(orgs_path[0..], "plain"));
    try std.testing.expectError(error.KeyNotBucket, db.putInBucketPath(plain_path[0..], "alice", "admin"));
}

test "nested bucket cursors and scans keep earlier snapshots stable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "nested-bucket-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    try db.createBucket("orgs");
    try db.createBucketInBucketPath(orgs_path[0..], "engineering");
    try db.putInBucketPath(engineering_path[0..], "alice", "one");
    try db.putInBucketPath(engineering_path[0..], "carol", "three");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = try read_tx.cursorInBucketPath(engineering_path[0..]);
    defer cursor.deinit();

    var managed_cursor = try db.cursorInBucketPath(engineering_path[0..]);
    defer managed_cursor.deinit();

    try db.putInBucketPath(engineering_path[0..], "bob", "two");
    try db.putInBucketPath(engineering_path[0..], "carol", "updated");

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");

    var second = (try cursor.next(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try expectCursorRecord(second, "carol", "three");
    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);

    try expectScanRecords(
        try read_tx.scanInBucketPathAlloc(std.testing.allocator, engineering_path[0..], .{
            .start_inclusive = "alice",
            .end_exclusive = "d",
        }),
        &.{
            .{ .key = "alice", .value = "one" },
            .{ .key = "carol", .value = "three" },
        },
    );

    var managed_first = (try managed_cursor.first(std.testing.allocator)).?;
    defer managed_first.deinit(std.testing.allocator);
    try expectCursorRecord(managed_first, "alice", "one");
    var managed_seek = (try managed_cursor.seek(std.testing.allocator, "bob")).?;
    defer managed_seek.deinit(std.testing.allocator);
    try expectCursorRecord(managed_seek, "carol", "three");

    try expectScanRecords(
        try db.scanInBucketPathAlloc(std.testing.allocator, engineering_path[0..], .{
            .start_inclusive = "alice",
            .end_exclusive = "d",
        }),
        &.{
            .{ .key = "alice", .value = "one" },
            .{ .key = "bob", .value = "two" },
            .{ .key = "carol", .value = "updated" },
        },
    );
}

test "deleteBucketInBucketPath keeps removed nested bucket visible to older snapshots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "nested-bucket-delete-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    try db.createBucket("orgs");
    try db.createBucketInBucketPath(orgs_path[0..], "engineering");
    try db.putInBucketPath(engineering_path[0..], "alice", "one");
    try db.putInBucketPath(engineering_path[0..], "bob", "two");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    try db.deleteBucketInBucketPath(orgs_path[0..], "engineering");

    const alice_before = (try read_tx.getInBucketPath(std.testing.allocator, engineering_path[0..], "alice")).?;
    defer std.testing.allocator.free(alice_before);
    try std.testing.expectEqualSlices(u8, "one", alice_before);

    var cursor = try read_tx.cursorInBucketPath(engineering_path[0..]);
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");

    var second = (try cursor.next(std.testing.allocator)).?;
    defer second.deinit(std.testing.allocator);
    try expectCursorRecord(second, "bob", "two");

    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    try std.testing.expectError(error.BucketNotFound, db.getInBucketPath(std.testing.allocator, engineering_path[0..], "alice"));
}

test "managed cursor traverses the latest root snapshot and releases its reader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-cursor-root.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("gamma", "three");
    try db.put("alpha", "one");
    try db.put("omega", "four");

    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());

    {
        var cursor = try db.cursor();
        defer cursor.deinit();

        try std.testing.expectEqual(@as(usize, 1), db.reclaim.activeReaderCount());

        var first = (try cursor.first(std.testing.allocator)).?;
        defer first.deinit(std.testing.allocator);
        try expectCursorRecord(first, "alpha", "one");

        var seek = (try cursor.seek(std.testing.allocator, "delta")).?;
        defer seek.deinit(std.testing.allocator);
        try expectCursorRecord(seek, "gamma", "three");

        var next = (try cursor.next(std.testing.allocator)).?;
        defer next.deinit(std.testing.allocator);
        try expectCursorRecord(next, "omega", "four");

        try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    }

    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
}

test "managed cursor deinit is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-cursor-deinit.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");

    var cursor = try db.cursor();
    try std.testing.expectEqual(@as(usize, 1), db.reclaim.activeReaderCount());

    cursor.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());

    cursor.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
}

test "managed bucket cursor keeps its snapshot stable after later writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-cursor-bucket.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");

    var cursor = try db.cursorInBucket("users");
    defer cursor.deinit();

    try db.putInBucket("users", "alice", "two");
    try db.putInBucket("users", "bob", "three");

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");

    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);
    try std.testing.expect((try cursor.seek(std.testing.allocator, "bob")) == null);

    try expectBucketValue(db, "users", "alice", "two");
    try expectBucketValue(db, "users", "bob", "three");
}

test "managed bucket cursor closes failed read snapshots on bucket lookup errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-cursor-bucket-errors.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("plain", "value");

    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
    try std.testing.expectError(error.BucketNotFound, db.cursorInBucket("users"));
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());

    try std.testing.expectError(error.KeyNotBucket, db.cursorInBucket("plain"));
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
}

test "managed read view keeps a stable snapshot across root and bucket reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-read-view-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    try db.put("plain", "before");
    try db.createBucket("orgs");
    try db.createBucketInBucketPath(orgs_path[0..], "engineering");
    try db.putInBucketPath(engineering_path[0..], "alice", "one");

    var view = try db.readView();
    defer view.deinit();

    try db.put("plain", "after");
    try db.putInBucketPath(engineering_path[0..], "alice", "updated");
    try db.putInBucketPath(engineering_path[0..], "bob", "two");

    const root_value = (try view.get(std.testing.allocator, "plain")).?;
    defer std.testing.allocator.free(root_value);
    try std.testing.expectEqualSlices(u8, "before", root_value);

    try std.testing.expect(try view.bucketExistsInBucketPath(std.testing.allocator, orgs_path[0..], "engineering"));

    const bucket_value = (try view.getInBucketPath(std.testing.allocator, engineering_path[0..], "alice")).?;
    defer std.testing.allocator.free(bucket_value);
    try std.testing.expectEqualSlices(u8, "one", bucket_value);

    try expectScanRecords(
        try view.scanInBucketPathAlloc(std.testing.allocator, engineering_path[0..], .{
            .start_inclusive = "a",
            .end_exclusive = "z",
        }),
        &.{
            .{ .key = "alice", .value = "one" },
        },
    );

    var cursor = try view.cursorInBucketPath(engineering_path[0..]);
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alice", "one");
    try std.testing.expect((try cursor.next(std.testing.allocator)) == null);

    const current_root_value = (try db.get(std.testing.allocator, "plain")).?;
    defer std.testing.allocator.free(current_root_value);
    try std.testing.expectEqualSlices(u8, "after", current_root_value);

    try expectBucketPathValue(db, engineering_path[0..], "alice", "updated");
    try expectBucketPathValue(db, engineering_path[0..], "bob", "two");
}

test "managed read view deinit is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-read-view-deinit.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");

    var view = try db.readView();
    try std.testing.expectEqual(@as(usize, 1), db.reclaim.activeReaderCount());

    view.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());

    view.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
}

test "managed read view stays usable after bucket lookup errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-read-view-errors.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("plain", "value");

    var view = try db.readView();
    defer view.deinit();

    try std.testing.expectEqual(@as(usize, 1), db.reclaim.activeReaderCount());
    try std.testing.expectError(error.BucketNotFound, view.cursorInBucket("users"));
    try std.testing.expectError(error.KeyNotBucket, view.cursorInBucket("plain"));
    try std.testing.expectEqual(@as(usize, 1), db.reclaim.activeReaderCount());

    const root_value = (try view.get(std.testing.allocator, "plain")).?;
    defer std.testing.allocator.free(root_value);
    try std.testing.expectEqualSlices(u8, "value", root_value);
}

test "managed bucket view keeps a stable bucket snapshot and supports nested scopes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-bucket-view-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    const orgs_path = [_][]const u8{"orgs"};
    const engineering_path = [_][]const u8{ "orgs", "engineering" };

    try db.createBucket("orgs");
    try db.createBucketInBucketPath(orgs_path[0..], "engineering");
    try db.putInBucketPath(engineering_path[0..], "alice", "one");
    try db.createBucketInBucketPath(engineering_path[0..], "birds");
    try db.putInBucketPath(&[_][]const u8{ "orgs", "engineering", "birds" }, "crow", "three");

    var view = try db.readViewInBucketPath(engineering_path[0..]);
    defer view.deinit();

    try db.putInBucketPath(engineering_path[0..], "alice", "updated");
    try db.putInBucketPath(engineering_path[0..], "bob", "two");
    try db.putInBucketPath(&[_][]const u8{ "orgs", "engineering", "birds" }, "crow", "updated");

    const alice = (try view.get(std.testing.allocator, "alice")).?;
    defer std.testing.allocator.free(alice);
    try std.testing.expectEqualSlices(u8, "one", alice);

    try std.testing.expect(try view.bucketExists(std.testing.allocator, "birds"));
    var scan = try view.scanAlloc(std.testing.allocator, .{
        .start_inclusive = "a",
        .end_exclusive = "z",
    });
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.items.len);
    try expectCursorRecord(scan.items[0], "alice", "one");
    try std.testing.expectEqualStrings("birds", scan.items[1].key);
    try std.testing.expect(namespace.isBucketFlags(scan.items[1].flags));

    var birds = try view.bucketViewInBucket("birds");
    const crow = (try birds.get(std.testing.allocator, "crow")).?;
    defer std.testing.allocator.free(crow);
    try std.testing.expectEqualSlices(u8, "three", crow);

    try expectBucketPathValue(db, engineering_path[0..], "alice", "updated");
    try expectBucketPathValue(db, engineering_path[0..], "bob", "two");
}

test "readViewInBucketPath closes failed snapshots on lookup errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "managed-bucket-view-errors.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.put("plain", "value");

    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
    try std.testing.expectError(error.BucketNotFound, db.readViewInBucket("missing"));
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());

    try std.testing.expectError(error.KeyNotBucket, db.readViewInBucket("plain"));
    try std.testing.expectEqual(@as(usize, 0), db.reclaim.activeReaderCount());
}

test "scanAlloc returns root records within inclusive start and exclusive end bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "scan-root-range.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    try db.put("beta", "two");
    try db.put("delta", "four");
    try db.put("gamma", "three");

    try expectScanRecords(
        try db.scanAlloc(std.testing.allocator, .{
            .start_inclusive = "beta",
            .end_exclusive = "gamma",
        }),
        &.{
            .{ .key = "beta", .value = "two" },
            .{ .key = "delta", .value = "four" },
        },
    );

    try expectScanRecords(
        try db.scanAlloc(std.testing.allocator, .{
            .start_inclusive = "carrot",
            .end_exclusive = "delta",
        }),
        &.{},
    );
}

test "scanAlloc treats equal or reversed bounds as an empty range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "scan-root-empty-range.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.put("alpha", "one");
    try db.put("beta", "two");

    try expectScanRecords(
        try db.scanAlloc(std.testing.allocator, .{
            .start_inclusive = "beta",
            .end_exclusive = "beta",
        }),
        &.{},
    );

    try expectScanRecords(
        try db.scanAlloc(std.testing.allocator, .{
            .start_inclusive = "gamma",
            .end_exclusive = "beta",
        }),
        &.{},
    );
}

test "scanInBucketAlloc reuses the same bounds semantics inside bucket roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "scan-bucket-range.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alpha", "one");
    try db.putInBucket("users", "beta", "two");
    try db.putInBucket("users", "gamma", "three");

    try expectScanRecords(
        try db.scanInBucketAlloc(std.testing.allocator, "users", .{
            .start_inclusive = "beta",
            .end_exclusive = "omega",
        }),
        &.{
            .{ .key = "beta", .value = "two" },
            .{ .key = "gamma", .value = "three" },
        },
    );
}

test "scanInBucketAlloc keeps read snapshots stable after later bucket writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "scan-bucket-snapshot.db");

    const db = try open(std.testing.allocator, std.testing.io, path);
    defer db.close();

    try db.createBucket("users");
    try db.putInBucket("users", "alice", "one");
    try db.putInBucket("users", "carol", "three");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    try db.putInBucket("users", "bob", "two");
    try db.putInBucket("users", "carol", "updated");

    try expectScanRecords(
        try read_tx.scanInBucketAlloc(std.testing.allocator, "users", .{
            .start_inclusive = "alice",
            .end_exclusive = "d",
        }),
        &.{
            .{ .key = "alice", .value = "one" },
            .{ .key = "carol", .value = "three" },
        },
    );

    try expectScanRecords(
        try db.scanInBucketAlloc(std.testing.allocator, "users", .{
            .start_inclusive = "alice",
            .end_exclusive = "d",
        }),
        &.{
            .{ .key = "alice", .value = "one" },
            .{ .key = "bob", .value = "two" },
            .{ .key = "carol", .value = "updated" },
        },
    );
}
