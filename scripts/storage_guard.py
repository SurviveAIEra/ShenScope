#!/usr/bin/env python3
"""Report storage, and clean only registered reproducible scratch artifacts."""
import argparse
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
SAFE = [ROOT / ".local/tmp", ROOT / ".local/build-scratch"]


def report():
    usage = shutil.disk_usage(ROOT)
    return {
        "total_gib": round(usage.total / 1024**3, 3),
        "free_gib": round(usage.free / 1024**3, 3),
        "large_build_allowed": usage.free >= 8 * 1024**3,
        "safe_scratch_paths": [str(p) for p in SAFE],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--clean-scratch", action="store_true")
    parser.add_argument("--require-build-space", action="store_true")
    args = parser.parse_args()
    if args.clean_scratch:
        for path in SAFE:
            if path.is_symlink():
                raise SystemExit(f"Refusing to follow scratch symlink: {path}")
            if path.exists():
                shutil.rmtree(path)
    result = report()
    print(json.dumps(result, indent=2))
    if args.require_build_space and not result["large_build_allowed"]:
        raise SystemExit("Large build refused: reserve 8 GiB first.")
