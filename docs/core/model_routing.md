# Explicit model roles and controlled fallback

Core now supports named provider sources, immutable model profiles and ordered
role routes. This is an opt-in inference policy. It does not define agent
prompts, alter permissions or infer model quality, capabilities or prices from
names. Without `model_routing`, the existing single-provider behavior applies.

## Configuration

```toml
[model_routing]
default_role = "main"

[model_routing.providers.primary]
protocol = "openai_chat"
name = "primary-provider"
endpoint = "https://api.example.com/v1"
key_env = "SHENSCOPE_PRIMARY_KEY"
retries = 2

[model_routing.providers.secondary]
protocol = "anthropic"
name = "secondary-provider"
endpoint = "https://api.another.example"
key_env = "SHENSCOPE_SECONDARY_KEY"
retries = 1

[model_routing.profiles.writer]
provider = "primary"
model = "configured-writer-model"
description = "Main coding model"

[model_routing.profiles.writer.options]
temperature = 0.2

[model_routing.profiles.backup]
provider = "secondary"
model = "configured-backup-model"

[model_routing.profiles.backup.capabilities]
context_window = 128000
max_output = 8192
tools = true

[model_routing.roles.main]
profiles = ["writer", "backup"]
fallback_codes = ["transport", "timeout", "server", "rate_limit", "circuit_open"]

[model_routing.roles.worker]
profiles = ["writer"]
fallback_codes = []
```

Provider declarations require protocol, name, endpoint and key environment
variable. They independently inherit ordinary provider defaults, including
configured capabilities/prices, and accept the existing retry/circuit tables.
Unknown fields, duplicate source identities, raw credential fields, Boolean
numeric limits and invalid profile references are rejected. Profile capabilities
can explicitly override the source declarations. These remain declarations,
not interoperability or model-quality evidence. The source's placeholder model
is replaced by the profile's concrete model for every request.

Bounds: 32 providers, 128 profiles, 32 roles, eight ordered unique profiles per
role, 1 MiB routing configuration, 64 KiB options per profile, and the existing
8 MiB individual request limit. A route admits at most 16 active logical
transactions, and retains at most 64 receipts of at most 16 KiB each. Combined
eligible prepared wire bodies are capped at 16 MiB. Source circuits share one
fleet manager's overall lease/source/history limits.

Profile options are stored as canonical JSON, independently of mutable caller
configuration. Request options override profile defaults, while wire-protected
fields remain forbidden. Options are not allowed to carry raw config secrets.
Configuration saving validates the complete fleet before replacing the file.

## Planning and execution

Planning freezes a bounded request and records its digest. Each configured
profile receives capability, output-capacity, actual wire/context and native
replay checks. Streaming is required; tool schemas, structured-output options
and reasoning options require the corresponding configured support. Candidate
and exclusion reports preserve configured order and typed reasons. The planner
does not read credentials or access the network. Estimates use the existing
byte/Unicode heuristic, not a verified tokenizer. Eligibility does not establish
availability.

Actual inference admits a bounded route seat before planning/preparation. All
eligible credentials are captured before the first network approval. Ineligible
profiles perform no credential lookup. Caller mutations, approval-time key
changes and later fallback cannot change those logical-request bodies/keys.
Each chosen source still requires normal network permission and shares the
parent cancellation, wall-clock budget and inference reservation. The source's
bounded retry/circuit policy applies before considering another profile.

Fallback handles only configured typed transient failures: transport, timeout,
server, rate limit, undelivered stream interruption and circuit-open. No auth,
permission, cancellation, budget, request or output-consumer failure can switch
sources. Any text, tools, usage or reasoning progress stops fallback, including
an interrupted partial stream. Exhaustion preserves the actual failure category.
Events identify selection and fallback reasons without exposing credentials or
private provider error bodies.

Every source has its own configured policy, while source/model variants retain
their intended shared runtime. Changing credentials creates a distinct circuit
identity. An open circuit for a provider source can therefore affect multiple
models/roles on that source. There are no background probes or automatic quality
rankings. Source selection receipts count logical profile attempts, not physical
HTTP attempts; retries can perform multiple HTTP requests within one attempt.

## Native replay and context accounting

New HTTP inference records include the public source identity alongside the
existing wire identity. Nonempty provider-native reasoning/items/thinking/parts
must match both the candidate model identity and recorded source. Malformed
metadata and legacy native records lacking a source are excluded from routing.
Core does not silently discard opaque history to make fallback possible. The
ordinary direct-provider path retains its existing legacy behavior. Explicit
history conversion and reviewed migration are future work.

Role context/output limits conservatively use the minimum declared capacities;
features are then checked per actual request. Context measurement includes the
largest eligible actual wire envelope. Budget admission uses the maximum
configured input and output prices among the role's sources. Actual successful
usage comes from the selected provider. Default zero prices are not billing
evidence. These conservative bounds can reject work a single larger/cheaper
source could accept; choosing a narrower role makes that tradeoff explicit.

## Services, clients and lifecycle

`models routes` returns configuration and scoped recent receipts. `models plan
REQUEST.json --model-role ROLE` previews eligible profiles. Existing model
directory/count/health services accept `--model-profile PROFILE`. Profile
selection for those services does not change the chat role. `chat`/`tui` accept
`--model-role`; task workers select the declared `worker` role when present,
otherwise the default role. Explicit routing is required to select a role.

RPC uses existing owned `models/start` actions `routes` and `plan`, and supports
`profile` for model services/query. `agent/start` accepts `model_role`. Query
returns a routing snapshot together with the selected profile's catalog/health.
Normal health reads capture credentials to identify the correct scope; they
are independent of the credential-free planner. Asynchronous jobs and receipts
remain workspace/state/conversation owned.

Both actual editor clients share role/profile/plan/recent-selection cards, secure
key prompts and chat role selection. The composer displays the configured role
and first model; execution events display the actual selected/fallback profile.
Role selection is disabled during inference. Both clients restore every declared
provider's securely stored environment-key binding when Core starts. Config
changes clear stale selections and rebuild the fleet after work is drained.
Fleet shutdown refuses live route seats; owners must finish/cancel first.

Receipts and circuits are bounded process memory. Receipt metadata includes
role, configuration/request hashes, selected profiles, typed outcomes and times,
but no body, key or private credential identity. Views are independent copies and
cannot read a sibling conversation's receipt history. Persistent fleet state,
reviewed role imports, adaptive quality/latency/cost routing, exact tokenization,
native-history migration and installed-package/desktop/Windows validation remain
pending. See checkpoint 020 evidence for loopback and actual-client validation.
