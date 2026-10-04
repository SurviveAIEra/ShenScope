# Julia extension lifecycle

An extension contributes ordinary Julia tools, providers, project backends,
analyzers or evidence projections. Core owns registration, compatibility,
activation, invocation leases, generation checks and cleanup receipts. Julia
multiple dispatch and an explicit `Base.invokelatest` boundary handle methods
defined after the running agent was compiled. This is trusted code in the Core
process, with its privileges; it is not an isolation mechanism.

## Independent package entry

An independently installed package declares ShenScope in its own Project.toml
and exports `shenscope_extension_bundle()`. This returns an `ExtensionBundle`
with the package UUID/version, a stable registry name, an inclusive minimum and
exclusive maximum Core version, and named `ExtensionContribution` values.
Each contribution identifies its interface kind and a factory `(ctx) -> instance`.
An optional cleanup callback `(instance, ctx) -> ...` closes its owned resources.
Factories must not treat captured authorization as a grant for future callers.
Use the context supplied to each operation. Resource-owning contributions must
provide appropriate cleanup; a default no-op cannot discover arbitrary resources.

The authored independent package fixture is in
`test/fixtures/extensions/ShenScopeLifecycleExample`. It is installed into a
test LOAD_PATH without copying the application or adding it to runtime Core.
Package installation, marketplace discovery, persistent activation configuration,
out-of-process extension hosts and provider/backend selection through config are
pending. The programmatic leased API already supports these interface kinds.

`inspect_package` resolves a standard installed `src/Name.jl` package layout,
verifies Project.toml name/UUID/version and returns entry/project SHA-256 values.
`load_package` requires that inspected identity/version and both hashes. It
rechecks them around authorization and `Base.require`, then checks the bundle's
UUID/version and registers it inactive. Core does not run Pkg.add or fetch a
package. Other source files and dependencies are not verified by these two hashes.
Already loaded modules are disclosed; loading does not re-evaluate their code.
A process-wide receipt refuses source changes after a prior Core load and
requires a Core restart. These filesystem observations do not certify cached
compiled code, module semantics or an atomic source transaction.

Read and dynamic-code authorization are separate. With Julia's normal compiled
module mode, loading also requests process and persistence authorization because
Julia may launch compilation and write its package cache. Package initialization
can run arbitrary trusted Julia code; Core's cooperative cancellation/budgets and
permission checks do not impose an OS sandbox or a hard deadline on it.

## Registration and leases

The process-local registry belongs to one workspace. It allows 64 bundles and
128 total contributions. Constructors validate invariants through inner Julia
constructors, so exact concrete argument types cannot bypass validation.
Registration copies collections and retains no factory instances. Activation
creates all instances under dynamic authorization, checks actual dispatch
contracts and publishes the whole generation together. This atomic publication
does not roll back arbitrary factory side effects.

Tool activation freezes a bounded object parameter schema. `inspect_tool` returns
that schema, registry UUID and generation. Both control-tool invocation and
generated tool wrappers compare the live schema and reject drift. Calls acquire
bounded leases and release them in `finally`. They require current dynamic
authorization, matching workspace/registry/generation and an active contribution.
Generations do not repeat after removal/re-registration in the same registry;
the registry UUID fences replacement after configuration changes.

The existing dynamic tool-discovery dispatch adds active wrapped tools to each
agent request. Names include an extension/contribution digest and remain within
the model's 64-character name bound. Factories are not rerun during discovery.
Activating a contribution during an agent run makes it discoverable on the next
model turn. Existing policy, argument validation, hooks, budgets, tool results
and no-progress detection continue to apply. Other extension kinds use
`with_extension_instance` and their existing dispatch interfaces; instances must
not escape that leased lifetime for subsequent interface calls.

Deactivation first enters `draining`, which refuses new leases. Existing calls
can finish. A bounded wait may return draining; repeat deactivation after calls
retire. Cancellation or budget expiry does not silently reactivate the extension.
Cleanup runs in reverse contribution order. Factory/contract failures and cleanup
failures quarantine the registration, preserving stage and failure counts without
private exception text. Forgetting a registration after failed cleanup requires
explicit acknowledgement and does not confirm resource closure.

Core shutdown and configuration replacement close the registry and run cleanup
for unleased activated instances. A still leased/activating instance is reported
pending rather than destroyed under its caller. Shutdown is best effort for
arbitrary trusted callbacks. Deactivation/removal never claim to unload Julia
methods, globals or module initialization effects.

## Interfaces

The `extensions` agent tool exposes list/inspect/inspect_tool, package inspection
and loading, optional loading, activation, deactivation, removal and generation-
fenced tool invocation. Mutating or permissioned IDE operations use owned
`extensions/start` jobs; query/job/cancel endpoints enforce conversation ownership,
remove pending approvals on cancellation and hide retained results after read
denial. Config changes and agent starts reject pending extension operations.

Both editors expose the same Core registry, package hash review, scoped approvals,
activation state, parameter forms and tool results. Registry state ends when Core
stops or configuration replaces it. The CLI inspects/loads packages and supports
a pinned ephemeral invocation; lifecycle management uses the long-running Core.
Ephemeral invocation creates and closes its own registry, without durable state.

## Optional sparse evidence

SparseArrays is a real `[weakdeps]` dependency. Julia activates
`ShenScopeSparseEvidenceExt` only after that dependency is imported. This loads
methods, without automatically registering or activating a contribution. Explicit
optional registration and activation expose a projection implementation.

The projection reads a verified combined project snapshot into sparse forward
and reverse dependency matrices. Multiple claims occupying a pair retain every
origin; their summarized weight is the maximum recorded weight, not their sum
or a probability. Exact-source anchor steps remain distinguishable from provider
edges. Keys, fingerprint and revision vectors survive conversion. Neighbor lookup
uses sparse column ranges without creating an N-by-N dense matrix. The returned
matrix is a detached trusted data object; neighbor reads refer to that captured
snapshot and do not recapture current index revisions or source bytes.

Optional Julia extension code is reported separately by cloc. The 250,000-line
delivery target continues to count authored `src` Core only, excluding CLI,
extension modules, tests, clients, helpers, dependencies and generated code.
