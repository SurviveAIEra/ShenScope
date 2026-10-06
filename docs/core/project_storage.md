# Derived project index storage

The project journal stores derived source facts and metadata. `compact_project!`
replaces obsolete index transactions with one complete snapshot of the current
facts. The logical revision, symbols, relations, occurrences, types, diagnostics
and configuration/input identities remain the same. Subsequent updates continue
at revision + 1. This operation intentionally removes older derived index
transactions; conversation and durable-task journals are separate stores.

## Snapshot and replay

The snapshot starts with a versioned owner/revision/metadata header, a generation
UUID, expected file count and content fingerprint. Sorted file records and a
matching commit follow. Each frame retains the existing sequence/checksum schema.
The fingerprint hashes owner/revision/metadata and each complete file-fact leaf.
Hashes detect corruption and identity differences; they are not signatures or
proof that a malicious author supplied truthful semantic facts.

Replay processes one bounded frame at a time, keeping the current graph and
pending transaction rather than an array of the entire journal history. It
validates frame fields, JSON bounds, revision/transaction boundaries, snapshot
ownership/fingerprint, file counts and graph endpoints before installation.
Ordinary pre-snapshot journals remain supported. Snapshots may begin at revision
zero for a deliberately committed empty index. Duplicate/foreign file entries,
tombstones inside snapshots, misplaced snapshot headers and invalid commits fail.

Incomplete ordinary appended transactions/torn tails recover by truncating to
the last committed byte offset. A damaged initial snapshot is rejected and left
intact. Recovery requires Persistence authorization; Read alone cannot truncate
the cache. The source files need not be re-read to recover or compact their
existing cached facts; normal index refresh and navigation still enforce their
own source/configuration checks.

## Atomic publication and concurrent writers

Compaction authorizes Read and Persistence, validates the current facts, checks
the expected revision and holds the resident-state mutex plus the existing OS
journal lock. A bounded streaming writer flushes a private staging file, rechecks
cancellation/budget/permissions and the cached physical identity, then atomically
replaces the journal. Unix publication flushes both rename directories. Failure
before rename discards the staging file and preserves the published journal.
A failure during the post-rename directory flush can leave the valid replacement
visible but its durability uncertain; reload before another write in that case.

Each resident state records file device/inode/size/mtime/ctime. Append/compaction
verify that identity under the OS lock and update it before releasing the lock.
A same-size replacement therefore rejects a stale process on the validated Linux
filesystem, even when the logical revision is unchanged. Writers must cooperate
with the lock. This does not claim adversarial OS isolation or validated Windows
file-identity behavior.

By default a replacement must save at least one byte; otherwise it is discarded.
`minimum_savings` can demand a larger saving; explicit `force=true` may grow a
small journal. The 128 MiB journal/stream cap remains. A graph too large to fit
one supported snapshot fails without silently dropping facts. Ordinary deltas
can contain up to 20,000 remove/add entries while the committed index remains
bounded to 10,000 files. Each frame retains its configured 16 MiB default cap.

## Owned staging cleanup

Staging uses a private `.shenscope-staging` directory and an owner descriptor
created before data is written. The descriptor names the destination, a unique
temporary file, owner PID and creation time. Normal completion, rejection,
capacity errors and cancellation remove the owned files. A hard-killed process
can leave its incomplete staging data. A later compaction reclaims only matching
destination descriptors whose processes are proven dead on Unix, with ownership,
symlink and descriptor checks immediately before removal.

Live or unknown processes, another destination, malformed descriptors, symlinks
and unclassified files are retained. Empty unidentified files can remain if a
process dies before its descriptor is created. Windows process-liveness cleanup
is not implemented. Application source folders, dependency checkouts and user
conversation history are never selected by this cleanup routine. The staging
directory is excluded from project source enumeration.

## Use and validation

```sh
shenscope project compact --backend typescript --root . --state-dir .local/state --allow-persistence
shenscope project compact --backend go_ast --root . --state-dir .local/state --minimum-savings 65536 --allow-persistence
JULIA_DEPOT_PATH=/workspace/julia-depot julia --startup-file=no --threads=4 --project=. test/project_storage.jl
```

The project tool and asynchronous `project/start` share this operation. Its job
poll/cancel requires the owning conversation ID. Both editor Project views show
index storage and an explicit **Compact index history** action with Core results.
The operation uses cached facts without launching a parser or calling a model.

Storage tests use an explicitly named fixture backend to exercise independent
storage invariants, not to claim compiler functionality. They include an actual
separate Julia process, a hard-killed writer, same-size stale-writer rejection,
corruption, recovery permissions, capacity, cancelled/expired contexts and safe
staging selection. A separate actual TypeScript integration verifies preserved
navigation/diagnostics and continued updates, plus real CLI compaction. Existing
Go AST/Tree-sitter/CodeGraph and compiler oracles verify the changed replay path.
The GUI flows use actual Core/TypeScript in native Workbench and standalone VSIX.
See checkpoint 014 for raw evidence. No disk-pull failure injection, Windows,
large-graph peak-memory benchmark or live-model result is inferred from these
small Linux fixtures. Saved-source watching is described in [project_watch.md](project_watch.md).
