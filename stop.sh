#!/bin/bash
set -e

# Ensure XDG_RUNTIME_DIR exists and is writable (needed for rootless Podman on headless Linux)
if [[ "$(uname)" == "Linux" ]] && [ ! -w "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="$HOME/.podman-data/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
fi

set -a
source config.env
set +a

PROFILE="${1:-}"

if [ -z "$PROFILE" ]; then
    echo "Usage: ./stop.sh [a|b|all] [jupyter|rstudio|vscode|claude|bash]"
    exit 1
fi
SERVICE="${2:-}"

stop_profile() {
    local p="$1"
    if [ -n "$SERVICE" ]; then
        podman stop "ds-${SERVICE}-${p}" 2>/dev/null || true
    else
        podman stop ds-jupyter-${p} ds-rstudio-${p} ds-vscode-${p} ds-claude-${p} ds-bash-${p} 2>/dev/null || true
    fi
}

case "$PROFILE" in
    a)
        stop_profile a
        ;;
    b)
        stop_profile b
        ;;
    all)
        if [ -n "$SERVICE" ]; then
            podman stop "ds-${SERVICE}-a" "ds-${SERVICE}-b" 2>/dev/null || true
        else
            podman stop ds-jupyter-a ds-rstudio-a ds-vscode-a ds-claude-a ds-bash-a \
                         ds-jupyter-b ds-rstudio-b ds-vscode-b ds-claude-b ds-bash-b 2>/dev/null || true
        fi
        ;;
    *)
        echo "Usage: ./stop.sh [a|b|all] [jupyter|rstudio|vscode|claude|bash]"
        exit 1
        ;;
esac

echo "Stopped."
