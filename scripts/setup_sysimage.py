#!/usr/bin/env python3
"""Prepare the optional compiler environment without copying or changing Core."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
records = json.loads((root / 'docs/architecture/reference_lockfile.json').read_text())
record = next(item for item in records if item['name'] == 'PackageCompiler.jl')
compiler = Path('/workspace/references') / record['name']
if not compiler.is_dir() or compiler.is_symlink():
    raise SystemExit('Clone the pinned references before preparing PackageCompiler')
observed = subprocess.check_output(['git', '-C', str(compiler), 'rev-parse', 'HEAD'], text=True).strip()
if observed != record['commit']:
    raise SystemExit('PackageCompiler checkout does not match the reference lock')
if shutil.disk_usage(root).free < 8 * 1024**3:
    raise SystemExit('Retain 8 GiB free before preparing the image build')
environment = root / '.local/packagecompiler-environment'
if environment.is_symlink():
    raise SystemExit('Refusing a compiler environment symlink')
environment.mkdir(parents=True, exist_ok=True)
if environment.resolve() != environment:
    raise SystemExit('Compiler environment must be a real local directory')
tracked = [root / 'Project.toml', root / 'Manifest.toml']
before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked]
julia = os.environ.get('SHENSCOPE_JULIA', '/workspace/toolchains/julia-1.11.7/bin/julia')
variables = dict(os.environ)
variables.setdefault('JULIA_DEPOT_PATH', '/workspace/julia-depot')
variables['JULIA_PKG_PRECOMPILE_AUTO'] = '0'
variables['JULIA_PKG_USE_CLI_GIT'] = 'true'
variables['JULIA_PKG_SERVER'] = ''
program = '''using Pkg
Pkg.activate(ARGS[1])
Pkg.develop([PackageSpec(path=ARGS[2]),PackageSpec(path=ARGS[3])])
Pkg.instantiate(;update_registry=false)
'''
subprocess.run([julia, '--startup-file=no', '--project=' + str(environment),
                '-e', program, '--', str(environment), str(compiler), str(root)],
               cwd=root, env=variables, check=True)
after = [hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked]
if after != before:
    raise SystemExit('Application dependency files changed during compiler setup')
print(json.dumps({'compiler_environment': str(environment),
                  'compiler_commit': observed, 'application_dependency_files_unchanged': True,
                  'project_directory_copies': 0}))
