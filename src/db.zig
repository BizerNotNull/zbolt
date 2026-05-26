const std = @import("std");

pub const DB = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    file: std.Io.File,
    path: []u8,

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

    return db;
}

// ==========tests==========

fn tempFilePath(buf: []u8, tmp_dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

test "open returns DB for an existing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "existing.db",
        .data = "seed",
        .flags = .{ .read = true, .truncate = false },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "existing.db");

    const db = try open(std.testing.allocator, path);
    defer db.close();

    const stat = try db.file.stat(db.io_threaded.io());
    try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
    try std.testing.expectEqual(@as(u64, 4), stat.size);
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
    try std.testing.expectEqual(@as(u64, 0), stat.size);
}
