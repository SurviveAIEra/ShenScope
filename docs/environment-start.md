# Cloud development environment

Project: `/workspace/ShenScope`, branch `main`. Use this checkout only.

```sh
cd /workspace/ShenScope
bash scripts/setup.sh
bin/shenscope --version
bin/shenscope doctor --state-dir .local/state
```

`scripts/setup.sh --editors` also installs/checks/builds the editor assets with
the shared npm cache. Add `--backends` to prepare pinned CodeGraphContext,
Tree-sitter grammars and the Go AST compiler/helper in shared locations.
See `docs/core/project_data.md` for alternate paths and validation commands.
`scripts/clone_references.py` prepares the one pinned
checkout per research dependency; it refuses to replace changed references.
The single Code-OSS checkout is a designated build dependency and contains the
small native overlay. Research/depot/registry checkouts are not application
repository membership. See `ide/README.md` for native validation preparation.

Julia 1.11.7 uses the verified official Docker OCI layer when the S3 download
host is unavailable. The installer keeps only extracted Julia, removes the
archive, and refuses large work below 8 GiB free. Pkg uses the shared depot and
CLI Git with normal CA verification. Never disable TLS checks or copy the repo.

State and configuration for this cloud task should be writable workspace paths:
`SHENSCOPE_STATE_DIR=/workspace/ShenScope/.local/state` and
`SHENSCOPE_CONFIG=/workspace/ShenScope/.local/config.toml`. Model credentials
are optional for offline development. Live default OpenAI-compatible calls use
`SHENSCOPE_MODEL_KEY`; provide its value only in the environment secret UI or
editor secure storage. `doctor` reports presence, never the value.

Tests: `julia --startup-file=no --threads=4 --project=. test/runtests.jl`,
targeted by changed subsystem during development. Real terminal:
`python test/integration/tui_pty.py`. Editor transport: `cd editors && npm test`.
Native GUI: `node ide/test/native_smoke.mjs` after the documented desktop setup.
No model-quality or Windows validation follows from these local fixtures.

`WORK_STATUS.md` and validation records are the durable progress source.
Use concise commits describing the actual change, push tested checkpoints,
verify the remote SHA, and leave source/build caches out of Git. Clean only
known reproducible archives/scratch outputs; reuse compiled desktop artifacts.
