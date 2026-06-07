# zbolt

The zbolt project is an embedded kv database for zig. The specific architecture will be similar to bbolt.

Current capabilities include:

- single-file open/bootstrap and meta recovery
- snapshot read transactions
- single-writer `put` / `delete`
- read cursor traversal
- explicit `compact()` file rewriting with state reload

Current limitations include:

- `compact()` requires no active read or write transactions
- delayed reclaim is still in-memory only until reuse or compaction
