#!/usr/bin/env python3
"""Package the small authored Core and editor assets, never a repository backup."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
extension = root / 'editors/vscode'
core = extension / 'core'
core.mkdir(exist_ok=True)
for name in ('Project.toml', 'Manifest.toml', 'LICENSE', 'NOTICE'):
    shutil.copyfile(root / name, core / name)
for source in (root / 'src').rglob('*.jl'):
    destination = core / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
for source in (root / 'ext').rglob('*.jl'):
    destination = core / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
for source in (root / 'scripts/backends').glob('*'):
    if source.suffix not in ('.py', '.go', '.mjs'):
        continue
    destination = core / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
shutil.copyfile(root / 'LICENSE', extension / 'LICENSE')
output = root / 'dist'
output.mkdir(exist_ok=True)
subprocess.run([str(root / 'editors/node_modules/.bin/vsce'), 'package', '--no-dependencies',
                '--out', str(output / 'shenscope-0.1.0.vsix')], cwd=extension, check=True)
print(output / 'shenscope-0.1.0.vsix')
