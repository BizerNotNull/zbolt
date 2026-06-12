# zbolt

The zbolt project is an embedded kv database for zig. The specific architecture will be similar to bbolt.

Current capabilities include:

- single-file open/bootstrap and meta recovery
- snapshot read transactions
- single-writer `put` / `delete`
- read cursor traversal
- persisted delayed reclaim through allocator state pages
- explicit `compact()` file rewriting with state reload
