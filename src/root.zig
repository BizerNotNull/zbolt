pub const meta = @import("meta.zig");
pub const page = @import("page.zig");
pub const errors = @import("errors.zig");
pub const Meta = meta.Meta;
pub const MetaError = meta.Error;
pub const PageError = page.Error;
pub const DbOpenError = errors.DbOpenError;
pub const MetaSlot = meta.MetaSlot;
pub const SelectedMeta = meta.SelectedMeta;
pub const PageHeader = page.Header;
pub const PageType = page.PageType;
pub const decodeMeta = meta.decode;
pub const encodeMeta = meta.encode;
pub const selectNewestValidMeta = meta.selectNewestValid;
pub const decodePageHeader = page.decodeHeader;
pub const encodePageHeader = page.encodeHeader;
pub const pageSpanSize = page.spanSize;

pub const DB = @import("db.zig").DB;
pub const open = @import("db.zig").open;

test {
    _ = @import("db.zig");
    _ = @import("meta.zig");
    _ = @import("page.zig");
}
