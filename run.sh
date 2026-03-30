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

PROFILE=${1:-a}
SERVICE=${2:-jupyter}

case "$PROFILE" in
    a)
        R_VERSION=$R_VERSION_A
        PYTHON_VERSION=$PYTHON_VERSION_A
        JUPYTER_PORT=$JUPYTER_PORT_A
        RSTUDIO_PORT=$RSTUDIO_PORT_A
        VSCODE_PORT=$VSCODE_PORT_A
        ;;
    b)
        R_VERSION=$R_VERSION_B
        PYTHON_VERSION=$PYTHON_VERSION_B
        JUPYTER_PORT=$JUPYTER_PORT_B
        RSTUDIO_PORT=$RSTUDIO_PORT_B
        VSCODE_PORT=$VSCODE_PORT_B
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode]"
        exit 1
        ;;
esac

IMAGE="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${WORK_DIR}"

COMMON_VOLUMES=(
    -v "${WORK_DIR}:${WORK_MOUNT}:Z"
    -v "ds-claude-config-${PROFILE}:/root/.claude"
    -v "${SCRIPT_DIR}/templates/CLAUDE.md:${WORK_MOUNT}/CLAUDE.md:ro,Z"
)
COMMON_ENV=(
    -e "MAMBA_ROOT_PREFIX=/opt/conda"
    -e "WORK_MOUNT=${WORK_MOUNT}"
)

# GCP credentials (optional) — auto-derived unless manually overridden in config.env.
# GCP_VOLUMES / GCP_ENV overrides (from config.env) are word-split intentionally;
# they must not contain spaces within individual values.
GCP_ARGS=()
if [ -n "${GCP_VOLUMES:-}" ]; then
    # shellcheck disable=SC2206
    GCP_ARGS+=(${GCP_VOLUMES})
elif [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ]; then
    KEY_PATH=$(eval echo "${GCP_SERVICE_ACCOUNT_KEY}")
    GCP_ARGS+=(-v "${KEY_PATH}:/run/secrets/gcp-key.json:ro,Z"
               -e "GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-key.json")
fi

# GCP_ENV override (rarely needed — only set if you need to inject extra env vars)
if [ -n "${GCP_ENV:-}" ]; then
    # shellcheck disable=SC2206
    GCP_ARGS+=(${GCP_ENV})
fi

# GCP bucket access — parse GCP_BUCKET_ACCESS into comma-separated path lists.
# Comma delimiter avoids word-splitting when the value is passed to podman run.
if [ -n "${GCP_BUCKET_ACCESS:-}" ]; then
    GCS_READ_PATHS=""
    GCS_WRITE_PATHS=""
    for entry in ${GCP_BUCKET_ACCESS}; do
        path="${entry%:*}"
        mode="${entry##*:}"
        case "$mode" in
            ro) GCS_READ_PATHS="${GCS_READ_PATHS:+${GCS_READ_PATHS},}${path}" ;;
            rw) GCS_READ_PATHS="${GCS_READ_PATHS:+${GCS_READ_PATHS},}${path}"
                GCS_WRITE_PATHS="${GCS_WRITE_PATHS:+${GCS_WRITE_PATHS},}${path}" ;;
        esac
    done
    [ -n "$GCS_READ_PATHS"  ] && GCP_ARGS+=(-e "GCS_READ_PATHS=${GCS_READ_PATHS}")
    [ -n "$GCS_WRITE_PATHS" ] && GCP_ARGS+=(-e "GCS_WRITE_PATHS=${GCS_WRITE_PATHS}")
fi

# Persistent packages directory (optional)
PACKAGES_ARGS=()
if [ -n "${PACKAGES_DIR:-}" ]; then
    PKG_DIR=$(eval echo "${PACKAGES_DIR}/${PROFILE}")
    mkdir -p "${PKG_DIR}/r-libs"
    # r-libs: bind mount (plain file writes, works fine on macOS/virtiofs)
    # conda-envs: named volume (micromamba needs a native Linux fs; virtiofs causes permission errors)
    PACKAGES_ARGS+=(
        -v "${PKG_DIR}/r-libs:/opt/r-libs:Z"
        -v "ds-conda-envs-${PROFILE}:/opt/conda/envs"
        -e "R_LIBS_USER=/opt/r-libs"
    )
fi

echo "Profile $PROFILE: R=${R_VERSION} Python=${PYTHON_VERSION}"

case "$SERVICE" in
    jupyter)
        echo "Starting JupyterLab → http://localhost:${JUPYTER_PORT}"
        podman run -it --rm \
            -p "0.0.0.0:${JUPYTER_PORT}:8888" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "JUPYTER_PASSWORD=$(whoami)" \
            --name "ds-jupyter-${PROFILE}" \
            "${IMAGE}" jupyter
        ;;
    rstudio)
        echo "Starting RStudio → http://localhost:${RSTUDIO_PORT}"
        podman run -it --rm \
            -p "0.0.0.0:${RSTUDIO_PORT}:8787" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            --name "ds-rstudio-${PROFILE}" \
            "${IMAGE}" rstudio
        ;;
    claude)
        echo "Starting Claude Code (profile $PROFILE)..."
        podman run -it --rm \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            --name "ds-claude-${PROFILE}" \
            "${IMAGE}" claude
        ;;
    bash)
        echo "Starting shell (profile $PROFILE)..."
        podman run -it --rm \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            --name "ds-bash-${PROFILE}" \
            "${IMAGE}" bash
        ;;
    vscode)
        echo "Starting VS Code Server → http://localhost:${VSCODE_PORT}"
        podman run -it --rm \
            -p "0.0.0.0:${VSCODE_PORT}:8080" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            -v "ds-vscode-config-${PROFILE}:/root/.local/share/code-server" \
            --name "ds-vscode-${PROFILE}" \
            "${IMAGE}" vscode
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode]"
        exit 1
        ;;
esac
