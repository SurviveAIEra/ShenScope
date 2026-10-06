#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash scripts/install_cli.sh [--bin-dir DIRECTORY]

Install the shenscope command as a symbolic link to this checkout.
The default directory is $HOME/.local/bin. No project files are copied.
Install Julia and the project's Julia dependencies before running the command.
USAGE
}

SHENSCOPE_INSTALL_BIN="${HOME:?HOME is required}/.local/bin"
while (( $# )); do
    case "$1" in
        --bin-dir)
            if (( $# < 2 )) || [[ -z "$2" ]]; then
                printf 'install_cli: --bin-dir requires a directory\n' >&2
                exit 2
            fi
            SHENSCOPE_INSTALL_BIN="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'install_cli: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

SHENSCOPE_INSTALL_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHENSCOPE_INSTALL_SOURCE="$SHENSCOPE_INSTALL_ROOT/bin/shenscope"
if [[ ! -x "$SHENSCOPE_INSTALL_SOURCE" ]]; then
    printf 'install_cli: executable bin/shenscope is missing from this checkout\n' >&2
    exit 1
fi
mkdir -p -- "$SHENSCOPE_INSTALL_BIN"
SHENSCOPE_INSTALL_BIN="$(cd -P -- "$SHENSCOPE_INSTALL_BIN" && pwd)"
SHENSCOPE_INSTALL_TARGET="$SHENSCOPE_INSTALL_BIN/shenscope"
if [[ -e "$SHENSCOPE_INSTALL_TARGET" || -L "$SHENSCOPE_INSTALL_TARGET" ]]; then
    if [[ -L "$SHENSCOPE_INSTALL_TARGET" && "$(readlink "$SHENSCOPE_INSTALL_TARGET")" == "$SHENSCOPE_INSTALL_SOURCE" ]]; then
        printf 'Already installed: %s\n' "$SHENSCOPE_INSTALL_TARGET"
    else
        printf 'install_cli: refusing to replace an existing command: %s\n' "$SHENSCOPE_INSTALL_TARGET" >&2
        exit 1
    fi
else
    ln -s "$SHENSCOPE_INSTALL_SOURCE" "$SHENSCOPE_INSTALL_TARGET"
    printf 'Installed: %s -> %s\n' "$SHENSCOPE_INSTALL_TARGET" "$SHENSCOPE_INSTALL_SOURCE"
fi

case ":${PATH:-}:" in
    *":$SHENSCOPE_INSTALL_BIN:"*) printf 'Ready: shenscope --help\n' ;;
    *)
        printf 'Add this directory to PATH in your shell configuration, then open a new terminal:\n'
        printf 'export PATH=%q:"$PATH"\n' "$SHENSCOPE_INSTALL_BIN"
        ;;
esac
