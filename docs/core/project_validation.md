# Compiler and project checks

The `validation` tool runs explicitly selected argument-vector commands through
the existing owned project command runner and interprets bounded output into
source-bound Problems. It is independent of the target project's language.
Supported text interpretation families are `generic`, `gcc`, `typescript`,
`python`, `go` and `none`. Unknown formats remain command output.

`run` requires `argv` and explicitly selected source `paths`, with optional
workspace `cwd`, family, column encoding, label and timeout. It snapshots source
hashes before executing, uses independent Process approval and rechecks source
versions afterward. Report IDs, command receipts and Problems snapshot IDs bind
the owning root, state directory and session. `get`/`list` read retained reports.
Reading reports does not run commands, replay checks or invoke a model. `sources`
checks the selected source versions again. `compare` associates both Problems
snapshots and, for executed checks, verifies their command receipt hashes.
It distinguishes command labels from matching arguments/directory and records
changes in selected files and output configuration. Disappearing report rows
do not independently prove a repair.

`import_sarif` reads a SARIF 2.1.0 report without running its producer. It requires
`path`, `expected_report_sha256` and a selected `source_versions` manifest of
`path`/`expected_sha256` pairs. These bytes must match current workspace files;
the report and sources are rechecked before retention. This associates caller-
selected versions with a historical report, not authenticated producer evidence
or proof that the producer originally checked those exact bytes.

The importer supports driver rules/message templates, artifact indices,
workspace file URIs and directory base IDs, levels, UTF-16 or Unicode scalar
columns and reported line ranges. Accepted suppressions, baseline-absent and
non-problem rows are counted separately. Invalid/unselected locations and
capacity omissions remain visible; unlocated diagnostics receive no editor
marker. Network URIs, escaping/protected/symlink paths, base cycles, duplicate
JSON keys and conflicting identities are rejected or omitted. SARIF fixes,
related traces, extension-component rules and the complete SARIF feature set
are not implemented. No fixes or embedded commands execute.

Parser output is an untrusted interpretation, not a compiler semantics guarantee.
Only selected workspace source paths can receive diagnostics. Missing sources,
invalid coordinates and unselected paths report omissions. If column encoding
is unknown, the report uses the producer's whole reported line with explicit
precision metadata. Exact columns require `utf8_byte`, `utf16` or
`unicode_scalar`; UTF-8/surrogate boundaries and line bounds are checked.

Source changes invalidate the corresponding editor markers. A successful
command reports that command's outcome; selected source checks cannot prove that
every configuration/dependency was unchanged or the whole project was checked.
Output truncation, interpretation omissions and coverage remain explicit.

RPC: asynchronous `validation/start`, owned `validation/job/cancel`, and cached
`validation/query` reads under effective Read Allow. Plan mode admits
`get/list/sources/compare/import_sarif` but not command execution. Imports use
the asynchronous controller; synchronous queries never wait for an approval.
Busy checks block session/configuration changes;
server shutdown drains dependent jobs before closing shared managers.

Default bounds: 64 selected files, 512 KiB/file, 8 MiB total source, 8,192 output
lines, 8 KiB/line, 512 interpreted diagnostics, 32 reports, 2 MiB/report and
16 MiB retention. Command stdout/stderr each retain at most 64 KiB. Reports are
bounded memory, not durable execution ledgers. The underlying command runner
retains its own execution evidence; cancellation/read revocation can prevent
the higher-level interpretation from producing a report.

SARIF defaults additionally bound reports to 4 MiB, 16 runs, 4,096 combined
results/artifacts/rules, 16 locations per result, 64 base IDs and 16 base-chain
levels. Message strings are at most 16 KiB. Coverage says which supported rows
were retained; selected-file freshness is not whole-project coverage.

Real Python `py_compile`, GCC/G++ syntax-only and Go compiler fixtures check
failure diagnostics, changed-source withdrawal and subsequent successful repair.
No language/tool download or implicit command retry happens at runtime.

```sh
julia --startup-file=no --threads=4 --project=. test/project_validation.jl
julia --startup-file=no --threads=4 --project=. test/validation_reports.jl
```

Set `SHENSCOPE_TEST_GO` to a Go executable when it is not on PATH. Test Go object
files are removed after verification; C/C++ syntax checks produce no binary.
