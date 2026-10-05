# ShenScope native IDE

**There is no complete downloadable IDE installer yet.** This is a standalone
development IDE based on Code-OSS. It can run from the source-build workflow below.
Installers, bundled Julia, upgrades and uninstall support remain unfinished.

The ShenScope sidebar is part of the editor itself and works with extensions
disabled. A Code-OSS shared utility process starts Julia Core. Agent,
configuration and session logic stays in Julia. The standalone VSIX is a
separate client for an existing VS Code installation.

The native Terminal, Testing and Problems views use Core-owned results. Project's
**Show in Problems** checks current source buffers before publishing markers;
edits and Read revocation withdraw them. **Clear Problems** clears ShenScope's
own markers. This integration is verified with extensions disabled.

Use the single pinned `/workspace/references/vscode` checkout. Do not copy it.
`scripts/apply_codeoss_overlay.py` installs only authored overlay files and
patches two entrypoints plus product branding/Open VSX settings. Exact source
paths, pin and license remain tracked here; Code-OSS source is not counted as Core.

Validated development flow:

```sh
python scripts/apply_codeoss_overlay.py
python scripts/prepare_codeoss.py
cd /workspace/references/vscode
npm ci --cache /workspace/npm-cache --ignore-scripts
npm --prefix build ci --cache /workspace/npm-cache --ignore-scripts
npm run typecheck-client
node build/next/index.ts transpile
cd /workspace/ShenScope
python scripts/install_electron.py
node ide/test/native_smoke.mjs
```

The GUI test uses a locally extracted apt-verified Xvfb under
`/workspace/toolchains/xvfb`. It uses isolated temporary user data and a local
HTTP model fixture. It does not contact a real model or change user IDE settings.
The upstream built-in-extension build needs its own extension dependencies;
typecheck/client GUI validation is not a complete desktop distribution build.

Windows-first installer/portable/upgrade/uninstall packaging, bundled Julia,
full parity, branding assets and release checksums remain in development.
Large source/binary build outputs stay outside Git and need not be rebuilt on
every Core change. Reuse the compiled desktop while Julia modules develop.
After the initial client transpilation, authored panel/channel-only changes can
use `node scripts/transpile_codeoss_panel.mjs` following overlay installation.
This updates a few modules and CSS in place. The standalone Webview uses
`cd editors && npm run check && npm run build`; its GUI test adds `--vsix` to
`ide/test/native_smoke.mjs`. Project-view validation also requires backend setup.
