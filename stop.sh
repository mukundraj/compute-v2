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

stop_container() {
    local name="$1"
    podman stop "$name" 2>/dev/null || true
}

stop_profile() {
    local p="$1"
    if [ -n "$SERVICE" ]; then
        stop_container "ds-${SERVICE}-${p}"
    else
        for svc in jupyter rstudio vscode claude bash; do
            stop_container "ds-${svc}-${p}"
        done
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
            for p in a b; do stop_container "ds-${SERVICE}-${p}"; done
        else
            for p in a b; do stop_profile "$p"; done
        fi
        ;;
    *)
        echo "Usage: ./stop.sh [a|b|all] [jupyter|rstudio|vscode|claude|bash]"
        exit 1
        ;;
esac

echo "Stopped."
