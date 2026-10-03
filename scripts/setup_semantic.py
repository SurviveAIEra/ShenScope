#!/usr/bin/env python3
"""Verify the one shared, lockfile-pinned compiler installation without copying it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PIN = "5.9.2"


def verify(compiler, node):
    executable = shutil.which(node)
    if not executable:
        raise SystemExit("Node.js is required. Install the pinned Node runtime before semantic setup.")
    compiler = compiler.resolve(strict=True)
    if compiler.name != "typescript.js":
        raise SystemExit("Select the installed TypeScript lib/typescript.js compiler entry.")
    package = compiler.parent.parent / "package.json"
    metadata = json.loads(package.read_text())
    if metadata.get("name") != "typescript" or metadata.get("version") != PIN:
        raise SystemExit(f"Expected the pinned TypeScript {PIN} installation.")
    checked = subprocess.check_output([executable, "-e", "const ts=require(process.argv[1]);process.stdout.write(ts.version)", str(compiler)], text=True)
    if checked != PIN:
        raise SystemExit("The compiler API version differs from its package metadata.")
    lock = json.loads((ROOT / "editors/package-lock.json").read_text())
    if lock["packages"]["node_modules/typescript"]["version"] != PIN:
        raise SystemExit("The editor lockfile and semantic compiler pin disagree.")
    info = {
        "schema": 1,
        "compiler": str(compiler),
        "compiler_version": PIN,
        "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
        "package_lock_sha256": hashlib.sha256((ROOT / "editors/package-lock.json").read_bytes()).hexdigest(),
        "node": executable,
        "node_version": subprocess.check_output([executable, "--version"], text=True).strip(),
        "installation": "shared editor dependency; no compiler directory copies",
    }
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, default=Path(os.environ.get("SHENSCOPE_TYPESCRIPT", ROOT / "editors/node_modules/typescript/lib/typescript.js")))
    parser.add_argument("--node", default=os.environ.get("SHENSCOPE_NODE", "node"))
    parser.add_argument("--verify", action="store_true", help="Verification is always performed; this flag is explicit for setup/CI.")
    args = parser.parse_args()
    try:
        verify(args.compiler, args.node)
    except FileNotFoundError:
        raise SystemExit("Compiler installation is missing. Run npm ci --ignore-scripts in editors, or scripts/setup.sh --semantic.")
