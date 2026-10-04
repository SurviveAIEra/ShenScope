# Compiler semantic project data

`typescript` uses the actual TypeScript 5.9.2 language service and checker. Julia
owns the input snapshot, configuration policy, source coordinates, stable graph,
navigation, permissions, budgets, persistence and analyzers. The small Node helper
returns compiler facts; its lines are excluded from the authored Julia Core count.
It does not evaluate indexed source or load project compiler plugins.

## Input and configuration

The Core scans supported TypeScript/TSX/JavaScript/JSX source under the workspace,
excluding dependency/build/secret paths and symlinks. A virtual compiler host can
read only those approved source documents and the pinned compiler's standard
`lib*.d.ts` files. Unavailable dependency declarations produce compiler diagnostics
or unresolved external references, not invented graph targets. Workspace imports
can bring excluded root files into the compiler program, as in TypeScript itself.

`tsconfig.json` supports bounded JSONC, relative workspace `extends`, multiple
parents, explicit `files`, `include`/`exclude`, approved Boolean/enum options, `lib`,
`baseUrl` and `paths`. Paths use the effective inherited baseUrl or the declaring
configuration directory. Inheritance cycles, duplicate JSON keys, unsupported
options, package-based extends, project references, plugins, external ambient
type packages and emitting options are rejected explicitly. `noEmit` is forced.
The default single project uses ES2022, ESNext/Bundler, strict checking,
JavaScript checking, JSX Preserve, skipLibCheck and no external ambient packages.

Before commit, every supplied source, the complete source file list and all
configuration sources are checked again. Source/configuration changes abort the
transaction. Sources are read with bounded UTF-8 reads and identity checks;
permissions, cancellation and the shared budget are checked before publication.
The installed compiler API and package lock are pinned by setup and CI.

## Facts, coordinates and updates

Declarations include classes/interfaces, functions/methods, overloads, type aliases,
enums, variables/properties/parameters and imports. IDs combine workspace path,
kind, qualified name and duplicate declaration ordinal. Body-only edits retain
IDs; renaming, movement across files or reordering indistinguishable overloads
can change them. Types/signatures, import aliases, references, static calls and
inheritance/implementation links come from the checker. Dynamic `any` calls,
external targets and unresolved calls are counted. Static resolution is not
proof of the target of every runtime invocation.

Compiler positions are zero-based UTF-16. Core ranges use one-based UTF-8 byte
columns with a half-open end. `SourceMap` handles CRLF/CR/LF, Unicode line
separators, Chinese/Korean text, emoji and surrogate/codepoint boundaries.
Sparse checkpoints make repeated long-line conversion bounded by short scans.
Responses cannot introduce foreign source paths, undeclared endpoints, stale
input identities, invalid coordinates, unsupported kinds or inconsistent counts.

The resident compiler reuses document versions and its language service. It still
recomputes semantic facts for the whole program after an input/configuration
change. Julia compares complete facts and persists only changed file facts plus
the new input metadata, then updates local graph adjacency. A signature change
can change facts/diagnostics for an unedited dependent source. This is not a claim
of localized compiler checking or a measured speed advantage. Syntax failure
preserves the prior revision, journal and graph, and a subsequent corrected
update can reuse the helper.

## Navigation and clients

The `project` tool, CLI and RPC support `definitions`, `references`, `hover`,
`incoming_calls`, `outgoing_calls`, `implementations` and `diagnostics`. Choose a
symbol ID or a file/line/column cursor. Cursor input is one-based `utf8_byte` by
default; `utf16` is explicit. Navigation verifies the selected source hash,
configuration identity and optional expected revision/source digest. Results
are deterministic bounded pages with the indexed source digest attached.

Results describe a committed snapshot. Referenced target files can have changed
after indexing; clients should use the returned digest to guard subsequent edits.
Workspace additions require refresh; there is no watcher yet. All-project
diagnostics describe the cached snapshot rather than promising every file is
currently unchanged. There is no rename or complete language-server capability.

The native Workbench and standalone VSIX share a Project view with compiler
status, searchable declarations, type/signatures, definitions, references,
callers/calls, implementations, diagnostic pages and source links. Compiler
queries do not call a model. These diagnostics are currently displayed in the
Project panel; native Problems/Testing/Terminal integration remains pending.
Async indexing owns a child cancellation token and shared conversation policy
and budget. Job polling/cancellation require its owning `session_id`; querying
workspace facts remains separate from conversation messages.

```sh
bash scripts/setup.sh --semantic
python scripts/setup_semantic.py --verify
bin/shenscope project build --backend typescript --root . --state-dir .local/state --allow-process --allow-persistence
bin/shenscope project definitions src/main.ts 8 12 --backend typescript --root . --state-dir .local/state
bin/shenscope project references --symbol SYMBOL_ID --backend typescript --root . --state-dir .local/state --exclude-declarations --limit 30
bin/shenscope project diagnostics --backend typescript --root . --state-dir .local/state
```

The single editor dependency installation supplies the pinned compiler. Alternate
installations use `SHENSCOPE_NODE` and `SHENSCOPE_TYPESCRIPT` pointing to trusted
`lib/typescript.js`. The VSIX includes authored Core/helper source but not Node,
Julia, the depot or TypeScript; install these dependencies separately. Bundled
desktop/extension runtime distribution is unfinished.

## Limits and evidence

Source snapshot: 24 MiB total, 8 MiB/file, 10,000 files. Configuration: 256 KiB/file,
eight inheritance levels and 32 files. Trusted libraries: 32 MiB total. Helper
frames: 32 MiB with strict JSON depth/node limits; stderr retains 64 KiB. Node's
V8 old-generation heap is capped at 512 MiB; this is not a total RSS or OS sandbox
limit. Request waits include blocked input pipes, cancellation, permission
revocation and the shared soft wall-clock budget. Linux helpers own process
groups; Windows descendant ownership remains unverified. Query pages are capped
at 3 MiB; completed RPC results and job retention are bounded. Project journals
retain their existing 128 MiB limit; derived history compaction/streaming replay
are described in `project_storage.md`. Large-graph extraction remains pending.

`test/semantic.jl` runs the real compiler, not fabricated semantic facts. It covers
aliases, methods, implicit constructors, overload choice, type errors, dynamic
calls, source non-execution, both cursor encodings, paging, stale/scope failures,
1/5/20-file full-fact/graph oracles, unchanged dependent rechecking, syntax failure,
deletion, configuration root changes, persistence and forged response rejection.
Separate transport tests use actual blocked/malformed child processes and verify
Linux descendant cleanup. Coordinates include 12,050 property assertions,
reported separately from compiler/backend behavior assertions. Raw evidence and
client screenshots are recorded in checkpoint 013. No live-model, Windows,
large-project performance or full upstream synthesis claim is made.
