const std = @import("std");
const db_mod = @import("db.zig");
const tree = @import("tree.zig");

pub const ReadTx = struct {
    db: *db_mod.DB,
    snapshot: tree.ReadSnapshot,
    txid: u64,

    /// Releases this read view.
    ///
    /// The transaction borrows the DB handle and is valid only while that DB
    /// remains open. The no-op lifecycle hook is where future reader tracking
    /// can detach snapshots before reclaimed pages are reused.
    pub fn deinit(self: *ReadTx) void {
        _ = self;
    }

    /// Returns an owned copy of the value visible to this read snapshot.
    pub fn get(self: *const ReadTx, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return tree.lookupSnapshot(self.db, allocator, self.snapshot, key);
    }
};
