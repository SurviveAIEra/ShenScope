#!/usr/bin/env python3
"""Install a pinned official Julia OCI layer with SHA-256 verification.

The registry token is public read-only authentication and is never logged.
Existing toolchains are reused. No Docker daemon or image unpack copy is needed.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "1.11.7"
LAYER = "sha256:4a695f03af55a8be1b1c5d34345a35e3f2d95d1ae0ce06fd24a16c32d0016110"
REGISTRY = "https://registry-1.docker.io/v2/library/julia"


def install():
    if os.uname().machine != "x86_64":
        raise SystemExit("This verified toolchain installer supports Linux x86_64 only.")
    target = Path(os.environ.get("SHENSCOPE_TOOLCHAINS", "/workspace/toolchains"))
    target.mkdir(parents=True, exist_ok=True)
    julia_dir = target / f"julia-{VERSION}"
    binary = julia_dir / "bin/julia"
    if binary.is_file():
        result = subprocess.run([str(binary), "--version"], check=True, capture_output=True, text=True)
        if result.stdout.strip() != f"julia version {VERSION}":
            raise SystemExit("Existing toolchain version mismatch; refusing to overwrite it.")
        return binary
    if shutil.disk_usage(target).free < 8 * 1024**3:
        raise SystemExit("Need at least 8 GiB free before installing the shared toolchain.")
    with urllib.request.urlopen(
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/julia:pull",
        timeout=30,
    ) as response:
        token = json.load(response)["token"]
    request = urllib.request.Request(
        f"{REGISTRY}/blobs/{LAYER}", headers={"Authorization": f"Bearer {token}"}
    )
    with tempfile.TemporaryDirectory(prefix="julia-download-", dir=target) as temp:
        archive_path = Path(temp) / "layer.tar.gz"
        digest = hashlib.sha256()
        with urllib.request.urlopen(request, timeout=60) as response, archive_path.open("wb") as stream:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                stream.write(chunk)
        if "sha256:" + digest.hexdigest() != LAYER:
            raise SystemExit("Official OCI layer failed SHA-256 verification.")
        # Install into a staging directory; publish it only after successful extraction.
        stage = Path(temp) / "runtime"
        with tarfile.open(archive_path) as archive:
            for member in archive:
                prefix = "usr/local/julia/"
                name = member.name.removeprefix("./")
                if name.startswith(prefix):
                    member.name = name[len(prefix):]
                    if member.name:
                        archive.extract(member, stage, filter="data")
        subprocess.run([str(stage / "bin/julia"), "--version"], check=True)
        if julia_dir.exists():
            raise SystemExit("Partial existing toolchain needs inspection; not overwritten.")
        stage.rename(julia_dir)
    return binary


if __name__ == "__main__":
    print(install())
