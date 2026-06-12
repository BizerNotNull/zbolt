# zbolt

The zbolt project is an embedded kv database for zig. The specific architecture will be similar to bbolt.

Callers provide the Zig `std.Io` context when opening a `zbolt.DB`, so the
application keeps control over IO runtime selection and lifecycle.

Current capabilities include:

- single-file open/bootstrap and meta recovery
- top-level bucket namespaces backed by independent B+Tree roots
- bucket existence checks and top-level bucket enumeration
- snapshot read transactions
- single-writer `put` / `delete`
- bucket-scoped `put` / `delete`
- read cursor traversal, including bucket-scoped cursor traversal
- managed DB-owned read cursors for snapshot traversal without manual `ReadTx` lifecycle handling
- persisted delayed reclaim through allocator state pages
- explicit `compact()` file rewriting with state reload
