Current direction (2026-10-24): the user stopped Julia agent development and
authorized an inference-acceleration prototype. Active work is the independent
Julia package under `inference/` in this checkout. Preserve existing agent source,
DSH integration and historical measurements. Do not resume the old line-count
targets, editor work or agent integration. Start with measured CPU operators;
GPU acceleration and whole-model benefits require separate hardware and evidence.
Read `inference/README.md` and `inference/REPORT.md` for the current workflow.
For real CPU model evaluation read `inference/models/README.md` and use
`inference/scripts/setup-model.sh`; the smaller setup script removes model extras.
The fixed public SmolLM2 checkpoint is currently blocked at us.aws.cdn.hf.co.
Random-weight integration tests are not pretrained-model performance evidence.

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
The original current source now uses the ShenScope Contribution-Only License.
The repository remains private and is intended to become public later. Do not
change GitHub visibility, invite new external recipients to legacy history, or
treat historical Apache-labeled commits as ready
for restricted public release. `scripts/audit_publication_license.py` is read
only; a legacy-history finding is an expected publication blocker, not a source
test failure. Preserve private development history and follow the publication
plan in `docs/licensing/license_decision.md` when public release is requested.

Read `docs/requirements/reconstruction.md` and `WORK_STATUS.md` on resumption.
Earlier agent line-count targets are historical and do not apply to inference
work. Do not pad or duplicate code. Validate numerical correctness against an
independent higher-precision oracle, compare with preallocated Julia and compiled
PyTorch baselines, and retain losses as well as wins. Separate first invocation,
warm operator timings and larger computation fragments. Do not claim full-model
or GPU acceleration from CPU operator results.

Current implementation: Julia owns agent, model, tool, security, session, project
data and analysis logic. Mature-agent integration is under evaluation; do not
claim an upstream migration has already happened.
ShenScope is a general agent for projects in any language. Julia implements Core;
it does not constrain target projects. Keep tools, workflows and IDE entry points
language independent; report exact language coverage of specialized analysis.
Current product scope is CLI/TUI and Julia repository analysis. The user canceled
the VSIX sidebar and native Code-OSS IDE on 2026-10-11. These override older
attachment requirements: do not develop, package or routinely test those clients.
Retained editor source/docs/tests are historical references. Keep TypeScript
semantic helpers and external language services needed by repository analysis;
their present location under editors/ does not make them canceled UI features.
Reference checkouts under `/workspace/references` are research dependencies,
read only, not source material to copy or translate into Core.
Existing Code-OSS/VSCodium checkouts are retired build/research dependencies.
Do not create or refresh editor checkouts, overlays or desktop builds as part of
normal setup. Preserve the single-checkout/no-directory-copy storage rule.
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
