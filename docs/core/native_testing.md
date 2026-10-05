# Editor Testing integration

The Tests view can publish a discovered command catalog into the editor's
ordinary Testing explorer with **Show commands in Testing**. The standalone
VSIX uses `vscode.tests`; the native Code-OSS client registers a Workbench test
controller directly, including when extension hosts are disabled. Neither client
needs a Python or JavaScript test extension for these published commands.

These entries run project **commands**, not independently discovered test
functions. For example, Python unittest discovery and a package's JavaScript
test script appear as separate runnable entries. Framework-reported child cases
appear after a run and are not individually runnable. Their IDs belong to that
execution receipt, not a stable project-wide test registry. Commands without
recognized case output can still have a successful observed process result;
that does not establish that any tests were collected.

## Ownership and execution

Publication binds the controller to the catalog's workspace, state directory
and conversation. Opening another conversation does not silently rebind it.
Discover and publish that conversation's commands explicitly to replace the
collection. Replacement is refused while its native run remains active.
Publication currently needs effective Read Allow for the owned catalog and
its declaration markers. An Ask policy can discover through an approved job,
but synchronous publication does not present a separate read-approval dialog.

Run All and command selections of one to sixteen entries use the same original
Julia implementation, `run_project_test_set!`. Core validates the entire
selection before launching the first process. Commands run in selection order,
with independent Process checks, fresh declaration validation after approval
and a shared cancellation/budget scope. The default continues after a known
command failure; SDK/tool callers can request `stop_on_failure=true`. Invalid,
duplicate, foreign or stale selections are rejected. One command's authorization
does not authorize a different command or absolute working directory.

An Allow-for-session process grant identifies the absolute directory and full
content-bound command, including declaration hashes. Rediscovering the same
declarations can reuse that grant. A new catalog timestamp alone does not ask
again; changed declarations, arguments or directories require a new decision.
Read, Process and Persistence remain independent permissions.

## Core result projections

`project_test_editor_catalog` exposes owned command identities and discovery
coverage. `project_test_editor_result` exposes a bounded editor projection of an
owned execution receipt. The versioned schemas are
`shenscope.editor-test-catalog/1` and `shenscope.editor-test-result/1`.

Core maps observed command outcomes and separately maps framework-reported
case states to passed, failed, skipped or errored. Editor code only adapts those
states to each Testing API. Receipt hashes, observed counts, output truncation
and interpretation limits remain explicit. Default projections include at most
32 cases, 16 source references and 8 KiB of plain output per stream, within a
192 KiB object limit. Terminal escape sequences are removed from editor output;
the original captured output remains in the retained receipt.

Run sets cap individual receipts at 512 KiB and default captured streams at
64 KiB each, also respecting tighter manager retention limits. Their aggregate
controller result remains within the existing 4 MiB operation bound. Command
progress can arrive before the aggregate result. A missing final result does
not erase a process receipt already retained by Core and does not establish
that the command had no effects.

No source URI or error location is assigned to an individual reported case:
the current parsers do not establish that association. Source references remain
available through the existing explicit preview path. Historical source
certification, coverage artifacts, automatic watching, individual test
discovery/reconciliation and Debug/Coverage profiles remain future work.

## Transport recovery and cancellation

The editor generates one `client_request_id` for `testing/start`. Core checks
duplicate IDs and registers the job under the same operation-manager lock.
An opt-in `testing_job_started` event supplies the owned job identity before
execution. Progress and approvals must match its conversation and trace.

If the start response is lost, the adapter uses the announced job or
`testing/find_job` to find that already registered job. It never resends the
start operation. Start responses and owned job views include their trace ID,
so losing the start notification does not prevent recovered approval handling.
Early approval/progress notifications wait in a buffer of at most 64 entries
and 512 KiB estimated UTF-16 JSON bytes until the trace is known; only matching
events are then applied. Overflow requests cancellation and reports uncertainty.
Native cancellation requests `testing/cancel_job` and closes
pending editor approval pickers. Denial is not interpreted as command success.
Transport loss reports uncertainty rather than silently restarting a command.

Correlation is bounded, in-memory job retention, **not** a durable exactly-once
service. Retired jobs and Core restart remove this lookup evidence; clients
must not infer that an absent job proves no execution occurred. Current Read
policy gates result delivery and hides evidence when access is denied.

The grouped SDK result uses `shenscope.project-test-run-set/1`. Tool action
`run_set` exposes the same implementation. CLI/TUI retain their existing
single-command controls; direct grouped controls there are not yet implemented.
Explicit saved history is separate from native Testing result persistence; see
[project_test_history.md](project_test_history.md).
