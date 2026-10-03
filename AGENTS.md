# ShenScope development contract

The current request authorizes rebuilding the application and pushing reviewed,
tested checkpoints to `SurviveAIEra/ShenScope` on GitHub. Use this checkout;
do not create worktrees or copy the project directory. No force pushes.

Read `docs/requirements/reconstruction.md` and `WORK_STATUS.md` on resumption.
The minimum target is 250,000 authored Julia Core code lines, with 500,000 as
the stretch target. Count using cloc, excluding tests, documentation, generated
code, third-party code and Code-OSS. Never pad or duplicate code to reach it.
Do not report the whole task complete before the target and functional gates pass.

Julia owns agent, model, tool, security, session, project data and analysis logic.
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
