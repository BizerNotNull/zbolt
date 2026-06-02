const std = @import("std");
const meta = @import("meta.zig");
const page = @import("page.zig");
const db_mod = @import("db.zig");
const errors = @import("errors.zig");
const test_page_size = 4096;

pub const TreeLookupError = error{
    CorruptTreePath,
};

const OwnedLeafEntry = struct {
    key: []u8,
    value: []u8,
    flags: u32,
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

pub fn rewriteSingleLeafRoot(
    allocator: std.mem.Allocator,
    root_page_bytes: []const u8,
    key: []const u8,
    value: []const u8,
    new_page_id: u64,
) ![]u8 {
    const header = try page.decodeHeader(root_page_bytes);
    switch (header.page_type) {
        .leaf => {
            const leaf_page = try page.LeafPage.validate(root_page_bytes);
            const current_entries = try readOwnedLeafEntries(allocator, leaf_page);
            defer freeOwnedLeafEntries(allocator, current_entries);

            const next_entries = try upsertOwnedLeafEntries(allocator, current_entries, key, value);
            defer freeOwnedLeafEntries(allocator, next_entries);

            return encodeOwnedLeafEntries(allocator, root_page_bytes.len, new_page_id, header.order, next_entries);
        },
        .branch => return errors.DbWriteError.UnsupportedWriteTree,
        else => return errors.DbWriteError.RootPageNotWritableLeaf,
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

fn readOwnedLeafEntries(allocator: std.mem.Allocator, leaf_page: page.LeafPage) ![]OwnedLeafEntry {
    const entries = try allocator.alloc(OwnedLeafEntry, leaf_page.count());
    errdefer allocator.free(entries);

    var initialized: usize = 0;
    errdefer freeOwnedLeafEntriesPartial(allocator, entries, initialized);

    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const entry = try leaf_page.entry(index);
        entries[index] = .{
            .key = try allocator.dupe(u8, entry.key),
            .value = try allocator.dupe(u8, entry.value),
            .flags = entry.flags,
        };
        initialized += 1;
    }

    return entries;
}

fn upsertOwnedLeafEntries(
    allocator: std.mem.Allocator,
    entries: []const OwnedLeafEntry,
    key: []const u8,
    value: []const u8,
) ![]OwnedLeafEntry {
    var insert_index: usize = entries.len;
    var replace_index: ?usize = null;

    for (entries, 0..) |entry, index| {
        switch (std.mem.order(u8, entry.key, key)) {
            .eq => {
                replace_index = index;
                insert_index = index;
                break;
            },
            .gt => {
                insert_index = index;
                break;
            },
            .lt => {},
        }
    }

    const next_len = if (replace_index == null) entries.len + 1 else entries.len;
    const next_entries = try allocator.alloc(OwnedLeafEntry, next_len);
    errdefer allocator.free(next_entries);

    var initialized: usize = 0;
    errdefer freeOwnedLeafEntriesPartial(allocator, next_entries, initialized);

    var source_index: usize = 0;
    var dest_index: usize = 0;
    while (dest_index < next_len) : (dest_index += 1) {
        if (dest_index == insert_index) {
            next_entries[dest_index] = .{
                .key = try allocator.dupe(u8, key),
                .value = try allocator.dupe(u8, value),
                .flags = if (replace_index) |index| entries[index].flags else 0,
            };
            initialized += 1;
            if (replace_index != null) source_index += 1;
            continue;
        }

        next_entries[dest_index] = .{
            .key = try allocator.dupe(u8, entries[source_index].key),
            .value = try allocator.dupe(u8, entries[source_index].value),
            .flags = entries[source_index].flags,
        };
        initialized += 1;
        source_index += 1;
    }

    return next_entries;
}

fn encodeOwnedLeafEntries(
    allocator: std.mem.Allocator,
    page_size: usize,
    page_id: u64,
    order: u8,
    entries: []const OwnedLeafEntry,
) ![]u8 {
    const page_bytes = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page_bytes);
    @memset(page_bytes, 0);

    const borrowed_entries = try allocator.alloc(page.LeafEntry, entries.len);
    defer allocator.free(borrowed_entries);

    for (entries, 0..) |entry, index| {
        borrowed_entries[index] = .{
            .key = entry.key,
            .value = entry.value,
            .flags = entry.flags,
        };
    }

    // v1 stops at the first page-full result so the write path stays append-only
    // until leaf splitting and parent updates are implemented together.
    _ = page.LeafPage.encodeInto(page_bytes, .{
        .page_id = page_id,
        .page_type = .leaf,
        .count = 0,
        .order = order,
    }, borrowed_entries) catch |err| switch (err) {
        error.PageFull => return errors.DbWriteError.LeafSplitRequired,
        else => return err,
    };

    return page_bytes;
}

fn freeOwnedLeafEntries(allocator: std.mem.Allocator, entries: []OwnedLeafEntry) void {
    freeOwnedLeafEntriesPartial(allocator, entries, entries.len);
    allocator.free(entries);
}

fn freeOwnedLeafEntriesPartial(allocator: std.mem.Allocator, entries: []OwnedLeafEntry, initialized: usize) void {
    for (entries[0..initialized]) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
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

test "rewriteSingleLeafRoot inserts a missing key in sorted order" {
    var root_page_bytes = [_]u8{0} ** test_page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "gamma", .value = "three", .flags = 0 },
    });

    const next_page = try rewriteSingleLeafRoot(std.testing.allocator, root_page_bytes[0..], "beta", "two", 3);
    defer std.testing.allocator.free(next_page);

    const leaf_page = try page.LeafPage.validate(next_page);
    try std.testing.expectEqual(@as(u16, 3), leaf_page.count());
    try std.testing.expectEqualSlices(u8, "alpha", (try leaf_page.entry(0)).key);
    try std.testing.expectEqualSlices(u8, "beta", (try leaf_page.entry(1)).key);
    try std.testing.expectEqualSlices(u8, "gamma", (try leaf_page.entry(2)).key);
    try std.testing.expectEqualSlices(u8, "two", (try leaf_page.entry(1)).value);
}

test "rewriteSingleLeafRoot replaces an existing key without duplicating it" {
    var root_page_bytes = [_]u8{0} ** test_page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 7 },
    });

    const next_page = try rewriteSingleLeafRoot(std.testing.allocator, root_page_bytes[0..], "beta", "updated", 3);
    defer std.testing.allocator.free(next_page);

    const leaf_page = try page.LeafPage.validate(next_page);
    try std.testing.expectEqual(@as(u16, 2), leaf_page.count());
    const second = try leaf_page.entry(1);
    try std.testing.expectEqualSlices(u8, "beta", second.key);
    try std.testing.expectEqualSlices(u8, "updated", second.value);
    try std.testing.expectEqual(@as(u32, 7), second.flags);
}

test "rewriteSingleLeafRoot reports leaf split requirement when page is full" {
    var root_page_bytes = [_]u8{0} ** 48;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "abcdef", .value = "ghijkl", .flags = 0 },
    });

    try std.testing.expectError(
        errors.DbWriteError.LeafSplitRequired,
        rewriteSingleLeafRoot(std.testing.allocator, root_page_bytes[0..], "z", "1", 3),
    );
}

test "rewriteSingleLeafRoot rejects branch roots until branch writes exist" {
    var root_page_bytes = [_]u8{0} ** test_page_size;
    _ = try page.BranchPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "omega", .child_page_id = 3 },
    });

    try std.testing.expectError(
        errors.DbWriteError.UnsupportedWriteTree,
        rewriteSingleLeafRoot(std.testing.allocator, root_page_bytes[0..], "alpha", "one", 3),
    );
}
