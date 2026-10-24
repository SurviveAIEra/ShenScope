#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/tool-cache/uv}"
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-/workspace/julia-depot}"
export JULIA_NUM_THREADS=1
cd "$repo_root"
python3 scripts/storage_guard.py --require-build-space
python3 scripts/install_julia.py
if [[ ! -x /workspace/toolchains/inference-python/bin/python ]]; then
    uv venv /workspace/toolchains/inference-python --python python3
fi
uv pip sync --python /workspace/toolchains/inference-python/bin/python --system-certs \
    --require-hashes --only-binary :all: --index-url https://pypi.org/simple \
    --index https://download.pytorch.org/whl/cpu inference/model-requirements.lock
PYTHONDONTWRITEBYTECODE=1 /workspace/toolchains/inference-python/bin/python inference/test/model_checks.py
PYTHONDONTWRITEBYTECODE=1 /workspace/toolchains/inference-python/bin/python inference/test/model_cache_checks.py
