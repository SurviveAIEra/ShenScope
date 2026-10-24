#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
toolchain_root="${SHENSCOPE_TOOLCHAINS:-/workspace/toolchains}"
python_env="$toolchain_root/inference-python"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/tool-cache/uv}"

cd "$repo_root"
python3 scripts/storage_guard.py --require-build-space
python3 scripts/install_julia.py
if [[ ! -x "$python_env/bin/python" ]]; then
    uv venv "$python_env" --python python3
fi
uv pip sync --python "$python_env/bin/python" --system-certs \
    --index-url https://download.pytorch.org/whl/cpu \
    --require-hashes --only-binary :all: inference/requirements.lock

export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-/workspace/julia-depot}"
export JULIA_PKG_OFFLINE=true
"$toolchain_root/julia-1.11.7/bin/julia" --startup-file=no --project=inference \
    inference/test/runtests.jl
export JULIA_NUM_THREADS=1
export SHEN_INFERENCE_JULIA="$toolchain_root/julia-1.11.7/bin/julia"
PYTHONDONTWRITEBYTECODE=1 "$python_env/bin/python" inference/test/benchmark_checks.py
PYTHONDONTWRITEBYTECODE=1 "$python_env/bin/python" inference/test/bridge_checks.py
