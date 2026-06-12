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
    InvalidPageOrder,
    PageIdOverflow,
    PageTooSmall,
    SpanSizeOverflow,
};

pub const PageLayoutError = error{
    UnexpectedPageType,
    InvalidPageLayout,
    EntryOutOfBounds,
    EntriesNotSorted,
    PageFull,
};

pub const DbOpenError = error{
    InvalidDatabaseFile,
    DatabaseFileTooSmall,
    DatabaseLocked,
};

pub const CompactError = error{
    WriteTransactionActive,
    ActiveReadersPresent,
    CorruptTreeShape,
    TempFileValidationFailed,
    FileReplaceRolledBack,
    FileReplaceRollbackFailed,
};

pub const StorageError = error{
    PageLengthMismatch,
    PageOffsetOverflow,
};
