# Skills

Julia Core owns SKILL.md discovery, metadata, activation, resources and prompt
projection. CLI, native Workbench and standalone VSIX use the same manager and
session references. No upstream agent implementation is embedded or translated.

## Sources and precedence

Default project sources are `.shenscope/skills`, `.agents/skills` and
`.claude/skills`. The default user source is `~/.config/shenscope/skills`.
Explicit project sources remain confined to the workspace; user sources must
be explicit absolute paths. Both scopes pass the read permission engine.
Source and resource symlinks are rejected. Protected secret/Git paths are denied.

```toml
[skills]
project_roots = [".shenscope/skills", ".agents/skills"]
user_roots = ["/absolute/user/skills"]
disabled = ["obsolete-skill"]
max_entries = 20000
max_depth = 8
max_skills = 512
```

Only SKILL.md roots are discovered. A discovered root stops deeper discovery;
hidden directories and dependency/build directories are skipped. Configured
project sources precede user sources, with configuration order breaking ties.
All same-name sources retain distinct IDs and provenance. The default name
resolves to the first source; explicit IDs can select another source. Disabling
the selected source does not silently fall through to a lower-priority source.
Catalog diagnostics report invalid documents, shadowing, unknown metadata and
capacity exhaustion. Truncation remains visible.

The traversal caps processed entries/depth/documents. Current `readdir` allocates
one directory's name vector before checking its entry count; a streaming native
directory iterator remains necessary for hostile directories with enormous
entry counts. Static path checks and read permissions do not establish an OS
sandbox or eliminate filesystem races against another local process.

## Metadata and lazy instructions

Frontmatter uses pinned YAML.jl 0.4.17 as a parsing dependency. Core independently
validates event depth/node limits and mapping/scalar types before constructing
metadata. Duplicate keys, explicit tags, anchors, aliases, multiple documents,
nonfinite numbers and excessive nesting are rejected. Literal/folded strings,
quoted Unicode, lists and nested metadata are supported. Names follow the
lowercase Agent Skills naming convention; descriptions have a 1024-character cap.
YAML.jl scalar resolution is not a claim of every upstream dialect's compatibility.

```markdown
---
name: review-code
description: Review changes using inspected source and test evidence
allowed-tools: [Read, Grep]
disable-model-invocation: false
user-invocable: true
metadata:
  owner: team
---
Inspect the changed files before making a recommendation.
Task-specific guidance: $ARGUMENTS
```

Catalogs retain metadata and whole-source hashes. Discovery reads bounded source
bytes to validate/hash a document; bodies are not cached in the catalog or put
in model context. Available metadata has a separate 16 KiB projection budget.
Bodies are loaded on explicit activation; resources require separate reads.
Scripts, backticks and hook-looking metadata never execute automatically.
Unknown fields remain visible as metadata and produce a diagnostic.

`allowed-tools` supports exact names and familiar Read/Write/Edit/Bash/Grep/Glob
aliases. It narrows model declarations, with intersections across active skills;
the skills control stays available for deactivation. It grants no permissions
and is not a security boundary. Shell permission patterns, implicit hook
registration, skill-directed model routing and positional argument dialects are
not implemented. `$ARGUMENTS`, `${SHENSCOPE_SKILL_DIR}` and
`${SHENSCOPE_SESSION_ID}` are literal substitutions, bounded before allocation.
No environment variable expansion or evaluation occurs.

## Activation and persistence

At most eight skills and 256 KiB of expanded bodies can be active per session.
Activation checks the catalog/source digest before loading and again after any
persistence approval. Changed sources require reload and explicit activation;
old bodies are not silently replaced. Active model context rechecks source
hashes and skips stale instructions. Model-disabled skills require explicit user
invocation; user-disabled invocation flags are also checked.

Only source identity, hash and arguments are persisted in the conversation
journal. The agent and skills share the actual Session object so tool activation
does not desynchronize its journal revision. Resume rehydrates only matching
source revisions through read permissions. Session/workspace ownership remains
separate from the project-wide catalog. Persistence denial publishes no activation.
The parent cancellation token and permission policy remain shared.

## Clients and RPC

```sh
shenscope skills list --root /workspace/project
shenscope skills source review-code --root /workspace/project
shenscope skills activate review-code "review the patch" --session ID --allow-persistence
shenscope skills deactivate review-code --session ID --allow-persistence
shenscope skills resource review-code references/checklist.md
```

CLI activation requires an existing conversation ID. Core RPC uses skills/start,
skills/job and skills/cancel_job for permissioned asynchronous operations, with
skills/query for already-authorized cached metadata. Eight operations and 64
retained jobs are bounded; results are capped at 4 MiB, aggregate retained job
results at 16 MiB. Configuration changes block while jobs run. Activation changes
and agent starts are serialized at the conversation boundary.

Both editor views show project/user sources, enabled state, source paths,
metadata, load state, reload and explicit activation/deactivation. Opening a
source goes through a completed permissioned source-read job. The Core validates
owner, source identity, content hash, current Deny policy, a five-minute lifetime
and one-time consumption before returning the path to the editor. This also
supports approved user sources outside the workspace without accepting arbitrary
outside paths from model links or Webview messages.

Remote installation/marketplaces, watchers, directory streaming, broad dialect
interoperability and automatic plugin package loading remain unfinished.
