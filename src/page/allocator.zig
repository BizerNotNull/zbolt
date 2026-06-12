const std = @import("std");
const page = @import("../page.zig");

const body_header_size: usize = 24;
const version_offset: usize = page.header_size;
const reserved_offset: usize = version_offset + 2;
const total_entries_offset: usize = reserved_offset + 2;
const capacity_entries_offset: usize = total_entries_offset + 4;
const checksum_offset: usize = capacity_entries_offset + 4;
const body_reserved_offset: usize = checksum_offset + 4;
const entries_offset: usize = page.header_size + body_header_size;

const entry_size: usize = 16;
const entry_page_id_offset: usize = 0;
const entry_order_offset: usize = 8;
const entry_reserved_offset: usize = 9;
const entry_reserved_size: usize = 7;

const v2_record_size: usize = 24;
const v2_record_kind_offset: usize = 0;
const v2_record_order_offset: usize = 1;
const v2_record_reserved_offset: usize = 2;
const v2_record_reserved_size: usize = 2;
const v2_record_page_id_offset: usize = 4;
const v2_record_visible_txid_offset: usize = 12;
const v2_record_tail_reserved_offset: usize = 20;
const v2_record_tail_reserved_size: usize = 4;

pub const version: u16 = 1;
pub const state_version: u16 = 2;
pub const Error = page.Error || page.LayoutError || error{
    InvalidAllocatorState,
    AllocatorStateTooLarge,
};

pub const Entry = struct {
    page_id: u64,
    order: u8,
};

pub const StateRecordKind = enum(u8) {
    free = 1,
    pending = 2,
};

pub const StateRecord = struct {
    kind: StateRecordKind,
    page_id: u64,
    order: u8,
    visible_through_txid: u64,
};

pub const AllocatorPage = struct {
    bytes: []const u8,
    header: page.Header,
    total_entries: u32,
    capacity_entries: u32,

    pub fn init(bytes: []u8, header: page.Header, total_entries: u32) Error!void {
        const capacity = try capacityForBytes(bytes.len);
        if (total_entries > capacity) return error.AllocatorStateTooLarge;

        var normalized = header;
        normalized.page_type = .allocator;
        normalized.count = if (total_entries <= std.math.maxInt(u16)) @intCast(total_entries) else std.math.maxInt(u16);

        @memset(bytes, 0);
        try page.encodeHeader(bytes, normalized);
        page.writeInt(u16, bytes, version_offset, version);
        page.writeInt(u16, bytes, reserved_offset, 0);
        page.writeInt(u32, bytes, total_entries_offset, total_entries);
        page.writeInt(u32, bytes, capacity_entries_offset, capacity);
        page.writeInt(u32, bytes, checksum_offset, 0);
        page.writeInt(u32, bytes, body_reserved_offset, 0);
    }

    pub fn encodeInto(bytes: []u8, header: page.Header, entries: []const Entry) Error!AllocatorPage {
        const total_entries = std.math.cast(u32, entries.len) orelse return error.AllocatorStateTooLarge;
        try init(bytes, header, total_entries);

        for (entries, 0..) |item, index| {
            const slot = entryBytes(bytes, index) catch return error.AllocatorStateTooLarge;
            writeEntry(slot, item);
        }

        page.writeInt(u32, bytes, checksum_offset, checksum(bytes));
        return try validate(bytes);
    }

    pub fn validate(bytes: []const u8) Error!AllocatorPage {
        if (bytes.len < entries_offset) return error.PageTooSmall;

        const header = try page.decodeHeader(bytes);
        try page.validatePageType(header.page_type, .allocator);

        if (page.readInt(u16, bytes, version_offset) != version) return error.InvalidAllocatorState;
        if (page.readInt(u16, bytes, reserved_offset) != 0) return error.InvalidAllocatorState;
        if (page.readInt(u32, bytes, body_reserved_offset) != 0) return error.InvalidAllocatorState;

        const total_entries = page.readInt(u32, bytes, total_entries_offset);
        const capacity_entries = page.readInt(u32, bytes, capacity_entries_offset);
        if (capacity_entries != try capacityForBytes(bytes.len)) return error.InvalidAllocatorState;
        if (total_entries > capacity_entries) return error.InvalidAllocatorState;
        if (header.count != @min(total_entries, std.math.maxInt(u16))) return error.InvalidAllocatorState;
        if (page.readInt(u32, bytes, checksum_offset) != checksum(bytes)) return error.InvalidAllocatorState;

        var index: usize = 0;
        while (index < total_entries) : (index += 1) {
            const slot = try entryBytesConst(bytes, index);
            for (slot[entry_reserved_offset .. entry_reserved_offset + entry_reserved_size]) |reserved| {
                if (reserved != 0) return error.InvalidAllocatorState;
            }
        }

        return .{
            .bytes = bytes,
            .header = header,
            .total_entries = total_entries,
            .capacity_entries = capacity_entries,
        };
    }

    pub fn entry(self: AllocatorPage, index: u32) Error!Entry {
        if (index >= self.total_entries) return error.EntryOutOfBounds;
        return readEntry(try entryBytesConst(self.bytes, index));
    }

    pub fn count(self: AllocatorPage) u32 {
        return self.total_entries;
    }
};

pub const AllocatorStatePage = struct {
    bytes: []const u8,
    header: page.Header,
    version: u16,
    total_records: u32,
    capacity_records: u32,
    record_size: usize,

    pub fn encodeInto(bytes: []u8, header: page.Header, records: []const StateRecord) Error!AllocatorStatePage {
        const total_records = std.math.cast(u32, records.len) orelse return error.AllocatorStateTooLarge;
        const capacity = try stateCapacityForBytes(bytes.len);
        if (total_records > capacity) return error.AllocatorStateTooLarge;

        var normalized = header;
        normalized.page_type = .allocator;
        normalized.count = if (total_records <= std.math.maxInt(u16)) @intCast(total_records) else std.math.maxInt(u16);

        @memset(bytes, 0);
        try page.encodeHeader(bytes, normalized);
        page.writeInt(u16, bytes, version_offset, state_version);
        page.writeInt(u16, bytes, reserved_offset, v2_record_size);
        page.writeInt(u32, bytes, total_entries_offset, total_records);
        page.writeInt(u32, bytes, capacity_entries_offset, capacity);
        page.writeInt(u32, bytes, checksum_offset, 0);
        page.writeInt(u32, bytes, body_reserved_offset, 0);

        for (records, 0..) |state_record, index| {
            const slot = stateRecordBytes(bytes, index) catch return error.AllocatorStateTooLarge;
            try writeStateRecord(slot, state_record);
        }

        page.writeInt(u32, bytes, checksum_offset, checksum(bytes));
        return try validate(bytes);
    }

    pub fn validate(bytes: []const u8) Error!AllocatorStatePage {
        if (bytes.len < entries_offset) return error.PageTooSmall;

        const header = try page.decodeHeader(bytes);
        try page.validatePageType(header.page_type, .allocator);

        const raw_version = page.readInt(u16, bytes, version_offset);
        return switch (raw_version) {
            version => validateV1(bytes, header),
            state_version => validateV2(bytes, header),
            else => error.InvalidAllocatorState,
        };
    }

    pub fn record(self: AllocatorStatePage, index: u32) Error!StateRecord {
        if (index >= self.total_records) return error.EntryOutOfBounds;
        return switch (self.version) {
            version => blk: {
                const entry = readEntry(try entryBytesConst(self.bytes, index));
                break :blk .{
                    .kind = .free,
                    .page_id = entry.page_id,
                    .order = entry.order,
                    .visible_through_txid = 0,
                };
            },
            state_version => readStateRecord(try stateRecordBytesConst(self.bytes, index)),
            else => error.InvalidAllocatorState,
        };
    }

    pub fn count(self: AllocatorStatePage) u32 {
        return self.total_records;
    }

    fn validateV1(bytes: []const u8, header: page.Header) Error!AllocatorStatePage {
        const allocator_page = try AllocatorPage.validate(bytes);
        return .{
            .bytes = bytes,
            .header = header,
            .version = version,
            .total_records = allocator_page.total_entries,
            .capacity_records = allocator_page.capacity_entries,
            .record_size = entry_size,
        };
    }

    fn validateV2(bytes: []const u8, header: page.Header) Error!AllocatorStatePage {
        if (page.readInt(u16, bytes, reserved_offset) != v2_record_size) return error.InvalidAllocatorState;
        if (page.readInt(u32, bytes, body_reserved_offset) != 0) return error.InvalidAllocatorState;

        const total_records = page.readInt(u32, bytes, total_entries_offset);
        const capacity_records = page.readInt(u32, bytes, capacity_entries_offset);
        if (capacity_records != try stateCapacityForBytes(bytes.len)) return error.InvalidAllocatorState;
        if (total_records > capacity_records) return error.InvalidAllocatorState;
        if (header.count != @min(total_records, std.math.maxInt(u16))) return error.InvalidAllocatorState;
        if (page.readInt(u32, bytes, checksum_offset) != checksum(bytes)) return error.InvalidAllocatorState;

        var index: usize = 0;
        while (index < total_records) : (index += 1) {
            _ = try readStateRecord(try stateRecordBytesConst(bytes, index));
        }

        return .{
            .bytes = bytes,
            .header = header,
            .version = state_version,
            .total_records = total_records,
            .capacity_records = capacity_records,
            .record_size = v2_record_size,
        };
    }
};

pub fn capacityForBytes(byte_count: usize) Error!u32 {
    if (byte_count < entries_offset) return error.PageTooSmall;
    return std.math.cast(u32, (byte_count - entries_offset) / entry_size) orelse return error.AllocatorStateTooLarge;
}

pub fn bytesNeededForEntries(entry_count: usize) Error!usize {
    const entry_bytes = std.math.mul(usize, entry_count, entry_size) catch return error.AllocatorStateTooLarge;
    return std.math.add(usize, entries_offset, entry_bytes) catch return error.AllocatorStateTooLarge;
}

pub fn stateCapacityForBytes(byte_count: usize) Error!u32 {
    if (byte_count < entries_offset) return error.PageTooSmall;
    return std.math.cast(u32, (byte_count - entries_offset) / v2_record_size) orelse return error.AllocatorStateTooLarge;
}

pub fn bytesNeededForStateRecords(record_count: usize) Error!usize {
    const record_bytes = std.math.mul(usize, record_count, v2_record_size) catch return error.AllocatorStateTooLarge;
    return std.math.add(usize, entries_offset, record_bytes) catch return error.AllocatorStateTooLarge;
}

fn entryBytes(bytes: []u8, index: usize) Error![]u8 {
    const start = std.math.add(usize, entries_offset, std.math.mul(usize, index, entry_size) catch return error.AllocatorStateTooLarge) catch return error.AllocatorStateTooLarge;
    const end = std.math.add(usize, start, entry_size) catch return error.AllocatorStateTooLarge;
    if (end > bytes.len) return error.AllocatorStateTooLarge;
    return bytes[start..end];
}

fn entryBytesConst(bytes: []const u8, index: usize) Error![]const u8 {
    const start = std.math.add(usize, entries_offset, std.math.mul(usize, index, entry_size) catch return error.AllocatorStateTooLarge) catch return error.AllocatorStateTooLarge;
    const end = std.math.add(usize, start, entry_size) catch return error.AllocatorStateTooLarge;
    if (end > bytes.len) return error.EntryOutOfBounds;
    return bytes[start..end];
}

fn stateRecordBytes(bytes: []u8, index: usize) Error![]u8 {
    const start = std.math.add(usize, entries_offset, std.math.mul(usize, index, v2_record_size) catch return error.AllocatorStateTooLarge) catch return error.AllocatorStateTooLarge;
    const end = std.math.add(usize, start, v2_record_size) catch return error.AllocatorStateTooLarge;
    if (end > bytes.len) return error.AllocatorStateTooLarge;
    return bytes[start..end];
}

fn stateRecordBytesConst(bytes: []const u8, index: usize) Error![]const u8 {
    const start = std.math.add(usize, entries_offset, std.math.mul(usize, index, v2_record_size) catch return error.AllocatorStateTooLarge) catch return error.AllocatorStateTooLarge;
    const end = std.math.add(usize, start, v2_record_size) catch return error.AllocatorStateTooLarge;
    if (end > bytes.len) return error.EntryOutOfBounds;
    return bytes[start..end];
}

fn writeEntry(bytes: []u8, entry: Entry) void {
    page.writeInt(u64, bytes, entry_page_id_offset, entry.page_id);
    bytes[entry_order_offset] = entry.order;
    @memset(bytes[entry_reserved_offset .. entry_reserved_offset + entry_reserved_size], 0);
}

fn readEntry(bytes: []const u8) Entry {
    return .{
        .page_id = page.readInt(u64, bytes, entry_page_id_offset),
        .order = bytes[entry_order_offset],
    };
}

fn writeStateRecord(bytes: []u8, record: StateRecord) Error!void {
    if (record.kind == .free and record.visible_through_txid != 0) return error.InvalidAllocatorState;

    bytes[v2_record_kind_offset] = @intFromEnum(record.kind);
    bytes[v2_record_order_offset] = record.order;
    page.writeInt(u16, bytes, v2_record_reserved_offset, 0);
    page.writeInt(u64, bytes, v2_record_page_id_offset, record.page_id);
    page.writeInt(u64, bytes, v2_record_visible_txid_offset, record.visible_through_txid);
    @memset(bytes[v2_record_tail_reserved_offset .. v2_record_tail_reserved_offset + v2_record_tail_reserved_size], 0);
}

fn readStateRecord(bytes: []const u8) Error!StateRecord {
    for (bytes[v2_record_reserved_offset .. v2_record_reserved_offset + v2_record_reserved_size]) |reserved| {
        if (reserved != 0) return error.InvalidAllocatorState;
    }
    for (bytes[v2_record_tail_reserved_offset .. v2_record_tail_reserved_offset + v2_record_tail_reserved_size]) |reserved| {
        if (reserved != 0) return error.InvalidAllocatorState;
    }

    const kind = switch (bytes[v2_record_kind_offset]) {
        @intFromEnum(StateRecordKind.free) => StateRecordKind.free,
        @intFromEnum(StateRecordKind.pending) => StateRecordKind.pending,
        else => return error.InvalidAllocatorState,
    };
    const visible_through_txid = page.readInt(u64, bytes, v2_record_visible_txid_offset);
    if (kind == .free and visible_through_txid != 0) return error.InvalidAllocatorState;

    return .{
        .kind = kind,
        .page_id = page.readInt(u64, bytes, v2_record_page_id_offset),
        .order = bytes[v2_record_order_offset],
        .visible_through_txid = visible_through_txid,
    };
}

fn checksum(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[page.header_size..checksum_offset]);
    crc.update(&[_]u8{0} ** @sizeOf(u32));
    crc.update(bytes[checksum_offset + @sizeOf(u32) ..]);
    return crc.final();
}

// ======tests======

test "encode validate round trip preserves allocator entries" {
    var bytes = [_]u8{0} ** 256;

    const allocator_page = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 9,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .page_id = 4, .order = 1 },
        .{ .page_id = 8, .order = 2 },
    });

    try std.testing.expectEqual(@as(u32, 2), allocator_page.count());
    try std.testing.expectEqual(@as(u16, 2), allocator_page.header.count);
    try std.testing.expectEqualDeep(Entry{ .page_id = 4, .order = 1 }, try allocator_page.entry(0));
    try std.testing.expectEqualDeep(Entry{ .page_id = 8, .order = 2 }, try allocator_page.entry(1));
}

test "validate rejects wrong page type" {
    var bytes = [_]u8{0} ** 128;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{});
    bytes[8] = @intFromEnum(page.PageType.leaf);

    try std.testing.expectError(error.UnexpectedPageType, AllocatorPage.validate(bytes[0..]));
}

test "validate rejects corrupted entry reserved bytes" {
    var bytes = [_]u8{0} ** 128;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .page_id = 4, .order = 0 }});
    bytes[entries_offset + entry_reserved_offset] = 1;
    page.writeInt(u32, bytes[0..], checksum_offset, checksum(bytes[0..]));

    try std.testing.expectError(error.InvalidAllocatorState, AllocatorPage.validate(bytes[0..]));
}

test "validate rejects body checksum mismatch" {
    var bytes = [_]u8{0} ** 128;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .page_id = 4, .order = 0 }});
    bytes[entries_offset] ^= 1;

    try std.testing.expectError(error.InvalidAllocatorState, AllocatorPage.validate(bytes[0..]));
}

test "validate rejects unsupported body version" {
    var bytes = [_]u8{0} ** 128;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{});
    page.writeInt(u16, bytes[0..], version_offset, version + 1);
    page.writeInt(u32, bytes[0..], checksum_offset, checksum(bytes[0..]));

    try std.testing.expectError(error.InvalidAllocatorState, AllocatorPage.validate(bytes[0..]));
}

test "validate rejects inconsistent total entries and capacity" {
    var bytes = [_]u8{0} ** 128;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .page_id = 4, .order = 0 }});

    page.writeInt(u32, bytes[0..], total_entries_offset, try capacityForBytes(bytes.len) + 1);
    page.writeInt(u32, bytes[0..], checksum_offset, checksum(bytes[0..]));
    try std.testing.expectError(error.InvalidAllocatorState, AllocatorPage.validate(bytes[0..]));

    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .page_id = 4, .order = 0 }});
    page.writeInt(u32, bytes[0..], capacity_entries_offset, try capacityForBytes(bytes.len) + 1);
    page.writeInt(u32, bytes[0..], checksum_offset, checksum(bytes[0..]));
    try std.testing.expectError(error.InvalidAllocatorState, AllocatorPage.validate(bytes[0..]));
}

test "encode rejects entries beyond page capacity" {
    var bytes = [_]u8{0} ** (entries_offset + entry_size);

    try std.testing.expectError(error.AllocatorStateTooLarge, AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 3,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .page_id = 4, .order = 0 },
        .{ .page_id = 5, .order = 0 },
    }));
}

test "state page decodes legacy allocator entries as free records" {
    var bytes = [_]u8{0} ** 256;
    _ = try AllocatorPage.encodeInto(bytes[0..], .{
        .page_id = 9,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .page_id = 4, .order = 1 }});

    const state_page = try AllocatorStatePage.validate(bytes[0..]);
    try std.testing.expectEqual(version, state_page.version);
    try std.testing.expectEqual(@as(u32, 1), state_page.count());
    try std.testing.expectEqualDeep(StateRecord{
        .kind = .free,
        .page_id = 4,
        .order = 1,
        .visible_through_txid = 0,
    }, try state_page.record(0));
}

test "state page v2 round trips free and pending records" {
    var bytes = [_]u8{0} ** 256;
    const state_page = try AllocatorStatePage.encodeInto(bytes[0..], .{
        .page_id = 9,
        .page_type = .leaf,
        .count = 0,
        .order = 0,
    }, &.{
        .{ .kind = .free, .page_id = 4, .order = 1, .visible_through_txid = 0 },
        .{ .kind = .pending, .page_id = 8, .order = 2, .visible_through_txid = 7 },
    });

    try std.testing.expectEqual(state_version, state_page.version);
    try std.testing.expectEqual(@as(usize, v2_record_size), state_page.record_size);
    try std.testing.expectEqual(@as(u16, 2), state_page.header.count);
    try std.testing.expectEqualDeep(StateRecord{
        .kind = .free,
        .page_id = 4,
        .order = 1,
        .visible_through_txid = 0,
    }, try state_page.record(0));
    try std.testing.expectEqualDeep(StateRecord{
        .kind = .pending,
        .page_id = 8,
        .order = 2,
        .visible_through_txid = 7,
    }, try state_page.record(1));
}

test "state page v2 rejects free record with txid" {
    var bytes = [_]u8{0} ** 256;

    try std.testing.expectError(error.InvalidAllocatorState, AllocatorStatePage.encodeInto(bytes[0..], .{
        .page_id = 9,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .kind = .free, .page_id = 4, .order = 1, .visible_through_txid = 1 }}));
}

test "state page v2 rejects invalid record size" {
    var bytes = [_]u8{0} ** 256;
    _ = try AllocatorStatePage.encodeInto(bytes[0..], .{
        .page_id = 9,
        .page_type = .allocator,
        .count = 0,
        .order = 0,
    }, &.{.{ .kind = .pending, .page_id = 4, .order = 0, .visible_through_txid = 1 }});

    page.writeInt(u16, bytes[0..], reserved_offset, v2_record_size - 1);
    page.writeInt(u32, bytes[0..], checksum_offset, checksum(bytes[0..]));

    try std.testing.expectError(error.InvalidAllocatorState, AllocatorStatePage.validate(bytes[0..]));
}
