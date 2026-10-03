# Julia extension and compiler diagnostics

Julia interfaces are ordinary multiple-dispatch functions. `contract_report`
inspects selected methods for concrete provider/tool/backend/analyzer types,
distinguishing required implementations from permitted defaults and missing or
ambiguous dispatch. It does not instantiate an extension, run its methods, inspect
runtime fields or print credentials. Method evidence includes module, signature,
source-relative location and line. A valid report establishes method presence,
not correct return values, cancellation, permissions or backend completeness.

`dispatch_ambiguities` checks loaded interface method pairs using Julia's real
`Base.isambiguous`. Pair/method/result counts are bounded and cancellation is
checked. A truncated scan never reports a complete audit. Test fixtures include
a deliberately ambiguous function; the current Core interfaces have no detected
ambiguities in that scope. This is not a scan of every dependency method.

`invoke_extension_latest` is an explicit `Base.invokelatest` boundary for an
already loaded trusted Julia callable. Dynamic permission is checked against its
module/function identity before invocation. It loads no file, accepts no source
string and provides no code archive or rollback. World Age and Julia Modules are
not sandboxes. Independent optional packages, weakdeps/extensions discovery and
analyzer version/promotion management remain separate unfinished work.

## Compiler evidence

The `diagnostics` tool and CLI expose `contracts`, `ambiguities`, `targets` and
`compile`. Compiler targets are a fixed list of trusted Core functions/signatures;
there is no string-to-expression/module evaluation or project source loading.
`Base.code_lowered` and `Base.code_typed(...; optimize=false)` produce actual
compiler output, inferred return types, slot/statement counts and nonconcrete
slot indicators. Typed IR may identify problems; a concrete return alone does
not prove stable intermediates, fast execution, or Julia superiority.

Compilation runs in a separate Julia process after dynamic and process approval.
It has request/response limits, 1–128 KiB retained IR, UTF-8-safe truncation,
timeout, cancellation and explicit process cleanup. The child inherits only
listed toolchain paths and a few platform variables, not model credentials.
It uses installed modules without producing another full project/cache copy.
The result explicitly reports `os_sandbox=false`: there is no enforced network,
write or memory isolation here. Arbitrary generated analyzers must await the
separate OS sandbox implementation; this helper is not that execution facility.
Compiler versions may change inferred types and IR, so reports record Julia's
version and separate compilation time from execution benchmarks.

```sh
bin/shenscope diagnostics contracts
bin/shenscope diagnostics ambiguities
bin/shenscope diagnostics targets
bin/shenscope diagnostics compile digest_string --allow-dynamic --allow-process
```

Human users can grant actions interactively; noninteractive compilation requires
explicit flags or configured permissions. Agent invocations go through the same
tool schema/permission engine and produce visible tool/approval/diagnostic events
in CLI, TUI, VSIX and native Workbench.

Research: Kaimon's pinned `src/reflection_tools.jl` demonstrates navigation from
runtime method evidence; `src/kaimon_tools.jl` keeps advanced introspection outside
its default agent surface. PromptingTools' `Project.toml` demonstrates independently
loadable weakdep extensions. These informed the boundary and pending package
work; no source was copied or translated into this implementation. ShenScope
uses fixed targets and explicit permissions rather than accepting evaluated
symbol/source strings. Relevant pins are in the reference lockfile.
