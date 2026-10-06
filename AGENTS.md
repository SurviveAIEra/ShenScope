# ShenScope development contract

The current request authorizes rebuilding the application and pushing reviewed,
tested checkpoints to `SurviveAIEra/ShenScope` on GitHub. Use this checkout;
do not create worktrees or copy the project directory. Normal feature pushes must
be fast-forward. The user explicitly authorized rewriting existing Git author and
committer identities to SurviveAIEra's GitHub noreply identity; that one history
replacement requires an exact remote SHA lease and preserved Git recovery bundle.
The user also explicitly authorized amending the initial project's LICENSE/NOTICE
attribution and replaying its descendants. That replacement likewise requires an
exact remote SHA lease, a verified Git-only recovery bundle, and checks that
every replayed tree differs only in those two files. Normal later pushes remain
fast-forward. Historical validation records retain their recorded identities;
`docs/validation/license-history-rewrite.json` maps the rewritten commits.

Read `docs/requirements/reconstruction.md` and `WORK_STATUS.md` on resumption.
The user's current phase target is 32,000 authored Julia Core code lines.
Prioritize missing everyday project capabilities. The earlier 250,000/500,000
figures are historical long-term planning, not this phase's stopping gate.
Count using cloc, excluding tests, documentation, generated
code, third-party code and Code-OSS. Never pad or duplicate code to reach it.
Complete this phase only after its size target and relevant functional checks
pass; report remaining product gates honestly.

Julia owns agent, model, tool, security, session, project data and analysis logic.
ShenScope is a general agent for projects in any language. Julia implements Core;
it does not constrain target projects. Keep tools, workflows and IDE entry points
language independent; report exact language coverage of specialized analysis.
Both native Code-OSS Workbench and a standalone VSIX are required clients.
Reference checkouts under `/workspace/references` are research dependencies,
read only, not source material to copy or translate into Core.
The single pinned Code-OSS checkout is the designated desktop build tree:
`scripts/apply_codeoss_overlay.py` may install the small authored overlay there.
Do not make another copy of that checkout. Keep all overlay source in this repo.
Research covers every named project across capabilities; maintain the capability
matrix and source evidence. Commit messages describe the current change only.

Keep each checkpoint runnable. Test changed behavior and affected interfaces;
do not repeatedly run unrelated tests or rebuild desktop distribution bundles.
Commit and push each coherent tested checkpoint. Confirm remote SHA afterward.
Never put credentials, raw chat logs, model keys or environment dumps into Git.

Keep at least 8 GiB free before large builds. Use one shared toolchain and depot.
Delete only known, reproducible temporary build outputs after validation.
Never recursively clean user data or source. Record disk use and safe cleanup.
Use an explicit command argument vector for child processes.
