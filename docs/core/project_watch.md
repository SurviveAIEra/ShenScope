# Saved-source monitoring

Core monitors source and compiler configuration changes with `ProjectWatch`.
The default is observation: changes become a pending batch, and the index remains
at its committed revision until the user requests a refresh. Automatic mode
requests the existing indexing permissions and updates after a quiet window.
Neither mode calls a model. Both native Workbench and the standalone extension
Webview expose the same controls, pending paths, retry and stop feedback.

## Scope and snapshots

Recursive enumeration uses `project_paths` and the backend's language list.
Git, dependency/build/cache folders, protected credential directories, staging
files and source symlinks are excluded. Directory pruning precedes cooperative
yielding because Julia's `walkdir` uses a Channel producer; yielding before
pruning can let the producer enter an ignored directory.

Each scan hashes the bounded UTF-8 content of each selected source, rather than
trusting modification time alone. Equal-length edits with preserved timestamps
are therefore detected. The default caps are 10,000 sources, 8 MiB per source and
32 MiB across scanned inputs. TypeScript extraction retains its narrower 24 MiB
program-input cap. Current graph and hash inventory remain resident; one source
text is hashed at a time. These structural bounds do not establish large-project
memory usage or scan performance.

The TypeScript monitor tracks the configured entry, workspace-relative inherited
JSONC files and missing inherited targets. It reads configuration dependencies
without executing compiler plugins or workspace source. Invalid entry JSON
retains known committed dependency paths for continued observation. The actual
compiler configuration validator still decides whether an update is supported.
A removed root entry returns indexing to the backend's default configuration.
Compiler metadata retains a digest of the complete approved source/configuration
inventory, including inputs outside the current root program. A fresh watcher
can verify that digest before accepting its initial baseline; excluded-source
deletions still trigger reconciliation. Older caches without this optional digest
may need one explicit refresh to populate it.

## Events, batches and failure

One owned `FileWatching.FolderMonitor` supplies root directory hints. It does not
claim recursive change coverage. Periodic recursive scans detect nested changes
and converge when hints are missing or unavailable. Hints and explicit refresh
requests share a single-slot wakeup Channel. A separately owned settling Timer
obtains another snapshot after the quiet window, even when the poll interval is
long. Further content changes restart settling; unchanged notifications do not
restart the quiet window indefinitely.

Only a stable changed snapshot is eligible for application. Successful Core
transactions advance the applied baseline. Parser/configuration failures retain
the committed facts, revision and journal and publish a visible error. The same
failed content fingerprint is not retried on every poll. New input content or an
explicit retry permits another attempt. Permission denial, cancellation, an
exhausted shared wall-clock budget and input-capacity errors stop the monitor.
Transient disappearing/conflicting source scans keep the baseline and rescan.

Read authorization covers continuous observation; each scan rechecks revocation
and shared budget/cancellation. Every indexing attempt separately uses the
existing Read, Persistence and Process authorization path. Choosing observation
does not grant writes. Choosing automatic mode does not bypass permission cards.

## Ownership and interfaces

A watcher owns a child cancellation token and shares its conversation's permission
policy, budget and event sink. Stop cancels that child and drains timers, the
native monitor and its task without cancelling the conversation. Status delivery
failure still releases resources. Session/root ownership guards status, stop and
refresh. Managers bound active watchers to 16 and retained records to 32; source
change pages contain at most 100 entries. Lists use smaller bounded previews.

Manual build/update/compaction and watched mutations of the same managed backend
cannot overlap. Direct tool operations reserve the index before any approval
wait. Configuration replacement waits for project jobs, watcher shutdown and
tool reservations. External cooperative journal writers still require an explicit
reload after a physical cache conflict; monitoring does not adopt another
process's cached state implicitly.

RPC methods are `project/watch_start`, `project/watch_status`,
`project/watch_refresh`, `project/watch_stop` and `project/watch_list`.
`watch_start` acknowledges an asynchronous start. `watch_stop` acknowledges
cancellation; the final `project_watch_stopped` event follows resource drainage.
Ready/pending/change/update/error events keep both clients current, including
reverting saved content to the committed state. Both client bridges import a
shared public RPC allowlist.

```sh
shenscope project watch --backend go_ast --root . --state-dir .local/state --allow-process --allow-persistence
shenscope project watch --backend typescript --automatic --json --poll-seconds 1 --quiet-seconds 0.25 --allow-process --allow-persistence
shenscope project watch --backend typescript --automatic --duration 60 --no-native-hints --allow-process --allow-persistence
JULIA_DEPOT_PATH=/workspace/julia-depot julia --startup-file=no --threads=4 --project=. test/project_watch_integration.jl
```

Foreground CLI observation reports pending changes; automatic mode applies them.
Zero duration means continue until stopped or runtime limits expire. CLI/TUI
interactive monitor-management parity remains a later step. This implementation
does not claim live-buffer synchronization, incremental TypeScript checking,
rename semantics, generic LSP federation, Windows watcher validation, large-graph
benchmarks or a packaged desktop/runtime distribution. Checkpoint 015 records
actual small-fixture Linux oracles and GUI evidence; the 250,000-line Core target
and remaining product gates are still in progress.
