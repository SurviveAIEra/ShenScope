# Competitive reference notes

Inspected actual source before Core implementation. See reference_lockfile.json
for immutable upstream revisions, licenses and inspected paths. Upstreams are
research dependencies under /workspace/references, not part of authored code.
All behavior below informs independent Julia APIs; no line-by-line translation.

| Module | Source observations | ShenScope design |
|---|---|---|
| Agent loop | Pi separates internal messages/events from model projections; DeepSeek tools use rolling bounded pools, exclusive barriers, model-order commit and drain on abort | Typed Julia internal transcript; per-provider projection; Task/Channel scheduling with explicit barriers and cancellation receipts |
| Requests | Kimi gates each request and composes cancellation; OpenCode retains provider metadata at conversion; Qwen distinguishes protocol-specific reasoning knobs | Immutable request-time model/key snapshot, capability validation, native metadata keyed by provider/model; no incompatible replay |
| Budgets | Codex estimates the assembled request including tools/instructions and rechecks restored evidence | Shared atomic reservation ledger; include schemas and instructions; estimates distinguished from backend-reported usage |
| Context | ZCode separates steering/queued messages, compaction and rapid-refill tracking | Durable goal/work state outside conversation; turn-boundary steering; observable compaction; no-progress considers results rather than identical names |
| Session | Pi has versioned headers, parent-linked branches, usage/model changes and explicit compaction entries | Journal with sequence/checksum, crash handling and side-effect ambiguity; session branching resets approvals while retaining evidence |
| Project map | Aider caches syntax tags and bounds repo-map by token allocation | File-version cache and evidence-based candidate ranking; index facts stay local, selected context carries reason/provenance |
| Semantic data | Serena facade exposes bounded discoverable objects; app is GPL, SolidLSP separately MIT | Independent stable symbol API; backend capabilities/quality explicit; no GPL implementation reuse |
| CodeGraph | GraphBuilder delegates parsing, resolution/persistence, per-thread parser caches; multiple graph DB drivers | Dedicated adapter converts supported graph facts; core Analyzer never sees private schema; independently negotiated capabilities |
| Dynamic compute | Aries uses subprocess JSON-RPC with startup/readiness/death/shutdown callbacks; cooperative cancellation is platform limited | Isolated Julia experiment child with OS enforcement and output/resources caps; fail closed when isolation unavailable |
| Process lifetime | Hermes tracks scoped environments/idle reaping and caches disk warnings | Session-owned handles, explicit cleanup and bounded logs; storage guard before heavy builds; no directory replication |
| IDE | Code-OSS SidebarPart uses native view/service registries; VSCodium has staged platform packing | Native Workbench contribution and separately packaged VSIX share transport/UI models; minimal pinned overlay without copying the whole tree |

Research uses the full project × capability inventory in `capability_matrix.md`.
Cross-check the relevant source/test implementations from every applicable
project before closing a capability domain; a few selected modules are not a
substitute for the complete inventory.
No claim of superiority follows from language features or line counts.
