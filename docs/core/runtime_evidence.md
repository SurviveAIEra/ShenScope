# Runtime and declaration evidence

Diagnostics `evidence` associates positions in existing owned completed compiler
and/or allocation-profile/periodic-sampling jobs with installed Core declarations. It uses the existing
JuliaSyntax adapter and stable `FileFacts`/`CodeSymbol` model. It does not run the
target, load a project, expand macros or create a persistent index. Joins consume
canonical facts independently of CodeGraph private schemas. Additional adapters
and arbitrary project inference are pending.

```
diagnostics/start {session_id, action:"evidence", compiler_job_id?, profile_job_id?, sampling_job_id?,
                   observation_kind:"all", offset:0, limit:40}
diagnostics/start {session_id, action:"evidence_source", compiler_job_id?, profile_job_id?, sampling_job_id?,
                   observation_key, expected_evidence_sha256, context_lines:4}
```

Select at least one owned workspace/conversation job. Compiler jobs must contain
completed graph inference; profiles must contain completed fixed-fixture
measurements; sampling jobs must contain completed periodic backtrace reports.
Combining requires the same target, signature, supported runtime
and current complete Core inventory. Parent validation checks report bodies and
derived projections. Historical archives and caller-supplied files are excluded.
`diagnostics/query` supports allowed Read requests; use `diagnostics/start` for
scoped approvals. Process/Dynamic/Persistence/Network are unnecessary for reads.

CLI `inspect` and the agent diagnostics tool explicitly execute two fixed helpers
first and therefore also need Dynamic/Process:

```bash
bin/shenscope diagnostics inspect cliptext_string --allow-dynamic --allow-process \
  --iterations 8 --repetitions 3 --max-samples 128 --max-frames 4 \
  --observation-kind allocation --limit 12 --query cliptext
```

This produces a page, not a durable report or an implicit optimization. Invalid
query parameters refuse before execution.

Observations retain report digests and method/statement or sample/frame handles.
Source reads verify inventory SHA-256 and byte counts before parsing. Provider
stamps retain parser version, canonical fact hashes, capabilities and a null
persistent revision. Positive lines must be within verified files; unknown and
external positions remain unmatched.

An interval index compares lines with all containing callable declarations of
the same source hash. Prefix maximum end lines bound backward scans. An
independent linear oracle covers nested, overlapping, duplicate and boundary
ranges. Multiple candidates remain ambiguous; no winner is selected. Even a
unique declaration start remains a source candidate rather than a proven runtime
binding or column identity. Excess contenders refuse instead of being dropped.

The evidence digest pins reports, complete source inventory, selected facts and
all observations. Subsequent pages can require it. Pages have bounded text and
method/statement/allocation/sampling filters. Previews require it and select an observation
key rather than a filename. Live Read denial, cancellation, shared budgets and
source changes stop reads. Preview windows reuse UTF-8/file-hash/line-length guards.

Defaults: 32 files, 4,096 callable declarations, 16,384 observations, 16 candidates
per position, 8 MiB source/retained projection, two million join steps and at most
128 observations/2 MiB per page. Parser inputs remain limited to 2 MiB/file. These
are application collection bounds, not OS memory caps or a large-project
benchmark. Each request reparses its bounded selection; no hidden cache is used.

Compiler rows describe inference; allocation rows describe a separate fixture/
helper run and can include background activity. One sample can appear in several
frame observations; summing their bytes would double-count. Periodic backtrace
frame occurrences are inclusive and cannot be added as CPU utilization. Actual timing and
retained-prefix allocation totals remain separate. Source association does not
prove runtime bindings, semantic equivalence, test coverage, retained heap or
performance gain. Digests are unsigned. Ephemeral jobs can be retired by
configuration replacement or bounded retention.

Both clients share Connect source facts, categorized pages, candidate details,
verified previews and scope notes. Target/report/conversation/configuration
changes clear associations. No arbitrary file link or editable document is
created. Tests: `test/runtime_evidence.jl` and
`cd editors && node --test test/evidence.test.mjs` against real Julia Core.
