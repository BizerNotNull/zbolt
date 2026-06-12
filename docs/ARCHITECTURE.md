# ARCHITECTURE

## 1. Overall Design

`zbolt` aims to be an embedded KV database for Zig. It runs as an embedded library, stores data in a single local file, and does not depend on a separate service process.

The current design uses the following combination:

- `COW`: write transactions generate new pages through copy-on-write instead of modifying committed pages in place
- `B+Tree`: the core structure for indexing and data organization
- `mmap`: maps the database file into memory so the read path can be as close to zero-copy as possible
- `page`: all on-disk structures use the base page as the addressing unit
- `double meta page`: two metadata pages are used to preserve the most recent recoverable state
- `buddy allocator`: the primary page-space allocation strategy
- `MVCC`: provides snapshot isolation and delayed reclamation under single-writer, multi-reader concurrency

This document uses the following terminology consistently:

- `base page`: the minimum on-disk addressing unit
- `page object`: a logical page object that may occupy one or more contiguous `base page`s
- `order`: the order of the block occupied by a page object
- `span size`: the total byte size occupied by a page object, equal to `base_page_size << order`

The core model is as follows:

- Single-file embedded database
- Single writer, multiple readers
- Read transactions are snapshot-based and do not block one another
- Write transactions commit serially
- Committed pages are never modified in place
- Old-version pages must not be reused until all read transactions that could still reference them have finished

## 2. File Format

### 2.1 File Layout

Logically, the database file consists of the following parts:

1. `meta0`
2. `meta1`
3. Data page region

The conventions are:

- Page `0` is `meta0`
- Page `1` is `meta1`
- Page `2` and beyond are normal data pages
- The database defines a fixed `base page size`
- `base page size` must be `2^n`
- The physical allocation size of a `page object` is `base page size << order`

The recommended constraints are:

- By default, `base page size` uses the operating system page size, for example `4096` bytes
- All page IDs are numbered in base pages, not in larger block units
- Larger nodes, large values, and allocator metadata are carried by `page object`s with higher `order`

This is closer to the `redb` approach: the logical addressing unit stays stable, while the physical span of a `page object` can grow by `2^k`.

### 2.2 Responsibilities of Meta Pages

Each meta page should describe at least the following information:

- magic number: identifies the file type
- file format version: file format version
- base page size: base page size
- flags: global flags
- root page id: the page ID of the current root tree
- allocator root / freelist root: the entry point of the allocator or free-page structure
- high water mark: the upper bound of currently allocated base page IDs
- txid: the most recently committed transaction ID
- checksum: the checksum of the meta page

If multiple top-level buckets or tables are supported in the future, then `root page id` should point to the root page of the top-level namespace tree rather than directly to a specific business bucket.

### 2.3 Selecting a Valid Meta Page at Startup

After opening the database, the system must read both `meta0` and `meta1`, then determine the valid state in the following order:

1. Check whether the magic number and version match
2. Check whether the checksum is valid
3. Filter out structurally invalid meta pages
   - `root page id` must not exceed the high water mark
   - `allocator root` must not point to an invalid page
4. If both are valid, choose the one with the larger `txid`
5. If only one is valid, use that one
6. If neither is valid, treat the database as corrupted or not fully initialized

This process is the first layer of crash recovery. During commit, a new meta page may be written only after the new data pages have already been persisted, so the old meta page always remains as a fallback state.

## 3. Page Model

### 3.1 Common Page Header

Each page should have a unified page-header format containing at least:

- `page_id`
- `page_type`
- `count`
- `order`

Where:

- `page_id`: the current page ID
- `page_type`: the page type
- `count`: the number of elements in this page
- `order`: the block order occupied by the current `page object`, where `span size = base page size << order`

When a key/value pair or a structure no longer fits in a single `base page`, the implementation should allocate a higher-order `page object` through the buddy allocator. If the implementation keeps an `overflow` field, it should still be treated only as a description of the `page object` span, not as a second allocation mechanism independent from the allocator.

### 3.2 Page Types

The current design should include at least the following page types:

- `meta page`
- `branch page`
- `leaf page`
- `allocator state page` or `freelist page`

Among them, `allocator state page` is the preferred direction for this project because `zbolt` plans to use a buddy allocator. If the early implementation starts with a more compatible freelist, the interface should still remain switchable.

### 3.3 Branch Page

A `branch page` stores only routing information and does not store values directly. Each element should contain at least:

- separator key
- child page ID

Semantically:

- the key is used to decide which child node a lookup should descend into
- values do not appear in branch pages
- child pointers in branch pages point to lower-level branch or leaf pages

This naturally makes the entire tree suitable for range scans and ordered traversal.

### 3.4 Leaf Page

A `leaf page` stores the actual business entries. Each element should contain at least:

- key length
- value length
- flags
- key bytes
- value bytes

The `flags` field can be used to mark:

- normal key/value pairs
- bucket or table entries
- large `page object` values or references to externally stored values

If nested buckets are supported in the future, then some entries in a leaf page will not be ordinary values but rather the root information of child buckets.

### 3.5 Top-Level Namespace

The database may expose bucket or table abstractions externally, but in the file format they are all mapped to a single root tree:

- leaf entries in the root tree store `name -> bucket/table root` mappings
- each bucket or table corresponds to its own independent B+Tree
- branch pages are responsible for routing
- leaf pages are responsible for storing key/value pairs or child bucket entries

This separates namespace management from the actual data trees and makes later extensions easier.

### 3.6 Large `page object`s

`zbolt` prefers to represent large objects using `base page` plus variable-order `page object`s, rather than treating overflow pages as an independent primary allocation model.

When a single value, a serialized node, or allocator metadata exceeds the capacity of one `base page`:

- allocate a higher-order `page object` through the buddy allocator
- its `span size = base page size << order`
- the first `base page` records the logical type and span information
- subsequent `base page`s are treated as the contiguous payload region of the same `page object`
- reclamation must happen for the entire `page object` as a whole and it must not be split for reuse

If the implementation keeps the name `overflow`, it should still be understood as meaning how many extra contiguous `base page`s are covered by this `page object`, not as a separate mechanism operating outside the buddy allocator.

## 4. B+Tree Organization

### 4.1 Basic Invariants

The B+Tree in `zbolt` must preserve the following invariants:

- all leaves are at the same level
- branch pages store only routing keys and child page references
- leaf pages store the actual entries in key order
- committed pages are never modified in place
- new versions of modified paths are constructed by reallocating new pages in write transactions

### 4.2 Lookup Path

When reading a key:

1. Start from the root page in the transaction snapshot
2. Compare the key in branch pages and descend
3. Continue until the target key is located in a leaf page
4. Return the value or the bucket/table entry

With `mmap`, a read transaction can access page contents directly from mapped memory and avoid intermediate copying as much as possible.

### 4.3 Update Path

When a write transaction modifies a key, it does not overwrite the original leaf page directly. Instead it:

1. Locates the target leaf in the current snapshot tree
2. Materializes the target leaf into a mutable node
3. Generates a new page after modifying the leaf
4. Copies the parent path upward layer by layer
5. Produces a new root page at the end

So a single write affects only the dirty path from the root to the target leaf, not the entire tree.

The current implementation round covers the `put`, `delete`, read-cursor,
and explicit `compact` paths. Reclaim currently covers the page objects
that are replaced by normal commits:

- old pages from the rewritten tree path are tracked for reclaim
- the previous allocator state page is tracked for reclaim after the new
  allocator state page and meta page commit successfully

## 5. Transaction Model

### 5.1 Transaction Types

The database has two kinds of transactions:

- read transactions
- write transactions

Read transactions:

- bind to the current valid meta page at creation time
- hold their own `txid`, `root page`, and `allocator snapshot boundary`
- see a stable snapshot for their entire lifetime

Write transactions:

- at most one exists at any given time
- start from the most recently committed state
- generate new pages and a new root through COW
- increment the global `txid` after commit

### 5.2 Concurrency Semantics

The concurrency model is defined as:

- multiple read transactions may execute concurrently
- write transactions may coexist with read transactions
- write transactions may not commit concurrently
- read transactions can continue reading their snapshot without waiting for a write transaction to finish

This is what `MVCC` means in this document: not multi-writer concurrency, but version isolation under a single-writer, multi-reader model.

### 5.3 Read Transaction Snapshots

When a read transaction starts, it fixes the following information:

- the currently active meta page
- the current root page ID
- the currently visible transaction ID

Even if a write transaction commits a new version afterward, the read transaction continues using the old root to read the old pages. As long as those old pages have not been reclaimed, the snapshot remains stable.

### 5.4 Write Transaction Commit Order

A write transaction commits in the following order:

1. rebalance / split: reorganize dirty node structures
2. spill: serialize dirty nodes into new branch or leaf pages
3. update allocator state and record newly allocated pages and pages pending release
4. write all dirty pages
5. `fsync` or equivalent persistence
6. write the new meta page
7. `fsync` again
8. treat the new meta page as the current active version

This is the typical double-meta-page plus two-phase persistence-entry switch design:

- if the process crashes halfway through writing data pages, the old meta page still points to the old tree
- the new tree becomes visible only after the new meta page has been successfully persisted

### 5.5 Rollback

When a write transaction rolls back:

- discard new pages that have not yet been committed
- do not update the meta page
- immediately release dirty pages that were allocated only by this transaction and never committed

Because committed pages are never modified in place, rollback does not need to restore old contents. It only needs to abandon the new version.

## 6. Space Allocation and Reclamation

### 6.1 Why Use a Buddy Allocator

`zbolt` plans to use a buddy allocator as its primary allocation strategy for the following reasons:

- it is better suited for managing `page object`s of different `order`s and naturally fits large-object allocation
- its split and merge logic is clear
- it expresses contiguous space at different orders more naturally than a simple freelist

It is responsible for:

- allocating `page object`s of different `order`s from free space
- tracking available blocks at different `order`s
- merging adjacent free blocks when conditions allow

It is not responsible for:

- transaction visibility checks
- read-snapshot version management
- dirty-page commit ordering

Those are still controlled by the transaction layer and the MVCC layer.

### 6.2 Delayed Reclamation

When a write transaction deletes a key, merges nodes, or replaces an old path, the old pages do not immediately return to the allocatable pool. Instead, they enter a pending-reclaim state.

A pending-reclaim page should record at least:

- which committed transaction released it
- the page ID range
- the corresponding `order` or `span size`

Only when the following condition holds may an old page truly re-enter the free-block set of the buddy allocator:

- all read transactions with `txid <= release_txid` that could still reference the page have finished

This is the handoff point between MVCC and the allocator.

In the current first implementation, the reclaim watermark follows the
writer's `base_txid` direction:

- a pending item records the highest snapshot `txid` that may still see
  the old pages
- an item becomes safe only after the oldest active reader has advanced
  past that `base_txid`

The current allocator state format persists pending reclaim:

- v1 allocator state pages are still readable as legacy free-list-only state
- new commits write v2 allocator state pages with both free blocks and
  pending-reclaim records
- each pending record stores the page ID, `order`, and highest snapshot
  `txid` that may still see the old page object
- when a database is reopened, there are no active read transactions from
  the previous process, so restored pending records are released into the
  in-memory buddy allocator before the next write transaction
- the release result is written back on the next successful commit; if the
  process exits before then, the pending records can be restored and safely
  released again on the next open

### 6.3 `pending free page` and the Shrink Strategy

`zbolt` explicitly plans to adopt an `MVCC + pending free page` space-reclamation model, and its shrink strategy is intended to stay aligned with `redb`.

Specifically:

- old `page object`s released by a write transaction first enter the `pending free page` set
- logically, `pending free page`s are still part of the database's known space, but they cannot be reused until the safety condition is satisfied
- after all read transactions that could reference those pages have finished, the pages may be safely returned to the buddy allocator
- reclaimed space is reused by later allocations first, rather than automatically shrinking the database file

At the two levels of reuse inside the file and physical shrinking of the database file, `zbolt` defines the behavior as:

- normal operation path: rely on `pending free page` plus the buddy allocator to reuse free space
- explicit shrink path: compact the database file through `compact`

The expected responsibilities of `compact` are:

- read the current latest consistent snapshot
- rewrite a new, more compact database file
- skip all unreachable pages and old-version pages that no longer need to be preserved
- switch to the new file through atomic replacement or an equivalent method after validation completes

The current first implementation narrows that path deliberately:

- `compact` still rejects concurrent write transactions
- it rewrites only tree pages referenced by the latest committed snapshot
- it emits identical `meta0/meta1` pages with the same logical `txid`
- it clears persisted pending reclaim by replacing the file with the compacted layout

Therefore:

- explicit compression through `compact` is supported
- safe reuse and release of free space through `MVCC + pending free page` is supported
- `redb`-style automatic trim is not planned

The reasons for not doing automatic trim are:

- under the expected workloads, the benefit of automatic trim is usually limited
- it would significantly increase the implementation complexity of the allocator, file layout, recovery path, and remap flow
- free-space reuse plus explicit `compact` is already sufficient for most real-world needs

### 6.4 High Water Mark and File Growth

If the buddy allocator cannot satisfy an allocation request, the database must grow the file:

- expand the file size
- expand the mmap mapping
- generate a new base-page range and attach it to the allocator
- update the high water mark

The normal commit path does not proactively shrink the database file. Physical shrinking is handled uniformly through explicit `compact`.

## 7. mmap Read/Write Model

### 7.1 Goals of mmap

`mmap` is primarily used to optimize the read path:

- page data can be read directly from mapped memory
- read transactions can return in-page byte slices with zero-copy semantics
- range scans and cursor traversal are cheaper

### 7.2 Relationship Between the Write Path and mmap

Write transactions must not modify committed pages in place through mmap. Instead they should:

- build dirty pages or higher-order `page object`s in heap memory or page buffers
- flush them to disk at commit time through `pwrite` or file-write interfaces
- switch versions through the new meta page only after persistence is complete

So mmap is a window for reading committed versions, not a channel for updating the database in place.

### 7.3 mmap Remapping Considerations

After file growth, remapping may be required. At that point, the implementation must ensure:

- active read transactions must not hold raw pointers that can become invalid
- transaction lifetimes must be designed to remain stable
- long-lived read transactions extend the lifetime of old pages and increase pressure on database growth

This is why read transactions should not be held indefinitely.

## 8. Read and Write Flows

### 8.1 Opening the Database

The database open flow should be:

1. Open or create the file
2. If the file is empty, initialize `meta0`, `meta1`, and the minimal root structure
3. Acquire a file lock or an in-process write lock
4. Read and validate the two meta pages
5. Establish the mmap mapping
6. Restore the current root, allocator state, and global txid
7. Restore the `base page size` and the allocator's order view

### 8.2 Read Flow

A typical read operation is:

1. Begin a read transaction
2. Fix the current meta snapshot
3. Descend the B+Tree from the root
4. Locate the key in a leaf page
5. Return the value
6. Close the read transaction

### 8.3 Write Flow

A typical write operation is:

1. Begin a write transaction
2. Load the current root snapshot
3. Locate the target leaf
4. Perform COW updates on the dirty path
5. Generate new pages and a new root
6. Mark old pages into the pending-reclaim queue
7. Write dirty pages
8. Write the new meta page
9. Commit successfully and release the write lock

### 8.4 Delete Flow

Deletion does not immediately free space. Instead it:

1. Removes the key from the new-version tree
2. May trigger leaf or branch rebalance
3. Moves old-version pages into pending reclaim
4. Hands them back to the allocator for reuse only after the read-transaction boundary advances

## 9. Crash Recovery and Consistency

### 9.1 Sources of Consistency

The current design's consistency guarantees mainly come from:

- committed pages are never modified in place
- new data pages are written before the new meta page
- the two meta pages preserve the two most recent commit-entry points
- the meta checksum is used to detect partial writes or corruption

### 9.2 Recovery Strategy

During recovery:

1. Read `meta0/meta1`
2. Select the newest meta page whose checksum passes validation
3. Restore the root and allocator root from that meta page
4. Discard any new pages that are not referenced by a valid meta page

If more recoverable information is stored in allocator state pages in the future, the same principle must still be followed: only data referenced by a valid meta page is considered part of committed state.

## 10. Implementation Mapping

This document describes the target architecture for future implementation. It does not imply that the repository already contains all modules. The current status and future module mapping are as follows:

### 10.1 Planned Module Boundaries

The following module responsibilities are planned to emerge incrementally:

- `db`
  - exposes the public database API
  - manages lifecycle
  - assembles modules such as `storage`, `meta`, `tx`, and `tree`
- `storage`
  - file open/close
  - file locking
  - mmap initialization and remap
  - translation between page IDs and file offsets or mapping addresses
  - file growth
  - low-level I/O support required for loading the current meta page
- `meta`
  - meta encoding/decoding
  - checksum
  - double-meta selection
- `page`
  - page-header definition
  - parsing of branch, leaf, meta, and allocator pages
  - `page object` span handling
- `allocator`
  - buddy allocator
  - free-block splitting and merging
  - allocation and release of `page object`s by `order`
- `reclaim`
  - `pending free page` management
  - advancing the reclaimable boundary according to the oldest active read transaction
  - returning old pages to `allocator` at a safe time

At the current stage, `reclaim` is implemented for old tree pages released
by write-path replacement and for allocator state pages replaced by a
successful commit.
- `compact`
  - explicit database-file compaction
  - rewriting data based on the latest snapshot
  - file switching and validation
- `tx`
  - read and write transactions
  - txid management
  - commit and rollback orchestration
  - coordination of `tree`, `allocator`, `reclaim`, and `meta`
- `tree`
  - B+Tree lookup, insertion, and deletion
  - structural adjustments such as split and rebalance
  - mutation logic based on in-memory nodes
  - handing dirty nodes to the transaction layer for spill and persistence
- `cursor`
  - ordered traversal and range scanning

The following constraints should be respected:

- `db` acts only as the facade and composition layer, and does not carry concrete page formats, allocation logic, or tree mutation logic
- `storage` is responsible for files and mapped views and does not understand B+Tree semantics
- `allocator` manages only free space and does not directly decide transaction visibility
- `reclaim` handles MVCC delayed reclamation and serves as the bridge between `tx` and `allocator`
- `tree` is responsible for tree structure and node transformations and does not directly control commit ordering
- `tx` is responsible for commit orchestration and coordinates dirty-page spill, meta switching, and reclamation advancement

## 11. Phased Trade-Offs

### 11.1 Suggested Implementation Stages

To land the system quickly, the implementation can be staged as follows:

1. File initialization plus meta encoding/decoding
2. mmap plus page abstraction
3. Read-only B+Tree traversal
4. Single-writer transaction plus COW commit
5. Minimal page-based allocator
6. Full `2^k` buddy allocator
7. `pending free page` plus MVCC delayed reclamation
8. cursor and range scans
9. Explicit `compact` compaction

## 12. Reference Implementations and Trade-Offs

This design mainly references the following projects:

- `etcd-io/bbolt`
  - provides the core reference for the single-file model, double meta pages, page-type division, single-writer multi-reader semantics, and commit order
- `cberner/redb`
  - provides additional perspective on MVCC, delayed reclamation, allocator state management, and ways to model buddy or region allocators
