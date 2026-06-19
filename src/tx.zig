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
    CommitFaultInjected,
};

pub const ScanBounds = struct {
    start_inclusive: ?[]const u8 = null,
    end_exclusive: ?[]const u8 = null,
};

pub const ScanRecords = struct {
    items: []tree.CursorRecord,

    pub fn deinit(self: *ScanRecords, allocator: std.mem.Allocator) void {
        const owned_items = self.items;
        self.items = &.{};

        for (owned_items) |*record| record.deinit(allocator);
        if (owned_items.len > 0) allocator.free(owned_items);
    }
};

/// Borrowed bucket-scoped read helper.
///
/// This view reuses transaction-owned page readers and cursor ownership, so it
/// remains valid only while the originating ReadTx, WriteTx, or managed view is
/// still alive.
pub const BucketReadView = struct {
    read_view: TxReadView,

    /// Returns an owned copy of the value visible at this bucket scope.
    pub fn get(self: *const BucketReadView, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return self.read_view.get(allocator, key);
    }

    /// Returns an owned copy of the value stored in the direct child bucket
    /// `bucket` for `key`.
    pub fn getInBucket(self: *const BucketReadView, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        const bucket_path = [_][]const u8{bucket};
        return self.getInBucketPath(allocator, bucket_path[0..], key);
    }

    /// Returns an owned copy of the value stored inside the descendant bucket
    /// at `bucket_path` for `key`.
    pub fn getInBucketPath(
        self: *const BucketReadView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        return self.read_view.getInBucketPath(allocator, bucket_path, key);
    }

    /// Returns whether the direct child bucket `bucket` exists.
    pub fn bucketExists(self: *const BucketReadView, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketExistsInBucketPath(allocator, parent_bucket_path[0..], bucket);
    }

    /// Returns whether `bucket` exists inside the descendant parent bucket at
    /// `parent_bucket_path`.
    pub fn bucketExistsInBucketPath(
        self: *const BucketReadView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        return self.read_view.bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    /// Returns the direct child bucket names visible at this bucket scope.
    pub fn bucketNamesAlloc(self: *const BucketReadView, allocator: std.mem.Allocator) !namespace.BucketNames {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path[0..]);
    }

    /// Returns the direct child bucket names inside the descendant parent
    /// bucket at `parent_bucket_path`.
    pub fn bucketNamesInBucketPathAlloc(
        self: *const BucketReadView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        return self.read_view.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    /// Returns owned records whose keys fall within
    /// `[start_inclusive, end_exclusive)` at this bucket scope.
    pub fn scanAlloc(self: *const BucketReadView, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        return self.read_view.scanAlloc(allocator, bounds);
    }

    /// Opens a read-only cursor pinned to this bucket scope.
    pub fn cursor(self: *const BucketReadView) tree.Cursor {
        return self.read_view.cursor();
    }

    /// Opens a read-only cursor pinned to the direct child bucket `bucket`.
    pub fn cursorInBucket(self: *const BucketReadView, bucket: []const u8) !tree.Cursor {
        const bucket_path = [_][]const u8{bucket};
        return self.cursorInBucketPath(bucket_path[0..]);
    }

    /// Opens a read-only cursor pinned to the descendant bucket at
    /// `bucket_path`.
    pub fn cursorInBucketPath(self: *const BucketReadView, bucket_path: []const []const u8) !tree.Cursor {
        return self.read_view.cursorInBucketPath(bucket_path);
    }

    /// Returns owned records from the direct child bucket `bucket` whose keys
    /// fall within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketAlloc(self: *const BucketReadView, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        const bucket_path = [_][]const u8{bucket};
        return self.scanInBucketPathAlloc(allocator, bucket_path[0..], bounds);
    }

    /// Returns owned records from the descendant bucket at `bucket_path` whose
    /// keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketPathAlloc(
        self: *const BucketReadView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        return self.read_view.scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Returns a further bucket-scoped borrowed view rooted at the direct child
    /// bucket `bucket`.
    pub fn bucketViewInBucket(self: *const BucketReadView, bucket: []const u8) !BucketReadView {
        const bucket_path = [_][]const u8{bucket};
        return self.bucketViewInBucketPath(bucket_path[0..]);
    }

    /// Returns a further bucket-scoped borrowed view rooted at the descendant
    /// bucket `bucket_path`.
    pub fn bucketViewInBucketPath(self: *const BucketReadView, bucket_path: []const []const u8) !BucketReadView {
        return .{
            .read_view = try self.read_view.scopedToBucketPath(bucket_path),
        };
    }
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
        return self.readView().get(allocator, key);
    }

    /// Returns an owned copy of the value stored inside `bucket` for `key`.
    pub fn getInBucket(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        const bucket_path = [_][]const u8{bucket};
        return self.getInBucketPath(allocator, bucket_path[0..], key);
    }

    /// Returns an owned copy of the value stored inside the bucket at
    /// `bucket_path` for `key`.
    pub fn getInBucketPath(self: *const ReadTx, allocator: std.mem.Allocator, bucket_path: []const []const u8, key: []const u8) !?[]u8 {
        std.debug.assert(self.db != null);
        return self.readView().getInBucketPath(allocator, bucket_path, key);
    }

    /// Returns whether `bucket` exists in this snapshot and is a bucket namespace entry.
    pub fn bucketExists(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketExistsInBucketPath(allocator, parent_bucket_path[0..], bucket);
    }

    /// Returns whether `bucket` exists inside the bucket at
    /// `parent_bucket_path` and is a bucket namespace entry.
    pub fn bucketExistsInBucketPath(
        self: *const ReadTx,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        std.debug.assert(self.db != null);
        return self.readView().bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    /// Returns the top-level bucket names visible in this snapshot in key order.
    pub fn bucketNamesAlloc(self: *const ReadTx, allocator: std.mem.Allocator) !namespace.BucketNames {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path[0..]);
    }

    /// Returns the direct child bucket names visible inside the bucket at
    /// `parent_bucket_path` in key order.
    pub fn bucketNamesInBucketPathAlloc(
        self: *const ReadTx,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        std.debug.assert(self.db != null);
        return self.readView().bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    /// Returns owned records whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanAlloc(self: *const ReadTx, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        std.debug.assert(self.db != null);
        return self.readView().scanAlloc(allocator, bounds);
    }

    /// Opens a read-only cursor pinned to this transaction's snapshot.
    pub fn cursor(self: *const ReadTx) tree.Cursor {
        std.debug.assert(self.db != null);
        return self.readView().cursor();
    }

    /// Opens a read-only cursor pinned to the snapshot root of `bucket`.
    pub fn cursorInBucket(self: *const ReadTx, bucket: []const u8) !tree.Cursor {
        const bucket_path = [_][]const u8{bucket};
        return self.cursorInBucketPath(bucket_path[0..]);
    }

    /// Opens a read-only cursor pinned to the snapshot root of the bucket at
    /// `bucket_path`.
    pub fn cursorInBucketPath(self: *const ReadTx, bucket_path: []const []const u8) !tree.Cursor {
        std.debug.assert(self.db != null);
        return self.readView().cursorInBucketPath(bucket_path);
    }

    /// Returns owned records from `bucket` whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketAlloc(self: *const ReadTx, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        const bucket_path = [_][]const u8{bucket};
        return self.scanInBucketPathAlloc(allocator, bucket_path[0..], bounds);
    }

    /// Returns owned records from the bucket at `bucket_path` whose keys fall
    /// within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketPathAlloc(
        self: *const ReadTx,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        std.debug.assert(self.db != null);
        return self.readView().scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Returns a borrowed bucket-scoped view pinned to this snapshot.
    pub fn bucketViewInBucket(self: *const ReadTx, bucket: []const u8) !BucketReadView {
        const bucket_path = [_][]const u8{bucket};
        return self.bucketViewInBucketPath(bucket_path[0..]);
    }

    /// Returns a borrowed bucket-scoped view pinned to the descendant bucket
    /// at `bucket_path`.
    pub fn bucketViewInBucketPath(self: *const ReadTx, bucket_path: []const []const u8) !BucketReadView {
        std.debug.assert(self.db != null);
        return .{
            .read_view = try self.readView().scopedToBucketPath(bucket_path),
        };
    }

    fn readView(self: *const ReadTx) TxReadView {
        std.debug.assert(self.db != null);
        return .{
            .page_reader = self.snapshot_source.pageReader(),
            .temp_allocator = self.db.?.allocator,
            .cursor_owner = cursorOwnerForReadTx(self),
            .root_page_id = self.snapshot.root_page_id,
        };
    }
};

pub const ManagedBucketView = struct {
    allocator: std.mem.Allocator,
    read_tx: ?*ReadTx,
    bucket_view: BucketReadView,

    /// Opens a stable bucket-scoped snapshot that owns the underlying read
    /// transaction.
    pub fn initInBucket(db: *db_mod.DB, bucket: []const u8) !ManagedBucketView {
        const bucket_path = [_][]const u8{bucket};
        return initInBucketPath(db, bucket_path[0..]);
    }

    /// Opens a stable bucket-scoped snapshot rooted at the descendant bucket
    /// `bucket_path`.
    pub fn initInBucketPath(db: *db_mod.DB, bucket_path: []const []const u8) !ManagedBucketView {
        const owned_read_tx = try initOwnedReadTx(db);
        errdefer destroyOwnedReadTx(db.allocator, owned_read_tx);

        return .{
            .allocator = db.allocator,
            .read_tx = owned_read_tx,
            .bucket_view = try owned_read_tx.bucketViewInBucketPath(bucket_path),
        };
    }

    pub fn get(self: *const ManagedBucketView, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.get(allocator, key);
    }

    pub fn getInBucket(self: *const ManagedBucketView, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.getInBucket(allocator, bucket, key);
    }

    pub fn getInBucketPath(
        self: *const ManagedBucketView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.getInBucketPath(allocator, bucket_path, key);
    }

    pub fn bucketExists(self: *const ManagedBucketView, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketExists(allocator, bucket);
    }

    pub fn bucketExistsInBucketPath(
        self: *const ManagedBucketView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    pub fn bucketNamesAlloc(self: *const ManagedBucketView, allocator: std.mem.Allocator) !namespace.BucketNames {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketNamesAlloc(allocator);
    }

    pub fn bucketNamesInBucketPathAlloc(
        self: *const ManagedBucketView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    pub fn scanAlloc(self: *const ManagedBucketView, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.scanAlloc(allocator, bounds);
    }

    pub fn cursor(self: *const ManagedBucketView) tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.cursor();
    }

    pub fn cursorInBucket(self: *const ManagedBucketView, bucket: []const u8) !tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.cursorInBucket(bucket);
    }

    pub fn cursorInBucketPath(self: *const ManagedBucketView, bucket_path: []const []const u8) !tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.cursorInBucketPath(bucket_path);
    }

    pub fn scanInBucketAlloc(self: *const ManagedBucketView, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.scanInBucketAlloc(allocator, bucket, bounds);
    }

    pub fn scanInBucketPathAlloc(
        self: *const ManagedBucketView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Returns a borrowed descendant bucket-scoped view rooted at the direct
    /// child bucket `bucket`.
    pub fn bucketViewInBucket(self: *const ManagedBucketView, bucket: []const u8) !BucketReadView {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketViewInBucket(bucket);
    }

    /// Returns a borrowed descendant bucket-scoped view rooted at
    /// `bucket_path`.
    pub fn bucketViewInBucketPath(self: *const ManagedBucketView, bucket_path: []const []const u8) !BucketReadView {
        std.debug.assert(self.read_tx != null);
        return self.bucket_view.bucketViewInBucketPath(bucket_path);
    }

    /// Releases the owned read transaction snapshot.
    pub fn deinit(self: *ManagedBucketView) void {
        const owned_read_tx = self.read_tx orelse return;
        self.read_tx = null;
        destroyOwnedReadTx(self.allocator, owned_read_tx);
    }
};

/// Write-transaction bucket-scoped read helper.
///
/// This view keeps a back-reference to the owning WriteTx so every operation
/// still enforces the usual staged-read lifetime and closed-transaction checks.
pub const WriteBucketView = struct {
    write_tx: *WriteTx,
    bucket_path: []const []const u8,

    pub fn get(self: *const WriteBucketView, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return (try self.currentBucketReadView()).get(allocator, key);
    }

    pub fn getInBucket(self: *const WriteBucketView, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        return (try self.currentBucketReadView()).getInBucket(allocator, bucket, key);
    }

    pub fn getInBucketPath(
        self: *const WriteBucketView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        return (try self.currentBucketReadView()).getInBucketPath(allocator, bucket_path, key);
    }

    pub fn bucketExists(self: *const WriteBucketView, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        return (try self.currentBucketReadView()).bucketExists(allocator, bucket);
    }

    pub fn bucketExistsInBucketPath(
        self: *const WriteBucketView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        return (try self.currentBucketReadView()).bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    pub fn bucketNamesAlloc(self: *const WriteBucketView, allocator: std.mem.Allocator) !namespace.BucketNames {
        return (try self.currentBucketReadView()).bucketNamesAlloc(allocator);
    }

    pub fn bucketNamesInBucketPathAlloc(
        self: *const WriteBucketView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        return (try self.currentBucketReadView()).bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    pub fn scanAlloc(self: *const WriteBucketView, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        return (try self.currentBucketReadView()).scanAlloc(allocator, bounds);
    }

    pub fn cursor(self: *const WriteBucketView) !tree.Cursor {
        return (try self.currentBucketReadView()).cursor();
    }

    pub fn cursorInBucket(self: *const WriteBucketView, bucket: []const u8) !tree.Cursor {
        return (try self.currentBucketReadView()).cursorInBucket(bucket);
    }

    pub fn cursorInBucketPath(self: *const WriteBucketView, bucket_path: []const []const u8) !tree.Cursor {
        return (try self.currentBucketReadView()).cursorInBucketPath(bucket_path);
    }

    pub fn scanInBucketAlloc(self: *const WriteBucketView, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        return (try self.currentBucketReadView()).scanInBucketAlloc(allocator, bucket, bounds);
    }

    pub fn scanInBucketPathAlloc(
        self: *const WriteBucketView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        return (try self.currentBucketReadView()).scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    pub fn bucketViewInBucket(self: *const WriteBucketView, bucket: []const u8) !WriteBucketView {
        try self.write_tx.ensureActive();
        _ = try (try self.currentBucketReadView()).bucketViewInBucket(bucket);
        return .{
            .write_tx = self.write_tx,
            .bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, &[_][]const u8{bucket}),
        };
    }

    pub fn bucketViewInBucketPath(self: *const WriteBucketView, bucket_path: []const []const u8) !WriteBucketView {
        try self.write_tx.ensureActive();
        _ = try (try self.currentBucketReadView()).bucketViewInBucketPath(bucket_path);
        return .{
            .write_tx = self.write_tx,
            .bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, bucket_path),
        };
    }

    pub fn put(self: *const WriteBucketView, key: []const u8, value: []const u8) !void {
        try self.write_tx.ensureActive();
        return self.write_tx.putInBucketPath(self.bucket_path, key, value);
    }

    pub fn delete(self: *const WriteBucketView, key: []const u8) !void {
        try self.write_tx.ensureActive();
        return self.write_tx.deleteInBucketPath(self.bucket_path, key);
    }

    pub fn createBucket(self: *const WriteBucketView, bucket: []const u8) !void {
        try self.write_tx.ensureActive();
        return self.write_tx.createBucketInBucketPath(self.bucket_path, bucket);
    }

    pub fn createBucketInBucket(self: *const WriteBucketView, parent_bucket: []const u8, bucket: []const u8) !void {
        return self.createBucketInBucketPath(&[_][]const u8{parent_bucket}, bucket);
    }

    pub fn createBucketInBucketPath(
        self: *const WriteBucketView,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !void {
        try self.write_tx.ensureActive();
        const scoped_parent_bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, parent_bucket_path);
        return self.write_tx.createBucketInBucketPath(scoped_parent_bucket_path, bucket);
    }

    pub fn deleteBucket(self: *const WriteBucketView, bucket: []const u8) !void {
        try self.write_tx.ensureActive();
        return self.write_tx.deleteBucketInBucketPath(self.bucket_path, bucket);
    }

    pub fn deleteBucketInBucket(self: *const WriteBucketView, parent_bucket: []const u8, bucket: []const u8) !void {
        return self.deleteBucketInBucketPath(&[_][]const u8{parent_bucket}, bucket);
    }

    pub fn deleteBucketInBucketPath(
        self: *const WriteBucketView,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !void {
        try self.write_tx.ensureActive();
        const scoped_parent_bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, parent_bucket_path);
        return self.write_tx.deleteBucketInBucketPath(scoped_parent_bucket_path, bucket);
    }

    pub fn putInBucket(self: *const WriteBucketView, bucket: []const u8, key: []const u8, value: []const u8) !void {
        return self.putInBucketPath(&[_][]const u8{bucket}, key, value);
    }

    pub fn putInBucketPath(
        self: *const WriteBucketView,
        bucket_path: []const []const u8,
        key: []const u8,
        value: []const u8,
    ) !void {
        try self.write_tx.ensureActive();
        const scoped_bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, bucket_path);
        return self.write_tx.putInBucketPath(scoped_bucket_path, key, value);
    }

    pub fn deleteInBucket(self: *const WriteBucketView, bucket: []const u8, key: []const u8) !void {
        return self.deleteInBucketPath(&[_][]const u8{bucket}, key);
    }

    pub fn deleteInBucketPath(self: *const WriteBucketView, bucket_path: []const []const u8, key: []const u8) !void {
        try self.write_tx.ensureActive();
        const scoped_bucket_path = try self.write_tx.extendScopedBucketPath(self.bucket_path, bucket_path);
        return self.write_tx.deleteInBucketPath(scoped_bucket_path, key);
    }

    fn currentBucketReadView(self: *const WriteBucketView) !BucketReadView {
        try self.write_tx.ensureActive();
        return .{
            .read_view = try self.write_tx.readView().scopedToBucketPath(self.bucket_path),
        };
    }
};

pub const ManagedReadView = struct {
    allocator: std.mem.Allocator,
    read_tx: ?*ReadTx,

    /// Opens a stable read snapshot that owns the underlying transaction.
    pub fn init(db: *db_mod.DB) !ManagedReadView {
        return .{
            .allocator = db.allocator,
            .read_tx = try initOwnedReadTx(db),
        };
    }

    /// Returns an owned copy of the value visible to this stable snapshot.
    pub fn get(self: *const ManagedReadView, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.get(allocator, key);
    }

    /// Returns an owned copy of the value stored inside `bucket` for `key`.
    pub fn getInBucket(self: *const ManagedReadView, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.getInBucket(allocator, bucket, key);
    }

    /// Returns an owned copy of the value stored inside the bucket at
    /// `bucket_path` for `key`.
    pub fn getInBucketPath(
        self: *const ManagedReadView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.getInBucketPath(allocator, bucket_path, key);
    }

    /// Returns whether `bucket` exists in this stable snapshot.
    pub fn bucketExists(self: *const ManagedReadView, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketExists(allocator, bucket);
    }

    /// Returns whether `bucket` exists inside the bucket at
    /// `parent_bucket_path` in this stable snapshot.
    pub fn bucketExistsInBucketPath(
        self: *const ManagedReadView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    /// Returns the top-level bucket names visible in this stable snapshot.
    pub fn bucketNamesAlloc(self: *const ManagedReadView, allocator: std.mem.Allocator) !namespace.BucketNames {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketNamesAlloc(allocator);
    }

    /// Returns the direct child bucket names visible inside the bucket at
    /// `parent_bucket_path`.
    pub fn bucketNamesInBucketPathAlloc(
        self: *const ManagedReadView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    /// Returns owned records whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanAlloc(self: *const ManagedReadView, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.scanAlloc(allocator, bounds);
    }

    /// Opens a read-only cursor pinned to this stable snapshot.
    pub fn cursor(self: *const ManagedReadView) tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.cursor();
    }

    /// Opens a read-only cursor pinned to the snapshot root of `bucket`.
    pub fn cursorInBucket(self: *const ManagedReadView, bucket: []const u8) !tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.cursorInBucket(bucket);
    }

    /// Opens a read-only cursor pinned to the snapshot root of the bucket at
    /// `bucket_path`.
    pub fn cursorInBucketPath(self: *const ManagedReadView, bucket_path: []const []const u8) !tree.Cursor {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.cursorInBucketPath(bucket_path);
    }

    /// Returns owned records from `bucket` whose keys fall within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketAlloc(self: *const ManagedReadView, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.scanInBucketAlloc(allocator, bucket, bounds);
    }

    /// Returns owned records from the bucket at `bucket_path` whose keys fall
    /// within `[start_inclusive, end_exclusive)`.
    pub fn scanInBucketPathAlloc(
        self: *const ManagedReadView,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Returns a borrowed bucket-scoped view rooted at the direct child bucket
    /// `bucket`.
    pub fn bucketViewInBucket(self: *const ManagedReadView, bucket: []const u8) !BucketReadView {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketViewInBucket(bucket);
    }

    /// Returns a borrowed bucket-scoped view rooted at the descendant bucket
    /// `bucket_path`.
    pub fn bucketViewInBucketPath(self: *const ManagedReadView, bucket_path: []const []const u8) !BucketReadView {
        std.debug.assert(self.read_tx != null);
        return self.read_tx.?.bucketViewInBucketPath(bucket_path);
    }

    /// Releases the owned read transaction snapshot.
    pub fn deinit(self: *ManagedReadView) void {
        const owned_read_tx = self.read_tx orelse return;
        self.read_tx = null;
        destroyOwnedReadTx(self.allocator, owned_read_tx);
    }
};

pub const ManagedCursor = struct {
    allocator: std.mem.Allocator,
    read_tx: ?*ReadTx,
    cursor: tree.Cursor,

    /// Opens a cursor that owns the underlying read transaction.
    ///
    /// The cursor and its snapshot remain valid until `deinit`, so callers can
    /// traverse the latest committed state without manually managing `ReadTx`.
    pub fn init(db: *db_mod.DB) !ManagedCursor {
        const owned_read_tx = try initOwnedReadTx(db);
        errdefer destroyOwnedReadTx(db.allocator, owned_read_tx);

        var managed = ManagedCursor{
            .allocator = db.allocator,
            .read_tx = owned_read_tx,
            .cursor = undefined,
        };
        // The wrapped tree cursor keeps pointers into the owning ReadTx, so the
        // transaction lives on the heap to preserve a stable address even if
        // the ManagedCursor itself is moved by value.
        managed.cursor = owned_read_tx.cursor();
        return managed;
    }

    /// Opens a bucket-scoped cursor that owns the underlying read transaction.
    pub fn initInBucket(db: *db_mod.DB, bucket: []const u8) !ManagedCursor {
        const bucket_path = [_][]const u8{bucket};
        return initInBucketPath(db, bucket_path[0..]);
    }

    /// Opens a bucket-scoped cursor that owns the underlying read transaction.
    pub fn initInBucketPath(db: *db_mod.DB, bucket_path: []const []const u8) !ManagedCursor {
        const owned_read_tx = try initOwnedReadTx(db);
        errdefer destroyOwnedReadTx(db.allocator, owned_read_tx);

        var managed = ManagedCursor{
            .allocator = db.allocator,
            .read_tx = owned_read_tx,
            .cursor = undefined,
        };
        managed.cursor = try owned_read_tx.cursorInBucketPath(bucket_path);
        return managed;
    }

    pub fn first(self: *ManagedCursor, allocator: std.mem.Allocator) tree.CursorError!?tree.CursorRecord {
        return self.cursor.first(allocator);
    }

    pub fn last(self: *ManagedCursor, allocator: std.mem.Allocator) tree.CursorError!?tree.CursorRecord {
        return self.cursor.last(allocator);
    }

    pub fn seek(self: *ManagedCursor, allocator: std.mem.Allocator, key: []const u8) tree.CursorError!?tree.CursorRecord {
        return self.cursor.seek(allocator, key);
    }

    pub fn next(self: *ManagedCursor, allocator: std.mem.Allocator) tree.CursorError!?tree.CursorRecord {
        return self.cursor.next(allocator);
    }

    pub fn prev(self: *ManagedCursor, allocator: std.mem.Allocator) tree.CursorError!?tree.CursorRecord {
        return self.cursor.prev(allocator);
    }

    /// Releases both the cursor handle and the owned read transaction snapshot.
    pub fn deinit(self: *ManagedCursor) void {
        const owned_read_tx = self.read_tx orelse return;
        self.read_tx = null;
        self.cursor.deinit();
        owned_read_tx.deinit();
        self.allocator.destroy(owned_read_tx);
    }
};

fn initOwnedReadTx(db: *db_mod.DB) !*ReadTx {
    const owned_read_tx = try db.allocator.create(ReadTx);
    errdefer db.allocator.destroy(owned_read_tx);
    // Managed wrappers can be moved by value, so the shared ReadTx lives on
    // the heap to keep cursor owner pointers stable for the snapshot lifetime.
    owned_read_tx.* = try db.beginRead();
    return owned_read_tx;
}

fn destroyOwnedReadTx(allocator: std.mem.Allocator, owned_read_tx: *ReadTx) void {
    owned_read_tx.deinit();
    allocator.destroy(owned_read_tx);
}

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

    /// Returns an owned copy of the latest value visible inside this write
    /// transaction, including staged uncommitted changes.
    pub fn get(self: *const WriteTx, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        try self.ensureActive();
        return self.readView().get(allocator, key);
    }

    /// Returns an owned copy of the value stored inside `bucket` for `key`,
    /// including staged bucket mutations in this transaction.
    pub fn getInBucket(self: *const WriteTx, allocator: std.mem.Allocator, bucket: []const u8, key: []const u8) !?[]u8 {
        const bucket_path = [_][]const u8{bucket};
        return self.getInBucketPath(allocator, bucket_path[0..], key);
    }

    /// Returns an owned copy of the value stored inside the bucket at
    /// `bucket_path`, including staged bucket mutations in this transaction.
    pub fn getInBucketPath(
        self: *const WriteTx,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        key: []const u8,
    ) !?[]u8 {
        try self.ensureActive();
        return self.readView().getInBucketPath(allocator, bucket_path, key);
    }

    /// Returns whether `bucket` exists in the current staged root snapshot.
    pub fn bucketExists(self: *const WriteTx, allocator: std.mem.Allocator, bucket: []const u8) !bool {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketExistsInBucketPath(allocator, parent_bucket_path[0..], bucket);
    }

    /// Returns whether `bucket` exists inside the bucket at
    /// `parent_bucket_path`, including staged namespace mutations.
    pub fn bucketExistsInBucketPath(
        self: *const WriteTx,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        try self.ensureActive();
        return self.readView().bucketExistsInBucketPath(allocator, parent_bucket_path, bucket);
    }

    /// Returns the top-level bucket names visible in the current staged state.
    pub fn bucketNamesAlloc(self: *const WriteTx, allocator: std.mem.Allocator) !namespace.BucketNames {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.bucketNamesInBucketPathAlloc(allocator, parent_bucket_path[0..]);
    }

    /// Returns the direct child bucket names visible inside the bucket at
    /// `parent_bucket_path`, including staged namespace mutations.
    pub fn bucketNamesInBucketPathAlloc(
        self: *const WriteTx,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
    ) !namespace.BucketNames {
        try self.ensureActive();
        return self.readView().bucketNamesInBucketPathAlloc(allocator, parent_bucket_path);
    }

    /// Returns owned records whose keys fall within `[start_inclusive, end_exclusive)`
    /// in the current staged root snapshot.
    pub fn scanAlloc(self: *const WriteTx, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        try self.ensureActive();
        return self.readView().scanAlloc(allocator, bounds);
    }

    /// Opens a read-only cursor pinned to the current staged root snapshot.
    pub fn cursor(self: *const WriteTx) !tree.Cursor {
        try self.ensureActive();
        return self.readView().cursor();
    }

    /// Opens a read-only cursor pinned to the current staged snapshot root of
    /// `bucket`.
    pub fn cursorInBucket(self: *const WriteTx, bucket: []const u8) !tree.Cursor {
        const bucket_path = [_][]const u8{bucket};
        return self.cursorInBucketPath(bucket_path[0..]);
    }

    /// Opens a read-only cursor pinned to the current staged snapshot root of
    /// the bucket at `bucket_path`.
    pub fn cursorInBucketPath(self: *const WriteTx, bucket_path: []const []const u8) !tree.Cursor {
        try self.ensureActive();
        return self.readView().cursorInBucketPath(bucket_path);
    }

    /// Returns owned records from `bucket` whose keys fall within
    /// `[start_inclusive, end_exclusive)` in the current staged snapshot.
    pub fn scanInBucketAlloc(self: *const WriteTx, allocator: std.mem.Allocator, bucket: []const u8, bounds: ScanBounds) !ScanRecords {
        const bucket_path = [_][]const u8{bucket};
        return self.scanInBucketPathAlloc(allocator, bucket_path[0..], bounds);
    }

    /// Returns owned records from the bucket at `bucket_path` whose keys fall
    /// within `[start_inclusive, end_exclusive)` in the current staged snapshot.
    pub fn scanInBucketPathAlloc(
        self: *const WriteTx,
        allocator: std.mem.Allocator,
        bucket_path: []const []const u8,
        bounds: ScanBounds,
    ) !ScanRecords {
        try self.ensureActive();
        return self.readView().scanInBucketPathAlloc(allocator, bucket_path, bounds);
    }

    /// Returns a borrowed bucket-scoped view rooted at the direct child bucket
    /// `bucket`, including staged writes.
    pub fn bucketViewInBucket(self: *WriteTx, bucket: []const u8) !WriteBucketView {
        const bucket_path = [_][]const u8{bucket};
        return self.bucketViewInBucketPath(bucket_path[0..]);
    }

    /// Returns a borrowed bucket-scoped view rooted at the descendant bucket
    /// `bucket_path`, including staged writes.
    pub fn bucketViewInBucketPath(self: *WriteTx, bucket_path: []const []const u8) !WriteBucketView {
        try self.ensureActive();
        _ = try self.readView().scopedToBucketPath(bucket_path);
        return .{
            .write_tx = self,
            .bucket_path = try self.cloneScopedBucketPath(bucket_path),
        };
    }

    pub fn put(self: *WriteTx, key: []const u8, value: []const u8) !void {
        try self.ensureActive();
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
        try self.ensureActive();
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
        const parent_bucket_path: [0][]const u8 = .{};
        return self.createBucketInBucketPath(parent_bucket_path[0..], bucket);
    }

    pub fn createBucketInBucketPath(self: *WriteTx, parent_bucket_path: []const []const u8, bucket: []const u8) !void {
        try self.ensureActive();
        const view = &self.view.?;
        const parent_root_page_id = try resolveBucketPathCurrentRootPageId(view, self.arena.allocator(), parent_bucket_path);
        const existing = try tree.lookupEntryPageReader(view.pageReader(), self.arena.allocator(), parent_root_page_id, bucket);
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
        const write_result = try writeBucketEntry(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            parent_root_page_id,
            bucket,
            bucket_root_page_id,
        );
        try self.applyWriteResultAtBucketPath(parent_bucket_path, write_result);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn deleteBucket(self: *WriteTx, bucket: []const u8) !void {
        const parent_bucket_path: [0][]const u8 = .{};
        return self.deleteBucketInBucketPath(parent_bucket_path[0..], bucket);
    }

    pub fn deleteBucketInBucketPath(self: *WriteTx, parent_bucket_path: []const []const u8, bucket: []const u8) !void {
        try self.ensureActive();
        const view = &self.view.?;
        const parent_root_page_id = try resolveBucketPathCurrentRootPageId(view, self.arena.allocator(), parent_bucket_path);
        const bucket_root_page_id = try bucketRootPageIdAtTreeRoot(view.pageReader(), self.arena.allocator(), parent_root_page_id, bucket);

        const delete_bucket_result = try tree.writeDelete(
            view.pageReader(),
            self.arena.allocator(),
            self.db.allocator,
            self.db.page_size,
            &self.working_page_allocator,
            parent_root_page_id,
            bucket,
        );
        switch (delete_bucket_result) {
            .unchanged => return error.BucketNotFound,
            .changed => |write_result| try self.applyWriteResultAtBucketPath(parent_bucket_path, write_result),
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
        const bucket_path = [_][]const u8{bucket};
        return self.putInBucketPath(bucket_path[0..], key, value);
    }

    pub fn putInBucketPath(self: *WriteTx, bucket_path: []const []const u8, key: []const u8, value: []const u8) !void {
        try self.ensureActive();
        const view = &self.view.?;
        const bucket_root_page_id = try resolveBucketPathCurrentRootPageId(view, self.arena.allocator(), bucket_path);
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
        try self.applyWriteResultAtBucketPath(bucket_path, bucket_write);
        self.has_pending_write = true;
        self.state = .open_dirty;
    }

    pub fn deleteInBucket(self: *WriteTx, bucket: []const u8, key: []const u8) !void {
        const bucket_path = [_][]const u8{bucket};
        return self.deleteInBucketPath(bucket_path[0..], key);
    }

    pub fn deleteInBucketPath(self: *WriteTx, bucket_path: []const []const u8, key: []const u8) !void {
        try self.ensureActive();
        const view = &self.view.?;
        const bucket_root_page_id = try resolveBucketPathCurrentRootPageId(view, self.arena.allocator(), bucket_path);
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
                try self.applyWriteResultAtBucketPath(bucket_path, write_result);
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
        return self.commitImpl(null);
    }

    pub fn commitWithFault(self: *WriteTx, fault_hook: db_mod.CommitFaultHook) !void {
        return self.commitImpl(fault_hook);
    }

    fn commitImpl(self: *WriteTx, fault_hook: ?db_mod.CommitFaultHook) !void {
        try self.ensureActive();
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

        // Fault injection step 1: before staged data page writes
        if (fault_hook) |hook| {
            if (hook.shouldFail(1)) return WriteTxError.CommitFaultInjected;
        }
        for (staged_pages) |pending_page| {
            try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, pending_page.page_id, pending_page.bytes);
        }

        // Fault injection step 2: before allocator state page write
        if (fault_hook) |hook| {
            if (hook.shouldFail(2)) return WriteTxError.CommitFaultInjected;
        }
        try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, allocator_state.page_id, allocator_state.bytes);

        // Fault injection step 3: before first sync (data + allocator durable boundary)
        if (fault_hook) |hook| {
            if (hook.shouldFail(3)) return WriteTxError.CommitFaultInjected;
        }
        try storage.sync(self.db.file, self.db.io);

        const next_meta_slot = inactiveMetaSlot(self.db.meta_slot);

        // Fault injection step 4: before meta page write
        if (fault_hook) |hook| {
            if (hook.shouldFail(4)) return WriteTxError.CommitFaultInjected;
        }
        try storage.writePageObject(&self.db.file, self.db.io, self.db.page_size, metaSlotPageId(next_meta_slot), next_meta_page);

        // Fault injection step 5: before final sync (commit durable boundary)
        if (fault_hook) |hook| {
            if (hook.shouldFail(5)) return WriteTxError.CommitFaultInjected;
        }
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

    fn ensureActive(self: *const WriteTx) WriteTxError!void {
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

    fn applyWriteResultAtBucketPath(self: *WriteTx, bucket_path: []const []const u8, write_result: tree.WriteResult) !void {
        const view = &self.view.?;
        if (bucket_path.len == 0) {
            try view.applyRootWriteResult(self.db.allocator, write_result);
            return;
        }

        try view.applyDetachedWriteResult(self.db.allocator, write_result);
        try self.propagateBucketRootUpdate(bucket_path, write_result.root_page_id);
    }

    fn propagateBucketRootUpdate(self: *WriteTx, bucket_path: []const []const u8, updated_bucket_root_page_id: u64) !void {
        const view = &self.view.?;
        var current_child_root_page_id = updated_bucket_root_page_id;
        var depth = bucket_path.len;
        // Rewrite each ancestor bucket entry from the touched subtree back to
        // the root so the whole path switches snapshots in one commit.
        while (depth > 0) : (depth -= 1) {
            const parent_bucket_path = bucket_path[0 .. depth - 1];
            const bucket = bucket_path[depth - 1];
            const parent_root_page_id = try resolveBucketPathCurrentRootPageId(
                view,
                self.arena.allocator(),
                parent_bucket_path,
            );
            const write_result = try writeBucketEntry(
                view.pageReader(),
                self.arena.allocator(),
                self.db.allocator,
                self.db.page_size,
                &self.working_page_allocator,
                parent_root_page_id,
                bucket,
                current_child_root_page_id,
            );
            if (depth == 1) {
                try view.applyRootWriteResult(self.db.allocator, write_result);
            } else {
                try view.applyDetachedWriteResult(self.db.allocator, write_result);
            }
            current_child_root_page_id = write_result.root_page_id;
        }
    }

    fn readView(self: *const WriteTx) TxReadView {
        return .{
            .page_reader = self.view.?.pageReader(),
            .temp_allocator = self.db.allocator,
            .cursor_owner = cursorOwnerForWriteTx(self),
            .root_page_id = self.view.?.current_root_page_id,
        };
    }

    fn cloneScopedBucketPath(self: *WriteTx, bucket_path: []const []const u8) ![]const []const u8 {
        return self.extendScopedBucketPath(&.{}, bucket_path);
    }

    fn extendScopedBucketPath(self: *WriteTx, prefix: []const []const u8, suffix: []const []const u8) ![]const []const u8 {
        const combined = try self.arena.allocator().alloc([]const u8, prefix.len + suffix.len);
        @memcpy(combined[0..prefix.len], prefix);
        // New relative path segments may be borrowed from caller-owned buffers,
        // so copy their bytes into the transaction arena before storing them.
        for (suffix, 0..) |segment, index| {
            combined[prefix.len + index] = try self.arena.allocator().dupe(u8, segment);
        }
        return combined;
    }
};

const TxReadView = struct {
    page_reader: tree.PageReader,
    temp_allocator: std.mem.Allocator,
    cursor_owner: tree.CursorOwner,
    root_page_id: u64,

    /// Share the read-side transaction logic without coupling it to write-side
    /// commit state or DB lifecycle ownership.
    fn get(self: TxReadView, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        const entry = try tree.lookupEntryPageReader(self.page_reader, allocator, self.root_page_id, key);
        return rootEntryValueOrError(allocator, entry);
    }

    fn getInBucketPath(self: TxReadView, allocator: std.mem.Allocator, bucket_path: []const []const u8, key: []const u8) !?[]u8 {
        const bucket_root_page_id = try self.resolveBucketPathRootPageId(allocator, bucket_path);
        const entry = try tree.lookupEntryPageReader(self.page_reader, allocator, bucket_root_page_id, key);
        return rootEntryValueOrError(allocator, entry);
    }

    fn bucketExistsInBucketPath(
        self: TxReadView,
        allocator: std.mem.Allocator,
        parent_bucket_path: []const []const u8,
        bucket: []const u8,
    ) !bool {
        const parent_root_page_id = try self.resolveBucketPathRootPageId(allocator, parent_bucket_path);
        const entry = try tree.lookupEntryPageReader(self.page_reader, allocator, parent_root_page_id, bucket);
        return try lookupEntryIsBucket(allocator, entry);
    }

    fn bucketNamesInBucketPathAlloc(self: TxReadView, allocator: std.mem.Allocator, parent_bucket_path: []const []const u8) !namespace.BucketNames {
        const parent_root_page_id = try self.resolveBucketPathRootPageId(allocator, parent_bucket_path);
        var bucket_cursor = self.cursorAtRoot(parent_root_page_id);
        defer bucket_cursor.deinit();
        return collectBucketNamesAlloc(&bucket_cursor, allocator);
    }

    fn scanAlloc(self: TxReadView, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
        return self.scanRangeAtRootAlloc(allocator, self.root_page_id, bounds);
    }

    fn cursor(self: TxReadView) tree.Cursor {
        return self.cursorAtRoot(self.root_page_id);
    }

    fn cursorInBucketPath(self: TxReadView, bucket_path: []const []const u8) !tree.Cursor {
        const bucket_root_page_id = try self.resolveBucketPathRootPageId(self.temp_allocator, bucket_path);
        return self.cursorAtRoot(bucket_root_page_id);
    }

    fn scanInBucketPathAlloc(self: TxReadView, allocator: std.mem.Allocator, bucket_path: []const []const u8, bounds: ScanBounds) !ScanRecords {
        const bucket_root_page_id = try self.resolveBucketPathRootPageId(allocator, bucket_path);
        return self.scanRangeAtRootAlloc(allocator, bucket_root_page_id, bounds);
    }

    fn resolveBucketPathRootPageId(self: TxReadView, allocator: std.mem.Allocator, bucket_path: []const []const u8) !u64 {
        return resolveBucketPathPageReaderRootPageId(self.page_reader, allocator, self.root_page_id, bucket_path);
    }

    fn scopedToBucketPath(self: TxReadView, bucket_path: []const []const u8) !TxReadView {
        return .{
            .page_reader = self.page_reader,
            .temp_allocator = self.temp_allocator,
            .cursor_owner = self.cursor_owner,
            .root_page_id = try self.resolveBucketPathRootPageId(self.temp_allocator, bucket_path),
        };
    }

    fn cursorAtRoot(self: TxReadView, root_page_id: u64) tree.Cursor {
        return tree.Cursor.init(self.page_reader, self.cursor_owner, self.temp_allocator, root_page_id);
    }

    fn scanRangeAtRootAlloc(self: TxReadView, allocator: std.mem.Allocator, root_page_id: u64, bounds: ScanBounds) !ScanRecords {
        if (rangeIsKnownEmpty(bounds)) {
            return .{ .items = &.{} };
        }

        var range_cursor = self.cursorAtRoot(root_page_id);
        defer range_cursor.deinit();

        return collectScanRangeAlloc(&range_cursor, allocator, bounds);
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

fn bucketRootPageIdAtTreeRoot(
    page_reader: tree.PageReader,
    allocator: std.mem.Allocator,
    tree_root_page_id: u64,
    bucket: []const u8,
) !u64 {
    const entry = try tree.lookupEntryPageReader(page_reader, allocator, tree_root_page_id, bucket);
    return try bucketRootPageIdFromLookup(allocator, entry);
}

fn resolveBucketPathPageReaderRootPageId(
    page_reader: tree.PageReader,
    allocator: std.mem.Allocator,
    root_page_id: u64,
    bucket_path: []const []const u8,
) !u64 {
    var current_root_page_id = root_page_id;
    for (bucket_path) |bucket| {
        current_root_page_id = try bucketRootPageIdAtTreeRoot(
            page_reader,
            allocator,
            current_root_page_id,
            bucket,
        );
    }
    return current_root_page_id;
}

fn resolveBucketPathCurrentRootPageId(
    view: *const UncommittedView,
    allocator: std.mem.Allocator,
    bucket_path: []const []const u8,
) !u64 {
    return resolveBucketPathPageReaderRootPageId(view.pageReader(), allocator, view.current_root_page_id, bucket_path);
}

fn cursorOwnerForReadTx(read_tx: *const ReadTx) tree.CursorOwner {
    return .{
        .context = read_tx,
        .is_active_fn = readTxCursorOwnerIsActive,
    };
}

fn readTxCursorOwnerIsActive(context: *const anyopaque) bool {
    const read_tx: *const ReadTx = @ptrCast(@alignCast(context));
    return read_tx.db != null;
}

fn cursorOwnerForWriteTx(write_tx: *const WriteTx) tree.CursorOwner {
    return .{
        .context = write_tx,
        .is_active_fn = writeTxCursorOwnerIsActive,
    };
}

fn writeTxCursorOwnerIsActive(context: *const anyopaque) bool {
    const write_tx: *const WriteTx = @ptrCast(@alignCast(context));
    return switch (write_tx.state) {
        .open_clean, .open_dirty => true,
        .committed, .rolled_back, .failed => false,
    };
}

fn writeBucketEntry(
    page_reader: tree.PageReader,
    arena_allocator: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    page_size: u32,
    page_allocator: *allocator_mod.PageAllocator,
    tree_root_page_id: u64,
    bucket: []const u8,
    bucket_root_page_id: u64,
) !tree.WriteResult {
    const bucket_record = try namespace.encodeBucketRecord(bucket_root_page_id);
    return tree.writePutWithFlags(
        page_reader,
        arena_allocator,
        backing_allocator,
        page_size,
        page_allocator,
        tree_root_page_id,
        bucket,
        bucket_record[0..],
        namespace.bucket_entry_flag,
    );
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

fn collectScanRangeAlloc(cursor: *tree.Cursor, allocator: std.mem.Allocator, bounds: ScanBounds) !ScanRecords {
    var records = std.ArrayList(tree.CursorRecord).empty;
    errdefer {
        for (records.items) |*record| record.deinit(allocator);
        records.deinit(allocator);
    }

    var next_record = if (bounds.start_inclusive) |start|
        try cursor.seek(allocator, start)
    else
        try cursor.first(allocator);

    while (next_record) |record| {
        var owned_record = record;
        if (!recordFallsWithinBounds(owned_record, bounds)) {
            owned_record.deinit(allocator);
            break;
        }

        try records.append(allocator, owned_record);
        next_record = try cursor.next(allocator);
    }

    return .{
        .items = try records.toOwnedSlice(allocator),
    };
}

fn rangeIsKnownEmpty(bounds: ScanBounds) bool {
    const start = bounds.start_inclusive orelse return false;
    const end = bounds.end_exclusive orelse return false;
    return std.mem.order(u8, start, end) != .lt;
}

fn recordFallsWithinBounds(record: tree.CursorRecord, bounds: ScanBounds) bool {
    const end = bounds.end_exclusive orelse return true;
    return std.mem.order(u8, record.key, end) == .lt;
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

fn tempDbPath(buf: []u8, tmp_dir: std.testing.TmpDir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

fn openTempDb(tmp_dir: std.testing.TmpDir, file_name: []const u8) !*db_mod.DB {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempDbPath(&path_buf, tmp_dir, file_name);
    return db_mod.open(std.testing.allocator, std.testing.io, path);
}

fn expectBucketNames(names: namespace.BucketNames, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

fn expectScanRecord(record: tree.CursorRecord, expected_key: []const u8, expected_value: []const u8) !void {
    try std.testing.expectEqualStrings(expected_key, record.key);
    try std.testing.expectEqualStrings(expected_value, record.value);
}

test "write transaction staged read view reflects namespace scan and cursor state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "staged-read-view.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.deinit();

    try write_tx.createBucket("animals");
    try write_tx.putInBucket("animals", "ant", "one");
    try write_tx.putInBucket("animals", "bat", "two");
    try write_tx.createBucketInBucketPath(&[_][]const u8{"animals"}, "birds");
    try write_tx.putInBucketPath(&[_][]const u8{ "animals", "birds" }, "crow", "three");

    try std.testing.expect(try write_tx.bucketExists(std.testing.allocator, "animals"));
    try std.testing.expect(try write_tx.bucketExistsInBucketPath(std.testing.allocator, &[_][]const u8{"animals"}, "birds"));

    var bucket_names = try write_tx.bucketNamesAlloc(std.testing.allocator);
    defer bucket_names.deinit(std.testing.allocator);
    try expectBucketNames(bucket_names, &[_][]const u8{"animals"});

    var nested_names = try write_tx.bucketNamesInBucketPathAlloc(std.testing.allocator, &[_][]const u8{"animals"});
    defer nested_names.deinit(std.testing.allocator);
    try expectBucketNames(nested_names, &[_][]const u8{"birds"});

    var scan = try write_tx.scanInBucketAlloc(std.testing.allocator, "animals", .{});
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), scan.items.len);
    try expectScanRecord(scan.items[0], "ant", "one");
    try expectScanRecord(scan.items[1], "bat", "two");
    try std.testing.expectEqualStrings("birds", scan.items[2].key);
    try std.testing.expect(namespace.isBucketFlags(scan.items[2].flags));

    var nested_scan = try write_tx.scanInBucketPathAlloc(std.testing.allocator, &[_][]const u8{ "animals", "birds" }, .{});
    defer nested_scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), nested_scan.items.len);
    try expectScanRecord(nested_scan.items[0], "crow", "three");

    var cursor = try write_tx.cursorInBucketPath(&[_][]const u8{ "animals", "birds" });
    defer cursor.deinit();
    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectScanRecord(first, "crow", "three");
}

test "read transaction bucket view keeps bucket scope and snapshot stability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "bucket-read-view.db");
    defer db.close();

    try db.createBucket("animals");
    try db.putInBucket("animals", "ant", "one");
    try db.createBucketInBucketPath(&[_][]const u8{"animals"}, "birds");
    try db.putInBucketPath(&[_][]const u8{ "animals", "birds" }, "crow", "three");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();

    var animals = try read_tx.bucketViewInBucket("animals");
    var birds = try animals.bucketViewInBucket("birds");

    try db.putInBucket("animals", "bat", "two");
    try db.putInBucketPath(&[_][]const u8{ "animals", "birds" }, "crow", "updated");

    const ant = (try animals.get(std.testing.allocator, "ant")).?;
    defer std.testing.allocator.free(ant);
    try std.testing.expectEqualSlices(u8, "one", ant);

    try std.testing.expect(try animals.bucketExists(std.testing.allocator, "birds"));
    var bucket_names = try animals.bucketNamesAlloc(std.testing.allocator);
    defer bucket_names.deinit(std.testing.allocator);
    try expectBucketNames(bucket_names, &[_][]const u8{"birds"});

    var scan = try animals.scanAlloc(std.testing.allocator, .{});
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.items.len);
    try expectScanRecord(scan.items[0], "ant", "one");
    try std.testing.expectEqualStrings("birds", scan.items[1].key);
    try std.testing.expect(namespace.isBucketFlags(scan.items[1].flags));

    const crow = (try birds.get(std.testing.allocator, "crow")).?;
    defer std.testing.allocator.free(crow);
    try std.testing.expectEqualSlices(u8, "three", crow);
}

test "write transaction bucket view reads staged nested state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "write-bucket-view.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.deinit();

    try write_tx.createBucket("animals");
    try write_tx.putInBucket("animals", "ant", "one");
    try write_tx.createBucketInBucketPath(&[_][]const u8{"animals"}, "birds");
    try write_tx.putInBucketPath(&[_][]const u8{ "animals", "birds" }, "crow", "three");

    var animals = try write_tx.bucketViewInBucket("animals");
    var birds = try animals.bucketViewInBucket("birds");

    const ant = (try animals.get(std.testing.allocator, "ant")).?;
    defer std.testing.allocator.free(ant);
    try std.testing.expectEqualSlices(u8, "one", ant);

    try std.testing.expect(try animals.bucketExists(std.testing.allocator, "birds"));
    var bucket_names = try animals.bucketNamesAlloc(std.testing.allocator);
    defer bucket_names.deinit(std.testing.allocator);
    try expectBucketNames(bucket_names, &[_][]const u8{"birds"});

    var scan = try birds.scanAlloc(std.testing.allocator, .{});
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), scan.items.len);
    try expectScanRecord(scan.items[0], "crow", "three");
}

test "write transaction bucket view writes scoped keys and buckets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "write-bucket-view-writes.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.deinit();

    try write_tx.createBucket("animals");
    var animals = try write_tx.bucketViewInBucket("animals");

    try animals.put("ant", "one");
    try animals.createBucket("birds");
    try animals.putInBucket("birds", "crow", "three");
    try animals.createBucketInBucket("birds", "owls");
    try animals.putInBucketPath(&[_][]const u8{ "birds", "owls" }, "snowy", "white");
    try animals.delete("ant");

    try std.testing.expect((try animals.get(std.testing.allocator, "ant")) == null);
    try std.testing.expect(try animals.bucketExists(std.testing.allocator, "birds"));

    var bucket_names = try animals.bucketNamesAlloc(std.testing.allocator);
    defer bucket_names.deinit(std.testing.allocator);
    try expectBucketNames(bucket_names, &[_][]const u8{"birds"});

    var birds = try animals.bucketViewInBucket("birds");
    const crow = (try birds.get(std.testing.allocator, "crow")).?;
    defer std.testing.allocator.free(crow);
    try std.testing.expectEqualSlices(u8, "three", crow);

    try std.testing.expect(try birds.bucketExists(std.testing.allocator, "owls"));
    const snowy = (try birds.getInBucket(std.testing.allocator, "owls", "snowy")).?;
    defer std.testing.allocator.free(snowy);
    try std.testing.expectEqualSlices(u8, "white", snowy);
}

test "nested write bucket views keep scoped paths for child writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "nested-write-bucket-view-writes.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.deinit();

    try write_tx.createBucket("animals");
    var animals = try write_tx.bucketViewInBucket("animals");
    try animals.createBucket("birds");

    var birds = try animals.bucketViewInBucket("birds");
    try birds.put("crow", "three");
    try birds.createBucket("owls");

    var owls = try birds.bucketViewInBucket("owls");
    try owls.put("snowy", "white");
    try owls.delete("snowy");
    try owls.put("great-horned", "brown");

    const crow = (try write_tx.getInBucketPath(std.testing.allocator, &[_][]const u8{ "animals", "birds" }, "crow")).?;
    defer std.testing.allocator.free(crow);
    try std.testing.expectEqualSlices(u8, "three", crow);

    try std.testing.expect((try owls.get(std.testing.allocator, "snowy")) == null);
    const great_horned = (try birds.getInBucket(std.testing.allocator, "owls", "great-horned")).?;
    defer std.testing.allocator.free(great_horned);
    try std.testing.expectEqualSlices(u8, "brown", great_horned);
}

test "write bucket view delete bucket reuses write transaction bucket semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "write-bucket-view-delete-bucket.db");
    defer db.close();

    try db.createBucket("animals");
    try db.createBucketInBucketPath(&[_][]const u8{"animals"}, "birds");
    try db.putInBucketPath(&[_][]const u8{ "animals", "birds" }, "crow", "three");

    var write_tx = try db.beginWrite();
    defer write_tx.deinit();

    var animals = try write_tx.bucketViewInBucket("animals");
    try animals.deleteBucket("birds");
    try std.testing.expect(!(try animals.bucketExists(std.testing.allocator, "birds")));
    try std.testing.expectError(error.BucketNotFound, animals.deleteBucket("birds"));
}

test "write transaction read helpers reject access after rollback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "closed-read-view.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.createBucket("animals");
    var bucket_view = try write_tx.bucketViewInBucket("animals");
    try write_tx.rollback();

    try std.testing.expectError(WriteTxError.WriteTransactionClosed, write_tx.get(std.testing.allocator, "animals"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, write_tx.bucketNamesAlloc(std.testing.allocator));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, write_tx.scanAlloc(std.testing.allocator, .{}));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, write_tx.cursor());
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, write_tx.bucketViewInBucket("animals"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.get(std.testing.allocator, "animals"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.put("ant", "one"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.createBucket("birds"));
}

test "write bucket view rejects access after commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTempDb(tmp, "closed-write-bucket-view-after-commit.db");
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.createBucket("animals");
    var bucket_view = try write_tx.bucketViewInBucket("animals");
    try write_tx.commit();

    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.get(std.testing.allocator, "animals"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.put("ant", "one"));
    try std.testing.expectError(WriteTxError.WriteTransactionClosed, bucket_view.deleteBucket("birds"));
}
