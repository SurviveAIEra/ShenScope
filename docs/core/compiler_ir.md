# Structured Julia compiler evidence

Core obtains real, unoptimized `Base.code_typed` output for six fixed installed
Core function/signature pairs. It does not evaluate supplied source, load an
arbitrary project, or execute the target function. This extends the existing
lowered/typed text diagnostics with a bounded structured report.

```sh
bin/shenscope diagnostics compile cliptext_string --mode graph \
  --allow-dynamic --allow-process --timeout 120
```

The same `diagnostics` tool is available to the agent. The native Workbench and
standalone VSIX expose it under **Runtime → Compiler inference**. Both clients
use Core's owned `diagnostics/start`, `diagnostics/job` and
`diagnostics/cancel_job` operations. `diagnostics/query` lists metadata and
contracts; compilation requires the asynchronous permissioned operation.

Shared clients permit 120 seconds for owned job-start admission because initial
Julia compilation can delay the acknowledgement. Ordinary RPC requests retain
their thirty-second default, and explicit caller timeouts remain authoritative.
This client allowance does not replace the Core worker timeout or shared budget.

## Evidence and analysis

Each method report retains its source-relative file/line, signature, method
world bounds, source SHA-256, inferred return type, slots and statement IDs.
Anonymous and repeated Julia slot names are preserved; slot IDs identify locals.
Constant values and arbitrary runtime objects are not exposed. Operands retain
SSA/slot references, control destinations and bounded expression structure.

Types distinguish concrete values, small unions, `Any`, bottom, constants and
other compiler lattice values. A nonconcrete value is advisory evidence; it does
not by itself establish allocations, dynamic dispatch, or slow execution.

Core independently builds explicit normal-control blocks and predecessor/
successor edges, entry reachability, dominators, immediate dominators, strongly
connected cycle groups and backedges. Bounded path witnesses describe possible
normal paths. Exception handlers are marked, and exception-edge completeness
is explicitly false. Loops have no observed iteration counts.

A bounded fixed-point analysis tracks possible local-slot definitions, resets,
entry arguments and uninitialized locals. Read witnesses retain alternative
definitions rather than choosing one runtime path. SSA uses form a separate
dependency projection. Neither projection resolves heap aliases, exceptions,
executed dispatch, or actual runtime values.

Call records distinguish known global functions, inferred invokes, constant
callables, SSA/slot callables and unresolved cases. They are compiler evidence,
not an executed call trace. Informational findings cover nonconcrete values,
unresolved calls, possible uninitialized reads and normally unreachable blocks.
Counts disclose retention truncation.

`Base.infer_effects` supplies experimental effect information. Core calls the
actual Julia predicates for consistency, effects, throwing, termination, task
state, inaccessible memory, undefined behavior, overlays and runtime calls.
Raw conditional encodings are version specific. A false predicate means there
is no unconditional compiler guarantee; it does not prove harmful behavior.
These properties establish neither security isolation nor measured performance.

## Ownership, validation and resources

The child helper requires separate dynamic and process approvals. Metadata and
source/result reads have their own read gates. Parent polling checks cancellation,
shared budgets and live read/dynamic denial. A configured restricted sandbox
refuses this helper rather than silently launching it on the host. The result
states `separate_process=true` and `os_sandbox=false`.

Core pins a sorted source/dependency fingerprint before the request, verifies
the worker's source identity and rechecks the source before publication. The
report records Core UUID/version, exact Julia version/platform and observed
compiler world. A canonical body SHA-256 detects accidental report changes;
it is unsigned and does not attest machine instructions or arbitrary workers.

The parent strictly validates report fields, operand/reference shapes, bounds,
source identities and metadata. It recomputes normal-control, local-definition,
SSA, call, finding and count projections from the validated statement records.
It does not reconstruct compiler inference from serialized text. The only
supported worker and targets are the trusted installed Core table.

Default limits are 2,048 statements, 40,000 operand nodes, depth 64, 512 blocks,
2,000,000 analysis operations and 128 retained findings. Maximum supported
bounds are 4,096/80,000/128/1,024/4,000,000/256 respectively. The entire report
is capped at 2 MiB. Compilation timeout is 0.1–120 seconds. Bounded analysis
yields to other Julia tasks. Worker pipes/processes close on every exit path.

Owned asynchronous results are ephemeral and bounded: two concurrent jobs,
sixteen retained jobs, one job per conversation, and eight MiB total results.
Another conversation cannot inspect or cancel the job or answer its approvals.
Cancellation retires pending approvals. Busy conversations cannot start agent
runs, change ownership metadata, or replace active configuration. Live read
denial hides previously retained results.

The shared UI shows return/statements/blocks/calls/cycles, forty statements per
page, uncertain-type and block filters, source fingerprints, findings and effect
qualifiers. Control-path buttons are capped at sixty-four. Text rendering avoids
HTML interpretation. The report remains available through Core for other clients.

## Remaining boundaries

Arbitrary project compiler inference, complete exception flow, heap/escape
analysis, measured allocations/profiling, runtime dispatch observations and
fusion with project/Git/coverage evidence are separate unfinished capabilities.
`compiler_ir_compare` compares compatible already-produced report summaries;
it is not archive authentication or proof of performance/behavior changes.

Checkpoint 031 tests use actual branch, loop and exception fixtures rather than
handwritten substitute IR. Mutated, rehashed frames exercise independent parent
validation. Real child, Node RPC, native Workbench and VSIX flows verify the
supported path. Raw evidence and limitations are recorded in the validation
checkpoint; installed/relocated or Windows environments are not implied.

The focused Julia suite runs with `julia --startup-file=no --project=.
test/compiler.jl`; it includes affected parser transport and owned-operation
regressions. Editor transport: `cd editors && node --test test/compiler.test.mjs
test/transport.test.mjs`. The GUI runner accepts `--compiler-only` and optional
`--vsix` after shared assets and the native overlay have been built.
