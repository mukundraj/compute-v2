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
    # Reconcile stale Podman state after runtime dir change
    podman system migrate &>/dev/null || true
fi

# Detect and recover from stale boot ID after a system reboot
if [[ "$(uname)" == "Linux" ]]; then
    _podman_check=$(podman info 2>&1 || true)
    if echo "$_podman_check" | grep -q "unhandled reboot"; then
        echo "Detected stale Podman state from a previous boot — cleaning up..."
        # Extract the two paths Podman tells us to delete from the error message
        while IFS= read -r _dir; do
            [ -n "$_dir" ] && rm -rf "$_dir" && echo "  removed: $_dir"
        done < <(echo "$_podman_check" | grep -oP '"[^"]+"' | tr -d '"')
        echo "Cleanup done. Retrying..."
    fi
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

# Assign the first available port in 8901-8920; exits if none are free.
pick_port() {
    for port in $(seq 8901 8920); do
        if ! ss -tlnH "sport = :${port}" 2>/dev/null | grep -q . &&
           ! podman ps --format '{{.Ports}}' 2>/dev/null | grep -qE ":${port}->"; then
            echo "$port"
            return 0
        fi
    done
    echo "Error: no free port available in 8901-8920" >&2
    exit 1
}

[[ "$JUPYTER_PORT"  == "auto" ]] && JUPYTER_PORT=$(pick_port)
[[ "$RSTUDIO_PORT"  == "auto" ]] && RSTUDIO_PORT=$(pick_port)
[[ "$VSCODE_PORT"   == "auto" ]] && VSCODE_PORT=$(pick_port)

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

# Resolve host IP for display (prefer first non-loopback address)
if [[ "$(uname)" == "Darwin" ]]; then
    HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")
else
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
HOST_IP=${HOST_IP:-localhost}

# Resolve public IP (best-effort, silent on failure)
PUBLIC_IP=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

case "$SERVICE" in
    jupyter)
        echo "Starting JupyterLab (profile $PROFILE)..."
        podman run -d --rm \
            -p "0.0.0.0:${JUPYTER_PORT}:8888" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "JUPYTER_PASSWORD=$(whoami)" \
            --name "ds-jupyter-${PROFILE}" \
            "${IMAGE}" jupyter
        echo "JupyterLab → http://${HOST_IP}:${JUPYTER_PORT} (local)"
        [[ -n "$PUBLIC_IP" ]] && echo "JupyterLab → http://${PUBLIC_IP}:${JUPYTER_PORT} (public)"
        ;;
    rstudio)
        echo "Starting RStudio (profile $PROFILE)..."
        podman run -d --rm \
            -p "0.0.0.0:${RSTUDIO_PORT}:8787" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            --name "ds-rstudio-${PROFILE}" \
            "${IMAGE}" rstudio
        echo "RStudio → http://${HOST_IP}:${RSTUDIO_PORT} (local)"
        [[ -n "$PUBLIC_IP" ]] && echo "RStudio → http://${PUBLIC_IP}:${RSTUDIO_PORT} (public)"
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
        echo "Starting VS Code Server (profile $PROFILE)..."
        podman run -d --rm \
            -p "0.0.0.0:${VSCODE_PORT}:8080" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            -v "ds-vscode-config-${PROFILE}:/root/.local/share/code-server" \
            --name "ds-vscode-${PROFILE}" \
            "${IMAGE}" vscode
        echo "VS Code Server → http://${HOST_IP}:${VSCODE_PORT} (local)"
        [[ -n "$PUBLIC_IP" ]] && echo "VS Code Server → http://${PUBLIC_IP}:${VSCODE_PORT} (public)"
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode]"
        exit 1
        ;;
esac
