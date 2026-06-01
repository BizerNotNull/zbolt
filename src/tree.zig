const std = @import("std");
const meta = @import("meta.zig");
const page = @import("page.zig");
const db_mod = @import("db.zig");
const test_page_size = 4096;

pub const TreeLookupError = error{
    CorruptTreePath,
};

pub fn lookup(db: *db_mod.DB, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    var page_id = db.root_page_id;

    while (true) {
        const page_bytes = try readTreePage(db, allocator, page_id);
        defer allocator.free(page_bytes);

        const header = try page.decodeHeader(page_bytes);
        switch (header.page_type) {
            .branch => {
                const branch_page = try page.BranchPage.validate(page_bytes);
                page_id = try selectChild(branch_page, key);
            },
            .leaf => {
                const leaf_page = try page.LeafPage.validate(page_bytes);
                return try findInLeaf(leaf_page, allocator, key);
            },
            // The read path only understands tree navigation pages. Reaching any
            // other page type means the root or a child pointer escaped the tree.
            else => return error.UnexpectedPageType,
        }
    }
}

fn readTreePage(db: *db_mod.DB, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
    return db.readPageAlloc(allocator, page_id);
}

fn selectChild(branch_page: page.BranchPage, key: []const u8) !u64 {
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const entry = try branch_page.entry(index);
        // Branch entries store upper bounds, so the first bound that is not less
        // than the target identifies the subtree that may still contain the key.
        if (std.mem.order(u8, entry.key, key) != .lt) {
            return entry.child_page_id;
        }
    }

    // A branch page that cannot route a search key violates the stored
    // upper-bound invariant rather than representing a normal lookup miss.
    return TreeLookupError.CorruptTreePath;
}

fn findInLeaf(leaf_page: page.LeafPage, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const entry = try leaf_page.entry(index);
        switch (std.mem.order(u8, entry.key, key)) {
            // `lookup` frees the backing page buffer before returning, so callers
            // receive an owned copy instead of a borrowed slice into page memory.
            .eq => return try allocator.dupe(u8, entry.value),
            // Leaf entries are sorted, so once we pass the target key the page
            // cannot contain a later match.
            .gt => return null,
            .lt => {},
        }
    }

    return null;
}

// ======tests=====

// Test helpers build on-disk fixtures that exercise the real `DB.open` and
// `DB.get` path without mixing fixture details into the production API.
fn tempFilePath(buf: []u8, tmp_dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

fn writePage(file: *std.Io.File, io: std.Io, page_id: u64, page_bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(page_id * page_bytes.len);
    try writer.interface.writeAll(page_bytes);
    try writer.interface.flush();
}

fn encodeMetaPage(allocator: std.mem.Allocator, page_size: u32, root_page_id: u64, high_water_mark: u64) ![]u8 {
    return meta.encode(allocator, .{
        .page_size = page_size,
        .flags = 0,
        .root_page_id = root_page_id,
        .allocator_root = 0,
        .high_water_mark = high_water_mark,
        .txid = 0,
    });
}

fn createDatabaseFile(path: []const u8, page_size: u32, root_page_id: u64, pages: []const []const u8) !void {
    const io = std.testing.io;
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close(io);

    const high_water_mark = 2 + pages.len - 1;
    const meta0_page = try encodeMetaPage(std.testing.allocator, page_size, root_page_id, high_water_mark);
    defer std.testing.allocator.free(meta0_page);
    const meta1_page = try encodeMetaPage(std.testing.allocator, page_size, root_page_id, high_water_mark);
    defer std.testing.allocator.free(meta1_page);

    try writePage(&file, io, 0, meta0_page);
    try writePage(&file, io, 1, meta1_page);

    for (pages, 0..) |page_bytes, index| {
        try writePage(&file, io, 2 + index, page_bytes);
    }
}

fn openTestDb(tmp: std.testing.TmpDir, file_name: []const u8, page_size: u32, root_page_id: u64, pages: []const []const u8) !*db_mod.DB {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, file_name);
    try createDatabaseFile(path, page_size, root_page_id, pages);
    return db_mod.open(std.testing.allocator, path);
}

test "lookup returns null from an empty root leaf" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    try page.LeafPage.init(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "empty-root.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    const value = try lookup(db, std.testing.allocator, "missing");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "lookup returns owned value from a single leaf" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "single-leaf-hit.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    const value = (try lookup(db, std.testing.allocator, "beta")).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, "two", value);
}

test "lookup returns null for a missing key in a single leaf" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "gamma", .value = "three", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "single-leaf-miss.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    const value = try lookup(db, std.testing.allocator, "beta");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "lookup stops when a leaf entry key is already greater than target" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "delta", .value = "four", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "leaf-early-stop.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    const value = try lookup(db, std.testing.allocator, "beta");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "lookup descends through branch pages using upper-bound routing" {
    const page_size = test_page_size;
    var branch_page_bytes = [_]u8{0} ** page_size;
    _ = try page.BranchPage.encodeInto(branch_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 4 },
    });

    var left_leaf_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(left_leaf_bytes[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });

    var right_leaf_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(right_leaf_bytes[0..], .{
        .page_id = 4,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "gamma", .value = "three", .flags = 0 },
        .{ .key = "omega", .value = "last", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "branch-hit.db", page_size, 2, &.{
        branch_page_bytes[0..],
        left_leaf_bytes[0..],
        right_leaf_bytes[0..],
    });
    defer db.close();

    const value = (try lookup(db, std.testing.allocator, "omega")).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, "last", value);
}

test "lookup returns null after descending through branch pages" {
    const page_size = test_page_size;
    var branch_page_bytes = [_]u8{0} ** page_size;
    _ = try page.BranchPage.encodeInto(branch_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 4 },
    });

    var left_leaf_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(left_leaf_bytes[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });

    var right_leaf_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(right_leaf_bytes[0..], .{
        .page_id = 4,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "gamma", .value = "three", .flags = 0 },
        .{ .key = "omega", .value = "last", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "branch-miss.db", page_size, 2, &.{
        branch_page_bytes[0..],
        left_leaf_bytes[0..],
        right_leaf_bytes[0..],
    });
    defer db.close();

    const value = try lookup(db, std.testing.allocator, "kappa");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
}

test "lookup rejects branch paths whose upper-bounds cannot route the key" {
    const page_size = test_page_size;
    var branch_page_bytes = [_]u8{0} ** page_size;
    _ = try page.BranchPage.encodeInto(branch_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
    });

    var leaf_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(leaf_bytes[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "branch-corrupt.db", page_size, 2, &.{
        branch_page_bytes[0..],
        leaf_bytes[0..],
    });
    defer db.close();

    try std.testing.expectError(TreeLookupError.CorruptTreePath, lookup(db, std.testing.allocator, "omega"));
}

test "lookup rejects root pages that are neither branch nor leaf" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    try page.encodeHeader(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    });
    try page.encodeDataHeader(root_page_bytes[0..], .{
        .lower = page.data_header_size,
        .upper = page_size,
        .flags = 0,
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "bad-root-type.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    try std.testing.expectError(error.UnexpectedPageType, lookup(db, std.testing.allocator, "alpha"));
}

test "lookup propagates malformed leaf layouts" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    try page.LeafPage.init(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    });
    page.writeInt(u16, root_page_bytes[0..], page.header_size, 40);
    page.writeInt(u16, root_page_bytes[0..], page.header_size + 2, 32);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "bad-leaf-layout.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    try std.testing.expectError(error.InvalidPageLayout, lookup(db, std.testing.allocator, "alpha"));
}

test "lookup propagates malformed branch layouts" {
    const page_size = test_page_size;
    var branch_page_bytes = [_]u8{0} ** page_size;
    try page.BranchPage.init(branch_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    });
    page.writeInt(u16, branch_page_bytes[0..], page.header_size, 40);
    page.writeInt(u16, branch_page_bytes[0..], page.header_size + 2, 32);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "bad-branch-layout.db", page_size, 2, &.{branch_page_bytes[0..]});
    defer db.close();

    try std.testing.expectError(error.InvalidPageLayout, lookup(db, std.testing.allocator, "alpha"));
}

test "DB.get integrates facade lookup against a real file" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 0 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "db-get.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    const value = (try db.get(std.testing.allocator, "alpha")).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualSlices(u8, "one", value);
}
