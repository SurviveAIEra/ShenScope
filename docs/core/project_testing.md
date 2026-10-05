# Project test discovery and execution

ShenScope Core is implemented in Julia; test projects can use any language.
`TestingTool` and its SDK use an explicit executable/argument vector. They do
not translate project source, choose a shell implicitly, install dependencies,
configure a build, or infer that a named runner is available.

## Discovery

`discover_project_tests!` reads ordinary UTF-8 project markers in one to sixteen
selected workspace directories. The default scan examines at most 512 files,
128 directories, four nested levels, 4,096 entries, 256 KiB per marker, 2 MiB
total marker content, and 64 command candidates. Results disclose examined
counts, excluded directories, skipped symlinks, invalid markers and limits hit.
One `readdir` materializes a directory listing; this is not a streaming memory
bound for a directory with millions of entries. A bounded scan is never a
complete project inventory.

| Project declaration | Candidate | Qualification |
|---|---|---|
| `package.json` test script | `npm test` | Declared script; reporting format is unknown. |
| Pytest configuration | `python3 -m pytest -q` | Declared framework; terse output may omit passing case names. |
| Other `pyproject.toml` | Python unittest discovery | Suggested; the marker alone establishes no collected tests. |
| `go.mod` | `go test -json ./...` | Suggested; a program named `go` is not proof of a Go SDK. |
| Cargo package/workspace | `cargo test` | Suggested; stable text is retained without inventing JSON case events. |
| CMake project | CTest in `build` | Requires an already configured build directory. |
| Make test target | `make test` | Declared target, ordinary process policy. |
| Maven/Gradle declarations | Maven/Gradle test command | Suggested; no project wrapper is selected automatically. |
| .NET project/solution | `dotnet test` | Suggested; uses the selected project file. |
| Composer test script | `composer run-script test` | Declared string or string-array script. |
| Rake/Julia package | Rake task / Julia package test | Suggested; dependencies and tasks remain the project's responsibility. |

Candidate IDs hash command, working directory, marker path/content hash and
qualification. Catalogs additionally bind the owning session, workspace hash
and state-directory scope. Only the owning scope can select a candidate.
Catalogs are bounded in memory and may be retired. Discovery executes none of
these commands. The selected marker is read again before launch, including
after asynchronous Process approval; changed declarations refuse execution.
Other project files are not pinned as an execution snapshot.

## Execution receipts and interpretation

`run_project_tests!` executes an owned candidate.
`run_project_test_command!` accepts explicit `argv`, `cwd`, `framework` and
`label`, independently of project language. Both use the existing process and
sandbox implementation: workspace directory checks, Read and Process policy,
shared wall-clock budget, cancellation, timeout and active permission checks.
Read and Process are independent permissions. Plan mode exposes discovery and
reads to the agent; agent command execution remains unavailable. Human client
test controls explicitly select their own operation.

The default retained output is 256 KiB **per stream**, with a maximum of 1 MiB.
Actual byte counts, retained stdout/stderr, exit code, signal, elapsed seconds,
timeout, cancellation, revocation and sandbox evidence remain separate fields.
No command is replayed because delivery fails. A receipt is retained before
final Read delivery checks, so an owning scope can inspect an executed command
after a deliberate permission change. RPC queries and notifications also
respect current Read denial.

Structured interpretation supports Python unittest, pytest text, top-level TAP,
Go JSON events, CTest text and plain output. Bounds are 1,024 cases, 256 source
references and 20,000 lines per interpreted stream; lines over 64 KiB are
reported as unparsed. Nested TAP cases are not flattened into duplicate parents.
Go source locations are decoded from `Output` events rather than matching raw
JSON strings. Raw output retains no invented per-case records. JUnit XML and
other framework-specific adapters remain pending.

Cases, summaries and source locations are **framework-reported data**. They do
not independently establish correctness or complete project coverage. A zero
exit code establishes command completion, not collection of any test. Reported
failures with exit zero still produce a failed tool result, and agent after-test
Hooks receive a failed outcome. Capture and interpretation capacity indicators
describe retained data and parsing bounds; they do not certify that every
possible framework record is recognized. JSON expansion can trim a receipt
further, with explicit omission flags, while preserving the process outcome.

`read_project_test_source` reads an owned reported frame through ordinary Read
policy, rejects workspace escapes/protected paths/symlinks and returns a bounded
current-file excerpt and SHA-256. An expected hash refuses a changed preview.
The source is current, not a snapshot from execution. Column units reported by
frameworks are unspecified; editor navigation uses the reported line only.

## Clients and retention

```
shenscope tests discover --root PROJECT
shenscope tests run CANDIDATE_ID --root PROJECT --allow-process
shenscope tests custom --root PROJECT --allow-process \
  --argv '["runner","argument"]' --framework raw
```

CLI candidate execution rediscovers declarations and selects the same content-
bound ID. A declaration change produces a different candidate ID. The TUI uses
`/tests` and `/test CANDIDATE_ID`; its UI task remains responsive to approval and
cancellation while the command runs. A failed CLI command retains its JSON
receipt and returns a nonzero status.

The standalone VSIX and native Code-OSS share a Tests view: discovery, explicit
selection/custom arguments, failures before passing cases, retained output,
source preview/open, recent receipts and conversation isolation. RPC operations
are `testing/start`, `testing/job`, `testing/cancel_job` and `testing/query`.
Jobs remain bound to the owning session/workspace/state directory. Competing
agent runs, mode changes and configuration changes cannot overlap these jobs.

Controller catalogs and receipts are bounded **in-memory** state (32 catalogs,
32 reports and 16 MiB retained reports by default); they do not survive Core
restart. Normal agent tool messages save execution receipts in the existing
conversation journal. Explicitly saved standalone test results are now available
through `history_save` and the shared Tests view; see
[`project_test_history.md`](project_test_history.md). Saving has separate
Persistence permission and revision checks, and never replays the command.
Native VS Code Testing API integration,
coverage artifacts, project-wide test identity/reconciliation and broader
framework adapters remain pending.

Validation uses real Python, JavaScript, Go, C and C++ projects, each with an
actual failing command, a hash-guarded edit and a successful rerun driven by
`MockProvider`. This tests orchestration and real compilers/runners, not live
model quality. See `docs/validation/project-testing-checkpoint-039.json`.
