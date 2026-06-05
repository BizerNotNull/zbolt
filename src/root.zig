pub const allocator = @import("allocator.zig");
pub const meta = @import("meta.zig");
pub const page = @import("page.zig");
pub const tree = @import("tree.zig");
pub const errors = @import("errors.zig");
pub const storage = @import("storage.zig");
pub const Meta = meta.Meta;
pub const MetaError = meta.Error;
pub const PageError = page.Error;
pub const PageLayoutError = page.LayoutError;
pub const DbOpenError = errors.DbOpenError;
pub const StorageError = storage.Error;
pub const PageAllocator = allocator.PageAllocator;
pub const PageAllocatorError = allocator.Error;
pub const TreeLookupError = tree.TreeLookupError;
pub const TreeWriteError = tree.TreeWriteError;
pub const MetaSlot = meta.MetaSlot;
pub const SelectedMeta = meta.SelectedMeta;
pub const PageHeader = page.Header;
pub const PageDataHeader = page.DataHeader;
pub const PageType = page.PageType;
pub const LeafEntry = page.LeafEntry;
pub const LeafEntryView = page.LeafEntryView;
pub const LeafPage = page.LeafPage;
pub const BranchEntry = page.BranchEntry;
pub const BranchEntryView = page.BranchEntryView;
pub const BranchPage = page.BranchPage;
pub const decodeMeta = meta.decode;
pub const encodeMeta = meta.encode;
pub const selectNewestValidMeta = meta.selectNewestValid;
pub const decodePageHeader = page.decodeHeader;
pub const encodePageHeader = page.encodeHeader;
pub const decodePageDataHeader = page.decodeDataHeader;
pub const encodePageDataHeader = page.encodeDataHeader;
pub const pageSpanSize = page.spanSize;
pub const pageSpanPageCount = page.spanPageCount;
pub const pageSpanEndPageId = page.spanEndPageId;
pub const maxPageObjectOrderForSpanSize = page.maxOrderForSpanSize;
pub const treeLookup = tree.lookup;

pub const DB = @import("db.zig").DB;
pub const open = @import("db.zig").open;

// ======tests======

test {
    _ = @import("allocator.zig");
    _ = @import("db.zig");
    _ = @import("meta.zig");
    _ = @import("page.zig");
    _ = @import("storage.zig");
    _ = @import("tree.zig");
    _ = @import("page/leaf.zig");
    _ = @import("page/branch.zig");
    _ = @import("page/allocator.zig");
}
