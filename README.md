# ShenScope

Open coding intelligence for serious codebases. Born in Shenzhen. Built with Julia.

ShenScope is an independent Julia coding agent under active development.
Current capabilities, validation evidence and remaining work are recorded in
`WORK_STATUS.md`.

```sh
bash scripts/setup.sh
bin/shenscope --version
bin/shenscope doctor --state-dir .local/state
```

The minimum scope includes a model-neutral Julia agent runtime, CLI/TUI,
permissions, persistent sessions and workflows, MCP/skills/hooks, incremental
project intelligence, controlled dynamic analyzers, a native Code-OSS sidebar
and a standalone VSIX. The minimum size goal is 250,000 authored Core code
lines. Work in progress is not represented as a finished release.

See `docs/requirements/reconstruction.md` for precedence and acceptance rules,
and `docs/architecture/competitive_reference_notes.md` for source research.
