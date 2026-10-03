#!/usr/bin/env python3
"""Install one checksum-pinned official Go compiler, with no checkout copies."""
import hashlib
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request
import os

VERSION = '1.27.1'
SHA256 = '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445'
root = Path(os.environ.get('SHENSCOPE_TOOLS_DIR', '/workspace/toolchains')); root.mkdir(parents=True, exist_ok=True)
destination = root / ('go-' + VERSION)
if not (destination / 'bin/go').exists():
    if shutil.disk_usage(root).free < 8 * 1024**3: raise SystemExit('Need at least 8 GiB free')
    with tempfile.TemporaryDirectory(prefix='go-install-', dir=root) as temporary:
        stage = Path(temporary); archive = stage / 'go.tar.gz'
        with urllib.request.urlopen(f'https://dl.google.com/go/go{VERSION}.linux-amd64.tar.gz', timeout=60) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
        if hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() != SHA256: raise SystemExit('Go checksum mismatch')
        with tarfile.open(archive) as source: source.extractall(stage, filter='data')
        (stage / 'go').rename(destination)
print(destination / 'bin/go')
