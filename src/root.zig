pub const DB = @import("db.zig").DB;
pub const open = @import("db.zig").open;

test {
    _ = @import("db.zig");
}
