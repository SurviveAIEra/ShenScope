# Conversation context and evidence

Julia Core prepares model requests from an immutable conversation journal. A
projection can omit older tool rounds, but the original messages remain in the
session. A saved checkpoint belongs to one workspace and conversation and
records its covered prefix, message digests and summary digest. Restoring a
changed, foreign or unbalanced prefix fails instead of silently trusting it.

## Request preparation

Preparation reads applicable instructions, restores explicitly activated Skills,
assembles the system prompt and measures both Core and provider-native request
serialization. Message, tool-schema, option, envelope and wire byte counts are
separate. Output reservation and safety tokens reduce the available input window.
The token count is a conservative byte/Unicode estimate, not a provider tokenizer.
Chinese characters and emoji receive an additional allowance.

Older tool results first receive bounded head/tail previews. If the request still
exceeds its limits, Core selects complete tool rounds for an extractive
checkpoint. Recent rounds, unresolved calls, historical system messages and the
latest actual user directive remain intact. Interleaved steering cannot break a
tool-call/result group. Fixed instructions, schemas or the latest directive that
cannot fit produce a controlled error. They are never silently discarded.

The default instruction names are `AGENTS.md` and `SHENSCOPE.md`. Core reads the
workspace root and ancestors of a bounded recent set of conversation-touched
paths. User files are explicit absolute paths. Sources carry scope, directory,
SHA-256 and approved text; they are read again for every request. Read policy,
size, UTF-8, path and post-approval integrity checks apply. This is not recursive
repository discovery, a filesystem watcher, or glob-based rule matching.

## Configuration

```toml
[provider.capabilities]
context_window = 128000
max_output = 8192

[context]
auto_compact = true
max_request_bytes = 262144
safety_tokens = 1024
recent_messages = 12
tool_preview_bytes = 4096
checkpoint_bytes = 16384
max_sources = 128
source_bytes = 32768
instructions_bytes = 262144
max_paths = 64
recovery_attempts = 2
instruction_names = ['AGENTS.md', 'SHENSCOPE.md']
user_files = []
paths = []
```

Unknown settings, incorrect types, out-of-range limits and duplicate entries are
rejected. Provider capabilities must use positive bounded integers and reserve
less output than the context window. The defaults are conservative application
settings, not automatically discovered model specifications.

## Checkpoints and original evidence

Extractive checkpoints cite bounded excerpts with exact message indexes and
digests. They identify omitted source counts. Saving the derivative checkpoint
requires persistence approval for its conversation; prefix integrity and policy
are checked again after approval. Branches receive their own checkpoint ownership
only when the complete covered prefix exists in the branch.

Tool results have a bounded conversation envelope. Original results up to 4 MiB
may also be saved as digest-addressed artifacts after scoped persistence approval.
Denying that optional archive retains the completed tool result and its bounded
preview without an artifact reference. An approved write is not undone or replayed
because archive persistence was declined. Archive files are read only when the
digest is referenced by a tool message in the owning conversation.

The `context` tool supports status, instruction inspection, UTF-8 message pages
and artifact previews. Message pages return canonical original message JSON,
the current digest and the next byte offset. Source digests are integrity checks,
not authority to read another conversation. The model cannot invoke manual
compaction; it requires an explicit user command.

```sh
julia --project=. -e 'using ShenScope; exit(ShenScope.main())' -- \
  context status --root /path/to/project --session SESSION_ID
julia --project=. -e 'using ShenScope; exit(ShenScope.main())' -- \
  context source 1 --root /path/to/project --session SESSION_ID
julia --project=. -e 'using ShenScope; exit(ShenScope.main())' -- \
  context compact extractive --root /path/to/project --session SESSION_ID
julia --project=. -e 'using ShenScope; exit(ShenScope.main())' -- \
  context compact model --root /path/to/project --session SESSION_ID
```

Optional model summaries use the configured provider without tools and share
the ordinary permission, cancellation, token and cost budget. Bounded strict
JSON must contain objective, constraints, work, next actions and valid citations
to the supplied sources. Duplicate keys, excessive nesting, foreign citations,
tool calls and incomplete output fail without replacing the saved checkpoint.
Reported rejected-request usage is still charged. A valid citation verifies
source identity; it does not prove the model's prose is semantically correct.
The UI labels model summaries explicitly.

## Overflow and interrupted delivery

Known context-overflow errors can trigger at most the configured recovery count.
Every recovery must produce a different request with fewer estimated tokens and
wire bytes. It never reruns completed tools. HTTP transport retries and context
recovery are separate decisions.

Any delivered text, reasoning/native fragment, tool argument, completed call or
usage prevents an invisible recovery retry. Interrupted visible text and complete
undispatched calls are journaled. Resume marks those calls as not executed; it
does not pretend their effects happened. Usage reservations are settled or
released on every attempt.

Cancellation and remaining wall budget are checked after network approval and
before writing HTTP requests. A deadline closes in-flight I/O. These are soft
Julia process budgets: JIT compilation and CPU execution cannot be forcibly
preempted by this mechanism. Host OS isolation remains separate work.

## Clients and validation

Both the standalone VSIX and native Workbench use the same Core RPC operations
and shared Context view: capacity, checkpoints, instructions, original evidence,
manual extractive/model compaction and settings. Operations are asynchronous,
owned by their conversation, cancellable and bounded. Config changes and agent
runs cannot race an active context operation. Approval cards have independent
request identities even when several sources use the same action name.

Process stdout/stderr events now use independent incremental UTF-8 decoders.
Incomplete code points remain pending across reads; malformed bytes produce
replacement characters. The retained raw capture is unchanged. No PTY or OS
sandbox is implied by this decoding improvement.

Executable coverage is in `test/unit/context.jl`, `context_protocol.jl`,
`utf8.jl` and `test/integration/context.jl`. Actual local HTTP fixtures exercise
all five protocols, context rejection, partial delivery and I/O deadlines.
There is no live-model compaction quality result. Large-history indexing,
checkpoint garbage collection, exact tokenizers, media slimming, instruction
watchers and pre/post-compaction Hooks remain unfinished.
