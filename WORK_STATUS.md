# Work status

Whole request: IN_PROGRESS. The 250,000-line Core goal is not reached.

Read `docs/requirements/reconstruction.md` for the reconciled requirements.
Prepared: 22 shallow upstream research repositories, Julia 1.11.7 from the
verified official OCI layer, one main checkout. Reference notes are recorded
before application implementation. No copied project directories or worktrees.

Verified checkpoint: five streaming model protocols (OpenAI Chat/Responses,
Anthropic, Gemini, Ollama) using loopback HTTP fixtures; provider-native reasoning
replay; bounded tool arguments; retry before delivery only; hash-guarded edits;
process groups, stdin, retained bounded output and cancellation/timeouts;
bounded parallel tools with exclusive barriers; persistent agent loop, context
projection, headless CLI and configuration profiles/CAS. One deterministic
agent fixture repairs a real failing Python unittest. This uses MockProvider,
not a live model; no live-model or multilingual benchmark claim is made.

`test/runtests.jl`: 119 assertions passed on Linux, Julia 1.11.7, four threads,
2026-10-03. Evidence: `docs/validation/core-checkpoint-001.json`.
Interface checkpoint: versioned framed stdio RPC, scoped approval responses,
asynchronous start/steer/cancel, config CAS and in-memory credential snapshots;
30 protocol assertions and 16 terminal assertions passed. Actual PTY validation
verifies TUI task/approval/Unicode write/exit. Node transport talks to the real
Julia Core and rejects malformed child framing (two passing tests).
Standalone VSIX packages successfully (~62 KiB; authored Core source included,
Julia runtime/dependencies must be installed separately). Native Code-OSS
Workbench/shared-process overlay passes the complete upstream client typecheck
and a real GUI HTTP/tool/approval/file-write test with extensions disabled.
This is a development desktop runtime, not a completed desktop distribution.
Full built-in-extension packaging and Windows installer validation are pending.
MCP integration, graph backend and real OS isolation remain unfinished.
Core remains far below the 250,000-line delivery target.

Storage hardening: atomic replacement now uses OS replacement primitives;
Unix file/directory flushes; bounded journal record reads; shared-ledger checks
under its mutex; finite provider/budget values. Windows 64-bit file flush,
replacement and cross-process lock source is present but not runtime-verified.
Broad Linux suite: 165 assertions passed after shared storage changes; targeted
atomic/bounded-record tests: five passed; finite-config tests add two cases.

Full-project research inventory: `docs/architecture/capability_matrix.md` covers
all 22 pinned checkouts. Rows distinguish research directions from verified
implementations; no complete-synthesis or model-quality claim is made.

Memory checkpoint: workspace/session/user namespaces, provenance/content hashes,
CAS, tombstones, eight-revision histories, expiry, lexical BM25 with Chinese
characters/bigrams and atomic import/export. Nonblocking cross-process locks
fix worker starvation under concurrent writes. Broad affected suite: 204 passing
assertions (32 new memory assertions). `docs/core/memory.md` describes limits.

Next: improve editor UI; real project backends/analysis; durable tasks/MCP;
extensions/diagnostics; measured release preparation.

Editor UI checkpoint: compact primary navigation, anchored composer, starter
prompts, safe Markdown/code/file links, grouped tool cards, visible permission
cards, searchable/manageable conversations, structured settings and secure-key
status. Actual native GUI and VSIX Webview flows pass. Full Workbench typecheck
and two Node/Core transport tests pass. V3 Julia-specific requirements have been
rechecked in `docs/architecture/julia_feature_contract.md`; graph work is next.

Only tested runnable checkpoints will be labeled verified. Update this file
after each checkpoint and push so another machine can resume without chat state.
