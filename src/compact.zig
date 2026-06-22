const std = @import("std");
const errors = @import("errors.zig");
const meta = @import("meta.zig");
const page = @import("page.zig");
const storage = @import("storage.zig");
const tree = @import("tree.zig");

pub const Error = anyerror;

pub const PageDescriptor = struct {
    old_page_id: u64,
    new_page_id: u64,
    page_type: page.PageType,
    order: u8,
    bytes: []u8,
};

pub const SnapshotTreeWalker = struct {
    allocator: std.mem.Allocator,
    page_reader: tree.PageReader,
    snapshot: tree.ReadSnapshot,
    descriptors: std.ArrayList(PageDescriptor),
    new_page_ids: std.AutoHashMap(u64, u64),
    frontier: std.ArrayList(u64),
    next_page_id: u64,

    pub fn init(allocator: std.mem.Allocator, page_reader: tree.PageReader, snapshot: tree.ReadSnapshot) SnapshotTreeWalker {
        return .{
            .allocator = allocator,
            .page_reader = page_reader,
            .snapshot = snapshot,
            .descriptors = .empty,
            .new_page_ids = std.AutoHashMap(u64, u64).init(allocator),
            .frontier = .empty,
            .next_page_id = 2,
        };
    }

    pub fn deinit(self: *SnapshotTreeWalker) void {
        for (self.descriptors.items) |descriptor| {
            self.allocator.free(descriptor.bytes);
        }
        self.descriptors.deinit(self.allocator);
        self.new_page_ids.deinit();
        self.frontier.deinit(self.allocator);
    }

    pub fn walk(self: *SnapshotTreeWalker) Error!void {
        try self.frontier.append(self.allocator, self.snapshot.root_page_id);

        while (self.frontier.pop()) |page_id| {
            if (self.new_page_ids.contains(page_id)) return error.CorruptTreeShape;

            const page_bytes = try self.readOwnedPage(page_id);
            errdefer self.allocator.free(page_bytes);

            const header = try page.decodeHeader(page_bytes);
            const new_page_id = self.next_page_id;
            self.next_page_id = std.math.add(u64, self.next_page_id, try page.spanPageCount(header.order)) catch return error.PageIdOverflow;

            switch (header.page_type) {
                .leaf => _ = try page.LeafPage.validate(page_bytes),
                .branch => {
                    const branch_page = try page.BranchPage.validate(page_bytes);
                    var index = branch_page.count();
                    while (index > 0) {
                        index -= 1;
                        const entry = try branch_page.entry(index);
                        try self.frontier.append(self.allocator, entry.child_page_id);
                    }
                },
                else => return error.CorruptTreeShape,
            }

            try self.new_page_ids.put(page_id, new_page_id);
            try self.descriptors.append(self.allocator, .{
                .old_page_id = page_id,
                .new_page_id = new_page_id,
                .page_type = header.page_type,
                .order = header.order,
                .bytes = page_bytes,
            });
        }
    }

    pub fn rewritePages(self: *SnapshotTreeWalker) Error!void {
        for (self.descriptors.items) |*descriptor| {
            var header = try page.decodeHeader(descriptor.bytes);
            header.page_id = descriptor.new_page_id;
            try page.encodeHeader(descriptor.bytes, header);

            switch (descriptor.page_type) {
                .leaf => _ = try page.LeafPage.validate(descriptor.bytes),
                .branch => {
                    const branch_page = try page.BranchPage.validate(descriptor.bytes);
                    var index: u16 = 0;
                    while (index < branch_page.count()) : (index += 1) {
                        const entry = try branch_page.entry(index);
                        const child_page_id = self.new_page_ids.get(entry.child_page_id) orelse return error.CorruptTreeShape;
                        try page.BranchPage.rewriteChildPageId(descriptor.bytes, index, child_page_id);
                    }
                    _ = try page.BranchPage.validate(descriptor.bytes);
                },
                else => return error.CorruptTreeShape,
            }
        }
    }

    pub fn rootPageId(self: *const SnapshotTreeWalker) Error!u64 {
        return self.new_page_ids.get(self.snapshot.root_page_id) orelse error.CorruptTreeShape;
    }

    pub fn highWaterMark(self: *const SnapshotTreeWalker) Error!u64 {
        if (self.next_page_id < 3) return error.CorruptTreeShape;
        return self.next_page_id - 1;
    }

    fn readOwnedPage(self: *SnapshotTreeWalker, page_id: u64) Error![]u8 {
        const page_ref = try self.page_reader.readPage(self.allocator, page_id);
        defer page_ref.deinit(self.allocator);

        return switch (page_ref) {
            .owned => |page_bytes| try self.allocator.dupe(u8, page_bytes),
            .borrowed => |page_bytes| try self.allocator.dupe(u8, page_bytes.bytes),
        };
    }
};

pub const FileReplacement = struct {
    pub fn writeCompactedFile(
        allocator: std.mem.Allocator,
        temp_path: []const u8,
        io: std.Io,
        page_size: u32,
        descriptors: []const PageDescriptor,
        compact_meta: meta.Meta,
    ) Error!void {
        deleteFileIfExists(temp_path, io) catch {};

        var file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{
            .read = true,
            .truncate = true,
        });
        defer file.close(io);

        for (descriptors) |descriptor| {
            try storage.writePageObject(&file, io, page_size, descriptor.new_page_id, descriptor.bytes);
        }
        try storage.sync(file, io);

        const meta0_page = try meta.encode(allocator, compact_meta);
        defer allocator.free(meta0_page);
        const meta1_page = try meta.encode(allocator, compact_meta);
        defer allocator.free(meta1_page);

        try storage.writePageObject(&file, io, page_size, 0, meta0_page);
        try storage.writePageObject(&file, io, page_size, 1, meta1_page);
        try storage.sync(file, io);
    }

    pub fn replaceFileWithRollback(
        original_path: []const u8,
        temp_path: []const u8,
        backup_path: []const u8,
        io: std.Io,
    ) Error!void {
        deleteFileIfExists(backup_path, io) catch {};

        try std.Io.Dir.renameAbsolute(original_path, backup_path, io);
        errdefer {
            std.Io.Dir.renameAbsolute(backup_path, original_path, io) catch {};
        }

        std.Io.Dir.renameAbsolute(temp_path, original_path, io) catch {
            std.Io.Dir.renameAbsolute(backup_path, original_path, io) catch return error.FileReplaceRollbackFailed;
            return error.FileReplaceRolledBack;
        };

        deleteFileIfExists(backup_path, io) catch {};
    }
};

pub fn deleteFileIfExists(path: []const u8, io: std.Io) Error!void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ======tests======

fn fakeReadPage(context: *const anyopaque, allocator: std.mem.Allocator, page_id: u64) !storage.PageView {
    _ = allocator;
    const pages: *const [3][]const u8 = @ptrCast(@alignCast(context));

    return storage.PageView.fromBorrowed(switch (page_id) {
        2 => pages[0],
        3 => pages[1],
        4 => pages[2],
        else => return error.EntryOutOfBounds,
    });
}

test "SnapshotTreeWalker walks a branch root and rewrites child pointers" {
    var root_bytes = [_]u8{0} ** 128;
    _ = try page.BranchPage.encodeInto(root_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 4 },
    });

    var left_leaf = [_]u8{0} ** 128;
    _ = try page.LeafPage.encodeInto(left_leaf[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{.{ .key = "alpha", .value = "one", .flags = 0 }});

    var right_leaf = [_]u8{0} ** 128;
    _ = try page.LeafPage.encodeInto(right_leaf[0..], .{
        .page_id = 4,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{.{ .key = "omega", .value = "last", .flags = 0 }});

    const pages = [3][]const u8{ root_bytes[0..], left_leaf[0..], right_leaf[0..] };
    const page_reader = tree.PageReader{
        .context = &pages,
        .read_page_fn = fakeReadPage,
    };

    var walker = SnapshotTreeWalker.init(std.testing.allocator, page_reader, .{
        .root_page_id = 2,
        .high_water_mark = 4,
    });
    defer walker.deinit();

    try walker.walk();
    try walker.rewritePages();

    try std.testing.expectEqual(@as(u64, 2), try walker.rootPageId());
    try std.testing.expectEqual(@as(u64, 4), try walker.highWaterMark());

    const root_branch = try page.BranchPage.validate(walker.descriptors.items[0].bytes);
    const first = try root_branch.entry(0);
    const second = try root_branch.entry(1);
    try std.testing.expectEqual(@as(u64, 3), first.child_page_id);
    try std.testing.expectEqual(@as(u64, 4), second.child_page_id);
}

test "SnapshotTreeWalker rejects duplicate child references" {
    var root_bytes = [_]u8{0} ** 128;
    _ = try page.BranchPage.encodeInto(root_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "omega", .child_page_id = 3 },
    });

    var leaf_bytes = [_]u8{0} ** 128;
    _ = try page.LeafPage.encodeInto(leaf_bytes[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{.{ .key = "alpha", .value = "one", .flags = 0 }});

    const pages = [3][]const u8{ root_bytes[0..], leaf_bytes[0..], leaf_bytes[0..] };
    const page_reader = tree.PageReader{
        .context = &pages,
        .read_page_fn = fakeReadPage,
    };

    var walker = SnapshotTreeWalker.init(std.testing.allocator, page_reader, .{
        .root_page_id = 2,
        .high_water_mark = 3,
    });
    defer walker.deinit();

    try std.testing.expectError(error.CorruptTreeShape, walker.walk());
}
