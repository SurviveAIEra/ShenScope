# Cloud development environment

Product checkout: `/workspace/DSH-JuliaScope`, branch `master`. Read its
`AGENTS.md`, `docs/user/juliascope.md` and `evaluation/REPORT.md`. The original
Core checkout `/workspace/ShenScope` on `main` remains available for Core
reference and its existing terminal tooling. Reuse both checkouts and shared
toolchains; do not clone a second DSH research checkout.

```sh
cd /workspace/ShenScope
bash scripts/setup.sh
export PATH="$HOME/.local/bin:$PATH"
shenscope --version
shenscope doctor --state-dir .local/state
```

Setup installs a single `~/.local/bin/shenscope` link to this checkout. It copies
no source directories and refuses to replace an unrelated existing command.
The directory is already on PATH in this cloud; the export above also supports
other shells. Once dependencies are prepared, install/repair just the command
with `bash scripts/install_cli.sh`, without repeating backend or editor setup.
See [command installation](cli-installation.md) for persistent shell settings,
custom locations and Julia selection. The installed launcher works from any
directory; pass `--root` to select the target project.

`scripts/setup.sh --semantic` prepares the shared lockfile-pinned TypeScript
compiler without building the retired editor clients. Add `--backends` to prepare pinned CodeGraphContext,
Tree-sitter grammars and the Go AST compiler/helper in shared locations.
See `docs/core/project_data.md` for alternate paths and validation commands.
`scripts/clone_references.py` prepares the one pinned
checkout per research dependency; it refuses to replace changed references.
Code-OSS and VSCodium cloning is skipped by default. Existing editor source and
checkouts are historical references after cancellation of the VSIX and native
IDE; do not run editor builds, GUI validation or packaging in normal development.
Research/depot/registry checkouts are not application repository membership.

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
`python test/integration/tui_pty.py --launcher shenscope`. Repository analysis:
`python scripts/setup_semantic.py --verify` and the affected Julia backend tests.
No model-quality or Windows validation follows from these local fixtures.

`WORK_STATUS.md` and validation records are the durable progress source.
Use concise commits describing the actual change, push tested checkpoints,
verify the remote SHA, and leave source/build caches out of Git. Clean only
known reproducible archives/scratch outputs. Retired GUI outputs need not be rebuilt.
