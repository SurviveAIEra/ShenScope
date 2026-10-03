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

Full-project research inventory: `docs/architecture/capability_matrix.md` covers
all 22 pinned checkouts. Rows distinguish research directions from verified
implementations; no complete-synthesis or model-quality claim is made.

Next: shared versioned protocol and editor clients; durable runtime/context/MCP;
incremental data/backends/analysis; full terminal UI; measured release preparation.

Only tested runnable checkpoints will be labeled verified. Update this file
after each checkpoint and push so another machine can resume without chat state.
