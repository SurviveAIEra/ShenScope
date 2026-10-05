# Compiler report archives

The Julia Core stores bounded structured compiler reports independently of the
ephemeral diagnostics job list. Each archive belongs to one workspace and one
conversation. Source inventories contain paths, byte counts and SHA-256 values;
archiving never copies source directories or stores executable historical code.

## Evidence and historical validation

`compiler_archive_save` accepts the `report`/`execution` result from graph
inference, verifies it against the current Core source inventory, and rechecks
the inventory immediately before catalog publication. RPC saves resolve an
owned, completed `compile` job with `mode=graph`; clients cannot submit a report
body as proof that compilation occurred. An expired or retired job must be
compiled again before saving.

The `compile_archive` diagnostics action performs actual graph inference and
publication without depending on an IDE's job ID. Agent calls and CLI
`compile --save` share this path. It checks explicit persistence denial and an
already stale catalog before inference, then uses the ordinary revision-checked
save after computation. A concurrent writer can still invalidate that revision;
there is no invisible retry of compilation or publication.

Reading uses the recorded inventory rather than requiring that the current Core
has the same source hashes or method line numbers. It checks the package UUID,
fixed target signature, report digest, asset digest, strict field inventory,
bounded operands, control-flow and data-flow projections, findings and metadata.
Current fixed signatures remain the compatibility contract: an archive may
become unsupported when a target is removed or its signature changes. Julia
versions are parsed and preserved, without executing a historical compiler.

These unsigned hashes detect mismatches and corruption. A host user who can
rewrite evidence and hashes can fabricate observations. Read results explicitly
return `producer_authenticated=false` and `source_currentness="not_checked"`.
Historical reads load no historical source and require no dynamic/process grant.
Experimental effect predicates retain their recorded Julia version and never
establish a security boundary.

## Storage, conflicts and cancellation

The default limits are 128 catalog entries and 64 MiB of evidence. Configurable
limits range from 1–512 reports and 1 KiB–256 MiB. Individual assets are limited
to 3 MiB and catalogs to 512 KiB. Reads are bounded, reject symlinks, check file
identity before and after reading, and reject unknown archive directory entries.
Inventory bounds are application limits; this is not an OS memory boundary
against another host process that creates arbitrary filesystem entries.

An OS file lock serializes catalog transactions. Save, rename, delete and cleanup
require the caller's `expected_revision`; catalog publication also checks its
previous digest. Save writes an atomic evidence asset before the atomic catalog.
Cancellation before catalog publication can leave an unreferenced asset, which
is visible in catalog storage statistics. A matching orphan can be reused by a
later save. Active reads and writes recheck cancellation, shared wall-clock
budget and live Read/Persistence denial.

After atomic catalog publication, notification failure is reported separately
as `commit_notification_failed`; it does not retroactively fail storage. Owned
diagnostics jobs retain bounded `committed_effects` records before notifying the
owner. Cancellation or budget expiry after publication can still stop job
completion; polling exposes the recorded catalog revision/digest so callers can
inspect committed state instead of replaying a mutation. These are reports by
the running Core rather than authenticated external attestation. They are
ephemeral job evidence; the archive catalog is the persisted state to inspect
after job retirement or process restart.

Read denial before result delivery rejects the owned result. Both synchronous
polling and asynchronous Core notifications hide result bodies and commit
evidence while Read is denied. The existing inventory, schema, provenance and
permission limits still apply.

Save counts referenced assets, orphans and staging bytes against its capacity.
Staging files are counted separately in listing results. Cleanup below only
deletes fully validated evidence assets; general atomic staging recovery remains
the separate storage lifecycle operation. There is no recursive folder cleanup.

Removing an entry changes the catalog and retains its evidence file. Cleanup is
an explicit two-step operation: review a dry-run plan, then apply against the
same expected catalog revision. It validates each orphan's ownership/schema,
rechecks the catalog and asset digest before deletion, and never removes a
referenced report. An interruption can leave a partially completed cleanup;
the next plan reflects the files that remain. Referenced missing/corrupt assets
fail when opened; listing is a catalog view rather than validation of every body.

## Comparison

Comparison loads and validates both stored assets from one pinned catalog.
Targets, argument signatures, Julia versions and compiler platforms must agree;
otherwise the response explains why comparison is unavailable. Methods are
matched by module/signature/file. Statements are paired only for unique source
location/opcode/operand-kind anchors. Unknown or repeated anchors remain
unpaired, with counts exposed to the UI. Compiler callee classes are compared
without treating SSA or slot IDs as runtime function identities.

Results include return types, structural statistic deltas, uncertain-value
counts, normal cycle groups, source changes, anchored value changes and advisory
effect changes. Change items are bounded and disclose truncation. Compiler
elapsed times are not treated as a performance benchmark. Every comparison
returns `performance_change_proven=false` and `behavior_equivalence_proven=false`.

## Interfaces

The `diagnostics` tool adds `archive_save`, `archive_list`, `archive_get`,
`archive_label`, `archive_delete`, `archive_compare` and `archive_gc`.
`diagnostics/query` permits reads and cleanup dry-runs under an existing Read
grant. Inference and mutations use `diagnostics/start` and the existing owned
poll/cancel/approval protocol. Save requires the completed compiler `job_id` and
expected catalog revision. Read operations accept an expected catalog digest
for stable pagination, opening or comparison. Owned operation results retain
their independent transport capacity: diagnostics allows 3 MiB plus 4 KiB,
64 JSON levels and 600,000 encoder nodes under an 8 MiB retained-result cap.
Other operation managers retain their existing defaults. Oversized or overdeep
results still fail explicitly. The same body and permission checks apply to
reads even when dynamic/process execution is denied.

CLI archives require an existing conversation ID and matching workspace:

```sh
shenscope diagnostics archive_list --session ID
shenscope diagnostics compile cliptext_string --mode graph --save \
  --session ID --expected-revision 0 --title 'UTF-8 method'
shenscope diagnostics archive_get REPORT_SHA256 --session ID
shenscope diagnostics archive_label REPORT_SHA256 --session ID \
  --title 'Reviewed' --expected-revision 1
shenscope diagnostics archive_compare BEFORE_SHA256 AFTER_SHA256 --session ID
shenscope diagnostics archive_delete REPORT_SHA256 --session ID --expected-revision 2
shenscope diagnostics archive_gc --session ID
shenscope diagnostics archive_gc --session ID --apply-cleanup --expected-revision 3
```

Normal dynamic/process/persistence approvals apply. `--allow-dynamic`,
`--allow-process` and `--allow-persistence` remain explicit CLI overrides. The
`--root`, `--state-dir` and `--config` options select the same context used by
the conversation. CLI has no access to another process's ephemeral job manager;
`compile --save` performs inference and publication in one invocation.

VSIX and native Workbench share the Runtime view: report title/save, paged
catalog, rename/open/remove, two-report comparison and explicit orphan cleanup.
Recorded reports have a visible currentness/producer qualifier. Changing
conversation or configuration clears the compiler/archive display state.
