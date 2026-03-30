#!/bin/bash
set -e

# Linux: raise file descriptor limit and ensure XDG_RUNTIME_DIR is writable
if [[ "$(uname)" == "Linux" ]]; then
    ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
fi
if [[ "$(uname)" == "Linux" ]] && [ ! -w "${XDG_RUNTIME_DIR:-}" ]; then
    # Must be on local /tmp — network-mounted $HOME breaks network namespace creation
    export XDG_RUNTIME_DIR="/tmp/${USER}-podman-runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

# Linux: redirect Podman's tmp scratch space to $HOME to avoid filling the
# root filesystem during layer commits ($HOME is on the large data disk).
if [[ "$(uname)" == "Linux" ]]; then
    export TMPDIR="$HOME/.podman-tmp"
    mkdir -p "$TMPDIR"
fi

# Reconcile any stale Podman internal state (e.g. after runtime dir change)
if [[ "$(uname)" == "Linux" ]]; then
    podman system migrate 2>/dev/null || true
fi

set -a
source config.env
set +a

build_image() {
    local R_VERSION=$1
    local PYTHON_VERSION=$2
    local TAG="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"

    echo "Building $TAG..."
    ISOLATION_OPT=""
    [[ "$(uname)" == "Linux" ]] && ISOLATION_OPT="--isolation=chroot"

    podman build \
        $ISOLATION_OPT \
        --platform linux/amd64 \
        --build-arg R_VERSION=${R_VERSION} \
        --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
        -f Containerfile \
        -t ${TAG} \
        .
    echo "Done: $TAG"
}

case "${1:-all}" in
    a)
        build_image $R_VERSION_A $PYTHON_VERSION_A
        ;;
    b)
        build_image $R_VERSION_B $PYTHON_VERSION_B
        ;;
    all)
        build_image $R_VERSION_A $PYTHON_VERSION_A
        build_image $R_VERSION_B $PYTHON_VERSION_B
        ;;
    *)
        echo "Usage: ./build.sh [a|b|all]"
        exit 1
        ;;
esac
