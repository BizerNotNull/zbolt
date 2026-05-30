const std = @import("std");
const errors = @import("errors.zig");
const meta = @import("meta.zig");

const default_page_size: u32 = 4096;
const bootstrap_page_count: u64 = 3;

pub const DB = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    file: std.Io.File,
    path: []u8,
    page_size: u32,
    root_page_id: u64,
    txid: u64,

    pub fn close(self: *DB) void {
        self.file.close(self.io_threaded.io());
        self.allocator.free(self.path);
        self.io_threaded.deinit();
        self.allocator.destroy(self);
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
        .page_size = 0,
        .root_page_id = 0,
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

    db.page_size = selected.meta.page_size;
    db.root_page_id = selected.meta.root_page_id;
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

    const root_page = try db.allocator.alloc(u8, default_page_size);
    defer db.allocator.free(root_page);
    @memset(root_page, 0);

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
    file: *std.Io.File,
    io: std.Io,
    page_id: u64,
    page_size: u32,
) ![]u8 {
    const page = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page);

    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(page_id * page_size);
    try reader.interface.readSliceAll(page);

    return page;
}

fn writePage(file: *std.Io.File, io: std.Io, page_id: u64, page: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(page_id * page.len);
    try writer.interface.writeAll(page);
    try writer.interface.flush();
}

// ==========tests==========

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
    const root_page = try std.testing.allocator.alloc(u8, default_page_size);
    defer std.testing.allocator.free(root_page);
    @memset(root_page, 0);

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);
    try writePage(&file, io, 2, root_page);
}

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

        const page = try readPage(std.testing.allocator, &file, io, 1, default_page_size);
        defer std.testing.allocator.free(page);

        var invalid_page = try std.testing.allocator.dupe(u8, page);
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
    const root_page = try std.testing.allocator.alloc(u8, root_size);
    defer std.testing.allocator.free(root_page);
    @memset(root_page, 0);

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);
    try writePage(&file, io, 2, root_page);
}
