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

case "${1:-all}" in
    a)
        podman stop ds-jupyter-a ds-rstudio-a 2>/dev/null || true
        ;;
    b)
        podman stop ds-jupyter-b ds-rstudio-b 2>/dev/null || true
        ;;
    all)
        podman stop ds-jupyter-a ds-rstudio-a ds-jupyter-b ds-rstudio-b 2>/dev/null || true
        ;;
    *)
        echo "Usage: ./stop.sh [a|b|all]"
        exit 1
        ;;
esac

echo "Stopped."
