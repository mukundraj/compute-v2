#!/bin/bash
set -e

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

IMAGE="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"
COMMON_VOLUMES="-v ./work:/home/rstudio/work:Z \
                -v ${NPM_GLOBAL_PREFIX}:/opt/npm-global:ro,Z \
                -v ~/.claude:/root/.claude:ro,Z"
COMMON_ENV="-e NPM_CONFIG_PREFIX=/opt/npm-global \
            -e MAMBA_ROOT_PREFIX=/opt/conda"

echo "Profile $PROFILE: R=${R_VERSION} Python=${PYTHON_VERSION}"

case "$SERVICE" in
    jupyter)
        echo "Starting JupyterLab → http://localhost:${JUPYTER_PORT}"
        podman run -it --rm \
            -p ${JUPYTER_PORT}:8888 \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            --name ds-jupyter-${PROFILE} \
            ${IMAGE} jupyter
        ;;
    rstudio)
        echo "Starting RStudio → http://localhost:${RSTUDIO_PORT}"
        podman run -it --rm \
            -p ${RSTUDIO_PORT}:8787 \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            -e PASSWORD=${RSTUDIO_PASSWORD} \
            --name ds-rstudio-${PROFILE} \
            ${IMAGE} rstudio
        ;;
    claude)
        echo "Starting Claude Code (profile $PROFILE)..."
        podman run -it --rm \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            --name ds-claude-${PROFILE} \
            ${IMAGE} claude
        ;;
    bash)
        echo "Starting shell (profile $PROFILE)..."
        podman run -it --rm \
            ${COMMON_VOLUMES} \
            ${COMMON_ENV} \
            --name ds-bash-${PROFILE} \
            ${IMAGE} bash
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash]"
        exit 1
        ;;
esac
