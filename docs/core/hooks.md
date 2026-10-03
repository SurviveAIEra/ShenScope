# Lifecycle Hooks

Julia Core discovers and executes the same configured command hooks for agents,
durable workers, CLI, VSIX and native Workbench. This is an independently authored
protocol, not an implementation of an upstream shell-hook dialect.

## Configuration and discovery

Inline declarations use `[hooks]` with `[[hooks.entries]]` in Core configuration.
Project sources default to `.shenscope/hooks.toml`; user sources require explicit
absolute file paths. Each separate source contains `[[hooks]]` declarations.
Sources are read through the permission engine, reject symlinks and protected
Git/secret paths, retain content hashes and load atomically. Duplicate names in
one file fail validation. Identical names in different files retain distinct
source IDs and both run; an ambiguous name requires selecting an ID.

```toml
[hooks]
enabled = true
project_files = [".shenscope/hooks.toml"]
user_files = []
disabled = []

[[hooks.entries]]
name = "review-write"
point = "before_tool"
tools = ["write", "edit", "patch"]
argv = ["python3", "-B", "checks/review.py"]
cwd = "."
timeout = 10.0
output_limit = 32768
on_failure = "deny"
allow_context = false
replay_safe = false
```

The catalog caps declarations at 128 by default (maximum 256), configuration
files at 128 KiB, source lists at eight files per scope and workspaces at 32.
Inline declarations also bind the Core configuration file digest. Changes to a
source require explicit reload and another review of the new process target.
Changing Core configuration externally requires reloading Core configuration;
catalog reload does not silently replace the Core settings snapshot.

Names, points, booleans, argv, timeout and environment bindings are validated.
Arguments are literal strings. No shell evaluation, interpolation, regular
expression matcher or HTTP/prompt hook is implied. Exact tool-name matchers are
supported. Unknown declaration fields fail validation.

## Lifecycle and output

Supported points are `session_start`, `before_model`, `after_model`,
`before_tool`, `after_tool`, `after_edit`, `after_test` and `session_end`.
Session start/end describe an agent invocation, including resumed invocations.
After-edit fires only after a successful Core edit/write/patch result. After-test
fires for completed `process` calls explicitly marked `purpose = "test"` and
for durable test workers; arbitrary shell commands are not inferred to be tests.
The test outcome uses actual process exit/timeout evidence. Post-tool observation
includes failed calls, while unstarted tests produce no after-test observation.

Core writes one versioned JSON document to stdin, including invocation
and hook IDs, point, workspace/session identity, test mode and a small scalar
metadata object. Chat text, tool arguments, tool output and model keys are never
included in this default input. `hooks test` executes the real configured command
with synthetic lifecycle metadata; it is not a dry run. A command may close or ignore stdin; successful exit/output
still determine its result, while `stdin_written` records whether Core completed
the write. This flag does not prove that the receiver consumed the document.

Empty stdout means continue. Otherwise stdout must be one bounded UTF-8 JSON
object with optional `version`, `decision`, `reason` and `context` fields:

```json
{"version":1,"decision":"deny","reason":"Review this write first"}
```

Decisions are `continue`, `deny` and `stop`. Duplicate keys, unsupported fields,
excessive nesting, malformed JSON and truncated output are rejected. Reasons
have a 1024-byte cap. Context requires `allow_context = true`, has a 4096-byte cap
per outcome and a 16 KiB/16-entry runtime queue. Context is consumed by the next
model preparation, not persisted as conversation history. Session-end context
is rejected because there is no subsequent request.

Deny/stop decisions and `on_failure = "deny"` are valid only before an operation.
Stop requests finish recording already completed tool results before ending the
agent batch. Post-effect hooks cannot replace a successful result or undo a write.
Their failures remain separate observations. `on_failure = "warn"` continues with
a visible outcome; it does not convert a denied process permission to approval.

## Permissions, execution and recovery

Every command uses Core process permission with an argv/cwd/environment-source/
declaration/source-digest target. Core rechecks source identity, enabled state,
working directory and current Deny policy after approval. Bound environment
values use named environment or secure-storage references. Only a small platform
environment is inherited; arbitrary model keys and unrelated environment values
are excluded. Known bound values are redacted from structured reasons/context.
This redaction is not a general detector for secrets a trusted command reads
from the host filesystem.

Execution shares the owner budget and cancellation lineage, reserves one step,
caps eight simultaneous commands and bounds stdin writing, captured stdout/stderr
and timeout. Raw stdout/stderr are not emitted or retained in public hook events.
Public invoked/result pairs retain IDs, status, decision, controlled errors,
exit code, byte counts and duration. History is bounded (256 entries by default)
and scoped to the workspace/conversation. It is currently in memory; durable
hook audit history, asynchronous fire-and-forget hooks and output artifacts are
unfinished.

On Linux, the shared process executor terminates owned process groups, including
descendants remaining in that group after the leader exits, and drains/closes their pipes.
Windows currently terminates only the direct child. Host commands are not an OS
sandbox: their filesystem/network actions are not mediated by each Core read,
edit or network rule. Filesystem identity checks do not eliminate local races.

Durable workers default unknown hook commands to an exclusive workflow slot.
Before launch, a lease/token/generation-fenced journal write marks that a hook
may have begun external effects. Lease expiry, cancellation or retryable failure
then requires reconciliation even when the original tool is a replay-safe read.
No hidden automatic replay occurs. A new `hook_started` receipt phase makes older
Core versions reject such journals rather than silently ignore the new execution
semantics. Ordinary older receipts remain readable. `replay_safe = true` is an
explicit operator assertion that the command is safe to repeat; it grants no
permission and must cover the command's complete behavior. Effect barriers are
per workflow, not a global lock across all agents/workflows in a workspace.

## Clients

```sh
shenscope hooks list --root /workspace/project
shenscope hooks source review-write --root /workspace/project
shenscope hooks test review-write --root /workspace/project --allow-process
shenscope hooks reload --root /workspace/project
```

CLI command-test failures return exit status 2. Recent history exists only in
the current manager process; a separate CLI invocation does not restore it.
Core RPC exposes `hooks/start`, `hooks/job`, `hooks/cancel_job`, `hooks/query` and
`hooks/source_path`. Jobs cap at eight running/64 retained, 4 MiB per result and
16 MiB aggregate retained results. Job tests block conversation agent starts;
configuration changes block active jobs/runs. Source opening consumes a recent,
completed, owner-scoped read proof with source identity/hash and current Deny
checks, including configured user files outside the workspace.

Both editor views show point, name, source, enable state, recent status/error,
command details, explicit test, reload and approved configuration opening.
They share Core CAS configuration and support inline command creation, project/
user source lists and global/per-source disable controls. Declaration-level
disabled project/user hooks are enabled by editing their own source file.
Compaction/permission-notification/plugin package hooks and upstream dialect
compatibility remain pending; permission hooks never get an implicit grant path.
