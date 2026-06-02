const std = @import("std");
const errors = @import("errors.zig");
const meta = @import("meta.zig");
const page = @import("page.zig");
const tree = @import("tree.zig");

const default_page_size: u32 = 4096;
const bootstrap_page_count: u64 = 3;

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
    txid: u64,

    pub fn close(self: *DB) void {
        self.file.close(self.io_threaded.io());
        self.allocator.free(self.path);
        self.io_threaded.deinit();
        self.allocator.destroy(self);
    }

    /// Returns an owned copy of the value for `key`, or `null` when the key is absent.
    pub fn get(self: *DB, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return tree.lookup(self, allocator, key);
    }

    /// Commits a single-key update by copy-on-writing the affected tree path.
    pub fn put(self: *DB, key: []const u8, value: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        const write_result = try tree.writePut(self, allocator, key, value);

        const next_meta = meta.Meta{
            .page_size = self.page_size,
            .flags = self.flags,
            .root_page_id = write_result.root_page_id,
            .allocator_root = self.allocator_root,
            .high_water_mark = write_result.high_water_mark,
            .txid = self.txid + 1,
        };
        const next_meta_page = try meta.encode(self.allocator, next_meta);
        defer self.allocator.free(next_meta_page);

        const io = self.io_threaded.io();
        // Dirty tree pages are written in child-to-root order, and the meta
        // page remains the only commit point visible during recovery.
        for (write_result.pages) |pending_page| {
            try writePage(&self.file, io, pending_page.page_id, pending_page.bytes);
        }

        const next_meta_slot = inactiveMetaSlot(self.meta_slot);
        // Meta pages act as the commit point. Writing the inactive slot last
        // keeps the previously selected snapshot available until this commit is durable.
        try writePage(&self.file, io, metaSlotPageId(next_meta_slot), next_meta_page);

        self.meta_slot = next_meta_slot;
        self.flags = next_meta.flags;
        self.root_page_id = next_meta.root_page_id;
        self.allocator_root = next_meta.allocator_root;
        self.high_water_mark = next_meta.high_water_mark;
        self.txid = next_meta.txid;
    }

    pub fn readPageAlloc(self: *DB, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
        return readPage(allocator, &self.file, self.io_threaded.io(), page_id, self.page_size);
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
        .txid = 0,
    };
    errdefer allocator.free(db.path);
    errdefer db.io_threaded.deinit();

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

fn recoverOrInitialize(db: *DB) !void {
    const io = db.io_threaded.io();
    const stat = try db.file.stat(io);

    if (stat.size == 0) {
        try initializeEmptyDatabase(db);
    } else if (stat.size < @as(u64, default_page_size) * 2) {
        return errors.DbOpenError.DatabaseFileTooSmall;
    }

    const selected = loadSelectedMeta(db.allocator, &db.file, io, default_page_size) catch |err| switch (err) {
        error.NoValidMetaPage => return errors.DbOpenError.InvalidDatabaseFile,
        else => return err,
    };

    db.meta_slot = selected.slot;
    db.page_size = selected.meta.page_size;
    db.flags = selected.meta.flags;
    db.root_page_id = selected.meta.root_page_id;
    db.allocator_root = selected.meta.allocator_root;
    db.high_water_mark = selected.meta.high_water_mark;
    db.txid = selected.meta.txid;
}

// TODO: plan to implement crash-safe base on commit marker
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

    // TODO: atomic write for crash-safe, need to ponder neccessity on commit marker
    const io = db.io_threaded.io();
    try writePage(&db.file, io, 0, meta0_page);
    try writePage(&db.file, io, 1, meta1_page);
    try writePage(&db.file, io, 2, root_page);
}

fn loadSelectedMeta(allocator: std.mem.Allocator, file: *std.Io.File, io: std.Io, page_size: u32) !meta.SelectedMeta {
    const meta0_page = try readPage(allocator, file, io, 0, page_size);
    defer allocator.free(meta0_page);

    const meta1_page = try readPage(allocator, file, io, 1, page_size);
    defer allocator.free(meta1_page);

    // TODO: parse meta pages need to be explicited decomposition
    return meta.selectNewestValid(meta0_page, meta1_page);
}

fn readPage(
    allocator: std.mem.Allocator,
    file: *const std.Io.File,
    io: std.Io,
    page_id: u64,
    page_size: u32,
) ![]u8 {
    const page_bytes = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page_bytes);

    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(page_id * page_size);
    try reader.interface.readSliceAll(page_bytes);

    return page_bytes;
}

fn writePage(file: *std.Io.File, io: std.Io, page_id: u64, page_bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(page_id * page_bytes.len);
    try writer.interface.writeAll(page_bytes);
    try writer.interface.flush();
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

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);
    try writePage(&file, io, 2, root_page);
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

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);
    try writePage(&file, io, 2, root_page);
}

fn writeTreeDatabase(path: []const u8, root_page_id: u64, pages: []const []const u8) !void {
    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const high_water_mark = 2 + pages.len - 1;
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

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);

    for (pages, 0..) |page_bytes, index| {
        try writePage(&file, io, 2 + index, page_bytes);
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

fn expectBranchRootMatchesChildren(db: *DB) !void {
    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);

    const branch_page = try page.BranchPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 2), branch_page.count());

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

// ======tests=====

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

    const meta0_page = try readPage(std.testing.allocator, &db.file, db.io_threaded.io(), 0, default_page_size);
    defer std.testing.allocator.free(meta0_page);

    const meta1_page = try readPage(std.testing.allocator, &db.file, db.io_threaded.io(), 1, default_page_size);
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

    const root_page = try readPage(std.testing.allocator, &db.file, db.io_threaded.io(), 2, default_page_size);
    defer std.testing.allocator.free(root_page);

    const leaf_page = try page.LeafPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 0), leaf_page.count());
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

        const page_bytes = try readPage(std.testing.allocator, &file, io, 1, default_page_size);
        defer std.testing.allocator.free(page_bytes);

        var invalid_page = try std.testing.allocator.dupe(u8, page_bytes);
        defer std.testing.allocator.free(invalid_page);
        invalid_page[12] ^= 0xFF;
        try writePage(&file, io, 1, invalid_page);
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

        var meta0_page = try readPage(std.testing.allocator, &file, io, 0, default_page_size);
        defer std.testing.allocator.free(meta0_page);
        var meta1_page = try readPage(std.testing.allocator, &file, io, 1, default_page_size);
        defer std.testing.allocator.free(meta1_page);

        meta0_page[8] ^= 0xFF;
        meta1_page[8] ^= 0xFF;

        try writePage(&file, io, 0, meta0_page);
        try writePage(&file, io, 1, meta1_page);
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
    try std.testing.expectEqual(@as(u64, 3), db.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), db.txid);

    const value = (try db.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, "one", value);

    const selected = try loadSelectedMeta(std.testing.allocator, &db.file, db.io_threaded.io(), db.page_size);
    try std.testing.expectEqual(meta.MetaSlot.meta1, selected.slot);
    try std.testing.expectEqual(@as(u64, 3), selected.meta.root_page_id);
    try std.testing.expectEqual(@as(u64, 3), selected.meta.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), selected.meta.txid);
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
        try std.testing.expectEqual(@as(u64, 5), db.root_page_id);
        try std.testing.expectEqual(@as(u64, 5), db.high_water_mark);
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

        try std.testing.expectEqual(@as(u64, 28), db.high_water_mark);
        try std.testing.expectEqual(@as(u64, 24), db.txid);
        try expectBranchRootMatchesChildren(db);

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

    try expectBranchRootMatchesChildren(reopened);
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
    try std.testing.expectEqual(@as(u64, 6), db.high_water_mark);
    try std.testing.expectEqual(@as(u64, 1), db.txid);

    const value = (try db.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualSlices(u8, "updated", value);
    try expectBranchRootMatchesChildren(db);

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
    try expectBranchRootMatchesChildren(db);

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const branch_page = try page.BranchPage.validate(root_page);
    const second = try branch_page.entry(1);
    try std.testing.expectEqualSlices(u8, "zzzz", second.key);
}

test "put rejects unsupported branch child split before changing commit state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "put-child-split-unsupported.db");

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

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const old_root_page_id = db.root_page_id;
    const old_high_water_mark = db.high_water_mark;
    const old_txid = db.txid;
    const old_meta_slot = db.meta_slot;

    var value_buf: [160]u8 = undefined;
    try std.testing.expectError(
        tree.TreeWriteError.UnsupportedChildSplit,
        db.put("zzzz", fillFixedValue(&value_buf, 'y')),
    );

    try std.testing.expectEqual(old_root_page_id, db.root_page_id);
    try std.testing.expectEqual(old_high_water_mark, db.high_water_mark);
    try std.testing.expectEqual(old_txid, db.txid);
    try std.testing.expectEqual(old_meta_slot, db.meta_slot);
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
        try writePage(&file, io, 2, branch_root[0..]);
    }

    const db = try open(std.testing.allocator, path);
    defer db.close();

    try std.testing.expectError(error.UnexpectedPageType, db.put("alpha", "one"));
}
