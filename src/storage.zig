const std = @import("std");
const errors = @import("errors.zig");
const page = @import("page.zig");

pub const Error = errors.StorageError;

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
