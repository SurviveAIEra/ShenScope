# Local Git evidence and review analysis

Julia owns snapshot acquisition, strict protocol parsing, the project-data join,
co-change ranking and review-priority scoring. Git supplies local commit and
numstat facts. No upstream implementation was copied or translated.

## Snapshot authority and bounds

`git_history_snapshot(context; limits=GitHistoryLimits())` supports an ordinary
repository with `.git` directly within the workspace root. A nested workspace,
linked worktree, submodule Git pointer, external object alternate, graft or
included Git configuration is rejected. Supporting another metadata scope is
separate work; this reader never copies a repository or creates a worktree.

Read permission covers local history evidence. Every child phase uses the
existing process permission engine with its exact argv and workspace. Allow
once approves that phase; session grants bind to the exact command target.
Network permission is not requested. Argument vectors and a fresh environment
remove ambient Git/config/loader injection. Global/system config, external
diff, textconv, signatures, notes, user attributes, hooks and pager execution
are disabled; optional locks and lazy fetching are disabled. Git 2.43 or later
is required. This guarded host-process reader does not prove general OS
filesystem/network isolation.

Phases read version, full HEAD and shallow status, acquire history pinned to
that commit, and verify HEAD again. Metadata declarations are checked around
approval and commands. Cancellation, revocation, shared wall-clock budget and
an operation deadline terminate the child process group and release its owned
handle. Public errors name the phase; stderr is not returned. No Git mutation
is requested.

History uses first-parent traversal and merge diffs against the first parent,
`--no-renames --numstat -z`, and NUL-delimited full identity/parents/timestamp
headers. Paths preserve spaces, tabs, newlines and Unicode. Invalid UTF-8,
absolute/traversing paths, malformed counts, duplicate file records, broken
first-parent identities and unterminated records fail the snapshot. SHA-1 and
SHA-256 identities are accepted. Binary line counts remain unknown. Empty
commits remain in history.

Defaults: 128 commits plus one lookahead, 512 retained changes per commit,
32,768 parsed changes, 4 MiB stdout, 120-second history deadline. Output loss
fails instead of joining retained head/tail data into an incomplete history.
File-cap overflow is recorded and excludes that commit from coupling evidence.
The lookahead records a commit limit; shallow status is independent. Raw bytes
have a retained SHA-256 and byte count. Protected paths cannot supply analysis
candidates. Deleted/unindexed historical files are counted in coverage. Renames
appear as deletion/addition; staged, untracked and working-tree changes are
outside this view.

## Project join and co-change

`GitCochangeAnalyzer()` accepts at most 128 indexed path/symbol seeds. It
captures file hashes, symbol counts, distinct file dependencies, capabilities
and a revision under the project mutex, then releases the mutex before running
Git. The revision must still match at delivery. Indexed contents are not
asserted to match Git HEAD: coverage says `index_matches_head = "not_checked"`.

Commits with more than `bulk_threshold` files, default 32, are excluded from
coupling and ordinary churn statistics. For each seed/candidate pair:

```
dice = 2 * joint_commits / (seed_commits + candidate_commits)
support_confidence = joint_commits / (joint_commits + 2)
score = dice * support_confidence
```

Default minimum support is two commits. Multiple seeds use the maximum
association; deterministic ties use file path. Eight best seed associations
and eight newest evidence commits per association are retained; omissions are
reported. Support confidence is an explicit regularizer, not a calibrated
probability or causal conclusion.

Ranking buffers are bounded. The requested candidate limit is 100 by default,
1,000 maximum, with a separate 3 MiB candidate payload cap. Total counts include
qualifying candidates omitted by result caps. No persistent analysis cache is
created.

## Review priority

`RiskAnalyzer()` considers selected indexed files, or all indexed files without
seeds. Results identify themselves as `heuristic_review_priority`. Each
component clips `log1p(value) / log1p(reference)` to one:

| Component | Weight | Reference |
|---|---:|---|
| Added plus removed non-bulk lines | 0.35 | 10,000 |
| Non-bulk change frequency | 0.30 | Retained non-bulk commits |
| Distinct incoming indexed files | 0.25 | 100 |
| Mean other files changed together | 0.10 | 32 |

High priority starts at 0.7; medium at 0.4. Raw metrics, components, weights,
exact commits, binary unknowns and excluded bulk counts accompany the score.
These are review heuristics, not defect rates. Dependency evidence is limited
by backend coverage; no test, ownership or vulnerability outcome is implied.

## Shared interfaces

Project tool actions `git_cochange` and `risk` require an existing index:

```bash
shenscope project build --backend tree_sitter --allow-process --allow-persistence
shenscope project git_cochange src/main.jl --allow-process --history-limit 128 --bulk-threshold 32 --minimum-support 2
shenscope project risk --allow-process --limit 30
```

RPC uses asynchronous `project/start`, conversation-owned `project/job` /
`project/cancel`, and ordinary `permissions/respond`. Synchronous
`project/query` does not execute Git. Request fields include `paths`, `symbols`,
`revision`, `history_limit`, `bulk_threshold`, `minimum_support`, `limit` and
`history_timeout` (0.05–600 seconds).

Native Workbench and VSIX share Commit evidence controls, file candidates,
commit disclosures, HEAD/revision/partial-coverage information and source
opening. Both render Julia results without reimplementing ranking.

## Validation and remaining scope

Owned temporary repositories contain tiny authored fixtures. Tests exercise
actual Git, NUL filenames, binaries, empty commits, lookahead, shallow history,
environment scrubbing, denial, expiry, declaration/HEAD conflicts, cancellation
and exact commit evidence. Real Tree-sitter indexing validates RPC/CLI joins;
both actual editor clients validate Go AST indexing and Git results without
model requests. Failed attempts are retained in checkpoint 021.

Remote history, side branches, rename lineage, ownership, calibrated risk,
migration planning, installed-package/native distribution and Windows runtime
validation remain separate work. The 250,000 authored Julia Core-line minimum
remains active and unmet.
