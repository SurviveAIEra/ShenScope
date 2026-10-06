# Core/editor protocol 1.0

Install the command using the [CLI installation guide](cli-installation.md),
then run `shenscope serve --stdio --root <workspace> --state-dir <state>`.
Use `--config <TOML>` for a nondefault configuration path and `--script <JSON>`
only for explicit offline fixtures. Standard output carries JSON-RPC 2.0 only.
Frames use `Content-Length: <UTF-8-byte-length>\r\n\r\n<body>`, capped at 8 MiB.
Headers, IDs, tool arguments, pending requests and pending approvals are bounded.

Initialize with `initialize {protocol_version: "1.0"}`. Capability fields report
actual implementation state; false means unfinished. The Core is the sole
configuration/session authority. Editor launcher settings contain executable,
source and state paths only. Requests use named parameters and integer/string IDs.

| Domain | Methods |
|---|---|
| Lifecycle | `initialize`, `health`, `shutdown` |
| Configuration | `config/get`, `config/set` with `expected_sha256` |
| Credentials | `credentials/set`, `credentials/status`; memory only, no value returned |
| Conversations | `sessions/create`, `list`, `get`, `export`, `rename`, `archive`, `pin`, `branch` |
| Agent | `agent/start`, `agent/steer`, `agent/cancel`, all scoped by `session_id` |
| Permissions | `permissions/respond` with `session_id`, `request_id`, `decision: once/session/deny` |
| Tools/runtime | `tools/list`, `runtime/status` |

`agent/start` acknowledges promptly; `agent/event` notifications carry ordered
sequence, session/trace IDs, timestamp, kind and payload. Approvals are registered
before notifying the client. A foreign, stale or duplicate approval fails.
Disconnect/shutdown cancels runs and cleans session-owned process handles.
Partial model output is persisted; its delivery prevents invisible retries.
Export currently returns the journal projection; deletion/import are unfinished.

Errors follow JSON-RPC parse/invalid-request/params/method codes; Core domain
errors use `-32010` with a sanitized domain code. Credentials and foreign HTTP
exception objects never appear in protocol errors. Keys supplied via editor
secure storage remain process-memory snapshots at request preparation time.

VSIX uses an extension-owned pipe. Native IDE uses a shared utility-process
channel and Workbench `ViewPane`, with no VS Code extension API import or
extension-host dependency. Both use the authored transport and DOM panel.
The native smoke test disables extensions and verifies a real HTTP model
fixture, permission card, file write and persisted conversation flow.
