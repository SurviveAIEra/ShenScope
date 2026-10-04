# Scoped persistent memory

Julia owns storage, validation, lexical retrieval, permissions and asynchronous
memory jobs. CLI/TUI, standalone VSIX and native Workbench use the same Core.
The editor Memory view supports browsing, searching, creating, reading, updating,
deleting and viewing retained versions. Import/export are currently CLI/tool/RPC
operations. Memory work does not request a model or launch a process.

## Ownership and durable state

Workspace memory belongs to the canonical project-root digest. Session memory
also proves that root and the conversation ID. User memory belongs to the local
state directory and is intentionally shared across project roots. A store from
another context is rejected. The default namespace preserves its existing
journal path; up to 31 additional named collections have independent journals
and a validated registry. Namespace identifiers are restricted ASCII names,
1–64 characters, beginning with a lowercase letter.

Default collections allow 512 object IDs, 32 MiB journals and eight revisions
per object. Named collections allow 256 IDs, 8 MiB journals and eight revisions.
Tombstones consume object IDs. Content is bounded to 64 KiB; metadata is bounded
separately. Stored records carry owner, namespace, workspace proof, version,
timestamps, content SHA-256, title, tags, declared origin and optional expiry or
source reference. A declared source/reference does not verify factual accuracy.
Legacy workspace/user records remain readable; legacy session records without
a workspace proof are refused and left untouched. Their migration is pending.

CAS writes require the observed version. Deletion records a tombstone and keeps
bounded history; expiry hides an entry from ordinary retrieval. Neither provides
secure erasure. Journal replay checks framing, record hashes, ownership, schema,
version order and content hashes, failing closed on corruption or a torn tail.
File and lock-path symlinks are rejected with confinement checks. These checks
are not an OS sandbox or a race-proof filesystem boundary.

Reads and persistence have independent Allow/Ask/Deny decisions. Once approved,
an operation checkpoints cancellation, shared budgets and current Deny rules.
Internal mutation validation uses persistence authorization without returning
stored content. Import validates the entire bounded input and then commits one
atomic fact batch. Namespace admission uses a separate journal; a newly admitted
empty namespace can remain after a later fact CAS/capacity failure. Cancellation
after a committed write can leave the effect stored: inspect its current version
before deciding whether to retry. Export/import are bounded to 3 MiB.

## Retrieval and evidence

The independent Julia index uses Unicode word normalization and Chinese
character/bigram tokens with original UTF-8 byte witnesses. There is no stemming,
camel-case splitting, embedding or compiler-semantic search. Query syntax supports
optional words, `+required`, `-excluded`, exact quoted phrases and excluded quoted
phrases. Negative phrases exclude the phrase rather than each constituent word.
Queries allow at most 4,096 bytes, 64 unique terms and 16 phrases.

BM25F combines title, content and tags with weights 2, 1 and 1.5, k1=1.2 and
b=0.75. Document frequencies and field averages use the visible, filtered
captured population. Scores represent lexical relevance, not calibrated truth
or confidence. Results expose per-term contributions, field frequencies, matched
terms, source declarations, stored hashes and snippet witnesses. Highlight
coordinates are zero-based UTF-8 byte offsets with exclusive ends; clipping is
by Unicode characters. Evidence lists and response bodies have explicit caps.

Filters cover all/any tags, source kinds, update timestamps, expiry and deletion.
Ordering is deterministic by relevance, key or update time. Cursor pagination
pins snapshot, query, filters, sort, snippet options, scope and expiry evaluation
time. Stale snapshots or changed query options fail instead of mixing pages.
A cursor is not an authentication token; reads remain permission checked. The
UI reuses the completed query for its next page even if draft inputs change.

Index captures retain at most 8 MiB of source documents, 262,144 tokens and
200,000 postings. The four-entry manager cache retains at most 16 MiB of input.
These are source/index limits, not a peak RSS quota. Partial document/token
coverage and omission events are disclosed. Excluded terms in partially indexed
records are checked against stored text to avoid false inclusions. The current
snapshot is revalidated before publication, and writes retire cached indexes.

## Interfaces and validation

The memory tool implements `get`, `search`, `retrieve`, `list`, `status`,
`namespaces`, `put`, `delete`, `history`, `export` and `import`, with action-specific
arguments. Legacy `search` preserves its vector shape. The CLI exposes the same
operations and explicit namespace/session selection. Protocol methods are
`memory/query`, `memory/start`, `memory/job` and `memory/cancel_job`; jobs are owned
by their conversation/root/state scope. Active memory jobs block conflicting
agent/session/config changes. Revoked Read permission hides retained results.

Checkpoint 024 evidence records Linux/Julia 1.11.7 verification. New tests cover
ownership, namespaces, capacities, corrupted journals, CAS, independently computed
BM25F scores, Unicode witnesses, filters, phrases, expiry, pagination, partial
coverage, cancellation, approval ownership, revocation, CLI and cleanup. Both
actual development IDEs are exercised separately. Installed distributions,
Windows, secure erasure, embeddings and independently verified file citations
remain outside this checkpoint's validation scope.
