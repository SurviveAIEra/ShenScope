# ShenScope for VS Code

Run the Julia coding agent in a trusted local workspace. Open the ShenScope
sidebar to chat, approve tools, inspect conversations and configure providers.
Model and budget settings are stored by Julia Core. Keys use VS Code secure
storage and are passed to Core over the local process pipe.

Install Julia 1.11 or later and instantiate the packaged `core/Project.toml`
once with `julia --project=<extension-directory>/core -e 'using Pkg; Pkg.instantiate()'`.
Use the launcher settings to select the Julia executable or an existing Core
checkout. This development VSIX contains authored Core source, not a bundled
Julia runtime. MCP, intelligence, skills and hooks remain in development.

The native ShenScope IDE has a separate Workbench contribution; it does not
require this extension.
