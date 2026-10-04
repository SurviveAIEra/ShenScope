# Execution policy and Linux isolation

Julia independently prepares command policy, permissions, mount plans, environment,
resource limits, process ownership and isolation receipts. Linux bubblewrap supplies
filesystem/PID/network namespaces; the small Julia bootstrap installs no_new_privs,
libseccomp rules and resource limits before executing the command. Julia types or
macros are not used as an OS boundary.

The default remains explicit `host` mode for compatibility. Host commands have
host access after process approval. Select `bubblewrap` to require isolation;
failure never falls back to host. This container has a protected bubblewrap binary,
but nested namespace creation fails because its UID mapping interface is read only.
Landlock's kernel interface is unavailable in this process. Accordingly, checkpoint
025 verifies refusal of the payload here, not successful full namespace isolation.
Network-only worker filters, descriptor closure and CPU/file limits are independently
exercised against real native child commands. The integration suite also contains a
full namespace branch for a machine where its probe actually succeeds.

```toml
[sandbox]
backend = "bubblewrap"
filesystem = "read_only" # or workspace_write
network = "closed"       # or open, with separate network permission

[sandbox.limits]
cpu_seconds = 120
file_bytes = 67108864
open_files = 256
address_space_bytes = 0  # zero leaves this optional virtual-memory limit unset
```

Host mode accepts only `backend = "host"`; policy fields cannot pretend to enforce
isolation there. Configuration is validated before replacing the config file or
retiring managers. Invalid fields/limits preserve the existing file and services.
Active conversations, owned jobs and running/draining processes block policy changes.
After a successful save, memory/security managers and task-executor references are
refreshed; durable facts remain readable. Explicit client configuration saves use
the existing config CAS interface, rather than a tool persistence approval.

## Access and child state

Restricted commands require workspace Read; workspace writes require separate Edit,
and open networking requires separate Network. The process approval includes its
argument vector, directory, policy digest, readonly runtime paths, environment-key
list and resource limits. Declarations are rechecked after approvals and preflight.
Runtime dependencies are mounted readonly; workspace is readonly or writable as
declared. `/tmp`, home and cache paths are private. PID/proc state and devices belong
to the namespace. Workspace `.env`/`.env.*`, `.ssh`, `.aws` and private Core state are
masked; `.git` metadata is readonly. Bounded scanning fails closed when incomplete.
Protected symlinks, escaped directories and changed mount identities are rejected.
Ordinary workspace files remain readable; additional runtime roots are explicitly
readable dependencies. This is not a general secret-discovery mechanism.

The runner's loader environment is reduced, and child environment is rebuilt from
approved locale/display keys plus fixed path/home/cache values. Credential variables
and loader injection variables are not inherited. Receipt metadata exposes keys,
not values. Currently restricted overlays accept only those locale/display keys;
language-worker/MCP environment adapters and credential-specific overlays need
further work. Existing host adapters preserve their current behavior.

Closed networking denies socket creation/pairs, connection and socket IO, including
Unix sockets. Open networking still blocks VM/network-kernel socket families. The
bootstrap also denies namespace/mount changes, cross-process memory/descriptor
access, kernel module operations and io_uring bypasses. Native threads/child commands
remain possible. No domain allowlist, syscall-complete hardening, process-count
quota or peak RSS limit is claimed. CPU, file-size, open-file and optional virtual
address-space limits are inherited; the existing shared wall deadline and bounded
output/input apply independently.

## Receipts and interrupted work

A bounded, nonce/policy-bound stderr marker confirms isolation setup before exec.
It is stripped from command output. Missing, wrong or incomplete markers stay
unconfirmed. Setup confirmation does not claim that the requested executable
successfully started: `payload_exec_verified` remains false. Diagnostics report
backend availability separately from command receipts; an available probe does not
mark host commands isolated. Probes are explicit process operations and run without
mounting the workspace; passive status does not start a child process.

Process status reports the native signal and a negative signal exit code for killed
commands. Permission revocation terminates an owned process group; restricted
commands also monitor Read/Edit/Network Deny. Polling revocation is not instantaneous
or an atomic rollback. Cancellation, timeout, permission changes and kernel signals
can leave file effects. Durable workers record interrupted unsafe commands as
`WorkUncertain`, preserving receipts and requiring reconciliation rather than
automatic replay. A real CPU-killed task that first writes a file tests this rule.

CLI commands are `security status`, `security probe --allow-process` and `doctor`.
The tool has `status`/`probe`; scoped RPC exposes `security/query`, `security/start`,
`security/job`, `security/cancel_job`. The native and standalone IDE Security view
shows host/required-isolation policy, actual diagnostic state, explicit approvals,
config CAS controls and detailed capability metadata. Linux development GUIs are
verified; installed packages, Windows/macOS backends and clean-machine restoration
remain unverified. The overall Core target and functional gates remain open.
