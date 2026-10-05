#!/usr/bin/env python3
"""Report actual cloc counts, keeping client/helper/test code outside Julia Core."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
tool = os.environ.get('SHENSCOPE_CLOC') or shutil.which('cloc')
if tool:
    command = [tool]
else:
    source = Path('/workspace/references/cloc/cloc')
    if not source.is_file():
        raise SystemExit('Install cloc or set SHENSCOPE_CLOC to its executable path')
    command = ['perl', str(source)]

def count(path, *options):
    output = subprocess.check_output(command + ['--json', *options, str(path)], text=True)
    return json.loads(output)

core = count(root / 'src', '--exclude-dir=CLI')
cli = count(root / 'src/CLI')
extensions = count(root / 'ext') if (root / 'ext').is_dir() else {}
lines = core['Julia']['code']
print(json.dumps({
    'tool': 'cloc', 'version': core['header']['cloc_version'],
    'core': core['Julia'], 'cli_tui': cli['Julia'],
    'optional_julia_extensions': extensions.get('Julia', {'nFiles': 0, 'code': 0}),
    'minimum_core_target': 32000, 'remaining_lines': max(0, 32000-lines),
    'line_target_percent': round(lines/32000*100, 4),
    'excludes': ['CLI/TUI', 'tests', 'documentation', 'frontend', 'helper scripts', 'generated code', 'third-party code'],
    'meaning': 'Line count measures source size; it does not establish feature completeness or agent quality.'
}, indent=2))
