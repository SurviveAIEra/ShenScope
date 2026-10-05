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
Reading reports does not run commands, replay checks or invoke a model.

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
`validation/query` reads under effective Read Allow. Plan mode admits `get/list`
but not command execution. Busy checks block session/configuration changes;
server shutdown drains dependent jobs before closing shared managers.

Default bounds: 64 selected files, 512 KiB/file, 8 MiB total source, 8,192 output
lines, 8 KiB/line, 512 interpreted diagnostics, 32 reports, 2 MiB/report and
16 MiB retention. Command stdout/stderr each retain at most 64 KiB. Reports are
bounded memory, not durable execution ledgers. The underlying command runner
retains its own execution evidence; cancellation/read revocation can prevent
the higher-level interpretation from producing a report.

Real Python `py_compile`, GCC/G++ syntax-only and Go compiler fixtures check
failure diagnostics, changed-source withdrawal and subsequent successful repair.
No language/tool download or implicit command retry happens at runtime.

```sh
julia --startup-file=no --threads=4 --project=. test/project_validation.jl
```

Set `SHENSCOPE_TEST_GO` to a Go executable when it is not on PATH. Test Go object
files are removed after verification; C/C++ syntax checks produce no binary.
