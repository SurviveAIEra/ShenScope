# Model retries and provider health

Core inference uses an immutable logical-request body and credential snapshot,
typed retry decisions and a bounded provider circuit manager. This applies to
the five existing streaming protocols through `HTTPProvider`; model directory
and counting service requests retain their separate, no-retry policy.

## Retry contract

`provider.retries` remains the default retry count. The optional
`provider.retry_policy` table accepts `max_retries` (0–32), `initial_delay`,
`maximum_delay` (at most 300 seconds), `jitter_ratio`, `retryable_codes` and
`honor_server_delay`. Unknown options, Boolean numeric values, nonfinite values
and terminal retry categories are rejected. Defaults are two retries, a
0.25-second initial delay, a 30-second maximum and 0.25 jitter.

Only typed transport, timeout, server, rate-limit and interrupted-stream failures
can retry. Authentication, invalid input, permission, cancellation, context,
budget and output-consumer failures remain terminal. Retries stop after any
text, tool call, usage or reasoning/progress delivery. An interrupted stream
that delivered nothing can retry; a partially delivered stream cannot replay.

The assembled JSON body is bounded and encoded once. Every attempt uses exactly
that body and the originally captured credentials. Changing caller options or
credentials during a request does not change a later attempt. HTTP redirects
and HTTP library retries remain disabled.

Bounded `retry-after-ms`, numeric `Retry-After` and strict IMF-fixdate headers are
interpreted before reading an error body. A valid server wait is a minimum,
measured against monotonic elapsed time. If it cannot fit the policy ceiling or
shared deadline, Core suppresses the retry instead of shortening the requested
wait. Invalid advice is reported by category without exposing header contents.
`x-should-retry: false` can veto a retry; `true` cannot override a terminal error.
Exponential jitter and exponent bounds prevent overflow. Waiting checks shared
budget, cancellation and current network permission at least every 25 ms.
Blocked inference reads are closed when cancellation or permission revocation
is observed. These are Core policy checks, not a host operating-system sandbox.

## Circuit contract

The optional `provider.circuit` table accepts `enabled`, `failure_threshold`,
`failure_window`, `cooldown`, `maximum_cooldown` and `max_in_flight`. Defaults are
three consecutive transient logical failures within 60 seconds, a 30-second
cooldown capped at 300 seconds, and 16 active logical requests per source.
Defaults also bound the manager to 64 source identities, 64 overall active
leases and 32 history entries per source. Explicit idle-history clearing frees
source capacity. Disabled circuits still enforce concurrency and retention caps.

Health belongs to workspace, state directory, provider source and a private
salted credential identity. Neither credentials nor credential tags appear in
public results. Conversations and task workers in one Core runtime share this
health; directory caches and asynchronous service jobs retain their narrower
conversation ownership. Standalone CLI invocations start with untracked health.
No circuit history survives a Core restart.

One lease covers one logical request, including its retries. Exhausted transient
failures count once. Successful inference resets current consecutive failures.
Cancellation, denied permission, budget exhaustion, invalid requests and failed
output consumers produce neutral outcomes. A delivered partial provider failure
still records an actual failure while remaining ineligible for retry.

After cooldown, one explicit inference request obtains the half-open probe.
There are no background probes. A failed probe increases bounded cooldown;
success closes the current epoch. Stale completions cannot close a newer open
epoch, duplicate settlements are ignored, and active seats are released on all
exit paths. Admission reserves CAS-version space for outstanding completions;
versions never silently saturate or wrap. Exhausted versions can be recovered
by clearing idle history. Metric counters may saturate independently.

## Interfaces and lifecycle

`models/query` returns scoped directory metadata and provider health using one
captured credential identity. The `models` tool and owned `models/start` actions
add `health` and `reset_health`. Reset requires read and network permission,
an exact nonnegative `expected_revision`, and no active inference leases.
`clear_history` additionally removes the idle entry. Credentials are captured
before approval so a concurrent key change cannot redirect the authorized reset.
Reset allows future inference; it does not verify availability or issue HTTP.

Both editor Models views show admission state, retry/circuit policy, the last
observed outcome and an explicit reset action. A closed circuit means requests
are allowed, not that the provider has been verified healthy. The normal agent
factory and worker factories retain the runtime instead of constructing empty
health on each turn. Config mutation waits for active work; credential changes
retire idle circuit identities. Shutdown cancels/drains owners before closing
model service managers. CLI/TUI use the same policy during their process lifetime.

`shenscope models health` reports the fresh CLI process's health without a
network probe. It cannot inspect another IDE process's live circuit manager.

## Validation and limits

Checkpoint 019 covers strict config/header/decision parsing, version capacity,
concurrent circuit epochs, half-open ownership and real loopback HTTP retry,
partial-output, body/key stability, cancellation, revocation and deadline cases.
RPC tests cover reset approval, CAS, scope and live worker/server health sharing.
Actual native Workbench and independent VS Code development-webview flows issue
a provider failure, show cooldown, reset without a probe, and then verify an
explicit successful recovery request. Evidence is in
`docs/validation/model-policy-checkpoint-019.json`.

This does not establish live-provider interoperability or predict future
availability. Persistent fleet health, role routing, pricing admission and
installed-package/desktop distribution validation remain separate work.
