pub const MetaError = error{
    InvalidMagic,
    InvalidVersion,
    InvalidChecksum,
    InvalidPageSize,
    PageTooSmall,
    PageLengthMismatch,
    RootPageOutOfRange,
    AllocatorRootOutOfRange,
    NoValidMetaPage,
    OutOfMemory,
};

pub const PageError = error{
    InvalidPageType,
    InvalidBasePageSize,
    PageTooSmall,
    SpanSizeOverflow,
};

pub const DbOpenError = error{
    InvalidDatabaseFile,
    DatabaseFileTooSmall,
};
