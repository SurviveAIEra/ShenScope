#!/usr/bin/env python3
"""Install pinned test language servers once in a shared cache; never copy a checkout."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

VERSIONS = {"pyright": "1.1.408", "typescript-language-server": "5.0.0", "typescript": "5.9.2"}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--verify", action="store_true", help="Verify an existing installation without downloading")
arguments = parser.parse_args()
modules = Path(os.environ.get("SHENSCOPE_LANGUAGE_SERVERS", "/workspace/tool-cache/language-servers/node_modules")).resolve()
if modules.name != "node_modules":
    raise SystemExit("SHENSCOPE_LANGUAGE_SERVERS must name the shared node_modules directory")
prefix = modules.parent
installed = all((modules / name / "package.json").is_file() for name in VERSIONS)
if not installed and not arguments.verify:
    prefix.mkdir(parents=True, exist_ok=True)
    npm = shutil.which("npm")
    if not npm:
        raise SystemExit("Install Node.js and npm before preparing language servers")
    subprocess.run([npm, "install", "--prefix", str(prefix), "--ignore-scripts", "--no-audit", "--no-fund",
                    *[f"{name}@{version}" for name, version in VERSIONS.items()]], check=True)
lock_file = prefix / "package-lock.json"
if not lock_file.is_file():
    raise SystemExit("The language-server installation has no reproducible npm lock")
lock = json.loads(lock_file.read_text())
result = []
for name, expected in VERSIONS.items():
    manifest = modules / name / "package.json"
    if not manifest.is_file() or json.loads(manifest.read_text()).get("version") != expected:
        raise SystemExit(f"Expected {name} {expected}; the installed package differs")
    record = lock["packages"].get(f"node_modules/{name}", {})
    if record.get("version") != expected or not record.get("integrity", "").startswith("sha512-"):
        raise SystemExit(f"The lock does not contain the pinned version and integrity for {name}")
    result.append({"name": name, "version": expected, "npm_integrity": record["integrity"]})
for name in ("pyright-langserver", "typescript-language-server"):
    if not (modules / ".bin" / name).is_file():
        raise SystemExit(f"Missing language-server entry point: {name}")
print(json.dumps({"node_modules": str(modules), "packages": result, "automatic_server_start": False}, indent=2))
