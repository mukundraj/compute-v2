#!/bin/bash
set -e

# Linux: raise file descriptor limit and ensure XDG_RUNTIME_DIR is writable
if [[ "$(uname)" == "Linux" ]]; then
    ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
fi
if [[ "$(uname)" == "Linux" ]] && [ ! -w "${XDG_RUNTIME_DIR:-}" ]; then
    # Must be on local /tmp — network-mounted $HOME breaks network namespace creation
    export XDG_RUNTIME_DIR="/tmp/${USER}-podman-runtime"
    # Reconcile stale Podman state after runtime dir change
    podman system migrate &>/dev/null || true
fi
if [[ "$(uname)" == "Linux" ]]; then
    # /tmp is cleared on reboot; recreate dirs Podman won't create itself
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    mkdir -p "${XDG_RUNTIME_DIR}/libpod/tmp"
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
# Machine-local, untracked overrides (e.g. APT_PACKAGES). See config.local.env.example.
# Auto-seed from the tracked example on first run; the copy stays gitignored.
[ -f config.local.env ] || { [ -f config.local.env.example ] && cp config.local.env.example config.local.env; }
[ -f config.local.env ] && source config.local.env
set +a

# Parse flags out of positional args. --reset-env wipes the persistent
# ds-conda-envs-<profile> volume before starting, so entrypoint.sh's
# first-run branch repopulates denv from the current image. Useful when
# the volume has rotted (libexpat ABI drift, missing jupyter_core, etc.)
# and a plain restart keeps re-mounting the same broken env.
# --memory <val> (or --memory=<val>) caps the container's memory for this
# launch, overriding CONTAINER_MEMORY from config.env/config.local.env;
# the (system RAM - 2G) ceiling below still applies.
RESET_ENV=false
MEMORY_FLAG=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --reset-env) RESET_ENV=true ;;
        --memory)
            if [ $# -lt 2 ]; then
                echo "Error: --memory requires a value (e.g. --memory 16G)" >&2
                exit 1
            fi
            MEMORY_FLAG="$2"; shift ;;
        --memory=*) MEMORY_FLAG="${1#--memory=}" ;;
        *) POSITIONAL+=("$1") ;;
    esac
    shift
done
PROFILE=${POSITIONAL[0]:-a}
SERVICE=${POSITIONAL[1]:-jupyter}

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
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode] [--reset-env] [--memory <size>]"
        exit 1
        ;;
esac

if [ "$RESET_ENV" = "true" ]; then
    CONTAINER_NAME="ds-${SERVICE}-${PROFILE}"
    VOLUME_NAME="ds-conda-envs-${PROFILE}"
    echo "Resetting ${VOLUME_NAME}..."
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    podman rm   "$CONTAINER_NAME" 2>/dev/null || true
    # --force lets us recover from missing-lock-file states (e.g. after a
    # VM reboot wiped /run/user/<uid>/) that would otherwise abort the rm.
    podman volume rm --force "$VOLUME_NAME" 2>/dev/null || true
    echo "Done. Continuing normal start; entrypoint will recreate denv."
fi

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
    # Resolve relative paths against the cwd where the command was invoked
    # (podman -v requires an absolute host path). $CALLER_PWD lets a wrapper
    # that has to `cd` elsewhere first (e.g. the ansible-installed
    # /etc/profile.d/zz-compute-v2-local.sh shortcuts) record the user's
    # actual interactive cwd; falls back to $PWD when unset.
    [[ "$KEY_PATH" != /* ]] && KEY_PATH="${CALLER_PWD:-$PWD}/${KEY_PATH#./}"
    if [ ! -f "$KEY_PATH" ]; then
        echo "Warning: GCP_SERVICE_ACCOUNT_KEY '${GCP_SERVICE_ACCOUNT_KEY}' not found at ${KEY_PATH} — skipping GCP credential mount." >&2
    else
        GCP_ARGS+=(-v "${KEY_PATH}:/run/secrets/gcp-key.json:ro,Z"
                   -e "GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-key.json")
    fi
fi

# GCP_ENV override (rarely needed — only set if you need to inject extra env vars)
if [ -n "${GCP_ENV:-}" ]; then
    # shellcheck disable=SC2206
    GCP_ARGS+=(${GCP_ENV})
fi

# Extra bind mounts (e.g. supplementary data disks). Word-split
# intentionally, like GCP_VOLUMES — no spaces within individual values.
# Settable from the environment (a login shell that exports it survives into
# the config sourcing above unless config.local.env redefines it) or from
# config.local.env directly.
if [ -n "${EXTRA_VOLUMES:-}" ]; then
    # shellcheck disable=SC2206
    GCP_ARGS+=(${EXTRA_VOLUMES})
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

# Extra apt system libs. The named .deb cache persists downloads so re-installs
# after the first pull are fast/offline; entrypoint.sh runs the actual apt-get
# install on every start (unpacked files live in the ephemeral overlay and can't
# otherwise survive a restart). config.local.env is mounted rw and DS_PROFILE is
# passed so the in-container apt wrapper can auto-record ad-hoc `apt install`s
# into the matching APT_PACKAGES_<profile> line.
if [ -f "${SCRIPT_DIR}/config.local.env" ]; then
    # Rootless Podman maps the container user outside this file's owner, so it
    # appears as nobody:nogroup inside and the apt wrapper can't record to it.
    # `:U` chown fails on rootless, so instead grant "other" write here (we run as
    # the file's owner); the container user falls into the "other" class.
    chmod o+w "${SCRIPT_DIR}/config.local.env" 2>/dev/null || true
    PACKAGES_ARGS+=(
        -v "ds-apt-cache-${PROFILE}:/var/cache/apt/archives"
        -v "${SCRIPT_DIR}/config.local.env:/opt/config.local.env:Z"
        -v "${SCRIPT_DIR}/templates/apt-autosave.sh:/opt/apt-autosave.sh:ro,Z"
        -e "DS_PROFILE=${PROFILE}"
    )
fi

# Per-profile APT_PACKAGES_<A|B> wins; APT_PACKAGES is the shared fallback.
_apt_var="APT_PACKAGES_$(echo "$PROFILE" | tr '[:lower:]' '[:upper:]')"
APT_PACKAGES="${!_apt_var:-${APT_PACKAGES:-}}"
[ -n "${APT_PACKAGES:-}" ] && PACKAGES_ARGS+=(-e "APT_PACKAGES=${APT_PACKAGES}")

# GPU passthrough (optional) — requires nvidia-container-toolkit + CDI spec on host.
# --security-opt=label=disable is needed on SELinux hosts (RHEL/Fedora); harmless elsewhere.
GPU_ARGS=()
if [ "${GPU_ENABLED:-false}" = "true" ]; then
    GPU_ARGS+=(--device nvidia.com/gpu=all
               --security-opt=label=disable)
fi

# ---- Container memory limit ----
# Hard ceiling: total system RAM minus 2G host headroom. "auto" (the
# config.env default) resolves to exactly that ceiling; an explicit value
# (--memory flag > CONTAINER_MEMORY in config.local.env > config.env) is
# capped to it, with a message, so a container can never starve the host.
mem_to_mib() {
    local v num unit
    v=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    if [[ "$v" =~ ^([0-9]+)(B|K|KB|M|MB|G|GB|T|TB)?$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        case "$unit" in
            B)       echo $(( num / 1048576 )) ;;
            K|KB)    echo $(( num / 1024 )) ;;
            ""|M|MB) echo "$num" ;;
            G|GB)    echo $(( num * 1024 )) ;;
            T|TB)    echo $(( num * 1024 * 1024 )) ;;
        esac
    else
        echo "Error: unparseable memory value '$1' (expected e.g. 16G, 1500M)" >&2
        return 1
    fi
}
mib_to_human() {
    if (( $1 % 1024 == 0 )); then echo "$(( $1 / 1024 ))G"; else echo "${1}M"; fi
}
if [[ "$(uname)" == "Darwin" ]]; then
    TOTAL_MIB=$(( $(sysctl -n hw.memsize) / 1048576 ))
else
    TOTAL_MIB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
fi
CAP_MIB=$(( TOTAL_MIB - 2048 ))
MEM_REQ="${MEMORY_FLAG:-${CONTAINER_MEMORY:-auto}}"
MEM_ARGS=()
if [ "$CAP_MIB" -le 0 ]; then
    echo "Warning: system RAM ($(mib_to_human "$TOTAL_MIB")) leaves nothing below the 2G host headroom — skipping container memory limit." >&2
else
    if [ "$MEM_REQ" = "auto" ]; then
        MEM_MIB=$CAP_MIB
        echo "Container memory limit: $(mib_to_human "$MEM_MIB") (system RAM $(mib_to_human "$TOTAL_MIB") minus 2G host headroom)"
    else
        MEM_MIB=$(mem_to_mib "$MEM_REQ") || exit 1
        if [ "$MEM_MIB" -gt "$CAP_MIB" ]; then
            echo "Memory: requested ${MEM_REQ} exceeds system RAM ($(mib_to_human "$TOTAL_MIB")) minus 2G host headroom — capping to $(mib_to_human "$CAP_MIB")."
            MEM_MIB=$CAP_MIB
        fi
        echo "Container memory limit: $(mib_to_human "$MEM_MIB")"
    fi
    MEM_ARGS=(--memory "${MEM_MIB}m")
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

# Check if container is already running.
# CONTAINER_NAME also doubles as the in-container --hostname below, so the
# shell prompt reads e.g. root@ds-jupyter-a instead of a random ID hash.
CONTAINER_NAME="ds-${SERVICE}-${PROFILE}"
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container '${CONTAINER_NAME}' is already running."

    # Reprint the connection URL using the live bound port. status.sh below
    # can only show the literal config.env value (which is "auto" when
    # pick_port() assigned the port at first start), so on its own it gives
    # a useless "http://localhost:auto". Look up the real host port via
    # `podman port` and emit the same banner the first-start path prints.
    case "$SERVICE" in
        jupyter) _cport=8888; _label="JupyterLab" ;;
        rstudio) _cport=8787; _label="RStudio" ;;
        vscode)  _cport=8080; _label="VS Code Server" ;;
        *)       _cport=""; _label="" ;;
    esac
    if [[ -n "$_cport" ]]; then
        _hport=$(podman port "$CONTAINER_NAME" "${_cport}/tcp" 2>/dev/null | head -n1 | awk -F: '{print $NF}')
        if [[ -n "$_hport" ]]; then
            echo "${_label} → http://${HOST_IP}:${_hport} (local)"
            [[ -n "$PUBLIC_IP" ]] && echo "${_label} → http://${PUBLIC_IP}:${_hport} (public)"
        fi
    fi
    echo ""
    bash "$(dirname "$0")/status.sh"
    exit 0
fi

# A container with this name can still exist in a NON-running state (exited or
# "created") if a previous run was killed before podman's --rm cleanup fired —
# OOM kill, host reboot, or a SIGKILL'd stop. The `podman ps` guard above only
# sees RUNNING containers, so such a leftover slips past it and then collides at
# `podman run --name` with 'the container name "ds-<svc>-<profile>" is already
# in use ... use --replace'. Force-remove any stale same-named container first
# so a stop+start (or a start after an unclean exit) always succeeds. No-op when
# nothing is left over; the running case already returned above, so this never
# removes a live container.
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

case "$SERVICE" in
    jupyter)
        echo "Starting JupyterLab (profile $PROFILE)..."
        podman run -d --rm \
            -p "0.0.0.0:${JUPYTER_PORT}:8888" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            "${GPU_ARGS[@]}" \
            "${MEM_ARGS[@]}" \
            -e "JUPYTER_PASSWORD=$(whoami)" \
            --name "$CONTAINER_NAME" \
            --hostname "$CONTAINER_NAME" \
            "${IMAGE}" jupyter
        echo "JupyterLab → http://${HOST_IP}:${JUPYTER_PORT} (local)"
        [[ -n "$PUBLIC_IP" ]] && echo "JupyterLab → http://${PUBLIC_IP}:${JUPYTER_PORT} (public)"
        ;;
    rstudio)
        echo "Starting RStudio (profile $PROFILE)..."
        # The image entrypoint starts RStudio via rocker's s6 supervisor
        # (`exec /init`). Under ROOTLESS podman, s6-overlay-preinit can't chown
        # /var/run/s6 ("Operation not permitted" inside the user namespace) and
        # aborts, so the container exits immediately. entrypoint.sh handles this
        # by running rserver directly in the foreground when COMPUTE_V2_ROOTLESS
        # is true (same shape as jupyter/vscode); rootful keeps the s6 path.
        #
        # We pass the rootless flag rather than overriding --entrypoint, so
        # entrypoint.sh STILL RUNS and performs the GCP credential/env setup
        # (gcloud activate-service-account + z-gcp.sh + Renviron.site) that the
        # RStudio terminal and R sessions depend on. The old code used
        # `--entrypoint bash ... exec rserver`, which bypassed entrypoint.sh
        # entirely and left rstudio with the metadata SA active and no
        # GOOGLE_APPLICATION_CREDENTIALS / CLOUDSDK_PYTHON_SITEPACKAGES in the
        # terminal — unlike jupyter/vscode, which launch the entrypoint normally.
        RSTUDIO_ROOTLESS=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)
        podman run -d --rm \
            -p "0.0.0.0:${RSTUDIO_PORT}:8787" \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            "${GPU_ARGS[@]}" \
            "${MEM_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            -e "COMPUTE_V2_ROOTLESS=${RSTUDIO_ROOTLESS}" \
            --name "$CONTAINER_NAME" \
            --hostname "$CONTAINER_NAME" \
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
            "${GPU_ARGS[@]}" \
            "${MEM_ARGS[@]}" \
            --name "$CONTAINER_NAME" \
            --hostname "$CONTAINER_NAME" \
            "${IMAGE}" claude
        ;;
    bash)
        echo "Starting shell (profile $PROFILE)..."
        podman run -it --rm \
            "${COMMON_VOLUMES[@]}" \
            "${COMMON_ENV[@]}" \
            "${GCP_ARGS[@]}" \
            "${PACKAGES_ARGS[@]}" \
            "${GPU_ARGS[@]}" \
            "${MEM_ARGS[@]}" \
            --name "$CONTAINER_NAME" \
            --hostname "$CONTAINER_NAME" \
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
            "${GPU_ARGS[@]}" \
            "${MEM_ARGS[@]}" \
            -e "PASSWORD=$(whoami)" \
            -v "ds-vscode-config-${PROFILE}:/root/.local/share/code-server" \
            --name "$CONTAINER_NAME" \
            --hostname "$CONTAINER_NAME" \
            "${IMAGE}" vscode
        echo "VS Code Server → http://${HOST_IP}:${VSCODE_PORT} (local)"
        [[ -n "$PUBLIC_IP" ]] && echo "VS Code Server → http://${PUBLIC_IP}:${VSCODE_PORT} (public)"
        if [[ -n "$PUBLIC_IP" ]]; then
            echo ""
            echo "First, enter this in your laptop terminal:"
            # SUDO_USER survives `sudo -i` via sudo's default env_keep, so when
            # run.sh runs under the ansible wrapper's auto-redirect
            # (`sudo -iu <name>ai vscode`) we still print the original human's
            # username — the one that's actually SSH-reachable via OS Login.
            # Falls back to whoami for direct (non-sudo) invocations.
            echo "  ssh -N -L ${VSCODE_PORT}:localhost:${VSCODE_PORT} ${SUDO_USER:-$(whoami)}@${PUBLIC_IP}"
            echo "Then, enter this in your browser:"
            echo "  http://localhost:${VSCODE_PORT}"
        fi
        ;;
    *)
        echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode] [--reset-env] [--memory <size>]"
        exit 1
        ;;
esac
