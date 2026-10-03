#!/usr/bin/env python3
"""Keep one shallow checkout per research dependency at its recorded revision."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
cache = Path('/workspace/references')
cache.mkdir(exist_ok=True)
for record in json.loads((root / 'docs/architecture/reference_lockfile.json').read_text()):
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
