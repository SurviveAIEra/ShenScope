# Model directories and input measurement

Julia Core implements provider directory discovery and request input measurement.
The `models` tool, `models/*` RPC methods, terminal commands and both editor
clients use the same services. Directory refresh is explicit; listing, inspecting
or clearing a directory never changes the configured model.

## Directory semantics

Supported protocols are OpenAI Chat, OpenAI Responses, Anthropic, Gemini and
Ollama. Compatible servers must implement the respective documented model-list
shape. Discovery performs bounded authenticated GET requests to `/models`, or
Ollama `/api/tags`; Anthropic and Gemini use their protocol pagination fields.
Keys are captured once per logical refresh and are sent in headers. A source
identity binds protocol, provider name and base URL. Base URLs reject credentials,
fragments and queries; HTTPS is required except for loopback development servers.

Every snapshot belongs to a workspace, state directory, conversation and source.
Its private salted credential tag prevents displaying a snapshot under changed
credentials. Tags and keys are absent from public results. A directory is memory
only and lasts for that Core conversation runtime. Restarting Core or launching
another standalone CLI command does not load a durable provider directory.

Metadata distinguishes API declarations from configured capabilities. Unknown
context, input, output or feature fields remain JSON null. Gemini input capacity
is separate from combined context capacity. Model names do not imply reasoning,
vision or tools, and missing prices never imply free inference. Duplicate model
IDs invalidate every occurrence; malformed entries produce bounded diagnostics.
Malformed page framing, repeated cursors and capacity failures preserve the last
committed snapshot. API metadata does not prove successful inference access.

Defaults: 600-second freshness, 1,024 entries per response page, 4,096 retained
models per source, 16 pages per refresh (caller maximum 32), 2 MiB per HTTP
response, 128 conversation/source cache keys and 16 MiB combined retained catalog
JSON. Up to four refreshes can run across distinct source keys. Public pages
default to 50 models and accept at most 100. JSON depth, node and output-byte
limits apply before unbounded serialization. Returned views are independent
copies. Explicit clear or scoped retirement frees source capacity.

ETag conditional requests are used only for a previous single-page directory;
an individual page validator cannot validate a combined multipage directory.
A successful 304 advances the snapshot revision/check time while retaining its
content hash. Refresh epochs and generation checks prevent canceled or invalidated
work from publishing. Credential changes cancel active refresh leases and discard
all cached directories; changing configuration retires the old service manager.

## Input measurement

Counting accepts an explicit assembled `ModelRequest`, not a chat completion or
an inferred editor conversation. JSON input uses `messages` with `role` and
`text`, optional assistant `calls` or tool `call_id`, optional `tools`,
`max_output` and provider `options`. It is bounded to 8 MiB, 2,048 messages and
128 schemas. The same request builders used for inference construct the actual
provider input fields, including system instructions, tool schemas and replay.

`estimate` performs no credential lookup or HTTP request. It measures serialized
input fields with the existing UTF-8/CJK/emoji heuristic and explicitly labels
the result an estimate, not a verified tokenizer count. Anthropic `provider`
uses `/messages/count_tokens`; Gemini uses `/models/ID:countTokens` with the
assembled `generateContentRequest`. These results are provider-reported input
counts. They are not inference usage, verified tokenizer measurements or billing
receipts and do not debit the inference token ledger. Service work still uses
the shared wall-clock budget.

`auto` uses an implemented provider endpoint when available. Other protocols
receive a labeled estimate. An HTTP 404 can fall back to an estimate with an
explicit reason; authentication, permission, transport and malformed responses
remain errors. Strict `provider` does not fall back. Reports include configured
capacity violations without rejecting oversized input before measurement, so
callers can assess compaction. No exact local tokenizer is implemented yet.

## Ownership, permissions and interfaces

Metadata and explicit request measurement require read permission. Network
permission is separately requested for an HTTP operation. Allow-once covers the
pages of one directory refresh and is bound to source, method, operation, scope
and the requesting cancellation token. It cannot authorize a foreign context.
Revocation, cancellation and shared deadlines are observed during blocked reads.
HTTP retries and redirects are disabled; error bodies are not echoed into results.

Owned asynchronous operations allow one active job per conversation and four
overall. Retention defaults to 64 jobs, 4 MiB per result and 16 MiB overall.
Job lookup/cancellation checks workspace, state directory and conversation.
Notification delivery failure does not relabel completed work as failed. Nested
approval callbacks observe the requesting context, and completion events carry
pending permission IDs so clients remove canceled child approval cards precisely.
Configuration mutation waits for active service jobs to finish or be canceled.

RPC methods: `models/query` reads allowed cached metadata; `models/start` starts
`status`, `list`, `refresh`, `inspect`, `count` or `clear`; `models/job` and
`models/cancel_job` operate on owned job IDs. Query does not launch a model run.
Inference retry/circuit policy and the additional `health`/`reset_health` actions
are described in [model_policy.md](model_policy.md). Directory and counting
transport retain the no-retry service policy described above.
Both editor clients expose a Models view with explicit refresh, unknown metadata,
inspection, request JSON measurement, cache clear and cancel controls.

Examples, using `shenscope` with the installed Julia runtime:

```sh
shenscope models status --root .
shenscope models refresh --root . --allow-network --limit 20
shenscope models count request.json --root . --count-mode estimate
shenscope models count request.json --root . --count-mode provider --allow-network
```

Routing, circuit breakers, persistent provider catalogs, exact tokenizers,
multimodal measurement policies and live-provider interoperability remain
separate development work. Deterministic loopback tests establish protocol and
lifecycle behavior, not live-model quality.
