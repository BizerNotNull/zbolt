const std = @import("std");
const errors = @import("errors.zig");
const page = @import("page.zig");

pub const Error = errors.StorageError;
pub const OpenDatabaseFileError = std.Io.File.OpenError || error{
    DatabaseLocked,
};
const database_file_lock: std.Io.File.Lock = .exclusive;
const database_file_lock_nonblocking = true;

pub const ActiveMapping = struct {
    allocator: std.mem.Allocator,
    current: ?*RetainedMap,
    retired: ?*RetainedMap,

    const RetainedMap = struct {
        map: std.Io.File.MemoryMap,
        pin_count: usize,
        next_retired: ?*RetainedMap,
    };

    pub fn init(allocator: std.mem.Allocator) ActiveMapping {
        return .{
            .allocator = allocator,
            .current = null,
            .retired = null,
        };
    }

    pub fn deinit(self: *ActiveMapping, io: std.Io) void {
        if (self.current) |mapping| self.destroyRetainedMap(io, mapping);
        self.current = null;

        var retired = self.retired;
        while (retired) |mapping| {
            const next = mapping.next_retired;
            self.destroyRetainedMap(io, mapping);
            retired = next;
        }
        self.retired = null;
    }

    pub fn remapReadOnly(self: *ActiveMapping, io: std.Io, file: std.Io.File, len: usize) !void {
        if (self.current) |current| {
            if (current.map.memory.len == len) return;
        }

        const next_map = try std.Io.File.MemoryMap.create(io, file, .{
            .len = len,
            .protection = .{ .read = true, .write = false },
        });
        errdefer {
            var cleanup = next_map;
            cleanup.destroy(io);
        }

        const next = try self.allocator.create(RetainedMap);
        errdefer self.allocator.destroy(next);
        next.* = .{
            .map = next_map,
            .pin_count = 0,
            .next_retired = null,
        };

        if (self.current) |current| {
            if (current.pin_count == 0) {
                self.destroyRetainedMap(io, current);
            } else {
                current.next_retired = self.retired;
                self.retired = current;
            }
        }

        self.current = next;
        self.collectReleasedRetiredMappings(io);
    }

    pub fn bytes(self: *const ActiveMapping) ?[]const u8 {
        const mapping = self.current orelse return null;
        return mapping.map.memory;
    }

    fn borrowRange(self: *ActiveMapping, start: usize, end: usize) PageView {
        const current = self.current orelse unreachable;
        std.debug.assert(start <= end);
        std.debug.assert(end <= current.map.memory.len);

        current.pin_count += 1;
        return PageView.pinBorrowed(
            current.map.memory[start..end],
            current,
            releaseRetainedMap,
        );
    }

    fn releaseRetainedMap(context: *anyopaque) void {
        const retained: *RetainedMap = @ptrCast(@alignCast(context));
        std.debug.assert(retained.pin_count > 0);
        retained.pin_count -= 1;
    }

    fn collectReleasedRetiredMappings(self: *ActiveMapping, io: std.Io) void {
        var current = &self.retired;
        while (current.*) |retained| {
            if (retained.pin_count == 0) {
                current.* = retained.next_retired;
                self.destroyRetainedMap(io, retained);
                continue;
            }

            current = &retained.next_retired;
        }
    }

    fn destroyRetainedMap(self: *ActiveMapping, io: std.Io, retained: *RetainedMap) void {
        std.debug.assert(retained.pin_count == 0);

        var mapping = retained.map;
        mapping.destroy(io);
        self.allocator.destroy(retained);
    }

    fn retiredMappingCount(self: *const ActiveMapping) usize {
        var count: usize = 0;
        var current = self.retired;
        while (current) |retained| {
            count += 1;
            current = retained.next_retired;
        }
        return count;
    }
};

pub const BorrowedPage = struct {
    bytes: []const u8,
    release_context: ?*anyopaque,
    release_fn: ?*const fn (context: *anyopaque) void,

    fn deinit(self: BorrowedPage) void {
        const release = self.release_fn orelse return;
        release(self.release_context.?);
    }
};

/// Storage-backed page bytes returned to higher layers.
///
/// `borrowed` views are owned by the underlying storage source, such as a
/// future mmap window or an in-memory staged page table, and must not outlive
/// that source. `owned` views are heap buffers that the caller must release.
pub const PageView = union(enum) {
    borrowed: BorrowedPage,
    owned: []const u8,

    pub fn fromBorrowed(page_bytes: []const u8) PageView {
        return .{
            .borrowed = .{
                .bytes = page_bytes,
                .release_context = null,
                .release_fn = null,
            },
        };
    }

    pub fn pinBorrowed(
        page_bytes: []const u8,
        release_context: *anyopaque,
        release_fn: *const fn (context: *anyopaque) void,
    ) PageView {
        return .{
            .borrowed = .{
                .bytes = page_bytes,
                .release_context = release_context,
                .release_fn = release_fn,
            },
        };
    }

    pub fn bytes(self: PageView) []const u8 {
        return switch (self) {
            .borrowed => |page_bytes| page_bytes.bytes,
            .owned => |page_bytes| page_bytes,
        };
    }

    pub fn deinit(self: PageView, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => |page_bytes| page_bytes.deinit(),
            .owned => |page_bytes| allocator.free(page_bytes),
        }
    }
};

/// Abstract page access across file-backed, mapped, or staged storage sources
/// without exposing the ownership policy to tree callers.
pub const PageReader = struct {
    context: *const anyopaque,
    read_page_fn: *const fn (context: *const anyopaque, allocator: std.mem.Allocator, page_id: u64) anyerror!PageView,

    pub fn readPage(self: PageReader, allocator: std.mem.Allocator, page_id: u64) !PageView {
        return self.read_page_fn(self.context, allocator, page_id);
    }
};

pub fn openDatabaseFileAbsolute(io: std.Io, path: []const u8) OpenDatabaseFileError!std.Io.File {
    return std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .read_write,
        .lock = database_file_lock,
        .lock_nonblocking = database_file_lock_nonblocking,
    }) catch |err| switch (err) {
        error.WouldBlock => error.DatabaseLocked,
        error.FileNotFound => std.Io.Dir.createFileAbsolute(io, path, .{
            .read = true,
            .truncate = false,
            .lock = database_file_lock,
            .lock_nonblocking = database_file_lock_nonblocking,
        }) catch |create_err| switch (create_err) {
            error.WouldBlock => error.DatabaseLocked,
            else => return create_err,
        },
        else => return err,
    };
}

pub fn readPageAlloc(
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
    try reader.seekTo(try pageOffset(page_id, page_size));
    try reader.interface.readSliceAll(page_bytes);

    return page_bytes;
}

pub fn readPageObjectAlloc(
    allocator: std.mem.Allocator,
    file: *const std.Io.File,
    io: std.Io,
    page_id: u64,
    base_page_size: u32,
    high_water_mark: u64,
    max_order: u8,
) ![]u8 {
    if (page_id > high_water_mark) return error.EntryOutOfBounds;

    const first_page = try readPageAlloc(allocator, file, io, page_id, base_page_size);
    errdefer allocator.free(first_page);

    const header = try page.decodeHeader(first_page);
    if (header.page_id != page_id) return error.InvalidPageLayout;

    if (header.order > max_order) return error.InvalidPageOrder;

    const span_end = try page.spanEndPageId(page_id, header.order);
    if (span_end > high_water_mark) return error.EntryOutOfBounds;

    const span_size = try page.spanSize(base_page_size, header.order);
    if (span_size == base_page_size) return first_page;

    const object_bytes = try allocator.alloc(u8, span_size);
    errdefer allocator.free(object_bytes);

    std.mem.copyForwards(u8, object_bytes[0..base_page_size], first_page);
    allocator.free(first_page);

    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const remaining_start_page_id = std.math.add(u64, page_id, 1) catch return error.PageIdOverflow;
    try reader.seekTo(try pageOffset(remaining_start_page_id, base_page_size));
    try reader.interface.readSliceAll(object_bytes[base_page_size..]);

    return object_bytes;
}

pub fn readMappedPageObject(
    mapping: *ActiveMapping,
    page_id: u64,
    base_page_size: u32,
    high_water_mark: u64,
    max_order: u8,
) !PageView {
    if (page_id > high_water_mark) return error.EntryOutOfBounds;

    const mapped_bytes = mapping.bytes() orelse return error.EntryOutOfBounds;
    const page_start = try pageOffset(page_id, base_page_size);
    const first_page_end = std.math.add(u64, page_start, base_page_size) catch return error.EntryOutOfBounds;
    if (first_page_end > mapped_bytes.len) return error.EntryOutOfBounds;

    const first_page = mapped_bytes[@intCast(page_start)..@intCast(first_page_end)];
    const header = try page.decodeHeader(first_page);
    if (header.page_id != page_id) return error.InvalidPageLayout;
    if (header.order > max_order) return error.InvalidPageOrder;

    const span_end = try page.spanEndPageId(page_id, header.order);
    if (span_end > high_water_mark) return error.EntryOutOfBounds;

    const span_size = try page.spanSize(base_page_size, header.order);
    const object_end = std.math.add(u64, page_start, span_size) catch return error.EntryOutOfBounds;
    if (object_end > mapped_bytes.len) return error.EntryOutOfBounds;

    return mapping.borrowRange(@intCast(page_start), @intCast(object_end));
}

pub fn writePage(file: *std.Io.File, io: std.Io, page_id: u64, page_size: u32, page_bytes: []const u8) !void {
    if (page_bytes.len != page_size) return Error.PageLengthMismatch;

    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(try pageOffset(page_id, page_size));
    try writer.interface.writeAll(page_bytes);
    try writer.interface.flush();
}

pub fn writePageObject(file: *std.Io.File, io: std.Io, base_page_size: u32, page_id: u64, page_bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(try pageOffset(page_id, base_page_size));
    try writer.interface.writeAll(page_bytes);
    try writer.interface.flush();
}

pub fn sync(file: std.Io.File, io: std.Io) !void {
    try file.sync(io);
}

pub fn pageOffset(page_id: u64, page_size: u32) Error!u64 {
    return std.math.mul(u64, page_id, page_size) catch Error.PageOffsetOverflow;
}

// ======tests======

fn tempFilePath(buf: []u8, tmp_dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

test "pageOffset multiplies page id by page size" {
    try std.testing.expectEqual(@as(u64, 4096 * 7), try pageOffset(7, 4096));
}

test "pageOffset rejects multiplication overflow" {
    try std.testing.expectError(Error.PageOffsetOverflow, pageOffset(std.math.maxInt(u64), 2));
}

test "writePage rejects buffers that are not exactly one page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "short-page.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const short_page = [_]u8{0} ** 15;
    try std.testing.expectError(Error.PageLengthMismatch, writePage(&file, io, 0, 16, short_page[0..]));
}

test "writePage writes at page size derived offsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "offset.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const page_size: u32 = 16;
    var page_bytes = [_]u8{0} ** page_size;
    page_bytes[0] = 0xAB;
    page_bytes[page_bytes.len - 1] = 0xCD;

    try writePage(&file, io, 3, page_size, page_bytes[0..]);

    const read_back = try readPageAlloc(std.testing.allocator, &file, io, 3, page_size);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualSlices(u8, page_bytes[0..], read_back);
}

test "writePageObject stores order one objects at base-page offsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "page-object-offset.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const page_size: u32 = 64;
    var object_bytes = [_]u8{0} ** (page_size * 2);
    try page.encodeHeader(object_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 1,
    });
    object_bytes[page_size] = 0xAB;
    object_bytes[object_bytes.len - 1] = 0xCD;

    try writePageObject(&file, io, page_size, 2, object_bytes[0..]);

    const read_back = try readPageObjectAlloc(std.testing.allocator, &file, io, 2, page_size, 3, 1);
    defer std.testing.allocator.free(read_back);
    try std.testing.expectEqualSlices(u8, object_bytes[0..], read_back);
}

test "openDatabaseFileAbsolute returns database locked when exclusive lock is already held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "locked.db");

    const io = std.testing.io;
    var first = try openDatabaseFileAbsolute(io, path);
    defer first.close(io);

    try std.testing.expectError(error.DatabaseLocked, openDatabaseFileAbsolute(io, path));
}

test "active mapping returns borrowed committed page bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "mapped-page.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const page_size: u32 = 64;
    var object_bytes = [_]u8{0} ** (page_size * 2);
    try page.encodeHeader(object_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 1,
    });
    object_bytes[page_size] = 0xAB;
    object_bytes[object_bytes.len - 1] = 0xCD;

    try writePageObject(&file, io, page_size, 2, object_bytes[0..]);

    var mapping = ActiveMapping.init(std.testing.allocator);
    defer mapping.deinit(io);
    try mapping.remapReadOnly(io, file, object_bytes.len + (page_size * 2));

    const page_view = try readMappedPageObject(&mapping, 2, page_size, 3, 1);
    defer page_view.deinit(std.testing.allocator);

    try std.testing.expect(page_view == .borrowed);
    try std.testing.expectEqualSlices(u8, object_bytes[0..], page_view.bytes());
}

test "active mapping remap keeps borrowed pages pinned across file growth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, "mapped-page-remap.db");

    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const page_size: u32 = 64;
    var initial_object = [_]u8{0} ** (page_size * 2);
    try page.encodeHeader(initial_object[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 1,
    });
    initial_object[page_size] = 0xAA;
    initial_object[initial_object.len - 1] = 0xBB;
    try writePageObject(&file, io, page_size, 2, initial_object[0..]);

    var mapping = ActiveMapping.init(std.testing.allocator);
    defer mapping.deinit(io);
    try mapping.remapReadOnly(io, file, page_size * 4);

    const initial_view = try readMappedPageObject(&mapping, 2, page_size, 3, 1);
    try std.testing.expect(initial_view == .borrowed);

    var grown_object = [_]u8{0} ** (page_size * 2);
    try page.encodeHeader(grown_object[0..], .{
        .page_id = 4,
        .page_type = .leaf,
        .count = 0,
        .order = 1,
    });
    grown_object[page_size] = 0xCC;
    grown_object[grown_object.len - 1] = 0xDD;
    try writePageObject(&file, io, page_size, 4, grown_object[0..]);

    try mapping.remapReadOnly(io, file, page_size * 6);
    try std.testing.expectEqual(@as(usize, 1), mapping.retiredMappingCount());
    try std.testing.expectEqualSlices(u8, initial_object[0..], initial_view.bytes());

    const grown_view = try readMappedPageObject(&mapping, 4, page_size, 5, 1);
    defer grown_view.deinit(std.testing.allocator);
    try std.testing.expect(grown_view == .borrowed);
    try std.testing.expectEqualSlices(u8, grown_object[0..], grown_view.bytes());

    initial_view.deinit(std.testing.allocator);
    mapping.collectReleasedRetiredMappings(io);
    try std.testing.expectEqual(@as(usize, 0), mapping.retiredMappingCount());
}
