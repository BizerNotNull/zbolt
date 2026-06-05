const std = @import("std");
const errors = @import("errors.zig");
const allocator_mod = @import("allocator.zig");
const meta = @import("meta.zig");
const page = @import("page.zig");
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
};

pub const DB = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    file: std.Io.File,
    path: []u8,
    meta_slot: meta.MetaSlot,
    page_size: u32,
    flags: u32,
    root_page_id: u64,
    allocator_root: u64,
    high_water_mark: u64,
    page_allocator: allocator_mod.PageAllocator,
    txid: u64,
    write_tx_active: bool,

    pub fn close(self: *DB) void {
        // Active WriteTx values borrow this DB and must be ended before close.
        std.debug.assert(!self.write_tx_active);
        self.file.close(self.io_threaded.io());
        self.page_allocator.deinit(self.allocator);
        self.allocator.free(self.path);
        self.io_threaded.deinit();
        self.allocator.destroy(self);
    }

    /// Returns an owned copy of the value for `key`, or `null` when the key is absent.
    pub fn get(self: *DB, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        var read_tx = self.beginRead();
        defer read_tx.deinit();

        return read_tx.get(allocator, key);
    }

    /// Opens a read-only view over the currently committed root.
    pub fn beginRead(self: *DB) tx.ReadTx {
        return .{
            .db = self,
            .snapshot = .{
                .root_page_id = self.root_page_id,
                .high_water_mark = self.high_water_mark,
            },
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

    pub fn readPageAlloc(self: *DB, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
        return readTreePageObjectAlloc(allocator, &self.file, self.io_threaded.io(), page_id, self.page_size, self.high_water_mark);
    }

    pub fn readPageAllocAtHighWater(self: *DB, allocator: std.mem.Allocator, page_id: u64, high_water_mark: u64) ![]u8 {
        return readTreePageObjectAlloc(allocator, &self.file, self.io_threaded.io(), page_id, self.page_size, high_water_mark);
    }
};

pub fn open(allocator: std.mem.Allocator, path: []const u8) !*DB {
    var db = try allocator.create(DB);
    errdefer allocator.destroy(db);

    db.* = .{
        .allocator = allocator,
        .io_threaded = .init(allocator, .{}),
        .file = undefined,
        .path = try allocator.dupe(u8, path),
        .meta_slot = .meta0,
        .page_size = 0,
        .flags = 0,
        .root_page_id = 0,
        .allocator_root = 0,
        .high_water_mark = 0,
        .page_allocator = allocator_mod.PageAllocator.init(allocator, 0),
        .txid = 0,
        .write_tx_active = false,
    };
    errdefer allocator.free(db.path);
    errdefer db.io_threaded.deinit();
    errdefer db.page_allocator.deinit(allocator);

    const io = db.io_threaded.io();

    db.file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
        }),
        else => return err,
    };

    errdefer db.file.close(io);

    try recoverOrInitialize(db);

    return db;
}

pub fn materializeAllocatorStatePage(db: *DB, baseline_page_allocator: allocator_mod.PageAllocator) !MaterializedAllocatorState {
    var baseline = baseline_page_allocator;
    errdefer baseline.deinit(db.allocator);

    var desired_order = try baseline.allocatorStateOrder(db.page_size);
    while (true) {
        var candidate = try baseline.clone(db.allocator);
        errdefer candidate.deinit(db.allocator);

        const page_id = try candidate.allocate(db.allocator, desired_order);
        const required_order = try candidate.allocatorStateOrder(db.page_size);
        if (required_order <= desired_order) {
            const state_page = try candidate.encodeStatePageAlloc(db.allocator, db.page_size, page_id, desired_order);
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
    const io = db.io_threaded.io();
    const stat = try db.file.stat(io);

    if (stat.size == 0) {
        try initializeEmptyDatabase(db);
    } else if (stat.size < @as(u64, default_page_size) * 2) {
        return errors.DbOpenError.DatabaseFileTooSmall;
    }

    var selected = loadNewestRecoverableSnapshot(db.allocator, &db.file, io, default_page_size) catch |err| switch (err) {
        error.NoValidMetaPage => return errors.DbOpenError.InvalidDatabaseFile,
        else => return err,
    };
    errdefer selected.page_allocator.deinit(db.allocator);

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

    const io = db.io_threaded.io();
    // A valid meta page is the recovery commit point, so the bootstrap root
    // must reach durable storage before either meta page can reference it.
    try storage.writePageObject(&db.file, io, default_page_size, initial_meta.root_page_id, root_page);
    try storage.sync(db.file, io);
    try storage.writePageObject(&db.file, io, default_page_size, 0, meta0_page);
    try storage.writePageObject(&db.file, io, default_page_size, 1, meta1_page);
    try storage.sync(db.file, io);
}

fn loadSelectedMeta(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !meta.SelectedMeta {
    const meta0_page = try storage.readPageAlloc(allocator, file, io, 0, page_size);
    defer allocator.free(meta0_page);

    const meta1_page = try storage.readPageAlloc(allocator, file, io, 1, page_size);
    defer allocator.free(meta1_page);

    // TODO: parse meta pages need to be explicited decomposition
    return meta.selectNewestValid(meta0_page, meta1_page);
}

fn loadNewestRecoverableSnapshot(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !RecoverableSnapshot {
    const meta0_page = try storage.readPageAlloc(allocator, file, io, 0, page_size);
    defer allocator.free(meta0_page);

    const meta1_page = try storage.readPageAlloc(allocator, file, io, 1, page_size);
    defer allocator.free(meta1_page);

    const snapshot0 = loadRecoverableSnapshotForMeta(allocator, file, io, meta.MetaSlot.meta0, meta0_page) catch |err| switch (err) {
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
    const snapshot1 = loadRecoverableSnapshotForMeta(allocator, file, io, meta.MetaSlot.meta1, meta1_page) catch |err| switch (err) {
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

    if (snapshot0 == null and snapshot1 == null) return error.NoValidMetaPage;
    if (snapshot0 != null and snapshot1 == null) return snapshot0.?;
    if (snapshot0 == null and snapshot1 != null) return snapshot1.?;

    if (snapshot0.?.meta.txid >= snapshot1.?.meta.txid) {
        var older = snapshot1.?;
        older.page_allocator.deinit(allocator);
        return snapshot0.?;
    }

    var older = snapshot0.?;
    older.page_allocator.deinit(allocator);
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

    const page_allocator = if (decoded_meta.allocator_root == 0)
        allocator_mod.PageAllocator.init(allocator, decoded_meta.high_water_mark)
    else blk: {
        const state_page = try readAllocatorStatePageObjectAlloc(
            allocator,
            file,
            io,
            decoded_meta.allocator_root,
            decoded_meta.page_size,
            decoded_meta.high_water_mark,
        );
        defer allocator.free(state_page);
        break :blk try allocator_mod.PageAllocator.restoreFromStatePage(
            allocator,
            state_page,
            decoded_meta.high_water_mark,
            decoded_meta.allocator_root,
        );
    };

    return .{
        .slot = slot,
        .meta = decoded_meta,
        .page_allocator = page_allocator,
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const stat = try db.file.stat(db.io_threaded.io());
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const stat = try tmp.dir.statFile(std.testing.io, "created.db", .{});
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u64, default_page_size) * bootstrap_page_count, stat.size);
    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 0), db.txid);
}

test "open initializes empty file with meta0 meta1 and root page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "initialized.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const stat = try db.file.stat(db.io_threaded.io());
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const meta0_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io_threaded.io(), 0, default_page_size);
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io_threaded.io(), 1, default_page_size);
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const root_page = try storage.readPageAlloc(std.testing.allocator, &db.file, db.io_threaded.io(), 2, default_page_size);
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

    try std.testing.expectError(errors.DbOpenError.InvalidDatabaseFile, open(std.testing.allocator, path));
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 3), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 9), db.txid);
}

test "open prefers only valid meta when the other one is invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "recover-one-valid.db");

    try writeSeededDatabase(path, .{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 7,
    }, .{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 3,
        .allocator_root = 0,
        .high_water_mark = 3,
        .txid = 8,
    });

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        const page_bytes = try storage.readPageAlloc(std.testing.allocator, &file, io, 1, default_page_size);
        defer std.testing.allocator.free(page_bytes);

        var invalid_page = try std.testing.allocator.dupe(u8, page_bytes);
        defer std.testing.allocator.free(invalid_page);
        invalid_page[12] ^= 0xFF;
        try storage.writePageObject(&file, io, default_page_size, 1, invalid_page);
    }

    const db = try open(std.testing.allocator, path);
    defer db.close();

    try std.testing.expectEqual(default_page_size, db.page_size);
    try std.testing.expectEqual(@as(u64, 2), db.root_page_id);
    try std.testing.expectEqual(@as(u64, 7), db.txid);
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

    try std.testing.expectError(errors.DbOpenError.DatabaseFileTooSmall, open(std.testing.allocator, path));
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

    try std.testing.expectError(errors.DbOpenError.DatabaseFileTooSmall, open(std.testing.allocator, path));
}

test "open maps invalid meta recovery into centralized db error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "bad-meta.db");

    try writeSeededDatabase(path, .{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 1,
    }, .{
        .page_size = default_page_size,
        .flags = 0,
        .root_page_id = 2,
        .allocator_root = 0,
        .high_water_mark = 2,
        .txid = 2,
    });

    {
        const io = std.testing.io;
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        defer file.close(io);

        var meta0_page = try storage.readPageAlloc(std.testing.allocator, &file, io, 0, default_page_size);
        defer std.testing.allocator.free(meta0_page);
        var meta1_page = try storage.readPageAlloc(std.testing.allocator, &file, io, 1, default_page_size);
        defer std.testing.allocator.free(meta1_page);

        meta0_page[8] ^= 0xFF;
        meta1_page[8] ^= 0xFF;

        try storage.writePageObject(&file, io, default_page_size, 0, meta0_page);
        try storage.writePageObject(&file, io, default_page_size, 1, meta1_page);
    }

    try std.testing.expectError(errors.DbOpenError.InvalidDatabaseFile, open(std.testing.allocator, path));
}

test "put commits a new root leaf and updates selected meta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-commit.db");

    const db = try open(std.testing.allocator, path);
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

    const selected = try loadSelectedMeta(std.testing.allocator, &db.file, db.io_threaded.io(), db.page_size);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();

        var index: usize = 0;
        while (index < 24) : (index += 1) {
            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, index);
            try db.put(key, value_buf[0..]);
        }
        try expectBranchRootMatchesChildren(db, 2);

        var read_tx = db.beginRead();
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

    const reopened = try open(std.testing.allocator, path);
    defer reopened.close();

    try expectDbValue(reopened, "k0000", "updated");
    try expectDbValue(reopened, "zzzz", "tail");
}

test "read transaction uses captured high water for higher-order root leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "read-tx-high-water.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    var large_value = [_]u8{'L'} ** 7000;
    try db.put("large", large_value[0..]);

    var read_tx = db.beginRead();
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
        const db = try open(std.testing.allocator, path);
        defer db.close();

        try db.put("alpha", "one");
        const old_root_page_id = db.root_page_id;
        const old_high_water_mark = db.high_water_mark;
        const old_txid = db.txid;

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var working_page_allocator = try db.page_allocator.clone(std.testing.allocator);
        defer working_page_allocator.deinit(std.testing.allocator);

        const write_result = try tree.writePut(db, arena.allocator(), &working_page_allocator, "beta", "two");
        const io = db.io_threaded.io();
        for (write_result.pages) |pending_page| {
            try storage.writePageObject(&db.file, io, db.page_size, pending_page.page_id, pending_page.bytes);
        }
        try storage.sync(db.file, io);

        try std.testing.expectEqual(old_root_page_id, db.root_page_id);
        try std.testing.expectEqual(old_high_water_mark, db.high_water_mark);
        try std.testing.expectEqual(old_txid, db.txid);
    }

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();

        try db.put("alpha", "one");

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var working_page_allocator = try db.page_allocator.clone(std.testing.allocator);
        errdefer working_page_allocator.deinit(std.testing.allocator);

        const write_result = try tree.writePut(db, arena.allocator(), &working_page_allocator, "beta", "two");
        const baseline_page_allocator = working_page_allocator;
        working_page_allocator = movedPageAllocator(std.testing.allocator);

        var allocator_state = try materializeAllocatorStatePage(db, baseline_page_allocator);
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

        const io = db.io_threaded.io();
        for (write_result.pages) |pending_page| {
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

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();

        try db.put("beta", "two");
        try db.put("alpha", "one");
        try db.put("beta", "updated");

        try std.testing.expectEqual(meta.MetaSlot.meta1, db.meta_slot);
        try std.testing.expectEqual(@as(u64, 7), db.root_page_id);
        try std.testing.expectEqual(@as(u64, 8), db.high_water_mark);
        try std.testing.expectEqual(@as(u64, 3), db.txid);
    }

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();

        var value_buf: [160]u8 = undefined;
        const value = fillFixedValue(&value_buf, 'x');

        var index: usize = 0;
        while (index < 24) : (index += 1) {
            var key_buf: [5]u8 = undefined;
            const key = try generatedKey(&key_buf, index);
            try db.put(key, value);
        }

        try std.testing.expectEqual(@as(u64, 52), db.high_water_mark);
        try std.testing.expectEqual(@as(u64, 24), db.txid);
        try expectBranchRootMatchesChildren(db, 2);

        const selected = try loadSelectedMeta(std.testing.allocator, &db.file, db.io_threaded.io(), db.page_size);
        try std.testing.expectEqual(db.root_page_id, selected.meta.root_page_id);
        try std.testing.expectEqual(db.high_water_mark, selected.meta.high_water_mark);
        try std.testing.expectEqual(db.txid, selected.meta.txid);
    }

    const reopened = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
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

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
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
        const reopened = try open(std.testing.allocator, path);
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

    const final_reopen = try open(std.testing.allocator, path);
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
        var db = try open(std.testing.allocator, path);

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
                db = try open(std.testing.allocator, path);
            }
        }

        try assertOracleMatches(db, &present, &expected_len, &expected_byte);
        try assertTreeInvariants(db);
        db.close();
    }

    const reopened = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
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

    const reopened = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();
        try db.put("old", "one");
        try db.put("new", "two");

        const newest_allocator_root = db.allocator_root;
        const io = db.io_threaded.io();
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

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
        defer db.close();
        try db.put("old", "one");

        var candidate = try db.page_allocator.clone(db.allocator);
        defer candidate.deinit(db.allocator);
        const unreferenced_root = try candidate.allocate(db.allocator, 0);
        const state_page = try candidate.encodeStatePageAlloc(std.testing.allocator, db.page_size, unreferenced_root, 0);
        defer std.testing.allocator.free(state_page);
        try storage.writePageObject(&db.file, db.io_threaded.io(), db.page_size, unreferenced_root, state_page);
    }

    const reopened = try open(std.testing.allocator, path);
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
        const db = try open(std.testing.allocator, path);
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

    const reopened = try open(std.testing.allocator, path);
    defer reopened.close();

    const state_page = try readAllocatorStatePageObjectAlloc(
        std.testing.allocator,
        &reopened.file,
        reopened.io_threaded.io(),
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

    const db = try open(std.testing.allocator, path);
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
        db.io_threaded.io(),
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    try std.testing.expectError(error.InvalidPageLayout, db.readPageAlloc(std.testing.allocator, 2));
}

test "explicit write transaction commit persists a staged put" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-commit.db");

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const initial_txid = db.txid;
    const initial_high_water_mark = db.high_water_mark;

    var write_tx = try db.beginWrite();
    try write_tx.put("alpha", "one");
    try write_tx.rollback();

    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expect(!db.write_tx_active);

    const value = try db.get(std.testing.allocator, "alpha");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "write transaction exposes a single writer slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-single-writer.db");

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
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

test "write transaction rejects a second put" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-single-put.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    defer write_tx.rollback() catch {};

    try write_tx.put("alpha", "one");
    try std.testing.expectError(tx.WriteTxError.WriteTransactionAlreadyUsed, write_tx.put("beta", "two"));
}

test "read transaction keeps its snapshot after an explicit write commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-read-snapshot.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    try db.put("alpha", "one");
    var read_tx = db.beginRead();
    defer read_tx.deinit();

    var write_tx = try db.beginWrite();
    try write_tx.put("beta", "two");
    try write_tx.commit();

    const snapshot_value = try read_tx.get(std.testing.allocator, "beta");
    defer if (snapshot_value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(snapshot_value == null);
    try expectDbValue(db, "beta", "two");
}

test "commit failure releases the writer slot and leaves the transaction failed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "write-tx-commit-failure.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.put("alpha", "one");

    const initial_txid = db.txid;
    const initial_high_water_mark = db.high_water_mark;
    const io = db.io_threaded.io();
    db.file.close(io);

    var commit_failed = false;
    write_tx.commit() catch {
        commit_failed = true;
    };
    try std.testing.expect(commit_failed);
    try std.testing.expectEqual(initial_txid, db.txid);
    try std.testing.expectEqual(initial_high_water_mark, db.high_water_mark);
    try std.testing.expect(!db.write_tx_active);
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.put("beta", "two"));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.commit());
    try std.testing.expectError(tx.WriteTxError.WriteTransactionFailed, write_tx.rollback());

    db.file = try std.Io.Dir.openFileAbsolute(io, db.path, .{ .mode = .read_write });

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

    const db = try open(std.testing.allocator, path);
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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    var write_tx = try db.beginWrite();
    try write_tx.rollback();

    try std.testing.expect(!db.write_tx_active);
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.put("alpha", "one"));
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.commit());
    try std.testing.expectError(tx.WriteTxError.WriteTransactionClosed, write_tx.rollback());
}
