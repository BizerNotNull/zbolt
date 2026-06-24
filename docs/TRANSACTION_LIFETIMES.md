# Transaction Lifetimes and Ownership

This document is the authoritative contract for transaction, managed view, and
cursor lifetimes in zbolt.

zbolt exposes two ownership styles for reads:

- Explicit transactions: callers own a `ReadTx` or `WriteTx` value and must end
  it with `deinit`, `commit`, or `rollback`.
- Managed wrappers: `ManagedReadView`, `ManagedBucketView`, and
  `ManagedCursor` own an internal `ReadTx` so callers can keep a stable snapshot
  across multiple calls without manually managing a transaction.

All transaction and managed wrapper handles borrow the `DB` that created them.
The `DB` must remain open until those handles are released. `DB.close` asserts
that no writers and no readers are still active.

## ReadTx

`ReadTx` is a stable read-only snapshot of the committed database state at the
time `DB.beginRead` succeeds.

- A `ReadTx` borrows its originating `DB`.
- A `ReadTx` owns the snapshot source used to read committed pages.
- Reads, scans, bucket views, and cursors opened from a `ReadTx` see the same
  snapshot even if later writes commit.
- `ReadTx` values must be used through one mutable binding and must not be
  copied after creation.
- `ReadTx.deinit` releases the snapshot source and ends the active reader for
  reclamation.
- Calling `deinit` more than once is allowed.

After `ReadTx.deinit`, the `ReadTx` is closed. Any `BucketReadView` or
`tree.Cursor` borrowed from it is also invalid. Read APIs on the closed
transaction or its borrowed bucket views return `ReadTxError.ReadTransactionClosed`.
Cursor movement through an already-open borrowed cursor returns
`CursorError.CursorOwnerClosed`.

## WriteTx

`WriteTx` is the single active writer for a `DB`.

- A `WriteTx` borrows its originating `DB`.
- A `WriteTx` owns staged pages, arena-allocated bucket paths, allocator state,
  and other uncommitted working state.
- Reads and cursors opened through a `WriteTx` include staged uncommitted
  changes.
- `WriteTx` values must be used through one mutable binding and must not be
  copied after creation.
- `WriteTx.deinit` rolls back an open transaction and releases the writer slot.
- `WriteTx.commit` publishes pending writes, releases the writer slot, and
  closes the transaction.
- `WriteTx.rollback` discards pending writes, releases the writer slot, and
  closes the transaction.

After a successful `commit` or `rollback`, the `WriteTx` is closed. Write,
read, cursor, and bucket-view operations on the closed transaction return
`WriteTxError.WriteTransactionClosed`.

If commit fails after the transaction starts committing, the `WriteTx` enters a
failed state. Later operations return `WriteTxError.WriteTransactionFailed`.
The writer slot is released, but the failed transaction must not be reused.

Any `WriteBucketView` or `tree.Cursor` borrowed from a `WriteTx` is valid only
while the transaction remains open. `commit`, `rollback`, `deinit`, or commit
failure invalidates those borrowed handles.

## Managed Views and Cursors

Managed wrappers own an internal heap-allocated `ReadTx`.

- `ManagedReadView` owns a stable root snapshot.
- `ManagedBucketView` owns a stable snapshot scoped to one bucket root.
- `ManagedCursor` owns a stable snapshot and the cursor handle traversing it.

Managed wrappers may be moved by value, but must still be treated as a single
owned handle. They must not be copied and then used from multiple bindings.

`deinit` releases the owned `ReadTx` and ends the active reader. Calling
`deinit` more than once is allowed. After `deinit`, the managed wrapper is
closed. `ManagedReadView` and `ManagedBucketView` APIs return
`ManagedViewError.ManagedViewClosed`; `ManagedCursor` movement APIs return
`ManagedCursorError.ManagedCursorClosed`.

Bucket views and cursors borrowed from `ManagedReadView` or
`ManagedBucketView` are valid only until the owning managed wrapper is
deinitialized. `ManagedCursor` methods are valid only until
`ManagedCursor.deinit`. After the owner closes, borrowed bucket views return
`ReadTxError.ReadTransactionClosed` and borrowed cursor movement returns
`CursorError.CursorOwnerClosed`.

## Bucket Views

`BucketReadView` is a borrowed, bucket-scoped read helper. It does not own a
snapshot. It remains valid only while the originating `ReadTx`,
`ManagedReadView`, `ManagedBucketView`, or open `WriteTx` remains valid.

`WriteBucketView` is a borrowed, bucket-scoped write helper. It stores a
back-reference to the owning `WriteTx` and a transaction-owned bucket path. It
remains valid only while that `WriteTx` remains open.

Nested bucket views follow the same ownership rule as the view they came from:
they borrow the same originating transaction or managed wrapper.

## Cursors and Returned Records

`tree.Cursor` handles borrow the snapshot or staged read view they were opened
from. Call `tree.Cursor.deinit` when finished with the handle.

Cursor movement methods return `tree.CursorRecord` values with owned key and
value buffers. Those records remain valid after the cursor or transaction is
closed, and the caller must release them with `CursorRecord.deinit`.

`ScanRecords` also owns its returned records. It remains valid after the
transaction or view is closed, and the caller must release it with
`ScanRecords.deinit`.

Lookup methods such as `get` return owned value copies. The caller owns those
buffers and must free them with the allocator passed to the lookup. The returned
values remain valid after the transaction or view is closed.

## Reclamation and Long-Lived Reads

Read transactions and managed wrappers keep their snapshots active for
reclamation. Old pages that may still be visible to an active reader cannot be
reused until that reader is released.

Close `ReadTx`, `ManagedReadView`, `ManagedBucketView`, and `ManagedCursor`
handles as soon as the snapshot is no longer needed. Holding them indefinitely
is safe for snapshot correctness, but can delay page reuse and increase file
growth pressure.
