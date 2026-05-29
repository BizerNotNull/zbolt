pub const meta = @import("meta.zig");
pub const Meta = meta.Meta;
pub const MetaError = meta.Error;
pub const MetaSlot = meta.MetaSlot;
pub const SelectedMeta = meta.SelectedMeta;
pub const decodeMeta = meta.decode;
pub const encodeMeta = meta.encode;
pub const selectNewestValidMeta = meta.selectNewestValid;

pub const DB = @import("db.zig").DB;
pub const open = @import("db.zig").open;

test {
    _ = @import("db.zig");
    _ = @import("meta.zig");
}
