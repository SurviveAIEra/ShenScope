# Durable tasks

Core owns immutable task definitions, dependency readiness, durable execution
receipts and local workers. Agent tools, CLI and framed RPC call the same Julia
implementation. This is a bounded first implementation, not a complete team
runtime or a sandbox.

## Definition and scope

A workflow has one workspace root, an owning session, a title and a validated
DAG of 1–2048 tasks. Session scope is the default. Workspace scope deliberately
permits other sessions in the same root to operate on it. Task IDs and optional
deduplication keys must be unique. Unknown/missing dependencies, self edges,
cycles and undeclared result bindings fail before persistence.

Each task declares `kind` (tool/test/index/analysis/model), `operation`, JSON
`arguments`, direct `dependencies`, priority, timeout and retry policy. Arguments
are capped at 128 KiB, 32 nesting levels and 20,000 JSON items. Credential fields
are forbidden in definitions. Schema checks apply again after dependency values
are resolved. Tests require foreground process completion; index and analysis
workers call the existing project tool; model workers own an attempt-specific
session. Worker toolkits exclude the task tool, bounding recursive delegation.

Example `workflow.json` inside the workspace:

```json
{
  "workflow_id": "inspect-source",
  "title": "Read source and retain evidence",
  "definitions": [
    {"id":"read","kind":"tool","operation":"read","arguments":{"path":"src/ShenScope.jl"}},
    {"id":"retain","kind":"tool","operation":"write","dependencies":["read"],
     "arguments":{"path":"inspection.txt","content":{"$task_result":"read","path":["text"]}}}
  ]
}
```

```sh
shenscope tasks create workflow.json --root . --allow-persistence
shenscope tasks run inspect-source --root . --allow-persistence --allow-edit
shenscope tasks tasks inspect-source --root .
shenscope tasks get inspect-source read --root .
```

The CLI's default task owner is `cli-tasks`; use the same `--session ID` to access
a conversation-owned workflow. State/config/profile paths use ordinary CLI flags.
`tasks list`, `status`, `cancel`, `recover`, and `reconcile` are also available.

## Execution and failure behavior

Claims are serialized under an OS file lock and checksummed append transaction.
Workers obtain a UUID token plus an increasing attempt generation and expiry.
Start, heartbeat and finish verify the same token and generation. A stale worker
cannot complete after another owner claims the task. Claims consume an attempt
even if the worker fails before start; this conservative admission accounting is
explicit, rather than silently exceeding an attempt limit.

Ready tasks are ordered by priority then ID. Known read-only operations may run
concurrently; other operations form an exclusive barrier within that workflow.
The barrier does not isolate separate workflows or arbitrary external processes.
Process managers are owned by individual executors, so cleanup cannot terminate
an unrelated foreground agent's processes.

Started executions that lose a lease and cannot safely replay become `uncertain`.
Their dependents remain pending. Safe retries require explicit `safe_retry=true`
and a known read operation, with bounded attempts/backoff/jitter. Retryable errors
must also be classified retryable. Failure or cancellation blocks dependents;
cascading cancellation can instead explicitly cancel all selected descendants.
Lease fencing protects journal state, not external side effects. A command may
have changed a file before timeout or before its completion receipt was persisted.

Reconciliation is an explicit CAS-capable operation on an uncertain task with
nonempty evidence: `succeeded`, `failed` or `retry`. Manual retry remains subject
to the original attempt bound. It never invents success based on missing output.

Workers inherit permissions, cancellation and the parent's model budget. Model
work persists a distinct child conversation with workflow/task/attempt metadata,
while progress/approval events retain the parent client owner. A run has bounded
concurrency and a deadline. Process cancellation drains process monitors/readers.
Arbitrary extension methods must cooperate with cancellation; OS isolation and
hard termination of untrusted Julia methods remain unimplemented.

## Persistence and results

One workflow journal lives under `STATE/workflows/ROOT_SHA/ID.jsonl`. Updates and
derived readiness changes commit together. Independent handles reload external
appends under the writer lock. Journals cap at 128 MiB; no automatic task-history
compaction is implemented. Read-only recovery recognizes an incomplete trailing
record without truncating it. A permitted mutation repairs that tail only after
validating the stored root/session scope. Interior corruption fails explicitly.

Results up to 128 KiB remain inline. Larger results up to 8 MiB use SHA-256-addressed
JSON in `ID.results/`, bounded to 64 MiB per workflow. The completion receipt records
the original result digest. Materialization verifies descriptor, size and digest;
returned objects are detached. A dependency binding can traverse string object
keys and one-based array indices of a declared successful direct predecessor.
Internal descriptor-shaped user results are archived to avoid impersonation.
Results are durable user evidence, not disposable build products. Automatic
artifact garbage collection, retention settings and workflow deletion are pending.
An artifact written before a failed journal flush can remain as a bounded orphan.

## RPC

`tasks/start` accepts create/run/cancel/recover/reconcile and returns a `job_id`.
Work and permission events arrive through `agent/event`. `tasks/job` returns a
detached job view; `tasks/cancel_job` requests runner cancellation. Both require
the owning session. `tasks/query` accepts list/status/tasks/get and requires an
already-allowed read policy. Task/config mutations are rejected while incompatible
jobs are active. Config cannot change while any task job runs.

Dedicated task controls in the graphical clients, durable mailboxes, editable
graphs, capability-specific worker pools, resource limits across workflows and
cross-machine scheduling remain pending. The current editor transport continues
to share Core, but no completed Runtime dashboard is claimed.
