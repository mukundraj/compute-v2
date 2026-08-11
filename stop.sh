#!/bin/bash
set -e

# Ensure XDG_RUNTIME_DIR exists and is writable (needed for rootless Podman on headless Linux)
if [[ "$(uname)" == "Linux" ]] && [ ! -w "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="$HOME/.podman-data/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
fi

set -a
source config.env
[ -f config.local.env ] || { [ -f config.local.env.example ] && cp config.local.env.example config.local.env; }
[ -f config.local.env ] && source config.local.env
set +a

PROFILE="${1:-}"

if [ -z "$PROFILE" ]; then
    echo "Usage: ./stop.sh [profile|all] [jupyter|rstudio|vscode|claude|bash]"
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

# Every profile defined via R_VERSION_<X> in config.env/config.local.env, so
# `stop all` also targets user-defined profiles. Matches build.sh's helper.
list_profiles() { compgen -v | sed -n 's/^R_VERSION_\([A-Z0-9]*\)$/\1/p' | tr '[:upper:]' '[:lower:]'; }

case "$PROFILE" in
    all)
        if [ -n "$SERVICE" ]; then
            for p in $(list_profiles); do stop_container "ds-${SERVICE}-${p}"; done
        else
            for p in $(list_profiles); do stop_profile "$p"; done
        fi
        ;;
    *)
        # Any profile name; stopping a container that isn't running is a no-op.
        stop_profile "$PROFILE"
        ;;
esac

echo "Stopped."
