# Julia startup and package precompilation

The CLI entry point parses common options and selects a command handler through
a bounded internal table. `Base.invokelatest` creates a compilation boundary at
the command entry and at each RPC service controller. Initialization still
checks protocol version, initialization state and shutdown state before routing.
Permissions, schemas, ownership, cancellation and error responses remain in
their existing controllers. This does not defer validation of configuration.

`Runtime/Precompile.jl` uses PrecompileTools 1.2.1 to capture the common metadata
path during normal package precompilation. The workload creates a temporary
configuration and state directory, initializes the framed server, reads health,
configuration, session metadata and cached model metadata, then shuts down.
It denies process/network permissions, makes no model request and cleans its
fixture. It does not run a terminal, invoke a tool, read user configuration or
modify the package-manager environment. No fixture server is a module global.
The package's usual dependency/source invalidation applies. The standard
PrecompileTools `precompile_workload=false` package preference disables it.

Reproduce the segmented fresh-process measurement from the repository:

```sh
julia --startup-file=no --threads=4 --project=. scripts/measure_startup.jl
```

Use the same executable, thread count, dependency cache and machine load when
comparing runs. Package-cache creation is a separate cost; an empty or invalid
cache causes Julia to rebuild before loading the module. The benchmark measures
module loading, construction, dynamically dispatched initialization, health,
configuration, session creation and local model metadata. Allocation totals are
not peak resident memory. Its total also includes fixture/report compilation;
it does not time a complete agent turn or a desktop's renderer startup.

Checkpoint 023 observations on Julia 1.11.7 with four threads:

| Observation | Result | Scope |
|---|---:|---|
| Original initialize phase | 13.441 s | Original segmented local fixture; trace enabled |
| Service boundary initialize phase | 3.548 s | Same local fixture; first load also rebuilt package |
| CLI/service boundaries, Node initialized | 28.553 s | One serial real editor transport run, existing cache |
| Package precompile wall time | 54.956 s | One explicit cache-generation run |
| Cached initialize phase | 0.000338 s | Fresh process, same segmented fixture/trace flags |
| Cached module load | 1.584 s | Same segmented fresh process |
| Cached Node initialized | 1.572 s | New real editor/Core process with existing cache |
| Tracked benchmark total | 1.854 s | Separate fresh process, no trace flag |
| Current ShenScope package cache | 39 MiB | One current `.ji`/`.so` pair; not a sysimage |

These are observations, not statistical benchmarks or cross-platform guarantees.
The earlier checkpoint 022 serial Node run recorded 74.567 s, but belongs to a
different source revision. The cached Node flow still waits roughly 25 seconds
for the first agent/tool execution; that path is not in the startup workload.

Checkpoint 030 adds one actual PackageCompiler 2.4.3 incremental generic Linux
sysimage build over the same checkout and depot. Build time was 495.728 seconds;
the image was 311,352,856 bytes. Source and dependency fingerprints were checked
before/after compilation. Three alternating fresh-process observations measured
the current metadata workload at 1.943–2.356 seconds with the package cache and
0.650–0.804 seconds with the image (medians 2.128 and 0.708 seconds). These are
small local observations, not statistical or desktop performance guarantees.
The actual image passed 120 affected Core assertions and seven real editor
transport tests, including scoped agent edits, PTY and extension behavior.
Five-protocol model tests used local HTTP fixtures, not real providers.

See `runtime_images.md` and `../validation/sysimage-checkpoint-030.json` for
integrity, permissions, raw phases and failure records. The experimental binary
was removed after verification, reclaiming space before further Core changes;
its receipt and reproducible scripts remain. Editor defaults remain ordinary
Julia startup. No installer, installed VSIX, clean-machine restore, native desktop
launch speed, live-provider latency or Windows performance is established. Native
Workbench and VSIX continue to use the same Julia stdio protocol. Their unchanged
UI workflows were validated in checkpoint 022; checkpoint 023 validates the
shared server through real Node transport and affected Core/CLI interfaces.
