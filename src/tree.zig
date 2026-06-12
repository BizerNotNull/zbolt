const std = @import("std");
const page_allocator_mod = @import("allocator.zig");
const meta = @import("meta.zig");
const page = @import("page.zig");
const db_mod = @import("db.zig");
const reclaim = @import("reclaim.zig");
const storage = @import("storage.zig");
const test_page_size = 4096;

pub const TreeLookupError = error{
    CorruptTreePath,
};

pub const TreeWriteError = error{
    EmptyBranchRoot,
    EmptyLeafSplit,
    KeyValueTooLarge,
    BranchEntryTooLarge,
    PageOverflowNoValidSplit,
};

const CursorTraversalError = error{
    CursorUnpositioned,
};

const ReadTreePageError = @typeInfo(@typeInfo(@TypeOf(readTreePageSnapshot)).@"fn".return_type.?).error_union.error_set;

pub const CursorError = ReadTreePageError || page.Error || page.LayoutError || TreeLookupError || CursorTraversalError || error{OutOfMemory};

pub const PendingPage = struct {
    page_id: u64,
    bytes: []const u8,
};

pub const CursorRecord = struct {
    key: []u8,
    value: []u8,
    flags: u32,

    /// Releases the owned key/value buffers returned by a cursor operation.
    pub fn deinit(self: *CursorRecord, allocator: std.mem.Allocator) void {
        const owned_key = self.key;
        const owned_value = self.value;

        self.key = &.{};
        self.value = &.{};
        self.flags = 0;

        if (owned_key.len > 0) allocator.free(owned_key);
        if (owned_value.len > 0) allocator.free(owned_value);
    }
};

pub const PageRef = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    pub fn bytes(self: PageRef) []const u8 {
        return switch (self) {
            .borrowed => |page_bytes| page_bytes,
            .owned => |page_bytes| page_bytes,
        };
    }

    pub fn deinit(self: PageRef, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |page_bytes| allocator.free(page_bytes),
        }
    }
};

pub const PageReader = struct {
    context: *const anyopaque,
    read_page_fn: *const fn (context: *const anyopaque, allocator: std.mem.Allocator, page_id: u64) anyerror!PageRef,

    pub fn readPage(self: PageReader, allocator: std.mem.Allocator, page_id: u64) !PageRef {
        return self.read_page_fn(self.context, allocator, page_id);
    }
};

pub const WriteResult = struct {
    root_page_id: u64,
    allocation_high_water_mark: u64,
    new_pages: []const PendingPage,
    obsolete_pages: []const reclaim.ReleasedPage,
};

pub const DeleteMutation = union(enum) {
    unchanged,
    changed: WriteResult,
};

pub const ReadSnapshot = struct {
    root_page_id: u64,
    high_water_mark: u64,
};

pub const SnapshotSource = struct {
    io: std.Io,
    file: std.Io.File,
    page_size: u32,
    snapshot: ReadSnapshot,

    pub fn init(db: *db_mod.DB, snapshot: ReadSnapshot, file: std.Io.File) SnapshotSource {
        return .{
            .io = db.io_threaded.io(),
            .file = file,
            .page_size = db.page_size,
            .snapshot = snapshot,
        };
    }

    pub fn readPageAlloc(self: *const SnapshotSource, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
        return storage.readPageObjectAlloc(
            allocator,
            &self.file,
            self.io,
            page_id,
            self.page_size,
            self.snapshot.high_water_mark,
            try page.maxOrderForSpanSize(self.page_size, std.math.maxInt(u16)),
        );
    }

    pub fn pageReader(self: *const SnapshotSource) PageReader {
        return .{
            .context = self,
            .read_page_fn = readPage,
        };
    }

    fn readPage(context: *const anyopaque, allocator: std.mem.Allocator, page_id: u64) !PageRef {
        const self: *const SnapshotSource = @ptrCast(@alignCast(context));
        return .{ .owned = try self.readPageAlloc(allocator, page_id) };
    }
};

const max_cursor_depth: usize = @bitSizeOf(u64);

const PathFrame = struct {
    branch_page_id: u64,
    child_index: u16,
};

const PathStack = struct {
    len: usize,
    frames: [max_cursor_depth]PathFrame,

    fn init() PathStack {
        return .{
            .len = 0,
            .frames = undefined,
        };
    }

    fn truncate(self: *PathStack, len: usize) void {
        std.debug.assert(len <= self.len);
        self.len = len;
    }

    fn append(self: *PathStack, frame: PathFrame) TreeLookupError!void {
        if (self.len >= self.frames.len) return error.CorruptTreePath;
        self.frames[self.len] = frame;
        self.len += 1;
    }

    fn get(self: PathStack, index: usize) *const PathFrame {
        std.debug.assert(index < self.len);
        return &self.frames[index];
    }

    fn getPtr(self: *PathStack, index: usize) *PathFrame {
        std.debug.assert(index < self.len);
        return &self.frames[index];
    }
};

const CursorPosition = struct {
    leaf_page_id: u64,
    entry_index: u16,
    path: PathStack,
};

const CursorState = union(enum) {
    unpositioned,
    positioned: CursorPosition,
    eof,
};

pub const Cursor = struct {
    snapshot_source: ?*const SnapshotSource,
    owner_db: ?*const ?*db_mod.DB,
    temp_allocator: std.mem.Allocator,
    state: CursorState,

    /// Repositions the cursor to the first record visible in this snapshot.
    pub fn first(self: *Cursor, allocator: std.mem.Allocator) CursorError!?CursorRecord {
        const snapshot_source = self.snapshot_source orelse return error.CursorUnpositioned;
        if (!self.ownerIsActive()) return error.CursorUnpositioned;
        const position = try locateFirstPosition(snapshot_source, self.temp_allocator);
        return try self.setPositionAndMaterialize(allocator, position);
    }

    /// Repositions the cursor to the first record whose key is not less than `key`.
    pub fn seek(self: *Cursor, allocator: std.mem.Allocator, key: []const u8) CursorError!?CursorRecord {
        const snapshot_source = self.snapshot_source orelse return error.CursorUnpositioned;
        if (!self.ownerIsActive()) return error.CursorUnpositioned;
        const position = try locateSeekPosition(snapshot_source, self.temp_allocator, key);
        return try self.setPositionAndMaterialize(allocator, position);
    }

    /// Returns the next record after the current cursor position.
    pub fn next(self: *Cursor, allocator: std.mem.Allocator) CursorError!?CursorRecord {
        const snapshot_source = self.snapshot_source orelse return error.CursorUnpositioned;
        if (!self.ownerIsActive()) return error.CursorUnpositioned;

        const position = switch (self.state) {
            .unpositioned => return error.CursorUnpositioned,
            .eof => return null,
            .positioned => |current| try advancePosition(snapshot_source, self.temp_allocator, current),
        };

        return try self.setPositionAndMaterialize(allocator, position);
    }

    /// Releases the cursor handle. Returned records remain owned by the caller.
    pub fn deinit(self: *Cursor) void {
        self.snapshot_source = null;
        self.owner_db = null;
        self.state = .eof;
    }

    fn setPositionAndMaterialize(self: *Cursor, allocator: std.mem.Allocator, position: ?CursorPosition) CursorError!?CursorRecord {
        const snapshot_source = self.snapshot_source orelse return error.CursorUnpositioned;
        if (!self.ownerIsActive()) return error.CursorUnpositioned;
        const resolved_position = position orelse {
            self.state = .eof;
            return null;
        };

        self.state = .{ .positioned = resolved_position };
        return try materializeRecord(snapshot_source, self.temp_allocator, allocator, resolved_position);
    }

    fn ownerIsActive(self: *const Cursor) bool {
        const owner_db = self.owner_db orelse return false;
        return owner_db.* != null;
    }
};

pub const SnapshotPageReader = struct {
    source: SnapshotSource,

    pub fn init(db: *db_mod.DB, snapshot: ReadSnapshot) SnapshotPageReader {
        return .{
            .source = SnapshotSource.init(db, snapshot, db.file),
        };
    }

    pub fn pageReader(self: *const SnapshotPageReader) PageReader {
        return self.source.pageReader();
    }
};

const SplitLeafPages = struct {
    left_page: []u8,
    right_page: []u8,
    left_max_key: []const u8,
    right_max_key: []const u8,
};

const SplitBranchPages = struct {
    left_page: []u8,
    right_page: []u8,
    left_max_key: []const u8,
    right_max_key: []const u8,
};

const ChildRef = struct {
    page_id: u64,
    max_key: []const u8,
};

const PutResult = union(enum) {
    one: ChildRef,
    split: struct {
        left: ChildRef,
        right: ChildRef,
    },
};

const DeleteStep = union(enum) {
    unchanged,
    replaced: ChildRef,
    removed,
};

const WriteContext = struct {
    page_reader: PageReader,
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    page_size: u32,
    page_allocator: *page_allocator_mod.PageAllocator,
    new_pages: std.ArrayList(PendingPage),
    obsolete_pages: std.ArrayList(reclaim.ReleasedPage),

    fn init(
        page_reader: PageReader,
        backing_allocator: std.mem.Allocator,
        allocator: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        page_size: u32,
        page_allocator: *page_allocator_mod.PageAllocator,
    ) WriteContext {
        return .{
            .page_reader = page_reader,
            .backing_allocator = backing_allocator,
            .allocator = allocator,
            .temp_allocator = temp_allocator,
            .page_size = page_size,
            .page_allocator = page_allocator,
            .new_pages = .empty,
            .obsolete_pages = .empty,
        };
    }

    fn appendAllocatedPage(self: *WriteContext, bytes: []u8) !u64 {
        // Page IDs become committed only through the returned WriteResult; failed
        // writes may abandon this context without mutating DB state.
        var header = try page.decodeHeader(bytes);

        const span_size = try page.spanSize(self.page_size, header.order);
        if (bytes.len != span_size) return error.InvalidPageLayout;

        const page_id = try self.page_allocator.allocate(self.backing_allocator, header.order);
        header.page_id = page_id;
        try page.encodeHeader(bytes, header);

        try self.new_pages.append(self.allocator, .{
            .page_id = page_id,
            .bytes = bytes,
        });
        return page_id;
    }

    fn appendObsoletePage(self: *WriteContext, bytes: []const u8) !void {
        const header = try page.decodeHeader(bytes);
        try self.obsolete_pages.append(self.allocator, .{
            .page_id = header.page_id,
            .order = header.order,
        });
    }

    fn isAllocatedPage(self: *const WriteContext, page_id: u64) bool {
        for (self.new_pages.items) |pending_page| {
            if (pending_page.page_id == page_id) return true;
        }
        return false;
    }

    fn readAvailablePage(self: *WriteContext, allocator: std.mem.Allocator, page_id: u64) !PageRef {
        for (self.new_pages.items) |pending_page| {
            if (pending_page.page_id == page_id) {
                return .{ .borrowed = pending_page.bytes };
            }
        }

        return self.page_reader.readPage(allocator, page_id);
    }

    fn discardAllocatedPage(self: *WriteContext, page_id: u64) !void {
        var index: usize = 0;
        while (index < self.new_pages.items.len) : (index += 1) {
            const pending_page = self.new_pages.items[index];
            if (pending_page.page_id != page_id) continue;

            const header = try page.decodeHeader(pending_page.bytes);
            _ = self.new_pages.swapRemove(index);
            try self.page_allocator.release(self.backing_allocator, header.page_id, header.order);
            return;
        }

        return error.MissingAllocatedPage;
    }
};

pub fn lookup(db: *db_mod.DB, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    return lookupSnapshot(db, allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, key);
}

pub fn lookupSnapshot(db: *db_mod.DB, allocator: std.mem.Allocator, snapshot: ReadSnapshot, key: []const u8) !?[]u8 {
    const snapshot_source = SnapshotSource.init(db, snapshot, db.file);
    return lookupSnapshotSource(&snapshot_source, allocator, key);
}

pub fn lookupSnapshotSource(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    var page_id = snapshot_source.snapshot.root_page_id;

    while (true) {
        const page_bytes = try readTreePageSnapshot(snapshot_source, allocator, page_id);
        defer allocator.free(page_bytes);

        const header = try page.decodeHeader(page_bytes);
        switch (header.page_type) {
            .branch => {
                const branch_page = try page.BranchPage.validate(page_bytes);
                page_id = (try selectChildForLookup(branch_page, key)) orelse return null;
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

pub fn writePut(
    page_reader: PageReader,
    allocator: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    page_size: u32,
    page_allocator: *page_allocator_mod.PageAllocator,
    root_page_id: u64,
    key: []const u8,
    value: []const u8,
) !WriteResult {
    const root_page_ref = try page_reader.readPage(allocator, root_page_id);
    defer root_page_ref.deinit(allocator);

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();

    var ctx = WriteContext.init(
        page_reader,
        backing_allocator,
        allocator,
        temp_arena.allocator(),
        page_size,
        page_allocator,
    );
    const root_result = try writeNodePut(&ctx, root_page_ref.bytes(), key, value);

    const next_root_page_id = switch (root_result) {
        .one => |child| child.page_id,
        .split => |children| blk: {
            // Non-root branch splits bubble upward as child refs. Only the original
            // root split creates a new branch root and increases tree height.
            const root_entries = [_]page.BranchEntry{
                .{ .key = children.left.max_key, .child_page_id = children.left.page_id },
                .{ .key = children.right.max_key, .child_page_id = children.right.page_id },
            };
            const root_page = try encodeBranchPageAlloc(allocator, page_size, placeholderPageId(), 0, &root_entries);
            const root_id = try ctx.appendAllocatedPage(root_page);
            break :blk root_id;
        },
    };

    return .{
        .root_page_id = next_root_page_id,
        .allocation_high_water_mark = ctx.page_allocator.currentHighWaterMark(),
        .new_pages = ctx.new_pages.items,
        .obsolete_pages = ctx.obsolete_pages.items,
    };
}

pub fn writeDelete(
    page_reader: PageReader,
    allocator: std.mem.Allocator,
    backing_allocator: std.mem.Allocator,
    page_size: u32,
    page_allocator: *page_allocator_mod.PageAllocator,
    root_page_id: u64,
    key: []const u8,
) !DeleteMutation {
    const root_page_ref = try page_reader.readPage(allocator, root_page_id);
    defer root_page_ref.deinit(allocator);

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();

    var ctx = WriteContext.init(
        page_reader,
        backing_allocator,
        allocator,
        temp_arena.allocator(),
        page_size,
        page_allocator,
    );
    const root_step = try writeNodeDelete(&ctx, root_page_ref.bytes(), key);

    const next_root_page_id = switch (root_step) {
        .unchanged => return .unchanged,
        .removed => blk: {
            const empty_root = try allocateEmptyLeafPageAlloc(ctx.allocator, ctx.page_size);
            break :blk try ctx.appendAllocatedPage(empty_root);
        },
        .replaced => |child| try collapseSingleChildBranchRootIfNeeded(&ctx, child.page_id),
    };

    return .{ .changed = .{
        .root_page_id = next_root_page_id,
        .allocation_high_water_mark = ctx.page_allocator.currentHighWaterMark(),
        .new_pages = ctx.new_pages.items,
        .obsolete_pages = ctx.obsolete_pages.items,
    } };
}

fn readTreePageSnapshot(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator, page_id: u64) ![]u8 {
    return snapshot_source.readPageAlloc(allocator, page_id);
}

fn selectChildForLookup(branch_page: page.BranchPage, key: []const u8) !?u64 {
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const entry = try branch_page.entry(index);
        // Branch entries store upper bounds, so the first bound that is not less
        // than the target identifies the subtree that may still contain the key.
        if (std.mem.order(u8, entry.key, key) != .lt) {
            return entry.child_page_id;
        }
    }

    return null;
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

fn locateFirstPosition(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator) CursorError!?CursorPosition {
    const path = PathStack.init();
    return try descendToLeftmostPosition(snapshot_source, allocator, snapshot_source.snapshot.root_page_id, path, true);
}

fn locateSeekPosition(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator, key: []const u8) CursorError!?CursorPosition {
    var page_id = snapshot_source.snapshot.root_page_id;
    var path = PathStack.init();

    while (true) {
        const page_bytes = try readTreePageSnapshot(snapshot_source, allocator, page_id);
        defer allocator.free(page_bytes);

        const header = try page.decodeHeader(page_bytes);
        switch (header.page_type) {
            .branch => {
                const branch_page = try page.BranchPage.validate(page_bytes);
                const child_index = (try selectChildIndexForLookup(branch_page, key)) orelse return null;
                const child_entry = try branch_page.entry(child_index);
                try path.append(.{
                    .branch_page_id = header.page_id,
                    .child_index = child_index,
                });
                page_id = child_entry.child_page_id;
            },
            .leaf => {
                const leaf_page = try page.LeafPage.validate(page_bytes);
                if (leaf_page.count() == 0) return null;

                if (try findLowerBoundIndex(leaf_page, key)) |entry_index| {
                    return .{
                        .leaf_page_id = header.page_id,
                        .entry_index = entry_index,
                        .path = path,
                    };
                }

                return try successorPositionFromPath(snapshot_source, allocator, path);
            },
            else => return error.UnexpectedPageType,
        }
    }
}

fn advancePosition(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator, current: CursorPosition) CursorError!?CursorPosition {
    const page_bytes = try readTreePageSnapshot(snapshot_source, allocator, current.leaf_page_id);
    defer allocator.free(page_bytes);

    const leaf_page = try page.LeafPage.validate(page_bytes);
    if (current.entry_index >= leaf_page.count()) return error.CorruptTreePath;

    const next_entry_index = std.math.add(u16, current.entry_index, 1) catch return error.CorruptTreePath;
    if (next_entry_index < leaf_page.count()) {
        return .{
            .leaf_page_id = current.leaf_page_id,
            .entry_index = next_entry_index,
            .path = current.path,
        };
    }

    return try successorPositionFromPath(snapshot_source, allocator, current.path);
}

fn materializeRecord(
    snapshot_source: *const SnapshotSource,
    temp_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    position: CursorPosition,
) CursorError!CursorRecord {
    const page_bytes = try readTreePageSnapshot(snapshot_source, temp_allocator, position.leaf_page_id);
    defer temp_allocator.free(page_bytes);

    const leaf_page = try page.LeafPage.validate(page_bytes);
    const entry = try leaf_page.entry(position.entry_index);

    const owned_key = try allocator.dupe(u8, entry.key);
    errdefer allocator.free(owned_key);

    const owned_value = try allocator.dupe(u8, entry.value);
    return .{
        .key = owned_key,
        .value = owned_value,
        .flags = entry.flags,
    };
}

fn descendToLeftmostPosition(
    snapshot_source: *const SnapshotSource,
    allocator: std.mem.Allocator,
    start_page_id: u64,
    initial_path: PathStack,
    allow_empty_leaf: bool,
) CursorError!?CursorPosition {
    var page_id = start_page_id;
    var path = initial_path;

    while (true) {
        const page_bytes = try readTreePageSnapshot(snapshot_source, allocator, page_id);
        defer allocator.free(page_bytes);

        const header = try page.decodeHeader(page_bytes);
        switch (header.page_type) {
            .branch => {
                const branch_page = try page.BranchPage.validate(page_bytes);
                if (branch_page.count() == 0) return error.CorruptTreePath;

                const child_index: u16 = 0;
                const child_entry = try branch_page.entry(child_index);
                try path.append(.{
                    .branch_page_id = header.page_id,
                    .child_index = child_index,
                });
                page_id = child_entry.child_page_id;
            },
            .leaf => {
                const leaf_page = try page.LeafPage.validate(page_bytes);
                if (leaf_page.count() == 0) {
                    if (allow_empty_leaf) return null;
                    return error.CorruptTreePath;
                }

                return .{
                    .leaf_page_id = header.page_id,
                    .entry_index = 0,
                    .path = path,
                };
            },
            else => return error.UnexpectedPageType,
        }
    }
}

fn successorPositionFromPath(snapshot_source: *const SnapshotSource, allocator: std.mem.Allocator, path: PathStack) CursorError!?CursorPosition {
    var branch_level = path.len;
    while (branch_level > 0) {
        branch_level -= 1;

        const frame = path.get(branch_level).*;
        const page_bytes = try readTreePageSnapshot(snapshot_source, allocator, frame.branch_page_id);
        defer allocator.free(page_bytes);

        const branch_page = try page.BranchPage.validate(page_bytes);
        if (frame.child_index >= branch_page.count()) return error.CorruptTreePath;

        const next_child_index = std.math.add(u16, frame.child_index, 1) catch continue;
        if (next_child_index >= branch_page.count()) continue;

        const next_child = try branch_page.entry(next_child_index);
        var next_path = path;
        next_path.truncate(branch_level);
        try next_path.append(.{
            .branch_page_id = frame.branch_page_id,
            .child_index = next_child_index,
        });

        return try descendToLeftmostPosition(snapshot_source, allocator, next_child.child_page_id, next_path, false);
    }

    return null;
}

fn selectChildIndexForLookup(branch_page: page.BranchPage, key: []const u8) !?u16 {
    // Branch and leaf entries are already sorted, so cursor seeks can use the
    // same lower-bound search shape that a B+Tree read path expects.
    var low: u16 = 0;
    var high: u16 = branch_page.count();

    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = try branch_page.entry(mid);
        if (std.mem.order(u8, entry.key, key) == .lt) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (low == branch_page.count()) return null;
    return low;
}

fn findLowerBoundIndex(leaf_page: page.LeafPage, key: []const u8) !?u16 {
    var low: u16 = 0;
    var high: u16 = leaf_page.count();

    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = try leaf_page.entry(mid);
        if (std.mem.order(u8, entry.key, key) == .lt) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (low == leaf_page.count()) return null;
    return low;
}

fn writeNodePut(ctx: *WriteContext, node_page_bytes: []const u8, key: []const u8, value: []const u8) anyerror!PutResult {
    const header = try page.decodeHeader(node_page_bytes);
    return switch (header.page_type) {
        .leaf => try writeLeafPut(ctx, node_page_bytes, key, value),
        .branch => try writeBranchPut(ctx, node_page_bytes, key, value),
        else => error.UnexpectedPageType,
    };
}

fn writeNodeDelete(ctx: *WriteContext, node_page_bytes: []const u8, key: []const u8) anyerror!DeleteStep {
    const header = try page.decodeHeader(node_page_bytes);
    return switch (header.page_type) {
        .leaf => try writeLeafDelete(ctx, node_page_bytes, key),
        .branch => try writeBranchDelete(ctx, node_page_bytes, key),
        else => error.UnexpectedPageType,
    };
}

fn writeLeafPut(ctx: *WriteContext, leaf_page_bytes: []const u8, key: []const u8, value: []const u8) anyerror!PutResult {
    const leaf_page = try page.LeafPage.validate(leaf_page_bytes);

    var next_entries = std.ArrayList(page.LeafEntry).empty;
    try collectUpdatedLeafEntries(&next_entries, leaf_page, ctx.temp_allocator, key, value);

    const leaf_bytes = encodeLeafPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        leaf_page.header.order,
        next_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => {
            if (next_entries.items.len == 1) {
                const grown_leaf = try encodeSingleLeafPageBestFitAlloc(
                    ctx.allocator,
                    ctx.page_size,
                    placeholderPageId(),
                    leaf_page.header.order,
                    next_entries.items,
                );
                const page_id = try ctx.appendAllocatedPage(grown_leaf);
                try ctx.appendObsoletePage(leaf_page_bytes);
                return .{ .one = .{
                    .page_id = page_id,
                    .max_key = maxKey(next_entries.items),
                } };
            }
            const split_result = try splitLeafPut(ctx, leaf_page.header.order, next_entries.items);
            try ctx.appendObsoletePage(leaf_page_bytes);
            return split_result;
        },
        else => return err,
    };

    const page_id = try ctx.appendAllocatedPage(leaf_bytes);
    try ctx.appendObsoletePage(leaf_page_bytes);
    return .{ .one = .{
        .page_id = page_id,
        .max_key = maxKey(next_entries.items),
    } };
}

fn writeBranchPut(ctx: *WriteContext, branch_page_bytes: []const u8, key: []const u8, value: []const u8) anyerror!PutResult {
    const branch_page = try page.BranchPage.validate(branch_page_bytes);
    const child_index = try selectChildIndexForPut(branch_page, key);
    const child_entry = try branch_page.entry(child_index);

    const child_page_ref = try ctx.page_reader.readPage(ctx.allocator, child_entry.child_page_id);
    defer child_page_ref.deinit(ctx.allocator);

    const child_result = try writeNodePut(ctx, child_page_ref.bytes(), key, value);

    var next_entries = std.ArrayList(page.BranchEntry).empty;
    try collectUpdatedBranchEntries(&next_entries, branch_page, ctx.temp_allocator, child_index, child_result);

    const branch_bytes = encodeBranchPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        branch_page.header.order,
        next_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => {
            if (next_entries.items.len == 1) return TreeWriteError.BranchEntryTooLarge;
            const split_result = try splitBranchPut(ctx, branch_page.header.order, next_entries.items);
            try ctx.appendObsoletePage(branch_page_bytes);
            return split_result;
        },
        else => return err,
    };

    const page_id = try ctx.appendAllocatedPage(branch_bytes);
    try ctx.appendObsoletePage(branch_page_bytes);
    return .{ .one = .{
        .page_id = page_id,
        .max_key = branchEntriesMaxKey(next_entries.items),
    } };
}

fn writeLeafDelete(ctx: *WriteContext, leaf_page_bytes: []const u8, key: []const u8) anyerror!DeleteStep {
    const leaf_page = try page.LeafPage.validate(leaf_page_bytes);

    var next_entries = std.ArrayList(page.LeafEntry).empty;
    const deleted = try collectDeletedLeafEntries(&next_entries, leaf_page, ctx.temp_allocator, key);
    if (!deleted) return .unchanged;

    if (next_entries.items.len == 0) {
        try ctx.appendObsoletePage(leaf_page_bytes);
        return .removed;
    }

    const leaf_bytes = try encodeLeafPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        leaf_page.header.order,
        next_entries.items,
    );
    const page_id = try ctx.appendAllocatedPage(leaf_bytes);
    try ctx.appendObsoletePage(leaf_page_bytes);
    return .{ .replaced = .{
        .page_id = page_id,
        .max_key = maxKey(next_entries.items),
    } };
}

fn writeBranchDelete(ctx: *WriteContext, branch_page_bytes: []const u8, key: []const u8) anyerror!DeleteStep {
    const branch_page = try page.BranchPage.validate(branch_page_bytes);
    const child_index = try selectChildIndexForPut(branch_page, key);
    const child_entry = try branch_page.entry(child_index);

    const child_page_ref = try ctx.page_reader.readPage(ctx.allocator, child_entry.child_page_id);
    defer child_page_ref.deinit(ctx.allocator);

    const child_step = try writeNodeDelete(ctx, child_page_ref.bytes(), key);
    if (child_step == .unchanged) return .unchanged;

    var next_entries = std.ArrayList(page.BranchEntry).empty;
    try collectDeletedBranchEntries(&next_entries, branch_page, ctx.temp_allocator, child_index, child_step);

    if (next_entries.items.len == 0) {
        try ctx.appendObsoletePage(branch_page_bytes);
        return .removed;
    }

    var affected_index = switch (child_step) {
        .removed => @min(@as(usize, child_index), next_entries.items.len - 1),
        .replaced => @as(usize, child_index),
        .unchanged => unreachable,
    };
    try maybeMergeBranchChildren(ctx, &next_entries, &affected_index);

    const branch_bytes = try encodeBranchPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        branch_page.header.order,
        next_entries.items,
    );
    const page_id = try ctx.appendAllocatedPage(branch_bytes);
    try ctx.appendObsoletePage(branch_page_bytes);
    return .{ .replaced = .{
        .page_id = page_id,
        .max_key = branchEntriesMaxKey(next_entries.items),
    } };
}

fn collectUpdatedBranchEntries(
    entries: *std.ArrayList(page.BranchEntry),
    branch_page: page.BranchPage,
    allocator: std.mem.Allocator,
    child_index: u16,
    child_result: PutResult,
) !void {
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const existing = try branch_page.entry(index);
        if (index == child_index) {
            switch (child_result) {
                .one => |child| try appendBranchEntry(entries, allocator, child.max_key, child.page_id),
                .split => |children| {
                    try appendBranchEntry(entries, allocator, children.left.max_key, children.left.page_id);
                    try appendBranchEntry(entries, allocator, children.right.max_key, children.right.page_id);
                },
            }
        } else {
            try appendBranchEntry(entries, allocator, existing.key, existing.child_page_id);
        }
    }
}

fn collectDeletedBranchEntries(
    entries: *std.ArrayList(page.BranchEntry),
    branch_page: page.BranchPage,
    allocator: std.mem.Allocator,
    child_index: u16,
    child_step: DeleteStep,
) !void {
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const existing = try branch_page.entry(index);
        if (index == child_index) {
            switch (child_step) {
                .unchanged => unreachable,
                .replaced => |child| try appendBranchEntry(entries, allocator, child.max_key, child.page_id),
                .removed => {},
            }
        } else {
            try appendBranchEntry(entries, allocator, existing.key, existing.child_page_id);
        }
    }
}

fn splitLeafPut(ctx: *WriteContext, leaf_order: u8, entries: []const page.LeafEntry) anyerror!PutResult {
    const split_pages = try splitLeafEntries(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        placeholderPageId(),
        leaf_order,
        entries,
    );

    const left_id = try ctx.appendAllocatedPage(split_pages.left_page);
    const right_id = try ctx.appendAllocatedPage(split_pages.right_page);

    return .{ .split = .{
        .left = .{ .page_id = left_id, .max_key = split_pages.left_max_key },
        .right = .{ .page_id = right_id, .max_key = split_pages.right_max_key },
    } };
}

fn splitBranchPut(ctx: *WriteContext, branch_order: u8, entries: []const page.BranchEntry) anyerror!PutResult {
    const split_pages = try splitBranchEntries(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        placeholderPageId(),
        branch_order,
        entries,
    );

    const left_id = try ctx.appendAllocatedPage(split_pages.left_page);
    const right_id = try ctx.appendAllocatedPage(split_pages.right_page);

    return .{ .split = .{
        .left = .{ .page_id = left_id, .max_key = split_pages.left_max_key },
        .right = .{ .page_id = right_id, .max_key = split_pages.right_max_key },
    } };
}

fn splitLeafEntries(
    allocator: std.mem.Allocator,
    page_size: u32,
    left_id: u64,
    right_id: u64,
    leaf_order: u8,
    entries: []const page.LeafEntry,
) !SplitLeafPages {
    if (entries.len < 2) return TreeWriteError.KeyValueTooLarge;

    const midpoint = entries.len / 2;
    var distance: usize = 0;
    while (distance < entries.len) : (distance += 1) {
        if (midpoint >= distance) {
            if (try trySplitLeafAt(
                allocator,
                page_size,
                left_id,
                right_id,
                leaf_order,
                entries,
                midpoint - distance,
            )) |split_pages| return split_pages;
        }

        const right_candidate = midpoint + distance + 1;
        if (right_candidate < entries.len) {
            if (try trySplitLeafAt(
                allocator,
                page_size,
                left_id,
                right_id,
                leaf_order,
                entries,
                right_candidate,
            )) |split_pages| return split_pages;
        }
    }

    return TreeWriteError.PageOverflowNoValidSplit;
}

fn trySplitLeafAt(
    allocator: std.mem.Allocator,
    page_size: u32,
    left_id: u64,
    right_id: u64,
    leaf_order: u8,
    entries: []const page.LeafEntry,
    split_index: usize,
) !?SplitLeafPages {
    if (split_index == 0 or split_index >= entries.len) return null;

    const left_entries = entries[0..split_index];
    const right_entries = entries[split_index..];

    const left_page = encodeLeafPageAlloc(
        allocator,
        page_size,
        left_id,
        leaf_order,
        left_entries,
    ) catch |err| switch (err) {
        error.PageFull => return null,
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
            return null;
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

fn splitBranchEntries(
    allocator: std.mem.Allocator,
    page_size: u32,
    left_id: u64,
    right_id: u64,
    branch_order: u8,
    entries: []const page.BranchEntry,
) !SplitBranchPages {
    if (entries.len < 2) return TreeWriteError.BranchEntryTooLarge;

    const midpoint = entries.len / 2;
    var distance: usize = 0;
    while (distance < entries.len) : (distance += 1) {
        if (midpoint >= distance) {
            if (try trySplitBranchAt(
                allocator,
                page_size,
                left_id,
                right_id,
                branch_order,
                entries,
                midpoint - distance,
            )) |split_pages| return split_pages;
        }

        const right_candidate = midpoint + distance + 1;
        if (right_candidate < entries.len) {
            if (try trySplitBranchAt(
                allocator,
                page_size,
                left_id,
                right_id,
                branch_order,
                entries,
                right_candidate,
            )) |split_pages| return split_pages;
        }
    }

    return TreeWriteError.PageOverflowNoValidSplit;
}

fn trySplitBranchAt(
    allocator: std.mem.Allocator,
    page_size: u32,
    left_id: u64,
    right_id: u64,
    branch_order: u8,
    entries: []const page.BranchEntry,
    split_index: usize,
) !?SplitBranchPages {
    if (split_index == 0 or split_index >= entries.len) return null;

    const left_entries = entries[0..split_index];
    const right_entries = entries[split_index..];

    const left_page = encodeBranchPageAlloc(
        allocator,
        page_size,
        left_id,
        branch_order,
        left_entries,
    ) catch |err| switch (err) {
        error.PageFull => return null,
        else => return err,
    };

    const right_page = encodeBranchPageAlloc(
        allocator,
        page_size,
        right_id,
        branch_order,
        right_entries,
    ) catch |err| switch (err) {
        error.PageFull => {
            allocator.free(left_page);
            return null;
        },
        else => {
            allocator.free(left_page);
            return err;
        },
    };

    return .{
        .left_page = left_page,
        .right_page = right_page,
        .left_max_key = branchEntriesMaxKey(left_entries),
        .right_max_key = branchEntriesMaxKey(right_entries),
    };
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

fn collectDeletedLeafEntries(
    entries: *std.ArrayList(page.LeafEntry),
    leaf_page: page.LeafPage,
    allocator: std.mem.Allocator,
    key: []const u8,
) !bool {
    var deleted = false;
    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const existing = try leaf_page.entry(index);
        switch (std.mem.order(u8, existing.key, key)) {
            .lt => try appendLeafEntry(entries, allocator, existing.key, existing.value, existing.flags),
            .eq => deleted = true,
            .gt => try appendLeafEntry(entries, allocator, existing.key, existing.value, existing.flags),
        }
    }

    return deleted;
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

fn appendBranchEntry(
    entries: *std.ArrayList(page.BranchEntry),
    allocator: std.mem.Allocator,
    key: []const u8,
    child_page_id: u64,
) !void {
    try entries.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .child_page_id = child_page_id,
    });
}

fn encodeLeafPageAlloc(
    allocator: std.mem.Allocator,
    page_size: u32,
    page_id: u64,
    order: u8,
    entries: []const page.LeafEntry,
) ![]u8 {
    const span_size = try page.spanSize(page_size, order);
    const page_bytes = try allocator.alloc(u8, span_size);
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
    const span_size = try page.spanSize(page_size, order);
    const page_bytes = try allocator.alloc(u8, span_size);
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

fn encodeSingleLeafPageBestFitAlloc(
    allocator: std.mem.Allocator,
    page_size: u32,
    page_id: u64,
    min_order: u8,
    entries: []const page.LeafEntry,
) ![]u8 {
    std.debug.assert(entries.len == 1);

    const max_order = try page.maxOrderForSpanSize(page_size, std.math.maxInt(u16));
    var order = min_order;
    while (order <= max_order) : (order += 1) {
        const leaf_bytes = encodeLeafPageAlloc(
            allocator,
            page_size,
            page_id,
            order,
            entries,
        ) catch |err| switch (err) {
            error.PageFull => continue,
            else => return err,
        };

        return leaf_bytes;
    }

    return TreeWriteError.KeyValueTooLarge;
}

fn allocateEmptyLeafPageAlloc(allocator: std.mem.Allocator, page_size: u32) ![]u8 {
    const page_bytes = try allocator.alloc(u8, page_size);
    errdefer allocator.free(page_bytes);
    @memset(page_bytes, 0);

    try page.LeafPage.init(page_bytes, .{
        .page_id = placeholderPageId(),
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    });
    return page_bytes;
}

fn collapseSingleChildBranchRootIfNeeded(ctx: *WriteContext, root_page_id: u64) !u64 {
    const root_page_ref = try ctx.readAvailablePage(ctx.allocator, root_page_id);
    defer root_page_ref.deinit(ctx.allocator);

    const root_header = try page.decodeHeader(root_page_ref.bytes());
    if (root_header.page_type != .branch) return root_page_id;

    const branch_page = try page.BranchPage.validate(root_page_ref.bytes());
    if (branch_page.count() != 1) return root_page_id;

    const only_entry = try branch_page.entry(0);
    if (ctx.isAllocatedPage(root_page_id)) {
        try ctx.discardAllocatedPage(root_page_id);
    }
    return only_entry.child_page_id;
}

fn maybeMergeBranchChildren(
    ctx: *WriteContext,
    entries: *std.ArrayList(page.BranchEntry),
    affected_index: *usize,
) !void {
    if (entries.items.len < 2) return;

    if (affected_index.* > 0) {
        if (try tryMergeBranchChildrenAt(ctx, entries, affected_index.* - 1)) {
            affected_index.* -= 1;
            return;
        }
    }

    if (affected_index.* + 1 < entries.items.len) {
        _ = try tryMergeBranchChildrenAt(ctx, entries, affected_index.*);
    }
}

fn tryMergeBranchChildrenAt(ctx: *WriteContext, entries: *std.ArrayList(page.BranchEntry), left_index: usize) !bool {
    const right_index = left_index + 1;
    if (right_index >= entries.items.len) return false;

    const left_entry = entries.items[left_index];
    const right_entry = entries.items[right_index];

    const left_page_ref = try ctx.readAvailablePage(ctx.allocator, left_entry.child_page_id);
    defer left_page_ref.deinit(ctx.allocator);
    const right_page_ref = try ctx.readAvailablePage(ctx.allocator, right_entry.child_page_id);
    defer right_page_ref.deinit(ctx.allocator);

    const left_header = try page.decodeHeader(left_page_ref.bytes());
    const right_header = try page.decodeHeader(right_page_ref.bytes());
    if (left_header.page_type != right_header.page_type) return false;

    const merged_child = switch (left_header.page_type) {
        .leaf => try tryMergeLeafChildren(
            ctx,
            left_entry.child_page_id,
            right_entry.child_page_id,
            left_page_ref.bytes(),
            right_page_ref.bytes(),
        ),
        .branch => try tryMergeBranchChildrenPages(
            ctx,
            left_entry.child_page_id,
            right_entry.child_page_id,
            left_page_ref.bytes(),
            right_page_ref.bytes(),
        ),
        else => return false,
    };

    const merged = merged_child orelse return false;
    entries.items[left_index] = .{
        .key = merged.max_key,
        .child_page_id = merged.page_id,
    };
    _ = entries.orderedRemove(right_index);
    return true;
}

fn tryMergeLeafChildren(
    ctx: *WriteContext,
    left_page_id: u64,
    right_page_id: u64,
    left_page_bytes: []const u8,
    right_page_bytes: []const u8,
) !?ChildRef {
    const left_leaf = try page.LeafPage.validate(left_page_bytes);
    const right_leaf = try page.LeafPage.validate(right_page_bytes);

    var merged_entries = std.ArrayList(page.LeafEntry).empty;
    try appendLeafPageEntries(&merged_entries, left_leaf, ctx.temp_allocator);
    try appendLeafPageEntries(&merged_entries, right_leaf, ctx.temp_allocator);

    const merged_order = @max(left_leaf.header.order, right_leaf.header.order);
    const merged_bytes = encodeLeafPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        merged_order,
        merged_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => return null,
        else => return err,
    };

    const merged_page_id = try ctx.appendAllocatedPage(merged_bytes);
    try retireMergedChildInput(ctx, left_page_id, left_page_bytes);
    try retireMergedChildInput(ctx, right_page_id, right_page_bytes);
    return .{
        .page_id = merged_page_id,
        .max_key = maxKey(merged_entries.items),
    };
}

fn tryMergeBranchChildrenPages(
    ctx: *WriteContext,
    left_page_id: u64,
    right_page_id: u64,
    left_page_bytes: []const u8,
    right_page_bytes: []const u8,
) !?ChildRef {
    const left_branch = try page.BranchPage.validate(left_page_bytes);
    const right_branch = try page.BranchPage.validate(right_page_bytes);

    var merged_entries = std.ArrayList(page.BranchEntry).empty;
    try appendBranchPageEntries(&merged_entries, left_branch, ctx.temp_allocator);
    try appendBranchPageEntries(&merged_entries, right_branch, ctx.temp_allocator);

    const merged_order = @max(left_branch.header.order, right_branch.header.order);
    const merged_bytes = encodeBranchPageAlloc(
        ctx.allocator,
        ctx.page_size,
        placeholderPageId(),
        merged_order,
        merged_entries.items,
    ) catch |err| switch (err) {
        error.PageFull => return null,
        else => return err,
    };

    const merged_page_id = try ctx.appendAllocatedPage(merged_bytes);
    try retireMergedChildInput(ctx, left_page_id, left_page_bytes);
    try retireMergedChildInput(ctx, right_page_id, right_page_bytes);
    return .{
        .page_id = merged_page_id,
        .max_key = branchEntriesMaxKey(merged_entries.items),
    };
}

fn retireMergedChildInput(ctx: *WriteContext, page_id: u64, page_bytes: []const u8) !void {
    if (ctx.isAllocatedPage(page_id)) {
        try ctx.discardAllocatedPage(page_id);
        return;
    }

    try ctx.appendObsoletePage(page_bytes);
}

fn appendLeafPageEntries(entries: *std.ArrayList(page.LeafEntry), leaf_page: page.LeafPage, allocator: std.mem.Allocator) !void {
    var index: u16 = 0;
    while (index < leaf_page.count()) : (index += 1) {
        const entry = try leaf_page.entry(index);
        try appendLeafEntry(entries, allocator, entry.key, entry.value, entry.flags);
    }
}

fn appendBranchPageEntries(entries: *std.ArrayList(page.BranchEntry), branch_page: page.BranchPage, allocator: std.mem.Allocator) !void {
    var index: u16 = 0;
    while (index < branch_page.count()) : (index += 1) {
        const entry = try branch_page.entry(index);
        try appendBranchEntry(entries, allocator, entry.key, entry.child_page_id);
    }
}

fn maxKey(entries: []const page.LeafEntry) []const u8 {
    std.debug.assert(entries.len > 0);
    return entries[entries.len - 1].key;
}

fn placeholderPageId() u64 {
    return page_allocator_mod.first_data_page_id;
}

fn branchEntriesMaxKey(entries: []const page.BranchEntry) []const u8 {
    std.debug.assert(entries.len > 0);
    return entries[entries.len - 1].key;
}

// ======tests======

// Test helpers build on-disk fixtures that exercise the real `DB.open` and
// `DB.get` path without mixing fixture details into the production API.
fn tempFilePath(buf: []u8, tmp_dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.realPath(std.testing.io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_path_len];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name });
}

fn writePageObject(file: *std.Io.File, io: std.Io, base_page_size: u32, page_id: u64, page_bytes: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(try std.math.mul(u64, page_id, base_page_size));
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

    var high_water_mark: u64 = 1;
    for (pages) |page_bytes| {
        high_water_mark += try page.spanPageCount((try page.decodeHeader(page_bytes)).order);
    }
    const meta0_page = try encodeMetaPage(std.testing.allocator, page_size, root_page_id, high_water_mark);
    defer std.testing.allocator.free(meta0_page);
    const meta1_page = try encodeMetaPage(std.testing.allocator, page_size, root_page_id, high_water_mark);
    defer std.testing.allocator.free(meta1_page);

    try writePageObject(&file, io, page_size, 0, meta0_page);
    try writePageObject(&file, io, page_size, 1, meta1_page);

    var next_page_id: u64 = 2;
    for (pages) |page_bytes| {
        try writePageObject(&file, io, page_size, next_page_id, page_bytes);
        next_page_id += try page.spanPageCount((try page.decodeHeader(page_bytes)).order);
    }
}

fn openTestDb(tmp: std.testing.TmpDir, file_name: []const u8, page_size: u32, root_page_id: u64, pages: []const []const u8) !*db_mod.DB {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, file_name);
    try createDatabaseFile(path, page_size, root_page_id, pages);
    return db_mod.open(std.testing.allocator, path);
}

fn openEmptyDb(tmp: std.testing.TmpDir, file_name: []const u8) !*db_mod.DB {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempFilePath(&path_buf, tmp.dir, file_name);
    return db_mod.open(std.testing.allocator, path);
}

fn generatedKey(buf: []u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "k{d:0>4}", .{index});
}

fn appendSnapshotPathPages(
    out: *std.ArrayList(reclaim.ReleasedPage),
    db: *db_mod.DB,
    allocator: std.mem.Allocator,
    snapshot: ReadSnapshot,
    key: []const u8,
) !void {
    const snapshot_source = SnapshotSource.init(db, snapshot, db.file);
    var page_id = snapshot.root_page_id;

    while (true) {
        const page_bytes = try readTreePageSnapshot(&snapshot_source, allocator, page_id);
        defer allocator.free(page_bytes);

        const header = try page.decodeHeader(page_bytes);
        try out.append(allocator, .{
            .page_id = header.page_id,
            .order = header.order,
        });

        switch (header.page_type) {
            .branch => {
                const branch_page = try page.BranchPage.validate(page_bytes);
                page_id = (try selectChildForLookup(branch_page, key)) orelse return error.CorruptTreePath;
            },
            .leaf => return,
            else => return error.UnexpectedPageType,
        }
    }
}

fn expectReleasedPagesMatchRewrittenPath(
    obsolete_pages: []const reclaim.ReleasedPage,
    snapshot_path: []const reclaim.ReleasedPage,
) !void {
    try std.testing.expectEqual(snapshot_path.len, obsolete_pages.len);

    var index: usize = 0;
    while (index < obsolete_pages.len) : (index += 1) {
        const expected = snapshot_path[snapshot_path.len - 1 - index];
        try std.testing.expectEqual(expected.page_id, obsolete_pages[index].page_id);
        try std.testing.expectEqual(expected.order, obsolete_pages[index].order);
    }
}

fn expectReleasedPagesContainPage(obsolete_pages: []const reclaim.ReleasedPage, page_id: u64) !void {
    for (obsolete_pages) |released_page| {
        if (released_page.page_id == page_id) return;
    }
    return error.ExpectedReleasedPageMissing;
}

fn snapshotPageReader(db: *db_mod.DB) SnapshotPageReader {
    return SnapshotPageReader.init(db, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    });
}

fn expectCursorRecord(record: CursorRecord, expected_key: []const u8, expected_value: []const u8, expected_flags: u32) !void {
    try std.testing.expectEqualSlices(u8, expected_key, record.key);
    try std.testing.expectEqualSlices(u8, expected_value, record.value);
    try std.testing.expectEqual(expected_flags, record.flags);
}

test "cursor record deinit is idempotent" {
    var record = CursorRecord{
        .key = try std.testing.allocator.dupe(u8, "alpha"),
        .value = try std.testing.allocator.dupe(u8, "one"),
        .flags = 7,
    };

    record.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), record.key.len);
    try std.testing.expectEqual(@as(usize, 0), record.value.len);
    try std.testing.expectEqual(@as(u32, 0), record.flags);

    record.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), record.key.len);
    try std.testing.expectEqual(@as(usize, 0), record.value.len);
}

test "branch child lookup keeps lower bound semantics" {
    var branch_page_bytes = [_]u8{0} ** test_page_size;
    const branch_page = try page.BranchPage.encodeInto(branch_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .child_page_id = 3 },
        .{ .key = "gamma", .child_page_id = 4 },
        .{ .key = "omega", .child_page_id = 5 },
    });

    try std.testing.expectEqual(@as(?u16, 1), try selectChildIndexForLookup(branch_page, "gamma"));
    try std.testing.expectEqual(@as(?u16, 1), try selectChildIndexForLookup(branch_page, "delta"));
    try std.testing.expectEqual(@as(?u16, null), try selectChildIndexForLookup(branch_page, "zeta"));
}

test "leaf lower bound lookup keeps lower bound semantics" {
    var leaf_page_bytes = [_]u8{0} ** test_page_size;
    const leaf_page = try page.LeafPage.encodeInto(leaf_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "gamma", .value = "three", .flags = 0 },
        .{ .key = "omega", .value = "last", .flags = 0 },
    });

    try std.testing.expectEqual(@as(?u16, 1), try findLowerBoundIndex(leaf_page, "gamma"));
    try std.testing.expectEqual(@as(?u16, 1), try findLowerBoundIndex(leaf_page, "beta"));
    try std.testing.expectEqual(@as(?u16, null), try findLowerBoundIndex(leaf_page, "zeta"));
}

test "cursor first returns null from an empty root leaf" {
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

    const db = try openTestDb(tmp, "cursor-empty-root.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    const first = try cursor.first(std.testing.allocator);
    try std.testing.expect(first == null);
    const next = try cursor.next(std.testing.allocator);
    try std.testing.expect(next == null);
}

test "cursor first returns the smallest record with flags" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 3 },
        .{ .key = "beta", .value = "two", .flags = 4 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "cursor-first-leaf.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alpha", "one", 3);
}

test "cursor next rejects unpositioned cursors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-unpositioned.db");
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    try std.testing.expectError(error.CursorUnpositioned, cursor.next(std.testing.allocator));
}

test "cursor rejects use after the owning read transaction closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-closed-read-tx.db");
    defer db.close();

    var read_tx = try db.beginRead();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    read_tx.deinit();

    try std.testing.expectError(error.CursorUnpositioned, cursor.first(std.testing.allocator));
    try std.testing.expectError(error.CursorUnpositioned, cursor.seek(std.testing.allocator, "alpha"));
    try std.testing.expectError(error.CursorUnpositioned, cursor.next(std.testing.allocator));
}

test "cursor seek supports exact gap and reset semantics" {
    const page_size = test_page_size;
    var root_page_bytes = [_]u8{0} ** page_size;
    _ = try page.LeafPage.encodeInto(root_page_bytes[0..], .{
        .page_id = 2,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "gamma", .value = "three", .flags = 1 },
        .{ .key = "omega", .value = "last", .flags = 2 },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openTestDb(tmp, "cursor-seek-reset.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var exact = (try cursor.seek(std.testing.allocator, "gamma")).?;
    defer exact.deinit(std.testing.allocator);
    try expectCursorRecord(exact, "gamma", "three", 1);

    var gap = (try cursor.seek(std.testing.allocator, "beta")).?;
    defer gap.deinit(std.testing.allocator);
    try expectCursorRecord(gap, "gamma", "three", 1);

    var tail = (try cursor.next(std.testing.allocator)).?;
    defer tail.deinit(std.testing.allocator);
    try expectCursorRecord(tail, "omega", "last", 2);

    var reset = (try cursor.first(std.testing.allocator)).?;
    defer reset.deinit(std.testing.allocator);
    try expectCursorRecord(reset, "alpha", "one", 0);
}

test "cursor seek past the largest key enters eof" {
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

    const db = try openTestDb(tmp, "cursor-seek-eof.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    const miss = try cursor.seek(std.testing.allocator, "omega");
    try std.testing.expect(miss == null);
    const next = try cursor.next(std.testing.allocator);
    try std.testing.expect(next == null);
}

test "cursor next traverses split leaves in key order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-split-leaves.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 24) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "k0000", value_buf[0..], 0);

    var seen: usize = 1;
    while (try cursor.next(std.testing.allocator)) |record| {
        defer {
            var owned = record;
            owned.deinit(std.testing.allocator);
        }

        var expected_key_buf: [5]u8 = undefined;
        const expected_key = try generatedKey(&expected_key_buf, seen);
        try expectCursorRecord(record, expected_key, value_buf[0..], 0);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 24), seen);
}

test "cursor next traverses a multi-level tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-multi-level.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 261) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var count: usize = 0;
    while (try (if (count == 0) cursor.first(std.testing.allocator) else cursor.next(std.testing.allocator))) |record| {
        defer {
            var owned = record;
            owned.deinit(std.testing.allocator);
        }

        var expected_key_buf: [5]u8 = undefined;
        const expected_key = try generatedKey(&expected_key_buf, count);
        try expectCursorRecord(record, expected_key, value_buf[0..], 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 261), count);
}

test "cursor snapshot remains stable after a later write commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-snapshot.db");
    defer db.close();

    try db.put("alpha", "one");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "alpha", "one", 0);

    try db.put("beta", "two");

    const next = try cursor.next(std.testing.allocator);
    try std.testing.expect(next == null);
    const missed_seek = try cursor.seek(std.testing.allocator, "beta");
    try std.testing.expect(missed_seek == null);
}

test "cursor traverses higher-order leaf pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-higher-order-leaf.db");
    defer db.close();

    var large_value = [_]u8{'L'} ** 7000;
    try db.put("large", large_value[0..]);

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "large", large_value[0..], 0);
}

test "cursor traverses the latest snapshot after root collapse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "cursor-root-collapse.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 24) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }
    try db.delete("k0000");

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    var first = (try cursor.first(std.testing.allocator)).?;
    defer first.deinit(std.testing.allocator);
    try expectCursorRecord(first, "k0001", value_buf[0..], 0);

    var seen: usize = 1;
    while (try cursor.next(std.testing.allocator)) |record| {
        defer {
            var owned = record;
            owned.deinit(std.testing.allocator);
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 23), seen);
}

test "cursor first propagates non tree root type errors" {
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

    const db = try openTestDb(tmp, "cursor-bad-root-type.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    try std.testing.expectError(error.UnexpectedPageType, cursor.first(std.testing.allocator));
}

test "cursor first propagates malformed leaf layouts" {
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

    const db = try openTestDb(tmp, "cursor-bad-leaf-layout.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var read_tx = try db.beginRead();
    defer read_tx.deinit();
    var cursor = read_tx.cursor();
    defer cursor.deinit();

    try std.testing.expectError(error.InvalidPageLayout, cursor.first(std.testing.allocator));
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

test "lookup returns null when the key is beyond the root upper bound" {
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

    const value = try lookup(db, std.testing.allocator, "omega");
    defer if (value) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(value == null);
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

test "writePut records split children from non adjacent free blocks" {
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

    const db = try openTestDb(tmp, "write-put-non-adjacent-split.db", page_size, 2, &.{root_page_bytes[0..]});
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 23) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>4}", .{index});
        try db.put(key, value_buf[0..]);
    }

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);
    working_page_allocator.high_water_mark = 52;
    try working_page_allocator.release(db.allocator, 50, 0);
    try working_page_allocator.release(db.allocator, 52, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const write_result = try writePut(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "k0023",
        value_buf[0..],
    );
    var root_page_bytes_written: ?[]const u8 = null;
    for (write_result.new_pages) |pending_page| {
        if (pending_page.page_id == write_result.root_page_id) {
            root_page_bytes_written = pending_page.bytes;
            break;
        }
    }

    const root_page = root_page_bytes_written.?;
    const root_branch = try page.BranchPage.validate(root_page);
    const left_entry = try root_branch.entry(0);
    const right_entry = try root_branch.entry(1);

    try std.testing.expect(left_entry.child_page_id == 50 or left_entry.child_page_id == 52);
    try std.testing.expect(right_entry.child_page_id == 50 or right_entry.child_page_id == 52);
    try std.testing.expect(left_entry.child_page_id != right_entry.child_page_id);
    try std.testing.expect(left_entry.child_page_id + 1 != right_entry.child_page_id);
    try std.testing.expect(right_entry.child_page_id + 1 != left_entry.child_page_id);
}

test "writePut reports released pages for a single leaf update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-put-released-single-leaf.db");
    defer db.close();

    try db.put("alpha", "one");

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "alpha");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const write_result = try writePut(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "alpha",
        "two",
    );
    try std.testing.expectEqual(@as(usize, 1), expected_path.items.len);
    try expectReleasedPagesMatchRewrittenPath(write_result.obsolete_pages, expected_path.items);
}

test "writePut reports released pages when a root leaf split replaces the old root page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-put-released-root-split.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 23) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "k0023");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const write_result = try writePut(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "k0023",
        value_buf[0..],
    );
    try std.testing.expectEqual(@as(usize, 1), expected_path.items.len);
    try std.testing.expect(write_result.root_page_id != expected_path.items[0].page_id);
    try expectReleasedPagesMatchRewrittenPath(write_result.obsolete_pages, expected_path.items);
}

test "writePut reports released pages across a multi-level rewritten path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-put-released-multi-level.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 261) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "k0238");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const write_result = try writePut(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "k0238",
        value_buf[0..],
    );
    try std.testing.expect(expected_path.items.len >= 2);
    try expectReleasedPagesMatchRewrittenPath(write_result.obsolete_pages, expected_path.items);
}

test "writePut records higher-order released pages for large root leaf replacements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-put-released-higher-order.db");
    defer db.close();

    var initial_value = [_]u8{'L'} ** 7000;
    try db.put("large", initial_value[0..]);

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "large");

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const root_header = try page.decodeHeader(root_page);

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var next_value = [_]u8{'M'} ** 7000;
    var page_reader = snapshotPageReader(db);
    const write_result = try writePut(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "large",
        next_value[0..],
    );
    try std.testing.expect(root_header.order > 0);
    try expectReleasedPagesMatchRewrittenPath(write_result.obsolete_pages, expected_path.items);
    try std.testing.expectEqual(root_header.order, write_result.obsolete_pages[0].order);
}

test "writeDelete returns unchanged when the key is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-delete-miss.db");
    defer db.close();

    try db.put("alpha", "one");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const delete_mutation = try writeDelete(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "missing",
    );
    try std.testing.expect(delete_mutation == .unchanged);
}

test "writeDelete reports released pages for a single leaf delete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-delete-single-leaf.db");
    defer db.close();

    try db.put("alpha", "one");
    try db.put("beta", "two");

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "alpha");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const delete_mutation = try writeDelete(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "alpha",
    );
    try std.testing.expect(delete_mutation == .changed);
    try expectReleasedPagesMatchRewrittenPath(delete_mutation.changed.obsolete_pages, expected_path.items);
}

test "writeDelete records the merged sibling as an obsolete committed page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db = try openEmptyDb(tmp, "write-delete-merge-sibling.db");
    defer db.close();

    var value_buf = [_]u8{'x'} ** 160;
    var index: usize = 0;
    while (index < 24) : (index += 1) {
        var key_buf: [5]u8 = undefined;
        const key = try generatedKey(&key_buf, index);
        try db.put(key, value_buf[0..]);
    }

    const root_page = try db.readPageAlloc(std.testing.allocator, db.root_page_id);
    defer std.testing.allocator.free(root_page);
    const root_branch = try page.BranchPage.validate(root_page);
    try std.testing.expectEqual(@as(u16, 2), root_branch.count());
    const right_child = try root_branch.entry(1);

    var expected_path = std.ArrayList(reclaim.ReleasedPage).empty;
    defer expected_path.deinit(std.testing.allocator);
    try appendSnapshotPathPages(&expected_path, db, std.testing.allocator, .{
        .root_page_id = db.root_page_id,
        .high_water_mark = db.high_water_mark,
    }, "k0000");

    var working_page_allocator = try db.page_allocator.clone(db.allocator);
    defer working_page_allocator.deinit(db.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var page_reader = snapshotPageReader(db);
    const delete_mutation = try writeDelete(
        page_reader.pageReader(),
        arena.allocator(),
        db.allocator,
        db.page_size,
        &working_page_allocator,
        db.root_page_id,
        "k0000",
    );
    try std.testing.expect(delete_mutation == .changed);
    try std.testing.expectEqual(expected_path.items.len + 1, delete_mutation.changed.obsolete_pages.len);
    try expectReleasedPagesContainPage(delete_mutation.changed.obsolete_pages, right_child.child_page_id);
}
