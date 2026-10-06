# ShenScope

**Understand the code. See the scope of a change.**

[简体中文](README.md) · English · [Documentation](#documentation) · [Authorship and license](#authorship-and-license)

ShenScope is an AI coding assistant initiated by [SurviveAIEra](https://github.com/SurviveAIEra), with an independently implemented Julia Core. It helps you explore a repository, investigate bugs, edit code and run tests through a CLI, terminal UI, VS Code extension or standalone development IDE.

The project plans to make its source public under a [restricted contribution-only license](LICENSE). It is not standard open source. Permission is limited to preparing, testing and submitting improvements to ShenScope; use on unrelated projects or independent distribution requires separate authorization.

It works with projects in Python, JavaScript/TypeScript, Go, C/C++ and other languages. Julia implements the agent; you do not need to write your project in Julia or learn Julia for everyday use.

ShenScope focuses on changes to existing codebases: **Who calls this interface? What might a change affect? Which files and tests should you inspect first? How do you check rules specific to your project?** It keeps code relationships locally, uses Julia functions to traverse and filter them, and gives the model relevant source and analysis results.

- **Reuse project data.** Symbols, dependencies and call relationships stay in the running Core, with caching, persistence and incremental updates for saved files.
- **Write project-specific analysis.** Add ordinary Julia analyzers, or ask a model to propose one and validate it before use.
- **Choose the code intelligence backend.** Go AST, Tree-sitter, CodeGraphContext and the TypeScript compiler supply a common data interface. Analyzers stay independent of database-specific schemas.
- **Bring your own models and tools.** Use supported model protocols, MCP, Skills and Hooks, or connect internal services through independent Julia extension packages.

*Born in Shenzhen. Built with Julia.*

## An idea from a walk in Shenzhen

ShenScope began with an idea that came to its creator, SurviveAIEra, during a walk through Talent Park in Nanshan, Shenzhen. The city's towers stood against a landscape of mountains and sea. Taking in that view gave a thought about coding tools room to take shape.

When using existing agents, the creator often saw them return to `grep` and similar text searches: find a piece of code, search for another, then open more files. Search is useful, but a matching line still leaves questions about calls, module dependencies and the consequences of a change. A developer who knows a codebase carries those relationships in mind. An assistant should be able to build on that knowledge as it moves between tasks.

That became ShenScope's starting point: **give the agent a lasting view of the relationships inside a project, with tools to analyze them.** Keep code indexes locally and update them as files change. Use local programs to follow calls, trace dependencies and select relevant tests. Give the model the resulting analysis and source so it can investigate and propose changes. Project-specific rules can become small analysis programs, validated and reused. This is the reason for the resident project state, interchangeable backends and programmable analyzers.

Julia brought the other half of the idea. The creator had used it before and loved its combination of expressive code and high performance. It offered one runtime for project data, graph computation and custom analysis, with ordinary functions, multiple dispatch, dynamic loading and JIT compilation. Familiarity and affection for Julia met the wish to redesign how an agent works with code. ShenScope is built in Julia and serves codebases written in many languages.

The name carries its origin: **Shen** comes from Shenzhen and also suggests looking deeply into code; **Scope** means understanding a project's structure and the reach of a change.

There is much to love about Shenzhen: engineering teams at work among the towers, mountains and sea close to the city, and parks where there is room to slow down and think. It is a place with both the energy to build an idea and the scenery that can spark one. We invite you to get to know Shenzhen. If you visit, take a walk through Talent Park and along Shenzhen Bay. That is where this project's story began.

## Quick start

ShenScope currently runs from source. Install **Julia 1.11 or a newer compatible version** first. These commands use Bash on Linux/macOS.

### 1. Prepare Core and install the command

```bash
git clone https://github.com/SurviveAIEra/ShenScope.git
cd ShenScope
export SHENSCOPE_JULIA="$(command -v julia)"
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-$HOME/.julia}"
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
bash scripts/install_cli.sh
export PATH="$HOME/.local/bin:$PATH"
shenscope --help
```

The installer creates a `shenscope` link in `~/.local/bin` pointing to this checkout; it does not copy the project. The `export` makes it available in the current terminal. Add that line to `~/.bashrc` for Bash or `~/.zshrc` for Zsh to make the command available in future terminals.

Install once, then run `shenscope` from any directory. Keep this checkout and update it with `git pull`. The `bin/shenscope` spelling runs a file directly from the repository; once installed on `PATH`, the shorter command works. See the [command installation guide](docs/cli-installation.md) for a custom location, Julia selection and troubleshooting.

### 2. Configure a model

Save the following as your own `shenscope.toml`. This example uses OpenAI Chat; change the endpoint and model to match your service.

```toml
[provider]
protocol = "openai_chat"
name = "my-service"
endpoint = "https://api.openai.com/v1"
model = "gpt-4.1"
key_env = "SHENSCOPE_MODEL_KEY"

[permissions]
read = "allow"
edit = "ask"
process = "ask"
network = "ask"
mcp = "ask"
dynamic = "ask"
persistence = "ask"
```

Put the API key in the `SHENSCOPE_MODEL_KEY` environment variable. The configuration stores only its name. In Bash, this prompt keeps the key off the screen and out of the command's shell history:

```bash
read -r -s -p 'Model API key: ' SHENSCOPE_MODEL_KEY
export SHENSCOPE_MODEL_KEY
```

OpenAI Responses, Anthropic, Gemini and Ollama are also supported. Other services can use the protocol they implement. See [model services](docs/core/models.md) for configuration details.

### 3. Open your project

After installing the command, run these from any directory, replacing the project and configuration paths:

```bash
shenscope doctor --root /path/to/project --config /path/to/shenscope.toml
shenscope tui --root /path/to/project --config /path/to/shenscope.toml
```

Try a first prompt in the TUI:

```text
Explain this repository's layout and find its main entry points and tests.
```

For a command-line task, Plan mode investigates and proposes work:

```bash
shenscope chat "Find callers of this interface and explain what changing it might affect" \
  --root /path/to/project --config /path/to/shenscope.toml --agent-mode plan
```

Graph analysis requires its backend dependencies and an index; see [project data and indexing](docs/core/project_data.md). Ordinary file search, edits and test commands can run without a code graph.

## Terminal, VS Code and standalone IDE

| Interface | How to use it |
|---|---|
| CLI | Start tasks in a terminal or integrate them into scripts |
| TUI | Keep an interactive conversation, follow tool execution and approve actions |
| VS Code extension | Install a standalone VSIX into your existing VS Code and open the ShenScope sidebar |
| ShenScope IDE | Build a standalone development editor from Code-OSS; its native sidebar works with extensions disabled |

All four interfaces use Julia Core for models, configuration, conversations, permissions and analysis. The two editor clients share panels and integrate with native Terminal, Testing and Problems views. You can run tests from the test view and publish project diagnostics to Problems.

### Build the VS Code extension

After preparing Core, install Node.js, npm and Python 3, then run from the repository root:

```bash
npm --prefix editors ci --ignore-scripts --no-audit --no-fund
npm --prefix editors run check
npm --prefix editors run build
python scripts/package_vsix.py
code --install-extension dist/shenscope-0.1.0.vsix
```

Open the ShenScope sidebar in a trusted local workspace. Set `shenscope.juliaPath` to your Julia executable and `shenscope.corePath` to the absolute path of your prepared ShenScope checkout. Model keys can also use VS Code secure storage.

The VSIX includes Core source without a bundled Julia runtime. To use its packaged Core, install that Core's Julia dependencies separately; see the [extension guide](editors/vscode/README.md).

### Standalone IDE

**There is no complete downloadable ShenScope IDE installer yet.** A working source development build and native sidebar integration are available. Installers, bundled Julia, upgrades and uninstall support remain unfinished. Follow the [IDE build guide](ide/README.md) to run it from source.

## Inside Julia Core

### Keep project relationships available

Suppose you are changing a public interface. ShenScope can follow indexed callers, list potentially affected locations, filter related tests and examine which files have historically changed together. The model can then inspect relevant code and propose a change. Local functions handle graph traversal and filtering.

A resident `ProjectState` holds files, symbols, relationships and forward/reverse indexes for repeated queries. Indexes can be persisted and updated incrementally after saved-file changes. Results record the source versions they describe, making stale analysis identifiable.

This keeps repeated queries and deterministic computation local, while the model handles requirements, code generation and engineering decisions. See [project data](docs/core/project_data.md), [saved-file monitoring](docs/core/project_watch.md) and [Git history analysis](docs/core/git_history.md).

### Separate data sources from analysis

Backends extract code information. Core represents symbols, relations and source locations through shared interfaces. Analyzers perform the computation.

| Data source | Current coverage |
|---|---|
| Go AST | Declarations, imports and candidate calls through Go's official parser; call candidates lack Go type-checker confirmation |
| Tree-sitter | Multilanguage syntax with partial declaration and relationship extraction |
| CodeGraphContext | Actual SDK and Ladybug graph storage, adapted to Core's data model |
| TypeScript compiler | JS/TS types, definitions, references, calls, implementations and diagnostics |
| JuliaSyntax | Additional syntax analysis for Julia projects |
| External LSP | Navigation, completion, signatures and call hierarchy according to the configured server's capabilities |

The same impact and test-selection analyzers can operate on different backends. An internal code graph can implement an adapter and reuse existing analysis methods.

Saved observations from multiple backends can also be queried together while retaining their origins. Syntax candidates, compiler-confirmed references and runtime samples have different meanings. External LSP currently synchronizes disk files; unsaved editor-buffer synchronization is unfinished. See [combined queries](docs/core/combined_evidence.md), [TypeScript semantics](docs/core/semantic.md) and [language services](docs/core/language_services.md) for exact coverage.

### Add analysis for your project's rules

Rules such as “business logic must not call storage directly” or “check these modules before changing this interface” vary between projects. Built-in analysis covers change impact, test candidates, Git cochanges, architecture dependencies, migration ordering and risk candidates. More specific rules can be ordinary Julia functions.

A model can also propose a temporary analyzer. Core passes selected project data to a separate process, runs external test fixtures and checks referenced symbols and relations. A validated analyzer can serve the current task; reusable methods can be archived, selected for project or user scope, updated and rolled back.

Julia functions, dynamic loading and JIT compilation provide one language for authoring and running these methods. Generated analysis code executes separately. Linux x86_64 has verified seccomp restrictions against file opens, network access and child-process creation, with time and output limits. Isolation on other platforms remains unfinished. See [custom analyzers](docs/core/isolated_analyzers.md) for contracts and lifecycle.

### Connect internal tools through independent packages

Providers, tools, data backends and analyzers use Julia types and multiple dispatch. An extension can live in its own Julia package, implement methods for its types, and be checked and activated by Core. Julia package extensions provide optional loading.

Core checks missing methods, signatures and dispatch ambiguities. Failed activation retains a failure state; deactivation stops new calls and waits for existing calls to finish. These facilities support internal model services, indexes and specialized tools, and make extension conflicts easier to inspect.

Extensions are trusted code running in Core. Custom analyzers use the separate isolation flow above. See [Julia extensions](docs/core/julia_extension_lifecycle.md) for interfaces and resource management.

### Coordinate background work in the same runtime

Julia `Task`, `Channel` and bounded worker pools coordinate model streams, tools, indexing and background tasks. `ScopedValue` carries the current execution context; Core manages permissions, budgets and cancellation. Background tasks record dependencies, claims and results, while clients can inspect progress or cancel work. See [task scheduling](docs/core/tasks.md) for implementation and limits.

### Inspect Core's own computation

Developers can inspect compiler IR, inferred types, allocations and sampled call stacks for supported Core functions. Julia's reflection and compiler interfaces make these checks accessible through ordinary tools when investigating slow or allocation-heavy analysis.

These checks concern Julia Core itself. Python, Go, C++ and other user projects use their corresponding parsers, language services, tests and check commands. See [runtime inspection](docs/core/julia_diagnostics.md), [compiler IR](docs/core/compiler_ir.md) and [profiling](docs/core/runtime_profiling.md).

## Coding features

- **Models:** five protocols, streaming, native reasoning information, discovery, budgets, routing and failure handling.
- **Investigation and planning:** file search, source reads, Plan/Act, editable task plans, context trimming and summaries.
- **Editing:** multifile proposals, diff previews, source checks before application, conflict handling and failure rollback. LSP rename, formatting and code actions can become reviewable proposals.
- **Verification:** project-defined tests, compiler and check commands, test execution/cancellation, saved results, SARIF import and source-version-associated diagnostics.
- **Continuity:** saved conversations and branches, versioned memory, persistent task dependencies and execution records.
- **External capabilities:** MCP stdio / Streamable HTTP, project/user Skills and lifecycle Hooks.
- **Permissions:** independent Allow / Ask / Deny for reads, edits, processes, network, MCP, dynamic code and persistence.

ShenScope remains in development. Live-model task quality, large-codebase performance and cross-platform distribution need further validation. Some Core features are available through tools or RPC without a dedicated graphical control.

## Open-source references

ShenScope studies agent designs and user workflows, then implements its own Core in Julia. Its primary references are:

| Project | Main areas studied |
|---|---|
| [Codex](https://github.com/openai/codex) | Tool execution and approval, cancellation, request boundaries, app-server and terminal interaction |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | Plugin architecture, events, durable state, scheduling, exclusive execution and task lifecycle |
| [OpenCode](https://github.com/anomalyco/opencode) | Provider adaptation, conversations, context compaction, MCP/LSP and client/server separation |
| [Pi](https://github.com/badlogic/pi-mono) | Raw messages versus model context, task steering, branches, Skills and extension interfaces |
| [Kimi Code](https://github.com/MoonshotAI/kimi-code) | Native reasoning, request protection, trust, cancellation, plugins and terminal interaction |
| [ZCode](https://github.com/zai-org/ZCode) | Turns, steering and queues, context compaction, CLI and desktop workflows |
| [Qwen Code](https://github.com/QwenLM/qwen-code) | Multiple providers, Plan/Act, MCP/Hooks/Skills/LSP and CLI/IDE/SDK interface organization |

Specialized references include:

- **Code understanding:** [Aider](https://github.com/Aider-AI/aider) for repository maps and edit feedback, [Serena](https://github.com/oraios/serena) for semantic navigation, and [CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext) for code graphs. CodeGraphContext is also an implemented backend.
- **Execution and durable work:** [Cline](https://github.com/cline/cline), [OpenHands](https://github.com/All-Hands-AI/OpenHands), [Software Agent SDK](https://github.com/OpenHands/software-agent-sdk), [Hermes Agent](https://github.com/NousResearch/hermes-agent) and [Goose](https://github.com/block/goose).
- **Resident computation and Julia tools:** [Aries CLI](https://github.com/aayoawoyemi/Aries-cli), [AgentREPL.jl](https://github.com/samtalki/AgentREPL.jl), [JuliaMCP.jl](https://github.com/julia-vscode/JuliaMCP.jl), [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl) and [PromptingTools.jl](https://github.com/svilupp/PromptingTools.jl).
- **Editors and distribution:** [Code-OSS](https://github.com/microsoft/vscode), [VSCodium](https://github.com/VSCodium/vscodium) and [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl). The standalone IDE builds on Code-OSS, with its code and license retained separately.

These projects have different scopes. The list identifies design references; consult the [capability matrix](docs/architecture/capability_matrix.md), [source research](docs/architecture/reference_synthesis.md) and [pinned revisions](docs/architecture/reference_lockfile.json) for specific review and implementation coverage.

## Documentation

| Topic | Starting points |
|---|---|
| Models and failure handling | [Services](docs/core/models.md) · [Routing](docs/core/model_routing.md) · [Retry policy](docs/core/model_policy.md) |
| Project intelligence | [Data](docs/core/project_data.md) · [Combined queries](docs/core/combined_evidence.md) · [Impact and migration](docs/core/migration.md) |
| Edits, tests and diagnostics | [Workspace edits](docs/core/workspace_edits.md) · [Testing](docs/core/project_testing.md) · [Validation](docs/core/project_validation.md) |
| Custom computation | [Isolated analyzers](docs/core/isolated_analyzers.md) · [Julia extensions](docs/core/julia_extension_lifecycle.md) |
| External capabilities | [MCP](docs/core/mcp.md) · [Skills](docs/core/skills.md) · [Hooks](docs/core/hooks.md) |
| Continuing work | [Context](docs/core/context.md) · [Memory](docs/core/memory.md) · [Tasks](docs/core/tasks.md) |
| Editors and builds | [VS Code extension](editors/vscode/README.md) · [Standalone IDE](ide/README.md) |

## Development

Core lives in `src/`, CLI/TUI in `src/CLI/` and optional Julia extensions in `ext/`. `editors/` contains shared panels and the VS Code extension; `ide/` contains standalone editor integration.

```bash
julia --startup-file=no --threads=4 --project=. test/runtests.jl
npm --prefix editors run check
npm --prefix editors test
```

Backend, language-server and GUI checks require the dependencies described in their module guides. Existing verification records are in [docs/validation](docs/validation/). Report issues or suggestions through [GitHub Issues](https://github.com/SurviveAIEra/ShenScope/issues).

## Authorship and license

ShenScope was initiated by **SurviveAIEra**. Its specific designs and implementations for resident project data, interchangeable backends, programmable analysis and Julia extensions are recorded in this repository's documentation and commit history.

Original source uses [ShenScope Contribution-Only License 1.0](LICENSE), with attribution in [NOTICE](NOTICE). It permits copying, modification, building and testing for Project contributions. It does not authorize unrelated personal or business use, commercial deployment, independent releases or derivative products. Rights under law, platform terms and prior lawful grants remain intact.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution instructions and explicit contribution terms. Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). The [authorship and license guide](docs/project_authorship.md) explains the scope and future public-repository preparation.
