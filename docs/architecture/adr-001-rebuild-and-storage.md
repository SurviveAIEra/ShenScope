# ADR 001: Independent reconstruction and a single checkout

Status: accepted by current user request.

The cloud machine and old source were lost. Attachments provide specification
and conversation evidence, not recoverable Git objects. Start an independent
Julia package in the existing checkout. Reconcile later user corrections into
requirements without claiming old pass counts for new code.

Use one checkout, shallow read-only reference dependencies and a shared Julia
toolchain/depot. Git checkpoints plus verified pushes preserve source. Avoid
copies/worktrees and routine distribution builds. Construct desktop integration
as a pinned upstream patch overlay instead of vendoring Code-OSS history.

The official Julia download host is not in this cloud's network policy. The
official Docker Hub `library/julia:1.11.7-bookworm` image is accessible. Extract
only its Julia layer, with a pinned SHA-256 from the verified OCI manifest.
Keep TLS and SHA verification enabled; delete the compressed layer immediately.

An executable process or existing archived artifact does not prove completion.
Record current tests and scope/LOC status separately from historical evidence.
