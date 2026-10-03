# MCP Core

ShenScope independently implements MCP clients in Julia. Stdio and Streamable
HTTP share version negotiation, bounded JSON-RPC requests, capability discovery,
permissions, cancellation and connection generations. No upstream MCP or agent
implementation is embedded or translated.

## Configuration and credentials

Configuration belongs to Core, so CLI, native Workbench and standalone VSIX use
the same server definitions. A local example:

```toml
[mcp.servers.project_tools]
transport = "stdio"
argv = ["python3", "/absolute/path/server.py"]
cwd = "."
timeout = 30.0
connect_timeout = 30.0
reconnect_attempts = 3
environment_env = [{ name = "SERVER_KEY", env = "PROJECT_SERVER_KEY" }]
```

An HTTP example:

```toml
[mcp.servers.remote_tools]
transport = "http"
endpoint = "https://example.test/mcp"
header_env = [{ name = "Authorization", env = "MCP_AUTHORIZATION_HEADER" }]
```

Bindings reference variable names; values come from the environment or editor
secure storage. HTTP values are snapshotted at connection time. Reconnect after
changing one. Core rejects raw credential configuration fields and protected
transport headers. Endpoint user information and fragments are forbidden.
Child processes inherit only a small platform environment and explicit bindings;
model keys and the rest of the parent environment are not implicitly inherited.
Servers needing JULIA_DEPOT_PATH or another runtime setting must bind it explicitly.

Connection permission targets include a digest of the complete configuration.
Starting/using a child also requires process permission; HTTP requires network
permission. Tool calls require a separate MCP target including the raw tool name
and argument digest. Deny takes precedence over previous session grants. Remote
annotations never grant permissions or make a tool safe to retry in task workers.
This controls host-process access; it is not an OS sandbox for MCP servers.

## Lifecycle and failure behavior

Each connection initializes, validates the negotiated version/server info and
capabilities, sends initialized and then becomes available. Supported versions
are 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05; Streamable HTTP requires
2025-03-26 or newer. Server sampling and elicitation are not advertised and are
rejected. Client ping and permissioned roots/list are supported.

Requests have unique IDs, separate linked cancellation contexts and bounded
pending slots. Late replies are ignored. Old-generation replies and notifications
cannot complete or invalidate a new connection. Progress must match its request
token and increase monotonically. Arbitrary server logs/error bodies are not
retained in public status. Protocol content is preserved as untrusted server data.

Stdio writes are serialized, stdout is strictly newline-delimited JSON-RPC, and
stderr is drained into a bounded private buffer. Nonprotocol stdout fails the
connection. Linux cleanup closes owned pipes, terminates the owned process group
and reaps its direct child. Windows currently kills the direct child; descendant
Job Object behavior remains unimplemented and unverified.

HTTP POST requests are never automatically retried and redirects are disabled.
JSON and SSE results are supported; matching SSE replies end that request even
if the server leaves its stream open. GET SSE notifications have bounded reconnect
attempts and Last-Event-ID tracking. GET 405/501 disables the optional listener.
Session and protocol headers are owned by the transport. Closing an owned session
attempts one bounded DELETE; its untrusted body is discarded.

Connection supervision closes the old transport before opening a replacement.
Failed attempts share an outage counter until the connection remains stable;
rapid handshake successes cannot reset a flapping connection indefinitely. No
in-flight request is replayed. A submitted tools/call without a confirmed response
returns mcp_outcome_uncertain, including timeout, cancellation and connection loss.
The result might have happened remotely; callers must inspect evidence before
requesting a new invocation. Remote JSON-RPC rejection is distinct from that case.

## Discovery, schemas and content

Catalogs are capabilities gated and paginated, with duplicate identity/cursor,
page, item and total-byte limits. Fetch/validate/publish is atomic: an invalid page
does not replace the prior catalog. List-changed notifications mark it dirty and
advance its revision. Generation/revision checks prevent a concurrent refresh
from marking an obsolete catalog clean. Continuous change ends after three tries.

Tools retain their raw names on the wire and receive independently hashed,
bounded model aliases. Remote wrappers retain a definition digest and reject
changed definitions until declarations refresh. Connected tools join the agent's
next request; configured servers are not eagerly started. Remote tools use the
exclusive effects barrier. An isError result remains available as evidence and
is represented as a failed Core tool result.

The local schema validator supports bounded object/array/string/numeric rules,
combinators, conditionals, property dependencies and local JSON Pointer references.
Unsupported assertion keywords and external references fail closed. Regex input,
match/depth execution and validation work are capped. Format remains annotation
only; this is a documented subset, not full JSON Schema dialect certification.
Schemas are checked at discovery, arguments before submission and declared
structured output after receipt. Missing required structured output is an error.

Resource lists/templates, reads, prompt catalogs/arguments/messages, completion
and subscription/unsubscription are implemented. Subscription reservations
capture notifications racing their acknowledgement; failure rolls them back.
Updates increment per-resource versions and emit Core events. Reconnection clears
subscriptions; they are not silently restored. Text, image, audio, resource links,
embedded resources, structured content and metadata remain distinct and bounded.
Links are not fetched automatically. Media is preserved as MCP evidence; native
multimedia model projection and attachment rendering remain pending.

## Shared clients

Examples:

```sh
shenscope mcp servers --root /workspace/project
shenscope mcp tools project_tools --allow-mcp --allow-process
shenscope mcp call project_tools inspect arguments.json --allow-mcp --allow-process
shenscope mcp read remote_tools resource://example --allow-mcp --allow-network
```

CLI actions open the needed connection, run the same Core operation and close
owned processes/streams. `--allow-mcp` grants only that CLI invocation's policy.
Interactive policy prompts remain available; unattended Ask is denied.

Core RPC provides mcp/query for local metadata and mcp/start, mcp/job,
mcp/cancel_job for asynchronous operations, so the input loop can receive approval
responses. Jobs, approvals and connections are workspace/session scoped. Active
MCP jobs block configuration replacement. After CAS validation, old connections
close before the new configuration is written. Both editor clients expose
connection forms, tool parameters, resource/template reads and prompts. Secret
references use each editor's secure storage and reload on Core startup.
Both clients also expose enabled state, restart, permissioned ping tests, controlled
failure codes and recent notification metadata. Diagnostics exclude stderr,
credential values and remote error bodies. Ping tests exercise the same transport
and do not invoke a discovered tool. Configuration changes drain prior clients.

## Capacity and remaining work

Defaults/caps: 8 MiB message, 256 KiB schema, 32 pending requests per connection,
8 incoming client requests, 100 pages/1,000 catalog items/16 MiB catalog, 128
notifications/subscriptions, 32 configured servers, 64 session connections,
8 concurrent jobs/64 retained jobs, 128 active remote tool declarations. These
are implementation limits, not a throughput or reliability benchmark.

OAuth discovery/PKCE/refresh, legacy HTTP+SSE transport, request stream resumption,
automatic subscription restoration, sampling/elicitation/task extensions,
media projection, deferred tool selection, status history persistence, remote
sandboxing, Windows process groups and broad real-server interoperability are
still pending. Upstream review remains partial across every project.
