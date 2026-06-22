# zbolt

The zbolt project is an embedded kv database for zig. The specific architecture will be similar to bbolt.

Callers provide the Zig `std.Io` context when opening a `zbolt.DB`, so the
application keeps control over IO runtime selection and lifecycle.

Current capabilities include:

- single-file open/bootstrap and meta recovery
- bucket namespaces backed by independent B+Tree roots, including nested buckets
- bucket existence checks and bucket enumeration at root or within parent buckets
- snapshot read transactions
- explicit write transactions with read-your-writes staging semantics
- single-writer `put` / `delete`
- bucket-scoped `put` / `delete`, including nested bucket paths
- read cursor traversal, including nested bucket-scoped cursor traversal
- range scan APIs at root or within bucket scopes
- managed DB-owned read views, including bucket-scoped stable snapshots, for multi-call reads without manual `ReadTx` lifecycle handling
- managed DB-owned read cursors for snapshot traversal without manual `ReadTx` lifecycle handling
- mmap-backed committed snapshot reads with owned-buffer fallback when file mapping is unavailable
- persisted delayed reclaim through allocator state pages
- explicit `compact()` file rewriting with state reload

## Storage model and limitations

zbolt stores data in a single database file with copy-on-write commits. Write
transactions build new page versions and publish them by switching the active
meta page after data and allocator state reach durable storage.

Read transactions capture the committed root page and high water mark at
transaction start. Committed tree pages are read through `mmap` when the
platform and IO backend can create a read-only mapping. If mapping fails, the
same read path falls back to owned heap buffers.

Mapped page views are pinned while higher layers use them, so a later file
growth or remap-sensitive read does not invalidate an already borrowed page
view. Long-lived read transactions still retain old snapshots and can delay
page reuse, so applications should close read transactions and managed read
views when they are no longer needed.

The write path does not mutate pages through `mmap`; mapped memory is a
read-side optimization only. The database currently grows as needed and does
not shrink on ordinary commits. Use explicit `compact()` to rewrite and shrink
the file.
