#!/usr/bin/env python3
"""Install the official pinned Electron runtime, keeping verified archive data transient."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import tempfile
import urllib.request
import zipfile

checkout = Path('/workspace/references/vscode')
version = re.search(r'^target="([^"]+)"$', (checkout / '.npmrc').read_text(), re.M)[1]
name = f'electron-v{version}-linux-x64.zip'
expected = re.search(r'^([a-f0-9]{64}) \*' + re.escape(name) + r'$', (checkout / 'build/checksums/electron.txt').read_text(), re.M)[1]
destination = checkout / '.build/electron'
if (destination / 'electron').exists():
    print(destination / 'electron')
else:
    if shutil.disk_usage(checkout).free < 8 * 1024**3:
        raise SystemExit('At least 8 GiB free required')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='electron-', dir=destination.parent) as temporary:
        archive = Path(temporary) / name
        with urllib.request.urlopen(f'https://github.com/electron/electron/releases/download/v{version}/{name}', timeout=60) as response, archive.open('wb') as output:
            checksum = hashlib.sha256()
            total = 0
            while data := response.read(1024*1024):
                total += len(data)
                if total > 512 * 1024 * 1024:
                    raise SystemExit('Electron archive exceeds size limit')
                checksum.update(data)
                output.write(data)
        if checksum.hexdigest() != expected:
            raise SystemExit('Electron checksum mismatch')
        extracted = Path(temporary) / 'runtime'
        extracted.mkdir()
        with zipfile.ZipFile(archive) as package:
            for item in package.infolist():
                target = (extracted / item.filename).resolve()
                if not target.is_relative_to(extracted.resolve()):
                    raise SystemExit('Unsafe Electron archive path')
                package.extract(item, extracted)
                if target.is_file():
                    mode = item.external_attr >> 16
                    if mode & 0o111:
                        target.chmod(0o755)
        os.rename(extracted, destination)
    print(f'Electron {version} verified; downloaded archive removed.')
