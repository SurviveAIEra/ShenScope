#!/usr/bin/env python3
"""Fetch pinned Electron declarations from the official npm package and verify them."""
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import urllib.request

checkout = Path('/workspace/references/vscode')
version = re.search(r'^target="([^"]+)"$', (checkout / '.npmrc').read_text(), re.M)[1]
checksums = (checkout / 'build/checksums/electron.txt').read_text()
expected = re.search(r'^([a-f0-9]{64}) \*electron\.d\.ts$', checksums, re.M)[1]
target = checkout / '.build/typings/electron.d.ts'
if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
    print('Electron declarations already match the pinned checksum.')
else:
    with urllib.request.urlopen('https://registry.npmjs.org/electron/' + version, timeout=30) as response:
        metadata = json.load(response)
    with urllib.request.urlopen(metadata['dist']['tarball'], timeout=30) as response:
        archive = response.read(16 * 1024 * 1024 + 1)
    if len(archive) > 16 * 1024 * 1024:
        raise SystemExit('Electron package exceeded expected size')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as package:
        content = package.extractfile('package/electron.d.ts').read()
    if hashlib.sha256(content).hexdigest() != expected:
        raise SystemExit('Electron declarations differ from the Code-OSS pinned checksum')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    print('Verified pinned Electron declarations; no runtime archive retained.')
