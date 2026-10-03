#!/usr/bin/env python3
"""Prepare shared real parser dependencies once; do not duplicate project/reference trees."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import venv

REPO = Path(__file__).resolve().parents[1]
TOOLS = Path(os.environ.get('SHENSCOPE_TOOLS_DIR', '/workspace/toolchains'))
REFERENCES = Path(os.environ.get('SHENSCOPE_REFERENCES', '/workspace/references'))
CACHE = Path(os.environ.get('SHENSCOPE_PARSER_CACHE', '/workspace/tool-cache'))
PIN = '642c3215f8ef87fba03bc5dea6dbcb28d655fbd8'
TOOLS.mkdir(parents=True, exist_ok=True); REFERENCES.mkdir(parents=True, exist_ok=True); CACHE.mkdir(parents=True, exist_ok=True)
if shutil.disk_usage(TOOLS).free < 8 * 1024**3: raise SystemExit('Need at least 8 GiB free before parser setup')
sdk = REFERENCES / 'CodeGraphContext'
if not (sdk / '.git').exists():
    sdk.mkdir(exist_ok=True)
    subprocess.run(['git', 'init', str(sdk)], check=True)
    subprocess.run(['git', '-C', str(sdk), 'remote', 'add', 'origin', 'https://github.com/CodeGraphContext/CodeGraphContext.git'], check=True)
    subprocess.run(['git', '-C', str(sdk), 'fetch', '--depth', '1', 'origin', PIN], check=True)
    subprocess.run(['git', '-C', str(sdk), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
observed = subprocess.check_output(['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip()
if observed != PIN: raise SystemExit('CodeGraphContext revision differs from the pinned SDK')
environment = TOOLS / 'codegraph-venv'
if not environment.exists(): venv.create(environment, with_pip=True)
python = environment / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
subprocess.run([str(python), '-m', 'pip', 'install', '--no-cache-dir', '-r', str(REPO / 'scripts/backends/requirements.lock')], check=True)
subprocess.run([str(python), '-m', 'pip', 'install', '--no-cache-dir', '--no-deps', '-e', str(sdk)], check=True)
env = dict(os.environ, XDG_CACHE_HOME=str(CACHE), SHENSCOPE_TOOLS_DIR=str(TOOLS))
subprocess.run([str(python), '-c', 'from tree_sitter_language_pack import get_parser; [get_parser(language) for language in ["python","go","javascript","typescript","rust","java","julia"]]'], env=env, check=True)
go = subprocess.check_output([sys.executable, str(REPO / 'scripts/install_go.py')], env=env, text=True).strip()
helper = TOOLS / 'shenscope-go-ast'
subprocess.run([go, 'build', '-o', str(helper), str(REPO / 'scripts/backends/go_ast.go')],
               env=dict(env, GOCACHE=str(CACHE / 'go-build'), GOTELEMETRY='off'), check=True)
# Downloaded grammar archives are reproducible; loaded native libraries and their manifest remain.
for archive in (CACHE / 'tree-sitter-language-pack/v1.20.0/bundles').glob('*.tar.zst'): archive.unlink()
settings = {'SHENSCOPE_PARSER_PYTHON': str(python), 'SHENSCOPE_GO_HELPER': str(helper), 'SHENSCOPE_PARSER_CACHE': str(CACHE)}
result = TOOLS / 'shenscope-backends.json'; result.write_text(json.dumps(settings, indent=2)+'\n')
print(result)
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'], 'a') as output:
        for name, value in settings.items(): output.write(name+'='+value+'\n')
