#!/usr/bin/env python3
"""Keep one shallow checkout per research dependency at its recorded revision."""
import argparse
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
cache = Path('/workspace/references')
cache.mkdir(exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--include-retired-editors', action='store_true',
                    help='Also prepare historical Code-OSS/VSCodium references.')
args = parser.parse_args()
for record in json.loads((root / 'docs/architecture/reference_lockfile.json').read_text()):
    if record['name'] in ('vscode', 'vscodium') and not args.include_retired_editors:
        print(record['name'] + ': retired; skipped')
        continue
    active_dsh = root.parent / 'DSH-JuliaScope'
    if record['name'] == 'deepseek-harness' and (active_dsh / '.git').exists():
        upstream = subprocess.check_output(['git','-C',str(active_dsh),'remote','get-url','upstream'],text=True).strip()
        if upstream.removesuffix('.git') != 'https://github.com/deepseek-ai/deepseek-harness':
            raise SystemExit('The active DSH fork must retain its verified upstream remote')
        pin = record['commit'] + '^{commit}'
        if subprocess.run(['git','-C',str(active_dsh),'cat-file','-e',pin],stderr=subprocess.DEVNULL).returncode:
            subprocess.run(['git','-C',str(active_dsh),'fetch','upstream',record['commit']],check=True)
        print(record['name'] + ': source pin available in active DSH fork; no duplicate checkout')
        continue
    checkout = cache / record['name']
    if not checkout.exists():
        subprocess.run(['git','clone','--depth','1','https://github.com/'+record['repository']+'.git',str(checkout)],check=True)
    observed = subprocess.check_output(['git','-C',str(checkout),'rev-parse','HEAD'],text=True).strip()
    if observed != record['commit']:
        dirty = subprocess.check_output(['git','-C',str(checkout),'status','--porcelain'],text=True)
        if dirty:
            raise SystemExit(f'Refusing to change modified reference checkout: {checkout}')
        subprocess.run(['git','-C',str(checkout),'fetch','--depth','1','origin',record['commit']],check=True)
        subprocess.run(['git','-C',str(checkout),'checkout','--detach',record['commit']],check=True)
    print(record['name']+': pinned')
