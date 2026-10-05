# Saved project test results

ShenScope can explicitly save an execution receipt from its owned in-memory test
manager. The saved receipt retains the captured command, exit status, timeout or
cancellation flags, bounded output, framework-reported cases and source references.
Reading the saved result after restarting Core does not launch its command.
This works with the language-independent argument-vector runner and each of the
six currently supported reporting formats. Runner installation is independent.

## Ownership and storage

The store belongs to the exact workspace, state directory and conversation. Its
path is `STATE/project-tests/WORKSPACE_SHA256/SESSION_SHA256/history.json`.
Reads require Read permission. Saving, renaming and deleting also require
Persistence permission; they never require Process permission. Plan mode can
read saved results but cannot change this store. Source previews independently
authorize the current workspace file and can check its expected content digest.
They do not establish the source snapshot that existed during execution.

One atomic snapshot contains at most 32 saved results, at most 4 MiB per receipt,
and at most 16 MiB of serialized JSON including metadata. Limits apply to each
conversation, not to all conversations combined. Encoding, decoding, nesting,
node counts and interpreted case/reference counts are bounded. These simultaneous
bounds can reject a save before the record-count limit. A save never silently
retires an existing saved result. Delete a selected record to release capacity.

There are no project-directory backups or per-revision snapshot copies. A write
temporarily stages one bounded JSON document, flushes it, checks current policy
and the previous history digest, and atomically replaces the current snapshot.
Normal completion removes the temporary stage. Before another publication, the
shared staging helper can reclaim independently identified Core stages belonging
to a dead process and older than one hour. Unknown files and live stages are
preserved; staging count/byte limits can reject further publication.

The snapshot and each receipt have content digests. These detect corruption and
changed content; they do not authenticate against an external actor who edits
the filesystem and recomputes digests. Unsupported coverage/source-certification
claims, foreign owners, unsafe source references and inconsistent receipt
identities are rejected. Linux atomic publication and cross-process contention
are tested; Windows source uses shared storage primitives but runtime validation
on Windows remains pending.

## Revisions and interrupted delivery

Each changed save, rename or deletion increments the history revision. Writers
must supply `expected_revision`; a cross-process lock and a final content check
prevent stale edits from replacing another write. Identical saves or labels at
the current revision are no-ops. Pagination can require the expected history
digest to avoid combining different snapshots.

An owned operation records `testing_history_committed` only after publication.
Cancellation, budget expiry or notification failure afterward cannot roll back
the saved record. The job may fail to deliver its result while still retaining
a minimal committed-effect receipt. Current Read denial hides both result and
commit evidence. Refresh the owned history to determine what persisted; a
delivery failure must never trigger automatic test replay.

## Interfaces

The `testing` tool adds `history_list`, `history_get`, `history_source`,
`history_save`, `history_label` and `history_delete`. Save only accepts a run ID
from the manager in the same runtime scope; arbitrary client JSON is not accepted
as evidence of a Core execution. Async controller operations use `testing/start`;
read-only queries use `testing/query` when Read is currently Allow.

CLI examples use the same root, state directory and session on each invocation:

```sh
shenscope tests custom --argv '["python3","-m","unittest","discover","-v"]' \
  --framework unittest --save --expected-revision 0 \
  --allow-process --allow-persistence --session review
shenscope tests saved --session review
shenscope tests show RUN_ID --session review
shenscope tests rename RUN_ID --title 'Before repair' --expected-revision 1 \
  --allow-persistence --session review
shenscope tests forget RUN_ID --expected-revision 2 \
  --allow-persistence --session review
```

The default CLI test session is `cli-tests`. A failed test with a successful save
still exits 1. A save failure exits 2 and prints the observed process receipt
together with the persistence error; it does not repeat the command. Normal
controller results remain in-memory until explicitly saved.

The shared VSIX/native Tests view provides Save, saved-result names, reopening,
source previews and selected deletion. Core owns the record and its revision;
the client stores IDs and temporary view state. Session changes discard late
read responses. Integration with the editors' built-in Testing API is a separate
unfinished feature.

Validation: `test/project_test_history.jl`,
`editors/test/projectTestHistory.test.mjs` and
`ide/test/native_smoke.mjs --testing-only` (also `--vsix`). See the checkpoint 040
validation record for actual results and retained failures.
