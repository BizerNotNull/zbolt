const std = @import("std");
const page = @import("../page.zig");

const slot_size: usize = 12;
const flags_offset: usize = 0;
const key_len_offset: usize = 4;
const value_len_offset: usize = 6;
const payload_offset_offset: usize = 8;
const reserved_offset: usize = 10;

pub const Error = page.Error || page.LayoutError;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    flags: u32,
};

pub const EntryView = struct {
    key: []const u8,
    value: []const u8,
    flags: u32,
};

pub const LeafPage = struct {
    bytes: []const u8,
    header: page.Header,
    data_header: page.DataHeader,

    pub fn init(bytes: []u8, header: page.Header) Error!void {
        var normalized = header;
        normalized.page_type = .leaf;
        normalized.count = 0;

        try page.encodeHeader(bytes, normalized);
        try page.encodeDataHeader(bytes, .{
            .lower = try page.checkedCastU16(page.data_header_size),
            .upper = try page.checkedCastU16(bytes.len),
            .flags = 0,
        });
    }

    pub fn encodeInto(bytes: []u8, header: page.Header, entries: []const Entry) Error!LeafPage {
        try init(bytes, header);
        try assertSorted(entries);

        var upper = bytes.len;
        var index: usize = 0;
        while (index < entries.len) : (index += 1) {
            const item = entries[index];
            const payload_len = item.key.len + item.value.len;
            if (payload_len > upper) return error.PageFull;
            upper -= payload_len;

            const slot_start = try page.checkedAdd(page.data_header_size, index * slot_size);
            const slot_end = try page.checkedAdd(slot_start, slot_size);
            if (slot_end > upper) return error.PageFull;

            // Payload grows backward from the page tail so small inserts only move the
            // compact slot array in front, not every later value blob.
            std.mem.copyForwards(u8, bytes[upper .. upper + item.key.len], item.key);
            std.mem.copyForwards(u8, bytes[upper + item.key.len .. upper + payload_len], item.value);

            writeSlot(bytes[slot_start..slot_end], .{
                .flags = item.flags,
                .key_len = try page.checkedCastU16(item.key.len),
                .value_len = try page.checkedCastU16(item.value.len),
                .payload_offset = try page.checkedCastU16(upper),
            });
        }

        var normalized = header;
        normalized.page_type = .leaf;
        normalized.count = std.math.cast(u16, entries.len) orelse return error.PageFull;
        try page.encodeHeader(bytes, normalized);
        try page.encodeDataHeader(bytes, .{
            .lower = try page.checkedCastU16(page.data_header_size + entries.len * slot_size),
            .upper = try page.checkedCastU16(upper),
            .flags = 0,
        });

        return try validate(bytes);
    }

    pub fn validate(bytes: []const u8) Error!LeafPage {
        try page.ensureDataHeaderCapacity(bytes);

        const header = try page.decodeHeader(bytes);
        try page.validatePageType(header.page_type, .leaf);

        const data_header = try page.decodeDataHeader(bytes);
        try page.validateDataBounds(bytes.len, data_header.lower, data_header.upper);

        const expected_lower = try page.checkedAdd(page.data_header_size, @as(usize, header.count) * slot_size);
        if (data_header.lower != expected_lower) return error.InvalidPageLayout;

        var leaf_page = LeafPage{
            .bytes = bytes,
            .header = header,
            .data_header = data_header,
        };

        var previous_key: ?[]const u8 = null;
        var index: u16 = 0;
        while (index < header.count) : (index += 1) {
            const item = try leaf_page.entry(index);
            if (previous_key) |prev| {
                if (std.mem.order(u8, prev, item.key) != .lt) return error.EntriesNotSorted;
            }
            previous_key = item.key;
        }

        return leaf_page;
    }

    pub fn entry(self: LeafPage, index: u16) Error!EntryView {
        try page.validateEntryIndex(self.header.count, index);

        const slot_start = try page.checkedAdd(page.data_header_size, @as(usize, index) * slot_size);
        const slot_end = try page.checkedAdd(slot_start, slot_size);
        const slot = readSlot(self.bytes[slot_start..slot_end]);

        if (slot.payload_offset < self.data_header.upper) return error.InvalidPageLayout;

        const key_start = slot.payload_offset;
        const key_end = try page.checkedAdd(key_start, slot.key_len);
        const value_end = try page.checkedAdd(key_end, slot.value_len);

        try page.validateRange(self.bytes.len, key_start, slot.key_len);
        try page.validateRange(self.bytes.len, key_end, slot.value_len);

        // Returned slices borrow directly from the page, so callers must keep the backing
        // page bytes alive while they hold these views.
        return .{
            .key = self.bytes[key_start..key_end],
            .value = self.bytes[key_end..value_end],
            .flags = slot.flags,
        };
    }

    pub fn count(self: LeafPage) u16 {
        return self.header.count;
    }
};

const Slot = struct {
    flags: u32,
    key_len: u16,
    value_len: u16,
    payload_offset: u16,
};

fn assertSorted(entries: []const Entry) page.LayoutError!void {
    var index: usize = 1;
    while (index < entries.len) : (index += 1) {
        if (std.mem.order(u8, entries[index - 1].key, entries[index].key) != .lt) {
            return error.EntriesNotSorted;
        }
    }
}

fn writeSlot(bytes: []u8, slot: Slot) void {
    page.writeInt(u32, bytes, flags_offset, slot.flags);
    page.writeInt(u16, bytes, key_len_offset, slot.key_len);
    page.writeInt(u16, bytes, value_len_offset, slot.value_len);
    page.writeInt(u16, bytes, payload_offset_offset, slot.payload_offset);
    page.writeInt(u16, bytes, reserved_offset, 0);
}

fn readSlot(bytes: []const u8) Slot {
    return .{
        .flags = page.readInt(u32, bytes, flags_offset),
        .key_len = page.readInt(u16, bytes, key_len_offset),
        .value_len = page.readInt(u16, bytes, value_len_offset),
        .payload_offset = page.readInt(u16, bytes, payload_offset_offset),
    };
}

// ======tests=====

test "init creates a valid empty leaf page" {
    var bytes = [_]u8{0} ** 128;

    try LeafPage.init(bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 9,
        .order = 0,
    });

    const leaf_page = try LeafPage.validate(bytes[0..]);
    try std.testing.expectEqual(@as(u16, 0), leaf_page.count());
    try std.testing.expectEqual(@as(u16, page.data_header_size), leaf_page.data_header.lower);
    try std.testing.expectEqual(@as(u16, bytes.len), leaf_page.data_header.upper);
}

test "encodeInto round trips a single kv entry" {
    var bytes = [_]u8{0} ** 128;

    const leaf_page = try LeafPage.encodeInto(bytes[0..], .{
        .page_id = 7,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "a", .value = "1", .flags = 3 },
    });

    const entry = try leaf_page.entry(0);
    try std.testing.expectEqualSlices(u8, "a", entry.key);
    try std.testing.expectEqualSlices(u8, "1", entry.value);
    try std.testing.expectEqual(@as(u32, 3), entry.flags);
}

test "encodeInto round trips multiple kv entries with in-page views" {
    var bytes = [_]u8{0} ** 256;

    const leaf_page = try LeafPage.encodeInto(bytes[0..], .{
        .page_id = 8,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "alpha", .value = "one", .flags = 0 },
        .{ .key = "beta", .value = "two", .flags = 1 },
        .{ .key = "gamma", .value = "three", .flags = 2 },
    });

    const second = try leaf_page.entry(1);
    try std.testing.expectEqualSlices(u8, "beta", second.key);
    try std.testing.expectEqualSlices(u8, "two", second.value);
    try std.testing.expect(@intFromPtr(second.key.ptr) >= @intFromPtr(&bytes[0]));
    try std.testing.expect(@intFromPtr(second.key.ptr) < @intFromPtr(&bytes[bytes.len - 1]) + 1);
}

test "encodeInto rejects unsorted entries" {
    var bytes = [_]u8{0} ** 128;

    try std.testing.expectError(error.EntriesNotSorted, LeafPage.encodeInto(bytes[0..], .{
        .page_id = 1,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "beta", .value = "two", .flags = 0 },
        .{ .key = "alpha", .value = "one", .flags = 0 },
    }));
}

test "encodeInto rejects entries that do not fit into one page" {
    var bytes = [_]u8{0} ** 48;

    try std.testing.expectError(error.PageFull, LeafPage.encodeInto(bytes[0..], .{
        .page_id = 1,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "abcdef", .value = "ghijkl", .flags = 0 },
        .{ .key = "mnopqr", .value = "stuvwx", .flags = 0 },
    }));
}

test "validate rejects wrong page type" {
    var bytes = [_]u8{0} ** 128;
    try page.encodeHeader(bytes[0..], .{
        .page_id = 2,
        .page_type = .branch,
        .count = 0,
        .order = 0,
    });
    try page.encodeDataHeader(bytes[0..], .{
        .lower = page.data_header_size,
        .upper = bytes.len,
        .flags = 0,
    });

    try std.testing.expectError(error.UnexpectedPageType, LeafPage.validate(bytes[0..]));
}

test "validate rejects corrupted slot payload bounds" {
    var bytes = [_]u8{0} ** 128;
    _ = try LeafPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .key = "a", .value = "b", .flags = 0 },
    });

    page.writeInt(u16, bytes[0..], page.data_header_size + payload_offset_offset, 1);

    try std.testing.expectError(error.InvalidPageLayout, LeafPage.validate(bytes[0..]));
}
