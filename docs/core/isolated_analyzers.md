# Isolated Julia analyzer candidates

Dynamic analyzer source is evaluated only in a separate Julia process. The
parent sends source and explicit JSON inputs after validating the trusted
bootstrap's ready frame. Source is never evaluated in the agent, server or IDE
process. An ordinary Julia Module is used to organize definitions inside that
child; it supplies no security boundary.

The Linux compute profile uses libseccomp with a default EACCES action, thread
synchronization and no-new-privileges. It permits runtime memory, timing, signals
to the same process, synchronization and audited anonymous IPC. It does not
permit filesystem opens/mutations, sockets, process creation/exec, descriptor
duplication/receipt, tracing, cross-process memory or io_uring. Julia's existing
anonymous LLVM code memfd can be mapped/resized within a 128 MiB hard file-size
limit. That RAM object has no host filesystem pathname. No writable host file
descriptor is admitted. `/dev/null` is checked as the actual Linux device.

A small isolated-mode Python exec launcher closes every inherited non-stdio
descriptor before starting Julia. Python owns no agent/analyzer logic. The
trusted Julia bootstrap then audits its newly created runtime descriptors;
stdio must be pipes. The child environment contains explicit runtime settings,
PATH and the shared Julia depot, without inherited model keys or startup hooks.
Launcher identity is rechecked after asynchronous permission approval.

Each child receives hard CPU, virtual-address-space, core-dump and memfd size
limits before the filter is installed. Parent checks bound wall time, input,
combined protocol output and diagnostics, enforce cancellation and permission
revocation, and reap the process group and streams. CPU accounting includes
trusted bootstrap; virtual address space is not a resident-memory quota. Parent
process buffers stay bounded even when caller code floods stdout. There is no
permissive fallback: unavailable enforcement or a failed bootstrap rejects the
operation before source delivery. Linux x86_64 is the verified platform;
macOS/Windows are unavailable and aarch64 has not been runtime-tested.

## Candidate contract

Define `analyze(data, request)::Dict` and `selftest()::Bool`. JSON dictionaries,
arrays, strings, finite numbers, booleans and null are the data boundary. Base
and preloaded runtime modules are available; filesystem/package loading after
bootstrap is unavailable. New methods are inspected and called through
`invokelatest`, including contract reflection, to handle Julia World Age.

The parent compares each external fixture's actual dictionary with its expected
canonical JSON. Expected outputs are not sent to the child. A successful
`selftest()` alone does not validate a candidate. Evaluation reruns external
fixtures and rejects mismatches before publishing the actual result. Receipts
bind source, version, fixture inputs/expectations, actual result hashes, limits
and enforced sandbox. Supplied fixtures establish agreement for those cases;
they do not prove general correctness. Child compile/analyze timing counters
are untrusted observations; parent elapsed time includes startup and validation.

Registrations are session-scoped, hash-addressed and bounded by record, byte and
concurrent execution caps. Registering another version does not silently replace
the selected version. Inspection returns copies. In-flight runs have child
cancellation tokens and shared budgets; cancellation leaves the owning agent
context active. Removing a running candidate requires cancellation first.
Permission checks cover read, dynamic-code admission and process execution.

The `analyzers` model tool exposes status, register, list, inspect, validate,
evaluate, select, remove and cancel. Explicit JSON data evaluation is present.
Project graph projection/evidence validation, archival persistence, promotion,
rollback and dedicated RPC/editor controls are the next implementation stage;
this checkpoint does not claim those features or general host-tool isolation.

## CLI

```sh
shenscope analyzers status --root /path/to/project
shenscope analyzers validate DEFINITION.json --root /path/to/project \
  --allow-dynamic --allow-process
shenscope analyzers evaluate DEFINITION.json INPUT.json --root /path/to/project \
  --allow-dynamic --allow-process
```

CLI reads bounded workspace-confined definitions and inputs, registers a
candidate for that invocation, runs the same implementation, prints JSON and
cleans the registry. Validation exits with code 1 when external fixtures fail.
Source symlinks and protected paths are rejected. The fixture example under
`examples/analyzers` is excluded from authored Core line counts.

## Verification

`test/unit/compute_protocol.jl`, `test/unit/analyzers.jl`,
`test/integration/compute_isolation.jl` and `test/integration/analyzers.jl`
cover the wire contract, source integrity, ownership, actual kernel calls,
descriptor inheritance, running cancellation, output flooding and external
fixture disagreement. The full affected suite exercises the shared in-memory
JSON parser and tool registration. No live-model quality claim follows from
these local process tests.
