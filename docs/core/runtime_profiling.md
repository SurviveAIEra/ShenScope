# Trusted Core workload measurements

`diagnostics profile` executes a fixed installed Core fixture in a separate Julia
host process. It measures runtime behavior rather than treating inferred IR as a
runtime trace. Three supported targets are `digest_string`, `cliptext_string` and
`canonical_dictionary`. Other targets, arbitrary source and user input refuse.

```sh
bin/shenscope diagnostics profile cliptext_string \
  --allow-dynamic --allow-process --timeout 120 \
  --iterations 8 --repetitions 3 --max-samples 128 --max-frames 4
```

The normal agent tool, owned RPC and both editor Runtime views call the same
Core service. Fixtures are deterministic installed ASCII/Unicode strings or a
nested dictionary. Reports record fixture identity and input hash, method/source
identity, Julia version/platform, a digest of observed output and collection
limits. Raw returned strings, external paths, pointer and task addresses are not
serialized. The helper uses one Julia thread and closes on every exit path.

## Measurement phases

One warmup batch runs before timing. The report records its wall time separately;
this does not include all package loading, helper startup or fixture setup. Each
timing batch uses real `Base.@timed` and records wall time, allocated bytes, GC
time and compilation/recompilation counters. Minimum/median/maximum summaries
are recomputed by the parent. The measured region includes the fixture call,
typed workload loop and returned batch tuple; it is not exclusive target cost.

A separate pass uses actual `Profile.Allocs`. Rate defaults to one; lower rates
can observe no allocations. A bounded prefix retains allocation type/size and
unique authored Core frames, with driver frames labeled. External frames are
omitted. Frame scans are capped at 128 entries and retained frame lists expose
truncation. Type and first-Core-frame aggregation uses the retained sampled prefix.
It does not estimate unretained allocations or diagnose retained heap/RSS/leaks.
Allocation recording can include helper background activity.

Sampled bytes need not equal timing-pass allocated bytes even at rate one; these
are different passes with different instrumentation and accounting. Output hashes,
byte lengths and loop-consumption checks agree across warmup, timing and sampling.
Short timings are sensitive to timer resolution, scheduling and remaining JIT
work. This allocation report provides no periodic backtraces or statistically
established performance improvement. The separate [sampling service](runtime_sampling.md)
collects fixed-Core backtraces with its own scope and limits. Neither benchmarks
arbitrary project workloads.

## Bounds and ownership

Defaults: eight calls per batch, three timing batches, 128 retained allocations,
four Core frames per allocation and rate one. Supported maxima are 32 calls,
eight timing batches, 256 retained allocations and eight frames; rate is finite
between 0.001 and one. Observed records cap at 250,000, with a 2 MiB report and
the existing owned-diagnostics result/retention bounds. The maximum workload call
request count includes one warmup and one sampling batch in addition to timings.

Read, dynamic execution and process permissions remain independent. Cancellation,
live denial, shared budget and a 0.1–120 second timeout close the actual child.
Configured restricted sandboxes refuse this trusted-host path; it is not OS
isolation. Current source inventories must agree before workload execution and
again before parent publication. The parent validates strict fields, dimensions,
source hashes, fixed input, runtime/target identity, output consistency and all
derived aggregates. Digests do not authenticate an external machine.

Only the owning workspace/conversation can inspect or cancel a job or answer its
approvals. Temporary Read denial filters retained results and notifications;
configuration replacement retires old jobs. Results are ephemeral and are not
added to the IR archive catalog. CLI JSON can be captured through ordinary shell
redirection. Persistence, project profiling, exclusive CPU/heap profiles, distribution and
cross-platform validation remain separate capabilities.

The UI shows batch timing/allocation metrics, warmup, sample retention, allocation
types, first Core frames and expandable collection notes. It preserves the
inferred IR view as separate evidence and resets on configuration/conversation
changes. The focused suite is `julia --startup-file=no --threads=4 --project=.
test/compiler_profile.jl`; real client coverage is
`cd editors && node --test test/profile.test.mjs`.
