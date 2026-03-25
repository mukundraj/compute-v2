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
        ;;
    b)
        R_VERSION=$R_VERSION_B
        PYTHON_VERSION=$PYTHON_VERSION_B
        JUPYTER_PORT=$JUPYTER_PORT_B
        RSTUDIO_PORT=$RSTUDIO_PORT_B
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash]"
        exit 1
        ;;
esac

# Persistent packages directory (optional)
PACKAGES_VOLUMES=""
PACKAGES_ENV=""
if [ -n "${PACKAGES_DIR}" ]; then
    PKG_DIR=$(eval echo "${PACKAGES_DIR}/${PROFILE}")
    mkdir -p "${PKG_DIR}/r-libs"
    # r-libs: bind mount (plain file writes, works fine on macOS/virtiofs)
    # conda-envs: named volume (micromamba needs a native Linux fs; virtiofs causes permission errors)
    PACKAGES_VOLUMES="-v ${PKG_DIR}/r-libs:/opt/r-libs:Z \
                      -v ds-conda-envs-${PROFILE}:/opt/conda/envs"
    PACKAGES_ENV="-e R_LIBS_USER=/opt/r-libs"
fi

IMAGE="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${WORK_DIR}"
COMMON_VOLUMES="-v ${WORK_DIR}:${WORK_MOUNT}:Z \
                -v ds-claude-config-${PROFILE}:/root/.claude \
                -v ${SCRIPT_DIR}/templates/CLAUDE.md:${WORK_MOUNT}/CLAUDE.md:ro,Z"
COMMON_ENV="-e MAMBA_ROOT_PREFIX=/opt/conda -e WORK_MOUNT=${WORK_MOUNT}"

# GCP credentials (optional) — auto-derived unless manually set in config.env
if [ -z "${GCP_VOLUMES}" ] && [ -n "${GCP_SERVICE_ACCOUNT_KEY}" ]; then
    KEY_PATH=$(eval echo "${GCP_SERVICE_ACCOUNT_KEY}")
    GCP_VOLUMES="-v ${KEY_PATH}:/run/secrets/gcp-key.json:ro,Z"
    GCP_ENV="-e GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-key.json"
fi

# GCP bucket access (optional) — parse GCP_BUCKET_ACCESS into GCS_READ_PATHS / GCS_WRITE_PATHS
if [ -n "${GCP_BUCKET_ACCESS}" ]; then
    GCS_READ_PATHS=""
    GCS_WRITE_PATHS=""
    for entry in ${GCP_BUCKET_ACCESS}; do
        path="${entry%:*}"
        mode="${entry##*:}"
        case "$mode" in
            ro) GCS_READ_PATHS="${GCS_READ_PATHS:+$GCS_READ_PATHS }$path" ;;
            rw) GCS_READ_PATHS="${GCS_READ_PATHS:+$GCS_READ_PATHS }$path"
                GCS_WRITE_PATHS="${GCS_WRITE_PATHS:+$GCS_WRITE_PATHS }$path" ;;
        esac
    done
    GCP_ENV="${GCP_ENV} -e GCS_READ_PATHS=${GCS_READ_PATHS} -e GCS_WRITE_PATHS=${GCS_WRITE_PATHS}"
fi

echo "Profile $PROFILE: R=${R_VERSION} Python=${PYTHON_VERSION}"

case "$SERVICE" in
    jupyter)
        echo "Starting JupyterLab → http://localhost:${JUPYTER_PORT}"
        podman run -it --rm \
            -p 0.0.0.0:${JUPYTER_PORT}:8888 \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            ${GCP_VOLUMES} \
            ${GCP_ENV} \
            ${PACKAGES_VOLUMES} \
            ${PACKAGES_ENV} \
            -e JUPYTER_PASSWORD=$(whoami) \
            --name ds-jupyter-${PROFILE} \
            ${IMAGE} jupyter
        ;;
    rstudio)
        echo "Starting RStudio → http://localhost:${RSTUDIO_PORT}"
        podman run -it --rm \
            -p 0.0.0.0:${RSTUDIO_PORT}:8787 \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            ${GCP_VOLUMES} \
            ${GCP_ENV} \
            ${PACKAGES_VOLUMES} \
            ${PACKAGES_ENV} \
            -e PASSWORD=$(whoami) \
            --name ds-rstudio-${PROFILE} \
            ${IMAGE} rstudio
        ;;
    claude)
        echo "Starting Claude Code (profile $PROFILE)..."
        podman run -it --rm \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            ${GCP_VOLUMES} \
            ${GCP_ENV} \
            ${PACKAGES_VOLUMES} \
            ${PACKAGES_ENV} \
            --name ds-claude-${PROFILE} \
            ${IMAGE} claude
        ;;
    bash)
        echo "Starting shell (profile $PROFILE)..."
        podman run -it --rm \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            ${GCP_VOLUMES} \
            ${GCP_ENV} \
            ${PACKAGES_VOLUMES} \
            ${PACKAGES_ENV} \
            --name ds-bash-${PROFILE} \
            ${IMAGE} bash
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash]"
        exit 1
        ;;
esac
