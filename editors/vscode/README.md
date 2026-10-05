# ShenScope for VS Code

Run the Julia coding agent in a trusted local workspace. Open the ShenScope
sidebar to chat, approve tools, inspect conversations and configure providers.
Model and budget settings are stored by Julia Core. Keys use VS Code secure
storage and are passed to Core over the local process pipe.

Install Julia 1.11 or later and instantiate the packaged `core/Project.toml`
once with `julia --project=<extension-directory>/core -e 'using Pkg; Pkg.instantiate()'`.
Use the launcher settings to select the Julia executable or an existing Core
checkout. This development VSIX contains authored Core source, not a bundled
Julia runtime. Both editor clients share views for project intelligence, MCP,
skills, hooks, analyzers and extensions. Some newer Core tools/RPC operations
do not yet have a dedicated graphical control.

Project's **Show in Problems** publishes source-checked Core diagnostics into
VS Code's Problems view. Unsaved edits and file/configuration/session changes
clear ShenScope's markers. **Clear Problems** removes only ShenScope diagnostics.
Cached publication requires Read Allow. Terminal and Testing are also connected
to the same Core; imported SARIF is currently a Core tool/RPC action.

The native ShenScope IDE has a separate Workbench contribution; it does not
require this extension.
