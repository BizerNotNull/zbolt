const std = @import("std");
const meta = @import("meta.zig");
const page = @import("page.zig");
const db_mod = @import("db.zig");
const test_page_size = 4096;

pub const TreeLookupError = error{
    CorruptTreePath,
};

pub const TreeWriteError = error{
    EmptyBranchRoot,
    EmptyLeafSplit,
    UnsupportedChildSplit,
    UnsupportedTreeDepth,
};

pub const PendingPage = struct {
    page_id: u64,
    bytes: []const u8,
};

pub const WriteResult = struct {
    root_page_id: u64,
    high_water_mark: u64,
    pages: []const PendingPage,
};

const SplitLeafPages = struct {
    left_page: []const u8,
    right_page: []const u8,
    left_max_key: []const u8,
    right_max_key: []const u8,
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

pub fn writePut(db: *db_mod.DB, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !WriteResult {
    const root_page_bytes = try readTreePage(db, allocator, db.root_page_id);
    defer allocator.free(root_page_bytes);

    const header = try page.decodeHeader(root_page_bytes);
    return switch (header.page_type) {
        .leaf => try writeRootLeafPut(db, allocator, root_page_bytes, key, value),
        .branch => try writeBranchRootPut(db, allocator, root_page_bytes, key, value),
        else => error.UnexpectedPageType,
    };
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

fn selectChildIndexForPut(branch_page: page.BranchPage, key: []const u8) !u16 {
    if (branch_page.count() == 0) return TreeWriteError.EmptyBranchRoot;

    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const entry = try branch_page.entry(index);
        if (std.mem.order(u8, entry.key, key) != .lt) {
            return index;
        }
    }

    // Writes past the current largest upper bound extend the rightmost child
    // instead of treating the path as corrupt like the read-only lookup path.
    return branch_page.count() - 1;
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

fn writeRootLeafPut(
    db: *db_mod.DB,
    allocator: std.mem.Allocator,
    root_page_bytes: []const u8,
    key: []const u8,
    value: []const u8,
) !WriteResult {
    const root_leaf = try page.LeafPage.validate(root_page_bytes);

    var next_entries = std.ArrayList(page.LeafEntry).empty;
    try collectUpdatedLeafEntries(&next_entries, root_leaf, allocator, key, value);

    const next_root_page_id = db.high_water_mark + 1;
    const next_root_page = encodeLeafPageAlloc(
        allocator,
        db.page_size,
        next_root_page_id,
        root_leaf.header.order,
        next_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => return try splitRootLeaf(db, allocator, root_leaf.header.order, next_entries.items),
        else => return err,
    };

    const pending_pages = try allocator.alloc(PendingPage, 1);
    pending_pages[0] = .{ .page_id = next_root_page_id, .bytes = next_root_page };

    return .{
        .root_page_id = next_root_page_id,
        .high_water_mark = next_root_page_id,
        .pages = pending_pages,
    };
}

fn splitRootLeaf(
    db: *db_mod.DB,
    allocator: std.mem.Allocator,
    leaf_order: u8,
    entries: []const page.LeafEntry,
) !WriteResult {
    const left_id = db.high_water_mark + 1;
    const right_id = db.high_water_mark + 2;
    const root_id = db.high_water_mark + 3;

    const split_pages = try splitLeafEntries(
        allocator,
        db.page_size,
        left_id,
        right_id,
        leaf_order,
        entries,
    );

    const branch_entries = [_]page.BranchEntry{
        .{ .key = split_pages.left_max_key, .child_page_id = left_id },
        .{ .key = split_pages.right_max_key, .child_page_id = right_id },
    };
    const root_page = encodeBranchPageAlloc(allocator, db.page_size, root_id, 0, &branch_entries) catch |err| {
        allocator.free(split_pages.left_page);
        allocator.free(split_pages.right_page);
        return err;
    };

    const pending_pages = try allocator.alloc(PendingPage, 3);
    pending_pages[0] = .{ .page_id = left_id, .bytes = split_pages.left_page };
    pending_pages[1] = .{ .page_id = right_id, .bytes = split_pages.right_page };
    pending_pages[2] = .{ .page_id = root_id, .bytes = root_page };

    return .{
        .root_page_id = root_id,
        .high_water_mark = root_id,
        .pages = pending_pages,
    };
}

fn writeBranchRootPut(
    db: *db_mod.DB,
    allocator: std.mem.Allocator,
    root_page_bytes: []const u8,
    key: []const u8,
    value: []const u8,
) !WriteResult {
    const root_branch = try page.BranchPage.validate(root_page_bytes);
    const child_index = try selectChildIndexForPut(root_branch, key);
    const child_entry = try root_branch.entry(child_index);

    const child_page_bytes = try readTreePage(db, allocator, child_entry.child_page_id);
    defer allocator.free(child_page_bytes);

    const child_header = try page.decodeHeader(child_page_bytes);
    if (child_header.page_type != .leaf) return TreeWriteError.UnsupportedTreeDepth;

    const child_leaf = try page.LeafPage.validate(child_page_bytes);
    var next_child_entries = std.ArrayList(page.LeafEntry).empty;
    try collectUpdatedLeafEntries(&next_child_entries, child_leaf, allocator, key, value);

    const new_child_id = db.high_water_mark + 1;
    const new_root_id = db.high_water_mark + 2;
    const new_child_page = encodeLeafPageAlloc(
        allocator,
        db.page_size,
        new_child_id,
        child_leaf.header.order,
        next_child_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => return try writeBranchRootPutWithChildSplit(
            db,
            allocator,
            root_branch,
            child_index,
            child_leaf.header.order,
            next_child_entries.items,
        ),
        else => return err,
    };

    var branch_entries = std.ArrayList(page.BranchEntry).empty;
    var index: u16 = 0;
    while (index < root_branch.count()) : (index += 1) {
        const existing = try root_branch.entry(index);
        if (index == child_index) {
            try branch_entries.append(allocator, .{
                .key = maxKey(next_child_entries.items),
                .child_page_id = new_child_id,
            });
        } else {
            try branch_entries.append(allocator, .{
                .key = try allocator.dupe(u8, existing.key),
                .child_page_id = existing.child_page_id,
            });
        }
    }

    const new_root_page = encodeBranchPageAlloc(
        allocator,
        db.page_size,
        new_root_id,
        root_branch.header.order,
        branch_entries.items,
    ) catch |err| {
        allocator.free(new_child_page);
        return err;
    };

    const pending_pages = try allocator.alloc(PendingPage, 2);
    pending_pages[0] = .{ .page_id = new_child_id, .bytes = new_child_page };
    pending_pages[1] = .{ .page_id = new_root_id, .bytes = new_root_page };

    return .{
        .root_page_id = new_root_id,
        .high_water_mark = new_root_id,
        .pages = pending_pages,
    };
}

fn writeBranchRootPutWithChildSplit(
    db: *db_mod.DB,
    allocator: std.mem.Allocator,
    root_branch: page.BranchPage,
    child_index: u16,
    leaf_order: u8,
    next_child_entries: []const page.LeafEntry,
) !WriteResult {
    const left_id = db.high_water_mark + 1;
    const right_id = db.high_water_mark + 2;
    const root_id = db.high_water_mark + 3;

    const split_pages = try splitLeafEntries(
        allocator,
        db.page_size,
        left_id,
        right_id,
        leaf_order,
        next_child_entries,
    );

    var branch_entries = std.ArrayList(page.BranchEntry).empty;
    var index: u16 = 0;
    while (index < root_branch.count()) : (index += 1) {
        const existing = try root_branch.entry(index);
        if (index == child_index) {
            try branch_entries.append(allocator, .{
                .key = split_pages.left_max_key,
                .child_page_id = left_id,
            });
            try branch_entries.append(allocator, .{
                .key = split_pages.right_max_key,
                .child_page_id = right_id,
            });
        } else {
            try branch_entries.append(allocator, .{
                .key = try allocator.dupe(u8, existing.key),
                .child_page_id = existing.child_page_id,
            });
        }
    }

    const root_page = encodeBranchPageAlloc(
        allocator,
        db.page_size,
        root_id,
        root_branch.header.order,
        branch_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => {
            allocator.free(split_pages.left_page);
            allocator.free(split_pages.right_page);
            // Child leaf split is supported only while the branch root still fits.
            // Needing to split the branch/root is the next unsupported propagation step.
            return TreeWriteError.UnsupportedChildSplit;
        },
        else => {
            allocator.free(split_pages.left_page);
            allocator.free(split_pages.right_page);
            return err;
        },
    };

    const pending_pages = try allocator.alloc(PendingPage, 3);
    pending_pages[0] = .{ .page_id = left_id, .bytes = split_pages.left_page };
    pending_pages[1] = .{ .page_id = right_id, .bytes = split_pages.right_page };
    pending_pages[2] = .{ .page_id = root_id, .bytes = root_page };

    return .{
        .root_page_id = root_id,
        .high_water_mark = root_id,
        .pages = pending_pages,
    };
}

fn splitLeafEntries(
    allocator: std.mem.Allocator,
    page_size: u32,
    left_id: u64,
    right_id: u64,
    leaf_order: u8,
    entries: []const page.LeafEntry,
) !SplitLeafPages {
    if (entries.len < 2) return TreeWriteError.EmptyLeafSplit;

    var split_index: usize = 1;
    while (split_index < entries.len) : (split_index += 1) {
        const left_entries = entries[0..split_index];
        const right_entries = entries[split_index..];

        const left_page = encodeLeafPageAlloc(
            allocator,
            page_size,
            left_id,
            leaf_order,
            left_entries,
        ) catch |err| switch (err) {
            error.PageFull => continue,
            else => return err,
        };

        const right_page = encodeLeafPageAlloc(
            allocator,
            page_size,
            right_id,
            leaf_order,
            right_entries,
        ) catch |err| switch (err) {
            error.PageFull => {
                allocator.free(left_page);
                continue;
            },
            else => {
                allocator.free(left_page);
                return err;
            },
        };

        return .{
            .left_page = left_page,
            .right_page = right_page,
            .left_max_key = maxKey(left_entries),
            .right_max_key = maxKey(right_entries),
        };
    }

    return error.PageFull;
}

fn collectUpdatedLeafEntries(
    entries: *std.ArrayList(page.LeafEntry),
    leaf_page: page.LeafPage,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    var inserted = false;
    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const existing = try leaf_page.entry(index);
        switch (std.mem.order(u8, existing.key, key)) {
            .lt => try appendLeafEntry(entries, allocator, existing.key, existing.value, existing.flags),
            .eq => {
                try appendLeafEntry(entries, allocator, key, value, existing.flags);
                inserted = true;
            },
            .gt => {
                if (!inserted) {
                    try appendLeafEntry(entries, allocator, key, value, 0);
                    inserted = true;
                }
                try appendLeafEntry(entries, allocator, existing.key, existing.value, existing.flags);
            },
        }
    }

    if (!inserted) {
        try appendLeafEntry(entries, allocator, key, value, 0);
    }
}

fn appendLeafEntry(
    entries: *std.ArrayList(page.LeafEntry),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    flags: u32,
) !void {
    try entries.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
        .flags = flags,
    });
}

fn encodeLeafPageAlloc(
    allocator: std.mem.Allocator,
    page_size: u32,
    page_id: u64,
    order: u8,
    entries: []const page.LeafEntry,
) ![]u8 {
    const page_bytes = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page_bytes);
    @memset(page_bytes, 0);

    _ = try page.LeafPage.encodeInto(page_bytes, .{
        .page_id = page_id,
        .page_type = .leaf,
        .count = 0,
        .order = order,
    }, entries);

    return page_bytes;
}

fn encodeBranchPageAlloc(
    allocator: std.mem.Allocator,
    page_size: u32,
    page_id: u64,
    order: u8,
    entries: []const page.BranchEntry,
) ![]u8 {
    const page_bytes = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page_bytes);
    @memset(page_bytes, 0);

    _ = try page.BranchPage.encodeInto(page_bytes, .{
        .page_id = page_id,
        .page_type = .branch,
        .count = 0,
        .order = order,
    }, entries);

    return page_bytes;
}

fn maxKey(entries: []const page.LeafEntry) []const u8 {
    std.debug.assert(entries.len > 0);
    return entries[entries.len - 1].key;
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
