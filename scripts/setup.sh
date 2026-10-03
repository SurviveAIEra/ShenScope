#!/usr/bin/env bash
set -euo pipefail
SHENSCOPE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHENSCOPE_JULIA="$(python "$SHENSCOPE_ROOT/scripts/install_julia.py" | tail -n 1)"
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-/workspace/julia-depot}"
export JULIA_PKG_SERVER=""
export JULIA_PKG_USE_CLI_GIT=true
export JULIA_NUM_PRECOMPILE_TASKS=2
export JULIA_SSL_CA_ROOTS_PATH=/etc/ssl/certs/ca-certificates.crt
mkdir -p "$JULIA_DEPOT_PATH/registries"
if [[ ! -f "$JULIA_DEPOT_PATH/registries/General/Registry.toml" ]]; then
    git clone --depth 1 https://github.com/JuliaRegistries/General.git \
        "$JULIA_DEPOT_PATH/registries/General"
fi
cd "$SHENSCOPE_ROOT"
"$SHENSCOPE_JULIA" --startup-file=no --project=. \
    -e 'using Pkg; Pkg.instantiate(; update_registry=false); Pkg.precompile()'
"$SHENSCOPE_JULIA" --startup-file=no --project=. -e 'using ShenScope; exit(ShenScope.main(["--version"]))'
if [[ " $* " == *" --backends "* ]]; then
    python "$SHENSCOPE_ROOT/scripts/setup_backends.py"
fi
if [[ " $* " == *" --editors "* ]]; then
    cd "$SHENSCOPE_ROOT/editors"
    npm ci --cache /workspace/npm-cache --ignore-scripts --no-audit --no-fund
    npm run check
    npm run build
fi
