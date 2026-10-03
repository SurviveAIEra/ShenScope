# ShenScope native IDE

The sidebar is a native Code-OSS `ViewPane`. The shared utility process owns
Julia Core; it works with extensions disabled. All agent/configuration/session
logic stays in Julia. The standalone VSIX is a separate supported client.

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
