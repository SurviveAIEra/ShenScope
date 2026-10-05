# External language services

Julia Core implements a bounded stdio LSP client for explicitly configured
servers. The target project can use any language declared in the server
specification. Core does not install, discover or automatically restart a server.
Actual integration checks use Pyright 1.1.408 and typescript-language-server 5.0.0
with TypeScript 5.9.2; `scripts/setup_language_servers.py` installs these pinned
test dependencies in one shared directory.

The `language` tool supports explicit start/stop/status, disk document open/close/
save, diagnostics and Problems capture. Definition/reference/implementation/type
definition, hover, document/workspace symbols, completion/signature and call
hierarchy queries negotiate server capabilities. Formatting, rename and code
actions return review proposals. Server commands and `workspace/applyEdit` are
not executed. Create/delete/rename resource operations are unsupported.

`configure`, `configured`, `configuration`, `remove_configuration` and
`start_configured` operate a conversation-owned versioned configuration store.
Saving requires Read and Persistence and a matching expected version. Saving a
command never starts it or grants its future Process authorization.

RPC methods are `language/start`, `language/query`, `language/job` and
`language/cancel`. Start handles asynchronous actions, including permissioned
reads. Query admits selected cached/configuration reads only with effective
Read Allow. Jobs bind root, state directory and session; cancellation releases
their pending approvals without cancelling the parent conversation. Current
Read denial suppresses retained results and event evidence.

Messages use strict CRLF Content-Length framing measured in UTF-8 bytes. Header
duplicates, overflow, malformed boundaries/JSON and excessive frames are refused.
Document positions negotiate UTF-16; unsupported encodings are refused. LSP
line positions follow CR/LF/CRLF, independently of Unicode separator handling
used by compiler source maps. Half-surrogate positions are rejected.

Core synchronizes current disk text with monotonically increasing document
versions. Returned locations are checked against workspace-owned source hashes,
ranges and permissions. Outside/protected/unavailable targets report omissions.
This does not integrate unsaved editor buffers. Navigation and call edges remain
language-server reports, not independent runtime-call evidence.

Push diagnostics must match the current opened document version to become
publishable Problems. Versionless reports remain inspectable but cannot create
current editor markers. Full pull reports are paired with the current source
under the document mutex. File edits invalidate prior source-bound Problems.

Defaults: eight server processes per manager, 64 documents/server, 512 KiB per
document, 16 MiB total document text, 4 MiB messages, 16 pending requests and 256
diagnostics/document. Navigation is additionally bounded by target files, source
bytes and result items. Limits and omissions are explicit. Server commands use
Process approval, a checked workspace CWD and a configuration fingerprint;
Read/Process revocation closes the client. Host LSP processes are not OS isolated.

Reproduce the actual tests:

```sh
python scripts/setup_language_servers.py
julia --startup-file=no --threads=4 --project=. test/language_services.jl
julia --startup-file=no --threads=4 --project=. test/project_workflow_protocol.jl
```

Set `SHENSCOPE_LANGUAGE_SERVERS` to the shared `node_modules` path when overriding
the cloud default. Selected source reviews in checkpoint 042 cover OpenCode,
DeepSeek Harness and Qwen LSP framing/lifecycle/diagnostics; checkpoint 043 adds
seven-primary-agent source observations for edit guards and review boundaries.
All reviews are partial and no upstream implementation is copied or translated.
