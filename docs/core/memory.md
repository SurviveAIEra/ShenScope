# Scoped persistent memory

`memory` is a Core tool shared by the CLI, TUI and editor clients. Workspace
memory is keyed by the canonical project root, session memory by the session
ID, and user memory by the local state directory. Store/context scope mismatches
are rejected. Reads and persistence have separate permission decisions.

Entries carry content SHA-256, title, tags, provenance, expiry and a monotonic
version. Updates and deletion require an observed version. Deleted objects keep
a tombstone, so stale clients cannot recreate an object using version zero.
The default limits are 512 object IDs (including tombstones), 64 KiB content,
32 MiB journal and eight revisions per object. Full history is not retained.

Retrieval uses explicit lexical BM25 scores with Latin word normalization and
Chinese characters/bigrams. Results include matched terms and hashes. This is
not an embedding or compiler-semantic search. Expired/deleted entries disappear
from ordinary retrieval, while version history remains available for auditing.

Import validates all metadata and content hashes before committing one atomic
batch; conflicts, duplicates, capacity errors and denied permission preserve
the existing store. Imported entries receive local scope/provenance and start
at version one. Export includes only visible entries.

Versioned stores serialize access with an OS lock using nonblocking acquisition
and a 30-second timeout, yielding between attempts. This avoids occupying all
Julia worker threads while a lock holder is waiting for filesystem IO. Every
transaction rewrites a bounded snapshot journal and flushes it before atomic
replacement. Large, unbounded project graphs use a separate persistence design.

Verified on Linux with Julia 1.11.7: scope separation, cross-workspace user
memory, reload, Chinese/English ranking, expiry, deletion, CAS contention,
bounded history and all-or-nothing malformed imports. Windows branches remain
unverified at runtime.
