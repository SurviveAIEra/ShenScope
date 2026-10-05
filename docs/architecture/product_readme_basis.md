# Product README source mapping

The Chinese and English READMEs describe the current implementation and its
uses. Source-size goals, checkpoint bookkeeping, environment maintenance and
Git-identity changes belong in engineering records rather than product copy.

The uploaded documents were reread for the following product requirements.
Names and SHA-256 values are recorded in
[the source inventory](../requirements/source_inventory.json). Documents are
design inputs; historical assistant implementation claims do not establish
current functionality.

| Source | Sections reread | Product description |
|---|---|---|
| Design and Implementation Handoff V3 | 8–9, 11–12, 18, 32, 39A.10–15 | Resident project data; backend/analyzer/model separation; local filtering; ordinary Julia analyzers; multiple dispatch; lifecycle and explicit dynamic-call boundaries |
| Full Development Execution Prompt | 1–2, 12–17 | General-language projects; resident caches; incremental/full equivalence; three levels of computation; isolated analyzers; extension validation |
| Code-OSS IDE Continuation V2 | P0–P5, 5–6, 33–35 | Local graph deltas; actual interchangeable CodeGraph backend; capability negotiation; shared Julia Core; validated analyzer reuse |
| Code-OSS IDE Continuation V3 | 1–2, 33–35 | Independent IDE alongside CLI/TUI; targeted validation; analyzer evidence and supported isolation platforms |
| Julia project conversation | 9273, 9372, 10237–10243, 12740–12765 | Native Workbench sidebar plus standalone VSIX; independently implemented Julia Core; Julia-specific extensibility, inspection and programmable analysis |

Current implementation references:

- [Project data](../core/project_data.md), [combined evidence](../core/combined_evidence.md)
  and [language services](../core/language_services.md): distinguish resident
  graph facts, combined saved observations and live configured language servers.
- [Isolated analyzers](../core/isolated_analyzers.md): external fixture checks,
  verified Linux x86_64 isolation, grounded graph results and archive-pointer
  promotion/rollback. The generated-analyzer path does not modify Core source.
- [Julia extensions](../core/julia_extension_lifecycle.md): trusted installed
  packages, actual reflection/dispatch contracts, leases, quarantine and
  deactivation. Module organization and World Age are not security boundaries.
- [Compiler IR](../core/compiler_ir.md), [profiling](../core/runtime_profiling.md),
  [sampling](../core/runtime_sampling.md) and [runtime evidence](../core/runtime_evidence.md):
  current fixed-Core inspection is distinct from arbitrary project diagnostics.
- [IDE](../../ide/README.md) and [VSIX](../../editors/vscode/README.md):
  development runtime and extension package are available through build flows;
  a full bundled desktop installer is unfinished.

No historical timing comparison, projected token saving or unmeasured advantage
over another agent is used as a current product claim. Requirements for future
backends, Revise, whole-project inference and cross-platform distribution are
not presented as shipped capabilities.
