# Periodic trusted-Core backtraces

`diagnostics sample` runs one fixed installed Core fixture in a separate Julia
helper and collects actual `Profile` periodic backtraces. Supported targets are
`digest_string`, `cliptext_string` and `canonical_dictionary`. Arbitrary source,
symbols, commands and user inputs refuse. This facility inspects helper activity;
it does not measure exclusive target CPU time or CPU utilization.

```sh
bin/shenscope diagnostics sample cliptext_string \
  --allow-dynamic --allow-process --timeout 120 \
  --duration 0.1 --sample-delay 0.001 --iterations 8 \
  --max-samples 128 --max-frames 4 --profile-buffer-words 20000
```

The agent tool, asynchronous owned RPC and both editor Runtime views use the same
Core service. The `Sample method` control preserves existing inference and
allocation reports. Separate cards distinguish these three observations.

## Collection and meaning

A warmup loop requests 0.01 seconds before collection. The sampled workload
repeats the same typed fixture batch until its requested minimum loop window or
100,000-batch limit. The batch output is consumed and its hash, length and
checksum must agree with warmup. Instrumented wall time and loop wall time remain
separate. Driver work, remaining compilation, GC and scheduling can extend them;
this is not a throughput benchmark or an exact-duration experiment.

The helper configures a finite per-thread `Profile` buffer, starts collection
through `Profile.@profile` and always stops and clears it. It reads a buffer with
metadata removed, validates zero-delimited backtraces and counts the observed
records. It retains the first bounded prefix and resolves only its instruction
words. Stack scanning and inline-frame resolution have separate bounds. This
uses the supported Julia 1.11 runtime's `Profile.getdict` resolver; a different
runtime requires its own compatibility verification.

Only unique authored Core frames from the recorded inventory are serialized.
Frames retain relative file, positive line, function label, inlining, file hash
and a driver/Core role. Raw task identities, instruction addresses, method
objects and external host paths are omitted. Unknown positions remain
unattributed. The report exposes a full-buffer flag and independent sample,
stack, lookup and Core-frame truncation counts.

Frame counts are inclusive occurrences among the retained backtraces. Each
fraction divides that frame's backtrace count by the retained count, including
backtraces without Core frames. One backtrace can contain several frames, so
fractions can overlap and must not be added as utilization. The first prefix
need not represent the entire collection window. The requested sampling delay
does not guarantee a sample frequency. Background helper activity can contribute.
Empty samples or missing Core frames do not establish absence of CPU work.

## Bounds and validation

Defaults are eight calls per batch, a 0.1-second window, a 0.001-second delay,
128 retained backtraces, four Core frames per backtrace and 20,000 buffer words
per thread. Supported limits are 1–32 calls, 0.01–1 seconds, 0.0001–0.01 seconds
delay, 1–256 backtraces, 1–8 frames and 4,096–200,000 words. Delay must fit at
least twice in the requested window. Stack scans retain at most 128 instruction
words and resolve at most 256 inline frames per retained backtrace.

The child uses one Julia thread. Its report is bounded to 2 MiB. The parent
independently checks exact fields, input/runtime/method/source identity, output
consumption, collection dimensions, unique source frames, fractions, aggregates,
scope qualifiers and report digest. A plausible unretained sample count cannot
be authenticated from retained frames alone; unsigned digests are not producer
attestation. Limits are application bounds, not OS memory limits.

Read, Dynamic and Process remain independent approvals. Cancellation, timeout,
current source checks, shared budgets and live permission denial use the common
diagnostics worker and close its child. Restricted configured sandboxes refuse
this trusted-host path. The report explicitly states `os_sandbox=false`.

## Declaration association

`evidence` and `evidence_source` accept `sampling_job_id` alongside the optional
compiler and allocation-profile job IDs. At least one owned completed report is
required. Combining requires the same fixed target/signature and current Core
inventory. Queries revalidate reports and read bounded JuliaSyntax facts without
executing any target; Process and Dynamic are unnecessary for those reads.

`observation_kind="sampling"` selects sample/frame occurrences. Each retains a
report digest, sample/frame handle, position and truncation flags. Unattributed
backtraces retain one unmatched observation. Containing declarations remain
candidates, not proof of runtime binding, target attribution or semantic
equivalence. Fingerprint-pinned previews reuse the source-byte/hash guards.

Results are ephemeral owned jobs, not additions to the compiler archive.
Configuration replacement and retention can retire them. Arbitrary project
sampling, task attribution, flame graphs, retained heap/RSS, live-model quality,
Windows execution and comparative performance evidence remain unfinished.

Focused validation: `test/compiler_sampling.jl`,
`editors/test/sampling.test.mjs`, `editors/test/evidence.test.mjs` and the actual
native/VSIX compiler GUI workflow in `ide/test/native_smoke.mjs`.
