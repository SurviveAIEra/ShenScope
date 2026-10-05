# Conversation plans and user-controlled execution modes

ShenScope remains a general development agent. These controls apply to projects
in any language; Julia implements the controls rather than restricting inputs.

`act` is the compatibility default. It exposes the existing working set of tools
and still requires the configured permissions, budget and execution policy.
`plan` narrows the agent's offered schemas to reviewed Core reads and the
conversation-plan tool. File edits, commands/terminals, dynamic code, MCP and
unreviewed plugin tools are unavailable. Schema narrowing also removes mutating
actions from otherwise mixed read/write tools. Direct Core dispatch checks the
same boundary before lifecycle hooks. Names, parallel execution hints and MCP
read-only annotations do not establish eligibility.

The mode is an inherited Julia `ScopedValue`: a new RuntimeContext does not
escape it, asynchronous tasks and threads retain it, and an inner Act request
cannot relax an outer Plan scope. Normal model-network and Read permissions
remain independent. Plan persistence and existing context archives/checkpoints
retain their own permission gates. This is a Core execution boundary, not an OS
sandbox for trusted packages or arbitrary direct system calls. Project queries
that need to start a cold parser/compiler subprocess can still refuse in Plan;
existing resident facts do not require that execution permission.

Only explicit user controllers change the stored mode. The model has no mode
change tool. Settings carry session/workspace identity, hash, logical revision
and branch ancestry in the existing conversation journal. A nonblocking OS file
lock covers the entire agent run and mode update. A second Core process cannot
change a running conversation; a crash releases the lock. Stale session copies
also refuse against the journal sequence. Tiny stable lock files remain; they
are not directory backups and must not be deleted while processes use them.
Linux cross-process/crash behavior is tested. Windows lock source is present,
but this checkpoint does not claim Windows runtime validation.

Plans are reported intent, separate from executable task workflows. Each contains
a title and 1–64 named steps, at most one in progress, at most 16 dependencies
per step, bounded notes and up to eight owned message-hash citations. Unknown or
duplicate dependencies, cycles and starting/completing a step before its
dependencies are reported completed refuse. Reported-completed steps require a
message citation. Citations establish matching conversation bytes, not truthful
claims, passing tests or actual execution. There is no automatic plan execution.

Writes compare the logical revision, revalidate ownership/messages and check
current Read/Persistence permission, cancellation and budget before the journal
commit. A notification failure after saving returns `committed=true` and
`notification_disrupted=true`; readers can still recover the saved plan. The
current plan occupies conversation metadata. History streams the existing
journal and retains only the requested last 1–16 versions, bounded by 128 MiB
of journal and 2 MiB of response. Plan documents are bounded to 96 KiB. No
per-revision folders or whole-project copies are made.

Full branches preserve reported progress and owned citations. Partial branches
preserve intent but reset every step to pending and remove citations after the
branch boundary. Both inherit the parent's mode without silently switching Plan
to Act; each child owns new hashes/revision one with explicit parent ancestry.

Use the same controls in CLI, TUI, standalone VSIX and native Workbench:

```sh
bin/shenscope chat "Inspect the project and prepare steps" --agent-mode plan
bin/shenscope sessions mode SESSION_ID
bin/shenscope sessions mode SESSION_ID act --expected-revision 1
bin/shenscope plan get --session SESSION_ID
bin/shenscope plan history --session SESSION_ID --limit 8
bin/shenscope plan replace plan.json --session SESSION_ID --expected-revision 0 --allow-persistence
```

Replace input has exactly `title` and `steps`; every step supplies `id`, `text`,
`status`, `dependencies`, `note`, `citations`. Progress input has exactly `id`,
`status`, `note`, `citations`. CLI input must be a bounded workspace text file;
Read and Persistence checks apply. `--agent-mode` is an explicit selection for
the chat/TUI launch; later controller edits require a displayed revision.
TUI `/mode [plan|act]` and `/plan` stay local controls and do not become model
prompts. Their asynchronous execution leaves approvals and cancellation responsive.

RPC exposes `sessions/mode` get/set and read-only `plans/query`, `plans/history`.
Unknown fields refuse, with no caller-selected foreign ownership. Queries require
current Read Allow; Ask/Deny refuses rather than blocking the RPC reader on an
approval it would have to deliver. Ordinary session views omit saved plans;
authorized exports include them. Both GUI clients share the composer selector,
reported-progress review card, conversation isolation and saved history restore.
The selector controls chat runs; explicitly invoked project/settings operations
retain their independent existing permissions.

Validation covers real Julia agents reading Python/JavaScript/Rust fixtures,
malicious unoffered write calls, actual Act writes and Act permission refusal,
owned persistence, restart, ancestry, dependency/citation corruption, cancellation,
late revocation, notification disruption, actual cross-process crash release,
real Node/Core RPC, PTY TUI and both actual GUI clients. Agent behavior uses
MockProvider or a local HTTP fixture. This does not establish live-model
planning quality, complete language intelligence or distribution readiness.
