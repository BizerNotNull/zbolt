const std = @import("std");
const page = @import("../page.zig");

const child_page_id_offset: usize = 0;
const key_len_offset: usize = 8;
const payload_offset_offset: usize = 10;
const slot_size: usize = 12;

pub const Error = page.Error || page.LayoutError;

pub const Entry = struct {
    key: []const u8,
    child_page_id: u64,
};

pub const EntryView = struct {
    key: []const u8,
    child_page_id: u64,
};

pub const BranchPage = struct {
    bytes: []const u8,
    header: page.Header,
    data_header: page.DataHeader,

    pub fn init(bytes: []u8, header: page.Header) Error!void {
        var normalized = header;
        normalized.page_type = .branch;
        normalized.count = 0;

        try page.encodeHeader(bytes, normalized);
        try page.encodeDataHeader(bytes, .{
            .lower = try page.checkedCastU16(page.data_header_size),
            .upper = try page.checkedCastU16(bytes.len),
            .flags = 0,
        });
    }

    pub fn encodeInto(bytes: []u8, header: page.Header, entries: []const Entry) Error!BranchPage {
        try init(bytes, header);
        try assertSorted(entries);

        var upper = bytes.len;
        var index: usize = 0;
        while (index < entries.len) : (index += 1) {
            const item = entries[index];
            if (item.key.len > upper) return error.PageFull;
            upper -= item.key.len;

            const slot_start = try page.checkedAdd(page.data_header_size, index * slot_size);
            const slot_end = try page.checkedAdd(slot_start, slot_size);
            if (slot_end > upper) return error.PageFull;

            std.mem.copyForwards(u8, bytes[upper .. upper + item.key.len], item.key);
            writeSlot(bytes[slot_start..slot_end], .{
                .child_page_id = item.child_page_id,
                .key_len = try page.checkedCastU16(item.key.len),
                .payload_offset = try page.checkedCastU16(upper),
            });
        }

        var normalized = header;
        normalized.page_type = .branch;
        normalized.count = std.math.cast(u16, entries.len) orelse return error.PageFull;
        try page.encodeHeader(bytes, normalized);
        try page.encodeDataHeader(bytes, .{
            .lower = try page.checkedCastU16(page.data_header_size + entries.len * slot_size),
            .upper = try page.checkedCastU16(upper),
            .flags = 0,
        });

        return try validate(bytes);
    }

    pub fn validate(bytes: []const u8) Error!BranchPage {
        try page.ensureDataHeaderCapacity(bytes);

        const header = try page.decodeHeader(bytes);
        try page.validatePageType(header.page_type, .branch);

        const data_header = try page.decodeDataHeader(bytes);
        try page.validateDataBounds(bytes.len, data_header.lower, data_header.upper);

        const expected_lower = try page.checkedAdd(page.data_header_size, @as(usize, header.count) * slot_size);
        if (data_header.lower != expected_lower) return error.InvalidPageLayout;

        var branch_page = BranchPage{
            .bytes = bytes,
            .header = header,
            .data_header = data_header,
        };

        var previous_key: ?[]const u8 = null;
        var index: u16 = 0;
        while (index < header.count) : (index += 1) {
            const item = try branch_page.entry(index);
            if (previous_key) |prev| {
                if (std.mem.order(u8, prev, item.key) != .lt) return error.EntriesNotSorted;
            }
            previous_key = item.key;
        }

        return branch_page;
    }

    pub fn entry(self: BranchPage, index: u16) Error!EntryView {
        try page.validateEntryIndex(self.header.count, index);

        const slot_start = try page.checkedAdd(page.data_header_size, @as(usize, index) * slot_size);
        const slot_end = try page.checkedAdd(slot_start, slot_size);
        const slot = readSlot(self.bytes[slot_start..slot_end]);

        if (slot.payload_offset < self.data_header.upper) return error.InvalidPageLayout;
        try page.validateRange(self.bytes.len, slot.payload_offset, slot.key_len);

        return .{
            .key = self.bytes[slot.payload_offset .. slot.payload_offset + slot.key_len],
            .child_page_id = slot.child_page_id,
        };
    }

    pub fn count(self: BranchPage) u16 {
        return self.header.count;
    }
};

const Slot = struct {
    child_page_id: u64,
    key_len: u16,
    payload_offset: u16,
};

fn assertSorted(entries: []const Entry) page.LayoutError!void {
    var index: usize = 1;
    while (index < entries.len) : (index += 1) {
        // We intentionally store each child with its upper-bound key so branch lookup can
        // stay "first key >= target" without a special leftmost-child side channel.
        if (std.mem.order(u8, entries[index - 1].key, entries[index].key) != .lt) {
            return error.EntriesNotSorted;
        }
    }
}

fn writeSlot(bytes: []u8, slot: Slot) void {
    page.writeInt(u64, bytes, child_page_id_offset, slot.child_page_id);
    page.writeInt(u16, bytes, key_len_offset, slot.key_len);
    page.writeInt(u16, bytes, payload_offset_offset, slot.payload_offset);
}

fn readSlot(bytes: []const u8) Slot {
    return .{
        .child_page_id = page.readInt(u64, bytes, child_page_id_offset),
        .key_len = page.readInt(u16, bytes, key_len_offset),
        .payload_offset = page.readInt(u16, bytes, payload_offset_offset),
    };
}

// ======tests=====

test "init creates a valid empty branch page" {
    var bytes = [_]u8{0} ** 128;

    try BranchPage.init(bytes[0..], .{
        .page_id = 4,
        .page_type = .leaf,
        .count = 1,
        .order = 0,
    });

    const branch_page = try BranchPage.validate(bytes[0..]);
    try std.testing.expectEqual(@as(u16, 0), branch_page.count());
    try std.testing.expectEqual(@as(u16, page.data_header_size), branch_page.data_header.lower);
    try std.testing.expectEqual(@as(u16, bytes.len), branch_page.data_header.upper);
}

test "encodeInto round trips multiple branch entries" {
    var bytes = [_]u8{0} ** 128;

    const branch_page = try BranchPage.encodeInto(bytes[0..], .{
        .page_id = 5,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .child_page_id = 11 },
        .{ .key = "gamma", .child_page_id = 15 },
    });

    const first = try branch_page.entry(0);
    const second = try branch_page.entry(1);
    try std.testing.expectEqualSlices(u8, "alpha", first.key);
    try std.testing.expectEqual(@as(u64, 11), first.child_page_id);
    try std.testing.expectEqualSlices(u8, "gamma", second.key);
    try std.testing.expectEqual(@as(u64, 15), second.child_page_id);
}

test "encodeInto rejects unsorted branch entries" {
    var bytes = [_]u8{0} ** 128;

    try std.testing.expectError(error.EntriesNotSorted, BranchPage.encodeInto(bytes[0..], .{
        .page_id = 1,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "zeta", .child_page_id = 3 },
        .{ .key = "beta", .child_page_id = 4 },
    }));
}

test "validate rejects malformed bounds" {
    var bytes = [_]u8{0} ** 128;
    try BranchPage.init(bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    });

    page.writeInt(u16, bytes[0..], page.header_size, 40);
    page.writeInt(u16, bytes[0..], page.header_size + 2, 32);

    try std.testing.expectError(error.InvalidPageLayout, BranchPage.validate(bytes[0..]));
}
