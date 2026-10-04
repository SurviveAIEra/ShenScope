# Terminal runtime

Julia Core owns Linux PTY handles, argument-vector launch, permission checks,
input, resize, foreground interruption, retained output and cleanup. An independent
Julia bootstrap process establishes a new session and controlling terminal,
checks the foreground group, closes inherited descriptors above stderr and resets
ignored signal dispositions and the inherited blocked signal mask before exec.
Core requires its nonce receipt before reporting readiness. The payload receives
the slave on stdin/stdout/stderr; its streams merge as ordinary terminal output.
The helper sets a parent-death signal. This is a host process, not an OS sandbox.

The initial implementation is Linux only. It explicitly refuses a selected
restricted sandbox rather than launching a host fallback. Windows ConPTY,
macOS support, restricted PTY launch and reconnect after Core restart remain
pending. Capability metadata distinguishes implementation from each child's
checked readiness. A terminal command still runs arbitrary trusted host code
under process authorization and inherits the host environment.

## Ownership and lifecycle

Each manager binds one workspace. Handles belong to one conversation, including
list/poll/input/resize/interrupt/stop/remove. Foreign handles and operation jobs
are refused. Starts ask separately for output read and process execution. Input,
resize, interruption and stopping use independent process requests targeting the
handle. A session grant for that handle covers those operations under the existing
permission engine. Revocation of process permission, cancellation, lifetime expiry
or shared budget exhaustion terminates the owned process group. SIGINT targets
the foreground group only after checking its session identity.

Closing sends TERM followed by KILL to the session leader's process group and
closes the master descriptor after a bounded drain. Descendants retaining the
slave cannot hold cleanup open. Processes that deliberately create a different
session/process group are not recursively discovered; this is group cleanup,
not containment of hostile host code. Parent death signaling covers the payload
leader; no guarantee is made for detached grandchildren. Reaped child descriptors
and reader tasks close. Completed output remains until explicit removal or manager
shutdown. Configuration replacement and Core shutdown close the manager.

One manager retains at most 32 handles by default, configurable up to 128 for
trusted Core callers. Each terminal has 1 KiB–4 MiB retained filtered output
(256 KiB default), 64 KiB input writes, 64 KiB pages, 2–500 rows/columns and a
0.05–3600 second lifetime. Startup confirmation has at most 15 seconds within the
same lifetime/budget. These are data/lifetime limits, not a physical RSS or CPU
sandbox. Output notifications carry offsets, not unbounded output text.

## Output cursors

Streaming UTF-8 decoding handles split characters and replaces malformed input.
The filter retains a bounded escape sequence state, supports common display CSI
sequences, and discards OSC, DCS, APC, PM and SOS control strings across chunks.
Encoded C1 introducers are normalized through the same filter. Window/device
queries and clipboard/title commands are removed. This does not make the payload
safe to execute or certify terminal rendering equivalence.

The journal counts filtered UTF-8 bytes separately from observed raw bytes. Polls
report requested/actual offsets, retained floor, next cursor, lost bytes and more
data. Future offsets and character-splitting offsets are rejected. Retention and
pages preserve UTF-8 boundaries. Plain output removes the retained display escape
sequences while keeping cursor units tied to the filtered byte stream. Cursor
pages and a retained tail can split ANSI sequences; full screen reconstruction
after loss is not guaranteed. Output is ephemeral; no hidden transcript writes
or automatic full-output files are created.

## Agent, CLI and editors

The `terminal` tool exposes platform/list/start/poll/write/resize/interrupt/stop/
remove. Mutations and permissioned reads use owned asynchronous `terminal/start`
jobs; query/job/cancel endpoints verify conversation scope. Synchronous query
requires an existing read Allow grant, so it does not block the RPC input loop
waiting for an approval. Pending terminal operations block agent starts and
configuration saves. Already running terminals can coexist with agent work.

`terminal run --argv '["python3","script.py"]' --json` runs one ephemeral PTY
and closes its manager. `--input` sends explicit text, with optional rows/columns/
timeout. The CLI has no cross-process retained handles or raw interactive stdin
mode yet. TUI agents access the same tool through ordinary agent calls.

Both clients have a shared Terminal view with reviewed JSON argv, scoped approvals,
input, dimensions, interruption and bounded output. Native Workbench attaches a
custom `ITerminalChildProcess` through its actual terminal service without an
extension host; VSIX attaches a `vscode.Pseudoterminal`. Neither client starts a
shell. A shared transport adapter polls bounded pages, batches/limits queued input
and serializes mutations. Read Allow is required for native attachment; Ask reads
can be granted through an owned output operation first. Process approval remains
visible in the ShenScope panel, including operations initiated by the terminal.
There is one pending terminal mutation per conversation; competing attachments
receive the existing busy refusal. Terminal sessions are not persisted across
reloads and do not expose shell integration, binary input or resolved dynamic cwd.

Validation evidence is recorded in `docs/validation/terminal-checkpoint-029.json`.
The 250,000 authored Julia Core target and remaining product gates are still open.
