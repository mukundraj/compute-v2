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
# Machine-local, untracked overrides (e.g. APT_PACKAGES). See config.local.env.example.
# Auto-seed from the tracked example on first run; the copy stays gitignored.
[ -f config.local.env ] || { [ -f config.local.env.example ] && cp config.local.env.example config.local.env; }
[ -f config.local.env ] && source config.local.env
set +a

build_image() {
    local R_VERSION=$1
    local PYTHON_VERSION=$2
    # Optional 3rd arg: "true" builds the stripped lightweight variant (no CUDA
    # / no scientific-Python / no torch / no heavy-R) under a distinct -lite
    # tag, gated in the Containerfile by the LIGHTWEIGHT build-arg.
    local LIGHTWEIGHT="${3:-false}"
    local TAG
    if [ "$LIGHTWEIGHT" = "true" ]; then
        TAG="ds-env-lite-r${R_VERSION}-py${PYTHON_VERSION}"
    else
        TAG="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"
    fi
    # Build-ID stamp: passed into the image as IMAGE_BUILD_ID and persisted
    # into /opt/conda/envs/denv/.image-build-id, so entrypoint.sh can detect
    # when ds-conda-envs-<profile> is stale (built against an older image).
    local BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)"

    echo "Building $TAG (build ID: $BUILD_ID)..."
    ISOLATION_OPT=""
    [[ "$(uname)" == "Linux" ]] && ISOLATION_OPT="--isolation=chroot"

    podman build \
        $ISOLATION_OPT \
        $EXTRA_BUILD_ARGS \
        --platform linux/amd64 \
        --build-arg R_VERSION=${R_VERSION} \
        --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
        --build-arg LIGHTWEIGHT=${LIGHTWEIGHT} \
        --build-arg IMAGE_BUILD_ID=${BUILD_ID} \
        -f Containerfile \
        -t ${TAG} \
        .
    echo "Done: $TAG"
}

# List every profile defined via R_VERSION_<X> in config.env/config.local.env
# (uppercased suffix -> lowercased profile name). LITE_REF_* is deliberately
# outside this namespace, so `all` never builds the bake-only lite reference.
list_profiles() { compgen -v | sed -n 's/^R_VERSION_\([A-Z0-9]*\)$/\1/p' | tr '[:upper:]' '[:lower:]'; }

# Build a single named profile, honoring its LIGHTWEIGHT_<X> flag.
build_one() {
    local uc; uc=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local rv="R_VERSION_${uc}" pv="PYTHON_VERSION_${uc}" lt="LIGHTWEIGHT_${uc}"
    if [ -z "${!rv:-}" ]; then
        echo "Error: profile '$1' not defined (no R_VERSION_${uc})." >&2
        exit 1
    fi
    build_image "${!rv}" "${!pv}" "${!lt:-false}"
}

EXTRA_BUILD_ARGS=""
for arg in "$@"; do
    case "$arg" in
        --no-cache) EXTRA_BUILD_ARGS="$EXTRA_BUILD_ARGS --no-cache" ;;
    esac
done

case "${1:-all}" in
    all)
        # Build every defined profile, deduped by resulting image tag so
        # profiles that share versions (and lite flag) build only once.
        declare -A _seen
        for p in $(list_profiles); do
            uc=$(echo "$p" | tr '[:lower:]' '[:upper:]')
            rv="R_VERSION_${uc}"; pv="PYTHON_VERSION_${uc}"; lt="LIGHTWEIGHT_${uc}"
            if [ "${!lt:-false}" = "true" ]; then tag="ds-env-lite-r${!rv}-py${!pv}"
            else tag="ds-env-r${!rv}-py${!pv}"; fi
            [ -n "${_seen[$tag]:-}" ] && continue
            _seen[$tag]=1
            build_image "${!rv}" "${!pv}" "${!lt:-false}"
        done
        ;;
    lite)
        # Build the bake-only lightweight reference image at the tracked
        # LITE_REF_* versions (consumed by publish.sh -> bake_compute_v2.yml).
        # NOT a launch profile and NOT part of `all`.
        build_image "$LITE_REF_R_VERSION" "$LITE_REF_PYTHON_VERSION" true
        ;;
    *)
        build_one "$1"
        ;;
esac
