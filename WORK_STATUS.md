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
Interactive terminal is currently a line-oriented chat loop, not a finished TUI.
No VSIX/native IDE release, MCP integration, graph backend or real OS isolation
is verified yet. Core remains far below the 250,000-line delivery target.

Next: shared versioned protocol and editor clients; durable runtime/context/MCP;
incremental data/backends/analysis; full terminal UI; measured release preparation.

Only tested runnable checkpoints will be labeled verified. Update this file
after each checkpoint and push so another machine can resume without chat state.
