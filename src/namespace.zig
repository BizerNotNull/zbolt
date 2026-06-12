const std = @import("std");

pub const bucket_entry_flag: u32 = 1;

pub const Error = error{
    BucketAlreadyExists,
    BucketNameConflict,
    BucketNotFound,
    InvalidBucketRecord,
    KeyBelongsToBucket,
    KeyNotBucket,
};

pub const BucketRecord = struct {
    root_page_id: u64,
};

pub const RootEntry = union(enum) {
    value: []const u8,
    bucket: BucketRecord,
};

pub const BucketNames = struct {
    items: [][]u8,

    pub fn deinit(self: *BucketNames, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub fn isBucketFlags(flags: u32) bool {
    return flags == bucket_entry_flag;
}

pub fn decodeRootEntry(value: []const u8, flags: u32) Error!RootEntry {
    if (!isBucketFlags(flags)) {
        return .{ .value = value };
    }

    return .{ .bucket = try decodeBucketRecord(value, flags) };
}

pub fn encodeBucketRecord(root_page_id: u64) Error![8]u8 {
    if (root_page_id == 0) return error.InvalidBucketRecord;

    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, root_page_id, .little);
    return bytes;
}

pub fn decodeBucketRecord(value: []const u8, flags: u32) Error!BucketRecord {
    if (!isBucketFlags(flags)) return error.KeyNotBucket;
    if (value.len != 8) return error.InvalidBucketRecord;

    const root_page_id = std.mem.readInt(u64, value[0..8], .little);
    if (root_page_id == 0) return error.InvalidBucketRecord;

    return .{
        .root_page_id = root_page_id,
    };
}

// ======tests======

test "bucket record round trips root page ids" {
    const encoded = try encodeBucketRecord(42);
    const decoded = try decodeBucketRecord(encoded[0..], bucket_entry_flag);

    try std.testing.expectEqual(@as(u64, 42), decoded.root_page_id);
}

test "decodeBucketRecord rejects non bucket flags" {
    const encoded = try encodeBucketRecord(9);

    try std.testing.expectError(error.KeyNotBucket, decodeBucketRecord(encoded[0..], 0));
}

test "decodeBucketRecord rejects invalid payload length" {
    try std.testing.expectError(error.InvalidBucketRecord, decodeBucketRecord("bad", bucket_entry_flag));
}

test "decodeRootEntry keeps plain values opaque" {
    const decoded = try decodeRootEntry("plain", 0);

    switch (decoded) {
        .value => |value| try std.testing.expectEqualSlices(u8, "plain", value),
        .bucket => return error.UnexpectedBucketEntry,
    }
}

test "decodeRootEntry recognizes bucket namespace entries" {
    const encoded = try encodeBucketRecord(17);
    const decoded = try decodeRootEntry(encoded[0..], bucket_entry_flag);

    switch (decoded) {
        .value => return error.UnexpectedPlainValue,
        .bucket => |record| try std.testing.expectEqual(@as(u64, 17), record.root_page_id),
    }
}
